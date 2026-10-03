// Tests for selectors.odin (port of src/selectors.{hh,cc}).
//
// The C++ UnitTest test_find_surrounding is ported 1:1 first
// (test_selectors_find_surrounding); the rest cover every selector from
// the header/cc semantics plus edge cases (empty buffer, single char,
// counts, object flags, allocator cleanup).
package kak

import "core:mem"
import "core:strings"
import "core:testing"

// selectors_test_sel builds a capture-less selection.
selectors_test_sel :: proc(anchor, cursor: Coord_Buffer) -> Selection {
	return Selection{basic = Basic_Selection{anchor = anchor, cursor = coord_buffer_and_target(cursor)}}
}

// selectors_test_buffer builds a scratch buffer; tests free it with
// buffer_destroy (usually via defer).
selectors_test_buffer :: proc(lines: []string) -> ^Buffer {
	return buffer_make("test", Buffer_Flags{}, lines, .None, .Lf, .Present, File_Fs_Status{timestamp = File_Invalid_Time})
}

// selectors_test_set_runes_option installs a [dynamic]rune option on the
// buffer scope; selectors_test_clear_options frees it.
selectors_test_set_runes_option :: proc(b: ^Buffer, name: string, runes: []rune) {
	mgr := &b.scope.data.options
	desc := new(Option_Desc, b.allocator)
	desc^ = Option_Desc{name = name}
	val := make([dynamic]rune, len(runes), b.allocator)
	copy(val[:], runes)
	opt := new(Option, b.allocator)
	opt^ = Option{desc = desc, manager = mgr, value = val, allocator = b.allocator}
	mgr.options[name] = opt
}

// selectors_test_set_int_option installs an int option on the buffer scope.
selectors_test_set_int_option :: proc(b: ^Buffer, name: string, v: int) {
	mgr := &b.scope.data.options
	desc := new(Option_Desc, b.allocator)
	desc^ = Option_Desc{name = name}
	opt := new(Option, b.allocator)
	opt^ = Option{desc = desc, manager = mgr, value = v, allocator = b.allocator}
	mgr.options[name] = opt
}

// selectors_test_clear_options frees options installed by the setters
// above (buffer_destroy only drops the map itself).
selectors_test_clear_options :: proc(b: ^Buffer) {
	mgr := &b.scope.data.options
	for _, opt in mgr.options {
		desc := opt.desc
		option_manager_option_destroy(opt)
		free(desc, b.allocator)
	}
	clear(&mgr.options)
}

// selectors_test_ctx builds a context over b with the given selections;
// tests free it with context_destroy.
selectors_test_ctx :: proc(b: ^Buffer, sels: []Selection) -> Context {
	list := selection_list_make(b, sels, buffer_timestamp(b), context.allocator)
	ctx: Context
	context_init(&ctx, nil, list, {}, "", context.allocator)
	selection_list_destroy(&list)
	return ctx
}

// selectors_test_regex compiles pattern for both search directions;
// tests free it with regex_destroy.
selectors_test_regex :: proc(t: ^testing.T, pattern: string) -> Regex {
	re, msg, err := regex_make(pattern, {.Backward})
	defer delete(msg)
	testing.expect_value(t, err, Regex_Error.None)
	return re
}

// selectors_test_free_all frees a result array including captures.
selectors_test_free_all :: proc(res: ^[dynamic]Selection, allocator := context.allocator) {
	for &sel in res {
		selection_destroy(&sel, allocator)
	}
	delete(res^)
}

// selectors_test_endpoints asserts the anchor/cursor of got.
selectors_test_endpoints :: proc(t: ^testing.T, got: Selection, anchor, cursor: Coord_Buffer) {
	testing.expect_value(t, got.anchor, anchor)
	testing.expect_value(t, got.cursor.coord, cursor)
}

// Port of the C++ UnitTest test_find_surrounding, assertion for
// assertion: find_surrounding over a plain string.
@(test)
test_selectors_find_surrounding :: proc(t: ^testing.T) {
	check_equal :: proc(t: ^testing.T, s: string, pos: int, opening, closing: string, flags: Selectors_Object_Flags, level: int, expected: string) {
		open_pat := strings.concatenate({"\\Q", opening})
		defer delete(open_pat)
		close_pat := strings.concatenate({"\\Q", closing})
		defer delete(close_pat)
		open_re := selectors_test_regex(t, open_pat)
		defer regex_destroy(&open_re)
		close_re := selectors_test_regex(t, close_pat)
		defer regex_destroy(&close_re)
		first, last, ok := selectors_find_surrounding_text(s, pos, &open_re, &close_re, flags, level)
		testing.expect_value(t, !ok, len(expected) == 0)
		if !ok {
			return
		}
		testing.expect_value(t, s[first:last + 1], expected)
	}

	s := "{foo [bar { baz[] }]}"
	check_equal(t, s, 13, "{", "}", {.To_Begin, .To_End}, 0, "{ baz[] }")
	check_equal(t, s, 13, "[", "]", {.To_Begin, .To_End, .Inner}, 0, "bar { baz[] }")
	check_equal(t, s, 5, "[", "]", {.To_Begin, .To_End}, 0, "[bar { baz[] }]")
	check_equal(t, s, 10, "{", "}", {.To_Begin, .To_End}, 0, "{ baz[] }")
	check_equal(t, s, 16, "[", "]", {.To_Begin, .To_End, .Inner}, 0, "")
	check_equal(t, s, 18, "[", "]", {.To_Begin, .To_End}, 0, "[bar { baz[] }]")
	check_equal(t, s, 6, "[", "]", {.To_Begin}, 0, "[b")

	s2 := "[*][] foo"
	open_re := selectors_test_regex(t, "\\Q[")
	defer regex_destroy(&open_re)
	close_re := selectors_test_regex(t, "\\Q]")
	defer regex_destroy(&close_re)
	_, _, ok := selectors_find_surrounding_text(s2, 6, &open_re, &close_re, {.To_Begin}, 0)
	testing.expect(t, !ok)

	s3 := "begin foo begin bar end end"
	check_equal(t, s3, 6, "begin", "end", {.To_Begin, .To_End}, 0, s3)
	check_equal(t, s3, 22, "begin", "end", {.To_Begin, .To_End}, 0, "begin bar end")
}

