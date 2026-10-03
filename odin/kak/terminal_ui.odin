// Port of Kakoune's src/terminal_ui.{hh,cc}: NCurses-free raw terminal UI.
//
// Covers escape-sequence parsing (CSI/SS3, SGR and legacy mouse, kitty
// keyboard, bracketed paste, focus reports, synchronized-output replies),
// the window/screen drawing model with hash-based incremental output,
// resize handling, and the UserInterface vtable implementation.
//
// Mapping notes:
//   * Terminal escape output is accumulated in Terminal_UI.output (a
//     strings.Builder) instead of being written straight to stdout; the
//     real paths flush it with terminal_ui_flush, and tests read it with
//     terminal_ui_output without touching a tty.
//   * Input parsing is separated from the tty: Terminal_UI_Parser consumes
//     byte strings fed with terminal_ui_parser_feed and yields
//     Terminal_UI_Event values. The stdin watcher only drains the fd into
//     the parser. Truncated input yields ok=false and keeps the bytes;
//     garbage yields the same Alt fallbacks as the C++ value_or calls.
//   * The synchronized-output diff (C++ for_each_diff over line hashes)
//     is a small LCS diff here because the diff module only handles
//     strings; any valid diff is correct output.
//   * User_Interface still carries opaque display placeholders, so the
//     vtable adapters expect each .opaque to hold a ^Display_Line or
//     ^Display_Buffer respectively (see terminal_ui_as_interface).
//
// Ownership: Terminal_UI and Terminal_UI_Parser own their dynamic arrays
// and the strings inside window atoms; destroy with terminal_ui_destroy
// and terminal_ui_parser_destroy. Display_Line atoms cloned into the menu
// and info box are owned (arrays only; atom text stays borrowed, except
// trim padding allocated during menu_show/info_show, which leaks like the
// C++ String churn it mirrors). Paste event content is allocated with the
// allocator passed to terminal_ui_parser_next and owned by the caller.
package kak

import "core:c"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:unicode/utf8"
import linux "core:sys/linux"
import posix "core:sys/posix"

// Terminal_UI_Error reports terminal setup and output failures. Zero
// value None is success.
Terminal_UI_Error :: enum {
	None,
	Not_A_Tty,
	Tcgetattr_Failed,
	Tcsetattr_Failed,
	Write_Failed,
	Ioctl_Failed,
}

// Terminal_UI_Rect is a positioned rectangle of display cells (port of
// C++ TerminalUI::Rect).
Terminal_UI_Rect :: struct {
	pos:  Coord_Display,
	size: Coord_Display,
}

// Terminal_UI_Atom is one styled run of a window line (port of C++
// TerminalUI::Window::Line::Atom). text is owned.
Terminal_UI_Atom :: struct {
	text: string,
	skip: Coord_Column,
	face: Face,
}

// Terminal_UI_Line is a window line: a list of atoms (port of C++
// TerminalUI::Window::Line).
Terminal_UI_Line :: struct {
	atoms:     [dynamic]Terminal_UI_Atom,
	allocator: mem.Allocator,
}

// Terminal_UI_Window is an off-screen cell buffer (port of C++
// TerminalUI::Window).
Terminal_UI_Window :: struct {
	using rect: Terminal_UI_Rect,
	lines:      [dynamic]Terminal_UI_Line,
	allocator:  mem.Allocator,
}

// Terminal_UI_Screen is the shadow of what is displayed, with per-line
// hashes for incremental output (port of C++ TerminalUI::Screen).
Terminal_UI_Screen :: struct {
	using window: Terminal_UI_Window,
	hashes:       [dynamic]uint,
	active_face:  Face,
}

// Terminal_UI_Synchronized tracks synchronized-output support (port of
// C++ TerminalUI::Synchronized).
Terminal_UI_Synchronized :: struct {
	queried:   bool,
	supported: bool,
	set:       bool,
	requested: bool,
}

// Terminal_UI_Assistant selects the info-box assistant art (port of the
// m_assistant option handling).
Terminal_UI_Assistant :: enum {
	Clippy,
	Cat,
	Dilbert,
	None,
}

// Terminal_UI_Menu is the choice menu window plus its items (port of C++
// TerminalUI::Menu). Items are owned clones (atom arrays only).
Terminal_UI_Menu :: struct {
	using window:  Terminal_UI_Window,
	items:         [dynamic]Display_Line,
	fg:            Face,
	bg:            Face,
	anchor:        Coord_Display,
	style:         User_Interface_Menu_Style,
	selected_item: int,
	first_item:    int,
	columns:       int,
}

// Terminal_UI_Info is the info-box window plus its content (port of C++
// TerminalUI::Info). Title and content are owned clones.
Terminal_UI_Info :: struct {
	using window: Terminal_UI_Window,
	title:        Display_Line,
	content:      Display_Line_List,
	face:         Face,
	anchor:       Coord_Display,
	style:        User_Interface_Info_Style,
}

// Terminal_UI_Change is one coalesced run of the line-hash diff used by
// synchronized output (port of the local Change struct).
Terminal_UI_Change :: struct {
	keep: int,
	add:  int,
	del:  int,
}

// Terminal_UI_Paste is a completed bracketed paste; content is owned by
// the caller-provided allocator of terminal_ui_parser_next.
Terminal_UI_Paste :: struct {
	content: string,
}

// Terminal_UI_Event is one parsed input unit: a key or a paste.
Terminal_UI_Event :: union {
	Keys_Key,
	Terminal_UI_Paste,
}

// Terminal_UI_Parser holds incremental input-parsing state (port of the
// get_next_key/parse_csi/parse_ss3 closures plus the paste buffer).
Terminal_UI_Parser :: struct {
	input:          [dynamic]u8,
	erase_char:     u8,
	line_offset:    int,
	mouse_state:    int,
	wheel_scroll:   int,
	paste_active:   bool,
	paste:          [dynamic]u8,
	sync_seen:      bool,
	sync_supported: bool,
	allocator:      mem.Allocator,
}

// Terminal_UI_Cursor scans parser input with truncation detection.
Terminal_UI_Cursor :: struct {
	bytes:     []u8,
	pos:       int,
	truncated: bool,
}

// Terminal_UI is the raw terminal user interface (port of C++
// TerminalUI). Build with terminal_ui_make, attach to the tty with
// terminal_ui_init_tty, release with terminal_ui_destroy. Never copy
// after init.
Terminal_UI :: struct {
	window:             Terminal_UI_Window,
	screen:             Terminal_UI_Screen,
	output:             strings.Builder,
	dimensions:         Coord_Display,
	original_termios:   posix.termios,
	have_termios:       bool,
	menu:               Terminal_UI_Menu,
	info:               Terminal_UI_Info,
	cursor_pos:         Coord_Display,
	stdin_watcher:      Event_Manager_Fd_Watcher,
	watcher_active:     bool,
	on_key:             User_Interface_On_Key_Callback,
	on_paste:           User_Interface_On_Paste_Callback,
	parser:             Terminal_UI_Parser,
	synchronized:       Terminal_UI_Synchronized,
	status_on_top:      bool,
	assistant:          Terminal_UI_Assistant,
	mouse_enabled:      bool,
	wheel_scroll:       int,
	shift_function_key: int,
	set_title:          bool,
	title:              string,
	has_title:          bool,
	padding_char:       rune,
	padding_fill:       bool,
	cursor_native:      bool,
	dirty:              bool,
	resize_pending:     bool,
	status_len:         Coord_Column,
	status_pos:         Coord_Column,
	status_cursor_pos:  Coord_Column,
	info_max_width:     Coord_Column,
	allocator:          mem.Allocator,
}

terminal_ui_SHIFT_FUNCTION_KEY_DEFAULT :: 12
terminal_ui_WHEEL_SCROLL_DEFAULT :: 3
terminal_ui_FALLBACK_LINES :: 24
terminal_ui_FALLBACK_COLUMNS :: 80

@(private = "file")
terminal_ui_fg_table := [?]int{39, 30, 31, 32, 33, 34, 35, 36, 37, 90, 91, 92, 93, 94, 95, 96, 97}

@(private = "file")
terminal_ui_bg_table := [?]int{49, 40, 41, 42, 43, 44, 45, 46, 47, 100, 101, 102, 103, 104, 105, 106, 107}

@(private = "file")
terminal_ui_ul_table := [?]int{0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15}

// Attribute SGR codes indexed by Face_Attribute_Flag value 0..8
// (Underline..Strikethrough), matching the C++ attr_table positions
// 1..9 (bit 0 is never set).
@(private = "file")
terminal_ui_attr_table := [?]string{"4", "4:3", "21", "7", "5", "1", "2", "3", "9"}

@(private = "file")
terminal_ui_assistant_clippy := [?]string{
	" ╭──╮   ",
	" │  │   ",
	" @  @  ╭",
	" ││ ││ │",
	" ││ ││ ╯",
	" │╰─╯│  ",
	" ╰───╯  ",
	"        ",
}

@(private = "file")
terminal_ui_assistant_cat := [?]string{
	`  ___            `,
	` (__ \           `,
	`   / /          ╭`,
	`  .' '·.        │`,
	` '      ”       │`,
	` ╰       /\_/|  │`,
	`  | .         \ │`,
	`  ╰_J` + "    | | | ╯)",
	`      ' \__- _/  `,
	`      \_\   \_\  `,
	`                 `,
}

@(private = "file")
terminal_ui_assistant_dilbert := [?]string{
	`  დოოოოოდ   `,
	`  |     |   `,
	`  |     |  ╭`,
	`  |-ᱛ ᱛ-|  │`,
	` Ͼ   ∪   Ͽ │`,
	`  |     |  ╯`,
	` ˏ` + "`-.ŏ.-´ˎ  ",
	`     @      `,
	`      @     `,
	`            `,
}

@(private = "file")
terminal_ui_setup_text := "\033[?1049h\033[?1004h\033[>4;1m\033[>5u\033[22t\033[?25l\033=\033[?2004h"

@(private = "file")
terminal_ui_restore_text := "\033>\033[?25h\033[23t\033[<u\033[>4;0m\033[?1004l\033[?1049l\033[?2004l\033[m"

@(private = "file")
terminal_ui_mouse_enable_text := "\033[?1006h\033[?1000h\033[?1002h"

@(private = "file")
terminal_ui_mouse_disable_text := "\033[?1002l\033[?1000l\033[?1006l"

// terminal_ui_singleton is the live UI for signal and stdin callbacks
// (port of Singleton<TerminalUI>).
terminal_ui_singleton: ^Terminal_UI

// terminal_ui_resize_flag is set by the SIGWINCH handler (port of the
// file-static resize_pending).
terminal_ui_resize_flag := false

// terminal_ui_hangup_flag is set by the SIGHUP handler (port of the
// file-static terminal_hungup).
terminal_ui_hangup_flag := false

// terminal_ui_suspend_flag is set by the SIGTSTP handler and serviced
// by terminal_ui_poll, because "c" signal handlers cannot call
// context-carrying Odin procedures (and suspending synchronously
// inside a handler would be async-signal-unsafe anyway).
terminal_ui_suspend_flag := false

// terminal_ui_fix_atom_text replaces C0 control bytes with their
// U+2400 block pictures (port of fix_atom_text). The result is always
// a fresh string owned by the caller.
terminal_ui_fix_atom_text :: proc(s: string, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	start := 0
	for i := 0; i < len(s); i += 1 {
		if s[i] <= 0x1F {
			strings.write_string(&sb, s[start:i])
			strings.write_rune(&sb, rune(0x2400 + rune(s[i])))
			start = i + 1
		}
	}
	strings.write_string(&sb, s[start:])
	return strings.to_string(sb)
}

// terminal_ui_atom_length returns the display width of an atom (port of
// Atom::length).
terminal_ui_atom_length :: proc(atom: Terminal_UI_Atom) -> Coord_Column {
	return terminal_ui_text_columns(atom.text) + atom.skip
}

// terminal_ui_text_columns sums codepoint display widths (port of
// String::column_length).
terminal_ui_text_columns :: proc(s: string) -> Coord_Column {
	total: Coord_Column = 0
	pos := 0
	for pos < len(s) {
		cp := utf8_read_codepoint(s, &pos)
		total += Coord_Column(string_utils_codepoint_width(cp))
	}
	return total
}

// terminal_ui_remove_line_atoms drops atoms [lo, hi) from a display
// line (port of AtomList::erase).
terminal_ui_remove_line_atoms :: proc(line: ^Display_Line, lo, hi: int) {
	copy(line.atoms[lo:], line.atoms[hi:])
	resize(&line.atoms, len(line.atoms) - (hi - lo))
}

// terminal_ui_atom_hash hashes an atom (port of hash_value(Atom)).
terminal_ui_atom_hash :: proc(atom: Terminal_UI_Atom) -> uint {
	return hash_values(hash_fnv1a(atom.text), hash_value(int(atom.skip)), face_hash(atom.face))
}

// terminal_ui_atom_resize cuts an atom to size columns, splitting wide
// codepoints with a skip of 1 (port of Atom::resize).
terminal_ui_atom_resize :: proc(atom: ^Terminal_UI_Atom, size: Coord_Column, allocator := context.allocator) {
	pos := 0
	remaining := size
	for pos < len(atom.text) && remaining > 0 {
		cp, w := utf8.decode_rune_in_string(atom.text[pos:])
		if w <= 0 {
			w = 1
		}
		remaining -= Coord_Column(string_utils_codepoint_width(cp))
		pos += w
	}
	if remaining < 0 {
		pos = utf8_previous(atom.text, pos)
		atom.skip = 1
	} else {
		atom.skip = remaining
	}
	text := strings.clone(atom.text[:pos], allocator)
	delete(atom.text, allocator)
	atom.text = text
}

