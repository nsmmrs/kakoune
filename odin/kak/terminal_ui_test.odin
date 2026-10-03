// Tests for the terminal_ui module. No C++ UnitTest exists for
// src/terminal_ui.cc, so these are edge-case tests written from the
// C++ behavior: atom/line/window handling, SGR face output,
// incremental screen output, escape-sequence parsing (including
// truncated and garbage input), resize, menu/info rendering, options,
// and allocator cleanup. Nothing here touches a real tty: input is
// fed as byte strings and output is captured from the UI's buffer.
package kak

import "core:mem"
import "core:strings"
import "core:testing"

// terminal_ui_test_line builds a single-atom display line fixture.
terminal_ui_test_line :: proc(text: string, allocator := context.allocator) -> Display_Line {
	line := display_buffer_line_make(allocator)
	display_buffer_line_insert(&line, 0, display_buffer_atom_text(text, Face{}))
	return line
}

// terminal_ui_test_parse feeds input (final) and collects all events.
// Paste contents must be freed by the caller.
terminal_ui_test_parse :: proc(
	t: ^testing.T,
	input: string,
	allocator := context.allocator,
) -> (events: [dynamic]Terminal_UI_Event, leftover: int) {
	parser := terminal_ui_parser_make(allocator)
	defer terminal_ui_parser_destroy(&parser)
	terminal_ui_parser_feed(&parser, transmute([]u8)input)
	events = make([dynamic]Terminal_UI_Event, 0, allocator)
	for {
		event, ok := terminal_ui_parser_next(&parser, true, allocator)
		if !ok {
			break
		}
		append(&events, event)
	}
	leftover = len(parser.input)
	return events, leftover
}

terminal_ui_test_free_events :: proc(events: ^[dynamic]Terminal_UI_Event, allocator := context.allocator) {
	for event in events^ {
		if paste, is_paste := event.(Terminal_UI_Paste); is_paste {
			delete(paste.content, allocator)
		}
	}
	delete(events^)
}

terminal_ui_test_key :: proc(t: ^testing.T, event: Terminal_UI_Event) -> Keys_Key {
	key, ok := event.(Keys_Key)
	testing.expect(t, ok)
	return key
}

// terminal_ui_test_ui builds a sized UI with the resize event cleared.
terminal_ui_test_ui :: proc(rows, cols: int, allocator := context.allocator) -> Terminal_UI {
	ui := terminal_ui_make(allocator)
	terminal_ui_apply_size(&ui, rows, cols)
	ui.resize_pending = false
	return ui
}

// terminal_ui_test_options builds a UI options map from key/value pairs.
terminal_ui_test_options :: proc(pairs: ..string, allocator := context.allocator) -> User_Interface_Options {
	options := make(User_Interface_Options, len(pairs) / 2, allocator)
	for i := 0; i + 1 < len(pairs); i += 2 {
		options[pairs[i]] = pairs[i + 1]
	}
	return options
}

// terminal_ui_test_buffer builds a display buffer fixture; the caller
// owns the line list and must delete it.
terminal_ui_test_buffer :: proc(lines: ..Display_Line, allocator := context.allocator) -> Display_Buffer {
	list := make(Display_Line_List, len(lines), allocator)
	copy(list[:], lines)
	return Display_Buffer{lines = list}
}

// terminal_ui_test_want maps a case name to its expected key.
terminal_ui_test_want :: proc(name: string) -> Keys_Key {
	switch name {
	case "home":
		return {key = keys_HOME}
	case "end":
		return {key = keys_END}
	case "ins":
		return {key = keys_INSERT}
	case "del":
		return {key = keys_DELETE}
	case "pageup":
		return {key = keys_PAGE_UP}
	case "pagedown":
		return {key = keys_PAGE_DOWN}
	case "f1":
		return {key = keys_F1}
	case "f5":
		return {key = keys_F5}
	case "f6":
		return {key = keys_F6}
	case "f12":
		return {key = keys_F12}
	case "shift-tab":
		return {modifiers = keys_MOD_SHIFT, key = keys_TAB}
	case "focus-in":
		return {key = keys_FOCUS_IN}
	case "focus-out":
		return {key = keys_FOCUS_OUT}
	}
	return {}
}

@(test)
test_terminal_ui_fix_atom_text :: proc(t: ^testing.T) {
	fixed := terminal_ui_fix_atom_text("a\x01b\x7f", context.allocator)
	defer delete(fixed)
	testing.expect_value(t, fixed, "a␁b\x7f")
	plain := terminal_ui_fix_atom_text("hello", context.allocator)
	defer delete(plain)
	testing.expect_value(t, plain, "hello")
	nul := terminal_ui_fix_atom_text("\x00\x1b", context.allocator)
	defer delete(nul)
	testing.expect_value(t, nul, "␀␛")
}

@(test)
test_terminal_ui_atom_resize :: proc(t: ^testing.T) {
	atom := Terminal_UI_Atom{text = strings.clone("hello")}
	terminal_ui_atom_resize(&atom, 3)
	testing.expect_value(t, atom.text, "hel")
	testing.expect_value(t, atom.skip, Coord_Column(0))
	terminal_ui_atom_resize(&atom, 8)
	testing.expect_value(t, atom.text, "hel")
	testing.expect_value(t, atom.skip, Coord_Column(5))
	testing.expect_value(t, terminal_ui_atom_length(atom), Coord_Column(8))
	delete(atom.text)

	wide := Terminal_UI_Atom{text = strings.clone("あ")}
	testing.expect_value(t, terminal_ui_atom_length(wide), Coord_Column(2))
	terminal_ui_atom_resize(&wide, 1)
	testing.expect_value(t, wide.text, "")
	testing.expect_value(t, wide.skip, Coord_Column(1))
	delete(wide.text)

	mixed := Terminal_UI_Atom{text = strings.clone("aあ")}
	terminal_ui_atom_resize(&mixed, 2)
	testing.expect_value(t, mixed.text, "a")
	testing.expect_value(t, mixed.skip, Coord_Column(1))
	delete(mixed.text)
}

