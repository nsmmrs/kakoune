// Tests for changes.odin (port of src/changes.hh + src/changes.cc).
//
// No C++ UnitTest covers these files, so the tests are written from the
// header/cc semantics: tracker insert/erase folding, old/new coordinate
// mapping, run splitting, and selection shifting through changes.
//
// changes_update_buffer and changes_update_ranges call buffer stubs and are
// not covered here (stub-blocked).
package kak

import "core:testing"

@(test)
test_changes_tracker_insert_same_line :: proc(t: ^testing.T) {
	tracker: Forward_Changes_Tracker
	changes_update_change(&tracker, Buffer_Change{type = .Insert, begin = {0, 5}, end = {0, 8}})
	testing.expect_value(t, tracker.old_pos, Coord_Buffer{0, 5})
	testing.expect_value(t, tracker.cur_pos, Coord_Buffer{0, 8})

	// coordinates at/after the insertion shift by its width
	testing.expect_value(t, changes_get_new_coord(&tracker, {0, 5}), Coord_Buffer{0, 8})
	testing.expect_value(t, changes_get_new_coord(&tracker, {0, 7}), Coord_Buffer{0, 10})
	// other lines are unaffected
	testing.expect_value(t, changes_get_new_coord(&tracker, {1, 2}), Coord_Buffer{1, 2})
	// and back again
	testing.expect_value(t, changes_get_old_coord(&tracker, {0, 8}), Coord_Buffer{0, 5})
	testing.expect_value(t, changes_get_old_coord(&tracker, {0, 10}), Coord_Buffer{0, 7})
}

@(test)
test_changes_tracker_insert_multiline :: proc(t: ^testing.T) {
	tracker: Forward_Changes_Tracker
	changes_update_change(&tracker, Buffer_Change{type = .Insert, begin = {0, 3}, end = {2, 1}})
	// same-line tail shifts by the column delta and gains the new lines
	testing.expect_value(t, changes_get_new_coord(&tracker, {0, 5}), Coord_Buffer{2, 3})
	// later lines only gain lines
	testing.expect_value(t, changes_get_new_coord(&tracker, {3, 4}), Coord_Buffer{5, 4})
	// reverse mapping
	testing.expect_value(t, changes_get_old_coord(&tracker, {2, 1}), Coord_Buffer{0, 3})
	testing.expect_value(t, changes_get_old_coord(&tracker, {5, 4}), Coord_Buffer{3, 4})
}

@(test)
test_changes_tracker_erase :: proc(t: ^testing.T) {
	tracker: Forward_Changes_Tracker
	changes_update_change(&tracker, Buffer_Change{type = .Erase, begin = {0, 2}, end = {0, 5}})
	testing.expect_value(t, tracker.old_pos, Coord_Buffer{0, 5})
	testing.expect_value(t, tracker.cur_pos, Coord_Buffer{0, 2})
	testing.expect_value(t, changes_get_new_coord(&tracker, {0, 5}), Coord_Buffer{0, 2})
	testing.expect_value(t, changes_get_new_coord(&tracker, {0, 7}), Coord_Buffer{0, 4})
	testing.expect_value(t, changes_get_new_coord(&tracker, {4, 0}), Coord_Buffer{4, 0})
	testing.expect_value(t, changes_get_old_coord(&tracker, {0, 2}), Coord_Buffer{0, 5})
}

@(test)
test_changes_tracker_sequential_and_tolerant :: proc(t: ^testing.T) {
	tracker: Forward_Changes_Tracker
	changes_update_change(&tracker, Buffer_Change{type = .Insert, begin = {0, 1}, end = {0, 3}})
	changes_update_change(&tracker, Buffer_Change{type = .Insert, begin = {0, 5}, end = {0, 6}})
	// second begin maps back through the first insertion: {0,5} -> {0,3}
	testing.expect_value(t, tracker.old_pos, Coord_Buffer{0, 3})
	testing.expect_value(t, tracker.cur_pos, Coord_Buffer{0, 6})
	testing.expect_value(t, changes_get_new_coord(&tracker, {0, 4}), Coord_Buffer{0, 7})
	testing.expect_value(t, changes_get_new_coord(&tracker, {0, 9}), Coord_Buffer{0, 12})
	// tolerant mapping clamps pre-tracking coordinates to the current pos
	testing.expect_value(t, changes_get_new_coord_tolerant(&tracker, {0, 0}), Coord_Buffer{0, 6})
	testing.expect_value(t, changes_get_new_coord_tolerant(&tracker, {0, 9}), Coord_Buffer{0, 12})
}

