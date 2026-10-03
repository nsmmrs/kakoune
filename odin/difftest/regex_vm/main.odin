// Odin side of the regex_vm differential harness. Same line protocol
// as harness.cc; see that file for the op list and escaping rules.
//
// Build: odin build . -collection:kaksrc=<repo>/odin -out:bin/regex_vm_odin
package main

import kak "kaksrc:kak"

import "core:fmt"
import "core:os"
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

cflags_of :: proc(bits: int) -> kak.Regex_Vm_Compile_Flags {
	flags := kak.Regex_Vm_Compile_Flags{}
	if bits & 1 != 0 {
		flags += {.No_Subs}
	}
	if bits & 2 != 0 {
		flags += {.Optimize}
	}
	if bits & 4 != 0 {
		flags += {.Backward}
	}
	if bits & 8 != 0 {
		flags += {.No_Forward}
	}
	return flags
}

xflags_of :: proc(bits: int) -> kak.Regex_Vm_Exec_Flags {
	flags := kak.Regex_Vm_Exec_Flags{}
	if bits & 2 != 0 {
		flags += {.Not_Begin_Of_Line}
	}
	if bits & 4 != 0 {
		flags += {.Not_End_Of_Line}
	}
	if bits & 8 != 0 {
		flags += {.Not_Begin_Of_Word}
	}
	if bits & 16 != 0 {
		flags += {.Not_End_Of_Word}
	}
	if bits & 32 != 0 {
		flags += {.Not_Initial_Null}
	}
	return flags
}

mode_of :: proc(bits: int) -> kak.Regex_Vm_Modes {
	mode := kak.Regex_Vm_Modes{}
	if bits & 1 != 0 {
		mode += {.Forward}
	}
	if bits & 2 != 0 {
		mode += {.Backward}
	}
	if bits & 4 != 0 {
		mode += {.Search}
	}
	if bits & 8 != 0 {
		mode += {.Any_Match}
	}
	if bits & 16 != 0 {
		mode += {.No_Saves}
	}
	return mode
}

start_desc_str :: proc(has: bool, desc: kak.Regex_Vm_Start_Desc) -> string {
	if !has {
		return "-"
	}
	digits := "0123456789abcdef"
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "%d:%d:", desc.start_byte, desc.offset)
	for i := 0; i < 256; i += 4 {
		v := 0
		for k := 0; k < 4; k += 1 {
			if desc.bytes[i + k] {
				v |= 1 << uint(k)
			}
		}
		strings.write_byte(&b, digits[v])
	}
	return strings.to_string(b)
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
		case "compile":
			if len(fields) == 3 {
				prog, msg, err := kak.regex_vm_compile(
					unescape(fields[1]),
					cflags_of(parse_int(fields[2])),
				)
				if err != .None {
					fmt.printf("ERR %s\n", escape(msg))
					delete(msg)
				} else {
					defer kak.regex_vm_compiled_destroy(&prog)
					fmt.printf(
						"OK saves=%d ninst=%d nclass=%d nlook=%d bwd=%d named=%d",
						prog.save_count,
						len(prog.instructions),
						len(prog.char_classes),
						len(prog.lookarounds),
						prog.first_backward_inst >= 0 ? 1 : 0,
						len(prog.named_captures),
					)
					for nc in prog.named_captures {
						fmt.printf(" %s=%d", escape(nc.name), nc.index)
					}
					fmt.printf(
						" F %s B %s\n",
						start_desc_str(prog.has_forward_start, prog.forward_start),
						start_desc_str(prog.has_backward_start, prog.backward_start),
					)
				}
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "exec":
			if len(fields) == 10 {
				mode_bits := parse_int(fields[3])
				forward := mode_bits & 1 != 0 && mode_bits & 2 == 0
				backward := mode_bits & 2 != 0 && mode_bits & 1 == 0
				if !forward && !backward {
					fmt.println("HARNESS-ERROR bad mode")
					continue
				}
				cf := parse_int(fields[2])
				if backward {
					cf |= 4
				} else {
					cf &~= 8
				}
				prog, msg, err := kak.regex_vm_compile(
					unescape(fields[1]),
					cflags_of(cf),
				)
				if err != .None {
					fmt.printf("ERR %s\n", escape(msg))
					delete(msg)
					continue
				}
				defer kak.regex_vm_compiled_destroy(&prog)
				subj := unescape(fields[9])
				b := clamp(parse_int(fields[4]), 0, len(subj))
				e := clamp(parse_int(fields[5]), b, len(subj))
				sb := clamp(parse_int(fields[6]), 0, len(subj))
				se := clamp(parse_int(fields[7]), sb, len(subj))
				xf := xflags_of(parse_int(fields[8]))
				mode := mode_of(mode_bits)
				vm := kak.regex_vm_make(&prog, mode)
				defer kak.regex_vm_destroy(&vm)
				found := kak.regex_vm_exec(&vm, subj, b, e, sb, se, xf)
				if found {
					if .No_Saves in mode {
						fmt.println("YES")
					} else {
						caps := kak.regex_vm_captures(&vm)
						if len(caps) == 0 {
							fmt.println("YES")
						} else {
							fmt.printf("YES")
							for i := 0; i < len(caps); i += 2 {
								fmt.printf(" ")
								if caps[i] < 0 || caps[i + 1] < 0 {
									fmt.printf("-")
								} else {
									fmt.printf("%d:%d", caps[i], caps[i + 1])
								}
							}
							fmt.printf("\n")
						}
					}
				} else {
					fmt.println("NO")
				}
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "ctype":
			if len(fields) == 3 {
				mask := u8(parse_int(fields[1]) & 0xFF)
				cp := rune(parse_int(fields[2]))
				ct := transmute(kak.Regex_Vm_Char_Types)mask
				fmt.printf("%d\n", kak.regex_vm_is_ctype(ct, cp) ? 1 : 0)
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
