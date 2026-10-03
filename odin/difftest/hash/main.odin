// Odin side of the hash differential harness. Same line protocol as
// harness.cc; see that file for the op list and escaping rules.
//
// Build: odin build . -collection:kaksrc=<repo>/odin -out:bin/hash_odin
// Single input: echo 'murmur3 abc' | odin run . -collection:kaksrc=<repo>/odin
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
		case "murmur3":
			if len(fields) == 2 {
				fmt.printf("%d\n", u32(kak.hash_murmur3(unescape(fields[1]))))
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "fnv1a":
			if len(fields) == 2 {
				fmt.printf("%d\n", u32(kak.hash_fnv1a(unescape(fields[1]))))
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "combine":
			if len(fields) == 3 {
				a := uint(parse_u64(fields[1]))
				b := uint(parse_u64(fields[2]))
				fmt.printf("%d\n", kak.hash_combine(a, b))
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "values":
			if len(fields) >= 2 && len(fields) <= 5 {
				v: [4]uint
				for i := 1; i < len(fields); i += 1 {
					v[i - 1] = uint(parse_u64(fields[i]))
				}
				r := v[0]
				switch len(fields) {
				case 3:
					r = kak.hash_values(v[0], v[1])
				case 4:
					r = kak.hash_values(v[0], v[1], v[2])
				case 5:
					r = kak.hash_values(v[0], v[1], v[2], v[3])
				}
				fmt.printf("%d\n", r)
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
