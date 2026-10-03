// Port of Kakoune's src/user_interface.hh (abstract UI contract).
//
// The C++ UserInterface class is a virtual interface; here it becomes
// an explicit vtable (User_Interface_VTable) plus a (data, vtable)
// handle (User_Interface). Implementations fill in the vtable once
// and pass an implementation-defined data pointer through; the
// user_interface_* procs dispatch through the vtable.
//
// DisplayLine and DisplayBuffer have no Odin port yet, so they are
// opaque placeholders (User_Interface_Display_Line and
// User_Interface_Display_Buffer) to be unified with the display
// modules when those land. Existing ports are reused: Face (face
// module), Coord_Display/Coord_Column (coord module), Keys_Key
// (keys module).
//
// Ownership: nothing here allocates. Slices, placeholder handles and
// the options map are borrowed views owned by the caller for the
// duration of each call, matching the C++ const-reference parameters.
// Callback context (if any) is owned by whoever installs the callback.
package kak

// User_Interface_Display_Line is an opaque rendered line (placeholder
// for C++ DisplayLine until the display modules are ported).
User_Interface_Display_Line :: struct {
	opaque: rawptr,
}

// User_Interface_Display_Buffer is an opaque rendered screen
// (placeholder for C++ DisplayBuffer until the display modules are
// ported).
User_Interface_Display_Buffer :: struct {
	opaque: rawptr,
}

// User_Interface_Menu_Style selects the menu presentation (port of
// C++ MenuStyle).
User_Interface_Menu_Style :: enum {
	Prompt,
	Search,
	Inline,
}

// User_Interface_Info_Style selects the info-box placement (port of
// C++ InfoStyle).
User_Interface_Info_Style :: enum {
	Prompt,
	Inline,
	Inline_Above,
	Inline_Below,
	Menu_Doc,
	Modal,
}

// User_Interface_Status_Style selects the status-line mode (port of
// C++ StatusStyle).
User_Interface_Status_Style :: enum {
	Status,
	Command,
	Search,
	Prompt,
}

// User_Interface_Options maps UI option names to values (port of
// C++ UserInterface::Options).
User_Interface_Options :: map[string]string

// User_Interface_On_Key_Callback receives a pressed key (port of C++
// OnKeyCallback, whose lambda captures the client; data plays that
// role here).
User_Interface_On_Key_Callback :: struct {
	call: proc(data: rawptr, key: Keys_Key),
	data: rawptr,
}

// User_Interface_On_Paste_Callback receives pasted text (port of C++
// OnPasteCallback).
User_Interface_On_Paste_Callback :: struct {
	call: proc(data: rawptr, content: string),
	data: rawptr,
}

// User_Interface_VTable is the procedure table implementing the UI
// contract (port of the C++ UserInterface virtual methods). Every
// entry receives the implementation's data pointer first.
User_Interface_VTable :: struct {
	is_ok:         proc(data: rawptr) -> bool,
	menu_show:     proc(data: rawptr, choices: []User_Interface_Display_Line, anchor: Coord_Display, fg, bg: Face, style: User_Interface_Menu_Style),
	menu_select:   proc(data: rawptr, selected: int),
	menu_hide:     proc(data: rawptr),
	info_show:     proc(data: rawptr, title: ^User_Interface_Display_Line, content: []User_Interface_Display_Line, anchor: Coord_Display, face: Face, style: User_Interface_Info_Style),
	info_hide:     proc(data: rawptr),
	draw:          proc(data: rawptr, display_buffer: ^User_Interface_Display_Buffer, cursor_pos: Coord_Display, default_face, padding_face: Face, widget_columns: Coord_Column),
	draw_status:   proc(data: rawptr, prompt, content: ^User_Interface_Display_Line, cursor_pos: Coord_Column, mode_line: ^User_Interface_Display_Line, default_face: Face, style: User_Interface_Status_Style),
	dimensions:    proc(data: rawptr) -> Coord_Display,
	refresh:       proc(data: rawptr, force: bool),
	set_on_key:    proc(data: rawptr, callback: User_Interface_On_Key_Callback),
	set_on_paste:  proc(data: rawptr, callback: User_Interface_On_Paste_Callback),
	set_ui_options: proc(data: rawptr, options: User_Interface_Options),
}

