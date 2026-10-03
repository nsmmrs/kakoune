// Tests for file.odin (port of src/file.{hh,cc}).
//
// No C++ UnitTest covers this module; tests are written from the
// source behavior: path translation, file I/O, temp files, mapping,
// search, listing, directory creation, fs status, and buffered writes.
//
// Parallelism note: `odin test` runs tests on worker threads, so every
// test uses unique scratch names under the tmpdir, and only
// file_test_compact_path changes the cwd (all other tests use absolute
// paths). TMPDIR is mutated only to values that keep concurrent
// scratch-path users working (a real dir, unset, or empty).
package kak

import "core:c"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import posix "core:sys/posix"

// file_test_listed collects file_test_collect callback names. Owned by
// file_test_list_files alone (see parallelism note above).
file_test_listed: [dynamic]string

// file_test_collect appends a clone of each listed name.
file_test_collect :: proc(name: string, st: posix.stat_t) {
	_ = st
	append(&file_test_listed, strings.clone(name))
}

// file_test_scratch joins the tmpdir with a unique leaf. Caller frees.
file_test_scratch :: proc(leaf: string, allocator := context.allocator) -> string {
	return strings.concatenate({file_tmpdir(), "/", leaf}, allocator)
}

// file_test_restore_tmpdir restores a saved TMPDIR (or unsets it).
file_test_restore_tmpdir :: proc(saved: string, have_old: bool) {
	if have_old {
		os.set_env("TMPDIR", saved)
	} else {
		os.unset_env("TMPDIR")
	}
}

// file_test_chdir changes directory, ignoring the result (used to
// restore the cwd after file_test_compact_path).
file_test_chdir :: proc(dir: string) {
	c := strings.clone_to_cstring(dir, context.temp_allocator)
	posix.chdir(c)
}

// None is the zero value.
@(test)
file_test_error_zero :: proc(t: ^testing.T) {
	testing.expect_value(t, int(File_Error.None), 0)
}

// parse_filename: ~/% expansion, plain passthrough, edge prefixes.
@(test)
file_test_parse_filename :: proc(t: ^testing.T) {
	home := file_homedir()

	got := file_parse_filename("~/x")
	expected := strings.concatenate({home, "/x"})
	defer delete(expected)
	testing.expect_value(t, got, expected)
	delete(got)

	got = file_parse_filename("~")
	testing.expect_value(t, got, home)
	delete(got)

	got = file_parse_filename("%/x", "/buf")
	testing.expect_value(t, got, "/buf/x")
	delete(got)

	got = file_parse_filename("%", "/buf")
	testing.expect_value(t, got, "/buf")
	delete(got)

	// % without a buf dir is left alone.
	got = file_parse_filename("%/x")
	testing.expect_value(t, got, "%/x")
	delete(got)

	// No user expansion: ~other is not a prefix match.
	got = file_parse_filename("~other/x")
	testing.expect_value(t, got, "~other/x")
	delete(got)

	got = file_parse_filename("plain")
	testing.expect_value(t, got, "plain")
	delete(got)

	got = file_parse_filename("")
	testing.expect_value(t, got, "")
	delete(got)
}

// split_path keeps the slash with the directory.
@(test)
file_test_split_path :: proc(t: ^testing.T) {
	dir, file := file_split_path("a/b/c")
	testing.expect_value(t, dir, "a/b/")
	testing.expect_value(t, file, "c")

	dir, file = file_split_path("name")
	testing.expect_value(t, dir, "")
	testing.expect_value(t, file, "name")

	dir, file = file_split_path("/x")
	testing.expect_value(t, dir, "/")
	testing.expect_value(t, file, "x")

	dir, file = file_split_path("a/")
	testing.expect_value(t, dir, "a/")
	testing.expect_value(t, file, "")

	dir, file = file_split_path("/")
	testing.expect_value(t, dir, "/")
	testing.expect_value(t, file, "")

	dir, file = file_split_path("")
	testing.expect_value(t, dir, "")
	testing.expect_value(t, file, "")
}

