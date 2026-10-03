package kak

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"

// register_manager_test_disable_hooks turns the modified hook off so the
// context is never touched (nil is passed for it).
register_manager_test_disable_hooks :: proc(reg: ^Register) {
	utils_nested_bool_set(register_manager_modified_hook_disabled(reg))
}

// register_manager_test_getter_calls counts dynamic getter invocations.
register_manager_test_getter_calls := 0

register_manager_test_getter :: proc(ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	register_manager_test_getter_calls += 1
	res := make([dynamic]string, allocator)
	append(&res, strings.clone("g1", allocator), strings.clone("g2", allocator))
	return res
}

// Separate counter/getter for the readonly test: tests run threaded and
// must not share mutable package state.
register_manager_test_readonly_getter_calls := 0

register_manager_test_readonly_getter :: proc(
	ctx: ^Context,
	allocator: mem.Allocator,
) -> [dynamic]string {
	register_manager_test_readonly_getter_calls += 1
	res := make([dynamic]string, allocator)
	append(&res, strings.clone("g1", allocator), strings.clone("g2", allocator))
	return res
}

// register_manager_test_setter_seen records the last dynamic assignment.
register_manager_test_setter_seen: [dynamic]string

register_manager_test_setter :: proc(ctx: ^Context, values: []string) {
	clear(&register_manager_test_setter_seen)
	append(&register_manager_test_setter_seen, ..values)
}

@(test)
register_manager_test_static_set_get :: proc(t: ^testing.T) {
	reg := register_manager_make_static("a")
	defer register_manager_destroy_register(reg)
	register_manager_test_disable_hooks(reg)

	register_manager_set(reg, nil, {"x", "y"})
	got := register_manager_get_values(reg, nil)
	testing.expect_value(t, len(got), 2)
	testing.expect_value(t, got[0], "x")
	testing.expect_value(t, got[1], "y")

	// Assignment replaces the whole content.
	register_manager_set(reg, nil, {"z"})
	got = register_manager_get_values(reg, nil)
	testing.expect_value(t, len(got), 1)
	testing.expect_value(t, got[0], "z")
}

