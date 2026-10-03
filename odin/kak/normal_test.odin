package kak

import "core:mem"
import "core:testing"

// Port of the C++ UnitTest group "merge_selection": merges new_sel
// into sel, the cursor follows new_sel and the anchor extends when
// both selections point the same way.
@(test)
normal_test_merge_selection :: proc(t: ^testing.T) {
	merge := proc(anchor, cursor, new_anchor, new_cursor: Coord_Buffer) -> Selection {
		sel := Selection{
			basic = Basic_Selection{anchor = anchor, cursor = coord_buffer_and_target(cursor)},
		}
		new_sel := Selection{
			basic = Basic_Selection{anchor = new_anchor, cursor = coord_buffer_and_target(new_cursor)},
		}
		normal_merge_selections(&sel, new_sel)
		return sel
	}
	expect := proc(t: ^testing.T, got: Selection, anchor, cursor: Coord_Buffer) {
		testing.expect_value(t, got.anchor, anchor)
		testing.expect_value(t, got.cursor.coord, cursor)
	}
	expect(t, merge({0, 1}, {0, 2}, {0, 3}, {0, 4}), {0, 1}, {0, 4})
	expect(t, merge({0, 1}, {0, 2}, {0, 1}, {0, 2}), {0, 1}, {0, 2})
	expect(t, merge({0, 1}, {0, 2}, {0, 0}, {0, 0}), {0, 1}, {0, 0})
	expect(t, merge({0, 1}, {0, 2}, {0, 0}, {0, 3}), {0, 0}, {0, 3})
	expect(t, merge({0, 1}, {0, 3}, {0, 4}, {0, 2}), {0, 1}, {0, 2})
	expect(t, merge({0, 1}, {0, 2}, {0, 1}, {0, 1}), {0, 1}, {0, 1})
	// Backward anchor extension: both point backward.
	expect(t, merge({0, 3}, {0, 1}, {0, 4}, {0, 0}), {0, 4}, {0, 0})
	// Mixed directions: the anchor does not move.
	expect(t, merge({0, 1}, {0, 3}, {0, 0}, {0, 0}), {0, 1}, {0, 0})
}

// Port of the C++ UnitTest group "apply_diff": forwards-only buffer
// updates driven by a line diff.
@(test)
normal_test_apply_diff :: proc(t: ^testing.T) {
	validate := proc(t: ^testing.T, line: int, new_text: string, expected_range: Buffer_Range, expected_changes: []Buffer_Change) {
		buffer := buffer_make(
			"", {}, []string{"line1\n", "line2\n", "line3\n"},
			.None, .Lf, .Present, File_Fs_Status{}, context.allocator,
		)
		defer buffer_destroy(buffer)
		timestamp := buffer_timestamp(buffer)
		old_lines := make([dynamic]string, 0, context.temp_allocator)
		defer delete(old_lines)
		for i := line; i < int(buffer_line_count(buffer)); i += 1 {
			append(&old_lines, buffer_line(buffer, Units_LineCount(i)))
		}
		new_range := normal_apply_diff(buffer, Coord_Buffer{Units_LineCount(line), 0}, old_lines[:], new_text)
		testing.expect_value(t, new_range, expected_range)
		changes := buffer_changes_since(buffer, timestamp)
		testing.expect_value(t, len(changes), len(expected_changes))
		for i in 0 ..< min(len(changes), len(expected_changes)) {
			testing.expect_value(t, changes[i], expected_changes[i])
		}
	}
	// When appending at end, we add any missing newline
	validate(
		t, 3, "added-line3-missing-eol", {{3, 0}, {4, 0}},
		[]Buffer_Change{{type = .Insert, begin = {3, 0}, end = {4, 0}}},
	)
	// Special case: erasing until buffer end also erases the final newline
	validate(
		t, 2, "", {{1, 5}, {1, 5}},
		[]Buffer_Change{{type = .Erase, begin = {2, 0}, end = {3, 0}}},
	)
	// Special case: when either the before and after end with a missing
	// newline, the diffs will still be treated as separate lines by
	// split_after('\n'), but ends exactly at the buffer end so the
	// modification will clamp to the end, and the missing newline will be
	// unchanged.
	validate(
		t, 2, "changed-line3\nadded-line4\nadded-line5\n", {{2, 0}, {5, 0}},
		[]Buffer_Change{
			{type = .Erase, begin = {2, 0}, end = {3, 0}},
			{type = .Insert, begin = {2, 0}, end = {5, 0}},
		},
	)
	validate(
		t, 2, "changed-line3\nadded-line4\nadded-line5-missing-eol", {{2, 0}, {5, 0}},
		[]Buffer_Change{
			{type = .Erase, begin = {2, 0}, end = {3, 0}},
			{type = .Insert, begin = {2, 0}, end = {5, 0}},
		},
	)
}

