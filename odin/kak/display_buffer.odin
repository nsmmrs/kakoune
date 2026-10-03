// Port of Kakoune's src/display_buffer.{hh,cc} (DisplayAtom,
// DisplayLine, DisplayBuffer, parse_display_line).
//
// Mapping notes:
//   * Display_Atom, Display_Line, Display_Buffer and Buffer_Iterator
//     live in knot.odin (coordinator-owned); only procedures are here.
//   * C++ atom iterators become plain indices into Display_Line.atoms.
//     Split/insert/erase return the index of the first affected atom,
//     mirroring the returned C++ iterator.
//   * Buffer text is read straight from Buffer.lines (knot.odin owns
//     the struct, no buffer-module procedures are needed): newlines
//     between lines are implicit and contribute no columns, exactly
//     like C++ BufferIterator iteration, which never yields '\n'.
//   * C++ runtime_error throws in parse become Display_Buffer_Error.
//   * Ownership: atoms borrow their strings. Procs that must allocate
//     (optimize text merges, trim padding, parse content) take an
//     explicit allocator; the caller owns those strings (delete them
//     or use context.temp_allocator).
package kak

import "core:mem"
import "core:strings"

// Display_Buffer_Error reports parse failures (port of the
// runtime_error throws in parse_display_line).
Display_Buffer_Error :: enum {
	None,
	Unclosed_Face,
	Undefined_Atom,
	Invalid_Face,
}

// display_buffer_atom_range builds a Range atom over a buffer range
// (port of the DisplayAtom(buffer, range, face) constructor).
display_buffer_atom_range :: proc(buffer: ^Buffer, r: Buffer_Range, face: Face) -> Display_Atom {
	return Display_Atom{face = face, type = .Range, buffer = buffer, range = r}
}

// display_buffer_atom_replaced builds a ReplacedRange atom: a buffer
// range displayed as text (port of the DisplayAtom(buffer, range,
// str, face) constructor).
display_buffer_atom_replaced :: proc(buffer: ^Buffer, r: Buffer_Range, text: string, face: Face) -> Display_Atom {
	return Display_Atom{face = face, type = .Replaced_Range, buffer = buffer, range = r, text = text}
}

// display_buffer_atom_text builds a Text atom (port of the
// DisplayAtom(str, face) constructors).
display_buffer_atom_text :: proc(text: string, face: Face) -> Display_Atom {
	return Display_Atom{face = face, type = .Text, text = text}
}

// display_buffer_atom_content returns the atom's displayed text. A
// Range atom must sit on one line (or end at column 0 of the next
// line); anything else yields "" (port of DisplayAtom::content,
// whose release build returns {} past its assert).
display_buffer_atom_content :: proc(atom: Display_Atom) -> string {
	if atom.type == .Range {
		line := atom.buffer.lines[int(atom.range.begin.line)]
		if atom.range.begin.line == atom.range.end.line {
			return line[int(atom.range.begin.column):int(atom.range.end.column)]
		}
		if atom.range.begin.line + 1 == atom.range.end.line && atom.range.end.column == 0 {
			return line[int(atom.range.begin.column):]
		}
		return ""
	}
	return atom.text
}

// display_buffer_atom_length returns the atom's width in display
// columns (port of DisplayAtom::length).
display_buffer_atom_length :: proc(atom: Display_Atom) -> Coord_Column {
	if atom.type == .Range {
		return display_buffer_range_columns(atom.buffer, atom.range.begin, atom.range.end)
	}
	return display_buffer_text_columns(atom.text)
}

// display_buffer_atom_empty reports whether the atom displays
// nothing (port of DisplayAtom::empty).
display_buffer_atom_empty :: proc(atom: Display_Atom) -> bool {
	if atom.type == .Range {
		return atom.range.begin == atom.range.end
	}
	return len(atom.text) == 0
}

// display_buffer_atom_has_range reports whether the atom refers to a
// buffer range (port of DisplayAtom::has_buffer_range).
display_buffer_atom_has_range :: proc(atom: Display_Atom) -> bool {
	return atom.type == .Range || atom.type == .Replaced_Range
}

