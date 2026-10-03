// Odin side of the keymap_manager differential harness. Same line
// protocol as harness.cc; see that file for the op list, key encoding,
// and escaping rules.
//
// Build: odin build . -collection:kaksrc=<repo>/odin -out:bin/keymap_manager_odin
package main

import kak "kaksrc:kak"

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

unescape :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	i := 0
	for i < len(s) {
		if s[i] == '\\' && i + 3 < len(s) && s[i + 1] == 'x' {
			hi := hex_val(s[i + 2])
			lo := hex_val(s[i + 3])
			if hi >= 0 && lo >= 0 {
				strings.write_byte(&b, u8(hi * 16 + lo))
				i += 4
				continue
			}
		}
		strings.write_byte(&b, s[i])
		i += 1
	}
	return strings.to_string(b)
}

hex_val :: proc(c: byte) -> int {
	switch c {
	case '0' ..= '9':
		return int(c - '0')
	case 'a' ..= 'f':
		return int(c - 'a') + 10
	case 'A' ..= 'F':
		return int(c - 'A') + 10
	}
	return -1
}

escape :: proc(s: string) -> string {
	digits := "0123456789abcdef"
	b := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		if c >= 0x20 && c <= 0x7E && c != '\\' {
			strings.write_byte(&b, c)
		} else {
			strings.write_string(&b, "\\x")
			strings.write_byte(&b, digits[c >> 4])
			strings.write_byte(&b, digits[c & 15])
		}
	}
	return strings.to_string(b)
}

parse_int :: proc(s: string) -> (int, bool) {
	v, ok := strconv.parse_int(s)
	return v, ok
}

parse_key :: proc(s: string) -> (kak.Keys_Key, bool) {
	colon := strings.index_byte(s, ':')
	if colon < 0 {
		return {}, false
	}
	mod, ok1 := parse_int(s[:colon])
	cp, ok2 := parse_int(s[colon + 1:])
	if !ok1 || !ok2 || cp < 0 || cp > 0x7FFFFFFF {
		return {}, false
	}
	return kak.Keys_Key{modifiers = kak.Keys_Modifiers(i32(mod)), key = rune(cp)}, true
}

parse_keys :: proc(s: string) -> (kak.Keys_Key_List, bool) {
	keys := make(kak.Keys_Key_List, 0, context.temp_allocator)
	if len(s) == 0 {
		return keys, true
	}
	for piece in strings.split(s, ",", context.temp_allocator) {
		k, ok := parse_key(piece)
		if !ok {
			return {}, false
		}
		append(&keys, k)
	}
	return keys, true
}

// keys_val mirrors C++ Key::val: the int modifiers sign-extended to
// u64, shifted, ORed with the zero-extended codepoint.
keys_val :: proc(k: kak.Keys_Key) -> u64 {
	return (u64(i64(i32(k.modifiers))) << 32) | u64(u32(k.key))
}

show_key :: proc(k: kak.Keys_Key, b: ^strings.Builder) {
	fmt.sbprintf(b, "%d:%d", i32(k.modifiers), u32(k.key))
}

show_keys :: proc(keys: []kak.Keys_Key) -> string {
	b := strings.builder_make(context.temp_allocator)
	for k, i in keys {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		show_key(k, &b)
	}
	return strings.to_string(b)
}

show_mapping :: proc(info: ^kak.Keymap_Manager_Info) -> string {
	if info == nil {
		return "NONE"
	}
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(
		&b,
		"FOUND %s %s %d",
		show_keys(info.keys[:]),
		escape(info.docstring),
		info.atomic ? 1 : 0,
	)
	return strings.to_string(b)
}

mode_of :: proc(s: string) -> kak.Keymap_Manager_Mode {
	v, _ := parse_int(s)
	return kak.Keymap_Manager_Mode(v)
}

err_name :: proc(e: kak.Keymap_Manager_Error) -> string {
	switch e {
	case .None:
		return "None"
	case .Regular_Mode:
		return "Regular_Mode"
	case .Already_Defined:
		return "Already_Defined"
	case .Invalid_Name:
		return "Invalid_Name"
	}
	unreachable()
}