// tmpdir honors $TMPDIR (minus one trailing slash) and $HOME-less
// fallbacks; homedir is non-empty in practice.
@(test)
file_test_tmpdir :: proc(t: ^testing.T) {
	sync.mutex_lock(&test_env_mutex)
	defer sync.mutex_unlock(&test_env_mutex)
	raw := posix.getenv("TMPDIR")
	got := file_tmpdir()
	if raw == nil || len(string(raw)) == 0 {
		testing.expect_value(t, got, "/tmp")
	} else if s := string(raw); s[len(s) - 1] == '/' {
		testing.expect_value(t, got, s[:len(s) - 1])
	} else {
		testing.expect_value(t, got, string(raw))
	}

	have_old := raw != nil
	saved := have_old ? strings.clone(string(raw)) : ""
	defer delete(saved)
	defer file_test_restore_tmpdir(saved, have_old)

	base := strings.clone(file_tmpdir())
	defer delete(base)
	slashed := strings.concatenate({base, "/"}, context.temp_allocator)
	os.set_env("TMPDIR", slashed)
	testing.expect_value(t, file_tmpdir(), base)
	os.unset_env("TMPDIR")
	testing.expect_value(t, file_tmpdir(), "/tmp")
	os.set_env("TMPDIR", "")
	testing.expect_value(t, file_tmpdir(), "/tmp")
}

@(test)
file_test_homedir :: proc(t: ^testing.T) {
	sync.mutex_lock(&test_env_mutex)
	defer sync.mutex_unlock(&test_env_mutex)
	testing.expect(t, len(file_homedir()) > 0)
}

// real_path: empty passthrough, canonical identity, non-existing
// suffix appended, trailing slash stripped.
@(test)
file_test_real_path :: proc(t: ^testing.T) {
	got, err := file_real_path("")
	testing.expect_value(t, err, File_Error.None)
	testing.expect_value(t, got, "")
	delete(got)

	base := file_real_path(file_tmpdir(), context.temp_allocator) or_else ""
	testing.expect(t, len(base) > 0)

	leaf := "kak_file_test_real_a"
	name := file_test_scratch(leaf)
	defer delete(name)
	testing.expect_value(t, file_write_to_file(name, "x"), File_Error.None)
	defer os.remove(name)

	got, err = file_real_path(name)
	testing.expect_value(t, err, File_Error.None)
	expected := strings.concatenate({base, "/", leaf}, context.temp_allocator)
	testing.expect_value(t, got, expected)
	delete(got)

	deep := strings.concatenate({name, "/nope/nested"}, context.temp_allocator)
	got, err = file_real_path(deep)
	testing.expect_value(t, err, File_Error.None)
	expected_deep := strings.concatenate({base, "/", leaf, "/nope/nested"}, context.temp_allocator)
	testing.expect_value(t, got, expected_deep)
	delete(got)

	slashed := strings.concatenate({base, "/"}, context.temp_allocator)
	got, err = file_real_path(slashed)
	testing.expect_value(t, err, File_Error.None)
	testing.expect_value(t, got, base)
	delete(got)
}

