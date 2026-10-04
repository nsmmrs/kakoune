// Tests for the buffer_utils module. No C++ UnitTest block covers
// buffer_utils, so every test below is a new edge-case test. Buffer
// fixtures use buffer_make directly (no singletons, thread-safe);
// the singleton-dependent checks (name generation, Debug creation,
// fifo buffers) live in the single mutex-guarded
// buffer_utils_test_singleton test because the singletons are
// process-global and the runner is multithreaded.
package kak

import "core:os"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import "core:c"
import posix "core:sys/posix"

// buffer_utils_test_singleton_mutex serializes the singleton
// sections in this file and debug_test.odin.
buffer_utils_test_singleton_mutex: sync.Mutex

// buffer_utils_test_fifo_mutex serializes the fifo-registry tests:
// buffer_utils_fifo_owners is process-global and the fifo tests
// delete it on exit, so concurrent runs corrupt each other.
buffer_utils_test_fifo_mutex: sync.Mutex

// buffer_utils_test_claim_singletons takes the singleton mutex and
// waits (bounded) for a foreign buffer-manager user to finish.
// Returns false when the manager stays busy, in which case the
// caller must skip without touching it. The mutex wait itself is
// bounded too: a bounds trap in a holder would skip its unlock
// (test signals bypass defers), so an unbounded wait could hang
// the suite; the timeout degrades that catastrophe to a skip.
//
// Background: the runner is multithreaded and the manager
// singleton is process-global. My tests serialize through the
// mutex; one foreign test (client_manager_test) also initializes
// the buffer manager without coordination, so this waits it out.
// These tests never install the event manager: event_manager_test
// owns that singleton for ~70ms per run, which no bounded wait can
// survive. Fifo coverage drives fifo_read/fifo_close directly on
// hand-built watcher state instead. The residual reverse order
// (foreign starting mid-test) cannot be fenced from here; the
// coordinator can close it by guarding that test with this same
// mutex.
buffer_utils_test_claim_singletons :: proc() -> bool {
	// TEMPORARY ANTI-FLAKINESS DESCHEDULING (remove once the buffer-manager
	// singleton has a process-wide test mutex): foreign tests such as
	// client_manager_test_add_free_window_unknown_buffer install and destroy
	// the process-global buffer manager without this mutex, and the runner
	// co-schedules them with these tests in the same wavefront, so without
	// this delay teardown races mid-test use ~50% of full-suite runs. The
	// whole suite currently runs in ~75 ms, so waiting 500 ms first lets all
	// foreign singleton users finish before these tests claim the manager.
	time.sleep(500 * time.Millisecond)
	for _ in 0 ..< 20000 {
		if sync.mutex_try_lock(&buffer_utils_test_singleton_mutex) {
			if !buffer_manager_has_instance {
				return true
			}
			sync.mutex_unlock(&buffer_utils_test_singleton_mutex)
		}
		time.sleep(100 * time.Microsecond)
	}
	fmt.println("SKIP: buffer manager stayed busy")
	return false
}

// buffer_utils_test_manager_live reports whether our claimed
// buffer manager is still installed. Singleton tests check it
// before each step and bail out when a foreign test tore the
// manager down mid-flight, so a race degrades to a skip instead
// of use-after-free.
buffer_utils_test_manager_live :: proc() -> bool {
	return buffer_manager_has_instance
}

// buffer_utils_test_own_manager reports whether the installed
// manager still holds our expected buffer. Pointer-compared, never
// dereferenced, so it stays safe even if a foreign teardown freed
// the buffer. Singleton teardowns destroy the manager only when
// this holds, so they never nuke a foreign manager. Reads the
// global directly instead of buffer_manager_instance(): the
// asserting accessor could fire when the flag flips mid-call,
// which in teardown would skip the mutex unlock and hang the
// suite.
buffer_utils_test_own_manager :: proc(name: string, expected: ^Buffer) -> bool {
	if !buffer_manager_has_instance {
		return false
	}
	return buffer_manager_get_ifp(&Buffer_Manager_Instance, name) == expected
}

// buffer_utils_test_release_manager destroys our claimed manager
// when it is still ours, then unlocks the singleton mutex. Uses
// direct global access throughout so teardown itself cannot assert.
buffer_utils_test_release_manager :: proc(name: string, expected: ^Buffer) {
	if buffer_utils_test_own_manager(name, expected) {
		buffer_manager_destroy(&Buffer_Manager_Instance)
		buffer_manager_has_instance = false
	}
	sync.mutex_unlock(&buffer_utils_test_singleton_mutex)
}

// buffer_utils_test_make_buffer builds a scratch buffer owning
// clones of lines (each must end with "\n"). Free with
// buffer_destroy (after buffer_utils_test_free_options when options
// were stuffed).
buffer_utils_test_make_buffer :: proc(
	lines: []string,
	flags: Buffer_Flags = {},
	name := "test",
	allocator := context.allocator,
) -> ^Buffer {
	return buffer_make(name, flags, lines, .None, .Lf, .Present, File_Fs_Status{}, allocator)
}

// buffer_utils_test_set_option installs a local option value on a
// fixture buffer (buffer_make leaves options empty; the C++
// constructor fills them). Names are static; free the entries with
// buffer_utils_test_free_options before buffer_destroy.
buffer_utils_test_set_option :: proc(b: ^Buffer, name: string, value: Option_Value) {
	desc := new(Option_Desc)
	desc^ = Option_Desc{name = name, docstring = "", flags = {}}
	opt := option_manager_option_make(desc, &b.scope.data.options, value)
	b.scope.data.options.options[name] = opt
}

// buffer_utils_test_free_options releases entries installed by
// buffer_utils_test_set_option (buffer_destroy drops the containers
// without freeing entries).
buffer_utils_test_free_options :: proc(b: ^Buffer) {
	for _, opt in b.scope.data.options.options {
		option_manager_value_destroy(&opt.value)
		free(opt.desc)
		free(opt)
	}
	clear(&b.scope.data.options.options)
}

