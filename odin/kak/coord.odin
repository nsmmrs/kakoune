// Port of Kakoune's src/coord.hh and src/units.hh.
//
// Mapping notes:
//   * StronglyTypedNumber becomes a `distinct int` (Coord_Line,
//     Coord_Byte, Coord_Char, Coord_Column). Arithmetic, compound
//     assignment, comparison, and zero initialization come free with
//     the distinct type; the `_line`/`_byte`/`_char`/`_col` literal
//     suffixes have no Odin equivalent, construct explicitly instead.
//   * The LineAndColumn template becomes generic procs (coord_add,
//     coord_sub, coord_compare) over any struct with .line/.column.
//     Odin structs already support == and !=, so only ordering needs
//     a proc (C++ defaulted <=> is lexicographic line, then column).
//   * DisplayCoord's option_type_name ("coord") and its "line,column"
//     string form belong to the option system (see the option_types
//     module), not to this header.
//   * Hashing reuses the hash module; argument order matches the C++
//     variadic hash_values exactly (see coord_hash_buffer).
package kak

import "base:intrinsics"

// Coord_Line is a 0-based line number (port of C++ LineCount).
Coord_Line :: distinct int

// Coord_Byte is a 0-based byte offset within a line (port of C++ ByteCount).
Coord_Byte :: distinct int

// Coord_Char is a 0-based character offset within a line (port of C++ CharCount).
Coord_Char :: distinct int

// Coord_Column is a 0-based display-column offset (port of C++ ColumnCount).
Coord_Column :: distinct int

// Coord_Buffer is a (line, byte-column) position in a buffer.
Coord_Buffer :: struct {
	line:   Coord_Line,
	column: Coord_Byte,
}

// Coord_Display is a (line, display-column) position on screen.
Coord_Display :: struct {
	line:   Coord_Line,
	column: Coord_Column,
}

// Coord_Buffer_And_Target is a buffer position plus the desired columns
// used when moving across lines of different lengths. Use
// coord_buffer_and_target to get the C++ constructor defaults (-1).
Coord_Buffer_And_Target :: struct {
	using coord:   Coord_Buffer,
	target:        Coord_Column,
	display_target: Coord_Column,
}

// coord_buffer_and_target builds a Coord_Buffer_And_Target with the C++
// constructor defaults: both targets -1 (no goal column).
coord_buffer_and_target :: proc(
	c: Coord_Buffer,
	target: Coord_Column = -1,
	display_target: Coord_Column = -1,
) -> Coord_Buffer_And_Target {
	return {c, target, display_target}
}

// coord_abs is the absolute value of a unit (port of C++ abs()).
coord_abs :: proc(v: $T) -> T where intrinsics.type_is_integer(T) {
	if v < 0 {
		return -v
	}
	return v
}

// coord_add adds two coordinates component-wise (port of operator+).
coord_add :: proc(a, b: $T) -> T {
	return {a.line + b.line, a.column + b.column}
}

// coord_sub subtracts two coordinates component-wise (port of operator-).
coord_sub :: proc(a, b: $T) -> T {
	return {a.line - b.line, a.column - b.column}
}

// coord_compare orders coordinates lexicographically (line, then column),
// returning -1, 0, or 1 (port of the defaulted C++ <=>).
coord_compare :: proc(a, b: $T) -> int {
	if a.line < b.line {
		return -1
	}
	if a.line > b.line {
		return 1
	}
	if a.column < b.column {
		return -1
	}
	if a.column > b.column {
		return 1
	}
	return 0
}

// coord_hash_buffer hashes a buffer position: the C++
// hash_values(line, column) folds to combine(hash(column), hash(line)).
coord_hash_buffer :: proc(c: Coord_Buffer) -> uint {
	return hash_values(hash_value(int(c.line)), hash_value(int(c.column)))
}

// coord_hash_display hashes a display position, same fold as coord_hash_buffer.
coord_hash_display :: proc(c: Coord_Display) -> uint {
	return hash_values(hash_value(int(c.line)), hash_value(int(c.column)))
}

// coord_hash_target hashes a buffer position with target: the C++
// hash_values(line, column, target) folds to
// combine(combine(hash(target), hash(column)), hash(line)).
// display_target is deliberately excluded, as in C++.
coord_hash_target :: proc(c: Coord_Buffer_And_Target) -> uint {
	return hash_values(
		hash_value(int(c.line)),
		hash_value(int(c.column)),
		hash_value(int(c.target)),
	)
}

// coord_hash hashes any coord struct (port of the C++ hash_value overloads).
coord_hash :: proc {
	coord_hash_buffer,
	coord_hash_display,
	coord_hash_target,
}
