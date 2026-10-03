// Tests for the client module ported from src/client.{hh,cc}.
// No C++ UnitTest covers client; these assert the ported behavior.
//
// Only stub-free procs are exercised here: anything reaching window,
// context, input handler, option/hook/client manager, buffer, display
// or command code panics by design (STUB protocol) and is listed in
// the module summary as an integration-test gap.
package kak

import "core:mem"
import "core:testing"
import "core:time"

// Client_Test_Ui records user_interface calls for the fake ui below.
Client_Test_Ui :: struct {
	ok:                bool,
	dims:              Coord_Display,
	ui_options:        User_Interface_Options,
	set_options_calls: int,
}

client_test_ui_is_ok :: proc(data: rawptr) -> bool {
	return (cast(^Client_Test_Ui)data).ok
}

client_test_ui_menu_show :: proc(
	data: rawptr,
	choices: []User_Interface_Display_Line,
	anchor: Coord_Display,
	fg, bg: Face,
	style: User_Interface_Menu_Style,
) {
	_ = data
	_ = choices
	_ = anchor
	_ = fg
	_ = bg
	_ = style
}

client_test_ui_menu_select :: proc(data: rawptr, selected: int) {
	_ = data
	_ = selected
}

client_test_ui_menu_hide :: proc(data: rawptr) {
	_ = data
}

client_test_ui_info_show :: proc(
	data: rawptr,
	title: ^User_Interface_Display_Line,
	content: []User_Interface_Display_Line,
	anchor: Coord_Display,
	face: Face,
	style: User_Interface_Info_Style,
) {
	_ = data
	_ = title
	_ = content
	_ = anchor
	_ = face
	_ = style
}

client_test_ui_info_hide :: proc(data: rawptr) {
	_ = data
}

client_test_ui_draw :: proc(
	data: rawptr,
	display_buffer: ^User_Interface_Display_Buffer,
	cursor_pos: Coord_Display,
	default_face, padding_face: Face,
	widget_columns: Coord_Column,
) {
	_ = data
	_ = display_buffer
	_ = cursor_pos
	_ = default_face
	_ = padding_face
	_ = widget_columns
}

client_test_ui_draw_status :: proc(
	data: rawptr,
	prompt, content: ^User_Interface_Display_Line,
	cursor_pos: Coord_Column,
	mode_line: ^User_Interface_Display_Line,
	default_face: Face,
	style: User_Interface_Status_Style,
) {
	_ = data
	_ = prompt
	_ = content
	_ = cursor_pos
	_ = mode_line
	_ = default_face
	_ = style
}

client_test_ui_dimensions :: proc(data: rawptr) -> Coord_Display {
	return (cast(^Client_Test_Ui)data).dims
}

client_test_ui_refresh :: proc(data: rawptr, force: bool) {
	_ = data
	_ = force
}

client_test_ui_set_on_key :: proc(data: rawptr, callback: User_Interface_On_Key_Callback) {
	_ = data
	_ = callback
}

client_test_ui_set_on_paste :: proc(data: rawptr, callback: User_Interface_On_Paste_Callback) {
	_ = data
	_ = callback
}

client_test_ui_set_ui_options :: proc(data: rawptr, options: User_Interface_Options) {
	ui := cast(^Client_Test_Ui)data
	ui.ui_options = options
	ui.set_options_calls += 1
}

client_test_ui_vtable := User_Interface_VTable{
	is_ok          = client_test_ui_is_ok,
	menu_show      = client_test_ui_menu_show,
	menu_select    = client_test_ui_menu_select,
	menu_hide      = client_test_ui_menu_hide,
	info_show      = client_test_ui_info_show,
	info_hide      = client_test_ui_info_hide,
	draw           = client_test_ui_draw,
	draw_status    = client_test_ui_draw_status,
	dimensions     = client_test_ui_dimensions,
	refresh        = client_test_ui_refresh,
	set_on_key     = client_test_ui_set_on_key,
	set_on_paste   = client_test_ui_set_on_paste,
	set_ui_options = client_test_ui_set_ui_options,
}

