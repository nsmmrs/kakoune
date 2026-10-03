package kak

import "core:testing"

// User_Interface_Test_Stub records every vtable call so the tests can
// verify dispatch, argument forwarding and callback installation.
User_Interface_Test_Stub :: struct {
	ok:              bool,
	dims:            Coord_Display,
	menu_choices:    int,
	menu_anchor:     Coord_Display,
	menu_style:      User_Interface_Menu_Style,
	menu_selected:   int,
	menu_shown:      bool,
	info_lines:      int,
	info_style:      User_Interface_Info_Style,
	info_shown:      bool,
	drawn:           bool,
	cursor:          Coord_Display,
	widget_columns:  Coord_Column,
	status_style:    User_Interface_Status_Style,
	status_cursor:   Coord_Column,
	refreshed:       bool,
	forced:          bool,
	on_key:          User_Interface_On_Key_Callback,
	on_paste:        User_Interface_On_Paste_Callback,
	options_seen:    int,
}

user_interface_test_stub :: proc(data: rawptr) -> ^User_Interface_Test_Stub {
	return (^User_Interface_Test_Stub)(data)
}

user_interface_test_stub_is_ok :: proc(data: rawptr) -> bool {
	return user_interface_test_stub(data).ok
}

user_interface_test_stub_menu_show :: proc(data: rawptr, choices: []User_Interface_Display_Line, anchor: Coord_Display, fg, bg: Face, style: User_Interface_Menu_Style) {
	stub := user_interface_test_stub(data)
	stub.menu_shown = true
	stub.menu_choices = len(choices)
	stub.menu_anchor = anchor
	stub.menu_style = style
	_ = fg
	_ = bg
}

user_interface_test_stub_menu_select :: proc(data: rawptr, selected: int) {
	user_interface_test_stub(data).menu_selected = selected
}

user_interface_test_stub_menu_hide :: proc(data: rawptr) {
	user_interface_test_stub(data).menu_shown = false
}

user_interface_test_stub_info_show :: proc(data: rawptr, title: ^User_Interface_Display_Line, content: []User_Interface_Display_Line, anchor: Coord_Display, face: Face, style: User_Interface_Info_Style) {
	stub := user_interface_test_stub(data)
	stub.info_shown = true
	stub.info_lines = len(content)
	stub.info_style = style
	_ = title
	_ = anchor
	_ = face
}

user_interface_test_stub_info_hide :: proc(data: rawptr) {
	user_interface_test_stub(data).info_shown = false
}

user_interface_test_stub_draw :: proc(data: rawptr, display_buffer: ^User_Interface_Display_Buffer, cursor_pos: Coord_Display, default_face, padding_face: Face, widget_columns: Coord_Column) {
	stub := user_interface_test_stub(data)
	stub.drawn = true
	stub.cursor = cursor_pos
	stub.widget_columns = widget_columns
	_ = display_buffer
	_ = default_face
	_ = padding_face
}

user_interface_test_stub_draw_status :: proc(data: rawptr, prompt, content: ^User_Interface_Display_Line, cursor_pos: Coord_Column, mode_line: ^User_Interface_Display_Line, default_face: Face, style: User_Interface_Status_Style) {
	stub := user_interface_test_stub(data)
	stub.status_style = style
	stub.status_cursor = cursor_pos
	_ = prompt
	_ = content
	_ = mode_line
	_ = default_face
}

user_interface_test_stub_dimensions :: proc(data: rawptr) -> Coord_Display {
	return user_interface_test_stub(data).dims
}

user_interface_test_stub_refresh :: proc(data: rawptr, force: bool) {
	stub := user_interface_test_stub(data)
	stub.refreshed = true
	stub.forced = force
}

user_interface_test_stub_set_on_key :: proc(data: rawptr, callback: User_Interface_On_Key_Callback) {
	user_interface_test_stub(data).on_key = callback
}

user_interface_test_stub_set_on_paste :: proc(data: rawptr, callback: User_Interface_On_Paste_Callback) {
	user_interface_test_stub(data).on_paste = callback
}

user_interface_test_stub_set_ui_options :: proc(data: rawptr, options: User_Interface_Options) {
	user_interface_test_stub(data).options_seen = len(options)
}

user_interface_test_seen_key: Keys_Key
user_interface_test_seen_key_count: int
user_interface_test_seen_paste: string
user_interface_test_seen_paste_count: int

user_interface_test_on_key :: proc(data: rawptr, key: Keys_Key) {
	_ = data
	user_interface_test_seen_key = key
	user_interface_test_seen_key_count += 1
}

user_interface_test_on_paste :: proc(data: rawptr, content: string) {
	_ = data
	user_interface_test_seen_paste = content
	user_interface_test_seen_paste_count += 1
}

user_interface_test_vtable := User_Interface_VTable {
	is_ok          = user_interface_test_stub_is_ok,
	menu_show      = user_interface_test_stub_menu_show,
	menu_select    = user_interface_test_stub_menu_select,
	menu_hide      = user_interface_test_stub_menu_hide,
	info_show      = user_interface_test_stub_info_show,
	info_hide      = user_interface_test_stub_info_hide,
	draw           = user_interface_test_stub_draw,
	draw_status    = user_interface_test_stub_draw_status,
	dimensions     = user_interface_test_stub_dimensions,
	refresh        = user_interface_test_stub_refresh,
	set_on_key     = user_interface_test_stub_set_on_key,
	set_on_paste   = user_interface_test_stub_set_on_paste,
	set_ui_options = user_interface_test_stub_set_ui_options,
}

