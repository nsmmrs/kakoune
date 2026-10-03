// Port of Kakoune's src/line_modification.hh and src/line_modification.cc.
//
// Tracks per-line added/removed deltas between a buffer snapshot and its
// current state (used for diff gutters), plus Line_Range_Set which shifts
// tracked ranges through those deltas.
//
// Mapping notes:
//   * C++ Vector<LineModification> -> [dynamic]Line_Modification, owned by
//     the caller of line_modification_compute (pass allocator explicitly).
//   * Line_Range_Set is the knot-owned [dynamic]Line_Range; the procs take
//     a pointer and mutate in place. Growth uses the array's allocator.
//   * std::upper_bound/lower_bound become explicit index loops; iterator
//     insert/erase become index arithmetic over the dynamic arrays.
//   * FunctionRef<void(LineRange)> -> proc(rawptr, Line_Range) + data pair.
package kak

// Line_Modification_Error is the line_modification module error enum. All
// current procs are infallible; this is reserved for future fallible wrappers.
Line_Modification_Error :: enum {
	None,
}

// line_modification_diff returns the net line shift of a modification:
// how much later lines moved (port of LineModification::diff).
line_modification_diff :: proc(m: Line_Modification) -> Units_LineCount {
	return m.new_line - m.old_line + m.num_added - m.num_removed
}

// line_modification_make folds one buffer change into a line modification
// (port of make_line_modif).
line_modification_make :: proc(change: Buffer_Change) -> Line_Modification {
	num_added, num_removed: Units_LineCount
	if change.type == .Insert {
		num_added = change.end.line - change.begin.line
	} else {
		num_removed = change.end.line - change.begin.line
	}
	// Modified a line (a change touching column content, not just a
	// whole-line insert/erase at column 0).
	if change.begin.column != 0 || change.end.column != 0 {
		num_removed += 1
		num_added += 1
	}
	return Line_Modification{change.begin.line, change.begin.line, num_removed, num_added}
}

// line_modification_upper_bound_new_line returns the first index at or after
// start whose new_line is greater than value (port of the std::upper_bound
// calls keyed on LineModification::new_line).
line_modification_upper_bound_new_line :: proc(mods: []Line_Modification, value: Units_LineCount, start := 0) -> int {
	i := start
	for i < len(mods) && mods[i].new_line <= value {
		i += 1
	}
	return i
}

// line_modification_lower_bound_old_end returns the first index whose
// old_line + num_removed is not less than value (port of the
// std::lower_bound call in LineRangeSet::update).
line_modification_lower_bound_old_end :: proc(modifs: []Line_Modification, value: Units_LineCount) -> int {
	i := 0
	for i < len(modifs) && modifs[i].old_line + modifs[i].num_removed < value {
		i += 1
	}
	return i
}

// line_modification_upper_bound_old_line returns the first index whose
// old_line is greater than value (port of the std::upper_bound call in
// LineRangeSet::update).
line_modification_upper_bound_old_line :: proc(modifs: []Line_Modification, value: Units_LineCount) -> int {
	i := 0
	for i < len(modifs) && modifs[i].old_line <= value {
		i += 1
	}
	return i
}

// line_modification_lower_bound_range_end returns the first range index
// whose end is not less than value (port of the std::lower_bound calls in
// LineRangeSet::add_range/remove_range).
line_modification_lower_bound_range_end :: proc(set: Line_Range_Set, value: Units_LineCount) -> int {
	i := 0
	for i < len(set) && set[i].end < value {
		i += 1
	}
	return i
}

// line_modification_erase_range removes elements [lo, hi) from a dynamic
// array, preserving order (port of Vector::erase(first, last)).
line_modification_erase_range :: proc(arr: ^[dynamic]$T, lo, hi: int) {
	rest := len(arr) - hi
	if rest > 0 {
		copy(arr[lo:lo + rest], arr[hi:hi + rest])
	}
	resize(arr, len(arr) - (hi - lo))
}

// line_modification_compute folds every buffer change since timestamp into
// merged line modifications, in new_line order (port of
// compute_line_modifications). The caller owns the result; free with delete.
line_modification_compute :: proc(buffer: ^Buffer, timestamp: int, allocator := context.allocator) -> [dynamic]Line_Modification {
	res := make([dynamic]Line_Modification, 0, allocator)
	for buf_change in buffer_changes_since(buffer, timestamp) {
		change := line_modification_make(buf_change)

		pos := line_modification_upper_bound_new_line(res[:], change.new_line)
		if pos > 0 {
			prev := res[pos - 1]
			if change.new_line <= prev.new_line + prev.num_added {
				pos -= 1
				removed_from_previously_added := clamp(
					res[pos].new_line + res[pos].num_added - change.new_line,
					0,
					min(res[pos].num_added, change.num_removed),
				)
				res[pos].num_removed += change.num_removed - removed_from_previously_added
				res[pos].num_added += change.num_added - removed_from_previously_added
			} else {
				change.old_line -= line_modification_diff(prev)
				inject_at(&res, pos, change)
			}
		} else {
			inject_at(&res, pos, change)
		}

		next := pos + 1
		diff := buf_change.end.line - buf_change.begin.line
		if buf_change.type == .Erase {
			delend := line_modification_upper_bound_new_line(res[:], change.new_line + change.num_removed, next)
			for it := next; it < delend; it += 1 {
				removed_from_previously_added := min(
					res[it].num_added,
					change.new_line + change.num_removed - res[it].new_line,
				)
				res[pos].num_removed += res[it].num_removed - removed_from_previously_added
				res[pos].num_added += res[it].num_added - removed_from_previously_added
			}
			line_modification_erase_range(&res, next, delend)
			if diff != 0 {
				for it := next; it < len(res); it += 1 {
					res[it].new_line -= diff
				}
			}
		} else if diff != 0 {
			for it := next; it < len(res); it += 1 {
				res[it].new_line += diff
			}
		}
	}
	return res
}

