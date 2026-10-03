// Ranked fuzzy matching ported from src/ranked_match.cc / src/ranked_match.hh.
//
// Scores and ordering match the C++ implementation exactly for valid UTF-8
// input. Non-ASCII character classification uses Odin core:unicode tables
// where the C++ uses libc wide-character functions (see deviations below).
//
// The candidate string is borrowed: Ranked_Match keeps a view of it, like
// the C++ StringView member. Nothing here allocates.
package kak

import "core:unicode"

// Bitset of letters used by a string, see ranked_match_used_letters.
Ranked_Match_Used_Letters :: u64

// Bits 26..51: the uppercase letters A-Z.
ranked_match_UPPER_MASK :: Ranked_Match_Used_Letters(0xFFFFFFC000000)

// Match quality flags. Bit order is significant: in ranked_match_less the
// highest differing bit decides, mirroring the C++ int comparison.
Ranked_Match_Flag :: enum u8 {
	Single_Word,
	Contiguous,
	Only_Word_Boundary,
	Prefix,
	Base_Name,
	Smart_Full_Match,
	Full_Match,
}

Ranked_Match_Flags :: bit_set[Ranked_Match_Flag; u8]

Ranked_Match :: struct {
	candidate:                 string,
	matches:                   bool,
	flags:                     Ranked_Match_Flags,
	full_word_match_count:     int,
	word_boundary_match_count: int,
	max_index:                 int,
	input_sequence_number:     uint,
}

Ranked_Match_Subseq_Result :: struct {
	max_index:   int,
	single_word: bool,
}

// Words longer than this (in bytes) are skipped by the word splitter,
// mirroring WordSplitter::max_word_len.
ranked_match_MAX_WORD_LEN :: 100

ranked_match_used_letters :: proc(s: string) -> Ranked_Match_Used_Letters {
	res: Ranked_Match_Used_Letters = 0
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		switch {
		case c >= 'a' && c <= 'z':
			res |= Ranked_Match_Used_Letters(1) << (c - 'a')
		case c >= 'A' && c <= 'Z':
			res |= Ranked_Match_Used_Letters(1) << (c - 'A' + 26)
		case c == '_':
			res |= Ranked_Match_Used_Letters(1) << 53
		case c == '-':
			res |= Ranked_Match_Used_Letters(1) << 54
		case:
			res |= Ranked_Match_Used_Letters(1) << 63
		}
	}
	return res
}

ranked_match_to_lower_letters :: proc(letters: Ranked_Match_Used_Letters) -> Ranked_Match_Used_Letters {
	return ((letters & ranked_match_UPPER_MASK) >> 26) | (letters & ~ranked_match_UPPER_MASK)
}

ranked_match_matches :: proc(query, letters: Ranked_Match_Used_Letters) -> bool {
	return query & letters == query
}

// ASCII behavior is exactly the C++ unicode.hh classification; non-ASCII
// codepoints use core:unicode tables instead of libc wide functions.
ranked_match_is_alnum :: proc(c: rune) -> bool {
	if c >= 0 && c < 128 {
		return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
	}
	if c < 0 {
		// Artifact of invalid UTF-8 (sign-extended byte); iswalnum is false there.
		return false
	}
	return unicode.is_letter(c) || unicode.is_digit(c)
}

// is_word with the default extra word chars ('_').
ranked_match_is_word :: proc(c: rune) -> bool {
	return c == '_' || ranked_match_is_alnum(c)
}

// is_word with empty extra word chars, as used by the word-boundary,
// basename-word and tiebreak logic in ranked_match.cc.
ranked_match_is_word_strict :: proc(c: rune) -> bool {
	return ranked_match_is_alnum(c)
}

ranked_match_is_lower :: proc(c: rune) -> bool {
	if c < 128 {
		return c >= 'a' && c <= 'z'
	}
	return unicode.is_lower(c)
}

ranked_match_is_upper :: proc(c: rune) -> bool {
	if c < 128 {
		return c >= 'A' && c <= 'Z'
	}
	return unicode.is_upper(c)
}

ranked_match_to_lower :: proc(c: rune) -> rune {
	if c < 128 {
		if c >= 'A' && c <= 'Z' {
			return c + ('a' - 'A')
		}
		return c
	}
	return unicode.to_lower(c)
}

ranked_match_is_character_start :: proc(b: byte) -> bool {
	return b & 0xC0 != 0x80
}

// Lenient continuation byte read mirroring utf8::read_codepoint with the
// Pass policy: bytes are masked, never validated.
ranked_match_read_continuation :: proc(s: string, pos: ^int, end: int) -> u32 {
	if pos^ >= end {
		return 0
	}
	b := s[pos^]
	pos^ += 1
	return u32(b) & 0x3F
}

