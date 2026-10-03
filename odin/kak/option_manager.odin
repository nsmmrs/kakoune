// Port of src/option_manager.hh and src/option_manager.cc: typed
// options, option managers, and the global options registry.
//
// Mapping notes:
//   * C++ TypedOption<T>/TypedCheckedOption<T> become the single Option
//     struct (knot.odin) holding an Option_Value union: the union variant
//     IS the type. option_manager_option_set rejects values whose variant
//     differs from the stored one (C++ dynamic_cast failure).
//   * C++ validators throw runtime_error; here Option_Validator returns ""
//     when valid or a static message describing the violation. Mutating
//     procs surface that message alongside the error.
//   * C++ throws become Option_Manager_Error (None = ok). Conversions
//     reuse the merged option_types procs; only variants without merged
//     coverage (codepoint lists, Regex, display coords, completion lists,
//     spec lists, string maps) convert here.
//   * Regex option values recompile on clone (regex_make); equality
//     compares pattern strings like C++ Regex::operator==.
//   * option_manager_option_update delegates the two spec-list types to
//     the highlighter module (STUBBED below); every other type reports
//     No_Update like the C++ WorstMatch overload.
//
// Ownership: declare/set clone the passed value into the option (the
// caller keeps its own copy). option_manager_option_get returns a
// borrowed view; option_manager_option_clone returns an owned copy.
// option_manager_flatten_options and complete_name return owned
// containers the caller frees with delete (flattened options stay
// borrowed; completed names are cloned, free them too or use
// option_manager_candidates_free).
package kak

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:sync"

// Option_Manager_Error reports option failures. None (= 0) is success.
Option_Manager_Error :: enum {
	None,
	Not_Found, // option not found: use declare-option first
	Type_Mismatch, // wrong value type, or redeclared with a different type or flags
	Invalid_Name, // name holds a char outside [a-zA-Z0-9_]
	Validation, // the option validator rejected the value (message alongside)
	Convert, // string conversion failed (detail message alongside)
	Regex, // regex pattern failed to compile
	No_Update, // no update operation supported for this option type
	No_Add, // no add operation supported for this option type
	No_Remove, // no remove operation supported for this option type
}

// option_manager_error_message describes an error.
option_manager_error_message :: proc(err: Option_Manager_Error) -> string {
	switch err {
	case .None:
		return ""
	case .Not_Found:
		return "option not found: use declare-option first"
	case .Type_Mismatch:
		return "option already declared with different type or flags"
	case .Invalid_Name:
		return "name contains char out of [a-zA-Z0-9_]"
	case .Validation:
		return "option validation failed"
	case .Convert:
		return "option string conversion failed"
	case .Regex:
		return "invalid regex"
	case .No_Update:
		return "no update operation supported for this option type"
	case .No_Add:
		return "no add operation supported for this option type"
	case .No_Remove:
		return "no remove operation supported for this option type"
	}
	unreachable()
}

// option_manager_value_tag numbers the Option_Value variant so two values
// can be compared for type identity (the C++ dynamic_cast check).
// --- enum/flags/completer-desc option types (deduced declare_option
// value types from src/main.cc). Added at integration: the union grew
// from 12 to 21 variants after this module was written. ---

option_manager_EOL_FORMAT_DESCS := [2]Enum_Desc(Eol_Format){
	{.Lf, "lf"},
	{.Crlf, "crlf"},
}
option_manager_FINAL_EOL_DESCS := [3]Enum_Desc(Final_Eol){
	{.Present, "present"},
	{.Missing, "missing"},
	{.If_Not_Empty, "ifnotempty"},
}
option_manager_BYTE_ORDER_MARK_DESCS := [2]Enum_Desc(Byte_Order_Mark){
	{.None, "none"},
	{.Utf8, "utf8"},
}
option_manager_AUTORELOAD_DESCS := [5]Enum_Desc(Autoreload){
	{.Yes, "yes"},
	{.No, "no"},
	{.Ask, "ask"},
	{.Yes, "true"},
	{.No, "false"},
}
option_manager_AUTO_INFO_DESCS := [3]Enum_Desc(Auto_Info_Flag){
	{.Command, "command"},
	{.On_Key, "onkey"},
	{.Normal, "normal"},
}
option_manager_AUTO_COMPLETE_DESCS := [2]Enum_Desc(Auto_Complete_Flag){
	{.Insert, "insert"},
	{.Prompt, "prompt"},
}
option_manager_DEBUG_FLAGS_DESCS := [5]Enum_Desc(Option_types_Debug_Flag){
	{.Hooks, "hooks"},
	{.Shell, "shell"},
	{.Profile, "profile"},
	{.Keys, "keys"},
	{.Commands, "commands"},
}

// option_manager_enum_to_string clones the FIRST desc name for e (C++
// option_to_string(Enum) finds the first match, so Autoreload.Yes -> "yes").
option_manager_enum_to_string :: proc(e: $E, descs: []Enum_Desc(E), allocator := context.allocator) -> string {
	name, ok := enum_to_name(descs, e)
	assert(ok)
	return strings.clone(name, allocator)
}

// option_manager_enum_from_string parses a desc name (C++
// option_from_string(Enum) throws "invalid enum value" on miss).
option_manager_enum_from_string :: proc($E: typeid, s: string, descs: []Enum_Desc(E)) -> (E, bool) {
	return enum_from_name(descs, s)
}

// option_manager_flags_to_string joins set flag names with '|' in desc
// order (C++ option_to_string(Flags)); empty set formats as "".
option_manager_flags_to_string :: proc(flags: $F, descs: []Enum_Desc($G), allocator := context.allocator) -> string {
	names := make([dynamic]string, 0, len(descs), context.temp_allocator)
	defer delete(names)
	for d in descs {
		if d.value in flags {
			append(&names, d.name)
		}
	}
	return strings.join(names[:], "|", allocator)
}

// option_manager_flags_from_string parses '|' separated flag names (C++
// option_from_string(Flags) throws "invalid flag value" on miss,
// including on empty segments, so "" itself is invalid).
option_manager_flags_from_string :: proc($F: typeid, $G: typeid, s: string, descs: []Enum_Desc(G), allocator := context.allocator) -> (F, bool) {
	_ = allocator
	parts := strings.split(s, "|", context.temp_allocator)
	defer delete(parts, context.temp_allocator)
	flags: F
	for part in parts {
		flag, ok := enum_from_name(descs, part)
		if !ok {
			return {}, false
		}
		flags += {flag}
	}
	return flags, true
}

// option_manager_completer_desc_to_string formats one completer (C++
// option_to_string(InsertCompleterDesc)): "word=all|buffer",
// "filename", "option=<name>", "line=all|buffer".
option_manager_completer_desc_to_string :: proc(d: Insert_Completer_Desc, allocator := context.allocator) -> string {
	switch d.mode {
	case .Word:
		return strings.concatenate({"word=", d.param.? or_else ""}, allocator)
	case .Filename:
		return strings.clone("filename", allocator)
	case .Option:
		return strings.concatenate({"option=", d.param.? or_else ""}, allocator)
	case .Line:
		return strings.concatenate({"line=", d.param.? or_else ""}, allocator)
	}
	unreachable()
}

// option_manager_completer_desc_from_string parses one completer (C++
// option_from_string throws "invalid completer description" on miss).
option_manager_completer_desc_from_string :: proc(s: string, allocator := context.allocator) -> (Insert_Completer_Desc, bool) {
	if strings.has_prefix(s, "option=") {
		return Insert_Completer_Desc{mode = .Option, param = strings.clone(s[7:], allocator)}, true
	}
	if strings.has_prefix(s, "word=") {
		param := s[5:]
		if param == "all" || param == "buffer" {
			return Insert_Completer_Desc{mode = .Word, param = strings.clone(param, allocator)}, true
		}
		return {}, false
	}
	if s == "filename" {
		return Insert_Completer_Desc{mode = .Filename}, true
	}
	if strings.has_prefix(s, "line=") {
		param := s[5:]
		if param == "all" || param == "buffer" {
			return Insert_Completer_Desc{mode = .Line, param = strings.clone(param, allocator)}, true
		}
		return {}, false
	}
	return {}, false
}

option_manager_completer_desc_clone :: proc(d: Insert_Completer_Desc, allocator := context.allocator) -> Insert_Completer_Desc {
	if p, ok := d.param.?; ok {
		return Insert_Completer_Desc{mode = d.mode, param = strings.clone(p, allocator)}
	}
	return Insert_Completer_Desc{mode = d.mode}
}

option_manager_completer_desc_free :: proc(d: Insert_Completer_Desc, allocator := context.allocator) {
	if p, ok := d.param.?; ok {
		delete(p, allocator)
	}
}

// option_manager_completer_descs_to_string ports the Vector<T> to_string
// (space-joined, no escaping); desc formatting ignores quoting.
option_manager_completer_descs_to_string :: proc(
	vec: []Insert_Completer_Desc,
	quoting: Option_types_Quoting,
	allocator := context.allocator,
) -> string {
	_ = quoting
	entries := make([]string, len(vec), context.temp_allocator)
	for i := 0; i < len(vec); i += 1 {
		entries[i] = option_manager_completer_desc_to_string(vec[i], context.temp_allocator)
	}
	return option_types_join(entries, ' ', false, allocator)
}

// option_manager_completer_descs_to_strings formats each desc Raw.
option_manager_completer_descs_to_strings :: proc(
	vec: []Insert_Completer_Desc,
	allocator := context.allocator,
) -> []string {
	res := make([]string, len(vec), allocator)
	for i := 0; i < len(vec); i += 1 {
		res[i] = option_manager_completer_desc_to_string(vec[i], allocator)
	}
	return res
}

option_manager_value_tag :: proc(val: Option_Value) -> int {
	switch _ in val {
	case int:
		return 0
	case bool:
		return 1
	case string:
		return 2
	case [dynamic]string:
		return 3
	case [dynamic]int:
		return 4
	case [dynamic]rune:
		return 5
	case Regex:
		return 6
	case Coord_Display:
		return 7
	case Insert_Completer_Completion_List:
		return 8
	case Option_Timestamped_List(Line_And_Spec):
		return 9
	case Option_Timestamped_List(Range_And_String):
		return 10
	case map[string]string:
		return 11
	case Eol_Format:
		return 12
	case Final_Eol:
		return 13
	case Byte_Order_Mark:
		return 14
	case Autoreload:
		return 15
	case Auto_Info:
		return 16
	case Auto_Complete:
		return 17
	case Option_types_Debug_Flags:
		return 18
	case [dynamic]Insert_Completer_Desc:
		return 19
	case File_Write_Method:
		return 20
	}
	unreachable()
}

