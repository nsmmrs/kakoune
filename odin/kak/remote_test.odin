// Tests for the remote port. src/remote.cc has no C++ UnitTest, so
// these are edge-case tests written against the documented C++
// semantics: message encode/decode round-trips, partial-frame
// feeding, malformed frame rejection, session path validation, and
// hermetic socketpair tests (no live server).
package kak

import "core:mem"
import "core:sync"
import "core:testing"
import posix "core:sys/posix"

// message tags match the C++ MessageType declaration order
@(test)
remote_test_message_type_values :: proc(t: ^testing.T) {
	testing.expect_value(t, u8(Remote_Message_Type.Unknown), 0)
	testing.expect_value(t, u8(Remote_Message_Type.Connect), 1)
	testing.expect_value(t, u8(Remote_Message_Type.Command), 2)
	testing.expect_value(t, u8(Remote_Message_Type.Menu_Show), 3)
	testing.expect_value(t, u8(Remote_Message_Type.Menu_Select), 4)
	testing.expect_value(t, u8(Remote_Message_Type.Menu_Hide), 5)
	testing.expect_value(t, u8(Remote_Message_Type.Info_Show), 6)
	testing.expect_value(t, u8(Remote_Message_Type.Info_Hide), 7)
	testing.expect_value(t, u8(Remote_Message_Type.Draw), 8)
	testing.expect_value(t, u8(Remote_Message_Type.Draw_Status), 9)
	testing.expect_value(t, u8(Remote_Message_Type.Refresh), 10)
	testing.expect_value(t, u8(Remote_Message_Type.Set_Options), 11)
	testing.expect_value(t, u8(Remote_Message_Type.Exit), 12)
	testing.expect_value(t, u8(Remote_Message_Type.Key), 13)
	testing.expect_value(t, u8(Remote_Message_Type.Paste), 14)
	testing.expect_value(t, remote_HEADER_SIZE, 5)
}

// the fd control message matches CMSG_SPACE/CMSG_LEN
@(test)
remote_test_cmsg_layout :: proc(t: ^testing.T) {
	testing.expect_value(t, size_of(Remote_Cmsg_Fd), remote_cmsg_space_int())
	testing.expect_value(t, offset_of(Remote_Cmsg_Fd, fd), uintptr(remote_cmsg_align(size_of(posix.cmsghdr))))
	testing.expect_value(t, remote_cmsg_len_int(), remote_cmsg_align(size_of(posix.cmsghdr)) + size_of(i32))
}

// begin/end frame a message with its tag and patched size
@(test)
remote_test_writer_framing :: proc(t: ^testing.T) {
	buffer := make(Remote_Buffer)
	defer delete(buffer)
	w := remote_msg_writer_begin(&buffer, .Key)
	remote_msg_write_u8(&w, 0xAB)
	remote_msg_writer_end(&w)
	testing.expect_value(t, len(buffer), 6)
	testing.expect_value(t, buffer[0], u8(Remote_Message_Type.Key))
	testing.expect_value(t, buffer[1], 6)
	testing.expect_value(t, buffer[2], 0)
	testing.expect_value(t, buffer[5], 0xAB)
}

// scalar fields round-trip, including extremes
@(test)
remote_test_roundtrip_scalars :: proc(t: ^testing.T) {
	buffer := make(Remote_Buffer)
	defer delete(buffer)
	w := remote_msg_writer_begin(&buffer, .Refresh)
	remote_msg_write_u8(&w, 0)
	remote_msg_write_u8(&w, 255)
	remote_msg_write_u32(&w, 0)
	remote_msg_write_u32(&w, max(u32))
	remote_msg_write_i32(&w, min(i32))
	remote_msg_write_i32(&w, -1)
	remote_msg_write_i32(&w, max(i32))
	remote_msg_write_bool(&w, false)
	remote_msg_write_bool(&w, true)
	remote_msg_writer_end(&w)

	r: Remote_Msg_Reader
	remote_msg_reader_init(&r)
	defer remote_msg_reader_destroy(&r)
	testing.expect_value(t, remote_msg_reader_feed(&r, buffer[:]), Remote_Error.None)
	testing.expect(t, remote_msg_reader_ready(&r))
	testing.expect_value(t, remote_msg_reader_type(&r), Remote_Message_Type.Refresh)

	a, a_err := remote_msg_reader_read_u8(&r)
	testing.expect_value(t, a_err, Remote_Error.None)
	testing.expect_value(t, a, 0)
	b, _ := remote_msg_reader_read_u8(&r)
	testing.expect_value(t, b, 255)
	c, _ := remote_msg_reader_read_u32(&r)
	testing.expect_value(t, c, 0)
	d, _ := remote_msg_reader_read_u32(&r)
	testing.expect_value(t, d, max(u32))
	e, _ := remote_msg_reader_read_i32(&r)
	testing.expect_value(t, e, min(i32))
	f, _ := remote_msg_reader_read_i32(&r)
	testing.expect_value(t, f, -1)
	g, _ := remote_msg_reader_read_i32(&r)
	testing.expect_value(t, g, max(i32))
	h, _ := remote_msg_reader_read_bool(&r)
	testing.expect(t, !h)
	i, i_err := remote_msg_reader_read_bool(&r)
	testing.expect_value(t, i_err, Remote_Error.None)
	testing.expect(t, i)
	_, tail_err := remote_msg_reader_read_u8(&r)
	testing.expect_value(t, tail_err, Remote_Error.Bad_Frame)
}

