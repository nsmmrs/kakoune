// Tests for the input_handler port. Only standalone-testable behavior
// is covered: no test calls a STUBBED proc (see the gaps list in the
// wave summary). Leak checks use a tracking allocator.
package kak

import "core:mem"
import "core:strings"
import "core:testing"

input_handler_test_key :: proc(mods: Keys_Modifiers, code: rune) -> Keys_Key {
	return Keys_Key{modifiers = mods, key = code}
}

@(test)
test_input_handler_word_motions :: proc(t: ^testing.T) {
	pos := 0
	input_handler_to_next_word_begin(&pos, "hello world", false)
	testing.expect_value(t, pos, 6)
	input_handler_to_next_word_begin(&pos, "hello world", false)
	testing.expect_value(t, pos, 11)
	input_handler_to_next_word_begin(&pos, "hello world", false)
	testing.expect_value(t, pos, 11)

	pos = 5
	input_handler_to_next_word_begin(&pos, "hello world", false)
	testing.expect_value(t, pos, 6)

	pos = 11
	input_handler_to_prev_word_begin(&pos, "hello world", false)
	testing.expect_value(t, pos, 6)
	input_handler_to_prev_word_begin(&pos, "hello world", false)
	testing.expect_value(t, pos, 0)
	input_handler_to_prev_word_begin(&pos, "hello world", false)
	testing.expect_value(t, pos, 0)

	pos = 0
	input_handler_to_next_word_end(&pos, "hello world", false)
	testing.expect_value(t, pos, 4)
	input_handler_to_next_word_end(&pos, "hello world", false)
	testing.expect_value(t, pos, 10)

	// Punctuation forms its own word stops for Word.
	pos = 0
	input_handler_to_next_word_begin(&pos, "a,b", false)
	testing.expect_value(t, pos, 1)
	input_handler_to_next_word_begin(&pos, "a,b", false)
	testing.expect_value(t, pos, 2)

	// WORD skips punctuation as word contents.
	pos = 0
	input_handler_to_next_word_begin(&pos, "a,b c", true)
	testing.expect_value(t, pos, 4)
	pos = 5
	input_handler_to_prev_word_begin(&pos, "a,b c", true)
	testing.expect_value(t, pos, 4)

	// Motions count characters, not bytes.
	pos = 0
	input_handler_to_next_word_begin(&pos, "héllo wörld", false)
	testing.expect_value(t, pos, 6)
	pos = 11
	input_handler_to_prev_word_begin(&pos, "héllo wörld", false)
	testing.expect_value(t, pos, 6)

	// Blank-only tail stops at end.
	pos = 3
	input_handler_to_next_word_begin(&pos, "ab   ", false)
	testing.expect_value(t, pos, 5)
}

@(test)
test_input_handler_char_helpers :: proc(t: ^testing.T) {
	testing.expect_value(t, input_handler_char_at("héllo", 1), 'é')
	testing.expect_value(t, input_handler_char_to_byte("héllo", 2), 3)
	testing.expect_value(t, input_handler_byte_to_char("héllo", 3), 2)
	s := input_handler_splice("abcd", 1, 3, "XY", context.temp_allocator)
	testing.expect_value(t, s, "aXYd")
}

@(test)
test_input_handler_key_validity :: proc(t: ^testing.T) {
	testing.expect(t, input_handler_is_valid_key(input_handler_test_key(keys_MOD_NONE, 'a')))
	testing.expect(t, input_handler_is_valid_key(input_handler_test_key(keys_MOD_CONTROL, 'a')))
	testing.expect(t, input_handler_is_valid_key(input_handler_test_key(keys_MOD_MOUSE_PRESS, 0)))
	testing.expect(t, input_handler_is_valid_key(input_handler_test_key(keys_MOD_MENU_SELECT, 3)))
	testing.expect(t, !input_handler_is_valid_key(input_handler_test_key(keys_MOD_NONE, 0x110000)))

	cp, ok := input_handler_get_raw_codepoint(input_handler_test_key(keys_MOD_NONE, 'a'))
	testing.expect(t, ok && cp == 'a')
	cp, ok = input_handler_get_raw_codepoint(input_handler_test_key(keys_MOD_CONTROL, 'a'))
	testing.expect(t, ok && cp == 1)
	cp, ok = input_handler_get_raw_codepoint(input_handler_test_key(keys_MOD_CONTROL, 'J'))
	testing.expect(t, ok && cp == '\n')
	_, ok = input_handler_get_raw_codepoint(input_handler_test_key(keys_MOD_NONE, keys_UP))
	testing.expect(t, !ok)
}

