// Tests for the string_utils port.
//
// The C++ `UnitTest test_string` assertions owned by string_utils
// (trim_indent, escape, unescape, prefix_match, subsequence_match,
// str_to_int, double_up, replace) are ported 1:1 first; each ported group
// is marked `// C++:` below. The remaining `test_string` assertions cover
// sibling modules (`String` concat, `starts_with`/`ends_with`, `format`,
// `format_to`) and belong in their own test files, so they are not
// duplicated here. Edge cases follow each ported group.
package kak

import "core:strings"
import "core:testing"


@(test)
test_string_utils_trim_indent :: proc(t: ^testing.T) {
    // C++: trim_indent(" ") == ""
    r, err := string_utils_trim_indent(" ")
    testing.expect_value(t, err, String_Utils_Error.None)
    testing.expect_value(t, r, "")
    delete(r)
    // C++: trim_indent("no-indent") == "no-indent"
    r, err = string_utils_trim_indent("no-indent")
    testing.expect_value(t, err, String_Utils_Error.None)
    testing.expect_value(t, r, "no-indent")
    delete(r)
    // C++: trim_indent("\nno-indent") == "no-indent"
    r, err = string_utils_trim_indent("\nno-indent")
    testing.expect_value(t, err, String_Utils_Error.None)
    testing.expect_value(t, r, "no-indent")
    delete(r)
    // C++: trim_indent("\n  indent\n  indent") == "indent\nindent"
    r, err = string_utils_trim_indent("\n  indent\n  indent")
    testing.expect_value(t, err, String_Utils_Error.None)
    testing.expect_value(t, r, "indent\nindent")
    delete(r)
    // C++: trim_indent("\n  indent\n    indent") == "indent\n  indent"
    r, err = string_utils_trim_indent("\n  indent\n    indent")
    testing.expect_value(t, err, String_Utils_Error.None)
    testing.expect_value(t, r, "indent\n  indent")
    delete(r)
    // C++: trim_indent("\n  indent\n  indent\n   ") == "indent\nindent"
    r, err = string_utils_trim_indent("\n  indent\n  indent\n   ")
    testing.expect_value(t, err, String_Utils_Error.None)
    testing.expect_value(t, r, "indent\nindent")
    delete(r)
    // C++: kak_expect_throw(runtime_error, trim_indent("\n  indent\nno-indent"))
    r, err = string_utils_trim_indent("\n  indent\nno-indent")
    testing.expect_value(t, err, String_Utils_Error.Inconsistent_Indent)
    testing.expect_value(t, r, "")
    delete(r)

    // Edges: empty and degenerate inputs.
    r, err = string_utils_trim_indent("")
    testing.expect_value(t, err, String_Utils_Error.None)
    testing.expect_value(t, r, "")
    delete(r)
    r, err = string_utils_trim_indent("\n")
    testing.expect_value(t, err, String_Utils_Error.None)
    testing.expect_value(t, r, "")
    delete(r)
    r, err = string_utils_trim_indent("   \n  ")
    testing.expect_value(t, err, String_Utils_Error.None)
    testing.expect_value(t, r, "")
    delete(r)
    // Blank middle line ("\n"-only) needs no indent.
    r, err = string_utils_trim_indent("\n  a\n\n  b")
    testing.expect_value(t, err, String_Utils_Error.None)
    testing.expect_value(t, r, "a\n\nb")
    delete(r)
    // Tab indent is horizontal blank too.
    r, err = string_utils_trim_indent("\n\ta\n\tb")
    testing.expect_value(t, err, String_Utils_Error.None)
    testing.expect_value(t, r, "a\nb")
    delete(r)
    // Trailing newline is a trailing blank and gets stripped.
    r, err = string_utils_trim_indent("a\n")
    testing.expect_value(t, err, String_Utils_Error.None)
    testing.expect_value(t, r, "a")
    delete(r)
    // Inconsistent indent on a later line still errors.
    _, err = string_utils_trim_indent("  a\n  b\n c")
    testing.expect_value(t, err, String_Utils_Error.Inconsistent_Indent)
}

