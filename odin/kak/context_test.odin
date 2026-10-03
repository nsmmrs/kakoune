// Tests for context.odin (port of src/context.hh / src/context.cc).
//
// The C++ context code has no UnitTest block; these tests cover every
// standalone-testable behavior: lifecycle, accessors, jump-list surgery,
// selection-history surgery, draft buffer switches, and the scoped guards.
// Procs that must call into unmerged modules (selection update, buffer
// text, hooks, client, registers) are implemented but untestable here; see
// the coverage gaps in the wave summary.
//
// Test buffers are hand-built knot structs (no buffer module yet): lines
// borrow string literals (freed as arrays only), while selections passed to
// context procs are deep-owned via the builders below and released with
// selection_list_destroy.
package kak

import "core:mem"
import "core:strings"
import "core:testing"

// context_test_make_buffer builds a minimal test buffer borrowing lines.
context_test_make_buffer :: proc(lines: []string, allocator := context.allocator) -> ^Buffer {
	buf := new(Buffer, allocator)
	buf.lines = make(Buffer_Lines, len(lines), allocator)
	copy(buf.lines[:], lines)
	buf.changes = make([dynamic]Buffer_Change, 0, allocator)
	return buf
}

// context_test_destroy_buffer frees a buffer from context_test_make_buffer
// (line bytes are borrowed literals and are not freed).
context_test_destroy_buffer :: proc(buf: ^Buffer, allocator := context.allocator) {
	delete(buf.lines)
	delete(buf.changes)
	free(buf, allocator)
}

// context_test_make_selection builds a selection with default (-1) targets
// and owned capture copies.
context_test_make_selection :: proc(
	anchor: Coord_Buffer,
	cursor: Coord_Buffer,
	captures: []string = nil,
	allocator := context.allocator,
) -> Selection {
	sel := Selection {
		basic = Basic_Selection{anchor = anchor, cursor = coord_buffer_and_target(cursor)},
	}
	if len(captures) > 0 {
		sel.captures = make([dynamic]string, len(captures), allocator)
		for cap, i in captures {
			sel.captures[i] = strings.clone(cap, allocator)
		}
	}
	return sel
}

// context_test_free_selection frees a selection from
// context_test_make_selection.
context_test_free_selection :: proc(sel: ^Selection, allocator := context.allocator) {
	for cap in sel.captures {
		delete(cap, allocator)
	}
	delete(sel.captures)
}

// context_test_make_selections builds an owned Selection_List (captures
// deep-copied); release with selection_list_destroy.
context_test_make_selections :: proc(
	buffer: ^Buffer,
	main: int,
	sels: []Selection,
	allocator := context.allocator,
) -> Selection_List {
	out := Selection_List {
		main      = main,
		buffer    = buffer,
		timestamp = len(buffer.changes),
		allocator = allocator,
	}
	out.selections = make([dynamic]Selection, len(sels), allocator)
	for s, i in sels {
		out.selections[i] = Selection {
			basic = Basic_Selection{anchor = s.anchor, cursor = s.cursor},
		}
		if len(s.captures) > 0 {
			out.selections[i].captures = make([dynamic]string, len(s.captures), allocator)
			for cap, j in s.captures {
				out.selections[i].captures[j] = strings.clone(cap, allocator)
			}
		}
	}
	return out
}

@(test)
test_context_empty_lifecycle :: proc(t: ^testing.T) {
	ctx := Context{}
	context_init_empty(&ctx, context.allocator)
	defer context_destroy(&ctx)

	testing.expect(t, !context_has_buffer(&ctx))
	testing.expect(t, !context_has_window(&ctx))
	testing.expect(t, !context_has_client(&ctx))
	testing.expect(t, !context_has_input_handler(&ctx))
	testing.expect(t, context_local_scope(&ctx) == nil)
	testing.expect_value(t, context_flags(&ctx), Context_Flags{})
	testing.expect_value(t, context_name(&ctx), "")
	testing.expect(t, ctx.ensure_cursor_visible)
	testing.expect(t, !context_is_editing(&ctx))

	// (Missing-member access now asserts instead of returning an error;
	// only the has_* guards above are testable here.)
	testing.expect_value(t, context_jump_current_index(context_jump_list(&ctx)), 0)
	testing.expect_value(t, len(context_jump_as_list(context_jump_list(&ctx))), 0)
	testing.expect(t, context_last_buffer(&ctx) == nil)
}

@(test)
test_context_init_destroy :: proc(t: ^testing.T) {
	buf := context_test_make_buffer({"hello", "world"}, context.allocator)
	defer context_test_destroy_buffer(buf, context.allocator)
	sel := context_test_make_selection({line = 1, column = 2}, {line = 1, column = 4}, {"cap"})
	defer context_test_free_selection(&sel, context.allocator)
	sels := context_test_make_selections(buf, 0, {sel}, context.allocator)
	defer selection_list_destroy(&sels)

	handler := Input_Handler{}
	ctx := Context{}
	context_init(&ctx, &handler, sels, {.Draft}, "test-ctx", context.allocator)
	defer context_destroy(&ctx)

	testing.expect(t, context_has_buffer(&ctx))
	testing.expect(t, context_buffer(&ctx) == buf)
	testing.expect(t, context_input_handler(&ctx) == &handler)
	testing.expect_value(t, context_flags(&ctx), Context_Flags{.Draft})
	testing.expect_value(t, context_name(&ctx), "test-ctx")

	sels_now := context_selections(&ctx, false)
	testing.expect_value(t, sels_now.main, 0)
	testing.expect_value(t, len(sels_now.selections), 1)
	testing.expect_value(t, sels_now.selections[0].anchor, Coord_Buffer{line = 1, column = 2})
	testing.expect_value(t, len(sels_now.selections[0].captures), 1)
	testing.expect_value(t, sels_now.selections[0].captures[0], sels.selections[0].captures[0])
	// Deep copies: independent bytes.
	testing.expect(
		t,
		raw_data(sels_now.selections[0].captures[0]) != raw_data(sels.selections[0].captures[0]),
	)
	want_name := "test-ctx"
	testing.expect(t, raw_data(context_name(&ctx)) != raw_data(want_name))
}

