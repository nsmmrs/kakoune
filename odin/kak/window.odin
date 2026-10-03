// Port of Kakoune's src/window.hh and src/window.cc: Window, a view onto a
// Buffer.
//
// Mapping notes:
//   * C++ Window is heap-owned (UniquePtr) and non-copyable; window_make
//     returns a heap Window (^Window via new) and window_destroy frees it,
//     including the storage. Never copy a Window after make (the registered
//     option watcher pins its address).
//   * C++ Optional<DisplayCoord>/Optional<BufferCoord> become
//     Maybe(Coord_Display)/Maybe(Coord_Buffer).
//   * C++ Window throws no errors; Window_Error exists for interface
//     symmetry and future fallible operations.
//   * The one-line Buffer inlines (timestamp, line_count, end_coord,
//     operator[] in buffer.inl.hh/buffer.hh) are read directly off knot
//     Buffer fields at each use site; every other cross-module call is an
//     exact STUB one-liner (see the stubs section at the end).
//   * C++-private helpers used only inside this file are @(private="file").
//     window_compute_faces_hash stays public: it is the one display-input
//     helper testable without unmerged modules.
//   * update_display_buffer skips the C++ ProfileScope (diagnostic timing
//     only; the debug-buffer timing lines it may emit are not reproduced).
//   * compute_faces_hash sorts the flattened faces by name before folding.
//     The C++ relies on its HashMap iteration order being stable within a
//     run; Odin map iteration is randomized per loop, so sorting keeps the
//     hash (only ever compared within a run) deterministic.
//
// Ownership: the caller owns the ^Window; window_destroy frees the display
// buffer, the cached setup selections, the scope and the storage.
package kak

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