@(test)
test_terminal_ui_line_append_merge :: proc(t: ^testing.T) {
	line := Terminal_UI_Line{allocator = context.allocator}
	defer terminal_ui_line_destroy(&line)
	red := Face{fg = color_from_named(.Red)}
	terminal_ui_line_append(&line, "a", 0, red)
	terminal_ui_line_append(&line, "b", 0, red)
	testing.expect_value(t, len(line.atoms), 1)
	testing.expect_value(t, line.atoms[0].text, "ab")
	terminal_ui_line_append(&line, "c", 0, Face{})
	testing.expect_value(t, len(line.atoms), 2)
	// Same face but previous atom has skip and new text is not empty:
	// no merge.
	skippy := Terminal_UI_Line{allocator = context.allocator}
	defer terminal_ui_line_destroy(&skippy)
	terminal_ui_line_append(&skippy, "x", 2, Face{})
	terminal_ui_line_append(&skippy, "y", 0, Face{})
	testing.expect_value(t, len(skippy.atoms), 2)
	// Empty text merges and accumulates skip.
	terminal_ui_line_append(&skippy, "", 3, Face{})
	testing.expect_value(t, len(skippy.atoms), 2)
	testing.expect_value(t, skippy.atoms[1].skip, Coord_Column(3))
}

@(test)
test_terminal_ui_line_resize :: proc(t: ^testing.T) {
	line := Terminal_UI_Line{allocator = context.allocator}
	defer terminal_ui_line_destroy(&line)
	terminal_ui_line_append(&line, "hi", 0, Face{})
	terminal_ui_line_resize(&line, 5)
	testing.expect_value(t, len(line.atoms), 1)
	testing.expect_value(t, line.atoms[0].text, "hi")
	testing.expect_value(t, line.atoms[0].skip, Coord_Column(3))
	terminal_ui_line_resize(&line, 1)
	testing.expect_value(t, line.atoms[0].text, "h")
	testing.expect_value(t, terminal_ui_atom_length(line.atoms[0]), Coord_Column(1))
}

@(test)
test_terminal_ui_line_erase_range :: proc(t: ^testing.T) {
	line := Terminal_UI_Line{allocator = context.allocator}
	defer terminal_ui_line_destroy(&line)
	terminal_ui_line_append(&line, "hello", 0, Face{})
	at := terminal_ui_line_erase_range(&line, 1, 2)
	testing.expect_value(t, at, 1)
	testing.expect_value(t, len(line.atoms), 2)
	testing.expect_value(t, line.atoms[0].text, "h")
	testing.expect_value(t, line.atoms[1].text, "lo")
}

@(test)
test_terminal_ui_window_draw_clip :: proc(t: ^testing.T) {
	window := Terminal_UI_Window{allocator = context.allocator}
	defer terminal_ui_window_destroy(&window)
	terminal_ui_window_create(&window, Coord_Display{}, Coord_Display{line = 2, column = 5})
	atom := display_buffer_atom_text("toolong", Face{})
	atoms := [1]Display_Atom{atom}
	// Out-of-date draw past the bottom is dropped, not fatal.
	terminal_ui_window_draw(&window, Coord_Display{line = 5}, atoms[:], Face{})
	terminal_ui_window_draw(&window, Coord_Display{line = 0}, atoms[:], Face{})
	testing.expect_value(t, len(window.lines[0].atoms), 1)
	// Over-wide content is kept whole until blit trims it to the width.
	testing.expect_value(t, window.lines[0].atoms[0].text, "toolong")
	target := Terminal_UI_Window{allocator = context.allocator}
	defer terminal_ui_window_destroy(&target)
	terminal_ui_window_create(&target, Coord_Display{}, Coord_Display{line = 2, column = 5})
	terminal_ui_window_blit(&window, &target)
	blitted := strings.builder_make(context.allocator)
	defer strings.builder_destroy(&blitted)
	for atom in target.lines[0].atoms {
		strings.write_string(&blitted, atom.text)
	}
	testing.expect_value(t, strings.to_string(blitted), "toolo")
	// Trailing newline content becomes a skip, merged with the padding.
	nl := display_buffer_atom_text("ab\n", Face{})
	nls := [1]Display_Atom{nl}
	terminal_ui_window_draw(&window, Coord_Display{line = 1}, nls[:], Face{})
	testing.expect_value(t, window.lines[1].atoms[0].text, "ab")
	testing.expect_value(t, window.lines[1].atoms[0].skip, Coord_Column(3))
}

@(test)
test_terminal_ui_window_blit :: proc(t: ^testing.T) {
	target := Terminal_UI_Window{allocator = context.allocator}
	defer terminal_ui_window_destroy(&target)
	terminal_ui_window_create(&target, Coord_Display{}, Coord_Display{line = 3, column = 8})
	src := Terminal_UI_Window{allocator = context.allocator}
	defer terminal_ui_window_destroy(&src)
	terminal_ui_window_create(&src, Coord_Display{line = 1, column = 2}, Coord_Display{line = 1, column = 3})
	atom := display_buffer_atom_text("xyz", Face{})
	atoms := [1]Display_Atom{atom}
	terminal_ui_window_draw(&src, Coord_Display{}, atoms[:], Face{})
	terminal_ui_window_blit(&src, &target)
	text := strings.builder_make(context.allocator)
	defer strings.builder_destroy(&text)
	for atom in target.lines[1].atoms {
		strings.write_string(&text, atom.text)
		for _ in 0 ..< int(atom.skip) {
			strings.write_byte(&text, ' ')
		}
	}
	testing.expect_value(t, strings.to_string(text), "  xyz   ")
}

