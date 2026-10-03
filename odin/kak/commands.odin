// Port of Kakoune's src/commands.{hh,cc}: every builtin :command.
//
// Each builtin has a core proc (commands_<name>) returning
// (Commands_Error, string) with an owned message on failure, plus a thin
// Command_Func.call wrapper (commands_<name>_call) that reports failures
// on the status line. Cores take an explicit Commands_Env instead of
// touching singletons so tests stay hermetic; wrappers build it from the
// singletons (C++ parity).
//
// Deviations from the C++:
//   * C++ throws runtime_error/failure/kill_session; here cores return
//     Commands_Error and wrappers print it (status text is never freed,
//     the client convention). Kill_Session records its status in
//     commands_kill_status for the unmerged main loop.
//   * Nested failures cannot propagate through void Command_Func.call
//     (knot limitation, also noted in command_manager.odin), so try/catch
//     only observes parse-level errors from nested execute.
//   * Async shell-script completers run synchronously via
//     shell_manager_eval_full (no event loop is available here).
//   * BusyIndicator progress display is skipped (UI-only).
//   * write_to_debug_buffer is implemented here over buffer_manager
//     (the debug module is unmerged); commands_version stands in for
//     main.cc's version string.
//   * Scope highlighter groups currently carry a nil vtable (the
//     highlighters module is unmerged), so add/remove-highlighter report
//     an error instead of crashing; the logic is complete otherwise.
//   * quit without a client returns an error instead of asserting
//     like the C++.
//   * Without an installed server singleton, wrappers use
//     commands_fallback_server instead of asserting.
package kak

import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sys/posix"

// Commands_Error ports the C++ command outcomes. None is success; Error
// carries an owned message, Fail propagates undecorated like C++ failure,
// Kill_Session asks the main loop to exit with commands_kill_status.
Commands_Error :: enum {
	None,
	Error,
	Fail,
	Kill_Session,
}

// Commands_Env bundles the singletons command cores need. Wrappers fill
// it via commands_default_env; tests build it explicitly.
Commands_Env :: struct {
	buffers:      ^Buffer_Manager,
	clients:      ^Client_Manager,
	commands:     ^Command_Manager,
	global:       ^Global_Scope,
	server:       ^Server,
	registers:    ^Register_Manager,
	highlighters: ^Highlighter_Registry,
}

// commands_version stands in for main.cc's `version` (unmerged main
// module). The coordinator should wire the real version at integration.
commands_version :: "unknown"

// commands_kill_status holds the exit status from the last :kill
// invocation for the main loop to consume.
commands_kill_status: int

// commands_fallback_server stands in for the session server when no
// server singleton is installed (tests never bind a real server).
commands_fallback_server := Server{session = "fallback"}

// Test-only default_env override (installed per holder test by
// test_commands_setup_singletons; production never activates it).
// Declared unconditionally: `odin build` also compiles *_test.odin
// files (with ODIN_TEST=false), and the commands tests reference
// these globals, so a `when ODIN_TEST` gate breaks non-test builds.
commands_test_env: Commands_Env
commands_test_env_active := false

// commands_default_env builds the production env from the singletons
// (C++ CommandManager/BufferManager/...::instance()). The server
// falls back to commands_fallback_server when uninstalled so
// wrapper-driven paths stay usable without a bound socket. The
// buffer and client managers are owned by other modules' tests and
// may be uninstalled (or concurrently reset) while commands tests
// run, so they resolve to nil instead of asserting; cores that need
// them must nil-check (production always installs both).
commands_default_env :: proc() -> Commands_Env {
	when ODIN_TEST {
		if commands_test_env_active {
			return commands_test_env
		}
	}
	server := remote_server_singleton
	if server == nil {
		server = &commands_fallback_server
	}
	buffers: ^Buffer_Manager
	if buffer_manager_has_instance {
		buffers = buffer_manager_instance()
	}
	clients: ^Client_Manager
	if client_manager_has_instance {
		clients = client_manager_instance()
	}
	return Commands_Env {
		buffers      = buffers,
		clients      = clients,
		commands     = command_manager_instance(),
		global       = scope_global_instance(),
		server       = server,
		registers    = register_manager_instance(),
		highlighters = highlighter_registry_instance(),
	}
}

// commands_errorf builds a (.Error, owned-message) pair through
// format_format (C++ format()).
commands_errorf :: proc(
	fmt: string,
	params: []string,
	allocator := context.allocator,
) -> (
	Commands_Error,
	string,
) {
	msg, err := format_format(fmt, params, allocator)
	assert(err == .None)
	return .Error, msg
}

// commands_int_string renders an integer (C++ to_string(int)). Caller
// owns the result.
commands_int_string :: proc(v: int, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_int(&b, v)
	return strings.to_string(b)
}

// commands_clone_candidates clones every candidate (completer results
// own their strings; freed with command_manager_free_completions).
commands_clone_candidates :: proc(
	list: []string,
	allocator := context.allocator,
) -> Candidate_List {
	res := make(Candidate_List, 0, len(list), allocator)
	for c in list {
		append(&res, strings.clone(c, allocator))
	}
	return res
}

// commands_positionals gathers the parser positionals into an owned
// list (C++ params_to_shell / join(parser)).
commands_positionals :: proc(
	p: ^Parameters_Parser,
	allocator := context.allocator,
) -> [dynamic]string {
	res := make([dynamic]string, 0, parameters_parser_positional_count(p), allocator)
	for i in 0 ..< parameters_parser_positional_count(p) {
		append(&res, strings.clone(parameters_parser_positional(p, i), allocator))
	}
	return res
}

// commands_join_positionals joins positionals with a space (C++
// join(parser, ' ', false)). Caller owns the result.
commands_join_positionals :: proc(
	p: ^Parameters_Parser,
	allocator := context.allocator,
) -> string {
	parts := commands_positionals(p, allocator)
	defer {
		for s in parts {
			delete(s, allocator)
		}
		delete(parts)
	}
	return string_utils_join_char(parts[:], ' ', false, allocator)
}

// commands_report surfaces a core result through the status line (the
// wrapper path). Success is silent; the message is borrowed by the
// stored status line and never freed (client convention).
commands_report :: proc(err: Commands_Error, msg: string, ctx: ^Context) {
	if err == .None {
		return
	}
	face := Face{}
	if f, ferr := face_registry_lookup(context_faces(ctx), "Error", ctx.allocator); ferr == .None {
		face = f
	}
	line := display_buffer_line_make_text(msg, face, ctx.allocator)
	context_print_status_simple(ctx, line)
}

// ---------------------------------------------------------------------------
// Hash-map profiling (micro-port of the C++ do_profile template and
// profile_hash_maps in src/hash_map.cc; kept here because no hash_map
// module exists).
// ---------------------------------------------------------------------------

// profile_hash_maps_do runs one insert/read/remove/find timing pass over
// an Odin builtin map holding count keys (port of the C++ do_profile()
// template, which profiles both std::unordered_map and HashMap; the Odin
// port has only the builtin map, so one pass stands in for both). Keys
// come from a deterministic LCG rather than random_device so the debug
// output is reproducible. The result line goes to the *debug* buffer
// like the C++.
profile_hash_maps_do :: proc(count: int, allocator := context.allocator) {
	state := u64(0x9E3779B97F4A7C15)
	next_rand := proc(state: ^u64, bound: int) -> int {
		state^ = state^ * 6364136223846793005 + 1442695040888963407
		return int((state^ >> 33) % u64(bound))
	}
	vec := make([dynamic]int, 0, count, allocator)
	defer delete(vec)
	for i in 0 ..< count {
		append(&vec, i)
	}
	for i := count - 1; i > 0; i -= 1 {
		j := next_rand(&state, i + 1)
		vec[i], vec[j] = vec[j], vec[i]
	}
	m := make(map[int]int, count, allocator)
	defer delete(m)
	start := clock_now()
	for v in vec {
		m[v] = next_rand(&state, count + 1)
	}
	after_insert := clock_now()
	for _ in 0 ..< count {
		k := next_rand(&state, count + 1)
		cur := 0
		if old, ok := m[k]; ok {
			cur = old
		}
		m[k] = cur + 1
	}
	after_read := clock_now()
	for _ in 0 ..< count {
		delete_key(&m, next_rand(&state, count + 1))
	}
	after_remove := clock_now()
	found := 0
	for v in vec {
		if v in m {
			found += 1
		}
	}
	after_find := clock_now()
	to_us := proc(earlier, later: Clock_Time) -> int {
		return int(i64(clock_diff(earlier, later)) / 1000)
	}
	count_s := commands_int_string(count, allocator)
	defer delete(count_s, allocator)
	inserts := commands_int_string(to_us(start, after_insert), allocator)
	defer delete(inserts, allocator)
	reads := commands_int_string(to_us(after_insert, after_read), allocator)
	defer delete(reads, allocator)
	removes := commands_int_string(to_us(after_read, after_remove), allocator)
	defer delete(removes, allocator)
	finds := commands_int_string(to_us(after_remove, after_find), allocator)
	defer delete(finds, allocator)
	found_s := commands_int_string(found, allocator)
	defer delete(found_s, allocator)
	msg, ferr := format_format(
		"map ({}) -- inserts: {}us, reads: {}us, remove: {}us, find: {}us ({})",
		{count_s, inserts, reads, removes, finds, found_s},
		allocator,
	)
	assert(ferr == .None)
	defer delete(msg, allocator)
	debug_write_to_debug_buffer(msg)
}

// profile_hash_maps times builtin-map workloads at increasing sizes
// (port of C++ profile_hash_maps in src/hash_map.cc).
profile_hash_maps :: proc() {
	counts := [5]int{1000, 10000, 100000, 1000000, 10000000}
	for count in counts {
		profile_hash_maps_do(count)
	}
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

// commands_scope_ifp resolves a scope name like C++ get_scope_ifp:
// global/buffer/window/local prefixes plus buffer=<name>.
commands_scope_ifp :: proc(
	scope_name: string,
	ctx: ^Context,
	buffers: ^Buffer_Manager,
	global: ^Global_Scope,
) -> ^Scope {
	if string_utils_prefix_match("global", scope_name) {
		return &global.scope
	} else if string_utils_prefix_match("buffer", scope_name) {
		if context_has_buffer(ctx) {
			return &context_buffer(ctx).scope
		}
		return nil
	} else if string_utils_prefix_match("window", scope_name) {
		if context_has_window(ctx) {
			return &context_window(ctx).scope
		}
		return nil
	} else if string_utils_prefix_match("local", scope_name) {
		return context_local_scope(ctx)
	} else if string_utils_prefix_match(scope_name, "buffer=") {
		if buffers != nil {
			if buf := buffer_manager_get_ifp(buffers, scope_name[7:]); buf != nil {
				return &buf.scope
			}
		}
	}
	return nil
}

// commands_get_scope resolves a scope name or reports "no such scope"
// (C++ get_scope).
commands_get_scope :: proc(
	scope_name: string,
	ctx: ^Context,
	env: ^Commands_Env,
	allocator := context.allocator,
) -> (
	^Scope,
	Commands_Error,
	string,
) {
	if s := commands_scope_ifp(scope_name, ctx, env.buffers, env.global); s != nil {
		return s, .None, ""
	}
	err, msg := commands_errorf("no such scope: '{}'", {scope_name}, allocator)
	return nil, err, msg
}

// commands_get_options returns the option manager for a set/unset/update
// scope: "current" is the narrowest scope holding the option (C++
// get_options).
commands_get_options :: proc(
	scope_name: string,
	ctx: ^Context,
	env: ^Commands_Env,
	option_name: string,
	allocator := context.allocator,
) -> (
	^Option_Manager,
	Commands_Error,
	string,
) {
	if scope_name == "current" {
		opt, oerr := option_manager_get_option(context_options(ctx), option_name)
		if oerr != .None {
			err, msg := commands_errorf("no such option: '{}'", {option_name}, allocator)
			return nil, err, msg
		}
		return opt.manager, .None, ""
	}
	scope, serr, smsg := commands_get_scope(scope_name, ctx, env, allocator)
	if serr != .None {
		return nil, serr, smsg
	}
	return &scope.data.options, .None, ""
}

// commands_parse_keymap_mode maps a mode name to its KeymapMode (C++
// parse_keymap_mode), including user modes.
commands_parse_keymap_mode :: proc(
	name: string,
	user_modes: []string,
	allocator := context.allocator,
) -> (
	Keymap_Manager_Mode,
	Commands_Error,
	string,
) {
	if string_utils_prefix_match("normal", name) {
		return .Normal, .None, ""
	}
	if string_utils_prefix_match("insert", name) {
		return .Insert, .None, ""
	}
	if string_utils_prefix_match("menu", name) {
		return .Menu, .None, ""
	}
	if string_utils_prefix_match("prompt", name) {
		return .Prompt, .None, ""
	}
	if string_utils_prefix_match("goto", name) {
		return .Goto, .None, ""
	}
	if string_utils_prefix_match("view", name) {
		return .View, .None, ""
	}
	if string_utils_prefix_match("user", name) {
		return .User, .None, ""
	}
	if string_utils_prefix_match("object", name) {
		return .Object, .None, ""
	}
	if string_utils_prefix_match("combine", name) {
		return .Combine, .None, ""
	}
	for mode, i in user_modes {
		if mode == name {
			return Keymap_Manager_Mode(int(Keymap_Manager_Mode.First_User_Mode) + i), .None, ""
		}
	}
	err, msg := commands_errorf("no such keymap mode: '{}'", {name}, allocator)
	return .None, err, msg
}

// commands_parse_write_method parses a writemethod name (C++
// parse_write_method).
commands_parse_write_method :: proc(
	name: string,
	allocator := context.allocator,
) -> (
	File_Write_Method,
	Commands_Error,
	string,
) {
	if method, ok := file_write_method_from_name(name); ok {
		return method, .None, ""
	}
	err, msg := commands_errorf("invalid writemethod '{}'", {name}, allocator)
	return .Overwrite, err, msg
}

// commands_generate_buffer_name finds the first free name matching the
// pattern (C++ generate_buffer_name, buffer_utils.cc).
commands_generate_buffer_name :: proc(
	pattern: string,
	buffers: ^Buffer_Manager,
	allocator := context.allocator,
) -> string {
	for i := 0; ; i += 1 {
		num := commands_int_string(i, allocator)
		name, ferr := format_format(pattern, {num}, allocator)
		assert(ferr == .None)
		delete(num, allocator)
		if buffer_manager_get_ifp(buffers, name) == nil {
			return name
		}
		delete(name, allocator)
	}
}

// commands_write_to_debug_buffer appends a line to the *debug* buffer
// (C++ write_to_debug_buffer, buffer_utils.cc).
commands_write_to_debug_buffer :: proc(
	text: string,
	buffers: ^Buffer_Manager,
	allocator := context.allocator,
) {
	buf := buffer_manager_get_ifp(buffers, "*debug*")
	if buf == nil {
		// Zero lines: buffer_do_insert cannot insert at the end of a
		// buffer whose last line is empty (it indexes the last byte
		// unguarded), but the empty-lines case short-circuits safely.
		lines := make(Buffer_Lines, 0, allocator)
		made, merr := buffer_manager_create(
			buffers,
			"*debug*",
			{.Debug},
			lines,
			.None,
			.Lf,
			.Present,
			File_Fs_Status{},
		)
		delete(lines)
		if merr != .None {
			return
		}
		buf = made
	}
	content := strings.concatenate({text, "\n"}, allocator)
	defer delete(content, allocator)
	_, _ = buffer_insert(buf, buffer_end_coord(buf), content)
}

// commands_open_fifo opens a named fifo for reading (C++ open_fifo).
// The fd transfers to the fifo buffer.
commands_open_fifo :: proc(
	name, filename: string,
	flags: Buffer_Flags,
	scroll: bool,
	allocator := context.allocator,
) -> (
	^Buffer,
	Commands_Error,
	string,
) {
	path := file_parse_filename(filename, "", allocator)
	defer delete(path, allocator)
	cname := strings.clone_to_cstring(path, context.temp_allocator)
	fd := posix.open(cname, {.NONBLOCK, .CLOEXEC})
	if fd == -1 {
		err, msg := commands_errorf("unable to open '{}'", {filename}, allocator)
		return nil, err, msg
	}
	auto_scroll := Buffer_Utils_Auto_Scroll.Not_Initially
	if scroll {
		auto_scroll = .Yes
	}
	buf, ferr := buffer_utils_create_fifo_buffer(name, int(fd), flags, auto_scroll, allocator)
	if ferr != .None || buf == nil {
		posix.close(posix.FD(fd))
		err, msg := commands_errorf("{}: {}", {filename, buffer_utils_error_message(ferr)}, allocator)
		return nil, err, msg
	}
	return buf, .None, ""
}

// commands_option_value reads a context option's value or reports "no
// such option".
commands_option_value :: proc(
	ctx: ^Context,
	name: string,
	allocator := context.allocator,
) -> (
	Option_Value,
	Commands_Error,
	string,
) {
	opt, oerr := option_manager_get_option(context_options(ctx), name)
	if oerr != .None {
		err, msg := commands_errorf("no such option: '{}'", {name}, allocator)
		return 0, err, msg
	}
	return opt.value, .None, ""
}

// commands_do_write_buffer writes the current buffer (C++
// do_write_buffer).
commands_do_write_buffer :: proc(
	ctx: ^Context,
	filename: Maybe(string),
	force, sync: bool,
	method: Maybe(File_Write_Method),
	allocator := context.allocator,
) -> (
	Commands_Error,
	string,
) {
	buffer := context_buffer(ctx)
	is_file := .File in buffer.flags
	if _, ok := filename.?; !ok && !is_file {
		return commands_errorf(
			"cannot write a non file buffer without a filename",
			{},
			allocator,
		)
	}

	is_readonly := .Read_Only in buffer.flags
	if fname, ok := filename.?; is_file && is_readonly {
		same := false
		if ok {
			real, rerr := file_real_path(fname, allocator)
			if rerr == .None {
				same = real == buffer.filename
				delete(real, allocator)
			}
		} else {
			same = true
		}
		if same {
			return commands_errorf(
				"cannot overwrite the buffer when in readonly mode",
				{},
				allocator,
			)
		}
	}

	effective: string
	owned := false
	// Function scope: Odin defers fire at block end, so this must
	// not sit inside the if below (effective outlives the block).
	defer if owned {
		delete(effective, allocator)
	}
	if fname, ok := filename.?; ok {
		effective = file_parse_filename(fname, "", allocator)
		owned = true
		if !force {
			real, rerr := file_real_path(effective, allocator)
			if rerr == .None {
				mismatch := real != buffer.filename
				delete(real, allocator)
				if mismatch && file_regular_file_exists(effective) {
					return commands_errorf(
						"cannot overwrite existing file without -force",
						{},
						allocator,
					)
				}
			}
		}
	} else {
		effective = buffer.filename
	}

	write_method := method.? or_else File_Write_Method.Overwrite
	if _, ok := method.?; !ok {
		val, verr, vmsg := commands_option_value(ctx, "writemethod", allocator)
		if verr != .None {
			return verr, vmsg
		}
		write_method = val.(File_Write_Method)
	}

	hook_manager_run_hook(context_hooks(ctx), .Buf_Write_Pre, effective, ctx)
	wflags := Buffer_Utils_Write_Flags{}
	if force {
		wflags += {.Force}
	}
	if sync {
		wflags += {.Sync}
	}
	if werr := buffer_utils_write_buffer_to_file(buffer, effective, write_method, wflags); werr != .None {
		return commands_errorf("{}: {}", {effective, buffer_utils_error_message(werr)}, allocator)
	}
	hook_manager_run_hook(context_hooks(ctx), .Buf_Write_Post, effective, ctx)
	return .None, ""
}

// commands_write_all_buffers writes every modified file buffer (C++
// write_all_buffers).
commands_write_all_buffers :: proc(
	ctx: ^Context,
	env: ^Commands_Env,
	sync: bool,
	method: Maybe(File_Write_Method),
	allocator := context.allocator,
) -> (
	Commands_Error,
	string,
) {
	buffers := make([dynamic]^Buffer, 0, len(env.buffers.buffers), allocator)
	defer delete(buffers)
	for buf in env.buffers.buffers {
		append(&buffers, buf)
	}
	for buf in buffers {
		if .File in buf.flags &&
		   (.New in buf.flags || buffer_is_modified(buf)) &&
		   .Read_Only not_in buf.flags {
			write_method := method.? or_else File_Write_Method.Overwrite
			if _, ok := method.?; !ok {
				val, verr, vmsg := commands_option_value(ctx, "writemethod", allocator)
				if verr != .None {
					return verr, vmsg
				}
				write_method = val.(File_Write_Method)
			}
			name := buffer_manager_buffer_name(buf)
			buffer_run_hook_in_own_context(buf, .Buf_Write_Pre, name)
			wflags := Buffer_Utils_Write_Flags{}
			if sync {
				wflags += {.Sync}
			}
			if werr := buffer_utils_write_buffer_to_file(buf, name, write_method, wflags); werr != .None {
				return commands_errorf("{}: {}", {name, buffer_utils_error_message(werr)}, allocator)
			}
			buffer_run_hook_in_own_context(buf, .Buf_Write_Post, name)
		}
	}
	return .None, ""
}

// commands_ensure_all_buffers_are_saved errors when modified file
// buffers remain, switching to the first one (C++
// ensure_all_buffers_are_saved).
commands_ensure_all_buffers_are_saved :: proc(
	ctx: ^Context,
	env: ^Commands_Env,
	allocator := context.allocator,
) -> (
	Commands_Error,
	string,
) {
	first := -1
	count := 0
	for buf, i in env.buffers.buffers {
		if .File in buf.flags && buffer_is_modified(buf) {
			if first < 0 {
				first = i
			}
			count += 1
		}
	}
	if first < 0 {
		return .None, ""
	}
	if context_has_buffer(ctx) && !buffer_is_modified(context_buffer(ctx)) {
		context_push_jump(ctx)
		if cerr := context_change_buffer(ctx, env.buffers.buffers[first]); cerr != .None {
			return commands_errorf("buffer is locked", {}, allocator)
		}
	}
	b := strings.builder_make(allocator)
	num := commands_int_string(count, allocator)
	defer delete(num, allocator)
	strings.write_string(&b, num)
	strings.write_string(&b, " modified buffers remaining: [")
	shown := 0
	for buf in env.buffers.buffers {
		if .File in buf.flags && buffer_is_modified(buf) {
			if shown > 0 {
				strings.write_string(&b, ", ")
			}
			strings.write_string(&b, buf.display_name)
			shown += 1
		}
	}
	strings.write_string(&b, "]")
	return .Error, strings.to_string(b)
}

// commands_cycle_buffer moves to the next/previous non-debug buffer
// (C++ cycle_buffer).
commands_cycle_buffer :: proc(
	ctx: ^Context,
	env: ^Commands_Env,
	next: bool,
	allocator := context.allocator,
) -> (
	Commands_Error,
	string,
) {
	old := context_buffer(ctx)
	idx := -1
	for buf, i in env.buffers.buffers {
		if buf == old {
			idx = i
			break
		}
	}
	assert(idx >= 0)
	count := len(env.buffers.buffers)
	next_idx := idx
	for {
		if next {
			next_idx = (next_idx + 1) % count
		} else {
			next_idx = (next_idx + count - 1) % count
		}
		newbuf := env.buffers.buffers[next_idx]
		if newbuf == old || .Debug not_in newbuf.flags {
			if newbuf != old {
				context_push_jump(ctx)
				if cerr := context_change_buffer(ctx, newbuf); cerr != .None {
					return commands_errorf("buffer is locked", {}, allocator)
				}
			}
			return .None, ""
		}
	}
}

// commands_shared_highlighters is the port of SharedHighlighters: a
// group shell with a nil vtable until the highlighters module merges.
commands_shared_highlighters := Highlighter_Group{}

// commands_highlighter_group_for_scope resolves the highlighter group
// for a scope prefix (C++ highlighter_cmd_completer / get_highlighter).
commands_highlighter_group_for_scope :: proc(
	scope_name: string,
	ctx: ^Context,
	env: ^Commands_Env,
) -> ^Highlighter_Group {
	if scope_name == "shared" {
		return &commands_shared_highlighters
	}
	if s := commands_scope_ifp(scope_name, ctx, env.buffers, env.global); s != nil {
		return &s.data.highlighters.group
	}
	return nil
}

// commands_get_highlighter resolves a highlighter path to its root
// group and the addressed highlighter (C++ get_highlighter). Scope
// groups carry a nil vtable until the highlighters module merges;
// that reports an error instead of crashing.
commands_get_highlighter :: proc(
	ctx: ^Context,
	env: ^Commands_Env,
	path: string,
	allocator := context.allocator,
) -> (
	root: ^Highlighter_Group,
	hl: ^Highlighter,
	err: Commands_Error,
	msg: string,
) {
	trimmed := path
	if len(trimmed) > 0 && trimmed[len(trimmed) - 1] == '/' {
		trimmed = trimmed[:len(trimmed) - 1]
	}
	sep := strings.index_byte(trimmed, '/')
	scope_name := trimmed
	rest := ""
	if sep >= 0 {
		scope_name = trimmed[:sep]
		rest = trimmed[sep + 1:]
	}
	if strings.has_prefix(trimmed, "buffer=") {
		for i := 7; i < len(trimmed); i += 1 {
			if trimmed[i] == '/' &&
			   buffer_manager_get_ifp(env.buffers, trimmed[7:i]) != nil {
				scope_name = trimmed[:i]
				rest = trimmed[i + 1:]
				break
			}
		}
	}
	group := commands_highlighter_group_for_scope(scope_name, ctx, env)
	if group == nil {
		serr, smsg := commands_errorf("no such scope: '{}'", {scope_name}, allocator)
		return nil, nil, serr, smsg
	}
	base := &group.base
	if len(rest) == 0 {
		return group, base, .None, ""
	}
	if base.vtable == nil {
		serr, smsg := commands_errorf(
			"highlighter groups are unavailable (highlighters module not ported)",
			{},
			allocator,
		)
		return nil, nil, serr, smsg
	}
	child, herr := highlighter_get_child(base, rest, allocator)
	if herr != .None || child == nil {
		serr, smsg := commands_errorf("no such highlighter: '{}'", {path}, allocator)
		return nil, nil, serr, smsg
	}
	return group, child, .None, ""
}

// commands_redraw_relevant_clients redraws clients whose highlighter
// root is affected (C++ redraw_relevant_clients).
commands_redraw_relevant_clients :: proc(ctx: ^Context, env: ^Commands_Env, root: ^Highlighter_Group) {
	global_group := &env.global.scope.data.highlighters.group
	for client in env.clients.clients {
		cctx := client_context(client)
		hit := root == &commands_shared_highlighters || root == global_group
		if !hit && context_has_buffer(cctx) {
			hit = root == &context_buffer(cctx).scope.data.highlighters.group
		}
		if !hit && context_has_window(cctx) {
			hit = root == &context_window(cctx).scope.data.highlighters.group
		}
		if hit {
			client_force_redraw(client)
		}
	}
}

// Commands_Buffer_Match pairs a ranked match with its buffer name for
// buffer-name completion sorting.
Commands_Buffer_Match :: struct {
	match: Ranked_Match,
	name:  string,
}

commands_buffer_match_less :: proc(a, b: Commands_Buffer_Match) -> bool {
	return ranked_match_less(a.match, b.match)
}

// commands_complete_buffer_names completes buffer display names,
// filename matches first (C++ complete_buffer_name).
commands_complete_buffer_names :: proc(
	ctx: ^Context,
	env: ^Commands_Env,
	prefix: string,
	cursor_pos: Units_ByteCount,
	ignore_current: bool,
	allocator := context.allocator,
) -> Completions {
	end := clamp(int(cursor_pos), 0, len(prefix))
	query := prefix[:end]
	if env.buffers == nil {
		return commands_complete_words(query, cursor_pos, {}, true, allocator)
	}
	current: ^Buffer
	if context_has_buffer(ctx) {
		current = context_buffer(ctx)
	}
	file_matches := make([dynamic]Commands_Buffer_Match, 0, allocator)
	defer delete(file_matches)
	plain_matches := make([dynamic]Commands_Buffer_Match, 0, allocator)
	defer delete(plain_matches)
	for buf in env.buffers.buffers {
		if ignore_current && buf == current {
			continue
		}
		bufname := buf.display_name
		if .File in buf.flags {
			_, file := file_split_path(bufname)
			if m := ranked_match_make(file, query); m.matches {
				append(&file_matches, Commands_Buffer_Match{m, bufname})
				continue
			}
		}
		if m := ranked_match_make(bufname, query); m.matches {
			append(&plain_matches, Commands_Buffer_Match{m, bufname})
		}
	}
	slice.sort_by(file_matches[:], commands_buffer_match_less)
	slice.sort_by(plain_matches[:], commands_buffer_match_less)
	names := make([dynamic]string, 0, len(file_matches) + len(plain_matches), allocator)
	defer delete(names)
	for m in file_matches {
		append(&names, m.name)
	}
	for m in plain_matches {
		append(&names, m.name)
	}
	return Completions{
		candidates = commands_clone_candidates(names[:], allocator),
		start      = 0,
		end        = cursor_pos,
	}
}

// Commands_Context_Func is the per-context body run by
// commands_context_wrap.
Commands_Context_Func :: #type proc(
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
	env: ^Commands_Env,
	allocator: mem.Allocator,
) -> (
	Commands_Error,
	string,
)