// strings round-trip: empty, ascii, unicode, embedded NUL
@(test)
remote_test_roundtrip_string :: proc(t: ^testing.T) {
	cases := [?]string{"", "hello", "héllo wörld ✓", "a\x00b"}
	buffer := make(Remote_Buffer)
	defer delete(buffer)
	w := remote_msg_writer_begin(&buffer, .Paste)
	for s in cases {
		remote_msg_write_string(&w, s)
	}
	remote_msg_writer_end(&w)

	r: Remote_Msg_Reader
	remote_msg_reader_init(&r)
	defer remote_msg_reader_destroy(&r)
	testing.expect_value(t, remote_msg_reader_feed(&r, buffer[:]), Remote_Error.None)
	for want in cases {
		got, err := remote_msg_reader_read_string(&r)
		defer delete(got)
		testing.expect_value(t, err, Remote_Error.None)
		testing.expect_value(t, got, want)
	}
}

// keys round-trip, including modifiers and named keys
@(test)
remote_test_roundtrip_key :: proc(t: ^testing.T) {
	cases := [?]Keys_Key{
		{modifiers = keys_MOD_NONE, key = 'a'},
		{modifiers = keys_MOD_CONTROL, key = 'c'},
		{modifiers = keys_MOD_ALT | keys_MOD_SHIFT, key = keys_RETURN},
		{modifiers = keys_MOD_RESIZE, key = keys_encode_coord(Keys_Coord{line = 24, column = 80})},
	}
	buffer := make(Remote_Buffer)
	defer delete(buffer)
	w := remote_msg_writer_begin(&buffer, .Key)
	for k in cases {
		remote_msg_write_key(&w, k)
	}
	remote_msg_writer_end(&w)

	r: Remote_Msg_Reader
	remote_msg_reader_init(&r)
	defer remote_msg_reader_destroy(&r)
	testing.expect_value(t, remote_msg_reader_feed(&r, buffer[:]), Remote_Error.None)
	for want in cases {
		got, err := remote_msg_reader_read_key(&r)
		testing.expect_value(t, err, Remote_Error.None)
		testing.expect_value(t, got, want)
	}
	coord := keys_coord(cases[3])
	testing.expect_value(t, coord.line, 24)
	testing.expect_value(t, coord.column, 80)
}

// colors round-trip: named and RGB
@(test)
remote_test_roundtrip_color :: proc(t: ^testing.T) {
	rgb, rgb_err := color_from_rgb(10, 20, 30)
	testing.expect_value(t, rgb_err, Color_Error.None)
	cases := [?]Color{color_from_named(.Default), color_from_named(.Red), rgb}
	buffer := make(Remote_Buffer)
	defer delete(buffer)
	w := remote_msg_writer_begin(&buffer, .Refresh)
	for c in cases {
		remote_msg_write_color(&w, c)
	}
	remote_msg_writer_end(&w)

	r: Remote_Msg_Reader
	remote_msg_reader_init(&r)
	defer remote_msg_reader_destroy(&r)
	testing.expect_value(t, remote_msg_reader_feed(&r, buffer[:]), Remote_Error.None)
	for want in cases {
		got, err := remote_msg_reader_read_color(&r)
		testing.expect_value(t, err, Remote_Error.None)
		testing.expect_value(t, got, want)
	}
}

// a face encodes as the raw 16-byte C++ layout
@(test)
remote_test_face_wire_layout :: proc(t: ^testing.T) {
	face := Face{
		fg         = color_from_named(.Red),
		bg         = color_from_named(.Default),
		attributes = {.Underline, .Bold},
		underline  = color_from_named(.Blue),
	}
	buffer := make(Remote_Buffer)
	defer delete(buffer)
	w := remote_msg_writer_begin(&buffer, .Refresh)
	remote_msg_write_face(&w, face)
	remote_msg_writer_end(&w)
	// tag, r, g, b per color; attributes bit1|bit6 = 0x42.
	want := [16]u8{2, 0, 0, 0, 0, 0, 0, 0, 0x42, 0, 0, 0, 5, 0, 0, 0}
	testing.expect_value(t, len(buffer), remote_HEADER_SIZE + 16)
	for want_byte, i in want {
		testing.expect_value(t, buffer[remote_HEADER_SIZE + i], want_byte)
	}

	r: Remote_Msg_Reader
	remote_msg_reader_init(&r)
	defer remote_msg_reader_destroy(&r)
	testing.expect_value(t, remote_msg_reader_feed(&r, buffer[:]), Remote_Error.None)
	got, err := remote_msg_reader_read_face(&r)
	testing.expect_value(t, err, Remote_Error.None)
	testing.expect_value(t, got, face)
}

