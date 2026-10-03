// Tests for the display_buffer module (port of
// src/display_buffer.{hh,cc}). The C++ ships no unit tests here, so
// these cover atoms (content, length, trim, replace, equality),
// lines (split, insert, extract, erase, trim, optimize), buffers
// (range, optimize) and markup parsing (faces, escapes, builtins,
// errors).
package kak

import "core:testing"

// display_buffer_test_make_buffer builds a Buffer borrowing lines
// (only .lines is touched by this module).
display_buffer_test_make_buffer :: proc(lines: []string, allocator := context.allocator) -> Buffer {
	buf := Buffer{}
	buf.lines = make(Buffer_Lines, len(lines), allocator)
	copy(buf.lines[:], lines)
	return buf
}

display_buffer_test_destroy_buffer :: proc(buf: ^Buffer) {
	delete(buf.lines)
}

@(test)
test_display_buffer_atom_text :: proc(t: ^testing.T) {
	face := Face{fg = color_from_named(.Red)}
	atom := display_buffer_atom_text("héllo", face)
	testing.expect_value(t, display_buffer_atom_content(atom), "héllo")
	testing.expect_value(t, display_buffer_atom_length(atom), Coord_Column(5))
	testing.expect(t, !display_buffer_atom_empty(atom), "nonempty text")
	testing.expect(t, !display_buffer_atom_has_range(atom), "text has no range")
	testing.expect_value(t, atom.type, Display_Atom_Type.Text)
	testing.expect(t, atom.face == face, "face stored")
	testing.expect_value(t, display_buffer_atom_length(display_buffer_atom_text("", Face{})), Coord_Column(0))
	testing.expect(t, display_buffer_atom_empty(display_buffer_atom_text("", Face{})), "empty text")
}

@(test)
test_display_buffer_atom_wide_length :: proc(t: ^testing.T) {
	atom := display_buffer_atom_text("aあb", Face{})
	testing.expect_value(t, display_buffer_atom_length(atom), Coord_Column(4))
}

@(test)
test_display_buffer_atom_range_single_line :: proc(t: ^testing.T) {
	buf := display_buffer_test_make_buffer({"hello world", "second"})
	defer display_buffer_test_destroy_buffer(&buf)
	atom := display_buffer_atom_range(&buf, Buffer_Range{{0, 6}, {0, 11}}, Face{})
	testing.expect_value(t, display_buffer_atom_content(atom), "world")
	testing.expect_value(t, display_buffer_atom_length(atom), Coord_Column(5))
	testing.expect(t, display_buffer_atom_has_range(atom), "range atom has range")
	testing.expect(t, !display_buffer_atom_empty(atom), "nonempty range")
	empty := display_buffer_atom_range(&buf, Buffer_Range{{1, 2}, {1, 2}}, Face{})
	testing.expect(t, display_buffer_atom_empty(empty), "empty range")
	testing.expect_value(t, display_buffer_atom_content(empty), "")
}

@(test)
test_display_buffer_atom_range_two_lines :: proc(t: ^testing.T) {
	buf := display_buffer_test_make_buffer({"hello", "world"})
	defer display_buffer_test_destroy_buffer(&buf)
	atom := display_buffer_atom_range(&buf, Buffer_Range{{0, 3}, {1, 0}}, Face{})
	testing.expect_value(t, display_buffer_atom_content(atom), "lo")
	// The line break itself contributes no columns.
	testing.expect_value(t, display_buffer_atom_length(atom), Coord_Column(2))
	wide := display_buffer_atom_range(&buf, Buffer_Range{{0, 0}, {1, 5}}, Face{})
	testing.expect_value(t, display_buffer_atom_content(wide), "")
	testing.expect_value(t, display_buffer_atom_length(wide), Coord_Column(10))
}

@(test)
test_display_buffer_atom_replaced :: proc(t: ^testing.T) {
	buf := display_buffer_test_make_buffer({"hello"})
	defer display_buffer_test_destroy_buffer(&buf)
	atom := display_buffer_atom_replaced(&buf, Buffer_Range{{0, 0}, {0, 5}}, "XX", Face{})
	testing.expect_value(t, display_buffer_atom_content(atom), "XX")
	testing.expect_value(t, display_buffer_atom_length(atom), Coord_Column(2))
	testing.expect(t, display_buffer_atom_has_range(atom), "replaced keeps range")
}