// option_manager_value_type_name ports option_type_name for each variant.
option_manager_value_type_name :: proc(val: Option_Value) -> string {
	switch _ in val {
	case int:
		return option_types_int_type_name()
	case bool:
		return option_types_bool_type_name()
	case string:
		return option_types_string_type_name()
	case [dynamic]string:
		return option_types_string_list_type_name()
	case [dynamic]int:
		return option_types_int_list_type_name()
	case [dynamic]rune:
		return "codepoint-list"
	case Regex:
		return "regex"
	case Coord_Display:
		return "coord"
	case Insert_Completer_Completion_List:
		return "completions"
	case Option_Timestamped_List(Line_And_Spec):
		return "line-specs"
	case Option_Timestamped_List(Range_And_String):
		return "range-specs"
	case map[string]string:
		return "str-to-str-map"
	case Eol_Format:
		return "enum(lf|crlf)"
	case Final_Eol:
		return "enum(present|missing|ifnotempty)"
	case Byte_Order_Mark:
		return "enum(none|utf8)"
	case Autoreload:
		return "enum(yes|no|ask|true|false)"
	case Auto_Info:
		return "flags(command|onkey|normal)"
	case Auto_Complete:
		return "flags(insert|prompt)"
	case Option_types_Debug_Flags:
		return "flags(hooks|shell|profile|keys|commands)"
	case [dynamic]Insert_Completer_Desc:
		return "completer-list"
	case File_Write_Method:
		return "enum(overwrite|replace)"
	}
	unreachable()
}

// option_manager_value_clone deep-copies a value into allocator.
option_manager_value_clone :: proc(val: Option_Value, allocator := context.allocator) -> Option_Value {
	switch v in val {
	case int:
		return v
	case bool:
		return v
	case string:
		return strings.clone(v, allocator)
	case [dynamic]string:
		res := make([dynamic]string, len(v), allocator)
		for i := 0; i < len(v); i += 1 {
			res[i] = strings.clone(v[i], allocator)
		}
		return res
	case [dynamic]int:
		res := make([dynamic]int, len(v), allocator)
		copy(res[:], v[:])
		return res
	case [dynamic]rune:
		res := make([dynamic]rune, len(v), allocator)
		copy(res[:], v[:])
		return res
	case Regex:
		rc := v
		re, msg, err := regex_make(regex_str(&rc), {}, allocator)
		if err != .None {
			delete(msg, allocator)
			return Regex{}
		}
		return re
	case Coord_Display:
		return v
	case Insert_Completer_Completion_List:
		res := Insert_Completer_Completion_List {
			prefix = strings.clone(v.prefix, allocator),
			list   = make([dynamic]Completion_Candidate, len(v.list), allocator),
		}
		for i := 0; i < len(v.list); i += 1 {
			res.list[i] = Completion_Candidate {
				completion = strings.clone(v.list[i].completion, allocator),
				menu_entry = strings.clone(v.list[i].menu_entry, allocator),
				on_select  = strings.clone(v.list[i].on_select, allocator),
			}
		}
		return res
	case Option_Timestamped_List(Line_And_Spec):
		res := Option_Timestamped_List(Line_And_Spec) {
			prefixed = Option_types_Prefixed_List(uint, Line_And_Spec) {
				prefix = v.prefix,
				list   = make([dynamic]Line_And_Spec, len(v.list), allocator),
			},
		}
		for i := 0; i < len(v.list); i += 1 {
			res.list[i] = Line_And_Spec{line = v.list[i].line, spec = strings.clone(v.list[i].spec, allocator)}
		}
		return res
	case Option_Timestamped_List(Range_And_String):
		res := Option_Timestamped_List(Range_And_String) {
			prefixed = Option_types_Prefixed_List(uint, Range_And_String) {
				prefix = v.prefix,
				list   = make([dynamic]Range_And_String, len(v.list), allocator),
			},
		}
		for i := 0; i < len(v.list); i += 1 {
			res.list[i] = Range_And_String {
				range = v.list[i].range,
				spec  = strings.clone(v.list[i].spec, allocator),
			}
		}
		return res
	case map[string]string:
		res := make(map[string]string, len(v), allocator)
		for k, e in v {
			res[strings.clone(k, allocator)] = strings.clone(e, allocator)
		}
		return res
	case Eol_Format, Final_Eol, Byte_Order_Mark, Autoreload, Auto_Info, Auto_Complete, Option_types_Debug_Flags, File_Write_Method:
		return v
	case [dynamic]Insert_Completer_Desc:
		res := make([dynamic]Insert_Completer_Desc, len(v), allocator)
		for i := 0; i < len(v); i += 1 {
			res[i] = option_manager_completer_desc_clone(v[i], allocator)
		}
		return res
	}
	unreachable()
}

// option_manager_value_destroy frees the heap parts of a value allocated
// with allocator. The value itself must not be used afterwards.
option_manager_value_destroy :: proc(val: ^Option_Value, allocator := context.allocator) {
	switch v in val^ {
	case int, bool, Coord_Display, Eol_Format, Final_Eol, Byte_Order_Mark, Autoreload, Auto_Info, Auto_Complete, Option_types_Debug_Flags, File_Write_Method:
	// nothing owned
	case string:
		delete(v, allocator)
	case [dynamic]string:
		for s in v {
			delete(s, allocator)
		}
		delete(v)
	case [dynamic]int:
		delete(v)
	case [dynamic]rune:
		delete(v)
	case Regex:
		rc := v
		regex_destroy(&rc)
	case Insert_Completer_Completion_List:
		delete(v.prefix, allocator)
		for c in v.list {
			delete(c.completion, allocator)
			delete(c.menu_entry, allocator)
			delete(c.on_select, allocator)
		}
		delete(v.list)
	case Option_Timestamped_List(Line_And_Spec):
		for e in v.list {
			delete(e.spec, allocator)
		}
		delete(v.list)
	case Option_Timestamped_List(Range_And_String):
		for e in v.list {
			delete(e.spec, allocator)
		}
		delete(v.list)
	case map[string]string:
		for k, e in v {
			delete(k, allocator)
			delete(e, allocator)
		}
		delete(v)
	case [dynamic]Insert_Completer_Desc:
		for e in v {
			option_manager_completer_desc_free(e, allocator)
		}
		delete(v)
	}
}

// option_manager_value_equal reports whether two values hold the same
// variant with equal contents (C++ TypedOption::has_same_value).
option_manager_value_equal :: proc(a, b: Option_Value) -> bool {
	switch av in a {
	case int:
		bv, ok := b.(int)
		return ok && av == bv
	case bool:
		bv, ok := b.(bool)
		return ok && av == bv
	case string:
		bv, ok := b.(string)
		return ok && av == bv
	case [dynamic]string:
		bv, ok := b.([dynamic]string)
		return ok && slice.equal(av[:], bv[:])
	case [dynamic]int:
		bv, ok := b.([dynamic]int)
		return ok && slice.equal(av[:], bv[:])
	case [dynamic]rune:
		bv, ok := b.([dynamic]rune)
		return ok && slice.equal(av[:], bv[:])
	case Regex:
		bv, ok := b.(Regex)
		if !ok {
			return false
		}
		ra, rb := av, bv
		return regex_str(&ra) == regex_str(&rb)
	case Coord_Display:
		bv, ok := b.(Coord_Display)
		return ok && av == bv
	case Eol_Format:
		bv, ok := b.(Eol_Format)
		return ok && av == bv
	case Final_Eol:
		bv, ok := b.(Final_Eol)
		return ok && av == bv
	case Byte_Order_Mark:
		bv, ok := b.(Byte_Order_Mark)
		return ok && av == bv
	case Autoreload:
		bv, ok := b.(Autoreload)
		return ok && av == bv
	case Auto_Info:
		bv, ok := b.(Auto_Info)
		return ok && av == bv
	case Auto_Complete:
		bv, ok := b.(Auto_Complete)
		return ok && av == bv
	case Option_types_Debug_Flags:
		bv, ok := b.(Option_types_Debug_Flags)
		return ok && av == bv
	case Insert_Completer_Completion_List:
		bv, ok := b.(Insert_Completer_Completion_List)
		return ok && av.prefix == bv.prefix && slice.equal(av.list[:], bv.list[:])
	case Option_Timestamped_List(Line_And_Spec):
		bv, ok := b.(Option_Timestamped_List(Line_And_Spec))
		return ok && av.prefix == bv.prefix && slice.equal(av.list[:], bv.list[:])
	case Option_Timestamped_List(Range_And_String):
		bv, ok := b.(Option_Timestamped_List(Range_And_String))
		return ok && av.prefix == bv.prefix && slice.equal(av.list[:], bv.list[:])
	case map[string]string:
		bv, ok := b.(map[string]string)
		if !ok || len(av) != len(bv) {
			return false
		}
		for k, e in av {
			ev, found := bv[k]
			if !found || ev != e {
				return false
			}
		}
		return true
	case [dynamic]Insert_Completer_Desc:
		bv, ok := b.([dynamic]Insert_Completer_Desc)
		return ok && slice.equal(av[:], bv[:])
	case File_Write_Method:
		bv, ok := b.(File_Write_Method)
		return ok && av == bv
	}
	unreachable()
}

// option_manager_rune_list_to_strings formats each codepoint Raw.
option_manager_rune_list_to_strings :: proc(vec: []rune, allocator := context.allocator) -> []string {
	res := make([]string, len(vec), allocator)
	for i := 0; i < len(vec); i += 1 {
		res[i] = option_types_codepoint_to_string(vec[i], .Raw, allocator)
	}
	return res
}

// option_manager_rune_list_to_string quotes each element and joins with
// a space, without escaping.
option_manager_rune_list_to_string :: proc(
	vec: []rune,
	quoting: Option_types_Quoting,
	allocator := context.allocator,
) -> string {
	quoted := make([]string, len(vec), context.temp_allocator)
	for i := 0; i < len(vec); i += 1 {
		quoted[i] = option_types_codepoint_to_string(vec[i], quoting, context.temp_allocator)
	}
	return option_types_join(quoted, ' ', false, allocator)
}

// option_manager_rune_list_from_strings parses each element.
option_manager_rune_list_from_strings :: proc(
	strs: []string,
	allocator := context.allocator,
) -> ([dynamic]rune, Option_types_Error) {
	res := make([dynamic]rune, len(strs), allocator)
	for i := 0; i < len(strs); i += 1 {
		c, err := option_types_codepoint_from_string(strs[i])
		if err != .None {
			delete(res)
			return nil, err
		}
		res[i] = c
	}
	return res, .None
}

// option_manager_coord_to_string formats a display coord as
// "<line>,<column>" (quoting is ignored like the C++ which has no
// quoting overload for coords).
option_manager_coord_to_string :: proc(c: Coord_Display, allocator := context.allocator) -> string {
	return fmt.aprintf("%d,%d", int(c.line), int(c.column), allocator = allocator)
}

// option_manager_coord_from_string parses "<line>,<column>".
option_manager_coord_from_string :: proc(s: string) -> (Coord_Display, Option_types_Error) {
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
	return Coord_Display{line = Coord_Line(line), column = Coord_Column(column)}, .None
}