@(test)
test_context_error_messages :: proc(t: ^testing.T) {
	testing.expect_value(t, context_error_message(.None), "")
	testing.expect_value(t, context_error_message(.No_Buffer), "no buffer in context")
	testing.expect_value(t, context_error_message(.No_Window), "no window in context")
	testing.expect_value(t, context_error_message(.No_Client), "no client in context")
	testing.expect_value(t, context_error_message(.No_Input_Handler), "no input handler in context")
	testing.expect_value(t, context_error_message(.No_Selections), "no selections in context")
	testing.expect_value(t, context_error_message(.No_Next_Jump), "no next jump")
	testing.expect_value(t, context_error_message(.No_Previous_Jump), "no previous jump")
	testing.expect_value(
		t,
		context_error_message(.Selection_Undo_In_Edition),
		"selection undo is only supported at top-level",
	)
	testing.expect_value(t, context_error_message(.No_Selection_Undo), "no selection change to undo")
	testing.expect_value(t, context_error_message(.No_Selection_Redo), "no selection change to redo")
	testing.expect_value(t, context_error_message(.No_Such_Register), "no such register")
	testing.expect_value(
		t,
		context_error_message(.Buffer_Locked),
		"Changing buffer is not allowed while current buffer is locked",
	)
}

@(test)
test_context_client_window_scope :: proc(t: ^testing.T) {
	buf := context_test_make_buffer({"abc"}, context.allocator)
	defer context_test_destroy_buffer(buf, context.allocator)
	sel := context_test_make_selection({}, {})
	sels := context_test_make_selections(buf, 0, {sel}, context.allocator)
	defer selection_list_destroy(&sels)
	handler := Input_Handler{}
	ctx := Context{}
	context_init(&ctx, &handler, sels, {}, "", context.allocator)
	defer context_destroy(&ctx)

	client := Client{}
	context_set_client(&ctx, &client)
	testing.expect(t, context_has_client(&ctx))
	testing.expect(t, context_client(&ctx) == &client)

	// Buffer scope wins while no window is attached.
	buffer_data := Scope_Data{}
	buf.scope.data = &buffer_data
	testing.expect(t, context_scope(&ctx) == &buf.scope)
	testing.expect(t, context_options(&ctx) == &buffer_data.options)
	testing.expect(t, context_hooks(&ctx) == &buffer_data.hooks)
	testing.expect(t, context_keymaps(&ctx) == &buffer_data.keymaps)
	testing.expect(t, context_aliases(&ctx) == &buffer_data.aliases)
	testing.expect(t, context_faces(&ctx) == &buffer_data.faces)

	window_data := Scope_Data{}
	win := Window{buffer = buf}
	win.scope.data = &window_data
	context_set_window(&ctx, &win)
	testing.expect(t, context_has_window(&ctx))
	testing.expect(t, context_window(&ctx) == &win)
	// Window scope now wins.
	testing.expect(t, context_scope(&ctx) == &win.scope)
	testing.expect(t, context_options(&ctx) == &window_data.options)
	// A pushed local scope wins over both (until the local_scope module
	// owns push/pop, the vector is driven directly).
	local_data := Scope_Data{}
	local := Scope{data = &local_data}
	append(&ctx.local_scopes, &local)
	testing.expect(t, context_local_scope(&ctx) == &local)
	testing.expect(t, context_scope(&ctx) == &local)
	testing.expect(t, context_scope(&ctx, false) == &win.scope)
	testing.expect(t, context_faces(&ctx, false) == &window_data.faces)
	pop(&ctx.local_scopes)
}

@(test)
test_context_print_status_without_client :: proc(t: ^testing.T) {
	ctx := Context{}
	context_init_empty(&ctx, context.allocator)
	defer context_destroy(&ctx)
	// No client: no-op, must not crash (the client path needs client.cc).
	context_print_status(&ctx, Display_Line{})
	context_print_status(&ctx, Display_Line{}, Display_Line{}, Units_ColumnCount(3), User_Interface_Status_Style.Prompt)
	testing.expect(t, !context_has_client(&ctx))
}

@(test)
test_context_scoped_edition :: proc(t: ^testing.T) {
	buf := context_test_make_buffer({"abc"}, context.allocator)
	defer context_test_destroy_buffer(buf, context.allocator)
	sel := context_test_make_selection({}, {})
	sels := context_test_make_selections(buf, 0, {sel}, context.allocator)
	defer selection_list_destroy(&sels)
	handler := Input_Handler{}
	ctx := Context{}
	context_init(&ctx, &handler, sels, {}, "", context.allocator)
	defer context_destroy(&ctx)

	testing.expect(t, !context_is_editing(&ctx))
	outer := context_scoped_edition_make(&ctx)
	testing.expect(t, context_is_editing(&ctx))
	testing.expect_value(t, ctx.edition_level, 1)
	testing.expect_value(t, ctx.edition_timestamp, len(buf.changes))
	inner := context_scoped_edition_make(&ctx)
	testing.expect_value(t, ctx.edition_level, 2)
	context_scoped_edition_destroy(&inner)
	testing.expect_value(t, ctx.edition_level, 1)
	context_scoped_edition_destroy(&outer)
	testing.expect_value(t, ctx.edition_level, 0)
	testing.expect(t, !context_is_editing(&ctx))

	context_disable_undo_handling(&ctx)
	testing.expect_value(t, ctx.edition_level, -1)
	testing.expect(t, context_is_editing(&ctx))
	disabled := context_scoped_edition_make(&ctx)
	testing.expect_value(t, ctx.edition_level, -1)
	context_scoped_edition_destroy(&disabled)
	testing.expect_value(t, ctx.edition_level, -1)

	// Buffer-less contexts get a inert guard.
	empty := Context{}
	context_init_empty(&empty, context.allocator)
	defer context_destroy(&empty)
	empty_edition := context_scoped_edition_make(&empty)
	testing.expect(t, empty_edition.buffer == nil)
	context_scoped_edition_destroy(&empty_edition)
	testing.expect_value(t, empty.edition_level, 0)
}

