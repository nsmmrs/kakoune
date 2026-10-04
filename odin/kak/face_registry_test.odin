// Tests for the face_registry module (port of
// src/face_registry.{hh,cc}). The C++ ships no unit tests here, so
// these cover the parse_face contract (colors, attributes, bases,
// errors), the to_string roundtrip, and the registry (defaults,
// add/remove/override, cycles, scopes, flattening).
package kak

import "core:testing"

@(test)
face_registry_test_parse_fg_only :: proc(t: ^testing.T) {
	spec, err := face_registry_parse("red")
	defer face_registry_spec_destroy(&spec)
	testing.expect_value(t, err, Face_Registry_Error.None)
	testing.expect(t, spec.face.fg == color_from_named(.Red), "fg must parse")
	testing.expect(t, spec.face.bg == color_from_named(.Default), "bg must default")
	testing.expect_value(t, spec.base, "")
}

@(test)
face_registry_test_parse_fg_bg_underline :: proc(t: ^testing.T) {
	spec, err := face_registry_parse("red,blue,green")
	defer face_registry_spec_destroy(&spec)
	testing.expect_value(t, err, Face_Registry_Error.None)
	testing.expect(t, spec.face.fg == color_from_named(.Red), "fg must parse")
	testing.expect(t, spec.face.bg == color_from_named(.Blue), "bg must parse")
	testing.expect(t, spec.face.underline == color_from_named(.Green), "underline must parse")
}

@(test)
face_registry_test_parse_empty_fields_default :: proc(t: ^testing.T) {
	spec, err := face_registry_parse(",blue")
	defer face_registry_spec_destroy(&spec)
	testing.expect_value(t, err, Face_Registry_Error.None)
	testing.expect(t, spec.face.fg == color_from_named(.Default), "empty fg must default")
	testing.expect(t, spec.face.bg == color_from_named(.Blue), "bg must parse")

	spec2, err2 := face_registry_parse("red,,green")
	defer face_registry_spec_destroy(&spec2)
	testing.expect_value(t, err2, Face_Registry_Error.None)
	testing.expect(t, spec2.face.bg == color_from_named(.Default), "empty bg must default")
	testing.expect(t, spec2.face.underline == color_from_named(.Green), "underline must parse")
}

@(test)
face_registry_test_parse_rgb :: proc(t: ^testing.T) {
	spec, err := face_registry_parse("rgb:ff0000,rgba:00ff0080")
	defer face_registry_spec_destroy(&spec)
	testing.expect_value(t, err, Face_Registry_Error.None)
	want_fg, _ := color_from_rgb(255, 0, 0)
	want_bg, _ := color_from_rgb(0, 255, 0, 128)
	testing.expect(t, spec.face.fg == want_fg, "rgb: fg must parse")
	testing.expect(t, spec.face.bg == want_bg, "rgba: bg must parse")
}

@(test)
face_registry_test_parse_all_attributes :: proc(t: ^testing.T) {
	chars := [?]struct {
		ch:   byte,
		flag: Face_Attribute,
	}{
		{'u', {.Underline}},
		{'c', {.Curly_Underline}},
		{'U', {.Double_Underline}},
		{'r', {.Reverse}},
		{'b', {.Bold}},
		{'B', {.Blink}},
		{'d', {.Dim}},
		{'i', {.Italic}},
		{'s', {.Strikethrough}},
		{'f', {.Final_Fg}},
		{'g', {.Final_Bg}},
		{'a', {.Final_Attr}},
		{'F', Face_Final},
	}
	for c in chars {
		desc := [5]byte{'r', 'e', 'd', '+', c.ch}
		spec, err := face_registry_parse(string(desc[:]))
		face_registry_spec_destroy(&spec)
		testing.expect(t, err == Face_Registry_Error.None, string(desc[:]))
		testing.expect(t, spec.face.attributes == c.flag, string(desc[:]))
	}
	combined, err := face_registry_parse("red+ucUrBbdis")
	defer face_registry_spec_destroy(&combined)
	testing.expect_value(t, err, Face_Registry_Error.None)
	testing.expect(
		t,
		combined.face.attributes ==
		Face_Attribute{.Underline, .Curly_Underline, .Double_Underline, .Reverse, .Bold, .Blink, .Dim, .Italic, .Strikethrough},
		"every attr char must map",
	)
	finals, final_err := face_registry_parse("red+fga")
	defer face_registry_spec_destroy(&finals)
	testing.expect_value(t, final_err, Face_Registry_Error.None)
	testing.expect(t, finals.face.attributes == Face_Final, "fga must set every Final flag")
	big_final, big_err := face_registry_parse("red+F")
	defer face_registry_spec_destroy(&big_final)
	testing.expect_value(t, big_err, Face_Registry_Error.None)
	testing.expect(t, big_final.face.attributes == Face_Final, "F must set every Final flag")
}