@(test)
test_terminal_ui_set_face_basic :: proc(t: ^testing.T) {
	screen := Terminal_UI_Screen{}
	defer terminal_ui_screen_destroy(&screen)
	sb := strings.builder_make(context.allocator)
	defer strings.builder_destroy(&sb)
	face := Face{fg = color_from_named(.Red), attributes = {.Bold}}
	terminal_ui_screen_set_face(&screen, face, &sb)
	testing.expect_value(t, strings.to_string(sb), "\033[;1;31m")
	// No output when the face is unchanged.
	strings.builder_reset(&sb)
	terminal_ui_screen_set_face(&screen, face, &sb)
	testing.expect_value(t, strings.to_string(sb), "")
	// Back to default emits a bare reset.
	terminal_ui_screen_set_face(&screen, Face{}, &sb)
	testing.expect_value(t, strings.to_string(sb), "\033[m")
}

@(test)
test_terminal_ui_set_face_rgb_underline :: proc(t: ^testing.T) {
	screen := Terminal_UI_Screen{}
	defer terminal_ui_screen_destroy(&screen)
	sb := strings.builder_make(context.allocator)
	defer strings.builder_destroy(&sb)
	rgb, err := color_from_rgb(1, 2, 3)
	testing.expect_value(t, err, Color_Error.None)
	terminal_ui_screen_set_face(&screen, Face{fg = rgb}, &sb)
	testing.expect_value(t, strings.to_string(sb), "\033[38;2;1;2;3m")
	strings.builder_reset(&sb)
	terminal_ui_screen_set_face(&screen, Face{underline = color_from_named(.Red)}, &sb)
	testing.expect_value(t, strings.to_string(sb), "\033[39;58:5:1m")
	// Clearing the underline emits 59.
	strings.builder_reset(&sb)
	terminal_ui_screen_set_face(&screen, Face{}, &sb)
	testing.expect_value(t, strings.to_string(sb), "\033[59m")
}

@(test)
test_terminal_ui_screen_write_elide :: proc(t: ^testing.T) {
	window := Terminal_UI_Window{allocator = context.allocator}
	defer terminal_ui_window_destroy(&window)
	terminal_ui_window_create(&window, Coord_Display{}, Coord_Display{line = 1, column = 6})
	atom := display_buffer_atom_text("ab", Face{})
	atoms := [1]Display_Atom{atom}
	terminal_ui_window_draw(&window, Coord_Display{}, atoms[:], Face{})
	screen := Terminal_UI_Screen{}
	defer terminal_ui_screen_destroy(&screen)
	terminal_ui_screen_create(&screen, Coord_Display{}, Coord_Display{line = 1, column = 6})
	terminal_ui_window_blit(&window, &screen.window)
	sb := strings.builder_make(context.allocator)
	defer strings.builder_destroy(&sb)
	terminal_ui_screen_write(&screen, false, false, &sb)
	testing.expect_value(t, strings.to_string(sb), "\033[1Hab\033[K")
	// Unchanged lines are skipped.
	strings.builder_reset(&sb)
	terminal_ui_screen_write(&screen, false, false, &sb)
	testing.expect_value(t, strings.to_string(sb), "")
	// Force redraws everything with a reset first.
	terminal_ui_screen_write(&screen, true, false, &sb)
	testing.expect_value(t, strings.to_string(sb), "\033[m\033[1Hab\033[K")
}

@(test)
test_terminal_ui_parse_plain :: proc(t: ^testing.T) {
	events, leftover := terminal_ui_test_parse(t, "aé")
	defer terminal_ui_test_free_events(&events)
	testing.expect_value(t, leftover, 0)
	testing.expect_value(t, len(events), 2)
	testing.expect_value(t, terminal_ui_test_key(t, events[0]), Keys_Key{key = 'a'})
	testing.expect_value(t, terminal_ui_test_key(t, events[1]), Keys_Key{key = 'é'})
}

@(test)
test_terminal_ui_parse_controls :: proc(t: ^testing.T) {
	events, leftover := terminal_ui_test_parse(t, "\x01\x00\r\t \x1b")
	defer terminal_ui_test_free_events(&events)
	testing.expect_value(t, leftover, 0)
	testing.expect_value(t, len(events), 6)
	testing.expect_value(
		t,
		terminal_ui_test_key(t, events[0]),
		Keys_Key{modifiers = keys_MOD_CONTROL, key = 'a'},
	)
	testing.expect_value(
		t,
		terminal_ui_test_key(t, events[1]),
		Keys_Key{modifiers = keys_MOD_CONTROL, key = keys_SPACE},
	)
	testing.expect_value(t, terminal_ui_test_key(t, events[2]), Keys_Key{key = keys_RETURN})
	testing.expect_value(t, terminal_ui_test_key(t, events[3]), Keys_Key{key = keys_TAB})
	testing.expect_value(t, terminal_ui_test_key(t, events[4]), Keys_Key{key = keys_SPACE})
	testing.expect_value(t, terminal_ui_test_key(t, events[5]), Keys_Key{key = keys_ESCAPE})

	ctrlsym, _ := terminal_ui_test_parse(t, "\x1c")
	defer terminal_ui_test_free_events(&ctrlsym)
	testing.expect_value(
		t,
		terminal_ui_test_key(t, ctrlsym[0]),
		Keys_Key{modifiers = keys_MOD_CONTROL, key = '\\'},
	)

	// DEL is Backspace with the default erase char, Delete otherwise.
	del, _ := terminal_ui_test_parse(t, "\x7f")
	defer terminal_ui_test_free_events(&del)
	testing.expect_value(t, terminal_ui_test_key(t, del[0]), Keys_Key{key = keys_BACKSPACE})
	parser := terminal_ui_parser_make(context.allocator)
	defer terminal_ui_parser_destroy(&parser)
	parser.erase_char = 8
	terminal_ui_parser_feed(&parser, transmute([]u8)string("\x7f"))
	event, ok := terminal_ui_parser_next(&parser, true)
	testing.expect(t, ok)
	testing.expect_value(t, terminal_ui_test_key(t, event), Keys_Key{key = keys_DELETE})
}

