// Tests for enum.odin (port of src/enum.hh).
//
// No C++ UnitTest covers this header; tests mirror the desc-table
// lookups in option_to_string/option_from_string (src/option_types.hh).
package kak

import "core:testing"

// Enum_Test_Choice is a sample described enum; Undescribed has no
// table entry, exercising the miss paths.
Enum_Test_Choice :: enum {
	First,
	Second,
	Third,
	Undescribed,
}

@(test)
test_enum_roundtrip :: proc(t: ^testing.T) {
	descs := []Enum_Desc(Enum_Test_Choice){
		{.First, "first"},
		{.Second, "second"},
		{.Third, "third"},
	}
	for d in descs {
		name, ok := enum_to_name(descs, d.value)
		testing.expect(t, ok)
		testing.expect_value(t, name, d.name)

		value, ok2 := enum_from_name(descs, d.name)
		testing.expect(t, ok2)
		testing.expect_value(t, value, d.value)
	}
}

// misses report ok == false instead of throwing (C++ throws runtime_error)
@(test)
test_enum_unknown :: proc(t: ^testing.T) {
	descs := []Enum_Desc(Enum_Test_Choice){
		{.First, "first"},
		{.Second, "second"},
	}
	_, ok := enum_from_name(descs, "bogus")
	testing.expect(t, !ok)
	// empty string never matches
	_, ok = enum_from_name(descs, "")
	testing.expect(t, !ok)
	// a value absent from the table has no name
	_, ok = enum_to_name(descs, Enum_Test_Choice.Undescribed)
	testing.expect(t, !ok)
	// lookup is case-sensitive, like the C++ StringView comparison
	_, ok = enum_from_name(descs, "First")
	testing.expect(t, !ok)
}

// empty tables match nothing
@(test)
test_enum_empty_desc :: proc(t: ^testing.T) {
	empty: []Enum_Desc(Enum_Test_Choice)
	_, ok := enum_to_name(empty, Enum_Test_Choice.First)
	testing.expect(t, !ok)
	_, ok = enum_from_name(empty, "first")
	testing.expect(t, !ok)
}
