// Port of src/keys.hh and src/keys.cc: key codes, modifiers, and the
// <mod-name> key description language used for mappings and macros.
package kak

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"

// Named keys live in the UTF-16 surrogate range so they can never collide
// with real codepoints, matching Key::NamedKey in keys.hh.
keys_BACKSPACE: rune : 0xD800
keys_DELETE:    rune : keys_BACKSPACE + 1
keys_ESCAPE:    rune : keys_DELETE + 1
keys_RETURN:    rune : keys_ESCAPE + 1
keys_UP:        rune : keys_RETURN + 1
keys_DOWN:      rune : keys_UP + 1
keys_LEFT:      rune : keys_DOWN + 1
keys_RIGHT:     rune : keys_LEFT + 1
keys_PAGE_UP:   rune : keys_RIGHT + 1
keys_PAGE_DOWN: rune : keys_PAGE_UP + 1
keys_HOME:      rune : keys_PAGE_DOWN + 1
keys_END:       rune : keys_HOME + 1
keys_INSERT:    rune : keys_END + 1
keys_TAB:       rune : keys_INSERT + 1
keys_SPACE:     rune : keys_TAB + 1
keys_F1:        rune : keys_SPACE + 1
keys_F2:        rune : keys_F1 + 1
keys_F3:        rune : keys_F2 + 1
keys_F4:        rune : keys_F3 + 1
keys_F5:        rune : keys_F4 + 1
keys_F6:        rune : keys_F5 + 1
keys_F7:        rune : keys_F6 + 1
keys_F8:        rune : keys_F7 + 1
keys_F9:        rune : keys_F8 + 1
keys_F10:       rune : keys_F9 + 1
keys_F11:       rune : keys_F10 + 1
keys_F12:       rune : keys_F11 + 1
keys_FOCUS_IN:  rune : keys_F12 + 1
keys_FOCUS_OUT: rune : keys_FOCUS_IN + 1
keys_INVALID:   rune : keys_FOCUS_OUT + 1

// Key modifiers. A plain 32-bit integer (not a bit set) because the value
// also carries payloads: the mouse button in bits 6-7 and the scroll
// amount in the high 16 bits. Matches Key::Modifiers in keys.hh.
Keys_Modifiers :: distinct i32

keys_MOD_NONE:               Keys_Modifiers : 0
keys_MOD_CONTROL:           Keys_Modifiers : 1 << 0
keys_MOD_ALT:               Keys_Modifiers : 1 << 1
keys_MOD_SHIFT:             Keys_Modifiers : 1 << 2
keys_MOD_MOUSE_PRESS:       Keys_Modifiers : 1 << 3
keys_MOD_MOUSE_RELEASE:     Keys_Modifiers : 1 << 4
keys_MOD_MOUSE_POS:         Keys_Modifiers : 1 << 5
keys_MOD_MOUSE_BUTTON_MASK: Keys_Modifiers : 0b11 << 6
keys_MOD_SCROLL:            Keys_Modifiers : 1 << 8
keys_MOD_RESIZE:            Keys_Modifiers : 1 << 9
keys_MOD_MENU_SELECT:       Keys_Modifiers : 1 << 10

Keys_Mouse_Button :: enum {
	Left,
	Middle,
	Right,
}

// Display cell position, mirroring DisplayCoord (line and column only).
Keys_Coord :: struct {
	line:   int,
	column: int,
}

Keys_Key :: struct {
	modifiers: Keys_Modifiers,
	key:       rune,
}

Keys_Key_List :: [dynamic]Keys_Key

// Errors raised while parsing or printing keys. C++ throws key_parse_error
// for malformed descriptions and runtime_error for bad numbers and bad
// mouse button names; the three non-None values preserve that split.
Keys_Error :: enum {
	None,
	Parse_Error,
	Not_A_Number,
	Bad_Button,
}

Keys_Name_And_Key :: struct {
	name: string,
	key:  rune,
}

