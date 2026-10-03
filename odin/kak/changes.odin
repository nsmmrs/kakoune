// Port of Kakoune's src/changes.hh and src/changes.cc.
//
// ForwardChangesTracker maps old coordinates to new ones across a run of
// buffer changes, and the update_* procs shift selections through them.
//
// Mapping notes:
//   * The C++ templates (update_forward/update_backward/update_ranges over
//     any RangeContainer) are instantiated only for selections, so they are
//     ported concretely over []Selection.
//   * forward_sorted_until/backward_sorted_until return an index (the C++
//     returns a pointer into the change array).
//   * Buffer access goes through buffer_* stubs (owned by the buffer
//     module); the pure slice-based core (changes_update_changes) is
//     standalone-testable.
package kak

// Changes_Error is the changes module error enum. All current changes procs
// are infallible; this is reserved for future fallible wrappers.
Changes_Error :: enum {
	None,
}

// changes_update_change folds one change into the tracker (port of
// ForwardChangesTracker::update(const Buffer::Change&)).
changes_update_change :: proc(tracker: ^Forward_Changes_Tracker, change: Buffer_Change) {
	assert(coord_compare(change.begin, tracker.cur_pos) >= 0)

	if change.type == .Insert {
		tracker.old_pos = changes_get_old_coord(tracker, change.begin)
		tracker.cur_pos = change.end
	} else if change.type == .Erase {
		tracker.old_pos = changes_get_old_coord(tracker, change.end)
		tracker.cur_pos = change.begin
	}
}

// changes_update_buffer folds every change since timestamp into the tracker
// and advances timestamp (port of ForwardChangesTracker::update(const
// Buffer&, size_t&)).
changes_update_buffer :: proc(tracker: ^Forward_Changes_Tracker, buffer: ^Buffer, timestamp: ^int) {
	for change in buffer_changes_since(buffer, timestamp^) {
		changes_update_change(tracker, change)
	}
	timestamp^ = buffer_timestamp(buffer)
}

// changes_get_old_coord maps a current coordinate back to the coordinate it
// had when tracking started (port of get_old_coord).
changes_get_old_coord :: proc(tracker: ^Forward_Changes_Tracker, coord: Coord_Buffer) -> Coord_Buffer {
	assert(coord_compare(tracker.cur_pos, coord) <= 0)
	res := coord
	pos_change := coord_sub(tracker.cur_pos, tracker.old_pos)
	if tracker.cur_pos.line == res.line {
		assert(pos_change.column <= res.column)
		res.column -= pos_change.column
	}
	res.line -= pos_change.line
	assert(coord_compare(tracker.old_pos, res) <= 0)
	return res
}

// changes_get_new_coord maps a start coordinate to its current position
// (port of get_new_coord).
changes_get_new_coord :: proc(tracker: ^Forward_Changes_Tracker, coord: Coord_Buffer) -> Coord_Buffer {
	assert(coord_compare(tracker.old_pos, coord) <= 0)
	res := coord
	pos_change := coord_sub(tracker.cur_pos, tracker.old_pos)
	if tracker.old_pos.line == res.line {
		assert(-pos_change.column <= res.column)
		res.column += pos_change.column
	}
	res.line += pos_change.line
	assert(coord_compare(tracker.cur_pos, res) <= 0)
	return res
}

// changes_get_new_coord_tolerant is get_new_coord, clamping coordinates
// before tracking started to the current position (port of
// get_new_coord_tolerant).
changes_get_new_coord_tolerant :: proc(tracker: ^Forward_Changes_Tracker, coord: Coord_Buffer) -> Coord_Buffer {
	if coord_compare(coord, tracker.old_pos) < 0 {
		return tracker.cur_pos
	}
	return changes_get_new_coord(tracker, coord)
}

// changes_relevant reports whether change still needs folding before pos is
// mapped (port of ForwardChangesTracker::relevant).
changes_relevant :: proc(tracker: ^Forward_Changes_Tracker, change: Buffer_Change, old_coord: Coord_Buffer) -> bool {
	new_coord := changes_get_new_coord_tolerant(tracker, old_coord)
	if change.type == .Insert {
		return coord_compare(change.begin, new_coord) <= 0
	}
	return coord_compare(change.begin, new_coord) < 0
}

// changes_forward_sorted_until returns the end index of the leading run of
// changes sorted for forward application (port of forward_sorted_until).
changes_forward_sorted_until :: proc(changes: []Buffer_Change) -> int {
	if len(changes) != 0 {
		for i := 1; i < len(changes); i += 1 {
			first := changes[i - 1]
			ref := first.begin
			if first.type == .Insert {
				ref = first.end
			}
			if coord_compare(changes[i].begin, ref) < 0 {
				return i
			}
		}
	}
	return len(changes)
}