@(test)
test_selectors_keep_direction :: proc(t: ^testing.T) {
	fwd := selectors_test_sel({0, 1}, {0, 5})
	rev := selectors_test_sel({0, 5}, {0, 1})

	// same direction: unchanged
	selectors_test_endpoints(t, selectors_keep_direction(fwd, fwd), {0, 1}, {0, 5})
	selectors_test_endpoints(t, selectors_keep_direction(rev, rev), {0, 5}, {0, 1})
	// different direction: endpoints swap
	swapped := selectors_keep_direction(fwd, rev)
	selectors_test_endpoints(t, swapped, {0, 5}, {0, 1})
	swapped = selectors_keep_direction(rev, fwd)
	selectors_test_endpoints(t, swapped, {0, 1}, {0, 5})
	// cursor targets stay with the cursor across the swap
	targeted := Selection{basic = Basic_Selection{anchor = {0, 1}, cursor = coord_buffer_and_target({0, 5}, 42, 43)}}
	got := selectors_keep_direction(targeted, rev)
	selectors_test_endpoints(t, got, {0, 5}, {0, 1})
	testing.expect_value(t, got.cursor.target, Coord_Column(42))
	testing.expect_value(t, got.cursor.display_target, Coord_Column(43))
}

@(test)
test_selectors_word_motions :: proc(t: ^testing.T) {
	lines := [2]string{"foo bar, baz\n", "qux  quux\n"}
	b := selectors_test_buffer(lines[:])
	defer buffer_destroy(b)
	ctx := selectors_test_ctx(b, []Selection{selectors_test_sel({0, 0}, {0, 0})})
	defer context_destroy(&ctx)

	// w from 'f': covers "foo " (up to the char before next word start)
	got, ok := selectors_select_to_next_word(&ctx, selectors_test_sel({0, 0}, {0, 0}), .Word)
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 0}, {0, 3})

	// w from inside "bar": covers to the end of "bar"
	got, ok = selectors_select_to_next_word(&ctx, selectors_test_sel({0, 5}, {0, 5}), .Word)
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 5}, {0, 6})

	// w from ',': category change steps onto the space, which is its own stop
	got, ok = selectors_select_to_next_word(&ctx, selectors_test_sel({0, 7}, {0, 7}), .Word)
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 8}, {0, 8})

	// WORD from 'f' also stops at the blank
	got, ok = selectors_select_to_next_word(&ctx, selectors_test_sel({0, 0}, {0, 0}), .Big_Word)
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 0}, {0, 3})

	// WORD includes punctuation: "bar," is one stop
	got, ok = selectors_select_to_next_word(&ctx, selectors_test_sel({0, 4}, {0, 4}), .Big_Word)
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 4}, {0, 8})

	// e from 'f': to end of "foo"
	got, ok = selectors_select_to_next_word_end(&ctx, selectors_test_sel({0, 0}, {0, 0}), .Word)
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 0}, {0, 2})

	// b from "baz": the ',' punctuation run is the previous stop
	got, ok = selectors_select_to_previous_word(&ctx, selectors_test_sel({0, 9}, {0, 9}), .Word)
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 8}, {0, 7})

	// b from buffer start fails
	_, ok = selectors_select_to_previous_word(&ctx, selectors_test_sel({0, 0}, {0, 0}), .Word)
	testing.expect(t, !ok)

	// w from the last char (final newline) fails
	_, ok = selectors_select_to_next_word(&ctx, selectors_test_sel({1, 9}, {1, 9}), .Word)
	testing.expect(t, !ok)
}

@(test)
test_selectors_select_word :: proc(t: ^testing.T) {
	lines := [1]string{"foo bar_baz qux\n"}
	b := selectors_test_buffer(lines[:])
	defer buffer_destroy(b)
	underscore := [1]rune{'_'}
	selectors_test_set_runes_option(b, "extra_word_chars", underscore[:])
	defer selectors_test_clear_options(b)
	ctx := selectors_test_ctx(b, []Selection{selectors_test_sel({0, 0}, {0, 0})})
	defer context_destroy(&ctx)

	// inner word both directions
	got, ok := selectors_select_word(&ctx, selectors_test_sel({0, 1}, {0, 1}), 0, {.To_Begin, .To_End, .Inner}, .Word)
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 0}, {0, 2})

	// outer word eats trailing blanks
	got, ok = selectors_select_word(&ctx, selectors_test_sel({0, 1}, {0, 1}), 0, {.To_Begin, .To_End}, .Word)
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 0}, {0, 3})

	// '_' is a word char through the option
	got, ok = selectors_select_word(&ctx, selectors_test_sel({0, 5}, {0, 5}), 0, {.To_Begin, .To_End, .Inner}, .Word)
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 4}, {0, 10})

	// ToBegin only extends backward from the cursor
	got, ok = selectors_select_word(&ctx, selectors_test_sel({0, 6}, {0, 6}), 0, {.To_Begin}, .Word)
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 6}, {0, 4})

	// ToEnd only extends forward
	got, ok = selectors_select_word(&ctx, selectors_test_sel({0, 6}, {0, 6}), 0, {.To_End, .Inner}, .Word)
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 6}, {0, 10})

	// cursor on a blank is not a word
	_, ok = selectors_select_word(&ctx, selectors_test_sel({0, 3}, {0, 3}), 0, {.To_Begin, .To_End, .Inner}, .Word)
	testing.expect(t, !ok)
}

@(test)
test_selectors_line_motions :: proc(t: ^testing.T) {
	lines := [3]string{"  hello\n", "world\n", "\n"}
	b := selectors_test_buffer(lines[:])
	defer buffer_destroy(b)
	ctx := selectors_test_ctx(b, []Selection{selectors_test_sel({0, 0}, {0, 0})})
	defer context_destroy(&ctx)

	// extend to line end
	got, ok := selectors_select_to_line_end(&ctx, selectors_test_sel({0, 0}, {0, 0}), false)
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 0}, {0, 6})
	testing.expect_value(t, got.cursor.target, selection_MAX_NON_EOL_COLUMN)

	// move to line end
	got, ok = selectors_select_to_line_end(&ctx, selectors_test_sel({0, 0}, {0, 0}), true)
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 6}, {0, 6})

	// cursor on the newline stays (never goes backward)
	got, ok = selectors_select_to_line_end(&ctx, selectors_test_sel({0, 7}, {0, 7}), false)
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 7}, {0, 7})

	// blank line: begin and end coincide
	got, ok = selectors_select_to_line_end(&ctx, selectors_test_sel({2, 0}, {2, 0}), false)
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {2, 0}, {2, 0})

	// extend and move to line begin
	got, ok = selectors_select_to_line_begin(&ctx, selectors_test_sel({1, 3}, {1, 3}), false)
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {1, 3}, {1, 0})
	got, ok = selectors_select_to_line_begin(&ctx, selectors_test_sel({1, 3}, {1, 3}), true)
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {1, 0}, {1, 0})

	// first non-blank skips the indent
	got, ok = selectors_select_to_first_non_blank(&ctx, selectors_test_sel({0, 6}, {0, 6}))
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 2}, {0, 2})
	got, ok = selectors_select_to_first_non_blank(&ctx, selectors_test_sel({1, 4}, {1, 4}))
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {1, 0}, {1, 0})
	// blank line stops on the newline
	got, ok = selectors_select_to_first_non_blank(&ctx, selectors_test_sel({2, 0}, {2, 0}))
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {2, 0}, {2, 0})
}