@(test)
test_display_buffer_atom_replace :: proc(t: ^testing.T) {
	buf := display_buffer_test_make_buffer({"hello"})
	defer display_buffer_test_destroy_buffer(&buf)
	atom := display_buffer_atom_range(&buf, Buffer_Range{{0, 0}, {0, 5}}, Face{})
	display_buffer_atom_replace_text(&atom, "hi")
	testing.expect_value(t, atom.type, Display_Atom_Type.Replaced_Range)
	testing.expect_value(t, display_buffer_atom_content(atom), "hi")
	testing.expect_value(t, atom.range, Buffer_Range{{0, 0}, {0, 5}})
	text := display_buffer_atom_text("x", Face{})
	display_buffer_atom_replace_range(&text, Buffer_Range{{0, 1}, {0, 2}})
	testing.expect_value(t, text.type, Display_Atom_Type.Replaced_Range)
	testing.expect_value(t, display_buffer_atom_content(text), "x")
}

@(test)
test_display_buffer_atom_equal :: proc(t: ^testing.T) {
	buf := display_buffer_test_make_buffer({"aaa", "aaa"})
	defer display_buffer_test_destroy_buffer(&buf)
	a := display_buffer_atom_range(&buf, Buffer_Range{{0, 0}, {0, 3}}, Face{})
	b := display_buffer_atom_range(&buf, Buffer_Range{{1, 0}, {1, 3}}, Face{})
	testing.expect(t, display_buffer_atom_equal(a, b), "same content compares equal")
	testing.expect(t, !display_buffer_atom_equal(a, display_buffer_atom_text("aaa", Face{})), "type differs")
	red := Face{fg = color_from_named(.Red)}
	testing.expect(
		t,
		!display_buffer_atom_equal(a, display_buffer_atom_range(&buf, Buffer_Range{{0, 0}, {0, 3}}, red)),
		"face differs",
	)
}

@(test)
test_display_buffer_atom_trim_text :: proc(t: ^testing.T) {
	atom := display_buffer_atom_text("hello", Face{})
	testing.expect_value(t, display_buffer_atom_trim_begin(&atom, 2), Coord_Column(2))
	testing.expect_value(t, display_buffer_atom_content(atom), "llo")
	testing.expect_value(t, display_buffer_atom_trim_end(&atom, 2), Coord_Column(2))
	testing.expect_value(t, display_buffer_atom_content(atom), "ll")
	// Trimming past the end clamps.
	testing.expect_value(t, display_buffer_atom_trim_begin(&atom, 9), Coord_Column(2))
	testing.expect(t, display_buffer_atom_empty(atom), "trimmed to empty")
}

@(test)
test_display_buffer_atom_trim_wide_overshoot :: proc(t: ^testing.T) {
	atom := display_buffer_atom_text("aあb", Face{})
	// Trimming 2 columns consumes 'a' (1) plus 'あ' (2): overshoot.
	testing.expect_value(t, display_buffer_atom_trim_begin(&atom, 2), Coord_Column(3))
	testing.expect_value(t, display_buffer_atom_content(atom), "b")
	atom2 := display_buffer_atom_text("aあb", Face{})
	testing.expect_value(t, display_buffer_atom_trim_end(&atom2, 2), Coord_Column(3))
	testing.expect_value(t, display_buffer_atom_content(atom2), "aあ")
}

@(test)
test_display_buffer_atom_trim_range :: proc(t: ^testing.T) {
	buf := display_buffer_test_make_buffer({"hello world"})
	defer display_buffer_test_destroy_buffer(&buf)
	atom := display_buffer_atom_range(&buf, Buffer_Range{{0, 0}, {0, 11}}, Face{})
	testing.expect_value(t, display_buffer_atom_trim_begin(&atom, 6), Coord_Column(6))
	testing.expect_value(t, display_buffer_atom_content(atom), "world")
	testing.expect_value(t, display_buffer_atom_trim_end(&atom, 3), Coord_Column(3))
	testing.expect_value(t, display_buffer_atom_content(atom), "wor")
	testing.expect_value(t, atom.range, Buffer_Range{{0, 6}, {0, 9}})
}

