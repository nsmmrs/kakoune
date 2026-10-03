// Port of Kakoune's src/value.hh: a type-erased value holder.
//
// The C++ Concept/Model virtuals plus UniquePtr become Odin's builtin
// `any` plus the context allocator: value_make copies the payload onto
// the heap, value_as recovers a typed pointer, value_free releases it.
// The C++ `bad_value_cast` exception becomes Value_Error.Bad_Cast, and
// `ValueMap` (a HashMap) becomes the builtin map Value_Map.
package kak

// Value_Error is the module error. Zero value `None` is success;
// `Bad_Cast` ports the C++ `bad_value_cast` throw from `as<T>()`.
Value_Error :: enum {
	None,
	Bad_Cast,
}

// Value is a type-erased holder. The zero value is empty (no payload).
// The payload is owned: value_free releases it with the allocator that
// value_make used.
Value :: struct {
	data: any,
}

// Value_Id ports C++ `ValueId`: an opaque key minted by value_get_free_id.
Value_Id :: distinct int

// Value_Map ports C++ `ValueMap` as a builtin map. Callers own both the
// map and each Value payload (value_free each element, then delete the map).
Value_Map :: map[Value_Id]Value

// Next free id for value_get_free_id.
@(private = "file")
value_next_free_id := 0

// value_make copies `val` onto the heap and wraps it in a Value.
// Caller releases with value_free using the same allocator.
value_make :: proc(val: $T, allocator := context.allocator) -> Value {
	p := new(T, allocator)
	p^ = val
	return Value{data = p^}
}

// value_is_valid reports whether the Value holds a payload.
// Ports C++ `explicit operator bool`.
value_is_valid :: proc(v: Value) -> bool {
	return v.data != nil
}

// value_is_a reports whether the payload has type T. Ports C++ `is_a<T>`.
value_is_a :: proc(v: Value, $T: typeid) -> bool {
	return v.data != nil && v.data.id == T
}

// value_as returns a pointer to the payload when it has type T, so
// callers can read and mutate it like the C++ `T& as<T>()` reference.
// A missing payload or a type mismatch returns Bad_Cast.
value_as :: proc(v: Value, $T: typeid) -> (^T, Value_Error) {
	if !value_is_a(v, T) {
		return nil, .Bad_Cast
	}
	return cast(^T)v.data.data, .None
}

// value_free releases the payload and resets the Value to empty. Freeing
// an empty Value is a no-op. Must use the allocator value_make used.
value_free :: proc(v: ^Value, allocator := context.allocator) {
	if v.data == nil {
		return
	}
	free(v.data.data, allocator)
	v.data = nil
}

// value_get_free_id mints a fresh id, starting from 0.
// Ports C++ `get_free_value_id` (whose static counter starts at 0).
value_get_free_id :: proc() -> Value_Id {
	id := Value_Id(value_next_free_id)
	value_next_free_id += 1
	return id
}
