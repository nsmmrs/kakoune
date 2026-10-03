// JSON value model, parser, and serializer.
//
// Port of src/json.hh and src/json.cc.
//
// Ownership: json_parse clones every string, array, and object into
// `allocator` (default context.allocator). The caller owns the returned
// Json_Value tree and must release it with json_free, with the same
// allocator in context.allocator (Odin's delete uses context.allocator).
// json_to_string returns an owned string in `allocator` that the caller
// must delete. On parse failure json_parse frees all partial state itself
// and returns (nil, err): there is nothing to free. json_free requires a
// fully owned tree (as produced by json_parse); handing it static string
// literals is a caller bug.
//
// Fidelity notes vs the C++ implementation:
//   - Escapes are NOT interpreted: "\n" parses to "n", "\u001b" to "u001b";
//     a backslash only quotes the next byte. This matches C++ exactly.
//   - A bare "true"/"false" with no trailing byte fails with
//     .Unexpected_Char (C++ requires end - pos > 4/5); inside arrays and
//     objects they parse normally.
//   - "[ ]" and "{ }" (blank-only, nothing else) fail with .Unexpected_Char
//     because C++ checks for the closing bracket before skipping blanks.
//   - Trailing input after a complete value is ignored, as C++ returns
//     new_pos and lets callers decide.
//   - Numbers are 32-bit ints with wraparound on overflow, matching C++
//     str_to_int; only an optional '-' followed by ASCII digits is
//     accepted (no fraction, exponent, or '+' spelling).
//   - Object member order in json_to_string output is nondeterministic:
//     C++ iterates a HashMap (stable per build), Odin randomizes map
//     iteration order.
package kak

import "core:fmt"
import "core:mem"
import "core:strings"

// json_max_depth is the maximum JSON nesting depth. It mirrors C++
// max_parsing_depth: parsing a value nested deeper than this fails.
json_max_depth :: 100

// Json_Error enumerates every failure mode of json_parse. The zero value
// .None means success.
Json_Error :: enum {
	None, // ok
	Unexpected_End, // empty input, or a value cut off mid-parse (unterminated string/array/object); C++ returned a null Value here, except a bare '['/'{' at end of input which threw
	Max_Depth, // nesting depth reached json_max_depth; C++ threw "maximum parsing depth reached"
	Bad_Number, // '-' not followed by digits; C++ str_to_int threw
	Expected_Colon, // object key not followed by ':'; C++ threw "expected :"
	Expected_Comma_Or_Close, // array/object member not followed by ',' or the closing bracket
	Unexpected_Char, // byte that starts no JSON value here; C++ threw "unable to parse json"
	Non_String_Key, // object key parsed but is not a string; C++ threw bad_value_cast
}

// Json_Value is a parsed JSON value. int holds C++ int (32-bit range),
// string/ Json_Array/Json_Object are owned allocations (see file docs).
Json_Value :: union {
	int,
	bool,
	string,
	Json_Array,
	Json_Object,
}

// Json_Array is an owned JSON array.
Json_Array :: [dynamic]Json_Value

// Json_Object is an owned JSON object. Both keys and values are owned.
Json_Object :: map[string]Json_Value

// json_parse parses one JSON value from the start of input (leading blanks
// skipped). See the file docs for ownership and fidelity notes.
json_parse :: proc(input: string, allocator := context.allocator) -> (Json_Value, Json_Error) {
	val, _, err := json_parse_impl(input, 0, 0, allocator)
	return val, err
}

// json_to_string serializes a value: ints as decimal, strings quoted with
// \\, \", and \u00XX escapes for bytes <= 0x1F, arrays joined with ", ",
// objects as "key": value pairs joined with ','. The caller owns the
// returned string. Object member order is nondeterministic (map order).
json_to_string :: proc(v: Json_Value, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	json_write_value(&b, v)
	// Ownership of the builder buffer transfers to the caller; the builder
	// itself must not be destroyed here.
	return strings.to_string(b)
}

// json_free recursively releases a fully owned Json_Value tree (see file
// docs). It must run with the tree's allocator in context.allocator.
json_free :: proc(v: Json_Value) {
	switch t in v {
	case int:
	case bool:
	case string:
		delete(t)
	case Json_Array:
		json_abandon_array(t)
	case Json_Object:
		json_abandon_object(t)
	}
}