// commands_split_list splits a comma-separated list with backslash
// escapes (C++ split(',', '\\') + unescape). Caller owns the result
// strings.
commands_split_list :: proc(
	value: string,
	allocator := context.allocator,
) -> [dynamic]string {
	parts := ranges_split_escaped(value, ',', '\\', allocator)
	defer delete(parts)
	res := make([dynamic]string, 0, len(parts), allocator)
	for part in parts {
		append(&res, string_utils_unescape(part, ",", '\\', allocator))
	}
	return res
}

// Commands_Saved_Reg holds one saved register's cloned values.
Commands_Saved_Reg :: struct {
	reg:    ^Register,
	values: [dynamic]string,
}

// Commands_Reg_Saver saves registers for -save-regs and restores them
// (C++ make_register_restorer).
Commands_Reg_Saver :: struct {
	saves:     [dynamic]Commands_Saved_Reg,
	allocator: mem.Allocator,
}

// commands_reg_saver_make saves every register in regs.
commands_reg_saver_make :: proc(
	regs: string,
	ctx: ^Context,
	env: ^Commands_Env,
	allocator := context.allocator,
) -> (
	Commands_Reg_Saver,
	Commands_Error,
	string,
) {
	saver := Commands_Reg_Saver{allocator = allocator}
	saver.saves = make([dynamic]Commands_Saved_Reg, 0, allocator)
	for c in regs {
		reg, rerr := register_manager_get(env.registers, c)
		if rerr != .None {
			commands_reg_saver_destroy(&saver)
			err, msg := commands_errorf("no such register: '{}'", {regs}, allocator)
			return {}, err, msg
		}
		values := register_manager_save(reg, ctx, allocator)
		cloned := make([dynamic]string, len(values), allocator)
		for v, i in values {
			cloned[i] = strings.clone(v, allocator)
		}
		delete(values)
		append(&saver.saves, Commands_Saved_Reg{reg, cloned})
	}
	return saver, .None, ""
}

// commands_reg_saver_restore restores saved registers in reverse order.
commands_reg_saver_restore :: proc(saver: ^Commands_Reg_Saver, ctx: ^Context) {
	for i := len(saver.saves) - 1; i >= 0; i -= 1 {
		saved := &saver.saves[i]
		guard := utils_scoped_bool_make(register_manager_modified_hook_disabled(saved.reg))
		register_manager_restore(saved.reg, ctx, saved.values[:])
		utils_scoped_bool_release(&guard)
	}
}

// commands_reg_saver_destroy frees the saver without restoring.
commands_reg_saver_destroy :: proc(saver: ^Commands_Reg_Saver) {
	for &saved in saver.saves {
		for v in saved.values {
			delete(v, saver.allocator)
		}
		delete(saved.values)
	}
	delete(saver.saves)
	saver.saves = nil
}

// commands_input_handler_init mirrors input_handler_init but appends
// the initial normal mode directly: input_handler_push_mode reads
// mode_stack[-1] and traps on the empty stack, so input_handler_make
// cannot run until that production bug is fixed (reported to the
// coordinator; the input_handler module's own tests never call make).
// Release with input_handler_deinit like the original.
commands_input_handler_init :: proc(
	h: ^Input_Handler,
	selections: Selection_List,
	flags: Context_Flags,
	name: string,
	allocator := context.allocator,
) {
	h.allocator = allocator
	h.mode_stack = make([dynamic]^Input_Mode, 0, 4, allocator)
	h.last_insert = Input_Handler_Insertion{count = 1}
	h.handle_key_level = 0
	h.recording_reg = 0
	h.recorded_keys = make([dynamic]Keys_Key, 0, allocator)
	h.recording_level = -1
	context_init(&h.ctx, h, selections, flags, name, allocator)
	mode := input_handler_normal_make(h, false)
	append(&h.mode_stack, mode)
	mode.vtable.on_enabled(mode.data, false)
}

// commands_input_handler_make allocates and inits a handler (the
// commands-side input_handler_make stand-in). Release with
// input_handler_destroy like the original.
commands_input_handler_make :: proc(
	selections: Selection_List,
	flags: Context_Flags,
	name: string,
	allocator := context.allocator,
) -> ^Input_Handler {
	h := new(Input_Handler, allocator)
	commands_input_handler_init(h, selections, flags, name, allocator)
	return h
}

// commands_context_wrap_for_buffer runs func in a draft context on
// buffer (C++ context_wrap -buffer path).
commands_context_wrap_for_buffer :: proc(
	p: ^Parameters_Parser,
	buffer: ^Buffer,
	shell_ctx: ^Shell_Context,
	env: ^Commands_Env,
	func: Commands_Context_Func,
	allocator := context.allocator,
) -> (
	Commands_Error,
	string,
) {
	sels := make([dynamic]Selection, 1, allocator)
	sels[0] = Selection{}
	list := Selection_List{
		selections = sels,
		buffer     = buffer,
		timestamp  = buffer_timestamp(buffer),
		allocator  = allocator,
	}
	handler := commands_input_handler_make(list, {.Draft}, "", allocator)
	defer input_handler_destroy(handler)
	// context_init clones the list; the caller's array is freed here.
	delete(sels)
	return func(p, input_handler_context(handler), shell_ctx, env, allocator)
}

// commands_context_wrap_for_context runs func on base_context,
// honouring -draft and -itersel (C++ context_wrap).
commands_context_wrap_for_context :: proc(
	p: ^Parameters_Parser,
	base_context: ^Context,
	shell_ctx: ^Shell_Context,
	env: ^Commands_Env,
	func: Commands_Context_Func,
	allocator := context.allocator,
) -> (
	Commands_Error,
	string,
) {
	_, draft := parameters_parser_get_switch(p, "draft")
	handler: ^Input_Handler
	if draft {
		cloned := selection_list_clone(context_selections_write_only(base_context), allocator)
		handler = commands_input_handler_make(cloned, {.Draft}, context_name(base_context), allocator)
		// context_init clones the list; the caller's copy is freed here.
		selection_list_destroy(&cloned)
		if context_has_window(base_context) {
			context_set_window(input_handler_context(handler), context_window(base_context))
		}
		if context_is_editing(base_context) {
			context_disable_undo_handling(input_handler_context(handler))
		}
	}
	// Function scope (Odin defers fire at block end, so this must not
	// sit inside the if above).
	defer if handler != nil {
		input_handler_destroy(handler)
	}
	ctx := base_context
	if handler != nil {
		ctx = input_handler_context(handler)
	}

	edition := context_scoped_edition_make(ctx)
	defer context_scoped_edition_destroy(&edition)
	sel_edition := context_scoped_selection_edition_make(ctx)
	defer context_scoped_selection_edition_destroy(&sel_edition)

	if _, itersel := parameters_parser_get_switch(p, "itersel"); itersel {
		return commands_context_wrap_itersel(p, base_context, ctx, draft, shell_ctx, env, func, allocator)
	}

	collapse_jumps :=
		.Draft not_in context_flags(ctx) && context_has_buffer(ctx)
	jump_list := context_jump_list(ctx)
	prev_index := context_jump_current_index(jump_list)
	saved_jump: Selection_List
	have_jump := false
	if collapse_jumps {
		saved_jump = selection_list_clone(context_selections_write_only(ctx), allocator)
		have_jump = true
	}
	ferr, fmsg := func(p, ctx, shell_ctx, env, allocator)
	if ferr != .None {
		if have_jump {
			selection_list_destroy(&saved_jump)
		}
		return ferr, fmsg
	}
	if collapse_jumps && context_jump_current_index(jump_list) > prev_index {
		still_there := false
		for buf in env.buffers.buffers {
			if buf == saved_jump.buffer {
				still_there = true
				break
			}
		}
		if still_there {
			context_jump_push(jump_list, saved_jump, prev_index, allocator)
		}
	}
	if have_jump {
		selection_list_destroy(&saved_jump)
	}
	return .None, ""
}

// commands_context_wrap_itersel runs func once per selection (C++
// context_wrap -itersel path).
commands_context_wrap_itersel :: proc(
	p: ^Parameters_Parser,
	base_context, ctx: ^Context,
	draft: bool,
	shell_ctx: ^Shell_Context,
	env: ^Commands_Env,
	func: Commands_Context_Func,
	allocator := context.allocator,
) -> (
	Commands_Error,
	string,
) {
	sels := selection_list_clone(context_selections_write_only(base_context), allocator)
	defer selection_list_destroy(&sels)
	new_sels := make([dynamic]Selection, 0, allocator)
	defer delete(new_sels)
	main := 0
	timestamp := buffer_timestamp(context_buffer(ctx))
	succeeded := false
	for &sel in sels.selections {
		single := selection_list_make_single(sels.buffer, sel, sels.timestamp, allocator)
		target := context_selections_write_only(ctx)
		selection_list_destroy(target)
		target^ = single
		selection_list_update(context_selections_write_only(ctx))

		ferr, fmsg := func(p, ctx, shell_ctx, env, allocator)
		if ferr != .None {
			return ferr, fmsg
		}
		succeeded = true

		if context_buffer(ctx) != sels.buffer {
			return commands_errorf(
				"buffer has changed while iterating on selections",
				{},
				allocator,
			)
		}
		if !draft {
			selection_update_selections(&new_sels, &main, context_buffer(ctx), timestamp)
			timestamp = buffer_timestamp(context_buffer(ctx))
			if &sel == selection_list_main(&sels) {
				main = len(new_sels) + selection_list_main_index(context_selections_write_only(ctx))
			}
			middle := len(new_sels)
			current := context_selections_write_only(ctx)
			for s in current.selections {
				append(&new_sels, s)
			}
			selection_inplace_merge(&new_sels, middle, allocator)
		}
	}

	if !succeeded {
		target := context_selections_write_only(ctx)
		selection_list_destroy(target)
		target^ = selection_list_clone(&sels, allocator)
		return commands_errorf("no selections remaining", {}, allocator)
	}
	if !draft {
		target := context_selections_write_only(ctx)
		selection_list_destroy(target)
		merged := Selection_List{
			main       = main,
			selections = new_sels,
			buffer     = context_buffer(ctx),
			timestamp  = buffer_timestamp(context_buffer(ctx)),
			allocator  = allocator,
		}
		new_sels = nil
		target^ = merged
	}
	return .None, ""
}

// commands_context_wrap runs func in the contexts selected by -buffer,
// -client, -try-client, -draft and -itersel (C++ context_wrap).
commands_context_wrap :: proc(
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
	env: ^Commands_Env,
	default_saved_regs: string,
	func: Commands_Context_Func,
	allocator := context.allocator,
) -> (
	Commands_Error,
	string,
) {
	_, has_buffer := parameters_parser_get_switch(p, "buffer")
	_, has_client := parameters_parser_get_switch(p, "client")
	_, has_try_client := parameters_parser_get_switch(p, "try-client")
	count := 0
	if has_buffer {
		count += 1
	}
	if has_client {
		count += 1
	}
	if has_try_client {
		count += 1
	}
	if count > 1 {
		return commands_errorf(
			"only one of -buffer, -client or -try-client can be specified",
			{},
			allocator,
		)
	}

	saved_regs := default_saved_regs
	if regs, ok := parameters_parser_get_switch(p, "save-regs"); ok {
		saved_regs = regs
	}
	saver, serr, smsg := commands_reg_saver_make(saved_regs, ctx, env, allocator)
	if serr != .None {
		return serr, smsg
	}
	defer commands_reg_saver_destroy(&saver)
	defer commands_reg_saver_restore(&saver, ctx)

	if bufnames, ok := parameters_parser_get_switch(p, "buffer"); ok {
		if bufnames == "*" {
			targets := make([dynamic]^Buffer, 0, allocator)
			defer delete(targets)
			for buf in env.buffers.buffers {
				if .Debug not_in buf.flags {
					append(&targets, buf)
				}
			}
			for buf in targets {
				if ferr, fmsg := commands_context_wrap_for_buffer(
					p,
					buf,
					shell_ctx,
					env,
					func,
					allocator,
				); ferr != .None {
					return ferr, fmsg
				}
			}
			return .None, ""
		}
		names := commands_split_list(bufnames, allocator)
		defer {
			for n in names {
				delete(n, allocator)
			}
			delete(names)
		}
		for name in names {
			buf, berr := buffer_manager_get(env.buffers, name)
			if berr != .None {
				return commands_errorf("no such buffer '{}'", {name}, allocator)
			}
			if ferr, fmsg := commands_context_wrap_for_buffer(
				p,
				buf,
				shell_ctx,
				env,
				func,
				allocator,
			); ferr != .None {
				return ferr, fmsg
			}
		}
		return .None, ""
	}

	if client_names, ok := parameters_parser_get_switch(p, "client"); ok {
		if client_names == "*" {
			targets := make([dynamic]^Client, 0, allocator)
			defer delete(targets)
			for client in env.clients.clients {
				append(&targets, client)
			}
			for client in targets {
				if ferr, fmsg := commands_context_wrap_for_context(
					p,
					client_context(client),
					shell_ctx,
					env,
					func,
					allocator,
				); ferr != .None {
					return ferr, fmsg
				}
			}
			return .None, ""
		}
		names := commands_split_list(client_names, allocator)
		defer {
			for n in names {
				delete(n, allocator)
			}
			delete(names)
		}
		for name in names {
			client, cerr := client_manager_get_client(env.clients, name)
			if cerr != .None {
				return commands_errorf("no such client: '{}'", {name}, allocator)
			}
			if ferr, fmsg := commands_context_wrap_for_context(
				p,
				client_context(client),
				shell_ctx,
				env,
				func,
				allocator,
			); ferr != .None {
				return ferr, fmsg
			}
		}
		return .None, ""
	}

	if client_name, ok := parameters_parser_get_switch(p, "try-client"); ok {
		base := ctx
		if client, _ := client_manager_get_client(env.clients, client_name); client != nil {
			base = client_context(client)
		}
		return commands_context_wrap_for_context(p, base, shell_ctx, env, func, allocator)
	}
	return commands_context_wrap_for_context(p, ctx, shell_ctx, env, func, allocator)
}

// ---------------------------------------------------------------------------
// Completers. Every Command_Completer.call proc below returns owned
// candidates (freed with command_manager_free_completions).
// ---------------------------------------------------------------------------

// commands_complete_words completes prefix against a static word list
// (C++ complete()).
commands_complete_words :: proc(
	prefix: string,
	cursor_pos: Units_ByteCount,
	words: []string,
	menu: bool,
	allocator := context.allocator,
) -> Completions {
	matched := completion_complete(prefix, cursor_pos, words, allocator)
	defer delete(matched)
	flags := Completion_Flags{}
	if menu {
		flags = {.Menu}
	}
	return Completions{
		candidates = commands_clone_candidates(matched[:], allocator),
		start      = 0,
		end        = cursor_pos,
		flags      = flags,
	}
}

// commands_completer_prefix fetches the token being completed.
commands_completer_prefix :: proc(
	params: Command_Parameters,
	token_to_complete: int,
) -> string {
	if token_to_complete < 0 || token_to_complete >= len(params) {
		return ""
	}
	return params[token_to_complete]
}

commands_complete_scope_call :: proc(
	data: rawptr,
	ctx: ^Context,
	params: Command_Parameters,
	token_to_complete: int,
	pos_in_token: Units_ByteCount,
	allocator: mem.Allocator,
) -> Completions {
	words := []string{"global", "buffer", "window", "local"}
	return commands_complete_words(
		commands_completer_prefix(params, token_to_complete),
		pos_in_token,
		words,
		true,
		allocator,
	)
}

commands_complete_scope_including_current_call :: proc(
	data: rawptr,
	ctx: ^Context,
	params: Command_Parameters,
	token_to_complete: int,
	pos_in_token: Units_ByteCount,
	allocator: mem.Allocator,
) -> Completions {
	words := []string{"global", "buffer", "window", "local", "current"}
	return commands_complete_words(
		commands_completer_prefix(params, token_to_complete),
		pos_in_token,
		words,
		true,
		allocator,
	)
}

commands_complete_scope_no_global_call :: proc(
	data: rawptr,
	ctx: ^Context,
	params: Command_Parameters,
	token_to_complete: int,
	pos_in_token: Units_ByteCount,
	allocator: mem.Allocator,
) -> Completions {
	words := []string{"buffer", "window", "local", "current"}
	return commands_complete_words(
		commands_completer_prefix(params, token_to_complete),
		pos_in_token,
		words,
		true,
		allocator,
	)
}

// commands_complete_hooks_call completes hook names (C++ complete_hooks).
commands_complete_hooks_call :: proc(
	data: rawptr,
	ctx: ^Context,
	params: Command_Parameters,
	token_to_complete: int,
	pos_in_token: Units_ByteCount,
	allocator: mem.Allocator,
) -> Completions {
	names := make([dynamic]string, 0, len(hook_manager_hook_descs), allocator)
	defer delete(names)
	for d in hook_manager_hook_descs {
		append(&names, d.name)
	}
	return commands_complete_words(
		commands_completer_prefix(params, token_to_complete),
		pos_in_token,
		names[:],
		false,
		allocator,
	)
}

// commands_complete_command_names completes defined command names plus
// aliases (C++ complete_command_name, without the panicking stub).
commands_complete_command_names :: proc(
	ctx: ^Context,
	m: ^Command_Manager,
	prefix: string,
	cursor_pos: Units_ByteCount,
	allocator := context.allocator,
) -> Completions {
	names := make([dynamic]string, 0, allocator)
	defer delete(names)
	for name, cmd in m.commands {
		if .Hidden not_in cmd.flags {
			append(&names, name)
		}
	}
	flat := alias_registry_flatten(context_aliases(ctx), allocator)
	defer delete(flat)
	for e in flat {
		append(&names, e.alias)
	}
	return commands_complete_words(prefix, cursor_pos, names[:], true, allocator)
}

commands_complete_command_name_call :: proc(
	data: rawptr,
	ctx: ^Context,
	params: Command_Parameters,
	token_to_complete: int,
	pos_in_token: Units_ByteCount,
	allocator: mem.Allocator,
) -> Completions {
	return commands_complete_command_names(
		ctx,
		command_manager_instance(),
		commands_completer_prefix(params, token_to_complete),
		pos_in_token,
		allocator,
	)
}

// commands_complete_module_names completes provided module names (C++
// complete_module_name, without the panicking stub).
commands_complete_module_names :: proc(
	m: ^Command_Manager,
	prefix: string,
	cursor_pos: Units_ByteCount,
	allocator := context.allocator,
) -> Completions {
	names := make([dynamic]string, 0, allocator)
	defer delete(names)
	for name, mod in m.modules {
		if mod.state == .Registered {
			append(&names, name)
		}
	}
	return commands_complete_words(prefix, cursor_pos, names[:], true, allocator)
}

// commands_complete_nested_call completes a nested command line (C++
// CommandManager::Completer / NestedCompleter).
commands_complete_nested_call :: proc(
	data: rawptr,
	ctx: ^Context,
	params: Command_Parameters,
	token_to_complete: int,
	pos_in_token: Units_ByteCount,
	allocator: mem.Allocator,
) -> Completions {
	m := command_manager_instance()
	prefix := commands_completer_prefix(params, token_to_complete)
	if token_to_complete <= 0 || len(params) == 0 {
		return commands_complete_command_names(ctx, m, prefix, pos_in_token, allocator)
	}
	name := command_manager_resolve_alias(ctx, params[0])
	cmd, found := m.commands[name]
	if !found || cmd.completer.call == nil {
		return Completions{}
	}
	return cmd.completer.call(
		cmd.completer.data,
		ctx,
		params[1:],
		token_to_complete - 1,
		pos_in_token,
		allocator,
	)
}

// commands_ignored_files returns the ignored_files regex for filename
// completion, or a zero regex when the option is missing.
commands_ignored_files :: proc(ctx: ^Context) -> Regex {
	if opt, oerr := option_manager_get_option(context_options(ctx), "ignored_files"); oerr == .None {
		if re, ok := opt.value.(Regex); ok {
			return re
		}
	}
	return Regex{}
}

commands_complete_filename_call :: proc(
	data: rawptr,
	ctx: ^Context,
	params: Command_Parameters,
	token_to_complete: int,
	pos_in_token: Units_ByteCount,
	allocator: mem.Allocator,
) -> Completions {
	ignored := commands_ignored_files(ctx)
	prefix := commands_completer_prefix(params, token_to_complete)
	return Completions{
		candidates = completion_complete_filename(prefix, &ignored, pos_in_token, {.Expand}, allocator),
		start      = 0,
		end        = pos_in_token,
	}
}

commands_complete_filename_menu_call :: proc(
	data: rawptr,
	ctx: ^Context,
	params: Command_Parameters,
	token_to_complete: int,
	pos_in_token: Units_ByteCount,
	allocator: mem.Allocator,
) -> Completions {
	ignored := commands_ignored_files(ctx)
	prefix := commands_completer_prefix(params, token_to_complete)
	return Completions{
		candidates = completion_complete_filename(prefix, &ignored, pos_in_token, {.Expand}, allocator),
		start      = 0,
		end        = pos_in_token,
		flags      = {.Menu},
	}
}

commands_complete_dirs_menu_call :: proc(
	data: rawptr,
	ctx: ^Context,
	params: Command_Parameters,
	token_to_complete: int,
	pos_in_token: Units_ByteCount,
	allocator: mem.Allocator,
) -> Completions {
	ignored := commands_ignored_files(ctx)
	prefix := commands_completer_prefix(params, token_to_complete)
	return Completions{
		candidates = completion_complete_filename(
			prefix,
			&ignored,
			pos_in_token,
			{.Only_Directories},
			allocator,
		),
		start      = 0,
		end        = pos_in_token,
		flags      = {.Menu},
	}
}

commands_complete_buffer_call :: proc(
	data: rawptr,
	ctx: ^Context,
	params: Command_Parameters,
	token_to_complete: int,
	pos_in_token: Units_ByteCount,
	allocator: mem.Allocator,
) -> Completions {
	env := commands_default_env()
	comps := commands_complete_buffer_names(
		ctx,
		&env,
		commands_completer_prefix(params, token_to_complete),
		pos_in_token,
		false,
		allocator,
	)
	comps.flags = {.Menu}
	return comps
}

commands_complete_buffer_no_current_call :: proc(
	data: rawptr,
	ctx: ^Context,
	params: Command_Parameters,
	token_to_complete: int,
	pos_in_token: Units_ByteCount,
	allocator: mem.Allocator,
) -> Completions {
	env := commands_default_env()
	comps := commands_complete_buffer_names(
		ctx,
		&env,
		commands_completer_prefix(params, token_to_complete),
		pos_in_token,
		true,
		allocator,
	)
	comps.flags = {.Menu}
	return comps
}

commands_complete_client_call :: proc(
	data: rawptr,
	ctx: ^Context,
	params: Command_Parameters,
	token_to_complete: int,
	pos_in_token: Units_ByteCount,
	allocator: mem.Allocator,
) -> Completions {
	env := commands_default_env()
	if env.clients == nil {
		return Completions{
			candidates = make([dynamic]string, 0, allocator),
			start      = 0,
			end        = pos_in_token,
			flags      = {.Menu},
		}
	}
	prefix := commands_completer_prefix(params, token_to_complete)
	matched := client_manager_complete_client_name(
		env.clients,
		prefix,
		pos_in_token,
		allocator,
	)
	defer delete(matched)
	return Completions{
		candidates = commands_clone_candidates(matched[:], allocator),
		start      = 0,
		end        = pos_in_token,
		flags      = {.Menu},
	}
}

commands_complete_face_call :: proc(
	data: rawptr,
	ctx: ^Context,
	params: Command_Parameters,
	token_to_complete: int,
	pos_in_token: Units_ByteCount,
	allocator: mem.Allocator,
) -> Completions {
	flat := face_registry_flatten(context_faces(ctx), allocator)
	defer face_registry_flatten_free(&flat, allocator)
	names := make([dynamic]string, 0, len(flat), allocator)
	defer delete(names)
	for e in flat {
		append(&names, e.name)
	}
	return commands_complete_words(
		commands_completer_prefix(params, token_to_complete),
		pos_in_token,
		names[:],
		false,
		allocator,
	)
}

commands_complete_alias_call :: proc(
	data: rawptr,
	ctx: ^Context,
	params: Command_Parameters,
	token_to_complete: int,
	pos_in_token: Units_ByteCount,
	allocator: mem.Allocator,
) -> Completions {
	flat := alias_registry_flatten(context_aliases(ctx), allocator)
	defer delete(flat)
	names := make([dynamic]string, 0, len(flat), allocator)
	defer delete(names)
	for e in flat {
		append(&names, e.alias)
	}
	return commands_complete_words(
		commands_completer_prefix(params, token_to_complete),
		pos_in_token,
		names[:],
		false,
		allocator,
	)
}

commands_complete_register_call :: proc(
	data: rawptr,
	ctx: ^Context,
	params: Command_Parameters,
	token_to_complete: int,
	pos_in_token: Units_ByteCount,
	allocator: mem.Allocator,
) -> Completions {
	// Without an installed register manager there are no names to
	// complete (production always installs it; some tests do not,
	// and they must not trap).
	if !register_manager_has_instance {
		return Completions{
			candidates = commands_clone_candidates(nil, allocator),
			start      = 0,
			end        = pos_in_token,
		}
	}
	matched := register_manager_complete_name(
		register_manager_instance(),
		commands_completer_prefix(params, token_to_complete),
		pos_in_token,
		allocator,
	)
	defer delete(matched)
	return Completions{
		candidates = commands_clone_candidates(matched[:], allocator),
		start      = 0,
		end        = pos_in_token,
	}
}

