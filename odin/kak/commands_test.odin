// Tests for the commands port (src/commands.cc has no UnitTests, so
// these cover each command family: bad args, missing buffer/client,
// empty selections and allocator cleanup).
package kak

import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

// test_commands_singleton_mutex serializes whole test bodies that
// touch the per-test singletons (the suite runs tests in parallel).
test_commands_singleton_mutex: sync.Mutex

// Test_Commands_Fixture bundles local managers plus the global scope
// with builtin options declared (what main.cc provides in prod).
Test_Commands_Fixture :: struct {
	global:       ^Global_Scope,
	buffers:      Buffer_Manager,
	clients:      Client_Manager,
	commands:     Command_Manager,
	registers:    Register_Manager,
	highlighters: Highlighter_Registry,
	server:       Server,
	env:          Commands_Env,
	allocator:    mem.Allocator,
}

test_commands_declare_builtins :: proc(g: ^Global_Scope) {
	reg := &g.global_data.option_registry
	if !option_manager_registry_exists(reg, "disabled_hooks") {
		_, _ = option_manager_registry_declare(reg, "disabled_hooks", "", Regex{})
	}
	if !option_manager_registry_exists(reg, "debug") {
		_, _ = option_manager_registry_declare(reg, "debug", "", Option_types_Debug_Flags{})
	}
	if !option_manager_registry_exists(reg, "ignored_files") {
		ignored, _, _ := regex_make(`(^(\..*|.*\.(o|so|a))$)`, {})
		_, _ = option_manager_registry_declare(reg, "ignored_files", "", ignored)
		regex_destroy(&ignored)
	}
	if !option_manager_registry_exists(reg, "writemethod") {
		_, _ = option_manager_registry_declare(
			reg,
			"writemethod",
			"",
			File_Write_Method.Overwrite,
		)
	}
	if !option_manager_registry_exists(reg, "tabstop") {
		_, _ = option_manager_registry_declare(reg, "tabstop", "", 8)
	}
	if !option_manager_registry_exists(reg, "readonly") {
		_, _ = option_manager_registry_declare(reg, "readonly", "", false)
	}
	// Client/input-handler paths get_checked these (C++ main.cc
	// builtins); the flag sets stay empty (no autoinfo/autocomplete).
	if !option_manager_registry_exists(reg, "idle_timeout") {
		_, _ = option_manager_registry_declare(reg, "idle_timeout", "", 50)
	}
	if !option_manager_registry_exists(reg, "fs_check_timeout") {
		_, _ = option_manager_registry_declare(reg, "fs_check_timeout", "", 500)
	}
	if !option_manager_registry_exists(reg, "scrolloff") {
		_, _ = option_manager_registry_declare(reg, "scrolloff", "", Coord_Display{})
	}
	if !option_manager_registry_exists(reg, "autoinfo") {
		_, _ = option_manager_registry_declare(reg, "autoinfo", "", Auto_Info{})
	}
	if !option_manager_registry_exists(reg, "autocomplete") {
		_, _ = option_manager_registry_declare(reg, "autocomplete", "", Auto_Complete{})
	}
	// .No keeps client_check_if_buffer_needs_reloading off the
	// filesystem in tests.
	if !option_manager_registry_exists(reg, "autoreload") {
		_, _ = option_manager_registry_declare(reg, "autoreload", "", Autoreload.No)
	}
}

test_commands_setup :: proc(allocator := context.allocator) -> ^Test_Commands_Fixture {
	// Local (non-singleton) global scope: fully isolated per test.
	g := scope_global_make(allocator)
	test_commands_declare_builtins(g)
	// Detach the global hook watcher: global-option notify would run
	// the Global_Set_Option hook with a bare context, whose scope
	// lookup falls back to the shared global singleton (never
	// installed here; see test_commands_setup_singletons). Reversal
	// happens in test_commands_teardown before the destroy below.
	option_manager_unregister_watcher(
		&g.scope.data.options,
		Option_Watcher{data = g, on_option_changed = scope_global_watcher_callback},
	)
	f := new(Test_Commands_Fixture, allocator)
	f.global = g
	f.buffers = buffer_manager_make(allocator)
	f.clients = client_manager_make(allocator)
	f.commands = command_manager_make(allocator)
	f.registers = register_manager_make(allocator)
	f.highlighters = make(Highlighter_Registry, 8, allocator)
	f.server = Server{session = "test-session", allocator = allocator}
	f.allocator = allocator
	f.env = Commands_Env{
		buffers      = &f.buffers,
		clients      = &f.clients,
		commands     = &f.commands,
		global       = g,
		server       = &f.server,
		registers    = &f.registers,
		highlighters = &f.highlighters,
	}
	return f
}

test_commands_teardown :: proc(f: ^Test_Commands_Fixture) {
	// buffer_destroy drops the scope without unregistering its parent
	// watch; detach first so the global destroy finds no watchers.
	for buf in f.buffers.buffers {
		test_commands_detach_buffer(buf)
		test_commands_destroy_buffer_scope_contents(buf)
		buffer_destroy(buf)
	}
	delete(f.buffers.buffers)
	for buf in f.buffers.buffer_trash {
		test_commands_detach_buffer(buf)
		test_commands_destroy_buffer_scope_contents(buf)
		buffer_destroy(buf)
	}
	delete(f.buffers.buffer_trash)
	for client in f.clients.clients {
		test_commands_destroy_client(client, f.allocator)
	}
	delete(f.clients.clients)
	for client in f.clients.client_trash {
		test_commands_destroy_client(client, f.allocator)
	}
	delete(f.clients.client_trash)
	delete(f.clients.free_windows)
	command_manager_destroy(&f.commands)
	register_manager_destroy(&f.registers)
	delete(f.highlighters)
	// Reattach the watcher detached in setup (the destroy asserts
	// its registration).
	option_manager_register_watcher(
		&f.global.scope.data.options,
		Option_Watcher{data = f.global, on_option_changed = scope_global_watcher_callback},
	)
	scope_global_destroy(f.global, f.allocator)
	free(f, f.allocator)
}

test_commands_detach_buffer :: proc(buf: ^Buffer) {
	opts := &buf.scope.data.options
	if opts.parent == nil {
		return
	}
	option_manager_unregister_watcher(
		opts.parent,
		Option_Watcher{data = opts, on_option_changed = option_manager_watcher_callback},
	)
	opts.parent = nil
}

// test_commands_destroy_buffer_scope_contents frees the contents of a
// buffer scope's hook/alias/option containers. buffer_destroy drops
// those containers without freeing their entries (its "nothing can
// populate them yet" predates commands, which populates all three),
// so populated scopes would leak without this. Destroyed containers
// are zeroed/nilled where the later buffer_destroy would otherwise
// double-delete. Options are destroyed per-option rather than via
// option_manager_destroy, whose no-watchers assert client contexts
// still holding watches would trip.
test_commands_destroy_buffer_scope_contents :: proc(buf: ^Buffer) {
	hook_manager_destroy(&buf.scope.data.hooks)
	alias_registry_destroy(&buf.scope.data.aliases)
	buf.scope.data.aliases.aliases = nil
	for _, opt in buf.scope.data.options.options {
		option_manager_option_destroy(opt)
	}
	delete(buf.scope.data.options.options)
	buf.scope.data.options.options = nil
}

test_commands_make_buffer :: proc(
	f: ^Test_Commands_Fixture,
	name: string,
	flags: Buffer_Flags,
	lines: []string,
) -> ^Buffer {
	// No_Hooks: Buf_* hooks run through input_handler_make, which
	// traps in production input_handler_push_mode (reported), so no
	// fixture buffer may trigger hook execution (delete, set-option
	// notify and friends all stay hook-free).
	buf := buffer_make(name, flags + {.No_Hooks}, lines, .None, .Lf, .Present, File_Fs_Status{})
	// Full reparent (not a bare options.parent write): the option
	// watcher registration must exist so buffer_destroy can unregister.
	scope_reparent(&buf.scope, &f.global.scope)
	// Mirror buffer_on_registered's self-watch (minus hook machinery):
	// buffer_manager_delete's on_unregistered asserts it exists.
	option_manager_register_watcher(
		&buf.scope.data.options,
		Option_Watcher{data = buf, on_option_changed = buffer_option_watcher_callback},
	)
	append(&f.buffers.buffers, buf)
	return buf
}

test_commands_make_context :: proc(
	f: ^Test_Commands_Fixture,
	buf: ^Buffer,
	name := "test",
) -> Context {
	ctx: Context
	sels := selection_list_make_single(
		buf,
		Selection{},
		buffer_timestamp(buf),
		f.allocator,
	)
	// context_init clones the list into the selection history; the
	// caller's copy is freed here.
	context_init(&ctx, nil, sels, {}, name, f.allocator)
	selection_list_destroy(&sels)
	// Attach the buffer so context_scope resolves to the fixture's
	// buffer scope (never the process-global singleton scope).
	if cerr := context_change_buffer(&ctx, buf); cerr != .None {
		panic("test_commands_make_context: context_change_buffer failed")
	}
	return ctx
}

test_commands_make_shell :: proc(
	f: ^Test_Commands_Fixture,
) -> Shell_Context {
	return Shell_Context{
		params   = {},
		env_vars = make(Env_Var_Map, 0, f.allocator),
	}
}

test_commands_free_shell :: proc(f: ^Test_Commands_Fixture, sc: ^Shell_Context) {
	commands_destroy_shell_context(sc, f.allocator)
}

// test_commands_free_msg frees a core-returned message. Cores return a
// static "" on success, which must never be passed to delete.
test_commands_free_msg :: proc(s: string, allocator: mem.Allocator) {
	if len(s) > 0 {
		delete(s, allocator)
	}
}

// test_commands_parse builds a parser for a builtin's spec. The spec
// desc must be released with commands_destroy_desc and the parser
// with parameters_parser_free (same allocator ambient).
test_commands_parse :: proc(
	f: ^Test_Commands_Fixture,
	spec_name: string,
	args: []string,
) -> (
	Parameters_Parser,
	Commands_Spec,
	Parameters_Parser_Error,
) {
	spec, ok := commands_spec_for(spec_name, f.allocator)
	assert(ok)
	p, perr := parameters_parser_parse(args, spec.desc, false, f.allocator)
	return p, spec, perr
}

test_commands_free_parse :: proc(
	f: ^Test_Commands_Fixture,
	p: ^Parameters_Parser,
	spec: ^Commands_Spec,
) {
	parameters_parser_free(p)
	commands_destroy_desc(&spec.desc)
}

test_commands_noop_exit :: proc(data: rawptr, status: int) {}

// test_commands_make_client builds a minimal client with a real input
// handler context on buf (stub UI, no window).
test_commands_make_client :: proc(
	f: ^Test_Commands_Fixture,
	buf: ^Buffer,
	name: string,
) -> ^Client {
	sels := selection_list_make_single(
		buf,
		Selection{},
		buffer_timestamp(buf),
		f.allocator,
	)
	// commands_input_handler_init (via context_init) clones the
	// list; the caller's copy is freed here.
	client := new(Client, f.allocator)
	client^ = Client{}
	client.allocator = f.allocator
	commands_input_handler_init(&client.input_handler, sels, {}, name, f.allocator)
	selection_list_destroy(&sels)
	// Production clients link back from their context (info, quit
	// and echo-status all key off context_has_client).
	client.input_handler.ctx.client = client
	// Prompt display reads dimensions through the UI; reuse the
	// client module's recording stub.
	ui_state := new(Client_Test_Ui, f.allocator)
	ui_state^ = Client_Test_Ui{ok = true, dims = Coord_Display{24, 80}}
	ui := new(User_Interface, f.allocator)
	ui^ = user_interface_make(ui_state, &client_test_ui_vtable)
	client.ui = ui
	client.on_exit = Client_On_Exit_Callback{call = test_commands_noop_exit}
	append(&f.clients.clients, client)
	return client
}

test_commands_destroy_client :: proc(client: ^Client, allocator := context.allocator) {
	// Mirrors client_destroy minus the window/singleton parts (test
	// clients have no window and never install the client singleton).
	input_handler_deinit(&client.input_handler)
	client_info_hide(client, false)
	client_display_line_destroy(&client.status_prompt, allocator)
	client_display_line_destroy(&client.status_content, allocator)
	client_display_line_destroy(&client.mode_line, allocator)
	client_display_line_destroy(&client.info.title, allocator)
	client_display_line_list_destroy(&client.info.content, allocator)
	client_display_line_list_destroy(&client.menu.items, allocator)
	delete(client.pending_keys)
	env_vars_free(&client.env_vars, allocator)
	// The stub UI state is test-owned (production leaves ui.data to
	// its creator).
	if client.ui != nil {
		free(cast(^Client_Test_Ui)client.ui.data, allocator)
		free(client.ui, allocator)
	}
	free(client, allocator)
}

// Per-test singleton setup/teardown for tests that execute through
// the command manager or singleton-backed completers. The suite's
// per-test allocator is rolled back when each test ends, so
// singletons must live and die inside one test (same discipline as
// shell_manager_test); sharing them across tests reuses freed
// buckets and corrupts the command map. Callers must hold
// test_commands_singleton_mutex across setup, use and teardown.
// Only singletons this module owns outright (command, register,
// highlighter); the shared global scope is never installed here
// because it may be backed by another test's rolled-back allocator
// (its hook watcher is detached from fixture globals instead, and
// executing tests push a fixture-parented local scope so the
// execute path never falls back to the singleton). Buffer/client
// singletons are owned (and reset) by other modules' tests and are
// never installed here; commands_default_env resolves them to nil.
// Builtin aliases register into the fixture global, and the
// default_env override points wrappers/completers at the fixture
// managers (with the singleton command registry swapped in so
// execute paths dispatch the registered builtins).
// Only the command-manager singleton is installed here: nested
// command execution (try/evaluate-commands/source/...) resolves the
// manager via command_manager_instance(), and no other test file
// touches that singleton, so the install is infallible. The
// register-manager singleton is deliberately NOT installed: it is
// shared with test_remainders_register_singleton, which offers no
// mutex, and only test_commands_prompt_push needs it (see
// test_commands_register_hold).
test_commands_setup_singletons :: proc(f: ^Test_Commands_Fixture) {
	command_manager_init_singleton()
	commands_register_all(command_manager_instance(), f.global)
	commands_test_env = f.env
	commands_test_env.commands = command_manager_instance()
	commands_test_env_active = true
}

test_commands_teardown_singletons :: proc() {
	commands_test_env_active = false
	commands_test_env = Commands_Env{}
	command_manager_destroy(command_manager_instance())
}

// test_commands_deschedule_guard hands the one-time suite
// descheduling sleep to whichever caller arrives first (only
// test_commands_prompt_push calls it).
test_commands_deschedule_guard: sync.Mutex
test_commands_descheduled := false