@(test)
test_user_interface_enums :: proc(t: ^testing.T) {
	testing.expect_value(t, int(User_Interface_Menu_Style.Prompt), 0)
	testing.expect_value(t, int(User_Interface_Menu_Style.Search), 1)
	testing.expect_value(t, int(User_Interface_Menu_Style.Inline), 2)
	testing.expect_value(t, int(User_Interface_Info_Style.Modal), 5)
	testing.expect_value(t, int(User_Interface_Info_Style.Inline_Below), 3)
	testing.expect_value(t, int(User_Interface_Status_Style.Status), 0)
	testing.expect_value(t, int(User_Interface_Status_Style.Prompt), 3)
}

@(test)
test_user_interface_dispatch :: proc(t: ^testing.T) {
	stub := User_Interface_Test_Stub {
		ok   = true,
		dims = Coord_Display{line = 24, column = 80},
	}
	ui := user_interface_make(&stub, &user_interface_test_vtable)

	testing.expect(t, user_interface_is_ok(&ui))
	testing.expect_value(t, user_interface_dimensions(&ui), Coord_Display{line = 24, column = 80})

	choices := make([]User_Interface_Display_Line, 3, context.temp_allocator)
	anchor := Coord_Display{line = 1, column = 2}
	user_interface_menu_show(&ui, choices, anchor, Face{}, Face{}, .Search)
	testing.expect(t, stub.menu_shown)
	testing.expect_value(t, stub.menu_choices, 3)
	testing.expect_value(t, stub.menu_anchor, anchor)
	testing.expect_value(t, stub.menu_style, User_Interface_Menu_Style.Search)

	user_interface_menu_select(&ui, 1)
	testing.expect_value(t, stub.menu_selected, 1)
	user_interface_menu_hide(&ui)
	testing.expect(t, !stub.menu_shown)

	title := User_Interface_Display_Line{}
	content := make([]User_Interface_Display_Line, 4, context.temp_allocator)
	user_interface_info_show(&ui, &title, content, anchor, Face{}, .Modal)
	testing.expect(t, stub.info_shown)
	testing.expect_value(t, stub.info_lines, 4)
	testing.expect_value(t, stub.info_style, User_Interface_Info_Style.Modal)
	user_interface_info_hide(&ui)
	testing.expect(t, !stub.info_shown)

	buffer := User_Interface_Display_Buffer{}
	cursor := Coord_Display{line = 5, column = 7}
	user_interface_draw(&ui, &buffer, cursor, Face{}, Face{}, 3)
	testing.expect(t, stub.drawn)
	testing.expect_value(t, stub.cursor, cursor)
	testing.expect_value(t, stub.widget_columns, Coord_Column(3))

	prompt := User_Interface_Display_Line{}
	line := User_Interface_Display_Line{}
	mode := User_Interface_Display_Line{}
	user_interface_draw_status(&ui, &prompt, &line, 9, &mode, Face{}, .Command)
	testing.expect_value(t, stub.status_style, User_Interface_Status_Style.Command)
	testing.expect_value(t, stub.status_cursor, Coord_Column(9))

	user_interface_refresh(&ui, true)
	testing.expect(t, stub.refreshed)
	testing.expect(t, stub.forced)

	options := make(User_Interface_Options, 2, context.temp_allocator)
	options["color"] = "yes"
	options["font"] = "mono"
	user_interface_set_ui_options(&ui, options)
	testing.expect_value(t, stub.options_seen, 2)
}

@(test)
test_user_interface_callbacks :: proc(t: ^testing.T) {
	stub := User_Interface_Test_Stub{}
	ui := user_interface_make(&stub, &user_interface_test_vtable)

	key := Keys_Key{modifiers = keys_MOD_CONTROL, key = 'c'}
	user_interface_set_on_key(&ui, {user_interface_test_on_key, nil})
	testing.expect(t, stub.on_key.call != nil)
	stub.on_key.call(stub.on_key.data, key)
	testing.expect_value(t, user_interface_test_seen_key_count, 1)
	testing.expect_value(t, user_interface_test_seen_key, key)

	user_interface_set_on_paste(&ui, {user_interface_test_on_paste, nil})
	testing.expect(t, stub.on_paste.call != nil)
	stub.on_paste.call(stub.on_paste.data, "pasted")
	testing.expect_value(t, user_interface_test_seen_paste_count, 1)
	testing.expect_value(t, user_interface_test_seen_paste, "pasted")

	// A second UI over a distinct stub stays independent.
	other := User_Interface_Test_Stub{ok = false}
	other_ui := user_interface_make(&other, &user_interface_test_vtable)
	testing.expect(t, !user_interface_is_ok(&other_ui))
	testing.expect_value(t, stub.menu_selected, 0)
	user_interface_menu_select(&other_ui, 42)
	testing.expect_value(t, other.menu_selected, 42)
	testing.expect_value(t, stub.menu_selected, 0)
}
