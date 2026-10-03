// Odin side of the ranked_match differential harness. Same line protocol
// as harness.cc; see that file for the op list and escaping rules.
//
// Build: odin build . -collection:kaksrc=<repo>/odin -out:bin/ranked_match_odin
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

parse_u64 :: proc(s: string) -> u64 {
	v, _ := strconv.parse_u64(s)
	return v
}

bool_int :: proc(b: bool) -> int {
	return 1 if b else 0
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
	// Match C++ getline semantics: a trailing newline terminates the
	// last line instead of adding an empty one.
	lines := strings.split(input, "\n", context.allocator)
	defer delete(lines)
	if len(lines) > 0 && lines[len(lines) - 1] == "" {
		lines = lines[:len(lines) - 1]
	}
	for line, n in lines {
		if n % 1024 == 0 {
			free_all(context.temp_allocator)
		}
		line := strings.trim_suffix(line, "\r")
		fields := strings.split(line, "\t", context.temp_allocator)
		if len(fields) == 0 {
			continue
		}
		switch fields[0] {
		case "match":
			if len(fields) == 3 {
				c := unescape(fields[1])
				q := unescape(fields[2])
				m := kak.ranked_match_make(c, q)
				fmt.printf("%d\n", bool_int(m.matches))
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "matchL":
			if len(fields) == 3 {
				c := unescape(fields[1])
				q := unescape(fields[2])
				cl := kak.ranked_match_used_letters(c)
				ql := kak.ranked_match_used_letters(q)
				m := kak.ranked_match_make_with_letters(c, cl, q, ql)
				fmt.printf("%d\n", bool_int(m.matches))
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "cmp":
			if len(fields) == 4 {
				q := unescape(fields[1])
				a := unescape(fields[2])
				b := unescape(fields[3])
				A := kak.ranked_match_make(a, q)
				B := kak.ranked_match_make(b, q)
				if !A.matches || !B.matches {
					fmt.println("NA")
				} else {
					fmt.printf(
						"%d %d\n",
						bool_int(kak.ranked_match_less(A, B)),
						bool_int(kak.ranked_match_less(B, A)),
					)
				}
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "letters":
			if len(fields) == 2 {
				fmt.printf("%d\n", kak.ranked_match_used_letters(unescape(fields[1])))
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "lowletters":
			if len(fields) == 2 {
				v := kak.Ranked_Match_Used_Letters(parse_u64(fields[1]))
				fmt.printf("%d\n", kak.ranked_match_to_lower_letters(v))
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
