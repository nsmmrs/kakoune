package kak

import "core:strings"
import "core:sync"
import "core:testing"

// Option_Manager_Test_State counts watcher notifications.
Option_Manager_Test_State :: struct {
	count: int,
	last:  ^Option,
}

// option_manager_test_watch records notifications.
option_manager_test_watch :: proc(data: rawptr, option: rawptr) {
	st := (^Option_Manager_Test_State)(data)
	st.count += 1
	st.last = (^Option)(option)
}

// option_manager_test_setup initializes a root manager with a registry.
option_manager_test_setup :: proc(m: ^Option_Manager, reg: ^Options_Registry) {
	option_manager_init_root(m)
	option_manager_registry_init(reg, m)
}

// option_manager_test_non_negative rejects negative ints.
option_manager_test_non_negative :: proc(value: Option_Value) -> string {
	v, ok := value.(int)
	if !ok {
		return "not an int"
	}
	if v < 0 {
		return "must be >= 0"
	}
	return ""
}

// option_manager_test_strings_free frees a strings result.
option_manager_test_strings_free :: proc(strs: []string) {
	for s in strs {
		delete(s)
	}
	delete(strs)
}

// option_manager_test_roundtrip parses strs as current's variant and
// checks the value survives the trip.
option_manager_test_roundtrip :: proc(t: ^testing.T, current: Option_Value, strs: []string) {
	parsed, err, _ := option_manager_value_from_strings(current, strs)
	testing.expect_value(t, err, Option_Manager_Error.None)
	testing.expect(t, option_manager_value_equal(current, parsed))
	option_manager_value_destroy(&parsed)
}

// option_manager_test_desc_check checks the hook short form of value.
option_manager_test_desc_check :: proc(t: ^testing.T, m: ^Option_Manager, value: Option_Value, want: string) {
	desc := Option_Desc{name = "d", docstring = "d", flags = {}}
	opt := option_manager_option_make(&desc, m, value)
	defer option_manager_option_destroy(opt)
	got := option_manager_option_get_desc_string(opt)
	defer delete(got)
	testing.expect_value(t, got, want)
}

// option_manager_test_update_check checks update of value.
option_manager_test_update_check :: proc(
	t: ^testing.T,
	m: ^Option_Manager,
	ctx: ^Context,
	value: Option_Value,
	want: Option_Manager_Error,
) {
	desc := Option_Desc{name = "d", docstring = "d", flags = {}}
	opt := option_manager_option_make(&desc, m, value)
	defer option_manager_option_destroy(opt)
	testing.expect_value(t, option_manager_option_update(opt, ctx), want)
}

// Option_Manager_Test_Unreg unregisters another watcher mid-flight.
Option_Manager_Test_Unreg :: struct {
	m:     ^Option_Manager,
	other: Option_Watcher,
	count: int,
}

// option_manager_test_unreg_watch unregisters .other once, then counts.
option_manager_test_unreg_watch :: proc(data: rawptr, option: rawptr) {
	st := (^Option_Manager_Test_Unreg)(data)
	st.count += 1
	for w in st.m.watchers {
		if w == st.other {
			option_manager_unregister_watcher(st.m, st.other)
			return
		}
	}
}

@(test)
test_option_manager_declare :: proc(t: ^testing.T) {
	m: Option_Manager
	reg: Options_Registry
	option_manager_test_setup(&m, &reg)
	defer option_manager_registry_destroy(&reg)
	defer option_manager_destroy(&m)

	opt, err := option_manager_registry_declare(&reg, "tabstop", "size of a tab character", 8)
	testing.expect_value(t, err, Option_Manager_Error.None)
	testing.expect_value(t, option_manager_option_name(opt), "tabstop")
	testing.expect_value(t, option_manager_option_docstring(opt), "[int] - size of a tab character")
	testing.expect_value(t, option_manager_option_type_name(opt), "int")
	testing.expect_value(t, option_manager_option_flags(opt), Option_Flags{})
	testing.expect(t, opt.manager == &m)

	plain, _ := option_manager_registry_declare(&reg, "flag", "", true)
	testing.expect_value(t, option_manager_option_docstring(plain), "[bool]")

	same, rerr := option_manager_registry_declare(&reg, "tabstop", "other doc", 4)
	testing.expect_value(t, rerr, Option_Manager_Error.None)
	testing.expect(t, same == opt)
	v, _ := option_manager_option_get(opt).(int)
	testing.expect_value(t, v, 8)

	_, terr := option_manager_registry_declare(&reg, "tabstop", "", "str")
	testing.expect_value(t, terr, Option_Manager_Error.Type_Mismatch)

	_, ferr := option_manager_registry_declare(&reg, "tabstop", "", 8, {.Hidden})
	testing.expect_value(t, ferr, Option_Manager_Error.Type_Mismatch)

	_, nerr := option_manager_registry_declare(&reg, "bad-name!", "", 0)
	testing.expect_value(t, nerr, Option_Manager_Error.Invalid_Name)

	testing.expect(t, option_manager_registry_exists(&reg, "tabstop"))
	testing.expect(t, !option_manager_registry_exists(&reg, "nope"))
	testing.expect(t, option_manager_registry_desc(&reg, "tabstop") != nil)
	testing.expect(t, option_manager_registry_desc(&reg, "nope") == nil)

	testing.expect_value(t, option_manager_error_message(.None), "")
	testing.expect_value(t, option_manager_error_message(.Not_Found), "option not found: use declare-option first")
}

@(test)
test_option_manager_set_get_validate :: proc(t: ^testing.T) {
	m: Option_Manager
	reg: Options_Registry
	option_manager_test_setup(&m, &reg)
	defer option_manager_registry_destroy(&reg)
	defer option_manager_destroy(&m)

	opt, _ := option_manager_registry_declare(
		&reg,
		"tabstop",
		"",
		8,
		{},
		option_manager_test_non_negative,
	)
	st := Option_Manager_Test_State{}
	option_manager_register_watcher(&m, Option_Watcher{data = &st, on_option_changed = option_manager_test_watch})
	defer option_manager_unregister_watcher(
		&m,
		Option_Watcher{data = &st, on_option_changed = option_manager_test_watch},
	)

	serr, smsg := option_manager_option_set(opt, 4)
	testing.expect_value(t, serr, Option_Manager_Error.None)
	testing.expect_value(t, smsg, "")
	v, _ := option_manager_option_get(opt).(int)
	testing.expect_value(t, v, 4)
	testing.expect_value(t, st.count, 1)
	testing.expect(t, st.last == opt)

	verr, vmsg := option_manager_option_set(opt, -1)
	testing.expect_value(t, verr, Option_Manager_Error.Validation)
	testing.expect_value(t, vmsg, "must be >= 0")
	v2, _ := option_manager_option_get(opt).(int)
	testing.expect_value(t, v2, 4)
	testing.expect_value(t, st.count, 1)

	same_err, _ := option_manager_option_set(opt, 4)
	testing.expect_value(t, same_err, Option_Manager_Error.None)
	testing.expect_value(t, st.count, 1)

	qerr, _ := option_manager_option_set(opt, 6, false)
	testing.expect_value(t, qerr, Option_Manager_Error.None)
	testing.expect_value(t, st.count, 1)
	v3, _ := option_manager_option_get(opt).(int)
	testing.expect_value(t, v3, 6)

	werr, _ := option_manager_option_set(opt, "str")
	testing.expect_value(t, werr, Option_Manager_Error.Type_Mismatch)
}