// Long key names, in the same order as keynamemap in keys.cc. Order is
// significant: keys_to_string_key prints the first name matching the key.
keys_KEY_NAMES: [25]Keys_Name_And_Key = {
	{"ret", keys_RETURN},
	{"space", keys_SPACE},
	{"tab", keys_TAB},
	{"lt", '<'},
	{"gt", '>'},
	{"backspace", keys_BACKSPACE},
	{"esc", keys_ESCAPE},
	{"up", keys_UP},
	{"down", keys_DOWN},
	{"left", keys_LEFT},
	{"right", keys_RIGHT},
	{"pageup", keys_PAGE_UP},
	{"pagedown", keys_PAGE_DOWN},
	{"home", keys_HOME},
	{"end", keys_END},
	{"ins", keys_INSERT},
	{"del", keys_DELETE},
	{"plus", '+'},
	{"minus", '-'},
	{"semicolon", ';'},
	{"percent", '%'},
	{"quote", '\''},
	{"dquote", '"'},
	{"focus_in", keys_FOCUS_IN},
	{"focus_out", keys_FOCUS_OUT},
}

// Total order over keys, matching Key::val.
keys_val :: proc(key: Keys_Key) -> u64 {
	return (u64(i32(key.modifiers)) << 32) | u64(u32(key.key))
}

keys_shift :: proc(key: Keys_Key) -> Keys_Key {
	return Keys_Key{key.modifiers | keys_MOD_SHIFT, key.key}
}

keys_alt :: proc(key: Keys_Key) -> Keys_Key {
	return Keys_Key{key.modifiers | keys_MOD_ALT, key.key}
}

keys_ctrl :: proc(key: Keys_Key) -> Keys_Key {
	return Keys_Key{key.modifiers | keys_MOD_CONTROL, key.key}
}

// Encodes a display position into a key codepoint, matching encode_coord.
keys_encode_coord :: proc(coord: Keys_Coord) -> rune {
	return rune(u32((i32(coord.line) << 16) | (i32(coord.column) & 0xFFFF)))
}

// Decodes a key codepoint holding an encoded position, matching Key::coord.
// The line is sign extended, the column zero extended.
keys_coord :: proc(key: Keys_Key) -> Keys_Coord {
	bits := u32(key.key)
	line := i32(bits & 0xFFFF0000) >> 16
	column := i32(bits & 0x0000FFFF)
	return Keys_Coord{int(line), int(column)}
}

keys_mouse_button :: proc(key: Keys_Key) -> Keys_Mouse_Button {
	return Keys_Mouse_Button((i32(key.modifiers) & (0b11 << 6)) >> 6)
}

keys_scroll_amount :: proc(key: Keys_Key) -> int {
	return int(i32(key.modifiers) >> 16)
}

keys_button_modifier :: proc(button: Keys_Mouse_Button) -> Keys_Modifiers {
	return Keys_Modifiers((i32(button) << 6) & (0b11 << 6))
}

keys_resize :: proc(dim: Keys_Coord) -> Keys_Key {
	return Keys_Key{keys_MOD_RESIZE, keys_encode_coord(dim)}
}

// Returns the codepoint a key inserts, if any, matching Key::codepoint.
keys_codepoint :: proc(key: Keys_Key) -> (rune, bool) {
	if key.modifiers == keys_MOD_NONE && key.key == keys_RETURN {
		return '\n', true
	}
	if key.modifiers == keys_MOD_NONE && key.key == keys_TAB {
		return '\t', true
	}
	if key.key == keys_SPACE &&
	   (key.modifiers == keys_MOD_NONE || key.modifiers == keys_MOD_SHIFT) {
		return ' ', true
	}
	if key.modifiers == keys_MOD_NONE && key.key == keys_ESCAPE {
		return 0x1B, true
	}
	if key.modifiers == keys_MOD_NONE && key.key > 27 &&
	   (key.key < 0xD800 || key.key > 0xDFFF) {
		return key.key, true
	}
	return 0, false
}

keys_is_basic_alpha :: proc(cp: rune) -> bool {
	return (cp >= 'a' && cp <= 'z') || (cp >= 'A' && cp <= 'Z')
}

keys_to_upper_byte :: proc(c: byte) -> byte {
	return c >= 'a' && c <= 'z' ? c - 'a' + 'A' : c
}

keys_to_lower_byte :: proc(c: byte) -> byte {
	return c >= 'A' && c <= 'Z' ? c - 'A' + 'a' : c
}

// Normalizes a parsed key, matching canonicalize_ifn: control characters
// become ctrl+letter, and shift+letter folds to uppercase. Shift on any
// other non-special key is an error.
keys_canonicalize :: proc(key: Keys_Key) -> (Keys_Key, Keys_Error) {
	k := key
	if k.key > 0 && k.key < 27 {
		k.modifiers = keys_MOD_CONTROL
		k.key = k.key - 1 + 'a'
	}
	if (k.modifiers & keys_MOD_SHIFT) != 0 {
		if keys_is_basic_alpha(k.key) {
			k.modifiers &= ~keys_MOD_SHIFT
			k.key = rune(keys_to_upper_byte(byte(k.key)))
		} else if k.key < 0xD800 || k.key > 0xDFFF {
			return k, Keys_Error.Parse_Error
		}
	}
	return k, Keys_Error.None
}

