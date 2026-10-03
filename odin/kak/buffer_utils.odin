// Port of Kakoune's src/buffer_utils.hh and src/buffer_utils.cc: small
// buffer helpers (content, erase, lengths, word predicates, column
// conversions), buffer factories (from string, from file, fifo), file
// reload, file writing (fd, file, backup), and history formatting.
//
// Error mapping: C++ throws runtime_error/file_access_error here. Those
// become Buffer_Utils_Error returns; the variants name the C++ throw
// site. File_Error details collapse into .File_Open_Failed on the read
// path and .File_Write_Failed on the write path.
//
// Ownership: procs returning strings or string lists allocate them in
// `allocator` (default context.allocator); the caller frees them.
// Parsed lines are cloned again by buffer_make/buffer_reload, so the
// parse helpers' output is always freed by the caller (see
// buffer_utils_free_lines).
//
// Fifo watchers: C++ FifoWatcher subclasses FDWatcher and lives in the
// buffer's value map. Odin has no subclassing, so the watcher state is
// a Buffer_Utils_Fifo_Watcher heap value (owned by the buffer's value
// map, allocated with the buffer allocator) plus an Event_Manager fd
// watcher registered on its embedded watcher field. The event callback
// finds the state through the buffer_utils_fifo_owners registry, which
// mirrors the remote_watcher_owners pattern in remote.odin and lives
// for the whole process.
package kak

import "core:c"
import "core:strings"
import posix "core:sys/posix"

// Buffer_Utils_Error enumerates every failure of this module. The zero
// value .None means success.
Buffer_Utils_Error :: enum {
	None, // ok
	// A buffer with the requested name already exists (C++ threw
	// "buffer name is already in use").
	Name_In_Use,
	// A hook deleted the buffer while it was being created (C++
	// threw "buffer got removed during its creation").
	Removed_During_Creation,
	// The buffer manager refused creation for another reason
	// (unreachable from its create path; defensive).
	Creation_Failed,
	// The file holds max(i32) lines or more (C++ threw
	// "too many lines").
	Too_Many_Lines,
	// A file line holds max(i32) bytes or more (C++ threw
	// "line is too long").
	Line_Too_Long,
	// Opening, stating, or mapping the file failed, or the parsed
	// name is unusable (C++ threw file_access_error).
	File_Open_Failed,
	// Writing, flushing, chmod/chown/rename, or the post-write
	// stat failed (C++ threw file_access_error or runtime_error).
	File_Write_Failed,
	// A mutation targeted a read-only buffer.
	Buffer_Read_Only,
}

// buffer_utils_error_message renders the C++ exception text for err
// (file_access_error details like the filename are lost; best static
// text is used). Used for status-line error reports.
buffer_utils_error_message :: proc(err: Buffer_Utils_Error) -> string {
	switch err {
	case .None:
		return "ok"
	case .Name_In_Use:
		return "buffer name is already in use"
	case .Removed_During_Creation:
		return "buffer got removed during its creation"
	case .Creation_Failed:
		return "buffer creation failed"
	case .Too_Many_Lines:
		return "too many lines"
	case .Line_Too_Long:
		return "line is too long"
	case .File_Open_Failed:
		return "unable to open file"
	case .File_Write_Failed:
		return "unable to write file"
	case .Buffer_Read_Only:
		return "buffer is read-only"
	}
	unreachable()
}

// Buffer_Utils_Write_Flag selects write_buffer_to_file behaviors (port
// of C++ WriteFlags; the empty set is WriteFlags::None).
Buffer_Utils_Write_Flag :: enum {
	Force, // make a read-only file writable around the write
	Sync, // fsync before closing
}
Buffer_Utils_Write_Flags :: bit_set[Buffer_Utils_Write_Flag; u8]

// Buffer_Utils_Auto_Scroll selects fifo-buffer scroll behavior (port
// of C++ AutoScroll in buffer_utils.hh).
Buffer_Utils_Auto_Scroll :: enum {
	No, // keep point, drop the trailing newline bookkeeping
	Not_Initially, // scroll once the first chunk landed
	Yes, // always scroll with new output
}

// buffer_utils_map_manager_error translates a buffer-manager creation
// result. Only .None, .Name_In_Use and .Removed_During_Creation can
// come out of buffer_manager_create; anything else is defensive.
@(private)
buffer_utils_map_manager_error :: proc(err: Buffer_Manager_Error) -> Buffer_Utils_Error {
	mapped := Buffer_Utils_Error.Creation_Failed
	switch err {
	case .None:
		mapped = .None
	case .Name_In_Use:
		mapped = .Name_In_Use
	case .Removed_During_Creation:
		mapped = .Removed_During_Creation
	case .No_Such_Buffer, .Duplicate_Buffer, .Locked:
		mapped = .Creation_Failed
	}
	return mapped
}