// every attribute flag survives the wire mapping
@(test)
remote_test_roundtrip_face_attributes :: proc(t: ^testing.T) {
	all := Face_Attribute{.Underline, .Curly_Underline, .Double_Underline, .Reverse, .Blink, .Bold, .Dim, .Italic, .Strikethrough, .Final_Fg, .Final_Bg, .Final_Attr}
	wire := remote_face_attributes_to_wire(all)
	testing.expect_value(t, wire, i32(0x1FFE))
	testing.expect_value(t, remote_face_attributes_from_wire(wire), all)
	testing.expect_value(t, remote_face_attributes_from_wire(0), Face_Attribute{})
	// unknown bits (bit0, bit13+) are dropped
	testing.expect_value(t, remote_face_attributes_from_wire(1 | (1 << 13)), Face_Attribute{})
}

// coords round-trip, including -1 targets
@(test)
remote_test_roundtrip_coords :: proc(t: ^testing.T) {
	buffer := make(Remote_Buffer)
	defer delete(buffer)
	w := remote_msg_writer_begin(&buffer, .Refresh)
	remote_msg_write_coord_display(&w, Coord_Display{line = 3, column = 7})
	remote_msg_write_coord_display(&w, Coord_Display{line = -1, column = -1})
	remote_msg_write_coord_buffer(&w, Coord_Buffer{line = 1000000, column = 42})
	remote_msg_write_optional_coord_buffer(&w, nil)
	remote_msg_write_optional_coord_buffer(&w, Coord_Buffer{line = 1, column = 2})
	remote_msg_writer_end(&w)

	r: Remote_Msg_Reader
	remote_msg_reader_init(&r)
	defer remote_msg_reader_destroy(&r)
	testing.expect_value(t, remote_msg_reader_feed(&r, buffer[:]), Remote_Error.None)
	d1, _ := remote_msg_reader_read_coord_display(&r)
	testing.expect_value(t, d1, Coord_Display{line = 3, column = 7})
	d2, _ := remote_msg_reader_read_coord_display(&r)
	testing.expect_value(t, d2, Coord_Display{line = -1, column = -1})
	b1, _ := remote_msg_reader_read_coord_buffer(&r)
	testing.expect_value(t, b1, Coord_Buffer{line = 1000000, column = 42})
	o1, o1_err := remote_msg_reader_read_optional_coord_buffer(&r)
	testing.expect_value(t, o1_err, Remote_Error.None)
	testing.expect_value(t, o1, Maybe(Coord_Buffer)(nil))
	o2, _ := remote_msg_reader_read_optional_coord_buffer(&r)
	testing.expect_value(t, o2, Maybe(Coord_Buffer)(Coord_Buffer{line = 1, column = 2}))
}

// atoms, lines and buffers round-trip with owned text
@(test)
remote_test_roundtrip_display :: proc(t: ^testing.T) {
	face := Face{fg = color_from_named(.Green), attributes = {.Bold}}
	line := display_buffer_line_make()
	defer display_buffer_line_destroy(&line)
	display_buffer_line_push_back(&line, display_buffer_atom_text("one", face))
	display_buffer_line_push_back(&line, display_buffer_atom_text("", Face{}))
	empty := display_buffer_line_make()
	defer display_buffer_line_destroy(&empty)

	buffer := make(Remote_Buffer)
	defer delete(buffer)
	w := remote_msg_writer_begin(&buffer, .Draw)
	remote_msg_write_display_line(&w, line)
	remote_msg_write_display_line(&w, empty)
	remote_msg_writer_end(&w)

	r: Remote_Msg_Reader
	remote_msg_reader_init(&r)
	defer remote_msg_reader_destroy(&r)
	testing.expect_value(t, remote_msg_reader_feed(&r, buffer[:]), Remote_Error.None)
	got, err := remote_msg_reader_read_display_line(&r)
	defer remote_destroy_display_line(&got)
	testing.expect_value(t, err, Remote_Error.None)
	testing.expect_value(t, len(got.atoms), 2)
	testing.expect_value(t, display_buffer_atom_content(got.atoms[0]), "one")
	testing.expect_value(t, got.atoms[0].face, face)
	testing.expect_value(t, display_buffer_atom_content(got.atoms[1]), "")
	got_empty, empty_err := remote_msg_reader_read_display_line(&r)
	defer remote_destroy_display_line(&got_empty)
	testing.expect_value(t, empty_err, Remote_Error.None)
	testing.expect_value(t, len(got_empty.atoms), 0)
}