// User_Interface is a UI handle: an implementation data pointer plus
// its vtable (port of C++ UserInterface& / unique_ptr<UserInterface>).
User_Interface :: struct {
	data:   rawptr,
	vtable: ^User_Interface_VTable,
}

// user_interface_make builds a UI handle from an implementation data
// pointer and its vtable.
user_interface_make :: proc(data: rawptr, vtable: ^User_Interface_VTable) -> User_Interface {
	return User_Interface{data = data, vtable = vtable}
}

// user_interface_is_ok reports whether the UI is usable (port of
// UserInterface::is_ok).
user_interface_is_ok :: proc(ui: ^User_Interface) -> bool {
	return ui.vtable.is_ok(ui.data)
}

// user_interface_menu_show displays the choice menu (port of
// UserInterface::menu_show).
user_interface_menu_show :: proc(ui: ^User_Interface, choices: []User_Interface_Display_Line, anchor: Coord_Display, fg, bg: Face, style: User_Interface_Menu_Style) {
	ui.vtable.menu_show(ui.data, choices, anchor, fg, bg, style)
}

// user_interface_menu_select highlights one menu entry (port of
// UserInterface::menu_select).
user_interface_menu_select :: proc(ui: ^User_Interface, selected: int) {
	ui.vtable.menu_select(ui.data, selected)
}

// user_interface_menu_hide dismisses the menu (port of
// UserInterface::menu_hide).
user_interface_menu_hide :: proc(ui: ^User_Interface) {
	ui.vtable.menu_hide(ui.data)
}

// user_interface_info_show displays the info box (port of
// UserInterface::info_show).
user_interface_info_show :: proc(ui: ^User_Interface, title: ^User_Interface_Display_Line, content: []User_Interface_Display_Line, anchor: Coord_Display, face: Face, style: User_Interface_Info_Style) {
	ui.vtable.info_show(ui.data, title, content, anchor, face, style)
}

// user_interface_info_hide dismisses the info box (port of
// UserInterface::info_hide).
user_interface_info_hide :: proc(ui: ^User_Interface) {
	ui.vtable.info_hide(ui.data)
}

// user_interface_draw renders the main area (port of
// UserInterface::draw).
user_interface_draw :: proc(ui: ^User_Interface, display_buffer: ^User_Interface_Display_Buffer, cursor_pos: Coord_Display, default_face, padding_face: Face, widget_columns: Coord_Column) {
	ui.vtable.draw(ui.data, display_buffer, cursor_pos, default_face, padding_face, widget_columns)
}

// user_interface_draw_status renders the status line (port of
// UserInterface::draw_status).
user_interface_draw_status :: proc(ui: ^User_Interface, prompt, content: ^User_Interface_Display_Line, cursor_pos: Coord_Column, mode_line: ^User_Interface_Display_Line, default_face: Face, style: User_Interface_Status_Style) {
	ui.vtable.draw_status(ui.data, prompt, content, cursor_pos, mode_line, default_face, style)
}

// user_interface_dimensions returns the UI size in display cells
// (port of UserInterface::dimensions).
user_interface_dimensions :: proc(ui: ^User_Interface) -> Coord_Display {
	return ui.vtable.dimensions(ui.data)
}

// user_interface_refresh repaints the UI, fully when force is set
// (port of UserInterface::refresh).
user_interface_refresh :: proc(ui: ^User_Interface, force: bool) {
	ui.vtable.refresh(ui.data, force)
}

// user_interface_set_on_key installs the key callback (port of
// UserInterface::set_on_key).
user_interface_set_on_key :: proc(ui: ^User_Interface, callback: User_Interface_On_Key_Callback) {
	ui.vtable.set_on_key(ui.data, callback)
}

// user_interface_set_on_paste installs the paste callback (port of
// UserInterface::set_on_paste).
user_interface_set_on_paste :: proc(ui: ^User_Interface, callback: User_Interface_On_Paste_Callback) {
	ui.vtable.set_on_paste(ui.data, callback)
}

// user_interface_set_ui_options applies UI options (port of
// UserInterface::set_ui_options).
user_interface_set_ui_options :: proc(ui: ^User_Interface, options: User_Interface_Options) {
	ui.vtable.set_ui_options(ui.data, options)
}
