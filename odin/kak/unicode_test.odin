// Tests for the unicode module. No C++ UnitTest covers src/unicode.hh,
// so these tests pin the C++ predicate tables and case mappings
// directly, plus edge cases.
package kak

import "core:testing"

@(test)
unicode_test_is_eol :: proc(t: ^testing.T) {
	testing.expect(t, unicode_is_eol('\n'))
	testing.expect(t, !unicode_is_eol('\r'))
	testing.expect(t, !unicode_is_eol('\v'))
	testing.expect(t, !unicode_is_eol(0x2028))
	testing.expect(t, !unicode_is_eol('a'))
	testing.expect(t, !unicode_is_eol(0))
}

@(test)
unicode_test_is_horizontal_blank :: proc(t: ^testing.T) {
	blanks := []rune{
		'\t', '\f', ' ',
		0x00A0, 0xFEFF, 0x1680,
		0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005,
		0x2006, 0x2007, 0x2008, 0x2009, 0x200A,
		0x2028, 0x2029, 0x202F, 0x205F, 0x3000,
	}
	for cp in blanks {
		testing.expect(t, unicode_is_horizontal_blank(cp))
	}
	// Vertical tab, line terminators, and ordinary text are excluded.
	testing.expect(t, !unicode_is_horizontal_blank('\v'))
	testing.expect(t, !unicode_is_horizontal_blank('\n'))
	testing.expect(t, !unicode_is_horizontal_blank('\r'))
	testing.expect(t, !unicode_is_horizontal_blank('a'))
	testing.expect(t, !unicode_is_horizontal_blank('_'))
	testing.expect(t, !unicode_is_horizontal_blank(0))
}

@(test)
unicode_test_is_blank :: proc(t: ^testing.T) {
	testing.expect(t, unicode_is_blank('\n'))
	testing.expect(t, unicode_is_blank('\r'))
	testing.expect(t, unicode_is_blank('\v'))
	testing.expect(t, unicode_is_blank(0x2028))
	testing.expect(t, unicode_is_blank(0x2029))
	// Every horizontal blank is also blank.
	testing.expect(t, unicode_is_blank('\t'))
	testing.expect(t, unicode_is_blank('\f'))
	testing.expect(t, unicode_is_blank(' '))
	testing.expect(t, unicode_is_blank(0x00A0))
	testing.expect(t, unicode_is_blank(0x3000))
	testing.expect(t, !unicode_is_blank('a'))
	testing.expect(t, !unicode_is_blank('.'))
	testing.expect(t, !unicode_is_blank(0))
}

@(test)
unicode_test_basic_alpha_digit :: proc(t: ^testing.T) {
	for c in 'a' ..= 'z' {
		testing.expect(t, unicode_is_basic_alpha(c))
		testing.expect(t, !unicode_is_basic_digit(c))
	}
	for c in 'A' ..= 'Z' {
		testing.expect(t, unicode_is_basic_alpha(c))
	}
	for c in '0' ..= '9' {
		testing.expect(t, unicode_is_basic_digit(c))
		testing.expect(t, !unicode_is_basic_alpha(c))
	}
	testing.expect(t, !unicode_is_basic_alpha('_'))
	testing.expect(t, !unicode_is_basic_alpha('é'))
	testing.expect(t, !unicode_is_basic_digit('é'))
}

@(test)
unicode_test_is_word_ascii :: proc(t: ^testing.T) {
	underscore := []rune{'_'}
	testing.expect(t, unicode_is_word('a', underscore))
	testing.expect(t, unicode_is_word('Z', underscore))
	testing.expect(t, unicode_is_word('5', underscore))
	testing.expect(t, unicode_is_word('_', underscore))
	testing.expect(t, !unicode_is_word('-', underscore))
	testing.expect(t, !unicode_is_word('.', underscore))
	testing.expect(t, !unicode_is_word(' ', underscore))
	// No extra word chars: '_' stops being a word char.
	testing.expect(t, !unicode_is_word('_', {}))
	testing.expect(t, unicode_is_word('a', {}))
	// Custom extra word chars (as in `:declare-option` group checks).
	dash := []rune{'-'}
	testing.expect(t, unicode_is_word('-', dash))
	testing.expect(t, !unicode_is_word('_', dash))
}

