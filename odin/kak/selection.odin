// Port of Kakoune's src/selection.hh and src/selection.cc.
//
// Selections are (anchor, cursor) pairs over a Buffer; Selection_List owns a
// sorted vector of them plus the buffer timestamp they are valid for.
//
// Mapping notes:
//   * Basic_Selection/Selection/Selection_List live in knot.odin. A
//     Selection owns its captures strings (allocated with the list
//     allocator); every proc that drops or moves selections frees or
//     transfers them, matching the C++ Vector move/destroy behavior.
//   * C++ BufferCoordAndTarget implicitly converts from BufferCoord with
//     targets reset to -1. Every assignment of a BufferCoord to a cursor
//     (coord_buffer_and_target) resets targets; assignment through
//     selection_first/selection_last (the C++ min()/max() BufferCoord&)
//     preserves them.
//   * check_invariant is KAK_DEBUG-only in C++ (empty in release), so the
//     Odin port is a no-op. kak_assert is likewise KAK_DEBUG-only: pure
//     ones (bounds, preconditions) become assert(), while asserts calling
//     into buffer code are omitted for release parity.
//   * Buffer and buffer_utils access goes through buffer_* stubs (owned by
//     those modules); the Byte-column string conversions only touch the
//     buffer in their Codepoint/DisplayColumn branches.
package kak

import "core:slice"
import "core:strings"

// selection_MAX_COLUMN is the largest representable column (port of C++
// max_column, INT_MAX on the C++ side).
selection_MAX_COLUMN :: Coord_Column(2147483647)

// selection_MAX_NON_EOL_COLUMN is the largest non-end-of-line column.
selection_MAX_NON_EOL_COLUMN :: Coord_Column(2147483646)

// Selection_Error is the selection module error enum (the C++ throws
// runtime_error for all of these).
Selection_Error :: enum {
	None,
	Invalid_Format, // not "<line>.<col>,<line>.<col>" (or not numbers)
	Invalid_Coordinate, // negative or not present in the buffer
	Invalid_Timestamp, // timestamp newer than the buffer (or stale non-Byte)
	Empty_Description, // empty selection description list
	Invalid_Main_Index, // main index out of range
	Format_Failed, // internal formatting failure
}

// selection_min_is_anchor reports whether the anchor is the min endpoint
// (anchor <= cursor, the single-char case counting anchor as min).
selection_min_is_anchor :: proc(sel: Basic_Selection) -> bool {
	return coord_compare(sel.anchor, sel.cursor.coord) <= 0
}

// selection_basic_min returns the min endpoint (port of BasicSelection::min).
selection_basic_min :: proc(sel: Basic_Selection) -> Coord_Buffer {
	if selection_min_is_anchor(sel) {
		return sel.anchor
	}
	return sel.cursor.coord
}

// selection_basic_max returns the max endpoint (port of BasicSelection::max).
selection_basic_max :: proc(sel: Basic_Selection) -> Coord_Buffer {
	if selection_min_is_anchor(sel) {
		return sel.cursor.coord
	}
	return sel.anchor
}

// selection_first returns a pointer to the min endpoint member (port of the
// free get_first overloading sel.min()): assignment through it preserves
// cursor targets.
selection_first :: proc(sel: ^Selection) -> ^Coord_Buffer {
	if selection_min_is_anchor(sel.basic) {
		return &sel.anchor
	}
	return &sel.cursor.coord
}

// selection_last returns a pointer to the max endpoint member (port of
// get_last overloading sel.max()).
selection_last :: proc(sel: ^Selection) -> ^Coord_Buffer {
	if selection_min_is_anchor(sel.basic) {
		return &sel.cursor.coord
	}
	return &sel.anchor
}

// selection_overlaps reports whether two selections share any character
// (port of overlaps).
selection_overlaps :: proc(lhs, rhs: Basic_Selection) -> bool {
	lmin := selection_basic_min(lhs)
	lmax := selection_basic_max(lhs)
	rmin := selection_basic_min(rhs)
	rmax := selection_basic_max(rhs)
	if coord_compare(lmin, rmin) <= 0 {
		return coord_compare(lmax, rmin) >= 0
	}
	return coord_compare(lmin, rmax) <= 0
}

// selection_compare orders selections by (min, max) (port of
// compare_selections).
selection_compare :: proc(lhs, rhs: Selection) -> bool {
	lmin := selection_basic_min(lhs.basic)
	rmin := selection_basic_min(rhs.basic)
	if lmin == rmin {
		return coord_compare(selection_basic_max(lhs.basic), selection_basic_max(rhs.basic)) < 0
	}
	return coord_compare(lmin, rmin) < 0
}

