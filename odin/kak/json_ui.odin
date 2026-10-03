// Port of Kakoune's src/json_ui.hh and src/json_ui.cc: the JSON-RPC
// user interface. Draw/menu/info calls serialize to JSON-RPC 2.0
// notifications on stdout; stdin carries newline-delimited JSON-RPC
// requests (keys, paste, mouse, scroll, menu_select, resize).
//
// Wire format notes (all verified against json_ui.cc/json.cc):
//   - Strings use the exact C++ to_json(StringView) escaping via
//     json_to_string(); arrays join members with ", ", objects join
//     "key": value pairs with ",".
//   - The attributes array joins with "," (no space), unlike generic
//     arrays, matching the C++ char-joiner call.
//   - RGB colors print as lowercase "#rrggbb".
//
// Error mapping: C++ eval_json throws invalid_rpc_request (a
// runtime_error) for every protocol violation; here json_ui_eval
// returns a Json_Ui_Error naming the violated rule, and the request
// loop logs it to stderr and salvages the stream by dropping through
// the next newline, exactly like the C++ catch block.
//
// Testability: the serializers, json_ui_format_rpc, json_ui_eval, and
// json_ui_consume_requests are pure or callback-driven and fully
// tested. json_ui_make/json_ui_parse_requests and the vtable draw
// path touch fds 0/1 and the event loop and are untested, like the
// socket paths in remote.odin.
package kak

import "core:c"
import "core:mem"
import "core:strings"
import posix "core:sys/posix"

// Json_Ui_Error names the JSON-RPC rule a request broke. The zero
// value .None means the request evaluated cleanly.
Json_Ui_Error :: enum {
	None, // ok
	// The request is not a JSON object.
	Not_An_Object,
	// The "jsonrpc" member is missing, not a string, or not "2.0".
	Bad_Protocol,
	// The "method" member is missing or not a string.
	Bad_Method,
	// The "params" member is missing or not an array.
	Bad_Params,
	// A "keys" parameter is not a string.
	Bad_Keys,
	// "paste" needs exactly one string parameter.
	Bad_Paste,
	// A mouse event has the wrong arity or non-string button /
	// non-integer coordinates.
	Bad_Mouse,
	// "scroll" needs three integer parameters.
	Bad_Scroll,
	// "menu_select" needs one integer parameter.
	Bad_Menu_Select,
	// "resize" needs two integer parameters.
	Bad_Resize,
	// The method name is unknown.
	Unknown_Method,
	// A key description or mouse button name did not parse.
	Key_Error,
}

// json_ui_error_message describes err for the stderr log (borrowed
// static text, mirroring the C++ invalid_rpc_request messages).
json_ui_error_message :: proc(err: Json_Ui_Error) -> string {
	message := ""
	switch err {
	case .None:
		message = ""
	case .Not_An_Object:
		message = "request is not an object"
	case .Bad_Protocol:
		message = "only protocol '2.0' is supported"
	case .Bad_Method:
		message = "method missing or not a string"
	case .Bad_Params:
		message = "params missing or not an array"
	case .Bad_Keys:
		message = "'keys' is not an array of strings"
	case .Bad_Paste:
		message = "paste requires a string parameter"
	case .Bad_Mouse:
		message = "invalid mouse button or coordinates"
	case .Bad_Scroll:
		message = "scroll needs an amount and coordinates"
	case .Bad_Menu_Select:
		message = "menu_select needs the item index"
	case .Bad_Resize:
		message = "resize expects 2 integer parameters"
	case .Unknown_Method:
		message = "unknown method"
	case .Key_Error:
		message = "invalid key description"
	}
	return message
}