// Maps control characters typed outside <...> to their named key,
// matching the convert lambda in parse_keys.
keys_convert_raw :: proc(cp: rune) -> rune {
	switch cp {
	case '\n', '\r':
		return keys_RETURN
	case '\x08':
		return keys_BACKSPACE
	case '\t':
		return keys_TAB
	case ' ':
		return keys_SPACE
	case '\x1b':
		return keys_ESCAPE
	case:
		return cp
	}
}

// Parses an ASCII decimal number, matching str_to_int_ifp for the
// non-negative inputs reachable here.
keys_parse_int :: proc(s: string) -> (int, bool) {
	if len(s) == 0 {
		return 0, false
	}
	val := 0
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		if c < '0' || c > '9' {
			return 0, false
		}
		val = val * 10 + int(c - '0')
	}
	return val, true
}

// Parses a key description string into a key list, matching parse_keys.
// The caller owns the returned list and must delete it with the same
// allocator, even when an error is returned (the list is then partial).
keys_parse :: proc(s: string, allocator := context.allocator) -> (Keys_Key_List, Keys_Error) {
	result := make(Keys_Key_List, allocator)
	i := 0
	for i < len(s) {
		r, width := utf8.decode_rune_in_string(s[i:])
		if r != '<' {
			append(&result, Keys_Key{keys_MOD_NONE, keys_convert_raw(r)})
			i += width
			continue
		}
		end := -1
		for j := i + 1; j < len(s); j += 1 {
			if s[j] == '>' {
				end = j
				break
			}
		}
		if end == -1 {
			append(&result, Keys_Key{keys_MOD_NONE, '<'})
			i += 1
			continue
		}
		rest := s[i + 1:end]
		modifier := keys_MOD_NONE
		for {
			dash := strings.index_byte(rest, '-')
			if dash < 0 {
				break
			}
			if dash != 1 {
				return result, Keys_Error.Parse_Error
			}
			switch keys_to_lower_byte(rest[0]) {
			case 'c':
				modifier |= keys_MOD_CONTROL
			case 'a':
				modifier |= keys_MOD_ALT
			case 's':
				modifier |= keys_MOD_SHIFT
			case:
				return result, Keys_Error.Parse_Error
			}
			rest = rest[dash + 1:]
		}
		found := false
		named_key: rune
		for e in keys_KEY_NAMES {
			if e.name == rest {
				named_key, found = e.key, true
				break
			}
		}
		if found {
			k, err := keys_canonicalize(Keys_Key{modifier, named_key})
			if err != Keys_Error.None {
				return result, err
			}
			append(&result, k)
		} else if utf8.rune_count_in_string(rest) == 1 {
			cp, _ := utf8.decode_rune_in_string(rest)
			k, err := keys_canonicalize(Keys_Key{modifier, cp})
			if err != Keys_Error.None {
				return result, err
			}
			append(&result, k)
		} else if len(rest) > 0 && rest[0] == 'F' && len(rest) <= 3 {
			val, ok := keys_parse_int(rest[1:])
			if !ok {
				return result, Keys_Error.Not_A_Number
			}
			if val < 1 || val > 12 {
				return result, Keys_Error.Parse_Error
			}
			append(&result, Keys_Key{modifier, keys_F1 + rune(val - 1)})
		} else {
			return result, Keys_Error.Parse_Error
		}
		i = end + 1
	}
	return result, Keys_Error.None
}

keys_button_to_string :: proc(button: Keys_Mouse_Button) -> string {
	switch button {
	case .Left:
		return "left"
	case .Middle:
		return "middle"
	case .Right:
		return "right"
	}
	unreachable()
}

keys_string_to_button :: proc(s: string) -> (Keys_Mouse_Button, Keys_Error) {
	switch s {
	case "left":
		return Keys_Mouse_Button.Left, Keys_Error.None
	case "middle":
		return Keys_Mouse_Button.Middle, Keys_Error.None
	case "right":
		return Keys_Mouse_Button.Right, Keys_Error.None
	case:
		return Keys_Mouse_Button.Left, Keys_Error.Bad_Button
	}
}

