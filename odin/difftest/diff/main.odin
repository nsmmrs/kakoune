// Odin side of the diff differential harness. Same line protocol as
// harness.cc; see that file for the op list and escaping rules.
//
// Build: odin build . -collection:kaksrc=<repo>/odin -out:bin/diff_odin
package main

import kak "kaksrc:kak"

import "core:fmt"
import "core:os"
import "core:strings"

Diff_Entry :: struct {
	op:  kak.Diff_Op,
	len: int,
}

// diff_for_each_diff takes a plain proc, so runs accumulate in a global.
g_entries: [dynamic]Diff_Entry

on_diff :: proc(op: kak.Diff_Op, len: int) {
	append(&g_entries, Diff_Entry{op, len})
}

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
		case "diff":
			if len(fields) == 3 {
				clear(&g_entries)
				a := unescape(fields[1])
				b := unescape(fields[2])
				kak.diff_for_each_diff(a, b, on_diff)
				if len(g_entries) == 0 {
					fmt.println("EMPTY")
				} else {
					ob := strings.builder_make(context.temp_allocator)
					for e, i in g_entries {
						if i > 0 {
							strings.write_byte(&ob, ' ')
						}
						switch e.op {
						case .Keep:
							strings.write_byte(&ob, 'K')
						case .Add:
							strings.write_byte(&ob, 'A')
						case .Remove:
							strings.write_byte(&ob, 'R')
						}
						strings.write_int(&ob, e.len)
					}
					fmt.println(strings.to_string(ob))
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
