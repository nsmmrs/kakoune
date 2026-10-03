package kak

import "core:os"
import "core:strings"
import "core:testing"

// buffer_manager_test_make_buffer builds a bare Buffer borrowing its
// names (buffers are normally built by the STUBBED buffer_make).
buffer_manager_test_make_buffer :: proc(
	display_name: string,
	filename: string,
	flags: Buffer_Flags,
	allocator := context.allocator,
) -> ^Buffer {
	buf := new(Buffer, allocator)
	buf.display_name = display_name
	buf.filename = filename
	buf.flags = flags
	return buf
}

buffer_manager_test_free_buffer :: proc(buf: ^Buffer, allocator := context.allocator) {
	free(buf, allocator)
}

// buffer_manager_test_reset releases only the manager arrays: buffers
// are freed individually because destroying them runs the STUBBED
// buffer lifecycle.
buffer_manager_test_reset :: proc(m: ^Buffer_Manager) {
	delete(m.buffers)
	delete(m.buffer_trash)
	m^ = Buffer_Manager{}
}

// buffer_manager_test_names returns the display names in list order.
buffer_manager_test_names :: proc(m: ^Buffer_Manager, allocator := context.allocator) -> [dynamic]string {
	res := make([dynamic]string, 0, len(m.buffers), allocator)
	for b in m.buffers {
		append(&res, b.display_name)
	}
	return res
}

@(test)
buffer_manager_test_make_destroy_empty :: proc(t: ^testing.T) {
	m := buffer_manager_make()
	testing.expect_value(t, buffer_manager_count(&m), 0)
	buffer_manager_destroy(&m)
}

@(test)
buffer_manager_test_buffer_name :: proc(t: ^testing.T) {
	file_buf := buffer_manager_test_make_buffer("short", "/abs/path", {.File})
	defer buffer_manager_test_free_buffer(file_buf)
	testing.expect_value(t, buffer_manager_buffer_name(file_buf), "/abs/path")

	scratch := buffer_manager_test_make_buffer("*scratch*", "", {})
	defer buffer_manager_test_free_buffer(scratch)
	testing.expect_value(t, buffer_manager_buffer_name(scratch), "*scratch*")
}

@(test)
buffer_manager_test_is_modified :: proc(t: ^testing.T) {
	buf := buffer_manager_test_make_buffer("*scratch*", "", {})
	defer buffer_manager_test_free_buffer(buf)
	testing.expect(t, !buffer_manager_is_modified(buf))

	buf.flags = {.File}
	testing.expect(t, !buffer_manager_is_modified(buf))

	buf.history_id = Buffer_History_Id(3)
	testing.expect(t, buffer_manager_is_modified(buf))
	buf.history_id = buf.last_save_history_id

	mod := Buffer_Modification{type = .Insert, coord = Coord_Buffer{}, content = "x"}
	append(&buf.current_undo_group, mod)
	defer delete(buf.current_undo_group)
	testing.expect(t, buffer_manager_is_modified(buf))
}

@(test)
buffer_manager_test_get_ifp_display_name :: proc(t: ^testing.T) {
	m := buffer_manager_make()
	defer buffer_manager_test_reset(&m)
	a := buffer_manager_test_make_buffer("*scratch*", "", {})
	defer buffer_manager_test_free_buffer(a)
	append(&m.buffers, a)

	testing.expect(t, buffer_manager_get_ifp(&m, "*scratch*") == a)
	testing.expect(t, buffer_manager_get_ifp(&m, "*missing*") == nil)
}

@(test)
buffer_manager_test_get_ifp_filename :: proc(t: ^testing.T) {
	path := strings.concatenate(
		{file_tmpdir(), "/kak_buffer_manager_test_file.txt"},
		context.temp_allocator,
	)
	testing.expect_value(t, file_write_to_file(path, "x"), File_Error.None)
	defer os.remove(path)
	canonical, real_err := file_real_path(path, context.temp_allocator)
	testing.expect_value(t, real_err, File_Error.None)

	m := buffer_manager_make()
	defer buffer_manager_test_reset(&m)
	buf := buffer_manager_test_make_buffer("short", canonical, {.File})
	defer buffer_manager_test_free_buffer(buf)
	append(&m.buffers, buf)

	// File buffers match by resolved filename, not display name.
	testing.expect(t, buffer_manager_get_ifp(&m, canonical) == buf)
	testing.expect(t, buffer_manager_get_ifp(&m, path) == buf)
	testing.expect(t, buffer_manager_get_ifp(&m, "short") == nil)
}

