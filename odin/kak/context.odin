// Port of Kakoune's src/context.hh and src/context.cc: Context, JumpList,
// the selection undo history, and the scoped-edition guards.
//
// Mapping notes:
//   * C++ runtime_error throws become Context_Error returns (None == ok,
//     zero value). See context_error_message for the C++ throw texts.
//   * Context is non-copyable in C++ (selection_history.ctx self-links and
//     the struct owns heap arrays); here it is initialized in caller-owned
//     storage with context_init/context_init_empty and torn down with
//     context_destroy. Never copy a Context after init.
//   * C++ SelectionHistory::HistoryNode holds a SelectionList (which borrows
//     its Buffer); the knot node mirrors it with a list field plus the
//     parent/redo_child links.
//   * C++ Context accessors (buffer/window/client/input_handler/selections)
//     throw only when the context is malformed; every real caller either
//     guarantees the member or checks has_* first, so the ports are
//     infallible and assert the invariant instead. Genuinely reachable
//     failures (selection undo/redo limits, jump limits, missing
//     registers) keep Context_Error returns.
//   * Buffer::timestamp(), line_count(), end_coord() and operator[] are
//     one-line inlines in buffer.inl.hh/buffer.hh; they are read directly
//     off knot Buffer fields (len(changes), len(lines)) at each use site.
//     Every other cross-module call is an exact STUB one-liner (see the
//     stubs section at the end of this file).
//   * Strings owned by the context (name, cloned selection captures) are
//     deep copies made with the context allocator and freed by
//     context_destroy. Jump-list entries carry their own allocator
//     (Selection_List.allocator); dynamic arrays remember theirs, so the
//     destroy procs take no allocator.
//
// Ownership: the caller owns the Context storage (usually embedded in an
// Input_Handler); context_destroy frees everything the context owns.
package kak

import "core:mem"
import "core:strings"

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

// Context_Error reports every failure the C++ context code signals by
// throwing runtime_error. Zero value None is success.
Context_Error :: enum {
	None,
	No_Buffer,
	No_Window,
	No_Client,
	No_Input_Handler,
	No_Selections,
	No_Next_Jump,
	No_Previous_Jump,
	Selection_Undo_In_Edition,
	No_Selection_Undo,
	No_Selection_Redo,
	No_Such_Register,
	Buffer_Locked,
}

// context_error_message returns the C++ throw text for an error.
context_error_message :: proc(err: Context_Error) -> string {
	switch err {
	case .None:
		return ""
	case .No_Buffer:
		return "no buffer in context"
	case .No_Window:
		return "no window in context"
	case .No_Client:
		return "no client in context"
	case .No_Input_Handler:
		return "no input handler in context"
	case .No_Selections:
		return "no selections in context"
	case .No_Next_Jump:
		return "no next jump"
	case .No_Previous_Jump:
		return "no previous jump"
	case .Selection_Undo_In_Edition:
		return "selection undo is only supported at top-level"
	case .No_Selection_Undo:
		return "no selection change to undo"
	case .No_Selection_Redo:
		return "no selection change to redo"
	case .No_Such_Register:
		return "no such register"
	case .Buffer_Locked:
		return "Changing buffer is not allowed while current buffer is locked"
	}
	unreachable()
}

// context_HISTORY_INVALID is the invalid selection-history id (C++
// SelectionHistory::HistoryId::Invalid, (size_t)-1).
context_HISTORY_INVALID :: -1

// ---------------------------------------------------------------------------
// Selection clone/compare helpers (context-local; the SelectionList shape)
// ---------------------------------------------------------------------------

// context_selections_equal compares two selections slices the way C++
// Vector<Selection>== does: anchor, cursor (with targets) and captures.
@(private = "file")
context_selections_equal :: proc(a, b: []Selection) -> bool {
	if len(a) != len(b) {
		return false
	}
	for av, i in a {
		bv := b[i]
		if av.anchor != bv.anchor || av.cursor != bv.cursor {
			return false
		}
		if len(av.captures) != len(bv.captures) {
			return false
		}
		for ac, j in av.captures {
			if ac != bv.captures[j] {
				return false
			}
		}
	}
	return true
}

// context_selection_lists_equal ports C++ SelectionList::operator==: same
// buffer and same selections (main index and timestamp are ignored).
@(private = "file")
context_selection_lists_equal :: proc(a, b: Selection_List) -> bool {
	return a.buffer == b.buffer && context_selections_equal(a.selections[:], b.selections[:])
}

// ---------------------------------------------------------------------------
// Jump list
// ---------------------------------------------------------------------------

// context_jump_list_make builds an empty jump list. The jumps array uses
// allocator (dynamic arrays remember it, so destroy needs no allocator).
context_jump_list_make :: proc(allocator := context.allocator) -> Jump_List {
	return Jump_List {
		jumps   = make([dynamic]Selection_List, 0, allocator),
		current = 0,
	}
}

// context_jump_list_destroy frees every jump entry (each with its recorded
// allocator) and the jumps array.
context_jump_list_destroy :: proc(jl: ^Jump_List) {
	for &jump in jl.jumps {
		selection_list_destroy(&jump)
	}
	delete(jl.jumps)
	jl.current = 0
}

