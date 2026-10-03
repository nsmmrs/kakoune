// Option value types and their string conversions.
//
// Ported from src/option_types.hh and src/option_types.cc. Covers the
// scalar types (int, bool, string, codepoint, coord, flags enums), the
// string/int lists, the string-to-int map, the string triple used for
// completion candidates, and the generic prefixed list.
//
// The small string helpers here (quoting, escape/unescape, split, join,
// str_to_int) are thin wrappers over the canonical string_utils and
// ranges implementations; option_types keeps its own signatures (and
// error enum) so existing callers are unaffected.
//
// Error handling: every fallible proc returns Option_types_Error with
// None (= 0) as success, replacing the C++ runtime_error throws.
//
// Ownership: procs returning string/[]string/map allocate with the given
// allocator (default context.allocator); the caller frees them with
// delete while the same allocator is ambient. Split results are views
// into the input (only the slice itself is owned). Scratch memory uses
// context.temp_allocator internally and must not be freed by callers.
package kak

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:unicode/utf8"

// Quoting selects how a single option value string is quoted.
Option_types_Quoting :: enum {
	Raw,
	Kakoune,
	Shell,
}

// Option_types_Error reports option conversion failures.
Option_types_Error :: enum {
	None,
	NotANumber,
	InvalidBool,
	NotSingleCodepoint,
	ExpectedSingleValue,
	MapExpectsKeyValue,
	TupleTooFewElements,
	TupleTooManyElements,
	ExpectedLineColumn,
	InvalidFlagValue,
	InvalidEnumValue,
	NoAddOperation,
	NoRemoveOperation,
	NoUpdateOperation,
}

// option_types_error_message describes an error; static strings only,
// the C++ messages interpolate the offending value.
option_types_error_message :: proc(err: Option_types_Error) -> string {
	switch err {
	case .None:
		return ""
	case .NotANumber:
		return "value is not a number"
	case .InvalidBool:
		return "boolean values are either true, yes, false or no"
	case .NotSingleCodepoint:
		return "value is not a single codepoint"
	case .ExpectedSingleValue:
		return "expected a single value for option"
	case .MapExpectsKeyValue:
		return "map option expects key=value"
	case .TupleTooFewElements:
		return "not enough elements in tuple"
	case .TupleTooManyElements:
		return "too many elements in tuple"
	case .ExpectedLineColumn:
		return "expected <line>,<column>"
	case .InvalidFlagValue:
		return "invalid flag value"
	case .InvalidEnumValue:
		return "invalid enum value"
	case .NoAddOperation:
		return "no add operation supported for this option type"
	case .NoRemoveOperation:
		return "no remove operation supported for this option type"
	case .NoUpdateOperation:
		return "no update operation supported for this option type"
	}
	unreachable()
}

// option_types_replace rewrites s replacing every non-overlapping
// occurrence of substr with replacement, scanning left to right.
// Thin wrapper over string_utils_replace.
option_types_replace :: proc(
	s, substr, replacement: string,
	allocator := context.allocator,
) -> string {
	return string_utils_replace(s, substr, replacement, allocator)
}

// option_types_double_up duplicates every byte of s found in characters.
// Thin wrapper over string_utils_double_up.
option_types_double_up :: proc(
	s, characters: string,
	allocator := context.allocator,
) -> string {
	return string_utils_double_up(s, characters, allocator)
}

// option_types_quote quotes s Kakoune style: 'it''s'.
// Thin wrapper over string_utils_quote.
option_types_quote :: proc(s: string, allocator := context.allocator) -> string {
	return string_utils_quote(s, allocator)
}

// option_types_shell_quote quotes s shell style: 'it'\''s'.
// Thin wrapper over string_utils_shell_quote.
option_types_shell_quote :: proc(s: string, allocator := context.allocator) -> string {
	return string_utils_shell_quote(s, allocator)
}

// option_types_apply_quoting quotes s per quoting (the C++ quoter).
option_types_apply_quoting :: proc(
	quoting: Option_types_Quoting,
	s: string,
	allocator := context.allocator,
) -> string {
	switch quoting {
	case .Raw:
		return string_utils_quote_raw(s, allocator)
	case .Kakoune:
		return string_utils_quote(s, allocator)
	case .Shell:
		return string_utils_shell_quote(s, allocator)
	}
	unreachable()
}

// option_types_str_to_int_ifp parses an optional '-' followed by digits.
// Like the C++ version it accumulates into a 32 bit word with wraparound,
// so huge inputs wrap instead of failing.
// Thin wrapper over string_utils_str_to_int_ifp.
option_types_str_to_int_ifp :: proc(s: string) -> (int, bool) {
	return string_utils_str_to_int_ifp(s)
}

