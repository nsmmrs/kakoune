// Tests for the word_splitter module. No C++ UnitTest covers
// src/word_splitter.hh, so these tests pin the documented iterator
// semantics directly, plus edge cases.
package kak

import "core:testing"

@(test)
word_splitter_test_basic :: proc(t: ^testing.T) {
	extra := []rune{'_'}
	words := word_splitter_collect(word_splitter_make("hello world", extra[:]))
	defer delete(words)
	testing.expect_value(t, len(words), 2)
	testing.expect_value(t, words[0], "hello")
	testing.expect_value(t, words[1], "world")
}

@(test)
word_splitter_test_separators :: proc(t: ^testing.T) {
	extra := []rune{'_'}
	words := word_splitter_collect(word_splitter_make("  foo, bar!baz\tqux\n", extra[:]))
	defer delete(words)
	testing.expect_value(t, len(words), 4)
	testing.expect_value(t, words[0], "foo")
	testing.expect_value(t, words[1], "bar")
	testing.expect_value(t, words[2], "baz")
	testing.expect_value(t, words[3], "qux")
}

@(test)
word_splitter_test_underscore_default :: proc(t: ^testing.T) {
	extra := []rune{'_'}
	words := word_splitter_collect(word_splitter_make("foo_bar", extra[:]))
	defer delete(words)
	testing.expect_value(t, len(words), 1)
	testing.expect_value(t, words[0], "foo_bar")
}

@(test)
word_splitter_test_empty_extra_splits_underscore :: proc(t: ^testing.T) {
	words := word_splitter_collect(word_splitter_make("foo_bar", nil))
	defer delete(words)
	testing.expect_value(t, len(words), 2)
	testing.expect_value(t, words[0], "foo")
	testing.expect_value(t, words[1], "bar")
}

@(test)
word_splitter_test_custom_extra_chars :: proc(t: ^testing.T) {
	extra := []rune{'-'}
	words := word_splitter_collect(word_splitter_make("foo-bar baz_qux", extra[:]))
	defer delete(words)
	testing.expect_value(t, len(words), 3)
	testing.expect_value(t, words[0], "foo-bar")
	testing.expect_value(t, words[1], "baz")
	testing.expect_value(t, words[2], "qux")
}

@(test)
word_splitter_test_empty_content :: proc(t: ^testing.T) {
	splitter := word_splitter_make("", nil)
	begin := word_splitter_begin(splitter)
	end := word_splitter_end(splitter)
	testing.expect(t, word_splitter_iterator_at_end(begin))
	testing.expect(t, word_splitter_iterator_equal(begin, end))
	testing.expect_value(t, word_splitter_iterator_value(begin), "")
	words := word_splitter_collect(splitter)
	defer delete(words)
	testing.expect_value(t, len(words), 0)
}

@(test)
word_splitter_test_no_words :: proc(t: ^testing.T) {
	splitter := word_splitter_make("   .,!\t\n", nil)
	begin := word_splitter_begin(splitter)
	testing.expect(t, word_splitter_iterator_at_end(begin))
	testing.expect(t, word_splitter_iterator_equal(begin, word_splitter_end(splitter)))
	words := word_splitter_collect(splitter)
	defer delete(words)
	testing.expect_value(t, len(words), 0)
}

@(test)
word_splitter_test_single_word :: proc(t: ^testing.T) {
	splitter := word_splitter_make("abc", nil)
	it := word_splitter_begin(splitter)
	testing.expect(t, !word_splitter_iterator_at_end(it))
	testing.expect_value(t, word_splitter_iterator_value(it), "abc")
	testing.expect(t, !word_splitter_iterator_equal(it, word_splitter_end(splitter)))
	word_splitter_iterator_next(&it)
	testing.expect(t, word_splitter_iterator_at_end(it))
	testing.expect(t, word_splitter_iterator_equal(it, word_splitter_end(splitter)))
}