@(test)
normal_test_apply_diff_edge_cases :: proc(t: ^testing.T) {
	// Identical text: no changes, range collapses at pos.
	buffer := buffer_make(
		"", {}, []string{"aaa\n", "bbb\n"},
		.None, .Lf, .Present, File_Fs_Status{}, context.allocator,
	)
	defer buffer_destroy(buffer)
	old := []string{buffer_line(buffer, 0), buffer_line(buffer, 1)}
	timestamp := buffer_timestamp(buffer)
	rng := normal_apply_diff(buffer, Coord_Buffer{0, 0}, old, "aaa\nbbb\n")
	testing.expect_value(t, rng, Buffer_Range{{0, 0}, {2, 0}})
	changes := buffer_changes_since(buffer, timestamp)
	testing.expect_value(t, len(changes), 0)
	// Note: an empty buffer ([""]) has no valid {0,0} under the
	// port's buffer_is_valid (only the end coord {1,0} validates),
	// so apply_diff cannot run there; the C++ is_valid is looser.
	// Partial overlap: only the changed tail is rewritten.
	timestamp = buffer_timestamp(buffer)
	old = []string{buffer_line(buffer, 1)}
	rng = normal_apply_diff(buffer, Coord_Buffer{1, 0}, old, "CHANGED\n")
	testing.expect_value(t, buffer_line(buffer, 0), "aaa\n")
	testing.expect_value(t, buffer_line(buffer, 1), "CHANGED\n")
	changes = buffer_changes_since(buffer, timestamp)
	testing.expect_value(t, len(changes), 2)
}

@(test)
normal_test_paste_pos :: proc(t: ^testing.T) {
	buffer := buffer_make(
		"", {}, []string{"ab\n", "cd\n"},
		.None, .Lf, .Present, File_Fs_Status{}, context.allocator,
	)
	defer buffer_destroy(buffer)
	// Append goes after max; Insert stays at min.
	testing.expect_value(
		t, normal_paste_pos(buffer, Coord_Buffer{0, 0}, Coord_Buffer{0, 0}, .Append, false), Coord_Buffer{0, 1},
	)
	testing.expect_value(
		t, normal_paste_pos(buffer, Coord_Buffer{0, 1}, Coord_Buffer{0, 1}, .Insert, false), Coord_Buffer{0, 1},
	)
	// Append at buffer end stays at end.
	testing.expect_value(
		t, normal_paste_pos(buffer, Coord_Buffer{1, 2}, Coord_Buffer{2, 0}, .Append, false), Coord_Buffer{2, 0},
	)
	// Linewise: next line start for Append, own line start for Insert.
	testing.expect_value(
		t, normal_paste_pos(buffer, Coord_Buffer{0, 0}, Coord_Buffer{0, 1}, .Append, true), Coord_Buffer{1, 0},
	)
	testing.expect_value(
		t, normal_paste_pos(buffer, Coord_Buffer{0, 2}, Coord_Buffer{1, 2}, .Insert, true), Coord_Buffer{0, 0},
	)
	// Linewise Append on the last line clamps to the end.
	testing.expect_value(
		t, normal_paste_pos(buffer, Coord_Buffer{1, 0}, Coord_Buffer{1, 2}, .Append, true), Coord_Buffer{2, 0},
	)
}