// buffer_utils_test_scratch joins the tmpdir with a unique leaf.
// Caller frees; caller removes the file.
buffer_utils_test_scratch :: proc(leaf: string, allocator := context.allocator) -> string {
	return strings.concatenate({file_tmpdir(), "/", leaf}, allocator)
}

// buffer_utils_test_expect_lines checks a buffer's full line list.
// The count gate matters in mutex-held tests: a bounds trap would
// skip the mutex unlock and hang the other singleton tests.
buffer_utils_test_expect_lines :: proc(t: ^testing.T, b: ^Buffer, want: []string) {
	testing.expect_value(t, buffer_line_count(b), Units_LineCount(len(want)))
	if int(buffer_line_count(b)) != len(want) {
		return
	}
	for line, i in want {
		testing.expect_value(t, buffer_line(b, Units_LineCount(i)), line)
	}
}

// Backup-test recorder for the file_list_files callback (only the
// backup test uses these).
buffer_utils_test_backup_want: string
buffer_utils_test_backup_dir: string
buffer_utils_test_backup_found: string

buffer_utils_test_backup_callback :: proc(name: string, st: posix.stat_t) {
	_ = st
	if strings.has_prefix(name, buffer_utils_test_backup_want) {
		buffer_utils_test_backup_found = strings.concatenate(
			{buffer_utils_test_backup_dir, name},
		)
	}
}

@(test)
buffer_utils_test_content :: proc(t: ^testing.T) {
	b := buffer_utils_test_make_buffer({"hello world\n"})
	defer buffer_destroy(b)
	forward := Selection{basic = Basic_Selection{anchor = {0, 0}, cursor = coord_buffer_and_target({0, 4})}}
	text := buffer_utils_content(b, forward)
	defer delete(text)
	testing.expect_value(t, text, "hello")
	// Reversed selections read the same span.
	backward := Selection{basic = Basic_Selection{anchor = {0, 4}, cursor = coord_buffer_and_target({0, 0})}}
	back_text := buffer_utils_content(b, backward)
	defer delete(back_text)
	testing.expect_value(t, back_text, "hello")
}

@(test)
buffer_utils_test_erase :: proc(t: ^testing.T) {
	b := buffer_utils_test_make_buffer({"hello world\n"})
	defer buffer_destroy(b)
	sel := Selection{basic = Basic_Selection{anchor = {0, 6}, cursor = coord_buffer_and_target({0, 10})}}
	pos, err := buffer_utils_erase(b, sel)
	testing.expect_value(t, err, Buffer_Utils_Error.None)
	testing.expect_value(t, pos, Coord_Buffer{0, 6})
	testing.expect_value(t, buffer_line(b, 0), "hello \n")
	// Read-only buffers refuse.
	ro := buffer_utils_test_make_buffer({"hello\n"}, {.Read_Only})
	defer buffer_destroy(ro)
	_, ro_err := buffer_utils_erase(ro, Selection{basic = Basic_Selection{anchor = {0, 0}, cursor = coord_buffer_and_target({0, 1})}})
	testing.expect_value(t, ro_err, Buffer_Utils_Error.Buffer_Read_Only)
}

@(test)
buffer_utils_test_replace :: proc(t: ^testing.T) {
	b := buffer_utils_test_make_buffer({"hello world\n"})
	defer buffer_destroy(b)
	ranges := [2]Buffer_Range{{{0, 0}, {0, 5}}, {{0, 6}, {0, 11}}}
	err := buffer_utils_replace(b, ranges[:], {"bye", "moon"})
	testing.expect_value(t, err, Buffer_Utils_Error.None)
	testing.expect_value(t, buffer_line(b, 0), "bye moon\n")
	// Later ranges map forward past earlier edits.
	testing.expect_value(t, ranges[0], Buffer_Range{{0, 0}, {0, 3}})
	testing.expect_value(t, ranges[1], Buffer_Range{{0, 4}, {0, 8}})
}

@(test)
buffer_utils_test_replace_string_reuse :: proc(t: ^testing.T) {
	b := buffer_utils_test_make_buffer({"a b c\n"})
	defer buffer_destroy(b)
	ranges := [3]Buffer_Range{{{0, 0}, {0, 1}}, {{0, 2}, {0, 3}}, {{0, 4}, {0, 5}}}
	// The last string repeats; no strings would erase.
	err := buffer_utils_replace(b, ranges[:], {"x"})
	testing.expect_value(t, err, Buffer_Utils_Error.None)
	testing.expect_value(t, buffer_line(b, 0), "x x x\n")
	erase_ranges := [1]Buffer_Range{{{0, 0}, {0, 1}}}
	err = buffer_utils_replace(b, erase_ranges[:], {})
	testing.expect_value(t, err, Buffer_Utils_Error.None)
	testing.expect_value(t, buffer_line(b, 0), " x x\n")
	ro := buffer_utils_test_make_buffer({"a\n"}, {.Read_Only})
	defer buffer_destroy(ro)
	ro_ranges := [1]Buffer_Range{{{0, 0}, {0, 1}}}
	err = buffer_utils_replace(ro, ro_ranges[:], {"b"})
	testing.expect_value(t, err, Buffer_Utils_Error.Buffer_Read_Only)
}

@(test)
buffer_utils_test_char_length :: proc(t: ^testing.T) {
	b := buffer_utils_test_make_buffer({"héllo\n"})
	defer buffer_destroy(b)
	sel := Selection{basic = Basic_Selection{anchor = {0, 0}, cursor = coord_buffer_and_target({0, 5})}}
	testing.expect_value(t, buffer_utils_char_length(b, sel), Units_CharCount(5))
	testing.expect_value(t, buffer_utils_char_length_range(b, {0, 0}, {0, 6}), Units_CharCount(5))
	testing.expect_value(t, buffer_utils_char_length_range(b, {0, 1}, {0, 3}), Units_CharCount(1))
}

