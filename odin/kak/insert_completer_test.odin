// Tests for the insert_completer port. No C++ UnitTest exists for this
// module, so these are edge-case tests over the standalone-testable
// surface: nothing here touches a STUBBED proc (word_db, buffer_utils,
// buffer manager singletons) or a real Context/Client.
package kak

import "core:mem"
import "core:strings"
import "core:testing"

// insert_completer_test_candidate builds a synthetic candidate with owned
// (cloned) strings and atoms atoms aliasing the completion, following the
// module ownership rules. Uses context.allocator.
insert_completer_test_candidate :: proc(completion: string, on_select := "", atoms := 1) -> Insert_Completion_Candidate {
	comp := ""
	if len(completion) > 0 {
		comp = strings.clone(completion)
	}
	sel := ""
	if len(on_select) > 0 {
		sel = strings.clone(on_select)
	}
	entry := display_buffer_line_make()
	for _ in 0 ..< atoms {
		display_buffer_line_push_back(&entry, display_buffer_atom_text(comp, Face{}))
	}
	return Insert_Completion_Candidate{completion = comp, on_select = sel, menu_entry = entry}
}

@(test)
test_insert_completer_empty_state :: proc(t: ^testing.T) {
	c := Insert_Completer{}
	testing.expect(t, !insert_completer_has_candidate_selected(&c))

	// Everything is a safe no-op with no candidates and no context.
	insert_completer_try_accept(&c)
	insert_completer_reset(&c)
	insert_completer_select(&c, 1, true, nil, nil)
	insert_completer_select(&c, 0, false, nil, nil)
	insert_completer_update(&c, true)
	testing.expect(t, c.enabled)
	insert_completer_update(&c, false)
	testing.expect(t, !c.enabled)

	testing.expect_value(t, len(c.completions.candidates), 0)
	testing.expect(t, c.explicit_completer == nil)
	testing.expect_value(t, len(c.inserted_ranges), 0)
	// Zero value (make() initializes -1); untouched by the no-ops above.
	testing.expect_value(t, c.current_candidate, 0)

	insert_completer_destroy(&c)
}

@(test)
test_insert_completer_wrap_index :: proc(t: ^testing.T) {
	// {current, index, relative, count, want}; (-4 % 3) + 3 = 2 pins the
	// C++ single negative adjustment.
	flat := [][5]int{
		{0, 1, 1, 3, 1}, {2, 1, 1, 3, 0}, {0, -1, 1, 3, 2}, {1, -1, 1, 3, 0},
		{0, 1, 0, 3, 1}, {2, 0, 0, 3, 0}, {0, -1, 0, 3, 2}, {1, 5, 0, 3, 2},
		{0, -4, 1, 3, 2}, {0, 0, 1, 1, 0}, {0, 7, 1, 1, 0},
		{3, 2, 1, 4, 1}, {3, -2, 1, 4, 1},
	}
	for f in flat {
		got := insert_completer_wrap_index(f[0], f[1], f[2] == 1, f[3])
		testing.expect_value(t, got, f[4])
	}
	// Defensive: C++ would divide by zero.
	testing.expect_value(t, insert_completer_wrap_index(0, 1, true, 0), 0)
}

@(test)
test_insert_completer_single_candidate_accept :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	alloc := mem.tracking_allocator(&track)
	defer mem.tracking_allocator_destroy(&track)

	{
		context.allocator = alloc
		c := Insert_Completer{}

		// A lone entry is the unmodified original text: not "selected".
		append(&c.completions.candidates, insert_completer_test_candidate("orig"))
		c.current_candidate = 0
		testing.expect(t, !insert_completer_has_candidate_selected(&c))
		insert_completer_try_accept(&c)
		testing.expect_value(t, len(c.completions.candidates), 1)

		// Completion + original: current on the original is not selected.
		insert_completer_reset(&c)
		append(&c.completions.candidates, insert_completer_test_candidate("completion"))
		append(&c.completions.candidates, insert_completer_test_candidate("orig"))
		c.current_candidate = 1
		testing.expect(t, !insert_completer_has_candidate_selected(&c))
		insert_completer_try_accept(&c)
		testing.expect_value(t, len(c.completions.candidates), 2)

		// Current on the completion: accept clears everything.
		c.current_candidate = 0
		testing.expect(t, insert_completer_has_candidate_selected(&c))
		insert_completer_try_accept(&c)
		testing.expect_value(t, len(c.completions.candidates), 0)
		testing.expect(t, c.explicit_completer == nil)
		testing.expect_value(t, len(c.inserted_ranges), 0)

		insert_completer_destroy(&c)
	}

	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_insert_completer_reset_clears :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	alloc := mem.tracking_allocator(&track)
	defer mem.tracking_allocator_destroy(&track)

	{
		context.allocator = alloc
		c := Insert_Completer{}
		append(&c.completions.candidates, insert_completer_test_candidate("foo", "select-cmd", 2))
		append(&c.completions.candidates, insert_completer_test_candidate("fo"))
		c.current_candidate = 0
		c.explicit_completer = insert_completer_complete_word_buffer
		append(&c.inserted_ranges, Buffer_Range{{0, 0}, {0, 3}})
		append(&c.inserted_ranges, Buffer_Range{{1, 0}, {1, 3}})

		insert_completer_reset(&c)

		testing.expect_value(t, len(c.completions.candidates), 0)
		testing.expect(t, c.explicit_completer == nil)
		testing.expect_value(t, len(c.inserted_ranges), 0)
		// current_candidate is untouched by reset (C++ parity).
		testing.expect_value(t, c.current_candidate, 0)

		// Second reset is a no-op.
		insert_completer_reset(&c)
		testing.expect_value(t, len(c.completions.candidates), 0)

		insert_completer_destroy(&c)
	}

	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_insert_completer_destroy_frees :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	alloc := mem.tracking_allocator(&track)
	defer mem.tracking_allocator_destroy(&track)

	{
		context.allocator = alloc
		c := Insert_Completer{}
		append(&c.completions.candidates, insert_completer_test_candidate("alpha", "", 3))
		append(&c.completions.candidates, insert_completer_test_candidate("beta", "run-me", 1))
		append(&c.completions.candidates, insert_completer_test_candidate(""))
		c.current_candidate = 1
		c.explicit_completer = insert_completer_complete_line_all
		append(&c.inserted_ranges, Buffer_Range{{2, 1}, {2, 9}})
		c.completions.timestamp = 7

		insert_completer_destroy(&c)
	}

	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
}