@(test)
normal_test_get_command :: proc(t: ^testing.T) {
	cmd, ok := normal_get_command(Keys_Key{keys_MOD_NONE, 'h'})
	testing.expect(t, ok)
	testing.expect_value(t, cmd.docstring, "move left")
	testing.expect(t, cmd.func == normal_key_move_left)
	cmd, ok = normal_get_command(Keys_Key{keys_MOD_ALT, 'w'})
	testing.expect(t, ok)
	testing.expect_value(t, cmd.docstring, "select to next WORD start")
	cmd, ok = normal_get_command(Keys_Key{keys_MOD_CONTROL, 'l'})
	testing.expect(t, ok)
	testing.expect_value(t, cmd.docstring, "force redraw")
	cmd, ok = normal_get_command(Keys_Key{keys_MOD_NONE, keys_SPACE})
	testing.expect(t, ok)
	testing.expect_value(t, cmd.docstring, "user mappings")
	cmd, ok = normal_get_command(Keys_Key{keys_MOD_NONE, keys_PAGE_DOWN})
	testing.expect(t, ok)
	testing.expect_value(t, cmd.docstring, "scroll one page down")
	// Unknown keys report no command.
	_, ok = normal_get_command(Keys_Key{keys_MOD_NONE, keys_ESCAPE})
	testing.expect(t, !ok)
	_, ok = normal_get_command(Keys_Key{keys_MOD_CONTROL, 'z'})
	testing.expect(t, !ok)
	_, ok = normal_get_command(Keys_Key{keys_MOD_NONE, 0x0})
	testing.expect(t, !ok)
	// The table holds the full C++ keymap (150 entries) exactly once.
	testing.expect_value(t, len(normal_keymap_entries), 150)
	for i in 0 ..< len(normal_keymap_entries) {
		testing.expect(t, normal_keymap_entries[i].cmd.func != nil)
		for j in i + 1 ..< len(normal_keymap_entries) {
			testing.expect(t, normal_keymap_entries[i].key != normal_keymap_entries[j].key)
		}
	}
}

@(test)
normal_test_combine_ops :: proc(t: ^testing.T) {
	check := proc(t: ^testing.T, code: rune, expected: normal_Combine_Op) {
		op, ok := normal_key_to_combine_op(Keys_Key{keys_MOD_NONE, code})
		testing.expect(t, ok)
		testing.expect_value(t, op, expected)
	}
	check(t, 'a', .Append)
	check(t, 'u', .Union)
	check(t, 'i', .Intersect)
	check(t, '<', .Select_Leftmost_Cursor)
	check(t, '>', .Select_Rightmost_Cursor)
	check(t, '+', .Select_Longest)
	check(t, '-', .Select_Shortest)
	_, ok := normal_key_to_combine_op(Keys_Key{keys_MOD_NONE, 'z'})
	testing.expect(t, !ok)
	// Only the key code matters, like the C++ switch.
	op, ok2 := normal_key_to_combine_op(Keys_Key{keys_MOD_ALT, 'a'})
	testing.expect(t, ok2)
	testing.expect_value(t, op, normal_Combine_Op.Append)
}

@(test)
normal_test_combine_selection :: proc(t: ^testing.T) {
	buffer := buffer_make(
		"", {}, []string{"hello world\n"},
		.None, .Lf, .Present, File_Fs_Status{}, context.allocator,
	)
	defer buffer_destroy(buffer)
	make_sel := proc(anchor, cursor: Coord_Buffer) -> Selection {
		return Selection{basic = Basic_Selection{anchor = anchor, cursor = coord_buffer_and_target(cursor)}}
	}
	sel := make_sel({0, 0}, {0, 4})
	other := make_sel({0, 6}, {0, 10})
	normal_combine_selection(buffer, &sel, other, .Union)
	testing.expect_value(t, sel.anchor, Coord_Buffer{0, 0})
	testing.expect_value(t, sel.cursor.coord, Coord_Buffer{0, 10})
	sel = make_sel({0, 0}, {0, 4})
	normal_combine_selection(buffer, &sel, other, .Intersect)
	testing.expect_value(t, sel.anchor, Coord_Buffer{0, 6})
	testing.expect_value(t, sel.cursor.coord, Coord_Buffer{0, 4})
	// Leftmost keeps sel, rightmost takes other.
	sel = make_sel({0, 0}, {0, 4})
	normal_combine_selection(buffer, &sel, other, .Select_Leftmost_Cursor)
	testing.expect_value(t, sel.cursor.coord, Coord_Buffer{0, 4})
	sel = make_sel({0, 0}, {0, 4})
	normal_combine_selection(buffer, &sel, other, .Select_Rightmost_Cursor)
	testing.expect_value(t, sel.cursor.coord, Coord_Buffer{0, 10})
	// Longest/shortest compare covered lengths ("hello" vs "world").
	sel = make_sel({0, 0}, {0, 4})
	longer := make_sel({0, 0}, {0, 10})
	normal_combine_selection(buffer, &sel, longer, .Select_Longest)
	testing.expect_value(t, sel.cursor.coord, Coord_Buffer{0, 10})
	sel = make_sel({0, 0}, {0, 4})
	normal_combine_selection(buffer, &sel, longer, .Select_Shortest)
	testing.expect_value(t, sel.cursor.coord, Coord_Buffer{0, 4})
}

