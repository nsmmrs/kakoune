// Port of Kakoune's src/remote.{hh,cc}: the client/server protocol.
//
// Message framing: every message is a MessageType byte followed by a
// u32 total size (both included in the size), then the fields. Writer
// procs append fields to a Remote_Buffer and patch the size on
// remote_msg_writer_end (port of MsgWriter's destructor patch).
// Reader procs consume fields from a Remote_Msg_Reader with bounds
// checks; short reads and bad sizes yield .Bad_Frame (port of the
// `disconnected` throws in MsgReader).
//
// Wire compatibility: integers are C++-width (i32/u32 for int and the
// unit types, u8 for MessageType, 1 byte for bool), little-endian
// like the C++ memcpy writes. Face is the raw 16-byte C++ layout
// (fg, bg, attributes as i32, underline) with the Odin attribute
// flags mapped onto the C++ bit positions (C++ bit N+1). Key is i32
// modifiers plus the i32 codepoint. Strings are an i32 byte length
// plus the bytes; vectors and maps are a u32 count plus the items;
// optionals are a bool plus the value when present.
//
// Remote_UI implements the merged User_Interface vtable for a
// server-side client (port of RemoteUI). The vtable's opaque display
// placeholders are the real Display_Line/Display_Buffer values (see
// KNOTFIX_ui_line in client.odin), unwrapped here for encoding.
//
// Ownership: init procs take `allocator` and every owned value is
// released by the matching destroy proc with the same allocator.
// Decoded strings, atoms, lines, buffers and maps are owned by the
// caller; display values are freed with the remote_destroy_* helpers
// (atom text is owned here, unlike display_buffer_line_destroy's
// borrowed convention), maps with env_vars_free. Remote_Client.ui is
// borrowed. Remote_UI owns its watcher, reader, send buffer and the
// ui handle; the ui handle is freed by client_destroy while the
// Remote_UI itself needs remote_ui_destroy. Sockets held by watchers
// are closed exactly where the C++ closes them (close_fd call sites);
// destroying a watcher never closes, matching ~FDWatcher.
//
// Event callbacks are plain procs (no closures), so watchers are
// linked to their owners through the remote_watcher_owners registry.
// Remote_Client additionally needs a process-level trampoline for the
// UI on_key/on_paste callbacks, which carry no user data: there is at
// most one RemoteClient per (client) process, like the C++.
//
// Deviations: connect failures close the just-opened socket (the C++
// leaks it). Unknown bits in a wire Face's attributes are dropped.
// Unknown received message types on the client side log and continue
// past an assert (kak_assert(false) parity).
package kak

import "core:mem"
import "core:strings"
import posix "core:sys/posix"

// Remote_Error reports remote failures. Zero value `None` is success.
Remote_Error :: enum {
	None,
	// remote_session_path: the session name holds characters outside
	// [A-Za-z0-9_-] (C++ throws runtime_error).
	Invalid_Session_Name,
	// remote_session_path: the socket path does not fit sun_path
	// (C++ throws runtime_error).
	Socket_Path_Too_Long,
	// socket() failed.
	Socket_Create,
	// bind() on the session socket failed.
	Bind,
	// listen() on the session socket failed.
	Listen,
	// accept() on the session socket failed.
	Accept,
	// connect() to the session socket failed (C++ disconnected).
	Connect,
	// Socket read/write failed, or the peer went away (port of the
	// C++ `disconnected` exception).
	Disconnected,
	// A received message is malformed: size below the header size,
	// a negative string length, or a read past the message end
	// (C++ throws disconnected for these too).
	Bad_Frame,
}

// Remote_Message_Type is the protocol message tag (port of
// remote.cc MessageType). The order matches the C++ declaration.
Remote_Message_Type :: enum u8 {
	Unknown,
	Connect,
	Command,
	Menu_Show,
	Menu_Select,
	Menu_Hide,
	Info_Show,
	Info_Hide,
	Draw,
	Draw_Status,
	Refresh,
	Set_Options,
	Exit,
	Key,
	Paste,
}

// remote_HEADER_SIZE is the framed header: one MessageType byte plus
// the u32 total message size.
remote_HEADER_SIZE :: 1 + 4

// ---------------------------------------------------------------------------
// Writer
// ---------------------------------------------------------------------------

// Remote_Msg_Writer appends one message to a send buffer (port of
// MsgWriter). Begin with remote_msg_writer_begin, append fields with
// the remote_msg_write_* procs, then remote_msg_writer_end patches
// the size prefix. Growth uses allocator.
Remote_Msg_Writer :: struct {
	buffer:    ^Remote_Buffer,
	start:     int,
	allocator: mem.Allocator,
}

// remote_msg_writer_begin starts a message of the given type.
remote_msg_writer_begin :: proc(buffer: ^Remote_Buffer, type: Remote_Message_Type, allocator := context.allocator) -> Remote_Msg_Writer {
	context.allocator = allocator
	append(buffer, u8(type), 0, 0, 0, 0)
	return Remote_Msg_Writer{buffer = buffer, start = len(buffer) - remote_HEADER_SIZE, allocator = allocator}
}

// remote_msg_writer_end patches the message size prefix (port of
// ~MsgWriter).
remote_msg_writer_end :: proc(w: ^Remote_Msg_Writer) {
	count := u32(len(w.buffer) - w.start)
	w.buffer[w.start + 1] = u8(count)
	w.buffer[w.start + 2] = u8(count >> 8)
	w.buffer[w.start + 3] = u8(count >> 16)
	w.buffer[w.start + 4] = u8(count >> 24)
}

// remote_msg_write_raw appends raw bytes.
remote_msg_write_raw :: proc(w: ^Remote_Msg_Writer, data: []byte) {
	context.allocator = w.allocator
	append(w.buffer, ..data)
}

// remote_msg_write_u8 appends one byte.
remote_msg_write_u8 :: proc(w: ^Remote_Msg_Writer, v: u8) {
	context.allocator = w.allocator
	append(w.buffer, v)
}

// remote_msg_write_u32 appends a u32, little-endian like the C++.
remote_msg_write_u32 :: proc(w: ^Remote_Msg_Writer, v: u32) {
	context.allocator = w.allocator
	append(w.buffer, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))
}

// remote_msg_write_i32 appends an i32 (port of writing a C++ int).
remote_msg_write_i32 :: proc(w: ^Remote_Msg_Writer, v: i32) {
	remote_msg_write_u32(w, cast(u32)v)
}

// remote_msg_write_bool appends a bool as one byte (port of the C++
// bool write).
remote_msg_write_bool :: proc(w: ^Remote_Msg_Writer, v: bool) {
	remote_msg_write_u8(w, u8(v ? 1 : 0))
}

// remote_msg_write_string appends a string as an i32 byte length plus
// the bytes (port of the StringView write, whose length is ByteCount).
remote_msg_write_string :: proc(w: ^Remote_Msg_Writer, s: string) {
	remote_msg_write_i32(w, i32(len(s)))
	remote_msg_write_raw(w, transmute([]byte)s)
}

// remote_msg_write_key appends a key: i32 modifiers plus the i32
// codepoint (port of the trivially-copyable Key write).
remote_msg_write_key :: proc(w: ^Remote_Msg_Writer, key: Keys_Key) {
	remote_msg_write_i32(w, i32(key.modifiers))
	remote_msg_write_i32(w, i32(key.key))
}

// remote_msg_write_color appends a color as the tag byte plus r, g, b
// when it is an RGB color (port of the Color write; the alpha channel
// is not transmitted, like the C++).
remote_msg_write_color :: proc(w: ^Remote_Msg_Writer, c: Color) {
	remote_msg_write_u8(w, c.a)
	if color_is_rgb(c) {
		remote_msg_write_u8(w, c.r)
		remote_msg_write_u8(w, c.g)
		remote_msg_write_u8(w, c.b)
	}
}

// remote_face_attributes_to_wire maps Odin attribute flags onto the
// C++ Attribute bit positions (Odin bit N is C++ bit N+1).
remote_face_attributes_to_wire :: proc(attrs: Face_Attribute) -> i32 {
	v := i32(0)
	if .Underline in attrs { v |= 1 << 1 }
	if .Curly_Underline in attrs { v |= 1 << 2 }
	if .Double_Underline in attrs { v |= 1 << 3 }
	if .Reverse in attrs { v |= 1 << 4 }
	if .Blink in attrs { v |= 1 << 5 }
	if .Bold in attrs { v |= 1 << 6 }
	if .Dim in attrs { v |= 1 << 7 }
	if .Italic in attrs { v |= 1 << 8 }
	if .Strikethrough in attrs { v |= 1 << 9 }
	if .Final_Fg in attrs { v |= 1 << 10 }
	if .Final_Bg in attrs { v |= 1 << 11 }
	if .Final_Attr in attrs { v |= 1 << 12 }
	return v
}

// remote_face_attributes_from_wire maps C++ Attribute bits back onto
// Odin flags. Unknown bits are dropped.
remote_face_attributes_from_wire :: proc(v: i32) -> Face_Attribute {
	attrs := Face_Attribute{}
	if v & (1 << 1) != 0 { attrs += {.Underline} }
	if v & (1 << 2) != 0 { attrs += {.Curly_Underline} }
	if v & (1 << 3) != 0 { attrs += {.Double_Underline} }
	if v & (1 << 4) != 0 { attrs += {.Reverse} }
	if v & (1 << 5) != 0 { attrs += {.Blink} }
	if v & (1 << 6) != 0 { attrs += {.Bold} }
	if v & (1 << 7) != 0 { attrs += {.Dim} }
	if v & (1 << 8) != 0 { attrs += {.Italic} }
	if v & (1 << 9) != 0 { attrs += {.Strikethrough} }
	if v & (1 << 10) != 0 { attrs += {.Final_Fg} }
	if v & (1 << 11) != 0 { attrs += {.Final_Bg} }
	if v & (1 << 12) != 0 { attrs += {.Final_Attr} }
	return attrs
}

// remote_msg_write_face appends a face as the raw 16-byte C++ layout:
// fg, bg, attributes as i32, underline (port of the
// trivially-copyable Face write).
remote_msg_write_face :: proc(w: ^Remote_Msg_Writer, f: Face) {
	for c in ([4]u8{f.fg.a, f.fg.r, f.fg.g, f.fg.b}) {
		remote_msg_write_u8(w, c)
	}
	for c in ([4]u8{f.bg.a, f.bg.r, f.bg.g, f.bg.b}) {
		remote_msg_write_u8(w, c)
	}
	remote_msg_write_i32(w, remote_face_attributes_to_wire(f.attributes))
	for c in ([4]u8{f.underline.a, f.underline.r, f.underline.g, f.underline.b}) {
		remote_msg_write_u8(w, c)
	}
}

