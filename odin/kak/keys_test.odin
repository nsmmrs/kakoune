// Port of the test_keys UnitTest from src/keys.cc plus edge cases.
package kak

import "core:strings"
import "core:testing"

// Parses s, expects success, and compares against want.
keys_check_parse :: proc(t: ^testing.T, s: string, want: ..Keys_Key) {
	got, err := keys_parse(s)
	defer delete(got)
	testing.expect_value(t, err, Keys_Error.None)
	testing.expect_value(t, len(got), len(want))
	for i in 0 ..< min(len(got), len(want)) {
		testing.expect_value(t, got[i], want[i])
	}
}

// Prints key and compares against want.
keys_check_print :: proc(t: ^testing.T, key: Keys_Key, want: string) {
	got := keys_to_string_key(key)
	defer delete(got)
	testing.expect_value(t, got, want)
}

// Parses s and expects the given error.
keys_check_error :: proc(t: ^testing.T, s: string, want: Keys_Error) {
	got, err := keys_parse(s)
	defer delete(got)
	testing.expect_value(t, err, want)
}

@(test)
keys_test_round_trip :: proc(t: ^testing.T) {
	keys := [10]Keys_Key{
		{key = keys_SPACE},
		{key = 'c'},
		{key = keys_UP},
		keys_alt(Keys_Key{key = 'j'}),
		keys_ctrl(Keys_Key{key = 'r'}),
		keys_shift(Keys_Key{key = keys_UP}),
		keys_ctrl(Keys_Key{key = '['}),
		keys_ctrl(Keys_Key{key = '\\'}),
		keys_ctrl(Keys_Key{key = ']'}),
		keys_ctrl(Keys_Key{key = '_'}),
	}
	sb := strings.builder_make(context.allocator)
	defer strings.builder_destroy(&sb)
	for k in keys {
		s := keys_to_string_key(k)
		strings.write_string(&sb, s)
		delete(s)
	}
	testing.expect_value(
		t,
		strings.to_string(sb),
		"<space>c<up><a-j><c-r><s-up><c-[><c-\\><c-]><c-_>",
	)
	parsed, err := keys_parse(strings.to_string(sb))
	defer delete(parsed)
	testing.expect_value(t, err, Keys_Error.None)
	testing.expect_value(t, len(parsed), len(keys))
	for i in 0 ..< min(len(parsed), len(keys)) {
		testing.expect_value(t, parsed[i], keys[i])
	}
}

@(test)
keys_test_parse :: proc(t: ^testing.T) {
	keys_check_parse(
		t,
		"a<c-a-b>c",
		{key = 'a'},
		keys_ctrl(keys_alt(Keys_Key{key = 'b'})),
		{key = 'c'},
	)
	keys_check_parse(t, "x", {key = 'x'})
	keys_check_parse(t, "<x>", {key = 'x'})
	keys_check_parse(t, "<s-x>", {key = 'X'})
	keys_check_parse(t, "<s-X>", {key = 'X'})
	keys_check_parse(t, "<X>", {key = 'X'})
	keys_check_parse(t, "X", {key = 'X'})
	keys_check_parse(t, "<s-up>", keys_shift(Keys_Key{key = keys_UP}))
	keys_check_parse(t, "<s-tab>", keys_shift(Keys_Key{key = keys_TAB}))
	keys_check_parse(t, "\n", {key = keys_RETURN})
}

@(test)
keys_test_parse_errors :: proc(t: ^testing.T) {
	cases := [9]string{
		"<-x>",
		"<xy-z>",
		"<x-y>",
		"<s-/>",
		"<s-ë>",
		"<s-lt>",
		"<f99>",
		"<backtab>",
		"<invalidkey>",
	}
	for s in cases {
		keys_check_error(t, s, Keys_Error.Parse_Error)
	}
}

@(test)
keys_test_print_shift_tab :: proc(t: ^testing.T) {
	keys_check_print(t, keys_shift(Keys_Key{key = keys_TAB}), "<s-tab>")
}