// client_test_make_client builds a Client least-squares style: only
// the fields the stub-free procs touch are initialized.
client_test_make_client :: proc(allocator := context.allocator) -> Client {
	c: Client
	c.allocator = allocator
	c.pending_keys = make([dynamic]Keys_Key, allocator)
	return c
}

client_test_destroy_client_arrays :: proc(c: ^Client) {
	client_display_line_destroy(&c.status_prompt)
	client_display_line_destroy(&c.status_content)
	client_display_line_destroy(&c.mode_line)
	client_display_line_destroy(&c.info.title)
	client_display_line_list_destroy(&c.info.content)
	client_display_line_list_destroy(&c.menu.items)
	delete(c.pending_keys)
}

// Menu show stores the choices unselected and flags Menu_Show.
@(test)
client_test_menu_show :: proc(t: ^testing.T) {
	c := client_test_make_client()
	defer client_test_destroy_client_arrays(&c)

	choices := make([dynamic]Display_Line, 2)
	choices[0] = client_display_line_from_text("one", Face{})
	choices[1] = client_display_line_from_text("two", Face{})
	client_menu_show(&c, choices, Coord_Buffer{3, 4}, .Inline)

	testing.expect_value(t, len(c.menu.items), 2)
	testing.expect_value(t, c.menu.items[0].atoms[0].text, "one")
	testing.expect_value(t, c.menu.anchor, Coord_Buffer{3, 4})
	testing.expect_value(t, c.menu.style, User_Interface_Menu_Style.Inline)
	testing.expect_value(t, c.menu.selected, -1)
	testing.expect(t, .Menu_Show in c.ui_pending)
	testing.expect(t, .Menu_Hide not_in c.ui_pending)
	_, has_anchor := c.menu.ui_anchor.?
	testing.expect(t, !has_anchor)
}

// Menu show replaces previous items and clears a stale Menu_Hide.
@(test)
client_test_menu_show_replaces :: proc(t: ^testing.T) {
	c := client_test_make_client()
	defer client_test_destroy_client_arrays(&c)

	first := make([dynamic]Display_Line, 1)
	first[0] = client_display_line_from_text("old", Face{})
	client_menu_show(&c, first, Coord_Buffer{}, .Prompt)
	c.ui_pending |= {.Menu_Hide}

	second := make([dynamic]Display_Line, 1)
	second[0] = client_display_line_from_text("new", Face{})
	client_menu_show(&c, second, Coord_Buffer{1, 1}, .Search)

	testing.expect_value(t, len(c.menu.items), 1)
	testing.expect_value(t, c.menu.items[0].atoms[0].text, "new")
	testing.expect_value(t, c.menu.selected, -1)
	testing.expect(t, .Menu_Hide not_in c.ui_pending)
}

// Menu select records the selection and flags Menu_Select.
@(test)
client_test_menu_select :: proc(t: ^testing.T) {
	c := client_test_make_client()
	defer client_test_destroy_client_arrays(&c)

	choices := make([dynamic]Display_Line, 1)
	choices[0] = client_display_line_from_text("one", Face{})
	client_menu_show(&c, choices, Coord_Buffer{}, .Prompt)
	c.ui_pending |= {.Menu_Hide}

	client_menu_select(&c, 0)

	testing.expect_value(t, c.menu.selected, 0)
	testing.expect(t, .Menu_Select in c.ui_pending)
	testing.expect(t, .Menu_Hide not_in c.ui_pending)
}

// Menu hide frees the items and flags Menu_Hide only.
@(test)
client_test_menu_hide :: proc(t: ^testing.T) {
	c := client_test_make_client()
	defer client_test_destroy_client_arrays(&c)

	choices := make([dynamic]Display_Line, 1)
	choices[0] = client_display_line_from_text("one", Face{})
	client_menu_show(&c, choices, Coord_Buffer{2, 2}, .Prompt)
	client_menu_select(&c, 0)

	client_menu_hide(&c)

	testing.expect_value(t, len(c.menu.items), 0)
	testing.expect(t, .Menu_Hide in c.ui_pending)
	testing.expect(t, .Menu_Show not_in c.ui_pending)
	testing.expect(t, .Menu_Select not_in c.ui_pending)
}