@(test)
test_option_manager_inheritance :: proc(t: ^testing.T) {
	m: Option_Manager
	reg: Options_Registry
	option_manager_test_setup(&m, &reg)
	defer option_manager_registry_destroy(&reg)
	defer option_manager_destroy(&m)
	child: Option_Manager
	option_manager_init_child(&child, &m)
	defer option_manager_destroy(&child)

	_, _ = option_manager_registry_declare(&reg, "n", "", 1)
	inherited, gerr := option_manager_get_option(&child, "n")
	testing.expect_value(t, gerr, Option_Manager_Error.None)
	testing.expect(t, inherited.manager == &m)

	_, merr := option_manager_get_option(&child, "missing")
	testing.expect_value(t, merr, Option_Manager_Error.Not_Found)
	_, lerr := option_manager_get_local_option(&child, "missing")
	testing.expect_value(t, lerr, Option_Manager_Error.Not_Found)

	st := Option_Manager_Test_State{}
	option_manager_register_watcher(&child, Option_Watcher{data = &st, on_option_changed = option_manager_test_watch})
	defer option_manager_unregister_watcher(
		&child,
		Option_Watcher{data = &st, on_option_changed = option_manager_test_watch},
	)

	parent_opt, _ := option_manager_get_option(&m, "n")
	option_manager_option_set(parent_opt, 2)
	testing.expect_value(t, st.count, 1)
	testing.expect(t, st.last == parent_opt)

	local, _ := option_manager_get_local_option(&child, "n")
	testing.expect(t, local.manager == &child)
	testing.expect(t, local != parent_opt)
	lv, _ := option_manager_option_get(local).(int)
	testing.expect_value(t, lv, 2)
	option_manager_option_set(local, 3)
	pv, _ := option_manager_option_get(parent_opt).(int)
	testing.expect_value(t, pv, 2)

	st.count = 0
	option_manager_option_set(parent_opt, 4)
	testing.expect_value(t, st.count, 0)

	again, _ := option_manager_get_local_option(&child, "n")
	testing.expect(t, again == local)
}

@(test)
test_option_manager_unset :: proc(t: ^testing.T) {
	m: Option_Manager
	reg: Options_Registry
	option_manager_test_setup(&m, &reg)
	defer option_manager_registry_destroy(&reg)
	defer option_manager_destroy(&m)
	child: Option_Manager
	option_manager_init_child(&child, &m)
	defer option_manager_destroy(&child)

	_, _ = option_manager_registry_declare(&reg, "n", "", 1)
	st := Option_Manager_Test_State{}
	option_manager_register_watcher(&child, Option_Watcher{data = &st, on_option_changed = option_manager_test_watch})
	defer option_manager_unregister_watcher(
		&child,
		Option_Watcher{data = &st, on_option_changed = option_manager_test_watch},
	)

	testing.expect_value(t, option_manager_unset_option(&child, "n"), Option_Manager_Error.None)
	testing.expect_value(t, st.count, 0)

	local, _ := option_manager_get_local_option(&child, "n")
	option_manager_option_set(local, 9)
	st.count = 0
	testing.expect_value(t, option_manager_unset_option(&child, "n"), Option_Manager_Error.None)
	testing.expect(t, "n" not_in child.options)
	restored, _ := option_manager_get_option(&child, "n")
	testing.expect(t, restored.manager == &m)
	testing.expect_value(t, st.count, 1)
	testing.expect(t, st.last == restored)

	equal_local, _ := option_manager_get_local_option(&child, "n")
	_ = equal_local
	st.count = 0
	testing.expect_value(t, option_manager_unset_option(&child, "n"), Option_Manager_Error.None)
	testing.expect_value(t, st.count, 0)
}

@(test)
test_option_manager_unset_trash :: proc(t: ^testing.T) {
	g := scope_global_init()
	defer scope_global_deinit()
	reg := scope_global_option_registry(g)
	_, _ = option_manager_registry_declare(reg, "n", "", 1)
	child: Option_Manager
	option_manager_init_child(&child, scope_options(&g.scope))
	defer option_manager_destroy(&child)

	local, _ := option_manager_get_local_option(&child, "n")
	option_manager_option_set(local, 9)
	testing.expect_value(t, option_manager_unset_option(&child, "n"), Option_Manager_Error.None)
	restored, _ := option_manager_get_option(&child, "n")
	testing.expect(t, restored.manager == scope_options(&g.scope))
	// The global trash is shared with concurrently running tests, so
	// look for our own option instead of asserting exact counts.
	sync.mutex_lock(&scope_global_mutex)
	found := false
	for opt in reg.trash {
		if opt == local {
			found = true
		}
	}
	sync.mutex_unlock(&scope_global_mutex)
	testing.expect(t, found)
	option_manager_registry_clear_trash(reg)
}

@(test)
test_option_manager_unset_orphan :: proc(t: ^testing.T) {
	m: Option_Manager
	reg: Options_Registry
	option_manager_test_setup(&m, &reg)
	defer option_manager_registry_destroy(&reg)
	defer option_manager_destroy(&m)
	child: Option_Manager
	option_manager_init_child(&child, &m)
	defer option_manager_destroy(&child)

	_, _ = option_manager_registry_declare(&reg, "n", "", 1)
	_, _ = option_manager_get_local_option(&child, "n")
	parent_opt, _ := option_manager_get_option(&m, "n")
	delete_key(&m.options, "n")
	option_manager_option_destroy(parent_opt)

	testing.expect_value(t, option_manager_unset_option(&child, "n"), Option_Manager_Error.Not_Found)
	testing.expect(t, "n" in child.options)
}

@(test)
test_option_manager_flatten :: proc(t: ^testing.T) {
	m: Option_Manager
	reg: Options_Registry
	option_manager_test_setup(&m, &reg)
	defer option_manager_registry_destroy(&reg)
	defer option_manager_destroy(&m)
	p: Option_Manager
	option_manager_init_child(&p, &m)
	defer option_manager_destroy(&p)
	l: Option_Manager
	option_manager_init_child(&l, &p)
	defer option_manager_destroy(&l)

	_, _ = option_manager_registry_declare(&reg, "a", "", 1)
	_, _ = option_manager_registry_declare(&reg, "b", "", 2)
	pb, _ := option_manager_get_local_option(&p, "b")
	option_manager_option_set(pb, 20, false)
	la, _ := option_manager_get_local_option(&l, "a")
	option_manager_option_set(la, 10, false)

	flat := option_manager_flatten_options(&l)
	defer delete(flat)
	testing.expect_value(t, len(flat), 2)
	got := make(map[string]^Option, context.temp_allocator)
	for o in flat {
		got[option_manager_option_name(o)] = o
	}
	testing.expect(t, got["b"] == pb)
	testing.expect(t, got["a"] == la)
}

