// Port of Kakoune's src/face_registry.{hh,cc}.
//
// face_registry_parse implements parse_face: a description is
// "[<fg>][,<bg>[,<underline>]][+<attrs>][@base]" or a bare base face
// name. face_registry_face_to_string and
// face_registry_attributes_to_string implement the to_string
// overloads, and Face_Registry implements the scoped registry with
// its 29 default faces.
//
// Differences from the C++:
// - The C++ throws runtime_error; here every failure is a
//   Face_Registry_Error.
// - A comma after '@' and a '+' after '@' read out of bounds in the
//   C++; here they report Invalid_Description.
// - flatten_faces returns a lazy range in C++; here
//   face_registry_flatten returns an owned array (same entries:
//   three scope levels, nearer scopes winning on name clashes).
//
// Ownership: the registry owns its name keys and spec bases,
// allocated with the allocator passed to face_registry_make; free
// them with face_registry_destroy. face_registry_parse returns an
// owned base string; free it with face_registry_spec_destroy.
// face_registry_flatten returns owned entries freed with
// face_registry_flatten_free. Procs returning string allocate with
// allocator (default context.allocator); the caller frees with
// delete(s, allocator).
package kak

import "core:mem"
import "core:strings"

// Face_Registry_Error reports face parsing and registry failures.
// Zero value None is success.
Face_Registry_Error :: enum {
	None,
	// face_registry_parse: malformed description (misplaced comma,
	// trailing '+' or comma, comma or '+' after '@').
	Invalid_Description,
	// face_registry_parse: a color field is neither a color name nor
	// an rgb:/rgba: value (the C++ str_to_color throws).
	Invalid_Color,
	// face_registry_parse: unknown '+' attribute character.
	Unknown_Attribute,
	// face_registry_add: empty name, a color name, or a name with
	// non-word characters.
	Invalid_Name,
	// face_registry_add: name already defined without override.
	Already_Defined,
	// face_registry_add: the new face would close a base cycle.
	Face_Cycle,
}

// Face_Registry_Spec pairs a face with an optional base face name
// (port of C++ FaceSpec); an empty base means no base.
Face_Registry_Spec :: struct {
	face: Face,
	base: string,
}

// Face_Registry maps face names to specs with an optional parent
// scope (port of C++ FaceRegistry; the C++ SafePtr parent is a plain
// pointer here).
Face_Registry :: struct {
	parent:    ^Face_Registry,
	faces:     map[string]Face_Registry_Spec,
	allocator: mem.Allocator,
}

// Face_Registry_Entry is one flattened name/spec pair (port of one
// item of the flatten_faces range).
Face_Registry_Entry :: struct {
	name: string,
	spec: Face_Registry_Spec,
}

@(private = "file")
Face_Registry_Default :: struct {
	name: string,
	// Palette tags; face_registry_make converts them with
	// color_from_named (procedures cannot run in a global
	// initializer).
	fg, bg, underline: Color_Named,
	attributes:        Face_Attribute,
	base:              string,
}

// face_registry_defaults is the default face table (port of the
// private FaceRegistry() constructor).
@(private = "file")
face_registry_defaults := [?]Face_Registry_Default{
	{name = "Default"},
	{name = "PrimarySelection", fg = .White, bg = .Blue},
	{name = "SecondarySelection", fg = .Black, bg = .Blue},
	{name = "PrimaryCursor", fg = .Black, bg = .White},
	{name = "SecondaryCursor", fg = .Black, bg = .White},
	{name = "PrimaryCursorEol", fg = .Black, bg = .Cyan},
	{name = "SecondaryCursorEol", fg = .Black, bg = .Cyan},
	{name = "LineNumbers"},
	{name = "LineNumberCursor", attributes = {.Reverse}},
	{name = "LineNumbersWrapped", attributes = {.Italic}},
	{name = "WrapMarker", fg = .Blue},
	{name = "MenuForeground", fg = .White, bg = .Blue},
	{name = "MenuBackground", fg = .Blue, bg = .White},
	{name = "MenuInfo", fg = .Cyan},
	{name = "Information", fg = .Black, bg = .Yellow},
	{name = "InlineInformation", base = "Information"},
	{name = "Error", fg = .Black, bg = .Red},
	{name = "DiagnosticError", fg = .Red},
	{name = "DiagnosticWarning", fg = .Yellow},
	{name = "StatusLine", fg = .Cyan},
	{name = "StatusLineMode", fg = .Yellow},
	{name = "StatusLineInfo", fg = .Blue},
	{name = "StatusLineValue", fg = .Green},
	{name = "StatusCursor", fg = .Black, bg = .Cyan},
	{name = "Prompt", fg = .Yellow},
	{name = "MatchingChar", attributes = {.Bold}},
	{name = "BufferPadding", fg = .Blue},
	{name = "Whitespace", attributes = {.Final_Fg}},
	{name = "WhitespaceIndent", base = "Whitespace"},
}