// terminal_ui_atom_clone deep-copies an atom's text (port of the Atom
// copy used by blit).
terminal_ui_atom_clone :: proc(atom: Terminal_UI_Atom, allocator := context.allocator) -> Terminal_UI_Atom {
	return Terminal_UI_Atom{text = strings.clone(atom.text, allocator), skip = atom.skip, face = atom.face}
}

// terminal_ui_line_append appends text to a line, merging with the
// previous atom when faces match (port of Line::append).
terminal_ui_line_append :: proc(line: ^Terminal_UI_Line, text: string, skip: Coord_Column, face: Face) {
	fixed := terminal_ui_fix_atom_text(text, line.allocator)
	if len(line.atoms) > 0 {
		back := &line.atoms[len(line.atoms) - 1]
		if back.face == face && (back.skip == 0 || len(text) == 0) {
			joined := strings.concatenate({back.text, fixed}, line.allocator)
			delete(back.text, line.allocator)
			delete(fixed, line.allocator)
			back.text = joined
			back.skip += skip
			return
		}
	}
	append(&line.atoms, Terminal_UI_Atom{text = fixed, skip = skip, face = face})
}

// terminal_ui_line_resize pads or cuts a line to width columns (port of
// Line::resize).
terminal_ui_line_resize :: proc(line: ^Terminal_UI_Line, width: Coord_Column) {
	column: Coord_Column = 0
	index := 0
	for index < len(line.atoms) && column < width {
		column += terminal_ui_atom_length(line.atoms[index])
		index += 1
	}
	if column < width {
		face := Face{}
		if len(line.atoms) > 0 {
			face = line.atoms[len(line.atoms) - 1].face
		}
		terminal_ui_line_append(line, "", width - column, face)
		return
	}
	for i in index ..< len(line.atoms) {
		delete(line.atoms[i].text, line.allocator)
	}
	resize(&line.atoms, index)
	if column > width {
		back := &line.atoms[len(line.atoms) - 1]
		terminal_ui_atom_resize(back, terminal_ui_atom_length(back^) - (column - width), line.allocator)
	}
}

// terminal_ui_line_hash hashes a line, ensuring a non-zero result (port
// of the hash_line lambda).
terminal_ui_line_hash :: proc(line: Terminal_UI_Line) -> uint {
	h: uint = 0
	for atom in line.atoms {
		h = hash_combine(h, terminal_ui_atom_hash(atom))
	}
	return (h << 1) | 1
}

// terminal_ui_make_tail builds the tail of an atom starting at column
// from (port of the make_tail lambda in erase_range).
terminal_ui_make_tail :: proc(atom: Terminal_UI_Atom, from: Coord_Column, allocator := context.allocator) -> Terminal_UI_Atom {
	pos := 0
	rest := from
	for pos < len(atom.text) && rest > 0 {
		cp, w := utf8.decode_rune_in_string(atom.text[pos:])
		if w <= 0 {
			w = 1
		}
		rest -= Coord_Column(string_utils_codepoint_width(cp))
		pos += w
	}
	if rest < 0 {
		sb := strings.builder_make(allocator)
		strings.write_byte(&sb, ' ')
		strings.write_string(&sb, atom.text[pos:])
		return Terminal_UI_Atom{text = strings.to_string(sb), skip = atom.skip, face = atom.face}
	}
	return Terminal_UI_Atom{text = strings.clone(atom.text[pos:], allocator), skip = atom.skip - rest, face = atom.face}
}

// terminal_ui_find_column locates the atom holding column col, returning
// its index and the offset inside it.
terminal_ui_find_column :: proc(line: ^Terminal_UI_Line, col: Coord_Column) -> (index: int, column: Coord_Column) {
	pos: Coord_Column = 0
	for i in 0 ..< len(line.atoms) {
		atom_len := terminal_ui_atom_length(line.atoms[i])
		if pos + atom_len >= col {
			return i, col - pos
		}
		pos += atom_len
	}
	return len(line.atoms), 0
}

// terminal_ui_line_erase_range removes len columns at pos and returns
// the insertion index for replacement atoms (port of
// Line::erase_range).
terminal_ui_line_erase_range :: proc(line: ^Terminal_UI_Line, pos, length: Coord_Column) -> int {
	begin_index, begin_column := terminal_ui_find_column(line, pos)
	end_index, end_column := terminal_ui_find_column(line, pos + length)
	if begin_index == end_index {
		tail := terminal_ui_make_tail(line.atoms[begin_index], end_column, line.allocator)
		terminal_ui_atom_resize(&line.atoms[begin_index], begin_column, line.allocator)
		if len(tail.text) == 0 && tail.skip == 0 {
			delete(tail.text, line.allocator)
			return begin_index + 1
		}
		inject_at(&line.atoms, begin_index + 1, tail)
		return begin_index + 1
	}
	terminal_ui_atom_resize(&line.atoms[begin_index], begin_column, line.allocator)
	if end_column > 0 {
		if end_column == terminal_ui_atom_length(line.atoms[end_index]) {
			end_index += 1
		} else {
			tail := terminal_ui_make_tail(line.atoms[end_index], end_column, line.allocator)
			delete(line.atoms[end_index].text, line.allocator)
			line.atoms[end_index] = tail
		}
	}
	for i in begin_index + 1 ..< end_index {
		delete(line.atoms[i].text, line.allocator)
	}
	copy(line.atoms[begin_index + 1:], line.atoms[end_index:])
	resize(&line.atoms, len(line.atoms) - (end_index - begin_index - 1))
	return begin_index + 1
}

// terminal_ui_line_destroy frees a line's atoms and their text.
terminal_ui_line_destroy :: proc(line: ^Terminal_UI_Line) {
	for atom in line.atoms {
		delete(atom.text, line.allocator)
	}
	delete(line.atoms)
}

// terminal_ui_window_create (re)creates a window at pos with size (port
// of Window::create). Size components must be non-negative.
terminal_ui_window_create :: proc(window: ^Terminal_UI_Window, pos, size: Coord_Display, allocator := context.allocator) {
	assert(int(pos.line) >= 0 && int(pos.column) >= 0)
	assert(int(size.line) >= 0 && int(size.column) >= 0)
	terminal_ui_window_destroy(window)
	window.pos = pos
	window.size = size
	window.allocator = allocator
	window.lines = make([dynamic]Terminal_UI_Line, int(size.line), allocator)
	for &line in window.lines {
		line.allocator = allocator
		line.atoms = make([dynamic]Terminal_UI_Atom, 0, allocator)
	}
}

// terminal_ui_window_destroy frees a window's lines and resets it (port
// of Window::destroy).
terminal_ui_window_destroy :: proc(window: ^Terminal_UI_Window) {
	for &line in window.lines {
		terminal_ui_line_destroy(&line)
	}
	delete(window.lines)
	window.lines = nil
	window.pos = Coord_Display{}
	window.size = Coord_Display{}
}

// terminal_ui_window_valid reports whether a window holds lines (port of
// the Window bool conversion).
terminal_ui_window_valid :: proc(window: ^Terminal_UI_Window) -> bool {
	return len(window.lines) > 0
}

// terminal_ui_window_blit copies src onto target at src.pos (port of
// Window::blit).
terminal_ui_window_blit :: proc(src: ^Terminal_UI_Window, target: ^Terminal_UI_Window) {
	if !terminal_ui_window_valid(src) || !terminal_ui_window_valid(target) {
		return
	}
	assert(int(src.pos.line) < int(target.size.line))
	line_index := src.pos.line
	for &line in src.lines {
		terminal_ui_line_resize(&line, src.size.column)
		target_line := &target.lines[int(line_index)]
		terminal_ui_line_resize(target_line, target.size.column)
		at := terminal_ui_line_erase_range(target_line, src.pos.column, src.size.column)
		clones := make([dynamic]Terminal_UI_Atom, 0, target_line.allocator)
		defer delete(clones)
		for atom in line.atoms {
			append(&clones, terminal_ui_atom_clone(atom, target_line.allocator))
		}
		inject_at(&target_line.atoms, at, ..clones[:])
		line_index += 1
		if line_index == target.size.line {
			break
		}
	}
}

// terminal_ui_window_draw renders display atoms at pos, padding the rest
// of the line with the default face (port of Window::draw).
terminal_ui_window_draw :: proc(window: ^Terminal_UI_Window, pos: Coord_Display, atoms: []Display_Atom, default_face: Face) {
	if pos.line >= window.size.line {
		return
	}
	cursor := pos
	terminal_ui_line_resize(&window.lines[int(cursor.line)], cursor.column)
	for atom in atoms {
		content := display_buffer_atom_content(atom)
		if len(content) == 0 {
			continue
		}
		face := face_merge(default_face, atom.face)
		if content[len(content) - 1] == '\n' {
			terminal_ui_line_append(&window.lines[int(cursor.line)], content[:len(content) - 1], 1, face)
		} else {
			terminal_ui_line_append(&window.lines[int(cursor.line)], content, 0, face)
		}
		cursor.column += display_buffer_atom_length(atom)
	}
	if cursor.column < window.size.column {
		terminal_ui_line_append(&window.lines[int(cursor.line)], "", window.size.column - cursor.column, default_face)
	}
}

// terminal_ui_screen_create creates a screen window plus zeroed hashes.
terminal_ui_screen_create :: proc(screen: ^Terminal_UI_Screen, pos, size: Coord_Display, allocator := context.allocator) {
	terminal_ui_window_create(&screen.window, pos, size, allocator)
	delete(screen.hashes)
	screen.hashes = make([dynamic]uint, int(size.line), allocator)
	screen.active_face = Face{}
}

// terminal_ui_screen_destroy frees a screen's window and hashes.
terminal_ui_screen_destroy :: proc(screen: ^Terminal_UI_Screen) {
	terminal_ui_window_destroy(&screen.window)
	delete(screen.hashes)
	screen.hashes = nil
	screen.active_face = Face{}
}

// terminal_ui_write_color emits one SGR color selector (port of the
// set_color lambda).
terminal_ui_write_color :: proc(sb: ^strings.Builder, fg: bool, color: Color, join: bool) {
	if join {
		strings.write_byte(sb, ';')
	}
	if color_is_rgb(color) {
		fmt.sbprintf(sb, "{};2;{};{};{}", fg ? 38 : 48, color.r, color.g, color.b)
	} else {
		table := terminal_ui_fg_table if fg else terminal_ui_bg_table
		fmt.sbprintf(sb, "{}", table[int(color.a)])
	}
}

// terminal_ui_screen_set_face switches the active face, emitting the
// minimal SGR sequence (port of Screen::set_face).
terminal_ui_screen_set_face :: proc(screen: ^Terminal_UI_Screen, face: Face, sb: ^strings.Builder) {
	if screen.active_face == face {
		return
	}
	strings.write_string(sb, "\033[")
	join := false
	if face.attributes != screen.active_face.attributes {
		for i in 0 ..< 9 {
			if Face_Attribute_Flag(i) in face.attributes {
				fmt.sbprintf(sb, ";{}", terminal_ui_attr_table[i])
			}
		}
		screen.active_face.fg = color_from_named(.Default)
		screen.active_face.bg = color_from_named(.Default)
		screen.active_face.underline = color_from_named(.Default)
		join = true
	}
	if screen.active_face.fg != face.fg {
		terminal_ui_write_color(sb, true, face.fg, join)
		join = true
	}
	if screen.active_face.bg != face.bg {
		terminal_ui_write_color(sb, false, face.bg, join)
		join = true
	}
	if screen.active_face.underline != face.underline {
		if join {
			strings.write_byte(sb, ';')
		}
		if face.underline != color_from_named(.Default) {
			if color_is_rgb(face.underline) {
				fmt.sbprintf(sb, "58:2::{}:{}:{}", face.underline.r, face.underline.g, face.underline.b)
			} else {
				fmt.sbprintf(sb, "58:5:{}", terminal_ui_ul_table[int(face.underline.a)])
			}
		} else {
			strings.write_string(sb, "59")
		}
	}
	strings.write_byte(sb, 'm')
	screen.active_face = face
}

// terminal_ui_write_line emits one screen line's atoms, eliding long
// blank runs with EL (port of the output_line lambda).
terminal_ui_write_line :: proc(screen: ^Terminal_UI_Screen, line: Terminal_UI_Line, sb: ^strings.Builder) {
	pending_move: Coord_Column = 0
	for atom in line.atoms {
		if len(atom.text) == 0 && atom.skip == 0 {
			continue
		}
		if pending_move != 0 {
			fmt.sbprintf(sb, "\033[{}C", int(pending_move))
			pending_move = 0
		}
		terminal_ui_screen_set_face(screen, atom.face, sb)
		strings.write_string(sb, atom.text)
		plain := atom.face.attributes == Face_Attribute{}
		if atom.skip > 3 && plain {
			strings.write_string(sb, "\033[K")
			pending_move = atom.skip
		} else if atom.skip > 0 {
			for _ in 0 ..< int(atom.skip) {
				strings.write_byte(sb, ' ')
			}
		}
	}
}

