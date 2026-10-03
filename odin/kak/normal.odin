// Port of Kakoune's src/normal.{hh,cc}: normal-mode commands, the
// NormalCmd keymap dispatch, goto/view/object/regex prompts, and paste.
//
// Mapping notes:
//   * C++ throws (runtime_error, no_selections_remaining) at the void
//     NormalCmd boundary become status-line reports through
//     normal_fail: the C++ main loop catches escaping exceptions and
//     shows them, which is exactly what normal_fail does. Fallible
//     helpers return Normal_Error so tests can assert on them.
//   * C++ Optional<Selection> becomes (Selection, bool); C++ lambdas
//     capturing counts/flags become normal_Select_Func procs taking an
//     explicit data pointer, with heap data structs for the prompt and
//     on-next-key callbacks (prompt/hook ownership matches knot.odin:
//     the callback structs are owned by the mode, freed by destroy).
//   * C++ templates on SelectMode/Direction/WordType/bool become
//     runtime parameters; each keymap entry is a thin named wrapper
//     (Normal_Cmd.func is a plain proc pointer, no closures).
//   * apply_diff ports for_each_diff instantiated on lines as
//     normal_diff_lines_*: the merged diff module is byte-specialized
//     and cannot express line runs.
//   * Selection anchor/cursor/min/max reuse the input_handler helpers
//     (input_handler_sel_min/max/set_min_max, selection_from_coord);
//     register reads/writes go through register_manager_*.
//
// Ownership:
//   * Command procs (normal_cmd_*) borrow ctx and report failures on
//     the status line; they return nothing (knot.odin Normal_Cmd).
//   * normal_build_autoinfo_for_mapping and normal_apply_diff helpers
//     return owned strings; free with the passed allocator.
//   * Callback data structs own their strings/lists; each has a
//     paired destroy proc run by the owning mode.
package kak

import "core:mem"
import "core:slice"
import "core:strings"

// Normal_Error reports normal-mode failures. Zero value None is
// success. The C++ throws runtime_error (message preserved by the
// caller through normal_fail) and no_selections_remaining.
Normal_Error :: enum {
	None,
	// The selection set came back empty (C++ no_selections_remaining).
	No_Selections_Remaining,
	// A register, capture, index or pattern argument was invalid.
	Invalid_Argument,
	// Buffer, regex, shell, diff or option failure; details are
	// reported on the status line at the throw site.
	Failed,
}

// normal_error_message describes err.
normal_error_message :: proc(err: Normal_Error) -> string {
	switch err {
	case .None:
		return "no error"
	case .No_Selections_Remaining:
		return "no selections remaining"
	case .Invalid_Argument:
		return "invalid argument"
	case .Failed:
		return "operation failed"
	}
	unreachable()
}

// normal_Select_Mode ports C++ SelectMode.
normal_Select_Mode :: enum {
	Replace,
	Extend,
	Append,
}

// normal_Select_Flags ports C++ SelectFlags (select to next char).
normal_Select_Flags :: bit_set[normal_Select_Flag; u8]

normal_Select_Flag :: enum {
	Reverse,
	Inclusive,
	Extend,
}

// normal_Select_Func selects from sel (port of the select() functor).
// data carries captured state (nil for plain motions); the returned
// bool reports whether a selection was produced. Returned captures
// are moved into the selection: they must be nil or owned by the
// selections allocator (every adapter below returns nil captures).
normal_Select_Func :: #type proc(data: rawptr, ctx: ^Context, sel: Selection) -> (Selection, bool)

// normal_fail reports a command failure on the status line (port of
// the C++ main-loop catch around key handling: show and abort).
normal_fail :: proc(ctx: ^Context, msg: string) {
	if ctx.client == nil {
		return
	}
	// Atoms use context.allocator (client_display_line_destroy deletes
	// them with it); atom text is borrowed, like the C++ StringView.
	prompt := client_display_line_from_text("", Face{})
	content := client_display_line_from_text(msg, Face{})
	client_print_status(ctx.client, prompt, content, Units_ColumnCount(0), .Status)
}

// normal_print_info shows an informational status message (port of
// context.print_status({text, faces()["Information"]})).
normal_print_info :: proc(ctx: ^Context, text: string) {
	if ctx.client == nil {
		return
	}
	face := input_handler_face(context_faces(ctx), "Information")
	prompt := client_display_line_from_text("", Face{})
	content := client_display_line_from_text(text, face)
	client_print_status(ctx.client, prompt, content, Units_ColumnCount(0), .Status)
}

// normal_alloc is the allocator for callback data owned by modes:
// the input handler's, falling back to the context's.
normal_alloc :: proc(ctx: ^Context) -> mem.Allocator {
	if ctx.input_handler != nil {
		return ctx.input_handler.allocator
	}
	return ctx.allocator
}

// normal_sel_content returns the owned text covered by sel, inclusive
// of both ends (port of content(buffer, sel)).
normal_sel_content :: proc(b: ^Buffer, sel: Selection, allocator := context.allocator) -> string {
	s := sel
	sel_min := input_handler_sel_min(&s)
	sel_max := input_handler_sel_max(&s)
	return buffer_string(b, sel_min, buffer_char_next(b, sel_max), allocator)
}

// normal_char_length counts the codepoints covered by sel, inclusive
// (port of char_length(buffer, sel)).
normal_char_length :: proc(b: ^Buffer, sel: Selection) -> int {
	content := normal_sel_content(b, sel, context.temp_allocator)
	defer delete(content, context.temp_allocator)
	return utf8_distance(content)
}

// normal_merge_selections merges new_sel into sel (port of
// merge_selections): the cursor follows new_sel; the anchor extends
// when both selections point the same way.
normal_merge_selections :: proc(sel: ^Selection, new_sel: Selection) {
	forward := coord_compare(sel.cursor.coord, sel.anchor) >= 0
	new_forward := coord_compare(new_sel.cursor.coord, new_sel.anchor) > 0
	if forward && new_forward {
		sel.anchor = sel.anchor if coord_compare(sel.anchor, new_sel.anchor) <= 0 else new_sel.anchor
	}
	backward := coord_compare(sel.cursor.coord, sel.anchor) <= 0
	new_backward := coord_compare(new_sel.cursor.coord, new_sel.anchor) < 0
	if backward && new_backward {
		sel.anchor = sel.anchor if coord_compare(sel.anchor, new_sel.anchor) >= 0 else new_sel.anchor
	}
	sel.cursor = new_sel.cursor
}

// normal_select applies func to the selections (port of select()).
// Replace rewrites anchor+cursor, Extend merges, Append adds one
// selection after main. Captures move from the result into the
// selection, like the C++.
normal_select :: proc(ctx: ^Context, mode: normal_Select_Mode, func: normal_Select_Func, data: rawptr = nil) -> Normal_Error {
	edition := context_scoped_selection_edition_make(ctx)
	defer context_scoped_selection_edition_destroy(&edition)
	sels := context_selections(ctx)
	if mode == .Append {
		main := &sels.selections[sels.main]
		res, ok := func(data, ctx, main^)
		if ok {
			if len(res.captures) == 0 {
				res.captures = make([dynamic]string, 0, len(main.captures), sels.allocator)
				for c in main.captures {
					append(&res.captures, strings.clone(c, sels.allocator))
				}
			}
			append(&sels.selections, res)
			sels.main = len(sels.selections) - 1
		}
	} else {
		main_index := sels.main
		new_size := 0
		for i := 0; i < len(sels.selections); i += 1 {
			res, ok := func(data, ctx, sels.selections[i])
			if !ok {
				for c in res.captures {
					delete(c, sels.allocator)
				}
				delete(res.captures)
				if i <= main_index && main_index != 0 {
					main_index -= 1
				}
				continue
			}
			sel := &sels.selections[i]
			if mode == .Extend {
				normal_merge_selections(sel, res)
			} else {
				sel.anchor = res.anchor
				sel.cursor = res.cursor
			}
			if len(res.captures) != 0 {
				selection_destroy(sel, sels.allocator)
				sel.captures = res.captures
			}
			if i != new_size {
				selection_destroy(&sels.selections[new_size], sels.allocator)
				sels.selections[new_size] = sel^
				sel.captures = nil
			}
			new_size += 1
		}
		if new_size == 0 {
			return .No_Selections_Remaining
		}
		for i := new_size; i < len(sels.selections); i += 1 {
			selection_destroy(&sels.selections[i], sels.allocator)
		}
		resize(&sels.selections, new_size)
		sels.main = main_index
	}
	selection_list_sort_and_merge_overlapping(sels)
	selection_list_check_invariant(sels)
	return .None
}

// normal_Last_Select_Data replays a selection command (port of the
// set_last_select lambdas). data/destroy describe the captured
// functor state; both may be nil.
normal_Last_Select_Data :: struct {
	mode:    normal_Select_Mode,
	func:    normal_Select_Func,
	data:    rawptr,
	destroy: proc(data: rawptr, allocator: mem.Allocator),
}

normal_last_select_call :: proc(data: rawptr, ctx: ^Context) {
	d := cast(^normal_Last_Select_Data)(data)
	if err := normal_select(ctx, d.mode, d.func, d.data); err != .None {
		normal_fail(ctx, normal_error_message(err))
	}
}

normal_last_select_destroy :: proc(data: rawptr, allocator: mem.Allocator) {
	d := cast(^normal_Last_Select_Data)(data)
	if d.destroy != nil {
		d.destroy(d.data, allocator)
	}
	free(d, allocator)
}

// normal_select_and_set_last selects and records the repeatable
// command (port of select_and_set_last). clone copies data for the
// record when non-nil (data itself stays with the caller).
normal_select_and_set_last :: proc(
	ctx: ^Context,
	mode: normal_Select_Mode,
	func: normal_Select_Func,
	data: rawptr = nil,
	destroy: proc(data: rawptr, allocator: mem.Allocator) = nil,
	clone: proc(data: rawptr, allocator: mem.Allocator) -> rawptr = nil,
) -> Normal_Error {
	record: ^normal_Last_Select_Data = new(normal_Last_Select_Data, ctx.allocator)
	record.mode = mode
	record.func = func
	if clone != nil {
		record.data = clone(data, ctx.allocator)
		record.destroy = destroy
	}
	context_set_last_select(ctx, normal_last_select_call, record, normal_last_select_destroy)
	return normal_select(ctx, mode, func, data)
}

// normal_select_coord collapses the selections onto coord (port of
// select_coord): Replace selects it, Extend moves every cursor to it.
normal_select_coord :: proc(ctx: ^Context, coord: Coord_Buffer, mode: normal_Select_Mode = .Replace) {
	edition := context_scoped_selection_edition_make(ctx)
	defer context_scoped_selection_edition_destroy(&edition)
	sels := context_selections(ctx)
	clamped := buffer_clamp(context_buffer(ctx), coord)
	if mode == .Replace {
		sel := input_handler_selection_from_coord(clamped)
		selection_list_set(sels, []Selection{sel}, 0)
	} else if mode == .Extend {
		for &sel in sels.selections {
			sel.cursor = coord_buffer_and_target(clamped)
		}
		selection_list_sort_and_merge_overlapping(sels)
	}
}

// normal_enter_insert_mode enters insert mode count times (port of
// enter_insert_mode<mode>).
normal_enter_insert_mode :: proc(ctx: ^Context, params: Normal_Params, mode: Input_Handler_Insert_Mode) {
	if err := input_handler_insert(context_input_handler(ctx), mode, params.count); err != .None {
		input_handler_report_error(ctx, err)
	}
}

// normal_repeat_last_insert_cmd repeats the last insertion.
normal_repeat_last_insert_cmd :: proc(ctx: ^Context, params: Normal_Params) {
	_ = params
	if err := input_handler_repeat_last_insert(context_input_handler(ctx)); err != .None {
		input_handler_report_error(ctx, err)
	}
}

// normal_repeat_last_select_cmd repeats the last selection command.
normal_repeat_last_select_cmd :: proc(ctx: ^Context, params: Normal_Params) {
	_ = params
	context_repeat_last_select(ctx)
}

// normal_Key_Info pairs builtin keys with their docstring (port of
// C++ KeyInfo).
normal_Key_Info :: struct {
	keys:      []Keys_Key,
	docstring: string,
}

// normal_build_autoinfo_for_mapping lists builtin keys (minus mapped
// ones) plus user mappings as "keys: doc" lines (port of
// build_autoinfo_for_mapping). Caller owns the result.
normal_build_autoinfo_for_mapping :: proc(
	ctx: ^Context,
	mode: Keymap_Manager_Mode,
	built_ins: []normal_Key_Info,
	allocator := context.allocator,
) -> string {
	keymaps := context_keymaps(ctx)
	Descs :: struct {
		keys:      string,
		docstring: string,
	}
	descs := make([dynamic]Descs, 0, allocator)
	defer {
		for d in descs {
			delete(d.keys, allocator)
		}
		delete(descs)
	}
	for bi in built_ins {
		sb := strings.builder_make(context.temp_allocator)
		defer strings.builder_destroy(&sb)
		first := true
		for k in bi.keys {
			if keymap_manager_get_mapping(keymaps, k, mode) != nil {
				continue
			}
			if !first {
				strings.write_byte(&sb, ',')
			}
			first = false
			key_str := keys_to_string_key(k, context.temp_allocator)
			defer delete(key_str, context.temp_allocator)
			strings.write_string(&sb, key_str)
		}
		if strings.builder_len(sb) != 0 {
			append(&descs, Descs{keys = strings.clone(strings.to_string(sb), allocator), docstring = bi.docstring})
		}
	}
	mapped := keymap_manager_get_mapped_keys(keymaps, mode, context.temp_allocator)
	defer delete(mapped)
	for key in mapped {
		mapping := keymap_manager_get_mapping(keymaps, key, mode)
		if mapping == nil || (len(mapping.keys) == 0 && len(mapping.docstring) == 0) {
			continue
		}
		key_str := keys_to_string_key(key, context.temp_allocator)
		defer delete(key_str, context.temp_allocator)
		found := -1
		for d, i in descs {
			if d.docstring == mapping.docstring {
				found = i
				break
			}
		}
		if found >= 0 {
			joined := strings.concatenate({descs[found].keys, ",", key_str}, allocator)
			delete(descs[found].keys, allocator)
			descs[found].keys = joined
		} else {
			append(&descs, Descs{keys = strings.clone(key_str, allocator), docstring = mapping.docstring})
		}
	}
	max_len := 0
	for d in descs {
		max_len = max(max_len, string_utils_column_length(d.keys))
	}
	out := strings.builder_make(allocator)
	for d in descs {
		strings.write_string(&out, d.keys)
		strings.write_byte(&out, ':')
		for _ in 0 ..< max_len - string_utils_column_length(d.keys) + 1 {
			strings.write_byte(&out, ' ')
		}
		strings.write_string(&out, d.docstring)
		strings.write_byte(&out, '\n')
	}
	return strings.to_string(out)
}

// normal_opt_int reads an int option (port of options()[name].get<int>()).
normal_opt_int :: proc(ctx: ^Context, name: string) -> int {
	opt := option_manager_get_checked(context_options(ctx), name)
	return opt.value.(int)
}

// normal_opt_bool reads a bool option.
normal_opt_bool :: proc(ctx: ^Context, name: string) -> bool {
	opt := option_manager_get_checked(context_options(ctx), name)
	return opt.value.(bool)
}

// normal_opt_strings reads a strings option (borrowed).
normal_opt_strings :: proc(ctx: ^Context, name: string) -> []string {
	opt := option_manager_get_checked(context_options(ctx), name)
	return opt.value.([dynamic]string)[:]
}

// normal_opt_coord reads a Coord option.
normal_opt_coord :: proc(ctx: ^Context, name: string) -> Coord_Display {
	opt := option_manager_get_checked(context_options(ctx), name)
	return opt.value.(Coord_Display)
}

// normal_Goto_Data carries goto parameters into the on-next-key
// callback (port of the goto_commands lambda captures).
normal_Goto_Data :: struct {
	mode:  normal_Select_Mode,
	count: int,
}

normal_goto_destroy :: proc(data: rawptr, allocator: mem.Allocator) {
	free(cast(^normal_Goto_Data)(data), allocator)
}

// normal_goto_offset_apply moves one selection vertically by the
// captured offset (goto d/u edelta).
normal_goto_offset_apply :: proc(data: rawptr, ctx: ^Context, sel: Selection) -> (Selection, bool) {
	offset := (cast(^Units_LineCount)(data))^
	if context_has_window(ctx) {
		cursor := sel.cursor
		win := context_window(ctx)
		if display_coord, ok := window_display_coord(win, cursor.coord); ok {
			if cursor.display_target == Coord_Column(-1) {
				cursor.display_target = display_coord.column
			}
			display_coord.column = cursor.display_target
			target := Coord_Display{line = display_coord.line + offset, column = display_coord.column}
			if buffer_coord, ok2 := window_buffer_coord(win, target); ok2 {
				full := coord_buffer_and_target(buffer_coord, Coord_Column(-1), cursor.display_target)
				return Selection{basic = Basic_Selection{anchor = buffer_coord, cursor = full}}, true
			}
		}
	}
	tabstop := Units_ColumnCount(normal_opt_int(ctx, "tabstop"))
	moved := buffer_offset_coord_by_line(context_buffer(ctx), sel.cursor, offset, tabstop)
	return Selection{basic = Basic_Selection{anchor = moved.coord, cursor = moved}}, true
}

normal_goto_call :: proc(data: rawptr, key: Keys_Key, ctx: ^Context) {
	d := cast(^normal_Goto_Data)(data)
	cp, ok := keys_codepoint(key)
	if !ok || input_handler_key_is(key, keys_MOD_NONE, keys_ESCAPE) {
		return
	}
	buffer := context_buffer(ctx)
	lower := unicode_to_lower(cp)
	switch lower {
	case 'g', 'k':
		context_push_jump(ctx)
		normal_select_coord(ctx, Coord_Buffer{0, 0}, d.mode)
	case 'l':
		normal_select(ctx, d.mode, normal_sel_goto_line_end)
	case 'h':
		normal_select(ctx, d.mode, normal_sel_goto_line_begin)
	case 'i':
		normal_select(ctx, d.mode, normal_sel_first_non_blank)
	case 'j':
		context_push_jump(ctx)
		normal_select_coord(ctx, Coord_Buffer{buffer_line_count(buffer) - 1, 0}, d.mode)
	case 'e':
		context_push_jump(ctx)
		normal_select_coord(ctx, buffer_back_coord(buffer), d.mode)
	case 't':
		if context_has_window(ctx) {
			normal_select_coord(ctx, Coord_Buffer{window_position(context_window(ctx)).line, 0}, d.mode)
		}
	case 'b':
		if context_has_window(ctx) {
			win := context_window(ctx)
			line := window_position(win).line + window_dimensions(win).line - 1
			normal_select_coord(ctx, Coord_Buffer{line, 0}, d.mode)
		}
	case 'c':
		if context_has_window(ctx) {
			win := context_window(ctx)
			line := window_position(win).line + window_dimensions(win).line / 2
			normal_select_coord(ctx, Coord_Buffer{line, 0}, d.mode)
		}
	case 'a':
		target := context_last_buffer(ctx)
		if target == nil {
			normal_fail(ctx, "no last buffer")
			return
		}
		context_push_jump(ctx)
		context_change_buffer(ctx, target)
	case 'd', 'u':
		sign := Units_LineCount(1) if lower == 'd' else Units_LineCount(-1)
		offset := sign * Units_LineCount(max(d.count, 1))
		if err := normal_select(ctx, d.mode, normal_goto_offset_apply, &offset); err != .None {
			normal_fail(ctx, normal_error_message(err))
		}
	case 'f':
		normal_goto_file(ctx, d)
	case '.':
		context_push_jump(ctx)
		pos, found := buffer_last_modification_coord(buffer)
		if !found {
			normal_fail(ctx, "no last modification position")
			return
		}
		if coord_compare(pos, buffer_back_coord(buffer)) >= 0 {
			pos = buffer_back_coord(buffer)
		}
		normal_select_coord(ctx, pos, d.mode)
	case:
		normal_fail(ctx, "key not mapped")
	}
}

// normal_goto_file jumps to the file under each selection (goto f).
normal_goto_file :: proc(ctx: ^Context, d: ^normal_Goto_Data) {
	_ = d
	buffer := context_buffer(ctx)
	paths := normal_opt_strings(ctx, "path")
	buffer_dir, _ := file_split_path(buffer_filename(buffer))
	Buf_Path :: struct {
		path:      string,
		owned:     bool,
		allocator: mem.Allocator,
	}
	collected := make([dynamic]Buf_Path, 0, context.temp_allocator)
	defer {
		for p in collected {
			if p.owned {
				delete(p.path, p.allocator)
			}
		}
		delete(collected)
	}
	sels := context_selections(ctx)
	for &sel in sels.selections {
		filename := normal_sel_content(buffer, sel, context.temp_allocator)
		defer delete(filename, context.temp_allocator)
		forbidden := false
		for i := 0; i < len(filename); i += 1 {
			if filename[i] == '\'' || filename[i] == '\\' {
				forbidden = true
				break
			}
		}
		if forbidden {
			msg, _ := format_format("filename contains invalid characters: '{}'", []string{filename}, context.temp_allocator)
			defer delete(msg, context.temp_allocator)
			normal_fail(ctx, msg)
			return
		}
		path := file_find_file(filename, buffer_dir, paths, context.temp_allocator)
		if len(path) == 0 {
			msg, _ := format_format("unable to find file '{}'", []string{filename}, context.temp_allocator)
			defer delete(msg, context.temp_allocator)
			normal_fail(ctx, msg)
			return
		}
		append(&collected, Buf_Path{path = path, owned = true, allocator = context.temp_allocator})
	}
	buffer_main: ^Buffer = nil
	for path, i in collected {
		target := buffer_manager_get_ifp(buffer_manager_instance(), path.path)
		if target == nil {
			flags := Buffer_Flags{}
			if utils_nested_bool_is_set(context_hooks_disabled(ctx)^) {
				flags = {.No_Hooks}
			}
			opened, oerr := buffer_utils_open_file_buffer(path.path, flags)
			if oerr != .None || opened == nil {
				msg, _ := format_format("unable to open '{}'", []string{path.path}, context.temp_allocator)
				defer delete(msg, context.temp_allocator)
				normal_fail(ctx, msg)
				return
			}
			target = opened
			buffer_set_flags(target, buffer_flags(target) & ~Buffer_Flags{.No_Hooks})
		}
		if i == sels.main {
			buffer_main = target
		}
	}
	if buffer_main != nil && buffer_main != buffer {
		context_push_jump(ctx)
		context_change_buffer(ctx, buffer_main)
	}
}

// normal_goto_commands implements g/G (port of goto_commands<mode>).
normal_goto_commands :: proc(ctx: ^Context, params: Normal_Params, mode: normal_Select_Mode) {
	if params.count != 0 {
		context_push_jump(ctx)
		line := Units_LineCount(params.count - 1)
		normal_select_coord(ctx, Coord_Buffer{line, 0}, mode)
		if context_has_window(ctx) {
			window_center_line(context_window(ctx), line)
		}
		return
	}
	alloc := normal_alloc(ctx)
	d := new(normal_Goto_Data, alloc)
	d^ = normal_Goto_Data{mode = mode, count = params.count}
	cmd := Key_Callback{call = normal_goto_call, data = d, destroy = normal_goto_destroy}
	title := "goto (extend to)" if mode == .Extend else "goto"
	gk := []Keys_Key{{keys_MOD_NONE, 'g'}, {keys_MOD_NONE, 'k'}}
	gl := []Keys_Key{{keys_MOD_NONE, 'l'}}
	gh := []Keys_Key{{keys_MOD_NONE, 'h'}}
	gi := []Keys_Key{{keys_MOD_NONE, 'i'}}
	gj := []Keys_Key{{keys_MOD_NONE, 'j'}}
	ge := []Keys_Key{{keys_MOD_NONE, 'e'}}
	gt := []Keys_Key{{keys_MOD_NONE, 't'}}
	gb := []Keys_Key{{keys_MOD_NONE, 'b'}}
	gc := []Keys_Key{{keys_MOD_NONE, 'c'}}
	ga := []Keys_Key{{keys_MOD_NONE, 'a'}}
	gf := []Keys_Key{{keys_MOD_NONE, 'f'}}
	gd := []Keys_Key{{keys_MOD_NONE, '.'}}
	infos := []normal_Key_Info{
		{gk[:], "buffer top"},
		{gl[:], "line end"},
		{gh[:], "line begin"},
		{gi[:], "line non blank start"},
		{gj[:], "buffer bottom"},
		{ge[:], "buffer end"},
		{gt[:], "window top"},
		{gb[:], "window bottom"},
		{gc[:], "window center"},
		{ga[:], "last buffer"},
		{gf[:], "file"},
		{gd[:], "last buffer change"},
	}
	info := normal_build_autoinfo_for_mapping(ctx, .Goto, infos, context.temp_allocator)
	defer delete(info, context.temp_allocator)
	input_handler_on_next_key_with_autoinfo(ctx, "goto", .Goto, cmd, title, info)
}

// normal_View_Data carries view parameters (port of the
// view_commands lambda captures).
normal_View_Data :: struct {
	count: int,
	lock:  bool,
}

normal_view_destroy :: proc(data: rawptr, allocator: mem.Allocator) {
	free(cast(^normal_View_Data)(data), allocator)
}