@(test)
test_selectors_lines :: proc(t: ^testing.T) {
	lines := [3]string{"  hello\n", "world\n", "\n"}
	b := selectors_test_buffer(lines[:])
	defer buffer_destroy(b)
	ctx := selectors_test_ctx(b, []Selection{selectors_test_sel({0, 0}, {0, 0})})
	defer context_destroy(&ctx)

	// forward selection extends to full lines
	got, ok := selectors_select_lines(&ctx, selectors_test_sel({0, 2}, {1, 3}))
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 0}, {1, 5})
	testing.expect_value(t, got.cursor.target, selection_MAX_COLUMN)

	// reversed selection keeps its direction
	got, ok = selectors_select_lines(&ctx, selectors_test_sel({1, 3}, {0, 2}))
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {1, 5}, {0, 0})

	// already full lines are unchanged
	got, ok = selectors_trim_partial_lines(&ctx, selectors_test_sel({0, 0}, {1, 5}))
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 0}, {1, 5})

	// partial last line is dropped
	got, ok = selectors_trim_partial_lines(&ctx, selectors_test_sel({0, 0}, {1, 3}))
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 0}, {0, 7})

	// nothing whole left: failure
	_, ok = selectors_trim_partial_lines(&ctx, selectors_test_sel({0, 2}, {1, 3}))
	testing.expect(t, !ok)

	// partial first line on line 0 with a partial end cannot trim either side
	_, ok = selectors_trim_partial_lines(&ctx, selectors_test_sel({0, 2}, {0, 4}))
	testing.expect(t, !ok)
}

@(test)
test_selectors_matching :: proc(t: ^testing.T) {
	lines := [2]string{"(foo [bar])\n", "plain\n"}
	b := selectors_test_buffer(lines[:])
	defer buffer_destroy(b)
	pairs := [8]rune{'(', ')', '{', '}', '[', ']', '<', '>'}
	selectors_test_set_runes_option(b, "matching_pairs", pairs[:])
	defer selectors_test_clear_options(b)
	ctx := selectors_test_ctx(b, []Selection{selectors_test_sel({0, 0}, {0, 0})})
	defer context_destroy(&ctx)

	// outer parens, nesting-aware
	got, ok := selectors_select_matching(&ctx, selectors_test_sel({0, 0}, {0, 0}), true)
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 0}, {0, 10})

	// inner brackets
	got, ok = selectors_select_matching(&ctx, selectors_test_sel({0, 5}, {0, 5}), true)
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 5}, {0, 9})

	// forward scan finds the next bracket first
	got, ok = selectors_select_matching(&ctx, selectors_test_sel({0, 1}, {0, 1}), true)
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 5}, {0, 9})

	// backward from the closing paren
	got, ok = selectors_select_matching(&ctx, selectors_test_sel({0, 10}, {0, 10}), false)
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 10}, {0, 0})

	// backward scan finds '[' then matches forward
	got, ok = selectors_select_matching(&ctx, selectors_test_sel({0, 6}, {0, 6}), false)
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 5}, {0, 9})

	// no bracket ahead
	_, ok = selectors_select_matching(&ctx, selectors_test_sel({1, 0}, {1, 0}), true)
	testing.expect(t, !ok)
}

@(test)
test_selectors_select_to :: proc(t: ^testing.T) {
	lines := [1]string{"foo bar foo\n"}
	b := selectors_test_buffer(lines[:])
	defer buffer_destroy(b)
	ctx := selectors_test_ctx(b, []Selection{selectors_test_sel({0, 0}, {0, 0})})
	defer context_destroy(&ctx)

	got, ok := selectors_select_to(&ctx, selectors_test_sel({0, 0}, {0, 0}), 'o', 1, true)
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 0}, {0, 1})

	got, ok = selectors_select_to(&ctx, selectors_test_sel({0, 0}, {0, 0}), 'o', 1, false)
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 0}, {0, 0})

	got, ok = selectors_select_to(&ctx, selectors_test_sel({0, 0}, {0, 0}), 'o', 2, true)
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 0}, {0, 2})

	_, ok = selectors_select_to(&ctx, selectors_test_sel({0, 0}, {0, 0}), 'z', 1, true)
	testing.expect(t, !ok)

	got, ok = selectors_select_to_reverse(&ctx, selectors_test_sel({0, 10}, {0, 10}), 'o', 1, true)
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 10}, {0, 9})

	got, ok = selectors_select_to_reverse(&ctx, selectors_test_sel({0, 10}, {0, 10}), 'o', 1, false)
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 10}, {0, 10})

	_, ok = selectors_select_to_reverse(&ctx, selectors_test_sel({0, 2}, {0, 2}), 'z', 1, true)
	testing.expect(t, !ok)

	_, ok = selectors_select_to_reverse(&ctx, selectors_test_sel({0, 0}, {0, 0}), 'o', 1, true)
	testing.expect(t, !ok)
}

@(test)
test_selectors_number :: proc(t: ^testing.T) {
	lines := [1]string{"x -12.5 y 7\n"}
	b := selectors_test_buffer(lines[:])
	defer buffer_destroy(b)
	ctx := selectors_test_ctx(b, []Selection{selectors_test_sel({0, 0}, {0, 0})})
	defer context_destroy(&ctx)

	// outer keeps the decimal part and the sign
	got, ok := selectors_select_number(&ctx, selectors_test_sel({0, 3}, {0, 3}), 0, {.To_Begin, .To_End})
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 2}, {0, 6})

	// inner stops at the dot
	got, ok = selectors_select_number(&ctx, selectors_test_sel({0, 3}, {0, 3}), 0, {.To_Begin, .To_End, .Inner})
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 2}, {0, 4})

	// starting on the sign works
	got, ok = selectors_select_number(&ctx, selectors_test_sel({0, 2}, {0, 2}), 0, {.To_Begin, .To_End})
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 2}, {0, 6})

	// single digit
	got, ok = selectors_select_number(&ctx, selectors_test_sel({0, 10}, {0, 10}), 0, {.To_Begin, .To_End})
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 10}, {0, 10})

	// letters are not numbers
	_, ok = selectors_select_number(&ctx, selectors_test_sel({0, 0}, {0, 0}), 0, {.To_Begin, .To_End})
	testing.expect(t, !ok)
}