// terminal_ui_diff_hashes diffs old and new line hashes into coalesced
// keep/add/del runs (port of the for_each_diff use in Screen::output,
// via LCS: any valid diff is correct output).
terminal_ui_diff_hashes :: proc(old_hashes, new_hashes: []uint, allocator := context.allocator) -> [dynamic]Terminal_UI_Change {
	m := len(old_hashes)
	n := len(new_hashes)
	width := n + 1
	table := make([]int, (m + 1) * width, allocator)
	defer delete(table, allocator)
	for i in 1 ..= m {
		for j in 1 ..= n {
			if old_hashes[i - 1] == new_hashes[j - 1] {
				table[i * width + j] = table[(i - 1) * width + j - 1] + 1
			} else {
				table[i * width + j] = max(table[(i - 1) * width + j], table[i * width + j - 1])
			}
		}
	}
	Op :: enum {
		Keep,
		Add,
		Remove,
	}
	ops := make([dynamic]Op, 0, allocator)
	defer delete(ops)
	i := m
	j := n
	for i > 0 || j > 0 {
		switch {
		case i > 0 && j > 0 && old_hashes[i - 1] == new_hashes[j - 1]:
			append(&ops, Op.Keep)
			i -= 1
			j -= 1
		case j > 0 && (i == 0 || table[i * width + j - 1] >= table[(i - 1) * width + j]):
			append(&ops, Op.Add)
			j -= 1
		case:
			append(&ops, Op.Remove)
			i -= 1
		}
	}
	changes := make([dynamic]Terminal_UI_Change, 1, allocator)
	for k := len(ops) - 1; k >= 0; k -= 1 {
		switch ops[k] {
		case .Keep:
			append(&changes, Terminal_UI_Change{keep = 1})
		case .Add:
			changes[len(changes) - 1].add += 1
		case .Remove:
			changes[len(changes) - 1].del += 1
		}
	}
	merged := make([dynamic]Terminal_UI_Change, 0, allocator)
	for change in changes {
		if len(merged) > 0 && change.add == 0 && change.del == 0 {
			merged[len(merged) - 1].keep += change.keep
		} else {
			append(&merged, change)
		}
	}
	delete(changes)
	return merged
}

// terminal_ui_screen_write outputs changed lines, with scroll-region
// optimization when synchronized (port of Screen::output).
terminal_ui_screen_write :: proc(screen: ^Terminal_UI_Screen, force, synchronized: bool, sb: ^strings.Builder, allocator := context.allocator) {
	if !terminal_ui_window_valid(&screen.window) {
		return
	}
	if force {
		for &hash in screen.hashes {
			hash = 0
		}
		strings.write_string(sb, "\033[m")
		screen.active_face = Face{}
	}
	if synchronized {
		strings.write_string(sb, "\033[?2026h")
		new_hashes := make([]uint, len(screen.window.lines), allocator)
		defer delete(new_hashes, allocator)
		for line, i in screen.window.lines {
			new_hashes[i] = terminal_ui_line_hash(line)
		}
		changes := terminal_ui_diff_hashes(screen.hashes[:], new_hashes, allocator)
		defer delete(changes)
		copy(screen.hashes[:], new_hashes)
		line := 0
		for change in changes {
			line += change.keep
			if del := change.del - change.add; del > 0 {
				fmt.sbprintf(sb, "\033[{}H\033[{}M", line + 1, del)
				line -= del
			}
			line += change.del
		}
		line = 0
		for change in changes {
			line += change.keep
			for k in 0 ..< change.add {
				if add := change.add - change.del; k == 0 && add > 0 {
					fmt.sbprintf(sb, "\033[{}H\033[{}L", line + 1, add)
				} else {
					fmt.sbprintf(sb, "\033[{}H", line + 1)
				}
				terminal_ui_write_line(screen, screen.window.lines[line], sb)
				line += 1
			}
		}
		strings.write_string(sb, "\033[?2026l")
		return
	}
	for line in 0 ..< int(screen.size.line) {
		hash := terminal_ui_line_hash(screen.window.lines[line])
		if hash == screen.hashes[line] {
			continue
		}
		screen.hashes[line] = hash
		fmt.sbprintf(sb, "\033[{}H", line + 1)
		terminal_ui_write_line(screen, screen.window.lines[line], sb)
	}
}

// terminal_ui_cursor_next consumes one byte, setting truncated at the
// end of input (port of the get_char().value_or fallbacks).
terminal_ui_cursor_next :: proc(cursor: ^Terminal_UI_Cursor) -> u8 {
	if cursor.pos >= len(cursor.bytes) {
		cursor.truncated = true
		return 0
	}
	b := cursor.bytes[cursor.pos]
	cursor.pos += 1
	return b
}

// terminal_ui_parse_mask decodes an xterm modifier mask (port of the
// parse_mask lambda).
terminal_ui_parse_mask :: proc(mask: int) -> Keys_Modifiers {
	mods := keys_MOD_NONE
	if mask & 1 != 0 {
		mods = Keys_Modifiers(i32(mods) | i32(keys_MOD_SHIFT))
	}
	if mask & 2 != 0 {
		mods = Keys_Modifiers(i32(mods) | i32(keys_MOD_ALT))
	}
	if mask & 4 != 0 {
		mods = Keys_Modifiers(i32(mods) | i32(keys_MOD_CONTROL))
	}
	return mods
}

// terminal_ui_convert_key maps raw codepoints to named keys (port of
// the convert lambda).
terminal_ui_convert_key :: proc(cp: rune, erase_char: u8) -> rune {
	if cp == 13 {
		return keys_RETURN
	}
	if cp == 9 {
		return keys_TAB
	}
	if cp == ' ' {
		return keys_SPACE
	}
	if cp == rune(erase_char) {
		return keys_BACKSPACE
	}
	if cp == 127 {
		return keys_DELETE
	}
	if cp == 27 {
		return keys_ESCAPE
	}
	return cp
}

// terminal_ui_decode_key decodes one key at bytes[pos], following with
// (key, end, true); ok=false means truncated input (port of parse_key).
terminal_ui_decode_key :: proc(bytes: []u8, pos: int, erase_char: u8, final: bool) -> (key: Keys_Key, end: int, ok: bool) {
	c := bytes[pos]
	if cp := terminal_ui_convert_key(rune(c), erase_char); cp > 255 {
		return Keys_Key{key = cp}, pos + 1, true
	}
	if c == 0 {
		return Keys_Key{modifiers = keys_MOD_CONTROL, key = keys_SPACE}, pos + 1, true
	}
	if c < 27 {
		return Keys_Key{modifiers = keys_MOD_CONTROL, key = rune(c) - 1 + 'a'}, pos + 1, true
	}
	if c < 32 {
		return Keys_Key{modifiers = keys_MOD_CONTROL, key = rune(c) - 1 + 'A'}, pos + 1, true
	}
	expected := utf8_codepoint_size_byte(c)
	if pos + expected > len(bytes) && !final {
		return {}, pos, false
	}
	cp, w := utf8.decode_rune_in_string(string(bytes[pos:]))
	if w <= 0 {
		w = 1
	}
	return Keys_Key{key = cp}, pos + w, true
}

// terminal_ui_masked_key applies the CSI modifier parameter to a key,
// resolving shift-prefixed keys (port of the masked_key lambda).
terminal_ui_masked_key :: proc(params: ^[16][4]int, key, shifted: rune) -> Keys_Key {
	mods := terminal_ui_parse_mask(max(params[1][0] - 1, 0))
	result := key
	if shifted != 0 && i32(mods) & i32(keys_MOD_SHIFT) != 0 {
		mods = Keys_Modifiers(i32(mods) & ~i32(keys_MOD_SHIFT))
		result = shifted
	}
	return Keys_Key{modifiers = mods, key = result}
}

// terminal_ui_mouse_button builds a mouse button key, tracking press
// state (port of the mouse_button lambda).
terminal_ui_mouse_button :: proc(parser: ^Terminal_UI_Parser, base_mods: Keys_Modifiers, button: Keys_Mouse_Button, coord: rune, release: bool) -> Keys_Key {
	mask := 1 << uint(button)
	mods := base_mods
	if !release {
		extra := keys_MOD_MOUSE_PRESS
		if parser.mouse_state & mask != 0 {
			extra = keys_MOD_MOUSE_POS
		}
		mods = Keys_Modifiers(i32(mods) | i32(extra))
		parser.mouse_state |= mask
	} else {
		mods = Keys_Modifiers(i32(mods) | i32(keys_MOD_MOUSE_RELEASE))
		parser.mouse_state &= ~mask
	}
	return Keys_Key{modifiers = Keys_Modifiers(i32(mods) | i32(keys_button_modifier(button))), key = coord}
}

// terminal_ui_mouse_scroll builds a wheel-scroll key (port of the
// mouse_scroll lambda).
terminal_ui_mouse_scroll :: proc(parser: ^Terminal_UI_Parser, base_mods: Keys_Modifiers, coord: rune, down: bool) -> Keys_Key {
	amount := parser.wheel_scroll if down else -parser.wheel_scroll
	mods := Keys_Modifiers(i32(base_mods) | i32(keys_MOD_SCROLL) | (i32(amount) << 16))
	return Keys_Key{modifiers = mods, key = coord}
}

// terminal_ui_first_set_bit returns the lowest set bit index, or -1
// (port of ffs(m_mouse_state) - 1).
terminal_ui_first_set_bit :: proc(mask: int) -> int {
	for i in 0 ..< 32 {
		if mask & (1 << uint(i)) != 0 {
			return i
		}
	}
	return -1
}

// terminal_ui_parse_csi parses a CSI sequence after ESC [ (port of
// parse_csi). ok=false with cursor.truncated set means truncated
// input; ok=false otherwise means garbage (caller emits Alt+[).
terminal_ui_parse_csi :: proc(cursor: ^Terminal_UI_Cursor, parser: ^Terminal_UI_Parser, allocator := context.allocator) -> (event: Terminal_UI_Event, ok: bool) {
	c := terminal_ui_cursor_next(cursor)
	private_mode: u8 = 0
	if c == '?' || c == '<' || c == '=' || c == '>' {
		private_mode = c
		c = terminal_ui_cursor_next(cursor)
	}
	params: [16][4]int
	count := 0
	subcount := 0
	for count < 16 && c >= 0x30 && c <= 0x3f {
		switch {
		case c >= '0' && c <= '9':
			params[count][subcount] = params[count][subcount] * 10 + int(c - '0')
		case c == ':' && subcount < 3:
			subcount += 1
		case c == ';':
			count += 1
			subcount = 0
		case:
			return {}, false
		}
		c = terminal_ui_cursor_next(cursor)
	}
	if cursor.truncated {
		return {}, false
	}
	if c != '$' && (c < 0x40 || c > 0x7e) {
		return {}, false
	}
	switch c {
	case '$':
		if private_mode == '?' {
			reply := terminal_ui_cursor_next(cursor)
			if cursor.truncated {
				return {}, false
			}
			if reply == 'y' {
				if params[0][0] == 2026 {
					parser.sync_seen = true
					parser.sync_supported = params[1][0] == 1 || params[1][0] == 2
				}
				return Keys_Key{key = keys_INVALID}, true
			}
		}
		switch params[0][0] {
		case 23, 24:
			return Keys_Key{modifiers = keys_MOD_SHIFT, key = keys_F11 + rune(params[0][0] - 23)}, true
		}
		return {}, false
	case 'A':
		return terminal_ui_masked_key(&params, keys_UP, 0), true
	case 'B':
		return terminal_ui_masked_key(&params, keys_DOWN, 0), true
	case 'C':
		return terminal_ui_masked_key(&params, keys_RIGHT, 0), true
	case 'D':
		return terminal_ui_masked_key(&params, keys_LEFT, 0), true
	case 'E':
		return terminal_ui_masked_key(&params, '5', 0), true
	case 'F':
		return terminal_ui_masked_key(&params, keys_END, 0), true
	case 'H':
		return terminal_ui_masked_key(&params, keys_HOME, 0), true
	case 'P':
		return terminal_ui_masked_key(&params, keys_F1, 0), true
	case 'Q':
		return terminal_ui_masked_key(&params, keys_F2, 0), true
	case 'R':
		return terminal_ui_masked_key(&params, keys_F3, 0), true
	case 'S':
		return terminal_ui_masked_key(&params, keys_F4, 0), true
	case '~':
		switch params[0][0] {
		case 1:
			return terminal_ui_masked_key(&params, keys_HOME, 0), true
		case 2:
			return terminal_ui_masked_key(&params, keys_INSERT, 0), true
		case 3:
			return terminal_ui_masked_key(&params, keys_DELETE, 0), true
		case 4:
			return terminal_ui_masked_key(&params, keys_END, 0), true
		case 5:
			return terminal_ui_masked_key(&params, keys_PAGE_UP, 0), true
		case 6:
			return terminal_ui_masked_key(&params, keys_PAGE_DOWN, 0), true
		case 7:
			return terminal_ui_masked_key(&params, keys_HOME, 0), true
		case 8:
			return terminal_ui_masked_key(&params, keys_END, 0), true
		case 11, 12, 13, 14, 15:
			return terminal_ui_masked_key(&params, keys_F1 + rune(params[0][0] - 11), 0), true
		case 17, 18, 19, 20, 21:
			return terminal_ui_masked_key(&params, keys_F6 + rune(params[0][0] - 17), 0), true
		case 23, 24:
			return terminal_ui_masked_key(&params, keys_F11 + rune(params[0][0] - 23), 0), true
		case 25, 26:
			return Keys_Key{modifiers = keys_MOD_SHIFT, key = keys_F3 + rune(params[0][0] - 25)}, true
		case 27:
			return terminal_ui_masked_key(&params, terminal_ui_convert_key(rune(params[2][0]), parser.erase_char), 0), true
		case 28, 29:
			return Keys_Key{modifiers = keys_MOD_SHIFT, key = keys_F5 + rune(params[0][0] - 28)}, true
		case 31, 32:
			return Keys_Key{modifiers = keys_MOD_SHIFT, key = keys_F7 + rune(params[0][0] - 31)}, true
		case 33, 34:
			return Keys_Key{modifiers = keys_MOD_SHIFT, key = keys_F9 + rune(params[0][0] - 33)}, true
		case 200:
			parser.paste_active = true
			clear(&parser.paste)
			return Keys_Key{key = keys_INVALID}, true
		case 201:
			if parser.paste_active {
				content := strings.clone(string(parser.paste[:]), allocator)
				parser.paste_active = false
				clear(&parser.paste)
				return Terminal_UI_Paste{content = content}, true
			}
			return Keys_Key{key = keys_INVALID}, true
		}
		return {}, false
	case 'u':
		key := terminal_ui_convert_key(rune(params[0][0]), parser.erase_char)
		switch params[0][0] {
		case 57399:
			key = '0'
		case 57400:
			key = '1'
		case 57401:
			key = '2'
		case 57402:
			key = '3'
		case 57403:
			key = '4'
		case 57404:
			key = '5'
		case 57405:
			key = '6'
		case 57406:
			key = '7'
		case 57407:
			key = '8'
		case 57408:
			key = '9'
		case 57409:
			key = '.'
		case 57410:
			key = '/'
		case 57411:
			key = '*'
		case 57412:
			key = '-'
		case 57413:
			key = '+'
		case 57414:
			key = keys_RETURN
		case 57415:
			key = '='
		case 57417:
			key = keys_LEFT
		case 57418:
			key = keys_RIGHT
		case 57419:
			key = keys_UP
		case 57420:
			key = keys_DOWN
		case 57421:
			key = keys_PAGE_UP
		case 57422:
			key = keys_PAGE_DOWN
		case 57423:
			key = keys_HOME
		case 57424:
			key = keys_END
		case 57425:
			key = keys_INSERT
		case 57426:
			key = keys_DELETE
		}
		return terminal_ui_masked_key(&params, key, terminal_ui_convert_key(rune(params[0][1]), parser.erase_char)), true
	case 'Z':
		return Keys_Key{modifiers = keys_MOD_SHIFT, key = keys_TAB}, true
	case 'I':
		return Keys_Key{key = keys_FOCUS_IN}, true
	case 'O':
		return Keys_Key{key = keys_FOCUS_OUT}, true
	case 'M', 'm':
		sgr := private_mode == '<'
		if !sgr && c != 'M' {
			return {}, false
		}
		b, x, y: int
		if sgr {
			b = params[0][0]
			x = params[1][0] - 1
			y = params[2][0] - 1
		} else {
			b = int(terminal_ui_cursor_next(cursor)) - 32
			x = int(terminal_ui_cursor_next(cursor)) - 32 - 1
			y = int(terminal_ui_cursor_next(cursor)) - 32 - 1
		}
		if cursor.truncated {
			return {}, false
		}
		coord := keys_encode_coord(Keys_Coord{line = y - parser.line_offset, column = x})
		mods := terminal_ui_parse_mask((b >> 2) & 0x7)
		switch code := b & 0x43; code {
		case 0, 1, 2:
			return terminal_ui_mouse_button(parser, mods, Keys_Mouse_Button(code), coord, c == 'm'), true
		case 3:
			if sgr {
				return {}, false
			}
			if guess := terminal_ui_first_set_bit(parser.mouse_state); guess >= 0 && guess < 3 {
				return terminal_ui_mouse_button(parser, mods, Keys_Mouse_Button(guess), coord, true), true
			}
		case 64:
			return terminal_ui_mouse_scroll(parser, mods, coord, false), true
		case 65:
			return terminal_ui_mouse_scroll(parser, mods, coord, true), true
		}
		return Keys_Key{modifiers = keys_MOD_MOUSE_POS, key = coord}, true
	}
	return {}, false
}