// compact_path relative to a chdir'd cwd: inside shrinks to relative,
// home shrinks to ~, outside is unchanged.
@(test)
file_test_compact_path :: proc(t: ^testing.T) {
	cwd_buf: [1024]byte
	cwd_raw := posix.getcwd(([^]c.char)(raw_data(cwd_buf[:])), 1024)
	if cwd_raw == nil {
		testing.expect(t, false, "cannot save cwd")
		return
	}
	saved_cwd := strings.clone(string(cwd_raw))
	defer delete(saved_cwd)
	tmp_c := strings.clone_to_cstring(file_tmpdir(), context.temp_allocator)
	if posix.chdir(tmp_c) != .OK {
		testing.expect(t, false, "cannot chdir to tmpdir")
		return
	}
	defer file_test_chdir(saved_cwd)

	leaf := "kak_file_test_compact_xyz"
	abs := file_test_scratch(leaf)
	defer delete(abs)
	got, err := file_compact_path(abs)
	testing.expect_value(t, err, File_Error.None)
	testing.expect_value(t, got, leaf)
	delete(got)

	// Home case only when home is neither the cwd nor under it (else
	// the cwd branch legitimately wins).
	home := file_homedir()
	if len(home) > 0 {
		real_home, _ := file_real_path(home, context.temp_allocator)
		real_tmp, _ := file_real_path(file_tmpdir(), context.temp_allocator)
		under_cwd := real_home == real_tmp || strings.has_prefix(real_home, strings.concatenate({real_tmp, "/"}, context.temp_allocator))
		if !under_cwd {
			target := strings.concatenate({home, "/kak_file_test_compact_home_xyz"}, context.temp_allocator)
			got, err = file_compact_path(target)
			testing.expect_value(t, err, File_Error.None)
			testing.expect_value(t, got, "~/kak_file_test_compact_home_xyz")
			delete(got)
		}
	}

	outside := "/kak_file_test_compact_outside_xyz"
	got, err = file_compact_path(outside)
	testing.expect_value(t, err, File_Error.None)
	testing.expect_value(t, got, outside)
	delete(got)

	got, err = file_compact_path("")
	testing.expect_value(t, err, File_Error.None)
	testing.expect_value(t, got, "")
	delete(got)
}

// The test binary path resolves to an existing file.
@(test)
file_test_binary_path :: proc(t: ^testing.T) {
	path, err := file_get_kak_binary_path()
	testing.expect_value(t, err, File_Error.None)
	testing.expect(t, len(path) > 0)
	testing.expect(t, file_exists(path))
	delete(path)
}

// fd poll transitions across a pipe write and drain.
@(test)
file_test_fd_readable_writable :: proc(t: ^testing.T) {
	fds := [2]posix.FD{-1, -1}
	testing.expect_value(t, posix.pipe(&fds), posix.result.OK)
	rfd, wfd := int(fds[0]), int(fds[1])
	defer posix.close(posix.FD(rfd))
	defer posix.close(posix.FD(wfd))

	testing.expect(t, !file_fd_readable(rfd))
	testing.expect(t, file_fd_writable(wfd))
	buf := [1]byte{'q'}
	testing.expect_value(t, int(posix.write(posix.FD(wfd), raw_data(buf[:]), 1)), 1)
	testing.expect(t, file_fd_readable(rfd))
	got: [1]byte
	testing.expect_value(t, int(posix.read(posix.FD(rfd), raw_data(got[:]), 1)), 1)
	testing.expect(t, !file_fd_readable(rfd))
}

// read_fd/write over a pipe: roundtrip, \r stripping, bad-fd errors.
@(test)
file_test_read_write_fd :: proc(t: ^testing.T) {
	fds := [2]posix.FD{-1, -1}
	testing.expect_value(t, posix.pipe(&fds), posix.result.OK)
	rfd, wfd := int(fds[0]), int(fds[1])
	testing.expect_value(t, file_write(wfd, "hello"), File_Error.None)
	posix.close(posix.FD(wfd)) // EOF for the reader
	got, err := file_read_fd(rfd)
	testing.expect_value(t, err, File_Error.None)
	testing.expect_value(t, got, "hello")
	delete(got)
	posix.close(posix.FD(rfd))

	fds = [2]posix.FD{-1, -1}
	testing.expect_value(t, posix.pipe(&fds), posix.result.OK)
	rfd, wfd = int(fds[0]), int(fds[1])
	testing.expect_value(t, file_write(wfd, "a\rb\nc\r"), File_Error.None)
	posix.close(posix.FD(wfd))
	got, err = file_read_fd(rfd, true)
	testing.expect_value(t, err, File_Error.None)
	testing.expect_value(t, got, "ab\nc")
	delete(got)
	posix.close(posix.FD(rfd))

	// A never-allocatable fd fails with EBADF. (A small closed fd
	// cannot be used here: another test thread may reuse its number.)
	dead := 2000000000
	_, err = file_read_fd(dead)
	testing.expect_value(t, err, File_Error.Read_Failed)
	testing.expect_value(t, file_write(dead, "x"), File_Error.Write_Failed)
	testing.expect_value(t, file_write(dead, ""), File_Error.None) // nothing to write
}