// json_parse_impl parses one value at s[pos:] nested at depth. It returns
// the value, the offset just past it, and the error (.None on success).
// On error the value is nil and any partial state is already freed.
@(private)
json_parse_impl :: proc(s: string, pos: int, depth: int, allocator: mem.Allocator) -> (Json_Value, int, Json_Error) {
	p := json_skip_blanks(s, pos)
	if p >= len(s) {
		return {}, p, .Unexpected_End
	}
	if depth >= json_max_depth {
		return {}, p, .Max_Depth
	}
	c := s[p]
	if json_is_digit(c) || c == '-' {
		return json_parse_number(s, p)
	}
	// NOTE: the strict > (not >=) reproduces a C++ off-by-one quirk: a
	// bare "true"/"false" ending exactly at end of input does not match.
	if len(s) - p > 4 && s[p:p + 4] == "true" {
		return true, p + 4, .None
	}
	if len(s) - p > 5 && s[p:p + 5] == "false" {
		return false, p + 5, .None
	}
	if c == '"' {
		return json_parse_string(s, p, allocator)
	}
	if c == '[' {
		return json_parse_array(s, p, depth, allocator)
	}
	if c == '{' {
		return json_parse_object(s, p, depth, allocator)
	}
	return {}, p, .Unexpected_Char
}

// json_parse_number parses the C++ number spelling: one optional '-'
// followed by ASCII digits starting at s[pos]. Parsing stops at the first
// non-digit. Accumulation wraps mod 2^32 like C++ str_to_int.
@(private)
json_parse_number :: proc(s: string, pos: int) -> (Json_Value, int, Json_Error) {
	end := pos + 1
	for end < len(s) && json_is_digit(s[end]) {
		end += 1
	}
	digits := s[pos:end]
	negative := digits[0] == '-'
	if negative {
		digits = digits[1:]
	}
	if len(digits) == 0 {
		return {}, pos, .Bad_Number
	}
	res: u32 = 0
	for i := 0; i < len(digits); i += 1 {
		res = res * 10 + u32(digits[i]) - u32('0')
	}
	if negative {
		res = 0 - res
	}
	return int(i32(res)), end, .None
}

// json_parse_string parses a double-quoted string starting at s[pos].
// Backslashes quote the next byte literally; no escape is interpreted.
@(private)
json_parse_string :: proc(s: string, pos: int, allocator: mem.Allocator) -> (Json_Value, int, Json_Error) {
	p := pos + 1 // skip opening quote
	b := strings.builder_make(allocator)
	escaped := false
	for p < len(s) {
		ch := s[p]
		if escaped {
			strings.write_byte(&b, ch)
			escaped = false
		} else if ch == '\\' {
			escaped = true
		} else if ch == '"' {
			// Ownership of the builder buffer transfers to the caller.
			return strings.to_string(b), p + 1, .None
		} else {
			strings.write_byte(&b, ch)
		}
		p += 1
	}
	strings.builder_destroy(&b)
	return {}, p, .Unexpected_End
}

// json_parse_array parses an array starting at s[pos] == '['.
@(private)
json_parse_array :: proc(s: string, pos: int, depth: int, allocator: mem.Allocator) -> (Json_Value, int, Json_Error) {
	p := pos + 1 // skip '['
	if p >= len(s) {
		// C++ throws "unable to parse array" here.
		return {}, p, .Unexpected_End
	}
	arr := make(Json_Array, 0, 8, allocator)
	// NOTE: no blank skipping before this check, matching C++: "[ ]" fails.
	if s[p] == ']' {
		return arr, p + 1, .None
	}
	for {
		elem, elem_end, elem_err := json_parse_impl(s, p, depth + 1, allocator)
		if elem_err != .None {
			json_abandon_array(arr)
			return {}, p, elem_err
		}
		p = elem_end
		append(&arr, elem)
		p = json_skip_blanks(s, p)
		if p >= len(s) {
			json_abandon_array(arr)
			return {}, p, .Unexpected_End
		}
		if s[p] == ',' {
			p += 1
		} else if s[p] == ']' {
			return arr, p + 1, .None
		} else {
			json_abandon_array(arr)
			return {}, p, .Expected_Comma_Or_Close
		}
	}
}

