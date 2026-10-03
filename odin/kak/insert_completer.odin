// Port of Kakoune's src/insert_completer.hh and src/insert_completer.cc.
//
// InsertCompleter drives insert-mode completion: after every edit it tries
// the configured `completers` option list (filename/option/word/line
// engines), shows the candidates as an inline menu, replaces the completed
// range on selection, and clears everything on accept/reset. Explicit
// (user-triggered) completion pins one engine for the next update.
//
// Mapping notes:
//   * Insert_Completer/Insert_Completion and friends live in knot.odin;
//     this file owns every insert_completer_* proc.
//   * Memory: the completer has no allocator field (knot struct), so ALL
//     owned memory (candidates array, completion/on_select strings, menu
//     atom arrays, inserted ranges, client menu entries) uses
//     context.allocator. reset/destroy free it with the same allocator.
//   * Candidate ownership: completion/on_select are owned clones (empty
//     stays the "" literal and is never freed); menu atom texts are
//     BORROWED (aliases of the owned strings, static pieces, or buffer
//     display names) and never freed. reset() therefore hides the client
//     menu BEFORE freeing candidates; C++ relies on refcounted strings
//     instead, so its order is reversed.
//   * The C++ engines are templates (word<all>, filename<slash>) or a
//     capturing lambda (option); Odin gets one plain proc per
//     instantiation plus shared impls, since plain proc values cannot
//     capture. The six engine procs match Insert_Completer_Complete_Func.
//   * C++ failures (unknown option, bad prefix, bad face) become empty
//     completions; the try_complete catch-all has no Odin equivalent.
//   * Watcher registration is lazy: make() is passed a context but
//     returns the completer BY VALUE (no stable address yet), so the
//     first select/update/try_complete registers {completer, callback}
//     on the options manager. destroy() unregisters when present.
//   * Recorded completion keys iterate by rune; C++ iterates bytes (its
//     signed char-to-Codepoint conversion is unrepresentable here).
//     Identical for ASCII; multibyte replays stay correct.
//   * Menu tabs/padding allocate nothing: tabs expand into runs of static
//     space atoms and overlong names split into "…" + suffix atoms,
//     rendering exactly like the C++ expanded strings.
//   * Nil context/options/faces are tolerated (helpers return empty
//     results); C++ uses references and cannot express this. Real
//     editor flows always pass valid pointers.
package kak

import "core:mem"
import "core:slice"
import "core:strings"

// Insert_Completer_Error is the insert_completer module error enum.
Insert_Completer_Error :: enum {
	None,
	// Invalid_Prefix means an option-completion prefix is not
	// "line.col[+len]@timestamp" (1-based).
	Invalid_Prefix,
}

// Insert_Completer_Option_Prefix is a parsed option-completion prefix
// (C++ complete_option's static regex, full match).
Insert_Completer_Option_Prefix :: struct {
	line:      int, // 0-based
	col:       int, // 0-based byte column
	has_len:   bool,
	len:       Units_ByteCount,
	timestamp: int,
}

@(private)
Insert_Completer_Ranked_Word :: struct {
	match:  Ranked_Match,
	buffer: ^Buffer, // nil for static words
}

@(private)
Insert_Completer_Ranked_Option :: struct {
	match:     Ranked_Match,
	on_select: string, // borrowed from the option list
	menu:      string, // borrowed from the option list
}

// insert_completer_SPACES backs menu tab expansion and padding: runs of
// spaces are sliced from it so no per-candidate string is ever allocated.
@(private)
insert_completer_SPACES := "                                                                " +
	"                                                                "

// insert_completer_make builds a completer for ctx, borrowing the
// long-lived (non-local) scope's options and faces (port of the C++
// constructor; watcher registration stays lazy, see above).
insert_completer_make :: proc(ctx: ^Context) -> Insert_Completer {
	scope := context_scope(ctx, false)
	return Insert_Completer{
		ctx               = ctx,
		options           = &scope.data.options,
		faces             = &scope.data.faces,
		current_candidate = -1,
		enabled           = true,
	}
}

// insert_completer_destroy unregisters the watcher and frees all owned
// memory (port of the C++ destructor). Uses context.allocator.
insert_completer_destroy :: proc(c: ^Insert_Completer) {
	insert_completer_unregister_watcher(c)
	insert_completer_destroy_completion(c)
	delete(c.inserted_ranges)
}

// insert_completer_has_candidate_selected reports whether a real candidate
// (not the trailing original-text entry) is selected.
insert_completer_has_candidate_selected :: proc(c: ^Insert_Completer) -> bool {
	n := len(c.completions.candidates)
	return n > 0 && c.current_candidate >= 0 && c.current_candidate < n - 1
}

// insert_completer_try_accept clears a visible selection (port of
// InsertCompleter::try_accept).
insert_completer_try_accept :: proc(c: ^Insert_Completer) {
	if insert_completer_has_candidate_selected(c) {
		insert_completer_reset(c)
	}
}

// insert_completer_reset clears the completions, hides the menu and runs
// the InsertCompletionHide hook (port of InsertCompleter::reset). The
// menu is hidden BEFORE freeing candidates because client menu atoms
// borrow candidate strings.
insert_completer_reset :: proc(c: ^Insert_Completer) {
	if c.explicit_completer == nil && len(c.completions.candidates) == 0 {
		return
	}
	hook_param := ""
	if c.ctx != nil && context_has_client(c.ctx) && insert_completer_has_candidate_selected(c) {
		buffer := context_buffer(c.ctx)
		insert_completer_update_inserted_ranges(c, buffer)
		c.completions.timestamp = buffer_timestamp(buffer)
		hook_param = insert_completer_hook_param(c, buffer)
	}
	if c.ctx != nil && context_has_client(c.ctx) {
		client := context_client(c.ctx)
		client_menu_hide(client)
		client_info_hide(client)
		hook_manager_run_hook(context_hooks(c.ctx), .Insert_Completion_Hide, hook_param, c.ctx)
	}
	c.explicit_completer = nil
	insert_completer_destroy_completion(c)
	clear(&c.inserted_ranges)
}