@(test)
normal_test_swap_case :: proc(t: ^testing.T) {
	testing.expect_value(t, normal_swap_case('a'), 'A')
	testing.expect_value(t, normal_swap_case('Z'), 'z')
	testing.expect_value(t, normal_swap_case('5'), '5')
	testing.expect_value(t, normal_swap_case('é'), 'É')
}

@(test)
normal_test_parse_object_desc :: proc(t: ^testing.T) {
	check := proc(t: ^testing.T, input, expected_open, expected_close: string) {
		open, close, ok := normal_parse_object_desc(input)
		defer delete(open)
		defer delete(close)
		testing.expect(t, ok)
		testing.expect_value(t, open, expected_open)
		testing.expect_value(t, close, expected_close)
	}
	check(t, "[(],[)]", "[(]", "[)]")
	// Escaped commas stay literal.
	check(t, "a\\,b,c", "a,b", "c")
	_, _, ok := normal_parse_object_desc("no-separator")
	testing.expect(t, !ok)
	_, _, ok = normal_parse_object_desc(",")
	testing.expect(t, !ok)
	_, _, ok = normal_parse_object_desc("open,")
	testing.expect(t, !ok)
	_, _, ok = normal_parse_object_desc("")
	testing.expect(t, !ok)
}

@(test)
normal_test_split_after_lines :: proc(t: ^testing.T) {
	check := proc(t: ^testing.T, input: string, expected: []string) {
		res := normal_split_after_lines(input)
		defer delete(res)
		testing.expect_value(t, len(res), len(expected))
		for i in 0 ..< min(len(res), len(expected)) {
			testing.expect_value(t, res[i], expected[i])
		}
	}
	check(t, "a\nb\n", []string{"a\n", "b\n"})
	check(t, "a\nb", []string{"a\n", "b"})
	check(t, "", []string{})
	check(t, "abc", []string{"abc"})
}

@(test)
normal_test_diff_lines :: proc(t: ^testing.T) {
	Collector :: struct {
		ops: [dynamic]Diff_Diff,
	}
	collect := proc(state: rawptr, op: Diff_Op, len: int) {
		c := cast(^Collector)(state)
		append(&c.ops, Diff_Diff{op, len})
	}
	c := Collector{}
	defer delete(c.ops)
	check_script := proc(
		t: ^testing.T,
		c: ^Collector,
		a, b: []string,
		expected: []Diff_Diff,
		on_diff: proc(state: rawptr, op: Diff_Op, len: int),
	) {
		clear(&c.ops)
		normal_diff_lines(a, b, c, on_diff)
		testing.expect_value(t, len(c.ops), len(expected))
		for i in 0 ..< min(len(c.ops), len(expected)) {
			testing.expect_value(t, c.ops[i], expected[i])
		}
	}
	check_script(t, &c, []string{"x\n"}, []string{"x\n"}, []Diff_Diff{{.Keep, 1}}, collect)
	check_script(t, &c, []string{}, []string{"y\n"}, []Diff_Diff{{.Add, 1}}, collect)
	check_script(t, &c, []string{"x\n"}, []string{}, []Diff_Diff{{.Remove, 1}}, collect)
	check_script(t, &c, []string{}, []string{}, []Diff_Diff{}, collect)
	// Any script must account for every input line exactly once.
	before := []string{"a\n", "b\n", "c\n"}
	after := []string{"c\n", "a\n", "d\n"}
	normal_diff_lines(before, after, &c, collect)
	kept_removed, kept_added := 0, 0
	for step in c.ops {
		if step.op == .Keep {
			kept_removed += step.len
			kept_added += step.len
		} else if step.op == .Remove {
			kept_removed += step.len
		} else {
			kept_added += step.len
		}
	}
	testing.expect_value(t, kept_removed, len(before))
	testing.expect_value(t, kept_added, len(after))
}

