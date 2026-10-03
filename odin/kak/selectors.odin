// Port of Kakoune's src/selectors.{hh,cc}: text-object and motion
// selections over a Buffer.
//
// Mapping notes:
//   * C++ Optional<Selection> becomes (Selection, bool); the C++
//     runtime_error throws ("nothing selected", "invalid capture
//     number", "no matches found", unimplemented nested indents)
//     become Selectors_Error.
//   * C++ BufferIterator/Utf8Iterator become Coord_Buffer values moved
//     with the merged buffer_next/buffer_prev (bytes) and
//     buffer_char_next/buffer_char_prev (codepoints) procs; rune
//     decoding goes through selectors_rune_at. skip_while and
//     skip_while_reverse become selectors_skip_bytes/selectors_skip_runes
//     (forward, reporting whether the end was reached) and the
//     _reverse variants (reporting whether the predicate still holds,
//     exactly like the C++ return of condition(*it)).
//   * C++ templates on WordType/bool become runtime parameters
//     (Unicode_Word_Type, bool). The two regex_select_nested overloads
//     become selectors_regex_select_nested (opening/closing pair) and
//     selectors_regex_select_nested_delim (single delimiter).
//   * Regex work runs on the full buffer text (buffer_string) with byte
//     offsets mapped to coords through buffer_distance/buffer_advance,
//     matching the C++ whole-buffer search ranges. find_surrounding is
//     factored as selectors_find_surrounding_text over a plain string,
//     which is also what the ported UnitTest exercises.
//   * Buffer boundary predicates (is_bol/is_eol/is_bow/is_eow) live in
//     the unmerged buffer_utils module; the three-line forms needed
//     here are implemented locally as selectors_is_bol and siblings
//     (no stub can serve them: the regex paths must run in tests).
//   * Ownership: single-selection procs return selections with nil
//     captures (nothing to free). selectors_find_next_match,
//     selectors_select_matches, selectors_split_on_matches and the
//     nested procs return owned [dynamic]Selection in allocator; the
//     first two clone capture strings, so free each element with
//     selection_destroy before deleting the array.
package kak

import "core:slice"
import "core:strings"

// Selectors_Error reports the failures the C++ signals by throwing
// runtime_error. Zero value None is success.
Selectors_Error :: enum {
	None,
	Nothing_Selected, // selection set came back empty
	Invalid_Capture, // capture index out of range
	No_Match, // find_next_match found nothing (even wrapped)
	Not_Implemented, // select_nested_indents (unimplemented in C++ too)
}

// selectors_error_message describes err.
selectors_error_message :: proc(err: Selectors_Error) -> string {
	switch err {
	case .None:
		return "no error"
	case .Nothing_Selected:
		return "nothing selected"
	case .Invalid_Capture:
		return "invalid capture number"
	case .No_Match:
		return "no matches found"
	case .Not_Implemented:
		return "nested indents are not implemented"
	}
	unreachable()
}

// selectors_selection builds a capture-less selection.
selectors_selection :: proc(anchor, cursor: Coord_Buffer) -> Selection {
	return Selection{basic = Basic_Selection{anchor = anchor, cursor = coord_buffer_and_target(cursor)}}
}

// selectors_keep_direction swaps res endpoints when its direction differs
// from ref (port of keep_direction; only the coord parts move, cursor
// targets stay with the cursor like the C++ swap<BufferCoord>).
selectors_keep_direction :: proc(res, ref: Selection) -> Selection {
	r := res
	res_reversed := coord_compare(r.cursor.coord, r.anchor) < 0
	ref_reversed := coord_compare(ref.cursor.coord, ref.anchor) < 0
	if res_reversed != ref_reversed {
		r.anchor, r.cursor.coord = r.cursor.coord, r.anchor
	}
	return r
}

// selectors_rune_at decodes the codepoint starting at c. The coord must
// address a character start (or the line-final newline, which decodes to
// '\n'); every call site keeps coords on boundaries.
selectors_rune_at :: proc(b: ^Buffer, c: Coord_Buffer) -> rune {
	line := b.lines[int(c.line)]
	col := int(c.column)
	if line[col] == '\n' {
		return '\n'
	}
	pos := col
	return utf8_read_codepoint(line, &pos)
}

// Selectors_Rune_Pred classifies a codepoint for the rune skip helpers;
// data carries predicate-specific state (word tables, target rune).
Selectors_Rune_Pred :: #type proc(cp: rune, data: rawptr) -> bool

// Selectors_Byte_Pred classifies a byte for the byte skip helpers.
Selectors_Byte_Pred :: #type proc(by: byte, data: rawptr) -> bool

// Selectors_Word_Data is the predicate data for word classification.
Selectors_Word_Data :: struct {
	extra:     []rune,
	word_type: Unicode_Word_Type,
}

selectors_pred_eol :: proc(cp: rune, data: rawptr) -> bool {
	_ = data
	return unicode_is_eol(cp)
}

selectors_pred_hblank :: proc(cp: rune, data: rawptr) -> bool {
	_ = data
	return unicode_is_horizontal_blank(cp)
}

selectors_pred_word :: proc(cp: rune, data: rawptr) -> bool {
	d := (^Selectors_Word_Data)(data)
	return unicode_is_word(cp, d.extra, d.word_type)
}

selectors_pred_not_word :: proc(cp: rune, data: rawptr) -> bool {
	return !selectors_pred_word(cp, data)
}

selectors_pred_punct :: proc(cp: rune, data: rawptr) -> bool {
	d := (^Selectors_Word_Data)(data)
	return unicode_is_punctuation(cp, d.extra)
}

// selectors_pred_rune_neq matches anything but the target rune (data is
// ^rune); used by the select_to pair.
selectors_pred_rune_neq :: proc(cp: rune, data: rawptr) -> bool {
	target := (^rune)(data)
	return cp != target^
}

selectors_pred_byte_eol :: proc(by: byte, data: rawptr) -> bool {
	_ = data
	return by == '\n'
}

selectors_pred_byte_hblank :: proc(by: byte, data: rawptr) -> bool {
	_ = data
	return unicode_is_horizontal_blank(rune(by))
}

selectors_pred_byte_blank :: proc(by: byte, data: rawptr) -> bool {
	_ = data
	return unicode_is_blank(rune(by))
}

selectors_pred_byte_blank_or_eol :: proc(by: byte, data: rawptr) -> bool {
	_ = data
	return unicode_is_horizontal_blank(rune(by)) || unicode_is_eol(rune(by))
}

selectors_pred_byte_sentence_end :: proc(by: byte, data: rawptr) -> bool {
	_ = data
	return selectors_byte_is_sentence_end(by)
}

selectors_pred_byte_space_nl_tab :: proc(by: byte, data: rawptr) -> bool {
	_ = data
	return by == ' ' || by == '\n' || by == '\t'
}

selectors_pred_byte_space_only :: proc(by: byte, data: rawptr) -> bool {
	_ = data
	return by == ' '
}

// selectors_pred_byte_number matches digits, plus '.' outside inner mode
// (data is ^bool holding the inner flag).
selectors_pred_byte_number :: proc(by: byte, data: rawptr) -> bool {
	inner := (^bool)(data)
	return (by >= '0' && by <= '9') || (!inner^ && by == '.')
}

selectors_pred_byte_not_number_start :: proc(by: byte, data: rawptr) -> bool {
	return by != '-' && !selectors_pred_byte_number(by, data)
}

selectors_pred_byte_digit :: proc(by: byte, data: rawptr) -> bool {
	_ = data
	return by >= '0' && by <= '9'
}

// selectors_pred_byte_whitespace matches blanks, plus newline outside
// inner mode (data is ^bool holding the inner flag).
selectors_pred_byte_whitespace :: proc(by: byte, data: rawptr) -> bool {
	inner := (^bool)(data)
	return by == ' ' || by == '\t' || (!inner^ && by == '\n')
}

selectors_pred_byte_not_whitespace :: proc(by: byte, data: rawptr) -> bool {
	return !selectors_pred_byte_whitespace(by, data)
}

// selectors_byte_is_sentence_end reports whether by terminates a sentence.
selectors_byte_is_sentence_end :: proc(by: byte) -> bool {
	return by == '.' || by == ';' || by == '!' || by == '?'
}

// selectors_skip_runes advances c^ past codepoints satisfying pred,
// stopping at end. Returns whether c^ stopped before end.
selectors_skip_runes :: proc(b: ^Buffer, c: ^Coord_Buffer, end: Coord_Buffer, pred: Selectors_Rune_Pred, data: rawptr = nil) -> bool {
	for c^ != end && pred(selectors_rune_at(b, c^), data) {
		c^ = buffer_char_next(b, c^)
	}
	return c^ != end
}

