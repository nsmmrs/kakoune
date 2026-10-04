// Tests for buffer.odin (port of the Buffer UnitTests in src/buffer.cc,
// plus edge cases for coords, iterators, reload, and saved-state).
//
// Never calls STUB-blocked procs (buffer_set_name, buffer_on_registered
// past the Debug guard, buffer_offset_coord_by_line, ...): those panic
// until their modules merge. See the module summary for the gaps.
package kak

import "core:strings"
import "core:testing"

// buffer_test_make builds a scratch buffer; tests free it with
// buffer_destroy (usually via defer).
buffer_test_make :: proc(lines: []string, flags: Buffer_Flags = Buffer_Flags{}, name := "test") -> ^Buffer {
	return buffer_make(name, flags, lines, .None, .Lf, .Present, File_Fs_Status{timestamp = File_Invalid_Time})
}

buffer_test_lines := [4]string{"allo ?\n", "mais que fais la police\n", " hein ?\n", " youpi\n"}

// Port of C++ UnitTest test_buffer: iterators, insert, end-of-buffer
// newline handling, and a commit/erase/insert/undo/redo cycle.
@(test)
test_buffer_basic :: proc(t: ^testing.T) {
	empty := buffer_test_make([]string{"\n"}, {}, "empty")
	defer buffer_destroy(empty)

	b := buffer_test_make(buffer_test_lines[:])
	defer buffer_destroy(b)
	testing.expect(t, buffer_line_count(b) == 4)

	pos := buffer_begin(b)
	testing.expect_value(t, buffer_iterator_deref(pos), 'a')
	buffer_iterator_advance(&pos, 6)
	testing.expect_value(t, buffer_iterator_coord(pos), Coord_Buffer{0, 6})
	buffer_iterator_next(&pos)
	testing.expect_value(t, buffer_iterator_coord(pos), Coord_Buffer{1, 0})
	buffer_iterator_prev(&pos)
	testing.expect_value(t, buffer_iterator_coord(pos), Coord_Buffer{0, 6})
	buffer_iterator_advance(&pos, 1)
	testing.expect_value(t, buffer_iterator_coord(pos), Coord_Buffer{1, 0})
	_, err := buffer_insert(b, buffer_iterator_coord(pos), "tchou kanaky\n")
	testing.expect_value(t, err, Buffer_Error.None)
	testing.expect(t, buffer_line_count(b) == 5)
	pos2 := buffer_end(b)
	buffer_iterator_recede(&pos2, 9)
	testing.expect_value(t, buffer_iterator_deref(pos2), '?')

	str := buffer_string(b, {4, 1}, buffer_next(b, {4, 5}))
	defer delete(str)
	testing.expect_value(t, str, "youpi")

	// Insert at end gains the missing newline.
	posc := buffer_iterator_coord(buffer_iterator_sub(buffer_end(b), 1))
	_, err = buffer_insert(b, posc, "tchou")
	testing.expect_value(t, err, Buffer_Error.None)
	s := buffer_string(b, posc, buffer_end_coord(b))
	defer delete(s)
	testing.expect_value(t, s, "tchou\n")

	// Appending a full line at the end coord.
	old_end := buffer_iterator_coord(buffer_iterator_sub(buffer_end(b), 1))
	old_end = buffer_iterator_coord(buffer_iterator_add(buffer_iterator_at(b, old_end), 1))
	_, err = buffer_insert(b, buffer_end_coord(b), "kanaky\n")
	testing.expect_value(t, err, Buffer_Error.None)
	s2 := buffer_string(b, old_end, buffer_end_coord(b))
	defer delete(s2)
	testing.expect_value(t, s2, "kanaky\n")

	buffer_commit_undo_group(b)
	_, err = buffer_erase(b, old_end, buffer_end_coord(b))
	testing.expect_value(t, err, Buffer_Error.None)
	_, err = buffer_insert(b, buffer_end_coord(b), "mutch\n")
	testing.expect_value(t, err, Buffer_Error.None)
	buffer_commit_undo_group(b)
	ok, uerr := buffer_undo(b)
	testing.expect_value(t, uerr, Buffer_Error.None)
	testing.expect(t, ok)
	s3 := buffer_string(b, buffer_advance(b, buffer_end_coord(b), -7), buffer_end_coord(b))
	defer delete(s3)
	testing.expect_value(t, s3, "kanaky\n")
	ok, uerr = buffer_redo(b)
	testing.expect_value(t, uerr, Buffer_Error.None)
	testing.expect(t, ok)
	s4 := buffer_string(b, buffer_advance(b, buffer_end_coord(b), -6), buffer_end_coord(b))
	defer delete(s4)
	testing.expect_value(t, s4, "mutch\n")
}