normal_view_call :: proc(data: rawptr, key: Keys_Key, ctx: ^Context) {
	d := cast(^normal_View_Data)(data)
	ctx.ensure_cursor_visible = false
	if input_handler_key_is(key, keys_MOD_NONE, keys_ESCAPE) {
		return
	}
	if d.lock {
		normal_view_commands(ctx, Normal_Params{count = d.count}, true)
	}
	cp, ok := keys_codepoint(key)
	if !ok || !context_has_window(ctx) {
		return
	}
	cursor := input_handler_sel_min(selection_list_main(context_selections(ctx)))
	win := context_window(ctx)
	window_update_display_buffer(win, ctx)
	if context_has_client(ctx) {
		client_force_redraw(context_client(ctx), false)
	}
	scrolloff := normal_opt_coord(ctx, "scrolloff")
	dims := window_dimensions(win)
	line_offset := min((dims.line - 1) / 2, scrolloff.line)
	column_offset := min((dims.column - 1) / 2, scrolloff.column)
	buffer := context_buffer(ctx)
	cursor_col := Units_ColumnCount(string_utils_column_length(buffer_line(buffer, cursor.line)[:int(cursor.column)]))
	switch cp {
	case 'v', 'c':
		window_center_line(win, cursor.line)
	case 'm':
		window_center_column(win, cursor_col)
	case 't':
		window_display_line_at(win, cursor.line, Units_LineCount(line_offset))
	case 'b':
		window_display_line_at(win, cursor.line, dims.line - 1 - Units_LineCount(line_offset))
	case '<':
		window_display_column_at(win, cursor_col, column_offset)
	case '>':
		window_display_column_at(win, cursor_col, dims.column - 1 - column_offset)
	case 'h':
		window_scroll(win, -max(Units_ColumnCount(1), Units_ColumnCount(d.count)))
	case 'j':
		input_handler_scroll_window(ctx, max(Units_LineCount(1), Units_LineCount(d.count)), .Preserve_Selections)
	case 'k':
		input_handler_scroll_window(ctx, -max(Units_LineCount(1), Units_LineCount(d.count)), .Preserve_Selections)
	case 'l':
		window_scroll(win, max(Units_ColumnCount(1), Units_ColumnCount(d.count)))
	case:
		normal_fail(ctx, "key not mapped")
	}
}

// normal_view_commands implements v/V (port of view_commands<lock>).
normal_view_commands :: proc(ctx: ^Context, params: Normal_Params, lock: bool) {
	alloc := normal_alloc(ctx)
	d := new(normal_View_Data, alloc)
	d^ = normal_View_Data{count = params.count, lock = lock}
	cmd := Key_Callback{call = normal_view_call, data = d, destroy = normal_view_destroy}
	vc := []Keys_Key{{keys_MOD_NONE, 'v'}, {keys_MOD_NONE, 'c'}}
	vm := []Keys_Key{{keys_MOD_NONE, 'm'}}
	vt := []Keys_Key{{keys_MOD_NONE, 't'}}
	vb := []Keys_Key{{keys_MOD_NONE, 'b'}}
	vl := []Keys_Key{{keys_MOD_NONE, '<'}}
	vg := []Keys_Key{{keys_MOD_NONE, '>'}}
	vh := []Keys_Key{{keys_MOD_NONE, 'h'}}
	vj := []Keys_Key{{keys_MOD_NONE, 'j'}}
	vk := []Keys_Key{{keys_MOD_NONE, 'k'}}
	vll := []Keys_Key{{keys_MOD_NONE, 'l'}}
	infos := []normal_Key_Info{
		{vc[:], "center cursor (vertically)"},
		{vm[:], "center cursor (horizontally)"},
		{vt[:], "cursor on top"},
		{vb[:], "cursor on bottom"},
		{vl[:], "cursor on left"},
		{vg[:], "cursor on right"},
		{vh[:], "scroll left"},
		{vj[:], "scroll down"},
		{vk[:], "scroll up"},
		{vll[:], "scroll right"},
	}
	info := normal_build_autoinfo_for_mapping(ctx, .View, infos, context.temp_allocator)
	defer delete(info, context.temp_allocator)
	title := "view (lock)" if lock else "view"
	input_handler_on_next_key_with_autoinfo(ctx, "view", .View, cmd, title, info)
}

// normal_replace_char_data is empty; the callback needs no state.
normal_replace_char_call :: proc(data: rawptr, key: Keys_Key, ctx: ^Context) {
	_ = data
	cp, ok := keys_codepoint(key)
	if !ok || input_handler_key_is(key, keys_MOD_NONE, keys_ESCAPE) {
		return
	}
	edition := context_scoped_edition_make(ctx)
	defer context_scoped_edition_destroy(&edition)
	sel_edition := context_scoped_selection_edition_make(ctx)
	defer context_scoped_selection_edition_destroy(&sel_edition)
	buffer := context_buffer(ctx)
	sels := context_selections(ctx)
	selection_list_merge_overlapping(sels)
	replace_data := normal_Replace_Char_Data{buffer = buffer, cp = cp}
	if err := selection_list_for_each(sels, normal_replace_char_apply, &replace_data, true); err != .None {
		normal_fail(ctx, buffer_error_message(err))
	}
}

// normal_Replace_Char_Data carries the buffer and codepoint into the
// for_each callback (replace with char).
normal_Replace_Char_Data :: struct {
	buffer: ^Buffer,
	cp:     rune,
}

normal_replace_char_apply :: proc(data: rawptr, index: int, sel: ^Selection) -> Buffer_Error {
	_ = index
	d := cast(^normal_Replace_Char_Data)(data)
	count := normal_char_length(d.buffer, sel^)
	buf: [4]byte
	n := utf8_dump(d.cp, buf[:])
	grown := make([]u8, n * count, context.temp_allocator)
	for i in 0 ..< count {
		copy(grown[i * n:], buf[:n])
	}
	return selection_replace(d.buffer, sel, string(grown))
}

// normal_replace_with_char implements r (port of replace_with_char).
normal_replace_with_char :: proc(ctx: ^Context, params: Normal_Params) {
	_ = params
	cmd := Key_Callback{call = normal_replace_char_call}
	input_handler_on_next_key_with_autoinfo(ctx, "replace-char", .None, cmd, "replace with char", "enter char to replace with\n")
}

// normal_swap_case flips cp's case (port of swap_case).
normal_swap_case :: proc(cp: rune) -> rune {
	lower := unicode_to_lower(cp)
	return unicode_to_upper(cp) if lower == cp else lower
}

// normal_for_each_codepoint maps func over every codepoint of each
// selection (port of for_each_codepoint<func>).
normal_for_each_codepoint :: proc(ctx: ^Context, func: proc(rune) -> rune) {
	edition := context_scoped_edition_make(ctx)
	defer context_scoped_edition_destroy(&edition)
	sel_edition := context_scoped_selection_edition_make(ctx)
	defer context_scoped_selection_edition_destroy(&sel_edition)
	buffer := context_buffer(ctx)
	data := normal_Case_Data{buffer = buffer, func = func}
	if err := selection_list_for_each(context_selections(ctx), normal_case_apply, &data, false); err != .None {
		normal_fail(ctx, buffer_error_message(err))
	}
}

// normal_Case_Data carries the buffer and mapping into the case
// conversion callback.
normal_Case_Data :: struct {
	buffer: ^Buffer,
	func:   proc(rune) -> rune,
}

normal_case_apply :: proc(data: rawptr, index: int, sel: ^Selection) -> Buffer_Error {
	_ = index
	d := cast(^normal_Case_Data)(data)
	content := normal_sel_content(d.buffer, sel^, context.temp_allocator)
	defer delete(content, context.temp_allocator)
	sb := strings.builder_make(context.temp_allocator)
	defer strings.builder_destroy(&sb)
	pos := 0
	for pos < len(content) {
		cp := utf8_read_codepoint(content, &pos)
		mapped := d.func(cp)
		buf: [4]byte
		n := utf8_dump(mapped, buf[:])
		strings.write_string(&sb, string(buf[:n]))
	}
	return selection_replace(d.buffer, sel, strings.to_string(sb))
}

// normal_shell_complete_call adapts completion_shell_complete to a
// Prompt_Completer (port of the shell_complete prompt completer).
normal_shell_complete_call :: proc(data: rawptr, ctx: ^Context, text: string, cursor_pos: Units_ByteCount, allocator: mem.Allocator) -> Completions {
	_ = data
	return completion_shell_complete(ctx, text, cursor_pos, allocator)
}

// normal_complete_nothing_call adapts completion_complete_nothing to
// a Prompt_Completer (port of complete_nothing).
normal_complete_nothing_call :: proc(data: rawptr, ctx: ^Context, text: string, cursor_pos: Units_ByteCount, allocator: mem.Allocator) -> Completions {
	_ = data
	_ = text
	return completion_complete_nothing(ctx, "", cursor_pos)
}

// normal_Command_Data owns the : prompt state (port of the command()
// lambda captures): the completer, shell env and default command.
normal_Command_Data :: struct {
	completer:        Command_Manager_Completer,
	env_vars:          Env_Var_Map,
	default_command:   string,
	allocator:         mem.Allocator,
}

normal_command_destroy :: proc(data: rawptr, allocator: mem.Allocator) {
	_ = allocator
	d := cast(^normal_Command_Data)(data)
	command_manager_completer_destroy(&d.completer)
	env_vars_free(&d.env_vars, d.allocator)
	delete(d.default_command, d.allocator)
	free(d, d.allocator)
}

normal_command_complete :: proc(data: rawptr, ctx: ^Context, text: string, cursor_pos: Units_ByteCount, allocator: mem.Allocator) -> Completions {
	d := cast(^normal_Command_Data)(data)
	completions, err, msg := command_manager_complete(&d.completer, ctx, text, cursor_pos, allocator)
	if err != .None {
		delete(msg, allocator)
		return Completions{start = cursor_pos, end = cursor_pos}
	}
	delete(msg, allocator)
	return completions
}

normal_command_call :: proc(data: rawptr, text: string, event: Prompt_Event, ctx: ^Context) {
	d := cast(^normal_Command_Data)(data)
	if context_has_client(ctx) {
		if event != .Validate {
			client_info_hide(context_client(ctx))
		}
		if event == .Change {
			info, found := command_manager_command_info(
				command_manager_instance(), ctx, text, context.temp_allocator,
			)
			defer command_manager_free_info(&info, context.temp_allocator)
			faces := context_faces(ctx)
			face := "Prompt" if found || len(text) == 0 else "Error"
			input_handler_set_prompt_face(context_input_handler(ctx), input_handler_face(faces, face))
			autoinfo := input_handler_option_auto_info(option_manager_get_checked(context_options(ctx), "autoinfo"))
			if .Command in autoinfo {
				if len(text) == 1 && (text[0] == ' ' || text[0] == '\t') {
					client_info_show_string(
						context_client(ctx), "prompt",
						"commands preceded by a blank wont be saved to history",
						Coord_Buffer{}, .Prompt,
					)
				} else if found && len(info.info) != 0 {
					client_info_show_string(context_client(ctx), info.name, info.info, Coord_Buffer{}, .Prompt)
				}
			}
		}
	}
	if event == .Validate {
		cmdline := text if len(text) != 0 else d.default_command
		shell_ctx := Shell_Context{env_vars = d.env_vars}
		if err, msg := command_manager_execute(
			command_manager_instance(), cmdline, ctx, &shell_ctx, context.temp_allocator,
		); err != .None {
			defer delete(msg, context.temp_allocator)
			normal_fail(ctx, msg)
			// The C++ lets the error throw to exec(); stash it for
			// exec() to report since this callback cannot return it.
			kind := Commands_Error.Error if err == .Error else .Fail
			input_handler_set_key_error(context_input_handler(ctx), kind, msg)
		} else {
			delete(msg, context.temp_allocator)
		}
	}
}

// normal_reg_name renders a register char as a name (port of the
// implicit char-to-register lookup).
normal_reg_name :: proc(reg: rune, allocator := context.allocator) -> string {
	buf := make([]u8, 1, allocator)
	buf[0] = byte(reg)
	return string(buf)
}

// normal_command_prompt opens the : prompt (port of command()).
// Deviation: the C++ checks CommandManager::has_instance, but the
// Odin singleton always exists, so commands are always supported.
normal_command_prompt :: proc(ctx: ^Context, env_vars: Env_Var_Map, reg: rune = 0) {
	default_reg := reg if reg != 0 else ':'
	reg_name := normal_reg_name(default_reg, context.temp_allocator)
	defer delete(reg_name, context.temp_allocator)
	default_command, reg_err := context_main_sel_register_value(ctx, reg_name)
	if reg_err != .None {
		default_command = ""
	}
	alloc := normal_alloc(ctx)
	d := new(normal_Command_Data, alloc)
	d.completer = command_manager_completer_make(alloc)
	d.env_vars = env_vars
	d.default_command = strings.clone(default_command, alloc)
	d.allocator = alloc
	completer := Prompt_Completer{call = normal_command_complete, data = d}
	callback := Prompt_Callback{call = normal_command_call, data = d, destroy = normal_command_destroy}
	// The mode owns callback data; the completer borrows it (its
	// destroy stays nil so the data is freed exactly once).
	faces := context_faces(ctx)
	input_handler_prompt(
		context_input_handler(ctx), ":", "", default_command,
		input_handler_face(faces, "Prompt"),
		{.Drop_History_Entries_With_Blank_Prefix, .Command}, ':',
		completer, callback,
	)
}

// normal_count_register_env_vars builds the count/register env map
// handed to prompts (port of the EnvVarMap built in command() and in
// the <a-;> object prompt). Keys and values are owned clones so the
// map can be released with env_vars_free; static keys would corrupt
// the heap when the prompt is destroyed.
normal_count_register_env_vars :: proc(count: int, reg: rune, allocator: mem.Allocator) -> Env_Var_Map {
	env_vars := make(Env_Var_Map, 2, allocator)
	env_vars[strings.clone("count", allocator)] = format_to_string_int(count, allocator)
	reg_buf := make([]u8, 1, allocator)
	reg_buf[0] = byte(reg)
	env_vars[strings.clone("register", allocator)] = string(reg_buf)
	return env_vars
}

// normal_cmd_command implements : (port of command(Context&, Params)).
normal_cmd_command :: proc(ctx: ^Context, params: Normal_Params) {
	alloc := normal_alloc(ctx)
	env_vars := normal_count_register_env_vars(params.count, params.reg, alloc)
	normal_command_prompt(ctx, env_vars, params.reg)
}

// normal_Diff_Snake_Op mirrors Snake::Op for the line diff.
normal_Diff_Snake_Op :: enum {
	Add,
	Del,
	Rev_Add,
	Rev_Del,
}

// normal_Diff_Snake is an edit plus diagonal for the line diff.
normal_Diff_Snake :: struct {
	x, y, u, v: int,
	op:         normal_Diff_Snake_Op,
}

// normal_diff_end_snake is diff_end_snake instantiated on lines:
// furthest-reaching D-path end snake on diagonal k.
normal_diff_end_snake :: proc(a, b: []string, v: []int, v_off, d, k: int, forward: bool) -> normal_Diff_Snake {
	n := len(a)
	m := len(b)
	add := k == -d || (k != d && v[k - 1 + v_off] < v[k + 1 + v_off])
	x := v[k + 1 + v_off] if add else v[k - 1 + v_off] + 1
	y := x - k
	u, w := x, y
	for u < n && w < m {
		ca := a[u] if forward else a[n - 1 - u]
		cb := b[w] if forward else b[m - 1 - w]
		if ca != cb {
			break
		}
		u += 1
		w += 1
	}
	return normal_Diff_Snake{x, y, u, w, .Add if add else .Del}
}

// normal_diff_middle_snake is diff_middle_snake instantiated on lines.
normal_diff_middle_snake :: proc(a, b: []string, v1, v2: []int, v_off, cost_limit: int) -> normal_Diff_Snake {
	n := len(a)
	m := len(b)
	delta := n - m
	v1[1 + v_off] = 0
	v2[1 + v_off] = 0
	max_d := min((m + n + 1) / 2 + 1, cost_limit)
	for d in 0 ..< max_d {
		for k1 := -d; k1 <= d; k1 += 2 {
			p := normal_diff_end_snake(a, b, v1, v_off, d, k1, true)
			v1[k1 + v_off] = p.u
			k2 := -(k1 - delta)
			if delta % 2 != 0 && -(d - 1) <= k2 && k2 <= (d - 1) && v1[k1 + v_off] + v2[k2 + v_off] >= n {
				return p
			}
		}
		for k2 := -d; k2 <= d; k2 += 2 {
			p := normal_diff_end_snake(a, b, v2, v_off, d, k2, false)
			v2[k2 + v_off] = p.u
			k1 := -(k2 - delta)
			if delta % 2 == 0 && -d <= k1 && k1 <= d && v1[k1 + v_off] + v2[k2 + v_off] >= n {
				op := normal_Diff_Snake_Op.Rev_Add if p.op == .Add else .Rev_Del
				return normal_Diff_Snake{n - p.u, m - p.v, n - p.x, m - p.y, op}
			}
		}
	}
	best := normal_Diff_Snake{}
	for k1 := -max_d; k1 <= max_d; k1 += 2 {
		p := normal_diff_end_snake(a, b, v1, v_off, max_d, k1, true)
		v1[k1 + v_off] = p.u
		if delta % 2 != 0 && p.u <= n && p.v <= m && p.u + p.v >= best.u + best.v {
			best = p
		}
	}
	for k2 := -max_d; k2 <= max_d; k2 += 2 {
		p := normal_diff_end_snake(a, b, v2, v_off, max_d, k2, false)
		v2[k2 + v_off] = p.u
		if delta % 2 == 0 && p.u <= n && p.v <= m && p.u + p.v >= best.u + best.v {
			op := normal_Diff_Snake_Op.Rev_Add if p.op == .Add else .Rev_Del
			best = normal_Diff_Snake{p.x, p.y, p.u, p.v, op}
		}
	}
	if best.op == .Rev_Add || best.op == .Rev_Del {
		best = normal_Diff_Snake{n - best.u, m - best.v, n - best.x, m - best.y, best.op}
	}
	return best
}

// normal_Diff_Coalescer merges adjacent line runs before forwarding
// them to outer (like Diff_Coalescer, but the callback takes an
// explicit state: Odin has no capturing closures).
normal_Diff_Coalescer :: struct {
	last:  Diff_Diff,
	state: rawptr,
	outer: proc(state: rawptr, op: Diff_Op, len: int),
}

normal_diff_coalescer_emit :: proc(c: ^normal_Diff_Coalescer, op: Diff_Op, len: int) {
	if c.last.op == op {
		c.last.len += len
	} else {
		if c.last.len != 0 {
			c.outer(c.state, c.last.op, c.last.len)
		}
		c.last = Diff_Diff{op, len}
	}
}

// normal_diff_find_rec is diff_find_rec instantiated on lines.
normal_diff_find_rec :: proc(
	a: []string,
	beg_a, end_a: int,
	b: []string,
	beg_b, end_b: int,
	v1, v2: []int,
	v_off, cost_limit: int,
	coalescer: ^normal_Diff_Coalescer,
) {
	lo_a, hi_a := beg_a, end_a
	lo_b, hi_b := beg_b, end_b
	prefix_len := 0
	for lo_a != hi_a && lo_b != hi_b && a[lo_a] == b[lo_b] {
		lo_a += 1
		lo_b += 1
		prefix_len += 1
	}
	suffix_len := 0
	for lo_a != hi_a && lo_b != hi_b && a[hi_a - 1] == b[hi_b - 1] {
		hi_a -= 1
		hi_b -= 1
		suffix_len += 1
	}
	if prefix_len != 0 {
		normal_diff_coalescer_emit(coalescer, .Keep, prefix_len)
	}
	len_a := hi_a - lo_a
	len_b := hi_b - lo_b
	if len_a == 0 {
		if len_b != 0 {
			normal_diff_coalescer_emit(coalescer, .Add, len_b)
		}
	} else if len_b == 0 {
		normal_diff_coalescer_emit(coalescer, .Remove, len_a)
	} else {
		snake := normal_diff_middle_snake(a[lo_a:hi_a], b[lo_b:hi_b], v1, v2, v_off, cost_limit)
		assert(snake.u <= len_a && snake.v <= len_b)
		del := 1 if snake.op == .Del else 0
		add := 1 if snake.op == .Add else 0
		normal_diff_find_rec(a, lo_a, lo_a + snake.x - del, b, lo_b, lo_b + snake.y - add, v1, v2, v_off, cost_limit, coalescer)
		if snake.op == .Add {
			normal_diff_coalescer_emit(coalescer, .Add, 1)
		}
		if snake.op == .Del {
			normal_diff_coalescer_emit(coalescer, .Remove, 1)
		}
		if snake.u - snake.x != 0 {
			normal_diff_coalescer_emit(coalescer, .Keep, snake.u - snake.x)
		}
		if snake.op == .Rev_Add {
			normal_diff_coalescer_emit(coalescer, .Add, 1)
		}
		if snake.op == .Rev_Del {
			normal_diff_coalescer_emit(coalescer, .Remove, 1)
		}
		rev_del := 1 if snake.op == .Rev_Del else 0
		rev_add := 1 if snake.op == .Rev_Add else 0
		normal_diff_find_rec(
			a, lo_a + snake.u + rev_del, hi_a, b, lo_b + snake.v + rev_add, hi_b,
			v1, v2, v_off, cost_limit, coalescer,
		)
	}
	if suffix_len != 0 {
		normal_diff_coalescer_emit(coalescer, .Keep, suffix_len)
	}
}

// normal_diff_lines reports the coalesced line edit script turning a
// into b (port of for_each_diff over line vectors). Scratch uses
// allocator; on_diff runs synchronously with state.
normal_diff_lines :: proc(
	a, b: []string,
	state: rawptr,
	on_diff: proc(state: rawptr, op: Diff_Op, len: int),
	allocator := context.allocator,
) {
	cost_limit := 1000
	v_off := len(a) + len(b) + 1
	v1 := make([]int, 2 * v_off + 1, allocator)
	defer delete(v1, allocator)
	v2 := make([]int, 2 * v_off + 1, allocator)
	defer delete(v2, allocator)
	coalescer := normal_Diff_Coalescer{state = state, outer = on_diff}
	normal_diff_find_rec(a, 0, len(a), b, 0, len(b), v1, v2, v_off, cost_limit, &coalescer)
	if coalescer.last.op != .Keep || coalescer.last.len != 0 {
		on_diff(state, coalescer.last.op, coalescer.last.len)
	}
}

// normal_split_after_lines splits s after each \n (port of
// split_after<StringView>('\n')): separators stay with their line,
// no trailing empty part, and empty input yields no lines.
normal_split_after_lines :: proc(s: string, allocator := context.allocator) -> [dynamic]string {
	res := make([dynamic]string, 0, allocator)
	start := 0
	for i in 0 ..< len(s) {
		if s[i] == '\n' {
			append(&res, s[start:i + 1])
			start = i + 1
		}
	}
	if start != len(s) {
		append(&res, s[start:])
	}
	return res
}

// normal_diff_byte_count sums the bytes of count lines.
normal_diff_byte_count :: proc(lines: []string, first, count: int) -> Units_ByteCount {
	total := Units_ByteCount(0)
	for i in first ..< first + count {
		total += Units_ByteCount(len(lines[i]))
	}
	return total
}

// normal_Apply_Diff_State threads the buffer cursor through the diff
// callback (port of the apply_diff lambda captures).
normal_Apply_Diff_State :: struct {
	buffer:                       ^Buffer,
	cursor:                       Coord_Buffer,
	pos_a:                        int,
	pos_b:                        int,
	lines_before:                 []string,
	lines_after:                  []string,
	tried_to_erase_final_newline: bool,
}

normal_apply_diff_on_diff :: proc(state: rawptr, op: Diff_Op, len: int) {
	st := cast(^normal_Apply_Diff_State)(state)
	switch op {
	case .Keep:
		assert(!st.tried_to_erase_final_newline)
		st.cursor = buffer_advance(st.buffer, st.cursor, normal_diff_byte_count(st.lines_before, st.pos_a, len))
		st.pos_a += len
		st.pos_b += len
	case .Add:
		if buffer_is_end(st.buffer, st.cursor) {
			st.tried_to_erase_final_newline = false
		}
		sb := strings.builder_make(context.temp_allocator)
		defer strings.builder_destroy(&sb)
		for i in st.pos_b ..< st.pos_b + len {
			strings.write_string(&sb, st.lines_after[i])
		}
		inserted, _ := buffer_insert(st.buffer, st.cursor, strings.to_string(sb))
		st.cursor = inserted.end
		st.pos_b += len
	case .Remove:
		assert(!st.tried_to_erase_final_newline)
		end := buffer_advance(st.buffer, st.cursor, normal_diff_byte_count(st.lines_before, st.pos_a, len))
		st.tried_to_erase_final_newline |= buffer_is_end(st.buffer, end)
		st.cursor, _ = buffer_erase(st.buffer, st.cursor, end)
		st.pos_a += len
	}
}

// normal_apply_diff rewrites [pos, ...) from lines_before to after,
// keeping changes forward-only (port of apply_diff). Returns the
// range covering the new text. lines_before is copied: the edits
// free buffer lines, and the C++ keeps its views alive through
// refcounted StringDataPtr.
normal_apply_diff :: proc(
	buffer: ^Buffer,
	pos: Coord_Buffer,
	lines_before: []string,
	after: string,
	allocator := context.allocator,
) -> Buffer_Range {
	before_owned := make([dynamic]string, len(lines_before), allocator)
	defer {
		for l in before_owned {
			delete(l, allocator)
		}
		delete(before_owned)
	}
	for l, i in lines_before {
		before_owned[i] = strings.clone(l, allocator)
	}
	lines_after := normal_split_after_lines(after, allocator)
	defer delete(lines_after)
	first := pos
	st := normal_Apply_Diff_State{
		buffer       = buffer,
		cursor       = pos,
		lines_before = before_owned[:],
		lines_after  = lines_after[:],
	}
	normal_diff_lines(before_owned[:], lines_after[:], &st, normal_apply_diff_on_diff, allocator)
	if st.tried_to_erase_final_newline {
		back := buffer_back_coord(buffer)
		if coord_compare(first, back) > 0 {
			first = back
		}
		st.cursor, _ = buffer_erase(buffer, buffer_back_coord(buffer), buffer_end_coord(buffer))
	}
	return Buffer_Range{first, st.cursor}
}

// normal_register looks up register reg (port of RegisterManager()[reg]).
normal_register :: proc(ctx: ^Context, reg: rune) -> ^Register {
	_ = ctx
	r, err := register_manager_get(register_manager_instance(), reg)
	assert(err == .None)
	return r
}

// normal_yank_to_register yanks the selections into reg (set clones
// the values, so the yanked strings are freed here).
normal_yank_to_register :: proc(ctx: ^Context, reg: rune) {
	contents := context_selections_content(ctx)
	register_manager_set(normal_register(ctx, reg), ctx, contents[:])
	for c in contents {
		delete(c)
	}
	delete(contents)
}