// selectors_skip_runes_reverse moves c^ back over codepoints satisfying
// pred, stopping at begin. Returns whether pred still holds at c^ (like
// the C++ skip_while_reverse return of condition(*it)).
selectors_skip_runes_reverse :: proc(b: ^Buffer, c: ^Coord_Buffer, begin: Coord_Buffer, pred: Selectors_Rune_Pred, data: rawptr = nil) -> bool {
	for c^ != begin && pred(selectors_rune_at(b, c^), data) {
		c^ = buffer_char_prev(b, c^)
	}
	return pred(selectors_rune_at(b, c^), data)
}

// selectors_skip_bytes advances c^ past bytes satisfying pred, stopping
// at end. Returns whether c^ stopped before end.
selectors_skip_bytes :: proc(b: ^Buffer, c: ^Coord_Buffer, end: Coord_Buffer, pred: Selectors_Byte_Pred, data: rawptr = nil) -> bool {
	for c^ != end && pred(buffer_byte_at(b, c^), data) {
		c^ = buffer_next(b, c^)
	}
	return c^ != end
}

// selectors_skip_bytes_reverse moves c^ back over bytes satisfying pred,
// stopping at begin. Returns whether pred still holds at c^.
selectors_skip_bytes_reverse :: proc(b: ^Buffer, c: ^Coord_Buffer, begin: Coord_Buffer, pred: Selectors_Byte_Pred, data: rawptr = nil) -> bool {
	for c^ != begin && pred(buffer_byte_at(b, c^), data) {
		c^ = buffer_prev(b, c^)
	}
	return pred(buffer_byte_at(b, c^), data)
}

// selectors_extra_word_chars reads the extra_word_chars option (nil when
// the option is missing, matching its empty default).
selectors_extra_word_chars :: proc(ctx: ^Context) -> []rune {
	opt, err := option_manager_get_option(context_options(ctx), "extra_word_chars")
	if err != .None {
		return nil
	}
	if v, ok := opt.value.([dynamic]rune); ok {
		return v[:]
	}
	return nil
}

// selectors_matching_pairs reads the matching_pairs option (nil when the
// option is missing; matching then finds nothing).
selectors_matching_pairs :: proc(ctx: ^Context) -> []rune {
	opt, err := option_manager_get_option(context_options(ctx), "matching_pairs")
	if err != .None {
		return nil
	}
	if v, ok := opt.value.([dynamic]rune); ok {
		return v[:]
	}
	return nil
}

// selectors_tabstop reads the tabstop option (8, the builtin default,
// when the option is missing).
selectors_tabstop :: proc(ctx: ^Context) -> int {
	opt, err := option_manager_get_option(context_options(ctx), "tabstop")
	if err != .None {
		return 8
	}
	if v, ok := opt.value.(int); ok {
		return v
	}
	return 8
}

// selectors_find_rune returns the index of cp in runes, or -1.
selectors_find_rune :: proc(runes: []rune, cp: rune) -> int {
	for r, i in runes {
		if r == cp {
			return i
		}
	}
	return -1
}

// selectors_is_bol reports whether c starts a line (buffer_utils parity).
selectors_is_bol :: proc(c: Coord_Buffer) -> bool {
	return c.column == 0
}

// selectors_is_eol reports whether c ends a line: the end coord or the
// line-final newline (buffer_utils parity).
selectors_is_eol :: proc(b: ^Buffer, c: Coord_Buffer) -> bool {
	if buffer_is_end(b, c) {
		return true
	}
	return Units_ByteCount(len(b.lines[int(c.line)])) == c.column + 1
}

// selectors_is_bow reports whether c starts a word (buffer_utils parity:
// default word table, like the C++ default arguments).
selectors_is_bow :: proc(b: ^Buffer, c: Coord_Buffer) -> bool {
	if c == (Coord_Buffer{0, 0}) {
		return unicode_is_word(selectors_rune_at(b, c), nil)
	}
	prev := buffer_char_prev(b, c)
	return !unicode_is_word(selectors_rune_at(b, prev), nil) && unicode_is_word(selectors_rune_at(b, c), nil)
}

// selectors_is_eow reports whether c ends a word (buffer_utils parity).
selectors_is_eow :: proc(b: ^Buffer, c: Coord_Buffer) -> bool {
	if buffer_is_end(b, c) || c == (Coord_Buffer{0, 0}) {
		return false
	}
	prev := buffer_char_prev(b, c)
	return unicode_is_word(selectors_rune_at(b, prev), nil) && !unicode_is_word(selectors_rune_at(b, c), nil)
}

// selectors_match_flags builds regex boundary flags for [begin, end)
// (port of the file-static match_flags in selectors.cc).
selectors_match_flags :: proc(b: ^Buffer, begin, end: Coord_Buffer) -> Regex_Vm_Exec_Flags {
	return regex_match_flags(selectors_is_bol(begin), selectors_is_eol(b, end), selectors_is_bow(b, begin), selectors_is_eow(b, end))
}

// selectors_offset_of_coord returns the byte offset of c in the full
// buffer text.
selectors_offset_of_coord :: proc(b: ^Buffer, c: Coord_Buffer) -> int {
	return int(buffer_distance(b, Coord_Buffer{0, 0}, c))
}

// selectors_coord_of_offset maps a byte offset of the full buffer text
// back to a coord.
selectors_coord_of_offset :: proc(b: ^Buffer, off: int) -> Coord_Buffer {
	return buffer_advance(b, Coord_Buffer{0, 0}, Units_ByteCount(off))
}

// selectors_select_to_next_word extends the cursor to the start of the
// next word (port of select_to_next_word).
selectors_select_to_next_word :: proc(ctx: ^Context, sel: Selection, word_type: Unicode_Word_Type) -> (Selection, bool) {
	b := context_buffer(ctx)
	data := Selectors_Word_Data{extra = selectors_extra_word_chars(ctx), word_type = word_type}
	end_coord := buffer_end_coord(b)
	begin := sel.cursor.coord
	if buffer_char_next(b, begin) == end_coord {
		return {}, false
	}
	if unicode_categorize(selectors_rune_at(b, begin), data.extra, word_type) !=
	   unicode_categorize(selectors_rune_at(b, buffer_char_next(b, begin)), data.extra, word_type) {
		begin = buffer_char_next(b, begin)
	}
	if !selectors_skip_runes(b, &begin, end_coord, selectors_pred_eol) {
		return {}, false
	}
	end := buffer_char_next(b, begin)
	first := selectors_rune_at(b, begin)
	if unicode_is_word(first, data.extra, word_type) {
		selectors_skip_runes(b, &end, end_coord, selectors_pred_word, &data)
	} else if unicode_is_punctuation(first, data.extra) {
		selectors_skip_runes(b, &end, end_coord, selectors_pred_punct, &data)
	}
	selectors_skip_runes(b, &end, end_coord, selectors_pred_hblank)
	return selectors_selection(begin, buffer_char_prev(b, end)), true
}

// selectors_select_to_next_word_end extends the cursor to the end of the
// next word (port of select_to_next_word_end).
selectors_select_to_next_word_end :: proc(ctx: ^Context, sel: Selection, word_type: Unicode_Word_Type) -> (Selection, bool) {
	b := context_buffer(ctx)
	data := Selectors_Word_Data{extra = selectors_extra_word_chars(ctx), word_type = word_type}
	end_coord := buffer_end_coord(b)
	begin := sel.cursor.coord
	if buffer_char_next(b, begin) == end_coord {
		return {}, false
	}
	if unicode_categorize(selectors_rune_at(b, begin), data.extra, word_type) !=
	   unicode_categorize(selectors_rune_at(b, buffer_char_next(b, begin)), data.extra, word_type) {
		begin = buffer_char_next(b, begin)
	}
	if !selectors_skip_runes(b, &begin, end_coord, selectors_pred_eol) {
		return {}, false
	}
	end := begin
	selectors_skip_runes(b, &end, end_coord, selectors_pred_hblank)
	last := selectors_rune_at(b, end)
	if unicode_is_word(last, data.extra, word_type) {
		selectors_skip_runes(b, &end, end_coord, selectors_pred_word, &data)
	} else if unicode_is_punctuation(last, data.extra) {
		selectors_skip_runes(b, &end, end_coord, selectors_pred_punct, &data)
	}
	return selectors_selection(begin, buffer_char_prev(b, end)), true
}