// Port of C++ UnitTest test_undo: branching history, undo/redo counts,
// replace, and move_to across the undo tree.
@(test)
test_buffer_undo_tree :: proc(t: ^testing.T) {
	b := buffer_test_make(buffer_test_lines[:])
	defer buffer_destroy(b)

	pos := buffer_end_coord(b)
	_, _ = buffer_insert(b, pos, "kanaky\n") // change 1
	buffer_commit_undo_group(b)
	_, _ = buffer_erase(b, pos, buffer_end_coord(b)) // change 2
	buffer_commit_undo_group(b)
	_, _ = buffer_insert(b, {2, 0}, "tchou\n") // change 3
	buffer_commit_undo_group(b)
	_, _ = buffer_undo(b)
	_, _ = buffer_insert(b, {2, 0}, "mutch\n") // change 4
	buffer_commit_undo_group(b)
	_, _ = buffer_erase(b, {2, 1}, {2, 5}) // change 5
	buffer_commit_undo_group(b)
	_, _ = buffer_undo(b, 2)
	_, _ = buffer_redo(b, 2)
	_, _ = buffer_undo(b)
	_, _ = buffer_replace(b, {2, 0}, buffer_end_coord(b), "foo") // change 6
	buffer_commit_undo_group(b)

	testing.expect(t, buffer_line_count(b) == 3)
	testing.expect_value(t, buffer_line(b, 0), "allo ?\n")
	testing.expect_value(t, buffer_line(b, 1), "mais que fais la police\n")
	testing.expect_value(t, buffer_line(b, 2), "foo\n")

	_, _ = buffer_move_to(b, Buffer_History_Id(3))
	testing.expect(t, buffer_line_count(b) == 5)
	testing.expect_value(t, buffer_line(b, 0), "allo ?\n")
	testing.expect_value(t, buffer_line(b, 1), "mais que fais la police\n")
	testing.expect_value(t, buffer_line(b, 2), "tchou\n")
	testing.expect_value(t, buffer_line(b, 3), " hein ?\n")
	testing.expect_value(t, buffer_line(b, 4), " youpi\n")

	_, _ = buffer_move_to(b, Buffer_History_Id(4))
	testing.expect(t, buffer_line_count(b) == 5)
	testing.expect_value(t, buffer_line(b, 0), "allo ?\n")
	testing.expect_value(t, buffer_line(b, 1), "mais que fais la police\n")
	testing.expect_value(t, buffer_line(b, 2), "mutch\n")
	testing.expect_value(t, buffer_line(b, 3), " hein ?\n")
	testing.expect_value(t, buffer_line(b, 4), " youpi\n")

	_, _ = buffer_move_to(b, buffer_HISTORY_FIRST)
	testing.expect(t, buffer_line_count(b) == 4)
	testing.expect_value(t, buffer_line(b, 0), "allo ?\n")
	testing.expect_value(t, buffer_line(b, 1), "mais que fais la police\n")
	testing.expect_value(t, buffer_line(b, 2), " hein ?\n")
	testing.expect_value(t, buffer_line(b, 3), " youpi\n")
	ok, _ := buffer_undo(b)
	testing.expect(t, !ok)

	_, _ = buffer_move_to(b, Buffer_History_Id(5))
	ok, _ = buffer_redo(b)
	testing.expect(t, !ok)

	_, _ = buffer_move_to(b, Buffer_History_Id(6))
	ok, _ = buffer_redo(b)
	testing.expect(t, !ok)
}