// normal_cmd_yank implements y (port of yank).
normal_cmd_yank :: proc(ctx: ^Context, params: Normal_Params) {
	reg := params.reg if params.reg != 0 else '"'
	normal_yank_to_register(ctx, reg)
	count_str := format_to_string_int(len(context_selections(ctx).selections), context.temp_allocator)
	reg_str := normal_reg_name(reg, context.temp_allocator)
	msg, _ := format_format("yanked {} selections to register {}", []string{count_str, reg_str}, context.temp_allocator)
	normal_print_info(ctx, msg)
}

// normal_cmd_erase implements d/A-d (port of erase_selections<yank>).
normal_cmd_erase :: proc(ctx: ^Context, params: Normal_Params, yank: bool) {
	if yank {
		normal_yank_to_register(ctx, params.reg if params.reg != 0 else '"')
	}
	edition := context_scoped_edition_make(ctx)
	defer context_scoped_edition_destroy(&edition)
	sel_edition := context_scoped_selection_edition_make(ctx)
	defer context_scoped_selection_edition_destroy(&sel_edition)
	if err := selection_list_erase(context_selections(ctx)); err != .None {
		normal_fail(ctx, buffer_error_message(err))
	}
}

// normal_cmd_change implements c/A-c (port of change<yank>).
normal_cmd_change :: proc(ctx: ^Context, params: Normal_Params, yank: bool) {
	if yank {
		normal_yank_to_register(ctx, params.reg if params.reg != 0 else '"')
	}
	normal_enter_insert_mode(ctx, params, .Replace)
}

// normal_paste_pos returns the paste position for [min, max] (port of
// paste_pos): Append pastes after max (next line when linewise),
// Insert at min (its line when linewise).
normal_paste_pos :: proc(buffer: ^Buffer, sel_min, sel_max: Coord_Buffer, mode: Paste_Mode, linewise: bool) -> Coord_Buffer {
	switch mode {
	case .Append:
		if buffer_is_end(buffer, sel_max) {
			return sel_max
		}
		if linewise {
			return Coord_Buffer{min(buffer_line_count(buffer), sel_max.line + 1), 0}
		}
		return buffer_char_next(buffer, sel_max)
	case .Insert:
		if linewise {
			return Coord_Buffer{sel_min.line, 0}
		}
		return sel_min
	case .Replace:
		unreachable()
	}
	unreachable()
}

// normal_Paste_Data carries the paste state into the for_each
// callback (port of the paste() lambda captures).
normal_Paste_Data :: struct {
	buffer:   ^Buffer,
	strings:  []string,
	mode:     Paste_Mode,
	linewise: bool,
	last:     Coord_Buffer,
}

normal_paste_apply :: proc(data: rawptr, index: int, sel: ^Selection) -> Buffer_Error {
	d := cast(^normal_Paste_Data)(data)
	str := d.strings[index % len(d.strings)]
	sel_min := input_handler_sel_min(sel)
	sel_max := input_handler_sel_max(sel)
	upper := sel_max if coord_compare(sel_max, d.last) >= 0 else d.last
	rng: Buffer_Range
	err: Buffer_Error
	if d.mode == .Replace {
		rng, err = buffer_replace(d.buffer, sel_min, buffer_char_next(d.buffer, sel_max), str)
	} else {
		rng, err = buffer_insert(d.buffer, normal_paste_pos(d.buffer, sel_min, upper, d.mode, d.linewise), str)
	}
	if err != .None {
		return err
	}
	new_min := rng.begin
	new_max := rng.begin if rng.end == rng.begin else buffer_char_prev(d.buffer, rng.end)
	input_handler_sel_set_min_max(sel, new_min, new_max)
	d.last = new_max
	return .None
}

// normal_paste implements p/P/R (port of paste<mode>).
normal_paste :: proc(ctx: ^Context, params: Normal_Params, mode: Paste_Mode) {
	reg := params.reg if params.reg != 0 else '"'
	strs := register_manager_get_values(normal_register(ctx, reg), ctx, context.temp_allocator)
	linewise := true
	for s in strs {
		if len(s) == 0 || s[len(s) - 1] != '\n' {
			linewise = false
			break
		}
	}
	edition := context_scoped_edition_make(ctx)
	defer context_scoped_edition_destroy(&edition)
	sel_edition := context_scoped_selection_edition_make(ctx)
	defer context_scoped_selection_edition_destroy(&sel_edition)
	data := normal_Paste_Data{buffer = context_buffer(ctx), strings = strs, mode = mode, linewise = linewise}
	if err := selection_list_for_each(context_selections(ctx), normal_paste_apply, &data, mode == .Append); err != .None {
		normal_fail(ctx, buffer_error_message(err))
	}
}

// normal_cmd_paste_repeated runs paste max(count, 1) times (port of
// repeated<paste<mode>>).
normal_cmd_paste_repeated :: proc(ctx: ^Context, params: Normal_Params, mode: Paste_Mode) {
	edition := context_scoped_edition_make(ctx)
	defer context_scoped_edition_destroy(&edition)
	sel_edition := context_scoped_selection_edition_make(ctx)
	defer context_scoped_selection_edition_destroy(&sel_edition)
	count := params.count
	for {
		normal_paste(ctx, Normal_Params{count = 0, reg = params.reg}, mode)
		count -= 1
		if count <= 0 {
			break
		}
	}
}

// normal_Paste_All_Data carries paste-all state (port of the
// paste_all() lambda captures).
normal_Paste_All_Data :: struct {
	buffer:  ^Buffer,
	all:     string,
	offsets: []normal_Paste_All_Offset,
	mode:    Paste_Mode,
	linewise: bool,
	result:  ^[dynamic]Selection,
}

// normal_Paste_All_Offset is one pasted string's cursor/length pair.
normal_Paste_All_Offset :: struct {
	cursor_offset: Units_ByteCount,
	length:        Units_ByteCount,
}

normal_paste_all_apply :: proc(data: rawptr, index: int, sel: ^Selection) -> Buffer_Error {
	_ = index
	d := cast(^normal_Paste_All_Data)(data)
	sel_min := input_handler_sel_min(sel)
	sel_max := input_handler_sel_max(sel)
	rng: Buffer_Range
	err: Buffer_Error
	if d.mode == .Replace {
		rng, err = buffer_replace(d.buffer, sel_min, buffer_char_next(d.buffer, sel_max), d.all)
	} else {
		rng, err = buffer_insert(d.buffer, normal_paste_pos(d.buffer, sel_min, sel_max, d.mode, d.linewise), d.all)
	}
	if err != .None {
		return err
	}
	pos := rng.begin
	for off in d.offsets {
		cursor := buffer_advance(d.buffer, pos, off.cursor_offset)
		append(d.result, Selection{basic = Basic_Selection{anchor = pos, cursor = coord_buffer_and_target(cursor)}})
		pos = buffer_advance(d.buffer, cursor, off.length - off.cursor_offset)
	}
	return .None
}

// normal_paste_all implements A-p/A-P/A-R (port of paste_all<mode>).
normal_paste_all :: proc(ctx: ^Context, params: Normal_Params, mode: Paste_Mode) {
	reg := params.reg if params.reg != 0 else '"'
	strs := register_manager_get_values(normal_register(ctx, reg), ctx, context.temp_allocator)
	sb := strings.builder_make(context.temp_allocator)
	defer strings.builder_destroy(&sb)
	offsets := make([dynamic]normal_Paste_All_Offset, 0, context.temp_allocator)
	defer delete(offsets)
	for s in strs {
		if len(s) == 0 {
			continue
		}
		strings.write_string(&sb, s)
		cursor_offset := Units_ByteCount(utf8_advance(s, 0, utf8_distance(s) - 1))
		append(&offsets, normal_Paste_All_Offset{cursor_offset = cursor_offset, length = Units_ByteCount(len(s))})
	}
	linewise := true
	for s in strs {
		if len(s) == 0 || s[len(s) - 1] != '\n' {
			linewise = false
			break
		}
	}
	if len(offsets) == 0 {
		normal_fail(ctx, "nothing to paste")
		return
	}
	buffer := context_buffer(ctx)
	sel_edition := context_scoped_selection_edition_make(ctx)
	defer context_scoped_selection_edition_destroy(&sel_edition)
	result := make([dynamic]Selection, 0, context.temp_allocator)
	defer delete(result)
	{
		edition := context_scoped_edition_make(ctx)
		defer context_scoped_edition_destroy(&edition)
		data := normal_Paste_All_Data{
			buffer = buffer, all = strings.to_string(sb), offsets = offsets[:],
			mode = mode, linewise = linewise, result = &result,
		}
		if err := selection_list_for_each(context_selections(ctx), normal_paste_all_apply, &data, mode == .Append); err != .None {
			normal_fail(ctx, buffer_error_message(err))
			return
		}
	}
	// C++ assigns the vector (main index becomes the last one).
	selection_list_set(context_selections(ctx), result[:], len(result) - 1)
}

// normal_Pipe_Data owns the pipe prompt state (port of the pipe()
// lambda captures).
normal_Pipe_Data :: struct {
	default_command: string,
	replace:         bool,
	edition:         Scoped_Selection_Edition,
	allocator:       mem.Allocator,
}

normal_pipe_destroy :: proc(data: rawptr, allocator: mem.Allocator) {
	_ = allocator
	d := cast(^normal_Pipe_Data)(data)
	context_scoped_selection_edition_destroy(&d.edition)
	delete(d.default_command, d.allocator)
	free(d, d.allocator)
}

// normal_pipe_eval runs cmdline with stdin_content, returning owned
// stdout in allocator (port of ShellManager::eval).
normal_pipe_eval :: proc(
	cmdline: string,
	ctx: ^Context,
	stdin_content: string,
	wait: bool,
	allocator := context.allocator,
) -> (
	string,
	Normal_Error,
) {
	shell_ctx := Shell_Context{}
	flags := Shell_Flags{.Wait_For_Stdout} if wait else Shell_Flags{}
	res, err := shell_manager_eval_full(cmdline, ctx, &shell_ctx, stdin_content, flags, allocator)
	if err != .None {
		shell_manager_eval_result_free(&res, allocator)
		return "", .Failed
	}
	delete(res.stderr, allocator)
	return res.output, .None
}

normal_pipe_call :: proc(data: rawptr, text: string, event: Prompt_Event, ctx: ^Context) {
	d := cast(^normal_Pipe_Data)(data)
	if event != .Validate {
		return
	}
	cmdline := text if len(text) != 0 else d.default_command
	if len(cmdline) == 0 {
		return
	}
	if d.replace {
		normal_pipe_replace(ctx, cmdline)
	} else {
		normal_pipe_to(ctx, cmdline)
	}
}

// normal_pipe_replace filters each selection through cmdline (pipe |).
normal_pipe_replace :: proc(ctx: ^Context, cmdline: string) {
	buffer := context_buffer(ctx)
	if err := buffer_check_read_only(buffer); err != .None {
		normal_fail(ctx, buffer_error_message(err))
		return
	}
	edition := context_scoped_edition_make(ctx)
	defer context_scoped_edition_destroy(&edition)
	tracker := Forward_Changes_Tracker{}
	timestamp := buffer_timestamp(buffer)
	// Work on a clone: the live list is temporarily narrowed per
	// selection so shell expansions see the current one.
	working := selection_list_clone(context_selections(ctx))
	defer selection_list_destroy(&working)
	live := context_selections_write_only(ctx)
	for &sel in working.selections {
		first := changes_get_new_coord_tolerant(&tracker, input_handler_sel_min(&sel))
		last := changes_get_new_coord_tolerant(&tracker, input_handler_sel_max(&sel))
		in_lines := make([dynamic]string, 0, context.temp_allocator)
		defer delete(in_lines)
		for line := first.line; line <= last.line; line += 1 {
			content := buffer_line(buffer, line)
			if line == last.line {
				content = content[:int(last.column) + utf8_codepoint_size_byte(content[int(last.column)])]
			}
			if line == first.line {
				content = content[int(first.column):]
			}
			append(&in_lines, strings.clone(content, context.temp_allocator))
		}
		defer {
			for l in in_lines {
				delete(l, context.temp_allocator)
			}
		}
		single := selectors_keep_direction(
			Selection{basic = Basic_Selection{anchor = first, cursor = coord_buffer_and_target(last)}}, sel,
		)
		selection_list_set(live, []Selection{single}, 0)
		stdin_sb := strings.builder_make(context.temp_allocator)
		defer strings.builder_destroy(&stdin_sb)
		for l in in_lines {
			strings.write_string(&stdin_sb, l)
		}
		out, eval_err := normal_pipe_eval(cmdline, ctx, strings.to_string(stdin_sb), true, context.temp_allocator)
		if eval_err != .None {
			selection_list_force_timestamp(&working, timestamp)
			context_assign_selections(ctx, working)
			normal_fail(ctx, "shell command failed")
			return
		}
		defer delete(out, context.temp_allocator)
		back_line := in_lines[len(in_lines) - 1]
		if (len(back_line) == 0 || back_line[len(back_line) - 1] != '\n') && len(out) != 0 && out[len(out) - 1] == '\n' {
			out = out[:len(out) - 1]
		}
		rng := normal_apply_diff(buffer, first, in_lines[:], out, context.temp_allocator)
		if rng.begin != rng.end {
			input_handler_sel_set_min_max(&sel, rng.begin, buffer_char_prev(buffer, rng.end))
		} else {
			pos := rng.end
			if pos.line != 0 || pos.column != 0 {
				pos = buffer_char_prev(buffer, pos)
			}
			sel.anchor = pos
			sel.cursor = coord_buffer_and_target(pos)
		}
		changes_update_buffer(&tracker, buffer, &timestamp)
	}
	selection_list_force_timestamp(&working, timestamp)
	context_assign_selections(ctx, working)
}

// normal_pipe_to runs cmdline per selection, ignoring output (pipe A-|).
normal_pipe_to :: proc(ctx: ^Context, cmdline: string) {
	buffer := context_buffer(ctx)
	sels := context_selections(ctx)
	old_main := sels.main
	for i in 0 ..< len(sels.selections) {
		selection_list_set_main_index(sels, i)
		content := normal_sel_content(buffer, sels.selections[i], context.temp_allocator)
		defer delete(content, context.temp_allocator)
		if _, err := normal_pipe_eval(cmdline, ctx, content, false, context.temp_allocator); err != .None {
			selection_list_set_main_index(sels, old_main)
			normal_fail(ctx, "shell command failed")
			return
		}
	}
	selection_list_set_main_index(sels, old_main)
}

// normal_pipe_prompt opens the pipe prompt (port of pipe<replace>).
normal_pipe_prompt :: proc(ctx: ^Context, params: Normal_Params, replace: bool) {
	default_reg := params.reg if params.reg != 0 else '|'
	reg_name := normal_reg_name(default_reg, context.temp_allocator)
	defer delete(reg_name, context.temp_allocator)
	default_command, reg_err := context_main_sel_register_value(ctx, reg_name)
	if reg_err != .None {
		default_command = ""
	}
	alloc := normal_alloc(ctx)
	d := new(normal_Pipe_Data, alloc)
	d.default_command = strings.clone(default_command, alloc)
	d.replace = replace
	d.edition = context_scoped_selection_edition_make(ctx)
	d.allocator = alloc
	completer := Prompt_Completer{call = normal_shell_complete_call}
	callback := Prompt_Callback{call = normal_pipe_call, data = d, destroy = normal_pipe_destroy}
	faces := context_faces(ctx)
	prompt := "pipe:" if replace else "pipe-to:"
	input_handler_prompt(
		context_input_handler(ctx), prompt, "", default_command,
		input_handler_face(faces, "Prompt"),
		{.Drop_History_Entries_With_Blank_Prefix}, '|',
		completer, callback,
	)
}

// normal_Insert_Output_Data carries insert-output state (port of the
// insert_output() lambda captures).
normal_Insert_Output_Data :: struct {
	sels:      ^Selection_List,
	buffer:    ^Buffer,
	cmdline:   string,
	mode:      Paste_Mode,
	shell_err: bool,
	ctx:       ^Context,
}

normal_insert_output_apply :: proc(data: rawptr, index: int, sel: ^Selection) -> Buffer_Error {
	d := cast(^normal_Insert_Output_Data)(data)
	selection_list_set_main_index(d.sels, index)
	content := normal_sel_content(d.buffer, sel^, context.temp_allocator)
	defer delete(content, context.temp_allocator)
	out, eval_err := normal_pipe_eval(d.cmdline, d.ctx, content, true, context.temp_allocator)
	defer delete(out, context.temp_allocator)
	if eval_err != .None {
		d.shell_err = true
		return .None
	}
	sel_min := input_handler_sel_min(sel)
	sel_max := input_handler_sel_max(sel)
	rng, err := selection_insert(d.buffer, sel, normal_paste_pos(d.buffer, sel_min, sel_max, d.mode, false), out)
	if err != .None {
		return err
	}
	new_max := rng.begin if rng.end == rng.begin else buffer_char_prev(d.buffer, rng.end)
	input_handler_sel_set_min_max(sel, rng.begin, new_max)
	return .None
}

// normal_Insert_Output_Prompt owns the prompt state for !/A-!.
normal_Insert_Output_Prompt :: struct {
	default_command: string,
	mode:            Paste_Mode,
	edition:         Scoped_Selection_Edition,
	allocator:       mem.Allocator,
}

normal_insert_output_prompt_destroy :: proc(data: rawptr, allocator: mem.Allocator) {
	_ = allocator
	d := cast(^normal_Insert_Output_Prompt)(data)
	context_scoped_selection_edition_destroy(&d.edition)
	delete(d.default_command, d.allocator)
	free(d, d.allocator)
}

normal_insert_output_call :: proc(data: rawptr, text: string, event: Prompt_Event, ctx: ^Context) {
	d := cast(^normal_Insert_Output_Prompt)(data)
	if event != .Validate {
		return
	}
	cmdline := text if len(text) != 0 else d.default_command
	if len(cmdline) == 0 {
		return
	}
	edition := context_scoped_edition_make(ctx)
	defer context_scoped_edition_destroy(&edition)
	sels := context_selections(ctx)
	buffer := context_buffer(ctx)
	old_main := sels.main
	apply_data := normal_Insert_Output_Data{sels = sels, buffer = buffer, cmdline = cmdline, mode = d.mode, ctx = ctx}
	err := selection_list_for_each(sels, normal_insert_output_apply, &apply_data, d.mode == .Append)
	selection_list_set_main_index(sels, old_main)
	if apply_data.shell_err {
		normal_fail(ctx, "shell command failed")
	} else if err != .None {
		normal_fail(ctx, buffer_error_message(err))
	}
}

// normal_insert_output implements !/A-! (port of insert_output<mode>).
normal_insert_output :: proc(ctx: ^Context, params: Normal_Params, mode: Paste_Mode) {
	default_reg := params.reg if params.reg != 0 else '|'
	reg_name := normal_reg_name(default_reg, context.temp_allocator)
	defer delete(reg_name, context.temp_allocator)
	default_command, reg_err := context_main_sel_register_value(ctx, reg_name)
	if reg_err != .None {
		default_command = ""
	}
	alloc := normal_alloc(ctx)
	d := new(normal_Insert_Output_Prompt, alloc)
	d.default_command = strings.clone(default_command, alloc)
	d.mode = mode
	d.edition = context_scoped_selection_edition_make(ctx)
	d.allocator = alloc
	completer := Prompt_Completer{call = normal_shell_complete_call}
	callback := Prompt_Callback{call = normal_insert_output_call, data = d, destroy = normal_insert_output_prompt_destroy}
	faces := context_faces(ctx)
	prompt := "insert-output:" if mode == .Insert else "append-output:"
	input_handler_prompt(
		context_input_handler(ctx), prompt, "", default_command,
		input_handler_face(faces, "Prompt"),
		{.Drop_History_Entries_With_Blank_Prefix}, '|',
		completer, callback,
	)
}

// normal_direction_flags maps search direction to compile flags
// (port of direction_flags).
normal_direction_flags :: proc(forward: bool) -> Regex_Vm_Compile_Flags {
	if forward {
		return {}
	}
	return {.Backward, .No_Forward}
}

// normal_Regex_Kind selects the regex prompt follow-up.
normal_Regex_Kind :: enum {
	Search,
	Select,
	Split,
	Keep,
}

// normal_Regex_Data owns the regex prompt state (port of the
// regex_prompt lambda captures).
normal_Regex_Data :: struct {
	kind:             normal_Regex_Kind,
	reg:              rune,
	forward:          bool,
	mode:             normal_Select_Mode,
	count:            int,
	capture:          int,
	matching:         bool,
	default_pattern:  string,
	saved_selections: Selection_List,
	saved_reg:        [dynamic]string,
	position:         Coord_Display,
	edition:          Scoped_Selection_Edition,
	allocator:        mem.Allocator,
}

normal_regex_destroy :: proc(data: rawptr, allocator: mem.Allocator) {
	_ = allocator
	d := cast(^normal_Regex_Data)(data)
	context_scoped_selection_edition_destroy(&d.edition)
	selection_list_destroy(&d.saved_selections)
	for s in d.saved_reg {
		delete(s, d.allocator)
	}
	delete(d.saved_reg)
	delete(d.default_pattern, d.allocator)
	free(d, d.allocator)
}

// normal_regex_word_start finds the word under the regex cursor (port
// of the current_word lambda): the word before pos, unescaping a
// single leading backslash. Returns the byte start and the word view.
normal_regex_word_start :: proc(regex_text: string, pos: int) -> (
	int,
	string,
) {
	it := pos
	for it != 0 {
		prev := it - 1
		for prev > 0 && (regex_text[prev] & 0xC0) == 0x80 {
			prev -= 1
		}
		p := prev
		cp := utf8_read_codepoint(regex_text, &p)
		extra := []rune{'_'}
		if !unicode_is_word(cp, extra) {
			break
		}
		it = prev
	}
	word := regex_text[it:pos]
	if it == 0 || len(word) == 0 {
		return it, word
	}
	backslashes := 0
	for bs := it; bs != 0 && regex_text[bs - 1] == '\\'; bs -= 1 {
		backslashes += 1
	}
	if backslashes % 2 == 1 {
		return it, word[1:]
	}
	return it, word
}

normal_regex_complete :: proc(data: rawptr, ctx: ^Context, text: string, cursor_pos: Units_ByteCount, allocator: mem.Allocator) -> Completions {
	_ = data
	pos := min(int(cursor_pos), len(text))
	word_start, word := normal_regex_word_start(text, pos)
	matches := word_db_find_matching(word_db_get(context_buffer(ctx)), word, context.temp_allocator)
	defer delete(matches)
	filtered := make([dynamic]Ranked_Match, 0, context.temp_allocator)
	defer delete(filtered)
	for m in matches {
		if m.matches {
			append(&filtered, m)
		}
	}
	slice.sort_by(filtered[:], ranked_match_less)
	candidates := make(Candidate_List, 0, min(len(filtered), 100), allocator)
	for m in filtered[:min(len(filtered), 100)] {
		append(&candidates, strings.clone(m.candidate, allocator))
	}
	return Completions{candidates = candidates, start = Units_ByteCount(word_start), end = cursor_pos}
}

// normal_selection_take moves val into sel, deep-copying captures
// into allocator (val's own captures stay with the caller).
normal_selection_take :: proc(sel: ^Selection, val: Selection, allocator: mem.Allocator) {
	owned := selection_clone(val, allocator)
	selection_destroy(sel, allocator)
	sel^ = owned
}

// normal_select_next_matches selects the next count matches (port of
// select_next_matches). detail carries the failure message.
normal_select_next_matches :: proc(ctx: ^Context, re: ^Regex, forward: bool, count: int) -> (Normal_Error, string) {
	remaining := count
	for {
		sels := context_selections(ctx)
		for &sel in sels.selections {
			found, _, err := selectors_find_next_match(ctx, sel, re, forward, context.temp_allocator)
			if err != .None {
				return .Failed, selectors_error_message(err)
			}
			defer selection_destroy(&found, context.temp_allocator)
			normal_selection_take(&sel, selectors_keep_direction(found, sel), sels.allocator)
		}
		selection_list_sort_and_merge_overlapping(sels)
		remaining -= 1
		if remaining <= 0 {
			break
		}
	}
	return .None, ""
}

// normal_extend_to_next_matches extends to the next count matches
// (port of extend_to_next_matches). detail carries the failure message.
normal_extend_to_next_matches :: proc(ctx: ^Context, re: ^Regex, forward: bool, count: int) -> (Normal_Error, string) {
	remaining := count
	new_sels := make([dynamic]Selection, 0, context.temp_allocator)
	defer delete(new_sels)
	for {
		sels := context_selections(ctx)
		clear(&new_sels)
		main_index := sels.main
		for &sel in sels.selections {
			found, wrapped, err := selectors_find_next_match(ctx, sel, re, forward, context.temp_allocator)
			if err != .None {
				return .Failed, selectors_error_message(err)
			}
			defer selection_destroy(&found, context.temp_allocator)
			if !wrapped {
				merged := sel
				normal_merge_selections(&merged, found)
				append(&new_sels, merged)
			} else if len(new_sels) <= main_index && main_index != 0 {
				main_index -= 1
			}
		}
		if len(new_sels) == 0 {
			return .Failed, "All selections wrapped"
		}
		normal_selection_list_set_cloned(sels, new_sels[:], main_index)
		remaining -= 1
		if remaining <= 0 {
			break
		}
	}
	return .None, ""
}

// normal_regex_apply runs the prompt follow-up for kind. detail
// carries the failure message for Validate-time reporting.
normal_regex_apply :: proc(d: ^normal_Regex_Data, re: ^Regex, ctx: ^Context) -> (Normal_Error, string) {
	switch d.kind {
	case .Search:
		if regex_empty(re) || len(regex_str(re)) == 0 {
			return .None, ""
		}
		if d.mode == .Extend {
			return normal_extend_to_next_matches(ctx, re, d.forward, d.count)
		}
		return normal_select_next_matches(ctx, re, d.forward, d.count)
	case .Select, .Split:
		if regex_empty(re) || len(regex_str(re)) == 0 {
			return .None, ""
		}
		buffer := context_buffer(ctx)
		sels := context_selections(ctx)
		matched: [dynamic]Selection
		err: Selectors_Error
		if d.kind == .Select {
			matched, err = selectors_select_matches(buffer, sels.selections[:], re, d.capture, context.temp_allocator)
		} else {
			matched, err = selectors_split_on_matches(buffer, sels.selections[:], re, d.capture, context.temp_allocator)
		}
		if err != .None || len(matched) == 0 {
			detail := "no matches found"
			if err != .None {
				detail = selectors_error_message(err)
			}
			for &m in matched {
				selection_destroy(&m, context.temp_allocator)
			}
			delete(matched)
			return .Failed, detail
		}
		defer {
			for &m in matched {
				selection_destroy(&m, context.temp_allocator)
			}
			delete(matched)
		}
		selection_list_set(sels, matched[:], len(matched) - 1)
		return .None, ""
	case .Keep:
		if regex_empty(re) || len(regex_str(re)) == 0 {
			return .None, ""
		}
		return normal_keep_apply(ctx, re, d.matching)
	}
	unreachable()
}