// face_registry_make builds a registry. A nil parent builds a root
// registry preloaded with the default faces (port of the private
// FaceRegistry()); a non-nil parent builds an empty child scope
// (port of FaceRegistry(parent)). Free with face_registry_destroy.
face_registry_make :: proc(parent: ^Face_Registry = nil, allocator := context.allocator) -> Face_Registry {
	reg := Face_Registry{parent = parent, allocator = allocator}
	if parent == nil {
		reg.faces = make(map[string]Face_Registry_Spec, len(face_registry_defaults) * 2, allocator)
		for d in face_registry_defaults {
			key := strings.clone(d.name, allocator)
			base := strings.clone(d.base, allocator)
			face := Face{
				fg         = color_from_named(d.fg),
				bg         = color_from_named(d.bg),
				attributes = d.attributes,
				underline  = color_from_named(d.underline),
			}
			reg.faces[key] = Face_Registry_Spec{face = face, base = base}
		}
	} else {
		reg.faces = make(map[string]Face_Registry_Spec, 0, allocator)
	}
	return reg
}

// face_registry_destroy frees the registry's names, bases and map.
// It does not touch the parent.
face_registry_destroy :: proc(reg: ^Face_Registry) {
	for key, spec in reg.faces {
		delete(key, reg.allocator)
		delete(spec.base, reg.allocator)
	}
	delete(reg.faces)
}

// face_registry_reparent repoints the parent scope (port of C++
// FaceRegistry::reparent).
// face_registry_reparent chains reg under parent. A root registry
// preloads the builtin faces; once chained those copies would shadow
// the parent's entries (e.g. colorscheme redefinitions), so they are
// dropped (buffer scopes are the only root-to-child transition; local
// scopes are never roots and keep their faces).
face_registry_reparent :: proc(reg: ^Face_Registry, parent: ^Face_Registry) {
	if reg.parent == nil {
		for key, spec in reg.faces {
			delete(key, reg.allocator)
			delete(spec.base, reg.allocator)
		}
		clear(&reg.faces)
	}
	reg.parent = parent
}

// face_registry_is_word_str reports whether every byte of s is a
// word character (port of the all_of/is_word checks; like the C++,
// the empty string passes). Bytes convert through i8 like the C++
// char-to-Codepoint conversion, so high bytes are negative and never
// word characters.
@(private = "file")
face_registry_is_word_str :: proc(s: string) -> bool {
	underscore := [1]rune{'_'}
	for i := 0; i < len(s); i += 1 {
		if !unicode_is_word(rune(i8(s[i])), underscore[:]) {
			return false
		}
	}
	return true
}

// face_registry_parse_color parses one color field: empty means
// Default, otherwise a color name or rgb:/rgba: value (port of the
// parse_color lambda in parse_face).
@(private = "file")
face_registry_parse_color :: proc(s: string) -> (Color, Face_Registry_Error) {
	if len(s) == 0 {
		return color_from_named(.Default), .None
	}
	c, err := color_from_string(s)
	if err != .None {
		return {}, .Invalid_Color
	}
	return c, .None
}