@(test)
face_registry_test_parse_base :: proc(t: ^testing.T) {
	spec, err := face_registry_parse("red@PrimarySelection")
	defer face_registry_spec_destroy(&spec)
	testing.expect_value(t, err, Face_Registry_Error.None)
	testing.expect(t, spec.face.fg == color_from_named(.Red), "fg must parse")
	testing.expect_value(t, spec.base, "PrimarySelection")

	full, full_err := face_registry_parse("red,blue,green+bu@Base")
	defer face_registry_spec_destroy(&full)
	testing.expect_value(t, full_err, Face_Registry_Error.None)
	testing.expect(t, full.face.attributes == Face_Attribute{.Bold, .Underline}, "attrs must parse before @")
	testing.expect_value(t, full.base, "Base")
}

@(test)
face_registry_test_parse_bare_base :: proc(t: ^testing.T) {
	spec, err := face_registry_parse("PrimarySelection")
	defer face_registry_spec_destroy(&spec)
	testing.expect_value(t, err, Face_Registry_Error.None)
	testing.expect(t, spec.face == Face{}, "bare base must carry a default face")
	testing.expect_value(t, spec.base, "PrimarySelection")
}

@(test)
face_registry_test_parse_bare_color_is_not_base :: proc(t: ^testing.T) {
	spec, err := face_registry_parse("red")
	defer face_registry_spec_destroy(&spec)
	testing.expect_value(t, err, Face_Registry_Error.None)
	testing.expect_value(t, spec.base, "")

	def, def_err := face_registry_parse("default")
	defer face_registry_spec_destroy(&def)
	testing.expect_value(t, def_err, Face_Registry_Error.None)
	testing.expect(t, def.face == Face{}, "'default' must parse as the default fg")
	testing.expect_value(t, def.base, "")
}

@(test)
face_registry_test_parse_empty :: proc(t: ^testing.T) {
	spec, err := face_registry_parse("")
	defer face_registry_spec_destroy(&spec)
	testing.expect_value(t, err, Face_Registry_Error.None)
	testing.expect(t, spec.face == Face{}, "empty description must give the default face")
	testing.expect_value(t, spec.base, "")
}

@(test)
face_registry_test_parse_errors :: proc(t: ^testing.T) {
	Traversal :: struct {
		desc: string,
		want: Face_Registry_Error,
	}
	cases := [?]Traversal{
		{"red,", .Invalid_Description}, // trailing comma
		{"red+", .Invalid_Description}, // trailing plus
		{"red+u,blue", .Invalid_Description}, // comma after attrs
		{"red,blue,green,yellow", .Invalid_Color}, // third comma lands in the color
		{"nope,blue", .Invalid_Color}, // bad fg
		{"red,nope", .Invalid_Color}, // bad bg
		{"red,blue,nope", .Invalid_Color}, // bad underline
		{"rgb:12345", .Invalid_Color}, // short rgb
		{"red+z", .Unknown_Attribute}, // bad attr char
		{"red@a,b", .Invalid_Description}, // comma after @
		{"red@a+b", .Invalid_Description}, // plus after @
	}
	for c in cases {
		spec, err := face_registry_parse(c.desc)
		face_registry_spec_destroy(&spec)
		testing.expect(t, err == c.want, c.desc)
	}
}

@(test)
face_registry_test_attributes_to_string :: proc(t: ^testing.T) {
	empty := face_registry_attributes_to_string({})
	defer delete(empty)
	testing.expect_value(t, empty, "")

	attrs := face_registry_attributes_to_string({.Bold, .Underline})
	defer delete(attrs)
	testing.expect_value(t, attrs, "+ub")

	final := face_registry_attributes_to_string(Face_Final)
	defer delete(final)
	testing.expect_value(t, final, "+F")

	partial := face_registry_attributes_to_string({.Final_Fg, .Final_Attr})
	defer delete(partial)
	testing.expect_value(t, partial, "+fa")
}

@(test)
face_registry_test_face_to_string :: proc(t: ^testing.T) {
	def := face_registry_face_to_string(Face{})
	defer delete(def)
	testing.expect_value(t, def, "default,default,default")

	face := Face{
		fg         = color_from_named(.Red),
		bg         = color_from_named(.Blue),
		attributes = {.Bold, .Underline},
		underline  = color_from_named(.Green),
	}
	s := face_registry_face_to_string(face)
	defer delete(s)
	testing.expect_value(t, s, "red,blue,green+ub")
}