// line vectors and display buffers round-trip
@(test)
remote_test_roundtrip_lines_buffer :: proc(t: ^testing.T) {
	face := Face{fg = color_from_named(.Blue)}
	l1 := display_buffer_line_make_text("first", face)
	defer display_buffer_line_destroy(&l1)
	l2 := display_buffer_line_make_text("second", Face{})
	defer display_buffer_line_destroy(&l2)

	lines := make(Display_Line_List, 2)
	defer delete(lines)
	lines[0], lines[1] = l1, l2
	buffer := make(Remote_Buffer)
	defer delete(buffer)
	w := remote_msg_writer_begin(&buffer, .Draw)
	remote_msg_write_display_buffer(&w, Display_Buffer{lines = lines})
	remote_msg_writer_end(&w)

	r: Remote_Msg_Reader
	remote_msg_reader_init(&r)
	defer remote_msg_reader_destroy(&r)
	testing.expect_value(t, remote_msg_reader_feed(&r, buffer[:]), Remote_Error.None)
	got, err := remote_msg_reader_read_display_buffer(&r)
	defer remote_destroy_display_buffer(&got)
	testing.expect_value(t, err, Remote_Error.None)
	testing.expect_value(t, len(got.lines), 2)
	testing.expect_value(t, display_buffer_atom_content(got.lines[0].atoms[0]), "first")
	testing.expect_value(t, got.lines[0].atoms[0].face, face)
	testing.expect_value(t, display_buffer_atom_content(got.lines[1].atoms[0]), "second")
}

// every style ordinal round-trips
@(test)
remote_test_roundtrip_styles :: proc(t: ^testing.T) {
	buffer := make(Remote_Buffer)
	defer delete(buffer)
	w := remote_msg_writer_begin(&buffer, .Refresh)
	for s in User_Interface_Menu_Style {
		remote_msg_write_menu_style(&w, s)
	}
	for s in User_Interface_Info_Style {
		remote_msg_write_info_style(&w, s)
	}
	for s in User_Interface_Status_Style {
		remote_msg_write_status_style(&w, s)
	}
	remote_msg_writer_end(&w)

	r: Remote_Msg_Reader
	remote_msg_reader_init(&r)
	defer remote_msg_reader_destroy(&r)
	testing.expect_value(t, remote_msg_reader_feed(&r, buffer[:]), Remote_Error.None)
	for want in User_Interface_Menu_Style {
		got, err := remote_msg_reader_read_menu_style(&r)
		testing.expect_value(t, err, Remote_Error.None)
		testing.expect_value(t, got, want)
	}
	for want in User_Interface_Info_Style {
		got, err := remote_msg_reader_read_info_style(&r)
		testing.expect_value(t, err, Remote_Error.None)
		testing.expect_value(t, got, want)
	}
	for want in User_Interface_Status_Style {
		got, err := remote_msg_reader_read_status_style(&r)
		testing.expect_value(t, err, Remote_Error.None)
		testing.expect_value(t, got, want)
	}
}

// string maps round-trip, including empty maps and values
@(test)
remote_test_roundtrip_map :: proc(t: ^testing.T) {
	m := make(map[string]string)
	defer delete(m)
	m["a"] = "1"
	m["empty"] = ""
	m["uni"] = "✓"
	empty := make(map[string]string)
	defer delete(empty)
	buffer := make(Remote_Buffer)
	defer delete(buffer)
	w := remote_msg_writer_begin(&buffer, .Set_Options)
	remote_msg_write_string_map(&w, m)
	remote_msg_write_string_map(&w, empty)
	remote_msg_writer_end(&w)

	r: Remote_Msg_Reader
	remote_msg_reader_init(&r)
	defer remote_msg_reader_destroy(&r)
	testing.expect_value(t, remote_msg_reader_feed(&r, buffer[:]), Remote_Error.None)
	got, err := remote_msg_reader_read_string_map(&r)
	defer env_vars_free(&got)
	testing.expect_value(t, err, Remote_Error.None)
	testing.expect_value(t, len(got), 3)
	testing.expect_value(t, got["a"], "1")
	testing.expect_value(t, got["empty"], "")
	testing.expect_value(t, got["uni"], "✓")
	got_empty, empty_err := remote_msg_reader_read_string_map(&r)
	defer env_vars_free(&got_empty)
	testing.expect_value(t, empty_err, Remote_Error.None)
	testing.expect_value(t, len(got_empty), 0)
}

