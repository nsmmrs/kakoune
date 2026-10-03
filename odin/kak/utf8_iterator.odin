// Codepoint iterator over UTF-8 bytes, ported from
// src/utf8_iterator.hh.
//
// The C++ bidirectional iterator template becomes a small struct
// holding the buffer plus begin/end/pos byte offsets; all movement
// and decoding delegate to the merged utf8 module (Pass policy).
// `pos` always sits on a character start (or `end`); `begin` and
// `end` must be character boundaries (or 0 / len(s)).
// `unicode_is_eol` et al from the unicode module classify values.
//
// Nothing here allocates.
package kak

// Utf8_Iterator iterates codepoints over s[begin:end]. Compare and
// order iterators by `pos`; iterators over different buffers, or
// with different bounds, must not be mixed.
Utf8_Iterator :: struct {
	s:     string,
	begin: int,
	end:   int,
	pos:   int,
}

// utf8_iterator_make builds an iterator over s[begin:end] positioned
// at pos. A negative end selects len(s); out-of-range bounds are
// clamped into the buffer and pos into [begin, end].
utf8_iterator_make :: proc(s: string, pos := 0, begin := 0, end := -1) -> Utf8_Iterator {
	lo := clamp(begin, 0, len(s))
	hi := len(s)
	if end >= 0 {
		hi = clamp(end, 0, len(s))
	}
	if hi < lo {
		hi = lo
	}
	return Utf8_Iterator{s = s, begin = lo, end = hi, pos = clamp(pos, lo, hi)}
}

// utf8_iterator_next steps to the next character start, stopping at
// end (C++ `operator++` / `to_next`).
utf8_iterator_next :: proc(it: ^Utf8_Iterator) {
	if it.pos < it.end {
		it.pos = min(utf8_next(it.s, it.pos), it.end)
	}
}

// utf8_iterator_prev steps to the previous character start,
// stopping at begin (C++ `operator--` / `to_previous`).
utf8_iterator_prev :: proc(it: ^Utf8_Iterator) {
	if it.pos > it.begin {
		it.pos = max(utf8_previous(it.s, it.pos), it.begin)
	}
}

// utf8_iterator_value decodes the codepoint at pos without moving
// (C++ `operator*`). At end it yields rune(-1), matching
// `InvalidPolicy::Pass{}(-1)`.
utf8_iterator_value :: proc(it: Utf8_Iterator) -> rune {
	return utf8_codepoint(it.s[:it.end], it.pos)
}

// utf8_iterator_read decodes the codepoint at pos and steps past the
// bytes consumed (C++ `read`).
utf8_iterator_read :: proc(it: ^Utf8_Iterator) -> rune {
	p := it.pos
	cp := utf8_read_codepoint(it.s[:it.end], &p)
	it.pos = p
	return cp
}

// utf8_iterator_base returns the byte offset of the current
// character (C++ `base`).
utf8_iterator_base :: proc(it: Utf8_Iterator) -> int {
	return it.pos
}

// utf8_iterator_at_end reports whether pos reached end.
utf8_iterator_at_end :: proc(it: Utf8_Iterator) -> bool {
	return it.pos >= it.end
}

// utf8_iterator_advance moves count characters forward (count > 0)
// or backward (count < 0), stopping at the bounds (C++
// `operator+=` / `operator-=`).
utf8_iterator_advance :: proc(it: ^Utf8_Iterator, count: int) {
	if count < 0 {
		n := -count
		for _ in 0 ..< n {
			utf8_iterator_prev(it)
		}
	} else {
		for _ in 0 ..< count {
			utf8_iterator_next(it)
		}
	}
}

// utf8_iterator_distance counts the characters from `from` to `to`
// (C++ `operator-`). Both iterators must share buffer and bounds; a
// reversed pair yields a negative count.
utf8_iterator_distance :: proc(from, to: Utf8_Iterator) -> int {
	if from.pos <= to.pos {
		return utf8_distance(from.s[from.pos:to.pos])
	}
	return -utf8_distance(from.s[to.pos:from.pos])
}

// utf8_iterator_equal reports whether both iterators sit at the same
// byte offset (C++ `operator==`).
utf8_iterator_equal :: proc(a, b: Utf8_Iterator) -> bool {
	return a.pos == b.pos
}

// utf8_iterator_compare orders iterators by byte offset: -1, 0, or 1
// (C++ `operator<=>`).
utf8_iterator_compare :: proc(a, b: Utf8_Iterator) -> int {
	if a.pos < b.pos {
		return -1
	}
	if a.pos > b.pos {
		return 1
	}
	return 0
}