@(test)
test_input_handler_line_editor :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	alloc := mem.tracking_allocator(&track)
	defer mem.tracking_allocator_destroy(&track)

	{
		reg := face_registry_make(nil, alloc)
		defer face_registry_destroy(&reg)
		ed: input_handler_Line_Editor
		input_handler_line_editor_init(&ed, &reg, alloc)
		defer input_handler_line_editor_destroy(&ed)

		hello := "hello world"
		for i in 0 ..< len(hello) {
			input_handler_line_editor_handle_key(&ed, input_handler_test_key(keys_MOD_NONE, rune(hello[i])))
		}
		testing.expect_value(t, ed.line, "hello world")
		testing.expect_value(t, ed.cursor_pos, 11)

	// Home/End/Ctrl-a/Ctrl-e.
	input_handler_line_editor_handle_key(&ed, input_handler_test_key(keys_MOD_NONE, keys_HOME))
	testing.expect_value(t, ed.cursor_pos, 0)
	input_handler_line_editor_handle_key(&ed, input_handler_test_key(keys_MOD_CONTROL, 'e'))
	testing.expect_value(t, ed.cursor_pos, 11)
	input_handler_line_editor_handle_key(&ed, input_handler_test_key(keys_MOD_CONTROL, 'a'))
	testing.expect_value(t, ed.cursor_pos, 0)
	input_handler_line_editor_handle_key(&ed, input_handler_test_key(keys_MOD_NONE, keys_END))
	testing.expect_value(t, ed.cursor_pos, 11)

	// Left/Right/Ctrl-b/Ctrl-f clamp at the edges.
	input_handler_line_editor_handle_key(&ed, input_handler_test_key(keys_MOD_NONE, keys_RIGHT))
	testing.expect_value(t, ed.cursor_pos, 11)
	input_handler_line_editor_handle_key(&ed, input_handler_test_key(keys_MOD_NONE, keys_LEFT))
	testing.expect_value(t, ed.cursor_pos, 10)
	input_handler_line_editor_handle_key(&ed, input_handler_test_key(keys_MOD_CONTROL, 'b'))
	testing.expect_value(t, ed.cursor_pos, 9)
	input_handler_line_editor_handle_key(&ed, input_handler_test_key(keys_MOD_CONTROL, 'f'))
	testing.expect_value(t, ed.cursor_pos, 10)

	// Backspace/Delete remove around the cursor.
	input_handler_line_editor_handle_key(&ed, input_handler_test_key(keys_MOD_NONE, keys_BACKSPACE))
	testing.expect_value(t, ed.line, "hello word")
	testing.expect_value(t, ed.cursor_pos, 9)
	input_handler_line_editor_handle_key(&ed, input_handler_test_key(keys_MOD_NONE, keys_END))
	input_handler_line_editor_handle_key(&ed, input_handler_test_key(keys_MOD_NONE, keys_DELETE))
	testing.expect_value(t, ed.line, "hello word")
	input_handler_line_editor_handle_key(&ed, input_handler_test_key(keys_MOD_NONE, keys_LEFT))
	input_handler_line_editor_handle_key(&ed, input_handler_test_key(keys_MOD_NONE, keys_DELETE))
	testing.expect_value(t, ed.line, "hello wor")

	// Alt-b/Alt-f word jumps.
	input_handler_line_editor_handle_key(&ed, input_handler_test_key(keys_MOD_NONE, keys_END))
	input_handler_line_editor_handle_key(&ed, input_handler_test_key(keys_MOD_ALT, 'b'))
	testing.expect_value(t, ed.cursor_pos, 6)
	input_handler_line_editor_handle_key(&ed, input_handler_test_key(keys_MOD_ALT, 'f'))
	testing.expect_value(t, ed.cursor_pos, 9)

	// Ctrl-w kills the previous word into the clipboard, Ctrl-y yanks.
	input_handler_line_editor_handle_key(&ed, input_handler_test_key(keys_MOD_CONTROL, 'w'))
	testing.expect_value(t, ed.line, "hello ")
	testing.expect_value(t, ed.clipboard, "wor")
	input_handler_line_editor_handle_key(&ed, input_handler_test_key(keys_MOD_CONTROL, 'y'))
	testing.expect_value(t, ed.line, "hello wor")

	// Ctrl-k kills to end of line, Ctrl-u kills to start.
	input_handler_line_editor_handle_key(&ed, input_handler_test_key(keys_MOD_CONTROL, 'a'))
	input_handler_line_editor_handle_key(&ed, input_handler_test_key(keys_MOD_CONTROL, 'k'))
	testing.expect_value(t, ed.line, "")
	testing.expect_value(t, ed.clipboard, "hello wor")
	input_handler_line_editor_handle_key(&ed, input_handler_test_key(keys_MOD_CONTROL, 'y'))
	testing.expect_value(t, ed.line, "hello wor")
	input_handler_line_editor_handle_key(&ed, input_handler_test_key(keys_MOD_CONTROL, 'u'))
	testing.expect_value(t, ed.line, "")
	testing.expect_value(t, ed.cursor_pos, 0)

	// insert_from replaces from start to the cursor.
	input_handler_line_editor_reset(&ed, "flower", "")
	input_handler_line_editor_handle_key(&ed, input_handler_test_key(keys_MOD_CONTROL, 'a'))
	input_handler_line_editor_insert_from(&ed, 0, "fl")
	testing.expect_value(t, ed.line, "flflower")
	testing.expect_value(t, ed.cursor_pos, 2)
	input_handler_line_editor_handle_key(&ed, input_handler_test_key(keys_MOD_NONE, keys_END))
	input_handler_line_editor_insert_from(&ed, 2, "ow")
	testing.expect_value(t, ed.line, "flow")
	testing.expect_value(t, ed.cursor_pos, 4)

	// Cursor column and the empty-text display line.
	testing.expect_value(t, input_handler_line_editor_cursor_display_column(&ed), Units_ColumnCount(4))
	input_handler_line_editor_reset(&ed, "", "empty")
	dl := input_handler_line_editor_build_display_line(&ed, 80, alloc)
	defer {
		for a in dl.atoms {
			delete(a.text, alloc)
		}
		delete(dl.atoms)
	}
	testing.expect_value(t, len(dl.atoms), 3)
	testing.expect_value(t, dl.atoms[0].text, "")
	testing.expect_value(t, dl.atoms[1].text, "e")
	testing.expect_value(t, dl.atoms[2].text, "mpty")

	// Mid-line cursor renders three atoms.
	input_handler_line_editor_reset(&ed, "abc", "")
	input_handler_line_editor_handle_key(&ed, input_handler_test_key(keys_MOD_NONE, keys_LEFT))
	dl2 := input_handler_line_editor_build_display_line(&ed, 80, alloc)
	defer {
		for a in dl2.atoms {
			delete(a.text, alloc)
		}
		delete(dl2.atoms)
	}
		testing.expect_value(t, len(dl2.atoms), 3)
		testing.expect_value(t, dl2.atoms[0].text, "ab")
		testing.expect_value(t, dl2.atoms[1].text, "c")
		testing.expect_value(t, dl2.atoms[2].text, "")
	}

	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_input_handler_recording :: proc(t: ^testing.T) {
	h := Input_Handler{}
	defer delete(h.last_insert.keys)
	defer delete(h.recorded_keys)
	testing.expect(t, !input_handler_is_recording(&h))

	input_handler_start_recording(&h, 'q')
	testing.expect(t, input_handler_is_recording(&h))
	testing.expect_value(t, input_handler_recording_reg(&h), 'q')

	key := input_handler_test_key(keys_MOD_NONE, 'x')
	input_handler_record_key(&h, key)
	testing.expect_value(t, len(h.recorded_keys), 1)
	input_handler_drop_last_recorded_key(&h)
	testing.expect_value(t, len(h.recorded_keys), 0)

	// Last-insert and macro recording both fire at level 0.
	utils_nested_bool_set(&h.last_insert.recording)
	defer utils_nested_bool_unset(&h.last_insert.recording)
	input_handler_record_key(&h, key)
	testing.expect_value(t, len(h.last_insert.keys), 1)
	testing.expect_value(t, len(h.recorded_keys), 1)
	input_handler_drop_last_recorded_key(&h)
	testing.expect_value(t, len(h.last_insert.keys), 0)
	testing.expect_value(t, len(h.recorded_keys), 0)

	// Keys at other levels are ignored.
	h.handle_key_level = 5
	input_handler_record_key(&h, key)
	testing.expect_value(t, len(h.last_insert.keys), 0)
	testing.expect_value(t, len(h.recorded_keys), 0)
	h.handle_key_level = 0

	// Empty recordings skip the register entirely.
	input_handler_stop_recording(&h)
	testing.expect(t, !input_handler_is_recording(&h))
	testing.expect_value(t, input_handler_recording_reg(&h), rune(0))
}