// Info show stores the box and flags Info_Show.
@(test)
client_test_info_show :: proc(t: ^testing.T) {
	c := client_test_make_client()
	defer client_test_destroy_client_arrays(&c)
	c.pending_clear |= {.Info}

	title := client_display_line_from_text("title", Face{})
	content := make(Display_Line_List, 1)
	content[0] = client_display_line_from_text("body", Face{})
	client_info_show(&c, title, content, Coord_Buffer{5, 6}, .Inline)

	testing.expect_value(t, c.info.title.atoms[0].text, "title")
	testing.expect_value(t, len(c.info.content), 1)
	testing.expect_value(t, c.info.anchor, Coord_Buffer{5, 6})
	testing.expect_value(t, c.info.style, User_Interface_Info_Style.Inline)
	testing.expect(t, .Info_Show in c.ui_pending)
	testing.expect(t, .Info_Hide not_in c.ui_pending)
	testing.expect(t, .Info not_in c.pending_clear)
}

// A modal box already on screen is left untouched.
@(test)
client_test_info_show_modal_guard :: proc(t: ^testing.T) {
	c := client_test_make_client()
	defer client_test_destroy_client_arrays(&c)

	title := client_display_line_from_text("modal", Face{})
	client_info_show(&c, title, make(Display_Line_List, 0), Coord_Buffer{}, .Modal)
	c.ui_pending = Client_Pending_Ui{}

	// Refused lines are destroyed by the callee (modal guard).
	other_title := client_display_line_from_text("other", Face{})
	other_content := make(Display_Line_List, 0)
	client_info_show(&c, other_title, other_content, Coord_Buffer{}, .Prompt)

	testing.expect_value(t, c.info.title.atoms[0].text, "modal")
	testing.expect_value(t, c.info.style, User_Interface_Info_Style.Modal)
	testing.expect(t, card(c.ui_pending) == 0)
}

// Info hide frees the box and flags Info_Hide only.
@(test)
client_test_info_hide :: proc(t: ^testing.T) {
	c := client_test_make_client()
	defer client_test_destroy_client_arrays(&c)

	title := client_display_line_from_text("title", Face{})
	content := make(Display_Line_List, 1)
	content[0] = client_display_line_from_text("body", Face{})
	client_info_show(&c, title, content, Coord_Buffer{}, .Prompt)

	client_info_hide(&c)

	testing.expect_value(t, len(c.info.content), 0)
	testing.expect_value(t, len(c.info.title.atoms), 0)
	testing.expect(t, .Info_Hide in c.ui_pending)
	testing.expect(t, .Info_Show not_in c.ui_pending)
}

// A modal box needs even_modal to be dismissed.
@(test)
client_test_info_hide_modal :: proc(t: ^testing.T) {
	c := client_test_make_client()
	defer client_test_destroy_client_arrays(&c)

	title := client_display_line_from_text("modal", Face{})
	client_info_show(&c, title, make(Display_Line_List, 0), Coord_Buffer{}, .Modal)
	c.ui_pending = Client_Pending_Ui{}

	client_info_hide(&c)
	testing.expect_value(t, c.info.title.atoms[0].text, "modal")
	testing.expect(t, card(c.ui_pending) == 0)

	client_info_hide(&c, true)
	testing.expect_value(t, len(c.info.title.atoms), 0)
	testing.expect(t, .Info_Hide in c.ui_pending)
}

