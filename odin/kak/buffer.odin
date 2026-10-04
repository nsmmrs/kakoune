// Port of Kakoune's src/buffer.{hh,cc} and src/buffer.inl.hh: the in-memory
// file representation with undo history.
//
// Types (Buffer, Buffer_Change, ...) come from knot.odin (READ-ONLY shared
// vocabulary). This file implements the Buffer procs plus the BufferIterator
// procs and the EolFormat/ByteOrderMark/FinalEol enum tables from buffer.hh.
//
// Ownership and lifecycle:
//   * buffer_make heap-allocates a Buffer (with `allocator`, stored in the
//     struct) and clones every line; buffer_destroy frees the lines, the
//     undo history, names, values, scope data and the Buffer itself.
//   * Buffer-owned allocations (lines, undo content, names) always use
//     b.allocator. Procs returning caller-owned strings (buffer_string,
//     buffer_debug_description) take an `allocator` param.
//   * Buffer_Iterator borrows b.lines; any mutation invalidates it.
//   * C++ throw_if_read_only becomes the Buffer_Error.Read_Only return;
//     invalid coords stay hard asserts, as in C++ (kak_assert).
//
// Known deviations (all forced by unmerged modules, see summary):
//   * Option sync (eolformat/finaleol/BOM/readonly) in make/reload is
//     deferred: option_manager is unmerged, so the params are accepted
//     for signature parity but not stored. Hook/option paths
//     (on_registered, run_hook, ...) call STUBs and panic until merged.
//   * Scope parents are nil (global scope unmerged); faces preload the
//     default table so face lookup behaves as in a registered buffer.
//   * buffer_iterator_distance returns int (C++ wraps negatives in size_t).
//   * Defensive guards where C++ has UB: iterator construction at
//     end-of-buffer, advance-assign clamping, empty-line edge in do_insert.
//   * C++ declares but never defines Buffer::revert_modification; it is
//     omitted here as well.
package kak

import "core:fmt"
import "core:strings"

// Buffer_Error is the module error. Zero value `None` is success;
// `Read_Only` ports the C++ `throw_if_read_only` runtime_error.
Buffer_Error :: enum {
	None,
	Read_Only,
}

// buffer_error_message describes an error, porting the C++ throw text.
buffer_error_message :: proc(err: Buffer_Error) -> string {
	switch err {
	case .None:
		return ""
	case .Read_Only:
		return "buffer is read-only"
	}
	unreachable()
}

// buffer_eol_format_descs is the canonical name table (port of the
// enum_desc<EolFormat> overload), shared by the to/from-name helpers.
buffer_eol_format_descs := [2]Enum_Desc(Eol_Format){{.Lf, "lf"}, {.Crlf, "crlf"}}

// buffer_eol_format_to_name maps an EOL format to its canonical name.
buffer_eol_format_to_name :: proc(format: Eol_Format) -> (name: string, ok: bool) {
	return enum_to_name(buffer_eol_format_descs[:], format)
}

// buffer_eol_format_from_name parses a canonical EOL format name.
buffer_eol_format_from_name :: proc(name: string) -> (format: Eol_Format, ok: bool) {
	return enum_from_name(buffer_eol_format_descs[:], name)
}

// buffer_byte_order_mark_descs is the canonical name table (port of the
// enum_desc<ByteOrderMark> overload).
buffer_byte_order_mark_descs := [2]Enum_Desc(Byte_Order_Mark){{.None, "none"}, {.Utf8, "utf8"}}

// buffer_byte_order_mark_to_name maps a BOM marker to its canonical name.
buffer_byte_order_mark_to_name :: proc(bom: Byte_Order_Mark) -> (name: string, ok: bool) {
	return enum_to_name(buffer_byte_order_mark_descs[:], bom)
}

// buffer_byte_order_mark_from_name parses a canonical BOM marker name.
buffer_byte_order_mark_from_name :: proc(name: string) -> (bom: Byte_Order_Mark, ok: bool) {
	return enum_from_name(buffer_byte_order_mark_descs[:], name)
}

// buffer_final_eol_descs is the canonical name table (port of the
// enum_desc<FinalEol> overload).
buffer_final_eol_descs := [3]Enum_Desc(Final_Eol){{.Present, "present"}, {.Missing, "missing"}, {.If_Not_Empty, "ifnotempty"}}

// buffer_final_eol_to_name maps a final-EOL mode to its canonical name.
buffer_final_eol_to_name :: proc(mode: Final_Eol) -> (name: string, ok: bool) {
	return enum_to_name(buffer_final_eol_descs[:], mode)
}

// buffer_final_eol_from_name parses a canonical final-EOL mode name.
buffer_final_eol_from_name :: proc(name: string) -> (mode: Final_Eol, ok: bool) {
	return enum_from_name(buffer_final_eol_descs[:], name)
}

// buffer_set_file_option records one decoded file attribute as a
// buffer-local option (port of the Buffer ctor/reload option sets).
// Fixture buffers with no declared option in the parent chain keep
// the inherited value instead.
buffer_set_file_option :: proc(b: ^Buffer, name: string, value: Option_Value) {
	mgr := &b.scope.data.options
	opt, err := option_manager_get_local_option(mgr, name, mgr.allocator)
	if err != .None {
		return
	}
	set_err, _ := option_manager_option_set(opt, value, true)
	assert(set_err == .None)
}

// buffer_set_file_options records the decoded BOM/EOL attributes as
// buffer-local options (port of the Buffer ctor/reload option sets).
buffer_set_file_options :: proc(b: ^Buffer, bom: Byte_Order_Mark, eolformat: Eol_Format, finaleol: Final_Eol) {
	buffer_set_file_option(b, "BOM", bom)
	buffer_set_file_option(b, "eolformat", eolformat)
	buffer_set_file_option(b, "finaleol", finaleol)
}

// buffer_make creates a heap Buffer with cloned lines (each line must end
// with '\n', as in C++). File buffers resolve the display name through
// the merged file module. The bom/eolformat/finaleol values are applied
// to the buffer-local options by buffer_manager_create after the scope
// reparent (the fresh scope has no parent chain yet); direct fixture
// callers keep inherited values. Free with buffer_destroy.
buffer_make :: proc(
	name: string,
	flags: Buffer_Flags,
	lines: []string,
	bom: Byte_Order_Mark,
	eolformat: Eol_Format,
	finaleol: Final_Eol,
	fs_status: File_Fs_Status,
	allocator := context.allocator,
) -> ^Buffer {
	// Option values are set on the scope's OptionManager in C++; that
	// module is unmerged, so there is nowhere to store them yet.
	_ = bom
	_ = eolformat
	_ = finaleol

	b := new(Buffer, allocator)
	b.allocator = allocator
	b.lines = make(Buffer_Lines, 0, len(lines), allocator)
	for l in lines {
		append(&b.lines, strings.clone(l, allocator))
	}
	if .File in flags {
		// C++ real_path/compact_path cannot fail; the Odin ports only
		// fail when getcwd fails, in which case keep the raw name.
		real, real_err := file_real_path(name, allocator)
		b.filename = real if real_err == .None else strings.clone(name, allocator)
		compact, compact_err := file_compact_path(b.filename, allocator)
		b.display_name = compact if compact_err == .None else strings.clone(b.filename, allocator)
	} else {
		b.filename = ""
		b.display_name = strings.clone(name, allocator)
	}
	// C++ sets NoUndo then clears it unless requested; the net effect
	// is exactly the input flags.
	b.flags = flags
	b.history = make([dynamic]Buffer_History_Node, 0, 1, allocator)
	append(&b.history, Buffer_History_Node{parent = buffer_HISTORY_INVALID, redo_child = buffer_HISTORY_INVALID, committed = clock_now()})
	b.history_id = buffer_HISTORY_FIRST
	b.last_save_history_id = buffer_HISTORY_FIRST
	b.current_undo_group = make([dynamic]Buffer_Modification, 0, allocator)
	b.changes = make([dynamic]Buffer_Change, 0, allocator)
	append(&b.changes, Buffer_Change{type = .Insert, begin = {0, 0}, end = buffer_end_coord(b)})
	b.fs_status = fs_status
	b.values = make(Value_Map, allocator)

	// Scope::Data construction (scope module unmerged): parents stay nil
	// and merged managers use their own make procs. Faces preload the
	// default table so lookups behave as in a registered buffer.
	data := new(Scope_Data, allocator)
	data.options = Option_Manager {
		options   = make(map[string]^Option, allocator),
		watchers  = make([dynamic]Option_Watcher, 0, allocator),
		allocator = allocator,
	}
	data.hooks = Hook_Manager {
		running_hooks = make([dynamic]Hook_Running, 0, allocator),
		hooks_trash   = make([dynamic]^Hook_Data, 0, allocator),
		allocator     = allocator,
	}
	data.keymaps = keymap_manager_init(allocator)
	data.aliases = Alias_Registry{aliases = make(map[string]string, allocator), allocator = allocator}
	data.faces = face_registry_make(nil, allocator)
	// In-place init: the root group's base borrows &data.highlighters.group.
	highlighters_init_child(&data.highlighters, nil, allocator)
	b.scope.data = data
	return b
}