@(test)
face_registry_test_to_string_roundtrip :: proc(t: ^testing.T) {
	face := Face{
		fg         = color_from_named(.Yellow),
		bg         = color_from_named(.Black),
		attributes = {.Italic, .Final_Bg},
		underline  = color_from_named(.Cyan),
	}
	s := face_registry_face_to_string(face)
	defer delete(s)
	spec, err := face_registry_parse(s)
	defer face_registry_spec_destroy(&spec)
	testing.expect_value(t, err, Face_Registry_Error.None)
	testing.expect(t, spec.face == face, "parse(to_string(face)) must roundtrip")
	testing.expect_value(t, spec.base, "")
}

@(test)
face_registry_test_default_faces :: proc(t: ^testing.T) {
	reg := face_registry_make()
	defer face_registry_destroy(&reg)

	sel, err := face_registry_lookup(&reg, "PrimarySelection")
	testing.expect_value(t, err, Face_Registry_Error.None)
	testing.expect(
		t,
		sel.fg == color_from_named(.White) && sel.bg == color_from_named(.Blue),
		"PrimarySelection must be white on blue",
	)

	cursor, _ := face_registry_lookup(&reg, "LineNumberCursor")
	testing.expect(t, .Reverse in cursor.attributes, "LineNumberCursor must be reversed")

	// Aliases resolve through their base.
	inline, _ := face_registry_lookup(&reg, "InlineInformation")
	info, _ := face_registry_lookup(&reg, "Information")
	testing.expect(t, inline == info, "InlineInformation must alias Information")
	indent, _ := face_registry_lookup(&reg, "WhitespaceIndent")
	whitespace, _ := face_registry_lookup(&reg, "Whitespace")
	testing.expect(t, indent == whitespace, "WhitespaceIndent must alias Whitespace")
	testing.expect(t, .Final_Fg in whitespace.attributes, "Whitespace must pin fg")
}

@(test)
face_registry_test_lookup_unknown_base :: proc(t: ^testing.T) {
	reg := face_registry_make()
	defer face_registry_destroy(&reg)
	face, err := face_registry_lookup(&reg, "NoSuchFace")
	testing.expect_value(t, err, Face_Registry_Error.None)
	testing.expect(t, face == Face{}, "unknown base must resolve to the spec face")
}

@(test)
face_registry_test_lookup_merges_over_base :: proc(t: ^testing.T) {
	reg := face_registry_make()
	defer face_registry_destroy(&reg)
	face, err := face_registry_lookup(&reg, "red@PrimarySelection")
	testing.expect_value(t, err, Face_Registry_Error.None)
	testing.expect(t, face.fg == color_from_named(.Red), "spec fg must win over base")
	testing.expect(t, face.bg == color_from_named(.Blue), "base bg must show through")
}

@(test)
face_registry_test_add_and_remove :: proc(t: ^testing.T) {
	reg := face_registry_make()
	defer face_registry_destroy(&reg)
	testing.expect_value(t, face_registry_add(&reg, "Mine", "red,blue+u"), Face_Registry_Error.None)
	face, err := face_registry_lookup(&reg, "Mine")
	testing.expect_value(t, err, Face_Registry_Error.None)
	testing.expect(t, face.fg == color_from_named(.Red) && face.bg == color_from_named(.Blue), "added face must resolve")
	testing.expect(t, face.attributes == Face_Attribute{.Underline}, "added attrs must resolve")

	testing.expect(
		t,
		face_registry_add(&reg, "Mine", "green") == Face_Registry_Error.Already_Defined,
		"redefining without override must fail",
	)
	testing.expect_value(t, face_registry_add(&reg, "Mine", "green", true), Face_Registry_Error.None)
	overridden, _ := face_registry_lookup(&reg, "Mine")
	testing.expect(t, overridden.fg == color_from_named(.Green), "override must replace the face")

	face_registry_remove(&reg, "Mine")
	removed, _ := face_registry_lookup(&reg, "Mine")
	testing.expect(t, removed == Face{}, "removed face must resolve to default")
	face_registry_remove(&reg, "Mine")
	testing.expect(t, true, "removing twice must not crash")
}