@(test)
test_selectors_sentence :: proc(t: ^testing.T) {
	lines := [2]string{"Hello world. Foo bar.\n", "Next line here.\n"}
	b := selectors_test_buffer(lines[:])
	defer buffer_destroy(b)
	ctx := selectors_test_ctx(b, []Selection{selectors_test_sel({0, 0}, {0, 0})})
	defer context_destroy(&ctx)

	// inner sentence
	got, ok := selectors_select_sentence(&ctx, selectors_test_sel({0, 0}, {0, 0}), 0, {.To_Begin, .To_End, .Inner})
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 0}, {0, 11})

	// outer sentence eats the trailing space
	got, ok = selectors_select_sentence(&ctx, selectors_test_sel({0, 0}, {0, 0}), 0, {.To_Begin, .To_End})
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 0}, {0, 12})

	// second sentence from its middle
	got, ok = selectors_select_sentence(&ctx, selectors_test_sel({0, 14}, {0, 14}), 0, {.To_Begin, .To_End, .Inner})
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 13}, {0, 20})

	// count extends over two sentences
	got, ok = selectors_select_sentence(&ctx, selectors_test_sel({0, 0}, {0, 0}), 1, {.To_Begin, .To_End})
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 0}, {0, 20})

	// ToBegin only extends backward
	got, ok = selectors_select_sentence(&ctx, selectors_test_sel({0, 14}, {0, 14}), 0, {.To_Begin})
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 14}, {0, 13})
}

@(test)
test_selectors_paragraph :: proc(t: ^testing.T) {
	lines := [4]string{"para one\n", "still one\n", "\n", "para two\n"}
	b := selectors_test_buffer(lines[:])
	defer buffer_destroy(b)
	ctx := selectors_test_ctx(b, []Selection{selectors_test_sel({0, 0}, {0, 0})})
	defer context_destroy(&ctx)

	// inner paragraph stops before the blank line
	got, ok := selectors_select_paragraph(&ctx, selectors_test_sel({0, 2}, {0, 2}), 0, {.To_Begin, .To_End, .Inner})
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 0}, {1, 9})

	// outer paragraph includes the blank line
	got, ok = selectors_select_paragraph(&ctx, selectors_test_sel({0, 2}, {0, 2}), 0, {.To_Begin, .To_End})
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 0}, {2, 0})

	// second paragraph runs to the buffer end
	got, ok = selectors_select_paragraph(&ctx, selectors_test_sel({3, 2}, {3, 2}), 0, {.To_Begin, .To_End, .Inner})
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {3, 0}, {3, 8})

	// ToBegin only extends backward
	got, ok = selectors_select_paragraph(&ctx, selectors_test_sel({1, 3}, {1, 3}), 0, {.To_Begin, .Inner})
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {1, 3}, {0, 0})
}

@(test)
test_selectors_whitespaces :: proc(t: ^testing.T) {
	lines := [3]string{"foo   bar\n", "\n", "baz\n"}
	b := selectors_test_buffer(lines[:])
	defer buffer_destroy(b)
	ctx := selectors_test_ctx(b, []Selection{selectors_test_sel({0, 0}, {0, 0})})
	defer context_destroy(&ctx)

	got, ok := selectors_select_whitespaces(&ctx, selectors_test_sel({0, 4}, {0, 4}), 0, {.To_Begin, .To_End})
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 3}, {0, 5})

	// inner excludes newlines
	_, ok = selectors_select_whitespaces(&ctx, selectors_test_sel({0, 9}, {0, 9}), 0, {.To_Begin, .To_End, .Inner})
	testing.expect(t, !ok)

	// outer crosses newlines
	got, ok = selectors_select_whitespaces(&ctx, selectors_test_sel({0, 9}, {0, 9}), 0, {.To_Begin, .To_End})
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 9}, {1, 0})

	// words are not whitespace
	_, ok = selectors_select_whitespaces(&ctx, selectors_test_sel({0, 0}, {0, 0}), 0, {.To_Begin, .To_End})
	testing.expect(t, !ok)
}

@(test)
test_selectors_indent :: proc(t: ^testing.T) {
	lines := [6]string{"fn x:\n", "    one\n", "    two\n", "\n", "  shallow\n", "    deep\n"}
	b := selectors_test_buffer(lines[:])
	defer buffer_destroy(b)
	selectors_test_set_int_option(b, "tabstop", 4)
	defer selectors_test_clear_options(b)
	ctx := selectors_test_ctx(b, []Selection{selectors_test_sel({0, 0}, {0, 0})})
	defer context_destroy(&ctx)

	// block at indent 4; outer keeps the trailing blank line
	got, ok := selectors_select_indent(&ctx, selectors_test_sel({1, 5}, {1, 5}), 0, {.To_Begin, .To_End})
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {1, 0}, {3, 0})

	// from the blank line, outer keeps it
	got, ok = selectors_select_indent(&ctx, selectors_test_sel({3, 0}, {3, 0}), 0, {.To_Begin, .To_End})
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {1, 0}, {3, 0})

	// from the blank line, inner trims it
	got, ok = selectors_select_indent(&ctx, selectors_test_sel({3, 0}, {3, 0}), 0, {.To_Begin, .To_End, .Inner})
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {1, 0}, {2, 7})

	// shallower indent selects a wider block
	got, ok = selectors_select_indent(&ctx, selectors_test_sel({4, 3}, {4, 3}), 0, {.To_Begin, .To_End})
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {1, 0}, {5, 8})
}

@(test)
test_selectors_argument :: proc(t: ^testing.T) {
	lines := [1]string{"f(aa, bb(cc), dd);\n"}
	b := selectors_test_buffer(lines[:])
	defer buffer_destroy(b)
	ctx := selectors_test_ctx(b, []Selection{selectors_test_sel({0, 0}, {0, 0})})
	defer context_destroy(&ctx)

	// middle argument, inner skips the nested parens
	got, ok := selectors_select_argument(&ctx, selectors_test_sel({0, 6}, {0, 6}), 0, {.To_Begin, .To_End, .Inner})
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 6}, {0, 11})

	// middle argument, outer keeps separators
	got, ok = selectors_select_argument(&ctx, selectors_test_sel({0, 6}, {0, 6}), 0, {.To_Begin, .To_End})
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 5}, {0, 12})

	// first argument
	got, ok = selectors_select_argument(&ctx, selectors_test_sel({0, 2}, {0, 2}), 0, {.To_Begin, .To_End, .Inner})
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 2}, {0, 3})
	got, ok = selectors_select_argument(&ctx, selectors_test_sel({0, 2}, {0, 2}), 0, {.To_Begin, .To_End})
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 2}, {0, 5})

	// last argument
	got, ok = selectors_select_argument(&ctx, selectors_test_sel({0, 14}, {0, 14}), 0, {.To_Begin, .To_End, .Inner})
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 14}, {0, 15})
	got, ok = selectors_select_argument(&ctx, selectors_test_sel({0, 14}, {0, 14}), 0, {.To_Begin, .To_End})
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 12}, {0, 15})

	// nesting level from inside the inner parens selects the outer argument
	got, ok = selectors_select_argument(&ctx, selectors_test_sel({0, 9}, {0, 9}), 1, {.To_Begin, .To_End})
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 5}, {0, 12})

	// ToBegin only runs backward from the cursor
	got, ok = selectors_select_argument(&ctx, selectors_test_sel({0, 14}, {0, 14}), 0, {.To_Begin})
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 14}, {0, 12})
}