normal_regex_call :: proc(data: rawptr, text: string, event: Prompt_Event, ctx: ^Context) {
	d := cast(^normal_Regex_Data)(data)
	reg := normal_register(ctx, d.reg)
	if event != .Change && context_has_client(ctx) {
		client_info_hide(context_client(ctx))
	}
	incsearch := normal_opt_bool(ctx, "incsearch")
	if incsearch {
		selection_list_update(&d.saved_selections)
		context_assign_selections(ctx, d.saved_selections)
		if context_has_window(ctx) {
			window_set_position(context_window(ctx), d.position)
		}
		input_handler_set_prompt_face(context_input_handler(ctx), input_handler_face(context_faces(ctx), "Prompt"))
		register_manager_restore(reg, ctx, d.saved_reg[:])
	}
	regex_failed := false
	runtime_failed := false
	detail := ""
	switch event {
	case .Abort:
		return
	case .Change:
		if !incsearch {
			return
		}
		if len(text) != 0 {
			register_manager_set(reg, ctx, []string{text})
		}
	case .Validate:
		if len(text) != 0 {
			register_manager_set(reg, ctx, []string{text})
		}
		context_push_jump(ctx)
	}
	pattern := text if len(text) != 0 else d.default_pattern
	re, msg, re_err := regex_make(pattern, normal_direction_flags(d.forward), context.temp_allocator)
	defer delete(msg, context.temp_allocator)
	if re_err != .None {
		regex_failed = true
	} else {
		defer regex_destroy(&re)
		if err, apply_detail := normal_regex_apply(d, &re, ctx); err != .None {
			runtime_failed = true
			if err == .No_Selections_Remaining {
				detail = normal_error_message(err)
			} else {
				detail = apply_detail
			}
		}
	}
	if regex_failed {
		if event == .Validate {
			normal_fail(ctx, "regex error")
			// The C++ throws to exec(); stash it for exec() to
			// report since this callback cannot return it.
			input_handler_set_key_error(context_input_handler(ctx), .Error, "regex error")
		} else {
			input_handler_set_prompt_face(context_input_handler(ctx), input_handler_face(context_faces(ctx), "Error"))
		}
		return
	}
	if runtime_failed {
		context_assign_selections(ctx, d.saved_selections)
		if event == .Validate {
			normal_fail(ctx, detail)
			// The C++ assigns the empty selection list and the next
			// command throws; fail here instead since the port keeps
			// selections non-empty.
			input_handler_set_key_error(context_input_handler(ctx), .Error, detail)
		}
	}
}

// normal_regex_prompt opens a regex prompt (port of regex_prompt).
normal_regex_prompt :: proc(
	ctx: ^Context,
	prompt: string,
	reg: rune,
	forward: bool,
	kind: normal_Regex_Kind,
	mode: normal_Select_Mode = .Replace,
	count: int = 0,
	capture: int = 0,
	matching: bool = true,
) {
	alloc := normal_alloc(ctx)
	position := Coord_Display{} if !context_has_window(ctx) else window_position(context_window(ctx))
	d := new(normal_Regex_Data, alloc)
	d.kind = kind
	d.reg = reg
	d.forward = forward
	d.mode = mode
	d.count = count
	d.capture = capture
	d.matching = matching
	d.position = position
	d.edition = context_scoped_selection_edition_make(ctx)
	d.allocator = alloc
	sels := context_selections(ctx)
	d.saved_selections = selection_list_clone(sels, alloc)
	// save returns an owned deep copy; the prompt takes it over and
	// frees it in normal_regex_destroy.
	d.saved_reg = register_manager_save(normal_register(ctx, reg), ctx, alloc)
	main_value := register_manager_get_main(normal_register(ctx, reg), ctx, sels.main)
	d.default_pattern = strings.clone(main_value, alloc)
	completer := Prompt_Completer{call = normal_regex_complete, data = d}
	callback := Prompt_Callback{call = normal_regex_call, data = d, destroy = normal_regex_destroy}
	faces := context_faces(ctx)
	input_handler_prompt(
		context_input_handler(ctx), prompt, "", main_value,
		input_handler_face(faces, "Prompt"),
		{.Search}, reg,
		completer, callback,
	)
}

// normal_search implements //?/A-//A-? (port of search()).
normal_search :: proc(ctx: ^Context, params: Normal_Params, mode: normal_Select_Mode, forward: bool) {
	prompt := "search:"
	if mode == .Extend {
		prompt = "search (extend):" if forward else "reverse search (extend):"
	} else if !forward {
		prompt = "reverse search:"
	}
	reg := unicode_to_lower(params.reg if params.reg != 0 else '/')
	normal_regex_prompt(ctx, prompt, reg, forward, .Search, mode, params.count)
}

// normal_search_next implements n/N/A-n/A-N (port of search_next()).
normal_search_next :: proc(ctx: ^Context, params: Normal_Params, mode: normal_Select_Mode, forward: bool) {
	reg := unicode_to_lower(params.reg if params.reg != 0 else '/')
	strs := register_manager_get_values(normal_register(ctx, reg), ctx, context.temp_allocator)
	if len(strs) == 0 || len(strs[0]) == 0 {
		normal_fail(ctx, "no search pattern")
		return
	}
	re, msg, re_err := regex_make(strs[0], normal_direction_flags(forward), context.temp_allocator)
	defer delete(msg, context.temp_allocator)
	if re_err != .None {
		normal_fail(ctx, "regex error")
		return
	}
	defer regex_destroy(&re)
	edition := context_scoped_selection_edition_make(ctx)
	defer context_scoped_selection_edition_destroy(&edition)
	sels := context_selections(ctx)
	main_wrapped := false
	count := params.count
	for {
		wrapped := false
		if mode == .Replace {
			main := selection_list_main(sels)
			found, w, err := selectors_find_next_match(ctx, main^, &re, forward, context.temp_allocator)
			if err != .None {
				normal_fail(ctx, selectors_error_message(err))
				return
			}
			defer selection_destroy(&found, context.temp_allocator)
			normal_selection_take(main, selectors_keep_direction(found, main^), sels.allocator)
			wrapped = w
		} else if mode == .Append {
			main := selection_list_main(sels)
			found, w, err := selectors_find_next_match(ctx, main^, &re, forward, context.temp_allocator)
			if err != .None {
				normal_fail(ctx, selectors_error_message(err))
				return
			}
			defer selection_destroy(&found, context.temp_allocator)
			append(&sels.selections, selection_clone(selectors_keep_direction(found, main^), sels.allocator))
			sels.main = len(sels.selections) - 1
			wrapped = w
		}
		selection_list_sort_and_merge_overlapping(sels)
		main_wrapped = main_wrapped || wrapped
		count -= 1
		if count <= 0 {
			break
		}
	}
	if main_wrapped {
		normal_print_info(ctx, "main selection search wrapped around buffer")
	}
}

// normal_use_selection_as_search_pattern implements */A-* (port of
// use_selection_as_search_pattern<smart>).
normal_use_selection_as_search_pattern :: proc(ctx: ^Context, params: Normal_Params, smart: bool) {
	buffer := context_buffer(ctx)
	patterns := make(map[string]struct{}, context.temp_allocator)
	defer delete(patterns)
	for &sel in context_selections(ctx).selections {
		beg := input_handler_sel_min(&sel)
		end := buffer_char_next(buffer, input_handler_sel_max(&sel))
		content := buffer_string(buffer, beg, end, context.temp_allocator)
		defer delete(content, context.temp_allocator)
		escaped := string_utils_escape(content, "^$\\.*+?()[]{}|", '\\', context.temp_allocator)
		defer delete(escaped, context.temp_allocator)
		sb := strings.builder_make(context.temp_allocator)
		defer strings.builder_destroy(&sb)
		if smart && selectors_is_bow(buffer, beg) {
			strings.write_string(&sb, "\\b")
		}
		strings.write_string(&sb, escaped)
		if smart && selectors_is_eow(buffer, end) {
			strings.write_string(&sb, "\\b")
		}
		patterns[strings.to_string(sb)] = {}
	}
	sb := strings.builder_make(context.temp_allocator)
	defer strings.builder_destroy(&sb)
	first := true
	for pattern in patterns {
		if !first {
			strings.write_byte(&sb, '|')
		}
		first = false
		strings.write_string(&sb, pattern)
	}
	joined := strings.clone(strings.to_string(sb), context.temp_allocator)
	reg := unicode_to_lower(params.reg if params.reg != 0 else '/')
	reg_str := normal_reg_name(reg, context.temp_allocator)
	msg, _ := format_format("register '{}' set to '{}'", []string{reg_str, joined}, context.temp_allocator)
	normal_print_info(ctx, msg)
	register_manager_set(normal_register(ctx, reg), ctx, []string{joined})
	if context_has_client(ctx) {
		client_force_redraw(context_client(ctx), false)
	}
}

// normal_cmd_select_regex implements s (port of select_regex).
normal_cmd_select_regex :: proc(ctx: ^Context, params: Normal_Params) {
	reg := unicode_to_lower(params.reg if params.reg != 0 else '/')
	capture := params.count
	prompt := "select:"
	prompt_owned := ""
	if capture != 0 {
		cap_str := format_to_string_int(capture, context.temp_allocator)
		prompt_owned, _ = format_format("select (capture {}):", []string{cap_str}, context.temp_allocator)
		prompt = prompt_owned
	}
	normal_regex_prompt(ctx, prompt, reg, true, .Select, .Replace, 0, capture)
}

// normal_cmd_split_regex implements S (port of split_regex).
normal_cmd_split_regex :: proc(ctx: ^Context, params: Normal_Params) {
	reg := unicode_to_lower(params.reg if params.reg != 0 else '/')
	capture := params.count
	prompt := "split:"
	prompt_owned := ""
	if capture != 0 {
		cap_str := format_to_string_int(capture, context.temp_allocator)
		prompt_owned, _ = format_format("split (on capture {}):", []string{cap_str}, context.temp_allocator)
		prompt = prompt_owned
	}
	normal_regex_prompt(ctx, prompt, reg, true, .Split, .Replace, 0, capture)
}

// normal_cmd_split_lines implements A-s (port of split_lines).
normal_cmd_split_lines :: proc(ctx: ^Context, params: Normal_Params) {
	count := Units_LineCount(params.count if params.count != 0 else 1)
	edition := context_scoped_selection_edition_make(ctx)
	defer context_scoped_selection_edition_destroy(&edition)
	sels := context_selections(ctx)
	buffer := context_buffer(ctx)
	res := make([dynamic]Selection, 0, context.temp_allocator)
	defer delete(res)
	for &sel in sels.selections {
		if sel.anchor.line == sel.cursor.line {
			append(&res, sel)
			continue
		}
		sel_min := input_handler_sel_min(&sel)
		sel_max := input_handler_sel_max(&sel)
		line := sel_min.line
		for line <= sel_max.line {
			last_line := min(line + count - 1, buffer_line_count(buffer) - 1)
			lo := sel_min if coord_compare(sel_min, Coord_Buffer{line, 0}) >= 0 else Coord_Buffer{line, 0}
			line_end := Coord_Buffer{last_line, Units_ByteCount(len(buffer_line(buffer, last_line)) - 1)}
			hi := sel_max if coord_compare(sel_max, line_end) <= 0 else line_end
			append(&res, selectors_keep_direction(Selection{basic = Basic_Selection{anchor = lo, cursor = coord_buffer_and_target(hi)}}, sel))
			line += count
		}
	}
	normal_selection_list_set_cloned(sels, res[:], len(res) - 1)
}

// normal_cmd_select_boundaries implements A-S (port of select_boundaries).
normal_cmd_select_boundaries :: proc(ctx: ^Context, params: Normal_Params) {
	_ = params
	edition := context_scoped_selection_edition_make(ctx)
	defer context_scoped_selection_edition_destroy(&edition)
	sels := context_selections(ctx)
	res := make([dynamic]Selection, 0, context.temp_allocator)
	defer delete(res)
	for &sel in sels.selections {
		sel_min := input_handler_sel_min(&sel)
		sel_max := input_handler_sel_max(&sel)
		append(&res, input_handler_selection_from_coord(sel_min))
		if sel_min != sel_max {
			append(&res, input_handler_selection_from_coord(sel_max))
		}
	}
	selection_list_set(sels, res[:], len(res) - 1)
}

// normal_cmd_join_lines_select_spaces implements A-J (port of
// join_lines_select_spaces): selects the line-break runs, then
// replaces them with single spaces.
normal_cmd_join_lines_select_spaces :: proc(ctx: ^Context, params: Normal_Params) {
	_ = params
	buffer := context_buffer(ctx)
	edition := context_scoped_selection_edition_make(ctx)
	defer context_scoped_selection_edition_destroy(&edition)
	selections := make([dynamic]Selection, 0, context.temp_allocator)
	defer delete(selections)
	for &sel in context_selections(ctx).selections {
		min_line := input_handler_sel_min(&sel).line
		max_line := input_handler_sel_max(&sel).line
		extra := Units_LineCount(1) if min_line == max_line else Units_LineCount(0)
		end_line := min(buffer_line_count(buffer) - 1, max_line + extra)
		line := min_line
		for line < end_line {
			line_len := Units_ByteCount(len(buffer_line(buffer, line)))
			begin := Coord_Buffer{line, line_len - 1}
			end := buffer_next(buffer, begin)
			for end != buffer_end_coord(buffer) && unicode_is_horizontal_blank(rune(buffer_byte_at(buffer, end))) {
				end = buffer_next(buffer, end)
			}
			end_sel := buffer_prev(buffer, end)
			append(&selections, Selection{basic = Basic_Selection{anchor = begin, cursor = coord_buffer_and_target(end_sel)}})
			line += 1
		}
	}
	if len(selections) == 0 {
		return
	}
	sels := context_selections_write_only(ctx)
	selection_list_set(sels, selections[:], len(selections) - 1)
	selection_list_merge_consecutive(sels)
	edit := context_scoped_edition_make(ctx)
	defer context_scoped_edition_destroy(&edit)
	if err := selection_list_replace_strings(sels, []string{" "}); err != .None {
		normal_fail(ctx, buffer_error_message(err))
	}
}

// normal_cmd_join_lines implements A-j (port of join_lines):
// join_lines_select_spaces, then restore the selections.
normal_cmd_join_lines :: proc(ctx: ^Context, params: Normal_Params) {
	saved := selection_list_clone(context_selections(ctx))
	defer selection_list_destroy(&saved)
	normal_cmd_join_lines_select_spaces(ctx, params)
	selection_list_update(&saved)
	context_assign_selections(ctx, saved)
}

// normal_keep_apply keeps selections matching re iff matching (port
// of the keep() follow-up).
normal_keep_apply :: proc(ctx: ^Context, re: ^Regex, matching: bool) -> (Normal_Error, string) {
	buffer := context_buffer(ctx)
	text := buffer_string(buffer, Coord_Buffer{0, 0}, buffer_end_coord(buffer), context.temp_allocator)
	defer delete(text, context.temp_allocator)
	keep := make([dynamic]Selection, 0, context.temp_allocator)
	defer delete(keep)
	for &sel in context_selections(ctx).selections {
		begin := input_handler_sel_min(&sel)
		end := buffer_char_next(buffer, input_handler_sel_max(&sel))
		begin_off := int(buffer_distance(buffer, Coord_Buffer{0, 0}, begin))
		end_off := int(buffer_distance(buffer, Coord_Buffer{0, 0}, end))
		flags := regex_match_flags(
			selectors_is_bol(begin), false,
			selectors_is_bow(buffer, begin), selectors_is_eow(buffer, end),
		)
		if regex_search_simple(text, begin_off, end_off, re, flags) == matching {
			append(&keep, sel)
		}
	}
	if len(keep) == 0 {
		return .No_Selections_Remaining, ""
	}
	normal_selection_list_set_cloned(context_selections(ctx), keep[:], len(keep) - 1)
	return .None, ""
}

// normal_cmd_keep implements A-k/A-K (port of keep<matching>).
normal_cmd_keep :: proc(ctx: ^Context, params: Normal_Params, matching: bool) {
	reg := unicode_to_lower(params.reg if params.reg != 0 else '/')
	prompt := "keep matching:" if matching else "keep not matching:"
	normal_regex_prompt(ctx, prompt, reg, true, .Keep, .Replace, 0, 0, matching)
}

// normal_Keep_Pipe_Data owns the keep-pipe prompt state.
normal_Keep_Pipe_Data :: struct {
	default_command: string,
	edition:         Scoped_Selection_Edition,
	allocator:       mem.Allocator,
}

normal_keep_pipe_destroy :: proc(data: rawptr, allocator: mem.Allocator) {
	_ = allocator
	d := cast(^normal_Keep_Pipe_Data)(data)
	context_scoped_selection_edition_destroy(&d.edition)
	delete(d.default_command, d.allocator)
	free(d, d.allocator)
}

normal_keep_pipe_call :: proc(data: rawptr, text: string, event: Prompt_Event, ctx: ^Context) {
	d := cast(^normal_Keep_Pipe_Data)(data)
	if event != .Validate {
		return
	}
	cmdline := text if len(text) != 0 else d.default_command
	if len(cmdline) == 0 {
		return
	}
	buffer := context_buffer(ctx)
	sels := context_selections(ctx)
	old_main := sels.main
	keep := make([dynamic]Selection, 0, context.temp_allocator)
	defer delete(keep)
	new_main := -1
	for i in 0 ..< len(sels.selections) {
		sel := sels.selections[i]
		selection_list_set_main_index(sels, i)
		content := normal_sel_content(buffer, sel, context.temp_allocator)
		defer delete(content, context.temp_allocator)
		shell_ctx := Shell_Context{}
		res, err := shell_manager_eval_full(cmdline, ctx, &shell_ctx, content, Shell_Flags{}, context.temp_allocator)
		defer shell_manager_eval_result_free(&res, context.temp_allocator)
		if err != .None {
			normal_fail(ctx, shell_manager_error_message(err))
			return
		}
		if res.status == 0 {
			append(&keep, sel)
			if i >= old_main && new_main == -1 {
				new_main = len(keep) - 1
			}
		}
	}
	if len(keep) == 0 {
		normal_fail(ctx, normal_error_message(.No_Selections_Remaining))
		return
	}
	if new_main == -1 {
		new_main = len(keep) - 1
	}
	selection_list_set(sels, keep[:], new_main)
}

// normal_cmd_keep_pipe implements $ (port of keep_pipe).
normal_cmd_keep_pipe :: proc(ctx: ^Context, params: Normal_Params) {
	default_reg := params.reg if params.reg != 0 else '|'
	reg_name := normal_reg_name(default_reg, context.temp_allocator)
	defer delete(reg_name, context.temp_allocator)
	default_command, reg_err := context_main_sel_register_value(ctx, reg_name)
	if reg_err != .None {
		default_command = ""
	}
	alloc := normal_alloc(ctx)
	d := new(normal_Keep_Pipe_Data, alloc)
	d.default_command = strings.clone(default_command, alloc)
	d.edition = context_scoped_selection_edition_make(ctx)
	d.allocator = alloc
	completer := Prompt_Completer{call = normal_shell_complete_call}
	callback := Prompt_Callback{call = normal_keep_pipe_call, data = d, destroy = normal_keep_pipe_destroy}
	faces := context_faces(ctx)
	input_handler_prompt(
		context_input_handler(ctx), "keep pipe:", "", default_command,
		input_handler_face(faces, "Prompt"),
		{.Drop_History_Entries_With_Blank_Prefix}, '|',
		completer, callback,
	)
}

// normal_cmd_indent implements >/A-> (port of indent<indent_empty>).
normal_cmd_indent :: proc(ctx: ^Context, params: Normal_Params, indent_empty: bool) {
	count := params.count if params.count != 0 else 1
	indent_width := normal_opt_int(ctx, "indentwidth")
	indent_buf := make([dynamic]u8, 0, context.temp_allocator)
	defer delete(indent_buf)
	if indent_width == 0 {
		for _ in 0 ..< count {
			append(&indent_buf, u8('\t'))
		}
	} else {
		for _ in 0 ..< indent_width * count {
			append(&indent_buf, u8(' '))
		}
	}
	indent := string(indent_buf[:])
	edition := context_scoped_edition_make(ctx)
	defer context_scoped_edition_destroy(&edition)
	buffer := context_buffer(ctx)
	last_line := Units_LineCount(0)
	sel_edition := context_scoped_selection_edition_make(ctx)
	defer context_scoped_selection_edition_destroy(&sel_edition)
	for &sel in context_selections(ctx).selections {
		line := max(last_line, input_handler_sel_min(&sel).line)
		max_line := input_handler_sel_max(&sel).line + 1
		for line < max_line {
			if indent_empty || len(buffer_line(buffer, line)) > 1 {
				if _, err := buffer_insert(buffer, Coord_Buffer{line, 0}, indent); err != .None {
					normal_fail(ctx, buffer_error_message(err))
					return
				}
			}
			line += 1
		}
		last_line = input_handler_sel_max(&sel).line + 1
	}
}

// normal_cmd_deindent implements </A-< (port of
// deindent<deindent_incomplete>).
normal_cmd_deindent :: proc(ctx: ^Context, params: Normal_Params, deindent_incomplete: bool) {
	count := Units_ColumnCount(params.count if params.count != 0 else 1)
	tabstop := Units_ColumnCount(normal_opt_int(ctx, "tabstop"))
	indent_width := Units_ColumnCount(normal_opt_int(ctx, "indentwidth"))
	if indent_width == 0 {
		indent_width = tabstop
	}
	indent_width = indent_width * count
	buffer := context_buffer(ctx)
	last_line := Units_LineCount(0)
	sel_edition := context_scoped_selection_edition_make(ctx)
	defer context_scoped_selection_edition_destroy(&sel_edition)
	for &sel in context_selections(ctx).selections {
		line := max(input_handler_sel_min(&sel).line, last_line)
		max_line := input_handler_sel_max(&sel).line + 1
		for line < max_line {
			width := Units_ColumnCount(0)
			content := buffer_line(buffer, line)
			column := 0
			for column < len(content) {
				c := content[column]
				if c == '\t' {
					width = (width / tabstop + 1) * tabstop
				} else if c == ' ' {
					width += 1
				} else {
					if deindent_incomplete && width != 0 {
						if _, err := buffer_erase(buffer, Coord_Buffer{line, 0}, Coord_Buffer{line, Units_ByteCount(column)}); err != .None {
							normal_fail(ctx, buffer_error_message(err))
							return
						}
					}
					break
				}
				if width >= indent_width {
					if _, err := buffer_erase(buffer, Coord_Buffer{line, 0}, Coord_Buffer{line, Units_ByteCount(column) + 1}); err != .None {
						normal_fail(ctx, buffer_error_message(err))
						return
					}
					break
				}
				column += 1
			}
			line += 1
		}
		last_line = input_handler_sel_max(&sel).line + 1
	}
}

// normal_Object_Kind selects the text object.
normal_Object_Kind :: enum {
	Word,
	Big_Word,
	Sentence,
	Paragraph,
	Whitespace,
	Indent,
	Number,
	Argument,
	Pair,
	Punct,
	Custom,
}

// normal_Object_Data carries object selection state (port of the
// select_object lambda captures). custom_open/close are owned when
// kind is Custom.
normal_Object_Data :: struct {
	kind:         normal_Object_Kind,
	open:         rune,
	close:        rune,
	cp:           rune,
	custom_open:  string,
	custom_close: string,
	count:        int,
	flags:        Selectors_Object_Flags,
	mode:         normal_Select_Mode,
}

normal_object_data_clone :: proc(data: rawptr, allocator: mem.Allocator) -> rawptr {
	src := cast(^normal_Object_Data)(data)
	dst := new(normal_Object_Data, allocator)
	dst^ = src^
	if src.kind == .Custom {
		dst.custom_open = strings.clone(src.custom_open, allocator)
		dst.custom_close = strings.clone(src.custom_close, allocator)
	}
	return dst
}

normal_object_data_destroy :: proc(data: rawptr, allocator: mem.Allocator) {
	d := cast(^normal_Object_Data)(data)
	if d.kind == .Custom {
		delete(d.custom_open, allocator)
		delete(d.custom_close, allocator)
	}
	free(d, allocator)
}

// normal_object_regexes builds the open/close patterns for Pair,
// Punct and Custom kinds (temp allocator).
normal_object_regexes :: proc(d: ^normal_Object_Data) -> (
	string,
	string,
) {
	buf: [4]byte
	switch d.kind {
	case .Pair:
		n := utf8_dump(d.open, buf[:])
		open := strings.concatenate({"\\Q", string(buf[:n])}, context.temp_allocator)
		n = utf8_dump(d.close, buf[:])
		close := strings.concatenate({"\\Q", string(buf[:n])}, context.temp_allocator)
		return open, close
	case .Punct:
		n := utf8_dump(d.cp, buf[:])
		re := strings.concatenate({"\\Q", string(buf[:n])}, context.temp_allocator)
		return re, re
	case .Custom:
		return d.custom_open, d.custom_close
	case .Word, .Big_Word, .Sentence, .Paragraph, .Whitespace, .Indent, .Number, .Argument:
		unreachable()
	}
	unreachable()
}