@(test)
buffer_utils_test_column_length_range :: proc(t: ^testing.T) {
	// Tabs count 1 here (codepoint_width, no tabstop expansion),
	// wide runes count 2.
	b := buffer_utils_test_make_buffer({"a\t中\n"})
	defer buffer_destroy(b)
	testing.expect_value(t, buffer_utils_column_length_range(b, {0, 0}, {0, 5}), Coord_Column(4))
	testing.expect_value(t, buffer_utils_column_length_range(b, {0, 2}, {0, 5}), Coord_Column(2))
}

@(test)
buffer_utils_test_bol_eol :: proc(t: ^testing.T) {
	b := buffer_utils_test_make_buffer({"ab\n", "c\n"})
	defer buffer_destroy(b)
	testing.expect(t, buffer_utils_is_bol({0, 0}))
	testing.expect(t, !buffer_utils_is_bol({0, 1}))
	testing.expect(t, buffer_utils_is_eol(b, {0, 2}))
	testing.expect(t, !buffer_utils_is_eol(b, {0, 1}))
	testing.expect(t, buffer_utils_is_eol(b, buffer_end_coord(b)))
}

@(test)
buffer_utils_test_bow_eow :: proc(t: ^testing.T) {
	b := buffer_utils_test_make_buffer({"foo bar_baz\n"})
	defer buffer_destroy(b)
	testing.expect(t, buffer_utils_is_bow(b, {0, 0}))
	testing.expect(t, buffer_utils_is_bow(b, {0, 4}))
	testing.expect(t, !buffer_utils_is_bow(b, {0, 1}))
	testing.expect(t, !buffer_utils_is_bow(b, {0, 5}))
	// '_' is a word char, so no boundary around it.
	testing.expect(t, !buffer_utils_is_bow(b, {0, 8}))
	testing.expect(t, buffer_utils_is_eow(b, {0, 3}))
	testing.expect(t, buffer_utils_is_eow(b, {0, 11}))
	testing.expect(t, !buffer_utils_is_eow(b, {0, 7}))
	testing.expect(t, !buffer_utils_is_eow(b, {0, 0}))
	testing.expect(t, !buffer_utils_is_eow(b, buffer_end_coord(b)))
	lead := buffer_utils_test_make_buffer({" bar\n"})
	defer buffer_destroy(lead)
	testing.expect(t, !buffer_utils_is_bow(lead, {0, 0}))
}

@(test)
buffer_utils_test_get_column :: proc(t: ^testing.T) {
	b := buffer_utils_test_make_buffer({"a\tb中\n"})
	defer buffer_destroy(b)
	testing.expect_value(t, buffer_utils_get_column(b, 8, {0, 0}), Coord_Column(0))
	testing.expect_value(t, buffer_utils_get_column(b, 8, {0, 1}), Coord_Column(1))
	// The tab jumps to the next multiple of 8.
	testing.expect_value(t, buffer_utils_get_column(b, 8, {0, 2}), Coord_Column(8))
	testing.expect_value(t, buffer_utils_get_column(b, 8, {0, 3}), Coord_Column(9))
	// Wide rune counts 2; columns past the end clamp.
	testing.expect_value(t, buffer_utils_get_column(b, 8, {0, 6}), Coord_Column(11))
	testing.expect_value(t, buffer_utils_get_column(b, 4, {0, 2}), Coord_Column(4))
}

@(test)
buffer_utils_test_column_length :: proc(t: ^testing.T) {
	b := buffer_utils_test_make_buffer({"a\tb\n", "xy\n"})
	defer buffer_destroy(b)
	// Like the C++, the trailing newline counts one column.
	testing.expect_value(t, buffer_utils_column_length(b, 8, 0), Coord_Column(10))
	testing.expect_value(t, buffer_utils_column_length(b, 8, 1), Coord_Column(3))
}

@(test)
buffer_utils_test_get_byte_to_column :: proc(t: ^testing.T) {
	b := buffer_utils_test_make_buffer({"a\tb\n"})
	defer buffer_destroy(b)
	testing.expect_value(t, buffer_utils_get_byte_to_column(b, 8, {0, 0}), Units_ByteCount(0))
	testing.expect_value(t, buffer_utils_get_byte_to_column(b, 8, {0, 1}), Units_ByteCount(1))
	// Inside the tab: stop at the tab.
	testing.expect_value(t, buffer_utils_get_byte_to_column(b, 8, {0, 4}), Units_ByteCount(1))
	testing.expect_value(t, buffer_utils_get_byte_to_column(b, 8, {0, 8}), Units_ByteCount(2))
	wide := buffer_utils_test_make_buffer({"a中b\n"})
	defer buffer_destroy(wide)
	// Inside the wide rune: stop at its first byte.
	testing.expect_value(t, buffer_utils_get_byte_to_column(wide, 8, {0, 2}), Units_ByteCount(1))
	testing.expect_value(t, buffer_utils_get_byte_to_column(wide, 8, {0, 3}), Units_ByteCount(4))
}

@(test)
buffer_utils_test_parse_lines :: proc(t: ^testing.T) {
	lines, err := buffer_utils_parse_lines("a\nb", .Lf)
	testing.expect_value(t, err, Buffer_Utils_Error.None)
	defer buffer_utils_free_lines(lines)
	testing.expect_value(t, len(lines), 2)
	testing.expect_value(t, lines[0], "a\n")
	testing.expect_value(t, lines[1], "b\n")
	crlf, cerr := buffer_utils_parse_lines("a\r\nb\r\n", .Crlf)
	testing.expect_value(t, cerr, Buffer_Utils_Error.None)
	defer buffer_utils_free_lines(crlf)
	testing.expect_value(t, len(crlf), 2)
	testing.expect_value(t, crlf[0], "a\n")
	testing.expect_value(t, crlf[1], "b\n")
	empty, eerr := buffer_utils_parse_lines("", .Lf)
	testing.expect_value(t, eerr, Buffer_Utils_Error.None)
	defer buffer_utils_free_lines(empty)
	testing.expect_value(t, len(empty), 1)
	testing.expect_value(t, empty[0], "\n")
}