@(test)
test_terminal_ui_parse_csi_arrows :: proc(t: ^testing.T) {
	events, leftover := terminal_ui_test_parse(t, "\x1b[A\x1b[1;5A\x1b[1;2B")
	defer terminal_ui_test_free_events(&events)
	testing.expect_value(t, leftover, 0)
	testing.expect_value(t, len(events), 3)
	testing.expect_value(t, terminal_ui_test_key(t, events[0]), Keys_Key{key = keys_UP})
	testing.expect_value(
		t,
		terminal_ui_test_key(t, events[1]),
		Keys_Key{modifiers = keys_MOD_CONTROL, key = keys_UP},
	)
	testing.expect_value(
		t,
		terminal_ui_test_key(t, events[2]),
		Keys_Key{modifiers = keys_MOD_SHIFT, key = keys_DOWN},
	)
}

@(test)
test_terminal_ui_parse_csi_special :: proc(t: ^testing.T) {
	cases := [18][2]string{
		{"\x1b[H", "home"}, {"\x1b[1~", "home"}, {"\x1b[7~", "home"},
		{"\x1b[F", "end"}, {"\x1b[4~", "end"}, {"\x1b[8~", "end"},
		{"\x1b[2~", "ins"}, {"\x1b[3~", "del"},
		{"\x1b[5~", "pageup"}, {"\x1b[6~", "pagedown"},
		{"\x1b[P", "f1"}, {"\x1b[11~", "f1"}, {"\x1b[15~", "f5"},
		{"\x1b[17~", "f6"}, {"\x1b[24~", "f12"},
		{"\x1b[Z", "shift-tab"}, {"\x1b[I", "focus-in"}, {"\x1b[O", "focus-out"},
	}
	for c in cases {
		events, leftover := terminal_ui_test_parse(t, c[0])
		testing.expect_value(t, leftover, 0)
		testing.expect_value(t, len(events), 1)
		if len(events) == 1 {
			testing.expect_value(t, terminal_ui_test_key(t, events[0]), terminal_ui_test_want(c[1]))
		}
		terminal_ui_test_free_events(&events)
	}
}

@(test)
test_terminal_ui_parse_csi_u :: proc(t: ^testing.T) {
	events, _ := terminal_ui_test_parse(t, "\x1b[97u")
	defer terminal_ui_test_free_events(&events)
	testing.expect_value(t, terminal_ui_test_key(t, events[0]), Keys_Key{key = 'a'})

	shifted, _ := terminal_ui_test_parse(t, "\x1b[97:65;2u")
	defer terminal_ui_test_free_events(&shifted)
	testing.expect_value(t, terminal_ui_test_key(t, shifted[0]), Keys_Key{key = 'A'})

	numpad, _ := terminal_ui_test_parse(t, "\x1b[57414u")
	defer terminal_ui_test_free_events(&numpad)
	testing.expect_value(t, terminal_ui_test_key(t, numpad[0]), Keys_Key{key = keys_RETURN})

	modify, _ := terminal_ui_test_parse(t, "\x1b[27;5;13~")
	defer terminal_ui_test_free_events(&modify)
	testing.expect_value(
		t,
		terminal_ui_test_key(t, modify[0]),
		Keys_Key{modifiers = keys_MOD_CONTROL, key = keys_RETURN},
	)
}

@(test)
test_terminal_ui_parse_ss3 :: proc(t: ^testing.T) {
	events, leftover := terminal_ui_test_parse(t, "\x1bOA\x1bOP\x1bO2A\x1bOp")
	defer terminal_ui_test_free_events(&events)
	testing.expect_value(t, leftover, 0)
	testing.expect_value(t, len(events), 4)
	testing.expect_value(t, terminal_ui_test_key(t, events[0]), Keys_Key{key = keys_UP})
	testing.expect_value(t, terminal_ui_test_key(t, events[1]), Keys_Key{key = keys_F1})
	testing.expect_value(
		t,
		terminal_ui_test_key(t, events[2]),
		Keys_Key{modifiers = keys_MOD_SHIFT, key = keys_UP},
	)
	testing.expect_value(t, terminal_ui_test_key(t, events[3]), Keys_Key{key = '0'})
}

@(test)
test_terminal_ui_parse_alt :: proc(t: ^testing.T) {
	events, leftover := terminal_ui_test_parse(t, "\x1bx\x1b\x01")
	defer terminal_ui_test_free_events(&events)
	testing.expect_value(t, leftover, 0)
	testing.expect_value(t, len(events), 2)
	testing.expect_value(
		t,
		terminal_ui_test_key(t, events[0]),
		Keys_Key{modifiers = keys_MOD_ALT, key = 'x'},
	)
	testing.expect_value(
		t,
		terminal_ui_test_key(t, events[1]),
		Keys_Key{modifiers = Keys_Modifiers(i32(keys_MOD_CONTROL) | i32(keys_MOD_ALT)), key = 'a'},
	)
}

@(test)
test_terminal_ui_parse_mouse_sgr :: proc(t: ^testing.T) {
	parser := terminal_ui_parser_make(context.allocator)
	defer terminal_ui_parser_destroy(&parser)
	terminal_ui_parser_feed(&parser, transmute([]u8)string("\x1b[<0;10;5M\x1b[<0;10;5m"))
	press, ok := terminal_ui_parser_next(&parser, true)
	testing.expect(t, ok)
	press_key := terminal_ui_test_key(t, press)
	testing.expect_value(t, keys_mouse_button(press_key), Keys_Mouse_Button.Left)
	testing.expect(t, i32(press_key.modifiers) & i32(keys_MOD_MOUSE_PRESS) != 0)
	testing.expect_value(t, keys_coord(press_key), Keys_Coord{line = 4, column = 9})
	release, ok2 := terminal_ui_parser_next(&parser, true)
	testing.expect(t, ok2)
	release_key := terminal_ui_test_key(t, release)
	testing.expect(t, i32(release_key.modifiers) & i32(keys_MOD_MOUSE_RELEASE) != 0)
	testing.expect_value(t, parser.mouse_state, 0)

	terminal_ui_parser_feed(&parser, transmute([]u8)string("\x1b[<64;10;5M\x1b[<65;10;5M"))
	up, _ := terminal_ui_parser_next(&parser, true)
	up_key := terminal_ui_test_key(t, up)
	testing.expect(t, i32(up_key.modifiers) & i32(keys_MOD_SCROLL) != 0)
	testing.expect_value(t, keys_scroll_amount(up_key), -3)
	down, _ := terminal_ui_parser_next(&parser, true)
	testing.expect_value(t, keys_scroll_amount(terminal_ui_test_key(t, down)), 3)
}