@(test)
test_display_buffer_get_iterator :: proc(t: ^testing.T) {
	buf := display_buffer_test_make_buffer({"ab", "c"})
	defer display_buffer_test_destroy_buffer(&buf)
	it := display_buffer_get_iterator(&buf, Coord_Buffer{0, 2})
	testing.expect_value(t, it.coord, Coord_Buffer{1, 0})
	it2 := display_buffer_get_iterator(&buf, Coord_Buffer{0, 1})
	testing.expect_value(t, it2.coord, Coord_Buffer{0, 1})
	testing.expect_value(t, it2.line, "ab")
	testing.expect_value(t, it2.line_count, Units_LineCount(2))
	it3 := display_buffer_get_iterator(&buf, Coord_Buffer{1, 1})
	testing.expect_value(t, it3.coord, Coord_Buffer{2, 0})
}

@(test)
test_display_buffer_line_make :: proc(t: ^testing.T) {
	line := display_buffer_line_make()
	defer display_buffer_line_destroy(&line)
	testing.expect_value(t, len(line.atoms), 0)
	testing.expect(t, coord_compare(line.range.begin, line.range.end) > 0, "fresh range is inverted")
	testing.expect_value(t, display_buffer_line_length(line), Coord_Column(0))
	text_line := display_buffer_line_make_text("hi", Face{})
	defer display_buffer_line_destroy(&text_line)
	testing.expect_value(t, len(text_line.atoms), 1)
	testing.expect_value(t, display_buffer_line_length(text_line), Coord_Column(2))
}

@(test)
test_display_buffer_line_push_back_range :: proc(t: ^testing.T) {
	buf := display_buffer_test_make_buffer({"hello world"})
	defer display_buffer_test_destroy_buffer(&buf)
	line := display_buffer_line_make()
	defer display_buffer_line_destroy(&line)
	display_buffer_line_push_back(&line, display_buffer_atom_text("x", Face{}))
	testing.expect(t, coord_compare(line.range.begin, line.range.end) > 0, "text-only keeps inverted range")
	display_buffer_line_push_back(&line, display_buffer_atom_range(&buf, Buffer_Range{{0, 6}, {0, 11}}, Face{}))
	display_buffer_line_push_back(&line, display_buffer_atom_range(&buf, Buffer_Range{{0, 0}, {0, 5}}, Face{}))
	testing.expect_value(t, line.range, Buffer_Range{{0, 0}, {0, 11}})
}

@(test)
test_display_buffer_line_insert :: proc(t: ^testing.T) {
	buf := display_buffer_test_make_buffer({"abcdef"})
	defer display_buffer_test_destroy_buffer(&buf)
	line := display_buffer_line_make()
	defer display_buffer_line_destroy(&line)
	display_buffer_line_push_back(&line, display_buffer_atom_range(&buf, Buffer_Range{{0, 0}, {0, 2}}, Face{}))
	display_buffer_line_push_back(&line, display_buffer_atom_range(&buf, Buffer_Range{{0, 4}, {0, 6}}, Face{}))
	idx := display_buffer_line_insert(
		&line,
		1,
		display_buffer_atom_range(&buf, Buffer_Range{{0, 2}, {0, 4}}, Face{}),
	)
	testing.expect_value(t, idx, 1)
	testing.expect_value(t, len(line.atoms), 3)
	testing.expect_value(t, display_buffer_atom_content(line.atoms[1]), "cd")
	testing.expect_value(t, line.range, Buffer_Range{{0, 0}, {0, 6}})
	many := []Display_Atom{
		display_buffer_atom_range(&buf, Buffer_Range{{0, 1}, {0, 2}}, Face{}),
		display_buffer_atom_text("z", Face{}),
	}
	display_buffer_line_insert_many(&line, 0, many)
	testing.expect_value(t, len(line.atoms), 5)
	testing.expect_value(t, display_buffer_atom_content(line.atoms[1]), "z")
	testing.expect_value(t, line.range, Buffer_Range{{0, 0}, {0, 6}})
}

@(test)
test_display_buffer_line_insert_many_no_prior_range :: proc(t: ^testing.T) {
	buf := display_buffer_test_make_buffer({"abcdef"})
	defer display_buffer_test_destroy_buffer(&buf)
	line := display_buffer_line_make()
	defer display_buffer_line_destroy(&line)
	display_buffer_line_push_back(&line, display_buffer_atom_text("x", Face{}))
	many := []Display_Atom{
		display_buffer_atom_range(&buf, Buffer_Range{{0, 2}, {0, 3}}, Face{}),
		display_buffer_atom_range(&buf, Buffer_Range{{0, 4}, {0, 5}}, Face{}),
	}
	display_buffer_line_insert_many(&line, 1, many)
	testing.expect_value(t, line.range, Buffer_Range{{0, 2}, {0, 5}})
}

