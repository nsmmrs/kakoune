package kak

import "core:testing"

// Port of UnitTest test_utf8 from src/unit_tests.cc.
@(test)
utf8_test_distance_and_codepoint :: proc(t: ^testing.T) {
	str := "maïs mélange bientôt"
	testing.expect_value(t, utf8_distance(str), 20)
	testing.expect_value(t, utf8_codepoint(str, 2), rune(0x00EF))
}

@(test)
utf8_test_is_character_start :: proc(t: ^testing.T) {
	testing.expect(t, utf8_is_character_start(0x41))
	testing.expect(t, utf8_is_character_start(0x00))
	testing.expect(t, utf8_is_character_start(0x7F))
	testing.expect(t, utf8_is_character_start(0xC3))
	testing.expect(t, utf8_is_character_start(0xE2))
	testing.expect(t, utf8_is_character_start(0xF0))
	testing.expect(t, !utf8_is_character_start(0x80))
	testing.expect(t, !utf8_is_character_start(0xAF))
	testing.expect(t, !utf8_is_character_start(0xBF))
	testing.expect(t, utf8_is_character_start(0xFE))
	testing.expect(t, utf8_is_character_start(0xFF))
}

@(test)
utf8_test_read_codepoint_widths :: proc(t: ^testing.T) {
	s := "Aé€𝄞" // U+0041, U+00E9, U+20AC, U+1D11E
	pos := 0
	testing.expect_value(t, utf8_read_codepoint(s, &pos), rune(0x41))
	testing.expect_value(t, pos, 1)
	testing.expect_value(t, utf8_read_codepoint(s, &pos), rune(0xE9))
	testing.expect_value(t, pos, 3)
	testing.expect_value(t, utf8_read_codepoint(s, &pos), rune(0x20AC))
	testing.expect_value(t, pos, 6)
	testing.expect_value(t, utf8_read_codepoint(s, &pos), rune(0x1D11E))
	testing.expect_value(t, pos, 10)
}

@(test)
utf8_test_read_codepoint_does_not_advance_peek :: proc(t: ^testing.T) {
	s := "é"
	testing.expect_value(t, utf8_codepoint(s, 0), rune(0xE9))
	testing.expect_value(t, utf8_codepoint(s, 0), rune(0xE9))
}

@(test)
utf8_test_empty_input :: proc(t: ^testing.T) {
	testing.expect_value(t, utf8_distance(""), 0)
	testing.expect_value(t, utf8_codepoint("", 0), rune(-1))
	pos := 0
	testing.expect_value(t, utf8_read_codepoint("", &pos), rune(-1))
	testing.expect_value(t, pos, 0)
	testing.expect_value(t, utf8_next("", 0), 0)
	testing.expect_value(t, utf8_previous("", 0), 0)
	testing.expect_value(t, utf8_prev_codepoint("", 0), rune(-1))
}

@(test)
utf8_test_invalid_bytes_pass_policy :: proc(t: ^testing.T) {
	// Lone continuation and 0xFE/0xFF yield the sign-extended byte.
	testing.expect_value(t, utf8_codepoint("\x80", 0), rune(-128))
	testing.expect_value(t, utf8_codepoint("\xbf", 0), rune(-65))
	testing.expect_value(t, utf8_codepoint("\xfe", 0), rune(-2))
	testing.expect_value(t, utf8_codepoint("\xff", 0), rune(-1))
	// A 2-byte lead with no continuation yields the sign-extended lead.
	testing.expect_value(t, utf8_codepoint("\xc3", 0), rune(-61))
	// Truncated 3-byte sequence yields the partial codepoint.
	// 0xE2 0x82: (0x02 << 12) | (0x02 << 6) = 0x2080.
	testing.expect_value(t, utf8_codepoint("\xe2\x82", 0), rune(0x2080))
	// Truncated 4-byte sequence after two bytes.
	// 0xF0 0x9D: (0x00 << 18) | (0x1D << 12) = 0x1D000.
	testing.expect_value(t, utf8_codepoint("\xf0\x9d", 0), rune(0x1D000))
	// Truncated 4-byte sequence after three bytes.
	// 0xF0 0x9D 0x84: 0x1D000 | (0x04 << 6) = 0x1D100.
	testing.expect_value(t, utf8_codepoint("\xf0\x9d\x84", 0), rune(0x1D100))
	// Continuation bytes are masked, never validated: 0xC3 0x28
	// decodes with 0x28 & 0x3F as the low bits.
	testing.expect_value(t, utf8_codepoint("\xc3\x28", 0), rune(0xE8))
}

