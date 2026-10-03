// Tests for window.odin (port of src/window.hh / src/window.cc).
//
// The C++ window code has no UnitTest block; these tests cover every
// standalone-testable behavior using hand-built Window values (window_make
// itself needs the unmerged scope/option/hook/highlighter modules):
// scrolling and positioning, dimension/resize-flag handling, the faces
// hash, buffer-to-display coord mapping, and the coord-mapping guards.
// Render paths (update_display_buffer, needs_redraw, buffer_coord success,
// hooks) call into unmerged modules; see the coverage gaps in the wave
// summary.
package kak

import "core:strings"
import "core:testing"

// window_test_make_buffer builds a minimal test buffer borrowing lines.
window_test_make_buffer :: proc(lines: []string, allocator := context.allocator) -> ^Buffer {
	buf := new(Buffer, allocator)
	buf.lines = make(Buffer_Lines, len(lines), allocator)
	copy(buf.lines[:], lines)
	buf.changes = make([dynamic]Buffer_Change, 0, allocator)
	return buf
}

// window_test_destroy_buffer frees a buffer from window_test_make_buffer
// (line bytes are borrowed literals and are not freed).
window_test_destroy_buffer :: proc(buf: ^Buffer, allocator := context.allocator) {
	delete(buf.lines)
	delete(buf.changes)
	free(buf, allocator)
}

// window_test_make_window builds a bare Window value; only the position,
// dimensions, buffer and display-buffer fields are live (no scope). Release
// display lines with window_test_destroy_lines.
window_test_make_window :: proc(
	buffer: ^Buffer,
	position: Coord_Display,
	dimensions: Coord_Display,
	allocator := context.allocator,
) -> Window {
	return Window {
		buffer          = buffer,
		position        = position,
		dimensions      = dimensions,
		display_buffer  = Display_Buffer {
			lines     = make(Display_Line_List, 0, allocator),
			timestamp = len(buffer.changes),
		},
		allocator       = allocator,
	}
}

// window_test_destroy_lines frees the display lines of a window from
// window_test_make_window (atom text is borrowed and is not freed).
window_test_destroy_lines :: proc(win: ^Window) {
	for &line in win.display_buffer.lines {
		delete(line.atoms)
	}
	delete(win.display_buffer.lines)
}

// window_test_make_range_atom builds a Range atom over buffer text.
window_test_make_range_atom :: proc(buffer: ^Buffer, begin: Coord_Buffer, end: Coord_Buffer) -> Display_Atom {
	return Display_Atom {
		type   = .Range,
		buffer = buffer,
		range  = Buffer_Range{begin = begin, end = end},
	}
}

// window_test_make_text_atom builds a Text atom with borrowed text.
window_test_make_text_atom :: proc(text: string) -> Display_Atom {
	return Display_Atom{type = .Text, text = text}
}

// window_test_append_line appends a display line with the given range and
// atoms (atoms borrowed by value; text borrowed).
window_test_append_line :: proc(
	win: ^Window,
	line_range: Buffer_Range,
	atoms: []Display_Atom,
	allocator := context.allocator,
) {
	line := Display_Line {
		range = line_range,
		atoms = make([dynamic]Display_Atom, len(atoms), allocator),
	}
	copy(line.atoms[:], atoms)
	append(&win.display_buffer.lines, line)
}

@(test)
test_window_scroll_line :: proc(t: ^testing.T) {
	buf := window_test_make_buffer({"a", "b", "c"}, context.allocator)
	defer window_test_destroy_buffer(buf, context.allocator)
	win := window_test_make_window(buf, {line = 5, column = 0}, {line = 10, column = 80}, context.allocator)
	defer window_test_destroy_lines(&win)

	window_scroll_line(&win, Units_LineCount(3))
	testing.expect_value(t, window_position(&win).line, Units_LineCount(8))
	// The proc group dispatches both overloads.
	window_scroll(&win, Units_LineCount(-2))
	testing.expect_value(t, window_position(&win).line, Units_LineCount(6))
	// Clamped at the first line, never negative.
	window_scroll(&win, Units_LineCount(-100))
	testing.expect_value(t, window_position(&win).line, Units_LineCount(0))
	testing.expect_value(t, window_position(&win).column, Units_ColumnCount(0))
}