@(test)
test_changes_relevant :: proc(t: ^testing.T) {
	tracker: Forward_Changes_Tracker
	ins := Buffer_Change{type = .Insert, begin = {0, 5}, end = {0, 8}}
	testing.expect(t, changes_relevant(&tracker, ins, {0, 5}))
	testing.expect(t, changes_relevant(&tracker, ins, {0, 9}))
	testing.expect(t, !changes_relevant(&tracker, ins, {0, 2}))
	ers := Buffer_Change{type = .Erase, begin = {0, 5}, end = {0, 8}}
	testing.expect(t, !changes_relevant(&tracker, ers, {0, 5}))
	testing.expect(t, changes_relevant(&tracker, ers, {0, 6}))
}

@(test)
test_changes_sorted_until :: proc(t: ^testing.T) {
	testing.expect_value(t, changes_forward_sorted_until(nil), 0)
	testing.expect_value(t, changes_backward_sorted_until(nil), 0)

	one := []Buffer_Change{{type = .Insert, begin = {0, 1}, end = {0, 2}}}
	testing.expect_value(t, changes_forward_sorted_until(one), 1)
	testing.expect_value(t, changes_backward_sorted_until(one), 1)

	// forward-sorted: each begin at/after the previous insert end
	fwd := []Buffer_Change{
		{type = .Insert, begin = {0, 1}, end = {0, 3}},
		{type = .Insert, begin = {0, 5}, end = {0, 6}},
	}
	testing.expect_value(t, changes_forward_sorted_until(fwd), 2)
	testing.expect_value(t, changes_backward_sorted_until(fwd), 1)

	// backward-sorted: each begin at/after the next end
	bwd := []Buffer_Change{
		{type = .Insert, begin = {0, 5}, end = {0, 6}},
		{type = .Insert, begin = {0, 1}, end = {0, 2}},
	}
	testing.expect_value(t, changes_forward_sorted_until(bwd), 1)
	testing.expect_value(t, changes_backward_sorted_until(bwd), 2)

	// erase runs compare against begin, not end
	ers := []Buffer_Change{
		{type = .Erase, begin = {0, 5}, end = {0, 9}},
		{type = .Insert, begin = {0, 3}, end = {0, 4}},
	}
	testing.expect_value(t, changes_forward_sorted_until(ers), 1)
}

// changes_make_sel builds a selection with empty captures for the tests.
changes_make_sel :: proc(anchor, cursor: Coord_Buffer) -> Selection {
	return Selection{basic = Basic_Selection{anchor = anchor, cursor = coord_buffer_and_target(cursor)}}
}

@(test)
test_changes_update_forward_insert :: proc(t: ^testing.T) {
	sels := [2]Selection{changes_make_sel({0, 0}, {0, 0}), changes_make_sel({0, 5}, {0, 7})}
	changes := []Buffer_Change{{type = .Insert, begin = {0, 1}, end = {0, 4}}}
	changes_update_forward(changes, sels[:])
	// first selection ends before the change: skipped by the lower bound
	testing.expect_value(t, sels[0].anchor, Coord_Buffer{0, 0})
	testing.expect_value(t, sels[0].cursor.coord, Coord_Buffer{0, 0})
	// second shifts by the insertion width
	testing.expect_value(t, sels[1].anchor, Coord_Buffer{0, 8})
	testing.expect_value(t, sels[1].cursor.coord, Coord_Buffer{0, 10})
}