// display_buffer_atom_replace_text swaps the atom's displayed text,
// turning a Range into a ReplacedRange (port of
// DisplayAtom::replace(String)).
display_buffer_atom_replace_text :: proc(atom: ^Display_Atom, text: string) {
	if atom.type == .Range {
		atom.type = .Replaced_Range
	}
	atom.text = text
}

// display_buffer_atom_replace_range attaches a buffer range to a
// Text atom, turning it into a ReplacedRange (port of
// DisplayAtom::replace(BufferRange)).
display_buffer_atom_replace_range :: proc(atom: ^Display_Atom, r: Buffer_Range) {
	assert(atom.type == .Text)
	atom.type = .Replaced_Range
	atom.range = r
}

// display_buffer_atom_equal compares face, type and content, like
// C++ DisplayAtom::operator== (raw ranges are NOT compared).
display_buffer_atom_equal :: proc(a, b: Display_Atom) -> bool {
	return a.face == b.face && a.type == b.type && display_buffer_atom_content(a) == display_buffer_atom_content(b)
}

// display_buffer_atom_trim_begin drops the first count columns and
// returns the columns actually removed, which may overshoot count
// inside a wide codepoint (port of DisplayAtom::trim_begin).
display_buffer_atom_trim_begin :: proc(atom: ^Display_Atom, count: Coord_Column) -> Coord_Column {
	res: Coord_Column = 0
	if atom.type == .Range {
		end := display_buffer_normalize_coord(atom.buffer, atom.range.end)
		coord := display_buffer_normalize_coord(atom.buffer, atom.range.begin)
		for coord != end && res < count {
			line := atom.buffer.lines[int(coord.line)]
			pos := int(coord.column)
			if pos >= len(line) {
				coord = Coord_Buffer{coord.line + 1, 0}
				continue
			}
			cp := utf8_read_codepoint(line, &pos)
			res += Coord_Column(unicode_codepoint_width(cp))
			coord = Coord_Buffer{coord.line, Coord_Byte(pos)}
		}
		atom.range.begin = display_buffer_min_coord(coord, atom.range.end)
	} else {
		pos := 0
		for pos < len(atom.text) && res < count {
			cp := utf8_read_codepoint(atom.text, &pos)
			res += Coord_Column(unicode_codepoint_width(cp))
		}
		atom.text = atom.text[pos:]
	}
	return res
}

// display_buffer_atom_trim_end keeps at most the first count columns
// and returns the columns kept, which may overshoot count inside a
// wide codepoint (port of DisplayAtom::trim_end_to_length).
display_buffer_atom_trim_end :: proc(atom: ^Display_Atom, count: Coord_Column) -> Coord_Column {
	res: Coord_Column = 0
	if atom.type == .Range {
		end := display_buffer_normalize_coord(atom.buffer, atom.range.end)
		coord := display_buffer_normalize_coord(atom.buffer, atom.range.begin)
		for coord != end && res < count {
			line := atom.buffer.lines[int(coord.line)]
			pos := int(coord.column)
			if pos >= len(line) {
				coord = Coord_Buffer{coord.line + 1, 0}
				continue
			}
			cp := utf8_read_codepoint(line, &pos)
			res += Coord_Column(unicode_codepoint_width(cp))
			coord = Coord_Buffer{coord.line, Coord_Byte(pos)}
		}
		atom.range.end = display_buffer_min_coord(coord, atom.range.end)
	} else {
		pos := 0
		for pos < len(atom.text) && res < count {
			cp := utf8_read_codepoint(atom.text, &pos)
			res += Coord_Column(unicode_codepoint_width(cp))
		}
		atom.text = atom.text[:pos]
	}
	return res
}

// display_buffer_get_iterator returns a buffer iterator position for
// coord, folding a one-past-end-of-line coord onto the next line
// (port of get_iterator).
display_buffer_get_iterator :: proc(buffer: ^Buffer, coord: Coord_Buffer) -> Buffer_Iterator {
	adjusted := display_buffer_normalize_coord(buffer, coord)
	line := ""
	if int(adjusted.line) < len(buffer.lines) {
		line = buffer.lines[int(adjusted.line)]
	}
	return Buffer_Iterator{
		lines      = buffer.lines[:],
		line       = line,
		line_count = Units_LineCount(len(buffer.lines)),
		coord      = adjusted,
	}
}

