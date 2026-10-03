// Tests for the value module ported from src/value.hh.
// No C++ UnitTest covers value.hh; these assert the ported behavior.
package kak

import "core:testing"

// Zero Value is empty: invalid, is_a false for every type.
@(test)
value_test_empty :: proc(t: ^testing.T) {
	v: Value
	testing.expect(t, !value_is_valid(v))
	testing.expect(t, !value_is_a(v, int))
	testing.expect(t, !value_is_a(v, string))
	// Freeing an empty Value is a no-op.
	value_free(&v)
	testing.expect(t, !value_is_valid(v))
}

// Round trip: make an int, check type, read it back.
@(test)
value_test_int_round_trip :: proc(t: ^testing.T) {
	v := value_make(42)
	defer value_free(&v)
	testing.expect(t, value_is_valid(v))
	testing.expect(t, value_is_a(v, int))
	testing.expect(t, !value_is_a(v, string))
	p, err := value_as(v, int)
	testing.expect_value(t, err, Value_Error.None)
	testing.expect_value(t, p^, 42)
}

// as<T> returns a live pointer: mutation through it sticks.
@(test)
value_test_as_mutates :: proc(t: ^testing.T) {
	v := value_make(7)
	defer value_free(&v)
	p, err := value_as(v, int)
	testing.expect_value(t, err, Value_Error.None)
	p^ = 99
	q, _ := value_as(v, int)
	testing.expect_value(t, q^, 99)
}

// Wrong type returns Bad_Cast and a nil pointer (C++ throws bad_value_cast).
@(test)
value_test_bad_cast :: proc(t: ^testing.T) {
	v := value_make(42)
	defer value_free(&v)
	p, err := value_as(v, string)
	testing.expect_value(t, err, Value_Error.Bad_Cast)
	testing.expect(t, p == nil)
	// The Value still holds its payload after a failed cast.
	testing.expect(t, value_is_valid(v))
	testing.expect(t, value_is_a(v, int))
}

// Casting an empty Value fails too.
@(test)
value_test_bad_cast_empty :: proc(t: ^testing.T) {
	v: Value
	p, err := value_as(v, int)
	testing.expect_value(t, err, Value_Error.Bad_Cast)
	testing.expect(t, p == nil)
}

// Strings and structs round-trip, including distinct int types.
@(test)
value_test_other_types :: proc(t: ^testing.T) {
	vs := value_make(string("hello"))
	defer value_free(&vs)
	ps, errs := value_as(vs, string)
	testing.expect_value(t, errs, Value_Error.None)
	testing.expect_value(t, ps^, "hello")

	vi := value_make(Value_Id(3))
	defer value_free(&vi)
	testing.expect(t, value_is_a(vi, Value_Id))
	testing.expect(t, !value_is_a(vi, int))
	pi, erri := value_as(vi, Value_Id)
	testing.expect_value(t, erri, Value_Error.None)
	testing.expect_value(t, pi^, Value_Id(3))
}

// value_make copies: later changes to the source do not alias the payload.
@(test)
value_test_make_copies :: proc(t: ^testing.T) {
	src := 10
	v := value_make(src)
	defer value_free(&v)
	src = 20
	p, _ := value_as(v, int)
	testing.expect_value(t, p^, 10)
}

// value_free resets to empty and is idempotent.
@(test)
value_test_free_resets :: proc(t: ^testing.T) {
	v := value_make(1)
	value_free(&v)
	testing.expect(t, !value_is_valid(v))
	testing.expect(t, !value_is_a(v, int))
	value_free(&v)
	testing.expect(t, !value_is_valid(v))
}

// Minted ids are unique and increase.
@(test)
value_test_ids_unique :: proc(t: ^testing.T) {
	a := value_get_free_id()
	b := value_get_free_id()
	c := value_get_free_id()
	testing.expect(t, a != b && b != c && a != c)
	testing.expect(t, int(a) < int(b) && int(b) < int(c))
}

// Value_Map stores Values by id like the C++ ValueMap.
@(test)
value_test_map :: proc(t: ^testing.T) {
	m := make(Value_Map)
	defer {
		for _, &v in m {
			value_free(&v)
		}
		delete(m)
	}
	id := value_get_free_id()
	m[id] = value_make(123)
	got, ok := m[id]
	testing.expect(t, ok)
	p, err := value_as(got, int)
	testing.expect_value(t, err, Value_Error.None)
	testing.expect_value(t, p^, 123)
}