@(test)
test_selectors_nested_words_numbers :: proc(t: ^testing.T) {
	lines := [1]string{"foo 123, bar.\n"}
	b := selectors_test_buffer(lines[:])
	defer buffer_destroy(b)
	ctx := selectors_test_ctx(b, []Selection{selectors_test_sel({0, 0}, {0, 12})})
	defer context_destroy(&ctx)

	res, err := selectors_select_nested_words(&ctx, 0, {.To_Begin, .To_End, .Inner}, .Word)
	testing.expect_value(t, err, Selectors_Error.None)
	defer selectors_test_free_all(&res)
	testing.expect_value(t, len(res), 3)
	selectors_test_endpoints(t, res[0], {0, 0}, {0, 2})
	selectors_test_endpoints(t, res[1], {0, 4}, {0, 6})
	selectors_test_endpoints(t, res[2], {0, 9}, {0, 11})

	outer, err2 := selectors_select_nested_words(&ctx, 0, {.To_Begin, .To_End}, .Word)
	testing.expect_value(t, err2, Selectors_Error.None)
	defer selectors_test_free_all(&outer)
	testing.expect_value(t, len(outer), 3)
	selectors_test_endpoints(t, outer[0], {0, 0}, {0, 3})
	selectors_test_endpoints(t, outer[1], {0, 4}, {0, 6})
	selectors_test_endpoints(t, outer[2], {0, 9}, {0, 11})

	nums, err3 := selectors_select_nested_numbers(&ctx, 0, {.To_Begin, .To_End})
	testing.expect_value(t, err3, Selectors_Error.None)
	defer selectors_test_free_all(&nums)
	testing.expect_value(t, len(nums), 1)
	selectors_test_endpoints(t, nums[0], {0, 4}, {0, 6})
}

@(test)
test_selectors_nested_sentences_paragraphs_whitespaces :: proc(t: ^testing.T) {
	lines := [2]string{"foo 123, bar.\n", "second line here\n"}
	b := selectors_test_buffer(lines[:])
	defer buffer_destroy(b)
	ctx := selectors_test_ctx(b, []Selection{selectors_test_sel({0, 0}, {0, 12})})
	defer context_destroy(&ctx)

	sents, err := selectors_select_nested_sentences(&ctx, 0, {.To_Begin, .To_End, .Inner})
	testing.expect_value(t, err, Selectors_Error.None)
	defer selectors_test_free_all(&sents)
	testing.expect_value(t, len(sents), 1)
	selectors_test_endpoints(t, sents[0], {0, 0}, {0, 12})

	ws, err2 := selectors_select_nested_whitespaces(&ctx, 0, {.To_Begin, .To_End, .Inner})
	testing.expect_value(t, err2, Selectors_Error.None)
	defer selectors_test_free_all(&ws)
	testing.expect_value(t, len(ws), 2)
	selectors_test_endpoints(t, ws[0], {0, 3}, {0, 3})
	selectors_test_endpoints(t, ws[1], {0, 8}, {0, 8})

	// paragraphs over a two-line selection
	replacement := selection_list_make_single(b, selectors_test_sel({0, 0}, {1, 15}), buffer_timestamp(b))
	context_assign_selections(&ctx, replacement)
	selection_list_destroy(&replacement)
	paras, err3 := selectors_select_nested_paragraphs(&ctx, 0, {.To_Begin, .To_End, .Inner})
	testing.expect_value(t, err3, Selectors_Error.None)
	defer selectors_test_free_all(&paras)
	testing.expect_value(t, len(paras), 1)
	selectors_test_endpoints(t, paras[0], {0, 0}, {1, 15})
}

@(test)
test_selectors_nested_arguments :: proc(t: ^testing.T) {
	lines := [1]string{"(a, b(c), d)\n"}
	b := selectors_test_buffer(lines[:])
	defer buffer_destroy(b)
	ctx := selectors_test_ctx(b, []Selection{selectors_test_sel({0, 1}, {0, 10})})
	defer context_destroy(&ctx)

	inner, err := selectors_select_nested_arguments(&ctx, 0, {.To_Begin, .To_End, .Inner})
	testing.expect_value(t, err, Selectors_Error.None)
	defer selectors_test_free_all(&inner)
	testing.expect_value(t, len(inner), 3)
	selectors_test_endpoints(t, inner[0], {0, 1}, {0, 1})
	selectors_test_endpoints(t, inner[1], {0, 4}, {0, 7})
	selectors_test_endpoints(t, inner[2], {0, 10}, {0, 10})

	outer, err2 := selectors_select_nested_arguments(&ctx, 0, {.To_Begin, .To_End})
	testing.expect_value(t, err2, Selectors_Error.None)
	defer selectors_test_free_all(&outer)
	testing.expect_value(t, len(outer), 3)
	selectors_test_endpoints(t, outer[0], {0, 1}, {0, 2})
	selectors_test_endpoints(t, outer[1], {0, 3}, {0, 8})
	selectors_test_endpoints(t, outer[2], {0, 9}, {0, 10})
}

@(test)
test_selectors_nested_errors :: proc(t: ^testing.T) {
	lines := [1]string{"foo 123, bar.\n"}
	b := selectors_test_buffer(lines[:])
	defer buffer_destroy(b)
	// selection holding only punctuation: words find nothing
	ctx := selectors_test_ctx(b, []Selection{selectors_test_sel({0, 7}, {0, 7})})
	defer context_destroy(&ctx)

	res, err := selectors_select_nested_words(&ctx, 0, {.To_Begin, .To_End, .Inner}, .Word)
	testing.expect_value(t, err, Selectors_Error.Nothing_Selected)
	testing.expect(t, res == nil)

	_, err = selectors_select_nested_indents(&ctx, 0, {.To_Begin, .To_End})
	testing.expect_value(t, err, Selectors_Error.Not_Implemented)

	testing.expect_value(t, selectors_error_message(.Nothing_Selected), "nothing selected")
	testing.expect_value(t, selectors_error_message(.Invalid_Capture), "invalid capture number")
	testing.expect_value(t, selectors_error_message(.No_Match), "no matches found")
	testing.expect_value(t, selectors_error_message(.Not_Implemented), "nested indents are not implemented")
}

