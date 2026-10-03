// Tests for line_modification.odin: 1:1 ports of the C++ UnitTests
// test_line_modifications and test_line_range_set in
// src/line_modification.cc, plus edge cases.
package kak

import "core:testing"

// Line_Modification_Test_Collector gathers the on_new_range callbacks from
// line_modification_range_set_add so tests can compare them afterwards.
Line_Modification_Test_Collector :: struct {
	got: [dynamic]Line_Range,
}

line_modification_test_collect :: proc(data: rawptr, r: Line_Range) {
	collector := (^Line_Modification_Test_Collector)(data)
	append(&collector.got, r)
}

line_modification_test_make_buffer :: proc(lines: []string) -> ^Buffer {
	return buffer_make("test", Buffer_Flags{}, lines, .None, .Lf, .Present, File_Fs_Status{timestamp = File_Invalid_Time})
}

line_modification_test_expect_ranges :: proc(t: ^testing.T, set: ^Line_Range_Set, expected: []Line_Range, loc := #caller_location) {
	testing.expect(t, len(set) == len(expected), "range count mismatch", loc = loc)
	for i in 0 ..< min(len(set), len(expected)) {
		testing.expect_value(t, set[i], expected[i], loc = loc)
	}
}

line_modification_test_expect_new_ranges :: proc(t: ^testing.T, collector: ^Line_Modification_Test_Collector, expected: []Line_Range, loc := #caller_location) {
	testing.expect(t, len(collector.got) == len(expected), "callback count mismatch", loc = loc)
	for i in 0 ..< min(len(collector.got), len(expected)) {
		testing.expect_value(t, collector.got[i], expected[i], loc = loc)
	}
	clear(&collector.got)
}

// Port of C++ UnitTest test_line_modifications: whole-line erase.
@(test)
test_line_modification_erase :: proc(t: ^testing.T) {
	b := line_modification_test_make_buffer([]string{"line 1\n", "line 2\n"})
	defer buffer_destroy(b)
	ts := buffer_timestamp(b)
	_, err := buffer_erase(b, {1, 0}, {2, 0})
	testing.expect_value(t, err, Buffer_Error.None)

	modifs := line_modification_compute(b, ts)
	defer delete(modifs)
	testing.expect(t, len(modifs) == 1)
	testing.expect_value(t, modifs[0], Line_Modification{1, 1, 1, 0})
}

// Port of C++ UnitTest test_line_modifications: single-line insert.
@(test)
test_line_modification_insert :: proc(t: ^testing.T) {
	b := line_modification_test_make_buffer([]string{"line 1\n", "line 2\n"})
	defer buffer_destroy(b)
	ts := buffer_timestamp(b)
	_, err := buffer_insert(b, {2, 0}, "line 3")
	testing.expect_value(t, err, Buffer_Error.None)

	modifs := line_modification_compute(b, ts)
	defer delete(modifs)
	testing.expect(t, len(modifs) == 1)
	testing.expect_value(t, modifs[0], Line_Modification{2, 2, 0, 1})
}

// Port of C++ UnitTest test_line_modifications: insert then erase merging
// into a single modification.
@(test)
test_line_modification_insert_then_erase :: proc(t: ^testing.T) {
	b := line_modification_test_make_buffer([]string{"line 1\n", "line 2\n", "line 3\n"})
	defer buffer_destroy(b)
	ts := buffer_timestamp(b)
	_, err := buffer_insert(b, {1, 4}, "hoho\nhehe")
	testing.expect_value(t, err, Buffer_Error.None)
	_, err = buffer_erase(b, {0, 0}, {1, 0})
	testing.expect_value(t, err, Buffer_Error.None)

	modifs := line_modification_compute(b, ts)
	defer delete(modifs)
	testing.expect(t, len(modifs) == 1)
	testing.expect_value(t, modifs[0], Line_Modification{0, 0, 2, 2})
}