// terminal_ui_parse_ss3 parses an SS3 sequence after ESC O (port of
// parse_ss3). ok=false with cursor.truncated set means truncated
// input; ok=false otherwise means garbage (caller emits Alt+O).
terminal_ui_parse_ss3 :: proc(cursor: ^Terminal_UI_Cursor) -> (key: Keys_Key, ok: bool) {
	raw_mask := 0
	code: u8 = '0'
	for {
		raw_mask = raw_mask * 10 + int(code - '0')
		code = terminal_ui_cursor_next(cursor)
		if cursor.truncated {
			return {}, false
		}
		if code < '0' || code > '9' {
			break
		}
	}
	mods := terminal_ui_parse_mask(max(raw_mask - 1, 0))
	switch code {
	case ' ':
		return Keys_Key{modifiers = mods, key = keys_SPACE}, true
	case 'A':
		return Keys_Key{modifiers = mods, key = keys_UP}, true
	case 'B':
		return Keys_Key{modifiers = mods, key = keys_DOWN}, true
	case 'C':
		return Keys_Key{modifiers = mods, key = keys_RIGHT}, true
	case 'D':
		return Keys_Key{modifiers = mods, key = keys_LEFT}, true
	case 'F':
		return Keys_Key{modifiers = mods, key = keys_END}, true
	case 'H':
		return Keys_Key{modifiers = mods, key = keys_HOME}, true
	case 'I':
		return Keys_Key{modifiers = mods, key = keys_TAB}, true
	case 'M':
		return Keys_Key{modifiers = mods, key = keys_RETURN}, true
	case 'P':
		return Keys_Key{modifiers = mods, key = keys_F1}, true
	case 'Q':
		return Keys_Key{modifiers = mods, key = keys_F2}, true
	case 'R':
		return Keys_Key{modifiers = mods, key = keys_F3}, true
	case 'S':
		return Keys_Key{modifiers = mods, key = keys_F4}, true
	case 'X':
		return Keys_Key{modifiers = mods, key = '='}, true
	case 'j':
		return Keys_Key{modifiers = mods, key = '*'}, true
	case 'k':
		return Keys_Key{modifiers = mods, key = '+'}, true
	case 'l':
		return Keys_Key{modifiers = mods, key = ','}, true
	case 'm':
		return Keys_Key{modifiers = mods, key = '-'}, true
	case 'n':
		return Keys_Key{modifiers = mods, key = '.'}, true
	case 'o':
		return Keys_Key{modifiers = mods, key = '/'}, true
	case 'p':
		return Keys_Key{modifiers = mods, key = '0'}, true
	case 'q':
		return Keys_Key{modifiers = mods, key = '1'}, true
	case 'r':
		return Keys_Key{modifiers = mods, key = '2'}, true
	case 's':
		return Keys_Key{modifiers = mods, key = '3'}, true
	case 't':
		return Keys_Key{modifiers = mods, key = '4'}, true
	case 'u':
		return Keys_Key{modifiers = mods, key = '5'}, true
	case 'v':
		return Keys_Key{modifiers = mods, key = '6'}, true
	case 'w':
		return Keys_Key{modifiers = mods, key = '7'}, true
	case 'x':
		return Keys_Key{modifiers = mods, key = '8'}, true
	case 'y':
		return Keys_Key{modifiers = mods, key = '9'}, true
	}
	return {}, false
}

// terminal_ui_parser_make builds an empty parser.
terminal_ui_parser_make :: proc(allocator := context.allocator) -> Terminal_UI_Parser {
	return Terminal_UI_Parser{
		input = make([dynamic]u8, 0, allocator),
		erase_char = 127,
		wheel_scroll = terminal_ui_WHEEL_SCROLL_DEFAULT,
		paste = make([dynamic]u8, 0, allocator),
		allocator = allocator,
	}
}

// terminal_ui_parser_destroy frees a parser's buffers.
terminal_ui_parser_destroy :: proc(parser: ^Terminal_UI_Parser) {
	delete(parser.input)
	delete(parser.paste)
}

// terminal_ui_parser_feed appends bytes to the parser input.
terminal_ui_parser_feed :: proc(parser: ^Terminal_UI_Parser, data: []u8) {
	append(&parser.input, ..data)
}

// terminal_ui_parser_consume drops the first n parsed bytes.
terminal_ui_parser_consume :: proc(parser: ^Terminal_UI_Parser, n: int) {
	copy(parser.input[0:], parser.input[n:])
	resize(&parser.input, len(parser.input) - n)
}

// terminal_ui_parser_next parses one event; ok=false means no complete
// event is available (truncated input stays buffered). With final set,
// a trailing ESC yields Escape instead of waiting for more bytes.
terminal_ui_parser_next :: proc(parser: ^Terminal_UI_Parser, final: bool, allocator := context.allocator) -> (event: Terminal_UI_Event, ok: bool) {
	if len(parser.input) == 0 {
		return {}, false
	}
	if parser.input[0] == 27 {
		if len(parser.input) == 1 {
			if parser.paste_active {
				append(&parser.paste, byte('\n') if parser.input[0] == '\r' else parser.input[0])
				terminal_ui_parser_consume(parser, 1)
				return Keys_Key{key = keys_INVALID}, true
			}
			if !final {
				return {}, false
			}
			terminal_ui_parser_consume(parser, 1)
			return Keys_Key{key = keys_ESCAPE}, true
		}
		cursor := Terminal_UI_Cursor{bytes = parser.input[:], pos = 2}
		if parser.input[1] == '[' {
			csi_event, csi_ok := terminal_ui_parse_csi(&cursor, parser, allocator)
			if !csi_ok {
				if cursor.truncated {
					return {}, false
				}
				terminal_ui_parser_consume(parser, cursor.pos)
				return Keys_Key{modifiers = keys_MOD_ALT, key = '['}, true
			}
			terminal_ui_parser_consume(parser, cursor.pos)
			return csi_event, true
		}
		if parser.input[1] == 'O' {
			ss3_key, ss3_ok := terminal_ui_parse_ss3(&cursor)
			if !ss3_ok {
				if cursor.truncated {
					return {}, false
				}
				terminal_ui_parser_consume(parser, cursor.pos)
				return Keys_Key{modifiers = keys_MOD_ALT, key = 'O'}, true
			}
			terminal_ui_parser_consume(parser, cursor.pos)
			return ss3_key, true
		}
		alt_key, alt_end, alt_ok := terminal_ui_decode_key(parser.input[:], 1, parser.erase_char, final)
		if !alt_ok {
			return {}, false
		}
		terminal_ui_parser_consume(parser, alt_end)
		return Keys_Key{modifiers = Keys_Modifiers(i32(alt_key.modifiers) | i32(keys_MOD_ALT)), key = alt_key.key}, true
	}
	if parser.paste_active {
		append(&parser.paste, byte('\n') if parser.input[0] == '\r' else parser.input[0])
		terminal_ui_parser_consume(parser, 1)
		return Keys_Key{key = keys_INVALID}, true
	}
	plain_key, plain_end, plain_ok := terminal_ui_decode_key(parser.input[:], 0, parser.erase_char, final)
	if !plain_ok {
		return {}, false
	}
	terminal_ui_parser_consume(parser, plain_end)
	return plain_key, true
}

// terminal_ui_force_signal pokes the event manager when one is
// installed (tests run without a manager).
terminal_ui_force_signal :: proc(fd: int) {
	if event_manager_has_instance() {
		event_manager_force_signal(fd)
	}
}

// terminal_ui_make builds a detached UI: no tty touched, no window
// yet. Follow with terminal_ui_apply_size (tests) or
// terminal_ui_init_tty (real use).
terminal_ui_make :: proc(allocator := context.allocator) -> Terminal_UI {
	ui := Terminal_UI{
		allocator          = allocator,
		assistant          = .Clippy,
		wheel_scroll       = terminal_ui_WHEEL_SCROLL_DEFAULT,
		shift_function_key = terminal_ui_SHIFT_FUNCTION_KEY_DEFAULT,
		set_title          = true,
		padding_char       = '~',
	}
	ui.output = strings.builder_make(allocator)
	ui.parser = terminal_ui_parser_make(allocator)
	ui.menu.window.allocator = allocator
	ui.menu.items = make([dynamic]Display_Line, 0, allocator)
	ui.menu.columns = 1
	ui.info.window.allocator = allocator
	ui.info.content = make(Display_Line_List, 0, allocator)
	ui.info.title = display_buffer_line_make(allocator)
	return ui
}

// terminal_ui_destroy releases a UI, restoring the tty when one was
// attached with terminal_ui_init_tty.
terminal_ui_destroy :: proc(ui: ^Terminal_UI) {
	if terminal_ui_singleton == ui {
		terminal_ui_singleton = nil
	}
	if ui.watcher_active {
		event_manager_fd_watcher_destroy(&ui.stdin_watcher)
		ui.watcher_active = false
	}
	if ui.have_termios && !terminal_ui_hangup_flag {
		terminal_ui_enable_mouse(ui, false)
		strings.write_string(&ui.output, terminal_ui_restore_text)
		terminal_ui_flush(ui)
		posix.tcsetattr(posix.STDIN_FILENO, .TCSAFLUSH, &ui.original_termios)
		_, _ = event_manager_set_signal_handler(posix.Signal(posix.SIGWINCH), nil)
		posix.sigignore(.SIGHUP)
		_, _ = event_manager_set_signal_handler(.SIGTSTP, nil)
	}
	terminal_ui_menu_free_items(&ui.menu)
	terminal_ui_window_destroy(&ui.menu.window)
	delete(ui.menu.items)
	for &line in ui.info.content {
		display_buffer_line_destroy(&line)
	}
	delete(ui.info.content)
	display_buffer_line_destroy(&ui.info.title)
	terminal_ui_window_destroy(&ui.info.window)
	terminal_ui_window_destroy(&ui.window)
	terminal_ui_screen_destroy(&ui.screen)
	terminal_ui_parser_destroy(&ui.parser)
	if ui.has_title {
		delete(ui.title, ui.allocator)
	}
	strings.builder_destroy(&ui.output)
}

