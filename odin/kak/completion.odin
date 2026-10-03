// Completion ported from src/completion.{hh,cc}: ranked candidate matching,
// filename/command completion, and shell word completion.
//
// Ownership: completion_complete borrows the container strings (free only
// the returned array). completion_complete_filename,
// completion_complete_command, and completion_shell_complete return owned
// strings (free each string, then the array). The command cache owns its
// keys and listings for the life of the process, like the C++ static.
package kak

import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import posix "core:sys/posix"

// completion_substr mirrors C++ StringView::substr(ByteCount from, length):
// a negative length, or one running past the end, extends to the end of s.
@(private = "file")
completion_substr :: proc(s: string, from, length: int) -> string {
	clamped_from := clamp(from, 0, len(s))
	max_length := len(s) - clamped_from
	if length < 0 || length >= max_length {
		return s[clamped_from:]
	}
	return s[clamped_from:clamped_from + length]
}

// completion_complete ranks container against the query truncated to
// cursor_pos bytes (a negative cursor_pos keeps the whole query), best
// match first (port of complete()). Candidates borrow the container
// strings; free only the returned array.
completion_complete :: proc(
	query: string,
	cursor_pos: Units_ByteCount,
	container: []string,
	allocator := context.allocator,
) -> Candidate_List {
	q := completion_substr(query, 0, int(cursor_pos))
	matches := make([dynamic]Ranked_Match, 0, len(container), context.temp_allocator)
	for s in container {
		m := ranked_match_make(s, q)
		if m.matches {
			append(&matches, m)
		}
	}
	slice.sort_by(matches[:], ranked_match_less)
	res := make(Candidate_List, 0, len(matches), allocator)
	for m in matches {
		append(&res, m.candidate)
	}
	return res
}

// Completion_File_Collector gathers file_list_files results for the
// completion procs. It travels through context.user_ptr because the
// list_files callback takes no user data.
@(private = "file")
Completion_File_Collector :: struct {
	names:     ^[dynamic]string,
	modes:     ^[dynamic]posix.mode_t,
	allocator: mem.Allocator,
}

@(private = "file")
completion_collect_file :: proc(name: string, st: posix.stat_t) {
	c := cast(^Completion_File_Collector)context.user_ptr
	append(c.names, strings.clone(name, c.allocator))
	append(c.modes, st.st_mode)
}

// completion_list_files returns the owned (name, mode) listing of dirname.
@(private = "file")
completion_list_files :: proc(
	dirname: string,
	allocator: mem.Allocator,
) -> (
	names: [dynamic]string,
	modes: [dynamic]posix.mode_t,
) {
	names = make([dynamic]string, 0, 64, allocator)
	modes = make([dynamic]posix.mode_t, 0, 64, allocator)
	collector := Completion_File_Collector{&names, &modes, allocator}
	context.user_ptr = &collector
	file_list_files(dirname, completion_collect_file)
	context.user_ptr = nil
	return names, modes
}

// completion_join_candidates prefixes every match with dirname (port of
// the static candidates() helper). The returned strings are owned.
@(private = "file")
completion_join_candidates :: proc(
	matches: []Ranked_Match,
	dirname: string,
	allocator: mem.Allocator,
) -> Candidate_List {
	res := make(Candidate_List, 0, len(matches), allocator)
	for m in matches {
		append(&res, strings.concatenate({dirname, m.candidate}, allocator))
	}
	return res
}