// selection_update_insert shifts coord past an insertion of [begin, end)
// (port of the file-static update_insert).
selection_update_insert :: proc(coord, begin, end: Coord_Buffer) -> Coord_Buffer {
	res := coord
	if coord_compare(res, begin) < 0 {
		return res
	}
	if begin.line == res.line {
		res.column += end.column - begin.column
	}
	res.line += end.line - begin.line
	assert(res.line >= 0 && res.column >= 0)
	return res
}

// selection_any_overlaps reports whether any adjacent pair overlaps (the
// input is expected sorted, as in the C++).
selection_any_overlaps :: proc(sels: []Selection) -> bool {
	for i := 0; i + 1 < len(sels); i += 1 {
		if selection_overlaps(sels[i].basic, sels[i + 1].basic) {
			return true
		}
	}
	return false
}

// Selection_Overlap_Fn decides whether two selections merge. ctx is
// caller-owned (nil for plain overlaps, a buffer or context struct for the
// touching variants).
Selection_Overlap_Fn :: #type proc(a, b: Selection, ctx: rawptr) -> bool

// selection_overlaps_fn adapts selection_overlaps to Selection_Overlap_Fn.
selection_overlaps_fn :: proc(a, b: Selection, ctx: rawptr) -> bool {
	return selection_overlaps(a.basic, b.basic)
}

// selection_merge_overlapping_if merges runs of overlapping selections in
// place and compacts the array, adjusting main (port of the file-static
// merge_overlapping template). Selections must be sorted. The allocator must
// be the one owning the selections' captures.
selection_merge_overlapping_if :: proc(
	selections: ^[dynamic]Selection,
	main: ^int,
	overlaps_fn: Selection_Overlap_Fn,
	ctx: rawptr,
	allocator := context.allocator,
) {
	if len(selections) == 0 {
		return
	}
	i := 0
	for j := 1; j < len(selections); j += 1 {
		if overlaps_fn(selections[i], selections[j], ctx) {
			first := selection_first(&selections[i])
			last := selection_last(&selections[i])
			jmin := selection_basic_min(selections[j].basic)
			jmax := selection_basic_max(selections[j].basic)
			if coord_compare(jmin, first^) < 0 {
				first^ = jmin
			}
			if coord_compare(jmax, last^) > 0 {
				last^ = jmax
			}
			selection_destroy(&selections[j], allocator)
			if i < main^ {
				main^ -= 1
			}
		} else if i + 1 != j {
			i += 1
			selection_destroy(&selections[i], allocator)
			selections[i] = selections[j]
			selections[j].captures = nil
		} else {
			i += 1
		}
	}
	for k := i + 1; k < len(selections); k += 1 {
		selection_destroy(&selections[k], allocator)
	}
	resize(selections, i + 1)
}

// selection_merge_overlapping merges overlapping selections (port of
// merge_overlapping_selections).
selection_merge_overlapping :: proc(selections: ^[dynamic]Selection, main: ^int, allocator := context.allocator) {
	if len(selections) == 1 {
		return
	}
	selection_merge_overlapping_if(selections, main, selection_overlaps_fn, nil, allocator)
}

// selection_sort sorts selections and recomputes the main index (port of
// sort_selections).
selection_sort :: proc(selections: ^[dynamic]Selection, main: ^int) {
	if len(selections) <= 1 {
		return
	}
	old_main := main^
	main_begin := selection_basic_min(selections[old_main].basic)
	count := 0
	for i := 0; i < len(selections); i += 1 {
		begin := selection_basic_min(selections[i].basic)
		if begin == main_begin {
			if i < old_main {
				count += 1
			}
		} else if coord_compare(begin, main_begin) < 0 {
			count += 1
		}
	}
	main^ = count
	slice.stable_sort_by(selections[:], selection_compare)
}

// selection_inplace_merge stably merges the sorted runs [0, mid) and
// [mid, len) (port of the std::inplace_merge use in
// compute_modified_ranges).
selection_inplace_merge :: proc(selections: ^[dynamic]Selection, mid: int, allocator := context.allocator) {
	tmp := make([dynamic]Selection, 0, len(selections), allocator)
	defer delete(tmp)
	for s in selections {
		append(&tmp, s)
	}
	i := 0
	j := mid
	k := 0
	for i < mid && j < len(tmp) {
		if selection_compare(tmp[j], tmp[i]) {
			selections[k] = tmp[j]
			j += 1
		} else {
			selections[k] = tmp[i]
			i += 1
		}
		k += 1
	}
	for i < mid {
		selections[k] = tmp[i]
		i += 1
		k += 1
	}
	for j < len(tmp) {
		selections[k] = tmp[j]
		j += 1
		k += 1
	}
}

// selection_clone deep-copies a selection, duplicating its captures strings.
selection_clone :: proc(sel: Selection, allocator := context.allocator) -> Selection {
	res := Selection {
		basic    = sel.basic,
		captures = make([dynamic]string, 0, len(sel.captures), allocator),
	}
	for c in sel.captures {
		append(&res.captures, strings.clone(c, allocator))
	}
	return res
}

