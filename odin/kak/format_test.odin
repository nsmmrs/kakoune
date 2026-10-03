// Tests for the format port. src/format.cc has no C++ UnitTest, so
// these are edge-case tests written against the documented C++
// semantics; the float goldens below were produced by the real
// std::to_chars (see task report), and the grouped max-uint64 case
// pins the documented deviation (the C++ overruns its 23-byte
// buffer there).
package kak

import "core:strconv"
import "core:testing"

// integers across types and extremes
@(test)
format_test_to_string_int :: proc(t: ^testing.T) {
	r := format_to_string(0)
	defer delete(r)
	testing.expect_value(t, r, "0")
	r2 := format_to_string(42)
	defer delete(r2)
	testing.expect_value(t, r2, "42")
	r3 := format_to_string(-42)
	defer delete(r3)
	testing.expect_value(t, r3, "-42")
	r4 := format_to_string(max(i64))
	defer delete(r4)
	testing.expect_value(t, r4, "9223372036854775807")
	r5 := format_to_string(min(i64))
	defer delete(r5)
	testing.expect_value(t, r5, "-9223372036854775808")
	r6 := format_to_string(max(uint))
	defer delete(r6)
	testing.expect_value(t, r6, "18446744073709551615")
	r7 := format_to_string(i8(min(i8)))
	defer delete(r7)
	testing.expect_value(t, r7, "-128")
	r8 := format_to_string(u8(max(u8)))
	defer delete(r8)
	testing.expect_value(t, r8, "255")
}

// hex is lowercase with no prefix
@(test)
format_test_to_string_hex :: proc(t: ^testing.T) {
	h := format_to_string(format_hex(0))
	defer delete(h)
	testing.expect_value(t, h, "0")
	h2 := format_to_string(format_hex(255))
	defer delete(h2)
	testing.expect_value(t, h2, "ff")
	h3 := format_to_string(format_hex(0xdeadbeef))
	defer delete(h3)
	testing.expect_value(t, h3, "deadbeef")
	h4 := format_to_string(format_hex(max(uint)))
	defer delete(h4)
	testing.expect_value(t, h4, "ffffffffffffffff")
}

// thousands separators, including the max-uint64 deviation case
@(test)
format_test_to_string_grouped :: proc(t: ^testing.T) {
	g := format_to_string(format_grouped(0))
	defer delete(g)
	testing.expect_value(t, g, "0")
	g2 := format_to_string(format_grouped(999))
	defer delete(g2)
	testing.expect_value(t, g2, "999")
	g3 := format_to_string(format_grouped(1000))
	defer delete(g3)
	testing.expect_value(t, g3, "1,000")
	g4 := format_to_string(format_grouped(1234567))
	defer delete(g4)
	testing.expect_value(t, g4, "1,234,567")
	g5 := format_to_string(format_grouped(123456789))
	defer delete(g5)
	testing.expect_value(t, g5, "123,456,789")
	// 26 chars: the C++ InplaceString<23> overruns here
	g6 := format_to_string(format_grouped(max(uint)))
	defer delete(g6)
	testing.expect_value(t, g6, "18,446,744,073,709,551,615")
}

// float goldens from the real std::to_chars general format
@(test)
format_test_to_string_float :: proc(t: ^testing.T) {
	vals := [?]f32{0.0, 1.5, -2.5, 0.1, 123.456, 3.14159265, 100.0, 0.0001, 1e10, 1e-5, 1e21, 123456789.0, 1.2345678e-38, 3.4028235e38, 2.5e-7}
	want := [?]string{"0", "1.5", "-2.5", "0.1", "123.456", "3.1415927", "100", "0.0001", "1e+10", "1e-05", "1e+21", "1.2345679e+08", "1.2345678e-38", "3.4028235e+38", "2.5e-07"}
	for v, i in vals {
		s := format_to_string(v)
		defer delete(s)
		testing.expect_value(t, s, want[i])
	}
	// negative zero keeps its sign, like to_chars
	nz := format_to_string(f32(-0.0))
	defer delete(nz)
	testing.expect_value(t, nz, "-0")
}