@(test)
normal_test_error_message_and_flags :: proc(t: ^testing.T) {
	testing.expect_value(t, normal_error_message(.None), "no error")
	testing.expect_value(t, normal_error_message(.No_Selections_Remaining), "no selections remaining")
	testing.expect_value(t, normal_error_message(.Invalid_Argument), "invalid argument")
	testing.expect_value(t, normal_error_message(.Failed), "operation failed")
	testing.expect_value(t, normal_direction_flags(true), Regex_Vm_Compile_Flags{})
	testing.expect_value(t, normal_direction_flags(false), Regex_Vm_Compile_Flags{.Backward, .No_Forward})
}

// normal_test_ctx builds a buffer with the options normal commands
// need (tabstop, indentwidth, incsearch), one collapsed selection at
// anchor/cursor, and an owning context.
normal_test_ctx :: struct {
	buffer:    ^Buffer,
	ctx:       Context,
	allocator: mem.Allocator,
}

normal_test_ctx_make :: proc(
	lines: []string,
	anchor, cursor: Coord_Buffer,
	allocator := context.allocator,
) -> normal_test_ctx {
	buffer := buffer_make("", {}, lines, .None, .Lf, .Present, File_Fs_Status{}, allocator)
	mgr := &buffer.scope.data.options
	install_int := proc(mgr: ^Option_Manager, name: string, value: int, allocator: mem.Allocator) {
		desc := new(Option_Desc, allocator)
		desc^ = Option_Desc{name = name}
		opt := new(Option, allocator)
		opt^ = Option{desc = desc, manager = mgr, value = value, allocator = allocator}
		mgr.options[name] = opt
	}
	install_int(mgr, "tabstop", 8, allocator)
	install_int(mgr, "indentwidth", 2, allocator)
	sel := Selection{
		basic = Basic_Selection{anchor = anchor, cursor = coord_buffer_and_target(cursor)},
	}
	list := selection_list_make(buffer, []Selection{sel}, buffer_timestamp(buffer), allocator)
	ctx := Context{}
	context_init(&ctx, nil, list, {}, "", allocator)
	// context_init clones into the history; the source list is ours.
	selection_list_destroy(&list)
	return normal_test_ctx{buffer, ctx, allocator}
}

normal_test_ctx_destroy :: proc(fix: ^normal_test_ctx) {
	context_destroy(&fix.ctx)
	mgr := &fix.buffer.scope.data.options
	for _, opt in mgr.options {
		desc := opt.desc
		option_manager_option_destroy(opt)
		free(desc, fix.allocator)
	}
	clear(&mgr.options)
	buffer_destroy(fix.buffer)
}

@(test)
normal_test_move_cursor :: proc(t: ^testing.T) {
	fix := normal_test_ctx_make([]string{"hello\n"}, {0, 0}, {0, 0})
	defer normal_test_ctx_destroy(&fix)
	// Selections are re-fetched after every command: editions commit
	// through the history, invalidating earlier pointers.
	cur := context_selections(&fix.ctx).selections[0]
	testing.expect_value(t, cur.cursor.coord, Coord_Buffer{0, 0})
	// Count 0 moves once; counts scale; <= 0 clamps to one step.
	normal_move_cursor(&fix.ctx, Normal_Params{count = 0}, .Forward, .Replace, false)
	cur = context_selections(&fix.ctx).selections[0]
	testing.expect_value(t, cur.cursor.coord, Coord_Buffer{0, 1})
	testing.expect_value(t, cur.anchor, Coord_Buffer{0, 1})
	normal_move_cursor(&fix.ctx, Normal_Params{count = 3}, .Forward, .Replace, false)
	cur = context_selections(&fix.ctx).selections[0]
	testing.expect_value(t, cur.cursor.coord, Coord_Buffer{0, 4})
	normal_move_cursor(&fix.ctx, Normal_Params{count = -5}, .Forward, .Replace, false)
	cur = context_selections(&fix.ctx).selections[0]
	testing.expect_value(t, cur.cursor.coord, Coord_Buffer{0, 5})
	// Clamp at the buffer back; Extend keeps the anchor.
	normal_move_cursor(&fix.ctx, Normal_Params{count = 100}, .Forward, .Replace, false)
	cur = context_selections(&fix.ctx).selections[0]
	testing.expect_value(t, cur.cursor.coord, Coord_Buffer{0, 5})
	normal_move_cursor(&fix.ctx, Normal_Params{count = 2}, .Backward, .Extend, false)
	cur = context_selections(&fix.ctx).selections[0]
	testing.expect_value(t, cur.cursor.coord, Coord_Buffer{0, 3})
	testing.expect_value(t, cur.anchor, Coord_Buffer{0, 5})
	normal_move_cursor(&fix.ctx, Normal_Params{count = 100}, .Backward, .Replace, false)
	cur = context_selections(&fix.ctx).selections[0]
	testing.expect_value(t, cur.cursor.coord, Coord_Buffer{0, 0})
}

