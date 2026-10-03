// Tests for the parameters_parser port. src/parameters_parser.cc has no C++
// UnitTest, so these pin the constructor/doc semantics against the C++
// source line by line, plus edge cases (empty input, lone dash, `--`
// handling, ignore_errors subtleties).
package kak

import "core:strings"
import "core:testing"

// parameters_parser_test_expect_strings checks a string slice element-wise
// (testing.expect_value needs comparable values, which slices are not).
parameters_parser_test_expect_strings :: proc(t: ^testing.T, got, want: []string) {
	testing.expect_value(t, len(got), len(want))
	for w, i in want {
		if i < len(got) {
			testing.expect_value(t, got[i], w)
		}
	}
}

// parameters_parser_test_desc builds a desc with a boolean "scratch" and a
// valued "fifo" switch. Caller owns desc.switches.
parameters_parser_test_desc :: proc(
	flags: Parameters_Parser_Flags,
	min, max: int,
	allocator := context.allocator,
) -> Parameters_Parser_Desc {
	switches := make(map[string]Parameters_Parser_Switch_Desc, allocator)
	switches["scratch"] = {false, "create a scratch buffer"}
	switches["fifo"] = {true, "read its content from a named fifo"}
	return {switches, flags, min, max}
}

// plain positionals, no switches given
@(test)
parameters_parser_test_positionals_only :: proc(t: ^testing.T) {
	desc := parameters_parser_test_desc({}, 0, 3)
	defer delete(desc.switches)
	p, err := parameters_parser_parse({"a", "b"}, desc)
	testing.expect_value(t, err, Parameters_Parser_Error.None)
	if err != .None {
		return
	}
	defer parameters_parser_free(&p)
	testing.expect_value(t, parameters_parser_positional_count(&p), 2)
	testing.expect_value(t, parameters_parser_positional(&p, 0), "a")
	testing.expect_value(t, parameters_parser_positional(&p, 1), "b")
	_, ok := parameters_parser_get_switch(&p, "scratch")
	testing.expect(t, !ok)
	st, has_state := parameters_parser_state(&p)
	testing.expect(t, has_state)
	testing.expect_value(t, st, Parameters_Parser_State.Positional)
}

// boolean switch plus a positional
@(test)
parameters_parser_test_bool_switch :: proc(t: ^testing.T) {
	desc := parameters_parser_test_desc({}, 0, max(int))
	defer delete(desc.switches)
	p, err := parameters_parser_parse({"-scratch", "file"}, desc)
	testing.expect_value(t, err, Parameters_Parser_Error.None)
	if err != .None {
		return
	}
	defer parameters_parser_free(&p)
	v, ok := parameters_parser_get_switch(&p, "scratch")
	testing.expect(t, ok)
	testing.expect_value(t, v, "")
	testing.expect_value(t, parameters_parser_positional_count(&p), 1)
	testing.expect_value(t, parameters_parser_positional(&p, 0), "file")
	_, fifo_ok := parameters_parser_get_switch(&p, "fifo")
	testing.expect(t, !fifo_ok)
}

// valued switch consumes the next param as its argument
@(test)
parameters_parser_test_arg_switch :: proc(t: ^testing.T) {
	desc := parameters_parser_test_desc({}, 0, max(int))
	defer delete(desc.switches)
	p, err := parameters_parser_parse({"-fifo", "pipe", "out"}, desc)
	testing.expect_value(t, err, Parameters_Parser_Error.None)
	if err != .None {
		return
	}
	defer parameters_parser_free(&p)
	v, ok := parameters_parser_get_switch(&p, "fifo")
	testing.expect(t, ok)
	testing.expect_value(t, v, "pipe")
	testing.expect_value(t, parameters_parser_positional_count(&p), 1)
	testing.expect_value(t, parameters_parser_positional(&p, 0), "out")
}

