// Tests for the remainder implementations (the 24 STUB-contract procs
// implemented in their owner modules). Each test exercises the C++-named
// proc, not the longer-named proc it delegates to.
package kak

import "core:slice"
import "core:strings"
import "core:testing"

// remainders_test_bracket wraps s in angle brackets (an owning
// Client_Postprocess for the command_expand test).
remainders_test_bracket :: proc(data: rawptr, s: string) -> string {
	_ = data
	return strings.concatenate({"<", s, ">"})
}

@(test)
test_remainders_command_parser :: proc(t: ^testing.T) {
	p := command_parser_make("echo \"a b\" 'c'")
	tok, ok := command_parser_read_token(&p, false)
	testing.expect(t, ok)
	testing.expect_value(t, tok.type, Token_Type.Raw)
	testing.expect_value(t, tok.content, "echo")
	delete(tok.content)

	tok, ok = command_parser_read_token(&p, false)
	testing.expect(t, ok)
	testing.expect_value(t, tok.type, Token_Type.Expand)
	testing.expect_value(t, tok.content, "a b")
	delete(tok.content)

	tok, ok = command_parser_read_token(&p, false)
	testing.expect(t, ok)
	testing.expect_value(t, tok.type, Token_Type.Raw_Quoted)
	testing.expect_value(t, tok.content, "c")
	delete(tok.content)

	_, ok = command_parser_read_token(&p, false)
	testing.expect(t, !ok)

	// Command separators lex as their own token.
	p2 := command_parser_make("a;b")
	t1, ok1 := command_parser_read_token(&p2, false)
	testing.expect(t, ok1 && t1.type == .Raw && t1.content == "a")
	delete(t1.content)
	t2, ok2 := command_parser_read_token(&p2, false)
	testing.expect(t, ok2 && t2.type == .Command_Separator)
	delete(t2.content)
	t3, ok3 := command_parser_read_token(&p2, false)
	testing.expect(t, ok3 && t3.type == .Raw && t3.content == "b")
	delete(t3.content)
}

@(test)
test_remainders_command_expand :: proc(t: ^testing.T) {
	ctx := context_make_empty()
	defer context_destroy(&ctx)
	shell_ctx := Shell_Context{}
	pp := Client_Postprocess{remainders_test_bracket, nil}

	plain := command_expand("abc", &ctx, &shell_ctx, pp)
	testing.expect_value(t, plain, "abc")
	delete(plain)

	escaped := command_expand("100%%", &ctx, &shell_ctx, pp)
	testing.expect_value(t, escaped, "100%")
	delete(escaped)

	// %arg needs only the shell context, so it exercises the
	// postprocess adapter without unmerged backends.
	shell_args := Shell_Context{params = []string{"hello"}}
	expanded := command_expand("say %arg{1}!", &ctx, &shell_args, pp)
	testing.expect_value(t, expanded, "say <hello>!")
	delete(expanded)
}

@(test)
test_remainders_scoped_edition :: proc(t: ^testing.T) {
	buf := context_test_make_buffer([]string{"hi\n"})
	defer context_test_destroy_buffer(buf, context.allocator)
	sel := context_test_make_selection({}, {})
	sels := context_test_make_selections(buf, 0, []Selection{sel})
	defer selection_list_destroy(&sels)
	handler := Input_Handler{}
	ctx := Context{}
	context_init(&ctx, &handler, sels, {}, "")
	defer context_destroy(&ctx)

	ed := scoped_edition_make(&ctx)
	testing.expect(t, ed.buffer == buf)
	testing.expect_value(t, ctx.edition_level, 1)
	scoped_edition_destroy(&ed)
	testing.expect_value(t, ctx.edition_level, 0)

	// Buffer-less contexts get an inert guard.
	empty := context_make_empty()
	defer context_destroy(&empty)
	noop := scoped_edition_make(&empty)
	testing.expect(t, noop.buffer == nil)
	scoped_edition_destroy(&noop)
	testing.expect_value(t, empty.edition_level, 0)
}

@(test)
test_remainders_scoped_selection_edition :: proc(t: ^testing.T) {
	buf := context_test_make_buffer([]string{"hi\n"})
	defer context_test_destroy_buffer(buf, context.allocator)
	sel := context_test_make_selection({}, {})
	sels := context_test_make_selections(buf, 0, []Selection{sel})
	defer selection_list_destroy(&sels)
	handler := Input_Handler{}
	ctx := Context{}
	context_init(&ctx, &handler, sels, {}, "")
	defer context_destroy(&ctx)

	ed := scoped_selection_edition_make(&ctx)
	testing.expect(t, ed.valid)
	scoped_selection_edition_destroy(&ed)
	testing.expect(t, !utils_nested_bool_is_set(ctx.selection_history.in_edition))

	// Buffer-less contexts get an inert guard.
	empty := context_make_empty()
	defer context_destroy(&empty)
	noop := scoped_selection_edition_make(&empty)
	testing.expect(t, !noop.valid)
	scoped_selection_edition_destroy(&noop)
}

