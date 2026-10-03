// Port of the test_ranges UnitTest from src/ranges.cc plus edge cases.
package kak

import "core:testing"

// ranges_test_unescape replicates String unescape(StringView, StringView,
// char) from src/string_utils.cc for the separator/escaper characters
// used by the split tests below. It is a test-local stand-in until the
// string_utils module is ported; its semantics were verified against
// src/string_utils.cc by hand-tracing both implementations.
ranges_test_unescape :: proc(s: string) -> [dynamic]byte {
	res := make([dynamic]byte, 0, len(s))
	i := 0
	for i < len(s) {
		j := i
		for j < len(s) && s[j] != '\\' {
			j += 1
		}
		if j < len(s) && j + 1 < len(s) && (s[j + 1] == ',' || s[j + 1] == '\\') {
			for k in i ..= j {
				append(&res, s[k])
			}
			res[len(res) - 1] = s[j + 1]
			i = j + 2
		} else {
			end := j + 1 if j < len(s) else j
			for k in i ..< end {
				append(&res, s[k])
			}
			i = end
		}
	}
	return res
}

ranges_test_check_strings :: proc(t: ^testing.T, got: []string, expected: []string, loc := #caller_location) {
	testing.expect_value(t, len(got), len(expected), loc = loc)
	for e, i in expected {
		if i < len(got) {
			testing.expect_value(t, got[i], e, loc = loc)
		}
	}
}

ranges_test_check_ints :: proc(t: ^testing.T, got: []int, expected: []int, loc := #caller_location) {
	testing.expect_value(t, len(got), len(expected), loc = loc)
	for e, i in expected {
		if i < len(got) {
			testing.expect_value(t, got[i], e, loc = loc)
		}
	}
}

ranges_test_check_bytes :: proc(t: ^testing.T, got: []byte, expected: string, loc := #caller_location) {
	testing.expect_value(t, string(got), expected, loc = loc)
}

// Port of the split assertions in test_ranges (src/ranges.cc).
@(test)
ranges_test_split :: proc(t: ^testing.T) {
	inputs := []string{"a,b,c", ",b,c", ",b,", ","}
	expected := [][]string{{"a", "b", "c"}, {"", "b", "c"}, {"", "b", ""}, {"", ""}}
	for input, k in inputs {
		got := ranges_split(input, ',')
		defer delete(got)
		ranges_test_check_strings(t, got[:], expected[k])
	}

	got := ranges_split("", ',')
	defer delete(got)
	testing.expect_value(t, len(got), 0)
}

// Port of the split_after assertions in test_ranges (src/ranges.cc).
@(test)
ranges_test_split_after :: proc(t: ^testing.T) {
	got := ranges_split_after("a,b,c,", ',')
	defer delete(got)
	ranges_test_check_strings(t, got[:], []string{"a,", "b,", "c,"})

	got2 := ranges_split_after("a,b,c", ',')
	defer delete(got2)
	ranges_test_check_strings(t, got2[:], []string{"a,", "b,", "c"})
}