@(test)
test_display_buffer_line_split_coord :: proc(t: ^testing.T) {
	buf := display_buffer_test_make_buffer({"hello"})
	defer display_buffer_test_destroy_buffer(&buf)
	line := display_buffer_line_make()
	defer display_buffer_line_destroy(&line)
	display_buffer_line_push_back(&line, display_buffer_atom_range(&buf, Buffer_Range{{0, 0}, {0, 5}}, Face{}))
	idx := display_buffer_line_split_coord(&line, 0, Coord_Buffer{0, 2})
	testing.expect_value(t, idx, 0)
	testing.expect_value(t, len(line.atoms), 2)
	testing.expect_value(t, display_buffer_atom_content(line.atoms[0]), "he")
	testing.expect_value(t, display_buffer_atom_content(line.atoms[1]), "llo")
	testing.expect_value(t, line.range, Buffer_Range{{0, 0}, {0, 5}})
}

@(test)
test_display_buffer_line_split_col_text :: proc(t: ^testing.T) {
	line := display_buffer_line_make_text("hello", Face{})
	defer display_buffer_line_destroy(&line)
	idx := display_buffer_line_split_col(&line, 0, 2)
	testing.expect_value(t, idx, 0)
	testing.expect_value(t, display_buffer_atom_content(line.atoms[0]), "he")
	testing.expect_value(t, display_buffer_atom_content(line.atoms[1]), "llo")
}

@(test)
test_display_buffer_line_split_col_wide :: proc(t: ^testing.T) {
	line := display_buffer_line_make_text("aあb", Face{})
	defer display_buffer_line_destroy(&line)
	// Column 2 falls inside 'あ' (columns 1-2): the split steps
	// back so the wide char starts the second atom.
	idx := display_buffer_line_split_col(&line, 0, 2)
	testing.expect_value(t, idx, 0)
	testing.expect_value(t, display_buffer_atom_content(line.atoms[0]), "a")
	testing.expect_value(t, display_buffer_atom_content(line.atoms[1]), "あb")
}

@(test)
test_display_buffer_line_split_col_range :: proc(t: ^testing.T) {
	buf := display_buffer_test_make_buffer({"hello"})
	defer display_buffer_test_destroy_buffer(&buf)
	line := display_buffer_line_make()
	defer display_buffer_line_destroy(&line)
	display_buffer_line_push_back(&line, display_buffer_atom_range(&buf, Buffer_Range{{0, 0}, {0, 5}}, Face{}))
	idx := display_buffer_line_split_col(&line, 0, 3)
	testing.expect_value(t, idx, 0)
	testing.expect_value(t, display_buffer_atom_content(line.atoms[0]), "hel")
	testing.expect_value(t, display_buffer_atom_content(line.atoms[1]), "lo")
}

@(test)
test_display_buffer_line_split_at :: proc(t: ^testing.T) {
	buf := display_buffer_test_make_buffer({"hello"})
	defer display_buffer_test_destroy_buffer(&buf)
	line := display_buffer_line_make()
	defer display_buffer_line_destroy(&line)
	display_buffer_line_push_back(&line, display_buffer_atom_range(&buf, Buffer_Range{{0, 0}, {0, 5}}, Face{}))
	idx := display_buffer_line_split_at(&line, Coord_Buffer{0, 2})
	testing.expect_value(t, idx, 1)
	testing.expect_value(t, display_buffer_atom_content(line.atoms[1]), "llo")
	// Splitting on an existing boundary is a no-op returning it.
	testing.expect_value(t, display_buffer_line_split_at(&line, Coord_Buffer{0, 2}), 1)
	testing.expect_value(t, len(line.atoms), 2)
	// Past the end returns the end index.
	testing.expect_value(t, display_buffer_line_split_at(&line, Coord_Buffer{0, 9}), 2)
}

