// Port of Kakoune's src/utils.hh.
//
// Only the runtime-semantics pieces are portable. The rest is C++
// template machinery whose Odin equivalent is a language feature,
// so it is intentionally not ported:
//
//   * Singleton<T>      -> package-level state holds the one instance.
//   * OnScopeEnd        -> the `defer` statement.
//   * FunctionRef       -> a plain `proc` value (see Format_Append).
//   * Overload/overload -> a `proc` group (see format_to_string).
//   * to_underlying     -> the `int(val)` / `u8(val)` conversion.
//
// Ownership: nothing here allocates.
package kak

// Utils_Nested_Bool is a bool that can be set multiple times and
// reads false only after being unset as many times (port of C++
// NestedBool).
Utils_Nested_Bool :: struct {
	count: int,
}

// utils_nested_bool_set pushes one set level.
utils_nested_bool_set :: proc(nb: ^Utils_Nested_Bool) {
	nb.count += 1
}

// utils_nested_bool_unset pops one set level. Like the C++, popping
// an unset bool is a bug and asserts.
utils_nested_bool_unset :: proc(nb: ^Utils_Nested_Bool) {
	assert(nb.count > 0)
	nb.count -= 1
}

// utils_nested_bool_is_set reports whether any set level is held.
utils_nested_bool_is_set :: proc(nb: Utils_Nested_Bool) -> bool {
	return nb.count > 0
}

// Utils_Scoped_Bool is the RAII half of C++ ScopedSetBool, adapted
// to explicit release: make it, then `defer utils_scoped_bool_release`.
//
// Usage:
//
// 	guard := utils_scoped_bool_make(&nb)
// 	defer utils_scoped_bool_release(&guard)
Utils_Scoped_Bool :: struct {
	nb:     ^Utils_Nested_Bool,
	active: bool,
}

// utils_scoped_bool_make sets nb (unless condition is false) and
// returns a guard that releases it. A moved-from C++ guard releases
// nothing; here that is a zero-value guard with active == false.
utils_scoped_bool_make :: proc(nb: ^Utils_Nested_Bool, condition := true) -> Utils_Scoped_Bool {
	if condition {
		utils_nested_bool_set(nb)
	}
	return {nb, condition}
}

// utils_scoped_bool_release unsets the guarded bool, once: a second
// call (or releasing an inactive guard) is a no-op.
utils_scoped_bool_release :: proc(guard: ^Utils_Scoped_Bool) {
	if guard.active {
		utils_nested_bool_unset(guard.nb)
	}
	guard.active = false
}

// utils_clamp returns val pinned into [lo, hi] (port of C++ clamp).
utils_clamp :: proc(val, lo, hi: $T) -> T {
	return clamp(val, lo, hi)
}

// utils_skip_while advances pos^ past leading elements satisfying
// cond and reports whether one that does not remains (port of C++
// skip_while, whose iterator pair becomes a slice plus an index).
utils_skip_while :: proc(s: []$T, pos: ^int, cond: proc(T) -> bool) -> bool {
	for pos^ < len(s) && cond(s[pos^]) {
		pos^ += 1
	}
	return pos^ < len(s)
}

// utils_skip_while_reverse moves pos^ back over trailing elements
// satisfying cond and reports whether the element it stops on
// satisfies cond too (port of C++ skip_while_reverse).
//
// Deviation: the C++ dereferences the begin iterator even for an
// empty range (undefined behavior); here an empty slice clamps
// pos^ to 0 and returns false, and an out-of-range pos^ is clamped
// into the slice instead of invoking undefined behavior.
utils_skip_while_reverse :: proc(s: []$T, pos: ^int, cond: proc(T) -> bool) -> bool {
	if len(s) == 0 {
		pos^ = 0
		return false
	}
	pos^ = clamp(pos^, 0, len(s) - 1)
	for pos^ > 0 && cond(s[pos^]) {
		pos^ -= 1
	}
	return cond(s[pos^])
}