// terminal_ui_content_line_offset returns 1 when the status line is on
// top, else 0 (port of content_line_offset).
terminal_ui_content_line_offset :: proc(ui: ^Terminal_UI) -> Coord_Line {
	return 1 if ui.status_on_top else 0
}

// terminal_ui_dimensions returns the drawable size (port of dimensions).
terminal_ui_dimensions :: proc(ui: ^Terminal_UI) -> Coord_Display {
	return ui.dimensions
}

// terminal_ui_output returns the buffered escape output.
terminal_ui_output :: proc(ui: ^Terminal_UI) -> string {
	return strings.to_string(ui.output)
}

// terminal_ui_clear_output discards the buffered escape output.
terminal_ui_clear_output :: proc(ui: ^Terminal_UI) {
	clear(&ui.output.buf)
}

// terminal_ui_flush writes buffered output to stdout.
terminal_ui_flush :: proc(ui: ^Terminal_UI) -> Terminal_UI_Error {
	data := ui.output.buf[:]
	for len(data) > 0 {
		n := posix.write(posix.STDOUT_FILENO, raw_data(data), c.size_t(len(data)))
		if n <= 0 {
			return .Write_Failed
		}
		data = data[int(n):]
	}
	clear(&ui.output.buf)
	return .None
}

// terminal_ui_clone_line clones a display line's atom array; atom text
// stays borrowed (port of the DisplayLine copies).
terminal_ui_clone_line :: proc(line: Display_Line, allocator := context.allocator) -> Display_Line {
	atoms := make([dynamic]Display_Atom, len(line.atoms), allocator)
	copy(atoms[:], line.atoms[:])
	return Display_Line{range = line.range, atoms = atoms}
}

// terminal_ui_destroy_line_list frees every line's atoms and the list.
terminal_ui_destroy_line_list :: proc(lines: ^Display_Line_List) {
	for &line in lines {
		display_buffer_line_destroy(&line)
	}
	delete(lines^)
	lines^ = nil
}

// terminal_ui_repeat_rune builds a run of count copies of cp.
terminal_ui_repeat_rune :: proc(cp: rune, count: int, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	for _ in 0 ..< count {
		strings.write_rune(&sb, cp)
	}
	return strings.to_string(sb)
}

// terminal_ui_write_escaped writes str with non-printable bytes as '?'
// (port of the write_escaped lambda in draw_status).
terminal_ui_write_escaped :: proc(sb: ^strings.Builder, str: string) {
	for i := 0; i < len(str); i += 1 {
		if str[i] >= 0x20 && str[i] <= 0x7e {
			strings.write_byte(sb, str[i])
		} else {
			strings.write_byte(sb, '?')
		}
	}
}

// terminal_ui_draw renders the main area (port of TerminalUI::draw).
terminal_ui_draw :: proc(
	ui: ^Terminal_UI,
	buffer: ^Display_Buffer,
	cursor_pos: Coord_Display,
	default_face, padding_face: Face,
	widget_columns: Coord_Column,
) {
	_ = widget_columns
	terminal_ui_check_resize(ui)
	dim := ui.dimensions
	line_offset := terminal_ui_content_line_offset(ui)
	line_index := line_offset
	for line in buffer.lines {
		terminal_ui_window_draw(&ui.window, Coord_Display{line = line_index}, line.atoms[:], default_face)
		line_index += 1
	}
	face := face_merge(default_face, padding_face)
	count := int(dim.column) if ui.padding_fill else 1
	pad := terminal_ui_repeat_rune(ui.padding_char, count, context.temp_allocator)
	atom := display_buffer_atom_text(pad, Face{})
	atoms := [1]Display_Atom{atom}
	for line_index < dim.line + line_offset {
		terminal_ui_window_draw(&ui.window, Coord_Display{line = line_index}, atoms[:], face)
		line_index += 1
	}
	ui.cursor_pos = cursor_pos
	ui.dirty = true
}

// terminal_ui_draw_status renders the status line (port of draw_status).
terminal_ui_draw_status :: proc(
	ui: ^Terminal_UI,
	prompt, content: ^Display_Line,
	cursor_pos: Coord_Column,
	mode_line: ^Display_Line,
	default_face: Face,
	style: User_Interface_Status_Style,
) {
	_ = style
	status_line_pos := Coord_Line(0) if ui.status_on_top else ui.dimensions.line
	prompt_len := display_buffer_line_length(prompt^)
	status_width := ui.dimensions.column - prompt_len
	if cursor_pos < ui.status_pos {
		ui.status_pos = cursor_pos
	}
	if cursor_pos >= ui.status_pos + status_width {
		ui.status_pos = cursor_pos + 1 - status_width
	}
	ui.status_cursor_pos = prompt_len + cursor_pos if cursor_pos >= 0 else -1
	trimmed_content := terminal_ui_clone_line(content^, ui.allocator)
	defer display_buffer_line_destroy(&trimmed_content)
	display_buffer_line_trim(&trimmed_content, ui.status_pos, status_width, ui.allocator)
	terminal_ui_window_draw(&ui.window, Coord_Display{line = status_line_pos}, prompt.atoms[:], default_face)
	terminal_ui_window_draw(
		&ui.window,
		Coord_Display{line = status_line_pos, column = prompt_len},
		trimmed_content.atoms[:],
		default_face,
	)
	mode_len := display_buffer_line_length(mode_line^)
	ui.status_len = prompt_len + display_buffer_line_length(trimmed_content)
	remaining := ui.dimensions.column - ui.status_len
	if mode_len < remaining {
		terminal_ui_window_draw(
			&ui.window,
			Coord_Display{line = status_line_pos, column = ui.dimensions.column - mode_len},
			mode_line.atoms[:],
			default_face,
		)
	} else if remaining > 2 {
		trimmed_mode := terminal_ui_clone_line(mode_line^, ui.allocator)
		defer display_buffer_line_destroy(&trimmed_mode)
		display_buffer_line_trim(&trimmed_mode, mode_len + 2 - remaining, remaining - 2, ui.allocator)
		ellipsis := display_buffer_atom_text("…", Face{})
		display_buffer_line_insert(&trimmed_mode, 0, ellipsis)
		terminal_ui_window_draw(
			&ui.window,
			Coord_Display{line = status_line_pos, column = ui.dimensions.column - remaining + 1},
			trimmed_mode.atoms[:],
			default_face,
		)
	}
	if ui.set_title {
		strings.write_string(&ui.output, "\033]2;")
		if !ui.has_title {
			for atom in mode_line.atoms {
				terminal_ui_write_escaped(&ui.output, display_buffer_atom_content(atom))
			}
			strings.write_string(&ui.output, " - Kakoune")
		} else {
			terminal_ui_write_escaped(&ui.output, ui.title)
		}
		strings.write_byte(&ui.output, 7)
	}
	ui.dirty = true
}

// terminal_ui_menu_free_items frees the menu's cloned item lines.
terminal_ui_menu_free_items :: proc(menu: ^Terminal_UI_Menu) {
	for &line in menu.items {
		display_buffer_line_destroy(&line)
	}
	clear(&menu.items)
}

// terminal_ui_menu_height_limit returns the menu height cap per style
// (port of height_limit).
terminal_ui_menu_height_limit :: proc(style: User_Interface_Menu_Style) -> Coord_Line {
	switch style {
	case .Inline:
		return 10
	case .Prompt:
		return 10
	case .Search:
		return 3
	}
	return 0
}

// terminal_ui_div_round_up divides rounding up (port of div_round_up).
terminal_ui_div_round_up :: proc(a, b: int) -> int {
	return (a - 1) / b + 1
}

// terminal_ui_draw_menu renders the menu items into the menu window
// (port of draw_menu).
terminal_ui_draw_menu :: proc(ui: ^Terminal_UI) {
	menu := &ui.menu
	if !terminal_ui_window_valid(&menu.window) {
		return
	}
	item_count := len(menu.items)
	if menu.columns == 0 {
		win_width := menu.size.column - 4
		pos: Coord_Column = 0
		marker := "< " if menu.first_item > 0 else ""
		atom := display_buffer_atom_text(marker, Face{})
		one := [1]Display_Atom{atom}
		terminal_ui_window_draw(&menu.window, Coord_Display{}, one[:], menu.bg)
		i := menu.first_item
		for i < item_count && pos < win_width {
			item_width := display_buffer_line_length(menu.items[i])
			face := menu.fg if i == menu.selected_item else menu.bg
			terminal_ui_window_draw(&menu.window, Coord_Display{column = pos + 2}, menu.items[i].atoms[:], face)
			if pos + item_width >= win_width {
				dots := display_buffer_atom_text("…", Face{})
				two := [1]Display_Atom{dots}
				terminal_ui_window_draw(&menu.window, Coord_Display{column = win_width + 2}, two[:], menu.bg)
			}
			pos += item_width + 1
			i += 1
		}
		if i != item_count {
			gt := display_buffer_atom_text(">", Face{})
			three := [1]Display_Atom{gt}
			terminal_ui_window_draw(&menu.window, Coord_Display{column = win_width + 3}, three[:], menu.bg)
		}
		ui.dirty = true
		return
	}
	win_height := int(menu.size.line)
	menu_lines := terminal_ui_div_round_up(item_count, menu.columns)
	assert(win_height <= menu_lines)
	column_width := (int(menu.size.column) - 1) / menu.columns
	mark_height := min(terminal_ui_div_round_up(win_height * win_height, menu_lines), win_height)
	menu_cols := terminal_ui_div_round_up(item_count, win_height)
	first_col := menu.first_item / win_height
	mark_line := (win_height - mark_height) * first_col / max(1, menu_cols - menu.columns)
	for line in 0 ..< win_height {
		for col in 0 ..< menu.columns {
			item_idx := (first_col + col) * win_height + line
			face := menu.bg
			atoms: []Display_Atom
			if item_idx < item_count {
				if item_idx == menu.selected_item {
					face = menu.fg
				}
				atoms = menu.items[item_idx].atoms[:]
			}
			terminal_ui_window_draw(
				&menu.window,
				Coord_Display{line = Coord_Line(line), column = Coord_Column(col * column_width)},
				atoms,
				face,
			)
		}
		is_mark := line >= mark_line && line < mark_line + mark_height
		mark := display_buffer_atom_text("█" if is_mark else "░", Face{})
		arr := [1]Display_Atom{mark}
		terminal_ui_window_draw(
			&menu.window,
			Coord_Display{line = Coord_Line(line), column = menu.size.column - 1},
			arr[:],
			menu.bg,
		)
	}
	ui.dirty = true
}

// terminal_ui_menu_show displays the choice menu (port of menu_show).
terminal_ui_menu_show :: proc(
	ui: ^Terminal_UI,
	items: []Display_Line,
	anchor: Coord_Display,
	fg, bg: Face,
	style: User_Interface_Menu_Style,
) {
	menu := &ui.menu
	if terminal_ui_window_valid(&menu.window) {
		terminal_ui_window_destroy(&menu.window)
		ui.dirty = true
	}
	menu.fg = fg
	menu.bg = bg
	menu.style = style
	menu.anchor = anchor
	if ui.dimensions.column <= 2 {
		return
	}
	item_count := len(items)
	longest: Coord_Column = 1
	for item in items {
		longest = max(longest, display_buffer_line_length(item))
	}
	max_width := ui.dimensions.column - 1
	is_inline := style == .Inline
	is_search := style == .Search
	if is_search {
		menu.columns = 0
	} else if is_inline {
		menu.columns = 1
	} else {
		menu.columns = max(int(max_width / (longest + 1)), 1)
	}
	max_height := min(
		int(terminal_ui_menu_height_limit(style)),
		max(int(anchor.line), int(ui.dimensions.line) - int(anchor.line) - 1),
	)
	height := 1 if is_search else min(max_height, terminal_ui_div_round_up(item_count, menu.columns))
	clones := make([dynamic]Display_Line, 0, menu.window.allocator)
	defer delete(clones)
	if height > 0 {
		maxlen := max_width
		if menu.columns > 1 && item_count > 1 {
			maxlen = max_width / Coord_Column(menu.columns) - 1
		}
		for item in items {
			clone := terminal_ui_clone_line(item, menu.window.allocator)
			display_buffer_line_trim(&clone, 0, maxlen, menu.window.allocator)
			append(&clones, clone)
		}
		placed := anchor
		if is_inline {
			placed.line += terminal_ui_content_line_offset(ui)
		}
		line := placed.line + 1
		column := max(Coord_Column(0), min(placed.column, ui.dimensions.column - longest - 1))
		if is_search {
			line = 0 if ui.status_on_top else ui.dimensions.line
			column = ui.dimensions.column / 2
		} else if !is_inline {
			line = 1 if ui.status_on_top else ui.dimensions.line - Coord_Line(height)
		} else if line + Coord_Line(height) > ui.dimensions.line && placed.line >= Coord_Line(height) {
			line = placed.line - Coord_Line(height)
		}
		width := ui.dimensions.column
		if is_search {
			width = ui.dimensions.column - ui.dimensions.column / 2
		} else if is_inline {
			width = min(longest + 1, ui.dimensions.column)
		}
		terminal_ui_window_create(
			&menu.window,
			Coord_Display{line = line, column = column},
			Coord_Display{line = Coord_Line(height), column = width},
			menu.window.allocator,
		)
		menu.selected_item = item_count
		menu.first_item = 0
	}
	terminal_ui_menu_free_items(menu)
	for clone in clones {
		append(&menu.items, clone)
	}
	clear(&clones)
	terminal_ui_draw_menu(ui)
	if terminal_ui_window_valid(&ui.info.window) {
		terminal_ui_info_show(ui, &ui.info.title, ui.info.content[:], ui.info.anchor, ui.info.face, ui.info.style)
	}
}