@(test)
test_context_nested_bool_accessors :: proc(t: ^testing.T) {
	ctx := Context{}
	context_init_empty(&ctx, context.allocator)
	defer context_destroy(&ctx)
	testing.expect(t, !utils_nested_bool_is_set(context_hooks_disabled(&ctx)^))
	testing.expect(t, !utils_nested_bool_is_set(context_keymaps_disabled(&ctx)^))
	utils_nested_bool_set(context_hooks_disabled(&ctx))
	testing.expect(t, utils_nested_bool_is_set(ctx.hooks_disabled))
	utils_nested_bool_unset(context_hooks_disabled(&ctx))
	testing.expect(t, !utils_nested_bool_is_set(ctx.hooks_disabled))
}

@(test)
test_context_selection_list_clone_destroy :: proc(t: ^testing.T) {
	buf := context_test_make_buffer({"abc"}, context.allocator)
	defer context_test_destroy_buffer(buf, context.allocator)
	sel := context_test_make_selection({line = 0, column = 1}, {line = 0, column = 2}, {"x", "y"})
	defer context_test_free_selection(&sel, context.allocator)
	sels := context_test_make_selections(buf, 0, {sel}, context.allocator)
	defer selection_list_destroy(&sels)

	sc := sels
	clone := selection_list_clone(&sc, context.allocator)
	defer selection_list_destroy(&clone)
	testing.expect(t, clone.buffer == buf)
	testing.expect_value(t, clone.main, sels.main)
	testing.expect_value(t, clone.timestamp, sels.timestamp)
	testing.expect_value(t, len(clone.selections[0].captures), 2)
	testing.expect_value(t, clone.selections[0].captures[0], "x")
	testing.expect_value(t, clone.selections[0].captures[1], "y")
	testing.expect(t, raw_data(clone.selections[0].captures[0]) != raw_data(sels.selections[0].captures[0]))
}

@(test)
test_context_push_jump_draft_noop :: proc(t: ^testing.T) {
	buf := context_test_make_buffer({"abc"}, context.allocator)
	defer context_test_destroy_buffer(buf, context.allocator)
	sel := context_test_make_selection({}, {})
	sels := context_test_make_selections(buf, 0, {sel}, context.allocator)
	defer selection_list_destroy(&sels)
	handler := Input_Handler{}
	ctx := Context{}
	context_init(&ctx, &handler, sels, {.Draft}, "", context.allocator)
	defer context_destroy(&ctx)

	context_push_jump(&ctx)
	testing.expect_value(t, len(context_jump_as_list(&ctx.jump_list)), 0)
	// (The pushing path refreshes selections via the selection module, so
	// only the draft no-op is testable here; jumps below are pushed
	// directly.)
}

@(test)
test_context_jump_push_dedup_truncate :: proc(t: ^testing.T) {
	allocator := context.allocator
	buf_a := context_test_make_buffer({"a"}, allocator)
	defer context_test_destroy_buffer(buf_a, allocator)
	buf_b := context_test_make_buffer({"b"}, allocator)
	defer context_test_destroy_buffer(buf_b, allocator)

	jl := context_jump_list_make(allocator)
	defer context_jump_list_destroy(&jl)

	sel_a1 := context_test_make_selection({}, {line = 0, column = 1})
	defer context_test_free_selection(&sel_a1, allocator)
	sel_a2 := context_test_make_selection({}, {line = 0, column = 2})
	defer context_test_free_selection(&sel_a2, allocator)
	sel_b := context_test_make_selection({line = 0, column = 1}, {line = 0, column = 1})
	defer context_test_free_selection(&sel_b, allocator)

	list_a1 := context_test_make_selections(buf_a, 0, {sel_a1}, allocator)
	defer selection_list_destroy(&list_a1)
	list_a2 := context_test_make_selections(buf_a, 0, {sel_a2}, allocator)
	defer selection_list_destroy(&list_a2)
	list_b := context_test_make_selections(buf_b, 0, {sel_b}, allocator)
	defer selection_list_destroy(&list_b)

	context_jump_push(&jl, list_a1, nil, allocator)
	context_jump_push(&jl, list_b, nil, allocator)
	context_jump_push(&jl, list_a2, nil, allocator)
	testing.expect_value(t, len(jl.jumps), 3)
	testing.expect_value(t, context_jump_current_index(&jl), 3)
	testing.expect(t, jl.jumps[0].buffer == buf_a)
	testing.expect(t, jl.jumps[1].buffer == buf_b)

	// Duplicate push removes the old entry and re-appends.
	context_jump_push(&jl, list_a1, nil, allocator)
	testing.expect_value(t, len(jl.jumps), 3)
	testing.expect_value(t, context_jump_current_index(&jl), 3)
	testing.expect(t, jl.jumps[0].buffer == buf_b)
	testing.expect(t, jl.jumps[2].buffer == buf_a)
	testing.expect_value(t, jl.jumps[2].selections[0].cursor.column, Coord_Byte(1))

	// Indexed push truncates past the index first: current=1 drops jumps[2].
	context_jump_push(&jl, list_b, 1, allocator)
	testing.expect_value(t, len(jl.jumps), 2)
	testing.expect_value(t, context_jump_current_index(&jl), 2)
	testing.expect(t, jl.jumps[1].buffer == buf_b)
	// (The old jumps[0] on buf_b was also a duplicate and got removed.)

	// Main index and timestamp do not participate in equality (C++
	// SelectionList::operator== compares buffer + selections only).
	sel_dup := context_test_make_selection({}, {line = 0, column = 1})
	defer context_test_free_selection(&sel_dup, allocator)
	list_dup := context_test_make_selections(buf_a, 0, {sel_dup}, allocator)
	defer selection_list_destroy(&list_dup)
	list_dup.main = 0
	list_dup.timestamp = 999
	context_jump_push(&jl, list_dup, nil, allocator)
	// buf_a entry was truncated above, so this appends (a foreign
	// timestamp does not distinguish it); pushing it again dedups.
	testing.expect_value(t, len(jl.jumps), 3)
	context_jump_push(&jl, list_dup, nil, allocator)
	testing.expect_value(t, len(jl.jumps), 3)
}