@(test)
test_window_display_line_at_center :: proc(t: ^testing.T) {
	buf := window_test_make_buffer({"a"}, context.allocator)
	defer window_test_destroy_buffer(buf, context.allocator)
	win := window_test_make_window(buf, {}, {line = 10, column = 80}, context.allocator)
	defer window_test_destroy_lines(&win)

	window_display_line_at(&win, Units_LineCount(20), Units_LineCount(2))
	testing.expect_value(t, window_position(&win).line, Units_LineCount(18))
	window_display_line_at(&win, Units_LineCount(1), Units_LineCount(5))
	testing.expect_value(t, window_position(&win).line, Units_LineCount(0))
	window_center_line(&win, Units_LineCount(20))
	testing.expect_value(t, window_position(&win).line, Units_LineCount(15))
	window_center_line(&win, Units_LineCount(3))
	testing.expect_value(t, window_position(&win).line, Units_LineCount(0))
	// NOTE: the C++ guard `display_line >= 0 or display_line < dimensions`
	// is always true, so positioning applies unconditionally; the port
	// keeps the quirk verbatim.
	window_display_line_at(&win, Units_LineCount(20), Units_LineCount(-3))
	testing.expect_value(t, window_position(&win).line, Units_LineCount(23))
}

@(test)
test_window_scroll_column :: proc(t: ^testing.T) {
	buf := window_test_make_buffer({"a"}, context.allocator)
	defer window_test_destroy_buffer(buf, context.allocator)
	win := window_test_make_window(buf, {}, {line = 10, column = 80}, context.allocator)
	defer window_test_destroy_lines(&win)

	window_scroll_column(&win, Units_ColumnCount(7))
	testing.expect_value(t, window_position(&win).column, Units_ColumnCount(7))
	window_scroll(&win, Units_ColumnCount(-2))
	testing.expect_value(t, window_position(&win).column, Units_ColumnCount(5))
	window_scroll(&win, Units_ColumnCount(-100))
	testing.expect_value(t, window_position(&win).column, Units_ColumnCount(0))

	window_display_column_at(&win, Units_ColumnCount(50), Units_ColumnCount(10))
	testing.expect_value(t, window_position(&win).column, Units_ColumnCount(40))
	window_center_column(&win, Units_ColumnCount(50))
	testing.expect_value(t, window_position(&win).column, Units_ColumnCount(10))
	window_center_column(&win, Units_ColumnCount(4))
	testing.expect_value(t, window_position(&win).column, Units_ColumnCount(0))
}

@(test)
test_window_set_position_clamp :: proc(t: ^testing.T) {
	buf := window_test_make_buffer({"a", "b", "c"}, context.allocator)
	defer window_test_destroy_buffer(buf, context.allocator)
	win := window_test_make_window(buf, {}, {line = 10, column = 80}, context.allocator)
	defer window_test_destroy_lines(&win)

	// Lines clamp to the last buffer line, columns clamp at zero.
	window_set_position(&win, Coord_Display{line = Units_LineCount(10), column = Units_ColumnCount(5)})
	testing.expect_value(t, window_position(&win), Coord_Display{line = Units_LineCount(2), column = Units_ColumnCount(5)})
	window_set_position(&win, Coord_Display{line = Units_LineCount(-3), column = Units_ColumnCount(-7)})
	testing.expect_value(t, window_position(&win), Coord_Display{line = Units_LineCount(0), column = Units_ColumnCount(0)})
	window_set_position(&win, Coord_Display{line = Units_LineCount(1), column = Units_ColumnCount(9)})
	testing.expect_value(t, window_position(&win).line, Units_LineCount(1))
	testing.expect_value(t, window_position(&win).column, Units_ColumnCount(9))
	testing.expect(t, window_buffer(&win) == buf)
}