// the full Connect payload round-trips in field order
@(test)
remote_test_roundtrip_connect :: proc(t: ^testing.T) {
	env := make(map[string]string)
	defer delete(env)
	env["kak_session"] = "s"
	env["PATH"] = "/bin"
	buffer := make(Remote_Buffer)
	defer delete(buffer)
	w := remote_msg_writer_begin(&buffer, .Connect)
	remote_msg_write_i32(&w, 1234)
	remote_msg_write_string(&w, "client0")
	remote_msg_write_string(&w, "edit foo")
	remote_msg_write_optional_coord_buffer(&w, Coord_Buffer{line = 5, column = 6})
	remote_msg_write_coord_display(&w, Coord_Display{line = 24, column = 80})
	remote_msg_write_string_map(&w, env)
	remote_msg_writer_end(&w)

	r: Remote_Msg_Reader
	remote_msg_reader_init(&r)
	defer remote_msg_reader_destroy(&r)
	testing.expect_value(t, remote_msg_reader_feed(&r, buffer[:]), Remote_Error.None)
	testing.expect(t, remote_msg_reader_ready(&r))
	testing.expect_value(t, remote_msg_reader_type(&r), Remote_Message_Type.Connect)
	pid, _ := remote_msg_reader_read_i32(&r)
	testing.expect_value(t, pid, 1234)
	name, _ := remote_msg_reader_read_string(&r)
	defer delete(name)
	testing.expect_value(t, name, "client0")
	cmds, _ := remote_msg_reader_read_string(&r)
	defer delete(cmds)
	testing.expect_value(t, cmds, "edit foo")
	coord, _ := remote_msg_reader_read_optional_coord_buffer(&r)
	testing.expect_value(t, coord, Maybe(Coord_Buffer)(Coord_Buffer{line = 5, column = 6}))
	dims, _ := remote_msg_reader_read_coord_display(&r)
	testing.expect_value(t, dims, Coord_Display{line = 24, column = 80})
	got_env, env_err := remote_msg_reader_read_string_map(&r)
	defer env_vars_free(&got_env)
	testing.expect_value(t, env_err, Remote_Error.None)
	testing.expect_value(t, got_env["kak_session"], "s")
}

// the Command payload round-trips
@(test)
remote_test_roundtrip_command :: proc(t: ^testing.T) {
	buffer := make(Remote_Buffer)
	defer delete(buffer)
	w := remote_msg_writer_begin(&buffer, .Command)
	remote_msg_write_string(&w, "echo hello")
	remote_msg_writer_end(&w)

	r: Remote_Msg_Reader
	remote_msg_reader_init(&r)
	defer remote_msg_reader_destroy(&r)
	testing.expect_value(t, remote_msg_reader_feed(&r, buffer[:]), Remote_Error.None)
	testing.expect_value(t, remote_msg_reader_type(&r), Remote_Message_Type.Command)
	cmd, err := remote_msg_reader_read_string(&r)
	defer delete(cmd)
	testing.expect_value(t, err, Remote_Error.None)
	testing.expect_value(t, cmd, "echo hello")
}

// the full Draw payload round-trips in field order
@(test)
remote_test_roundtrip_draw :: proc(t: ^testing.T) {
	atom_face := Face{fg = color_from_named(.Yellow)}
	line := display_buffer_line_make_text("status", atom_face)
	defer display_buffer_line_destroy(&line)
	lines := make(Display_Line_List, 1)
	defer delete(lines)
	lines[0] = line
	buffer := make(Remote_Buffer)
	defer delete(buffer)
	w := remote_msg_writer_begin(&buffer, .Draw)
	remote_msg_write_display_buffer(&w, Display_Buffer{lines = lines})
	remote_msg_write_coord_display(&w, Coord_Display{line = 1, column = 2})
	remote_msg_write_face(&w, Face{})
	remote_msg_write_face(&w, Face{bg = color_from_named(.Black)})
	remote_msg_write_i32(&w, 3)
	remote_msg_writer_end(&w)

	r: Remote_Msg_Reader
	remote_msg_reader_init(&r)
	defer remote_msg_reader_destroy(&r)
	testing.expect_value(t, remote_msg_reader_feed(&r, buffer[:]), Remote_Error.None)
	db, err := remote_msg_reader_read_display_buffer(&r)
	defer remote_destroy_display_buffer(&db)
	testing.expect_value(t, err, Remote_Error.None)
	testing.expect_value(t, len(db.lines), 1)
	testing.expect_value(t, display_buffer_atom_content(db.lines[0].atoms[0]), "status")
	cursor, _ := remote_msg_reader_read_coord_display(&r)
	testing.expect_value(t, cursor, Coord_Display{line = 1, column = 2})
	def, _ := remote_msg_reader_read_face(&r)
	testing.expect_value(t, def, Face{})
	pad, _ := remote_msg_reader_read_face(&r)
	testing.expect_value(t, pad, Face{bg = color_from_named(.Black)})
	widget, w_err := remote_msg_reader_read_i32(&r)
	testing.expect_value(t, w_err, Remote_Error.None)
	testing.expect_value(t, widget, 3)
}