@(test)
test_remainders_local_scope :: proc(t: ^testing.T) {
	g := scope_global_init()
	defer scope_global_deinit()
	ctx := context_make_empty()
	defer context_destroy(&ctx)

	ls := local_scope_make(&ctx)
	testing.expect_value(t, len(ctx.local_scopes), 1)
	testing.expect(t, context_scope(&ctx).data == ls.scope.data)
	testing.expect(t, ls.scope.data.options.parent == &g.scope.data.options)

	// Nested scopes chain onto the outer one and pop in LIFO order.
	inner := local_scope_make(&ctx)
	testing.expect_value(t, len(ctx.local_scopes), 2)
	testing.expect(t, context_scope(&ctx).data == inner.scope.data)
	testing.expect(t, inner.scope.data.options.parent == &ls.scope.data.options)
	local_scope_destroy(&inner)
	testing.expect(t, context_scope(&ctx).data == ls.scope.data)
	local_scope_destroy(&ls)
	testing.expect_value(t, len(ctx.local_scopes), 0)
}

@(test)
test_remainders_option_get_as_string :: proc(t: ^testing.T) {
	int_opt := Option{value = 42}
	s := option_get_as_string(&int_opt, .Raw)
	testing.expect_value(t, s, "42")
	delete(s)

	str_opt := Option{value = "hi"}
	q := option_get_as_string(&str_opt, .Raw)
	testing.expect_value(t, q, "hi")
	delete(q)
}

@(test)
test_remainders_option_get_as_strings :: proc(t: ^testing.T) {
	vec := make([dynamic]string, 2)
	defer delete(vec)
	vec[0] = "a"
	vec[1] = "b"
	opt := Option{value = vec}
	strs := option_get_as_strings(&opt)
	defer delete(strs)
	testing.expect_value(t, len(strs), 2)
	testing.expect_value(t, strs[0], "a")
	testing.expect_value(t, strs[1], "b")
	for s in strs {
		delete(s)
	}
}

@(test)
test_remainders_option_get_debug_flags :: proc(t: ^testing.T) {
	opt := Option{value = Option_types_Debug_Flags{.Hooks, .Commands}}
	testing.expect_value(t, option_get_debug_flags(&opt), Option_types_Debug_Flags{.Hooks, .Commands})
}

@(test)
test_remainders_options_registry_complete :: proc(t: ^testing.T) {
	mk := proc(name: string, hidden: bool) -> ^Option_Desc {
		d := new(Option_Desc)
		d.name = name
		if hidden {
			d.flags = {.Hidden}
		}
		return d
	}
	descs := make([dynamic]^Option_Desc)
	defer delete(descs)
	append(&descs, mk("tabstop", false), mk("tab_hidden", true), mk("scrolloff", false))
	defer for d in descs {
		free(d)
	}
	reg := Options_Registry{descs = descs}

	cands := options_registry_complete_option_name(&reg, "tab", 3)
	defer option_manager_candidates_free(&cands)
	testing.expect_value(t, len(cands), 1)
	testing.expect_value(t, cands[0], "tabstop")
}

// One test for both register_singleton procs: the singleton is process
// state, so two tests would race on init/destroy.
@(test)
test_remainders_register_singleton :: proc(t: ^testing.T) {
	testing.expect(t, !register_manager_has_instance)
	register_manager_instance_init()
	defer register_manager_destroy(&Register_Manager_Instance)
	defer register_manager_has_instance = false
	ctx := context_make_empty()
	defer context_destroy(&ctx)

	m := register_manager_instance()
	reg := register_manager_make_static("a")
	register_manager_add(m, 'a', reg)
	utils_nested_bool_set(register_manager_modified_hook_disabled(reg))
	register_manager_set(reg, &ctx, []string{"one", "two"})

	vals := register_manager_get_strings("a", &ctx)
	// get_strings returns owned clones (save semantics): free both.
	defer {
		for v in vals {
			delete(v)
		}
		delete(vals)
	}
	testing.expect_value(t, len(vals), 2)
	testing.expect_value(t, vals[0], "one")
	testing.expect_value(t, vals[1], "two")

	cands := register_manager_complete_register_name("dq", 2)
	defer delete(cands)
	testing.expect_value(t, len(cands), 1)
	testing.expect_value(t, cands[0], "dquote")
}