// buffer_utils_content returns the text covered by sel, end-inclusive
// (port of C++ content()).
buffer_utils_content :: proc(buffer: ^Buffer, sel: Selection, allocator := context.allocator) -> string {
	return buffer_string(buffer, selection_basic_min(sel.basic), buffer_char_next(buffer, selection_basic_max(sel.basic)), allocator)
}

// buffer_utils_erase removes the text covered by sel, end-inclusive,
// and returns the position left behind (port of C++ erase()).
buffer_utils_erase :: proc(buffer: ^Buffer, sel: Selection) -> (Coord_Buffer, Buffer_Utils_Error) {
	pos, err := buffer_erase(buffer, selection_basic_min(sel.basic), buffer_char_next(buffer, selection_basic_max(sel.basic)))
	if err != .None {
		return pos, .Buffer_Read_Only
	}
	return pos, .None
}

// buffer_utils_replace replaces each range with the corresponding
// string (the last string repeats when there are fewer strings than
// ranges; no strings means erase). Later ranges are mapped forward
// past earlier edits, as in C++.
buffer_utils_replace :: proc(buffer: ^Buffer, ranges: []Buffer_Range, strs: []string) -> Buffer_Utils_Error {
	tracker: Forward_Changes_Tracker
	timestamp := buffer_timestamp(buffer)
	for &range, index in ranges {
		range.begin = changes_get_new_coord_tolerant(&tracker, range.begin)
		range.end = changes_get_new_coord_tolerant(&tracker, range.end)
		assert(buffer_is_valid(buffer, range.begin) && buffer_is_valid(buffer, range.end))
		content := ""
		if len(strs) != 0 {
			content = strs[min(index, len(strs) - 1)]
		}
		replaced, err := buffer_replace(buffer, range.begin, range.end, content)
		if err != .None {
			return .Buffer_Read_Only
		}
		range = replaced
		assert(buffer_is_valid(buffer, range.begin) && buffer_is_valid(buffer, range.end))
		changes_update_buffer(&tracker, buffer, &timestamp)
	}
	buffer_check_invariant(buffer)
	return .None
}

// buffer_utils_char_length counts the codepoints covered by sel,
// end-inclusive (port of C++ char_length()).
buffer_utils_char_length :: proc(buffer: ^Buffer, sel: Selection) -> Units_CharCount {
	return buffer_utils_char_length_range(buffer, selection_basic_min(sel.basic), buffer_char_next(buffer, selection_basic_max(sel.basic)))
}

// buffer_utils_char_length_range counts the codepoints in the
// half-open range [begin, end) (port of the C++ char_length()
// overload taking two coords).
buffer_utils_char_length_range :: proc(buffer: ^Buffer, begin, end: Coord_Buffer) -> Units_CharCount {
	count: Units_CharCount = 0
	pos := begin
	for coord_compare(pos, end) < 0 {
		pos = buffer_char_next(buffer, pos)
		count += 1
	}
	return count
}

// buffer_utils_column_length_range sums the display widths of the
// codepoints in [begin, end) (port of the C++ column_length()
// overload taking two coords, i.e. utf8::column_distance).
buffer_utils_column_length_range :: proc(buffer: ^Buffer, begin, end: Coord_Buffer) -> Coord_Column {
	total := 0
	pos := begin
	for coord_compare(pos, end) < 0 {
		total += unicode_codepoint_width(buffer_utils_codepoint_at(buffer, pos))
		pos = buffer_char_next(buffer, pos)
	}
	return Coord_Column(total)
}

// buffer_utils_is_bol reports whether coord starts a line.
buffer_utils_is_bol :: proc(coord: Coord_Buffer) -> bool {
	return coord.column == 0
}

// buffer_utils_is_eol reports whether coord addresses the newline
// ending its line, or the end of the buffer (port of C++ is_eol()).
buffer_utils_is_eol :: proc(buffer: ^Buffer, coord: Coord_Buffer) -> bool {
	return buffer_is_end(buffer, coord) || len(buffer_line(buffer, coord.line)) == int(coord.column) + 1
}

// buffer_utils_codepoint_at reads the codepoint starting at coord,
// snapping mid-character columns back to the character start like the
// C++ utf8::iterator. Out-of-range coords read as a newline.
@(private)
buffer_utils_codepoint_at :: proc(buffer: ^Buffer, coord: Coord_Buffer) -> rune {
	if coord.line < 0 || coord.line >= buffer_line_count(buffer) {
		return '\n'
	}
	line := buffer_line(buffer, coord.line)
	pos := utf8_character_start(line, int(coord.column))
	if pos >= len(line) {
		return '\n'
	}
	return utf8_read_codepoint(line, &pos)
}

// buffer_utils_is_word_char reports whether cp is a word character
// with the C++ default extra word chars ({'_'}).
@(private)
buffer_utils_is_word_char :: proc(cp: rune) -> bool {
	extra := [1]rune{'_'}
	return unicode_is_word(cp, extra[:])
}