// display_buffer_line_make builds an empty line (port of the default
// DisplayLine constructor; the range starts as the inverted init
// range). Destroy with display_buffer_line_destroy.
display_buffer_line_make :: proc(allocator := context.allocator) -> Display_Line {
	return Display_Line{range = display_buffer_init_range(), atoms = make([dynamic]Display_Atom, allocator)}
}

// display_buffer_line_make_atoms builds a line from atoms (port of
// the DisplayLine(AtomList) constructor, which computes the range).
display_buffer_line_make_atoms :: proc(atoms: []Display_Atom, allocator := context.allocator) -> Display_Line {
	line := Display_Line{
		range = display_buffer_init_range(),
		atoms = make([dynamic]Display_Atom, len(atoms), allocator),
	}
	copy(line.atoms[:], atoms)
	display_buffer_line_compute_range(&line, false)
	return line
}

// display_buffer_line_make_text builds a single-atom line (port of
// the DisplayLine(String, Face) constructor).
display_buffer_line_make_text :: proc(text: string, face: Face, allocator := context.allocator) -> Display_Line {
	line := display_buffer_line_make(allocator)
	display_buffer_line_push_back(&line, display_buffer_atom_text(text, face))
	return line
}

// display_buffer_line_destroy frees the atom list. Atom strings are
// borrowed and untouched; strings owned by the caller (optimize
// merges, trim padding, parse content) must be deleted separately.
display_buffer_line_destroy :: proc(line: ^Display_Line) {
	delete(line.atoms)
}

// display_buffer_line_length sums atom widths (port of
// DisplayLine::length).
display_buffer_line_length :: proc(line: Display_Line) -> Coord_Column {
	total: Coord_Column = 0
	for atom in line.atoms {
		total += display_buffer_atom_length(atom)
	}
	return total
}

// display_buffer_line_split_coord splits the Range atom at index
// around pos and returns the index of the first half (port of
// DisplayLine::split(iterator, BufferCoord)).
display_buffer_line_split_coord :: proc(line: ^Display_Line, index: int, pos: Coord_Buffer) -> int {
	assert(line.atoms[index].type == .Range)
	assert(coord_compare(line.atoms[index].range.begin, pos) < 0)
	assert(coord_compare(line.atoms[index].range.end, pos) > 0)
	first := line.atoms[index]
	first.range.end = pos
	line.atoms[index].range.begin = pos
	inject_at(&line.atoms, index, first)
	return index
}

// display_buffer_line_split_col splits the atom at index after count
// columns and returns the index of the first half (port of
// DisplayLine::split(iterator, ColumnCount)).
display_buffer_line_split_col :: proc(line: ^Display_Line, index: int, count: Coord_Column) -> int {
	assert(count > 0)
	assert(count < display_buffer_atom_length(line.atoms[index]))
	if line.atoms[index].type == .Text || line.atoms[index].type == .Replaced_Range {
		first := line.atoms[index]
		off := display_buffer_advance_text(first.text, count)
		first.text = first.text[:off]
		line.atoms[index].text = line.atoms[index].text[off:]
		inject_at(&line.atoms, index, first)
		return index
	}
	atom := line.atoms[index]
	pos := display_buffer_advance_buffer(atom.buffer, atom.range.begin, atom.range.end, count)
	if pos == atom.range.begin {
		inject_at(
			&line.atoms,
			index,
			display_buffer_atom_range(atom.buffer, Buffer_Range{pos, pos}, atom.face),
		)
		return index
	}
	if pos == atom.range.end {
		inject_at(
			&line.atoms,
			index + 1,
			display_buffer_atom_range(atom.buffer, Buffer_Range{pos, pos}, atom.face),
		)
		return index
	}
	return display_buffer_line_split_coord(line, index, pos)
}

