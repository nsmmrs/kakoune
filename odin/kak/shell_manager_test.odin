// Tests for the shell_manager module. No C++ UnitTest covers
// shell_manager, so these assert ported behavior plus edge cases:
// empty/missing variables, quoting/expansion edges, completion with no
// match, fifo plumbing, exit statuses, and allocator cleanup.
//
// odin test runs tests on multiple threads, so every test here uses a
// local manager (shell_manager_make_with_shell); only
// test_shell_manager_make_destroy touches the singleton. No test
// mutates the environment.
package kak

import "core:c"
import "core:mem"
import "core:strings"
import "core:testing"
import posix "core:sys/posix"

// shell_manager_test_greet serves the "greeting" test variable.
shell_manager_test_greet :: proc(name: string, ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	vals := make([dynamic]string, 1, allocator)
	vals[0] = strings.clone("hello", allocator)
	return vals
}

// shell_manager_test_pair serves the "pair" test variable: two values
// needing quotes (quote char, blank char).
shell_manager_test_pair :: proc(name: string, ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	vals := make([dynamic]string, 2, allocator)
	vals[0] = strings.clone("a'b", allocator)
	vals[1] = strings.clone("c d", allocator)
	return vals
}

// shell_manager_test_empty serves the "empty" test variable: one empty
// value (still an entry, like the C++).
shell_manager_test_empty :: proc(name: string, ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	vals := make([dynamic]string, 1, allocator)
	vals[0] = strings.clone("", allocator)
	return vals
}

// shell_manager_test_none serves the "none" test variable: zero values.
shell_manager_test_none :: proc(name: string, ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	return make([dynamic]string, 0, allocator)
}

// shell_manager_test_echo serves prefix variables: it echoes the full
// looked-up name so tests can prove the whole name reaches prefix
// retrievers (C++ passes the full name, not the suffix).
shell_manager_test_echo :: proc(name: string, ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	vals := make([dynamic]string, 1, allocator)
	vals[0] = strings.concatenate({"v:", name}, allocator)
	return vals
}

// shell_manager_test_contains reports whether list holds want.
shell_manager_test_contains :: proc(list: []string, want: string) -> bool {
	for s in list {
		if s == want {
			return true
		}
	}
	return false
}

// shell_manager_test_assert_clean asserts the tracker saw no leaks and
// no bad frees.
shell_manager_test_assert_clean :: proc(t: ^testing.T, track: ^mem.Tracking_Allocator) {
	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
}

// shell_manager_test_track starts a tracking allocator test scope.
shell_manager_test_track :: proc(track: ^mem.Tracking_Allocator) -> mem.Allocator {
	mem.tracking_allocator_init(track, context.allocator)
	return mem.tracking_allocator(track)
}

// shell_manager_test_make builds a local manager over /bin/sh. Tests
// destroy it with shell_manager_destroy.
shell_manager_test_make :: proc(t: ^testing.T, table: []Env_Var_Desc, alloc: mem.Allocator) -> (Shell_Manager, bool) {
	m, merr := shell_manager_make_with_shell(table, "/bin/sh", alloc)
	testing.expect_value(t, merr, Shell_Manager_Error.None)
	return m, merr == .None
}

