// Port of Kakoune's src/ranges.hh.
//
// The C++ original is built on lazy iterator views composed with
// `operator|` (e.g. `split`, `transform`, `filter`, `flatten`). Odin has
// no equivalent view/pipe machinery, so this port expresses the same
// operations as eager generic procs over slices:
//
//   * View adaptors that only reorder/reslice without copying
//     (`reverse`, `skip`, `drop`) become subslice/in-place procs.
//   * Adaptors that reshape elements (`filter`, `enumerate`, `transform`,
//     `split`, `split_after`, `flatten`, `concatenated`) materialize a
//     `[dynamic]T` the caller owns (freed with `delete`).
//   * Algorithms (`find`, `contains`, `accumulate`, ...) keep their
//     semantics; iterators become indices.
//
// Ownership: every proc returning `[dynamic]T` (or `[]T` reslices of one)
// allocates the backing array with the given `allocator` argument; the
// caller owns and frees it. Subslice views into the caller's data
// (`ranges_skip`, `ranges_drop`, the `string` pieces from the split
// procs, `ranges_remove_if`) borrow and must not outlive the input.
package kak

// Ranges_Enumerated pairs an element with its index, as produced by
// ranges_enumerate (port of C++ enumerate()).
Ranges_Enumerated :: struct(T: typeid) {
	index: int,
	value: T,
}

// ranges_reverse reverses s in place (port of C++ reverse()).
ranges_reverse :: proc(s: []$T) {
	i, j := 0, len(s) - 1
	for i < j {
		s[i], s[j] = s[j], s[i]
		i += 1
		j -= 1
	}
}

// ranges_reversed returns a reversed copy of s (non-mutating form of
// C++ reverse()). The caller owns the result.
ranges_reversed :: proc(s: []$T, allocator := context.allocator) -> [dynamic]T {
	res := make([dynamic]T, len(s), allocator)
	for v, i in s {
		res[len(s) - 1 - i] = v
	}
	return res
}

// ranges_skip returns s with the first count elements dropped (port of
// C++ skip()). Counts past the end clamp to an empty slice; the C++
// version has undefined behavior there.
ranges_skip :: proc(s: []$T, count: int) -> []T {
	n := clamp(count, 0, len(s))
	return s[n:]
}

// ranges_drop returns s with the last count elements dropped (port of
// C++ drop()). Counts past the start clamp to an empty slice; the C++
// version has undefined behavior there.
ranges_drop :: proc(s: []$T, count: int) -> []T {
	n := clamp(count, 0, len(s))
	return s[:len(s) - n]
}

// ranges_filter returns the elements of s for which pred holds, in
// order (eager port of C++ filter()). The caller owns the result.
ranges_filter :: proc(s: []$T, pred: proc(T) -> bool, allocator := context.allocator) -> [dynamic]T {
	res := make([dynamic]T, 0, len(s), allocator)
	for v in s {
		if pred(v) {
			append(&res, v)
		}
	}
	return res
}

// ranges_enumerate pairs each element of s with its index (eager port
// of C++ enumerate()). The caller owns the result.
ranges_enumerate :: proc(s: []$T, allocator := context.allocator) -> [dynamic]Ranges_Enumerated(T) {
	res := make([dynamic]Ranges_Enumerated(T), len(s), allocator)
	for v, i in s {
		res[i] = {i, v}
	}
	return res
}

// ranges_transform applies f to each element of s and returns the
// results in order (eager port of C++ transform()). The caller owns
// the result. The C++ member-pointer overload has no Odin equivalent.
ranges_transform :: proc(s: []$T, f: proc(T) -> $U, allocator := context.allocator) -> [dynamic]U {
	res := make([dynamic]U, 0, len(s), allocator)
	for v in s {
		append(&res, f(v))
	}
	return res
}

