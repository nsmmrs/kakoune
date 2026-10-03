// Odin side of the faces differential harness. Same line protocol as
// harness.cc; see that file for the op list, face encoding, and
// escaping rules.
//
// Build: odin build . -collection:kaksrc=<repo>/odin -out:bin/faces_odin
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

parse_int :: proc(s: string) -> int {
	v, _ := strconv.parse_int(s)
	return v
}

attrs_of :: proc(s: string) -> (kak.Face_Attribute, bool) {
	attrs := kak.Face_Attribute{}
	for i := 0; i < len(s); i += 1 {
		switch s[i] {
		case 'u':
			attrs += {.Underline}
		case 'c':
			attrs += {.Curly_Underline}
		case 'U':
			attrs += {.Double_Underline}
		case 'r':
			attrs += {.Reverse}
		case 'b':
			attrs += {.Bold}
		case 'B':
			attrs += {.Blink}
		case 'd':
			attrs += {.Dim}
		case 'i':
			attrs += {.Italic}
		case 's':
			attrs += {.Strikethrough}
		case 'f':
			attrs += {.Final_Fg}
		case 'g':
			attrs += {.Final_Bg}
		case 'a':
			attrs += {.Final_Attr}
		case 'F':
			attrs += kak.Face_Final
		case:
			return {}, false
		}
	}
	return attrs, true
}

face_of :: proc(s: string) -> (kak.Face, bool) {
	parts := strings.split(s, "|", context.temp_allocator)
	if len(parts) != 4 {
		return {}, false
	}
	fg, fg_err := kak.color_from_string(parts[0])
	bg, bg_err := kak.color_from_string(parts[1])
	ul, ul_err := kak.color_from_string(parts[2])
	attrs, attrs_ok := attrs_of(parts[3])
	if fg_err != .None || bg_err != .None || ul_err != .None || !attrs_ok {
		return {}, false
	}
	return kak.Face{fg = fg, bg = bg, attributes = attrs, underline = ul}, true
}

show_face :: proc(f: kak.Face) -> string {
	s := kak.face_registry_face_to_string(f, context.temp_allocator)
	return s
}

show_attrs :: proc(a: kak.Face_Attribute) -> string {
	s := kak.face_registry_attributes_to_string(a, context.temp_allocator)
	return s
}