@(test)
test_shell_manager_make_destroy :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := shell_manager_test_track(&track)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = alloc
	table := [?]Env_Var_Desc{
		{"greeting", false, shell_manager_test_greet},
	}
	// shell_manager_make honors $KAKOUNE_POSIX_SHELL when set. The
	// assertions follow the ambient environment instead of mutating
	// it, so tests snapshotting the environment in parallel never
	// observe a transient value.
	want_shell := ""
	if raw := posix.getenv("KAKOUNE_POSIX_SHELL"); raw != nil {
		want_shell = string(raw)
	}
	m, merr := shell_manager_make(table[:], alloc)
	if len(want_shell) > 0 {
		if !shell_manager_is_executable(want_shell) {
			testing.expect_value(t, merr, Shell_Manager_Error.Bad_Shell)
			shell_manager_test_assert_clean(t, &track)
			return
		}
		testing.expect_value(t, merr, Shell_Manager_Error.None)
		if merr != .None {
			return
		}
		testing.expect_value(t, m.shell, want_shell)
	} else {
		testing.expect_value(t, merr, Shell_Manager_Error.None)
		if merr != .None {
			return
		}
		testing.expect(t, len(m.shell) > 0)
		testing.expect(t, shell_manager_is_executable(m.shell))
	}
	shell_manager_destroy(&m)
	// The singleton path wires the same manager to the instance; the
	// three command_manager entry points run on it. This stays in this
	// test so one test owns all singleton and environment use.
	serr := shell_manager_init_singleton(table[:], alloc)
	testing.expect_value(t, serr, Shell_Manager_Error.None)
	if serr != .None {
		return
	}
	testing.expect(t, len(shell_manager_instance().shell) > 0)
	ctx := Context{}
	shctx := Shell_Context{}
	vals := shell_manager_get_val("greeting", &ctx, alloc)
	testing.expect_value(t, len(vals), 1)
	testing.expect_value(t, vals[0], "hello")
	shell_manager_free_strings(&vals, alloc)
	c := shell_manager_complete_env_var("greet", 5, alloc)
	testing.expect_value(t, len(c), 1)
	testing.expect_value(t, c[0], "greeting")
	shell_manager_free_strings(&c, alloc)
	out := shell_manager_eval("echo $kak_greeting", &ctx, &shctx, alloc)
	testing.expect_value(t, out, "hello\n")
	delete(out, alloc)
	shell_manager_destroy(shell_manager_instance())
	shell_manager_test_assert_clean(t, &track)
}

@(test)
test_shell_manager_make_with_shell :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := shell_manager_test_track(&track)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = alloc
	table := [?]Env_Var_Desc{
		{"greeting", false, shell_manager_test_greet},
	}
	m, ok := shell_manager_test_make(t, table[:], alloc)
	if !ok {
		return
	}
	testing.expect_value(t, m.shell, "/bin/sh")
	shell_manager_destroy(&m)
	_, err := shell_manager_make_with_shell(table[:], "/nonexistent-shell-xyz", alloc)
	testing.expect_value(t, err, Shell_Manager_Error.Bad_Shell)
	// A directory is not an executable shell either.
	_, err = shell_manager_make_with_shell(table[:], "/tmp", alloc)
	testing.expect_value(t, err, Shell_Manager_Error.Bad_Shell)
	shell_manager_test_assert_clean(t, &track)
}

@(test)
test_shell_manager_find_shell :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := shell_manager_test_track(&track)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = alloc
	found, ok := shell_manager_find_shell("/bin:/usr/bin", alloc)
	testing.expect(t, ok)
	testing.expect(t, strings.has_suffix(found, "/sh"))
	testing.expect(t, shell_manager_is_executable(found))
	delete(found, alloc)
	_, ok = shell_manager_find_shell("/nonexistent-dir-xyz", alloc)
	testing.expect(t, !ok)
	_, ok = shell_manager_find_shell("", alloc)
	testing.expect(t, !ok)
	// Empty segments are skipped.
	found2, ok2 := shell_manager_find_shell("::/bin:", alloc)
	testing.expect(t, ok2)
	delete(found2, alloc)
	shell_manager_test_assert_clean(t, &track)
}

@(test)
test_shell_manager_is_executable :: proc(t: ^testing.T) {
	testing.expect(t, shell_manager_is_executable("/bin/sh"))
	testing.expect(t, !shell_manager_is_executable("/nonexistent-file-xyz"))
	testing.expect(t, !shell_manager_is_executable("/tmp"))
}