// read_file/write_to_file roundtrips plus error paths.
@(test)
file_test_read_write_file :: proc(t: ^testing.T) {
	name := file_test_scratch("kak_file_test_rw")
	defer delete(name)
	testing.expect_value(t, file_write_to_file(name, "content"), File_Error.None)
	defer os.remove(name)
	got, err := file_read_file(name)
	testing.expect_value(t, err, File_Error.None)
	testing.expect_value(t, got, "content")
	delete(got)

	testing.expect_value(t, file_write_to_file(name, "a\r\nb"), File_Error.None)
	got, err = file_read_file(name, true)
	testing.expect_value(t, err, File_Error.None)
	testing.expect_value(t, got, "a\nb")
	delete(got)

	missing := file_test_scratch("kak_file_test_rw_missing_xyz")
	defer delete(missing)
	_, err = file_read_file(missing)
	testing.expect_value(t, err, File_Error.Open_Failed)
	bad := strings.concatenate({missing, "/sub"}, context.temp_allocator)
	testing.expect_value(t, file_write_to_file(bad, "x"), File_Error.Open_Failed)

	// Atomic (blocking) write to a regular file.
	afd, aerr := file_create_file(name)
	testing.expect_value(t, aerr, File_Error.None)
	testing.expect_value(t, file_write(int(afd), "atomic", true), File_Error.None)
	posix.close(posix.FD(afd))
	got, err = file_read_file(name)
	testing.expect_value(t, got, "atomic")
	delete(got)
}

// create_file opens 0644 truncating; bad paths fail.
@(test)
file_test_create_file :: proc(t: ^testing.T) {
	name := file_test_scratch("kak_file_test_create")
	defer delete(name)
	defer os.remove(name)
	fd, err := file_create_file(name)
	testing.expect_value(t, err, File_Error.None)
	testing.expect(t, fd >= 0)
	testing.expect_value(t, file_write(fd, "hello"), File_Error.None)
	posix.close(posix.FD(fd))
	testing.expect(t, file_regular_file_exists(name))

	fd, err = file_create_file(name) // truncates
	testing.expect_value(t, err, File_Error.None)
	posix.close(posix.FD(fd))
	got, rerr := file_read_file(name)
	testing.expect_value(t, rerr, File_Error.None)
	testing.expect_value(t, got, "")
	delete(got)

	missing := file_test_scratch("kak_file_test_create_missing_xyz")
	defer delete(missing)
	bad := strings.concatenate({missing, "/f"}, context.temp_allocator)
	_, err = file_create_file(bad)
	testing.expect_value(t, err, File_Error.Open_Failed)
}

// open_temp_file yields an open fd plus a .kak. sibling path.
@(test)
file_test_open_temp_file :: proc(t: ^testing.T) {
	anchor := file_test_scratch("kak_file_test_temp_anchor")
	defer delete(anchor)
	testing.expect_value(t, file_write_to_file(anchor, "x"), File_Error.None)
	defer os.remove(anchor)

	fd, path, err := file_open_temp_file(anchor)
	testing.expect_value(t, err, File_Error.None)
	testing.expect(t, fd >= 0)
	defer delete(path)
	defer os.remove(path)
	testing.expect(t, file_exists(path))
	real_tmp, rterr := file_real_path(file_tmpdir(), context.temp_allocator)
	testing.expect_value(t, rterr, File_Error.None)
	testing.expect(t, strings.has_prefix(path, real_tmp))
	testing.expect(t, strings.contains(path, ".kak_file_test_temp_anchor.kak."))
	posix.close(posix.FD(fd))
}