// option_types_str_to_int parses s as an int, NotANumber on failure.
// Delegates to string_utils_str_to_int, mapping its error enum.
option_types_str_to_int :: proc(s: string) -> (int, Option_types_Error) {
	val, err := string_utils_str_to_int(s)
	if err != .None {
		return 0, .NotANumber
	}
	return val, .None
}

// option_types_escape prefixes every byte of s found in characters with
// the escape byte. Thin wrapper over string_utils_escape.
option_types_escape :: proc(
	s, characters: string,
	escape: byte,
	allocator := context.allocator,
) -> string {
	return string_utils_escape(s, characters, escape, allocator)
}

// option_types_unescape drops an escape byte that precedes a byte found
// in characters; other escape bytes (trailing, or before other bytes)
// are kept literally. Thin wrapper over string_utils_unescape.
option_types_unescape :: proc(
	s, characters: string,
	escape: byte,
	allocator := context.allocator,
) -> string {
	return string_utils_unescape(s, characters, escape, allocator)
}

// option_types_split splits s on separator, keeping empty parts; an
// empty input yields zero parts. Parts are views into s. Delegates to
// ranges_split (the canonical port of C++ split()); the slice shares the
// dynamic array's backing and the caller frees it with delete as before.
option_types_split :: proc(
	s: string,
	separator: byte,
	allocator := context.allocator,
) -> []string {
	dyn := ranges_split(s, separator, allocator)
	return dyn[:]
}

// option_types_split_escaped splits s on separator unless the separator
// is escaped by the escaper byte (an escaper escapes the next byte, and
// an escaped escaper loses its meaning). Escapes are left in place for
// option_types_unescape to remove. Parts are views into s. Delegates to
// ranges_split_escaped; the caller frees the slice with delete as before.
option_types_split_escaped :: proc(
	s: string,
	separator, escaper: byte,
	allocator := context.allocator,
) -> []string {
	dyn := ranges_split_escaped(s, separator, escaper, allocator)
	return dyn[:]
}

// option_types_join joins parts with joiner, optionally escaping the
// joiner and backslash inside each part first.
// Thin wrapper over string_utils_join_char.
option_types_join :: proc(
	parts: []string,
	joiner: byte,
	escape_joiner := true,
	allocator := context.allocator,
) -> string {
	return string_utils_join_char(parts, joiner, escape_joiner, allocator)
}

// option_types_join_with joins parts with a string joiner, no escaping.
// Thin wrapper over string_utils_join_str.
option_types_join_with :: proc(
	parts: []string,
	joiner: string,
	allocator := context.allocator,
) -> string {
	return string_utils_join_str(parts, joiner, allocator)
}

// option_types_int_to_string formats an int option value.
option_types_int_to_string :: proc(value: int, allocator := context.allocator) -> string {
	return fmt.aprintf("%d", value, allocator = allocator)
}

// option_types_int_from_string parses an int option value.
option_types_int_from_string :: proc(s: string) -> (int, Option_types_Error) {
	return option_types_str_to_int(s)
}

// option_types_int_to_strings wraps the single value form.
option_types_int_to_strings :: proc(value: int, allocator := context.allocator) -> []string {
	res := make([]string, 1, allocator)
	res[0] = option_types_int_to_string(value, allocator)
	return res
}

// option_types_int_from_strings parses exactly one string.
option_types_int_from_strings :: proc(strs: []string) -> (int, Option_types_Error) {
	if len(strs) != 1 {
		return 0, .ExpectedSingleValue
	}
	return option_types_int_from_string(strs[0])
}

// option_types_int_add adds s to opt, reporting whether opt changed.
option_types_int_add :: proc(opt: ^int, s: string) -> (bool, Option_types_Error) {
	val, err := option_types_int_from_string(s)
	if err != .None {
		return false, err
	}
	opt^ += val
	return val != 0, .None
}

// option_types_int_remove subtracts s from opt, reporting changedness.
option_types_int_remove :: proc(opt: ^int, s: string) -> (bool, Option_types_Error) {
	val, err := option_types_int_from_string(s)
	if err != .None {
		return false, err
	}
	opt^ -= val
	return val != 0, .None
}

// option_types_int_type_name is "int".
option_types_int_type_name :: proc() -> string {
	return "int"
}

// option_types_uint_to_string formats a size_t option value.
option_types_uint_to_string :: proc(value: uint, allocator := context.allocator) -> string {
	return fmt.aprintf("%d", value, allocator = allocator)
}