// every float golden round-trips back to the same bits
@(test)
format_test_to_string_float_roundtrip :: proc(t: ^testing.T) {
	vals := [?]f32{0.0, -0.0, 1.5, 0.1, 123.456, 1e10, 1e-5, 1e21, 123456789.0, 2.5e-7, 3.4028235e38}
	for v in vals {
		s := format_to_string(v)
		defer delete(s)
		back, ok := strconv.parse_f32(s)
		testing.expect(t, ok)
		testing.expect_value(t, back, v)
	}
}

// single codepoints encode as UTF-8
@(test)
format_test_to_string_codepoint :: proc(t: ^testing.T) {
	a := format_to_string('A')
	defer delete(a)
	testing.expect_value(t, a, "A")
	e := format_to_string('é')
	defer delete(e)
	testing.expect_value(t, e, "é")
	euro := format_to_string('€')
	defer delete(euro)
	testing.expect_value(t, euro, "€")
	emoji := format_to_string('😀')
	defer delete(emoji)
	testing.expect_value(t, emoji, "😀")
}

// plain text passes through; empty format gives empty output
@(test)
format_test_plain :: proc(t: ^testing.T) {
	s, err := format_format("hello", {})
	defer delete(s)
	testing.expect_value(t, err, Format_Error.None)
	testing.expect_value(t, s, "hello")
	e, err2 := format_format("", {})
	defer delete(e)
	testing.expect_value(t, err2, Format_Error.None)
	testing.expect_value(t, e, "")
}

// implicit, explicit and mixed placeholder indexing
@(test)
format_test_indexing :: proc(t: ^testing.T) {
	s, err := format_format("{} + {} = {}", []string{"1", "2", "3"})
	defer delete(s)
	testing.expect_value(t, err, Format_Error.None)
	testing.expect_value(t, s, "1 + 2 = 3")
	r, err2 := format_format("{2}{1}{0}{1}", []string{"a", "b", "c"})
	defer delete(r)
	testing.expect_value(t, err2, Format_Error.None)
	testing.expect_value(t, r, "cbab")
	// an explicit {n} moves the implicit cursor to n+1
	m, err3 := format_format("{1} {}", []string{"a", "b", "c"})
	defer delete(m)
	testing.expect_value(t, err3, Format_Error.None)
	testing.expect_value(t, m, "b c")
}

// space and zero padding to column width
@(test)
format_test_padding :: proc(t: ^testing.T) {
	s, err := format_format("[{0:5}]", []string{"ab"})
	defer delete(s)
	testing.expect_value(t, err, Format_Error.None)
	testing.expect_value(t, s, "[   ab]")
	z, err2 := format_format("{:02}", []string{"f"})
	defer delete(z)
	testing.expect_value(t, err2, Format_Error.None)
	testing.expect_value(t, z, "0f")
	z2, err3 := format_format("{:02}", []string{"ff"})
	defer delete(z2)
	testing.expect_value(t, err3, Format_Error.None)
	testing.expect_value(t, z2, "ff")
	// width at or below the value length pads nothing
	w, err4 := format_format("[{:2}][{:5}][{:-3}]", []string{"ab", "abcdef", "x"})
	defer delete(w)
	testing.expect_value(t, err4, Format_Error.None)
	testing.expect_value(t, w, "[ab][abcdef][x]")
	// implicit index with width spec
	iw, err5 := format_format("{:4}! {}", []string{"ab", "cd"})
	defer delete(iw)
	testing.expect_value(t, err5, Format_Error.None)
	testing.expect_value(t, iw, "  ab! cd")
}

// padding counts columns, not bytes
@(test)
format_test_padding_wide :: proc(t: ^testing.T) {
	s, err := format_format("[{:4}]", []string{"é"})
	defer delete(s)
	testing.expect_value(t, err, Format_Error.None)
	testing.expect_value(t, s, "[   é]")
}