// remote_msg_write_coord_display appends a display coord as two i32s.
remote_msg_write_coord_display :: proc(w: ^Remote_Msg_Writer, c: Coord_Display) {
	remote_msg_write_i32(w, i32(c.line))
	remote_msg_write_i32(w, i32(c.column))
}

// remote_msg_write_coord_buffer appends a buffer coord as two i32s.
remote_msg_write_coord_buffer :: proc(w: ^Remote_Msg_Writer, c: Coord_Buffer) {
	remote_msg_write_i32(w, i32(c.line))
	remote_msg_write_i32(w, i32(c.column))
}

// remote_msg_write_display_atom appends an atom as its content string
// plus its face (port of the DisplayAtom write).
remote_msg_write_display_atom :: proc(w: ^Remote_Msg_Writer, atom: Display_Atom) {
	remote_msg_write_string(w, display_buffer_atom_content(atom))
	remote_msg_write_face(w, atom.face)
}

// remote_msg_write_display_line appends a line as its atom vector
// (port of the DisplayLine write).
remote_msg_write_display_line :: proc(w: ^Remote_Msg_Writer, line: Display_Line) {
	remote_msg_write_u32(w, u32(len(line.atoms)))
	for &atom in line.atoms {
		remote_msg_write_display_atom(w, atom)
	}
}

// remote_msg_write_display_lines appends a line vector (port of the
// ArrayView<DisplayLine> and DisplayLineList writes).
remote_msg_write_display_lines :: proc(w: ^Remote_Msg_Writer, lines: []Display_Line) {
	remote_msg_write_u32(w, u32(len(lines)))
	for &line in lines {
		remote_msg_write_display_line(w, line)
	}
}

// remote_msg_write_display_buffer appends a display buffer as its
// line vector (port of the DisplayBuffer write).
remote_msg_write_display_buffer :: proc(w: ^Remote_Msg_Writer, db: Display_Buffer) {
	remote_msg_write_display_lines(w, db.lines[:])
}

// remote_msg_write_menu_style appends a menu style as an i32 ordinal
// (port of the C++ MenuStyle write).
remote_msg_write_menu_style :: proc(w: ^Remote_Msg_Writer, style: User_Interface_Menu_Style) {
	remote_msg_write_i32(w, i32(style))
}

// remote_msg_write_info_style appends an info style as an i32 ordinal
// (port of the C++ InfoStyle write).
remote_msg_write_info_style :: proc(w: ^Remote_Msg_Writer, style: User_Interface_Info_Style) {
	remote_msg_write_i32(w, i32(style))
}

// remote_msg_write_status_style appends a status style as an i32
// ordinal (port of the C++ StatusStyle write).
remote_msg_write_status_style :: proc(w: ^Remote_Msg_Writer, style: User_Interface_Status_Style) {
	remote_msg_write_i32(w, i32(style))
}

// remote_msg_write_string_map appends a string map as a u32 count
// plus the key/value pairs (port of the HashMap write). Used for both
// the env vars and the UI options.
remote_msg_write_string_map :: proc(w: ^Remote_Msg_Writer, m: map[string]string) {
	remote_msg_write_u32(w, u32(len(m)))
	for k, v in m {
		remote_msg_write_string(w, k)
		remote_msg_write_string(w, v)
	}
}

// remote_msg_write_optional_coord_buffer appends an optional buffer
// coord as a bool plus the value when present (port of the
// Optional<BufferCoord> write).
remote_msg_write_optional_coord_buffer :: proc(w: ^Remote_Msg_Writer, c: Maybe(Coord_Buffer)) {
	if coord, ok := c.?; ok {
		remote_msg_write_bool(w, true)
		remote_msg_write_coord_buffer(w, coord)
	} else {
		remote_msg_write_bool(w, false)
	}
}

// ---------------------------------------------------------------------------
// Reader
// ---------------------------------------------------------------------------

// remote_msg_reader_init prepares a reader (port of MsgReader's
// empty state).
remote_msg_reader_init :: proc(r: ^Remote_Msg_Reader, allocator := context.allocator) {
	context.allocator = allocator
	r.stream = make(Remote_Buffer, allocator)
	r.read_pos = remote_HEADER_SIZE
	r.write_pos = 0
}

// remote_msg_reader_destroy releases the reader's stream.
remote_msg_reader_destroy :: proc(r: ^Remote_Msg_Reader, allocator := context.allocator) {
	context.allocator = allocator
	delete(r.stream)
	r.stream = nil
	r.read_pos = remote_HEADER_SIZE
	r.write_pos = 0
}

// remote_msg_reader_reset clears the reader for the next message
// (port of MsgReader::reset, minus the ancillary close, which the
// caller handles through remote_close_maybe_fd).
remote_msg_reader_reset :: proc(r: ^Remote_Msg_Reader) {
	resize(&r.stream, 0)
	r.write_pos = 0
	r.read_pos = remote_HEADER_SIZE
}

// remote_msg_reader_feed appends received bytes to the reader. Once
// the header is complete, a size below the header size yields
// .Bad_Frame (the C++ throws disconnected there).
remote_msg_reader_feed :: proc(r: ^Remote_Msg_Reader, data: []byte, allocator := context.allocator) -> Remote_Error {
	context.allocator = allocator
	append(&r.stream, ..data)
	r.write_pos = len(r.stream)
	if r.write_pos >= remote_HEADER_SIZE && remote_msg_reader_size(r) < remote_HEADER_SIZE {
		return .Bad_Frame
	}
	return .None
}

// remote_msg_reader_ready reports whether a whole message arrived
// (port of MsgReader::ready).
remote_msg_reader_ready :: proc(r: ^Remote_Msg_Reader) -> bool {
	return r.write_pos >= remote_HEADER_SIZE && u32(r.write_pos) == remote_msg_reader_size(r)
}

// remote_msg_reader_size returns the framed total message size (port
// of MsgReader::size). The header must be complete.
remote_msg_reader_size :: proc(r: ^Remote_Msg_Reader) -> u32 {
	assert(r.write_pos >= remote_HEADER_SIZE)
	s := r.stream[1:5]
	return u32(s[0]) | u32(s[1]) << 8 | u32(s[2]) << 16 | u32(s[3]) << 24
}

// remote_msg_reader_type returns the message tag (port of
// MsgReader::type). The header must be complete.
remote_msg_reader_type :: proc(r: ^Remote_Msg_Reader) -> Remote_Message_Type {
	assert(r.write_pos >= remote_HEADER_SIZE)
	return Remote_Message_Type(r.stream[0])
}

// remote_msg_reader_read_bytes consumes n bytes. Reading past the
// message end yields .Bad_Frame (port of MsgReader::read).
remote_msg_reader_read_bytes :: proc(r: ^Remote_Msg_Reader, n: int) -> ([]byte, Remote_Error) {
	if n < 0 || r.read_pos + n > len(r.stream) {
		return nil, .Bad_Frame
	}
	data := r.stream[r.read_pos:r.read_pos + n]
	r.read_pos += n
	return data, .None
}

// remote_msg_reader_read_u8 consumes one byte.
remote_msg_reader_read_u8 :: proc(r: ^Remote_Msg_Reader) -> (u8, Remote_Error) {
	data, err := remote_msg_reader_read_bytes(r, 1)
	if err != .None {
		return 0, err
	}
	return data[0], .None
}

// remote_msg_reader_read_u32 consumes a u32.
remote_msg_reader_read_u32 :: proc(r: ^Remote_Msg_Reader) -> (u32, Remote_Error) {
	data, err := remote_msg_reader_read_bytes(r, 4)
	if err != .None {
		return 0, err
	}
	return u32(data[0]) | u32(data[1]) << 8 | u32(data[2]) << 16 | u32(data[3]) << 24, .None
}

// remote_msg_reader_read_i32 consumes an i32.
remote_msg_reader_read_i32 :: proc(r: ^Remote_Msg_Reader) -> (i32, Remote_Error) {
	v, err := remote_msg_reader_read_u32(r)
	return cast(i32)v, err
}

// remote_msg_reader_read_bool consumes a bool byte.
remote_msg_reader_read_bool :: proc(r: ^Remote_Msg_Reader) -> (bool, Remote_Error) {
	v, err := remote_msg_reader_read_u8(r)
	return v != 0, err
}

// remote_msg_reader_read_string consumes a length-prefixed string.
// The result is owned; free it with delete(s, allocator). A negative
// length yields .Bad_Frame.
remote_msg_reader_read_string :: proc(r: ^Remote_Msg_Reader, allocator := context.allocator) -> (string, Remote_Error) {
	n, err := remote_msg_reader_read_i32(r)
	if err != .None {
		return "", err
	}
	if n < 0 {
		return "", .Bad_Frame
	}
	data, data_err := remote_msg_reader_read_bytes(r, int(n))
	if data_err != .None {
		return "", data_err
	}
	return strings.clone(string(data), allocator), .None
}

// remote_msg_reader_read_key consumes a key.
remote_msg_reader_read_key :: proc(r: ^Remote_Msg_Reader) -> (Keys_Key, Remote_Error) {
	modifiers, err := remote_msg_reader_read_i32(r)
	if err != .None {
		return {}, err
	}
	key, key_err := remote_msg_reader_read_i32(r)
	if key_err != .None {
		return {}, key_err
	}
	return Keys_Key{modifiers = Keys_Modifiers(modifiers), key = rune(key)}, .None
}

// remote_msg_reader_read_color consumes a color: the tag byte plus r,
// g, b for RGB colors (port of the Color reader; like the C++, the
// alpha channel of an RGB color is not transmitted).
remote_msg_reader_read_color :: proc(r: ^Remote_Msg_Reader) -> (Color, Remote_Error) {
	tag, err := remote_msg_reader_read_u8(r)
	if err != .None {
		return {}, err
	}
	c := Color{a = tag}
	if color_is_rgb(c) {
		data, data_err := remote_msg_reader_read_bytes(r, 3)
		if data_err != .None {
			return {}, data_err
		}
		c.r, c.g, c.b = data[0], data[1], data[2]
	}
	return c, .None
}

// remote_msg_reader_read_face consumes a 16-byte C++-layout face.
remote_msg_reader_read_face :: proc(r: ^Remote_Msg_Reader) -> (Face, Remote_Error) {
	data, err := remote_msg_reader_read_bytes(r, 16)
	if err != .None {
		return {}, err
	}
	attrs := i32(data[8]) | i32(data[9]) << 8 | i32(data[10]) << 16 | i32(data[11]) << 24
	return Face{
		fg         = Color{a = data[0], r = data[1], g = data[2], b = data[3]},
		bg         = Color{a = data[4], r = data[5], g = data[6], b = data[7]},
		attributes = remote_face_attributes_from_wire(attrs),
		underline  = Color{a = data[12], r = data[13], g = data[14], b = data[15]},
	}, .None
}