@(test)
test_input_handler_mode_pure :: proc(t: ^testing.T) {
	n := input_handler_Normal{params = Normal_Params{count = 5, reg = 'a'}}
	testing.expect_value(t, input_handler_normal_vtable.take_pending_count(&n), uint(5))
	testing.expect_value(t, n.params.count, 0)
	testing.expect_value(t, input_handler_normal_vtable.take_pending_count(&n), uint(1))
	testing.expect_value(t, input_handler_normal_vtable.name(&n), "normal")
	testing.expect_value(t, input_handler_normal_vtable.keymap_mode(&n), Keymap_Manager_Mode.Normal)

	nk := input_handler_Next_Key{name = "next-key[x]", keymap = .User}
	testing.expect_value(t, input_handler_next_key_vtable.name(&nk), "next-key[x]")
	testing.expect_value(t, input_handler_next_key_vtable.keymap_mode(&nk), Keymap_Manager_Mode.User)
	testing.expect_value(t, input_handler_next_key_vtable.take_pending_count(&nk), uint(1))

	p := input_handler_Prompt{}
	testing.expect_value(t, input_handler_prompt_vtable.name(&p), "prompt")
	testing.expect_value(t, input_handler_prompt_vtable.keymap_mode(&p), Keymap_Manager_Mode.Prompt)

	ins := input_handler_Insert{}
	testing.expect_value(t, input_handler_insert_vtable.name(&ins), "insert")
	testing.expect_value(t, input_handler_insert_vtable.keymap_mode(&ins), Keymap_Manager_Mode.Insert)
}