@(test)
test_context_jump_forget_buffer :: proc(t: ^testing.T) {
	allocator := context.allocator
	buf_a := context_test_make_buffer({"a"}, allocator)
	defer context_test_destroy_buffer(buf_a, allocator)
	buf_b := context_test_make_buffer({"b"}, allocator)
	defer context_test_destroy_buffer(buf_b, allocator)

	jl := context_jump_list_make(allocator)
	defer context_jump_list_destroy(&jl)

	sel := context_test_make_selection({}, {})
	defer context_test_free_selection(&sel, allocator)
	list_a := context_test_make_selections(buf_a, 0, {sel}, allocator)
	defer selection_list_destroy(&list_a)
	list_b := context_test_make_selections(buf_b, 0, {sel}, allocator)
	defer selection_list_destroy(&list_b)

	context_jump_push(&jl, list_a, nil, allocator)
	context_jump_push(&jl, list_b, nil, allocator)
	testing.expect_value(t, context_jump_current_index(&jl), 2)

	// Forgetting a buffer before current shifts current down.
	context_jump_forget_buffer(&jl, buf_a)
	testing.expect_value(t, len(jl.jumps), 1)
	testing.expect_value(t, context_jump_current_index(&jl), 1)
	testing.expect(t, jl.jumps[0].buffer == buf_b)

	// Forgetting an unknown buffer changes nothing.
	buf_c := context_test_make_buffer({"c"}, allocator)
	defer context_test_destroy_buffer(buf_c, allocator)
	context_jump_forget_buffer(&jl, buf_c)
	testing.expect_value(t, len(jl.jumps), 1)
	testing.expect_value(t, context_jump_current_index(&jl), 1)

	// Forgetting the entry exactly at current moves current past the end.
	jl.current = 0
	context_jump_forget_buffer(&jl, buf_b)
	testing.expect_value(t, len(jl.jumps), 0)
	testing.expect_value(t, context_jump_current_index(&jl), 0)
}

@(test)
test_context_jump_forward_errors :: proc(t: ^testing.T) {
	// All forward error paths return before touching the selection
	// module, so they are testable (success needs selection update).
	ctx := Context{}
	context_init_empty(&ctx, context.allocator)
	defer context_destroy(&ctx)
	jl := context_jump_list(&ctx)

	_, err := context_jump_forward(jl, &ctx, 1)
	testing.expect_value(t, err, Context_Error.No_Next_Jump)
	_, err = context_jump_forward(jl, &ctx, -1)
	testing.expect_value(t, err, Context_Error.No_Next_Jump)

	allocator := context.allocator
	buf := context_test_make_buffer({"a"}, allocator)
	defer context_test_destroy_buffer(buf, allocator)
	sel := context_test_make_selection({}, {})
	defer context_test_free_selection(&sel, allocator)
	list := context_test_make_selections(buf, 0, {sel}, allocator)
	defer selection_list_destroy(&list)
	context_jump_push(jl, list, nil, allocator)
	// Past the end: nothing forward.
	testing.expect_value(t, context_jump_current_index(jl), 1)
	_, err = context_jump_forward(jl, &ctx, 1)
	testing.expect_value(t, err, Context_Error.No_Next_Jump)
	// (Backward always refreshes selections first: gap.)
}

@(test)
test_context_undo_in_edition_error :: proc(t: ^testing.T) {
	allocator := context.allocator
	buf := context_test_make_buffer({"a"}, allocator)
	defer context_test_destroy_buffer(buf, allocator)
	sel := context_test_make_selection({}, {})
	defer context_test_free_selection(&sel, allocator)
	sels := context_test_make_selections(buf, 0, {sel}, allocator)
	defer selection_list_destroy(&sels)
	handler := Input_Handler{}
	ctx := Context{}
	context_init(&ctx, &handler, sels, {}, "", allocator)
	defer context_destroy(&ctx)

	utils_nested_bool_set(&ctx.selection_history.in_edition)
	defer utils_nested_bool_unset(&ctx.selection_history.in_edition)
	testing.expect_value(
		t,
		context_undo_selection_change(&ctx, .Backward),
		Context_Error.Selection_Undo_In_Edition,
	)
	testing.expect_value(
		t,
		context_undo_selection_change(&ctx, .Forward),
		Context_Error.Selection_Undo_In_Edition,
	)
	// (Undo itself refreshes selections via the selection module: gap.)
}

@(test)
test_context_selections_content :: proc(t: ^testing.T) {
	allocator := context.allocator
	buf := context_test_make_buffer({"hello"}, allocator)
	defer context_test_destroy_buffer(buf, allocator)
	sel := context_test_make_selection({line = 0, column = 1}, {line = 0, column = 3})
	defer context_test_free_selection(&sel, allocator)
	sels := context_test_make_selections(buf, 0, {sel}, allocator)
	defer selection_list_destroy(&sels)
	handler := Input_Handler{}
	ctx := Context{}
	context_init(&ctx, &handler, sels, {}, "", allocator)
	defer context_destroy(&ctx)
	contents := context_selections_content(&ctx, allocator)
	testing.expect_value(t, len(contents), 1)
	testing.expect_value(t, contents[0], "ell")
	for c in contents {
		delete(c, allocator)
	}
	delete(contents)
}

