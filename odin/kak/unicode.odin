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
unicode_is_word :: proc(cp: rune, extra_word_chars: []rune, word_type: Unicode_Word_Type = .Word) -> bool {
	if word_type == .Big_Word {
		return !unicode_is_blank(cp)
	}
	if cp < 128 {
		if unicode_is_basic_alpha(cp) || unicode_is_basic_digit(cp) {
			return true
		}
	} else if unicode.is_letter(cp) || unicode.is_number(cp) {
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
unicode_to_lower :: proc(cp: rune) -> rune {
	if cp < 128 {
		return rune(unicode_to_lower_byte(byte(cp)))
	}
	return unicode.to_lower(cp)
}

// unicode_to_upper uppercases cp: ASCII by table, the rest by
// Unicode simple case mapping (C++ `towupper` in a UTF-8 locale).
unicode_to_upper :: proc(cp: rune) -> rune {
	if cp < 128 {
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