// normal_object_apply selects the object around sel (port of the
// non-nested object functors).
normal_object_apply :: proc(data: rawptr, ctx: ^Context, sel: Selection) -> (Selection, bool) {
	d := cast(^normal_Object_Data)(data)
	switch d.kind {
	case .Word:
		return selectors_select_word(ctx, sel, d.count, d.flags, .Word)
	case .Big_Word:
		return selectors_select_word(ctx, sel, d.count, d.flags, .Big_Word)
	case .Sentence:
		return selectors_select_sentence(ctx, sel, d.count, d.flags)
	case .Paragraph:
		return selectors_select_paragraph(ctx, sel, d.count, d.flags)
	case .Whitespace:
		return selectors_select_whitespaces(ctx, sel, d.count, d.flags)
	case .Indent:
		return selectors_select_indent(ctx, sel, d.count, d.flags)
	case .Number:
		return selectors_select_number(ctx, sel, d.count, d.flags)
	case .Argument:
		return selectors_select_argument(ctx, sel, d.count, d.flags)
	case .Pair, .Punct, .Custom:
		open_pat, close_pat := normal_object_regexes(d)
		defer if d.kind != .Custom {
			delete(open_pat, context.temp_allocator)
			delete(close_pat, context.temp_allocator)
		}
		open_re, open_msg, open_err := regex_make(open_pat, {.Backward}, context.temp_allocator)
		defer delete(open_msg, context.temp_allocator)
		if open_err != .None {
			return {}, false
		}
		defer regex_destroy(&open_re)
		close_re, close_msg, close_err := regex_make(close_pat, {.Backward}, context.temp_allocator)
		defer delete(close_msg, context.temp_allocator)
		if close_err != .None {
			return {}, false
		}
		defer regex_destroy(&close_re)
		return selectors_select_surrounding(ctx, sel, &open_re, &close_re, d.count, d.flags)
	}
	unreachable()
}

// normal_object_nested_run replaces the selections with the nested
// objects (port of select_nested_and_set_last's immediate half).
normal_object_nested_run :: proc(ctx: ^Context, d: ^normal_Object_Data) -> Normal_Error {
	edition := context_scoped_selection_edition_make(ctx)
	defer context_scoped_selection_edition_destroy(&edition)
	matched: [dynamic]Selection
	err: Selectors_Error
	switch d.kind {
	case .Word:
		matched, err = selectors_select_nested_words(ctx, d.count, d.flags, .Word, context.temp_allocator)
	case .Big_Word:
		matched, err = selectors_select_nested_words(ctx, d.count, d.flags, .Big_Word, context.temp_allocator)
	case .Sentence:
		matched, err = selectors_select_nested_sentences(ctx, d.count, d.flags, context.temp_allocator)
	case .Paragraph:
		matched, err = selectors_select_nested_paragraphs(ctx, d.count, d.flags, context.temp_allocator)
	case .Whitespace:
		matched, err = selectors_select_nested_whitespaces(ctx, d.count, d.flags, context.temp_allocator)
	case .Indent:
		matched, err = selectors_select_nested_indents(ctx, d.count, d.flags, context.temp_allocator)
	case .Number:
		matched, err = selectors_select_nested_numbers(ctx, d.count, d.flags, context.temp_allocator)
	case .Argument:
		matched, err = selectors_select_nested_arguments(ctx, d.count, d.flags, context.temp_allocator)
	case .Pair, .Punct, .Custom:
		open_pat, close_pat := normal_object_regexes(d)
		defer if d.kind != .Custom {
			delete(open_pat, context.temp_allocator)
			delete(close_pat, context.temp_allocator)
		}
		open_re, open_msg, open_err := regex_make(open_pat, {}, context.temp_allocator)
		defer delete(open_msg, context.temp_allocator)
		if open_err != .None {
			return .Failed
		}
		defer regex_destroy(&open_re)
		if open_pat == close_pat {
			matched, err = selectors_regex_select_nested_delim(ctx, &open_re, d.flags, context.temp_allocator)
		} else {
			close_re, close_msg, close_err := regex_make(close_pat, {}, context.temp_allocator)
			defer delete(close_msg, context.temp_allocator)
			if close_err != .None {
				return .Failed
			}
			defer regex_destroy(&close_re)
			matched, err = selectors_regex_select_nested(ctx, &open_re, &close_re, d.count, d.flags, context.temp_allocator)
		}
	}
	if err != .None {
		return .Failed
	}
	defer {
		for &m in matched {
			selection_destroy(&m, context.temp_allocator)
		}
		delete(matched)
	}
	selection_list_set(context_selections(ctx), matched[:], len(matched) - 1)
	return .None
}

normal_object_nested_last_call :: proc(data: rawptr, ctx: ^Context) {
	d := cast(^normal_Object_Data)(data)
	if err := normal_object_nested_run(ctx, d); err != .None {
		normal_fail(ctx, normal_error_message(err))
	}
}

// normal_object_select runs the object selection and records it
// (port of select_nested_and_set_last / select_and_set_last).
normal_object_select :: proc(ctx: ^Context, d: ^normal_Object_Data, nested: bool) {
	if nested {
		record := cast(^normal_Object_Data)(normal_object_data_clone(d, ctx.allocator))
		context_set_last_select(ctx, normal_object_nested_last_call, record, normal_object_data_destroy)
		if err := normal_object_nested_run(ctx, d); err != .None {
			normal_fail(ctx, normal_error_message(err))
		}
		return
	}
	if err := normal_select_and_set_last(
		ctx, d.mode, normal_object_apply, d,
		normal_object_data_destroy, normal_object_data_clone,
	); err != .None {
		normal_fail(ctx, normal_error_message(err))
	}
}

// normal_Object_Prompt_Data owns the custom-desc prompt state.
normal_Object_Prompt_Data :: struct {
	count:     int,
	flags:     Selectors_Object_Flags,
	mode:      normal_Select_Mode,
	nested:    bool,
	info:      bool,
	allocator: mem.Allocator,
}

normal_object_prompt_destroy :: proc(data: rawptr, allocator: mem.Allocator) {
	_ = allocator
	d := cast(^normal_Object_Prompt_Data)(data)
	free(d, d.allocator)
}

// normal_parse_object_desc splits "open,close" on the unescaped comma
// and unescapes \, (port of the desc parsing in select_object).
normal_parse_object_desc :: proc(cmdline: string, allocator := context.allocator) -> (
	string,
	string,
	bool,
) {
	sep := -1
	escaped := false
	for i in 0 ..< len(cmdline) {
		c := cmdline[i]
		if escaped {
			escaped = false
			continue
		}
		if c == '\\' {
			escaped = true
			continue
		}
		if c == ',' {
			sep = i
			break
		}
	}
	if sep < 0 {
		return "", "", false
	}
	open := string_utils_unescape(cmdline[:sep], ",\\", '\\', allocator)
	close := string_utils_unescape(cmdline[sep + 1:], ",\\", '\\', allocator)
	if len(open) == 0 || len(close) == 0 {
		delete(open, allocator)
		delete(close, allocator)
		return "", "", false
	}
	return open, close, true
}

normal_object_prompt_call :: proc(data: rawptr, text: string, event: Prompt_Event, ctx: ^Context) {
	d := cast(^normal_Object_Prompt_Data)(data)
	if event != .Change {
		input_handler_hide_auto_info_ifn(ctx, d.info)
	}
	if event != .Validate {
		return
	}
	open, close, ok := normal_parse_object_desc(text, context.temp_allocator)
	defer delete(open, context.temp_allocator)
	defer delete(close, context.temp_allocator)
	if !ok {
		normal_fail(ctx, "desc parsing failed, expected <open>,<close>")
		return
	}
	obj := normal_Object_Data{
		kind = .Custom, custom_open = open, custom_close = close,
		count = d.count, flags = d.flags, mode = d.mode,
	}
	normal_object_select(ctx, &obj, d.nested)
}

// normal_Object_Key_Data carries select_object parameters.
normal_Object_Key_Data :: struct {
	params: Normal_Params,
	flags:  Selectors_Object_Flags,
	mode:   normal_Select_Mode,
}

normal_object_key_destroy :: proc(data: rawptr, allocator: mem.Allocator) {
	free(cast(^normal_Object_Key_Data)(data), allocator)
}

// normal_object_pair_for maps a key to a surrounding pair.
normal_object_pair_for :: proc(key: Keys_Key) -> (
	rune,
	rune,
	bool,
) {
	pairs := [7][3]rune{
		[3]rune{'(', ')', 'b'},
		[3]rune{'{', '}', 'B'},
		[3]rune{'[', ']', 'r'},
		[3]rune{'<', '>', 'a'},
		[3]rune{'"', '"', 'Q'},
		[3]rune{'\'' , '\'', 'q'},
		[3]rune{'`', '`', 'g'},
	}
	for p in pairs {
		if (key.modifiers == keys_MOD_NONE && (key.key == p[0] || key.key == p[1] || key.key == p[2])) {
			return p[0], p[1], true
		}
	}
	return 0, 0, false
}

normal_object_key_call :: proc(data: rawptr, key: Keys_Key, ctx: ^Context) {
	d := cast(^normal_Object_Key_Data)(data)
	if input_handler_key_is(key, keys_MOD_NONE, keys_ESCAPE) {
		return
	}
	nested := .Nested in d.flags
	count := d.params.count - 1 if d.params.count > 0 else 0
	obj := normal_Object_Data{count = count, flags = d.flags, mode = d.mode}
	// Builtin objects.
	if key.modifiers == keys_MOD_NONE {
		switch key.key {
		case 'w':
			obj.kind = .Word
			normal_object_select(ctx, &obj, nested)
			return
		case 's':
			obj.kind = .Sentence
			normal_object_select(ctx, &obj, nested)
			return
		case 'p':
			obj.kind = .Paragraph
			normal_object_select(ctx, &obj, nested)
			return
		case 'i':
			obj.kind = .Indent
			normal_object_select(ctx, &obj, nested)
			return
		case 'n':
			obj.kind = .Number
			normal_object_select(ctx, &obj, nested)
			return
		case 'u':
			obj.kind = .Argument
			normal_object_select(ctx, &obj, nested)
			return
		case 'c':
			info := input_handler_show_auto_info_ifn(
				"Enter object desc",
				"format: <open regex>,<close regex>\n        escape commas with '\\'",
				{.Command}, ctx,
			)
			alloc := normal_alloc(ctx)
			pd := new(normal_Object_Prompt_Data, alloc)
			pd^ = normal_Object_Prompt_Data{count = count, flags = d.flags, mode = d.mode, nested = nested, info = info, allocator = alloc}
			completer := Prompt_Completer{call = normal_complete_nothing_call}
			callback := Prompt_Callback{call = normal_object_prompt_call, data = pd, destroy = normal_object_prompt_destroy}
			faces := context_faces(ctx)
			input_handler_prompt(
				context_input_handler(ctx), "object desc:", "", "",
				input_handler_face(faces, "Prompt"),
				Prompt_Flags{}, '_',
				completer, callback,
			)
			return
		}
		if key.key == keys_SPACE {
			obj.kind = .Whitespace
			normal_object_select(ctx, &obj, nested)
			return
		}
	} else if key.modifiers == keys_MOD_ALT && key.key == 'w' {
		obj.kind = .Big_Word
		normal_object_select(ctx, &obj, nested)
		return
	} else if key.modifiers == keys_MOD_ALT && key.key == ';' {
		alloc := normal_alloc(ctx)
		env_vars := normal_count_register_env_vars(d.params.count, d.params.reg, alloc)
		mode_name := "replace"
		if d.mode == .Extend {
			mode_name = "extend"
		} else if d.mode == .Append {
			mode_name = "append"
		}
		env_vars[strings.clone("select_mode", alloc)] = strings.clone(mode_name, alloc)
		flag_sb := strings.builder_make(alloc)
		first := true
		all_flags := Selectors_Object_Flags{.To_Begin, .To_End, .Inner, .Nested}
		for f in all_flags {
			if f in d.flags {
				if !first {
					strings.write_byte(&flag_sb, ',')
				}
				first = false
				name := "to_begin"
				if f == .To_End {
					name = "to_end"
				} else if f == .Inner {
					name = "inner"
				} else if f == .Nested {
					name = "nested"
				}
				strings.write_string(&flag_sb, name)
			}
		}
		env_vars[strings.clone("object_flags", alloc)] = strings.to_string(flag_sb)
		normal_command_prompt(ctx, env_vars)
		return
	}
	if open, close, found := normal_object_pair_for(key); found {
		obj.kind = .Pair
		obj.open = open
		obj.close = close
		normal_object_select(ctx, &obj, nested)
		return
	}
	if cp, ok := keys_codepoint(key); ok && unicode_is_punctuation(cp, []rune{}) {
		obj.kind = .Punct
		obj.cp = cp
		normal_object_select(ctx, &obj, nested)
	}
}

// normal_select_object implements the object keys (port of
// select_object(flags, mode)).
normal_select_object :: proc(ctx: ^Context, params: Normal_Params, flags: Selectors_Object_Flags, mode: normal_Select_Mode = .Replace) {
	whole := .To_Begin in flags && .To_End in flags
	verb := "extend" if mode == .Extend else "select"
	to := "" if whole else "to "
	inner := "inner " if .Inner in flags else ""
	kind := "nested" if .Nested in flags else "surrounding"
	end := ""
	if !whole {
		end = " begin" if .To_Begin in flags else " end"
	}
	verb_s := strings.clone(verb, context.temp_allocator)
	defer delete(verb_s, context.temp_allocator)
	to_s := strings.clone(to, context.temp_allocator)
	defer delete(to_s, context.temp_allocator)
	inner_s := strings.clone(inner, context.temp_allocator)
	defer delete(inner_s, context.temp_allocator)
	kind_s := strings.clone(kind, context.temp_allocator)
	defer delete(kind_s, context.temp_allocator)
	end_s := strings.clone(end, context.temp_allocator)
	defer delete(end_s, context.temp_allocator)
	title, _ := format_format(
		"{} {}{}{} object{}", []string{verb_s, to_s, inner_s, kind_s, end_s}, context.temp_allocator,
	)
	defer delete(title, context.temp_allocator)
	alloc := normal_alloc(ctx)
	d := new(normal_Object_Key_Data, alloc)
	d^ = normal_Object_Key_Data{params = params, flags = flags, mode = mode}
	cmd := Key_Callback{call = normal_object_key_call, data = d, destroy = normal_object_key_destroy}
	b := []Keys_Key{{keys_MOD_NONE, 'b'}, {keys_MOD_NONE, '('}, {keys_MOD_NONE, ')'}}
	bb := []Keys_Key{{keys_MOD_NONE, 'B'}, {keys_MOD_NONE, '{'}, {keys_MOD_NONE, '}'}}
	r := []Keys_Key{{keys_MOD_NONE, 'r'}, {keys_MOD_NONE, '['}, {keys_MOD_NONE, ']'}}
	a := []Keys_Key{{keys_MOD_NONE, 'a'}, {keys_MOD_NONE, '<'}, {keys_MOD_NONE, '>'}}
	qd := []Keys_Key{{keys_MOD_NONE, '"'}, {keys_MOD_NONE, 'Q'}}
	qs := []Keys_Key{{keys_MOD_NONE, '\''}, {keys_MOD_NONE, 'q'}}
	g := []Keys_Key{{keys_MOD_NONE, '`'}, {keys_MOD_NONE, 'g'}}
	w := []Keys_Key{{keys_MOD_NONE, 'w'}}
	aw := []Keys_Key{{keys_MOD_ALT, 'w'}}
	s := []Keys_Key{{keys_MOD_NONE, 's'}}
	p := []Keys_Key{{keys_MOD_NONE, 'p'}}
	sp := []Keys_Key{{keys_MOD_NONE, keys_SPACE}}
	i := []Keys_Key{{keys_MOD_NONE, 'i'}}
	u := []Keys_Key{{keys_MOD_NONE, 'u'}}
	n := []Keys_Key{{keys_MOD_NONE, 'n'}}
	c := []Keys_Key{{keys_MOD_NONE, 'c'}}
	as_ := []Keys_Key{{keys_MOD_ALT, ';'}}
	infos := []normal_Key_Info{
		{b[:], "parenthesis block"},
		{bb[:], "brace block"},
		{r[:], "bracket block"},
		{a[:], "angle block"},
		{qd[:], "double quote string"},
		{qs[:], "single quote string"},
		{g[:], "grave quote string"},
		{w[:], "word"},
		{aw[:], "WORD"},
		{s[:], "sentence"},
		{p[:], "paragraph"},
		{sp[:], "whitespaces"},
		{i[:], "indent"},
		{u[:], "argument"},
		{n[:], "number"},
		{c[:], "custom object desc"},
		{as_[:], "run command in object context"},
	}
	info := normal_build_autoinfo_for_mapping(ctx, .Object, infos, context.temp_allocator)
	defer delete(info, context.temp_allocator)
	input_handler_on_next_key_with_autoinfo(ctx, "text-object", .Object, cmd, title, info)
}

// normal_cmd_scroll implements the page scroll keys (port of
// scroll<direction, half>).
normal_cmd_scroll :: proc(ctx: ^Context, params: Normal_Params, direction: Direction, half: bool) {
	win := context_window(ctx)
	count := params.count if params.count != 0 else 1
	divisor := Units_LineCount(2) if half else Units_LineCount(1)
	offset := (window_dimensions(win).line - 2) / divisor * Units_LineCount(count)
	if direction == .Backward {
		offset = -offset
	}
	input_handler_scroll_window(ctx, offset, .Move_Cursor_And_Anchor)
}

// normal_cmd_copy_selections_on_next_lines implements C/A-C (port of
// copy_selections_on_next_lines<direction>).
normal_cmd_copy_selections_on_next_lines :: proc(ctx: ^Context, params: Normal_Params, direction: Direction) {
	edition := context_scoped_selection_edition_make(ctx)
	defer context_scoped_selection_edition_destroy(&edition)
	sels := context_selections(ctx)
	buffer := context_buffer(ctx)
	tabstop := Units_ColumnCount(normal_opt_int(ctx, "tabstop"))
	result := make([dynamic]Selection, 0, context.temp_allocator)
	defer delete(result)
	main_index := 0
	for &sel in sels.selections {
		is_main := &sel == selection_list_main(sels)
		anchor := sel.anchor
		cursor := sel.cursor
		cursor_col := buffer_utils_get_column(buffer, tabstop, cursor.coord)
		anchor_col := buffer_utils_get_column(buffer, tabstop, anchor)
		if is_main {
			main_index = len(result)
		}
		append(&result, sel)
		top := min(anchor.line, cursor.line)
		bottom := max(anchor.line, cursor.line)
		height := bottom - top + 1
		max_lines := max(params.count, 1)
		nb_sels := 0
		i := 0
		for nb_sels < max_lines {
			step := Units_LineCount(i + 1) * height
			offset := step if direction == .Forward else -step
			anchor_line := anchor.line + offset
			cursor_line := cursor.line + offset
			if anchor_line < 0 || cursor_line < 0 ||
			   anchor_line >= buffer_line_count(buffer) || cursor_line >= buffer_line_count(buffer) {
				break
			}
			anchor_byte := buffer_utils_get_byte_to_column(buffer, tabstop, Coord_Display{anchor_line, anchor_col})
			cursor_byte := buffer_utils_get_byte_to_column(buffer, tabstop, Coord_Display{cursor_line, cursor_col})
			if anchor_byte != Units_ByteCount(len(buffer_line(buffer, anchor_line))) &&
			   cursor_byte != Units_ByteCount(len(buffer_line(buffer, cursor_line))) {
				if is_main {
					main_index = len(result)
				}
				append(
					&result,
					Selection{
						basic = Basic_Selection{
							anchor = Coord_Buffer{anchor_line, anchor_byte},
							cursor = coord_buffer_and_target(
								Coord_Buffer{cursor_line, cursor_byte}, cursor.target, cursor.display_target,
							),
						},
					},
				)
				nb_sels += 1
			}
			i += 1
		}
	}
	normal_selection_list_set_cloned(sels, result[:], main_index)
	selection_list_sort_and_merge_overlapping(sels)
}

// normal_cmd_rotate_selections implements (/} (port of
// rotate_selections<direction>).
normal_cmd_rotate_selections :: proc(ctx: ^Context, params: Normal_Params, direction: Direction) {
	count := params.count if params.count != 0 else 1
	edition := context_scoped_selection_edition_make(ctx)
	defer context_scoped_selection_edition_destroy(&edition)
	sels := context_selections(ctx)
	index := sels.main
	num := len(sels.selections)
	if direction == .Forward {
		selection_list_set_main_index(sels, (index + count) % num)
	} else {
		selection_list_set_main_index(sels, (index + (num - count % num)) % num)
	}
}

// normal_cmd_rotate_selections_content implements A-(/A-) (port of
// rotate_selections_content<direction>).
normal_cmd_rotate_selections_content :: proc(ctx: ^Context, params: Normal_Params, direction: Direction) {
	strs := context_selections_content(ctx, context.temp_allocator)
	defer {
		for s in strs {
			delete(s, context.temp_allocator)
		}
		delete(strs)
	}
	group := params.count
	if group <= 0 || group > len(strs) {
		group = len(strs)
	}
	count := 1 % group
	edition := context_scoped_selection_edition_make(ctx)
	defer context_scoped_selection_edition_destroy(&edition)
	sels := context_selections(ctx)
	main := sels.main
	it := 0
	for it < len(strs) {
		end := min(len(strs), it + group)
		new_beg := end - count if direction == .Forward else it + count
		// Rotate [it, end) around new_beg.
		tmp := make([dynamic]string, 0, context.temp_allocator)
		defer delete(tmp)
		for k in new_beg ..< end {
			append(&tmp, strs[k])
		}
		for k in it ..< new_beg {
			append(&tmp, strs[k])
		}
		for k in it ..< end {
			strs[k] = tmp[k - it]
		}
		if it <= main && main < end {
			main = end - (new_beg - main) if main < new_beg else it + (main - new_beg)
		}
		it = end
	}
	if err := selection_list_replace_strings(sels, strs[:]); err != .None {
		normal_fail(ctx, buffer_error_message(err))
		return
	}
	selection_list_set_main_index(sels, main)
}

// normal_To_Char_Data carries to-char parameters (port of the
// select_to_next_char lambda captures).
normal_To_Char_Data :: struct {
	cp:        rune,
	count:     int,
	flags:     normal_Select_Flags,
}

normal_to_char_data_clone :: proc(data: rawptr, allocator: mem.Allocator) -> rawptr {
	dst := new(normal_To_Char_Data, allocator)
	dst^ = (cast(^normal_To_Char_Data)(data))^
	return dst
}

normal_to_char_data_destroy :: proc(data: rawptr, allocator: mem.Allocator) {
	free(cast(^normal_To_Char_Data)(data), allocator)
}

normal_to_char_apply :: proc(data: rawptr, ctx: ^Context, sel: Selection) -> (Selection, bool) {
	d := cast(^normal_To_Char_Data)(data)
	if .Reverse in d.flags {
		return selectors_select_to_reverse(ctx, sel, d.cp, d.count, .Inclusive in d.flags)
	}
	return selectors_select_to(ctx, sel, d.cp, d.count, .Inclusive in d.flags)
}

// normal_To_Char_Key_Data carries the key callback parameters.
normal_To_Char_Key_Data :: struct {
	params: Normal_Params,
	flags:  normal_Select_Flags,
}

normal_to_char_key_destroy :: proc(data: rawptr, allocator: mem.Allocator) {
	free(cast(^normal_To_Char_Key_Data)(data), allocator)
}

normal_to_char_key_call :: proc(data: rawptr, key: Keys_Key, ctx: ^Context) {
	d := cast(^normal_To_Char_Key_Data)(data)
	cp, ok := keys_codepoint(key)
	if !ok || input_handler_key_is(key, keys_MOD_NONE, keys_ESCAPE) {
		return
	}
	mode := normal_Select_Mode.Extend if .Extend in d.flags else normal_Select_Mode.Replace
	apply_data := normal_To_Char_Data{cp = cp, count = d.params.count, flags = d.flags}
	if err := normal_select_and_set_last(
		ctx, mode, normal_to_char_apply, &apply_data,
		normal_to_char_data_destroy, normal_to_char_data_clone,
	); err != .None {
		normal_fail(ctx, normal_error_message(err))
	}
}

// normal_select_to_next_char implements t/f/T/F/A-t/A-f/A-T/A-F
// (port of select_to_next_char<flags>).
normal_select_to_next_char :: proc(ctx: ^Context, params: Normal_Params, flags: normal_Select_Flags) {
	verb := "extend" if .Extend in flags else "select"
	onto := "onto" if .Inclusive in flags else "to"
	prev := "previous" if .Reverse in flags else "next"
	verb_s := strings.clone(verb, context.temp_allocator)
	defer delete(verb_s, context.temp_allocator)
	onto_s := strings.clone(onto, context.temp_allocator)
	defer delete(onto_s, context.temp_allocator)
	prev_s := strings.clone(prev, context.temp_allocator)
	defer delete(prev_s, context.temp_allocator)
	title, _ := format_format("{} {} {} char", []string{verb_s, onto_s, prev_s}, context.temp_allocator)
	defer delete(title, context.temp_allocator)
	alloc := normal_alloc(ctx)
	d := new(normal_To_Char_Key_Data, alloc)
	d^ = normal_To_Char_Key_Data{params = params, flags = flags}
	cmd := Key_Callback{call = normal_to_char_key_call, data = d, destroy = normal_to_char_key_destroy}
	input_handler_on_next_key_with_autoinfo(ctx, "to-char", .None, cmd, title, "enter char to select to")
}

// normal_macro_running guards against recursive macro execution
// (port of the replay_macro static).
normal_macro_running: [27]bool

// normal_cmd_start_or_end_macro_recording implements Q (port of
// start_or_end_macro_recording).
normal_cmd_start_or_end_macro_recording :: proc(ctx: ^Context, params: Normal_Params) {
	handler := context_input_handler(ctx)
	if input_handler_is_recording(handler) {
		input_handler_stop_recording(handler)
		return
	}
	reg := unicode_to_lower(params.reg if params.reg != 0 else '@')
	if !keys_is_basic_alpha(reg) && reg != '@' {
		normal_fail(ctx, "macros can only use the '@' and alphabetic registers")
		return
	}
	input_handler_start_recording(handler, reg)
}