@(test)
test_option_manager_strings_scalar :: proc(t: ^testing.T) {
	m: Option_Manager
	reg: Options_Registry
	option_manager_test_setup(&m, &reg)
	defer option_manager_registry_destroy(&reg)
	defer option_manager_destroy(&m)

	iopt, _ := option_manager_registry_declare(&reg, "n", "", 123)
	strs := option_manager_option_get_as_strings(iopt)
	defer option_manager_test_strings_free(strs)
	testing.expect_value(t, len(strs), 1)
	testing.expect_value(t, strs[0], "123")
	option_manager_test_roundtrip(t, 123, strs)
	s := option_manager_option_get_as_string(iopt, .Raw)
	defer delete(s)
	testing.expect_value(t, s, "123")

	serr, _ := option_manager_option_set_from_strings(iopt, []string{"456"})
	testing.expect_value(t, serr, Option_Manager_Error.None)
	iv, _ := option_manager_option_get(iopt).(int)
	testing.expect_value(t, iv, 456)
	bad, _ := option_manager_option_set_from_strings(iopt, []string{"1", "2"})
	testing.expect_value(t, bad, Option_Manager_Error.Convert)
	bad2, _ := option_manager_option_set_from_strings(iopt, []string{"abc"})
	testing.expect_value(t, bad2, Option_Manager_Error.Convert)

	st := Option_Manager_Test_State{}
	w := Option_Watcher{data = &st, on_option_changed = option_manager_test_watch}
	option_manager_register_watcher(&m, w)
	defer option_manager_unregister_watcher(&m, w)
	aerr, _ := option_manager_option_add_from_strings(iopt, []string{"4"})
	testing.expect_value(t, aerr, Option_Manager_Error.None)
	av, _ := option_manager_option_get(iopt).(int)
	testing.expect_value(t, av, 460)
	testing.expect_value(t, st.count, 1)
	zerr, _ := option_manager_option_add_from_strings(iopt, []string{"0"})
	testing.expect_value(t, zerr, Option_Manager_Error.None)
	testing.expect_value(t, st.count, 1)
	rerr, _ := option_manager_option_remove_from_strings(iopt, []string{"60"})
	testing.expect_value(t, rerr, Option_Manager_Error.None)
	rv, _ := option_manager_option_get(iopt).(int)
	testing.expect_value(t, rv, 400)

	bopt, _ := option_manager_registry_declare(&reg, "b", "", true)
	option_manager_test_roundtrip(t, true, []string{"true"})
	option_manager_test_roundtrip(t, false, []string{"no"})
	berr, _ := option_manager_option_set_from_strings(bopt, []string{"bogus"})
	testing.expect_value(t, berr, Option_Manager_Error.Convert)
	bopt_add_err, _ := option_manager_option_add_from_strings(bopt, []string{"true"})
	testing.expect_value(t, bopt_add_err, Option_Manager_Error.No_Add)
	bopt_rm_err, _ := option_manager_option_remove_from_strings(bopt, []string{"true"})
	testing.expect_value(t, bopt_rm_err, Option_Manager_Error.No_Remove)

	sopt, _ := option_manager_registry_declare(&reg, "s", "", "a'b")
	raw := option_manager_option_get_as_string(sopt, .Raw)
	defer delete(raw)
	testing.expect_value(t, raw, "a'b")
	quoted := option_manager_option_get_as_string(sopt, .Kakoune)
	defer delete(quoted)
	testing.expect_value(t, quoted, "'a''b'")
	sstrs := option_manager_option_get_as_strings(sopt)
	defer option_manager_test_strings_free(sstrs)
	option_manager_test_roundtrip(t, "a'b", sstrs)
	st.count = 0
	option_manager_option_add_from_strings(sopt, []string{"c"})
	sv, _ := option_manager_option_get(sopt).(string)
	testing.expect_value(t, sv, "a'bc")
	testing.expect_value(t, st.count, 1)
	option_manager_option_add_from_strings(sopt, []string{""})
	testing.expect_value(t, st.count, 1)
	sopt_rm_err, _ := option_manager_option_remove_from_strings(sopt, []string{"c"})
	testing.expect_value(t, sopt_rm_err, Option_Manager_Error.No_Remove)
}

@(test)
test_option_manager_strings_lists :: proc(t: ^testing.T) {
	m: Option_Manager
	reg: Options_Registry
	option_manager_test_setup(&m, &reg)
	defer option_manager_registry_destroy(&reg)
	defer option_manager_destroy(&m)

	init_sl := make([dynamic]string)
	append(&init_sl, "foo", "bar:", "baz")
	defer delete(init_sl)
	sl, _ := option_manager_registry_declare(&reg, "sl", "", init_sl)
	strs := option_manager_option_get_as_strings(sl)
	defer option_manager_test_strings_free(strs)
	testing.expect_value(t, len(strs), 3)
	option_manager_test_roundtrip(t, init_sl, strs)
	joined := option_manager_option_get_as_string(sl, .Raw)
	defer delete(joined)
	testing.expect_value(t, joined, "foo bar: baz")

	st := Option_Manager_Test_State{}
	w := Option_Watcher{data = &st, on_option_changed = option_manager_test_watch}
	option_manager_register_watcher(&m, w)
	defer option_manager_unregister_watcher(&m, w)
	option_manager_option_add_from_strings(sl, []string{"x"})
	slv, _ := option_manager_option_get(sl).([dynamic]string)
	testing.expect_value(t, len(slv), 4)
	testing.expect_value(t, st.count, 1)
	option_manager_option_add_from_strings(sl, []string{})
	testing.expect_value(t, st.count, 1)
	option_manager_option_remove_from_strings(sl, []string{"bar:", "missing"})
	slv2, _ := option_manager_option_get(sl).([dynamic]string)
	testing.expect_value(t, len(slv2), 3)
	testing.expect_value(t, st.count, 2)
	option_manager_option_remove_from_strings(sl, []string{"missing"})
	testing.expect_value(t, st.count, 2)

	init_il := make([dynamic]int)
	append(&init_il, 10, 20, 30)
	defer delete(init_il)
	il, _ := option_manager_registry_declare(&reg, "il", "", init_il)
	istrs := option_manager_option_get_as_strings(il)
	defer option_manager_test_strings_free(istrs)
	option_manager_test_roundtrip(t, init_il, istrs)
	option_manager_option_add_from_strings(il, []string{"40"})
	ilv, _ := option_manager_option_get(il).([dynamic]int)
	testing.expect_value(t, len(ilv), 4)
	testing.expect_value(t, ilv[3], 40)
	ibad, _ := option_manager_option_add_from_strings(il, []string{"bad"})
	testing.expect_value(t, ibad, Option_Manager_Error.Convert)
	ilv, _ = option_manager_option_get(il).([dynamic]int)
	testing.expect_value(t, len(ilv), 4)
	option_manager_option_remove_from_strings(il, []string{"20"})
	ilv, _ = option_manager_option_get(il).([dynamic]int)
	testing.expect_value(t, len(ilv), 3)
	irm, _ := option_manager_option_remove_from_strings(il, []string{"bad"})
	testing.expect_value(t, irm, Option_Manager_Error.Convert)

	init_rl := make([dynamic]rune)
	append(&init_rl, 'a', 'é')
	defer delete(init_rl)
	rl, _ := option_manager_registry_declare(&reg, "rl", "", init_rl)
	rstrs := option_manager_option_get_as_strings(rl)
	defer option_manager_test_strings_free(rstrs)
	testing.expect_value(t, len(rstrs), 2)
	testing.expect_value(t, rstrs[0], "a")
	testing.expect_value(t, rstrs[1], "é")
	option_manager_test_roundtrip(t, init_rl, rstrs)
	option_manager_option_add_from_strings(rl, []string{"z"})
	rlv, _ := option_manager_option_get(rl).([dynamic]rune)
	testing.expect_value(t, len(rlv), 3)
	rbad, _ := option_manager_option_add_from_strings(rl, []string{"toolong"})
	testing.expect_value(t, rbad, Option_Manager_Error.Convert)
	rlv, _ = option_manager_option_get(rl).([dynamic]rune)
	testing.expect_value(t, len(rlv), 3)
	option_manager_option_remove_from_strings(rl, []string{"a"})
	rlv, _ = option_manager_option_get(rl).([dynamic]rune)
	testing.expect_value(t, len(rlv), 2)
}