@(test)
buffer_manager_test_get :: proc(t: ^testing.T) {
	m := buffer_manager_make()
	defer buffer_manager_test_reset(&m)
	a := buffer_manager_test_make_buffer("a", "", {})
	defer buffer_manager_test_free_buffer(a)
	append(&m.buffers, a)

	found, err := buffer_manager_get(&m, "a")
	testing.expect_value(t, err, Buffer_Manager_Error.None)
	testing.expect(t, found == a)

	_, missing := buffer_manager_get(&m, "b")
	testing.expect_value(t, missing, Buffer_Manager_Error.No_Such_Buffer)
}

buffer_manager_test_is_debug :: proc(buf: ^Buffer) -> bool {
	return .Debug in buf.flags
}

buffer_manager_test_match_all :: proc(buf: ^Buffer) -> bool {
	return true
}

buffer_manager_test_match_none :: proc(buf: ^Buffer) -> bool {
	return false
}

@(test)
buffer_manager_test_get_matching :: proc(t: ^testing.T) {
	m := buffer_manager_make()
	defer buffer_manager_test_reset(&m)
	a := buffer_manager_test_make_buffer("a", "", {})
	defer buffer_manager_test_free_buffer(a)
	d := buffer_manager_test_make_buffer("d", "", {.Debug})
	defer buffer_manager_test_free_buffer(d)
	b := buffer_manager_test_make_buffer("b", "", {})
	defer buffer_manager_test_free_buffer(b)
	append(&m.buffers, a)
	append(&m.buffers, d)
	append(&m.buffers, b)

	testing.expect(
		t,
		buffer_manager_get_matching_ifp(&m, buffer_manager_test_is_debug) == d,
	)
	// Matching scans most-recent-first.
	testing.expect(
		t,
		buffer_manager_get_matching_ifp(&m, buffer_manager_test_match_all) == b,
	)
	testing.expect(
		t,
		buffer_manager_get_matching_ifp(&m, buffer_manager_test_match_none) == nil,
	)

	found, err := buffer_manager_get_matching(&m, buffer_manager_test_is_debug)
	testing.expect_value(t, err, Buffer_Manager_Error.None)
	testing.expect(t, found == d)

	_, missing := buffer_manager_get_matching(&m, buffer_manager_test_match_none)
	testing.expect_value(t, missing, Buffer_Manager_Error.No_Such_Buffer)
}

@(test)
buffer_manager_test_make_latest :: proc(t: ^testing.T) {
	m := buffer_manager_make()
	defer buffer_manager_test_reset(&m)
	a := buffer_manager_test_make_buffer("a", "", {})
	defer buffer_manager_test_free_buffer(a)
	b := buffer_manager_test_make_buffer("b", "", {})
	defer buffer_manager_test_free_buffer(b)
	c := buffer_manager_test_make_buffer("c", "", {})
	defer buffer_manager_test_free_buffer(c)
	append(&m.buffers, a)
	append(&m.buffers, b)
	append(&m.buffers, c)

	buffer_manager_make_latest(&m, a)
	names := buffer_manager_test_names(&m)
	defer delete(names)
	testing.expect_value(t, len(names), 3)
	testing.expect_value(t, names[0], "b")
	testing.expect_value(t, names[1], "c")
	testing.expect_value(t, names[2], "a")
}

@(test)
buffer_manager_test_arrange_front :: proc(t: ^testing.T) {
	m := buffer_manager_make()
	defer buffer_manager_test_reset(&m)
	a := buffer_manager_test_make_buffer("a", "", {})
	defer buffer_manager_test_free_buffer(a)
	b := buffer_manager_test_make_buffer("b", "", {})
	defer buffer_manager_test_free_buffer(b)
	c := buffer_manager_test_make_buffer("c", "", {})
	defer buffer_manager_test_free_buffer(c)
	append(&m.buffers, a)
	append(&m.buffers, b)
	append(&m.buffers, c)

	err := buffer_manager_arrange(&m, {"c"}, false)
	testing.expect_value(t, err, Buffer_Manager_Error.None)
	names := buffer_manager_test_names(&m)
	defer delete(names)
	testing.expect_value(t, names[0], "c")
	testing.expect_value(t, names[1], "a")
	testing.expect_value(t, names[2], "b")
}

