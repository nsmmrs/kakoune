package kak

import "core:mem"
import "core:testing"

@(test)
test_scope_make_root :: proc(t: ^testing.T) {
	s := scope_make()
	defer scope_destroy(&s)

	testing.expect(t, scope_options(&s).parent == nil)
	testing.expect(t, scope_hooks(&s).parent == nil)
	testing.expect(t, scope_keymaps(&s).parent == nil)
	testing.expect(t, scope_aliases(&s).parent == nil)
	testing.expect(t, scope_faces(&s).parent == nil)
	testing.expect(t, scope_highlighters(&s).parent == nil)
	testing.expect(t, len(scope_faces(&s).faces) > 0)
	testing.expect(
		t,
		scope_highlighters(&s).group.base.passes == Highlight_Pass{.Replace, .Wrap, .Move, .Colorize},
	)
	testing.expect_value(t, len(scope_highlighters(&s).group.highlighters), 0)
}

@(test)
test_scope_child_and_reparent :: proc(t: ^testing.T) {
	root := scope_make()
	defer scope_destroy(&root)
	root2 := scope_make()
	defer scope_destroy(&root2)
	child := scope_make_child(&root)
	defer scope_destroy(&child)

	testing.expect(t, scope_options(&child).parent == scope_options(&root))
	testing.expect(t, scope_hooks(&child).parent == scope_hooks(&root))
	testing.expect(t, scope_keymaps(&child).parent == scope_keymaps(&root))
	testing.expect(t, scope_aliases(&child).parent == scope_aliases(&root))
	testing.expect(t, scope_faces(&child).parent == scope_faces(&root))
	testing.expect(t, scope_highlighters(&child).parent == scope_highlighters(&root))

	reg: Options_Registry
	option_manager_registry_init(&reg, scope_options(&root))
	defer option_manager_registry_destroy(&reg)
	opt, err := option_manager_registry_declare(&reg, "g", "", 8)
	testing.expect_value(t, err, Option_Manager_Error.None)
	inherited, gerr := option_manager_get_option(scope_options(&child), "g")
	testing.expect_value(t, gerr, Option_Manager_Error.None)
	testing.expect(t, inherited == opt)

	scope_reparent(&child, &root2)
	testing.expect(t, scope_options(&child).parent == scope_options(&root2))
	testing.expect(t, scope_hooks(&child).parent == scope_hooks(&root2))
	testing.expect(t, scope_keymaps(&child).parent == scope_keymaps(&root2))
	testing.expect(t, scope_aliases(&child).parent == scope_aliases(&root2))
	testing.expect(t, scope_faces(&child).parent == scope_faces(&root2))
	testing.expect(t, scope_highlighters(&child).parent == scope_highlighters(&root2))
	_, gerr2 := option_manager_get_option(scope_options(&child), "g")
	testing.expect_value(t, gerr2, Option_Manager_Error.Not_Found)
}

@(test)
test_scope_global :: proc(t: ^testing.T) {
	g := scope_global_make()
	defer scope_global_destroy(g)

	testing.expect(t, g.global_data.parent == &g.scope)
	reg := scope_global_option_registry(g)
	opt, err := option_manager_registry_declare(reg, "tabstop", "size of a tab character", 8)
	testing.expect_value(t, err, Option_Manager_Error.None)
	testing.expect_value(t, option_manager_option_docstring(opt), "[int] - size of a tab character")
	got, gerr := option_manager_get_option(scope_options(&g.scope), "tabstop")
	testing.expect_value(t, gerr, Option_Manager_Error.None)
	testing.expect(t, got == opt)
	// NOTE: changing a global option with notify would run the
	// GlobalSetOption hook (STUBBED run_hook); covered at integration.
}

@(test)
test_scope_global_singleton :: proc(t: ^testing.T) {
	g := scope_global_init()
	testing.expect(t, g != nil)
	testing.expect(t, scope_global_instance() == g)
	testing.expect(t, scope_global_init() == g)
	scope_global_deinit()
	scope_global_deinit()
}

@(test)
test_scope_local :: proc(t: ^testing.T) {
	root := scope_make()
	defer scope_destroy(&root)
	reg: Options_Registry
	option_manager_registry_init(&reg, scope_options(&root))
	defer option_manager_registry_destroy(&reg)
	_, err := option_manager_registry_declare(&reg, "opt", "", 1)
	testing.expect_value(t, err, Option_Manager_Error.None)

	ctx := Context{}
	defer delete(ctx.local_scopes)

	l1 := scope_local_make(&ctx, &root)
	l2 := scope_local_make(&ctx, &root)
	testing.expect_value(t, len(ctx.local_scopes), 2)
	testing.expect(t, ctx.local_scopes[0] == &l1.scope)
	testing.expect(t, ctx.local_scopes[1] == &l2.scope)
	testing.expect(t, l2.ctx == &ctx)
	testing.expect(t, scope_options(&l2.scope).parent == scope_options(&root))

	local, lerr := option_manager_get_local_option(scope_options(&l1.scope), "opt")
	testing.expect_value(t, lerr, Option_Manager_Error.None)
	serr, _ := option_manager_option_set(local, 2)
	testing.expect_value(t, serr, Option_Manager_Error.None)
	lv, lok := option_manager_option_get(local).(int)
	testing.expect(t, lok)
	testing.expect_value(t, lv, 2)
	roots, _ := option_manager_get_option(scope_options(&root), "opt")
	rv, rok := option_manager_option_get(roots).(int)
	testing.expect(t, rok)
	testing.expect_value(t, rv, 1)

	scope_local_destroy(l2)
	testing.expect_value(t, len(ctx.local_scopes), 1)
	scope_local_destroy(l1)
	testing.expect_value(t, len(ctx.local_scopes), 0)
}

// Minimal child highlighter vtable for the root-group test: destroy
// is a no-op since the child owns nothing.
scope_test_dummy_destroy :: proc(data: rawptr, allocator: mem.Allocator) {
	_ = data
	_ = allocator
}

scope_test_dummy_vtable := Highlighter_VTable{
	destroy = scope_test_dummy_destroy,
}

// Scope root groups are functional highlighter groups (regression:
// they carried a nil vtable, so add-highlighter always failed with
// "highlighter groups are unavailable").
@(test)
test_scope_highlighters_root_group_wired :: proc(t: ^testing.T) {
	s := scope_make()
	defer scope_destroy(&s)

	root := &s.data.highlighters.group
	testing.expect(t, root.base.vtable == &highlighters_group_vtable)
	testing.expect(t, root.base.data == root)

	// Exercise add-highlighter's path through the vtable.
	child := new(Highlighter)
	child.vtable = &scope_test_dummy_vtable
	root.base.vtable.add_child(root.base.data, "kid", child, false)
	found := root.base.vtable.get_child(root.base.data, "kid", context.allocator)
	testing.expect(t, found == child)
}
