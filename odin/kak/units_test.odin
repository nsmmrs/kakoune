// Tests for units.odin (port of src/units.hh).
//
// No C++ UnitTest covers this header, so these tests are written from
// the header semantics: StronglyTypedNumber arithmetic, comparisons,
// conversions, abs/hash, Byte* + ByteCount, and the literal suffixes'
// explicit-construction replacement.
package kak

import "core:testing"

// Units_* are aliases of the merged coord unit types: one type system,
// so they interoperate with coord procs directly.
@(test)
test_units_alias_identity :: proc(t: ^testing.T) {
	testing.expect_value(t, Units_LineCount(3), Coord_Line(3))
	testing.expect_value(t, Units_ByteCount(3), Coord_Byte(3))
	testing.expect_value(t, Units_CharCount(3), Coord_Char(3))
	testing.expect_value(t, Units_ColumnCount(3), Coord_Column(3))
	// an alias value feeds coord procs without conversion
	testing.expect_value(t, coord_abs(Units_LineCount(-4)), Coord_Line(4))
	testing.expect_value(
		t,
		coord_add(
			Coord_Buffer{Units_LineCount(1), Units_ByteCount(2)},
			Coord_Buffer{Units_LineCount(3), Units_ByteCount(4)},
		),
		Coord_Buffer{Coord_Line(4), Coord_Byte(6)},
	)
}

// binary operators +,-,*,/,% and unary - match StronglyTypedNumber
@(test)
test_units_arithmetic :: proc(t: ^testing.T) {
	a := Units_LineCount(7)
	b := Units_LineCount(3)
	testing.expect_value(t, a + b, Units_LineCount(10))
	testing.expect_value(t, a - b, Units_LineCount(4))
	testing.expect_value(t, a * b, Units_LineCount(21))
	testing.expect_value(t, a / b, Units_LineCount(2))
	testing.expect_value(t, a % b, Units_LineCount(1))
	testing.expect_value(t, -a, Units_LineCount(-7))

	testing.expect_value(
		t,
		Units_ByteCount(20) / Units_ByteCount(6),
		Units_ByteCount(3),
	)
	testing.expect_value(
		t,
		Units_CharCount(20) % Units_CharCount(6),
		Units_CharCount(2),
	)
	testing.expect_value(
		t,
		-Units_ColumnCount(9),
		Units_ColumnCount(-9),
	)
}

// compound assignment matches +=,-=,*=,/=,%=; += 1/-= 1 replace ++/--
@(test)
test_units_compound_assign :: proc(t: ^testing.T) {
	c := Units_ByteCount(1)
	c += Units_ByteCount(2)
	testing.expect_value(t, c, Units_ByteCount(3))
	c -= Units_ByteCount(1)
	testing.expect_value(t, c, Units_ByteCount(2))
	c *= Units_ByteCount(5)
	testing.expect_value(t, c, Units_ByteCount(10))
	c /= Units_ByteCount(3)
	testing.expect_value(t, c, Units_ByteCount(3))
	c %= Units_ByteCount(2)
	testing.expect_value(t, c, Units_ByteCount(1))

	// ++/-- replacement: untyped-constant and explicit-unit forms agree
	d := Units_CharCount(10)
	d += 1
	testing.expect_value(t, d, Units_CharCount(11))
	d -= 1
	testing.expect_value(t, d, Units_CharCount(10))
	d += Units_CharCount(1)
	testing.expect_value(t, d, Units_CharCount(11))
	d -= Units_CharCount(1)
	testing.expect_value(t, d, Units_CharCount(10))
}

// ==/!= and ordering match the defaulted C++ == and <=>
@(test)
test_units_compare :: proc(t: ^testing.T) {
	testing.expect(t, Units_LineCount(1) < Units_LineCount(2))
	testing.expect(t, Units_LineCount(2) > Units_LineCount(1))
	testing.expect(t, Units_LineCount(2) <= Units_LineCount(2))
	testing.expect(t, Units_LineCount(2) >= Units_LineCount(2))
	testing.expect(t, Units_ByteCount(3) == Units_ByteCount(3))
	testing.expect(t, Units_ByteCount(3) != Units_ByteCount(4))
	testing.expect(t, Units_ColumnCount(-1) < Units_ColumnCount(0))
	testing.expect(t, Units_CharCount(0) >= Units_CharCount(-5))
}