@(test)
test_selectors_surrounding :: proc(t: ^testing.T) {
	lines := [1]string{"{foo [bar { baz[] }]}\n"}
	b := selectors_test_buffer(lines[:])
	defer buffer_destroy(b)
	ctx := selectors_test_ctx(b, []Selection{selectors_test_sel({0, 13}, {0, 13})})
	defer context_destroy(&ctx)
	open_re := selectors_test_regex(t, "\\Q{")
	defer regex_destroy(&open_re)
	close_re := selectors_test_regex(t, "\\Q}")
	defer regex_destroy(&close_re)

	got, ok := selectors_select_surrounding(&ctx, selectors_test_sel({0, 13}, {0, 13}), &open_re, &close_re, 0, {.To_Begin, .To_End})
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 10}, {0, 18})

	got, ok = selectors_select_surrounding(&ctx, selectors_test_sel({0, 13}, {0, 13}), &open_re, &close_re, 0, {.To_Begin, .To_End, .Inner})
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 11}, {0, 17})

	// selecting the same block again expands to the parent
	got, ok = selectors_select_surrounding(&ctx, selectors_test_sel({0, 10}, {0, 18}), &open_re, &close_re, 0, {.To_Begin, .To_End})
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 0}, {0, 20})

	// unbalanced: no closing brace after the cursor
	lines2 := [1]string{"{foo bar\n"}
	b2 := selectors_test_buffer(lines2[:])
	defer buffer_destroy(b2)
	ctx2 := selectors_test_ctx(b2, []Selection{selectors_test_sel({0, 2}, {0, 2})})
	defer context_destroy(&ctx2)
	_, ok = selectors_select_surrounding(&ctx2, selectors_test_sel({0, 2}, {0, 2}), &open_re, &close_re, 0, {.To_Begin, .To_End})
	testing.expect(t, !ok)
}

@(test)
test_selectors_regex_nested :: proc(t: ^testing.T) {
	lines := [1]string{"a(X)b(Y)c\n"}
	b := selectors_test_buffer(lines[:])
	defer buffer_destroy(b)
	ctx := selectors_test_ctx(b, []Selection{selectors_test_sel({0, 0}, {0, 8})})
	defer context_destroy(&ctx)
	open_re := selectors_test_regex(t, "\\Q(")
	defer regex_destroy(&open_re)
	close_re := selectors_test_regex(t, "\\Q)")
	defer regex_destroy(&close_re)

	outer, err := selectors_regex_select_nested(&ctx, &open_re, &close_re, 0, {.To_Begin, .To_End})
	testing.expect_value(t, err, Selectors_Error.None)
	defer selectors_test_free_all(&outer)
	testing.expect_value(t, len(outer), 2)
	selectors_test_endpoints(t, outer[0], {0, 1}, {0, 3})
	selectors_test_endpoints(t, outer[1], {0, 5}, {0, 7})

	inner, err2 := selectors_regex_select_nested(&ctx, &open_re, &close_re, 0, {.To_Begin, .To_End, .Inner})
	testing.expect_value(t, err2, Selectors_Error.None)
	defer selectors_test_free_all(&inner)
	testing.expect_value(t, len(inner), 2)
	selectors_test_endpoints(t, inner[0], {0, 2}, {0, 2})
	selectors_test_endpoints(t, inner[1], {0, 6}, {0, 6})

	// level without nesting finds nothing
	_, err3 := selectors_regex_select_nested(&ctx, &open_re, &close_re, 1, {.To_Begin, .To_End})
	testing.expect_value(t, err3, Selectors_Error.Nothing_Selected)

	// delimiter form
	lines2 := [1]string{"a,b;c\n"}
	b2 := selectors_test_buffer(lines2[:])
	defer buffer_destroy(b2)
	ctx2 := selectors_test_ctx(b2, []Selection{selectors_test_sel({0, 0}, {0, 4})})
	defer context_destroy(&ctx2)
	delim_re := selectors_test_regex(t, "[,;]")
	defer regex_destroy(&delim_re)
	douter, err4 := selectors_regex_select_nested_delim(&ctx2, &delim_re, {.To_Begin, .To_End})
	testing.expect_value(t, err4, Selectors_Error.None)
	defer selectors_test_free_all(&douter)
	testing.expect_value(t, len(douter), 1)
	selectors_test_endpoints(t, douter[0], {0, 1}, {0, 3})
	dinner, err5 := selectors_regex_select_nested_delim(&ctx2, &delim_re, {.To_Begin, .To_End, .Inner})
	testing.expect_value(t, err5, Selectors_Error.None)
	defer selectors_test_free_all(&dinner)
	testing.expect_value(t, len(dinner), 1)
	selectors_test_endpoints(t, dinner[0], {0, 2}, {0, 2})
}

@(test)
test_selectors_find_next_match :: proc(t: ^testing.T) {
	lines := [2]string{"foo bar foo\n", "bar baz\n"}
	b := selectors_test_buffer(lines[:])
	defer buffer_destroy(b)
	ctx := selectors_test_ctx(b, []Selection{selectors_test_sel({0, 0}, {0, 0})})
	defer context_destroy(&ctx)
	bar_re := selectors_test_regex(t, "bar")
	defer regex_destroy(&bar_re)
	foo_re := selectors_test_regex(t, "foo")
	defer regex_destroy(&foo_re)
	zzz_re := selectors_test_regex(t, "zzz")
	defer regex_destroy(&zzz_re)

	got, wrapped, err := selectors_find_next_match(&ctx, selectors_test_sel({0, 0}, {0, 0}), &bar_re, true)
	testing.expect_value(t, err, Selectors_Error.None)
	testing.expect(t, !wrapped)
	defer selection_destroy(&got)
	selectors_test_endpoints(t, got, {0, 4}, {0, 6})
	testing.expect_value(t, len(got.captures), 1)
	testing.expect_value(t, got.captures[0], "bar")

	// wraps around the buffer end
	got2, wrapped2, err2 := selectors_find_next_match(&ctx, selectors_test_sel({0, 8}, {0, 10}), &foo_re, true)
	testing.expect_value(t, err2, Selectors_Error.None)
	testing.expect(t, wrapped2)
	defer selection_destroy(&got2)
	selectors_test_endpoints(t, got2, {0, 0}, {0, 2})

	// backward search returns a reversed selection
	got3, wrapped3, err3 := selectors_find_next_match(&ctx, selectors_test_sel({0, 8}, {0, 8}), &foo_re, false)
	testing.expect_value(t, err3, Selectors_Error.None)
	testing.expect(t, !wrapped3)
	defer selection_destroy(&got3)
	selectors_test_endpoints(t, got3, {0, 2}, {0, 0})

	// no match anywhere
	_, _, err4 := selectors_find_next_match(&ctx, selectors_test_sel({0, 0}, {0, 0}), &zzz_re, true)
	testing.expect_value(t, err4, Selectors_Error.No_Match)

	// capture groups are cloned
	groups_re := selectors_test_regex(t, "f(o+)")
	defer regex_destroy(&groups_re)
	got5, _, err5 := selectors_find_next_match(&ctx, selectors_test_sel({0, 0}, {0, 0}), &groups_re, true)
	testing.expect_value(t, err5, Selectors_Error.None)
	defer selection_destroy(&got5)
	selectors_test_endpoints(t, got5, {0, 8}, {0, 10})
	testing.expect_value(t, len(got5.captures), 2)
	testing.expect_value(t, got5.captures[0], "foo")
	testing.expect_value(t, got5.captures[1], "oo")
}