// selection_destroy frees a selection's captures. The allocator must be the
// one the captures were cloned with.
selection_destroy :: proc(sel: ^Selection, allocator := context.allocator) {
	for c in sel.captures {
		delete(c, allocator)
	}
	delete(sel.captures)
	sel.captures = nil
}

// selection_clamp_selections clamps every selection into the buffer (port of
// clamp_selections). Cursor targets reset to -1, as in the C++.
selection_clamp_selections :: proc(selections: []Selection, buffer: ^Buffer) {
	for &sel in selections {
		sel.anchor = buffer_clamp(buffer, sel.anchor)
		sel.cursor = coord_buffer_and_target(buffer_clamp(buffer, sel.cursor.coord))
	}
}

// selection_update_selections refreshes selections from timestamp to the
// buffer's current state, clamping and optionally merging them (port of
// update_selections). The allocator must own the selections' captures.
selection_update_selections :: proc(
	selections: ^[dynamic]Selection,
	main: ^int,
	buffer: ^Buffer,
	timestamp: int,
	merge := true,
	allocator := context.allocator,
) {
	if timestamp == buffer_timestamp(buffer) {
		return
	}
	changes_update_changes(buffer_changes_since(buffer, timestamp), selections[:])
	selection_clamp_selections(selections[:], buffer)
	if merge {
		selection_merge_overlapping_if(selections, main, selection_overlaps_fn, nil, allocator)
	}
}

// Selection_Touches_Ctx is the context for selection_touches_fn.
Selection_Touches_Ctx :: struct {
	buffer:    ^Buffer,
	end_coord: Coord_Buffer,
}

// selection_touches_fn merges selections that touch (or reach end of
// buffer), for compute_modified_ranges.
selection_touches_fn :: proc(a, b: Selection, ctx: rawptr) -> bool {
	c := (^Selection_Touches_Ctx)(ctx)
	amax := selection_basic_max(a.basic)
	return amax == c.end_coord || coord_compare(buffer_char_next(c.buffer, amax), selection_basic_min(b.basic)) >= 0
}

// selection_touches_consecutive_fn merges consecutive selections (separated
// by at most the caret step), for merge_consecutive. ctx is the ^Buffer.
selection_touches_consecutive_fn :: proc(a, b: Selection, ctx: rawptr) -> bool {
	buffer := cast(^Buffer)ctx
	return coord_compare(
		buffer_char_next(buffer, selection_basic_max(a.basic)),
		selection_basic_min(b.basic),
	) >= 0
}

// selection_compute_modified_ranges returns the selection set covering every
// change since timestamp (port of compute_modified_ranges). Caller owns the
// result (allocated with allocator).
selection_compute_modified_ranges :: proc(buffer: ^Buffer, timestamp: int, allocator := context.allocator) -> [dynamic]Selection {
	ranges := make([dynamic]Selection, 0, allocator)
	changes := buffer_changes_since(buffer, timestamp)
	i := 0
	for i < len(changes) {
		rest := changes[i:]
		forward_end := changes_forward_sorted_until(rest)
		backward_end := changes_backward_sorted_until(rest)
		dummy := 0
		prev_size := 0
		if forward_end >= backward_end {
			changes_update_forward(rest[:forward_end], ranges[:])
			selection_merge_overlapping_if(&ranges, &dummy, selection_overlaps_fn, nil, allocator)
			prev_size = len(ranges)
			tracker: Forward_Changes_Tracker
			for c in rest[:forward_end] {
				if c.type == .Insert {
					append(
						&ranges,
						Selection{basic = Basic_Selection{anchor = c.begin, cursor = coord_buffer_and_target(c.end)}},
					)
				} else {
					append(
						&ranges,
						Selection{basic = Basic_Selection{anchor = c.begin, cursor = coord_buffer_and_target(c.begin)}},
					)
				}
				changes_update_change(&tracker, c)
			}
			i += forward_end
		} else {
			changes_update_backward(rest[:backward_end], ranges[:])
			selection_merge_overlapping_if(&ranges, &dummy, selection_overlaps_fn, nil, allocator)
			prev_size = len(ranges)
			tracker: Forward_Changes_Tracker
			for k := backward_end - 1; k >= 0; k -= 1 {
				ch := rest[k]
				ch.begin = changes_get_new_coord(&tracker, ch.begin)
				ch.end = changes_get_new_coord(&tracker, ch.end)
				if ch.type == .Insert {
					append(
						&ranges,
						Selection{basic = Basic_Selection{anchor = ch.begin, cursor = coord_buffer_and_target(ch.end)}},
					)
				} else {
					append(
						&ranges,
						Selection{basic = Basic_Selection{anchor = ch.begin, cursor = coord_buffer_and_target(ch.begin)}},
					)
				}
				changes_update_change(&tracker, ch)
			}
			i += backward_end
		}
		selection_inplace_merge(&ranges, prev_size, context.temp_allocator)
		selection_merge_overlapping_if(&ranges, &dummy, selection_overlaps_fn, nil, allocator)
	}

	end_coord := buffer_end_coord(buffer)
	for &range in ranges {
		if coord_compare(end_coord, range.anchor) < 0 {
			range.anchor = end_coord
		}
		if cursor_coord, end := range.cursor.coord, end_coord; coord_compare(end, cursor_coord) < 0 {
			range.cursor = coord_buffer_and_target(end)
		}
	}

	touches_ctx := Selection_Touches_Ctx{buffer = buffer, end_coord = end_coord}
	dummy := 0
	selection_merge_overlapping_if(&ranges, &dummy, selection_touches_fn, &touches_ctx, allocator)

	for &sel in ranges {
		// (KAK_DEBUG-only is_valid asserts omitted: release parity.)
		if buffer_is_end(buffer, sel.anchor) {
			sel.anchor = buffer_back_coord(buffer)
		}
		if buffer_is_end(buffer, sel.cursor.coord) {
			sel.cursor = coord_buffer_and_target(buffer_back_coord(buffer))
		}
		if sel.anchor != sel.cursor.coord {
			sel.cursor = coord_buffer_and_target(buffer_char_prev(buffer, sel.cursor.coord))
		}
	}
	return ranges
}