// buffer_destroy frees every string, history node, change, value and
// manager owned by b, then b itself. Do not use b afterwards.
buffer_destroy :: proc(b: ^Buffer) {
	alloc := b.allocator
	for l in b.lines {
		delete(l, alloc)
	}
	delete(b.lines)
	for &node in b.history {
		for m in node.undo_group {
			delete(m.content, alloc)
		}
		delete(node.undo_group)
	}
	delete(b.history)
	for m in b.current_undo_group {
		delete(m.content, alloc)
	}
	delete(b.current_undo_group)
	delete(b.changes)
	delete(b.filename, alloc)
	delete(b.display_name, alloc)
	// Fifo-aware: an open fifo's watcher must unregister and its fd
	// must close (~FifoWatcher), not just free the value payload.
	buffer_utils_clear_values(b)
	delete(b.values)

	data := b.scope.data
	// Undo buffer_manager_create's reparenting: drop the parent-link
	// watcher so the global scope keeps no dangling pointer to this
	// buffer's option manager. Other managers' parents are plain
	// pointers with no parent-side state.
	if data.options.parent != nil {
		option_manager_unregister_watcher(
			data.options.parent,
			Option_Watcher{data = &data.options, on_option_changed = option_manager_watcher_callback},
		)
		data.options.parent = nil
	}
	// Local options are populated by set paths (file attributes,
	// :set); destroy each (the desc stays registry-owned).
	for _, opt in data.options.options {
		option_manager_option_destroy(opt)
	}
	delete(data.options.options)
	delete(data.options.watchers)
	delete(data.aliases.aliases)
	for &list in data.hooks.hooks {
		delete(list)
	}
	delete(data.hooks.running_hooks)
	delete(data.hooks.hooks_trash)
	keymap_manager_destroy(&data.keymaps)
	face_registry_destroy(&data.faces)
	highlighters_destroy(&data.highlighters)
	free(data, alloc)
	free(b, alloc)
}

// buffer_flags returns the buffer flags (port of the const overload).
buffer_flags :: proc(b: ^Buffer) -> Buffer_Flags {
	return b.flags
}

// buffer_set_flags replaces the buffer flags (port of the mutable overload).
buffer_set_flags :: proc(b: ^Buffer, flags: Buffer_Flags) {
	b.flags = flags
}

// buffer_check_read_only ports throw_if_read_only: Read_Only when the
// buffer cannot be modified, None otherwise.
buffer_check_read_only :: proc(b: ^Buffer) -> Buffer_Error {
	if .Read_Only in b.flags {
		return .Read_Only
	}
	return .None
}

// buffer_name returns the filename for File buffers, the display name
// otherwise (port of Buffer::name).
buffer_name :: proc(b: ^Buffer) -> string {
	if .File in b.flags {
		return b.filename
	}
	return b.display_name
}

// buffer_filename returns the buffer filename.
buffer_filename :: proc(b: ^Buffer) -> string {
	return b.filename
}

// buffer_display_name returns the buffer display name.
buffer_display_name :: proc(b: ^Buffer) -> string {
	return b.display_name
}

// buffer_line_count returns the number of lines.
buffer_line_count :: proc(b: ^Buffer) -> Units_LineCount {
	return Units_LineCount(len(b.lines))
}

// buffer_timestamp returns the change count (port of Buffer::timestamp).
buffer_timestamp :: proc(b: ^Buffer) -> int {
	return len(b.changes)
}

// buffer_changes_since views the changes recorded after timestamp.
buffer_changes_since :: proc(b: ^Buffer, timestamp: int) -> []Buffer_Change {
	if timestamp < len(b.changes) {
		return b.changes[timestamp:]
	}
	return {}
}

// buffer_history views the undo-tree nodes.
buffer_history :: proc(b: ^Buffer) -> []Buffer_History_Node {
	return b.history[:]
}

// buffer_current_undo_group views the uncommitted undo group.
buffer_current_undo_group :: proc(b: ^Buffer) -> []Buffer_Modification {
	return b.current_undo_group[:]
}

// buffer_current_history_id returns the current undo-tree node id.
buffer_current_history_id :: proc(b: ^Buffer) -> Buffer_History_Id {
	return b.history_id
}

// buffer_next_history_id returns the id the next commit will use.
buffer_next_history_id :: proc(b: ^Buffer) -> Buffer_History_Id {
	return Buffer_History_Id(len(b.history))
}

// buffer_values returns the buffer value map (port of Buffer::values).
buffer_values :: proc(b: ^Buffer) -> ^Value_Map {
	return &b.values
}

// buffer_back_coord returns the coord of the last byte (the final '\n').
buffer_back_coord :: proc(b: ^Buffer) -> Coord_Buffer {
	return {buffer_line_count(b) - 1, Units_ByteCount(len(b.lines[len(b.lines) - 1]) - 1)}
}

// buffer_end_coord returns the past-the-end coord {line_count, 0}.
buffer_end_coord :: proc(b: ^Buffer) -> Coord_Buffer {
	return {buffer_line_count(b), 0}
}

// buffer_is_valid reports whether c addresses a byte or is the end coord.
buffer_is_valid :: proc(b: ^Buffer, c: Coord_Buffer) -> bool {
	return (c.line >= 0 && c.column >= 0) &&
		((c.line < buffer_line_count(b) && c.column < Units_ByteCount(len(b.lines[int(c.line)]))) ||
			(c.line == buffer_line_count(b) && c.column == 0))
}

// buffer_is_end reports whether c is at or past the end coord.
buffer_is_end :: proc(b: ^Buffer, c: Coord_Buffer) -> bool {
	return coord_compare(c, buffer_end_coord(b)) >= 0
}

// buffer_byte_at returns the byte at c.
buffer_byte_at :: proc(b: ^Buffer, c: Coord_Buffer) -> byte {
	assert(c.line < buffer_line_count(b) && c.column < Units_ByteCount(len(b.lines[int(c.line)])))
	return b.lines[int(c.line)][int(c.column)]
}

// buffer_next returns the coord one byte after coord.
buffer_next :: proc(b: ^Buffer, coord: Coord_Buffer) -> Coord_Buffer {
	if coord.column < Units_ByteCount(len(b.lines[int(coord.line)])) - 1 {
		return {coord.line, coord.column + 1}
	}
	return {coord.line + 1, 0}
}

// buffer_prev returns the coord one byte before coord.
buffer_prev :: proc(b: ^Buffer, coord: Coord_Buffer) -> Coord_Buffer {
	if coord.column == 0 {
		return {coord.line - 1, Units_ByteCount(len(b.lines[int(coord.line) - 1]) - 1)}
	}
	return {coord.line, coord.column - 1}
}