// face_registry_parse parses a face description (port of C++
// parse_face). A description that is all word characters and not a
// color name is a bare base face name; otherwise it is
// "[<fg>][,<bg>[,<underline>]][+<attrs>][@base]". The returned base
// is owned; free it with face_registry_spec_destroy.
face_registry_parse :: proc(facedesc: string, allocator := context.allocator) -> (Face_Registry_Spec, Face_Registry_Error) {
	if face_registry_is_word_str(facedesc) && !color_is_name(facedesc) {
		return Face_Registry_Spec{face = Face{}, base = strings.clone(facedesc, allocator)}, .None
	}
	end := len(facedesc)
	bg_pos := end
	if bg := strings.index_byte(facedesc, ','); bg >= 0 {
		bg_pos = bg
	}
	underline_pos := end
	if bg_pos != end {
		if rel := strings.index_byte(facedesc[bg_pos + 1:], ','); rel >= 0 {
			underline_pos = bg_pos + 1 + rel
		}
	}
	attr_pos := end
	if attr := strings.index_byte(facedesc, '+'); attr >= 0 {
		attr_pos = attr
	}
	base_pos := end
	if base := strings.index_byte(facedesc, '@'); base >= 0 {
		base_pos = base
	}
	if bg_pos != end && (attr_pos < bg_pos || bg_pos + 1 == end) {
		return {}, .Invalid_Description
	}
	if attr_pos != end && attr_pos + 1 == end {
		return {}, .Invalid_Description
	}
	colors_end := min(attr_pos, base_pos)
	if underline_pos != end && underline_pos > colors_end {
		return {}, .Invalid_Description
	}
	// The C++ builds a reversed range for a comma after '@' and
	// overruns the string for a '+' after '@'; report both instead.
	if bg_pos != end && bg_pos > colors_end {
		return {}, .Invalid_Description
	}
	if attr_pos != end && base_pos != end && attr_pos > base_pos {
		return {}, .Invalid_Description
	}

	spec: Face_Registry_Spec
	fg, err := face_registry_parse_color(facedesc[:min(bg_pos, colors_end)])
	if err != .None {
		return {}, err
	}
	spec.face.fg = fg
	if bg_pos != end {
		bgc, bg_err := face_registry_parse_color(facedesc[bg_pos + 1:min(underline_pos, colors_end)])
		if bg_err != .None {
			return {}, bg_err
		}
		spec.face.bg = bgc
		if underline_pos != end {
			underline, ul_err := face_registry_parse_color(facedesc[underline_pos + 1:colors_end])
			if ul_err != .None {
				return {}, ul_err
			}
			spec.face.underline = underline
		}
	}
	if attr_pos != end {
		for i := attr_pos + 1; i < base_pos; i += 1 {
			switch facedesc[i] {
			case 'u':
				spec.face.attributes += {.Underline}
			case 'c':
				spec.face.attributes += {.Curly_Underline}
			case 'U':
				spec.face.attributes += {.Double_Underline}
			case 'r':
				spec.face.attributes += {.Reverse}
			case 'b':
				spec.face.attributes += {.Bold}
			case 'B':
				spec.face.attributes += {.Blink}
			case 'd':
				spec.face.attributes += {.Dim}
			case 'i':
				spec.face.attributes += {.Italic}
			case 's':
				spec.face.attributes += {.Strikethrough}
			case 'f':
				spec.face.attributes += {.Final_Fg}
			case 'g':
				spec.face.attributes += {.Final_Bg}
			case 'a':
				spec.face.attributes += {.Final_Attr}
			case 'F':
				spec.face.attributes += Face_Final
			case:
				return {}, .Unknown_Attribute
			}
		}
	}
	if base_pos != end {
		spec.base = strings.clone(facedesc[base_pos + 1:], allocator)
	}
	return spec, .None
}

// face_registry_spec_destroy frees a spec returned by
// face_registry_parse. The allocator must be the one passed to the
// parse.
face_registry_spec_destroy :: proc(spec: ^Face_Registry_Spec, allocator := context.allocator) {
	delete(spec.base, allocator)
	spec.base = ""
}