input_handler_test_destroy_count := 0

input_handler_test_destroy :: proc(data: rawptr, allocator: mem.Allocator) {
	_ = data
	_ = allocator
	input_handler_test_destroy_count += 1
}

input_handler_test_vtable := Input_Mode_VTable{destroy = input_handler_test_destroy}

@(test)
test_input_handler_guards :: proc(t: ^testing.T) {
	h := Input_Handler{allocator = context.allocator}
	defer delete(h.mode_stack)
	input_handler_test_destroy_count = 0

	// Releasing a mode that left the stack destroys it.
	mode := new(Input_Mode)
	mode.vtable = &input_handler_test_vtable
	input_handler_mode_guard(mode)
	testing.expect(t, input_handler_mode_guarded(mode))
	input_handler_mode_guard(mode)
	input_handler_mode_release(&h, mode)
	testing.expect(t, input_handler_mode_guarded(mode))
	input_handler_mode_release(&h, mode)
	testing.expect_value(t, input_handler_test_destroy_count, 1)

	// Releasing a mode still on the stack keeps it.
	mode2 := new(Input_Mode)
	defer free(mode2)
	mode2.vtable = &input_handler_test_vtable
	append(&h.mode_stack, mode2)
	input_handler_mode_guard(mode2)
	input_handler_mode_release(&h, mode2)
	testing.expect_value(t, input_handler_test_destroy_count, 1)
	testing.expect(t, !input_handler_mode_guarded(mode2))
	testing.expect(t, input_handler_mode_enabled(&h, mode2))

	testing.expect_value(t, len(input_handler_guard_counts), 0)
}