@(test)
unicode_test_is_word_unicode :: proc(t: ^testing.T) {
	underscore := []rune{'_'}
	testing.expect(t, unicode_is_word('é', underscore))
	testing.expect(t, unicode_is_word('中', underscore))
	testing.expect(t, unicode_is_word('Σ', underscore))
	// Decimal digits beyond ASCII count as alphanumerics.
	testing.expect(t, unicode_is_word(0x0660, underscore)) // Arabic-Indic 0
	testing.expect(t, unicode_is_word(0x2167, underscore)) // Roman numeral VIII
	// ...but other numbers (No) do not: glibc iswalnum excludes them.
	testing.expect(t, !unicode_is_word('²', underscore)) // superscript two
	testing.expect(t, !unicode_is_word('¹', underscore)) // superscript one
	testing.expect(t, !unicode_is_word('¼', underscore)) // vulgar fraction
	// Letter-like marks count; generic diacritics do not (difftest3).
	testing.expect(t, unicode_is_word(0x0345, underscore)) // ypogegrammeni
	testing.expect(t, unicode_is_word(0x05B0, underscore)) // Hebrew point sheva
	testing.expect(t, !unicode_is_word(0x0300, underscore)) // combining grave
	// Symbols, marks, and punctuation are not word characters.
	testing.expect(t, !unicode_is_word('€', underscore))
	testing.expect(t, !unicode_is_word(0x1F600, underscore)) // emoji
	testing.expect(t, !unicode_is_word(0x0301, underscore)) // combining mark
	testing.expect(t, !unicode_is_word(0xD800, underscore)) // surrogate
	testing.expect(t, !unicode_is_word('.', underscore))
	// Non-ASCII extra word chars are honored.
	extra := []rune{'€'}
	testing.expect(t, unicode_is_word('€', extra))
}

@(test)
unicode_test_is_word_big_word :: proc(t: ^testing.T) {
	underscore := []rune{'_'}
	testing.expect(t, unicode_is_word('a', underscore, .Big_Word))
	testing.expect(t, unicode_is_word('.', underscore, .Big_Word))
	testing.expect(t, unicode_is_word('-', underscore, .Big_Word))
	testing.expect(t, unicode_is_word('é', underscore, .Big_Word))
	testing.expect(t, !unicode_is_word(' ', underscore, .Big_Word))
	testing.expect(t, !unicode_is_word('\t', underscore, .Big_Word))
	testing.expect(t, !unicode_is_word('\n', underscore, .Big_Word))
	// Extra word chars are ignored for Big_Word, as in C++.
	testing.expect(t, !unicode_is_word(' ', {}, .Big_Word))
}

@(test)
unicode_test_is_punctuation :: proc(t: ^testing.T) {
	underscore := []rune{'_'}
	testing.expect(t, unicode_is_punctuation('.', underscore))
	testing.expect(t, unicode_is_punctuation('-', underscore))
	testing.expect(t, unicode_is_punctuation('€', underscore))
	testing.expect(t, !unicode_is_punctuation('a', underscore))
	testing.expect(t, !unicode_is_punctuation('5', underscore))
	testing.expect(t, !unicode_is_punctuation('_', underscore))
	testing.expect(t, !unicode_is_punctuation(' ', underscore))
	testing.expect(t, !unicode_is_punctuation('\n', underscore))
	testing.expect(t, !unicode_is_punctuation('é', underscore))
}

@(test)
unicode_test_is_identifier :: proc(t: ^testing.T) {
	testing.expect(t, unicode_is_identifier('a'))
	testing.expect(t, unicode_is_identifier('Z'))
	testing.expect(t, unicode_is_identifier('0'))
	testing.expect(t, unicode_is_identifier('_'))
	testing.expect(t, unicode_is_identifier('-'))
	testing.expect(t, !unicode_is_identifier('.'))
	testing.expect(t, !unicode_is_identifier(' '))
	testing.expect(t, !unicode_is_identifier('é'))
}

@(test)
unicode_test_codepoint_width :: proc(t: ^testing.T) {
	// ASCII is always width 1, including controls.
	testing.expect_value(t, unicode_codepoint_width('A'), 1)
	testing.expect_value(t, unicode_codepoint_width(0), 1)
	testing.expect_value(t, unicode_codepoint_width('\n'), 1)
	testing.expect_value(t, unicode_codepoint_width(0x7F), 1)
	// Latin and narrow scripts are width 1.
	testing.expect_value(t, unicode_codepoint_width('é'), 1)
	testing.expect_value(t, unicode_codepoint_width('Σ'), 1)
	// Wide/fullwidth East Asian codepoints are width 2.
	testing.expect_value(t, unicode_codepoint_width('中'), 2)
	testing.expect_value(t, unicode_codepoint_width(0x1F600), 2)
	// Combining and zero-width codepoints are width 0.
	testing.expect_value(t, unicode_codepoint_width(0x0301), 0)
	testing.expect_value(t, unicode_codepoint_width(0x200B), 0)
	testing.expect_value(t, unicode_codepoint_width(0xFEFF), 0)
	// Non-ASCII controls fall back to 1 (the wcwidth-negative rule).
	testing.expect_value(t, unicode_codepoint_width(0x80), 1)
	testing.expect_value(t, unicode_codepoint_width(0x9F), 1)
}