// buffer_utils_test_write_scratch writes data to a fresh tmp file and
// returns its owned path; the caller removes it.
buffer_utils_test_write_scratch :: proc(t: ^testing.T, leaf, data: string) -> string {
	name := buffer_utils_test_scratch(leaf)
	testing.expect_value(t, file_write_to_file(name, data), File_Error.None)
	return name
}

@(test)
buffer_utils_test_parse_file :: proc(t: ^testing.T) {
	name := buffer_utils_test_write_scratch(t, "kak_buffer_utils_parse_lf", "a\nb\n")
	defer delete(name)
	defer os.remove(name)
	parsed, err := buffer_utils_parse_file(name)
	testing.expect_value(t, err, Buffer_Utils_Error.None)
	defer buffer_utils_free_lines(parsed.lines)
	testing.expect_value(t, len(parsed.lines), 2)
	testing.expect_value(t, parsed.lines[0], "a\n")
	testing.expect_value(t, parsed.bom, Byte_Order_Mark.None)
	testing.expect_value(t, parsed.eolformat, Eol_Format.Lf)
	testing.expect_value(t, parsed.finaleol, Final_Eol.Present)
	testing.expect_value(t, parsed.fs_status.file_size, 4)
	testing.expect(t, parsed.fs_status.timestamp != File_Invalid_Time)
	testing.expect_value(t, parsed.fs_status.hash, hash_murmur3("a\nb\n"))
}

@(test)
buffer_utils_test_parse_file_variants :: proc(t: ^testing.T) {
	crlf_name := buffer_utils_test_write_scratch(t, "kak_buffer_utils_parse_crlf", "a\r\nb\r\n")
	defer delete(crlf_name)
	defer os.remove(crlf_name)
	crlf, cerr := buffer_utils_parse_file(crlf_name)
	testing.expect_value(t, cerr, Buffer_Utils_Error.None)
	defer buffer_utils_free_lines(crlf.lines)
	testing.expect_value(t, crlf.eolformat, Eol_Format.Crlf)
	testing.expect_value(t, crlf.lines[0], "a\n")
	testing.expect_value(t, crlf.lines[1], "b\n")
	mixed_name := buffer_utils_test_write_scratch(t, "kak_buffer_utils_parse_mixed", "a\r\nb\n")
	defer delete(mixed_name)
	defer os.remove(mixed_name)
	mixed, merr := buffer_utils_parse_file(mixed_name)
	testing.expect_value(t, merr, Buffer_Utils_Error.None)
	defer buffer_utils_free_lines(mixed.lines)
	// One bare LF forces LF mode; the CR survives in the text.
	testing.expect_value(t, mixed.eolformat, Eol_Format.Lf)
	testing.expect_value(t, mixed.lines[0], "a\r\n")
	bom_name := buffer_utils_test_write_scratch(t, "kak_buffer_utils_parse_bom", "\xEF\xBB\xBFa\n")
	defer delete(bom_name)
	defer os.remove(bom_name)
	bom, berr := buffer_utils_parse_file(bom_name)
	testing.expect_value(t, berr, Buffer_Utils_Error.None)
	defer buffer_utils_free_lines(bom.lines)
	testing.expect_value(t, bom.bom, Byte_Order_Mark.Utf8)
	testing.expect_value(t, len(bom.lines), 1)
	testing.expect_value(t, bom.lines[0], "a\n")
	testing.expect_value(t, bom.fs_status.file_size, 5)
	noeol_name := buffer_utils_test_write_scratch(t, "kak_buffer_utils_parse_noeol", "a\nb")
	defer delete(noeol_name)
	defer os.remove(noeol_name)
	noeol, nerr := buffer_utils_parse_file(noeol_name)
	testing.expect_value(t, nerr, Buffer_Utils_Error.None)
	defer buffer_utils_free_lines(noeol.lines)
	testing.expect_value(t, noeol.finaleol, Final_Eol.Missing)
	testing.expect_value(t, noeol.lines[1], "b\n")
	empty_name := buffer_utils_test_write_scratch(t, "kak_buffer_utils_parse_empty", "")
	defer delete(empty_name)
	defer os.remove(empty_name)
	empty, emerr := buffer_utils_parse_file(empty_name)
	testing.expect_value(t, emerr, Buffer_Utils_Error.None)
	defer buffer_utils_free_lines(empty.lines)
	testing.expect_value(t, empty.finaleol, Final_Eol.If_Not_Empty)
	testing.expect_value(t, len(empty.lines), 1)
	bom_only_name := buffer_utils_test_write_scratch(t, "kak_buffer_utils_parse_bomonly", "\xEF\xBB\xBF")
	defer delete(bom_only_name)
	defer os.remove(bom_only_name)
	bom_only, boerr := buffer_utils_parse_file(bom_only_name)
	testing.expect_value(t, boerr, Buffer_Utils_Error.None)
	defer buffer_utils_free_lines(bom_only.lines)
	testing.expect_value(t, bom_only.bom, Byte_Order_Mark.Utf8)
	testing.expect_value(t, len(bom_only.lines), 1)
	missing, mierr := buffer_utils_parse_file(buffer_utils_test_scratch("kak_buffer_utils_no_such_file", context.temp_allocator))
	testing.expect_value(t, mierr, Buffer_Utils_Error.File_Open_Failed)
	testing.expect_value(t, len(missing.lines), 0)
	dir_case, derr := buffer_utils_parse_file(file_tmpdir())
	testing.expect_value(t, derr, Buffer_Utils_Error.File_Open_Failed)
	testing.expect_value(t, len(dir_case.lines), 0)
}

