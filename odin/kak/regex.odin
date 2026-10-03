// Regex wrapper ported from src/regex.{hh,cc}: a compiled pattern that
// keeps its string form, match results, and match/search helpers.
//
// Positions are byte offsets into the subject string (the C++ uses
// iterators; offsets are the equivalent here, matching the merged utf8
// module's conventions).
//
// Ownership: regex_make returns an owned Regex in `allocator` (release
// with regex_destroy, same allocator). On failure it returns an owned
// error message string instead (delete it); the regex is zero and must
// not be destroyed. Match/search procs return owned Regex_Match_Results
// (release with regex_match_results_destroy); the Regex_Iterator owns a
// VM plus results (release with regex_iterator_destroy). Subjects are
// always borrowed.
//
// option_to_string/option_from_string for Regex are not ported: they need
// the option/quoting machinery, which no merged module provides yet.
package kak

import "core:mem"
import "core:strings"

// Regex_Error reports Regex construction failures. Zero value None is
// success; detail is carried by the message string returned next to it.
Regex_Error :: enum {
	None,
	Compile_Error,
}

// Regex is a compiled pattern that keeps its string form (C++ Regex).
Regex :: struct {
	pattern:   string,
	compiled:  Regex_Vm_Compiled,
	allocator: mem.Allocator,
}

// regex_make compiles pattern with flags (C++ Regex::Regex).
// On success the caller owns the regex; on failure the caller owns the
// error message and the regex is zero.
regex_make :: proc(
	pattern: string,
	flags: Regex_Vm_Compile_Flags = {},
	allocator := context.allocator,
) -> (
	re: Regex,
	err_msg: string,
	err: Regex_Error,
) {
	prog, msg, vm_err := regex_vm_compile(pattern, flags, allocator)
	if vm_err != .None {
		return {}, msg, .Compile_Error
	}
	return Regex{
			pattern = strings.clone(pattern, allocator),
			compiled = prog,
			allocator = allocator,
		},
		"", .None
}

// regex_destroy releases all memory owned by re.
regex_destroy :: proc(re: ^Regex) {
	delete(re.pattern, re.allocator)
	regex_vm_compiled_destroy(&re.compiled)
	re^ = {}
}

// regex_empty reports whether the pattern string is empty (C++ Regex::empty).
regex_empty :: proc(re: ^Regex) -> bool {
	return len(re.pattern) == 0
}

// regex_str returns the borrowed pattern string (C++ Regex::str).
regex_str :: proc(re: ^Regex) -> string {
	return re.pattern
}

// regex_mark_count returns the number of capture groups, excluding group 0
// (C++ Regex::mark_count).
regex_mark_count :: proc(re: ^Regex) -> int {
	return re.compiled.save_count / 2 - 1
}

// regex_named_capture_index returns the group index of the (?<name>...)
// group, or -1 when there is none (C++ Regex::named_capture_index).
regex_named_capture_index :: proc(re: ^Regex, name: string) -> int {
	for nc in re.compiled.named_captures {
		if nc.name == name {
			return nc.index
		}
	}
	return -1
}

// regex_impl returns the borrowed compiled program (C++ Regex::impl).
regex_impl :: proc(re: ^Regex) -> ^Regex_Vm_Compiled {
	return &re.compiled
}

// Regex_Sub_Match is one capture group: byte offsets plus whether the
// group participated in the match (C++ MatchResults::SubMatch).
Regex_Sub_Match :: struct {
	begin:   int,
	end:     int,
	matched: bool,
}

// Regex_Match_Results holds save pairs (begin/end byte offsets, -1 when
// unmatched) for group 0 and each capture group (C++ MatchResults).
Regex_Match_Results :: struct {
	values:    [dynamic]int,
	allocator: mem.Allocator,
}

// regex_match_results_make creates an empty results vector.
regex_match_results_make :: proc(allocator := context.allocator) -> Regex_Match_Results {
	return Regex_Match_Results{
		values = make([dynamic]int, 0, allocator),
		allocator = allocator,
	}
}