// completion_complete_filename completes prefix as a filename, skipping
// entries matched by ignored_regex (port of complete_filename). When
// Only_Directories is set and prefix names a directory, the directory
// itself is echoed back so menu completion can select it. Expand prefixes
// candidates with the parsed (tilde-expanded) directory. Returned strings
// are owned.
completion_complete_filename :: proc(
	prefix: string,
	ignored_regex: ^Regex,
	cursor_pos: Units_ByteCount = -1,
	flags: Filename_Flags = {},
	allocator := context.allocator,
) -> Candidate_List {
	trunc := completion_substr(prefix, 0, int(cursor_pos))
	dirname, fileprefix := file_split_path(trunc)
	parsed_dirname := file_parse_filename(dirname, "", context.temp_allocator)

	// When the file prefix itself matches the ignored regex, filtering
	// is disabled so the user can still complete it.
	filter := false
	vm: Regex_Vm
	vm_live := false
	if !regex_empty(ignored_regex) {
		vm = regex_vm_make(
			regex_impl(ignored_regex),
			{.Forward, .Any_Match, .No_Saves},
			context.temp_allocator,
		)
		vm_live = true
		filter = !regex_vm_exec(&vm, fileprefix, 0, len(fileprefix), 0, len(fileprefix), {})
	}
	defer if vm_live {
		regex_vm_destroy(&vm)
	}

	only_dirs := .Only_Directories in flags
	names, modes := completion_list_files(parsed_dirname, context.temp_allocator)
	matches := make([dynamic]Ranked_Match, 0, len(names), context.temp_allocator)
	kept := 0
	for i := 0; i < len(names); i += 1 {
		if only_dirs && !posix.S_ISDIR(modes[i]) {
			continue
		}
		if filter && regex_vm_exec(&vm, names[i], 0, len(names[i]), 0, len(names[i]), {}) {
			continue
		}
		kept += 1
		m := ranked_match_make(names[i], fileprefix)
		if m.matches {
			append(&matches, m)
		}
	}
	if only_dirs &&
	   len(dirname) > 0 &&
	   dirname[len(dirname) - 1] == '/' &&
	   len(fileprefix) == 0 &&
	   kept > 0 {
		append(&matches, ranked_match_make(fileprefix, fileprefix))
	}
	slice.sort_by(matches[:], ranked_match_less)
	dir := dirname
	if .Expand in flags {
		dir = parsed_dirname
	}
	return completion_join_candidates(matches[:], dir, allocator)
}

// Completion_Command_Cache is one PATH directory's cached listing (port of
// the static CommandCache in complete_command).
Completion_Command_Cache :: struct {
	mtime:    posix.timespec,
	commands: [dynamic]string,
}

// completion_command_cache mirrors the C++ function-static command cache:
// PATH directory -> cached executables. Lazily initialized; entries are
// refreshed when the directory mtime changes. Internal; tests reset it.
completion_command_cache: map[string]Completion_Command_Cache

// completion_complete_command completes prefix as a shell command: from
// the named directory when prefix contains one, else from PATH with a
// persistent per-directory cache (port of complete_command). Returned
// strings are owned.
completion_complete_command :: proc(
	prefix: string,
	cursor_pos: Units_ByteCount = -1,
	allocator := context.allocator,
) -> Candidate_List {
	trunc := completion_substr(prefix, 0, int(cursor_pos))
	real_prefix := file_parse_filename(trunc, "", context.temp_allocator)
	dirname, fileprefix := file_split_path(real_prefix)
	exec_bits := posix.mode_t{.IXUSR, .IXGRP, .IXOTH}

	if len(dirname) > 0 {
		names, modes := completion_list_files(dirname, context.temp_allocator)
		matches := make([dynamic]Ranked_Match, 0, len(names), context.temp_allocator)
		for i := 0; i < len(names); i += 1 {
			is_dir := posix.S_ISDIR(modes[i])
			is_exec := posix.S_ISREG(modes[i]) && modes[i] & exec_bits != posix.mode_t{}
			if !is_dir && !is_exec {
				continue
			}
			m := ranked_match_make(names[i], fileprefix)
			if m.matches {
				append(&matches, m)
			}
		}
		slice.sort_by(matches[:], ranked_match_less)
		return completion_join_candidates(matches[:], dirname, allocator)
	}

	if completion_command_cache == nil {
		completion_command_cache = make(map[string]Completion_Command_Cache, 8, context.allocator)
	}
	matches := make([dynamic]Ranked_Match, 0, 64, context.temp_allocator)
	rest := os.get_env("PATH", context.temp_allocator)
	for len(rest) > 0 {
		sep := 0
		for sep < len(rest) && rest[sep] != ':' {
			sep += 1
		}
		dir := rest[:sep]
		if sep < len(rest) {
			rest = rest[sep + 1:]
		} else {
			rest = ""
		}
		if len(dir) > 0 && dir[len(dir) - 1] == '/' {
			dir = dir[:len(dir) - 1]
		}
		cname := strings.clone_to_cstring(dir, context.temp_allocator)
		st: posix.stat_t
		if posix.stat(cname, &st) != .OK {
			continue
		}
		if dir not_in completion_command_cache {
			completion_command_cache[strings.clone(dir, context.allocator)] =
				Completion_Command_Cache{}
		}
		entry := &completion_command_cache[dir]
		if entry.mtime != st.st_mtim {
			for c in entry.commands {
				delete(c, context.allocator)
			}
			clear(&entry.commands)
			names, modes := completion_list_files(dir, context.allocator)
			defer delete(names)
			defer delete(modes)
			for i := 0; i < len(names); i += 1 {
				keep :=
					posix.S_ISREG(modes[i]) &&
					modes[i] & exec_bits != posix.mode_t{}
				if keep {
					append(&entry.commands, names[i])
				} else {
					delete(names[i], context.allocator)
				}
			}
			entry.mtime = st.st_mtim
		}
		for c in entry.commands {
			m := ranked_match_make(c, fileprefix)
			if m.matches {
				append(&matches, m)
			}
		}
	}
	slice.sort_by(matches[:], ranked_match_less)
	// C++ std::unique: RankedMatch equality compares candidates only.
	count := 0
	for i := 0; i < len(matches); i += 1 {
		if i == 0 || matches[i].candidate != matches[i - 1].candidate {
			matches[count] = matches[i]
			count += 1
		}
	}
	return completion_join_candidates(matches[:count], "", allocator)
}

