// Port of Kakoune's src/input_handler.{hh,cc}: the modal input stack
// (Normal/Insert/Prompt/NextKey modes), macro recording, last-insert
// repeat, and the prompt line editor.
//
// Types (Input_Handler, Input_Mode, Input_Mode_VTable) come from
// knot.odin; the concrete modes are private structs in this file
// behind package-level vtables.
//
// Ownership:
//   * input_handler_make returns a heap Input_Handler; free it with
//     input_handler_destroy (which pops and destroys every mode).
//     input_handler_init/deinit are the placement pair for by-value
//     owners (Client embeds Input_Handler by value).
//   * Mode_Info atoms returned by input_handler_mode_info own their
//     text (cloned with the given allocator, literals included); free
//     with input_handler_mode_info_destroy.
//   * Prompt/NextKey take ownership of their callback structs; the
//     mode destroy runs each non-nil destroy proc.
//   * input_handler_prompt and input_handler_on_next_key CLONE the
//     prompt text and mode name; callers retain theirs.
//   * Strings passed to stubbed foreign procs are borrowed (callee
//     clones synchronously, mirroring the C++ by-value boundary),
//     except where the C++ moves ownership: client_menu_show takes
//     the choices array.
//   * input_handler_history_enabled is declared in input_handler.hh
//     but never defined in src/ (dead declaration); it is omitted.
//
// Deviation: C++ keeps modes alive across reentrant callbacks with
// RefPtr (InputMode::handle_key and the idle-timer lambdas hold a
// keep_alive). Odin vtables carry no refcount, so this file guards
// the current mode across on_key (input_handler_process_key) and
// across timer dispatch (input_handler_timer_fired); a mode popped
// while guarded is destroyed when the last guard releases
// (input_handler_mode_guard / input_handler_mode_release).
package kak

import "core:mem"
import "core:strings"
import "core:time"

// Input_Handler_Error reports input-handler failures. Zero value None
// is success. The C++ throws runtime_error in these cases.
Input_Handler_Error :: enum {
	None,
	// repeat_last_insert outside a recordable Normal context.
	Repeat_Unavailable,
	// insert into a read-only buffer.
	Read_Only,
}

// input_handler_report_error shows an operation error on the status line.
// This ports the C++ main-loop catch, which reports throws escaping key
// handling. Used at void-callback boundaries where errors cannot
// propagate; the operation aborts exactly like a C++ unwind (defers run).
input_handler_report_error :: proc(ctx: ^Context, err: Input_Handler_Error) {
	if ctx.client == nil {
		return
	}
	msg := "buffer is read-only"
	if err == .Repeat_Unavailable {
		msg = "repeating last insert not available in this context"
	}
	alloc := ctx.client.allocator
	prompt := client_display_line_from_text("", Face{}, alloc)
	content := client_display_line_from_text(msg, Face{}, alloc)
	client_print_status(ctx.client, prompt, content, Units_ColumnCount(0), .Status)
}

// input_handler_For_Each_Apply is the selection visitor passed to the
// (stubbed) selection_list_for_each. It carries an explicit ctx
// because Odin procs cannot capture; the C++ lambdas capture the
// buffer and the strings to insert.
input_handler_For_Each_Apply :: #type proc(ctx: rawptr, index: int, sel: ^Selection)

// input_handler_Record_Key_Apply records one key; passed to the
// (stubbed) insert_completer_select with the handler as ctx.
input_handler_Record_Key_Apply :: #type proc(ctx: rawptr, key: Keys_Key)

// Special-register help shown by the register/next-key autoinfo.
input_handler_REGISTER_DOC :: string(
	"Special registers:\n" +
	"[0-9]: selections capture group\n" +
	"%:     buffer name\n" +
	".:     selection contents\n" +
	"#:     selection index\n" +
	"_:     null register\n" +
	"\":     default yank/paste register\n" +
	"@:     default macro register\n" +
	"/:     default search register\n" +
	"^:     default mark register\n" +
	"|:     default shell command register\n" +
	"::     last entered command\n",
)

// Extra word characters for word motions (C++ is_word default {'_'}).
input_handler_EXTRA_WORD_CHARS := [1]rune{'_'}

// input_handler_key_is reports whether key is exactly (mods, code),
// mirroring C++ Key equality (e.g. key == ctrl('r')).
input_handler_key_is :: proc(key: Keys_Key, mods: Keys_Modifiers, code: rune) -> bool {
	return key.modifiers == mods && key.key == code
}

// input_handler_is_valid_key mirrors the C++ is_valid: keys with
// mouse/resize/menu modifiers pass, plain keys must be valid Unicode.
input_handler_is_valid_key :: proc(key: Keys_Key) -> bool {
	valid_mods := keys_MOD_CONTROL | keys_MOD_ALT | keys_MOD_SHIFT
	return (key.modifiers & ~valid_mods) != keys_MOD_NONE || key.key <= 0x10FFFF
}

// input_handler_get_raw_codepoint maps a key to the codepoint it
// inserts literally (C-T inserts), mirroring get_raw_codepoint.
input_handler_get_raw_codepoint :: proc(key: Keys_Key) -> (rune, bool) {
	if cp, ok := keys_codepoint(key); ok {
		return cp, true
	}
	if key.modifiers == keys_MOD_CONTROL &&
	   ((key.key >= '@' && key.key <= '_') || (key.key >= 'a' && key.key <= 'z')) {
		upper := key.key
		if upper >= 'a' && upper <= 'z' {
			upper -= 'a' - 'A'
		}
		return upper - '@', true
	}
	return 0, false
}

// input_handler_byte_to_char counts the characters in line[:byte_pos].
input_handler_byte_to_char :: proc(line: string, byte_pos: int) -> int {
	return utf8_distance(line[:byte_pos])
}

// input_handler_char_to_byte returns the byte offset of the char_pos-th
// character of line.
input_handler_char_to_byte :: proc(line: string, char_pos: int) -> int {
	return utf8_advance(line, 0, char_pos)
}

// input_handler_char_at returns the char_pos-th codepoint of line.
input_handler_char_at :: proc(line: string, char_pos: int) -> rune {
	return utf8_codepoint(line, input_handler_char_to_byte(line, char_pos))
}

// input_handler_splice builds s[:lo] + ins + s[hi:]. The caller owns
// the result.
input_handler_splice :: proc(s: string, lo, hi: int, ins: string, allocator := context.allocator) -> string {
	out := make([]u8, lo + len(ins) + (len(s) - hi), allocator)
	copy(out, s[:lo])
	copy(out[lo:], ins)
	copy(out[lo + len(ins):], s[hi:])
	return string(out)
}

// input_handler_is_word reports word membership for motions: vi word
// by default, blank-delimited WORD when big is set.
input_handler_is_word :: proc(cp: rune, big: bool) -> bool {
	if big {
		return unicode_is_word(cp, input_handler_EXTRA_WORD_CHARS[:], .Big_Word)
	}
	return unicode_is_word(cp, input_handler_EXTRA_WORD_CHARS[:])
}

// input_handler_to_next_word_begin moves pos past the current word to
// the next word start (Word unless big selects WORD).
input_handler_to_next_word_begin :: proc(pos: ^int, line: string, big: bool) {
	length := utf8_distance(line)
	if pos^ == length {
		return
	}
	cp := input_handler_char_at(line, pos^)
	if !big && unicode_is_punctuation(cp, input_handler_EXTRA_WORD_CHARS[:]) {
		for pos^ != length && unicode_is_punctuation(input_handler_char_at(line, pos^), input_handler_EXTRA_WORD_CHARS[:]) {
			pos^ += 1
		}
	} else if input_handler_is_word(cp, big) {
		for pos^ != length && input_handler_is_word(input_handler_char_at(line, pos^), big) {
			pos^ += 1
		}
	}
	for pos^ != length && unicode_is_horizontal_blank(input_handler_char_at(line, pos^)) {
		pos^ += 1
	}
}

// input_handler_to_next_word_end moves pos to the next word end.
input_handler_to_next_word_end :: proc(pos: ^int, line: string, big: bool) {
	length := utf8_distance(line)
	if pos^ + 1 >= length {
		return
	}
	pos^ += 1
	for pos^ != length && unicode_is_horizontal_blank(input_handler_char_at(line, pos^)) {
		pos^ += 1
	}
	cp := input_handler_char_at(line, pos^)
	if !big && unicode_is_punctuation(cp, input_handler_EXTRA_WORD_CHARS[:]) {
		for pos^ != length && unicode_is_punctuation(input_handler_char_at(line, pos^), input_handler_EXTRA_WORD_CHARS[:]) {
			pos^ += 1
		}
	} else if input_handler_is_word(cp, big) {
		for pos^ != length && input_handler_is_word(input_handler_char_at(line, pos^), big) {
			pos^ += 1
		}
	}
	pos^ -= 1
}

// input_handler_to_prev_word_begin moves pos to the previous word start.
input_handler_to_prev_word_begin :: proc(pos: ^int, line: string, big: bool) {
	if pos^ == 0 {
		return
	}
	pos^ -= 1
	for pos^ != 0 && unicode_is_horizontal_blank(input_handler_char_at(line, pos^)) {
		pos^ -= 1
	}
	cp := input_handler_char_at(line, pos^)
	if !big && unicode_is_punctuation(cp, input_handler_EXTRA_WORD_CHARS[:]) {
		for pos^ != 0 && unicode_is_punctuation(input_handler_char_at(line, pos^), input_handler_EXTRA_WORD_CHARS[:]) {
			pos^ -= 1
		}
		if !unicode_is_punctuation(input_handler_char_at(line, pos^), input_handler_EXTRA_WORD_CHARS[:]) {
			pos^ += 1
		}
	} else if input_handler_is_word(cp, big) {
		for pos^ != 0 && input_handler_is_word(input_handler_char_at(line, pos^), big) {
			pos^ -= 1
		}
		if !input_handler_is_word(input_handler_char_at(line, pos^), big) {
			pos^ += 1
		}
	}
}

// input_handler_Erase_Move selects the word motion used by a kill.
input_handler_Erase_Move :: enum {
	Prev_Word,
	Prev_Big_Word,
	Next_Word,
	Next_Big_Word,
}

// input_handler_Line_Editor is the C++ LineEditor: the prompt line
// with Emacs/readline bindings. Owns line and clipboard; empty_text
// is borrowed; faces is borrowed.
input_handler_Line_Editor :: struct {
	cursor_pos: int,
	line:       string,
	empty_text: string,
	clipboard:  string,
	faces:      ^Face_Registry,
	allocator:  mem.Allocator,
}

input_handler_line_editor_init :: proc(ed: ^input_handler_Line_Editor, faces: ^Face_Registry, allocator := context.allocator) {
	ed.cursor_pos = 0
	ed.line = ""
	ed.empty_text = ""
	ed.clipboard = ""
	ed.faces = faces
	ed.allocator = allocator
}

input_handler_line_editor_destroy :: proc(ed: ^input_handler_Line_Editor) {
	if len(ed.line) != 0 {
		delete(ed.line, ed.allocator)
	}
	if len(ed.clipboard) != 0 {
		delete(ed.clipboard, ed.allocator)
	}
	ed.line = ""
	ed.clipboard = ""
}

// input_handler_line_editor_replace swaps the whole line, freeing the old.
input_handler_line_editor_replace :: proc(ed: ^input_handler_Line_Editor, new_line: string) {
	if len(ed.line) != 0 {
		delete(ed.line, ed.allocator)
	}
	ed.line = new_line
}

input_handler_line_editor_handle_key :: proc(ed: ^input_handler_Line_Editor, key: Keys_Key) {
	erase_move := proc(ed: ^input_handler_Line_Editor, move: input_handler_Erase_Move) {
		old_pos := ed.cursor_pos
		switch move {
		case .Prev_Word:
			input_handler_to_prev_word_begin(&ed.cursor_pos, ed.line, false)
		case .Prev_Big_Word:
			input_handler_to_prev_word_begin(&ed.cursor_pos, ed.line, true)
		case .Next_Word:
			input_handler_to_next_word_begin(&ed.cursor_pos, ed.line, false)
		case .Next_Big_Word:
			input_handler_to_next_word_begin(&ed.cursor_pos, ed.line, true)
		}
		lo, hi := ed.cursor_pos, old_pos
		if lo > hi {
			lo, hi = hi, lo
		}
		lo_byte := input_handler_char_to_byte(ed.line, lo)
		hi_byte := input_handler_char_to_byte(ed.line, hi)
		if len(ed.clipboard) != 0 {
			delete(ed.clipboard, ed.allocator)
		}
		ed.clipboard = strings.clone(ed.line[lo_byte:hi_byte], ed.allocator)
		ed.cursor_pos = lo
		input_handler_line_editor_replace(ed, input_handler_splice(ed.line, lo_byte, hi_byte, "", ed.allocator))
	}

	switch {
	case input_handler_key_is(key, keys_MOD_NONE, keys_LEFT) ||
	     input_handler_key_is(key, keys_MOD_CONTROL, 'b'):
		if ed.cursor_pos > 0 {
			ed.cursor_pos -= 1
		}
	case input_handler_key_is(key, keys_MOD_NONE, keys_RIGHT) ||
	     input_handler_key_is(key, keys_MOD_CONTROL, 'f'):
		if ed.cursor_pos < utf8_distance(ed.line) {
			ed.cursor_pos += 1
		}
	case input_handler_key_is(key, keys_MOD_NONE, keys_HOME) ||
	     input_handler_key_is(key, keys_MOD_CONTROL, 'a'):
		ed.cursor_pos = 0
	case input_handler_key_is(key, keys_MOD_NONE, keys_END) ||
	     input_handler_key_is(key, keys_MOD_CONTROL, 'e'):
		ed.cursor_pos = utf8_distance(ed.line)
	case input_handler_key_is(key, keys_MOD_NONE, keys_BACKSPACE) ||
	     input_handler_key_is(key, keys_MOD_SHIFT, keys_BACKSPACE) ||
	     input_handler_key_is(key, keys_MOD_CONTROL, 'h'):
		if ed.cursor_pos != 0 {
			byte_pos := input_handler_char_to_byte(ed.line, ed.cursor_pos)
			prev_byte := input_handler_char_to_byte(ed.line, ed.cursor_pos - 1)
			input_handler_line_editor_replace(ed, input_handler_splice(ed.line, prev_byte, byte_pos, "", ed.allocator))
			ed.cursor_pos -= 1
		}
	case input_handler_key_is(key, keys_MOD_NONE, keys_DELETE) ||
	     input_handler_key_is(key, keys_MOD_CONTROL, 'd'):
		if ed.cursor_pos != utf8_distance(ed.line) {
			byte_pos := input_handler_char_to_byte(ed.line, ed.cursor_pos)
			next_byte := input_handler_char_to_byte(ed.line, ed.cursor_pos + 1)
			input_handler_line_editor_replace(ed, input_handler_splice(ed.line, byte_pos, next_byte, "", ed.allocator))
		}
	case input_handler_key_is(key, keys_MOD_ALT, 'f'):
		input_handler_to_next_word_begin(&ed.cursor_pos, ed.line, false)
	case input_handler_key_is(key, keys_MOD_ALT, 'F'):
		input_handler_to_next_word_begin(&ed.cursor_pos, ed.line, true)
	case input_handler_key_is(key, keys_MOD_ALT, 'b'):
		input_handler_to_prev_word_begin(&ed.cursor_pos, ed.line, false)
	case input_handler_key_is(key, keys_MOD_ALT, 'B'):
		input_handler_to_prev_word_begin(&ed.cursor_pos, ed.line, true)
	case input_handler_key_is(key, keys_MOD_ALT, 'e'):
		input_handler_to_next_word_end(&ed.cursor_pos, ed.line, false)
	case input_handler_key_is(key, keys_MOD_ALT, 'E'):
		input_handler_to_next_word_end(&ed.cursor_pos, ed.line, true)
	case input_handler_key_is(key, keys_MOD_CONTROL, 'k'):
		byte_pos := input_handler_char_to_byte(ed.line, ed.cursor_pos)
		if len(ed.clipboard) != 0 {
			delete(ed.clipboard, ed.allocator)
		}
		ed.clipboard = strings.clone(ed.line[byte_pos:], ed.allocator)
		input_handler_line_editor_replace(ed, strings.clone(ed.line[:byte_pos], ed.allocator))
	case input_handler_key_is(key, keys_MOD_CONTROL, 'u'):
		byte_pos := input_handler_char_to_byte(ed.line, ed.cursor_pos)
		if len(ed.clipboard) != 0 {
			delete(ed.clipboard, ed.allocator)
		}
		ed.clipboard = strings.clone(ed.line[:byte_pos], ed.allocator)
		input_handler_line_editor_replace(ed, strings.clone(ed.line[byte_pos:], ed.allocator))
		ed.cursor_pos = 0
	case input_handler_key_is(key, keys_MOD_CONTROL, 'w') ||
	     input_handler_key_is(key, keys_MOD_ALT, keys_BACKSPACE):
		erase_move(ed, .Prev_Word)
	case input_handler_key_is(key, keys_MOD_CONTROL, 'W'):
		erase_move(ed, .Prev_Big_Word)
	case input_handler_key_is(key, keys_MOD_ALT, 'd'):
		erase_move(ed, .Next_Word)
	case input_handler_key_is(key, keys_MOD_ALT, 'D'):
		erase_move(ed, .Next_Big_Word)
	case input_handler_key_is(key, keys_MOD_CONTROL, 'y'):
		byte_pos := input_handler_char_to_byte(ed.line, ed.cursor_pos)
		input_handler_line_editor_replace(ed, input_handler_splice(ed.line, byte_pos, byte_pos, ed.clipboard, ed.allocator))
		ed.cursor_pos += utf8_distance(ed.clipboard)
	case:
		if cp, ok := keys_codepoint(key); ok {
			input_handler_line_editor_insert_codepoint(ed, cp)
		}
	}
}