commands_complete_hook_group_call :: proc(
	data: rawptr,
	ctx: ^Context,
	params: Command_Parameters,
	token_to_complete: int,
	pos_in_token: Units_ByteCount,
	allocator: mem.Allocator,
) -> Completions {
	env := commands_default_env()
	scope: ^Scope
	if len(params) > 0 {
		scope = commands_scope_ifp(params[0], ctx, env.buffers, env.global)
	}
	if scope == nil {
		return Completions{}
	}
	groups := make([dynamic]string, 0, allocator)
	defer delete(groups)
	for i in 0 ..< len(scope.data.hooks.hooks) {
		for hook_data in scope.data.hooks.hooks[i] {
			known := false
			for g in groups {
				if g == hook_data.group {
					known = true
					break
				}
			}
			if !known {
				append(&groups, hook_data.group)
			}
		}
	}
	prefix := commands_completer_prefix(params, token_to_complete)
	matched := completion_complete(prefix, pos_in_token, groups[:], allocator)
	defer delete(matched)
	return Completions{
		candidates = commands_clone_candidates(matched[:], allocator),
		start      = 0,
		end        = len(params) > 0 ? Units_ByteCount(len(params[0])) : pos_in_token,
		flags      = {.Menu},
	}
}

commands_complete_shell_call :: proc(
	data: rawptr,
	ctx: ^Context,
	params: Command_Parameters,
	token_to_complete: int,
	pos_in_token: Units_ByteCount,
	allocator: mem.Allocator,
) -> Completions {
	return completion_shell_complete(
		ctx,
		commands_completer_prefix(params, token_to_complete),
		pos_in_token,
		allocator,
	)
}

commands_complete_completer_type_call :: proc(
	data: rawptr,
	ctx: ^Context,
	params: Command_Parameters,
	token_to_complete: int,
	pos_in_token: Units_ByteCount,
	allocator: mem.Allocator,
) -> Completions {
	words := []string{
		"file",
		"client",
		"buffer",
		"shell-script",
		"shell-script-candidates",
		"command",
		"shell",
	}
	return commands_complete_words(
		commands_completer_prefix(params, token_to_complete),
		pos_in_token,
		words,
		false,
		allocator,
	)
}

commands_complete_debug_call :: proc(
	data: rawptr,
	ctx: ^Context,
	params: Command_Parameters,
	token_to_complete: int,
	pos_in_token: Units_ByteCount,
	allocator: mem.Allocator,
) -> Completions {
	words := []string{
		"info",
		"buffers",
		"options",
		"memory",
		"shared-strings",
		"profile-hash-maps",
		"faces",
		"mappings",
		"regex",
		"registers",
	}
	return commands_complete_words(
		commands_completer_prefix(params, token_to_complete),
		pos_in_token,
		words,
		true,
		allocator,
	)
}

commands_complete_option_type_call :: proc(
	data: rawptr,
	ctx: ^Context,
	params: Command_Parameters,
	token_to_complete: int,
	pos_in_token: Units_ByteCount,
	allocator: mem.Allocator,
) -> Completions {
	words := []string{
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
	}
	return commands_complete_words(
		commands_completer_prefix(params, token_to_complete),
		pos_in_token,
		words,
		true,
		allocator,
	)
}

commands_complete_keymap_mode_call :: proc(
	data: rawptr,
	ctx: ^Context,
	params: Command_Parameters,
	token_to_complete: int,
	pos_in_token: Units_ByteCount,
	allocator: mem.Allocator,
) -> Completions {
	env := commands_default_env()
	modes := make([dynamic]string, 0, allocator)
	defer delete(modes)
	for mode in ([?]string{
		"normal",
		"insert",
		"menu",
		"prompt",
		"goto",
		"view",
		"user",
		"object",
		"combine",
	}) {
		append(&modes, mode)
	}
	if len(params) > 0 {
		if scope := commands_scope_ifp(params[0], ctx, env.buffers, env.global); scope != nil {
			for mode in keymap_manager_user_modes(&scope.data.keymaps)^ {
				append(&modes, mode)
			}
		}
	}
	return commands_complete_words(
		commands_completer_prefix(params, token_to_complete),
		pos_in_token,
		modes[:],
		true,
		allocator,
	)
}

commands_complete_user_mode_call :: proc(
	data: rawptr,
	ctx: ^Context,
	params: Command_Parameters,
	token_to_complete: int,
	pos_in_token: Units_ByteCount,
	allocator: mem.Allocator,
) -> Completions {
	modes := keymap_manager_user_modes(context_keymaps(ctx))
	prefix := commands_completer_prefix(params, token_to_complete)
	matched := completion_complete(prefix, pos_in_token, modes^[:], allocator)
	defer delete(matched)
	return Completions{
		candidates = commands_clone_candidates(matched[:], allocator),
		start      = 0,
		end        = Units_ByteCount(len(prefix)),
		flags      = {.Menu},
	}
}

// Commands_Completer_Kind selects the completion backend for
// commands_make_completer (C++ make_command_completer types).
Commands_Completer_Kind :: enum {
	File,
	Client,
	Buffer,
	Shell_Script,
	Shell_Candidates,
	Shell,
}

// Commands_Stored_Completer is the heap data for completers built by
// commands_make_completer.
Commands_Stored_Completer :: struct {
	kind:      Commands_Completer_Kind,
	script:    string,
	flags:     Completion_Flags,
	allocator: mem.Allocator,
}

// commands_run_shell_candidates runs script and splits stdout into
// lines (sync port of AsyncShellScript). Caller owns the result.
commands_run_shell_candidates :: proc(
	script: string,
	ctx: ^Context,
	params: Command_Parameters,
	token_to_complete: int,
	pos_in_token: Units_ByteCount,
	with_pos: bool,
	allocator := context.allocator,
) -> [dynamic]string {
	res := make([dynamic]string, 0, allocator)
	env_vars := make(Env_Var_Map, 2, allocator)
	defer {
		for k, v in env_vars {
			delete(k, allocator)
			delete(v, allocator)
		}
		delete(env_vars)
	}
	token_str := commands_int_string(token_to_complete, allocator)
	defer delete(token_str, allocator)
	env_vars[strings.clone("token_to_complete", allocator)] = strings.clone(token_str, allocator)
	if with_pos {
		pos_str := commands_int_string(int(pos_in_token), allocator)
		defer delete(pos_str, allocator)
		env_vars[strings.clone("pos_in_token", allocator)] = strings.clone(pos_str, allocator)
	}
	shell_ctx := Shell_Context{params = params, env_vars = env_vars}
	eval, eerr := shell_manager_eval_full(
		script,
		ctx,
		&shell_ctx,
		"",
		{.Wait_For_Stdout},
		allocator,
	)
	defer shell_manager_eval_result_free(&eval, allocator)
	if eerr != .None {
		return res
	}
	lines := strings.split_lines(eval.output, allocator)
	defer delete(lines)
	for line in lines {
		if len(line) > 0 {
			append(&res, strings.clone(line, allocator))
		}
	}
	return res
}

commands_stored_completer_call :: proc(
	data: rawptr,
	ctx: ^Context,
	params: Command_Parameters,
	token_to_complete: int,
	pos_in_token: Units_ByteCount,
	allocator: mem.Allocator,
) -> Completions {
	stored := cast(^Commands_Stored_Completer)data
	prefix := commands_completer_prefix(params, token_to_complete)
	switch stored.kind {
	case .File:
		ignored := commands_ignored_files(ctx)
		return Completions{
			candidates = completion_complete_filename(
				prefix,
				&ignored,
				pos_in_token,
				{.Expand},
				allocator,
			),
			start      = 0,
			end        = pos_in_token,
			flags      = stored.flags,
		}
	case .Client:
		env := commands_default_env()
		if env.clients == nil {
			return Completions{
				candidates = make([dynamic]string, 0, allocator),
				start      = 0,
				end        = pos_in_token,
				flags      = stored.flags,
			}
		}
		matched := client_manager_complete_client_name(
			env.clients,
			prefix,
			pos_in_token,
			allocator,
		)
		defer delete(matched)
		return Completions{
			candidates = commands_clone_candidates(matched[:], allocator),
			start      = 0,
			end        = pos_in_token,
			flags      = stored.flags,
		}
	case .Buffer:
		env := commands_default_env()
		if env.buffers == nil {
			return Completions{
				candidates = make([dynamic]string, 0, allocator),
				start      = 0,
				end        = pos_in_token,
				flags      = stored.flags,
			}
		}
		comps := commands_complete_buffer_names(
			ctx,
			&env,
			prefix,
			pos_in_token,
			false,
			allocator,
		)
		comps.flags = stored.flags
		return comps
	case .Shell:
		comps := completion_shell_complete(ctx, prefix, pos_in_token, allocator)
		comps.flags = stored.flags
		return comps
	case .Shell_Script:
		candidates := commands_run_shell_candidates(
			stored.script,
			ctx,
			params,
			token_to_complete,
			pos_in_token,
			true,
			allocator,
		)
		defer {
			for c in candidates {
				delete(c, allocator)
			}
			delete(candidates)
		}
		return Completions{
			candidates = commands_clone_candidates(candidates[:], allocator),
			start      = 0,
			end        = pos_in_token,
			flags      = stored.flags,
		}
	case .Shell_Candidates:
		candidates := commands_run_shell_candidates(
			stored.script,
			ctx,
			params,
			token_to_complete,
			pos_in_token,
			false,
			allocator,
		)
		defer {
			for c in candidates {
				delete(c, allocator)
			}
			delete(candidates)
		}
		end := clamp(int(pos_in_token), 0, len(prefix))
		matched := completion_complete(prefix[:end], pos_in_token, candidates[:], allocator)
		defer delete(matched)
		return Completions{
			candidates = commands_clone_candidates(matched[:], allocator),
			start      = 0,
			end        = pos_in_token,
			flags      = stored.flags,
		}
	}
	unreachable()
}

commands_stored_completer_destroy :: proc(data: rawptr, allocator: mem.Allocator) {
	stored := cast(^Commands_Stored_Completer)data
	delete(stored.script, stored.allocator)
	free(stored, stored.allocator)
}

// commands_make_completer builds a completer from a type name (C++
// make_command_completer).
commands_make_completer :: proc(
	type, param: string,
	flags: Completion_Flags,
	allocator := context.allocator,
) -> (
	Command_Completer,
	Commands_Error,
	string,
) {
	if type == "command" {
		return Command_Completer{call = commands_complete_nested_call}, .None, ""
	}
	kind := Commands_Completer_Kind.File
	switch type {
	case "file":
		kind = .File
	case "client":
		kind = .Client
	case "buffer":
		kind = .Buffer
	case "shell":
		kind = .Shell
	case "shell-script":
		if len(param) == 0 {
			return {}, commands_errorf(
				"shell-script requires a shell script parameter",
				{},
				allocator,
			)
		}
		kind = .Shell_Script
	case "shell-script-candidates":
		if len(param) == 0 {
			return {}, commands_errorf(
				"shell-script-candidates requires a shell script parameter",
				{},
				allocator,
			)
		}
		kind = .Shell_Candidates
	case:
		return {}, commands_errorf("invalid command completion type '{}'", {type}, allocator)
	}
	stored := new(Commands_Stored_Completer, allocator)
	stored^ = Commands_Stored_Completer{
		kind      = kind,
		script    = strings.clone(param, allocator),
		flags     = flags,
		allocator = allocator,
	}
	return Command_Completer{
		call    = commands_stored_completer_call,
		data    = stored,
		destroy = commands_stored_completer_destroy,
	}, .None, ""
}

// commands_parse_completion_switch builds the completer selected by
// the *-completion switches (C++ parse_completion_switch).
commands_parse_completion_switch :: proc(
	p: ^Parameters_Parser,
	flags: Completion_Flags,
	allocator := context.allocator,
) -> (
	Command_Completer,
	Commands_Error,
	string,
) {
	for name in ([?]string{
		"file-completion",
		"client-completion",
		"buffer-completion",
		"shell-script-completion",
		"shell-script-candidates",
		"command-completion",
		"shell-completion",
	}) {
		if param, ok := parameters_parser_get_switch(p, name); ok {
			type := name
			if strings.has_suffix(type, "-completion") {
				type = type[:len(type) - len("-completion")]
			}
			return commands_make_completer(type, param, flags, allocator)
		}
	}
	return Command_Completer{}, .None, ""
}

// commands_complete_nothing_call completes nothing (C++ complete_nothing).
commands_complete_nothing_call :: proc(
	data: rawptr,
	ctx: ^Context,
	params: Command_Parameters,
	token_to_complete: int,
	pos_in_token: Units_ByteCount,
	allocator: mem.Allocator,
) -> Completions {
	return completion_complete_nothing(ctx, "", pos_in_token)
}

// commands_complete_arrange_call completes the last arrange-buffers
// argument as a buffer name.
commands_complete_arrange_call :: proc(
	data: rawptr,
	ctx: ^Context,
	params: Command_Parameters,
	token_to_complete: int,
	pos_in_token: Units_ByteCount,
	allocator: mem.Allocator,
) -> Completions {
	if len(params) == 0 {
		return Completions{}
	}
	last := []string{params[len(params) - 1]}
	return commands_complete_buffer_call(data, ctx, last, 0, pos_in_token, allocator)
}

// commands_complete_highlighter_path completes a highlighter path
// (C++ highlighter_cmd_completer).
commands_complete_highlighter_path :: proc(
	ctx: ^Context,
	path: string,
	pos_in_token: Units_ByteCount,
	add: bool,
	allocator := context.allocator,
) -> Completions {
	env := commands_default_env()
	sep := strings.index_byte(path, '/')
	if sep < 0 {
		scopes := []string{"global/", "buffer/", "window/", "shared/"}
		return commands_complete_words(path, pos_in_token, scopes, true, allocator)
	}
	scope_name := path[:sep]
	group := commands_highlighter_group_for_scope(scope_name, ctx, &env)
	if group == nil || group.base.vtable == nil {
		return Completions{}
	}
	offset := Units_ByteCount(sep + 1)
	comps, herr := highlighter_complete_child(
		&group.base,
		path[sep + 1:],
		pos_in_token - offset,
		add,
		allocator,
	)
	if herr != .None {
		return Completions{}
	}
	cloned := commands_clone_candidates(comps.candidates[:], allocator)
	delete(comps.candidates)
	comps.candidates = cloned
	return completion_offset_pos(comps, offset)
}

commands_complete_add_highlighter_call :: proc(
	data: rawptr,
	ctx: ^Context,
	params: Command_Parameters,
	token_to_complete: int,
	pos_in_token: Units_ByteCount,
	allocator: mem.Allocator,
) -> Completions {
	if token_to_complete == 0 && len(params) > 0 {
		return commands_complete_highlighter_path(
			ctx,
			params[0],
			pos_in_token,
			true,
			allocator,
		)
	}
	if token_to_complete == 1 && len(params) > 1 {
		// Without an installed registry there are no types to
		// complete (production always installs it; some tests do
		// not, and they must not trap).
		if !highlighter_registry_has_instance {
			return Completions{}
		}
		names := make([dynamic]string, 0, allocator)
		defer delete(names)
		for name in highlighter_registry_instance()^ {
			append(&names, name)
		}
		return commands_complete_words(params[1], pos_in_token, names[:], true, allocator)
	}
	return Completions{}
}

commands_complete_remove_highlighter_call :: proc(
	data: rawptr,
	ctx: ^Context,
	params: Command_Parameters,
	token_to_complete: int,
	pos_in_token: Units_ByteCount,
	allocator: mem.Allocator,
) -> Completions {
	if token_to_complete == 0 && len(params) > 0 {
		return commands_complete_highlighter_path(
			ctx,
			params[0],
			pos_in_token,
			false,
			allocator,
		)
	}
	return Completions{}
}

commands_complete_hook_call :: proc(
	data: rawptr,
	ctx: ^Context,
	params: Command_Parameters,
	token_to_complete: int,
	pos_in_token: Units_ByteCount,
	allocator: mem.Allocator,
) -> Completions {
	switch token_to_complete {
	case 0:
		return commands_complete_scope_call(data, ctx, params, 0, pos_in_token, allocator)
	case 1:
		return commands_complete_hooks_call(data, ctx, params, 1, pos_in_token, allocator)
	case 2:
		return commands_complete_nothing_call(data, ctx, params, 2, pos_in_token, allocator)
	case:
		return commands_complete_nested_call(data, ctx, params, token_to_complete, pos_in_token, allocator)
	}
}

commands_complete_remove_hooks_call :: proc(
	data: rawptr,
	ctx: ^Context,
	params: Command_Parameters,
	token_to_complete: int,
	pos_in_token: Units_ByteCount,
	allocator: mem.Allocator,
) -> Completions {
	switch token_to_complete {
	case 0:
		return commands_complete_scope_call(data, ctx, params, 0, pos_in_token, allocator)
	case 1:
		return commands_complete_hook_group_call(data, ctx, params, 1, pos_in_token, allocator)
	case:
		return Completions{}
	}
}

commands_complete_alias_args_call :: proc(
	data: rawptr,
	ctx: ^Context,
	params: Command_Parameters,
	token_to_complete: int,
	pos_in_token: Units_ByteCount,
	allocator: mem.Allocator,
) -> Completions {
	switch token_to_complete {
	case 0:
		return commands_complete_scope_call(data, ctx, params, 0, pos_in_token, allocator)
	case 1:
		return commands_complete_alias_call(data, ctx, params, 1, pos_in_token, allocator)
	case 2:
		return commands_complete_command_name_call(data, ctx, params, 2, pos_in_token, allocator)
	case:
		return Completions{}
	}
}

commands_complete_complete_command_call :: proc(
	data: rawptr,
	ctx: ^Context,
	params: Command_Parameters,
	token_to_complete: int,
	pos_in_token: Units_ByteCount,
	allocator: mem.Allocator,
) -> Completions {
	switch token_to_complete {
	case 0:
		return commands_complete_command_name_call(data, ctx, params, 0, pos_in_token, allocator)
	case 1:
		return commands_complete_completer_type_call(data, ctx, params, 1, pos_in_token, allocator)
	case:
		return Completions{}
	}
}

// commands_complete_option_value_call completes the current value of
// the option named by params[1] (C++ set-option token 2).
commands_complete_option_value_call :: proc(
	data: rawptr,
	ctx: ^Context,
	params: Command_Parameters,
	token_to_complete: int,
	pos_in_token: Units_ByteCount,
	allocator: mem.Allocator,
) -> Completions {
	env := commands_default_env()
	if len(params) < 3 || len(params[2]) > 0 {
		return Completions{}
	}
	reg := &env.global.global_data.option_registry
	if !option_manager_registry_exists(reg, params[1]) {
		return Completions{}
	}
	scope := commands_scope_ifp(params[0], ctx, env.buffers, env.global)
	if scope == nil {
		return Completions{}
	}
	opt, oerr := option_manager_get_option(&scope.data.options, params[1])
	if oerr != .None {
		return Completions{}
	}
	value := option_manager_option_get_as_string(opt, .Kakoune, allocator)
	candidates := make(Candidate_List, 1, allocator)
	candidates[0] = value
	return Completions{
		candidates = candidates,
		start      = 0,
		end        = Units_ByteCount(len(params[2])),
		flags      = {.Quoted},
	}
}

commands_complete_option_name_call :: proc(
	data: rawptr,
	ctx: ^Context,
	params: Command_Parameters,
	token_to_complete: int,
	pos_in_token: Units_ByteCount,
	allocator: mem.Allocator,
) -> Completions {
	env := commands_default_env()
	prefix := commands_completer_prefix(params, token_to_complete)
	candidates := option_manager_registry_complete_name(
		&env.global.global_data.option_registry,
		prefix,
		pos_in_token,
		allocator,
	)
	return Completions{
		candidates = candidates,
		start      = 0,
		end        = Units_ByteCount(len(prefix)),
		flags      = {.Menu},
	}
}

commands_complete_set_option_call :: proc(
	data: rawptr,
	ctx: ^Context,
	params: Command_Parameters,
	token_to_complete: int,
	pos_in_token: Units_ByteCount,
	allocator: mem.Allocator,
) -> Completions {
	switch token_to_complete {
	case 0:
		return commands_complete_scope_including_current_call(
			data,
			ctx,
			params,
			0,
			pos_in_token,
			allocator,
		)
	case 1:
		return commands_complete_option_name_call(data, ctx, params, 1, pos_in_token, allocator)
	case 2:
		return commands_complete_option_value_call(data, ctx, params, 2, pos_in_token, allocator)
	case:
		return Completions{}
	}
}

// commands_complete_option_scope_call completes unset/update-option
// arguments (C++ complete_option).
commands_complete_option_scope_call :: proc(
	data: rawptr,
	ctx: ^Context,
	params: Command_Parameters,
	token_to_complete: int,
	pos_in_token: Units_ByteCount,
	allocator: mem.Allocator,
) -> Completions {
	switch token_to_complete {
	case 0:
		return commands_complete_scope_no_global_call(
			data,
			ctx,
			params,
			0,
			pos_in_token,
			allocator,
		)
	case 1:
		return commands_complete_option_name_call(data, ctx, params, 1, pos_in_token, allocator)
	case:
		return Completions{}
	}
}

commands_complete_map_call :: proc(
	data: rawptr,
	ctx: ^Context,
	params: Command_Parameters,
	token_to_complete: int,
	pos_in_token: Units_ByteCount,
	allocator: mem.Allocator,
) -> Completions {
	switch token_to_complete {
	case 0:
		return commands_complete_scope_call(data, ctx, params, 0, pos_in_token, allocator)
	case 1:
		return commands_complete_keymap_mode_call(data, ctx, params, 1, pos_in_token, allocator)
	case:
		return Completions{}
	}
}

commands_complete_unmap_call :: proc(
	data: rawptr,
	ctx: ^Context,
	params: Command_Parameters,
	token_to_complete: int,
	pos_in_token: Units_ByteCount,
	allocator: mem.Allocator,
) -> Completions {
	switch token_to_complete {
	case 0:
		return commands_complete_scope_call(data, ctx, params, 0, pos_in_token, allocator)
	case 1:
		return commands_complete_keymap_mode_call(data, ctx, params, 1, pos_in_token, allocator)
	case 2:
		return commands_complete_mapped_keys_call(data, ctx, params, 2, pos_in_token, allocator)
	case:
		return Completions{}
	}
}

// commands_complete_mapped_keys_call completes keys mapped in the
// scope/mode named by params[0:2].
commands_complete_mapped_keys_call :: proc(
	data: rawptr,
	ctx: ^Context,
	params: Command_Parameters,
	token_to_complete: int,
	pos_in_token: Units_ByteCount,
	allocator: mem.Allocator,
) -> Completions {
	env := commands_default_env()
	if len(params) < 2 {
		return Completions{}
	}
	scope := commands_scope_ifp(params[0], ctx, env.buffers, env.global)
	if scope == nil {
		return Completions{}
	}
	mode, merr, mmsg := commands_parse_keymap_mode(
		params[1],
		keymap_manager_user_modes(&scope.data.keymaps)^[:],
		allocator,
	)
	if merr != .None {
		delete(mmsg, allocator)
		return Completions{}
	}
	mapped := keymap_manager_get_mapped_keys(&scope.data.keymaps, mode, allocator)
	defer delete(mapped)
	names := make([dynamic]string, 0, len(mapped), allocator)
	defer delete(names)
	for key in mapped {
		append(&names, keys_to_string_key(key, allocator))
	}
	defer {
		for n in names {
			delete(n, allocator)
		}
	}
	return commands_complete_words(
		commands_completer_prefix(params, token_to_complete),
		pos_in_token,
		names[:],
		true,
		allocator,
	)
}

commands_complete_set_face_call :: proc(
	data: rawptr,
	ctx: ^Context,
	params: Command_Parameters,
	token_to_complete: int,
	pos_in_token: Units_ByteCount,
	allocator: mem.Allocator,
) -> Completions {
	switch token_to_complete {
	case 0:
		return commands_complete_scope_call(data, ctx, params, 0, pos_in_token, allocator)
	case 1, 2:
		return commands_complete_face_call(
			data,
			ctx,
			params,
			token_to_complete,
			pos_in_token,
			allocator,
		)
	case:
		return Completions{}
	}
}

commands_complete_unset_face_call :: proc(
	data: rawptr,
	ctx: ^Context,
	params: Command_Parameters,
	token_to_complete: int,
	pos_in_token: Units_ByteCount,
	allocator: mem.Allocator,
) -> Completions {
	switch token_to_complete {
	case 0:
		return commands_complete_scope_call(data, ctx, params, 0, pos_in_token, allocator)
	case 1:
		comps := commands_complete_face_call(data, ctx, params, 1, pos_in_token, allocator)
		comps.flags = {.Menu}
		return comps
	case:
		return Completions{}
	}
}

commands_complete_require_module_call :: proc(
	data: rawptr,
	ctx: ^Context,
	params: Command_Parameters,
	token_to_complete: int,
	pos_in_token: Units_ByteCount,
	allocator: mem.Allocator,
) -> Completions {
	return commands_complete_module_names(
		command_manager_instance(),
		commands_completer_prefix(params, token_to_complete),
		pos_in_token,
		allocator,
	)
}

// commands_complete_client_name_call completes the current client
// name (C++ make_single_word_completer for rename-client).
commands_complete_client_name_call :: proc(
	data: rawptr,
	ctx: ^Context,
	params: Command_Parameters,
	token_to_complete: int,
	pos_in_token: Units_ByteCount,
	allocator: mem.Allocator,
) -> Completions {
	words := []string{context_name(ctx)}
	return commands_complete_words(
		commands_completer_prefix(params, token_to_complete),
		pos_in_token,
		words,
		false,
		allocator,
	)
}

// commands_complete_session_name_call completes the current session
// name (C++ make_single_word_completer for rename-session).
commands_complete_session_name_call :: proc(
	data: rawptr,
	ctx: ^Context,
	params: Command_Parameters,
	token_to_complete: int,
	pos_in_token: Units_ByteCount,
	allocator: mem.Allocator,
) -> Completions {
	env := commands_default_env()
	words := []string{env.server.session}
	return commands_complete_words(
		commands_completer_prefix(params, token_to_complete),
		pos_in_token,
		words,
		false,
		allocator,
	)
}

// commands_option_doc_helper_call shows an option's docstring (C++
// option_doc_helper).
commands_option_doc_helper_call :: proc(
	data: rawptr,
	ctx: ^Context,
	params: Command_Parameters,
	allocator: mem.Allocator,
) -> string {
	is_switch := len(params) > 1 && (params[0] == "-add" || params[0] == "-remove")
	need := 2
	if is_switch {
		need = 3
	}
	if len(params) < need {
		return ""
	}
	env := commands_default_env()
	desc := option_manager_registry_desc(
		&env.global.global_data.option_registry,
		params[need - 1],
	)
	if desc == nil || len(desc.docstring) == 0 {
		return ""
	}
	indented := string_utils_indent(desc.docstring, "    ", allocator)
	defer delete(indented, allocator)
	msg, ferr := format_format("{}:\n{}", {desc.name, indented}, allocator)
	assert(ferr == .None)
	return msg
}

