// Tests for selection.odin (port of src/selection.hh + src/selection.cc).
//
// No C++ UnitTest covers these files, so the tests are written from the
// header/cc semantics: min/max endpoints, overlap, ordering, sorting,
// merging, list lifecycle, UTF-8 column counting, and the Byte-column
// string conversions (which touch no buffer code).
//
// Buffer-dependent behavior (update, clamp, replace, insert, erase,
// for_each, compute_modified_ranges, Codepoint/DisplayColumn conversions)
// calls buffer stubs and is stub-blocked; see the wave summary.
package kak

import "core:strings"
import "core:testing"

// selection_test_sel builds a selection with empty captures.
selection_test_sel :: proc(anchor, cursor: Coord_Buffer) -> Selection {
	return Selection{basic = Basic_Selection{anchor = anchor, cursor = coord_buffer_and_target(cursor)}}
}

// selection_test_dyn builds an owned dynamic selection array.
selection_test_dyn :: proc(items: ..Selection) -> [dynamic]Selection {
	res := make([dynamic]Selection, 0, len(items))
	for s in items {
		append(&res, s)
	}
	return res
}

@(test)
test_selection_min_max :: proc(t: ^testing.T) {
	fwd := selection_test_sel({0, 1}, {0, 5})
	testing.expect_value(t, selection_basic_min(fwd.basic), Coord_Buffer{0, 1})
	testing.expect_value(t, selection_basic_max(fwd.basic), Coord_Buffer{0, 5})
	testing.expect(t, selection_min_is_anchor(fwd.basic))

	rev := selection_test_sel({0, 5}, {0, 1})
	testing.expect_value(t, selection_basic_min(rev.basic), Coord_Buffer{0, 1})
	testing.expect_value(t, selection_basic_max(rev.basic), Coord_Buffer{0, 5})
	testing.expect(t, !selection_min_is_anchor(rev.basic))

	// single-char selection: anchor counts as min
	single := selection_test_sel({2, 2}, {2, 2})
	testing.expect(t, selection_min_is_anchor(single.basic))
	testing.expect_value(t, selection_basic_min(single.basic), Coord_Buffer{2, 2})

	// assignment through first/last preserves cursor targets
	targeted := Selection {
		basic = Basic_Selection {
			anchor = {3, 3},
			cursor = coord_buffer_and_target({3, 7}, 42, 43),
		},
	}
	first := selection_first(&targeted)
	testing.expect_value(t, first^, Coord_Buffer{3, 3})
	last := selection_last(&targeted)
	testing.expect_value(t, last^, Coord_Buffer{3, 7})
	last^ = Coord_Buffer{3, 9}
	testing.expect_value(t, targeted.cursor.coord, Coord_Buffer{3, 9})
	testing.expect_value(t, targeted.cursor.target, Coord_Column(42))
	testing.expect_value(t, targeted.cursor.display_target, Coord_Column(43))
}

@(test)
test_selection_overlaps :: proc(t: ^testing.T) {
	a := selection_test_sel({0, 1}, {0, 5}).basic
	testing.expect(t, selection_overlaps(a, a))
	// touching at one endpoint overlaps
	testing.expect(t, selection_overlaps(a, selection_test_sel({0, 5}, {0, 8}).basic))
	testing.expect(t, selection_overlaps(a, selection_test_sel({0, 0}, {0, 1}).basic))
	// disjoint
	testing.expect(t, !selection_overlaps(a, selection_test_sel({0, 6}, {0, 8}).basic))
	testing.expect(t, !selection_overlaps(a, selection_test_sel({1, 0}, {1, 2}).basic))
	// direction does not matter
	testing.expect(t, selection_overlaps(selection_test_sel({0, 8}, {0, 5}).basic, a))
	testing.expect(t, !selection_overlaps(a, selection_test_sel({0, 8}, {0, 6}).basic))
}

@(test)
test_selection_compare_and_any_overlaps :: proc(t: ^testing.T) {
	a := selection_test_sel({0, 1}, {0, 5})
	b := selection_test_sel({0, 1}, {0, 3})
	c := selection_test_sel({0, 2}, {0, 9})
	// same min: shorter max first
	testing.expect(t, selection_compare(b, a))
	testing.expect(t, !selection_compare(a, b))
	testing.expect(t, selection_compare(a, c))
	testing.expect(t, selection_compare(b, c))
	testing.expect(t, !selection_compare(a, a))

	sorted_disjoint := [2]Selection{selection_test_sel({0, 0}, {0, 1}), selection_test_sel({0, 3}, {0, 4})}
	testing.expect(t, !selection_any_overlaps(sorted_disjoint[:]))
	sorted_touching := [2]Selection{selection_test_sel({0, 0}, {0, 3}), selection_test_sel({0, 3}, {0, 4})}
	testing.expect(t, selection_any_overlaps(sorted_touching[:]))
	testing.expect(t, !selection_any_overlaps(nil))
}