@(test)
test_terminal_ui_parse_mouse_legacy :: proc(t: ^testing.T) {
	parser := terminal_ui_parser_make(context.allocator)
	defer terminal_ui_parser_destroy(&parser)
	terminal_ui_parser_feed(&parser, transmute([]u8)string("\x1b[M !\"\x1b[M#!!"))
	press, ok := terminal_ui_parser_next(&parser, true)
	testing.expect(t, ok)
	press_key := terminal_ui_test_key(t, press)
	testing.expect_value(t, keys_mouse_button(press_key), Keys_Mouse_Button.Left)
	testing.expect_value(t, keys_coord(press_key), Keys_Coord{line = 1, column = 0})
	release, ok2 := terminal_ui_parser_next(&parser, true)
	testing.expect(t, ok2)
	release_key := terminal_ui_test_key(t, release)
	testing.expect(t, i32(release_key.modifiers) & i32(keys_MOD_MOUSE_RELEASE) != 0)
	testing.expect_value(t, keys_mouse_button(release_key), Keys_Mouse_Button.Left)

	terminal_ui_parser_feed(&parser, transmute([]u8)string("\x1b[M`!!"))
	wheel, ok3 := terminal_ui_parser_next(&parser, true)
	testing.expect(t, ok3)
	testing.expect_value(t, keys_scroll_amount(terminal_ui_test_key(t, wheel)), -3)
}

@(test)
test_terminal_ui_parse_paste :: proc(t: ^testing.T) {
	events, leftover := terminal_ui_test_parse(t, "\x1b[200~hello\r\nworld\x1b[201~")
	defer terminal_ui_test_free_events(&events)
	testing.expect_value(t, leftover, 0)
	testing.expect_value(t, len(events), 14)
	paste, ok := events[len(events) - 1].(Terminal_UI_Paste)
	testing.expect(t, ok)
	if ok {
		testing.expect_value(t, paste.content, "hello\n\nworld")
	}
	for event in events[:len(events) - 1] {
		testing.expect_value(t, terminal_ui_test_key(t, event), Keys_Key{key = keys_INVALID})
	}
}

@(test)
test_terminal_ui_parse_truncated :: proc(t: ^testing.T) {
	parser := terminal_ui_parser_make(context.allocator)
	defer terminal_ui_parser_destroy(&parser)
	terminal_ui_parser_feed(&parser, transmute([]u8)string("\x1b[1;"))
	_, ok := terminal_ui_parser_next(&parser, false)
	testing.expect(t, !ok)
	testing.expect_value(t, len(parser.input), 4)
	terminal_ui_parser_feed(&parser, transmute([]u8)string("5A"))
	event, ok2 := terminal_ui_parser_next(&parser, false)
	testing.expect(t, ok2)
	testing.expect_value(
		t,
		terminal_ui_test_key(t, event),
		Keys_Key{modifiers = keys_MOD_CONTROL, key = keys_UP},
	)
	testing.expect_value(t, len(parser.input), 0)

	// Lone ESC waits for more input unless final.
	terminal_ui_parser_feed(&parser, transmute([]u8)string("\x1b"))
	_, ok3 := terminal_ui_parser_next(&parser, false)
	testing.expect(t, !ok3)
	event4, ok4 := terminal_ui_parser_next(&parser, true)
	testing.expect(t, ok4)
	testing.expect_value(t, terminal_ui_test_key(t, event4), Keys_Key{key = keys_ESCAPE})

	// Split UTF-8 waits for the tail bytes.
	head := [1]u8{0xc3}
	terminal_ui_parser_feed(&parser, head[:])
	_, ok5 := terminal_ui_parser_next(&parser, false)
	testing.expect(t, !ok5)
	tail := [1]u8{0xa9}
	terminal_ui_parser_feed(&parser, tail[:])
	event6, ok6 := terminal_ui_parser_next(&parser, false)
	testing.expect(t, ok6)
	testing.expect_value(t, terminal_ui_test_key(t, event6), Keys_Key{key = 'é'})
}

@(test)
test_terminal_ui_parse_garbage :: proc(t: ^testing.T) {
	events, leftover := terminal_ui_test_parse(t, "\x1b[Xy")
	defer terminal_ui_test_free_events(&events)
	testing.expect_value(t, leftover, 0)
	testing.expect_value(t, len(events), 2)
	testing.expect_value(
		t,
		terminal_ui_test_key(t, events[0]),
		Keys_Key{modifiers = keys_MOD_ALT, key = '['},
	)
	testing.expect_value(t, terminal_ui_test_key(t, events[1]), Keys_Key{key = 'y'})

	bad_ss3, _ := terminal_ui_test_parse(t, "\x1bO?")
	defer terminal_ui_test_free_events(&bad_ss3)
	testing.expect_value(t, len(bad_ss3), 1)
	testing.expect_value(
		t,
		terminal_ui_test_key(t, bad_ss3[0]),
		Keys_Key{modifiers = keys_MOD_ALT, key = 'O'},
	)

	bad_tilde, _ := terminal_ui_test_parse(t, "\x1b[999~")
	defer terminal_ui_test_free_events(&bad_tilde)
	testing.expect_value(t, len(bad_tilde), 1)
	testing.expect_value(
		t,
		terminal_ui_test_key(t, bad_tilde[0]),
		Keys_Key{modifiers = keys_MOD_ALT, key = '['},
	)
}