@(test)
test_string_utils_escape :: proc(t: ^testing.T) {
    // C++: escape(R"(\youpi:matin:tchou\:)", ":\\", '\\')
    r := string_utils_escape(`\youpi:matin:tchou\:`, `:\`, '\\')
    testing.expect_value(t, r, `\\youpi\:matin\:tchou\\\:`)
    delete(r)

    // Edges.
    r = string_utils_escape("", ":\\", '\\')
    testing.expect_value(t, r, "")
    delete(r)
    r = string_utils_escape("plain", ":\\", '\\')
    testing.expect_value(t, r, "plain")
    delete(r)
    r = string_utils_escape("a:b", "", '\\')
    testing.expect_value(t, r, "a:b")
    delete(r)
    r = string_utils_escape("::", ":", '\\')
    testing.expect_value(t, r, `\:\:`)
    delete(r)
    r = string_utils_escape(`\`, `\`, '\\')
    testing.expect_value(t, r, `\\`)
    delete(r)
}

@(test)
test_string_utils_unescape :: proc(t: ^testing.T) {
    // C++: unescape(R"(\\youpi\:matin\:tchou\\\:)", ":\\", '\\')
    r := string_utils_unescape(`\\youpi\:matin\:tchou\\\:`, `:\`, '\\')
    testing.expect_value(t, r, `\youpi:matin:tchou\:`)
    delete(r)

    // Edges: trailing escape stays, escape before other chars stays.
    r = string_utils_unescape(`abc\`, `:\`, '\\')
    testing.expect_value(t, r, `abc\`)
    delete(r)
    r = string_utils_unescape(`a\xb`, `:\`, '\\')
    testing.expect_value(t, r, `a\xb`)
    delete(r)
    r = string_utils_unescape("", `:\`, '\\')
    testing.expect_value(t, r, "")
    delete(r)
    r = string_utils_unescape(`\:`, `:\`, '\\')
    testing.expect_value(t, r, ":")
    delete(r)
    // Round-trip with escape.
    e := string_utils_escape(`\a:b\c:`, `:\`, '\\')
    u := string_utils_unescape(e, `:\`, '\\')
    testing.expect_value(t, u, `\a:b\c:`)
    delete(e)
    delete(u)
}

@(test)
test_string_utils_unescape_single :: proc(t: ^testing.T) {
    // Ports the unescape<character, escape> template: characters are
    // {character, escape}.
    r := string_utils_unescape_single(`a\'b\\c`, '\'', '\\')
    testing.expect_value(t, r, `a'b\c`)
    delete(r)
    r = string_utils_unescape_single(`a\:b`, ':', '\\')
    testing.expect_value(t, r, "a:b")
    delete(r)
    // Escape before any other byte stays untouched.
    r = string_utils_unescape_single(`a\xb`, ':', '\\')
    testing.expect_value(t, r, `a\xb`)
    delete(r)
}

@(test)
test_string_utils_indent :: proc(t: ^testing.T) {
    r := string_utils_indent("")
    testing.expect_value(t, r, "")
    delete(r)
    r = string_utils_indent("a")
    testing.expect_value(t, r, "    a")
    delete(r)
    r = string_utils_indent("a\n")
    testing.expect_value(t, r, "    a\n")
    delete(r)
    r = string_utils_indent("a\nb")
    testing.expect_value(t, r, "    a\n    b")
    delete(r)
    r = string_utils_indent("a\n\nb")
    testing.expect_value(t, r, "    a\n    \n    b")
    delete(r)
    r = string_utils_indent("a\nb", ">>")
    testing.expect_value(t, r, ">>a\n>>b")
    delete(r)
}

@(test)
test_string_utils_replace :: proc(t: ^testing.T) {
    // C++: replace("tchou/tcha/tchi", "/", "!!") == "tchou!!tcha!!tchi"
    r := string_utils_replace("tchou/tcha/tchi", "/", "!!")
    testing.expect_value(t, r, "tchou!!tcha!!tchi")
    delete(r)

    // Edges.
    r = string_utils_replace("abc", "z", "!!")
    testing.expect_value(t, r, "abc")
    delete(r)
    r = string_utils_replace("", "a", "b")
    testing.expect_value(t, r, "")
    delete(r)
    r = string_utils_replace("aaa", "a", "aa")
    testing.expect_value(t, r, "aaaaaa")
    delete(r)
    r = string_utils_replace("aaa", "aa", "b")
    testing.expect_value(t, r, "ba")
    delete(r)
    r = string_utils_replace("abc", "b", "")
    testing.expect_value(t, r, "ac")
    delete(r)
    // Deviation from C++ (which hangs): empty substr returns a copy.
    r = string_utils_replace("abc", "", "x")
    testing.expect_value(t, r, "abc")
    delete(r)
}