// regex_match_results_destroy releases results.
regex_match_results_destroy :: proc(res: ^Regex_Match_Results) {
	delete(res.values)
	res^ = {}
}

// regex_match_results_size returns the group count (C++ MatchResults::size).
regex_match_results_size :: proc(res: ^Regex_Match_Results) -> int {
	return len(res.values) / 2
}

// regex_match_results_empty reports whether there are no groups.
regex_match_results_empty :: proc(res: ^Regex_Match_Results) -> bool {
	return len(res.values) == 0
}

// regex_match_results_get returns group i, or an unmatched sub-match when
// i is out of range (C++ MatchResults::operator[]).
regex_match_results_get :: proc(res: ^Regex_Match_Results, i: int) -> Regex_Sub_Match {
	if i < 0 || i * 2 + 1 >= len(res.values) {
		return {}
	}
	begin := res.values[i * 2]
	end := res.values[i * 2 + 1]
	return {begin, end, begin >= 0}
}

// regex_match_results_substring returns the borrowed text of group i,
// or "" when the group is unmatched or out of range.
regex_match_results_substring :: proc(res: ^Regex_Match_Results, subject: string, i: int) -> string {
	m := regex_match_results_get(res, i)
	if !m.matched {
		return ""
	}
	return subject[m.begin:m.end]
}

@(private = "file")
regex_copy_captures :: proc(
	vm: ^Regex_Vm,
	allocator: mem.Allocator,
) -> Regex_Match_Results {
	caps := regex_vm_captures(vm)
	res := Regex_Match_Results{
		values = make([dynamic]int, len(caps), allocator),
		allocator = allocator,
	}
	copy(res.values[:], caps)
	return res
}

// regex_match_flags builds exec flags from boundary conditions
// (C++ match_flags).
regex_match_flags :: proc(bol, eol, bow, eow: bool) -> Regex_Vm_Exec_Flags {
	flags := Regex_Vm_Exec_Flags{}
	if !bol {
		flags += {.Not_Begin_Of_Line}
	}
	if !eol {
		flags += {.Not_End_Of_Line}
	}
	if !bow {
		flags += {.Not_Begin_Of_Word}
	}
	if !eow {
		flags += {.Not_End_Of_Word}
	}
	return flags
}

// regex_match matches the whole subject against re (C++ regex_match with
// results). The caller owns the returned results.
regex_match :: proc(
	subject: string,
	re: ^Regex,
	allocator := context.allocator,
) -> (
	res: Regex_Match_Results,
	matched: bool,
) {
	vm := regex_vm_make(&re.compiled, {.Forward}, context.temp_allocator)
	defer regex_vm_destroy(&vm)
	if regex_vm_exec(&vm, subject, 0, len(subject), 0, len(subject), {}) {
		return regex_copy_captures(&vm, allocator), true
	}
	return regex_match_results_make(allocator), false
}

// regex_match_simple reports whether the whole subject matches re,
// without captures (C++ regex_match without results).
regex_match_simple :: proc(subject: string, re: ^Regex) -> bool {
	vm := regex_vm_make(&re.compiled, {.Forward, .Any_Match, .No_Saves}, context.temp_allocator)
	defer regex_vm_destroy(&vm)
	return regex_vm_exec(&vm, subject, 0, len(subject), 0, len(subject), {})
}

// regex_search searches [begin, end) of subject for re (C++ regex_search
// with results). The caller owns the returned results.
regex_search :: proc(
	subject: string,
	begin, end: int,
	re: ^Regex,
	flags: Regex_Vm_Exec_Flags = {},
	allocator := context.allocator,
) -> (
	res: Regex_Match_Results,
	matched: bool,
) {
	vm := regex_vm_make(&re.compiled, {.Forward, .Search}, context.temp_allocator)
	defer regex_vm_destroy(&vm)
	if regex_vm_exec(&vm, subject, begin, end, 0, len(subject), flags) {
		return regex_copy_captures(&vm, allocator), true
	}
	return regex_match_results_make(allocator), false
}

