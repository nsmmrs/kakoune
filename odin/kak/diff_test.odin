package kak

import "core:testing"

// Tests run on a thread pool, and Odin procs cannot capture locals, so
// each check stashes its sink in context.user_ptr for the callback.
@(private)
diff_test_sink_emit :: proc(op: Diff_Op, len: int) {
	sink := cast(^[dynamic]Diff_Diff)context.user_ptr
	append(sink, Diff_Diff{op, len})
}

// diff_test_collect runs the diff and returns the reported runs; the
// caller owns the result (context.allocator).
diff_test_collect :: proc(a, b: string, allocator := context.allocator) -> [dynamic]Diff_Diff {
	sink := make([dynamic]Diff_Diff, allocator)
	context.user_ptr = &sink
	diff_for_each_diff(a, b, diff_test_sink_emit)
	return sink
}

// diff_check_diff collects the runs reported for a/b and compares them
// against the expected script, mirroring check_diff in src/unit_tests.cc.
diff_check_diff :: proc(t: ^testing.T, a, b: string, expected: []Diff_Diff) {
	got := diff_test_collect(a, b)
	defer delete(got)
	testing.expect_value(t, len(got), len(expected))
	for exp, i in expected {
		if i >= len(got) {
			break
		}
		testing.expect_value(t, got[i].op, exp.op)
		testing.expect_value(t, got[i].len, exp.len)
	}
}

// diff_check_reconstruction asserts the script accounts for every byte:
// Keep + Remove consume a, Keep + Add produce b.
diff_check_reconstruction :: proc(t: ^testing.T, a, b: string) {
	got := diff_test_collect(a, b)
	defer delete(got)
	kept, added, removed := 0, 0, 0
	for run in got {
		testing.expect(t, run.len > 0)
		switch run.op {
		case .Keep:
			kept += run.len
		case .Add:
			added += run.len
		case .Remove:
			removed += run.len
		}
	}
	testing.expect_value(t, kept + removed, len(a))
	testing.expect_value(t, kept + added, len(b))
}

@(test)
diff_test_ported_cases :: proc(t: ^testing.T) {
	// 1:1 port of test_diff in src/unit_tests.cc.
	diff_check_diff(t, "a?", "!", {{.Remove, 1}, {.Add, 1}, {.Remove, 1}})
	diff_check_diff(t, "abcde", "cd", {{.Remove, 2}, {.Keep, 2}, {.Remove, 1}})
	diff_check_diff(t, "abcd", "cdef", {{.Remove, 2}, {.Keep, 2}, {.Add, 2}})

	diff_check_diff(
		t,
		"mais que fais la police",
		"mais ou va la police",
		{
			{.Keep, 5},
			{.Remove, 1},
			{.Add, 1},
			{.Keep, 1},
			{.Remove, 1},
			{.Keep, 1},
			{.Add, 1},
			{.Remove, 1},
			{.Keep, 1},
			{.Remove, 2},
			{.Keep, 10},
		},
	)

	diff_check_diff(
		t,
		"abcdefghijk",
		"1cdef2hij34",
		{
			{.Remove, 2},
			{.Add, 1},
			{.Keep, 4},
			{.Remove, 1},
			{.Add, 1},
			{.Keep, 3},
			{.Add, 2},
			{.Remove, 1},
		},
	)
}

@(test)
diff_test_empty_and_identical :: proc(t: ^testing.T) {
	// Empty vs empty reports nothing.
	diff_check_diff(t, "", "", {})
	// Identical inputs are one Keep run.
	diff_check_diff(t, "abc", "abc", {{.Keep, 3}})
	diff_check_diff(t, "x", "x", {{.Keep, 1}})
	// Empty on one side is a pure Add/Remove.
	diff_check_diff(t, "", "abc", {{.Add, 3}})
	diff_check_diff(t, "abc", "", {{.Remove, 3}})
}

@(test)
diff_test_single_byte :: proc(t: ^testing.T) {
	// One differing byte: remove then add (matches the C++ walk).
	diff_check_diff(t, "a", "b", {{.Remove, 1}, {.Add, 1}})
}

@(test)
diff_test_prefix_suffix :: proc(t: ^testing.T) {
	// Common prefix trimmed, differing tail split.
	diff_check_diff(t, "abc", "abd", {{.Keep, 2}, {.Remove, 1}, {.Add, 1}})
	// Common suffix trimmed, differing head split.
	diff_check_diff(t, "xbc", "abc", {{.Remove, 1}, {.Add, 1}, {.Keep, 2}})
	// Prefix consumes one side entirely.
	diff_check_diff(t, "aaa", "aaaa", {{.Keep, 3}, {.Add, 1}})
	diff_check_diff(t, "aaaa", "aaa", {{.Keep, 3}, {.Remove, 1}})
	// Interleaved repeats still coalesce into runs.
	diff_check_diff(t, "abab", "baba", {{.Remove, 1}, {.Keep, 3}, {.Add, 1}})
}

@(test)
diff_test_reconstruction_invariant :: proc(t: ^testing.T) {
	// Classic pairs plus adversarial shapes: every script must account
	// for all of a and all of b.
	diff_check_reconstruction(t, "kitten", "sitting")
	diff_check_reconstruction(t, "saturday", "sunday")
	diff_check_reconstruction(t, "abcdef", "azced")
	diff_check_reconstruction(t, "abc", "def")
	diff_check_reconstruction(t, "", "")
	diff_check_reconstruction(t, "a", "")
	diff_check_reconstruction(t, "", "b")
	diff_check_reconstruction(t, "aaaaaaaaaa", "aaaaa")
	diff_check_reconstruction(t, "aaaaa", "aaaaaaaaaa")
	diff_check_reconstruction(t, "abcabcabc", "abcabcabcabc")
}