// Port of C++ UnitTest test_line_modifications: erase/insert/erase/insert
// sequence folding into one modification.
@(test)
test_line_modification_erase_insert_sequence :: proc(t: ^testing.T) {
	b := line_modification_test_make_buffer([]string{"line 1\n", "line 2\n", "line 3\n", "line 4\n"})
	defer buffer_destroy(b)
	ts := buffer_timestamp(b)
	_, err := buffer_erase(b, {0, 0}, {3, 0})
	testing.expect_value(t, err, Buffer_Error.None)
	_, err = buffer_insert(b, {1, 0}, "newline 1\nnewline 2\nnewline 3\n")
	testing.expect_value(t, err, Buffer_Error.None)
	_, err = buffer_erase(b, {0, 0}, {1, 0})
	testing.expect_value(t, err, Buffer_Error.None)

	{
		modifs := line_modification_compute(b, ts)
		defer delete(modifs)
		testing.expect(t, len(modifs) == 1)
		testing.expect_value(t, modifs[0], Line_Modification{0, 0, 4, 3})
	}

	_, err = buffer_insert(b, {3, 0}, "newline 4\n")
	testing.expect_value(t, err, Buffer_Error.None)

	{
		modifs := line_modification_compute(b, ts)
		defer delete(modifs)
		testing.expect(t, len(modifs) == 1)
		testing.expect_value(t, modifs[0], Line_Modification{0, 0, 4, 4})
	}
}

// Port of C++ UnitTest test_line_modifications: repeated single-line edits
// coalesce into one modified line.
@(test)
test_line_modification_repeated_edits :: proc(t: ^testing.T) {
	b := line_modification_test_make_buffer([]string{"line 1\n"})
	defer buffer_destroy(b)
	ts := buffer_timestamp(b)
	_, err := buffer_insert(b, {0, 0}, "n")
	testing.expect_value(t, err, Buffer_Error.None)
	_, err = buffer_insert(b, {0, 1}, "e")
	testing.expect_value(t, err, Buffer_Error.None)
	_, err = buffer_insert(b, {0, 2}, "w")
	testing.expect_value(t, err, Buffer_Error.None)

	modifs := line_modification_compute(b, ts)
	defer delete(modifs)
	testing.expect(t, len(modifs) == 1)
	testing.expect_value(t, modifs[0], Line_Modification{0, 0, 1, 1})
}

// Port of C++ UnitTest test_line_range_set block 1: adjacent adds merge,
// re-adding is silent, remove splits.
@(test)
test_line_modification_range_set_merge_split :: proc(t: ^testing.T) {
	set := make(Line_Range_Set, 0)
	defer delete(set)
	collector := Line_Modification_Test_Collector{got = make([dynamic]Line_Range, 0)}
	defer delete(collector.got)

	line_modification_range_set_add(&set, {0, 5}, line_modification_test_collect, &collector)
	line_modification_test_expect_new_ranges(t, &collector, []Line_Range{{0, 5}})
	line_modification_range_set_add(&set, {10, 15}, line_modification_test_collect, &collector)
	line_modification_test_expect_new_ranges(t, &collector, []Line_Range{{10, 15}})
	line_modification_range_set_add(&set, {5, 10}, line_modification_test_collect, &collector)
	line_modification_test_expect_new_ranges(t, &collector, []Line_Range{{5, 10}})
	line_modification_test_expect_ranges(t, &set, []Line_Range{{0, 15}})
	line_modification_range_set_add(&set, {5, 10}, line_modification_test_collect, &collector)
	line_modification_test_expect_new_ranges(t, &collector, []Line_Range{})
	line_modification_range_set_remove(&set, {3, 8})
	line_modification_test_expect_ranges(t, &set, []Line_Range{{0, 3}, {8, 15}})
}

