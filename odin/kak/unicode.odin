// Unicode character classification ported from src/unicode.hh.
//
// Codepoints are plain `rune` and widths plain `int`, matching the
// merged utf8 module's rune-based API; `ConstArrayView<Codepoint>`
// parameters become `[]rune` slices. The libc wide-character calls
// (`iswalnum`, `towlower`, `wcwidth`, ...) are locale-dependent, so
// they are replaced by locale-independent `core:unicode` tables (see
// deviations below). Nothing here allocates.
package kak

import "core:unicode"

// Unicode_Word_Type selects vi word (`Word`: alphanumeric plus
// extra_word_chars) versus blank-delimited `Big_Word` (C++ `WORD`).
Unicode_Word_Type :: enum {
	Word,
	Big_Word,
}

// Unicode_Char_Categories classifies a codepoint for cursor motion
// and selection (C++ `CharCategories`).
Unicode_Char_Categories :: enum {
	Blank,
	End_Of_Line,
	Word,
	Punctuation,
}

// unicode_is_eol reports whether cp is a line terminator for buffer
// purposes (LF only).
unicode_is_eol :: proc(cp: rune) -> bool {
	return cp == '\n'
}

// unicode_is_horizontal_blank reports whether cp is ECMA-whitespace
// minus vertical tab (C++ `is_horizontal_blank`).
unicode_is_horizontal_blank :: proc(cp: rune) -> bool {
	return cp == '\t' || cp == '\f' || cp == ' ' ||
		cp == 0x00A0 || cp == 0xFEFF || cp == 0x1680 ||
		cp == 0x2000 || cp == 0x2001 || cp == 0x2002 || cp == 0x2003 ||
		cp == 0x2004 || cp == 0x2005 || cp == 0x2006 || cp == 0x2007 ||
		cp == 0x2008 || cp == 0x2009 || cp == 0x200A || cp == 0x2028 ||
		cp == 0x2029 || cp == 0x202F || cp == 0x205F || cp == 0x3000
}

// unicode_is_blank reports whether cp is an ECMA line terminator,
// vertical tab, or horizontal blank (C++ `is_blank`).
unicode_is_blank :: proc(cp: rune) -> bool {
	return cp == '\n' || cp == '\r' || cp == '\v' ||
		cp == 0x2028 || cp == 0x2029 || unicode_is_horizontal_blank(cp)
}

// unicode_is_basic_alpha reports whether cp is ASCII [a-zA-Z].
unicode_is_basic_alpha :: proc(cp: rune) -> bool {
	return (cp >= 'a' && cp <= 'z') || (cp >= 'A' && cp <= 'Z')
}

// unicode_is_basic_digit reports whether cp is ASCII [0-9].
unicode_is_basic_digit :: proc(cp: rune) -> bool {
	return cp >= '0' && cp <= '9'
}