// json_ui_parse_error_message describes a request-parse failure for
// the stderr log (borrowed static text, following the C++ json.cc
// messages where they exist).
json_ui_parse_error_message :: proc(err: Json_Error) -> string {
	message := ""
	switch err {
	case .None:
		message = ""
	case .Unexpected_End:
		message = "unterminated request"
	case .Max_Depth:
		message = "maximum parsing depth reached"
	case .Bad_Number:
		message = "unable to parse number"
	case .Expected_Colon:
		message = "expected :"
	case .Expected_Comma_Or_Close:
		message = "expected ',' or closing bracket"
	case .Unexpected_Char:
		message = "unable to parse json"
	case .Non_String_Key:
		message = "object key is not a string"
	}
	return message
}

// Json_Ui is the C++ JsonUI: a stdin watcher, the key/paste
// callbacks, the last known dimensions, and the unparsed request
// prefix. Create with json_ui_make (which needs an event manager),
// release with json_ui_destroy. The C++ m_pending_keys member is
// dead in json_ui.cc (written nowhere, read nowhere) and is omitted.
Json_Ui :: struct {
	watcher:    Event_Manager_Fd_Watcher,
	on_key:     User_Interface_On_Key_Callback,
	on_paste:   User_Interface_On_Paste_Callback,
	dimensions: Coord_Display,
	requests:      string, // owned with allocator
	allocator:     mem.Allocator,
}

// json_ui_active is the UI owning stdin (there can only be one stdin
// watcher); the fd callback dispatches through it.
json_ui_active: ^Json_Ui

// json_ui_hex2 writes v as two lowercase hex digits.
@(private)
json_ui_hex2 :: proc(b: ^strings.Builder, v: u8) {
	digits := "0123456789abcdef"
	strings.write_byte(b, digits[v >> 4])
	strings.write_byte(b, digits[v & 15])
}

// json_ui_to_json_color serializes a color: "#rrggbb" for RGB, the
// quoted palette name otherwise (port of C++ to_json(Color)). The
// caller owns the result.
json_ui_to_json_color :: proc(c: Color, allocator := context.allocator) -> string {
	if color_is_rgb(c) {
		b := strings.builder_make(allocator)
		strings.write_byte(&b, '#')
		json_ui_hex2(&b, c.r)
		json_ui_hex2(&b, c.g)
		json_ui_hex2(&b, c.b)
		return strings.to_string(b)
	}
	name := color_to_string(c, context.temp_allocator)
	return json_to_string(name, allocator)
}

// json_ui_attr_names lists the attribute flags in C++ to_json order
// with their wire names.
@(private)
json_ui_attr_names := [12]struct {
	flag: Face_Attribute_Flag,
	name: string,
}{
	{.Underline, "underline"},
	{.Curly_Underline, "curly_underline"},
	{.Double_Underline, "double_underline"},
	{.Reverse, "reverse"},
	{.Blink, "blink"},
	{.Bold, "bold"},
	{.Dim, "dim"},
	{.Italic, "italic"},
	{.Final_Fg, "final_fg"},
	{.Final_Bg, "final_bg"},
	{.Final_Attr, "final_attr"},
	{.Strikethrough, "strikethrough"},
}

// json_ui_to_json_attrs serializes an attribute set as a JSON array
// of wire names (port of C++ to_json(Attribute)). The caller owns the
// result.
json_ui_to_json_attrs :: proc(attrs: Face_Attribute, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_byte(&b, '[')
	first := true
	for entry in json_ui_attr_names {
		if entry.flag in attrs {
			if !first {
				strings.write_byte(&b, ',')
			}
			first = false
			strings.write_string(&b, json_to_string(entry.name, context.temp_allocator))
		}
	}
	strings.write_byte(&b, ']')
	return strings.to_string(b)
}

// json_ui_to_json_face serializes a face (port of C++ to_json(Face)).
// The caller owns the result.
json_ui_to_json_face :: proc(face: Face, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, `{ "fg": `)
	strings.write_string(&b, json_ui_to_json_color(face.fg, context.temp_allocator))
	strings.write_string(&b, `, "bg": `)
	strings.write_string(&b, json_ui_to_json_color(face.bg, context.temp_allocator))
	strings.write_string(&b, `, "underline": `)
	strings.write_string(&b, json_ui_to_json_color(face.underline, context.temp_allocator))
	strings.write_string(&b, `, "attributes": `)
	strings.write_string(&b, json_ui_to_json_attrs(face.attributes, context.temp_allocator))
	strings.write_string(&b, ` }`)
	return strings.to_string(b)
}