@(test)
test_string_utils_pad :: proc(t: ^testing.T) {
    r := string_utils_left_pad("ab", 5)
    testing.expect_value(t, r, "   ab")
    delete(r)
    r = string_utils_right_pad("ab", 5)
    testing.expect_value(t, r, "ab   ")
    delete(r)
    r = string_utils_left_pad("ab", 5, '0')
    testing.expect_value(t, r, "000ab")
    delete(r)
    r = string_utils_right_pad("ab", 5, '0')
    testing.expect_value(t, r, "ab000")
    delete(r)
    // Exact size: unchanged.
    r = string_utils_left_pad("ab", 2)
    testing.expect_value(t, r, "ab")
    delete(r)
    // Oversize truncates to size columns.
    r = string_utils_left_pad("abcd", 2)
    testing.expect_value(t, r, "ab")
    delete(r)
    r = string_utils_right_pad("abcd", 2)
    testing.expect_value(t, r, "ab")
    delete(r)
    // Empty string pads fully.
    r = string_utils_left_pad("", 3)
    testing.expect_value(t, r, "   ")
    delete(r)
    // Size zero truncates to empty.
    r = string_utils_right_pad("ab", 0)
    testing.expect_value(t, r, "")
    delete(r)
    // Negative size returns the string unchanged.
    r = string_utils_left_pad("ab", -1)
    testing.expect_value(t, r, "ab")
    delete(r)
    // Wide char (U+4E2D, width 2) counts two columns.
    r = string_utils_right_pad("中", 4)
    testing.expect_value(t, r, "中  ")
    delete(r)
    r = string_utils_left_pad("中", 4)
    testing.expect_value(t, r, "  中")
    delete(r)
    // Truncation keeps a wide char that reaches the end (C++ quirk).
    r = string_utils_right_pad("中", 1)
    testing.expect_value(t, r, "中")
    delete(r)
    // ... but drops one followed by more text.
    r = string_utils_right_pad("中x", 1)
    testing.expect_value(t, r, "")
    delete(r)
    // Combining mark (U+0301) is zero width.
    testing.expect_value(t, string_utils_column_length("e\u0301"), 1)
    testing.expect_value(t, string_utils_column_length("中"), 2)
    testing.expect_value(t, string_utils_column_length("a中b"), 4)
}

@(test)
test_string_utils_join :: proc(t: ^testing.T) {
    r := string_utils_join_str({"a", "b", "c"}, ",")
    testing.expect_value(t, r, "a,b,c")
    delete(r)
    r = string_utils_join_str({"a"}, ",")
    testing.expect_value(t, r, "a")
    delete(r)
    r = string_utils_join_str({}, ",")
    testing.expect_value(t, r, "")
    delete(r)
    r = string_utils_join_str({"a", "b"}, "<-->")
    testing.expect_value(t, r, "a<-->b")
    delete(r)

    j := string_utils_join_char({"a", "b"}, ':')
    testing.expect_value(t, j, "a:b")
    delete(j)
    // Joiner and backslash inside parts get escaped.
    j = string_utils_join_char({`a:b`, `c\d`}, ':')
    testing.expect_value(t, j, `a\:b:c\\d`)
    delete(j)
    // ... unless escaping is off.
    j = string_utils_join_char({`a:b`, `c`}, ':', false)
    testing.expect_value(t, j, "a:b:c")
    delete(j)
    j = string_utils_join_char({}, ':')
    testing.expect_value(t, j, "")
    delete(j)
}

@(test)
test_string_utils_prefix_match :: proc(t: ^testing.T) {
    // C++ (4 asserts).
    testing.expect(t, string_utils_prefix_match("tchou kanaky", "tchou"))
    testing.expect(t, string_utils_prefix_match("tchou kanaky", "tchou kanaky"))
    testing.expect(t, string_utils_prefix_match("tchou kanaky", "t"))
    testing.expect(t, !string_utils_prefix_match("tchou kanaky", "c"))
    // Edges.
    testing.expect(t, string_utils_prefix_match("abc", ""))
    testing.expect(t, string_utils_prefix_match("", ""))
    testing.expect(t, !string_utils_prefix_match("", "a"))
    testing.expect(t, !string_utils_prefix_match("ab", "abc"))
}