// buffer_utils_is_bow reports whether coord starts a word (port of
// C++ is_bow()).
buffer_utils_is_bow :: proc(buffer: ^Buffer, coord: Coord_Buffer) -> bool {
	origin := Coord_Buffer{0, 0}
	if coord == origin {
		return buffer_utils_is_word_char(buffer_utils_codepoint_at(buffer, coord))
	}
	return !buffer_utils_is_word_char(buffer_utils_codepoint_at(buffer, buffer_char_prev(buffer, coord))) &&
		buffer_utils_is_word_char(buffer_utils_codepoint_at(buffer, coord))
}

// buffer_utils_is_eow reports whether coord ends a word (port of C++
// is_eow()).
buffer_utils_is_eow :: proc(buffer: ^Buffer, coord: Coord_Buffer) -> bool {
	origin := Coord_Buffer{0, 0}
	if buffer_is_end(buffer, coord) || coord == origin {
		return false
	}
	return buffer_utils_is_word_char(buffer_utils_codepoint_at(buffer, buffer_char_prev(buffer, coord))) &&
		!buffer_utils_is_word_char(buffer_utils_codepoint_at(buffer, coord))
}

// buffer_utils_get_column returns the display column of coord,
// expanding tabs against tabstop (port of C++ get_column()).
buffer_utils_get_column :: proc(buffer: ^Buffer, tabstop: Coord_Column, coord: Coord_Buffer) -> Coord_Column {
	line := buffer_line(buffer, coord.line)
	col := 0
	i := 0
	for i < len(line) && int(coord.column) > i {
		if line[i] == '\t' {
			col = (col / int(tabstop) + 1) * int(tabstop)
			i += 1
		} else {
			col += unicode_codepoint_width(utf8_read_codepoint(line, &i))
		}
	}
	return Coord_Column(col)
}

// buffer_utils_column_length returns the display width of line,
// expanding tabs against tabstop (port of C++ column_length()).
buffer_utils_column_length :: proc(buffer: ^Buffer, tabstop: Coord_Column, line: Units_LineCount) -> Coord_Column {
	return buffer_utils_get_column(buffer, tabstop, Coord_Buffer{line, Units_ByteCount(max(int))})
}

// buffer_utils_get_byte_to_column returns the byte offset of the
// character covering display column coord.column, stopping at a tab
// or character straddling it (port of C++ get_byte_to_column()).
buffer_utils_get_byte_to_column :: proc(
	buffer: ^Buffer,
	tabstop: Coord_Column,
	coord: Coord_Display,
) -> Units_ByteCount {
	line := buffer_line(buffer, coord.line)
	col := 0
	i := 0
	for i < len(line) && int(coord.column) > col {
		if line[i] == '\t' {
			col = (col / int(tabstop) + 1) * int(tabstop)
			if col > int(coord.column) {
				break
			}
			i += 1
		} else {
			next := i
			col += unicode_codepoint_width(utf8_read_codepoint(line, &next))
			if col > int(coord.column) {
				break
			}
			i = next
		}
	}
	return Units_ByteCount(i)
}

// buffer_utils_free_lines releases lines parsed by
// buffer_utils_parse_lines (each string, then the list).
buffer_utils_free_lines :: proc(lines: Buffer_Lines, allocator := context.allocator) {
	for l in lines {
		delete(l, allocator)
	}
	delete(lines)
}

// buffer_utils_parse_lines splits data into buffer lines, storing the
// "\n" terminator with each line and stripping one carriage return
// before it in Crlf mode (port of the C++ static parse_lines()).
// Empty input yields one empty line. The caller owns the result (see
// buffer_utils_free_lines).
@(private)
buffer_utils_parse_lines :: proc(data: string, eolformat: Eol_Format, allocator := context.allocator) -> (lines: Buffer_Lines, err: Buffer_Utils_Error) {
	err = .None
	newlines := 0
	for i := 0; i < len(data); i += 1 {
		if data[i] == '\n' {
			newlines += 1
		}
	}
	lines = make(Buffer_Lines, 0, newlines + 1, allocator)
	pos := 0
	for pos < len(data) {
		if len(lines) >= int(max(i32)) {
			buffer_utils_free_lines(lines, allocator)
			return {}, .Too_Many_Lines
		}
		end := len(data)
		if rel := strings.index_byte(data[pos:], '\n'); rel >= 0 {
			end = pos + rel
		}
		if end - pos >= int(max(i32)) {
			buffer_utils_free_lines(lines, allocator)
			return {}, .Line_Too_Long
		}
		cut := end
		if eolformat == .Crlf && end < len(data) && cut > pos {
			cut -= 1
		}
		append(&lines, strings.concatenate({data[pos:cut], "\n"}, allocator))
		pos = end + 1
	}
	if len(lines) == 0 {
		append(&lines, strings.clone("\n", allocator))
	}
	return lines, .None
}