// default construction is zero; units_is_zero matches operator!/bool
@(test)
test_units_zero :: proc(t: ^testing.T) {
	zero_line: Units_LineCount
	testing.expect_value(t, zero_line, Units_LineCount(0))
	zero_byte: Units_ByteCount
	testing.expect_value(t, zero_byte, Units_ByteCount(0))
	zero_char: Units_CharCount
	testing.expect_value(t, zero_char, Units_CharCount(0))
	zero_col: Units_ColumnCount
	testing.expect_value(t, zero_col, Units_ColumnCount(0))

	testing.expect(t, units_is_zero(Units_LineCount(0)))
	testing.expect(t, !units_is_zero(Units_LineCount(1)))
	testing.expect(t, !units_is_zero(Units_ByteCount(-1)))
	testing.expect(t, units_is_zero(Units_CharCount(0)))
	testing.expect(t, !units_is_zero(Units_ColumnCount(7)))
	// direct spelling agrees with the proc
	testing.expect(t, Units_ByteCount(0) == 0)
	testing.expect(t, Units_ByteCount(2) != 0)
}

// explicit int() conversion and explicit construction (the _line/_byte/
// _char/_col suffix replacement) round-trip
@(test)
test_units_convert :: proc(t: ^testing.T) {
	testing.expect_value(t, int(Units_LineCount(42)), 42)
	testing.expect_value(t, int(Units_ByteCount(-3)), -3)
	testing.expect_value(t, int(Units_CharCount(0)), 0)
	testing.expect_value(t, int(Units_ColumnCount(1000)), 1000)
	// construct-from-int round-trips
	testing.expect_value(t, Units_LineCount(int(Units_LineCount(-9))), Units_LineCount(-9))
}

// units_abs matches C++ abs(): magnitude as an unsigned value
@(test)
test_units_abs :: proc(t: ^testing.T) {
	testing.expect_value(t, units_abs(Units_LineCount(-5)), uint(5))
	testing.expect_value(t, units_abs(Units_LineCount(5)), uint(5))
	testing.expect_value(t, units_abs(Units_LineCount(0)), uint(0))
	testing.expect_value(t, units_abs(Units_ByteCount(-1)), uint(1))
	testing.expect_value(t, units_abs(Units_CharCount(-100)), uint(100))
	testing.expect_value(t, units_abs(Units_ColumnCount(7)), uint(7))
}

// units_as_size matches operator size_t(): value as uint for >= 0
@(test)
test_units_as_size :: proc(t: ^testing.T) {
	testing.expect_value(t, units_as_size(Units_ByteCount(7)), uint(7))
	testing.expect_value(t, units_as_size(Units_LineCount(0)), uint(0))
	testing.expect_value(t, units_as_size(Units_CharCount(123)), uint(123))
	testing.expect_value(t, units_as_size(Units_ColumnCount(1)), uint(1))
}

// units_hash matches C++ hash_value(unit): hash of the underlying int
@(test)
test_units_hash :: proc(t: ^testing.T) {
	testing.expect_value(t, units_hash(Units_LineCount(1)), hash_value(1))
	testing.expect_value(t, units_hash(Units_ByteCount(2)), hash_value(2))
	testing.expect_value(t, units_hash(Units_CharCount(0)), hash_value(0))
	testing.expect_value(t, units_hash(Units_ColumnCount(-1)), hash_value(-1))
	testing.expect_value(t, units_hash(Units_LineCount(9)), uint(9))
}

// units_advance matches Byte* + ByteCount over []byte and string views
@(test)
test_units_advance :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		units_advance("hello", Units_ByteCount(2)),
		"llo",
	)
	testing.expect_value(t, units_advance("hello", Units_ByteCount(0)), "hello")
	testing.expect_value(t, units_advance("hello", Units_ByteCount(5)), "")
	got := units_advance([]byte{10, 20, 30, 40}, Units_ByteCount(1))
	want := []byte{20, 30, 40}
	testing.expect_value(t, len(got), len(want))
	for i in 0 ..< len(want) {
		testing.expect_value(t, got[i], want[i])
	}
	testing.expect_value(
		t,
		units_advance_string("abc", Units_ByteCount(3)),
		"",
	)
}
