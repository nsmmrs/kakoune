// UTF-8 helpers ported from src/utf8.hh.
//
// Byte-slice semantics: C++ iterator pairs (it, end) become a `string`
// plus a byte offset. Sub-ranges are expressed by subslicing at the
// call site. All offsets are byte offsets into `s`; valid range is
// 0 .. len(s). Decoding follows C++ `InvalidPolicy::Pass`: invalid
// or truncated input yields a best-effort value, never an error.
//
// Nothing here allocates.
package kak

// utf8_is_character_start reports whether c can start a character,
// i.e. it is not a UTF-8 continuation byte (10xxxxxx).
utf8_is_character_start :: proc(c: byte) -> bool {
	return c & 0xC0 != 0x80
}

// utf8_read_codepoint decodes the character starting at pos^ and
// advances pos^ past the bytes consumed.
//
// Exact port of the multibyte cascade in read_codepoint_multibyte:
// continuation bytes are masked with 0x3F without validation, the
// 4-byte lead mask is 0x0F (not 0x07), and a truncated sequence
// yields the partial codepoint decoded so far. A lead byte with no
// bytes after it yields the sign-extended lead byte; reading at
// end of input yields rune(-1).
utf8_read_codepoint :: proc(s: string, pos: ^int) -> rune {
	if pos^ >= len(s) {
		return rune(-1)
	}
	lead := s[pos^]
	pos^ += 1
	if lead & 0x80 == 0 {
		return rune(lead)
	}
	if pos^ >= len(s) {
		return rune(i8(lead))
	}
	if lead & 0xE0 == 0xC0 {
		cont := s[pos^]
		pos^ += 1
		return rune(lead & 0x1F) << 6 | rune(cont & 0x3F)
	}
	if lead & 0xF0 == 0xE0 {
		cont := s[pos^]
		pos^ += 1
		cp := rune(lead & 0x0F) << 12 | rune(cont & 0x3F) << 6
		if pos^ >= len(s) {
			return cp
		}
		last := s[pos^]
		pos^ += 1
		return cp | rune(last & 0x3F)
	}
	if lead & 0xF8 == 0xF0 {
		cont := s[pos^]
		pos^ += 1
		cp := rune(lead & 0x0F) << 18 | rune(cont & 0x3F) << 12
		if pos^ >= len(s) {
			return cp
		}
		cont2 := s[pos^]
		pos^ += 1
		cp |= rune(cont2 & 0x3F) << 6
		if pos^ >= len(s) {
			return cp
		}
		last := s[pos^]
		pos^ += 1
		return cp | rune(last & 0x3F)
	}
	return rune(i8(lead))
}

// utf8_codepoint decodes the character starting at byte offset pos
// without advancing. Reading at end of input yields rune(-1).
utf8_codepoint :: proc(s: string, pos: int) -> rune {
	p := pos
	return utf8_read_codepoint(s, &p)
}

// utf8_codepoint_size_byte returns the encoded length implied by a
// lead byte: 1-4, or 1 for a byte that starts no valid sequence
// (continuation bytes, 0xF8-0xFF), matching codepoint_size(char)
// under InvalidPolicy::Pass.
utf8_codepoint_size_byte :: proc(b: byte) -> int {
	if b & 0x80 == 0 {
		return 1
	} else if b & 0xE0 == 0xC0 {
		return 2
	} else if b & 0xF0 == 0xE0 {
		return 3
	} else if b & 0xF8 == 0xF0 {
		return 4
	}
	return 1
}

// utf8_codepoint_size_cp returns the encoded length of a codepoint:
// 1-4, or 0 when cp exceeds U+10FFFF, matching codepoint_size(cp)
// under InvalidPolicy::Pass. Negative codepoints yield 1, as the
// C++ comparison `cp <= 0x7F` is signed.
utf8_codepoint_size_cp :: proc(cp: rune) -> int {
	if cp <= 0x7F {
		return 1
	} else if cp <= 0x7FF {
		return 2
	} else if cp <= 0xFFFF {
		return 3
	} else if cp <= 0x10FFFF {
		return 4
	}
	return 0
}