// normal_cmd_replay_macro implements q (port of replay_macro).
normal_cmd_replay_macro :: proc(ctx: ^Context, params: Normal_Params) {
	reg := unicode_to_lower(params.reg if params.reg != 0 else '@')
	if !keys_is_basic_alpha(reg) && reg != '@' {
		normal_fail(ctx, "macros can only use the '@' and alphabetic registers")
		return
	}
	idx := int(reg - 'a') if reg != '@' else 26
	if normal_macro_running[idx] {
		normal_fail(ctx, "recursive macros call detected")
		return
	}
	strs := register_manager_get_values(normal_register(ctx, reg), ctx, context.temp_allocator)
	if len(strs) == 0 || len(strs[0]) == 0 {
		reg_str := normal_reg_name(reg, context.temp_allocator)
		msg, _ := format_format("register '{}' is empty", []string{reg_str}, context.temp_allocator)
		normal_fail(ctx, msg)
		return
	}
	normal_macro_running[idx] = true
	defer normal_macro_running[idx] = false
	keys, parse_err := keys_parse(strs[0], context.temp_allocator)
	defer delete(keys)
	if parse_err != .None {
		normal_fail(ctx, "macro parse error")
		return
	}
	edition := context_scoped_edition_make(ctx)
	defer context_scoped_edition_destroy(&edition)
	sel_edition := context_scoped_selection_edition_make(ctx)
	defer context_scoped_selection_edition_destroy(&sel_edition)
	guard := utils_scoped_bool_make(context_keymaps_disabled(ctx))
	defer utils_scoped_bool_release(&guard)
	count := params.count
	for {
		for key in keys {
			input_handler_handle_key(context_input_handler(ctx), key)
		}
		count -= 1
		if count <= 0 {
			break
		}
	}
}

// normal_cmd_jump implements C-i/C-o (port of jump<direction>).
normal_cmd_jump :: proc(ctx: ^Context, params: Normal_Params, direction: Direction) {
	count := max(1, params.count)
	jl := context_jump_list(ctx)
	target: ^Selection_List
	err: Context_Error
	if direction == .Forward {
		target, err = context_jump_forward(jl, ctx, count)
	} else {
		target, err = context_jump_backward(jl, ctx, count)
	}
	if err != .None {
		normal_fail(ctx, context_error_message(err))
		// The C++ throws to exec(); stash it for exec() to report
		// since normal commands cannot return errors.
		input_handler_set_key_error(context_input_handler(ctx), .Error, context_error_message(err))
		return
	}
	old_buffer := context_buffer(ctx)
	edition := context_scoped_selection_edition_make(ctx)
	defer context_scoped_selection_edition_destroy(&edition)
	if target.buffer != old_buffer {
		context_change_buffer(ctx, target.buffer)
	}
	context_assign_selections(ctx, target^)
}

// normal_cmd_push_selections implements C-s (port of push_selections).
normal_cmd_push_selections :: proc(ctx: ^Context, params: Normal_Params) {
	_ = params
	context_push_jump(ctx, true)
	count_str := format_to_string_int(len(context_selections(ctx).selections), context.temp_allocator)
	msg, _ := format_format("saved {} selections", []string{count_str}, context.temp_allocator)
	normal_print_info(ctx, msg)
}

// normal_cmd_align implements & (port of align).
normal_cmd_align :: proc(ctx: ^Context, params: Normal_Params) {
	_ = params
	edition := context_scoped_selection_edition_make(ctx)
	defer context_scoped_selection_edition_destroy(&edition)
	sels := context_selections(ctx)
	buffer := context_buffer(ctx)
	tabstop := Units_ColumnCount(normal_opt_int(ctx, "tabstop"))
	columns := make([dynamic][dynamic]^Selection, 0, context.temp_allocator)
	defer {
		for &col in columns {
			delete(col)
		}
		delete(columns)
	}
	last_line := Units_LineCount(-1)
	column := 0
	for &sel in sels.selections {
		line := sel.cursor.line
		if sel.anchor.line != line {
			normal_fail(ctx, "align cannot work with multi line selections")
			return
		}
		column = column + 1 if line == last_line else 0
		for len(columns) <= column {
			append(&columns, make([dynamic]^Selection, 0, context.temp_allocator))
		}
		append(&columns[column], &sel)
		last_line = line
	}
	use_tabs := normal_opt_bool(ctx, "aligntab")
	for &col in columns {
		maxcol := Units_ColumnCount(0)
		for sel in col {
			maxcol = max(maxcol, buffer_utils_get_column(buffer, tabstop, sel.cursor.coord))
		}
		for sel in col {
			insert_coord := input_handler_sel_min(sel)
			lastcol := buffer_utils_get_column(buffer, tabstop, sel.cursor.coord)
			inscount := maxcol - lastcol
			pad := make([dynamic]u8, 0, context.temp_allocator)
			defer delete(pad)
			if !use_tabs {
				for _ in 0 ..< int(inscount) {
					append(&pad, u8(' '))
				}
			} else {
				inscol := buffer_utils_get_column(buffer, tabstop, insert_coord)
				targetcol := inscol + inscount
				tabcol := inscol - (inscol % tabstop)
				tabs := int((targetcol - tabcol) / tabstop)
				spaces := int(targetcol - (tabcol + Units_ColumnCount(tabs) * tabstop if tabs != 0 else inscol))
				for _ in 0 ..< tabs {
					append(&pad, u8('\t'))
				}
				for _ in 0 ..< spaces {
					append(&pad, u8(' '))
				}
			}
			if _, err := buffer_insert(buffer, insert_coord, string(pad[:])); err != .None {
				normal_fail(ctx, buffer_error_message(err))
				return
			}
		}
		selection_list_update(sels)
	}
}

// normal_cmd_copy_indent implements A-& (port of copy_indent).
normal_cmd_copy_indent :: proc(ctx: ^Context, params: Normal_Params) {
	selection := params.count
	buffer := context_buffer(ctx)
	edition := context_scoped_selection_edition_make(ctx)
	defer context_scoped_selection_edition_destroy(&edition)
	sels := context_selections(ctx)
	lines := make([dynamic]Units_LineCount, 0, context.temp_allocator)
	defer delete(lines)
	for &sel in sels.selections {
		l := input_handler_sel_min(&sel).line
		top := input_handler_sel_max(&sel).line + 1
		for l < top {
			append(&lines, l)
			l += 1
		}
	}
	if selection > len(sels.selections) {
		normal_fail(ctx, "invalid selection index")
		return
	}
	if selection == 0 {
		selection = sels.main + 1
	}
	ref_line := input_handler_sel_min(&sels.selections[selection - 1]).line
	line := buffer_line(buffer, ref_line)
	it := 0
	for it < len(line) && unicode_is_horizontal_blank(rune(line[it])) {
		it += 1
	}
	indent := line[:it]
	edit := context_scoped_edition_make(ctx)
	defer context_scoped_edition_destroy(&edit)
	for l in lines {
		if l == ref_line {
			continue
		}
		content := buffer_line(buffer, l)
		i := 0
		for i < len(content) && unicode_is_horizontal_blank(rune(content[i])) {
			i += 1
		}
		if _, err := buffer_replace(buffer, Coord_Buffer{l, 0}, Coord_Buffer{l, Units_ByteCount(i)}, indent); err != .None {
			normal_fail(ctx, buffer_error_message(err))
			return
		}
	}
}

// normal_cmd_tabs_to_spaces implements @ (port of tabs_to_spaces).
normal_cmd_tabs_to_spaces :: proc(ctx: ^Context, params: Normal_Params) {
	buffer := context_buffer(ctx)
	opt_tabstop := Units_ColumnCount(normal_opt_int(ctx, "tabstop"))
	tabstop := opt_tabstop if params.count == 0 else Units_ColumnCount(params.count)
	tabs := make([dynamic]Selection, 0, context.temp_allocator)
	defer delete(tabs)
	spaces := make([dynamic]string, 0, context.temp_allocator)
	defer {
		for s in spaces {
			delete(s, context.temp_allocator)
		}
		delete(spaces)
	}
	edition := context_scoped_selection_edition_make(ctx)
	defer context_scoped_selection_edition_destroy(&edition)
	sel_edition := context_scoped_selection_edition_make(ctx)
	defer context_scoped_selection_edition_destroy(&sel_edition)
	for &sel in context_selections(ctx).selections {
		it := input_handler_sel_min(&sel)
		end := buffer_char_next(buffer, input_handler_sel_max(&sel))
		for it != end {
			if buffer_byte_at(buffer, it) == '\t' {
				col := buffer_utils_get_column(buffer, opt_tabstop, it)
				end_col := (col / tabstop + 1) * tabstop
				append(&tabs, input_handler_selection_from_coord(it))
				pad := make([]u8, int(end_col - col), context.temp_allocator)
				for &b in pad {
					b = u8(' ')
				}
				append(&spaces, string(pad))
			}
			it = buffer_next(buffer, it)
		}
	}
	if len(tabs) == 0 {
		return
	}
	helper := selection_list_make(buffer, tabs[:], buffer_timestamp(buffer), context.temp_allocator)
	defer selection_list_destroy(&helper)
	if err := selection_list_replace_strings(&helper, spaces[:]); err != .None {
		normal_fail(ctx, buffer_error_message(err))
	}
}

// normal_cmd_spaces_to_tabs implements A-@ (port of spaces_to_tabs).
normal_cmd_spaces_to_tabs :: proc(ctx: ^Context, params: Normal_Params) {
	buffer := context_buffer(ctx)
	opt_tabstop := Units_ColumnCount(normal_opt_int(ctx, "tabstop"))
	tabstop := opt_tabstop if params.count == 0 else Units_ColumnCount(params.count)
	blanks := make([dynamic]Selection, 0, context.temp_allocator)
	defer delete(blanks)
	edition := context_scoped_edition_make(ctx)
	defer context_scoped_edition_destroy(&edition)
	sel_edition := context_scoped_selection_edition_make(ctx)
	defer context_scoped_selection_edition_destroy(&sel_edition)
	for &sel in context_selections(ctx).selections {
		it := input_handler_sel_min(&sel)
		end := buffer_char_next(buffer, input_handler_sel_max(&sel))
		for it != end {
			if buffer_byte_at(buffer, it) == ' ' {
				beg := it
				it = buffer_next(buffer, it)
				col := buffer_utils_get_column(buffer, opt_tabstop, it)
				for it != end && buffer_byte_at(buffer, it) == ' ' && (col % tabstop) != 0 {
					it = buffer_next(buffer, it)
					col += 1
				}
				if (col % tabstop) == 0 {
					append(&blanks, Selection{basic = Basic_Selection{anchor = beg, cursor = coord_buffer_and_target(buffer_prev(buffer, it))}})
				} else if it != end && buffer_byte_at(buffer, it) == '\t' {
					append(&blanks, Selection{basic = Basic_Selection{anchor = beg, cursor = coord_buffer_and_target(it)}})
					it = buffer_next(buffer, it)
				}
			} else {
				it = buffer_next(buffer, it)
			}
		}
	}
	if len(blanks) == 0 {
		return
	}
	helper := selection_list_make(buffer, blanks[:], buffer_timestamp(buffer), context.temp_allocator)
	defer selection_list_destroy(&helper)
	if err := selection_list_replace_strings(&helper, []string{"\t"}); err != .None {
		normal_fail(ctx, buffer_error_message(err))
	}
}

// normal_cmd_trim_selections implements _ (port of trim_selections).
normal_cmd_trim_selections :: proc(ctx: ^Context, params: Normal_Params) {
	_ = params
	buffer := context_buffer(ctx)
	edition := context_scoped_selection_edition_make(ctx)
	defer context_scoped_selection_edition_destroy(&edition)
	sels := context_selections(ctx)
	to_remove := make([dynamic]int, 0, context.temp_allocator)
	defer delete(to_remove)
	for i in 0 ..< len(sels.selections) {
		sel := &sels.selections[i]
		beg := input_handler_sel_min(sel)
		end := input_handler_sel_max(sel)
		beg_text := buffer_string(buffer, beg, buffer_char_next(buffer, end), context.temp_allocator)
		defer delete(beg_text, context.temp_allocator)
		// Trim blank codepoints from both ends.
		start_off := 0
		pos := 0
		n := utf8_distance(beg_text)
		for pos < n {
			p := utf8_advance(beg_text, 0, pos)
			q := p
			if !unicode_is_blank(utf8_read_codepoint(beg_text, &q)) {
				break
			}
			pos += 1
		}
		start_off = pos
		end_off := n - 1
		for end_off >= pos {
			p := utf8_advance(beg_text, 0, end_off)
			q := p
			if !unicode_is_blank(utf8_read_codepoint(beg_text, &q)) {
				break
			}
			end_off -= 1
		}
		if start_off > end_off {
			append(&to_remove, i)
			continue
		}
		new_min := buffer_advance(buffer, beg, Units_ByteCount(utf8_advance(beg_text, 0, start_off)))
		new_max := buffer_advance(buffer, beg, Units_ByteCount(utf8_advance(beg_text, 0, end_off)))
		input_handler_sel_set_min_max(sel, new_min, new_max)
	}
	if len(to_remove) == len(sels.selections) {
		normal_fail(ctx, normal_error_message(.No_Selections_Remaining))
		return
	}
	for i := len(to_remove) - 1; i >= 0; i -= 1 {
		selection_list_remove(sels, to_remove[i])
	}
}

// normal_selection_list_set_cloned replaces the list with deep copies
// of res. res may alias the live selections (selection_list_set
// destroys the live elements before cloning, so passing aliases to
// it directly would clone freed captures).
normal_selection_list_set_cloned :: proc(sels: ^Selection_List, res: []Selection, main: int) {
	tmp := make([dynamic]Selection, 0, len(res), context.temp_allocator)
	defer delete(tmp)
	defer {
		for &sel in tmp {
			selection_destroy(&sel, context.temp_allocator)
		}
	}
	for sel in res {
		append(&tmp, selection_clone(sel, context.temp_allocator))
	}
	selection_list_set(sels, tmp[:], main)
}

// normal_read_selections_from_register parses a selections desc from
// reg (port of read_selections_from_register). Caller destroys the
// result; detail carries the failure message.
normal_read_selections_from_register :: proc(ctx: ^Context, reg: rune) -> (
	Selection_List,
	Normal_Error,
	string,
) {
	if !keys_is_basic_alpha(reg) && reg != '^' {
		return {}, .Invalid_Argument, "selections can only be saved to the '^' and alphabetic registers"
	}
	content := register_manager_get_values(normal_register(ctx, reg), ctx, context.temp_allocator)
	if len(content) < 2 {
		reg_str := normal_reg_name(reg, context.temp_allocator)
		msg, _ := format_format("register '{}' does not contain a selections desc", []string{reg_str}, context.temp_allocator)
		return {}, .Invalid_Argument, msg
	}
	head := content[0]
	last_at := -1
	for i := len(head) - 1; i >= 0; i -= 1 {
		if head[i] == '@' {
			last_at = i
			break
		}
	}
	prev_at := -1
	if last_at > 0 {
		for i := last_at - 1; i >= 0; i -= 1 {
			if head[i] == '@' {
				prev_at = i
				break
			}
		}
	}
	if last_at < 0 || prev_at < 0 {
		return {}, .Invalid_Argument, "expected <buffer>@<timestamp>@main_index"
	}
	main, main_err := string_utils_str_to_int(head[last_at + 1:])
	timestamp, ts_err := string_utils_str_to_int(head[prev_at + 1:last_at])
	if main_err != .None || ts_err != .None {
		return {}, .Invalid_Argument, "expected <buffer>@<timestamp>@main_index"
	}
	buffer_name := head[:prev_at]
	buffer, buf_err := buffer_manager_get(buffer_manager_instance(), buffer_name)
	if buf_err != .None {
		return {}, .Invalid_Argument, "expected <buffer>@<timestamp>@main_index"
	}
	list, list_err := selection_list_from_strings(buffer, .Byte, content[1:], timestamp, main)
	if list_err != .None {
		return {}, .Invalid_Argument, "expected <buffer>@<timestamp>@main_index"
	}
	return list, .None, ""
}

// normal_Combine_Op ports C++ CombineOp.
normal_Combine_Op :: enum {
	Append,
	Union,
	Intersect,
	Select_Leftmost_Cursor,
	Select_Rightmost_Cursor,
	Select_Longest,
	Select_Shortest,
}

// normal_key_to_combine_op maps a key to its combine operator (port
// of key_to_combine_op).
normal_key_to_combine_op :: proc(key: Keys_Key) -> (
	normal_Combine_Op,
	bool,
) {
	switch key.key {
	case 'a':
		return .Append, true
	case 'u':
		return .Union, true
	case 'i':
		return .Intersect, true
	case '<':
		return .Select_Leftmost_Cursor, true
	case '>':
		return .Select_Rightmost_Cursor, true
	case '+':
		return .Select_Longest, true
	case '-':
		return .Select_Shortest, true
	}
	return .Append, false
}

// normal_combine_selection merges other into sel through op (port of
// combine_selection). Whole-selection takes deep-copy captures with
// allocator so sel never aliases other's list.
normal_combine_selection :: proc(buffer: ^Buffer, sel: ^Selection, other: Selection, op: normal_Combine_Op, allocator := context.allocator) {
	o := other
	take := proc(buffer: ^Buffer, sel: ^Selection, other: Selection, allocator: mem.Allocator) {
		_ = buffer
		selection_destroy(sel, allocator)
		sel^ = selection_clone(other, allocator)
	}
	switch op {
	case .Append:
		unreachable()
	case .Union:
		sel_min := input_handler_sel_min(sel)
		other_min := input_handler_sel_min(&o)
		sel_max := input_handler_sel_max(sel)
		other_max := input_handler_sel_max(&o)
		lo := sel_min if coord_compare(sel_min, other_min) <= 0 else other_min
		hi := sel_max if coord_compare(sel_max, other_max) >= 0 else other_max
		input_handler_sel_set_min_max(sel, lo, hi)
	case .Intersect:
		sel_min := input_handler_sel_min(sel)
		other_min := input_handler_sel_min(&o)
		sel_max := input_handler_sel_max(sel)
		other_max := input_handler_sel_max(&o)
		lo := sel_min if coord_compare(sel_min, other_min) >= 0 else other_min
		hi := sel_max if coord_compare(sel_max, other_max) <= 0 else other_max
		input_handler_sel_set_min_max(sel, lo, hi)
	case .Select_Leftmost_Cursor:
		if coord_compare(sel.cursor.coord, other.cursor.coord) > 0 {
			take(buffer, sel, other, allocator)
		}
	case .Select_Rightmost_Cursor:
		if coord_compare(sel.cursor.coord, other.cursor.coord) < 0 {
			take(buffer, sel, other, allocator)
		}
	case .Select_Longest:
		if normal_char_length(buffer, sel^) < normal_char_length(buffer, other) {
			take(buffer, sel, other, allocator)
		}
	case .Select_Shortest:
		if normal_char_length(buffer, sel^) > normal_char_length(buffer, other) {
			take(buffer, sel, other, allocator)
		}
	}
}

// normal_Combine_Data owns the combine prompt state (port of the
// combine_selections lambda captures).
normal_Combine_Data :: struct {
	list:      Selection_List,
	reg:       rune,
	is_save:   bool,
	allocator: mem.Allocator,
}

normal_combine_destroy :: proc(data: rawptr, allocator: mem.Allocator) {
	_ = allocator
	d := cast(^normal_Combine_Data)(data)
	selection_list_destroy(&d.list)
	free(d, d.allocator)
}

normal_combine_call :: proc(data: rawptr, key: Keys_Key, ctx: ^Context) {
	d := cast(^normal_Combine_Data)(data)
	if input_handler_key_is(key, keys_MOD_NONE, keys_ESCAPE) {
		return
	}
	op, ok := normal_key_to_combine_op(key)
	if !ok {
		buf: [4]byte
		n := utf8_dump(key.key, buf[:])
		key_s := strings.clone(string(buf[:n]), context.temp_allocator)
		defer delete(key_s, context.temp_allocator)
		msg, _ := format_format("no such combine operator: '{}'", []string{key_s}, context.temp_allocator)
		normal_fail(ctx, msg)
		return
	}
	edition := context_scoped_selection_edition_make(ctx)
	defer context_scoped_selection_edition_destroy(&edition)
	sels := context_selections(ctx)
	selection_list_update(&d.list)
	if op == .Append {
		main_index := len(d.list.selections) + sels.main
		for &sel in sels.selections {
			selection_list_push_back(&d.list, sel)
		}
		selection_list_set_main_index(&d.list, main_index)
		selection_list_sort_and_merge_overlapping(&d.list)
	} else {
		if len(d.list.selections) != len(sels.selections) {
			a := format_to_string_int(len(d.list.selections), context.temp_allocator)
			b := format_to_string_int(len(sels.selections), context.temp_allocator)
			msg, _ := format_format(
				"the two selection lists don't have the same number of elements ({} vs {})",
				[]string{a, b}, context.temp_allocator,
			)
			normal_fail(ctx, msg)
			return
		}
		for i in 0 ..< len(d.list.selections) {
			normal_combine_selection(sels.buffer, &d.list.selections[i], sels.selections[i], op, d.list.allocator)
		}
		selection_list_set_main_index(&d.list, sels.main)
	}
	if d.is_save {
		normal_save_selections_to_register(ctx, d.reg, &d.list, true)
	} else {
		normal_restore_selections_from_list(ctx, d.reg, &d.list, true)
	}
}

// normal_combine_selections opens the combine prompt (port of
// combine_selections). list transfers to the callback data.
normal_combine_selections :: proc(ctx: ^Context, list: Selection_List, reg: rune, is_save: bool, title: string) {
	if context_buffer(ctx) != list.buffer {
		normal_fail(ctx, "cannot combine selections from different buffers")
		moved := list
		selection_list_destroy(&moved)
		return
	}
	alloc := normal_alloc(ctx)
	d := new(normal_Combine_Data, alloc)
	d.list = list
	d.reg = reg
	d.is_save = is_save
	d.allocator = alloc
	cmd := Key_Callback{call = normal_combine_call, data = d, destroy = normal_combine_destroy}
	a := []Keys_Key{{keys_MOD_NONE, 'a'}}
	u := []Keys_Key{{keys_MOD_NONE, 'u'}}
	i := []Keys_Key{{keys_MOD_NONE, 'i'}}
	lt := []Keys_Key{{keys_MOD_NONE, '<'}}
	gt := []Keys_Key{{keys_MOD_NONE, '>'}}
	plus := []Keys_Key{{keys_MOD_NONE, '+'}}
	minus := []Keys_Key{{keys_MOD_NONE, '-'}}
	infos := []normal_Key_Info{
		{a[:], "append lists"},
		{u[:], "union"},
		{i[:], "intersection"},
		{lt[:], "select leftmost cursor"},
		{gt[:], "select rightmost cursor"},
		{plus[:], "select longest"},
		{minus[:], "select shortest"},
	}
	info := normal_build_autoinfo_for_mapping(ctx, .Combine, infos, context.temp_allocator)
	defer delete(info, context.temp_allocator)
	input_handler_on_next_key_with_autoinfo(ctx, "combine-selections", .Combine, cmd, title, info)
}

// normal_save_selections_to_register writes sels descs to reg.
normal_save_selections_to_register :: proc(ctx: ^Context, reg: rune, sels: ^Selection_List, combine: bool) {
	buffer := context_buffer(ctx)
	descs := make([dynamic]string, 0, len(sels.selections) + 1, context.allocator)
	name := strings.clone(buffer_name(buffer), context.allocator)
	ts := format_to_string_int(buffer_timestamp(buffer), context.allocator)
	main := format_to_string_int(sels.main, context.allocator)
	head, _ := format_format("{}@{}@{}", []string{name, ts, main}, context.allocator)
	delete(name, context.allocator)
	delete(ts, context.allocator)
	delete(main, context.allocator)
	append(&descs, head)
	for &sel in sels.selections {
		desc, err := selection_to_string(.Byte, buffer, sel, -1, context.allocator)
		if err != .None {
			for d in descs {
				delete(d, context.allocator)
			}
			delete(descs)
			normal_fail(ctx, "cannot describe selections")
			return
		}
		append(&descs, desc)
	}
	// set clones the values, so the descriptions are freed here.
	register_manager_set(normal_register(ctx, reg), ctx, descs[:])
	for d in descs {
		delete(d, context.allocator)
	}
	delete(descs)
	verb := "Combined" if combine else "Saved"
	count_str := format_to_string_int(len(sels.selections), context.temp_allocator)
	reg_str := normal_reg_name(reg, context.temp_allocator)
	verb_s := strings.clone(verb, context.temp_allocator)
	msg, _ := format_format("{} {} selections to register '{}'", []string{verb_s, count_str, reg_str}, context.temp_allocator)
	normal_print_info(ctx, msg)
}

// normal_restore_selections_from_list assigns list and reports.
normal_restore_selections_from_list :: proc(ctx: ^Context, reg: rune, list: ^Selection_List, combine: bool) {
	size := len(list.selections)
	context_assign_selections(ctx, list^)
	verb := "Combined" if combine else "Restored"
	count_str := format_to_string_int(size, context.temp_allocator)
	reg_str := normal_reg_name(reg, context.temp_allocator)
	verb_s := strings.clone(verb, context.temp_allocator)
	msg, _ := format_format("{} {} selections from register '{}'", []string{verb_s, count_str, reg_str}, context.temp_allocator)
	normal_print_info(ctx, msg)
}

// normal_cmd_save_selections implements Z/A-Z (port of
// save_selections<combine>).
normal_cmd_save_selections :: proc(ctx: ^Context, params: Normal_Params, combine: bool) {
	reg := unicode_to_lower(params.reg if params.reg != 0 else '^')
	if !keys_is_basic_alpha(reg) && reg != '^' {
		normal_fail(ctx, "selections can only be saved to the '^' and alphabetic registers")
		return
	}
	content := register_manager_get_values(normal_register(ctx, reg), ctx, context.temp_allocator)
	empty := len(content) == 1 && len(content[0]) == 0
	if combine && !empty {
		edition := context_scoped_selection_edition_make(ctx)
		defer context_scoped_selection_edition_destroy(&edition)
		list, err, detail := normal_read_selections_from_register(ctx, reg)
		if err != .None {
			normal_fail(ctx, detail)
			return
		}
		normal_combine_selections(ctx, list, reg, true, "combine selections to register")
		return
	}
	normal_save_selections_to_register(ctx, reg, context_selections(ctx), combine)
}

// normal_cmd_restore_selections implements z/A-z (port of
// restore_selections<combine>).
normal_cmd_restore_selections :: proc(ctx: ^Context, params: Normal_Params, combine: bool) {
	reg := unicode_to_lower(params.reg if params.reg != 0 else '^')
	list, err, detail := normal_read_selections_from_register(ctx, reg)
	if err != .None {
		normal_fail(ctx, detail)
		return
	}
	edition := context_scoped_selection_edition_make(ctx)
	defer context_scoped_selection_edition_destroy(&edition)
	if !combine {
		if list.buffer != context_buffer(ctx) {
			context_change_buffer(ctx, list.buffer)
		}
		normal_restore_selections_from_list(ctx, reg, &list, false)
		selection_list_destroy(&list)
		return
	}
	normal_combine_selections(ctx, list, reg, false, "combine selections from register")
}