// option_manager_candidate_to_string formats one completion candidate as
// "completion|on_select|menu_entry" (the C++ tuple element order).
option_manager_candidate_to_string :: proc(
	c: Completion_Candidate,
	quoting: Option_types_Quoting,
	allocator := context.allocator,
) -> string {
	elems := [3]string{c.completion, c.on_select, c.menu_entry}
	joined := option_types_join(elems[:], option_types_TUPLE_SEPARATOR, true, context.temp_allocator)
	return option_types_apply_quoting(quoting, joined, allocator)
}

// option_manager_candidate_from_string parses one candidate. Parts are
// owned by the caller.
option_manager_candidate_from_string :: proc(
	s: string,
	allocator := context.allocator,
) -> (Completion_Candidate, Option_types_Error) {
	parts := option_types_split_escaped(s, option_types_TUPLE_SEPARATOR, '\\', context.temp_allocator)
	if len(parts) < 3 {
		return {}, .TupleTooFewElements
	}
	if len(parts) > 3 {
		return {}, .TupleTooManyElements
	}
	completion := option_types_unescape(parts[0], "|\\", '\\', allocator)
	on_select := option_types_unescape(parts[1], "|\\", '\\', allocator)
	menu_entry := option_types_unescape(parts[2], "|\\", '\\', allocator)
	return Completion_Candidate{completion = completion, menu_entry = menu_entry, on_select = on_select}, .None
}

// option_manager_candidate_free frees the owned strings of a parsed probe.
option_manager_candidate_free :: proc(c: Completion_Candidate, allocator := context.allocator) {
	delete(c.completion, allocator)
	delete(c.menu_entry, allocator)
	delete(c.on_select, allocator)
}

// option_manager_completion_list_to_strings formats the prefix Raw
// followed by each candidate Raw.
option_manager_completion_list_to_strings :: proc(
	opt: Insert_Completer_Completion_List,
	allocator := context.allocator,
) -> []string {
	res := make([]string, 1 + len(opt.list), allocator)
	res[0] = strings.clone(opt.prefix, allocator)
	for i := 0; i < len(opt.list); i += 1 {
		res[i + 1] = option_manager_candidate_to_string(opt.list[i], .Raw, allocator)
	}
	return res
}

// option_manager_completion_list_to_string formats "prefix elem...".
option_manager_completion_list_to_string :: proc(
	opt: Insert_Completer_Completion_List,
	quoting: Option_types_Quoting,
	allocator := context.allocator,
) -> string {
	prefix := option_types_string_to_string(opt.prefix, quoting, context.temp_allocator)
	elems := make([]string, len(opt.list), context.temp_allocator)
	for i := 0; i < len(opt.list); i += 1 {
		elems[i] = option_manager_candidate_to_string(opt.list[i], quoting, context.temp_allocator)
	}
	list := option_types_join(elems, ' ', false, context.temp_allocator)
	return strings.concatenate({prefix, " ", list}, allocator)
}

// option_manager_completion_list_from_strings parses the prefix from
// strs[0] and the candidates from the rest; empty input yields zero
// values like the C++ PrefixedList overload.
option_manager_completion_list_from_strings :: proc(
	strs: []string,
	allocator := context.allocator,
) -> (Insert_Completer_Completion_List, Option_types_Error) {
	res := Insert_Completer_Completion_List{list = make([dynamic]Completion_Candidate, allocator)}
	if len(strs) == 0 {
		return res, .None
	}
	res.prefix = strings.clone(strs[0], allocator)
	for i := 1; i < len(strs); i += 1 {
		elem, err := option_manager_candidate_from_string(strs[i], allocator)
		if err != .None {
			option_manager_completion_list_destroy(&res, allocator)
			return {}, err
		}
		append(&res.list, elem)
	}
	return res, .None
}

// option_manager_completion_list_destroy frees a parsed list.
option_manager_completion_list_destroy :: proc(
	opt: ^Insert_Completer_Completion_List,
	allocator := context.allocator,
) {
	delete(opt.prefix, allocator)
	for c in opt.list {
		option_manager_candidate_free(c, allocator)
	}
	delete(opt.list)
}

// option_manager_line_spec_to_string formats one line-spec as
// "line|spec" (the C++ tuple form; the line stays 0-based).
option_manager_line_spec_to_string :: proc(
	e: Line_And_Spec,
	quoting: Option_types_Quoting,
	allocator := context.allocator,
) -> string {
	line := option_types_int_to_string(int(e.line), context.temp_allocator)
	elems := [2]string{line, e.spec}
	joined := option_types_join(elems[:], option_types_TUPLE_SEPARATOR, true, context.temp_allocator)
	return option_types_apply_quoting(quoting, joined, allocator)
}

// option_manager_line_spec_from_string parses one line-spec.
option_manager_line_spec_from_string :: proc(
	s: string,
	allocator := context.allocator,
) -> (Line_And_Spec, Option_types_Error) {
	parts := option_types_split_escaped(s, option_types_TUPLE_SEPARATOR, '\\', context.temp_allocator)
	if len(parts) < 2 {
		return {}, .TupleTooFewElements
	}
	if len(parts) > 2 {
		return {}, .TupleTooManyElements
	}
	line, err := option_types_str_to_int(parts[0])
	if err != .None {
		return {}, err
	}
	spec := option_types_unescape(parts[1], "|\\", '\\', allocator)
	return Line_And_Spec{line = Coord_Line(line), spec = spec}, .None
}

// option_manager_line_spec_free frees a parsed probe's spec.
option_manager_line_spec_free :: proc(e: Line_And_Spec, allocator := context.allocator) {
	delete(e.spec, allocator)
}

// option_manager_line_spec_less orders specs by line (C++
// option_list_postprocess for LineAndSpec).
option_manager_line_spec_less :: proc(a, b: Line_And_Spec) -> bool {
	return a.line < b.line
}

// option_manager_line_specs_sort sorts the list by line.
option_manager_line_specs_sort :: proc(list: ^[dynamic]Line_And_Spec) {
	slice.sort_by(list[:], option_manager_line_spec_less)
}

// option_manager_line_specs_to_strings formats the timestamp prefix Raw
// followed by each spec Raw.
option_manager_line_specs_to_strings :: proc(
	opt: Line_And_Spec_List,
	allocator := context.allocator,
) -> []string {
	res := make([]string, 1 + len(opt.list), allocator)
	res[0] = option_types_uint_to_string(opt.prefix, allocator)
	for i := 0; i < len(opt.list); i += 1 {
		res[i + 1] = option_manager_line_spec_to_string(opt.list[i], .Raw, allocator)
	}
	return res
}

// option_manager_line_specs_to_string formats "prefix elem...".
option_manager_line_specs_to_string :: proc(
	opt: Line_And_Spec_List,
	quoting: Option_types_Quoting,
	allocator := context.allocator,
) -> string {
	prefix := option_types_uint_to_string(opt.prefix, context.temp_allocator)
	elems := make([]string, len(opt.list), context.temp_allocator)
	for i := 0; i < len(opt.list); i += 1 {
		elems[i] = option_manager_line_spec_to_string(opt.list[i], quoting, context.temp_allocator)
	}
	list := option_types_join(elems, ' ', false, context.temp_allocator)
	return strings.concatenate({prefix, " ", list}, allocator)
}

// option_manager_line_specs_from_strings parses the timestamp prefix and
// the specs, sorting the list like option_list_postprocess.
option_manager_line_specs_from_strings :: proc(
	strs: []string,
	allocator := context.allocator,
) -> (Line_And_Spec_List, Option_types_Error) {
	res := Line_And_Spec_List {
		prefixed = Option_types_Prefixed_List(uint, Line_And_Spec){list = make([dynamic]Line_And_Spec, allocator)},
	}
	if len(strs) == 0 {
		return res, .None
	}
	prefix, prefix_err := option_types_uint_from_string(strs[0])
	if prefix_err != .None {
		delete(res.list)
		return {}, prefix_err
	}
	res.prefix = prefix
	for i := 1; i < len(strs); i += 1 {
		elem, err := option_manager_line_spec_from_string(strs[i], allocator)
		if err != .None {
			option_manager_line_specs_destroy(&res, allocator)
			return {}, err
		}
		append(&res.list, elem)
	}
	option_manager_line_specs_sort(&res.list)
	return res, .None
}

// option_manager_line_specs_destroy frees a parsed spec list.
option_manager_line_specs_destroy :: proc(opt: ^Line_And_Spec_List, allocator := context.allocator) {
	for e in opt.list {
		option_manager_line_spec_free(e, allocator)
	}
	delete(opt.list)
}

// option_manager_inclusive_range_empty ports C++ is_empty for ranges.
option_manager_inclusive_range_empty :: proc(r: Inclusive_Buffer_Range) -> bool {
	return int(r.last.line) < 0 || (int(r.last.line) == 0 && int(r.last.column) < 0)
}

// option_manager_inclusive_range_to_string formats a range 1-based as
// "<line>.<col>,<line>.<col>" or "<line>.<col>+0" when empty.
option_manager_inclusive_range_to_string :: proc(
	r: Inclusive_Buffer_Range,
	allocator := context.allocator,
) -> string {
	if option_manager_inclusive_range_empty(r) {
		return fmt.aprintf(
			"{}.{}+0",
			int(r.first.line) + 1,
			int(r.first.column) + 1,
			allocator = allocator,
		)
	}
	return fmt.aprintf(
		"{}.{},{}.{}",
		int(r.first.line) + 1,
		int(r.first.column) + 1,
		int(r.last.line) + 1,
		int(r.last.column) + 1,
		allocator = allocator,
	)
}

// option_manager_inclusive_range_from_string parses "<line>.<column>,
// <line>.<column>" or "<line>.<column>+<len>" (all 1-based).
option_manager_inclusive_range_from_string :: proc(s: string) -> (Inclusive_Buffer_Range, Option_types_Error) {
	sep := -1
	for i := 0; i < len(s); i += 1 {
		if s[i] == ',' || s[i] == '+' {
			sep = i
			break
		}
	}
	if sep < 0 {
		return {}, .ExpectedLineColumn
	}
	dot_beg := -1
	for i := 0; i < sep; i += 1 {
		if s[i] == '.' {
			dot_beg = i
			break
		}
	}
	dot_end := -1
	for i := sep; i < len(s); i += 1 {
		if s[i] == '.' {
			dot_end = i
			break
		}
	}
	if dot_beg < 0 || (s[sep] == ',' && dot_end < 0) {
		return {}, .ExpectedLineColumn
	}
	first_line, err := option_types_str_to_int(s[:dot_beg])
	if err != .None {
		return {}, err
	}
	first_col, err2 := option_types_str_to_int(s[dot_beg + 1:sep])
	if err2 != .None {
		return {}, err2
	}
	first := Coord_Buffer{line = Coord_Line(first_line - 1), column = Coord_Byte(first_col - 1)}
	if first_line - 1 < 0 || first_col - 1 < 0 {
		return {}, .ExpectedLineColumn
	}
	if s[sep] == '+' {
		length, len_err := option_types_str_to_int(s[sep + 1:])
		if len_err != .None {
			return {}, len_err
		}
		if length == 0 {
			return Inclusive_Buffer_Range{first = first, last = Coord_Buffer{line = -1, column = -1}}, .None
		}
		return Inclusive_Buffer_Range {
			first = first,
			last = Coord_Buffer{line = first.line, column = Coord_Byte(int(first.column) + length - 1)},
		}, .None
	}
	last_line, err3 := option_types_str_to_int(s[sep + 1:dot_end])
	if err3 != .None {
		return {}, err3
	}
	last_col, err4 := option_types_str_to_int(s[dot_end + 1:])
	if err4 != .None {
		return {}, err4
	}
	if last_line - 1 < 0 || last_col - 1 < 0 {
		return {}, .ExpectedLineColumn
	}
	last := Coord_Buffer{line = Coord_Line(last_line - 1), column = Coord_Byte(last_col - 1)}
	if option_manager_buffer_coord_less(last, first) {
		return Inclusive_Buffer_Range{first = last, last = first}, .None
	}
	return Inclusive_Buffer_Range{first = first, last = last}, .None
}