// Lenient decoder mirroring Kakoune utf8::read_codepoint<Pass>: overlong or
// out-of-range values pass through, truncated sequences yield partial
// values, and stray bytes sign-extend like C++ char -> char32_t.
ranked_match_read_codepoint_end :: proc(s: string, pos: ^int, end: int) -> rune {
	b := s[pos^]
	pos^ += 1
	if b & 0x80 == 0 {
		return rune(b)
	}
	if pos^ >= end {
		return rune(i8(b))
	}
	switch {
	case b & 0xE0 == 0xC0:
		return rune((u32(b) & 0x1F) << 6 | ranked_match_read_continuation(s, pos, end))
	case b & 0xF0 == 0xE0:
		cp := (u32(b) & 0x0F) << 12 | ranked_match_read_continuation(s, pos, end) << 6
		if pos^ >= end {
			return rune(cp)
		}
		return rune(cp | ranked_match_read_continuation(s, pos, end))
	case b & 0xF8 == 0xF0:
		cp := (u32(b) & 0x07) << 18 | ranked_match_read_continuation(s, pos, end) << 12
		if pos^ >= end {
			return rune(cp)
		}
		cp |= ranked_match_read_continuation(s, pos, end) << 6
		if pos^ >= end {
			return rune(cp)
		}
		return rune(cp | ranked_match_read_continuation(s, pos, end))
	}
	return rune(i8(b))
}

ranked_match_read_codepoint :: proc(s: string, pos: ^int) -> rune {
	return ranked_match_read_codepoint_end(s, pos, len(s))
}

ranked_match_peek_codepoint :: proc(s: string, byte_pos: int) -> rune {
	pos := byte_pos
	return ranked_match_read_codepoint(s, &pos)
}

// Byte offset of the next character start (utf8::to_next).
ranked_match_next_char :: proc(s: string, pos: int) -> int {
	p := pos
	if p < len(s) {
		p += 1
	}
	for p < len(s) && !ranked_match_is_character_start(s[p]) {
		p += 1
	}
	return p
}

// Byte offset of the character start at or before pos (utf8::character_start).
ranked_match_character_start :: proc(s: string, pos, begin: int) -> int {
	p := pos
	for p > begin && !ranked_match_is_character_start(s[p]) {
		p -= 1
	}
	return p
}

ranked_match_prev_codepoint :: proc(s: string, pos, begin: int) -> rune {
	if pos <= begin {
		return rune(-1)
	}
	start := ranked_match_character_start(s, pos - 1, begin)
	return ranked_match_read_codepoint_end(s, &start, pos)
}

ranked_match_count_word_boundaries :: proc(candidate, query: string) -> int {
	count := 0
	query_pos := 0
	prev: rune = 0
	pos := 0
	for pos < len(candidate) {
		c := ranked_match_peek_codepoint(candidate, pos)
		is_boundary := prev == 0 ||
			(!ranked_match_is_word_strict(prev) && ranked_match_is_word_strict(c)) ||
			(ranked_match_is_lower(prev) && ranked_match_is_upper(c))
		prev = c
		next := ranked_match_next_char(candidate, pos)
		if !is_boundary {
			pos = next
			continue
		}
		lc := ranked_match_to_lower(c)
		qpos := query_pos
		for qpos < len(query) {
			qc := ranked_match_peek_codepoint(query, qpos)
			want := lc if ranked_match_is_lower(qc) else c
			qnext := ranked_match_next_char(query, qpos)
			if qc == want {
				count += 1
				query_pos = qnext
				break
			}
			qpos = qnext
		}
		if query_pos >= len(query) {
			break
		}
		pos = next
	}
	return count
}

// Next word of s at or after pos, mirroring WordSplitter with empty extra
// word chars. Words longer than ranked_match_MAX_WORD_LEN bytes are skipped.
ranked_match_next_word :: proc(s: string, pos: int) -> (word: string, next_pos: int, found: bool) {
	n := len(s)
	p := pos
	for {
		// Skip non-word characters.
		q := p
		for q < n {
			r := q
			c := ranked_match_read_codepoint(s, &r)
			if ranked_match_is_word_strict(c) {
				break
			}
			q = r
		}
		if q >= n {
			return "", n, false
		}
		start := q
		// Consume word characters.
		for q < n {
			r := q
			c := ranked_match_read_codepoint(s, &r)
			if !ranked_match_is_word_strict(c) {
				break
			}
			q = r
		}
		p = q
		if q - start > ranked_match_MAX_WORD_LEN {
			continue
		}
		return s[start:q], q, true
	}
}