// selectors_select_to_previous_word extends the cursor to the start of
// the previous word (port of select_to_previous_word).
selectors_select_to_previous_word :: proc(ctx: ^Context, sel: Selection, word_type: Unicode_Word_Type) -> (Selection, bool) {
	b := context_buffer(ctx)
	data := Selectors_Word_Data{extra = selectors_extra_word_chars(ctx), word_type = word_type}
	begin_coord := Coord_Buffer{0, 0}
	begin := sel.cursor.coord
	if begin == begin_coord {
		return {}, false
	}
	if unicode_categorize(selectors_rune_at(b, begin), data.extra, word_type) !=
	   unicode_categorize(selectors_rune_at(b, buffer_char_prev(b, begin)), data.extra, word_type) {
		begin = buffer_char_prev(b, begin)
	}
	selectors_skip_runes_reverse(b, &begin, begin_coord, selectors_pred_eol)
	end := begin
	with_end := selectors_skip_runes_reverse(b, &end, begin_coord, selectors_pred_hblank)
	last := selectors_rune_at(b, end)
	if unicode_is_word(last, data.extra, word_type) {
		with_end = selectors_skip_runes_reverse(b, &end, begin_coord, selectors_pred_word, &data)
	} else if unicode_is_punctuation(last, data.extra) {
		with_end = selectors_skip_runes_reverse(b, &end, begin_coord, selectors_pred_punct, &data)
	}
	if with_end {
		return selectors_selection(begin, end), true
	}
	return selectors_selection(begin, buffer_char_next(b, end)), true
}

// selectors_select_word selects the word under the cursor (port of
// select_word; count is unused in C++ too).
selectors_select_word :: proc(
	ctx: ^Context,
	sel: Selection,
	count: int,
	flags: Selectors_Object_Flags,
	word_type: Unicode_Word_Type,
) -> (
	Selection,
	bool,
) {
	_ = count
	b := context_buffer(ctx)
	extra := selectors_extra_word_chars(ctx)
	data := Selectors_Word_Data{extra = extra, word_type = word_type}
	end_coord := buffer_end_coord(b)
	first := sel.cursor.coord
	if !unicode_is_word(selectors_rune_at(b, first), extra, word_type) {
		return {}, false
	}
	last := first
	if .To_Begin in flags {
		selectors_skip_runes_reverse(b, &first, Coord_Buffer{0, 0}, selectors_pred_word, &data)
		if !unicode_is_word(selectors_rune_at(b, first), extra, word_type) {
			first = buffer_char_next(b, first)
		}
	}
	if .To_End in flags {
		selectors_skip_runes(b, &last, end_coord, selectors_pred_word, &data)
		if .Inner not_in flags {
			selectors_skip_runes(b, &last, end_coord, selectors_pred_hblank)
		}
		last = buffer_char_prev(b, last)
	}
	if .To_End in flags {
		return selectors_selection(first, last), true
	}
	return selectors_selection(last, first), true
}

// selectors_select_to_line_end extends (or, with only_move, moves) the
// cursor to the last character of the line (port of select_to_line_end).
selectors_select_to_line_end :: proc(ctx: ^Context, sel: Selection, only_move: bool) -> (Selection, bool) {
	b := context_buffer(ctx)
	begin := sel.cursor.coord
	line_text := b.lines[int(begin.line)]
	end := Coord_Buffer{begin.line, Units_ByteCount(len(line_text) - 1)}
	if end.column > 0 {
		end = buffer_char_prev(b, end)
	}
	if coord_compare(end, begin) < 0 {
		end = begin
	}
	anchor := end if only_move else begin
	return Selection{basic = Basic_Selection{anchor = anchor, cursor = coord_buffer_and_target(end, selection_MAX_NON_EOL_COLUMN)}}, true
}

// selectors_select_to_line_begin extends (or, with only_move, moves) the
// cursor to the first character of the line (port of select_to_line_begin).
selectors_select_to_line_begin :: proc(ctx: ^Context, sel: Selection, only_move: bool) -> (Selection, bool) {
	begin := sel.cursor.coord
	end := Coord_Buffer{begin.line, 0}
	anchor := end if only_move else begin
	return Selection{basic = Basic_Selection{anchor = anchor, cursor = coord_buffer_and_target(end)}}, true
}

// selectors_select_to_first_non_blank moves the cursor to the first
// non-blank character of the line (port of select_to_first_non_blank).
selectors_select_to_first_non_blank :: proc(ctx: ^Context, sel: Selection) -> (Selection, bool) {
	b := context_buffer(ctx)
	line := sel.cursor.coord.line
	it := Coord_Buffer{line, 0}
	selectors_skip_bytes(b, &it, Coord_Buffer{line + 1, 0}, selectors_pred_byte_hblank)
	return selectors_selection(it, it), true
}

// selectors_select_matching selects from the cursor to the character
// matching the one under (forward) or before (backward) the cursor
// (port of select_matching).
selectors_select_matching :: proc(ctx: ^Context, sel: Selection, forward: bool) -> (Selection, bool) {
	b := context_buffer(ctx)
	pairs := selectors_matching_pairs(ctx)
	end_coord := buffer_end_coord(b)
	begin_coord := Coord_Buffer{0, 0}
	it := sel.cursor.coord
	match := -1
	if forward {
		for it != end_coord {
			match = selectors_find_rune(pairs, selectors_rune_at(b, it))
			if match >= 0 {
				break
			}
			it = buffer_char_next(b, it)
		}
	} else {
		for {
			match = selectors_find_rune(pairs, selectors_rune_at(b, it))
			if match >= 0 || it == begin_coord {
				break
			}
			it = buffer_char_prev(b, it)
		}
	}
	if match < 0 {
		return {}, false
	}
	begin := it
	if match % 2 == 0 {
		if match + 1 >= len(pairs) {
			return {}, false
		}
		level := 0
		opening := pairs[match]
		closing := pairs[match + 1]
		for it != end_coord {
			cp := selectors_rune_at(b, it)
			if cp == opening {
				level += 1
			} else if cp == closing {
				level -= 1
				if level == 0 {
					return selectors_selection(begin, it), true
				}
			}
			it = buffer_char_next(b, it)
		}
	} else {
		level := 0
		opening := pairs[match - 1]
		closing := pairs[match]
		for {
			cp := selectors_rune_at(b, it)
			if cp == closing {
				level += 1
			} else if cp == opening {
				level -= 1
				if level == 0 {
					return selectors_selection(begin, it), true
				}
			}
			if it == begin_coord {
				break
			}
			it = buffer_char_prev(b, it)
		}
	}
	return {}, false
}

// selectors_select_to extends the cursor to the count-th occurrence of c
// (port of select_to).
selectors_select_to :: proc(ctx: ^Context, sel: Selection, c: rune, count: int, inclusive: bool) -> (Selection, bool) {
	b := context_buffer(ctx)
	end_coord := buffer_end_coord(b)
	begin := sel.cursor.coord
	end := begin
	target := c
	remaining := count
	for {
		end = buffer_char_next(b, end)
		if !selectors_skip_runes(b, &end, end_coord, selectors_pred_rune_neq, &target) {
			return {}, false
		}
		remaining -= 1
		if remaining <= 0 {
			break
		}
	}
	if inclusive {
		return selectors_selection(begin, end), true
	}
	return selectors_selection(begin, buffer_char_prev(b, end)), true
}

// selectors_select_to_reverse extends the cursor backward to the count-th
// occurrence of c (port of select_to_reverse).
selectors_select_to_reverse :: proc(ctx: ^Context, sel: Selection, c: rune, count: int, inclusive: bool) -> (Selection, bool) {
	b := context_buffer(ctx)
	begin_coord := Coord_Buffer{0, 0}
	if sel.cursor.coord == begin_coord {
		return {}, false
	}
	begin := sel.cursor.coord
	end := begin
	target := c
	remaining := count
	for {
		if end == begin_coord {
			return {}, false
		}
		end = buffer_char_prev(b, end)
		if selectors_skip_runes_reverse(b, &end, begin_coord, selectors_pred_rune_neq, &target) {
			return {}, false
		}
		remaining -= 1
		if remaining <= 0 {
			break
		}
	}
	if inclusive {
		return selectors_selection(begin, end), true
	}
	return selectors_selection(begin, buffer_char_next(b, end)), true
}