@(test)
normal_test_select_coord :: proc(t: ^testing.T) {
	fix := normal_test_ctx_make([]string{"ab\n", "cd\n"}, {0, 0}, {0, 1})
	defer normal_test_ctx_destroy(&fix)
	normal_select_coord(&fix.ctx, Coord_Buffer{1, 1})
	sels := context_selections(&fix.ctx)
	testing.expect_value(t, len(sels.selections), 1)
	testing.expect_value(t, sels.selections[0].anchor, Coord_Buffer{1, 1})
	testing.expect_value(t, sels.selections[0].cursor.coord, Coord_Buffer{1, 1})
	normal_select_coord(&fix.ctx, Coord_Buffer{0, 0}, .Extend)
	sels = context_selections(&fix.ctx)
	testing.expect_value(t, sels.selections[0].anchor, Coord_Buffer{1, 1})
	testing.expect_value(t, sels.selections[0].cursor.coord, Coord_Buffer{0, 0})
	// Out of range clamps into the buffer.
	normal_select_coord(&fix.ctx, Coord_Buffer{99, 99})
	sels = context_selections(&fix.ctx)
	testing.expect_value(t, sels.selections[0].anchor, buffer_back_coord(fix.buffer))
}

@(test)
normal_test_clear_flip_ensure :: proc(t: ^testing.T) {
	fix := normal_test_ctx_make([]string{"hello\n"}, {0, 1}, {0, 3})
	defer normal_test_ctx_destroy(&fix)
	normal_cmd_clear_selections(&fix.ctx, Normal_Params{})
	cur := context_selections(&fix.ctx).selections[0]
	testing.expect_value(t, cur.anchor, Coord_Buffer{0, 3})
	normal_cmd_flip_selections(&fix.ctx, Normal_Params{})
	cur = context_selections(&fix.ctx).selections[0]
	testing.expect_value(t, cur.anchor, Coord_Buffer{0, 3})
	testing.expect_value(t, cur.cursor.coord, Coord_Buffer{0, 3})
	context_selections(&fix.ctx).selections[0] = Selection{
		basic = Basic_Selection{anchor = Coord_Buffer{0, 3}, cursor = coord_buffer_and_target(Coord_Buffer{0, 1})},
	}
	normal_cmd_ensure_forward(&fix.ctx, Normal_Params{})
	cur = context_selections(&fix.ctx).selections[0]
	// Faithful to the C++: max() is read after anchor() was
	// overwritten with min(), so backward selections collapse.
	testing.expect_value(t, cur.anchor, Coord_Buffer{0, 1})
	testing.expect_value(t, cur.cursor.coord, Coord_Buffer{0, 1})
}

@(test)
normal_test_indent_deindent :: proc(t: ^testing.T) {
	fix := normal_test_ctx_make([]string{"a\n", "b\n"}, {0, 0}, {1, 0})
	defer normal_test_ctx_destroy(&fix)
	normal_cmd_indent(&fix.ctx, Normal_Params{}, false)
	testing.expect_value(t, buffer_line(fix.buffer, 0), "  a\n")
	testing.expect_value(t, buffer_line(fix.buffer, 1), "  b\n")
	normal_cmd_deindent(&fix.ctx, Normal_Params{}, true)
	testing.expect_value(t, buffer_line(fix.buffer, 0), "a\n")
	testing.expect_value(t, buffer_line(fix.buffer, 1), "b\n")
	// Explicit count scales the indent.
	normal_cmd_indent(&fix.ctx, Normal_Params{count = 2}, false)
	testing.expect_value(t, buffer_line(fix.buffer, 0), "    a\n")
}

@(test)
normal_test_select_whole_buffer :: proc(t: ^testing.T) {
	fix := normal_test_ctx_make([]string{"ab\n", "cd\n"}, {1, 1}, {1, 1})
	defer normal_test_ctx_destroy(&fix)
	normal_cmd_select_whole_buffer(&fix.ctx, Normal_Params{})
	sels := context_selections(&fix.ctx)
	testing.expect_value(t, len(sels.selections), 1)
	testing.expect_value(t, sels.selections[0].anchor, Coord_Buffer{0, 0})
	testing.expect_value(t, sels.selections[0].cursor.coord, buffer_back_coord(fix.buffer))
}