// unicode_is_word reports whether cp is part of a word: ASCII
// alphanumerics, non-ASCII alphanumerics, or one of
// extra_word_chars (C++ default: `{'_'}`). With `.Big_Word` any
// non-blank codepoint is a word character.
//
// Deviation: C++ uses locale-dependent `iswalnum`; here a codepoint
// is alphanumeric when `core:unicode` classifies it as a letter or
// a number.
// unicode_alnum_extra_ranges covers the non-ASCII codepoints where glibc
// iswalnum (en_US.utf8) is true but the codepoint is neither a Unicode
// letter nor a decimal digit: letter numbers (Nl, e.g. Roman numerals)
// and letter-like marks (vowel signs, Hebrew points, ...). Generic
// diacritics (U+0300 block) and other numbers (No, e.g. superscripts,
// fractions) are NOT alphanumeric in glibc, even though core:unicode
// reports them as marks/numbers. Derived by exhaustive probing of
// iswalnum over U+0000..U+10FFFF against core:unicode queries; the
// predicate below agrees with glibc on every codepoint.
// 1586 codepoints in 263 sorted ranges.
@(private)
unicode_alnum_extra_ranges := [?][2]rune{
	{0x363, 0x36F},
	{0x5B0, 0x5BD},
	{0x5BF, 0x5BF},
	{0x5C1, 0x5C2},
	{0x5C4, 0x5C5},
	{0x5C7, 0x5C7},
	{0x610, 0x61A},
	{0x64B, 0x657},
	{0x659, 0x65F},
	{0x670, 0x670},
	{0x6D6, 0x6DC},
	{0x6E1, 0x6E4},
	{0x6E7, 0x6E8},
	{0x6ED, 0x6ED},
	{0x711, 0x711},
	{0x730, 0x73F},
	{0x7A6, 0x7B0},
	{0x816, 0x817},
	{0x81B, 0x823},
	{0x825, 0x827},
	{0x829, 0x82C},
	{0x897, 0x897},
	{0x8D4, 0x8DF},
	{0x8E3, 0x8E9},
	{0x8F0, 0x903},
	{0x93A, 0x93B},
	{0x93E, 0x94C},
	{0x94E, 0x94F},
	{0x955, 0x957},
	{0x962, 0x963},
	{0x981, 0x983},
	{0x9BE, 0x9C4},
	{0x9C7, 0x9C8},
	{0x9CB, 0x9CC},
	{0x9D7, 0x9D7},
	{0x9E2, 0x9E3},
	{0xA01, 0xA03},
	{0xA3E, 0xA42},
	{0xA47, 0xA48},
	{0xA4B, 0xA4C},
	{0xA51, 0xA51},
	{0xA70, 0xA71},
	{0xA75, 0xA75},
	{0xA81, 0xA83},
	{0xABE, 0xAC5},
	{0xAC7, 0xAC9},
	{0xACB, 0xACC},
	{0xAE2, 0xAE3},
	{0xAFA, 0xAFC},
	{0xB01, 0xB03},
	{0xB3E, 0xB44},
	{0xB47, 0xB48},
	{0xB4B, 0xB4C},
	{0xB56, 0xB57},
	{0xB62, 0xB63},
	{0xB82, 0xB82},
	{0xBBE, 0xBC2},
	{0xBC6, 0xBC8},
	{0xBCA, 0xBCC},
	{0xBD7, 0xBD7},
	{0xC00, 0xC04},
	{0xC3E, 0xC44},
	{0xC46, 0xC48},
	{0xC4A, 0xC4C},
	{0xC55, 0xC56},
	{0xC62, 0xC63},
	{0xC81, 0xC83},
	{0xCBE, 0xCC4},
	{0xCC6, 0xCC8},
	{0xCCA, 0xCCC},
	{0xCD5, 0xCD6},
	{0xCE2, 0xCE3},
	{0xCF3, 0xCF3},
	{0xD00, 0xD03},
	{0xD3E, 0xD44},
	{0xD46, 0xD48},
	{0xD4A, 0xD4C},
	{0xD57, 0xD57},
	{0xD62, 0xD63},
	{0xD81, 0xD83},
	{0xDCF, 0xDD4},
	{0xDD6, 0xDD6},
	{0xDD8, 0xDDF},
	{0xDF2, 0xDF3},
	{0xE31, 0xE31},
	{0xE34, 0xE3A},
	{0xE4D, 0xE4D},
	{0xEB1, 0xEB1},
	{0xEB4, 0xEB9},
	{0xEBB, 0xEBC},
	{0xECD, 0xECD},
	{0xF71, 0xF83},
	{0xF8D, 0xF97},
	{0xF99, 0xFBC},
	{0x102B, 0x1036},
	{0x1038, 0x1038},
	{0x103B, 0x103E},
	{0x1056, 0x1059},
	{0x105E, 0x1060},
	{0x1062, 0x1064},
	{0x1067, 0x106D},
	{0x1071, 0x1074},
	{0x1082, 0x108D},
	{0x108F, 0x108F},
	{0x109A, 0x109D},
	{0x16EE, 0x16F0},
	{0x1712, 0x1713},
	{0x1732, 0x1733},
	{0x1752, 0x1753},
	{0x1772, 0x1773},
	{0x17B6, 0x17C8},
	{0x1885, 0x1886},
	{0x18A9, 0x18A9},
	{0x1920, 0x192B},
	{0x1930, 0x1938},
	{0x1A17, 0x1A1B},
	{0x1A55, 0x1A5E},
	{0x1A61, 0x1A74},
	{0x1ABF, 0x1AC0},
	{0x1ACC, 0x1ACE},
	{0x1B00, 0x1B04},
	{0x1B35, 0x1B43},
	{0x1B80, 0x1B82},
	{0x1BA1, 0x1BA9},
	{0x1BAC, 0x1BAD},
	{0x1BE7, 0x1BF1},
	{0x1C24, 0x1C36},
	{0x1DD3, 0x1DF4},
	{0x2180, 0x2182},
	{0x2185, 0x2188},
	{0x2DE0, 0x2DFF},
	{0x3007, 0x3007},
	{0x3021, 0x3029},
	{0x3038, 0x303A},
	{0xA674, 0xA67B},
	{0xA69E, 0xA69F},
	{0xA6E6, 0xA6EF},
	{0xA802, 0xA802},
	{0xA80B, 0xA80B},
	{0xA823, 0xA827},
	{0xA880, 0xA881},
	{0xA8B4, 0xA8C3},
	{0xA8C5, 0xA8C5},
	{0xA8FF, 0xA8FF},
	{0xA926, 0xA92A},
	{0xA947, 0xA952},
	{0xA980, 0xA983},
	{0xA9B4, 0xA9BF},
	{0xA9E5, 0xA9E5},
	{0xAA29, 0xAA36},
	{0xAA43, 0xAA43},
	{0xAA4C, 0xAA4D},
	{0xAA7B, 0xAA7D},
	{0xAAB0, 0xAAB0},
	{0xAAB2, 0xAAB4},
	{0xAAB7, 0xAAB8},
	{0xAABE, 0xAABE},
	{0xAAEB, 0xAAEF},
	{0xAAF5, 0xAAF5},
	{0xABE3, 0xABEA},
	{0xFB1E, 0xFB1E},
	{0x10140, 0x10174},
	{0x10341, 0x10341},
	{0x1034A, 0x1034A},
	{0x10376, 0x1037A},
	{0x103D1, 0x103D5},
	{0x10A01, 0x10A03},
	{0x10A05, 0x10A06},
	{0x10A0C, 0x10A0F},
	{0x10D24, 0x10D27},
	{0x10D69, 0x10D69},
	{0x10EAB, 0x10EAC},
	{0x10EFA, 0x10EFC},
	{0x11000, 0x11002},
	{0x11038, 0x11045},
	{0x11073, 0x11074},
	{0x11080, 0x11082},
	{0x110B0, 0x110B8},
	{0x110C2, 0x110C2},
	{0x11100, 0x11102},
	{0x11127, 0x11132},
	{0x11145, 0x11146},
	{0x11180, 0x11182},
	{0x111B3, 0x111BF},
	{0x111CE, 0x111CF},
	{0x1122C, 0x11234},
	{0x11237, 0x11237},
	{0x1123E, 0x1123E},
	{0x11241, 0x11241},
	{0x112DF, 0x112E8},
	{0x11300, 0x11303},
	{0x1133E, 0x11344},
	{0x11347, 0x11348},
	{0x1134B, 0x1134C},
	{0x11357, 0x11357},
	{0x11362, 0x11363},
	{0x113B8, 0x113C0},
	{0x113C2, 0x113C2},
	{0x113C5, 0x113C5},
	{0x113C7, 0x113CA},
	{0x113CC, 0x113CD},
	{0x11435, 0x11441},
	{0x11443, 0x11445},
	{0x114B0, 0x114C1},
	{0x115AF, 0x115B5},
	{0x115B8, 0x115BE},
	{0x115DC, 0x115DD},
	{0x11630, 0x1163E},
	{0x11640, 0x11640},
	{0x116AB, 0x116B5},
	{0x1171D, 0x1172A},
	{0x1182C, 0x11838},
	{0x11930, 0x11935},
	{0x11937, 0x11938},
	{0x1193B, 0x1193C},
	{0x11940, 0x11940},
	{0x11942, 0x11942},
	{0x119D1, 0x119D7},
	{0x119DA, 0x119DF},
	{0x119E4, 0x119E4},
	{0x11A01, 0x11A0A},
	{0x11A35, 0x11A39},
	{0x11A3B, 0x11A3E},
	{0x11A51, 0x11A5B},
	{0x11A8A, 0x11A97},
	{0x11B60, 0x11B67},
	{0x11C2F, 0x11C36},
	{0x11C38, 0x11C3E},
	{0x11C92, 0x11CA7},
	{0x11CA9, 0x11CB6},
	{0x11D31, 0x11D36},
	{0x11D3A, 0x11D3A},
	{0x11D3C, 0x11D3D},
	{0x11D3F, 0x11D41},
	{0x11D43, 0x11D43},
	{0x11D47, 0x11D47},
	{0x11D8A, 0x11D8E},
	{0x11D90, 0x11D91},
	{0x11D93, 0x11D96},
	{0x11EF3, 0x11EF6},
	{0x11F00, 0x11F01},
	{0x11F03, 0x11F03},
	{0x11F34, 0x11F3A},
	{0x11F3E, 0x11F40},
	{0x12400, 0x1246E},
	{0x1611E, 0x1612E},
	{0x16F4F, 0x16F4F},
	{0x16F51, 0x16F87},
	{0x16F8F, 0x16F92},
	{0x16FF0, 0x16FF1},
	{0x16FF4, 0x16FF6},
	{0x1BC9E, 0x1BC9E},
	{0x1E000, 0x1E006},
	{0x1E008, 0x1E018},
	{0x1E01B, 0x1E021},
	{0x1E023, 0x1E024},
	{0x1E026, 0x1E02A},
	{0x1E08F, 0x1E08F},
	{0x1E6E3, 0x1E6E3},
	{0x1E6E6, 0x1E6E6},
	{0x1E6EE, 0x1E6EF},
	{0x1E6F5, 0x1E6F5},
	{0x1E947, 0x1E947},
}