// Finds the long name for a key codepoint, matching the reverse lookup
// in to_string. Returns the first name in keys_KEY_NAMES on a match.
keys_lookup_name :: proc(key: rune) -> (string, bool) {
	for e in keys_KEY_NAMES {
		if e.key == key {
			return e.name, true
		}
	}
	return "", false
}

// Encodes one codepoint as UTF-8, matching utf8::dump: values up to
// U+10FFFF (including surrogates) encode raw. Out of range values,
// unreachable for real keys, fall back to U+FFFD.
keys_write_rune_raw :: proc(sb: ^strings.Builder, cp: rune) {
	c := u32(cp)
	switch {
	case c <= 0x7F:
		strings.write_byte(sb, u8(c))
	case c <= 0x7FF:
		strings.write_byte(sb, u8(0xC0 | (c >> 6)))
		strings.write_byte(sb, u8(0x80 | (c & 0x3F)))
	case c <= 0xFFFF:
		strings.write_byte(sb, u8(0xE0 | (c >> 12)))
		strings.write_byte(sb, u8(0x80 | ((c >> 6) & 0x3F)))
		strings.write_byte(sb, u8(0x80 | (c & 0x3F)))
	case c <= 0x10FFFF:
		strings.write_byte(sb, u8(0xF0 | (c >> 18)))
		strings.write_byte(sb, u8(0x80 | ((c >> 12) & 0x3F)))
		strings.write_byte(sb, u8(0x80 | ((c >> 6) & 0x3F)))
		strings.write_byte(sb, u8(0x80 | (c & 0x3F)))
	case:
		strings.write_string(sb, "�")
	}
}

// Prints a key in <mod-name> form, matching to_string(Key). The caller
// owns the returned string and must delete it with the same allocator.
keys_to_string_key :: proc(key: Keys_Key, allocator := context.allocator) -> string {
	coord := keys_coord(key)
	coord.line += 1
	coord.column += 1

	mods := key.modifiers
	has_ctrl := (mods & keys_MOD_CONTROL) != 0
	has_alt := (mods & keys_MOD_ALT) != 0
	has_shift := (mods & keys_MOD_SHIFT) != 0
	special :=
		(mods &
				(keys_MOD_MOUSE_POS | keys_MOD_MOUSE_PRESS | keys_MOD_MOUSE_RELEASE |
					keys_MOD_SCROLL | keys_MOD_RESIZE)) != 0

	name, found := keys_lookup_name(key.key)
	is_fkey := key.key >= keys_F1 && key.key <= keys_F12
	named := special || found || is_fkey || has_ctrl || has_alt || has_shift

	sb := strings.builder_make(allocator)
	if named {
		strings.write_byte(&sb, '<')
	}
	if has_ctrl {
		strings.write_string(&sb, "c-")
	}
	if has_alt {
		strings.write_string(&sb, "a-")
	}
	if has_shift {
		strings.write_string(&sb, "s-")
	}
	if (mods & keys_MOD_MOUSE_POS) != 0 {
		fmt.sbprintf(&sb, "mouse:move:{}.{}", coord.line, coord.column)
	} else if (mods & keys_MOD_MOUSE_PRESS) != 0 {
		fmt.sbprintf(
			&sb,
			"mouse:press:{}:{}.{}",
			keys_button_to_string(keys_mouse_button(key)),
			coord.line,
			coord.column,
		)
	} else if (mods & keys_MOD_MOUSE_RELEASE) != 0 {
		fmt.sbprintf(
			&sb,
			"mouse:release:{}:{}.{}",
			keys_button_to_string(keys_mouse_button(key)),
			coord.line,
			coord.column,
		)
	} else if (mods & keys_MOD_SCROLL) != 0 {
		fmt.sbprintf(&sb, "scroll:{}:{}.{}", keys_scroll_amount(key), coord.line, coord.column)
	} else if (mods & keys_MOD_RESIZE) != 0 {
		fmt.sbprintf(&sb, "resize:{}.{}", coord.line, coord.column)
	} else if found {
		strings.write_string(&sb, name)
	} else if is_fkey {
		fmt.sbprintf(&sb, "F{}", int(key.key - keys_F1 + 1))
	} else {
		keys_write_rune_raw(&sb, key.key)
	}
	if named {
		strings.write_byte(&sb, '>')
	}
	return strings.to_string(sb)
}