input_handler_line_editor_insert_codepoint :: proc(ed: ^input_handler_Line_Editor, cp: rune) {
	byte_pos := input_handler_char_to_byte(ed.line, ed.cursor_pos)
	buf: [4]byte
	n := utf8_dump(cp, buf[:])
	input_handler_line_editor_replace(ed, input_handler_splice(ed.line, byte_pos, byte_pos, string(buf[:n]), ed.allocator))
	ed.cursor_pos += 1
}

input_handler_line_editor_insert :: proc(ed: ^input_handler_Line_Editor, str: string) {
	input_handler_line_editor_insert_from(ed, ed.cursor_pos, str)
}

input_handler_line_editor_insert_from :: proc(ed: ^input_handler_Line_Editor, start: int, str: string) {
	assert(start <= ed.cursor_pos)
	start_byte := input_handler_char_to_byte(ed.line, start)
	cursor_byte := input_handler_char_to_byte(ed.line, ed.cursor_pos)
	input_handler_line_editor_replace(ed, input_handler_splice(ed.line, start_byte, cursor_byte, str, ed.allocator))
	ed.cursor_pos = start + utf8_distance(str)
}

// input_handler_line_editor_reset replaces the line, cloning it; the
// empty text is borrowed.
input_handler_line_editor_reset :: proc(ed: ^input_handler_Line_Editor, line, empty_text: string) {
	input_handler_line_editor_replace(ed, strings.clone(line, ed.allocator))
	ed.empty_text = empty_text
	ed.cursor_pos = utf8_distance(ed.line)
}

input_handler_line_editor_cursor_display_column :: proc(ed: ^input_handler_Line_Editor) -> Units_ColumnCount {
	byte_pos := input_handler_char_to_byte(ed.line, ed.cursor_pos)
	return Units_ColumnCount(string_utils_column_length(ed.line[:byte_pos]))
}

// input_handler_line_editor_build_display_line renders the line with a
// cursor atom. The width parameter is unused, as in the C++. All atom
// texts are cloned with allocator; the caller owns the result.
input_handler_line_editor_build_display_line :: proc(ed: ^input_handler_Line_Editor, width: int, allocator := context.allocator) -> Display_Line {
	_ = width
	empty := len(ed.line) == 0
	str := ed.empty_text if empty else ed.line
	line_face := input_handler_face(ed.faces, "StatusLineInfo" if empty else "StatusLine")
	cursor_face := input_handler_face(ed.faces, "StatusCursor")
	atoms := make([dynamic]Display_Atom, 0, 3, allocator)
	cursor_char := ed.cursor_pos
	if cursor_char == utf8_distance(str) {
		append(&atoms, Display_Atom{face = line_face, type = .Text, text = strings.clone(str, allocator)})
		append(&atoms, Display_Atom{face = cursor_face, type = .Text, text = strings.clone(" ", allocator)})
	} else {
		cursor_byte := input_handler_char_to_byte(str, cursor_char)
		next_byte := input_handler_char_to_byte(str, cursor_char + 1)
		append(&atoms, Display_Atom{face = line_face, type = .Text, text = strings.clone(str[:cursor_byte], allocator)})
		append(&atoms, Display_Atom{face = cursor_face, type = .Text, text = strings.clone(str[cursor_byte:next_byte], allocator)})
		append(&atoms, Display_Atom{face = line_face, type = .Text, text = strings.clone(str[next_byte:], allocator)})
	}
	return Display_Line{atoms = atoms}
}

// input_handler_face resolves a named face through the registry chain,
// returning the zero face when unknown (the C++ operator[] asserts,
// but standalone callers may use bare registries).
input_handler_face :: proc(reg: ^Face_Registry, name: string) -> Face {
	r := reg
	for r != nil {
		if spec, ok := r.faces[name]; ok {
			return face_registry_resolve(r, spec)
		}
		r = r.parent
	}
	return Face{}
}

// input_handler_sel_min returns the min end of a selection.
input_handler_sel_min :: proc(sel: ^Selection) -> Coord_Buffer {
	if coord_compare(sel.anchor, sel.cursor.coord) <= 0 {
		return sel.anchor
	}
	return sel.cursor.coord
}

// input_handler_sel_max returns the max end of a selection.
input_handler_sel_max :: proc(sel: ^Selection) -> Coord_Buffer {
	if coord_compare(sel.anchor, sel.cursor.coord) <= 0 {
		return sel.cursor.coord
	}
	return sel.anchor
}

// input_handler_sel_set_min_max rewrites both ends, preserving captures.
input_handler_sel_set_min_max :: proc(sel: ^Selection, min, max: Coord_Buffer) {
	if coord_compare(sel.anchor, sel.cursor.coord) <= 0 {
		sel.anchor = min
		sel.cursor = coord_buffer_and_target(max)
	} else {
		sel.cursor = coord_buffer_and_target(min)
		sel.anchor = max
	}
}

// input_handler_selection_from_coord builds a collapsed selection.
input_handler_selection_from_coord :: proc(c: Coord_Buffer) -> Selection {
	return Selection{basic = Basic_Selection{anchor = c, cursor = coord_buffer_and_target(c)}}
}

// input_handler_idle_timeout reads the idle_timeout option.
input_handler_idle_timeout :: proc(ctx: ^Context) -> time.Duration {
	opts := context_options(ctx)
	opt := option_manager_get_checked(opts, "idle_timeout")
	return time.Duration(opt.value.(int)) * time.Millisecond
}

// input_handler_fs_check_timeout reads the fs_check_timeout option.
input_handler_fs_check_timeout :: proc(ctx: ^Context) -> time.Duration {
	opts := context_options(ctx)
	opt := option_manager_get_checked(opts, "fs_check_timeout")
	return time.Duration(opt.value.(int)) * time.Millisecond
}

// REPORT(KNOTFIX): knot.odin's Option_Value union has no Auto_Info or
// Auto_Complete variants even though autoinfo/autocomplete are
// declare_option instantiations, and the fixed Option struct cannot be
// extended locally. The helpers below read them as the int bitmask the
// option module must store (C++ bit values match the Odin flag order).
input_handler_option_auto_info :: proc(opt: ^Option) -> Auto_Info {
	return transmute(Auto_Info)u8(opt.value.(int))
}

input_handler_option_auto_complete :: proc(opt: ^Option) -> Auto_Complete {
	return transmute(Auto_Complete)u8(opt.value.(int))
}

// input_handler_guard_counts holds the reentrancy guard count per
// mode (the Odin half of the C++ RefPtr keep_alive: a mode popped
// while guarded is destroyed when its last guard releases).
input_handler_guard_counts: map[^Input_Mode]int

input_handler_mode_guard :: proc(mode: ^Input_Mode) {
	if input_handler_guard_counts == nil {
		input_handler_guard_counts = make(map[^Input_Mode]int, context.allocator)
	}
	input_handler_guard_counts[mode] = input_handler_guard_counts[mode] + 1
}

// input_handler_mode_release drops one guard; a guarded mode that left
// the stack is destroyed here.
input_handler_mode_release :: proc(h: ^Input_Handler, mode: ^Input_Mode) {
	count := input_handler_guard_counts[mode] - 1
	assert(count >= 0)
	if count == 0 {
		delete_key(&input_handler_guard_counts, mode)
		if len(input_handler_guard_counts) == 0 {
			delete(input_handler_guard_counts)
			input_handler_guard_counts = nil
		}
		on_stack := false
		for stacked in h.mode_stack {
			if stacked == mode {
				on_stack = true
				break
			}
		}
		if !on_stack {
			input_handler_destroy_mode(h, mode)
			return
		}
	} else {
		input_handler_guard_counts[mode] = count
	}
}

input_handler_mode_guarded :: proc(mode: ^Input_Mode) -> bool {
	return input_handler_guard_counts[mode] > 0
}

// input_handler_mode_enabled reports whether mode is the current mode.
input_handler_mode_enabled :: proc(h: ^Input_Handler, mode: ^Input_Mode) -> bool {
	return len(h.mode_stack) != 0 && h.mode_stack[len(h.mode_stack) - 1] == mode
}

// input_handler_destroy_mode runs the vtable destroy and frees the wrapper.
input_handler_destroy_mode :: proc(h: ^Input_Handler, mode: ^Input_Mode) {
	assert(!input_handler_mode_guarded(mode))
	mode.vtable.destroy(mode.data, h.allocator)
	free(mode, h.allocator)
}

// input_handler_Timer_Kind identifies which mode callback a timer fires.
input_handler_Timer_Kind :: enum {
	Normal_Idle,
	Normal_Fs_Check,
	Prompt_Idle,
	Insert_Idle,
	Next_Key_Idle,
}

// input_handler_Timer is a heap timer whose callback recovers the
// owner: the Event_Manager_Timer must stay the first field so the
// fired callback can cast back from the timer pointer.
input_handler_Timer :: struct {
	timer: Event_Manager_Timer,
	mode:  ^Input_Mode,
	kind:  input_handler_Timer_Kind,
	idle:  Input_Handler_Idle_Callback,
}

input_handler_timer_make :: proc(mode: ^Input_Mode, kind: input_handler_Timer_Kind, date: Clock_Time, armed: bool, allocator := context.allocator) -> ^input_handler_Timer {
	t := new(input_handler_Timer, allocator)
	t.mode = mode
	t.kind = kind
	callback: Event_Manager_Timer_Callback = input_handler_timer_fired if armed else nil
	event_manager_timer_init(&t.timer, date, callback)
	return t
}

input_handler_timer_destroy :: proc(t: ^input_handler_Timer, allocator := context.allocator) {
	event_manager_timer_destroy(&t.timer)
	if t.kind == .Next_Key_Idle && t.idle.destroy != nil {
		t.idle.destroy(t.idle.data, allocator)
	}
	free(t, allocator)
}

input_handler_timer_fired :: proc(timer: ^Event_Manager_Timer) {
	owned := cast(^input_handler_Timer)(cast(rawptr)(timer))
	h := owned.mode.input_handler
	input_handler_mode_guard(owned.mode)
	defer input_handler_mode_release(h, owned.mode)
	switch owned.kind {
	case .Normal_Idle:
		input_handler_normal_idle(owned.mode)
	case .Normal_Fs_Check:
		input_handler_normal_fs_check(owned.mode, timer)
	case .Prompt_Idle:
		input_handler_prompt_idle(owned.mode)
	case .Insert_Idle:
		input_handler_insert_idle(owned.mode)
	case .Next_Key_Idle:
		owned.idle.call(owned.idle.data, timer)
	}
}

// input_handler_Mouse_Handler is the C++ MouseHandler: selection by
// mouse drag and window scroll. dragging holds the in-progress
// selection edition while the button is down.
input_handler_Mouse_Handler :: struct {
	dragging: Maybe(Scoped_Selection_Edition),
	anchor:   Coord_Buffer,
}

input_handler_mouse_destroy :: proc(m: ^input_handler_Mouse_Handler) {
	if _, ok := m.dragging.?; ok {
		scoped_selection_edition_destroy(&m.dragging.?)
		m.dragging = nil
	}
}

input_handler_mouse_handle_key :: proc(m: ^input_handler_Mouse_Handler, key: Keys_Key, ctx: ^Context) -> bool {
	if ctx.window == nil {
		return false
	}
	buffer := context_selections(ctx).buffer
	// Bits above the mask potentially store additional information.
	mask := Keys_Modifiers(0x7FF)
	ignored := keys_MOD_CONTROL | keys_MOD_ALT | keys_MOD_SHIFT | keys_MOD_MOUSE_BUTTON_MASK | ~mask
	switch Keys_Modifiers(i32(key.modifiers) & ~i32(ignored)) {
	case keys_MOD_MOUSE_PRESS:
		switch keys_mouse_button(key) {
		case .Right:
			input_handler_mouse_destroy(m)
			coord := keys_coord(key)
			cursor, ok := window_buffer_coord(ctx.window, Coord_Display{Coord_Line(coord.line), Coord_Column(coord.column)})
			if !ok {
				ctx.ensure_cursor_visible = false
				return true
			}
			ed := scoped_selection_edition_make(ctx)
			defer scoped_selection_edition_destroy(&ed)
			sels := context_selections(ctx)
			if (key.modifiers & keys_MOD_CONTROL) != keys_MOD_NONE {
				anchor := sels.selections[0].anchor
				list := make([dynamic]Selection, 1, ctx.allocator)
				list[0] = Selection{basic = Basic_Selection{anchor = anchor, cursor = coord_buffer_and_target(cursor)}}
				selection_list_set(sels, list[:], 0)
			} else {
				sels.selections[sels.main].cursor = coord_buffer_and_target(cursor)
			}
			selection_list_sort_and_merge_overlapping(sels)
			return true
		case .Left:
			input_handler_mouse_destroy(m)
			ed := scoped_selection_edition_make(ctx)
			m.dragging = ed
			coord := keys_coord(key)
			anchor, ok := window_buffer_coord(ctx.window, Coord_Display{Coord_Line(coord.line), Coord_Column(coord.column)})
			if !ok {
				ctx.ensure_cursor_visible = false
				return true
			}
			m.anchor = anchor
			sels := context_selections_write_only(ctx)
			if (key.modifiers & keys_MOD_CONTROL) == keys_MOD_NONE {
				old := sels^
				sels^ = selection_list_make_single(buffer, input_handler_selection_from_coord(m.anchor), buffer_timestamp(buffer), ctx.allocator)
				selection_list_destroy(&old)
			} else {
				main := len(sels.selections)
				append(&sels.selections, input_handler_selection_from_coord(m.anchor))
				sels.main = main
				selection_list_sort_and_merge_overlapping(sels)
			}
			return true
		case .Middle:
			return true
		}
	case keys_MOD_MOUSE_RELEASE:
		coord := keys_coord(key)
		cursor, ok := window_buffer_coord(ctx.window, Coord_Display{Coord_Line(coord.line), Coord_Column(coord.column)})
		if _, dragging := m.dragging.?; !dragging || !ok {
			ctx.ensure_cursor_visible = false
			return true
		}
		sels := context_selections(ctx)
		sels.selections[sels.main] = Selection{basic = Basic_Selection{anchor = buffer_clamp(buffer, m.anchor), cursor = coord_buffer_and_target(cursor)}}
		selection_list_sort_and_merge_overlapping(sels)
		input_handler_mouse_destroy(m)
		return true
	case keys_MOD_MOUSE_POS:
		coord := keys_coord(key)
		cursor, ok := window_buffer_coord(ctx.window, Coord_Display{Coord_Line(coord.line), Coord_Column(coord.column)})
		if _, dragging := m.dragging.?; !dragging || !ok {
			ctx.ensure_cursor_visible = false
			return true
		}
		sels := context_selections(ctx)
		sels.selections[sels.main] = Selection{basic = Basic_Selection{anchor = buffer_clamp(buffer, m.anchor), cursor = coord_buffer_and_target(cursor)}}
		selection_list_sort_and_merge_overlapping(sels)
		return true
	case keys_MOD_SCROLL:
		on_hidden := On_Hidden_Cursor.Preserve_Selections
		if _, dragging := m.dragging.?; dragging {
			on_hidden = .Move_Cursor
		}
		input_handler_scroll_window(ctx, Units_LineCount(keys_scroll_amount(key)), on_hidden)
		return true
	case:
		return false
	}
	return false
}