@(test)
test_string_utils_subsequence_match :: proc(t: ^testing.T) {
    // C++ (4 asserts).
    testing.expect(t, string_utils_subsequence_match("tchou kanaky", "tknky"))
    testing.expect(t, string_utils_subsequence_match("tchou kanaky", "knk"))
    testing.expect(t, string_utils_subsequence_match("tchou kanaky", "tchou kanaky"))
    testing.expect(t, !string_utils_subsequence_match("tchou kanaky", "tchou  kanaky"))
    // Edges.
    testing.expect(t, string_utils_subsequence_match("abc", ""))
    testing.expect(t, string_utils_subsequence_match("", ""))
    testing.expect(t, !string_utils_subsequence_match("", "a"))
    testing.expect(t, !string_utils_subsequence_match("abc", "abcd"))
    testing.expect(t, string_utils_subsequence_match("abc", "abc"))
    testing.expect(t, !string_utils_subsequence_match("abc", "cba"))
}

@(test)
test_string_utils_expand_tabs :: proc(t: ^testing.T) {
    r := string_utils_expand_tabs("\t", 8)
    testing.expect_value(t, r, "        ")
    delete(r)
    r = string_utils_expand_tabs("a\t", 8)
    testing.expect_value(t, r, "a       ")
    delete(r)
    r = string_utils_expand_tabs("ab\tcd\t", 4)
    testing.expect_value(t, r, "ab  cd  ")
    delete(r)
    r = string_utils_expand_tabs("no tabs", 8)
    testing.expect_value(t, r, "no tabs")
    delete(r)
    r = string_utils_expand_tabs("", 8)
    testing.expect_value(t, r, "")
    delete(r)
    // Start column offsets the tab stops.
    r = string_utils_expand_tabs("\t", 8, 3)
    testing.expect_value(t, r, "     ")
    delete(r)
    // Wide char counts two columns toward the next stop.
    r = string_utils_expand_tabs("中\t", 8)
    testing.expect_value(t, r, "中      ")
    delete(r)
    // Tabstop of 1: every tab becomes one space.
    r = string_utils_expand_tabs("a\tb", 1)
    testing.expect_value(t, r, "a b")
    delete(r)
}

@(test)
test_string_utils_str_to_int :: proc(t: ^testing.T) {
    // C++ (5 asserts).
    v, err := string_utils_str_to_int("5")
    testing.expect_value(t, err, String_Utils_Error.None)
    testing.expect_value(t, v, 5)
    v, err = string_utils_str_to_int("2147483647") // INT_MAX
    testing.expect_value(t, err, String_Utils_Error.None)
    testing.expect_value(t, v, 2147483647)
    v, err = string_utils_str_to_int("-2147483648") // INT_MIN
    testing.expect_value(t, err, String_Utils_Error.None)
    testing.expect_value(t, v, -2147483648)
    v, err = string_utils_str_to_int("00")
    testing.expect_value(t, err, String_Utils_Error.None)
    testing.expect_value(t, v, 0)
    v, err = string_utils_str_to_int("-0")
    testing.expect_value(t, err, String_Utils_Error.None)
    testing.expect_value(t, v, 0)

    // Edges: invalid inputs fail like the C++ throw.
    _, err = string_utils_str_to_int("")
    testing.expect_value(t, err, String_Utils_Error.Invalid_Number)
    _, err = string_utils_str_to_int("-")
    testing.expect_value(t, err, String_Utils_Error.Invalid_Number)
    _, err = string_utils_str_to_int("12a")
    testing.expect_value(t, err, String_Utils_Error.Invalid_Number)
    _, err = string_utils_str_to_int(" 5")
    testing.expect_value(t, err, String_Utils_Error.Invalid_Number)
    _, err = string_utils_str_to_int("+5")
    testing.expect_value(t, err, String_Utils_Error.Invalid_Number)
    _, err = string_utils_str_to_int("--5")
    testing.expect_value(t, err, String_Utils_Error.Invalid_Number)
    // C++ wraps modulo 2^32 on overflow; the port matches.
    v, err = string_utils_str_to_int("4294967296") // 2^32 -> 0
    testing.expect_value(t, err, String_Utils_Error.None)
    testing.expect_value(t, v, 0)
    v, err = string_utils_str_to_int("4294967297") // 2^32+1 -> 1
    testing.expect_value(t, err, String_Utils_Error.None)
    testing.expect_value(t, v, 1)
    v, err = string_utils_str_to_int("2147483648") // INT_MAX+1 -> INT_MIN
    testing.expect_value(t, err, String_Utils_Error.None)
    testing.expect_value(t, v, -2147483648)
}

