// Port of Kakoune's src/client.{hh,cc}: Client (a UI + window pairing
// with menu/info/status state) and BusyIndicator.
//
// Client, Client_Menu, Client_Info and Busy_Indicator come from
// knot.odin (coordinator-owned, read-only here). All client_* procs
// below are this module's implementation of the C++ Client methods,
// free functions (generate_context_info) and BusyIndicator.
//
// Ownership: client_make takes ownership of the heap-allocated ui,
// window, selections array, env_vars map and name; client_destroy
// releases everything the client owns (the window moves to the
// client manager's free list, mirroring the C++ destructor) and frees
// the Client itself. Display_Line values passed to menu/info/status
// procs transfer ownership of their atoms arrays to the client;
// Display_Atom text is borrowed, except tab-expanded copies made by
// client_info_show_string (see the note there).
//
// Known gaps (reported to the coordinator, see the final summary):
//   - The merged user_interface callbacks carry no user data, so
//     client_make cannot install the on-key/on-paste handlers. Their
//     logic lives in client_handle_ui_key / client_handle_ui_paste,
//     ready to be wired once the API grows a data pointer.
//   - C++ try/catch sites (per-key errors, modelinefmt errors, reload
//     errors) have no Odin error plumbing yet; only success paths are
//     ported until the callee modules define error returns.
//   - Display_Line <-> User_Interface_Display_Line bridging uses the
//     KNOTFIX_ adapters below until the display modules unify the
//     user_interface placeholders with the real types.
package kak

import "core:mem"
import "core:strings"
import "core:sys/posix"
import "core:time"

// Client_Error reports fallible client operations. Zero value None
// means success, per the package conventions.
Client_Error :: enum {
	None,
	// Change_Buffer was refused because the current buffer is locked.
	Buffer_Locked,
}

// Client_Selection_Callback is a non-owning selection setter (port of
// C++ Optional<FunctionRef<void()>> in change_buffer).
Client_Selection_Callback :: struct {
	call: proc(data: rawptr),
	data: rawptr,
}

// Client_Postprocess maps a string to a string without owning either
// side (port of C++ FunctionRef<String (String)> in expand).
Client_Postprocess :: struct {
	call: proc(data: rawptr, s: string) -> string,
	data: rawptr,
}

// Client_Busy_Status_Callback builds the busy status line from the
// elapsed whole seconds (port of C++
// Function<DisplayLine(std::chrono::seconds)>). destroy frees data
// and may be nil.
Client_Busy_Status_Callback :: struct {
	call:    proc(data: rawptr, elapsed_seconds: i64, allocator: mem.Allocator) -> Display_Line,
	data:    rawptr,
	destroy: proc(data: rawptr, allocator: mem.Allocator),
}

// Client_Busy_Entry is the per-indicator state the merged timer
// callback cannot carry itself (Event_Manager_Timer_Callback takes no
// user data), keyed by timer pointer in client_busy_entries.
Client_Busy_Entry :: struct {
	indicator:      ^Busy_Indicator,
	status_message: Client_Busy_Status_Callback,
	wait_time:      Clock_Time,
}

// client_busy_entries maps live busy-indicator timers to their
// entries. Created lazily, process lifetime; entries are removed by
// client_busy_indicator_destroy.
client_busy_entries: map[^Event_Manager_Timer]Client_Busy_Entry

// client_BUSY_WAIT_TIMEOUT is the delay before the busy status line
// appears and its refresh period (port of wait_timeout in client.cc).
client_BUSY_WAIT_TIMEOUT :: time.Second

// client_autoreload_desc is the Autoreload name table (port of the
// enum_desc in client.hh, including the true/false aliases).
client_autoreload_desc: [5]Enum_Desc(Autoreload) = {
	{.Yes, "yes"},
	{.No, "no"},
	{.Ask, "ask"},
	{.Yes, "true"},
	{.No, "false"},
}

// client_autoreload_to_string names an autoreload value ("yes" for
// Yes: first table match, like the C++ option_to_string).
client_autoreload_to_string :: proc(value: Autoreload) -> string {
	name, _ := enum_to_name(client_autoreload_desc[:], value)
	return name
}

// client_autoreload_from_string parses an autoreload value, accepting
// the true/false aliases like the C++ option_from_string.
client_autoreload_from_string :: proc(name: string) -> (Autoreload, bool) {
	return enum_from_name(client_autoreload_desc[:], name)
}

// ---------------------------------------------------------------------------
// KNOTFIX adapters (coordinator-owned gaps, see final summary)
// ---------------------------------------------------------------------------

// KNOTFIX_ui_line wraps a display line for the merged user_interface
// procs, whose placeholder line type is still opaque. The wrapper
// borrows l; it must not outlive the call.
KNOTFIX_ui_line :: proc(l: ^Display_Line) -> User_Interface_Display_Line {
	return User_Interface_Display_Line{opaque = l}
}

// KNOTFIX_ui_lines wraps display lines for the merged user_interface
// procs. The returned slice is scratch (see allocator) borrowing
// lines; it must not outlive the call.
KNOTFIX_ui_lines :: proc(lines: []Display_Line, allocator := context.allocator) -> []User_Interface_Display_Line {
	wrapped := make([]User_Interface_Display_Line, len(lines), allocator)
	for &line, i in lines {
		wrapped[i] = KNOTFIX_ui_line(&line)
	}
	return wrapped
}

// KNOTFIX_ui_buffer reinterprets a display buffer for the merged
// user_interface_draw, whose placeholder buffer type is still opaque.
KNOTFIX_ui_buffer :: proc(db: ^Display_Buffer) -> ^User_Interface_Display_Buffer {
	return cast(^User_Interface_Display_Buffer)db
}

// ---------------------------------------------------------------------------
// Small real helpers
// ---------------------------------------------------------------------------

// client_face looks up a builtin face, falling back to the default
// face when the registry lacks it (port of FaceRegistry::operator[]).
client_face :: proc(reg: ^Face_Registry, name: string) -> Face {
	face, err := face_registry_lookup(reg, name, context.temp_allocator)
	if err != .None {
		return Face{}
	}
	return face
}

// client_display_line_from_text builds a single-atom text line (port
// of the DisplayLine(StringView, Face) constructor). text is borrowed.
client_display_line_from_text :: proc(text: string, face: Face, allocator := context.allocator) -> Display_Line {
	line: Display_Line
	line.atoms = make([dynamic]Display_Atom, 1, allocator)
	line.atoms[0] = Display_Atom{face = face, type = .Text, text = text}
	return line
}