// json_parse_object parses an object starting at s[pos] == '{'.
@(private)
json_parse_object :: proc(s: string, pos: int, depth: int, allocator: mem.Allocator) -> (Json_Value, int, Json_Error) {
	p := pos + 1 // skip '{'
	if p >= len(s) {
		// C++ throws "unable to parse object" here.
		return {}, p, .Unexpected_End
	}
	obj := make(Json_Object, 0, allocator)
	// NOTE: no blank skipping before this check, matching C++: "{ }" fails.
	if s[p] == '}' {
		return obj, p + 1, .None
	}
	for {
		name_val, name_end, name_err := json_parse_impl(s, p, depth + 1, allocator)
		if name_err != .None {
			json_abandon_object(obj)
			return {}, p, name_err
		}
		p = name_end
		name, name_ok := name_val.(string)
		if !name_ok {
			json_free(name_val)
			json_abandon_object(obj)
			return {}, p, .Non_String_Key
		}
		p = json_skip_blanks(s, p)
		if p >= len(s) {
			delete(name)
			json_abandon_object(obj)
			return {}, p, .Unexpected_End
		}
		if s[p] != ':' {
			delete(name)
			json_abandon_object(obj)
			return {}, p, .Expected_Colon
		}
		p += 1
		elem, elem_end, elem_err := json_parse_impl(s, p, depth + 1, allocator)
		if elem_err != .None {
			delete(name)
			json_abandon_object(obj)
			return {}, p, elem_err
		}
		p = elem_end
		old, exists := obj[name]
		if exists {
			// Duplicate key: last wins, like C++ HashMap::insert.
			json_free(old)
		}
		obj[name] = elem
		if exists {
			// The map kept the original key; the new one is orphaned.
			delete(name)
		}
		p = json_skip_blanks(s, p)
		if p >= len(s) {
			json_abandon_object(obj)
			return {}, p, .Unexpected_End
		}
		if s[p] == ',' {
			p += 1
		} else if s[p] == '}' {
			return obj, p + 1, .None
		} else {
			json_abandon_object(obj)
			return {}, p, .Expected_Comma_Or_Close
		}
	}
}

// json_write_value appends the serialization of v to b.
@(private)
json_write_value :: proc(b: ^strings.Builder, v: Json_Value) {
	switch t in v {
	case int:
		fmt.sbprintf(b, "%d", t)
	case bool:
		strings.write_string(b, "true" if t else "false")
	case string:
		// Lowercase hex alphabet, matching C++ std::to_chars base-16.
		hex := "0123456789abcdef"
		strings.write_byte(b, '"')
		for i := 0; i < len(t); i += 1 {
			c := t[i]
			if c == '\\' || c == '"' {
				strings.write_byte(b, '\\')
				strings.write_byte(b, c)
			} else if c <= 0x1f {
				strings.write_string(b, "\\u00")
				strings.write_byte(b, hex[c >> 4])
				strings.write_byte(b, hex[c & 15])
			} else {
				strings.write_byte(b, c)
			}
		}
		strings.write_byte(b, '"')
	case Json_Array:
		strings.write_byte(b, '[')
		for e, i in t {
			if i > 0 {
				strings.write_string(b, ", ")
			}
			json_write_value(b, e)
		}
		strings.write_byte(b, ']')
	case Json_Object:
		strings.write_byte(b, '{')
		first := true
		for k, e in t {
			if !first {
				strings.write_byte(b, ',')
			}
			first = false
			json_write_value(b, k)
			strings.write_string(b, ": ")
			json_write_value(b, e)
		}
		strings.write_byte(b, '}')
	}
}

// json_abandon_array frees a partially built array and its elements.
@(private)
json_abandon_array :: proc(arr: Json_Array) {
	for e in arr {
		json_free(e)
	}
	delete(arr)
}

// json_abandon_object frees a partially built object: keys, values, map.
@(private)
json_abandon_object :: proc(obj: Json_Object) {
	for k, e in obj {
		delete(k)
		json_free(e)
	}
	delete(obj)
}

// json_skip_blanks skips ASCII blanks. C++ is_blank takes a Codepoint but
// the parser feeds it raw bytes, so only the ASCII members (' ', '\t',
// '\n', '\r', '\v', '\f') can ever match there.
@(private)
json_skip_blanks :: proc(s: string, pos: int) -> int {
	p := pos
	for p < len(s) && json_is_blank(s[p]) {
		p += 1
	}
	return p
}

// json_is_blank reports whether c is ASCII JSON whitespace.
@(private)
json_is_blank :: proc(c: byte) -> bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\v' || c == '\f'
}

// json_is_digit reports whether c is an ASCII digit.
@(private)
json_is_digit :: proc(c: byte) -> bool {
	return c >= '0' && c <= '9'
}