// display_buffer_line_split_at splits the atom covering pos so that
// an atom boundary sits at pos, and returns the index of the atom
// starting at pos (port of DisplayLine::split(BufferCoord)).
display_buffer_line_split_at :: proc(line: ^Display_Line, pos: Coord_Buffer) -> int {
	for i in 0 ..< len(line.atoms) {
		atom := line.atoms[i]
		if (display_buffer_atom_has_range(atom) &&
			   coord_compare(atom.range.begin, pos) >= 0) ||
		   (atom.type == .Range && coord_compare(atom.range.end, pos) > 0) {
			if coord_compare(atom.range.begin, pos) >= 0 {
				return i
			}
			return display_buffer_line_split_coord(line, i, pos) + 1
		}
	}
	return len(line.atoms)
}

// display_buffer_line_insert inserts an atom and returns its index
// (port of DisplayLine::insert(iterator, DisplayAtom)).
display_buffer_line_insert :: proc(line: ^Display_Line, index: int, atom: Display_Atom) -> int {
	if display_buffer_atom_has_range(atom) {
		line.range.begin = display_buffer_min_coord(line.range.begin, atom.range.begin)
		line.range.end = display_buffer_max_coord(line.range.end, atom.range.end)
	}
	inject_at(&line.atoms, index, atom)
	return index
}

// display_buffer_line_insert_many inserts atoms at index and returns
// index (port of the DisplayLine::insert(iterator, It, It)
// template).
display_buffer_line_insert_many :: proc(line: ^Display_Line, index: int, atoms: []Display_Atom) -> int {
	had_range := false
	for atom in line.atoms {
		if display_buffer_atom_has_range(atom) {
			had_range = true
			break
		}
	}
	first := -1
	last := -1
	for i in 0 ..< len(atoms) {
		if display_buffer_atom_has_range(atoms[i]) {
			if first < 0 {
				first = i
			}
			last = i
		}
	}
	if first >= 0 {
		if had_range {
			line.range.begin = display_buffer_min_coord(line.range.begin, atoms[first].range.begin)
			line.range.end = display_buffer_max_coord(line.range.end, atoms[last].range.end)
		} else {
			line.range.begin = atoms[first].range.begin
			line.range.end = atoms[last].range.end
		}
	}
	old_len := len(line.atoms)
	resize(&line.atoms, old_len + len(atoms))
	copy(line.atoms[index + len(atoms):], line.atoms[index:old_len])
	copy(line.atoms[index:], atoms)
	return index
}

// display_buffer_line_extract moves atoms [beg, end) into a new line
// (port of DisplayLine::extract). The moved strings are shared, not
// copied; destroy the result with display_buffer_line_destroy. When
// the whole line is extracted the source keeps no atoms and its
// range resets to zero (the C++ leaves a moved-from object behind,
// which must not be reused).
display_buffer_line_extract :: proc(
	line: ^Display_Line,
	beg, end: int,
	allocator := context.allocator,
) -> Display_Line {
	if beg == 0 && end == len(line.atoms) {
		extracted := Display_Line{
			range = line.range,
			atoms = make([dynamic]Display_Atom, len(line.atoms), allocator),
		}
		copy(extracted.atoms[:], line.atoms[:])
		clear(&line.atoms)
		line.range = Buffer_Range{{0, 0}, {0, 0}}
		return extracted
	}
	extracted := Display_Line{
		range = Buffer_Range{{0, 0}, {0, 0}},
		atoms = make([dynamic]Display_Atom, end - beg, allocator),
	}
	copy(extracted.atoms[:], line.atoms[beg:end])
	display_buffer_line_compute_range(&extracted, false)
	display_buffer_remove_atoms(line, beg, end)
	if extracted.range.begin == line.range.begin || extracted.range.end == line.range.end {
		display_buffer_line_compute_range(line, true)
	}
	return extracted
}

// display_buffer_line_erase drops atoms [beg, end) and returns beg,
// the index following the removal (port of DisplayLine::erase).
display_buffer_line_erase :: proc(line: ^Display_Line, beg, end: int) -> int {
	display_buffer_remove_atoms(line, beg, end)
	display_buffer_line_compute_range(line, true)
	return beg
}