@(test)
utf8_test_codepoint_size_byte :: proc(t: ^testing.T) {
	testing.expect_value(t, utf8_codepoint_size_byte(0x00), 1)
	testing.expect_value(t, utf8_codepoint_size_byte(0x7F), 1)
	testing.expect_value(t, utf8_codepoint_size_byte(0xC0), 2)
	testing.expect_value(t, utf8_codepoint_size_byte(0xDF), 2)
	testing.expect_value(t, utf8_codepoint_size_byte(0xE0), 3)
	testing.expect_value(t, utf8_codepoint_size_byte(0xEF), 3)
	testing.expect_value(t, utf8_codepoint_size_byte(0xF0), 4)
	testing.expect_value(t, utf8_codepoint_size_byte(0xF7), 4)
	// Invalid lead bytes report size 1 under the pass policy.
	testing.expect_value(t, utf8_codepoint_size_byte(0x80), 1)
	testing.expect_value(t, utf8_codepoint_size_byte(0xBF), 1)
	testing.expect_value(t, utf8_codepoint_size_byte(0xF8), 1)
	testing.expect_value(t, utf8_codepoint_size_byte(0xFF), 1)
}

@(test)
utf8_test_codepoint_size_cp :: proc(t: ^testing.T) {
	testing.expect_value(t, utf8_codepoint_size_cp(0x00), 1)
	testing.expect_value(t, utf8_codepoint_size_cp(0x7F), 1)
	testing.expect_value(t, utf8_codepoint_size_cp(0x80), 2)
	testing.expect_value(t, utf8_codepoint_size_cp(0x7FF), 2)
	testing.expect_value(t, utf8_codepoint_size_cp(0x800), 3)
	testing.expect_value(t, utf8_codepoint_size_cp(0xFFFF), 3)
	testing.expect_value(t, utf8_codepoint_size_cp(0x10000), 4)
	testing.expect_value(t, utf8_codepoint_size_cp(0x10FFFF), 4)
	testing.expect_value(t, utf8_codepoint_size_cp(0x110000), 0)
	testing.expect_value(t, utf8_codepoint_size_cp(0x1FFFFF), 0)
	// Signed comparison: negatives take the 1-byte branch.
	testing.expect_value(t, utf8_codepoint_size_cp(rune(-1)), 1)
}

@(test)
utf8_test_next_previous_finish :: proc(t: ^testing.T) {
	s := "aé€" // starts at bytes 0, 1, 3; len 6
	testing.expect_value(t, utf8_next(s, 0), 1)
	testing.expect_value(t, utf8_next(s, 1), 3)
	testing.expect_value(t, utf8_next(s, 3), 6)
	testing.expect_value(t, utf8_next(s, 6), 6)
	testing.expect_value(t, utf8_next(s, 2), 3) // mid-char skips ahead
	testing.expect_value(t, utf8_previous(s, 6), 3)
	testing.expect_value(t, utf8_previous(s, 3), 1)
	testing.expect_value(t, utf8_previous(s, 1), 0)
	testing.expect_value(t, utf8_previous(s, 0), 0)
	testing.expect_value(t, utf8_previous(s, 2), 1) // mid-char backs up
	testing.expect_value(t, utf8_finish(s, 0), 0)
	testing.expect_value(t, utf8_finish(s, 1), 1)
	testing.expect_value(t, utf8_finish(s, 2), 3)
	testing.expect_value(t, utf8_finish(s, 4), 6)
	testing.expect_value(t, utf8_finish(s, 6), 6)
}