@(test)
test_option_manager_strings_regex_coord :: proc(t: ^testing.T) {
	m: Option_Manager
	reg: Options_Registry
	option_manager_test_setup(&m, &reg)
	defer option_manager_registry_destroy(&reg)
	defer option_manager_destroy(&m)

	rx, _ := option_manager_registry_declare(&reg, "rx", "", Regex{})
	rstr := option_manager_option_get_as_string(rx, .Raw)
	defer delete(rstr)
	testing.expect_value(t, rstr, "")
	rerr, _ := option_manager_option_set_from_strings(rx, []string{"a+b"})
	testing.expect_value(t, rerr, Option_Manager_Error.None)
	rstr2 := option_manager_option_get_as_string(rx, .Raw)
	defer delete(rstr2)
	testing.expect_value(t, rstr2, "a+b")
	bad, _ := option_manager_option_set_from_strings(rx, []string{"["})
	testing.expect_value(t, bad, Option_Manager_Error.Regex)
	multi, _ := option_manager_option_set_from_strings(rx, []string{"a", "b"})
	testing.expect_value(t, multi, Option_Manager_Error.Convert)
	rx_add_err, _ := option_manager_option_add_from_strings(rx, []string{"c"})
	testing.expect_value(t, rx_add_err, Option_Manager_Error.No_Add)
	rx_rm_err, _ := option_manager_option_remove_from_strings(rx, []string{"c"})
	testing.expect_value(t, rx_rm_err, Option_Manager_Error.No_Remove)
	rx2, _ := option_manager_registry_declare(&reg, "rx2", "", Regex{})
	option_manager_option_set_from_strings(rx2, []string{"a+b"})
	testing.expect(t, option_manager_option_has_same_value(rx, rx2))
	option_manager_option_set_from_strings(rx2, []string{"a+c"})
	testing.expect(t, !option_manager_option_has_same_value(rx, rx2))

	co, _ := option_manager_registry_declare(&reg, "co", "", Coord_Display{line = 3, column = 7})
	cstr := option_manager_option_get_as_string(co, .Raw)
	defer delete(cstr)
	testing.expect_value(t, cstr, "3,7")
	cstrs := option_manager_option_get_as_strings(co)
	defer option_manager_test_strings_free(cstrs)
	option_manager_test_roundtrip(t, Coord_Display{line = 3, column = 7}, cstrs)
	cerr, _ := option_manager_option_set_from_strings(co, []string{"1"})
	testing.expect_value(t, cerr, Option_Manager_Error.Convert)
	cerr2, _ := option_manager_option_set_from_strings(co, []string{"a,b"})
	testing.expect_value(t, cerr2, Option_Manager_Error.Convert)
	co_add_err, _ := option_manager_option_add_from_strings(co, []string{"1,1"})
	testing.expect_value(t, co_add_err, Option_Manager_Error.No_Add)
	co_rm_err, _ := option_manager_option_remove_from_strings(co, []string{"1,1"})
	testing.expect_value(t, co_rm_err, Option_Manager_Error.No_Remove)
}

@(test)
test_option_manager_strings_completion :: proc(t: ^testing.T) {
	m: Option_Manager
	reg: Options_Registry
	option_manager_test_setup(&m, &reg)
	defer option_manager_registry_destroy(&reg)
	defer option_manager_destroy(&m)

	init_cl := Insert_Completer_Completion_List{prefix = "desc"}
	append(&init_cl.list, Completion_Candidate{completion = "comp", menu_entry = "menu", on_select = "sel"})
	append(&init_cl.list, Completion_Candidate{completion = "a|b", menu_entry = "", on_select = "x\\y"})
	defer delete(init_cl.list)
	cl, _ := option_manager_registry_declare(&reg, "cl", "", init_cl)
	testing.expect_value(t, option_manager_option_type_name(cl), "completions")

	strs := option_manager_option_get_as_strings(cl)
	defer option_manager_test_strings_free(strs)
	testing.expect_value(t, len(strs), 3)
	testing.expect_value(t, strs[0], "desc")
	testing.expect_value(t, strs[1], "comp|sel|menu")
	testing.expect_value(t, strs[2], "a\\|b|x\\\\y|")
	option_manager_test_roundtrip(t, init_cl, strs)

	single := option_manager_option_get_as_string(cl, .Raw)
	defer delete(single)
	testing.expect_value(t, single, "desc comp|sel|menu a\\|b|x\\\\y|")

	empty: Insert_Completer_Completion_List
	defer delete(empty.list)
	option_manager_test_roundtrip(t, empty, []string{})

	st := Option_Manager_Test_State{}
	w := Option_Watcher{data = &st, on_option_changed = option_manager_test_watch}
	option_manager_register_watcher(&m, w)
	defer option_manager_unregister_watcher(&m, w)
	option_manager_option_add_from_strings(cl, []string{"n|o|m"})
	clv, _ := option_manager_option_get(cl).(Insert_Completer_Completion_List)
	testing.expect_value(t, len(clv.list), 3)
	testing.expect_value(t, clv.list[2].completion, "n")
	testing.expect_value(t, st.count, 1)
	cbad, _ := option_manager_option_add_from_strings(cl, []string{"only|two"})
	testing.expect_value(t, cbad, Option_Manager_Error.Convert)
	testing.expect_value(t, len(clv.list), 3)
	option_manager_option_remove_from_strings(cl, []string{"comp|sel|menu"})
	clv, _ = option_manager_option_get(cl).(Insert_Completer_Completion_List)
	testing.expect_value(t, len(clv.list), 2)
	testing.expect_value(t, st.count, 2)
}