// display_buffer_line_push_back appends an atom and returns its index
// (port of DisplayLine::push_back, which returns a reference).
display_buffer_line_push_back :: proc(line: ^Display_Line, atom: Display_Atom) -> int {
	if display_buffer_atom_has_range(atom) {
		line.range.begin = display_buffer_min_coord(line.range.begin, atom.range.begin)
		line.range.end = display_buffer_max_coord(line.range.end, atom.range.end)
	}
	append(&line.atoms, atom)
	return len(line.atoms) - 1
}

// display_buffer_line_trim drops front columns from the start and
// caps the line at col_count columns, reporting whether anything was
// cut off the end (port of DisplayLine::trim). Padding is allocated
// with allocator and owned by the caller.
display_buffer_line_trim :: proc(
	line: ^Display_Line,
	front, col_count: Coord_Column,
	allocator := context.allocator,
) -> bool {
	return display_buffer_line_trim_from(line, 0, front, col_count, allocator)
}

// display_buffer_line_trim_from is trim with a first_col skip prefix
// (port of DisplayLine::trim_from).
display_buffer_line_trim_from :: proc(
	line: ^Display_Line,
	first_col, front, col_count: Coord_Column,
	allocator := context.allocator,
) -> bool {
	i := 0
	skipped := first_col
	for skipped > 0 && i < len(line.atoms) {
		atom_len := display_buffer_atom_length(line.atoms[i])
		if atom_len <= skipped {
			i += 1
			skipped -= atom_len
		} else {
			if front > 0 {
				i = display_buffer_line_split_col(line, i, front) + 1
			}
			skipped = 0
		}
	}
	front_index := i
	has_padding := false
	padding_atom: Display_Atom
	remaining := front
	for remaining > 0 && i < len(line.atoms) {
		remaining -= display_buffer_atom_trim_begin(&line.atoms[i], remaining)
		assert(display_buffer_atom_empty(line.atoms[i]) || remaining <= 0)
		if remaining < 0 {
			spaces := display_buffer_make_spaces(int(-remaining), allocator)
			if display_buffer_atom_has_range(line.atoms[i]) {
				begin := line.atoms[i].range.begin
				padding_atom = display_buffer_atom_replaced(
					line.atoms[i].buffer,
					Buffer_Range{begin, begin},
					spaces,
					line.atoms[i].face,
				)
			} else {
				padding_atom = display_buffer_atom_text(spaces, line.atoms[i].face)
			}
			has_padding = true
		}
		if display_buffer_atom_empty(line.atoms[i]) {
			i += 1
		}
	}
	display_buffer_remove_atoms(line, front_index, i)
	if has_padding {
		inject_at(&line.atoms, front_index, padding_atom)
	}
	i = 0
	columns := col_count
	for i < len(line.atoms) && columns > 0 {
		columns -= display_buffer_atom_trim_end(&line.atoms[i], columns)
		i += 1
	}
	did_trim := i < len(line.atoms) && columns == 0
	display_buffer_remove_atoms(line, i, len(line.atoms))
	display_buffer_line_compute_range(line, true)
	return did_trim
}

// display_buffer_line_optimize merges consecutive atoms that share
// type and face (port of DisplayLine::optimize). Merged text is
// allocated with allocator and owned by the caller.
display_buffer_line_optimize :: proc(line: ^Display_Line, allocator := context.allocator) {
	if len(line.atoms) == 0 {
		return
	}
	write := 0
	for read in 1 ..< len(line.atoms) {
		atom := &line.atoms[write]
		next := line.atoms[read]
		if atom.type == next.type && atom.face == next.face {
			merged := false
			if atom.type == .Text {
				atom.text = strings.concatenate({atom.text, next.text}, allocator)
				merged = true
			} else if next.range.begin == atom.range.end {
				atom.range.end = next.range.end
				if atom.type == .Replaced_Range {
					atom.text = strings.concatenate({atom.text, next.text}, allocator)
				}
				merged = true
			}
			if !merged {
				write += 1
				if write != read {
					line.atoms[write] = next
				}
			}
		} else {
			write += 1
			if write != read {
				line.atoms[write] = next
			}
		}
	}
	resize(&line.atoms, write + 1)
}