// test_commands_deschedule_for_register sleeps past the whole fast
// suite (including remainders and the 500 ms buffer_utils claimants)
// so the later register-manager hold runs uncontested. Call with NO
// locks held: sleeping under test_commands_singleton_mutex would park
// every other singleton test and exhaust the pool. Single-threaded
// runs skip the sleep: sequential alphabetical order already
// separates the prompt test from remainders deterministically.
test_commands_deschedule_for_register :: proc() {
	when #config(ODIN_TEST_THREADS, 0) != 1 {
		sync.mutex_lock(&test_commands_deschedule_guard)
		first := !test_commands_descheduled
		test_commands_descheduled = true
		sync.mutex_unlock(&test_commands_deschedule_guard)
		if first {
			time.sleep(2000 * time.Millisecond)
		}
	}
}

// test_commands_register_hold installs the register-manager
// singleton for test_commands_prompt_push (input_handler_prompt_make
// dereferences register_manager_instance() unconditionally). A
// straggler still holding it must drain first; on expiry this
// returns false and the caller fails loudly WITHOUT trapping (a
// trap would poison test_commands_singleton_mutex for every later
// singleton test, since defers do not run on trap).
test_commands_register_hold :: proc() -> bool {
	for _ in 0 ..< 20000 {
		if !register_manager_has_instance {
			register_manager_instance_init()
			return true
		}
		time.sleep(100 * time.Microsecond)
	}
	return false
}

// test_commands_register_release undoes test_commands_register_hold.
test_commands_register_release :: proc() {
	register_manager_destroy(register_manager_instance())
	register_manager_has_instance = false
}

@(test)
test_commands_register_all :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	commands_register_all(&f.commands, f.global)
	testing.expect_value(t, len(f.commands.commands), len(commands_all_names))
	for name in commands_all_names {
		testing.expect(
			t,
			command_manager_command_defined(&f.commands, name),
			name,
		)
		spec, ok := commands_spec_for(name)
		testing.expect(t, ok, name)
		commands_destroy_desc(&spec.desc)
	}
	testing.expect_value(
		t,
		alias_registry_get(&f.global.scope.data.aliases, "e"),
		"edit",
	)
	testing.expect_value(
		t,
		alias_registry_get(&f.global.scope.data.aliases, "wq!"),
		"write-quit!",
	)
	testing.expect_value(
		t,
		alias_registry_get(&f.global.scope.data.aliases, "cd"),
		"change-directory",
	)
}

@(test)
test_commands_spec_bounds :: proc(t: ^testing.T) {
	check :: proc(
		t: ^testing.T,
		name: string,
		min_pos, max_pos: int,
		flags: Parameters_Parser_Flags,
	) {
		spec, ok := commands_spec_for(name)
		testing.expect(t, ok, name)
		defer commands_destroy_desc(&spec.desc)
		testing.expect_value(t, spec.desc.min_positionals, min_pos)
		testing.expect_value(t, spec.desc.max_positionals, max_pos)
		testing.expect_value(t, spec.desc.flags, flags)
		testing.expect(t, len(spec.docstring) > 0, name)
	}
	check(t, "nop", 0, max(int), {.Ignore_Unknown_Switches})
	check(t, "edit", 0, 3, {})
	check(t, "write-all", 0, 0, {})
	check(t, "kill", 0, 1, {.Switches_As_Positional})
	check(t, "buffer", 1, 1, {})
	check(t, "hook", 4, 4, {})
	check(t, "set-option", 2, max(int), {.Switches_Only_At_Start})
	check(t, "execute-keys", 1, max(int), {.Switches_Only_At_Start})
	check(t, "prompt", 2, 2, {})
	check(t, "fail", 0, max(int), {})
	check(t, "select", 1, max(int), {.Switches_Only_At_Start})
	_, ok := commands_spec_for("no-such-command")
	testing.expect(t, !ok)
}

@(test)
test_commands_edit_switches :: proc(t: ^testing.T) {
	spec, ok := commands_spec_for("edit")
	testing.expect(t, ok)
	defer commands_destroy_desc(&spec.desc)
	testing.expect_value(t, len(spec.desc.switches), 6)
	testing.expect(t, spec.desc.switches["fifo"].takes_argument)
	testing.expect(t, !spec.desc.switches["scratch"].takes_argument)
}

@(test)
test_commands_nop :: proc(t: ^testing.T) {
	err, msg := commands_nop()
	testing.expect_value(t, err, Commands_Error.None)
	testing.expect_value(t, msg, "")
}

@(test)
test_commands_fail :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	p, spec, perr := test_commands_parse(f, "fail", {"boom", "bang"})
	testing.expect_value(t, perr, Parameters_Parser_Error.None)
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_fail(&p, f.allocator)
	defer test_commands_free_msg(msg, f.allocator)
	testing.expect_value(t, err, Commands_Error.Fail)
	testing.expect_value(t, msg, "boom bang")
}

@(test)
test_commands_fail_empty :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	p, spec, perr := test_commands_parse(f, "fail", {})
	testing.expect_value(t, perr, Parameters_Parser_Error.None)
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_fail(&p, f.allocator)
	defer test_commands_free_msg(msg, f.allocator)
	testing.expect_value(t, err, Commands_Error.Fail)
	testing.expect_value(t, msg, "")
}

@(test)
test_commands_try_arg_errors :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello"})
	ctx := test_commands_make_context(f, buf)
	defer context_destroy(&ctx)
	sc := test_commands_make_shell(f)
	defer test_commands_free_shell(f, &sc)

	p, spec, _ := test_commands_parse(f, "try", {"nop", "catch"})
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_try(&p, &ctx, &sc, f.allocator)
	defer test_commands_free_msg(msg, f.allocator)
	testing.expect_value(t, err, Commands_Error.Error)
	testing.expect_value(t, msg, "wrong argument count")

	p2, spec2, _ := test_commands_parse(f, "try", {"nop", "oops", "nop"})
	defer test_commands_free_parse(f, &p2, &spec2)
	err2, msg2 := commands_try(&p2, &ctx, &sc, f.allocator)
	defer test_commands_free_msg(msg2, f.allocator)
	testing.expect_value(t, err2, Commands_Error.Error)
}

@(test)
test_commands_try_catch :: proc(t: ^testing.T) {
	sync.lock(&test_commands_singleton_mutex)
	defer sync.unlock(&test_commands_singleton_mutex)
	f := test_commands_setup()
	defer test_commands_teardown(f)
	test_commands_setup_singletons(f)
	defer test_commands_teardown_singletons()
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello"})
	ctx := test_commands_make_context(f, buf)
	defer context_destroy(&ctx)
	// Pin a fixture-parented local scope so command_manager_execute
	// never falls back to the shared global singleton.
	exec_local := scope_local_make(&ctx, &buf.scope, f.allocator)
	defer scope_local_destroy(exec_local, f.allocator)
	sc := test_commands_make_shell(f)
	defer test_commands_free_shell(f, &sc)

	p, spec, _ := test_commands_parse(
		f,
		"try",
		{"no-such-command-xyz", "catch", "define-command trymarker nop"},
	)
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_try(&p, &ctx, &sc, f.allocator)
	if err != .None {
		test_commands_free_msg(msg, f.allocator)
	}
	testing.expect_value(t, err, Commands_Error.None)
	testing.expect(
		t,
		command_manager_command_defined(command_manager_instance(), "trymarker"),
	)
}

@(test)
test_commands_try_fail_caught :: proc(t: ^testing.T) {
	sync.lock(&test_commands_singleton_mutex)
	defer sync.unlock(&test_commands_singleton_mutex)
	f := test_commands_setup()
	defer test_commands_teardown(f)
	test_commands_setup_singletons(f)
	defer test_commands_teardown_singletons()
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello"})
	ctx := test_commands_make_context(f, buf)
	defer context_destroy(&ctx)
	exec_local := scope_local_make(&ctx, &buf.scope, f.allocator)
	defer scope_local_destroy(exec_local, f.allocator)
	sc := test_commands_make_shell(f)
	defer test_commands_free_shell(f, &sc)

	// Fail-kind errors propagate out of the failing command (C++
	// throwing model) so try/catch observes them.
	p, spec, _ := test_commands_parse(
		f,
		"try",
		{"fail oops", "catch", "define-command failmarker nop"},
	)
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_try(&p, &ctx, &sc, f.allocator)
	if err != .None {
		test_commands_free_msg(msg, f.allocator)
	}
	testing.expect_value(t, err, Commands_Error.None)
	testing.expect(
		t,
		command_manager_command_defined(command_manager_instance(), "failmarker"),
	)
}

@(test)
test_commands_try_no_catch_swallows :: proc(t: ^testing.T) {
	sync.lock(&test_commands_singleton_mutex)
	defer sync.unlock(&test_commands_singleton_mutex)
	f := test_commands_setup()
	defer test_commands_teardown(f)
	test_commands_setup_singletons(f)
	defer test_commands_teardown_singletons()
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello"})
	ctx := test_commands_make_context(f, buf)
	defer context_destroy(&ctx)
	// Pin a fixture-parented local scope so command_manager_execute
	// never falls back to the shared global singleton.
	exec_local := scope_local_make(&ctx, &buf.scope, f.allocator)
	defer scope_local_destroy(exec_local, f.allocator)
	sc := test_commands_make_shell(f)
	defer test_commands_free_shell(f, &sc)

	p, spec, _ := test_commands_parse(f, "try", {"no-such-command-xyz"})
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_try(&p, &ctx, &sc, f.allocator)
	defer test_commands_free_msg(msg, f.allocator)
	// C++ try swallows the error when no catch consumes it (the
	// first block is always try-guarded and the loop just ends).
	testing.expect_value(t, err, Commands_Error.None)
}

@(test)
test_commands_edit_scratch :: proc(t: ^testing.T) {
	// NOTE: scratch creation via buffer_manager_create is untestable
	// until buffer_make chains options to the global scope (creating
	// a buffer runs Buf_Create hooks which assert option presence).
	// This covers the find-and-switch path with a pre-created buffer.
	f := test_commands_setup()
	defer test_commands_teardown(f)
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello"})
	_ = test_commands_make_buffer(f, "*scratch*", {}, {"s"})
	ctx := test_commands_make_context(f, buf)
	defer context_destroy(&ctx)

	p, spec, _ := test_commands_parse(f, "edit", {"-scratch", "*scratch*"})
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_edit(&p, &ctx, &f.env, false, f.allocator)
	if err != .None {
		test_commands_free_msg(msg, f.allocator)
	}
	testing.expect_value(t, err, Commands_Error.None)
	testing.expect_value(t, context_buffer(&ctx).display_name, "*scratch*")

	p2, spec2, _ := test_commands_parse(f, "edit", {"-scratch", "*test*"})
	defer test_commands_free_parse(f, &p2, &spec2)
	// *test* is a scratch buffer too (no .File flag), so this switches.
	err2, msg2 := commands_edit(&p2, &ctx, &f.env, false, f.allocator)
	if err2 != .None {
		test_commands_free_msg(msg2, f.allocator)
	}
	testing.expect_value(t, err2, Commands_Error.None)
	testing.expect_value(t, context_buffer(&ctx).display_name, "*test*")
}

@(test)
test_commands_edit_errors :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello"})
	ctx := test_commands_make_context(f, buf)
	defer context_destroy(&ctx)

	p, spec, _ := test_commands_parse(f, "edit", {"-scratch", "-readonly", "*s*"})
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_edit(&p, &ctx, &f.env, false, f.allocator)
	defer test_commands_free_msg(msg, f.allocator)
	testing.expect_value(t, err, Commands_Error.Error)

	p2, spec2, _ := test_commands_parse(f, "edit", {})
	defer test_commands_free_parse(f, &p2, &spec2)
	err2, msg2 := commands_edit(&p2, &ctx, &f.env, false, f.allocator)
	defer test_commands_free_msg(msg2, f.allocator)
	testing.expect_value(t, err2, Commands_Error.Error)
	testing.expect_value(t, msg2, "wrong argument count")
}

@(test)
test_commands_edit_existing_buffer :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	a := test_commands_make_buffer(f, "*a*", {}, {"a"})
	b := test_commands_make_buffer(f, "*b*", {}, {"b1", "b2", "b3"})
	ctx := test_commands_make_context(f, a)
	defer context_destroy(&ctx)

	p, spec, _ := test_commands_parse(f, "edit", {"*b*", "3", "2"})
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_edit(&p, &ctx, &f.env, false, f.allocator)
	if err != .None {
		test_commands_free_msg(msg, f.allocator)
	}
	testing.expect_value(t, err, Commands_Error.None)
	testing.expect(t, context_buffer(&ctx) == b)
	main := selection_list_main(context_selections_write_only(&ctx))
	testing.expect_value(t, main.cursor.line, Coord_Line(2))
	testing.expect_value(t, main.cursor.column, Coord_Byte(1))
}

@(test)
test_commands_edit_bad_position :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	a := test_commands_make_buffer(f, "*a*", {}, {"a"})
	_ = test_commands_make_buffer(f, "*b*", {}, {"b"})
	ctx := test_commands_make_context(f, a)
	defer context_destroy(&ctx)

	p, spec, _ := test_commands_parse(f, "edit", {"*b*", "nope"})
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_edit(&p, &ctx, &f.env, false, f.allocator)
	defer test_commands_free_msg(msg, f.allocator)
	testing.expect_value(t, err, Commands_Error.Error)
	testing.expect_value(t, msg, "nope is not a number")
}

@(test)
test_commands_buffer_switch :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	a := test_commands_make_buffer(f, "*a*", {}, {"a"})
	b := test_commands_make_buffer(f, "*b*", {}, {"b"})
	ctx := test_commands_make_context(f, a)
	defer context_destroy(&ctx)

	p, spec, _ := test_commands_parse(f, "buffer", {"*b*"})
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_buffer(&p, &ctx, &f.env, f.allocator)
	if err != .None {
		test_commands_free_msg(msg, f.allocator)
	}
	testing.expect_value(t, err, Commands_Error.None)
	testing.expect(t, context_buffer(&ctx) == b)
	// C++ buffer_cmd pushes a jump before switching (current moves
	// past the single entry).
	testing.expect(t, context_jump_current_index(context_jump_list(&ctx)) == 1)

	p2, spec2, _ := test_commands_parse(f, "buffer", {"*missing*"})
	defer test_commands_free_parse(f, &p2, &spec2)
	err2, msg2 := commands_buffer(&p2, &ctx, &f.env, f.allocator)
	defer test_commands_free_msg(msg2, f.allocator)
	testing.expect_value(t, err2, Commands_Error.Error)
}