// utf8_next returns the byte offset of the next character start
// after pos (to_next). At end of input it returns len(s).
utf8_next :: proc(s: string, pos: int) -> int {
	p := pos
	if p < len(s) {
		p += 1
	}
	for p < len(s) && !utf8_is_character_start(s[p]) {
		p += 1
	}
	return p
}

// utf8_finish returns pos itself when it points at a character
// start, else the next character start after pos.
utf8_finish :: proc(s: string, pos: int) -> int {
	p := pos
	for p < len(s) && !utf8_is_character_start(s[p]) {
		p += 1
	}
	return p
}

// utf8_previous returns the byte offset of the previous character
// start before pos (to_previous with begin 0). At 0 it returns 0.
utf8_previous :: proc(s: string, pos: int) -> int {
	p := pos
	if p > 0 {
		p -= 1
	}
	for p > 0 && !utf8_is_character_start(s[p]) {
		p -= 1
	}
	return p
}

// utf8_advance returns the byte offset of the character start d
// characters after (d > 0) or before (d < 0) pos. Forward motion
// stops at len(s); backward motion stops at 0. Like the C++
// advance, pos == len(s) is returned unchanged for any d.
utf8_advance :: proc(s: string, pos: int, d: int) -> int {
	if pos == len(s) {
		return pos
	}
	p := pos
	n := d
	if n < 0 {
		for p > 0 && n < 0 {
			p = utf8_previous(s, p)
			n += 1
		}
	} else if n > 0 {
		for p < len(s) && n > 0 {
			p = utf8_next(s, p)
			n -= 1
		}
	}
	return p
}

// utf8_distance returns the character count of s: the number of
// bytes that start a character.
utf8_distance :: proc(s: string) -> int {
	dist := 0
	for i := 0; i < len(s); i += 1 {
		if utf8_is_character_start(s[i]) {
			dist += 1
		}
	}
	return dist
}

// utf8_character_start returns the byte offset of the first byte of
// the character pos is inside of, backing up over continuation
// bytes and stopping at 0.
utf8_character_start :: proc(s: string, pos: int) -> int {
	p := pos
	if p > len(s) {
		p = len(s)
	}
	for p > 0 && (p == len(s) || !utf8_is_character_start(s[p])) {
		p -= 1
	}
	return p
}

// utf8_prev_codepoint decodes the character ending at byte offset
// pos, i.e. the character whose last byte is s[pos-1]. Decoding is
// bounded at pos (matching the C++ end parameter); pos <= 0
// yields rune(-1).
utf8_prev_codepoint :: proc(s: string, pos: int) -> rune {
	if pos <= 0 {
		return rune(-1)
	}
	start := utf8_character_start(s, pos - 1)
	return utf8_codepoint(s[:pos], start)
}

// utf8_dump encodes cp into buf and returns the bytes written.
// buf must hold at least 4 bytes for a full encoding; when it is
// too small, or cp exceeds U+10FFFF, nothing is written and 0 is
// returned (InvalidPolicy::Pass writes nothing for cp > U+10FFFF).
// A negative cp encodes as its single low byte, as in C++.
utf8_dump :: proc(cp: rune, buf: []byte) -> int {
	size := utf8_codepoint_size_cp(cp)
	if size == 0 || len(buf) < size {
		return 0
	}
	if cp <= 0x7F {
		buf[0] = byte(cp)
	} else if cp <= 0x7FF {
		buf[0] = 0xC0 | byte(cp >> 6)
		buf[1] = 0x80 | byte(cp & 0x3F)
	} else if cp <= 0xFFFF {
		buf[0] = 0xE0 | byte(cp >> 12)
		buf[1] = 0x80 | byte((cp >> 6) & 0x3F)
		buf[2] = 0x80 | byte(cp & 0x3F)
	} else {
		buf[0] = 0xF0 | byte(cp >> 18)
		buf[1] = 0x80 | byte((cp >> 12) & 0x3F)
		buf[2] = 0x80 | byte((cp >> 6) & 0x3F)
		buf[3] = 0x80 | byte(cp & 0x3F)
	}
	return size
}