@(test)
buffer_utils_test_reload :: proc(t: ^testing.T) {
	name := buffer_utils_test_write_scratch(t, "kak_buffer_utils_reload", "one\n")
	defer delete(name)
	defer os.remove(name)
	b := buffer_utils_test_make_buffer({"stale\n"}, {.File, .New}, name)
	defer buffer_destroy(b)
	testing.expect_value(t, buffer_utils_reload_file_buffer(b), Buffer_Utils_Error.None)
	testing.expect_value(t, buffer_line(b, 0), "one\n")
	testing.expect_value(t, buffer_line_count(b), Units_LineCount(1))
	testing.expect(t, .New not_in b.flags)
	testing.expect(t, b.fs_status.timestamp != File_Invalid_Time)
	testing.expect_value(t, file_write_to_file(name, "one\ntwo\n"), File_Error.None)
	testing.expect_value(t, buffer_utils_reload_file_buffer(b), Buffer_Utils_Error.None)
	testing.expect_value(t, buffer_line_count(b), Units_LineCount(2))
	testing.expect_value(t, buffer_line(b, 1), "two\n")
	// A vanished file errors and leaves the buffer alone.
	testing.expect_value(t, os.remove(name), os.ERROR_NONE)
	testing.expect_value(t, buffer_utils_reload_file_buffer(b), Buffer_Utils_Error.File_Open_Failed)
	testing.expect_value(t, buffer_line_count(b), Units_LineCount(2))
}

// buffer_utils_test_write_options stuffs the write path options onto
// a fixture buffer.
buffer_utils_test_write_options :: proc(b: ^Buffer, finaleol: Final_Eol, eolformat: Eol_Format, bom: Byte_Order_Mark) {
	buffer_utils_test_set_option(b, "finaleol", finaleol)
	buffer_utils_test_set_option(b, "eolformat", eolformat)
	buffer_utils_test_set_option(b, "BOM", bom)
}

@(test)
buffer_utils_test_write_fd :: proc(t: ^testing.T) {
	name := buffer_utils_test_scratch("kak_buffer_utils_write_fd")
	defer delete(name)
	defer os.remove(name)
	b := buffer_utils_test_make_buffer({"a\n", "b\n"})
	defer buffer_destroy(b)
	defer buffer_utils_test_free_options(b)
	buffer_utils_test_write_options(b, .Present, .Lf, .None)
	fd, create_err := file_create_file(name)
	testing.expect_value(t, create_err, File_Error.None)
	testing.expect_value(t, buffer_utils_write_buffer_to_fd(b, fd), Buffer_Utils_Error.None)
	posix.close(posix.FD(fd))
	back, read_err := file_read_file(name, false, context.temp_allocator)
	testing.expect_value(t, read_err, File_Error.None)
	testing.expect_value(t, back, "a\nb\n")
}

// buffer_utils_test_fd_bytes writes b to a scratch fd with the given
// settings and returns the owned bytes read back.
buffer_utils_test_fd_bytes :: proc(
	t: ^testing.T,
	leaf: string,
	lines: []string,
	finaleol: Final_Eol,
	eolformat: Eol_Format,
	bom: Byte_Order_Mark,
	override: Maybe(Final_Eol) = nil,
) -> string {
	name := buffer_utils_test_scratch(leaf)
	defer delete(name)
	defer os.remove(name)
	b := buffer_utils_test_make_buffer(lines)
	defer buffer_destroy(b)
	defer buffer_utils_test_free_options(b)
	buffer_utils_test_write_options(b, finaleol, eolformat, bom)
	fd, create_err := file_create_file(name)
	testing.expect_value(t, create_err, File_Error.None)
	testing.expect_value(t, buffer_utils_write_buffer_to_fd(b, fd, override), Buffer_Utils_Error.None)
	posix.close(posix.FD(fd))
	back, read_err := file_read_file(name)
	testing.expect_value(t, read_err, File_Error.None)
	return back
}

@(test)
buffer_utils_test_write_fd_variants :: proc(t: ^testing.T) {
	crlf := buffer_utils_test_fd_bytes(t, "kak_buffer_utils_fd_crlf", {"a\n", "b\n"}, .Present, .Crlf, .None)
	defer delete(crlf)
	testing.expect_value(t, crlf, "a\r\nb\r\n")
	missing := buffer_utils_test_fd_bytes(t, "kak_buffer_utils_fd_missing", {"a\n", "b\n"}, .Missing, .Lf, .None)
	defer delete(missing)
	testing.expect_value(t, missing, "a\nb")
	with_bom := buffer_utils_test_fd_bytes(t, "kak_buffer_utils_fd_bom", {"a\n"}, .Present, .Lf, .Utf8)
	defer delete(with_bom)
	testing.expect_value(t, with_bom, "\xEF\xBB\xBFa\n")
	empty_kept := buffer_utils_test_fd_bytes(t, "kak_buffer_utils_fd_empty", {"\n"}, .If_Not_Empty, .Lf, .None)
	defer delete(empty_kept)
	testing.expect_value(t, empty_kept, "")
	nonempty := buffer_utils_test_fd_bytes(t, "kak_buffer_utils_fd_nonempty", {"a\n"}, .If_Not_Empty, .Lf, .None)
	defer delete(nonempty)
	testing.expect_value(t, nonempty, "a\n")
	overridden := buffer_utils_test_fd_bytes(t, "kak_buffer_utils_fd_override", {"a\n"}, .Missing, .Lf, .None, .Present)
	defer delete(overridden)
	testing.expect_value(t, overridden, "a\n")
}

@(test)
buffer_utils_test_write_file_overwrite :: proc(t: ^testing.T) {
	name := buffer_utils_test_write_scratch(t, "kak_buffer_utils_overwrite", "old\n")
	defer delete(name)
	defer os.remove(name)
	b := buffer_utils_test_make_buffer({"new\n"}, {.File}, name)
	defer buffer_destroy(b)
	defer buffer_utils_test_free_options(b)
	buffer_utils_test_write_options(b, .Present, .Lf, .None)
	testing.expect_value(t, buffer_utils_write_buffer_to_file(b, name, .Overwrite), Buffer_Utils_Error.None)
	back, read_err := file_read_file(name, false, context.temp_allocator)
	testing.expect_value(t, read_err, File_Error.None)
	testing.expect_value(t, back, "new\n")
	// Same-file writes notify the buffer saved.
	testing.expect_value(t, b.history_id, b.last_save_history_id)
	testing.expect(t, b.fs_status.timestamp != File_Invalid_Time)
	// Missing parent directories fail the open.
	bad := strings.concatenate({name, "_no_such_dir", "/f"}, context.temp_allocator)
	testing.expect_value(
		t,
		buffer_utils_write_buffer_to_file(b, bad, .Overwrite),
		Buffer_Utils_Error.File_Open_Failed,
	)
}