@(test)
keys_test_function_keys :: proc(t: ^testing.T) {
	keys_check_parse(t, "<F1>", {key = keys_F1})
	keys_check_parse(t, "<F12>", {key = keys_F12})
	keys_check_parse(t, "<F5>", {key = keys_F5})
	keys_check_parse(t, "<s-F5>", Keys_Key{keys_MOD_SHIFT, keys_F5})
	keys_check_parse(t, "<c-a-F12>", Keys_Key{keys_MOD_CONTROL | keys_MOD_ALT, keys_F12})
	keys_check_print(t, Keys_Key{key = keys_F1}, "<F1>")
	keys_check_print(t, Keys_Key{key = keys_F12}, "<F12>")
	keys_check_print(t, Keys_Key{keys_MOD_SHIFT, keys_F5}, "<s-F5>")
	keys_check_error(t, "<F0>", Keys_Error.Parse_Error)
	keys_check_error(t, "<F13>", Keys_Error.Parse_Error)
	keys_check_error(t, "<F123>", Keys_Error.Parse_Error)
	keys_check_error(t, "<f1>", Keys_Error.Parse_Error)
	// Non-numeric F-key numbers fail number conversion, matching the
	// runtime_error (not key_parse_error) thrown by str_to_int in C++.
	keys_check_error(t, "<Fg>", Keys_Error.Not_A_Number)
	keys_check_error(t, "<F1x>", Keys_Error.Not_A_Number)
	// A lone F is a single character, not an F-key.
	keys_check_parse(t, "<F>", {key = 'F'})
}

@(test)
keys_test_modifiers :: proc(t: ^testing.T) {
	// Modifier letters are case insensitive.
	keys_check_parse(t, "<C-x>", Keys_Key{keys_MOD_CONTROL, 'x'})
	keys_check_parse(t, "<A-J>", Keys_Key{keys_MOD_ALT, 'J'})
	keys_check_parse(
		t,
		"<C-A-X>",
		Keys_Key{keys_MOD_CONTROL | keys_MOD_ALT, 'X'},
	)
	// Shift folds into uppercase letters, other modifiers are kept.
	keys_check_parse(t, "<c-s-x>", Keys_Key{keys_MOD_CONTROL, 'X'})
	keys_check_parse(
		t,
		"<a-s-x>",
		Keys_Key{keys_MOD_ALT, 'X'},
	)
	keys_check_parse(t, "<c-a-s-x>", Keys_Key{keys_MOD_CONTROL | keys_MOD_ALT, 'X'})
	keys_check_print(t, Keys_Key{keys_MOD_CONTROL | keys_MOD_ALT, 'X'}, "<c-a-X>")
	// Shift survives on special keys only.
	keys_check_parse(
		t,
		"<a-s-up>",
		Keys_Key{keys_MOD_ALT | keys_MOD_SHIFT, keys_UP},
	)
	keys_check_print(t, Keys_Key{keys_MOD_ALT | keys_MOD_SHIFT, keys_UP}, "<a-s-up>")
	keys_check_error(t, "<s-plus>", Keys_Error.Parse_Error)
	keys_check_parse(t, "<s-space>", Keys_Key{keys_MOD_SHIFT, keys_SPACE})
	keys_check_print(t, Keys_Key{keys_MOD_SHIFT, keys_SPACE}, "<s-space>")
}

@(test)
keys_test_special_names :: proc(t: ^testing.T) {
	keys_check_parse(t, "<ret>", {key = keys_RETURN})
	keys_check_parse(t, "<esc>", {key = keys_ESCAPE})
	keys_check_parse(t, "<backspace>", {key = keys_BACKSPACE})
	keys_check_parse(t, "<del>", {key = keys_DELETE})
	keys_check_parse(t, "<ins>", {key = keys_INSERT})
	keys_check_parse(t, "<home>", {key = keys_HOME})
	keys_check_parse(t, "<end>", {key = keys_END})
	keys_check_parse(t, "<pageup>", {key = keys_PAGE_UP})
	keys_check_parse(t, "<pagedown>", {key = keys_PAGE_DOWN})
	keys_check_parse(t, "<left>", {key = keys_LEFT})
	keys_check_parse(t, "<right>", {key = keys_RIGHT})
	keys_check_parse(t, "<down>", {key = keys_DOWN})
	keys_check_parse(t, "<lt>", {key = '<'})
	keys_check_parse(t, "<gt>", {key = '>'})
	keys_check_parse(t, "<plus>", {key = '+'})
	keys_check_parse(t, "<minus>", {key = '-'})
	keys_check_parse(t, "<semicolon>", {key = ';'})
	keys_check_parse(t, "<percent>", {key = '%'})
	keys_check_parse(t, "<quote>", {key = '\''})
	keys_check_parse(t, "<dquote>", {key = '"'})
	keys_check_parse(t, "<focus_in>", {key = keys_FOCUS_IN})
	keys_check_parse(t, "<focus_out>", {key = keys_FOCUS_OUT})
	keys_check_print(t, Keys_Key{key = keys_RETURN}, "<ret>")
	keys_check_print(t, Keys_Key{key = '<'}, "<lt>")
	keys_check_print(t, Keys_Key{key = '>'}, "<gt>")
	keys_check_print(t, Keys_Key{key = '+'}, "<plus>")
	keys_check_print(t, Keys_Key{key = '-'}, "<minus>")
	keys_check_print(t, Keys_Key{key = keys_FOCUS_IN}, "<focus_in>")
	// Single printable characters print bare.
	keys_check_print(t, Keys_Key{key = 'x'}, "x")
	keys_check_print(t, Keys_Key{key = 'X'}, "X")
	keys_check_print(t, Keys_Key{key = 'é'}, "é")
	// Raw control characters map to named keys.
	keys_check_parse(t, "\r", {key = keys_RETURN})
	keys_check_parse(t, "\t", {key = keys_TAB})
	keys_check_parse(t, " ", {key = keys_SPACE})
	keys_check_parse(t, "\x1b", {key = keys_ESCAPE})
	keys_check_parse(t, "\x08", {key = keys_BACKSPACE})
	keys_check_print(t, Keys_Key{key = keys_TAB}, "<tab>")
	keys_check_print(t, Keys_Key{key = keys_SPACE}, "<space>")
	keys_check_print(t, Keys_Key{key = keys_ESCAPE}, "<esc>")
}