// commands_face_doc_helper_call shows a face's definition (C++
// face_doc_helper).
commands_face_doc_helper_call :: proc(
	data: rawptr,
	ctx: ^Context,
	params: Command_Parameters,
	allocator: mem.Allocator,
) -> string {
	if len(params) < 2 {
		return ""
	}
	// C++ faces()[name] throws when the name is absent from the
	// chain; the resolving lookup never fails, so check first.
	found := false
	for r := context_faces(ctx); r != nil; r = r.parent {
		if params[1] in r.faces {
			found = true
			break
		}
	}
	if !found {
		return ""
	}
	face, ferr := face_registry_lookup(context_faces(ctx), params[1], allocator)
	if ferr != .None {
		return ""
	}
	rendered := face_registry_face_to_string(face, allocator)
	defer delete(rendered, allocator)
	indented := string_utils_indent(rendered, "    ", allocator)
	defer delete(indented, allocator)
	msg, mferr := format_format("{}:\n{}", {params[1], indented}, allocator)
	assert(mferr == .None)
	return msg
}

// commands_addhl_doc_helper_call shows a highlighter type's docstring
// (C++ add_highlighter_cmd helper).
commands_addhl_doc_helper_call :: proc(
	data: rawptr,
	ctx: ^Context,
	params: Command_Parameters,
	allocator: mem.Allocator,
) -> string {
	if len(params) <= 1 {
		return ""
	}
	// Without an installed registry no type can be documented
	// (production always installs it; some tests do not, and they
	// must not trap).
	if !highlighter_registry_has_instance {
		return ""
	}
	entry, herr := highlighter_registry_get(highlighter_registry_instance(), params[1])
	if herr != .None {
		return ""
	}
	doc := entry.description.docstring
	switches_doc := parameters_parser_generate_switches_doc(
		entry.description.params.switches,
		allocator,
	)
	defer delete(switches_doc, allocator)
	if len(switches_doc) == 0 {
		indented := string_utils_indent(doc, "    ", allocator)
		defer delete(indented, allocator)
		msg, ferr := format_format("{}:\n{}", {params[1], indented}, allocator)
		assert(ferr == .None)
		return msg
	}
	parts := []string{doc, "Switches:", switches_doc}
	indented := make([dynamic]string, 0, 3, allocator)
	defer {
		for s in indented {
			delete(s, allocator)
		}
		delete(indented)
	}
	for part in parts {
		append(&indented, string_utils_indent(part, "    ", allocator))
	}
	joined := string_utils_join_char(indented[:], '\n', false, allocator)
	defer delete(joined, allocator)
	msg, ferr := format_format("{}:\n{}", {params[1], joined}, allocator)
	assert(ferr == .None)
	return msg
}

// ---------------------------------------------------------------------------
// Parameter descriptions and the command spec table.
// ---------------------------------------------------------------------------

// Commands_Switch describes one switch for commands_make_desc.
Commands_Switch :: struct {
	name:           string,
	description:    string,
	takes_argument: bool,
}

// commands_make_desc builds a parameter description (C++ ParameterDesc).
// The switches map is owned (keys/descriptions borrow the caller's
// strings); release with commands_destroy_desc. Registration clones it
// into the manager.
commands_make_desc :: proc(
	switches: []Commands_Switch,
	flags: Parameters_Parser_Flags,
	min_positionals, max_positionals: int,
	allocator := context.allocator,
) -> Parameters_Parser_Desc {
	table := make(map[string]Parameters_Parser_Switch_Desc, len(switches), allocator)
	for sw in switches {
		table[sw.name] = Parameters_Parser_Switch_Desc{
			takes_argument = sw.takes_argument,
			description    = sw.description,
		}
	}
	return Parameters_Parser_Desc{
		switches        = table,
		flags           = flags,
		min_positionals = min_positionals,
		max_positionals = max_positionals,
	}
}

// commands_destroy_desc releases a description from commands_make_desc.
commands_destroy_desc :: proc(desc: ^Parameters_Parser_Desc) {
	delete(desc.switches)
	desc.switches = nil
}

// Commands_Spec is one builtin's registration data (C++ CommandDesc).
Commands_Spec :: struct {
	name:      string,
	alias:     string,
	docstring: string,
	desc:      Parameters_Parser_Desc,
	func:      Command_Func,
	helper:    Command_Helper,
	completer: Command_Completer,
}

// commands_all_names lists every builtin command name.
commands_all_names := [57]string{
	"nop",
	"edit",
	"edit!",
	"write",
	"write!",
	"write-all",
	"write-all-quit",
	"kill",
	"kill!",
	"daemonize-session",
	"quit",
	"quit!",
	"write-quit",
	"write-quit!",
	"buffer",
	"buffer-next",
	"buffer-previous",
	"delete-buffer",
	"delete-buffer!",
	"rename-buffer",
	"arrange-buffers",
	"add-highlighter",
	"remove-highlighter",
	"hook",
	"remove-hooks",
	"trigger-user-hook",
	"define-command",
	"complete-command",
	"alias",
	"unalias",
	"echo",
	"debug",
	"source",
	"set-option",
	"unset-option",
	"update-option",
	"declare-option",
	"map",
	"unmap",
	"execute-keys",
	"evaluate-commands",
	"prompt",
	"on-key",
	"info",
	"try",
	"set-face",
	"unset-face",
	"rename-client",
	"set-register",
	"select",
	"change-directory",
	"rename-session",
	"fail",
	"declare-user-mode",
	"enter-user-mode",
	"provide-module",
	"require-module",
}

// commands_spec_for builds one builtin's spec (C++ CommandDesc table +
// register_commands). The desc map is owned; release with
// commands_destroy_desc after registering.
commands_spec_for :: proc(
	name: string,
	allocator := context.allocator,
) -> (
	Commands_Spec,
	bool,
) {
	switch name {
	case "nop":
		return Commands_Spec{
			name = "nop",
			docstring = "do nothing",
			desc = commands_make_desc({}, {.Ignore_Unknown_Switches}, 0, max(int), allocator),
			func = {call = commands_nop_call},
		}, true
	case "edit", "edit!":
		switches := [6]Commands_Switch{
			{"existing", "fail if the file does not exist, do not open a new file", false},
			{"scratch", "create a scratch buffer, not linked to a file", false},
			{"debug", "create buffer as debug output", false},
			{"fifo", "create a buffer reading its content from a named fifo", true},
			{"readonly", "create a buffer in readonly mode", false},
			{"scroll", "place the initial cursor so that the fifo will scroll to show new data", false},
		}
		if name == "edit" {
			return Commands_Spec{
				name = "edit",
				alias = "e",
				docstring = "edit [<switches>] <filename> [<line> [<column>]]: open the given filename in a buffer",
				desc = commands_make_desc(switches[:], {}, 0, 3, allocator),
				func = {call = commands_edit_call},
				completer = {call = commands_complete_filename_call},
			}, true
		}
		return Commands_Spec{
			name = "edit!",
			alias = "e!",
			docstring = "edit! [<switches>] <filename> [<line> [<column>]]: open the given filename in a buffer, " +
				"force reload if needed",
			desc = commands_make_desc(switches[:], {}, 0, 3, allocator),
			func = {call = commands_force_edit_call},
			completer = {call = commands_complete_filename_call},
		}, true
	case "write", "write!", "write-quit", "write-quit!", "write-all-quit":
		switches := [3]Commands_Switch{
			{"sync", "force the synchronization of the file onto the filesystem", false},
			{"method", "explicit writemethod (replace|overwrite)", true},
			{"force", "Allow overwriting existing file with explicit filename", false},
		}
		no_force := switches[:2]
		switch name {
		case "write":
			return Commands_Spec{
				name = "write",
				alias = "w",
				docstring = "write [<switches>] [<filename>]: write the current buffer to its file " +
					"or to <filename> if specified",
				desc = commands_make_desc(switches[:], {}, 0, 1, allocator),
				func = {call = commands_write_call},
				completer = {call = commands_complete_filename_call},
			}, true
		case "write!":
			return Commands_Spec{
				name = "write!",
				alias = "w!",
				docstring = "write! [<switches>] [<filename>]: write the current buffer to its file " +
					"or to <filename> if specified, even when the file is write protected",
				desc = commands_make_desc(no_force, {}, 0, 1, allocator),
				func = {call = commands_force_write_call},
				completer = {call = commands_complete_filename_call},
			}, true
		case "write-quit":
			return Commands_Spec{
				name = "write-quit",
				alias = "wq",
				docstring = "write-quit [<switches>] [<exit status>]: write current buffer and quit current client. " +
					"An optional integer parameter can set the client exit status",
				desc = commands_make_desc(no_force, {}, 0, 1, allocator),
				func = {call = commands_write_quit_call},
			}, true
		case "write-quit!":
			return Commands_Spec{
				name = "write-quit!",
				alias = "wq!",
				docstring = "write-quit! [<switches>] [<exit status>] write: current buffer and quit current client, even if other buffers are not saved. " +
					"An optional integer parameter can set the client exit status",
				desc = commands_make_desc(no_force, {}, 0, 1, allocator),
				func = {call = commands_force_write_quit_call},
			}, true
		}
		return Commands_Spec{
			name = "write-all-quit",
			alias = "waq",
			docstring = "write-all-quit [<switches>] [<exit status>]: write all buffers associated to a file and quit current client. " +
				"An optional integer parameter can set the client exit status.",
			desc = commands_make_desc(no_force, {}, 0, 1, allocator),
			func = {call = commands_write_all_quit_call},
		}, true
	case "write-all":
		switches := [2]Commands_Switch{
			{"sync", "force the synchronization of the file onto the filesystem", false},
			{"method", "explicit writemethod (replace|overwrite)", true},
		}
		return Commands_Spec{
			name = "write-all",
			alias = "wa",
			docstring = "write-all [<switches>]: write all changed buffers that are associated to a file",
			desc = commands_make_desc(switches[:], {}, 0, 0, allocator),
			func = {call = commands_write_all_call},
		}, true
	case "kill", "kill!":
		doc := "kill [<exit status>]: terminate the current session, the server and all clients connected. " +
			"An optional integer parameter can set the server and client processes exit status"
		call := commands_kill_call
		if name == "kill!" {
			doc = "kill! [<exit status>]: force the termination of the current session, the server and all clients connected. " +
				"An optional integer parameter can set the server and client processes exit status"
			call = commands_force_kill_call
		}
		return Commands_Spec{
			name = name,
			docstring = doc,
			desc = commands_make_desc({}, {.Switches_As_Positional}, 0, 1, allocator),
			func = {call = call},
		}, true
	case "daemonize-session":
		return Commands_Spec{
			name = "daemonize-session",
			docstring = "daemonize-session: set the session server not to quit on last client exit",
			desc = commands_make_desc({}, {}, 0, max(int), allocator),
			func = {call = commands_daemonize_session_call},
		}, true
	case "quit", "quit!":
		alias := "q"
		doc := "quit [<exit status>]: quit current client, and the kakoune session if the client is the last " +
			"(if not running in daemon mode). " +
			"An optional integer parameter can set the client exit status"
		call := commands_quit_call
		if name == "quit!" {
			alias = "q!"
			doc = "quit! [<exit status>]: quit current client, and the kakoune session if the client is the last " +
				"(if not running in daemon mode). Force quit even if the client is the " +
				"last and some buffers are not saved. " +
				"An optional integer parameter can set the client exit status"
			call = commands_force_quit_call
		}
		return Commands_Spec{
			name = name,
			alias = alias,
			docstring = doc,
			desc = commands_make_desc({}, {.Switches_As_Positional}, 0, 1, allocator),
			func = {call = call},
		}, true
	case "buffer":
		switches := [1]Commands_Switch{
			{"matching", "treat the argument as a regex", false},
		}
		return Commands_Spec{
			name = "buffer",
			alias = "b",
			docstring = "buffer <name>: set buffer to edit in current client",
			desc = commands_make_desc(switches[:], {}, 1, 1, allocator),
			func = {call = commands_buffer_call},
			completer = {call = commands_complete_buffer_no_current_call},
		}, true
	case "buffer-next":
		return Commands_Spec{
			name = "buffer-next",
			alias = "bn",
			docstring = "buffer-next: move to the next buffer in the list",
			desc = commands_make_desc({}, {}, 0, 0, allocator),
			func = {call = commands_buffer_next_call},
		}, true
	case "buffer-previous":
		return Commands_Spec{
			name = "buffer-previous",
			alias = "bp",
			docstring = "buffer-previous: move to the previous buffer in the list",
			desc = commands_make_desc({}, {}, 0, 0, allocator),
			func = {call = commands_buffer_previous_call},
		}, true
	case "delete-buffer", "delete-buffer!":
		alias := "db"
		doc := "delete-buffer [name]: delete current buffer or the buffer named <name> if given"
		call := commands_delete_buffer_call
		if name == "delete-buffer!" {
			alias = "db!"
			doc = "delete-buffer! [name]: delete current buffer or the buffer named <name> if " +
				"given, even if the buffer is unsaved"
			call = commands_force_delete_buffer_call
		}
		return Commands_Spec{
			name = name,
			alias = alias,
			docstring = doc,
			desc = commands_make_desc({}, {}, 0, 1, allocator),
			func = {call = call},
			completer = {call = commands_complete_buffer_call},
		}, true
	case "rename-buffer":
		switches := [2]Commands_Switch{
			{"scratch", "convert a file buffer to a scratch buffer", false},
			{"file", "convert a scratch buffer to a file buffer", false},
		}
		return Commands_Spec{
			name = "rename-buffer",
			docstring = "rename-buffer <name>: change current buffer name",
			desc = commands_make_desc(switches[:], {}, 1, 1, allocator),
			func = {call = commands_rename_buffer_call},
			completer = {call = commands_complete_filename_call},
		}, true
	case "arrange-buffers":
		switches := [1]Commands_Switch{
			{"back", "place the named buffers at the back, rather than the front, of the buffer list", false},
		}
		return Commands_Spec{
			name = "arrange-buffers",
			docstring = "arrange-buffers <buffer>...: reorder the buffers in the buffers list\n" +
				"    the named buffers will be moved to the front of the buffer list, in the order given\n" +
				"    buffers that do not appear in the parameters will remain at the end of the list, keeping their current order",
			desc = commands_make_desc(switches[:], {}, 1, max(int), allocator),
			func = {call = commands_arrange_buffers_call},
			completer = {call = commands_complete_arrange_call},
		}, true
	case "add-highlighter":
		switches := [1]Commands_Switch{
			{"override", "replace existing highlighter with same path if it exists", false},
		}
		return Commands_Spec{
			name = "add-highlighter",
			alias = "addhl",
			docstring = "add-highlighter [-override] <path>/<name> <type> <type params>...: add a highlighter to the group identified by <path>\n" +
				"    <path> is a '/' delimited path or the parent highlighter, starting with either\n" +
				"   'global', 'buffer', 'window' or 'shared', if <name> is empty, it will be autogenerated",
			desc = commands_make_desc(switches[:], {.Switches_Only_At_Start}, 2, max(int), allocator),
			func = {call = commands_add_highlighter_call},
			helper = {call = commands_addhl_doc_helper_call},
			completer = {call = commands_complete_add_highlighter_call},
		}, true
	case "remove-highlighter":
		return Commands_Spec{
			name = "remove-highlighter",
			alias = "rmhl",
			docstring = "remove-highlighter <path>: remove highlighter identified by <path>",
			desc = commands_make_desc({}, {}, 1, 1, allocator),
			func = {call = commands_remove_highlighter_call},
			completer = {call = commands_complete_remove_highlighter_call},
		}, true
	case "hook":
		switches := [3]Commands_Switch{
			{"group", "set hook group, see remove-hooks", true},
			{"always", "run hook even if hooks are disabled", false},
			{"once", "run the hook only once", false},
		}
		return Commands_Spec{
			name = "hook",
			docstring = "hook [<switches>] <scope> <hook_name> <filter> <command>: add <command> in <scope> " +
				"to be executed on hook <hook_name> when its parameter matches the <filter> regex\n" +
				"<scope> can be:\n" +
				"  * global: hook is executed for any buffer or window\n" +
				"  * buffer: hook is executed only for the current buffer\n" +
				"            (and any window for that buffer)\n" +
				"  * window: hook is executed only for the current window",
			desc = commands_make_desc(switches[:], {}, 4, 4, allocator),
			func = {call = commands_hook_call},
			completer = {call = commands_complete_hook_call},
		}, true
	case "remove-hooks":
		return Commands_Spec{
			name = "remove-hooks",
			alias = "rmhooks",
			docstring = "remove-hooks <scope> <group>: remove all hooks whose group matches the regex <group>",
			desc = commands_make_desc({}, {}, 2, 2, allocator),
			func = {call = commands_remove_hooks_call},
			completer = {call = commands_complete_remove_hooks_call},
		}, true
	case "trigger-user-hook":
		return Commands_Spec{
			name = "trigger-user-hook",
			docstring = "trigger-user-hook <param>: run 'User' hook with <param> as filter string",
			desc = commands_make_desc({}, {}, 1, 1, allocator),
			func = {call = commands_trigger_user_hook_call},
			completer = {call = commands_complete_nested_call},
		}, true
	case "define-command":
		switches := [12]Commands_Switch{
			{
				"params",
				"take parameters, accessible to each shell escape as $0..$N\n" +
				"parameter should take the form <count> or <min>..<max> (both omittable)",
				true,
			},
			{"override", "allow overriding an existing command", false},
			{"hidden", "do not display the command in completion candidates", false},
			{"docstring", "define the documentation string for command", true},
			{"menu", "treat completions as the only valid inputs", false},
			{"file-completion", "complete parameters using filename completion", false},
			{"client-completion", "complete parameters using client name completion", false},
			{"buffer-completion", "complete parameters using buffer name completion", false},
			{"command-completion", "complete parameters using kakoune command completion", false},
			{"shell-completion", "complete parameters using shell command completion", false},
			{"shell-script-completion", "complete parameters using the given shell-script", true},
			{"shell-script-candidates", "get the parameter candidates using the given shell-script", true},
		}
		return Commands_Spec{
			name = "define-command",
			alias = "def",
			docstring = "define-command [<switches>] <name> <cmds>: define a command <name> executing <cmds>",
			desc = commands_make_desc(switches[:], {}, 2, 2, allocator),
			func = {call = commands_define_command_call},
		}, true
	case "complete-command":
		switches := [1]Commands_Switch{
			{"menu", "treat completions as the only valid inputs", false},
		}
		return Commands_Spec{
			name = "complete-command",
			alias = "compl",
			docstring = "complete-command [<switches>] <name> <type> [<param>]\n" +
				"define command completion",
			desc = commands_make_desc(switches[:], {}, 2, 3, allocator),
			func = {call = commands_complete_command_call},
			completer = {call = commands_complete_complete_command_call},
		}, true
	case "alias":
		return Commands_Spec{
			name = "alias",
			docstring = "alias <scope> <alias> <command>: alias <alias> to <command> in <scope>",
			desc = commands_make_desc({}, {}, 3, 3, allocator),
			func = {call = commands_alias_call},
			completer = {call = commands_complete_alias_args_call},
		}, true
	case "unalias":
		return Commands_Spec{
			name = "unalias",
			docstring = "unalias <scope> <alias> [<expected>]: remove <alias> from <scope>\n" +
				"If <expected> is specified, remove <alias> only if its value is <expected>",
			desc = commands_make_desc({}, {}, 2, 3, allocator),
			func = {call = commands_unalias_call},
			completer = {call = commands_complete_alias_args_call},
		}, true
	case "echo":
		switches := [6]Commands_Switch{
			{"markup", "parse markup", false},
			{"quoting", "quote each argument separately using the given style (raw|kakoune|shell)", true},
			{"end-of-line", "add trailing end-of-line", false},
			{"to-file", "echo contents to given filename", true},
			{"to-shell-script", "pipe contents to given shell script", true},
			{"debug", "write to debug buffer instead of status line", false},
		}
		return Commands_Spec{
			name = "echo",
			docstring = "echo <params>...: display given parameters in the status line",
			desc = commands_make_desc(switches[:], {.Switches_Only_At_Start}, 0, max(int), allocator),
			func = {call = commands_echo_call},
		}, true
	case "debug":
		return Commands_Spec{
			name = "debug",
			docstring = "debug <command>: write some debug information to the *debug* buffer",
			desc = commands_make_desc({}, {.Switches_Only_At_Start}, 1, max(int), allocator),
			func = {call = commands_debug_call},
			completer = {call = commands_complete_debug_call},
		}, true
	case "source":
		return Commands_Spec{
			name = "source",
			docstring = "source <filename> <params>...: execute commands contained in <filename>\n" +
				"parameters are available in the sourced script as %arg{0}, %arg{1}, …",
			desc = commands_make_desc({}, {}, 1, max(int), allocator),
			func = {call = commands_source_call},
			completer = {call = commands_complete_filename_menu_call},
		}, true
	case "set-option":
		switches := [2]Commands_Switch{
			{"add", "add to option rather than replacing it", false},
			{"remove", "remove from option rather than replacing it", false},
		}
		return Commands_Spec{
			name = "set-option",
			alias = "set",
			docstring = "set-option [<switches>] <scope> <name> <value>: set option <name> in <scope> to <value>\n" +
				"<scope> can be global, buffer, window, or current which refers to the narrowest " +
				"scope the option is set in",
			desc = commands_make_desc(switches[:], {.Switches_Only_At_Start}, 2, max(int), allocator),
			func = {call = commands_set_option_call},
			helper = {call = commands_option_doc_helper_call},
			completer = {call = commands_complete_set_option_call},
		}, true
	case "unset-option":
		return Commands_Spec{
			name = "unset-option",
			alias = "unset",
			docstring = "unset-option <scope> <name>: remove <name> option from scope, falling back on parent scope value\n" +
				"<scope> can be buffer, window, or current which refers to the narrowest " +
				"scope the option is set in",
			desc = commands_make_desc({}, {}, 2, 2, allocator),
			func = {call = commands_unset_option_call},
			helper = {call = commands_option_doc_helper_call},
			completer = {call = commands_complete_option_scope_call},
		}, true
	case "update-option":
		return Commands_Spec{
			name = "update-option",
			docstring = "update-option <scope> <name>: update <name> option from scope\n" +
				"some option types, such as line-specs or range-specs can be updated to latest buffer timestamp\n" +
				"<scope> can be buffer, window, or current which refers to the narrowest " +
				"scope the option is set in",
			desc = commands_make_desc({}, {}, 2, 2, allocator),
			func = {call = commands_update_option_call},
			helper = {call = commands_option_doc_helper_call},
			completer = {call = commands_complete_option_scope_call},
		}, true
	case "declare-option":
		switches := [2]Commands_Switch{
			{"hidden", "do not display option name when completing", false},
			{"docstring", "specify option description", true},
		}
		return Commands_Spec{
			name = "declare-option",
			alias = "decl",
			docstring = "declare-option [<switches>] <type> <name> [value]: declare option <name> of type <type>.\n" +
				"set its initial value to <value> if given and the option did not exist\n" +
				"Available types:\n" +
				"    int: integer\n" +
				"    bool: boolean (true/false or yes/no)\n" +
				"    str: character string\n" +
				"    regex: regular expression\n" +
				"    int-list: list of integers\n" +
				"    str-list: list of character strings\n" +
				"    completions: list of completion candidates\n" +
				"    line-specs: list of line specs\n" +
				"    range-specs: list of range specs\n" +
				"    str-to-str-map: map from strings to strings",
			desc = commands_make_desc(switches[:], {.Switches_Only_At_Start}, 2, max(int), allocator),
			func = {call = commands_declare_option_call},
			completer = {call = commands_complete_option_type_call},
		}, true
	case "map":
		switches := [2]Commands_Switch{
			{"atomic", "repeat whole mapping if count given", false},
			{"docstring", "specify mapping description", true},
		}
		return Commands_Spec{
			name = "map",
			docstring = "map [<switches>] <scope> <mode> <key> <keys>: map <key> to <keys> in given <mode> in <scope>",
			desc = commands_make_desc(switches[:], {}, 4, 4, allocator),
			func = {call = commands_map_call},
			completer = {call = commands_complete_map_call},
		}, true
	case "unmap":
		return Commands_Spec{
			name = "unmap",
			docstring = "unmap <scope> <mode> [<key> [<expected-keys>]]: unmap <key> from given <mode> in <scope>.\n" +
				"If <expected-keys> is specified, remove the mapping only if its value is <expected-keys>.\n" +
				"If only <scope> and <mode> are specified remove all mappings",
			desc = commands_make_desc({}, {}, 2, 4, allocator),
			func = {call = commands_unmap_call},
			completer = {call = commands_complete_unmap_call},
		}, true
	case "execute-keys":
		switches := [8]Commands_Switch{
			{"client", "run in the client context for each client in the given comma separated list", true},
			{"try-client", "run in given client context if it exists, or else in the current one", true},
			{"buffer", "run in a disposable context for each given buffer in the comma separated list argument", true},
			{"draft", "run in a disposable context", false},
			{"itersel", "run once for each selection with that selection as the only one", false},
			{"save-regs", "restore all given registers after execution (default: '/\"|^@:')", true},
			{"with-maps", "use user defined key mapping when executing keys", false},
			{"with-hooks", "trigger hooks while executing keys", false},
		}
		return Commands_Spec{
			name = "execute-keys",
			alias = "exec",
			docstring = "execute-keys [<switches>] <keys>: execute given keys as if entered by user",
			desc = commands_make_desc(switches[:], {.Switches_Only_At_Start}, 1, max(int), allocator),
			func = {call = commands_execute_keys_call},
		}, true
	case "evaluate-commands":
		switches := [8]Commands_Switch{
			{"client", "run in the client context for each client in the given comma separated list", true},
			{"try-client", "run in given client context if it exists, or else in the current one", true},
			{"buffer", "run in a disposable context for each given buffer in the comma separated list argument", true},
			{"draft", "run in a disposable context", false},
			{"itersel", "run once for each selection with that selection as the only one", false},
			{"save-regs", "restore all given registers after execution (default: '')", true},
			{"no-hooks", "disable hooks while executing commands", false},
			{"verbatim", "do not reparse argument", false},
		}
		return Commands_Spec{
			name = "evaluate-commands",
			alias = "eval",
			docstring = "evaluate-commands [<switches>] <commands>...: execute commands as if entered by user",
			desc = commands_make_desc(switches[:], {.Switches_Only_At_Start}, 1, max(int), allocator),
			func = {call = commands_evaluate_commands_call},
			completer = {call = commands_complete_nested_call},
		}, true
	case "prompt":
		switches := [12]Commands_Switch{
			{"init", "set initial prompt content", true},
			{"password", "Do not display entered text and clear reg after command", false},
			{"menu", "treat completions as the only valid inputs", false},
			{"file-completion", "use file completion for prompt", false},
			{"client-completion", "use client completion for prompt", false},
			{"buffer-completion", "use buffer completion for prompt", false},
			{"command-completion", "use command completion for prompt", false},
			{"shell-completion", "use shell command completion for prompt", false},
			{"shell-script-completion", "use shell command completion for prompt", true},
			{"shell-script-candidates", "use shell command completion for prompt", true},
			{"on-change", "command to execute whenever the prompt changes", true},
			{"on-abort", "command to execute whenever the prompt is canceled", true},
		}
		return Commands_Spec{
			name = "prompt",
			docstring = "prompt [<switches>] <prompt> <command>: prompt the user to enter a text string " +
				"and then executes <command>, entered text is available in the 'text' value",
			desc = commands_make_desc(switches[:], {}, 2, 2, allocator),
			func = {call = commands_prompt_call},
		}, true
	case "on-key":
		switches := [1]Commands_Switch{
			{"mode-name", "set mode name to use", true},
		}
		return Commands_Spec{
			name = "on-key",
			docstring = "on-key [<switches>] <command>: wait for next user key and then execute <command>, " +
				"with key available in the `key` value",
			desc = commands_make_desc(switches[:], {}, 1, 1, allocator),
			func = {call = commands_on_key_call},
		}, true
	case "info":
		switches := [4]Commands_Switch{
			{"anchor", "set info anchoring <line>.<column>", true},
			{"style", "set info style (above, below, menu, modal)", true},
			{"markup", "parse markup", false},
			{"title", "set info title", true},
		}
		return Commands_Spec{
			name = "info",
			docstring = "info [<switches>] <text>: display an info box containing <text>",
			desc = commands_make_desc(switches[:], {}, 0, 1, allocator),
			func = {call = commands_info_call},
		}, true
	case "try":
		return Commands_Spec{
			name = "try",
			docstring = "try <cmds> [catch <error_cmds>]...: execute <cmds> in current context.\n" +
				"if an error is raised and <error_cmds> is specified, execute it and do\n" +
				"not propagate that error. If <error_cmds> raises an error and another\n" +
				"<error_cmds> is provided, execute this one and so-on",
			desc = commands_make_desc({}, {}, 1, max(int), allocator),
			func = {call = commands_try_call},
		}, true
	case "set-face":
		return Commands_Spec{
			name = "set-face",
			alias = "face",
			docstring = "set-face <scope> <name> <facespec>: set face <name> to <facespec> in <scope>\n" +
				"\n" +
				"facespec format is:\n" +
				"    <fg color>[,<bg color>[,<underline color>]][+<attributes>][@<base>]\n" +
				"colors are either a color name, rgb:######, or rgba:######## values.\n" +
				"attributes is a combination of:\n" +
				"    u: underline, c: curly underline, U: double underline,\n" +
				"    i: italic,            b: bold,            r: reverse,\n" +
				"    s: strikethrough,     B: blink,           d: dim,\n" +
				"    f: final foreground,              g: final background,\n" +
				"    a: final attributes,              F: same as +fga\n" +
				"facespec can as well just be the name of another face.\n" +
				"if a base face is specified, colors and attributes are applied on top of it",
			desc = commands_make_desc({}, {}, 3, 3, allocator),
			func = {call = commands_set_face_call},
			helper = {call = commands_face_doc_helper_call},
			completer = {call = commands_complete_set_face_call},
		}, true
	case "unset-face":
		return Commands_Spec{
			name = "unset-face",
			docstring = "unset-face <scope> <name>: remove <face> from <scope>",
			desc = commands_make_desc({}, {}, 2, 2, allocator),
			func = {call = commands_unset_face_call},
			helper = {call = commands_face_doc_helper_call},
			completer = {call = commands_complete_unset_face_call},
		}, true
	case "rename-client":
		return Commands_Spec{
			name = "rename-client",
			docstring = "rename-client <name>: set current client name to <name>",
			desc = commands_make_desc({}, {}, 1, 1, allocator),
			func = {call = commands_rename_client_call},
			completer = {call = commands_complete_client_name_call},
		}, true
	case "set-register":
		return Commands_Spec{
			name = "set-register",
			alias = "reg",
			docstring = "set-register <name> <values>...: set register <name> to <values>",
			desc = commands_make_desc({}, {.Switches_As_Positional}, 1, max(int), allocator),
			func = {call = commands_set_register_call},
			completer = {call = commands_complete_register_call},
		}, true
	case "select":
		switches := [3]Commands_Switch{
			{"timestamp", "specify buffer timestamp at which those selections are valid", true},
			{"codepoint", "columns are specified in codepoints, not bytes", false},
			{"display-column", "columns are specified in display columns, not bytes", false},
		}
		return Commands_Spec{
			name = "select",
			docstring = "select <selection_desc>...: select given selections\n" +
				"\n" +
				"selection_desc format is <anchor_line>.<anchor_column>,<cursor_line>.<cursor_column>",
			desc = commands_make_desc(switches[:], {.Switches_Only_At_Start}, 1, max(int), allocator),
			func = {call = commands_select_call},
		}, true
	case "change-directory":
		return Commands_Spec{
			name = "change-directory",
			alias = "cd",
			docstring = "change-directory [<directory>]: change the server's working directory to <directory>, or the home directory if unspecified",
			desc = commands_make_desc({}, {}, 0, 1, allocator),
			func = {call = commands_change_directory_call},
			completer = {call = commands_complete_dirs_menu_call},
		}, true
	case "rename-session":
		return Commands_Spec{
			name = "rename-session",
			docstring = "rename-session <name>: change remote session name",
			desc = commands_make_desc({}, {}, 1, 1, allocator),
			func = {call = commands_rename_session_call},
			completer = {call = commands_complete_session_name_call},
		}, true
	case "fail":
		return Commands_Spec{
			name = "fail",
			docstring = "fail [<message>]: raise an error with the given message",
			desc = commands_make_desc({}, {}, 0, max(int), allocator),
			func = {call = commands_fail_call},
		}, true
	case "declare-user-mode":
		return Commands_Spec{
			name = "declare-user-mode",
			docstring = "declare-user-mode <name>: add a new user keymap mode",
			desc = commands_make_desc({}, {}, 1, 1, allocator),
			func = {call = commands_declare_user_mode_call},
		}, true
	case "enter-user-mode":
		switches := [3]Commands_Switch{
			{"lock", "stay in mode until <esc> is pressed", false},
			{"count", "count to forward to normal mode parameters", true},
			{"register", "register to forward to normal mode parameters", true},
		}
		return Commands_Spec{
			name = "enter-user-mode",
			docstring = "enter-user-mode [<switches>] <name> [<count>] [<register>]: enable <name> keymap mode for next key",
			desc = commands_make_desc(switches[:], {}, 1, 1, allocator),
			func = {call = commands_enter_user_mode_call},
			completer = {call = commands_complete_user_mode_call},
		}, true
	case "provide-module":
		switches := [1]Commands_Switch{
			{"override", "allow overriding an existing module", false},
		}
		return Commands_Spec{
			name = "provide-module",
			docstring = "provide-module [<switches>] <name> <cmds>: declares a module <name> provided by <cmds>",
			desc = commands_make_desc(switches[:], {}, 2, 2, allocator),
			func = {call = commands_provide_module_call},
		}, true
	case "require-module":
		return Commands_Spec{
			name = "require-module",
			docstring = "require-module <name>: ensures that <name> module has been loaded",
			desc = commands_make_desc({}, {}, 1, 1, allocator),
			func = {call = commands_require_module_call},
			completer = {call = commands_complete_require_module_call},
		}, true
	}
	return {}, false
}