@(test)
test_commands_buffer_matching :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	a := test_commands_make_buffer(f, "*a*", {}, {"a"})
	_ = test_commands_make_buffer(f, "other", {}, {"b"})
	ctx := test_commands_make_context(f, a)
	defer context_destroy(&ctx)

	p, spec, _ := test_commands_parse(f, "buffer", {"-matching", "oth.*"})
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_buffer(&p, &ctx, &f.env, f.allocator)
	if err != .None {
		test_commands_free_msg(msg, f.allocator)
	}
	testing.expect_value(t, err, Commands_Error.None)
	testing.expect_value(t, context_buffer(&ctx).display_name, "other")

	p2, spec2, _ := test_commands_parse(f, "buffer", {"-matching", "[["})
	defer test_commands_free_parse(f, &p2, &spec2)
	err2, msg2 := commands_buffer(&p2, &ctx, &f.env, f.allocator)
	defer test_commands_free_msg(msg2, f.allocator)
	testing.expect_value(t, err2, Commands_Error.Error)
}

@(test)
test_commands_cycle_buffer :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	a := test_commands_make_buffer(f, "*a*", {}, {"a"})
	b := test_commands_make_buffer(f, "*b*", {}, {"b"})
	_ = test_commands_make_buffer(f, "*debug-skip*", {.Debug}, {"d"})
	ctx := test_commands_make_context(f, a)
	defer context_destroy(&ctx)

	err, msg := commands_cycle_buffer(&ctx, &f.env, true, f.allocator)
	if err != .None {
		test_commands_free_msg(msg, f.allocator)
	}
	testing.expect_value(t, err, Commands_Error.None)
	testing.expect(t, context_buffer(&ctx) == b)

	err2, msg2 := commands_cycle_buffer(&ctx, &f.env, true, f.allocator)
	if err2 != .None {
		test_commands_free_msg(msg2, f.allocator)
	}
	testing.expect_value(t, err2, Commands_Error.None)
	testing.expect(t, context_buffer(&ctx) == a)
}

@(test)
test_commands_delete_buffer :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	a := test_commands_make_buffer(f, "*a*", {}, {"a"})
	_ = test_commands_make_buffer(f, "*b*", {}, {"b"})
	ctx := test_commands_make_context(f, a)
	defer context_destroy(&ctx)

	p, spec, _ := test_commands_parse(f, "delete-buffer", {"*b*"})
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_delete_buffer(&p, &ctx, &f.env, false, f.allocator)
	if err != .None {
		test_commands_free_msg(msg, f.allocator)
	}
	testing.expect_value(t, err, Commands_Error.None)
	testing.expect(t, buffer_manager_get_ifp(&f.buffers, "*b*") == nil)
	testing.expect_value(t, len(f.buffers.buffers), 1)

	p2, spec2, _ := test_commands_parse(f, "delete-buffer", {"*missing*"})
	defer test_commands_free_parse(f, &p2, &spec2)
	err2, msg2 := commands_delete_buffer(&p2, &ctx, &f.env, false, f.allocator)
	defer test_commands_free_msg(msg2, f.allocator)
	testing.expect_value(t, err2, Commands_Error.Error)
}

@(test)
test_commands_delete_modified :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	a := test_commands_make_buffer(f, "mod.txt", {.File}, {"a"})
	ctx := test_commands_make_context(f, a)
	defer context_destroy(&ctx)
	_, _ = buffer_insert(a, Coord_Buffer{}, "x")

	p, spec, _ := test_commands_parse(f, "delete-buffer", {})
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_delete_buffer(&p, &ctx, &f.env, false, f.allocator)
	defer test_commands_free_msg(msg, f.allocator)
	testing.expect_value(t, err, Commands_Error.Error)
	testing.expect(t, buffer_manager_get_ifp(&f.buffers, "mod.txt") != nil)

	p2, spec2, _ := test_commands_parse(f, "delete-buffer", {})
	defer test_commands_free_parse(f, &p2, &spec2)
	other := test_commands_make_buffer(f, "*other*", {}, {"o"})
	// Seed the jump list so forgetting the current buffer falls back
	// to *other* (never the uninstalled buffer singleton).
	jsels := selection_list_make_single(
		other,
		Selection{},
		buffer_timestamp(other),
		f.allocator,
	)
	context_jump_push(&ctx.jump_list, jsels, nil, f.allocator)
	selection_list_destroy(&jsels)
	err2, msg2 := commands_delete_buffer(&p2, &ctx, &f.env, true, f.allocator)
	if err2 != .None {
		test_commands_free_msg(msg2, f.allocator)
	}
	testing.expect_value(t, err2, Commands_Error.None)
	testing.expect(t, buffer_manager_get_ifp(&f.buffers, "mod.txt") == nil)
}

@(test)
test_commands_rename_buffer :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	a := test_commands_make_buffer(f, "*a*", {}, {"a"})
	_ = test_commands_make_buffer(f, "*b*", {}, {"b"})
	ctx := test_commands_make_context(f, a)
	defer context_destroy(&ctx)

	p, spec, _ := test_commands_parse(f, "rename-buffer", {"-scratch", "-file", "*c*"})
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_rename_buffer(&p, &ctx, f.allocator)
	defer test_commands_free_msg(msg, f.allocator)
	testing.expect_value(t, err, Commands_Error.Error)
	// NOTE: rename success and the name-collision error are
	// untestable until buffer_set_name's buffer_manager stub merges
	// (it panics unconditionally); only the switch conflict is
	// covered here.
}

@(test)
test_commands_arrange_buffers :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	_ = test_commands_make_buffer(f, "*a*", {}, {"a"})
	_ = test_commands_make_buffer(f, "*b*", {}, {"b"})
	_ = test_commands_make_buffer(f, "*c*", {}, {"c"})

	p, spec, _ := test_commands_parse(f, "arrange-buffers", {"*c*", "*a*"})
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_arrange_buffers(&p, &f.env, f.allocator)
	if err != .None {
		test_commands_free_msg(msg, f.allocator)
	}
	testing.expect_value(t, err, Commands_Error.None)
	testing.expect_value(t, f.buffers.buffers[0].display_name, "*c*")
	testing.expect_value(t, f.buffers.buffers[1].display_name, "*a*")
	testing.expect_value(t, f.buffers.buffers[2].display_name, "*b*")

	p2, spec2, _ := test_commands_parse(f, "arrange-buffers", {"*missing*"})
	defer test_commands_free_parse(f, &p2, &spec2)
	err2, msg2 := commands_arrange_buffers(&p2, &f.env, f.allocator)
	defer test_commands_free_msg(msg2, f.allocator)
	testing.expect_value(t, err2, Commands_Error.Error)
}

@(test)
test_commands_write_errors :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello"})
	ctx := test_commands_make_context(f, buf)
	defer context_destroy(&ctx)

	p, spec, _ := test_commands_parse(f, "write", {})
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_write(&p, &ctx, false, f.allocator)
	defer test_commands_free_msg(msg, f.allocator)
	testing.expect_value(t, err, Commands_Error.Error)

	p2, spec2, _ := test_commands_parse(f, "write", {"-method", "bogus"})
	defer test_commands_free_parse(f, &p2, &spec2)
	err2, msg2 := commands_write(&p2, &ctx, false, f.allocator)
	defer test_commands_free_msg(msg2, f.allocator)
	testing.expect_value(t, err2, Commands_Error.Error)
}

@(test)
test_commands_write_existing_no_force :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	buf := test_commands_make_buffer(f, "orig.txt", {.File}, {"hello"})
	ctx := test_commands_make_context(f, buf)
	defer context_destroy(&ctx)

	dir, derr := os.temp_directory(f.allocator)
	testing.expect_value(t, derr, os.ERROR_NONE)
	defer delete(dir, f.allocator)
	target := strings.concatenate({dir, "/kak-cmd-test-existing.txt"}, f.allocator)
	defer delete(target, f.allocator)
	testing.expect_value(t, file_write_to_file(target, "existing"), File_Error.None)
	defer os.remove(target)

	p, spec, _ := test_commands_parse(f, "write", {target})
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_write(&p, &ctx, false, f.allocator)
	defer test_commands_free_msg(msg, f.allocator)
	testing.expect_value(t, err, Commands_Error.Error)
}

@(test)
test_commands_write_readonly :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	buf := test_commands_make_buffer(f, "ro.txt", {.File, .Read_Only}, {"hello"})
	ctx := test_commands_make_context(f, buf)
	defer context_destroy(&ctx)

	p, spec, _ := test_commands_parse(f, "write", {})
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_write(&p, &ctx, false, f.allocator)
	defer test_commands_free_msg(msg, f.allocator)
	testing.expect_value(t, err, Commands_Error.Error)
}

@(test)
test_commands_write_all_clean :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	buf := test_commands_make_buffer(f, "clean.txt", {.File}, {"hello"})
	ctx := test_commands_make_context(f, buf)
	defer context_destroy(&ctx)

	p, spec, _ := test_commands_parse(f, "write-all", {})
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_write_all(&p, &ctx, &f.env, f.allocator)
	if err != .None {
		test_commands_free_msg(msg, f.allocator)
	}
	testing.expect_value(t, err, Commands_Error.None)
}

@(test)
test_commands_ensure_saved :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	a := test_commands_make_buffer(f, "dirty.txt", {.File}, {"a"})
	_ = test_commands_make_buffer(f, "*clean*", {}, {"c"})
	ctx := test_commands_make_context(f, a)
	defer context_destroy(&ctx)
	_, _ = buffer_insert(a, Coord_Buffer{}, "x")

	err, msg := commands_ensure_all_buffers_are_saved(&ctx, &f.env, f.allocator)
	defer test_commands_free_msg(msg, f.allocator)
	testing.expect_value(t, err, Commands_Error.Error)
	testing.expect(t, strings.contains(msg, "dirty.txt"))
}

@(test)
test_commands_kill :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello"})
	ctx := test_commands_make_context(f, buf)
	defer context_destroy(&ctx)
	_ = test_commands_make_client(f, buf, "c1")
	_ = test_commands_make_client(f, buf, "c2")

	p, spec, _ := test_commands_parse(f, "kill", {"3"})
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_kill(&p, &ctx, &f.env, true, f.allocator)
	testing.expect_value(t, err, Commands_Error.Kill_Session)
	testing.expect_value(t, msg, "")
	testing.expect_value(t, commands_kill_status, 3)
	testing.expect_value(t, len(f.clients.clients), 0)
	testing.expect_value(t, len(f.clients.client_trash), 2)
}

@(test)
test_commands_kill_bad_status :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello"})
	ctx := test_commands_make_context(f, buf)
	defer context_destroy(&ctx)

	p, spec, _ := test_commands_parse(f, "kill", {"nope"})
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_kill(&p, &ctx, &f.env, true, f.allocator)
	defer test_commands_free_msg(msg, f.allocator)
	testing.expect_value(t, err, Commands_Error.Error)
}

@(test)
test_commands_daemonize :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	err, msg := commands_daemonize_session(&f.env)
	testing.expect_value(t, err, Commands_Error.None)
	testing.expect_value(t, msg, "")
	testing.expect(t, remote_server_is_daemon(&f.server))
}

@(test)
test_commands_quit :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello"})
	client := test_commands_make_client(f, buf, "c1")
	ctx := &client.input_handler.ctx
	f.server.is_daemon = true

	p, spec, _ := test_commands_parse(f, "quit", {})
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_quit(&p, ctx, &f.env, false, f.allocator)
	if err != .None {
		test_commands_free_msg(msg, f.allocator)
	}
	testing.expect_value(t, err, Commands_Error.None)
	testing.expect_value(t, len(f.clients.clients), 0)
}

@(test)
test_commands_quit_no_client :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello"})
	ctx := test_commands_make_context(f, buf)
	defer context_destroy(&ctx)

	p, spec, _ := test_commands_parse(f, "quit", {})
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_quit(&p, &ctx, &f.env, false, f.allocator)
	defer test_commands_free_msg(msg, f.allocator)
	testing.expect_value(t, err, Commands_Error.Error)
}

@(test)
test_commands_quit_last_unsaved :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	buf := test_commands_make_buffer(f, "dirty.txt", {.File}, {"a"})
	client := test_commands_make_client(f, buf, "c1")
	ctx := &client.input_handler.ctx
	_, _ = buffer_insert(buf, Coord_Buffer{}, "x")

	p, spec, _ := test_commands_parse(f, "quit", {})
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_quit(&p, ctx, &f.env, false, f.allocator)
	defer test_commands_free_msg(msg, f.allocator)
	testing.expect_value(t, err, Commands_Error.Error)
	testing.expect_value(t, len(f.clients.clients), 1)
}

@(test)
test_commands_write_quit_write_error :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello"})
	ctx := test_commands_make_context(f, buf)
	defer context_destroy(&ctx)

	p, spec, _ := test_commands_parse(f, "write-quit", {})
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_write_quit(&p, &ctx, &f.env, false, f.allocator)
	defer test_commands_free_msg(msg, f.allocator)
	testing.expect_value(t, err, Commands_Error.Error)
}

@(test)
test_commands_add_highlighter_errors :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello"})
	ctx := test_commands_make_context(f, buf)
	defer context_destroy(&ctx)

	p, spec, _ := test_commands_parse(f, "add-highlighter", {"global/", "no-such-type"})
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_add_highlighter(&p, &ctx, &f.env, f.allocator)
	defer test_commands_free_msg(msg, f.allocator)
	testing.expect_value(t, err, Commands_Error.Error)

	p2, spec2, _ := test_commands_parse(f, "add-highlighter", {"noslash", "group"})
	defer test_commands_free_parse(f, &p2, &spec2)
	err2, msg2 := commands_add_highlighter(&p2, &ctx, &f.env, f.allocator)
	defer test_commands_free_msg(msg2, f.allocator)
	testing.expect_value(t, err2, Commands_Error.Error)
}

@(test)
test_commands_remove_highlighter :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello"})
	ctx := test_commands_make_context(f, buf)
	defer context_destroy(&ctx)

	p, spec, _ := test_commands_parse(f, "remove-highlighter", {"noslash"})
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_remove_highlighter(&p, &ctx, &f.env, f.allocator)
	testing.expect_value(t, err, Commands_Error.None)
	testing.expect_value(t, msg, "")

	p2, spec2, _ := test_commands_parse(f, "remove-highlighter", {"bogus/x"})
	defer test_commands_free_parse(f, &p2, &spec2)
	err2, msg2 := commands_remove_highlighter(&p2, &ctx, &f.env, f.allocator)
	defer test_commands_free_msg(msg2, f.allocator)
	testing.expect_value(t, err2, Commands_Error.Error)
}