@(test)
register_manager_test_set_owns_values :: proc(t: ^testing.T) {
	// Regression: set must clone its values (command params are freed
	// after each command; borrowing them corrupted the heap and
	// crashed %reg expansion with "free(): invalid pointer").
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	alloc := mem.tracking_allocator(&track)
	defer mem.tracking_allocator_destroy(&track)
	reg := register_manager_make_static("a", alloc)
	register_manager_test_disable_hooks(reg)
	tmp := strings.clone("volatile", context.temp_allocator)
	register_manager_set(reg, nil, {tmp})
	delete(tmp, context.temp_allocator)
	got := register_manager_get_values(reg, nil)
	testing.expect_value(t, len(got), 1)
	testing.expect_value(t, got[0], "volatile")
	testing.expect(t, raw_data(got[0]) != raw_data(tmp), "register content must be a clone, not a borrow")
	// Replacement frees the old clone; destroy frees the rest.
	register_manager_set(reg, nil, {"still", "here"})
	register_manager_destroy_register(reg, alloc)
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
register_manager_test_static_empty :: proc(t: ^testing.T) {
	reg := register_manager_make_static("a")
	defer register_manager_destroy_register(reg)
	register_manager_test_disable_hooks(reg)

	got := register_manager_get_values(reg, nil)
	testing.expect_value(t, len(got), 1)
	testing.expect_value(t, got[0], "")
	testing.expect_value(t, register_manager_get_main(reg, nil, 0), "")
	testing.expect_value(t, register_manager_get_main(reg, nil, 9), "")
}

@(test)
register_manager_test_static_get_main :: proc(t: ^testing.T) {
	reg := register_manager_make_static("a")
	defer register_manager_destroy_register(reg)
	register_manager_test_disable_hooks(reg)

	register_manager_set(reg, nil, {"a", "b"})
	testing.expect_value(t, register_manager_get_main(reg, nil, 0), "a")
	testing.expect_value(t, register_manager_get_main(reg, nil, 1), "b")
	testing.expect_value(t, register_manager_get_main(reg, nil, 5), "b")
}

@(test)
register_manager_test_save_restore :: proc(t: ^testing.T) {
	reg := register_manager_make_static("a")
	defer register_manager_destroy_register(reg)
	register_manager_test_disable_hooks(reg)

	register_manager_set(reg, nil, {"p", "q"})
	saved := register_manager_save(reg, nil)
	defer {
		for s in saved {
			delete(s)
		}
		delete(saved)
	}
	testing.expect_value(t, len(saved), 2)

	// The save is a deep copy: later assignments do not affect it.
	register_manager_set(reg, nil, {"z"})
	testing.expect_value(t, len(saved), 2)
	testing.expect_value(t, saved[0], "p")
	testing.expect_value(t, saved[1], "q")

	register_manager_restore(reg, nil, saved[:])
	got := register_manager_get_values(reg, nil)
	testing.expect_value(t, len(got), 2)
	testing.expect_value(t, got[0], "p")
}

@(test)
register_manager_test_history_order :: proc(t: ^testing.T) {
	reg := register_manager_make_history("/")
	defer register_manager_destroy_register(reg)
	register_manager_test_disable_hooks(reg)

	register_manager_set(reg, nil, {"a"})
	register_manager_set(reg, nil, {"b"})
	got := register_manager_get_values(reg, nil)
	testing.expect_value(t, len(got), 2)
	testing.expect_value(t, got[0], "b")
	testing.expect_value(t, got[1], "a")
	testing.expect_value(t, register_manager_get_main(reg, nil, 0), "b")

	// Re-adding moves the entry to the front without duplicating.
	register_manager_set(reg, nil, {"a"})
	got = register_manager_get_values(reg, nil)
	testing.expect_value(t, len(got), 2)
	testing.expect_value(t, got[0], "a")
	testing.expect_value(t, got[1], "b")

	// Multi-value assignment keeps its order.
	register_manager_set(reg, nil, {"x", "y"})
	got = register_manager_get_values(reg, nil)
	testing.expect_value(t, got[0], "x")
	testing.expect_value(t, got[1], "y")

	testing.expect_value(t, register_manager_get_main(reg, nil, 7), "x")
}

@(test)
register_manager_test_history_restore_filters_empty :: proc(t: ^testing.T) {
	reg := register_manager_make_history("/")
	defer register_manager_destroy_register(reg)
	register_manager_test_disable_hooks(reg)

	register_manager_restore(reg, nil, {"", "b", "", "c"})
	got := register_manager_get_values(reg, nil)
	testing.expect_value(t, len(got), 2)
	testing.expect_value(t, got[0], "b")
	testing.expect_value(t, got[1], "c")
}

@(test)
register_manager_test_history_cap :: proc(t: ^testing.T) {
	reg := register_manager_make_history("/")
	defer register_manager_destroy_register(reg)
	register_manager_test_disable_hooks(reg)

	values := make([dynamic]string, 0, 1005, context.temp_allocator)
	for i := 0; i < 1005; i += 1 {
		append(&values, fmt.aprintf("e%d", i, allocator = context.temp_allocator))
	}
	register_manager_set(reg, nil, values[:])
	got := register_manager_get_values(reg, nil)
	testing.expect_value(t, len(got), 1000)
	testing.expect_value(t, got[0], "e0")
	testing.expect_value(t, got[999], "e999")
}

@(test)
register_manager_test_history_get_main_empty :: proc(t: ^testing.T) {
	reg := register_manager_make_history("/")
	defer register_manager_destroy_register(reg)
	register_manager_test_disable_hooks(reg)
	testing.expect_value(t, register_manager_get_main(reg, nil, 0), "")
}

@(test)
register_manager_test_null :: proc(t: ^testing.T) {
	reg := register_manager_make_null()
	defer register_manager_destroy_register(reg)

	register_manager_set(reg, nil, {"x"})
	got := register_manager_get_values(reg, nil)
	testing.expect_value(t, len(got), 1)
	testing.expect_value(t, got[0], "")
	testing.expect_value(t, register_manager_get_main(reg, nil, 3), "")
}

@(test)
register_manager_test_dynamic :: proc(t: ^testing.T) {
	register_manager_test_setter_seen = make([dynamic]string, context.allocator)
	defer delete(register_manager_test_setter_seen)
	register_manager_test_getter_calls = 0
	reg := register_manager_make_dynamic(
		"d",
		register_manager_test_getter,
		register_manager_test_setter,
	)
	defer register_manager_destroy_register(reg)
	register_manager_test_disable_hooks(reg)

	got := register_manager_get_values(reg, nil)
	testing.expect_value(t, register_manager_test_getter_calls, 1)
	testing.expect_value(t, len(got), 2)
	testing.expect_value(t, got[0], "g1")

	// get_main refreshes through the getter (C++ StaticRegister::get_main
	// calls the virtual get), so it observes current values.
	testing.expect_value(t, register_manager_get_main(reg, nil, 1), "g2")
	testing.expect_value(t, register_manager_test_getter_calls, 2)

	// A second read refreshes (and frees) the previous content.
	_ = register_manager_get_values(reg, nil)
	testing.expect_value(t, register_manager_test_getter_calls, 3)

	register_manager_set(reg, nil, {"s1", "s2", "s3"})
	testing.expect_value(t, len(register_manager_test_setter_seen), 3)
	testing.expect_value(t, register_manager_test_setter_seen[0], "s1")
	testing.expect_value(t, register_manager_test_setter_seen[2], "s3")
}

@(test)
register_manager_test_dynamic_readonly_get :: proc(t: ^testing.T) {
	register_manager_test_readonly_getter_calls = 0
	reg := register_manager_make_dynamic_readonly("%", register_manager_test_readonly_getter)
	defer register_manager_destroy_register(reg)
	register_manager_test_disable_hooks(reg)

	got := register_manager_get_values(reg, nil)
	testing.expect_value(t, register_manager_test_readonly_getter_calls, 1)
	testing.expect_value(t, len(got), 2)
	// The read-only setter panics; it is never called here (see summary).
}

@(test)
register_manager_test_hook_guard :: proc(t: ^testing.T) {
	reg := register_manager_make_static("a")
	defer register_manager_destroy_register(reg)
	guard := register_manager_modified_hook_disabled(reg)
	testing.expect(t, !utils_nested_bool_is_set(guard^))
	utils_nested_bool_set(guard)
	testing.expect(t, utils_nested_bool_is_set(guard^))
	utils_nested_bool_unset(guard)
	testing.expect(t, !utils_nested_bool_is_set(guard^))
}

@(test)
register_manager_test_add_get :: proc(t: ^testing.T) {
	m := register_manager_make()
	defer register_manager_destroy(&m)

	register_manager_add(&m, 'a', register_manager_make_static("a"))
	register_manager_add(&m, '/', register_manager_make_history("/"))

	// Lookup lowercases the codepoint.
	reg, err := register_manager_get(&m, 'A')
	testing.expect_value(t, err, Register_Manager_Error.None)
	testing.expect(t, reg != nil)
	reg2, err2 := register_manager_get(&m, '/')
	testing.expect_value(t, err2, Register_Manager_Error.None)
	testing.expect(t, reg2 != nil)
	testing.expect(t, reg != reg2)

	_, missing := register_manager_get(&m, 'z')
	testing.expect_value(t, missing, Register_Manager_Error.No_Such_Register)
}

@(test)
register_manager_test_get_by_name :: proc(t: ^testing.T) {
	m := register_manager_make()
	defer register_manager_destroy(&m)
	register_manager_add(&m, 'a', register_manager_make_static("a"))
	register_manager_add(&m, '/', register_manager_make_history("/"))

	reg, err := register_manager_get_by_name(&m, "a")
	testing.expect_value(t, err, Register_Manager_Error.None)
	testing.expect(t, reg != nil)

	reg, err = register_manager_get_by_name(&m, "A")
	testing.expect_value(t, err, Register_Manager_Error.None)
	testing.expect(t, reg != nil)

	reg, err = register_manager_get_by_name(&m, "slash")
	testing.expect_value(t, err, Register_Manager_Error.None)
	testing.expect(t, reg != nil)

	_, err = register_manager_get_by_name(&m, "nope")
	testing.expect_value(t, err, Register_Manager_Error.No_Such_Register)

	_, err = register_manager_get_by_name(&m, "")
	testing.expect_value(t, err, Register_Manager_Error.No_Such_Register)
}

// Separate counter/getter for the get-main-first test: tests run
// threaded and must not share mutable package state.
register_manager_test_first_getter_calls := 0

register_manager_test_first_getter :: proc(ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	register_manager_test_first_getter_calls += 1
	res := make([dynamic]string, allocator)
	append(&res, strings.clone("fresh", allocator))
	return res
}

@(test)
register_manager_test_dynamic_get_main_first :: proc(t: ^testing.T) {
	register_manager_test_first_getter_calls = 0
	reg := register_manager_make_dynamic(
		"f",
		register_manager_test_first_getter,
		register_manager_test_setter,
	)
	defer register_manager_destroy_register(reg)
	register_manager_test_disable_hooks(reg)

	// get_main with no prior get still observes fresh values: it
	// refreshes through the getter instead of reading cold cache.
	testing.expect_value(t, register_manager_get_main(reg, nil, 0), "fresh")
	testing.expect_value(t, register_manager_test_first_getter_calls, 1)
}

@(test)
register_manager_test_complete_name :: proc(t: ^testing.T) {
	m := register_manager_make()
	defer register_manager_destroy(&m)

	res := register_manager_complete_name(&m, "sl", -1)
	defer delete(res)
	testing.expect_value(t, len(res), 1)
	testing.expect_value(t, res[0], "slash")

	res2 := register_manager_complete_name(&m, "slashx", 5)
	defer delete(res2)
	testing.expect_value(t, len(res2), 1)
	testing.expect_value(t, res2[0], "slash")

	none := register_manager_complete_name(&m, "zzz", -1)
	defer delete(none)
	testing.expect_value(t, len(none), 0)
}