@(test)
test_context_history_begin_edition_nested :: proc(t: ^testing.T) {
	allocator := context.allocator
	buf := context_test_make_buffer({"a"}, allocator)
	defer context_test_destroy_buffer(buf, allocator)
	sel := context_test_make_selection({}, {})
	defer context_test_free_selection(&sel, allocator)
	sels := context_test_make_selections(buf, 0, {sel}, allocator)
	defer selection_list_destroy(&sels)
	handler := Input_Handler{}
	ctx := Context{}
	context_init(&ctx, &handler, sels, {}, "", allocator)
	defer context_destroy(&ctx)
	hist := &ctx.selection_history

	// Nested begin only adds a level (no selections refresh, no stub).
	utils_nested_bool_set(&hist.in_edition)
	defer utils_nested_bool_unset(&hist.in_edition)
	defer utils_nested_bool_unset(&hist.in_edition)
	context_selection_history_begin_edition(hist, allocator)
	testing.expect_value(t, hist.in_edition.count, 2)
	_, has_staging := hist.staging.?
	testing.expect(t, !has_staging)
	// (Top-level begin snapshots refreshed selections: gap.)
}

@(test)
test_context_last_buffer :: proc(t: ^testing.T) {
	allocator := context.allocator
	buf_a := context_test_make_buffer({"a"}, allocator)
	defer context_test_destroy_buffer(buf_a, allocator)
	buf_b := context_test_make_buffer({"b"}, allocator)
	defer context_test_destroy_buffer(buf_b, allocator)
	sel := context_test_make_selection({}, {})
	defer context_test_free_selection(&sel, allocator)
	list_a := context_test_make_selections(buf_a, 0, {sel}, allocator)
	defer selection_list_destroy(&list_a)
	list_b := context_test_make_selections(buf_b, 0, {sel}, allocator)
	defer selection_list_destroy(&list_b)

	handler := Input_Handler{}
	ctx := Context{}
	context_init(&ctx, &handler, list_a, {}, "", allocator)
	defer context_destroy(&ctx)

	// Empty jump list: no last buffer.
	testing.expect(t, context_last_buffer(&ctx) == nil)

	context_jump_push(&ctx.jump_list, list_b, nil, allocator)
	context_jump_push(&ctx.jump_list, list_a, nil, allocator)
	context_jump_push(&ctx.jump_list, list_b, nil, allocator)
	// Current is buf_a; the pushes dedup to [A, B], forward search finds buf_b.
	testing.expect(t, context_last_buffer(&ctx) == buf_b)

	// Backward-only hit: everything from current-1 on is buf_a.
	jl := context_jump_list(&ctx)
	for &jump in jl.jumps {
		selection_list_destroy(&jump)
	}
	clear(&jl.jumps)
	context_jump_push(jl, list_b, nil, allocator)
	context_jump_push(jl, list_a, nil, allocator)
	// A distinct selection is needed for a third entry (equality ignores
	// main index and timestamp, so those cannot distinguish entries).
	sel_far := context_test_make_selection({line = 0, column = 5}, {line = 0, column = 5})
	defer context_test_free_selection(&sel_far, allocator)
	list_a_far := context_test_make_selections(buf_a, 0, {sel_far}, allocator)
	defer selection_list_destroy(&list_a_far)
	context_jump_push(jl, list_a_far, nil, allocator)
	jl.current = 2
	testing.expect(t, context_last_buffer(&ctx) == buf_b)
}

@(test)
test_context_history_initialize :: proc(t: ^testing.T) {
	allocator := context.allocator
	buf := context_test_make_buffer({"abc"}, allocator)
	defer context_test_destroy_buffer(buf, allocator)
	sel := context_test_make_selection({line = 0, column = 1}, {line = 0, column = 3}, {"c"})
	defer context_test_free_selection(&sel, allocator)
	sels := context_test_make_selections(buf, 0, {sel}, allocator)
	defer selection_list_destroy(&sels)

	ctx := Context{}
	context_init_empty(&ctx, allocator)
	defer context_destroy(&ctx)
	testing.expect(t, context_selection_history_empty(&ctx.selection_history))

	context_selection_history_initialize(&ctx.selection_history, sels, allocator)
	testing.expect(t, !context_selection_history_empty(&ctx.selection_history))
	got := context_selections(&ctx, false)
	testing.expect_value(t, len(got.selections), 1)
	testing.expect_value(t, len(got.selections[0].captures), 1)
	testing.expect_value(t, got.selections[0].captures[0], sels.selections[0].captures[0])
	testing.expect(t, context_buffer(&ctx) == buf)
}

// context_test_open_staging sets up an edition with a white-box staging
// node (the top-level begin path refreshes selections via the selection
// module, so tests drive staging directly). Takes ownership of sels.
context_test_open_staging :: proc(
	hist: ^Context_Selection_History,
	sels: [dynamic]Selection,
	main: int,
	buffer: ^Buffer,
	timestamp: int,
	parent: int,
	allocator := context.allocator,
	levels := 1,
) {
	hist.staging = Context_Selection_History_Node {
		list = Selection_List {
			main       = main,
			selections = sels,
			buffer     = buffer,
			timestamp  = timestamp,
			allocator  = allocator,
		},
		parent     = parent,
		redo_child = context_HISTORY_INVALID,
	}
	for _ in 0 ..< levels {
		utils_nested_bool_set(&hist.in_edition)
	}
}