@(test)
test_commands_hook :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello"})
	ctx := test_commands_make_context(f, buf)
	defer context_destroy(&ctx)

	p, spec, _ := test_commands_parse(
		f,
		"hook",
		{"-group", "mygroup", "buffer", "User", ".*", "nop"},
	)
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_hook(&p, &ctx, &f.env, f.allocator)
	if err != .None {
		test_commands_free_msg(msg, f.allocator)
	}
	testing.expect_value(t, err, Commands_Error.None)
	testing.expect_value(t, len(buf.scope.data.hooks.hooks[int(Hook.User)]), 1)

	p2, spec2, _ := test_commands_parse(f, "hook", {"global", "Nope", ".*", "nop"})
	defer test_commands_free_parse(f, &p2, &spec2)
	err2, msg2 := commands_hook(&p2, &ctx, &f.env, f.allocator)
	defer test_commands_free_msg(msg2, f.allocator)
	testing.expect_value(t, err2, Commands_Error.Error)

	p3, spec3, _ := test_commands_parse(f, "hook", {"global", "User", "[[", "nop"})
	defer test_commands_free_parse(f, &p3, &spec3)
	err3, msg3 := commands_hook(&p3, &ctx, &f.env, f.allocator)
	defer test_commands_free_msg(msg3, f.allocator)
	testing.expect_value(t, err3, Commands_Error.Error)

	p4, spec4, _ := test_commands_parse(
		f,
		"hook",
		{"-group", "-bad", "global", "User", ".*", "nop"},
	)
	defer test_commands_free_parse(f, &p4, &spec4)
	err4, msg4 := commands_hook(&p4, &ctx, &f.env, f.allocator)
	defer test_commands_free_msg(msg4, f.allocator)
	testing.expect_value(t, err4, Commands_Error.Error)
}

@(test)
test_commands_remove_hooks :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello"})
	ctx := test_commands_make_context(f, buf)
	defer context_destroy(&ctx)

	p, spec, _ := test_commands_parse(
		f,
		"hook",
		{"-group", "gone", "buffer", "User", ".*", "nop"},
	)
	defer test_commands_free_parse(f, &p, &spec)
	_, _ = commands_hook(&p, &ctx, &f.env, f.allocator)
	testing.expect_value(t, len(buf.scope.data.hooks.hooks[int(Hook.User)]), 1)

	p2, spec2, _ := test_commands_parse(f, "remove-hooks", {"buffer", "gone"})
	defer test_commands_free_parse(f, &p2, &spec2)
	err, msg := commands_remove_hooks(&p2, &ctx, &f.env, f.allocator)
	if err != .None {
		test_commands_free_msg(msg, f.allocator)
	}
	testing.expect_value(t, err, Commands_Error.None)
	testing.expect_value(t, len(buf.scope.data.hooks.hooks[int(Hook.User)]), 0)
}

@(test)
test_commands_trigger_user_hook :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello"})
	ctx := test_commands_make_context(f, buf)
	defer context_destroy(&ctx)

	p, spec, _ := test_commands_parse(f, "trigger-user-hook", {"hello"})
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_trigger_user_hook(&p, &ctx, f.allocator)
	testing.expect_value(t, err, Commands_Error.None)
	testing.expect_value(t, msg, "")
}

@(test)
test_commands_define_command :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello"})
	ctx := test_commands_make_context(f, buf)
	defer context_destroy(&ctx)

	p, spec, _ := test_commands_parse(
		f,
		"define-command",
		{"-params", "1..2", "-docstring", "mydoc", "mycmd", "nop"},
	)
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_define_command(&p, &ctx, &f.env, f.allocator)
	if err != .None {
		test_commands_free_msg(msg, f.allocator)
	}
	testing.expect_value(t, err, Commands_Error.None)
	testing.expect(t, command_manager_command_defined(&f.commands, "mycmd"))
	testing.expect_value(t, f.commands.commands["mycmd"].param_desc.min_positionals, 1)
	testing.expect_value(t, f.commands.commands["mycmd"].param_desc.max_positionals, 2)

	p2, spec2, _ := test_commands_parse(f, "define-command", {"mycmd", "nop"})
	defer test_commands_free_parse(f, &p2, &spec2)
	err2, msg2 := commands_define_command(&p2, &ctx, &f.env, f.allocator)
	defer test_commands_free_msg(msg2, f.allocator)
	testing.expect_value(t, err2, Commands_Error.Error)

	p3, spec3, _ := test_commands_parse(f, "define-command", {"bad-name!", "nop"})
	defer test_commands_free_parse(f, &p3, &spec3)
	err3, msg3 := commands_define_command(&p3, &ctx, &f.env, f.allocator)
	defer test_commands_free_msg(msg3, f.allocator)
	testing.expect_value(t, err3, Commands_Error.Error)

	p4, spec4, _ := test_commands_parse(
		f,
		"define-command",
		{"-params", "bogus", "other", "nop"},
	)
	defer test_commands_free_parse(f, &p4, &spec4)
	err4, msg4 := commands_define_command(&p4, &ctx, &f.env, f.allocator)
	defer test_commands_free_msg(msg4, f.allocator)
	testing.expect_value(t, err4, Commands_Error.Error)

	p5, spec5, _ := test_commands_parse(f, "define-command", {"-menu", "menucmd", "nop"})
	defer test_commands_free_parse(f, &p5, &spec5)
	err5, msg5 := commands_define_command(&p5, &ctx, &f.env, f.allocator)
	defer test_commands_free_msg(msg5, f.allocator)
	testing.expect_value(t, err5, Commands_Error.Error)
}

@(test)
test_commands_defined_command_call :: proc(t: ^testing.T) {
	sync.lock(&test_commands_singleton_mutex)
	defer sync.unlock(&test_commands_singleton_mutex)
	f := test_commands_setup()
	defer test_commands_teardown(f)
	test_commands_setup_singletons(f)
	defer test_commands_teardown_singletons()
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello"})
	ctx := test_commands_make_context(f, buf)
	defer context_destroy(&ctx)
	// Pin a fixture-parented local scope so command_manager_execute
	// never falls back to the shared global singleton.
	exec_local := scope_local_make(&ctx, &buf.scope, f.allocator)
	defer scope_local_destroy(exec_local, f.allocator)
	sc := test_commands_make_shell(f)
	defer test_commands_free_shell(f, &sc)

	env := f.env
	env.commands = command_manager_instance()
	p, spec, _ := test_commands_parse(
		f,
		"define-command",
		{"-params", "0..3", "outermarker", "define-command innermarker nop"},
	)
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_define_command(&p, &ctx, &env, f.allocator)
	if err != .None {
		test_commands_free_msg(msg, f.allocator)
	}
	testing.expect_value(t, err, Commands_Error.None)

	exec_err, exec_msg := command_manager_execute(
		command_manager_instance(),
		"outermarker a b",
		&ctx,
		&sc,
		f.allocator,
	)
	if exec_err != .None {
		test_commands_free_msg(exec_msg, f.allocator)
	}
	testing.expect_value(t, exec_err, Commands_Error.None)
	testing.expect(
		t,
		command_manager_command_defined(command_manager_instance(), "innermarker"),
	)
}

@(test)
test_commands_parse_define_params :: proc(t: ^testing.T) {
	min_pos, max_pos, err, msg := commands_parse_define_params("2", context.allocator)
	testing.expect_value(t, err, Commands_Error.None)
	testing.expect_value(t, min_pos, 2)
	testing.expect_value(t, max_pos, 2)

	min_pos, max_pos, err, msg = commands_parse_define_params("1..3", context.allocator)
	testing.expect_value(t, err, Commands_Error.None)
	testing.expect_value(t, min_pos, 1)
	testing.expect_value(t, max_pos, 3)

	min_pos, max_pos, err, msg = commands_parse_define_params("1..", context.allocator)
	testing.expect_value(t, err, Commands_Error.None)
	testing.expect_value(t, min_pos, 1)
	testing.expect_value(t, max_pos, max(int))

	_, _, err, msg = commands_parse_define_params("bogus", context.allocator)
	defer test_commands_free_msg(msg, context.allocator)
	testing.expect_value(t, err, Commands_Error.Error)
	_ = min_pos
	_ = max_pos
}

@(test)
test_commands_complete_command :: proc(t: ^testing.T) {
	sync.lock(&test_commands_singleton_mutex)
	defer sync.unlock(&test_commands_singleton_mutex)
	f := test_commands_setup()
	defer test_commands_teardown(f)
	test_commands_setup_singletons(f)
	defer test_commands_teardown_singletons()
	env := f.env
	env.commands = command_manager_instance()

	p, spec, _ := test_commands_parse(f, "complete-command", {"nop", "file"})
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_complete_command(&p, &env, f.allocator)
	if err != .None {
		test_commands_free_msg(msg, f.allocator)
	}
	testing.expect_value(t, err, Commands_Error.None)
	testing.expect(
		t,
		command_manager_instance().commands["nop"].completer.call != nil,
	)

	p2, spec2, _ := test_commands_parse(f, "complete-command", {"nop", "bogus"})
	defer test_commands_free_parse(f, &p2, &spec2)
	err2, msg2 := commands_complete_command(&p2, &env, f.allocator)
	defer test_commands_free_msg(msg2, f.allocator)
	testing.expect_value(t, err2, Commands_Error.Error)

	p3, spec3, _ := test_commands_parse(
		f,
		"complete-command",
		{"no-such-cmd", "file"},
	)
	defer test_commands_free_parse(f, &p3, &spec3)
	err3, msg3 := commands_complete_command(&p3, &env, f.allocator)
	defer test_commands_free_msg(msg3, f.allocator)
	testing.expect_value(t, err3, Commands_Error.Error)
}

@(test)
test_commands_alias :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello"})
	ctx := test_commands_make_context(f, buf)
	defer context_destroy(&ctx)
	commands_register_all(&f.commands, f.global)

	p, spec, _ := test_commands_parse(f, "alias", {"buffer", "nn", "nop"})
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_alias(&p, &ctx, &f.env, f.allocator)
	if err != .None {
		test_commands_free_msg(msg, f.allocator)
	}
	testing.expect_value(t, err, Commands_Error.None)
	testing.expect_value(t, alias_registry_get(&buf.scope.data.aliases, "nn"), "nop")

	p2, spec2, _ := test_commands_parse(f, "alias", {"buffer", "xx", "nope"})
	defer test_commands_free_parse(f, &p2, &spec2)
	err2, msg2 := commands_alias(&p2, &ctx, &f.env, f.allocator)
	defer test_commands_free_msg(msg2, f.allocator)
	testing.expect_value(t, err2, Commands_Error.Error)

	p3, spec3, _ := test_commands_parse(f, "unalias", {"buffer", "nn", "other"})
	defer test_commands_free_parse(f, &p3, &spec3)
	err3, msg3 := commands_unalias(&p3, &ctx, &f.env, f.allocator)
	testing.expect_value(t, err3, Commands_Error.None)
	testing.expect_value(t, msg3, "")
	testing.expect_value(t, alias_registry_get(&buf.scope.data.aliases, "nn"), "nop")

	p4, spec4, _ := test_commands_parse(f, "unalias", {"buffer", "nn"})
	defer test_commands_free_parse(f, &p4, &spec4)
	err4, msg4 := commands_unalias(&p4, &ctx, &f.env, f.allocator)
	testing.expect_value(t, err4, Commands_Error.None)
	testing.expect_value(t, msg4, "")
	testing.expect_value(t, alias_registry_get(&buf.scope.data.aliases, "nn"), "")
}

@(test)
test_commands_provide_require_module :: proc(t: ^testing.T) {
	sync.lock(&test_commands_singleton_mutex)
	defer sync.unlock(&test_commands_singleton_mutex)
	f := test_commands_setup()
	defer test_commands_teardown(f)
	test_commands_setup_singletons(f)
	defer test_commands_teardown_singletons()
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello"})
	ctx := test_commands_make_context(f, buf)
	defer context_destroy(&ctx)
	env := f.env
	env.commands = command_manager_instance()

	p, spec, _ := test_commands_parse(f, "provide-module", {"testmod", "nop"})
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_provide_module(&p, &env, f.allocator)
	if err != .None {
		test_commands_free_msg(msg, f.allocator)
	}
	testing.expect_value(t, err, Commands_Error.None)

	p2, spec2, _ := test_commands_parse(f, "provide-module", {"testmod", "nop"})
	defer test_commands_free_parse(f, &p2, &spec2)
	err2, msg2 := commands_provide_module(&p2, &env, f.allocator)
	defer test_commands_free_msg(msg2, f.allocator)
	testing.expect_value(t, err2, Commands_Error.Error)

	p3, spec3, _ := test_commands_parse(f, "provide-module", {"bad-mod!", "nop"})
	defer test_commands_free_parse(f, &p3, &spec3)
	err3, msg3 := commands_provide_module(&p3, &env, f.allocator)
	defer test_commands_free_msg(msg3, f.allocator)
	testing.expect_value(t, err3, Commands_Error.Error)

	// NOTE: require-module on a provided module is untestable until
	// command_manager_load_module's context_make_empty STUB merges
	// (it panics on the load path); only the missing-module error is
	// covered here.
	p5, spec5, _ := test_commands_parse(f, "require-module", {"missingmod"})
	defer test_commands_free_parse(f, &p5, &spec5)
	err5, msg5 := commands_require_module(&p5, &ctx, &env, f.allocator)
	defer test_commands_free_msg(msg5, f.allocator)
	testing.expect_value(t, err5, Commands_Error.Error)
}

@(test)
test_commands_declare_option_types :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)

	for type, i in ([?]string{
		"int",
		"bool",
		"str",
		"regex",
		"int-list",
		"str-list",
		"completions",
		"line-specs",
		"range-specs",
		"str-to-str-map",
	}) {
		// Owned copy with dashes blanked (replace_all borrows the
		// input when nothing matches, which delete must not free).
		safe := strings.clone(type, f.allocator)
		defer delete(safe, f.allocator)
		safe_bytes := transmute([]u8)safe
		for b, j in safe_bytes {
			if b == '-' {
				safe_bytes[j] = '_'
			}
		}
		name := strings.concatenate({"testopt", safe}, f.allocator)
		_ = i
		p, spec, perr := test_commands_parse(f, "declare-option", {type, name})
		if perr != .None {
			testing.expect_value(t, perr, Parameters_Parser_Error.None)
		}
		err, msg := commands_declare_option(&p, &f.env, f.allocator)
		test_commands_free_parse(f, &p, &spec)
		if err != .None {
			test_commands_free_msg(msg, f.allocator)
		}
		testing.expect_value(t, err, Commands_Error.None)
		testing.expect(
			t,
			option_manager_registry_exists(&f.global.global_data.option_registry, name),
			type,
		)
		delete(name, f.allocator)
	}

	p, spec, _ := test_commands_parse(f, "declare-option", {"bogus", "xx"})
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_declare_option(&p, &f.env, f.allocator)
	defer test_commands_free_msg(msg, f.allocator)
	testing.expect_value(t, err, Commands_Error.Error)
}