// face_registry_attributes_to_string renders the attribute set
// (port of C++ to_string(Attribute)): "" when empty, otherwise
// "+<chars>" with Final greedily rendered as 'F'. Caller frees the
// result.
face_registry_attributes_to_string :: proc(attrs: Face_Attribute, allocator := context.allocator) -> string {
	if attrs == {} {
		return strings.clone("", allocator)
	}
	entries := [?]struct {
		flags: Face_Attribute,
		ch:    byte,
	}{
		{{.Underline}, 'u'},
		{{.Curly_Underline}, 'c'},
		{{.Double_Underline}, 'U'},
		{{.Reverse}, 'r'},
		{{.Blink}, 'B'},
		{{.Bold}, 'b'},
		{{.Dim}, 'd'},
		{{.Italic}, 'i'},
		{{.Strikethrough}, 's'},
		{Face_Final, 'F'},
		{{.Final_Fg}, 'f'},
		{{.Final_Bg}, 'g'},
		{{.Final_Attr}, 'a'},
	}
	b := strings.builder_make(0, 8, allocator)
	strings.write_byte(&b, '+')
	remaining := attrs
	for e in entries {
		if e.flags <= remaining {
			strings.write_byte(&b, e.ch)
			remaining -= e.flags
		}
	}
	return strings.to_string(b)
}

// face_registry_face_to_string renders "<fg>,<bg>,<underline>[+attrs]"
// (port of C++ to_string(Face)). Caller frees the result.
face_registry_face_to_string :: proc(face: Face, allocator := context.allocator) -> string {
	fg := color_to_string(face.fg, allocator)
	defer delete(fg, allocator)
	bg := color_to_string(face.bg, allocator)
	defer delete(bg, allocator)
	underline := color_to_string(face.underline, allocator)
	defer delete(underline, allocator)
	attrs := face_registry_attributes_to_string(face.attributes, allocator)
	defer delete(attrs, allocator)
	b := strings.builder_make(0, len(fg) + len(bg) + len(underline) + len(attrs) + 2, allocator)
	strings.write_string(&b, fg)
	strings.write_byte(&b, ',')
	strings.write_string(&b, bg)
	strings.write_byte(&b, ',')
	strings.write_string(&b, underline)
	strings.write_string(&b, attrs)
	return strings.to_string(b)
}

// face_registry_resolve resolves a spec against the registry chain
// (port of C++ FaceRegistry::resolve_spec and operator[](FaceSpec)):
// a spec without a base is returned as-is, otherwise the base face
// is looked up through this registry and its parents and the spec's
// own face is merged over it. A self-based face (built by
// face_registry_add merging into an existing name) keeps searching
// the outer scopes for its base. Unknown bases resolve to the
// spec's own face.
face_registry_resolve :: proc(reg: ^Face_Registry, spec: Face_Registry_Spec) -> Face {
	if len(spec.base) == 0 {
		return spec.face
	}
	base := spec.base
	face := spec.face
	r := reg
	for r != nil {
		if found, ok := r.faces[base]; ok {
			if len(found.base) == 0 {
				return face_merge(found.face, face)
			}
			if found.base != base {
				return face_merge(face_registry_resolve(r, found), face)
			}
			face = face_merge(found.face, face)
		}
		r = r.parent
	}
	return face
}

// face_registry_lookup parses a face description and resolves it
// (port of C++ FaceRegistry::operator[](StringView)). The allocator
// is only used for the transient parse; nothing owned is returned.
face_registry_lookup :: proc(reg: ^Face_Registry, facedesc: string, allocator := context.allocator) -> (Face, Face_Registry_Error) {
	spec, err := face_registry_parse(facedesc, allocator)
	if err != .None {
		return {}, err
	}
	defer face_registry_spec_destroy(&spec, allocator)
	return face_registry_resolve(reg, spec), .None
}