// Coords, distances, stepping, and clamping on a small buffer.
@(test)
test_buffer_coords :: proc(t: ^testing.T) {
	b := buffer_test_make({"ab\n", "cdef\n", "\n"})
	defer buffer_destroy(b)

	testing.expect_value(t, buffer_back_coord(b), Coord_Buffer{2, 0})
	testing.expect_value(t, buffer_end_coord(b), Coord_Buffer{3, 0})
	testing.expect(t, buffer_is_valid(b, {0, 0}))
	testing.expect(t, buffer_is_valid(b, {0, 2}))
	testing.expect(t, buffer_is_valid(b, {2, 0}))
	testing.expect(t, buffer_is_valid(b, {3, 0}))
	testing.expect(t, !buffer_is_valid(b, {0, 3}))
	testing.expect(t, !buffer_is_valid(b, {3, 1}))
	testing.expect(t, !buffer_is_valid(b, {-1, 0}))
	testing.expect(t, buffer_is_end(b, {3, 0}))
	testing.expect(t, !buffer_is_end(b, {2, 0}))

	testing.expect_value(t, buffer_byte_at(b, {1, 2}), 'e')
	testing.expect_value(t, buffer_next(b, {0, 2}), Coord_Buffer{1, 0})
	testing.expect_value(t, buffer_prev(b, {1, 0}), Coord_Buffer{0, 2})
	testing.expect_value(t, buffer_next(b, {0, 0}), Coord_Buffer{0, 1})

	// Advance and distance round-trip, with clamping at both ends.
	testing.expect_value(t, buffer_advance(b, {0, 0}, 4), Coord_Buffer{1, 1})
	testing.expect_value(t, buffer_advance(b, {1, 1}, -4), Coord_Buffer{0, 0})
	testing.expect_value(t, buffer_advance(b, {0, 0}, 100), Coord_Buffer{3, 0})
	testing.expect_value(t, buffer_advance(b, {2, 0}, -100), Coord_Buffer{0, 0})
	testing.expect_value(t, buffer_advance(b, {1, 2}, 0), Coord_Buffer{1, 2})
	testing.expect_value(t, buffer_distance(b, {0, 0}, {1, 1}), Units_ByteCount(4))
	testing.expect_value(t, buffer_distance(b, {1, 1}, {0, 0}), Units_ByteCount(-4))
	testing.expect_value(t, buffer_distance(b, {0, 1}, {0, 1}), Units_ByteCount(0))
	testing.expect_value(t, buffer_distance(b, {0, 0}, buffer_end_coord(b)), Units_ByteCount(9))

	// Clamp pulls outside coords back into range.
	testing.expect_value(t, buffer_clamp(b, {9, 99}), Coord_Buffer{2, 0})
	testing.expect_value(t, buffer_clamp(b, {1, 99}), Coord_Buffer{1, 4})
	testing.expect_value(t, buffer_clamp(b, {0, 1}), Coord_Buffer{0, 1})

	// Static line-array variants agree with the member ones.
	testing.expect_value(t, buffer_advance_lines(b.lines[:], {0, 0}, 4), Coord_Buffer{1, 1})
	testing.expect_value(t, buffer_distance_lines(b.lines[:], {0, 0}, {1, 1}), Units_ByteCount(4))

	// Substr and line views.
	testing.expect_value(t, buffer_substr(b, {1, 1}, {1, 3}), "de")
	testing.expect_value(t, buffer_line(b, 1), "cdef\n")
}

// Char stepping over multibyte content.
@(test)
test_buffer_char_step :: proc(t: ^testing.T) {
	b := buffer_test_make({"h\xc3\xa9llo\n", "x\n"})
	defer buffer_destroy(b)

	testing.expect_value(t, buffer_char_next(b, {0, 0}), Coord_Buffer{0, 1})
	testing.expect_value(t, buffer_char_next(b, {0, 1}), Coord_Buffer{0, 3})
	testing.expect_value(t, buffer_char_prev(b, {0, 3}), Coord_Buffer{0, 1})
	testing.expect_value(t, buffer_char_prev(b, {1, 0}), Coord_Buffer{0, 6})
	testing.expect_value(t, buffer_char_next(b, {0, 6}), Coord_Buffer{1, 0})

	// Char offsets count codepoints and clamp at both ends.
	testing.expect_value(t, buffer_offset_coord_by_char(b, {0, 0}, 2, 0), Coord_Buffer{0, 3})
	testing.expect_value(t, buffer_offset_coord_by_char(b, {0, 3}, -1, 0), Coord_Buffer{0, 1})
	testing.expect_value(t, buffer_offset_coord_by_char(b, {0, 0}, -5, 0), Coord_Buffer{0, 0})
	testing.expect_value(t, buffer_offset_coord_by_char(b, {0, 0}, 100, 0), buffer_back_coord(b))
	testing.expect_value(t, buffer_offset_coord_by_char(b, {1, 1}, 0, 0), Coord_Buffer{1, 1})
}