// input_handler_Normal_State mirrors Normal::State.
input_handler_Normal_State :: enum {
	Normal,
	Single_Command,
	Pop_On_Enabled,
}

// input_handler_Normal is the C++ InputModes::Normal.
input_handler_Normal :: struct {
	handler:        ^Input_Handler,
	self:           ^Input_Mode,
	allocator:      mem.Allocator,
	params:         Normal_Params,
	hooks_disabled: bool,
	in_on_key:      Utils_Nested_Bool,
	idle:           ^input_handler_Timer,
	fs_check:       ^input_handler_Timer,
	mouse:          input_handler_Mouse_Handler,
	state:          input_handler_Normal_State,
}

input_handler_normal_make :: proc(h: ^Input_Handler, single_command: bool) -> ^Input_Mode {
	mode := new(Input_Mode, h.allocator)
	n := new(input_handler_Normal, h.allocator)
	n.handler = h
	n.self = mode
	n.allocator = h.allocator
	n.state = .Single_Command if single_command else .Normal
	draft := .Draft in h.ctx.flags
	n.idle = input_handler_timer_make(mode, .Normal_Idle, clock_max(), !draft, h.allocator)
	n.fs_check = input_handler_timer_make(mode, .Normal_Fs_Check, clock_max(), !draft, h.allocator)
	mode.vtable = &input_handler_normal_vtable
	mode.input_handler = h
	mode.data = n
	return mode
}

input_handler_normal_destroy :: proc(data: rawptr, allocator: mem.Allocator) {
	n := cast(^input_handler_Normal)(data)
	input_handler_timer_destroy(n.idle, allocator)
	input_handler_timer_destroy(n.fs_check, allocator)
	input_handler_mouse_destroy(&n.mouse)
	free(n, allocator)
}

input_handler_normal_idle :: proc(mode: ^Input_Mode) {
	n := cast(^input_handler_Normal)(mode.data)
	ctx := &n.handler.ctx
	if ctx.client != nil {
		client_clear_pending(ctx.client)
	}
	hooks := context_hooks(ctx)
	hook_manager_run_hook(hooks, .Normal_Idle, "", ctx)
}

input_handler_normal_fs_check :: proc(mode: ^Input_Mode, timer: ^Event_Manager_Timer) {
	n := cast(^input_handler_Normal)(mode.data)
	ctx := &n.handler.ctx
	if ctx.client != nil {
		client_check_if_buffer_needs_reloading(ctx.client)
	}
	timer.date = clock_add(clock_now(), input_handler_fs_check_timeout(ctx))
}

input_handler_normal_on_enabled :: proc(data: rawptr, from_pop: bool) {
	n := cast(^input_handler_Normal)(data)
	ctx := &n.handler.ctx
	if n.state == .Pop_On_Enabled {
		input_handler_pop_mode(n.handler, n.self)
		return
	}
	if .Draft not_in ctx.flags {
		if ctx.client != nil {
			client_check_if_buffer_needs_reloading(ctx.client)
		}
		n.fs_check.timer.date = clock_add(clock_now(), input_handler_fs_check_timeout(ctx))
		n.idle.timer.date = clock_add(clock_now(), input_handler_idle_timeout(ctx))
	}
	if n.hooks_disabled && !utils_nested_bool_is_set(n.in_on_key) {
		utils_nested_bool_unset(&ctx.hooks_disabled)
		n.hooks_disabled = false
	}
}

input_handler_normal_on_disabled :: proc(data: rawptr, from_push: bool) {
	n := cast(^input_handler_Normal)(data)
	event_manager_timer_disable(&n.idle.timer)
	event_manager_timer_disable(&n.fs_check.timer)
	if !from_push && n.hooks_disabled {
		utils_nested_bool_unset(&n.handler.ctx.hooks_disabled)
		n.hooks_disabled = false
	}
}

// input_handler_Normal_Register_Data carries the mode for the register
// selection callback.
input_handler_Normal_Register_Data :: struct {
	mode: ^Input_Mode,
}

input_handler_normal_register_call :: proc(data: rawptr, key: Keys_Key, ctx: ^Context) {
	d := cast(^input_handler_Normal_Register_Data)(data)
	n := cast(^input_handler_Normal)(d.mode.data)
	cp, ok := keys_codepoint(key)
	if !ok || input_handler_key_is(key, keys_MOD_NONE, keys_ESCAPE) {
		return
	}
	if cp <= 127 {
		n.params.reg = cp
	} else {
		cp_str := format_to_string_codepoint(cp, context.temp_allocator)
		msg, _ := format_format("invalid register '{}'", []string{cp_str}, context.temp_allocator)
		faces := context_faces(ctx)
		atom := Display_Atom{face = input_handler_face(faces, "Error"), type = .Text, text = msg}
		atoms := make([dynamic]Display_Atom, 1, context.temp_allocator)
		atoms[0] = atom
		context_print_status_simple(ctx, Display_Line{atoms = atoms})
	}
}

input_handler_normal_register_destroy :: proc(data: rawptr, allocator: mem.Allocator) {
	free(cast(^input_handler_Normal_Register_Data)(data), allocator)
}

input_handler_normal_on_key :: proc(data: rawptr, key_: Keys_Key) {
	n := cast(^input_handler_Normal)(data)
	h := n.handler
	ctx := &h.ctx
	key := key_
	should_clear := false

	assert(n.state != .Pop_On_Enabled)
	guard := utils_scoped_bool_make(&n.in_on_key)
	defer utils_scoped_bool_release(&guard)

	do_restore_hooks := false
	defer {
		if n.hooks_disabled && input_handler_mode_enabled(h, n.self) && do_restore_hooks {
			utils_nested_bool_unset(&ctx.hooks_disabled)
			n.hooks_disabled = false
		}
	}

	transient := .Draft in ctx.flags

	if input_handler_mouse_handle_key(&n.mouse, key, ctx) {
		should_clear = true
		if !transient {
			n.idle.timer.date = clock_add(clock_now(), input_handler_idle_timeout(ctx))
		}
	} else if cp, ok := keys_codepoint(key); ok && cp >= '0' && cp <= '9' {
		new_val := i64(n.params.count) * 10 + i64(cp - '0')
		if new_val > i64(max(i32)) {
			faces := context_faces(ctx)
			atom := Display_Atom{face = input_handler_face(faces, "Error"), type = .Text, text = "parameter overflowed"}
			atoms := make([dynamic]Display_Atom, 1, context.temp_allocator)
			atoms[0] = atom
			context_print_status_simple(ctx, Display_Line{atoms = atoms})
		} else {
			n.params.count = int(new_val)
		}
	} else if input_handler_key_is(key, keys_MOD_NONE, keys_BACKSPACE) {
		n.params.count /= 10
	} else if input_handler_key_is(key, keys_MOD_NONE, '\\') {
		if !n.hooks_disabled {
			n.hooks_disabled = true
			utils_nested_bool_set(&ctx.hooks_disabled)
		}
	} else if input_handler_key_is(key, keys_MOD_NONE, '"') {
		reg_data := new(input_handler_Normal_Register_Data, h.allocator)
		reg_data.mode = n.self
		cmd := Key_Callback{call = input_handler_normal_register_call, data = reg_data, destroy = input_handler_normal_register_destroy}
		input_handler_on_next_key_with_autoinfo(ctx, "register", .None, cmd, "enter target register", input_handler_REGISTER_DOC)
	} else {
		defer {
			if n.state == .Single_Command && input_handler_mode_enabled(h, n.self) {
				input_handler_pop_mode(h, n.self)
			} else if n.state == .Single_Command {
				n.state = .Pop_On_Enabled
			}
		}
		should_clear = true
		// Hack to parse keys sent by terminals using the 8th bit to
		// mark the meta key. In normal mode, give priority to a
		// potential alt-key than the accentuated character.
		if key.key >= 127 && key.key < 256 {
			key.modifiers |= keys_MOD_ALT
			key.key &= 0x7f
		}
		do_restore_hooks = true
		if command, found := normal_get_command(key); found {
			opts := context_options(ctx)
			autoinfo := input_handler_option_auto_info(option_manager_get_checked(opts, "autoinfo"))
			if .Normal in autoinfo && ctx.client != nil {
				key_str := keys_to_string_key(key, context.temp_allocator)
				client_info_show_string(ctx.client, key_str, command.docstring, Coord_Buffer{}, .Prompt)
			}
			// Reset params now to be reentrant.
			params := n.params
			n.params = Normal_Params{count = 0, reg = 0}
			command.func(ctx, params)
		} else {
			n.params = Normal_Params{count = 0, reg = 0}
		}
	}

	hooks := context_hooks(ctx)
	key_str := keys_to_string_key(key, context.temp_allocator)
	hook_manager_run_hook(hooks, .Normal_Key, key_str, ctx)
	if should_clear && !transient && ctx.client != nil {
		client_schedule_clear(ctx.client)
	}
	// The hook might have changed mode.
	if input_handler_mode_enabled(h, n.self) && !transient {
		n.idle.timer.date = clock_add(clock_now(), input_handler_idle_timeout(ctx))
	}
}

input_handler_normal_mode_info :: proc(data: rawptr, allocator: mem.Allocator) -> Mode_Info {
	n := cast(^input_handler_Normal)(data)
	ctx := &n.handler.ctx
	faces := context_faces(ctx)
	info_face := input_handler_face(faces, "StatusLineInfo")
	value_face := input_handler_face(faces, "StatusLineValue")
	sels := context_selections(ctx)
	hidden_count := 0
	if ctx.window != nil {
		for &sel in sels.selections {
			if _, ok := window_display_coord(ctx.window, sel.cursor.coord); !ok {
				hidden_count += 1
			}
		}
	}
	atoms := make([dynamic]Display_Atom, 0, 6, allocator)
	count_str := format_to_string_int(len(sels.selections), allocator)
	main_str := format_to_string_int(sels.main + 1, allocator)
	defer delete(count_str, allocator)
	defer delete(main_str, allocator)
	if len(sels.selections) == 1 {
		sel, _ := format_format("{} sel", []string{count_str}, allocator)
		append(&atoms, Display_Atom{face = info_face, type = .Text, text = sel})
		if hidden_count != 0 {
			append(&atoms, Display_Atom{face = info_face, type = .Text, text = strings.clone(" (hidden)", allocator)})
		}
	} else {
		hidden_str := format_to_string_int(hidden_count, allocator)
		defer delete(hidden_str, allocator)
		sel, _ := format_format("{} sels ({})", []string{count_str, main_str}, allocator)
		append(&atoms, Display_Atom{face = info_face, type = .Text, text = sel})
		if hidden_count != 0 {
			sel_hidden, _ := format_format(" ({} hidden)", []string{hidden_str}, allocator)
			append(&atoms, Display_Atom{face = info_face, type = .Text, text = sel_hidden})
		}
	}
	if n.params.count != 0 {
		param_str := format_to_string_int(n.params.count, allocator)
		append(&atoms, Display_Atom{face = info_face, type = .Text, text = strings.clone(" param=", allocator)})
		append(&atoms, Display_Atom{face = value_face, type = .Text, text = param_str})
	}
	if n.params.reg != 0 {
		reg_str := format_to_string_codepoint(n.params.reg, allocator)
		append(&atoms, Display_Atom{face = info_face, type = .Text, text = strings.clone(" reg=", allocator)})
		append(&atoms, Display_Atom{face = value_face, type = .Text, text = reg_str})
	}
	return Mode_Info{display_line = Display_Line{atoms = atoms}, normal_params = n.params}
}

input_handler_normal_paste :: proc(data: rawptr, content: string) {
	n := cast(^input_handler_Normal)(data)
	if err := input_handler_base_paste(n.handler, content); err != .None {
		input_handler_report_error(&n.handler.ctx, err)
		return
	}
	if .Draft not_in n.handler.ctx.flags {
		if n.handler.ctx.client != nil {
			client_schedule_clear(n.handler.ctx.client)
		}
		n.idle.timer.date = clock_add(clock_now(), input_handler_idle_timeout(&n.handler.ctx))
	}
}

input_handler_normal_take_pending_count :: proc(data: rawptr) -> uint {
	n := cast(^input_handler_Normal)(data)
	count := uint(max(n.params.count, 1))
	n.params.count = 0
	return count
}

input_handler_normal_keymap_mode :: proc(data: rawptr) -> Keymap_Manager_Mode {
	return .Normal
}

input_handler_normal_name :: proc(data: rawptr) -> string {
	return "normal"
}

input_handler_normal_on_raw_key :: proc(data: rawptr) {
}

input_handler_normal_refresh_ifn :: proc(data: rawptr) {
}

input_handler_normal_vtable := Input_Mode_VTable{
	on_key             = input_handler_normal_on_key,
	paste              = input_handler_normal_paste,
	on_raw_key         = input_handler_normal_on_raw_key,
	on_enabled         = input_handler_normal_on_enabled,
	on_disabled        = input_handler_normal_on_disabled,
	refresh_ifn        = input_handler_normal_refresh_ifn,
	take_pending_count = input_handler_normal_take_pending_count,
	mode_info          = input_handler_normal_mode_info,
	keymap_mode        = input_handler_normal_keymap_mode,
	name               = input_handler_normal_name,
	destroy            = input_handler_normal_destroy,
}

// input_handler_Explicit_Kind selects the prompt explicit completer.
input_handler_Explicit_Kind :: enum {
	Filename,
	Words,
}

// input_handler_Explicit_Data carries the explicit completer kind.
input_handler_Explicit_Data :: struct {
	kind: input_handler_Explicit_Kind,
}

// input_handler_Prompt is the C++ InputModes::Prompt. Owns prompt,
// prefix and empty_text; the line editor borrows empty_text; history
// is borrowed from the register manager.
input_handler_Prompt :: struct {
	handler:                    ^Input_Handler,
	self:                       ^Input_Mode,
	allocator:                  mem.Allocator,
	callback:                   Prompt_Callback,
	completer:                  Prompt_Completer,
	explicit_completer:         Prompt_Completer,
	prompt:                     string,
	prompt_face:                Face,
	completions:                Completions,
	current_completion:         int,
	prefix_in_completions:      bool,
	prefix:                     string,
	empty_text:                 string,
	line_editor:                input_handler_Line_Editor,
	line_changed:               bool,
	flags:                      Prompt_Flags,
	was_interactive:            bool,
	history:                    ^Register,
	current_history:            int,
	auto_complete:              bool,
	refresh_completion_pending: bool,
	idle:                       ^input_handler_Timer,
}