// ---------------------------------------------------------------------------
// Command cores.
// ---------------------------------------------------------------------------

// commands_str_to_int parses an integer (C++ str_to_int).
commands_str_to_int :: proc(
	str: string,
	allocator := context.allocator,
) -> (
	int,
	Commands_Error,
	string,
) {
	if v, ok := string_utils_str_to_int_ifp(str); ok {
		return v, .None, ""
	}
	err, msg := commands_errorf("{} is not a number", {str}, allocator)
	return 0, err, msg
}

// commands_status_face looks up a status face, defaulting to Face{}.
commands_status_face :: proc(ctx: ^Context, name: string) -> Face {
	if face, ferr := face_registry_lookup(
		context_faces(ctx),
		name,
		context.temp_allocator,
	); ferr == .None {
		return face
	}
	return Face{}
}

// commands_nop does nothing (C++ nop).
commands_nop :: proc() -> (Commands_Error, string) {
	return .None, ""
}

// commands_edit opens a file or scratch buffer (C++ edit).
commands_edit :: proc(
	p: ^Parameters_Parser,
	ctx: ^Context,
	env: ^Commands_Env,
	force_reload: bool,
	allocator := context.allocator,
) -> (
	Commands_Error,
	string,
) {
	_, scratch := parameters_parser_get_switch(p, "scratch")
	if parameters_parser_positional_count(p) == 0 && !force_reload && !scratch {
		return commands_errorf("wrong argument count", {}, allocator)
	}

	flags := Buffer_Flags{}
	if utils_nested_bool_is_set(context_hooks_disabled(ctx)^) {
		flags = flags + Buffer_Flags{.No_Hooks}
	}
	if _, debug := parameters_parser_get_switch(p, "debug"); debug {
		flags = flags + Buffer_Flags{.Debug}
	}

	name := ""
	if parameters_parser_positional_count(p) > 0 {
		name = parameters_parser_positional(p, 0)
	} else if scratch {
		name = commands_generate_buffer_name("*scratch-{}*", env.buffers, allocator)
		defer delete(name, allocator)
	} else {
		name = context_buffer(ctx).display_name
	}

	buffer := buffer_manager_get_ifp(env.buffers, name)
	if scratch {
		if _, ok := parameters_parser_get_switch(p, "readonly"); ok {
			return commands_errorf(
				"scratch is not compatible with readonly, fifo or scroll",
				{},
				allocator,
			)
		}
		if _, ok := parameters_parser_get_switch(p, "fifo"); ok {
			return commands_errorf(
				"scratch is not compatible with readonly, fifo or scroll",
				{},
				allocator,
			)
		}
		if _, ok := parameters_parser_get_switch(p, "scroll"); ok {
			return commands_errorf(
				"scratch is not compatible with readonly, fifo or scroll",
				{},
				allocator,
			)
		}
		if buffer == nil || force_reload {
			if buffer != nil && force_reload {
				_ = buffer_manager_delete(env.buffers, buffer)
			}
			lines := make(Buffer_Lines, 1, allocator)
			lines[0] = ""
			made, merr := buffer_manager_create(
				env.buffers,
				name,
				flags,
				lines,
				.None,
				.Lf,
				.Present,
				File_Fs_Status{},
			)
			delete(lines)
			if merr != .None {
				return commands_errorf("cannot create buffer '{}'", {name}, allocator)
			}
			buffer = made
		} else if .File in buffer.flags {
			return commands_errorf(
				"buffer '{}' exists but is not a scratch buffer",
				{name},
				allocator,
			)
		}
	} else if force_reload && buffer != nil && .File in buffer.flags {
		if rerr := buffer_utils_reload_file_buffer(buffer); rerr != .None {
			return commands_errorf("{}: {}", {name, buffer_utils_error_message(rerr)}, allocator)
		}
	} else {
		if fifo, ok := parameters_parser_get_switch(p, "fifo"); ok {
			_, scroll := parameters_parser_get_switch(p, "scroll")
			opened, oerr, omsg := commands_open_fifo(name, fifo, flags, scroll, allocator)
			if oerr != .None {
				return oerr, omsg
			}
			buffer = opened
		} else if buffer == nil {
			if _, existing := parameters_parser_get_switch(p, "existing"); existing {
				opened, oerr := buffer_utils_open_file_buffer(name, flags, allocator)
				if oerr != .None || opened == nil {
					return commands_errorf("{}: {}", {name, buffer_utils_error_message(oerr)}, allocator)
				}
				buffer = opened
			} else {
				created, cerr := buffer_utils_open_or_create_file_buffer(name, flags, allocator)
				if cerr != .None || created == nil {
					return commands_errorf("{}: {}", {name, buffer_utils_error_message(cerr)}, allocator)
				}
				buffer = created
			}
			if .New in buffer.flags {
				line := display_buffer_line_make_text(
					strings.concatenate({"new file '", name, "'"}, allocator),
					commands_status_face(ctx, "StatusLine"),
					allocator,
				)
				context_print_status_simple(ctx, line)
			}
		}

		buffer.flags = buffer.flags - Buffer_Flags{.No_Hooks}
		if _, readonly := parameters_parser_get_switch(p, "readonly"); readonly {
			buffer.flags = buffer.flags + Buffer_Flags{.Read_Only}
			if opt, oerr := option_manager_get_local_option(
				&buffer.scope.data.options,
				"readonly",
				allocator,
			); oerr == .None {
				_, _ = option_manager_option_set(opt, true)
			}
		}
	}

	current: ^Buffer
	if context_has_buffer(ctx) {
		current = context_buffer(ctx)
	}
	param_count := parameters_parser_positional_count(p)
	if current != nil && (buffer != current || param_count > 1) {
		context_push_jump(ctx)
	}
	if buffer != current {
		if cerr := context_change_buffer(ctx, buffer); cerr != .None {
			return commands_errorf("buffer is locked", {}, allocator)
		}
	}
	buffer = context_buffer(ctx)

	if _, fifo := parameters_parser_get_switch(p, "fifo"); fifo {
		if _, scroll := parameters_parser_get_switch(p, "scroll"); !scroll {
			target := context_selections_write_only(ctx)
			selection_list_destroy(target)
			target^ = selection_list_make_single(
				buffer,
				Selection{},
				buffer_timestamp(buffer),
				allocator,
			)
			return .None, ""
		}
	}
	if param_count > 1 && len(parameters_parser_positional(p, 1)) > 0 {
		line, lerr, lmsg := commands_str_to_int(parameters_parser_positional(p, 1), allocator)
		if lerr != .None {
			return lerr, lmsg
		}
		column := 0
		if param_count > 2 && len(parameters_parser_positional(p, 2)) > 0 {
			c, cerr, cmsg := commands_str_to_int(
				parameters_parser_positional(p, 2),
				allocator,
			)
			if cerr != .None {
				return cerr, cmsg
			}
			column = c
		}
		coord := buffer_clamp(
			buffer,
			Coord_Buffer{line = Coord_Line(max(0, line - 1)), column = Coord_Byte(max(0, column - 1))},
		)
		sel := Selection{basic = Basic_Selection{anchor = coord, cursor = coord_buffer_and_target(coord)}}
		target := context_selections_write_only(ctx)
		selection_list_destroy(target)
		target^ = selection_list_make_single(buffer, sel, buffer_timestamp(buffer), allocator)
		if context_has_window(ctx) {
			window_center_line(
				context_window(ctx),
				selection_list_main(context_selections_write_only(ctx)).cursor.line,
			)
		}
	}
	return .None, ""
}

// commands_write writes the current buffer (C++ write_buffer).
commands_write :: proc(
	p: ^Parameters_Parser,
	ctx: ^Context,
	force_flag: bool,
	allocator := context.allocator,
) -> (
	Commands_Error,
	string,
) {
	_, sync := parameters_parser_get_switch(p, "sync")
	_, force_switch := parameters_parser_get_switch(p, "force")
	force := force_switch || force_flag
	method: Maybe(File_Write_Method)
	if text, ok := parameters_parser_get_switch(p, "method"); ok {
		parsed, perr, pmsg := commands_parse_write_method(text, allocator)
		if perr != .None {
			return perr, pmsg
		}
		method = parsed
	}
	filename: Maybe(string)
	if parameters_parser_positional_count(p) > 0 {
		filename = parameters_parser_positional(p, 0)
	}
	return commands_do_write_buffer(ctx, filename, force, sync, method, allocator)
}

// commands_write_all writes all file buffers (C++ write_all_cmd).
commands_write_all :: proc(
	p: ^Parameters_Parser,
	ctx: ^Context,
	env: ^Commands_Env,
	allocator := context.allocator,
) -> (
	Commands_Error,
	string,
) {
	_, sync := parameters_parser_get_switch(p, "sync")
	method: Maybe(File_Write_Method)
	if text, ok := parameters_parser_get_switch(p, "method"); ok {
		parsed, perr, pmsg := commands_parse_write_method(text, allocator)
		if perr != .None {
			return perr, pmsg
		}
		method = parsed
	}
	return commands_write_all_buffers(ctx, env, sync, method, allocator)
}

// commands_kill terminates the session (C++ kill).
commands_kill :: proc(
	p: ^Parameters_Parser,
	ctx: ^Context,
	env: ^Commands_Env,
	force: bool,
	allocator := context.allocator,
) -> (
	Commands_Error,
	string,
) {
	if !force {
		if serr, smsg := commands_ensure_all_buffers_are_saved(ctx, env, allocator); serr != .None {
			return serr, smsg
		}
	}
	status := 0
	if parameters_parser_positional_count(p) > 0 {
		v, verr, vmsg := commands_str_to_int(parameters_parser_positional(p, 0), allocator)
		if verr != .None {
			return verr, vmsg
		}
		status = v
	}
	targets := make([dynamic]^Client, 0, len(env.clients.clients), allocator)
	defer delete(targets)
	for client in env.clients.clients {
		append(&targets, client)
	}
	for client in targets {
		client_manager_remove_client(env.clients, client, true, status)
	}
	commands_kill_status = status
	return .Kill_Session, ""
}

// commands_daemonize_session marks the server daemonized (C++
// daemonize_session_cmd).
commands_daemonize_session :: proc(env: ^Commands_Env) -> (Commands_Error, string) {
	remote_server_daemonize(env.server)
	return .None, ""
}

// commands_quit quits the current client (C++ quit).
commands_quit :: proc(
	p: ^Parameters_Parser,
	ctx: ^Context,
	env: ^Commands_Env,
	force: bool,
	allocator := context.allocator,
) -> (
	Commands_Error,
	string,
) {
	if !context_has_client(ctx) {
		return commands_errorf("no client", {}, allocator)
	}
	if !force && client_manager_count(env.clients) == 1 && !remote_server_is_daemon(env.server) {
		if serr, smsg := commands_ensure_all_buffers_are_saved(ctx, env, allocator); serr != .None {
			return serr, smsg
		}
	}
	status := 0
	if parameters_parser_positional_count(p) > 0 {
		v, verr, vmsg := commands_str_to_int(parameters_parser_positional(p, 0), allocator)
		if verr != .None {
			return verr, vmsg
		}
		status = v
	}
	client_manager_remove_client(env.clients, context_client(ctx), true, status)
	return .None, ""
}

// commands_write_quit writes the buffer and quits (C++ write_quit).
commands_write_quit :: proc(
	p: ^Parameters_Parser,
	ctx: ^Context,
	env: ^Commands_Env,
	force: bool,
	allocator := context.allocator,
) -> (
	Commands_Error,
	string,
) {
	_, sync := parameters_parser_get_switch(p, "sync")
	method: Maybe(File_Write_Method)
	if text, ok := parameters_parser_get_switch(p, "method"); ok {
		parsed, perr, pmsg := commands_parse_write_method(text, allocator)
		if perr != .None {
			return perr, pmsg
		}
		method = parsed
	}
	if werr, wmsg := commands_do_write_buffer(ctx, nil, false, sync, method, allocator); werr != .None {
		return werr, wmsg
	}
	return commands_quit(p, ctx, env, force, allocator)
}

// commands_write_all_quit writes everything and quits (C++
// write_all_quit_cmd).
commands_write_all_quit :: proc(
	p: ^Parameters_Parser,
	ctx: ^Context,
	env: ^Commands_Env,
	allocator := context.allocator,
) -> (
	Commands_Error,
	string,
) {
	_, sync := parameters_parser_get_switch(p, "sync")
	method: Maybe(File_Write_Method)
	if text, ok := parameters_parser_get_switch(p, "method"); ok {
		parsed, perr, pmsg := commands_parse_write_method(text, allocator)
		if perr != .None {
			return perr, pmsg
		}
		method = parsed
	}
	if werr, wmsg := commands_write_all_buffers(ctx, env, sync, method, allocator); werr != .None {
		return werr, wmsg
	}
	return commands_quit(p, ctx, env, false, allocator)
}

// commands_buffer switches to a buffer (C++ buffer_cmd).
commands_buffer :: proc(
	p: ^Parameters_Parser,
	ctx: ^Context,
	env: ^Commands_Env,
	allocator := context.allocator,
) -> (
	Commands_Error,
	string,
) {
	want := parameters_parser_positional(p, 0)
	buffer: ^Buffer
	if _, matching := parameters_parser_get_switch(p, "matching"); matching {
		re, re_err, _ := regex_make(want, {.Optimize}, allocator)
		if len(re_err) > 0 {
			defer delete(re_err, allocator)
			return commands_errorf("invalid regex: '{}'", {want}, allocator)
		}
		defer regex_destroy(&re)
		for buf in env.buffers.buffers {
			name := buffer_manager_buffer_name(buf)
			if regex_match_simple(name, &re) {
				buffer = buf
				break
			}
		}
		if buffer == nil {
			return commands_errorf("no such buffer '{}'", {want}, allocator)
		}
	} else {
		found, berr := buffer_manager_get(env.buffers, want)
		if berr != .None {
			return commands_errorf("no such buffer '{}'", {want}, allocator)
		}
		buffer = found
	}
	if buffer != context_buffer(ctx) {
		context_push_jump(ctx)
		if cerr := context_change_buffer(ctx, buffer); cerr != .None {
			return commands_errorf("buffer is locked", {}, allocator)
		}
	}
	return .None, ""
}

// commands_delete_buffer deletes a buffer (C++ delete_buffer).
commands_delete_buffer :: proc(
	p: ^Parameters_Parser,
	ctx: ^Context,
	env: ^Commands_Env,
	force: bool,
	allocator := context.allocator,
) -> (
	Commands_Error,
	string,
) {
	buffer := context_buffer(ctx)
	if parameters_parser_positional_count(p) > 0 {
		want := parameters_parser_positional(p, 0)
		found, berr := buffer_manager_get(env.buffers, want)
		if berr != .None {
			return commands_errorf("no such buffer '{}'", {want}, allocator)
		}
		buffer = found
	}
	if !force && .File in buffer.flags && buffer_is_modified(buffer) {
		return commands_errorf("buffer '{}' is modified", {buffer.display_name}, allocator)
	}
	if derr := buffer_manager_delete(env.buffers, buffer); derr != .None {
		return commands_errorf("buffer is locked", {}, allocator)
	}
	if ferr := context_forget_buffer(ctx, buffer); ferr != .None {
		return .Error, strings.clone(context_error_message(ferr), allocator)
	}
	return .None, ""
}

// commands_rename_buffer renames the current buffer (C++
// rename_buffer_cmd).
commands_rename_buffer :: proc(
	p: ^Parameters_Parser,
	ctx: ^Context,
	allocator := context.allocator,
) -> (
	Commands_Error,
	string,
) {
	_, scratch := parameters_parser_get_switch(p, "scratch")
	_, file := parameters_parser_get_switch(p, "file")
	if scratch && file {
		return commands_errorf("scratch and file are incompatible switches", {}, allocator)
	}
	buffer := context_buffer(ctx)
	if scratch {
		buffer.flags = buffer.flags - Buffer_Flags{.File, .New}
	}
	if file {
		buffer.flags = buffer.flags + Buffer_Flags{.File}
	}
	want := parameters_parser_positional(p, 0)
	target := want
	owned := false
	// Function scope: Odin defers fire at block end, so this must
	// not sit inside the if below (target outlives the block).
	defer if owned {
		delete(target, allocator)
	}
	if .File in buffer.flags {
		target = file_parse_filename(want, "", allocator)
		owned = true
	}
	if !buffer_set_name(buffer, target) {
		return commands_errorf(
			"unable to change buffer name to '{}': a buffer with this name already exists",
			{want},
			allocator,
		)
	}
	return .None, ""
}

// commands_arrange_buffers reorders the buffer list (C++
// arrange_buffers_cmd).
commands_arrange_buffers :: proc(
	p: ^Parameters_Parser,
	env: ^Commands_Env,
	allocator := context.allocator,
) -> (
	Commands_Error,
	string,
) {
	_, to_back := parameters_parser_get_switch(p, "back")
	if aerr := buffer_manager_arrange(
		env.buffers,
		parameters_parser_positionals_from(p, 0),
		to_back,
	); aerr != .None {
		return commands_errorf("no such buffer", {}, allocator)
	}
	return .None, ""
}

// commands_add_highlighter adds a highlighter (C++ add_highlighter_cmd).
commands_add_highlighter :: proc(
	p: ^Parameters_Parser,
	ctx: ^Context,
	env: ^Commands_Env,
	allocator := context.allocator,
) -> (
	Commands_Error,
	string,
) {
	path := parameters_parser_positional(p, 0)
	type := parameters_parser_positional(p, 1)
	count := parameters_parser_positional_count(p)
	hl_params := make([dynamic]string, 0, count, allocator)
	defer delete(hl_params)
	for i in 2 ..< count {
		append(&hl_params, parameters_parser_positional(p, i))
	}

	entry, rerr := highlighter_registry_get(env.highlighters, type)
	if rerr != .None {
		return commands_errorf("no such highlighter type: '{}'", {type}, allocator)
	}

	slash := -1
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '/' {
			slash = i
			break
		}
	}
	if slash < 0 {
		return commands_errorf("no parent in path", {}, allocator)
	}

	name := path[slash + 1:]
	auto_owned := ""
	// Function scope: Odin defers fire at block end (name aliases
	// auto_owned past the if below).
	defer if len(auto_owned) > 0 {
		delete(auto_owned, allocator)
	}
	if len(name) == 0 {
		parts := make([dynamic]string, 0, count, allocator)
		defer {
			for s in parts {
				delete(s, allocator)
			}
			delete(parts)
		}
		for i in 1 ..< count {
			append(&parts, string_utils_replace(
				parameters_parser_positional(p, i),
				"/",
				"<slash>",
				allocator,
			))
		}
		auto_owned = string_utils_join_char(parts[:], '_', false, allocator)
		name = auto_owned
	}

	root, parent, gerr, gmsg := commands_get_highlighter(
		ctx,
		env,
		path[:slash],
		allocator,
	)
	if gerr != .None {
		return gerr, gmsg
	}
	if parent.vtable == nil {
		return commands_errorf(
			"highlighter groups are unavailable (highlighters module not ported)",
			{},
			allocator,
		)
	}
	child := entry.factory(hl_params[:], parent, allocator)
	_, override := parameters_parser_get_switch(p, "override")
	if herr := highlighter_add_child(parent, name, child, override); herr != .None {
		if herr == .No_Children {
			return commands_errorf(
				"highlighter groups are unavailable (highlighters module not ported)",
				{},
				allocator,
			)
		}
		return commands_errorf("cannot add highlighter '{}'", {path}, allocator)
	}
	commands_redraw_relevant_clients(ctx, env, root)
	return .None, ""
}

// commands_remove_highlighter removes a highlighter (C++
// remove_highlighter_cmd).
commands_remove_highlighter :: proc(
	p: ^Parameters_Parser,
	ctx: ^Context,
	env: ^Commands_Env,
	allocator := context.allocator,
) -> (
	Commands_Error,
	string,
) {
	path := parameters_parser_positional(p, 0)
	if len(path) > 0 && path[len(path) - 1] == '/' {
		path = path[:len(path) - 1]
	}
	slash := -1
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '/' {
			slash = i
			break
		}
	}
	if slash < 0 {
		return .None, ""
	}
	root, parent, gerr, gmsg := commands_get_highlighter(ctx, env, path[:slash + 1], allocator)
	if gerr != .None {
		return gerr, gmsg
	}
	if parent.vtable == nil {
		return commands_errorf(
			"highlighter groups are unavailable (highlighters module not ported)",
			{},
			allocator,
		)
	}
	_ = highlighter_remove_child(parent, path[slash + 1:])
	commands_redraw_relevant_clients(ctx, env, root)
	return .None, ""
}