// selectors_select_number selects the number under the cursor (port of
// select_number; count is unused in C++ too).
selectors_select_number :: proc(ctx: ^Context, sel: Selection, count: int, flags: Selectors_Object_Flags) -> (Selection, bool) {
	_ = count
	b := context_buffer(ctx)
	inner := .Inner in flags
	end_coord := buffer_end_coord(b)
	begin_coord := Coord_Buffer{0, 0}
	first := sel.cursor.coord
	last := first
	if !selectors_pred_byte_number(buffer_byte_at(b, first), &inner) && buffer_byte_at(b, first) != '-' {
		return {}, false
	}
	if .To_Begin in flags {
		selectors_skip_bytes_reverse(b, &first, begin_coord, selectors_pred_byte_number, &inner)
		if !selectors_pred_byte_number(buffer_byte_at(b, first), &inner) &&
		   buffer_byte_at(b, first) != '-' &&
		   buffer_next(b, first) != end_coord {
			first = buffer_next(b, first)
		}
	}
	if .To_End in flags {
		if buffer_byte_at(b, last) == '-' {
			last = buffer_next(b, last)
		}
		selectors_skip_bytes(b, &last, end_coord, selectors_pred_byte_number, &inner)
		if last != begin_coord {
			last = buffer_prev(b, last)
		}
	}
	if .To_End in flags {
		return selectors_selection(first, last), true
	}
	return selectors_selection(last, first), true
}

// selectors_select_sentence selects count sentences around the cursor
// (port of select_sentence). A negative count selects none, like count 0
// (the C++ loop would leave last uninitialized there).
selectors_select_sentence :: proc(ctx: ^Context, sel: Selection, count: int, flags: Selectors_Object_Flags) -> (Selection, bool) {
	b := context_buffer(ctx)
	end_coord := buffer_end_coord(b)
	begin_coord := Coord_Buffer{0, 0}
	first := sel.cursor.coord
	last := first
	for i := 0; i <= max(count, 0); i += 1 {
		if .To_End not_in flags && first != begin_coord {
			prev := buffer_prev(b, first)
			selectors_skip_bytes_reverse(b, &prev, begin_coord, selectors_pred_byte_blank_or_eol)
			if selectors_byte_is_sentence_end(buffer_byte_at(b, prev)) {
				first = prev
			}
		}
		if i == 0 {
			last = first
		}
		if .To_Begin in flags {
			saw_non_blank := false
			for first != begin_coord {
				cur := buffer_byte_at(b, first)
				prev := buffer_byte_at(b, buffer_prev(b, first))
				if !unicode_is_horizontal_blank(rune(cur)) {
					saw_non_blank = true
				}
				if prev == '\n' && cur == '\n' && buffer_next(b, first) != end_coord {
					first = buffer_next(b, first)
					break
				} else if selectors_byte_is_sentence_end(prev) {
					if saw_non_blank {
						break
					} else if .To_End in flags {
						last = buffer_prev(b, first)
					}
				}
				first = buffer_prev(b, first)
			}
			selectors_skip_bytes(b, &first, end_coord, selectors_pred_byte_hblank)
		}
		if .To_End in flags {
			for last != end_coord {
				cur := buffer_byte_at(b, last)
				if selectors_byte_is_sentence_end(cur) {
					break
				}
				if cur == '\n' {
					next := buffer_next(b, last)
					if next == end_coord || buffer_byte_at(b, next) == '\n' {
						break
					}
				}
				last = buffer_next(b, last)
			}
			if .Inner not_in flags && last != end_coord {
				last = buffer_next(b, last)
				selectors_skip_bytes(b, &last, end_coord, selectors_pred_byte_hblank)
				last = buffer_prev(b, last)
			}
		}
	}
	if .To_End in flags {
		return selectors_selection(first, last), true
	}
	return selectors_selection(last, first), true
}

// selectors_select_paragraph selects count paragraphs around the cursor
// (port of select_paragraph). A negative count selects none, like
// count 0 (the C++ loop would leave last uninitialized there).
selectors_select_paragraph :: proc(ctx: ^Context, sel: Selection, count: int, flags: Selectors_Object_Flags) -> (Selection, bool) {
	b := context_buffer(ctx)
	end_coord := buffer_end_coord(b)
	begin_coord := Coord_Buffer{0, 0}
	first := sel.cursor.coord
	last := first
	for i := 0; i <= max(count, 0); i += 1 {
		if .To_End not_in flags &&
		   coord_compare(first, Coord_Buffer{0, 1}) > 0 &&
		   buffer_byte_at(b, buffer_prev(b, first)) == '\n' &&
		   buffer_prev(b, first) != begin_coord &&
		   buffer_byte_at(b, buffer_prev(b, buffer_prev(b, first))) == '\n' {
			first = buffer_prev(b, first)
		} else if .To_End in flags &&
			first != begin_coord &&
			buffer_next(b, first) != end_coord &&
			buffer_byte_at(b, buffer_prev(b, first)) == '\n' &&
			buffer_byte_at(b, first) == '\n' {
			first = buffer_next(b, first)
		}
		if i == 0 {
			last = first
		}
		if .To_Begin in flags && first != begin_coord {
			selectors_skip_bytes_reverse(b, &first, begin_coord, selectors_pred_byte_eol)
			if .To_End in flags {
				last = first
			}
			for first != begin_coord {
				cur := buffer_byte_at(b, first)
				prev := buffer_byte_at(b, buffer_prev(b, first))
				if prev == '\n' && cur == '\n' {
					first = buffer_next(b, first)
					break
				}
				first = buffer_prev(b, first)
			}
		}
		if .To_End in flags {
			if last != end_coord && buffer_byte_at(b, last) == '\n' {
				last = buffer_next(b, last)
			}
			for last != end_coord {
				if last != begin_coord && buffer_byte_at(b, last) == '\n' && buffer_byte_at(b, buffer_prev(b, last)) == '\n' {
					if .Inner not_in flags {
						selectors_skip_bytes(b, &last, end_coord, selectors_pred_byte_eol)
					}
					break
				}
				last = buffer_next(b, last)
			}
			last = buffer_prev(b, last)
		}
	}
	if .To_End in flags {
		return selectors_selection(first, last), true
	}
	return selectors_selection(last, first), true
}

// selectors_select_whitespaces selects the whitespace run under the
// cursor (port of select_whitespaces; count is unused in C++ too).
selectors_select_whitespaces :: proc(ctx: ^Context, sel: Selection, count: int, flags: Selectors_Object_Flags) -> (Selection, bool) {
	_ = count
	b := context_buffer(ctx)
	inner := .Inner in flags
	end_coord := buffer_end_coord(b)
	begin_coord := Coord_Buffer{0, 0}
	first := sel.cursor.coord
	last := first
	if !selectors_pred_byte_whitespace(buffer_byte_at(b, first), &inner) {
		return {}, false
	}
	if .To_Begin in flags && selectors_pred_byte_whitespace(buffer_byte_at(b, first), &inner) {
		selectors_skip_bytes_reverse(b, &first, begin_coord, selectors_pred_byte_whitespace, &inner)
		if !selectors_pred_byte_whitespace(buffer_byte_at(b, first), &inner) {
			first = buffer_next(b, first)
		}
	}
	if .To_End in flags && selectors_pred_byte_whitespace(buffer_byte_at(b, last), &inner) {
		selectors_skip_bytes(b, &last, end_coord, selectors_pred_byte_whitespace, &inner)
		last = buffer_prev(b, last)
	}
	if .To_End in flags {
		return selectors_selection(first, last), true
	}
	return selectors_selection(last, first), true
}

// selectors_indent_of_line returns the display indent of a buffer line
// (port of the get_indent lambda in select_indent).
selectors_indent_of_line :: proc(line: string, tabstop: int) -> int {
	indent := 0
	for i := 0; i < len(line); i += 1 {
		switch line[i] {
		case ' ':
			indent += 1
		case '\t':
			indent = (indent / max(tabstop, 1) + 1) * max(tabstop, 1)
		case:
			return indent
		}
	}
	return indent
}

// selectors_line_is_only_whitespace reports whether line holds only
// blanks (port of the is_only_whitespaces lambda in select_indent).
selectors_line_is_only_whitespace :: proc(line: string) -> bool {
	for i := 0; i < len(line); i += 1 {
		by := line[i]
		if by != ' ' && by != '\t' && by != '\n' {
			return false
		}
	}
	return true
}