// Window_Error is the window error set. C++ Window operations never throw
// (they assert or return Optional), so None is currently the only value;
// the enum exists for interface symmetry with the other knot modules.
Window_Error :: enum {
	None,
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

// window_make builds a window onto buffer (C++ Window::Window): child scope,
// option watcher, builtin highlighters, and an initial option-changed pass.
window_make :: proc(buffer: ^Buffer, allocator := context.allocator) -> ^Window {
	win := new(Window, allocator)
	win.buffer = buffer
	win.allocator = allocator
	win.display_buffer.lines = make(Display_Line_List, 0, allocator)
	win.display_buffer.timestamp = -1 // C++ DisplayBuffer{} defaults m_timestamp to -1
	win.scope = scope_make_child(&buffer.scope, allocator)
	name := buffer.display_name
	if .File in buffer.flags {
		name = buffer.filename // C++ Buffer::name()
	}
	window_run_hook_in_own_context(win, .Win_Create, name)
	option_manager_register_watcher(&win.scope.data.options, window_make_watcher(win))
	highlighters_init_child(&win.builtin_highlighters, &win.scope.data.highlighters, allocator)
	highlighters_setup_builtin(&win.builtin_highlighters.group)
	options := option_manager_flatten_options(&win.scope.data.options, allocator)
	defer delete(options)
	for option in options {
		window_on_option_changed(win, option)
	}
	return win
}

// window_destroy tears down a window built by window_make and frees the
// storage.
window_destroy :: proc(win: ^Window) {
	allocator := win.allocator
	option_manager_unregister_watcher(&win.scope.data.options, window_make_watcher(win))
	highlighters_destroy(&win.builtin_highlighters)
	display_buffer_destroy(&win.display_buffer)
	window_setup_destroy(&win.last_setup)
	scope_destroy(&win.scope)
	free(win, allocator)
}

// window_make_watcher builds the Option_Watcher pinning win (C++ Window
// itself is the OptionWatcher).
window_make_watcher :: proc(win: ^Window) -> Option_Watcher {
	return Option_Watcher{data = win, on_option_changed = window_on_option_changed_callback}
}

// window_on_option_changed_callback adapts the option watcher callback to
// window_on_option_changed.
window_on_option_changed_callback :: proc(data: rawptr, option: rawptr) {
	win := cast(^Window)data
	opt := cast(^Option)option
	window_on_option_changed(win, opt)
}

// window_on_option_changed runs the WinSetOption hook for a changed option
// (C++ Window::on_option_changed).
@(private = "file")
window_on_option_changed :: proc(win: ^Window, option: ^Option) {
	desc := option_desc_string(option, win.allocator)
	defer delete(desc, win.allocator)
	params := []string{option.desc.name, desc}
	text, format_err := format_format("{}={}", params, win.allocator)
	assert(format_err == .None)
	defer delete(text, win.allocator)
	window_run_hook_in_own_context(win, .Win_Set_Option, text)
}

// window_run_hook_in_own_context runs a window hook in a throwaway draft
// context bound to this window (C++ Window::run_hook_in_own_context). It is
// public because C++ grants ClientManager friendship for it.
window_run_hook_in_own_context :: proc(win: ^Window, hook: Hook, param: string, client_name: string = "") {
	if .No_Hooks in win.buffer.flags {
		return
	}
	sels := Selection_List {
		main      = 0,
		buffer    = win.buffer,
		timestamp = len(win.buffer.changes), // buffer.inl.hh: timestamp()
		allocator = win.allocator,
	}
	sels.selections = make([dynamic]Selection, 1, win.allocator)
	sels.selections[0] = Selection {
		basic = Basic_Selection {
			anchor = Coord_Buffer{},
			cursor = coord_buffer_and_target(Coord_Buffer{}),
		},
	}
	// input_handler_make takes ownership of sels (mirrors the C++ move).
	handler := input_handler_make(sels, {.Draft}, client_name, win.allocator)
	defer input_handler_destroy(handler)
	context_set_window(&handler.ctx, win)
	if win.client != nil {
		context_set_client(&handler.ctx, win.client)
	}
	hook_manager_run_hook(&win.scope.data.hooks, hook, param, &handler.ctx)
}

// ---------------------------------------------------------------------------
// Position, dimensions, scrolling
// ---------------------------------------------------------------------------

// window_position returns the top-left display position (C++
// Window::position).
window_position :: proc(win: ^Window) -> Coord_Display {
	return win.position
}

// window_set_position clamps and sets the display position (C++
// Window::set_position).
window_set_position :: proc(win: ^Window, position: Coord_Display) {
	line_count := Units_LineCount(len(win.buffer.lines)) // buffer.inl.hh: line_count()
	win.position.line = utils_clamp(position.line, Units_LineCount(0), line_count - 1)
	win.position.column = max(position.column, Units_ColumnCount(0))
}

// window_dimensions returns the window dimensions (C++ Window::dimensions).
window_dimensions :: proc(win: ^Window) -> Coord_Display {
	return win.dimensions
}

// window_set_dimensions sets the dimensions, flagging a pending resize hook
// on change (C++ Window::set_dimensions).
window_set_dimensions :: proc(win: ^Window, dimensions: Coord_Display) {
	if win.dimensions != dimensions {
		win.dimensions = dimensions
		win.resize_hook_pending = true
	}
}

// window_scroll_line scrolls vertically, clamped at the first line (C++
// Window::scroll(LineCount)).
window_scroll_line :: proc(win: ^Window, offset: Units_LineCount) {
	win.position.line = max(Units_LineCount(0), win.position.line + offset)
}

// window_scroll_column scrolls horizontally, clamped at the first column
// (C++ Window::scroll(ColumnCount)).
window_scroll_column :: proc(win: ^Window, offset: Units_ColumnCount) {
	win.position.column = max(Units_ColumnCount(0), win.position.column + offset)
}

// window_scroll scrolls the window (C++ Window::scroll overloads).
window_scroll :: proc {
	window_scroll_line,
	window_scroll_column,
}

// window_display_line_at scrolls so buffer_line shows on display_line (C++
// Window::display_line_at).
window_display_line_at :: proc(win: ^Window, buffer_line: Units_LineCount, display_line: Units_LineCount) {
	if display_line >= 0 || display_line < win.dimensions.line {
		win.position.line = max(Units_LineCount(0), buffer_line - display_line)
	}
}

// window_center_line centers buffer_line vertically (C++
// Window::center_line).
window_center_line :: proc(win: ^Window, buffer_line: Units_LineCount) {
	window_display_line_at(win, buffer_line, win.dimensions.line / 2)
}

// window_display_column_at scrolls so buffer_column shows on display_column
// (C++ Window::display_column_at).
window_display_column_at :: proc(win: ^Window, buffer_column: Units_ColumnCount, display_column: Units_ColumnCount) {
	if display_column >= 0 || display_column < win.dimensions.column {
		win.position.column = max(Units_ColumnCount(0), buffer_column - display_column)
	}
}

// window_center_column centers buffer_column horizontally (C++
// Window::center_column).
window_center_column :: proc(win: ^Window, buffer_column: Units_ColumnCount) {
	window_display_column_at(win, buffer_column, win.dimensions.column / 2)
}

// ---------------------------------------------------------------------------
// Buffer access, client, display setup queries
// ---------------------------------------------------------------------------

// window_buffer returns the viewed buffer (C++ Window::buffer).
window_buffer :: proc(win: ^Window) -> ^Buffer {
	return win.buffer
}

// window_set_client attaches (or, with nil, detaches) the client (C++
// Window::set_client).
window_set_client :: proc(win: ^Window, client: ^Client) {
	win.client = client
}

// window_last_display_setup returns the last computed display setup (C++
// Window::last_display_setup).
window_last_display_setup :: proc(win: ^Window) -> Display_Setup {
	return win.last_display_setup
}

// window_clear_display_buffer drops the rendered lines (C++
// Window::clear_display_buffer).
window_clear_display_buffer :: proc(win: ^Window) {
	display_buffer_destroy(&win.display_buffer)
	win.display_buffer = Display_Buffer {
		lines     = make(Display_Line_List, 0, win.allocator),
		timestamp = -1,
	}
}

// window_run_resize_hook_ifn runs the pending WinResize hook, if any (C++
// Window::run_resize_hook_ifn).
window_run_resize_hook_ifn :: proc(win: ^Window) {
	if win.resize_hook_pending {
		win.resize_hook_pending = false
		line_str := format_to_string_int(int(win.dimensions.line), win.allocator)
		defer delete(line_str, win.allocator)
		column_str := format_to_string_int(int(win.dimensions.column), win.allocator)
		defer delete(column_str, win.allocator)
		params := []string{line_str, column_str}
		text, format_err := format_format("{}.{}", params, win.allocator)
		assert(format_err == .None)
		defer delete(text, win.allocator)
		window_run_hook_in_own_context(win, .Win_Resize, text)
	}
}

// ---------------------------------------------------------------------------
// Redraw tracking
// ---------------------------------------------------------------------------

// window_compute_faces_hash folds the visible faces (C++
// compute_faces_hash): the face hash for plain faces, the base-name hash
// for based ones. Public for tests; see the file header on ordering.
window_compute_faces_hash :: proc(faces: ^Face_Registry, allocator := context.allocator) -> uint {
	entries := face_registry_flatten(faces, allocator)
	defer face_registry_flatten_free(&entries, allocator)
	// Insertion sort by name: deterministic order (see file header).
	for i := 1; i < len(entries); i += 1 {
		j := i
		for j > 0 && entries[j].name < entries[j - 1].name {
			entries[j], entries[j - 1] = entries[j - 1], entries[j]
			j -= 1
		}
	}
	hash: u32 = 0
	for entry in entries {
		face_value := face_hash(entry.spec.face)
		if len(entry.spec.base) > 0 {
			face_value = hash_fnv1a(entry.spec.base)
		}
		hash = u32(hash_combine(uint(hash), face_value))
	}
	return uint(hash)
}

// window_build_setup snapshots the current render inputs (C++
// Window::build_setup). The selections vector is cloned with allocator.
@(private = "file")
window_build_setup :: proc(win: ^Window, ctx: ^Context, allocator := context.allocator) -> Window_Setup {
	buffer := context_buffer(ctx)
	sels := context_selections(ctx)
	setup := Window_Setup {
		position       = win.position,
		dimensions     = win.dimensions,
		timestamp      = len(buffer.changes), // buffer.inl.hh: timestamp()
		faces_hash     = window_compute_faces_hash(context_faces(ctx, false), allocator),
		main_selection = sels.main,
		selections     = make([dynamic]Basic_Selection, len(sels.selections), allocator),
	}
	for sel, i in sels.selections {
		setup.selections[i] = Basic_Selection{anchor = sel.anchor, cursor = sel.cursor}
	}
	return setup
}

// window_setup_destroy frees a setup built by window_build_setup.
@(private = "file")
window_setup_destroy :: proc(setup: ^Window_Setup) {
	delete(setup.selections)
}

// window_needs_redraw reports whether the render inputs changed since the
// last display-buffer update (C++ Window::needs_redraw).
window_needs_redraw :: proc(win: ^Window, ctx: ^Context) -> bool {
	sels := context_selections(ctx)
	buffer := context_buffer(ctx)
	if win.position != win.last_setup.position ||
	   win.dimensions != win.last_setup.dimensions ||
	   len(buffer.changes) != win.last_setup.timestamp { // buffer.inl.hh: timestamp()
		return true
	}
	if sels.main != win.last_setup.main_selection || len(sels.selections) != len(win.last_setup.selections) {
		return true
	}
	if window_compute_faces_hash(context_faces(ctx, false), context.temp_allocator) != win.last_setup.faces_hash {
		return true
	}
	for sel, i in sels.selections {
		cached := win.last_setup.selections[i]
		if sel.anchor != cached.anchor || sel.cursor != cached.cursor {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// Display setup and display-buffer update
// ---------------------------------------------------------------------------

// window_check_display_setup asserts display-setup invariants (C++
// check_display_setup).
@(private = "file")
window_check_display_setup :: proc(setup: Display_Setup, win: ^Window) {
	line_count := Units_LineCount(len(win.buffer.lines)) // buffer.inl.hh: line_count()
	assert(setup.first_line >= 0 && setup.first_line < line_count)
	assert(setup.first_column >= 0)
	assert(setup.line_count >= 0)
}

// window_compute_display_setup derives the visible region, honoring the
// scrolloff option, cursor visibility and highlighter adjustments (C++
// Window::compute_display_setup).
@(private = "file")
window_compute_display_setup :: proc(win: ^Window, ctx: ^Context) -> Display_Setup {
	line_count := Units_LineCount(len(win.buffer.lines)) // buffer.inl.hh: line_count()
	scrolloff_option := option_manager_get_checked(context_options(ctx), "scrolloff")
	scrolloff, scrolloff_ok := scrolloff_option.value.(Coord_Display)
	assert(scrolloff_ok)
	offset := Coord_Display {
		line   = min(scrolloff.line, (win.dimensions.line + 1) / 2),
		column = min(scrolloff.column, (win.dimensions.column + 1) / 2),
	}
	sels := context_selections(ctx)
	cursor := sels.selections[sels.main].cursor
	setup := Display_Setup {
		first_line     = win.position.line,
		line_count     = win.dimensions.line,
		first_column   = win.position.column,
		widget_columns = Units_ColumnCount(0),
		scroll_offset  = offset,
	}
	if ctx.ensure_cursor_visible && cursor.line - offset.line < setup.first_line {
		setup.first_line = utils_clamp(cursor.line - offset.line, Units_LineCount(0), line_count - 1)
	}
	highlight_ctx := Highlight_Context {
		ctx          = ctx,
		setup        = &setup,
		pass         = {.Move},
		disabled_ids = nil,
	}
	highlight_ctx.pass = {.Move}
	highlighters_compute_display_setup(&win.builtin_highlighters, highlight_ctx, &setup)
	highlight_ctx.pass = {.Wrap}
	highlighters_compute_display_setup(&win.builtin_highlighters, highlight_ctx, &setup)
	highlight_ctx.pass = {.Replace}
	highlighters_compute_display_setup(&win.builtin_highlighters, highlight_ctx, &setup)
	if ctx.ensure_cursor_visible && cursor.line + offset.line >= setup.first_line + setup.line_count {
		setup.first_line = min(cursor.line + offset.line - setup.line_count + 1, line_count - 1)
	}
	setup.first_line = min(setup.first_line, line_count - 1)
	window_check_display_setup(setup, win)
	return setup
}

// window_update_display_buffer re-renders the window lines (C++
// Window::update_display_buffer): position tracking across buffer changes,
// per-line atoms, highlighter passes, cursor-visibility scrolling, trimming
// and colorization. Returns the live display buffer.
window_update_display_buffer :: proc(win: ^Window, ctx: ^Context) -> ^Display_Buffer {
	// Profiling (C++ ProfileScope) is intentionally skipped: diagnostics only.
	if win.display_buffer.timestamp != -1 {
		stamp := win.display_buffer.timestamp
		if stamp >= 0 && stamp < len(win.buffer.changes) {
			// buffer.inl.hh: changes_since(timestamp)
			for change in win.buffer.changes[stamp:] {
				if change.type == .Insert && change.begin.line < win.position.line {
					win.position.line += change.end.line - change.begin.line
				}
				if change.type == .Erase && change.begin.line < win.position.line {
					win.position.line = max(
						win.position.line - (change.end.line - change.begin.line),
						change.begin.line,
					)
				}
			}
		}
	}
	lines := &win.display_buffer.lines
	for &line in lines {
		display_buffer_line_destroy(&line)
	}
	clear(lines)
	win.display_buffer.timestamp = len(win.buffer.changes) // buffer.inl.hh: timestamp()
	if win.dimensions.line == 0 || win.dimensions.column == 0 {
		return &win.display_buffer
	}
	assert(context_buffer(ctx) == win.buffer)
	setup := window_compute_display_setup(win, ctx)
	if setup.line_count != win.last_display_setup.line_count ||
	   setup.widget_columns != win.last_display_setup.widget_columns {
		// Technically the window has not resized, but most things that hook
		// WinResize probably want to be notified anyway.
		win.resize_hook_pending = true
	}
	line_count := Units_LineCount(len(win.buffer.lines)) // buffer.inl.hh: line_count()
	line: Units_LineCount = 0
	for line < setup.line_count {
		buffer_line := setup.first_line + line
		if buffer_line >= line_count {
			break
		}
		line_length := Units_ByteCount(len(win.buffer.lines[int(buffer_line)])) // buffer.hh: operator[]
	display_line := display_buffer_line_make(win.allocator)
	display_buffer_line_push_back(
		&display_line,
		display_buffer_atom_range(
			win.buffer,
			Buffer_Range {
				begin = Coord_Buffer{line = buffer_line, column = 0},
				end = Coord_Buffer{line = buffer_line, column = line_length},
			},
			Face{},
		),
	)
	append(lines, display_line)
		line += 1
	}
	display_buffer_compute_range(&win.display_buffer)
	// buffer.inl.hh: end_coord() == line_count()
	highlight_range := Buffer_Range {
		begin = Coord_Buffer{},
		end = Coord_Buffer{line = line_count, column = 0},
	}
	highlight_ctx := Highlight_Context {
		ctx          = ctx,
		setup        = &setup,
		pass         = {.Replace},
		disabled_ids = nil,
	}
	highlight_ctx.pass = {.Replace}
	highlighters_highlight(&win.builtin_highlighters, highlight_ctx, &win.display_buffer, highlight_range)
	highlight_ctx.pass = {.Wrap}
	highlighters_highlight(&win.builtin_highlighters, highlight_ctx, &win.display_buffer, highlight_range)
	highlight_ctx.pass = {.Move}
	highlighters_highlight(&win.builtin_highlighters, highlight_ctx, &win.display_buffer, highlight_range)
	if ctx.ensure_cursor_visible {
		sels := context_selections(ctx)
		main_cursor := sels.selections[sels.main].cursor
		cursor_pos, cursor_ok := window_display_coord(
			win,
			Coord_Buffer{line = main_cursor.line, column = main_cursor.column},
		)
		assert(cursor_ok)
		if line_overflow :=
			cursor_pos.line - win.dimensions.line + setup.scroll_offset.line + 1;
			line_overflow > 0 {
			n := int(line_overflow)
			for i in 0 ..< n {
				display_buffer_line_destroy(&lines[i])
			}
			copy(lines[0:], lines[n:])
			resize(lines, len(lines) - n)
			setup.first_line = lines[0].range.begin.line
		}
		max_first_column := cursor_pos.column - (setup.widget_columns + setup.scroll_offset.column)
		setup.first_column = max(Units_ColumnCount(0), min(setup.first_column, max_first_column))
		min_first_column := cursor_pos.column - (win.dimensions.column - setup.scroll_offset.column) + 1
		setup.first_column = max(setup.first_column, min_first_column)
	}
	for &line in lines {
		display_buffer_line_trim_from(&line, setup.widget_columns, setup.first_column, win.dimensions.column, win.allocator)
	}
	if Units_LineCount(len(lines)) > win.dimensions.line {
		for i := int(win.dimensions.line); i < len(lines); i += 1 {
			display_buffer_line_destroy(&lines[i])
		}
		resize(lines, int(win.dimensions.line))
	}
	highlight_ctx.pass = {.Colorize}
	highlighters_highlight(&win.builtin_highlighters, highlight_ctx, &win.display_buffer, highlight_range)
	display_buffer_optimize(&win.display_buffer)
	window_set_position(win, Coord_Display{line = setup.first_line, column = setup.first_column})
	window_setup_destroy(&win.last_setup)
	win.last_setup = window_build_setup(win, ctx, win.allocator)
	win.last_display_setup = setup
	return &win.display_buffer
}

// ---------------------------------------------------------------------------
// Coordinate mapping
// ---------------------------------------------------------------------------

// window_display_coord maps a buffer coord to display coords, or nil when
// the display buffer is stale or the coord is not displayed (C++
// Window::display_coord).
window_display_coord :: proc(win: ^Window, coord: Coord_Buffer) -> (Coord_Display, bool) {
	if win.display_buffer.timestamp != len(win.buffer.changes) { // buffer.inl.hh: timestamp()
		return {}, false
	}
	for line_index in 0 ..< len(win.display_buffer.lines) {
		display_line := &win.display_buffer.lines[line_index]
		line_range := display_line.range
		if coord_compare(line_range.begin, coord) <= 0 && coord_compare(coord, line_range.end) < 0 {
			return Coord_Display {
					line   = Units_LineCount(line_index),
					column = window_find_display_column(display_line, win.buffer, coord),
				}, true
		}
	}
	return {}, false
}

// window_buffer_coord maps display coords back to a buffer coord, or nil
// when the display buffer is stale or the coord is out of view (C++
// Window::buffer_coord).
window_buffer_coord :: proc(win: ^Window, coord: Coord_Display) -> (Coord_Buffer, bool) {
	if win.display_buffer.timestamp != len(win.buffer.changes) || // buffer.inl.hh: timestamp()
	   len(win.display_buffer.lines) == 0 {
		return {}, false
	}
	if coord.line < 0 {
		return {}, false
	}
	if int(coord.line) >= len(win.display_buffer.lines) {
		return {}, false
	}
	return window_find_buffer_coord(&win.display_buffer.lines[int(coord.line)], win.buffer, coord.column), true
}

// window_find_display_column locates coord within a display line (C++
// find_display_column in window.cc).
@(private = "file")
window_find_display_column :: proc(line: ^Display_Line, buffer: ^Buffer, coord: Coord_Buffer) -> Units_ColumnCount {
	column: Units_ColumnCount = 0
	for &atom in line.atoms {
		if atom.type != .Text &&
		   coord_compare(atom.range.begin, coord) <= 0 &&
		   coord_compare(coord, atom.range.end) < 0 {
			if atom.type == .Range {
				column += window_column_distance(buffer, atom.range.begin, coord)
			}
			return column
		}
		column += window_atom_length(&atom, buffer)
	}
	return column
}

// window_find_buffer_coord locates a display column within a display line
// (C++ find_buffer_coord in window.cc).
@(private = "file")
window_find_buffer_coord :: proc(line: ^Display_Line, buffer: ^Buffer, column: Units_ColumnCount) -> Coord_Buffer {
	line_range := line.range
	remaining := column
	for &atom in line.atoms {
		length := window_atom_length(&atom, buffer)
		if atom.type != .Text && remaining < length {
			if atom.type == .Range {
				advanced := window_advance_columns(buffer, atom.range.begin, line_range.end, max(Units_ColumnCount(0), remaining))
				return buffer_clamp(buffer, advanced)
			}
			return buffer_clamp(buffer, atom.range.begin)
		}
		remaining -= length
	}
	if line_range.end == (Coord_Buffer{}) {
		return line_range.end
	}
	return buffer_prev(buffer, line_range.end)
}

// window_atom_length measures an atom in display columns (C++
// DisplayAtom::length): buffer text width for ranges, replacement/text
// width otherwise.
@(private = "file")
window_atom_length :: proc(atom: ^Display_Atom, buffer: ^Buffer) -> Units_ColumnCount {
	if atom.type == .Range {
		return window_column_distance(buffer, atom.range.begin, atom.range.end)
	}
	return Units_ColumnCount(window_string_column_width(atom.text))
}

// window_column_distance sums codepoint widths over the buffer text in
// [begin, end) (C++ utf8::column_distance over buffer iterators).
@(private = "file")
window_column_distance :: proc(buffer: ^Buffer, begin: Coord_Buffer, end: Coord_Buffer) -> Units_ColumnCount {
	width := 0
	window_for_each_span(buffer, begin, end, &width)
	return Units_ColumnCount(width)
}

// window_for_each_span feeds every text span (line slices and the newlines
// between them) in [begin, end) to the width accumulator.
@(private = "file")
window_for_each_span :: proc(buffer: ^Buffer, begin: Coord_Buffer, end: Coord_Buffer, width: ^int) {
	if coord_compare(end, begin) <= 0 {
		return
	}
	line := begin.line
	column := int(begin.column)
	for {
		line_text := ""
		if int(line) < len(buffer.lines) {
			line_text = buffer.lines[int(line)]
		}
		stop := len(line_text)
		last := line == end.line
		if last {
			stop = min(stop, int(end.column))
		}
		start := min(column, len(line_text))
		if stop > start {
			width^ += window_string_column_width(line_text[start:stop])
		}
		if last {
			return
		}
		// The newline joining this line to the next.
		width^ += unicode_codepoint_width('\n')
		line += 1
		column = 0
	}
}

// window_advance_columns moves columns display columns forward from begin,
// stopping at end (C++ utf8::advance over buffer iterators, ColumnCount
// overload, d >= 0 branch).
@(private = "file")
window_advance_columns :: proc(
	buffer: ^Buffer,
	begin: Coord_Buffer,
	end: Coord_Buffer,
	columns: Units_ColumnCount,
) -> Coord_Buffer {
	remaining := int(columns)
	pos := begin
	if coord_compare(pos, end) >= 0 || remaining <= 0 {
		return pos
	}
	for coord_compare(pos, end) < 0 && remaining > 0 {
		next, width := window_next_codepoint(buffer, pos, end)
		remaining -= width
		pos = next
		if coord_compare(pos, end) < 0 && remaining < 0 {
			pos = window_prev_codepoint(buffer, pos, begin)
		}
	}
	return pos
}

// window_next_codepoint steps one codepoint forward, returning the new
// position and the codepoint width. Newlines between lines count as one
// codepoint.
@(private = "file")
window_next_codepoint :: proc(buffer: ^Buffer, pos: Coord_Buffer, end: Coord_Buffer) -> (Coord_Buffer, int) {
	line_text := ""
	if int(pos.line) < len(buffer.lines) {
		line_text = buffer.lines[int(pos.line)]
	}
	if int(pos.column) < len(line_text) {
		byte_pos := int(pos.column)
		codepoint := utf8_codepoint(line_text, byte_pos)
		size := 1
		for byte_pos + size < len(line_text) &&
		    !utf8_is_character_start(line_text[byte_pos + size]) {
			size += 1
		}
		next := Coord_Buffer{line = pos.line, column = Units_ByteCount(byte_pos + size)}
		if coord_compare(next, end) > 0 {
			next = end
		}
		return next, unicode_codepoint_width(codepoint)
	}
	next := Coord_Buffer{line = pos.line + 1, column = 0}
	if coord_compare(next, end) > 0 {
		next = end
	}
	return next, unicode_codepoint_width('\n')
}

// window_prev_codepoint steps one codepoint back toward begin (C++
// to_previous over buffer iterators).
@(private = "file")
window_prev_codepoint :: proc(buffer: ^Buffer, pos: Coord_Buffer, begin: Coord_Buffer) -> Coord_Buffer {
	if int(pos.column) > 0 {
		line_text := ""
		if int(pos.line) < len(buffer.lines) {
			line_text = buffer.lines[int(pos.line)]
		}
		back := utf8_previous(line_text, min(int(pos.column), len(line_text)))
		prev := Coord_Buffer{line = pos.line, column = Units_ByteCount(back)}
		if coord_compare(prev, begin) < 0 {
			return begin
		}
		return prev
	}
	if pos.line > 0 && int(pos.line) - 1 < len(buffer.lines) {
		prev := Coord_Buffer {
			line   = pos.line - 1,
			column = Units_ByteCount(len(buffer.lines[int(pos.line) - 1])),
		}
		if coord_compare(prev, begin) < 0 {
			return begin
		}
		return prev
	}
	return begin
}

// window_string_column_width sums codepoint widths over s (C++
// String::column_length).
@(private = "file")
window_string_column_width :: proc(s: string) -> int {
	width := 0
	pos := 0
	for pos < len(s) {
		codepoint := utf8_read_codepoint(s, &pos)
		width += unicode_codepoint_width(codepoint)
	}
	return width
}

// ---------------------------------------------------------------------------
// Stubs: called here, implemented by unmerged modules (STUB protocol)
// ---------------------------------------------------------------------------

highlighters_init_child :: proc(highlighters: ^Highlighters, parent: ^Highlighters, allocator := context.allocator) {
	panic("STUB: highlighters_init_child")
}

highlighters_setup_builtin :: proc(group: ^Highlighter_Group) {
	panic("STUB: highlighters_setup_builtin")
}

highlighters_destroy :: proc(highlighters: ^Highlighters) {
	panic("STUB: highlighters_destroy")
}

highlighters_highlight :: proc(
	highlighters: ^Highlighters,
	ctx: Highlight_Context,
	display_buffer: ^Display_Buffer,
	buffer_range: Buffer_Range,
) {
	panic("STUB: highlighters_highlight")
}

highlighters_compute_display_setup :: proc(highlighters: ^Highlighters, ctx: Highlight_Context, setup: ^Display_Setup) {
	panic("STUB: highlighters_compute_display_setup")
}