@(test)
test_display_buffer_line_extract :: proc(t: ^testing.T) {
	line := display_buffer_line_make()
	defer display_buffer_line_destroy(&line)
	words := []string{"a", "b", "c", "d"}
	for s in words {
		display_buffer_line_push_back(&line, display_buffer_atom_text(s, Face{}))
	}
	extracted := display_buffer_line_extract(&line, 1, 3)
	defer display_buffer_line_destroy(&extracted)
	testing.expect_value(t, len(extracted.atoms), 2)
	testing.expect_value(t, display_buffer_atom_content(extracted.atoms[0]), "b")
	testing.expect_value(t, display_buffer_atom_content(extracted.atoms[1]), "c")
	testing.expect_value(t, len(line.atoms), 2)
	testing.expect_value(t, display_buffer_atom_content(line.atoms[0]), "a")
	testing.expect_value(t, display_buffer_atom_content(line.atoms[1]), "d")
	whole := display_buffer_line_extract(&line, 0, 2)
	defer display_buffer_line_destroy(&whole)
	testing.expect_value(t, len(whole.atoms), 2)
	testing.expect_value(t, len(line.atoms), 0)
}

@(test)
test_display_buffer_line_extract_range :: proc(t: ^testing.T) {
	buf := display_buffer_test_make_buffer({"abcdef"})
	defer display_buffer_test_destroy_buffer(&buf)
	line := display_buffer_line_make()
	defer display_buffer_line_destroy(&line)
	display_buffer_line_push_back(&line, display_buffer_atom_range(&buf, Buffer_Range{{0, 0}, {0, 2}}, Face{}))
	display_buffer_line_push_back(&line, display_buffer_atom_range(&buf, Buffer_Range{{0, 2}, {0, 4}}, Face{}))
	display_buffer_line_push_back(&line, display_buffer_atom_range(&buf, Buffer_Range{{0, 4}, {0, 6}}, Face{}))
	extracted := display_buffer_line_extract(&line, 0, 1)
	defer display_buffer_line_destroy(&extracted)
	testing.expect_value(t, extracted.range, Buffer_Range{{0, 0}, {0, 2}})
	testing.expect_value(t, line.range, Buffer_Range{{0, 2}, {0, 6}})
}

@(test)
test_display_buffer_line_erase :: proc(t: ^testing.T) {
	buf := display_buffer_test_make_buffer({"abcdef"})
	defer display_buffer_test_destroy_buffer(&buf)
	line := display_buffer_line_make()
	defer display_buffer_line_destroy(&line)
	display_buffer_line_push_back(&line, display_buffer_atom_range(&buf, Buffer_Range{{0, 0}, {0, 2}}, Face{}))
	display_buffer_line_push_back(&line, display_buffer_atom_range(&buf, Buffer_Range{{0, 2}, {0, 4}}, Face{}))
	display_buffer_line_push_back(&line, display_buffer_atom_range(&buf, Buffer_Range{{0, 4}, {0, 6}}, Face{}))
	testing.expect_value(t, display_buffer_line_erase(&line, 0, 2), 0)
	testing.expect_value(t, len(line.atoms), 1)
	testing.expect_value(t, line.range, Buffer_Range{{0, 4}, {0, 6}})
}

@(test)
test_display_buffer_line_trim :: proc(t: ^testing.T) {
	line := display_buffer_line_make_text("hello world", Face{})
	defer display_buffer_line_destroy(&line)
	// did_trim only reports leftover atoms past the cap, so cutting
	// a single atom down still reports false.
	trimmed := display_buffer_line_trim(&line, 6, 3)
	testing.expect(t, !trimmed, "no atoms past the cap")
	testing.expect_value(t, len(line.atoms), 1)
	testing.expect_value(t, display_buffer_atom_content(line.atoms[0]), "wor")
	untrimmed := display_buffer_line_trim(&line, 0, 9)
	testing.expect(t, !untrimmed, "nothing cut")
	testing.expect_value(t, display_buffer_atom_content(line.atoms[0]), "wor")
	// Trimming everything leaves no atoms.
	testing.expect(t, !display_buffer_line_trim(&line, 9, 9), "empty trim reports false")
	testing.expect_value(t, len(line.atoms), 0)
	multi := display_buffer_line_make()
	defer display_buffer_line_destroy(&multi)
	pairs := []string{"ab", "cd", "ef"}
	for s in pairs {
		display_buffer_line_push_back(&multi, display_buffer_atom_text(s, Face{}))
	}
	testing.expect(t, display_buffer_line_trim(&multi, 0, 4), "leftover atom past the cap")
	testing.expect_value(t, len(multi.atoms), 2)
	testing.expect_value(t, display_buffer_atom_content(multi.atoms[1]), "cd")
}