@(test)
test_shell_manager_get_val :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := shell_manager_test_track(&track)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = alloc
	table := [?]Env_Var_Desc{
		{"greeting", false, shell_manager_test_greet},
		{"pair", false, shell_manager_test_pair},
		{"opt_", true, shell_manager_test_echo},
	}
	m, ok := shell_manager_test_make(t, table[:], alloc)
	if !ok {
		return
	}
	ctx := Context{}
	vals, verr := shell_manager_get_val_from(&m, "greeting", &ctx, alloc)
	testing.expect_value(t, verr, Shell_Manager_Error.None)
	testing.expect_value(t, len(vals), 1)
	testing.expect_value(t, vals[0], "hello")
	shell_manager_free_strings(&vals, alloc)
	pair, perr := shell_manager_get_val_from(&m, "pair", &ctx, alloc)
	testing.expect_value(t, perr, Shell_Manager_Error.None)
	testing.expect_value(t, len(pair), 2)
	testing.expect_value(t, pair[0], "a'b")
	testing.expect_value(t, pair[1], "c d")
	shell_manager_free_strings(&pair, alloc)
	// Prefix descriptors receive the full looked-up name.
	opt, oerr := shell_manager_get_val_from(&m, "opt_debug", &ctx, alloc)
	testing.expect_value(t, oerr, Shell_Manager_Error.None)
	testing.expect_value(t, len(opt), 1)
	testing.expect_value(t, opt[0], "v:opt_debug")
	shell_manager_free_strings(&opt, alloc)
	shell_manager_destroy(&m)
	shell_manager_test_assert_clean(t, &track)
}

@(test)
test_shell_manager_get_val_missing :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := shell_manager_test_track(&track)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = alloc
	table := [?]Env_Var_Desc{
		{"greeting", false, shell_manager_test_greet},
		{"opt_", true, shell_manager_test_echo},
	}
	m, ok := shell_manager_test_make(t, table[:], alloc)
	if !ok {
		return
	}
	ctx := Context{}
	vals, verr := shell_manager_get_val_from(&m, "nope", &ctx, alloc)
	testing.expect_value(t, verr, Shell_Manager_Error.No_Such_Variable)
	testing.expect_value(t, len(vals), 0)
	shell_manager_free_strings(&vals, alloc)
	// Exact names do not match longer lookups.
	_, e1 := shell_manager_get_val_from(&m, "greeting2", &ctx, alloc)
	testing.expect_value(t, e1, Shell_Manager_Error.No_Such_Variable)
	// A name shorter than the prefix does not match it.
	_, e2 := shell_manager_get_val_from(&m, "opt", &ctx, alloc)
	testing.expect_value(t, e2, Shell_Manager_Error.No_Such_Variable)
	// The prefix itself matches.
	v3, e3 := shell_manager_get_val_from(&m, "opt_", &ctx, alloc)
	testing.expect_value(t, e3, Shell_Manager_Error.None)
	shell_manager_free_strings(&v3, alloc)
	shell_manager_destroy(&m)
	shell_manager_test_assert_clean(t, &track)
}

@(test)
test_shell_manager_get_val_empty :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := shell_manager_test_track(&track)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = alloc
	table := [?]Env_Var_Desc{
		{"empty", false, shell_manager_test_empty},
		{"none", false, shell_manager_test_none},
	}
	m, ok := shell_manager_test_make(t, table[:], alloc)
	if !ok {
		return
	}
	ctx := Context{}
	e, eerr := shell_manager_get_val_from(&m, "empty", &ctx, alloc)
	testing.expect_value(t, eerr, Shell_Manager_Error.None)
	testing.expect_value(t, len(e), 1)
	testing.expect_value(t, e[0], "")
	shell_manager_free_strings(&e, alloc)
	n, nerr := shell_manager_get_val_from(&m, "none", &ctx, alloc)
	testing.expect_value(t, nerr, Shell_Manager_Error.None)
	testing.expect_value(t, len(n), 0)
	shell_manager_free_strings(&n, alloc)
	shell_manager_destroy(&m)
	shell_manager_test_assert_clean(t, &track)
}