@(test)
test_window_set_dimensions_resize_flag :: proc(t: ^testing.T) {
	buf := window_test_make_buffer({"a"}, context.allocator)
	defer window_test_destroy_buffer(buf, context.allocator)
	win := window_test_make_window(buf, {}, {line = 10, column = 80}, context.allocator)
	defer window_test_destroy_lines(&win)

	testing.expect(t, !win.resize_hook_pending)
	window_set_dimensions(&win, Coord_Display{line = Units_LineCount(10), column = Units_ColumnCount(80)})
	testing.expect(t, !win.resize_hook_pending)
	window_set_dimensions(&win, Coord_Display{line = Units_LineCount(24), column = Units_ColumnCount(80)})
	testing.expect(t, win.resize_hook_pending)
	testing.expect_value(t, window_dimensions(&win), Coord_Display{line = Units_LineCount(24), column = Units_ColumnCount(80)})
	// No pending hook: no-op (the hook path needs input_handler/hook_manager).
	win.resize_hook_pending = false
	window_run_resize_hook_ifn(&win)
	testing.expect(t, !win.resize_hook_pending)
}

@(test)
test_window_run_hook_nohooks_noop :: proc(t: ^testing.T) {
	buf := window_test_make_buffer({"a"}, context.allocator)
	defer window_test_destroy_buffer(buf, context.allocator)
	buf.flags = {.No_Hooks}
	win := window_test_make_window(buf, {}, {line = 10, column = 80}, context.allocator)
	defer window_test_destroy_lines(&win)
	client := Client{}
	window_set_client(&win, &client)
	testing.expect(t, win.client == &client)
	// NoHooks buffers skip hook context creation entirely (anything else
	// would call into the unmerged input_handler module and panic).
	window_run_hook_in_own_context(&win, .Win_Create, "name")
	window_run_hook_in_own_context(&win, .Win_Resize, "10.80", "client")
	window_set_client(&win, nil)
	testing.expect(t, win.client == nil)
	testing.expect_value(t, window_last_display_setup(&win), Display_Setup{})
}

@(test)
test_window_watcher_wiring :: proc(t: ^testing.T) {
	buf := window_test_make_buffer({"a"}, context.allocator)
	defer window_test_destroy_buffer(buf, context.allocator)
	win := window_test_make_window(buf, {}, {line = 10, column = 80}, context.allocator)
	defer window_test_destroy_lines(&win)

	watcher := window_make_watcher(&win)
	testing.expect(t, watcher.data == rawptr(&win))
	testing.expect(t, watcher.on_option_changed == window_on_option_changed_callback)
	// (Invoking the callback runs the WinSetOption hook: gap.)
}

@(test)
test_window_error_zero :: proc(t: ^testing.T) {
	testing.expect_value(t, Window_Error.None, Window_Error(0))
}

@(test)
test_window_compute_faces_hash :: proc(t: ^testing.T) {
	allocator := context.allocator
	root := face_registry_make(nil, allocator)
	defer face_registry_destroy(&root)
	err := face_registry_add(&root, "mine", "red,blue")
	testing.expect_value(t, err, Face_Registry_Error.None)

	// Deterministic across calls despite randomized map iteration.
	first := window_compute_faces_hash(&root, allocator)
	second := window_compute_faces_hash(&root, allocator)
	third := window_compute_faces_hash(&root, allocator)
	testing.expect_value(t, first, second)
	testing.expect_value(t, second, third)

	// Sensitive to face changes.
	before := window_compute_faces_hash(&root, allocator)
	add_err := face_registry_add(&root, "other", "green,yellow")
	testing.expect_value(t, add_err, Face_Registry_Error.None)
	after := window_compute_faces_hash(&root, allocator)
	testing.expect(t, before != after)

	// Based faces hash by base name, plain faces by face value: the same
	// face with and without a base hashes differently (white-box inserts
	// keep the face value identical so only the branch differs).
	plain_root := face_registry_make(nil, allocator)
	defer face_registry_destroy(&plain_root)
	plain_key := strings.clone("same", allocator)
	plain_root.faces[plain_key] = Face_Registry_Spec{face = Face{}, base = strings.clone("", allocator)}
	based_root := face_registry_make(nil, allocator)
	defer face_registry_destroy(&based_root)
	based_key := strings.clone("same", allocator)
	based_base := strings.clone("somebase", allocator)
	based_root.faces[based_key] = Face_Registry_Spec{face = Face{}, base = based_base}
	testing.expect(t, window_compute_faces_hash(&plain_root, allocator) != window_compute_faces_hash(&based_root, allocator))
}