@(test)
test_selectors_matches_and_split :: proc(t: ^testing.T) {
	lines := [1]string{"foo 123 bar 456\n"}
	b := selectors_test_buffer(lines[:])
	defer buffer_destroy(b)
	sels := [1]Selection{selectors_test_sel({0, 0}, {0, 14})}
	nums_re := selectors_test_regex(t, "[0-9]+")
	defer regex_destroy(&nums_re)

	res, err := selectors_select_matches(b, sels[:], &nums_re)
	testing.expect_value(t, err, Selectors_Error.None)
	defer selectors_test_free_all(&res)
	testing.expect_value(t, len(res), 2)
	selectors_test_endpoints(t, res[0], {0, 4}, {0, 6})
	selectors_test_endpoints(t, res[1], {0, 12}, {0, 14})
	testing.expect_value(t, res[0].captures[0], "123")

	// capture index selects the group
	groups_re := selectors_test_regex(t, "([0-9])([0-9])")
	defer regex_destroy(&groups_re)
	res2, err2 := selectors_select_matches(b, sels[:], &groups_re, 2)
	testing.expect_value(t, err2, Selectors_Error.None)
	defer selectors_test_free_all(&res2)
	testing.expect_value(t, len(res2), 2)
	selectors_test_endpoints(t, res2[0], {0, 5}, {0, 5})
	selectors_test_endpoints(t, res2[1], {0, 13}, {0, 13})

	// reversed selections keep their direction
	rev := [1]Selection{selectors_test_sel({0, 14}, {0, 0})}
	res3, err3 := selectors_select_matches(b, rev[:], &nums_re)
	testing.expect_value(t, err3, Selectors_Error.None)
	defer selectors_test_free_all(&res3)
	testing.expect_value(t, len(res3), 2)
	selectors_test_endpoints(t, res3[0], {0, 6}, {0, 4})

	// invalid capture index
	_, err4 := selectors_select_matches(b, sels[:], &nums_re, 5)
	testing.expect_value(t, err4, Selectors_Error.Invalid_Capture)
	_, err5 := selectors_select_matches(b, sels[:], &nums_re, -1)
	testing.expect_value(t, err5, Selectors_Error.Invalid_Capture)

	// no match is an error
	zzz_re := selectors_test_regex(t, "zzz")
	defer regex_destroy(&zzz_re)
	_, err6 := selectors_select_matches(b, sels[:], &zzz_re)
	testing.expect_value(t, err6, Selectors_Error.Nothing_Selected)

	// split on the numbers
	parts, err7 := selectors_split_on_matches(b, sels[:], &nums_re)
	testing.expect_value(t, err7, Selectors_Error.None)
	defer selectors_test_free_all(&parts)
	testing.expect_value(t, len(parts), 2)
	selectors_test_endpoints(t, parts[0], {0, 0}, {0, 3})
	selectors_test_endpoints(t, parts[1], {0, 7}, {0, 11})

	// split without matches returns the whole selection
	whole, err8 := selectors_split_on_matches(b, sels[:], &zzz_re)
	testing.expect_value(t, err8, Selectors_Error.None)
	defer selectors_test_free_all(&whole)
	testing.expect_value(t, len(whole), 1)
	selectors_test_endpoints(t, whole[0], {0, 0}, {0, 14})
}

@(test)
test_selectors_empty_buffer :: proc(t: ^testing.T) {
	lines := [1]string{"\n"}
	b := selectors_test_buffer(lines[:])
	defer buffer_destroy(b)
	ctx := selectors_test_ctx(b, []Selection{selectors_test_sel({0, 0}, {0, 0})})
	defer context_destroy(&ctx)
	here := selectors_test_sel({0, 0}, {0, 0})

	// motions fail, objects either fail or select the newline without crashing
	got := Selection{}
	ok := false
	_, ok = selectors_select_to_next_word(&ctx, here, .Word)
	testing.expect(t, !ok)
	_, ok = selectors_select_to_previous_word(&ctx, here, .Word)
	testing.expect(t, !ok)
	_, ok = selectors_select_word(&ctx, here, 0, {.To_Begin, .To_End, .Inner}, .Word)
	testing.expect(t, !ok)
	_, ok = selectors_select_number(&ctx, here, 0, {.To_Begin, .To_End})
	testing.expect(t, !ok)
	_, ok = selectors_select_to(&ctx, here, 'x', 1, true)
	testing.expect(t, !ok)
	_, ok = selectors_select_matching(&ctx, here, true)
	testing.expect(t, !ok)

	got, ok = selectors_select_sentence(&ctx, here, 0, {.To_Begin, .To_End, .Inner})
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 0}, {0, 0})

	got, ok = selectors_select_paragraph(&ctx, here, 0, {.To_Begin, .To_End, .Inner})
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 0}, {0, 0})

	got, ok = selectors_select_whitespaces(&ctx, here, 0, {.To_Begin, .To_End})
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 0}, {0, 0})

	got, ok = selectors_select_indent(&ctx, here, 0, {.To_Begin, .To_End})
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 0}, {0, 0})

	_, ok = selectors_select_argument(&ctx, here, 0, {.To_Begin, .To_End})
	testing.expect(t, ok)
}

@(test)
test_selectors_single_char :: proc(t: ^testing.T) {
	lines := [1]string{"a\n"}
	b := selectors_test_buffer(lines[:])
	defer buffer_destroy(b)
	ctx := selectors_test_ctx(b, []Selection{selectors_test_sel({0, 0}, {0, 0})})
	defer context_destroy(&ctx)

	got, ok := selectors_select_word(&ctx, selectors_test_sel({0, 0}, {0, 0}), 0, {.To_Begin, .To_End, .Inner}, .Word)
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 0}, {0, 0})

	// motions off either edge fail
	_, ok = selectors_select_to_next_word(&ctx, selectors_test_sel({0, 1}, {0, 1}), .Word)
	testing.expect(t, !ok)
	_, ok = selectors_select_to_previous_word(&ctx, selectors_test_sel({0, 0}, {0, 0}), .Word)
	testing.expect(t, !ok)

	// w from 'a': stepping onto the newline then skipping it reaches the
	// buffer end, so there is no next word
	_, ok = selectors_select_to_next_word(&ctx, selectors_test_sel({0, 0}, {0, 0}), .Word)
	testing.expect(t, !ok)
}

