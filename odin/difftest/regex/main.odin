// Odin side of the regex differential harness. Same line protocol as
// harness.cc; see that file for the op list and escaping rules.
//
// Build: odin build . -collection:kaksrc=<repo>/odin -out:bin/regex_odin
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

print_caps :: proc(res: ^kak.Regex_Match_Results, comma: bool) {
	n := kak.regex_match_results_size(res)
	for i := 0; i < n; i += 1 {
		if i > 0 {
			fmt.printf(comma ? "," : " ")
		}
		m := kak.regex_match_results_get(res, i)
		if !m.matched {
			fmt.printf("-")
		} else {
			fmt.printf("%d:%d", m.begin, m.end)
		}
	}
}

print_match_comma :: proc(res: ^kak.Regex_Match_Results, b: ^strings.Builder) {
	n := kak.regex_match_results_size(res)
	for i := 0; i < n; i += 1 {
		if i > 0 {
			strings.write_byte(b, ',')
		}
		m := kak.regex_match_results_get(res, i)
		if !m.matched {
			strings.write_byte(b, '-')
		} else {
			fmt.sbprintf(b, "%d:%d", m.begin, m.end)
		}
	}
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
				re, msg, err := kak.regex_make(
					unescape(fields[1]),
					cflags_of(parse_int(fields[2])),
				)
				if err != .None {
					fmt.printf("ERR %s\n", escape(msg))
					delete(msg)
				} else {
					defer kak.regex_destroy(&re)
					fmt.printf(
						"OK marks=%d saves=%d named=%d",
						kak.regex_mark_count(&re),
						re.compiled.save_count,
						len(re.compiled.named_captures),
					)
					for nc in re.compiled.named_captures {
						fmt.printf(" %s=%d", escape(nc.name), nc.index)
					}
					fmt.printf("\n")
				}
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "match":
			if len(fields) == 4 {
				cf := parse_int(fields[2]) &~ 8
				re, msg, err := kak.regex_make(unescape(fields[1]), cflags_of(cf))
				if err != .None {
					fmt.printf("ERR %s\n", escape(msg))
					delete(msg)
				} else {
					defer kak.regex_destroy(&re)
					res, matched := kak.regex_match(unescape(fields[3]), &re)
					defer kak.regex_match_results_destroy(&res)
					if matched {
						fmt.printf("YES")
						if kak.regex_match_results_size(&res) > 0 {
							fmt.printf(" ")
						}
						print_caps(&res, false)
						fmt.printf("\n")
					} else {
						fmt.println("NO")
					}
				}
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "matchs":
			if len(fields) == 4 {
				cf := parse_int(fields[2]) &~ 8
				re, msg, err := kak.regex_make(unescape(fields[1]), cflags_of(cf))
				if err != .None {
					fmt.printf("ERR %s\n", escape(msg))
					delete(msg)
				} else {
					defer kak.regex_destroy(&re)
					fmt.println(
						kak.regex_match_simple(unescape(fields[3]), &re) ? "YES" : "NO",
					)
				}
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "search", "searchs", "bsearch":
			if len(fields) == 7 {
				cf := parse_int(fields[2])
				backward := fields[0] == "bsearch"
				if backward {
					cf |= 4
				} else {
					cf &~= 8
				}
				re, msg, err := kak.regex_make(unescape(fields[1]), cflags_of(cf))
				if err != .None {
					fmt.printf("ERR %s\n", escape(msg))
					delete(msg)
				} else {
					defer kak.regex_destroy(&re)
					subj := unescape(fields[6])
					b := parse_int(fields[3])
					e := parse_int(fields[4])
					b = clamp(b, 0, len(subj))
					e = clamp(e, b, len(subj))
					xf := xflags_of(parse_int(fields[5]))
					if fields[0] == "searchs" {
						fmt.println(
							kak.regex_search_simple(subj, b, e, &re, xf) ? "YES" : "NO",
						)
					} else {
						res: kak.Regex_Match_Results
						matched := false
						if backward {
							res, matched = kak.regex_backward_search(subj, b, e, &re, xf)
						} else {
							res, matched = kak.regex_search(subj, b, e, &re, xf)
						}
						defer kak.regex_match_results_destroy(&res)
						if matched {
							fmt.printf("YES")
							if kak.regex_match_results_size(&res) > 0 {
								fmt.printf(" ")
							}
							print_caps(&res, false)
							fmt.printf("\n")
						} else {
							fmt.println("NO")
						}
					}
				}
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "iter", "biter":
			if len(fields) == 7 {
				cf := parse_int(fields[2])
				backward := fields[0] == "biter"
				if backward {
					cf |= 4
				} else {
					cf &~= 8
				}
				re, msg, err := kak.regex_make(unescape(fields[1]), cflags_of(cf))
				if err != .None {
					fmt.printf("ERR %s\n", escape(msg))
					delete(msg)
				} else {
					defer kak.regex_destroy(&re)
					subj := unescape(fields[6])
					b := parse_int(fields[3])
					e := parse_int(fields[4])
					b = clamp(b, 0, len(subj))
					e = clamp(e, b, len(subj))
					xf := xflags_of(parse_int(fields[5]))
					it := kak.regex_iterator_make(
						subj,
						b,
						e,
						&re,
						xf,
						backward,
					)
					defer kak.regex_iterator_destroy(&it)
					out := strings.builder_make(context.temp_allocator)
					count := 0
					trunc := false
					for kak.regex_iterator_next(&it) {
						if count == 500 {
							trunc = true
							break
						}
						if count > 0 {
							strings.write_byte(&out, ' ')
						}
						print_match_comma(&it.results, &out)
						count += 1
					}
					fmt.printf("N %d", count)
					if count > 0 {
						fmt.printf(" %s", strings.to_string(out))
					}
					if trunc {
						fmt.printf(" TRUNC")
					}
					fmt.printf("\n")
				}
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "named":
			if len(fields) == 4 {
				cf := parse_int(fields[2]) &~ 8
				re, msg, err := kak.regex_make(unescape(fields[1]), cflags_of(cf))
				if err != .None {
					fmt.printf("ERR %s\n", escape(msg))
					delete(msg)
				} else {
					defer kak.regex_destroy(&re)
					fmt.printf(
						"%d\n",
						kak.regex_named_capture_index(&re, unescape(fields[3])),
					)
				}
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "flags":
			if len(fields) == 5 {
				xf := kak.regex_match_flags(
					parse_int(fields[1]) != 0,
					parse_int(fields[2]) != 0,
					parse_int(fields[3]) != 0,
					parse_int(fields[4]) != 0,
				)
				bits := 0
				if .Not_Begin_Of_Line in xf {
					bits |= 2
				}
				if .Not_End_Of_Line in xf {
					bits |= 4
				}
				if .Not_Begin_Of_Word in xf {
					bits |= 8
				}
				if .Not_End_Of_Word in xf {
					bits |= 16
				}
				fmt.printf("%d\n", bits)
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "empty":
			if len(fields) == 3 {
				cf := parse_int(fields[2]) &~ 8
				re, msg, err := kak.regex_make(unescape(fields[1]), cflags_of(cf))
				if err != .None {
					fmt.printf("ERR %s\n", escape(msg))
					delete(msg)
				} else {
					defer kak.regex_destroy(&re)
					fmt.printf("%d\n", kak.regex_empty(&re) ? 1 : 0)
				}
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
