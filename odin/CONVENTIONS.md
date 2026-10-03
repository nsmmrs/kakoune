# Odin port conventions (package `kak`)

Single package for the whole port until a proven independent lib earns a
split. Read this before writing any `.odin` file here.

## Naming

- Every file starts with a `package kak` clause.
- Every top-level name must contain the module name (case-insensitive):
  `<module>_*` for procs (e.g. `utf8_distance`), `<Module>_*` types (e.g.
  `Json_Value`, `Ranked_Match`), `<module>_test_*` or `test_<module>_*`
  for tests. One package means no two modules may claim the same bare name.
- Enums: zero value is the ok/empty case.

## Types

- C++ `String`/`StringView` → builtin `string`. `cstring` only at a C
  boundary (none yet).
- C++ `Vector`/`Array` → `[dynamic]T` (owned) or `[]T` slices (views).
- C++ `HashMap`/`HashSet` → builtin `map[K]V`. No custom containers.
- No pointer arithmetic; `int` unless a width matters.

## Errors (no exceptions in Odin)

- Simplest sufficient shape: `(value, ok: bool)` or a module error enum
  with `None = ok` as zero, e.g. `Json_Error :: enum { None, ... }`.
- Document ownership: who frees owned returns, which allocator.

## Memory

- Default `context.allocator`; scratch on `context.temp_allocator`.
- Allocating procs take `allocator := context.allocator` and forward it.

## Tests

- Every module gets `<module>_test.odin` with `@(test)` procs using
  `core:testing` (`expect` / `expect_value`).
- Port the C++ `UnitTest` assertions 1:1 first, then add edge cases.
- Verify from the repo root: `odin test ./odin/kak` must pass (it
  both compiles the package and runs its tests).

## Style gate

- `odin build` and `odin check` require `package main`, so `odin test`
  is the compile+test gate for this library. New files must also be
  `-vet -strict-style` clean (`odin test -vet -strict-style ./odin/kak`).
- Idiomatic Odin: procs + structs + explicit loops. No methods, no
  hidden allocation, no `auto_cast`, no `#partial` on exhaustive switches.

## Parallel-port rules (wave phase)

- Create ONLY your assigned files. Never modify another module's files,
  never touch `.lane/`, never commit. The coordinator integrates.
- `knot.odin` is coordinator-owned shared vocabulary (all
  mutually-referential structs/enums/callbacks). Agents read it, never
  write it. Missing a field or type? Report it; the coordinator amends
  and you re-copy the file into your worktree.

## STUB protocol (knot implementations, wave 5+)

Implementation agents compile standalone, so a proc you CALL that lives in
an unmerged module gets a stub in YOUR OWN file, next to your code:

```odin
option_manager_get :: proc(m: ^Option_Manager, name: string) -> ^Option {
	panic("STUB: option_manager_get")
}
```

Rules:

- Body is exactly one line: `panic("STUB: <name>")`. Nothing else.
- Signature comes from the C++ header (knot.odin has the types).
- Never stub a proc from an already-merged module; never stub what you
  implement yourself; never redeclare a knot.odin type.
- The coordinator deletes your stub when the real proc merges (mechanical
  grep for `panic("STUB:`). If your stub's signature disagrees with the
  real proc, the later merge fails to compile in YOUR file and the
  coordinator fixes your call sites (coordinator owns integration).