@(test)
test_changes_update_forward_erase_and_reversed :: proc(t: ^testing.T) {
	// reversed selection: anchor is the max endpoint
	sels := [1]Selection{changes_make_sel({0, 7}, {0, 5})}
	changes := []Buffer_Change{{type = .Erase, begin = {0, 1}, end = {0, 3}}}
	changes_update_forward(changes, sels[:])
	testing.expect_value(t, sels[0].anchor, Coord_Buffer{0, 5})
	testing.expect_value(t, sels[0].cursor.coord, Coord_Buffer{0, 3})
	// cursor targets survive min/max member updates
	testing.expect_value(t, sels[0].cursor.target, Coord_Column(-1))
}

@(test)
test_changes_update_forward_change_after_selection :: proc(t: ^testing.T) {
	sels := [1]Selection{changes_make_sel({0, 0}, {0, 2})}
	changes := []Buffer_Change{{type = .Insert, begin = {0, 5}, end = {0, 8}}}
	changes_update_forward(changes, sels[:])
	testing.expect_value(t, sels[0].anchor, Coord_Buffer{0, 0})
	testing.expect_value(t, sels[0].cursor.coord, Coord_Buffer{0, 2})
}

@(test)
test_changes_update_backward :: proc(t: ^testing.T) {
	sels := [1]Selection{changes_make_sel({0, 9}, {0, 9})}
	// backward-sorted pair: latest change (at col 1) applies first
	changes := []Buffer_Change{
		{type = .Insert, begin = {0, 5}, end = {0, 6}},
		{type = .Insert, begin = {0, 1}, end = {0, 2}},
	}
	testing.expect_value(t, changes_backward_sorted_until(changes), 2)
	changes_update_backward(changes, sels[:])
	testing.expect_value(t, sels[0].anchor, Coord_Buffer{0, 11})
	testing.expect_value(t, sels[0].cursor.coord, Coord_Buffer{0, 11})
}

@(test)
test_changes_update_changes_splits_runs :: proc(t: ^testing.T) {
	// forward run covering everything
	sels_fwd := [1]Selection{changes_make_sel({0, 5}, {0, 6})}
	fwd := []Buffer_Change{
		{type = .Insert, begin = {0, 1}, end = {0, 2}},
		{type = .Insert, begin = {0, 3}, end = {0, 4}},
	}
	changes_update_changes(fwd, sels_fwd[:])
	testing.expect_value(t, sels_fwd[0].anchor, Coord_Buffer{0, 7})
	testing.expect_value(t, sels_fwd[0].cursor.coord, Coord_Buffer{0, 8})

	// backward run
	sels_bwd := [1]Selection{changes_make_sel({0, 9}, {0, 9})}
	bwd := []Buffer_Change{
		{type = .Insert, begin = {0, 5}, end = {0, 6}},
		{type = .Insert, begin = {0, 1}, end = {0, 2}},
	}
	changes_update_changes(bwd, sels_bwd[:])
	testing.expect_value(t, sels_bwd[0].anchor, Coord_Buffer{0, 11})

	// empty changes leave selections alone
	sels_empty := [1]Selection{changes_make_sel({2, 2}, {2, 3})}
	changes_update_changes(nil, sels_empty[:])
	testing.expect_value(t, sels_empty[0].anchor, Coord_Buffer{2, 2})
}

@(test)
test_changes_lower_bound_by_last :: proc(t: ^testing.T) {
	sels := [3]Selection{
		changes_make_sel({0, 0}, {0, 2}),
		changes_make_sel({0, 4}, {0, 6}),
		changes_make_sel({0, 8}, {0, 9}),
	}
	testing.expect_value(t, changes_lower_bound_by_last(sels[:], {0, 0}), 0)
	testing.expect_value(t, changes_lower_bound_by_last(sels[:], {0, 3}), 1)
	testing.expect_value(t, changes_lower_bound_by_last(sels[:], {0, 6}), 1)
	testing.expect_value(t, changes_lower_bound_by_last(sels[:], {0, 7}), 2)
	testing.expect_value(t, changes_lower_bound_by_last(sels[:], {1, 0}), 3)
}