// selection_replace replaces sel with content and selects the inserted text
// (port of the free replace).
selection_replace :: proc(buffer: ^Buffer, sel: ^Selection, content: string) -> Buffer_Error {
	first := selection_first(sel)
	last := selection_last(sel)
	min_val := first^
	max_val := last^
	range, err := buffer_replace(buffer, min_val, buffer_char_next(buffer, max_val), content)
	if err != .None {
		return err
	}
	first^ = range.begin
	if coord_compare(range.end, range.begin) > 0 {
		last^ = buffer_char_prev(buffer, range.end)
	} else {
		last^ = range.begin
	}
	return .None
}

// selection_insert inserts content at pos and shifts sel past it (port of
// the free insert). Cursor targets reset to -1, as in the C++.
selection_insert :: proc(buffer: ^Buffer, sel: ^Selection, pos: Coord_Buffer, content: string) -> (Buffer_Range, Buffer_Error) {
	range, err := buffer_insert(buffer, pos, content)
	if err != .None {
		return {}, err
	}
	sel.anchor = buffer_clamp(buffer, selection_update_insert(sel.anchor, range.begin, range.end))
	sel.cursor = coord_buffer_and_target(buffer_clamp(buffer, selection_update_insert(sel.cursor.coord, range.begin, range.end)))
	return range, .None
}

// selection_fix_overflowing_selections pulls selections pushed past the end
// back into the buffer (port of the file-static fix_overflowing_selections).
// Cursor targets reset to -1, as in the C++.
selection_fix_overflowing_selections :: proc(selections: []Selection, buffer: ^Buffer) {
	back_coord := buffer_back_coord(buffer)
	for &sel in selections {
		clamped_cursor := buffer_clamp(buffer, sel.cursor.coord)
		sel.cursor = coord_buffer_and_target(
			coord_compare(clamped_cursor, back_coord) < 0 ? clamped_cursor : back_coord,
		)
		clamped_anchor := buffer_clamp(buffer, sel.anchor)
		sel.anchor = coord_compare(clamped_anchor, back_coord) < 0 ? clamped_anchor : back_coord
	}
}

// selection_list_make builds a list owning deep copies of sels (port of the
// SelectionList ctors; the C++ default timestamp is buffer.timestamp(), the
// caller passes it explicitly here). Main is the last selection.
selection_list_make :: proc(
	buffer: ^Buffer,
	sels: []Selection,
	timestamp: int,
	allocator := context.allocator,
) -> Selection_List {
	assert(len(sels) > 0)
	res := Selection_List {
		main       = len(sels) - 1,
		selections = make([dynamic]Selection, 0, len(sels), allocator),
		buffer     = buffer,
		timestamp  = timestamp,
		allocator  = allocator,
	}
	for s in sels {
		append(&res.selections, selection_clone(s, allocator))
	}
	return res
}

// selection_list_make_single builds a single-selection list (port of the
// SelectionList(Buffer&, Selection) ctors).
selection_list_make_single :: proc(
	buffer: ^Buffer,
	sel: Selection,
	timestamp: int,
	allocator := context.allocator,
) -> Selection_List {
	sels := [1]Selection{sel}
	return selection_list_make(buffer, sels[:], timestamp, allocator)
}

// selection_list_destroy frees the list and its selections' captures.
selection_list_destroy :: proc(list: ^Selection_List) {
	for &sel in list.selections {
		selection_destroy(&sel, list.allocator)
	}
	delete(list.selections)
	list.selections = nil
}