// context_jump_push_selections pushes one jump (C++ JumpList::push): optional
// index repositioning, truncation past current, duplicate removal, append.
// The selections are cloned with allocator.
context_jump_push_selections :: proc(
	jl: ^Jump_List,
	sels: []Selection,
	main: int,
	buffer: ^Buffer,
	timestamp: int,
	index: Maybe(int) = nil,
	allocator := context.allocator,
) {
	if idx, ok := index.?; ok {
		jl.current = idx
		assert(jl.current >= 0 && jl.current <= len(jl.jumps))
	}
	if jl.current != len(jl.jumps) {
		for i := len(jl.jumps) - 1; i > jl.current; i -= 1 {
			selection_list_destroy(&jl.jumps[i])
			ordered_remove(&jl.jumps, i)
		}
	}
	for i := len(jl.jumps) - 1; i >= 0; i -= 1 {
		existing := jl.jumps[i]
		if existing.buffer == buffer && context_selections_equal(existing.selections[:], sels) {
			selection_list_destroy(&jl.jumps[i])
			ordered_remove(&jl.jumps, i)
		}
	}
	jump := selection_list_make(buffer, sels, timestamp, allocator)
	jump.main = main
	append(&jl.jumps, jump)
	jl.current = len(jl.jumps)
}

// context_jump_push pushes a Selection_List jump (C++ JumpList::push). The
// list is cloned with allocator.
context_jump_push :: proc(jl: ^Jump_List, jump: Selection_List, index: Maybe(int) = nil, allocator := context.allocator) {
	context_jump_push_selections(jl, jump.selections[:], jump.main, jump.buffer, jump.timestamp, index, allocator)
}

// context_jump_forward moves current forward by count (C++
// JumpList::forward), refreshing the target jump and reporting the move on
// the status line.
context_jump_forward :: proc(jl: ^Jump_List, ctx: ^Context, count: int) -> (^Selection_List, Context_Error) {
	// (The C++ adds count in size_t, so negative counts wrap and throw.)
	if count < 0 {
		return nil, .No_Next_Jump
	}
	if jl.current != len(jl.jumps) && jl.current + count < len(jl.jumps) {
		jl.current += count
		res := &jl.jumps[jl.current]
		selection_update_selections(&res.selections, &res.main, res.buffer, res.timestamp, true)
		res.timestamp = len(res.buffer.changes) // buffer.inl.hh: timestamp() == m_changes.size()
		context_jump_report_position(jl, ctx)
		return res, .None
	}
	return nil, .No_Next_Jump
}

// context_jump_backward moves current backward by count (C++
// JumpList::backward), pushing the current selections first when they are
// not already the current jump.
context_jump_backward :: proc(jl: ^Jump_List, ctx: ^Context, count: int) -> (^Selection_List, Context_Error) {
	current := context_selections(ctx)
	should_push_current := jl.current == len(jl.jumps)
	if !should_push_current {
		should_push_current = !context_selection_lists_equal(current^, jl.jumps[jl.current])
	}
	if should_push_current {
		context_jump_push_selections(jl, current.selections[:], current.main, current.buffer, current.timestamp, nil, ctx.allocator)
	}
	steps := count + (1 if should_push_current else 0)
	if jl.current - steps < 0 {
		return nil, .No_Previous_Jump
	}
	jl.current -= steps
	res := &jl.jumps[jl.current]
	selection_update_selections(&res.selections, &res.main, res.buffer, res.timestamp, true)
	res.timestamp = len(res.buffer.changes) // buffer.inl.hh: timestamp() == m_changes.size()
	context_jump_report_position(jl, ctx)
	return res, .None
}

// context_jump_report_position prints the "jumped to #i (n)" status line
// shared by forward and backward.
@(private = "file")
context_jump_report_position :: proc(jl: ^Jump_List, ctx: ^Context) {
	current_str := format_to_string_int(jl.current, ctx.allocator)
	defer delete(current_str, ctx.allocator)
	last_str := format_to_string_int(len(jl.jumps) - 1, ctx.allocator)
	defer delete(last_str, ctx.allocator)
	params := []string{current_str, last_str}
	text, format_err := format_format("jumped to #{} ({})", params, ctx.allocator)
	if format_err != .None {
		return
	}
	defer delete(text, ctx.allocator)
	faces := context_faces(ctx)
	face, face_err := face_registry_lookup(faces, "Information", ctx.allocator)
	if face_err != .None {
		return
	}
	line := display_buffer_line_make_text(text, face, ctx.allocator)
	defer display_buffer_line_destroy(&line)
	context_print_status(ctx, line)
}

// context_jump_forget_buffer drops every jump on buffer (C++
// JumpList::forget_buffer), adjusting current past the removals.
context_jump_forget_buffer :: proc(jl: ^Jump_List, buffer: ^Buffer) {
	i := 0
	for i < len(jl.jumps) {
		if jl.jumps[i].buffer == buffer {
			if i < jl.current {
				jl.current -= 1
			} else if i == jl.current {
				jl.current = len(jl.jumps) - 1
			}
			selection_list_destroy(&jl.jumps[i])
			ordered_remove(&jl.jumps, i)
		} else {
			i += 1
		}
	}
}

// context_jump_current_index returns the jump-list cursor (C++
// JumpList::current_index). len(jumps) means "past the last jump".
context_jump_current_index :: proc(jl: ^Jump_List) -> int {
	return jl.current
}