@(test)
test_window_display_coord :: proc(t: ^testing.T) {
	allocator := context.allocator
	buf := window_test_make_buffer({"hello", "héllo", "あx"}, allocator)
	defer window_test_destroy_buffer(buf, allocator)
	win := window_test_make_window(buf, {}, {line = 10, column = 80}, allocator)
	defer window_test_destroy_lines(&win)

	window_test_append_line(
		&win,
		Buffer_Range {
			begin = Coord_Buffer{line = 0, column = 0},
			end = Coord_Buffer{line = 0, column = 5},
		},
		{window_test_make_range_atom(buf, Coord_Buffer{line = 0, column = 0}, Coord_Buffer{line = 0, column = 5})},
		allocator,
	)
	window_test_append_line(
		&win,
		Buffer_Range {
			begin = Coord_Buffer{line = 1, column = 0},
			end = Coord_Buffer{line = 1, column = 6},
		},
		{window_test_make_range_atom(buf, Coord_Buffer{line = 1, column = 0}, Coord_Buffer{line = 1, column = 6})},
		allocator,
	)
	window_test_append_line(
		&win,
		Buffer_Range {
			begin = Coord_Buffer{line = 2, column = 0},
			end = Coord_Buffer{line = 2, column = 4},
		},
		{window_test_make_range_atom(buf, Coord_Buffer{line = 2, column = 0}, Coord_Buffer{line = 2, column = 4})},
		allocator,
	)

	// Plain ASCII: byte offsets equal columns.
	pos, ok := window_display_coord(&win, Coord_Buffer{line = 0, column = 2})
	testing.expect(t, ok)
	testing.expect_value(t, pos, Coord_Display{line = 0, column = 2})
	// Multibyte é (2 bytes, width 1): byte 3 is column 2.
	pos, ok = window_display_coord(&win, Coord_Buffer{line = 1, column = 3})
	testing.expect(t, ok)
	testing.expect_value(t, pos, Coord_Display{line = 1, column = 2})
	// Wide あ (3 bytes, width 2): the char after it is column 2.
	pos, ok = window_display_coord(&win, Coord_Buffer{line = 2, column = 3})
	testing.expect(t, ok)
	testing.expect_value(t, pos, Coord_Display{line = 2, column = 2})
	// Range end is exclusive.
	_, ok = window_display_coord(&win, Coord_Buffer{line = 0, column = 5})
	testing.expect(t, !ok)
	// Unknown line.
	_, ok = window_display_coord(&win, Coord_Buffer{line = 9, column = 0})
	testing.expect(t, !ok)

	// Stale display buffer: no mapping.
	win.display_buffer.timestamp = -1
	_, ok = window_display_coord(&win, Coord_Buffer{line = 0, column = 0})
	testing.expect(t, !ok)
	win.display_buffer.timestamp = len(buf.changes)
	pos, ok = window_display_coord(&win, Coord_Buffer{line = 0, column = 0})
	testing.expect(t, ok)
	testing.expect_value(t, pos, Coord_Display{line = 0, column = 0})

	// Empty display buffer: no mapping.
	empty := window_test_make_window(buf, {}, {line = 10, column = 80}, allocator)
	defer window_test_destroy_lines(&empty)
	_, ok = window_display_coord(&empty, Coord_Buffer{line = 0, column = 0})
	testing.expect(t, !ok)
}