@(test)
unicode_test_categorize :: proc(t: ^testing.T) {
	underscore := []rune{'_'}
	testing.expect_value(t, unicode_categorize('\n', underscore), Unicode_Char_Categories.End_Of_Line)
	testing.expect_value(t, unicode_categorize(' ', underscore), Unicode_Char_Categories.Blank)
	testing.expect_value(t, unicode_categorize('\t', underscore), Unicode_Char_Categories.Blank)
	testing.expect_value(t, unicode_categorize('a', underscore), Unicode_Char_Categories.Word)
	testing.expect_value(t, unicode_categorize('_', underscore), Unicode_Char_Categories.Word)
	testing.expect_value(t, unicode_categorize('é', underscore), Unicode_Char_Categories.Word)
	testing.expect_value(t, unicode_categorize('.', underscore), Unicode_Char_Categories.Punctuation)
	testing.expect_value(t, unicode_categorize('-', underscore), Unicode_Char_Categories.Punctuation)
	// '\r' is blank but not horizontal blank, so it is punctuation.
	testing.expect_value(t, unicode_categorize('\r', underscore), Unicode_Char_Categories.Punctuation)
	// Big_Word turns punctuation into words but keeps EOL and blanks.
	testing.expect_value(t, unicode_categorize('.', underscore, .Big_Word), Unicode_Char_Categories.Word)
	testing.expect_value(t, unicode_categorize(' ', underscore, .Big_Word), Unicode_Char_Categories.Blank)
	testing.expect_value(t, unicode_categorize('\n', underscore, .Big_Word), Unicode_Char_Categories.End_Of_Line)
}

@(test)
unicode_test_case_bytes :: proc(t: ^testing.T) {
	testing.expect_value(t, unicode_to_lower_byte('A'), 'a')
	testing.expect_value(t, unicode_to_lower_byte('Z'), 'z')
	testing.expect_value(t, unicode_to_lower_byte('a'), 'a')
	testing.expect_value(t, unicode_to_lower_byte('0'), '0')
	testing.expect_value(t, unicode_to_lower_byte(' '), ' ')
	testing.expect_value(t, unicode_to_upper_byte('a'), 'A')
	testing.expect_value(t, unicode_to_upper_byte('z'), 'Z')
	testing.expect_value(t, unicode_to_upper_byte('A'), 'A')
	testing.expect_value(t, unicode_to_upper_byte('0'), '0')
	testing.expect(t, unicode_is_lower_byte('a'))
	testing.expect(t, unicode_is_lower_byte('z'))
	testing.expect(t, !unicode_is_lower_byte('A'))
	testing.expect(t, !unicode_is_lower_byte('0'))
	testing.expect(t, unicode_is_upper_byte('A'))
	testing.expect(t, unicode_is_upper_byte('Z'))
	testing.expect(t, !unicode_is_upper_byte('a'))
	testing.expect(t, !unicode_is_upper_byte('0'))
}

@(test)
unicode_test_case_runes :: proc(t: ^testing.T) {
	testing.expect_value(t, unicode_to_lower('A'), 'a')
	testing.expect_value(t, unicode_to_lower('É'), 'é')
	testing.expect_value(t, unicode_to_lower('Σ'), 'σ')
	testing.expect_value(t, unicode_to_lower('Ω'), 'ω')
	testing.expect_value(t, unicode_to_lower('é'), 'é')
	testing.expect_value(t, unicode_to_lower('中'), '中')
	testing.expect_value(t, unicode_to_lower('5'), '5')
	testing.expect_value(t, unicode_to_upper('a'), 'A')
	testing.expect_value(t, unicode_to_upper('é'), 'É')
	testing.expect_value(t, unicode_to_upper('σ'), 'Σ')
	testing.expect_value(t, unicode_to_upper('É'), 'É')
	testing.expect_value(t, unicode_to_upper('中'), '中')
	testing.expect(t, unicode_is_lower('a'))
	testing.expect(t, unicode_is_lower('é'))
	testing.expect(t, !unicode_is_lower('A'))
	testing.expect(t, !unicode_is_lower('É'))
	testing.expect(t, !unicode_is_lower('5'))
	testing.expect(t, !unicode_is_lower('中'))
	testing.expect(t, unicode_is_upper('A'))
	testing.expect(t, unicode_is_upper('É'))
	testing.expect(t, !unicode_is_upper('a'))
	testing.expect(t, !unicode_is_upper('é'))
	// ASCII boundary: 0x7F uses the byte table, 0x80 the Unicode tables.
	testing.expect(t, !unicode_is_lower(0x7F))
	testing.expect(t, !unicode_is_upper(0x7F))
	testing.expect(t, !unicode_is_lower(0x80))
	testing.expect(t, !unicode_is_upper(0x80))
	testing.expect_value(t, unicode_to_lower(0x7F), 0x7F)
	testing.expect_value(t, unicode_to_upper(0x7F), 0x7F)
}