// option_types_uint_from_string parses a size_t option value; negative
// inputs wrap as in the C++ str_to_int to size_t conversion.
option_types_uint_from_string :: proc(s: string) -> (uint, Option_types_Error) {
	val, err := option_types_str_to_int(s)
	if err != .None {
		return 0, err
	}
	return uint(val), .None
}

// option_types_uint_to_strings wraps the single value form.
option_types_uint_to_strings :: proc(value: uint, allocator := context.allocator) -> []string {
	res := make([]string, 1, allocator)
	res[0] = option_types_uint_to_string(value, allocator)
	return res
}

// option_types_uint_from_strings parses exactly one string.
option_types_uint_from_strings :: proc(strs: []string) -> (uint, Option_types_Error) {
	if len(strs) != 1 {
		return 0, .ExpectedSingleValue
	}
	return option_types_uint_from_string(strs[0])
}

// option_types_bool_to_string formats a bool option value.
option_types_bool_to_string :: proc(value: bool) -> string {
	return "true" if value else "false"
}

// option_types_bool_from_string parses true/yes/false/no.
option_types_bool_from_string :: proc(s: string) -> (bool, Option_types_Error) {
	if s == "true" || s == "yes" {
		return true, .None
	}
	if s == "false" || s == "no" {
		return false, .None
	}
	return false, .InvalidBool
}

// option_types_bool_to_strings wraps the single value form.
option_types_bool_to_strings :: proc(value: bool, allocator := context.allocator) -> []string {
	res := make([]string, 1, allocator)
	res[0] = option_types_bool_to_string(value)
	return res
}

// option_types_bool_from_strings parses exactly one string.
option_types_bool_from_strings :: proc(strs: []string) -> (bool, Option_types_Error) {
	if len(strs) != 1 {
		return false, .ExpectedSingleValue
	}
	return option_types_bool_from_string(strs[0])
}

// option_types_bool_type_name is "bool".
option_types_bool_type_name :: proc() -> string {
	return "bool"
}

// option_types_string_to_string quotes a str option value.
option_types_string_to_string :: proc(
	s: string,
	quoting: Option_types_Quoting,
	allocator := context.allocator,
) -> string {
	return option_types_apply_quoting(quoting, s, allocator)
}

// option_types_string_from_string copies a str option value; infallible
// but keeps the uniform (value, error) shape.
option_types_string_from_string :: proc(
	s: string,
	allocator := context.allocator,
) -> (string, Option_types_Error) {
	return strings.clone(s, allocator), .None
}

// option_types_string_to_strings wraps the single value form.
option_types_string_to_strings :: proc(s: string, allocator := context.allocator) -> []string {
	res := make([]string, 1, allocator)
	res[0] = strings.clone(s, allocator)
	return res
}

// option_types_string_from_strings parses exactly one string.
option_types_string_from_strings :: proc(
	strs: []string,
	allocator := context.allocator,
) -> (string, Option_types_Error) {
	if len(strs) != 1 {
		return "", .ExpectedSingleValue
	}
	return option_types_string_from_string(strs[0], allocator)
}

// option_types_string_add appends val to opt. The previous contents are
// not freed; seed opt with an owned (possibly empty) string.
option_types_string_add :: proc(
	opt: ^string,
	val: string,
	allocator := context.allocator,
) -> bool {
	opt^ = strings.concatenate({opt^, val}, allocator)
	return len(val) != 0
}

// option_types_string_type_name is "str".
option_types_string_type_name :: proc() -> string {
	return "str"
}

// option_types_codepoint_to_string formats a codepoint option value.
option_types_codepoint_to_string :: proc(
	c: rune,
	quoting: Option_types_Quoting,
	allocator := context.allocator,
) -> string {
	buf, n := utf8.encode_rune(c)
	return option_types_apply_quoting(quoting, string(buf[:n]), allocator)
}

// option_types_codepoint_from_string parses a single codepoint; the
// input must be valid UTF-8 holding exactly one codepoint.
option_types_codepoint_from_string :: proc(s: string) -> (rune, Option_types_Error) {
	if utf8.rune_count(s) != 1 {
		return 0, .NotSingleCodepoint
	}
	c, _ := utf8.decode_rune(s)
	return c, .None
}

// option_types_codepoint_to_strings wraps the single value form.
option_types_codepoint_to_strings :: proc(
	c: rune,
	allocator := context.allocator,
) -> []string {
	res := make([]string, 1, allocator)
	res[0] = option_types_codepoint_to_string(c, .Raw, allocator)
	return res
}

// option_types_codepoint_from_strings parses exactly one string.
option_types_codepoint_from_strings :: proc(strs: []string) -> (rune, Option_types_Error) {
	if len(strs) != 1 {
		return 0, .ExpectedSingleValue
	}
	return option_types_codepoint_from_string(strs[0])
}

