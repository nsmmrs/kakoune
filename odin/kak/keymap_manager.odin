// Port of Kakoune's src/keymap_manager.{hh,cc}.
//
// A Keymap_Manager maps (key, mode) pairs to a key list plus docstring.
// Managers form a parent chain (mirroring Scope nesting): get_mapping
// falls back to the parent when the local table has no entry, and
// get_mapped_keys unions parent keys with local ones. User mode names
// are stored once at the root of the chain.
//
// Ownership: the manager clones every mapping and docstring with its
// own allocator (see keymap_manager_init); keymap_manager_destroy
// frees them. Pointers returned by keymap_manager_get_mapping borrow
// the manager and are invalidated by the next map/unmap on it.
package kak

import "core:mem"

// Keymap_Manager_Mode mirrors KeymapMode. Zero value None means no mode.
Keymap_Manager_Mode :: enum {
	None,
	Normal,
	Insert,
	Prompt,
	Menu,
	Goto,
	View,
	User,
	Object,
	Combine,
	First_User_Mode,
}

// Keymap_Manager_Error reports add_user_mode failures. Zero value None
// is success. The C++ throws runtime_error with a formatted message;
// the three non-None values preserve the three distinct cases.
Keymap_Manager_Error :: enum {
	None,
	// The name is already a regular mode.
	Regular_Mode,
	// The user mode is already defined.
	Already_Defined,
	// The name contains characters outside is_identifier.
	Invalid_Name,
}

// Keymap_Manager_Info is one mapping: the replacement keys, its
// docstring, and whether it executes atomically. Both keys and
// docstring are owned by the manager.
Keymap_Manager_Info :: struct {
	keys:      Keys_Key_List,
	docstring: string,
	atomic:    bool,
}

// Keymap_Manager_Key_And_Mode is the table key, mirroring KeyAndMode.
Keymap_Manager_Key_And_Mode :: struct {
	key:  Keys_Key,
	mode: Keymap_Manager_Mode,
}

// Keymap_Manager owns its mapping table. user_modes is only populated
// at the root; children delegate to it via keymap_manager_user_modes.
Keymap_Manager :: struct {
	parent:     ^Keymap_Manager,
	mapping:    map[Keymap_Manager_Key_And_Mode]Keymap_Manager_Info,
	user_modes: [dynamic]string,
	allocator:  mem.Allocator,
}

// Regular mode names, in the same order as in add_user_mode.
keymap_manager_REGULAR_MODES: [9]string = {
	"normal",
	"insert",
	"prompt",
	"menu",
	"goto",
	"view",
	"user",
	"object",
	"combine",
}

// keymap_manager_init creates a root manager (no parent).
keymap_manager_init :: proc(allocator := context.allocator) -> Keymap_Manager {
	return {parent = nil, allocator = allocator}
}

// keymap_manager_init_child creates a manager whose lookups fall back
// to parent.
keymap_manager_init_child :: proc(parent: ^Keymap_Manager, allocator := context.allocator) -> Keymap_Manager {
	return {parent = parent, allocator = allocator}
}

// keymap_manager_destroy frees all mappings, docstrings, and user mode
// names owned by m. Each manager frees only its own table; destroy the
// root to free the user mode list.
keymap_manager_destroy :: proc(m: ^Keymap_Manager) {
	for _, &info in m.mapping {
		delete(info.keys)
		if len(info.docstring) > 0 {
			delete(info.docstring, m.allocator)
		}
	}
	delete(m.mapping)
	for name in m.user_modes {
		delete(name, m.allocator)
	}
	delete(m.user_modes)
	m^ = {}
}

// keymap_manager_reparent changes the fallback parent of m.
keymap_manager_reparent :: proc(m: ^Keymap_Manager, parent: ^Keymap_Manager) {
	m.parent = parent
}

