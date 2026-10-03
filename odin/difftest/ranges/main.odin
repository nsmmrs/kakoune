// Odin side of the ranges differential harness. Same line protocol as
// harness.cc; see that file for the op list and escaping rules.
//
// Build: odin build . -collection:kaksrc=<repo>/odin -out:bin/ranges_odin
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

parse_i64 :: proc(s: string) -> i64 {
	v, _ := strconv.parse_i64(s)
	return v
}

parse_u64 :: proc(s: string) -> u64 {
	v, _ := strconv.parse_u64(s)
	return v
}

parse_ints :: proc(s: string) -> []i64 {
	if len(s) == 0 {
		return nil
	}
	parts := strings.split(s, ",", context.temp_allocator)
	out := make([]i64, len(parts), context.temp_allocator)
	for p, i in parts {
		out[i] = parse_i64(p)
	}
	return out
}

join_ints :: proc(v: []i64) -> string {
	if len(v) == 0 {
		return "EMPTY"
	}
	b := strings.builder_make(context.temp_allocator)
	for x, i in v {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		fmt.sbprintf(&b, "%d", x)
	}
	return strings.to_string(b)
}

// Predicate ids shared with harness.cc: 0 = even, 1 = ASCII lowercase,
// 2 = high bit set.
byte_pred_0 :: proc(b: byte) -> bool { return b % 2 == 0 }
byte_pred_1 :: proc(b: byte) -> bool { return b >= 'a' && b <= 'z' }
byte_pred_2 :: proc(b: byte) -> bool { return b >= 0x80 }

byte_pred :: proc(id: int) -> proc(byte) -> bool {
	switch id {
	case 0:
		return byte_pred_0
	case 1:
		return byte_pred_1
	}
	return byte_pred_2
}

byte_tr_0 :: proc(b: byte) -> byte { return b + 1 }
byte_tr_1 :: proc(b: byte) -> byte { return 255 - b }

byte_tr :: proc(id: int) -> proc(byte) -> byte {
	if id == 0 {
		return byte_tr_0
	}
	return byte_tr_1
}

acc_add :: proc(a, b: i64) -> i64 { return a + b }
acc_mul :: proc(a, b: i64) -> i64 { return a * b }

fnb_less :: proc(a, b: i64) -> bool { return a < b }

// for_n_best funcs record visits here; reset before each op.
g_visited: [dynamic]i64

fnb_func_0 :: proc(v: i64) -> bool {
	append(&g_visited, v)
	return true
}

fnb_func_1 :: proc(v: i64) -> bool {
	append(&g_visited, v)
	return v % 2 == 0
}

fnb_func_2 :: proc(v: i64) -> bool {
	append(&g_visited, v)
	return v > 0
}