@(test)
test_window_display_coord_atoms :: proc(t: ^testing.T) {
	allocator := context.allocator
	buf := window_test_make_buffer({"hello"}, allocator)
	defer window_test_destroy_buffer(buf, allocator)
	win := window_test_make_window(buf, {}, {line = 10, column = 80}, allocator)
	defer window_test_destroy_lines(&win)

	// Leading Text atom shifts the range columns by its width.
	window_test_append_line(
		&win,
		Buffer_Range {
			begin = Coord_Buffer{line = 0, column = 0},
			end = Coord_Buffer{line = 0, column = 5},
		},
		{
			window_test_make_text_atom("» "),
			window_test_make_range_atom(buf, Coord_Buffer{line = 0, column = 0}, Coord_Buffer{line = 0, column = 5}),
		},
		allocator,
	)
	pos, ok := window_display_coord(&win, Coord_Buffer{line = 0, column = 1})
	testing.expect(t, ok)
	testing.expect_value(t, pos, Coord_Display{line = 0, column = 3})

	// ReplacedRange atoms report the atom start without in-atom advance
	// (C++ find_display_column only advances inside Range atoms).
	replaced := window_test_make_window(buf, {}, {line = 10, column = 80}, allocator)
	defer window_test_destroy_lines(&replaced)
	replacement := Display_Atom {
		type   = .Replaced_Range,
		buffer = buf,
		range  = Buffer_Range {
			begin = Coord_Buffer{line = 0, column = 0},
			end = Coord_Buffer{line = 0, column = 5},
		},
		text   = "xyz",
	}
	window_test_append_line(
		&replaced,
		Buffer_Range {
			begin = Coord_Buffer{line = 0, column = 0},
			end = Coord_Buffer{line = 0, column = 5},
		},
		{replacement},
		allocator,
	)
	pos, ok = window_display_coord(&replaced, Coord_Buffer{line = 0, column = 3})
	testing.expect(t, ok)
	testing.expect_value(t, pos, Coord_Display{line = 0, column = 0})
}

@(test)
test_window_buffer_coord_guards :: proc(t: ^testing.T) {
	allocator := context.allocator
	buf := window_test_make_buffer({"hello"}, allocator)
	defer window_test_destroy_buffer(buf, allocator)
	win := window_test_make_window(buf, {}, {line = 10, column = 80}, allocator)
	defer window_test_destroy_lines(&win)
	window_test_append_line(
		&win,
		Buffer_Range {
			begin = Coord_Buffer{line = 0, column = 0},
			end = Coord_Buffer{line = 0, column = 5},
		},
		{window_test_make_range_atom(buf, Coord_Buffer{line = 0, column = 0}, Coord_Buffer{line = 0, column = 5})},
		allocator,
	)

	// Stale display buffer.
	win.display_buffer.timestamp = -1
	_, ok := window_buffer_coord(&win, Coord_Display{line = 0, column = 0})
	testing.expect(t, !ok)
	win.display_buffer.timestamp = len(buf.changes)
	// Negative and out-of-view lines.
	_, ok = window_buffer_coord(&win, Coord_Display{line = -1, column = 0})
	testing.expect(t, !ok)
	_, ok = window_buffer_coord(&win, Coord_Display{line = 7, column = 0})
	testing.expect(t, !ok)
	// Empty display buffer.
	empty := window_test_make_window(buf, {}, {line = 10, column = 80}, allocator)
	defer window_test_destroy_lines(&empty)
	_, ok = window_buffer_coord(&empty, Coord_Display{line = 0, column = 0})
	testing.expect(t, !ok)
	// (In-view mapping needs buffer clamp/prev from the buffer module: gap.)
}