// The string overload strips one trailing newline and splits lines.
@(test)
client_test_info_show_string :: proc(t: ^testing.T) {
	c := client_test_make_client()
	defer client_test_destroy_client_arrays(&c)

	client_info_show_string(&c, "t", "a\nb\n", Coord_Buffer{1, 0}, .Prompt)

	testing.expect_value(t, c.info.title.atoms[0].text, "t")
	testing.expect_value(t, len(c.info.content), 2)
	testing.expect_value(t, c.info.content[0].atoms[0].text, "a")
	testing.expect_value(t, c.info.content[1].atoms[0].text, "b")
	testing.expect(t, .Info_Show in c.ui_pending)
}

// Tabs become spaces and an empty title stays an empty line.
@(test)
client_test_info_show_string_tabs :: proc(t: ^testing.T) {
	c := client_test_make_client()
	defer client_test_destroy_client_arrays(&c)

	client_info_show_string(&c, "", "a\tb", Coord_Buffer{}, .Inline_Below)

	testing.expect_value(t, len(c.info.title.atoms), 0)
	testing.expect_value(t, len(c.info.content), 1)
	testing.expect_value(t, c.info.content[0].atoms[0].text, "a b")
	// Box owns atoms and texts; teardown destroys both.
}

// The string overload honors the modal guard without allocating.
@(test)
client_test_info_show_string_modal_guard :: proc(t: ^testing.T) {
	c := client_test_make_client()
	defer client_test_destroy_client_arrays(&c)

	title := client_display_line_from_text("modal", Face{})
	client_info_show(&c, title, make(Display_Line_List, 0), Coord_Buffer{}, .Modal)
	c.ui_pending = Client_Pending_Ui{}

	client_info_show_string(&c, "other", "body", Coord_Buffer{}, .Prompt)

	testing.expect_value(t, c.info.title.atoms[0].text, "modal")
	testing.expect(t, card(c.ui_pending) == 0)
}

// print_status stores the line, flags Status_Line and clears the
// scheduled status clear.
@(test)
client_test_print_status :: proc(t: ^testing.T) {
	c := client_test_make_client()
	defer client_test_destroy_client_arrays(&c)
	c.pending_clear |= {.Status_Line}

	prompt := client_display_line_from_text(">", Face{})
	content := client_display_line_from_text("hello", Face{})
	client_print_status(&c, prompt, content, Units_ColumnCount(2), .Command)

	testing.expect_value(t, c.status_prompt.atoms[0].text, ">")
	testing.expect_value(t, c.status_content.atoms[0].text, "hello")
	testing.expect_value(t, c.status_cursor_pos, Units_ColumnCount(2))
	testing.expect_value(t, c.status_style, User_Interface_Status_Style.Command)
	testing.expect(t, .Status_Line in c.ui_pending)
	testing.expect(t, .Status_Line not_in c.pending_clear)
}

// schedule_clear marks both areas unless already pending.
@(test)
client_test_schedule_and_clear_pending :: proc(t: ^testing.T) {
	c := client_test_make_client()
	defer client_test_destroy_client_arrays(&c)

	client_schedule_clear(&c)
	testing.expect(t, .Info in c.pending_clear)
	testing.expect(t, .Status_Line in c.pending_clear)

	c.pending_clear = Client_Pending_Clear{}
	c.ui_pending |= {.Info_Show}
	client_schedule_clear(&c)
	testing.expect(t, .Info not_in c.pending_clear)
	testing.expect(t, .Status_Line in c.pending_clear)
	c.ui_pending = Client_Pending_Ui{}
}

