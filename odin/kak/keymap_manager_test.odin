// Tests for the keymap_manager module. The C++ has no UnitTest for
// KeymapManager, so these cover the documented behavior of every proc
// plus edge cases.
package kak

import "core:testing"

@(test)
keymap_manager_test_map_and_get :: proc(t: ^testing.T) {
	m := keymap_manager_init()
	defer keymap_manager_destroy(&m)

	testing.expect(t, keymap_manager_get_mapping(&m, {key = 'a'}, .Normal) == nil)

	target := []Keys_Key{{key = 'b'}, {key = 'c'}}
	keymap_manager_map_key(&m, {key = 'a'}, .Normal, target, "go bc")
	info := keymap_manager_get_mapping(&m, {key = 'a'}, .Normal)
	testing.expect(t, info != nil)
	if info == nil {
		return
	}
	testing.expect_value(t, len(info.keys), 2)
	testing.expect_value(t, info.keys[0], Keys_Key{key = 'b'})
	testing.expect_value(t, info.keys[1], Keys_Key{key = 'c'})
	testing.expect_value(t, info.docstring, "go bc")
	testing.expect_value(t, info.atomic, false)

	// A different mode is a different entry.
	testing.expect(t, keymap_manager_get_mapping(&m, {key = 'a'}, .Insert) == nil)
	keymap_manager_map_key(&m, {key = 'a'}, .Insert, target, "insert bc", true)
	insert := keymap_manager_get_mapping(&m, {key = 'a'}, .Insert)
	testing.expect(t, insert != nil)
	if insert != nil {
		testing.expect_value(t, insert.atomic, true)
		testing.expect_value(t, insert.docstring, "insert bc")
	}
	// The Normal entry is unchanged.
	normal := keymap_manager_get_mapping(&m, {key = 'a'}, .Normal)
	testing.expect(t, normal != nil)
	if normal != nil {
		testing.expect_value(t, normal.atomic, false)
	}
}

@(test)
keymap_manager_test_map_replaces :: proc(t: ^testing.T) {
	m := keymap_manager_init()
	defer keymap_manager_destroy(&m)

	keymap_manager_map_key(&m, {key = 'a'}, .Normal, []Keys_Key{{key = 'x'}}, "first")
	keymap_manager_map_key(&m, {key = 'a'}, .Normal, []Keys_Key{{key = 'y'}}, "second", true)
	info := keymap_manager_get_mapping(&m, {key = 'a'}, .Normal)
	testing.expect(t, info != nil)
	if info == nil {
		return
	}
	testing.expect_value(t, len(info.keys), 1)
	testing.expect_value(t, info.keys[0], Keys_Key{key = 'y'})
	testing.expect_value(t, info.docstring, "second")
	testing.expect_value(t, info.atomic, true)
}

@(test)
keymap_manager_test_unmap :: proc(t: ^testing.T) {
	m := keymap_manager_init()
	defer keymap_manager_destroy(&m)

	keymap_manager_map_key(&m, {key = 'a'}, .Normal, []Keys_Key{{key = 'b'}}, "doc")
	keymap_manager_map_key(&m, {key = 'a'}, .Insert, []Keys_Key{{key = 'b'}}, "doc")
	// Unmapping an absent entry is a no-op.
	keymap_manager_unmap_key(&m, {key = 'z'}, .Normal)

	keymap_manager_unmap_key(&m, {key = 'a'}, .Normal)
	testing.expect(t, keymap_manager_get_mapping(&m, {key = 'a'}, .Normal) == nil)
	testing.expect(t, keymap_manager_get_mapping(&m, {key = 'a'}, .Insert) != nil)
}

@(test)
keymap_manager_test_unmap_keys :: proc(t: ^testing.T) {
	m := keymap_manager_init()
	defer keymap_manager_destroy(&m)

	keymap_manager_map_key(&m, {key = 'a'}, .Normal, []Keys_Key{{key = 'b'}}, "")
	keymap_manager_map_key(&m, {key = 'c'}, .Normal, []Keys_Key{{key = 'd'}}, "")
	keymap_manager_map_key(&m, {key = 'a'}, .Insert, []Keys_Key{{key = 'b'}}, "")

	keymap_manager_unmap_keys(&m, .Normal)
	testing.expect(t, keymap_manager_get_mapping(&m, {key = 'a'}, .Normal) == nil)
	testing.expect(t, keymap_manager_get_mapping(&m, {key = 'c'}, .Normal) == nil)
	testing.expect(t, keymap_manager_get_mapping(&m, {key = 'a'}, .Insert) != nil)

	// Unmapping an empty mode is a no-op.
	keymap_manager_unmap_keys(&m, .Normal)
	keymap_manager_unmap_keys(&m, .Menu)
	testing.expect(t, keymap_manager_get_mapping(&m, {key = 'a'}, .Insert) != nil)
}