@(test)
test_insert_completer_scan_word :: proc(t: ^testing.T) {
	extra := []rune{'_'}
	none := []rune{}

	Case :: struct {
		line:                 string,
		col:                  int,
		first:                bool,
		begin, end, checked:  int,
	}
	word_cases := []Case{
		{"hello world", 5, true, 0, 5, 6},
		{"hello world", 11, true, 6, 11, 7},
		{"hello world", 0, true, 0, 5, 7},
		{"hello world", 5, false, 0, 5, 8},
		{"foo_bar", 7, true, 0, 7, 7},
		{"a b", 2, true, 2, 3, 3},
		{"héllo", 6, true, 0, 6, 5},
		{"", 0, true, 0, 0, 1},
		{"", 0, false, 0, 0, 2},
	}
	for cs in word_cases {
		b, e, n := insert_completer_scan_word(cs.line, cs.col, cs.first, extra)
		testing.expect_value(t, b, cs.begin)
		testing.expect_value(t, e, cs.end)
		testing.expect_value(t, n, cs.checked)
	}

	// Without '_' as a word char the scan stops at it.
	b, e, n := insert_completer_scan_word("foo_bar", 7, true, none)
	testing.expect_value(t, b, 4)
	testing.expect_value(t, e, 7)
	testing.expect_value(t, n, 5)

	// Overlong words still scan (the caller gates on checked > 100).
	long := strings.repeat("x", 150, context.temp_allocator)
	b, e, n = insert_completer_scan_word(long, 150, true, extra)
	testing.expect_value(t, b, 0)
	testing.expect_value(t, e, 150)
	testing.expect_value(t, n, 150)
	testing.expect(t, n > word_splitter_MAX_WORD_LEN)

	// Boundaries always equal the naive maximal word-char run around the
	// cursor (the tricky counting above only feeds the length gate).
	naive_begin := proc(s: string, col: int, extra: []rune) -> int {
		p := col
		for p > 0 {
			q := utf8_previous(s, p)
			if !unicode_is_word(utf8_codepoint(s, q), extra) {
				break
			}
			p = q
		}
		return p
	}
	naive_end := proc(s: string, col: int, extra: []rune) -> int {
		p := col
		for p < len(s) {
			if !unicode_is_word(utf8_codepoint(s, p), extra) {
				break
			}
			_, p = string_utils_read_codepoint(s, p)
		}
		return p
	}
	lines := []string{
		"hello world",
		"  spaced  out  ",
		"foo_bar baz_qux",
		"a",
		"",
		"héllo wörld",
		"mix3d c4se!",
		"\tindented\n",
	}
	firsts := []bool{true, false}
	for line in lines {
		for first in firsts {
			// Every byte offset, including mid-codepoint ones.
			for col := 0; col <= len(line); col += 1 {
				want_b := naive_begin(line, col, extra)
				want_e := naive_end(line, col, extra)
				// Mid-codepoint columns are garbage-in; only check
				// codepoint boundaries against the model.
				boundary := col == 0 || col == len(line) || utf8_is_character_start(line[col])
				got_b, got_e, _ := insert_completer_scan_word(line, col, first, extra)
				if boundary {
					testing.expect_value(t, got_b, want_b)
					testing.expect_value(t, got_e, want_e)
				}
				// Word slices are always well-formed ranges.
				testing.expect(t, got_b >= 0 && got_b <= got_e && got_e <= len(line))
			}
		}
	}
}