@(test)
test_commands_set_option :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello"})
	ctx := test_commands_make_context(f, buf)
	defer context_destroy(&ctx)

	pd, specd, _ := test_commands_parse(f, "declare-option", {"int", "myint", "3"})
	defer test_commands_free_parse(f, &pd, &specd)
	_, _ = commands_declare_option(&pd, &f.env, f.allocator)

	p, spec, _ := test_commands_parse(f, "set-option", {"buffer", "myint", "42"})
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_set_option(&p, &ctx, &f.env, f.allocator)
	if err != .None {
		test_commands_free_msg(msg, f.allocator)
	}
	testing.expect_value(t, err, Commands_Error.None)
	opt, _ := option_manager_get_option(&buf.scope.data.options, "myint")
	testing.expect_value(t, opt.value.(int), 42)

	p2, spec2, _ := test_commands_parse(f, "set-option", {"buffer", "myint", "bogus"})
	defer test_commands_free_parse(f, &p2, &spec2)
	err2, msg2 := commands_set_option(&p2, &ctx, &f.env, f.allocator)
	defer test_commands_free_msg(msg2, f.allocator)
	testing.expect_value(t, err2, Commands_Error.Error)

	p3, spec3, _ := test_commands_parse(
		f,
		"set-option",
		{"-add", "-remove", "buffer", "myint", "1"},
	)
	defer test_commands_free_parse(f, &p3, &spec3)
	err3, msg3 := commands_set_option(&p3, &ctx, &f.env, f.allocator)
	defer test_commands_free_msg(msg3, f.allocator)
	testing.expect_value(t, err3, Commands_Error.Error)

	p4, spec4, _ := test_commands_parse(f, "set-option", {"buffer", "nosuch", "1"})
	defer test_commands_free_parse(f, &p4, &spec4)
	err4, msg4 := commands_set_option(&p4, &ctx, &f.env, f.allocator)
	defer test_commands_free_msg(msg4, f.allocator)
	testing.expect_value(t, err4, Commands_Error.Error)
}

@(test)
test_commands_set_option_current :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello"})
	ctx := test_commands_make_context(f, buf)
	defer context_destroy(&ctx)

	pd, specd, _ := test_commands_parse(f, "declare-option", {"str", "curstr"})
	defer test_commands_free_parse(f, &pd, &specd)
	_, _ = commands_declare_option(&pd, &f.env, f.allocator)

	p, spec, _ := test_commands_parse(f, "set-option", {"current", "curstr", "hi"})
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_set_option(&p, &ctx, &f.env, f.allocator)
	if err != .None {
		test_commands_free_msg(msg, f.allocator)
	}
	testing.expect_value(t, err, Commands_Error.None)
	opt, _ := option_manager_get_option(&f.global.scope.data.options, "curstr")
	testing.expect_value(t, opt.value.(string), "hi")

	p2, spec2, _ := test_commands_parse(f, "set-option", {"current", "nosuch", "x"})
	defer test_commands_free_parse(f, &p2, &spec2)
	err2, msg2 := commands_set_option(&p2, &ctx, &f.env, f.allocator)
	defer test_commands_free_msg(msg2, f.allocator)
	testing.expect_value(t, err2, Commands_Error.Error)
}

@(test)
test_commands_unset_update_option :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello"})
	ctx := test_commands_make_context(f, buf)
	defer context_destroy(&ctx)

	pd, specd, _ := test_commands_parse(f, "declare-option", {"int", "unint", "7"})
	defer test_commands_free_parse(f, &pd, &specd)
	_, _ = commands_declare_option(&pd, &f.env, f.allocator)

	ps, specs, _ := test_commands_parse(f, "set-option", {"buffer", "unint", "9"})
	defer test_commands_free_parse(f, &ps, &specs)
	_, _ = commands_set_option(&ps, &ctx, &f.env, f.allocator)
	_, found := buf.scope.data.options.options["unint"]
	testing.expect(t, found)

	p, spec, _ := test_commands_parse(f, "unset-option", {"buffer", "unint"})
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_unset_option(&p, &ctx, &f.env, f.allocator)
	if err != .None {
		test_commands_free_msg(msg, f.allocator)
	}
	testing.expect_value(t, err, Commands_Error.None)
	_, found_after := buf.scope.data.options.options["unint"]
	testing.expect(t, !found_after)

	p2, spec2, _ := test_commands_parse(f, "unset-option", {"global", "unint"})
	defer test_commands_free_parse(f, &p2, &spec2)
	err2, msg2 := commands_unset_option(&p2, &ctx, &f.env, f.allocator)
	defer test_commands_free_msg(msg2, f.allocator)
	testing.expect_value(t, err2, Commands_Error.Error)

	p3, spec3, _ := test_commands_parse(f, "update-option", {"buffer", "unint"})
	defer test_commands_free_parse(f, &p3, &spec3)
	err3, msg3 := commands_update_option(&p3, &ctx, &f.env, f.allocator)
	defer test_commands_free_msg(msg3, f.allocator)
	testing.expect_value(t, err3, Commands_Error.Error)
}

@(test)
test_commands_parse_keymap_mode :: proc(t: ^testing.T) {
	modes := []string{"normal", "insert", "menu", "prompt", "goto", "view", "user", "object", "combine"}
	expected := []Keymap_Manager_Mode{
		.Normal,
		.Insert,
		.Menu,
		.Prompt,
		.Goto,
		.View,
		.User,
		.Object,
		.Combine,
	}
	for mode, i in modes {
		parsed, err, msg := commands_parse_keymap_mode(mode, {}, context.allocator)
		testing.expect_value(t, err, Commands_Error.None)
		testing.expect_value(t, parsed, expected[i])
		_ = msg
	}
	parsed, err, msg := commands_parse_keymap_mode(
		"mymode",
		{"mymode"},
		context.allocator,
	)
	testing.expect_value(t, err, Commands_Error.None)
	testing.expect_value(t, parsed, Keymap_Manager_Mode.First_User_Mode)
	_ = msg

	_, err2, msg2 := commands_parse_keymap_mode("bogus", {}, context.allocator)
	defer test_commands_free_msg(msg2, context.allocator)
	testing.expect_value(t, err2, Commands_Error.Error)
}

@(test)
test_commands_map_unmap :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello"})
	ctx := test_commands_make_context(f, buf)
	defer context_destroy(&ctx)

	p, spec, _ := test_commands_parse(f, "map", {"buffer", "normal", "x", "l"})
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_map(&p, &ctx, &f.env, f.allocator)
	if err != .None {
		test_commands_free_msg(msg, f.allocator)
	}
	testing.expect_value(t, err, Commands_Error.None)
	key, _ := keys_parse("x", f.allocator)
	defer delete(key)
	mapping := keymap_manager_get_mapping(&buf.scope.data.keymaps, key[0], .Normal)
	testing.expect(t, mapping != nil)

	p2, spec2, _ := test_commands_parse(f, "map", {"buffer", "bogus", "x", "l"})
	defer test_commands_free_parse(f, &p2, &spec2)
	err2, msg2 := commands_map(&p2, &ctx, &f.env, f.allocator)
	defer test_commands_free_msg(msg2, f.allocator)
	testing.expect_value(t, err2, Commands_Error.Error)

	p3, spec3, _ := test_commands_parse(f, "map", {"buffer", "normal", "xy", "l"})
	defer test_commands_free_parse(f, &p3, &spec3)
	err3, msg3 := commands_map(&p3, &ctx, &f.env, f.allocator)
	defer test_commands_free_msg(msg3, f.allocator)
	testing.expect_value(t, err3, Commands_Error.Error)

	p4, spec4, _ := test_commands_parse(f, "unmap", {"buffer", "normal", "x", "j"})
	defer test_commands_free_parse(f, &p4, &spec4)
	err4, msg4 := commands_unmap(&p4, &ctx, &f.env, f.allocator)
	testing.expect_value(t, err4, Commands_Error.None)
	testing.expect_value(t, msg4, "")
	testing.expect(
		t,
		keymap_manager_get_mapping(&buf.scope.data.keymaps, key[0], .Normal) != nil,
	)

	p5, spec5, _ := test_commands_parse(f, "unmap", {"buffer", "normal", "x"})
	defer test_commands_free_parse(f, &p5, &spec5)
	err5, msg5 := commands_unmap(&p5, &ctx, &f.env, f.allocator)
	testing.expect_value(t, err5, Commands_Error.None)
	testing.expect_value(t, msg5, "")
	testing.expect(
		t,
		keymap_manager_get_mapping(&buf.scope.data.keymaps, key[0], .Normal) == nil,
	)
}

@(test)
test_commands_get_scope :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello"})
	ctx := test_commands_make_context(f, buf)
	defer context_destroy(&ctx)

	global, _, _ := commands_get_scope("global", &ctx, &f.env, f.allocator)
	testing.expect(t, global == &f.global.scope)
	abbrev, _, _ := commands_get_scope("g", &ctx, &f.env, f.allocator)
	testing.expect(t, abbrev == &f.global.scope)
	buffer_scope, _, _ := commands_get_scope("buffer", &ctx, &f.env, f.allocator)
	testing.expect(t, buffer_scope == &buf.scope)
	named, _, _ := commands_get_scope("buffer=*test*", &ctx, &f.env, f.allocator)
	testing.expect(t, named == &buf.scope)
	_, err, msg := commands_get_scope("bogus", &ctx, &f.env, f.allocator)
	defer test_commands_free_msg(msg, f.allocator)
	testing.expect_value(t, err, Commands_Error.Error)
	local := commands_scope_ifp("local", &ctx, &f.buffers, f.global)
	testing.expect(t, local == nil)
}

test_commands_debug_text :: proc(f: ^Test_Commands_Fixture) -> string {
	buf := buffer_manager_get_ifp(&f.buffers, "*debug*")
	if buf == nil {
		return ""
	}
	b := strings.builder_make(f.allocator)
	nlines := buffer_line_count(buf)
	for i in 0 ..< nlines {
		strings.write_string(&b, buffer_line(buf, Units_LineCount(i)))
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

@(test)
test_commands_echo_debug :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello"})
	ctx := test_commands_make_context(f, buf)
	defer context_destroy(&ctx)
	sc := test_commands_make_shell(f)
	defer test_commands_free_shell(f, &sc)

	p, spec, _ := test_commands_parse(f, "echo", {"-debug", "hello", "world"})
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_echo(&p, &ctx, &sc, &f.env, f.allocator)
	if err != .None {
		test_commands_free_msg(msg, f.allocator)
	}
	testing.expect_value(t, err, Commands_Error.None)
	text := test_commands_debug_text(f)
	defer delete(text, f.allocator)
	testing.expect(t, strings.contains(text, "hello world"))
}

@(test)
test_commands_echo_quoting :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello"})
	ctx := test_commands_make_context(f, buf)
	defer context_destroy(&ctx)
	sc := test_commands_make_shell(f)
	defer test_commands_free_shell(f, &sc)

	p, spec, _ := test_commands_parse(
		f,
		"echo",
		{"-quoting", "shell", "-debug", "a b", "c"},
	)
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_echo(&p, &ctx, &sc, &f.env, f.allocator)
	if err != .None {
		test_commands_free_msg(msg, f.allocator)
	}
	testing.expect_value(t, err, Commands_Error.None)
	text := test_commands_debug_text(f)
	defer delete(text, f.allocator)
	// C++ shell_quote wraps every argument (even "c").
	testing.expect(t, strings.contains(text, "'a b' 'c'"))

	p2, spec2, _ := test_commands_parse(f, "echo", {"-quoting", "bogus", "x"})
	defer test_commands_free_parse(f, &p2, &spec2)
	err2, msg2 := commands_echo(&p2, &ctx, &sc, &f.env, f.allocator)
	defer test_commands_free_msg(msg2, f.allocator)
	testing.expect_value(t, err2, Commands_Error.Error)
}

@(test)
test_commands_echo_to_file :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello"})
	ctx := test_commands_make_context(f, buf)
	defer context_destroy(&ctx)
	sc := test_commands_make_shell(f)
	defer test_commands_free_shell(f, &sc)

	dir, derr := os.temp_directory(f.allocator)
	testing.expect_value(t, derr, os.ERROR_NONE)
	defer delete(dir, f.allocator)
	target := strings.concatenate({dir, "/kak-cmd-test-echo.txt"}, f.allocator)
	defer delete(target, f.allocator)
	defer os.remove(target)

	p, spec, _ := test_commands_parse(f, "echo", {"-to-file", target, "file-content"})
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_echo(&p, &ctx, &sc, &f.env, f.allocator)
	if err != .None {
		test_commands_free_msg(msg, f.allocator)
	}
	testing.expect_value(t, err, Commands_Error.None)
	data, rok := os.read_entire_file(target, f.allocator)
	testing.expect_value(t, rok, os.ERROR_NONE)
	defer delete(data, f.allocator)
	testing.expect_value(t, string(data), "file-content")
}

@(test)
test_commands_echo_status :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello"})
	client := test_commands_make_client(f, buf, "c1")
	ctx := &client.input_handler.ctx
	sc := test_commands_make_shell(f)
	defer test_commands_free_shell(f, &sc)

	p, spec, _ := test_commands_parse(f, "echo", {"status-msg"})
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_echo(&p, ctx, &sc, &f.env, f.allocator)
	if err != .None {
		test_commands_free_msg(msg, f.allocator)
	}
	testing.expect_value(t, err, Commands_Error.None)
	testing.expect(t, len(client.status_content.atoms) == 1)
	testing.expect_value(t, client.status_content.atoms[0].text, "status-msg")
}

@(test)
test_commands_debug_subcommands :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello"})
	ctx := test_commands_make_context(f, buf)
	defer context_destroy(&ctx)

	for sub in ([?]string{
		"info",
		"buffers",
		"options",
		"memory",
		"shared-strings",
		"faces",
		"mappings",
		"registers",
	}) {
		p, spec, _ := test_commands_parse(f, "debug", {sub})
		err, msg := commands_debug(&p, &ctx, &f.env, f.allocator)
		test_commands_free_parse(f, &p, &spec)
		if err != .None {
			test_commands_free_msg(msg, f.allocator)
		}
		testing.expect(t, err == Commands_Error.None, sub)
	}
	text := test_commands_debug_text(f)
	defer delete(text, f.allocator)
	testing.expect(t, strings.contains(text, "version: "))
	testing.expect(t, strings.contains(text, "Buffers:"))
	testing.expect(t, strings.contains(text, "Options:"))
	testing.expect(t, strings.contains(text, "Memory usage:"))
	testing.expect(t, strings.contains(text, "Faces:"))
	testing.expect(t, strings.contains(text, "Mappings:"))
	testing.expect(t, strings.contains(text, "Register info:"))
}