// insert_completer_update refreshes the completions after an edit (port of
// InsertCompleter::update): an explicit completer wins for one update,
// otherwise the automatic `completers` list is walked.
insert_completer_update :: proc(c: ^Insert_Completer, allow_implicit: bool) {
	c.enabled = allow_implicit
	insert_completer_ensure_watcher(c)
	if c.explicit_completer != nil {
		if insert_completer_try_complete(c, c.explicit_completer) {
			return
		}
	}
	insert_completer_reset(c)
	insert_completer_setup_ifn(c)
}

// insert_completer_select replaces the completed range in every matching
// selection with candidate index (relative when relative), records the
// equivalent keys through record, and runs the candidate's on_select
// command (port of InsertCompleter::select).
insert_completer_select :: proc(
	c: ^Insert_Completer,
	index: int,
	relative: bool,
	record: input_handler_Record_Key_Apply,
	record_ctx: rawptr,
) {
	c.enabled = true
	insert_completer_ensure_watcher(c)
	if !insert_completer_setup_ifn(c) {
		return
	}
	buffer := context_buffer(c.ctx)
	sels := context_selections(c.ctx)
	n := len(c.completions.candidates)
	c.current_candidate = insert_completer_wrap_index(c.current_candidate, index, relative, n)
	candidate := &c.completions.candidates[c.current_candidate]
	cursor_pos := selection_list_main(sels).cursor.coord
	prefix_len := buffer_distance(buffer, c.completions.begin, cursor_pos)
	suffix_len := buffer_distance(buffer, cursor_pos, c.completions.end)
	if suffix_len < 0 {
		suffix_len = 0
	}
	ref := buffer_string(buffer, c.completions.begin, c.completions.end, context.temp_allocator)
	ranges := make([dynamic]Buffer_Range, 0, len(sels.selections), context.temp_allocator)
	end_coord := buffer_end_coord(buffer)
	for &sel in sels.selections {
		pos := sel.cursor.coord
		if pos.column < prefix_len {
			continue
		}
		begin_c := buffer_advance(buffer, pos, -prefix_len)
		end_c := buffer_advance(buffer, pos, suffix_len)
		if end_c != end_coord {
			at := buffer_string(buffer, begin_c, end_c, context.temp_allocator)
			if at == ref {
				append(&ranges, Buffer_Range{begin_c, end_c})
			}
		}
	}
	// C++ replace() throws on failure, skipping the state update below.
	if insert_completer_replace_ranges(buffer, ranges[:], candidate.completion) != .None {
		return
	}
	selection_list_update(sels)
	c.completions.end = cursor_pos
	c.completions.begin = buffer_advance(buffer, cursor_pos, -Units_ByteCount(len(candidate.completion)))
	c.completions.timestamp = buffer_timestamp(buffer)
	clear(&c.inserted_ranges)
	append(&c.inserted_ranges, ..ranges[:])
	if c.ctx != nil && context_has_client(c.ctx) {
		client_menu_select(context_client(c.ctx), c.current_candidate)
	}
	if record != nil {
		for _ in 0 ..< int(prefix_len) {
			record(record_ctx, Keys_Key{key = keys_BACKSPACE})
		}
		for _ in 0 ..< int(suffix_len) {
			record(record_ctx, Keys_Key{key = keys_DELETE})
		}
		for cp in candidate.completion {
			record(record_ctx, Keys_Key{key = cp})
		}
	}
	if len(candidate.on_select) > 0 {
		shell_ctx := Shell_Context{}
		// C++ lets command errors throw to the input handler; without an
		// error channel here the failure is ignored (message freed).
		exec_err, exec_msg := command_manager_execute(
			command_manager_instance(),
			candidate.on_select,
			c.ctx,
			&shell_ctx,
		)
		if exec_err != .None {
			delete(exec_msg)
		}
	}
}

// insert_completer_explicit_file_complete triggers filename completion
// without requiring a slash (port of explicit_file_complete).
insert_completer_explicit_file_complete :: proc(c: ^Insert_Completer) {
	insert_completer_try_complete(c, insert_completer_complete_filename_any)
	c.explicit_completer = insert_completer_complete_filename_any
}

// insert_completer_explicit_word_buffer_complete triggers word completion
// from the current buffer (port of explicit_word_buffer_complete).
insert_completer_explicit_word_buffer_complete :: proc(c: ^Insert_Completer) {
	insert_completer_try_complete(c, insert_completer_complete_word_buffer)
	c.explicit_completer = insert_completer_complete_word_buffer
}

// insert_completer_explicit_word_all_complete triggers word completion
// from all buffers (port of explicit_word_all_complete).
insert_completer_explicit_word_all_complete :: proc(c: ^Insert_Completer) {
	insert_completer_try_complete(c, insert_completer_complete_word_all)
	c.explicit_completer = insert_completer_complete_word_all
}

// insert_completer_explicit_line_buffer_complete triggers line completion
// from the current buffer (port of explicit_line_buffer_complete).
insert_completer_explicit_line_buffer_complete :: proc(c: ^Insert_Completer) {
	insert_completer_try_complete(c, insert_completer_complete_line_buffer)
	c.explicit_completer = insert_completer_complete_line_buffer
}

// insert_completer_explicit_line_all_complete triggers line completion
// from all buffers (port of explicit_line_all_complete).
insert_completer_explicit_line_all_complete :: proc(c: ^Insert_Completer) {
	insert_completer_try_complete(c, insert_completer_complete_line_all)
	c.explicit_completer = insert_completer_complete_line_all
}

// insert_completer_wrap_index folds index into [0, count), relative to
// current when relative (port of select()'s modulo arithmetic, including
// its single negative adjustment). Returns 0 for count <= 0; C++ would
// divide by zero there.
insert_completer_wrap_index :: proc(current, index: int, relative: bool, count: int) -> int {
	if count <= 0 {
		return 0
	}
	next := index
	if relative {
		next = current + index
	}
	next %= count
	if next < 0 {
		next += count
	}
	return next
}