// backslash-brace escapes; other backslashes and lone } are literal
@(test)
format_test_escapes :: proc(t: ^testing.T) {
	s, err := format_format("\\{} {}", []string{"x"})
	defer delete(s)
	testing.expect_value(t, err, Format_Error.None)
	testing.expect_value(t, s, "{} x")
	b, err2 := format_format("a\\b}c", {})
	defer delete(b)
	testing.expect_value(t, err2, Format_Error.None)
	testing.expect_value(t, b, "a\\b}c")
	// double backslash before a brace: one literal, brace still escaped
	d, err3 := format_format("\\\\{}", []string{"x"})
	defer delete(d)
	testing.expect_value(t, err3, Format_Error.None)
	testing.expect_value(t, d, "\\{}")
	// brace at the very start cannot be escaped (nothing precedes it)
	l, err4 := format_format("{}", []string{"x"})
	defer delete(l)
	testing.expect_value(t, err4, Format_Error.None)
	testing.expect_value(t, l, "x")
}

// malformed placeholders report errors and allocate nothing
@(test)
format_test_errors :: proc(t: ^testing.T) {
	_, err := format_format("abc {", {})
	testing.expect_value(t, err, Format_Error.Unclosed_Brace)
	_, err2 := format_format("{0} {1}", []string{"a"})
	testing.expect_value(t, err2, Format_Error.Param_Index_Too_Big)
	_, err3 := format_format("{5}", []string{"a"})
	testing.expect_value(t, err3, Format_Error.Param_Index_Too_Big)
	_, err4 := format_format("{-1}", []string{"a"})
	testing.expect_value(t, err4, Format_Error.Param_Index_Too_Big)
	_, err5 := format_format("{x}", []string{"a"})
	testing.expect_value(t, err5, Format_Error.Invalid_Number)
	_, err6 := format_format("{:}", []string{"a"})
	testing.expect_value(t, err6, Format_Error.Invalid_Number)
	_, err7 := format_format("{:0}", []string{"a"})
	testing.expect_value(t, err7, Format_Error.Invalid_Number)
	_, err8 := format_format("{0:w}", []string{"a"})
	testing.expect_value(t, err8, Format_Error.Invalid_Number)
	// error results are always the empty string
	s, err9 := format_format("{9}", []string{"a"})
	defer delete(s)
	testing.expect_value(t, err9, Format_Error.Param_Index_Too_Big)
	testing.expect_value(t, s, "")
}

// format_to_buffer writes into caller memory with a NUL terminator
@(test)
format_test_to_buffer :: proc(t: ^testing.T) {
	buf: [16]byte
	s, err := format_to_buffer(buf[:], "rgb:{:02}{:02}{:02}", []string{"f", "a0", "3"})
	testing.expect_value(t, err, Format_Error.None)
	testing.expect_value(t, s, "rgb:0fa003")
	testing.expect_value(t, buf[len(s)], 0)
	// output that exactly fills the buffer still fails (no NUL room)
	tight: [3]byte
	_, err2 := format_to_buffer(tight[:], "{}", []string{"abc"})
	testing.expect_value(t, err2, Format_Error.Buffer_Too_Small)
	fit: [4]byte
	s3, err3 := format_to_buffer(fit[:], "{}", []string{"abc"})
	testing.expect_value(t, err3, Format_Error.None)
	testing.expect_value(t, s3, "abc")
	// mid-write overflow and error propagation
	small: [2]byte
	_, err4 := format_to_buffer(small[:], "{}", []string{"abc"})
	testing.expect_value(t, err4, Format_Error.Buffer_Too_Small)
	_, err5 := format_to_buffer(buf[:], "{", {})
	testing.expect_value(t, err5, Format_Error.Unclosed_Brace)
}

// format_with delivers literal spans, padding and params in order
@(test)
format_test_with :: proc(t: ^testing.T) {
	pieces := make([dynamic]string, context.temp_allocator)
	collect :: proc(ctx: rawptr, s: string) {
		append((^[dynamic]string)(ctx), s)
	}
	err := format_with(collect, &pieces, "a{:03}b", []string{"7"})
	testing.expect_value(t, err, Format_Error.None)
	// "a", two zero pads (one call per char, like the C++), "7", "b"
	testing.expect_value(t, len(pieces), 5)
	testing.expect_value(t, pieces[0], "a")
	testing.expect_value(t, pieces[1], "0")
	testing.expect_value(t, pieces[2], "0")
	testing.expect_value(t, pieces[3], "7")
	testing.expect_value(t, pieces[4], "b")
	err2 := format_with(collect, &pieces, "{", {})
	testing.expect_value(t, err2, Format_Error.Unclosed_Brace)
}