// Port of C++ UnitTest test_line_range_set block 2: bridging add reports
// only the gap.
@(test)
test_line_modification_range_set_bridge :: proc(t: ^testing.T) {
	set := make(Line_Range_Set, 0)
	defer delete(set)
	collector := Line_Modification_Test_Collector{got = make([dynamic]Line_Range, 0)}
	defer delete(collector.got)

	line_modification_range_set_add(&set, {0, 7}, line_modification_test_collect, &collector)
	line_modification_test_expect_new_ranges(t, &collector, []Line_Range{{0, 7}})
	line_modification_range_set_add(&set, {9, 15}, line_modification_test_collect, &collector)
	line_modification_test_expect_new_ranges(t, &collector, []Line_Range{{9, 15}})
	line_modification_range_set_add(&set, {5, 10}, line_modification_test_collect, &collector)
	line_modification_test_expect_new_ranges(t, &collector, []Line_Range{{7, 9}})
	line_modification_test_expect_ranges(t, &set, []Line_Range{{0, 15}})
}

// Port of C++ UnitTest test_line_range_set block 3: partial overlap keeps
// two ranges; remove trims both.
@(test)
test_line_modification_range_set_partial_overlap :: proc(t: ^testing.T) {
	set := make(Line_Range_Set, 0)
	defer delete(set)
	collector := Line_Modification_Test_Collector{got = make([dynamic]Line_Range, 0)}
	defer delete(collector.got)

	line_modification_range_set_add(&set, {0, 7}, line_modification_test_collect, &collector)
	line_modification_test_expect_new_ranges(t, &collector, []Line_Range{{0, 7}})
	line_modification_range_set_add(&set, {11, 15}, line_modification_test_collect, &collector)
	line_modification_test_expect_new_ranges(t, &collector, []Line_Range{{11, 15}})
	line_modification_range_set_add(&set, {5, 10}, line_modification_test_collect, &collector)
	line_modification_test_expect_new_ranges(t, &collector, []Line_Range{{7, 10}})
	line_modification_test_expect_ranges(t, &set, []Line_Range{{0, 10}, {11, 15}})
	line_modification_range_set_remove(&set, {8, 13})
	line_modification_test_expect_ranges(t, &set, []Line_Range{{0, 8}, {13, 15}})
}

// Port of C++ UnitTest test_line_range_set block 4: update through a
// removal and an addition.
@(test)
test_line_modification_range_set_update_mixed :: proc(t: ^testing.T) {
	set := make(Line_Range_Set, 0)
	defer delete(set)
	collector := Line_Modification_Test_Collector{got = make([dynamic]Line_Range, 0)}
	defer delete(collector.got)

	line_modification_range_set_add(&set, {0, 5}, line_modification_test_collect, &collector)
	line_modification_range_set_add(&set, {10, 15}, line_modification_test_collect, &collector)
	line_modification_range_set_update(&set, []Line_Modification{{3, 3, 3, 1}, {11, 9, 2, 4}})
	line_modification_test_expect_ranges(t, &set, []Line_Range{{0, 3}, {8, 9}, {13, 15}})
}

// Port of C++ UnitTest test_line_range_set block 5: update through a pure
// removal.
@(test)
test_line_modification_range_set_update_removal :: proc(t: ^testing.T) {
	set := make(Line_Range_Set, 0)
	defer delete(set)
	collector := Line_Modification_Test_Collector{got = make([dynamic]Line_Range, 0)}
	defer delete(collector.got)

	line_modification_range_set_add(&set, {0, 5}, line_modification_test_collect, &collector)
	line_modification_range_set_update(&set, []Line_Modification{{2, 2, 2, 0}})
	line_modification_test_expect_ranges(t, &set, []Line_Range{{0, 3}})
}

// Port of C++ UnitTest test_line_range_set block 6: update through a pure
// addition splits the range.
@(test)
test_line_modification_range_set_update_addition :: proc(t: ^testing.T) {
	set := make(Line_Range_Set, 0)
	defer delete(set)
	collector := Line_Modification_Test_Collector{got = make([dynamic]Line_Range, 0)}
	defer delete(collector.got)

	line_modification_range_set_add(&set, {0, 5}, line_modification_test_collect, &collector)
	line_modification_range_set_update(&set, []Line_Modification{{2, 2, 0, 2}})
	line_modification_test_expect_ranges(t, &set, []Line_Range{{0, 2}, {4, 7}})
}