@(test)
test_input_handler_callback_destroys :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	alloc := mem.tracking_allocator(&track)
	defer mem.tracking_allocator_destroy(&track)

	reg_data := new(input_handler_Normal_Register_Data, alloc)
	input_handler_normal_register_destroy(reg_data, alloc)
	key_data := new(input_handler_Prompt_Key_Data, alloc)
	input_handler_prompt_key_destroy(key_data, alloc)
	ins_data := new(input_handler_Insert_Key_Data, alloc)
	input_handler_insert_key_destroy(ins_data, alloc)
	exp_data := new(input_handler_Explicit_Data, alloc)
	input_handler_prompt_explicit_destroy(exp_data, alloc)
	auto_key := new(input_handler_Autoinfo_Key_Data, alloc)
	input_handler_autoinfo_key_destroy(auto_key, alloc)
	auto_idle := new(input_handler_Autoinfo_Idle_Data, alloc)
	auto_idle.title = strings.clone("title", alloc)
	auto_idle.info = strings.clone("info", alloc)
	input_handler_autoinfo_idle_destroy(auto_idle, alloc)

	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_input_handler_face_and_mode_info :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	alloc := mem.tracking_allocator(&track)
	defer mem.tracking_allocator_destroy(&track)

	{
		reg := face_registry_make(nil, alloc)
		defer face_registry_destroy(&reg)
		testing.expect(t, input_handler_face(&reg, "NoSuchFace") == Face{})
		testing.expect(t, input_handler_face(&reg, "PrimarySelection") != Face{})

		info := Mode_Info{}
		info.display_line.atoms = make([dynamic]Display_Atom, 2, alloc)
		info.display_line.atoms[0] = Display_Atom{type = .Text, text = strings.clone("a", alloc)}
		info.display_line.atoms[1] = Display_Atom{type = .Text, text = strings.clone("b", alloc)}
		input_handler_mode_info_destroy(&info, alloc)
		testing.expect(t, info.display_line.atoms == nil)
	}

	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_input_handler_selections :: proc(t: ^testing.T) {
	sel := input_handler_selection_from_coord(Coord_Buffer{line = 1, column = 2})
	testing.expect(t, input_handler_sel_min(&sel) == Coord_Buffer{line = 1, column = 2})
	testing.expect(t, input_handler_sel_max(&sel) == Coord_Buffer{line = 1, column = 2})

	sel.anchor = Coord_Buffer{line = 3, column = 4}
	sel.cursor = coord_buffer_and_target(Coord_Buffer{line = 1, column = 2})
	testing.expect(t, input_handler_sel_min(&sel) == Coord_Buffer{line = 1, column = 2})
	testing.expect(t, input_handler_sel_max(&sel) == Coord_Buffer{line = 3, column = 4})
	input_handler_sel_set_min_max(&sel, Coord_Buffer{}, Coord_Buffer{line = 9, column = 9})
	testing.expect(t, sel.anchor == Coord_Buffer{line = 9, column = 9})
	testing.expect(t, sel.cursor.coord == Coord_Buffer{})
}

// input_handler_test_pop_state is shared fake-mode state for the
// reentrant-pop test below.
input_handler_test_pop_state :: struct {
	middle_destroyed:          bool,
	middle_named_after_destroy: bool,
	destroy_count:             int,
}

// input_handler_test_fake_mode is a minimal mode whose on_enabled can
// pop itself, mimicking single-command normal resolving Pop_On_Enabled.
input_handler_test_fake_mode :: struct {
	h:              ^Input_Handler,
	self:           ^Input_Mode,
	state:          ^input_handler_test_pop_state,
	name:           string,
	pop_on_enabled: bool,
	is_middle:      bool,
}

input_handler_test_fake_on_disabled :: proc(data: rawptr, from_push: bool) {
	_ = data
	_ = from_push
}

input_handler_test_fake_on_enabled :: proc(data: rawptr, from_pop: bool) {
	f := cast(^input_handler_test_fake_mode)(data)
	if f.pop_on_enabled && from_pop {
		input_handler_pop_mode(f.h, f.self)
	}
}

input_handler_test_fake_name :: proc(data: rawptr) -> string {
	f := cast(^input_handler_test_fake_mode)(data)
	if f.is_middle && f.state.middle_destroyed {
		f.state.middle_named_after_destroy = true
	}
	return f.name
}

input_handler_test_fake_destroy :: proc(data: rawptr, allocator: mem.Allocator) {
	_ = allocator
	f := cast(^input_handler_test_fake_mode)(data)
	if f.is_middle {
		f.state.middle_destroyed = true
	}
	f.state.destroy_count += 1
}

input_handler_test_fake_vtable := Input_Mode_VTable{
	on_disabled = input_handler_test_fake_on_disabled,
	on_enabled  = input_handler_test_fake_on_enabled,
	name        = input_handler_test_fake_name,
	destroy     = input_handler_test_fake_destroy,
}