// commands_hook adds a hook (C++ add_hook_cmd).
commands_hook :: proc(
	p: ^Parameters_Parser,
	ctx: ^Context,
	env: ^Commands_Env,
	allocator := context.allocator,
) -> (
	Commands_Error,
	string,
) {
	hook, ok := enum_from_name(
		hook_manager_hook_descs[:],
		parameters_parser_positional(p, 1),
	)
	if !ok {
		return commands_errorf(
			"no such hook: '{}'",
			{parameters_parser_positional(p, 1)},
			allocator,
		)
	}
	filter, filter_err, _ := regex_make(
		parameters_parser_positional(p, 2),
		{.Optimize},
		allocator,
	)
	if len(filter_err) > 0 {
		defer delete(filter_err, allocator)
		return commands_errorf(
			"invalid regex: '{}'",
			{parameters_parser_positional(p, 2)},
			allocator,
		)
	}
	group := ""
	if g, has_group := parameters_parser_get_switch(p, "group"); has_group {
		group = g
	}
	extra := [1]rune{'-'}
	is_first := true
	for c in group {
		if !unicode_is_word(c, extra[:]) {
			regex_destroy(&filter)
			return commands_errorf("invalid group name '{}'", {group}, allocator)
		}
		if is_first {
			is_first = false
			if !unicode_is_word(c, nil) {
				regex_destroy(&filter)
				return commands_errorf("invalid group name '{}'", {group}, allocator)
			}
		}
	}
	flags := Hook_Flags{}
	if _, always := parameters_parser_get_switch(p, "always"); always {
		flags = flags + Hook_Flags{.Always}
	}
	if _, once := parameters_parser_get_switch(p, "once"); once {
		flags = flags + Hook_Flags{.Once}
	}
	scope, serr, smsg := commands_get_scope(
		parameters_parser_positional(p, 0),
		ctx,
		env,
		allocator,
	)
	if serr != .None {
		regex_destroy(&filter)
		return serr, smsg
	}
	herr, hmsg := hook_manager_add_hook(
		&scope.data.hooks,
		hook,
		group,
		flags,
		filter,
		parameters_parser_positional(p, 3),
		ctx,
	)
	if herr != .None {
		if herr == .Fail {
			return .Fail, hmsg
		}
		return .Error, hmsg
	}
	return .None, ""
}

// commands_remove_hooks removes hooks by group (C++ remove_hook_cmd).
commands_remove_hooks :: proc(
	p: ^Parameters_Parser,
	ctx: ^Context,
	env: ^Commands_Env,
	allocator := context.allocator,
) -> (
	Commands_Error,
	string,
) {
	scope, serr, smsg := commands_get_scope(
		parameters_parser_positional(p, 0),
		ctx,
		env,
		allocator,
	)
	if serr != .None {
		return serr, smsg
	}
	pattern, pattern_err, _ := regex_make(parameters_parser_positional(p, 1), {}, allocator)
	if len(pattern_err) > 0 {
		defer delete(pattern_err, allocator)
		return commands_errorf(
			"invalid regex: '{}'",
			{parameters_parser_positional(p, 1)},
			allocator,
		)
	}
	defer regex_destroy(&pattern)
	hook_manager_remove_hooks(&scope.data.hooks, &pattern)
	return .None, ""
}

// commands_trigger_user_hook runs the User hook (C++
// trigger_user_hook_cmd).
commands_trigger_user_hook :: proc(
	p: ^Parameters_Parser,
	ctx: ^Context,
	allocator := context.allocator,
) -> (
	Commands_Error,
	string,
) {
	hook_manager_run_hook(
		context_hooks(ctx),
		.User,
		parameters_parser_positional(p, 0),
		ctx,
	)
	return .None, ""
}

// commands_parse_define_params parses a define-command -params value:
// <count> or <min>..<max> (C++ define_command).
commands_parse_define_params :: proc(
	text: string,
	allocator := context.allocator,
) -> (
	min_count, max_count: int,
	err: Commands_Error,
	msg: string,
) {
	is_digits :: proc(s: string) -> bool {
		if len(s) == 0 {
			return false
		}
		for i := 0; i < len(s); i += 1 {
			if s[i] < '0' || s[i] > '9' {
				return false
			}
		}
		return true
	}
	if idx := strings.index(text, ".."); idx >= 0 {
		left := text[:idx]
		right := text[idx + 2:]
		if (len(left) > 0 && !is_digits(left)) ||
		   (len(right) > 0 && !is_digits(right)) {
			err, msg = commands_errorf("{} is not a number", {text}, allocator)
			return 0, 0, err, msg
		}
		min_count = 0
		max_count = max(int)
		if len(left) > 0 {
			min_count, _, _ = commands_str_to_int(left, allocator)
		}
		if len(right) > 0 {
			max_count, _, _ = commands_str_to_int(right, allocator)
		}
		return min_count, max_count, .None, ""
	}
	count, cerr, cmsg := commands_str_to_int(text, allocator)
	if cerr != .None {
		return 0, 0, cerr, cmsg
	}
	return count, count, .None, ""
}

// commands_all_identifier reports whether every rune is an identifier
// character (C++ all_of(x, is_identifier)).
commands_all_identifier :: proc(s: string) -> bool {
	for c in s {
		if !unicode_is_identifier(c) {
			return false
		}
	}
	return true
}

// commands_define_command defines a new command (C++ define_command).
commands_define_command :: proc(
	p: ^Parameters_Parser,
	ctx: ^Context,
	env: ^Commands_Env,
	allocator := context.allocator,
) -> (
	Commands_Error,
	string,
) {
	cmd_name := parameters_parser_positional(p, 0)
	if !commands_all_identifier(cmd_name) {
		return commands_errorf("invalid command name: '{}'", {cmd_name}, allocator)
	}
	if _, override := parameters_parser_get_switch(p, "override"); !override {
		if command_manager_command_defined(env.commands, cmd_name) {
			return commands_errorf("command '{}' already defined", {cmd_name}, allocator)
		}
	}
	flags := Command_Flags{}
	if _, hidden := parameters_parser_get_switch(p, "hidden"); hidden {
		flags = {.Hidden}
	}
	_, menu := parameters_parser_get_switch(p, "menu")
	completions_flags := Completion_Flags{}
	if menu {
		completions_flags = {.Menu}
	}

	forwards_params := false
	min_pos := 0
	max_pos := 0
	if text, ok := parameters_parser_get_switch(p, "params"); ok {
		forwards_params = true
		perr: Commands_Error
		pmsg: string
		min_pos, max_pos, perr, pmsg = commands_parse_define_params(text, allocator)
		if perr != .None {
			return perr, pmsg
		}
	}

	completer, cerr, cmsg := commands_parse_completion_switch(p, completions_flags, allocator)
	if cerr != .None {
		return cerr, cmsg
	}
	if menu && completer.call == nil {
		return commands_errorf("menu switch requires a completion switch", {}, allocator)
	}
	doc := ""
	if raw, ok := parameters_parser_get_switch(p, "docstring"); ok {
		trimmed, terr := string_utils_trim_indent(raw, allocator)
		if terr != .None {
			return commands_errorf("inconsistent indentation in the string", {}, allocator)
		}
		doc = trimmed
		defer delete(doc, allocator)
	}

	stored := new(Commands_Defined_Command, allocator)
	stored^ = Commands_Defined_Command{
		commands     = strings.clone(parameters_parser_positional(p, 1), allocator),
		takes_params = forwards_params,
		allocator    = allocator,
	}
	desc := commands_make_desc({}, {.Switches_As_Positional}, min_pos, max_pos, allocator)
	defer commands_destroy_desc(&desc)
	command_manager_register_command(
		env.commands,
		cmd_name,
		Command_Func{
			call    = commands_defined_command_call,
			data    = stored,
			destroy = commands_defined_command_destroy,
		},
		doc,
		desc,
		flags,
		Command_Helper{},
		completer,
	)
	return .None, ""
}

// commands_complete_command defines a command's completion (C++
// complete_command_cmd).
commands_complete_command :: proc(
	p: ^Parameters_Parser,
	env: ^Commands_Env,
	allocator := context.allocator,
) -> (
	Commands_Error,
	string,
) {
	_, menu := parameters_parser_get_switch(p, "menu")
	flags := Completion_Flags{}
	if menu {
		flags = {.Menu}
	}
	param := ""
	if parameters_parser_positional_count(p) >= 3 {
		param = parameters_parser_positional(p, 2)
	}
	completer, cerr, cmsg := commands_make_completer(
		parameters_parser_positional(p, 1),
		param,
		flags,
		allocator,
	)
	if cerr != .None {
		return cerr, cmsg
	}
	merr, mmsg := command_manager_set_command_completer(
		env.commands,
		parameters_parser_positional(p, 0),
		completer,
		allocator,
	)
	if merr != .None {
		if completer.destroy != nil {
			completer.destroy(completer.data, allocator)
		}
		return .Error, mmsg
	}
	return .None, ""
}

// commands_alias adds an alias (C++ alias_cmd).
commands_alias :: proc(
	p: ^Parameters_Parser,
	ctx: ^Context,
	env: ^Commands_Env,
	allocator := context.allocator,
) -> (
	Commands_Error,
	string,
) {
	if !command_manager_command_defined(env.commands, parameters_parser_positional(p, 2)) {
		return commands_errorf(
			"no such command: '{}'",
			{parameters_parser_positional(p, 2)},
			allocator,
		)
	}
	scope, serr, smsg := commands_get_scope(
		parameters_parser_positional(p, 0),
		ctx,
		env,
		allocator,
	)
	if serr != .None {
		return serr, smsg
	}
	_ = alias_registry_add(
		&scope.data.aliases,
		parameters_parser_positional(p, 1),
		parameters_parser_positional(p, 2),
	)
	return .None, ""
}

// commands_unalias removes an alias (C++ unalias_cmd).
commands_unalias :: proc(
	p: ^Parameters_Parser,
	ctx: ^Context,
	env: ^Commands_Env,
	allocator := context.allocator,
) -> (
	Commands_Error,
	string,
) {
	scope, serr, smsg := commands_get_scope(
		parameters_parser_positional(p, 0),
		ctx,
		env,
		allocator,
	)
	if serr != .None {
		return serr, smsg
	}
	aliases := &scope.data.aliases
	if parameters_parser_positional_count(p) == 3 &&
	   alias_registry_get(aliases, parameters_parser_positional(p, 1)) !=
		   parameters_parser_positional(p, 2) {
		return .None, ""
	}
	alias_registry_remove(aliases, parameters_parser_positional(p, 1))
	return .None, ""
}

// commands_file_error builds a file_access_error-style message. The
// errno detail is lost (the file module returns only File_Error).
commands_file_error :: proc(
	path: string,
	allocator := context.allocator,
) -> (
	Commands_Error,
	string,
) {
	return commands_errorf("{}: unable to open file", {path}, allocator)
}

// commands_echo displays a message (C++ echo_cmd).
commands_echo :: proc(
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
	env: ^Commands_Env,
	allocator := context.allocator,
) -> (
	Commands_Error,
	string,
) {
	message: string
	if text, ok := parameters_parser_get_switch(p, "quoting"); ok {
		quoting := String_Utils_Quoting.Raw
		switch text {
		case "raw":
			quoting = .Raw
		case "kakoune":
			quoting = .Kakoune
		case "shell":
			quoting = .Shell
		case:
			return commands_errorf("invalid quoting style: '{}'", {text}, allocator)
		}
		quoter := string_utils_quoter(quoting)
		parts := make([dynamic]string, 0, allocator)
		defer {
			for s in parts {
				delete(s, allocator)
			}
			delete(parts)
		}
		for i in 0 ..< parameters_parser_positional_count(p) {
			append(&parts, quoter(parameters_parser_positional(p, i), allocator))
		}
		message = string_utils_join_char(parts[:], ' ', false, allocator)
	} else {
		parts := commands_positionals(p, allocator)
		defer {
			for s in parts {
				delete(s, allocator)
			}
			delete(parts)
		}
		message = string_utils_join_char(parts[:], ' ', false, allocator)
	}

	if _, eol := parameters_parser_get_switch(p, "end-of-line"); eol {
		extended := strings.concatenate({message, "\n"}, allocator)
		delete(message, allocator)
		message = extended
	}

	if filename, ok := parameters_parser_get_switch(p, "to-file"); ok {
		defer delete(message, allocator)
		if ferr := file_write_to_file(filename, message); ferr != .None {
			return commands_file_error(filename, allocator)
		}
		return .None, ""
	}
	if script, ok := parameters_parser_get_switch(p, "to-shell-script"); ok {
		defer delete(message, allocator)
		res, rerr := shell_manager_eval_full(
			script,
			ctx,
			shell_ctx,
			message,
			Shell_Flags{},
			allocator,
		)
		defer shell_manager_eval_result_free(&res, allocator)
		if rerr != .None {
			return commands_errorf(
				"shell error: {}",
				{shell_manager_error_message(rerr)},
				allocator,
			)
		}
		return .None, ""
	}
	if _, debug := parameters_parser_get_switch(p, "debug"); debug {
		defer delete(message, allocator)
		commands_write_to_debug_buffer(message, env.buffers, allocator)
		return .None, ""
	}
	// The status line borrows the message (never freed).
	if _, markup := parameters_parser_get_switch(p, "markup"); markup {
		line, lerr := display_buffer_parse_line(message, context_faces(ctx), nil, allocator)
		if lerr != .None {
			delete(message, allocator)
			return commands_errorf("invalid markup", {}, allocator)
		}
		context_print_status_simple(ctx, line)
		return .None, ""
	}
	line := display_buffer_line_make_text(
		message,
		commands_status_face(ctx, "StatusLine"),
		allocator,
	)
	context_print_status_simple(ctx, line)
	return .None, ""
}

// commands_debug_info writes version info (C++ debug info).
commands_debug_info :: proc(
	ctx: ^Context,
	env: ^Commands_Env,
	allocator := context.allocator,
) {
	version := strings.concatenate({"version: ", commands_version}, allocator)
	defer delete(version, allocator)
	commands_write_to_debug_buffer(version, env.buffers, allocator)
	pid := commands_int_string(os.get_pid(), allocator)
	defer delete(pid, allocator)
	pid_line := strings.concatenate({"pid: ", pid}, allocator)
	defer delete(pid_line, allocator)
	commands_write_to_debug_buffer(pid_line, env.buffers, allocator)
	session := strings.concatenate({"session: ", env.server.session}, allocator)
	defer delete(session, allocator)
	commands_write_to_debug_buffer(session, env.buffers, allocator)
	when ODIN_DEBUG {
		commands_write_to_debug_buffer("build: debug", env.buffers, allocator)
	} else {
		commands_write_to_debug_buffer("build: release", env.buffers, allocator)
	}
}

// commands_debug_buffers lists buffers (C++ debug buffers).
commands_debug_buffers :: proc(
	env: ^Commands_Env,
	allocator := context.allocator,
) {
	commands_write_to_debug_buffer("Buffers:", env.buffers, allocator)
	for buf in env.buffers.buffers {
		desc := buffer_debug_description(buf, allocator)
		commands_write_to_debug_buffer(desc, env.buffers, allocator)
		delete(desc, allocator)
	}
}

// commands_debug_options lists options (C++ debug options).
commands_debug_options :: proc(
	ctx: ^Context,
	env: ^Commands_Env,
	allocator := context.allocator,
) {
	commands_write_to_debug_buffer("Options:", env.buffers, allocator)
	flat := option_manager_flatten_options(context_options(ctx), allocator)
	defer delete(flat)
	for opt in flat {
		hidden := ""
		if .Hidden in opt.desc.flags {
			hidden = " (hidden)"
		}
		value := option_manager_option_get_as_string(opt, .Kakoune, allocator)
		msg, ferr := format_format(
			" * {} \"{}{}: {}",
			{opt.desc.name, opt.desc.docstring, hidden, value},
			allocator,
		)
		assert(ferr == .None)
		delete(value, allocator)
		commands_write_to_debug_buffer(msg, env.buffers, allocator)
		delete(msg, allocator)
	}
}

// commands_debug_memory reports memory stats (C++ debug memory).
commands_debug_memory :: proc(env: ^Commands_Env, allocator := context.allocator) {
	commands_write_to_debug_buffer("Memory usage:", env.buffers, allocator)
	total: uint = 0
	for domain in Memory_Domain.Undefined ..< Memory_Domain.Count {
		stats := memory_stats[int(domain)]
		total += stats.allocated_bytes
		bytes := format_to_string_grouped(format_grouped(stats.allocated_bytes), allocator)
		active := commands_int_string(int(stats.allocation_count), allocator)
		lifetime := commands_int_string(int(stats.total_allocation_count), allocator)
		msg, ferr := format_format(
			"{}: {} bytes, {} active allocs, {} total allocs",
			{memory_domain_name(domain), bytes, active, lifetime},
			allocator,
		)
		assert(ferr == .None)
		delete(bytes, allocator)
		delete(active, allocator)
		delete(lifetime, allocator)
		commands_write_to_debug_buffer(msg, env.buffers, allocator)
		delete(msg, allocator)
	}
	grouped := format_to_string_grouped(format_grouped(total), allocator)
	msg, ferr := format_format("  Total: {}", {grouped}, allocator)
	assert(ferr == .None)
	delete(grouped, allocator)
	commands_write_to_debug_buffer(msg, env.buffers, allocator)
	delete(msg, allocator)
}

// commands_debug_faces lists faces (C++ debug faces).
commands_debug_faces :: proc(
	ctx: ^Context,
	env: ^Commands_Env,
	allocator := context.allocator,
) {
	commands_write_to_debug_buffer("Faces:", env.buffers, allocator)
	flat := face_registry_flatten(context_faces(ctx), allocator)
	defer face_registry_flatten_free(&flat, allocator)
	for e in flat {
		face := face_registry_resolve(context_faces(ctx), e.spec)
		rendered := face_registry_face_to_string(face, allocator)
		msg, ferr := format_format(" * {}: {}", {e.name, rendered}, allocator)
		assert(ferr == .None)
		delete(rendered, allocator)
		commands_write_to_debug_buffer(msg, env.buffers, allocator)
		delete(msg, allocator)
	}
}

// commands_debug_mappings lists key mappings (C++ debug mappings).
commands_debug_mappings :: proc(
	ctx: ^Context,
	env: ^Commands_Env,
	allocator := context.allocator,
) {
	commands_write_to_debug_buffer("Mappings:", env.buffers, allocator)
	keymaps := context_keymaps(ctx)
	modes := make([dynamic]string, 0, allocator)
	defer delete(modes)
	for mode in ([?]string{
		"normal",
		"insert",
		"menu",
		"prompt",
		"goto",
		"view",
		"user",
		"object",
		"combine",
	}) {
		append(&modes, mode)
	}
	user_modes := keymap_manager_user_modes(keymaps)
	for mode in user_modes^ {
		append(&modes, mode)
	}
	for mode in modes {
		parsed, perr, pmsg := commands_parse_keymap_mode(mode, user_modes^[:], allocator)
		if perr != .None {
			delete(pmsg, allocator)
			continue
		}
		mapped := keymap_manager_get_mapped_keys(keymaps, parsed, allocator)
		for key in mapped {
			mapping := keymap_manager_get_mapping(keymaps, key, parsed)
			if mapping == nil {
				continue
			}
			key_str := keys_to_string_key(key, allocator)
			keys := strings.builder_make(allocator)
			for k in mapping.keys {
				part := keys_to_string_key(k, allocator)
				strings.write_string(&keys, part)
				delete(part, allocator)
			}
			keys_str := strings.to_string(keys)
			atomic := ""
			if mapping.atomic {
				atomic = "(atomic)"
			}
			msg, ferr := format_format(
				" * {} {}: '{}' {} {}",
				{mode, key_str, keys_str, atomic, mapping.docstring},
				allocator,
			)
			assert(ferr == .None)
			delete(key_str, allocator)
			delete(keys_str, allocator)
			commands_write_to_debug_buffer(msg, env.buffers, allocator)
			delete(msg, allocator)
		}
		delete(mapped)
	}
}

// commands_debug_registers lists registers (C++ debug registers).
commands_debug_registers :: proc(
	ctx: ^Context,
	env: ^Commands_Env,
	allocator := context.allocator,
) {
	commands_write_to_debug_buffer("Register info:", env.buffers, allocator)
	for name, reg in env.registers.registers {
		content := register_manager_get_values(reg, ctx, allocator)
		if len(content) == 1 && len(content[0]) == 0 {
			continue
		}
		quoted := make([dynamic]string, 0, len(content), allocator)
		for c in content {
			append(&quoted, string_utils_quote(c, allocator))
		}
		joined := string_utils_join_str(quoted[:], "\n     = ", allocator)
		for q in quoted {
			delete(q, allocator)
		}
		delete(quoted)
		name_str := strings.builder_make(allocator)
		strings.write_rune(&name_str, name)
		name_owned := strings.to_string(name_str)
		msg, ferr := format_format(" * {} = {}", {name_owned, joined}, allocator)
		assert(ferr == .None)
		delete(name_owned, allocator)
		delete(joined, allocator)
		commands_write_to_debug_buffer(msg, env.buffers, allocator)
		delete(msg, allocator)
	}
}

// commands_debug dispatches debug subcommands (C++ debug_cmd).
commands_debug :: proc(
	p: ^Parameters_Parser,
	ctx: ^Context,
	env: ^Commands_Env,
	allocator := context.allocator,
) -> (
	Commands_Error,
	string,
) {
	what := parameters_parser_positional(p, 0)
	switch what {
	case "info":
		commands_debug_info(ctx, env, allocator)
	case "buffers":
		commands_debug_buffers(env, allocator)
	case "options":
		commands_debug_options(ctx, env, allocator)
	case "memory":
		commands_debug_memory(env, allocator)
	case "shared-strings":
		commands_write_to_debug_buffer(
			"shared strings: unavailable in the Odin port (builtin strings are not interned)",
			env.buffers,
			allocator,
		)
	case "profile-hash-maps":
		profile_hash_maps()
	case "faces":
		commands_debug_faces(ctx, env, allocator)
	case "mappings":
		commands_debug_mappings(ctx, env, allocator)
	case "regex":
		if parameters_parser_positional_count(p) != 2 {
			return commands_errorf("expected a regex", {}, allocator)
		}
		pattern := parameters_parser_positional(p, 1)
		re, re_err, _ := regex_make(pattern, {.Optimize}, allocator)
		if len(re_err) > 0 {
			defer delete(re_err, allocator)
			return commands_errorf("invalid regex: '{}'", {pattern}, allocator)
		}
		defer regex_destroy(&re)
		marks := commands_int_string(regex_mark_count(&re), allocator)
		defer delete(marks, allocator)
		msg, ferr := format_format(" * {} (captures: {})", {pattern, marks}, allocator)
		assert(ferr == .None)
		commands_write_to_debug_buffer(msg, env.buffers, allocator)
		delete(msg, allocator)
	case "registers":
		commands_debug_registers(ctx, env, allocator)
	case:
		return commands_errorf("no such debug command: '{}'", {what}, allocator)
	}
	return .None, ""
}

// commands_source executes a script file (C++ source_cmd).
commands_source :: proc(
	p: ^Parameters_Parser,
	ctx: ^Context,
	env: ^Commands_Env,
	allocator := context.allocator,
) -> (
	Commands_Error,
	string,
) {
	profile := false
	if opt, oerr := option_manager_get_option(context_options(ctx), "debug"); oerr == .None {
		if flags, ok := opt.value.(Option_types_Debug_Flags); ok {
			profile = .Profile in flags
		}
	}
	start := clock_now()

	parsed := file_parse_filename(parameters_parser_positional(p, 0), "", allocator)
	defer delete(parsed, allocator)
	path, rerr := file_real_path(parsed, allocator)
	if rerr != .None {
		return commands_file_error(parameters_parser_positional(p, 0), allocator)
	}
	defer delete(path, allocator)

	mapped, merr := file_mapped_file_open(path)
	if merr != .None {
		return commands_file_error(parameters_parser_positional(p, 0), allocator)
	}
	defer file_mapped_file_close(&mapped)
	content, verr := file_mapped_file_view(mapped)
	if verr != .None {
		return commands_file_error(parameters_parser_positional(p, 0), allocator)
	}

	params := make([dynamic]string, 0, allocator)
	defer delete(params)
	for i in 1 ..< parameters_parser_positional_count(p) {
		append(&params, parameters_parser_positional(p, i))
	}
	env_vars := make(Env_Var_Map, 1, allocator)
	source_key := strings.clone("source", allocator)
	source_val := strings.clone(path, allocator)
	env_vars[source_key] = source_val
	defer {
		delete(source_key, allocator)
		delete(source_val, allocator)
		delete(env_vars)
	}
	shell_ctx := Shell_Context{params = params[:], env_vars = env_vars}
	exec_err, exec_msg := command_manager_execute(
		command_manager_instance(),
		content,
		ctx,
		&shell_ctx,
		allocator,
	)
	if profile {
		microseconds := int(clock_diff(start, clock_now())) / 1000
		useconds := commands_int_string(microseconds, allocator)
		defer delete(useconds, allocator)
		msg, ferr := format_format(
			"sourcing '{}' took {} us",
			{parameters_parser_positional(p, 0), useconds},
			allocator,
		)
		assert(ferr == .None)
		commands_write_to_debug_buffer(msg, env.buffers, allocator)
		delete(msg, allocator)
	}
	if exec_err != .None {
		dbg, ferr := format_format(
			"{}:{}",
			{parameters_parser_positional(p, 0), exec_msg},
			allocator,
		)
		assert(ferr == .None)
		commands_write_to_debug_buffer(dbg, env.buffers, allocator)
		delete(dbg, allocator)
		if exec_err == .Fail {
			return .Fail, exec_msg
		}
		return .Error, exec_msg
	}
	return .None, ""
}

// commands_option_result maps an option operation outcome.
commands_option_result :: proc(
	oerr: Option_Manager_Error,
	detail: string,
	allocator := context.allocator,
) -> (
	Commands_Error,
	string,
) {
	if oerr == .None {
		// Detail is borrowed (option_manager's error texts are
		// static); never freed.
		return .None, ""
	}
	if len(detail) > 0 {
		return .Error, strings.clone(detail, allocator)
	}
	return .Error, strings.clone(option_manager_error_message(oerr), allocator)
}

// commands_set_option sets an option (C++ set_option_cmd).
commands_set_option :: proc(
	p: ^Parameters_Parser,
	ctx: ^Context,
	env: ^Commands_Env,
	allocator := context.allocator,
) -> (
	Commands_Error,
	string,
) {
	_, add := parameters_parser_get_switch(p, "add")
	_, remove := parameters_parser_get_switch(p, "remove")
	if add && remove {
		return commands_errorf("cannot add and remove at the same time", {}, allocator)
	}
	options, oerr, omsg := commands_get_options(
		parameters_parser_positional(p, 0),
		ctx,
		env,
		parameters_parser_positional(p, 1),
		allocator,
	)
	if oerr != .None {
		return oerr, omsg
	}
	opt, lerr := option_manager_get_local_option(
		options,
		parameters_parser_positional(p, 1),
		allocator,
	)
	if lerr != .None {
		return commands_option_result(lerr, "", allocator)
	}
	values := parameters_parser_positionals_from(p, 2)
	if add {
		serr, smsg := option_manager_option_add_from_strings(opt, values)
		return commands_option_result(serr, smsg, allocator)
	}
	if remove {
		serr, smsg := option_manager_option_remove_from_strings(opt, values)
		return commands_option_result(serr, smsg, allocator)
	}
	serr, smsg := option_manager_option_set_from_strings(opt, values)
	return commands_option_result(serr, smsg, allocator)
}

// commands_unset_option unsets an option (C++ unset_option_cmd).
commands_unset_option :: proc(
	p: ^Parameters_Parser,
	ctx: ^Context,
	env: ^Commands_Env,
	allocator := context.allocator,
) -> (
	Commands_Error,
	string,
) {
	options, oerr, omsg := commands_get_options(
		parameters_parser_positional(p, 0),
		ctx,
		env,
		parameters_parser_positional(p, 1),
		allocator,
	)
	if oerr != .None {
		return oerr, omsg
	}
	if options == &env.global.scope.data.options {
		return commands_errorf("cannot unset options in global scope", {}, allocator)
	}
	uerr := option_manager_unset_option(options, parameters_parser_positional(p, 1))
	return commands_option_result(uerr, "", allocator)
}