// state tracks the last consumed param kind
@(test)
parameters_parser_test_states :: proc(t: ^testing.T) {
	desc := parameters_parser_test_desc({}, 0, max(int))
	defer delete(desc.switches)
	p1, err1 := parameters_parser_parse({"-scratch"}, desc)
	testing.expect_value(t, err1, Parameters_Parser_Error.None)
	if err1 != .None {
		return
	}
	defer parameters_parser_free(&p1)
	st1, ok1 := parameters_parser_state(&p1)
	testing.expect(t, ok1)
	testing.expect_value(t, st1, Parameters_Parser_State.Switch)

	p2, err2 := parameters_parser_parse({"-fifo", "pipe"}, desc)
	testing.expect_value(t, err2, Parameters_Parser_Error.None)
	if err2 != .None {
		return
	}
	defer parameters_parser_free(&p2)
	st2, ok2 := parameters_parser_state(&p2)
	testing.expect(t, ok2)
	testing.expect_value(t, st2, Parameters_Parser_State.Switch_Argument)
}

// `--` ends switch parsing; the rest is positional
@(test)
parameters_parser_test_double_dash :: proc(t: ^testing.T) {
	desc := parameters_parser_test_desc({}, 0, max(int))
	defer delete(desc.switches)
	p, err := parameters_parser_parse({"-scratch", "--", "-fifo", "x"}, desc)
	testing.expect_value(t, err, Parameters_Parser_Error.None)
	if err != .None {
		return
	}
	defer parameters_parser_free(&p)
	_, ok := parameters_parser_get_switch(&p, "scratch")
	testing.expect(t, ok)
	_, fifo_ok := parameters_parser_get_switch(&p, "fifo")
	testing.expect(t, !fifo_ok)
	testing.expect_value(t, parameters_parser_positional_count(&p), 2)
	testing.expect_value(t, parameters_parser_positional(&p, 0), "-fifo")
	testing.expect_value(t, parameters_parser_positional(&p, 1), "x")
}

// unknown switch is an error; the failed parser owns nothing
@(test)
parameters_parser_test_unknown_option :: proc(t: ^testing.T) {
	desc := parameters_parser_test_desc({}, 0, max(int))
	defer delete(desc.switches)
	p, err := parameters_parser_parse({"-bogus"}, desc)
	testing.expect_value(t, err, Parameters_Parser_Error.Unknown_Option)
	testing.expect(t, p.switches == nil)
	testing.expect_value(t, len(p.positional_indices), 0)
}

// valued switch at the end has no argument
@(test)
parameters_parser_test_missing_value :: proc(t: ^testing.T) {
	desc := parameters_parser_test_desc({}, 0, max(int))
	defer delete(desc.switches)
	_, err := parameters_parser_parse({"-fifo"}, desc)
	testing.expect_value(t, err, Parameters_Parser_Error.Missing_Option_Value)
	// the missing value is only missing at the very end
	p, err2 := parameters_parser_parse({"-fifo", "-scratch"}, desc)
	testing.expect_value(t, err2, Parameters_Parser_Error.None)
	if err2 != .None {
		return
	}
	defer parameters_parser_free(&p)
	v, ok := parameters_parser_get_switch(&p, "fifo")
	testing.expect(t, ok)
	testing.expect_value(t, v, "-scratch")
}

// positional count bounds, including exact boundaries
@(test)
parameters_parser_test_wrong_count :: proc(t: ^testing.T) {
	desc := parameters_parser_test_desc({}, 1, 2)
	defer delete(desc.switches)
	_, err_none := parameters_parser_parse({}, desc)
	testing.expect_value(t, err_none, Parameters_Parser_Error.Wrong_Argument_Count)
	_, err_many := parameters_parser_parse({"a", "b", "c"}, desc)
	testing.expect_value(t, err_many, Parameters_Parser_Error.Wrong_Argument_Count)
	p1, err1 := parameters_parser_parse({"a"}, desc)
	testing.expect_value(t, err1, Parameters_Parser_Error.None)
	if err1 == .None {
		defer parameters_parser_free(&p1)
	}
	p2, err2 := parameters_parser_parse({"a", "b"}, desc)
	testing.expect_value(t, err2, Parameters_Parser_Error.None)
	if err2 == .None {
		defer parameters_parser_free(&p2)
	}
}

// repeated switch is an error
@(test)
parameters_parser_test_duplicate :: proc(t: ^testing.T) {
	desc := parameters_parser_test_desc({}, 0, max(int))
	defer delete(desc.switches)
	_, err := parameters_parser_parse({"-scratch", "-scratch"}, desc)
	testing.expect_value(t, err, Parameters_Parser_Error.Duplicate_Switch)
}