@(test)
test_commands_debug_errors :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello"})
	ctx := test_commands_make_context(f, buf)
	defer context_destroy(&ctx)

	p, spec, _ := test_commands_parse(f, "debug", {"bogus"})
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_debug(&p, &ctx, &f.env, f.allocator)
	defer test_commands_free_msg(msg, f.allocator)
	testing.expect_value(t, err, Commands_Error.Error)

	p2, spec2, _ := test_commands_parse(f, "debug", {"regex"})
	defer test_commands_free_parse(f, &p2, &spec2)
	err2, msg2 := commands_debug(&p2, &ctx, &f.env, f.allocator)
	defer test_commands_free_msg(msg2, f.allocator)
	testing.expect_value(t, err2, Commands_Error.Error)

	p3, spec3, _ := test_commands_parse(f, "debug", {"regex", "a.*b"})
	defer test_commands_free_parse(f, &p3, &spec3)
	err3, msg3 := commands_debug(&p3, &ctx, &f.env, f.allocator)
	if err3 != .None {
		test_commands_free_msg(msg3, f.allocator)
	}
	testing.expect_value(t, err3, Commands_Error.None)
	text := test_commands_debug_text(f)
	defer delete(text, f.allocator)
	testing.expect(t, strings.contains(text, "a.*b"))
}

@(test)
test_commands_source :: proc(t: ^testing.T) {
	sync.lock(&test_commands_singleton_mutex)
	defer sync.unlock(&test_commands_singleton_mutex)
	f := test_commands_setup()
	defer test_commands_teardown(f)
	test_commands_setup_singletons(f)
	defer test_commands_teardown_singletons()
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello"})
	ctx := test_commands_make_context(f, buf)
	defer context_destroy(&ctx)
	// Pin a fixture-parented local scope so command_manager_execute
	// never falls back to the shared global singleton.
	exec_local := scope_local_make(&ctx, &buf.scope, f.allocator)
	defer scope_local_destroy(exec_local, f.allocator)

	dir, derr := os.temp_directory(f.allocator)
	testing.expect_value(t, derr, os.ERROR_NONE)
	defer delete(dir, f.allocator)
	target := strings.concatenate({dir, "/kak-cmd-test-source.kak"}, f.allocator)
	defer delete(target, f.allocator)
	defer os.remove(target)
	testing.expect_value(
		t,
		file_write_to_file(target, "define-command sourcedmarker nop\n"),
		File_Error.None,
	)

	p, spec, _ := test_commands_parse(f, "source", {target})
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_source(&p, &ctx, &f.env, f.allocator)
	if err != .None {
		test_commands_free_msg(msg, f.allocator)
	}
	testing.expect_value(t, err, Commands_Error.None)
	testing.expect(
		t,
		command_manager_command_defined(command_manager_instance(), "sourcedmarker"),
	)

	p2, spec2, _ := test_commands_parse(f, "source", {"/no/such/file-xyz"})
	defer test_commands_free_parse(f, &p2, &spec2)
	err2, msg2 := commands_source(&p2, &ctx, &f.env, f.allocator)
	defer test_commands_free_msg(msg2, f.allocator)
	testing.expect_value(t, err2, Commands_Error.Error)
}

@(test)
test_commands_execute_keys_errors :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello"})
	ctx := test_commands_make_context(f, buf)
	defer context_destroy(&ctx)
	sc := test_commands_make_shell(f)
	defer test_commands_free_shell(f, &sc)

	p, spec, _ := test_commands_parse(
		f,
		"execute-keys",
		{"-buffer", "*test*", "-client", "c1", "l"},
	)
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_execute_keys(&p, &ctx, &sc, &f.env, f.allocator)
	defer test_commands_free_msg(msg, f.allocator)
	testing.expect_value(t, err, Commands_Error.Error)

	p2, spec2, _ := test_commands_parse(f, "execute-keys", {"-client", "nobody", "l"})
	defer test_commands_free_parse(f, &p2, &spec2)
	err2, msg2 := commands_execute_keys(&p2, &ctx, &sc, &f.env, f.allocator)
	defer test_commands_free_msg(msg2, f.allocator)
	testing.expect_value(t, err2, Commands_Error.Error)

	p3, spec3, _ := test_commands_parse(f, "execute-keys", {"-buffer", "nobody", "l"})
	defer test_commands_free_parse(f, &p3, &spec3)
	err3, msg3 := commands_execute_keys(&p3, &ctx, &sc, &f.env, f.allocator)
	defer test_commands_free_msg(msg3, f.allocator)
	testing.expect_value(t, err3, Commands_Error.Error)
}

@(test)
test_commands_evaluate_commands :: proc(t: ^testing.T) {
	sync.lock(&test_commands_singleton_mutex)
	defer sync.unlock(&test_commands_singleton_mutex)
	f := test_commands_setup()
	defer test_commands_teardown(f)
	test_commands_setup_singletons(f)
	defer test_commands_teardown_singletons()
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello"})
	ctx := test_commands_make_context(f, buf)
	defer context_destroy(&ctx)
	// Pin a fixture-parented local scope so command_manager_execute
	// never falls back to the shared global singleton.
	exec_local := scope_local_make(&ctx, &buf.scope, f.allocator)
	defer scope_local_destroy(exec_local, f.allocator)
	sc := test_commands_make_shell(f)
	defer test_commands_free_shell(f, &sc)

	p, spec, _ := test_commands_parse(
		f,
		"evaluate-commands",
		{"define-command evalmarker nop"},
	)
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_evaluate_commands(&p, &ctx, &sc, &f.env, f.allocator)
	if err != .None {
		test_commands_free_msg(msg, f.allocator)
	}
	testing.expect_value(t, err, Commands_Error.None)
	testing.expect(
		t,
		command_manager_command_defined(command_manager_instance(), "evalmarker"),
	)

	p2, spec2, _ := test_commands_parse(
		f,
		"evaluate-commands",
		{"-verbatim", "nop"},
	)
	defer test_commands_free_parse(f, &p2, &spec2)
	err2, msg2 := commands_evaluate_commands(&p2, &ctx, &sc, &f.env, f.allocator)
	if err2 != .None {
		test_commands_free_msg(msg2, f.allocator)
	}
	testing.expect_value(t, err2, Commands_Error.None)

	p3, spec3, _ := test_commands_parse(
		f,
		"evaluate-commands",
		{"-verbatim", "no-such-command-xyz"},
	)
	defer test_commands_free_parse(f, &p3, &spec3)
	err3, msg3 := commands_evaluate_commands(&p3, &ctx, &sc, &f.env, f.allocator)
	defer test_commands_free_msg(msg3, f.allocator)
	testing.expect_value(t, err3, Commands_Error.Error)
}

@(test)
test_commands_evaluate_draft_itersel :: proc(t: ^testing.T) {
	sync.lock(&test_commands_singleton_mutex)
	defer sync.unlock(&test_commands_singleton_mutex)
	f := test_commands_setup()
	defer test_commands_teardown(f)
	test_commands_setup_singletons(f)
	defer test_commands_teardown_singletons()
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello", "world"})
	ctx := test_commands_make_context(f, buf)
	defer context_destroy(&ctx)
	// Pin a fixture-parented local scope so command_manager_execute
	// never falls back to the shared global singleton.
	exec_local := scope_local_make(&ctx, &buf.scope, f.allocator)
	defer scope_local_destroy(exec_local, f.allocator)
	sc := test_commands_make_shell(f)
	defer test_commands_free_shell(f, &sc)

	p, spec, _ := test_commands_parse(f, "evaluate-commands", {"-draft", "nop"})
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_evaluate_commands(&p, &ctx, &sc, &f.env, f.allocator)
	if err != .None {
		test_commands_free_msg(msg, f.allocator)
	}
	testing.expect_value(t, err, Commands_Error.None)

	p2, spec2, _ := test_commands_parse(
		f,
		"evaluate-commands",
		{"-itersel", "-draft", "nop"},
	)
	defer test_commands_free_parse(f, &p2, &spec2)
	err2, msg2 := commands_evaluate_commands(&p2, &ctx, &sc, &f.env, f.allocator)
	if err2 != .None {
		test_commands_free_msg(msg2, f.allocator)
	}
	testing.expect_value(t, err2, Commands_Error.None)

	p3, spec3, _ := test_commands_parse(
		f,
		"evaluate-commands",
		{"-buffer", "*test*", "nop"},
	)
	defer test_commands_free_parse(f, &p3, &spec3)
	err3, msg3 := commands_evaluate_commands(&p3, &ctx, &sc, &f.env, f.allocator)
	if err3 != .None {
		test_commands_free_msg(msg3, f.allocator)
	}
	testing.expect_value(t, err3, Commands_Error.None)
}

@(test)
test_commands_itersel_fail_propagates :: proc(t: ^testing.T) {
	sync.lock(&test_commands_singleton_mutex)
	defer sync.unlock(&test_commands_singleton_mutex)
	f := test_commands_setup()
	defer test_commands_teardown(f)
	test_commands_setup_singletons(f)
	defer test_commands_teardown_singletons()
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello", "world"})
	ctx := test_commands_make_context(f, buf)
	defer context_destroy(&ctx)
	exec_local := scope_local_make(&ctx, &buf.scope, f.allocator)
	defer scope_local_destroy(exec_local, f.allocator)
	sc := test_commands_make_shell(f)
	defer test_commands_free_shell(f, &sc)

	// Non-no-selections failures propagate out of -itersel (only
	// No_Selections_Remaining is swallowed per selection).
	p, spec, _ := test_commands_parse(f, "evaluate-commands", {"-itersel", "fail x"})
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_evaluate_commands(&p, &ctx, &sc, &f.env, f.allocator)
	if err != .None {
		test_commands_free_msg(msg, f.allocator)
	}
	testing.expect_value(t, err, Commands_Error.Fail)
}

@(test)
test_commands_prompt_push :: proc(t: ^testing.T) {
	// The only commands test needing the register-manager singleton
	// (input_handler_prompt_make dereferences it). Deschedule with no
	// locks held, then hold the singleton across the body.
	test_commands_deschedule_for_register()
	sync.lock(&test_commands_singleton_mutex)
	defer sync.unlock(&test_commands_singleton_mutex)
	f := test_commands_setup()
	defer test_commands_teardown(f)
	test_commands_setup_singletons(f)
	defer test_commands_teardown_singletons()
	if !test_commands_register_hold() {
		testing.expect(t, false, "register manager stayed busy")
		return
	}
	defer test_commands_register_release()
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello"})
	client := test_commands_make_client(f, buf, "c1")
	ctx := &client.input_handler.ctx
	sc := test_commands_make_shell(f)
	defer test_commands_free_shell(f, &sc)

	before := len(client.input_handler.mode_stack)
	p, spec, _ := test_commands_parse(f, "prompt", {"ask:", "nop"})
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_prompt(&p, ctx, &sc, f.allocator)
	if err != .None {
		test_commands_free_msg(msg, f.allocator)
	}
	testing.expect_value(t, err, Commands_Error.None)
	testing.expect(t, len(client.input_handler.mode_stack) == before + 1)
}

@(test)
test_commands_prompt_bad_completer :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello"})
	client := test_commands_make_client(f, buf, "c1")
	ctx := &client.input_handler.ctx
	sc := test_commands_make_shell(f)
	defer test_commands_free_shell(f, &sc)

	p, spec, perr := test_commands_parse(
		f,
		"prompt",
		{"-shell-script-completion", "", "ask:", "nop"},
	)
	defer test_commands_free_parse(f, &p, &spec)
	testing.expect_value(t, perr, Parameters_Parser_Error.None)
	err, msg := commands_prompt(&p, ctx, &sc, f.allocator)
	defer test_commands_free_msg(msg, f.allocator)
	testing.expect_value(t, err, Commands_Error.Error)
}

@(test)
test_commands_prompt_callback :: proc(t: ^testing.T) {
	sync.lock(&test_commands_singleton_mutex)
	defer sync.unlock(&test_commands_singleton_mutex)
	f := test_commands_setup()
	defer test_commands_teardown(f)
	test_commands_setup_singletons(f)
	defer test_commands_teardown_singletons()
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello"})
	ctx := test_commands_make_context(f, buf)
	defer context_destroy(&ctx)
	// Pin a fixture-parented local scope so command_manager_execute
	// never falls back to the shared global singleton.
	exec_local := scope_local_make(&ctx, &buf.scope, f.allocator)
	defer scope_local_destroy(exec_local, f.allocator)

	stored := new(Commands_Prompt_Callback, f.allocator)
	stored^ = Commands_Prompt_Callback{
		command   = strings.clone("define-command promptmarker nop", f.allocator),
		on_change = strings.clone("", f.allocator),
		on_abort  = strings.clone("define-command abortmarker nop", f.allocator),
		params    = make([dynamic]string, 0, f.allocator),
		env_vars  = make(Env_Var_Map, 0, f.allocator),
		allocator = f.allocator,
	}
	commands_prompt_callback_call(stored, "typed", .Validate, &ctx)
	testing.expect(
		t,
		command_manager_command_defined(command_manager_instance(), "promptmarker"),
	)
	commands_prompt_callback_call(stored, "", .Change, &ctx)
	commands_prompt_callback_call(stored, "", .Abort, &ctx)
	testing.expect(
		t,
		command_manager_command_defined(command_manager_instance(), "abortmarker"),
	)
	commands_prompt_callback_destroy(stored, f.allocator)
}

@(test)
test_commands_on_key :: proc(t: ^testing.T) {
	sync.lock(&test_commands_singleton_mutex)
	defer sync.unlock(&test_commands_singleton_mutex)
	f := test_commands_setup()
	defer test_commands_teardown(f)
	test_commands_setup_singletons(f)
	defer test_commands_teardown_singletons()
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello"})
	client := test_commands_make_client(f, buf, "c1")
	ctx := &client.input_handler.ctx
	// Pin a fixture-parented local scope so command_manager_execute
	// never falls back to the shared global singleton.
	exec_local := scope_local_make(ctx, &buf.scope, f.allocator)
	defer scope_local_destroy(exec_local, f.allocator)
	sc := test_commands_make_shell(f)
	defer test_commands_free_shell(f, &sc)

	before := len(client.input_handler.mode_stack)
	p, spec, _ := test_commands_parse(f, "on-key", {"nop"})
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_on_key(&p, ctx, &sc, f.allocator)
	if err != .None {
		test_commands_free_msg(msg, f.allocator)
	}
	testing.expect_value(t, err, Commands_Error.None)
	testing.expect(t, len(client.input_handler.mode_stack) == before + 1)

	stored := new(Commands_On_Key_Callback, f.allocator)
	stored^ = Commands_On_Key_Callback{
		command   = strings.clone("define-command keymarker nop", f.allocator),
		params    = make([dynamic]string, 0, f.allocator),
		env_vars  = make(Env_Var_Map, 0, f.allocator),
		allocator = f.allocator,
	}
	keys, _ := keys_parse("a", f.allocator)
	defer delete(keys)
	commands_on_key_callback_call(stored, keys[0], ctx)
	testing.expect(
		t,
		command_manager_command_defined(command_manager_instance(), "keymarker"),
	)
	testing.expect(t, stored.env_vars["key"] == "a")
	commands_on_key_callback_destroy(stored, f.allocator)
}

