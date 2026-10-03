// Tests for the hook_manager module: hook names, add/remove lists and
// should_run filtering. run_hook, exec and complete_hook_group call
// STUBBED procs (context options, command execution, completion) and are
// GAPS (see summary); the ModuleLoaded immediate-fire path of add_hook is
// likewise untestable.
package kak

import "core:testing"

// hook_manager_make_filter compiles a filter regex for the tests,
// asserting success. Ownership transfers to the caller.
hook_manager_make_filter :: proc(t: ^testing.T, pattern: string) -> Regex {
	re, msg, err := regex_make(pattern)
	if err != .None {
		delete(msg)
	}
	testing.expect_value(t, err, Regex_Error.None)
	return re
}

@(test)
hook_manager_test_names :: proc(t: ^testing.T) {
	testing.expect_value(t, len(hook_manager_hook_descs), 43)
	testing.expect_value(t, hook_manager_hook_name(.Buf_Create), "BufCreate")
	testing.expect_value(t, hook_manager_hook_name(.Module_Loaded), "ModuleLoaded")
	testing.expect_value(t, hook_manager_hook_name(.User), "User")
	testing.expect_value(t, hook_manager_hook_name(.Win_Set_Option), "WinSetOption")
	// Every enumerator has a name and the table is in enumerator order.
	for i in 0 ..< 43 {
		hook := Hook(i)
		testing.expect(t, len(hook_manager_hook_name(hook)) > 0)
		testing.expect_value(t, hook_manager_hook_descs[i].value, hook)
	}
}

@(test)
hook_manager_test_lifecycle :: proc(t: ^testing.T) {
	m := hook_manager_make()
	testing.expect_value(t, m.parent, nil)
	testing.expect_value(t, len(m.hooks), 43)
	child := hook_manager_make(&m)
	testing.expect_value(t, child.parent, &m)
	hook_manager_reparent(&child, nil)
	testing.expect_value(t, child.parent, nil)
	root := hook_manager_make()
	hook_manager_reparent(&child, &root)
	testing.expect_value(t, child.parent, &root)
	hook_manager_destroy(&child)
	hook_manager_destroy(&m)
	hook_manager_destroy(&root)
}

@(test)
hook_manager_test_add_remove :: proc(t: ^testing.T) {
	m := hook_manager_make()
	defer hook_manager_destroy(&m)
	// A dummy context: the plain add path never dereferences it.
	ctx := Context{}

	err, msg := hook_manager_add_hook(&m, .Buf_Write_Pre, "grp1", {}, hook_manager_make_filter(t, ".*"), "cmds1", &ctx)
	testing.expect_value(t, err, Command_Manager_Error.None)
	testing.expect_value(t, msg, "")
	err, msg = hook_manager_add_hook(&m, .Buf_Write_Pre, "grp2", {.Once}, hook_manager_make_filter(t, ".*"), "cmds2", &ctx)
	testing.expect_value(t, err, Command_Manager_Error.None)
	err, msg = hook_manager_add_hook(&m, .Win_Create, "grp1", {.Always}, hook_manager_make_filter(t, ".*"), "cmds3", &ctx)
	testing.expect_value(t, err, Command_Manager_Error.None)
	testing.expect_value(t, len(m.hooks[int(Hook.Buf_Write_Pre)]), 2)
	testing.expect_value(t, len(m.hooks[int(Hook.Win_Create)]), 1)

	// Removing grp1 drops it from every hook list into the trash.
	pattern := hook_manager_make_filter(t, "grp1")
	defer regex_destroy(&pattern)
	hook_manager_remove_hooks(&m, &pattern)
	testing.expect_value(t, len(m.hooks[int(Hook.Buf_Write_Pre)]), 1)
	testing.expect_value(t, len(m.hooks[int(Hook.Win_Create)]), 0)
	testing.expect_value(t, m.hooks[int(Hook.Buf_Write_Pre)][0].commands, "cmds2")
	testing.expect_value(t, len(m.hooks_trash), 2)

	// A pattern matching nothing changes nothing.
	nomatch := hook_manager_make_filter(t, "zzz")
	defer regex_destroy(&nomatch)
	hook_manager_remove_hooks(&m, &nomatch)
	testing.expect_value(t, len(m.hooks[int(Hook.Buf_Write_Pre)]), 1)
	testing.expect_value(t, len(m.hooks_trash), 2)
}

@(test)
hook_manager_test_should_run :: proc(t: ^testing.T) {
	empty_disabled := hook_manager_make_filter(t, "")
	defer regex_destroy(&empty_disabled)

	// Plain hook, matching filter.
	data := Hook_Data{group = "g", filter = hook_manager_make_filter(t, "a+")}
	defer regex_destroy(&data.filter)
	captures, should := hook_manager_should_run(&data, false, &empty_disabled, "aaa")
	defer regex_match_results_destroy(&captures)
	testing.expect(t, should)

	// Non-matching filter.
	captures2, should2 := hook_manager_should_run(&data, false, &empty_disabled, "bbb")
	defer regex_match_results_destroy(&captures2)
	testing.expect(t, !should2)

	// only_always skips hooks without the Always flag.
	captures3, should3 := hook_manager_should_run(&data, true, &empty_disabled, "aaa")
	defer regex_match_results_destroy(&captures3)
	testing.expect(t, !should3)

	// ... but Always hooks still fire.
	always_data := Hook_Data{group = "g", flags = {.Always}, filter = hook_manager_make_filter(t, "a+")}
	defer regex_destroy(&always_data.filter)
	captures4, should4 := hook_manager_should_run(&always_data, true, &empty_disabled, "aaa")
	defer regex_match_results_destroy(&captures4)
	testing.expect(t, should4)

	// A group matching disabled_hooks is skipped ...
	disabled := hook_manager_make_filter(t, "g")
	defer regex_destroy(&disabled)
	captures5, should5 := hook_manager_should_run(&data, false, &disabled, "aaa")
	defer regex_match_results_destroy(&captures5)
	testing.expect(t, !should5)

	// ... while other groups still fire.
	other := Hook_Data{group = "other", filter = hook_manager_make_filter(t, "a+")}
	defer regex_destroy(&other.filter)
	captures6, should6 := hook_manager_should_run(&other, false, &disabled, "aaa")
	defer regex_match_results_destroy(&captures6)
	testing.expect(t, should6)

	// Hooks without a group ignore disabled_hooks.
	nogroup := Hook_Data{filter = hook_manager_make_filter(t, "a+")}
	defer regex_destroy(&nogroup.filter)
	captures7, should7 := hook_manager_should_run(&nogroup, false, &disabled, "aaa")
	defer regex_match_results_destroy(&captures7)
	testing.expect(t, should7)
}

@(test)
hook_manager_test_should_run_captures :: proc(t: ^testing.T) {
	empty_disabled := hook_manager_make_filter(t, "")
	defer regex_destroy(&empty_disabled)
	data := Hook_Data{filter = hook_manager_make_filter(t, "(a)(b)")}
	defer regex_destroy(&data.filter)
	captures, should := hook_manager_should_run(&data, false, &empty_disabled, "ab")
	defer regex_match_results_destroy(&captures)
	testing.expect(t, should)
	testing.expect_value(t, regex_match_results_size(&captures), 3)
	testing.expect_value(t, regex_match_results_substring(&captures, "ab", 0), "ab")
	testing.expect_value(t, regex_match_results_substring(&captures, "ab", 1), "a")
	testing.expect_value(t, regex_match_results_substring(&captures, "ab", 2), "b")
}
