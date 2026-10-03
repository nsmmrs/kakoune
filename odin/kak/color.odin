// Port of Kakoune's src/color.{hh,cc}.
//
// A Color packs either a named color or an RGB(A) value into four
// bytes, exactly like the C++ union: field a holds the Color_Named
// tag when it is below RGB (17), otherwise the alpha channel, and
// r/g/b hold the color channels (zero for named colors).
//
// Ports Color, str_to_color, to_string, option_to_string,
// option_from_string, is_color_name and hash_value. Name lookup uses
// ranges_find/ranges_contains and the RGB hash uses hash_values, so
// this module stays consistent with the ranges and hash modules.
//
// The C++ runtime_error throws become Color_Error.
//
// Ownership: procs returning `string` allocate with `allocator`
// (default `context.allocator`); the caller frees with
// `delete(s, allocator)`.
package kak

import "core:strings"

// Color_Named names the 17 palette colors. RGB is not a color but the
// tag threshold: Color.a values at or above it are alpha channels
// (port of C++ Color::NamedColor; RGB == 17 as asserted in C++).
Color_Named :: enum u8 {
	Default,
	Black,
	Red,
	Green,
	Yellow,
	Blue,
	Magenta,
	Cyan,
	White,
	Bright_Black,
	Bright_Red,
	Bright_Green,
	Bright_Yellow,
	Bright_Blue,
	Bright_Magenta,
	Bright_Cyan,
	Bright_White,
	RGB,
}

// Color is a named palette color or an RGB(A) value (port of C++
// Color). Compare values with ==; build them with color_from_named
// and color_from_rgb.
Color :: struct {
	a: u8,
	r: u8,
	g: u8,
	b: u8,
}

// Color_Error reports color construction and parsing failures. Zero
// value `None` is success.
Color_Error :: enum {
	None,
	// color_from_rgb: alpha below 17 (C++ throws runtime_error;
	// such values would collide with the Color_Named tags).
	Invalid_Alpha,
	// color_from_string: not a color name, not rgb:/rgba:, or a bad
	// hex digit (C++ throws runtime_error).
	Invalid_Color,
}

// color_names lists the Color_Named names in tag order (port of the
// color_names table in color.cc).
@(private = "file")
color_names := [?]string{
	"default",
	"black",
	"red",
	"green",
	"yellow",
	"blue",
	"magenta",
	"cyan",
	"white",
	"bright-black",
	"bright-red",
	"bright-green",
	"bright-yellow",
	"bright-blue",
	"bright-magenta",
	"bright-cyan",
	"bright-white",
}

// color_from_named builds the named palette color c (port of the
// Color(NamedColor) constructor).
color_from_named :: proc(c: Color_Named) -> Color {
	return {u8(c), 0, 0, 0}
}

// color_from_rgb builds an RGB(A) color (port of the
// Color(r, g, b, a) constructor). Alpha defaults to 255 (opaque);
// values below 17 are rejected, like the C++ validate_alpha check.
color_from_rgb :: proc(r, g, b: u8, a := u8(255)) -> (Color, Color_Error) {
	if a < u8(Color_Named.RGB) {
		return {}, .Invalid_Alpha
	}
	return {a, r, g, b}, .None
}

// color_is_rgb reports whether c holds RGB(A) channels rather than a
// palette tag (port of C++ Color::isRGB).
color_is_rgb :: proc(c: Color) -> bool {
	return c.a >= u8(Color_Named.RGB)
}

// color_named reads the palette tag of a non-RGB color. The result
// is only meaningful when color_is_rgb(c) is false.
color_named :: proc(c: Color) -> Color_Named {
	return Color_Named(c.a)
}

// color_is_name reports whether s is one of the 17 palette color
// names (port of C++ is_color_name).
color_is_name :: proc(s: string) -> bool {
	return ranges_contains(color_names[:], s)
}

// color_hex_value decodes one hex digit (port of the hval lambda in
// str_to_color).
@(private = "file")
color_hex_value :: proc(c: byte) -> (int, bool) {
	switch c {
	case '0' ..= '9':
		return int(c - '0'), true
	case 'a' ..= 'f':
		return 10 + int(c - 'a'), true
	case 'A' ..= 'F':
		return 10 + int(c - 'A'), true
	}
	return 0, false
}

// color_from_string parses a palette name, an `rgb:rrggbb` value, or
// an `rgba:rrggbbaa` value (port of C++ str_to_color).
color_from_string :: proc(s: string) -> (Color, Color_Error) {
	if index, found := ranges_find(color_names[:], s); found {
		return color_from_named(Color_Named(index)), .None
	}
	if len(s) == 10 && s[:4] == "rgb:" {
		channel := [3]u8{}
		for c := 0; c < 3; c += 1 {
			hi, ok_hi := color_hex_value(s[4 + 2 * c])
			lo, ok_lo := color_hex_value(s[4 + 2 * c + 1])
			if !ok_hi || !ok_lo {
				return {}, .Invalid_Color
			}
			channel[c] = u8(hi * 16 + lo)
		}
		return color_from_rgb(channel[0], channel[1], channel[2])
	}
	if len(s) == 13 && s[:5] == "rgba:" {
		channel := [4]u8{}
		for c := 0; c < 4; c += 1 {
			hi, ok_hi := color_hex_value(s[5 + 2 * c])
			lo, ok_lo := color_hex_value(s[5 + 2 * c + 1])
			if !ok_hi || !ok_lo {
				return {}, .Invalid_Color
			}
			channel[c] = u8(hi * 16 + lo)
		}
		return color_from_rgb(channel[0], channel[1], channel[2], channel[3])
	}
	return {}, .Invalid_Color
}

// color_to_string renders c as a palette name, `rgb:rrggbb`, or
// `rgba:rrggbbaa` when the alpha is not opaque (port of C++
// to_string(Color); the hex is lowercase like the C++ {:02} of
// format_hex). Caller frees the result.
color_to_string :: proc(c: Color, allocator := context.allocator) -> string {
	if !color_is_rgb(c) {
		return strings.clone(color_names[c.a], allocator)
	}
	hex := "0123456789abcdef"
	b := strings.builder_make(0, 13, allocator)
	channels := [3]u8{c.r, c.g, c.b}
	if c.a == 255 {
		strings.write_string(&b, "rgb:")
	} else {
		strings.write_string(&b, "rgba:")
	}
	for v in channels {
		strings.write_byte(&b, hex[v >> 4])
		strings.write_byte(&b, hex[v & 0xF])
	}
	if c.a != 255 {
		strings.write_byte(&b, hex[c.a >> 4])
		strings.write_byte(&b, hex[c.a & 0xF])
	}
	return strings.to_string(b)
}

// color_option_to_string renders an option value (port of C++
// option_to_string(Color)). Caller frees the result.
color_option_to_string :: proc(c: Color, allocator := context.allocator) -> string {
	return color_to_string(c, allocator)
}

// color_option_from_string parses an option value (port of C++
// option_from_string(Meta::Type<Color>, ...)).
color_option_from_string :: proc(s: string) -> (Color, Color_Error) {
	return color_from_string(s)
}

// color_hash hashes c for hash tables (port of C++ hash_value(Color):
// the RGB channels combine with hash_values, a palette tag hashes as
// its number).
color_hash :: proc(c: Color) -> uint {
	if color_is_rgb(c) {
		return hash_values(uint(c.a), uint(c.r), uint(c.g), uint(c.b))
	}
	return hash_value(Color_Named(c.a))
}