@(test)
test_terminal_ui_parse_sync_reply :: proc(t: ^testing.T) {
	parser := terminal_ui_parser_make(context.allocator)
	defer terminal_ui_parser_destroy(&parser)
	terminal_ui_parser_feed(&parser, transmute([]u8)string("\x1b[?2026;1$y"))
	event, ok := terminal_ui_parser_next(&parser, true)
	testing.expect(t, ok)
	testing.expect_value(t, terminal_ui_test_key(t, event), Keys_Key{key = keys_INVALID})
	testing.expect(t, parser.sync_seen)
	testing.expect(t, parser.sync_supported)

	terminal_ui_parser_feed(&parser, transmute([]u8)string("\x1b[?2026;0$y"))
	_, ok2 := terminal_ui_parser_next(&parser, true)
	testing.expect(t, ok2)
	testing.expect(t, !parser.sync_supported)
}

@(test)
test_terminal_ui_resize :: proc(t: ^testing.T) {
	ui := terminal_ui_make(context.allocator)
	defer terminal_ui_destroy(&ui)
	testing.expect(t, !terminal_ui_window_valid(&ui.window))
	// Zero sizes fall back to 24x80 like a zero winsize.
	terminal_ui_apply_size(&ui, 0, 0)
	testing.expect(t, terminal_ui_window_valid(&ui.window))
	testing.expect_value(t, ui.dimensions, Coord_Display{line = 23, column = 80})
	testing.expect(t, ui.resize_pending)
	event, ok := terminal_ui_poll(&ui, true)
	testing.expect(t, ok)
	key := terminal_ui_test_key(t, event)
	testing.expect_value(t, key.modifiers, keys_MOD_RESIZE)
	testing.expect_value(t, keys_coord(key), Keys_Coord{line = 23, column = 80})
	// A 1x1 terminal leaves a zero-line drawable area but a valid window.
	terminal_ui_apply_size(&ui, 1, 1)
	testing.expect_value(t, ui.dimensions, Coord_Display{line = 0, column = 1})
	testing.expect(t, terminal_ui_window_valid(&ui.window))
	terminal_ui_refresh(&ui, true)
	testing.expect(t, len(terminal_ui_output(&ui)) > 0)
}

@(test)
test_terminal_ui_draw_refresh :: proc(t: ^testing.T) {
	ui := terminal_ui_test_ui(4, 10)
	defer terminal_ui_destroy(&ui)
	line0 := terminal_ui_test_line("hi")
	defer display_buffer_line_destroy(&line0)
	line1 := terminal_ui_test_line("bye")
	defer display_buffer_line_destroy(&line1)
	buffer := terminal_ui_test_buffer(line0, line1)
	defer delete(buffer.lines)
	terminal_ui_draw(&ui, &buffer, Coord_Display{}, Face{}, Face{}, 0)
	prompt := terminal_ui_test_line(":")
	defer display_buffer_line_destroy(&prompt)
	content := terminal_ui_test_line("cmd")
	defer display_buffer_line_destroy(&content)
	mode := terminal_ui_test_line("file")
	defer display_buffer_line_destroy(&mode)
	terminal_ui_draw_status(&ui, &prompt, &content, 3, &mode, Face{}, .Status)
	testing.expect(t, strings.contains(terminal_ui_output(&ui), "\033]2;file - Kakoune\x07"))
	terminal_ui_clear_output(&ui)
	terminal_ui_refresh(&ui, false)
	out := terminal_ui_output(&ui)
	testing.expect(t, strings.contains(out, "\033[1Hhi"))
	testing.expect(t, strings.contains(out, "\033[2Hbye"))
	testing.expect(t, strings.contains(out, "~"))
	testing.expect(t, strings.contains(out, "\033[4H:cmd  file"))
	testing.expect(t, strings.has_suffix(out, "\033[4;5H"))
	// Clean refresh emits nothing.
	terminal_ui_clear_output(&ui)
	terminal_ui_refresh(&ui, false)
	testing.expect_value(t, terminal_ui_output(&ui), "")
}

@(test)
test_terminal_ui_menu :: proc(t: ^testing.T) {
	ui := terminal_ui_test_ui(10, 40)
	defer terminal_ui_destroy(&ui)
	item0 := terminal_ui_test_line("aaa")
	defer display_buffer_line_destroy(&item0)
	item1 := terminal_ui_test_line("b")
	defer display_buffer_line_destroy(&item1)
	item2 := terminal_ui_test_line("cc")
	defer display_buffer_line_destroy(&item2)
	items := [3]Display_Line{item0, item1, item2}
	terminal_ui_menu_show(&ui, items[:], Coord_Display{line = 2, column = 5}, Face{}, Face{}, .Prompt)
	testing.expect(t, terminal_ui_window_valid(&ui.menu.window))
	terminal_ui_menu_select(&ui, 1)
	testing.expect_value(t, ui.menu.selected_item, 1)
	terminal_ui_refresh(&ui, true)
	out := terminal_ui_output(&ui)
	testing.expect(t, strings.contains(out, "aaa"))
	testing.expect(t, strings.contains(out, "cc"))
	terminal_ui_menu_hide(&ui)
	testing.expect(t, !terminal_ui_window_valid(&ui.menu.window))

	terminal_ui_menu_show(&ui, items[:], Coord_Display{line = 2, column = 5}, Face{}, Face{}, .Search)
	testing.expect_value(t, ui.menu.columns, 0)
	testing.expect_value(t, ui.menu.size.line, Coord_Line(1))
	terminal_ui_menu_hide(&ui)
}

@(test)
test_terminal_ui_info_modal :: proc(t: ^testing.T) {
	ui := terminal_ui_test_ui(10, 40)
	defer terminal_ui_destroy(&ui)
	title := terminal_ui_test_line("T")
	defer display_buffer_line_destroy(&title)
	row := terminal_ui_test_line("hello")
	defer display_buffer_line_destroy(&row)
	rows := [1]Display_Line{row}
	terminal_ui_info_show(&ui, &title, rows[:], Coord_Display{}, Face{}, .Modal)
	testing.expect(t, terminal_ui_window_valid(&ui.info.window))
	terminal_ui_refresh(&ui, true)
	out := terminal_ui_output(&ui)
	testing.expect(t, strings.contains(out, "╭──┤T├──╮"))
	testing.expect(t, strings.contains(out, "│ hello │"))
	testing.expect(t, strings.contains(out, "╰───────╯"))
	terminal_ui_info_hide(&ui)
	testing.expect(t, !terminal_ui_window_valid(&ui.info.window))
}

