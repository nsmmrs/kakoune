// Port of Kakoune's src/env_vars.{hh,cc}: snapshot the process environment.
//
// The C++ scans `environ` for the first '=' in each entry; entries without
// one map to "". `get_env_vars` returns a HashMap, which becomes the
// builtin map Env_Var_Map here. The scan itself lives in
// env_vars_split_entry so it is unit-testable without touching the real
// environment.
package kak

import "core:os"
import "core:strings"

// Env_Var_Map ports C++ `EnvVarMap` as a builtin map. Keys and values are
// owned clones; release with env_vars_free.
Env_Var_Map :: map[string]string

// env_vars_split_entry splits one environ entry at the first '='.
// Entries without '=' yield an empty value, exactly like the C++ loop.
env_vars_split_entry :: proc(entry: string) -> (name, value: string) {
	for i := 0; i < len(entry); i += 1 {
		if entry[i] == '=' {
			return entry[:i], entry[i + 1:]
		}
	}
	return entry, ""
}

// env_vars_get snapshots the process environment into an owned map.
// Ports C++ `get_env_vars`. Caller releases with env_vars_free using the
// same allocator. On failure returns a nil map and the os error.
env_vars_get :: proc(allocator := context.allocator) -> (Env_Var_Map, os.Error) {
	env, err := os.environ(allocator)
	if err != nil {
		return nil, err
	}
	m := make(Env_Var_Map, len(env), allocator)
	for e in env {
		name, value := env_vars_split_entry(e)
		// Duplicate names occur in real environments (e.g. SHELL set by
		// both login and the spawner). Like C++ HashMap::insert, the
		// first entry wins; later ones are dropped, not overwritten
		// (overwriting would leak the replaced clones).
		if name in m {
			delete(e, allocator)
			continue
		}
		m[strings.clone(name, allocator)] = strings.clone(value, allocator)
		delete(e, allocator)
	}
	delete(env, allocator)
	return m, nil
}

// env_vars_free releases every key, value, and the map itself.
// Must use the allocator env_vars_get used.
env_vars_free :: proc(m: ^Env_Var_Map, allocator := context.allocator) {
	for k, v in m^ {
		delete(k, allocator)
		delete(v, allocator)
	}
	delete(m^)
	m^ = nil
}