// normal_cmd_undo implements u (port of undo).
normal_cmd_undo :: proc(ctx: ^Context, params: Normal_Params) {
	buffer := context_buffer(ctx)
	timestamp := buffer_timestamp(buffer)
	moved, err := buffer_undo(buffer, max(1, params.count))
	if err != .None {
		normal_fail(ctx, buffer_error_message(err))
		return
	}
	if !moved {
		normal_fail(ctx, "nothing left to undo")
		return
	}
	ranges := selection_compute_modified_ranges(buffer, timestamp, context.temp_allocator)
	defer delete(ranges)
	if len(ranges) != 0 {
		selection_list_set(context_selections_write_only(ctx), ranges[:], len(ranges) - 1)
	}
}

// normal_cmd_redo implements U (port of redo).
normal_cmd_redo :: proc(ctx: ^Context, params: Normal_Params) {
	buffer := context_buffer(ctx)
	timestamp := buffer_timestamp(buffer)
	moved, err := buffer_redo(buffer, max(1, params.count))
	if err != .None {
		normal_fail(ctx, buffer_error_message(err))
		return
	}
	if !moved {
		normal_fail(ctx, "nothing left to redo")
		return
	}
	ranges := selection_compute_modified_ranges(buffer, timestamp, context.temp_allocator)
	defer delete(ranges)
	if len(ranges) != 0 {
		selection_list_set(context_selections_write_only(ctx), ranges[:], len(ranges) - 1)
	}
}

// normal_cmd_move_in_history implements C-k/C-j (port of
// move_in_history<direction>).
normal_cmd_move_in_history :: proc(ctx: ^Context, params: Normal_Params, direction: Direction) {
	buffer := context_buffer(ctx)
	timestamp := buffer_timestamp(buffer)
	count := max(1, params.count)
	step := count if direction == .Forward else -count
	history_id := int(buffer_current_history_id(buffer)) + step
	max_history_id := int(buffer_next_history_id(buffer)) - 1
	moved, err := buffer_move_to(buffer, Buffer_History_Id(history_id))
	if err != .None {
		normal_fail(ctx, buffer_error_message(err))
		return
	}
	if !moved {
		a := format_to_string_int(history_id, context.temp_allocator)
		b := format_to_string_int(max_history_id, context.temp_allocator)
		msg, _ := format_format("no such change: #{} ({})", []string{a, b}, context.temp_allocator)
		normal_fail(ctx, msg)
		return
	}
	ranges := selection_compute_modified_ranges(buffer, timestamp, context.temp_allocator)
	defer delete(ranges)
	if len(ranges) != 0 {
		selection_list_set(context_selections_write_only(ctx), ranges[:], len(ranges) - 1)
	}
	a := format_to_string_int(history_id, context.temp_allocator)
	b := format_to_string_int(max_history_id, context.temp_allocator)
	msg, _ := format_format("moved to change #{} ({})", []string{a, b}, context.temp_allocator)
	normal_print_info(ctx, msg)
}

// normal_cmd_undo_selection_change implements A-u/A-U (port of
// undo_selection_change<direction>).
normal_cmd_undo_selection_change :: proc(ctx: ^Context, params: Normal_Params, direction: Direction) {
	count := max(1, params.count)
	for _ in 0 ..< count {
		if err := context_undo_selection_change(ctx, direction); err != .None {
			normal_fail(ctx, context_error_message(err))
			return
		}
	}
}

// normal_User_Mapping_Data carries the mapping callback parameters.
normal_User_Mapping_Data :: struct {
	params: Normal_Params,
}

normal_user_mapping_destroy :: proc(data: rawptr, allocator: mem.Allocator) {
	free(cast(^normal_User_Mapping_Data)(data), allocator)
}

normal_user_mapping_call :: proc(data: rawptr, key: Keys_Key, ctx: ^Context) {
	d := cast(^normal_User_Mapping_Data)(data)
	mapping := keymap_manager_get_mapping(context_keymaps(ctx), key, .User)
	if mapping == nil {
		return
	}
	guard := utils_scoped_bool_make(context_keymaps_disabled(ctx))
	defer utils_scoped_bool_release(&guard)
	handler := context_input_handler(ctx)
	force_normal := input_handler_scoped_force_normal_make(handler, d.params)
	defer input_handler_scoped_force_normal_destroy(&force_normal)
	edition := context_scoped_edition_make(ctx)
	defer context_scoped_edition_destroy(&edition)
	sel_edition := context_scoped_selection_edition_make(ctx)
	defer context_scoped_selection_edition_destroy(&sel_edition)
	// Copy: reentrant unmap may free the mapping mid-replay.
	keys := slice.clone(mapping.keys[:], context.temp_allocator)
	defer delete(keys)
	for k in keys {
		input_handler_handle_key(handler, k)
	}
}

// normal_cmd_exec_user_mappings implements Space (port of
// exec_user_mappings).
normal_cmd_exec_user_mappings :: proc(ctx: ^Context, params: Normal_Params) {
	alloc := normal_alloc(ctx)
	d := new(normal_User_Mapping_Data, alloc)
	d^ = normal_User_Mapping_Data{params = params}
	cmd := Key_Callback{call = normal_user_mapping_call, data = d, destroy = normal_user_mapping_destroy}
	info := normal_build_autoinfo_for_mapping(ctx, .User, {}, context.temp_allocator)
	defer delete(info, context.temp_allocator)
	input_handler_on_next_key_with_autoinfo(ctx, "user-mapping", .None, cmd, "user mapping", info)
}

// normal_cmd_add_empty_line implements A-o/A-O (port of
// add_empty_line<above>).
normal_cmd_add_empty_line :: proc(ctx: ^Context, params: Normal_Params, above: bool) {
	count := max(params.count, 1)
	newlines := make([dynamic]u8, count, context.temp_allocator)
	defer delete(newlines)
	for &b in newlines {
		b = u8('\n')
	}
	buffer := context_buffer(ctx)
	edition := context_scoped_selection_edition_make(ctx)
	defer context_scoped_selection_edition_destroy(&edition)
	sels := context_selections(ctx)
	edit := context_scoped_edition_make(ctx)
	defer context_scoped_edition_destroy(&edit)
	for i in 0 ..< len(sels.selections) {
		base := input_handler_sel_min(&sels.selections[i]).line if above else input_handler_sel_max(&sels.selections[i]).line + 1
		line := base + Units_LineCount(i * count)
		if _, err := buffer_insert(buffer, Coord_Buffer{line, 0}, string(newlines[:])); err != .None {
			normal_fail(ctx, buffer_error_message(err))
			return
		}
	}
}

// normal_move_cursor moves every cursor by offset (port of
// move_cursor<Type>).
normal_move_cursor :: proc(ctx: ^Context, params: Normal_Params, direction: Direction, mode: normal_Select_Mode, by_line: bool) {
	sign := 1 if direction == .Forward else -1
	edition := context_scoped_selection_edition_make(ctx)
	defer context_scoped_selection_edition_destroy(&edition)
	sels := context_selections(ctx)
	buffer := context_buffer(ctx)
	tabstop := Units_ColumnCount(normal_opt_int(ctx, "tabstop"))
	for &sel in sels.selections {
		cursor: Coord_Buffer_And_Target
		if by_line {
			cursor = buffer_offset_coord_by_line(buffer, sel.cursor, Units_LineCount(sign * max(params.count, 1)), tabstop)
		} else {
			moved := buffer_offset_coord_by_char(buffer, sel.cursor.coord, Units_CharCount(sign * max(params.count, 1)), tabstop)
			cursor = coord_buffer_and_target(moved)
		}
		sel.anchor = sel.anchor if mode == .Extend else cursor.coord
		sel.cursor = cursor
	}
	selection_list_sort_and_merge_overlapping(sels)
}

// normal_cmd_select_whole_buffer implements % (port of
// select_whole_buffer).
normal_cmd_select_whole_buffer :: proc(ctx: ^Context, params: Normal_Params) {
	_ = params
	buffer := context_buffer(ctx)
	edition := context_scoped_selection_edition_make(ctx)
	defer context_scoped_selection_edition_destroy(&edition)
	sel := Selection{
		basic = Basic_Selection{
			anchor = Coord_Buffer{0, 0},
			cursor = Coord_Buffer_And_Target{
				coord          = buffer_back_coord(buffer),
				target         = selection_MAX_COLUMN,
				display_target = Coord_Column(-1),
			},
		},
	}
	selection_list_set(context_selections_write_only(ctx), []Selection{sel}, 0)
}

// normal_cmd_keep_selection implements , (port of keep_selection).
normal_cmd_keep_selection :: proc(ctx: ^Context, params: Normal_Params) {
	edition := context_scoped_selection_edition_make(ctx)
	defer context_scoped_selection_edition_destroy(&edition)
	sels := context_selections(ctx)
	index := params.count - 1 if params.count != 0 else sels.main
	if index >= len(sels.selections) {
		idx := format_to_string_int(index, context.temp_allocator)
		msg, _ := format_format("invalid selection index: {}", []string{idx}, context.temp_allocator)
		normal_fail(ctx, msg)
		return
	}
	normal_selection_list_set_cloned(sels, sels.selections[index:index + 1], 0)
}

// normal_cmd_remove_selection implements A-, (port of remove_selection).
normal_cmd_remove_selection :: proc(ctx: ^Context, params: Normal_Params) {
	edition := context_scoped_selection_edition_make(ctx)
	defer context_scoped_selection_edition_destroy(&edition)
	sels := context_selections(ctx)
	index := params.count - 1 if params.count != 0 else sels.main
	if index >= len(sels.selections) {
		idx := format_to_string_int(index, context.temp_allocator)
		msg, _ := format_format("invalid selection index: {}", []string{idx}, context.temp_allocator)
		normal_fail(ctx, msg)
		return
	}
	if len(sels.selections) == 1 {
		normal_fail(ctx, normal_error_message(.No_Selections_Remaining))
		return
	}
	selection_list_remove(sels, index)
}

// normal_cmd_clear_selections implements ; (port of clear_selections).
normal_cmd_clear_selections :: proc(ctx: ^Context, params: Normal_Params) {
	_ = params
	edition := context_scoped_selection_edition_make(ctx)
	defer context_scoped_selection_edition_destroy(&edition)
	for &sel in context_selections(ctx).selections {
		sel.anchor = sel.cursor.coord
	}
}

// normal_cmd_flip_selections implements A-; (port of flip_selections).
normal_cmd_flip_selections :: proc(ctx: ^Context, params: Normal_Params) {
	_ = params
	edition := context_scoped_selection_edition_make(ctx)
	defer context_scoped_selection_edition_destroy(&edition)
	for &sel in context_selections(ctx).selections {
		tmp := sel.anchor
		sel.anchor = sel.cursor.coord
		sel.cursor = coord_buffer_and_target(tmp)
	}
}

// normal_cmd_ensure_forward implements A-: (port of ensure_forward).
normal_cmd_ensure_forward :: proc(ctx: ^Context, params: Normal_Params) {
	_ = params
	edition := context_scoped_selection_edition_make(ctx)
	defer context_scoped_selection_edition_destroy(&edition)
	for &sel in context_selections(ctx).selections {
		sel.anchor = input_handler_sel_min(&sel)
		sel.cursor = coord_buffer_and_target(input_handler_sel_max(&sel))
	}
}

// normal_cmd_merge_consecutive implements A-_ (port of
// merge_consecutive).
normal_cmd_merge_consecutive :: proc(ctx: ^Context, params: Normal_Params) {
	edition := context_scoped_selection_edition_make(ctx)
	defer context_scoped_selection_edition_destroy(&edition)
	normal_cmd_ensure_forward(ctx, params)
	selection_list_merge_consecutive(context_selections(ctx))
}

// normal_cmd_merge_overlapping implements A-+ (port of
// merge_overlapping).
normal_cmd_merge_overlapping :: proc(ctx: ^Context, params: Normal_Params) {
	edition := context_scoped_selection_edition_make(ctx)
	defer context_scoped_selection_edition_destroy(&edition)
	normal_cmd_ensure_forward(ctx, params)
	selection_list_merge_overlapping(context_selections(ctx))
}

// normal_cmd_duplicate_selections implements + (port of
// duplicate_selections).
normal_cmd_duplicate_selections :: proc(ctx: ^Context, params: Normal_Params) {
	edition := context_scoped_selection_edition_make(ctx)
	defer context_scoped_selection_edition_destroy(&edition)
	sels := context_selections(ctx)
	count := params.count if params.count != 0 else 2
	res := make([dynamic]Selection, 0, context.temp_allocator)
	defer delete(res)
	last_anchor := Coord_Buffer{-1, -1}
	last_cursor := Coord_Buffer{-1, -1}
	main_index := 0
	for sel, index in sels.selections {
		n := 1 if sel.anchor == last_anchor && sel.cursor.coord == last_cursor else count
		for _ in 0 ..< n {
			append(&res, sel)
		}
		last_anchor = sel.anchor
		last_cursor = sel.cursor.coord
		if index == sels.main {
			main_index = len(res) - 1
		}
	}
	normal_selection_list_set_cloned(sels, res[:], main_index)
}

// normal_cmd_force_redraw implements C-l (port of force_redraw).
normal_cmd_force_redraw :: proc(ctx: ^Context, params: Normal_Params) {
	_ = params
	if context_has_client(ctx) {
		client_force_redraw(context_client(ctx), true)
		client_redraw_ifn(context_client(ctx))
	}
}

// normal_select_repeated runs select max(count, 1) times (port of
// Repeated<select<mode, func>>).
normal_select_repeated :: proc(ctx: ^Context, params: Normal_Params, mode: normal_Select_Mode, func: normal_Select_Func) {
	edition := context_scoped_edition_make(ctx)
	defer context_scoped_edition_destroy(&edition)
	sel_edition := context_scoped_selection_edition_make(ctx)
	defer context_scoped_selection_edition_destroy(&sel_edition)
	count := params.count
	for {
		if err := normal_select(ctx, mode, func); err != .None {
			normal_fail(ctx, normal_error_message(err))
			return
		}
		count -= 1
		if count <= 0 {
			break
		}
	}
}

// Select adapters: normal_Select_Func shims over the selectors
// module (ports of the select<mode, func> instantiations).

normal_sel_lines :: proc(data: rawptr, ctx: ^Context, sel: Selection) -> (Selection, bool) {
	_ = data
	return selectors_select_lines(ctx, sel)
}

normal_sel_trim_partial_lines :: proc(data: rawptr, ctx: ^Context, sel: Selection) -> (Selection, bool) {
	_ = data
	return selectors_trim_partial_lines(ctx, sel)
}

normal_sel_matching_forward :: proc(data: rawptr, ctx: ^Context, sel: Selection) -> (Selection, bool) {
	_ = data
	return selectors_select_matching(ctx, sel, true)
}

normal_sel_matching_backward :: proc(data: rawptr, ctx: ^Context, sel: Selection) -> (Selection, bool) {
	_ = data
	return selectors_select_matching(ctx, sel, false)
}

normal_sel_word_next :: proc(data: rawptr, ctx: ^Context, sel: Selection) -> (Selection, bool) {
	_ = data
	return selectors_select_to_next_word(ctx, sel, .Word)
}

normal_sel_word_end :: proc(data: rawptr, ctx: ^Context, sel: Selection) -> (Selection, bool) {
	_ = data
	return selectors_select_to_next_word_end(ctx, sel, .Word)
}

normal_sel_word_prev :: proc(data: rawptr, ctx: ^Context, sel: Selection) -> (Selection, bool) {
	_ = data
	return selectors_select_to_previous_word(ctx, sel, .Word)
}

normal_sel_big_word_next :: proc(data: rawptr, ctx: ^Context, sel: Selection) -> (Selection, bool) {
	_ = data
	return selectors_select_to_next_word(ctx, sel, .Big_Word)
}

normal_sel_big_word_end :: proc(data: rawptr, ctx: ^Context, sel: Selection) -> (Selection, bool) {
	_ = data
	return selectors_select_to_next_word_end(ctx, sel, .Big_Word)
}

normal_sel_big_word_prev :: proc(data: rawptr, ctx: ^Context, sel: Selection) -> (Selection, bool) {
	_ = data
	return selectors_select_to_previous_word(ctx, sel, .Big_Word)
}

normal_sel_to_line_end :: proc(data: rawptr, ctx: ^Context, sel: Selection) -> (Selection, bool) {
	_ = data
	return selectors_select_to_line_end(ctx, sel, false)
}

normal_sel_to_line_begin :: proc(data: rawptr, ctx: ^Context, sel: Selection) -> (Selection, bool) {
	_ = data
	return selectors_select_to_line_begin(ctx, sel, false)
}

normal_sel_goto_line_end :: proc(data: rawptr, ctx: ^Context, sel: Selection) -> (Selection, bool) {
	_ = data
	return selectors_select_to_line_end(ctx, sel, true)
}

normal_sel_goto_line_begin :: proc(data: rawptr, ctx: ^Context, sel: Selection) -> (Selection, bool) {
	_ = data
	return selectors_select_to_line_begin(ctx, sel, true)
}

normal_sel_first_non_blank :: proc(data: rawptr, ctx: ^Context, sel: Selection) -> (Selection, bool) {
	_ = data
	return selectors_select_to_first_non_blank(ctx, sel)
}

// Keymap command wrappers: one Normal_Cmd.func per keymap entry
// (ports of the keymap lambdas and template instantiations).

normal_key_move_left :: proc(ctx: ^Context, params: Normal_Params) {
	normal_move_cursor(ctx, params, .Backward, .Replace, false)
}

normal_key_move_down :: proc(ctx: ^Context, params: Normal_Params) {
	normal_move_cursor(ctx, params, .Forward, .Replace, true)
}

normal_key_move_up :: proc(ctx: ^Context, params: Normal_Params) {
	normal_move_cursor(ctx, params, .Backward, .Replace, true)
}

normal_key_move_right :: proc(ctx: ^Context, params: Normal_Params) {
	normal_move_cursor(ctx, params, .Forward, .Replace, false)
}

normal_key_extend_left :: proc(ctx: ^Context, params: Normal_Params) {
	normal_move_cursor(ctx, params, .Backward, .Extend, false)
}

normal_key_extend_down :: proc(ctx: ^Context, params: Normal_Params) {
	normal_move_cursor(ctx, params, .Forward, .Extend, true)
}

normal_key_extend_up :: proc(ctx: ^Context, params: Normal_Params) {
	normal_move_cursor(ctx, params, .Backward, .Extend, true)
}

normal_key_extend_right :: proc(ctx: ^Context, params: Normal_Params) {
	normal_move_cursor(ctx, params, .Forward, .Extend, false)
}

normal_key_to_char :: proc(ctx: ^Context, params: Normal_Params) {
	normal_select_to_next_char(ctx, params, normal_Select_Flags{})
}

normal_key_to_char_inclusive :: proc(ctx: ^Context, params: Normal_Params) {
	normal_select_to_next_char(ctx, params, {.Inclusive})
}

normal_key_extend_to_char :: proc(ctx: ^Context, params: Normal_Params) {
	normal_select_to_next_char(ctx, params, {.Extend})
}

normal_key_extend_to_char_inclusive :: proc(ctx: ^Context, params: Normal_Params) {
	normal_select_to_next_char(ctx, params, {.Inclusive, .Extend})
}

normal_key_to_char_prev :: proc(ctx: ^Context, params: Normal_Params) {
	normal_select_to_next_char(ctx, params, {.Reverse})
}

normal_key_to_char_prev_inclusive :: proc(ctx: ^Context, params: Normal_Params) {
	normal_select_to_next_char(ctx, params, {.Inclusive, .Reverse})
}

normal_key_extend_to_char_prev :: proc(ctx: ^Context, params: Normal_Params) {
	normal_select_to_next_char(ctx, params, {.Extend, .Reverse})
}

normal_key_extend_to_char_prev_inclusive :: proc(ctx: ^Context, params: Normal_Params) {
	normal_select_to_next_char(ctx, params, {.Inclusive, .Extend, .Reverse})
}

normal_key_erase :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_erase(ctx, params, true)
}

normal_key_erase_no_yank :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_erase(ctx, params, false)
}

normal_key_change :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_change(ctx, params, true)
}

normal_key_change_no_yank :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_change(ctx, params, false)
}

normal_key_insert :: proc(ctx: ^Context, params: Normal_Params) {
	normal_enter_insert_mode(ctx, params, .Insert)
}

normal_key_insert_at_line_begin :: proc(ctx: ^Context, params: Normal_Params) {
	normal_enter_insert_mode(ctx, params, .Insert_At_Line_Begin)
}

normal_key_append :: proc(ctx: ^Context, params: Normal_Params) {
	normal_enter_insert_mode(ctx, params, .Append)
}

normal_key_append_at_line_end :: proc(ctx: ^Context, params: Normal_Params) {
	normal_enter_insert_mode(ctx, params, .Append_At_Line_End)
}

normal_key_open_below :: proc(ctx: ^Context, params: Normal_Params) {
	normal_enter_insert_mode(ctx, params, .Open_Line_Below)
}

normal_key_open_above :: proc(ctx: ^Context, params: Normal_Params) {
	normal_enter_insert_mode(ctx, params, .Open_Line_Above)
}

normal_key_replace_char :: proc(ctx: ^Context, params: Normal_Params) {
	normal_replace_with_char(ctx, params)
}

normal_key_add_empty_line_below :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_add_empty_line(ctx, params, false)
}

normal_key_add_empty_line_above :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_add_empty_line(ctx, params, true)
}

normal_key_goto :: proc(ctx: ^Context, params: Normal_Params) {
	normal_goto_commands(ctx, params, .Replace)
}

normal_key_goto_extend :: proc(ctx: ^Context, params: Normal_Params) {
	normal_goto_commands(ctx, params, .Extend)
}

normal_key_view :: proc(ctx: ^Context, params: Normal_Params) {
	normal_view_commands(ctx, params, false)
}

normal_key_view_lock :: proc(ctx: ^Context, params: Normal_Params) {
	normal_view_commands(ctx, params, true)
}

normal_key_yank :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_yank(ctx, params)
}

normal_key_paste_after :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_paste_repeated(ctx, params, .Append)
}

normal_key_paste_before :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_paste_repeated(ctx, params, .Insert)
}

normal_key_paste_all_after :: proc(ctx: ^Context, params: Normal_Params) {
	normal_paste_all(ctx, params, .Append)
}

normal_key_paste_all_before :: proc(ctx: ^Context, params: Normal_Params) {
	normal_paste_all(ctx, params, .Insert)
}

normal_key_paste_replace :: proc(ctx: ^Context, params: Normal_Params) {
	normal_paste(ctx, params, .Replace)
}

normal_key_paste_all_replace :: proc(ctx: ^Context, params: Normal_Params) {
	normal_paste_all(ctx, params, .Replace)
}

normal_key_select_regex :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_select_regex(ctx, params)
}

normal_key_split_regex :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_split_regex(ctx, params)
}

normal_key_split_lines :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_split_lines(ctx, params)
}

normal_key_select_boundaries :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_select_boundaries(ctx, params)
}

normal_key_repeat_insert :: proc(ctx: ^Context, params: Normal_Params) {
	normal_repeat_last_insert_cmd(ctx, params)
}

normal_key_repeat_select :: proc(ctx: ^Context, params: Normal_Params) {
	normal_repeat_last_select_cmd(ctx, params)
}

normal_key_whole_buffer :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_select_whole_buffer(ctx, params)
}

normal_key_command :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_command(ctx, params)
}

normal_key_pipe :: proc(ctx: ^Context, params: Normal_Params) {
	normal_pipe_prompt(ctx, params, true)
}

normal_key_pipe_to :: proc(ctx: ^Context, params: Normal_Params) {
	normal_pipe_prompt(ctx, params, false)
}

normal_key_insert_output :: proc(ctx: ^Context, params: Normal_Params) {
	normal_insert_output(ctx, params, .Insert)
}

normal_key_append_output :: proc(ctx: ^Context, params: Normal_Params) {
	normal_insert_output(ctx, params, .Append)
}

normal_key_keep_selection :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_keep_selection(ctx, params)
}

normal_key_remove_selection :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_remove_selection(ctx, params)
}

normal_key_clear_selections :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_clear_selections(ctx, params)
}

normal_key_flip_selections :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_flip_selections(ctx, params)
}

normal_key_ensure_forward :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_ensure_forward(ctx, params)
}

normal_key_merge_consecutive :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_merge_consecutive(ctx, params)
}

normal_key_duplicate_selections :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_duplicate_selections(ctx, params)
}

normal_key_merge_overlapping :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_merge_overlapping(ctx, params)
}

normal_key_word_next :: proc(ctx: ^Context, params: Normal_Params) {
	normal_select_repeated(ctx, params, .Replace, normal_sel_word_next)
}

normal_key_word_end :: proc(ctx: ^Context, params: Normal_Params) {
	normal_select_repeated(ctx, params, .Replace, normal_sel_word_end)
}

normal_key_word_prev :: proc(ctx: ^Context, params: Normal_Params) {
	normal_select_repeated(ctx, params, .Replace, normal_sel_word_prev)
}

normal_key_word_next_extend :: proc(ctx: ^Context, params: Normal_Params) {
	normal_select_repeated(ctx, params, .Extend, normal_sel_word_next)
}

normal_key_word_end_extend :: proc(ctx: ^Context, params: Normal_Params) {
	normal_select_repeated(ctx, params, .Extend, normal_sel_word_end)
}

normal_key_word_prev_extend :: proc(ctx: ^Context, params: Normal_Params) {
	normal_select_repeated(ctx, params, .Extend, normal_sel_word_prev)
}

normal_key_big_word_next :: proc(ctx: ^Context, params: Normal_Params) {
	normal_select_repeated(ctx, params, .Replace, normal_sel_big_word_next)
}

normal_key_big_word_end :: proc(ctx: ^Context, params: Normal_Params) {
	normal_select_repeated(ctx, params, .Replace, normal_sel_big_word_end)
}

normal_key_big_word_prev :: proc(ctx: ^Context, params: Normal_Params) {
	normal_select_repeated(ctx, params, .Replace, normal_sel_big_word_prev)
}