@(test)
test_shell_manager_complete_env_var :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := shell_manager_test_track(&track)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = alloc
	table := [?]Env_Var_Desc{
		{"bufname", false, shell_manager_test_greet},
		{"buffile", false, shell_manager_test_greet},
		{"buflist", false, shell_manager_test_greet},
		{"selection", false, shell_manager_test_greet},
		{"greeting", false, shell_manager_test_greet},
	}
	m, ok := shell_manager_test_make(t, table[:], alloc)
	if !ok {
		return
	}
	c := shell_manager_complete_env_var_from(&m, "buf", 3, alloc)
	testing.expect_value(t, len(c), 3)
	testing.expect(t, shell_manager_test_contains(c[:], "bufname"))
	testing.expect(t, shell_manager_test_contains(c[:], "buffile"))
	testing.expect(t, shell_manager_test_contains(c[:], "buflist"))
	shell_manager_free_strings(&c, alloc)
	// No match: empty, still owned.
	c2 := shell_manager_complete_env_var_from(&m, "zzz_no_match", 12, alloc)
	testing.expect_value(t, len(c2), 0)
	shell_manager_free_strings(&c2, alloc)
	// The cursor truncates the query.
	c3 := shell_manager_complete_env_var_from(&m, "bufname Trailing", 7, alloc)
	testing.expect_value(t, len(c3), 1)
	testing.expect_value(t, c3[0], "bufname")
	shell_manager_free_strings(&c3, alloc)
	// An empty query matches every name.
	c4 := shell_manager_complete_env_var_from(&m, "", 0, alloc)
	testing.expect_value(t, len(c4), 5)
	shell_manager_free_strings(&c4, alloc)
	shell_manager_destroy(&m)
	shell_manager_test_assert_clean(t, &track)
}

@(test)
test_shell_manager_generate_env :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := shell_manager_test_track(&track)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = alloc
	table := [?]Env_Var_Desc{
		{"greeting", false, shell_manager_test_greet},
		{"pair", false, shell_manager_test_pair},
		{"empty", false, shell_manager_test_empty},
		{"opt_", true, shell_manager_test_echo},
	}
	m, ok := shell_manager_test_make(t, table[:], alloc)
	if !ok {
		return
	}
	ctx := Context{}
	shctx := Shell_Context{}
	env := shell_manager_generate_env(&m, "echo $kak_greeting and $kak_greeting $kak_quoted_pair $kak_nope $kak_ kak end", nil, &ctx, &shctx, nil, alloc)
	// Repeats dedup, quoted values are shell-quoted, unknown names and
	// bare kak_/kak words are skipped.
	testing.expect_value(t, len(env), 2)
	testing.expect(t, shell_manager_test_contains(env[:], "kak_greeting=hello"))
	testing.expect(t, shell_manager_test_contains(env[:], "kak_quoted_pair='a'\\''b' 'c d'"))
	shell_manager_free_strings(&env, alloc)
	// Params are scanned too; raw values join with spaces; empty values
	// still produce an entry.
	parr := [2]string{"$kak_pair", "$kak_empty $kak_opt_x"}
	env2 := shell_manager_generate_env(&m, "echo hi", parr[:], &ctx, &shctx, nil, alloc)
	testing.expect_value(t, len(env2), 3)
	testing.expect(t, shell_manager_test_contains(env2[:], "kak_pair=a'b c d"))
	testing.expect(t, shell_manager_test_contains(env2[:], "kak_empty="))
	testing.expect(t, shell_manager_test_contains(env2[:], "kak_opt_x=v:opt_x"))
	shell_manager_free_strings(&env2, alloc)
	// No references: no entries.
	env3 := shell_manager_generate_env(&m, "echo hi", nil, &ctx, &shctx, nil, alloc)
	testing.expect_value(t, len(env3), 0)
	shell_manager_free_strings(&env3, alloc)
	shell_manager_destroy(&m)
	shell_manager_test_assert_clean(t, &track)
}

@(test)
test_shell_manager_generate_env_override :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := shell_manager_test_track(&track)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = alloc
	table := [?]Env_Var_Desc{
		{"greeting", false, shell_manager_test_greet},
	}
	m, ok := shell_manager_test_make(t, table[:], alloc)
	if !ok {
		return
	}
	ctx := Context{}
	overrides := make(Env_Var_Map, 2, alloc)
	overrides[strings.clone("greeting", alloc)] = strings.clone("O V", alloc)
	shctx := Shell_Context{env_vars = overrides}
	env := shell_manager_generate_env(&m, "echo $kak_greeting $kak_quoted_greeting", nil, &ctx, &shctx, nil, alloc)
	// Overrides win raw, even for quoted references (C++ parity: the
	// override branch returns before quoting).
	testing.expect_value(t, len(env), 2)
	testing.expect(t, shell_manager_test_contains(env[:], "kak_greeting=O V"))
	testing.expect(t, shell_manager_test_contains(env[:], "kak_quoted_greeting=O V"))
	shell_manager_free_strings(&env, alloc)
	for k, v in overrides {
		delete(k, alloc)
		delete(v, alloc)
	}
	delete(overrides)
	shell_manager_destroy(&m)
	shell_manager_test_assert_clean(t, &track)
}