@(test)
utf8_test_advance :: proc(t: ^testing.T) {
	s := "aé€x" // starts at bytes 0, 1, 3, 6; len 7
	testing.expect_value(t, utf8_advance(s, 0, 0), 0)
	testing.expect_value(t, utf8_advance(s, 0, 1), 1)
	testing.expect_value(t, utf8_advance(s, 0, 2), 3)
	testing.expect_value(t, utf8_advance(s, 0, 4), 7)
	testing.expect_value(t, utf8_advance(s, 0, 99), 7) // clamps at end
	testing.expect_value(t, utf8_advance(s, 6, -1), 3)
	testing.expect_value(t, utf8_advance(s, 6, -3), 0)
	testing.expect_value(t, utf8_advance(s, 1, -99), 0) // clamps at 0
	testing.expect_value(t, utf8_advance(s, 0, -1), 0)
	// Like C++, advancing from end returns end unchanged.
	testing.expect_value(t, utf8_advance(s, 7, -1), 7)
	testing.expect_value(t, utf8_advance(s, 7, 2), 7)
}

@(test)
utf8_test_distance :: proc(t: ^testing.T) {
	testing.expect_value(t, utf8_distance("hello"), 5)
	testing.expect_value(t, utf8_distance("aé€𝄞"), 4)
	testing.expect_value(t, utf8_distance("\x80\x80"), 0) // no starts
	testing.expect_value(t, utf8_distance("a\x80b"), 2)
}

@(test)
utf8_test_character_start_and_prev_codepoint :: proc(t: ^testing.T) {
	s := "aé€" // starts at bytes 0, 1, 3; len 6
	testing.expect_value(t, utf8_character_start(s, 0), 0)
	testing.expect_value(t, utf8_character_start(s, 1), 1)
	testing.expect_value(t, utf8_character_start(s, 2), 1)
	testing.expect_value(t, utf8_character_start(s, 4), 3)
	testing.expect_value(t, utf8_character_start(s, 5), 3)
	testing.expect_value(t, utf8_prev_codepoint(s, 0), rune(-1))
	testing.expect_value(t, utf8_prev_codepoint(s, 1), rune(0x61))
	testing.expect_value(t, utf8_prev_codepoint(s, 3), rune(0xE9))
	testing.expect_value(t, utf8_prev_codepoint(s, 6), rune(0x20AC))
	// Decode is bounded at pos: the byte after pos is not consumed.
	testing.expect_value(t, utf8_prev_codepoint("\xc3X", 1), rune(-61))
}

@(test)
utf8_test_dump_roundtrip :: proc(t: ^testing.T) {
	cases := []rune{0x00, 0x41, 0x7F, 0x80, 0x7FF, 0x800, 0x20AC, 0xFFFF, 0x10000, 0x1D11E, 0x10FFFF}
	buf: [4]byte
	for cp in cases {
		n := utf8_dump(cp, buf[:])
		testing.expect_value(t, n, utf8_codepoint_size_cp(cp))
		testing.expect(t, n > 0)
		pos := 0
		testing.expect_value(t, utf8_read_codepoint(string(buf[:n]), &pos), cp)
		testing.expect_value(t, pos, n)
	}
}

@(test)
utf8_test_dump_exact_bytes :: proc(t: ^testing.T) {
	buf: [4]byte
	n := utf8_dump(0xE9, buf[:])
	testing.expect_value(t, n, 2)
	testing.expect_value(t, buf[0], byte(0xC3))
	testing.expect_value(t, buf[1], byte(0xA9))
	n = utf8_dump(0x20AC, buf[:])
	testing.expect_value(t, n, 3)
	testing.expect_value(t, buf[0], byte(0xE2))
	testing.expect_value(t, buf[1], byte(0x82))
	testing.expect_value(t, buf[2], byte(0xAC))
	n = utf8_dump(0x1D11E, buf[:])
	testing.expect_value(t, n, 4)
	testing.expect_value(t, buf[0], byte(0xF0))
	testing.expect_value(t, buf[1], byte(0x9D))
	testing.expect_value(t, buf[2], byte(0x84))
	testing.expect_value(t, buf[3], byte(0x9E))
}

@(test)
utf8_test_dump_invalid :: proc(t: ^testing.T) {
	buf: [4]byte
	buf[0] = 0xAA
	testing.expect_value(t, utf8_dump(0x110000, buf[:]), 0)
	testing.expect_value(t, buf[0], byte(0xAA)) // untouched
	testing.expect_value(t, utf8_dump(0xE9, buf[:1]), 0) // too small
	// Negative codepoints take the 1-byte branch like C++.
	testing.expect_value(t, utf8_dump(rune(-1), buf[:]), 1)
	testing.expect_value(t, buf[0], byte(0xFF))
}