// buffer_char_next returns the coord one codepoint after coord.
buffer_char_next :: proc(b: ^Buffer, coord: Coord_Buffer) -> Coord_Buffer {
	if coord.column < Units_ByteCount(len(b.lines[int(coord.line)])) - 1 {
		line := b.lines[int(coord.line)]
		column := coord.column + Units_ByteCount(utf8_codepoint_size_byte(line[int(coord.column)]))
		if column >= Units_ByteCount(len(line)) { 	// Handle invalid utf-8
			return {coord.line + 1, 0}
		}
		return {coord.line, column}
	}
	return {coord.line + 1, 0}
}

// buffer_char_prev returns the coord one codepoint before coord.
buffer_char_prev :: proc(b: ^Buffer, coord: Coord_Buffer) -> Coord_Buffer {
	assert(buffer_is_valid(b, coord))
	if coord.column == 0 {
		return {coord.line - 1, Units_ByteCount(len(b.lines[int(coord.line) - 1]) - 1)}
	}
	line := b.lines[int(coord.line)]
	return {coord.line, Units_ByteCount(utf8_character_start(line, int(coord.column) - 1))}
}

// buffer_advance_lines moves coord by count bytes over a line array,
// clamping at {0,0} and at the past-the-end line (port of the static
// Buffer::advance).
buffer_advance_lines :: proc(lines: []string, coord: Coord_Buffer, count: Units_ByteCount) -> Coord_Buffer {
	if count > 0 {
		line := coord.line
		c := count + coord.column
		for c >= Units_ByteCount(len(lines[int(line)])) {
			c -= Units_ByteCount(len(lines[int(line)]))
			line += 1
			if int(line) == len(lines) {
				return {line, 0}
			}
		}
		return {line, c}
	} else if count < 0 {
		line := coord.line
		c := count + coord.column
		for c < 0 {
			line -= 1
			if line < 0 {
				return {0, 0}
			}
			c += Units_ByteCount(len(lines[int(line)]))
		}
		return {line, c}
	}
	return coord
}

// buffer_advance moves coord by count bytes within the buffer.
buffer_advance :: proc(b: ^Buffer, coord: Coord_Buffer, count: Units_ByteCount) -> Coord_Buffer {
	return buffer_advance_lines(b.lines[:], coord, count)
}

// buffer_distance_lines returns the byte distance from begin to end over
// a line array (negative when begin follows end; port of the static
// Buffer::distance).
buffer_distance_lines :: proc(lines: []string, begin, end: Coord_Buffer) -> Units_ByteCount {
	if coord_compare(begin, end) > 0 {
		return -buffer_distance_lines(lines, end, begin)
	}
	if begin.line == end.line {
		return end.column - begin.column
	}
	res := Units_ByteCount(len(lines[int(begin.line)])) - begin.column
	l := begin.line + 1
	for l < end.line {
		res += Units_ByteCount(len(lines[int(l)]))
		l += 1
	}
	res += end.column
	return res
}

// buffer_distance returns the byte distance from begin to end.
buffer_distance :: proc(b: ^Buffer, begin, end: Coord_Buffer) -> Units_ByteCount {
	return buffer_distance_lines(b.lines[:], begin, end)
}

// buffer_clamp returns the nearest valid coord to coord.
buffer_clamp :: proc(b: ^Buffer, coord: Coord_Buffer) -> Coord_Buffer {
	c := coord
	if coord_compare(c, buffer_back_coord(b)) > 0 {
		c = buffer_back_coord(b)
	}
	assert(c.line >= 0 && c.line < buffer_line_count(b))
	max_col := max(Units_ByteCount(0), Units_ByteCount(len(b.lines[int(c.line)])) - 1)
	c.column = utils_clamp(c.column, Units_ByteCount(0), max_col)
	return c
}

// buffer_offset_coord_by_char moves coord by offset codepoints, clamped
// to [begin, back_coord] like the C++ utf8::advance call. The column
// parameter is unused in C++ too. Defensive: coords already past
// back_coord stay instead of running off the end (C++ UB there).
buffer_offset_coord_by_char :: proc(b: ^Buffer, coord: Coord_Buffer, offset: Units_CharCount, column: Units_ColumnCount) -> Coord_Buffer {
	_ = column
	res := coord
	back := buffer_back_coord(b)
	if offset < 0 {
		i := Units_CharCount(0)
		for i > offset {
			if res.line == 0 && res.column == 0 {
				break
			}
			res = buffer_char_prev(b, res)
			i -= 1
		}
	} else {
		i := Units_CharCount(0)
		for i < offset {
			if coord_compare(res, back) >= 0 {
				break
			}
			res = buffer_char_next(b, res)
			i += 1
		}
	}
	return res
}

// buffer_offset_coord_by_line moves coord vertically by offset lines,
// keeping the target column (port of the BufferCoordAndTarget overload).
// Calls the unmerged buffer_utils module: panics until it merges.
buffer_offset_coord_by_line :: proc(b: ^Buffer, coord: Coord_Buffer_And_Target, offset: Units_LineCount, tabstop: Units_ColumnCount) -> Coord_Buffer_And_Target {
	column := coord.target if coord.target != -1 else buffer_utils_get_column(b, tabstop, coord.coord)
	avoid_eol := coord.target < selection_MAX_COLUMN
	line := utils_clamp(coord.line + offset, Units_LineCount(0), buffer_line_count(b) - 1)
	max_byte := Units_ByteCount(len(b.lines[int(line)])) - 1
	max_col := buffer_utils_get_column(b, tabstop, {line, max_byte})
	final_column := max(Units_ColumnCount(0), min(column, max_col - (1 if avoid_eol else 0)))
	return coord_buffer_and_target(
		{line, min(max_byte, buffer_utils_get_byte_to_column(b, tabstop, {line, final_column}))},
		column,
	)
}

// buffer_string returns the owned text in [begin, end). Caller frees it.
buffer_string :: proc(b: ^Buffer, begin, end: Coord_Buffer, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	last_line := min(int(end.line), len(b.lines) - 1)
	for line := int(begin.line); line <= last_line; line += 1 {
		l := b.lines[line]
		start := 0
		if line == int(begin.line) {
			start = int(begin.column)
		}
		count := len(l) - start
		if line == int(end.line) {
			count = int(end.column) - start
		}
		strings.write_string(&sb, l[start:start + count])
	}
	return strings.to_string(sb)
}

// buffer_substr views the single-line text in [begin, end).
buffer_substr :: proc(b: ^Buffer, begin, end: Coord_Buffer) -> string {
	assert(begin.line == end.line)
	l := b.lines[int(begin.line)]
	return l[int(begin.column):int(end.column)]
}

// buffer_line views the line storage (ports both operator[] and
// line_storage: strings are values in Odin, so they coincide).
buffer_line :: proc(b: ^Buffer, line: Units_LineCount) -> string {
	return b.lines[int(line)]
}

// buffer_iterator_make_lines builds an iterator over a line array at coord
// (port of the raw-lines BufferIterator constructor).
buffer_iterator_make_lines :: proc(lines: []string, line_count: Units_LineCount, coord: Coord_Buffer) -> Buffer_Iterator {
	line := ""
	if coord.line < line_count {
		line = lines[int(coord.line)]
	}
	return Buffer_Iterator{lines = lines, line = line, line_count = line_count, coord = coord}
}

// buffer_iterator_make builds an iterator over the buffer at coord.
buffer_iterator_make :: proc(b: ^Buffer, coord: Coord_Buffer) -> Buffer_Iterator {
	assert(buffer_is_valid(b, coord))
	return buffer_iterator_make_lines(b.lines[:], buffer_line_count(b), coord)
}

// buffer_iterator_at returns an iterator at coord (port of iterator_at).
buffer_iterator_at :: proc(b: ^Buffer, coord: Coord_Buffer) -> Buffer_Iterator {
	assert(buffer_is_valid(b, coord))
	return buffer_iterator_make(b, coord)
}

// buffer_begin returns an iterator at {0, 0}.
buffer_begin :: proc(b: ^Buffer) -> Buffer_Iterator {
	return buffer_iterator_make(b, {0, 0})
}

// buffer_end returns an iterator at the end coord.
buffer_end :: proc(b: ^Buffer) -> Buffer_Iterator {
	return buffer_iterator_make(b, buffer_end_coord(b))
}