@(test)
test_selection_update_insert :: proc(t: ^testing.T) {
	// before the insertion: unchanged
	testing.expect_value(
		t,
		selection_update_insert({0, 0}, {0, 5}, {0, 8}),
		Coord_Buffer{0, 0},
	)
	// same line, at/after begin: shifted by the width
	testing.expect_value(
		t,
		selection_update_insert({0, 5}, {0, 5}, {0, 8}),
		Coord_Buffer{0, 8},
	)
	testing.expect_value(
		t,
		selection_update_insert({0, 7}, {0, 5}, {0, 8}),
		Coord_Buffer{0, 10},
	)
	// later line: gains lines, keeps column
	testing.expect_value(
		t,
		selection_update_insert({3, 2}, {0, 5}, {2, 8}),
		Coord_Buffer{5, 2},
	)
	// multiline insertion onto the same line shifts both parts
	testing.expect_value(
		t,
		selection_update_insert({0, 7}, {0, 5}, {2, 1}),
		Coord_Buffer{2, 3},
	)
}

@(test)
test_selection_sort :: proc(t: ^testing.T) {
	sels := selection_test_dyn(
		selection_test_sel({0, 8}, {0, 9}),
		selection_test_sel({0, 1}, {0, 2}),
		selection_test_sel({0, 4}, {0, 5}),
	)
	defer delete(sels)
	main := 0 // the {0,8} selection
	selection_sort(&sels, &main)
	testing.expect_value(t, sels[0].anchor, Coord_Buffer{0, 1})
	testing.expect_value(t, sels[1].anchor, Coord_Buffer{0, 4})
	testing.expect_value(t, sels[2].anchor, Coord_Buffer{0, 8})
	testing.expect_value(t, main, 2)

	// equal mins sort by max (stable); note the C++ recomputes main from
	// the min only, so with equal mins main keeps its relative slot (0
	// here) even though the main element sorts second. Verified against
	// the C++ count_if/stable_sort logic.
	tied := selection_test_dyn(
		selection_test_sel({1, 0}, {1, 5}),
		selection_test_sel({1, 0}, {1, 1}),
	)
	defer delete(tied)
	tied_main := 0
	selection_sort(&tied, &tied_main)
	// shorter max first
	testing.expect_value(t, tied[0].cursor.coord, Coord_Buffer{1, 1})
	testing.expect_value(t, tied[1].cursor.coord, Coord_Buffer{1, 5})
	testing.expect_value(t, tied_main, 0)

	// single selection: no-op
	one := selection_test_dyn(selection_test_sel({0, 0}, {0, 0}))
	defer delete(one)
	one_main := 0
	selection_sort(&one, &one_main)
	testing.expect_value(t, one_main, 0)
}

@(test)
test_selection_merge_overlapping :: proc(t: ^testing.T) {
	// chain merge keeps first captures, main tracks the merged run
	sels := selection_test_dyn(
		selection_test_sel({0, 0}, {0, 2}),
		selection_test_sel({0, 2}, {0, 4}),
		selection_test_sel({0, 9}, {0, 9}),
	)
	defer {
		for &s in sels {
			selection_destroy(&s)
		}
		delete(sels)
	}
	main := 1
	selection_merge_overlapping(&sels, &main)
	testing.expect_value(t, len(sels), 2)
	testing.expect_value(t, selection_basic_min(sels[0].basic), Coord_Buffer{0, 0})
	testing.expect_value(t, selection_basic_max(sels[0].basic), Coord_Buffer{0, 4})
	testing.expect_value(t, main, 0)
	testing.expect_value(t, sels[1].anchor, Coord_Buffer{0, 9})

	// main after the merged run shifts down
	sels2 := selection_test_dyn(
		selection_test_sel({0, 0}, {0, 2}),
		selection_test_sel({0, 1}, {0, 3}),
		selection_test_sel({0, 9}, {0, 9}),
	)
	defer delete(sels2)
	main2 := 2
	selection_merge_overlapping(&sels2, &main2)
	testing.expect_value(t, len(sels2), 2)
	testing.expect_value(t, main2, 1)

	// no overlaps: untouched
	sels3 := selection_test_dyn(
		selection_test_sel({0, 0}, {0, 1}),
		selection_test_sel({0, 5}, {0, 6}),
	)
	defer delete(sels3)
	main3 := 1
	selection_merge_overlapping(&sels3, &main3)
	testing.expect_value(t, len(sels3), 2)
	testing.expect_value(t, main3, 1)
}