// Buffer_Utils_Parsed_File is a file decoded into buffer inputs (the
// C++ parse_file() callback parameters as one value).
Buffer_Utils_Parsed_File :: struct {
	lines:    Buffer_Lines,
	bom:      Byte_Order_Mark,
	eolformat: Eol_Format,
	finaleol: Final_Eol,
	fs_status: File_Fs_Status,
}

// buffer_utils_parse_file reads and decodes filename (port of the C++
// static parse_file()): tilde/percent expansion, memory mapping, BOM
// detection, CRLF sniffing, final-EOL detection, and the fs status
// snapshot. The caller owns parsed.lines (see buffer_utils_free_lines).
@(private)
buffer_utils_parse_file :: proc(filename: string, allocator := context.allocator) -> (parsed: Buffer_Utils_Parsed_File, err: Buffer_Utils_Error) {
	parsed_path := file_parse_filename(filename, "", context.temp_allocator)
	mapped, map_err := file_mapped_file_open(parsed_path)
	if map_err != .None {
		return {}, .File_Open_Failed
	}
	defer file_mapped_file_close(&mapped)
	if len(mapped.data) > int(max(i32)) {
		return {}, .File_Open_Failed
	}
	data := string(mapped.data)
	pos := 0
	bom := Byte_Order_Mark.None
	if len(data) >= 3 && data[:3] == "\xEF\xBB\xBF" {
		bom = .Utf8
		pos = 3
	}
	has_crlf := false
	has_lf := false
	i := pos
	for i < len(data) {
		rel := strings.index_byte(data[i:], '\n')
		if rel < 0 {
			break
		}
		nl := i + rel
		if nl != pos && data[nl - 1] == '\r' {
			has_crlf = true
		} else {
			has_lf = true
		}
		i = nl + 1
	}
	eolformat := Eol_Format.Lf
	if has_crlf && !has_lf {
		eolformat = .Crlf
	}
	finaleol := Final_Eol.If_Not_Empty
	if pos != len(data) {
		finaleol = .Present if data[len(data) - 1] == '\n' else .Missing
	}
	lines, parse_err := buffer_utils_parse_lines(data[pos:], eolformat, allocator)
	if parse_err != .None {
		return {}, parse_err
	}
	parsed = Buffer_Utils_Parsed_File {
		lines     = lines,
		bom       = bom,
		eolformat = eolformat,
		finaleol  = finaleol,
		fs_status = File_Fs_Status{timestamp = mapped.modified, file_size = len(mapped.data), hash = hash_murmur3(data)},
	}
	return parsed, .None
}

// buffer_utils_create_buffer_from_string registers a buffer holding
// data (port of C++ create_buffer_from_string()).
buffer_utils_create_buffer_from_string :: proc(
	name: string,
	flags: Buffer_Flags,
	data: string,
	allocator := context.allocator,
) -> (^Buffer, Buffer_Utils_Error) {
	lines, parse_err := buffer_utils_parse_lines(data, .Lf, allocator)
	if parse_err != .None {
		return nil, parse_err
	}
	defer buffer_utils_free_lines(lines, allocator)
	buf, create_err := buffer_manager_create(
		buffer_manager_instance(),
		name,
		flags,
		lines,
		.None,
		.Lf,
		.Present,
		File_Fs_Status{timestamp = File_Invalid_Time},
	)
	if create_err != .None {
		return nil, buffer_utils_map_manager_error(create_err)
	}
	return buf, .None
}

// buffer_utils_open_file_buffer registers a File buffer holding the
// decoded filename (port of C++ open_file_buffer()). The buffer name
// is filename as given, before filename expansion.
buffer_utils_open_file_buffer :: proc(
	filename: string,
	flags: Buffer_Flags = {},
	allocator := context.allocator,
) -> (^Buffer, Buffer_Utils_Error) {
	parsed, parse_err := buffer_utils_parse_file(filename, allocator)
	if parse_err != .None {
		return nil, parse_err
	}
	defer buffer_utils_free_lines(parsed.lines, allocator)
	buf, create_err := buffer_manager_create(
		buffer_manager_instance(),
		filename,
		{.File} | flags,
		parsed.lines,
		parsed.bom,
		parsed.eolformat,
		parsed.finaleol,
		parsed.fs_status,
	)
	if create_err != .None {
		return nil, buffer_utils_map_manager_error(create_err)
	}
	return buf, .None
}

// buffer_utils_open_or_create_file_buffer opens filename, or registers
// a fresh New buffer when it does not exist (port of C++
// open_or_create_file_buffer()). Like the C++, the create branch
// ignores flags beyond File and New.
buffer_utils_open_or_create_file_buffer :: proc(
	filename: string,
	flags: Buffer_Flags = {},
	allocator := context.allocator,
) -> (^Buffer, Buffer_Utils_Error) {
	path := file_parse_filename(filename, "", context.temp_allocator)
	if file_exists(path) {
		return buffer_utils_open_file_buffer(filename, {.File} | flags, allocator)
	}
	return buffer_utils_create_buffer_from_string(filename, {.File, .New}, "", allocator)
}