@(test)
test_context_history_end_edition_no_change :: proc(t: ^testing.T) {
	allocator := context.allocator
	buf := context_test_make_buffer({"abc"}, allocator)
	defer context_test_destroy_buffer(buf, allocator)
	sel := context_test_make_selection({}, {line = 0, column = 1})
	defer context_test_free_selection(&sel, allocator)
	sels := context_test_make_selections(buf, 0, {sel}, allocator)
	defer selection_list_destroy(&sels)
	handler := Input_Handler{}
	ctx := Context{}
	context_init(&ctx, &handler, sels, {}, "", allocator)
	defer context_destroy(&ctx)
	hist := &ctx.selection_history

	// Unchanged selections with a new main index and timestamp: no new
	// node, current node refreshed.
	current := context_selections(&ctx, false)
	staging_sels := make([dynamic]Selection, 1, allocator)
	staging_sels[0] = Selection {
		basic = Basic_Selection{anchor = current.selections[0].anchor, cursor = current.selections[0].cursor},
	}
	context_test_open_staging(hist, staging_sels, 0, buf, 42, 0, allocator)
	context_selection_history_end_edition(hist)
	testing.expect_value(t, len(hist.history), 1)
	testing.expect_value(t, hist.history_id, 0)
	testing.expect_value(t, hist.history[0].list.timestamp, 42)
	_, has_staging := hist.staging.?
	testing.expect(t, !has_staging)
	testing.expect(t, !utils_nested_bool_is_set(hist.in_edition))
}

@(test)
test_context_history_end_edition_change :: proc(t: ^testing.T) {
	allocator := context.allocator
	buf := context_test_make_buffer({"abc"}, allocator)
	defer context_test_destroy_buffer(buf, allocator)
	sel := context_test_make_selection({}, {line = 0, column = 1})
	defer context_test_free_selection(&sel, allocator)
	sels := context_test_make_selections(buf, 0, {sel}, allocator)
	defer selection_list_destroy(&sels)
	handler := Input_Handler{}
	ctx := Context{}
	context_init(&ctx, &handler, sels, {}, "", allocator)
	defer context_destroy(&ctx)
	hist := &ctx.selection_history

	// Changed selections: staging becomes a new node linked to the old one.
	moved := context_test_make_selection({line = 0, column = 2}, {line = 0, column = 2})
	defer context_test_free_selection(&moved, allocator)
	staging_sels := make([dynamic]Selection, 1, allocator)
	staging_sels[0] = Selection {
		basic = Basic_Selection{anchor = moved.anchor, cursor = moved.cursor},
	}
	context_test_open_staging(hist, staging_sels, 0, buf, 9, hist.history_id, allocator)
	context_selection_history_end_edition(hist)
	testing.expect_value(t, len(hist.history), 2)
	testing.expect_value(t, hist.history_id, 1)
	testing.expect_value(t, hist.history[1].parent, 0)
	testing.expect_value(t, hist.history[1].list.timestamp, 9)
	testing.expect_value(t, hist.history[1].list.selections[0].anchor.column, Coord_Byte(2))
	testing.expect(t, hist.history[1].list.buffer == buf)
	got := context_selections(&ctx, false)
	testing.expect_value(t, got.selections[0].anchor.column, Coord_Byte(2))
}

@(test)
test_context_history_end_edition_nested :: proc(t: ^testing.T) {
	allocator := context.allocator
	buf := context_test_make_buffer({"abc"}, allocator)
	defer context_test_destroy_buffer(buf, allocator)
	sel := context_test_make_selection({}, {})
	defer context_test_free_selection(&sel, allocator)
	sels := context_test_make_selections(buf, 0, {sel}, allocator)
	defer selection_list_destroy(&sels)
	handler := Input_Handler{}
	ctx := Context{}
	context_init(&ctx, &handler, sels, {}, "", allocator)
	defer context_destroy(&ctx)
	hist := &ctx.selection_history

	staging_sels := make([dynamic]Selection, 1, allocator)
	staging_sels[0] = Selection {
		basic = Basic_Selection{
			anchor = Coord_Buffer{},
			cursor = coord_buffer_and_target(Coord_Buffer{}),
		},
	}
	context_test_open_staging(hist, staging_sels, 0, buf, 0, 0, allocator, 2)
	// First end only drops a level; staging survives.
	context_selection_history_end_edition(hist)
	testing.expect(t, utils_nested_bool_is_set(hist.in_edition))
	_, has_staging := hist.staging.?
	testing.expect(t, has_staging)
	testing.expect_value(t, len(hist.history), 1)
	// Second end commits (no change: same single default selection).
	context_selection_history_end_edition(hist)
	testing.expect(t, !utils_nested_bool_is_set(hist.in_edition))
	_, has_staging_after := hist.staging.?
	testing.expect(t, !has_staging_after)
	testing.expect_value(t, len(hist.history), 1)
}

@(test)
test_context_history_assign :: proc(t: ^testing.T) {
	allocator := context.allocator
	buf_a := context_test_make_buffer({"a"}, allocator)
	defer context_test_destroy_buffer(buf_a, allocator)
	buf_b := context_test_make_buffer({"b"}, allocator)
	defer context_test_destroy_buffer(buf_b, allocator)
	sel := context_test_make_selection({}, {})
	defer context_test_free_selection(&sel, allocator)
	list_a := context_test_make_selections(buf_a, 0, {sel}, allocator)
	defer selection_list_destroy(&list_a)
	moved := context_test_make_selection({line = 0, column = 1}, {line = 0, column = 1})
	defer context_test_free_selection(&moved, allocator)
	list_b := context_test_make_selections(buf_b, 0, {moved}, allocator)
	defer selection_list_destroy(&list_b)

	handler := Input_Handler{}
	ctx := Context{}
	context_init(&ctx, &handler, list_a, {}, "", allocator)
	defer context_destroy(&ctx)
	hist := &ctx.selection_history

	// No edition: current node replaced in place, buffer follows.
	context_selection_history_assign(hist, list_b, allocator)
	testing.expect_value(t, len(hist.history), 1)
	testing.expect_value(t, hist.history[0].list.selections[0].anchor.column, Coord_Byte(1))
	testing.expect(t, context_buffer(&ctx) == buf_b)

	// Open edition: staging replaced instead, current untouched.
	staging_sels := make([dynamic]Selection, 1, allocator)
	staging_sels[0] = Selection {
		basic = Basic_Selection{
			anchor = Coord_Buffer{},
			cursor = coord_buffer_and_target(Coord_Buffer{}),
		},
	}
	context_test_open_staging(hist, staging_sels, 0, buf_b, 0, 0, allocator)
	context_selection_history_assign(hist, list_a, allocator)
	testing.expect_value(t, hist.history[0].list.selections[0].anchor.column, Coord_Byte(1))
	staging, _ := hist.staging.?
	testing.expect_value(t, staging.list.selections[0].anchor.column, Coord_Byte(0))
	testing.expect(t, hist.history[0].list.buffer == buf_b)
	testing.expect(t, staging.list.buffer == buf_a)
	context_selection_history_end_edition(hist)
}