input_handler_prompt_make :: proc(h: ^Input_Handler, prompt: string, initstr, emptystr: string, face: Face, flags: Prompt_Flags, history_register: rune, completer: Prompt_Completer, callback: Prompt_Callback) -> ^Input_Mode {
	mode := new(Input_Mode, h.allocator)
	p := new(input_handler_Prompt, h.allocator)
	p.handler = h
	p.self = mode
	p.allocator = h.allocator
	p.callback = callback
	p.completer = completer
	p.prompt = strings.clone(prompt, h.allocator)
	p.prompt_face = face
	p.current_completion = -1
	p.prefix = ""
	p.empty_text = strings.clone(emptystr, h.allocator)
	// This prompt may outlive local scopes so ignore local faces.
	faces := context_faces(&h.ctx, false)
	input_handler_line_editor_init(&p.line_editor, faces, h.allocator)
	input_handler_line_editor_reset(&p.line_editor, initstr, p.empty_text)
	p.flags = flags
	p.history = register_manager_instance().registers[history_register]
	p.current_history = -1
	opts := context_options(&h.ctx)
	p.auto_complete = .Prompt in input_handler_option_auto_complete(option_manager_get_checked(opts, "autocomplete"))
	p.refresh_completion_pending = true
	draft := .Draft in h.ctx.flags
	p.idle = input_handler_timer_make(mode, .Prompt_Idle, clock_max(), !draft, h.allocator)
	mode.vtable = &input_handler_prompt_vtable
	mode.input_handler = h
	mode.data = p
	return mode
}

input_handler_prompt_completions_clear :: proc(p: ^input_handler_Prompt) {
	p.current_completion = -1
	for c in p.completions.candidates {
		delete(c, p.allocator)
	}
	clear(&p.completions.candidates)
}

input_handler_prompt_destroy :: proc(data: rawptr, allocator: mem.Allocator) {
	p := cast(^input_handler_Prompt)(data)
	input_handler_timer_destroy(p.idle, allocator)
	input_handler_line_editor_destroy(&p.line_editor)
	input_handler_prompt_completions_clear(p)
	delete(p.completions.candidates)
	delete(p.prompt, allocator)
	if len(p.prefix) != 0 {
		delete(p.prefix, allocator)
	}
	delete(p.empty_text, allocator)
	if p.callback.destroy != nil {
		p.callback.destroy(p.callback.data, allocator)
	}
	if p.completer.destroy != nil {
		p.completer.destroy(p.completer.data, allocator)
	}
	if p.explicit_completer.destroy != nil {
		p.explicit_completer.destroy(p.explicit_completer.data, allocator)
	}
	free(p, allocator)
}

input_handler_prompt_idle :: proc(mode: ^Input_Mode) {
	p := cast(^input_handler_Prompt)(mode.data)
	ctx := &p.handler.ctx
	if p.auto_complete && p.refresh_completion_pending {
		input_handler_prompt_refresh_completions(p)
	}
	if p.line_changed {
		p.callback.call(p.callback.data, p.line_editor.line, .Change, ctx)
		p.line_changed = false
	}
	hooks := context_hooks(ctx)
	hook_manager_run_hook(hooks, .Prompt_Idle, "", ctx)
}

// input_handler_prompt_can_auto_insert_completion mirrors the Prompt
// on_key closure of the same name.
input_handler_prompt_can_auto_insert_completion :: proc(p: ^input_handler_Prompt) -> bool {
	line := p.line_editor.line
	cursor_byte := input_handler_char_to_byte(line, p.line_editor.cursor_pos)
	has_completions := len(p.completions.candidates) != 0
	completion_selected := p.current_completion != -1
	text_entered := p.completions.start != Units_ByteCount(cursor_byte)
	at_end := cursor_byte == len(line)
	return .Menu in p.completions.flags &&
		has_completions &&
		!completion_selected && at_end &&
		(!(.No_Empty in p.completions.flags) || text_entered)
}

input_handler_prompt_history_push :: proc(p: ^input_handler_Prompt, entry: string) {
	if len(entry) == 0 || !p.was_interactive ||
	   (.Drop_History_Entries_With_Blank_Prefix in p.flags &&
	    string_utils_is_horizontal_blank(rune(entry[0]))) {
		return
	}
	p.history.vtable.set(p.history.data, &p.handler.ctx, []string{entry}, false)
}

input_handler_prompt_display :: proc(p: ^input_handler_Prompt) {
	ctx := &p.handler.ctx
	if ctx.client == nil {
		return
	}
	width := int(client_dimensions(ctx.client).column) - string_utils_column_length(p.prompt)
	content := Display_Line{}
	if .Password not_in p.flags {
		content = input_handler_line_editor_build_display_line(&p.line_editor, width, p.allocator)
	}
	prompt_atoms := make([dynamic]Display_Atom, 1, p.allocator)
	prompt_atoms[0] = Display_Atom{face = p.prompt_face, type = .Text, text = p.prompt}
	prompt_line := Display_Line{atoms = prompt_atoms}
	status_style := User_Interface_Status_Style.Prompt
	if .Search in p.flags {
		status_style = .Search
	} else if .Command in p.flags {
		status_style = .Command
	}
	context_print_status(ctx, prompt_line, content, input_handler_line_editor_cursor_display_column(&p.line_editor), status_style)
	delete(prompt_atoms)
	for a in content.atoms {
		delete(a.text, p.allocator)
	}
	delete(content.atoms)
}

input_handler_prompt_show_completions :: proc(p: ^input_handler_Prompt) {
	ctx := &p.handler.ctx
	items := make([dynamic]Display_Line, 0, len(p.completions.candidates), p.allocator)
	for candidate in p.completions.candidates {
		atoms := make([dynamic]Display_Atom, 1, p.allocator)
		atoms[0] = Display_Atom{type = .Text, text = strings.clone(candidate, p.allocator)}
		append(&items, Display_Line{atoms = atoms})
	}
	menu_style := User_Interface_Menu_Style.Prompt
	if .Search in p.flags {
		menu_style = .Search
	}
	// Ownership of items transfers to the client.
	client_menu_show(ctx.client, items, Coord_Buffer{}, menu_style)
}

input_handler_prompt_refresh_completions :: proc(p: ^input_handler_Prompt) {
	// Deviation: the C++ catches runtime_error from the completer;
	// Odin completers return values, so there is nothing to catch.
	p.refresh_completion_pending = false
	completer := p.completer
	if p.explicit_completer.call != nil {
		completer = p.explicit_completer
	}
	if completer.call == nil {
		return
	}
	p.current_completion = -1
	line := p.line_editor.line
	input_handler_prompt_completions_clear(p)
	p.completions = completer.call(completer.data, &p.handler.ctx, line, Units_ByteCount(input_handler_char_to_byte(line, p.line_editor.cursor_pos)), p.allocator)
	ctx := &p.handler.ctx
	if ctx.client == nil {
		return
	}
	if len(p.completions.candidates) == 0 {
		client_menu_hide(ctx.client)
		return
	}
	input_handler_prompt_show_completions(p)
	if .Menu in p.completions.flags {
		client_menu_select(ctx.client, 0)
	}
	prefix := line[int(p.completions.start):int(p.completions.end)]
	p.prefix_in_completions = .Menu not_in p.completions.flags && !ranges_contains(p.completions.candidates[:], prefix)
	if p.prefix_in_completions {
		p.current_completion = len(p.completions.candidates)
		append(&p.completions.candidates, strings.clone(prefix, p.allocator))
	}
}

// input_handler_Prompt_Key_Data carries the mode for prompt nested-key
// callbacks.
input_handler_Prompt_Key_Data :: struct {
	mode: ^Input_Mode,
}

input_handler_prompt_key_destroy :: proc(data: rawptr, allocator: mem.Allocator) {
	free(cast(^input_handler_Prompt_Key_Data)(data), allocator)
}

input_handler_prompt_register_call :: proc(data: rawptr, key_: Keys_Key, ctx: ^Context) {
	d := cast(^input_handler_Prompt_Key_Data)(data)
	p := cast(^input_handler_Prompt)(d.mode.data)
	key := key_
	joined := (key.modifiers & keys_MOD_ALT) != keys_MOD_NONE
	quoted := (key.modifiers & keys_MOD_CONTROL) != keys_MOD_NONE
	key.modifiers = Keys_Modifiers(i32(key.modifiers) & ~i32(keys_MOD_ALT | keys_MOD_CONTROL))
	cp, ok := keys_codepoint(key)
	if !ok || input_handler_key_is(key, keys_MOD_NONE, keys_ESCAPE) {
		return
	}
	quoting := String_Utils_Quoting.Raw
	if quoted {
		quoting = .Kakoune
	}
	quoter := string_utils_quoter(quoting)
	if joined {
		reg := register_manager_instance().registers[cp]
		values := reg.vtable.get(reg.data, ctx, context.temp_allocator)
		quoted_values := make([dynamic]string, 0, len(values), context.temp_allocator)
		for v in values {
			append(&quoted_values, quoter(v, context.temp_allocator))
		}
		input_handler_line_editor_insert(&p.line_editor, string_utils_join_str(quoted_values[:], " ", context.temp_allocator))
	} else {
		reg_str := format_to_string_codepoint(cp, context.temp_allocator)
		reg_val, reg_err := context_main_sel_register_value(ctx, reg_str)
		if reg_err == .None {
			input_handler_line_editor_insert(&p.line_editor, quoter(reg_val, context.temp_allocator))
		} else if context_has_client(ctx) {
			// C++ throws to the key-handling boundary, which reports the
			// failure; here the status line is updated directly. The text
			// is borrowed by the stored line (client convention).
			c := context_client(ctx)
			faces := context_faces(ctx)
			err_face, face_err := face_registry_lookup(faces, "Error", c.allocator)
			assert(face_err == .None)
			msg_parts := [3]string{"no such register: '", reg_str, "'"}
			err_line := display_buffer_line_make_text(
				strings.concatenate(msg_parts[:], c.allocator),
				err_face,
				c.allocator,
			)
			context_print_status_simple(ctx, err_line)
			return
		}
	}
	input_handler_prompt_display(p)
	p.line_changed = true
	p.refresh_completion_pending = true
}

input_handler_prompt_raw_call :: proc(data: rawptr, key: Keys_Key, ctx: ^Context) {
	d := cast(^input_handler_Prompt_Key_Data)(data)
	p := cast(^input_handler_Prompt)(d.mode.data)
	if cp, ok := input_handler_get_raw_codepoint(key); ok {
		input_handler_line_editor_insert_codepoint(&p.line_editor, cp)
		input_handler_prompt_display(p)
		p.line_changed = true
		p.refresh_completion_pending = true
	}
}

input_handler_prompt_explicit_type_call :: proc(data: rawptr, key: Keys_Key, ctx: ^Context) {
	d := cast(^input_handler_Prompt_Key_Data)(data)
	p := cast(^input_handler_Prompt)(d.mode.data)
	p.explicit_completer = Prompt_Completer{}
	if key.key == 'f' {
		input_handler_prompt_use_explicit_completer(p, .Filename)
	} else if key.key == 'w' {
		input_handler_prompt_use_explicit_completer(p, .Words)
	}
	if p.explicit_completer.call != nil {
		input_handler_prompt_refresh_completions(p)
	}
}

input_handler_prompt_use_explicit_completer :: proc(p: ^input_handler_Prompt, kind: input_handler_Explicit_Kind) {
	if p.explicit_completer.destroy != nil {
		p.explicit_completer.destroy(p.explicit_completer.data, p.allocator)
	}
	data := new(input_handler_Explicit_Data, p.allocator)
	data.kind = kind
	p.explicit_completer = Prompt_Completer{call = input_handler_prompt_explicit_complete, data = data, destroy = input_handler_prompt_explicit_destroy}
}

input_handler_prompt_explicit_destroy :: proc(data: rawptr, allocator: mem.Allocator) {
	free(cast(^input_handler_Explicit_Data)(data), allocator)
}

input_handler_prompt_explicit_complete :: proc(data: rawptr, ctx: ^Context, content: string, cursor_pos: Units_ByteCount, allocator: mem.Allocator) -> Completions {
	d := cast(^input_handler_Explicit_Data)(data)
	parser := command_parser_make(content[:int(cursor_pos)])
	has_last := false
	last: Token
	for {
		tok, ok := command_parser_read_token(&parser, false, allocator)
		if !ok {
			break
		}
		if has_last {
			delete(last.content, allocator)
		}
		last = tok
		has_last = true
	}
	if has_last && last.pos + Units_ByteCount(len(last.content)) < cursor_pos {
		delete(last.content, allocator)
		has_last = false
	}
	token_start := cursor_pos
	token_content := ""
	if has_last {
		token_start = last.pos
		token_content = last.content
	}
	candidates: Candidate_List
	switch d.kind {
	case .Filename:
		opts := context_options(ctx)
		ignore := option_manager_get_checked(opts, "ignored_files").value.(Regex)
		candidates = completion_complete_filename(token_content, &ignore, Units_ByteCount(len(token_content)), Filename_Flags{.Expand}, allocator)
	case .Words:
		buffer := context_selections(ctx).buffer
		db := word_db_get(buffer)
		matches := word_db_find_matching(db, token_content, allocator)
		defer delete(matches)
		// Select up to 100 best matches (mirrors for_n_best with a
		// flipped less: ranges_for_n_best cannot take a capturing
		// append closure, so the selection is an explicit loop).
		candidates = make(Candidate_List, 0, min(100, len(matches)), allocator)
		visited := make([dynamic]bool, len(matches), context.temp_allocator)
		for len(candidates) < 100 && len(candidates) < len(matches) {
			best := -1
			for _, i in matches {
				if visited[i] {
					continue
				}
				if best == -1 || ranked_match_less(matches[i], matches[best]) {
					best = i
				}
			}
			visited[best] = true
			append(&candidates, strings.clone(matches[best].candidate, allocator))
		}
	}
	if has_last {
		delete(last.content, allocator)
	}
	return Completions{candidates = candidates, start = token_start, end = cursor_pos}
}

input_handler_prompt_navigate_history :: proc(p: ^input_handler_Prompt, up: bool) {
	history := p.history.vtable.get(p.history.data, &p.handler.ctx, p.allocator)
	line := p.line_editor.line
	p.current_history = min(len(history) - 1, p.current_history)
	if up {
		if p.current_history == -1 {
			if len(p.prefix) != 0 {
				delete(p.prefix, p.allocator)
			}
			p.prefix = strings.clone(line, p.allocator)
		}
		for i := p.current_history + 1; i < len(history); i += 1 {
			if string_utils_prefix_match(history[i], p.prefix) {
				p.current_history = i
				input_handler_line_editor_reset(&p.line_editor, history[i], p.empty_text)
				break
			}
		}
	} else if p.current_history >= 0 {
		found := -1
		for i := p.current_history - 1; i >= 0; i -= 1 {
			if string_utils_prefix_match(history[i], p.prefix) {
				found = i
				break
			}
		}
		p.current_history = found
		input_handler_line_editor_reset(&p.line_editor, history[found] if found != -1 else p.prefix, p.empty_text)
	}
	input_handler_prompt_completions_clear(p)
	p.refresh_completion_pending = true
}