@(test)
test_selection_inplace_merge :: proc(t: ^testing.T) {
	sels := selection_test_dyn(
		selection_test_sel({0, 0}, {0, 1}),
		selection_test_sel({0, 8}, {0, 9}),
		selection_test_sel({0, 2}, {0, 3}),
		selection_test_sel({0, 4}, {0, 5}),
	)
	defer delete(sels)
	selection_inplace_merge(&sels, 2)
	testing.expect_value(t, selection_basic_min(sels[0].basic), Coord_Buffer{0, 0})
	testing.expect_value(t, selection_basic_min(sels[1].basic), Coord_Buffer{0, 2})
	testing.expect_value(t, selection_basic_min(sels[2].basic), Coord_Buffer{0, 4})
	testing.expect_value(t, selection_basic_min(sels[3].basic), Coord_Buffer{0, 8})
}

@(test)
test_selection_clone_destroy_roundtrip :: proc(t: ^testing.T) {
	src := selection_test_sel({1, 2}, {3, 4})
	src.captures = make([dynamic]string, 0, 2)
	append(&src.captures, strings.clone("foo"))
	defer selection_destroy(&src)
	dup := selection_clone(src)
	defer selection_destroy(&dup)
	testing.expect_value(t, dup.anchor, src.anchor)
	testing.expect_value(t, dup.cursor.coord, src.cursor.coord)
	testing.expect_value(t, len(dup.captures), 1)
	testing.expect_value(t, dup.captures[0], string("foo"))
	// deep copy: distinct backing
	testing.expect(t, raw_data(dup.captures) != raw_data(src.captures))
}

@(test)
test_selection_list_lifecycle :: proc(t: ^testing.T) {
	buffer: Buffer
	sels := [2]Selection{selection_test_sel({0, 5}, {0, 6}), selection_test_sel({0, 0}, {0, 1})}
	list := selection_list_make(&buffer, sels[:], 7)
	defer selection_list_destroy(&list)
	testing.expect_value(t, len(list.selections), 2)
	testing.expect_value(t, list.main, 1)
	testing.expect_value(t, selection_list_timestamp(&list), 7)
	testing.expect(t, selection_list_buffer(&list) == &buffer)

	// main accessors
	testing.expect_value(t, selection_list_main(&list).anchor, Coord_Buffer{0, 0})
	selection_list_set_main_index(&list, 0)
	testing.expect_value(t, selection_list_main_index(&list), 0)
	selection_list_force_timestamp(&list, 42)
	testing.expect_value(t, selection_list_timestamp(&list), 42)

	// clone is a deep copy
	dup := selection_list_clone(&list)
	defer selection_list_destroy(&dup)
	testing.expect_value(t, len(dup.selections), 2)
	testing.expect_value(t, dup.main, 0)
	testing.expect_value(t, dup.timestamp, 42)

	// sort + merge via the list
	selection_list_sort(&list)
	testing.expect_value(t, list.selections[0].anchor, Coord_Buffer{0, 0})
	selection_list_push_back(&list, selection_test_sel({0, 0}, {0, 3}))
	testing.expect_value(t, len(list.selections), 3)
	selection_list_sort_and_merge_overlapping(&list)
	testing.expect_value(t, len(list.selections), 2)
	testing.expect_value(t, selection_basic_max(list.selections[0].basic), Coord_Buffer{0, 3})

	// remove adjusts main
	selection_list_set_main_index(&list, 1)
	selection_list_remove(&list, 0)
	testing.expect_value(t, len(list.selections), 1)
	testing.expect_value(t, selection_list_main_index(&list), 0)

	// remove_from drops the tail
	selection_list_push_back(&list, selection_test_sel({1, 0}, {1, 1}))
	selection_list_push_back(&list, selection_test_sel({2, 0}, {2, 1}))
	selection_list_set_main_index(&list, 2)
	selection_list_remove_from(&list, 1)
	testing.expect_value(t, len(list.selections), 1)
	testing.expect_value(t, selection_list_main_index(&list), 0)

	// single-selection list ctor
	single := selection_list_make_single(&buffer, selection_test_sel({4, 4}, {4, 4}), 3)
	defer selection_list_destroy(&single)
	testing.expect_value(t, len(single.selections), 1)
	testing.expect_value(t, single.main, 0)
}