// context_jump_as_list borrows the jump entries (C++ JumpList::get_as_list).
context_jump_as_list :: proc(jl: ^Jump_List) -> []Selection_List {
	return jl.jumps[:]
}

// ---------------------------------------------------------------------------
// Selection history (C++ Context::SelectionHistory)
// ---------------------------------------------------------------------------

// context_selection_history_init_empty initializes an empty history; the
// context link lets later procs reach the context allocator and buffers.
context_selection_history_init_empty :: proc(hist: ^Context_Selection_History, ctx: ^Context, allocator := context.allocator) {
	hist.ctx = ctx
	hist.history = make([dynamic]Context_Selection_History_Node, 0, allocator)
	hist.history_id = context_HISTORY_INVALID
	hist.staging = nil
	hist.in_edition = {}
}

// context_selection_history_destroy frees the history nodes and the staging
// node (each list with its recorded allocator).
context_selection_history_destroy :: proc(hist: ^Context_Selection_History) {
	for &node in hist.history {
		selection_list_destroy(&node.list)
	}
	delete(hist.history)
	if st, ok := &hist.staging.?; ok {
		selection_list_destroy(&st.list)
	}
	hist.staging = nil
	hist.history_id = context_HISTORY_INVALID
}

// context_selection_history_initialize seeds an empty history with one node
// (C++ SelectionHistory::initialize). The list is cloned with allocator.
context_selection_history_initialize :: proc(hist: ^Context_Selection_History, sels: Selection_List, allocator := context.allocator) {
	assert(context_selection_history_empty(hist))
	assert(len(sels.selections) > 0 && sels.main < len(sels.selections))
	if hist.history == nil {
		hist.history = make([dynamic]Context_Selection_History_Node, 0, 1, allocator)
	}
	sc := sels
	append(
		&hist.history,
		Context_Selection_History_Node {
			list = selection_list_clone(&sc, allocator),
			parent = context_HISTORY_INVALID,
			redo_child = context_HISTORY_INVALID,
		},
	)
	hist.history_id = 0
}

// context_selection_history_empty reports whether the history holds no
// selections (C++ SelectionHistory::empty).
context_selection_history_empty :: proc(hist: ^Context_Selection_History) -> bool {
	_, has_staging := hist.staging.?
	return len(hist.history) == 0 && !has_staging
}

// context_selection_history_selections returns the staging list when an
// edition is open, else the current history list (C++
// SelectionHistory::selections). With update, the list is refreshed
// against buffer changes first. The history must be non-empty.
context_selection_history_selections :: proc(
	hist: ^Context_Selection_History,
	update := true,
) -> ^Selection_List {
	assert(!context_selection_history_empty(hist))
	if st, ok := &hist.staging.?; ok {
		if update {
			selection_list_update(&st.list)
		}
		return &st.list
	}
	assert(hist.history_id >= 0 && hist.history_id < len(hist.history))
	node := &hist.history[hist.history_id]
	if update {
		selection_list_update(&node.list)
	}
	return &node.list
}

// context_selection_history_begin_edition snapshots the current selections
// into staging (C++ SelectionHistory::begin_edition); nested calls only add
// an edition level. allocator is used for the staging clone.
context_selection_history_begin_edition :: proc(
	hist: ^Context_Selection_History,
	allocator := context.allocator,
) {
	if !utils_nested_bool_is_set(hist.in_edition) {
		current := context_selection_history_selections(hist, true)
		hist.staging = Context_Selection_History_Node {
			list = selection_list_clone(current, allocator),
			parent = hist.history_id,
			redo_child = context_HISTORY_INVALID,
		}
	}
	utils_nested_bool_set(&hist.in_edition)
}

// context_selection_history_end_edition commits staging (C++
// SelectionHistory::end_edition): unchanged selections only refresh the
// timestamp and main index of the current node, changed ones append a new
// history node.
context_selection_history_end_edition :: proc(hist: ^Context_Selection_History) {
	assert(utils_nested_bool_is_set(hist.in_edition))
	utils_nested_bool_unset(&hist.in_edition)
	if utils_nested_bool_is_set(hist.in_edition) {
		return
	}
	staging, has_staging := hist.staging.?
	assert(has_staging)
	same := false
	if hist.history_id != context_HISTORY_INVALID {
		current := &hist.history[hist.history_id]
		same = context_selection_lists_equal(current.list, staging.list)
		if same {
			// No change, except maybe the index of the main selection.
			// Update timestamp to potentially improve interaction with content undo.
			current.list.timestamp = staging.list.timestamp
			current.list.main = staging.list.main
		}
	}
	if same {
		selection_list_destroy(&staging.list)
	} else {
		hist.history_id = len(hist.history)
		append(&hist.history, staging)
	}
	hist.staging = nil
}

