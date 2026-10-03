// Port of Kakoune's src/parameters_parser.{hh,cc}: command parameter parsing.
//
// ParametersParser splits raw command params into positional arguments and
// named switches (`-name` for booleans, `-name value` for valued switches),
// honouring the ParameterDesc flags (SwitchesOnlyAtStart,
// SwitchesAsPositional, IgnoreUnknownSwitches) and the positional count
// bounds. generate_switches_doc renders the aligned help listing.
//
// Deviations from the C++:
//   * The ArgCompleter callback needs Context (not ported), so
//     Parameters_Parser_Switch_Desc keeps only takes_argument (the
//     presence of the completer, which is all the parser observes) plus
//     the description.
//   * The parameter_error exception hierarchy becomes
//     Parameters_Parser_Error; the interpolated messages are available
//     through parameters_parser_error_message.
//   * C++ state() on an empty parse dereferences an empty Optional
//     (undefined behavior); here parameters_parser_state reports ok=false.
//   * Positional iteration (C++ begin/end) is a plain index loop over
//     parameters_parser_positional_count / parameters_parser_positional.
//
// Ownership: the parser borrows params and the desc; both must outlive it.
// Switch keys and values borrow param strings, so parameters_parser_free
// only releases the index array and the map itself. On error the returned
// parser is zero and owns nothing.
package kak

import "core:strings"

// Parameters_Parser_Error reports parameter parsing failures. Zero value
// `None` is success.
Parameters_Parser_Error :: enum {
	None,
	// An unknown `-name` switch was given (C++ unknown_option).
	Unknown_Option,
	// A switch expecting an argument had none left (C++ missing_option_value).
	Missing_Option_Value,
	// Positional count outside [min, max] (C++ wrong_argument_count).
	Wrong_Argument_Count,
	// A switch was specified more than once (C++ runtime_error).
	Duplicate_Switch,
}

// parameters_parser_error_message renders the C++ exception message for err.
// name is the offending token: the full `-name` param for Unknown_Option,
// the bare switch key for Missing_Option_Value and Duplicate_Switch, and
// unused otherwise. Caller frees the result.
parameters_parser_error_message :: proc(
	err: Parameters_Parser_Error,
	name := "",
	allocator := context.allocator,
) -> string {
	switch err {
	case .None:
		return ""
	case .Unknown_Option:
		return strings.concatenate({"unknown option '", name, "'"}, allocator)
	case .Missing_Option_Value:
		return strings.concatenate({"missing value for option '", name, "'"}, allocator)
	case .Wrong_Argument_Count:
		return strings.clone("wrong argument count", allocator)
	case .Duplicate_Switch:
		return strings.concatenate({"switch '-", name, "' specified more than once"}, allocator)
	}
	unreachable()
}

// Parameters_Parser_Switch_Desc describes one named switch (port of C++
// SwitchDesc; the completer itself is dropped, see the header comment).
Parameters_Parser_Switch_Desc :: struct {
	takes_argument: bool,
	description:    string,
}

// Parameters_Parser_Flag lists the parse-mode flags (port of C++
// ParameterDesc::Flags).
Parameters_Parser_Flag :: enum {
	// Once a positional is seen, everything after is positional.
	Switches_Only_At_Start,
	// Every param is positional, even `-looking` ones and `--`.
	Switches_As_Positional,
	// Unknown `-looking` params become positionals instead of errors.
	Ignore_Unknown_Switches,
}

// Parameters_Parser_Flags is a set of parse-mode flags.
Parameters_Parser_Flags :: bit_set[Parameters_Parser_Flag]

// Parameters_Parser_Desc describes the accepted switches, the parse-mode
// flags and the positional count bounds (port of C++ ParameterDesc).
// max_positionals of max(int) means unlimited (C++ default of -1).
// The switches map is borrowed by parameters_parser_parse.
Parameters_Parser_Desc :: struct {
	switches:        map[string]Parameters_Parser_Switch_Desc,
	flags:           Parameters_Parser_Flags,
	min_positionals: int,
	max_positionals: int,
}

// Parameters_Parser_State classifies the last consumed param (port of C++
// ParametersParser::State).
Parameters_Parser_State :: enum {
	Switch,
	Switch_Argument,
	Positional,
}

// Parameters_Parser is a parsed parameter list (port of C++
// ParametersParser). params is borrowed; positional_indices and the switches
// map are owned (keys/values borrow params); state is unset when params is
// empty. Release with parameters_parser_free.
Parameters_Parser :: struct {
	params:             []string,
	positional_indices: [dynamic]int,
	switches:           map[string]string,
	state:              Maybe(Parameters_Parser_State),
}