// clear_pending empties the status line and hides the info box.
@(test)
client_test_clear_pending :: proc(t: ^testing.T) {
	c := client_test_make_client()
	defer client_test_destroy_client_arrays(&c)

	prompt := client_display_line_from_text(">", Face{})
	content := client_display_line_from_text("hello", Face{})
	client_print_status(&c, prompt, content, Units_ColumnCount(0), .Status)
	title := client_display_line_from_text("t", Face{})
	body := make(Display_Line_List, 1)
	body[0] = client_display_line_from_text("b", Face{})
	client_info_show(&c, title, body, Coord_Buffer{}, .Prompt)
	c.ui_pending = Client_Pending_Ui{}
	c.pending_clear |= {.Info, .Status_Line}

	client_clear_pending(&c)

	testing.expect_value(t, len(c.status_prompt.atoms), 0)
	testing.expect_value(t, len(c.status_content.atoms), 0)
	testing.expect_value(t, c.status_cursor_pos, Units_ColumnCount(-1))
	testing.expect_value(t, len(c.info.content), 0)
	testing.expect(t, card(c.pending_clear) == 0)
	testing.expect(t, .Status_Line in c.ui_pending)
	testing.expect(t, .Info_Hide in c.ui_pending)
}

// force_redraw(false) flags only Draw.
@(test)
client_test_force_redraw_partial :: proc(t: ^testing.T) {
	c := client_test_make_client()
	defer client_test_destroy_client_arrays(&c)

	client_force_redraw(&c)

	testing.expect(t, .Draw in c.ui_pending)
	testing.expect(t, card(c.ui_pending) == 1)
}

// force_redraw(true) refreshes everything, hiding empty widgets.
@(test)
client_test_force_redraw_full_empty :: proc(t: ^testing.T) {
	c := client_test_make_client()
	defer client_test_destroy_client_arrays(&c)

	client_force_redraw(&c, true)

	testing.expect(t, .Refresh in c.ui_pending)
	testing.expect(t, .Draw in c.ui_pending)
	testing.expect(t, .Status_Line in c.ui_pending)
	testing.expect(t, .Menu_Hide in c.ui_pending)
	testing.expect(t, .Info_Hide in c.ui_pending)
	testing.expect(t, .Menu_Show not_in c.ui_pending)
	testing.expect(t, .Info_Show not_in c.ui_pending)
}

// force_redraw(true) re-shows non-empty widgets.
@(test)
client_test_force_redraw_full_shown :: proc(t: ^testing.T) {
	c := client_test_make_client()
	defer client_test_destroy_client_arrays(&c)

	choices := make([dynamic]Display_Line, 1)
	choices[0] = client_display_line_from_text("one", Face{})
	client_menu_show(&c, choices, Coord_Buffer{}, .Prompt)
	title := client_display_line_from_text("t", Face{})
	body := make(Display_Line_List, 1)
	body[0] = client_display_line_from_text("b", Face{})
	client_info_show(&c, title, body, Coord_Buffer{}, .Prompt)
	c.ui_pending = Client_Pending_Ui{}

	client_force_redraw(&c, true)

	testing.expect(t, .Menu_Show in c.ui_pending)
	testing.expect(t, .Menu_Select in c.ui_pending)
	testing.expect(t, .Info_Show in c.ui_pending)
	testing.expect(t, .Menu_Hide not_in c.ui_pending)
	testing.expect(t, .Info_Hide not_in c.ui_pending)
}

// Pending-input and pending-ui queries mirror the flags.
@(test)
client_test_pending_queries :: proc(t: ^testing.T) {
	c := client_test_make_client()
	defer client_test_destroy_client_arrays(&c)

	testing.expect(t, !client_has_pending_inputs(&c))
	testing.expect(t, !client_info_pending(&c))
	testing.expect(t, !client_status_line_pending(&c))

	append(&c.pending_keys, Keys_Key{key = 'a'})
	c.ui_pending |= {.Info_Show, .Status_Line}

	testing.expect(t, client_has_pending_inputs(&c))
	testing.expect(t, client_info_pending(&c))
	testing.expect(t, client_status_line_pending(&c))
}

// Env var lookup hits and misses.
@(test)
client_test_get_env_var :: proc(t: ^testing.T) {
	c := client_test_make_client()
	defer client_test_destroy_client_arrays(&c)
	c.env_vars = make(Env_Var_Map, context.allocator)
	defer delete(c.env_vars)
	c.env_vars["kak_client"] = "main"

	testing.expect_value(t, client_get_env_var(&c, "kak_client"), "main")
	testing.expect_value(t, client_get_env_var(&c, "missing"), "")
	testing.expect_value(t, client_pid(&c), 0)
}