// ignore_errors skips bad switches and the count check
@(test)
parameters_parser_test_ignore_errors :: proc(t: ^testing.T) {
	desc := parameters_parser_test_desc({}, 1, 1)
	defer delete(desc.switches)
	// unknown and duplicate switches are skipped, count unchecked
	p, err := parameters_parser_parse({"-bogus", "-scratch", "-scratch"}, desc, true)
	testing.expect_value(t, err, Parameters_Parser_Error.None)
	if err != .None {
		return
	}
	defer parameters_parser_free(&p)
	_, ok := parameters_parser_get_switch(&p, "scratch")
	testing.expect(t, ok)
	testing.expect_value(t, parameters_parser_positional_count(&p), 0)

	// trailing valued switch is skipped without recording anything
	p2, err2 := parameters_parser_parse({"-fifo"}, desc, true)
	testing.expect_value(t, err2, Parameters_Parser_Error.None)
	if err2 != .None {
		return
	}
	defer parameters_parser_free(&p2)
	_, fifo_ok := parameters_parser_get_switch(&p2, "fifo")
	testing.expect(t, !fifo_ok)
}

// ignore_errors keeps the first occurrence; a duplicated valued switch
// does NOT consume the next param (mirrors the C++ continue placement)
@(test)
parameters_parser_test_ignore_errors_duplicate_arg :: proc(t: ^testing.T) {
	desc := parameters_parser_test_desc({}, 0, max(int))
	defer delete(desc.switches)
	p, err := parameters_parser_parse({"-fifo", "a", "-fifo", "b"}, desc, true)
	testing.expect_value(t, err, Parameters_Parser_Error.None)
	if err != .None {
		return
	}
	defer parameters_parser_free(&p)
	v, ok := parameters_parser_get_switch(&p, "fifo")
	testing.expect(t, ok)
	testing.expect_value(t, v, "a")
	testing.expect_value(t, parameters_parser_positional_count(&p), 1)
	testing.expect_value(t, parameters_parser_positional(&p, 0), "b")
}

// SwitchesOnlyAtStart: switch-like params after a positional are positional
@(test)
parameters_parser_test_switches_only_at_start :: proc(t: ^testing.T) {
	flags := Parameters_Parser_Flags{.Switches_Only_At_Start}
	desc := parameters_parser_test_desc(flags, 0, max(int))
	defer delete(desc.switches)
	p, err := parameters_parser_parse({"-scratch", "pos", "-zzz"}, desc)
	testing.expect_value(t, err, Parameters_Parser_Error.None)
	if err != .None {
		return
	}
	defer parameters_parser_free(&p)
	_, ok := parameters_parser_get_switch(&p, "scratch")
	testing.expect(t, ok)
	testing.expect_value(t, parameters_parser_positional_count(&p), 2)
	testing.expect_value(t, parameters_parser_positional(&p, 0), "pos")
	testing.expect_value(t, parameters_parser_positional(&p, 1), "-zzz")
}

// SwitchesAsPositional: everything is positional, even `--` and known switches
@(test)
parameters_parser_test_switches_as_positional :: proc(t: ^testing.T) {
	flags := Parameters_Parser_Flags{.Switches_As_Positional}
	desc := parameters_parser_test_desc(flags, 0, max(int))
	defer delete(desc.switches)
	p, err := parameters_parser_parse({"--", "-scratch", "x"}, desc)
	testing.expect_value(t, err, Parameters_Parser_Error.None)
	if err != .None {
		return
	}
	defer parameters_parser_free(&p)
	_, ok := parameters_parser_get_switch(&p, "scratch")
	testing.expect(t, !ok)
	testing.expect_value(t, parameters_parser_positional_count(&p), 3)
	testing.expect_value(t, parameters_parser_positional(&p, 0), "--")
	testing.expect_value(t, parameters_parser_positional(&p, 1), "-scratch")
	st, has_state := parameters_parser_state(&p)
	testing.expect(t, has_state)
	testing.expect_value(t, st, Parameters_Parser_State.Positional)
}