// insert_completer_scan_word finds the word around byte column col in line
// (port of complete_word's per-selection utf8 scan). is_first_line selects
// the buffer-begin boundary. Returns byte offsets plus the C++ predicate
// check count (backward loop, final re-check, forward loop) for the
// max_word_len gate. col is clamped to the line.
insert_completer_scan_word :: proc(
	line: string,
	col: int,
	is_first_line: bool,
	extra: []rune,
) -> (
	begin_col, end_col: int,
	checked: int,
) {
	column := clamp(col, 0, len(line))
	// Forward scan (C++ skip_while from the cursor; no trailing call).
	// Every predicate call counts, including the failing one.
	epos := column
	for epos < len(line) {
		if !unicode_is_word(utf8_codepoint(line, epos), extra) {
			checked += 1
			break
		}
		checked += 1
		_, epos = string_utils_read_codepoint(line, epos)
	}
	if column == 0 {
		if is_first_line {
			// C++: begin clamps to buffer.begin; the final re-check
			// still runs once.
			return 0, epos, checked + 1
		}
		// C++: two '\n' checks (loop + final), both fail.
		return 0, epos, checked + 2
	}
	bpos := utf8_previous(line, column)
	for bpos >= 0 {
		if bpos == 0 && is_first_line {
			break // C++ stops at buffer.begin without checking.
		}
		if !unicode_is_word(utf8_codepoint(line, bpos), extra) {
			checked += 1
			break
		}
		checked += 1
		if bpos == 0 {
			bpos = -1 // non-first line: continue onto the virtual '\n'
		} else {
			bpos = utf8_previous(line, bpos)
		}
	}
	if bpos < 0 {
		// Only reachable past a non-first line start: stopped on the
		// virtual '\n' (C++ re-checks it, failing, and steps back onto
		// the line start).
		checked += 2
		return 0, epos, checked
	}
	// Final re-check of the stopping char (C++ skip_while_reverse tail).
	checked += 1
	if !unicode_is_word(utf8_codepoint(line, bpos), extra) && bpos < column {
		_, bpos = string_utils_read_codepoint(line, bpos)
	}
	return bpos, epos, checked
}

// insert_completer_push_expanded_atoms appends text to line with tabs
// expanded to static space runs, starting at display column col (renders
// exactly like string_utils_expand_tabs). Returns the end column.
// Allocates only the atoms array, owned by line; atom texts borrow text
// or static spaces. A non-positive tabstop pushes text verbatim.
insert_completer_push_expanded_atoms :: proc(
	line: ^Display_Line,
	text: string,
	face: Face,
	tabstop, col: int,
) -> int {
	c := col
	if tabstop <= 0 {
		if len(text) > 0 {
			display_buffer_line_push_back(line, display_buffer_atom_text(text, face))
		}
		return c
	}
	pos := 0
	start := 0
	for pos < len(text) {
		if text[pos] == '\t' {
			if pos > start {
				display_buffer_line_push_back(line, display_buffer_atom_text(text[start:pos], face))
			}
			end_col := (c / tabstop + 1) * tabstop
			for c < end_col {
				n := min(end_col - c, len(insert_completer_SPACES))
				display_buffer_line_push_back(line, display_buffer_atom_text(insert_completer_SPACES[:n], face))
				c += n
			}
			pos += 1
			start = pos
		} else {
			cp, next := string_utils_read_codepoint(text, pos)
			c += string_utils_codepoint_width(cp)
			pos = next
		}
	}
	if pos > start {
		display_buffer_line_push_back(line, display_buffer_atom_text(text[start:pos], face))
	}
	return c
}

// insert_completer_shorten_display_name limits a menu buffer name to
// max_cols columns (port of complete_word's limit lambda). Returns whether
// to show the "…" marker plus the (possibly column-sliced) suffix,
// borrowing name.
insert_completer_shorten_display_name :: proc(name: string, max_cols: int) -> (ellipsis: bool, suffix: string) {
	if string_utils_column_length(name) <= max_cols {
		return false, name
	}
	// Mirror utf8::advance by columns: consume codepoints while columns
	// remain; a straddling char is kept (stepped back over) unless it
	// reaches the end of the string.
	from := string_utils_column_length(name) - (max_cols + 1)
	pos := 0
	d := from
	for pos < len(name) && d > 0 {
		cp, next := string_utils_read_codepoint(name, pos)
		d -= string_utils_codepoint_width(cp)
		pos = next
		if pos < len(name) && d < 0 {
			pos = utf8_previous(name, pos)
		}
	}
	return true, name[pos:]
}

// insert_completer_parse_option_prefix parses "line.col[+len]@timestamp"
// (1-based, full match; port of complete_option's static regex).
insert_completer_parse_option_prefix :: proc(desc: string) -> (prefix: Insert_Completer_Option_Prefix, err: Insert_Completer_Error) {
	scan := proc(s: string, pos: ^int) -> (int, bool) {
		start := pos^
		for pos^ < len(s) && s[pos^] >= '0' && s[pos^] <= '9' {
			pos^ += 1
		}
		if pos^ == start {
			return 0, false
		}
		return string_utils_str_to_int_ifp(s[start:pos^])
	}
	pos := 0
	line, line_ok := scan(desc, &pos)
	if !line_ok || pos >= len(desc) || desc[pos] != '.' {
		return {}, .Invalid_Prefix
	}
	pos += 1
	col, col_ok := scan(desc, &pos)
	if !col_ok || pos >= len(desc) {
		return {}, .Invalid_Prefix
	}
	if desc[pos] == '+' {
		pos += 1
		n, len_ok := scan(desc, &pos)
		if !len_ok || pos >= len(desc) {
			return {}, .Invalid_Prefix
		}
		prefix.has_len = true
		prefix.len = Units_ByteCount(n)
	}
	if desc[pos] != '@' {
		return {}, .Invalid_Prefix
	}
	pos += 1
	timestamp, ts_ok := scan(desc, &pos)
	if !ts_ok || pos != len(desc) {
		return {}, .Invalid_Prefix
	}
	prefix.line = line - 1
	prefix.col = col - 1
	prefix.timestamp = timestamp
	if prefix.line < 0 || prefix.col < 0 {
		return {}, .Invalid_Prefix
	}
	return prefix, .None
}

@(private)
insert_completer_watcher_of :: proc(c: ^Insert_Completer) -> Option_Watcher {
	return Option_Watcher{data = c, on_option_changed = insert_completer_watcher_callback}
}

