// Tests for the color port. src/color.cc has no C++ UnitTest, so
// these are edge-case tests written against the documented C++
// semantics; the hash goldens below were produced by compiling the
// real src/hash.hh (see task report).
package kak

import "core:testing"

// every palette name parses to its tag and renders back
@(test)
color_test_named_roundtrip :: proc(t: ^testing.T) {
	names := [?]string{
		"default", "black", "red", "green", "yellow", "blue", "magenta",
		"cyan", "white", "bright-black", "bright-red", "bright-green",
		"bright-yellow", "bright-blue", "bright-magenta", "bright-cyan",
		"bright-white",
	}
	testing.expect_value(t, len(names), 17)
	for name, i in names {
		c, err := color_from_string(name)
		testing.expect_value(t, err, Color_Error.None)
		testing.expect(t, !color_is_rgb(c))
		testing.expect_value(t, color_named(c), Color_Named(i))
		testing.expect(t, c == color_from_named(Color_Named(i)))
		back := color_to_string(c)
		defer delete(back)
		testing.expect_value(t, back, name)
	}
}

// is_name accepts exactly the palette names
@(test)
color_test_is_name :: proc(t: ^testing.T) {
	testing.expect(t, color_is_name("default"))
	testing.expect(t, color_is_name("red"))
	testing.expect(t, color_is_name("bright-white"))
	testing.expect(t, !color_is_name(""))
	testing.expect(t, !color_is_name("RED"))
	testing.expect(t, !color_is_name("red "))
	testing.expect(t, !color_is_name("pink"))
	testing.expect(t, !color_is_name("rgb:ff0000"))
}

// rgb: values parse in any hex case and render lowercase
@(test)
color_test_rgb :: proc(t: ^testing.T) {
	c, err := color_from_string("rgb:000000")
	testing.expect_value(t, err, Color_Error.None)
	testing.expect(t, color_is_rgb(c))
	testing.expect_value(t, c.r, 0)
	testing.expect_value(t, c.g, 0)
	testing.expect_value(t, c.b, 0)
	testing.expect_value(t, c.a, 255)
	m, err2 := color_from_string("rgb:FF00aA")
	testing.expect_value(t, err2, Color_Error.None)
	testing.expect_value(t, m.r, 0xFF)
	testing.expect_value(t, m.g, 0x00)
	testing.expect_value(t, m.b, 0xAA)
	back := color_to_string(m)
	defer delete(back)
	testing.expect_value(t, back, "rgb:ff00aa")
}

// rgba: values carry alpha; opaque alpha renders as rgb:
@(test)
color_test_rgba :: proc(t: ^testing.T) {
	c, err := color_from_string("rgba:11223344")
	testing.expect_value(t, err, Color_Error.None)
	testing.expect(t, color_is_rgb(c))
	testing.expect_value(t, c.r, 0x11)
	testing.expect_value(t, c.g, 0x22)
	testing.expect_value(t, c.b, 0x33)
	testing.expect_value(t, c.a, 0x44)
	back := color_to_string(c)
	defer delete(back)
	testing.expect_value(t, back, "rgba:11223344")
	// opaque alpha drops back to the rgb: form, like the C++
	o, err2 := color_from_string("rgba:112233ff")
	testing.expect_value(t, err2, Color_Error.None)
	plain := color_to_string(o)
	defer delete(plain)
	testing.expect_value(t, plain, "rgb:112233")
}

// alpha below 17 collides with the palette tags and is rejected
@(test)
color_test_alpha_boundary :: proc(t: ^testing.T) {
	_, err := color_from_rgb(1, 2, 3, 0)
	testing.expect_value(t, err, Color_Error.Invalid_Alpha)
	_, err2 := color_from_rgb(1, 2, 3, 16)
	testing.expect_value(t, err2, Color_Error.Invalid_Alpha)
	c, err3 := color_from_rgb(1, 2, 3, 17)
	testing.expect_value(t, err3, Color_Error.None)
	testing.expect(t, color_is_rgb(c))
	d, err4 := color_from_rgb(1, 2, 3)
	testing.expect_value(t, err4, Color_Error.None)
	testing.expect_value(t, d.a, 255)
	// the same check fires through the string parser
	_, err5 := color_from_string("rgba:00000010")
	testing.expect_value(t, err5, Color_Error.Invalid_Alpha)
	e, err6 := color_from_string("rgba:00000011")
	testing.expect_value(t, err6, Color_Error.None)
	testing.expect_value(t, e.a, 17)
}

// malformed inputs are Invalid_Color
@(test)
color_test_invalid :: proc(t: ^testing.T) {
	bad := [?]string{
		"",
		"pink",
		"RGB:000000", // prefix match is case-sensitive
		"rgb:00000", // too short
		"rgb:0000000", // too long
		"rgb:00000g", // bad digit
		"rgb: 00000",
		"rgba:1122334", // too short
		"rgba:112233445", // too long
		"rgba:1122334z", // bad digit
		"defaultx",
	}
	for s in bad {
		_, err := color_from_string(s)
		testing.expect_value(t, err, Color_Error.Invalid_Color)
	}
}

// values compare by channel; named colors are all distinct
@(test)
color_test_equality :: proc(t: ^testing.T) {
	r1, _ := color_from_string("red")
	r2 := color_from_named(.Red)
	testing.expect(t, r1 == r2)
	g, _ := color_from_string("green")
	testing.expect(t, r1 != g)
	c1, _ := color_from_string("rgb:010203")
	c2, _ := color_from_rgb(1, 2, 3)
	testing.expect(t, c1 == c2)
	c3, _ := color_from_rgb(1, 2, 4)
	testing.expect(t, c1 != c3)
	// quirk carried over from the C++: the RGB tag value itself
	// reads back as an RGB color, since a == 17 >= RGB
	tag := color_from_named(.RGB)
	testing.expect(t, color_is_rgb(tag))
}

// hash goldens from the real src/hash.hh
@(test)
color_test_hash :: proc(t: ^testing.T) {
	testing.expect_value(t, color_hash(color_from_named(.Default)), uint(0))
	testing.expect_value(t, color_hash(color_from_named(.Red)), uint(2))
	testing.expect_value(t, color_hash(color_from_named(.Bright_White)), uint(16))
	c1, _ := color_from_rgb(1, 2, 3)
	testing.expect_value(t, color_hash(c1), uint(11093819468256))
	c2, _ := color_from_rgb(0, 0, 0)
	testing.expect_value(t, color_hash(c2), uint(11093822414321))
	c3, _ := color_from_rgb(255, 255, 255, 17)
	testing.expect_value(t, color_hash(c3), uint(11093886667656))
	c4, _ := color_from_rgb(16, 32, 64, 200)
	testing.expect_value(t, color_hash(c4), uint(11093770488621))
	// equal colors hash equal
	p, _ := color_from_string("rgb:010203")
	testing.expect_value(t, color_hash(p), color_hash(c1))
}

// option conversions delegate to the string conversions
@(test)
color_test_option :: proc(t: ^testing.T) {
	c, err := color_option_from_string("blue")
	testing.expect_value(t, err, Color_Error.None)
	testing.expect(t, c == color_from_named(.Blue))
	s := color_option_to_string(c)
	defer delete(s)
	testing.expect_value(t, s, "blue")
	_, err2 := color_option_from_string("nope")
	testing.expect_value(t, err2, Color_Error.Invalid_Color)
}