@(test)
test_shell_manager_generate_env_no_fifos :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := shell_manager_test_track(&track)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = alloc
	table := [?]Env_Var_Desc{
		{"greeting", false, shell_manager_test_greet},
	}
	m, ok := shell_manager_test_make(t, table[:], alloc)
	if !ok {
		return
	}
	ctx := Context{}
	shctx := Shell_Context{}
	// The spawn path passes no fifo pair: fifo references are skipped,
	// like the C++ spawn lambda missing the fifo branch.
	env := shell_manager_generate_env(&m, "echo $kak_command_fifo $kak_greeting", nil, &ctx, &shctx, nil, alloc)
	testing.expect_value(t, len(env), 1)
	testing.expect(t, shell_manager_test_contains(env[:], "kak_greeting=hello"))
	shell_manager_free_strings(&env, alloc)
	shell_manager_destroy(&m)
	shell_manager_test_assert_clean(t, &track)
}

@(test)
test_shell_manager_needs_fifos :: proc(t: ^testing.T) {
	testing.expect(t, shell_manager_cmdline_needs_fifos("echo $kak_command_fifo", nil))
	testing.expect(t, shell_manager_cmdline_needs_fifos("echo $kak_quoted_command_fifo", nil))
	parr := [1]string{"$kak_response_fifo"}
	testing.expect(t, shell_manager_cmdline_needs_fifos("echo hi", parr[:]))
	testing.expect(t, !shell_manager_cmdline_needs_fifos("echo hi", nil))
	testing.expect(t, !shell_manager_cmdline_needs_fifos("", nil))
}

@(test)
test_shell_manager_fifos_make_destroy :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := shell_manager_test_track(&track)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = alloc
	f, ferr := shell_manager_fifos_make(alloc)
	testing.expect_value(t, ferr, Shell_Manager_Error.None)
	if ferr != .None {
		return
	}
	testing.expect(t, len(f.base_dir) > 0)
	testing.expect(t, f.command_fd != posix.FD(-1))
	testing.expect_value(t, len(f.command), 0)
	cmd := shell_manager_fifos_command_path(&f, alloc)
	rsp := shell_manager_fifos_response_path(&f, alloc)
	base := strings.clone(f.base_dir, alloc)
	st: posix.stat_t
	testing.expect(t, posix.stat(strings.clone_to_cstring(cmd, context.temp_allocator), &st) == .OK)
	testing.expect(t, posix.stat(strings.clone_to_cstring(rsp, context.temp_allocator), &st) == .OK)
	shell_manager_fifos_destroy(&f)
	testing.expect(t, f.command_fd == posix.FD(-1))
	testing.expect(t, posix.stat(strings.clone_to_cstring(base, context.temp_allocator), &st) != .OK)
	delete(cmd, alloc)
	delete(rsp, alloc)
	delete(base, alloc)
	shell_manager_test_assert_clean(t, &track)
}

@(test)
test_shell_manager_eval_echo :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := shell_manager_test_track(&track)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = alloc
	table := [?]Env_Var_Desc{
		{"greeting", false, shell_manager_test_greet},
	}
	m, ok := shell_manager_test_make(t, table[:], alloc)
	if !ok {
		return
	}
	ctx := Context{}
	shctx := Shell_Context{}
	res, rerr := shell_manager_eval_full_from(&m, "echo hello", &ctx, &shctx, "", {.Wait_For_Stdout}, alloc)
	testing.expect_value(t, rerr, Shell_Manager_Error.None)
	testing.expect_value(t, res.output, "hello\n")
	testing.expect_value(t, res.stderr, "")
	testing.expect_value(t, res.status, 0)
	shell_manager_eval_result_free(&res, alloc)
	shell_manager_destroy(&m)
	shell_manager_test_assert_clean(t, &track)
}