// terminal_ui_menu_select highlights one menu entry (port of
// menu_select).
terminal_ui_menu_select :: proc(ui: ^Terminal_UI, selected: int) {
	menu := &ui.menu
	item_count := len(menu.items)
	if !terminal_ui_window_valid(&menu.window) || int(menu.size.line) == 0 {
		menu.selected_item = -1 if selected < 0 || selected >= item_count else selected
		menu.first_item = 0
		return
	}
	if selected < 0 || selected >= item_count {
		menu.selected_item = -1
		menu.first_item = 0
	} else if menu.columns == 0 {
		menu.selected_item = selected
		width := int(menu.size.column) - 3
		first := 0
		item_col := 0
		for i in 0 ..= selected {
			item_width := int(display_buffer_line_length(menu.items[i])) + 1
			if item_col + item_width > width {
				first = i
				item_col = item_width
			} else {
				item_col += item_width
			}
		}
		menu.first_item = first
	} else {
		menu.selected_item = selected
		win_height := int(menu.size.line)
		menu_cols := terminal_ui_div_round_up(item_count, win_height)
		first_col := menu.first_item / win_height
		selected_col := selected / win_height
		if selected_col < first_col {
			menu.first_item = selected_col * win_height
		}
		if selected_col >= first_col + menu.columns {
			menu.first_item = min(selected_col, menu_cols - menu.columns) * win_height
		}
	}
	terminal_ui_draw_menu(ui)
}

// terminal_ui_menu_hide dismisses the menu (port of menu_hide).
terminal_ui_menu_hide :: proc(ui: ^Terminal_UI) {
	if !terminal_ui_window_valid(&ui.menu.window) {
		return
	}
	terminal_ui_menu_free_items(&ui.menu)
	terminal_ui_window_destroy(&ui.menu.window)
	ui.dirty = true
	if terminal_ui_window_valid(&ui.info.window) {
		terminal_ui_info_show(ui, &ui.info.title, ui.info.content[:], ui.info.anchor, ui.info.face, ui.info.style)
	}
}

// terminal_ui_compute_pos places a box near an anchor inside rect while
// avoiding to_avoid (port of compute_pos).
terminal_ui_compute_pos :: proc(
	anchor, size: Coord_Display,
	rect, to_avoid: Terminal_UI_Rect,
	prefer_above: bool,
) -> Coord_Display {
	above := prefer_above
	pos: Coord_Display
	if above {
		pos = Coord_Display{line = anchor.line - size.line, column = anchor.column}
		if pos.line < 0 {
			above = false
		}
	}
	rect_end := Coord_Display{
		line   = rect.pos.line + rect.size.line,
		column = rect.pos.column + rect.size.column,
	}
	if !above {
		pos = Coord_Display{line = anchor.line + 1, column = anchor.column}
		if pos.line + size.line >= rect_end.line {
			pos.line = max(rect.pos.line, anchor.line - size.line)
		}
	}
	if pos.column + size.column >= rect_end.column {
		pos.column = max(rect.pos.column, rect_end.column - size.column)
	}
	if to_avoid.size != (Coord_Display{}) {
		avoid_end := Coord_Display{
			line   = to_avoid.pos.line + to_avoid.size.line,
			column = to_avoid.pos.column + to_avoid.size.column,
		}
		end := Coord_Display{line = pos.line + size.line, column = pos.column + size.column}
		if !(end.line < to_avoid.pos.line ||
			   end.column < to_avoid.pos.column ||
			   pos.line > avoid_end.line ||
			   pos.column > avoid_end.column) {
			pos.line = min(to_avoid.pos.line, anchor.line) - size.line
			if pos.line < 0 {
				pos.line = max(avoid_end.line, anchor.line)
			}
		}
	}
	return pos
}

// terminal_ui_word_cut finds the column cut for wrapping, backing up to
// a word boundary (port of the content/find_if logic in wrap_lines).
terminal_ui_word_cut :: proc(content: string, keep: Coord_Column) -> Coord_Column {
	if keep <= 0 {
		return 0
	}
	cols: Coord_Column = 0
	off := 0
	for off < len(content) {
		cp, w := utf8.decode_rune_in_string(content[off:])
		if w <= 0 {
			w = 1
		}
		cw := Coord_Column(string_utils_codepoint_width(cp))
		if cols + cw > keep && cols > 0 {
			break
		}
		cols += cw
		off += w
		if cols >= keep {
			break
		}
	}
	extra := [1]rune{'_'}
	best := off
	scan := 0
	for scan < off {
		cp, w := utf8.decode_rune_in_string(content[scan:])
		if w <= 0 {
			w = 1
		}
		if !unicode_is_word(cp, extra[:]) {
			best = scan + w
		}
		scan += w
	}
	if best >= off || best <= 0 {
		return cols
	}
	result: Coord_Column = 0
	scan = 0
	for scan < best {
		cp, w := utf8.decode_rune_in_string(content[scan:])
		if w <= 0 {
			w = 1
		}
		result += Coord_Column(string_utils_codepoint_width(cp))
		scan += w
	}
	return result
}

// terminal_ui_wrap_lines wraps lines at max_width on word boundaries
// (port of wrap_lines). The result is owned by the caller.
terminal_ui_wrap_lines :: proc(
	lines: []Display_Line,
	max_width: Coord_Column,
	allocator := context.allocator,
) -> Display_Line_List {
	result := make(Display_Line_List, 0, allocator)
	for src in lines {
		work := terminal_ui_clone_line(src, allocator)
		column: Coord_Column = 0
		i := 0
		for i < len(work.atoms) {
			length := display_buffer_atom_length(work.atoms[i])
			column += length
			if column <= max_width {
				i += 1
				continue
			}
			cut := terminal_ui_word_cut(display_buffer_atom_content(work.atoms[i]), length - (column - max_width))
			if cut <= 0 || cut >= length {
				if i == 0 {
					i += 1
					continue
				}
				moved := display_buffer_line_make(allocator)
				display_buffer_line_insert_many(&moved, 0, work.atoms[:i])
				append(&result, moved)
				terminal_ui_remove_line_atoms(&work, 0, i)
				column = 0
				i = 0
				continue
			}
			end := display_buffer_line_split_col(&work, i, cut) + 1
			moved := display_buffer_line_make(allocator)
			display_buffer_line_insert_many(&moved, 0, work.atoms[:end])
			append(&result, moved)
			terminal_ui_remove_line_atoms(&work, 0, end)
			column = 0
			i = 0
		}
		append(&result, work)
	}
	return result
}

// terminal_ui_lines_size measures a line list (port of the compute_size
// lambda in info_show).
terminal_ui_lines_size :: proc(lines: []Display_Line) -> Coord_Display {
	size := Coord_Display{line = Coord_Line(len(lines))}
	for line in lines {
		size.column = max(size.column, display_buffer_line_length(line))
	}
	return size
}

// terminal_ui_assistant_lines returns the assistant art for a kind.
terminal_ui_assistant_lines :: proc(assistant: Terminal_UI_Assistant) -> []string {
	switch assistant {
	case .Clippy:
		return terminal_ui_assistant_clippy[:]
	case .Cat:
		return terminal_ui_assistant_cat[:]
	case .Dilbert:
		return terminal_ui_assistant_dilbert[:]
	case .None:
		return {}
	}
	return {}
}

// terminal_ui_info_draw_text draws one text run at (line, col),
// advancing col past it.
terminal_ui_info_draw_text :: proc(
	ui: ^Terminal_UI,
	line: int,
	col: ^Coord_Column,
	text: string,
	face: Face,
) {
	atom := display_buffer_atom_text(text, Face{})
	arr := [1]Display_Atom{atom}
	terminal_ui_window_draw(&ui.info.window, Coord_Display{line = Coord_Line(line), column = col^}, arr[:], face)
	col^ += terminal_ui_text_columns(text)
}

// terminal_ui_info_show displays the info box (port of info_show).
terminal_ui_info_show :: proc(
	ui: ^Terminal_UI,
	title: ^Display_Line,
	content: []Display_Line,
	anchor: Coord_Display,
	face: Face,
	style: User_Interface_Info_Style,
) {
	new_title := terminal_ui_clone_line(title^, ui.info.window.allocator)
	new_content := make(Display_Line_List, len(content), ui.info.window.allocator)
	for src, i in content {
		new_content[i] = terminal_ui_clone_line(src, ui.info.window.allocator)
	}
	terminal_ui_info_hide(ui)
	display_buffer_line_destroy(&ui.info.title)
	ui.info.title = new_title
	for &line in ui.info.content {
		display_buffer_line_destroy(&line)
	}
	delete(ui.info.content)
	ui.info.content = new_content
	ui.info.anchor = anchor
	ui.info.face = face
	ui.info.style = style

	framed := style == .Prompt || style == .Modal
	assistant_lines := terminal_ui_assistant_lines(ui.assistant)
	assisted := style == .Prompt && len(assistant_lines) != 0

	max_size := ui.dimensions
	if style == .Menu_Doc {
		max_size.column = max(
			ui.dimensions.column - (ui.menu.pos.column + ui.menu.size.column),
			ui.menu.pos.column,
		)
	} else if style != .Modal {
		max_size.line -= ui.menu.size.line
	}
	assistant_width: Coord_Column = 0
	if assisted {
		assistant_width = terminal_ui_text_columns(assistant_lines[0])
	}
	max_content_width := max_size.column
	if ui.info_max_width > 0 {
		max_content_width = min(max_size.column, ui.info_max_width)
	}
	if framed {
		max_content_width -= 4
	}
	if assisted {
		max_content_width -= assistant_width
	}
	if max_content_width <= 0 {
		return
	}
	content_size := terminal_ui_lines_size(ui.info.content[:])
	wrapped: Display_Line_List
	lines := ui.info.content[:]
	if content_size.column > max_content_width {
		wrapped = terminal_ui_wrap_lines(ui.info.content[:], max_content_width, ui.info.window.allocator)
		content_size = terminal_ui_lines_size(wrapped[:])
		lines = wrapped[:]
	}
	defer terminal_ui_destroy_line_list(&wrapped)

	size := Coord_Display{
		line   = content_size.line,
		column = max(content_size.column, display_buffer_line_length(ui.info.title) + (2 if framed else 0)),
	}
	if framed {
		size.line += 2
		size.column += 4
	}
	if assisted {
		size.line = max(Coord_Line(len(assistant_lines) - 1), size.line)
		size.column += assistant_width
	}
	size.line = min(max_size.line, size.line)
	size.column = min(max_size.column, size.column)
	if (framed && size.line < 3) || size.line <= 0 {
		return
	}
	rect := Terminal_UI_Rect{
		pos  = Coord_Display{line = terminal_ui_content_line_offset(ui)},
		size = ui.dimensions,
	}
	avoid := Terminal_UI_Rect{pos = ui.menu.pos, size = ui.menu.size}
	placed := anchor
	if style == .Prompt {
		placed = Coord_Display{
			line   = 0 if ui.status_on_top else ui.dimensions.line,
			column = ui.dimensions.column - 1,
		}
		placed = terminal_ui_compute_pos(placed, size, rect, avoid, false)
	} else if style == .Modal {
		placed = Coord_Display{
			line   = rect.pos.line + rect.size.line / 2 - size.line / 2,
			column = rect.pos.column + rect.size.column / 2 - size.column / 2,
		}
	} else if style == .Menu_Doc {
		right_max := ui.dimensions.column - (ui.menu.pos.column + ui.menu.size.column)
		left_max := ui.menu.pos.column
		placed.line = ui.menu.pos.line
		if size.column <= right_max || right_max >= left_max {
			placed.column = ui.menu.pos.column + ui.menu.size.column
		} else {
			placed.column = ui.menu.pos.column - size.column
		}
	} else {
		placed = terminal_ui_compute_pos(placed, size, rect, avoid, style == .Inline_Above)
		placed.line += terminal_ui_content_line_offset(ui)
	}
	terminal_ui_window_create(&ui.info.window, placed, size, ui.info.window.allocator)
	for line in 0 ..< int(size.line) {
		col: Coord_Column = 0
		if assisted {
			top_margin := (int(size.line) - len(assistant_lines) + 1) / 2
			art := assistant_lines[len(assistant_lines) - 1]
			if line >= top_margin {
				art = assistant_lines[min(line - top_margin, len(assistant_lines) - 1)]
			}
			terminal_ui_info_draw_text(ui, line, &col, art, face)
		}
		if !framed {
			terminal_ui_window_draw(
				&ui.info.window,
				Coord_Display{line = Coord_Line(line), column = col},
				lines[line].atoms[:],
				face,
			)
		} else if line == 0 {
			if len(ui.info.title.atoms) == 0 || content_size.column < 2 {
				dashes := terminal_ui_repeat_rune('─', int(content_size.column), context.temp_allocator)
				top := strings.builder_make(context.temp_allocator)
				strings.write_string(&top, "╭─")
				strings.write_string(&top, dashes)
				strings.write_string(&top, "─╮")
				terminal_ui_info_draw_text(ui, line, &col, strings.to_string(top), face)
			} else {
				trimmed := terminal_ui_clone_line(ui.info.title, context.temp_allocator)
				display_buffer_line_trim(&trimmed, 0, content_size.column - 2, context.temp_allocator)
				dash_count := int(content_size.column) - int(display_buffer_line_length(trimmed)) - 2
				left := terminal_ui_repeat_rune('─', dash_count / 2, context.temp_allocator)
				right := terminal_ui_repeat_rune('─', dash_count - dash_count / 2, context.temp_allocator)
				head := strings.builder_make(context.temp_allocator)
				strings.write_string(&head, "╭─")
				strings.write_string(&head, left)
				strings.write_string(&head, "┤")
				terminal_ui_info_draw_text(ui, line, &col, strings.to_string(head), face)
				terminal_ui_window_draw(
					&ui.info.window,
					Coord_Display{line = Coord_Line(line), column = col},
					trimmed.atoms[:],
					face,
				)
				col += display_buffer_line_length(trimmed)
				tail := strings.builder_make(context.temp_allocator)
				strings.write_string(&tail, "├")
				strings.write_string(&tail, right)
				strings.write_string(&tail, "─╮")
				terminal_ui_info_draw_text(ui, line, &col, strings.to_string(tail), face)
			}
		} else if line < int(size.line) - 1 && line <= len(lines) {
			info_line := terminal_ui_clone_line(lines[line - 1], context.temp_allocator)
			trimmed := display_buffer_line_trim(&info_line, 0, content_size.column, context.temp_allocator)
			padding := content_size.column - display_buffer_line_length(info_line)
			terminal_ui_info_draw_text(ui, line, &col, "│ ", face)
			terminal_ui_window_draw(
				&ui.info.window,
				Coord_Display{line = Coord_Line(line), column = col},
				info_line.atoms[:],
				face,
			)
			col += display_buffer_line_length(info_line)
			col += padding
			terminal_ui_info_draw_text(ui, line, &col, "…│" if trimmed else " │", face)
		} else if line == min(len(lines) + 1, int(size.line) - 1) {
			dashes := terminal_ui_repeat_rune('─' if line > len(lines) else '┄', int(content_size.column), context.temp_allocator)
			bottom := strings.builder_make(context.temp_allocator)
			strings.write_string(&bottom, "╰─")
			strings.write_string(&bottom, dashes)
			strings.write_string(&bottom, "─╯")
			terminal_ui_info_draw_text(ui, line, &col, strings.to_string(bottom), face)
		}
	}
	ui.dirty = true
}