input_handler_prompt_complete :: proc(p: ^input_handler_Prompt, key: Keys_Key) {
	line := p.line_editor.line
	candidates := &p.completions.candidates
	if p.auto_complete && p.refresh_completion_pending {
		input_handler_prompt_refresh_completions(p)
	}
	if len(candidates) == 0 {
		input_handler_prompt_refresh_completions(p)
		if (!p.prefix_in_completions && len(candidates) > 1) || len(candidates) > 2 {
			return
		}
	}
	if len(candidates) == 0 {
		return
	}
	reverse := input_handler_key_is(key, keys_MOD_SHIFT, keys_TAB)
	if key.modifiers == keys_MOD_MENU_SELECT {
		p.current_completion = clamp(int(key.key), 0, len(candidates) - 1)
	} else if !reverse {
		p.current_completion += 1
		if p.current_completion >= len(candidates) {
			p.current_completion = 0
		}
	} else {
		p.current_completion -= 1
		if p.current_completion < 0 {
			p.current_completion = len(candidates) - 1
		}
	}
	completion := candidates[p.current_completion]
	if p.handler.ctx.client != nil {
		client_menu_select(p.handler.ctx.client, p.current_completion)
	}
	input_handler_line_editor_insert_from(&p.line_editor, input_handler_byte_to_char(line, int(p.completions.start)), completion)
	// When we have only one completion candidate, make next tab
	// complete from the new content.
	if len(candidates) == 1 || (p.prefix_in_completions && len(candidates) == 2) {
		p.current_completion = -1
		for c in candidates {
			delete(c, p.allocator)
		}
		clear(candidates)
		p.refresh_completion_pending = true
	}
}

input_handler_prompt_on_key :: proc(data: rawptr, key: Keys_Key) {
	p := cast(^input_handler_Prompt)(data)
	h := p.handler
	ctx := &h.ctx
	line := p.line_editor.line

	if input_handler_key_is(key, keys_MOD_NONE, keys_RETURN) {
		if input_handler_prompt_can_auto_insert_completion(p) {
			completion := p.completions.candidates[0]
			input_handler_line_editor_insert_from(&p.line_editor, input_handler_byte_to_char(line, int(p.completions.start)), completion)
			line = p.line_editor.line
		}
		input_handler_prompt_history_push(p, line)
		context_print_status_simple(ctx, Display_Line{})
		if ctx.client != nil {
			client_menu_hide(ctx.client)
		}
		// Maintain hooks disabled in callback if they were before pop_mode.
		guard := utils_scoped_bool_make(&ctx.hooks_disabled, utils_nested_bool_is_set(ctx.hooks_disabled))
		defer utils_scoped_bool_release(&guard)
		input_handler_pop_mode(h, p.self)
		// Call callback after pop_mode so that callback may change
		// the mode.
		p.callback.call(p.callback.data, line, .Validate, ctx)
		return
	} else if input_handler_key_is(key, keys_MOD_NONE, keys_ESCAPE) ||
	   input_handler_key_is(key, keys_MOD_CONTROL, 'c') ||
	   ((input_handler_key_is(key, keys_MOD_NONE, keys_BACKSPACE) ||
	     input_handler_key_is(key, keys_MOD_SHIFT, keys_BACKSPACE) ||
	     input_handler_key_is(key, keys_MOD_CONTROL, 'h')) && len(line) == 0) {
		input_handler_prompt_history_push(p, line)
		context_print_status_simple(ctx, Display_Line{})
		if ctx.client != nil {
			client_menu_hide(ctx.client)
		}
		guard := utils_scoped_bool_make(&ctx.hooks_disabled, utils_nested_bool_is_set(ctx.hooks_disabled))
		defer utils_scoped_bool_release(&guard)
		input_handler_pop_mode(h, p.self)
		p.callback.call(p.callback.data, line, .Abort, ctx)
		return
	} else if input_handler_key_is(key, keys_MOD_CONTROL, 'r') {
		key_data := new(input_handler_Prompt_Key_Data, h.allocator)
		key_data.mode = p.self
		cmd := Key_Callback{call = input_handler_prompt_register_call, data = key_data, destroy = input_handler_prompt_key_destroy}
		input_handler_on_next_key_with_autoinfo(ctx, "register", .None, cmd, "enter register name", input_handler_REGISTER_DOC)
		input_handler_prompt_display(p)
		return
	} else if input_handler_key_is(key, keys_MOD_CONTROL, 'v') {
		key_data := new(input_handler_Prompt_Key_Data, h.allocator)
		key_data.mode = p.self
		cmd := Key_Callback{call = input_handler_prompt_raw_call, data = key_data, destroy = input_handler_prompt_key_destroy}
		input_handler_on_next_key_with_autoinfo(ctx, "raw-key", .None, cmd, "raw insert", "enter key to insert")
		input_handler_prompt_display(p)
		return
	} else if input_handler_key_is(key, keys_MOD_NONE, keys_UP) || input_handler_key_is(key, keys_MOD_CONTROL, 'p') {
		input_handler_prompt_navigate_history(p, true)
	} else if input_handler_key_is(key, keys_MOD_NONE, keys_DOWN) || input_handler_key_is(key, keys_MOD_CONTROL, 'n') {
		input_handler_prompt_navigate_history(p, false)
	} else if input_handler_key_is(key, keys_MOD_NONE, keys_TAB) ||
	   input_handler_key_is(key, keys_MOD_SHIFT, keys_TAB) ||
	   key.modifiers == keys_MOD_MENU_SELECT {
		input_handler_prompt_complete(p, key)
	} else if input_handler_key_is(key, keys_MOD_CONTROL, 'x') {
		key_data := new(input_handler_Prompt_Key_Data, h.allocator)
		key_data.mode = p.self
		cmd := Key_Callback{call = input_handler_prompt_explicit_type_call, data = key_data, destroy = input_handler_prompt_key_destroy}
		input_handler_on_next_key_with_autoinfo(ctx, "explicit-completion", .None, cmd, "enter completion type", "f: filename\nw: buffer word\n")
	} else if input_handler_key_is(key, keys_MOD_CONTROL, 'o') {
		if p.explicit_completer.destroy != nil {
			p.explicit_completer.destroy(p.explicit_completer.data, p.allocator)
		}
		p.explicit_completer = Prompt_Completer{}
		p.auto_complete = !p.auto_complete
		if p.auto_complete {
			input_handler_prompt_refresh_completions(p)
		} else if ctx.client != nil {
			input_handler_prompt_completions_clear(p)
			client_menu_hide(ctx.client)
		}
	} else if input_handler_key_is(key, keys_MOD_ALT, '!') {
		shell_ctx := Shell_Context{}
		expanded, expand_err, expand_msg := command_manager_expand(line, ctx, &shell_ctx, context.temp_allocator)
		if expand_err != .None {
			faces := context_faces(ctx)
			atom := Display_Atom{face = input_handler_face(faces, "Error"), type = .Text, text = expand_msg}
			atoms := make([dynamic]Display_Atom, 1, context.temp_allocator)
			atoms[0] = atom
			context_print_status_simple(ctx, Display_Line{atoms = atoms})
			return
		}
		input_handler_line_editor_reset(&p.line_editor, expanded, p.empty_text)
	} else if input_handler_key_is(key, keys_MOD_ALT, ';') {
		input_handler_push_mode(h, input_handler_normal_make(h, true))
		return
	} else {
		if (input_handler_key_is(key, keys_MOD_NONE, keys_SPACE) || input_handler_key_is(key, keys_MOD_SHIFT, keys_SPACE)) &&
		   .Quoted not_in p.completions.flags &&
		   input_handler_prompt_can_auto_insert_completion(p) {
			input_handler_line_editor_insert_from(&p.line_editor, input_handler_byte_to_char(line, int(p.completions.start)), p.completions.candidates[0])
		}
		input_handler_line_editor_handle_key(&p.line_editor, key)
		input_handler_prompt_completions_clear(p)
		p.refresh_completion_pending = true
	}

	input_handler_prompt_display(p)
	p.line_changed = true
	// The callback might have disabled us.
	if input_handler_mode_enabled(h, p.self) && .Draft not_in ctx.flags {
		p.idle.timer.date = clock_add(clock_now(), input_handler_idle_timeout(ctx))
	}
}

input_handler_prompt_on_raw_key :: proc(data: rawptr) {
	p := cast(^input_handler_Prompt)(data)
	p.was_interactive = true
}

input_handler_prompt_refresh_ifn :: proc(data: rawptr) {
	p := cast(^input_handler_Prompt)(data)
	explicit_selected := p.current_completion != -1 &&
		(!p.prefix_in_completions || p.current_completion != len(p.completions.candidates) - 1)
	if !input_handler_mode_enabled(p.handler, p.self) || .Draft in p.handler.ctx.flags || explicit_selected {
		return
	}
	if next_date := clock_add(clock_now(), input_handler_idle_timeout(&p.handler.ctx)); next_date < p.idle.timer.date {
		p.idle.timer.date = next_date
	}
	p.refresh_completion_pending = true
}

input_handler_prompt_paste :: proc(data: rawptr, content: string) {
	p := cast(^input_handler_Prompt)(data)
	input_handler_line_editor_insert(&p.line_editor, content)
	input_handler_prompt_completions_clear(p)
	p.refresh_completion_pending = true
	input_handler_prompt_display(p)
	p.line_changed = true
	if .Draft not_in p.handler.ctx.flags {
		p.idle.timer.date = clock_add(clock_now(), input_handler_idle_timeout(&p.handler.ctx))
	}
}

input_handler_prompt_set_face :: proc(p: ^input_handler_Prompt, face: Face) {
	if face != p.prompt_face {
		p.prompt_face = face
		input_handler_prompt_display(p)
	}
}

input_handler_prompt_on_enabled :: proc(data: rawptr, from_pop: bool) {
	p := cast(^input_handler_Prompt)(data)
	input_handler_prompt_display(p)
	if from_pop {
		if p.handler.ctx.client != nil && len(p.completions.candidates) != 0 {
			input_handler_prompt_show_completions(p)
			if p.current_completion != -1 {
				client_menu_select(p.handler.ctx.client, p.current_completion)
			} else if .Menu in p.completions.flags {
				client_menu_select(p.handler.ctx.client, 0)
			}
		}
	}
	if .Draft not_in p.handler.ctx.flags {
		p.idle.timer.date = clock_add(clock_now(), input_handler_idle_timeout(&p.handler.ctx))
	}
}

input_handler_prompt_on_disabled :: proc(data: rawptr, from_push: bool) {
	p := cast(^input_handler_Prompt)(data)
	if !from_push {
		context_print_status_simple(&p.handler.ctx, Display_Line{})
	}
	event_manager_timer_disable(&p.idle.timer)
	if p.handler.ctx.client != nil {
		client_menu_hide(p.handler.ctx.client)
	}
}

input_handler_prompt_mode_info :: proc(data: rawptr, allocator: mem.Allocator) -> Mode_Info {
	p := cast(^input_handler_Prompt)(data)
	faces := context_faces(&p.handler.ctx)
	atoms := make([dynamic]Display_Atom, 1, allocator)
	atoms[0] = Display_Atom{face = input_handler_face(faces, "StatusLineMode"), type = .Text, text = strings.clone("prompt", allocator)}
	return Mode_Info{display_line = Display_Line{atoms = atoms}}
}

input_handler_prompt_keymap_mode :: proc(data: rawptr) -> Keymap_Manager_Mode {
	return .Prompt
}

input_handler_prompt_name :: proc(data: rawptr) -> string {
	return "prompt"
}

input_handler_prompt_take_pending_count :: proc(data: rawptr) -> uint {
	return 1
}

input_handler_prompt_vtable := Input_Mode_VTable{
	on_key             = input_handler_prompt_on_key,
	paste              = input_handler_prompt_paste,
	on_raw_key         = input_handler_prompt_on_raw_key,
	on_enabled         = input_handler_prompt_on_enabled,
	on_disabled        = input_handler_prompt_on_disabled,
	refresh_ifn        = input_handler_prompt_refresh_ifn,
	take_pending_count = input_handler_prompt_take_pending_count,
	mode_info          = input_handler_prompt_mode_info,
	keymap_mode        = input_handler_prompt_keymap_mode,
	name               = input_handler_prompt_name,
	destroy            = input_handler_prompt_destroy,
}

// input_handler_Next_Key is the C++ InputModes::NextKey. Owns name;
// the idle callback is owned by the timer.
input_handler_Next_Key :: struct {
	handler:    ^Input_Handler,
	self:       ^Input_Mode,
	allocator:  mem.Allocator,
	name:       string,
	callback:   Key_Callback,
	keymap:     Keymap_Manager_Mode,
	idle:       ^input_handler_Timer,
}

input_handler_next_key_make :: proc(h: ^Input_Handler, name: string, keymap_mode: Keymap_Manager_Mode, callback: Key_Callback, idle: Input_Handler_Idle_Callback) -> ^Input_Mode {
	mode := new(Input_Mode, h.allocator)
	n := new(input_handler_Next_Key, h.allocator)
	n.handler = h
	n.self = mode
	n.allocator = h.allocator
	n.name = strings.clone(name, h.allocator)
	n.callback = callback
	n.keymap = keymap_mode
	n.idle = input_handler_timer_make(mode, .Next_Key_Idle, clock_add(clock_now(), input_handler_idle_timeout(&h.ctx)), idle.call != nil, h.allocator)
	n.idle.idle = idle
	mode.vtable = &input_handler_next_key_vtable
	mode.input_handler = h
	mode.data = n
	return mode
}

input_handler_next_key_destroy :: proc(data: rawptr, allocator: mem.Allocator) {
	n := cast(^input_handler_Next_Key)(data)
	input_handler_timer_destroy(n.idle, allocator)
	delete(n.name, allocator)
	if n.callback.destroy != nil {
		n.callback.destroy(n.callback.data, allocator)
	}
	free(n, allocator)
}

input_handler_next_key_on_key :: proc(data: rawptr, key: Keys_Key) {
	n := cast(^input_handler_Next_Key)(data)
	ctx := &n.handler.ctx
	// Maintain hooks disabled in the callback if they were before pop_mode.
	guard := utils_scoped_bool_make(&ctx.hooks_disabled, utils_nested_bool_is_set(ctx.hooks_disabled))
	defer utils_scoped_bool_release(&guard)
	input_handler_pop_mode(n.handler, n.self)
	n.callback.call(n.callback.data, key, ctx)
}

input_handler_next_key_mode_info :: proc(data: rawptr, allocator: mem.Allocator) -> Mode_Info {
	n := cast(^input_handler_Next_Key)(data)
	faces := context_faces(&n.handler.ctx)
	atoms := make([dynamic]Display_Atom, 1, allocator)
	atoms[0] = Display_Atom{face = input_handler_face(faces, "StatusLineMode"), type = .Text, text = strings.clone("enter key", allocator)}
	return Mode_Info{display_line = Display_Line{atoms = atoms}}
}

input_handler_next_key_keymap_mode :: proc(data: rawptr) -> Keymap_Manager_Mode {
	n := cast(^input_handler_Next_Key)(data)
	return n.keymap
}

input_handler_next_key_name :: proc(data: rawptr) -> string {
	n := cast(^input_handler_Next_Key)(data)
	return n.name
}

input_handler_next_key_on_raw_key :: proc(data: rawptr) {
}

input_handler_next_key_on_enabled :: proc(data: rawptr, from_pop: bool) {
}

input_handler_next_key_on_disabled :: proc(data: rawptr, from_push: bool) {
	n := cast(^input_handler_Next_Key)(data)
	event_manager_timer_disable(&n.idle.timer)
}

input_handler_next_key_refresh_ifn :: proc(data: rawptr) {
}

input_handler_next_key_take_pending_count :: proc(data: rawptr) -> uint {
	return 1
}