// json_ui_to_json_atom serializes one display atom (port of C++
// to_json(DisplayAtom)). The caller owns the result.
json_ui_to_json_atom :: proc(atom: Display_Atom, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, `{ "face": `)
	strings.write_string(&b, json_ui_to_json_face(atom.face, context.temp_allocator))
	strings.write_string(&b, `, "contents": `)
	strings.write_string(&b, json_to_string(display_buffer_atom_content(atom), context.temp_allocator))
	strings.write_byte(&b, ' ')
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

// json_ui_to_json_line serializes one display line as an atom array
// (port of C++ to_json(DisplayLine)). The caller owns the result.
json_ui_to_json_line :: proc(line: Display_Line, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_byte(&b, '[')
	for atom, i in line.atoms {
		if i > 0 {
			strings.write_string(&b, ", ")
		}
		strings.write_string(&b, json_ui_to_json_atom(atom, context.temp_allocator))
	}
	strings.write_byte(&b, ']')
	return strings.to_string(b)
}

// json_ui_to_json_lines serializes display lines as a line array
// (port of C++ to_json() over line vectors). The caller owns the
// result.
json_ui_to_json_lines :: proc(lines: []Display_Line, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_byte(&b, '[')
	for line, i in lines {
		if i > 0 {
			strings.write_string(&b, ", ")
		}
		strings.write_string(&b, json_ui_to_json_line(line, context.temp_allocator))
	}
	strings.write_byte(&b, ']')
	return strings.to_string(b)
}

// json_ui_to_json_coord serializes a display coord (port of C++
// to_json(DisplayCoord)). The caller owns the result.
json_ui_to_json_coord :: proc(coord: Coord_Display, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, `{ "line": `)
	strings.write_string(&b, json_to_string(int(coord.line), context.temp_allocator))
	strings.write_string(&b, `, "column": `)
	strings.write_string(&b, json_to_string(int(coord.column), context.temp_allocator))
	strings.write_string(&b, ` }`)
	return strings.to_string(b)
}

// json_ui_to_json_column serializes a column count as a bare number
// (port of C++ to_json(ColumnCount)). The caller owns the result.
json_ui_to_json_column :: proc(column: Coord_Column, allocator := context.allocator) -> string {
	return json_to_string(int(column), allocator)
}

// json_ui_to_json_menu_style names a menu style (borrowed static
// text, port of C++ to_json(MenuStyle)).
json_ui_to_json_menu_style :: proc(style: User_Interface_Menu_Style) -> string {
	name := ""
	switch style {
	case .Prompt:
		name = `"prompt"`
	case .Search:
		name = `"search"`
	case .Inline:
		name = `"inline"`
	}
	return name
}

// json_ui_to_json_info_style names an info style (borrowed static
// text, port of C++ to_json(InfoStyle)).
json_ui_to_json_info_style :: proc(style: User_Interface_Info_Style) -> string {
	name := ""
	switch style {
	case .Prompt:
		name = `"prompt"`
	case .Inline:
		name = `"inline"`
	case .Inline_Above:
		name = `"inlineAbove"`
	case .Inline_Below:
		name = `"inlineBelow"`
	case .Menu_Doc:
		name = `"menuDoc"`
	case .Modal:
		name = `"modal"`
	}
	return name
}

// json_ui_to_json_status_style names a status style (borrowed static
// text, port of C++ to_json(StatusStyle)).
json_ui_to_json_status_style :: proc(style: User_Interface_Status_Style) -> string {
	name := ""
	switch style {
	case .Status:
		name = `"status"`
	case .Command:
		name = `"command"`
	case .Search:
		name = `"search"`
	case .Prompt:
		name = `"prompt"`
	}
	return name
}

