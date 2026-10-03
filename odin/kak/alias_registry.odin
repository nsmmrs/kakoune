// Port of src/alias_registry.hh and src/alias_registry.cc: per-scope
// command aliases with parent-chain fallback.
//
// Mapping notes:
//   * C++ add_alias asserts the alias is non-empty and (debug-only) that
//     the command exists. The command check needs the unmerged command
//     manager, so it is skipped here; an empty alias reports
//     Empty_Alias instead of asserting so callers can handle it.
//   * C++ flatten_aliases returns a lazy merged view; here flatten
//     returns an owned array (caller deletes it, entries stay borrowed).
//
// Ownership: add clones alias and command into the registry allocator;
// destroy frees them.
package kak

import "core:strings"

// Alias_Registry_Error reports alias failures. None (= 0) is success.
Alias_Registry_Error :: enum {
	None,
	Empty_Alias,
}

// alias_registry_error_message describes an error.
alias_registry_error_message :: proc(err: Alias_Registry_Error) -> string {
	switch err {
	case .None:
		return ""
	case .Empty_Alias:
		return "alias must not be empty"
	}
	unreachable()
}

// Alias_Registry_Entry is one flattened alias (borrowed strings).
Alias_Registry_Entry :: struct {
	alias:   string,
	command: string,
}

// alias_registry_make_root builds a root registry with no parent (C++
// private AliasRegistry(), friend of Scope).
alias_registry_make_root :: proc(allocator := context.allocator) -> Alias_Registry {
	return Alias_Registry{parent = nil, aliases = make(map[string]string, allocator), allocator = allocator}
}

// alias_registry_make_child builds an empty registry falling back to
// parent (C++ AliasRegistry(parent)).
alias_registry_make_child :: proc(parent: ^Alias_Registry, allocator := context.allocator) -> Alias_Registry {
	return Alias_Registry{parent = parent, aliases = make(map[string]string, allocator), allocator = allocator}
}

// alias_registry_destroy frees the registry's aliases. It does not touch
// the parent.
alias_registry_destroy :: proc(reg: ^Alias_Registry) {
	for k, v in reg.aliases {
		delete(k, reg.allocator)
		delete(v, reg.allocator)
	}
	delete(reg.aliases)
}

// alias_registry_reparent repoints the parent scope (C++ reparent).
alias_registry_reparent :: proc(reg: ^Alias_Registry, parent: ^Alias_Registry) {
	reg.parent = parent
}

// alias_registry_add defines alias for command, replacing any local
// definition (C++ add_alias).
alias_registry_add :: proc(reg: ^Alias_Registry, alias, command: string) -> Alias_Registry_Error {
	if len(alias) == 0 {
		return .Empty_Alias
	}
	if alias in reg.aliases {
		delete(reg.aliases[alias], reg.allocator)
		reg.aliases[alias] = strings.clone(command, reg.allocator)
	} else {
		reg.aliases[strings.clone(alias, reg.allocator)] = strings.clone(command, reg.allocator)
	}
	return .None
}

// alias_registry_remove drops the local alias, if present (C++
// remove_alias; a no-op like HashMap::remove when missing).
alias_registry_remove :: proc(reg: ^Alias_Registry, alias: string) {
	stored := ""
	found := false
	for k in reg.aliases {
		if k == alias {
			stored = k
			found = true
			break
		}
	}
	if !found {
		return
	}
	delete(reg.aliases[stored], reg.allocator)
	delete_key(&reg.aliases, stored)
	delete(stored, reg.allocator)
}

// alias_registry_get resolves alias along the parent chain, returning ""
// when undefined (C++ operator[]).
alias_registry_get :: proc(reg: ^Alias_Registry, alias: string) -> string {
	cur := reg
	for cur != nil {
		if cmd, ok := cur.aliases[alias]; ok {
			return cmd
		}
		cur = cur.parent
	}
	return ""
}

// alias_registry_aliases_for lists parent aliases first, then local ones
// naming command (C++ aliases_for). The caller deletes the result; the
// names stay borrowed.
alias_registry_aliases_for :: proc(
	reg: ^Alias_Registry,
	command: string,
	allocator := context.allocator,
) -> [dynamic]string {
	res := make([dynamic]string, allocator)
	if reg.parent != nil {
		parent := alias_registry_aliases_for(reg.parent, command, allocator)
		defer delete(parent)
		append(&res, ..parent[:])
	}
	for k, v in reg.aliases {
		if v == command {
			append(&res, k)
		}
	}
	return res
}

// alias_registry_flatten merges visible aliases with shadowing:
// grandparent entries not overridden, then parent entries not
// overridden, then local entries (C++ flatten_aliases). The caller
// deletes the result; entries stay borrowed.
alias_registry_flatten :: proc(reg: ^Alias_Registry, allocator := context.allocator) -> [dynamic]Alias_Registry_Entry {
	res := make([dynamic]Alias_Registry_Entry, allocator)
	p := reg.parent
	gp := p != nil ? p.parent : nil
	if gp != nil {
		for k, v in gp.aliases {
			if k in p.aliases {
				continue
			}
			if k in reg.aliases {
				continue
			}
			append(&res, Alias_Registry_Entry{alias = k, command = v})
		}
	}
	if p != nil {
		for k, v in p.aliases {
			if k in reg.aliases {
				continue
			}
			append(&res, Alias_Registry_Entry{alias = k, command = v})
		}
	}
	for k, v in reg.aliases {
		append(&res, Alias_Registry_Entry{alias = k, command = v})
	}
	return res
}
