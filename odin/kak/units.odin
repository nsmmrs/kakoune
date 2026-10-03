// Port of Kakoune's src/units.hh (StronglyTypedNumber + four counts).
//
// Mapping notes:
//   * The four C++ counts are aliases of the merged coord unit types
//     (see coord.odin), which already port units.hh as `distinct int`:
//     full arithmetic (+,-,*,/,%, unary -, compound assignment),
//     comparisons, and zero initialization come free, and aliasing keeps
//     one unit type system so Units_* values interoperate with every
//     coord/range/option_types proc directly. No helpers are vendored:
//     magnitude, hashing, and folds reuse coord_abs and the hash module.
//   * The `_line`/`_byte`/`_char`/`_col` literal suffixes have no Odin
//     equivalent; construct explicitly, e.g. Units_ByteCount(3).
//   * C++ pre/post ++/-- have no expression form in Odin; use += 1/-= 1
//     (both the untyped-constant and the explicit-unit form work).
//   * C++ `operator size_t()` (asserting non-negativity) is units_as_size;
//     C++ `abs()` (returning size_t) is units_abs; `operator!` and
//     `operator bool` are the zero test in units_is_zero.
//   * C++ `Byte* + ByteCount` pointer arithmetic is units_advance over
//     []byte/string views (no pointer arithmetic in Odin).
//   * Nothing here allocates, so no proc takes an allocator; views
//     returned by units_advance borrow their input (nothing to free).
package kak

import "base:intrinsics"

// Units_LineCount is a line count (port of C++ LineCount).
Units_LineCount :: Coord_Line

// Units_ByteCount is a byte count (port of C++ ByteCount).
Units_ByteCount :: Coord_Byte

// Units_CharCount is a character count (port of C++ CharCount).
Units_CharCount :: Coord_Char

// Units_ColumnCount is a display-column count (port of C++ ColumnCount).
Units_ColumnCount :: Coord_Column

// units_abs is the magnitude of a unit as uint (port of C++ abs(),
// which returns size_t). Reuses coord_abs for the signed magnitude.
units_abs :: proc(v: $T) -> uint where intrinsics.type_is_integer(T) {
	return uint(coord_abs(v))
}

// units_as_size converts a unit to uint (port of the explicit C++
// operator size_t(), which asserts the value is non-negative).
units_as_size :: proc(v: $T) -> uint where intrinsics.type_is_integer(T) {
	assert(int(v) >= 0, "units count must be non-negative for size conversion")
	return uint(int(v))
}

// units_is_zero reports whether a unit is zero (port of C++ operator!
// and the explicit operator bool zero test).
units_is_zero :: proc(v: $T) -> bool where intrinsics.type_is_integer(T) {
	return v == 0
}

// units_hash hashes a unit (port of the C++ friend hash_value, which
// hashes the underlying int). Reuses hash_value from the hash module.
units_hash :: proc(v: $T) -> uint where intrinsics.type_is_integer(T) {
	return hash_value(int(v))
}

// units_advance_bytes skips n bytes of a byte slice (port of C++
// operator+(Byte*, ByteCount)). The result borrows s; nothing to free.
units_advance_bytes :: proc(s: []byte, n: Units_ByteCount) -> []byte {
	return s[int(n):]
}

// units_advance_string skips n bytes of a string (same C++ operator,
// string form). The result borrows s; nothing to free.
units_advance_string :: proc(s: string, n: Units_ByteCount) -> string {
	return s[int(n):]
}

// units_advance skips a byte count over []byte or string views.
units_advance :: proc {
	units_advance_bytes,
	units_advance_string,
}