@(test)
test_string_utils_str_to_int_ifp :: proc(t: ^testing.T) {
    v, ok := string_utils_str_to_int_ifp("42")
    testing.expect(t, ok)
    testing.expect_value(t, v, 42)
    v, ok = string_utils_str_to_int_ifp("-42")
    testing.expect(t, ok)
    testing.expect_value(t, v, -42)
    _, ok = string_utils_str_to_int_ifp("")
    testing.expect(t, !ok)
    _, ok = string_utils_str_to_int_ifp("-")
    testing.expect(t, !ok)
    _, ok = string_utils_str_to_int_ifp("4x2")
    testing.expect(t, !ok)
    _, ok = string_utils_str_to_int_ifp(" 42")
    testing.expect(t, !ok)
}

@(test)
test_string_utils_double_up :: proc(t: ^testing.T) {
    // C++: double_up(R"('foo%"bar"')", "'\"%") == R"(''foo%%""bar""'')"
    r := string_utils_double_up(`'foo%"bar"'`, `'\"%`)
    testing.expect_value(t, r, `''foo%%""bar""''`)
    delete(r)

    // Edges.
    r = string_utils_double_up("", "'")
    testing.expect_value(t, r, "")
    delete(r)
    r = string_utils_double_up("abc", "")
    testing.expect_value(t, r, "abc")
    delete(r)
    r = string_utils_double_up("aaa", "a")
    testing.expect_value(t, r, "aaaaaa")
    delete(r)
}

@(test)
test_string_utils_quote :: proc(t: ^testing.T) {
    r := string_utils_quote("don't")
    testing.expect_value(t, r, "'don''t'")
    delete(r)
    r = string_utils_quote("")
    testing.expect_value(t, r, "''")
    delete(r)
    r = string_utils_quote("plain")
    testing.expect_value(t, r, "'plain'")
    delete(r)

    s := string_utils_shell_quote("don't")
    testing.expect_value(t, s, `'don'\''t'`)
    delete(s)
    s = string_utils_shell_quote("")
    testing.expect_value(t, s, "''")
    delete(s)
    s = string_utils_shell_quote("a'b'c")
    testing.expect_value(t, s, `'a'\''b'\''c'`)
    delete(s)

    q := string_utils_quote_raw("don't")
    testing.expect_value(t, q, "don't")
    delete(q)
}

@(test)
test_string_utils_quoter_and_options :: proc(t: ^testing.T) {
    quoter := string_utils_quoter(.Kakoune)
    r := quoter("don't", context.allocator)
    testing.expect_value(t, r, "'don''t'")
    delete(r)
    quoter = string_utils_quoter(.Shell)
    r = quoter("don't", context.allocator)
    testing.expect_value(t, r, `'don'\''t'`)
    delete(r)
    quoter = string_utils_quoter(.Raw)
    r = quoter("don't", context.allocator)
    testing.expect_value(t, r, "don't")
    delete(r)

    o := string_utils_option_to_string("don't", .Kakoune)
    testing.expect_value(t, o, "'don''t'")
    delete(o)
    o = string_utils_option_to_string("don't", .Shell)
    testing.expect_value(t, o, `'don'\''t'`)
    delete(o)
    o = string_utils_option_to_string("don't", .Raw)
    testing.expect_value(t, o, "don't")
    delete(o)

    arr := string_utils_option_to_strings("val")
    testing.expect_value(t, len(arr), 1)
    testing.expect_value(t, arr[0], "val")
    delete(arr[0])
    delete(arr)

    f := string_utils_option_from_string("val")
    testing.expect_value(t, f, "val")
    delete(f)

    opt := strings.clone("base")
    testing.expect(t, string_utils_option_add(&opt, "+x"))
    testing.expect_value(t, opt, "base+x")
    testing.expect(t, !string_utils_option_add(&opt, ""))
    testing.expect_value(t, opt, "base+x")
    delete(opt)
}