@(test)
normal_test_allocator_cleanup :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	alloc := mem.tracking_allocator(&track)
	defer mem.tracking_allocator_destroy(&track)
	{
		// Diff scratch and split lines free fully.
		a := []string{"a\n", "b\n"}
		Collector :: struct {
			ops: [dynamic]Diff_Diff,
		}
		collect := proc(state: rawptr, op: Diff_Op, len: int) {
			c := cast(^Collector)(state)
			append(&c.ops, Diff_Diff{op, len})
		}
		c := Collector{ops = make([dynamic]Diff_Diff, alloc)}
		normal_diff_lines(a, []string{"b\n", "c\n"}, &c, collect, alloc)
		delete(c.ops)
		lines := normal_split_after_lines("a\nb\n", alloc)
		delete(lines)
		open, close, ok := normal_parse_object_desc("[(],[)]", alloc)
		testing.expect(t, ok)
		delete(open, alloc)
		delete(close, alloc)
		sel := Selection{
			basic = Basic_Selection{anchor = Coord_Buffer{0, 1}, cursor = coord_buffer_and_target(Coord_Buffer{0, 2})},
		}
		other := Selection{
			basic = Basic_Selection{anchor = Coord_Buffer{0, 3}, cursor = coord_buffer_and_target(Coord_Buffer{0, 4})},
		}
		normal_merge_selections(&sel, other)
	}
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
normal_test_regex_validate_no_match_stashes_error :: proc(t: ^testing.T) {
	// A validating select with no matches must fail the exec (the C++
	// assigns the empty selection list and the next command throws);
	// the port keeps selections non-empty and stashes the error instead.
	fix := normal_test_ctx_make([]string{"hello\n"}, {0, 0}, {0, 0})
	defer normal_test_ctx_destroy(&fix)
	// normal_regex_call reads incsearch; the fixture only installs
	// tabstop/indentwidth.
	mgr := &fix.buffer.scope.data.options
	idesc := new(Option_Desc, context.allocator)
	idesc^ = Option_Desc{name = "incsearch"}
	iopt := new(Option, context.allocator)
	iopt^ = Option{desc = idesc, manager = mgr, value = false, allocator = context.allocator}
	mgr.options["incsearch"] = iopt
	if !test_commands_register_hold() {
		testing.expect(t, false, "register singleton stayed busy")
		return
	}
	defer test_commands_register_release()
	register_manager_add(
		register_manager_instance(), '/', register_manager_make_history("/", context.allocator),
	)
	h := Input_Handler{allocator = context.allocator}
	defer input_handler_clear_key_error(&h)
	fix.ctx.input_handler = &h
	saved := selection_list_clone(context_selections(&fix.ctx))
	defer selection_list_destroy(&saved)
	d := normal_Regex_Data{
		kind = .Select,
		reg = '/',
		forward = true,
		mode = .Replace,
		default_pattern = "zzz-no-match",
		saved_selections = saved,
		allocator = context.allocator,
	}
	normal_regex_call(&d, "", .Validate, &fix.ctx)
	err, msg, ok := input_handler_take_key_error(&h, context.allocator)
	defer delete(msg)
	testing.expect(t, ok, "validating select with no matches must stash a key error")
	testing.expect_value(t, err, Commands_Error.Error)
	testing.expect_value(t, msg, "nothing selected")
}

@(test)
normal_test_prompt_env_vars_own_keys :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	alloc := mem.tracking_allocator(&track)
	defer mem.tracking_allocator_destroy(&track)
	env_vars := normal_count_register_env_vars(3, 'a', alloc)
	// Every key and value must be a tracked heap allocation: static
	// keys would be freed by env_vars_free and corrupt the heap.
	for k, v in env_vars {
		testing.expect(t, rawptr(raw_data(k)) in track.allocation_map, "prompt env key is not heap-owned")
		testing.expect(t, rawptr(raw_data(v)) in track.allocation_map, "prompt env value is not heap-owned")
	}
	testing.expect_value(t, env_vars["count"], "3")
	testing.expect_value(t, env_vars["register"], "a")
	env_vars_free(&env_vars, alloc)
	testing.expect_value(t, len(track.allocation_map), 0)
}