// buffer_utils_reload_file_buffer replaces buffer contents with the
// current file decoding (port of C++ reload_file_buffer()).
buffer_utils_reload_file_buffer :: proc(b: ^Buffer, allocator := context.allocator) -> Buffer_Utils_Error {
	assert(.File in b.flags)
	parsed, parse_err := buffer_utils_parse_file(b.filename, allocator)
	if parse_err != .None {
		return parse_err
	}
	defer buffer_utils_free_lines(parsed.lines, allocator)
	buffer_reload(b, parsed.lines[:], parsed.bom, parsed.eolformat, parsed.finaleol, parsed.fs_status)
	b.flags -= {.New}
	return .None
}

// buffer_utils_write_buffer_to_fd writes the buffer text to fd,
// honoring the finaleol override (or the buffer's "finaleol"
// option), the "eolformat" option, and the "BOM" option (port of C++
// write_buffer_to_fd()).
buffer_utils_write_buffer_to_fd :: proc(b: ^Buffer, fd: int, finaleol: Maybe(Final_Eol) = nil) -> Buffer_Utils_Error {
	options := &b.scope.data.options
	fe := finaleol.? or_else option_manager_get_checked(options, "finaleol").value.(Final_Eol)
	eolformat := option_manager_get_checked(options, "eolformat").value.(Eol_Format)
	eoldata := "\r\n" if eolformat == .Crlf else "\n"
	write_eol_at_eof := fe == .Present ||
		(fe == .If_Not_Empty && (buffer_line_count(b) != 1 || buffer_line(b, 0) != "\n"))
	w := file_buffered_writer_make(fd, false)
	if option_manager_get_checked(options, "BOM").value.(Byte_Order_Mark) == .Utf8 {
		if err := file_buffered_writer_write(&w, "\xEF\xBB\xBF"); err != .None {
			return .File_Write_Failed
		}
	}
	line_count := int(buffer_line_count(b))
	for i in 0 ..< line_count {
		linedata := buffer_line(b, Units_LineCount(i))
		if err := file_buffered_writer_write(&w, linedata[:len(linedata) - 1]); err != .None {
			return .File_Write_Failed
		}
		if write_eol_at_eof || i != line_count - 1 {
			if err := file_buffered_writer_write(&w, eoldata); err != .None {
				return .File_Write_Failed
			}
		}
	}
	if err := file_buffered_writer_flush(&w); err != .None {
		return .File_Write_Failed
	}
	return .None
}

// buffer_utils_write_buffer_to_file writes the buffer to filename
// (port of C++ write_buffer_to_file()). Method .Replace writes a temp
// file, copies ownership and permissions, and renames it over the
// target; .Overwrite truncates in place. Like the C++, a failed
// temp-file write leaks the temp file, and a failed mid-write chmod
// restore is not attempted.
buffer_utils_write_buffer_to_file :: proc(
	b: ^Buffer,
	filename: string,
	method: File_Write_Method,
	flags: Buffer_Utils_Write_Flags = {},
	finaleol: Maybe(Final_Eol) = nil,
) -> Buffer_Utils_Error {
	zfilename := strings.clone_to_cstring(filename, context.temp_allocator)
	st: posix.stat_t
	replace := method == .Replace
	force := .Force in flags
	if (replace || force) && (posix.stat(zfilename, &st) != .OK || !posix.S_ISREG(st.st_mode)) {
		force = false
		replace = false
	}
	if force && posix.chmod(zfilename, st.st_mode + posix.mode_t{.IWUSR}) != .OK {
		return .File_Write_Failed
	}
	fd := -1
	temp_path := ""
	if replace {
		tfd, tpath, temp_err := file_open_temp_file(filename, context.temp_allocator)
		if temp_err != .None {
			if force {
				posix.chmod(zfilename, st.st_mode)
			}
			return .File_Open_Failed
		}
		fd, temp_path = tfd, tpath
	} else {
		cfd, create_err := file_create_file(filename)
		if create_err != .None {
			if force {
				posix.chmod(zfilename, st.st_mode)
			}
			return .File_Open_Failed
		}
		fd = cfd
	}
	write_err := buffer_utils_write_buffer_to_fd(b, fd, finaleol)
	if .Sync in flags {
		posix.fsync(posix.FD(fd))
	}
	posix.close(posix.FD(fd))
	if write_err != .None {
		return write_err
	}
	temp_cname := strings.clone_to_cstring(temp_path, context.temp_allocator)
	if replace && posix.geteuid() == 0 && posix.chown(temp_cname, st.st_uid, st.st_gid) != .OK {
		return .File_Write_Failed
	}
	if replace && posix.chmod(temp_cname, st.st_mode) != .OK {
		return .File_Write_Failed
	}
	if force && !replace && posix.chmod(zfilename, st.st_mode) != .OK {
		return .File_Write_Failed
	}
	if replace && posix.rename(temp_cname, zfilename) != 0 {
		if force {
			posix.chmod(zfilename, st.st_mode)
		}
		return .File_Write_Failed
	}
	if .File in b.flags {
		saved, saved_err := file_real_path(filename, context.temp_allocator)
		current, current_err := file_real_path(b.filename, context.temp_allocator)
		if saved_err == .None && current_err == .None && saved == current {
			status, status_err := file_get_fs_status(saved)
			if status_err != .None {
				return .File_Open_Failed
			}
			buffer_notify_saved(b, status)
		}
	}
	return .None
}