// display_buffer_make builds an empty buffer (port of the default
// DisplayBuffer constructor). Destroy with display_buffer_destroy.
display_buffer_make :: proc(allocator := context.allocator) -> Display_Buffer {
	return Display_Buffer{lines = make(Display_Line_List, allocator), timestamp = -1}
}

// display_buffer_destroy frees the line list and every line's atoms.
// Atom strings are borrowed and untouched (see
// display_buffer_line_destroy).
display_buffer_destroy :: proc(buf: ^Display_Buffer) {
	for &line in buf.lines {
		display_buffer_line_destroy(&line)
	}
	delete(buf.lines)
}

// display_buffer_compute_range refreshes the range covering every
// line (port of DisplayBuffer::compute_range).
display_buffer_compute_range :: proc(buf: ^Display_Buffer) {
	buf.range = display_buffer_init_range()
	for line in buf.lines {
		buf.range.begin = display_buffer_min_coord(line.range.begin, buf.range.begin)
		buf.range.end = display_buffer_max_coord(line.range.end, buf.range.end)
	}
	if buf.range == display_buffer_init_range() {
		buf.range = Buffer_Range{{0, 0}, {0, 0}}
	}
}

// display_buffer_optimize optimizes every line (port of
// DisplayBuffer::optimize). Merged text is allocated with allocator
// and owned by the caller.
display_buffer_optimize :: proc(buf: ^Display_Buffer, allocator := context.allocator) {
	for &line in buf.lines {
		display_buffer_line_optimize(&line, allocator)
	}
}

// display_buffer_parse_line parses face-markup text into a line
// (port of parse_display_line(StringView, FaceRegistry, builtins)).
// Content strings are allocated with allocator and owned by the
// caller; atoms copied from builtins keep borrowing the builtins.
display_buffer_parse_line :: proc(
	line: string,
	faces: ^Face_Registry,
	builtins: map[string]Display_Line = nil,
	allocator := context.allocator,
) -> (Display_Line, Display_Buffer_Error) {
	face := Face{}
	return display_buffer_parse_line_with_face(line, &face, faces, builtins, allocator)
}

// display_buffer_parse_line_with_face is parse with a carried face:
// face^ seeds the initial face and receives the trailing one (port
// of the static parse_display_line(StringView, Face&, ...) helper).
display_buffer_parse_line_with_face :: proc(
	line: string,
	face: ^Face,
	faces: ^Face_Registry,
	builtins: map[string]Display_Line = nil,
	allocator := context.allocator,
) -> (Display_Line, Display_Buffer_Error) {
	res := display_buffer_line_make(allocator)
	content: strings.Builder
	strings.builder_init(&content, allocator)
	defer strings.builder_destroy(&content)
	// to_string only views the builder buffer, so clone before the
	// reset below reuses it.
	flush := proc(res: ^Display_Line, content: ^strings.Builder, face: Face, allocator: mem.Allocator) {
		if strings.builder_len(content^) > 0 {
			display_buffer_line_push_back(
				res,
				display_buffer_atom_text(strings.clone(strings.to_string(content^), allocator), face),
			)
			strings.builder_reset(content)
		}
	}
	was_antislash := false
	pos := 0
	i := 0
	for i < len(line) {
		c := line[i]
		if c == '{' {
			if was_antislash {
				// The segment ends with the escaping backslash;
				// rewrite it as a literal '{'.
				strings.write_string(&content, line[pos:i - 1])
				strings.write_byte(&content, '{')
				pos = i + 1
			} else {
				strings.write_string(&content, line[pos:i])
				flush(&res, &content, face^, allocator)
				closing := -1
				for j in i + 1 ..< len(line) {
					if line[j] == '}' {
						closing = j
						break
					}
				}
				if closing < 0 {
					display_buffer_line_destroy(&res)
					return res, .Unclosed_Face
				}
				if i + 1 < len(line) && line[i + 1] == '{' && closing + 1 < len(line) &&
				   line[closing + 1] == '}' {
					builtin, ok := builtins[line[i + 2:closing]]
					if !ok {
						display_buffer_line_destroy(&res)
						return res, .Undefined_Atom
					}
					for atom in builtin.atoms {
						display_buffer_line_push_back(&res, atom)
					}
					closing += 1
				} else if closing == i + 2 && line[i + 1] == '\\' {
					pos = closing + 1
					break
				} else {
					parsed, err := face_registry_lookup(faces, line[i + 1:closing], allocator)
					if err != .None {
						display_buffer_line_destroy(&res)
						return res, .Invalid_Face
					}
					face^ = parsed
				}
				i = closing
				pos = closing + 1
			}
		}
		if c == '\n' || c == '\t' {
			// Line breaks and tabs are forbidden, replace with space.
			strings.write_string(&content, line[pos:i])
			strings.write_byte(&content, ' ')
			pos = i + 1
		}
		if c == '\\' {
			if was_antislash {
				strings.write_string(&content, line[pos:i])
				pos = i + 1
				was_antislash = false
			} else {
				was_antislash = true
			}
		} else {
			was_antislash = false
		}
		i += 1
	}
	strings.write_string(&content, line[pos:])
	flush(&res, &content, face^, allocator)
	return res, .None
}