ranked_match_count_full_word_match :: proc(candidate, query: string) -> int {
	count := 0
	qpos := 0
	for {
		qword, qnext, qok := ranked_match_next_word(query, qpos)
		if !qok {
			break
		}
		qpos = qnext
		cpos := 0
		for {
			cword, cnext, cok := ranked_match_next_word(candidate, cpos)
			if !cok {
				break
			}
			cpos = cnext
			if cword == qword {
				count += 1
				break
			}
		}
	}
	return count
}

ranked_match_smartcase_eq :: proc(candidate, query: rune) -> bool {
	if ranked_match_is_lower(query) {
		return query == ranked_match_to_lower(candidate)
	}
	return query == candidate
}

ranked_match_subsequence_match :: proc(str, subseq: string) -> (res: Ranked_Match_Subseq_Result, ok: bool) {
	single_word := true
	max_index := -1
	pos := 0
	index := 0
	qpos := 0
	for qpos < len(subseq) {
		if pos >= len(str) {
			return {}, false
		}
		c := ranked_match_read_codepoint(subseq, &qpos)
		if single_word && !ranked_match_is_word(c) {
			single_word = false
		}
		for {
			str_c := ranked_match_read_codepoint(str, &pos)
			if ranked_match_smartcase_eq(str_c, c) {
				break
			}
			if max_index != -1 && single_word && !ranked_match_is_word(str_c) {
				single_word = false
			}
			index += 1
			if pos >= len(str) {
				return {}, false
			}
		}
		max_index = index
		index += 1
	}
	return Ranked_Match_Subseq_Result{max_index, single_word}, true
}

// Byte offset of the basename: one past the last '/' before the final byte,
// or 0 when there is none. Mirrors
// find(candidate | reverse() | skip(1), '/').base() from the C++.
ranked_match_basename_start :: proc(candidate: string) -> int {
	for i := len(candidate) - 2; i >= 0; i -= 1 {
		if candidate[i] == '/' {
			return i + 1
		}
	}
	return 0
}

// Byte-wise smartcase search mirroring std::search with smartcase_eq over
// the raw bytes. Bytes convert to runes with sign extension, exactly like
// the C++ char -> Codepoint conversion.
ranked_match_find_contiguous :: proc(candidate, query: string) -> (pos: int, found: bool) {
	for i := 0; i + len(query) <= len(candidate); i += 1 {
		ok := true
		for j := 0; j < len(query); j += 1 {
			cb := rune(i8(candidate[i + j]))
			qb := rune(i8(query[j]))
			if !ranked_match_smartcase_eq(cb, qb) {
				ok = false
				break
			}
		}
		if ok {
			return i, true
		}
	}
	return 0, false
}

ranked_match_make_impl :: proc(candidate, query: string, pretest_passed: bool) -> Ranked_Match {
	m := Ranked_Match{candidate = candidate}
	if len(query) > len(candidate) {
		return m
	}
	if len(query) == 0 {
		m.matches = true
		return m
	}
	if !pretest_passed {
		return m
	}
	res, ok := ranked_match_subsequence_match(candidate, query)
	if !ok {
		return m
	}
	m.matches = true
	m.max_index = res.max_index
	if res.single_word {
		m.flags += {.Single_Word}
	}
	base := ranked_match_basename_start(candidate)
	if base == 0 {
		m.flags += {.Base_Name}
	} else if _, bok := ranked_match_subsequence_match(candidate[base:], query); bok {
		m.flags += {.Base_Name}
	}
	if .Base_Name in m.flags {
		basename := candidate[base:]
		if len(basename) >= len(query) {
			prefix := true
			qpos := 0
			bpos := 0
			for qpos < len(query) {
				if bpos >= len(basename) {
					prefix = false
					break
				}
				qc := ranked_match_read_codepoint(query, &qpos)
				bc := ranked_match_read_codepoint(basename, &bpos)
				if !ranked_match_smartcase_eq(bc, qc) {
					prefix = false
					break
				}
			}
			if prefix {
				m.flags += {.Prefix}
			}
		}
	}
	if cpos, cfound := ranked_match_find_contiguous(candidate, query); cfound {
		m.flags += {.Contiguous}
		all_word := true
		qpos := 0
		for qpos < len(query) {
			qc := ranked_match_read_codepoint(query, &qpos)
			if !ranked_match_is_word(qc) {
				all_word = false
				break
			}
		}
		if all_word {
			m.flags += {.Single_Word}
		}
		if cpos == 0 {
			m.flags += {.Prefix}
			if len(query) == len(candidate) {
				m.flags += {.Smart_Full_Match}
				if candidate == query {
					m.flags += {.Full_Match}
				}
			}
		}
	}
	m.full_word_match_count = ranked_match_count_full_word_match(candidate, query)
	m.word_boundary_match_count = ranked_match_count_word_boundaries(candidate, query)
	// NOTE: the C++ compares the codepoint-based count against the byte
	// length of the query; keep that exact (odd for multibyte queries).
	if m.word_boundary_match_count == len(query) {
		m.flags += {.Only_Word_Boundary}
	}
	return m
}

