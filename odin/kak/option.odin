// Port of src/option.hh: the generic single-value option conversion
// fallbacks, the timestamped list shorthand, and the option watcher
// hook.
//
// The C++ file is templates plus two small declarations, so this port
// is generic procs plus reuse of the merged modules: conversions take
// Option_types_Quoting (C++ Quoting, whose default Raw is passed by
// option_to_strings), PrefixedList is the merged
// Option_types_Prefixed_List (never vendored here), and
// Option_Timestamped_List embeds it with a size_t (uint) prefix.
//
// Error handling: the single-value fallbacks throw runtime_error in C++
// when given more or fewer than one string; here they return
// Option_Error with None (= 0) as success.
//
// Ownership: option_to_strings returns an owned []string allocated with
// the given allocator; the caller frees it with delete. The element
// strings are owned by the to_string callback's contract.
package kak

import "base:runtime"

// Option_Error reports single-value option conversion failures.
Option_Error :: enum {
	None,
	Expected_Single_Value,
}

// option_error_message describes an error. Ports the C++ throw text.
option_error_message :: proc(err: Option_Error) -> string {
	switch err {
	case .None:
		return ""
	case .Expected_Single_Value:
		return "expected a single value for option"
	}
	unreachable()
}

// option_from_strings is the default option_from_string fallback: it
// requires exactly one string and delegates to from_string.
option_from_strings :: proc(
	$T: typeid,
	strs: []string,
	from_string: proc(s: string) -> (T, Option_Error),
) -> (
	T,
	Option_Error,
) {
	if len(strs) != 1 {
		res: T
		return res, .Expected_Single_Value
	}
	return from_string(strs[0])
}

// option_to_strings is the default option_to_string fallback: it wraps
// the single Raw-quoted value in an owned slice.
option_to_strings :: proc(
	opt: $T,
	to_string: proc(val: T, quoting: Option_types_Quoting, allocator: runtime.Allocator) -> string,
	allocator := context.allocator,
) -> []string {
	res := make([]string, 1, allocator)
	res[0] = to_string(opt, .Raw, allocator)
	return res
}

// option_add_from_strings is the default option_add fallback: it
// requires exactly one string and delegates to add.
option_add_from_strings :: proc(
	opt: ^$T,
	strs: []string,
	add: proc(opt: ^T, s: string) -> (bool, Option_Error),
) -> (
	bool,
	Option_Error,
) {
	if len(strs) != 1 {
		return false, .Expected_Single_Value
	}
	return add(opt, strs[0])
}

// option_remove_from_strings is the default option_remove fallback: it
// requires exactly one string and delegates to remove.
option_remove_from_strings :: proc(
	opt: ^$T,
	strs: []string,
	remove: proc(opt: ^T, s: string) -> (bool, Option_Error),
) -> (
	bool,
	Option_Error,
) {
	if len(strs) != 1 {
		return false, .Expected_Single_Value
	}
	return remove(opt, strs[0])
}

// NOTE: C++ PrefixedList itself is already ported as
// Option_types_Prefixed_List in option_types; it is reused, not repeated,
// here. Only the TimestampedList shorthand below is option.hh-specific.

// Option_Timestamped_List ports C++ TimestampedList (a PrefixedList
// keyed by size_t). It embeds the canonical prefixed list so .prefix
// and .list resolve directly.
Option_Timestamped_List :: struct($T: typeid) {
	using prefixed: Option_types_Prefixed_List(uint, T),
}

// Option_Watcher_Callback ports OptionWatcher::on_option_changed. The
// option is opaque here: option.hh only forward-declares C++ Option
// (defined in option_manager.hh), so callers pass a pointer to the
// option_manager-owned option as rawptr.
Option_Watcher_Callback :: #type proc(data: rawptr, option: rawptr)

// Option_Watcher ports the C++ OptionWatcher interface as data plus a
// callback, following the watcher pattern in event_manager.
Option_Watcher :: struct {
	data:              rawptr,
	on_option_changed: Option_Watcher_Callback,
}

// option_watcher_notify invokes the watcher's callback, if any.
option_watcher_notify :: proc(w: Option_Watcher, option: rawptr) {
	if w.on_option_changed != nil {
		w.on_option_changed(w.data, option)
	}
}