// option_types_codepoint_type_name is "codepoint".
option_types_codepoint_type_name :: proc() -> string {
	return "codepoint"
}

// Option_types_Coord is a <line>,<column> option value.
Option_types_Coord :: struct {
	line, column: int,
}

// option_types_coord_to_string formats a coord as "<line>,<column>".
option_types_coord_to_string :: proc(c: Option_types_Coord, allocator := context.allocator) -> string {
	return fmt.aprintf("%d,%d", c.line, c.column, allocator = allocator)
}

// option_types_coord_from_string parses "<line>,<column>".
option_types_coord_from_string :: proc(s: string) -> (Option_types_Coord, Option_types_Error) {
	parts := option_types_split(s, ',', context.temp_allocator)
	if len(parts) != 2 {
		return {}, .ExpectedLineColumn
	}
	line, line_err := option_types_str_to_int(parts[0])
	if line_err != .None {
		return {}, line_err
	}
	column, column_err := option_types_str_to_int(parts[1])
	if column_err != .None {
		return {}, column_err
	}
	return {line, column}, .None
}

// option_types_coord_to_strings wraps the single value form.
option_types_coord_to_strings :: proc(c: Option_types_Coord, allocator := context.allocator) -> []string {
	res := make([]string, 1, allocator)
	res[0] = option_types_coord_to_string(c, allocator)
	return res
}

// option_types_coord_from_strings parses exactly one string.
option_types_coord_from_strings :: proc(strs: []string) -> (Option_types_Coord, Option_types_Error) {
	if len(strs) != 1 {
		return {}, .ExpectedSingleValue
	}
	return option_types_coord_from_string(strs[0])
}

// option_types_coord_type_name is "coord".
option_types_coord_type_name :: proc() -> string {
	return "coord"
}

// Option_types_Debug_Flag lists the debug flags; declaration order is
// the enum_desc order used when formatting flag sets.
Option_types_Debug_Flag :: enum {
	Hooks,
	Shell,
	Profile,
	Keys,
	Commands,
}

// Option_types_Debug_Flags is a set of debug flags.
Option_types_Debug_Flags :: bit_set[Option_types_Debug_Flag]

// option_types_debug_flag_name names one flag.
option_types_debug_flag_name :: proc(flag: Option_types_Debug_Flag) -> string {
	switch flag {
	case .Hooks:
		return "hooks"
	case .Shell:
		return "shell"
	case .Profile:
		return "profile"
	case .Keys:
		return "keys"
	case .Commands:
		return "commands"
	}
	unreachable()
}

// option_types_debug_flags_to_string formats set flags in desc order,
// joined with '|'; the empty set formats as "".
option_types_debug_flags_to_string :: proc(
	flags: Option_types_Debug_Flags,
	allocator := context.allocator,
) -> string {
	b := strings.builder_make(allocator)
	defer strings.builder_destroy(&b)
	first := true
	for flag in Option_types_Debug_Flag {
		if flag not_in flags {
			continue
		}
		if !first {
			strings.write_byte(&b, '|')
		}
		first = false
		strings.write_string(&b, option_types_debug_flag_name(flag))
	}
	return strings.clone(strings.to_string(b), allocator)
}

// option_types_debug_flags_from_string parses '|' separated flag names;
// "" parses to the empty set.
option_types_debug_flags_from_string :: proc(s: string) -> (Option_types_Debug_Flags, Option_types_Error) {
	flags: Option_types_Debug_Flags
	parts := option_types_split(s, '|', context.temp_allocator)
	for i := 0; i < len(parts); i += 1 {
		matched := false
		for flag in Option_types_Debug_Flag {
			if parts[i] == option_types_debug_flag_name(flag) {
				flags |= {flag}
				matched = true
				break
			}
		}
		if !matched {
			return {}, .InvalidFlagValue
		}
	}
	return flags, .None
}

// option_types_debug_flags_to_strings wraps the single value form.
option_types_debug_flags_to_strings :: proc(
	flags: Option_types_Debug_Flags,
	allocator := context.allocator,
) -> []string {
	res := make([]string, 1, allocator)
	res[0] = option_types_debug_flags_to_string(flags, allocator)
	return res
}

// option_types_debug_flags_from_strings parses exactly one string.
option_types_debug_flags_from_strings :: proc(
	strs: []string,
) -> (Option_types_Debug_Flags, Option_types_Error) {
	if len(strs) != 1 {
		return {}, .ExpectedSingleValue
	}
	return option_types_debug_flags_from_string(strs[0])
}