// terminal_ui_info_hide dismisses the info box (port of info_hide).
terminal_ui_info_hide :: proc(ui: ^Terminal_UI) {
	if !terminal_ui_window_valid(&ui.info.window) {
		return
	}
	terminal_ui_window_destroy(&ui.info.window)
	ui.dirty = true
}

// terminal_ui_sync_active reports whether synchronized output applies
// (port of the Synchronized bool conversion).
terminal_ui_sync_active :: proc(sync: ^Terminal_UI_Synchronized) -> bool {
	if sync.set {
		return sync.requested
	}
	return sync.supported
}

// terminal_ui_redraw blits the windows and emits the screen (port of
// redraw).
terminal_ui_redraw :: proc(ui: ^Terminal_UI, force: bool, allocator := context.allocator) {
	terminal_ui_window_blit(&ui.window, &ui.screen.window)
	if ui.menu.columns != 0 || ui.menu.pos.column > ui.status_len {
		terminal_ui_window_blit(&ui.menu.window, &ui.screen.window)
	}
	terminal_ui_window_blit(&ui.info.window, &ui.screen.window)
	terminal_ui_screen_write(&ui.screen, force, terminal_ui_sync_active(&ui.synchronized), &ui.output, allocator)
	if ui.status_cursor_pos > 0 {
		line := Coord_Line(0) if ui.status_on_top else ui.dimensions.line
		fmt.sbprintf(&ui.output, "\033[{};{}H", int(line) + 1, int(ui.status_cursor_pos) + 1)
	} else {
		cursor := Coord_Display{
			line   = ui.cursor_pos.line + terminal_ui_content_line_offset(ui),
			column = ui.cursor_pos.column,
		}
		fmt.sbprintf(&ui.output, "\033[{};{}H", int(cursor.line) + 1, int(cursor.column) + 1)
	}
}

// terminal_ui_refresh repaints when dirty or forced (port of refresh).
// Output stays buffered; the real paths flush it afterwards.
terminal_ui_refresh :: proc(ui: ^Terminal_UI, force: bool, allocator := context.allocator) {
	if ui.dirty || force {
		terminal_ui_redraw(ui, force, allocator)
	}
	ui.dirty = false
}

// terminal_ui_set_on_key installs the key callback (port of set_on_key).
terminal_ui_set_on_key :: proc(ui: ^Terminal_UI, callback: User_Interface_On_Key_Callback) {
	ui.on_key = callback
	terminal_ui_force_signal(0)
}

// terminal_ui_set_on_paste installs the paste callback (port of
// set_on_paste).
terminal_ui_set_on_paste :: proc(ui: ^Terminal_UI, callback: User_Interface_On_Paste_Callback) {
	ui.on_paste = callback
}

// Terminal_UI_Winsize mirrors struct winsize for TIOCGWINSZ.
Terminal_UI_Winsize :: struct {
	rows:   u16,
	cols:   u16,
	xpixel: u16,
	ypixel: u16,
}

// terminal_ui_query_size reads the tty size via ioctl (port of the
// /dev/tty query in check_resize).
terminal_ui_query_size :: proc() -> (rows, cols: int, ok: bool) {
	fd := posix.open("/dev/tty", posix.O_Flags{.RDWR})
	if fd < 0 {
		return 0, 0, false
	}
	defer posix.close(fd)
	ws := Terminal_UI_Winsize{}
	if linux.ioctl(linux.Fd(fd), linux.TIOCGWINSZ, uintptr(rawptr(&ws))) != 0 {
		return 0, 0, false
	}
	if ws.rows == 0 || ws.cols == 0 {
		return terminal_ui_FALLBACK_LINES, terminal_ui_FALLBACK_COLUMNS, true
	}
	return int(ws.rows), int(ws.cols), true
}

// terminal_ui_apply_size rebuilds the windows for rows x cols,
// re-showing the menu and info box (port of the check_resize body).
// Non-positive sizes fall back to 24x80, like a zero winsize.
terminal_ui_apply_size :: proc(ui: ^Terminal_UI, rows, cols: int) {
	size := Coord_Display{line = Coord_Line(rows), column = Coord_Column(cols)}
	if rows <= 0 || cols <= 0 {
		size = Coord_Display{
			line   = terminal_ui_FALLBACK_LINES,
			column = terminal_ui_FALLBACK_COLUMNS,
		}
	}
	info_valid := terminal_ui_window_valid(&ui.info.window)
	menu_valid := terminal_ui_window_valid(&ui.menu.window)
	terminal_ui_window_destroy(&ui.window)
	if info_valid {
		terminal_ui_window_destroy(&ui.info.window)
	}
	if menu_valid {
		terminal_ui_window_destroy(&ui.menu.window)
	}
	terminal_ui_window_create(&ui.window, Coord_Display{}, size, ui.allocator)
	terminal_ui_screen_create(&ui.screen, Coord_Display{}, size, ui.allocator)
	assert(terminal_ui_window_valid(&ui.window))
	ui.dimensions = Coord_Display{line = size.line - 1, column = size.column}
	if menu_valid {
		terminal_ui_menu_show(ui, ui.menu.items[:], ui.menu.anchor, ui.menu.fg, ui.menu.bg, ui.menu.style)
	}
	if info_valid {
		terminal_ui_info_show(ui, &ui.info.title, ui.info.content[:], ui.info.anchor, ui.info.face, ui.info.style)
	}
	ui.resize_pending = true
	terminal_ui_force_signal(0)
}

// terminal_ui_check_resize re-queries the tty size when a resize is
// pending or forced (port of check_resize).
terminal_ui_check_resize :: proc(ui: ^Terminal_UI, force := false) {
	if !force && !terminal_ui_resize_flag {
		return
	}
	terminal_ui_resize_flag = false
	rows, cols, ok := terminal_ui_query_size()
	if !ok {
		return
	}
	terminal_ui_apply_size(ui, rows, cols)
}

// terminal_ui_to_bool parses a yes/true option value.
terminal_ui_to_bool :: proc(s: string) -> bool {
	return s == "yes" || s == "true"
}

// terminal_ui_option_bool reads a bool UI option with a default.
terminal_ui_option_bool :: proc(options: User_Interface_Options, name: string, default: bool) -> bool {
	if value, ok := options[name]; ok {
		return terminal_ui_to_bool(value)
	}
	return default
}

// terminal_ui_option_int reads an int UI option with a default.
terminal_ui_option_int :: proc(options: User_Interface_Options, name: string, default: int) -> int {
	if value, ok := options[name]; ok {
		if n, valid := string_utils_str_to_int_ifp(value); valid {
			return n
		}
	}
	return default
}

// terminal_ui_set_ui_options applies UI options (port of
// set_ui_options).
terminal_ui_set_ui_options :: proc(ui: ^Terminal_UI, options: User_Interface_Options) {
	assistant := "clippy"
	if value, ok := options["terminal_assistant"]; ok {
		assistant = value
	}
	switch assistant {
	case "clippy":
		ui.assistant = .Clippy
	case "cat":
		ui.assistant = .Cat
	case "dilbert":
		ui.assistant = .Dilbert
	case "none", "off":
		ui.assistant = .None
	}
	ui.status_on_top = terminal_ui_option_bool(options, "terminal_status_on_top", false)
	ui.set_title = terminal_ui_option_bool(options, "terminal_set_title", true)
	if ui.has_title {
		delete(ui.title, ui.allocator)
		ui.has_title = false
		ui.title = ""
	}
	if title, ok := options["terminal_title"]; ok {
		ui.title = strings.clone(title, ui.allocator)
		ui.has_title = true
	}
	if value, ok := options["terminal_synchronized"]; ok {
		ui.synchronized.set = true
		ui.synchronized.requested = terminal_ui_to_bool(value)
	} else {
		ui.synchronized.set = false
		ui.synchronized.requested = false
	}
	if !ui.synchronized.queried && !ui.synchronized.set {
		strings.write_string(&ui.output, "\033[?2026$p")
		ui.synchronized.queried = true
	}
	ui.shift_function_key = terminal_ui_option_int(
		options,
		"terminal_shift_function_key",
		terminal_ui_SHIFT_FUNCTION_KEY_DEFAULT,
	)
	terminal_ui_enable_mouse(ui, terminal_ui_option_bool(options, "terminal_enable_mouse", true))
	ui.wheel_scroll = terminal_ui_option_int(options, "terminal_wheel_scroll_amount", terminal_ui_WHEEL_SCROLL_DEFAULT)
	padding := '~'
	if value, ok := options["terminal_padding_char"]; ok {
		if terminal_ui_text_columns(value) < 1 {
			padding = ' '
		} else {
			padding, _ = utf8.decode_rune_in_string(value)
		}
	}
	ui.padding_char = padding
	ui.padding_fill = terminal_ui_option_bool(options, "terminal_padding_fill", false)
	cursor_native := terminal_ui_option_bool(options, "terminal_cursor_native", false)
	if cursor_native != ui.cursor_native {
		ui.cursor_native = cursor_native
		strings.write_string(&ui.output, "\033[?25h" if cursor_native else "\033[?25l")
	}
	ui.info_max_width = Coord_Column(terminal_ui_option_int(options, "terminal_info_max_width", 0))
}

// terminal_ui_enable_mouse toggles mouse reporting (port of
// enable_mouse).
terminal_ui_enable_mouse :: proc(ui: ^Terminal_UI, enabled: bool) {
	if enabled == ui.mouse_enabled {
		return
	}
	ui.mouse_enabled = enabled
	strings.write_string(&ui.output, terminal_ui_mouse_enable_text if enabled else terminal_ui_mouse_disable_text)
}

// terminal_ui_set_raw_mode switches stdin to raw mode (port of
// set_raw_mode).
terminal_ui_set_raw_mode :: proc(ui: ^Terminal_UI) -> Terminal_UI_Error {
	if !ui.have_termios {
		return .Tcgetattr_Failed
	}
	attr := ui.original_termios
	attr.c_iflag -= {.IGNBRK, .BRKINT, .PARMRK, .ISTRIP, .INLCR, .IGNCR, .ICRNL, .IXON}
	attr.c_oflag -= {.OPOST}
	attr.c_lflag -= {.ECHO, .ECHONL, .ICANON, .ISIG, .IEXTEN}
	attr.c_lflag += {.NOFLSH}
	attr.c_cflag = (attr.c_cflag - posix.CSIZE) - {.PARENB} + {.CS8}
	attr.c_cc[.VMIN] = 0
	attr.c_cc[.VTIME] = 0
	if posix.tcsetattr(posix.STDIN_FILENO, .TCSANOW, &attr) != .OK {
		return .Tcsetattr_Failed
	}
	return .None
}