// parameters_parser_parse parses params against desc (port of the C++
// ParametersParser constructor). With ignore_errors, unknown, duplicated
// and missing-value switches are skipped and the positional count is not
// checked (like the C++ ignore_errors constructor used for completion).
// On error the returned parser is zero and owns nothing.
parameters_parser_parse :: proc(
	params: []string,
	desc: Parameters_Parser_Desc,
	ignore_errors := false,
	allocator := context.allocator,
) -> (Parameters_Parser, Parameters_Parser_Error) {
	p := Parameters_Parser {
		params = params,
	}
	p.positional_indices = make([dynamic]int, 0, len(params), allocator)
	p.switches = make(map[string]string, len(params), allocator)

	switches_only_at_start := Parameters_Parser_Flag.Switches_Only_At_Start in desc.flags
	ignore_unknown := Parameters_Parser_Flag.Ignore_Unknown_Switches in desc.flags
	only_pos := Parameters_Parser_Flag.Switches_As_Positional in desc.flags

	i := 0
	for i < len(params) {
		s := params[i]
		if !only_pos && !ignore_unknown && s == "--" {
			p.state = Parameters_Parser_State.Switch
			only_pos = true
		} else if !only_pos && len(s) > 0 && s[0] == '-' {
			name := s[1:]
			d, known := desc.switches[name]
			if ignore_unknown && !known {
				p.state = Parameters_Parser_State.Positional
			} else {
				p.state = Parameters_Parser_State.Switch
			}
			if !known {
				if ignore_unknown {
					append(&p.positional_indices, i)
					if switches_only_at_start {
						only_pos = true
					}
					i += 1
					continue
				}
				if ignore_errors {
					i += 1
					continue
				}
				return parameters_parser_fail(&p, .Unknown_Option)
			}
			if name in p.switches {
				if ignore_errors {
					i += 1
					continue
				}
				return parameters_parser_fail(&p, .Duplicate_Switch)
			}
			arg := ""
			if d.takes_argument {
				i += 1
				if i == len(params) {
					if ignore_errors {
						continue
					}
					return parameters_parser_fail(&p, .Missing_Option_Value)
				}
				p.state = Parameters_Parser_State.Switch_Argument
				arg = params[i]
			}
			p.switches[name] = arg
		} else {
			p.state = Parameters_Parser_State.Positional
			if switches_only_at_start {
				only_pos = true
			}
			append(&p.positional_indices, i)
		}
		i += 1
	}

	count := len(p.positional_indices)
	if !ignore_errors && (count > desc.max_positionals || count < desc.min_positionals) {
		return parameters_parser_fail(&p, .Wrong_Argument_Count)
	}
	return p, .None
}

// parameters_parser_fail releases a half-built parser and reports err.
@(private = "file")
parameters_parser_fail :: proc(
	p: ^Parameters_Parser,
	err: Parameters_Parser_Error,
) -> (Parameters_Parser, Parameters_Parser_Error) {
	parameters_parser_free(p)
	return {}, err
}

// parameters_parser_free releases the parser's index array and switch map.
// The borrowed params and desc are untouched. Dynamic arrays and maps free
// through the ambient allocator, so this must run with the parse allocator
// ambient (same shape as json_free).
parameters_parser_free :: proc(p: ^Parameters_Parser) {
	delete(p.positional_indices)
	delete(p.switches)
	p^ = {}
}

// parameters_parser_get_switch returns the switch value if -name was given:
// the consumed argument for valued switches, "" for boolean ones (port of
// C++ ParametersParser::get_switch, whose Optional becomes (value, ok)).
parameters_parser_get_switch :: proc(p: ^Parameters_Parser, name: string) -> (string, bool) {
	v, ok := p.switches[name]
	return v, ok
}

// parameters_parser_positional_count returns the positional count (port of
// C++ ParametersParser::positional_count).
parameters_parser_positional_count :: proc(p: ^Parameters_Parser) -> int {
	return len(p.positional_indices)
}

// parameters_parser_positional returns positional index (port of C++
// operator[]; index must be below the positional count, like the C++
// kak_assert).
parameters_parser_positional :: proc(p: ^Parameters_Parser, index: int) -> string {
	return p.params[p.positional_indices[index]]
}

// parameters_parser_positionals_from returns the raw params from the first
// raw index of positional first to the end (port of C++ positionals_from,
// whose subrange(-1) empty case becomes the empty slice here). Only
// meaningful with Switches_Only_At_Start or Switches_As_Positional, where
// positionals are contiguous raw params.
parameters_parser_positionals_from :: proc(p: ^Parameters_Parser, first: int) -> []string {
	if first < len(p.positional_indices) {
		return p.params[p.positional_indices[first]:]
	}
	return {}
}

// parameters_parser_state classifies the last consumed param (port of C++
// ParametersParser::state). ok is false when params was empty.
parameters_parser_state :: proc(p: ^Parameters_Parser) -> (Parameters_Parser_State, bool) {
	s, ok := p.state.?
	return s, ok
}

// parameters_parser_generate_switches_doc renders the aligned `-switch
// [<arg>] description` listing (port of C++ generate_switches_doc).
// Widths are display columns via string_utils_column_length. Empty input
// yields "". Caller frees the result.
parameters_parser_generate_switches_doc :: proc(
	switches: map[string]Parameters_Parser_Switch_Desc,
	allocator := context.allocator,
) -> string {
	b := strings.builder_make(0, len(switches) * 32, allocator)
	if len(switches) == 0 {
		return strings.to_string(b)
	}
	switch_len :: proc(key: string, takes_argument: bool) -> int {
		arg := 0
		if takes_argument {
			arg = 5
		}
		return string_utils_column_length(key) + arg
	}
	max_len := 0
	for key, desc in switches {
		max_len = max(max_len, switch_len(key, desc.takes_argument))
	}
	for key, desc in switches {
		strings.write_string(&b, "-")
		strings.write_string(&b, key)
		strings.write_string(&b, " ")
		if desc.takes_argument {
			strings.write_string(&b, "<arg>")
		}
		for _ in 0 ..< max_len - switch_len(key, desc.takes_argument) + 1 {
			strings.write_byte(&b, ' ')
		}
		strings.write_string(&b, desc.description)
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}
