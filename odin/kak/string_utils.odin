// Port of Kakoune's src/string_utils.{hh,cc}.
//
// C++ `String`/`StringView` map to builtin `string`. Owned results are
// allocated with `allocator` (default `context.allocator`) and must be
// freed by the caller with `delete(s, allocator)`; procedures returning a
// `String_Utils_Error` allocate nothing on the error path.
//
// Places where C++ behavior could not be carried over exactly are marked
// with "Deviation:" in the procedure docs.
package kak

import "core:mem"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"


// Module error. Zero value `None` is success.
String_Utils_Error :: enum {
    None,
    // trim_indent: a non-blank line does not start with the common indent
    // (C++ throws runtime_error).
    Inconsistent_Indent,
    // str_to_int: the input is not a valid integer literal
    // (C++ throws runtime_error).
    Invalid_Number,
}

// trim_indent removes the common leading indent from every line, plus one
// leading newline and trailing blanks. Caller frees the result.
// Ports Kakoune `trim_indent`; the C++ `runtime_error` on inconsistent
// indentation becomes `.Inconsistent_Indent`.
string_utils_trim_indent :: proc(str: string, allocator := context.allocator) -> (string, String_Utils_Error) {
    if len(str) == 0 {
        return "", .None
    }
    s := str
    if s[0] == '\n' {
        s = s[1:]
    }
    // C++ tests `str.back()`, a single byte, so only ASCII blanks are
    // stripped here even though `is_blank` covers multibyte codepoints.
    for len(s) > 0 {
        b := s[len(s) - 1]
        if b >= 0x80 || !string_utils_is_blank(rune(b)) {
            break
        }
        s = s[:len(s) - 1]
    }
    // Common indent: leading horizontal blanks of the first line,
    // measured in codepoints like the C++ utf8::iterator scan.
    pos := 0
    for pos < len(s) {
        cp, next := string_utils_read_codepoint(s, pos)
        if !string_utils_is_horizontal_blank(cp) {
            break
        }
        pos = next
    }
    indent := s[:pos]
    // Validate first so the build pass cannot fail midway (which would
    // require freeing a partially built buffer).
    if !string_utils_has_consistent_indent(s, indent) {
        return "", .Inconsistent_Indent
    }
    b := strings.builder_make(0, len(s), allocator)
    start := 0
    i := 0
    for i < len(s) {
        if s[i] == '\n' {
            line := s[start:i + 1]
            if line != "\n" {
                line = line[len(indent):]
            }
            strings.write_string(&b, line)
            start = i + 1
        }
        i += 1
    }
    if start < len(s) {
        line := s[start:]
        if line != "\n" {
            line = line[len(indent):]
        }
        strings.write_string(&b, line)
    }
    return strings.to_string(b), .None
}

// has_consistent_indent reports whether every line of `s` (split after
// each '\n', with no empty trailing segment) is either exactly "\n" or
// starts with `indent`. Shared by the validate pass of trim_indent.
string_utils_has_consistent_indent :: proc(s, indent: string) -> bool {
    start := 0
    i := 0
    for i < len(s) {
        if s[i] == '\n' {
            line := s[start:i + 1]
            if line != "\n" && !strings.has_prefix(line, indent) {
                return false
            }
            start = i + 1
        }
        i += 1
    }
    if start < len(s) {
        line := s[start:]
        if line != "\n" && !strings.has_prefix(line, indent) {
            return false
        }
    }
    return true
}

// escape prefixes every byte of `str` found in `characters` with `escape`.
// Byte-wise, like the C++. Caller frees the result.
string_utils_escape :: proc(str, characters: string, escape: byte, allocator := context.allocator) -> string {
    b := strings.builder_make(0, len(str), allocator)
    string_utils_write_escaped(&b, str, characters, escape)
    return strings.to_string(b)
}

// unescape removes an `escape` byte when followed by a byte from
// `characters`, leaving other escapes untouched. Byte-wise, like the C++.
// Caller frees the result.
string_utils_unescape :: proc(str, characters: string, escape: byte, allocator := context.allocator) -> string {
    b := strings.builder_make(0, len(str), allocator)
    start := 0
    i := 0
    for i < len(str) {
        if str[i] == escape && i + 1 < len(str) && strings.index_byte(characters, str[i + 1]) >= 0 {
            strings.write_string(&b, str[start:i])
            strings.write_byte(&b, str[i + 1])
            i += 2
            start = i
        } else {
            i += 1
        }
    }
    strings.write_string(&b, str[start:])
    return strings.to_string(b)
}

