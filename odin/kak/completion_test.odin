package kak

import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import posix "core:sys/posix"

// completion_test_free_owned releases a candidate list with owned strings.
completion_test_free_owned :: proc(list: ^Candidate_List) {
	for s in list^ {
		delete(s)
	}
	delete(list^)
}

// completion_test_contains reports whether list holds s.
completion_test_contains :: proc(list: Candidate_List, s: string) -> bool {
	for c in list {
		if c == s {
			return true
		}
	}
	return false
}

@(test)
completion_test_complete_basic :: proc(t: ^testing.T) {
	container := []string{"foo", "bar", "foobar"}
	res := completion_complete("foo", -1, container)
	defer delete(res)
	testing.expect_value(t, len(res), 2)
	testing.expect(t, completion_test_contains(res, "foo"))
	testing.expect(t, completion_test_contains(res, "foobar"))
	// Candidates borrow the container strings.
	for c in res {
		owned := false
		for s in container {
			if raw_data(c) == raw_data(s) {
				owned = true
			}
		}
		testing.expect(t, owned)
	}
}

@(test)
completion_test_complete_cursor_truncates :: proc(t: ^testing.T) {
	container := []string{"foo", "bar", "foobar"}
	full := completion_complete("foo", -1, container)
	defer delete(full)
	trunc := completion_complete("foobar", 3, container)
	defer delete(trunc)
	testing.expect_value(t, len(trunc), len(full))
	for i := 0; i < len(full); i += 1 {
		testing.expect_value(t, trunc[i], full[i])
	}
}

@(test)
completion_test_complete_no_match :: proc(t: ^testing.T) {
	container := []string{"foo", "bar"}
	res := completion_complete("zzz", -1, container)
	defer delete(res)
	testing.expect_value(t, len(res), 0)

	empty := completion_complete("foo", -1, {})
	defer delete(empty)
	testing.expect_value(t, len(empty), 0)
}

@(test)
completion_test_complete_empty_query :: proc(t: ^testing.T) {
	container := []string{"foo", "bar", "baz"}
	res := completion_complete("", -1, container)
	defer delete(res)
	testing.expect_value(t, len(res), 3)
}

@(test)
completion_test_offset_pos :: proc(t: ^testing.T) {
	candidates := make(Candidate_List, 0, 2)
	append(&candidates, "a", "b")
	c := Completions{candidates = candidates, start = 2, end = 5, flags = {.Menu}}
	shifted := completion_offset_pos(c, 3)
	testing.expect_value(t, shifted.start, Units_ByteCount(5))
	testing.expect_value(t, shifted.end, Units_ByteCount(8))
	testing.expect_value(t, shifted.flags, Completion_Flags{.Menu})
	testing.expect_value(t, len(shifted.candidates), 2)
	testing.expect_value(t, shifted.candidates[0], "a")
	delete(candidates)
}

@(test)
completion_test_complete_nothing :: proc(t: ^testing.T) {
	c := completion_complete_nothing(nil, "ignored", 7)
	testing.expect_value(t, c.start, Units_ByteCount(7))
	testing.expect_value(t, c.end, Units_ByteCount(7))
	testing.expect_value(t, len(c.candidates), 0)
	testing.expect_value(t, c.flags, Completion_Flags{})
}

@(test)
completion_test_shell_word_range :: proc(t: ^testing.T) {
	Case :: struct {
		prefix:     string,
		cursor:     Units_ByteCount,
		start:      Units_ByteCount,
		end:        Units_ByteCount,
		is_command: bool,
	}
	cases := []Case{
		{"", 0, 0, 0, true},
		{"ls", 2, 0, 2, true},
		{"ls foo", 2, 0, 2, true},
		{"ls foo", 5, 3, 6, false},
		{"a;ls", 4, 0, 4, true},
		{"a|ls", 4, 0, 4, true},
		{"a&&ls", 5, 0, 5, true},
		{"a&ls", 4, 0, 4, true},
		{"a; ls", 4, 3, 5, true},
		{"a && ls", 6, 5, 7, true},
		{"ab   ", 3, 5, 5, false},
		{"  ls", 4, 2, 4, true},
		{"ls  foo  bar", 8, 9, 12, false},
		{"echo hi;format x", 15, 15, 16, false},
	}
	for c in cases {
		start, end, is_command := completion_shell_word_range(c.prefix, c.cursor)
		testing.expect_value(t, start, c.start)
		testing.expect_value(t, end, c.end)
		testing.expect_value(t, is_command, c.is_command)
	}
}

// completion_test_scratch makes a fresh directory for filename tests.
completion_test_scratch :: proc(t: ^testing.T, name: string) -> string {
	dir := strings.concatenate({file_tmpdir(), "/", name}, context.temp_allocator)
	testing.expect_value(
		t,
		file_make_directory(dir, posix.mode_t{.IRUSR, .IWUSR, .IXUSR}),
		File_Error.None,
	)
	return dir
}