// buffer_iterator_is_valid reports whether the iterator is non-empty
// (port of the explicit operator bool).
buffer_iterator_is_valid :: proc(it: Buffer_Iterator) -> bool {
	return it.lines != nil
}

// buffer_iterator_equal compares two iterator positions.
buffer_iterator_equal :: proc(a, b: Buffer_Iterator) -> bool {
	return a.coord == b.coord
}

// buffer_iterator_compare orders two iterators (-1, 0, 1; port of <=>.
buffer_iterator_compare :: proc(a, b: Buffer_Iterator) -> int {
	return coord_compare(a.coord, b.coord)
}

// buffer_iterator_at_coord reports whether the iterator sits at coord.
buffer_iterator_at_coord :: proc(it: Buffer_Iterator, coord: Coord_Buffer) -> bool {
	return it.coord == coord
}

// buffer_iterator_deref returns the byte at the iterator (port of *it).
buffer_iterator_deref :: proc(it: Buffer_Iterator) -> byte {
	return it.line[int(it.coord.column)]
}

// buffer_iterator_index returns the byte n bytes past the iterator.
buffer_iterator_index :: proc(it: Buffer_Iterator, n: int) -> byte {
	coord := buffer_advance_lines(it.lines, it.coord, Units_ByteCount(n))
	return it.lines[int(coord.line)][int(coord.column)]
}

// buffer_iterator_distance returns a minus b in bytes. Deviation: C++
// returns size_t (wrapping when a precedes b); the signed value keeps
// the magnitude for ordered pairs and stays defined otherwise.
buffer_iterator_distance :: proc(a, b: Buffer_Iterator) -> int {
	return int(buffer_distance_lines(a.lines, b.coord, a.coord))
}

// buffer_iterator_coord returns the iterator position.
buffer_iterator_coord :: proc(it: Buffer_Iterator) -> Coord_Buffer {
	return it.coord
}

// buffer_iterator_add returns the iterator moved forward n bytes.
buffer_iterator_add :: proc(it: Buffer_Iterator, n: Units_ByteCount) -> Buffer_Iterator {
	assert(buffer_iterator_is_valid(it))
	return buffer_iterator_make_lines(it.lines, it.line_count, buffer_advance_lines(it.lines, it.coord, n))
}

// buffer_iterator_sub returns the iterator moved back n bytes.
buffer_iterator_sub :: proc(it: Buffer_Iterator, n: Units_ByteCount) -> Buffer_Iterator {
	return buffer_iterator_make_lines(it.lines, it.line_count, buffer_advance_lines(it.lines, it.coord, -n))
}

// buffer_iterator_advance moves the iterator forward n bytes in place
// (port of +=). Deviation: clamps the cached line at the end coord
// instead of reading past the array (C++ UB there).
buffer_iterator_advance :: proc(it: ^Buffer_Iterator, n: Units_ByteCount) {
	it.coord = buffer_advance_lines(it.lines, it.coord, n)
	if it.coord.line < it.line_count {
		it.line = it.lines[int(it.coord.line)]
	} else {
		it.line = ""
	}
}

// buffer_iterator_recede moves the iterator back n bytes in place (port
// of -=), with the same end-guard as buffer_iterator_advance.
buffer_iterator_recede :: proc(it: ^Buffer_Iterator, n: Units_ByteCount) {
	it.coord = buffer_advance_lines(it.lines, it.coord, -n)
	if it.coord.line < it.line_count {
		it.line = it.lines[int(it.coord.line)]
	} else {
		it.line = ""
	}
}

// buffer_iterator_next advances one byte in place (port of prefix ++).
buffer_iterator_next :: proc(it: ^Buffer_Iterator) {
	it.coord.column += 1
	if it.coord.column == Units_ByteCount(len(it.line)) {
		it.coord.line += 1
		if int(it.coord.line) < int(it.line_count) {
			it.line = it.lines[int(it.coord.line)]
		} else {
			it.line = ""
		}
		it.coord.column = 0
	}
}

// buffer_iterator_prev moves back one byte in place (port of prefix --).
buffer_iterator_prev :: proc(it: ^Buffer_Iterator) {
	if it.coord.column == 0 {
		it.coord.line -= 1
		it.line = it.lines[int(it.coord.line)]
		it.coord.column = Units_ByteCount(len(it.line)) - 1
	} else {
		it.coord.column -= 1
	}
}

// buffer_iterator_next_post advances one byte, returning the old position
// (port of postfix ++).
buffer_iterator_next_post :: proc(it: ^Buffer_Iterator) -> Buffer_Iterator {
	save := it^
	buffer_iterator_next(it)
	return save
}

// buffer_iterator_prev_post moves back one byte, returning the old
// position (port of postfix --).
buffer_iterator_prev_post :: proc(it: ^Buffer_Iterator) -> Buffer_Iterator {
	save := it^
	buffer_iterator_prev(it)
	return save
}

// buffer_do_insert splices content at pos without recording undo (port
// of the private do_insert). Old line strings are freed; new lines are
// owned by the buffer.
@(private = "file")
buffer_do_insert :: proc(b: ^Buffer, pos: Coord_Buffer, content: string) -> Buffer_Range {
	assert(buffer_is_valid(b, pos))
	if len(content) == 0 {
		return {pos, pos}
	}

	at_end := buffer_is_end(b, pos)
	append_lines := at_end && (len(b.lines) == 0 || b.lines[len(b.lines) - 1][len(b.lines[len(b.lines) - 1]) - 1] == '\n')

	// C++ reads m_lines[pos.line] unconditionally here, which is out of
	// bounds exactly when at_end; guard it (same values otherwise).
	prefix, suffix := "", ""
	if int(pos.line) < len(b.lines) {
		l := b.lines[int(pos.line)]
		if !append_lines {
			prefix = l[:int(pos.column)]
		}
		if !at_end {
			suffix = l[int(pos.column):]
		}
	}

	new_lines := make([dynamic]string, 0, context.temp_allocator)
	start := 0
	for i in 0 ..< len(content) {
		if content[i] == '\n' {
			line := content[start:i + 1]
			if start == 0 {
				append(&new_lines, strings.concatenate({prefix, line}, b.allocator))
			} else {
				append(&new_lines, strings.clone(line, b.allocator))
			}
			start = i + 1
		}
	}
	if start == 0 {
		append(&new_lines, strings.concatenate({prefix, content, suffix}, b.allocator))
	} else if start != len(content) || len(suffix) != 0 {
		append(&new_lines, strings.concatenate({content[start:], suffix}, b.allocator))
	}

	skip := 0
	if !append_lines {
		// Replace the first line with the new first line.
		delete(b.lines[int(pos.line)], b.allocator)
		b.lines[int(pos.line)] = new_lines[0]
		skip = 1
	}
	if skip < len(new_lines) {
		idx := min(int(pos.line) + skip, len(b.lines))
		merged := make(Buffer_Lines, 0, len(b.lines) + len(new_lines) - skip, b.allocator)
		append(&merged, ..b.lines[:idx])
		append(&merged, ..new_lines[skip:])
		append(&merged, ..b.lines[idx:])
		delete(b.lines)
		b.lines = merged
	}

	last_line := int(pos.line) + len(new_lines) - 1
	end_coord := buffer_end_coord(b)
	if !at_end {
		end_coord = Coord_Buffer{Coord_Line(last_line), Units_ByteCount(len(b.lines[last_line]) - len(suffix))}
	}
	append(&b.changes, Buffer_Change{type = .Insert, begin = pos, end = end_coord})
	return {pos, end_coord}
}