ranked_match_make :: proc(candidate, query: string) -> Ranked_Match {
	return ranked_match_make_impl(candidate, query, true)
}

ranked_match_make_with_letters :: proc(
	candidate: string,
	candidate_letters: Ranked_Match_Used_Letters,
	query: string,
	query_letters: Ranked_Match_Used_Letters,
) -> Ranked_Match {
	pretest :=
		ranked_match_matches(
			ranked_match_to_lower_letters(query_letters),
			ranked_match_to_lower_letters(candidate_letters),
		) &&
		ranked_match_matches(
			query_letters & ranked_match_UPPER_MASK,
			candidate_letters & ranked_match_UPPER_MASK,
		)
	return ranked_match_make_impl(candidate, query, pretest)
}

ranked_match_set_input_sequence_number :: proc(m: ^Ranked_Match, i: uint) {
	m.input_sequence_number = i
}

// Numeric value of a flag set with the C++ bit positions.
ranked_match_flags_value :: proc(flags: Ranked_Match_Flags) -> int {
	v := 0
	if .Single_Word in flags {
		v |= 1 << 0
	}
	if .Contiguous in flags {
		v |= 1 << 1
	}
	if .Only_Word_Boundary in flags {
		v |= 1 << 2
	}
	if .Prefix in flags {
		v |= 1 << 3
	}
	if .Base_Name in flags {
		v |= 1 << 4
	}
	if .Smart_Full_Match in flags {
		v |= 1 << 5
	}
	if .Full_Match in flags {
		v |= 1 << 6
	}
	return v
}

ranked_match_is_tiebreak_word_boundary :: proc(prev, c: rune) -> bool {
	return ranked_match_is_word_strict(prev) != ranked_match_is_word_strict(c) ||
		ranked_match_is_lower(prev) != ranked_match_is_lower(c)
}

ranked_match_order_codepoint :: proc(cp: rune) -> rune {
	if cp == '/' {
		return 0
	}
	return cp
}

ranked_match_candidate_less :: proc(a, b: string) -> bool {
	i, j := 0, 0
	last_i, last_j := 0, 0
	for {
		for i < len(a) && j < len(b) && a[i] == b[j] {
			i += 1
			j += 1
		}
		if i >= len(a) || j >= len(b) {
			return i >= len(a) && j < len(b)
		}
		i = ranked_match_character_start(a, i, last_i)
		j = ranked_match_character_start(b, j, last_j)
		save_i, save_j := i, j
		cp1 := ranked_match_read_codepoint(a, &i)
		cp2 := ranked_match_read_codepoint(b, &j)
		if cp1 != cp2 {
			cplast1 := ranked_match_prev_codepoint(a, save_i, 0)
			cplast2 := ranked_match_prev_codepoint(b, save_j, 0)
			is_wb1 := ranked_match_is_tiebreak_word_boundary(cplast1, cp1)
			is_wb2 := ranked_match_is_tiebreak_word_boundary(cplast2, cp2)
			if is_wb1 != is_wb2 {
				return is_wb1
			}
			low1 := ranked_match_is_lower(cp1)
			low2 := ranked_match_is_lower(cp2)
			if low1 != low2 {
				return low1
			}
			return ranked_match_order_codepoint(cp1) < ranked_match_order_codepoint(cp2)
		}
		last_i, last_j = i, j
	}
}

// Ordering between two matches, mirroring RankedMatch::operator<.
// Both matches must satisfy .matches (kak_assert in the C++).
ranked_match_less :: proc(a, b: Ranked_Match) -> bool {
	assert(a.matches && b.matches)
	av := ranked_match_flags_value(a.flags)
	bv := ranked_match_flags_value(b.flags)
	if av != bv {
		diff := av ~ bv
		return (av & diff) > (bv & diff)
	}
	if .Prefix not_in a.flags && .Single_Word not_in a.flags &&
	   a.word_boundary_match_count != b.word_boundary_match_count {
		return a.word_boundary_match_count > b.word_boundary_match_count
	}
	if a.full_word_match_count != b.full_word_match_count {
		return a.full_word_match_count > b.full_word_match_count
	}
	if a.max_index != b.max_index {
		return a.max_index < b.max_index
	}
	if a.input_sequence_number != b.input_sequence_number {
		return a.input_sequence_number < b.input_sequence_number
	}
	return ranked_match_candidate_less(a.candidate, b.candidate)
}