@(test)
face_registry_test_add_invalid_names :: proc(t: ^testing.T) {
	reg := face_registry_make()
	defer face_registry_destroy(&reg)
	bad_names := [?]string{"", "red", "has space", "a+b", "a,b", "a@b"}
	for name in bad_names {
		testing.expect(t, face_registry_add(&reg, name, "red") == Face_Registry_Error.Invalid_Name, name)
	}
	testing.expect_value(t, face_registry_add(&reg, "with_underscore1", "red"), Face_Registry_Error.None)
}

@(test)
face_registry_test_add_bad_description :: proc(t: ^testing.T) {
	reg := face_registry_make()
	defer face_registry_destroy(&reg)
	testing.expect_value(t, face_registry_add(&reg, "Bad", "red+z"), Face_Registry_Error.Unknown_Attribute)
	testing.expect(t, "Bad" not_in reg.faces, "failed add must not store the face")
}

@(test)
face_registry_test_add_cycle :: proc(t: ^testing.T) {
	reg := face_registry_make()
	defer face_registry_destroy(&reg)
	testing.expect_value(t, face_registry_add(&reg, "CycleA", "@CycleB"), Face_Registry_Error.None)
	testing.expect(
		t,
		face_registry_add(&reg, "CycleB", "@CycleA") == Face_Registry_Error.Face_Cycle,
		"closing a base cycle must fail",
	)
	testing.expect_value(t, face_registry_add(&reg, "CycleC", "@CycleC"), Face_Registry_Error.None)
	// NOTE: chaining another face onto the self-based CycleC is
	// deliberately untested: the C++ cycle probe revisits the
	// self-based entry forever (upstream infinite loop), and this
	// port keeps the same loop for 1:1 behavior.
}

@(test)
face_registry_test_add_self_base_merges :: proc(t: ^testing.T) {
	reg := face_registry_make()
	defer face_registry_destroy(&reg)
	testing.expect_value(t, face_registry_add(&reg, "Self", "red"), Face_Registry_Error.None)
	testing.expect_value(t, face_registry_add(&reg, "Self", "blue@Self", true), Face_Registry_Error.None)
	face, err := face_registry_lookup(&reg, "Self")
	testing.expect_value(t, err, Face_Registry_Error.None)
	testing.expect(t, face.fg == color_from_named(.Blue), "self-based redefine must merge over the old face")
}

@(test)
face_registry_test_chained_bases :: proc(t: ^testing.T) {
	reg := face_registry_make()
	defer face_registry_destroy(&reg)
	testing.expect_value(t, face_registry_add(&reg, "ChainC", "red,blue"), Face_Registry_Error.None)
	testing.expect_value(t, face_registry_add(&reg, "ChainB", "green@ChainC"), Face_Registry_Error.None)
	testing.expect_value(t, face_registry_add(&reg, "ChainA", "+u@ChainB"), Face_Registry_Error.None)
	face, err := face_registry_lookup(&reg, "ChainA")
	testing.expect_value(t, err, Face_Registry_Error.None)
	testing.expect(t, face.fg == color_from_named(.Green), "middle fg must win")
	testing.expect(t, face.bg == color_from_named(.Blue), "root bg must show through")
	testing.expect(t, face.attributes == Face_Attribute{.Underline}, "leaf attrs must apply")
}

@(test)
face_registry_test_child_scope :: proc(t: ^testing.T) {
	root := face_registry_make()
	defer face_registry_destroy(&root)
	child := face_registry_make(&root)
	defer face_registry_destroy(&child)

	testing.expect(t, len(child.faces) == 0, "child scope must start empty")
	face, err := face_registry_lookup(&child, "PrimarySelection")
	testing.expect_value(t, err, Face_Registry_Error.None)
	testing.expect(t, face.bg == color_from_named(.Blue), "child must see parent faces")

	testing.expect_value(t, face_registry_add(&child, "PrimarySelection", "red"), Face_Registry_Error.None)
	shadowed, _ := face_registry_lookup(&child, "PrimarySelection")
	testing.expect(t, shadowed.fg == color_from_named(.Red), "child face must shadow the parent")
	unshadowed, _ := face_registry_lookup(&root, "PrimarySelection")
	testing.expect(t, unshadowed.fg == color_from_named(.White), "parent must be unaffected")
}