@(test)
test_selectors_counts_and_flags :: proc(t: ^testing.T) {
	lines := [2]string{"foo bar foo\n", "second.\n"}
	b := selectors_test_buffer(lines[:])
	defer buffer_destroy(b)
	ctx := selectors_test_ctx(b, []Selection{selectors_test_sel({0, 0}, {0, 0})})
	defer context_destroy(&ctx)

	// count 0 still performs one step (do-while in C++)
	got, ok := selectors_select_to(&ctx, selectors_test_sel({0, 0}, {0, 0}), 'o', 0, true)
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 0}, {0, 1})

	// huge counts fail cleanly instead of running off the buffer
	_, ok = selectors_select_to(&ctx, selectors_test_sel({0, 0}, {0, 0}), 'o', 100, true)
	testing.expect(t, !ok)
	_, ok = selectors_select_to_reverse(&ctx, selectors_test_sel({0, 10}, {0, 10}), 'o', 100, true)
	testing.expect(t, !ok)

	// negative counts behave like 0
	_, ok = selectors_select_sentence(&ctx, selectors_test_sel({0, 0}, {0, 0}), -1, {.To_Begin, .To_End})
	testing.expect(t, ok)
	_, ok = selectors_select_paragraph(&ctx, selectors_test_sel({0, 0}, {0, 0}), -5, {.To_Begin, .To_End})
	testing.expect(t, ok)

	// huge counts terminate at the buffer edges
	got, ok = selectors_select_sentence(&ctx, selectors_test_sel({0, 0}, {0, 0}), 100, {.To_Begin, .To_End})
	testing.expect(t, ok)
	testing.expect(t, coord_compare(got.anchor, got.cursor.coord) <= 0)
	got, ok = selectors_select_paragraph(&ctx, selectors_test_sel({0, 0}, {0, 0}), 100, {.To_Begin, .To_End})
	testing.expect(t, ok)
	testing.expect(t, coord_compare(got.anchor, got.cursor.coord) <= 0)

	// no direction flags: objects collapse onto the cursor
	got, ok = selectors_select_word(&ctx, selectors_test_sel({0, 1}, {0, 1}), 0, {}, .Word)
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 1}, {0, 1})
	got, ok = selectors_select_whitespaces(&ctx, selectors_test_sel({0, 3}, {0, 3}), 0, {.Inner})
	testing.expect(t, ok)
	selectors_test_endpoints(t, got, {0, 3}, {0, 3})
}

@(test)
test_selectors_missing_options :: proc(t: ^testing.T) {
	lines := [2]string{"foo_bar (x)\n", "\ty\n"}
	b := selectors_test_buffer(lines[:])
	defer buffer_destroy(b)
	// no options installed: defaults apply (empty extra chars, no pairs, tabstop 8)
	ctx := selectors_test_ctx(b, []Selection{selectors_test_sel({0, 0}, {0, 0})})
	defer context_destroy(&ctx)

	// '_' is punctuation without extra_word_chars
	_, ok := selectors_select_word(&ctx, selectors_test_sel({0, 3}, {0, 3}), 0, {.To_Begin, .To_End, .Inner}, .Word)
	testing.expect(t, !ok)

	// no matching pairs configured
	_, ok = selectors_select_matching(&ctx, selectors_test_sel({0, 8}, {0, 8}), true)
	testing.expect(t, !ok)

	// tabstop defaults to 8: "\ty" has indent 8, and line 0 (indent 0)
	// stops the upward scan
	got, ok2 := selectors_select_indent(&ctx, selectors_test_sel({1, 1}, {1, 1}), 0, {.To_Begin, .To_End})
	testing.expect(t, ok2)
	selectors_test_endpoints(t, got, {1, 0}, {1, 2})
}

@(test)
test_selectors_allocator_cleanup :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	alloc := mem.tracking_allocator(&track)
	defer mem.tracking_allocator_destroy(&track)

	{
		lines := [2]string{"foo 123 (bar), baz.\n", "second line (qux) here\n"}
		b := buffer_make("test", Buffer_Flags{}, lines[:], .None, .Lf, .Present, File_Fs_Status{timestamp = File_Invalid_Time}, alloc)
		defer buffer_destroy(b)
		sels := [2]Selection{selectors_test_sel({0, 0}, {0, 18}), selectors_test_sel({1, 0}, {1, 21})}
		list := selection_list_make(b, sels[:], buffer_timestamp(b), alloc)
		ctx: Context
		context_init(&ctx, nil, list, {}, "", alloc)
		selection_list_destroy(&list)
		defer context_destroy(&ctx)

		words, werr := selectors_select_nested_words(&ctx, 0, {.To_Begin, .To_End}, .Word, alloc)
		testing.expect_value(t, werr, Selectors_Error.None)
		selectors_test_free_all(&words, alloc)

		nums, nerr := selectors_select_nested_numbers(&ctx, 0, {.To_Begin, .To_End}, alloc)
		testing.expect_value(t, nerr, Selectors_Error.None)
		selectors_test_free_all(&nums, alloc)

		bar_re, bar_msg, bar_err := regex_make("bar|qux", {.Backward}, alloc)
		if len(bar_msg) > 0 {
			defer delete(bar_msg, alloc)
		}
		testing.expect_value(t, bar_err, Regex_Error.None)
		defer regex_destroy(&bar_re)
		found, _, ferr := selectors_find_next_match(&ctx, sels[0], &bar_re, true, alloc)
		testing.expect_value(t, ferr, Selectors_Error.None)
		selection_destroy(&found, alloc)

		matches, merr := selectors_select_matches(b, sels[:], &bar_re, 0, alloc)
		testing.expect_value(t, merr, Selectors_Error.None)
		selectors_test_free_all(&matches, alloc)

		parts, perr := selectors_split_on_matches(b, sels[:], &bar_re, 0, alloc)
		testing.expect_value(t, perr, Selectors_Error.None)
		selectors_test_free_all(&parts, alloc)

		open_re, open_msg, open_err := regex_make("\\Q(", {.Backward}, alloc)
		if len(open_msg) > 0 {
			defer delete(open_msg, alloc)
		}
		testing.expect_value(t, open_err, Regex_Error.None)
		defer regex_destroy(&open_re)
		close_re, close_msg, close_err := regex_make("\\Q)", {.Backward}, alloc)
		if len(close_msg) > 0 {
			defer delete(close_msg, alloc)
		}
		testing.expect_value(t, close_err, Regex_Error.None)
		defer regex_destroy(&close_re)
		_, ok := selectors_select_surrounding(&ctx, selectors_test_sel({0, 10}, {0, 10}), &open_re, &close_re, 0, {.To_Begin, .To_End}, alloc)
		testing.expect(t, ok)

		nested, rgx_err := selectors_regex_select_nested(&ctx, &open_re, &close_re, 0, {.To_Begin, .To_End}, alloc)
		testing.expect_value(t, rgx_err, Selectors_Error.None)
		selectors_test_free_all(&nested, alloc)
	}
	testing.expect_value(t, len(track.allocation_map), 0)
}