// client_display_line_clone deep-copies a line's atoms array (atom
// text stays borrowed). The caller owns the result.
client_display_line_clone :: proc(line: Display_Line, allocator := context.allocator) -> Display_Line {
	res: Display_Line
	res.range = line.range
	res.atoms = make([dynamic]Display_Atom, len(line.atoms), allocator)
	copy(res.atoms[:], line.atoms[:])
	return res
}

// client_display_line_destroy frees a line's atoms array. Atom text is
// borrowed and untouched.
client_display_line_destroy :: proc(line: ^Display_Line, allocator := context.allocator) {
	delete(line.atoms)
	line.atoms = nil
}

// client_display_line_list_destroy frees every line's atoms array and
// the list itself. Atom text is borrowed and untouched.
client_display_line_list_destroy :: proc(list: ^Display_Line_List, allocator := context.allocator) {
	for &line in list {
		client_display_line_destroy(&line, allocator)
	}
	delete(list^)
	list^ = nil
}

// client_display_line_atoms_equal compares two lines' atoms (port of
// the atoms() != comparison in redraw_ifn).
client_display_line_atoms_equal :: proc(a, b: Display_Line) -> bool {
	if len(a.atoms) != len(b.atoms) {
		return false
	}
	for atom, i in a.atoms {
		if atom != b.atoms[i] {
			return false
		}
	}
	return true
}

// client_info_is_inline reports whether an info style anchors to a
// buffer position (port of is_inline in client.cc).
client_info_is_inline :: proc(style: User_Interface_Info_Style) -> bool {
	return style == .Inline || style == .Inline_Above || style == .Inline_Below
}