// option_types_debug_flags_add sets the flags named by s.
option_types_debug_flags_add :: proc(
	opt: ^Option_types_Debug_Flags,
	s: string,
) -> (bool, Option_types_Error) {
	old := opt^
	flags, err := option_types_debug_flags_from_string(s)
	if err != .None {
		return false, err
	}
	opt^ |= flags
	return opt^ != old, .None
}

// option_types_debug_flags_remove clears the flags named by s.
option_types_debug_flags_remove :: proc(
	opt: ^Option_types_Debug_Flags,
	s: string,
) -> (bool, Option_types_Error) {
	old := opt^
	flags, err := option_types_debug_flags_from_string(s)
	if err != .None {
		return false, err
	}
	opt^ &= ~flags
	return opt^ != old, .None
}

// option_types_debug_flags_type_name is "flags(hooks|shell|...|commands)".
option_types_debug_flags_type_name :: proc() -> string {
	return "flags(hooks|shell|profile|keys|commands)"
}

// option_types_quoting_to_string names a quoting (plain enum path).
option_types_quoting_to_string :: proc(quoting: Option_types_Quoting) -> string {
	switch quoting {
	case .Raw:
		return "raw"
	case .Kakoune:
		return "kakoune"
	case .Shell:
		return "shell"
	}
	unreachable()
}

// option_types_quoting_from_string parses a quoting name.
option_types_quoting_from_string :: proc(s: string) -> (Option_types_Quoting, Option_types_Error) {
	for quoting in Option_types_Quoting {
		if s == option_types_quoting_to_string(quoting) {
			return quoting, .None
		}
	}
	return .Raw, .InvalidEnumValue
}

// option_types_quoting_type_name is "enum(raw|kakoune|shell)".
option_types_quoting_type_name :: proc() -> string {
	return "enum(raw|kakoune|shell)"
}

// option_types_string_list_to_strings copies each element Raw.
option_types_string_list_to_strings :: proc(vec: []string, allocator := context.allocator) -> []string {
	res := make([]string, len(vec), allocator)
	for i := 0; i < len(vec); i += 1 {
		res[i] = option_types_string_to_string(vec[i], .Raw, allocator)
	}
	return res
}

// option_types_string_list_from_strings copies each string.
option_types_string_list_from_strings :: proc(strs: []string, allocator := context.allocator) -> []string {
	res := make([]string, len(strs), allocator)
	for i := 0; i < len(strs); i += 1 {
		res[i], _ = option_types_string_from_string(strs[i], allocator)
	}
	return res
}

// option_types_string_list_to_string quotes each element and joins with
// a space, without escaping.
option_types_string_list_to_string :: proc(
	vec: []string,
	quoting: Option_types_Quoting,
	allocator := context.allocator,
) -> string {
	quoted := make([]string, len(vec), context.temp_allocator)
	for i := 0; i < len(vec); i += 1 {
		quoted[i] = option_types_string_to_string(vec[i], quoting, context.temp_allocator)
	}
	return option_types_join(quoted, ' ', false, allocator)
}

// option_types_string_list_add appends copies of strs; true unless strs
// is empty.
option_types_string_list_add :: proc(
	vec: ^[dynamic]string,
	strs: []string,
	allocator := context.allocator,
) -> bool {
	for i := 0; i < len(strs); i += 1 {
		copied, _ := option_types_string_from_string(strs[i], allocator)
		append(vec, copied)
	}
	return len(strs) != 0
}

// option_types_string_list_remove drops the first occurrence of each of
// strs. Removed elements are not freed.
option_types_string_list_remove :: proc(vec: ^[dynamic]string, strs: []string) -> bool {
	did_remove := false
	for i := 0; i < len(strs); i += 1 {
		for j := 0; j < len(vec); j += 1 {
			if vec[j] == strs[i] {
				ordered_remove(vec, j)
				did_remove = true
				break
			}
		}
	}
	return did_remove
}

// option_types_string_list_type_name is "str-list".
option_types_string_list_type_name :: proc() -> string {
	return "str-list"
}

// option_types_int_list_to_strings formats each element Raw.
option_types_int_list_to_strings :: proc(vec: []int, allocator := context.allocator) -> []string {
	res := make([]string, len(vec), allocator)
	for i := 0; i < len(vec); i += 1 {
		res[i] = option_types_int_to_string(vec[i], allocator)
	}
	return res
}

// option_types_int_list_from_strings parses each element.
option_types_int_list_from_strings :: proc(
	strs: []string,
	allocator := context.allocator,
) -> ([]int, Option_types_Error) {
	res := make([]int, len(strs), allocator)
	for i := 0; i < len(strs); i += 1 {
		val, err := option_types_int_from_string(strs[i])
		if err != .None {
			delete(res)
			return nil, err
		}
		res[i] = val
	}
	return res, .None
}