@(test)
keys_test_control_chars :: proc(t: ^testing.T) {
	// Control characters in <...> canonicalize to ctrl+letter ...
	keys_check_parse(t, "<\x01>", Keys_Key{keys_MOD_CONTROL, 'a'})
	keys_check_parse(t, "<\x1a>", Keys_Key{keys_MOD_CONTROL, 'z'})
	// ... but pass through untouched outside <...>.
	keys_check_parse(t, "\x01", {key = 0x01})
	keys_check_parse(t, "\x1a", {key = 0x1a})
}

@(test)
keys_test_brackets :: proc(t: ^testing.T) {
	// A '<' without a closing '>' is literal.
	keys_check_parse(t, "a<b", {key = 'a'}, {key = '<'}, {key = 'b'})
	keys_check_parse(t, "<", {key = '<'})
	keys_check_parse(t, "<<", {key = '<'}, {key = '<'})
	keys_check_parse(t, "a<", {key = 'a'}, {key = '<'})
	// Empty descriptions are an error.
	keys_check_error(t, "<>", Keys_Error.Parse_Error)
	keys_check_error(t, "<c->", Keys_Error.Parse_Error)
	// Empty input parses to an empty list.
	keys_check_parse(t, "")
	// A '>' outside <...> is literal.
	keys_check_parse(t, "a>b", {key = 'a'}, {key = '>'}, {key = 'b'})
}

@(test)
keys_test_codepoint :: proc(t: ^testing.T) {
	cp, ok := keys_codepoint(Keys_Key{key = keys_RETURN})
	testing.expect(t, ok)
	testing.expect_value(t, cp, '\n')
	cp, ok = keys_codepoint(Keys_Key{key = keys_TAB})
	testing.expect(t, ok)
	testing.expect_value(t, cp, '\t')
	cp, ok = keys_codepoint(Keys_Key{key = keys_SPACE})
	testing.expect(t, ok)
	testing.expect_value(t, cp, ' ')
	cp, ok = keys_codepoint(Keys_Key{keys_MOD_SHIFT, keys_SPACE})
	testing.expect(t, ok)
	testing.expect_value(t, cp, ' ')
	cp, ok = keys_codepoint(Keys_Key{key = keys_ESCAPE})
	testing.expect(t, ok)
	testing.expect_value(t, cp, rune(0x1B))
	cp, ok = keys_codepoint(Keys_Key{key = 'a'})
	testing.expect(t, ok)
	testing.expect_value(t, cp, 'a')
	cp, ok = keys_codepoint(Keys_Key{key = 'é'})
	testing.expect(t, ok)
	testing.expect_value(t, cp, 'é')
	// 27 is excluded, 28 is the first plain codepoint.
	_, ok = keys_codepoint(Keys_Key{key = 27})
	testing.expect(t, !ok)
	cp, ok = keys_codepoint(Keys_Key{key = 28})
	testing.expect(t, ok)
	testing.expect_value(t, cp, rune(28))
	// Modifiers (other than shift+space) and special keys have none.
	_, ok = keys_codepoint(Keys_Key{key = keys_UP})
	testing.expect(t, !ok)
	_, ok = keys_codepoint(keys_ctrl(Keys_Key{key = 'a'}))
	testing.expect(t, !ok)
	_, ok = keys_codepoint(Keys_Key{keys_MOD_ALT, keys_RETURN})
	testing.expect(t, !ok)
}