@(test)
buffer_manager_test_arrange_back :: proc(t: ^testing.T) {
	m := buffer_manager_make()
	defer buffer_manager_test_reset(&m)
	a := buffer_manager_test_make_buffer("a", "", {})
	defer buffer_manager_test_free_buffer(a)
	b := buffer_manager_test_make_buffer("b", "", {})
	defer buffer_manager_test_free_buffer(b)
	c := buffer_manager_test_make_buffer("c", "", {})
	defer buffer_manager_test_free_buffer(c)
	append(&m.buffers, a)
	append(&m.buffers, b)
	append(&m.buffers, c)

	err := buffer_manager_arrange(&m, {"a", "b"}, true)
	testing.expect_value(t, err, Buffer_Manager_Error.None)
	names := buffer_manager_test_names(&m)
	defer delete(names)
	testing.expect_value(t, names[0], "c")
	testing.expect_value(t, names[1], "a")
	testing.expect_value(t, names[2], "b")
}

@(test)
buffer_manager_test_arrange_errors :: proc(t: ^testing.T) {
	m := buffer_manager_make()
	defer buffer_manager_test_reset(&m)
	a := buffer_manager_test_make_buffer("a", "", {})
	defer buffer_manager_test_free_buffer(a)
	append(&m.buffers, a)

	testing.expect_value(
		t,
		buffer_manager_arrange(&m, {"missing"}, false),
		Buffer_Manager_Error.No_Such_Buffer,
	)
	testing.expect_value(
		t,
		buffer_manager_arrange(&m, {"a", "a"}, false),
		Buffer_Manager_Error.Duplicate_Buffer,
	)
	testing.expect_value(t, buffer_manager_count(&m), 1)
}

@(test)
buffer_manager_test_get_first :: proc(t: ^testing.T) {
	m := buffer_manager_make()
	defer buffer_manager_test_reset(&m)
	a := buffer_manager_test_make_buffer("a", "", {})
	defer buffer_manager_test_free_buffer(a)
	b := buffer_manager_test_make_buffer("b", "", {})
	defer buffer_manager_test_free_buffer(b)
	append(&m.buffers, a)
	append(&m.buffers, b)

	// The most recently used buffer is at the back.
	first, err := buffer_manager_get_first(&m)
	testing.expect_value(t, err, Buffer_Manager_Error.None)
	testing.expect(t, first == b)
	// The all-debug creation path calls STUBBED buffer procs (see summary).
}

@(test)
buffer_manager_test_backup_unmodified :: proc(t: ^testing.T) {
	m := buffer_manager_make()
	defer buffer_manager_test_reset(&m)
	f := buffer_manager_test_make_buffer("f", "/tmp/x", {.File})
	defer buffer_manager_test_free_buffer(f)
	append(&m.buffers, f)

	// Nothing modified: no backup runs, no STUB is reached.
	buffer_manager_backup_modified(&m)
	// The modified path calls a STUBBED buffer proc (see summary).
}

@(test)
buffer_manager_test_clear_trash_empty :: proc(t: ^testing.T) {
	m := buffer_manager_make()
	defer buffer_manager_test_reset(&m)
	buffer_manager_clear_trash(&m)
	testing.expect_value(t, len(m.buffer_trash), 0)
}

@(test)
buffer_manager_test_delete_early_outs :: proc(t: ^testing.T) {
	m := buffer_manager_make()
	defer buffer_manager_test_reset(&m)
	locked := buffer_manager_test_make_buffer("locked", "", {.Locked})
	defer buffer_manager_test_free_buffer(locked)
	append(&m.buffers, locked)

	testing.expect_value(
		t,
		buffer_manager_delete(&m, locked),
		Buffer_Manager_Error.Locked,
	)

	// Deleting an unknown buffer is a silent no-op.
	other := buffer_manager_test_make_buffer("other", "", {})
	defer buffer_manager_test_free_buffer(other)
	testing.expect_value(t, buffer_manager_delete(&m, other), Buffer_Manager_Error.None)
	testing.expect_value(t, buffer_manager_count(&m), 1)
	// The live deletion path calls STUBBED buffer procs (see summary).
}

@(test)
buffer_manager_test_create_duplicate :: proc(t: ^testing.T) {
	m := buffer_manager_make()
	defer buffer_manager_test_reset(&m)
	a := buffer_manager_test_make_buffer("a", "", {})
	defer buffer_manager_test_free_buffer(a)
	append(&m.buffers, a)

	// The duplicate check runs before any STUBBED buffer proc.
	_, err := buffer_manager_create(&m, "a", {}, nil, .None, .Lf, .Present, File_Fs_Status{})
	testing.expect_value(t, err, Buffer_Manager_Error.Name_In_Use)
	testing.expect_value(t, buffer_manager_count(&m), 1)
	// Successful creation calls STUBBED buffer procs (see summary).
}