// json_ui_to_json_options serializes UI options as a JSON object
// (port of C++ to_json() over the Options map). Member order follows
// map order, as in C++. The caller owns the result.
json_ui_to_json_options :: proc(options: User_Interface_Options, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_byte(&b, '{')
	first := true
	for key, value in options {
		if !first {
			strings.write_byte(&b, ',')
		}
		first = false
		json_write_value(&b, key)
		strings.write_string(&b, ": ")
		json_write_value(&b, value)
	}
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

// json_ui_format_rpc formats one JSON-RPC 2.0 notification with the
// given already-serialized params (port of C++ rpc_call(), minus the
// write). The caller owns the result.
json_ui_format_rpc :: proc(method: string, params: []string = nil, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, `{ "jsonrpc": "2.0", "method": "`)
	strings.write_string(&b, method)
	strings.write_string(&b, `", "params": [`)
	for param, i in params {
		if i > 0 {
			strings.write_string(&b, ", ")
		}
		strings.write_string(&b, param)
	}
	strings.write_string(&b, "] }\n")
	return strings.to_string(b)
}

// json_ui_rpc_write formats and emits one JSON-RPC 2.0 notification
// on stdout (port of C++ rpc_call()).
json_ui_rpc_write :: proc(method: string, params: []string = nil) -> File_Error {
	return file_write(1, json_ui_format_rpc(method, params, context.temp_allocator))
}

// json_ui_unwrap_line reinterprets an opaque UI line as the real
// Display_Line it wraps (see KNOTFIX_ui_line in client.odin).
json_ui_unwrap_line :: proc(l: User_Interface_Display_Line) -> ^Display_Line {
	return (^Display_Line)(l.opaque)
}

// json_ui_unwrap_buffer reinterprets an opaque UI buffer as the real
// Display_Buffer it wraps (see KNOTFIX_ui_buffer).
json_ui_unwrap_buffer :: proc(db: ^User_Interface_Display_Buffer) -> ^Display_Buffer {
	return cast(^Display_Buffer)db
}

// json_ui_is_ok reports whether stdin is still open (port of
// JsonUI::is_ok).
json_ui_is_ok :: proc(data: rawptr) -> bool {
	ui := (^Json_Ui)(data)
	return ui.watcher.fd != -1
}

// json_ui_menu_show emits a menu_show notification (port of
// JsonUI::menu_show).
json_ui_menu_show :: proc(
	data: rawptr,
	choices: []User_Interface_Display_Line,
	anchor: Coord_Display,
	fg, bg: Face,
	style: User_Interface_Menu_Style,
) {
	_ = (^Json_Ui)(data)
	lines := make([]Display_Line, len(choices), context.temp_allocator)
	for choice, i in choices {
		lines[i] = json_ui_unwrap_line(choice)^
	}
	params := [5]string{
		json_ui_to_json_lines(lines, context.temp_allocator),
		json_ui_to_json_coord(anchor, context.temp_allocator),
		json_ui_to_json_face(fg, context.temp_allocator),
		json_ui_to_json_face(bg, context.temp_allocator),
		json_ui_to_json_menu_style(style),
	}
	json_ui_rpc_write("menu_show", params[:])
}

// json_ui_menu_select emits a menu_select notification (port of
// JsonUI::menu_select).
json_ui_menu_select :: proc(data: rawptr, selected: int) {
	_ = (^Json_Ui)(data)
	params := [1]string{json_to_string(selected, context.temp_allocator)}
	json_ui_rpc_write("menu_select", params[:])
}

// json_ui_menu_hide emits a menu_hide notification (port of
// JsonUI::menu_hide).
json_ui_menu_hide :: proc(data: rawptr) {
	_ = (^Json_Ui)(data)
	json_ui_rpc_write("menu_hide")
}