// remote_msg_reader_read_coord_display consumes a display coord.
remote_msg_reader_read_coord_display :: proc(r: ^Remote_Msg_Reader) -> (Coord_Display, Remote_Error) {
	line, err := remote_msg_reader_read_i32(r)
	if err != .None {
		return {}, err
	}
	column, col_err := remote_msg_reader_read_i32(r)
	if col_err != .None {
		return {}, col_err
	}
	return Coord_Display{line = Coord_Line(line), column = Coord_Column(column)}, .None
}

// remote_msg_reader_read_coord_buffer consumes a buffer coord.
remote_msg_reader_read_coord_buffer :: proc(r: ^Remote_Msg_Reader) -> (Coord_Buffer, Remote_Error) {
	line, err := remote_msg_reader_read_i32(r)
	if err != .None {
		return {}, err
	}
	column, col_err := remote_msg_reader_read_i32(r)
	if col_err != .None {
		return {}, col_err
	}
	return Coord_Buffer{line = Coord_Line(line), column = Coord_Byte(column)}, .None
}

// remote_msg_reader_read_display_atom consumes an atom. The atom is a
// Text atom with owned text; free it with remote_destroy_display_atom.
// Ranges cannot cross the socket, like the C++.
remote_msg_reader_read_display_atom :: proc(r: ^Remote_Msg_Reader, allocator := context.allocator) -> (Display_Atom, Remote_Error) {
	content, err := remote_msg_reader_read_string(r, allocator)
	if err != .None {
		return {}, err
	}
	face, face_err := remote_msg_reader_read_face(r)
	if face_err != .None {
		delete(content, allocator)
		return {}, face_err
	}
	return display_buffer_atom_text(content, face), .None
}

// remote_msg_reader_read_display_line consumes a line. The atoms own
// their text; free the line with remote_destroy_display_line.
remote_msg_reader_read_display_line :: proc(r: ^Remote_Msg_Reader, allocator := context.allocator) -> (Display_Line, Remote_Error) {
	count, err := remote_msg_reader_read_u32(r)
	if err != .None {
		return {}, err
	}
	context.allocator = allocator
	atoms := make([dynamic]Display_Atom, 0, int(count), allocator)
	for _ in 0 ..< count {
		atom, atom_err := remote_msg_reader_read_display_atom(r, allocator)
		if atom_err != .None {
			for &prev in atoms {
				remote_destroy_display_atom(&prev, allocator)
			}
			delete(atoms)
			return {}, atom_err
		}
		append(&atoms, atom)
	}
	line := display_buffer_line_make_atoms(atoms[:], allocator)
	delete(atoms)
	return line, .None
}

// remote_msg_reader_read_display_lines consumes a line vector. Free
// it with remote_destroy_display_lines.
remote_msg_reader_read_display_lines :: proc(r: ^Remote_Msg_Reader, allocator := context.allocator) -> (Display_Line_List, Remote_Error) {
	count, err := remote_msg_reader_read_u32(r)
	if err != .None {
		return nil, err
	}
	context.allocator = allocator
	lines := make(Display_Line_List, 0, int(count), allocator)
	for _ in 0 ..< count {
		line, line_err := remote_msg_reader_read_display_line(r, allocator)
		if line_err != .None {
			remote_destroy_display_lines(&lines, allocator)
			return nil, line_err
		}
		append(&lines, line)
	}
	return lines, .None
}

// remote_msg_reader_read_display_buffer consumes a display buffer.
// Free it with remote_destroy_display_buffer.
remote_msg_reader_read_display_buffer :: proc(r: ^Remote_Msg_Reader, allocator := context.allocator) -> (Display_Buffer, Remote_Error) {
	lines, err := remote_msg_reader_read_display_lines(r, allocator)
	if err != .None {
		return {}, err
	}
	db := Display_Buffer{lines = lines, timestamp = -1}
	display_buffer_compute_range(&db)
	return db, .None
}

// remote_msg_reader_read_menu_style consumes an i32 menu style
// ordinal. Out-of-range ordinals yield .Bad_Frame.
remote_msg_reader_read_menu_style :: proc(r: ^Remote_Msg_Reader) -> (User_Interface_Menu_Style, Remote_Error) {
	v, err := remote_msg_reader_read_i32(r)
	if err != .None {
		return .Prompt, err
	}
	if v < 0 || v > i32(User_Interface_Menu_Style.Inline) {
		return .Prompt, .Bad_Frame
	}
	return User_Interface_Menu_Style(v), .None
}

// remote_msg_reader_read_info_style consumes an i32 info style
// ordinal. Out-of-range ordinals yield .Bad_Frame.
remote_msg_reader_read_info_style :: proc(r: ^Remote_Msg_Reader) -> (User_Interface_Info_Style, Remote_Error) {
	v, err := remote_msg_reader_read_i32(r)
	if err != .None {
		return .Prompt, err
	}
	if v < 0 || v > i32(User_Interface_Info_Style.Modal) {
		return .Prompt, .Bad_Frame
	}
	return User_Interface_Info_Style(v), .None
}

// remote_msg_reader_read_status_style consumes an i32 status style
// ordinal. Out-of-range ordinals yield .Bad_Frame.
remote_msg_reader_read_status_style :: proc(r: ^Remote_Msg_Reader) -> (User_Interface_Status_Style, Remote_Error) {
	v, err := remote_msg_reader_read_i32(r)
	if err != .None {
		return .Status, err
	}
	if v < 0 || v > i32(User_Interface_Status_Style.Prompt) {
		return .Status, .Bad_Frame
	}
	return User_Interface_Status_Style(v), .None
}

// remote_msg_reader_read_string_map consumes a string map. Keys and
// values are owned; free them with env_vars_free.
remote_msg_reader_read_string_map :: proc(r: ^Remote_Msg_Reader, allocator := context.allocator) -> (map[string]string, Remote_Error) {
	count, err := remote_msg_reader_read_u32(r)
	if err != .None {
		return nil, err
	}
	context.allocator = allocator
	m := make(map[string]string, int(count), allocator)
	for _ in 0 ..< count {
		key, key_err := remote_msg_reader_read_string(r, allocator)
		if key_err != .None {
			env_vars_free(&m, allocator)
			return nil, key_err
		}
		value, val_err := remote_msg_reader_read_string(r, allocator)
		if val_err != .None {
			delete(key, allocator)
			env_vars_free(&m, allocator)
			return nil, val_err
		}
		m[key] = value
	}
	return m, .None
}

// remote_msg_reader_read_optional_coord_buffer consumes an optional
// buffer coord.
remote_msg_reader_read_optional_coord_buffer :: proc(r: ^Remote_Msg_Reader) -> (Maybe(Coord_Buffer), Remote_Error) {
	present, err := remote_msg_reader_read_bool(r)
	if err != .None || !present {
		return nil, err
	}
	coord, coord_err := remote_msg_reader_read_coord_buffer(r)
	if coord_err != .None {
		return nil, coord_err
	}
	return coord, .None
}

// ---------------------------------------------------------------------------
// Decoded display values cleanup
// ---------------------------------------------------------------------------

// remote_destroy_display_atom frees an atom decoded by
// remote_msg_reader_read_display_atom.
remote_destroy_display_atom :: proc(atom: ^Display_Atom, allocator := context.allocator) {
	delete(atom.text, allocator)
	atom.text = ""
}

// remote_destroy_display_line frees a line decoded by
// remote_msg_reader_read_display_line, including the owned atom text.
remote_destroy_display_line :: proc(line: ^Display_Line, allocator := context.allocator) {
	context.allocator = allocator
	for &atom in line.atoms {
		remote_destroy_display_atom(&atom, allocator)
	}
	display_buffer_line_destroy(line)
}

// remote_destroy_display_lines frees lines decoded by
// remote_msg_reader_read_display_lines.
remote_destroy_display_lines :: proc(lines: ^Display_Line_List, allocator := context.allocator) {
	context.allocator = allocator
	for &line in lines {
		remote_destroy_display_line(&line, allocator)
	}
	delete(lines^)
	lines^ = nil
}

// remote_destroy_display_buffer frees a buffer decoded by
// remote_msg_reader_read_display_buffer.
remote_destroy_display_buffer :: proc(db: ^Display_Buffer, allocator := context.allocator) {
	context.allocator = allocator
	for &line in db.lines {
		for &atom in line.atoms {
			remote_destroy_display_atom(&atom, allocator)
		}
		display_buffer_line_destroy(&line)
	}
	delete(db.lines)
	db.lines = nil
}

// ---------------------------------------------------------------------------
// Socket I/O
// ---------------------------------------------------------------------------

// remote_cmsg_align rounds a control-message length up like the C
// CMSG_ALIGN macro (glibc aligns to sizeof(size_t); posix.CMSG_DATA
// uses 4-byte alignment, which agrees for the first header but not
// for the total space, so this stays explicit).
remote_cmsg_align :: proc(len: int) -> int {
	a := size_of(uint)
	return (len + a - 1) & ~(a - 1)
}

// remote_cmsg_space_int is CMSG_SPACE(sizeof(int)): the control
// buffer size for passing one fd.
remote_cmsg_space_int :: proc() -> int {
	return remote_cmsg_align(size_of(posix.cmsghdr)) + remote_cmsg_align(size_of(i32))
}

// remote_cmsg_len_int is CMSG_LEN(sizeof(int)): the cmsg_len value
// for passing one fd.
remote_cmsg_len_int :: proc() -> int {
	return remote_cmsg_align(size_of(posix.cmsghdr)) + size_of(i32)
}

// Remote_Cmsg_Fd is the control message for passing one fd: the
// header plus the fd at the aligned data offset, padded to
// CMSG_SPACE. The struct layout replaces the C flexible array and
// keeps every field naturally aligned.
Remote_Cmsg_Fd :: struct {
	cmsg: posix.cmsghdr,
	fd:   i32,
	_pad:  u32,
}

// remote_set_cloexec sets FD_CLOEXEC on fd, ignoring failures like
// the C++.
remote_set_cloexec :: proc(fd: int) {
	posix.fcntl(posix.FD(fd), .SETFD, posix.FD_CLOEXEC)
}

// remote_close_maybe_fd closes a held ancillary fd and clears it
// (port of the m_ancillary_fd.map(close) sites).
remote_close_maybe_fd :: proc(fd: ^Maybe(int)) {
	if held, ok := fd.?; ok {
		posix.close(posix.FD(held))
		fd^ = nil
	}
}