// Mapped files view content; empty/missing/dir cases covered.
@(test)
file_test_mapped_file :: proc(t: ^testing.T) {
	name := file_test_scratch("kak_file_test_mmap")
	defer delete(name)
	testing.expect_value(t, file_write_to_file(name, "mapped!"), File_Error.None)
	defer os.remove(name)

	mapped, err := file_mapped_file_open(name)
	testing.expect_value(t, err, File_Error.None)
	view, verr := file_mapped_file_view(mapped)
	testing.expect_value(t, verr, File_Error.None)
	testing.expect_value(t, view, "mapped!")
	testing.expect_value(t, string(file_mapped_file_bytes(mapped)), "mapped!")
	file_mapped_file_close(&mapped)
	file_mapped_file_close(&mapped) // second close is a no-op

	empty := file_test_scratch("kak_file_test_mmap_empty")
	defer delete(empty)
	testing.expect_value(t, file_write_to_file(empty, ""), File_Error.None)
	defer os.remove(empty)
	mapped, err = file_mapped_file_open(empty)
	testing.expect_value(t, err, File_Error.None)
	view, verr = file_mapped_file_view(mapped)
	testing.expect_value(t, verr, File_Error.None)
	testing.expect_value(t, view, "")
	file_mapped_file_close(&mapped)

	missing := file_test_scratch("kak_file_test_mmap_missing_xyz")
	defer delete(missing)
	_, err = file_mapped_file_open(missing)
	testing.expect_value(t, err, File_Error.Open_Failed)

	_, err = file_mapped_file_open(file_tmpdir())
	testing.expect_value(t, err, File_Error.Is_Directory)
}

// WriteMethod names round-trip; unknown names miss.
@(test)
file_test_write_method :: proc(t: ^testing.T) {
	name, ok := file_write_method_to_name(.Overwrite)
	testing.expect(t, ok)
	testing.expect_value(t, name, "overwrite")
	name, ok = file_write_method_to_name(.Replace)
	testing.expect(t, ok)
	testing.expect_value(t, name, "replace")

	method, mok := file_write_method_from_name("overwrite")
	testing.expect(t, mok)
	testing.expect_value(t, method, File_Write_Method.Overwrite)
	method, mok = file_write_method_from_name("replace")
	testing.expect(t, mok)
	testing.expect_value(t, method, File_Write_Method.Replace)
	_, mok = file_write_method_from_name("append")
	testing.expect(t, !mok)
}