// option_manager_buffer_coord_less orders buffer coords lexicographically.
option_manager_buffer_coord_less :: proc(a, b: Coord_Buffer) -> bool {
	if a.line != b.line {
		return a.line < b.line
	}
	return a.column < b.column
}

// option_manager_range_spec_to_string formats one range-spec as
// "range|spec".
option_manager_range_spec_to_string :: proc(
	e: Range_And_String,
	quoting: Option_types_Quoting,
	allocator := context.allocator,
) -> string {
	range := option_manager_inclusive_range_to_string(e.range, context.temp_allocator)
	elems := [2]string{range, e.spec}
	joined := option_types_join(elems[:], option_types_TUPLE_SEPARATOR, true, context.temp_allocator)
	return option_types_apply_quoting(quoting, joined, allocator)
}

// option_manager_range_spec_from_string parses one range-spec.
option_manager_range_spec_from_string :: proc(
	s: string,
	allocator := context.allocator,
) -> (Range_And_String, Option_types_Error) {
	parts := option_types_split_escaped(s, option_types_TUPLE_SEPARATOR, '\\', context.temp_allocator)
	if len(parts) < 2 {
		return {}, .TupleTooFewElements
	}
	if len(parts) > 2 {
		return {}, .TupleTooManyElements
	}
	range, err := option_manager_inclusive_range_from_string(parts[0])
	if err != .None {
		return {}, err
	}
	spec := option_types_unescape(parts[1], "|\\", '\\', allocator)
	return Range_And_String{range = range, spec = spec}, .None
}

// option_manager_range_spec_free frees a parsed probe's spec.
option_manager_range_spec_free :: proc(e: Range_And_String, allocator := context.allocator) {
	delete(e.spec, allocator)
}

// option_manager_range_spec_less orders specs by (first, last) like C++
// option_element_compare.
option_manager_range_spec_less :: proc(a, b: Range_And_String) -> bool {
	if a.range.first != b.range.first {
		return option_manager_buffer_coord_less(a.range.first, b.range.first)
	}
	return option_manager_buffer_coord_less(a.range.last, b.range.last)
}

// option_manager_range_specs_sort sorts the list by (first, last).
option_manager_range_specs_sort :: proc(list: ^[dynamic]Range_And_String) {
	slice.sort_by(list[:], option_manager_range_spec_less)
}

// option_manager_range_specs_to_strings formats the timestamp prefix Raw
// followed by each spec Raw.
option_manager_range_specs_to_strings :: proc(
	opt: Range_And_String_List,
	allocator := context.allocator,
) -> []string {
	res := make([]string, 1 + len(opt.list), allocator)
	res[0] = option_types_uint_to_string(opt.prefix, allocator)
	for i := 0; i < len(opt.list); i += 1 {
		res[i + 1] = option_manager_range_spec_to_string(opt.list[i], .Raw, allocator)
	}
	return res
}

// option_manager_range_specs_to_string formats "prefix elem...".
option_manager_range_specs_to_string :: proc(
	opt: Range_And_String_List,
	quoting: Option_types_Quoting,
	allocator := context.allocator,
) -> string {
	prefix := option_types_uint_to_string(opt.prefix, context.temp_allocator)
	elems := make([]string, len(opt.list), context.temp_allocator)
	for i := 0; i < len(opt.list); i += 1 {
		elems[i] = option_manager_range_spec_to_string(opt.list[i], quoting, context.temp_allocator)
	}
	list := option_types_join(elems, ' ', false, context.temp_allocator)
	return strings.concatenate({prefix, " ", list}, allocator)
}

// option_manager_range_specs_from_strings parses the timestamp prefix and
// the specs, sorting the list like option_list_postprocess.
option_manager_range_specs_from_strings :: proc(
	strs: []string,
	allocator := context.allocator,
) -> (Range_And_String_List, Option_types_Error) {
	res := Range_And_String_List {
		prefixed = Option_types_Prefixed_List(uint, Range_And_String){list = make([dynamic]Range_And_String, allocator)},
	}
	if len(strs) == 0 {
		return res, .None
	}
	prefix, prefix_err := option_types_uint_from_string(strs[0])
	if prefix_err != .None {
		delete(res.list)
		return {}, prefix_err
	}
	res.prefix = prefix
	for i := 1; i < len(strs); i += 1 {
		elem, err := option_manager_range_spec_from_string(strs[i], allocator)
		if err != .None {
			option_manager_range_specs_destroy(&res, allocator)
			return {}, err
		}
		append(&res.list, elem)
	}
	option_manager_range_specs_sort(&res.list)
	return res, .None
}

// option_manager_range_specs_destroy frees a parsed spec list.
option_manager_range_specs_destroy :: proc(opt: ^Range_And_String_List, allocator := context.allocator) {
	for e in opt.list {
		option_manager_range_spec_free(e, allocator)
	}
	delete(opt.list)
}

// option_manager_map_entry formats one "key=value" entry, escaping '='.
option_manager_map_entry :: proc(key, value: string, allocator := context.allocator) -> string {
	ek := option_types_escape(key, "=", '\\', context.temp_allocator)
	ev := option_types_escape(value, "=", '\\', context.temp_allocator)
	return strings.concatenate({ek, "=", ev}, allocator)
}

// option_manager_map_to_strings formats every entry. Order follows map
// iteration order, which is not deterministic.
option_manager_map_to_strings :: proc(m: map[string]string, allocator := context.allocator) -> []string {
	res := make([]string, len(m), allocator)
	i := 0
	for k, v in m {
		res[i] = option_manager_map_entry(k, v, allocator)
		i += 1
	}
	return res
}

// option_manager_map_to_string quotes each entry and joins with a space.
option_manager_map_to_string :: proc(
	m: map[string]string,
	quoting: Option_types_Quoting,
	allocator := context.allocator,
) -> string {
	entries := make([]string, len(m), context.temp_allocator)
	i := 0
	for k, v in m {
		entry := option_manager_map_entry(k, v, context.temp_allocator)
		entries[i] = option_types_apply_quoting(quoting, entry, context.temp_allocator)
		i += 1
	}
	return option_types_join(entries, ' ', false, allocator)
}

// option_manager_map_add parses each entry in order and stores it (later
// duplicates win). A bad entry aborts with earlier entries kept, like
// the C++ sequential loop.
option_manager_map_add :: proc(
	m: ^map[string]string,
	strs: []string,
	allocator := context.allocator,
) -> (bool, Option_types_Error) {
	for i := 0; i < len(strs); i += 1 {
		key, val, pair_err := option_types_string_int_map_pair(strs[i])
		if pair_err != .None {
			return false, pair_err
		}
		if key in m^ {
			delete(m^[key], allocator)
			m^[key] = strings.clone(val, allocator)
		} else {
			m^[strings.clone(key, allocator)] = strings.clone(val, allocator)
		}
	}
	return len(strs) != 0, .None
}

// option_manager_map_remove drops the entry named by each "key[=value]"
// entry when the key exists and the value part is empty or equals the
// stored value.
option_manager_map_remove :: proc(
	m: ^map[string]string,
	strs: []string,
	allocator := context.allocator,
) -> (bool, Option_types_Error) {
	changed := false
	for i := 0; i < len(strs); i += 1 {
		key, val, pair_err := option_types_string_int_map_pair(strs[i])
		if pair_err != .None {
			return changed, pair_err
		}
		stored := ""
		found := false
		for k in m^ {
			if k == key {
				stored = k
				found = true
				break
			}
		}
		if !found {
			continue
		}
		if len(val) == 0 || val == m^[stored] {
			delete(m^[stored], allocator)
			delete_key(m, stored)
			delete(stored, allocator)
			changed = true
		}
	}
	return changed, .None
}

// option_manager_value_to_string formats one value (C++ get_as_string).
option_manager_value_to_string :: proc(
	val: Option_Value,
	quoting: Option_types_Quoting,
	allocator := context.allocator,
) -> string {
	switch v in val {
	case int:
		return option_types_int_to_string(v, allocator)
	case bool:
		return strings.clone(option_types_bool_to_string(v), allocator)
	case string:
		return option_types_string_to_string(v, quoting, allocator)
	case [dynamic]string:
		return option_types_string_list_to_string(v[:], quoting, allocator)
	case [dynamic]int:
		return option_types_int_list_to_string(v[:], allocator)
	case [dynamic]rune:
		return option_manager_rune_list_to_string(v[:], quoting, allocator)
	case Regex:
		rc := v
		return option_types_string_to_string(regex_str(&rc), quoting, allocator)
	case Coord_Display:
		return option_manager_coord_to_string(v, allocator)
	case Insert_Completer_Completion_List:
		return option_manager_completion_list_to_string(v, quoting, allocator)
	case Option_Timestamped_List(Line_And_Spec):
		return option_manager_line_specs_to_string(v, quoting, allocator)
	case Option_Timestamped_List(Range_And_String):
		return option_manager_range_specs_to_string(v, quoting, allocator)
	case map[string]string:
		return option_manager_map_to_string(v, quoting, allocator)
	case Eol_Format:
		return option_manager_enum_to_string(v, option_manager_EOL_FORMAT_DESCS[:], allocator)
	case Final_Eol:
		return option_manager_enum_to_string(v, option_manager_FINAL_EOL_DESCS[:], allocator)
	case Byte_Order_Mark:
		return option_manager_enum_to_string(v, option_manager_BYTE_ORDER_MARK_DESCS[:], allocator)
	case Autoreload:
		return option_manager_enum_to_string(v, option_manager_AUTORELOAD_DESCS[:], allocator)
	case Auto_Info:
		return option_manager_flags_to_string(v, option_manager_AUTO_INFO_DESCS[:], allocator)
	case Auto_Complete:
		return option_manager_flags_to_string(v, option_manager_AUTO_COMPLETE_DESCS[:], allocator)
	case Option_types_Debug_Flags:
		return option_manager_flags_to_string(v, option_manager_DEBUG_FLAGS_DESCS[:], allocator)
	case [dynamic]Insert_Completer_Desc:
		return option_manager_completer_descs_to_string(v[:], quoting, allocator)
	case File_Write_Method:
		return option_manager_enum_to_string(v, file_write_method_descs[:], allocator)
	}
	unreachable()
}