// remote_msg_reader_read_available reads one chunk of the current
// message from sock into the reader (port of
// MsgReader::read_available). A received ancillary fd replaces
// ancillary^ (the previous one is closed). A closed or failed socket
// yields .Disconnected, a size below the header size .Bad_Frame.
remote_msg_reader_read_available :: proc(r: ^Remote_Msg_Reader, sock: int, ancillary: ^Maybe(int), allocator := context.allocator) -> Remote_Error {
	context.allocator = allocator
	if r.write_pos < remote_HEADER_SIZE {
		resize(&r.stream, remote_HEADER_SIZE)
	} else {
		resize(&r.stream, int(remote_msg_reader_size(r)))
	}
	base := raw_data(r.stream[r.write_pos:])
	remaining := len(r.stream) - r.write_pos
	io := posix.iovec{iov_base = base, iov_len = uint(remaining)}
	control := Remote_Cmsg_Fd{}
	msg := posix.msghdr{
		msg_iov        = &io,
		msg_iovlen     = 1,
		msg_control    = &control,
		msg_controllen = uint(size_of(Remote_Cmsg_Fd)),
	}
	res := posix.recvmsg(posix.FD(sock), &msg, {})
	if res <= 0 {
		return .Disconnected
	}
	r.write_pos += int(res)
	if r.write_pos >= remote_HEADER_SIZE && remote_msg_reader_size(r) < remote_HEADER_SIZE {
		return .Bad_Frame
	}
	if msg.msg_controllen >= uint(size_of(posix.cmsghdr)) &&
	   control.cmsg.cmsg_level == posix.SOL_SOCKET && control.cmsg.cmsg_type == posix.SCM_RIGHTS &&
	   control.cmsg.cmsg_len == uint(remote_cmsg_len_int()) {
		remote_close_maybe_fd(ancillary)
		ancillary^ = int(control.fd)
		remote_set_cloexec(ancillary.? or_else -1)
	}
	return .None
}

// remote_send_data writes the send buffer to fd (port of send_data).
// It reports whether the buffer drained; a failed write yields
// .Disconnected. An ancillary fd is attached to every chunk, like
// the C++.
remote_send_data :: proc(fd: int, buffer: ^Remote_Buffer, ancillary_fd: Maybe(int) = nil) -> (drained: bool, err: Remote_Error) {
	for len(buffer) > 0 && file_fd_writable(fd) {
		io := posix.iovec{iov_base = raw_data(buffer^), iov_len = uint(len(buffer))}
		control := Remote_Cmsg_Fd{}
		msg := posix.msghdr{msg_iov = &io, msg_iovlen = 1}
		if _, ok := ancillary_fd.?; ok {
			control.cmsg.cmsg_len = uint(remote_cmsg_len_int())
			control.cmsg.cmsg_level = posix.SOL_SOCKET
			control.cmsg.cmsg_type = posix.SCM_RIGHTS
			control.fd = i32(ancillary_fd.? or_else -1)
			msg.msg_control = &control
			msg.msg_controllen = uint(size_of(Remote_Cmsg_Fd))
		}
		res := posix.sendmsg(posix.FD(fd), &msg, {})
		if res <= 0 {
			return false, .Disconnected
		}
		remove_range(buffer, 0, int(res))
	}
	return len(buffer) == 0, .None
}

// ---------------------------------------------------------------------------
// Sessions
// ---------------------------------------------------------------------------

// remote_get_user_name returns the login name (port of get_user_name:
// the passwd entry, else $USER). The result is owned.
remote_get_user_name :: proc(allocator := context.allocator) -> string {
	if pw := posix.getpwuid(posix.geteuid()); pw != nil && pw.pw_name != nil {
		return strings.clone(string(pw.pw_name), allocator)
	}
	if user := posix.getenv("USER"); user != nil {
		return strings.clone(string(user), allocator)
	}
	return ""
}

// remote_session_directory returns the directory holding the session
// sockets (port of session_directory, without the static cache: the
// result is owned). $XDG_RUNTIME_DIR/kakoune wins when the directory
// exists and is owned by the user, else $TMPDIR/kakoune-<user>.
remote_session_directory :: proc(allocator := context.allocator) -> string {
	if xdg := posix.getenv("XDG_RUNTIME_DIR"); xdg != nil && len(string(xdg)) > 0 {
		cpath := strings.clone_to_cstring(string(xdg), context.temp_allocator)
		st: posix.stat_t
		if posix.stat(cpath, &st) == .OK && st.st_uid == posix.geteuid() {
			return strings.concatenate({string(xdg), "/kakoune"}, allocator)
		}
		debug_write_to_debug_buffer("XDG_RUNTIME_DIR does not exist or not owned by current user, using tmpdir")
	}
	user := remote_get_user_name(context.temp_allocator)
	defer delete(user, context.temp_allocator)
	return strings.concatenate({file_tmpdir(), "/kakoune-", user}, allocator)
}