normal_key_big_word_next_extend :: proc(ctx: ^Context, params: Normal_Params) {
	normal_select_repeated(ctx, params, .Extend, normal_sel_big_word_next)
}

normal_key_big_word_end_extend :: proc(ctx: ^Context, params: Normal_Params) {
	normal_select_repeated(ctx, params, .Extend, normal_sel_big_word_end)
}

normal_key_big_word_prev_extend :: proc(ctx: ^Context, params: Normal_Params) {
	normal_select_repeated(ctx, params, .Extend, normal_sel_big_word_prev)
}

normal_key_line_end :: proc(ctx: ^Context, params: Normal_Params) {
	normal_select_repeated(ctx, params, .Replace, normal_sel_to_line_end)
}

normal_key_line_end_extend :: proc(ctx: ^Context, params: Normal_Params) {
	normal_select_repeated(ctx, params, .Extend, normal_sel_to_line_end)
}

normal_key_line_begin :: proc(ctx: ^Context, params: Normal_Params) {
	normal_select_repeated(ctx, params, .Replace, normal_sel_to_line_begin)
}

normal_key_line_begin_extend :: proc(ctx: ^Context, params: Normal_Params) {
	normal_select_repeated(ctx, params, .Extend, normal_sel_to_line_begin)
}

normal_key_lines :: proc(ctx: ^Context, params: Normal_Params) {
	_ = params
	if err := normal_select(ctx, .Replace, normal_sel_lines); err != .None {
		normal_fail(ctx, normal_error_message(err))
	}
}

normal_key_trim_partial_lines :: proc(ctx: ^Context, params: Normal_Params) {
	_ = params
	if err := normal_select(ctx, .Replace, normal_sel_trim_partial_lines); err != .None {
		normal_fail(ctx, normal_error_message(err))
	}
}

normal_key_matching :: proc(ctx: ^Context, params: Normal_Params) {
	_ = params
	if err := normal_select(ctx, .Replace, normal_sel_matching_forward); err != .None {
		normal_fail(ctx, normal_error_message(err))
	}
}

normal_key_matching_backward :: proc(ctx: ^Context, params: Normal_Params) {
	_ = params
	if err := normal_select(ctx, .Replace, normal_sel_matching_backward); err != .None {
		normal_fail(ctx, normal_error_message(err))
	}
}

normal_key_matching_extend :: proc(ctx: ^Context, params: Normal_Params) {
	_ = params
	if err := normal_select(ctx, .Extend, normal_sel_matching_forward); err != .None {
		normal_fail(ctx, normal_error_message(err))
	}
}

normal_key_matching_backward_extend :: proc(ctx: ^Context, params: Normal_Params) {
	_ = params
	if err := normal_select(ctx, .Extend, normal_sel_matching_backward); err != .None {
		normal_fail(ctx, normal_error_message(err))
	}
}

normal_key_search_forward :: proc(ctx: ^Context, params: Normal_Params) {
	normal_search(ctx, params, .Replace, true)
}

normal_key_search_forward_extend :: proc(ctx: ^Context, params: Normal_Params) {
	normal_search(ctx, params, .Extend, true)
}

normal_key_search_backward :: proc(ctx: ^Context, params: Normal_Params) {
	normal_search(ctx, params, .Replace, false)
}

normal_key_search_backward_extend :: proc(ctx: ^Context, params: Normal_Params) {
	normal_search(ctx, params, .Extend, false)
}

normal_key_search_next :: proc(ctx: ^Context, params: Normal_Params) {
	normal_search_next(ctx, params, .Replace, true)
}

normal_key_search_next_append :: proc(ctx: ^Context, params: Normal_Params) {
	normal_search_next(ctx, params, .Append, true)
}

normal_key_search_prev :: proc(ctx: ^Context, params: Normal_Params) {
	normal_search_next(ctx, params, .Replace, false)
}

normal_key_search_prev_append :: proc(ctx: ^Context, params: Normal_Params) {
	normal_search_next(ctx, params, .Append, false)
}

normal_key_use_selection_smart :: proc(ctx: ^Context, params: Normal_Params) {
	normal_use_selection_as_search_pattern(ctx, params, true)
}

normal_key_use_selection :: proc(ctx: ^Context, params: Normal_Params) {
	normal_use_selection_as_search_pattern(ctx, params, false)
}

normal_key_undo :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_undo(ctx, params)
}

normal_key_redo :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_redo(ctx, params)
}

normal_key_history_backward :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_move_in_history(ctx, params, .Backward)
}

normal_key_history_forward :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_move_in_history(ctx, params, .Forward)
}

normal_key_undo_selection :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_undo_selection_change(ctx, params, .Backward)
}

normal_key_redo_selection :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_undo_selection_change(ctx, params, .Forward)
}

normal_key_select_inner_object :: proc(ctx: ^Context, params: Normal_Params) {
	normal_select_object(ctx, params, {.To_Begin, .To_End, .Inner})
}

normal_key_select_whole_object :: proc(ctx: ^Context, params: Normal_Params) {
	normal_select_object(ctx, params, {.To_Begin, .To_End})
}

normal_key_select_to_object_begin :: proc(ctx: ^Context, params: Normal_Params) {
	normal_select_object(ctx, params, {.To_Begin})
}

normal_key_select_to_object_end :: proc(ctx: ^Context, params: Normal_Params) {
	normal_select_object(ctx, params, {.To_End})
}

normal_key_extend_to_object_begin :: proc(ctx: ^Context, params: Normal_Params) {
	normal_select_object(ctx, params, {.To_Begin}, .Extend)
}

normal_key_extend_to_object_end :: proc(ctx: ^Context, params: Normal_Params) {
	normal_select_object(ctx, params, {.To_End}, .Extend)
}

normal_key_select_to_inner_begin :: proc(ctx: ^Context, params: Normal_Params) {
	normal_select_object(ctx, params, {.To_Begin, .Inner})
}

normal_key_select_to_inner_end :: proc(ctx: ^Context, params: Normal_Params) {
	normal_select_object(ctx, params, {.To_End, .Inner})
}

normal_key_extend_to_inner_begin :: proc(ctx: ^Context, params: Normal_Params) {
	normal_select_object(ctx, params, {.To_Begin, .Inner}, .Extend)
}

normal_key_extend_to_inner_end :: proc(ctx: ^Context, params: Normal_Params) {
	normal_select_object(ctx, params, {.To_End, .Inner}, .Extend)
}

normal_key_select_nested_inner :: proc(ctx: ^Context, params: Normal_Params) {
	normal_select_object(ctx, params, {.Nested, .Inner, .To_Begin, .To_End})
}

normal_key_select_nested :: proc(ctx: ^Context, params: Normal_Params) {
	normal_select_object(ctx, params, {.Nested, .To_Begin, .To_End})
}

normal_key_join_lines :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_join_lines(ctx, params)
}

normal_key_join_lines_select_spaces :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_join_lines_select_spaces(ctx, params)
}

normal_key_keep_matching :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_keep(ctx, params, true)
}

normal_key_keep_not_matching :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_keep(ctx, params, false)
}

normal_key_keep_pipe :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_keep_pipe(ctx, params)
}

normal_key_deindent :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_deindent(ctx, params, true)
}

normal_key_indent :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_indent(ctx, params, false)
}

normal_key_indent_empty :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_indent(ctx, params, true)
}

normal_key_deindent_complete :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_deindent(ctx, params, false)
}

normal_key_jump_forward :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_jump(ctx, params, .Forward)
}

normal_key_jump_backward :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_jump(ctx, params, .Backward)
}

normal_key_push_selections :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_push_selections(ctx, params)
}

normal_key_rotate_forward :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_rotate_selections(ctx, params, .Forward)
}

normal_key_rotate_backward :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_rotate_selections(ctx, params, .Backward)
}

normal_key_rotate_content_forward :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_rotate_selections_content(ctx, params, .Forward)
}

normal_key_rotate_content_backward :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_rotate_selections_content(ctx, params, .Backward)
}

normal_key_replay_macro :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_replay_macro(ctx, params)
}

normal_key_record_macro :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_start_or_end_macro_recording(ctx, params)
}

normal_key_to_lower :: proc(ctx: ^Context, params: Normal_Params) {
	_ = params
	normal_for_each_codepoint(ctx, unicode_to_lower)
}

normal_key_to_upper :: proc(ctx: ^Context, params: Normal_Params) {
	_ = params
	normal_for_each_codepoint(ctx, unicode_to_upper)
}

normal_key_swap_case :: proc(ctx: ^Context, params: Normal_Params) {
	_ = params
	normal_for_each_codepoint(ctx, normal_swap_case)
}

normal_key_align :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_align(ctx, params)
}

normal_key_copy_indent :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_copy_indent(ctx, params)
}

normal_key_tabs_to_spaces :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_tabs_to_spaces(ctx, params)
}

normal_key_spaces_to_tabs :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_spaces_to_tabs(ctx, params)
}

normal_key_trim_selections :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_trim_selections(ctx, params)
}

normal_key_copy_selections_below :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_copy_selections_on_next_lines(ctx, params, .Forward)
}

normal_key_copy_selections_above :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_copy_selections_on_next_lines(ctx, params, .Backward)
}

normal_key_user_mappings :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_exec_user_mappings(ctx, params)
}

normal_key_scroll_page_up :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_scroll(ctx, params, .Backward, false)
}

normal_key_scroll_page_down :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_scroll(ctx, params, .Forward, false)
}

normal_key_scroll_half_up :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_scroll(ctx, params, .Backward, true)
}

normal_key_scroll_half_down :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_scroll(ctx, params, .Forward, true)
}

normal_key_restore_selections :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_restore_selections(ctx, params, false)
}

normal_key_combine_selections_from :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_restore_selections(ctx, params, true)
}

normal_key_save_selections :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_save_selections(ctx, params, false)
}

normal_key_combine_selections_to :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_save_selections(ctx, params, true)
}

normal_key_force_redraw :: proc(ctx: ^Context, params: Normal_Params) {
	normal_cmd_force_redraw(ctx, params)
}

// normal_Keymap_Entry pairs a key with its NormalCmd (port of the
// keymap HashMap entries).
normal_Keymap_Entry :: struct {
	key: Keys_Key,
	cmd: Normal_Cmd,
}

// normal_keymap_entries is the normal-mode keymap (port of keymap).
normal_keymap_entries := [?]normal_Keymap_Entry{
	{{keys_MOD_NONE, 'h'}, {"move left", normal_key_move_left}},
	{{keys_MOD_NONE, 'j'}, {"move down", normal_key_move_down}},
	{{keys_MOD_NONE, 'k'}, {"move up", normal_key_move_up}},
	{{keys_MOD_NONE, 'l'}, {"move right", normal_key_move_right}},
	{{keys_MOD_NONE, 'H'}, {"extend left", normal_key_extend_left}},
	{{keys_MOD_NONE, 'J'}, {"extend down", normal_key_extend_down}},
	{{keys_MOD_NONE, 'K'}, {"extend up", normal_key_extend_up}},
	{{keys_MOD_NONE, 'L'}, {"extend right", normal_key_extend_right}},
	{{keys_MOD_NONE, 't'}, {"select to next character", normal_key_to_char}},
	{{keys_MOD_NONE, 'f'}, {"select to next character included", normal_key_to_char_inclusive}},
	{{keys_MOD_NONE, 'T'}, {"extend to next character", normal_key_extend_to_char}},
	{{keys_MOD_NONE, 'F'}, {"extend to next character included", normal_key_extend_to_char_inclusive}},
	{{keys_MOD_ALT, 't'}, {"select to previous character", normal_key_to_char_prev}},
	{{keys_MOD_ALT, 'f'}, {"select to previous character included", normal_key_to_char_prev_inclusive}},
	{{keys_MOD_ALT, 'T'}, {"extend to previous character", normal_key_extend_to_char_prev}},
	{{keys_MOD_ALT, 'F'}, {"extend to previous character included", normal_key_extend_to_char_prev_inclusive}},
	{{keys_MOD_NONE, 'd'}, {"erase selected text", normal_key_erase}},
	{{keys_MOD_ALT, 'd'}, {"erase selected text, without yanking", normal_key_erase_no_yank}},
	{{keys_MOD_NONE, 'c'}, {"change selected text", normal_key_change}},
	{{keys_MOD_ALT, 'c'}, {"change selected text, without yanking", normal_key_change_no_yank}},
	{{keys_MOD_NONE, 'i'}, {"insert before selected text", normal_key_insert}},
	{{keys_MOD_NONE, 'I'}, {"insert at line begin", normal_key_insert_at_line_begin}},
	{{keys_MOD_NONE, 'a'}, {"insert after selected text", normal_key_append}},
	{{keys_MOD_NONE, 'A'}, {"insert at line end", normal_key_append_at_line_end}},
	{{keys_MOD_NONE, 'o'}, {"insert on new line below", normal_key_open_below}},
	{{keys_MOD_NONE, 'O'}, {"insert on new line above", normal_key_open_above}},
	{{keys_MOD_NONE, 'r'}, {"replace with character", normal_key_replace_char}},
	{{keys_MOD_ALT, 'o'}, {"add a new empty line below", normal_key_add_empty_line_below}},
	{{keys_MOD_ALT, 'O'}, {"add a new empty line above", normal_key_add_empty_line_above}},
	{{keys_MOD_NONE, 'g'}, {"go to location", normal_key_goto}},
	{{keys_MOD_NONE, 'G'}, {"extend to location", normal_key_goto_extend}},
	{{keys_MOD_NONE, 'v'}, {"move view", normal_key_view}},
	{{keys_MOD_NONE, 'V'}, {"move view (locked)", normal_key_view_lock}},
	{{keys_MOD_NONE, 'y'}, {"yank selected text", normal_key_yank}},
	{{keys_MOD_NONE, 'p'}, {"paste after selected text", normal_key_paste_after}},
	{{keys_MOD_NONE, 'P'}, {"paste before selected text", normal_key_paste_before}},
	{{keys_MOD_ALT, 'p'}, {"paste every yanked selection after selected text", normal_key_paste_all_after}},
	{{keys_MOD_ALT, 'P'}, {"paste every yanked selection before selected text", normal_key_paste_all_before}},
	{{keys_MOD_NONE, 'R'}, {"replace selected text with yanked text", normal_key_paste_replace}},
	{{keys_MOD_ALT, 'R'}, {"replace selected text with every yanked text", normal_key_paste_all_replace}},
	{{keys_MOD_NONE, 's'}, {"select regex matches in selected text", normal_key_select_regex}},
	{{keys_MOD_NONE, 'S'}, {"split selected text on regex matches", normal_key_split_regex}},
	{{keys_MOD_ALT, 's'}, {"split selected text on line ends", normal_key_split_lines}},
	{{keys_MOD_ALT, 'S'}, {"select selection boundaries", normal_key_select_boundaries}},
	{{keys_MOD_NONE, '.'}, {"repeat last insert command", normal_key_repeat_insert}},
	{{keys_MOD_ALT, '.'}, {"repeat last object select/character find", normal_key_repeat_select}},
	{{keys_MOD_NONE, '%'}, {"select whole buffer", normal_key_whole_buffer}},
	{{keys_MOD_NONE, ':'}, {"enter command prompt", normal_key_command}},
	{{keys_MOD_NONE, '|'}, {"pipe each selection through filter and replace with output", normal_key_pipe}},
	{{keys_MOD_ALT, '|'}, {"pipe each selection through command and ignore output", normal_key_pipe_to}},
	{{keys_MOD_NONE, '!'}, {"insert command output", normal_key_insert_output}},
	{{keys_MOD_ALT, '!'}, {"append command output", normal_key_append_output}},
	{{keys_MOD_NONE, ','}, {"remove all selections except main", normal_key_keep_selection}},
	{{keys_MOD_ALT, ','}, {"remove main selection", normal_key_remove_selection}},
	{{keys_MOD_NONE, ';'}, {"reduce selections to their cursor", normal_key_clear_selections}},
	{{keys_MOD_ALT, ';'}, {"swap selections cursor and anchor", normal_key_flip_selections}},
	{{keys_MOD_ALT, ':'}, {"ensure selection cursor is after anchor", normal_key_ensure_forward}},
	{{keys_MOD_ALT, '_'}, {"merge consecutive selections", normal_key_merge_consecutive}},
	{{keys_MOD_NONE, '+'}, {"duplicate each selection", normal_key_duplicate_selections}},
	{{keys_MOD_ALT, '+'}, {"merge overlapping selections", normal_key_merge_overlapping}},
	{{keys_MOD_NONE, 'w'}, {"select to next word start", normal_key_word_next}},
	{{keys_MOD_NONE, 'e'}, {"select to next word end", normal_key_word_end}},
	{{keys_MOD_NONE, 'b'}, {"select to previous word start", normal_key_word_prev}},
	{{keys_MOD_NONE, 'W'}, {"extend to next word start", normal_key_word_next_extend}},
	{{keys_MOD_NONE, 'E'}, {"extend to next word end", normal_key_word_end_extend}},
	{{keys_MOD_NONE, 'B'}, {"extend to previous word start", normal_key_word_prev_extend}},
	{{keys_MOD_ALT, 'w'}, {"select to next WORD start", normal_key_big_word_next}},
	{{keys_MOD_ALT, 'e'}, {"select to next WORD end", normal_key_big_word_end}},
	{{keys_MOD_ALT, 'b'}, {"select to previous WORD start", normal_key_big_word_prev}},
	{{keys_MOD_ALT, 'W'}, {"extend to next WORD start", normal_key_big_word_next_extend}},
	{{keys_MOD_ALT, 'E'}, {"extend to next WORD end", normal_key_big_word_end_extend}},
	{{keys_MOD_ALT, 'B'}, {"extend to previous WORD start", normal_key_big_word_prev_extend}},
	{{keys_MOD_ALT, 'l'}, {"select to line end", normal_key_line_end}},
	{{keys_MOD_ALT, 'L'}, {"extend to line end", normal_key_line_end_extend}},
	{{keys_MOD_ALT, 'h'}, {"select to line begin", normal_key_line_begin}},
	{{keys_MOD_ALT, 'H'}, {"extend to line begin", normal_key_line_begin_extend}},
	{{keys_MOD_NONE, 'x'}, {"extend selections to whole lines", normal_key_lines}},
	{{keys_MOD_ALT, 'x'}, {"crop selections to whole lines", normal_key_trim_partial_lines}},
	{{keys_MOD_NONE, 'm'}, {"select to matching character", normal_key_matching}},
	{{keys_MOD_ALT, 'm'}, {"backward select to matching character", normal_key_matching_backward}},
	{{keys_MOD_NONE, 'M'}, {"extend to matching character", normal_key_matching_extend}},
	{{keys_MOD_ALT, 'M'}, {"backward extend to matching character", normal_key_matching_backward_extend}},
	{{keys_MOD_NONE, '/'}, {"select next given regex match", normal_key_search_forward}},
	{{keys_MOD_NONE, '?'}, {"extend with next given regex match", normal_key_search_forward_extend}},
	{{keys_MOD_ALT, '/'}, {"select previous given regex match", normal_key_search_backward}},
	{{keys_MOD_ALT, '?'}, {"extend with previous given regex match", normal_key_search_backward_extend}},
	{{keys_MOD_NONE, 'n'}, {"select next current search pattern match", normal_key_search_next}},
	{{keys_MOD_NONE, 'N'}, {"extend with next current search pattern match", normal_key_search_next_append}},
	{{keys_MOD_ALT, 'n'}, {"select previous current search pattern match", normal_key_search_prev}},
	{{keys_MOD_ALT, 'N'}, {"extend with previous current search pattern match", normal_key_search_prev_append}},
	{{keys_MOD_NONE, '*'}, {"set search pattern to main selection content", normal_key_use_selection_smart}},
	{{keys_MOD_ALT, '*'}, {"set search pattern to main selection content, do not detect words", normal_key_use_selection}},
	{{keys_MOD_NONE, 'u'}, {"undo", normal_key_undo}},
	{{keys_MOD_NONE, 'U'}, {"redo", normal_key_redo}},
	{{keys_MOD_CONTROL, 'k'}, {"move backward in history", normal_key_history_backward}},
	{{keys_MOD_CONTROL, 'j'}, {"move forward in history", normal_key_history_forward}},
	{{keys_MOD_ALT, 'u'}, {"undo selection change", normal_key_undo_selection}},
	{{keys_MOD_ALT, 'U'}, {"redo selection change", normal_key_redo_selection}},
	{{keys_MOD_ALT, 'i'}, {"select inner object", normal_key_select_inner_object}},
	{{keys_MOD_ALT, 'a'}, {"select whole object", normal_key_select_whole_object}},
	{{keys_MOD_NONE, '['}, {"select to object start", normal_key_select_to_object_begin}},
	{{keys_MOD_NONE, ']'}, {"select to object end", normal_key_select_to_object_end}},
	{{keys_MOD_NONE, '{'}, {"extend to object start", normal_key_extend_to_object_begin}},
	{{keys_MOD_NONE, '}'}, {"extend to object end", normal_key_extend_to_object_end}},
	{{keys_MOD_ALT, '['}, {"select to inner object start", normal_key_select_to_inner_begin}},
	{{keys_MOD_ALT, ']'}, {"select to inner object end", normal_key_select_to_inner_end}},
	{{keys_MOD_ALT, '{'}, {"extend to inner object start", normal_key_extend_to_inner_begin}},
	{{keys_MOD_ALT, '}'}, {"extend to inner object end", normal_key_extend_to_inner_end}},
	{{keys_MOD_ALT, 'I'}, {"select nested objects", normal_key_select_nested_inner}},
	{{keys_MOD_ALT, 'A'}, {"select nested objects", normal_key_select_nested}},
	{{keys_MOD_ALT, 'j'}, {"join lines", normal_key_join_lines}},
	{{keys_MOD_ALT, 'J'}, {"join lines and select spaces", normal_key_join_lines_select_spaces}},
	{{keys_MOD_ALT, 'k'}, {"keep selections matching given regex", normal_key_keep_matching}},
	{{keys_MOD_ALT, 'K'}, {"keep selections not matching given regex", normal_key_keep_not_matching}},
	{{keys_MOD_NONE, '$'}, {"pipe each selection through shell command and keep the ones whose command succeed", normal_key_keep_pipe}},
	{{keys_MOD_NONE, '<'}, {"deindent", normal_key_deindent}},
	{{keys_MOD_NONE, '>'}, {"indent", normal_key_indent}},
	{{keys_MOD_ALT, '>'}, {"indent, including empty lines", normal_key_indent_empty}},
	{{keys_MOD_ALT, '<'}, {"deindent, not including incomplete indent", normal_key_deindent_complete}},
	{{keys_MOD_CONTROL, 'i'}, {"jump forward in jump list", normal_key_jump_forward}},
	{{keys_MOD_CONTROL, 'o'}, {"jump backward in jump list", normal_key_jump_backward}},
	{{keys_MOD_CONTROL, 's'}, {"push current selections in jump list", normal_key_push_selections}},
	{{keys_MOD_NONE, ')'}, {"rotate main selection forward", normal_key_rotate_forward}},
	{{keys_MOD_NONE, '('}, {"rotate main selection backward", normal_key_rotate_backward}},
	{{keys_MOD_ALT, ')'}, {"rotate selections content forward", normal_key_rotate_content_forward}},
	{{keys_MOD_ALT, '('}, {"rotate selections content backward", normal_key_rotate_content_backward}},
	{{keys_MOD_NONE, 'q'}, {"replay recorded macro", normal_key_replay_macro}},
	{{keys_MOD_NONE, 'Q'}, {"start or end macro recording", normal_key_record_macro}},
	{{keys_MOD_NONE, '`'}, {"convert to lower case in selections", normal_key_to_lower}},
	{{keys_MOD_NONE, '~'}, {"convert to upper case in selections", normal_key_to_upper}},
	{{keys_MOD_ALT, '`'}, {"swap case in selections", normal_key_swap_case}},
	{{keys_MOD_NONE, '&'}, {"align selection cursors", normal_key_align}},
	{{keys_MOD_ALT, '&'}, {"copy indentation", normal_key_copy_indent}},
	{{keys_MOD_NONE, '@'}, {"convert tabs to spaces in selections", normal_key_tabs_to_spaces}},
	{{keys_MOD_ALT, '@'}, {"convert spaces to tabs in selections", normal_key_spaces_to_tabs}},
	{{keys_MOD_NONE, '_'}, {"trim selections", normal_key_trim_selections}},
	{{keys_MOD_NONE, 'C'}, {"duplicate selections on the lines that follow them.", normal_key_copy_selections_below}},
	{{keys_MOD_ALT, 'C'}, {"duplicate selections on the lines that precede them.", normal_key_copy_selections_above}},
	{{keys_MOD_NONE, keys_SPACE}, {"user mappings", normal_key_user_mappings}},
	{{keys_MOD_NONE, keys_PAGE_UP}, {"scroll one page up", normal_key_scroll_page_up}},
	{{keys_MOD_NONE, keys_PAGE_DOWN}, {"scroll one page down", normal_key_scroll_page_down}},
	{{keys_MOD_CONTROL, 'b'}, {"scroll one page up", normal_key_scroll_page_up}},
	{{keys_MOD_CONTROL, 'f'}, {"scroll one page down", normal_key_scroll_page_down}},
	{{keys_MOD_CONTROL, 'u'}, {"scroll half a page up", normal_key_scroll_half_up}},
	{{keys_MOD_CONTROL, 'd'}, {"scroll half a page down", normal_key_scroll_half_down}},
	{{keys_MOD_NONE, 'z'}, {"restore selections from register", normal_key_restore_selections}},
	{{keys_MOD_ALT, 'z'}, {"combine selections from register", normal_key_combine_selections_from}},
	{{keys_MOD_NONE, 'Z'}, {"save selections to register", normal_key_save_selections}},
	{{keys_MOD_ALT, 'Z'}, {"combine selections to register", normal_key_combine_selections_to}},
	{{keys_MOD_CONTROL, 'l'}, {"force redraw", normal_key_force_redraw}},
}

// normal_get_command looks up the NormalCmd for key (port of
// get_normal_command).
normal_get_command :: proc(key: Keys_Key) -> (Normal_Cmd, bool) {
	for e in normal_keymap_entries {
		if e.key == key {
			return e.cmd, true
		}
	}
	return {}, false
}

