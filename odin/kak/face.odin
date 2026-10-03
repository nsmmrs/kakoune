// Port of Kakoune's src/face.hh.
//
// A Face layers a foreground color, a background color, an underline
// color and a set of attributes over a base face. face_merge
// implements the C++ merge_faces overlay rules: Final* flags pin a
// layer's colors, Default colors fall through to the base, and a
// translucent RGB color alpha-blends over an RGB base. Face parsing,
// stringifying and the named registry live in the face_registry
// module (src/face_registry.hh); colors come from the color module
// and are never redefined here.
//
// The C++ Attribute bit positions are an implementation detail, so
// flags use Odin bit positions; only the flag identities and the
// merge semantics are preserved. This module has no Face_Error:
// none of its operations can fail.
//
// Ownership: faces are plain values; nothing here allocates.
package kak

// Face_Attribute_Flag enumerates the attribute flags (port of the
// C++ Attribute enumerators; the empty set is Attribute::Normal and
// Face_Final is Attribute::Final).
Face_Attribute_Flag :: enum {
	Underline,
	Curly_Underline,
	Double_Underline,
	Reverse,
	Blink,
	Bold,
	Dim,
	Italic,
	Strikethrough,
	Final_Fg,
	Final_Bg,
	Final_Attr,
}

// Face_Attribute is a set of attribute flags (port of C++ Attribute
// with bit ops).
Face_Attribute :: bit_set[Face_Attribute_Flag; u16]

// Face_Final groups the Final* flags (port of C++ Attribute::Final).
Face_Final :: Face_Attribute{.Final_Fg, .Final_Bg, .Final_Attr}

// Face describes the rendering of a piece of text (port of C++
// Face). The zero value equals the C++ default face: Default colors
// and no attributes.
Face :: struct {
	fg:         Color,
	bg:         Color,
	attributes: Face_Attribute,
	underline:  Color,
}

// face_blend_colors alpha-blends a translucent RGB color over an RGB
// base (port of the alpha_blend lambda in merge_faces).
face_blend_colors :: proc(base, color: Color) -> Color {
	blend_channel := proc(base_channel, color_channel: u8, alpha: int) -> u8 {
		blended := (int(base_channel) * (255 - alpha) + int(color_channel) * alpha) / 255
		if blended > 255 {
			blended = 255
		}
		return u8(blended)
	}
	alpha := int(color.a) + int(base.a) * (255 - int(color.a)) / 255
	if alpha > 255 {
		alpha = 255
	}
	a := int(color.a)
	return {u8(alpha), blend_channel(base.r, color.r, a), blend_channel(base.g, color.g, a), blend_channel(base.b, color.b, a)}
}

// face_choose_color picks one color layer of a merge (port of the
// choose lambda in merge_faces): a Final flag on either layer pins
// that layer's color, a Default face color falls through to the
// base, and a translucent RGB face color blends over an RGB base.
// Pass an empty final set for the underline layer, which has no
// Final flag.
face_choose_color :: proc(base_color, face_color: Color, base_attrs, face_attrs: Face_Attribute, final: Face_Attribute) -> Color {
	if final != {} {
		if final <= face_attrs {
			return face_color
		}
		if final <= base_attrs {
			return base_color
		}
	}
	if face_color == color_from_named(.Default) {
		return base_color
	}
	if color_is_rgb(base_color) && color_is_rgb(face_color) && face_color.a != 255 {
		return face_blend_colors(base_color, face_color)
	}
	return face_color
}

// face_merge overlays face over base (port of C++ merge_faces).
face_merge :: proc(base, face: Face) -> Face {
	attrs: Face_Attribute
	if .Final_Attr in face.attributes {
		attrs = face.attributes + (base.attributes & Face_Final)
	} else if .Final_Attr in base.attributes {
		attrs = base.attributes
	} else {
		attrs = face.attributes + base.attributes
	}
	return Face{
		fg = face_choose_color(base.fg, face.fg, base.attributes, face.attributes, {.Final_Fg}),
		bg = face_choose_color(base.bg, face.bg, base.attributes, face.attributes, {.Final_Bg}),
		attributes = attrs,
		underline = face_choose_color(base.underline, face.underline, base.attributes, face.attributes, {}),
	}
}

// face_hash hashes a face for hash tables (port of C++
// hash_value(Face)).
face_hash :: proc(face: Face) -> uint {
	attr_bits := u16(0)
	for flag in face.attributes {
		attr_bits |= u16(1) << u16(flag)
	}
	return hash_values(color_hash(face.fg), color_hash(face.bg), color_hash(face.underline), uint(attr_bits))
}