// option_types_int_list_to_string formats each element and joins with a
// space, without escaping.
option_types_int_list_to_string :: proc(vec: []int, allocator := context.allocator) -> string {
	strs := make([]string, len(vec), context.temp_allocator)
	for i := 0; i < len(vec); i += 1 {
		strs[i] = option_types_int_to_string(vec[i], context.temp_allocator)
	}
	return option_types_join(strs, ' ', false, allocator)
}

// option_types_int_list_add parses all of strs first, then appends them,
// so a bad element leaves vec untouched.
option_types_int_list_add :: proc(
	vec: ^[dynamic]int,
	strs: []string,
	allocator := context.allocator,
) -> (bool, Option_types_Error) {
	parsed, err := option_types_int_list_from_strings(strs, allocator)
	if err != .None {
		return false, err
	}
	defer delete(parsed)
	append(vec, ..parsed)
	return len(parsed) != 0, .None
}

// option_types_int_list_remove parses and drops the first occurrence of
// each of strs in order; a bad element aborts with earlier removals
// kept, matching the C++ sequential loop.
option_types_int_list_remove :: proc(vec: ^[dynamic]int, strs: []string) -> (bool, Option_types_Error) {
	did_remove := false
	for i := 0; i < len(strs); i += 1 {
		val, err := option_types_int_from_string(strs[i])
		if err != .None {
			return did_remove, err
		}
		for j := 0; j < len(vec); j += 1 {
			if vec[j] == val {
				ordered_remove(vec, j)
				did_remove = true
				break
			}
		}
	}
	return did_remove, .None
}

// option_types_int_list_type_name is "int-list".
option_types_int_list_type_name :: proc() -> string {
	return "int-list"
}

// option_types_string_int_map_entry formats one "key=value" entry,
// escaping '=' in both halves. Only '=' is escaped, not backslash.
option_types_string_int_map_entry :: proc(
	key: string,
	value: int,
	allocator := context.allocator,
) -> string {
	ek := option_types_escape(key, "=", '\\', context.temp_allocator)
	ev := option_types_escape(
		option_types_int_to_string(value, context.temp_allocator),
		"=",
		'\\',
		context.temp_allocator,
	)
	return strings.concatenate({ek, "=", ev}, allocator)
}

// option_types_string_int_map_to_strings formats every entry. Order
// follows map iteration order, which is not deterministic.
option_types_string_int_map_to_strings :: proc(
	m: map[string]int,
	allocator := context.allocator,
) -> []string {
	res := make([]string, len(m), allocator)
	i := 0
	for k, v in m {
		res[i] = option_types_string_int_map_entry(k, v, allocator)
		i += 1
	}
	return res
}

// option_types_string_int_map_pair splits one "key=value" entry on
// unescaped '=', requiring exactly two halves, and unescapes both with
// the temp allocator.
option_types_string_int_map_pair :: proc(
	s: string,
) -> (key, value: string, err: Option_types_Error) {
	parts := option_types_split_escaped(s, '=', '\\', context.temp_allocator)
	if len(parts) != 2 {
		return "", "", .MapExpectsKeyValue
	}
	key = option_types_unescape(parts[0], "=\\", '\\', context.temp_allocator)
	value = option_types_unescape(parts[1], "=\\", '\\', context.temp_allocator)
	return key, value, .None
}

// option_types_string_int_map_from_strings parses entries into a new map
// that owns its keys; delete the keys, then the map.
option_types_string_int_map_from_strings :: proc(
	strs: []string,
	allocator := context.allocator,
) -> (map[string]int, Option_types_Error) {
	res := make(map[string]int, allocator)
	_, err := option_types_string_int_map_add(&res, strs, allocator)
	if err != .None {
		for k in res {
			delete(k)
		}
		delete(res)
		return nil, err
	}
	return res, .None
}

// option_types_string_int_map_to_string quotes each entry and joins with
// a space, without escaping.
option_types_string_int_map_to_string :: proc(
	m: map[string]int,
	quoting: Option_types_Quoting,
	allocator := context.allocator,
) -> string {
	entries := make([]string, len(m), context.temp_allocator)
	i := 0
	for k, v in m {
		entry := option_types_string_int_map_entry(k, v, context.temp_allocator)
		entries[i] = option_types_apply_quoting(quoting, entry, context.temp_allocator)
		i += 1
	}
	return option_types_join(entries, ' ', false, allocator)
}