// display_buffer_parse_line_list parses newline-separated markup
// into lines, carrying the face across lines (port of
// parse_display_line_list).
display_buffer_parse_line_list :: proc(
	content: string,
	faces: ^Face_Registry,
	builtins: map[string]Display_Line = nil,
	allocator := context.allocator,
) -> (Display_Line_List, Display_Buffer_Error) {
	lines := make(Display_Line_List, allocator)
	if len(content) == 0 {
		return lines, .None
	}
	face := Face{}
	start := 0
	for {
		end := len(content)
		for j in start ..< len(content) {
			if content[j] == '\n' {
				end = j
				break
			}
		}
		parsed, err := display_buffer_parse_line_with_face(content[start:end], &face, faces, builtins, allocator)
		if err != .None {
			for &line in lines {
				display_buffer_line_destroy(&line)
			}
			delete(lines)
			return nil, err
		}
		append(&lines, parsed)
		if end == len(content) {
			break
		}
		start = end + 1
	}
	return lines, .None
}

// display_buffer_init_range is the inverted sentinel range fresh
// lines and buffers start with (port of init_range).
@(private = "file")
display_buffer_init_range :: proc() -> Buffer_Range {
	return Buffer_Range{
		{Coord_Line(max(int)), Coord_Byte(max(int))},
		{Coord_Line(min(int)), Coord_Byte(min(int))},
	}
}

// display_buffer_min_coord orders buffer coords lexicographically
// (port of std::min on BufferCoord).
@(private = "file")
display_buffer_min_coord :: proc(a, b: Coord_Buffer) -> Coord_Buffer {
	if coord_compare(a, b) <= 0 {
		return a
	}
	return b
}

// display_buffer_max_coord orders buffer coords lexicographically
// (port of std::max on BufferCoord).
@(private = "file")
display_buffer_max_coord :: proc(a, b: Coord_Buffer) -> Coord_Buffer {
	if coord_compare(a, b) >= 0 {
		return a
	}
	return b
}

// display_buffer_normalize_coord folds a one-past-end-of-line coord
// onto the next line, like get_iterator does before iterating.
@(private = "file")
display_buffer_normalize_coord :: proc(buffer: ^Buffer, coord: Coord_Buffer) -> Coord_Buffer {
	if int(coord.line) < len(buffer.lines) &&
	   int(coord.column) == len(buffer.lines[int(coord.line)]) {
		return Coord_Buffer{coord.line + 1, 0}
	}
	return coord
}

// display_buffer_text_columns sums codepoint widths (port of
// utf8::column_distance over a string).
@(private = "file")
display_buffer_text_columns :: proc(s: string) -> Coord_Column {
	total: Coord_Column = 0
	pos := 0
	for pos < len(s) {
		cp := utf8_read_codepoint(s, &pos)
		total += Coord_Column(unicode_codepoint_width(cp))
	}
	return total
}