@(test)
keymap_manager_test_parent_fallback :: proc(t: ^testing.T) {
	root := keymap_manager_init()
	defer keymap_manager_destroy(&root)
	child := keymap_manager_init_child(&root)
	defer keymap_manager_destroy(&child)

	keymap_manager_map_key(&root, {key = 'a'}, .Normal, []Keys_Key{{key = 'r'}}, "root")

	// The child sees the parent mapping.
	info := keymap_manager_get_mapping(&child, {key = 'a'}, .Normal)
	testing.expect(t, info != nil)
	if info != nil {
		testing.expect_value(t, info.docstring, "root")
	}

	// A child entry shadows the parent one.
	keymap_manager_map_key(&child, {key = 'a'}, .Normal, []Keys_Key{{key = 'c'}}, "child")
	shadowed := keymap_manager_get_mapping(&child, {key = 'a'}, .Normal)
	testing.expect(t, shadowed != nil)
	if shadowed != nil {
		testing.expect_value(t, shadowed.docstring, "child")
	}
	// The parent entry is unchanged.
	parent_info := keymap_manager_get_mapping(&root, {key = 'a'}, .Normal)
	testing.expect(t, parent_info != nil)
	if parent_info != nil {
		testing.expect_value(t, parent_info.docstring, "root")
	}

	// Unmapping in the child reveals the parent entry again.
	keymap_manager_unmap_key(&child, {key = 'a'}, .Normal)
	revealed := keymap_manager_get_mapping(&child, {key = 'a'}, .Normal)
	testing.expect(t, revealed != nil)
	if revealed != nil {
		testing.expect_value(t, revealed.docstring, "root")
	}

	// A miss everywhere returns nil.
	testing.expect(t, keymap_manager_get_mapping(&child, {key = 'z'}, .Normal) == nil)
}

@(test)
keymap_manager_test_reparent :: proc(t: ^testing.T) {
	root := keymap_manager_init()
	defer keymap_manager_destroy(&root)
	other := keymap_manager_init()
	defer keymap_manager_destroy(&other)
	child := keymap_manager_init_child(&root)
	defer keymap_manager_destroy(&child)

	keymap_manager_map_key(&root, {key = 'a'}, .Normal, []Keys_Key{{key = 'r'}}, "root")
	keymap_manager_map_key(&other, {key = 'b'}, .Normal, []Keys_Key{{key = 'o'}}, "other")

	testing.expect(t, keymap_manager_get_mapping(&child, {key = 'a'}, .Normal) != nil)
	testing.expect(t, keymap_manager_get_mapping(&child, {key = 'b'}, .Normal) == nil)
	keymap_manager_reparent(&child, &other)
	testing.expect(t, keymap_manager_get_mapping(&child, {key = 'a'}, .Normal) == nil)
	testing.expect(t, keymap_manager_get_mapping(&child, {key = 'b'}, .Normal) != nil)
}