// option_manager_value_to_strings formats a value as strings.
option_manager_value_to_strings :: proc(val: Option_Value, allocator := context.allocator) -> []string {
	switch v in val {
	case int:
		return option_types_int_to_strings(v, allocator)
	case bool:
		res := make([]string, 1, allocator)
		res[0] = strings.clone(option_types_bool_to_string(v), allocator)
		return res
	case string:
		return option_types_string_to_strings(v, allocator)
	case [dynamic]string:
		return option_types_string_list_to_strings(v[:], allocator)
	case [dynamic]int:
		return option_types_int_list_to_strings(v[:], allocator)
	case [dynamic]rune:
		return option_manager_rune_list_to_strings(v[:], allocator)
	case Regex:
		rc := v
		res := make([]string, 1, allocator)
		res[0] = strings.clone(regex_str(&rc), allocator)
		return res
	case Coord_Display:
		res := make([]string, 1, allocator)
		res[0] = option_manager_coord_to_string(v, allocator)
		return res
	case Insert_Completer_Completion_List:
		return option_manager_completion_list_to_strings(v, allocator)
	case Option_Timestamped_List(Line_And_Spec):
		return option_manager_line_specs_to_strings(v, allocator)
	case Option_Timestamped_List(Range_And_String):
		return option_manager_range_specs_to_strings(v, allocator)
	case map[string]string:
		return option_manager_map_to_strings(v, allocator)
	case Eol_Format:
		res := make([]string, 1, allocator)
		res[0] = option_manager_enum_to_string(v, option_manager_EOL_FORMAT_DESCS[:], allocator)
		return res
	case Final_Eol:
		res := make([]string, 1, allocator)
		res[0] = option_manager_enum_to_string(v, option_manager_FINAL_EOL_DESCS[:], allocator)
		return res
	case Byte_Order_Mark:
		res := make([]string, 1, allocator)
		res[0] = option_manager_enum_to_string(v, option_manager_BYTE_ORDER_MARK_DESCS[:], allocator)
		return res
	case Autoreload:
		res := make([]string, 1, allocator)
		res[0] = option_manager_enum_to_string(v, option_manager_AUTORELOAD_DESCS[:], allocator)
		return res
	case Auto_Info:
		res := make([]string, 1, allocator)
		res[0] = option_manager_flags_to_string(v, option_manager_AUTO_INFO_DESCS[:], allocator)
		return res
	case Auto_Complete:
		res := make([]string, 1, allocator)
		res[0] = option_manager_flags_to_string(v, option_manager_AUTO_COMPLETE_DESCS[:], allocator)
		return res
	case Option_types_Debug_Flags:
		res := make([]string, 1, allocator)
		res[0] = option_manager_flags_to_string(v, option_manager_DEBUG_FLAGS_DESCS[:], allocator)
		return res
	case [dynamic]Insert_Completer_Desc:
		return option_manager_completer_descs_to_strings(v[:], allocator)
	case File_Write_Method:
		res := make([]string, 1, allocator)
		res[0] = option_manager_enum_to_string(v, file_write_method_descs[:], allocator)
		return res
	}
	unreachable()
}

// option_manager_value_from_strings parses strs into the variant held by
// current (the current contents are ignored, only the type matters). The
// message is static detail for Convert failures.
option_manager_value_from_strings :: proc(
	current: Option_Value,
	strs: []string,
	allocator := context.allocator,
) -> (Option_Value, Option_Manager_Error, string) {
	single := len(strs) == 1
	switch _ in current {
	case int:
		v, err := option_types_int_from_strings(strs)
		if err != .None {
			return 0, .Convert, option_types_error_message(err)
		}
		return v, .None, ""
	case bool:
		v, err := option_types_bool_from_strings(strs)
		if err != .None {
			return false, .Convert, option_types_error_message(err)
		}
		return v, .None, ""
	case string:
		v, err := option_types_string_from_strings(strs, allocator)
		if err != .None {
			return "", .Convert, option_types_error_message(err)
		}
		return v, .None, ""
	case [dynamic]string:
		parsed := option_types_string_list_from_strings(strs, allocator)
		res := make([dynamic]string, len(parsed), allocator)
		copy(res[:], parsed)
		delete(parsed, allocator)
		return res, .None, ""
	case [dynamic]int:
		parsed, err := option_types_int_list_from_strings(strs, allocator)
		if err != .None {
			return nil, .Convert, option_types_error_message(err)
		}
		res := make([dynamic]int, len(parsed), allocator)
		copy(res[:], parsed)
		delete(parsed, allocator)
		return res, .None, ""
	case [dynamic]rune:
		v, err := option_manager_rune_list_from_strings(strs, allocator)
		if err != .None {
			return nil, .Convert, option_types_error_message(err)
		}
		return v, .None, ""
	case Regex:
		if !single {
			return Regex{}, .Convert, option_types_error_message(.ExpectedSingleValue)
		}
		re, msg, err := regex_make(strs[0], {}, allocator)
		if err != .None {
			delete(msg, allocator)
			return Regex{}, .Regex, option_manager_error_message(.Regex)
		}
		return re, .None, ""
	case Coord_Display:
		if !single {
			return Coord_Display{}, .Convert, option_types_error_message(.ExpectedSingleValue)
		}
		v, err := option_manager_coord_from_string(strs[0])
		if err != .None {
			return Coord_Display{}, .Convert, option_types_error_message(err)
		}
		return v, .None, ""
	case Insert_Completer_Completion_List:
		v, err := option_manager_completion_list_from_strings(strs, allocator)
		if err != .None {
			return v, .Convert, option_types_error_message(err)
		}
		return v, .None, ""
	case Option_Timestamped_List(Line_And_Spec):
		v, err := option_manager_line_specs_from_strings(strs, allocator)
		if err != .None {
			return v, .Convert, option_types_error_message(err)
		}
		return v, .None, ""
	case Option_Timestamped_List(Range_And_String):
		v, err := option_manager_range_specs_from_strings(strs, allocator)
		if err != .None {
			return v, .Convert, option_types_error_message(err)
		}
		return v, .None, ""
	case map[string]string:
		res := make(map[string]string, allocator)
		_, err := option_manager_map_add(&res, strs, allocator)
		if err != .None {
			for k, e in res {
				delete(k, allocator)
				delete(e, allocator)
			}
			delete(res)
			return nil, .Convert, option_types_error_message(err)
		}
		return res, .None, ""
	case Eol_Format:
		if !single {
			return Eol_Format.Lf, .Convert, option_types_error_message(.ExpectedSingleValue)
		}
		v, ok := option_manager_enum_from_string(Eol_Format, strs[0], option_manager_EOL_FORMAT_DESCS[:])
		if !ok {
			return Eol_Format.Lf, .Convert, option_types_error_message(.InvalidEnumValue)
		}
		return v, .None, ""
	case Final_Eol:
		if !single {
			return Final_Eol.Present, .Convert, option_types_error_message(.ExpectedSingleValue)
		}
		v, ok := option_manager_enum_from_string(Final_Eol, strs[0], option_manager_FINAL_EOL_DESCS[:])
		if !ok {
			return Final_Eol.Present, .Convert, option_types_error_message(.InvalidEnumValue)
		}
		return v, .None, ""
	case Byte_Order_Mark:
		if !single {
			return Byte_Order_Mark.None, .Convert, option_types_error_message(.ExpectedSingleValue)
		}
		v, ok := option_manager_enum_from_string(Byte_Order_Mark, strs[0], option_manager_BYTE_ORDER_MARK_DESCS[:])
		if !ok {
			return Byte_Order_Mark.None, .Convert, option_types_error_message(.InvalidEnumValue)
		}
		return v, .None, ""
	case Autoreload:
		if !single {
			return Autoreload.Yes, .Convert, option_types_error_message(.ExpectedSingleValue)
		}
		v, ok := option_manager_enum_from_string(Autoreload, strs[0], option_manager_AUTORELOAD_DESCS[:])
		if !ok {
			return Autoreload.Yes, .Convert, option_types_error_message(.InvalidEnumValue)
		}
		return v, .None, ""
	case Auto_Info:
		if !single {
			return Auto_Info{}, .Convert, option_types_error_message(.ExpectedSingleValue)
		}
		v, ok := option_manager_flags_from_string(Auto_Info, Auto_Info_Flag, strs[0], option_manager_AUTO_INFO_DESCS[:])
		if !ok {
			return Auto_Info{}, .Convert, option_types_error_message(.InvalidFlagValue)
		}
		return v, .None, ""
	case Auto_Complete:
		if !single {
			return Auto_Complete{}, .Convert, option_types_error_message(.ExpectedSingleValue)
		}
		v, ok := option_manager_flags_from_string(Auto_Complete, Auto_Complete_Flag, strs[0], option_manager_AUTO_COMPLETE_DESCS[:])
		if !ok {
			return Auto_Complete{}, .Convert, option_types_error_message(.InvalidFlagValue)
		}
		return v, .None, ""
	case Option_types_Debug_Flags:
		if !single {
			return Option_types_Debug_Flags{}, .Convert, option_types_error_message(.InvalidFlagValue)
		}
		v, ok := option_manager_flags_from_string(Option_types_Debug_Flags, Option_types_Debug_Flag, strs[0], option_manager_DEBUG_FLAGS_DESCS[:])
		if !ok {
			return Option_types_Debug_Flags{}, .Convert, option_types_error_message(.InvalidFlagValue)
		}
		return v, .None, ""
	case [dynamic]Insert_Completer_Desc:
		res := make([dynamic]Insert_Completer_Desc, 0, len(strs), allocator)
		for s in strs {
			d, ok := option_manager_completer_desc_from_string(s, allocator)
			if !ok {
				for e in res {
					option_manager_completer_desc_free(e, allocator)
				}
				delete(res)
				return nil, .Convert, "invalid completer description"
			}
			append(&res, d)
		}
		return res, .None, ""
	case File_Write_Method:
		if !single {
			return File_Write_Method.Overwrite, .Convert, option_types_error_message(.ExpectedSingleValue)
		}
		v, ok := option_manager_enum_from_string(File_Write_Method, strs[0], file_write_method_descs[:])
		if !ok {
			return File_Write_Method.Overwrite, .Convert, option_types_error_message(.InvalidEnumValue)
		}
		return v, .None, ""
	}
	unreachable()
}

