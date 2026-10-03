// Tests for the utf8_iterator module. No C++ UnitTest covers
// src/utf8_iterator.hh, so these tests pin the documented
// iterator semantics directly, plus edge cases.
package kak

import "core:testing"

// "aéb中" — 1-, 2-, 1-, and 3-byte characters at offsets 0, 1, 3, 4.
@(test)
utf8_iterator_test_forward_walk :: proc(t: ^testing.T) {
	s := "aéb中"
	it := utf8_iterator_make(s)
	testing.expect_value(t, utf8_iterator_value(it), 'a')
	testing.expect_value(t, utf8_iterator_base(it), 0)
	testing.expect(t, !utf8_iterator_at_end(it))
	utf8_iterator_next(&it)
	testing.expect_value(t, utf8_iterator_value(it), 'é')
	testing.expect_value(t, utf8_iterator_base(it), 1)
	utf8_iterator_next(&it)
	testing.expect_value(t, utf8_iterator_value(it), 'b')
	testing.expect_value(t, utf8_iterator_base(it), 3)
	utf8_iterator_next(&it)
	testing.expect_value(t, utf8_iterator_value(it), '中')
	testing.expect_value(t, utf8_iterator_base(it), 4)
	utf8_iterator_next(&it)
	testing.expect(t, utf8_iterator_at_end(it))
	testing.expect_value(t, utf8_iterator_base(it), len(s))
	// Stepping past the end is a no-op.
	utf8_iterator_next(&it)
	testing.expect(t, utf8_iterator_at_end(it))
	testing.expect_value(t, utf8_iterator_base(it), len(s))
}

@(test)
utf8_iterator_test_backward_walk :: proc(t: ^testing.T) {
	s := "aéb中"
	it := utf8_iterator_make(s, len(s))
	testing.expect(t, utf8_iterator_at_end(it))
	utf8_iterator_prev(&it)
	testing.expect_value(t, utf8_iterator_value(it), '中')
	testing.expect_value(t, utf8_iterator_base(it), 4)
	utf8_iterator_prev(&it)
	testing.expect_value(t, utf8_iterator_value(it), 'b')
	testing.expect_value(t, utf8_iterator_base(it), 3)
	utf8_iterator_prev(&it)
	testing.expect_value(t, utf8_iterator_value(it), 'é')
	testing.expect_value(t, utf8_iterator_base(it), 1)
	utf8_iterator_prev(&it)
	testing.expect_value(t, utf8_iterator_value(it), 'a')
	testing.expect_value(t, utf8_iterator_base(it), 0)
	// Stepping before the begin is a no-op.
	utf8_iterator_prev(&it)
	testing.expect_value(t, utf8_iterator_base(it), 0)
	testing.expect_value(t, utf8_iterator_value(it), 'a')
}

@(test)
utf8_iterator_test_value_at_end :: proc(t: ^testing.T) {
	s := "ab"
	it := utf8_iterator_make(s, len(s))
	testing.expect_value(t, utf8_iterator_value(it), rune(-1))
	empty := utf8_iterator_make("")
	testing.expect(t, utf8_iterator_at_end(empty))
	testing.expect_value(t, utf8_iterator_value(empty), rune(-1))
}

@(test)
utf8_iterator_test_read :: proc(t: ^testing.T) {
	s := "aé中"
	it := utf8_iterator_make(s)
	testing.expect_value(t, utf8_iterator_read(&it), 'a')
	testing.expect_value(t, utf8_iterator_base(it), 1)
	testing.expect_value(t, utf8_iterator_read(&it), 'é')
	testing.expect_value(t, utf8_iterator_base(it), 3)
	testing.expect_value(t, utf8_iterator_read(&it), '中')
	testing.expect(t, utf8_iterator_at_end(it))
	testing.expect_value(t, utf8_iterator_read(&it), rune(-1))
	testing.expect(t, utf8_iterator_at_end(it))
}

@(test)
utf8_iterator_test_advance :: proc(t: ^testing.T) {
	s := "aéb中"
	it := utf8_iterator_make(s)
	utf8_iterator_advance(&it, 2)
	testing.expect_value(t, utf8_iterator_value(it), 'b')
	utf8_iterator_advance(&it, -1)
	testing.expect_value(t, utf8_iterator_value(it), 'é')
	utf8_iterator_advance(&it, 0)
	testing.expect_value(t, utf8_iterator_value(it), 'é')
	// Overshooting stops at the bounds.
	utf8_iterator_advance(&it, 100)
	testing.expect(t, utf8_iterator_at_end(it))
	utf8_iterator_advance(&it, -100)
	testing.expect_value(t, utf8_iterator_base(it), 0)
}

@(test)
utf8_iterator_test_distance :: proc(t: ^testing.T) {
	s := "aéb中"
	first := utf8_iterator_make(s)
	last := utf8_iterator_make(s, len(s))
	testing.expect_value(t, utf8_iterator_distance(first, last), 4)
	testing.expect_value(t, utf8_iterator_distance(first, first), 0)
	testing.expect_value(t, utf8_iterator_distance(last, first), -4)
	mid := utf8_iterator_make(s, 3) // 'b'
	testing.expect_value(t, utf8_iterator_distance(first, mid), 2)
	testing.expect_value(t, utf8_iterator_distance(mid, last), 2)
	testing.expect_value(t, utf8_iterator_distance(mid, first), -2)
}