// buffer_do_erase removes [begin, end) without recording undo (port of
// the private do_erase). Discarded line strings are freed.
@(private = "file")
buffer_do_erase :: proc(b: ^Buffer, begin, end: Coord_Buffer) -> Coord_Buffer {
	if begin == end {
		return begin
	}
	assert(buffer_is_valid(b, begin))
	assert(buffer_is_valid(b, end))

	prefix := b.lines[int(begin.line)][:int(begin.column)]
	suffix := ""
	if int(end.line) < len(b.lines) {
		suffix = b.lines[int(end.line)][int(end.column):]
	}

	new_line := ""
	has_new_line := len(prefix) != 0 || len(suffix) != 0
	if has_new_line {
		new_line = strings.concatenate({prefix, suffix}, b.allocator)
	}

	bi, ei := int(begin.line), int(end.line)
	// A joined line needs a surviving line slot: end at end_coord
	// implies an empty prefix (public erase normalizes it, undo
	// replays end-anchored content only from column 0).
	assert(!has_new_line || ei < len(b.lines))
	for i in bi ..< ei {
		delete(b.lines[i], b.allocator)
	}
	n := ei - bi
	for src := ei; src < len(b.lines); src += 1 {
		b.lines[src - n] = b.lines[src]
	}
	resize(&b.lines, len(b.lines) - n)

	append(&b.changes, Buffer_Change{type = .Erase, begin = begin, end = end})
	if has_new_line {
		delete(b.lines[bi], b.allocator)
		b.lines[bi] = new_line
	}
	return begin
}

// buffer_modification_inverse returns the modification undoing m.
buffer_modification_inverse :: proc(m: Buffer_Modification) -> Buffer_Modification {
	type := Buffer_Modification_Type.Erase if m.type == .Insert else Buffer_Modification_Type.Insert
	return {type = type, coord = m.coord, content = m.content}
}

// buffer_apply_modification performs one recorded modification (port of
// the private apply_modification).
@(private = "file")
buffer_apply_modification :: proc(b: ^Buffer, m: Buffer_Modification) {
	assert(buffer_is_valid(b, m.coord))
	switch m.type {
	case .Insert:
		buffer_do_insert(b, m.coord, m.content)
	case .Erase:
		end := buffer_advance(b, m.coord, Units_ByteCount(len(m.content)))
		cur := buffer_string(b, m.coord, end, context.temp_allocator)
		assert(cur == m.content)
		buffer_do_erase(b, m.coord, end)
	}
}

// buffer_insert inserts content at pos, recording undo. Inserts at the
// end gain a trailing newline when missing, as in C++.
buffer_insert :: proc(b: ^Buffer, pos: Coord_Buffer, content: string) -> (Buffer_Range, Buffer_Error) {
	if err := buffer_check_read_only(b); err != .None {
		return {}, err
	}
	assert(buffer_is_valid(b, pos))
	if len(content) == 0 {
		return {pos, pos}, .None
	}

	needs_newline := buffer_is_end(b, pos) && content[len(content) - 1] != '\n'
	if .No_Undo in b.flags {
		real_content := content
		if needs_newline {
			real_content = strings.concatenate({content, "\n"}, context.temp_allocator)
		}
		return buffer_do_insert(b, pos, real_content), .None
	}
	real_content := strings.clone(content, b.allocator)
	if needs_newline {
		delete(real_content, b.allocator)
		real_content = strings.concatenate({content, "\n"}, b.allocator)
	}
	append(&b.current_undo_group, Buffer_Modification{type = .Insert, coord = pos, content = real_content})
	return buffer_do_insert(b, pos, real_content), .None
}

// buffer_erase removes [begin, end), recording undo. Erasing to the end
// keeps the final newline unless begin starts a non-first line.
buffer_erase :: proc(b: ^Buffer, begin, end: Coord_Buffer) -> (Coord_Buffer, Buffer_Error) {
	if err := buffer_check_read_only(b); err != .None {
		return begin, err
	}
	assert(buffer_is_valid(b, begin) && buffer_is_valid(b, end))
	e := end
	if buffer_is_end(b, e) {
		e = buffer_prev(b, e) if begin.column != 0 || begin == Coord_Buffer{0, 0} else buffer_end_coord(b)
	}
	if coord_compare(begin, e) >= 0 {
		return begin, .None
	}
	if .No_Undo not_in b.flags {
		append(&b.current_undo_group, Buffer_Modification{type = .Erase, coord = begin, content = buffer_string(b, begin, e, b.allocator)})
	}
	return buffer_do_erase(b, begin, e), .None
}

// buffer_replace swaps [begin, end) for content, recording undo. It is a
// no-op when the range already holds content.
buffer_replace :: proc(b: ^Buffer, begin, end: Coord_Buffer, content: string) -> (Buffer_Range, Buffer_Error) {
	if err := buffer_check_read_only(b); err != .None {
		return {}, err
	}
	cur := buffer_string(b, begin, end, context.temp_allocator)
	if cur == content {
		return {begin, end}, .None
	}
	if buffer_is_end(b, end) && len(content) != 0 && content[len(content) - 1] == '\n' {
		erased, _ := buffer_erase(b, begin, buffer_back_coord(b))
		inserted, _ := buffer_insert(b, erased, content[:len(content) - 1])
		return {inserted.begin, buffer_end_coord(b)}, .None
	}
	erased, _ := buffer_erase(b, begin, end)
	return buffer_insert(b, erased, content)
}

// buffer_commit_undo_group closes the current undo group into a new
// history node (no-op when empty or NoUndo).
buffer_commit_undo_group :: proc(b: ^Buffer) {
	if .No_Undo in b.flags {
		return
	}
	if len(b.current_undo_group) == 0 {
		return
	}
	id := buffer_next_history_id(b)
	append(
		&b.history,
		Buffer_History_Node{parent = b.history_id, redo_child = buffer_HISTORY_INVALID, committed = clock_now()},
	)
	b.history[len(b.history) - 1].undo_group = b.current_undo_group
	b.current_undo_group = make([dynamic]Buffer_Modification, 0, b.allocator)
	b.history[int(b.history_id)].redo_child = id
	b.history_id = id
}

// buffer_undo reverts count undo groups.
buffer_undo :: proc(b: ^Buffer, count := 1) -> (bool, Buffer_Error) {
	if err := buffer_check_read_only(b); err != .None {
		return false, err
	}
	buffer_commit_undo_group(b)
	if b.history[int(b.history_id)].parent == buffer_HISTORY_INVALID {
		return false, .None
	}
	remaining := count
	for remaining != 0 && b.history[int(b.history_id)].parent != buffer_HISTORY_INVALID {
		remaining -= 1
		node := b.history[int(b.history_id)]
		for i := len(node.undo_group) - 1; i >= 0; i -= 1 {
			buffer_apply_modification(b, buffer_modification_inverse(node.undo_group[i]))
		}
		b.history_id = b.history[int(b.history_id)].parent
	}
	return true, .None
}

// buffer_redo reapplies count undone groups. It fails when there is
// nothing to redo or an uncommitted group is open.
buffer_redo :: proc(b: ^Buffer, count := 1) -> (bool, Buffer_Error) {
	if err := buffer_check_read_only(b); err != .None {
		return false, err
	}
	if b.history[int(b.history_id)].redo_child == buffer_HISTORY_INVALID || len(b.current_undo_group) != 0 {
		return false, .None
	}
	remaining := count
	for remaining != 0 && b.history[int(b.history_id)].redo_child != buffer_HISTORY_INVALID {
		remaining -= 1
		b.history_id = b.history[int(b.history_id)].redo_child
		for m in b.history[int(b.history_id)].undo_group {
			buffer_apply_modification(b, m)
		}
	}
	return true, .None
}

// buffer_history_lca finds the lowest common ancestor of two history ids.
@(private = "file")
buffer_history_lca :: proc(b: ^Buffer, a, c: Buffer_History_Id) -> Buffer_History_Id {
	depth_of :: proc(b: ^Buffer, id: Buffer_History_Id) -> int {
		depth := 0
		cur := id
		for b.history[int(cur)].parent != buffer_HISTORY_INVALID {
			cur = b.history[int(cur)].parent
			depth += 1
		}
		return depth
	}
	x, y := a, c
	dx, dy := depth_of(b, x), depth_of(b, y)
	for dx > dy {
		x = b.history[int(x)].parent
		dx -= 1
	}
	for dy > dx {
		y = b.history[int(y)].parent
		dy -= 1
	}
	for x != y {
		x = b.history[int(x)].parent
		y = b.history[int(y)].parent
	}
	assert(x == y && x != buffer_HISTORY_INVALID)
	return x
}

