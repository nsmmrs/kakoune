// Tests for coord.odin (port of src/coord.hh + src/units.hh).
//
// No C++ UnitTest covers these headers, so these tests are written
// from the header semantics: unit arithmetic, coord arithmetic,
// lexicographic ordering, and hash folds.
package kak

import "core:testing"

// distinct-int units support the full StronglyTypedNumber operator set
@(test)
test_coord_unit_arithmetic :: proc(t: ^testing.T) {
	a := Coord_Line(7)
	b := Coord_Line(3)
	testing.expect_value(t, a + b, Coord_Line(10))
	testing.expect_value(t, a - b, Coord_Line(4))
	testing.expect_value(t, a * b, Coord_Line(21))
	testing.expect_value(t, a / b, Coord_Line(2))
	testing.expect_value(t, a % b, Coord_Line(1))
	testing.expect_value(t, -a, Coord_Line(-7))

	c := Coord_Byte(1)
	c += Coord_Byte(2)
	testing.expect_value(t, c, Coord_Byte(3))
	c -= Coord_Byte(1)
	testing.expect_value(t, c, Coord_Byte(2))
	c *= Coord_Byte(5)
	testing.expect_value(t, c, Coord_Byte(10))
	c /= Coord_Byte(3)
	testing.expect_value(t, c, Coord_Byte(3))
	c %= Coord_Byte(2)
	testing.expect_value(t, c, Coord_Byte(1))

	// default construction is zero, like C++ `= 0` member init
	zero: Coord_Column
	testing.expect_value(t, zero, Coord_Column(0))
	testing.expect_value(t, int(Coord_Char(42)), 42)
}

// units compare and convert like their C++ counterparts
@(test)
test_coord_unit_compare :: proc(t: ^testing.T) {
	testing.expect(t, Coord_Line(1) < Coord_Line(2))
	testing.expect(t, Coord_Line(2) > Coord_Line(1))
	testing.expect(t, Coord_Line(2) <= Coord_Line(2))
	testing.expect(t, Coord_Line(2) >= Coord_Line(2))
	testing.expect(t, Coord_Byte(3) == Coord_Byte(3))
	testing.expect(t, Coord_Byte(3) != Coord_Byte(4))
	testing.expect(t, Coord_Column(-1) < Coord_Column(0))
}

// coord_abs matches C++ abs() on units
@(test)
test_coord_abs :: proc(t: ^testing.T) {
	testing.expect_value(t, coord_abs(Coord_Line(-5)), Coord_Line(5))
	testing.expect_value(t, coord_abs(Coord_Line(5)), Coord_Line(5))
	testing.expect_value(t, coord_abs(Coord_Line(0)), Coord_Line(0))
	testing.expect_value(t, coord_abs(Coord_Byte(-1)), Coord_Byte(1))
	testing.expect_value(t, coord_abs(Coord_Column(-100)), Coord_Column(100))
}

// BufferCoord +/- are component-wise
@(test)
test_coord_buffer_add_sub :: proc(t: ^testing.T) {
	a := Coord_Buffer{Coord_Line(3), Coord_Byte(10)}
	b := Coord_Buffer{Coord_Line(2), Coord_Byte(5)}
	testing.expect_value(t, coord_add(a, b), Coord_Buffer{Coord_Line(5), Coord_Byte(15)})
	testing.expect_value(t, coord_sub(a, b), Coord_Buffer{Coord_Line(1), Coord_Byte(5)})
	// identity: (a + b) - b == a
	testing.expect_value(t, coord_sub(coord_add(a, b), b), a)
	// zero coord is the additive identity
	zero: Coord_Buffer
	testing.expect_value(t, coord_add(a, zero), a)
	// negative results are representable
	testing.expect_value(t, coord_sub(b, a), Coord_Buffer{Coord_Line(-1), Coord_Byte(-5)})
}

// DisplayCoord +/- are component-wise over column counts
@(test)
test_coord_display_add_sub :: proc(t: ^testing.T) {
	a := Coord_Display{Coord_Line(1), Coord_Column(4)}
	b := Coord_Display{Coord_Line(1), Coord_Column(6)}
	testing.expect_value(t, coord_add(a, b), Coord_Display{Coord_Line(2), Coord_Column(10)})
	testing.expect_value(t, coord_sub(b, a), Coord_Display{Coord_Line(0), Coord_Column(2)})
}