@(test)
test_input_handler_pop_mode_reentrant_pop :: proc(t: ^testing.T) {
	h := Input_Handler{allocator = context.allocator}
	context_init_empty(&h.ctx, context.allocator)
	defer context_destroy(&h.ctx)
	// run_hook needs the disabled_hooks/debug options on the scope.
	scope := scope_make(context.allocator)
	reg: Options_Registry
	option_manager_registry_init(&reg, &scope.data.options)
	// Destroy the scope (owning the options) before the registry
	// (owning the descs the options borrow).
	defer option_manager_registry_destroy(&reg)
	defer scope_destroy(&scope)
	_, derr := option_manager_registry_declare(&reg, "disabled_hooks", "", Regex{})
	testing.expect_value(t, derr, Option_Manager_Error.None)
	_, berr := option_manager_registry_declare(&reg, "debug", "", Option_types_Debug_Flags{})
	testing.expect_value(t, berr, Option_Manager_Error.None)
	append(&h.ctx.local_scopes, &scope)
	defer delete(h.mode_stack)

	state: input_handler_test_pop_state
	bottom_data := input_handler_test_fake_mode{h = &h, state = &state, name = "bottom"}
	middle_data := input_handler_test_fake_mode{
		h = &h, state = &state, name = "middle", pop_on_enabled = true, is_middle = true,
	}
	top_data := input_handler_test_fake_mode{h = &h, state = &state, name = "top"}
	bottom := new(Input_Mode)
	bottom.vtable = &input_handler_test_fake_vtable
	bottom.input_handler = &h
	bottom.data = &bottom_data
	bottom_data.self = bottom
	middle := new(Input_Mode)
	middle.vtable = &input_handler_test_fake_vtable
	middle.input_handler = &h
	middle.data = &middle_data
	middle_data.self = middle
	top := new(Input_Mode)
	top.vtable = &input_handler_test_fake_vtable
	top.input_handler = &h
	top.data = &top_data
	top_data.self = top
	append(&h.mode_stack, bottom, middle, top)

	// Popping top enables middle, which pops itself; the outer pop
	// must name the surviving bottom for the hook, never the freed
	// middle.
	input_handler_pop_mode(&h, top)
	testing.expect(t, !state.middle_named_after_destroy, "pop_mode used the mode destroyed by a reentrant pop")
	testing.expect_value(t, state.destroy_count, 2)
	testing.expect_value(t, len(h.mode_stack), 1)
	testing.expect(t, h.mode_stack[0] == bottom)
	input_handler_destroy_mode(&h, bottom)
}

@(test)
test_input_handler_key_error_slot :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	alloc := mem.tracking_allocator(&track)
	defer mem.tracking_allocator_destroy(&track)
	h := Input_Handler{allocator = alloc}
	_, _, failed := input_handler_take_key_error(&h, alloc)
	testing.expect(t, !failed)
	// Set/take round-trips through the caller allocator.
	input_handler_set_key_error(&h, "boom")
	msg, kind, failed2 := input_handler_take_key_error(&h, alloc)
	testing.expect(t, failed2)
	testing.expect_value(t, kind, Input_Handler_Key_Error_Kind.Runtime)
	testing.expect_value(t, msg, "boom")
	delete(msg, alloc)
	// Set replaces; clear drops without leaking.
	input_handler_set_key_error(&h, "one", .No_Selections_Remaining)
	input_handler_set_key_error(&h, "two")
	input_handler_clear_key_error(&h)
	_, _, failed3 := input_handler_take_key_error(&h, alloc)
	testing.expect(t, !failed3)
	testing.expect_value(t, len(track.allocation_map), 0)
}

// test_input_handler_key_error_flag covers the key_error channel that
// carries C++ throws escaping the void on_key pipeline to key-driving
// loops (exec aborts like a C++ unwind instead of swallowing).
@(test)
test_input_handler_key_error_flag :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	alloc := mem.tracking_allocator(&track)
	defer mem.tracking_allocator_destroy(&track)

	h := Input_Handler{allocator = alloc}
	testing.expect(t, !input_handler_has_key_error(&h))

	// Set replaces any pending message; take moves it out and clears.
	input_handler_set_key_error(&h, "no selections remaining")
	testing.expect(t, input_handler_has_key_error(&h))
	input_handler_set_key_error(&h, "nothing selected")
	msg, _, failed := input_handler_take_key_error(&h, context.temp_allocator)
	defer delete(msg, context.temp_allocator)
	testing.expect(t, failed)
	testing.expect_value(t, msg, "nothing selected")
	testing.expect(t, !input_handler_has_key_error(&h))
	_, _, failed2 := input_handler_take_key_error(&h, context.temp_allocator)
	testing.expect(t, !failed2)

	// Clear drops a pending failure.
	input_handler_set_key_error(&h, "stale")
	input_handler_clear_key_error(&h)
	testing.expect(t, !input_handler_has_key_error(&h))

	testing.expect_value(t, len(track.allocation_map), 0)
}