// Iterator walk, indexing, distances, and comparisons.
@(test)
test_buffer_iterator :: proc(t: ^testing.T) {
	b := buffer_test_make({"ab\n", "c\n"})
	defer buffer_destroy(b)

	// Full walk spells the content.
	sb := strings.builder_make(context.allocator)
	defer strings.builder_destroy(&sb)
	it := buffer_begin(b)
	end := buffer_end(b)
	for !buffer_iterator_equal(it, end) {
		strings.write_byte(&sb, buffer_iterator_deref(it))
		buffer_iterator_next(&it)
	}
	testing.expect_value(t, strings.to_string(sb), "ab\nc\n")

	// Backward walk reaches begin again.
	back := buffer_end(b)
	buffer_iterator_prev(&back)
	testing.expect_value(t, buffer_iterator_coord(back), Coord_Buffer{1, 1})
	for !buffer_iterator_equal(back, buffer_begin(b)) {
		buffer_iterator_prev(&back)
	}
	testing.expect_value(t, buffer_iterator_deref(back), 'a')

	// Index, distance, ordering.
	first := buffer_begin(b)
	testing.expect_value(t, buffer_iterator_index(first, 3), 'c')
	testing.expect_value(t, buffer_iterator_distance(buffer_end(b), first), 5)
	testing.expect_value(t, buffer_iterator_distance(first, buffer_end(b)), -5)
	testing.expect_value(t, buffer_iterator_compare(first, buffer_end(b)), -1)
	testing.expect_value(t, buffer_iterator_compare(first, first), 0)
	testing.expect(t, buffer_iterator_at_coord(first, {0, 0}))
	testing.expect(t, !buffer_iterator_at_coord(first, {0, 1}))
	testing.expect(t, buffer_iterator_is_valid(first))
	testing.expect(t, !buffer_iterator_is_valid(Buffer_Iterator{}))

	// Value and in-place arithmetic agree.
	plus := buffer_iterator_add(first, 4)
	testing.expect_value(t, buffer_iterator_coord(plus), Coord_Buffer{1, 1})
	testing.expect_value(t, buffer_iterator_coord(buffer_iterator_sub(plus, 4)), Coord_Buffer{0, 0})
	moved := first
	buffer_iterator_advance(&moved, 4)
	testing.expect_value(t, buffer_iterator_coord(moved), Coord_Buffer{1, 1})
	buffer_iterator_recede(&moved, 3)
	testing.expect_value(t, buffer_iterator_coord(moved), Coord_Buffer{0, 1})

	// Postfix forms return the previous position.
	pf := first
	old := buffer_iterator_next_post(&pf)
	testing.expect_value(t, buffer_iterator_coord(old), Coord_Buffer{0, 0})
	testing.expect_value(t, buffer_iterator_coord(pf), Coord_Buffer{0, 1})
	old = buffer_iterator_prev_post(&pf)
	testing.expect_value(t, buffer_iterator_coord(old), Coord_Buffer{0, 1})
	testing.expect_value(t, buffer_iterator_coord(pf), Coord_Buffer{0, 0})

	// Raw-lines constructor mirrors the buffer one.
	raw := buffer_iterator_make_lines(b.lines[:], buffer_line_count(b), {1, 0})
	testing.expect_value(t, buffer_iterator_deref(raw), 'c')
	past := buffer_iterator_make_lines(b.lines[:], buffer_line_count(b), buffer_end_coord(b))
	testing.expect_value(t, buffer_iterator_coord(past), buffer_end_coord(b))
}

// Erase shapes: within a line, across lines, to the end, whole buffer.
@(test)
test_buffer_erase :: proc(t: ^testing.T) {
	b := buffer_test_make(buffer_test_lines[:])
	defer buffer_destroy(b)

	// Empty range is a no-op and records nothing.
	ts := buffer_timestamp(b)
	at, err := buffer_erase(b, {1, 2}, {1, 2})
	testing.expect_value(t, err, Buffer_Error.None)
	testing.expect_value(t, at, Coord_Buffer{1, 2})
	testing.expect_value(t, buffer_timestamp(b), ts)

	// Within one line.
	at, _ = buffer_erase(b, {0, 4}, {0, 6})
	testing.expect_value(t, at, Coord_Buffer{0, 4})
	testing.expect_value(t, buffer_line(b, 0), "allo\n")

	// Across lines joins prefix and suffix.
	at, _ = buffer_erase(b, {1, 4}, {2, 2})
	testing.expect_value(t, at, Coord_Buffer{1, 4})
	testing.expect_value(t, buffer_line(b, 1), "maisein ?\n")
	testing.expect(t, buffer_line_count(b) == 3)

	// Erasing from a line start to the end drops whole lines.
	at, _ = buffer_erase(b, {1, 0}, buffer_end_coord(b))
	testing.expect_value(t, at, Coord_Buffer{1, 0})
	testing.expect(t, buffer_line_count(b) == 1)
	testing.expect_value(t, buffer_line(b, 0), "allo\n")

	// Erasing the whole buffer keeps one empty line.
	at, _ = buffer_erase(b, {0, 0}, buffer_end_coord(b))
	testing.expect_value(t, at, Coord_Buffer{0, 0})
	testing.expect(t, buffer_line_count(b) == 1)
	testing.expect_value(t, buffer_line(b, 0), "\n")

	// Undo restores everything erased above.
	ok, _ := buffer_undo(b)
	testing.expect(t, ok)
	testing.expect(t, buffer_line_count(b) == 4)
	testing.expect_value(t, buffer_line(b, 0), "allo ?\n")
	testing.expect_value(t, buffer_line(b, 1), "mais que fais la police\n")
	testing.expect_value(t, buffer_line(b, 2), " hein ?\n")
	testing.expect_value(t, buffer_line(b, 3), " youpi\n")
}