// buffer_utils_write_to_backup_file writes the buffer to a temp file
// next to its file (port of C++ write_buffer_to_backup_file()). A
// temp file that cannot be created is silently skipped, as in C++.
buffer_utils_write_to_backup_file :: proc(buf: ^Buffer) -> Buffer_Utils_Error {
	fd, _, temp_err := file_open_temp_file(buf.filename, context.temp_allocator)
	if temp_err != .None {
		return .None
	}
	write_err := buffer_utils_write_buffer_to_fd(buf, fd)
	posix.close(posix.FD(fd))
	return write_err
}

// buffer_utils_fifo_watcher_id keys fifo state in buffer value maps
// (port of the C++ static fifo_watcher_id), minted lazily by
// buffer_utils_fifo_id because context procs cannot run at load.
buffer_utils_fifo_watcher_id: Value_Id
buffer_utils_fifo_id_made := false

// buffer_utils_fifo_id returns the value-map key for fifo state.
@(private)
buffer_utils_fifo_id :: proc() -> Value_Id {
	if !buffer_utils_fifo_id_made {
		buffer_utils_fifo_watcher_id = value_get_free_id()
		buffer_utils_fifo_id_made = true
	}
	return buffer_utils_fifo_watcher_id
}

// buffer_utils_fifo_owners maps live fifo watchers to their state for
// event dispatch (mirrors remote_watcher_owners; process lifetime).
buffer_utils_fifo_owners: map[^Event_Manager_Fd_Watcher]^Buffer_Utils_Fifo_Watcher

// Buffer_Utils_Fifo_Watcher is the C++ FifoWatcher: the fd watcher
// plus the owning buffer, scroll mode, and trailing-newline memory.
// Owned by the buffer's value map (buffer allocator); the embedded
// watcher is registered with the event manager.
Buffer_Utils_Fifo_Watcher :: struct {
	watcher:              Event_Manager_Fd_Watcher,
	buffer:               ^Buffer,
	scroll:               Buffer_Utils_Auto_Scroll,
	had_trailing_newline: bool,
}

// buffer_utils_fifo_register links a watcher to its state.
@(private)
buffer_utils_fifo_register :: proc(w: ^Event_Manager_Fd_Watcher, fifo: ^Buffer_Utils_Fifo_Watcher, allocator := context.allocator) {
	context.allocator = allocator
	if buffer_utils_fifo_owners == nil {
		buffer_utils_fifo_owners = make(map[^Event_Manager_Fd_Watcher]^Buffer_Utils_Fifo_Watcher, allocator)
	}
	buffer_utils_fifo_owners[w] = fifo
}

// buffer_utils_fifo_unregister drops a watcher's registry entry.
@(private)
buffer_utils_fifo_unregister :: proc(w: ^Event_Manager_Fd_Watcher) {
	if buffer_utils_fifo_owners != nil {
		delete_key(&buffer_utils_fifo_owners, w)
	}
}

// buffer_utils_fifo_lookup returns a watcher's state, if registered.
@(private)
buffer_utils_fifo_lookup :: proc(w: ^Event_Manager_Fd_Watcher) -> (^Buffer_Utils_Fifo_Watcher, bool) {
	fifo, ok := buffer_utils_fifo_owners[w]
	return fifo, ok
}

// buffer_utils_fifo_on_event drains a ready fifo in Normal mode (port
// of the FifoWatcher FDWatcher callback).
@(private)
buffer_utils_fifo_on_event :: proc(w: ^Event_Manager_Fd_Watcher, events: Event_Manager_Fd_Events, mode: Event_Manager_Mode) {
	_ = events
	if mode == .Normal {
		if fifo, ok := buffer_utils_fifo_lookup(w); ok {
			buffer_utils_fifo_read(fifo)
		}
	}
}