// feeding one byte at a time: ready only at the very end
@(test)
remote_test_partial_feed :: proc(t: ^testing.T) {
	buffer := make(Remote_Buffer)
	defer delete(buffer)
	w := remote_msg_writer_begin(&buffer, .Exit)
	remote_msg_write_i32(&w, 7)
	remote_msg_writer_end(&w)

	r: Remote_Msg_Reader
	remote_msg_reader_init(&r)
	defer remote_msg_reader_destroy(&r)
	for i in 0 ..< len(buffer) - 1 {
		testing.expect_value(t, remote_msg_reader_feed(&r, buffer[i:i + 1]), Remote_Error.None)
		testing.expect(t, !remote_msg_reader_ready(&r))
	}
	testing.expect_value(t, remote_msg_reader_feed(&r, buffer[len(buffer) - 1:]), Remote_Error.None)
	testing.expect(t, remote_msg_reader_ready(&r))
	testing.expect_value(t, remote_msg_reader_type(&r), Remote_Message_Type.Exit)
	status, err := remote_msg_reader_read_i32(&r)
	testing.expect_value(t, err, Remote_Error.None)
	testing.expect_value(t, status, 7)
}

// a size below the header size is rejected
@(test)
remote_test_feed_bad_size :: proc(t: ^testing.T) {
	frames := [?][]byte{
		[]byte{u8(Remote_Message_Type.Key), 0, 0, 0, 0},
		[]byte{u8(Remote_Message_Type.Key), 4, 0, 0, 0},
	}
	for bad in frames {
		r: Remote_Msg_Reader
		remote_msg_reader_init(&r)
		defer remote_msg_reader_destroy(&r)
		testing.expect_value(t, remote_msg_reader_feed(&r, bad), Remote_Error.Bad_Frame)
		testing.expect(t, !remote_msg_reader_ready(&r))
	}
}

// truncated fields are rejected
@(test)
remote_test_truncated_field :: proc(t: ^testing.T) {
	buffer := make(Remote_Buffer)
	defer delete(buffer)
	w := remote_msg_writer_begin(&buffer, .Paste)
	remote_msg_write_string(&w, "hello")
	remote_msg_writer_end(&w)

	r: Remote_Msg_Reader
	remote_msg_reader_init(&r)
	defer remote_msg_reader_destroy(&r)
	// whole frame present, string length claims more than it holds
	testing.expect_value(t, remote_msg_reader_feed(&r, buffer[:]), Remote_Error.None)
	testing.expect(t, remote_msg_reader_ready(&r))
	r.stream[remote_HEADER_SIZE] = 99
	s, err := remote_msg_reader_read_string(&r)
	testing.expect_value(t, err, Remote_Error.Bad_Frame)
	testing.expect_value(t, s, "")
}

// a negative string length is rejected
@(test)
remote_test_negative_string_length :: proc(t: ^testing.T) {
	buffer := make(Remote_Buffer)
	defer delete(buffer)
	w := remote_msg_writer_begin(&buffer, .Paste)
	remote_msg_write_i32(&w, -1)
	remote_msg_writer_end(&w)

	r: Remote_Msg_Reader
	remote_msg_reader_init(&r)
	defer remote_msg_reader_destroy(&r)
	testing.expect_value(t, remote_msg_reader_feed(&r, buffer[:]), Remote_Error.None)
	_, err := remote_msg_reader_read_string(&r)
	testing.expect_value(t, err, Remote_Error.Bad_Frame)
}

// out-of-range style ordinals are rejected
@(test)
remote_test_bad_style_ordinal :: proc(t: ^testing.T) {
	buffer := make(Remote_Buffer)
	defer delete(buffer)
	w := remote_msg_writer_begin(&buffer, .Refresh)
	remote_msg_write_i32(&w, -1)
	remote_msg_write_i32(&w, 99)
	remote_msg_writer_end(&w)

	r: Remote_Msg_Reader
	remote_msg_reader_init(&r)
	defer remote_msg_reader_destroy(&r)
	testing.expect_value(t, remote_msg_reader_feed(&r, buffer[:]), Remote_Error.None)
	_, err1 := remote_msg_reader_read_menu_style(&r)
	testing.expect_value(t, err1, Remote_Error.Bad_Frame)
	_, err2 := remote_msg_reader_read_status_style(&r)
	testing.expect_value(t, err2, Remote_Error.Bad_Frame)
}