read_all_stdin :: proc() -> [dynamic]byte {
	out := make([dynamic]byte, 0, 1 << 16, context.allocator)
	buf: [65536]byte
	for {
		n, err := os.read(os.stdin, buf[:])
		if n > 0 {
			append(&out, ..buf[:n])
		}
		if err != nil || n == 0 {
			break
		}
	}
	return out
}

main :: proc() {
	data := read_all_stdin()
	defer delete(data)
	input := string(data[:])
	lines := strings.split(input, "\n", context.allocator)
	defer delete(lines)
	if len(lines) > 0 && lines[len(lines) - 1] == "" {
		lines = lines[:len(lines) - 1]
	}
	for line, n in lines {
		if n % 256 == 0 {
			free_all(context.temp_allocator)
		}
		line := strings.trim_suffix(line, "\r")
		fields := strings.split(line, "\t", context.temp_allocator)
		if len(fields) == 0 {
			continue
		}
		switch fields[0] {
		case "mapget", "unmapget":
			if len(fields) == 8 {
				mgr := kak.keymap_manager_init()
				defer kak.keymap_manager_destroy(&mgr)
				key, ok1 := parse_key(unescape(fields[1]))
				mkeys, ok3 := parse_keys(unescape(fields[3]))
				qkey, ok6 := parse_key(unescape(fields[6]))
				if !ok1 || !ok3 || !ok6 {
					fmt.println("HARNESS-ERROR bad key")
					continue
				}
				atomic, _ := parse_int(fields[5])
				kak.keymap_manager_map_key(
					&mgr,
					key,
					mode_of(fields[2]),
					mkeys[:],
					unescape(fields[4]),
					atomic != 0,
				)
				if fields[0] == "unmapget" {
					kak.keymap_manager_unmap_key(&mgr, key, mode_of(fields[2]))
				}
				fmt.println(
					show_mapping(
						kak.keymap_manager_get_mapping(&mgr, qkey, mode_of(fields[7])),
					),
				)
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "unmapall":
			if len(fields) == 13 {
				mgr := kak.keymap_manager_init()
				defer kak.keymap_manager_destroy(&mgr)
				k1, ok1 := parse_key(unescape(fields[2]))
				mk1, ok4 := parse_keys(unescape(fields[4]))
				k2, ok7 := parse_key(unescape(fields[7]))
				mk2, ok9 := parse_keys(unescape(fields[9]))
				if !ok1 || !ok4 || !ok7 || !ok9 {
					fmt.println("HARNESS-ERROR bad key")
					continue
				}
				a1, _ := parse_int(fields[6])
				a2, _ := parse_int(fields[11])
				kak.keymap_manager_map_key(
					&mgr,
					k1,
					mode_of(fields[3]),
					mk1[:],
					unescape(fields[5]),
					a1 != 0,
				)
				kak.keymap_manager_map_key(
					&mgr,
					k2,
					mode_of(fields[8]),
					mk2[:],
					unescape(fields[10]),
					a2 != 0,
				)
				kak.keymap_manager_unmap_keys(&mgr, mode_of(fields[1]))
				g1 := show_mapping(
					kak.keymap_manager_get_mapping(&mgr, k1, mode_of(fields[3])),
				)
				g2 := show_mapping(
					kak.keymap_manager_get_mapping(&mgr, k2, mode_of(fields[8])),
				)
				mapped := kak.keymap_manager_get_mapped_keys(
					&mgr,
					mode_of(fields[12]),
				)
				defer delete(mapped)
				slice.sort_by(mapped[:], proc(a, b: kak.Keys_Key) -> bool {
					return keys_val(a) < keys_val(b)
				})
				fmt.printf(
					"G1 %s G2 %s MAPPED %d %s\n",
					g1,
					g2,
					len(mapped),
					show_keys(mapped[:]),
				)
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "mapped":
			if len(fields) >= 3 {
				count, _ := parse_int(fields[2])
				if count < 0 || len(fields) != 3 + 5 * count {
					fmt.println("HARNESS-ERROR bad line")
					continue
				}
				mgr := kak.keymap_manager_init()
				defer kak.keymap_manager_destroy(&mgr)
				bad := false
				for i := 0; i < count; i += 1 {
					key, ok1 := parse_key(unescape(fields[3 + 5 * i]))
					mkeys, ok2 := parse_keys(unescape(fields[5 + 5 * i]))
					if !ok1 || !ok2 {
						bad = true
						break
					}
					atomic, _ := parse_int(fields[7 + 5 * i])
					kak.keymap_manager_map_key(
						&mgr,
						key,
						mode_of(fields[4 + 5 * i]),
						mkeys[:],
						unescape(fields[6 + 5 * i]),
						atomic != 0,
					)
				}
				if bad {
					fmt.println("HARNESS-ERROR bad key")
					continue
				}
				mapped := kak.keymap_manager_get_mapped_keys(
					&mgr,
					mode_of(fields[1]),
				)
				defer delete(mapped)
				slice.sort_by(mapped[:], proc(a, b: kak.Keys_Key) -> bool {
					return keys_val(a) < keys_val(b)
				})
				fmt.printf("N %d %s\n", len(mapped), show_keys(mapped[:]))
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "usermode":
			if len(fields) >= 2 {
				count, _ := parse_int(fields[1])
				if count < 0 || len(fields) != 2 + count {
					fmt.println("HARNESS-ERROR bad line")
					continue
				}
				mgr := kak.keymap_manager_init()
				defer kak.keymap_manager_destroy(&mgr)
				out := strings.builder_make(context.temp_allocator)
				for i := 0; i < count; i += 1 {
					if i > 0 {
						strings.write_byte(&out, '\t')
					}
					err := kak.keymap_manager_add_user_mode(
						&mgr,
						unescape(fields[2 + i]),
					)
					if err == .None {
						strings.write_string(&out, "OK")
					} else {
						fmt.sbprintf(&out, "ERR %s", err_name(err))
					}
				}
				modes := kak.keymap_manager_user_modes(&mgr)
				ml := strings.builder_make(context.temp_allocator)
				for name, i in modes {
					if i > 0 {
						strings.write_byte(&ml, ',')
					}
					strings.write_string(&ml, escape(name))
				}
				if count > 0 {
					fmt.printf(
						"%s\tMODES %d %s\n",
						strings.to_string(out),
						len(modes),
						strings.to_string(ml),
					)
				} else {
					fmt.printf("MODES %d %s\n", len(modes), strings.to_string(ml))
				}
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "parent":
			if len(fields) == 8 {
				root := kak.keymap_manager_init()
				defer kak.keymap_manager_destroy(&root)
				sub := kak.keymap_manager_init_child(&root)
				defer kak.keymap_manager_destroy(&sub)
				key, ok1 := parse_key(unescape(fields[1]))
				rkeys, ok3 := parse_keys(unescape(fields[3]))
				cks := unescape(fields[5])
				ckeys, ok5 := parse_keys(cks)
				if !ok1 || !ok3 || (cks != "-" && !ok5) {
					fmt.println("HARNESS-ERROR bad key")
					continue
				}
				kak.keymap_manager_map_key(
					&root,
					key,
					mode_of(fields[2]),
					rkeys[:],
					unescape(fields[4]),
				)
				if cks != "-" {
					kak.keymap_manager_map_key(
						&sub,
						key,
						mode_of(fields[2]),
						ckeys[:],
						unescape(fields[6]),
					)
				}
				unmap, _ := parse_int(fields[7])
				if unmap != 0 {
					kak.keymap_manager_unmap_key(&sub, key, mode_of(fields[2]))
				}
				fmt.println(
					show_mapping(
						kak.keymap_manager_get_mapping(&sub, key, mode_of(fields[2])),
					),
				)
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "echo":
			if len(fields) == 2 {
				fmt.println(escape(unescape(fields[1])))
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case:
			fmt.println("HARNESS-ERROR bad line")
		}
	}
}