input_handler_next_key_vtable := Input_Mode_VTable{
	on_key             = input_handler_next_key_on_key,
	paste              = input_handler_next_key_paste,
	on_raw_key         = input_handler_next_key_on_raw_key,
	on_enabled         = input_handler_next_key_on_enabled,
	on_disabled        = input_handler_next_key_on_disabled,
	refresh_ifn        = input_handler_next_key_refresh_ifn,
	take_pending_count = input_handler_next_key_take_pending_count,
	mode_info          = input_handler_next_key_mode_info,
	keymap_mode        = input_handler_next_key_keymap_mode,
	name               = input_handler_next_key_name,
	destroy            = input_handler_next_key_destroy,
}

input_handler_next_key_paste :: proc(data: rawptr, content: string) {
	n := cast(^input_handler_Next_Key)(data)
	if err := input_handler_base_paste(n.handler, content); err != .None {
		input_handler_report_error(&n.handler.ctx, err)
		return
	}
}

// input_handler_Insert is the C++ InputModes::Insert. last_insert is
// borrowed (nil when repeating or nested).
input_handler_Insert :: struct {
	handler:          ^Input_Handler,
	self:             ^Input_Mode,
	allocator:        mem.Allocator,
	edition:          Scoped_Edition,
	selection_edition: Scoped_Selection_Edition,
	completer:        Insert_Completer,
	last_insert:      ^Input_Handler_Insertion,
	restore_cursor:   bool,
	auto_complete:    bool,
	idle:             ^input_handler_Timer,
	mouse:            input_handler_Mouse_Handler,
	disable_hooks:    Utils_Scoped_Bool,
}

input_handler_insert_make :: proc(h: ^Input_Handler, mode: Input_Handler_Insert_Mode, count: int, last_insert: ^Input_Handler_Insertion) -> (^Input_Mode, Input_Handler_Error) {
	m := new(Input_Mode, h.allocator)
	ins := new(input_handler_Insert, h.allocator)
	ins.handler = h
	ins.self = m
	ins.allocator = h.allocator
	ins.edition = scoped_edition_make(&h.ctx)
	ins.selection_edition = scoped_selection_edition_make(&h.ctx)
	ins.completer = insert_completer_make(&h.ctx)
	ins.last_insert = last_insert
	ins.restore_cursor = mode == .Append
	opts := context_options(&h.ctx)
	ins.auto_complete = .Insert in input_handler_option_auto_complete(option_manager_get_checked(opts, "autocomplete"))
	draft := .Draft in h.ctx.flags
	ins.idle = input_handler_timer_make(m, .Insert_Idle, clock_max(), !draft, h.allocator)
	ins.disable_hooks = utils_scoped_bool_make(&h.ctx.hooks_disabled, utils_nested_bool_is_set(h.ctx.hooks_disabled))
	if last_insert != nil {
		utils_nested_bool_set(&last_insert.recording)
		last_insert.mode = mode
		clear(&last_insert.keys)
		last_insert.disable_hooks = utils_nested_bool_is_set(h.ctx.hooks_disabled)
		last_insert.count = count
	}
	if err := input_handler_insert_prepare(ins, mode, count); err != .None {
		input_handler_insert_destroy(ins, h.allocator)
		free(m, h.allocator)
		return nil, err
	}
	m.vtable = &input_handler_insert_vtable
	m.input_handler = h
	m.data = ins
	return m, .None
}

input_handler_insert_destroy :: proc(data: rawptr, allocator: mem.Allocator) {
	ins := cast(^input_handler_Insert)(data)
	input_handler_timer_destroy(ins.idle, allocator)
	input_handler_mouse_destroy(&ins.mouse)
	insert_completer_destroy(&ins.completer)
	scoped_selection_edition_destroy(&ins.selection_edition)
	scoped_edition_destroy(&ins.edition)
	utils_scoped_bool_release(&ins.disable_hooks)
	free(ins, allocator)
}

input_handler_insert_idle :: proc(mode: ^Input_Mode) {
	ins := cast(^input_handler_Insert)(mode.data)
	ctx := &ins.handler.ctx
	if ctx.client != nil {
		client_clear_pending(ctx.client)
	}
	insert_completer_update(&ins.completer, ins.auto_complete)
	hooks := context_hooks(ctx)
	hook_manager_run_hook(hooks, .Insert_Idle, "", ctx)
}

input_handler_insert_on_enabled :: proc(data: rawptr, from_pop: bool) {
	ins := cast(^input_handler_Insert)(data)
	if .Draft not_in ins.handler.ctx.flags {
		ins.idle.timer.date = clock_add(clock_now(), input_handler_idle_timeout(&ins.handler.ctx))
	}
}

input_handler_insert_on_disabled :: proc(data: rawptr, from_push: bool) {
	ins := cast(^input_handler_Insert)(data)
	event_manager_timer_disable(&ins.idle.timer)
	if !from_push {
		if ins.last_insert != nil {
			utils_nested_bool_unset(&ins.last_insert.recording)
		}
		ctx := &ins.handler.ctx
		buffer := context_selections(ctx).buffer
		sels := context_selections(ctx)
		if ins.restore_cursor {
			for &sel in sels.selections {
				origin := Coord_Buffer{}
				if coord_compare(sel.cursor.coord, sel.anchor) > 0 && coord_compare(sel.cursor.coord, origin) > 0 {
					sel.cursor = coord_buffer_and_target(buffer_char_prev(buffer, sel.cursor.coord))
				}
			}
		}
	}
}

input_handler_insert_move_chars :: proc(ins: ^input_handler_Insert, offset: int) {
	ctx := &ins.handler.ctx
	sels := context_selections(ctx)
	opts := context_options(ctx)
	tabstop := Units_ColumnCount(option_manager_get_checked(opts, "tabstop").value.(int))
	for &sel in sels.selections {
		cursor := buffer_offset_coord_char(context_selections(ctx).buffer, sel.cursor.coord, Units_CharCount(offset), tabstop)
		sel.anchor = cursor
		sel.cursor = coord_buffer_and_target(cursor)
	}
	selection_list_sort_and_merge_overlapping(sels)
}

input_handler_insert_move_lines :: proc(ins: ^input_handler_Insert, offset: int) {
	ctx := &ins.handler.ctx
	sels := context_selections(ctx)
	opts := context_options(ctx)
	tabstop := Units_ColumnCount(option_manager_get_checked(opts, "tabstop").value.(int))
	for &sel in sels.selections {
		cursor := buffer_offset_coord_line(context_selections(ctx).buffer, sel.cursor, Units_LineCount(offset), tabstop)
		sel.anchor = cursor.coord
		sel.cursor = cursor
	}
	selection_list_sort_and_merge_overlapping(sels)
}

// input_handler_Insert_Ctx carries the strings for the insert visitor.
input_handler_Insert_Ctx :: struct {
	buffer:  ^Buffer,
	strings: []string,
}

input_handler_insert_apply :: proc(ctx: rawptr, index: int, sel: ^Selection) -> Buffer_Error {
	c := cast(^input_handler_Insert_Ctx)(ctx)
	_, err := selection_insert(c.buffer, sel, sel.cursor.coord, c.strings[min(len(c.strings) - 1, index)])
	return err
}

input_handler_insert_strings :: proc(ins: ^input_handler_Insert, strings: []string) -> Input_Handler_Error {
	// Deviation: the C++ asserts no candidate is selected (debug
	// only); the check needs the completer and is release-noop.
	c := input_handler_Insert_Ctx{buffer = context_selections(&ins.handler.ctx).buffer, strings = strings}
	if err := selection_list_for_each(context_selections(&ins.handler.ctx), input_handler_insert_apply, &c, false); err != .None {
		return .Read_Only
	}
	return .None
}

input_handler_insert_codepoint :: proc(ins: ^input_handler_Insert, cp: rune) -> Input_Handler_Error {
	str := format_to_string_codepoint(cp, context.temp_allocator)
	strings_arr := [1]string{str}
	if err := input_handler_insert_strings(ins, strings_arr[:]); err != .None {
		return err
	}
	hooks := context_hooks(&ins.handler.ctx)
	hook_manager_run_hook(hooks, .Insert_Char, str, &ins.handler.ctx)
	return .None
}

// input_handler_Insert_Key_Data carries the mode (and the transient
// flag for raw insert) for insert nested-key callbacks.
input_handler_Insert_Key_Data :: struct {
	mode:      ^Input_Mode,
	transient: bool,
}

input_handler_insert_key_destroy :: proc(data: rawptr, allocator: mem.Allocator) {
	free(cast(^input_handler_Insert_Key_Data)(data), allocator)
}

input_handler_insert_register_call :: proc(data: rawptr, key: Keys_Key, ctx: ^Context) {
	d := cast(^input_handler_Insert_Key_Data)(data)
	ins := cast(^input_handler_Insert)(d.mode.data)
	cp, ok := keys_codepoint(key)
	if !ok || input_handler_key_is(key, keys_MOD_NONE, keys_ESCAPE) {
		return
	}
	reg := register_manager_instance().registers[cp]
	if err := input_handler_insert_strings(ins, reg.vtable.get(reg.data, ctx, context.temp_allocator)); err != .None {
		input_handler_report_error(ctx, err)
		return
	}
}

input_handler_insert_explicit_call :: proc(data: rawptr, key: Keys_Key, ctx: ^Context) {
	d := cast(^input_handler_Insert_Key_Data)(data)
	ins := cast(^input_handler_Insert)(d.mode.data)
	if key.key == 'f' {
		insert_completer_explicit_file_complete(&ins.completer)
	}
	if key.key == 'w' {
		insert_completer_explicit_word_buffer_complete(&ins.completer)
	}
	if key.key == 'W' {
		insert_completer_explicit_word_all_complete(&ins.completer)
	}
	if key.key == 'l' {
		insert_completer_explicit_line_buffer_complete(&ins.completer)
	}
	if key.key == 'L' {
		insert_completer_explicit_line_all_complete(&ins.completer)
	}
}

input_handler_insert_raw_call :: proc(data: rawptr, key: Keys_Key, ctx: ^Context) {
	d := cast(^input_handler_Insert_Key_Data)(data)
	ins := cast(^input_handler_Insert)(d.mode.data)
	if cp, ok := input_handler_get_raw_codepoint(key); ok {
		if err := input_handler_insert_codepoint(ins, cp); err != .None {
			input_handler_report_error(ctx, err)
			return
		}
		key_str := keys_to_string_key(key, context.temp_allocator)
		hooks := context_hooks(ctx)
		hook_manager_run_hook(hooks, .Insert_Key, key_str, ctx)
		if input_handler_mode_enabled(ins.handler, ins.self) && !d.transient {
			ins.idle.timer.date = clock_add(clock_now(), input_handler_idle_timeout(ctx))
		}
	}
}

input_handler_insert_backspace :: proc(ins: ^input_handler_Insert) -> Input_Handler_Error {
	ctx := &ins.handler.ctx
	buffer := context_selections(ctx).buffer
	sels := context_selections(ctx)
	origin := Coord_Buffer{}
	arr := make([dynamic]Selection, 0, len(sels.selections), ins.allocator)
	for &sel in sels.selections {
		if sel.cursor.coord == origin {
			continue
		}
		append(&arr, input_handler_selection_from_coord(buffer_char_prev(buffer, sel.cursor.coord)))
	}
	main_char: string
	main_char_owned := false
	main := &context_selections(ctx).selections[context_selections(ctx).main]
	if main.cursor.coord != origin {
		main_char = buffer_string(buffer, buffer_char_prev(buffer, main.cursor.coord), main.cursor.coord, ins.allocator)
		main_char_owned = true
	}
	if len(arr) != 0 {
		tmp := selection_list_make_multi(buffer, arr, ins.allocator)
		if err := selection_list_erase(&tmp); err != .None {
			selection_list_destroy(&tmp)
			return .Read_Only
		}
		selection_list_destroy(&tmp)
	} else {
		delete(arr)
	}
	if len(main_char) != 0 {
		hooks := context_hooks(ctx)
		hook_manager_run_hook(hooks, .Insert_Delete, main_char, ctx)
	}
	if main_char_owned {
		delete(main_char, ins.allocator)
	}
	selection_list_update(context_selections_write_only(ctx), false)
	return .None
}

input_handler_insert_delete :: proc(ins: ^input_handler_Insert) -> Input_Handler_Error {
	ctx := &ins.handler.ctx
	buffer := context_selections(ctx).buffer
	sels := context_selections(ctx)
	arr := make([dynamic]Selection, 0, len(sels.selections), ins.allocator)
	for &sel in sels.selections {
		append(&arr, input_handler_selection_from_coord(sel.cursor.coord))
	}
	tmp := selection_list_make_multi(buffer, arr, ins.allocator)
	if err := selection_list_erase(&tmp); err != .None {
		selection_list_destroy(&tmp)
		return .Read_Only
	}
	selection_list_destroy(&tmp)
	return .None
}

input_handler_insert_home :: proc(ins: ^input_handler_Insert) {
	sels := context_selections(&ins.handler.ctx)
	for &sel in sels.selections {
		pos := Coord_Buffer{line = sel.cursor.line}
		sel.anchor = pos
		sel.cursor = coord_buffer_and_target(pos)
	}
	selection_list_sort_and_merge_overlapping(sels)
}

input_handler_insert_end :: proc(ins: ^input_handler_Insert) {
	ctx := &ins.handler.ctx
	buffer := context_selections(ctx).buffer
	sels := context_selections(ctx)
	for &sel in sels.selections {
		line := sel.cursor.line
		pos := buffer_clamp(buffer, Coord_Buffer{line = line, column = Coord_Byte(len(buffer.lines[int(line)]))})
		sel.anchor = pos
		sel.cursor = coord_buffer_and_target(pos)
	}
	selection_list_sort_and_merge_overlapping(sels)
}