// one reader serves consecutive messages after reset
@(test)
remote_test_reader_reset_reuse :: proc(t: ^testing.T) {
	first := make(Remote_Buffer)
	defer delete(first)
	w1 := remote_msg_writer_begin(&first, .Menu_Hide)
	remote_msg_writer_end(&w1)
	second := make(Remote_Buffer)
	defer delete(second)
	w2 := remote_msg_writer_begin(&second, .Info_Hide)
	remote_msg_writer_end(&w2)

	r: Remote_Msg_Reader
	remote_msg_reader_init(&r)
	defer remote_msg_reader_destroy(&r)
	testing.expect_value(t, remote_msg_reader_feed(&r, first[:]), Remote_Error.None)
	testing.expect(t, remote_msg_reader_ready(&r))
	testing.expect_value(t, remote_msg_reader_type(&r), Remote_Message_Type.Menu_Hide)
	remote_msg_reader_reset(&r)
	testing.expect(t, !remote_msg_reader_ready(&r))
	testing.expect_value(t, remote_msg_reader_feed(&r, second[:]), Remote_Error.None)
	testing.expect(t, remote_msg_reader_ready(&r))
	testing.expect_value(t, remote_msg_reader_type(&r), Remote_Message_Type.Info_Hide)
}

// session names are validated like the C++
@(test)
remote_test_session_path :: proc(t: ^testing.T) {
	path, err := remote_session_path("mysession1_-")
	defer delete(path)
	testing.expect_value(t, err, Remote_Error.None)
	testing.expect(t, len(path) > len("mysession1_-"))
	testing.expect_value(t, path[len(path) - len("mysession1_-"):], "mysession1_-")

	bad_names := [?]string{"a/b", "a b", "a.b", "séss", "a:b"}
	for bad in bad_names {
		_, bad_err := remote_session_path(bad)
		testing.expect_value(t, bad_err, Remote_Error.Invalid_Session_Name)
	}
	// the empty name is valid, like the C++ all_of on an empty range
	empty_path, empty_err := remote_session_path("")
	defer delete(empty_path)
	testing.expect_value(t, empty_err, Remote_Error.None)

	long := make([]u8, 200, context.temp_allocator)
	for i in 0 ..< len(long) {
		long[i] = 'a'
	}
	_, long_err := remote_session_path(string(long))
	testing.expect_value(t, long_err, Remote_Error.Socket_Path_Too_Long)
}

// session directory and user name are usable
@(test)
remote_test_session_directory :: proc(t: ^testing.T) {
	dir := remote_session_directory()
	defer delete(dir)
	testing.expect(t, len(dir) > 0)
	user := remote_get_user_name()
	defer delete(user)
	testing.expect(t, len(user) > 0)
}

// check_session rejects bad names and reports missing sessions
@(test)
remote_test_check_session :: proc(t: ^testing.T) {
	up, err := remote_check_session("no-such-remote-test-session")
	testing.expect_value(t, err, Remote_Error.None)
	testing.expect(t, !up)
	_, bad_err := remote_check_session("bad/name")
	testing.expect_value(t, bad_err, Remote_Error.Invalid_Session_Name)
}

// a socketpair carries a framed message end to end
@(test)
remote_test_socketpair_roundtrip :: proc(t: ^testing.T) {
	fds: [2]posix.FD
	testing.expect_value(t, posix.socketpair(.UNIX, .STREAM, .IP, &fds), posix.result.OK)
	defer posix.close(fds[0])
	defer posix.close(fds[1])

	send := make(Remote_Buffer)
	defer delete(send)
	w := remote_msg_writer_begin(&send, .Key)
	remote_msg_write_key(&w, Keys_Key{modifiers = keys_MOD_CONTROL, key = 'x'})
	remote_msg_writer_end(&w)
	drained, send_err := remote_send_data(int(fds[0]), &send)
	testing.expect_value(t, send_err, Remote_Error.None)
	testing.expect(t, drained)

	r: Remote_Msg_Reader
	remote_msg_reader_init(&r)
	defer remote_msg_reader_destroy(&r)
	anc: Maybe(int) = nil
	for !remote_msg_reader_ready(&r) {
		testing.expect_value(t, remote_msg_reader_read_available(&r, int(fds[1]), &anc), Remote_Error.None)
	}
	testing.expect_value(t, anc, Maybe(int)(nil))
	testing.expect_value(t, remote_msg_reader_type(&r), Remote_Message_Type.Key)
	key, err := remote_msg_reader_read_key(&r)
	testing.expect_value(t, err, Remote_Error.None)
	testing.expect_value(t, key, Keys_Key{modifiers = keys_MOD_CONTROL, key = 'x'})
}