// Exit runs the callback with the status.
client_test_exit_status := -1

client_test_on_exit :: proc(data: rawptr, status: int) {
	_ = data
	client_test_exit_status = status
}

@(test)
client_test_exit :: proc(t: ^testing.T) {
	c := client_test_make_client()
	defer client_test_destroy_client_arrays(&c)
	c.on_exit = Client_On_Exit_Callback{client_test_on_exit, nil, nil}
	client_test_exit_status = -1

	client_exit(&c, 3)

	testing.expect_value(t, client_test_exit_status, 3)
}

// is_ui_ok and dimensions dispatch through the vtable.
@(test)
client_test_ui_dispatch :: proc(t: ^testing.T) {
	c := client_test_make_client()
	defer client_test_destroy_client_arrays(&c)
	state := Client_Test_Ui{ok = true, dims = Coord_Display{24, 80}}
	ui := user_interface_make(&state, &client_test_ui_vtable)
	c.ui = &ui

	testing.expect(t, client_is_ui_ok(&c))
	testing.expect_value(t, client_dimensions(&c), Coord_Display{24, 80})

	state.ok = false
	testing.expect(t, !client_is_ui_ok(&c))
}

// ui_options changes reach the ui and always flag a redraw.
@(test)
client_test_on_option_changed :: proc(t: ^testing.T) {
	c := client_test_make_client()
	defer client_test_destroy_client_arrays(&c)
	state := Client_Test_Ui{}
	ui := user_interface_make(&state, &client_test_ui_vtable)
	c.ui = &ui

	desc := Option_Desc{name = "ui_options"}
	opts := make(map[string]string, context.allocator)
	defer delete(opts)
	opts["ncurses_assistant"] = "cat"
	option := Option{desc = &desc, value = opts}
	client_on_option_changed(&c, &option)

	testing.expect_value(t, state.set_options_calls, 1)
	testing.expect_value(t, state.ui_options["ncurses_assistant"], "cat")
	testing.expect(t, .Draw in c.ui_pending)

	c.ui_pending = Client_Pending_Ui{}
	other_desc := Option_Desc{name = "tabstop"}
	other := Option{desc = &other_desc, value = 8}
	client_on_option_changed(&c, &other)

	testing.expect_value(t, state.set_options_calls, 1)
	testing.expect(t, .Draw in c.ui_pending)
}

// The watcher trampoline routes notifications to the client.
@(test)
client_test_option_watcher :: proc(t: ^testing.T) {
	c := client_test_make_client()
	defer client_test_destroy_client_arrays(&c)
	state := Client_Test_Ui{}
	ui := user_interface_make(&state, &client_test_ui_vtable)
	c.ui = &ui

	watcher := client_option_watcher(&c)
	desc := Option_Desc{name = "ui_options"}
	opts := make(map[string]string, context.allocator)
	defer delete(opts)
	opts["x"] = "y"
	option := Option{desc = &desc, value = opts}
	watcher.on_option_changed(watcher.data, &option)

	testing.expect_value(t, state.set_options_calls, 1)
	testing.expect(t, .Draw in c.ui_pending)
}

// Autoreload names round-trip, including the true/false aliases.
@(test)
client_test_autoreload_names :: proc(t: ^testing.T) {
	testing.expect_value(t, client_autoreload_to_string(.Yes), "yes")
	testing.expect_value(t, client_autoreload_to_string(.No), "no")
	testing.expect_value(t, client_autoreload_to_string(.Ask), "ask")

	value, ok := client_autoreload_from_string("yes")
	testing.expect(t, ok && value == .Yes)
	value, ok = client_autoreload_from_string("true")
	testing.expect(t, ok && value == .Yes)
	value, ok = client_autoreload_from_string("no")
	testing.expect(t, ok && value == .No)
	value, ok = client_autoreload_from_string("false")
	testing.expect(t, ok && value == .No)
	value, ok = client_autoreload_from_string("ask")
	testing.expect(t, ok && value == .Ask)
	_, ok = client_autoreload_from_string("maybe")
	testing.expect(t, !ok)
}