// face_registry_add defines a face (port of C++
// FaceRegistry::add_face). Without override, redefining a name
// reports Already_Defined; redefining a name with itself as base
// merges the new face into the existing one. A base cycle reports
// Face_Cycle. NOTE: like the C++, chaining a new face onto a
// self-based face ("X" based on "X") loops forever in the cycle
// probe; callers must avoid building on self-based faces.
face_registry_add :: proc(reg: ^Face_Registry, name, facedesc: string, override := false) -> Face_Registry_Error {
	if !override && name in reg.faces {
		return .Already_Defined
	}
	if len(name) == 0 || color_is_name(name) || !face_registry_is_word_str(name) {
		return .Invalid_Name
	}
	spec, err := face_registry_parse(facedesc, reg.allocator)
	if err != .None {
		return err
	}
	if existing, ok := reg.faces[spec.base]; ok && spec.base == name {
		merged := face_merge(existing.face, spec.face)
		delete(existing.base, reg.allocator)
		delete(spec.base, reg.allocator)
		reg.faces[name] = Face_Registry_Spec{face = merged, base = strings.clone(name, reg.allocator)}
		return .None
	}
	probe, ok := reg.faces[spec.base]
	for ok && len(probe.base) != 0 {
		if probe.base == name {
			delete(spec.base, reg.allocator)
			return .Face_Cycle
		}
		probe, ok = reg.faces[probe.base]
	}
	if name in reg.faces {
		delete(reg.faces[name].base, reg.allocator)
		reg.faces[name] = spec
	} else {
		key := strings.clone(name, reg.allocator)
		reg.faces[key] = spec
	}
	return .None
}

// face_registry_remove undefines a face, freeing its name and base
// (port of C++ FaceRegistry::remove_face). Removing an unknown name
// is a no-op.
face_registry_remove :: proc(reg: ^Face_Registry, name: string) {
	spec, ok := reg.faces[name]
	if !ok {
		return
	}
	delete(spec.base, reg.allocator)
	// Capture the stored key, then remove the slot BEFORE freeing the
	// key bytes: delete_key compares stored keys during probing, so
	// freeing first reads freed memory and can leave a ghost entry.
	// (The removal happens outside the loop: mutating during iteration
	// is not allowed.)
	stored_key, found := "", false
	for key in reg.faces {
		if key == name {
			stored_key, found = key, true
			break
		}
	}
	assert(found) // reg.faces[name] succeeded above
	delete_key(&reg.faces, name)
	delete(stored_key, reg.allocator)
}

// face_registry_flatten lists the visible faces from the three scope
// levels (grandparent, parent, self), nearer scopes winning on name
// clashes (port of C++ FaceRegistry::flatten_faces). Caller frees
// with face_registry_flatten_free, using the same allocator.
face_registry_flatten :: proc(reg: ^Face_Registry, allocator := context.allocator) -> [dynamic]Face_Registry_Entry {
	levels: [3]^Face_Registry
	count := 0
	r := reg
	for r != nil && count < len(levels) {
		levels[count] = r
		count += 1
		r = r.parent
	}
	out := make([dynamic]Face_Registry_Entry, 0, 32, allocator)
	for i := count - 1; i >= 0; i -= 1 {
		for key, spec in levels[i].faces {
			replaced := false
			for &entry in out {
				if entry.name == key {
					delete(entry.name, allocator)
					delete(entry.spec.base, allocator)
					entry.name = strings.clone(key, allocator)
					entry.spec = Face_Registry_Spec{face = spec.face, base = strings.clone(spec.base, allocator)}
					replaced = true
					break
				}
			}
			if !replaced {
				append(&out, Face_Registry_Entry{
					name = strings.clone(key, allocator),
					spec = Face_Registry_Spec{face = spec.face, base = strings.clone(spec.base, allocator)},
				})
			}
		}
	}
	return out
}

// face_registry_flatten_free frees entries returned by
// face_registry_flatten. The allocator must be the one passed to the
// flatten call.
face_registry_flatten_free :: proc(entries: ^[dynamic]Face_Registry_Entry, allocator := context.allocator) {
	for &entry in entries {
		delete(entry.name, allocator)
		delete(entry.spec.base, allocator)
	}
	delete(entries^)
}