// line_modification_range_set_reset replaces the set with a single range
// (port of LineRangeSet::reset).
line_modification_range_set_reset :: proc(set: ^Line_Range_Set, r: Line_Range) {
	clear(set)
	append(set, r)
}

// line_modification_range_set_view returns the tracked ranges as a slice
// (port of LineRangeSet::view).
line_modification_range_set_view :: proc(set: ^Line_Range_Set) -> []Line_Range {
	return set[:]
}

// line_modification_range_set_update shifts every tracked range through the
// given modifications, splitting ranges around added lines and dropping
// empty ones (port of LineRangeSet::update).
line_modification_range_set_update :: proc(set: ^Line_Range_Set, modifs: []Line_Modification) {
	if len(modifs) == 0 {
		return
	}
	i := 0
	for i < len(set) {
		modif_beg := line_modification_lower_bound_old_end(modifs, set[i].begin)
		modif_end := line_modification_upper_bound_old_line(modifs, set[i].end)

		if modif_beg == len(modifs) {
			diff := line_modification_diff(modifs[modif_beg - 1])
			set[i].begin += diff
			set[i].end += diff
			i += 1
			continue
		}

		diff := modifs[modif_beg].new_line - modifs[modif_beg].old_line
		set[i].begin += diff
		set[i].end += diff

		for modif_beg < modif_end {
			m := modifs[modif_beg]
			modif_beg += 1
			if m.num_removed > 0 {
				if m.new_line < set[i].begin {
					set[i].begin = max(m.new_line, set[i].begin - m.num_removed)
				}
				set[i].end = max(m.new_line, max(set[i].begin, set[i].end - m.num_removed))
			}
			if m.num_added > 0 {
				if set[i].begin >= m.new_line {
					set[i].begin += m.num_added
				} else {
					inject_at(set, i, Line_Range{set[i].begin, m.new_line})
					i += 1
					set[i].begin = m.new_line + m.num_added
				}
				set[i].end += m.num_added
			}
		}
		i += 1
	}
	// Drop empty ranges (port of the remove_if at the end of update).
	w := 0
	for r := 0; r < len(set); r += 1 {
		if set[r].begin < set[r].end {
			set[w] = set[r]
			w += 1
		}
	}
	resize(set, w)
}

// line_modification_range_set_add merges a range into the set, invoking
// on_new_range for each newly covered sub-range (port of
// LineRangeSet::add_range).
line_modification_range_set_add :: proc(
	set: ^Line_Range_Set,
	r: Line_Range,
	on_new_range: proc(data: rawptr, r: Line_Range),
	data: rawptr = nil,
) {
	r := r
	merged := r
	insert_at := line_modification_lower_bound_range_end(set^, merged.begin)
	if insert_at == len(set) || set[insert_at].begin > merged.end {
		on_new_range(data, merged)
	} else {
		pos := merged.begin
		it := insert_at
		for it < len(set) && set[it].begin <= merged.end {
			if pos < set[it].begin {
				on_new_range(data, Line_Range{pos, set[it].begin})
			}
			merged = Line_Range{min(merged.begin, set[it].begin), max(merged.end, set[it].end)}
			pos = set[it].end
			it += 1
		}
		line_modification_erase_range(set, insert_at, it)
		if pos < merged.end {
			on_new_range(data, Line_Range{pos, merged.end})
		}
	}
	inject_at(set, insert_at, merged)
}

// line_modification_range_set_remove cuts a range out of the set (port of
// LineRangeSet::remove_range).
line_modification_range_set_remove :: proc(set: ^Line_Range_Set, r: Line_Range) {
	line_modification_inside := proc(line: Units_LineCount, r: Line_Range) -> bool {
		return r.begin <= line && line < r.end
	}

	it := line_modification_lower_bound_range_end(set^, r.begin)
	if it == len(set) || set[it].begin > r.end {
		return
	}
	for it < len(set) && set[it].begin <= r.end {
		if set[it].begin < r.begin && r.end <= set[it].end {
			inject_at(set, it, Line_Range{set[it].begin, r.begin})
			it += 1
			set[it].begin = r.end
		}
		if line_modification_inside(set[it].begin, r) {
			set[it].begin = r.end
		}
		if line_modification_inside(set[it].end, r) {
			set[it].end = r.begin
		}
		if set[it].end <= set[it].begin {
			ordered_remove(set, it)
		} else {
			it += 1
		}
	}
}