@(test)
test_display_buffer_line_trim_padding :: proc(t: ^testing.T) {
	line := display_buffer_line_make_text("aあb", Face{})
	defer display_buffer_line_destroy(&line)
	trimmed := display_buffer_line_trim(&line, 2, 9)
	testing.expect(t, !trimmed, "nothing cut off the end")
	testing.expect_value(t, len(line.atoms), 2)
	// Trimming 2 columns eats 'a' plus 'あ' (overshoot 1), so one
	// padding space replaces the half-eaten wide char.
	testing.expect_value(t, display_buffer_atom_content(line.atoms[0]), " ")
	testing.expect_value(t, display_buffer_atom_content(line.atoms[1]), "b")
	delete(line.atoms[0].text)
}

@(test)
test_display_buffer_line_trim_from :: proc(t: ^testing.T) {
	line := display_buffer_line_make()
	defer display_buffer_line_destroy(&line)
	display_buffer_line_push_back(&line, display_buffer_atom_text("ab", Face{}))
	display_buffer_line_push_back(&line, display_buffer_atom_text("cdef", Face{}))
	// Skip the first atom, drop 2 columns, keep the rest.
	trimmed := display_buffer_line_trim_from(&line, 2, 2, 9)
	testing.expect(t, !trimmed, "nothing cut off the end")
	testing.expect_value(t, len(line.atoms), 2)
	testing.expect_value(t, display_buffer_atom_content(line.atoms[0]), "ab")
	testing.expect_value(t, display_buffer_atom_content(line.atoms[1]), "ef")
	split := display_buffer_line_make()
	defer display_buffer_line_destroy(&split)
	display_buffer_line_push_back(&split, display_buffer_atom_text("ab", Face{}))
	display_buffer_line_push_back(&split, display_buffer_atom_text("cdef", Face{}))
	// first_col inside the first atom with front > 0 splits the atom
	// at the front width, then drops the second half.
	testing.expect(t, !display_buffer_line_trim_from(&split, 1, 1, 9), "nothing cut off the end")
	testing.expect_value(t, len(split.atoms), 2)
	testing.expect_value(t, display_buffer_atom_content(split.atoms[0]), "a")
	testing.expect_value(t, display_buffer_atom_content(split.atoms[1]), "cdef")
}

@(test)
test_display_buffer_line_optimize :: proc(t: ^testing.T) {
	red := Face{fg = color_from_named(.Red)}
	line := display_buffer_line_make()
	defer display_buffer_line_destroy(&line)
	display_buffer_line_push_back(&line, display_buffer_atom_text("a", Face{}))
	display_buffer_line_push_back(&line, display_buffer_atom_text("b", Face{}))
	display_buffer_line_push_back(&line, display_buffer_atom_text("c", red))
	display_buffer_line_optimize(&line)
	testing.expect_value(t, len(line.atoms), 2)
	testing.expect_value(t, display_buffer_atom_content(line.atoms[0]), "ab")
	testing.expect_value(t, display_buffer_atom_content(line.atoms[1]), "c")
	delete(line.atoms[0].text)
}

@(test)
test_display_buffer_line_optimize_range :: proc(t: ^testing.T) {
	buf := display_buffer_test_make_buffer({"abcdef"})
	defer display_buffer_test_destroy_buffer(&buf)
	line := display_buffer_line_make()
	defer display_buffer_line_destroy(&line)
	display_buffer_line_push_back(&line, display_buffer_atom_range(&buf, Buffer_Range{{0, 0}, {0, 2}}, Face{}))
	display_buffer_line_push_back(&line, display_buffer_atom_range(&buf, Buffer_Range{{0, 2}, {0, 4}}, Face{}))
	// Non-adjacent: a gap at {0,4}-{0,5} blocks the merge.
	display_buffer_line_push_back(&line, display_buffer_atom_range(&buf, Buffer_Range{{0, 5}, {0, 6}}, Face{}))
	display_buffer_line_optimize(&line)
	testing.expect_value(t, len(line.atoms), 2)
	testing.expect_value(t, line.atoms[0].range, Buffer_Range{{0, 0}, {0, 4}})
	testing.expect_value(t, line.range, Buffer_Range{{0, 0}, {0, 6}})
}