// buffer_apply_from_parent replays the history path parent..id,
// rewiring redo_child links along the way (port of move_to's lambda).
@(private = "file")
buffer_apply_from_parent :: proc(b: ^Buffer, parent, id: Buffer_History_Id) {
	if id == parent {
		return
	}
	node := b.history[int(id)]
	buffer_apply_from_parent(b, parent, node.parent)
	b.history[int(node.parent)].redo_child = id
	for m in b.history[int(id)].undo_group {
		buffer_apply_modification(b, m)
	}
}

// buffer_move_to jumps the buffer state to history id, rewiring the
// redo path. Unknown ids fail without touching read-only state.
buffer_move_to :: proc(b: ^Buffer, id: Buffer_History_Id) -> (bool, Buffer_Error) {
	if int(id) >= len(b.history) {
		return false, .None
	}
	if err := buffer_check_read_only(b); err != .None {
		return false, err
	}
	buffer_commit_undo_group(b)
	parent := buffer_history_lca(b, b.history_id, id)
	cur := b.history_id
	for cur != parent {
		node := b.history[int(cur)]
		for i := len(node.undo_group) - 1; i >= 0; i -= 1 {
			buffer_apply_modification(b, buffer_modification_inverse(node.undo_group[i]))
		}
		cur = b.history[int(cur)].parent
	}
	buffer_apply_from_parent(b, parent, id)
	b.history_id = id
	return true, .None
}

// buffer_last_modification_coord returns the coord of the latest
// committed modification, or false at history First.
buffer_last_modification_coord :: proc(b: ^Buffer) -> (Coord_Buffer, bool) {
	if b.history_id == buffer_HISTORY_FIRST {
		return {}, false
	}
	group := b.history[int(b.history_id)].undo_group
	return group[len(group) - 1].coord, true
}

// buffer_is_modified reports whether a File buffer differs from its last
// saved state.
buffer_is_modified :: proc(b: ^Buffer) -> bool {
	return .File in b.flags &&
		(b.history_id != b.last_save_history_id || len(b.current_undo_group) != 0)
}

// buffer_notify_saved records that the buffer was saved with status.
buffer_notify_saved :: proc(b: ^Buffer, status: File_Fs_Status) {
	if len(b.current_undo_group) != 0 {
		buffer_commit_undo_group(b)
	}
	b.flags = b.flags - Buffer_Flags{.New}
	b.last_save_history_id = b.history_id
	b.fs_status = status
}

// buffer_set_fs_status replaces the saved file status of a File buffer.
buffer_set_fs_status :: proc(b: ^Buffer, status: File_Fs_Status) {
	assert(.File in b.flags)
	b.fs_status = status
}

// buffer_fs_status returns the saved file status of a File buffer.
buffer_fs_status :: proc(b: ^Buffer) -> File_Fs_Status {
	assert(.File in b.flags)
	return b.fs_status
}

// buffer_set_name renames the buffer unless another buffer already owns
// the name. Calls the unmerged buffer_manager: panics until it merges.
buffer_set_name :: proc(b: ^Buffer, name: string) -> bool {
	other := buffer_manager_get_buffer_ifp(name)
	if other == nil || other == b {
		if .File in b.flags {
			// getcwd failure falls back to the raw name (see make).
			real, real_err := file_real_path(name, b.allocator)
			delete(b.filename, b.allocator)
			b.filename = real if real_err == .None else strings.clone(name, b.allocator)
			delete(b.display_name, b.allocator)
			compact, compact_err := file_compact_path(b.filename, b.allocator)
			b.display_name = compact if compact_err == .None else strings.clone(b.filename, b.allocator)
			if !file_exists(b.filename) {
				b.flags = b.flags + Buffer_Flags{.New}
				b.last_save_history_id = buffer_HISTORY_INVALID
			}
		} else {
			delete(b.filename, b.allocator)
			b.filename = ""
			delete(b.display_name, b.allocator)
			b.display_name = strings.clone(name, b.allocator)
		}
		return true
	}
	return false
}

// buffer_update_display_name refreshes the display name of a File buffer.
buffer_update_display_name :: proc(b: ^Buffer) {
	if .File not_in b.flags {
		return
	}
	compact, err := file_compact_path(b.filename, b.allocator)
	if err != .None {
		return
	}
	delete(b.display_name, b.allocator)
	b.display_name = compact
}

// Buffer_Diff_Op mirrors Kakoune's DiffOp for one coalesced line run.
@(private = "file")
Buffer_Diff_Op :: enum {
	Keep,
	Add,
	Remove,
}

// Buffer_Diff is one coalesced run: op repeated len times.
@(private = "file")
Buffer_Diff :: struct {
	op:  Buffer_Diff_Op,
	len: int,
}

// Buffer_Diff_Snake_Op mirrors Kakoune's Snake::Op.
@(private = "file")
Buffer_Diff_Snake_Op :: enum {
	Add,
	Del,
	Rev_Add,
	Rev_Del,
}

// Buffer_Diff_Snake is an edit plus the diagonal from (x, y) to (u, v).
@(private = "file")
Buffer_Diff_Snake :: struct {
	x, y, u, v: int,
	op:         Buffer_Diff_Snake_Op,
}

// Buffer_Diff_State threads the output plus the pending coalesced run
// through the recursion (Odin has no capturing closures).
@(private = "file")
Buffer_Diff_State :: struct {
	diffs: ^[dynamic]Buffer_Diff,
	last:  Buffer_Diff,
}

// buffer_diff_emit feeds one run into the coalescer.
@(private = "file")
buffer_diff_emit :: proc(st: ^Buffer_Diff_State, op: Buffer_Diff_Op, len: int) {
	if st.last.op == op {
		st.last.len += len
	} else {
		if st.last.len != 0 {
			append(st.diffs, st.last)
		}
		st.last = Buffer_Diff{op, len}
	}
}

// buffer_diff_end_snake ports find_end_snake_of_further_reaching_dpath
// over line arrays (lines compare with ==, as in Buffer::reload).
@(private = "file")
buffer_diff_end_snake :: proc(a, b: []string, v: []int, v_off, d, k: int, forward: bool) -> Buffer_Diff_Snake {
	n := len(a)
	m := len(b)

	add := k == -d || (k != d && v[k - 1 + v_off] < v[k + 1 + v_off])

	x := v[k + 1 + v_off] if add else v[k - 1 + v_off] + 1
	y := x - k

	u, w := x, y
	for u < n && w < m {
		ca := a[u] if forward else a[n - 1 - u]
		cb := b[w] if forward else b[m - 1 - w]
		if ca != cb {
			break
		}
		u += 1
		w += 1
	}

	return Buffer_Diff_Snake{x, y, u, w, .Add if add else .Del}
}