// insert_completer_ensure_watcher registers the completer on its options
// manager unless already present (lazy: make() has no stable address).
@(private)
insert_completer_ensure_watcher :: proc(c: ^Insert_Completer) {
	if c.options == nil {
		return
	}
	w := insert_completer_watcher_of(c)
	if !slice.contains(c.options.watchers[:], w) {
		option_manager_register_watcher(c.options, w)
	}
}

@(private)
insert_completer_unregister_watcher :: proc(c: ^Insert_Completer) {
	if c.options == nil {
		return
	}
	w := insert_completer_watcher_of(c)
	if slice.contains(c.options.watchers[:], w) {
		option_manager_unregister_watcher(c.options, w)
	}
}

@(private)
insert_completer_watcher_callback :: proc(data: rawptr, option: rawptr) {
	insert_completer_on_option_changed(cast(^Insert_Completer)data, cast(^Option)option)
}

// insert_completer_on_option_changed refreshes option-driven completions
// when their source option changes (port of on_option_changed).
@(private)
insert_completer_on_option_changed :: proc(c: ^Insert_Completer, opt: ^Option) {
	n := len(c.completions.candidates)
	if n > 0 && c.current_candidate != n - 1 {
		return
	}
	if c.options == nil || opt == nil {
		return
	}
	descs := option_manager_get_checked(c.options, "completers").value.([dynamic]Insert_Completer_Desc)
	for desc in descs {
		if desc.mode == .Option {
			if param, ok := desc.param.?; ok && param == opt.desc.name {
				insert_completer_reset(c)
				insert_completer_setup_ifn(c)
				return
			}
		}
	}
}

// insert_completer_setup_ifn builds completions from the `completers`
// option list unless already valid (port of setup_ifn).
@(private)
insert_completer_setup_ifn :: proc(c: ^Insert_Completer) -> bool {
	if !c.enabled || c.ctx == nil || c.options == nil {
		return false
	}
	if len(c.completions.candidates) == 0 {
		descs := option_manager_get_checked(c.options, "completers").value.([dynamic]Insert_Completer_Desc)
		for desc in descs {
			switch desc.mode {
			case .Filename:
				if insert_completer_try_complete(c, insert_completer_complete_filename_slash) {
					return true
				}
			case .Option:
				if param, ok := desc.param.?; ok {
					if insert_completer_try_complete_option(c, param) {
						return true
					}
				}
			case .Word:
				if param, ok := desc.param.?; ok {
					if param == "buffer" {
						if insert_completer_try_complete(c, insert_completer_complete_word_buffer) {
							return true
						}
					} else if param == "all" {
						if insert_completer_try_complete(c, insert_completer_complete_word_all) {
							return true
						}
					}
				}
			case .Line:
				if param, ok := desc.param.?; ok {
					if param == "buffer" {
						if insert_completer_try_complete(c, insert_completer_complete_line_buffer) {
							return true
						}
					} else if param == "all" {
						if insert_completer_try_complete(c, insert_completer_complete_line_all) {
							return true
						}
					}
				}
			}
		}
		return false
	}
	return true
}

// insert_completer_try_complete resets and runs one engine (port of the
// try_complete template).
@(private)
insert_completer_try_complete :: proc(c: ^Insert_Completer, complete: Insert_Completer_Complete_Func) -> bool {
	if c.ctx == nil || c.options == nil || complete == nil {
		return false
	}
	insert_completer_ensure_watcher(c)
	insert_completer_reset(c)
	sels := context_selections(c.ctx)
	comp := complete(sels, c.options, c.faces, context.allocator)
	return insert_completer_accept(c, sels, comp)
}

// insert_completer_try_complete_option runs the option engine for
// option_name (port of setup_ifn's Option lambda).
@(private)
insert_completer_try_complete_option :: proc(c: ^Insert_Completer, option_name: string) -> bool {
	if c.ctx == nil || c.options == nil {
		return false
	}
	insert_completer_ensure_watcher(c)
	insert_completer_reset(c)
	sels := context_selections(c.ctx)
	comp := insert_completer_complete_option(sels, c.options, c.faces, option_name, context.allocator)
	return insert_completer_accept(c, sels, comp)
}

// insert_completer_accept installs comp (ownership transfers to the
// completer, freed here on rejection), shows the menu and appends the
// original-text entry (port of try_complete's tail).
@(private)
insert_completer_accept :: proc(c: ^Insert_Completer, sels: ^Selection_List, comp: Insert_Completion) -> bool {
	comp := comp
	if c.ctx == nil || sels == nil || len(comp.candidates) == 0 {
		insert_completer_free_candidates(&comp.candidates)
		return false
	}
	buffer := selection_list_buffer(sels)
	assert(coord_compare(comp.begin, selection_list_main(sels).cursor.coord) <= 0)
	c.completions = comp
	c.current_candidate = len(c.completions.candidates)
	insert_completer_menu_show(c)
	original := buffer_string(buffer, c.completions.begin, c.completions.end, context.allocator)
	append(&c.completions.candidates, Insert_Completion_Candidate{completion = original})
	return true
}

// insert_completer_menu_show shows the candidate menu (port of menu_show).
// The entries are shallow clones (owned atoms arrays, borrowed texts)
// owned by the client afterwards.
@(private)
insert_completer_menu_show :: proc(c: ^Insert_Completer) {
	if c.ctx == nil || !context_has_client(c.ctx) {
		return
	}
	entries := make([dynamic]Display_Line, 0, len(c.completions.candidates), context.allocator)
	for cand in c.completions.candidates {
		append(&entries, client_display_line_clone(cand.menu_entry, context.allocator))
	}
	client := context_client(c.ctx)
	client_menu_show(client, entries, c.completions.begin, .Inline)
	client_menu_select(client, c.current_candidate)
	hook_manager_run_hook(context_hooks(c.ctx), .Insert_Completion_Show, "", c.ctx)
}

// insert_completer_free_candidates frees owned candidate memory: the array
// itself, non-empty completion/on_select clones, and menu atom arrays.
// Menu atom texts are borrowed and untouched.
@(private)
insert_completer_free_candidates :: proc(cands: ^[dynamic]Insert_Completion_Candidate) {
	for &cand in cands {
		if len(cand.completion) > 0 {
			delete(cand.completion)
		}
		if len(cand.on_select) > 0 {
			delete(cand.on_select)
		}
		display_buffer_line_destroy(&cand.menu_entry)
	}
	delete(cands^)
	cands^ = nil
}