// selection_list_clone deep-copies a list (port of the copy ctor/assign).
selection_list_clone :: proc(list: ^Selection_List, allocator := context.allocator) -> Selection_List {
	res := selection_list_make(list.buffer, list.selections[:], list.timestamp, allocator)
	res.main = list.main
	return res
}

// selection_list_main returns the main selection (port of SelectionList::main).
selection_list_main :: proc(list: ^Selection_List) -> ^Selection {
	return &list.selections[list.main]
}

// selection_list_main_index returns the main selection index.
selection_list_main_index :: proc(list: ^Selection_List) -> int {
	return list.main
}

// selection_list_set_main_index sets the main selection index.
selection_list_set_main_index :: proc(list: ^Selection_List, main: int) {
	assert(main < len(list.selections))
	list.main = main
}

// selection_list_buffer returns the list's buffer.
selection_list_buffer :: proc(list: ^Selection_List) -> ^Buffer {
	return list.buffer
}

// selection_list_timestamp returns the timestamp the selections are valid for.
selection_list_timestamp :: proc(list: ^Selection_List) -> int {
	return list.timestamp
}

// selection_list_force_timestamp overwrites the timestamp without updating.
selection_list_force_timestamp :: proc(list: ^Selection_List, timestamp: int) {
	list.timestamp = timestamp
}

// selection_list_push_back appends a copy of sel (port of push_back).
selection_list_push_back :: proc(list: ^Selection_List, sel: Selection) {
	append(&list.selections, selection_clone(sel, list.allocator))
}

// selection_list_set replaces the contents with copies of sels and sorts
// (port of SelectionList::set).
selection_list_set :: proc(list: ^Selection_List, sels: []Selection, main: int) {
	assert(main < len(sels))
	for &sel in list.selections {
		selection_destroy(&sel, list.allocator)
	}
	clear(&list.selections)
	for s in sels {
		append(&list.selections, selection_clone(s, list.allocator))
	}
	list.main = main
	list.timestamp = buffer_timestamp(list.buffer)
	selection_list_sort(list)
}

// selection_list_assign replaces the contents, making the last selection
// main (port of operator=(Vector<Selection>)).
selection_list_assign :: proc(list: ^Selection_List, sels: []Selection) {
	assert(len(sels) > 0)
	selection_list_set(list, sels, len(sels) - 1)
}

// selection_list_remove drops the selection at index (port of remove).
selection_list_remove :: proc(list: ^Selection_List, index: int) {
	assert(index < len(list.selections))
	selection_destroy(&list.selections[index], list.allocator)
	ordered_remove(&list.selections, index)
	if index < list.main || list.main == len(list.selections) {
		list.main -= 1
	}
}

// selection_list_remove_from drops all selections at and after index (port
// of remove_from).
selection_list_remove_from :: proc(list: ^Selection_List, index: int) {
	assert(index > 0)
	for i := index; i < len(list.selections); i += 1 {
		selection_destroy(&list.selections[i], list.allocator)
	}
	resize(&list.selections, index)
	if index <= list.main {
		list.main = len(list.selections) - 1
	}
}

// selection_list_update refreshes the list to the buffer's current state
// (port of SelectionList::update).
selection_list_update :: proc(list: ^Selection_List, merge := true) {
	selection_update_selections(&list.selections, &list.main, list.buffer, list.timestamp, merge, list.allocator)
	selection_list_check_invariant(list)
	list.timestamp = buffer_timestamp(list.buffer)
}

// selection_list_check_invariant is a no-op: the C++ is KAK_DEBUG-only and
// empty in release builds.
selection_list_check_invariant :: proc(list: ^Selection_List) {
}

// selection_list_sort sorts the list (port of SelectionList::sort).
selection_list_sort :: proc(list: ^Selection_List) {
	selection_sort(&list.selections, &list.main)
}

// selection_list_merge_overlapping merges overlapping selections (port of
// SelectionList::merge_overlapping).
selection_list_merge_overlapping :: proc(list: ^Selection_List) {
	selection_merge_overlapping(&list.selections, &list.main, list.allocator)
}

// selection_list_merge_consecutive merges selections separated by at most
// the caret step (port of SelectionList::merge_consecutive).
selection_list_merge_consecutive :: proc(list: ^Selection_List) {
	if len(list.selections) == 1 {
		return
	}
	selection_merge_overlapping_if(
		&list.selections,
		&list.main,
		selection_touches_consecutive_fn,
		list.buffer,
		list.allocator,
	)
}

// selection_list_sort_and_merge_overlapping sorts then merges (port of
// SelectionList::sort_and_merge_overlapping).
selection_list_sort_and_merge_overlapping :: proc(list: ^Selection_List) {
	selection_list_sort(list)
	selection_list_merge_overlapping(list)
}