// context_selection_history_undo moves one step through the selection
// history (C++ SelectionHistory::undo<direction>), switching buffers when
// the target node lives on another buffer. allocator is used for scratch
// clones.
context_selection_history_undo :: proc(
	hist: ^Context_Selection_History,
	direction: Direction,
	allocator := context.allocator,
) -> Context_Error {
	backward := direction == .Backward
	if utils_nested_bool_is_set(hist.in_edition) {
		return .Selection_Undo_In_Edition
	}
	assert(!context_selection_history_empty(hist))
	old := context_selection_history_selections(hist, true)
	old_clone := selection_list_clone(old, allocator)
	defer selection_list_destroy(&old_clone)
	for {
		current := &hist.history[hist.history_id]
		next := current.parent if backward else current.redo_child
		if next == context_HISTORY_INVALID {
			return .No_Selection_Undo if backward else .No_Selection_Redo
		}
		destination_buffer := hist.history[next].list.buffer
		current_buffer := context_buffer(hist.ctx)
		if destination_buffer == current_buffer {
			previous_id := hist.history_id
			hist.history_id = next
			if backward {
				hist.history[next].redo_child = previous_id
			}
		} else {
			data := Context_Undo_Select_Data {
				hist        = hist,
				next        = next,
				previous_id = hist.history_id,
				backward    = backward,
			}
			if change_err := context_change_buffer(
				hist.ctx,
				destination_buffer,
				context_undo_select_callback,
				&data,
			); change_err != .None {
				return change_err
			}
		}
		updated := context_selection_history_selections(hist, true)
		if !context_selection_lists_equal(updated^, old_clone) {
			break
		}
	}
	return .None
}

// Context_Undo_Select_Data carries the history navigation across the
// change_buffer callback used by cross-buffer selection undo.
Context_Undo_Select_Data :: struct {
	hist:        ^Context_Selection_History,
	next:        int,
	previous_id: int,
	backward:    bool,
}

// context_undo_select_callback performs the deferred history navigation
// once change_buffer has switched to the target buffer.
@(private = "file")
context_undo_select_callback :: proc(data: rawptr) {
	d := cast(^Context_Undo_Select_Data)data
	d.hist.history_id = d.next
	if d.backward {
		d.hist.history[d.next].redo_child = d.previous_id
	}
}

// context_selection_history_forget_buffer drops every history node on buffer
// (C++ SelectionHistory::forget_buffer), remapping parent, redo_child and
// the current id past the removals.
context_selection_history_forget_buffer :: proc(hist: ^Context_Selection_History, buffer: ^Buffer) {
	new_ids := make([dynamic]int, len(hist.history), context.temp_allocator)
	bias := 0
	for i in 0 ..< len(hist.history) {
		if hist.history[i].list.buffer == buffer {
			new_ids[i] = context_HISTORY_INVALID
			bias += 1
		} else {
			new_ids[i] = i - bias
		}
	}
	remap := proc(new_ids: []int, old_id: int) -> int {
		if old_id == context_HISTORY_INVALID {
			return context_HISTORY_INVALID
		}
		return new_ids[old_id]
	}
	for i := len(hist.history) - 1; i >= 0; i -= 1 {
		if hist.history[i].list.buffer == buffer {
			selection_list_destroy(&hist.history[i].list)
			ordered_remove(&hist.history, i)
		}
	}
	for &node in hist.history {
		node.parent = remap(new_ids[:], node.parent)
		node.redo_child = remap(new_ids[:], node.redo_child)
	}
	hist.history_id = remap(new_ids[:], hist.history_id)
	if staging, ok := &hist.staging.?; ok {
		staging.parent = remap(new_ids[:], staging.parent)
		assert(staging.redo_child == context_HISTORY_INVALID)
	}
	_, has_staging := hist.staging.?
	assert(hist.history_id != context_HISTORY_INVALID || has_staging)
}

// context_selection_history_assign replaces the staging list when an edition
// is open, else the current list, with a clone of sels (C++
// `selections_write_only() = SelectionList`). allocator is used for the clone.
context_selection_history_assign :: proc(
	hist: ^Context_Selection_History,
	sels: Selection_List,
	allocator := context.allocator,
) {
	assert(len(sels.selections) > 0 && sels.main < len(sels.selections))
	sc := sels
	if staging, ok := &hist.staging.?; ok {
		selection_list_destroy(&staging.list)
		staging.list = selection_list_clone(&sc, allocator)
		return
	}
	assert(hist.history_id >= 0 && hist.history_id < len(hist.history))
	current := &hist.history[hist.history_id]
	selection_list_destroy(&current.list)
	current.list = selection_list_clone(&sc, allocator)
}

// ---------------------------------------------------------------------------
// Context lifecycle
// ---------------------------------------------------------------------------

// context_init_empty initializes a buffer-less context in caller-owned
// storage (C++ Context::Context(EmptyContextFlag)). Tear down with
// context_destroy.
context_init_empty :: proc(ctx: ^Context, allocator := context.allocator) {
	ctx.edition_level = 0
	ctx.edition_timestamp = 0
	ctx.flags = {}
	ctx.input_handler = nil
	ctx.window = nil
	ctx.client = nil
	ctx.local_scopes = make([dynamic]^Scope, 0, allocator)
	context_selection_history_init_empty(&ctx.selection_history, ctx, allocator)
	ctx.name = ""
	ctx.jump_list = context_jump_list_make(allocator)
	ctx.last_select = {}
	ctx.hooks_disabled = {}
	ctx.keymaps_disabled = {}
	ctx.ensure_cursor_visible = true
	ctx.allocator = allocator
}