@(test)
test_context_history_forget_buffer :: proc(t: ^testing.T) {
	allocator := context.allocator
	buf_a := context_test_make_buffer({"a"}, allocator)
	defer context_test_destroy_buffer(buf_a, allocator)
	buf_b := context_test_make_buffer({"b"}, allocator)
	defer context_test_destroy_buffer(buf_b, allocator)
	sel := context_test_make_selection({}, {})
	defer context_test_free_selection(&sel, allocator)
	list_a := context_test_make_selections(buf_a, 0, {sel}, allocator)
	defer selection_list_destroy(&list_a)

	handler := Input_Handler{}
	ctx := Context{}
	context_init(&ctx, &handler, list_a, {}, "", allocator)
	defer context_destroy(&ctx)
	hist := &ctx.selection_history

	// White-box a three-node chain A -> B -> A with redo links.
	context_test_append_history_node(hist, buf_b, 0, allocator)
	context_test_append_history_node(hist, buf_a, 1, allocator)
	hist.history[0].redo_child = 1
	hist.history[1].redo_child = 2
	hist.history_id = 2
	staging_sels := make([dynamic]Selection, 1, allocator)
	staging_sels[0] = Selection {
		basic = Basic_Selection{
			anchor = Coord_Buffer{},
			cursor = coord_buffer_and_target(Coord_Buffer{}),
		},
	}
	context_test_open_staging(hist, staging_sels, 0, buf_a, 0, 1, allocator)

	context_selection_history_forget_buffer(hist, buf_b)
	testing.expect_value(t, len(hist.history), 2)
	testing.expect(t, hist.history[0].list.buffer == buf_a)
	testing.expect(t, hist.history[1].list.buffer == buf_a)
	// Old ids [0, 1, 2] remap to [0, invalid, 1].
	testing.expect_value(t, hist.history[0].redo_child, context_HISTORY_INVALID)
	testing.expect_value(t, hist.history[1].parent, context_HISTORY_INVALID)
	testing.expect_value(t, hist.history[1].redo_child, context_HISTORY_INVALID)
	testing.expect_value(t, hist.history_id, 1)
	staging, _ := hist.staging.?
	testing.expect_value(t, staging.parent, context_HISTORY_INVALID)
	context_selection_history_end_edition(hist)
}

// context_test_append_history_node appends a single-selection history node
// on buffer (white-box helper for forget_buffer tests).
context_test_append_history_node :: proc(
	hist: ^Context_Selection_History,
	buffer: ^Buffer,
	parent: int,
	allocator := context.allocator,
) {
	sels := make([dynamic]Selection, 1, allocator)
	sels[0] = Selection {
		basic = Basic_Selection{
			anchor = Coord_Buffer{},
			cursor = coord_buffer_and_target(Coord_Buffer{}),
		},
	}
	append(
		&hist.history,
		Context_Selection_History_Node {
			list = Selection_List {
				main       = 0,
				selections = sels,
				buffer     = buffer,
				timestamp  = len(buffer.changes),
				allocator  = allocator,
			},
			parent     = parent,
			redo_child = context_HISTORY_INVALID,
		},
	)
	hist.history_id = len(hist.history) - 1
}

@(test)
test_context_change_buffer_draft :: proc(t: ^testing.T) {
	allocator := context.allocator
	buf_a := context_test_make_buffer({"a"}, allocator)
	defer context_test_destroy_buffer(buf_a, allocator)
	buf_b := context_test_make_buffer({"b", "bb"}, allocator)
	defer context_test_destroy_buffer(buf_b, allocator)
	sel := context_test_make_selection({line = 0, column = 1}, {line = 0, column = 1})
	defer context_test_free_selection(&sel, allocator)
	list_a := context_test_make_selections(buf_a, 0, {sel}, allocator)
	defer selection_list_destroy(&list_a)

	// Draft, handler-less, scopeless: the direct path, no unmerged calls.
	ctx := Context{}
	context_init(&ctx, nil, list_a, {.Draft}, "", allocator)
	defer context_destroy(&ctx)

	// Same buffer: no-op.
	err := context_change_buffer(&ctx, buf_a)
	testing.expect_value(t, err, Context_Error.None)
	got_sels := context_selections(&ctx, false)
	testing.expect_value(t, got_sels.selections[0].anchor.column, Coord_Byte(1))

	// Switch: drafts overwrite the current node with fresh defaults.
	err = context_change_buffer(&ctx, buf_b)
	testing.expect_value(t, err, Context_Error.None)
	testing.expect_value(t, len(ctx.selection_history.history), 1)
	testing.expect(t, context_buffer(&ctx) == buf_b)
	got_sels = context_selections(&ctx, false)
	testing.expect_value(t, len(got_sels.selections), 1)
	testing.expect_value(t, got_sels.selections[0].anchor, Coord_Buffer{})
	testing.expect_value(t, got_sels.selections[0].cursor.target, Coord_Column(-1))
	testing.expect_value(t, got_sels.timestamp, len(buf_b.changes))

	// Empty history: the initialize path.
	empty := Context{}
	context_init_empty(&empty, allocator)
	defer context_destroy(&empty)
	empty.flags = {.Draft}
	err = context_change_buffer(&empty, buf_a)
	testing.expect_value(t, err, Context_Error.None)
	testing.expect(t, context_buffer(&empty) == buf_a)
}