// Selection_For_Each_Apply is applied to each selection by
// selection_list_for_each (port of SelectionList::ApplyFunc); data is
// caller-owned context.
Selection_For_Each_Apply :: #type proc(data: rawptr, index: int, sel: ^Selection) -> Buffer_Error

// selection_list_for_each updates the list then applies apply to each
// selection, keeping coordinates valid across buffer mutations (port of
// SelectionList::for_each).
selection_list_for_each :: proc(list: ^Selection_List, apply: Selection_For_Each_Apply, data: rawptr, may_append: bool) -> Buffer_Error {
	selection_list_update(list)

	if may_append && selection_any_overlaps(list.selections[:]) {
		timestamp := buffer_timestamp(list.buffer)
		for i := 0; i < len(list.selections); i += 1 {
			changes_update_ranges(list.buffer, timestamp, list.selections[i:i + 1])
			if err := apply(data, i, &list.selections[i]); err != .None {
				return err
			}
		}
	} else {
		tracker: Forward_Changes_Tracker
		for i := 0; i < len(list.selections); i += 1 {
			sel := &list.selections[i]
			sel.anchor = changes_get_new_coord_tolerant(&tracker, sel.anchor)
			sel.cursor = coord_buffer_and_target(changes_get_new_coord_tolerant(&tracker, sel.cursor.coord))
			// (KAK_DEBUG-only is_valid asserts omitted: release parity.)

			if err := apply(data, i, sel); err != .None {
				return err
			}

			changes_update_buffer(&tracker, list.buffer, &list.timestamp)
		}
	}

	selection_fix_overflowing_selections(list.selections[:], list.buffer)
	selection_list_check_invariant(list)
	return .None
}

// Selection_Replace_Ctx is the context for selection_replace_apply.
Selection_Replace_Ctx :: struct {
	strings: []string,
	buffer:  ^Buffer,
}

// selection_replace_apply replaces one selection with its string (last
// string reused for extra selections).
selection_replace_apply :: proc(data: rawptr, index: int, sel: ^Selection) -> Buffer_Error {
	ctx := (^Selection_Replace_Ctx)(data)
	return selection_replace(ctx.buffer, sel, ctx.strings[min(len(ctx.strings) - 1, index)])
}

// selection_list_replace_strings replaces each selection with the matching
// string (port of SelectionList::replace).
selection_list_replace_strings :: proc(list: ^Selection_List, strings_list: []string) -> Buffer_Error {
	if len(strings_list) == 0 {
		return .None
	}
	ctx := Selection_Replace_Ctx{strings = strings_list, buffer = list.buffer}
	return selection_list_for_each(list, selection_replace_apply, &ctx, false)
}

// selection_list_erase erases every selection's content (port of
// SelectionList::erase).
selection_list_erase :: proc(list: ^Selection_List) -> Buffer_Error {
	selection_list_update(list)
	selection_list_merge_overlapping(list)

	tracker: Forward_Changes_Tracker
	for &sel in list.selections {
		sel.anchor = changes_get_new_coord(&tracker, sel.anchor)
		sel.cursor = coord_buffer_and_target(changes_get_new_coord(&tracker, sel.cursor.coord))

		// Port of buffer_utils::erase(buffer, sel).
		min_val := selection_basic_min(sel.basic)
		max_val := selection_basic_max(sel.basic)
		pos, err := buffer_erase(list.buffer, min_val, buffer_char_next(list.buffer, max_val))
		if err != .None {
			return err
		}
		sel.anchor = pos
		sel.cursor = coord_buffer_and_target(pos)
		changes_update_buffer(&tracker, list.buffer, &list.timestamp)
	}

	selection_fix_overflowing_selections(list.selections[:], list.buffer)
	return .None
}

// selection_char_count_to counts the characters of line before byte_col
// (port of String::char_count_to).
selection_char_count_to :: proc(line: string, byte_col: int) -> int {
	return utf8_distance(line[:clamp(byte_col, 0, len(line))])
}

// selection_byte_count_to returns the byte offset of char_col in line (port
// of String::byte_count_to(CharCount)).
selection_byte_count_to :: proc(line: string, char_col: int) -> int {
	return utf8_advance(line, 0, char_col)
}