// IgnoreUnknownSwitches: unknown `-looking` params become positionals
@(test)
parameters_parser_test_ignore_unknown_switches :: proc(t: ^testing.T) {
	flags := Parameters_Parser_Flags{.Ignore_Unknown_Switches}
	desc := parameters_parser_test_desc(flags, 0, max(int))
	defer delete(desc.switches)
	p, err := parameters_parser_parse({"-bogus", "-scratch", "x"}, desc)
	testing.expect_value(t, err, Parameters_Parser_Error.None)
	if err != .None {
		return
	}
	defer parameters_parser_free(&p)
	_, ok := parameters_parser_get_switch(&p, "scratch")
	testing.expect(t, ok)
	testing.expect_value(t, parameters_parser_positional_count(&p), 2)
	testing.expect_value(t, parameters_parser_positional(&p, 0), "-bogus")
	testing.expect_value(t, parameters_parser_positional(&p, 1), "x")

	// `--` loses its separator meaning and is positional too
	p2, err2 := parameters_parser_parse({"--"}, desc)
	testing.expect_value(t, err2, Parameters_Parser_Error.None)
	if err2 != .None {
		return
	}
	defer parameters_parser_free(&p2)
	testing.expect_value(t, parameters_parser_positional_count(&p2), 1)
	testing.expect_value(t, parameters_parser_positional(&p2, 0), "--")
	st, has_state := parameters_parser_state(&p2)
	testing.expect(t, has_state)
	testing.expect_value(t, st, Parameters_Parser_State.Positional)
}

// unknown switch plus SwitchesOnlyAtStart flips to positional-only mode
@(test)
parameters_parser_test_ignore_unknown_at_start :: proc(t: ^testing.T) {
	flags := Parameters_Parser_Flags{.Ignore_Unknown_Switches, .Switches_Only_At_Start}
	desc := parameters_parser_test_desc(flags, 0, max(int))
	defer delete(desc.switches)
	p, err := parameters_parser_parse({"-bogus", "-scratch"}, desc)
	testing.expect_value(t, err, Parameters_Parser_Error.None)
	if err != .None {
		return
	}
	defer parameters_parser_free(&p)
	_, ok := parameters_parser_get_switch(&p, "scratch")
	testing.expect(t, !ok)
	testing.expect_value(t, parameters_parser_positional_count(&p), 2)
}

// positionals_from slices raw params from a positional's raw index
@(test)
parameters_parser_test_positionals_from :: proc(t: ^testing.T) {
	flags := Parameters_Parser_Flags{.Switches_Only_At_Start}
	desc := parameters_parser_test_desc(flags, 0, max(int))
	defer delete(desc.switches)
	p, err := parameters_parser_parse({"-scratch", "a", "b"}, desc)
	testing.expect_value(t, err, Parameters_Parser_Error.None)
	if err != .None {
		return
	}
	defer parameters_parser_free(&p)
	parameters_parser_test_expect_strings(t, parameters_parser_positionals_from(&p, 0), {"a", "b"})
	parameters_parser_test_expect_strings(t, parameters_parser_positionals_from(&p, 1), {"b"})
	testing.expect_value(t, len(parameters_parser_positionals_from(&p, 2)), 0)

	// without the flag the slice keeps interleaved switches (raw subrange)
	desc2 := parameters_parser_test_desc({}, 0, max(int))
	defer delete(desc2.switches)
	q, err2 := parameters_parser_parse({"a", "-scratch", "b"}, desc2)
	testing.expect_value(t, err2, Parameters_Parser_Error.None)
	if err2 != .None {
		return
	}
	defer parameters_parser_free(&q)
	parameters_parser_test_expect_strings(
		t,
		parameters_parser_positionals_from(&q, 0),
		{"a", "-scratch", "b"},
	)
}

// empty input: no positionals, no state
@(test)
parameters_parser_test_empty_params :: proc(t: ^testing.T) {
	desc := parameters_parser_test_desc({}, 0, max(int))
	defer delete(desc.switches)
	p, err := parameters_parser_parse({}, desc)
	testing.expect_value(t, err, Parameters_Parser_Error.None)
	if err != .None {
		return
	}
	defer parameters_parser_free(&p)
	testing.expect_value(t, parameters_parser_positional_count(&p), 0)
	_, has_state := parameters_parser_state(&p)
	testing.expect(t, !has_state)
}