@(test)
test_option_manager_strings_line_specs :: proc(t: ^testing.T) {
	m: Option_Manager
	reg: Options_Registry
	option_manager_test_setup(&m, &reg)
	defer option_manager_registry_destroy(&reg)
	defer option_manager_destroy(&m)

	init_ls := Line_And_Spec_List {
		prefixed = Option_types_Prefixed_List(uint, Line_And_Spec){prefix = 42},
	}
	append(&init_ls.list, Line_And_Spec{line = 0, spec = "other"})
	append(&init_ls.list, Line_And_Spec{line = 2, spec = "flag"})
	defer delete(init_ls.list)
	ls, _ := option_manager_registry_declare(&reg, "ls", "", init_ls)
	testing.expect_value(t, option_manager_option_type_name(ls), "line-specs")

	strs := option_manager_option_get_as_strings(ls)
	defer option_manager_test_strings_free(strs)
	testing.expect_value(t, len(strs), 3)
	testing.expect_value(t, strs[0], "42")
	testing.expect_value(t, strs[1], "0|other")
	testing.expect_value(t, strs[2], "2|flag")
	option_manager_test_roundtrip(t, init_ls, strs)

	serr, _ := option_manager_option_set_from_strings(ls, []string{"7", "5|b", "1|a"})
	testing.expect_value(t, serr, Option_Manager_Error.None)
	lsv, _ := option_manager_option_get(ls).(Line_And_Spec_List)
	testing.expect_value(t, lsv.prefix, uint(7))
	testing.expect_value(t, len(lsv.list), 2)
	testing.expect_value(t, int(lsv.list[0].line), 1)
	testing.expect_value(t, int(lsv.list[1].line), 5)
	lbad, _ := option_manager_option_set_from_strings(ls, []string{"x"})
	testing.expect_value(t, lbad, Option_Manager_Error.Convert)

	option_manager_option_add_from_strings(ls, []string{"3|c", "0|z"})
	lsv, _ = option_manager_option_get(ls).(Line_And_Spec_List)
	testing.expect_value(t, len(lsv.list), 4)
	testing.expect_value(t, int(lsv.list[0].line), 0)
	testing.expect_value(t, int(lsv.list[3].line), 5)
	option_manager_option_remove_from_strings(ls, []string{"3|c"})
	lsv, _ = option_manager_option_get(ls).(Line_And_Spec_List)
	testing.expect_value(t, len(lsv.list), 3)
}

@(test)
test_option_manager_strings_range_specs :: proc(t: ^testing.T) {
	r := option_manager_inclusive_range_to_string(
		Inclusive_Buffer_Range {
			first = Coord_Buffer{line = 0, column = 0},
			last = Coord_Buffer{line = 1, column = 2},
		},
	)
	defer delete(r)
	testing.expect_value(t, r, "1.1,2.3")

	empty := option_manager_inclusive_range_to_string(
		Inclusive_Buffer_Range {
			first = Coord_Buffer{line = 4, column = 4},
			last = Coord_Buffer{line = -1, column = -1},
		},
	)
	defer delete(empty)
	testing.expect_value(t, empty, "5.5+0")

	parsed, perr := option_manager_inclusive_range_from_string("1.1,2.3")
	testing.expect_value(t, perr, Option_types_Error.None)
	testing.expect_value(t, int(parsed.first.line), 0)
	testing.expect_value(t, int(parsed.last.column), 2)
	swapped, _ := option_manager_inclusive_range_from_string("2.3,1.1")
	testing.expect(t, swapped == parsed)
	plus, _ := option_manager_inclusive_range_from_string("2.3+4")
	testing.expect_value(t, int(plus.first.line), 1)
	testing.expect_value(t, int(plus.first.column), 2)
	testing.expect_value(t, int(plus.last.line), 1)
	testing.expect_value(t, int(plus.last.column), 5)
	plus0, _ := option_manager_inclusive_range_from_string("2.3+0")
	testing.expect(t, option_manager_inclusive_range_empty(plus0))
	_, e1 := option_manager_inclusive_range_from_string("1.1")
	testing.expect(t, e1 != .None)
	_, e2 := option_manager_inclusive_range_from_string("0.1,2.3")
	testing.expect(t, e2 != .None)
	_, e3 := option_manager_inclusive_range_from_string("1,2.3")
	testing.expect(t, e3 != .None)

	m: Option_Manager
	reg: Options_Registry
	option_manager_test_setup(&m, &reg)
	defer option_manager_registry_destroy(&reg)
	defer option_manager_destroy(&m)
	init_rs := Range_And_String_List {
		prefixed = Option_types_Prefixed_List(uint, Range_And_String){prefix = 9},
	}
	append(
		&init_rs.list,
		Range_And_String {
			range = Inclusive_Buffer_Range {
				first = Coord_Buffer{line = 0, column = 0},
				last = Coord_Buffer{line = 0, column = 1},
			},
			spec = "face",
		},
	)
	defer delete(init_rs.list)
	rs, _ := option_manager_registry_declare(&reg, "rs", "", init_rs)
	testing.expect_value(t, option_manager_option_type_name(rs), "range-specs")
	strs := option_manager_option_get_as_strings(rs)
	defer option_manager_test_strings_free(strs)
	testing.expect_value(t, len(strs), 2)
	testing.expect_value(t, strs[0], "9")
	testing.expect_value(t, strs[1], "1.1,1.2|face")
	option_manager_test_roundtrip(t, init_rs, strs)

	option_manager_option_add_from_strings(rs, []string{"3.1,3.1|late", "1.1,1.1|early"})
	rsv, _ := option_manager_option_get(rs).(Range_And_String_List)
	testing.expect_value(t, len(rsv.list), 3)
	testing.expect_value(t, rsv.list[0].spec, "early")
	testing.expect_value(t, rsv.list[2].spec, "late")
	option_manager_option_remove_from_strings(rs, []string{"1.1,1.1|early"})
	rsv, _ = option_manager_option_get(rs).(Range_And_String_List)
	testing.expect_value(t, len(rsv.list), 2)
	rbad, _ := option_manager_option_add_from_strings(rs, []string{"bogus"})
	testing.expect_value(t, rbad, Option_Manager_Error.Convert)
}

@(test)
test_option_manager_strings_map :: proc(t: ^testing.T) {
	m: Option_Manager
	reg: Options_Registry
	option_manager_test_setup(&m, &reg)
	defer option_manager_registry_destroy(&reg)
	defer option_manager_destroy(&m)

	init_map := make(map[string]string)
	defer delete(init_map)
	init_map["foo"] = "10"
	init_map["b=r"] = "20"
	init_map["plain"] = "x"
	mo, _ := option_manager_registry_declare(&reg, "mo", "", init_map)
	testing.expect_value(t, option_manager_option_type_name(mo), "str-to-str-map")

	strs := option_manager_option_get_as_strings(mo)
	defer option_manager_test_strings_free(strs)
	testing.expect_value(t, len(strs), 3)
	seen := make(map[string]bool, context.temp_allocator)
	for s in strs {
		seen[s] = true
	}
	testing.expect(t, seen["foo=10"])
	testing.expect(t, seen["b\\=r=20"])
	testing.expect(t, seen["plain=x"])
	mov, _ := option_manager_option_get(mo).(map[string]string)
	option_manager_test_roundtrip(t, mov, strs)

	st := Option_Manager_Test_State{}
	w := Option_Watcher{data = &st, on_option_changed = option_manager_test_watch}
	option_manager_register_watcher(&m, w)
	defer option_manager_unregister_watcher(&m, w)
	option_manager_option_add_from_strings(mo, []string{"k=v", "foo=99"})
	testing.expect_value(t, mov["foo"], "99")
	testing.expect_value(t, mov["k"], "v")
	testing.expect_value(t, st.count, 1)
	mbad, _ := option_manager_option_add_from_strings(mo, []string{"noequals"})
	testing.expect_value(t, mbad, Option_Manager_Error.Convert)
	testing.expect_value(t, st.count, 1)

	kbare, _ := option_manager_option_remove_from_strings(mo, []string{"k"})
	testing.expect_value(t, kbare, Option_Manager_Error.Convert)
	option_manager_option_remove_from_strings(mo, []string{"k="})
	_, kok := mov["k"]
	testing.expect(t, !kok)
	option_manager_option_remove_from_strings(mo, []string{"foo=wrong"})
	_, fok := mov["foo"]
	testing.expect(t, fok)
	option_manager_option_remove_from_strings(mo, []string{"foo=99"})
	_, fok2 := mov["foo"]
	testing.expect(t, !fok2)
	testing.expect_value(t, st.count, 3)
}