// option_manager_value_add adds strs to a value in place, reporting
// whether it changed. On error the caller must not notify (the C++
// throws before on_option_changed).
option_manager_value_add :: proc(
	val: ^Option_Value,
	strs: []string,
	allocator := context.allocator,
) -> (bool, Option_Manager_Error, string) {
	switch _ in val^ {
	case int:
		if len(strs) != 1 {
			return false, .Convert, option_types_error_message(.ExpectedSingleValue)
		}
		changed, err := option_types_int_add(&val.(int), strs[0])
		if err != .None {
			return false, .Convert, option_types_error_message(err)
		}
		return changed, .None, ""
	case bool:
		return false, .No_Add, ""
	case string:
		if len(strs) != 1 {
			return false, .Convert, option_types_error_message(.ExpectedSingleValue)
		}
		old := val.(string)
		changed := option_types_string_add(&val.(string), strs[0], allocator)
		delete(old, allocator)
		return changed, .None, ""
	case [dynamic]string:
		return option_types_string_list_add(&val.([dynamic]string), strs, allocator), .None, ""
	case [dynamic]int:
		changed, err := option_types_int_list_add(&val.([dynamic]int), strs, allocator)
		if err != .None {
			return false, .Convert, option_types_error_message(err)
		}
		return changed, .None, ""
	case [dynamic]rune:
		parsed, err := option_manager_rune_list_from_strings(strs, allocator)
		if err != .None {
			return false, .Convert, option_types_error_message(err)
		}
		append(&val.([dynamic]rune), ..parsed[:])
		n := len(parsed)
		delete(parsed)
		return n != 0, .None, ""
	case Regex:
		return false, .No_Add, ""
	case Coord_Display:
		return false, .No_Add, ""
	case Insert_Completer_Completion_List:
		parsed := make([dynamic]Completion_Candidate, 0, len(strs), allocator)
		for s in strs {
			elem, err := option_manager_candidate_from_string(s, allocator)
			if err != .None {
				for c in parsed {
					option_manager_candidate_free(c, allocator)
				}
				delete(parsed)
				return false, .Convert, option_types_error_message(err)
			}
			append(&parsed, elem)
		}
		tp := &val.(Insert_Completer_Completion_List)
		append(&tp.list, ..parsed[:])
		n := len(parsed)
		delete(parsed)
		return n != 0, .None, ""
	case Option_Timestamped_List(Line_And_Spec):
		parsed := make([dynamic]Line_And_Spec, 0, len(strs), allocator)
		for s in strs {
			elem, err := option_manager_line_spec_from_string(s, allocator)
			if err != .None {
				for e in parsed {
					option_manager_line_spec_free(e, allocator)
				}
				delete(parsed)
				return false, .Convert, option_types_error_message(err)
			}
			append(&parsed, elem)
		}
		tp := &val.(Option_Timestamped_List(Line_And_Spec))
		lp := &tp.list
		append(lp, ..parsed[:])
		n := len(parsed)
		delete(parsed)
		option_manager_line_specs_sort(lp)
		return n != 0, .None, ""
	case Option_Timestamped_List(Range_And_String):
		parsed := make([dynamic]Range_And_String, 0, len(strs), allocator)
		for s in strs {
			elem, err := option_manager_range_spec_from_string(s, allocator)
			if err != .None {
				for e in parsed {
					option_manager_range_spec_free(e, allocator)
				}
				delete(parsed)
				return false, .Convert, option_types_error_message(err)
			}
			append(&parsed, elem)
		}
		tp := &val.(Option_Timestamped_List(Range_And_String))
		lp := &tp.list
		append(lp, ..parsed[:])
		n := len(parsed)
		delete(parsed)
		option_manager_range_specs_sort(lp)
		return n != 0, .None, ""
	case map[string]string:
		changed, err := option_manager_map_add(&val.(map[string]string), strs, allocator)
		if err != .None {
			return false, .Convert, option_types_error_message(err)
		}
		return changed, .None, ""
	case Eol_Format, Final_Eol, Byte_Order_Mark, Autoreload, File_Write_Method:
		return false, .No_Add, ""
	case Auto_Info:
		if len(strs) != 1 {
			return false, .Convert, option_types_error_message(.ExpectedSingleValue)
		}
		parsed, ok := option_manager_flags_from_string(Auto_Info, Auto_Info_Flag, strs[0], option_manager_AUTO_INFO_DESCS[:])
		if !ok {
			return false, .Convert, option_types_error_message(.InvalidFlagValue)
		}
		fp := &val.(Auto_Info)
		old := fp^
		fp^ |= parsed
		return fp^ != old, .None, ""
	case Auto_Complete:
		if len(strs) != 1 {
			return false, .Convert, option_types_error_message(.ExpectedSingleValue)
		}
		parsed, ok := option_manager_flags_from_string(Auto_Complete, Auto_Complete_Flag, strs[0], option_manager_AUTO_COMPLETE_DESCS[:])
		if !ok {
			return false, .Convert, option_types_error_message(.InvalidFlagValue)
		}
		fp := &val.(Auto_Complete)
		old := fp^
		fp^ |= parsed
		return fp^ != old, .None, ""
	case Option_types_Debug_Flags:
		if len(strs) != 1 {
			return false, .Convert, option_types_error_message(.ExpectedSingleValue)
		}
		parsed, ok := option_manager_flags_from_string(Option_types_Debug_Flags, Option_types_Debug_Flag, strs[0], option_manager_DEBUG_FLAGS_DESCS[:])
		if !ok {
			return false, .Convert, option_types_error_message(.InvalidFlagValue)
		}
		fp := &val.(Option_types_Debug_Flags)
		old := fp^
		fp^ |= parsed
		return fp^ != old, .None, ""
	case [dynamic]Insert_Completer_Desc:
		parsed := make([dynamic]Insert_Completer_Desc, 0, len(strs), allocator)
		for s in strs {
			elem, ok := option_manager_completer_desc_from_string(s, allocator)
			if !ok {
				for e in parsed {
					option_manager_completer_desc_free(e, allocator)
				}
				delete(parsed)
				return false, .Convert, "invalid completer description"
			}
			append(&parsed, elem)
		}
		lp := &val.([dynamic]Insert_Completer_Desc)
		append(lp, ..parsed[:])
		n := len(parsed)
		delete(parsed)
		return n != 0, .None, ""
	}
	unreachable()
}

// option_manager_value_remove removes strs from a value in place,
// reporting whether it changed. On error the caller must not notify.
option_manager_value_remove :: proc(
	val: ^Option_Value,
	strs: []string,
	allocator := context.allocator,
) -> (bool, Option_Manager_Error, string) {
	switch _ in val^ {
	case int:
		if len(strs) != 1 {
			return false, .Convert, option_types_error_message(.ExpectedSingleValue)
		}
		changed, err := option_types_int_remove(&val.(int), strs[0])
		if err != .None {
			return false, .Convert, option_types_error_message(err)
		}
		return changed, .None, ""
	case bool, string, Regex, Coord_Display:
		return false, .No_Remove, ""
	case [dynamic]string:
		changed := false
		for s in strs {
			lp := &val.([dynamic]string)
			for j := 0; j < len(lp); j += 1 {
				if lp[j] == s {
					delete(lp[j], allocator)
					ordered_remove(lp, j)
					changed = true
					break
				}
			}
		}
		return changed, .None, ""
	case [dynamic]int:
		changed, err := option_types_int_list_remove(&val.([dynamic]int), strs)
		if err != .None {
			return changed, .Convert, option_types_error_message(err)
		}
		return changed, .None, ""
	case [dynamic]rune:
		changed := false
		for s in strs {
			c, err := option_types_codepoint_from_string(s)
			if err != .None {
				return changed, .Convert, option_types_error_message(err)
			}
			lp := &val.([dynamic]rune)
			for j := 0; j < len(lp); j += 1 {
				if lp[j] == c {
					ordered_remove(lp, j)
					changed = true
					break
				}
			}
		}
		return changed, .None, ""
	case Insert_Completer_Completion_List:
		changed := false
		for s in strs {
			probe, err := option_manager_candidate_from_string(s, allocator)
			if err != .None {
				return changed, .Convert, option_types_error_message(err)
			}
			tp := &val.(Insert_Completer_Completion_List)
			lp := &tp.list
			for j := 0; j < len(lp); j += 1 {
				if lp[j] == probe {
					option_manager_candidate_free(lp[j], allocator)
					ordered_remove(lp, j)
					changed = true
					break
				}
			}
			option_manager_candidate_free(probe, allocator)
		}
		return changed, .None, ""
	case Option_Timestamped_List(Line_And_Spec):
		changed := false
		for s in strs {
			probe, err := option_manager_line_spec_from_string(s, allocator)
			if err != .None {
				return changed, .Convert, option_types_error_message(err)
			}
			tp := &val.(Option_Timestamped_List(Line_And_Spec))
			lp := &tp.list
			for j := 0; j < len(lp); j += 1 {
				if lp[j] == probe {
					option_manager_line_spec_free(lp[j], allocator)
					ordered_remove(lp, j)
					changed = true
					break
				}
			}
			option_manager_line_spec_free(probe, allocator)
		}
		return changed, .None, ""
	case Option_Timestamped_List(Range_And_String):
		changed := false
		for s in strs {
			probe, err := option_manager_range_spec_from_string(s, allocator)
			if err != .None {
				return changed, .Convert, option_types_error_message(err)
			}
			tp := &val.(Option_Timestamped_List(Range_And_String))
			lp := &tp.list
			for j := 0; j < len(lp); j += 1 {
				if lp[j] == probe {
					option_manager_range_spec_free(lp[j], allocator)
					ordered_remove(lp, j)
					changed = true
					break
				}
			}
			option_manager_range_spec_free(probe, allocator)
		}
		return changed, .None, ""
	case map[string]string:
		changed, err := option_manager_map_remove(&val.(map[string]string), strs, allocator)
		if err != .None {
			return changed, .Convert, option_types_error_message(err)
		}
		return changed, .None, ""
	case Eol_Format, Final_Eol, Byte_Order_Mark, Autoreload, File_Write_Method:
		return false, .No_Remove, ""
	case Auto_Info:
		if len(strs) != 1 {
			return false, .Convert, option_types_error_message(.ExpectedSingleValue)
		}
		parsed, ok := option_manager_flags_from_string(Auto_Info, Auto_Info_Flag, strs[0], option_manager_AUTO_INFO_DESCS[:])
		if !ok {
			return false, .Convert, option_types_error_message(.InvalidFlagValue)
		}
		fp := &val.(Auto_Info)
		old := fp^
		fp^ &= ~parsed
		return fp^ != old, .None, ""
	case Auto_Complete:
		if len(strs) != 1 {
			return false, .Convert, option_types_error_message(.ExpectedSingleValue)
		}
		parsed, ok := option_manager_flags_from_string(Auto_Complete, Auto_Complete_Flag, strs[0], option_manager_AUTO_COMPLETE_DESCS[:])
		if !ok {
			return false, .Convert, option_types_error_message(.InvalidFlagValue)
		}
		fp := &val.(Auto_Complete)
		old := fp^
		fp^ &= ~parsed
		return fp^ != old, .None, ""
	case Option_types_Debug_Flags:
		if len(strs) != 1 {
			return false, .Convert, option_types_error_message(.ExpectedSingleValue)
		}
		parsed, ok := option_manager_flags_from_string(Option_types_Debug_Flags, Option_types_Debug_Flag, strs[0], option_manager_DEBUG_FLAGS_DESCS[:])
		if !ok {
			return false, .Convert, option_types_error_message(.InvalidFlagValue)
		}
		fp := &val.(Option_types_Debug_Flags)
		old := fp^
		fp^ &= ~parsed
		return fp^ != old, .None, ""
	case [dynamic]Insert_Completer_Desc:
		changed := false
		for s in strs {
			probe, ok := option_manager_completer_desc_from_string(s, allocator)
			if !ok {
				return changed, .Convert, "invalid completer description"
			}
			lp := &val.([dynamic]Insert_Completer_Desc)
			for j := 0; j < len(lp); j += 1 {
				if lp[j] == probe {
					option_manager_completer_desc_free(lp[j], allocator)
					ordered_remove(lp, j)
					changed = true
					break
				}
			}
			option_manager_completer_desc_free(probe, allocator)
		}
		return changed, .None, ""
	}
	unreachable()
}