input_handler_insert_on_key :: proc(data: rawptr, key: Keys_Key) {
	ins := cast(^input_handler_Insert)(data)
	h := ins.handler
	ctx := &h.ctx
	transient := .Draft in ctx.flags
	update_completions := true
	moved := false
	if input_handler_mouse_handle_key(&ins.mouse, key, ctx) {
		if !transient {
			ins.idle.timer.date = clock_add(clock_now(), input_handler_idle_timeout(ctx))
		}
	} else if input_handler_key_is(key, keys_MOD_NONE, keys_ESCAPE) || input_handler_key_is(key, keys_MOD_CONTROL, 'c') {
		insert_completer_reset(&ins.completer)
		input_handler_pop_mode(h, ins.self)
	} else if input_handler_key_is(key, keys_MOD_NONE, keys_BACKSPACE) || input_handler_key_is(key, keys_MOD_SHIFT, keys_BACKSPACE) {
		if err := input_handler_insert_backspace(ins); err != .None {
			input_handler_report_error(&ins.handler.ctx, err)
			return
		}
	} else if input_handler_key_is(key, keys_MOD_NONE, keys_DELETE) {
		if err := input_handler_insert_delete(ins); err != .None {
			input_handler_report_error(&ins.handler.ctx, err)
			return
		}
	} else if input_handler_key_is(key, keys_MOD_NONE, keys_LEFT) {
		input_handler_insert_move_chars(ins, -1)
		moved = true
	} else if input_handler_key_is(key, keys_MOD_NONE, keys_RIGHT) {
		input_handler_insert_move_chars(ins, 1)
		moved = true
	} else if input_handler_key_is(key, keys_MOD_NONE, keys_UP) {
		input_handler_insert_move_lines(ins, -1)
		moved = true
	} else if input_handler_key_is(key, keys_MOD_NONE, keys_DOWN) {
		input_handler_insert_move_lines(ins, 1)
		moved = true
	} else if input_handler_key_is(key, keys_MOD_NONE, keys_HOME) {
		input_handler_insert_home(ins)
	} else if input_handler_key_is(key, keys_MOD_NONE, keys_END) {
		input_handler_insert_end(ins)
	} else if cp, ok := keys_codepoint(key); ok {
		insert_completer_try_accept(&ins.completer)
		if err := input_handler_insert_codepoint(ins, cp); err != .None {
			input_handler_report_error(&ins.handler.ctx, err)
			return
		}
	} else if input_handler_key_is(key, keys_MOD_CONTROL, 'r') {
		insert_completer_try_accept(&ins.completer)
		key_data := new(input_handler_Insert_Key_Data, h.allocator)
		key_data.mode = ins.self
		cmd := Key_Callback{call = input_handler_insert_register_call, data = key_data, destroy = input_handler_insert_key_destroy}
		input_handler_on_next_key_with_autoinfo(ctx, "register", .None, cmd, "enter register name", input_handler_REGISTER_DOC)
		update_completions = false
	} else if input_handler_key_is(key, keys_MOD_CONTROL, 'n') ||
	   input_handler_key_is(key, keys_MOD_CONTROL, 'p') ||
	   key.modifiers == keys_MOD_MENU_SELECT {
		input_handler_drop_last_recorded_key(h)
		relative := key.modifiers != keys_MOD_MENU_SELECT
		index := 0
		if relative {
			index = 1 if input_handler_key_is(key, keys_MOD_CONTROL, 'n') else -1
		} else {
			index = int(key.key)
		}
		insert_completer_select(&ins.completer, index, relative, input_handler_record_key_apply, h)
		update_completions = false
	} else if input_handler_key_is(key, keys_MOD_CONTROL, 'x') {
		key_data := new(input_handler_Insert_Key_Data, h.allocator)
		key_data.mode = ins.self
		cmd := Key_Callback{call = input_handler_insert_explicit_call, data = key_data, destroy = input_handler_insert_key_destroy}
		input_handler_on_next_key_with_autoinfo(ctx, "explicit-completion", .None, cmd, "enter completion type",
			"f: filename\nw: word (current buffer)\nW: word (all buffers)\nl: line (current buffer)\nL: line (all buffers)\n")
		update_completions = false
	} else if input_handler_key_is(key, keys_MOD_CONTROL, 'o') {
		ins.auto_complete = !ins.auto_complete
		insert_completer_reset(&ins.completer)
	} else if input_handler_key_is(key, keys_MOD_CONTROL, 'u') {
		buffer := context_selections(ctx).buffer
		buffer_commit_undo_group(buffer)
		id_str := format_to_string_int(int(buffer_current_history_id(buffer)), context.temp_allocator)
		msg, _ := format_format("committed change #{}", []string{id_str}, context.temp_allocator)
		faces := context_faces(ctx)
		atom := Display_Atom{face = input_handler_face(faces, "Information"), type = .Text, text = msg}
		atoms := make([dynamic]Display_Atom, 1, context.temp_allocator)
		atoms[0] = atom
		context_print_status_simple(ctx, Display_Line{atoms = atoms})
	} else if input_handler_key_is(key, keys_MOD_CONTROL, 'v') {
		insert_completer_try_accept(&ins.completer)
		key_data := new(input_handler_Insert_Key_Data, h.allocator)
		key_data.mode = ins.self
		key_data.transient = transient
		cmd := Key_Callback{call = input_handler_insert_raw_call, data = key_data, destroy = input_handler_insert_key_destroy}
		input_handler_on_next_key_with_autoinfo(ctx, "raw-insert", .None, cmd, "raw insert", "enter key to insert")
		update_completions = false
	} else if input_handler_key_is(key, keys_MOD_ALT, ';') {
		input_handler_push_mode(h, input_handler_normal_make(h, true))
		return
	}

	hooks := context_hooks(ctx)
	key_str := keys_to_string_key(key, context.temp_allocator)
	hook_manager_run_hook(hooks, .Insert_Key, key_str, ctx)
	if moved {
		hook_manager_run_hook(hooks, .Insert_Move, key_str, ctx)
	}
	// Hooks might have disabled us.
	if update_completions && input_handler_mode_enabled(h, ins.self) && !transient {
		ins.idle.timer.date = clock_add(clock_now(), input_handler_idle_timeout(ctx))
	}
}

input_handler_insert_paste :: proc(data: rawptr, content: string) {
	ins := cast(^input_handler_Insert)(data)
	insert_completer_try_accept(&ins.completer)
	strings_arr := [1]string{content}
	if err := input_handler_insert_strings(ins, strings_arr[:]); err != .None {
		input_handler_report_error(&ins.handler.ctx, err)
		return
	}
	ins.idle.timer.date = clock_add(clock_now(), input_handler_idle_timeout(&ins.handler.ctx))
}

input_handler_insert_mode_info :: proc(data: rawptr, allocator: mem.Allocator) -> Mode_Info {
	ins := cast(^input_handler_Insert)(data)
	ctx := &ins.handler.ctx
	faces := context_faces(ctx)
	sels := context_selections(ctx)
	atoms := make([dynamic]Display_Atom, 0, 3, allocator)
	append(&atoms, Display_Atom{face = input_handler_face(faces, "StatusLineMode"), type = .Text, text = strings.clone("insert", allocator)})
	append(&atoms, Display_Atom{face = input_handler_face(faces, "StatusLine"), type = .Text, text = strings.clone(" ", allocator)})
	num_str := format_to_string_int(len(sels.selections), allocator)
	main_str := format_to_string_int(sels.main + 1, allocator)
	defer delete(num_str, allocator)
	defer delete(main_str, allocator)
	if len(sels.selections) == 1 {
		sel, _ := format_format("{} sel", []string{num_str}, allocator)
		append(&atoms, Display_Atom{face = input_handler_face(faces, "StatusLineInfo"), type = .Text, text = sel})
	} else {
		sel, _ := format_format("{} sels ({})", []string{num_str, main_str}, allocator)
		append(&atoms, Display_Atom{face = input_handler_face(faces, "StatusLineInfo"), type = .Text, text = sel})
	}
	return Mode_Info{display_line = Display_Line{atoms = atoms}}
}

input_handler_insert_prepare :: proc(ins: ^input_handler_Insert, mode: Input_Handler_Insert_Mode, count_: int) -> Input_Handler_Error {
	count := count_
	ctx := &ins.handler.ctx
	sels := context_selections(ctx)
	buffer := sels.buffer
	switch mode {
	case .Insert:
		for &sel in sels.selections {
			min, max := input_handler_sel_min(&sel), input_handler_sel_max(&sel)
			sel.anchor = max
			sel.cursor = coord_buffer_and_target(min)
		}
	case .Replace:
		if err := selection_list_erase(sels); err != .None {
			return .Read_Only
		}
	case .Append:
		for &sel in sels.selections {
			min, max := input_handler_sel_min(&sel), input_handler_sel_max(&sel)
			next := buffer_char_next(buffer, max)
			sel.anchor = min
			sel.cursor = coord_buffer_and_target(next)
			if sel.cursor.coord == buffer_end_coord(buffer) {
				buffer_insert(buffer, buffer_end_coord(buffer), "\n")
			}
		}
	case .Append_At_Line_End:
		for &sel in sels.selections {
			max := input_handler_sel_max(&sel)
			pos := Coord_Buffer{line = max.line, column = Coord_Byte(len(buffer.lines[int(max.line)]) - 1)}
			sel.anchor = pos
			sel.cursor = coord_buffer_and_target(pos)
		}
	case .Open_Line_Below:
		count = count if count > 0 else 1
		new_sels := make([dynamic]Selection, 0, len(sels.selections) * count, ins.allocator)
		inserted_count := 0
		nl := make([]u8, count, context.temp_allocator)
		for &b in nl {
			b = '\n'
		}
		for sel_copy in sels.selections {
			sel := sel_copy
			max := input_handler_sel_max(&sel)
			buffer_insert(buffer, Coord_Buffer{line = max.line + Units_LineCount(inserted_count) + 1}, string(nl))
			for i in 0 ..< count {
				append(&new_sels, input_handler_selection_from_coord(Coord_Buffer{line = max.line + Units_LineCount(inserted_count + i) + 1}))
			}
			inserted_count += count
		}
		selection_list_set(sels, new_sels[:], sels.main * count + count - 1)
		hooks := context_hooks(ctx)
		hook_manager_run_hook(hooks, .Insert_Char, "\n", ctx)
	case .Open_Line_Above:
		count = count if count > 0 else 1
		new_sels := make([dynamic]Selection, 0, len(sels.selections) * count, ins.allocator)
		inserted_count := 0
		nl := make([]u8, count, context.temp_allocator)
		for &b in nl {
			b = '\n'
		}
		for sel_copy in sels.selections {
			sel := sel_copy
			min := input_handler_sel_min(&sel)
			buffer_insert(buffer, Coord_Buffer{line = min.line + Units_LineCount(inserted_count)}, string(nl))
			for i in 0 ..< count {
				append(&new_sels, input_handler_selection_from_coord(Coord_Buffer{line = min.line + Units_LineCount(inserted_count + i)}))
			}
			inserted_count += count
		}
		selection_list_set(sels, new_sels[:], sels.main * count + count - 1)
		hooks := context_hooks(ctx)
		hook_manager_run_hook(hooks, .Insert_Char, "\n", ctx)
	case .Insert_At_Line_Begin:
		for &sel in sels.selections {
			min := input_handler_sel_min(&sel)
			pos := Coord_Buffer{line = min.line}
			it := buffer_iterator_at(buffer, pos)
			for buffer_iterator_value(it) == ' ' || buffer_iterator_value(it) == '\t' {
				buffer_iterator_next(&it)
			}
			if buffer_iterator_value(it) != '\n' {
				pos = it.coord
			}
			sel.anchor = pos
			sel.cursor = coord_buffer_and_target(pos)
		}
	}
	selection_list_check_invariant(sels)
	buffer_check_invariant(buffer)
	return .None
}

input_handler_insert_keymap_mode :: proc(data: rawptr) -> Keymap_Manager_Mode {
	return .Insert
}

input_handler_insert_name :: proc(data: rawptr) -> string {
	return "insert"
}

input_handler_insert_on_raw_key :: proc(data: rawptr) {
}

input_handler_insert_refresh_ifn :: proc(data: rawptr) {
}

input_handler_insert_take_pending_count :: proc(data: rawptr) -> uint {
	return 1
}

input_handler_insert_vtable := Input_Mode_VTable{
	on_key             = input_handler_insert_on_key,
	paste              = input_handler_insert_paste,
	on_raw_key         = input_handler_insert_on_raw_key,
	on_enabled         = input_handler_insert_on_enabled,
	on_disabled        = input_handler_insert_on_disabled,
	refresh_ifn        = input_handler_insert_refresh_ifn,
	take_pending_count = input_handler_insert_take_pending_count,
	mode_info          = input_handler_insert_mode_info,
	keymap_mode        = input_handler_insert_keymap_mode,
	name               = input_handler_insert_name,
	destroy            = input_handler_insert_destroy,
}

// input_handler_Paste_Ctx carries the paste arguments for the visitor.
input_handler_Paste_Ctx :: struct {
	buffer:   ^Buffer,
	content:  string,
	linewise: bool,
}

input_handler_paste_apply :: proc(ctx: rawptr, index: int, sel: ^Selection) -> Buffer_Error {
	_ = index
	c := cast(^input_handler_Paste_Ctx)(ctx)
	min, max := input_handler_sel_min(sel), input_handler_sel_max(sel)
	r, err := buffer_insert(c.buffer, normal_paste_pos(c.buffer, min, max, .Insert, c.linewise), c.content)
	if err != .None {
		return err
	}
	end := r.begin
	if coord_compare(r.end, r.begin) > 0 {
		end = buffer_char_prev(c.buffer, r.end)
	}
	input_handler_sel_set_min_max(sel, r.begin, end)
	return .None
}

// input_handler_base_paste is InputMode::paste: insert content at each
// selection. Deviation: the C++ catches runtime_error from the
// edition machinery; Odin buffer procs return values, and the
// reporting path needs client access that only exists in real
// contexts, so errors cannot be caught here.
input_handler_base_paste :: proc(h: ^Input_Handler, content: string) -> Input_Handler_Error {
	ctx := &h.ctx
	buffer := context_selections(ctx).buffer
	linewise := len(content) != 0 && content[len(content) - 1] == '\n'
	edition := scoped_edition_make(ctx)
	defer scoped_edition_destroy(&edition)
	selection_edition := scoped_selection_edition_make(ctx)
	defer scoped_selection_edition_destroy(&selection_edition)
	c := input_handler_Paste_Ctx{buffer = buffer, content = content, linewise = linewise}
	if err := selection_list_for_each(context_selections(ctx), input_handler_paste_apply, &c, false); err != .None {
		return .Read_Only
	}
	return .None
}

input_handler_init :: proc(h: ^Input_Handler, selections: Selection_List, flags: Context_Flags, name: string, allocator := context.allocator) {
	h.allocator = allocator
	h.mode_stack = make([dynamic]^Input_Mode, 0, 4, allocator)
	h.last_insert = Input_Handler_Insertion{count = 1}
	h.handle_key_level = 0
	h.recording_reg = 0
	h.recorded_keys = make([dynamic]Keys_Key, 0, allocator)
	h.recording_level = -1
	context_init(&h.ctx, h, selections, flags, name, allocator)
	input_handler_push_mode(h, input_handler_normal_make(h, false))
}

input_handler_make :: proc(selections: Selection_List, flags: Context_Flags, name: string, allocator := context.allocator) -> ^Input_Handler {
	h := new(Input_Handler, allocator)
	input_handler_init(h, selections, flags, name, allocator)
	return h
}

input_handler_deinit :: proc(h: ^Input_Handler) {
	for mode in h.mode_stack {
		input_handler_destroy_mode(h, mode)
	}
	delete(h.mode_stack)
	delete(h.last_insert.keys)
	delete(h.recorded_keys)
	context_destroy(&h.ctx)
}

input_handler_destroy :: proc(h: ^Input_Handler) {
	allocator := h.allocator
	input_handler_deinit(h)
	free(h, allocator)
}

input_handler_context :: proc(h: ^Input_Handler) -> ^Context {
	return &h.ctx
}

input_handler_push_mode :: proc(h: ^Input_Handler, new_mode: ^Input_Mode) {
	current := h.mode_stack[len(h.mode_stack) - 1]
	prev_name := current.vtable.name(current.data)
	current.vtable.on_disabled(current.data, true)
	append(&h.mode_stack, new_mode)
	new_mode.vtable.on_enabled(new_mode.data, false)
	hooks := context_hooks(&h.ctx)
	param, _ := format_format("push:{}:{}", []string{prev_name, new_mode.vtable.name(new_mode.data)}, context.temp_allocator)
	hook_manager_run_hook(hooks, .Mode_Change, param, &h.ctx)
}

input_handler_pop_mode :: proc(h: ^Input_Handler, mode: ^Input_Mode) {
	assert(len(h.mode_stack) > 1)
	assert(h.mode_stack[len(h.mode_stack) - 1] == mode)
	// Keep the mode alive across the hook (the C++ keep_alive);
	// destroy it after the hook when no guard holds it.
	current := h.mode_stack[len(h.mode_stack) - 1]
	current.vtable.on_disabled(current.data, false)
	pop(&h.mode_stack)
	next := h.mode_stack[len(h.mode_stack) - 1]
	next.vtable.on_enabled(next.data, true)
	hooks := context_hooks(&h.ctx)
	param, _ := format_format("pop:{}:{}", []string{current.vtable.name(current.data), next.vtable.name(next.data)}, context.temp_allocator)
	hook_manager_run_hook(hooks, .Mode_Change, param, &h.ctx)
	if !input_handler_mode_guarded(current) {
		input_handler_destroy_mode(h, current)
	}
}