@(test)
utf8_iterator_test_equal_compare :: proc(t: ^testing.T) {
	s := "aé"
	a := utf8_iterator_make(s)
	b := utf8_iterator_make(s)
	testing.expect(t, utf8_iterator_equal(a, b))
	testing.expect_value(t, utf8_iterator_compare(a, b), 0)
	utf8_iterator_next(&b)
	testing.expect(t, !utf8_iterator_equal(a, b))
	testing.expect_value(t, utf8_iterator_compare(a, b), -1)
	testing.expect_value(t, utf8_iterator_compare(b, a), 1)
	end := utf8_iterator_make(s, len(s))
	testing.expect_value(t, utf8_iterator_compare(b, end), -1)
}

@(test)
utf8_iterator_test_subrange :: proc(t: ^testing.T) {
	s := "aéb中"
	// Iterate only over "éb" (bytes 1..4).
	it := utf8_iterator_make(s, 1, 1, 4)
	testing.expect_value(t, utf8_iterator_value(it), 'é')
	utf8_iterator_next(&it)
	testing.expect_value(t, utf8_iterator_value(it), 'b')
	utf8_iterator_next(&it)
	testing.expect(t, utf8_iterator_at_end(it))
	testing.expect_value(t, utf8_iterator_base(it), 4)
	// Backward motion stops at begin, not at 0.
	utf8_iterator_prev(&it)
	utf8_iterator_prev(&it)
	testing.expect_value(t, utf8_iterator_base(it), 1)
	utf8_iterator_prev(&it)
	testing.expect_value(t, utf8_iterator_base(it), 1)
	// Decoding is bounded by end: a lead byte cut off by end yields
	// the partial codepoint, as in C++.
	cut := utf8_iterator_make(s, 4, 4, 5) // first byte of 中 only
	testing.expect_value(t, utf8_iterator_value(cut), utf8_codepoint(s[:5], 4))
}

@(test)
utf8_iterator_test_make_clamps :: proc(t: ^testing.T) {
	s := "ab"
	it := utf8_iterator_make(s, 100)
	testing.expect_value(t, utf8_iterator_base(it), len(s))
	neg := utf8_iterator_make(s, -5)
	testing.expect_value(t, utf8_iterator_base(neg), 0)
	wide := utf8_iterator_make(s, 0, -10, 100)
	testing.expect_value(t, wide.begin, 0)
	testing.expect_value(t, wide.end, len(s))
	// An inverted range collapses to an empty one.
	empty := utf8_iterator_make(s, 0, 2, 1)
	testing.expect(t, utf8_iterator_at_end(empty))
	testing.expect_value(t, utf8_iterator_base(empty), 2)
}

@(test)
utf8_iterator_test_ascii_and_empty :: proc(t: ^testing.T) {
	s := "hello"
	it := utf8_iterator_make(s)
	n := 0
	for !utf8_iterator_at_end(it) {
		testing.expect_value(t, utf8_iterator_value(it), rune(s[n]))
		utf8_iterator_next(&it)
		n += 1
	}
	testing.expect_value(t, n, len(s))
	end := utf8_iterator_make(s, len(s))
	testing.expect_value(t, utf8_iterator_distance(it, end), 0)
	empty := utf8_iterator_make("")
	testing.expect(t, utf8_iterator_at_end(empty))
	utf8_iterator_next(&empty)
	utf8_iterator_prev(&empty)
	testing.expect(t, utf8_iterator_at_end(empty))
	testing.expect_value(t, utf8_iterator_distance(empty, empty), 0)
	utf8_iterator_advance(&empty, 3)
	testing.expect(t, utf8_iterator_at_end(empty))
}

@(test)
utf8_iterator_test_invalid_bytes :: proc(t: ^testing.T) {
	// Pass policy: a stray continuation byte decodes to its
	// sign-extended value and consumes one byte.
	s := "a\x80b"
	it := utf8_iterator_make(s)
	testing.expect_value(t, utf8_iterator_value(it), 'a')
	// Forward motion skips the stray continuation byte.
	utf8_iterator_next(&it)
	testing.expect_value(t, utf8_iterator_value(it), 'b')
	testing.expect_value(t, utf8_iterator_base(it), 2)
	// Decoding directly on the stray byte yields its sign-extended
	// value, as in C++.
	stray := utf8_iterator_make(s, 1)
	testing.expect_value(t, utf8_iterator_value(stray), rune(-128))
	// Distance counts character starts, so the stray byte is skipped.
	end := utf8_iterator_make(s, len(s))
	start := utf8_iterator_make(s)
	testing.expect_value(t, utf8_iterator_distance(start, end), 2)
	// Backward motion steps over the stray byte back to 'a'.
	utf8_iterator_prev(&end)
	testing.expect_value(t, utf8_iterator_value(end), 'b')
	utf8_iterator_prev(&end)
	testing.expect_value(t, utf8_iterator_base(end), 0)
}
