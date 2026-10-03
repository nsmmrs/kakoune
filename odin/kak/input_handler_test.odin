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