// buffer_utils_fifo_read appends available fifo bytes to the buffer,
// following the C++ FifoWatcher::read_fifo scroll rules, then runs
// the BufReadFifo hook over the inserted span. A closed fifo tears
// the watcher down (BufCloseFifo hook, flag cleanup).
@(private)
buffer_utils_fifo_read :: proc(fifo: ^Buffer_Utils_Fifo_Watcher) {
	buf := fifo.buffer
	assert(.Fifo in buf.flags)
	saved_flags := buf.flags
	buf.flags -= {.Read_Only}
	insert_begin: Maybe(Coord_Buffer) = nil
	closed := false
	loop := 0
	data: [2048]byte
	for {
		n := posix.read(posix.FD(fifo.watcher.fd), raw_data(data[:]), c.size_t(len(data)))
		if n <= 0 {
			closed = true
			break
		}
		count := int(n)
		pos := buffer_back_coord(buf)
		is_first := pos == Coord_Buffer{0, 0}
		if (fifo.scroll == .No && (is_first || fifo.had_trailing_newline)) ||
		   (fifo.scroll == .Not_Initially && is_first) {
			pos = buffer_next(buf, pos)
		}
		inserted, insert_err := buffer_insert(buf, pos, string(data[:count]))
		assert(insert_err == .None)
		if insert_begin == nil {
			insert_begin = inserted.begin
		}
		pos = inserted.end
		have_trailing_newline := data[count - 1] == '\n'
		if fifo.scroll != .Yes {
			if is_first {
				_, erase_err := buffer_erase(buf, Coord_Buffer{0, 0}, buffer_next(buf, Coord_Buffer{0, 0}))
				assert(erase_err == .None)
				begin := insert_begin.?
				begin.line -= 1
				insert_begin = begin
				if fifo.scroll == .Not_Initially && have_trailing_newline {
					_, insert_err2 := buffer_insert(buf, buffer_end_coord(buf), "\n")
					assert(insert_err2 == .None)
				}
			} else if fifo.scroll == .No && !fifo.had_trailing_newline && have_trailing_newline {
				_, erase_err := buffer_erase(buf, buffer_prev(buf, pos), pos)
				assert(erase_err == .None)
			}
		}
		fifo.had_trailing_newline = have_trailing_newline
		loop += 1
		if !(loop < 1024 && file_fd_readable(fifo.watcher.fd)) {
			break
		}
	}
	buf.flags = saved_flags
	if begin, ok := insert_begin.?; ok {
		back := buffer_back_coord(buf)
		if !(fifo.had_trailing_newline && fifo.scroll == .No) {
			back = buffer_prev(buf, back)
		}
		sel := Selection{basic = Basic_Selection{anchor = begin, cursor = coord_buffer_and_target(back)}}
		text, sel_err := selection_to_string(.Byte, buf, sel, -1, context.temp_allocator)
		if sel_err == .None {
			buffer_run_hook_in_own_context(buf, .Buf_Read_Fifo, text)
		}
	}
	if closed {
		buffer_utils_fifo_close(fifo)
	}
}

// buffer_utils_fifo_close tears a fifo watcher down (port of
// ~FifoWatcher): the fd closes, the BufCloseFifo hook runs, and the
// Fifo/NoUndo flags clear unless the hook re-armed the watcher.
@(private)
buffer_utils_fifo_close :: proc(fifo: ^Buffer_Utils_Fifo_Watcher) {
	buf := fifo.buffer
	assert(.Fifo in buf.flags)
	event_manager_fd_watcher_destroy(&fifo.watcher)
	event_manager_fd_watcher_close_fd(&fifo.watcher)
	buffer_utils_fifo_unregister(&fifo.watcher)
	id := buffer_utils_fifo_id()
	if stored, ok := &buf.values[id]; ok {
		value_free(stored, buf.allocator)
		delete_key(&buf.values, id)
	}
	buffer_run_hook_in_own_context(buf, .Buf_Close_Fifo, "")
	if id not_in buf.values {
		buf.flags -= {.Fifo, .No_Undo}
	}
}

// buffer_utils_clear_values frees every buffer value and empties the
// map (port of ValueMap::clear()). A live fifo value tears its
// watcher down first (~FifoWatcher: the fd closes, the watcher
// unregisters, the BufCloseFifo hook runs); repeat until the value
// is gone so a hook re-arm is torn down too. Skips the fifo id
// entirely until one is minted, so non-fifo buffers pay nothing.
@(private)
buffer_utils_clear_values :: proc(buf: ^Buffer) {
	for buffer_utils_fifo_id_made {
		id := buffer_utils_fifo_watcher_id
		stored, ok := buf.values[id]
		if !ok {
			break
		}
		fifo, cast_err := value_as(stored, Buffer_Utils_Fifo_Watcher)
		assert(cast_err == .None)
		buffer_utils_fifo_close(fifo)
	}
	for _, &stored in buf.values {
		value_free(&stored, buf.allocator)
	}
	clear(&buf.values)
}