@(test)
buffer_utils_test_write_file_replace :: proc(t: ^testing.T) {
	name := buffer_utils_test_write_scratch(t, "kak_buffer_utils_replace", "old\n")
	defer delete(name)
	defer os.remove(name)
	cname := strings.clone_to_cstring(name, context.temp_allocator)
	testing.expect_value(t, posix.chmod(cname, posix.mode_t{.IRUSR, .IRGRP, .IROTH}), posix.result.OK)
	before: posix.stat_t
	testing.expect_value(t, posix.stat(cname, &before), posix.result.OK)
	b := buffer_utils_test_make_buffer({"new\n"})
	defer buffer_destroy(b)
	defer buffer_utils_test_free_options(b)
	buffer_utils_test_write_options(b, .Present, .Lf, .None)
	testing.expect_value(
		t,
		buffer_utils_write_buffer_to_file(b, name, .Replace, {.Sync}),
		Buffer_Utils_Error.None,
	)
	back, read_err := file_read_file(name, false, context.temp_allocator)
	testing.expect_value(t, read_err, File_Error.None)
	testing.expect_value(t, back, "new\n")
	after: posix.stat_t
	testing.expect_value(t, posix.stat(cname, &after), posix.result.OK)
	testing.expect_value(t, after.st_mode, before.st_mode)
	testing.expect(t, after.st_ino != before.st_ino)
}

@(test)
buffer_utils_test_write_file_force :: proc(t: ^testing.T) {
	name := buffer_utils_test_write_scratch(t, "kak_buffer_utils_force", "old\n")
	defer delete(name)
	defer os.remove(name)
	cname := strings.clone_to_cstring(name, context.temp_allocator)
	testing.expect_value(t, posix.chmod(cname, posix.mode_t{.IRUSR, .IRGRP, .IROTH}), posix.result.OK)
	b := buffer_utils_test_make_buffer({"new\n"})
	defer buffer_destroy(b)
	defer buffer_utils_test_free_options(b)
	buffer_utils_test_write_options(b, .Present, .Lf, .None)
	if posix.geteuid() != 0 {
		// Unprivileged writers cannot truncate a read-only file.
		testing.expect_value(
			t,
			buffer_utils_write_buffer_to_file(b, name, .Overwrite),
			Buffer_Utils_Error.File_Open_Failed,
		)
	}
	testing.expect_value(
		t,
		buffer_utils_write_buffer_to_file(b, name, .Overwrite, {.Force}),
		Buffer_Utils_Error.None,
	)
	back, read_err := file_read_file(name, false, context.temp_allocator)
	testing.expect_value(t, read_err, File_Error.None)
	testing.expect_value(t, back, "new\n")
	st: posix.stat_t
	testing.expect_value(t, posix.stat(cname, &st), posix.result.OK)
	testing.expect_value(t, st.st_mode, posix.mode_t{.IRUSR, .IRGRP, .IROTH} | posix.mode_t{.IFREG})
}

@(test)
buffer_utils_test_write_file_other_name_skips_notify :: proc(t: ^testing.T) {
	src := buffer_utils_test_write_scratch(t, "kak_buffer_utils_src", "x\n")
	defer delete(src)
	defer os.remove(src)
	dst := buffer_utils_test_scratch("kak_buffer_utils_dst")
	defer delete(dst)
	defer os.remove(dst)
	b := buffer_utils_test_make_buffer({"y\n"}, {.File}, src)
	defer buffer_destroy(b)
	defer buffer_utils_test_free_options(b)
	buffer_utils_test_write_options(b, .Present, .Lf, .None)
	_, _ = buffer_insert(b, {0, 0}, "z")
	testing.expect_value(
		t,
		buffer_utils_write_buffer_to_file(b, dst, .Overwrite),
		Buffer_Utils_Error.None,
	)
	// Saving under another name leaves the save state alone.
	testing.expect(t, b.history_id != b.last_save_history_id || len(b.current_undo_group) != 0)
}

@(test)
buffer_utils_test_write_backup :: proc(t: ^testing.T) {
	name := buffer_utils_test_write_scratch(t, "kak_buffer_utils_backup", "old\n")
	defer delete(name)
	defer os.remove(name)
	b := buffer_utils_test_make_buffer({"saved\n"}, {.File}, name)
	defer buffer_destroy(b)
	defer buffer_utils_test_free_options(b)
	buffer_utils_test_write_options(b, .Present, .Lf, .None)
	testing.expect_value(t, buffer_utils_write_to_backup_file(b), Buffer_Utils_Error.None)
	dir, base := file_split_path(name)
	prefix := strings.concatenate({".", base, ".kak."}, context.temp_allocator)
	buffer_utils_test_backup_want = prefix
	buffer_utils_test_backup_dir = dir
	buffer_utils_test_backup_found = ""
	file_list_files(dir, buffer_utils_test_backup_callback)
	found := buffer_utils_test_backup_found
	defer delete(found)
	testing.expect(t, len(found) != 0)
	defer os.remove(found)
	back, read_back_err := file_read_file(found, false, context.temp_allocator)
	testing.expect_value(t, read_back_err, File_Error.None)
	testing.expect_value(t, back, "saved\n")
}