@(test)
completion_test_filename :: proc(t: ^testing.T) {
	dir := completion_test_scratch(t, "kak_completion_test_fn")
	a := strings.concatenate({dir, "/a.txt"}, context.temp_allocator)
	b := strings.concatenate({dir, "/b.md"}, context.temp_allocator)
	sub := strings.concatenate({dir, "/subdir"}, context.temp_allocator)
	testing.expect_value(t, file_write_to_file(a, "a"), File_Error.None)
	testing.expect_value(t, file_write_to_file(b, "b"), File_Error.None)
	testing.expect_value(
		t,
		file_make_directory(sub, posix.mode_t{.IRUSR, .IWUSR, .IXUSR}),
		File_Error.None,
	)
	defer os.remove(a)
	defer os.remove(b)
	defer os.remove(sub)
	defer os.remove(dir)

	ignored, msg, rerr := regex_make("")
	testing.expect_value(t, rerr, Regex_Error.None)
	delete(msg)
	defer regex_destroy(&ignored)

	// A directory prefix lists everything, directories with a '/' suffix.
	pd := strings.concatenate({dir, "/"}, context.temp_allocator)
	all := completion_complete_filename(pd, &ignored)
	defer completion_test_free_owned(&all)
	want_a_all := strings.concatenate({dir, "/a.txt"}, context.temp_allocator)
	want_b_all := strings.concatenate({dir, "/b.md"}, context.temp_allocator)
	want_sub_all := strings.concatenate({dir, "/subdir/"}, context.temp_allocator)
	testing.expect(t, completion_test_contains(all, want_a_all))
	testing.expect(t, completion_test_contains(all, want_b_all))
	testing.expect(t, completion_test_contains(all, want_sub_all))

	// Prefix filtering keeps the dirname.
	pa := strings.concatenate({dir, "/a"}, context.temp_allocator)
	one := completion_complete_filename(pa, &ignored)
	defer completion_test_free_owned(&one)
	want_a := strings.concatenate({dir, "/a.txt"}, context.temp_allocator)
	testing.expect_value(t, len(one), 1)
	testing.expect_value(t, one[0], want_a)

	// Cursor truncation.
	pax := strings.concatenate({dir, "/ax"}, context.temp_allocator)
	trunc := completion_complete_filename(pax, &ignored, Units_ByteCount(len(pax) - 1))
	defer completion_test_free_owned(&trunc)
	testing.expect_value(t, len(trunc), 1)
	testing.expect_value(t, trunc[0], want_a)

	// OnlyDirectories drops plain files.
	dirs := completion_complete_filename(pd, &ignored, -1, {.Only_Directories})
	defer completion_test_free_owned(&dirs)
	testing.expect(t, len(dirs) > 0)
	for c in dirs {
		testing.expect(t, len(c) > 0 && c[len(c) - 1] == '/')
		testing.expect(t, !strings.has_suffix(c, "a.txt"))
	}
	want_sub := strings.concatenate({dir, "/subdir/"}, context.temp_allocator)
	testing.expect(t, completion_test_contains(dirs, want_sub))
	// The directory itself is echoed back for menu selection.
	testing.expect(t, completion_test_contains(dirs, pd))

	// Expand prefixes with the parsed directory: ~/ expands to home.
	home_prefixed := completion_complete_filename("~/", &ignored, -1, {.Expand})
	defer completion_test_free_owned(&home_prefixed)
	home := strings.concatenate({file_homedir(), "/"}, context.temp_allocator)
	for c in home_prefixed {
		testing.expect(t, strings.has_prefix(c, home))
	}
	home_raw := completion_complete_filename("~/", &ignored)
	defer completion_test_free_owned(&home_raw)
	for c in home_raw {
		testing.expect(t, strings.has_prefix(c, "~/"))
	}
}

