// Tests for the option module ported from src/option.hh.
// No C++ UnitTest covers option.hh; these assert the ported behavior.
package kak

import "base:runtime"
import "core:strings"
import "core:testing"

// Test converter: parses nothing, echoes length as the value.
option_test_len_from_string :: proc(s: string) -> (int, Option_Error) {
	return len(s), .None
}

// Test converter: fails always, to check error passthrough.
option_test_fail_from_string :: proc(s: string) -> (int, Option_Error) {
	return 0, .Expected_Single_Value
}

// option_test_last_quoting records the quoting the to_string fallback used.
option_test_last_quoting: Option_types_Quoting

option_test_int_to_string :: proc(
	val: int,
	quoting: Option_types_Quoting,
	allocator: runtime.Allocator,
) -> string {
	option_test_last_quoting = quoting
	return strings.clone("v" if val != 0 else "z", allocator)
}

option_test_add :: proc(opt: ^int, s: string) -> (bool, Option_Error) {
	opt^ += len(s)
	return len(s) != 0, .None
}

option_test_remove :: proc(opt: ^int, s: string) -> (bool, Option_Error) {
	opt^ -= len(s)
	return len(s) != 0, .None
}

@(test)
option_test_error_message :: proc(t: ^testing.T) {
	testing.expect_value(t, option_error_message(.None), "")
	testing.expect_value(
		t,
		option_error_message(.Expected_Single_Value),
		"expected a single value for option",
	)
}

@(test)
option_test_from_strings :: proc(t: ^testing.T) {
	val, err := option_from_strings(int, {"hello"}, option_test_len_from_string)
	testing.expect_value(t, err, Option_Error.None)
	testing.expect_value(t, val, 5)

	// Arity other than one fails (C++ throws runtime_error).
	_, err = option_from_strings(int, {}, option_test_len_from_string)
	testing.expect_value(t, err, Option_Error.Expected_Single_Value)
	_, err = option_from_strings(int, {"a", "b"}, option_test_len_from_string)
	testing.expect_value(t, err, Option_Error.Expected_Single_Value)

	// Converter errors pass through untouched.
	_, err = option_from_strings(int, {"a"}, option_test_fail_from_string)
	testing.expect_value(t, err, Option_Error.Expected_Single_Value)
}

@(test)
option_test_to_strings :: proc(t: ^testing.T) {
	res := option_to_strings(7, option_test_int_to_string)
	defer delete(res)
	testing.expect_value(t, len(res), 1)
	testing.expect_value(t, res[0], "v")
	// C++ passes Quoting{} (Raw) to the single-value converter.
	testing.expect_value(t, option_test_last_quoting, Option_types_Quoting.Raw)
	delete(res[0])
}

@(test)
option_test_add_remove_from_strings :: proc(t: ^testing.T) {
	opt := 10
	changed, err := option_add_from_strings(&opt, {"abc"}, option_test_add)
	testing.expect_value(t, err, Option_Error.None)
	testing.expect(t, changed)
	testing.expect_value(t, opt, 13)

	changed, err = option_add_from_strings(&opt, {}, option_test_add)
	testing.expect_value(t, err, Option_Error.Expected_Single_Value)
	testing.expect(t, !changed)
	testing.expect_value(t, opt, 13)

	changed, err = option_remove_from_strings(&opt, {"ab"}, option_test_remove)
	testing.expect_value(t, err, Option_Error.None)
	testing.expect(t, changed)
	testing.expect_value(t, opt, 11)

	changed, err = option_remove_from_strings(&opt, {"a", "b"}, option_test_remove)
	testing.expect_value(t, err, Option_Error.Expected_Single_Value)
	testing.expect(t, !changed)
	testing.expect_value(t, opt, 11)
}

@(test)
option_test_prefixed_list_reuse :: proc(t: ^testing.T) {
	// C++ PrefixedList is the merged Option_types_Prefixed_List; the
	// option module reuses it rather than redefining it.
	pl := Option_types_Prefixed_List(int, string){prefix = 3}
	append(&pl.list, strings.clone("x"), strings.clone("y"))
	defer {
		for s in pl.list {
			delete(s)
		}
		delete(pl.list)
	}
	testing.expect_value(t, pl.prefix, 3)
	testing.expect_value(t, len(pl.list), 2)
	testing.expect_value(t, pl.list[1], "y")
}

@(test)
option_test_timestamped_list :: proc(t: ^testing.T) {
	ts := Option_Timestamped_List(string){}
	ts.prefix = uint(42)
	append(&ts.list, strings.clone("a"))
	defer {
		for s in ts.list {
			delete(s)
		}
		delete(ts.list)
	}
	testing.expect_value(t, ts.prefix, uint(42))
	testing.expect_value(t, len(ts.list), 1)
	testing.expect_value(t, ts.list[0], "a")
}

// option_test_watch_count counts watcher notifications.
option_test_watch_count := 0
option_test_watch_data: rawptr
option_test_watch_option: rawptr

option_test_on_changed :: proc(data: rawptr, option: rawptr) {
	option_test_watch_count += 1
	option_test_watch_data = data
	option_test_watch_option = option
}

@(test)
option_test_watcher_notify :: proc(t: ^testing.T) {
	marker := 12345
	data := 7
	option_test_watch_count = 0
	w := Option_Watcher{data = &data, on_option_changed = option_test_on_changed}
	option_watcher_notify(w, &marker)
	testing.expect_value(t, option_test_watch_count, 1)
	testing.expect(t, option_test_watch_data == rawptr(&data))
	testing.expect(t, option_test_watch_option == rawptr(&marker))

	// A nil callback is a no-op.
	option_watcher_notify(Option_Watcher{}, &marker)
	testing.expect_value(t, option_test_watch_count, 1)
}