@(test)
buffer_utils_test_history_strings :: proc(t: ^testing.T) {
	undo := make([dynamic]Buffer_Modification, 2)
	undo[0] = {type = .Insert, coord = {1, 2}, content = "x"}
	undo[1] = {type = .Erase, coord = {3, 4}, content = "yz"}
	history := [2]Buffer_History_Node{
		{buffer_HISTORY_INVALID, buffer_HISTORY_FIRST, Clock_Time(5_000_000_000), nil},
		{buffer_HISTORY_FIRST, buffer_HISTORY_INVALID, Clock_Time(6_000_000_000), undo},
	}
	defer delete(history[1].undo_group)
	flat := buffer_utils_history_as_strings(history[:])
	defer {
		for s in flat {
			delete(s)
		}
		delete(flat)
	}
	testing.expect_value(t, len(flat), 8)
	testing.expect_value(t, flat[0], "-")
	testing.expect_value(t, flat[1], "5")
	testing.expect_value(t, flat[2], "0")
	testing.expect_value(t, flat[3], "0")
	testing.expect_value(t, flat[4], "6")
	testing.expect_value(t, flat[5], "-")
	testing.expect_value(t, flat[6], "+1.2|x")
	testing.expect_value(t, flat[7], "-3.4|yz")
	group := buffer_utils_undo_group_as_strings(undo[:])
	defer {
		for s in group {
			delete(s)
		}
		delete(group)
	}
	testing.expect_value(t, len(group), 2)
	testing.expect_value(t, group[0], "+1.2|x")
	// One real commit round-trips through the same spelling.
	b := buffer_utils_test_make_buffer({"ab\n"})
	defer buffer_destroy(b)
	_, _ = buffer_insert(b, {0, 0}, "xy")
	buffer_commit_undo_group(b)
	real := buffer_utils_history_as_strings(b.history[:])
	defer {
		for s in real {
			delete(s)
		}
		delete(real)
	}
	testing.expect_value(t, len(real), 7)
	testing.expect_value(t, real[0], "-")
	testing.expect_value(t, real[2], "1")
	testing.expect_value(t, real[3], "0")
	testing.expect_value(t, real[5], "-")
	testing.expect_value(t, real[6], "+0.0|xy")
	seconds, conv_err := string_utils_str_to_int(real[4])
	testing.expect_value(t, conv_err, String_Utils_Error.None)
	testing.expect(t, seconds >= 0)
}

// buffer_utils_test_pipe writes data to a fresh pipe and returns its
// read end, leaving the write end open for the caller to close.
buffer_utils_test_pipe :: proc(t: ^testing.T, data: string) -> (read_fd, write_fd: int) {
	fds: [2]posix.FD
	testing.expect_value(t, posix.pipe(&fds), posix.result.OK)
	bytes := transmute([]byte)(data)
	n := posix.write(fds[1], raw_data(bytes), c.size_t(len(bytes)))
	testing.expect_value(t, int(n), len(data))
	return int(fds[0]), int(fds[1])
}

// buffer_utils_test_fifo_state fetches the live fifo watcher for buf.
buffer_utils_test_fifo_state :: proc(
	t: ^testing.T,
	buf: ^Buffer,
) -> ^Buffer_Utils_Fifo_Watcher {
	testing.expect(t, buf != nil)
	if buf == nil {
		return nil
	}
	stored, ok := buf.values[buffer_utils_fifo_id()]
	testing.expect(t, ok)
	if !ok {
		return nil
	}
	fifo, cast_err := value_as(stored, Buffer_Utils_Fifo_Watcher)
	testing.expect_value(t, cast_err, Value_Error.None)
	if cast_err != .None {
		return nil
	}
	return fifo
}

@(test)
buffer_utils_test_singleton :: proc(t: ^testing.T) {
	if !buffer_utils_test_claim_singletons() {
		return
	}
	tracked_buf: ^Buffer = nil
	fresh: string
	defer {
		// Fresh is freed after the release check that reads it.
		buffer_utils_test_release_manager(fresh, tracked_buf)
		delete(fresh)
	}
	buffer_manager_instance_init()

	fresh = buffer_utils_generate_buffer_name("*stdin-{}*")
	testing.expect_value(t, fresh, "*stdin-0*")
	if !buffer_utils_test_manager_live() {
		fmt.println("SKIP: buffer manager lost mid-test")
		return
	}
	created, create_err := buffer_utils_create_buffer_from_string(fresh, {.Debug}, "a\nb")
	testing.expect_value(t, create_err, Buffer_Utils_Error.None)
	testing.expect(t, created != nil)
	if create_err == .None && created != nil {
		tracked_buf = created
		buffer_utils_test_expect_lines(t, created, {"a\n", "b\n"})
		testing.expect_value(t, created.display_name, fresh)
		testing.expect(t, created.fs_status.timestamp == File_Invalid_Time)
	}
	if !buffer_utils_test_own_manager(fresh, tracked_buf) {
		fmt.println("SKIP: buffer manager lost mid-test")
		return
	}
	next := buffer_utils_generate_buffer_name("*stdin-{}*")
	defer delete(next)
	testing.expect_value(t, next, "*stdin-1*")
	_, dup_err := buffer_utils_create_buffer_from_string(fresh, {.Debug}, "x")
	testing.expect_value(t, dup_err, Buffer_Utils_Error.Name_In_Use)
}