@(test)
test_terminal_ui_wrap_lines :: proc(t: ^testing.T) {
	line := terminal_ui_test_line("aa bb cc dd")
	defer display_buffer_line_destroy(&line)
	src := [1]Display_Line{line}
	wrapped := terminal_ui_wrap_lines(src[:], 5)
	defer terminal_ui_destroy_line_list(&wrapped)
	testing.expect_value(t, len(wrapped), 3)
	if len(wrapped) == 3 {
		testing.expect_value(t, display_buffer_atom_content(wrapped[0].atoms[0]), "aa ")
		testing.expect_value(t, display_buffer_atom_content(wrapped[1].atoms[0]), "bb ")
		testing.expect_value(t, display_buffer_atom_content(wrapped[2].atoms[0]), "cc dd")
	}
}

@(test)
test_terminal_ui_compute_pos :: proc(t: ^testing.T) {
	rect := Terminal_UI_Rect{size = Coord_Display{line = 10, column = 40}}
	size := Coord_Display{line = 3, column = 10}
	empty := Terminal_UI_Rect{}
	pos := terminal_ui_compute_pos(
		Coord_Display{line = 5, column = 5},
		size,
		rect,
		empty,
		false,
	)
	testing.expect_value(t, pos, Coord_Display{line = 6, column = 5})
	pos = terminal_ui_compute_pos(Coord_Display{line = 9, column = 35}, size, rect, empty, false)
	testing.expect_value(t, pos, Coord_Display{line = 6, column = 30})
	pos = terminal_ui_compute_pos(Coord_Display{line = 5, column = 5}, size, rect, empty, true)
	testing.expect_value(t, pos, Coord_Display{line = 2, column = 5})
	// Boxes overlapping to_avoid move above it.
	avoid := Terminal_UI_Rect{
		pos  = Coord_Display{line = 6, column = 0},
		size = Coord_Display{line = 4, column = 40},
	}
	pos = terminal_ui_compute_pos(Coord_Display{line = 5, column = 5}, size, rect, avoid, false)
	testing.expect_value(t, pos, Coord_Display{line = 2, column = 5})
}

@(test)
test_terminal_ui_diff_hashes :: proc(t: ^testing.T) {
	old := [3]uint{10, 20, 30}
	new := [3]uint{10, 20, 30}
	changes := terminal_ui_diff_hashes(old[:], new[:])
	defer delete(changes)
	testing.expect_value(t, len(changes), 1)
	testing.expect_value(t, changes[0], Terminal_UI_Change{keep = 3})

	other := [3]uint{11, 22, 33}
	changes2 := terminal_ui_diff_hashes(old[:], other[:])
	defer delete(changes2)
	keep, add, del := 0, 0, 0
	for change in changes2 {
		keep += change.keep
		add += change.add
		del += change.del
	}
	testing.expect_value(t, keep, 0)
	testing.expect_value(t, add, 3)
	testing.expect_value(t, del, 3)
}

@(test)
test_terminal_ui_options :: proc(t: ^testing.T) {
	ui := terminal_ui_test_ui(10, 40)
	defer terminal_ui_destroy(&ui)
	options := terminal_ui_test_options(
		"terminal_assistant", "cat",
		"terminal_status_on_top", "yes",
		"terminal_padding_char", ">",
		"terminal_padding_fill", "true",
		"terminal_wheel_scroll_amount", "5",
		"terminal_shift_function_key", "9",
		"terminal_info_max_width", "25",
		"terminal_title", "custom",
		"terminal_cursor_native", "yes",
	)
	defer delete(options)
	terminal_ui_set_ui_options(&ui, options)
	testing.expect_value(t, ui.assistant, Terminal_UI_Assistant.Cat)
	testing.expect(t, ui.status_on_top)
	testing.expect_value(t, ui.padding_char, '>')
	testing.expect(t, ui.padding_fill)
	testing.expect_value(t, ui.wheel_scroll, 5)
	testing.expect_value(t, ui.shift_function_key, 9)
	testing.expect_value(t, ui.info_max_width, Coord_Column(25))
	testing.expect(t, ui.has_title)
	testing.expect(t, ui.mouse_enabled)
	testing.expect(t, strings.contains(terminal_ui_output(&ui), "\033[?1006h"))
	testing.expect(t, strings.contains(terminal_ui_output(&ui), "\033[?25h"))
	testing.expect(t, strings.contains(terminal_ui_output(&ui), "\033[?2026$p"))
	// Unknown assistant leaves the current one in place.
	again := terminal_ui_test_options("terminal_assistant", "bogus", "terminal_enable_mouse", "no")
	defer delete(again)
	terminal_ui_set_ui_options(&ui, again)
	testing.expect_value(t, ui.assistant, Terminal_UI_Assistant.Cat)
	testing.expect(t, !ui.mouse_enabled)
	testing.expect(t, !ui.has_title)
}

@(test)
test_terminal_ui_title :: proc(t: ^testing.T) {
	ui := terminal_ui_test_ui(4, 10)
	defer terminal_ui_destroy(&ui)
	prompt := terminal_ui_test_line(":")
	defer display_buffer_line_destroy(&prompt)
	content := terminal_ui_test_line("")
	defer display_buffer_line_destroy(&content)
	mode := terminal_ui_test_line("m\x01x")
	defer display_buffer_line_destroy(&mode)
	terminal_ui_draw_status(&ui, &prompt, &content, 0, &mode, Face{}, .Status)
	testing.expect(t, strings.contains(terminal_ui_output(&ui), "\033]2;m?x - Kakoune\x07"))
	// Disabled titles emit nothing.
	options := terminal_ui_test_options("terminal_set_title", "no")
	defer delete(options)
	terminal_ui_set_ui_options(&ui, options)
	terminal_ui_clear_output(&ui)
	terminal_ui_draw_status(&ui, &prompt, &content, 0, &mode, Face{}, .Status)
	testing.expect(t, !strings.contains(terminal_ui_output(&ui), "\033]2;"))
}