// context_make_empty builds a buffer-less, client-less context (C++
// Context(EmptyContextFlag)). Tear down with context_destroy. Deviation:
// the C++ self-links selection_history to the in-place object, but a
// value-returning Odin proc cannot self-link (the returned value is a
// copy, verified experimentally), so the link is nilled: selection undo
// on such a context fails fast instead of reading a dead frame. The
// merged caller (module loading) never undoes selections.
context_make_empty :: proc(allocator := context.allocator) -> Context {
	ctx: Context
	context_init_empty(&ctx, allocator)
	ctx.selection_history.ctx = nil
	return ctx
}

// context_init initializes a context with selections in caller-owned
// storage (C++ Context::Context(InputHandler&, SelectionList, Flags,
// String)). The selections and name are cloned with allocator; tear down
// with context_destroy.
context_init :: proc(
	ctx: ^Context,
	input_handler: ^Input_Handler,
	selections: Selection_List,
	flags: Context_Flags,
	name: string,
	allocator := context.allocator,
) {
	assert(len(selections.selections) > 0 && selections.main < len(selections.selections))
	context_init_empty(ctx, allocator)
	ctx.flags = flags
	ctx.input_handler = input_handler
	context_selection_history_initialize(&ctx.selection_history, selections, allocator)
	if len(name) > 0 {
		ctx.name = strings.clone(name, allocator)
	}
}

// context_destroy frees everything the context owns: the name, local scope
// list, selection history, jump list and last-select callback. Local scopes
// must have been popped already (as in C++, where ~LocalScope asserts).
context_destroy :: proc(ctx: ^Context) {
	allocator := ctx.allocator
	if ctx.last_select.destroy != nil {
		ctx.last_select.destroy(ctx.last_select.data, allocator)
	}
	context_selection_history_destroy(&ctx.selection_history)
	context_jump_list_destroy(&ctx.jump_list)
	delete(ctx.local_scopes)
	if len(ctx.name) > 0 {
		delete(ctx.name, allocator)
	}
	ctx.name = ""
}

// ---------------------------------------------------------------------------
// Context accessors
// ---------------------------------------------------------------------------

// context_has_buffer reports whether the context has selections (C++
// Context::has_buffer).
context_has_buffer :: proc(ctx: ^Context) -> bool {
	return !context_selection_history_empty(&ctx.selection_history)
}

// context_buffer returns the current buffer (C++ Context::buffer: the
// buffer of the current selections). The context must have one.
context_buffer :: proc(ctx: ^Context) -> ^Buffer {
	assert(context_has_buffer(ctx))
	return context_selections(ctx, false).buffer
}

// context_has_window reports whether the context has a window (C++
// Context::has_window).
context_has_window :: proc(ctx: ^Context) -> bool {
	return ctx.window != nil
}

// context_window returns the context window (C++ Context::window).
context_window :: proc(ctx: ^Context) -> ^Window {
	assert(ctx.window != nil)
	return ctx.window
}

// context_has_client reports whether the context has a client (C++
// Context::has_client).
context_has_client :: proc(ctx: ^Context) -> bool {
	return ctx.client != nil
}

// context_client returns the context client (C++ Context::client).
context_client :: proc(ctx: ^Context) -> ^Client {
	assert(ctx.client != nil)
	return ctx.client
}

// context_has_input_handler reports whether the context has an input
// handler (C++ Context::has_input_handler).
context_has_input_handler :: proc(ctx: ^Context) -> bool {
	return ctx.input_handler != nil
}

// context_input_handler returns the context input handler (C++
// Context::input_handler).
context_input_handler :: proc(ctx: ^Context) -> ^Input_Handler {
	assert(ctx.input_handler != nil)
	return ctx.input_handler
}

// context_selections returns the current selections list (C++
// Context::selections). With update, the list is refreshed against
// buffer changes first. The history must be non-empty.
context_selections :: proc(ctx: ^Context, update := true) -> ^Selection_List {
	return context_selection_history_selections(&ctx.selection_history, update)
}

// context_selections_content returns the text covered by each selection
// (C++ Context::selections_content). The caller frees the strings and the
// array with allocator.
context_selections_content :: proc(
	ctx: ^Context,
	allocator := context.allocator,
) -> [dynamic]string {
	buffer := context_buffer(ctx)
	sels := context_selections(ctx)
	contents := make([dynamic]string, 0, len(sels.selections), allocator)
	for sel in sels.selections {
		sel_min := sel.anchor
		sel_max := Coord_Buffer{line = sel.cursor.line, column = sel.cursor.column}
		if coord_compare(sel_max, sel_min) < 0 {
			sel_min, sel_max = sel_max, sel_min
		}
		append(&contents, buffer_string(buffer, sel_min, buffer_char_next(buffer, sel_max), allocator))
	}
	return contents
}

// context_selections_write_only returns the selections list without
// refreshing it (C++ Context::selections_write_only).
context_selections_write_only :: proc(ctx: ^Context) -> ^Selection_List {
	return context_selections(ctx, false)
}

// context_end_selection_edition closes one selection-edition level (C++
// Context::end_selection_edition).
context_end_selection_edition :: proc(ctx: ^Context) {
	context_selection_history_end_edition(&ctx.selection_history)
}

// context_undo_selection_change moves one step through the selection
// history (C++ Context::undo_selection_change<direction>).
context_undo_selection_change :: proc(ctx: ^Context, direction: Direction) -> Context_Error {
	return context_selection_history_undo(&ctx.selection_history, direction, ctx.allocator)
}