// remote_is_session_char reports whether r may appear in a session
// name (port of is_identifier).
remote_is_session_char :: proc(r: rune) -> bool {
	return (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '_' || r == '-'
}

// remote_session_path returns the socket path for a session (port of
// session_path). The result is owned. Unless assume_valid, names
// with other characters yield .Invalid_Session_Name and paths too
// long for sun_path yield .Socket_Path_Too_Long.
remote_session_path :: proc(session: string, assume_valid := false, allocator := context.allocator) -> (string, Remote_Error) {
	if !assume_valid {
		for r in session {
			if !remote_is_session_char(r) {
				return "", .Invalid_Session_Name
			}
		}
	}
	dir := remote_session_directory(context.temp_allocator)
	defer delete(dir, context.temp_allocator)
	path := strings.concatenate({dir, "/", session}, allocator)
	if !assume_valid && len(path) + 1 > len(posix.sockaddr_un{}.sun_path) {
		delete(path, allocator)
		return "", .Socket_Path_Too_Long
	}
	return path, .None
}

// remote_session_addr builds the unix address for a session (port of
// session_addr).
remote_session_addr :: proc(session: string) -> (posix.sockaddr_un, Remote_Error) {
	path, err := remote_session_path(session, false, context.temp_allocator)
	if err != .None {
		return {}, err
	}
	defer delete(path, context.temp_allocator)
	addr := posix.sockaddr_un{sun_family = .UNIX}
	copy(addr.sun_path[:], transmute([]u8)path)
	return addr, .None
}

// remote_connect_to connects to a session socket (port of
// connect_to). Deviation: the socket is closed on failure (the C++
// leaks it).
remote_connect_to :: proc(session: string) -> (int, Remote_Error) {
	addr, err := remote_session_addr(session)
	if err != .None {
		return -1, err
	}
	sock := posix.socket(.UNIX, .STREAM, .IP)
	if sock == posix.FD(-1) {
		return -1, .Socket_Create
	}
	remote_set_cloexec(int(sock))
	// Like the C++, the length covers sun_path only.
	if posix.connect(sock, cast(^posix.sockaddr)(&addr), posix.socklen_t(size_of(addr.sun_path))) != .OK {
		posix.close(sock)
		return -1, .Connect
	}
	return int(sock), .None
}

// remote_check_session reports whether a session socket accepts
// connections (port of check_session). An invalid session name
// yields the path error; a refused connection is (false, .None).
remote_check_session :: proc(session: string) -> (up: bool, err: Remote_Error) {
	addr, addr_err := remote_session_addr(session)
	if addr_err != .None {
		return false, addr_err
	}
	sock := posix.socket(.UNIX, .STREAM, .IP)
	if sock == posix.FD(-1) {
		return false, .None
	}
	defer posix.close(sock)
	if posix.connect(sock, cast(^posix.sockaddr)(&addr), posix.socklen_t(size_of(addr.sun_path))) != .OK {
		return false, .None
	}
	return true, .None
}

// remote_send_command connects to a session and runs a command there
// (port of send_command). The socket write failure maps to
// .Disconnected.
remote_send_command :: proc(session: string, command: string, allocator := context.allocator) -> Remote_Error {
	context.allocator = allocator
	sock, err := remote_connect_to(session)
	if err != .None {
		return .Disconnected if err == .Connect else err
	}
	defer posix.close(posix.FD(sock))
	buffer := make(Remote_Buffer, allocator)
	defer delete(buffer)
	w := remote_msg_writer_begin(&buffer, .Command, allocator)
	remote_msg_write_string(&w, command)
	remote_msg_writer_end(&w)
	if file_write(sock, string(buffer[:])) != .None {
		return .Disconnected
	}
	return .None
}

// ---------------------------------------------------------------------------
// Watcher registry
// ---------------------------------------------------------------------------

// Remote_Watcher_Kind tags what a registered fd watcher belongs to.
// Event callbacks carry no user data, so the registry links watchers
// back to their owners.
Remote_Watcher_Kind :: enum {
	Listener,
	Accepter,
	Client,
	Ui,
}

// Remote_Watcher_Owner is one registry entry: the owner kind plus the
// owner pointer (^Server, ^Remote_Accepter, ^Remote_Client_Socket or
// ^Remote_UI).
Remote_Watcher_Owner :: struct {
	kind: Remote_Watcher_Kind,
	ptr:  rawptr,
}

// remote_watcher_owners links live remote watchers to their owners.
// Entries are added when a watcher is created and removed when it is
// destroyed; the map itself lives for the process lifetime.
remote_watcher_owners: map[^Event_Manager_Fd_Watcher]Remote_Watcher_Owner

// remote_watcher_register links a watcher to its owner.
remote_watcher_register :: proc(w: ^Event_Manager_Fd_Watcher, kind: Remote_Watcher_Kind, ptr: rawptr, allocator := context.allocator) {
	context.allocator = allocator
	if remote_watcher_owners == nil {
		remote_watcher_owners = make(map[^Event_Manager_Fd_Watcher]Remote_Watcher_Owner, allocator)
	}
	remote_watcher_owners[w] = Remote_Watcher_Owner{kind = kind, ptr = ptr}
}

// remote_watcher_unregister drops a watcher's registry entry.
remote_watcher_unregister :: proc(w: ^Event_Manager_Fd_Watcher) {
	if remote_watcher_owners != nil {
		delete_key(&remote_watcher_owners, w)
	}
}

// remote_watcher_lookup returns a watcher's owner, if registered.
remote_watcher_lookup :: proc(w: ^Event_Manager_Fd_Watcher) -> (Remote_Watcher_Owner, bool) {
	owner, ok := remote_watcher_owners[w]
	return owner, ok
}

// ---------------------------------------------------------------------------
// Server-side UI
// ---------------------------------------------------------------------------

// Remote_UI is the server end of a remote client connection (port of
// RemoteUI): a User_Interface implementation that forwards draws to
// the socket and feeds received keys into the client. Create with
// remote_ui_make, release with remote_ui_destroy. The ui handle is
// handed to client_manager_create_client and freed by client_destroy.
Remote_UI :: struct {
	watcher:     ^Event_Manager_Fd_Watcher,
	reader:      Remote_Msg_Reader,
	ancillary:   Maybe(int),
	dimensions:  Coord_Display,
	on_key:      User_Interface_On_Key_Callback,
	on_paste:    User_Interface_On_Paste_Callback,
	send_buffer: Remote_Buffer,
	ui:          ^User_Interface,
	allocator:   mem.Allocator,
}

// remote_ui_make builds a server-side UI around an accepted socket.
remote_ui_make :: proc(sock: int, dimensions: Coord_Display, allocator := context.allocator) -> ^Remote_UI {
	context.allocator = allocator
	ui := new(Remote_UI, allocator)
	ui.allocator = allocator
	ui.dimensions = dimensions
	remote_msg_reader_init(&ui.reader, allocator)
	ui.send_buffer = make(Remote_Buffer, allocator)
	ui.watcher = new(Event_Manager_Fd_Watcher, allocator)
	event_manager_fd_watcher_init(ui.watcher, sock, {.Read, .Write}, .Urgent, remote_ui_on_event)
	remote_watcher_register(ui.watcher, .Ui, ui, allocator)
	ui.ui = new(User_Interface, allocator)
	ui.ui^ = user_interface_make(ui, &remote_ui_vtable)
	remote_debug_write_int("remote client connected: ", sock)
	return ui
}

// remote_ui_destroy releases a Remote_UI. Remaining send data is
// flushed best-effort first, like ~RemoteUI. The ui handle is freed
// here unless client_destroy already freed it; exactly one of the
// two must run.
remote_ui_destroy :: proc(ui: ^Remote_UI) {
	context.allocator = ui.allocator
	if ui.watcher.fd != -1 {
		remote_send_data(ui.watcher.fd, &ui.send_buffer)
	}
	remote_debug_write_int("remote client disconnected: ", ui.watcher.fd)
	event_manager_fd_watcher_close_fd(ui.watcher)
	event_manager_fd_watcher_destroy(ui.watcher)
	remote_watcher_unregister(ui.watcher)
	free(ui.watcher, ui.allocator)
	remote_close_maybe_fd(&ui.ancillary)
	remote_msg_reader_destroy(&ui.reader, ui.allocator)
	delete(ui.send_buffer)
	free(ui.ui, ui.allocator)
	alloc := ui.allocator
	free(ui, alloc)
}

// remote_ui_send_begin starts a message to the remote client. The
// caller appends the fields, ends the writer, and marks the watcher
// writable.
remote_ui_send_begin :: proc(ui: ^Remote_UI, type: Remote_Message_Type) -> Remote_Msg_Writer {
	return remote_msg_writer_begin(&ui.send_buffer, type, ui.allocator)
}

// remote_ui_send_end finishes a message to the remote client.
remote_ui_send_end :: proc(ui: ^Remote_UI, w: ^Remote_Msg_Writer) {
	remote_msg_writer_end(w)
	ui.watcher.events += {.Write}
}

// remote_ui_exit sends the exit status to the remote client (port of
// RemoteUI::exit).
remote_ui_exit :: proc(ui: ^Remote_UI, status: int) {
	w := remote_ui_send_begin(ui, .Exit)
	remote_msg_write_i32(&w, i32(status))
	remote_ui_send_end(ui, &w)
}

// remote_ui_on_client_exit runs when the server-side client exits
// (the on_exit callback given to client_manager_create_client).
remote_ui_on_client_exit :: proc(data: rawptr, status: int) {
	ui := (^Remote_UI)(data)
	remote_ui_exit(ui, status)
}

// remote_ui_unwrap_line reinterprets an opaque UI line as the real
// Display_Line it wraps (see KNOTFIX_ui_line in client.odin).
remote_ui_unwrap_line :: proc(l: User_Interface_Display_Line) -> ^Display_Line {
	return (^Display_Line)(l.opaque)
}

// remote_ui_unwrap_buffer reinterprets an opaque UI buffer as the
// real Display_Buffer it wraps (see KNOTFIX_ui_buffer).
remote_ui_unwrap_buffer :: proc(db: ^User_Interface_Display_Buffer) -> ^Display_Buffer {
	return cast(^Display_Buffer)db
}

// remote_ui_is_ok reports whether the UI socket is still open.
remote_ui_is_ok :: proc(data: rawptr) -> bool {
	ui := (^Remote_UI)(data)
	return ui.watcher.fd != -1
}

// remote_ui_menu_show forwards menu_show to the remote client.
remote_ui_menu_show :: proc(data: rawptr, choices: []User_Interface_Display_Line, anchor: Coord_Display, fg, bg: Face, style: User_Interface_Menu_Style) {
	ui := (^Remote_UI)(data)
	w := remote_ui_send_begin(ui, .Menu_Show)
	remote_msg_write_u32(&w, u32(len(choices)))
	for choice in choices {
		remote_msg_write_display_line(&w, remote_ui_unwrap_line(choice)^)
	}
	remote_msg_write_coord_display(&w, anchor)
	remote_msg_write_face(&w, fg)
	remote_msg_write_face(&w, bg)
	remote_msg_write_menu_style(&w, style)
	remote_ui_send_end(ui, &w)
}

// remote_ui_menu_select forwards menu_select to the remote client.
remote_ui_menu_select :: proc(data: rawptr, selected: int) {
	ui := (^Remote_UI)(data)
	w := remote_ui_send_begin(ui, .Menu_Select)
	remote_msg_write_i32(&w, i32(selected))
	remote_ui_send_end(ui, &w)
}

// remote_ui_menu_hide forwards menu_hide to the remote client.
remote_ui_menu_hide :: proc(data: rawptr) {
	ui := (^Remote_UI)(data)
	w := remote_ui_send_begin(ui, .Menu_Hide)
	remote_ui_send_end(ui, &w)
}

// remote_ui_info_show forwards info_show to the remote client.
remote_ui_info_show :: proc(data: rawptr, title: ^User_Interface_Display_Line, content: []User_Interface_Display_Line, anchor: Coord_Display, face: Face, style: User_Interface_Info_Style) {
	ui := (^Remote_UI)(data)
	w := remote_ui_send_begin(ui, .Info_Show)
	remote_msg_write_display_line(&w, remote_ui_unwrap_line(title^)^)
	remote_msg_write_u32(&w, u32(len(content)))
	for line in content {
		remote_msg_write_display_line(&w, remote_ui_unwrap_line(line)^)
	}
	remote_msg_write_coord_display(&w, anchor)
	remote_msg_write_face(&w, face)
	remote_msg_write_info_style(&w, style)
	remote_ui_send_end(ui, &w)
}

// remote_ui_info_hide forwards info_hide to the remote client.
remote_ui_info_hide :: proc(data: rawptr) {
	ui := (^Remote_UI)(data)
	w := remote_ui_send_begin(ui, .Info_Hide)
	remote_ui_send_end(ui, &w)
}

// remote_ui_draw forwards draw to the remote client.
remote_ui_draw :: proc(data: rawptr, display_buffer: ^User_Interface_Display_Buffer, cursor_pos: Coord_Display, default_face, padding_face: Face, widget_columns: Coord_Column) {
	ui := (^Remote_UI)(data)
	w := remote_ui_send_begin(ui, .Draw)
	remote_msg_write_display_buffer(&w, remote_ui_unwrap_buffer(display_buffer)^)
	remote_msg_write_coord_display(&w, cursor_pos)
	remote_msg_write_face(&w, default_face)
	remote_msg_write_face(&w, padding_face)
	remote_msg_write_i32(&w, i32(widget_columns))
	remote_ui_send_end(ui, &w)
}

// remote_ui_draw_status forwards draw_status to the remote client.
remote_ui_draw_status :: proc(data: rawptr, prompt, content: ^User_Interface_Display_Line, cursor_pos: Coord_Column, mode_line: ^User_Interface_Display_Line, default_face: Face, style: User_Interface_Status_Style) {
	ui := (^Remote_UI)(data)
	w := remote_ui_send_begin(ui, .Draw_Status)
	remote_msg_write_display_line(&w, remote_ui_unwrap_line(prompt^)^)
	remote_msg_write_display_line(&w, remote_ui_unwrap_line(content^)^)
	remote_msg_write_i32(&w, i32(cursor_pos))
	remote_msg_write_display_line(&w, remote_ui_unwrap_line(mode_line^)^)
	remote_msg_write_face(&w, default_face)
	remote_msg_write_status_style(&w, style)
	remote_ui_send_end(ui, &w)
}

// remote_ui_dimensions returns the last known client dimensions.
remote_ui_dimensions :: proc(data: rawptr) -> Coord_Display {
	ui := (^Remote_UI)(data)
	return ui.dimensions
}

// remote_ui_refresh forwards refresh to the remote client.
remote_ui_refresh :: proc(data: rawptr, force: bool) {
	ui := (^Remote_UI)(data)
	w := remote_ui_send_begin(ui, .Refresh)
	remote_msg_write_bool(&w, force)
	remote_ui_send_end(ui, &w)
}

// remote_ui_set_on_key installs the key callback.
remote_ui_set_on_key :: proc(data: rawptr, callback: User_Interface_On_Key_Callback) {
	ui := (^Remote_UI)(data)
	ui.on_key = callback
}

// remote_ui_set_on_paste installs the paste callback.
remote_ui_set_on_paste :: proc(data: rawptr, callback: User_Interface_On_Paste_Callback) {
	ui := (^Remote_UI)(data)
	ui.on_paste = callback
}

// remote_ui_set_ui_options forwards the UI options to the remote client.
remote_ui_set_ui_options :: proc(data: rawptr, options: User_Interface_Options) {
	ui := (^Remote_UI)(data)
	w := remote_ui_send_begin(ui, .Set_Options)
	remote_msg_write_string_map(&w, options)
	remote_ui_send_end(ui, &w)
}

// remote_ui_vtable implements User_Interface for Remote_UI.
remote_ui_vtable := User_Interface_VTable{
	is_ok          = remote_ui_is_ok,
	menu_show      = remote_ui_menu_show,
	menu_select    = remote_ui_menu_select,
	menu_hide      = remote_ui_menu_hide,
	info_show      = remote_ui_info_show,
	info_hide      = remote_ui_info_hide,
	draw           = remote_ui_draw,
	draw_status    = remote_ui_draw_status,
	dimensions     = remote_ui_dimensions,
	refresh        = remote_ui_refresh,
	set_on_key     = remote_ui_set_on_key,
	set_on_paste   = remote_ui_set_on_paste,
	set_ui_options = remote_ui_set_ui_options,
}

// remote_ui_on_event pumps a server-side UI socket (port of the
// RemoteUI watcher callback): flush the send buffer, then dispatch
// received Key and Paste messages. Anything else closes the socket.
remote_ui_on_event :: proc(watcher: ^Event_Manager_Fd_Watcher, events: Event_Manager_Fd_Events, mode: Event_Manager_Mode) {
	owner, ok := remote_watcher_lookup(watcher)
	if !ok || owner.kind != .Ui {
		return
	}
	ui := (^Remote_UI)(owner.ptr)
	sock := watcher.fd
	if .Write in events {
		drained, err := remote_send_data(sock, &ui.send_buffer)
		if err != .None {
			debug_write_to_debug_buffer("error while transfering remote messages")
			event_manager_fd_watcher_close_fd(watcher)
			return
		}
		if drained {
			watcher.events -= {.Write}
		}
	}
	if .Read in events {
		for file_fd_readable(sock) {
			if err := remote_msg_reader_read_available(&ui.reader, sock, &ui.ancillary, ui.allocator); err != .None {
				debug_write_to_debug_buffer("error while transfering remote messages")
				event_manager_fd_watcher_close_fd(watcher)
				return
			}
			if !remote_msg_reader_ready(&ui.reader) {
				continue
			}
			remote_close_maybe_fd(&ui.ancillary)
			switch remote_msg_reader_type(&ui.reader) {
			case .Key:
				key, err := remote_msg_reader_read_key(&ui.reader)
				remote_msg_reader_reset(&ui.reader)
				if err != .None {
					debug_write_to_debug_buffer("error while transfering remote messages")
					event_manager_fd_watcher_close_fd(watcher)
					return
				}
				if key.modifiers == keys_MOD_RESIZE {
					coord := keys_coord(key)
					ui.dimensions = Coord_Display{line = Coord_Line(coord.line), column = Coord_Column(coord.column)}
				}
				if ui.on_key.call != nil {
					ui.on_key.call(ui.on_key.data, key)
				}
			case .Paste:
				content, err := remote_msg_reader_read_string(&ui.reader, ui.allocator)
				remote_msg_reader_reset(&ui.reader)
				if err != .None {
					debug_write_to_debug_buffer("error while transfering remote messages")
					event_manager_fd_watcher_close_fd(watcher)
					return
				}
				if ui.on_paste.call != nil {
					ui.on_paste.call(ui.on_paste.data, content)
				}
				delete(content, ui.allocator)
			case .Unknown, .Connect, .Command, .Menu_Show, .Menu_Select, .Menu_Hide, .Info_Show, .Info_Hide, .Draw, .Draw_Status, .Refresh, .Set_Options, .Exit:
				event_manager_fd_watcher_close_fd(watcher)
				return
			}
		}
	}
}

// ---------------------------------------------------------------------------
// Local client end
// ---------------------------------------------------------------------------

// Remote_Client_Socket holds the socket state of a Remote_Client: the
// persistent incoming-message reader plus its stray ancillary fd.
// Heap-allocated by remote_client_init, freed by remote_client_destroy.
Remote_Client_Socket :: struct {
	client:    ^Remote_Client,
	reader:    Remote_Msg_Reader,
	ancillary: Maybe(int),
	allocator: mem.Allocator,
}

// remote_client_current is the process's RemoteClient, if any. The
// merged UI callbacks carry no user data, so the on_key/on_paste
// trampolines reach the client through this (there is at most one
// RemoteClient per client process, like the C++).
remote_client_current: ^Remote_Client

// remote_client_init connects a Remote_Client to a session and sends
// the Connect handshake (port of RemoteClient::RemoteClient). ui is
// borrowed; env_vars is borrowed for the handshake. stdin_fd, when
// present, is passed to the server as an ancillary fd.
remote_client_init :: proc(
	c: ^Remote_Client,
	session: string,
	name: string,
	ui: ^User_Interface,
	pid: int,
	env_vars: Env_Var_Map,
	init_command: string,
	init_coord: Maybe(Coord_Buffer),
	stdin_fd: Maybe(int),
	allocator := context.allocator,
) -> Remote_Error {
	context.allocator = allocator
	c.allocator = allocator
	c.ui = ui
	c.exit_status = nil
	c.send_buffer = make(Remote_Buffer, allocator)
	c.socket_watcher = nil
	sock, err := remote_connect_to(session)
	if err != .None {
		delete(c.send_buffer)
		return .Disconnected if err == .Connect else err
	}
	w := remote_msg_writer_begin(&c.send_buffer, .Connect, allocator)
	remote_msg_write_i32(&w, i32(pid))
	remote_msg_write_string(&w, name)
	remote_msg_write_string(&w, init_command)
	remote_msg_write_optional_coord_buffer(&w, init_coord)
	remote_msg_write_coord_display(&w, user_interface_dimensions(ui))
	remote_msg_write_string_map(&w, env_vars)
	remote_msg_writer_end(&w)
	if _, send_err := remote_send_data(sock, &c.send_buffer, stdin_fd); send_err != .None {
		posix.close(posix.FD(sock))
		delete(c.send_buffer)
		return send_err
	}
	state := new(Remote_Client_Socket, allocator)
	state.client = c
	state.allocator = allocator
	remote_msg_reader_init(&state.reader, allocator)
	c.socket_watcher = new(Event_Manager_Fd_Watcher, allocator)
	event_manager_fd_watcher_init(c.socket_watcher, sock, {.Read, .Write}, .Urgent, remote_client_on_event)
	remote_watcher_register(c.socket_watcher, .Client, state, allocator)
	user_interface_set_on_key(ui, {remote_client_ui_on_key, nil})
	user_interface_set_on_paste(ui, {remote_client_ui_on_paste, nil})
	remote_client_current = c
	return .None
}

// remote_client_destroy releases a Remote_Client made by
// remote_client_init. The borrowed ui is untouched.
remote_client_destroy :: proc(c: ^Remote_Client) {
	context.allocator = c.allocator
	if c.socket_watcher != nil {
		if owner, ok := remote_watcher_lookup(c.socket_watcher); ok && owner.kind == .Client {
			state := (^Remote_Client_Socket)(owner.ptr)
			remote_msg_reader_destroy(&state.reader, state.allocator)
			remote_close_maybe_fd(&state.ancillary)
			free(state, state.allocator)
		}
		event_manager_fd_watcher_close_fd(c.socket_watcher)
		event_manager_fd_watcher_destroy(c.socket_watcher)
		remote_watcher_unregister(c.socket_watcher)
		free(c.socket_watcher, c.allocator)
		c.socket_watcher = nil
	}
	delete(c.send_buffer)
	c.send_buffer = nil
	if remote_client_current == c {
		remote_client_current = nil
	}
}

// remote_client_is_ui_ok reports whether the client's UI is usable
// (port of RemoteClient::is_ui_ok).
remote_client_is_ui_ok :: proc(c: ^Remote_Client) -> bool {
	return user_interface_is_ok(c.ui)
}

// remote_client_ui_on_key forwards a locally pressed key to the
// server (the UI on_key trampoline through remote_client_current).
remote_client_ui_on_key :: proc(data: rawptr, key: Keys_Key) {
	_ = data
	c := remote_client_current
	if c == nil || c.socket_watcher == nil {
		return
	}
	w := remote_msg_writer_begin(&c.send_buffer, .Key, c.allocator)
	remote_msg_write_key(&w, key)
	remote_msg_writer_end(&w)
	c.socket_watcher.events += {.Write}
}

// remote_client_ui_on_paste forwards locally pasted text to the
// server (the UI on_paste trampoline through remote_client_current).
remote_client_ui_on_paste :: proc(data: rawptr, content: string) {
	_ = data
	c := remote_client_current
	if c == nil || c.socket_watcher == nil {
		return
	}
	w := remote_msg_writer_begin(&c.send_buffer, .Paste, c.allocator)
	remote_msg_write_string(&w, content)
	remote_msg_writer_end(&w)
	c.socket_watcher.events += {.Write}
}

// remote_client_wrap_lines wraps decoded lines for the merged UI
// procs (scratch wrappers borrowing lines, like KNOTFIX_ui_lines).
remote_client_wrap_lines :: proc(lines: []Display_Line, allocator := context.allocator) -> []User_Interface_Display_Line {
	wrapped := make([]User_Interface_Display_Line, len(lines), allocator)
	for &line, i in lines {
		wrapped[i] = User_Interface_Display_Line{opaque = &line}
	}
	return wrapped
}

// remote_client_handle_message dispatches one ready message to the
// local UI (port of the RemoteClient watcher switch). The reader
// must be ready; it is reset before returning. Exit closes the
// socket and stores the status.
remote_client_handle_message :: proc(state: ^Remote_Client_Socket, watcher: ^Event_Manager_Fd_Watcher) -> Remote_Error {
	c := state.client
	context.allocator = c.allocator
	r := &state.reader
	remote_close_maybe_fd(&state.ancillary)
	switch remote_msg_reader_type(r) {
	case .Menu_Show:
		choices, err := remote_msg_reader_read_display_lines(r, c.allocator)
		if err != .None {
			remote_msg_reader_reset(r)
			return err
		}
		defer remote_destroy_display_lines(&choices, c.allocator)
		anchor, anchor_err := remote_msg_reader_read_coord_display(r)
		fg, fg_err := remote_msg_reader_read_face(r)
		bg, bg_err := remote_msg_reader_read_face(r)
		style, style_err := remote_msg_reader_read_menu_style(r)
		remote_msg_reader_reset(r)
		if anchor_err != .None {
			return anchor_err
		}
		if fg_err != .None {
			return fg_err
		}
		if bg_err != .None {
			return bg_err
		}
		if style_err != .None {
			return style_err
		}
		wrapped := remote_client_wrap_lines(choices[:], context.temp_allocator)
		defer delete(wrapped, context.temp_allocator)
		user_interface_menu_show(c.ui, wrapped, anchor, fg, bg, style)
	case .Menu_Select:
		selected, err := remote_msg_reader_read_i32(r)
		remote_msg_reader_reset(r)
		if err != .None {
			return err
		}
		user_interface_menu_select(c.ui, int(selected))
	case .Menu_Hide:
		remote_msg_reader_reset(r)
		user_interface_menu_hide(c.ui)
	case .Info_Show:
		title, err := remote_msg_reader_read_display_line(r, c.allocator)
		if err != .None {
			remote_msg_reader_reset(r)
			return err
		}
		defer remote_destroy_display_line(&title, c.allocator)
		content, content_err := remote_msg_reader_read_display_lines(r, c.allocator)
		if content_err != .None {
			remote_msg_reader_reset(r)
			return content_err
		}
		defer remote_destroy_display_lines(&content, c.allocator)
		anchor, anchor_err := remote_msg_reader_read_coord_display(r)
		face, face_err := remote_msg_reader_read_face(r)
		style, style_err := remote_msg_reader_read_info_style(r)
		remote_msg_reader_reset(r)
		if anchor_err != .None {
			return anchor_err
		}
		if face_err != .None {
			return face_err
		}
		if style_err != .None {
			return style_err
		}
		wrapped := remote_client_wrap_lines(content[:], context.temp_allocator)
		defer delete(wrapped, context.temp_allocator)
		title_wrapped := User_Interface_Display_Line{opaque = &title}
		user_interface_info_show(c.ui, &title_wrapped, wrapped, anchor, face, style)
	case .Info_Hide:
		remote_msg_reader_reset(r)
		user_interface_info_hide(c.ui)
	case .Draw:
		db, err := remote_msg_reader_read_display_buffer(r, c.allocator)
		if err != .None {
			remote_msg_reader_reset(r)
			return err
		}
		defer remote_destroy_display_buffer(&db, c.allocator)
		cursor, cursor_err := remote_msg_reader_read_coord_display(r)
		default_face, default_err := remote_msg_reader_read_face(r)
		padding_face, padding_err := remote_msg_reader_read_face(r)
		widget, widget_err := remote_msg_reader_read_i32(r)
		remote_msg_reader_reset(r)
		if cursor_err != .None {
			return cursor_err
		}
		if default_err != .None {
			return default_err
		}
		if padding_err != .None {
			return padding_err
		}
		if widget_err != .None {
			return widget_err
		}
		db_wrapped := cast(^User_Interface_Display_Buffer)&db
		user_interface_draw(c.ui, db_wrapped, cursor, default_face, padding_face, Coord_Column(widget))
	case .Draw_Status:
		prompt, err := remote_msg_reader_read_display_line(r, c.allocator)
		if err != .None {
			remote_msg_reader_reset(r)
			return err
		}
		defer remote_destroy_display_line(&prompt, c.allocator)
		content, content_err := remote_msg_reader_read_display_line(r, c.allocator)
		if content_err != .None {
			remote_msg_reader_reset(r)
			return content_err
		}
		defer remote_destroy_display_line(&content, c.allocator)
		cursor, cursor_err := remote_msg_reader_read_i32(r)
		mode_line, mode_err := remote_msg_reader_read_display_line(r, c.allocator)
		if mode_err != .None {
			remote_msg_reader_reset(r)
			return cursor_err if cursor_err != .None else mode_err
		}
		defer remote_destroy_display_line(&mode_line, c.allocator)
		default_face, default_err := remote_msg_reader_read_face(r)
		style, style_err := remote_msg_reader_read_status_style(r)
		remote_msg_reader_reset(r)
		if cursor_err != .None {
			return cursor_err
		}
		if default_err != .None {
			return default_err
		}
		if style_err != .None {
			return style_err
		}
		prompt_wrapped := User_Interface_Display_Line{opaque = &prompt}
		content_wrapped := User_Interface_Display_Line{opaque = &content}
		mode_wrapped := User_Interface_Display_Line{opaque = &mode_line}
		user_interface_draw_status(c.ui, &prompt_wrapped, &content_wrapped, Coord_Column(cursor), &mode_wrapped, default_face, style)
	case .Refresh:
		force, err := remote_msg_reader_read_bool(r)
		remote_msg_reader_reset(r)
		if err != .None {
			return err
		}
		user_interface_refresh(c.ui, force)
	case .Set_Options:
		options, err := remote_msg_reader_read_string_map(r, c.allocator)
		remote_msg_reader_reset(r)
		if err != .None {
			return err
		}
		defer env_vars_free(&options, c.allocator)
		user_interface_set_ui_options(c.ui, User_Interface_Options(options))
	case .Exit:
		status, err := remote_msg_reader_read_i32(r)
		if err != .None {
			remote_msg_reader_reset(r)
			return err
		}
		c.exit_status = int(status)
		event_manager_fd_watcher_close_fd(watcher)
		return .None
	case .Unknown, .Connect, .Command, .Key, .Paste:
		// The server never sends these (kak_assert(false) parity):
		// complain and skip the message.
		assert(false, "unexpected remote message")
		debug_write_to_debug_buffer("unexpected remote message received")
		remote_msg_reader_reset(r)
	}
	return .None
}

// remote_client_on_event pumps a RemoteClient socket (port of the
// RemoteClient watcher callback): flush the send buffer, then
// dispatch ready messages to the local UI. Deviation: socket errors
// close the socket (the C++ lets `disconnected` escape the callback).
remote_client_on_event :: proc(watcher: ^Event_Manager_Fd_Watcher, events: Event_Manager_Fd_Events, mode: Event_Manager_Mode) {
	owner, ok := remote_watcher_lookup(watcher)
	if !ok || owner.kind != .Client {
		return
	}
	state := (^Remote_Client_Socket)(owner.ptr)
	sock := watcher.fd
	if .Write in events {
		drained, err := remote_send_data(sock, &state.client.send_buffer)
		if err != .None {
			debug_write_to_debug_buffer("error while transfering remote messages")
			event_manager_fd_watcher_close_fd(watcher)
			return
		}
		if drained {
			watcher.events -= {.Write}
		}
	}
	if .Read in events {
		for file_fd_readable(sock) {
			if err := remote_msg_reader_read_available(&state.reader, sock, &state.ancillary, state.allocator); err != .None {
				debug_write_to_debug_buffer("error while transfering remote messages")
				event_manager_fd_watcher_close_fd(watcher)
				return
			}
			if !remote_msg_reader_ready(&state.reader) {
				continue
			}
			if err := remote_client_handle_message(state, watcher); err != .None {
				debug_write_to_debug_buffer("error while transfering remote messages")
				event_manager_fd_watcher_close_fd(watcher)
				return
			}
			if watcher.fd == -1 {
				return
			}
		}
	}
}

// ---------------------------------------------------------------------------
// Server
// ---------------------------------------------------------------------------

// remote_server_singleton is the installed session server, if any
// (port of Singleton<Server>).
remote_server_singleton: ^Server

// remote_server_instance returns the installed server, asserting one
// is installed like the C++ Singleton accessor.
remote_server_instance :: proc() -> ^Server {
	assert(remote_server_singleton != nil)
	return remote_server_singleton
}

// remote_debug_write_int writes "prefix<int>" to the debug buffer
// using scratch memory.
remote_debug_write_int :: proc(prefix: string, v: int) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, prefix)
	strings.write_int(&b, v)
	debug_write_to_debug_buffer(strings.to_string(b))
}