// find_file: absolute, ~/, and searched paths.
@(test)
file_test_find_file :: proc(t: ^testing.T) {
	// Absolute hits return themselves; misses and dirs return "".
	abs := file_test_scratch("kak_file_test_find_abs")
	defer delete(abs)
	testing.expect_value(t, file_write_to_file(abs, "x"), File_Error.None)
	defer os.remove(abs)
	real_abs, rabs_err := file_real_path(abs, context.temp_allocator)
	testing.expect_value(t, rabs_err, File_Error.None)
	found := file_find_file(real_abs, "", nil)
	testing.expect_value(t, found, real_abs)
	delete(found)
	missing_abs := strings.concatenate({real_abs, "_missing_xyz"}, context.temp_allocator)
	found = file_find_file(missing_abs, "", nil)
	testing.expect_value(t, found, "")
	delete(found)
	found = file_find_file(file_tmpdir(), "", nil)
	testing.expect_value(t, found, "")
	delete(found)

	// ~/ hits and misses.
	home := file_homedir()
	if len(home) > 0 {
		leaf := ".kak_file_test_find_home_xyz"
		home_file := strings.concatenate({home, "/", leaf}, context.temp_allocator)
		testing.expect_value(t, file_write_to_file(home_file, "x"), File_Error.None)
		defer os.remove(home_file)
		query := strings.concatenate({"~/", leaf}, context.temp_allocator)
		found = file_find_file(query, "", nil)
		testing.expect_value(t, found, home_file)
		delete(found)
	}
	found = file_find_file("~/kak_file_test_find_home_missing_xyz", "", nil)
	testing.expect_value(t, found, "")
	delete(found)

	// Searched paths: plain, trailing-slash, and %-via-bufdir forms.
	sub := file_test_scratch("kak_file_test_find_sub")
	defer delete(sub)
	testing.expect_value(t, file_make_directory(sub, posix.mode_t{.IRUSR, .IWUSR, .IXUSR}), File_Error.None)
	target := strings.concatenate({sub, "/target.txt"}, context.temp_allocator)
	testing.expect_value(t, file_write_to_file(target, "x"), File_Error.None)
	defer os.remove(sub)
	defer os.remove(target)
	paths_arr := [1]string{sub}
	found = file_find_file("target.txt", "", paths_arr[:])
	testing.expect_value(t, found, target)
	delete(found)
	slash_entry := strings.concatenate({sub, "/"}, context.temp_allocator)
	paths_slash_arr := [1]string{slash_entry}
	found = file_find_file("target.txt", "", paths_slash_arr[:])
	testing.expect_value(t, found, target)
	delete(found)
	paths_pct_arr := [1]string{"%/kak_file_test_find_sub"}
	found = file_find_file("target.txt", file_tmpdir(), paths_pct_arr[:])
	testing.expect_value(t, found, target)
	delete(found)
	found = file_find_file("target_missing_xyz.txt", "", paths_arr[:])
	testing.expect_value(t, found, "")
	delete(found)
	found = file_find_file("anything.txt", "", nil)
	testing.expect_value(t, found, "")
	delete(found)
}

// Existence predicates across file, dir, and missing.
@(test)
file_test_exists :: proc(t: ^testing.T) {
	name := file_test_scratch("kak_file_test_exists")
	defer delete(name)
	testing.expect_value(t, file_write_to_file(name, "x"), File_Error.None)
	defer os.remove(name)
	testing.expect(t, file_exists(name))
	testing.expect(t, file_regular_file_exists(name))
	testing.expect(t, file_exists(file_tmpdir()))
	testing.expect(t, !file_regular_file_exists(file_tmpdir()))
	missing := file_test_scratch("kak_file_test_exists_missing_xyz")
	defer delete(missing)
	testing.expect(t, !file_exists(missing))
	testing.expect(t, !file_regular_file_exists(missing))
}

// list_files reports bare names with / suffixed dirs; bad dirs are silent.
@(test)
file_test_list_files :: proc(t: ^testing.T) {
	file_test_listed = make([dynamic]string)
	defer {
		for s in file_test_listed {
			delete(s)
		}
		delete(file_test_listed)
		file_test_listed = nil
	}

	dir := file_test_scratch("kak_file_test_list")
	defer delete(dir)
	testing.expect_value(t, file_make_directory(dir, posix.mode_t{.IRUSR, .IWUSR, .IXUSR}), File_Error.None)
	defer os.remove(dir)
	a := strings.concatenate({dir, "/a"}, context.temp_allocator)
	b := strings.concatenate({dir, "/b"}, context.temp_allocator)
	testing.expect_value(t, file_write_to_file(a, "a"), File_Error.None)
	testing.expect_value(t, file_write_to_file(b, "b"), File_Error.None)
	defer os.remove(a)
	defer os.remove(b)
	sub := strings.concatenate({dir, "/c"}, context.temp_allocator)
	testing.expect_value(t, file_make_directory(sub, posix.mode_t{.IRUSR, .IWUSR, .IXUSR}), File_Error.None)
	defer os.remove(sub)

	file_list_files(dir, file_test_collect)
	// Like the C++, dot entries are reported (dirs get a '/' suffix).
	testing.expect_value(t, len(file_test_listed), 5)
	saw_a, saw_b, saw_c, saw_dot, saw_dotdot := false, false, false, false, false
	for s in file_test_listed {
		saw_a = saw_a || s == "a"
		saw_b = saw_b || s == "b"
		saw_c = saw_c || s == "c/"
		saw_dot = saw_dot || s == "./"
		saw_dotdot = saw_dotdot || s == "../"
	}
	testing.expect(t, saw_a && saw_b && saw_c && saw_dot && saw_dotdot)

	for s in file_test_listed {
		delete(s)
	}
	clear(&file_test_listed)
	missing := file_test_scratch("kak_file_test_list_missing_xyz")
	defer delete(missing)
	file_list_files(missing, file_test_collect)
	testing.expect_value(t, len(file_test_listed), 0)
}