fnb_func :: proc(id: int) -> proc(i64) -> bool {
	switch id {
	case 0:
		return fnb_func_0
	case 1:
		return fnb_func_1
	}
	return fnb_func_2
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

// print_split runs a split proc and prints "<n>\t<p0>\t..." like the C++.
print_split :: proc(data: string, sep, esc: byte, mode: int) {
	pieces: [dynamic]string
	if mode == 0 {
		pieces = kak.ranges_split(data, sep, context.temp_allocator)
	} else if mode == 1 {
		pieces = kak.ranges_split_after(data, sep, context.temp_allocator)
	} else {
		pieces = kak.ranges_split_escaped(data, sep, esc, context.temp_allocator)
	}
	fmt.printf("%d", len(pieces))
	for p in pieces {
		fmt.printf("\t%s", escape(p))
	}
	fmt.println()
}

main :: proc() {
	data := read_all_stdin()
	defer delete(data)
	input := string(data[:])
	// Match C++ getline semantics: a trailing newline terminates the
	// last line instead of adding an empty one.
	lines := strings.split(input, "\n", context.allocator)
	defer delete(lines)
	if len(lines) > 0 && lines[len(lines) - 1] == "" {
		lines = lines[:len(lines) - 1]
	}
	for line, n in lines {
		// Per-line scratch lives in the temp allocator; recycle it
		// periodically so huge batches do not exhaust the arena.
		if n % 1024 == 0 {
			free_all(context.temp_allocator)
		}
		line := strings.trim_suffix(line, "\r")
		fields := strings.split(line, "\t", context.temp_allocator)
		if len(fields) == 0 {
			continue
		}
		switch fields[0] {
		case "split":
			if len(fields) == 3 {
				print_split(unescape(fields[1]), byte(parse_u64(fields[2])), 0, 0)
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "split_after":
			if len(fields) == 3 {
				print_split(unescape(fields[1]), byte(parse_u64(fields[2])), 0, 1)
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "split_esc":
			if len(fields) == 4 {
				print_split(unescape(fields[1]), byte(parse_u64(fields[2])), byte(parse_u64(fields[3])), 2)
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "reverse":
			if len(fields) == 2 {
				s := unescape(fields[1])
				r := kak.ranges_reversed(transmute([]byte)(s), context.temp_allocator)
				fmt.printf("%s\n", escape(string(r[:])))
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "skip":
			if len(fields) == 3 {
				s := unescape(fields[1])
				r := kak.ranges_skip(transmute([]byte)(s), int(parse_u64(fields[2])))
				fmt.printf("%s\n", escape(string(r)))
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "drop":
			if len(fields) == 3 {
				s := unescape(fields[1])
				r := kak.ranges_drop(transmute([]byte)(s), int(parse_u64(fields[2])))
				fmt.printf("%s\n", escape(string(r)))
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "filter":
			if len(fields) == 3 {
				s := unescape(fields[1])
				r := kak.ranges_filter(transmute([]byte)(s), byte_pred(int(parse_u64(fields[2]))), context.temp_allocator)
				fmt.printf("%s\n", escape(string(r[:])))
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "transform":
			if len(fields) == 3 {
				s := unescape(fields[1])
				r := kak.ranges_transform(transmute([]byte)(s), byte_tr(int(parse_u64(fields[2]))), context.temp_allocator)
				fmt.printf("%s\n", escape(string(r[:])))
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "enum":
			if len(fields) == 2 {
				s := unescape(fields[1])
				if len(s) == 0 {
					fmt.println("EMPTY")
				} else {
					pairs := kak.ranges_enumerate(transmute([]byte)(s), context.temp_allocator)
					b := strings.builder_make(context.temp_allocator)
					for p, i in pairs {
						if i > 0 {
							strings.write_byte(&b, ',')
						}
						fmt.sbprintf(&b, "%d:%d", p.index, p.value)
					}
					fmt.printf("%s\n", strings.to_string(b))
				}
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "find":
			if len(fields) == 3 {
				s := unescape(fields[1])
				idx, found := kak.ranges_find(transmute([]byte)(s), byte(parse_u64(fields[2])))
				fmt.printf("%d\n", idx if found else -1)
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "contains":
			if len(fields) == 3 {
				s := unescape(fields[1])
				fmt.printf("%d\n", 1 if kak.ranges_contains(transmute([]byte)(s), byte(parse_u64(fields[2]))) else 0)
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "all_of", "any_of":
			if len(fields) == 3 {
				s := unescape(fields[1])
				pred := byte_pred(int(parse_u64(fields[2])))
				r := kak.ranges_all_of(transmute([]byte)(s), pred) if fields[0] == "all_of" else kak.ranges_any_of(transmute([]byte)(s), pred)
				fmt.printf("%d\n", 1 if r else 0)
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "remove_if":
			if len(fields) == 3 {
				s := unescape(fields[1])
				tmp := make([dynamic]byte, len(s), context.temp_allocator)
				copy(tmp[:], transmute([]byte)(s))
				r := kak.ranges_remove_if(tmp[:], byte_pred(int(parse_u64(fields[2]))))
				fmt.printf("%s\n", escape(string(r)))
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "unerase":
			if len(fields) == 3 {
				s := unescape(fields[1])
				tmp := make([dynamic]byte, 0, len(s), context.temp_allocator)
				append(&tmp, ..transmute([]byte)(s))
				kak.ranges_unordered_erase(&tmp, byte(parse_u64(fields[2])))
				fmt.printf("%s\n", escape(string(tmp[:])))
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "flatten":
			if len(fields) >= 1 {
				parts := make([]string, len(fields) - 1, context.temp_allocator)
				for i := 1; i < len(fields); i += 1 {
					parts[i - 1] = unescape(fields[i])
				}
				r := kak.ranges_flatten_bytes(parts, context.temp_allocator)
				fmt.printf("%s\n", escape(string(r[:])))
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "concat":
			if len(fields) == 3 {
				a := unescape(fields[1])
				b := unescape(fields[2])
				r := kak.ranges_concatenated(transmute([]byte)(a), transmute([]byte)(b), context.temp_allocator)
				fmt.printf("%s\n", escape(string(r[:])))
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "accumulate":
			if len(fields) == 4 {
				vals := parse_ints(fields[1])
				init := parse_i64(fields[2])
				id := int(parse_u64(fields[3]))
				op := acc_add if id == 0 else acc_mul
				fmt.printf("%d\n", kak.ranges_accumulate(vals, init, op))
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "for_n_best":
			if len(fields) == 4 {
				vals := parse_ints(fields[1])
				count := int(parse_u64(fields[2]))
				delete(g_visited)
				g_visited = make([dynamic]i64, context.allocator)
				kak.ranges_for_n_best(vals, count, fnb_less, fnb_func(int(parse_u64(fields[3]))))
				fmt.printf("%s\n", join_ints(g_visited[:]))
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "static_gather":
			if len(fields) == 4 {
				vals := parse_ints(fields[1])
				nn := int(parse_u64(fields[2]))
				exact := fields[3] != "0"
				ok := false
				got: [4]i64
				n := 0
				// N is a compile-time parameter: instantiate each case.
				// N=0 is absent: `0 ..< 0` does not compile in ranges.odin.
				switch nn {
				case 1:
					r, o := kak.ranges_static_gather(vals, 1, exact)
					if o {
						got[0] = r[0]
						n = 1
					}
					ok = o
				case 2:
					r, o := kak.ranges_static_gather(vals, 2, exact)
					if o {
						got[0], got[1] = r[0], r[1]
						n = 2
					}
					ok = o
				case 3:
					r, o := kak.ranges_static_gather(vals, 3, exact)
					if o {
						got[0], got[1], got[2] = r[0], r[1], r[2]
						n = 3
					}
					ok = o
				case 4:
					r, o := kak.ranges_static_gather(vals, 4, exact)
					if o {
						got[0], got[1], got[2], got[3] = r[0], r[1], r[2], r[3]
						n = 4
					}
					ok = o
				case:
					fmt.println("HARNESS-ERROR bad line")
					continue
				}
				if ok {
					fmt.printf("%s\n", join_ints(got[:n]))
				} else {
					fmt.println("ERR")
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
	delete(g_visited)
}