// client_expand_escape_proc postprocesses one modeline expansion,
// escaping '{' (port of the expand lambda in generate_mode_line).
client_expand_escape_proc :: proc(data: rawptr, s: string) -> string {
	_ = data
	return string_utils_escape(s, "{", '\\')
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

// client_make builds a client owning ui, window, the selections array
// and env_vars (all heap-allocated, transferred). name and the
// on_exit callback are stored by value. The caller frees the result
// with client_destroy.
client_make :: proc(
	ui: ^User_Interface,
	window: ^Window,
	selections: Selection_List,
	pid: int,
	env_vars: Env_Var_Map,
	name: string,
	on_exit: Client_On_Exit_Callback,
	allocator := context.allocator,
) -> ^Client {
	c := new(Client, allocator)
	c.ui = ui
	c.window = window
	c.pid = pid
	c.on_exit = on_exit
	c.env_vars = env_vars
	c.allocator = allocator
	c.pending_keys = make([dynamic]Keys_Key, allocator)

	input_handler_init(&c.input_handler, selections, {}, name, allocator)
	ctx := input_handler_context(&c.input_handler)

	window_set_client(window, c)
	context_set_client(ctx, c)
	context_set_window(ctx, window)

	window_set_dimensions(window, user_interface_dimensions(ui))
	option_manager_register_watcher(&window.data.options, client_option_watcher(c))

	ui_options := option_manager_get(&window.data.options, "ui_options")
	user_interface_set_ui_options(ui, User_Interface_Options(ui_options.value.(map[string]string)))

	// GAP: set_on_key/set_on_paste cannot be wired: the merged
	// User_Interface callbacks take no user data, so there is no way
	// to reach c from them. The handler bodies live in
	// client_handle_ui_key / client_handle_ui_paste for wiring once
	// the API grows a data pointer.

	hook_manager_run_hook(&window.data.hooks, .Win_Display, buffer_name(window_buffer(window)), ctx)

	client_force_redraw(c)
	return c
}

// client_destroy tears down a client made by client_make: the window
// moves to the client manager's free list (with a copy of the current
// selections, as in the C++ destructor), owned arrays and the ui
// handle are freed, and c itself is freed. The ui implementation's
// data pointer is owned by whoever created the ui and is untouched.
client_destroy :: proc(c: ^Client) {
	if c == nil {
		return
	}
	option_manager_unregister_watcher(&c.window.data.options, client_option_watcher(c))
	window_set_client(c.window, nil)
	// Keep the selections valid for the input handler teardown below;
	// the manager deep-copies them (mirroring the C++ by-value copy).
	client_manager_add_free_window(client_manager_instance(), c.window, context_selections(client_context(c))^)
	input_handler_destroy(&c.input_handler)

	client_display_line_destroy(&c.status_prompt, c.allocator)
	client_display_line_destroy(&c.status_content, c.allocator)
	client_display_line_destroy(&c.mode_line, c.allocator)
	client_display_line_destroy(&c.info.title, c.allocator)
	client_display_line_list_destroy(&c.info.content, c.allocator)
	client_display_line_list_destroy(&c.menu.items, c.allocator)
	delete(c.pending_keys)
	env_vars_free(&c.env_vars, c.allocator)
	free(c.ui, c.allocator)
	alloc := c.allocator
	free(c, alloc)
}

// ---------------------------------------------------------------------------
// Accessors
// ---------------------------------------------------------------------------

// client_context returns the client's context (port of Client::context).
client_context :: proc(c: ^Client) -> ^Context {
	return &c.input_handler.ctx
}

// client_input_handler returns the client's input handler.
client_input_handler :: proc(c: ^Client) -> ^Input_Handler {
	return &c.input_handler
}

// client_pid returns the client's process id.
client_pid :: proc(c: ^Client) -> int {
	return c.pid
}

// client_is_ui_ok reports whether the client's ui is usable.
client_is_ui_ok :: proc(c: ^Client) -> bool {
	return user_interface_is_ok(c.ui)
}

// client_has_pending_inputs reports whether keys are queued.
client_has_pending_inputs :: proc(c: ^Client) -> bool {
	return len(c.pending_keys) != 0
}

// client_info_pending reports whether an info box awaits display.
client_info_pending :: proc(c: ^Client) -> bool {
	return .Info_Show in c.ui_pending
}

// client_status_line_pending reports whether the status line awaits display.
client_status_line_pending :: proc(c: ^Client) -> bool {
	return .Status_Line in c.ui_pending
}

// client_dimensions returns the ui size in display cells.
client_dimensions :: proc(c: ^Client) -> Coord_Display {
	return user_interface_dimensions(c.ui)
}

// client_get_env_var looks up a client environment variable,
// returning "" when missing (port of Client::get_env_var).
client_get_env_var :: proc(c: ^Client, name: string) -> string {
	if value, ok := c.env_vars[name]; ok {
		return value
	}
	return ""
}

// client_exit runs the client's exit callback (port of Client::exit).
client_exit :: proc(c: ^Client, status: int) {
	if c.on_exit.call != nil {
		c.on_exit.call(c.on_exit.data, status)
	}
}

// ---------------------------------------------------------------------------
// Menu, info box and status line
// ---------------------------------------------------------------------------

// client_menu_show replaces the menu, transferring ownership of
// choices to the client. The previous items are freed.
client_menu_show :: proc(c: ^Client, choices: [dynamic]Display_Line, anchor: Coord_Buffer, style: User_Interface_Menu_Style) {
	client_display_line_list_destroy(&c.menu.items, c.allocator)
	c.menu.items = choices
	c.menu.anchor = anchor
	c.menu.ui_anchor = nil
	c.menu.style = style
	c.menu.selected = -1
	c.ui_pending |= {.Menu_Show}
	c.ui_pending &= ~Client_Pending_Ui{.Menu_Hide}
}

// client_menu_select highlights one menu entry.
client_menu_select :: proc(c: ^Client, selected: int) {
	c.menu.selected = selected
	c.ui_pending |= {.Menu_Select}
	c.ui_pending &= ~Client_Pending_Ui{.Menu_Hide}
}

// client_menu_hide clears the menu, freeing its items.
client_menu_hide :: proc(c: ^Client) {
	client_display_line_list_destroy(&c.menu.items, c.allocator)
	c.menu.anchor = Coord_Buffer{}
	c.menu.ui_anchor = nil
	c.menu.style = .Prompt
	c.menu.selected = 0
	c.ui_pending |= {.Menu_Hide}
	c.ui_pending &= ~Client_Pending_Ui{.Menu_Show, .Menu_Select}
}

// client_info_show replaces the info box, transferring ownership of
// title and content to the client. A modal box already on screen is
// left untouched, as in the C++; the previous box is freed.
client_info_show :: proc(
	c: ^Client,
	title: Display_Line,
	content: Display_Line_List,
	anchor: Coord_Buffer,
	style: User_Interface_Info_Style,
) {
	if c.info.style == .Modal {
		// We already have a modal info opened, do not touch it.
		return
	}
	client_display_line_destroy(&c.info.title, c.allocator)
	client_display_line_list_destroy(&c.info.content, c.allocator)
	c.info.title = title
	c.info.content = content
	c.info.anchor = anchor
	c.info.ui_anchor = nil
	c.info.style = style
	c.ui_pending |= {.Info_Show}
	c.ui_pending &= ~Client_Pending_Ui{.Info_Hide}
	c.pending_clear &= ~Client_Pending_Clear{.Info}
}

// client_info_show_string builds an info box from plain text: one
// trailing newline is stripped, content splits on newlines and tabs
// become spaces (port of the StringView overload). title and content
// are borrowed; tab-expanded copies are owned by the box (see the
// module note on atom text ownership).
client_info_show_string :: proc(
	c: ^Client,
	title, content: string,
	anchor: Coord_Buffer,
	style: User_Interface_Info_Style,
) {
	if c.info.style == .Modal {
		// Same early-out as client_info_show, before allocating.
		return
	}
	body := content
	if len(body) > 0 && body[len(body) - 1] == '\n' {
		body = body[:len(body) - 1]
	}
	title_line := Display_Line{}
	if len(title) > 0 {
		title_line = client_display_line_from_text(title, Face{}, c.allocator)
	}
	parts := ranges_split(body, '\n', c.allocator)
	defer delete(parts)
	list := make(Display_Line_List, len(parts), c.allocator)
	for part, i in parts {
		// Borrow tab-free lines; only tab expansion allocates, and
		// those copies are owned by the box (see the module note).
		text := part
		if strings.contains_rune(part, '\t') {
			text = string_utils_replace(part, "\t", " ", c.allocator)
		}
		list[i] = client_display_line_from_text(text, Face{}, c.allocator)
	}
	client_info_show(c, title_line, list, anchor, style)
}

// client_info_hide clears the info box, freeing it. A modal box needs
// even_modal to be dismissed.
client_info_hide :: proc(c: ^Client, even_modal := false) {
	if !even_modal && c.info.style == .Modal {
		return
	}
	client_display_line_destroy(&c.info.title, c.allocator)
	client_display_line_list_destroy(&c.info.content, c.allocator)
	c.info.anchor = Coord_Buffer{}
	c.info.ui_anchor = nil
	c.info.style = .Prompt
	c.ui_pending |= {.Info_Hide}
	c.ui_pending &= ~Client_Pending_Ui{.Info_Show}
}

// client_print_status replaces the status line, transferring ownership
// of prompt and content to the client. The previous line is freed.
client_print_status :: proc(
	c: ^Client,
	prompt, content: Display_Line,
	cursor_pos: Units_ColumnCount,
	style: User_Interface_Status_Style,
) {
	client_display_line_destroy(&c.status_prompt, c.allocator)
	client_display_line_destroy(&c.status_content, c.allocator)
	c.status_prompt = prompt
	c.status_content = content
	c.status_cursor_pos = cursor_pos
	c.status_style = style
	c.ui_pending |= {.Status_Line}
	c.pending_clear &= ~Client_Pending_Clear{.Status_Line}
}

// client_schedule_clear marks the info box and status line for
// clearing on the next redraw, unless already pending.
client_schedule_clear :: proc(c: ^Client) {
	if .Info_Show not_in c.ui_pending {
		c.pending_clear |= {.Info}
	}
	if .Status_Line not_in c.ui_pending {
		c.pending_clear |= {.Status_Line}
	}
}

// client_clear_pending clears whatever client_schedule_clear marked.
client_clear_pending :: proc(c: ^Client) {
	if .Status_Line in c.pending_clear {
		client_print_status(c, Display_Line{}, Display_Line{}, Units_ColumnCount(-1), .Status)
	}
	if .Info in c.pending_clear {
		client_info_hide(c)
	}
	c.pending_clear = Client_Pending_Clear{}
}

// client_force_redraw flags a redraw; full also refreshes the menu,
// info box and status line.
client_force_redraw :: proc(c: ^Client, full := false) {
	if full {
		c.ui_pending |= {.Refresh, .Draw, .Status_Line}
		if len(c.menu.items) == 0 {
			c.ui_pending |= {.Menu_Hide}
		} else {
			c.ui_pending |= {.Menu_Show, .Menu_Select}
		}
		if len(c.info.content) == 0 {
			c.ui_pending |= {.Info_Hide}
		} else {
			c.ui_pending |= {.Info_Show}
		}
	} else {
		c.ui_pending |= {.Draw}
	}
}

// ---------------------------------------------------------------------------
// Input handling
// ---------------------------------------------------------------------------

// client_handle_ui_key handles one key from the ui (port of the
// set_on_key callback in the constructor). It returns true when key
// processing must be aborted (port of `throw cancel{}` on ctrl-g).
client_handle_ui_key :: proc(c: ^Client, key: Keys_Key) -> (cancelled: bool) {
	assert(key != Keys_Key{key = keys_INVALID})
	if key == (Keys_Key{modifiers = keys_MOD_CONTROL, key = 'c'}) {
		ignore, prev: posix.sigaction_t
		posix.sigemptyset(&ignore.sa_mask)
		ignore.sa_handler = cast(proc "c"(posix.Signal))(posix.SIG_IGN)
		ignore.sa_flags = {.RESTART}
		posix.sigaction(.SIGINT, &ignore, &prev)
		posix.killpg(posix.getpgrp(), .SIGINT)
		posix.sigaction(.SIGINT, &prev, nil)
		return false
	} else if key == (Keys_Key{modifiers = keys_MOD_CONTROL, key = 'g'}) {
		clear(&c.pending_keys)
		content := client_display_line_from_text(
			"operation cancelled",
			client_face(context_faces(client_context(c)), "Error"),
			c.allocator,
		)
		client_print_status(c, Display_Line{}, content, Units_ColumnCount(-1), .Status)
		return true
	} else if key.modifiers & keys_MOD_RESIZE != keys_MOD_NONE {
		coord := keys_coord(key)
		window_set_dimensions(c.window, Coord_Display{Coord_Line(coord.line), Coord_Column(coord.column)})
		client_force_redraw(c, true)
		return false
	}
	append(&c.pending_keys, key)
	return false
}

// client_handle_ui_paste pastes ui-provided text (port of the
// set_on_paste callback in the constructor).
client_handle_ui_paste :: proc(c: ^Client, content: string) {
	input_handler_paste(context_input_handler(client_context(c)), content)
}

// client_process_pending_inputs dispatches the queued keys, stealing
// the queue first since handling may queue more. It returns whether
// any key was handled.
//
// GAP: the C++ reports per-key runtime_errors on the status line and
// through the RuntimeError hook; without error returns on the input
// handler that path is unported (see the module note).
client_process_pending_inputs :: proc(c: ^Client) -> bool {
	ctx := client_context(c)
	debug_opt := option_manager_get(context_options(ctx), "debug")
	debug_keys := .Keys in option_get_debug_flags(debug_opt)
	window_run_resize_hook_ifn(c.window)
	// Steal keys as we might receive new keys while handling them.
	keys := c.pending_keys
	c.pending_keys = make([dynamic]Keys_Key, c.allocator)
	defer delete(keys)
	for key in keys {
		if debug_keys {
			key_name := keys_to_string_key(key, context.temp_allocator)
			msg, err := format_format(
				"Client '{}' got key '{}'",
				[]string{context_name(ctx), key_name},
				context.temp_allocator,
			)
			if err == .None {
				debug_write_to_buffer(msg)
			}
		}
		if key == (Keys_Key{key = keys_FOCUS_IN}) {
			hook_manager_run_hook(context_hooks(ctx), .Focus_In, context_name(ctx), ctx)
		} else if key == (Keys_Key{key = keys_FOCUS_OUT}) {
			hook_manager_run_hook(context_hooks(ctx), .Focus_Out, context_name(ctx), ctx)
		} else {
			ctx.ensure_cursor_visible = true
			input_handler_handle_key(&c.input_handler, key, false)
		}
		raw_name := keys_to_string_key(key, context.temp_allocator)
		hook_manager_run_hook(context_hooks(ctx), .Raw_Key, raw_name, ctx)
	}
	return len(keys) != 0
}

// ---------------------------------------------------------------------------
// Redraw
// ---------------------------------------------------------------------------

// client_redraw_ifn flushes pending ui updates: the main area, menu,
// info box, mode line and status line (port of Client::redraw_ifn).
client_redraw_ifn :: proc(c: ^Client) {
	ctx := client_context(c)
	window := context_window(ctx)
	if window_needs_redraw(window, ctx) {
		c.ui_pending |= {.Draw}
	}
	faces := context_faces(ctx)

	if .Draw in c.ui_pending {
		db := window_update_display_buffer(window, ctx)
		sels := context_selections(ctx)
		main_cursor := sels.selections[sels.main].cursor.coord
		cursor_pos := Coord_Display{}
		if pos, ok := window_display_coord(window, main_cursor).?; ok {
			cursor_pos = pos
		}
		user_interface_draw(
			c.ui,
			KNOTFIX_ui_buffer(db),
			cursor_pos,
			client_face(faces, "Default"),
			client_face(faces, "BufferPadding"),
			window_last_display_setup(window).widget_columns,
		)
	}

	update_menu_anchor :=
		.Draw in c.ui_pending &&
		.Menu_Hide not_in c.ui_pending &&
		len(c.menu.items) != 0 &&
		c.menu.style == .Inline
	if .Menu_Show in c.ui_pending || update_menu_anchor {
		anchor: Maybe(Coord_Display)
		if c.menu.style == .Inline {
			anchor = window_display_coord(window, c.menu.anchor)
		} else {
			anchor = Coord_Display{}
		}
		if .Menu_Show not_in c.ui_pending && c.menu.ui_anchor != anchor {
			if _, ok := anchor.?; ok {
				c.ui_pending |= {.Menu_Show, .Menu_Select}
			} else {
				c.ui_pending |= {.Menu_Hide}
			}
		}
		c.menu.ui_anchor = anchor
	}

	if .Menu_Show in c.ui_pending {
		if ui_anchor, ok := c.menu.ui_anchor.?; ok {
			choices := KNOTFIX_ui_lines(c.menu.items[:], context.temp_allocator)
			defer delete(choices)
			user_interface_menu_show(
				c.ui,
				choices,
				ui_anchor,
				client_face(faces, "MenuForeground"),
				client_face(faces, "MenuBackground"),
				c.menu.style,
			)
		}
	}
	if .Menu_Select in c.ui_pending {
		if _, ok := c.menu.ui_anchor.?; ok {
			user_interface_menu_select(c.ui, c.menu.selected)
		}
	}
	if .Menu_Hide in c.ui_pending {
		user_interface_menu_hide(c.ui)
	}

	update_info_anchor :=
		.Draw in c.ui_pending &&
		.Info_Hide not_in c.ui_pending &&
		len(c.info.content) != 0 &&
		client_info_is_inline(c.info.style)
	if .Info_Show in c.ui_pending || update_info_anchor {
		anchor: Maybe(Coord_Display)
		if client_info_is_inline(c.info.style) {
			anchor = window_display_coord(window, c.info.anchor)
		} else {
			anchor = Coord_Display{}
		}
		// Mirrors upstream, which tests Menu_Show here rather than Info_Show.
		if .Menu_Show not_in c.ui_pending && c.info.ui_anchor != anchor {
			if _, ok := anchor.?; ok {
				c.ui_pending |= {.Info_Show}
			} else {
				c.ui_pending |= {.Info_Hide}
			}
		}
		c.info.ui_anchor = anchor
	}

	if .Info_Show in c.ui_pending {
		if ui_anchor, ok := c.info.ui_anchor.?; ok {
			title := KNOTFIX_ui_line(&c.info.title)
			content := KNOTFIX_ui_lines(c.info.content[:], context.temp_allocator)
			defer delete(content)
			face_name := "Information"
			if client_info_is_inline(c.info.style) || c.info.style == .Menu_Doc {
				face_name = "InlineInformation"
			}
			user_interface_info_show(c.ui, &title, content, ui_anchor, client_face(faces, face_name), c.info.style)
		}
	}
	if .Info_Hide in c.ui_pending {
		user_interface_info_hide(c.ui)
	}

	// This needs to be done *after* update_display_buffer as the mode
	// line may rely on it to compute whether selections are visible.
	mode_line := client_generate_mode_line(c, c.allocator)
	if !client_display_line_atoms_equal(mode_line, c.mode_line) {
		c.ui_pending |= {.Status_Line}
		client_display_line_destroy(&c.mode_line, c.allocator)
		c.mode_line = mode_line
	} else {
		client_display_line_destroy(&mode_line, c.allocator)
	}
	if .Status_Line in c.ui_pending {
		prompt := KNOTFIX_ui_line(&c.status_prompt)
		content := KNOTFIX_ui_line(&c.status_content)
		mode := KNOTFIX_ui_line(&c.mode_line)
		user_interface_draw_status(
			c.ui,
			&prompt,
			&content,
			c.status_cursor_pos,
			&mode,
			client_face(faces, "StatusLine"),
			c.status_style,
		)
	}

	if card(c.ui_pending) != 0 {
		user_interface_refresh(c.ui, .Refresh in c.ui_pending)
	}
	c.ui_pending = Client_Pending_Ui{}
}

// client_generate_mode_line expands the modelinefmt option into the
// mode line (port of Client::generate_mode_line). The caller owns the
// result.
//
// NOTE: on modelinefmt parse errors the C++ keeps the previous modeline;
// the port logs to the debug buffer and yields an empty line instead.
client_generate_mode_line :: proc(c: ^Client, allocator := context.allocator) -> Display_Line {
	ctx := client_context(c)
	info := input_handler_mode_info(&c.input_handler, allocator)
	modelinefmt_opt := option_manager_get(context_options(ctx), "modelinefmt")
	modelinefmt := modelinefmt_opt.value.(string)
	atoms := make(map[string]Display_Line, 2, allocator)
	defer delete(atoms)
	atoms["mode_info"] = info.display_line
	context_info := client_display_line_from_text(
		client_generate_context_info(ctx, allocator),
		client_face(context_faces(ctx), "Information"),
		allocator,
	)
	atoms["context_info"] = context_info
	shell_env := make(Env_Var_Map, 2, allocator)
	defer env_vars_free(&shell_env, allocator)
	_, has_params := info.normal_params.?
	if params, ok := info.normal_params.?; ok {
		shell_env["register"] = format_to_string(params.reg, allocator)
		shell_env["count"] = format_to_string(params.count, allocator)
	} else {
		shell_env["register"] = ""
		shell_env["count"] = ""
	}
	shell_ctx := Shell_Context{env_vars = shell_env}
	expanded := command_expand(modelinefmt, ctx, &shell_ctx, Client_Postprocess{client_expand_escape_proc, nil}, allocator)
	defer delete(expanded, allocator)
	// The parse borrows atoms/expanded and copies what it keeps (as in
	// the C++), so the locals are freed here like C++ scope-exit.
	result, parse_err := display_buffer_parse_line(expanded, context_faces(ctx), atoms, allocator)
	if parse_err != .None {
		// C++ parity: client.cc catches the parse throw, logs it to the
		// debug buffer, and keeps the previous modeline. The port cannot
		// alias the previous line safely here, so it logs and yields an
		// empty line instead (only reachable with a malformed modelinefmt).
		display_buffer_line_destroy(&result)
		result = display_buffer_line_make(allocator)
		err_name := "unknown parse error"
		switch parse_err {
		case .Unclosed_Face:
			err_name = "unclosed face definition"
		case .Undefined_Atom:
			err_name = "undefined atom"
		case .Invalid_Face:
			err_name = "invalid face"
		case .None:
		}
		parts := [2]string{"Error while parsing modelinefmt: ", err_name}
		msg := strings.concatenate(parts[:], allocator)
		debug_write_to_buffer(msg)
		delete(msg, allocator)
	}
	client_display_line_destroy(&info.display_line, allocator)
	client_display_line_destroy(&context_info, allocator)
	if has_params {
		delete(shell_env["register"], allocator)
		delete(shell_env["count"], allocator)
	}
	return result
}

// client_generate_context_info builds the bracketed buffer state flags
// for the mode line (port of generate_context_info in client.cc).
// The caller owns the result.
client_generate_context_info :: proc(ctx: ^Context, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	defer strings.builder_destroy(&b)
	buffer := context_buffer(ctx)
	if buffer_is_modified(buffer) {
		strings.write_string(&b, "[+]")
	}
	handler := client_input_handler(context_client(ctx))
	if input_handler_is_recording(handler) {
		reg := format_to_string(input_handler_recording_reg(handler), context.temp_allocator)
		msg, err := format_format("[recording ({})]", []string{reg}, context.temp_allocator)
		if err == .None {
			strings.write_string(&b, msg)
		}
	}
	if utils_nested_bool_is_set(context_hooks_disabled(ctx)^) {
		strings.write_string(&b, "[no-hooks]")
	}
	if .File not_in buffer.flags && .Debug not_in buffer.flags {
		strings.write_string(&b, "[scratch]")
	}
	if .New in buffer.flags {
		strings.write_string(&b, "[new file]")
	}
	if .Fifo in buffer.flags {
		strings.write_string(&b, "[fifo]")
	}
	if .Debug in buffer.flags {
		strings.write_string(&b, "[debug]")
	}
	if .Read_Only in buffer.flags {
		strings.write_string(&b, "[readonly]")
	}
	return strings.clone(strings.to_string(b), allocator)
}

// ---------------------------------------------------------------------------
// Buffer switching and reloading
// ---------------------------------------------------------------------------

// client_change_buffer switches the client to buffer, recycling the
// old window through the client manager (port of Client::change_buffer).
// set_selections replaces the recycled selections when present. It
// returns .Buffer_Locked when the current buffer forbids the switch.
client_change_buffer :: proc(c: ^Client, buffer: ^Buffer, set_selections: Maybe(Client_Selection_Callback)) -> Client_Error {
	ctx := client_context(c)
	if c.buffer_reload_dialog_opened {
		client_close_buffer_reload_dialog(c)
	}
	if .Locked in context_buffer(ctx).flags {
		return .Buffer_Locked
	}

	buffer.flags |= {.Locked}
	defer buffer.flags &= ~Buffer_Flags{.Locked}

	manager := client_manager_instance()
	ws := client_manager_get_free_window(manager, buffer)

	option_manager_unregister_watcher(&c.window.data.options, client_option_watcher(c))
	window_set_client(c.window, nil)
	// The manager deep-copies the selections (mirroring the C++
	// by-value copy); the input handler keeps owning them.
	client_manager_add_free_window(manager, c.window, context_selections(ctx)^)

	c.window = ws.window
	window_set_client(c.window, c)
	option_manager_register_watcher(&c.window.data.options, client_option_watcher(c))

	if callback, ok := set_selections.?; ok {
		callback.call(callback.data)
	} else {
		edition := scoped_selection_edition_make(ctx)
		dst := context_selections_write_only(ctx)
		selection_list_destroy(dst)
		dst^ = ws.selections
		scoped_selection_edition_destroy(&edition)
	}

	context_set_window(ctx, c.window)

	window_set_dimensions(c.window, user_interface_dimensions(c.ui))
	ui_options := option_manager_get(&c.window.data.options, "ui_options")
	user_interface_set_ui_options(c.ui, User_Interface_Options(ui_options.value.(map[string]string)))

	hook_manager_run_hook(&c.window.data.hooks, .Win_Display, buffer_name(buffer), ctx)
	client_force_redraw(c, true)
	return .None
}

// client_reload_buffer reloads the client's buffer from disk (port of
// Client::reload_buffer).
//
// GAP: the C++ reports reload failures on the status line and refreshes
// the fs status; without error returns that path is unported (see the
// module note).
client_reload_buffer :: proc(c: ^Client) {
	ctx := client_context(c)
	buffer := context_buffer(ctx)
	buffer_utils_reload_file_buffer(buffer)
	msg, err := format_format("'{}' reloaded", []string{buffer.display_name}, c.allocator)
	if err != .None {
		msg = "'?' reloaded"
	}
	content := client_display_line_from_text(msg, client_face(context_faces(ctx), "Information"), c.allocator)
	client_print_status(c, Display_Line{}, content, Units_ColumnCount(-1), .Status)
	hook_manager_run_hook(context_hooks(ctx), .Buf_Reload, buffer_name(buffer), ctx)
}

// client_set_autoreload sets the autoreload option, at buffer level at
// least: a global option is shadowed locally rather than touched
// (port of the set_autoreload lambda in on_buffer_reload_key).
client_set_autoreload :: proc(c: ^Client, autoreload: Autoreload) {
	ctx := client_context(c)
	option := option_manager_get(context_options(ctx), "autoreload")
	// Do not touch global autoreload, set it at least at buffer level
	if option.manager == &global_scope_instance().data.options {
		option = option_manager_get_local(&context_buffer(ctx).data.options, "autoreload")
	}
	option_set_autoreload(option, autoreload)
}

// client_on_buffer_reload_key handles one reload-dialog key (port of
// Client::on_buffer_reload_key).
client_on_buffer_reload_key :: proc(c: ^Client, key: Keys_Key) {
	ctx := client_context(c)
	buffer := context_buffer(ctx)
	if key == (Keys_Key{key = 'y'}) || key == (Keys_Key{key = 'Y'}) || key == (Keys_Key{key = keys_RETURN}) {
		client_reload_buffer(c)
		if key == (Keys_Key{key = 'Y'}) {
			client_set_autoreload(c, .Yes)
		}
	} else if key == (Keys_Key{key = 'n'}) || key == (Keys_Key{key = 'N'}) || key == (Keys_Key{key = keys_ESCAPE}) {
		// Reread timestamp in case the file was modified again
		if status, err := file_get_fs_status(buffer.filename); err == .None {
			buffer_set_fs_status(buffer, status)
		}
		msg, err := format_format("'{}' kept", []string{buffer.display_name}, c.allocator)
		if err != .None {
			msg = "'?' kept"
		}
		content := client_display_line_from_text(msg, client_face(context_faces(ctx), "Information"), c.allocator)
		client_print_status(c, Display_Line{}, content, Units_ColumnCount(-1), .Status)
		if key == (Keys_Key{key = 'N'}) {
			client_set_autoreload(c, .No)
		}
	} else {
		key_name := keys_to_string_key(key, context.temp_allocator)
		msg, err := format_format("'{}' is not a valid choice", []string{key_name}, c.allocator)
		if err != .None {
			msg = "'?' is not a valid choice"
		}
		content := client_display_line_from_text(msg, client_face(context_faces(ctx), "Error"), c.allocator)
		client_print_status(c, Display_Line{}, content, Units_ColumnCount(-1), .Status)
		input_handler_on_next_key(
			&c.input_handler,
			"buffer-reload",
			.None,
			Key_Callback{client_buffer_reload_key_callback, c, nil},
		)
		return
	}

	for other in client_manager_instance().clients {
		if context_buffer(client_context(other)) == buffer && other.buffer_reload_dialog_opened {
			client_close_buffer_reload_dialog(other)
		}
	}
}

// client_buffer_reload_key_callback routes on_next_key events to
// client_on_buffer_reload_key.
client_buffer_reload_key_callback :: proc(data: rawptr, key: Keys_Key, ctx: ^Context) {
	_ = ctx
	client_on_buffer_reload_key(cast(^Client)data, key)
}

// client_close_buffer_reload_dialog dismisses the reload dialog (port
// of Client::close_buffer_reload_dialog).
client_close_buffer_reload_dialog :: proc(c: ^Client) {
	assert(c.buffer_reload_dialog_opened)
	// Reset first as this might check for reloading.
	input_handler_reset_normal_mode(&c.input_handler)
	c.buffer_reload_dialog_opened = false
	client_info_hide(c, true)
}

// client_check_if_buffer_needs_reloading opens the reload dialog, or
// reloads directly, when the file changed on disk (port of
// Client::check_if_buffer_needs_reloading).
//
// GAP: the C++ reports check failures to the debug buffer; without
// error returns that path is unported (see the module note).
client_check_if_buffer_needs_reloading :: proc(c: ^Client) {
	if c.buffer_reload_dialog_opened {
		return
	}
	ctx := client_context(c)
	buffer := context_buffer(ctx)
	reload := option_get_autoreload(option_manager_get(context_options(ctx), "autoreload"))
	if .File not_in buffer.flags || reload == .No {
		return
	}

	filename := buffer.filename
	ts := file_get_fs_timestamp(filename)
	status := buffer.fs_status
	if ts == File_Invalid_Time || ts == status.timestamp {
		return
	}

	mapped, err := file_mapped_file_open(filename)
	if err != .None {
		return
	}
	view, view_err := file_mapped_file_view(mapped)
	same := view_err == .None && len(mapped.data) == status.file_size && hash_murmur3(view) == status.hash
	file_mapped_file_close(&mapped)
	if same {
		return
	}

	if reload == .Ask {
		title, title_err := format_format("reload '{}' ?", []string{buffer.display_name}, c.allocator)
		content, content_err := format_format(
			"'{}' was modified externally\n y, <ret>: reload | n, <esc>: keep\n Y: always reload | N: always keep\n",
			[]string{buffer.display_name},
			c.allocator,
		)
		if title_err != .None {
			title = "reload '?' ?"
		}
		if content_err != .None {
			content = "'?' was modified externally\n"
		}
		client_info_show_string(c, title, content, Coord_Buffer{}, .Modal)
		// The box borrows title/content slices and owns tab-expanded
		// copies; the format results stay alive with the client.
		c.buffer_reload_dialog_opened = true
		input_handler_on_next_key(
			&c.input_handler,
			"buffer-reload",
			.None,
			Key_Callback{client_buffer_reload_key_callback, c, nil},
		)
	} else {
		client_reload_buffer(c)
	}
}

// ---------------------------------------------------------------------------
// Option watching
// ---------------------------------------------------------------------------

// client_on_option_changed applies ui_options changes and flags a
// redraw (a highlighter might depend on the option). It is the
// OptionWatcher::on_option_changed port; wire it with
// client_option_watcher.
client_on_option_changed :: proc(c: ^Client, option: ^Option) {
	if option.desc.name == "ui_options" {
		if opts, ok := option.value.(map[string]string); ok {
			user_interface_set_ui_options(c.ui, User_Interface_Options(opts))
		}
	}
	// A highlighter might depend on the option, so we need to redraw
	c.ui_pending |= {.Draw}
}

// client_option_watcher builds the Option_Watcher observing c.
client_option_watcher :: proc(c: ^Client) -> Option_Watcher {
	return Option_Watcher{data = c, on_option_changed = client_option_watcher_callback}
}

// client_option_watcher_callback routes watcher notifications to
// client_on_option_changed.
client_option_watcher_callback :: proc(data: rawptr, option: rawptr) {
	client_on_option_changed(cast(^Client)data, cast(^Option)option)
}

// ---------------------------------------------------------------------------
// Busy indicator
// ---------------------------------------------------------------------------

// client_busy_indicator_make starts a busy indicator for ctx: after
// client_BUSY_WAIT_TIMEOUT the status line shows the message built by
// status_message until client_busy_indicator_destroy restores it
// (port of the BusyIndicator constructor). bi must stay at a stable
// address until destroyed, since the timer callback finds its entry
// through &bi.timer.
client_busy_indicator_make :: proc(
	bi: ^Busy_Indicator,
	ctx: ^Context,
	status_message: Client_Busy_Status_Callback,
	wait_time: Clock_Time, // C++ defaults this to Clock::now(); pass clock_now()
) {
	bi.ctx = ctx
	bi.previous_status = nil
	event_manager_timer_init(
		&bi.timer,
		clock_add(wait_time, client_BUSY_WAIT_TIMEOUT),
		client_busy_timer_fire,
		.Urgent, // C++ EventMode::Urgent
	)
	if client_busy_entries == nil {
		client_busy_entries = make(map[^Event_Manager_Timer]Client_Busy_Entry)
	}
	client_busy_entries[&bi.timer] = Client_Busy_Entry{bi, status_message, wait_time}
}

// client_busy_timer_fire shows (and refreshes) the busy status line
// (port of the BusyIndicator timer lambda).
client_busy_timer_fire :: proc(timer: ^Event_Manager_Timer) {
	entry, ok := client_busy_entries[timer]
	if !ok {
		return
	}
	ctx := entry.indicator.ctx
	if !context_has_client(ctx) {
		return
	}
	now := clock_now()
	// Port of Timer::set_next_date; no merged setter exists yet.
	timer.date = clock_add(now, client_BUSY_WAIT_TIMEOUT)

	client := context_client(ctx)
	if _, has := entry.indicator.previous_status.?; !has {
		entry.indicator.previous_status = Busy_Indicator_Previous_Status{
			client_display_line_clone(client.status_prompt, client.allocator),
			client_display_line_clone(client.status_content, client.allocator),
			client.status_cursor_pos,
			client.status_style,
		}
	}

	elapsed := i64(time.duration_seconds(clock_diff(entry.wait_time, now)))
	msg := entry.status_message.call(entry.status_message.data, elapsed, client.allocator)
	client_print_status(client, Display_Line{}, msg, Units_ColumnCount(-1), .Status)
	client_redraw_ifn(client)
}

// client_busy_indicator_destroy stops the indicator, freeing its
// status callback, and restores the status line saved on first fire
// (port of the BusyIndicator destructor; the C++ skips the restore
// while unwinding an exception, which has no Odin equivalent).
client_busy_indicator_destroy :: proc(bi: ^Busy_Indicator) {
	event_manager_timer_destroy(&bi.timer)
	if entry, ok := client_busy_entries[&bi.timer]; ok {
		delete_key(&client_busy_entries, &bi.timer)
		if entry.status_message.destroy != nil {
			entry.status_message.destroy(entry.status_message.data, context.allocator)
		}
	}
	if len(client_busy_entries) == 0 {
		delete(client_busy_entries)
		client_busy_entries = nil
	}
	if prev, has := bi.previous_status.?; has {
		ctx := bi.ctx
		context_print_status(ctx, prev.prompt, prev.content, prev.cursor_pos, prev.style)
		client_redraw_ifn(context_client(ctx))
		bi.previous_status = nil
	}
}

// ---------------------------------------------------------------------------
// STUBS: called-but-unmerged procs (STUB protocol; coordinator deletes
// these when the owning modules merge)
// ---------------------------------------------------------------------------

window_set_client :: proc(w: ^Window, c: ^Client) {
	panic("STUB: window_set_client")
}

window_set_dimensions :: proc(w: ^Window, dim: Coord_Display) {
	panic("STUB: window_set_dimensions")
}

window_run_resize_hook_ifn :: proc(w: ^Window) {
	panic("STUB: window_run_resize_hook_ifn")
}

window_needs_redraw :: proc(w: ^Window, ctx: ^Context) -> bool {
	panic("STUB: window_needs_redraw")
}

window_update_display_buffer :: proc(w: ^Window, ctx: ^Context) -> ^Display_Buffer {
	panic("STUB: window_update_display_buffer")
}

window_display_coord :: proc(w: ^Window, coord: Coord_Buffer) -> Maybe(Coord_Display) {
	panic("STUB: window_display_coord")
}

window_buffer :: proc(w: ^Window) -> ^Buffer {
	panic("STUB: window_buffer")
}

window_last_display_setup :: proc(w: ^Window) -> ^Display_Setup {
	panic("STUB: window_last_display_setup")
}

context_options :: proc(ctx: ^Context) -> ^Option_Manager {
	panic("STUB: context_options")
}

context_hooks :: proc(ctx: ^Context) -> ^Hook_Manager {
	panic("STUB: context_hooks")
}

context_faces :: proc(ctx: ^Context, allow_local := true) -> ^Face_Registry {
	panic("STUB: context_faces")
}

context_buffer :: proc(ctx: ^Context) -> ^Buffer {
	panic("STUB: context_buffer")
}

context_client :: proc(ctx: ^Context) -> ^Client {
	panic("STUB: context_client")
}

context_window :: proc(ctx: ^Context) -> ^Window {
	panic("STUB: context_window")
}

context_has_client :: proc(ctx: ^Context) -> bool {
	panic("STUB: context_has_client")
}

context_input_handler :: proc(ctx: ^Context) -> ^Input_Handler {
	panic("STUB: context_input_handler")
}

context_selections :: proc(ctx: ^Context, update := true) -> ^Selection_List {
	panic("STUB: context_selections")
}

context_selections_write_only :: proc(ctx: ^Context) -> ^Selection_List {
	panic("STUB: context_selections_write_only")
}

context_print_status :: proc(
	ctx: ^Context,
	prompt, content: Display_Line,
	cursor_pos: Units_ColumnCount,
	style: User_Interface_Status_Style,
) {
	panic("STUB: context_print_status")
}

context_set_client :: proc(ctx: ^Context, c: ^Client) {
	panic("STUB: context_set_client")
}

context_set_window :: proc(ctx: ^Context, w: ^Window) {
	panic("STUB: context_set_window")
}

context_name :: proc(ctx: ^Context) -> string {
	panic("STUB: context_name")
}

context_hooks_disabled :: proc(ctx: ^Context) -> ^Utils_Nested_Bool {
	panic("STUB: context_hooks_disabled")
}

scoped_selection_edition_make :: proc(ctx: ^Context) -> Scoped_Selection_Edition {
	panic("STUB: scoped_selection_edition_make")
}

scoped_selection_edition_destroy :: proc(e: ^Scoped_Selection_Edition) {
	panic("STUB: scoped_selection_edition_destroy")
}

input_handler_init :: proc(
	h: ^Input_Handler,
	selections: Selection_List,
	flags: Context_Flags,
	name: string,
	allocator := context.allocator,
) {
	panic("STUB: input_handler_init")
}

input_handler_destroy :: proc(h: ^Input_Handler) {
	panic("STUB: input_handler_destroy")
}

input_handler_context :: proc(h: ^Input_Handler) -> ^Context {
	panic("STUB: input_handler_context")
}

input_handler_handle_key :: proc(h: ^Input_Handler, key: Keys_Key, synthesized := true) {
	panic("STUB: input_handler_handle_key")
}

input_handler_on_next_key :: proc(h: ^Input_Handler, mode_name: string, mode: Keymap_Manager_Mode, callback: Key_Callback) {
	panic("STUB: input_handler_on_next_key")
}

input_handler_reset_normal_mode :: proc(h: ^Input_Handler) {
	panic("STUB: input_handler_reset_normal_mode")
}

input_handler_mode_info :: proc(h: ^Input_Handler, allocator := context.allocator) -> Mode_Info {
	panic("STUB: input_handler_mode_info")
}

input_handler_is_recording :: proc(h: ^Input_Handler) -> bool {
	panic("STUB: input_handler_is_recording")
}

input_handler_recording_reg :: proc(h: ^Input_Handler) -> rune {
	panic("STUB: input_handler_recording_reg")
}

input_handler_paste :: proc(h: ^Input_Handler, content: string) {
	panic("STUB: input_handler_paste")
}

option_manager_get :: proc(m: ^Option_Manager, name: string) -> ^Option {
	panic("STUB: option_manager_get")
}

option_manager_get_local :: proc(m: ^Option_Manager, name: string) -> ^Option {
	panic("STUB: option_manager_get_local")
}

option_manager_register_watcher :: proc(m: ^Option_Manager, w: Option_Watcher) {
	panic("STUB: option_manager_register_watcher")
}

option_manager_unregister_watcher :: proc(m: ^Option_Manager, w: Option_Watcher) {
	panic("STUB: option_manager_unregister_watcher")
}

option_get_debug_flags :: proc(o: ^Option) -> Option_types_Debug_Flags {
	panic("STUB: option_get_debug_flags")
}

option_get_autoreload :: proc(o: ^Option) -> Autoreload {
	panic("STUB: option_get_autoreload")
}

option_set_autoreload :: proc(o: ^Option, value: Autoreload) {
	panic("STUB: option_set_autoreload")
}

global_scope_instance :: proc() -> ^Global_Scope {
	panic("STUB: global_scope_instance")
}

client_manager_instance :: proc() -> ^Client_Manager {
	panic("STUB: client_manager_instance")
}

client_manager_add_free_window :: proc(m: ^Client_Manager, window: ^Window, selections: Selection_List) {
	panic("STUB: client_manager_add_free_window")
}

client_manager_get_free_window :: proc(m: ^Client_Manager, buffer: ^Buffer) -> Window_And_Selections {
	panic("STUB: client_manager_get_free_window")
}

buffer_utils_reload_file_buffer :: proc(b: ^Buffer) {
	panic("STUB: buffer_utils_reload_file_buffer")
}

debug_write_to_buffer :: proc(s: string) {
	panic("STUB: debug_write_to_buffer")
}

command_expand :: proc(
	str: string,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
	postprocess: Client_Postprocess,
	allocator := context.allocator,
) -> string {
	panic("STUB: command_expand")
}