@(test)
completion_test_filename_ignored :: proc(t: ^testing.T) {
	dir := completion_test_scratch(t, "kak_completion_test_ign")
	ax := strings.concatenate({dir, "/ax"}, context.temp_allocator)
	bx := strings.concatenate({dir, "/bx"}, context.temp_allocator)
	testing.expect_value(t, file_write_to_file(ax, "a"), File_Error.None)
	testing.expect_value(t, file_write_to_file(bx, "b"), File_Error.None)
	defer os.remove(ax)
	defer os.remove(bx)
	defer os.remove(dir)

	ignored, msg, rerr := regex_make("ax")
	testing.expect_value(t, rerr, Regex_Error.None)
	delete(msg)
	defer regex_destroy(&ignored)

	// "ax" is ignored while completing the shorter prefix.
	pa := strings.concatenate({dir, "/a"}, context.temp_allocator)
	filtered := completion_complete_filename(pa, &ignored)
	defer completion_test_free_owned(&filtered)
	testing.expect_value(t, len(filtered), 0)

	// Once the prefix itself matches the ignored regex, filtering lifts.
	pax := strings.concatenate({dir, "/ax"}, context.temp_allocator)
	unfiltered := completion_complete_filename(pax, &ignored)
	defer completion_test_free_owned(&unfiltered)
	testing.expect_value(t, len(unfiltered), 1)

	// A regex matching every candidate completes nothing (the file
	// prefix "a" does not match it, so filtering stays on).
	both, bmsg, berr := regex_make("ax|bx")
	testing.expect_value(t, berr, Regex_Error.None)
	delete(bmsg)
	defer regex_destroy(&both)
	none := completion_complete_filename(pa, &both)
	defer completion_test_free_owned(&none)
	testing.expect_value(t, len(none), 0)
}

@(test)
completion_test_command_dirname :: proc(t: ^testing.T) {
	dir := completion_test_scratch(t, "kak_completion_test_cmd")
	exe := strings.concatenate({dir, "/mytool"}, context.temp_allocator)
	plain := strings.concatenate({dir, "/notes.txt"}, context.temp_allocator)
	sub := strings.concatenate({dir, "/sub"}, context.temp_allocator)
	testing.expect_value(t, file_write_to_file(exe, "x"), File_Error.None)
	testing.expect_value(t, file_write_to_file(plain, "x"), File_Error.None)
	testing.expect_value(
		t,
		file_make_directory(sub, posix.mode_t{.IRUSR, .IWUSR, .IXUSR}),
		File_Error.None,
	)
	exe_c := strings.clone_to_cstring(exe, context.temp_allocator)
	posix.chmod(
		exe_c,
		posix.mode_t{.IRUSR, .IWUSR, .IXUSR, .IRGRP, .IXGRP, .IROTH, .IXOTH},
	)
	defer os.remove(exe)
	defer os.remove(plain)
	defer os.remove(sub)
	defer os.remove(dir)

	prefix := strings.concatenate({dir, "/my"}, context.temp_allocator)
	res := completion_complete_command(prefix)
	defer completion_test_free_owned(&res)
	want := strings.concatenate({dir, "/mytool"}, context.temp_allocator)
	testing.expect_value(t, len(res), 1)
	testing.expect_value(t, res[0], want)

	// Subdirectories are offered, non-executable files are not.
	all_pref := strings.concatenate({dir, "/"}, context.temp_allocator)
	all := completion_complete_command(all_pref)
	defer completion_test_free_owned(&all)
	testing.expect(t, completion_test_contains(all, want))
	want_sub := strings.concatenate({dir, "/sub/"}, context.temp_allocator)
	testing.expect(t, completion_test_contains(all, want_sub))
	want_plain := strings.concatenate({dir, "/notes.txt"}, context.temp_allocator)
	testing.expect(t, !completion_test_contains(all, want_plain))
}

@(test)
completion_test_command_path :: proc(t: ^testing.T) {
	sync.mutex_lock(&test_env_mutex)
	defer sync.mutex_unlock(&test_env_mutex)
	dir := completion_test_scratch(t, "kak_completion_test_path")
	exe := strings.concatenate({dir, "/zz_mycmd_12345"}, context.temp_allocator)
	testing.expect_value(t, file_write_to_file(exe, "x"), File_Error.None)
	exe_c := strings.clone_to_cstring(exe, context.temp_allocator)
	posix.chmod(exe_c, posix.mode_t{.IRUSR, .IWUSR, .IXUSR})
	defer os.remove(exe)
	defer os.remove(dir)
	defer completion_test_reset_command_cache()

	old_path, had_path := os.lookup_env("PATH", context.temp_allocator)
	testing.expect(t, os.set_env("PATH", dir) == nil)
	defer if had_path {
		os.set_env("PATH", old_path)
	} else {
		os.unset_env("PATH")
	}

	res := completion_complete_command("zz_mycmd")
	defer completion_test_free_owned(&res)
	testing.expect_value(t, len(res), 1)
	testing.expect_value(t, res[0], "zz_mycmd_12345")

	missing := completion_complete_command("zz_nomatch_xyz")
	defer completion_test_free_owned(&missing)
	testing.expect_value(t, len(missing), 0)
}

// completion_test_reset_command_cache frees the persistent command cache
// so the PATH test leaves no tracked allocations behind.
completion_test_reset_command_cache :: proc() {
	for k in completion_command_cache {
		entry := completion_command_cache[k]
		delete(k, context.allocator)
		for c in entry.commands {
			delete(c, context.allocator)
		}
		delete(entry.commands)
	}
	delete(completion_command_cache)
	completion_command_cache = nil
}