@(test)
word_splitter_test_max_word_len_boundary :: proc(t: ^testing.T) {
	// A word of exactly MAX_WORD_LEN bytes is kept; longer ones are
	// skipped (C++ `> max_word_len`).
	buf := make([dynamic]byte, 0, 2 * word_splitter_MAX_WORD_LEN)
	defer delete(buf)
	for _ in 0 ..< word_splitter_MAX_WORD_LEN {
		append(&buf, 'a')
	}
	kept := word_splitter_collect(word_splitter_make(string(buf[:]), nil))
	defer delete(kept)
	testing.expect_value(t, len(kept), 1)
	testing.expect_value(t, len(kept[0]), word_splitter_MAX_WORD_LEN)

	append(&buf, 'a')
	dropped := word_splitter_collect(word_splitter_make(string(buf[:]), nil))
	defer delete(dropped)
	testing.expect_value(t, len(dropped), 0)
}

@(test)
word_splitter_test_overlong_skipped_midstream :: proc(t: ^testing.T) {
	buf := make([dynamic]byte, 0, 2 * word_splitter_MAX_WORD_LEN)
	defer delete(buf)
	for c in "head " {
		append(&buf, byte(c))
	}
	for _ in 0 ..< word_splitter_MAX_WORD_LEN + 1 {
		append(&buf, 'x')
	}
	for c in " tail" {
		append(&buf, byte(c))
	}
	words := word_splitter_collect(word_splitter_make(string(buf[:]), nil))
	defer delete(words)
	testing.expect_value(t, len(words), 2)
	testing.expect_value(t, words[0], "head")
	testing.expect_value(t, words[1], "tail")
}

@(test)
word_splitter_test_max_len_counts_bytes :: proc(t: ^testing.T) {
	// 'é' is 2 bytes: 50 of them are exactly 100 bytes (kept) while
	// 51 are 102 bytes (skipped).
	kept_buf := make([dynamic]byte, 0, 100)
	defer delete(kept_buf)
	for _ in 0 ..< 50 {
		append(&kept_buf, 0xC3, 0xA9)
	}
	kept := word_splitter_collect(word_splitter_make(string(kept_buf[:]), nil))
	defer delete(kept)
	testing.expect_value(t, len(kept), 1)

	dropped_buf := make([dynamic]byte, 0, 110)
	defer delete(dropped_buf)
	for _ in 0 ..< 51 {
		append(&dropped_buf, 0xC3, 0xA9)
	}
	dropped := word_splitter_collect(word_splitter_make(string(dropped_buf[:]), nil))
	defer delete(dropped)
	testing.expect_value(t, len(dropped), 0)
}

@(test)
word_splitter_test_unicode_words :: proc(t: ^testing.T) {
	extra := []rune{'_'}
	words := word_splitter_collect(word_splitter_make("héllo wörld 中文", extra[:]))
	defer delete(words)
	testing.expect_value(t, len(words), 3)
	testing.expect_value(t, words[0], "héllo")
	testing.expect_value(t, words[1], "wörld")
	testing.expect_value(t, words[2], "中文")
}

@(test)
word_splitter_test_iterator_walk :: proc(t: ^testing.T) {
	splitter := word_splitter_make("one two", nil)
	it := word_splitter_begin(splitter)
	testing.expect_value(t, word_splitter_iterator_value(it), "one")
	testing.expect_value(t, it.word_begin, 0)
	testing.expect_value(t, it.word_end, 3)
	word_splitter_iterator_next(&it)
	testing.expect_value(t, word_splitter_iterator_value(it), "two")
	testing.expect_value(t, it.word_begin, 4)
	testing.expect_value(t, it.word_end, 7)
	word_splitter_iterator_next(&it)
	testing.expect(t, word_splitter_iterator_at_end(it))
	// Stepping past the end is a no-op.
	word_splitter_iterator_next(&it)
	testing.expect(t, word_splitter_iterator_at_end(it))
	testing.expect(t, word_splitter_iterator_equal(it, word_splitter_end(splitter)))
}

@(test)
word_splitter_test_trailing_word :: proc(t: ^testing.T) {
	words := word_splitter_collect(word_splitter_make("...end", nil))
	defer delete(words)
	testing.expect_value(t, len(words), 1)
	testing.expect_value(t, words[0], "end")
}