// buffer_utils_create_fifo_buffer registers (or resets) a fifo buffer
// reading fd (port of C++ create_fifo_buffer()). An existing buffer
// is emptied and reused; a missing one is created with the Fifo and
// NoUndo flags. Requires the buffer-manager singleton and an event
// manager for the fd watcher.
buffer_utils_create_fifo_buffer :: proc(
	name: string,
	fd: int,
	flags: Buffer_Flags,
	scroll: Buffer_Utils_Auto_Scroll,
	allocator := context.allocator,
) -> (^Buffer, Buffer_Utils_Error) {
	m := buffer_manager_instance()
	buf := buffer_manager_get_ifp(m, name)
	if buf != nil {
		buf.flags |= {.No_Undo} | flags
		buffer_utils_clear_values(buf)
		lines := make(Buffer_Lines, 0, 1, buf.allocator)
		append(&lines, strings.clone("\n", buf.allocator))
		buffer_reload(buf, lines[:], .None, .Lf, .Present, File_Fs_Status{timestamp = File_Invalid_Time})
		buffer_utils_free_lines(lines, buf.allocator)
		buffer_manager_make_latest(m, buf)
	} else {
		lines := make(Buffer_Lines, 0, 1, allocator)
		append(&lines, strings.clone("\n", allocator))
		defer buffer_utils_free_lines(lines, allocator)
		created, create_err := buffer_manager_create(
			m,
			name,
			flags | {.Fifo, .No_Undo},
			lines,
			.None,
			.Lf,
			.Present,
			File_Fs_Status{timestamp = File_Invalid_Time},
		)
		if create_err != .None {
			return nil, buffer_utils_map_manager_error(create_err)
		}
		buf = created
	}
	stored := value_make(Buffer_Utils_Fifo_Watcher{buffer = buf, scroll = scroll}, buf.allocator)
	fifo, cast_err := value_as(stored, Buffer_Utils_Fifo_Watcher)
	assert(cast_err == .None)
	event_manager_fd_watcher_init(&fifo.watcher, fd, {.Read}, .Normal, buffer_utils_fifo_on_event)
	buffer_utils_fifo_register(&fifo.watcher, fifo, allocator)
	buf.values[buffer_utils_fifo_id()] = stored
	buf.flags = flags | {.Fifo, .No_Undo}
	buffer_run_hook_in_own_context(buf, .Buf_Open_Fifo, buffer_name(buf))
	return buf, .None
}

// buffer_utils_history_id_to_string formats a history id, "-" for
// invalid (port of C++ to_string(Buffer::HistoryId)).
@(private)
buffer_utils_history_id_to_string :: proc(id: Buffer_History_Id, allocator := context.allocator) -> string {
	if id == buffer_HISTORY_INVALID {
		return strings.clone("-", allocator)
	}
	return format_to_string_int(int(id), allocator)
}

// buffer_utils_modification_to_string formats one undo entry as
// "+line.column|content" (insert) or "-line.column|content" (erase),
// the C++ modification_as_string() spelling.
@(private)
buffer_utils_modification_to_string :: proc(m: Buffer_Modification, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_byte(&b, '+' if m.type == .Insert else '-')
	strings.write_string(&b, format_to_string_int(int(m.coord.line), context.temp_allocator))
	strings.write_byte(&b, '.')
	strings.write_string(&b, format_to_string_int(int(m.coord.column), context.temp_allocator))
	strings.write_byte(&b, '|')
	strings.write_string(&b, m.content)
	return strings.to_string(b)
}

// buffer_utils_history_as_strings flattens history nodes into parent
// id, commit time (whole monotonic seconds), redo id, and one entry
// per undo modification (port of C++ history_as_strings()). The
// caller owns the result strings and the list.
buffer_utils_history_as_strings :: proc(history: []Buffer_History_Node, allocator := context.allocator) -> [dynamic]string {
	res := make([dynamic]string, 0, allocator)
	for node in history {
		append(&res, buffer_utils_history_id_to_string(node.parent, allocator))
		append(&res, format_to_string_int(i64(node.committed) / 1000000000, allocator))
		append(&res, buffer_utils_history_id_to_string(node.redo_child, allocator))
		for m in node.undo_group {
			append(&res, buffer_utils_modification_to_string(m, allocator))
		}
	}
	return res
}

// buffer_utils_undo_group_as_strings formats one undo group, one
// entry per modification (port of C++ undo_group_as_strings()). The
// caller owns the result strings and the list.
buffer_utils_undo_group_as_strings :: proc(undo_group: []Buffer_Modification, allocator := context.allocator) -> [dynamic]string {
	res := make([dynamic]string, 0, allocator)
	for m in undo_group {
		append(&res, buffer_utils_modification_to_string(m, allocator))
	}
	return res
}

// buffer_utils_generate_buffer_name expands pattern (a "{}" format
// holding an integer) into the first name no live buffer uses (port
// of C++ generate_buffer_name()). Requires the buffer-manager
// singleton. The caller owns the result.
buffer_utils_generate_buffer_name :: proc(pattern: string, allocator := context.allocator) -> string {
	m := buffer_manager_instance()
	i := 0
	for {
		num := format_to_string_int(i, context.temp_allocator)
		name, format_err := format_format(pattern, {num}, allocator)
		if format_err != .None {
			delete(name, allocator)
			name = strings.clone(pattern, allocator)
		}
		if buffer_manager_get_ifp(m, name) == nil {
			return name
		}
		delete(name, allocator)
		i += 1
	}
}