// unicode_is_alnum mirrors libc iswalnum in a UTF-8 locale (C++ unicode.hh
// wide path): ASCII letters/digits, Unicode letters, decimal digits, plus
// the letter numbers and letter-like marks in the table above. Negative
// codepoints (orphan bytes) and values past U+10FFFF yield false, like
// iswalnum on invalid input. Verified against glibc exhaustively.
unicode_is_alnum :: proc(cp: rune) -> bool {
	if cp < 128 {
		return unicode_is_basic_alpha(cp) || unicode_is_basic_digit(cp)
	}
	if cp < 0 || cp > 0x10FFFF {
		return false
	}
	if unicode.is_letter(cp) || unicode.is_decimal(cp) {
		return true
	}
	lo, hi := 0, len(unicode_alnum_extra_ranges)
	for lo < hi {
		mid := (lo + hi) / 2
		if cp < unicode_alnum_extra_ranges[mid][0] {
			hi = mid
		} else if cp > unicode_alnum_extra_ranges[mid][1] {
			lo = mid + 1
		} else {
			return true
		}
	}
	return false
}

unicode_is_word :: proc(cp: rune, extra_word_chars: []rune, word_type: Unicode_Word_Type = .Word) -> bool {
	if word_type == .Big_Word {
		return !unicode_is_blank(cp)
	}
	// unicode_is_alnum mirrors iswalnum exactly (verified exhaustively
	// against glibc); negatives fail inside, like iswalnum(invalid).
	if unicode_is_alnum(cp) {
		return true
	}
	for extra in extra_word_chars {
		if cp == extra {
			return true
		}
	}
	return false
}