// selectors_current_indent returns the indent of line, falling back to
// the nearest non-blank line above, then below (port of the
// get_current_indent lambda in select_indent).
selectors_current_indent :: proc(b: ^Buffer, line, tabstop: int) -> int {
	l := line
	for l >= 0 {
		if b.lines[l] != "\n" {
			return selectors_indent_of_line(b.lines[l], tabstop)
		}
		l -= 1
	}
	l = line + 1
	for l < len(b.lines) {
		if b.lines[l] != "\n" {
			return selectors_indent_of_line(b.lines[l], tabstop)
		}
		l += 1
	}
	return 0
}

// selectors_select_indent selects the block of lines indented at least as
// much as the cursor line (port of select_indent; count is unused in
// C++ too).
selectors_select_indent :: proc(ctx: ^Context, sel: Selection, count: int, flags: Selectors_Object_Flags) -> (Selection, bool) {
	_ = count
	b := context_buffer(ctx)
	tabstop := selectors_tabstop(ctx)
	pos := sel.cursor.coord
	line := int(pos.line)
	line_count := len(b.lines)
	indent := selectors_current_indent(b, line, tabstop)
	to_begin := .To_Begin in flags
	to_end := .To_End in flags
	begin_line := line - 1
	if to_begin {
		for begin_line >= 0 &&
		    (b.lines[begin_line] == "\n" || selectors_indent_of_line(b.lines[begin_line], tabstop) >= indent) {
			begin_line -= 1
		}
	}
	begin_line += 1
	end_line := line + 1
	if to_end {
		for end_line < line_count &&
		    (b.lines[end_line] == "\n" || selectors_indent_of_line(b.lines[end_line], tabstop) >= indent) {
			end_line += 1
		}
	}
	end_line -= 1
	if .Inner in flags {
		for begin_line < end_line && selectors_line_is_only_whitespace(b.lines[begin_line]) {
			begin_line += 1
		}
		for begin_line < end_line && selectors_line_is_only_whitespace(b.lines[end_line]) {
			end_line -= 1
		}
	}
	first := Coord_Buffer{Coord_Line(begin_line), 0} if to_begin else pos
	last := Coord_Buffer{Coord_Line(end_line), Units_ByteCount(len(b.lines[end_line]) - 1)} if to_end else pos
	if to_end {
		return selectors_selection(first, last), true
	}
	return selectors_selection(last, first), true
}

// Selectors_Argument_Class classifies bytes for argument selection.
Selectors_Argument_Class :: enum {
	None,
	Opening,
	Closing,
	Delimiter,
}

// selectors_classify_argument_byte classifies a byte as an argument
// delimiter, bracket, or plain text.
selectors_classify_argument_byte :: proc(by: byte) -> Selectors_Argument_Class {
	switch by {
	case '(', '[', '{':
		return .Opening
	case ')', ']', '}':
		return .Closing
	case ',', ';':
		return .Delimiter
	}
	return .None
}

// selectors_select_argument selects the function argument around the
// cursor at the given nesting level (port of select_argument). Guards
// against moving before the buffer start or skipping with inverted
// bounds, both undefined behavior in C++.
selectors_select_argument :: proc(ctx: ^Context, sel: Selection, level: int, flags: Selectors_Object_Flags) -> (Selection, bool) {
	b := context_buffer(ctx)
	end_coord := buffer_end_coord(b)
	begin_coord := Coord_Buffer{0, 0}
	pos := sel.cursor.coord
	switch selectors_classify_argument_byte(buffer_byte_at(b, pos)) {
	case .Opening, .Delimiter:
		if pos != begin_coord {
			pos = buffer_prev(b, pos)
		}
	case .Closing, .None:
	}
	first_arg := false
	begin := pos
	lev := level
	for begin != begin_coord {
		cls := selectors_classify_argument_byte(buffer_byte_at(b, begin))
		if cls == .Closing {
			lev += 1
		} else if cls == .Opening && lev == 0 {
			first_arg = true
			begin = buffer_next(b, begin)
			break
		} else if cls == .Opening {
			lev -= 1
		} else if cls == .Delimiter && lev == 0 {
			begin = buffer_next(b, begin)
			break
		}
		begin = buffer_prev(b, begin)
	}
	last_arg := false
	end := pos
	lev = level
	for end != end_coord {
		cls := selectors_classify_argument_byte(buffer_byte_at(b, end))
		if cls == .Opening {
			lev += 1
		} else if end != pos && cls == .Closing && lev == 0 {
			last_arg = true
			end = buffer_prev(b, end)
			break
		} else if end != pos && cls == .Closing {
			lev -= 1
		} else if cls == .Delimiter && lev == 0 {
			if first_arg && .Inner not_in flags {
				for buffer_next(b, end) != end_coord && unicode_is_blank(rune(buffer_byte_at(b, buffer_next(b, end)))) {
					end = buffer_next(b, end)
				}
			}
			break
		}
		end = buffer_next(b, end)
	}
	if .Inner in flags {
		if !last_arg && end != begin_coord {
			end = buffer_prev(b, end)
		}
		if coord_compare(begin, end) <= 0 {
			selectors_skip_bytes(b, &begin, end, selectors_pred_byte_blank)
			selectors_skip_bytes_reverse(b, &end, begin, selectors_pred_byte_blank)
		}
	} else if !first_arg && last_arg && begin != begin_coord {
		begin = buffer_prev(b, begin)
	}
	if end == end_coord {
		end = buffer_prev(b, end)
	}
	if .To_Begin in flags && .To_End not_in flags {
		return selectors_selection(pos, begin), true
	}
	begin_or_pos := begin if .To_Begin in flags else pos
	return selectors_selection(begin_or_pos, end), true
}

// selectors_nothing_selected_or returns res when non-empty, else frees it
// and reports Nothing_Selected (port of the for_each_sel tail).
selectors_nothing_selected_or :: proc(res: [dynamic]Selection) -> ([dynamic]Selection, Selectors_Error) {
	if len(res) == 0 {
		delete(res)
		return nil, .Nothing_Selected
	}
	return res, .None
}

// selectors_select_nested_words selects the words inside each selection
// (port of select_nested_words; count is unused in C++ too).
selectors_select_nested_words :: proc(
	ctx: ^Context,
	count: int,
	flags: Selectors_Object_Flags,
	word_type: Unicode_Word_Type,
	allocator := context.allocator,
) -> (
	[dynamic]Selection,
	Selectors_Error,
) {
	_ = count
	b := context_buffer(ctx)
	data := Selectors_Word_Data{extra = selectors_extra_word_chars(ctx), word_type = word_type}
	inner := .Inner in flags
	res := make([dynamic]Selection, 0, allocator)
	for sel in context_selections(ctx).selections {
		sel_end := buffer_char_next(b, selection_basic_max(sel.basic))
		it := selection_basic_min(sel.basic)
		for it != sel_end {
			if !selectors_skip_runes(b, &it, sel_end, selectors_pred_not_word, &data) {
				break
			}
			start := it
			selectors_skip_runes(b, &it, sel_end, selectors_pred_word, &data)
			if !inner {
				selectors_skip_runes(b, &it, sel_end, selectors_pred_hblank)
			}
			append(&res, selectors_selection(start, buffer_char_prev(b, it)))
		}
	}
	return selectors_nothing_selected_or(res)
}

// selectors_select_nested_numbers selects the numbers inside each
// selection (port of select_nested_numbers; count is unused in C++ too).
selectors_select_nested_numbers :: proc(ctx: ^Context, count: int, flags: Selectors_Object_Flags, allocator := context.allocator) -> ([dynamic]Selection, Selectors_Error) {
	_ = count
	b := context_buffer(ctx)
	inner := .Inner in flags
	res := make([dynamic]Selection, 0, allocator)
	for sel in context_selections(ctx).selections {
		sel_end := buffer_char_next(b, selection_basic_max(sel.basic))
		it := selection_basic_min(sel.basic)
		for it != sel_end {
			if !selectors_skip_bytes(b, &it, sel_end, selectors_pred_byte_not_number_start, &inner) {
				break
			}
			start := it
			if buffer_byte_at(b, it) == '-' {
				it = buffer_next(b, it)
			}
			selectors_skip_bytes(b, &it, sel_end, selectors_pred_byte_number, &inner)
			if it == start {
				it = buffer_next(b, it)
			} else {
				has_digit := false
				d := start
				for d != it {
					if selectors_pred_byte_digit(buffer_byte_at(b, d), nil) {
						has_digit = true
						break
					}
					d = buffer_next(b, d)
				}
				if has_digit {
					append(&res, selectors_selection(start, buffer_char_prev(b, it)))
				}
			}
		}
	}
	return selectors_nothing_selected_or(res)
}