@(test)
test_terminal_ui_sync_output :: proc(t: ^testing.T) {
	ui := terminal_ui_test_ui(4, 10)
	defer terminal_ui_destroy(&ui)
	options := terminal_ui_test_options("terminal_synchronized", "yes")
	defer delete(options)
	terminal_ui_set_ui_options(&ui, options)
	terminal_ui_clear_output(&ui)
	line := terminal_ui_test_line("hi")
	defer display_buffer_line_destroy(&line)
	buffer := terminal_ui_test_buffer(line)
	defer delete(buffer.lines)
	terminal_ui_draw(&ui, &buffer, Coord_Display{}, Face{}, Face{}, 0)
	terminal_ui_refresh(&ui, false)
	out := terminal_ui_output(&ui)
	testing.expect(t, strings.has_prefix(out, "\033[?2026h"))
	testing.expect(t, strings.contains(out, "\033[?2026l"))
	testing.expect(t, strings.contains(out, "hi"))
}

@(test)
test_terminal_ui_vtable :: proc(t: ^testing.T) {
	ui := terminal_ui_test_ui(10, 40)
	defer terminal_ui_destroy(&ui)
	iface := terminal_ui_as_interface(&ui)
	testing.expect(t, user_interface_is_ok(&iface))
	testing.expect_value(t, user_interface_dimensions(&iface), Coord_Display{line = 9, column = 40})

	item := terminal_ui_test_line("choice")
	defer display_buffer_line_destroy(&item)
	choices := [1]User_Interface_Display_Line{{opaque = &item}}
	red := Face{fg = color_from_named(.Red)}
	user_interface_menu_show(&iface, choices[:], Coord_Display{line = 1, column = 1}, red, Face{}, .Prompt)
	testing.expect(t, terminal_ui_window_valid(&ui.menu.window))
	user_interface_menu_select(&iface, 0)
	testing.expect_value(t, ui.menu.selected_item, 0)
	user_interface_menu_hide(&iface)
	testing.expect(t, !terminal_ui_window_valid(&ui.menu.window))

	row := terminal_ui_test_line("body")
	defer display_buffer_line_destroy(&row)
	buffer := terminal_ui_test_buffer(row)
	defer delete(buffer.lines)
	wrapped_buffer := User_Interface_Display_Buffer{opaque = &buffer}
	user_interface_draw(&iface, &wrapped_buffer, Coord_Display{}, Face{}, Face{}, 0)
	testing.expect(t, ui.dirty)

	title := terminal_ui_test_line("head")
	defer display_buffer_line_destroy(&title)
	content := [1]User_Interface_Display_Line{{opaque = &row}}
	wrapped_title := User_Interface_Display_Line{opaque = &title}
	user_interface_info_show(&iface, &wrapped_title, content[:], Coord_Display{}, Face{}, .Modal)
	testing.expect(t, terminal_ui_window_valid(&ui.info.window))
	user_interface_info_hide(&iface)
	testing.expect(t, !terminal_ui_window_valid(&ui.info.window))

	// Callbacks install through the handle.
	on_key := proc(data: rawptr, key: Keys_Key) {
		_ = data
		_ = key
	}
	user_interface_set_on_key(&iface, {on_key, nil})
	testing.expect(t, ui.on_key.call != nil)
	on_paste := proc(data: rawptr, content: string) {
		_ = data
		_ = content
	}
	user_interface_set_on_paste(&iface, {on_paste, nil})
	testing.expect(t, ui.on_paste.call != nil)
	options := terminal_ui_test_options("terminal_padding_char", "!")
	defer delete(options)
	user_interface_set_ui_options(&iface, options)
	testing.expect_value(t, ui.padding_char, '!')
	// NOTE: user_interface_refresh is deliberately not called: it
	// flushes to the real stdout.
	terminal_ui_refresh(&ui, true)
	testing.expect(t, len(terminal_ui_output(&ui)) > 0)
}

@(test)
test_terminal_ui_allocator_clean :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)

	ui := terminal_ui_make(alloc)
	terminal_ui_apply_size(&ui, 10, 40)
	ui.resize_pending = false
	line := terminal_ui_test_line("hello")
	defer display_buffer_line_destroy(&line)
	buffer := terminal_ui_test_buffer(line)
	defer delete(buffer.lines)
	terminal_ui_draw(&ui, &buffer, Coord_Display{line = 1, column = 2}, Face{}, Face{}, 0)
	prompt := terminal_ui_test_line(":")
	defer display_buffer_line_destroy(&prompt)
	content := terminal_ui_test_line("cmd")
	defer display_buffer_line_destroy(&content)
	mode := terminal_ui_test_line("mode")
	defer display_buffer_line_destroy(&mode)
	terminal_ui_draw_status(&ui, &prompt, &content, 3, &mode, Face{}, .Status)
	item := terminal_ui_test_line("item")
	defer display_buffer_line_destroy(&item)
	items := [1]Display_Line{item}
	terminal_ui_menu_show(&ui, items[:], Coord_Display{line = 2, column = 2}, Face{}, Face{}, .Prompt)
	terminal_ui_menu_select(&ui, 0)
	title := terminal_ui_test_line("title")
	defer display_buffer_line_destroy(&title)
	rows := [1]Display_Line{line}
	terminal_ui_info_show(&ui, &title, rows[:], Coord_Display{}, Face{}, .Modal)
	terminal_ui_refresh(&ui, true, alloc)
	terminal_ui_menu_hide(&ui)
	terminal_ui_info_hide(&ui)
	terminal_ui_apply_size(&ui, 5, 20)
	terminal_ui_destroy(&ui)
	testing.expect_value(t, len(track.allocation_map), 0)
}