@(test)
test_insert_completer_parse_option_prefix :: proc(t: ^testing.T) {
	p, err := insert_completer_parse_option_prefix("10.20@30")
	testing.expect_value(t, err, Insert_Completer_Error.None)
	testing.expect_value(t, p.line, 9)
	testing.expect_value(t, p.col, 19)
	testing.expect(t, !p.has_len)
	testing.expect_value(t, p.timestamp, 30)

	p, err = insert_completer_parse_option_prefix("1.1+5@99")
	testing.expect_value(t, err, Insert_Completer_Error.None)
	testing.expect_value(t, p.line, 0)
	testing.expect_value(t, p.col, 0)
	testing.expect(t, p.has_len)
	testing.expect_value(t, p.len, Units_ByteCount(5))
	testing.expect_value(t, p.timestamp, 99)

	p, err = insert_completer_parse_option_prefix("12.34+56@78")
	testing.expect_value(t, err, Insert_Completer_Error.None)
	testing.expect_value(t, p.line, 11)
	testing.expect_value(t, p.col, 33)
	testing.expect_value(t, p.len, Units_ByteCount(56))
	testing.expect_value(t, p.timestamp, 78)

	bads := []string{
		"",
		"abc",
		"0.1@2",
		"1.0@2",
		"1.2@3x",
		"1.2@3 ",
		"1.2+@3",
		"1.2@",
		"1.2",
		"+1.2@3",
		"1.2@-3",
		"1.@2",
		".1@2",
	}
	for bad in bads {
		_, err = insert_completer_parse_option_prefix(bad)
		testing.expect_value(t, err, Insert_Completer_Error.Invalid_Prefix)
	}
}

@(test)
test_insert_completer_push_expanded_atoms :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	alloc := mem.tracking_allocator(&track)
	defer mem.tracking_allocator_destroy(&track)

	{
		context.allocator = alloc

		line := display_buffer_line_make()
		end := insert_completer_push_expanded_atoms(&line, "a\tb", Face{}, 8, 0)
		testing.expect_value(t, len(line.atoms), 3)
		testing.expect_value(t, line.atoms[0].text, "a")
		testing.expect_value(t, line.atoms[1].text, "       ")
		testing.expect_value(t, line.atoms[2].text, "b")
		testing.expect_value(t, end, 9)
		// Rendered text matches expand_tabs exactly.
		rendered := strings.concatenate(
			[]string{line.atoms[0].text, line.atoms[1].text, line.atoms[2].text},
		)
		expanded := string_utils_expand_tabs("a\tb", 8, 0)
		testing.expect_value(t, rendered, expanded)
		delete(rendered)
		delete(expanded)
		display_buffer_line_destroy(&line)

		line2 := display_buffer_line_make()
		end = insert_completer_push_expanded_atoms(&line2, "xy", Face{}, 8, 3)
		testing.expect_value(t, len(line2.atoms), 1)
		testing.expect_value(t, line2.atoms[0].text, "xy")
		testing.expect_value(t, end, 5)
		display_buffer_line_destroy(&line2)

		line3 := display_buffer_line_make()
		end = insert_completer_push_expanded_atoms(&line3, "a\t", Face{}, 4, 0)
		testing.expect_value(t, len(line3.atoms), 2)
		testing.expect_value(t, line3.atoms[1].text, "   ")
		testing.expect_value(t, end, 4)
		display_buffer_line_destroy(&line3)

		line4 := display_buffer_line_make()
		end = insert_completer_push_expanded_atoms(&line4, "", Face{}, 8, 2)
		testing.expect_value(t, len(line4.atoms), 0)
		testing.expect_value(t, end, 2)
		display_buffer_line_destroy(&line4)
	}

	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_insert_completer_shorten_display_name :: proc(t: ^testing.T) {
	ellipsis, suffix := insert_completer_shorten_display_name("short", 20)
	testing.expect(t, !ellipsis)
	testing.expect_value(t, suffix, "short")

	exact := "12345678901234567890"
	ellipsis, suffix = insert_completer_shorten_display_name(exact, 20)
	testing.expect(t, !ellipsis)
	testing.expect_value(t, suffix, exact)

	ellipsis, suffix = insert_completer_shorten_display_name("abcdefghijklmnopqrstuvwxyz", 20)
	testing.expect(t, ellipsis)
	testing.expect_value(t, suffix, "fghijklmnopqrstuvwxyz")

	// Exactly max_cols + 1 columns keeps the whole name plus the marker
	// (C++ limit quirk: from = total - (max + 1) = 0).
	ellipsis, suffix = insert_completer_shorten_display_name("123456789012345678901", 20)
	testing.expect(t, ellipsis)
	testing.expect_value(t, suffix, "123456789012345678901")
}