// remote_server_init listens on the session socket and installs the
// server singleton (port of Server::Server). The session name is
// cloned; release with remote_server_destroy.
remote_server_init :: proc(s: ^Server, session_name: string, is_daemon: bool, allocator := context.allocator) -> Remote_Error {
	context.allocator = allocator
	assert(remote_server_singleton == nil)
	s.allocator = allocator
	s.session = strings.clone(session_name, allocator)
	s.is_daemon = is_daemon
	s.accepters = make([dynamic]^Remote_Accepter, allocator)
	s.listener = nil
	remote_server_singleton = s
	addr, addr_err := remote_session_addr(session_name)
	if addr_err != .None {
		remote_server_drop(s)
		return addr_err
	}
	listen_sock := posix.socket(.UNIX, .STREAM, .IP)
	if listen_sock == posix.FD(-1) {
		remote_server_drop(s)
		return .Socket_Create
	}
	sock := int(listen_sock)
	remote_set_cloexec(sock)
	dir := remote_session_directory(context.temp_allocator)
	defer delete(dir, context.temp_allocator)
	if file_make_directory(dir, {.IRUSR, .IWUSR, .IXUSR, .IXGRP, .IXOTH}) != .None {
		posix.close(listen_sock)
		remote_server_drop(s)
		return .Bind
	}
	// Like the C++, the socket is unreachable by other users.
	old_mask := posix.umask({.IRGRP, .IWGRP, .IXGRP, .IROTH, .IWOTH, .IXOTH})
	defer posix.umask(old_mask)
	if posix.bind(listen_sock, cast(^posix.sockaddr)(&addr), posix.socklen_t(size_of(posix.sockaddr_un))) != .OK {
		posix.close(listen_sock)
		remote_server_drop(s)
		return .Bind
	}
	if posix.listen(listen_sock, 4) != .OK {
		posix.close(listen_sock)
		remote_server_drop(s)
		return .Listen
	}
	s.listener = new(Event_Manager_Fd_Watcher, allocator)
	event_manager_fd_watcher_init(s.listener, sock, {.Read}, .Urgent, remote_server_on_accept)
	remote_watcher_register(s.listener, .Listener, s, allocator)
	return .None
}