// completion_shell_word_range finds the word under cursor_pos and reports
// whether it starts a command (port of the scan in shell_complete).
// Factored out so the scan is testable: shell_complete itself needs the
// unmerged option machinery.
completion_shell_word_range :: proc(
	prefix: string,
	cursor_pos: Units_ByteCount,
) -> (
	word_start, word_end: Units_ByteCount,
	is_command: bool,
) {
	word_start = 0
	word_end = 0
	is_command = true
	pos := 0
	for pos < int(cursor_pos) && pos < len(prefix) {
		is_command =
			pos == 0 ||
			prefix[pos - 1] == ';' ||
			prefix[pos - 1] == '|' ||
			(pos > 1 && prefix[pos - 1] == '&' && prefix[pos - 2] == '&')
		for pos < len(prefix) && unicode_is_horizontal_blank(rune(prefix[pos])) {
			pos += 1
		}
		word_start = Units_ByteCount(pos)
		for pos < len(prefix) && !unicode_is_horizontal_blank(rune(prefix[pos])) {
			pos += 1
		}
		word_end = Units_ByteCount(pos)
	}
	return word_start, word_end, is_command
}

// completion_shell_complete completes the shell word under the cursor as
// a command or filename (port of shell_complete). Returned strings are
// owned. Calls STUBBED option procs; test completion_shell_word_range,
// completion_complete_command, and completion_complete_filename instead.
completion_shell_complete :: proc(
	ctx: ^Context,
	prefix: string,
	cursor_pos: Units_ByteCount,
	allocator := context.allocator,
) -> Completions {
	word_start, word_end, is_command := completion_shell_word_range(prefix, cursor_pos)
	word := completion_substr(prefix, int(word_start), int(word_end))
	rel := cursor_pos - word_start
	completions := Completions{start = word_start, end = word_end}
	if is_command {
		completions.candidates = completion_complete_command(word, rel, allocator)
	} else {
		opts := context_options(ctx)
		opt := option_manager_get_checked(opts, "ignored_files")
		ignored := opt.value.(Regex)
		completions.candidates = completion_complete_filename(
			word,
			&ignored,
			rel,
			{},
			allocator,
		)
	}
	return completions
}

// completion_complete_nothing completes nothing at the cursor (port of
// complete_nothing).
completion_complete_nothing :: proc(
	ctx: ^Context,
	prefix: string,
	cursor_pos: Units_ByteCount,
) -> Completions {
	return Completions{start = cursor_pos, end = cursor_pos}
}

// completion_complete_strings ranks candidates against the query
// truncated to cursor_pos bytes, best match first (C++ complete()
// template in completion.hh; the name is kept from the STUB contract).
// Candidates borrow the caller's strings; free only the returned array.
completion_complete_strings :: proc(
	query: string,
	cursor_pos: Units_ByteCount,
	candidates: []string,
	allocator := context.allocator,
) -> Candidate_List {
	return completion_complete(query, cursor_pos, candidates, allocator)
}

// completion_offset_pos shifts a completion range by offset, keeping its
// candidates and flags (port of offset_pos). The result shares the
// candidates array with the input.
completion_offset_pos :: proc(completion: Completions, offset: Units_ByteCount) -> Completions {
	res := completion
	res.start += offset
	res.end += offset
	return res
}