input_handler_reset_normal_mode :: proc(h: ^Input_Handler) {
	assert(h.mode_stack[0].vtable == &input_handler_normal_vtable)
	for len(h.mode_stack) > 1 {
		input_handler_pop_mode(h, h.mode_stack[len(h.mode_stack) - 1])
	}
}

input_handler_insert :: proc(h: ^Input_Handler, mode: Input_Handler_Insert_Mode, count: int) -> Input_Handler_Error {
	// Checked first: the C++ Insert constructor throws before its
	// body runs, unwinding the member initializers with no net effect.
	if .Read_Only in context_selections(&h.ctx).buffer.flags {
		return .Read_Only
	}
	last_insert: ^Input_Handler_Insertion = &h.last_insert if h.handle_key_level <= 1 else nil
	mode_obj, err := input_handler_insert_make(h, mode, count, last_insert)
	if err != .None {
		return err
	}
	input_handler_push_mode(h, mode_obj)
	return .None
}

input_handler_repeat_last_insert :: proc(h: ^Input_Handler) -> Input_Handler_Error {
	if len(h.last_insert.keys) == 0 {
		return .None
	}
	if h.mode_stack[len(h.mode_stack) - 1].vtable != &input_handler_normal_vtable ||
	   utils_nested_bool_is_set(h.last_insert.recording) || h.last_insert.repeating {
		return .Repeat_Unavailable
	}
	ctx := &h.ctx
	guard := utils_scoped_bool_make(&ctx.hooks_disabled, h.last_insert.disable_hooks)
	defer utils_scoped_bool_release(&guard)
	h.last_insert.repeating = true
	defer h.last_insert.repeating = false
	mode_obj, err := input_handler_insert_make(h, h.last_insert.mode, h.last_insert.count, nil)
	if err != .None {
		return err
	}
	input_handler_push_mode(h, mode_obj)
	n := len(h.last_insert.keys)
	for i in 0 ..< n {
		input_handler_handle_key(h, h.last_insert.keys[i])
	}
	assert(h.mode_stack[len(h.mode_stack) - 1].vtable == &input_handler_normal_vtable)
	return .None
}

input_handler_paste :: proc(h: ^Input_Handler, content: string) {
	current := h.mode_stack[len(h.mode_stack) - 1]
	current.vtable.paste(current.data, content)
}

input_handler_prompt :: proc(h: ^Input_Handler, prompt: string, initstr, emptystr: string, prompt_face: Face, flags: Prompt_Flags, history_register: rune, completer: Prompt_Completer, callback: Prompt_Callback) {
	input_handler_push_mode(h, input_handler_prompt_make(h, prompt, initstr, emptystr, prompt_face, flags, history_register, completer, callback))
}

input_handler_set_prompt_face :: proc(h: ^Input_Handler, prompt_face: Face) {
	current := h.mode_stack[len(h.mode_stack) - 1]
	if current.vtable == &input_handler_prompt_vtable {
		input_handler_prompt_set_face(cast(^input_handler_Prompt)(current.data), prompt_face)
	}
}

input_handler_on_next_key :: proc(h: ^Input_Handler, mode_name: string, keymap_mode: Keymap_Manager_Mode, callback: Key_Callback, idle: Input_Handler_Idle_Callback = {}) {
	name, _ := format_format("next-key[{}]", []string{mode_name}, context.temp_allocator)
	input_handler_push_mode(h, input_handler_next_key_make(h, name, keymap_mode, callback, idle))
}

// input_handler_process_key records a key and delivers it to the
// current mode, guarding the mode across reentrant callbacks.
input_handler_process_key :: proc(h: ^Input_Handler, key: Keys_Key) {
	input_handler_record_key(h, key)
	current := h.mode_stack[len(h.mode_stack) - 1]
	input_handler_mode_guard(current)
	defer input_handler_mode_release(h, current)
	current.vtable.on_key(current.data, key)
}

input_handler_handle_key :: proc(h: ^Input_Handler, key: Keys_Key, synthesized: bool = true) {
	if !input_handler_is_valid_key(key) {
		return
	}
	h.handle_key_level += 1
	defer h.handle_key_level -= 1
	if !synthesized {
		current := h.mode_stack[len(h.mode_stack) - 1]
		current.vtable.on_raw_key(current.data)
	}
	current := h.mode_stack[len(h.mode_stack) - 1]
	keymap_mode := current.vtable.keymap_mode(current.data)
	keymaps := context_keymaps(&h.ctx)
	if mapping := keymap_manager_get_mapping(keymaps, key, keymap_mode);
	   mapping != nil && !utils_nested_bool_is_set(h.ctx.keymaps_disabled) {
		// Copy to allow reentrant unmap.
		keys := make(Keys_Key_List, 0, len(mapping.keys), h.allocator)
		defer delete(keys)
		append(&keys, ..mapping.keys[:])
		count := current.vtable.take_pending_count(current.data) if mapping.atomic else 1
		for ; count > 0; count -= 1 {
			for k in keys {
				input_handler_process_key(h, k)
			}
		}
	} else {
		input_handler_process_key(h, key)
	}
	if h.handle_key_level < h.recording_level {
		debug_write_to_buffer("Macro recording started but not finished")
		h.recording_reg = 0
		h.recording_level = -1
	}
}

input_handler_record_key :: proc(h: ^Input_Handler, key: Keys_Key) {
	if utils_nested_bool_is_set(h.last_insert.recording) && h.handle_key_level <= 1 {
		append(&h.last_insert.keys, key)
	}
	if input_handler_is_recording(h) && h.handle_key_level == h.recording_level {
		append(&h.recorded_keys, key)
	}
}

input_handler_record_key_apply :: proc(ctx: rawptr, key: Keys_Key) {
	input_handler_record_key(cast(^Input_Handler)(ctx), key)
}

input_handler_drop_last_recorded_key :: proc(h: ^Input_Handler) {
	if utils_nested_bool_is_set(h.last_insert.recording) && h.handle_key_level <= 1 {
		assert(len(h.last_insert.keys) != 0)
		pop(&h.last_insert.keys)
	}
	if input_handler_is_recording(h) && h.handle_key_level == h.recording_level {
		assert(len(h.recorded_keys) != 0)
		pop(&h.recorded_keys)
	}
}

input_handler_refresh_ifn :: proc(h: ^Input_Handler) {
	current := h.mode_stack[len(h.mode_stack) - 1]
	current.vtable.refresh_ifn(current.data)
}

input_handler_start_recording :: proc(h: ^Input_Handler, reg: rune) {
	assert(h.recording_reg == 0)
	h.recording_level = h.handle_key_level
	clear(&h.recorded_keys)
	h.recording_reg = reg
}

input_handler_is_recording :: proc(h: ^Input_Handler) -> bool {
	return h.recording_reg != 0
}

input_handler_stop_recording :: proc(h: ^Input_Handler) {
	assert(h.recording_reg != 0)
	if len(h.recorded_keys) != 0 {
		// Forget the key that got us to exit recording.
		if h.handle_key_level == h.recording_level {
			pop(&h.recorded_keys)
		}
		b := strings.builder_make(context.temp_allocator)
		for key in h.recorded_keys {
			str := keys_to_string_key(key, context.temp_allocator)
			strings.write_string(&b, str)
		}
		reg := register_manager_instance().registers[h.recording_reg]
		keys := strings.to_string(b)
		values := [1]string{keys}
		reg.vtable.set(reg.data, &h.ctx, values[:], false)
	}
	h.recording_reg = 0
	h.recording_level = -1
}

input_handler_recording_reg :: proc(h: ^Input_Handler) -> rune {
	return h.recording_reg
}

input_handler_mode_info :: proc(h: ^Input_Handler, allocator := context.allocator) -> Mode_Info {
	current := h.mode_stack[len(h.mode_stack) - 1]
	return current.vtable.mode_info(current.data, allocator)
}

// input_handler_mode_info_destroy frees a Mode_Info from
// input_handler_mode_info (atom texts and the array are owned).
input_handler_mode_info_destroy :: proc(info: ^Mode_Info, allocator := context.allocator) {
	for a in info.display_line.atoms {
		delete(a.text, allocator)
	}
	delete(info.display_line.atoms)
	info.display_line.atoms = nil
}

// input_handler_Scoped_Force_Normal is ScopedForceNormal: forces the
// handler into normal mode until destroyed.
input_handler_Scoped_Force_Normal :: struct {
	handler: ^Input_Handler,
	mode:    ^Input_Mode,
}

input_handler_scoped_force_normal_make :: proc(h: ^Input_Handler, params: Normal_Params) -> input_handler_Scoped_Force_Normal {
	s := input_handler_Scoped_Force_Normal{handler = h}
	if len(h.mode_stack) != 1 {
		input_handler_push_mode(h, input_handler_normal_make(h, false))
		s.mode = h.mode_stack[len(h.mode_stack) - 1]
	}
	back := h.mode_stack[len(h.mode_stack) - 1]
	back_normal := cast(^input_handler_Normal)(back.data)
	back_normal.params = params
	return s
}

input_handler_scoped_force_normal_destroy :: proc(s: ^input_handler_Scoped_Force_Normal) {
	if s.mode == nil {
		return
	}
	h := s.handler
	if h.mode_stack[len(h.mode_stack) - 1] == s.mode {
		input_handler_pop_mode(h, s.mode)
	} else {
		for m, i in h.mode_stack {
			if m == s.mode {
				ordered_remove(&h.mode_stack, i)
				input_handler_destroy_mode(h, s.mode)
				break
			}
		}
	}
	s.mode = nil
}

input_handler_should_show_info :: proc(mask: Auto_Info, ctx: ^Context) -> bool {
	opts := context_options(ctx)
	autoinfo := input_handler_option_auto_info(option_manager_get_checked(opts, "autoinfo"))
	return (autoinfo & mask) != Auto_Info{} && ctx.client != nil
}

input_handler_show_auto_info_ifn :: proc(title, info: string, mask: Auto_Info, ctx: ^Context) -> bool {
	if !input_handler_should_show_info(mask, ctx) {
		return false
	}
	client_info_show_string(ctx.client, title, info, Coord_Buffer{}, .Prompt)
	return true
}

input_handler_hide_auto_info_ifn :: proc(ctx: ^Context, hide: bool) {
	if hide {
		client_info_hide(ctx.client)
	}
}

// input_handler_Autoinfo_Key_Data carries the wrapped command for the
// autoinfo next-key callback.
input_handler_Autoinfo_Key_Data :: struct {
	cmd: Key_Callback,
}

input_handler_autoinfo_key_call :: proc(data: rawptr, key: Keys_Key, ctx: ^Context) {
	d := cast(^input_handler_Autoinfo_Key_Data)(data)
	hide := input_handler_should_show_info(Auto_Info{.On_Key}, ctx)
	input_handler_hide_auto_info_ifn(ctx, hide)
	d.cmd.call(d.cmd.data, key, ctx)
}

input_handler_autoinfo_key_destroy :: proc(data: rawptr, allocator: mem.Allocator) {
	d := cast(^input_handler_Autoinfo_Key_Data)(data)
	if d.cmd.destroy != nil {
		d.cmd.destroy(d.cmd.data, allocator)
	}
	free(d, allocator)
}

// input_handler_Autoinfo_Idle_Data carries the info text for the
// autoinfo idle callback.
input_handler_Autoinfo_Idle_Data :: struct {
	ctx:   ^Context,
	title: string,
	info:  string,
}

input_handler_autoinfo_idle_call :: proc(data: rawptr, timer: ^Event_Manager_Timer) {
	_ = timer
	d := cast(^input_handler_Autoinfo_Idle_Data)(data)
	input_handler_show_auto_info_ifn(d.title, d.info, Auto_Info{.On_Key}, d.ctx)
}

input_handler_autoinfo_idle_destroy :: proc(data: rawptr, allocator: mem.Allocator) {
	d := cast(^input_handler_Autoinfo_Idle_Data)(data)
	delete(d.title, allocator)
	delete(d.info, allocator)
	free(d, allocator)
}

// input_handler_on_next_key_with_autoinfo executes cmd on the next key,
// showing title/info while waiting. Clones title and info.
input_handler_on_next_key_with_autoinfo :: proc(ctx: ^Context, mode_name: string, keymap_mode: Keymap_Manager_Mode, cmd: Key_Callback, title, info: string) {
	h := ctx.input_handler
	key_data := new(input_handler_Autoinfo_Key_Data, h.allocator)
	key_data.cmd = cmd
	wrapped := Key_Callback{call = input_handler_autoinfo_key_call, data = key_data, destroy = input_handler_autoinfo_key_destroy}
	idle_data := new(input_handler_Autoinfo_Idle_Data, h.allocator)
	idle_data.ctx = ctx
	idle_data.title = strings.clone(title, h.allocator)
	idle_data.info = strings.clone(info, h.allocator)
	idle := Input_Handler_Idle_Callback{call = input_handler_autoinfo_idle_call, data = idle_data, destroy = input_handler_autoinfo_idle_destroy}
	input_handler_on_next_key(h, mode_name, keymap_mode, wrapped, idle)
}

input_handler_scroll_window :: proc(ctx: ^Context, offset: Units_LineCount, on_hidden_cursor: On_Hidden_Cursor) {
	window := context_window(ctx)
	buffer := context_selections(ctx).buffer
	line_count := buffer_line_count(buffer)
	win_pos := window.position
	win_dim := window.dimensions
	if on_hidden_cursor == .Preserve_Selections {
		ctx.ensure_cursor_visible = false
	}
	if (offset < 0 && win_pos.line == 0) || (offset > 0 && win_pos.line == line_count - 1) {
		return
	}
	max_offset := Coord_Display{line = (win_dim.line - 1) / 2, column = (win_dim.column - 1) / 2}
	opts := context_options(ctx)
	scrolloff_opt := option_manager_get_checked(opts, "scrolloff").value.(Coord_Display)
	scrolloff := Coord_Display{line = min(scrolloff_opt.line, max_offset.line), column = min(scrolloff_opt.column, max_offset.column)}
	win_pos.line = clamp(win_pos.line + offset, Units_LineCount(0), line_count - 1)
	window_set_position(window, win_pos)
	if on_hidden_cursor != .Preserve_Selections {
		edition := scoped_selection_edition_make(ctx)
		defer scoped_selection_edition_destroy(&edition)
		sels := context_selections(ctx)
		main := &sels.selections[sels.main]
		anchor := main.anchor
		cursor := main.cursor
		cursor_off := win_pos.line - window.position.line
		line := clamp(cursor.line + cursor_off, win_pos.line + scrolloff.line, win_pos.line + win_dim.line - 1 - scrolloff.line)
		tabstop := Units_ColumnCount(option_manager_get_checked(opts, "tabstop").value.(int))
		new_cursor := buffer_offset_coord_line(buffer, cursor, line - cursor.line, tabstop)
		main.anchor = new_cursor.coord if on_hidden_cursor == .Move_Cursor_And_Anchor else anchor
		main.cursor = new_cursor
		selection_list_sort_and_merge_overlapping(sels)
	}
}

// ---------------------------------------------------------------------------
// Stubs for procs owned by unmerged modules (STUB protocol: the
// coordinator deletes each stub when the real proc merges).
// ---------------------------------------------------------------------------

// (Remainder stubs implemented in their owner modules: scoped_edition_make,
// scoped_edition_destroy, buffer_offset_coord_char, buffer_offset_coord_line,
// buffer_iterator_value, selection_list_make_multi.)

normal_get_command :: proc(key: Keys_Key) -> (Normal_Cmd, bool) {
	panic("STUB: normal_get_command")
}

normal_paste_pos :: proc(buffer: ^Buffer, min, max: Coord_Buffer, mode: Paste_Mode, linewise: bool) -> Coord_Buffer {
	panic("STUB: normal_paste_pos")
}

// (Remainder stubs implemented in command_manager.odin: command_parser_make,
// command_parser_read_token.)