// Port of the escaped-split + unescape assertions in test_ranges
// (src/ranges.cc). transform(unescape) becomes ranges_transform with
// the test-local ranges_test_unescape stand-in.
@(test)
ranges_test_split_escaped_unescape :: proc(t: ^testing.T) {
	inputs := []string{`a\,,` + `\,b` + `,\,`, `\,\,`, `\\,\\,`}
	expected := [][]string{{"a,", ",b", ","}, {",,"}, {`\`, `\`, ""}}
	for input, k in inputs {
		pieces := ranges_split_escaped(input, ',', '\\')
		defer delete(pieces)
		got := ranges_transform(pieces[:], ranges_test_unescape)
		defer {
			for g in got {
				delete(g)
			}
			delete(got)
		}
		testing.expect_value(t, len(got), len(expected[k]))
		for e, i in expected[k] {
			if i < len(got) {
				ranges_test_check_bytes(t, got[i][:], e)
			}
		}
	}
}

// Port of the flatten assertions in test_ranges (src/ranges.cc).
@(test)
ranges_test_flatten :: proc(t: ^testing.T) {
	got := ranges_flatten_bytes([]string{"", "abc", "", "def", ""})
	defer delete(got)
	ranges_test_check_bytes(t, got[:], "abcdef")

	got2 := ranges_flatten_bytes([]string{"", ""})
	defer delete(got2)
	testing.expect_value(t, len(got2), 0)

	got3 := ranges_flatten_bytes([]string{})
	defer delete(got3)
	testing.expect_value(t, len(got3), 0)
}

@(test)
ranges_test_split_edges :: proc(t: ^testing.T) {
	// No separator present: single piece borrowing the whole input.
	got := ranges_split("abc", ',')
	defer delete(got)
	ranges_test_check_strings(t, got[:], []string{"abc"})

	// Separators only.
	got2 := ranges_split(",,", ',')
	defer delete(got2)
	ranges_test_check_strings(t, got2[:], []string{"", "", ""})

	// Leading / trailing separators yield empty edge pieces.
	got3 := ranges_split(",a", ',')
	defer delete(got3)
	ranges_test_check_strings(t, got3[:], []string{"", "a"})

	got4 := ranges_split("a,", ',')
	defer delete(got4)
	ranges_test_check_strings(t, got4[:], []string{"a", ""})

	// Single character, no separator.
	got5 := ranges_split("a", ',')
	defer delete(got5)
	ranges_test_check_strings(t, got5[:], []string{"a"})
}

@(test)
ranges_test_split_after_edges :: proc(t: ^testing.T) {
	got := ranges_split_after("abc", ',')
	defer delete(got)
	ranges_test_check_strings(t, got[:], []string{"abc"})

	// Lone separator is kept as its own piece.
	got2 := ranges_split_after(",", ',')
	defer delete(got2)
	ranges_test_check_strings(t, got2[:], []string{","})

	// Consecutive separators: empty piece between them keeps its separator.
	got3 := ranges_split_after("a,,", ',')
	defer delete(got3)
	ranges_test_check_strings(t, got3[:], []string{"a,", ","})

	got4 := ranges_split_after(",a", ',')
	defer delete(got4)
	ranges_test_check_strings(t, got4[:], []string{",", "a"})

	got5 := ranges_split_after("", ',')
	defer delete(got5)
	testing.expect_value(t, len(got5), 0)
}

@(test)
ranges_test_split_escaped_edges :: proc(t: ^testing.T) {
	// No escapers: behaves like a plain split.
	got := ranges_split_escaped("a,b", ',', '\\')
	defer delete(got)
	ranges_test_check_strings(t, got[:], []string{"a", "b"})

	// Escaped separator stays inside the piece, escaper kept.
	got2 := ranges_split_escaped(`a\,b`, ',', '\\')
	defer delete(got2)
	ranges_test_check_strings(t, got2[:], []string{`a\,b`})
	un := ranges_test_unescape(got2[0])
	defer delete(un)
	ranges_test_check_bytes(t, un[:], "a,b")

	// Trailing escaper is kept as-is by both split and unescape.
	got3 := ranges_split_escaped(`ab\`, ',', '\\')
	defer delete(got3)
	ranges_test_check_strings(t, got3[:], []string{`ab\`})
	un3 := ranges_test_unescape(got3[0])
	defer delete(un3)
	ranges_test_check_bytes(t, un3[:], `ab\`)

	// Escaper before a non-special char: unescape leaves it alone.
	un4 := ranges_test_unescape(`a\b`)
	defer delete(un4)
	ranges_test_check_bytes(t, un4[:], `a\b`)

	// Escaped escaper does not escape the following separator.
	got5 := ranges_split_escaped(`\\,x`, ',', '\\')
	defer delete(got5)
	ranges_test_check_strings(t, got5[:], []string{`\\`, "x"})

	// Empty input yields no pieces even with an escaper.
	got6 := ranges_split_escaped("", ',', '\\')
	defer delete(got6)
	testing.expect_value(t, len(got6), 0)
}

@(test)
ranges_test_reverse_skip_drop :: proc(t: ^testing.T) {
	nums := []int{1, 2, 3, 4}
	ranges_reverse(nums)
	ranges_test_check_ints(t, nums, []int{4, 3, 2, 1})

	single := []int{7}
	ranges_reverse(single)
	ranges_test_check_ints(t, single, []int{7})

	empty := []int{}
	ranges_reverse(empty)
	testing.expect_value(t, len(empty), 0)

	// Non-mutating copy leaves the input alone.
	src := []int{1, 2, 3}
	rev := ranges_reversed(src)
	defer delete(rev)
	ranges_test_check_ints(t, rev[:], []int{3, 2, 1})
	ranges_test_check_ints(t, src, []int{1, 2, 3})

	ranges_test_check_ints(t, ranges_skip([]int{1, 2, 3}, 1), []int{2, 3})
	ranges_test_check_ints(t, ranges_skip([]int{1, 2, 3}, 0), []int{1, 2, 3})
	testing.expect_value(t, len(ranges_skip([]int{1, 2, 3}, 5)), 0)
	ranges_test_check_ints(t, ranges_skip([]int{1, 2, 3}, -2), []int{1, 2, 3})

	ranges_test_check_ints(t, ranges_drop([]int{1, 2, 3}, 1), []int{1, 2})
	ranges_test_check_ints(t, ranges_drop([]int{1, 2, 3}, 0), []int{1, 2, 3})
	testing.expect_value(t, len(ranges_drop([]int{1, 2, 3}, 3)), 0)
	testing.expect_value(t, len(ranges_drop([]int{1, 2, 3}, 9)), 0)
}

@(test)
ranges_test_filter_enumerate_transform :: proc(t: ^testing.T) {
	is_even := proc(v: int) -> bool { return v % 2 == 0 }

	got := ranges_filter([]int{1, 2, 3, 4, 5, 6}, is_even)
	defer delete(got)
	ranges_test_check_ints(t, got[:], []int{2, 4, 6})

	none := ranges_filter([]int{1, 3, 5}, is_even)
	defer delete(none)
	testing.expect_value(t, len(none), 0)

	idx := ranges_enumerate([]string{"x", "y"})
	defer delete(idx)
	testing.expect_value(t, len(idx), 2)
	testing.expect_value(t, idx[0].index, 0)
	testing.expect_value(t, idx[0].value, "x")
	testing.expect_value(t, idx[1].index, 1)
	testing.expect_value(t, idx[1].value, "y")

	doubled := ranges_transform([]int{1, 2, 3}, proc(v: int) -> int { return v * 2 })
	defer delete(doubled)
	ranges_test_check_ints(t, doubled[:], []int{2, 4, 6})

	lens := ranges_transform([]string{"", "ab", "c"}, proc(s: string) -> int { return len(s) })
	defer delete(lens)
	ranges_test_check_ints(t, lens[:], []int{0, 2, 1})
}

@(test)
ranges_test_find_contains_all_any :: proc(t: ^testing.T) {
	nums := []int{10, 20, 30}

	i, found := ranges_find(nums, 20)
	testing.expect(t, found)
	testing.expect_value(t, i, 1)

	_, missing := ranges_find(nums, 99)
	testing.expect(t, !missing)

	j, found2 := ranges_find_if(nums, proc(v: int) -> bool { return v > 15 })
	testing.expect(t, found2)
	testing.expect_value(t, j, 1)

	testing.expect(t, ranges_contains(nums, 30))
	testing.expect(t, !ranges_contains(nums, 0))
	testing.expect(t, !ranges_contains([]int{}, 1))

	testing.expect(t, ranges_all_of(nums, proc(v: int) -> bool { return v > 0 }))
	testing.expect(t, !ranges_all_of(nums, proc(v: int) -> bool { return v > 15 }))
	testing.expect(t, ranges_all_of([]int{}, proc(v: int) -> bool { return false }))

	testing.expect(t, ranges_any_of(nums, proc(v: int) -> bool { return v == 20 }))
	testing.expect(t, !ranges_any_of(nums, proc(v: int) -> bool { return v < 0 }))
	testing.expect(t, !ranges_any_of([]int{}, proc(v: int) -> bool { return true }))
}

@(test)
ranges_test_remove_unordered_erase :: proc(t: ^testing.T) {
	nums := []int{1, 2, 3, 4, 5, 6}
	kept := ranges_remove_if(nums, proc(v: int) -> bool { return v % 2 == 0 })
	ranges_test_check_ints(t, kept, []int{1, 3, 5})

	all_kept := ranges_remove_if([]int{1, 3}, proc(v: int) -> bool { return false })
	ranges_test_check_ints(t, all_kept, []int{1, 3})

	dyn := ranges_gather([]int{1, 2, 3})
	defer delete(dyn)
	ranges_unordered_erase(&dyn, 2)
	ranges_test_check_ints(t, dyn[:], []int{1, 3})

	// Erasing an absent value is a no-op.
	ranges_unordered_erase(&dyn, 99)
	ranges_test_check_ints(t, dyn[:], []int{1, 3})
}

@(test)
ranges_test_accumulate_for_n_best :: proc(t: ^testing.T) {
	sum := ranges_accumulate([]int{1, 2, 3, 4}, 0, proc(acc, v: int) -> int { return acc + v })
	testing.expect_value(t, sum, 10)

	empty_sum := ranges_accumulate([]int{}, 42, proc(acc, v: int) -> int { return acc + v })
	testing.expect_value(t, empty_sum, 42)

	less := proc(a, b: int) -> bool { return a < b }

	// Best-first order, stops after count acceptances.
	ranges_test_best_calls = make([dynamic]int)
	defer delete(ranges_test_best_calls)
	ranges_for_n_best([]int{3, 1, 2}, 2, less, ranges_test_record_best)
	ranges_test_check_ints(t, ranges_test_best_calls[:], []int{3, 2})

	// Count larger than the input visits everything best-first.
	clear(&ranges_test_best_calls)
	ranges_for_n_best([]int{3, 1, 2}, 9, less, ranges_test_record_best)
	ranges_test_check_ints(t, ranges_test_best_calls[:], []int{3, 2, 1})

	// Rejected elements are consumed but do not count down.
	clear(&ranges_test_best_calls)
	ranges_for_n_best([]int{3, 1, 2}, 9, less, ranges_test_reject_best)
	ranges_test_check_ints(t, ranges_test_best_calls[:], []int{3, 2, 1})

	// Zero count and empty input never call func.
	clear(&ranges_test_best_calls)
	ranges_for_n_best([]int{3, 1, 2}, 0, less, ranges_test_record_best)
	testing.expect_value(t, len(ranges_test_best_calls), 0)
	ranges_for_n_best([]int{}, 3, less, ranges_test_record_best)
	testing.expect_value(t, len(ranges_test_best_calls), 0)
}

// Recording callbacks for ranges_test_accumulate_for_n_best. Plain
// procs cannot close over test state, so calls go to a shared buffer.
ranges_test_best_calls: [dynamic]int

ranges_test_record_best :: proc(v: int) -> bool {
	append(&ranges_test_best_calls, v)
	return true
}

ranges_test_reject_best :: proc(v: int) -> bool {
	append(&ranges_test_best_calls, v)
	return false
}

@(test)
ranges_test_gather_concat_flatten_static :: proc(t: ^testing.T) {
	got := ranges_gather([]int{1, 2})
	defer delete(got)
	ranges_test_check_ints(t, got[:], []int{1, 2})

	cat := ranges_concatenated([]int{1}, []int{2, 3})
	defer delete(cat)
	ranges_test_check_ints(t, cat[:], []int{1, 2, 3})

	empty_cat := ranges_concatenated([]int{}, []int{})
	defer delete(empty_cat)
	testing.expect_value(t, len(empty_cat), 0)

	flat := ranges_flatten([][]int{{}, {1, 2}, {}, {3}})
	defer delete(flat)
	ranges_test_check_ints(t, flat[:], []int{1, 2, 3})

	flat_empty := ranges_flatten([][]int{})
	defer delete(flat_empty)
	testing.expect_value(t, len(flat_empty), 0)

	arr, ok := ranges_static_gather([]int{4, 5}, 2)
	testing.expect(t, ok)
	testing.expect_value(t, arr, [2]int{4, 5})

	_, bad := ranges_static_gather([]int{4, 5, 6}, 2)
	testing.expect(t, !bad)

	arr2, ok2 := ranges_static_gather([]int{4, 5, 6}, 2, false)
	testing.expect(t, ok2)
	testing.expect_value(t, arr2, [2]int{4, 5})

	_, short := ranges_static_gather([]int{4}, 2, false)
	testing.expect(t, !short)
}
