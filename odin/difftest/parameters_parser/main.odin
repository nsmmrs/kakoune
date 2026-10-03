// Odin side of the parameters_parser differential harness. Same line
// protocol as harness.cc; see that file for the op list and escaping
// rules.
//
// Build: odin build . -collection:kaksrc=<repo>/odin -out:bin/parameters_parser_odin
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

flags_of :: proc(bits: int) -> kak.Parameters_Parser_Flags {
	flags := kak.Parameters_Parser_Flags{}
	if bits & 1 != 0 {
		flags += {.Switches_Only_At_Start}
	}
	if bits & 2 != 0 {
		flags += {.Switches_As_Positional}
	}
	if bits & 4 != 0 {
		flags += {.Ignore_Unknown_Switches}
	}
	return flags
}

err_name :: proc(e: kak.Parameters_Parser_Error) -> string {
	switch e {
	case .None:
		return "None"
	case .Unknown_Option:
		return "Unknown_Option"
	case .Missing_Option_Value:
		return "Missing_Option_Value"
	case .Wrong_Argument_Count:
		return "Wrong_Argument_Count"
	case .Duplicate_Switch:
		return "Duplicate_Switch"
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
		case "parse", "parseie":
			if len(fields) >= 6 {
				nsw := parse_int(fields[4])
				if nsw < 0 || len(fields) < 6 + 3 * nsw {
					fmt.println("HARNESS-ERROR bad line")
					continue
				}
				pat := 5 + 3 * nsw
				nparams := parse_int(fields[pat])
				if nparams < 0 || len(fields) != pat + 1 + nparams {
					fmt.println("HARNESS-ERROR bad line")
					continue
				}
				switches := make(
					map[string]kak.Parameters_Parser_Switch_Desc,
					nsw,
					context.temp_allocator,
				)
				for i := 0; i < nsw; i += 1 {
					name := unescape(fields[5 + 3 * i])
					takes := parse_int(fields[5 + 3 * i + 1]) != 0
					desc := unescape(fields[5 + 3 * i + 2])
					switches[name] = kak.Parameters_Parser_Switch_Desc{
						takes_argument = takes,
						description    = desc,
					}
				}
				params := make([]string, nparams, context.temp_allocator)
				for i := 0; i < nparams; i += 1 {
					params[i] = unescape(fields[pat + 1 + i])
				}
				min := parse_int(fields[2])
				mx := parse_int(fields[3])
				if mx < 0 {
					mx = max(int)
				}
				d := kak.Parameters_Parser_Desc{
					switches        = switches,
					flags           = flags_of(parse_int(fields[1])),
					min_positionals = min,
					max_positionals = mx,
				}
				p, err := kak.parameters_parser_parse(
					params,
					d,
					fields[0] == "parseie",
				)
				if err != .None {
					fmt.printf("ERR %s\n", err_name(err))
					continue
				}
				defer kak.parameters_parser_free(&p)
				out := strings.builder_make(context.temp_allocator)
				strings.write_string(&out, "OK")
				fmt.sbprintf(
					&out,
					"\t%d",
					kak.parameters_parser_positional_count(&p),
				)
				for i := 0; i < kak.parameters_parser_positional_count(&p); i += 1 {
					fmt.sbprintf(
						&out,
						"\t%s",
						escape(kak.parameters_parser_positional(&p, i)),
					)
				}
				sw := make([dynamic]string, 0, context.temp_allocator)
				for name in switches {
					if v, ok := kak.parameters_parser_get_switch(&p, name); ok {
						b := strings.builder_make(context.temp_allocator)
						fmt.sbprintf(&b, "%s=%s", escape(name), escape(v))
						append(&sw, strings.to_string(b))
					}
				}
				slice.sort(sw[:])
				fmt.sbprintf(&out, "\t%d", len(sw))
				for s in sw {
					fmt.sbprintf(&out, "\t%s", s)
				}
				st := "NONE"
				if s, ok := kak.parameters_parser_state(&p); ok {
					switch s {
					case .Switch:
						st = "Switch"
					case .Switch_Argument:
						st = "SwitchArgument"
					case .Positional:
						st = "Positional"
					}
				}
				fmt.sbprintf(&out, "\t%s", st)
				firsts := [2]int{0, 1}
				for first in firsts {
					from := kak.parameters_parser_positionals_from(&p, first)
					fmt.sbprintf(&out, "\t%d", len(from))
					for s in from {
						fmt.sbprintf(&out, "\t%s", escape(s))
					}
				}
				fmt.printf("%s\n", strings.to_string(out))
			} else {
				fmt.println("HARNESS-ERROR bad line")
			}
		case "gendoc":
			if len(fields) >= 2 {
				nsw := parse_int(fields[1])
				if nsw < 0 || len(fields) != 2 + 3 * nsw {
					fmt.println("HARNESS-ERROR bad line")
					continue
				}
				switches := make(
					map[string]kak.Parameters_Parser_Switch_Desc,
					max(nsw, 1),
					context.temp_allocator,
				)
				for i := 0; i < nsw; i += 1 {
					name := unescape(fields[2 + 3 * i])
					takes := parse_int(fields[2 + 3 * i + 1]) != 0
					desc := unescape(fields[2 + 3 * i + 2])
					switches[name] = kak.Parameters_Parser_Switch_Desc{
						takes_argument = takes,
						description    = desc,
					}
				}
				doc := kak.parameters_parser_generate_switches_doc(switches)
				defer delete(doc)
				parts := strings.split(string(doc), "\n", context.temp_allocator)
				if len(parts) > 0 && parts[len(parts) - 1] == "" {
					parts = parts[:len(parts) - 1]
				}
				slice.sort(parts)
				out := strings.builder_make(context.temp_allocator)
				fmt.sbprintf(&out, "DOC %d", len(parts))
				for s in parts {
					fmt.sbprintf(&out, "\t%s", escape(s))
				}
				fmt.printf("%s\n", strings.to_string(out))
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