// remote_server_drop releases a server that failed to initialize and
// uninstalls the singleton.
remote_server_drop :: proc(s: ^Server) {
	context.allocator = s.allocator
	if remote_server_singleton == s {
		remote_server_singleton = nil
	}
	delete(s.session, s.allocator)
	s.session = ""
	delete(s.accepters)
	s.accepters = nil
	s.listener = nil
}

// remote_server_destroy releases a server made by remote_server_init,
// closing the session socket first like ~Server.
remote_server_destroy :: proc(s: ^Server) {
	context.allocator = s.allocator
	if s.listener != nil {
		remote_server_close_session(s)
	}
	for a in s.accepters {
		remote_accepter_destroy(a, s.allocator)
	}
	delete(s.accepters)
	s.accepters = nil
	delete(s.session, s.allocator)
	s.session = ""
	if remote_server_singleton == s {
		remote_server_singleton = nil
	}
}

// remote_server_close_session unlinks the session socket (unless
// do_unlink is false) and closes the listener (port of
// Server::close_session).
remote_server_close_session :: proc(s: ^Server, do_unlink := true) {
	if do_unlink {
		if path, err := remote_session_path(s.session, true, context.temp_allocator); err == .None {
			defer delete(path, context.temp_allocator)
			cpath := strings.clone_to_cstring(path, context.temp_allocator)
			posix.unlink(cpath)
		}
	}
	if s.listener != nil {
		event_manager_fd_watcher_close_fd(s.listener)
		event_manager_fd_watcher_destroy(s.listener)
		remote_watcher_unregister(s.listener)
		free(s.listener, s.allocator)
		s.listener = nil
	}
}

