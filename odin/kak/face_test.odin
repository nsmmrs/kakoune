// Tests for the face module (port of src/face.hh). The C++ ships no
// unit tests for faces, so these cover the merge_faces contract
// directly: color fallthrough, Final* pinning, attribute merging and
// alpha blending, plus edge cases.
package kak

import "core:testing"

@(test)
face_test_merge_defaults :: proc(t: ^testing.T) {
	merged := face_merge(Face{}, Face{})
	testing.expect(t, merged == Face{}, "merging two default faces must stay default")
}

@(test)
face_test_merge_color_fallthrough :: proc(t: ^testing.T) {
	base := Face{fg = color_from_named(.Red), bg = color_from_named(.Blue)}
	face := Face{fg = color_from_named(.Green)}
	merged := face_merge(base, face)
	testing.expect(t, merged.fg == color_from_named(.Green), "face fg must win")
	testing.expect(t, merged.bg == color_from_named(.Blue), "Default face bg must fall through to base")
	testing.expect(t, merged.underline == color_from_named(.Default), "Default underline must stay Default")
}

@(test)
face_test_merge_face_final_fg :: proc(t: ^testing.T) {
	base := Face{fg = color_from_named(.Red)}
	// FinalFg pins the face layer even when its color is Default.
	face := Face{attributes = {.Final_Fg}}
	merged := face_merge(base, face)
	testing.expect(t, merged.fg == color_from_named(.Default), "FinalFg on face must pin the face fg")
}

@(test)
face_test_merge_base_final_fg :: proc(t: ^testing.T) {
	base := Face{fg = color_from_named(.Red), attributes = {.Final_Fg}}
	face := Face{fg = color_from_named(.Green)}
	merged := face_merge(base, face)
	testing.expect(t, merged.fg == color_from_named(.Red), "FinalFg on base must pin the base fg")
}

@(test)
face_test_merge_final_bg :: proc(t: ^testing.T) {
	base := Face{bg = color_from_named(.Blue), attributes = {.Final_Bg}}
	face := Face{bg = color_from_named(.Yellow)}
	merged := face_merge(base, face)
	testing.expect(t, merged.bg == color_from_named(.Blue), "FinalBg on base must pin the base bg")

	pinned := face_merge(Face{}, Face{bg = color_from_named(.Yellow), attributes = {.Final_Bg}})
	testing.expect(t, pinned.bg == color_from_named(.Yellow), "FinalBg on face must pin the face bg")
}

@(test)
face_test_merge_attributes_union :: proc(t: ^testing.T) {
	base := Face{attributes = {.Bold}}
	face := Face{attributes = {.Italic}}
	merged := face_merge(base, face)
	testing.expect(t, merged.attributes == Face_Attribute{.Bold, .Italic}, "attributes must union")
}

@(test)
face_test_merge_face_final_attr :: proc(t: ^testing.T) {
	base := Face{attributes = {.Bold, .Final_Fg}}
	face := Face{attributes = {.Italic, .Final_Attr}}
	merged := face_merge(base, face)
	// The face layer wins but keeps the base Final flags.
	testing.expect(
		t,
		merged.attributes == Face_Attribute{.Italic, .Final_Attr, .Final_Fg},
		"face FinalAttr must keep face attrs plus base Final flags",
	)
}

@(test)
face_test_merge_base_final_attr :: proc(t: ^testing.T) {
	base := Face{attributes = {.Bold, .Final_Attr}}
	face := Face{attributes = {.Italic, .Underline}}
	merged := face_merge(base, face)
	testing.expect(t, merged.attributes == base.attributes, "base FinalAttr must keep the base attrs")
}

@(test)
face_test_merge_alpha_blend :: proc(t: ^testing.T) {
	base_rgb, _ := color_from_rgb(255, 0, 0)
	face_rgba, _ := color_from_rgb(0, 0, 255, 128)
	merged := face_merge(Face{fg = base_rgb}, Face{fg = face_rgba})
	// r: 255*127/255 = 127, g: 0, b: 255*128/255 = 128, a: 128+127 = 255.
	want, _ := color_from_rgb(127, 0, 128)
	testing.expect(t, merged.fg == want, "translucent RGB face must blend over an RGB base")
}

@(test)
face_test_merge_no_blend_without_rgb_pair :: proc(t: ^testing.T) {
	translucent, _ := color_from_rgb(0, 0, 255, 128)
	// Named base: no blending, the face color wins as-is.
	merged := face_merge(Face{fg = color_from_named(.Red)}, Face{fg = translucent})
	testing.expect(t, merged.fg == translucent, "named base must not blend")

	// Opaque face: no blending either.
	base_rgb, _ := color_from_rgb(255, 0, 0)
	opaque, _ := color_from_rgb(0, 255, 0)
	merged_opaque := face_merge(Face{fg = base_rgb}, Face{fg = opaque})
	testing.expect(t, merged_opaque.fg == opaque, "opaque face must win without blending")
}

@(test)
face_test_merge_underline :: proc(t: ^testing.T) {
	base := Face{underline = color_from_named(.Red)}
	face := Face{underline = color_from_named(.Green)}
	merged := face_merge(base, face)
	testing.expect(t, merged.underline == color_from_named(.Green), "face underline must win")
	fallback := face_merge(base, Face{})
	testing.expect(t, fallback.underline == color_from_named(.Red), "Default underline must fall through")
}

@(test)
face_test_hash_consistent :: proc(t: ^testing.T) {
	a := Face{fg = color_from_named(.Red), bg = color_from_named(.Blue), attributes = {.Bold}}
	b := a
	testing.expect_value(t, face_hash(a), face_hash(b))
	c := Face{fg = color_from_named(.Red), bg = color_from_named(.Blue), attributes = {.Italic}}
	testing.expect(t, face_hash(a) != face_hash(c), "different attrs should hash different")
}