// Replace shapes: equal-content no-op, plain swap, trailing-newline end.
@(test)
test_buffer_replace :: proc(t: ^testing.T) {
	b := buffer_test_make(buffer_test_lines[:])
	defer buffer_destroy(b)

	// Equal content is a no-op and records nothing.
	ts := buffer_timestamp(b)
	r, err := buffer_replace(b, {0, 0}, {0, 4}, "allo")
	testing.expect_value(t, err, Buffer_Error.None)
	testing.expect_value(t, r, Buffer_Range{begin = {0, 0}, end = {0, 4}})
	testing.expect_value(t, buffer_timestamp(b), ts)

	// Plain swap within a line.
	r, _ = buffer_replace(b, {0, 0}, {0, 4}, "bye")
	testing.expect_value(t, buffer_line(b, 0), "bye ?\n")
	testing.expect_value(t, r.begin, Coord_Buffer{0, 0})

	// Newline-terminated content reaching the end.
	r, _ = buffer_replace(b, {2, 0}, buffer_end_coord(b), "foo\n")
	testing.expect_value(t, r.end, buffer_end_coord(b))
	testing.expect(t, buffer_line_count(b) == 3)
	testing.expect_value(t, buffer_line(b, 2), "foo\n")
}

// Read-only buffers reject every mutation with Read_Only.
@(test)
test_buffer_read_only :: proc(t: ^testing.T) {
	b := buffer_test_make(buffer_test_lines[:])
	defer buffer_destroy(b)
	buffer_set_flags(b, buffer_flags(b) + Buffer_Flags{.Read_Only})
	testing.expect_value(t, buffer_check_read_only(b), Buffer_Error.Read_Only)
	testing.expect_value(t, buffer_error_message(.Read_Only), "buffer is read-only")
	testing.expect_value(t, buffer_error_message(.None), "")

	ts := buffer_timestamp(b)
	_, err := buffer_insert(b, {0, 0}, "x")
	testing.expect_value(t, err, Buffer_Error.Read_Only)
	_, err = buffer_erase(b, {0, 0}, {0, 1})
	testing.expect_value(t, err, Buffer_Error.Read_Only)
	_, err = buffer_replace(b, {0, 0}, {0, 1}, "x")
	testing.expect_value(t, err, Buffer_Error.Read_Only)
	_, err = buffer_undo(b)
	testing.expect_value(t, err, Buffer_Error.Read_Only)
	_, err = buffer_redo(b)
	testing.expect_value(t, err, Buffer_Error.Read_Only)
	testing.expect_value(t, buffer_timestamp(b), ts)
	testing.expect_value(t, buffer_line(b, 0), "allo ?\n")

	// Unknown history ids fail before the read-only check.
	ok, merr := buffer_move_to(b, Buffer_History_Id(99))
	testing.expect(t, !ok)
	testing.expect_value(t, merr, Buffer_Error.None)
	_, merr = buffer_move_to(b, buffer_HISTORY_FIRST)
	testing.expect_value(t, merr, Buffer_Error.Read_Only)
}

// NoUndo buffers mutate without recording history.
@(test)
test_buffer_no_undo :: proc(t: ^testing.T) {
	b := buffer_test_make(buffer_test_lines[:], Buffer_Flags{.No_Undo})
	defer buffer_destroy(b)

	_, err := buffer_insert(b, {0, 0}, "zzz\n")
	testing.expect_value(t, err, Buffer_Error.None)
	_, _ = buffer_erase(b, {0, 0}, {0, 1})
	buffer_commit_undo_group(b)
	testing.expect(t, buffer_line_count(b) == 5)
	testing.expect_value(t, len(buffer_history(b)), 1)
	testing.expect(t, len(buffer_current_undo_group(b)) == 0)
	ok, _ := buffer_undo(b)
	testing.expect(t, !ok)
	_, has_mod := buffer_last_modification_coord(b)
	testing.expect(t, !has_mod)
}