// buffer_diff_middle_snake ports find_middle_snake over line arrays.
@(private = "file")
buffer_diff_middle_snake :: proc(a, b: []string, v1, v2: []int, v_off, cost_limit: int) -> Buffer_Diff_Snake {
	n := len(a)
	m := len(b)
	delta := n - m
	v1[1 + v_off] = 0
	v2[1 + v_off] = 0

	max_d := min((m + n + 1) / 2 + 1, cost_limit)
	for d in 0 ..< max_d {
		for k1 := -d; k1 <= d; k1 += 2 {
			p := buffer_diff_end_snake(a, b, v1, v_off, d, k1, true)
			v1[k1 + v_off] = p.u

			k2 := -(k1 - delta)
			if delta % 2 != 0 && -(d - 1) <= k2 && k2 <= (d - 1) && v1[k1 + v_off] + v2[k2 + v_off] >= n {
				return p
			}
		}

		for k2 := -d; k2 <= d; k2 += 2 {
			p := buffer_diff_end_snake(a, b, v2, v_off, d, k2, false)
			v2[k2 + v_off] = p.u

			k1 := -(k2 - delta)
			if delta % 2 == 0 && -d <= k1 && k1 <= d && v1[k1 + v_off] + v2[k2 + v_off] >= n {
				op := Buffer_Diff_Snake_Op.Rev_Add if p.op == .Add else Buffer_Diff_Snake_Op.Rev_Del
				return Buffer_Diff_Snake{n - p.u, m - p.v, n - p.x, m - p.y, op}
			}
		}
	}

	best := Buffer_Diff_Snake{}
	for k1 := -max_d; k1 <= max_d; k1 += 2 {
		p := buffer_diff_end_snake(a, b, v1, v_off, max_d, k1, true)
		v1[k1 + v_off] = p.u
		if delta % 2 != 0 && p.u <= n && p.v <= m && p.u + p.v >= best.u + best.v {
			best = p
		}
	}
	for k2 := -max_d; k2 <= max_d; k2 += 2 {
		p := buffer_diff_end_snake(a, b, v2, v_off, max_d, k2, false)
		v2[k2 + v_off] = p.u
		if delta % 2 == 0 && p.u <= n && p.v <= m && p.u + p.v >= best.u + best.v {
			op := Buffer_Diff_Snake_Op.Rev_Add if p.op == .Add else Buffer_Diff_Snake_Op.Rev_Del
			best = Buffer_Diff_Snake{p.x, p.y, p.u, p.v, op}
		}
	}

	if best.op == .Rev_Add || best.op == .Rev_Del {
		best = Buffer_Diff_Snake{n - best.u, m - best.v, n - best.x, m - best.y, best.op}
	}
	return best
}

// buffer_diff_find_rec ports find_diff_rec over line arrays.
@(private = "file")
buffer_diff_find_rec :: proc(
	a: []string,
	beg_a, end_a: int,
	b: []string,
	beg_b, end_b: int,
	v1, v2: []int,
	v_off, cost_limit: int,
	st: ^Buffer_Diff_State,
) {
	lo_a, hi_a := beg_a, end_a
	lo_b, hi_b := beg_b, end_b

	prefix_len := 0
	for lo_a != hi_a && lo_b != hi_b && a[lo_a] == b[lo_b] {
		lo_a += 1
		lo_b += 1
		prefix_len += 1
	}

	suffix_len := 0
	for lo_a != hi_a && lo_b != hi_b && a[hi_a - 1] == b[hi_b - 1] {
		hi_a -= 1
		hi_b -= 1
		suffix_len += 1
	}

	if prefix_len != 0 {
		buffer_diff_emit(st, .Keep, prefix_len)
	}

	len_a := hi_a - lo_a
	len_b := hi_b - lo_b

	if len_a == 0 {
		if len_b != 0 {
			buffer_diff_emit(st, .Add, len_b)
		}
	} else if len_b == 0 {
		buffer_diff_emit(st, .Remove, len_a)
	} else {
		snake := buffer_diff_middle_snake(a[lo_a:hi_a], b[lo_b:hi_b], v1, v2, v_off, cost_limit)
		assert(snake.u <= len_a && snake.v <= len_b)

		del := 1 if snake.op == .Del else 0
		add := 1 if snake.op == .Add else 0
		buffer_diff_find_rec(a, lo_a, lo_a + snake.x - del, b, lo_b, lo_b + snake.y - add, v1, v2, v_off, cost_limit, st)

		if snake.op == .Add {
			buffer_diff_emit(st, .Add, 1)
		}
		if snake.op == .Del {
			buffer_diff_emit(st, .Remove, 1)
		}
		if snake.u - snake.x != 0 {
			buffer_diff_emit(st, .Keep, snake.u - snake.x)
		}
		if snake.op == .Rev_Add {
			buffer_diff_emit(st, .Add, 1)
		}
		if snake.op == .Rev_Del {
			buffer_diff_emit(st, .Remove, 1)
		}

		rev_del := 1 if snake.op == .Rev_Del else 0
		rev_add := 1 if snake.op == .Rev_Add else 0
		buffer_diff_find_rec(a, lo_a + snake.u + rev_del, hi_a, b, lo_b + snake.v + rev_add, hi_b, v1, v2, v_off, cost_limit, st)
	}

	if suffix_len != 0 {
		buffer_diff_emit(st, .Keep, suffix_len)
	}
}

// buffer_diff_for_each reports the minimal (within the cost limit) edit
// script turning a into b as coalesced line runs. The merged diff
// module is byte-specialized, so reload carries this line variant.
@(private = "file")
buffer_diff_for_each :: proc(a, b: []string, diffs: ^[dynamic]Buffer_Diff, allocator := context.allocator) {
	cost_limit := 1000
	v_off := len(a) + len(b) + 1
	v1 := make([]int, 2 * v_off + 1, allocator)
	defer delete(v1, allocator)
	v2 := make([]int, 2 * v_off + 1, allocator)
	defer delete(v2, allocator)

	st := Buffer_Diff_State{diffs = diffs}
	buffer_diff_find_rec(a, 0, len(a), b, 0, len(b), v1, v2, v_off, cost_limit, &st)
	if st.last.op != .Keep || st.last.len != 0 {
		append(diffs, st.last)
	}
}

// buffer_reload swaps the buffer content for lines, recording undo as
// line-granular modifications (port of Buffer::reload). Without undo it
// resets the history instead. The bom/eolformat/finaleol option sync is
// deferred until option_manager merges (see header).
buffer_reload :: proc(
	b: ^Buffer,
	lines: []string,
	bom: Byte_Order_Mark,
	eolformat: Eol_Format,
	finaleol: Final_Eol,
	fs_status: File_Fs_Status,
) {
	record_undo := .No_Undo not_in b.flags
	buffer_commit_undo_group(b)

	if !record_undo {
		// Erase history about to be invalidated.
		b.history_id = buffer_HISTORY_FIRST
		b.last_save_history_id = buffer_HISTORY_FIRST
		for &node in b.history {
			for m in node.undo_group {
				delete(m.content, b.allocator)
			}
			delete(node.undo_group)
		}
		clear(&b.history)
		append(&b.history, Buffer_History_Node{parent = buffer_HISTORY_INVALID, redo_child = buffer_HISTORY_INVALID, committed = clock_now()})

		append(&b.changes, Buffer_Change{type = .Erase, begin = {0, 0}, end = buffer_end_coord(b)})
		for l in b.lines {
			delete(l, b.allocator)
		}
		clear(&b.lines)
		for l in lines {
			append(&b.lines, strings.clone(l, b.allocator))
		}
		append(&b.changes, Buffer_Change{type = .Insert, begin = {0, 0}, end = buffer_end_coord(b)})
	} else {
		diffs := make([dynamic]Buffer_Diff, 0, context.temp_allocator)
		buffer_diff_for_each(b.lines[:], lines, &diffs, context.temp_allocator)
		result := make(Buffer_Lines, 0, len(lines), b.allocator)
		r, w := 0, 0
		for d in diffs {
			switch d.op {
			case .Keep:
				for _ in 0 ..< d.len {
					append(&result, b.lines[r])
					r += 1
					w += 1
				}
			case .Add:
				cur := Units_LineCount(len(result))
				for i in 0 ..< d.len {
					append(
						&b.current_undo_group,
						Buffer_Modification {
							type = .Insert,
							coord = {cur + Units_LineCount(i), 0},
							content = strings.clone(lines[w], b.allocator),
						},
					)
					append(&result, strings.clone(lines[w], b.allocator))
					w += 1
				}
				append(&b.changes, Buffer_Change{type = .Insert, begin = {cur, 0}, end = {cur + Units_LineCount(d.len), 0}})
			case .Remove:
				cur := Units_LineCount(len(result))
				for i := d.len - 1; i >= 0; i -= 1 {
					append(
						&b.current_undo_group,
						Buffer_Modification {
							type = .Erase,
							coord = {cur + Units_LineCount(i), 0},
							content = strings.clone(b.lines[r + i], b.allocator),
						},
					)
				}
				for _ in 0 ..< d.len {
					delete(b.lines[r], b.allocator)
					r += 1
				}
				append(&b.changes, Buffer_Change{type = .Erase, begin = {cur, 0}, end = {cur + Units_LineCount(d.len), 0}})
			}
		}
		delete(b.lines)
		b.lines = result
	}

	buffer_commit_undo_group(b)
	b.last_save_history_id = b.history_id
	b.fs_status = fs_status
	// C++ Buffer::reload records the decoded file attributes as
	// local options (no-op for fixture buffers without them).
	buffer_set_file_options(b, bom, eolformat, finaleol)
}