@(private)
insert_completer_destroy_completion :: proc(c: ^Insert_Completer) {
	insert_completer_free_candidates(&c.completions.candidates)
	c.completions.begin = {}
	c.completions.end = {}
	c.completions.timestamp = 0
}

// insert_completer_clone_owned clones s, normalizing empty to the ""
// literal (which destroy never frees).
@(private)
insert_completer_clone_owned :: proc(s: string, allocator: mem.Allocator) -> string {
	if len(s) == 0 {
		return ""
	}
	return strings.clone(s, allocator)
}

// insert_completer_cursor_line maps cursor to a readable (line, col,
// line_index). The end coord {line_count, 0} reads past the last line's
// end; like the C++ clamp, a column past a trailing newline is pulled
// back onto it.
@(private)
insert_completer_cursor_line :: proc(buffer: ^Buffer, cursor: Coord_Buffer) -> (line: string, col: int, line_index: int) {
	count := int(buffer_line_count(buffer))
	idx := int(cursor.line)
	if idx >= count {
		idx = count - 1
		if idx < 0 {
			return "", 0, 0
		}
		line = buffer_line(buffer, Units_LineCount(idx))
		col = len(line)
	} else {
		line = buffer_line(buffer, Units_LineCount(idx))
		col = min(int(cursor.column), len(line))
	}
	if col == len(line) && col > 0 && line[col - 1] == '\n' {
		col -= 1
	}
	return line, col, idx
}

// insert_completer_replace_ranges replaces every range with content,
// tracking coordinates across edits (port of buffer_utils::replace).
@(private)
insert_completer_replace_ranges :: proc(buffer: ^Buffer, ranges: []Buffer_Range, content: string) -> Buffer_Error {
	tracker := Forward_Changes_Tracker{}
	timestamp := buffer_timestamp(buffer)
	for &r in ranges {
		r.begin = changes_get_new_coord_tolerant(&tracker, r.begin)
		r.end = changes_get_new_coord_tolerant(&tracker, r.end)
		new_range, err := buffer_replace(buffer, r.begin, r.end, content)
		if err != .None {
			return err
		}
		r = new_range
		changes_update_buffer(&tracker, buffer, &timestamp)
	}
	return .None
}

// insert_completer_update_inserted_ranges shifts the inserted ranges to the
// current buffer state (port of reset()'s update_ranges call; the merged
// changes_update_ranges only handles selections, so ranges convert
// through that form and back).
@(private)
insert_completer_update_inserted_ranges :: proc(c: ^Insert_Completer, buffer: ^Buffer) {
	if len(c.inserted_ranges) == 0 {
		return
	}
	tmp := make([dynamic]Selection, 0, len(c.inserted_ranges), context.temp_allocator)
	for r in c.inserted_ranges {
		append(
			&tmp,
			Selection{basic = Basic_Selection{anchor = r.begin, cursor = coord_buffer_and_target(r.end)}},
		)
	}
	changes_update_ranges(buffer, c.completions.timestamp, tmp[:])
	for s, i in tmp {
		c.inserted_ranges[i] = Buffer_Range{s.anchor, s.cursor.coord}
	}
}

// insert_completer_hook_param formats the non-empty inserted ranges for
// the InsertCompletionHide hook (port of reset()'s join). Transient:
// everything lives on the temp allocator for the synchronous hook run.
@(private)
insert_completer_hook_param :: proc(c: ^Insert_Completer, buffer: ^Buffer) -> string {
	parts := make([dynamic]string, 0, len(c.inserted_ranges), context.temp_allocator)
	for r in c.inserted_ranges {
		if range_empty(r) {
			continue
		}
		sel := Selection{
			basic = Basic_Selection{
				anchor = r.begin,
				cursor = coord_buffer_and_target(buffer_char_prev(buffer, r.end)),
			},
		}
		s, err := selection_to_string(.Byte, buffer, sel, -1, context.temp_allocator)
		if err == .None {
			append(&parts, s)
		}
	}
	return string_utils_join_char(parts[:], ' ', true, context.temp_allocator)
}

// insert_completer_complete_word_buffer completes words from the current
// buffer (port of complete_word<false>).
@(private)
insert_completer_complete_word_buffer :: proc(
	sels: ^Selection_List,
	options: ^Option_Manager,
	faces: ^Face_Registry,
	allocator: mem.Allocator,
) -> Insert_Completion {
	return insert_completer_complete_word_impl(sels, options, faces, false, allocator)
}

// insert_completer_complete_word_all completes words from all buffers
// (port of complete_word<true>).
@(private)
insert_completer_complete_word_all :: proc(
	sels: ^Selection_List,
	options: ^Option_Manager,
	faces: ^Face_Registry,
	allocator: mem.Allocator,
) -> Insert_Completion {
	return insert_completer_complete_word_impl(sels, options, faces, true, allocator)
}