// pass an fd over a socketpair as ancillary data
@(test)
remote_test_socketpair_ancillary_fd :: proc(t: ^testing.T) {
	fds: [2]posix.FD
	testing.expect_value(t, posix.socketpair(.UNIX, .STREAM, .IP, &fds), posix.result.OK)
	defer posix.close(fds[0])
	defer posix.close(fds[1])
	pass: [2]posix.FD
	testing.expect_value(t, posix.pipe(&pass), posix.result.OK)
	defer posix.close(pass[0])
	defer posix.close(pass[1])

	send := make(Remote_Buffer)
	defer delete(send)
	w := remote_msg_writer_begin(&send, .Connect)
	remote_msg_write_i32(&w, 0)
	remote_msg_writer_end(&w)
	drained, send_err := remote_send_data(int(fds[0]), &send, int(pass[1]))
	testing.expect_value(t, send_err, Remote_Error.None)
	testing.expect(t, drained)

	r: Remote_Msg_Reader
	remote_msg_reader_init(&r)
	defer remote_msg_reader_destroy(&r)
	anc: Maybe(int) = nil
	defer remote_close_maybe_fd(&anc)
	for !remote_msg_reader_ready(&r) {
		testing.expect_value(t, remote_msg_reader_read_available(&r, int(fds[1]), &anc), Remote_Error.None)
	}
	received, ok := anc.?
	testing.expect(t, ok)
	if ok {
		// the received fd is a live duplicate of the pipe end
		st: posix.stat_t
		testing.expect_value(t, posix.fstat(posix.FD(received), &st), posix.result.OK)
		orig: posix.stat_t
		testing.expect_value(t, posix.fstat(pass[1], &orig), posix.result.OK)
		testing.expect_value(t, st.st_ino, orig.st_ino)
	}
}

// a closed peer reads as disconnected
@(test)
remote_test_socketpair_disconnected :: proc(t: ^testing.T) {
	fds: [2]posix.FD
	testing.expect_value(t, posix.socketpair(.UNIX, .STREAM, .IP, &fds), posix.result.OK)
	posix.close(fds[0])

	r: Remote_Msg_Reader
	remote_msg_reader_init(&r)
	defer remote_msg_reader_destroy(&r)
	anc: Maybe(int) = nil
	testing.expect_value(
		t,
		remote_msg_reader_read_available(&r, int(fds[1]), &anc),
		Remote_Error.Disconnected,
	)
	posix.close(fds[1])
}

// a disconnected Remote_UI is destroyed exactly once through the
// client path: the event callback closes the socket (like the server
// loop observes before removing the client), then main_destroy_ui's
// .Remote case unregisters the watcher and frees the struct, the
// handle and the socket with no leaks
@(test)
remote_test_ui_disconnect_destroy :: proc(t: ^testing.T) {
	sync.mutex_lock(&event_manager_test_singleton_mutex)
	defer sync.mutex_unlock(&event_manager_test_singleton_mutex)

	manager: Event_Manager
	event_manager_init(&manager)
	defer event_manager_destroy(&manager)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)

	fds: [2]posix.FD
	testing.expect_value(t, posix.socketpair(.UNIX, .STREAM, .IP, &fds), posix.result.OK)
	sock := int(fds[0])
	// fds[0] moves to the Remote_UI; fds[1] is the peer client end.
	ui := remote_ui_make(sock, Coord_Display{}, alloc)
	watcher := ui.watcher
	testing.expect_value(t, len(manager.fd_watchers), 1)
	_, registered := remote_watcher_lookup(watcher)
	testing.expect(t, registered)
	testing.expect(t, user_interface_is_ok(ui.ui))

	// The peer disconnects; the callback closes the socket and the UI
	// reads not-ok, which is what makes the server loop remove the
	// client (C++ ~RemoteUI's disconnect path).
	posix.close(fds[1])
	remote_ui_on_event(watcher, {.Read}, .Urgent)
	testing.expect_value(t, watcher.fd, -1)
	testing.expect(t, !user_interface_is_ok(ui.ui))
	st: posix.stat_t
	testing.expect(t, posix.fstat(posix.FD(sock), &st) != .OK)

	// client_destroy funnels the handle here on the success path.
	main_destroy_ui(ui.ui, .Remote, alloc)
	testing.expect_value(t, len(manager.fd_watchers), 0)
	_, still_registered := remote_watcher_lookup(watcher)
	testing.expect(t, !still_registered)

	// The registry map is process-global and this test is its only
	// user, so drop it to stay hermetic (it was created above with
	// the tracking allocator).
	delete(remote_watcher_owners)
	remote_watcher_owners = nil
	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
}
