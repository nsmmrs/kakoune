// Tests for the JSON port. The first six procs port the test_json_parser
// and test_to_json UnitTest assertions from src/json.cc 1:1; the rest are
// edge cases for escapes, error mapping, C++ quirks, and roundtrips.
package kak

import "core:strings"
import "core:testing"

// Ports test_json_parser block 1: a JSON-RPC-ish object parses.
@(test)
test_json_parse_rpc_message :: proc(t: ^testing.T) {
	val, err := json_parse(`{ "jsonrpc": "2.0", "method": "keys", "params": [ "b", "l", "a", "h" ] }`)
	defer json_free(val)
	testing.expect_value(t, err, Json_Error.None)
}

// Ports test_json_parser block 2: "[10,20]" is an array with 20 at index 1.
@(test)
test_json_parse_int_array :: proc(t: ^testing.T) {
	val, err := json_parse("[10,20]")
	defer json_free(val)
	testing.expect_value(t, err, Json_Error.None)
	arr, is_arr := val.(Json_Array)
	testing.expect(t, is_arr)
	if !is_arr {
		return
	}
	json_expect_variant(t, arr[1], 20)
}

// Ports test_json_parser block 3: "-1" parses to -1.
@(test)
test_json_parse_negative_int :: proc(t: ^testing.T) {
	val, err := json_parse("-1")
	defer json_free(val)
	testing.expect_value(t, err, Json_Error.None)
	json_expect_variant(t, val, -1)
}

// Ports test_json_parser block 4: "{}" is an empty object.
@(test)
test_json_parse_empty_object :: proc(t: ^testing.T) {
	val, err := json_parse("{}")
	defer json_free(val)
	testing.expect_value(t, err, Json_Error.None)
	obj, is_obj := val.(Json_Object)
	testing.expect(t, is_obj)
	if !is_obj {
		return
	}
	testing.expect_value(t, len(obj), 0)
}

// Ports test_json_parser block 5: nesting past json_max_depth fails.
@(test)
test_json_parse_max_depth :: proc(t: ^testing.T) {
	b := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< json_max_depth + 1 {
		strings.write_byte(&b, '[')
	}
	for _ in 0 ..< json_max_depth + 1 {
		strings.write_byte(&b, ']')
	}
	val, err := json_parse(strings.to_string(b))
	defer json_free(val)
	testing.expect_value(t, err, Json_Error.Max_Depth)
}

// Ports test_to_json: scalars plus a two-key object of int arrays. Member
// order is nondeterministic (map iteration), so both orders are accepted.
@(test)
test_json_to_string_scalars_and_object :: proc(t: ^testing.T) {
	s_true := json_to_string(true)
	testing.expect_value(t, s_true, "true")
	delete(s_true)

	s_false := json_to_string(false)
	testing.expect_value(t, s_false, "false")
	delete(s_false)

	foo_arr := make(Json_Array, 0, 3, context.allocator)
	append(&foo_arr, 1)
	append(&foo_arr, 2)
	append(&foo_arr, 3)
	esc_arr := make(Json_Array, 0, 3, context.allocator)
	append(&esc_arr, 3)
	append(&esc_arr, 4)
	append(&esc_arr, 5)
	obj := make(Json_Object, 0, context.allocator)
	obj[strings.clone("foo")] = foo_arr
	obj[strings.clone("\x1b")] = esc_arr
	obj_val: Json_Value = obj
	defer json_free(obj_val)

	s := json_to_string(obj_val)
	defer delete(s)
	ok := s == "{\"foo\": [1, 2, 3],\"\\u001b\": [3, 4, 5]}" || s == "{\"\\u001b\": [3, 4, 5],\"foo\": [1, 2, 3]}"
	testing.expect(t, ok)
}

// Edge: backslashes quote the next byte literally; no escape sequence is
// interpreted, matching C++.
@(test)
test_json_parse_string_escapes :: proc(t: ^testing.T) {
	inputs := []string{`"a\"b"`, `"a\\b"`, `"\n"`, `"\u001b"`, `""`}
	wants := []string{"a\"b", `a\b`, "n", "u001b", ""}
	for input, i in inputs {
		val, err := json_parse(input)
		testing.expect_value(t, err, Json_Error.None)
		json_expect_variant(t, val, wants[i])
		json_free(val)
	}
}

