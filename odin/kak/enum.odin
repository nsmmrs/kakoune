// Port of Kakoune's src/enum.hh (EnumDesc + DescribedEnum).
//
// C++ associates a description table with an enum type via an
// enum_desc() overload found by argument-dependent lookup. Odin has no
// equivalent, so callers pass the desc slice explicitly to
// enum_to_name / enum_from_name. The bit-ops (flags) string forms from
// option_types.hh live in the option_types module, not here.
package kak

// Enum_Desc pairs an enum value with its canonical name.
Enum_Desc :: struct(T: typeid) {
	value: T,
	name:  string,
}

// enum_to_name looks up the canonical name of value, mirroring the
// find_if over the desc table in C++ option_to_string.
enum_to_name :: proc(descs: []Enum_Desc($T), value: T) -> (name: string, ok: bool) {
	for d in descs {
		if d.value == value {
			return d.name, true
		}
	}
	return "", false
}

// enum_from_name parses a canonical name back to its value, mirroring
// the find_if in C++ option_from_string (where a miss throws).
enum_from_name :: proc(descs: []Enum_Desc($T), name: string) -> (value: T, ok: bool) {
	for d in descs {
		if d.name == name {
			return d.value, true
		}
	}
	return value, false
}