// commands_update_option updates an option (C++ update_option_cmd).
commands_update_option :: proc(
	p: ^Parameters_Parser,
	ctx: ^Context,
	env: ^Commands_Env,
	allocator := context.allocator,
) -> (
	Commands_Error,
	string,
) {
	options, oerr, omsg := commands_get_options(
		parameters_parser_positional(p, 0),
		ctx,
		env,
		parameters_parser_positional(p, 1),
		allocator,
	)
	if oerr != .None {
		return oerr, omsg
	}
	opt, lerr := option_manager_get_local_option(
		options,
		parameters_parser_positional(p, 1),
		allocator,
	)
	if lerr != .None {
		return commands_option_result(lerr, "", allocator)
	}
	uerr := option_manager_option_update(opt, ctx)
	return commands_option_result(uerr, "", allocator)
}

// commands_declare_option declares an option (C++ declare_option_cmd).
commands_declare_option :: proc(
	p: ^Parameters_Parser,
	env: ^Commands_Env,
	allocator := context.allocator,
) -> (
	Commands_Error,
	string,
) {
	flags := Option_Flags{}
	if _, hidden := parameters_parser_get_switch(p, "hidden"); hidden {
		flags = {.Hidden}
	}
	doc := ""
	owned_doc := false
	if raw, ok := parameters_parser_get_switch(p, "docstring"); ok {
		trimmed, terr := string_utils_trim_indent(raw, allocator)
		if terr != .None {
			return commands_errorf("inconsistent indentation in the string", {}, allocator)
		}
		doc = trimmed
		owned_doc = true
	}
	// Function scope: Odin defers fire at block end (doc is used by
	// the declare call below).
	defer if owned_doc {
		delete(doc, allocator)
	}
	reg := &env.global.global_data.option_registry
	type := parameters_parser_positional(p, 0)
	name := parameters_parser_positional(p, 1)
	value: Option_Value
	switch type {
	case "int":
		value = 0
	case "bool":
		value = false
	case "str":
		value = ""
	case "regex":
		value = Regex{}
	case "int-list":
		value = [dynamic]int{}
	case "str-list":
		value = [dynamic]string{}
	case "completions":
		value = Insert_Completer_Completion_List{}
	case "line-specs":
		value = Option_Timestamped_List(Line_And_Spec){}
	case "range-specs":
		value = Option_Timestamped_List(Range_And_String){}
	case "str-to-str-map":
		value = map[string]string{}
	case:
		return commands_errorf("no such option type: '{}'", {type}, allocator)
	}
	opt, derr := option_manager_registry_declare(reg, name, doc, value, flags, nil, allocator)
	if derr != .None {
		return commands_option_result(derr, "", allocator)
	}
	if parameters_parser_positional_count(p) > 2 {
		serr, smsg := option_manager_option_set_from_strings(
			opt,
			parameters_parser_positionals_from(p, 2),
		)
		return commands_option_result(serr, smsg, allocator)
	}
	return .None, ""
}

// commands_parse_keys parses a key description (C++ parse_keys).
commands_parse_keys :: proc(
	text: string,
	allocator := context.allocator,
) -> (
	Keys_Key_List,
	Commands_Error,
	string,
) {
	keys, kerr := keys_parse(text, allocator)
	if kerr != .None {
		delete(keys)
		return {}, commands_errorf("unable to parse keys '{}'", {text}, allocator)
	}
	return keys, .None, ""
}

// commands_map maps a key (C++ map_key_cmd).
commands_map :: proc(
	p: ^Parameters_Parser,
	ctx: ^Context,
	env: ^Commands_Env,
	allocator := context.allocator,
) -> (
	Commands_Error,
	string,
) {
	scope, serr, smsg := commands_get_scope(
		parameters_parser_positional(p, 0),
		ctx,
		env,
		allocator,
	)
	if serr != .None {
		return serr, smsg
	}
	keymaps := &scope.data.keymaps
	mode, merr, mmsg := commands_parse_keymap_mode(
		parameters_parser_positional(p, 1),
		keymap_manager_user_modes(keymaps)^[:],
		allocator,
	)
	if merr != .None {
		return merr, mmsg
	}
	key, kerr, kmsg := commands_parse_keys(parameters_parser_positional(p, 2), allocator)
	if kerr != .None {
		return kerr, kmsg
	}
	defer delete(key)
	if len(key) != 1 {
		return commands_errorf("only a single key can be mapped", {}, allocator)
	}
	mapping, merr2, mmsg2 := commands_parse_keys(
		parameters_parser_positional(p, 3),
		allocator,
	)
	if merr2 != .None {
		return merr2, mmsg2
	}
	defer delete(mapping)
	doc := ""
	if raw, ok := parameters_parser_get_switch(p, "docstring"); ok {
		trimmed, terr := string_utils_trim_indent(raw, allocator)
		if terr != .None {
			return commands_errorf("inconsistent indentation in the string", {}, allocator)
		}
		doc = trimmed
		defer delete(doc, allocator)
	}
	_, atomic := parameters_parser_get_switch(p, "atomic")
	keymap_manager_map_key(keymaps, key[0], mode, mapping[:], doc, atomic)
	return .None, ""
}

// commands_unmap unmaps keys (C++ unmap_key_cmd).
commands_unmap :: proc(
	p: ^Parameters_Parser,
	ctx: ^Context,
	env: ^Commands_Env,
	allocator := context.allocator,
) -> (
	Commands_Error,
	string,
) {
	scope, serr, smsg := commands_get_scope(
		parameters_parser_positional(p, 0),
		ctx,
		env,
		allocator,
	)
	if serr != .None {
		return serr, smsg
	}
	keymaps := &scope.data.keymaps
	mode, merr, mmsg := commands_parse_keymap_mode(
		parameters_parser_positional(p, 1),
		keymap_manager_user_modes(keymaps)^[:],
		allocator,
	)
	if merr != .None {
		return merr, mmsg
	}
	if parameters_parser_positional_count(p) == 2 {
		keymap_manager_unmap_keys(keymaps, mode)
		return .None, ""
	}
	key, kerr, kmsg := commands_parse_keys(parameters_parser_positional(p, 2), allocator)
	if kerr != .None {
		return kerr, kmsg
	}
	defer delete(key)
	if len(key) != 1 {
		return commands_errorf("only a single key can be unmapped", {}, allocator)
	}
	mapping := keymap_manager_get_mapping(keymaps, key[0], mode)
	if mapping == nil {
		return .None, ""
	}
	if parameters_parser_positional_count(p) >= 4 {
		expected, eerr, emsg := commands_parse_keys(
			parameters_parser_positional(p, 3),
			allocator,
		)
		if eerr != .None {
			return eerr, emsg
		}
		defer delete(expected)
		if len(expected) != len(mapping.keys) {
			return .None, ""
		}
		for k, i in expected {
			if k != mapping.keys[i] {
				return .None, ""
			}
		}
	}
	keymap_manager_unmap_key(keymaps, key[0], mode)
	return .None, ""
}

// commands_execute_keys_body handles keys for one wrapped context
// (C++ execute_keys_cmd lambda).
commands_execute_keys_body :: proc(
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
	env: ^Commands_Env,
	allocator: mem.Allocator,
) -> (
	Commands_Error,
	string,
) {
	_, with_maps := parameters_parser_get_switch(p, "with-maps")
	_, with_hooks := parameters_parser_get_switch(p, "with-hooks")
	maps_guard := utils_scoped_bool_make(context_keymaps_disabled(ctx), !with_maps)
	defer utils_scoped_bool_release(&maps_guard)
	hooks_guard := utils_scoped_bool_make(context_hooks_disabled(ctx), !with_hooks)
	defer utils_scoped_bool_release(&hooks_guard)

	handler := context_input_handler(ctx)
	for i in 0 ..< parameters_parser_positional_count(p) {
		keys, kerr, kmsg := commands_parse_keys(
			parameters_parser_positional(p, i),
			allocator,
		)
		if kerr != .None {
			return kerr, kmsg
		}
		for key in keys {
			input_handler_handle_key(handler, key)
		}
		delete(keys)
	}
	return .None, ""
}

// commands_execute_keys executes keys (C++ execute_keys_cmd).
commands_execute_keys :: proc(
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
	env: ^Commands_Env,
	allocator := context.allocator,
) -> (
	Commands_Error,
	string,
) {
	return commands_context_wrap(
		p,
		ctx,
		shell_ctx,
		env,
		"/\"|^@:",
		commands_execute_keys_body,
		allocator,
	)
}

// commands_evaluate_commands_body runs commands for one wrapped
// context (C++ evaluate_commands_cmd lambda).
commands_evaluate_commands_body :: proc(
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
	env: ^Commands_Env,
	allocator: mem.Allocator,
) -> (
	Commands_Error,
	string,
) {
	_, no_hooks_switch := parameters_parser_get_switch(p, "no-hooks")
	disabled := utils_nested_bool_is_set(context_hooks_disabled(ctx)^) || no_hooks_switch
	guard := utils_scoped_bool_make(context_hooks_disabled(ctx), disabled)
	defer utils_scoped_bool_release(&guard)

	local := scope_local_make(ctx, context_scope(ctx), allocator)
	defer scope_local_destroy(local, allocator)

	if _, verbatim := parameters_parser_get_switch(p, "verbatim"); verbatim {
		params := commands_positionals(p, allocator)
		defer {
			for s in params {
				delete(s, allocator)
			}
			delete(params)
		}
		exec_err, exec_msg := command_manager_execute_single_command(
			command_manager_instance(),
			params[:],
			ctx,
			shell_ctx,
			allocator,
		)
		if exec_err != .None {
			if exec_err == .Fail {
				return .Fail, exec_msg
			}
			return .Error, exec_msg
		}
		return .None, ""
	}
	joined := commands_join_positionals(p, allocator)
	defer delete(joined, allocator)
	exec_err, exec_msg := command_manager_execute(
		command_manager_instance(),
		joined,
		ctx,
		shell_ctx,
		allocator,
	)
	if exec_err != .None {
		if exec_err == .Fail {
			return .Fail, exec_msg
		}
		return .Error, exec_msg
	}
	return .None, ""
}

// commands_evaluate_commands evaluates commands (C++
// evaluate_commands_cmd).
commands_evaluate_commands :: proc(
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
	env: ^Commands_Env,
	allocator := context.allocator,
) -> (
	Commands_Error,
	string,
) {
	return commands_context_wrap(
		p,
		ctx,
		shell_ctx,
		env,
		"",
		commands_evaluate_commands_body,
		allocator,
	)
}

// commands_prompt prompts for input (C++ prompt_cmd).
commands_prompt :: proc(
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
	allocator := context.allocator,
) -> (
	Commands_Error,
	string,
) {
	_, menu := parameters_parser_get_switch(p, "menu")
	flags := Completion_Flags{}
	if menu {
		flags = {.Menu}
	}
	completer, cerr, cmsg := commands_parse_completion_switch(p, flags, allocator)
	if cerr != .None {
		return cerr, cmsg
	}
	prompt_flags := Prompt_Flags{}
	if _, password := parameters_parser_get_switch(p, "password"); password {
		prompt_flags = {.Password}
	}
	init := ""
	if text, ok := parameters_parser_get_switch(p, "init"); ok {
		init = text
	}

	prompt_completer := Prompt_Completer{}
	if completer.call != nil {
		adapter := new(Commands_Prompt_Completer, allocator)
		adapter^ = Commands_Prompt_Completer{completer = completer, allocator = allocator}
		prompt_completer = Prompt_Completer{
			call    = commands_prompt_completer_call,
			data    = adapter,
			destroy = commands_prompt_completer_destroy,
		}
	}
	on_change := ""
	if text, ok := parameters_parser_get_switch(p, "on-change"); ok {
		on_change = text
	}
	on_abort := ""
	if text, ok := parameters_parser_get_switch(p, "on-abort"); ok {
		on_abort = text
	}
	callback_data := new(Commands_Prompt_Callback, allocator)
	callback_data^ = Commands_Prompt_Callback{
		command   = strings.clone(parameters_parser_positional(p, 1), allocator),
		on_change = strings.clone(on_change, allocator),
		on_abort  = strings.clone(on_abort, allocator),
		params    = commands_clone_shell_params(shell_ctx.params, allocator),
		env_vars  = commands_clone_env_vars(&shell_ctx.env_vars, allocator),
		allocator = allocator,
	}
	input_handler_prompt(
		context_input_handler(ctx),
		parameters_parser_positional(p, 0),
		init,
		"",
		commands_status_face(ctx, "Prompt"),
		prompt_flags,
		'_',
		prompt_completer,
		Prompt_Callback{
			call    = commands_prompt_callback_call,
			data    = callback_data,
			destroy = commands_prompt_callback_destroy,
		},
	)
	return .None, ""
}

// commands_on_key waits for a key (C++ on_key_cmd).
commands_on_key :: proc(
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
	allocator := context.allocator,
) -> (
	Commands_Error,
	string,
) {
	mode_name := "on-key"
	if text, ok := parameters_parser_get_switch(p, "mode-name"); ok {
		mode_name = text
	}
	callback_data := new(Commands_On_Key_Callback, allocator)
	callback_data^ = Commands_On_Key_Callback{
		command   = strings.clone(parameters_parser_positional(p, 0), allocator),
		params    = commands_clone_shell_params(shell_ctx.params, allocator),
		env_vars  = commands_clone_env_vars(&shell_ctx.env_vars, allocator),
		allocator = allocator,
	}
	input_handler_on_next_key(
		context_input_handler(ctx),
		mode_name,
		.None,
		Key_Callback{
			call    = commands_on_key_callback_call,
			data    = callback_data,
			destroy = commands_on_key_callback_destroy,
		},
	)
	return .None, ""
}

// commands_info shows an info box (C++ info_cmd).
commands_info :: proc(
	p: ^Parameters_Parser,
	ctx: ^Context,
	allocator := context.allocator,
) -> (
	Commands_Error,
	string,
) {
	if !context_has_client(ctx) {
		return .None, ""
	}
	_, has_anchor := parameters_parser_get_switch(p, "anchor")
	style := User_Interface_Info_Style.Prompt
	if has_anchor {
		style = .Inline
	}
	if text, ok := parameters_parser_get_switch(p, "style"); ok {
		switch text {
		case "above":
			style = .Inline_Above
		case "below":
			style = .Inline_Below
		case "menu":
			style = .Menu_Doc
		case "modal":
			style = .Modal
		case:
			return commands_errorf("invalid style: '{}'", {text}, allocator)
		}
	}
	client := context_client(ctx)
	client_info_hide(client, style == .Modal)
	if parameters_parser_positional_count(p) == 0 {
		return .None, ""
	}
	pos := Coord_Buffer{}
	if text, ok := parameters_parser_get_switch(p, "anchor"); ok {
		dot := strings.index_byte(text, '.')
		if dot < 0 {
			return commands_errorf("expected <line>.<column> for anchor", {}, allocator)
		}
		line, lerr, lmsg := commands_str_to_int(text[:dot], allocator)
		if lerr != .None {
			return lerr, lmsg
		}
		column, cerr, cmsg := commands_str_to_int(text[dot + 1:], allocator)
		if cerr != .None {
			return cerr, cmsg
		}
		pos = Coord_Buffer{line = Coord_Line(line - 1), column = Coord_Byte(column - 1)}
	}
	title := ""
	if text, ok := parameters_parser_get_switch(p, "title"); ok {
		title = text
	}
	content := parameters_parser_positional(p, 0)
	if _, markup := parameters_parser_get_switch(p, "markup"); markup {
		parsed_title, terr := display_buffer_parse_line(title, context_faces(ctx), nil, allocator)
		if terr != .None {
			return commands_errorf("invalid markup", {}, allocator)
		}
		parsed_content, cerr := display_buffer_parse_line_list(
			content,
			context_faces(ctx),
			nil,
			allocator,
		)
		if cerr != .None {
			return commands_errorf("invalid markup", {}, allocator)
		}
		client_info_show(client, parsed_title, parsed_content, pos, style)
		return .None, ""
	}
	client_info_show_string(client, title, content, pos, style)
	return .None, ""
}

// commands_try runs commands with catch handlers (C++ try_catch_cmd).
commands_try :: proc(
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
	allocator := context.allocator,
) -> (
	Commands_Error,
	string,
) {
	count := parameters_parser_positional_count(p)
	if count % 2 != 1 {
		return commands_errorf("wrong argument count", {}, allocator)
	}
	for i := 1; i < count; i += 2 {
		if parameters_parser_positional(p, i) != "catch" {
			return commands_errorf(
				"usage: try <commands> [catch <on error commands>]...",
				{},
				allocator,
			)
		}
	}
	m := command_manager_instance()
	have_error_ctx := false
	error_ctx := Shell_Context{}
	defer if have_error_ctx {
		commands_destroy_shell_context(&error_ctx, allocator)
	}
	for i := 0; i < count; i += 2 {
		active := shell_ctx
		if have_error_ctx {
			active = &error_ctx
		}
		if i == 0 || i < count - 1 {
			exec_err, exec_msg := command_manager_execute(
				m,
				parameters_parser_positional(p, i),
				ctx,
				active,
				allocator,
			)
			if exec_err == .None {
				return .None, ""
			}
			if have_error_ctx {
				commands_destroy_shell_context(&error_ctx, allocator)
			}
			error_ctx = commands_clone_shell_context(shell_ctx, allocator)
			have_error_ctx = true
			if old, ok := error_ctx.env_vars["error"]; ok {
				delete(old, allocator)
				error_ctx.env_vars["error"] = exec_msg
			} else {
				error_ctx.env_vars[strings.clone("error", allocator)] = exec_msg
			}
		} else {
			exec_err, exec_msg := command_manager_execute(
				m,
				parameters_parser_positional(p, i),
				ctx,
				active,
				allocator,
			)
			if exec_err != .None {
				if exec_err == .Fail {
					return .Fail, exec_msg
				}
				return .Error, exec_msg
			}
			return .None, ""
		}
	}
	return .None, ""
}

// commands_clone_shell_params clones shell params.
commands_clone_shell_params :: proc(
	params: []string,
	allocator := context.allocator,
) -> [dynamic]string {
	res := make([dynamic]string, len(params), allocator)
	for s, i in params {
		res[i] = strings.clone(s, allocator)
	}
	return res
}

// commands_clone_env_vars clones an env var map.
commands_clone_env_vars :: proc(
	vars: ^Env_Var_Map,
	allocator := context.allocator,
) -> Env_Var_Map {
	res := make(Env_Var_Map, len(vars^), allocator)
	for k, v in vars^ {
		res[strings.clone(k, allocator)] = strings.clone(v, allocator)
	}
	return res
}

// commands_clone_shell_context clones a shell context (C++
// CapturedShellContext).
commands_clone_shell_context :: proc(
	sc: ^Shell_Context,
	allocator := context.allocator,
) -> Shell_Context {
	return Shell_Context{
		params   = commands_clone_shell_params(sc.params, allocator)[:],
		env_vars = commands_clone_env_vars(&sc.env_vars, allocator),
	}
}

// commands_destroy_shell_context frees a cloned shell context.
commands_destroy_shell_context :: proc(sc: ^Shell_Context, allocator := context.allocator) {
	for s in sc.params {
		delete(s, allocator)
	}
	delete(sc.params)
	for k, v in sc.env_vars {
		delete(k, allocator)
		delete(v, allocator)
	}
	delete(sc.env_vars)
	sc^ = {}
}

// commands_face_error maps a face registry outcome.
commands_face_error :: proc(
	ferr: Face_Registry_Error,
	name: string,
	allocator := context.allocator,
) -> (
	Commands_Error,
	string,
) {
	switch ferr {
	case .None:
		return .None, ""
	case .Invalid_Description, .Invalid_Color:
		return commands_errorf(
			"invalid face description, expected [<fg>][,<bg>[,<underline>]][+<attr>][@base] or just [base]",
			{},
			allocator,
		)
	case .Unknown_Attribute:
		return commands_errorf("no such face attribute", {}, allocator)
	case .Invalid_Name:
		return commands_errorf("invalid face name: '{}'", {name}, allocator)
	case .Already_Defined:
		return commands_errorf("face '{}' already defined", {name}, allocator)
	case .Face_Cycle:
		return commands_errorf("face cycle detected", {}, allocator)
	}
	unreachable()
}

// commands_set_face sets a face (C++ set_face_cmd).
commands_set_face :: proc(
	p: ^Parameters_Parser,
	ctx: ^Context,
	env: ^Commands_Env,
	allocator := context.allocator,
) -> (
	Commands_Error,
	string,
) {
	scope, serr, smsg := commands_get_scope(
		parameters_parser_positional(p, 0),
		ctx,
		env,
		allocator,
	)
	if serr != .None {
		return serr, smsg
	}
	ferr := face_registry_add(
		&scope.data.faces,
		parameters_parser_positional(p, 1),
		parameters_parser_positional(p, 2),
		true,
	)
	if ferr != .None {
		return commands_face_error(ferr, parameters_parser_positional(p, 1), allocator)
	}
	for client in env.clients.clients {
		client_force_redraw(client)
	}
	return .None, ""
}

// commands_unset_face removes a face (C++ unset_face_cmd).
commands_unset_face :: proc(
	p: ^Parameters_Parser,
	ctx: ^Context,
	env: ^Commands_Env,
	allocator := context.allocator,
) -> (
	Commands_Error,
	string,
) {
	scope, serr, smsg := commands_get_scope(
		parameters_parser_positional(p, 0),
		ctx,
		env,
		allocator,
	)
	if serr != .None {
		return serr, smsg
	}
	face_registry_remove(&scope.data.faces, parameters_parser_positional(p, 1))
	return .None, ""
}

// commands_rename_client renames the client (C++ rename_client_cmd).
commands_rename_client :: proc(
	p: ^Parameters_Parser,
	ctx: ^Context,
	env: ^Commands_Env,
	allocator := context.allocator,
) -> (
	Commands_Error,
	string,
) {
	name := parameters_parser_positional(p, 0)
	if !commands_all_identifier(name) {
		return commands_errorf("invalid client name: '{}'", {name}, allocator)
	}
	if client_manager_client_name_exists(env.clients, name) && context_name(ctx) != name {
		return commands_errorf("client name '{}' is not unique", {name}, allocator)
	}
	context_set_name(ctx, name)
	return .None, ""
}

// commands_set_register sets a register (C++ set_register_cmd).
commands_set_register :: proc(
	p: ^Parameters_Parser,
	ctx: ^Context,
	env: ^Commands_Env,
	allocator := context.allocator,
) -> (
	Commands_Error,
	string,
) {
	reg, rerr := register_manager_get_by_name(
		env.registers,
		parameters_parser_positional(p, 0),
	)
	if rerr != .None {
		return commands_errorf(
			"no such register: '{}'",
			{parameters_parser_positional(p, 0)},
			allocator,
		)
	}
	register_manager_set(reg, ctx, parameters_parser_positionals_from(p, 1))
	return .None, ""
}

// commands_selection_error maps a selection parse failure.
commands_selection_error :: proc(
	serr: Selection_Error,
	allocator := context.allocator,
) -> (
	Commands_Error,
	string,
) {
	switch serr {
	case .None:
		return .None, ""
	case .Invalid_Format:
		return commands_errorf("invalid selection description", {}, allocator)
	case .Invalid_Coordinate:
		return commands_errorf("selection coordinate out of buffer", {}, allocator)
	case .Invalid_Timestamp:
		return commands_errorf("selections timestamp is newer than the buffer", {}, allocator)
	case .Empty_Description:
		return commands_errorf("empty selection description list", {}, allocator)
	case .Invalid_Main_Index:
		return commands_errorf("selection main index out of range", {}, allocator)
	case .Format_Failed:
		return commands_errorf("internal formatting failure", {}, allocator)
	}
	unreachable()
}

// commands_select sets the selections (C++ select_cmd).
commands_select :: proc(
	p: ^Parameters_Parser,
	ctx: ^Context,
	allocator := context.allocator,
) -> (
	Commands_Error,
	string,
) {
	buffer := context_buffer(ctx)
	timestamp := buffer_timestamp(buffer)
	if text, ok := parameters_parser_get_switch(p, "timestamp"); ok {
		if v, vok := string_utils_str_to_int_ifp(text); vok {
			timestamp = v
		}
	}
	column_type := Column_Type.Byte
	if _, codepoint := parameters_parser_get_switch(p, "codepoint"); codepoint {
		column_type = .Codepoint
	} else if _, display_column := parameters_parser_get_switch(p, "display-column"); display_column {
		column_type = .Display_Column
	}
	tabstop := Coord_Column(-1)
	if opt, oerr := option_manager_get_option(context_options(ctx), "tabstop"); oerr == .None {
		if v, ok := opt.value.(int); ok {
			tabstop = Coord_Column(v)
		}
	}
	edition := context_scoped_selection_edition_make(ctx)
	defer context_scoped_selection_edition_destroy(&edition)
	list, serr := selection_list_from_strings(
		buffer,
		column_type,
		parameters_parser_positionals_from(p, 0),
		timestamp,
		0,
		tabstop,
		allocator,
	)
	if serr != .None {
		return commands_selection_error(serr, allocator)
	}
	target := context_selections_write_only(ctx)
	selection_list_destroy(target)
	target^ = list
	return .None, ""
}

// commands_change_directory changes the working directory (C++
// change_directory_cmd).
commands_change_directory :: proc(
	p: ^Parameters_Parser,
	ctx: ^Context,
	env: ^Commands_Env,
	allocator := context.allocator,
) -> (
	Commands_Error,
	string,
) {
	target := "~"
	if parameters_parser_positional_count(p) == 1 {
		target = parameters_parser_positional(p, 0)
	}
	parsed := file_parse_filename(target, "", allocator)
	defer delete(parsed, allocator)
	path, rerr := file_real_path(parsed, allocator)
	if rerr != .None {
		return commands_errorf("unable to change to directory: '{}'", {target}, allocator)
	}
	defer delete(path, allocator)
	if cerr := os.change_directory(path); cerr != os.ERROR_NONE {
		return commands_errorf("unable to change to directory: '{}'", {target}, allocator)
	}
	for buf in env.buffers.buffers {
		buffer_update_display_name(buf)
	}
	hook_manager_run_hook(context_hooks(ctx), .Enter_Directory, path, ctx)
	return .None, ""
}

// commands_rename_session renames the session (C++ rename_session_cmd).
commands_rename_session :: proc(
	p: ^Parameters_Parser,
	ctx: ^Context,
	env: ^Commands_Env,
	allocator := context.allocator,
) -> (
	Commands_Error,
	string,
) {
	want := parameters_parser_positional(p, 0)
	old := strings.clone(env.server.session, allocator)
	defer delete(old, allocator)
	renamed, _ := remote_server_rename_session(env.server, want)
	if !renamed {
		return commands_errorf(
			"unable to rename current session: '{}' may be already in use",
			{want},
			allocator,
		)
	}
	param, ferr := format_format("{}:{}", {old, env.server.session}, allocator)
	assert(ferr == .None)
	defer delete(param, allocator)
	hook_manager_run_hook(context_hooks(ctx), .Session_Renamed, param, ctx)
	return .None, ""
}

// commands_fail raises an error (C++ fail_cmd).
commands_fail :: proc(
	p: ^Parameters_Parser,
	allocator := context.allocator,
) -> (
	Commands_Error,
	string,
) {
	return .Fail, commands_join_positionals(p, allocator)
}