// Port of C++ UnitTest test_line_range_set block 7: update shifts ranges
// after a removal.
@(test)
test_line_modification_range_set_update_shift :: proc(t: ^testing.T) {
	set := make(Line_Range_Set, 0)
	defer delete(set)
	collector := Line_Modification_Test_Collector{got = make([dynamic]Line_Range, 0)}
	defer delete(collector.got)

	line_modification_range_set_add(&set, {0, 1}, line_modification_test_collect, &collector)
	line_modification_range_set_add(&set, {5, 10}, line_modification_test_collect, &collector)
	line_modification_range_set_add(&set, {15, 20}, line_modification_test_collect, &collector)
	line_modification_range_set_add(&set, {25, 30}, line_modification_test_collect, &collector)
	line_modification_range_set_update(&set, []Line_Modification{{2, 2, 3, 0}})
	line_modification_test_expect_ranges(t, &set, []Line_Range{{0, 1}, {2, 7}, {12, 17}, {22, 27}})
}

// Edge case: computing right after the timestamp sees no changes.
@(test)
test_line_modification_empty_delta :: proc(t: ^testing.T) {
	b := line_modification_test_make_buffer([]string{"line 1\n", "line 2\n"})
	defer buffer_destroy(b)
	ts := buffer_timestamp(b)

	modifs := line_modification_compute(b, ts)
	defer delete(modifs)
	testing.expect(t, len(modifs) == 0)
}

// Edge case: full-buffer replace collapses into one modification.
@(test)
test_line_modification_full_replace :: proc(t: ^testing.T) {
	b := line_modification_test_make_buffer([]string{"line 1\n", "line 2\n", "line 3\n"})
	defer buffer_destroy(b)
	ts := buffer_timestamp(b)
	_, err := buffer_replace(b, {0, 0}, {3, 0}, "new 1\nnew 2\n")
	testing.expect_value(t, err, Buffer_Error.None)

	modifs := line_modification_compute(b, ts)
	defer delete(modifs)
	testing.expect(t, len(modifs) == 1)
	testing.expect_value(t, modifs[0], Line_Modification{0, 0, 3, 2})
}

// Edge case: two disjoint edits stay as two modifications in order.
@(test)
test_line_modification_disjoint_edits :: proc(t: ^testing.T) {
	b := line_modification_test_make_buffer([]string{"l0\n", "l1\n", "l2\n", "l3\n", "l4\n"})
	defer buffer_destroy(b)
	ts := buffer_timestamp(b)
	_, err := buffer_insert(b, {1, 1}, "x")
	testing.expect_value(t, err, Buffer_Error.None)
	_, err = buffer_insert(b, {3, 1}, "y")
	testing.expect_value(t, err, Buffer_Error.None)

	modifs := line_modification_compute(b, ts)
	defer delete(modifs)
	testing.expect(t, len(modifs) == 2)
	testing.expect_value(t, modifs[0], Line_Modification{1, 1, 1, 1})
	testing.expect_value(t, modifs[1], Line_Modification{3, 3, 1, 1})
}

// Edge case: undo records inverse changes, so an insert fully undone folds
// with its own undo into a no-op modification.
@(test)
test_line_modification_undo_interplay :: proc(t: ^testing.T) {
	b := line_modification_test_make_buffer([]string{"line 1\n", "line 2\n"})
	defer buffer_destroy(b)
	ts := buffer_timestamp(b)
	_, err := buffer_insert(b, {1, 0}, "x\n")
	testing.expect_value(t, err, Buffer_Error.None)
	buffer_commit_undo_group(b)
	ok, uerr := buffer_undo(b)
	testing.expect_value(t, uerr, Buffer_Error.None)
	testing.expect(t, ok)

	modifs := line_modification_compute(b, ts)
	defer delete(modifs)
	testing.expect(t, len(modifs) == 1)
	testing.expect_value(t, modifs[0], Line_Modification{1, 1, 0, 0})
}