@(test)
test_commands_info :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello"})
	ctx := test_commands_make_context(f, buf)
	defer context_destroy(&ctx)

	p, spec, _ := test_commands_parse(f, "info", {"hello"})
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_info(&p, &ctx, f.allocator)
	testing.expect_value(t, err, Commands_Error.None)
	testing.expect_value(t, msg, "")

	client := test_commands_make_client(f, buf, "c1")
	cctx := &client.input_handler.ctx
	p2, spec2, _ := test_commands_parse(f, "info", {"-style", "bogus", "x"})
	defer test_commands_free_parse(f, &p2, &spec2)
	err2, msg2 := commands_info(&p2, cctx, f.allocator)
	defer test_commands_free_msg(msg2, f.allocator)
	testing.expect_value(t, err2, Commands_Error.Error)

	p3, spec3, _ := test_commands_parse(f, "info", {"-anchor", "bogus", "x"})
	defer test_commands_free_parse(f, &p3, &spec3)
	err3, msg3 := commands_info(&p3, cctx, f.allocator)
	defer test_commands_free_msg(msg3, f.allocator)
	testing.expect_value(t, err3, Commands_Error.Error)

	p4, spec4, _ := test_commands_parse(
		f,
		"info",
		{"-anchor", "1.1", "-title", "t", "body"},
	)
	defer test_commands_free_parse(f, &p4, &spec4)
	err4, msg4 := commands_info(&p4, cctx, f.allocator)
	if err4 != .None {
		test_commands_free_msg(msg4, f.allocator)
	}
	testing.expect_value(t, err4, Commands_Error.None)
}

@(test)
test_commands_faces :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello"})
	ctx := test_commands_make_context(f, buf)
	defer context_destroy(&ctx)

	p, spec, _ := test_commands_parse(f, "set-face", {"buffer", "MyFace", "red,blue"})
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_set_face(&p, &ctx, &f.env, f.allocator)
	if err != .None {
		test_commands_free_msg(msg, f.allocator)
	}
	testing.expect_value(t, err, Commands_Error.None)
	// The resolving lookup never fails; check the map directly.
	_, found := buf.scope.data.faces.faces["MyFace"]
	testing.expect(t, found)

	p2, spec2, _ := test_commands_parse(f, "set-face", {"buffer", "Bad Face!", "red"})
	defer test_commands_free_parse(f, &p2, &spec2)
	err2, msg2 := commands_set_face(&p2, &ctx, &f.env, f.allocator)
	defer test_commands_free_msg(msg2, f.allocator)
	testing.expect_value(t, err2, Commands_Error.Error)

	p3, spec3, _ := test_commands_parse(f, "unset-face", {"buffer", "MyFace"})
	defer test_commands_free_parse(f, &p3, &spec3)
	err3, msg3 := commands_unset_face(&p3, &ctx, &f.env, f.allocator)
	testing.expect_value(t, err3, Commands_Error.None)
	testing.expect_value(t, msg3, "")
	_, found3 := buf.scope.data.faces.faces["MyFace"]
	testing.expect(t, !found3)
}

@(test)
test_commands_rename_client :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello"})
	c1 := test_commands_make_client(f, buf, "c1")
	_ = test_commands_make_client(f, buf, "c2")
	ctx := &c1.input_handler.ctx

	p, spec, _ := test_commands_parse(f, "rename-client", {"bad name!"})
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_rename_client(&p, ctx, &f.env, f.allocator)
	defer test_commands_free_msg(msg, f.allocator)
	testing.expect_value(t, err, Commands_Error.Error)

	p2, spec2, _ := test_commands_parse(f, "rename-client", {"c2"})
	defer test_commands_free_parse(f, &p2, &spec2)
	err2, msg2 := commands_rename_client(&p2, ctx, &f.env, f.allocator)
	defer test_commands_free_msg(msg2, f.allocator)
	testing.expect_value(t, err2, Commands_Error.Error)

	p3, spec3, _ := test_commands_parse(f, "rename-client", {"c3"})
	defer test_commands_free_parse(f, &p3, &spec3)
	err3, msg3 := commands_rename_client(&p3, ctx, &f.env, f.allocator)
	if err3 != .None {
		test_commands_free_msg(msg3, f.allocator)
	}
	testing.expect_value(t, err3, Commands_Error.None)
	testing.expect_value(t, context_name(ctx), "c3")
}

@(test)
test_commands_set_register :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello"})
	ctx := test_commands_make_context(f, buf)
	defer context_destroy(&ctx)
	register_manager_add(
		&f.registers,
		'a',
		register_manager_make_static("a", f.allocator),
	)

	p, spec, _ := test_commands_parse(f, "set-register", {"a", "one", "two"})
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_set_register(&p, &ctx, &f.env, f.allocator)
	testing.expect_value(t, err, Commands_Error.None)
	testing.expect_value(t, msg, "")
	reg, _ := register_manager_get(&f.registers, 'a')
	values := register_manager_get_values(reg, &ctx, f.allocator)
	testing.expect_value(t, len(values), 2)
	testing.expect_value(t, values[0], "one")

	p2, spec2, _ := test_commands_parse(f, "set-register", {"z", "x"})
	defer test_commands_free_parse(f, &p2, &spec2)
	err2, msg2 := commands_set_register(&p2, &ctx, &f.env, f.allocator)
	defer test_commands_free_msg(msg2, f.allocator)
	testing.expect_value(t, err2, Commands_Error.Error)
}

@(test)
test_commands_select :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello", "world"})
	ctx := test_commands_make_context(f, buf)
	defer context_destroy(&ctx)

	p, spec, _ := test_commands_parse(f, "select", {"1.1,1.3", "2.2,2.4"})
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_select(&p, &ctx, f.allocator)
	if err != .None {
		test_commands_free_msg(msg, f.allocator)
	}
	testing.expect_value(t, err, Commands_Error.None)
	sels := context_selections_write_only(&ctx)
	testing.expect_value(t, len(sels.selections), 2)

	p2, spec2, _ := test_commands_parse(f, "select", {"bogus"})
	defer test_commands_free_parse(f, &p2, &spec2)
	err2, msg2 := commands_select(&p2, &ctx, f.allocator)
	defer test_commands_free_msg(msg2, f.allocator)
	testing.expect_value(t, err2, Commands_Error.Error)

	p3, spec3, _ := test_commands_parse(f, "select", {"99.1,99.2"})
	defer test_commands_free_parse(f, &p3, &spec3)
	err3, msg3 := commands_select(&p3, &ctx, f.allocator)
	defer test_commands_free_msg(msg3, f.allocator)
	// C++ selection_list_from_strings clamps out-of-range coords
	// instead of erroring (only malformed descs fail).
	testing.expect_value(t, err3, Commands_Error.None)
}

@(test)
test_commands_change_directory :: proc(t: ^testing.T) {
	// NOTE: only the error path is tested; a successful chdir would
	// change process-global state while other tests run in parallel.
	f := test_commands_setup()
	defer test_commands_teardown(f)
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello"})
	ctx := test_commands_make_context(f, buf)
	defer context_destroy(&ctx)

	p2, spec2, _ := test_commands_parse(f, "change-directory", {"/no/such/dir-xyz"})
	defer test_commands_free_parse(f, &p2, &spec2)
	err2, msg2 := commands_change_directory(&p2, &ctx, &f.env, f.allocator)
	defer test_commands_free_msg(msg2, f.allocator)
	testing.expect_value(t, err2, Commands_Error.Error)
}

@(test)
test_commands_rename_session_missing :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello"})
	ctx := test_commands_make_context(f, buf)
	defer context_destroy(&ctx)
	f.server.session = "kak-test-missing-session-xyz"

	p, spec, _ := test_commands_parse(f, "rename-session", {"other"})
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_rename_session(&p, &ctx, &f.env, f.allocator)
	defer test_commands_free_msg(msg, f.allocator)
	testing.expect_value(t, err, Commands_Error.Error)
}

@(test)
test_commands_declare_user_mode :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello"})
	ctx := test_commands_make_context(f, buf)
	defer context_destroy(&ctx)

	p, spec, _ := test_commands_parse(f, "declare-user-mode", {"mymode"})
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_declare_user_mode(&p, &ctx, f.allocator)
	if err != .None {
		test_commands_free_msg(msg, f.allocator)
	}
	testing.expect_value(t, err, Commands_Error.None)
	testing.expect_value(t, len(keymap_manager_user_modes(&buf.scope.data.keymaps)^), 1)

	p2, spec2, _ := test_commands_parse(f, "declare-user-mode", {"normal"})
	defer test_commands_free_parse(f, &p2, &spec2)
	err2, msg2 := commands_declare_user_mode(&p2, &ctx, f.allocator)
	defer test_commands_free_msg(msg2, f.allocator)
	testing.expect_value(t, err2, Commands_Error.Error)

	p3, spec3, _ := test_commands_parse(f, "declare-user-mode", {"mymode"})
	defer test_commands_free_parse(f, &p3, &spec3)
	err3, msg3 := commands_declare_user_mode(&p3, &ctx, f.allocator)
	defer test_commands_free_msg(msg3, f.allocator)
	testing.expect_value(t, err3, Commands_Error.Error)
}

@(test)
test_commands_enter_user_mode :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello"})
	client := test_commands_make_client(f, buf, "c1")
	ctx := &client.input_handler.ctx

	pd, specd, _ := test_commands_parse(f, "declare-user-mode", {"mymode"})
	defer test_commands_free_parse(f, &pd, &specd)
	_, _ = commands_declare_user_mode(&pd, ctx, f.allocator)

	before := len(client.input_handler.mode_stack)
	p, spec, _ := test_commands_parse(f, "enter-user-mode", {"mymode"})
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_enter_user_mode(&p, ctx, f.allocator)
	if err != .None {
		test_commands_free_msg(msg, f.allocator)
	}
	testing.expect_value(t, err, Commands_Error.None)
	testing.expect(t, len(client.input_handler.mode_stack) == before + 1)

	p2, spec2, _ := test_commands_parse(f, "enter-user-mode", {"bogus"})
	defer test_commands_free_parse(f, &p2, &spec2)
	err2, msg2 := commands_enter_user_mode(&p2, ctx, f.allocator)
	defer test_commands_free_msg(msg2, f.allocator)
	testing.expect_value(t, err2, Commands_Error.Error)
}

@(test)
test_commands_user_mode_call :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello"})
	client := test_commands_make_client(f, buf, "c1")
	ctx := &client.input_handler.ctx

	stored := new(Commands_User_Mode, f.allocator)
	stored^ = Commands_User_Mode{
		mode_name = strings.clone("mymode", f.allocator),
		mode      = .Normal,
		allocator = f.allocator,
	}
	esc, _ := keys_parse("<esc>", f.allocator)
	defer delete(esc)
	commands_user_mode_call(stored, esc[0], ctx)
	plain, _ := keys_parse("z", f.allocator)
	defer delete(plain)
	commands_user_mode_call(stored, plain[0], ctx)
	commands_user_mode_destroy(stored, f.allocator)
	testing.expect(t, true)
}

test_commands_candidates_contain :: proc(comps: ^Completions, want: string) -> bool {
	for c in comps.candidates {
		if c == want {
			return true
		}
	}
	return false
}

@(test)
test_commands_static_completers :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello"})
	ctx := test_commands_make_context(f, buf)
	defer context_destroy(&ctx)

	comps := commands_complete_scope_call(nil, &ctx, {""}, 0, 0, f.allocator)
	defer command_manager_free_completions(&comps, f.allocator)
	testing.expect(t, test_commands_candidates_contain(&comps, "global"))
	testing.expect(t, .Menu in comps.flags)

	comps2 := commands_complete_hooks_call(nil, &ctx, {"U"}, 0, 1, f.allocator)
	defer command_manager_free_completions(&comps2, f.allocator)
	testing.expect(t, test_commands_candidates_contain(&comps2, "User"))

	comps3 := commands_complete_debug_call(nil, &ctx, {"in"}, 0, 2, f.allocator)
	defer command_manager_free_completions(&comps3, f.allocator)
	testing.expect(t, test_commands_candidates_contain(&comps3, "info"))

	comps4 := commands_complete_option_type_call(nil, &ctx, {"in"}, 0, 2, f.allocator)
	defer command_manager_free_completions(&comps4, f.allocator)
	testing.expect(t, test_commands_candidates_contain(&comps4, "int"))

	comps5 := commands_complete_completer_type_call(nil, &ctx, {"fi"}, 0, 2, f.allocator)
	defer command_manager_free_completions(&comps5, f.allocator)
	testing.expect(t, test_commands_candidates_contain(&comps5, "file"))

	comps6 := commands_complete_nothing_call(nil, &ctx, {"x"}, 0, 1, f.allocator)
	defer command_manager_free_completions(&comps6, f.allocator)
	testing.expect_value(t, len(comps6.candidates), 0)

	comps7 := commands_complete_client_name_call(nil, &ctx, {""}, 0, 0, f.allocator)
	defer command_manager_free_completions(&comps7, f.allocator)
	testing.expect(t, test_commands_candidates_contain(&comps7, "test"))
}

@(test)
test_commands_command_name_completion :: proc(t: ^testing.T) {
	sync.lock(&test_commands_singleton_mutex)
	defer sync.unlock(&test_commands_singleton_mutex)
	f := test_commands_setup()
	defer test_commands_teardown(f)
	test_commands_setup_singletons(f)
	defer test_commands_teardown_singletons()
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello"})
	ctx := test_commands_make_context(f, buf)
	defer context_destroy(&ctx)

	comps := commands_complete_nested_call(
		nil,
		&ctx,
		{"edi"},
		0,
		3,
		f.allocator,
	)
	defer command_manager_free_completions(&comps, f.allocator)
	testing.expect(t, test_commands_candidates_contain(&comps, "edit"))

	comps2 := commands_complete_nested_call(
		nil,
		&ctx,
		{"nosuchcmd", "x"},
		1,
		1,
		f.allocator,
	)
	defer command_manager_free_completions(&comps2, f.allocator)
	testing.expect_value(t, len(comps2.candidates), 0)
}

@(test)
test_commands_buffer_name_completion :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	a := test_commands_make_buffer(f, "alpha", {}, {"a"})
	_ = test_commands_make_buffer(f, "beta", {}, {"b"})
	ctx := test_commands_make_context(f, a)
	defer context_destroy(&ctx)

	comps := commands_complete_buffer_names(&ctx, &f.env, "", 0, false, f.allocator)
	defer command_manager_free_completions(&comps, f.allocator)
	testing.expect(t, test_commands_candidates_contain(&comps, "alpha"))
	testing.expect(t, test_commands_candidates_contain(&comps, "beta"))

	comps2 := commands_complete_buffer_names(&ctx, &f.env, "", 0, true, f.allocator)
	defer command_manager_free_completions(&comps2, f.allocator)
	testing.expect(t, !test_commands_candidates_contain(&comps2, "alpha"))
	testing.expect(t, test_commands_candidates_contain(&comps2, "beta"))
}