err_name :: proc(e: kak.Face_Registry_Error) -> string {
	switch e {
	case .None:
		return "None"
	case .Invalid_Description:
		return "Invalid_Description"
	case .Invalid_Color:
		return "Invalid_Color"
	case .Unknown_Attribute:
		return "Unknown_Attribute"
	case .Invalid_Name:
		return "Invalid_Name"
	case .Already_Defined:
		return "Already_Defined"
	case .Face_Cycle:
		return "Face_Cycle"
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
		case "merge":
			if len(fields) == 3 {
				f1, ok1 := face_of(unescape(fields[1]))
				f2, ok2 := face_of(unescape(fields[2]))
				if !ok1 || !ok2 {
					fmt.println("HARNESS-ERROR bad face")
				} else {
					fmt.printf("OK %s\n", show_face(kak.face_merge(f1, f2)))
				}
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "tostring":
			if len(fields) == 2 {
				f, ok := face_of(unescape(fields[1]))
				if !ok {
					fmt.println("HARNESS-ERROR bad face")
				} else {
					fmt.printf("OK %s\n", show_face(f))
				}
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "attrstr":
			if len(fields) == 2 {
				a, ok := attrs_of(unescape(fields[1]))
				if !ok {
					fmt.println("HARNESS-ERROR bad attrs")
				} else {
					fmt.printf("OK %s\n", show_attrs(a))
				}
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "parse":
			if len(fields) == 2 {
				spec, err := kak.face_registry_parse(unescape(fields[1]))
				if err != .None {
					fmt.printf("ERR %s\n", err_name(err))
				} else {
					defer kak.face_registry_spec_destroy(&spec)
					fmt.printf("OK %s @%s\n", show_face(spec.face), escape(spec.base))
				}
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "lookup":
			if len(fields) == 2 {
				reg := kak.face_registry_make()
				defer kak.face_registry_destroy(&reg)
				f, err := kak.face_registry_lookup(&reg, unescape(fields[1]))
				if err != .None {
					fmt.printf("ERR %s\n", err_name(err))
				} else {
					fmt.printf("OK %s\n", show_face(f))
				}
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "add":
			if len(fields) == 4 {
				reg := kak.face_registry_make()
				defer kak.face_registry_destroy(&reg)
				name := unescape(fields[1])
				err := kak.face_registry_add(
					&reg,
					name,
					unescape(fields[2]),
					parse_int(fields[3]) != 0,
				)
				if err != .None {
					fmt.printf("ERR %s\n", err_name(err))
				} else {
					f, lu_err := kak.face_registry_lookup(&reg, name)
					if lu_err != .None {
						fmt.printf("ERR %s\n", err_name(lu_err))
					} else {
						fmt.printf("OK %s\n", show_face(f))
					}
				}
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "chain":
			if len(fields) == 8 {
				reg := kak.face_registry_make()
				defer kak.face_registry_destroy(&reg)
				r1 := "OK"
				if kak.face_registry_add(
					&reg,
					unescape(fields[1]),
					unescape(fields[2]),
					parse_int(fields[3]) != 0,
				) != .None {
					r1 = "ERR"
				}
				r2 := "OK"
				if kak.face_registry_add(
					&reg,
					unescape(fields[4]),
					unescape(fields[5]),
					parse_int(fields[6]) != 0,
				) != .None {
					r2 = "ERR"
				}
				lu := "ERR"
				if f, lu_err := kak.face_registry_lookup(
					&reg,
					unescape(fields[7]),
				); lu_err == .None {
					b := strings.builder_make(context.temp_allocator)
					fmt.sbprintf(&b, "OK %s", show_face(f))
					lu = strings.to_string(b)
				}
				fmt.printf("ADD1 %s ADD2 %s LU %s\n", r1, r2, lu)
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "flatten":
			if len(fields) == 5 {
				reg := kak.face_registry_make()
				defer kak.face_registry_destroy(&reg)
				for i := 0; i < 2; i += 1 {
					_ = kak.face_registry_add(
						&reg,
						unescape(fields[1 + 2 * i]),
						unescape(fields[2 + 2 * i]),
					)
				}
				entries := kak.face_registry_flatten(&reg)
				defer kak.face_registry_flatten_free(&entries)
				slice.sort_by(entries[:], proc(a, b: kak.Face_Registry_Entry) -> bool {
					return a.name < b.name
				})
				fmt.printf("N %d", len(entries))
				for e in entries {
					b := strings.builder_make(context.temp_allocator)
					fmt.sbprintf(
						&b,
						"%s=%s@%s",
						escape(e.name),
						show_face(e.spec.face),
						escape(e.spec.base),
					)
					fmt.printf("\t%s", strings.to_string(b))
				}
				fmt.printf("\n")
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "child":
			if len(fields) == 4 {
				root := kak.face_registry_make()
				defer kak.face_registry_destroy(&root)
				sub := kak.face_registry_make(&root)
				defer kak.face_registry_destroy(&sub)
				add := "OK"
				if kak.face_registry_add(
					&sub,
					unescape(fields[1]),
					unescape(fields[2]),
				) != .None {
					add = "ERR"
				}
				lu := "ERR"
				if f, lu_err := kak.face_registry_lookup(
					&sub,
					unescape(fields[3]),
				); lu_err == .None {
					b := strings.builder_make(context.temp_allocator)
					fmt.sbprintf(&b, "OK %s", show_face(f))
					lu = strings.to_string(b)
				}
				fmt.printf("ADD %s LU %s\n", add, lu)
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