// Edge: every failure mode maps to the expected Json_Error, including the
// C++ quirks ("[ ]"/"{ }" fail rather than parsing as empty containers,
// and a bare "true"/"false" ending at end of input does not match).
@(test)
test_json_parse_invalid_inputs :: proc(t: ^testing.T) {
	Case :: struct {
		input: string,
		err:   Json_Error,
	}
	cases := []Case{
		{"", .Unexpected_End},
		{"   ", .Unexpected_End},
		{"[", .Unexpected_End},
		{"[1", .Unexpected_End},
		{"[1,", .Unexpected_End},
		{"[1,]", .Unexpected_Char},
		{"[1 2]", .Expected_Comma_Or_Close},
		{"{", .Unexpected_End},
		{`{"a"`, .Unexpected_End},
		{`{"a" 1}`, .Expected_Colon},
		{`{1:2}`, .Non_String_Key},
		{`"abc`, .Unexpected_End},
		{"xyz", .Unexpected_Char},
		{"[ ]", .Unexpected_Char},
		{"{ }", .Unexpected_Char},
		{"true", .Unexpected_Char},
		{"false", .Unexpected_Char},
		{"-", .Bad_Number},
		{"-x", .Bad_Number},
	}
	for c in cases {
		val, err := json_parse(c.input)
		testing.expect_value(t, err, c.err)
		testing.expect(t, val == nil)
		json_free(val)
	}
}

// Edge: bools need a trailing byte at top level (C++ quirk), parse
// normally in arrays; surrounding blanks and trailing garbage match C++.
@(test)
test_json_parse_bools_and_trivia :: proc(t: ^testing.T) {
	val_true, err_true := json_parse("true ")
	defer json_free(val_true)
	testing.expect_value(t, err_true, Json_Error.None)
	json_expect_variant(t, val_true, true)

	val_false, err_false := json_parse("false ")
	defer json_free(val_false)
	testing.expect_value(t, err_false, Json_Error.None)
	json_expect_variant(t, val_false, false)

	val_arr, err_arr := json_parse("[true, false]")
	defer json_free(val_arr)
	testing.expect_value(t, err_arr, Json_Error.None)
	arr, is_arr := val_arr.(Json_Array)
	testing.expect(t, is_arr)
	if is_arr {
		json_expect_variant(t, arr[0], true)
		json_expect_variant(t, arr[1], false)
	}

	val_num, err_num := json_parse("  -42\t")
	defer json_free(val_num)
	testing.expect_value(t, err_num, Json_Error.None)
	json_expect_variant(t, val_num, -42)

	// C++ returns new_pos without requiring full consumption.
	val_trail, err_trail := json_parse("[1] junk")
	defer json_free(val_trail)
	testing.expect_value(t, err_trail, Json_Error.None)
}

// Edge: integer-only spelling (no fraction/exponent/'+'), leading zeros,
// parsing stops at the first non-digit, and 32-bit wraparound on overflow
// like C++ str_to_int.
@(test)
test_json_parse_number_edges :: proc(t: ^testing.T) {
	nums := []string{"00", "-0", "007", "2147483647", "4294967297", "-2147483648", "12x", "1.5"}
	wants := []int{0, 0, 7, 2147483647, 1, -2147483648, 12, 1}
	for input, i in nums {
		val, err := json_parse(input)
		testing.expect_value(t, err, Json_Error.None)
		json_expect_variant(t, val, wants[i])
		json_free(val)
	}

	val, err := json_parse("+1")
	defer json_free(val)
	testing.expect_value(t, err, Json_Error.Unexpected_Char)
}

// Edge: nesting exactly at json_max_depth parses; one deeper fails.
@(test)
test_json_parse_depth_boundary :: proc(t: ^testing.T) {
	b := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< json_max_depth {
		strings.write_byte(&b, '[')
	}
	for _ in 0 ..< json_max_depth {
		strings.write_byte(&b, ']')
	}
	val, err := json_parse(strings.to_string(b))
	defer json_free(val)
	testing.expect_value(t, err, Json_Error.None)
}

// Edge: \" and \\ are backslash-escaped, bytes <= 0x1F become lowercase
// \u00XX, and 0x7F plus multi-byte UTF-8 pass through untouched.
@(test)
test_json_to_string_escapes :: proc(t: ^testing.T) {
	raw := strings.clone("a\"b\\c\x01\x7fé")
	val: Json_Value = raw
	defer json_free(val)
	s := json_to_string(val)
	defer delete(s)
	testing.expect_value(t, s, "\"a\\\"b\\\\c\\u0001\x7fé\"")
}

// Edge: parse then serialize roundtrips single-key objects and arrays
// with C++ formatting (", " in arrays, ": " after object keys).
@(test)
test_json_roundtrip :: proc(t: ^testing.T) {
	inputs := []string{
		`{"a": [1, -2, true, "x"]}`,
		`[[1, 2], {"k": false}]`,
		`{"b": {}}`,
		`"\""`,
		`[]`,
	}
	for input in inputs {
		val, err := json_parse(input)
		testing.expect_value(t, err, Json_Error.None)
		s := json_to_string(val)
		testing.expect_value(t, s, input)
		delete(s)
		json_free(val)
	}
}

// json_expect_variant asserts v holds variant T with value want. Plain
// testing.expect_value cannot compare Json_Value: unions holding maps and
// dynamic arrays are not comparable.
@(private)
json_expect_variant :: proc(t: ^testing.T, v: Json_Value, want: $T) {
	got, ok := v.(T)
	testing.expect(t, ok)
	if ok {
		testing.expect_value(t, got, want)
	}
}