// unescape_single ports the `unescape<character, escape>` template: like
// unescape with characters {character, escape}. Caller frees the result.
string_utils_unescape_single :: proc(str: string, character, escape: byte, allocator := context.allocator) -> string {
    chars := [2]byte{character, escape}
    return string_utils_unescape(str, string(chars[:]), escape, allocator)
}

// indent prefixes every line of `str` with `indent` (default four spaces).
// Caller frees the result.
string_utils_indent :: proc(str: string, indent := "    ", allocator := context.allocator) -> string {
    b := strings.builder_make(0, len(str), allocator)
    was_eol := true
    for i := 0; i < len(str); i += 1 {
        if was_eol {
            strings.write_string(&b, indent)
        }
        strings.write_byte(&b, str[i])
        was_eol = str[i] == '\n'
    }
    return strings.to_string(b)
}

// replace substitutes every non-overlapping occurrence of `substr` with
// `replacement`, scanning left to right. Caller frees the result.
//
// Deviation: C++ loops forever on an empty `substr` (std::search matches
// at every position without advancing); here it returns a copy of `str`.
string_utils_replace :: proc(str, substr, replacement: string, allocator := context.allocator) -> string {
    if len(substr) == 0 {
        return strings.clone(str, allocator)
    }
    b := strings.builder_make(0, len(str), allocator)
    string_utils_write_replaced(&b, str, substr, replacement)
    return strings.to_string(b)
}

// left_pad truncates `str` to `size` columns, then left-pads with `c` up
// to `size` columns. Column widths follow codepoint_width. A negative
// size returns `str` unchanged (C++ substr falls back to end() and the
// pad count clamps to zero). Caller frees the result.
string_utils_left_pad :: proc(str: string, size: int, c: rune = ' ', allocator := context.allocator) -> string {
    b := strings.builder_make(allocator)
    string_utils_write_repeat_codepoint(&b, c, max(0, size - string_utils_column_length(str)))
    strings.write_string(&b, string_utils_column_truncate(str, size))
    return strings.to_string(b)
}

// right_pad truncates `str` to `size` columns, then right-pads with `c`
// up to `size` columns. See left_pad. Caller frees the result.
string_utils_right_pad :: proc(str: string, size: int, c: rune = ' ', allocator := context.allocator) -> string {
    b := strings.builder_make(allocator)
    strings.write_string(&b, string_utils_column_truncate(str, size))
    string_utils_write_repeat_codepoint(&b, c, max(0, size - string_utils_column_length(str)))
    return strings.to_string(b)
}

// join_char joins `parts` with the byte `joiner`, escaping occurrences
// of `joiner` and '\\' in each part with '\\' when `esc_joiner` is set.
// Ports the `join(container, char, esc_joiner)` template.
// Caller frees the result.
string_utils_join_char :: proc(parts: []string, joiner: byte, esc_joiner := true, allocator := context.allocator) -> string {
    b := strings.builder_make(allocator)
    for i := 0; i < len(parts); i += 1 {
        if i > 0 {
            strings.write_byte(&b, joiner)
        }
        if esc_joiner {
            chars := [2]byte{joiner, '\\'}
            string_utils_write_escaped(&b, parts[i], string(chars[:]), '\\')
        } else {
            strings.write_string(&b, parts[i])
        }
    }
    return strings.to_string(b)
}

// join_str joins `parts` with the string `joiner`, without escaping.
// Ports the `join(container, StringView)` template. Caller frees the result.
string_utils_join_str :: proc(parts: []string, joiner: string, allocator := context.allocator) -> string {
    // strings.join provably matches: separator between elements, "" for empty.
    return strings.join(parts, joiner, allocator)
}

// prefix_match reports whether `str` starts with `prefix` (byte-wise).
string_utils_prefix_match :: proc(str, prefix: string) -> bool {
    // strings.has_prefix is exactly `substr(0, len(prefix)) == prefix`.
    return strings.has_prefix(str, prefix)
}