@(test)
test_shell_manager_eval_env :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := shell_manager_test_track(&track)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = alloc
	table := [?]Env_Var_Desc{
		{"greeting", false, shell_manager_test_greet},
		{"pair", false, shell_manager_test_pair},
	}
	m, ok := shell_manager_test_make(t, table[:], alloc)
	if !ok {
		return
	}
	ctx := Context{}
	shctx := Shell_Context{}
	res, _ := shell_manager_eval_full_from(&m, "echo $kak_greeting", &ctx, &shctx, "", {.Wait_For_Stdout}, alloc)
	testing.expect_value(t, res.output, "hello\n")
	shell_manager_eval_result_free(&res, alloc)
	// The quoted entry arrives intact (quote char and blank both
	// preserved verbatim through the environment).
	q, _ := shell_manager_eval_full_from(&m, `echo "$kak_quoted_pair"`, &ctx, &shctx, "", {.Wait_For_Stdout}, alloc)
	testing.expect_value(t, q.output, "'a'\\''b' 'c d'\n")
	shell_manager_eval_result_free(&q, alloc)
	shell_manager_destroy(&m)
	shell_manager_test_assert_clean(t, &track)
}

@(test)
test_shell_manager_eval_status_stderr :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := shell_manager_test_track(&track)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = alloc
	table := [?]Env_Var_Desc{
		{"greeting", false, shell_manager_test_greet},
	}
	m, ok := shell_manager_test_make(t, table[:], alloc)
	if !ok {
		return
	}
	ctx := Context{}
	shctx := Shell_Context{}
	res, rerr := shell_manager_eval_full_from(&m, "echo out; echo err >&2; exit 3", &ctx, &shctx, "", {.Wait_For_Stdout}, alloc)
	testing.expect_value(t, rerr, Shell_Manager_Error.None)
	testing.expect_value(t, res.output, "out\n")
	testing.expect_value(t, res.stderr, "err\n")
	testing.expect_value(t, res.status, 3)
	shell_manager_eval_result_free(&res, alloc)
	ok_res, _ := shell_manager_eval_full_from(&m, "true", &ctx, &shctx, "", {.Wait_For_Stdout}, alloc)
	testing.expect_value(t, ok_res.status, 0)
	testing.expect_value(t, ok_res.output, "")
	testing.expect_value(t, ok_res.stderr, "")
	shell_manager_eval_result_free(&ok_res, alloc)
	empty_res, _ := shell_manager_eval_full_from(&m, "", &ctx, &shctx, "", {.Wait_For_Stdout}, alloc)
	testing.expect_value(t, empty_res.status, 0)
	shell_manager_eval_result_free(&empty_res, alloc)
	shell_manager_destroy(&m)
	shell_manager_test_assert_clean(t, &track)
}

@(test)
test_shell_manager_eval_stdin :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := shell_manager_test_track(&track)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = alloc
	table := [?]Env_Var_Desc{
		{"greeting", false, shell_manager_test_greet},
	}
	m, ok := shell_manager_test_make(t, table[:], alloc)
	if !ok {
		return
	}
	ctx := Context{}
	shctx := Shell_Context{}
	res, _ := shell_manager_eval_full_from(&m, "cat", &ctx, &shctx, "hello stdin", {.Wait_For_Stdout}, alloc)
	testing.expect_value(t, res.output, "hello stdin")
	testing.expect_value(t, res.status, 0)
	shell_manager_eval_result_free(&res, alloc)
	// A 200KB round trip exercises streaming reads and writes well
	// past the pipe buffer without deadlocking.
	big := make([]byte, 200000, alloc)
	for &b in big {
		b = 120
	}
	big_res, _ := shell_manager_eval_full_from(&m, "cat", &ctx, &shctx, string(big), {.Wait_For_Stdout}, alloc)
	testing.expect_value(t, len(big_res.output), len(big))
	testing.expect(t, big_res.output == string(big))
	shell_manager_eval_result_free(&big_res, alloc)
	delete(big, alloc)
	shell_manager_destroy(&m)
	shell_manager_test_assert_clean(t, &track)
}