// ranges_split_impl is the shared engine behind ranges_split,
// ranges_split_after and ranges_split_escaped. It replicates
// SplitView's iteration exactly, including its edge cases: an empty
// input yields no pieces, a trailing separator yields a trailing empty
// piece (unless include_separator swallows it), and when escape is set
// a separator preceded by an unpaired escaper is skipped.
ranges_split_impl :: proc(
	s: string,
	separator, escaper: byte,
	escape, include_separator: bool,
	allocator := context.allocator,
) -> [dynamic]string {
	res := make([dynamic]string, allocator)
	if len(s) == 0 {
		return res
	}
	pos := 0
	sep := ranges_find_separator(s, 0, separator, escaper, escape, false)
	for {
		piece_end := sep
		if include_separator && sep != len(s) {
			piece_end = sep + 1
		}
		append(&res, s[pos:piece_end])
		if sep == len(s) {
			break
		}
		// Advance mirrors SplitView::Iterator::advance, including its
		// initial escaped state derived from the separator just found
		// (observable only when separator == escaper).
		pos = sep + 1
		if include_separator && pos == len(s) {
			break
		}
		sep = ranges_find_separator(s, pos, separator, escaper, escape, escape && s[sep] == escaper)
	}
	return res
}

// ranges_find_separator scans s for the first unescaped separator at
// or after start, returning len(s) when there is none.
ranges_find_separator :: proc(
	s: string,
	start: int,
	separator, escaper: byte,
	escape, escaped_init: bool,
) -> int {
	escaped := escaped_init
	sep := start
	for sep != len(s) {
		if !escaped && s[sep] == separator {
			break
		}
		escaped = escape && !escaped && s[sep] == escaper
		sep += 1
	}
	return sep
}

// ranges_split splits s on separator (port of C++ split()). Pieces are
// subslices borrowing s; the caller owns the array holding them.
ranges_split :: proc(s: string, separator: byte, allocator := context.allocator) -> [dynamic]string {
	return ranges_split_impl(s, separator, 0, false, false, allocator)
}

// ranges_split_after splits s on separator, keeping the separator at
// the end of each piece (port of C++ split_after()). Pieces borrow s;
// the caller owns the array holding them.
ranges_split_after :: proc(s: string, separator: byte, allocator := context.allocator) -> [dynamic]string {
	return ranges_split_impl(s, separator, 0, false, true, allocator)
}

// ranges_split_escaped splits s on separator, ignoring separators
// preceded by an unpaired escaper (port of C++ split(separator,
// escaper)). The escapers are kept in the pieces; use an unescape pass
// to remove them. Pieces borrow s; the caller owns the array.
ranges_split_escaped :: proc(
	s: string,
	separator, escaper: byte,
	allocator := context.allocator,
) -> [dynamic]string {
	return ranges_split_impl(s, separator, escaper, true, false, allocator)
}

// ranges_flatten concatenates nested slices into one array (eager port
// of C++ flatten()). Empty inner slices contribute nothing. The caller
// owns the result.
ranges_flatten :: proc(parts: [][]$T, allocator := context.allocator) -> [dynamic]T {
	total := 0
	for p in parts {
		total += len(p)
	}
	res := make([dynamic]T, 0, total, allocator)
	for p in parts {
		for v in p {
			append(&res, v)
		}
	}
	return res
}

// ranges_flatten_bytes concatenates string pieces into bytes (the
// []string case of C++ flatten(), e.g. over StringViews). The caller
// owns the result.
ranges_flatten_bytes :: proc(parts: []string, allocator := context.allocator) -> [dynamic]byte {
	total := 0
	for p in parts {
		total += len(p)
	}
	res := make([dynamic]byte, 0, total, allocator)
	for p in parts {
		for i in 0 ..< len(p) {
			append(&res, p[i])
		}
	}
	return res
}

// ranges_concatenated returns a followed by b (eager port of C++
// concatenated()). The caller owns the result.
ranges_concatenated :: proc(a, b: []$T, allocator := context.allocator) -> [dynamic]T {
	res := make([dynamic]T, 0, len(a) + len(b), allocator)
	for v in a {
		append(&res, v)
	}
	for v in b {
		append(&res, v)
	}
	return res
}