@(test)
keymap_manager_test_mapped_keys :: proc(t: ^testing.T) {
	root := keymap_manager_init()
	defer keymap_manager_destroy(&root)
	child := keymap_manager_init_child(&root)
	defer keymap_manager_destroy(&child)

	// Empty managers yield no keys.
	empty := keymap_manager_get_mapped_keys(&child, .Normal)
	defer delete(empty)
	testing.expect_value(t, len(empty), 0)

	keymap_manager_map_key(&root, {key = 'a'}, .Normal, []Keys_Key{{key = 'x'}}, "")
	keymap_manager_map_key(&root, {key = 'b'}, .Normal, []Keys_Key{{key = 'x'}}, "")
	keymap_manager_map_key(&root, {key = 'i'}, .Insert, []Keys_Key{{key = 'x'}}, "")
	// Shadows the parent 'a' entry: must appear only once.
	keymap_manager_map_key(&child, {key = 'a'}, .Normal, []Keys_Key{{key = 'y'}}, "")
	keymap_manager_map_key(&child, {key = 'c'}, .Normal, []Keys_Key{{key = 'y'}}, "")

	keys := keymap_manager_get_mapped_keys(&child, .Normal)
	defer delete(keys)
	testing.expect_value(t, len(keys), 3)
	testing.expect(t, ranges_contains(keys[:], Keys_Key{key = 'a'}))
	testing.expect(t, ranges_contains(keys[:], Keys_Key{key = 'b'}))
	testing.expect(t, ranges_contains(keys[:], Keys_Key{key = 'c'}))

	insert_keys := keymap_manager_get_mapped_keys(&child, .Insert)
	defer delete(insert_keys)
	testing.expect_value(t, len(insert_keys), 1)
}

@(test)
keymap_manager_test_user_modes :: proc(t: ^testing.T) {
	m := keymap_manager_init()
	defer keymap_manager_destroy(&m)

	testing.expect_value(t, keymap_manager_add_user_mode(&m, "mymode"), Keymap_Manager_Error.None)
	modes := keymap_manager_user_modes(&m)
	testing.expect_value(t, len(modes), 1)
	testing.expect_value(t, modes[0], "mymode")

	// Names with digits, underscores, and dashes are valid identifiers.
	testing.expect_value(
		t,
		keymap_manager_add_user_mode(&m, "mode-2_x"),
		Keymap_Manager_Error.None,
	)
	testing.expect_value(t, len(keymap_manager_user_modes(&m)), 2)
}

@(test)
keymap_manager_test_user_mode_errors :: proc(t: ^testing.T) {
	m := keymap_manager_init()
	defer keymap_manager_destroy(&m)

	for regular in keymap_manager_REGULAR_MODES {
		testing.expect_value(
			t,
			keymap_manager_add_user_mode(&m, regular),
			Keymap_Manager_Error.Regular_Mode,
		)
	}
	testing.expect_value(t, len(keymap_manager_user_modes(&m)), 0)

	testing.expect_value(t, keymap_manager_add_user_mode(&m, "mymode"), Keymap_Manager_Error.None)
	testing.expect_value(
		t,
		keymap_manager_add_user_mode(&m, "mymode"),
		Keymap_Manager_Error.Already_Defined,
	)
	testing.expect_value(
		t,
		keymap_manager_add_user_mode(&m, "bad mode"),
		Keymap_Manager_Error.Invalid_Name,
	)
	testing.expect_value(
		t,
		keymap_manager_add_user_mode(&m, "bad.mode"),
		Keymap_Manager_Error.Invalid_Name,
	)
	// Failed additions store nothing.
	testing.expect_value(t, len(keymap_manager_user_modes(&m)), 1)
}

@(test)
keymap_manager_test_user_modes_shared_at_root :: proc(t: ^testing.T) {
	root := keymap_manager_init()
	defer keymap_manager_destroy(&root)
	child := keymap_manager_init_child(&root)
	defer keymap_manager_destroy(&child)

	// Added through the child, stored at the root.
	testing.expect_value(t, keymap_manager_add_user_mode(&child, "shared"), Keymap_Manager_Error.None)
	testing.expect_value(t, len(root.user_modes), 1)
	testing.expect_value(t, len(child.user_modes), 0)
	testing.expect(t, keymap_manager_user_modes(&child) == &root.user_modes)

	// The root rejects the duplicate.
	testing.expect_value(
		t,
		keymap_manager_add_user_mode(&root, "shared"),
		Keymap_Manager_Error.Already_Defined,
	)
}

@(test)
keymap_manager_test_empty_name_parity :: proc(t: ^testing.T) {
	// The C++ all_of check is vacuously true for "", so an empty name
	// is accepted. Preserve that behavior.
	m := keymap_manager_init()
	defer keymap_manager_destroy(&m)

	testing.expect_value(t, keymap_manager_add_user_mode(&m, ""), Keymap_Manager_Error.None)
	testing.expect_value(t, len(keymap_manager_user_modes(&m)), 1)
}