@(test)
test_shell_manager_eval_no_wait :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := shell_manager_test_track(&track)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = alloc
	table := [?]Env_Var_Desc{
		{"greeting", false, shell_manager_test_greet},
	}
	m, ok := shell_manager_test_make(t, table[:], alloc)
	if !ok {
		return
	}
	ctx := Context{}
	shctx := Shell_Context{}
	// Without .Wait_For_Stdout the child is still reaped; only the
	// drain is partial (output content is timing-dependent here).
	res, rerr := shell_manager_eval_full_from(&m, "echo hi", &ctx, &shctx, "", {}, alloc)
	testing.expect_value(t, rerr, Shell_Manager_Error.None)
	testing.expect_value(t, res.status, 0)
	shell_manager_eval_result_free(&res, alloc)
	shell_manager_destroy(&m)
	shell_manager_test_assert_clean(t, &track)
}

@(test)
test_shell_manager_eval_fifo_env :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := shell_manager_test_track(&track)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = alloc
	table := [?]Env_Var_Desc{
		{"greeting", false, shell_manager_test_greet},
	}
	m, ok := shell_manager_test_make(t, table[:], alloc)
	if !ok {
		return
	}
	ctx := Context{}
	shctx := Shell_Context{}
	// Both fifo paths exist as fifos while the shell runs (the shell
	// never writes, so no command executes).
	res, rerr := shell_manager_eval_full_from(&m, `test -p "$kak_command_fifo" && test -p "$kak_response_fifo" && echo fifo-ok`, &ctx, &shctx, "", {.Wait_For_Stdout}, alloc)
	testing.expect_value(t, rerr, Shell_Manager_Error.None)
	testing.expect_value(t, res.output, "fifo-ok\n")
	testing.expect_value(t, res.status, 0)
	shell_manager_eval_result_free(&res, alloc)
	shell_manager_destroy(&m)
	shell_manager_test_assert_clean(t, &track)
}

@(test)
test_shell_manager_spawn :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := shell_manager_test_track(&track)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = alloc
	table := [?]Env_Var_Desc{
		{"greeting", false, shell_manager_test_greet},
	}
	m, ok := shell_manager_test_make(t, table[:], alloc)
	if !ok {
		return
	}
	ctx := Context{}
	shctx := Shell_Context{}
	sh, sherr := shell_manager_spawn(&m, "echo spawned", &ctx, false, &shctx, alloc)
	testing.expect_value(t, sherr, Shell_Manager_Error.None)
	if sherr != .None {
		return
	}
	testing.expect(t, unique_descriptor_is_valid(sh.pid))
	testing.expect(t, !unique_descriptor_is_valid(sh.stdin))
	testing.expect(t, unique_descriptor_is_valid(sh.out))
	testing.expect(t, unique_descriptor_is_valid(sh.err))
	buf: [1024]byte
	off := 0
	for {
		room := len(buf) - off
		n := posix.read(posix.FD(sh.out.descriptor), raw_data(buf[off:]), c.size_t(room))
		if n < 0 && posix.errno() == .EINTR {
			continue
		}
		if n <= 0 || off >= len(buf) {
			break
		}
		off += int(n)
	}
	testing.expect_value(t, string(buf[:off]), "spawned\n")
	shell_manager_shell_close(&sh)
	shell_manager_destroy(&m)
	shell_manager_test_assert_clean(t, &track)
}

@(test)
test_shell_manager_error_message :: proc(t: ^testing.T) {
	testing.expect_value(t, shell_manager_error_message(.None), "none")
	novar := shell_manager_error_message(.No_Such_Variable)
	noshell := shell_manager_error_message(.No_Shell)
	badshell := shell_manager_error_message(.Bad_Shell)
	spawn := shell_manager_error_message(.Spawn_Failed)
	testing.expect(t, len(novar) > 0 && len(noshell) > 0 && len(badshell) > 0 && len(spawn) > 0)
	testing.expect(t, novar != noshell && novar != badshell && novar != spawn)
	testing.expect(t, noshell != badshell && noshell != spawn && badshell != spawn)
}