// selection_to_string formats a selection as "<line>.<col>,<line>.<col>"
// (1-based, port of selection_to_string). Caller owns the result.
selection_to_string :: proc(
	column_type: Column_Type,
	buffer: ^Buffer,
	selection: Selection,
	tabstop: Coord_Column = -1,
	allocator := context.allocator,
) -> (
	string,
	Selection_Error,
) {
	anchor_line, anchor_col, cursor_line, cursor_col: int
	switch column_type {
	case .Byte:
		anchor_line = int(selection.anchor.line) + 1
		anchor_col = int(selection.anchor.column) + 1
		cursor_line = int(selection.cursor.line) + 1
		cursor_col = int(selection.cursor.column) + 1
	case .Codepoint:
		anchor_line_text := buffer_line(buffer, selection.anchor.line)
		cursor_line_text := buffer_line(buffer, selection.cursor.line)
		anchor_line = int(selection.anchor.line) + 1
		anchor_col = selection_char_count_to(anchor_line_text, int(selection.anchor.column)) + 1
		cursor_line = int(selection.cursor.line) + 1
		cursor_col = selection_char_count_to(cursor_line_text, int(selection.cursor.column)) + 1
	case .Display_Column:
		assert(tabstop != -1)
		anchor_line = int(selection.anchor.line) + 1
		anchor_col = int(buffer_utils_get_column(buffer, tabstop, selection.anchor)) + 1
		cursor_line = int(selection.cursor.line) + 1
		cursor_col = int(buffer_utils_get_column(buffer, tabstop, selection.cursor.coord)) + 1
	}
	params := [4]string{
		format_to_string_int(anchor_line, context.temp_allocator),
		format_to_string_int(anchor_col, context.temp_allocator),
		format_to_string_int(cursor_line, context.temp_allocator),
		format_to_string_int(cursor_col, context.temp_allocator),
	}
	res, err := format_format("{}.{},{}.{}", params[:], allocator)
	if err != .None {
		return "", .Format_Failed
	}
	return res, .None
}

// selection_list_to_string formats the list main-first, space-separated
// (port of selection_list_to_string). Caller owns the result.
selection_list_to_string :: proc(
	column_type: Column_Type,
	selections: ^Selection_List,
	tabstop: Coord_Column = -1,
	allocator := context.allocator,
) -> (
	string,
	Selection_Error,
) {
	// (The KAK_DEBUG-only timestamp-match assert is omitted: release
	// parity. Callers must pass an updated list, as in the C++.)
	buffer := selections.buffer

	parts := make([dynamic]string, 0, len(selections.selections), context.temp_allocator)
	main := selections.main
	for i := main; i < len(selections.selections); i += 1 {
		s, err := selection_to_string(column_type, buffer, selections.selections[i], tabstop, context.temp_allocator)
		if err != .None {
			return "", err
		}
		append(&parts, s)
	}
	for i := 0; i < main; i += 1 {
		s, err := selection_to_string(column_type, buffer, selections.selections[i], tabstop, context.temp_allocator)
		if err != .None {
			return "", err
		}
		append(&parts, s)
	}
	return string_utils_join_char(parts[:], ' ', false, allocator), .None
}

// selection_from_string parses "<line>.<col>,<line>.<col>" (1-based, port of
// selection_from_string).
selection_from_string :: proc(
	column_type: Column_Type,
	buffer: ^Buffer,
	desc: string,
	tabstop: Coord_Column = -1,
) -> (
	Selection,
	Selection_Error,
) {
	comma := strings.index_byte(desc, ',')
	if comma < 0 {
		return {}, .Invalid_Format
	}
	dot_anchor := strings.index_byte(desc[:comma], '.')
	if dot_anchor < 0 {
		return {}, .Invalid_Format
	}
	after_comma := desc[comma:]
	dot_cursor_rel := strings.index_byte(after_comma, '.')
	if dot_cursor_rel < 0 {
		return {}, .Invalid_Format
	}
	dot_cursor := comma + dot_cursor_rel

	anchor_line, err1 := string_utils_str_to_int(desc[:dot_anchor])
	anchor_col, err2 := string_utils_str_to_int(desc[dot_anchor + 1:comma])
	cursor_line, err3 := string_utils_str_to_int(desc[comma + 1:dot_cursor])
	cursor_col, err4 := string_utils_str_to_int(desc[dot_cursor + 1:])
	if err1 != .None || err2 != .None || err3 != .None || err4 != .None {
		return {}, .Invalid_Format
	}

	anchor, err := selection_coord_from_parsed(column_type, buffer, anchor_line - 1, anchor_col - 1, tabstop)
	if err != .None {
		return {}, err
	}
	cursor, cerr := selection_coord_from_parsed(column_type, buffer, cursor_line - 1, cursor_col - 1, tabstop)
	if cerr != .None {
		return {}, cerr
	}
	return Selection{basic = Basic_Selection{anchor = anchor, cursor = coord_buffer_and_target(cursor)}}, .None
}

