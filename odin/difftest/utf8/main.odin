// Odin side of the utf8 differential harness. Same line protocol as
// harness.cc; see that file for the op list and escaping rules.
//
// coldist/advcol have no utf8.odin counterpart (utf8.odin does not port
// the column-measured functions), so their loops are transcribed here
// from src/utf8.hh, calling the ported utf8_read_codepoint and
// unicode_codepoint_width primitives. A mismatch there implicates the
// transcription or the ported primitives, never ported column logic.
//
// Build: odin build . -collection:kaksrc=<repo>/odin -out:bin/utf8_odin
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

// clamp_pos parses a byte offset, mirroring the C++ side exactly:
// strtoull wraps negatives to huge, and any pos > size clamps to size.
clamp_pos :: proc(s, raw: string) -> int {
	p := int(parse_i64(raw))
	if p < 0 || p > len(s) {
		return len(s)
	}
	return p
}

// Transcription of utf8::column_distance over the ported primitives.
harness_column_distance :: proc(s: string) -> int {
	dist := 0
	pos := 0
	for pos < len(s) {
		dist += kak.unicode_codepoint_width(kak.utf8_read_codepoint(s, &pos))
	}
	return dist
}

// Transcription of advance(it, end, ColumnCount) over the ported
// primitives. The C++ forward backtrack to_previous(it, begin) can
// never cross begin (it always stops at the last-read character's
// start, which is >= begin), so plain utf8_previous is exact here.
harness_advance_col :: proc(s: string, pos, d: int) -> int {
	if pos == len(s) {
		return pos
	}
	p := pos
	n := d
	if n < 0 {
		for p != len(s) && n < 0 {
			cur := p
			p = kak.utf8_previous(s, p)
			n += kak.unicode_codepoint_width(kak.utf8_codepoint(s[:cur], p))
		}
	} else if n > 0 {
		for p < len(s) && n > 0 {
			n -= kak.unicode_codepoint_width(kak.utf8_read_codepoint(s, &p))
			if p != len(s) && n < 0 {
				p = kak.utf8_previous(s, p)
			}
		}
	}
	return p
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
		case "is_start":
			if len(fields) == 2 {
				fmt.printf("%d\n", 1 if kak.utf8_is_character_start(byte(parse_u64(fields[1]))) else 0)
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "read":
			if len(fields) == 3 {
				s := unescape(fields[1])
				pos := clamp_pos(s, fields[2])
				cp := kak.utf8_read_codepoint(s, &pos)
				fmt.printf("%d %d\n", i32(cp), pos)
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "cp":
			if len(fields) == 3 {
				s := unescape(fields[1])
				pos := clamp_pos(s, fields[2])
				fmt.printf("%d\n", i32(kak.utf8_codepoint(s, pos)))
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "size_byte":
			if len(fields) == 2 {
				fmt.printf("%d\n", kak.utf8_codepoint_size_byte(byte(parse_u64(fields[1]))))
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "size_cp":
			if len(fields) == 2 {
				fmt.printf("%d\n", kak.utf8_codepoint_size_cp(rune(i32(parse_i64(fields[1])))))
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "next":
			if len(fields) == 3 {
				s := unescape(fields[1])
				pos := clamp_pos(s, fields[2])
				fmt.printf("%d\n", kak.utf8_next(s, pos))
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "finish":
			if len(fields) == 3 {
				s := unescape(fields[1])
				pos := clamp_pos(s, fields[2])
				fmt.printf("%d\n", kak.utf8_finish(s, pos))
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "previous":
			if len(fields) == 3 {
				s := unescape(fields[1])
				pos := clamp_pos(s, fields[2])
				fmt.printf("%d\n", kak.utf8_previous(s, pos))
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "charstart":
			if len(fields) == 3 {
				s := unescape(fields[1])
				pos := clamp_pos(s, fields[2])
				fmt.printf("%d\n", kak.utf8_character_start(s, pos))
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "advance":
			if len(fields) == 4 {
				s := unescape(fields[1])
				pos := clamp_pos(s, fields[2])
				d := int(parse_i64(fields[3]))
				fmt.printf("%d\n", kak.utf8_advance(s, pos, d))
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "distance":
			if len(fields) == 2 {
				fmt.printf("%d\n", kak.utf8_distance(unescape(fields[1])))
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "prevcp":
			if len(fields) == 3 {
				s := unescape(fields[1])
				pos := clamp_pos(s, fields[2])
				fmt.printf("%d\n", i32(kak.utf8_prev_codepoint(s, pos)))
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "dump":
			if len(fields) == 2 {
				buf: [4]byte
				nn := kak.utf8_dump(rune(i32(parse_i64(fields[1]))), buf[:])
				fmt.printf("%s\n", escape(string(buf[:nn])))
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "width":
			if len(fields) == 2 {
				fmt.printf("%d\n", kak.unicode_codepoint_width(rune(i32(parse_i64(fields[1])))))
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "coldist":
			if len(fields) == 2 {
				fmt.printf("%d\n", harness_column_distance(unescape(fields[1])))
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "advcol":
			if len(fields) == 4 {
				s := unescape(fields[1])
				pos := clamp_pos(s, fields[2])
				d := int(parse_i64(fields[3]))
				fmt.printf("%d\n", harness_advance_col(s, pos, d))
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