// buffer_utils_test_fifo_phase runs one scroll-mode phase on buf:
// arm hand-built watcher state on a pipe holding data, read it,
// check the resulting lines, then close the pipe and check the
// teardown. No singletons: the watcher struct is filled in by hand
// (the event manager only matters for real dispatch) and reads run
// through buffer_utils_fifo_read directly.
buffer_utils_test_fifo_phase :: proc(
	t: ^testing.T,
	b: ^Buffer,
	data: string,
	scroll: Buffer_Utils_Auto_Scroll,
	want: []string,
	via_event: bool,
) {
	reset := [1]string{"\n"}
	buffer_reload(b, reset[:], .None, .Lf, .Present, File_Fs_Status{timestamp = File_Invalid_Time})
	b.flags |= {.Fifo, .No_Undo}
	read_fd, write_fd := buffer_utils_test_pipe(t, data)
	stored := value_make(Buffer_Utils_Fifo_Watcher{buffer = b, scroll = scroll}, b.allocator)
	fifo, cast_err := value_as(stored, Buffer_Utils_Fifo_Watcher)
	testing.expect_value(t, cast_err, Value_Error.None)
	if cast_err != .None {
		value_free(&stored, b.allocator)
		posix.close(posix.FD(write_fd))
		posix.close(posix.FD(read_fd))
		return
	}
	fifo.watcher.fd = read_fd
	fifo.watcher.events = {.Read}
	fifo.watcher.mode = .Normal
	fifo.watcher.callback = buffer_utils_fifo_on_event
	buffer_utils_fifo_register(&fifo.watcher, fifo)
	b.values[buffer_utils_fifo_id()] = stored
	if via_event {
		buffer_utils_fifo_on_event(&fifo.watcher, {.Read}, .Normal)
	} else {
		buffer_utils_fifo_read(fifo)
	}
	buffer_utils_test_expect_lines(t, b, want)
	testing.expect_value(t, len(buffer_utils_fifo_owners), 1)
	posix.close(posix.FD(write_fd))
	if state := buffer_utils_test_fifo_state(t, b); state != nil {
		buffer_utils_fifo_read(state)
	}
	testing.expect_value(t, b.flags, Buffer_Flags{.No_Hooks})
	testing.expect_value(t, len(b.values), 0)
	testing.expect_value(t, len(buffer_utils_fifo_owners), 0)
}

@(test)
buffer_utils_test_fifo :: proc(t: ^testing.T) {
	// Serialize with buffer_utils_test_fifo_destroy_open: both mutate
	// the process-global owners registry.
	sync.mutex_lock(&event_manager_test_singleton_mutex)
	defer sync.mutex_unlock(&event_manager_test_singleton_mutex)
	// The registry is a process-lifetime singleton; drop its backing
	// here so per-test tracking sees no leftover.
	defer {
		delete(buffer_utils_fifo_owners)
		buffer_utils_fifo_owners = nil
	}
	b := buffer_utils_test_make_buffer({"\n"}, {.No_Hooks}, "fifo-manual")
	defer buffer_destroy(b)
	// Not_Initially with trailing newlines: the initial empty line
	// is dropped and a fresh empty line is kept.
	buffer_utils_test_fifo_phase(t, b, "ab\ncd\n", .Not_Initially, {"ab\n", "cd\n", "\n"}, true)
	// .No without a trailing newline keeps the partial line only.
	buffer_utils_test_fifo_phase(t, b, "xy", .No, {"xy\n"}, false)
	// .Yes inserts at point with no line surgery.
	buffer_utils_test_fifo_phase(t, b, "p\nq", .Yes, {"p\n", "q\n"}, false)
	// Urgent-mode events and unknown watchers are ignored.
	read_fd, write_fd := buffer_utils_test_pipe(t, "zz")
	defer posix.close(posix.FD(write_fd))
	defer posix.close(posix.FD(read_fd))
	watcher := Event_Manager_Fd_Watcher{fd = read_fd, events = {.Read}, mode = .Normal}
	buffer_utils_fifo_on_event(&watcher, {.Read}, .Urgent)
	buffer_utils_fifo_on_event(&watcher, {.Read}, .Normal)
	testing.expect_value(t, len(buffer_utils_fifo_owners), 0)
	buffer_utils_test_expect_lines(t, b, {"p\n", "q\n"})
}

// destroying a buffer with an open fifo tears the watcher down
// (~FifoWatcher): the watcher unregisters from the event manager,
// the fd closes, and the registry entry drops (no teardown assert,
// no leak)
@(test)
buffer_utils_test_fifo_destroy_open :: proc(t: ^testing.T) {
	sync.mutex_lock(&event_manager_test_singleton_mutex)
	defer sync.mutex_unlock(&event_manager_test_singleton_mutex)
	manager: Event_Manager
	event_manager_init(&manager)
	defer event_manager_destroy(&manager)
	defer {
		delete(buffer_utils_fifo_owners)
		buffer_utils_fifo_owners = nil
	}

	b := buffer_utils_test_make_buffer({"\n"}, {.No_Hooks}, "fifo-open-destroy")
	read_fd, write_fd := buffer_utils_test_pipe(t, "ab\n")
	// The write end stays open: the fifo is NOT at EOF.
	defer posix.close(posix.FD(write_fd))
	stored := value_make(Buffer_Utils_Fifo_Watcher{buffer = b, scroll = .Yes}, b.allocator)
	fifo, cast_err := value_as(stored, Buffer_Utils_Fifo_Watcher)
	testing.expect_value(t, cast_err, Value_Error.None)
	if cast_err != .None {
		value_free(&stored, b.allocator)
		posix.close(posix.FD(read_fd))
		buffer_destroy(b)
		return
	}
	event_manager_fd_watcher_init(&fifo.watcher, read_fd, {.Read}, .Normal, buffer_utils_fifo_on_event)
	buffer_utils_fifo_register(&fifo.watcher, fifo)
	b.flags |= {.Fifo, .No_Undo}
	b.values[buffer_utils_fifo_id()] = stored
	testing.expect_value(t, len(manager.fd_watchers), 1)

	before: posix.stat_t
	testing.expect_value(t, posix.fstat(posix.FD(read_fd), &before), posix.result.OK)
	buffer_destroy(b)
	testing.expect_value(t, len(manager.fd_watchers), 0)
	testing.expect_value(t, len(buffer_utils_fifo_owners), 0)
	// The fd must be closed, but another thread may recycle the
	// number before this check runs: pass when fstat fails OR the
	// identity changed (a recycled fd is never our pipe). Only the
	// same (dev, ino) still open proves the close was missed.
	after: posix.stat_t
	closed_or_recycled :=
		posix.fstat(posix.FD(read_fd), &after) != .OK ||
		after.st_dev != before.st_dev || after.st_ino != before.st_ino
	testing.expect(t, closed_or_recycled)
	if len(manager.fd_watchers) != 0 {
		// Clean failure, not a teardown trap (which would skip the
		// mutex unlock and hang the suite): the expects above
		// already failed.
		event_manager_fd_watcher_destroy(manager.fd_watchers[0])
		posix.close(posix.FD(read_fd))
	}
}