// option_manager_option_make creates a heap option cloning value. The
// desc is borrowed from the registry; the manager is observed.
option_manager_option_make :: proc(
	desc: ^Option_Desc,
	manager: ^Option_Manager,
	value: Option_Value,
	validator: Option_Validator = nil,
	allocator := context.allocator,
) -> ^Option {
	opt := new(Option, allocator)
	opt^ = Option {
		desc      = desc,
		manager   = manager,
		value     = option_manager_value_clone(value, allocator),
		validator = validator,
		allocator = allocator,
	}
	return opt
}

// option_manager_option_destroy frees an option and its value. It does
// not touch the desc (registry-owned) or unregister anything.
option_manager_option_destroy :: proc(opt: ^Option) {
	option_manager_value_destroy(&opt.value, opt.allocator)
	free(opt, opt.allocator)
}

// option_manager_option_name returns the option name (C++ Option::name).
option_manager_option_name :: proc(opt: ^Option) -> string {
	return opt.desc.name
}

// option_manager_option_docstring returns the docstring.
option_manager_option_docstring :: proc(opt: ^Option) -> string {
	return opt.desc.docstring
}

// option_manager_option_flags returns the desc flags.
option_manager_option_flags :: proc(opt: ^Option) -> Option_Flags {
	return opt.desc.flags
}

// option_manager_option_type_name returns the value type name.
option_manager_option_type_name :: proc(opt: ^Option) -> string {
	return option_manager_value_type_name(opt.value)
}

// option_desc_string ports Option::get_desc_string; it shares the
// option_manager implementation (int/bool/String render Raw, every
// other type renders "...").
option_desc_string :: proc(o: ^Option, allocator := context.allocator) -> string {
	return option_manager_option_get_desc_string(o, allocator)
}

// option_manager_option_get returns the current value (borrowed view;
// clone it for ownership).
option_manager_option_get :: proc(opt: ^Option) -> Option_Value {
	return opt.value
}

// option_manager_option_store validates and stores new_val, taking
// ownership of it on every path (it is freed when rejected or equal).
option_manager_option_store :: proc(
	opt: ^Option,
	new_val: Option_Value,
	notify := true,
) -> (Option_Manager_Error, string) {
	nv := new_val
	if opt.validator != nil {
		if msg := opt.validator(nv); msg != "" {
			option_manager_value_destroy(&nv, opt.allocator)
			return .Validation, msg
		}
	}
	if option_manager_value_equal(opt.value, nv) {
		option_manager_value_destroy(&nv, opt.allocator)
		return .None, ""
	}
	option_manager_value_destroy(&opt.value, opt.allocator)
	opt.value = nv
	if notify {
		option_manager_on_option_changed(opt.manager, opt)
	}
	return .None, ""
}

// option_manager_option_set assigns value after a variant check and
// validation (C++ TypedOption::set). The passed value is cloned; the
// caller keeps ownership.
option_manager_option_set :: proc(
	opt: ^Option,
	value: Option_Value,
	notify := true,
) -> (Option_Manager_Error, string) {
	if option_manager_value_tag(opt.value) != option_manager_value_tag(value) {
		return .Type_Mismatch, ""
	}
	return option_manager_option_store(opt, option_manager_value_clone(value, opt.allocator), notify)
}

// option_manager_option_get_as_string formats the value (C++
// get_as_string). The caller frees the result.
option_manager_option_get_as_string :: proc(
	opt: ^Option,
	quoting: Option_types_Quoting,
	allocator := context.allocator,
) -> string {
	return option_manager_value_to_string(opt.value, quoting, allocator)
}

// option_manager_option_get_as_strings formats the value as strings. The
// caller frees the slice and its elements.
option_manager_option_get_as_strings :: proc(opt: ^Option, allocator := context.allocator) -> []string {
	return option_manager_value_to_strings(opt.value, allocator)
}

// option_manager_option_get_desc_string returns the hook short form: the
// raw value for int/bool/str, "..." otherwise. The caller frees it.
option_manager_option_get_desc_string :: proc(opt: ^Option, allocator := context.allocator) -> string {
	switch _ in opt.value {
	case int, bool, string:
		return option_manager_value_to_string(opt.value, .Raw, allocator)
	case [dynamic]string, [dynamic]int, [dynamic]rune:
		return strings.clone("...", allocator)
	case Regex, Coord_Display:
		return strings.clone("...", allocator)
	case Insert_Completer_Completion_List:
		return strings.clone("...", allocator)
	case Option_Timestamped_List(Line_And_Spec), Option_Timestamped_List(Range_And_String):
		return strings.clone("...", allocator)
	case map[string]string:
		return strings.clone("...", allocator)
	case Eol_Format, Final_Eol, Byte_Order_Mark, Autoreload, File_Write_Method:
		return strings.clone("...", allocator)
	case Auto_Info, Auto_Complete, Option_types_Debug_Flags:
		return strings.clone("...", allocator)
	case [dynamic]Insert_Completer_Desc:
		return strings.clone("...", allocator)
	}
	unreachable()
}

// option_manager_option_set_from_strings parses and stores strs (C++
// set_from_strings). On error the value is untouched.
option_manager_option_set_from_strings :: proc(
	opt: ^Option,
	strs: []string,
) -> (Option_Manager_Error, string) {
	parsed, err, msg := option_manager_value_from_strings(opt.value, strs, opt.allocator)
	if err != .None {
		return err, msg
	}
	return option_manager_option_store(opt, parsed)
}

// option_manager_option_add_from_strings adds strs (C++ add_from_strings).
option_manager_option_add_from_strings :: proc(
	opt: ^Option,
	strs: []string,
) -> (Option_Manager_Error, string) {
	changed, err, msg := option_manager_value_add(&opt.value, strs, opt.allocator)
	if err != .None {
		return err, msg
	}
	if changed {
		option_manager_on_option_changed(opt.manager, opt)
	}
	return .None, ""
}

// option_manager_option_remove_from_strings removes strs (C++
// remove_from_strings).
option_manager_option_remove_from_strings :: proc(
	opt: ^Option,
	strs: []string,
) -> (Option_Manager_Error, string) {
	changed, err, msg := option_manager_value_remove(&opt.value, strs, opt.allocator)
	if err != .None {
		return err, msg
	}
	if changed {
		option_manager_on_option_changed(opt.manager, opt)
	}
	return .None, ""
}

// option_manager_option_update refreshes timestamped spec lists (C++
// update); other types report No_Update. The spec cases call into the
// unmerged highlighter module (STUBBED below).
option_manager_option_update :: proc(opt: ^Option, ctx: ^Context) -> Option_Manager_Error {
	switch _ in opt.value {
	case Option_Timestamped_List(Line_And_Spec):
		highlighters_line_specs_update(&opt.value.(Option_Timestamped_List(Line_And_Spec)), ctx)
		return .None
	case Option_Timestamped_List(Range_And_String):
		highlighters_range_specs_update(&opt.value.(Option_Timestamped_List(Range_And_String)), ctx)
		return .None
	case int, bool, string:
		return .No_Update
	case [dynamic]string, [dynamic]int, [dynamic]rune:
		return .No_Update
	case Regex, Coord_Display:
		return .No_Update
	case Insert_Completer_Completion_List:
		return .No_Update
	case map[string]string:
		return .No_Update
	case Eol_Format, Final_Eol, Byte_Order_Mark, Autoreload, File_Write_Method:
		return .No_Update
	case Auto_Info, Auto_Complete, Option_types_Debug_Flags:
		return .No_Update
	case [dynamic]Insert_Completer_Desc:
		return .No_Update
	}
	unreachable()
}

// option_manager_option_has_same_value reports value equality (C++
// has_same_value).
option_manager_option_has_same_value :: proc(a, b: ^Option) -> bool {
	return option_manager_value_equal(a.value, b.value)
}

// option_manager_option_clone deep-copies an option under manager (C++
// clone). The desc stays borrowed from the registry.
option_manager_option_clone :: proc(
	opt: ^Option,
	manager: ^Option_Manager,
	allocator := context.allocator,
) -> ^Option {
	return option_manager_option_make(opt.desc, manager, opt.value, opt.validator, allocator)
}

// option_manager_init_root initializes a root manager with no parent
// (C++ private OptionManager(), friend of Scope/OptionsRegistry).
option_manager_init_root :: proc(m: ^Option_Manager, allocator := context.allocator) {
	m^ = Option_Manager {
		options   = make(map[string]^Option, allocator),
		parent    = nil,
		watchers  = make([dynamic]Option_Watcher, allocator),
		allocator = allocator,
	}
}

// option_manager_init_child initializes m with parent, registering m as
// a watcher of parent (C++ OptionManager(parent)). m must live at its
// final address: children are usually embedded in heap scope data.
option_manager_init_child :: proc(m: ^Option_Manager, parent: ^Option_Manager, allocator := context.allocator) {
	option_manager_init_root(m, allocator)
	m.parent = parent
	option_manager_register_watcher(parent, Option_Watcher{data = m, on_option_changed = option_manager_watcher_callback})
}

// option_manager_destroy frees a manager and its local options. Like the
// C++ destructor it first unregisters from its parent, then requires an
// empty watcher list: destroy child managers (and unregister plain
// watchers) first.
option_manager_destroy :: proc(m: ^Option_Manager) {
	if m.parent != nil {
		option_manager_unregister_watcher(
			m.parent,
			Option_Watcher{data = m, on_option_changed = option_manager_watcher_callback},
		)
		m.parent = nil
	}
	assert(len(m.watchers) == 0)
	for _, opt in m.options {
		option_manager_option_destroy(opt)
	}
	delete(m.options)
	delete(m.watchers)
}