// make_directory builds parents, tolerates repeats, rejects files.
@(test)
file_test_make_directory :: proc(t: ^testing.T) {
	mode := posix.mode_t{.IRUSR, .IWUSR, .IXUSR, .IRGRP, .IXGRP, .IROTH, .IXOTH}
	nested := strings.concatenate({file_tmpdir(), "/kak_file_test_mkdir_a/b/c"}, context.temp_allocator)
	testing.expect_value(t, file_make_directory(nested, mode), File_Error.None)
	testing.expect(t, file_exists(nested))
	testing.expect_value(t, file_make_directory(nested, mode), File_Error.None)
	slashed := strings.concatenate({nested, "/"}, context.temp_allocator)
	testing.expect_value(t, file_make_directory(slashed, mode), File_Error.None)
	os.remove(nested)
	os.remove(strings.concatenate({file_tmpdir(), "/kak_file_test_mkdir_a/b"}, context.temp_allocator))
	os.remove(strings.concatenate({file_tmpdir(), "/kak_file_test_mkdir_a"}, context.temp_allocator))
	testing.expect(t, !file_exists(nested))

	testing.expect_value(t, file_make_directory("", mode), File_Error.None)

	blocker := file_test_scratch("kak_file_test_mkdir_file")
	defer delete(blocker)
	testing.expect_value(t, file_write_to_file(blocker, "x"), File_Error.None)
	defer os.remove(blocker)
	testing.expect_value(t, file_make_directory(blocker, mode), File_Error.Mkdir_Failed)
}

// Timestamps and content status, including empty and missing files.
@(test)
file_test_fs_timestamp_status :: proc(t: ^testing.T) {
	testing.expect_value(t, File_Invalid_Time, File_Invalid_Time)
	missing := file_test_scratch("kak_file_test_fs_missing_xyz")
	defer delete(missing)
	testing.expect_value(t, file_get_fs_timestamp(missing), File_Invalid_Time)
	_, serr := file_get_fs_status(missing)
	testing.expect_value(t, serr, File_Error.Open_Failed)

	name := file_test_scratch("kak_file_test_fs")
	defer delete(name)
	testing.expect_value(t, file_write_to_file(name, "hello"), File_Error.None)
	defer os.remove(name)
	ts := file_get_fs_timestamp(name)
	testing.expect(t, ts != File_Invalid_Time)
	testing.expect_value(t, file_get_fs_timestamp(name), ts)
	status, err := file_get_fs_status(name)
	testing.expect_value(t, err, File_Error.None)
	testing.expect_value(t, status.timestamp, ts)
	testing.expect_value(t, status.file_size, 5)
	testing.expect_value(t, status.hash, hash_murmur3("hello"))

	empty := file_test_scratch("kak_file_test_fs_empty")
	defer delete(empty)
	testing.expect_value(t, file_write_to_file(empty, ""), File_Error.None)
	defer os.remove(empty)
	status, err = file_get_fs_status(empty)
	testing.expect_value(t, err, File_Error.None)
	testing.expect_value(t, status.file_size, 0)
	testing.expect_value(t, status.hash, hash_murmur3(""))
}