// insert_completer_complete_word_impl ranks word_db matches, other-buffer
// matches and static words against the main prefix (port of complete_word).
// allocator must be context.allocator (freed by destroy); matches and
// counts are transient (temp allocator), candidate strings are cloned.
@(private)
insert_completer_complete_word_impl :: proc(
	sels: ^Selection_List,
	options: ^Option_Manager,
	faces: ^Face_Registry,
	other_buffers: bool,
	allocator: mem.Allocator,
) -> Insert_Completion {
	assert(allocator == context.allocator)
	extra := option_manager_get_checked(options, "extra_word_chars").value.([dynamic]rune)
	buffer := selection_list_buffer(sels)
	main := selection_list_main(sels).cursor.coord
	main_line, main_col, main_idx := insert_completer_cursor_line(buffer, main)
	if main_idx == 0 && main_col == 0 {
		return {}
	}
	if main_col == 0 ||
	   !unicode_is_word(utf8_codepoint(main_line, utf8_previous(main_line, main_col)), extra[:]) {
		return {}
	}
	counts := make(map[string]int, len(sels.selections), context.temp_allocator)
	word_begin_col := 0
	prefix := ""
	main_index := selection_list_main_index(sels)
	for sel, i in sels.selections {
		line, col, idx := insert_completer_cursor_line(buffer, sel.cursor.coord)
		bcol, ecol, checked := insert_completer_scan_word(line, col, idx == 0, extra[:])
		if i == main_index {
			word_begin_col = bcol
			prefix = line[bcol:col]
		}
		if checked <= word_splitter_MAX_WORD_LEN {
			word := line[bcol:ecol]
			counts[word] = counts[word] + 1
		}
	}
	matches := make([dynamic]Insert_Completer_Ranked_Word, 0, 16, context.temp_allocator)
	db := word_db_get(buffer)
	found := word_db_find_matching(db, prefix, context.allocator)
	defer delete(found)
	for m in found {
		append(&matches, Insert_Completer_Ranked_Word{match = m, buffer = buffer})
	}
	// Remove words that are being edited.
	for word, count in counts {
		occ := 0
		if info, ok := db.words[word]; ok {
			occ = info.refcount
		}
		if occ <= count {
			insert_completer_erase_candidate(&matches, word)
		}
	}
	if other_buffers {
		for buf in buffer_manager_instance().buffers {
			if buf == buffer || .Debug in buffer_flags(buf) {
				continue
			}
			buf_found := word_db_find_matching(word_db_get(buf), prefix, context.allocator)
			for m in buf_found {
				// Filter out words that are not words for this buffer.
				if insert_completer_is_word_string(m.candidate, extra[:]) {
					append(&matches, Insert_Completer_Ranked_Word{match = m, buffer = buf})
				}
			}
			delete(buf_found)
		}
	}
	for w in option_manager_get_checked(options, "static_words").value.([dynamic]string) {
		m := ranked_match_make(w, prefix)
		if m.matches {
			append(&matches, Insert_Completer_Ranked_Word{match = m})
		}
	}
	insert_completer_erase_candidate(&matches, prefix)
	longest := 0
	for m in matches {
		longest = max(longest, utf8_distance(m.match.candidate))
	}
	menu_face := Face{}
	if faces != nil {
		// MenuInfo is a builtin face; fall back to default when missing.
		if face, ferr := face_registry_lookup(faces, "MenuInfo", context.temp_allocator); ferr == .None {
			menu_face = face
		}
	}
	cands := make([dynamic]Insert_Completion_Candidate, 0, min(len(matches), 100) + 1, allocator)
	// Explicit best-first loop: plain proc values cannot capture the
	// candidates array, so ranges_for_n_best is unusable (same reason as
	// input_handler's prompt Words completion).
	visited := make([dynamic]bool, len(matches), context.temp_allocator)
	remaining := 100
	for remaining > 0 {
		best := -1
		for m, i in matches {
			if visited[i] {
				continue
			}
			if best == -1 || ranked_match_less(m.match, matches[best].match) {
				best = i
			}
		}
		if best == -1 {
			break
		}
		visited[best] = true
		m := matches[best]
		if len(cands) > 0 && cands[len(cands) - 1].completion == m.match.candidate {
			continue
		}
		completion := insert_completer_clone_owned(m.match.candidate, allocator)
		entry := display_buffer_line_make(allocator)
		display_buffer_line_push_back(&entry, display_buffer_atom_text(completion, Face{}))
		if other_buffers && m.buffer != nil {
			pad := longest + 1 - utf8_distance(m.match.candidate)
			for _ in 0 ..< pad {
				display_buffer_line_push_back(&entry, display_buffer_atom_text(" ", Face{}))
			}
			ellipsis, short := insert_completer_shorten_display_name(
				buffer_display_name(m.buffer),
				20,
			)
			if ellipsis {
				display_buffer_line_push_back(&entry, display_buffer_atom_text("…", menu_face))
			}
			display_buffer_line_push_back(&entry, display_buffer_atom_text(short, menu_face))
		}
		append(&cands, Insert_Completion_Candidate{completion = completion, menu_entry = entry})
		remaining -= 1
	}
	word_begin := Coord_Buffer{Units_LineCount(main_idx), Units_ByteCount(word_begin_col)}
	return Insert_Completion{
		candidates = cands,
		begin      = word_begin,
		end        = main,
		timestamp  = buffer_timestamp(buffer),
	}
}

// insert_completer_erase_candidate drops the first match for word (port of
// unordered_erase over matches).
@(private)
insert_completer_erase_candidate :: proc(matches: ^[dynamic]Insert_Completer_Ranked_Word, word: string) {
	for m, i in matches {
		if m.match.candidate == word {
			matches[i] = matches[len(matches) - 1]
			pop(matches)
			return
		}
	}
}

// insert_completer_is_word_string reports whether every codepoint of s is
// a word char (port of complete_word's filter over other-buffer matches).
@(private)
insert_completer_is_word_string :: proc(s: string, extra: []rune) -> bool {
	pos := 0
	for pos < len(s) {
		cp, next := string_utils_read_codepoint(s, pos)
		if !unicode_is_word(cp, extra) {
			return false
		}
		pos = next
	}
	return true
}

// insert_completer_complete_filename_slash completes filenames, requiring a
// slash in the prefix (port of complete_filename<true>, the implicit one).
@(private)
insert_completer_complete_filename_slash :: proc(
	sels: ^Selection_List,
	options: ^Option_Manager,
	faces: ^Face_Registry,
	allocator: mem.Allocator,
) -> Insert_Completion {
	return insert_completer_complete_filename_impl(sels, options, true, allocator)
}

// insert_completer_complete_filename_any completes filenames with no slash
// requirement (port of complete_filename<false>, the explicit one).
@(private)
insert_completer_complete_filename_any :: proc(
	sels: ^Selection_List,
	options: ^Option_Manager,
	faces: ^Face_Registry,
	allocator: mem.Allocator,
) -> Insert_Completion {
	return insert_completer_complete_filename_impl(sels, options, false, allocator)
}

// insert_completer_is_filename_byte reports whether b continues a filename
// (port of complete_filename's is_filename lambda).
@(private)
insert_completer_is_filename_byte :: proc(b: byte) -> bool {
	return b >= 'a' && b <= 'z' ||
		b >= 'A' && b <= 'Z' ||
		b >= '0' && b <= '9' ||
		b == '/' ||
		b == '.' ||
		b == '_' ||
		b == '-'
}