// option_manager_reparent moves m under parent (C++ reparent).
option_manager_reparent :: proc(m: ^Option_Manager, parent: ^Option_Manager) {
	if m.parent != nil {
		option_manager_unregister_watcher(
			m.parent,
			Option_Watcher{data = m, on_option_changed = option_manager_watcher_callback},
		)
	}
	m.parent = parent
	option_manager_register_watcher(
		parent,
		Option_Watcher{data = m, on_option_changed = option_manager_watcher_callback},
	)
}

// option_manager_register_watcher subscribes watcher (C++
// register_watcher).
option_manager_register_watcher :: proc(m: ^Option_Manager, watcher: Option_Watcher) {
	assert(!slice.contains(m.watchers[:], watcher))
	append(&m.watchers, watcher)
}

// option_manager_unregister_watcher unsubscribes watcher (C++
// unregister_watcher).
option_manager_unregister_watcher :: proc(m: ^Option_Manager, watcher: Option_Watcher) {
	for w, i in m.watchers {
		if w == watcher {
			ordered_remove(&m.watchers, i)
			return
		}
	}
	assert(false)
}

// option_manager_watcher_callback forwards a parent change into the
// child manager (the C++ OptionManager::on_option_changed override,
// registered as an Option_Watcher on the parent).
option_manager_watcher_callback :: proc(data: rawptr, option: rawptr) {
	m := (^Option_Manager)(data)
	opt := (^Option)(option)
	option_manager_on_option_changed(m, opt)
}

// option_manager_on_option_changed notifies watchers of a change (C++
// on_option_changed). A parent change shadowed by a local override is
// swallowed; watchers removed mid-flight are skipped.
option_manager_on_option_changed :: proc(m: ^Option_Manager, opt: ^Option) {
	if opt.manager != m {
		if opt.desc.name in m.options {
			return
		}
	}
	watchers := slice.clone(m.watchers[:], context.temp_allocator)
	for w in watchers {
		if slice.contains(m.watchers[:], w) {
			option_watcher_notify(w, opt)
		}
	}
}

// option_manager_get_option looks up name along the parent chain (C++
// operator[]). The result is borrowed from its manager.
// option_manager_get_checked returns a startup-declared builtin option,
// asserting it exists (C++ operator[] throws option_not_found; all call
// sites reference main.cc builtins, so a miss is a programming error).
option_manager_get_checked :: proc(m: ^Option_Manager, name: string) -> ^Option {
	opt, err := option_manager_get_option(m, name)
	assert(err == .None)
	return opt
}

option_manager_get_option :: proc(m: ^Option_Manager, name: string) -> (^Option, Option_Manager_Error) {
	cur := m
	for cur != nil {
		if opt, ok := cur.options[name]; ok {
			return opt, .None
		}
		cur = cur.parent
	}
	return nil, .Not_Found
}

// option_manager_get_local_option returns the local option, cloning the
// inherited one on first use (C++ get_local_option).
option_manager_get_local_option :: proc(
	m: ^Option_Manager,
	name: string,
	allocator := context.allocator,
) -> (^Option, Option_Manager_Error) {
	if opt, ok := m.options[name]; ok {
		return opt, .None
	}
	if m.parent == nil {
		return nil, .Not_Found
	}
	parent_opt, err := option_manager_get_option(m.parent, name)
	if err != .None {
		return nil, err
	}
	clone := option_manager_option_clone(parent_opt, m, allocator)
	m.options[clone.desc.name] = clone
	return clone, .None
}

// option_manager_unset_option drops the local override, revealing the
// parent value again (C++ unset_option). The old local option moves to
// the global registry trash when a global scope exists, and is freed
// directly otherwise.
option_manager_unset_option :: proc(m: ^Option_Manager, name: string) -> Option_Manager_Error {
	assert(m.parent != nil)
	local, ok := m.options[name]
	if !ok {
		return .None
	}
	parent_opt, err := option_manager_get_option(m.parent, name)
	if err != .None {
		return err
	}
	changed := !option_manager_option_has_same_value(parent_opt, local)
	delete_key(&m.options, name)
	if g := scope_global_instance(); g != nil {
		option_manager_registry_move_to_trash(&g.global_data.option_registry, local)
	} else {
		option_manager_option_destroy(local)
	}
	if changed {
		option_manager_on_option_changed(m, parent_opt)
	}
	return .None
}

// option_manager_flatten_options merges visible options with shadowing:
// grandparent entries not overridden, then parent entries not
// overridden, then local entries (C++ flatten_options). The caller
// deletes the returned array; the options stay borrowed.
option_manager_flatten_options :: proc(m: ^Option_Manager, allocator := context.allocator) -> [dynamic]^Option {
	res := make([dynamic]^Option, allocator)
	p := m.parent
	gp := p != nil ? p.parent : nil
	if gp != nil {
		for k, v in gp.options {
			if k in p.options {
				continue
			}
			if k in m.options {
				continue
			}
			append(&res, v)
		}
	}
	if p != nil {
		for k, v in p.options {
			if k in m.options {
				continue
			}
			append(&res, v)
		}
	}
	for _, v in m.options {
		append(&res, v)
	}
	return res
}

// option_manager_registry_init initializes a registry over the global
// manager (C++ OptionsRegistry ctor).
option_manager_registry_init :: proc(
	reg: ^Options_Registry,
	global_manager: ^Option_Manager,
	allocator := context.allocator,
) {
	reg^ = Options_Registry {
		global_manager = global_manager,
		descs          = make([dynamic]^Option_Desc, allocator),
		trash          = make([dynamic]^Option, allocator),
		allocator      = allocator,
	}
}

// option_manager_registry_destroy frees descs and trash. Destroy the
// global manager (whose options borrow the descs) first.
option_manager_registry_destroy :: proc(reg: ^Options_Registry) {
	option_manager_registry_clear_trash(reg)
	for d in reg.descs {
		delete(d.name, reg.allocator)
		delete(d.docstring, reg.allocator)
		free(d, reg.allocator)
	}
	delete(reg.descs)
	delete(reg.trash)
}

// option_manager_option_name_valid reports whether name only holds
// [a-zA-Z0-9_] (like the C++ declare_option check; empty passes).
option_manager_option_name_valid :: proc(name: string) -> bool {
	for i := 0; i < len(name); i += 1 {
		c := name[i]
		ok := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'
		if !ok {
			return false
		}
	}
	return true
}

// option_manager_registry_declare declares a global option (C++
// OptionsRegistry::declare_option). The value variant selects the type.
// Redeclaring with the same type and flags returns the existing option;
// a different type or flags reports Type_Mismatch.
option_manager_registry_declare :: proc(
	reg: ^Options_Registry,
	name, docstring: string,
	value: Option_Value,
	flags: Option_Flags = {},
	validator: Option_Validator = nil,
	allocator := context.allocator,
) -> (^Option, Option_Manager_Error) {
	if !option_manager_option_name_valid(name) {
		return nil, .Invalid_Name
	}
	if existing, ok := reg.global_manager.options[name]; ok {
		if option_manager_value_tag(existing.value) == option_manager_value_tag(value) &&
		   existing.desc.flags == flags {
			return existing, .None
		}
		return nil, .Type_Mismatch
	}
	type_name := option_manager_value_type_name(value)
	doc := len(docstring) == 0 ? fmt.aprintf("[{}]", type_name, allocator = allocator) : fmt.aprintf("[{}] - {}", type_name, docstring, allocator = allocator)
	desc := new(Option_Desc, allocator)
	desc^ = Option_Desc{name = strings.clone(name, allocator), docstring = doc, flags = flags}
	append(&reg.descs, desc)
	opt := option_manager_option_make(desc, reg.global_manager, value, validator, allocator)
	reg.global_manager.options[desc.name] = opt
	return opt, .None
}

// option_manager_registry_desc returns the desc for name, or nil (C++
// option_desc).
option_manager_registry_desc :: proc(reg: ^Options_Registry, name: string) -> ^Option_Desc {
	for d in reg.descs {
		if d.name == name {
			return d
		}
	}
	return nil
}

// option_manager_registry_exists reports whether name is declared (C++
// option_exists).
option_manager_registry_exists :: proc(reg: ^Options_Registry, name: string) -> bool {
	return option_manager_registry_desc(reg, name) != nil
}

// option_manager_registry_complete_name completes non-hidden option
// names with ranked matching (C++ complete_option_name). The caller
// frees the candidates (see option_manager_candidates_free).
option_manager_registry_complete_name :: proc(
	reg: ^Options_Registry,
	prefix: string,
	cursor_pos: Units_ByteCount,
	allocator := context.allocator,
) -> Candidate_List {
	end := clamp(int(cursor_pos), 0, len(prefix))
	query := prefix[:end]
	matches := make([dynamic]Ranked_Match, context.temp_allocator)
	for d in reg.descs {
		if .Hidden in d.flags {
			continue
		}
		m := ranked_match_make(d.name, query)
		if m.matches {
			append(&matches, m)
		}
	}
	slice.sort_by(matches[:], ranked_match_less)
	res := make(Candidate_List, len(matches), allocator)
	for m, i in matches {
		res[i] = strings.clone(m.candidate, allocator)
	}
	return res
}

// options_registry_complete_option_name completes an option name against
// the registry's non-hidden descs (C++
// OptionsRegistry::complete_option_name in option_manager.cc; the name is
// kept from the STUB contract). Candidates own their strings; free with
// option_manager_candidates_free.
options_registry_complete_option_name :: proc(
	reg: ^Options_Registry,
	prefix: string,
	cursor_pos: Units_ByteCount,
	allocator := context.allocator,
) -> Candidate_List {
	return option_manager_registry_complete_name(reg, prefix, cursor_pos, allocator)
}

// option_manager_candidates_free frees a completion candidate list.
option_manager_candidates_free :: proc(list: ^Candidate_List, allocator := context.allocator) {
	for c in list^ {
		delete(c, allocator)
	}
	delete(list^)
}

// option_manager_registry_move_to_trash takes ownership of an unset
// option until the trash is cleared (C++ move_to_trash). Locked: the
// global registry's trash is shared across threads.
option_manager_registry_move_to_trash :: proc(reg: ^Options_Registry, opt: ^Option) {
	sync.mutex_lock(&scope_global_mutex)
	defer sync.mutex_unlock(&scope_global_mutex)
	append(&reg.trash, opt)
}

// option_manager_registry_clear_trash frees trashed options (C++
// clear_option_trash). Locked like move_to_trash.
option_manager_registry_clear_trash :: proc(reg: ^Options_Registry) {
	sync.mutex_lock(&scope_global_mutex)
	defer sync.mutex_unlock(&scope_global_mutex)
	for opt in reg.trash {
		option_manager_option_destroy(opt)
	}
	clear(&reg.trash)
}

// highlighters_line_specs_update / highlighters_range_specs_update merged
// from the highlighters module; stubs deleted.