// remote_server_rename_session moves the session socket to a new
// name (port of Server::rename_session). An invalid name yields the
// path error; an existing target or a failed rename is (false,
// .None).
remote_server_rename_session :: proc(s: ^Server, name: string) -> (renamed: bool, err: Remote_Error) {
	old_path, old_err := remote_session_path(s.session, true, context.temp_allocator)
	if old_err != .None {
		return false, old_err
	}
	defer delete(old_path, context.temp_allocator)
	new_path, new_err := remote_session_path(name, false, context.temp_allocator)
	if new_err != .None {
		return false, new_err
	}
	defer delete(new_path, context.temp_allocator)
	if file_exists(new_path) {
		return false, .None
	}
	old_c := strings.clone_to_cstring(old_path, context.temp_allocator)
	new_c := strings.clone_to_cstring(new_path, context.temp_allocator)
	if posix.renameat(posix.AT_FDCWD, old_c, posix.AT_FDCWD, new_c) != .OK {
		return false, .None
	}
	delete(s.session, s.allocator)
	context.allocator = s.allocator
	s.session = strings.clone(name, s.allocator)
	return true, .None
}

// remote_server_is_daemon reports whether the server is daemonized
// (port of Server::is_daemon).
remote_server_is_daemon :: proc(s: ^Server) -> bool {
	return s.is_daemon
}

// remote_server_daemonize marks the server daemonized (port of
// Server::daemonize).
remote_server_daemonize :: proc(s: ^Server) {
	s.is_daemon = true
}

// remote_server_negotiating reports whether handshakes are in flight
// (port of Server::negotiating).
remote_server_negotiating :: proc(s: ^Server) -> bool {
	return len(s.accepters) > 0
}

// remote_server_remove_accepter drops and frees a handshake (port of
// Server::remove_accepter). The socket is not closed: on Connect it
// now belongs to the Remote_UI.
remote_server_remove_accepter :: proc(s: ^Server, accepter: ^Remote_Accepter) {
	for a, i in s.accepters {
		if a == accepter {
			unordered_remove(&s.accepters, i)
			remote_accepter_destroy(accepter, s.allocator)
			return
		}
	}
	assert(false, "removing unknown accepter")
}

// remote_server_on_accept accepts one connection and starts its
// handshake (port of the Server listener callback).
remote_server_on_accept :: proc(watcher: ^Event_Manager_Fd_Watcher, events: Event_Manager_Fd_Events, mode: Event_Manager_Mode) {
	owner, ok := remote_watcher_lookup(watcher)
	if !ok || owner.kind != .Listener {
		return
	}
	s := (^Server)(owner.ptr)
	client_addr := posix.sockaddr_un{}
	client_len := posix.socklen_t(size_of(posix.sockaddr_un))
	sock := posix.accept(posix.FD(watcher.fd), cast(^posix.sockaddr)(&client_addr), &client_len)
	if sock == posix.FD(-1) {
		debug_write_to_debug_buffer("accept failed")
		return
	}
	remote_set_cloexec(int(sock))
	context.allocator = s.allocator
	append(&s.accepters, remote_accepter_make(int(sock), s.allocator))
}

// ---------------------------------------------------------------------------
// Accepter
// ---------------------------------------------------------------------------

// remote_accepter_make starts a handshake on an accepted socket (port
// of Server::Accepter's constructor). The accepter is owned by the
// server's accepter list; removal goes through
// remote_server_remove_accepter.
remote_accepter_make :: proc(sock: int, allocator := context.allocator) -> ^Remote_Accepter {
	context.allocator = allocator
	a := new(Remote_Accepter, allocator)
	remote_msg_reader_init(&a.reader, allocator)
	event_manager_fd_watcher_init(&a.socket_watcher, sock, {.Read}, .Normal, remote_accepter_on_event)
	remote_watcher_register(&a.socket_watcher, .Accepter, a, allocator)
	return a
}

// remote_accepter_destroy releases a handshake. The socket is left
// open: the caller closes it first, or it moved to a Remote_UI.
remote_accepter_destroy :: proc(a: ^Remote_Accepter, allocator := context.allocator) {
	event_manager_fd_watcher_destroy(&a.socket_watcher)
	remote_watcher_unregister(&a.socket_watcher)
	remote_msg_reader_destroy(&a.reader, allocator)
	free(a, allocator)
}

// remote_accepter_on_event pumps a handshake socket (port of
// Accepter::handle_available_input's watcher callback).
remote_accepter_on_event :: proc(watcher: ^Event_Manager_Fd_Watcher, events: Event_Manager_Fd_Events, mode: Event_Manager_Mode) {
	owner, ok := remote_watcher_lookup(watcher)
	if !ok || owner.kind != .Accepter {
		return
	}
	a := (^Remote_Accepter)(owner.ptr)
	anc: Maybe(int) = nil
	done, err := remote_accepter_handle(a, watcher, mode, &anc)
	remote_close_maybe_fd(&anc)
	if done {
		return
	}
	if err != .None {
		debug_write_to_debug_buffer("accepting connection failed")
		event_manager_fd_watcher_close_fd(watcher)
		remote_server_remove_accepter(remote_server_instance(), a)
	}
}

// remote_accepter_handle reads one handshake message and acts on it.
// It returns done=true once the accepter was removed (Connect,
// Command, or an invalid introduction); otherwise done=false and err
// reports a socket failure for the caller to clean up. A taken
// stdin fd is moved out of anc; leftovers are closed by the caller.
remote_accepter_handle :: proc(a: ^Remote_Accepter, watcher: ^Event_Manager_Fd_Watcher, mode: Event_Manager_Mode, anc: ^Maybe(int)) -> (done: bool, err: Remote_Error) {
	s := remote_server_instance()
	sock := watcher.fd
	for !remote_msg_reader_ready(&a.reader) && file_fd_readable(sock) {
		if read_err := remote_msg_reader_read_available(&a.reader, sock, anc, s.allocator); read_err != .None {
			return false, read_err
		}
	}
	if mode != .Normal || !remote_msg_reader_ready(&a.reader) {
		return false, .None
	}
	switch remote_msg_reader_type(&a.reader) {
	case .Connect:
		return remote_accepter_handle_connect(a, s, sock, anc)
	case .Command:
		command, read_err := remote_msg_reader_read_string(&a.reader, s.allocator)
		remote_msg_reader_reset(&a.reader)
		if read_err != .None {
			return false, read_err
		}
		defer delete(command, s.allocator)
		if len(command) > 0 {
			ctx := context_make_empty(s.allocator)
			defer context_destroy(&ctx)
			shell_ctx := Shell_Context{}
			exec_err, exec_msg := command_manager_execute(command_manager_instance(), command, &ctx, &shell_ctx, s.allocator)
			if exec_err != .None {
				b := strings.builder_make(context.temp_allocator)
				strings.write_string(&b, "error running command '")
				strings.write_string(&b, command)
				strings.write_string(&b, "': ")
				strings.write_string(&b, exec_msg)
				debug_write_to_debug_buffer(strings.to_string(b))
				delete(exec_msg, s.allocator)
			}
		}
		event_manager_fd_watcher_close_fd(watcher)
		remote_server_remove_accepter(s, a)
		return true, .None
	case .Unknown, .Menu_Show, .Menu_Select, .Menu_Hide, .Info_Show, .Info_Hide, .Draw, .Draw_Status, .Refresh, .Set_Options, .Exit, .Key, .Paste:
		debug_write_to_debug_buffer("invalid introduction message received")
		event_manager_fd_watcher_close_fd(watcher)
		remote_server_remove_accepter(s, a)
		return true, .None
	}
	return false, .None
}

// remote_accepter_handle_connect serves a Connect handshake: it
// creates the server-side client around a new Remote_UI and removes
// the accepter (port of the MessageType::Connect case). The socket
// now belongs to the Remote_UI.
remote_accepter_handle_connect :: proc(a: ^Remote_Accepter, s: ^Server, sock: int, anc: ^Maybe(int)) -> (done: bool, err: Remote_Error) {
	context.allocator = s.allocator
	pid, pid_err := remote_msg_reader_read_i32(&a.reader)
	name, name_err := remote_msg_reader_read_string(&a.reader, s.allocator)
	init_cmds, cmds_err := remote_msg_reader_read_string(&a.reader, s.allocator)
	init_coord, coord_err := remote_msg_reader_read_optional_coord_buffer(&a.reader)
	dimensions, dims_err := remote_msg_reader_read_coord_display(&a.reader)
	env_vars, env_err := remote_msg_reader_read_string_map(&a.reader, s.allocator)
	remote_msg_reader_reset(&a.reader)
	if pid_err != .None || name_err != .None || cmds_err != .None || coord_err != .None || dims_err != .None || env_err != .None {
		delete(name, s.allocator)
		delete(init_cmds, s.allocator)
		env_vars_free(&env_vars, s.allocator)
		for e in ([6]Remote_Error{pid_err, name_err, cmds_err, coord_err, dims_err, env_err}) {
			if e != .None {
				return false, e
			}
		}
	}
	if stdin, ok := anc.?; ok {
		anc^ = nil
		fifo_name := buffer_utils_generate_buffer_name("*stdin-{}*", context.temp_allocator)
		_, fifo_err := buffer_utils_create_fifo_buffer(fifo_name, stdin, Buffer_Flags{}, .Not_Initially)
		if fifo_err != .None {
			posix.close(posix.FD(stdin))
			delete(name, s.allocator)
			delete(init_cmds, s.allocator)
			env_vars_free(&env_vars, s.allocator)
			return false, .Disconnected
		}
	}
	ui := remote_ui_make(sock, dimensions, s.allocator)
	on_exit := Client_On_Exit_Callback{call = remote_ui_on_client_exit, data = ui}
	// .Dummy destroys the handle opaquely (plain free): the Remote_UI
	// itself is owned by the disconnect path, not the client.
	_, create_err := client_manager_create_client(
		client_manager_instance(), ui.ui, .Dummy, int(pid), name, Env_Var_Map(env_vars), init_cmds, "", init_coord, on_exit,
	)
	if create_err != .None {
		remote_ui_destroy(ui)
		delete(name, s.allocator)
		delete(init_cmds, s.allocator)
		env_vars_free(&env_vars, s.allocator)
		return false, .Disconnected
	}
	remote_server_remove_accepter(s, a)
	return true, .None
}

// buffer_utils_generate_buffer_name / buffer_utils_create_fifo_buffer merged
// from the buffer_utils module; stubs (and KNOTFIX_Auto_Scroll) deleted.