// selectors_select_nested_sentences selects the sentences inside each
// selection (port of select_nested_sentences; count is unused in C++ too).
selectors_select_nested_sentences :: proc(ctx: ^Context, count: int, flags: Selectors_Object_Flags, allocator := context.allocator) -> ([dynamic]Selection, Selectors_Error) {
	_ = count
	b := context_buffer(ctx)
	inner := .Inner in flags
	res := make([dynamic]Selection, 0, allocator)
	for sel in context_selections(ctx).selections {
		sel_end := buffer_char_next(b, selection_basic_max(sel.basic))
		it := selection_basic_min(sel.basic)
		for it != sel_end {
			if !selectors_skip_bytes(b, &it, sel_end, selectors_pred_byte_space_nl_tab) {
				break
			}
			start := it
			for it != sel_end && !selectors_byte_is_sentence_end(buffer_byte_at(b, it)) {
				it = buffer_next(b, it)
			}
			if it != sel_end {
				it = buffer_next(b, it)
				if !inner {
					selectors_skip_bytes(b, &it, sel_end, selectors_pred_byte_space_only)
				}
			}
			append(&res, selectors_selection(start, buffer_char_prev(b, it)))
		}
	}
	return selectors_nothing_selected_or(res)
}

// selectors_select_nested_paragraphs selects the paragraphs inside each
// selection (port of select_nested_paragraphs; count is unused in C++ too).
selectors_select_nested_paragraphs :: proc(ctx: ^Context, count: int, flags: Selectors_Object_Flags, allocator := context.allocator) -> ([dynamic]Selection, Selectors_Error) {
	_ = count
	b := context_buffer(ctx)
	inner := .Inner in flags
	res := make([dynamic]Selection, 0, allocator)
	for sel in context_selections(ctx).selections {
		sel_end := buffer_char_next(b, selection_basic_max(sel.basic))
		it := selection_basic_min(sel.basic)
		for it != sel_end {
			start := it
			for start != sel_end && buffer_byte_at(b, start) == '\n' {
				start = buffer_next(b, start)
			}
			consecutive_eols := 0
			it = start
			for it != sel_end {
				if buffer_byte_at(b, it) == '\n' {
					consecutive_eols += 1
					if consecutive_eols == 2 && inner {
						break
					}
				} else if consecutive_eols >= 2 {
					break
				} else {
					consecutive_eols = 0
				}
				it = buffer_next(b, it)
			}
			append(&res, selectors_selection(start, buffer_char_prev(b, it)))
		}
	}
	return selectors_nothing_selected_or(res)
}

// selectors_select_nested_whitespaces selects the whitespace runs inside
// each selection (port of select_nested_whitespaces; count is unused in
// C++ too).
selectors_select_nested_whitespaces :: proc(ctx: ^Context, count: int, flags: Selectors_Object_Flags, allocator := context.allocator) -> ([dynamic]Selection, Selectors_Error) {
	_ = count
	b := context_buffer(ctx)
	inner := .Inner in flags
	res := make([dynamic]Selection, 0, allocator)
	for sel in context_selections(ctx).selections {
		sel_end := buffer_char_next(b, selection_basic_max(sel.basic))
		it := selection_basic_min(sel.basic)
		for it != sel_end {
			if !selectors_skip_bytes(b, &it, sel_end, selectors_pred_byte_not_whitespace, &inner) {
				break
			}
			start := it
			selectors_skip_bytes(b, &it, sel_end, selectors_pred_byte_whitespace, &inner)
			append(&res, selectors_selection(start, buffer_char_prev(b, it)))
		}
	}
	return selectors_nothing_selected_or(res)
}

// selectors_select_nested_indents is unimplemented in C++ too (it throws),
// so it reports Not_Implemented.
selectors_select_nested_indents :: proc(ctx: ^Context, count: int, flags: Selectors_Object_Flags, allocator := context.allocator) -> ([dynamic]Selection, Selectors_Error) {
	_ = ctx
	_ = count
	_ = flags
	_ = allocator
	return nil, .Not_Implemented
}

// selectors_select_nested_arguments selects the comma-separated arguments
// inside each selection (port of select_nested_arguments; count is unused
// in C++ too). An empty inner segment at the buffer start selects nothing
// (char_prev there is undefined behavior in C++).
selectors_select_nested_arguments :: proc(ctx: ^Context, count: int, flags: Selectors_Object_Flags, allocator := context.allocator) -> ([dynamic]Selection, Selectors_Error) {
	_ = count
	b := context_buffer(ctx)
	inner := .Inner in flags
	res := make([dynamic]Selection, 0, allocator)
	for sel in context_selections(ctx).selections {
		sel_end := buffer_char_next(b, selection_basic_max(sel.basic))
		it := selection_basic_min(sel.basic)
		start := it
		level := 0
		for it != sel_end {
			switch buffer_byte_at(b, it) {
			case '(', '[', '{':
				level += 1
				it = buffer_next(b, it)
			case ')', ']', '}':
				level -= 1
				it = buffer_next(b, it)
			case ',', ';':
				if level == 0 {
					empty_at_start := inner && it == start && it == Coord_Buffer{0, 0}
					if !empty_at_start {
						end_c := buffer_char_prev(b, it) if inner else it
						append(&res, selectors_selection(start, end_c))
					}
					it = buffer_next(b, it)
					for inner && it != sel_end && selectors_pred_byte_space_nl_tab(buffer_byte_at(b, it), nil) {
						it = buffer_next(b, it)
					}
					start = it
				} else {
					it = buffer_next(b, it)
				}
			case:
				it = buffer_next(b, it)
			}
		}
		if start != it {
			append(&res, selectors_selection(start, buffer_char_prev(b, it)))
		}
	}
	return selectors_nothing_selected_or(res)
}

// selectors_find_opening_text finds the opening match enclosing pos in
// subject, skipping level nested pairs (port of find_opening). Returns
// the match byte offsets.
selectors_find_opening_text :: proc(
	subject: string,
	pos: int,
	opening, closing: ^Regex,
	level: int,
	nestable: bool,
	allocator := context.allocator,
) -> (
	first, second: int,
	ok: bool,
) {
	p := pos
	if nestable {
		res, matched := regex_backward_search(subject, 0, p, closing, {}, allocator)
		defer regex_match_results_destroy(&res)
		if matched {
			m := regex_match_results_get(&res, 0)
			if m.matched && m.end == p {
				p = m.begin
			}
		}
	}
	it := regex_iterator_make(subject, 0, p, opening, {}, true, allocator)
	defer regex_iterator_destroy(&it)
	lev := level
	cur := p
	for regex_iterator_next(&it) {
		m := regex_match_results_get(&it.results, 0)
		if nestable {
			inner := regex_iterator_make(subject, m.end, cur, closing, {}, true, allocator)
			for regex_iterator_next(&inner) {
				lev += 1
			}
			regex_iterator_destroy(&inner)
		}
		if !nestable || lev == 0 {
			return m.begin, m.end, true
		}
		cur = m.begin
		lev -= 1
	}
	return 0, 0, false
}

// selectors_find_closing_text finds the closing match enclosing pos in
// subject, skipping level nested pairs (port of find_closing). Returns
// the match byte offsets.
selectors_find_closing_text :: proc(
	subject: string,
	pos: int,
	opening, closing: ^Regex,
	level: int,
	nestable: bool,
	allocator := context.allocator,
) -> (
	first, second: int,
	ok: bool,
) {
	it := regex_iterator_make(subject, pos, len(subject), closing, {}, false, allocator)
	defer regex_iterator_destroy(&it)
	lev := level
	cur := pos
	for regex_iterator_next(&it) {
		m := regex_match_results_get(&it.results, 0)
		if nestable {
			inner := regex_iterator_make(subject, cur, m.begin, opening, {}, false, allocator)
			for regex_iterator_next(&inner) {
				lev += 1
			}
			regex_iterator_destroy(&inner)
		}
		if !nestable || lev == 0 {
			return m.begin, m.end, true
		}
		cur = m.end
		lev -= 1
	}
	return 0, 0, false
}

// selectors_utf8_prev_offset returns the start of the codepoint ending at
// (or before) off, bounded below by 0 (port of utf8::previous at the
// byte-offset level).
selectors_utf8_prev_offset :: proc(subject: string, off: int) -> int {
	if off <= 0 {
		return 0
	}
	return utf8_previous(subject, off)
}