// ordering is lexicographic: line first, then column (C++ <=>)
@(test)
test_coord_compare :: proc(t: ^testing.T) {
	a := Coord_Buffer{Coord_Line(2), Coord_Byte(0)}
	b := Coord_Buffer{Coord_Line(2), Coord_Byte(9)}
	c := Coord_Buffer{Coord_Line(3), Coord_Byte(0)}
	testing.expect_value(t, coord_compare(a, a), 0)
	testing.expect_value(t, coord_compare(a, b), -1)
	testing.expect_value(t, coord_compare(b, a), 1)
	// line dominates column
	testing.expect_value(t, coord_compare(b, c), -1)
	testing.expect_value(t, coord_compare(c, b), 1)

	d := Coord_Display{Coord_Line(0), Coord_Column(7)}
	e := Coord_Display{Coord_Line(0), Coord_Column(8)}
	testing.expect_value(t, coord_compare(d, e), -1)
	testing.expect_value(t, coord_compare(e, d), 1)
	testing.expect_value(t, coord_compare(d, d), 0)
}

// ==/!= on coord structs compare all fields
@(test)
test_coord_equality :: proc(t: ^testing.T) {
	testing.expect(t, Coord_Buffer{1, 2} == Coord_Buffer{1, 2})
	testing.expect(t, Coord_Buffer{1, 2} != Coord_Buffer{1, 3})
	testing.expect(t, Coord_Buffer{1, 2} != Coord_Buffer{2, 2})
	testing.expect(t, Coord_Display{0, 0} == Coord_Display{0, 0})
}

// hash folds match C++ hash_values order: combine(hash(column), hash(line))
@(test)
test_coord_hash :: proc(t: ^testing.T) {
	c := Coord_Buffer{Coord_Line(1), Coord_Byte(2)}
	testing.expect_value(
		t,
		coord_hash_buffer(c),
		hash_combine(hash_value(2), hash_value(1)),
	)
	// golden: combine(2, 1) = 0x9e377a38
	testing.expect_value(t, coord_hash_buffer(c), uint(0x9e377a38))
	// line/column order matters
	swapped := Coord_Buffer{Coord_Line(2), Coord_Byte(1)}
	testing.expect(t, coord_hash_buffer(c) != coord_hash_buffer(swapped))

	d := Coord_Display{Coord_Line(1), Coord_Column(2)}
	testing.expect_value(t, coord_hash_display(d), uint(0x9e377a38))

	// the proc group dispatches to the same functions
	testing.expect_value(t, coord_hash(c), coord_hash_buffer(c))
	testing.expect_value(t, coord_hash(d), coord_hash_display(d))
}

// BufferCoordAndTarget: promoted fields, -1 defaults, target-only hash
@(test)
test_coord_target :: proc(t: ^testing.T) {
	c := Coord_Buffer{Coord_Line(4), Coord_Byte(8)}
	tc := coord_buffer_and_target(c)
	// C++ constructor defaults are target = display_target = -1
	testing.expect_value(t, tc.target, Coord_Column(-1))
	testing.expect_value(t, tc.display_target, Coord_Column(-1))
	// line/column promote through the embedded coord (C++ inheritance)
	testing.expect_value(t, tc.line, Coord_Line(4))
	testing.expect_value(t, tc.column, Coord_Byte(8))

	explicit := coord_buffer_and_target(c, Coord_Column(3), Coord_Column(9))
	testing.expect_value(t, explicit.target, Coord_Column(3))
	testing.expect_value(t, explicit.display_target, Coord_Column(9))

	// hash covers line, column, target but NOT display_target
	testing.expect_value(
		t,
		coord_hash_target(explicit),
		hash_combine(
			hash_combine(hash_value(3), hash_value(8)),
			hash_value(4),
		),
	)
	other_display := coord_buffer_and_target(c, Coord_Column(3), Coord_Column(10))
	testing.expect_value(t, coord_hash_target(other_display), coord_hash_target(explicit))
	other_target := coord_buffer_and_target(c, Coord_Column(4), Coord_Column(9))
	testing.expect(t, coord_hash_target(other_target) != coord_hash_target(explicit))
	testing.expect_value(t, coord_hash(explicit), coord_hash_target(explicit))
}