// json_ui_info_show emits an info_show notification (port of
// JsonUI::info_show).
json_ui_info_show :: proc(
	data: rawptr,
	title: ^User_Interface_Display_Line,
	content: []User_Interface_Display_Line,
	anchor: Coord_Display,
	face: Face,
	style: User_Interface_Info_Style,
) {
	_ = (^Json_Ui)(data)
	lines := make([]Display_Line, len(content), context.temp_allocator)
	for line, i in content {
		lines[i] = json_ui_unwrap_line(line)^
	}
	params := [5]string{
		json_ui_to_json_line(json_ui_unwrap_line(title^)^, context.temp_allocator),
		json_ui_to_json_lines(lines, context.temp_allocator),
		json_ui_to_json_coord(anchor, context.temp_allocator),
		json_ui_to_json_face(face, context.temp_allocator),
		json_ui_to_json_info_style(style),
	}
	json_ui_rpc_write("info_show", params[:])
}

// json_ui_info_hide emits an info_hide notification (port of
// JsonUI::info_hide).
json_ui_info_hide :: proc(data: rawptr) {
	_ = (^Json_Ui)(data)
	json_ui_rpc_write("info_hide")
}

// json_ui_draw emits a draw notification (port of JsonUI::draw).
json_ui_draw :: proc(
	data: rawptr,
	display_buffer: ^User_Interface_Display_Buffer,
	cursor_pos: Coord_Display,
	default_face, padding_face: Face,
	widget_columns: Coord_Column,
) {
	_ = (^Json_Ui)(data)
	db := json_ui_unwrap_buffer(display_buffer)^
	params := [5]string{
		json_ui_to_json_lines(db.lines[:], context.temp_allocator),
		json_ui_to_json_coord(cursor_pos, context.temp_allocator),
		json_ui_to_json_face(default_face, context.temp_allocator),
		json_ui_to_json_face(padding_face, context.temp_allocator),
		json_ui_to_json_column(widget_columns, context.temp_allocator),
	}
	json_ui_rpc_write("draw", params[:])
}

// json_ui_draw_status emits a draw_status notification (port of
// JsonUI::draw_status).
json_ui_draw_status :: proc(
	data: rawptr,
	prompt, content: ^User_Interface_Display_Line,
	cursor_pos: Coord_Column,
	mode_line: ^User_Interface_Display_Line,
	default_face: Face,
	style: User_Interface_Status_Style,
) {
	_ = (^Json_Ui)(data)
	params := [6]string{
		json_ui_to_json_line(json_ui_unwrap_line(prompt^)^, context.temp_allocator),
		json_ui_to_json_line(json_ui_unwrap_line(content^)^, context.temp_allocator),
		json_ui_to_json_column(cursor_pos, context.temp_allocator),
		json_ui_to_json_line(json_ui_unwrap_line(mode_line^)^, context.temp_allocator),
		json_ui_to_json_face(default_face, context.temp_allocator),
		json_ui_to_json_status_style(style),
	}
	json_ui_rpc_write("draw_status", params[:])
}

// json_ui_dimensions returns the last resize dimensions (port of
// JsonUI::dimensions).
json_ui_dimensions :: proc(data: rawptr) -> Coord_Display {
	ui := (^Json_Ui)(data)
	return ui.dimensions
}

// json_ui_refresh emits a refresh notification (port of
// JsonUI::refresh).
json_ui_refresh :: proc(data: rawptr, force: bool) {
	_ = (^Json_Ui)(data)
	params := [1]string{json_to_string(force, context.temp_allocator)}
	json_ui_rpc_write("refresh", params[:])
}

// json_ui_set_on_key installs the key callback (port of
// JsonUI::set_on_key).
json_ui_set_on_key :: proc(data: rawptr, callback: User_Interface_On_Key_Callback) {
	ui := (^Json_Ui)(data)
	ui.on_key = callback
}

// json_ui_set_on_paste installs the paste callback (port of
// JsonUI::set_on_paste).
json_ui_set_on_paste :: proc(data: rawptr, callback: User_Interface_On_Paste_Callback) {
	ui := (^Json_Ui)(data)
	ui.on_paste = callback
}