// commands_declare_user_mode declares a user mode (C++
// declare_user_mode_cmd).
commands_declare_user_mode :: proc(
	p: ^Parameters_Parser,
	ctx: ^Context,
	allocator := context.allocator,
) -> (
	Commands_Error,
	string,
) {
	name := parameters_parser_positional(p, 0)
	switch keymap_manager_add_user_mode(context_keymaps(ctx), name) {
	case .None:
		return .None, ""
	case .Regular_Mode:
		return commands_errorf("'{}' is already a regular mode", {name}, allocator)
	case .Already_Defined:
		return commands_errorf("user mode '{}' already defined", {name}, allocator)
	case .Invalid_Name:
		return commands_errorf("invalid mode name: '{}'", {name}, allocator)
	}
	unreachable()
}

// commands_enter_user_mode enters a user mode for the next key (C++
// enter_user_mode_cmd).
commands_enter_user_mode :: proc(
	p: ^Parameters_Parser,
	ctx: ^Context,
	allocator := context.allocator,
) -> (
	Commands_Error,
	string,
) {
	_, lock := parameters_parser_get_switch(p, "lock")
	mode, merr, mmsg := commands_parse_keymap_mode(
		parameters_parser_positional(p, 0),
		keymap_manager_user_modes(context_keymaps(ctx))^[:],
		allocator,
	)
	if merr != .None {
		return merr, mmsg
	}
	count := 0
	if text, ok := parameters_parser_get_switch(p, "count"); ok {
		if v, vok := string_utils_str_to_int_ifp(text); vok {
			count = v
		}
	}
	reg := rune(0)
	if text, ok := parameters_parser_get_switch(p, "register"); ok {
		if len(text) > 0 {
			for c in text {
				reg = c
				break
			}
		}
	}
	commands_enter_user_mode_impl(
		ctx,
		Normal_Params{count = count, reg = reg},
		parameters_parser_positional(p, 0),
		mode,
		lock,
		allocator,
	)
	return .None, ""
}

// commands_provide_module declares a module (C++ provide_module_cmd).
commands_provide_module :: proc(
	p: ^Parameters_Parser,
	env: ^Commands_Env,
	allocator := context.allocator,
) -> (
	Commands_Error,
	string,
) {
	module_name := parameters_parser_positional(p, 0)
	if !commands_all_identifier(module_name) {
		return commands_errorf("invalid module name: '{}'", {module_name}, allocator)
	}
	if _, override := parameters_parser_get_switch(p, "override"); !override {
		if command_manager_module_defined(env.commands, module_name) {
			return commands_errorf("module '{}' already defined", {module_name}, allocator)
		}
	}
	merr, mmsg := command_manager_register_module(
		env.commands,
		module_name,
		parameters_parser_positional(p, 1),
		allocator,
	)
	if merr != .None {
		return .Error, mmsg
	}
	return .None, ""
}

// commands_require_module loads a module (C++ require_module_cmd).
commands_require_module :: proc(
	p: ^Parameters_Parser,
	ctx: ^Context,
	env: ^Commands_Env,
	allocator := context.allocator,
) -> (
	Commands_Error,
	string,
) {
	merr, mmsg := command_manager_load_module(
		env.commands,
		parameters_parser_positional(p, 0),
		ctx,
		allocator,
	)
	if merr != .None {
		if merr == .Fail {
			return .Fail, mmsg
		}
		return .Error, mmsg
	}
	return .None, ""
}

// ---------------------------------------------------------------------------
// Callback data for defined commands, prompt, on-key and user modes.
// ---------------------------------------------------------------------------

// Commands_Defined_Command is the data of a define-command command.
Commands_Defined_Command :: struct {
	commands:     string,
	takes_params: bool,
	allocator:    mem.Allocator,
}

commands_defined_command_call :: proc(
	data: rawptr,
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
) {
	stored := cast(^Commands_Defined_Command)data
	allocator := ctx.allocator
	local := scope_local_make(ctx, context_scope(ctx), allocator)
	defer scope_local_destroy(local, allocator)
	params: []string
	owned: [dynamic]string
	// Function scope: Odin defers fire at block end (params aliases
	// owned past the if below).
	defer if owned != nil {
		for s in owned {
			delete(s, allocator)
		}
		delete(owned)
	}
	if stored.takes_params {
		owned = commands_positionals(p, allocator)
		params = owned[:]
	}
	sc := Shell_Context{params = params, env_vars = shell_ctx.env_vars}
	exec_err, exec_msg := command_manager_execute(
		command_manager_instance(),
		stored.commands,
		ctx,
		&sc,
		allocator,
	)
	if exec_err == .Fail {
		commands_report(.Fail, exec_msg, ctx)
	} else if exec_err != .None {
		commands_report(.Error, exec_msg, ctx)
	}
}

commands_defined_command_destroy :: proc(data: rawptr, allocator: mem.Allocator) {
	stored := cast(^Commands_Defined_Command)data
	delete(stored.commands, stored.allocator)
	free(stored, stored.allocator)
}

// Commands_Prompt_Completer adapts a Command_Completer to prompt
// completion (C++ PromptCompleterAdapter).
Commands_Prompt_Completer :: struct {
	completer: Command_Completer,
	allocator:  mem.Allocator,
}

commands_prompt_completer_call :: proc(
	data: rawptr,
	ctx: ^Context,
	text: string,
	cursor_pos: Units_ByteCount,
	allocator: mem.Allocator,
) -> Completions {
	adapter := cast(^Commands_Prompt_Completer)data
	params := []string{text}
	return adapter.completer.call(
		adapter.completer.data,
		ctx,
		params,
		0,
		cursor_pos,
		allocator,
	)
}

commands_prompt_completer_destroy :: proc(data: rawptr, allocator: mem.Allocator) {
	adapter := cast(^Commands_Prompt_Completer)data
	if adapter.completer.destroy != nil {
		adapter.completer.destroy(adapter.completer.data, adapter.allocator)
	}
	free(adapter, adapter.allocator)
}

// Commands_Prompt_Callback is the data of a prompt callback (C++
// prompt_cmd lambda with CapturedShellContext).
Commands_Prompt_Callback :: struct {
	command:   string,
	on_change: string,
	on_abort:  string,
	params:    [dynamic]string,
	env_vars:  Env_Var_Map,
	allocator: mem.Allocator,
}

commands_prompt_callback_call :: proc(
	data: rawptr,
	text: string,
	event: Prompt_Event,
	ctx: ^Context,
) {
	stored := cast(^Commands_Prompt_Callback)data
	if (event == .Abort && len(stored.on_abort) == 0) ||
	   (event == .Change && len(stored.on_change) == 0) {
		return
	}
	cmd := stored.command
	switch event {
	case .Validate:
		cmd = stored.command
	case .Change:
		cmd = stored.on_change
	case .Abort:
		cmd = stored.on_abort
	}
	if prev, ok := stored.env_vars["text"]; ok {
		for k in stored.env_vars {
			if k == "text" {
				delete(k, stored.allocator)
				break
			}
		}
		delete(prev, stored.allocator)
		delete_key(&stored.env_vars, "text")
	}
	key := strings.clone("text", stored.allocator)
	stored.env_vars[key] = strings.clone(text, stored.allocator)
	sc := Shell_Context{params = stored.params[:], env_vars = stored.env_vars}
	exec_err, exec_msg := command_manager_execute(
		command_manager_instance(),
		cmd,
		ctx,
		&sc,
		ctx.allocator,
	)
	delete(stored.env_vars["text"], stored.allocator)
	delete(key, stored.allocator)
	delete_key(&stored.env_vars, "text")
	if exec_err != .None {
		commands_report(.Error, exec_msg, ctx)
		hook_manager_run_hook(context_hooks(ctx), .Runtime_Error, exec_msg, ctx)
	}
}

commands_prompt_callback_destroy :: proc(data: rawptr, allocator: mem.Allocator) {
	stored := cast(^Commands_Prompt_Callback)data
	delete(stored.command, stored.allocator)
	delete(stored.on_change, stored.allocator)
	delete(stored.on_abort, stored.allocator)
	for s in stored.params {
		delete(s, stored.allocator)
	}
	delete(stored.params)
	for k, v in stored.env_vars {
		delete(k, stored.allocator)
		delete(v, stored.allocator)
	}
	delete(stored.env_vars)
	free(stored, stored.allocator)
}

// Commands_On_Key_Callback is the data of an on-key callback.
Commands_On_Key_Callback :: struct {
	command:   string,
	params:    [dynamic]string,
	env_vars:  Env_Var_Map,
	allocator: mem.Allocator,
}

commands_on_key_callback_call :: proc(data: rawptr, key: Keys_Key, ctx: ^Context) {
	stored := cast(^Commands_On_Key_Callback)data
	key_str := keys_to_string_key(key, stored.allocator)
	env_key := strings.clone("key", stored.allocator)
	if old, ok := stored.env_vars["key"]; ok {
		delete(old, stored.allocator)
		delete(env_key, stored.allocator)
		stored.env_vars["key"] = key_str
	} else {
		stored.env_vars[env_key] = key_str
	}
	sc := Shell_Context{params = stored.params[:], env_vars = stored.env_vars}
	exec_err, exec_msg := command_manager_execute(
		command_manager_instance(),
		stored.command,
		ctx,
		&sc,
		ctx.allocator,
	)
	if exec_err == .Fail {
		commands_report(.Fail, exec_msg, ctx)
	} else if exec_err != .None {
		commands_report(.Error, exec_msg, ctx)
	}
}

commands_on_key_callback_destroy :: proc(data: rawptr, allocator: mem.Allocator) {
	stored := cast(^Commands_On_Key_Callback)data
	delete(stored.command, stored.allocator)
	for s in stored.params {
		delete(s, stored.allocator)
	}
	delete(stored.params)
	for k, v in stored.env_vars {
		delete(k, stored.allocator)
		delete(v, stored.allocator)
	}
	delete(stored.env_vars)
	free(stored, stored.allocator)
}

// Commands_User_Mode is the data of an enter-user-mode callback (C++
// enter_user_mode).
Commands_User_Mode :: struct {
	params:    Normal_Params,
	mode_name: string,
	mode:      Keymap_Manager_Mode,
	lock:      bool,
	allocator: mem.Allocator,
}

// commands_build_autoinfo_for_mapping builds the mode help listing
// (C++ build_autoinfo_for_mapping, normal.cc, with no built-ins).
commands_build_autoinfo_for_mapping :: proc(
	ctx: ^Context,
	mode: Keymap_Manager_Mode,
	allocator := context.allocator,
) -> string {
	keymaps := context_keymaps(ctx)
	keys_list := make([dynamic]string, 0, allocator)
	defer {
		for s in keys_list {
			delete(s, allocator)
		}
		delete(keys_list)
	}
	docs := make([dynamic]string, 0, allocator)
	defer delete(docs)
	mapped := keymap_manager_get_mapped_keys(keymaps, mode, allocator)
	defer delete(mapped)
	for key in mapped {
		mapping := keymap_manager_get_mapping(keymaps, key, mode)
		if mapping == nil {
			continue
		}
		if len(mapping.keys) == 0 && len(mapping.docstring) == 0 {
			continue
		}
		key_str := keys_to_string_key(key, allocator)
		merged := false
		for doc, i in docs {
			if doc == mapping.docstring {
				combined := strings.concatenate(
					{keys_list[i], ",", key_str},
					allocator,
				)
				delete(keys_list[i], allocator)
				keys_list[i] = combined
				merged = true
				break
			}
		}
		if merged {
			delete(key_str, allocator)
		} else {
			append(&keys_list, key_str)
			append(&docs, mapping.docstring)
		}
	}
	max_len := 0
	for k in keys_list {
		if w := string_utils_column_length(k); w > max_len {
			max_len = w
		}
	}
	b := strings.builder_make(allocator)
	for k, i in keys_list {
		strings.write_string(&b, k)
		strings.write_byte(&b, ':')
		for j := string_utils_column_length(k); j < max_len + 1; j += 1 {
			strings.write_byte(&b, ' ')
		}
		strings.write_string(&b, docs[i])
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

// commands_enter_user_mode_impl arms a user mode for the next key
// (C++ enter_user_mode).
commands_enter_user_mode_impl :: proc(
	ctx: ^Context,
	params: Normal_Params,
	mode_name: string,
	mode: Keymap_Manager_Mode,
	lock: bool,
	allocator := context.allocator,
) {
	stored := new(Commands_User_Mode, allocator)
	stored^ = Commands_User_Mode{
		params    = params,
		mode_name = strings.clone(mode_name, allocator),
		mode      = mode,
		lock      = lock,
		allocator = allocator,
	}
	display, ferr := format_format("user.{}", {mode_name}, allocator)
	assert(ferr == .None)
	defer delete(display, allocator)
	title := mode_name
	title_owned := ""
	if lock {
		title_owned, _ = format_format("{} (lock)", {mode_name}, allocator)
		title = title_owned
		defer delete(title_owned, allocator)
	}
	info := commands_build_autoinfo_for_mapping(ctx, mode, allocator)
	defer delete(info, allocator)
	input_handler_on_next_key_with_autoinfo(
		ctx,
		display,
		.None,
		Key_Callback{
			call    = commands_user_mode_call,
			data    = stored,
			destroy = commands_user_mode_destroy,
		},
		title,
		info,
	)
}

commands_user_mode_call :: proc(data: rawptr, key: Keys_Key, ctx: ^Context) {
	stored := cast(^Commands_User_Mode)data
	if key.modifiers == keys_MOD_NONE && key.key == keys_ESCAPE {
		return
	}
	if mapping := keymap_manager_get_mapping(
		context_keymaps(ctx),
		key,
		stored.mode,
	); mapping != nil {
		guard := utils_scoped_bool_make(context_keymaps_disabled(ctx))
		defer utils_scoped_bool_release(&guard)
		force := input_handler_scoped_force_normal_make(ctx.input_handler, stored.params)
		defer input_handler_scoped_force_normal_destroy(&force)
		edition := context_scoped_edition_make(ctx)
		defer context_scoped_edition_destroy(&edition)
		keys_copy := make([dynamic]Keys_Key, len(mapping.keys), ctx.allocator)
		defer delete(keys_copy)
		copy(keys_copy[:], mapping.keys[:])
		for k in keys_copy {
			input_handler_handle_key(ctx.input_handler, k)
		}
	}
	if stored.lock {
		commands_enter_user_mode_impl(
			ctx,
			stored.params,
			stored.mode_name,
			stored.mode,
			true,
			stored.allocator,
		)
	}
}

commands_user_mode_destroy :: proc(data: rawptr, allocator: mem.Allocator) {
	stored := cast(^Commands_User_Mode)data
	delete(stored.mode_name, stored.allocator)
	free(stored, stored.allocator)
}

// ---------------------------------------------------------------------------
// Command_Func.call wrappers. Each adapts a core proc to the void
// callback, reporting failures on the status line.
// ---------------------------------------------------------------------------

commands_nop_call :: proc(
	data: rawptr,
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
) {
	err, msg := commands_nop()
	commands_report(err, msg, ctx)
}

commands_edit_call :: proc(
	data: rawptr,
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
) {
	env := commands_default_env()
	err, msg := commands_edit(p, ctx, &env, false, ctx.allocator)
	commands_report(err, msg, ctx)
}

commands_force_edit_call :: proc(
	data: rawptr,
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
) {
	env := commands_default_env()
	err, msg := commands_edit(p, ctx, &env, true, ctx.allocator)
	commands_report(err, msg, ctx)
}

commands_write_call :: proc(
	data: rawptr,
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
) {
	err, msg := commands_write(p, ctx, false, ctx.allocator)
	commands_report(err, msg, ctx)
}

commands_force_write_call :: proc(
	data: rawptr,
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
) {
	err, msg := commands_write(p, ctx, true, ctx.allocator)
	commands_report(err, msg, ctx)
}

commands_write_all_call :: proc(
	data: rawptr,
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
) {
	env := commands_default_env()
	err, msg := commands_write_all(p, ctx, &env, ctx.allocator)
	commands_report(err, msg, ctx)
}

commands_kill_call :: proc(
	data: rawptr,
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
) {
	env := commands_default_env()
	err, msg := commands_kill(p, ctx, &env, false, ctx.allocator)
	commands_report(err, msg, ctx)
}

commands_force_kill_call :: proc(
	data: rawptr,
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
) {
	env := commands_default_env()
	err, msg := commands_kill(p, ctx, &env, true, ctx.allocator)
	commands_report(err, msg, ctx)
}

commands_daemonize_session_call :: proc(
	data: rawptr,
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
) {
	env := commands_default_env()
	err, msg := commands_daemonize_session(&env)
	commands_report(err, msg, ctx)
}

commands_quit_call :: proc(
	data: rawptr,
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
) {
	env := commands_default_env()
	err, msg := commands_quit(p, ctx, &env, false, ctx.allocator)
	commands_report(err, msg, ctx)
}

commands_force_quit_call :: proc(
	data: rawptr,
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
) {
	env := commands_default_env()
	err, msg := commands_quit(p, ctx, &env, true, ctx.allocator)
	commands_report(err, msg, ctx)
}

commands_write_quit_call :: proc(
	data: rawptr,
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
) {
	env := commands_default_env()
	err, msg := commands_write_quit(p, ctx, &env, false, ctx.allocator)
	commands_report(err, msg, ctx)
}

commands_force_write_quit_call :: proc(
	data: rawptr,
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
) {
	env := commands_default_env()
	err, msg := commands_write_quit(p, ctx, &env, true, ctx.allocator)
	commands_report(err, msg, ctx)
}

commands_write_all_quit_call :: proc(
	data: rawptr,
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
) {
	env := commands_default_env()
	err, msg := commands_write_all_quit(p, ctx, &env, ctx.allocator)
	commands_report(err, msg, ctx)
}

commands_buffer_call :: proc(
	data: rawptr,
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
) {
	env := commands_default_env()
	err, msg := commands_buffer(p, ctx, &env, ctx.allocator)
	commands_report(err, msg, ctx)
}

commands_buffer_next_call :: proc(
	data: rawptr,
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
) {
	env := commands_default_env()
	err, msg := commands_cycle_buffer(ctx, &env, true, ctx.allocator)
	commands_report(err, msg, ctx)
}

commands_buffer_previous_call :: proc(
	data: rawptr,
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
) {
	env := commands_default_env()
	err, msg := commands_cycle_buffer(ctx, &env, false, ctx.allocator)
	commands_report(err, msg, ctx)
}

commands_delete_buffer_call :: proc(
	data: rawptr,
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
) {
	env := commands_default_env()
	err, msg := commands_delete_buffer(p, ctx, &env, false, ctx.allocator)
	commands_report(err, msg, ctx)
}

commands_force_delete_buffer_call :: proc(
	data: rawptr,
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
) {
	env := commands_default_env()
	err, msg := commands_delete_buffer(p, ctx, &env, true, ctx.allocator)
	commands_report(err, msg, ctx)
}

commands_rename_buffer_call :: proc(
	data: rawptr,
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
) {
	err, msg := commands_rename_buffer(p, ctx, ctx.allocator)
	commands_report(err, msg, ctx)
}

commands_arrange_buffers_call :: proc(
	data: rawptr,
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
) {
	env := commands_default_env()
	err, msg := commands_arrange_buffers(p, &env, ctx.allocator)
	commands_report(err, msg, ctx)
}

commands_add_highlighter_call :: proc(
	data: rawptr,
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
) {
	env := commands_default_env()
	err, msg := commands_add_highlighter(p, ctx, &env, ctx.allocator)
	commands_report(err, msg, ctx)
}

commands_remove_highlighter_call :: proc(
	data: rawptr,
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
) {
	env := commands_default_env()
	err, msg := commands_remove_highlighter(p, ctx, &env, ctx.allocator)
	commands_report(err, msg, ctx)
}

commands_hook_call :: proc(
	data: rawptr,
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
) {
	env := commands_default_env()
	err, msg := commands_hook(p, ctx, &env, ctx.allocator)
	commands_report(err, msg, ctx)
}

commands_remove_hooks_call :: proc(
	data: rawptr,
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
) {
	env := commands_default_env()
	err, msg := commands_remove_hooks(p, ctx, &env, ctx.allocator)
	commands_report(err, msg, ctx)
}

commands_trigger_user_hook_call :: proc(
	data: rawptr,
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
) {
	err, msg := commands_trigger_user_hook(p, ctx, ctx.allocator)
	commands_report(err, msg, ctx)
}

commands_define_command_call :: proc(
	data: rawptr,
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
) {
	env := commands_default_env()
	err, msg := commands_define_command(p, ctx, &env, ctx.allocator)
	commands_report(err, msg, ctx)
}

commands_complete_command_call :: proc(
	data: rawptr,
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
) {
	env := commands_default_env()
	err, msg := commands_complete_command(p, &env, ctx.allocator)
	commands_report(err, msg, ctx)
}

commands_alias_call :: proc(
	data: rawptr,
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
) {
	env := commands_default_env()
	err, msg := commands_alias(p, ctx, &env, ctx.allocator)
	commands_report(err, msg, ctx)
}

commands_unalias_call :: proc(
	data: rawptr,
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
) {
	env := commands_default_env()
	err, msg := commands_unalias(p, ctx, &env, ctx.allocator)
	commands_report(err, msg, ctx)
}

commands_echo_call :: proc(
	data: rawptr,
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
) {
	env := commands_default_env()
	err, msg := commands_echo(p, ctx, shell_ctx, &env, ctx.allocator)
	commands_report(err, msg, ctx)
}

commands_debug_call :: proc(
	data: rawptr,
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
) {
	env := commands_default_env()
	err, msg := commands_debug(p, ctx, &env, ctx.allocator)
	commands_report(err, msg, ctx)
}

commands_source_call :: proc(
	data: rawptr,
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
) {
	env := commands_default_env()
	err, msg := commands_source(p, ctx, &env, ctx.allocator)
	commands_report(err, msg, ctx)
}

commands_set_option_call :: proc(
	data: rawptr,
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
) {
	env := commands_default_env()
	err, msg := commands_set_option(p, ctx, &env, ctx.allocator)
	commands_report(err, msg, ctx)
}

commands_unset_option_call :: proc(
	data: rawptr,
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
) {
	env := commands_default_env()
	err, msg := commands_unset_option(p, ctx, &env, ctx.allocator)
	commands_report(err, msg, ctx)
}

commands_update_option_call :: proc(
	data: rawptr,
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
) {
	env := commands_default_env()
	err, msg := commands_update_option(p, ctx, &env, ctx.allocator)
	commands_report(err, msg, ctx)
}

commands_declare_option_call :: proc(
	data: rawptr,
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
) {
	env := commands_default_env()
	err, msg := commands_declare_option(p, &env, ctx.allocator)
	commands_report(err, msg, ctx)
}

commands_map_call :: proc(
	data: rawptr,
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
) {
	env := commands_default_env()
	err, msg := commands_map(p, ctx, &env, ctx.allocator)
	commands_report(err, msg, ctx)
}

commands_unmap_call :: proc(
	data: rawptr,
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
) {
	env := commands_default_env()
	err, msg := commands_unmap(p, ctx, &env, ctx.allocator)
	commands_report(err, msg, ctx)
}

commands_execute_keys_call :: proc(
	data: rawptr,
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
) {
	env := commands_default_env()
	err, msg := commands_execute_keys(p, ctx, shell_ctx, &env, ctx.allocator)
	commands_report(err, msg, ctx)
}

commands_evaluate_commands_call :: proc(
	data: rawptr,
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
) {
	env := commands_default_env()
	err, msg := commands_evaluate_commands(p, ctx, shell_ctx, &env, ctx.allocator)
	commands_report(err, msg, ctx)
}

commands_prompt_call :: proc(
	data: rawptr,
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
) {
	err, msg := commands_prompt(p, ctx, shell_ctx, ctx.allocator)
	commands_report(err, msg, ctx)
}

commands_on_key_call :: proc(
	data: rawptr,
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
) {
	err, msg := commands_on_key(p, ctx, shell_ctx, ctx.allocator)
	commands_report(err, msg, ctx)
}

commands_info_call :: proc(
	data: rawptr,
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
) {
	err, msg := commands_info(p, ctx, ctx.allocator)
	commands_report(err, msg, ctx)
}

commands_try_call :: proc(
	data: rawptr,
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
) {
	err, msg := commands_try(p, ctx, shell_ctx, ctx.allocator)
	commands_report(err, msg, ctx)
}

commands_set_face_call :: proc(
	data: rawptr,
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
) {
	env := commands_default_env()
	err, msg := commands_set_face(p, ctx, &env, ctx.allocator)
	commands_report(err, msg, ctx)
}

commands_unset_face_call :: proc(
	data: rawptr,
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
) {
	env := commands_default_env()
	err, msg := commands_unset_face(p, ctx, &env, ctx.allocator)
	commands_report(err, msg, ctx)
}

commands_rename_client_call :: proc(
	data: rawptr,
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
) {
	env := commands_default_env()
	err, msg := commands_rename_client(p, ctx, &env, ctx.allocator)
	commands_report(err, msg, ctx)
}

commands_set_register_call :: proc(
	data: rawptr,
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
) {
	env := commands_default_env()
	err, msg := commands_set_register(p, ctx, &env, ctx.allocator)
	commands_report(err, msg, ctx)
}

commands_select_call :: proc(
	data: rawptr,
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
) {
	err, msg := commands_select(p, ctx, ctx.allocator)
	commands_report(err, msg, ctx)
}

commands_change_directory_call :: proc(
	data: rawptr,
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
) {
	env := commands_default_env()
	err, msg := commands_change_directory(p, ctx, &env, ctx.allocator)
	commands_report(err, msg, ctx)
}

commands_rename_session_call :: proc(
	data: rawptr,
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
) {
	env := commands_default_env()
	err, msg := commands_rename_session(p, ctx, &env, ctx.allocator)
	commands_report(err, msg, ctx)
}

commands_fail_call :: proc(
	data: rawptr,
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
) {
	err, msg := commands_fail(p, ctx.allocator)
	commands_report(err, msg, ctx)
}

commands_declare_user_mode_call :: proc(
	data: rawptr,
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
) {
	err, msg := commands_declare_user_mode(p, ctx, ctx.allocator)
	commands_report(err, msg, ctx)
}

commands_enter_user_mode_call :: proc(
	data: rawptr,
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
) {
	err, msg := commands_enter_user_mode(p, ctx, ctx.allocator)
	commands_report(err, msg, ctx)
}

commands_provide_module_call :: proc(
	data: rawptr,
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
) {
	env := commands_default_env()
	err, msg := commands_provide_module(p, &env, ctx.allocator)
	commands_report(err, msg, ctx)
}

commands_require_module_call :: proc(
	data: rawptr,
	p: ^Parameters_Parser,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
) {
	env := commands_default_env()
	err, msg := commands_require_module(p, ctx, &env, ctx.allocator)
	commands_report(err, msg, ctx)
}

// commands_register_all registers every builtin command and its alias
// (C++ register_commands).
commands_register_all :: proc(m: ^Command_Manager, global: ^Global_Scope) {
	for name in commands_all_names {
		spec, ok := commands_spec_for(name, m.allocator)
		assert(ok)
		defer commands_destroy_desc(&spec.desc)
		command_manager_register_command(
			m,
			spec.name,
			spec.func,
			spec.docstring,
			spec.desc,
			{},
			spec.helper,
			spec.completer,
		)
		if len(spec.alias) > 0 {
			_ = alias_registry_add(&global.scope.data.aliases, spec.alias, spec.name)
		}
	}
}