// selectors_find_surrounding_text finds the block delimited by opening
// and closing around pos in subject (port of find_surrounding over a
// string, which is also what the C++ UnitTest exercises). Returns the
// selected byte range [first, last].
selectors_find_surrounding_text :: proc(
	subject: string,
	pos: int,
	opening, closing: ^Regex,
	flags: Selectors_Object_Flags,
	level: int,
	allocator := context.allocator,
) -> (
	first, last: int,
	ok: bool,
) {
	nestable := opening.pattern != closing.pattern
	first = pos
	last = pos
	lev := level
	if .To_Begin in flags {
		back := min(pos + 1, len(subject))
		of, os, ook := selectors_find_opening_text(subject, back, opening, closing, lev, nestable, allocator)
		if !ook {
			return 0, 0, false
		}
		first = os if .Inner in flags else of
		if .To_End in flags {
			last = min(os + 1, len(subject)) if of == os else os
			lev = 0
		}
	} else {
		res, matched := regex_search(subject, pos, len(subject), opening, {}, allocator)
		defer regex_match_results_destroy(&res)
		if matched {
			m := regex_match_results_get(&res, 0)
			if m.matched && m.begin == pos {
				last = min(m.end + 1, len(subject)) if m.begin == m.end else m.end
			}
		}
	}
	if .To_End in flags {
		cf, cs, cok := selectors_find_closing_text(subject, last, opening, closing, lev, nestable, allocator)
		if !cok {
			return 0, 0, false
		}
		target := cf if .Inner in flags else cs
		last = selectors_utf8_prev_offset(subject, target)
	}
	if first > last {
		return 0, 0, false
	}
	return first, last, true
}

// selectors_select_surrounding selects the block delimited by opening
// and closing around the cursor (port of select_surrounding). When the
// found block equals the current selection it selects the parent instead.
selectors_select_surrounding :: proc(
	ctx: ^Context,
	sel: Selection,
	opening, closing: ^Regex,
	level: int,
	flags: Selectors_Object_Flags,
	allocator := context.allocator,
) -> (
	Selection,
	bool,
) {
	b := context_buffer(ctx)
	text := buffer_string(b, Coord_Buffer{0, 0}, buffer_end_coord(b), allocator)
	defer delete(text, allocator)
	pos := selectors_offset_of_coord(b, sel.cursor.coord)
	sel_min := selection_basic_min(sel.basic)
	sel_max := selection_basic_max(sel.basic)
	first, last, ok := selectors_find_surrounding_text(text, pos, opening, closing, flags, level, allocator)
	if ok && .Inner not_in flags {
		first_c := selectors_coord_of_offset(b, first)
		last_c := selectors_coord_of_offset(b, last)
		if (first_c == sel_min || .To_Begin not_in flags) && (last_c == sel_max || .To_End not_in flags) {
			first, last, ok = selectors_find_surrounding_text(text, pos, opening, closing, flags, level + 1, allocator)
		}
	}
	if !ok {
		return {}, false
	}
	first_c := selectors_coord_of_offset(b, first)
	last_c := selectors_coord_of_offset(b, last)
	if .To_End in flags {
		return selectors_selection(first_c, last_c), true
	}
	return selectors_selection(last_c, first_c), true
}

// selectors_regex_select_nested selects the blocks delimited by the
// opening/closing pair inside each selection (port of the pair overload
// of regex_select_nested; level counts the nesting depth to skip).
selectors_regex_select_nested :: proc(
	ctx: ^Context,
	opening, closing: ^Regex,
	level: int,
	flags: Selectors_Object_Flags,
	allocator := context.allocator,
) -> (
	[dynamic]Selection,
	Selectors_Error,
) {
	b := context_buffer(ctx)
	inner := .Inner in flags
	text := buffer_string(b, Coord_Buffer{0, 0}, buffer_end_coord(b), allocator)
	defer delete(text, allocator)
	res := make([dynamic]Selection, 0, allocator)
	for sel in context_selections(ctx).selections {
		beg := selectors_offset_of_coord(b, selection_basic_min(sel.basic))
		end := selectors_offset_of_coord(b, buffer_char_next(b, selection_basic_max(sel.basic)))
		open_it := regex_iterator_make(text, beg, end, opening, {}, false, allocator)
		close_it := regex_iterator_make(text, beg, end, closing, {}, false, allocator)
		have_open := regex_iterator_next(&open_it)
		have_close := regex_iterator_next(&close_it)
		have_start := false
		start_c: Coord_Buffer
		lev := -level - 1
		for have_open && have_close {
			for have_open && (!have_close || regex_match_results_get(&open_it.results, 0).begin < regex_match_results_get(&close_it.results, 0).begin) {
				lev += 1
				if lev == 0 {
					m := regex_match_results_get(&open_it.results, 0)
					start_c = selectors_coord_of_offset(b, m.end if inner else m.begin)
					have_start = true
				}
				have_open = regex_iterator_next(&open_it)
			}
			for have_close && (!have_open || regex_match_results_get(&close_it.results, 0).begin < regex_match_results_get(&open_it.results, 0).begin) {
				if lev == 0 && have_start {
					m := regex_match_results_get(&close_it.results, 0)
					close_off := m.begin if inner else m.end
					if close_off > 0 {
						end_c := buffer_char_prev(b, selectors_coord_of_offset(b, close_off))
						if coord_compare(start_c, end_c) <= 0 {
							append(&res, selectors_selection(start_c, end_c))
						}
					}
					have_start = false
				}
				lev -= 1
				have_close = regex_iterator_next(&close_it)
			}
		}
		if have_start {
			append(&res, selectors_selection(start_c, buffer_char_prev(b, selectors_coord_of_offset(b, end))))
		}
		regex_iterator_destroy(&open_it)
		regex_iterator_destroy(&close_it)
	}
	return selectors_nothing_selected_or(res)
}

// selectors_regex_select_nested_delim selects the blocks between
// delimiter matches inside each selection (port of the delimiter
// overload of regex_select_nested).
selectors_regex_select_nested_delim :: proc(
	ctx: ^Context,
	delimiter: ^Regex,
	flags: Selectors_Object_Flags,
	allocator := context.allocator,
) -> (
	[dynamic]Selection,
	Selectors_Error,
) {
	b := context_buffer(ctx)
	inner := .Inner in flags
	text := buffer_string(b, Coord_Buffer{0, 0}, buffer_end_coord(b), allocator)
	defer delete(text, allocator)
	res := make([dynamic]Selection, 0, allocator)
	for sel in context_selections(ctx).selections {
		beg := selectors_offset_of_coord(b, selection_basic_min(sel.basic))
		end := selectors_offset_of_coord(b, buffer_char_next(b, selection_basic_max(sel.basic)))
		it := regex_iterator_make(text, beg, end, delimiter, {}, false, allocator)
		have_start := false
		start_c: Coord_Buffer
		for regex_iterator_next(&it) {
			m := regex_match_results_get(&it.results, 0)
			if !have_start {
				start_c = selectors_coord_of_offset(b, m.end if inner else m.begin)
				have_start = true
			} else {
				close_off := m.begin if inner else m.end
				if close_off > 0 {
					end_c := buffer_char_prev(b, selectors_coord_of_offset(b, close_off))
					if coord_compare(start_c, end_c) <= 0 {
						append(&res, selectors_selection(start_c, end_c))
					}
				}
				have_start = false
			}
		}
		if have_start {
			append(&res, selectors_selection(start_c, buffer_char_prev(b, selectors_coord_of_offset(b, end))))
		}
		regex_iterator_destroy(&it)
	}
	return selectors_nothing_selected_or(res)
}

// selectors_select_lines extends the selection to full lines (port of
// select_lines).
selectors_select_lines :: proc(ctx: ^Context, sel: Selection) -> (Selection, bool) {
	b := context_buffer(ctx)
	anchor := sel.anchor
	cursor := sel.cursor.coord
	if coord_compare(anchor, cursor) <= 0 {
		anchor.column = 0
		cursor.column = Units_ByteCount(len(b.lines[int(cursor.line)]) - 1)
	} else {
		cursor.column = 0
		anchor.column = Units_ByteCount(len(b.lines[int(anchor.line)]) - 1)
	}
	return Selection{basic = Basic_Selection{anchor = anchor, cursor = coord_buffer_and_target(cursor, selection_MAX_COLUMN)}}, true
}