@(test)
test_context_forget_buffer :: proc(t: ^testing.T) {
	allocator := context.allocator
	buf_a := context_test_make_buffer({"a"}, allocator)
	defer context_test_destroy_buffer(buf_a, allocator)
	buf_b := context_test_make_buffer({"b"}, allocator)
	defer context_test_destroy_buffer(buf_b, allocator)
	buf_c := context_test_make_buffer({"c"}, allocator)
	defer context_test_destroy_buffer(buf_c, allocator)
	sel := context_test_make_selection({}, {})
	defer context_test_free_selection(&sel, allocator)
	list_a := context_test_make_selections(buf_a, 0, {sel}, allocator)
	defer selection_list_destroy(&list_a)
	list_b := context_test_make_selections(buf_b, 0, {sel}, allocator)
	defer selection_list_destroy(&list_b)
	list_c := context_test_make_selections(buf_c, 0, {sel}, allocator)
	defer selection_list_destroy(&list_c)

	ctx := Context{}
	context_init(&ctx, nil, list_a, {.Draft}, "", allocator)
	defer context_destroy(&ctx)
	context_jump_push(&ctx.jump_list, list_b, nil, allocator)
	context_jump_push(&ctx.jump_list, list_c, nil, allocator)

	// Forgetting a non-current buffer drops it from jumps and history.
	err := context_forget_buffer(&ctx, buf_c)
	testing.expect_value(t, err, Context_Error.None)
	testing.expect_value(t, len(ctx.jump_list.jumps), 1)
	testing.expect(t, context_buffer(&ctx) == buf_a)

	// Forgetting the current buffer switches to the last jump buffer.
	err = context_forget_buffer(&ctx, buf_a)
	testing.expect_value(t, err, Context_Error.None)
	testing.expect(t, context_buffer(&ctx) == buf_b)
	testing.expect_value(t, len(ctx.jump_list.jumps), 1)
	testing.expect_value(t, len(ctx.selection_history.history), 1)
}

// context_test_last_select_data counts repeat_last_select invocations.
context_test_last_select_data :: struct {
	calls:     int,
	destroyed: bool,
}

context_test_last_select_call :: proc(data: rawptr, ctx: ^Context) {
	d := cast(^context_test_last_select_data)data
	d.calls += 1
	_ = ctx
}

context_test_last_select_destroy :: proc(data: rawptr, allocator: mem.Allocator) {
	d := cast(^context_test_last_select_data)data
	d.destroyed = true
	_ = allocator
}

@(test)
test_context_last_select :: proc(t: ^testing.T) {
	allocator := context.allocator
	ctx := Context{}
	context_init_empty(&ctx, allocator)
	// No callback: repeat is a no-op.
	context_repeat_last_select(&ctx)

	data := context_test_last_select_data{}
	context_set_last_select(&ctx, context_test_last_select_call, &data, context_test_last_select_destroy)
	context_repeat_last_select(&ctx)
	context_repeat_last_select(&ctx)
	testing.expect_value(t, data.calls, 2)
	testing.expect(t, !data.destroyed)
	// Replacing the callback destroys the previous one.
	other := context_test_last_select_data{}
	context_set_last_select(&ctx, context_test_last_select_call, &other)
	testing.expect(t, data.destroyed)
	testing.expect(t, !other.destroyed)
	context_repeat_last_select(&ctx)
	testing.expect_value(t, other.calls, 1)
	context_destroy(&ctx)
	// Plain (destroy-less) callback: nothing to run.
	testing.expect(t, !other.destroyed)
}

@(test)
test_context_scoped_selection_edition :: proc(t: ^testing.T) {
	allocator := context.allocator
	buf := context_test_make_buffer({"abc"}, allocator)
	defer context_test_destroy_buffer(buf, allocator)
	sel := context_test_make_selection({}, {})
	defer context_test_free_selection(&sel, allocator)
	sels := context_test_make_selections(buf, 0, {sel}, allocator)
	defer selection_list_destroy(&sels)

	// Draft contexts get an inert guard.
	draft := Context{}
	context_init(&draft, nil, sels, {.Draft}, "", allocator)
	defer context_destroy(&draft)
	draft_edition := context_scoped_selection_edition_make(&draft)
	testing.expect(t, !draft_edition.valid)
	context_scoped_selection_edition_destroy(&draft_edition)

	// Buffer-less contexts get an inert guard.
	empty := Context{}
	context_init_empty(&empty, allocator)
	defer context_destroy(&empty)
	empty_edition := context_scoped_selection_edition_make(&empty)
	testing.expect(t, !empty_edition.valid)
	context_scoped_selection_edition_destroy(&empty_edition)

	// Move transfers validity; destroying the target closes the edition.
	ctx := Context{}
	context_init(&ctx, nil, sels, {}, "", allocator)
	defer context_destroy(&ctx)
	hist := &ctx.selection_history
	staging_sels := make([dynamic]Selection, 1, allocator)
	staging_sels[0] = Selection {
		basic = Basic_Selection{
			anchor = Coord_Buffer{},
			cursor = coord_buffer_and_target(Coord_Buffer{}),
		},
	}
	context_test_open_staging(hist, staging_sels, 0, buf, 0, 0, allocator)
	edition := Scoped_Selection_Edition{ctx = &ctx, valid = true}
	moved := context_scoped_selection_edition_move(&edition)
	testing.expect(t, !edition.valid)
	testing.expect(t, moved.valid)
	testing.expect(t, moved.ctx == &ctx)
	context_scoped_selection_edition_destroy(&edition)
	testing.expect(t, utils_nested_bool_is_set(hist.in_edition))
	context_scoped_selection_edition_destroy(&moved)
	testing.expect(t, !utils_nested_bool_is_set(hist.in_edition))
	_, has_staging := hist.staging.?
	testing.expect(t, !has_staging)
}