// regex_search_simple reports whether re matches anywhere in [begin, end)
// of subject, without captures (C++ regex_search without results).
regex_search_simple :: proc(
	subject: string,
	begin, end: int,
	re: ^Regex,
	flags: Regex_Vm_Exec_Flags = {},
) -> bool {
	vm := regex_vm_make(&re.compiled, {.Forward, .Search, .Any_Match, .No_Saves}, context.temp_allocator)
	defer regex_vm_destroy(&vm)
	return regex_vm_exec(&vm, subject, begin, end, 0, len(subject), flags)
}

// regex_backward_search searches [begin, end) of subject backwards for re:
// it finds the match ending last (C++ backward_regex_search). The regex
// must have been compiled with .Backward. The caller owns the results.
regex_backward_search :: proc(
	subject: string,
	begin, end: int,
	re: ^Regex,
	flags: Regex_Vm_Exec_Flags = {},
	allocator := context.allocator,
) -> (
	res: Regex_Match_Results,
	matched: bool,
) {
	vm := regex_vm_make(&re.compiled, {.Backward, .Search}, context.temp_allocator)
	defer regex_vm_destroy(&vm)
	if regex_vm_exec(&vm, subject, begin, end, 0, len(subject), flags) {
		return regex_copy_captures(&vm, allocator), true
	}
	return regex_match_results_make(allocator), false
}

// Regex_Iterator iterates the successive matches of re over [begin, end)
// of subject (C++ RegexIterator). It borrows the subject and the regex.
Regex_Iterator :: struct {
	vm:        Regex_Vm,
	results:   Regex_Match_Results,
	subject:   string,
	next_pos:  int,
	begin:     int,
	end:       int,
	flags:     Regex_Vm_Exec_Flags,
	backward:  bool,
	allocator: mem.Allocator,
}

// regex_iterator_make creates a match iterator; backward selects backward
// search (the regex must have been compiled with .Backward then).
regex_iterator_make :: proc(
	subject: string,
	begin, end: int,
	re: ^Regex,
	flags: Regex_Vm_Exec_Flags = {},
	backward := false,
	allocator := context.allocator,
) -> Regex_Iterator {
	mode := Regex_Vm_Modes{.Forward, .Search}
	next_pos := begin
	if backward {
		mode = {.Backward, .Search}
		next_pos = end
	}
	return Regex_Iterator{
		vm = regex_vm_make(&re.compiled, mode, allocator),
		results = regex_match_results_make(allocator),
		subject = subject,
		next_pos = next_pos,
		begin = begin,
		end = end,
		flags = flags,
		backward = backward,
		allocator = allocator,
	}
}

// regex_iterator_destroy releases the iterator's VM and results.
regex_iterator_destroy :: proc(it: ^Regex_Iterator) {
	regex_match_results_destroy(&it.results)
	regex_vm_destroy(&it.vm)
	it^ = {}
}

// regex_iterator_next advances to the next match, reporting whether one
// was found. The match is available as it.results.
regex_iterator_next :: proc(it: ^Regex_Iterator) -> bool {
	additional := Regex_Vm_Exec_Flags{}
	if regex_match_results_size(&it.results) > 0 {
		whole := regex_match_results_get(&it.results, 0)
		if whole.begin == whole.end {
			additional += {.Not_Initial_Null}
		}
	}
	found := false
	if it.backward {
		found = regex_vm_exec(
			&it.vm,
			it.subject,
			it.begin,
			it.next_pos,
			0,
			len(it.subject),
			it.flags + additional,
		)
	} else {
		found = regex_vm_exec(
			&it.vm,
			it.subject,
			it.next_pos,
			it.end,
			0,
			len(it.subject),
			it.flags + additional,
		)
	}
	if !found {
		return false
	}
	caps := regex_vm_captures(&it.vm)
	clear(&it.results.values)
	append(&it.results.values, ..caps)
	whole := regex_match_results_get(&it.results, 0)
	if it.backward {
		it.next_pos = whole.begin
		assert(it.next_pos >= it.begin)
	} else {
		it.next_pos = whole.end
		assert(it.next_pos <= it.end)
	}
	return true
}
