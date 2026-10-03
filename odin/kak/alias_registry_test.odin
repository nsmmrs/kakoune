package kak

import "core:testing"

@(test)
test_alias_registry_add_get_remove :: proc(t: ^testing.T) {
	reg := alias_registry_make_root()
	defer alias_registry_destroy(&reg)

	testing.expect_value(t, alias_registry_add(&reg, "w", "write"), Alias_Registry_Error.None)
	testing.expect_value(t, alias_registry_get(&reg, "w"), "write")
	testing.expect_value(t, alias_registry_get(&reg, "missing"), "")

	testing.expect_value(t, alias_registry_add(&reg, "w", "write-all"), Alias_Registry_Error.None)
	testing.expect_value(t, alias_registry_get(&reg, "w"), "write-all")

	alias_registry_remove(&reg, "w")
	testing.expect_value(t, alias_registry_get(&reg, "w"), "")

	alias_registry_remove(&reg, "w")
	testing.expect_value(t, alias_registry_get(&reg, "w"), "")

	testing.expect_value(t, alias_registry_add(&reg, "", "x"), Alias_Registry_Error.Empty_Alias)
	testing.expect_value(t, alias_registry_error_message(.Empty_Alias), "alias must not be empty")
	testing.expect_value(t, alias_registry_error_message(.None), "")
}

@(test)
test_alias_registry_parent_chain :: proc(t: ^testing.T) {
	root := alias_registry_make_root()
	defer alias_registry_destroy(&root)
	child := alias_registry_make_child(&root)
	defer alias_registry_destroy(&child)

	alias_registry_add(&root, "q", "quit")
	alias_registry_add(&root, "a", "root-cmd")
	alias_registry_add(&child, "a", "child-cmd")

	testing.expect_value(t, alias_registry_get(&child, "q"), "quit")
	testing.expect_value(t, alias_registry_get(&child, "a"), "child-cmd")
	testing.expect_value(t, alias_registry_get(&root, "a"), "root-cmd")

	alias_registry_remove(&child, "a")
	testing.expect_value(t, alias_registry_get(&child, "a"), "root-cmd")

	other := alias_registry_make_root()
	defer alias_registry_destroy(&other)
	alias_registry_add(&other, "q", "other-quit")
	alias_registry_reparent(&child, &other)
	testing.expect_value(t, alias_registry_get(&child, "q"), "other-quit")
	testing.expect_value(t, alias_registry_get(&child, "a"), "")
}

@(test)
test_alias_registry_aliases_for :: proc(t: ^testing.T) {
	root := alias_registry_make_root()
	defer alias_registry_destroy(&root)
	child := alias_registry_make_child(&root)
	defer alias_registry_destroy(&child)

	alias_registry_add(&root, "w", "write")
	alias_registry_add(&root, "q", "quit")
	alias_registry_add(&child, "wa", "write")

	res := alias_registry_aliases_for(&child, "write")
	defer delete(res)
	testing.expect_value(t, len(res), 2)
	if len(res) == 2 {
		testing.expect_value(t, res[0], "w")
		testing.expect_value(t, res[1], "wa")
	}

	none := alias_registry_aliases_for(&child, "nope")
	defer delete(none)
	testing.expect_value(t, len(none), 0)
}

@(test)
test_alias_registry_flatten :: proc(t: ^testing.T) {
	gp := alias_registry_make_root()
	defer alias_registry_destroy(&gp)
	p := alias_registry_make_child(&gp)
	defer alias_registry_destroy(&p)
	l := alias_registry_make_child(&p)
	defer alias_registry_destroy(&l)

	alias_registry_add(&gp, "a", "gp-a")
	alias_registry_add(&gp, "b", "gp-b")
	alias_registry_add(&p, "b", "p-b")
	alias_registry_add(&p, "c", "p-c")
	alias_registry_add(&l, "c", "l-c")
	alias_registry_add(&l, "d", "l-d")

	flat := alias_registry_flatten(&l)
	defer delete(flat)
	testing.expect_value(t, len(flat), 4)
	got := make(map[string]string, context.temp_allocator)
	for e in flat {
		got[e.alias] = e.command
	}
	testing.expect_value(t, got["a"], "gp-a")
	testing.expect_value(t, got["b"], "p-b")
	testing.expect_value(t, got["c"], "l-c")
	testing.expect_value(t, got["d"], "l-d")
}