// option_types_string_int_map_add parses each entry in order and stores
// it (later duplicates win); true unless strs is empty. A bad entry
// aborts with earlier entries kept.
option_types_string_int_map_add :: proc(
	m: ^map[string]int,
	strs: []string,
	allocator := context.allocator,
) -> (bool, Option_types_Error) {
	for i := 0; i < len(strs); i += 1 {
		key, val_str, pair_err := option_types_string_int_map_pair(strs[i])
		if pair_err != .None {
			return false, pair_err
		}
		val, int_err := option_types_str_to_int(val_str)
		if int_err != .None {
			return false, int_err
		}
		if key in m^ {
			m^[key] = val
		} else {
			owned := strings.clone(key, allocator)
			m^[owned] = val
		}
	}
	return len(strs) != 0, .None
}

// option_types_string_int_map_remove drops the entry named by each
// "key[=value]" entry when the key exists and the value part is empty
// or parses to the stored value. A malformed entry aborts with an
// error. Unparsable non-empty values simply match nothing: the C++
// template compares the raw text against the stored value, which only
// compiles for string-valued maps.
option_types_string_int_map_remove :: proc(
	m: ^map[string]int,
	strs: []string,
) -> (bool, Option_types_Error) {
	changed := false
	for i := 0; i < len(strs); i += 1 {
		key, val_str, pair_err := option_types_string_int_map_pair(strs[i])
		if pair_err != .None {
			return changed, pair_err
		}
		stored_key := ""
		found := false
		for k in m^ {
			if k == key {
				stored_key = k
				found = true
				break
			}
		}
		if !found {
			continue
		}
		match := len(val_str) == 0
		if !match {
			if val, ok := option_types_str_to_int_ifp(val_str); ok && val == m^[stored_key] {
				match = true
			}
		}
		if match {
			delete_key(m, stored_key)
			delete(stored_key)
			changed = true
		}
	}
	return changed, .None
}

// option_types_string_int_map_type_name is "str-to-int-map".
option_types_string_int_map_type_name :: proc() -> string {
	return "str-to-int-map"
}

// option_types_TUPLE_SEPARATOR separates tuple elements in strings.
option_types_TUPLE_SEPARATOR :: '|'

// Option_types_String_Triple is the tuple(String, String, String)
// option value (a completion candidate).
Option_types_String_Triple :: struct {
	first, second, third: string,
}

// option_types_string_triple_to_string joins the Raw elements with '|',
// escaping '|' and backslash, then applies quoting.
option_types_string_triple_to_string :: proc(
	t: Option_types_String_Triple,
	quoting: Option_types_Quoting,
	allocator := context.allocator,
) -> string {
	elems := [3]string{t.first, t.second, t.third}
	joined := option_types_join(elems[:], option_types_TUPLE_SEPARATOR, true, context.temp_allocator)
	return option_types_apply_quoting(quoting, joined, allocator)
}

// option_types_string_triple_from_string splits on unescaped '|',
// unescapes, and requires exactly three parts. Parts are owned.
option_types_string_triple_from_string :: proc(
	s: string,
	allocator := context.allocator,
) -> (Option_types_String_Triple, Option_types_Error) {
	parts := option_types_split_escaped(s, option_types_TUPLE_SEPARATOR, '\\', context.temp_allocator)
	if len(parts) < 3 {
		return {}, .TupleTooFewElements
	}
	if len(parts) > 3 {
		return {}, .TupleTooManyElements
	}
	first := option_types_unescape(parts[0], "|\\", '\\', allocator)
	second := option_types_unescape(parts[1], "|\\", '\\', allocator)
	third := option_types_unescape(parts[2], "|\\", '\\', allocator)
	return {first, second, third}, .None
}

// option_types_string_triple_to_strings wraps the single value form.
option_types_string_triple_to_strings :: proc(
	t: Option_types_String_Triple,
	allocator := context.allocator,
) -> []string {
	res := make([]string, 1, allocator)
	res[0] = option_types_string_triple_to_string(t, .Raw, allocator)
	return res
}

// option_types_string_triple_from_strings parses exactly one string.
option_types_string_triple_from_strings :: proc(
	strs: []string,
	allocator := context.allocator,
) -> (Option_types_String_Triple, Option_types_Error) {
	if len(strs) != 1 {
		return {}, .ExpectedSingleValue
	}
	return option_types_string_triple_from_string(strs[0], allocator)
}

// Option_types_Prefixed_List pairs a prefix value with a list of values.
// Callers supply the element conversions; the string/triple procs above
// fit the expected shapes.
Option_types_Prefixed_List :: struct($P, $T: typeid) {
	prefix: P,
	list:   [dynamic]T,
}