// unicode_is_punctuation reports whether cp is neither a word
// character (always `Word` type, as in C++) nor blank.
unicode_is_punctuation :: proc(cp: rune, extra_word_chars: []rune) -> bool {
	return !unicode_is_word(cp, extra_word_chars) && !unicode_is_blank(cp)
}

// unicode_is_identifier reports whether cp may appear in an
// identifier: ASCII alphanumeric, '_' or '-'.
unicode_is_identifier :: proc(cp: rune) -> bool {
	return unicode_is_basic_alpha(cp) || unicode_is_basic_digit(cp) ||
		cp == '_' || cp == '-'
}

// unicode_codepoint_width returns the terminal column width of cp:
// 1 for ASCII, otherwise the East Asian width (0 for combining and
// zero-width codepoints, 2 for wide/fullwidth, 1 otherwise), with
// control codepoints mapped to 1 as the C++ `wcwidth`-negative
// fallback does. Same semantics as `string_utils_codepoint_width`.
//
// Deviation: C++ uses libc `wcwidth`, which is locale- and
// libc-dependent; widths here come from `core:unicode` tables.
unicode_codepoint_width :: proc(cp: rune) -> int {
	if cp < 0x80 || unicode.is_control(cp) {
		return 1
	}
	if unicode.is_nonspacing_mark(cp) || unicode.is_enclosing_mark(cp) {
		return 0
	}
	return unicode.normalized_east_asian_width(cp)
}