// context_assign_selections replaces the current selections with a clone of
// sels (C++ `selections_write_only() = SelectionList`).
context_assign_selections :: proc(ctx: ^Context, sels: Selection_List) {
	context_selection_history_assign(&ctx.selection_history, sels, ctx.allocator)
}

// context_change_buffer switches the context to buffer (C++
// Context::change_buffer). set_selection/set_selection_data is the optional
// callback run by the client path after the switch (C++
// Optional<FunctionRef<void()>>); the direct path ignores it, as in C++.
context_change_buffer :: proc(
	ctx: ^Context,
	buffer: ^Buffer,
	set_selection: proc(data: rawptr) = nil,
	set_selection_data: rawptr = nil,
) -> Context_Error {
	if context_has_buffer(ctx) && context_buffer(ctx) == buffer {
		return .None
	}
	if context_has_buffer(ctx) && ctx.edition_level > 0 {
		buffer_commit_undo_group(context_buffer(ctx))
	}
	if context_has_client(ctx) {
		client := ctx.client
		client_ctx := client_context(client)
		if client_ctx == ctx {
			client_info_hide(client)
			client_menu_hide(client)
			cb := Maybe(Client_Selection_Callback)(nil)
			if set_selection != nil {
				cb = Client_Selection_Callback{call = set_selection, data = set_selection_data}
			}
			if client_change_buffer(client, buffer, cb) == .Buffer_Locked {
				return .Buffer_Locked
			}
		} else {
			context_change_buffer_direct(ctx, buffer)
		}
	} else {
		context_change_buffer_direct(ctx, buffer)
	}
	if context_has_input_handler(ctx) {
		input_handler_reset_normal_mode(ctx.input_handler)
	}
	return .None
}

// context_change_buffer_direct performs the client-less buffer switch: fresh
// default selections on the new buffer, local scopes reparented.
@(private = "file")
context_change_buffer_direct :: proc(ctx: ^Context, buffer: ^Buffer) {
	ctx.window = nil
	fresh := Selection_List {
		main       = 0,
		buffer     = buffer,
		timestamp  = len(buffer.changes), // buffer.inl.hh: SelectionList ctor uses buffer.timestamp()
		allocator  = ctx.allocator,
	}
	fresh.selections = make([dynamic]Selection, 1, ctx.allocator)
	fresh.selections[0] = Selection {
		basic = Basic_Selection {
			anchor = Coord_Buffer{},
			cursor = coord_buffer_and_target(Coord_Buffer{}),
		},
	}
	defer selection_list_destroy(&fresh)
	if context_selection_history_empty(&ctx.selection_history) {
		context_selection_history_initialize(&ctx.selection_history, fresh, ctx.allocator)
	} else {
		edition := context_scoped_selection_edition_make(ctx)
		defer context_scoped_selection_edition_destroy(&edition)
		context_selection_history_assign(&ctx.selection_history, fresh, ctx.allocator)
	}
	if len(ctx.local_scopes) > 0 {
		scope_reparent(ctx.local_scopes[0], &buffer.scope)
	}
}

// context_forget_buffer drops buffer from the jump list and selection
// history (C++ Context::forget_buffer), switching to the last buffer when
// the forgotten one is current.
context_forget_buffer :: proc(ctx: ^Context, buffer: ^Buffer) -> Context_Error {
	context_jump_forget_buffer(&ctx.jump_list, buffer)
	if context_buffer(ctx) != buffer {
		context_selection_history_forget_buffer(&ctx.selection_history, buffer)
		return .None
	}
	if ctx.edition_level != 0 && context_has_input_handler(ctx) {
		input_handler_reset_normal_mode(ctx.input_handler)
	}
	last := context_last_buffer(ctx)
	if last != nil {
		if err := context_change_buffer(ctx, last); err != .None {
			return err
		}
	} else {
		// At least one buffer always exists (C++ keeps *scratch*).
		first, first_err := buffer_manager_get_first(buffer_manager_instance())
		assert(first_err == .None)
		if err := context_change_buffer(ctx, first); err != .None {
			return err
		}
	}
	context_selection_history_forget_buffer(&ctx.selection_history, buffer)
	return .None
}

// context_set_client attaches the client (C++ Context::set_client). The
// context must not have one already.
context_set_client :: proc(ctx: ^Context, client: ^Client) {
	assert(!context_has_client(ctx))
	ctx.client = client
}

// context_set_window attaches the window (C++ Context::set_window). The
// window must view the context buffer; local scopes reparent onto it.
context_set_window :: proc(ctx: ^Context, window: ^Window) {
	assert(window.buffer == context_buffer(ctx))
	ctx.window = window
	if len(ctx.local_scopes) > 0 {
		scope_reparent(ctx.local_scopes[0], &window.scope)
	}
}

// context_scope returns the innermost scope: the top local scope, else the
// window, else the buffer, else the global scope (C++ Context::scope).
context_scope :: proc(ctx: ^Context, allow_local := true) -> ^Scope {
	if allow_local && len(ctx.local_scopes) > 0 {
		return ctx.local_scopes[len(ctx.local_scopes) - 1]
	}
	if context_has_window(ctx) {
		return &ctx.window.scope
	}
	if context_has_buffer(ctx) {
		return &context_buffer(ctx).scope
	}
	return &scope_global_instance().scope
}