// json_ui_set_ui_options emits a set_ui_options notification (port of
// JsonUI::set_ui_options).
json_ui_set_ui_options :: proc(data: rawptr, options: User_Interface_Options) {
	_ = (^Json_Ui)(data)
	params := [1]string{json_ui_to_json_options(options, context.temp_allocator)}
	json_ui_rpc_write("set_ui_options", params[:])
}

// json_ui_vtable implements UserInterface for Json_Ui.
json_ui_vtable := User_Interface_VTable{
	is_ok          = json_ui_is_ok,
	menu_show      = json_ui_menu_show,
	menu_select    = json_ui_menu_select,
	menu_hide      = json_ui_menu_hide,
	info_show      = json_ui_info_show,
	info_hide      = json_ui_info_hide,
	draw           = json_ui_draw,
	draw_status    = json_ui_draw_status,
	dimensions     = json_ui_dimensions,
	refresh        = json_ui_refresh,
	set_on_key     = json_ui_set_on_key,
	set_on_paste   = json_ui_set_on_paste,
	set_ui_options = json_ui_set_ui_options,
}

// json_ui_make initializes a JSON UI watching stdin (port of the
// JsonUI constructor). Requires an installed event manager; restores
// the default SIGINT disposition.
json_ui_make :: proc(ui: ^Json_Ui, allocator := context.allocator) {
	ui.allocator = allocator
	ui.dimensions = Coord_Display{24, 80}
	ui.requests = strings.clone("", allocator)
	event_manager_fd_watcher_init(&ui.watcher, 0, {.Read}, .Urgent, json_ui_on_stdin)
	json_ui_active = ui
	event_manager_set_signal_handler(posix.Signal.SIGINT, cast(Event_Manager_Signal_Handler)posix.SIG_DFL)
}

// json_ui_destroy unregisters the stdin watcher and frees the request
// buffer (stdin itself stays open, as in C++).
json_ui_destroy :: proc(ui: ^Json_Ui) {
	event_manager_fd_watcher_destroy(&ui.watcher)
	delete(ui.requests, ui.allocator)
	ui.requests = ""
	if json_ui_active == ui {
		json_ui_active = nil
	}
}

// json_ui_as_interface wraps an initialized Json_Ui in a User_Interface
// value (data points at the caller's struct).
json_ui_as_interface :: proc(ui: ^Json_Ui) -> User_Interface {
	return user_interface_make(ui, &json_ui_vtable)
}

// json_ui_make_ui heap-allocates a Json_Ui and wraps it in a heap
// User_Interface handle (what main_make_ui needs). Release with
// json_ui_destroy_ui, same allocator.
json_ui_make_ui :: proc(allocator := context.allocator) -> ^User_Interface {
	jui := new(Json_Ui, allocator)
	json_ui_make(jui, allocator)
	iface := new(User_Interface, allocator)
	iface^ = json_ui_as_interface(jui)
	return iface
}

// json_ui_destroy_ui releases a handle built by json_ui_make_ui.
json_ui_destroy_ui :: proc(ui: ^User_Interface, allocator := context.allocator) {
	jui := (^Json_Ui)(ui.data)
	json_ui_destroy(jui)
	free(jui, allocator)
	free(ui, allocator)
}

// json_ui_on_stdin dispatches a ready stdin to the UI owning it.
@(private)
json_ui_on_stdin :: proc(w: ^Event_Manager_Fd_Watcher, events: Event_Manager_Fd_Events, mode: Event_Manager_Mode) {
	_ = events
	if json_ui_active != nil && w == &json_ui_active.watcher {
		json_ui_parse_requests(json_ui_active, mode)
	}
}