// unicode_categorize classifies cp as end-of-line, blank, word, or
// punctuation (C++ `categorize`).
unicode_categorize :: proc(cp: rune, extra_word_chars: []rune, word_type: Unicode_Word_Type = .Word) -> Unicode_Char_Categories {
	if unicode_is_eol(cp) {
		return .End_Of_Line
	}
	if unicode_is_horizontal_blank(cp) {
		return .Blank
	}
	if word_type == .Big_Word || unicode_is_word(cp, extra_word_chars) {
		return .Word
	}
	return .Punctuation
}

// unicode_to_lower_byte lowercases an ASCII byte, passing the rest
// through (C++ `to_lower(char)`).
unicode_to_lower_byte :: proc(c: byte) -> byte {
	return c >= 'A' && c <= 'Z' ? c - 'A' + 'a' : c
}

// unicode_to_upper_byte uppercases an ASCII byte, passing the rest
// through (C++ `to_upper(char)`).
unicode_to_upper_byte :: proc(c: byte) -> byte {
	return c >= 'a' && c <= 'z' ? c - 'a' + 'A' : c
}

// unicode_is_lower_byte reports whether c is ASCII [a-z].
unicode_is_lower_byte :: proc(c: byte) -> bool {
	return c >= 'a' && c <= 'z'
}

// unicode_is_upper_byte reports whether c is ASCII [A-Z].
unicode_is_upper_byte :: proc(c: byte) -> bool {
	return c >= 'A' && c <= 'Z'
}

// unicode_to_lower lowercases cp: ASCII by table, the rest by
// Unicode simple case mapping (C++ `towlower` in a UTF-8 locale).
// The limit compares unsigned like the C++ char32_t Codepoint, so
// negative codepoints (orphan bytes) take the wide path and pass
// through unchanged instead of wrapping to a Latin-1 letter.
unicode_to_lower :: proc(cp: rune) -> rune {
	if u32(cp) < 128 {
		return rune(unicode_to_lower_byte(byte(cp)))
	}
	return unicode.to_lower(cp)
}

// unicode_to_upper uppercases cp: ASCII by table, the rest by
// Unicode simple case mapping (C++ `towupper` in a UTF-8 locale).
// The limit compares unsigned (see unicode_to_lower).
unicode_to_upper :: proc(cp: rune) -> rune {
	if u32(cp) < 128 {
		return rune(unicode_to_upper_byte(byte(cp)))
	}
	return unicode.to_upper(cp)
}

// unicode_is_lower reports whether cp is lowercase: ASCII [a-z], or
// Unicode Lowercase for the rest (C++ `iswlower` in a UTF-8 locale).
unicode_is_lower :: proc(cp: rune) -> bool {
	if cp < 128 {
		return unicode_is_lower_byte(byte(cp))
	}
	return unicode.is_lower(cp)
}

// unicode_is_upper reports whether cp is uppercase: ASCII [A-Z], or
// Unicode Uppercase for the rest (C++ `iswupper` in a UTF-8 locale).
unicode_is_upper :: proc(cp: rune) -> bool {
	if cp < 128 {
		return unicode_is_upper_byte(byte(cp))
	}
	return unicode.is_upper(cp)
}