// context_local_scope returns the top local scope, or nil (C++
// Context::local_scope).
context_local_scope :: proc(ctx: ^Context) -> ^Scope {
	if len(ctx.local_scopes) == 0 {
		return nil
	}
	return ctx.local_scopes[len(ctx.local_scopes) - 1]
}

// context_options returns the options of the context scope (C++
// Context::options).
context_options :: proc(ctx: ^Context) -> ^Option_Manager {
	return &context_scope(ctx).data.options
}

// context_hooks returns the hooks of the context scope (C++
// Context::hooks).
context_hooks :: proc(ctx: ^Context) -> ^Hook_Manager {
	return &context_scope(ctx).data.hooks
}

// context_keymaps returns the keymaps of the context scope (C++
// Context::keymaps).
context_keymaps :: proc(ctx: ^Context) -> ^Keymap_Manager {
	return &context_scope(ctx).data.keymaps
}

// context_aliases returns the aliases of the context scope (C++
// Context::aliases).
context_aliases :: proc(ctx: ^Context) -> ^Alias_Registry {
	return &context_scope(ctx).data.aliases
}

// context_faces returns the faces of the context scope (C++
// Context::faces).
context_faces :: proc(ctx: ^Context, allow_local := true) -> ^Face_Registry {
	return &context_scope(ctx, allow_local).data.faces
}

// context_print_status_full shows a prompt plus content on the status line
// (C++ Context::print_status(prompt, content, cursor_pos, style)); without
// a client it is a no-op.
context_print_status_full :: proc(
	ctx: ^Context,
	prompt: Display_Line,
	content: Display_Line,
	cursor_pos: Units_ColumnCount,
	style: User_Interface_Status_Style,
) {
	if context_has_client(ctx) {
		client_print_status(ctx.client, prompt, content, cursor_pos, style)
	}
}

// context_print_status_simple shows content on the status line (C++
// Context::print_status(content)).
context_print_status_simple :: proc(ctx: ^Context, content: Display_Line) {
	context_print_status_full(ctx, Display_Line{}, content, Units_ColumnCount(-1), .Status)
}

// context_print_status shows a status message (C++ Context::print_status
// overloads).
context_print_status :: proc {
	context_print_status_full,
	context_print_status_simple,
}

// context_main_sel_register_value returns the main-selection value of
// register reg (C++ Context::main_sel_register_value).
context_main_sel_register_value :: proc(ctx: ^Context, reg: string) -> (string, Context_Error) {
	index := 0
	if context_has_buffer(ctx) {
		index = context_selections(ctx, false).main
	}
	named_register, reg_err := register_manager_get_by_name(register_manager_instance(), reg)
	if reg_err != .None {
		return "", .No_Such_Register
	}
	return named_register.vtable.get_main(named_register.data, ctx, index), .None
}

// context_name returns the context name (C++ Context::name).
context_name :: proc(ctx: ^Context) -> string {
	return ctx.name
}

// context_set_name renames the context and runs the ClientRenamed hook
// (C++ Context::set_name).
context_set_name :: proc(ctx: ^Context, name: string) {
	old_name := ctx.name
	ctx.name = ""
	if len(name) > 0 {
		ctx.name = strings.clone(name, ctx.allocator)
	}
	params := []string{old_name, ctx.name}
	text, format_err := format_format("{}:{}", params, ctx.allocator)
	assert(format_err == .None)
	defer delete(text, ctx.allocator)
	hook_manager_run_hook(context_hooks(ctx), .Client_Renamed, text, ctx)
	if len(old_name) > 0 {
		delete(old_name, ctx.allocator)
	}
}

// context_is_editing reports whether a buffer edition is open (C++
// Context::is_editing).
context_is_editing :: proc(ctx: ^Context) -> bool {
	return ctx.edition_level != 0
}

// context_disable_undo_handling turns off undo handling for this context
// (C++ Context::disable_undo_handling).
context_disable_undo_handling :: proc(ctx: ^Context) {
	ctx.edition_level = -1
}

// context_hooks_disabled borrows the hooks-disabled flag (C++
// Context::hooks_disabled).
context_hooks_disabled :: proc(ctx: ^Context) -> ^Utils_Nested_Bool {
	return &ctx.hooks_disabled
}

// context_keymaps_disabled borrows the keymaps-disabled flag (C++
// Context::keymaps_disabled).
context_keymaps_disabled :: proc(ctx: ^Context) -> ^Utils_Nested_Bool {
	return &ctx.keymaps_disabled
}

// context_flags returns the context flags (C++ Context::flags).
context_flags :: proc(ctx: ^Context) -> Context_Flags {
	return ctx.flags
}

// context_jump_list borrows the jump list (C++ Context::jump_list).
context_jump_list :: proc(ctx: ^Context) -> ^Jump_List {
	return &ctx.jump_list
}

// context_push_jump pushes the current selections on the jump list (C++
// Context::push_jump). Draft contexts only push when forced.
context_push_jump :: proc(ctx: ^Context, force := false) {
	if force || .Draft not_in ctx.flags {
		current := context_selections(ctx)
		context_jump_push_selections(
			&ctx.jump_list,
			current.selections[:],
			current.main,
			current.buffer,
			current.timestamp,
			nil,
			ctx.allocator,
		)
	}
}