// History edge cases: counts, open groups, unknown ids, same-id moves.
@(test)
test_buffer_history_edges :: proc(t: ^testing.T) {
	b := buffer_test_make(buffer_test_lines[:])
	defer buffer_destroy(b)

	testing.expect_value(t, buffer_current_history_id(b), buffer_HISTORY_FIRST)
	testing.expect_value(t, buffer_next_history_id(b), Buffer_History_Id(1))
	_, has_mod := buffer_last_modification_coord(b)
	testing.expect(t, !has_mod)

	// Committing an empty group creates no node.
	buffer_commit_undo_group(b)
	testing.expect_value(t, buffer_next_history_id(b), Buffer_History_Id(1))

	_, _ = buffer_insert(b, {0, 0}, "a")
	// Redo fails while a group is still open.
	ok, _ := buffer_redo(b)
	testing.expect(t, !ok)
	buffer_commit_undo_group(b)
	testing.expect_value(t, buffer_current_history_id(b), Buffer_History_Id(1))
	coord, has_mod2 := buffer_last_modification_coord(b)
	testing.expect(t, has_mod2)
	testing.expect_value(t, coord, Coord_Buffer{0, 0})

	// Undo with count 0 succeeds without moving.
	ok, _ = buffer_undo(b, 0)
	testing.expect(t, ok)
	testing.expect_value(t, buffer_current_history_id(b), Buffer_History_Id(1))

	// Moving to the current id is a successful no-op.
	ok, _ = buffer_move_to(b, Buffer_History_Id(1))
	testing.expect(t, ok)
	testing.expect_value(t, buffer_line(b, 0), "aallo ?\n")

	// Unknown ids fail cleanly.
	moved, merr := buffer_move_to(b, Buffer_History_Id(42))
	testing.expect(t, !moved)
	testing.expect_value(t, merr, Buffer_Error.None)

	// Inverse flips the modification type, keeping coord and content.
	m := Buffer_Modification{type = .Insert, coord = {1, 2}, content = "hi\n"}
	inv := buffer_modification_inverse(m)
	testing.expect_value(t, inv.type, Buffer_Modification_Type.Erase)
	testing.expect_value(t, inv.coord, Coord_Buffer{1, 2})
	testing.expect_value(t, inv.content, "hi\n")
	testing.expect_value(t, buffer_modification_inverse(inv).type, Buffer_Modification_Type.Insert)
}

// Reload swaps content, records undo, and marks the buffer saved.
@(test)
test_buffer_reload :: proc(t: ^testing.T) {
	b := buffer_test_make(buffer_test_lines[:], Buffer_Flags{.File}, "reloadme")
	defer buffer_destroy(b)
	_, _ = buffer_insert(b, {0, 0}, "dirty")
	testing.expect(t, buffer_is_modified(b))

	// Identical content commits nothing but still marks saved.
	buffer_reload(b, buffer_test_lines[:], .None, .Lf, .Present, File_Fs_Status{})
	testing.expect(t, buffer_line_count(b) == 4)
	testing.expect(t, !buffer_is_modified(b))

	// Changed content is undoable back to the original.
	next := []string{"allo ?\n", "CHANGED\n", " hein ?\n", " youpi\n", "extra\n"}
	buffer_reload(b, next, .None, .Lf, .Present, File_Fs_Status{})
	testing.expect(t, buffer_line_count(b) == 5)
	testing.expect_value(t, buffer_line(b, 1), "CHANGED\n")
	testing.expect(t, !buffer_is_modified(b))
	ok, _ := buffer_undo(b)
	testing.expect(t, ok)
	testing.expect(t, buffer_line_count(b) == 4)
	for i in 0 ..< 4 {
		testing.expect_value(t, buffer_line(b, Units_LineCount(i)), buffer_test_lines[i])
	}
	ok, _ = buffer_redo(b)
	testing.expect(t, ok)
	testing.expect_value(t, buffer_line(b, 1), "CHANGED\n")

	// A full reversal exercises non-trivial diff paths and still
	// round-trips through undo.
	rev := []string{" youpi\n", " hein ?\n", "mais que fais la police\n", "allo ?\n"}
	buffer_move_to(b, buffer_HISTORY_FIRST)
	buffer_reload(b, rev, .None, .Lf, .Present, File_Fs_Status{})
	testing.expect(t, buffer_line_count(b) == 4)
	testing.expect_value(t, buffer_line(b, 0), " youpi\n")
	ok, _ = buffer_undo(b)
	testing.expect(t, ok)
	for i in 0 ..< 4 {
		testing.expect_value(t, buffer_line(b, Units_LineCount(i)), buffer_test_lines[i])
	}

	// Without undo, reload resets the history.
	buffer_reload(b, next, .None, .Lf, .Present, File_Fs_Status{})
	nb := buffer_test_make(buffer_test_lines[:], Buffer_Flags{.No_Undo})
	defer buffer_destroy(nb)
	_, _ = buffer_insert(nb, {0, 0}, "x")
	buffer_reload(nb, next, .None, .Lf, .Present, File_Fs_Status{})
	testing.expect(t, buffer_line_count(nb) == 5)
	testing.expect_value(t, len(buffer_history(nb)), 1)
	testing.expect_value(t, buffer_current_history_id(nb), buffer_HISTORY_FIRST)
	ok, _ = buffer_undo(nb)
	testing.expect(t, !ok)
}