// subsequence_match reports whether all bytes of `subseq` appear in `str`
// in order (not necessarily adjacent). Byte-wise, like the C++.
string_utils_subsequence_match :: proc(str, subseq: string) -> bool {
    it := 0
    for j := 0; j < len(subseq); j += 1 {
        for it < len(str) && str[it] != subseq[j] {
            it += 1
        }
        if it >= len(str) {
            return false
        }
        it += 1
    }
    return true
}

// expand_tabs replaces each '\t' with the spaces needed to reach the next
// multiple of `tabstop` columns, counting from `col`. `tabstop` must be
// positive (C++ divides by it). Caller frees the result.
string_utils_expand_tabs :: proc(line: string, tabstop: int, col := 0, allocator := context.allocator) -> string {
    b := strings.builder_make(0, len(line), allocator)
    c := col
    pos := 0
    for pos < len(line) {
        if line[pos] == '\t' {
            end_col := (c / tabstop + 1) * tabstop
            for _ in 0 ..< end_col - c {
                strings.write_byte(&b, ' ')
            }
            c = end_col
            pos += 1
        } else {
            cp, next := string_utils_read_codepoint(line, pos)
            strings.write_string(&b, line[pos:next])
            c += string_utils_codepoint_width(cp)
            pos = next
        }
    }
    return strings.to_string(b)
}

// str_to_int_ifp parses an optional '-' followed by ASCII digits, exactly
// like the C++ (unsigned 32-bit wraparound, then reinterpreted as signed,
// so out-of-range inputs wrap rather than fail).
string_utils_str_to_int_ifp :: proc(str: string) -> (int, bool) {
    s := str
    negative := len(s) > 0 && s[0] == '-'
    if negative {
        s = s[1:]
    }
    if len(s) == 0 {
        return 0, false
    }
    res: u32 = 0
    for i := 0; i < len(s); i += 1 {
        c := s[i]
        if c < '0' || c > '9' {
            return 0, false
        }
        res = res * 10 + u32(c - '0')
    }
    wrapped := negative ? 0 - res : res
    return int(cast(i32)wrapped), true
}

// str_to_int parses like str_to_int_ifp, returning `.Invalid_Number` when
// the input is not a number (C++ throws runtime_error).
string_utils_str_to_int :: proc(str: string) -> (int, String_Utils_Error) {
    v, ok := string_utils_str_to_int_ifp(str)
    if !ok {
        return 0, .Invalid_Number
    }
    return v, .None
}

// double_up duplicates every byte of `s` found in `characters`.
// Byte-wise, like the C++. Caller frees the result.
string_utils_double_up :: proc(s, characters: string, allocator := context.allocator) -> string {
    b := strings.builder_make(0, len(s), allocator)
    string_utils_write_doubled_up(&b, s, characters)
    return strings.to_string(b)
}

// quote wraps `s` in single quotes, doubling inner quotes (Kakoune
// quoting). Caller frees the result.
string_utils_quote :: proc(s: string, allocator := context.allocator) -> string {
    b := strings.builder_make(allocator)
    strings.write_byte(&b, '\'')
    string_utils_write_doubled_up(&b, s, "'")
    strings.write_byte(&b, '\'')
    return strings.to_string(b)
}

// quote_raw returns a copy of `s` (the `Quoting.Raw` quoter).
// Caller frees the result.
string_utils_quote_raw :: proc(s: string, allocator := context.allocator) -> string {
    return strings.clone(s, allocator)
}

// shell_quote wraps `s` in single quotes, replacing inner quotes with
// `'\\''` (shell quoting). Caller frees the result.
string_utils_shell_quote :: proc(s: string, allocator := context.allocator) -> string {
    b := strings.builder_make(allocator)
    strings.write_byte(&b, '\'')
    string_utils_write_replaced(&b, s, "'", `'\''`)
    strings.write_byte(&b, '\'')
    return strings.to_string(b)
}

// Quoting selects a quoting style for option values.
String_Utils_Quoting :: enum {
    Raw,
    Kakoune,
    Shell,
}

// Quoter quotes a string with an allocator; see string_utils_quoter.
String_Utils_Quoter :: proc(s: string, allocator: mem.Allocator) -> string

// quoter returns the quoter for a quoting style.
string_utils_quoter :: proc(quoting: String_Utils_Quoting) -> String_Utils_Quoter {
    switch quoting {
    case .Kakoune:
        return string_utils_quote
    case .Shell:
        return string_utils_shell_quote
    case .Raw:
        return string_utils_quote_raw
    }
    unreachable()
}