// context_set_last_select records the repeatable last selection command
// (C++ Context::set_last_select). destroy frees data at context_destroy.
context_set_last_select :: proc(
	ctx: ^Context,
	call: proc(data: rawptr, ctx: ^Context),
	data: rawptr = nil,
	destroy: proc(data: rawptr, allocator: mem.Allocator) = nil,
) {
	if ctx.last_select.destroy != nil {
		ctx.last_select.destroy(ctx.last_select.data, ctx.allocator)
	}
	ctx.last_select = Context_Last_Select{call = call, data = data, destroy = destroy}
}

// context_repeat_last_select repeats the last selection command, if any
// (C++ Context::repeat_last_select).
context_repeat_last_select :: proc(ctx: ^Context) {
	if ctx.last_select.call != nil {
		ctx.last_select.call(ctx.last_select.data, ctx)
	}
}

// context_last_buffer returns the most recently jumped-to buffer other than
// the current one, or nil (C++ Context::last_buffer).
context_last_buffer :: proc(ctx: ^Context) -> ^Buffer {
	jumps := context_jump_as_list(&ctx.jump_list)
	if len(jumps) == 0 {
		return nil
	}
	if !context_has_buffer(ctx) {
		return nil
	}
	current := context_buffer(ctx)
	// Search forward from current_index()-1, then backward from the start.
	// (The C++ subrange(current_index()-1) would underflow at index 0; an
	// empty forward range is used instead.)
	current_index := context_jump_current_index(&ctx.jump_list)
	start := len(jumps)
	if current_index > 0 {
		start = current_index - 1
	}
	for i := start; i < len(jumps); i += 1 {
		if jumps[i].buffer != current {
			return jumps[i].buffer
		}
	}
	stop := min(current_index, len(jumps))
	for i := stop - 1; i >= 0; i -= 1 {
		if jumps[i].buffer != current {
			return jumps[i].buffer
		}
	}
	return nil
}

// context_begin_edition opens one buffer-edition level (C++
// Context::begin_edition). The context must have a buffer.
@(private = "file")
context_begin_edition :: proc(ctx: ^Context) {
	if ctx.edition_level >= 0 {
		if ctx.edition_level == 0 {
			ctx.edition_timestamp = len(context_buffer(ctx).changes) // buffer.inl.hh: timestamp() == m_changes.size()
		}
		ctx.edition_level += 1
	}
}

// context_end_edition closes one buffer-edition level, committing the undo
// group when the outermost edition changed the buffer (C++
// Context::end_edition).
@(private = "file")
context_end_edition :: proc(ctx: ^Context) {
	if ctx.edition_level < 0 {
		return
	}
	assert(ctx.edition_level != 0)
	if ctx.edition_level == 1 {
		buffer := context_buffer(ctx)
		if len(buffer.changes) != ctx.edition_timestamp { // buffer.inl.hh: timestamp()
			buffer_commit_undo_group(buffer)
		}
	}
	ctx.edition_level -= 1
}

// ---------------------------------------------------------------------------
// Scoped editions (C++ ScopedEdition / ScopedSelectionEdition)
// ---------------------------------------------------------------------------

// context_scoped_edition_make opens a buffer edition for the context buffer,
// if any (C++ ScopedEdition ctor). Pair with
// context_scoped_edition_destroy.
context_scoped_edition_make :: proc(ctx: ^Context) -> Scoped_Edition {
	edition := Scoped_Edition{ctx = ctx}
	if context_has_buffer(ctx) {
		edition.buffer = context_buffer(ctx)
		context_begin_edition(ctx)
	}
	return edition
}

// context_scoped_edition_destroy closes the edition (C++ ScopedEdition
// dtor).
context_scoped_edition_destroy :: proc(edition: ^Scoped_Edition) {
	if edition.buffer != nil {
		context_end_edition(edition.ctx)
		edition.buffer = nil
	}
}

// context_scoped_selection_edition_make opens a selection edition unless the
// context is a draft or buffer-less (C++ ScopedSelectionEdition ctor). Pair
// with context_scoped_selection_edition_destroy.
context_scoped_selection_edition_make :: proc(ctx: ^Context) -> Scoped_Selection_Edition {
	edition := Scoped_Selection_Edition{ctx = ctx}
	edition.valid = .Draft not_in ctx.flags && context_has_buffer(ctx)
	if edition.valid {
		context_selection_history_begin_edition(&ctx.selection_history, ctx.allocator)
	}
	return edition
}

// context_scoped_selection_edition_move transfers the edition to a new
// guard, invalidating the source (C++ ScopedSelectionEdition move ctor).
context_scoped_selection_edition_move :: proc(other: ^Scoped_Selection_Edition) -> Scoped_Selection_Edition {
	moved := Scoped_Selection_Edition{ctx = other.ctx, valid = other.valid}
	other.valid = false
	return moved
}

// context_scoped_selection_edition_destroy closes the edition (C++
// ScopedSelectionEdition dtor).
context_scoped_selection_edition_destroy :: proc(edition: ^Scoped_Selection_Edition) {
	if edition.valid {
		context_selection_history_end_edition(&edition.ctx.selection_history)
		edition.valid = false
	}
}

// ---------------------------------------------------------------------------
// Stubs: called here, implemented by unmerged modules (STUB protocol)
// ---------------------------------------------------------------------------