// Saved-state tracking, names, and fs status on File buffers.
@(test)
test_buffer_saved_state :: proc(t: ^testing.T) {
	b := buffer_test_make(buffer_test_lines[:], Buffer_Flags{.File}, "somefile")
	defer buffer_destroy(b)

	testing.expect(t, .File in buffer_flags(b))
	testing.expect(t, !buffer_is_modified(b))
	testing.expect_value(t, buffer_name(b), buffer_filename(b))

	_, _ = buffer_insert(b, {0, 0}, "x")
	testing.expect(t, buffer_is_modified(b))
	buffer_commit_undo_group(b)
	testing.expect(t, buffer_is_modified(b))
	status := File_Fs_Status{timestamp = File_Invalid_Time, file_size = 10, hash = 7}
	buffer_notify_saved(b, status)
	testing.expect(t, !buffer_is_modified(b))
	testing.expect(t, .New not_in buffer_flags(b))
	testing.expect_value(t, buffer_fs_status(b), status)

	buffer_set_fs_status(b, File_Fs_Status{})
	testing.expect_value(t, buffer_fs_status(b).file_size, 0)
	buffer_update_display_name(b)
	testing.expect(t, len(buffer_display_name(b)) != 0)

	// Non-file buffers are never modified and use the display name.
	nb := buffer_test_make(buffer_test_lines[:], {}, "scratch")
	defer buffer_destroy(nb)
	_, _ = buffer_insert(nb, {0, 0}, "x")
	testing.expect(t, !buffer_is_modified(nb))
	testing.expect_value(t, buffer_name(nb), "scratch")
	testing.expect_value(t, buffer_filename(nb), "")
	buffer_update_display_name(nb)
	testing.expect_value(t, buffer_display_name(nb), "scratch")

	// Values ride along without disturbing anything.
	id := value_get_free_id()
	nb.values[id] = value_make(123)
	got, verr := value_as(nb.values[id], int)
	testing.expect_value(t, verr, Value_Error.None)
	testing.expect_value(t, got^, 123)
}

// Timestamps and change views grow with every mutation.
@(test)
test_buffer_changes :: proc(t: ^testing.T) {
	b := buffer_test_make(buffer_test_lines[:])
	defer buffer_destroy(b)

	// The constructor records one synthetic insert-all change.
	testing.expect_value(t, buffer_timestamp(b), 1)
	initial := buffer_changes_since(b, 0)
	testing.expect(t, len(initial) == 1)
	testing.expect_value(t, initial[0].type, Buffer_Change_Type.Insert)

	_, _ = buffer_insert(b, {0, 0}, "q")
	_, _ = buffer_erase(b, {0, 0}, {0, 1})
	testing.expect(t, buffer_timestamp(b) == 3)
	rest := buffer_changes_since(b, 1)
	testing.expect(t, len(rest) == 2)
	testing.expect_value(t, rest[0].type, Buffer_Change_Type.Insert)
	testing.expect_value(t, rest[1].type, Buffer_Change_Type.Erase)
	testing.expect(t, len(buffer_changes_since(b, 99)) == 0)
	testing.expect(t, len(buffer_changes_since(b, buffer_timestamp(b))) == 0)
}