@(test)
test_selection_char_byte_counts :: proc(t: ^testing.T) {
	// "aéb": a=1 byte, é=2 bytes, b=1 byte
	line := "a\xc3\xa9b"
	testing.expect_value(t, selection_char_count_to(line, 0), 0)
	testing.expect_value(t, selection_char_count_to(line, 1), 1)
	testing.expect_value(t, selection_char_count_to(line, 3), 2)
	testing.expect_value(t, selection_char_count_to(line, 4), 3)
	testing.expect_value(t, selection_byte_count_to(line, 0), 0)
	testing.expect_value(t, selection_byte_count_to(line, 1), 1)
	testing.expect_value(t, selection_byte_count_to(line, 2), 3)
	testing.expect_value(t, selection_byte_count_to(line, 3), 4)
}

@(test)
test_selection_to_from_string_byte :: proc(t: ^testing.T) {
	buffer: Buffer
	sel := selection_test_sel({0, 0}, {1, 4})
	s, err := selection_to_string(.Byte, &buffer, sel)
	testing.expect_value(t, err, Selection_Error.None)
	defer delete(s)
	testing.expect_value(t, s, "1.1,2.5")

	// round trip
	back, berr := selection_from_string(.Byte, &buffer, s)
	testing.expect_value(t, berr, Selection_Error.None)
	testing.expect_value(t, back.anchor, Coord_Buffer{0, 0})
	testing.expect_value(t, back.cursor.coord, Coord_Buffer{1, 4})
	testing.expect_value(t, back.cursor.target, Coord_Column(-1))
}

@(test)
test_selection_from_string_errors :: proc(t: ^testing.T) {
	buffer: Buffer
	bad_format := [7]string{"", "1.1", "1,2.3", "1.1,2", "a.b,c.d", "1.1,2.3.4", "1.1,,2.3"}
	for desc in bad_format {
		_, err := selection_from_string(.Byte, &buffer, desc)
		testing.expect_value(t, err, Selection_Error.Invalid_Format)
	}
	// 1-based: 0 maps to -1, which does not exist
	bad_coord := [4]string{"0.1,1.1", "1.0,1.1", "1.1,0.1", "-1.1,1.1"}
	for desc in bad_coord {
		_, err := selection_from_string(.Byte, &buffer, desc)
		testing.expect_value(t, err, Selection_Error.Invalid_Coordinate)
	}
}

@(test)
test_selection_list_to_string_byte :: proc(t: ^testing.T) {
	buffer: Buffer
	sels := [3]Selection{
		selection_test_sel({0, 0}, {0, 0}),
		selection_test_sel({1, 1}, {1, 1}),
		selection_test_sel({2, 2}, {2, 2}),
	}
	list := selection_list_make(&buffer, sels[:], 0)
	defer selection_list_destroy(&list)
	selection_list_set_main_index(&list, 1)
	// main-first ordering: selections[1], [2], [0]
	s, err := selection_list_to_string(.Byte, &list)
	testing.expect_value(t, err, Selection_Error.None)
	defer delete(s)
	testing.expect_value(t, s, "2.2,2.2 3.3,3.3 1.1,1.1")
}

@(test)
test_selection_erase_read_only_propagates :: proc(t: ^testing.T) {
	// Coordinator integration test: buffer errors propagate through the
	// selection cascade (C++ parity: read-only throws unwind to callers).
	lines := [1]string{"hello"}
	b := buffer_make("*test*", {.Read_Only}, lines[:], .None, .Lf, .Present, File_Fs_Status{}, context.allocator)
	defer buffer_destroy(b)
	sels := [1]Selection{selection_test_sel({0, 0}, {0, 4})}
	list := selection_list_make(b, sels[:], buffer_timestamp(b))
	defer selection_list_destroy(&list)
	testing.expect_value(t, selection_list_erase(&list), Buffer_Error.Read_Only)
	testing.expect_value(t, b.lines[0], "hello")
}