// lone `-` is an (empty-named) unknown switch
@(test)
parameters_parser_test_single_dash :: proc(t: ^testing.T) {
	desc := parameters_parser_test_desc({}, 0, max(int))
	defer delete(desc.switches)
	_, err := parameters_parser_parse({"-"}, desc)
	testing.expect_value(t, err, Parameters_Parser_Error.Unknown_Option)

	flags := Parameters_Parser_Flags{.Ignore_Unknown_Switches}
	desc2 := parameters_parser_test_desc(flags, 0, max(int))
	defer delete(desc2.switches)
	p, err2 := parameters_parser_parse({"-"}, desc2)
	testing.expect_value(t, err2, Parameters_Parser_Error.None)
	if err2 != .None {
		return
	}
	defer parameters_parser_free(&p)
	testing.expect_value(t, parameters_parser_positional_count(&p), 1)
	testing.expect_value(t, parameters_parser_positional(&p, 0), "-")
}

// empty-string params are positional
@(test)
parameters_parser_test_empty_string_param :: proc(t: ^testing.T) {
	desc := parameters_parser_test_desc({}, 0, max(int))
	defer delete(desc.switches)
	p, err := parameters_parser_parse({""}, desc)
	testing.expect_value(t, err, Parameters_Parser_Error.None)
	if err != .None {
		return
	}
	defer parameters_parser_free(&p)
	testing.expect_value(t, parameters_parser_positional_count(&p), 1)
	testing.expect_value(t, parameters_parser_positional(&p, 0), "")
}

// error messages match the C++ exception texts
@(test)
parameters_parser_test_error_messages :: proc(t: ^testing.T) {
	msg_none := parameters_parser_error_message(.None)
	testing.expect_value(t, msg_none, "")
	unknown := parameters_parser_error_message(.Unknown_Option, "-bogus")
	defer delete(unknown)
	testing.expect_value(t, unknown, "unknown option '-bogus'")
	missing := parameters_parser_error_message(.Missing_Option_Value, "fifo")
	defer delete(missing)
	testing.expect_value(t, missing, "missing value for option 'fifo'")
	count := parameters_parser_error_message(.Wrong_Argument_Count)
	defer delete(count)
	testing.expect_value(t, count, "wrong argument count")
	dup := parameters_parser_error_message(.Duplicate_Switch, "scratch")
	defer delete(dup)
	testing.expect_value(t, dup, "switch '-scratch' specified more than once")
}

// empty switch set documents to the empty string
@(test)
parameters_parser_test_generate_switches_doc_empty :: proc(t: ^testing.T) {
	switches := make(map[string]Parameters_Parser_Switch_Desc)
	defer delete(switches)
	doc := parameters_parser_generate_switches_doc(switches)
	defer delete(doc)
	testing.expect_value(t, doc, "")
}

// single boolean switch: exact C++ format output
@(test)
parameters_parser_test_generate_switches_doc_single :: proc(t: ^testing.T) {
	switches := make(map[string]Parameters_Parser_Switch_Desc)
	defer delete(switches)
	switches["scratch"] = {false, "create a scratch buffer"}
	doc := parameters_parser_generate_switches_doc(switches)
	defer delete(doc)
	testing.expect_value(t, doc, "-scratch  create a scratch buffer\n")
}

// single valued switch shows the <arg> marker
@(test)
parameters_parser_test_generate_switches_doc_arg :: proc(t: ^testing.T) {
	switches := make(map[string]Parameters_Parser_Switch_Desc)
	defer delete(switches)
	switches["method"] = {true, "explicit writemethod"}
	doc := parameters_parser_generate_switches_doc(switches)
	defer delete(doc)
	testing.expect_value(t, doc, "-method <arg> explicit writemethod\n")
}

// descriptions align to the widest entry (order-insensitive: maps are unordered)
@(test)
parameters_parser_test_generate_switches_doc_align :: proc(t: ^testing.T) {
	switches := make(map[string]Parameters_Parser_Switch_Desc)
	defer delete(switches)
	switches["a"] = {false, "x"}
	switches["longer"] = {false, "y"}
	switches["m"] = {true, "z"}
	doc := parameters_parser_generate_switches_doc(switches)
	defer delete(doc)
	// widest is "m" + <arg> = 1 + 5 = 6 columns
	testing.expect(t, strings.contains(doc, "-a       x\n"))
	testing.expect(t, strings.contains(doc, "-longer  y\n"))
	testing.expect(t, strings.contains(doc, "-m <arg> z\n"))
}