@(test)
keys_test_mouse_scroll_resize :: proc(t: ^testing.T) {
	keys_check_print(t, keys_resize(Keys_Coord{9, 4}), "<resize:10.5>")
	press := Keys_Key{
		keys_MOD_MOUSE_PRESS | keys_button_modifier(Keys_Mouse_Button.Left),
		keys_encode_coord(Keys_Coord{0, 0}),
	}
	keys_check_print(t, press, "<mouse:press:left:1.1>")
	testing.expect_value(t, keys_mouse_button(press), Keys_Mouse_Button.Left)
	release := Keys_Key{
		keys_MOD_MOUSE_RELEASE | keys_button_modifier(Keys_Mouse_Button.Right),
		keys_encode_coord(Keys_Coord{2, 5}),
	}
	keys_check_print(t, release, "<mouse:release:right:3.6>")
	testing.expect_value(t, keys_mouse_button(release), Keys_Mouse_Button.Right)
	move := Keys_Key{keys_MOD_MOUSE_POS, keys_encode_coord(Keys_Coord{7, 1})}
	keys_check_print(t, move, "<mouse:move:8.2>")
	scroll_down := Keys_Key{
		keys_MOD_SCROLL | Keys_Modifiers(3 << 16),
		keys_encode_coord(Keys_Coord{2, 3}),
	}
	keys_check_print(t, scroll_down, "<scroll:3:3.4>")
	testing.expect_value(t, keys_scroll_amount(scroll_down), 3)
	scroll_up := Keys_Key{
		keys_MOD_SCROLL | Keys_Modifiers(-3 << 16),
		keys_encode_coord(Keys_Coord{2, 3}),
	}
	keys_check_print(t, scroll_up, "<scroll:-3:3.4>")
	testing.expect_value(t, keys_scroll_amount(scroll_up), -3)
	// Button modifiers round trip through mouse_button.
	for button in Keys_Mouse_Button {
		key := Keys_Key{keys_button_modifier(button), keys_encode_coord(Keys_Coord{0, 0})}
		testing.expect_value(t, keys_mouse_button(key), button)
	}
	// Coord encoding round trips, including negative lines.
	testing.expect_value(t, keys_coord(Keys_Key{key = keys_encode_coord(Keys_Coord{5, 7})}), Keys_Coord{5, 7})
	testing.expect_value(
		t,
		keys_coord(Keys_Key{key = keys_encode_coord(Keys_Coord{-2, 3})}),
		Keys_Coord{-2, 3},
	)
}

@(test)
keys_test_buttons :: proc(t: ^testing.T) {
	testing.expect_value(t, keys_button_to_string(Keys_Mouse_Button.Left), "left")
	testing.expect_value(t, keys_button_to_string(Keys_Mouse_Button.Middle), "middle")
	testing.expect_value(t, keys_button_to_string(Keys_Mouse_Button.Right), "right")
	button, err := keys_string_to_button("left")
	testing.expect_value(t, err, Keys_Error.None)
	testing.expect_value(t, button, Keys_Mouse_Button.Left)
	button, err = keys_string_to_button("middle")
	testing.expect_value(t, err, Keys_Error.None)
	testing.expect_value(t, button, Keys_Mouse_Button.Middle)
	button, err = keys_string_to_button("right")
	testing.expect_value(t, err, Keys_Error.None)
	testing.expect_value(t, button, Keys_Mouse_Button.Right)
	_, err = keys_string_to_button("wheel")
	testing.expect_value(t, err, Keys_Error.Bad_Button)
	_, err = keys_string_to_button("")
	testing.expect_value(t, err, Keys_Error.Bad_Button)
}

@(test)
keys_test_val :: proc(t: ^testing.T) {
	testing.expect_value(t, keys_val(Keys_Key{key = 'a'}), u64(97))
	testing.expect_value(
		t,
		keys_val(Keys_Key{keys_MOD_CONTROL, 'a'}),
		(u64(1) << 32) | u64(97),
	)
	testing.expect(
		t,
		keys_val(Keys_Key{key = 'a'}) < keys_val(Keys_Key{key = 'b'}),
	)
}
