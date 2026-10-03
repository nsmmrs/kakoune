// Word splitting ported from src/word_splitter.hh.
//
// A `Word_Splitter` pairs content with the extra word characters that
// extend `unicode_is_word`, and `Word_Splitter_Iterator` walks the
// word runs in order, skipping words longer than
// `word_splitter_MAX_WORD_LEN` bytes exactly like the C++
// `operator++` do-while.
//
// Decoding delegates to the merged utf8 module (`utf8_read_codepoint`
// with Pass policy) and classification to `unicode_is_word`, so
// invalid bytes behave the same as the merged helpers define.
//
// Nothing here allocates except `word_splitter_collect`, which takes
// an explicit allocator; the collected substrings share the content's
// backing store, so only the returned array needs freeing.
package kak

// word_splitter_MAX_WORD_LEN is the longest word kept by the
// iterator, in bytes (C++ `WordSplitter::max_word_len`). Longer
// words are silently skipped.
word_splitter_MAX_WORD_LEN :: 100

// Word_Splitter is the content plus extra word characters to split
// (C++ `WordSplitter`).
Word_Splitter :: struct {
	content:          string,
	extra_word_chars: []rune,
}

// Word_Splitter_Iterator walks the words of a splitter. Compare and
// order iterators by their offsets; iterators over different content
// must not be mixed. `splitter` is stored by value (a string plus a
// slice header, cheap to copy) so iterators never dangle.
Word_Splitter_Iterator :: struct {
	splitter:   Word_Splitter,
	word_begin: int,
	word_end:   int,
}

// word_splitter_make builds a splitter over content with the given
// extra word characters (C++ aggregate construction).
word_splitter_make :: proc(content: string, extra_word_chars: []rune) -> Word_Splitter {
	return Word_Splitter{content = content, extra_word_chars = extra_word_chars}
}

// word_splitter_begin returns an iterator positioned at the first
// word (C++ `begin()`).
word_splitter_begin :: proc(splitter: Word_Splitter) -> Word_Splitter_Iterator {
	it := Word_Splitter_Iterator{splitter = splitter}
	word_splitter_iterator_next(&it)
	return it
}

// word_splitter_end returns the past-the-end iterator (C++ `end()`).
word_splitter_end :: proc(splitter: Word_Splitter) -> Word_Splitter_Iterator {
	it := Word_Splitter_Iterator{
		splitter   = splitter,
		word_begin = len(splitter.content),
		word_end   = len(splitter.content),
	}
	word_splitter_iterator_next(&it)
	return it
}

// word_splitter_iterator_next advances to the next word, skipping
// non-word codepoints and words longer than
// `word_splitter_MAX_WORD_LEN` bytes (C++ `operator++`).
word_splitter_iterator_next :: proc(it: ^Word_Splitter_Iterator) {
	content := it.splitter.content
	extra := it.splitter.extra_word_chars
	end := len(content)
	for {
		it_pos := it.word_end
		word_begin := it_pos
		for it_pos < end {
			p := it_pos
			cp := utf8_read_codepoint(content, &p)
			it_pos = p
			if unicode_is_word(cp, extra) {
				break
			}
			word_begin = it_pos
		}
		word_end := it_pos
		for it_pos < end {
			p := it_pos
			cp := utf8_read_codepoint(content, &p)
			if !unicode_is_word(cp, extra) {
				break
			}
			it_pos = p
			word_end = it_pos
		}
		it.word_begin = word_begin
		it.word_end = word_end
		if word_begin == end || word_end - word_begin <= word_splitter_MAX_WORD_LEN {
			return
		}
	}
}

// word_splitter_iterator_value returns the current word (C++
// `operator*`). At the end it yields "".
word_splitter_iterator_value :: proc(it: Word_Splitter_Iterator) -> string {
	return it.splitter.content[it.word_begin:it.word_end]
}

// word_splitter_iterator_at_end reports whether the iterator reached
// the end of the content.
word_splitter_iterator_at_end :: proc(it: Word_Splitter_Iterator) -> bool {
	return it.word_begin >= len(it.splitter.content)
}

// word_splitter_iterator_equal reports whether both iterators sit at
// the same word of the same content (C++ `operator==`).
word_splitter_iterator_equal :: proc(a, b: Word_Splitter_Iterator) -> bool {
	return a.word_begin == b.word_begin && a.word_end == b.word_end &&
		a.splitter.content == b.splitter.content
}

// word_splitter_collect gathers every word into an owned array. The
// caller owns the result and must `delete` it with the same
// allocator; the word substrings themselves share the content's
// backing store and need no freeing.
word_splitter_collect :: proc(splitter: Word_Splitter, allocator := context.allocator) -> [dynamic]string {
	words := make([dynamic]string, allocator)
	it := word_splitter_begin(splitter)
	for !word_splitter_iterator_at_end(it) {
		append(&words, word_splitter_iterator_value(it))
		word_splitter_iterator_next(&it)
	}
	return words
}