@(test)
test_remainders_buffer_offset_char :: proc(t: ^testing.T) {
	b := buffer_test_make([]string{"ab\n", "cd\n"})
	defer buffer_destroy(b)
	testing.expect_value(t, buffer_offset_coord_char(b, {0, 0}, 1, 8), Coord_Buffer{0, 1})
	testing.expect_value(t, buffer_offset_coord_char(b, {0, 1}, -1, 8), Coord_Buffer{0, 0})
	// Clamped at both ends.
	testing.expect_value(t, buffer_offset_coord_char(b, {0, 0}, -5, 8), Coord_Buffer{0, 0})
	testing.expect_value(
		t,
		buffer_offset_coord_char(b, {0, 0}, 100, 8),
		buffer_back_coord(b),
	)
}

@(test)
test_remainders_buffer_iterator_value :: proc(t: ^testing.T) {
	b := buffer_test_make([]string{"ab\n", "cd\n"})
	defer buffer_destroy(b)
	testing.expect_value(t, buffer_iterator_value(buffer_begin(b)), 'a')
	it := buffer_iterator_at(b, {0, 2})
	testing.expect_value(t, buffer_iterator_value(it), '\n')
	it2 := buffer_iterator_at(b, {1, 1})
	testing.expect_value(t, buffer_iterator_value(it2), 'd')
}

@(test)
test_remainders_completion_complete_strings :: proc(t: ^testing.T) {
	cands := []string{"foobar", "foo", "bar"}
	res := completion_complete_strings("foo", 3, cands)
	defer delete(res)
	testing.expect_value(t, len(res), 2)
	testing.expect_value(t, res[0], "foo")
	testing.expect_value(t, res[1], "foobar")
}

@(test)
test_remainders_context_make_empty :: proc(t: ^testing.T) {
	ctx := context_make_empty()
	defer context_destroy(&ctx)
	testing.expect_value(t, ctx.edition_level, 0)
	testing.expect(t, !context_has_buffer(&ctx))
	testing.expect(t, !context_has_window(&ctx))
	testing.expect(t, !context_has_client(&ctx))
	testing.expect(t, ctx.selection_history.ctx == nil)
}

@(test)
test_remainders_global_scope_option_registry :: proc(t: ^testing.T) {
	g := scope_global_init()
	defer scope_global_deinit()
	testing.expect(t, global_scope_option_registry() == &g.global_data.option_registry)
}

@(test)
test_remainders_alias_flatten_names :: proc(t: ^testing.T) {
	root := alias_registry_make_root()
	defer alias_registry_destroy(&root)
	alias_registry_add(&root, "a", "alpha")
	child := alias_registry_make_child(&root)
	defer alias_registry_destroy(&child)
	alias_registry_add(&child, "a", "overridden")
	alias_registry_add(&child, "b", "beta")

	names := alias_registry_flatten_alias_names(&child)
	defer delete(names)
	testing.expect_value(t, len(names), 2)
	testing.expect(t, slice.contains(names[:], "a"))
	testing.expect(t, slice.contains(names[:], "b"))
}

@(test)
test_remainders_selection_list_make_multi :: proc(t: ^testing.T) {
	b := buffer_test_make([]string{"ab\n", "cd\n"})
	defer buffer_destroy(b)
	sels := make([dynamic]Selection, 0, 2)
	append(
		&sels,
		Selection{basic = Basic_Selection{anchor = {0, 0}, cursor = coord_buffer_and_target({0, 1})}},
		Selection{basic = Basic_Selection{anchor = {1, 0}, cursor = coord_buffer_and_target({1, 1})}},
	)
	// make_multi takes ownership of sels: no delete(sels) here.
	list := selection_list_make_multi(b, sels)
	defer selection_list_destroy(&list)
	testing.expect_value(t, len(list.selections), 2)
	testing.expect_value(t, list.main, 1)
	testing.expect_value(t, list.timestamp, buffer_timestamp(b))
	testing.expect(t, list.buffer == b)
}

@(test)
test_remainders_buffer_manager_get_buffer_ifp :: proc(t: ^testing.T) {
	testing.expect(t, !buffer_manager_has_instance)
	buffer_manager_instance_init()
	defer buffer_manager_destroy(&Buffer_Manager_Instance)
	defer buffer_manager_has_instance = false

	m := buffer_manager_instance()
	buf, err := buffer_manager_create(m, "rmd-scratch", {.Debug}, nil, .None, .Lf, .Present, File_Fs_Status{})
	testing.expect_value(t, err, Buffer_Manager_Error.None)
	testing.expect(t, buffer_manager_get_buffer_ifp("rmd-scratch") == buf)
	testing.expect(t, buffer_manager_get_buffer_ifp("rmd-missing") == nil)
}