// display_buffer_range_columns sums codepoint widths between two
// buffer coords; line breaks are implicit and widthless, matching
// C++ BufferIterator traversal (port of utf8::column_distance over
// buffer iterators).
@(private = "file")
display_buffer_range_columns :: proc(buffer: ^Buffer, begin, end: Coord_Buffer) -> Coord_Column {
	begin_norm := display_buffer_normalize_coord(buffer, begin)
	end_norm := display_buffer_normalize_coord(buffer, end)
	total: Coord_Column = 0
	coord := begin_norm
	for coord != end_norm {
		line := buffer.lines[int(coord.line)]
		pos := int(coord.column)
		if pos >= len(line) {
			coord = Coord_Buffer{coord.line + 1, 0}
			continue
		}
		cp := utf8_read_codepoint(line, &pos)
		total += Coord_Column(unicode_codepoint_width(cp))
		coord = Coord_Buffer{coord.line, Coord_Byte(pos)}
	}
	return total
}

// display_buffer_advance_text returns the byte offset count columns
// into s, stepping back out of a partially covered wide codepoint
// (port of utf8::advance over string iterators).
@(private = "file")
display_buffer_advance_text :: proc(s: string, count: Coord_Column) -> int {
	pos := 0
	if pos >= len(s) {
		return pos
	}
	remaining := count
	for remaining > 0 && pos < len(s) {
		prev := pos
		cp := utf8_read_codepoint(s, &pos)
		remaining -= Coord_Column(unicode_codepoint_width(cp))
		if pos < len(s) && remaining < 0 {
			pos = prev
		}
	}
	return pos
}

// display_buffer_advance_buffer advances count columns from begin
// toward end, stepping back out of a partially covered wide
// codepoint (port of utf8::advance over buffer iterators).
@(private = "file")
display_buffer_advance_buffer :: proc(
	buffer: ^Buffer,
	begin, end: Coord_Buffer,
	count: Coord_Column,
) -> Coord_Buffer {
	end_norm := display_buffer_normalize_coord(buffer, end)
	coord := display_buffer_normalize_coord(buffer, begin)
	if coord == end_norm {
		return coord
	}
	remaining := count
	for remaining > 0 && coord != end_norm {
		line := buffer.lines[int(coord.line)]
		pos := int(coord.column)
		if pos >= len(line) {
			coord = Coord_Buffer{coord.line + 1, 0}
			continue
		}
		prev := coord
		cp := utf8_read_codepoint(line, &pos)
		remaining -= Coord_Column(unicode_codepoint_width(cp))
		coord = Coord_Buffer{coord.line, Coord_Byte(pos)}
		if coord != end_norm && remaining < 0 {
			coord = prev
		}
	}
	return coord
}

// display_buffer_line_compute_range refreshes the range from the
// first/last ranged atoms (port of DisplayLine::compute_range).
@(private = "file")
display_buffer_line_compute_range :: proc(line: ^Display_Line, preserve := false) {
	first := -1
	last := -1
	for i in 0 ..< len(line.atoms) {
		if display_buffer_atom_has_range(line.atoms[i]) {
			if first < 0 {
				first = i
			}
			last = i
		}
	}
	if first < 0 {
		if !(preserve && line.range != display_buffer_init_range()) {
			line.range = Buffer_Range{{0, 0}, {0, 0}}
		}
	} else {
		line.range.begin = line.atoms[first].range.begin
		line.range.end = line.atoms[last].range.end
	}
}

// display_buffer_remove_atoms drops atoms [beg, end) without touching
// the range (port of direct AtomList::erase calls).
@(private = "file")
display_buffer_remove_atoms :: proc(line: ^Display_Line, beg, end: int) {
	copy(line.atoms[beg:], line.atoms[end:])
	resize(&line.atoms, len(line.atoms) - (end - beg))
}

// display_buffer_make_spaces builds a padding run (port of
// String{' ', n}).
@(private = "file")
display_buffer_make_spaces :: proc(n: int, allocator := context.allocator) -> string {
	buf := make([]byte, n, allocator)
	for i in 0 ..< n {
		buf[i] = ' '
	}
	return string(buf)
}
