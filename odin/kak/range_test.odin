// Tests for range.odin (port of src/range.hh).
//
// No C++ UnitTest covers this header; tests are written from the
// header semantics: empty() and the hash fold.
package kak

import "core:testing"

// empty() is begin == end for any element type
@(test)
test_range_empty :: proc(t: ^testing.T) {
	testing.expect(t, range_empty(Range(int){3, 3}))
	testing.expect(t, !range_empty(Range(int){3, 4}))
	testing.expect(t, range_empty(Range(string){"x", "x"}))
	testing.expect(t, !range_empty(Range(string){"x", "y"}))
	a := Coord_Buffer{Coord_Line(1), Coord_Byte(2)}
	b := Coord_Buffer{Coord_Line(1), Coord_Byte(5)}
	testing.expect(t, range_empty(Range(Coord_Buffer){a, a}))
	testing.expect(t, !range_empty(Range(Coord_Buffer){a, b}))
	// degenerate (inverted) ranges are not empty, as in C++
	testing.expect(t, !range_empty(Range(int){4, 3}))
}

// ranges compare by value with builtin ==
@(test)
test_range_equality :: proc(t: ^testing.T) {
	testing.expect(t, Range(int){1, 2} == Range(int){1, 2})
	testing.expect(t, Range(int){1, 2} != Range(int){1, 3})
	testing.expect(t, Range(int){1, 2} != Range(int){0, 2})
}

// hash fold matches C++ hash_values(begin, end)
@(test)
test_range_hash :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		range_hash(hash_value(10), hash_value(20)),
		hash_combine(hash_value(20), hash_value(10)),
	)
	// golden: combine(20, 10)
	testing.expect_value(t, range_hash(hash_value(10), hash_value(20)), uint(0x9e377edc))
	// endpoint order matters
	testing.expect(
		t,
		range_hash(hash_value(1), hash_value(2)) != range_hash(hash_value(2), hash_value(1)),
	)
	// same endpoints hash the same
	testing.expect_value(
		t,
		range_hash(hash_value(5), hash_value(5)),
		range_hash(hash_value(5), hash_value(5)),
	)
}