// keymap_manager_map_key installs (or replaces) the mapping for
// (key, mode). The mapping and docstring are cloned; the caller keeps
// ownership of its copies.
keymap_manager_map_key :: proc(
	m: ^Keymap_Manager,
	key: Keys_Key,
	mode: Keymap_Manager_Mode,
	mapping: []Keys_Key,
	docstring: string,
	atomic := false,
) {
	k := Keymap_Manager_Key_And_Mode{key, mode}
	if old, ok := m.mapping[k]; ok {
		delete(old.keys)
		if len(old.docstring) > 0 {
			delete(old.docstring, m.allocator)
		}
	}
	keys := make(Keys_Key_List, len(mapping), m.allocator)
	copy(keys[:], mapping)
	doc := ""
	if len(docstring) > 0 {
		buf := make([]byte, len(docstring), m.allocator)
		copy(buf, docstring)
		doc = string(buf)
	}
	m.mapping[k] = Keymap_Manager_Info{keys, doc, atomic}
}

// keymap_manager_unmap_key removes the local mapping for (key, mode),
// if any. Parent mappings are untouched.
keymap_manager_unmap_key :: proc(m: ^Keymap_Manager, key: Keys_Key, mode: Keymap_Manager_Mode) {
	k := Keymap_Manager_Key_And_Mode{key, mode}
	if old, ok := m.mapping[k]; ok {
		delete(old.keys)
		if len(old.docstring) > 0 {
			delete(old.docstring, m.allocator)
		}
		delete_key(&m.mapping, k)
	}
}

// keymap_manager_unmap_keys removes every local mapping for mode.
// Parent mappings are untouched.
keymap_manager_unmap_keys :: proc(m: ^Keymap_Manager, mode: Keymap_Manager_Mode) {
	keys := make([dynamic]Keymap_Manager_Key_And_Mode, context.temp_allocator)
	for k in m.mapping {
		if k.mode == mode {
			append(&keys, k)
		}
	}
	for k in keys {
		keymap_manager_unmap_key(m, k.key, k.mode)
	}
}

// keymap_manager_get_mapping returns the mapping for (key, mode),
// falling back to the parent chain. Returns nil when no manager in
// the chain maps it. The pointer borrows m.
keymap_manager_get_mapping :: proc(
	m: ^Keymap_Manager,
	key: Keys_Key,
	mode: Keymap_Manager_Mode,
) -> ^Keymap_Manager_Info {
	k := Keymap_Manager_Key_And_Mode{key, mode}
	if k in m.mapping {
		return &m.mapping[k]
	}
	if m.parent != nil {
		return keymap_manager_get_mapping(m.parent, key, mode)
	}
	return nil
}

// keymap_manager_get_mapped_keys returns the keys mapped in mode,
// parent keys first, without duplicates. The caller owns the result
// and must delete it with the same allocator.
keymap_manager_get_mapped_keys :: proc(
	m: ^Keymap_Manager,
	mode: Keymap_Manager_Mode,
	allocator := context.allocator,
) -> [dynamic]Keys_Key {
	res := make([dynamic]Keys_Key, allocator)
	if m.parent != nil {
		parent_keys := keymap_manager_get_mapped_keys(m.parent, mode, allocator)
		defer delete(parent_keys)
		for k in parent_keys {
			append(&res, k)
		}
	}
	for k in m.mapping {
		if k.mode == mode && !ranges_contains(res[:], k.key) {
			append(&res, k.key)
		}
	}
	return res
}

// keymap_manager_user_modes returns the user mode list stored at the
// root of the chain. The pointer borrows the root manager.
keymap_manager_user_modes :: proc(m: ^Keymap_Manager) -> ^[dynamic]string {
	if m.parent != nil {
		return keymap_manager_user_modes(m.parent)
	}
	return &m.user_modes
}

// keymap_manager_add_user_mode registers a user mode name at the root.
// Like the C++, an empty name passes the identifier check and is added.
keymap_manager_add_user_mode :: proc(m: ^Keymap_Manager, name: string) -> Keymap_Manager_Error {
	modes := keymap_manager_user_modes(m)
	if ranges_contains(keymap_manager_REGULAR_MODES[:], name) {
		return Keymap_Manager_Error.Regular_Mode
	}
	if ranges_contains(modes[:], name) {
		return Keymap_Manager_Error.Already_Defined
	}
	for cp in name {
		if !unicode_is_identifier(cp) {
			return Keymap_Manager_Error.Invalid_Name
		}
	}
	root := m
	for root.parent != nil {
		root = root.parent
	}
	stored := ""
	if len(name) > 0 {
		buf := make([]byte, len(name), root.allocator)
		copy(buf, name)
		stored = string(buf)
	}
	append(modes, stored)
	return Keymap_Manager_Error.None
}