// selection_coord_from_parsed converts a 0-based (line, column) pair to a
// buffer coordinate (port of the compute_coord lambda in
// selection_from_string).
selection_coord_from_parsed :: proc(
	column_type: Column_Type,
	buffer: ^Buffer,
	line, column: int,
	tabstop: Coord_Column,
) -> (
	Coord_Buffer,
	Selection_Error,
) {
	if line < 0 || column < 0 {
		return {}, .Invalid_Coordinate
	}
	switch column_type {
	case .Byte:
		return Coord_Buffer{Coord_Line(line), Coord_Byte(column)}, .None
	case .Codepoint:
		line_text := buffer_line(buffer, Units_LineCount(line))
		if int(buffer_line_count(buffer)) <= line || utf8_distance(line_text) <= column {
			return {}, .Invalid_Coordinate
		}
		return Coord_Buffer{Coord_Line(line), Coord_Byte(selection_byte_count_to(line_text, column))}, .None
	case .Display_Column:
		assert(tabstop != -1)
		if int(buffer_line_count(buffer)) <= line ||
		   int(buffer_utils_column_length(buffer, tabstop, Units_LineCount(line))) <= column {
			return {}, .Invalid_Coordinate
		}
		byte_col := buffer_utils_get_byte_to_column(
			buffer,
			tabstop,
			Coord_Display{Coord_Line(line), Coord_Column(column)},
		)
		return Coord_Buffer{Coord_Line(line), Coord_Byte(byte_col)}, .None
	}
	unreachable()
}

// selection_list_from_strings parses descriptions into an updated list (port
// of selection_list_from_strings). Caller owns the result (use
// selection_list_destroy).
selection_list_from_strings :: proc(
	buffer: ^Buffer,
	column_type: Column_Type,
	descs: []string,
	timestamp: int,
	main: int,
	tabstop: Coord_Column = -1,
	allocator := context.allocator,
) -> (
	Selection_List,
	Selection_Error,
) {
	if (column_type != .Byte && timestamp != buffer_timestamp(buffer)) || timestamp > buffer_timestamp(buffer) {
		return {}, .Invalid_Timestamp
	}
	sels := make([dynamic]Selection, 0, len(descs), allocator)
	for d in descs {
		sel, err := selection_from_string(column_type, buffer, d, tabstop)
		if err != .None {
			delete(sels)
			return {}, err
		}
		append(&sels, sel)
	}
	if len(sels) == 0 {
		delete(sels)
		return {}, .Empty_Description
	}
	if main >= len(sels) {
		delete(sels)
		return {}, .Invalid_Main_Index
	}

	main_idx := main
	selection_sort(&sels, &main_idx)
	selection_merge_overlapping(&sels, &main_idx, allocator)
	if timestamp < buffer_timestamp(buffer) {
		selection_update_selections(&sels, &main_idx, buffer, timestamp, true, allocator)
	} else {
		selection_clamp_selections(sels[:], buffer)
	}

	return Selection_List {
		main = main_idx,
		selections = sels,
		buffer = buffer,
		timestamp = buffer_timestamp(buffer),
		allocator = allocator,
	}, .None
}

// ---------------------------------------------------------------------------
// Remainder implementations
// ---------------------------------------------------------------------------

// scoped_selection_edition_make opens a selection edition unless the
// context is a draft or buffer-less (C++ ScopedSelectionEdition ctor in
// context.hh; the name is kept from the STUB contract). Pair with
// scoped_selection_edition_destroy.
scoped_selection_edition_make :: proc(ctx: ^Context) -> Scoped_Selection_Edition {
	return context_scoped_selection_edition_make(ctx)
}

// scoped_selection_edition_destroy closes the edition (C++
// ScopedSelectionEdition dtor).
scoped_selection_edition_destroy :: proc(e: ^Scoped_Selection_Edition) {
	context_scoped_selection_edition_destroy(e)
}

// selection_list_make_multi builds a list from sels (C++
// SelectionList(Buffer&, Vector<Selection>): main is the last selection,
// timestamp is the buffer's). Like the C++ move, this takes ownership of
// the sels array: the caller must not use or free it afterwards.
selection_list_make_multi :: proc(
	buffer: ^Buffer,
	sels: [dynamic]Selection,
	allocator := context.allocator,
) -> Selection_List {
	assert(len(sels) > 0)
	return Selection_List {
		main       = len(sels) - 1,
		selections = sels,
		buffer     = buffer,
		timestamp  = buffer_timestamp(buffer),
		allocator  = allocator,
	}
}

// --- Buffer / buffer_utils stubs (owned by those modules; STUB protocol) ---

buffer_utils_get_column :: proc(buffer: ^Buffer, tabstop: Coord_Column, coord: Coord_Buffer) -> Coord_Column {
	panic("STUB: buffer_utils_get_column")
}

buffer_utils_column_length :: proc(buffer: ^Buffer, tabstop: Coord_Column, line: Units_LineCount) -> Coord_Column {
	panic("STUB: buffer_utils_column_length")
}

buffer_utils_get_byte_to_column :: proc(
	buffer: ^Buffer,
	tabstop: Coord_Column,
	coord: Coord_Display,
) -> Units_ByteCount {
	panic("STUB: buffer_utils_get_byte_to_column")
}