// Inline styles anchor to a buffer position; the rest do not.
@(test)
client_test_info_is_inline :: proc(t: ^testing.T) {
	testing.expect(t, client_info_is_inline(.Inline))
	testing.expect(t, client_info_is_inline(.Inline_Above))
	testing.expect(t, client_info_is_inline(.Inline_Below))
	testing.expect(t, !client_info_is_inline(.Prompt))
	testing.expect(t, !client_info_is_inline(.Menu_Doc))
	testing.expect(t, !client_info_is_inline(.Modal))
}

// Atom comparison distinguishes length and content.
@(test)
client_test_atoms_equal :: proc(t: ^testing.T) {
	a := client_display_line_from_text("x", Face{})
	defer client_display_line_destroy(&a)
	b := client_display_line_from_text("x", Face{})
	defer client_display_line_destroy(&b)
	different := client_display_line_from_text("y", Face{})
	defer client_display_line_destroy(&different)
	empty := Display_Line{}

	testing.expect(t, client_display_line_atoms_equal(a, b))
	testing.expect(t, !client_display_line_atoms_equal(a, different))
	testing.expect(t, !client_display_line_atoms_equal(a, empty))
	testing.expect(t, client_display_line_atoms_equal(empty, Display_Line{}))
}

// Clone copies the atoms array; destroy frees it.
@(test)
client_test_clone_destroy :: proc(t: ^testing.T) {
	line := client_display_line_from_text("x", Face{})
	defer client_display_line_destroy(&line)

	clone := client_display_line_clone(line)
	defer client_display_line_destroy(&clone)

	testing.expect(t, client_display_line_atoms_equal(line, clone))
	testing.expect(t, raw_data(line.atoms) != raw_data(clone.atoms))
}

// Context and input handler accessors return the embedded values.
@(test)
client_test_accessors :: proc(t: ^testing.T) {
	c := client_test_make_client()
	defer client_test_destroy_client_arrays(&c)

	testing.expect(t, client_context(&c) == &c.input_handler.ctx)
	testing.expect(t, client_input_handler(&c) == &c.input_handler)
}

// Ordinary keys queue for later dispatch.
@(test)
client_test_handle_ui_key_queues :: proc(t: ^testing.T) {
	c := client_test_make_client()
	defer client_test_destroy_client_arrays(&c)

	cancelled := client_handle_ui_key(&c, Keys_Key{key = 'j'})

	testing.expect(t, !cancelled)
	testing.expect_value(t, len(c.pending_keys), 1)
	testing.expect_value(t, c.pending_keys[0], Keys_Key{key = 'j'})
}

// The busy indicator arms its timer and cleans up without firing.
client_test_busy_status_destroy :: proc(data: rawptr, allocator: mem.Allocator) {
	_ = allocator
	(cast(^bool)data)^ = true
}

@(test)
client_test_busy_indicator_lifecycle :: proc(t: ^testing.T) {
	destroyed := false
	status := Client_Busy_Status_Callback{nil, &destroyed, client_test_busy_status_destroy}
	wait := clock_now()

	bi: Busy_Indicator
	client_busy_indicator_make(&bi, nil, status, wait)

	testing.expect(t, bi.ctx == nil)
	testing.expect_value(t, bi.timer.date, clock_add(wait, time.Second))
	testing.expect_value(t, bi.timer.mode, Event_Manager_Mode.Urgent)
	_, fired := bi.previous_status.?
	testing.expect(t, !fired)
	_, registered := client_busy_entries[&bi.timer]
	testing.expect(t, registered)

	client_busy_indicator_destroy(&bi)

	testing.expect(t, destroyed)
	_, still_registered := client_busy_entries[&bi.timer]
	testing.expect(t, !still_registered)
}