// option_to_string quotes an option value. Caller frees the result.
string_utils_option_to_string :: proc(opt: string, quoting: String_Utils_Quoting, allocator := context.allocator) -> string {
    return string_utils_quoter(quoting)(opt, allocator)
}

// option_to_strings wraps one option value in an owned array.
// Caller frees each element, then the array, with `allocator`.
string_utils_option_to_strings :: proc(opt: string, allocator := context.allocator) -> [dynamic]string {
    res := make([dynamic]string, 1, allocator)
    res[0] = strings.clone(opt, allocator)
    return res
}

// option_from_string copies a string option value. Caller frees the result.
string_utils_option_from_string :: proc(str: string, allocator := context.allocator) -> string {
    return strings.clone(str, allocator)
}

// option_add appends `val` to `opt`, reporting whether `val` was non-empty.
// `opt^` must be a heap string owned by `allocator` (or ""); it is freed
// and replaced. Caller frees the final `opt^`.
string_utils_option_add :: proc(opt: ^string, val: string, allocator := context.allocator) -> bool {
    joined := strings.concatenate({opt^, val}, allocator)
    if len(opt^) > 0 {
        delete(opt^, allocator)
    }
    opt^ = joined
    return len(val) > 0
}


// -- Internal helpers (ports of the unicode/utf8 pieces string_utils needs).
// A future unicode module may supersede these; they are prefixed so the
// packages cannot collide.

// is_horizontal_blank ports Kakoune's predicate: ECMA whitespace minus
// vertical tab.
string_utils_is_horizontal_blank :: proc(cp: rune) -> bool {
    return cp == '\t' || cp == '\f' || cp == ' ' || cp == 0x00A0 || cp == 0xFEFF ||
        cp == 0x1680 || cp == 0x2000 || cp == 0x2001 || cp == 0x2002 || cp == 0x2003 ||
        cp == 0x2004 || cp == 0x2005 || cp == 0x2006 || cp == 0x2007 || cp == 0x2008 ||
        cp == 0x2009 || cp == 0x200A || cp == 0x2028 || cp == 0x2029 || cp == 0x202F ||
        cp == 0x205F || cp == 0x3000
}

// is_blank ports Kakoune's predicate: ECMA line terminators, vertical tab,
// and horizontal blanks.
string_utils_is_blank :: proc(cp: rune) -> bool {
    return cp == '\n' || cp == '\r' || cp == '\v' || cp == 0x2028 || cp == 0x2029 ||
        string_utils_is_horizontal_blank(cp)
}

// codepoint_width ports Kakoune's `codepoint_width`: ASCII is always width
// 1, otherwise libc `wcwidth` with negative results mapped to 1.
//
// Deviation: libc `wcwidth` is locale- and libc-dependent, so exact parity
// is impossible; widths come from `core:unicode` (Unicode 15.1 tables: 0
// for nonspacing/enclosing marks, 2 for wide/fullwidth East Asian, 0 for
// a few zero-width format codepoints, 1 otherwise), with control
// codepoints mapped to 1 as in the C++.
string_utils_codepoint_width :: proc(cp: rune) -> int {
    if cp < 0x80 || unicode.is_control(cp) {
        return 1
    }
    if unicode.is_nonspacing_mark(cp) || unicode.is_enclosing_mark(cp) {
        return 0
    }
    return unicode.normalized_east_asian_width(cp)
}

