// Odin side of the json differential harness. Same line protocol as
// harness.cc; see that file for the op list and escaping rules.
//
// Canonical form matches the C++ side: scalars reuse the real
// json_to_string renderer, arrays join with ", ", objects sort keys
// byte-wise and join `"k": v` pairs with ','.
//
// Build: odin build . -collection:kaksrc=<repo>/odin -out:bin/json_odin
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

// canon renders v canonically into b. Scalar rendering goes through the
// real kak.json_to_string so escaping stays under test, not hand-copied.
canon :: proc(b: ^strings.Builder, v: kak.Json_Value) {
	#partial switch t in v {
	case int, bool, string:
		s := kak.json_to_string(v, context.temp_allocator)
		strings.write_string(b, s)
	case kak.Json_Array:
		strings.write_byte(b, '[')
		for e, i in t {
			if i > 0 {
				strings.write_string(b, ", ")
			}
			canon(b, e)
		}
		strings.write_byte(b, ']')
	case kak.Json_Object:
		keys := make([dynamic]string, 0, len(t), context.temp_allocator)
		for k in t {
			append(&keys, k)
		}
		slice.sort(keys[:])
		strings.write_byte(b, '{')
		for k, i in keys {
			if i > 0 {
				strings.write_byte(b, ',')
			}
			ks := kak.json_to_string(kak.Json_Value(k), context.temp_allocator)
			strings.write_string(b, ks)
			strings.write_string(b, ": ")
			canon(b, t[k])
		}
		strings.write_byte(b, '}')
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
		case "parse":
			if len(fields) == 2 {
				doc := unescape(fields[1])
				val, err := kak.json_parse(doc, context.allocator)
				if err != kak.Json_Error.None {
					fmt.printf("ERR %v\n", err)
				} else {
					b := strings.builder_make(context.temp_allocator)
					strings.write_string(&b, "OK ")
					canon(&b, val)
					fmt.println(strings.to_string(b))
					kak.json_free(val)
				}
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "serstr":
			if len(fields) == 2 {
				raw := unescape(fields[1])
				s := kak.json_to_string(kak.Json_Value(raw), context.temp_allocator)
				fmt.println(s)
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "serint":
			if len(fields) == 2 {
				v, _ := strconv.parse_int(fields[1])
				s := kak.json_to_string(kak.Json_Value(int(v)), context.temp_allocator)
				fmt.println(s)
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "serbool":
			if len(fields) == 2 {
				s := kak.json_to_string(
					kak.Json_Value(fields[1] != "0"),
					context.temp_allocator,
				)
				fmt.println(s)
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