@(test)
test_commands_filename_completion :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello"})
	ctx := test_commands_make_context(f, buf)
	defer context_destroy(&ctx)

	dir, derr := os.temp_directory(f.allocator)
	testing.expect_value(t, derr, os.ERROR_NONE)
	defer delete(dir, f.allocator)
	target := strings.concatenate({dir, "/kak-cmd-test-compl.txt"}, f.allocator)
	defer delete(target, f.allocator)
	defer os.remove(target)
	testing.expect_value(t, file_write_to_file(target, "x"), File_Error.None)

	prefix := strings.concatenate({dir, "/kak-cmd-test-"}, f.allocator)
	defer delete(prefix, f.allocator)
	comps := commands_complete_filename_menu_call(
		nil,
		&ctx,
		{prefix},
		0,
		Units_ByteCount(len(prefix)),
		f.allocator,
	)
	defer command_manager_free_completions(&comps, f.allocator)
	testing.expect(t, .Menu in comps.flags)
	testing.expect(t, test_commands_candidates_contain(&comps, target))
}

@(test)
test_commands_option_face_alias_completion :: proc(t: ^testing.T) {
	sync.lock(&test_commands_singleton_mutex)
	defer sync.unlock(&test_commands_singleton_mutex)
	f := test_commands_setup()
	defer test_commands_teardown(f)
	test_commands_setup_singletons(f)
	defer test_commands_teardown_singletons()
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello"})
	ctx := test_commands_make_context(f, buf)
	defer context_destroy(&ctx)

	comps := commands_complete_option_name_call(
		nil,
		&ctx,
		{"global", "tabst"},
		1,
		5,
		f.allocator,
	)
	defer command_manager_free_completions(&comps, f.allocator)
	testing.expect(t, test_commands_candidates_contain(&comps, "tabstop"))

	comps2 := commands_complete_face_call(nil, &ctx, {"StatusL"}, 0, 7, f.allocator)
	defer command_manager_free_completions(&comps2, f.allocator)
	testing.expect(t, len(comps2.candidates) > 0)

	_ = alias_registry_add(&buf.scope.data.aliases, "myalias", "nop")
	comps3 := commands_complete_alias_call(nil, &ctx, {"myal"}, 0, 4, f.allocator)
	defer command_manager_free_completions(&comps3, f.allocator)
	testing.expect(t, test_commands_candidates_contain(&comps3, "myalias"))

	comps4 := commands_complete_option_value_call(
		nil,
		&ctx,
		{"global", "tabstop", ""},
		2,
		0,
		f.allocator,
	)
	defer command_manager_free_completions(&comps4, f.allocator)
	testing.expect(t, test_commands_candidates_contain(&comps4, "8"))
	testing.expect(t, .Quoted in comps4.flags)
}

@(test)
test_commands_dispatch_completers :: proc(t: ^testing.T) {
	sync.lock(&test_commands_singleton_mutex)
	defer sync.unlock(&test_commands_singleton_mutex)
	f := test_commands_setup()
	defer test_commands_teardown(f)
	test_commands_setup_singletons(f)
	defer test_commands_teardown_singletons()
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello"})
	ctx := test_commands_make_context(f, buf)
	defer context_destroy(&ctx)

	comps := commands_complete_hook_call(nil, &ctx, {"g"}, 0, 1, f.allocator)
	defer command_manager_free_completions(&comps, f.allocator)
	testing.expect(t, test_commands_candidates_contain(&comps, "global"))

	comps2 := commands_complete_hook_call(
		nil,
		&ctx,
		{"global", "U"},
		1,
		1,
		f.allocator,
	)
	defer command_manager_free_completions(&comps2, f.allocator)
	testing.expect(t, test_commands_candidates_contain(&comps2, "User"))

	comps3 := commands_complete_hook_call(
		nil,
		&ctx,
		{"global", "User", "x"},
		2,
		1,
		f.allocator,
	)
	defer command_manager_free_completions(&comps3, f.allocator)
	testing.expect_value(t, len(comps3.candidates), 0)

	comps4 := commands_complete_set_option_call(
		nil,
		&ctx,
		{"cur"},
		0,
		3,
		f.allocator,
	)
	defer command_manager_free_completions(&comps4, f.allocator)
	testing.expect(t, test_commands_candidates_contain(&comps4, "current"))

	comps5 := commands_complete_option_scope_call(
		nil,
		&ctx,
		{"g"},
		0,
		1,
		f.allocator,
	)
	defer command_manager_free_completions(&comps5, f.allocator)
	testing.expect(t, !test_commands_candidates_contain(&comps5, "global"))

	comps6 := commands_complete_alias_args_call(nil, &ctx, {"b"}, 0, 1, f.allocator)
	defer command_manager_free_completions(&comps6, f.allocator)
	testing.expect(t, test_commands_candidates_contain(&comps6, "buffer"))

	comps7 := commands_complete_complete_command_call(
		nil,
		&ctx,
		{"nop", "fi"},
		1,
		2,
		f.allocator,
	)
	defer command_manager_free_completions(&comps7, f.allocator)
	testing.expect(t, test_commands_candidates_contain(&comps7, "file"))

	comps8 := commands_complete_add_highlighter_call(
		nil,
		&ctx,
		{"glo"},
		0,
		3,
		f.allocator,
	)
	defer command_manager_free_completions(&comps8, f.allocator)
	testing.expect(t, test_commands_candidates_contain(&comps8, "global/"))
}

@(test)
test_commands_user_mode_completion :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello"})
	ctx := test_commands_make_context(f, buf)
	defer context_destroy(&ctx)

	pd, specd, _ := test_commands_parse(f, "declare-user-mode", {"compmode"})
	defer test_commands_free_parse(f, &pd, &specd)
	_, _ = commands_declare_user_mode(&pd, &ctx, f.allocator)

	comps := commands_complete_user_mode_call(nil, &ctx, {"comp"}, 0, 4, f.allocator)
	defer command_manager_free_completions(&comps, f.allocator)
	testing.expect(t, test_commands_candidates_contain(&comps, "compmode"))
}

@(test)
test_commands_make_completer :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)

	comp, err, msg := commands_make_completer("file", "", {}, f.allocator)
	testing.expect_value(t, err, Commands_Error.None)
	testing.expect(t, comp.call != nil)
	if comp.destroy != nil {
		comp.destroy(comp.data, f.allocator)
	}
	_ = msg

	comp2, err2, msg2 := commands_make_completer("command", "", {}, f.allocator)
	testing.expect_value(t, err2, Commands_Error.None)
	testing.expect(t, comp2.call == commands_complete_nested_call)
	_ = msg2

	_, err3, msg3 := commands_make_completer("bogus", "", {}, f.allocator)
	defer test_commands_free_msg(msg3, f.allocator)
	testing.expect_value(t, err3, Commands_Error.Error)

	_, err4, msg4 := commands_make_completer("shell-script", "", {}, f.allocator)
	defer test_commands_free_msg(msg4, f.allocator)
	testing.expect_value(t, err4, Commands_Error.Error)

	p, spec, _ := test_commands_parse(
		f,
		"define-command",
		{"-file-completion", "ccmd", "nop"},
	)
	defer test_commands_free_parse(f, &p, &spec)
	parsed, perr, pmsg := commands_parse_completion_switch(&p, {}, f.allocator)
	if perr != .None {
		test_commands_free_msg(pmsg, f.allocator)
	}
	testing.expect_value(t, perr, Commands_Error.None)
	testing.expect(t, parsed.call != nil)
	if parsed.destroy != nil {
		parsed.destroy(parsed.data, f.allocator)
	}
}

@(test)
test_commands_doc_helpers :: proc(t: ^testing.T) {
	sync.lock(&test_commands_singleton_mutex)
	defer sync.unlock(&test_commands_singleton_mutex)
	f := test_commands_setup()
	defer test_commands_teardown(f)
	test_commands_setup_singletons(f)
	defer test_commands_teardown_singletons()
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello"})
	ctx := test_commands_make_context(f, buf)
	defer context_destroy(&ctx)

	// NOTE: the option doc helper reads the shared global
	// singleton through production default_env, which these tests
	// never install (it may be backed by another test's rolled-back
	// allocator); only the arity guard below is covered here.
	doc2 := commands_option_doc_helper_call(nil, &ctx, {"global"}, f.allocator)
	defer delete(doc2, f.allocator)
	testing.expect_value(t, doc2, "")

	face_doc := commands_face_doc_helper_call(
		nil,
		&ctx,
		{"buffer", "StatusLine"},
		f.allocator,
	)
	defer delete(face_doc, f.allocator)
	testing.expect(t, strings.contains(face_doc, "StatusLine"))

	face_missing := commands_face_doc_helper_call(
		nil,
		&ctx,
		{"buffer", "NoSuchFace"},
		f.allocator,
	)
	defer delete(face_missing, f.allocator)
	testing.expect_value(t, face_missing, "")

	hl_missing := commands_addhl_doc_helper_call(
		nil,
		&ctx,
		{"global/", "nosuchtype"},
		f.allocator,
	)
	defer delete(hl_missing, f.allocator)
	testing.expect_value(t, hl_missing, "")
}

@(test)
test_commands_parse_write_method :: proc(t: ^testing.T) {
	method, err, msg := commands_parse_write_method("overwrite", context.allocator)
	testing.expect_value(t, err, Commands_Error.None)
	testing.expect_value(t, method, File_Write_Method.Overwrite)
	_ = msg

	method, err, msg = commands_parse_write_method("replace", context.allocator)
	testing.expect_value(t, err, Commands_Error.None)
	testing.expect_value(t, method, File_Write_Method.Replace)
	_ = msg

	_, err, msg = commands_parse_write_method("bogus", context.allocator)
	defer test_commands_free_msg(msg, context.allocator)
	testing.expect_value(t, err, Commands_Error.Error)
}

@(test)
test_commands_generate_buffer_name :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	_ = test_commands_make_buffer(f, "*scratch-0*", {}, {"a"})

	name := commands_generate_buffer_name("*scratch-{}*", &f.buffers, f.allocator)
	defer delete(name, f.allocator)
	testing.expect_value(t, name, "*scratch-1*")
}

@(test)
test_commands_reg_saver :: proc(t: ^testing.T) {
	f := test_commands_setup()
	defer test_commands_teardown(f)
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello"})
	ctx := test_commands_make_context(f, buf)
	defer context_destroy(&ctx)
	register_manager_add(
		&f.registers,
		'a',
		register_manager_make_static("a", f.allocator),
	)
	reg, _ := register_manager_get(&f.registers, 'a')
	register_manager_set(reg, &ctx, {"orig"})

	saver, err, msg := commands_reg_saver_make("a", &ctx, &f.env, f.allocator)
	if err != .None {
		test_commands_free_msg(msg, f.allocator)
	}
	testing.expect_value(t, err, Commands_Error.None)
	register_manager_set(reg, &ctx, {"changed"})
	commands_reg_saver_restore(&saver, &ctx)
	commands_reg_saver_destroy(&saver)
	values := register_manager_get_values(reg, &ctx, f.allocator)
	testing.expect_value(t, values[0], "orig")

	_, err2, msg2 := commands_reg_saver_make("?", &ctx, &f.env, f.allocator)
	defer test_commands_free_msg(msg2, f.allocator)
	testing.expect_value(t, err2, Commands_Error.Error)
}

@(test)
test_commands_context_wrap_save_regs :: proc(t: ^testing.T) {
	sync.lock(&test_commands_singleton_mutex)
	defer sync.unlock(&test_commands_singleton_mutex)
	f := test_commands_setup()
	defer test_commands_teardown(f)
	test_commands_setup_singletons(f)
	defer test_commands_teardown_singletons()
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello"})
	ctx := test_commands_make_context(f, buf)
	defer context_destroy(&ctx)
	// Pin a fixture-parented local scope so command_manager_execute
	// never falls back to the shared global singleton.
	exec_local := scope_local_make(&ctx, &buf.scope, f.allocator)
	defer scope_local_destroy(exec_local, f.allocator)
	sc := test_commands_make_shell(f)
	defer test_commands_free_shell(f, &sc)

	p, spec, _ := test_commands_parse(
		f,
		"evaluate-commands",
		{"-save-regs", "?", "nop"},
	)
	defer test_commands_free_parse(f, &p, &spec)
	err, msg := commands_evaluate_commands(&p, &ctx, &sc, &f.env, f.allocator)
	defer test_commands_free_msg(msg, f.allocator)
	testing.expect_value(t, err, Commands_Error.Error)
}

@(test)
test_commands_profile_hash_maps :: proc(t: ^testing.T) {
	// One small profiling pass through the claimed buffer-manager
	// singleton (see buffer_utils_test_claim_singletons): the full
	// profile_hash_maps loop runs 10M keys and is too slow for the
	// suite. The pass must not trap and must append its timing line
	// to the *debug* buffer.
	if !buffer_utils_test_claim_singletons() {
		return
	}
	tracked: ^Buffer = nil
	defer {
		buffer_utils_test_release_manager("*debug*", tracked)
	}
	buffer_manager_instance_init()
	profile_hash_maps_do(100, context.allocator)
	if !buffer_utils_test_manager_live() {
		return
	}
	tracked = buffer_manager_get_ifp(&Buffer_Manager_Instance, "*debug*")
	testing.expect(t, tracked != nil)
	if tracked == nil {
		return
	}
	testing.expect_value(t, buffer_line_count(tracked), 2)
	first := buffer_line(tracked, 0)
	testing.expect(t, strings.has_prefix(first, "map (100) -- inserts: "))
	testing.expect(t, strings.has_suffix(first, ")\n"))
}

@(test)
test_commands_fail_call_propagates :: proc(t: ^testing.T) {
	// Wrappers return the core result for execute() to propagate (the
	// C++ rethrows); try/catch and the client loop observe body errors.
	spec, ok := commands_spec_for("fail", context.allocator)
	assert(ok)
	defer commands_destroy_desc(&spec.desc)
	p, perr := parameters_parser_parse([]string{"boom"}, spec.desc, false, context.allocator)
	assert(perr == .None)
	defer parameters_parser_free(&p)
	ctx := Context{allocator = context.allocator}
	shell_ctx := Shell_Context{}
	err, msg := commands_fail_call(nil, &p, &ctx, &shell_ctx)
	defer delete(msg)
	testing.expect_value(t, err, Commands_Error.Fail)
	testing.expect_value(t, msg, "boom")
}