// The enum tables from buffer.hh round-trip.
@(test)
test_buffer_enums :: proc(t: ^testing.T) {
	name, ok := buffer_eol_format_to_name(.Crlf)
	testing.expect(t, ok)
	testing.expect_value(t, name, "crlf")
	f, ok2 := buffer_eol_format_from_name("lf")
	testing.expect(t, ok2)
	testing.expect_value(t, f, Eol_Format.Lf)
	_, ok3 := buffer_eol_format_from_name("bogus")
	testing.expect(t, !ok3)

	bname, _ := buffer_byte_order_mark_to_name(.Utf8)
	testing.expect_value(t, bname, "utf8")
	bom, _ := buffer_byte_order_mark_from_name("none")
	testing.expect_value(t, bom, Byte_Order_Mark.None)

	fname, _ := buffer_final_eol_to_name(.If_Not_Empty)
	testing.expect_value(t, fname, "ifnotempty")
	final, _ := buffer_final_eol_from_name("missing")
	testing.expect_value(t, final, Final_Eol.Missing)
}

// Early-return guards on the stub-blocked hook/option paths.
@(test)
test_buffer_hook_guards :: proc(t: ^testing.T) {
	// NoHooks buffers skip hook dispatch entirely.
	b := buffer_test_make(buffer_test_lines[:], Buffer_Flags{.No_Hooks})
	defer buffer_destroy(b)
	buffer_run_hook_in_own_context(b, .Buf_Create, "param")

	// Debug buffers skip register/unregister work.
	db := buffer_test_make(buffer_test_lines[:], Buffer_Flags{.Debug})
	defer buffer_destroy(db)
	buffer_on_registered(db)
	buffer_on_unregistered(db)

	// NoBufSetOption skips option handling without touching the option.
	nb := buffer_test_make(buffer_test_lines[:], Buffer_Flags{.No_Buf_Set_Option})
	defer buffer_destroy(nb)
	buffer_on_option_changed(nb, nil)
}

// Invariant and debug description smoke tests.
@(test)
test_buffer_debug :: proc(t: ^testing.T) {
	b := buffer_test_make(buffer_test_lines[:], Buffer_Flags{.File}, "dbg")
	defer buffer_destroy(b)
	buffer_check_invariant(b)

	desc := buffer_debug_description(b)
	defer delete(desc)
	testing.expect(t, strings.contains(desc, buffer_display_name(b)))
	testing.expect(t, strings.contains(desc, "Used mem: content="))

	nb := buffer_test_make([]string{"x\n"}, Buffer_Flags{.No_Undo, .Debug, .Read_Only}, "flags")
	defer buffer_destroy(nb)
	fdesc := buffer_debug_description(nb)
	defer delete(fdesc)
	testing.expect(t, strings.contains(fdesc, "NoUndo "))
	testing.expect(t, strings.contains(fdesc, "Debug "))
	testing.expect(t, strings.contains(fdesc, "ReadOnly "))
}

// Decoded file attributes land in the buffer-local options (port of the
// Buffer ctor/reload option sets; regression: finaleol stayed Present
// for missing-EOL files so :write added a trailing newline).
@(test)
test_buffer_set_file_options :: proc(t: ^testing.T) {
	m: Option_Manager
	reg: Options_Registry
	option_manager_test_setup(&m, &reg)
	defer option_manager_registry_destroy(&reg)
	defer option_manager_destroy(&m)
	_, derr := option_manager_registry_declare(&reg, "eolformat", "", Eol_Format.Lf)
	testing.expect_value(t, derr, Option_Manager_Error.None)
	_, derr = option_manager_registry_declare(&reg, "finaleol", "", Final_Eol.Present)
	testing.expect_value(t, derr, Option_Manager_Error.None)
	_, derr = option_manager_registry_declare(&reg, "BOM", "", Byte_Order_Mark.None)
	testing.expect_value(t, derr, Option_Manager_Error.None)

	b := buffer_test_make([]string{"hi\n"})
	defer buffer_destroy(b)
	option_manager_reparent(&b.scope.data.options, &m)
	buffer_set_file_options(b, .Utf8, .Crlf, .Missing)

	opts := &b.scope.data.options
	fe, ferr := option_manager_get_option(&m, "finaleol")
	_ = fe
	testing.expect_value(t, ferr, Option_Manager_Error.None)
	got_bom, _ := option_manager_get_option(opts, "BOM")
	testing.expect_value(t, got_bom.value.(Byte_Order_Mark), Byte_Order_Mark.Utf8)
	got_eol, _ := option_manager_get_option(opts, "eolformat")
	testing.expect_value(t, got_eol.value.(Eol_Format), Eol_Format.Crlf)
	got_fe, _ := option_manager_get_option(opts, "finaleol")
	testing.expect_value(t, got_fe.value.(Final_Eol), Final_Eol.Missing)
	// The parent keeps the defaults (locals, not globals, changed).
	parent_fe, _ := option_manager_get_option(&m, "finaleol")
	testing.expect_value(t, parent_fe.value.(Final_Eol), Final_Eol.Present)
}