// insert_completer_complete_filename_impl completes the filename around
// the main cursor (port of complete_filename). allocator must be
// context.allocator (freed by destroy).
@(private)
insert_completer_complete_filename_impl :: proc(
	sels: ^Selection_List,
	options: ^Option_Manager,
	require_slash: bool,
	allocator: mem.Allocator,
) -> Insert_Completion {
	assert(allocator == context.allocator)
	buffer := selection_list_buffer(sels)
	cursor := selection_list_main(sels).cursor.coord
	line, col, _ := insert_completer_cursor_line(buffer, cursor)
	bcol := col
	for bcol > 0 && insert_completer_is_filename_byte(line[bcol - 1]) {
		bcol -= 1
	}
	if bcol > 0 && bcol < len(line) && line[bcol] == '/' && line[bcol - 1] == '~' {
		bcol -= 1
	}
	prefix := line[bcol:col]
	if require_slash && !strings.contains(prefix, "/") {
		return {}
	}
	if len(prefix) >= 2 && prefix[:2] == "//" {
		return {}
	}
	// Local Regex copy, mirroring input_handler's filename completion.
	ignored := option_manager_get_checked(options, "ignored_files").value.(Regex)
	cands := make([dynamic]Insert_Completion_Candidate, 0, 8, allocator)
	if len(prefix) > 0 && (prefix[0] == '/' || prefix[0] == '~') {
		found := completion_complete_filename(prefix, &ignored, -1, Filename_Flags{}, allocator)
		defer delete(found)
		for f in found {
			entry := display_buffer_line_make_text(f, Face{}, allocator)
			append(&cands, Insert_Completion_Candidate{completion = f, menu_entry = entry})
		}
	} else {
		paths := option_manager_get_checked(options, "path").value.([dynamic]string)
		bufdir := ""
		if .File in buffer_flags(buffer) {
			dir, _ := file_split_path(buffer_filename(buffer))
			bufdir = dir
		}
		visited := make(map[string]bool, len(paths), context.temp_allocator)
		for d in paths {
			parsed := file_parse_filename(d, bufdir, context.temp_allocator)
			real, rerr := file_real_path(parsed, context.temp_allocator)
			if rerr != .None {
				real = ""
			}
			if len(real) > 0 && real[len(real) - 1] != '/' {
				real = strings.concatenate({real, "/"}, context.temp_allocator)
			}
			if real in visited {
				continue
			}
			visited[real] = true
			target := strings.concatenate({real, prefix}, context.temp_allocator)
			found := completion_complete_filename(target, &ignored, -1, Filename_Flags{}, allocator)
			for f in found {
				completion := insert_completer_clone_owned(f[len(real):], allocator)
				delete(f)
				entry := display_buffer_line_make_text(completion, Face{}, allocator)
				append(&cands, Insert_Completion_Candidate{completion = completion, menu_entry = entry})
			}
			delete(found)
		}
	}
	begin := Coord_Buffer{cursor.line, Units_ByteCount(bcol)}
	return Insert_Completion{
		candidates = cands,
		begin      = begin,
		end        = cursor,
		timestamp  = buffer_timestamp(buffer),
	}
}

// insert_completer_complete_option completes from a completions option
// value (port of complete_option). allocator must be context.allocator
// (freed by destroy).
@(private)
insert_completer_complete_option :: proc(
	sels: ^Selection_List,
	options: ^Option_Manager,
	faces: ^Face_Registry,
	option_name: string,
	allocator: mem.Allocator,
) -> Insert_Completion {
	assert(allocator == context.allocator)
	buffer := selection_list_buffer(sels)
	cursor := selection_list_main(sels).cursor.coord
	opt, oerr := option_manager_get_option(options, option_name)
	if oerr != .None {
		return {}
	}
	list, ok := option_manager_option_get(opt).(Insert_Completer_Completion_List)
	if !ok || len(list.list) == 0 {
		return {}
	}
	parsed, perr := insert_completer_parse_option_prefix(list.prefix)
	if perr != .None {
		return {}
	}
	coord := Coord_Buffer{Units_LineCount(parsed.line), Units_ByteCount(parsed.col)}
	if !buffer_is_valid(buffer, coord) {
		return {}
	}
	if parsed.timestamp > buffer_timestamp(buffer) {
		// Defensive: C++ changes_since would assert or overrun.
		return {}
	}
	for ch in buffer_changes_since(buffer, parsed.timestamp) {
		if coord_compare(ch.begin, coord) < 0 {
			return {}
		}
	}
	if cursor.line != coord.line || cursor.column < coord.column {
		return {}
	}
	if int(coord.line) >= int(buffer_line_count(buffer)) {
		// End coord: C++ substr would run past the lines.
		return {}
	}
	tabstop := option_manager_get_checked(options, "tabstop").value.(int)
	column := int(buffer_utils_get_column(buffer, Coord_Column(tabstop), cursor))
	line_text := buffer_line(buffer, coord.line)
	query := line_text[int(coord.column):min(int(cursor.column), len(line_text))]
	matches := make([dynamic]Insert_Completer_Ranked_Option, 0, len(list.list), context.temp_allocator)
	for cand, i in list.list {
		m := ranked_match_make(cand.completion, query)
		if m.matches {
			ranked_match_set_input_sequence_number(&m, uint(i))
			append(
				&matches,
				Insert_Completer_Ranked_Option{match = m, on_select = cand.on_select, menu = cand.menu_entry},
			)
		}
	}
	cands := make([dynamic]Insert_Completion_Candidate, 0, min(len(matches), 100) + 1, allocator)
	visited := make([dynamic]bool, len(matches), context.temp_allocator)
	remaining := 100
	for remaining > 0 {
		best := -1
		for m, i in matches {
			if visited[i] {
				continue
			}
			if best == -1 || ranked_match_less(m.match, matches[best].match) {
				best = i
			}
		}
		if best == -1 {
			break
		}
		visited[best] = true
		m := matches[best]
		if len(cands) > 0 {
			back := &cands[len(cands) - 1]
			if back.completion == m.match.candidate && back.on_select == m.on_select {
				continue
			}
		}
		completion := insert_completer_clone_owned(m.match.candidate, allocator)
		on_select := insert_completer_clone_owned(m.on_select, allocator)
		entry := display_buffer_line_make(allocator)
		if len(m.menu) > 0 {
			if faces == nil {
				insert_completer_push_expanded_atoms(&entry, m.menu, Face{}, tabstop, column)
			} else {
				parsed_menu, merr := display_buffer_parse_line(m.menu, faces, nil, allocator)
				if merr != .None {
					// C++ parse failure throws, failing the completion.
					display_buffer_line_destroy(&entry)
					if len(completion) > 0 {
						delete(completion)
					}
					if len(on_select) > 0 {
						delete(on_select)
					}
					insert_completer_free_candidates(&cands)
					return {}
				}
				col := column
				for a in parsed_menu.atoms {
					if a.type == .Text {
						col = insert_completer_push_expanded_atoms(
							&entry,
							a.text,
							a.face,
							tabstop,
							col,
						)
					} else {
						display_buffer_line_push_back(&entry, a)
					}
				}
				delete(parsed_menu.atoms)
			}
		}
		append(
			&cands,
			Insert_Completion_Candidate{completion = completion, on_select = on_select, menu_entry = entry},
		)
		remaining -= 1
	}
	end := cursor
	if parsed.has_len {
		end = buffer_advance(buffer, coord, parsed.len)
	}
	return Insert_Completion{
		candidates = cands,
		begin      = coord,
		end        = end,
		timestamp  = parsed.timestamp,
	}
}