@(test)
test_option_manager_update_clone :: proc(t: ^testing.T) {
	m: Option_Manager
	reg: Options_Registry
	option_manager_test_setup(&m, &reg)
	defer option_manager_registry_destroy(&reg)
	defer option_manager_destroy(&m)
	ctx := Context{}
	defer delete(ctx.local_scopes)

	option_manager_test_update_check(t, &m, &ctx, 1, .No_Update)
	option_manager_test_update_check(t, &m, &ctx, true, .No_Update)
	option_manager_test_update_check(t, &m, &ctx, "s", .No_Update)
	option_manager_test_update_check(t, &m, &ctx, Regex{}, .No_Update)
	option_manager_test_update_check(t, &m, &ctx, Coord_Display{}, .No_Update)
	option_manager_test_update_check(t, &m, &ctx, Insert_Completer_Completion_List{}, .No_Update)
	// NOTE: spec-list updates call the STUBBED highlighter procs;
	// covered at integration.

	init_il := make([dynamic]int)
	append(&init_il, 1, 2)
	defer delete(init_il)
	opt, _ := option_manager_registry_declare(&reg, "il", "", init_il)
	clone := option_manager_option_clone(opt, &m)
	defer option_manager_option_destroy(clone)
	testing.expect(t, clone != opt)
	testing.expect(t, clone.manager == &m)
	testing.expect(t, clone.desc == opt.desc)
	testing.expect(t, option_manager_option_has_same_value(opt, clone))
	option_manager_option_set_from_strings(opt, []string{"3"})
	testing.expect(t, !option_manager_option_has_same_value(opt, clone))
	cv, _ := option_manager_option_get(clone).([dynamic]int)
	testing.expect_value(t, len(cv), 2)

	other, _ := option_manager_registry_declare(&reg, "s", "", "x")
	testing.expect(t, !option_manager_option_has_same_value(opt, other))
}

@(test)
test_option_manager_desc_and_type_names :: proc(t: ^testing.T) {
	m: Option_Manager
	option_manager_init_root(&m)
	defer option_manager_destroy(&m)

	option_manager_test_desc_check(t, &m, 8, "8")
	option_manager_test_desc_check(t, &m, true, "true")
	option_manager_test_desc_check(t, &m, "raw", "raw")
	sl: [dynamic]string
	il: [dynamic]int
	rl: [dynamic]rune
	mp: map[string]string
	option_manager_test_desc_check(t, &m, sl, "...")
	option_manager_test_desc_check(t, &m, il, "...")
	option_manager_test_desc_check(t, &m, rl, "...")
	option_manager_test_desc_check(t, &m, Regex{}, "...")
	option_manager_test_desc_check(t, &m, Coord_Display{}, "...")
	option_manager_test_desc_check(t, &m, Insert_Completer_Completion_List{}, "...")
	option_manager_test_desc_check(t, &m, Line_And_Spec_List{}, "...")
	option_manager_test_desc_check(t, &m, Range_And_String_List{}, "...")
	option_manager_test_desc_check(t, &m, mp, "...")

	testing.expect_value(t, option_manager_value_type_name(0), "int")
	testing.expect_value(t, option_manager_value_type_name(true), "bool")
	testing.expect_value(t, option_manager_value_type_name(""), "str")
	testing.expect_value(t, option_manager_value_type_name(sl), "str-list")
	testing.expect_value(t, option_manager_value_type_name(il), "int-list")
	testing.expect_value(t, option_manager_value_type_name(rl), "codepoint-list")
	testing.expect_value(t, option_manager_value_type_name(Regex{}), "regex")
	testing.expect_value(t, option_manager_value_type_name(Coord_Display{}), "coord")
	testing.expect_value(t, option_manager_value_type_name(Insert_Completer_Completion_List{}), "completions")
	testing.expect_value(t, option_manager_value_type_name(Line_And_Spec_List{}), "line-specs")
	testing.expect_value(t, option_manager_value_type_name(Range_And_String_List{}), "range-specs")
	testing.expect_value(t, option_manager_value_type_name(mp), "str-to-str-map")
	testing.expect_value(t, option_manager_value_tag(0), option_manager_value_tag(1))
	testing.expect(t, option_manager_value_tag(0) != option_manager_value_tag("s"))
}

@(test)
test_option_manager_complete :: proc(t: ^testing.T) {
	m: Option_Manager
	reg: Options_Registry
	option_manager_test_setup(&m, &reg)
	defer option_manager_registry_destroy(&reg)
	defer option_manager_destroy(&m)

	_, _ = option_manager_registry_declare(&reg, "tabstop", "", 8)
	_, _ = option_manager_registry_declare(&reg, "tagstack", "", "x")
	_, _ = option_manager_registry_declare(&reg, "secret", "", 0, {.Hidden})

	res := option_manager_registry_complete_name(&reg, "tabs", Units_ByteCount(4))
	defer option_manager_candidates_free(&res)
	testing.expect_value(t, len(res), 1)
	if len(res) == 1 {
		testing.expect_value(t, res[0], "tabstop")
	}

	clamped := option_manager_registry_complete_name(&reg, "tabstopZZZ", Units_ByteCount(4))
	defer option_manager_candidates_free(&clamped)
	testing.expect_value(t, len(clamped), 1)

	all := option_manager_registry_complete_name(&reg, "", Units_ByteCount(0))
	defer option_manager_candidates_free(&all)
	testing.expect_value(t, len(all), 2)
	for c in all {
		testing.expect(t, c != "secret")
	}
}

@(test)
test_option_manager_trash :: proc(t: ^testing.T) {
	m: Option_Manager
	reg: Options_Registry
	option_manager_test_setup(&m, &reg)
	defer option_manager_registry_destroy(&reg)
	defer option_manager_destroy(&m)

	opt, _ := option_manager_registry_declare(&reg, "n", "", 1)
	extra := option_manager_option_clone(opt, &m)
	option_manager_registry_move_to_trash(&reg, extra)
	testing.expect_value(t, len(reg.trash), 1)
	option_manager_registry_clear_trash(&reg)
	testing.expect_value(t, len(reg.trash), 0)
	option_manager_registry_clear_trash(&reg)
	testing.expect_value(t, len(reg.trash), 0)
}