// selectors_trim_partial_lines trims partial first/last lines from the
// selection (port of trim_partial_lines).
selectors_trim_partial_lines :: proc(ctx: ^Context, sel: Selection) -> (Selection, bool) {
	b := context_buffer(ctx)
	anchor := sel.anchor
	cursor := sel.cursor.coord
	forward := coord_compare(anchor, cursor) <= 0
	line_start := anchor if forward else cursor
	line_end := cursor if forward else anchor
	if line_start.column != 0 {
		line_start = Coord_Buffer{line_start.line + 1, 0}
	}
	if line_end.column != Units_ByteCount(len(b.lines[int(line_end.line)]) - 1) {
		if line_end.line == 0 {
			return {}, false
		}
		prev_line := line_end.line - 1
		line_end = Coord_Buffer{prev_line, Units_ByteCount(len(b.lines[int(prev_line)]) - 1)}
	}
	if coord_compare(line_start, line_end) > 0 {
		return {}, false
	}
	if forward {
		anchor, cursor = line_start, line_end
	} else {
		anchor, cursor = line_end, line_start
	}
	return Selection{basic = Basic_Selection{anchor = anchor, cursor = coord_buffer_and_target(cursor, selection_MAX_COLUMN)}}, true
}

// selectors_clone_captures clones every capture group of res over subject
// (unmatched groups become ""); the caller frees them with
// selection_destroy in allocator.
selectors_clone_captures :: proc(res: ^Regex_Match_Results, subject: string, allocator := context.allocator) -> [dynamic]string {
	captures := make([dynamic]string, 0, regex_match_results_size(res), allocator)
	for i in 0 ..< regex_match_results_size(res) {
		m := regex_match_results_get(res, i)
		if m.matched {
			append(&captures, strings.clone(subject[m.begin:m.end], allocator))
		} else {
			append(&captures, "")
		}
	}
	return captures
}

// selectors_find_next_match finds the next match of re after (forward)
// or before (backward) the selection, wrapping once around the buffer
// (port of find_next_match). The regex must be compiled for the search
// direction (with .Backward for backward search), like in C++.
selectors_find_next_match :: proc(
	ctx: ^Context,
	sel: Selection,
	re: ^Regex,
	forward: bool,
	allocator := context.allocator,
) -> (
	Selection,
	bool,
	Selectors_Error,
) {
	b := context_buffer(ctx)
	begin_coord := Coord_Buffer{0, 0}
	end_coord := buffer_end_coord(b)
	text := buffer_string(b, begin_coord, end_coord, allocator)
	defer delete(text, allocator)
	wrapped := false
	found := false
	res := regex_match_results_make(allocator)
	defer regex_match_results_destroy(&res)
	if forward {
		start := buffer_char_next(b, selection_basic_max(sel.basic))
		if start != end_coord {
			start_off := selectors_offset_of_coord(b, start)
			r, matched := regex_search(text, start_off, len(text), re, selectors_match_flags(b, start, end_coord), allocator)
			regex_match_results_destroy(&res)
			res = r
			found = matched
		}
		if !found {
			wrapped = true
			r, matched := regex_search(text, 0, len(text), re, selectors_match_flags(b, begin_coord, end_coord), allocator)
			regex_match_results_destroy(&res)
			res = r
			found = matched
		}
	} else {
		start := selection_basic_min(sel.basic)
		if start != begin_coord {
			start_off := selectors_offset_of_coord(b, start)
			flags := selectors_match_flags(b, begin_coord, start)
			flags += {.Not_Initial_Null}
			r, matched := regex_backward_search(text, 0, start_off, re, flags, allocator)
			regex_match_results_destroy(&res)
			res = r
			found = matched
		}
		if !found {
			wrapped = true
			flags := selectors_match_flags(b, begin_coord, end_coord)
			flags += {.Not_Initial_Null}
			r, matched := regex_backward_search(text, 0, len(text), re, flags, allocator)
			regex_match_results_destroy(&res)
			res = r
			found = matched
		}
	}
	if !found {
		return {}, wrapped, .No_Match
	}
	m0 := regex_match_results_get(&res, 0)
	if !m0.matched || m0.begin == len(text) {
		return {}, wrapped, .No_Match
	}
	begin_c := selectors_coord_of_offset(b, m0.begin)
	end_c := selectors_coord_of_offset(b, m0.end)
	if m0.begin != m0.end {
		end_c = buffer_char_prev(b, end_c)
	}
	if !forward {
		begin_c, end_c = end_c, begin_c
	}
	return Selection {
		basic = Basic_Selection{anchor = begin_c, cursor = coord_buffer_and_target(end_c)},
		captures = selectors_clone_captures(&res, text, allocator),
	}, wrapped, .None
}

// selectors_select_matches selects capture_idx of every match of re
// inside the selections (port of select_matches). Results are sorted;
// the caller frees captures with selection_destroy.
selectors_select_matches :: proc(
	buffer: ^Buffer,
	sels: []Selection,
	re: ^Regex,
	capture_idx := 0,
	allocator := context.allocator,
) -> (
	[dynamic]Selection,
	Selectors_Error,
) {
	if capture_idx < 0 || capture_idx > regex_mark_count(re) {
		return nil, .Invalid_Capture
	}
	text := buffer_string(buffer, Coord_Buffer{0, 0}, buffer_end_coord(buffer), allocator)
	defer delete(text, allocator)
	res := make([dynamic]Selection, 0, allocator)
	for sel in sels {
		sel_min := selection_basic_min(sel.basic)
		sel_end := buffer_char_next(buffer, selection_basic_max(sel.basic))
		beg := selectors_offset_of_coord(buffer, sel_min)
		end := selectors_offset_of_coord(buffer, sel_end)
		it := regex_iterator_make(text, beg, end, re, selectors_match_flags(buffer, sel_min, sel_end), false, allocator)
		for regex_iterator_next(&it) {
			cap := regex_match_results_get(&it.results, capture_idx)
			if !cap.matched || cap.begin == end {
				continue
			}
			begin_c := selectors_coord_of_offset(buffer, cap.begin)
			end_c := selectors_coord_of_offset(buffer, cap.end)
			if cap.begin != cap.end {
				end_c = buffer_char_prev(buffer, end_c)
			}
			cand := Selection {
				basic = Basic_Selection{anchor = begin_c, cursor = coord_buffer_and_target(end_c)},
				captures = selectors_clone_captures(&it.results, text, allocator),
			}
			append(&res, selectors_keep_direction(cand, sel))
		}
		regex_iterator_destroy(&it)
	}
	if len(res) == 0 {
		delete(res)
		return nil, .Nothing_Selected
	}
	slice.sort_by(res[:], selection_compare)
	return res, .None
}

// selectors_split_on_matches splits the selections on capture_idx of
// every match of re (port of split_on_matches).
selectors_split_on_matches :: proc(
	buffer: ^Buffer,
	sels: []Selection,
	re: ^Regex,
	capture_idx := 0,
	allocator := context.allocator,
) -> (
	[dynamic]Selection,
	Selectors_Error,
) {
	if capture_idx < 0 || capture_idx > regex_mark_count(re) {
		return nil, .Invalid_Capture
	}
	end_coord := buffer_end_coord(buffer)
	text := buffer_string(buffer, Coord_Buffer{0, 0}, end_coord, allocator)
	defer delete(text, allocator)
	res := make([dynamic]Selection, 0, allocator)
	for sel in sels {
		sel_min := selection_basic_min(sel.basic)
		sel_max := selection_basic_max(sel.basic)
		sel_end := buffer_char_next(buffer, sel_max)
		beg := selectors_offset_of_coord(buffer, sel_min)
		end := selectors_offset_of_coord(buffer, sel_end)
		it := regex_iterator_make(text, beg, end, re, selectors_match_flags(buffer, sel_min, sel_end), false, allocator)
		begin_off := beg
		for regex_iterator_next(&it) {
			cap := regex_match_results_get(&it.results, capture_idx)
			if !cap.matched || cap.begin == len(text) {
				continue
			}
			if cap.begin != beg {
				begin_c := selectors_coord_of_offset(buffer, begin_off)
				end_c := selectors_coord_of_offset(buffer, cap.begin)
				if begin_off != cap.begin {
					end_c = buffer_char_prev(buffer, end_c)
				}
				append(&res, selectors_keep_direction(selectors_selection(begin_c, end_c), sel))
			}
			begin_off = cap.end
		}
		regex_iterator_destroy(&it)
		if coord_compare(selectors_coord_of_offset(buffer, begin_off), sel_max) <= 0 {
			append(&res, selectors_keep_direction(selectors_selection(selectors_coord_of_offset(buffer, begin_off), sel_max), sel))
		}
	}
	return selectors_nothing_selected_or(res)
}