// insert_completer_complete_line_buffer completes lines from the current
// buffer (port of complete_line<false>).
@(private)
insert_completer_complete_line_buffer :: proc(
	sels: ^Selection_List,
	options: ^Option_Manager,
	faces: ^Face_Registry,
	allocator: mem.Allocator,
) -> Insert_Completion {
	return insert_completer_complete_line_impl(sels, options, false, allocator)
}

// insert_completer_complete_line_all completes lines from all buffers
// (port of complete_line<true>).
@(private)
insert_completer_complete_line_all :: proc(
	sels: ^Selection_List,
	options: ^Option_Manager,
	faces: ^Face_Registry,
	allocator: mem.Allocator,
) -> Insert_Completion {
	return insert_completer_complete_line_impl(sels, options, true, allocator)
}

// insert_completer_trim_leading_blanks strips leading horizontal blanks
// (port of complete_line's trim lambda).
@(private)
insert_completer_trim_leading_blanks :: proc(s: string) -> string {
	pos := 0
	for pos < len(s) {
		cp, next := string_utils_read_codepoint(s, pos)
		if !unicode_is_horizontal_blank(cp) {
			break
		}
		pos = next
	}
	return s[pos:]
}

// insert_completer_complete_line_impl completes whole lines matching the
// main prefix (port of complete_line). allocator must be context.allocator
// (freed by destroy).
@(private)
insert_completer_complete_line_impl :: proc(
	sels: ^Selection_List,
	options: ^Option_Manager,
	other_buffers: bool,
	allocator: mem.Allocator,
) -> Insert_Completion {
	assert(allocator == context.allocator)
	buffer := selection_list_buffer(sels)
	cursor := selection_list_main(sels).cursor.coord
	tabstop := option_manager_get_checked(options, "tabstop").value.(int)
	column := int(buffer_utils_get_column(buffer, Coord_Column(tabstop), cursor))
	line, col, _ := insert_completer_cursor_line(buffer, cursor)
	prefix := insert_completer_trim_leading_blanks(line[:col])
	replace_begin := buffer_advance(buffer, cursor, -Units_ByteCount(len(prefix)))
	cands := make([dynamic]Insert_Completion_Candidate, 0, 32, allocator)
	insert_completer_collect_line_candidates(
		buffer,
		int(cursor.line),
		true,
		prefix,
		tabstop,
		column,
		&cands,
		allocator,
	)
	if other_buffers {
		for buf in buffer_manager_instance().buffers {
			if buf != buffer && .Debug not_in buffer_flags(buf) {
				insert_completer_collect_line_candidates(
					buf,
					0,
					false,
					prefix,
					tabstop,
					column,
					&cands,
					allocator,
				)
			}
		}
	}
	if len(cands) == 0 {
		delete(cands)
		return {}
	}
	slice.sort_by(cands[:], proc(a, b: Insert_Completion_Candidate) -> bool {
		return a.completion < b.completion
	})
	// len > 0: dedup adjacent equal completions (port of sort+unique).
	kept := 1
	for i := 1; i < len(cands); i += 1 {
		if cands[i].completion != cands[kept - 1].completion {
			cands[kept] = cands[i]
			kept += 1
		} else {
			// Same completion and menu: drop the duplicate's owned data.
			if len(cands[i].completion) > 0 {
				delete(cands[i].completion)
			}
			display_buffer_line_destroy(&cands[i].menu_entry)
		}
	}
	resize(&cands, kept)
	return Insert_Completion{
		candidates = cands,
		begin      = replace_begin,
		end        = cursor,
		timestamp  = buffer_timestamp(buffer),
	}
}

// insert_completer_collect_line_candidates appends prefix-matching lines
// of buf (port of complete_line's add_candidates lambda). The 100 cap
// checks the shared size, like the C++ (so it only bites once).
@(private)
insert_completer_collect_line_candidates :: proc(
	buf: ^Buffer,
	skip_line: int,
	has_skip: bool,
	prefix: string,
	tabstop, column: int,
	cands: ^[dynamic]Insert_Completion_Candidate,
	allocator: mem.Allocator,
) {
	count := int(buffer_line_count(buf))
	for l := 0; l < count; l += 1 {
		if has_skip && l == skip_line {
			continue
		}
		text := buffer_line(buf, Units_LineCount(l))
		if len(text) > 0 && text[len(text) - 1] == '\n' {
			text = text[:len(text) - 1]
		}
		candidate := insert_completer_trim_leading_blanks(text)
		if len(candidate) == 0 {
			continue
		}
		if !strings.has_prefix(candidate, prefix) {
			continue
		}
		completion := insert_completer_clone_owned(candidate, allocator)
		entry := display_buffer_line_make(allocator)
		insert_completer_push_expanded_atoms(&entry, completion, Face{}, tabstop, column)
		append(cands, Insert_Completion_Candidate{completion = completion, menu_entry = entry})
		if len(cands^) == 100 {
			break
		}
	}
}