@(test)
test_option_manager_unregister_midflight :: proc(t: ^testing.T) {
	m: Option_Manager
	reg: Options_Registry
	option_manager_test_setup(&m, &reg)
	defer option_manager_registry_destroy(&reg)
	defer option_manager_destroy(&m)

	opt, _ := option_manager_registry_declare(&reg, "n", "", 1)
	st2 := Option_Manager_Test_State{}
	w2 := Option_Watcher{data = &st2, on_option_changed = option_manager_test_watch}
	un := Option_Manager_Test_Unreg{m = &m, other = w2}
	w1 := Option_Watcher{data = &un, on_option_changed = option_manager_test_unreg_watch}
	option_manager_register_watcher(&m, w1)
	option_manager_register_watcher(&m, w2)
	defer option_manager_unregister_watcher(&m, w1)

	option_manager_option_set(opt, 2)
	testing.expect_value(t, un.count, 1)
	testing.expect_value(t, st2.count, 0)
	option_manager_option_set(opt, 3)
	testing.expect_value(t, un.count, 2)
	testing.expect_value(t, st2.count, 0)
}

// option_manager_test_enum_options covers the 5 plain-enum option
// variants (Eol_Format, Final_Eol, Byte_Order_Mark, Autoreload,
// File_Write_Method): names, parse, first-match formatting, aliases,
// and the single-value/error paths.
@(test)
option_manager_test_enum_options :: proc(t: ^testing.T) {
	// to_string uses the FIRST desc name (Autoreload.Yes -> "yes").
	s1 := option_manager_value_to_string(Option_Value(Eol_Format.Crlf), .Raw)
	defer delete(s1)
	testing.expect_value(t, s1, "crlf")
	s2 := option_manager_value_to_string(Option_Value(Autoreload.Yes), .Raw)
	defer delete(s2)
	testing.expect_value(t, s2, "yes")
	s3 := option_manager_value_to_string(Option_Value(File_Write_Method.Replace), .Raw)
	defer delete(s3)
	testing.expect_value(t, s3, "replace")

	// from_string parses names, incl. the true/false aliases.
	v, err, _ := option_manager_value_from_strings(Option_Value(Autoreload.Yes), {"true"})
	testing.expect_value(t, err, Option_Manager_Error.None)
	testing.expect_value(t, v.(Autoreload), Autoreload.Yes)
	v, err, _ = option_manager_value_from_strings(Option_Value(Autoreload.Yes), {"ask"})
	testing.expect_value(t, err, Option_Manager_Error.None)
	testing.expect_value(t, v.(Autoreload), Autoreload.Ask)
	v, err, _ = option_manager_value_from_strings(Option_Value(Final_Eol.Present), {"ifnotempty"})
	testing.expect_value(t, err, Option_Manager_Error.None)
	testing.expect_value(t, v.(Final_Eol), Final_Eol.If_Not_Empty)

	// Invalid names and multi-value input fail like the C++ throws.
	_, emerr, emsg := option_manager_value_from_strings(Option_Value(Autoreload.Yes), {"maybe"})
	testing.expect_value(t, emerr, Option_Manager_Error.Convert)
	testing.expect_value(t, emsg, "invalid enum value")
	_, err, emsg = option_manager_value_from_strings(Option_Value(Autoreload.Yes), {"yes", "no"})
	testing.expect_value(t, err, Option_Manager_Error.Convert)
	testing.expect_value(t, emsg, "expected a single value for option")

	// to_strings wraps the single name; add/remove are unsupported.
	strs := option_manager_value_to_strings(Option_Value(Byte_Order_Mark.Utf8))
	defer option_manager_test_strings_free(strs)
	testing.expect_value(t, len(strs), 1)
	testing.expect_value(t, strs[0], "utf8")
	ev: Option_Value = Eol_Format.Lf
	_, aerr, _ := option_manager_value_add(&ev, {"crlf"})
	testing.expect_value(t, aerr, Option_Manager_Error.No_Add)
	_, rerr, _ := option_manager_value_remove(&ev, {"lf"})
	testing.expect_value(t, rerr, Option_Manager_Error.No_Remove)
}

// option_manager_test_flags_options covers the 3 flags option variants:
// desc-order formatting, '|' parsing, and the empty/invalid paths.
@(test)
option_manager_test_flags_options :: proc(t: ^testing.T) {
	// Formatting follows desc order regardless of set order.
	s1 := option_manager_value_to_string(Option_Value(Auto_Info{.Normal, .Command}), .Raw)
	defer delete(s1)
	testing.expect_value(t, s1, "command|normal")
	s2 := option_manager_value_to_string(Option_Value(Auto_Info{}), .Raw)
	defer delete(s2)
	testing.expect_value(t, s2, "")
	s3 := option_manager_value_to_string(Option_Value(Option_types_Debug_Flags{.Keys, .Hooks}), .Raw)
	defer delete(s3)
	testing.expect_value(t, s3, "hooks|keys")

	// Parsing splits on '|' and rejects unknown/empty segments.
	v, err, _ := option_manager_value_from_strings(Option_Value(Auto_Complete{}), {"prompt|insert"})
	testing.expect_value(t, err, Option_Manager_Error.None)
	testing.expect_value(t, v.(Auto_Complete), Auto_Complete{.Insert, .Prompt})
	_, fmerr, fmsg := option_manager_value_from_strings(Option_Value(Auto_Complete{}), {"insert|bogus"})
	testing.expect_value(t, fmerr, Option_Manager_Error.Convert)
	testing.expect_value(t, fmsg, "invalid flag value")
	_, err, _ = option_manager_value_from_strings(Option_Value(Auto_Complete{}), {""})
	testing.expect_value(t, err, Option_Manager_Error.Convert)
	_, err, fmsg = option_manager_value_from_strings(Option_Value(Auto_Complete{}), {"insert", "prompt"})
	testing.expect_value(t, err, Option_Manager_Error.Convert)
	testing.expect_value(t, fmsg, "expected a single value for option")

	// add ORs the group and reports real changes (C++ old-vs-new).
	fv: Option_Value = Auto_Info{.Command}
	changed, cerr, _ := option_manager_value_add(&fv, {"normal|command"})
	testing.expect_value(t, cerr, Option_Manager_Error.None)
	testing.expect_value(t, changed, true)
	testing.expect_value(t, fv.(Auto_Info), Auto_Info{.Command, .Normal})
	changed, cerr, _ = option_manager_value_add(&fv, {"command"})
	testing.expect_value(t, cerr, Option_Manager_Error.None)
	testing.expect_value(t, changed, false)
	_, err, _ = option_manager_value_add(&fv, {"command", "normal"})
	testing.expect_value(t, err, Option_Manager_Error.Convert)

	// remove clears the group and reports real changes.
	changed, err, _ = option_manager_value_remove(&fv, {"command|normal"})
	testing.expect_value(t, err, Option_Manager_Error.None)
	testing.expect_value(t, changed, true)
	testing.expect_value(t, fv.(Auto_Info), Auto_Info{})
	changed, err, _ = option_manager_value_remove(&fv, {"command"})
	testing.expect_value(t, err, Option_Manager_Error.None)
	testing.expect_value(t, changed, false)
}