// buffer_check_invariant asserts the line invariant (port of the
// KAK_DEBUG-only check_invariant; always active here).
buffer_check_invariant :: proc(b: ^Buffer) {
	assert(len(b.lines) != 0)
	for l in b.lines {
		assert(len(l) > 0)
		assert(l[len(l) - 1] == '\n')
	}
}

// buffer_debug_description summarizes the buffer state (port of
// debug_description). Caller frees the result.
buffer_debug_description :: proc(b: ^Buffer, allocator := context.allocator) -> string {
	content_size := 0
	for l in b.lines {
		content_size += len(l)
	}
	additional_size := 0
	for node in b.history {
		additional_size += size_of(Buffer_History_Node) + len(node.undo_group) * size_of(Buffer_Modification)
	}
	additional_size += len(b.changes) * size_of(Buffer_Change)

	file_str := ""
	if .File in b.flags {
		file_str = fmt.tprintf("File (%s) ", b.filename)
	}
	sb := strings.builder_make(allocator)
	fmt.sbprintf(
		&sb,
		"%s\nFlags: %s%s%s%s%s%s%s%s\nUsed mem: content=%d additional=%d\n",
		b.display_name,
		file_str,
		"New " if .New in b.flags else "",
		"Fifo " if .Fifo in b.flags else "",
		"NoUndo " if .No_Undo in b.flags else "",
		"NoHooks " if .No_Hooks in b.flags else "",
		"Debug " if .Debug in b.flags else "",
		"ReadOnly " if .Read_Only in b.flags else "",
		"Modified " if buffer_is_modified(b) else "",
		content_size,
		additional_size,
	)
	return strings.to_string(sb)
}

// buffer_run_hook_in_own_context runs hook with a draft context on this
// buffer. Only the NoHooks early return works standalone; the rest calls
// the unmerged input_handler/hook_manager modules.
buffer_run_hook_in_own_context :: proc(b: ^Buffer, hook: Hook, param: string, client_name := "", allocator := context.allocator) {
	if .No_Hooks in b.flags {
		return
	}
	sels := make([dynamic]Selection, 1, allocator)
	sels[0] = Selection{}
	list := Selection_List{selections = sels, buffer = b, timestamp = buffer_timestamp(b)}
	handler := input_handler_make(list, Context_Flags{.Draft}, client_name)
	hook_manager_run_hook(&b.scope.data.hooks, hook, param, input_handler_context(handler))
	input_handler_destroy(handler)
	delete(sels)
}

// buffer_option_watcher_callback adapts buffer_on_option_changed to the
// merged Option_Watcher callback shape.
buffer_option_watcher_callback :: proc(data: rawptr, option: rawptr) {
	b := cast(^Buffer)data
	o := cast(^Option)option
	buffer_on_option_changed(b, o)
}

// buffer_on_option_changed syncs the ReadOnly flag and runs BufSetOption.
// Only the NoBufSetOption early return works standalone; the rest calls
// the unmerged option/hook modules.
buffer_on_option_changed :: proc(b: ^Buffer, option: ^Option, allocator := context.allocator) {
	if .No_Buf_Set_Option in b.flags {
		return
	}
	if option.desc.name == "readonly" {
		if option.value.(bool) {
			b.flags = b.flags + Buffer_Flags{.Read_Only}
		} else {
			b.flags = b.flags - Buffer_Flags{.Read_Only}
		}
	}
	desc := option_manager_option_get_desc_string(option, allocator)
	defer delete(desc, allocator)
	param := strings.concatenate({option.desc.name, "=", desc}, context.temp_allocator)
	buffer_run_hook_in_own_context(b, .Buf_Set_Option, param)
}

// buffer_on_registered runs the registration hooks (called by the buffer
// manager). Only the Debug early return works standalone; the rest calls
// unmerged modules.
buffer_on_registered :: proc(b: ^Buffer, allocator := context.allocator) {
	if .Debug in b.flags {
		return
	}
	option_manager_register_watcher(&b.scope.data.options, Option_Watcher{data = b, on_option_changed = buffer_option_watcher_callback})
	if .No_Hooks in b.flags {
		readonly_opt := option_manager_get_checked(&b.scope.data.options, "readonly")
		buffer_on_option_changed(b, readonly_opt)
		return
	}
	b.flags = b.flags + Buffer_Flags{.No_Buf_Set_Option}
	buffer_run_hook_in_own_context(b, .Buf_Create, buffer_name(b))
	if .File in b.flags {
		if .New in b.flags {
			buffer_run_hook_in_own_context(b, .Buf_New_File, buffer_name(b))
		} else {
			assert(b.fs_status.timestamp != File_Invalid_Time)
			buffer_run_hook_in_own_context(b, .Buf_Open_File, buffer_name(b))
		}
	}
	b.flags = b.flags - Buffer_Flags{.No_Buf_Set_Option}
	opts := option_manager_flatten_options(&b.scope.data.options, allocator)
	defer delete(opts)
	for o in opts {
		buffer_on_option_changed(b, o)
	}
}

// buffer_on_unregistered runs BufClose and drops the option watcher
// (called by the buffer manager). Stub-blocked except for Debug buffers.
buffer_on_unregistered :: proc(b: ^Buffer) {
	if .Debug in b.flags {
		return
	}
	option_manager_unregister_watcher(&b.scope.data.options, Option_Watcher{data = b, on_option_changed = buffer_option_watcher_callback})
	buffer_run_hook_in_own_context(b, .Buf_Close, buffer_name(b))
}

// --- Stubs for procs owned by unmerged modules. Each body is exactly
// one panic line per the STUB protocol; the coordinator deletes the stub
// when the real proc merges. ---
// (Remainder stub implemented: buffer_manager_get_buffer_ifp.)

// ---------------------------------------------------------------------------
// Remainder implementations (C++-named aliases over this module's procs)
// ---------------------------------------------------------------------------

// scoped_edition_make opens a buffer edition for the context buffer, if
// any (C++ ScopedEdition ctor in context.hh; the name is kept from the
// STUB contract). Pair with scoped_edition_destroy.
scoped_edition_make :: proc(ctx: ^Context) -> Scoped_Edition {
	return context_scoped_edition_make(ctx)
}

// scoped_edition_destroy closes the edition (C++ ScopedEdition dtor).
scoped_edition_destroy :: proc(edition: ^Scoped_Edition) {
	context_scoped_edition_destroy(edition)
}

// buffer_offset_coord_char moves coord by offset codepoints (C++
// Buffer::offset_coord overload; the ColumnCount parameter is unused in
// the C++ too).
buffer_offset_coord_char :: proc(
	buffer: ^Buffer,
	coord: Coord_Buffer,
	offset: Units_CharCount,
	tabstop: Units_ColumnCount,
) -> Coord_Buffer {
	return buffer_offset_coord_by_char(buffer, coord, offset, tabstop)
}

// buffer_offset_coord_line moves coord vertically by offset lines,
// keeping the target column (C++ Buffer::offset_coord
// BufferCoordAndTarget overload).
buffer_offset_coord_line :: proc(
	buffer: ^Buffer,
	coord: Coord_Buffer_And_Target,
	offset: Units_LineCount,
	tabstop: Units_ColumnCount,
) -> Coord_Buffer_And_Target {
	return buffer_offset_coord_by_line(buffer, coord, offset, tabstop)
}

// buffer_iterator_value returns the byte at the iterator, widened to a
// rune (C++ BufferIterator::operator*, which returns char; the rune type
// is fixed by the STUB contract).
buffer_iterator_value :: proc(it: Buffer_Iterator) -> rune {
	return rune(buffer_iterator_deref(it))
}