// BufferedWriter: explicit flush boundary, auto-flush at capacity,
// small custom capacity, and bad-fd errors.
@(test)
file_test_buffered_writer :: proc(t: ^testing.T) {
	name := file_test_scratch("kak_file_test_buf_a")
	defer delete(name)
	defer os.remove(name)
	fd, cerr := file_create_file(name)
	testing.expect_value(t, cerr, File_Error.None)
	writer := file_buffered_writer_make(fd)
	testing.expect_value(t, file_buffered_writer_write(&writer, "ab"), File_Error.None)
	testing.expect_value(t, writer.pos, 2)
	testing.expect_value(t, file_buffered_writer_flush(&writer), File_Error.None)
	testing.expect_value(t, writer.pos, 0)
	posix.close(posix.FD(fd))
	got, rerr := file_read_file(name)
	testing.expect_value(t, rerr, File_Error.None)
	testing.expect_value(t, got, "ab")
	delete(got)

	// Unflushed bytes stay invisible; a 5000-byte write auto-flushes
	// the first 4096-byte block.
	name2 := file_test_scratch("kak_file_test_buf_b")
	defer delete(name2)
	defer os.remove(name2)
	fd2, cerr2 := file_create_file(name2)
	testing.expect_value(t, cerr2, File_Error.None)
	writer2 := file_buffered_writer_make(fd2)
	testing.expect_value(t, file_buffered_writer_write(&writer2, "xy"), File_Error.None)
	mid, merr := file_read_file(name2)
	testing.expect_value(t, merr, File_Error.None)
	testing.expect_value(t, mid, "")
	delete(mid)
	payload := make([dynamic]byte, 5000)
	defer delete(payload)
	for i in 0 ..< 5000 {
		payload[i] = 'q'
	}
	testing.expect_value(t, file_buffered_writer_write(&writer2, string(payload[:])), File_Error.None)
	part, perr := file_read_file(name2)
	testing.expect_value(t, perr, File_Error.None)
	testing.expect_value(t, len(part), 4096)
	delete(part)
	testing.expect_value(t, file_buffered_writer_flush(&writer2), File_Error.None)
	posix.close(posix.FD(fd2))
	full, ferr := file_read_file(name2)
	testing.expect_value(t, ferr, File_Error.None)
	testing.expect_value(t, full, strings.concatenate({"xy", string(payload[:])}, context.temp_allocator))
	delete(full)

	// Tiny custom capacity flushes every 8 bytes.
	name3 := file_test_scratch("kak_file_test_buf_c")
	defer delete(name3)
	defer os.remove(name3)
	fd3, cerr3 := file_create_file(name3)
	testing.expect_value(t, cerr3, File_Error.None)
	writer3 := File_Buffered_Writer(8){fd = fd3}
	testing.expect_value(t, file_buffered_writer_write(&writer3, "0123456789abcdefghij"), File_Error.None)
	testing.expect_value(t, writer3.pos, 4)
	testing.expect_value(t, file_buffered_writer_flush(&writer3), File_Error.None)
	posix.close(posix.FD(fd3))
	got3, rerr3 := file_read_file(name3)
	testing.expect_value(t, rerr3, File_Error.None)
	testing.expect_value(t, got3, "0123456789abcdefghij")
	delete(got3)

	// Bad fds fail on flush (buffered writes alone cannot fail).
	bad := file_buffered_writer_make(-1)
	testing.expect_value(t, file_buffered_writer_write(&bad, "x"), File_Error.None)
	testing.expect_value(t, file_buffered_writer_flush(&bad), File_Error.Write_Failed)
	testing.expect_value(t, file_buffered_writer_write(&bad, string(payload[:])), File_Error.Write_Failed)
}