@(test)
face_registry_test_reparent :: proc(t: ^testing.T) {
	root := face_registry_make()
	defer face_registry_destroy(&root)
	other := face_registry_make()
	defer face_registry_destroy(&other)
	testing.expect_value(t, face_registry_add(&other, "OnlyThere", "red"), Face_Registry_Error.None)
	child := face_registry_make(&root)
	defer face_registry_destroy(&child)

	before, _ := face_registry_lookup(&child, "OnlyThere")
	testing.expect(t, before == Face{}, "face must be invisible before reparenting")
	face_registry_reparent(&child, &other)
	after, _ := face_registry_lookup(&child, "OnlyThere")
	testing.expect(t, after.fg == color_from_named(.Red), "face must resolve after reparenting")
}

@(test)
face_registry_test_flatten :: proc(t: ^testing.T) {
	root := face_registry_make()
	defer face_registry_destroy(&root)
	child := face_registry_make(&root)
	defer face_registry_destroy(&child)
	testing.expect_value(t, face_registry_add(&child, "PrimarySelection", "red"), Face_Registry_Error.None)
	testing.expect_value(t, face_registry_add(&child, "ChildOnly", "green"), Face_Registry_Error.None)

	entries := face_registry_flatten(&child)
	defer face_registry_flatten_free(&entries)
	by_name := make(map[string]Face, len(entries))
	defer delete(by_name)
	for e in entries {
		by_name[e.name] = e.spec.face
	}
	testing.expect(t, len(entries) == len(by_name), "flatten must not duplicate names")
	testing.expect(t, by_name["PrimarySelection"].fg == color_from_named(.Red), "child must win in flatten")
	testing.expect(t, by_name["ChildOnly"].fg == color_from_named(.Green), "child-only face must appear")
	testing.expect(t, by_name["Error"].bg == color_from_named(.Red), "parent-only face must appear")
}

@(test)
face_registry_test_remove_repeated_no_ghost :: proc(t: ^testing.T) {
	// Regression (difftest3): remove used to free the key bytes before
	// delete_key, so the removal probe could read freed memory and
	// leave a ghost entry; repeated add/remove cycles corrupted the
	// heap. Cycle a full registry several times.
	reg := face_registry_make()
	defer face_registry_destroy(&reg)
	names := [12]string{
		"Alpha", "Beta", "Gamma", "Delta", "Epsilon", "Zeta",
		"Eta", "Theta", "Iota", "Kappa", "Lambda", "Mu",
	}
	for n in names {
		testing.expect_value(t, face_registry_add(&reg, n, "red"), Face_Registry_Error.None)
	}
	for _ in 0 ..< 5 {
		for n in names {
			face_registry_remove(&reg, n)
			_, found := reg.faces[n]
			testing.expect(t, !found, "removed face must be gone")
		}
		for n in names {
			testing.expect_value(t, face_registry_add(&reg, n, "red"), Face_Registry_Error.None)
		}
	}
	face, err := face_registry_lookup(&reg, "Gamma")
	testing.expect_value(t, err, Face_Registry_Error.None)
	testing.expect(t, face.fg == color_from_named(.Red), "cycled registry must resolve")
}

@(test)
face_registry_test_high_byte_names_rejected :: proc(t: ^testing.T) {
	// Like the C++ (is_word over signed bytes), high bytes are never
	// word characters: names are invalid and descriptions fall
	// through to color parsing, which rejects them. (difftest3)
	reg := face_registry_make()
	defer face_registry_destroy(&reg)
	testing.expect_value(
		t,
		face_registry_add(&reg, "Gp\xce", "red"),
		Face_Registry_Error.Invalid_Name,
	)
	testing.expect_value(
		t,
		face_registry_add(&reg, "\xbc", "red"),
		Face_Registry_Error.Invalid_Name,
	)
	_, err := face_registry_parse("n2z4K0\xc3")
	testing.expect(t, err != Face_Registry_Error.None, "high-byte desc must not parse as base")
}

// Reparenting a root registry drops its builtin copies so they never
// shadow the parent's entries (regression: buffer scopes kept stale
// builtins, hiding colorscheme redefinitions like PrimaryCursor+fg).
@(test)
face_registry_test_reparent_drops_builtin_copies :: proc(t: ^testing.T) {
	parent := face_registry_make(nil)
	defer face_registry_destroy(&parent)
	child := face_registry_make(nil)
	defer face_registry_destroy(&child)

	testing.expect_value(
		t,
		face_registry_add(&parent, "PrimaryCursor", "black,white+fg", true),
		Face_Registry_Error.None,
	)
	face_registry_reparent(&child, &parent)

	face, err := face_registry_lookup(&child, "PrimaryCursor")
	testing.expect_value(t, err, Face_Registry_Error.None)
	testing.expect(t, .Final_Fg in face.attributes)
	testing.expect(t, .Final_Bg in face.attributes)
}