// json_ui_parse_requests drains stdin into the request buffer and
// evaluates complete requests (port of JsonUI::parse_requests). A
// closed or failed stdin closes the watcher.
json_ui_parse_requests :: proc(ui: ^Json_Ui, mode: Event_Manager_Mode) {
	_ = mode
	for file_fd_readable(0) {
		chunk: [1024]byte
		n := posix.read(posix.FD(0), raw_data(chunk[:]), c.size_t(len(chunk)))
		if n <= 0 {
			event_manager_fd_watcher_close_fd(&ui.watcher)
			break
		}
		grown := strings.concatenate({ui.requests, string(chunk[:int(n)])}, ui.allocator)
		delete(ui.requests, ui.allocator)
		ui.requests = grown
	}
	json_ui_consume_requests(ui)
}

// json_ui_drop_requests discards the first end bytes of the request
// buffer.
@(private)
json_ui_drop_requests :: proc(ui: ^Json_Ui, end: int) {
	rest := strings.clone(ui.requests[end:], ui.allocator)
	delete(ui.requests, ui.allocator)
	ui.requests = rest
}

// json_ui_salvage finds the resync point after a bad request: past
// the first newline, or the whole buffer when there is none (port of
// the C++ find-min salvage).
@(private)
json_ui_salvage :: proc(ui: ^Json_Ui) -> int {
	if rel := strings.index_byte(ui.requests, '\n'); rel >= 0 {
		return rel + 1
	}
	return len(ui.requests)
}

// json_ui_log_error reports a bad request on stderr (port of the C++
// parse_requests catch block).
@(private)
json_ui_log_error :: proc(ui: ^Json_Ui, message: string) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "error while handling requests '")
	strings.write_string(&b, ui.requests)
	strings.write_string(&b, "': '")
	strings.write_string(&b, message)
	strings.write_string(&b, "'\n")
	file_write(2, strings.to_string(b))
}

// json_ui_consume_requests evaluates complete requests off the
// request buffer, stopping at the first unterminated one (port of
// the JsonUI::parse_requests evaluation loop). Nothing runs until a
// key callback is installed.
json_ui_consume_requests :: proc(ui: ^Json_Ui) {
	if ui.on_key.call == nil {
		return
	}
	for len(ui.requests) > 0 {
		val, end, parse_err := json_parse_impl(ui.requests, 0, 0, ui.allocator)
		if parse_err == .Unexpected_End {
			break
		}
		if parse_err != .None {
			json_ui_log_error(ui, json_ui_parse_error_message(parse_err))
			json_ui_drop_requests(ui, json_ui_salvage(ui))
			continue
		}
		eval_err := json_ui_eval(ui, val)
		saved := context.allocator
		context.allocator = ui.allocator
		json_free(val)
		context.allocator = saved
		if eval_err != .None {
			json_ui_log_error(ui, json_ui_error_message(eval_err))
			json_ui_drop_requests(ui, json_ui_salvage(ui))
			continue
		}
		json_ui_drop_requests(ui, end)
	}
}

// json_ui_param_int reads params[i] as an int.
@(private)
json_ui_param_int :: proc(params: Json_Array, i: int) -> (int, bool) {
	if i < 0 || i >= len(params) {
		return 0, false
	}
	n, ok := params[i].(int)
	return n, ok
}

// json_ui_eval_keys runs one "keys" request: every string parses to
// keys fed to the key callback.
@(private)
json_ui_eval_keys :: proc(ui: ^Json_Ui, params: Json_Array) -> Json_Ui_Error {
	for param in params {
		text, ok := param.(string)
		if !ok {
			return .Bad_Keys
		}
		keys, keys_err := keys_parse(text, context.temp_allocator)
		if keys_err != .None {
			return .Key_Error
		}
		for key in keys {
			ui.on_key.call(ui.on_key.data, key)
		}
	}
	return .None
}