// option_manager_test_completer_options covers the completer-desc list
// variant: all four modes, invalid descriptions, and list add/remove.
@(test)
option_manager_test_completer_options :: proc(t: ^testing.T) {
	empty := make([dynamic]Insert_Completer_Desc)
	defer delete(empty)
	current := Option_Value(empty)
	v, err, _ := option_manager_value_from_strings(current, {"word=all", "filename", "option=path", "line=buffer"})
	testing.expect_value(t, err, Option_Manager_Error.None)
	lv := v.([dynamic]Insert_Completer_Desc)
	defer option_manager_value_destroy(&v)
	testing.expect_value(t, len(lv), 4)
	testing.expect_value(t, lv[0].mode, Insert_Completer_Desc_Mode.Word)
	testing.expect_value(t, lv[0].param, Maybe(string)("all"))
	testing.expect_value(t, lv[1].mode, Insert_Completer_Desc_Mode.Filename)
	testing.expect_value(t, lv[2].param, Maybe(string)("path"))
	testing.expect_value(t, lv[3].mode, Insert_Completer_Desc_Mode.Line)

	// Invalid descriptions fail the whole parse (C++ throws).
	_, cmerr, cmsg := option_manager_value_from_strings(current, {"word=all", "word=something"})
	testing.expect_value(t, cmerr, Option_Manager_Error.Convert)
	testing.expect_value(t, cmsg, "invalid completer description")
	_, err, _ = option_manager_value_from_strings(current, {"filenamex"})
	testing.expect_value(t, err, Option_Manager_Error.Convert)

	// Lists format space-joined and support add/remove of members.
	s := option_manager_value_to_string(v, .Raw)
	defer delete(s)
	testing.expect_value(t, s, "word=all filename option=path line=buffer")
	changed, cerr, _ := option_manager_value_add(&v, {"word=buffer"})
	testing.expect_value(t, cerr, Option_Manager_Error.None)
	testing.expect_value(t, changed, true)
	testing.expect_value(t, len(v.([dynamic]Insert_Completer_Desc)), 5)
	changed, cerr, _ = option_manager_value_remove(&v, {"filename"})
	testing.expect_value(t, cerr, Option_Manager_Error.None)
	testing.expect_value(t, changed, true)
	testing.expect_value(t, len(v.([dynamic]Insert_Completer_Desc)), 4)
	changed, cerr, _ = option_manager_value_remove(&v, {"filename"})
	testing.expect_value(t, cerr, Option_Manager_Error.None)
	testing.expect_value(t, changed, false)
}

// option_manager_test_new_type_names checks tags and type names for the
// 9 union variants added after this module was first written.
@(test)
option_manager_test_new_type_names :: proc(t: ^testing.T) {
	vals := [9]Option_Value{
		Eol_Format.Lf,
		Final_Eol.Present,
		Byte_Order_Mark.None,
		Autoreload.Yes,
		Auto_Info{},
		Auto_Complete{},
		Option_types_Debug_Flags{},
		make([dynamic]Insert_Completer_Desc),
		File_Write_Method.Overwrite,
	}
	defer option_manager_value_destroy(&vals[7])
	names := [9]string{
		"enum(lf|crlf)",
		"enum(present|missing|ifnotempty)",
		"enum(none|utf8)",
		"enum(yes|no|ask|true|false)",
		"flags(command|onkey|normal)",
		"flags(insert|prompt)",
		"flags(hooks|shell|profile|keys|commands)",
		"completer-list",
		"enum(overwrite|replace)",
	}
	for i := 0; i < 9; i += 1 {
		testing.expect_value(t, option_manager_value_tag(vals[i]), 12 + i)
		testing.expect_value(t, option_manager_value_type_name(vals[i]), names[i])
	}
}

// option_manager_test_new_equal_clone checks equality and deep-copying
// for the new variants, including cross-variant inequality.
@(test)
option_manager_test_new_equal_clone :: proc(t: ^testing.T) {
	testing.expect(t, option_manager_value_equal(Option_Value(Autoreload.No), Option_Value(Autoreload.No)))
	testing.expect(t, !option_manager_value_equal(Option_Value(Autoreload.No), Option_Value(Autoreload.Yes)))
	testing.expect(t, !option_manager_value_equal(Option_Value(Autoreload.Yes), Option_Value(true)))
	testing.expect(t, option_manager_value_equal(Option_Value(Auto_Info{.Command}), Option_Value(Auto_Info{.Command})))
	testing.expect(t, !option_manager_value_equal(Option_Value(Auto_Info{.Command}), Option_Value(Auto_Info{})))

	a := make([dynamic]Insert_Completer_Desc)
	append(&a, Insert_Completer_Desc{mode = .Option, param = strings.clone("path")})
	av: Option_Value = a
	defer option_manager_value_destroy(&av)
	b := make([dynamic]Insert_Completer_Desc)
	append(&b, Insert_Completer_Desc{mode = .Option, param = strings.clone("path")})
	bv: Option_Value = b
	defer option_manager_value_destroy(&bv)
	testing.expect(t, option_manager_value_equal(av, bv))

	// Clones own their params: destroying the source keeps the clone valid.
	cv := option_manager_value_clone(av)
	defer option_manager_value_destroy(&cv)
	testing.expect(t, option_manager_value_equal(av, cv))
	cl := cv.([dynamic]Insert_Completer_Desc)
	testing.expect(t, cl[0].param != nil)
	testing.expect_value(t, cl[0].param.?, "path")
	testing.expect(t, raw_data(cl[0].param.?) != raw_data(a[0].param.?))
}

// option_manager_test_new_options_end_to_end declares enum and flags
// options through the registry and exercises set/get/desc/update.
@(test)
option_manager_test_new_options_end_to_end :: proc(t: ^testing.T) {
	m := Option_Manager{}
	reg := Options_Registry{}
	option_manager_test_setup(&m, &reg)
	defer option_manager_registry_destroy(&reg)
	defer option_manager_destroy(&m)

	opt, derr := option_manager_registry_declare(&reg, "writemethod", "", File_Write_Method.Overwrite)
	testing.expect_value(t, derr, Option_Manager_Error.None)
	testing.expect_value(t, option_manager_option_type_name(opt), "enum(overwrite|replace)")
	serr, _ := option_manager_option_set_from_strings(opt, {"replace"})
	testing.expect_value(t, serr, Option_Manager_Error.None)
	testing.expect_value(t, opt.value.(File_Write_Method), File_Write_Method.Replace)
	// Wrong-variant stores are rejected (C++ dynamic_cast failure).
	serr, _ = option_manager_option_set(opt, 1, false)
	testing.expect_value(t, serr, Option_Manager_Error.Type_Mismatch)
	testing.expect_value(t, opt.value.(File_Write_Method), File_Write_Method.Replace)
	// Non-scalar values render "..." in desc strings.
	d := option_manager_option_get_desc_string(opt)
	defer delete(d)
	testing.expect_value(t, d, "...")
	testing.expect_value(t, option_manager_option_update(opt, nil), Option_Manager_Error.No_Update)

	fopt, fderr := option_manager_registry_declare(&reg, "autoinfo", "", Auto_Info{.Command})
	testing.expect_value(t, fderr, Option_Manager_Error.None)
	serr, _ = option_manager_option_add_from_strings(fopt, {"normal"})
	testing.expect_value(t, serr, Option_Manager_Error.None)
	testing.expect_value(t, fopt.value.(Auto_Info), Auto_Info{.Command, .Normal})
	g := option_manager_option_get_as_string(fopt, .Raw)
	defer delete(g)
	testing.expect_value(t, g, "command|normal")
}