// terminal_ui_init_tty attaches a UI to the real terminal: tty check,
// raw mode, mouse, signals, stdin watcher and initial resize (port of
// the TerminalUI constructor).
terminal_ui_init_tty :: proc(ui: ^Terminal_UI) -> Terminal_UI_Error {
	if posix.isatty(posix.STDOUT_FILENO) == false {
		return .Not_A_Tty
	}
	if posix.tcgetattr(posix.STDIN_FILENO, &ui.original_termios) != .OK {
		return .Tcgetattr_Failed
	}
	ui.have_termios = true
	terminal_ui_singleton = ui
	strings.write_string(&ui.output, terminal_ui_setup_text)
	if err := terminal_ui_set_raw_mode(ui); err != .None {
		return err
	}
	terminal_ui_enable_mouse(ui, true)
	_, _ = event_manager_set_signal_handler(posix.Signal(posix.SIGWINCH), terminal_ui_sigwinch_handler)
	_, _ = event_manager_set_signal_handler(.SIGHUP, terminal_ui_sighup_handler)
	_, _ = event_manager_set_signal_handler(.SIGTSTP, terminal_ui_sigtstp_handler)
	event_manager_fd_watcher_init(
		&ui.stdin_watcher,
		int(posix.STDIN_FILENO),
		{.Read},
		.Urgent,
		terminal_ui_stdin_callback,
	)
	ui.watcher_active = true
	terminal_ui_check_resize(ui, true)
	terminal_ui_refresh(ui, false)
	return terminal_ui_flush(ui)
}

// terminal_ui_suspend suspends on SIGTSTP and restores the terminal on
// resume (port of suspend).
terminal_ui_suspend :: proc(ui: ^Terminal_UI) {
	if ui.on_key != nil {
		ui.on_key(Keys_Key{key = keys_FOCUS_OUT})
	}
	mouse_enabled := ui.mouse_enabled
	terminal_ui_enable_mouse(ui, false)
	if ui.have_termios {
		posix.tcsetattr(posix.STDIN_FILENO, .TCSAFLUSH, &ui.original_termios)
	}
	strings.write_string(&ui.output, terminal_ui_restore_text)
	terminal_ui_flush(ui)
	new_action, old_action: posix.sigaction_t
	posix.sigemptyset(&new_action.sa_mask)
	new_action.sa_handler = nil
	new_action.sa_flags = {}
	posix.sigaction(.SIGTSTP, &new_action, &old_action)
	unblock, old_mask: posix.sigset_t
	posix.sigemptyset(&unblock)
	posix.sigaddset(&unblock, .SIGTSTP)
	posix.sigprocmask(.UNBLOCK, &unblock, &old_mask)
	posix.kill(posix.getpid(), .SIGTSTP)
	posix.sigaction(.SIGTSTP, &old_action, nil)
	posix.sigprocmask(.SETMASK, &old_mask, nil)
	strings.write_string(&ui.output, terminal_ui_setup_text)
	terminal_ui_flush(ui)
	terminal_ui_check_resize(ui, true)
	terminal_ui_set_raw_mode(ui)
	terminal_ui_enable_mouse(ui, mouse_enabled)
	terminal_ui_refresh(ui, true)
	terminal_ui_flush(ui)
	if ui.on_key != nil {
		ui.on_key(Keys_Key{key = keys_FOCUS_IN})
	}
}

// terminal_ui_poll parses the next input event: hangup, resize, then
// parser input (port of get_next_key).
terminal_ui_poll :: proc(
	ui: ^Terminal_UI,
	final: bool,
	allocator := context.allocator,
) -> (event: Terminal_UI_Event, ok: bool) {
	if terminal_ui_hangup_flag {
		_, _ = event_manager_set_signal_handler(posix.Signal(posix.SIGWINCH), nil)
		posix.sigignore(.SIGHUP)
		if terminal_ui_window_valid(&ui.window) {
			terminal_ui_window_destroy(&ui.window)
		}
		event_manager_fd_watcher_disable(&ui.stdin_watcher)
		return {}, false
	}
	if terminal_ui_suspend_flag {
		terminal_ui_suspend_flag = false
		terminal_ui_suspend(ui)
	}
	terminal_ui_check_resize(ui)
	if ui.resize_pending {
		ui.resize_pending = false
		return keys_resize(Keys_Coord{line = int(ui.dimensions.line), column = int(ui.dimensions.column)}), true
	}
	if ui.have_termios {
		ui.parser.erase_char = u8(ui.original_termios.c_cc[.VERASE])
	}
	ui.parser.line_offset = int(terminal_ui_content_line_offset(ui))
	ui.parser.wheel_scroll = ui.wheel_scroll
	event, ok = terminal_ui_parser_next(&ui.parser, final, allocator)
	if !ok {
		return {}, false
	}
	if ui.parser.sync_seen {
		ui.synchronized.supported = ui.parser.sync_supported
		ui.parser.sync_seen = false
	}
	return event, true
}

// terminal_ui_drain_stdin reads available stdin bytes into the parser.
terminal_ui_drain_stdin :: proc(ui: ^Terminal_UI) {
	buf: [256]u8
	for {
		n := posix.read(posix.STDIN_FILENO, raw_data(buf[:]), c.size_t(len(buf)))
		if n == 0 {
			break
		}
		if n < 0 {
			terminal_ui_hangup_flag = true
			break
		}
		append(&ui.parser.input, ..buf[:int(n)])
	}
}

// terminal_ui_dispatch_available polls final input and runs the key and
// paste callbacks (port of the stdin watcher body).
terminal_ui_dispatch_available :: proc(ui: ^Terminal_UI, allocator := context.allocator) {
	if ui.on_key == nil {
		return
	}
	for {
		event, ok := terminal_ui_poll(ui, true, allocator)
		if !ok {
			break
		}
		switch ev in event {
		case Keys_Key:
			if ev.modifiers == keys_MOD_CONTROL && ev.key == 'z' {
				posix.kill(0, .SIGTSTP)
			} else if ev.key != keys_INVALID {
				ui.on_key(ev)
			}
		case Terminal_UI_Paste:
			if ui.on_paste != nil {
				ui.on_paste(ev.content)
			}
			delete(ev.content, allocator)
		}
	}
}

// terminal_ui_stdin_callback drains stdin and dispatches input.
terminal_ui_stdin_callback :: proc(
	watcher: ^Event_Manager_Fd_Watcher,
	events: Event_Manager_Fd_Events,
	mode: Event_Manager_Mode,
) {
	_ = watcher
	_ = events
	_ = mode
	ui := terminal_ui_singleton
	if ui == nil {
		return
	}
	terminal_ui_drain_stdin(ui)
	terminal_ui_dispatch_available(ui)
}

// terminal_ui_sigwinch_handler flags a pending resize (port of
// signal_handler<&resize_pending>). Only the flag is set: "c"
// handlers cannot call context-carrying procedures, so the event
// manager is not poked and the flag is serviced on the next dispatch.
terminal_ui_sigwinch_handler :: proc "c" (sig: posix.Signal) {
	_ = sig
	terminal_ui_resize_flag = true
}

// terminal_ui_sighup_handler flags a terminal hangup (port of
// signal_handler<&terminal_hungup>).
terminal_ui_sighup_handler :: proc "c" (sig: posix.Signal) {
	_ = sig
	terminal_ui_hangup_flag = true
}

// terminal_ui_sigtstp_handler flags a suspend request, serviced by
// terminal_ui_poll (port of the SIGTSTP lambda).
terminal_ui_sigtstp_handler :: proc "c" (sig: posix.Signal) {
	_ = sig
	terminal_ui_suspend_flag = true
}

// terminal_ui_as_interface wraps a UI in a User_Interface handle. Each
// User_Interface_Display_Line passed through the vtable must carry a
// ^Display_Line in .opaque, and each
// User_Interface_Display_Buffer a ^Display_Buffer.
terminal_ui_as_interface :: proc(ui: ^Terminal_UI) -> User_Interface {
	return user_interface_make(ui, &terminal_ui_vtable)
}

// terminal_ui_restore_terminal writes the teardown escape sequence
// straight to stdout (C++ TerminalUI::restore_terminal, static; called by
// the fatal signal handler in main). Termios is untouched, like the C++.
terminal_ui_restore_terminal :: proc() {
	data := transmute([]byte)(terminal_ui_restore_text)
	_ = posix.write(posix.STDOUT_FILENO, raw_data(data), c.size_t(len(data)))
}

// terminal_ui_make_ui heap-allocates a Terminal_UI and wraps it in a heap
// User_Interface handle (what main_make_ui needs). Release with
// terminal_ui_destroy_ui, same allocator.
terminal_ui_make_ui :: proc(allocator := context.allocator) -> ^User_Interface {
	tui := new(Terminal_UI, allocator)
	tui^ = terminal_ui_make(allocator)
	iface := new(User_Interface, allocator)
	iface^ = terminal_ui_as_interface(tui)
	return iface
}

// terminal_ui_destroy_ui releases a handle built by terminal_ui_make_ui.
terminal_ui_destroy_ui :: proc(ui: ^User_Interface, allocator := context.allocator) {
	tui := (^Terminal_UI)(ui.data)
	terminal_ui_destroy(tui)
	free(tui, allocator)
	free(ui, allocator)
}

terminal_ui_vtable_is_ok :: proc(data: rawptr) -> bool {
	ui := (^Terminal_UI)(data)
	return terminal_ui_window_valid(&ui.window)
}

terminal_ui_vtable_menu_show :: proc(
	data: rawptr,
	choices: []User_Interface_Display_Line,
	anchor: Coord_Display,
	fg, bg: Face,
	style: User_Interface_Menu_Style,
) {
	ui := (^Terminal_UI)(data)
	lines := make([]Display_Line, len(choices), context.temp_allocator)
	for choice, i in choices {
		lines[i] = ((^Display_Line)(choice.opaque))^
	}
	terminal_ui_menu_show(ui, lines, anchor, fg, bg, style)
}

terminal_ui_vtable_menu_select :: proc(data: rawptr, selected: int) {
	terminal_ui_menu_select((^Terminal_UI)(data), selected)
}

terminal_ui_vtable_menu_hide :: proc(data: rawptr) {
	terminal_ui_menu_hide((^Terminal_UI)(data))
}

terminal_ui_vtable_info_show :: proc(
	data: rawptr,
	title: ^User_Interface_Display_Line,
	content: []User_Interface_Display_Line,
	anchor: Coord_Display,
	face: Face,
	style: User_Interface_Info_Style,
) {
	ui := (^Terminal_UI)(data)
	lines := make([]Display_Line, len(content), context.temp_allocator)
	for item, i in content {
		lines[i] = ((^Display_Line)(item.opaque))^
	}
	terminal_ui_info_show(ui, (^Display_Line)(title.opaque), lines, anchor, face, style)
}

terminal_ui_vtable_info_hide :: proc(data: rawptr) {
	terminal_ui_info_hide((^Terminal_UI)(data))
}

terminal_ui_vtable_draw :: proc(
	data: rawptr,
	display_buffer: ^User_Interface_Display_Buffer,
	cursor_pos: Coord_Display,
	default_face, padding_face: Face,
	widget_columns: Coord_Column,
) {
	ui := (^Terminal_UI)(data)
	terminal_ui_draw(
		ui,
		(^Display_Buffer)(display_buffer.opaque),
		cursor_pos,
		default_face,
		padding_face,
		widget_columns,
	)
}

terminal_ui_vtable_draw_status :: proc(
	data: rawptr,
	prompt, content: ^User_Interface_Display_Line,
	cursor_pos: Coord_Column,
	mode_line: ^User_Interface_Display_Line,
	default_face: Face,
	style: User_Interface_Status_Style,
) {
	ui := (^Terminal_UI)(data)
	terminal_ui_draw_status(
		ui,
		(^Display_Line)(prompt.opaque),
		(^Display_Line)(content.opaque),
		cursor_pos,
		(^Display_Line)(mode_line.opaque),
		default_face,
		style,
	)
}

terminal_ui_vtable_dimensions :: proc(data: rawptr) -> Coord_Display {
	return (^Terminal_UI)(data).dimensions
}

terminal_ui_vtable_refresh :: proc(data: rawptr, force: bool) {
	ui := (^Terminal_UI)(data)
	terminal_ui_refresh(ui, force)
	terminal_ui_flush(ui)
}

terminal_ui_vtable_set_on_key :: proc(data: rawptr, callback: User_Interface_On_Key_Callback) {
	terminal_ui_set_on_key((^Terminal_UI)(data), callback)
}

terminal_ui_vtable_set_on_paste :: proc(data: rawptr, callback: User_Interface_On_Paste_Callback) {
	terminal_ui_set_on_paste((^Terminal_UI)(data), callback)
}

terminal_ui_vtable_set_ui_options :: proc(data: rawptr, options: User_Interface_Options) {
	terminal_ui_set_ui_options((^Terminal_UI)(data), options)
}

// terminal_ui_vtable implements User_Interface for Terminal_UI.
terminal_ui_vtable := User_Interface_VTable{
	is_ok          = terminal_ui_vtable_is_ok,
	menu_show      = terminal_ui_vtable_menu_show,
	menu_select    = terminal_ui_vtable_menu_select,
	menu_hide      = terminal_ui_vtable_menu_hide,
	info_show      = terminal_ui_vtable_info_show,
	info_hide      = terminal_ui_vtable_info_hide,
	draw           = terminal_ui_vtable_draw,
	draw_status    = terminal_ui_vtable_draw_status,
	dimensions     = terminal_ui_vtable_dimensions,
	refresh        = terminal_ui_vtable_refresh,
	set_on_key     = terminal_ui_vtable_set_on_key,
	set_on_paste   = terminal_ui_vtable_set_on_paste,
	set_ui_options = terminal_ui_vtable_set_ui_options,
}
