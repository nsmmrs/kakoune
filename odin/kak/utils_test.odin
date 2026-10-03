// Tests for the utils port. src/utils.hh has no C++ UnitTest, so these
// are edge-case tests written against the documented C++ semantics.
package kak

import "core:testing"

// basic set/unset/is_set cycle
@(test)
utils_test_nested_bool_basic :: proc(t: ^testing.T) {
	nb := Utils_Nested_Bool{}
	testing.expect(t, !utils_nested_bool_is_set(nb))
	utils_nested_bool_set(&nb)
	testing.expect(t, utils_nested_bool_is_set(nb))
	utils_nested_bool_unset(&nb)
	testing.expect(t, !utils_nested_bool_is_set(nb))
}

// nesting: two sets need two unsets
@(test)
utils_test_nested_bool_nested :: proc(t: ^testing.T) {
	nb := Utils_Nested_Bool{}
	utils_nested_bool_set(&nb)
	utils_nested_bool_set(&nb)
	utils_nested_bool_unset(&nb)
	testing.expect(t, utils_nested_bool_is_set(nb))
	utils_nested_bool_unset(&nb)
	testing.expect(t, !utils_nested_bool_is_set(nb))
}

// scoped guard sets on make and clears on release
@(test)
utils_test_scoped_bool :: proc(t: ^testing.T) {
	nb := Utils_Nested_Bool{}
	guard := utils_scoped_bool_make(&nb)
	testing.expect(t, utils_nested_bool_is_set(nb))
	utils_scoped_bool_release(&guard)
	testing.expect(t, !utils_nested_bool_is_set(nb))
	// releasing twice is a no-op, like a moved-from C++ guard
	utils_scoped_bool_release(&guard)
	testing.expect(t, !utils_nested_bool_is_set(nb))
}

// condition=false guards touch nothing
@(test)
utils_test_scoped_bool_condition_false :: proc(t: ^testing.T) {
	nb := Utils_Nested_Bool{}
	guard := utils_scoped_bool_make(&nb, false)
	testing.expect(t, !utils_nested_bool_is_set(nb))
	utils_scoped_bool_release(&guard)
	testing.expect(t, !utils_nested_bool_is_set(nb))
}

// the defer pattern restores the bool at scope end
@(test)
utils_test_scoped_bool_defer :: proc(t: ^testing.T) {
	nb := Utils_Nested_Bool{}
	{
		guard := utils_scoped_bool_make(&nb)
		defer utils_scoped_bool_release(&guard)
		testing.expect(t, utils_nested_bool_is_set(nb))
	}
	testing.expect(t, !utils_nested_bool_is_set(nb))
}

// clamp pins below/within/above, ints and floats
@(test)
utils_test_clamp :: proc(t: ^testing.T) {
	testing.expect_value(t, utils_clamp(5, 0, 10), 5)
	testing.expect_value(t, utils_clamp(-3, 0, 10), 0)
	testing.expect_value(t, utils_clamp(42, 0, 10), 10)
	testing.expect_value(t, utils_clamp(0, 0, 10), 0)
	testing.expect_value(t, utils_clamp(10, 0, 10), 10)
	testing.expect_value(t, utils_clamp(1.5, 0.0, 1.0), 1.0)
	testing.expect_value(t, utils_clamp(-1.5, 0.0, 1.0), 0.0)
	testing.expect_value(t, utils_clamp(7, 7, 7), 7)
}

@(private = "file")
utils_test_is_space :: proc(v: byte) -> bool {
	return v == ' '
}

// skip_while stops at the first non-matching element
@(test)
utils_test_skip_while :: proc(t: ^testing.T) {
	s := [?]byte{' ', ' ', 'a', ' '}
	pos := 0
	testing.expect(t, utils_skip_while(s[:], &pos, utils_test_is_space))
	testing.expect_value(t, pos, 2)
	// no leading match: stops immediately, still true
	pos = 2
	testing.expect(t, utils_skip_while(s[:], &pos, utils_test_is_space))
	testing.expect_value(t, pos, 2)
	// all remaining match: runs to the end, false
	pos = 3
	testing.expect(t, !utils_skip_while(s[:], &pos, utils_test_is_space))
	testing.expect_value(t, pos, 4)
}

// skip_while on empty input and from the end
@(test)
utils_test_skip_while_edges :: proc(t: ^testing.T) {
	empty := [?]byte{}
	pos := 0
	testing.expect(t, !utils_skip_while(empty[:], &pos, utils_test_is_space))
	testing.expect_value(t, pos, 0)
	s := [?]byte{'a'}
	pos = 1
	testing.expect(t, !utils_skip_while(s[:], &pos, utils_test_is_space))
	testing.expect_value(t, pos, 1)
}

// skip_while_reverse stops at the last non-matching element
@(test)
utils_test_skip_while_reverse :: proc(t: ^testing.T) {
	s := [?]byte{' ', 'a', ' ', ' '}
	pos := 3
	testing.expect(t, !utils_skip_while_reverse(s[:], &pos, utils_test_is_space))
	testing.expect_value(t, pos, 1)
	// element 2 matches so it steps to 1, then reports 'a' as false
	pos = 2
	testing.expect(t, !utils_skip_while_reverse(s[:], &pos, utils_test_is_space))
	testing.expect_value(t, pos, 1)
	// at index 0 the loop cannot step, so it reports s[0] itself
	pos = 0
	testing.expect(t, utils_skip_while_reverse(s[:], &pos, utils_test_is_space))
	testing.expect_value(t, pos, 0)
	// end element matches nothing: stays, reports false
	pos = 1
	testing.expect(t, !utils_skip_while_reverse(s[:], &pos, utils_test_is_space))
	testing.expect_value(t, pos, 1)
}

// skip_while_reverse edges: all match, none match, empty, clamped pos
@(test)
utils_test_skip_while_reverse_edges :: proc(t: ^testing.T) {
	all := [?]byte{' ', ' ', ' '}
	pos := 2
	testing.expect(t, utils_skip_while_reverse(all[:], &pos, utils_test_is_space))
	testing.expect_value(t, pos, 0)
	none := [?]byte{'a', 'b'}
	pos = 1
	testing.expect(t, !utils_skip_while_reverse(none[:], &pos, utils_test_is_space))
	testing.expect_value(t, pos, 1)
	empty := [?]byte{}
	pos = 5
	testing.expect(t, !utils_skip_while_reverse(empty[:], &pos, utils_test_is_space))
	testing.expect_value(t, pos, 0)
	// out-of-range pos clamps into the slice
	pos = 99
	testing.expect(t, !utils_skip_while_reverse(none[:], &pos, utils_test_is_space))
	testing.expect_value(t, pos, 1)
}