// read_codepoint decodes the codepoint at byte `pos` (which must be in
// range) and returns it with the position past it. It mirrors Kakoune's
// `utf8::read_codepoint` with the Pass policy: lenient, structural
// decoding with no validation of continuation bytes; truncated sequences
// yield partial values and stray bytes yield their sign-extended value,
// exactly as `char` -> `Codepoint` conversion does in C++.
string_utils_read_codepoint :: proc(s: string, pos: int) -> (rune, int) {
    b := s[pos]
    p := pos + 1
    if b & 0x80 == 0 {
        return rune(b), p
    }
    if p >= len(s) {
        return rune(i8(b)), p
    }
    if b & 0xE0 == 0xC0 {
        // 110xxxxx
        cp := (rune(b) & 0x1F) << 6 | (rune(s[p]) & 0x3F)
        return cp, p + 1
    }
    if b & 0xF0 == 0xE0 {
        // 1110xxxx
        cp := (rune(b) & 0x0F) << 12 | (rune(s[p]) & 0x3F) << 6
        p += 1
        if p >= len(s) {
            return cp, p
        }
        return cp | (rune(s[p]) & 0x3F), p + 1
    }
    if b & 0xF8 == 0xF0 {
        // 11110xxx (mask 0x0F as in the C++; bit 3 is always clear here,
        // so it equals a 0x07 mask)
        cp := (rune(b) & 0x0F) << 18 | (rune(s[p]) & 0x3F) << 12
        p += 1
        if p >= len(s) {
            return cp, p
        }
        cp |= (rune(s[p]) & 0x3F) << 6
        p += 1
        if p >= len(s) {
            return cp, p
        }
        return cp | (rune(s[p]) & 0x3F), p + 1
    }
    return rune(i8(b)), p
}

// column_length sums codepoint widths, like `String::column_length`.
string_utils_column_length :: proc(s: string) -> int {
    total := 0
    pos := 0
    for pos < len(s) {
        cp, next := string_utils_read_codepoint(s, pos)
        total += string_utils_codepoint_width(cp)
        pos = next
    }
    return total
}

// column_truncate returns the byte prefix of `s` spanning `size` columns,
// mirroring `substr(0_col, size)` including its quirks: a negative size
// yields all of `s`, and a wide char straddling the boundary is kept when
// it reaches the end of the string, dropped otherwise.
string_utils_column_truncate :: proc(s: string, size: int) -> string {
    if size < 0 {
        return s
    }
    it := 0
    d := size
    for it < len(s) && d > 0 {
        cp, next := string_utils_read_codepoint(s, it)
        it = next
        d -= string_utils_codepoint_width(cp)
        if it < len(s) && d < 0 {
            // to_previous: step back one character.
            if it > 0 {
                it -= 1
                for it > 0 && s[it] & 0xC0 == 0x80 {
                    it -= 1
                }
            }
        }
    }
    return s[:it]
}

// write_repeat_codepoint writes `cp` `columns / max(width(cp), 1)` times,
// like the `String(Codepoint, ColumnCount)` constructor.
string_utils_write_repeat_codepoint :: proc(b: ^strings.Builder, cp: rune, columns: int) {
    n := columns / max(string_utils_codepoint_width(cp), 1)
    if n <= 0 {
        return
    }
    buf, size := utf8.encode_rune(cp)
    for _ in 0 ..< n {
        strings.write_string(b, string(buf[:size]))
    }
}

// write_escaped writes `str` to `b`, prefixing bytes found in `characters`
// with `escape`. Shared by escape and join_char.
string_utils_write_escaped :: proc(b: ^strings.Builder, str, characters: string, escape: byte) {
    start := 0
    for i := 0; i < len(str); i += 1 {
        if strings.index_byte(characters, str[i]) >= 0 {
            strings.write_string(b, str[start:i])
            strings.write_byte(b, escape)
            strings.write_byte(b, str[i])
            start = i + 1
        }
    }
    strings.write_string(b, str[start:])
}

// write_doubled_up writes `s` to `b`, duplicating bytes found in
// `characters`. Shared by double_up and quote.
string_utils_write_doubled_up :: proc(b: ^strings.Builder, s, characters: string) {
    start := 0
    for i := 0; i < len(s); i += 1 {
        if strings.index_byte(characters, s[i]) >= 0 {
            strings.write_string(b, s[start:i + 1])
            strings.write_byte(b, s[i])
            start = i + 1
        }
    }
    strings.write_string(b, s[start:])
}

// write_replaced writes `str` to `b` with every occurrence of `substr`
// replaced by `replacement`. Shared by replace and shell_quote; an empty
// `substr` writes `str` unchanged (see replace).
string_utils_write_replaced :: proc(b: ^strings.Builder, str, substr, replacement: string) {
    if len(substr) == 0 {
        strings.write_string(b, str)
        return
    }
    rest := str
    for len(rest) > 0 {
        idx := strings.index(rest, substr)
        if idx < 0 {
            strings.write_string(b, rest)
            break
        }
        strings.write_string(b, rest[:idx])
        strings.write_string(b, replacement)
        rest = rest[idx + len(substr):]
    }
}