// Edge case: diff, reset, and view helpers.
@(test)
test_line_modification_helpers :: proc(t: ^testing.T) {
	testing.expect_value(t, line_modification_diff(Line_Modification{0, 0, 4, 3}), Units_LineCount(-1))
	testing.expect_value(t, line_modification_diff(Line_Modification{2, 5, 1, 1}), Units_LineCount(3))
	testing.expect_value(t, line_modification_diff(Line_Modification{0, 0, 0, 0}), Units_LineCount(0))

	set := make(Line_Range_Set, 0)
	defer delete(set)
	collector := Line_Modification_Test_Collector{got = make([dynamic]Line_Range, 0)}
	defer delete(collector.got)
	line_modification_range_set_add(&set, {0, 5}, line_modification_test_collect, &collector)
	line_modification_range_set_add(&set, {10, 15}, line_modification_test_collect, &collector)
	line_modification_range_set_reset(&set, {7, 9})
	line_modification_test_expect_ranges(t, &set, []Line_Range{{7, 9}})
	view := line_modification_range_set_view(&set)
	testing.expect(t, len(view) == 1)
	testing.expect_value(t, view[0], Line_Range{7, 9})

	// Update with no modifications is a no-op.
	line_modification_range_set_update(&set, []Line_Modification{})
	line_modification_test_expect_ranges(t, &set, []Line_Range{{7, 9}})

	// Removing a disjoint range is a no-op.
	line_modification_range_set_remove(&set, {20, 25})
	line_modification_test_expect_ranges(t, &set, []Line_Range{{7, 9}})
}

// Edge case: remove covering a whole range and remove from an empty set.
@(test)
test_line_modification_remove_edge_cases :: proc(t: ^testing.T) {
	set := make(Line_Range_Set, 0)
	defer delete(set)
	collector := Line_Modification_Test_Collector{got = make([dynamic]Line_Range, 0)}
	defer delete(collector.got)

	// Remove from an empty set is a no-op.
	line_modification_range_set_remove(&set, {0, 5})
	testing.expect(t, len(set) == 0)

	line_modification_range_set_add(&set, {5, 10}, line_modification_test_collect, &collector)
	// Remove exactly covering the range drops it.
	line_modification_range_set_remove(&set, {5, 10})
	testing.expect(t, len(set) == 0)

	line_modification_range_set_add(&set, {5, 10}, line_modification_test_collect, &collector)
	// Remove strictly inside splits into two.
	line_modification_range_set_remove(&set, {6, 8})
	line_modification_test_expect_ranges(t, &set, []Line_Range{{5, 6}, {8, 10}})
}

// Edge case: compute with an explicit tracking allocator reports no leaks.
@(test)
test_line_modification_allocator_cleanup :: proc(t: ^testing.T) {
	b := line_modification_test_make_buffer([]string{"a\n", "b\n"})
	defer buffer_destroy(b)
	ts := buffer_timestamp(b)
	_, err := buffer_insert(b, {1, 0}, "x\n")
	testing.expect_value(t, err, Buffer_Error.None)

	modifs := line_modification_compute(b, ts, context.allocator)
	testing.expect(t, len(modifs) == 1)
	delete(modifs)

	set := make(Line_Range_Set, 0, context.allocator)
	collector := Line_Modification_Test_Collector{got = make([dynamic]Line_Range, 0, context.allocator)}
	defer delete(collector.got)
	line_modification_range_set_add(&set, {0, 5}, line_modification_test_collect, &collector)
	line_modification_range_set_update(&set, []Line_Modification{{1, 1, 0, 2}})
	testing.expect(t, len(set) == 2)
	delete(set)
}