// option_types_prefixed_list_from_strings parses the prefix from strs[0]
// and the list from the rest; empty input yields zero values.
option_types_prefixed_list_from_strings :: proc(
	$P, $T: typeid,
	strs: []string,
	prefix_from_string: proc(s: string, allocator: runtime.Allocator) -> (P, Option_types_Error),
	elem_from_string: proc(s: string, allocator: runtime.Allocator) -> (T, Option_types_Error),
	allocator := context.allocator,
) -> (Option_types_Prefixed_List(P, T), Option_types_Error) {
	res: Option_types_Prefixed_List(P, T)
	res.list = make([dynamic]T, allocator)
	if len(strs) == 0 {
		return res, .None
	}
	prefix, prefix_err := prefix_from_string(strs[0], allocator)
	if prefix_err != .None {
		delete(res.list)
		return res, prefix_err
	}
	res.prefix = prefix
	for i := 1; i < len(strs); i += 1 {
		elem, elem_err := elem_from_string(strs[i], allocator)
		if elem_err != .None {
			delete(res.list)
			return res, elem_err
		}
		append(&res.list, elem)
	}
	return res, .None
}

// option_types_prefixed_list_to_strings formats the prefix Raw followed
// by each list element Raw.
option_types_prefixed_list_to_strings :: proc(
	opt: Option_types_Prefixed_List($P, $T),
	prefix_to_string: proc(p: P, quoting: Option_types_Quoting, allocator: runtime.Allocator) -> string,
	elem_to_string: proc(e: T, quoting: Option_types_Quoting, allocator: runtime.Allocator) -> string,
	allocator := context.allocator,
) -> []string {
	res := make([]string, 1 + len(opt.list), allocator)
	res[0] = prefix_to_string(opt.prefix, .Raw, allocator)
	for i := 0; i < len(opt.list); i += 1 {
		res[i + 1] = elem_to_string(opt.list[i], .Raw, allocator)
	}
	return res
}

// option_types_prefixed_list_to_string formats "prefix elem..." with the
// given quoting.
option_types_prefixed_list_to_string :: proc(
	opt: Option_types_Prefixed_List($P, $T),
	quoting: Option_types_Quoting,
	prefix_to_string: proc(p: P, quoting: Option_types_Quoting, allocator: runtime.Allocator) -> string,
	elem_to_string: proc(e: T, quoting: Option_types_Quoting, allocator: runtime.Allocator) -> string,
	allocator := context.allocator,
) -> string {
	prefix := prefix_to_string(opt.prefix, quoting, context.temp_allocator)
	elems := make([]string, len(opt.list), context.temp_allocator)
	for i := 0; i < len(opt.list); i += 1 {
		elems[i] = elem_to_string(opt.list[i], quoting, context.temp_allocator)
	}
	list := option_types_join(elems, ' ', false, context.temp_allocator)
	return strings.concatenate({prefix, " ", list}, allocator)
}

// option_types_prefixed_list_add parses all of strs first, then appends
// them to the list; true unless strs is empty.
option_types_prefixed_list_add :: proc(
	opt: ^Option_types_Prefixed_List($P, $T),
	strs: []string,
	elem_from_string: proc(s: string, allocator: runtime.Allocator) -> (T, Option_types_Error),
	allocator := context.allocator,
) -> (bool, Option_types_Error) {
	parsed := make([dynamic]T, allocator)
	defer delete(parsed)
	for i := 0; i < len(strs); i += 1 {
		elem, err := elem_from_string(strs[i], allocator)
		if err != .None {
			return false, err
		}
		append(&parsed, elem)
	}
	append(&opt.list, ..parsed[:])
	return len(parsed) != 0, .None
}

// option_types_prefixed_list_remove parses and drops the first list
// occurrence of each of strs in order; a bad element aborts with
// earlier removals kept. Each parsed probe value is handed to
// free_elem (when given); removed list elements are not freed.
option_types_prefixed_list_remove :: proc(
	opt: ^Option_types_Prefixed_List($P, $T),
	strs: []string,
	elem_from_string: proc(s: string, allocator: runtime.Allocator) -> (T, Option_types_Error),
	free_elem: proc(val: T) = nil,
	allocator := context.allocator,
) -> (bool, Option_types_Error) {
	did_remove := false
	for i := 0; i < len(strs); i += 1 {
		val, err := elem_from_string(strs[i], allocator)
		if err != .None {
			return did_remove, err
		}
		for j := 0; j < len(opt.list); j += 1 {
			if opt.list[j] == val {
				ordered_remove(&opt.list, j)
				did_remove = true
				break
			}
		}
		if free_elem != nil {
			free_elem(val)
		}
	}
	return did_remove, .None
}