// changes_backward_sorted_until returns the end index of the leading run of
// changes sorted for backward application (port of backward_sorted_until).
changes_backward_sorted_until :: proc(changes: []Buffer_Change) -> int {
	if len(changes) != 0 {
		for i := 1; i < len(changes); i += 1 {
			if coord_compare(changes[i - 1].begin, changes[i].end) < 0 {
				return i
			}
		}
	}
	return len(changes)
}

// changes_update_forward shifts selections through forward-sorted changes
// (port of update_forward for selections). Selections before the first
// touched one are skipped, as in the C++ lower_bound.
changes_update_forward :: proc(changes: []Buffer_Change, sels: []Selection) {
	if len(changes) == 0 || len(sels) == 0 {
		return
	}
	tracker: Forward_Changes_Tracker
	change_idx := 0
	start := changes_lower_bound_by_last(sels, changes[0].begin)
	for i := start; i < len(sels); i += 1 {
		first := selection_first(&sels[i])
		last := selection_last(&sels[i])
		last_orig := last^
		for change_idx < len(changes) && changes_relevant(&tracker, changes[change_idx], first^) {
			changes_update_change(&tracker, changes[change_idx])
			change_idx += 1
		}
		first^ = changes_get_new_coord_tolerant(&tracker, first^)
		if coord_compare(last_orig, Coord_Buffer{}) < 0 {
			continue
		}
		for change_idx < len(changes) && changes_relevant(&tracker, changes[change_idx], last_orig) {
			changes_update_change(&tracker, changes[change_idx])
			change_idx += 1
		}
		last^ = changes_get_new_coord_tolerant(&tracker, last_orig)
	}
}

// changes_update_backward shifts selections through backward-sorted changes,
// applied latest-first with coordinates mapped into the current space (port
// of update_backward for selections).
changes_update_backward :: proc(changes: []Buffer_Change, sels: []Selection) {
	if len(changes) == 0 || len(sels) == 0 {
		return
	}
	tracker: Forward_Changes_Tracker
	change_idx := len(changes) - 1
	for i := 0; i < len(sels); i += 1 {
		first := selection_first(&sels[i])
		last := selection_last(&sels[i])
		last_orig := last^
		for change_idx >= 0 {
			mapped := Buffer_Change {
				type  = changes[change_idx].type,
				begin = changes_get_new_coord(&tracker, changes[change_idx].begin),
				end   = changes_get_new_coord(&tracker, changes[change_idx].end),
			}
			if !changes_relevant(&tracker, mapped, first^) {
				break
			}
			changes_update_change(&tracker, mapped)
			change_idx -= 1
		}
		first^ = changes_get_new_coord_tolerant(&tracker, first^)
		if coord_compare(last_orig, Coord_Buffer{}) < 0 {
			continue
		}
		for change_idx >= 0 {
			mapped := Buffer_Change {
				type  = changes[change_idx].type,
				begin = changes_get_new_coord(&tracker, changes[change_idx].begin),
				end   = changes_get_new_coord(&tracker, changes[change_idx].end),
			}
			if !changes_relevant(&tracker, mapped, last_orig) {
				break
			}
			changes_update_change(&tracker, mapped)
			change_idx -= 1
		}
		last^ = changes_get_new_coord_tolerant(&tracker, last_orig)
	}
}

// changes_update_changes shifts selections through a raw change list,
// splitting it into forward/backward runs (the buffer-free core shared by
// changes_update_ranges and selection_update_selections).
changes_update_changes :: proc(changes: []Buffer_Change, sels: []Selection) {
	i := 0
	for i < len(changes) {
		rest := changes[i:]
		forward_end := changes_forward_sorted_until(rest)
		backward_end := changes_backward_sorted_until(rest)
		if forward_end >= backward_end {
			changes_update_forward(rest[:forward_end], sels)
			i += forward_end
		} else {
			changes_update_backward(rest[:backward_end], sels)
			i += backward_end
		}
	}
}

// changes_update_ranges shifts selections from timestamp to the buffer's
// current state (port of update_ranges for selections).
changes_update_ranges :: proc(buffer: ^Buffer, timestamp: int, sels: []Selection) {
	if timestamp == buffer_timestamp(buffer) {
		return
	}
	changes_update_changes(buffer_changes_since(buffer, timestamp), sels)
}

// changes_lower_bound_by_last is the selection.cc lower_bound: the first
// index whose max is at or after pos (binary search, like std::lower_bound).
changes_lower_bound_by_last :: proc(sels: []Selection, pos: Coord_Buffer) -> int {
	first := 0
	count := len(sels)
	for count > 0 {
		step := count / 2
		mid := first + step
		if coord_compare(selection_basic_max(sels[mid].basic), pos) < 0 {
			first = mid + 1
			count -= step + 1
		} else {
			count = step
		}
	}
	return first
}

// --- Buffer stubs (owned by the buffer module; STUB protocol) ---