@(test)
test_display_buffer_line_optimize_replaced :: proc(t: ^testing.T) {
	buf := display_buffer_test_make_buffer({"abcd"})
	defer display_buffer_test_destroy_buffer(&buf)
	line := display_buffer_line_make()
	defer display_buffer_line_destroy(&line)
	display_buffer_line_push_back(
		&line,
		display_buffer_atom_replaced(&buf, Buffer_Range{{0, 0}, {0, 2}}, "X", Face{}),
	)
	display_buffer_line_push_back(
		&line,
		display_buffer_atom_replaced(&buf, Buffer_Range{{0, 2}, {0, 4}}, "Y", Face{}),
	)
	display_buffer_line_optimize(&line)
	testing.expect_value(t, len(line.atoms), 1)
	testing.expect_value(t, line.atoms[0].range, Buffer_Range{{0, 0}, {0, 4}})
	testing.expect_value(t, display_buffer_atom_content(line.atoms[0]), "XY")
	delete(line.atoms[0].text)
}

@(test)
test_display_buffer_compute_range :: proc(t: ^testing.T) {
	buf := display_buffer_test_make_buffer({"ab", "cdef"})
	defer display_buffer_test_destroy_buffer(&buf)
	display := display_buffer_make()
	defer display_buffer_destroy(&display)
	testing.expect_value(t, display.timestamp, -1)
	display_buffer_compute_range(&display)
	testing.expect_value(t, display.range, Buffer_Range{{0, 0}, {0, 0}})
	first := display_buffer_line_make()
	display_buffer_line_push_back(&first, display_buffer_atom_range(&buf, Buffer_Range{{0, 1}, {0, 2}}, Face{}))
	second := display_buffer_line_make()
	display_buffer_line_push_back(
		&second,
		display_buffer_atom_range(&buf, Buffer_Range{{1, 0}, {1, 4}}, Face{}),
	)
	append(&display.lines, first, second)
	display_buffer_compute_range(&display)
	testing.expect_value(t, display.range, Buffer_Range{{0, 1}, {1, 4}})
}

@(test)
test_display_buffer_optimize :: proc(t: ^testing.T) {
	display := display_buffer_make()
	defer display_buffer_destroy(&display)
	line := display_buffer_line_make_text("a", Face{})
	display_buffer_line_push_back(&line, display_buffer_atom_text("b", Face{}))
	append(&display.lines, line)
	display_buffer_optimize(&display)
	testing.expect_value(t, len(display.lines[0].atoms), 1)
	testing.expect_value(t, display_buffer_atom_content(display.lines[0].atoms[0]), "ab")
	delete(display.lines[0].atoms[0].text)
}

@(test)
test_display_buffer_parse_plain :: proc(t: ^testing.T) {
	reg := face_registry_make()
	defer face_registry_destroy(&reg)
	line, err := display_buffer_parse_line("hello", &reg, nil, context.temp_allocator)
	testing.expect_value(t, err, Display_Buffer_Error.None)
	testing.expect_value(t, len(line.atoms), 1)
	testing.expect_value(t, display_buffer_atom_content(line.atoms[0]), "hello")
	testing.expect(t, line.atoms[0].face == Face{}, "default face")
}

@(test)
test_display_buffer_parse_face :: proc(t: ^testing.T) {
	reg := face_registry_make()
	defer face_registry_destroy(&reg)
	line, err := display_buffer_parse_line("a{red}b{blue}c", &reg, nil, context.temp_allocator)
	testing.expect_value(t, err, Display_Buffer_Error.None)
	testing.expect_value(t, len(line.atoms), 3)
	testing.expect_value(t, display_buffer_atom_content(line.atoms[0]), "a")
	testing.expect(t, line.atoms[0].face == Face{}, "first atom default face")
	want_red, _ := face_registry_lookup(&reg, "red", context.temp_allocator)
	testing.expect(t, line.atoms[1].face == want_red, "red face")
	testing.expect_value(t, display_buffer_atom_content(line.atoms[1]), "b")
	want_blue, _ := face_registry_lookup(&reg, "blue", context.temp_allocator)
	testing.expect(t, line.atoms[2].face == want_blue, "blue face")
}