// json_ui_eval_mouse runs one "mouse_move", "mouse_press", or
// "mouse_release" request.
@(private)
json_ui_eval_mouse :: proc(ui: ^Json_Ui, method: string, params: Json_Array) -> Json_Ui_Error {
	if method == "mouse_move" {
		if len(params) != 2 {
			return .Bad_Mouse
		}
		line, line_ok := json_ui_param_int(params, 0)
		column, column_ok := json_ui_param_int(params, 1)
		if !line_ok || !column_ok {
			return .Bad_Mouse
		}
		ui.on_key.call(ui.on_key.data, Keys_Key{keys_MOD_MOUSE_POS, keys_encode_coord(Keys_Coord{line, column})})
		return .None
	}
	if len(params) != 3 {
		return .Bad_Mouse
	}
	button_name, name_ok := params[0].(string)
	if !name_ok {
		return .Bad_Mouse
	}
	line, line_ok := json_ui_param_int(params, 1)
	column, column_ok := json_ui_param_int(params, 2)
	if !line_ok || !column_ok {
		return .Bad_Mouse
	}
	button, button_err := keys_string_to_button(button_name)
	if button_err != .None {
		return .Key_Error
	}
	event := keys_MOD_MOUSE_RELEASE
	if method == "mouse_press" {
		event = keys_MOD_MOUSE_PRESS
	}
	ui.on_key.call(ui.on_key.data, Keys_Key{event | keys_button_modifier(button), keys_encode_coord(Keys_Coord{line, column})})
	return .None
}

// json_ui_eval runs one parsed request object (port of
// JsonUI::eval_json). The key callback must be installed; the paste
// callback is optional, as in C++.
json_ui_eval :: proc(ui: ^Json_Ui, value: Json_Value) -> Json_Ui_Error {
	object, is_object := value.(Json_Object)
	if !is_object {
		return .Not_An_Object
	}
	protocol_raw, has_protocol := object["jsonrpc"]
	protocol, protocol_ok := protocol_raw.(string)
	if !has_protocol || !protocol_ok || protocol != "2.0" {
		return .Bad_Protocol
	}
	method_raw, has_method := object["method"]
	method, method_ok := method_raw.(string)
	if !has_method || !method_ok {
		return .Bad_Method
	}
	params_raw, has_params := object["params"]
	params, params_ok := params_raw.(Json_Array)
	if !has_params || !params_ok {
		return .Bad_Params
	}
	switch method {
	case "keys":
		return json_ui_eval_keys(ui, params)
	case "paste":
		if len(params) != 1 {
			return .Bad_Paste
		}
		text, ok := params[0].(string)
		if !ok {
			return .Bad_Paste
		}
		if ui.on_paste.call != nil {
			ui.on_paste.call(ui.on_paste.data, text)
		}
		return .None
	case "mouse_move", "mouse_press", "mouse_release":
		return json_ui_eval_mouse(ui, method, params)
	case "scroll":
		if len(params) != 3 {
			return .Bad_Scroll
		}
		amount, amount_ok := json_ui_param_int(params, 0)
		line, line_ok := json_ui_param_int(params, 1)
		column, column_ok := json_ui_param_int(params, 2)
		if !amount_ok || !line_ok || !column_ok {
			return .Bad_Scroll
		}
		ui.on_key.call(ui.on_key.data, 
			Keys_Key {
				keys_MOD_SCROLL | Keys_Modifiers(i32(amount) << 16),
				keys_encode_coord(Keys_Coord{line, column}),
			},
		)
		return .None
	case "menu_select":
		if len(params) != 1 {
			return .Bad_Menu_Select
		}
		index, ok := json_ui_param_int(params, 0)
		if !ok {
			return .Bad_Menu_Select
		}
		ui.on_key.call(ui.on_key.data, Keys_Key{keys_MOD_MENU_SELECT, rune(index)})
		return .None
	case "resize":
		if len(params) != 2 {
			return .Bad_Resize
		}
		line, line_ok := json_ui_param_int(params, 0)
		column, column_ok := json_ui_param_int(params, 1)
		if !line_ok || !column_ok {
			return .Bad_Resize
		}
		ui.dimensions = Coord_Display{Coord_Line(line), Coord_Column(column)}
		ui.on_key.call(ui.on_key.data, keys_resize(Keys_Coord{line, column}))
		return .None
	case:
		return .Unknown_Method
	}
}