// ranges_find returns the index of the first element equal to value
// (port of C++ find(), whose iterator becomes an index here).
ranges_find :: proc(s: []$T, value: T) -> (index: int, found: bool) {
	for v, i in s {
		if v == value {
			return i, true
		}
	}
	return 0, false
}

// ranges_find_if returns the index of the first element satisfying
// pred (port of C++ find_if()).
ranges_find_if :: proc(s: []$T, pred: proc(T) -> bool) -> (index: int, found: bool) {
	for v, i in s {
		if pred(v) {
			return i, true
		}
	}
	return 0, false
}

// ranges_contains reports whether any element equals value (port of
// C++ contains()).
ranges_contains :: proc(s: []$T, value: T) -> bool {
	_, found := ranges_find(s, value)
	return found
}

// ranges_all_of reports whether pred holds for every element (port of
// C++ all_of()). Vacuously true for empty input.
ranges_all_of :: proc(s: []$T, pred: proc(T) -> bool) -> bool {
	for v in s {
		if !pred(v) {
			return false
		}
	}
	return true
}

// ranges_any_of reports whether pred holds for any element (port of
// C++ any_of()). False for empty input.
ranges_any_of :: proc(s: []$T, pred: proc(T) -> bool) -> bool {
	for v in s {
		if pred(v) {
			return true
		}
	}
	return false
}

// ranges_remove_if stably moves survivors to the front and returns the
// survivor prefix (port of C++ remove_if(), whose returned iterator
// becomes the slice end here). The tail past the result is unspecified.
ranges_remove_if :: proc(s: []$T, pred: proc(T) -> bool) -> []T {
	w := 0
	for v in s {
		if !pred(v) {
			s[w] = v
			w += 1
		}
	}
	return s[:w]
}

// ranges_unordered_erase removes the first element equal to value by
// swapping it with the back and popping (port of C++ unordered_erase()).
// A no-op when value is absent.
ranges_unordered_erase :: proc(s: ^[dynamic]$T, value: T) {
	for v, i in s^ {
		if v == value {
			s[i], s[len(s) - 1] = s[len(s) - 1], s[i]
			pop(s)
			return
		}
	}
}

// ranges_accumulate folds s left with op starting from init (port of
// C++ accumulate()).
ranges_accumulate :: proc(s: []$T, init: $U, op: proc(acc: U, val: T) -> U) -> U {
	acc := init
	for v in s {
		acc = op(acc, v)
	}
	return acc
}

// ranges_for_n_best calls func on elements best-first (maximum under
// less first) until count calls return true or elements run out (port
// of C++ for_n_best()). Each element is visited at most once; a false
// return consumes the element but not the count. Unlike the C++
// version, which heapifies the range in place, the input order is left
// untouched. Uses context.temp_allocator for scratch.
ranges_for_n_best :: proc(s: []$T, count: int, less: proc(a, b: T) -> bool, func: proc(val: T) -> bool) {
	remaining := count
	visited := make([dynamic]bool, len(s), context.temp_allocator)
	for remaining > 0 {
		best := -1
		for v, i in s {
			if visited[i] {
				continue
			}
			if best == -1 || less(s[best], v) {
				best = i
			}
		}
		if best == -1 {
			return
		}
		visited[best] = true
		if func(s[best]) {
			remaining -= 1
		}
	}
}

// ranges_gather copies s into a new dynamic array (port of C++
// gather()). The caller owns the result.
ranges_gather :: proc(s: []$T, allocator := context.allocator) -> [dynamic]T {
	res := make([dynamic]T, 0, len(s), allocator)
	for v in s {
		append(&res, v)
	}
	return res
}

// ranges_static_gather copies s into a fixed-size array (port of C++
// static_gather(), whose exception becomes ok == false). With
// exact_size it requires len(s) == N; otherwise len(s) >= N and only
// the first N elements are taken.
ranges_static_gather :: proc(s: []$T, $N: int, exact_size := true) -> (res: [N]T, ok: bool) {
	if exact_size {
		if len(s) != N {
			return res, false
		}
	} else if len(s) < N {
		return res, false
	}
	for i in 0 ..< N {
		res[i] = s[i]
	}
	return res, true
}