@(test)
test_display_buffer_parse_escapes :: proc(t: ^testing.T) {
	reg := face_registry_make()
	defer face_registry_destroy(&reg)
	line, err := display_buffer_parse_line("a\\{red}b\\\\c", &reg, nil, context.temp_allocator)
	testing.expect_value(t, err, Display_Buffer_Error.None)
	testing.expect_value(t, len(line.atoms), 1)
	testing.expect_value(t, display_buffer_atom_content(line.atoms[0]), "a{red}b\\c")
	// Tabs and newlines become spaces.
	spaced, serr := display_buffer_parse_line("a\tb\nc", &reg, nil, context.temp_allocator)
	testing.expect_value(t, serr, Display_Buffer_Error.None)
	testing.expect_value(t, display_buffer_atom_content(spaced.atoms[0]), "a b c")
	// {\} ends markup: the rest is literal.
	rest, rerr := display_buffer_parse_line("a{\\}b{red}c", &reg, nil, context.temp_allocator)
	testing.expect_value(t, rerr, Display_Buffer_Error.None)
	testing.expect_value(t, len(rest.atoms), 2)
	testing.expect_value(t, display_buffer_atom_content(rest.atoms[0]), "a")
	testing.expect_value(t, display_buffer_atom_content(rest.atoms[1]), "b{red}c")
}

@(test)
test_display_buffer_parse_builtin :: proc(t: ^testing.T) {
	reg := face_registry_make()
	defer face_registry_destroy(&reg)
	builtin := display_buffer_line_make_text("X", Face{fg = color_from_named(.Green)})
	defer display_buffer_line_destroy(&builtin)
	builtins := make(map[string]Display_Line)
	defer delete(builtins)
	builtins["mark"] = builtin
	line, err := display_buffer_parse_line("a{{mark}}b", &reg, builtins, context.temp_allocator)
	testing.expect_value(t, err, Display_Buffer_Error.None)
	testing.expect_value(t, len(line.atoms), 3)
	testing.expect_value(t, display_buffer_atom_content(line.atoms[0]), "a")
	testing.expect_value(t, display_buffer_atom_content(line.atoms[1]), "X")
	testing.expect(t, line.atoms[1].face == builtin.atoms[0].face, "builtin face kept")
	testing.expect_value(t, display_buffer_atom_content(line.atoms[2]), "b")
}

@(test)
test_display_buffer_parse_errors :: proc(t: ^testing.T) {
	reg := face_registry_make()
	defer face_registry_destroy(&reg)
	testing.expect_value(t, Display_Buffer_Error.None, Display_Buffer_Error(0))
	_, err := display_buffer_parse_line("a{red", &reg, nil, context.temp_allocator)
	testing.expect_value(t, err, Display_Buffer_Error.Unclosed_Face)
	_, uerr := display_buffer_parse_line("a{{nope}}", &reg, nil, context.temp_allocator)
	testing.expect_value(t, uerr, Display_Buffer_Error.Undefined_Atom)
	_, ferr := display_buffer_parse_line("a{notacolor,,,}b", &reg, nil, context.temp_allocator)
	testing.expect_value(t, ferr, Display_Buffer_Error.Invalid_Face)
}

@(test)
test_display_buffer_parse_line_list :: proc(t: ^testing.T) {
	reg := face_registry_make()
	defer face_registry_destroy(&reg)
	lines, err := display_buffer_parse_line_list("a{red}b\nc\nd", &reg, nil, context.temp_allocator)
	testing.expect_value(t, err, Display_Buffer_Error.None)
	testing.expect_value(t, len(lines), 3)
	want_red, _ := face_registry_lookup(&reg, "red", context.temp_allocator)
	testing.expect(t, lines[1].atoms[0].face == want_red, "face carries across lines")
	testing.expect_value(t, display_buffer_atom_content(lines[2].atoms[0]), "d")
	trailing, terr := display_buffer_parse_line_list("a\n", &reg, nil, context.temp_allocator)
	testing.expect_value(t, terr, Display_Buffer_Error.None)
	testing.expect_value(t, len(trailing), 2)
	testing.expect_value(t, len(trailing[1].atoms), 0)
	empty, eerr := display_buffer_parse_line_list("", &reg, nil, context.temp_allocator)
	testing.expect_value(t, eerr, Display_Buffer_Error.None)
	testing.expect_value(t, len(empty), 0)
}
