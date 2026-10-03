// Port of src/scope.{hh,cc} and src/local_scope.hh: scopes bundle the
// six per-scope managers, the global scope adds the options registry,
// and local scopes stack on a context for the duration of a command.
//
// Mapping notes:
//   * Scope_Data heap-allocates so embedded managers keep stable
//     addresses for watcher registration; Scope itself is just the
//     pointer and must be destroyed exactly once.
//   * Hook_Manager and Highlighters live in unmerged modules, but both
//     are plain knot.odin structs, so scopes initialize and destroy them
//     directly instead of stubbing: hooks destroy fully (Hook_Data holds
//     only strings and a Regex), highlighter children destroy through
//     their knot.odin vtable when present. Only run_hook (needed by the
//     GlobalSetOption watcher) is STUBBED below.
//   * Like C++ Scope::reparent, scope_reparent repoints every manager at
//     the new parent's managers.
//   * The C++ GlobalScope singleton becomes a reference-counted
//     package-level instance behind a mutex: each scope_global_init
//     needs a matching scope_global_deinit, and the scope is destroyed
//     when the last holder lets go.
//
// Ownership: scope_make/scope_make_child return a Scope owning heap data;
// scope_destroy frees it with the same allocator. Global and local
// scopes are heap objects freed by their destroy procs.
package kak

import "core:fmt"
import "core:sync"

// scope_hooks_init builds hooks state with parent (C++ HookManager
// ctors, which only set the parent link).
scope_hooks_init :: proc(parent: ^Hook_Manager, allocator := context.allocator) -> Hook_Manager {
	return Hook_Manager{parent = parent, allocator = allocator}
}

// scope_hooks_destroy frees every hook list and trashed hook. Hook_Data
// is a plain struct, so this is complete without the hook module.
scope_hooks_destroy :: proc(m: ^Hook_Manager) {
	for &list in m.hooks {
		for hd in list {
			scope_hook_data_destroy(hd, m.allocator)
		}
		delete(list)
	}
	for hd in m.hooks_trash {
		scope_hook_data_destroy(hd, m.allocator)
	}
	delete(m.hooks_trash)
	delete(m.running_hooks)
}

// scope_hook_data_destroy frees one heap hook (params stay borrowed,
// like the C++ StringView running-hook params).
scope_hook_data_destroy :: proc(hd: ^Hook_Data, allocator := context.allocator) {
	regex_destroy(&hd.filter)
	delete(hd.group, allocator)
	delete(hd.commands, allocator)
	free(hd, allocator)
}

// scope_highlighters_init builds highlighters state with parent (C++
// Highlighters ctors: parent link plus an All-passes root group).
scope_highlighters_init :: proc(parent: ^Highlighters, allocator := context.allocator) -> Highlighters {
	return Highlighters {
		parent = parent,
		group = Highlighter_Group {
			base = Highlighter {
				vtable = nil,
				passes = {.Replace, .Wrap, .Move, .Colorize},
				data = nil,
			},
			highlighters = make(map[string]^Highlighter, allocator),
			allocator = allocator,
		},
	}
}

// scope_highlighters_destroy frees the root group. Children destroy
// through their vtable when present, then their heap shell is freed;
// coordinator: adjust if the highlighter module allocates children
// differently (no child-adding proc exists yet, so groups are always
// empty in standalone use).
scope_highlighters_destroy :: proc(h: ^Highlighters) {
	for k, child in h.group.highlighters {
		if child.vtable != nil && child.vtable.destroy != nil {
			child.vtable.destroy(child.data, h.group.allocator)
		}
		delete(k, h.group.allocator)
		free(child, h.group.allocator)
	}
	delete(h.group.highlighters)
}

// scope_make builds a root scope with fresh managers (C++ Scope()).
scope_make :: proc(allocator := context.allocator) -> Scope {
	data := new(Scope_Data, allocator)
	option_manager_init_root(&data.options, allocator)
	data.hooks = scope_hooks_init(nil, allocator)
	data.keymaps = keymap_manager_init(allocator)
	data.aliases = alias_registry_make_root(allocator)
	data.faces = face_registry_make(nil, allocator)
	data.highlighters = scope_highlighters_init(nil, allocator)
	return Scope{data = data}
}

// scope_make_child builds a scope whose managers fall back to parent's
// (C++ Scope(parent)).
scope_make_child :: proc(parent: ^Scope, allocator := context.allocator) -> Scope {
	data := new(Scope_Data, allocator)
	option_manager_init_child(&data.options, &parent.data.options, allocator)
	data.hooks = scope_hooks_init(&parent.data.hooks, allocator)
	data.keymaps = keymap_manager_init_child(&parent.data.keymaps, allocator)
	data.aliases = alias_registry_make_child(&parent.data.aliases, allocator)
	data.faces = face_registry_make(&parent.data.faces, allocator)
	data.highlighters = scope_highlighters_init(&parent.data.highlighters, allocator)
	return Scope{data = data}
}

// scope_destroy frees a scope's managers and data (C++ ~Scope, which
// destroys members in reverse declaration order). Destroy child scopes
// first: their option managers watch this one's.
scope_destroy :: proc(s: ^Scope, allocator := context.allocator) {
	scope_highlighters_destroy(&s.data.highlighters)
	face_registry_destroy(&s.data.faces)
	alias_registry_destroy(&s.data.aliases)
	keymap_manager_destroy(&s.data.keymaps)
	scope_hooks_destroy(&s.data.hooks)
	option_manager_destroy(&s.data.options)
	free(s.data, allocator)
}

// scope_options returns the scope's option manager (C++ options()).
scope_options :: proc(s: ^Scope) -> ^Option_Manager {
	return &s.data.options
}

// scope_hooks returns the scope's hook manager (C++ hooks()).
scope_hooks :: proc(s: ^Scope) -> ^Hook_Manager {
	return &s.data.hooks
}

// scope_keymaps returns the scope's keymap manager (C++ keymaps()).
scope_keymaps :: proc(s: ^Scope) -> ^Keymap_Manager {
	return &s.data.keymaps
}

// scope_aliases returns the scope's alias registry (C++ aliases()).
scope_aliases :: proc(s: ^Scope) -> ^Alias_Registry {
	return &s.data.aliases
}

// scope_faces returns the scope's face registry (C++ faces()).
scope_faces :: proc(s: ^Scope) -> ^Face_Registry {
	return &s.data.faces
}

// scope_highlighters returns the scope's highlighters (C++
// highlighters()).
scope_highlighters :: proc(s: ^Scope) -> ^Highlighters {
	return &s.data.highlighters
}

// scope_reparent repoints every manager at the new parent's managers
// (C++ Scope::reparent).
scope_reparent :: proc(s: ^Scope, parent: ^Scope) {
	option_manager_reparent(&s.data.options, &parent.data.options)
	s.data.hooks.parent = &parent.data.hooks
	keymap_manager_reparent(&s.data.keymaps, &parent.data.keymaps)
	alias_registry_reparent(&s.data.aliases, &parent.data.aliases)
	face_registry_reparent(&s.data.faces, &parent.data.faces)
	s.data.highlighters.parent = &parent.data.highlighters
}

// scope_global_make builds a heap global scope: a root scope plus the
// global data (options registry) and the GlobalSetOption watcher (C++
// GlobalScope).
scope_global_make :: proc(allocator := context.allocator) -> ^Global_Scope {
	g := new(Global_Scope, allocator)
	g.scope = scope_make(allocator)
	g.global_data = new(Global_Scope_Data, allocator)
	g.global_data.parent = &g.scope
	option_manager_registry_init(&g.global_data.option_registry, &g.scope.data.options, allocator)
	option_manager_register_watcher(
		&g.scope.data.options,
		Option_Watcher{data = g, on_option_changed = scope_global_watcher_callback},
	)
	return g
}

// scope_global_destroy unregisters the watcher and frees the global
// scope (C++ ~GlobalScope; the watcher must go before the options).
scope_global_destroy :: proc(g: ^Global_Scope, allocator := context.allocator) {
	option_manager_unregister_watcher(
		&g.scope.data.options,
		Option_Watcher{data = g, on_option_changed = scope_global_watcher_callback},
	)
	scope_destroy(&g.scope, allocator)
	option_manager_registry_destroy(&g.global_data.option_registry)
	free(g.global_data, allocator)
	free(g, allocator)
}

// scope_global_option_registry returns the options registry (C++
// option_registry()).
scope_global_option_registry :: proc(g: ^Global_Scope) -> ^Options_Registry {
	return &g.global_data.option_registry
}

// scope_global_watcher_callback runs the GlobalSetOption hook for a
// changed global option (C++ GlobalScope::GlobalData::on_option_changed).
// It calls the STUBBED run_hook, so standalone callers must not change
// global options with notification enabled.
scope_global_watcher_callback :: proc(data: rawptr, option: rawptr) {
	g := (^Global_Scope)(data)
	opt := (^Option)(option)
	desc := option_manager_option_get_desc_string(opt, context.temp_allocator)
	param := fmt.aprintf("{}={}", option_manager_option_name(opt), desc, allocator = context.temp_allocator)
	ctx := Context{}
	hook_manager_run_hook(&g.scope.data.hooks, .Global_Set_Option, param, &ctx)
}

// scope_global_singleton is the process-wide global scope (C++
// Singleton<GlobalScope>). It is reference-counted behind a mutex so
// concurrent users (tests run multithreaded) share it safely: every
// scope_global_init needs a matching scope_global_deinit, and the scope
// is destroyed when the last holder lets go.
scope_global_singleton: ^Global_Scope
scope_global_refcount: int
scope_global_mutex: sync.Mutex

// scope_global_init creates (or returns) the process-wide global scope,
// holding one reference for the caller.
scope_global_init :: proc(allocator := context.allocator) -> ^Global_Scope {
	sync.mutex_lock(&scope_global_mutex)
	defer sync.mutex_unlock(&scope_global_mutex)
	if scope_global_singleton == nil {
		scope_global_singleton = scope_global_make(allocator)
	}
	scope_global_refcount += 1
	return scope_global_singleton
}

// scope_global_instance observes the process-wide global scope, or nil
// when uninitialized. Callers that act on the result (like unset moving
// options to trash) must hold an init reference across the use.
scope_global_instance :: proc() -> ^Global_Scope {
	sync.mutex_lock(&scope_global_mutex)
	defer sync.mutex_unlock(&scope_global_mutex)
	return scope_global_singleton
}

// scope_global_deinit releases one init reference, destroying the scope
// when the last one goes. The destroy runs outside the lock (unlinked
// first), since destruction itself takes the lock for trash cleanup.
scope_global_deinit :: proc(allocator := context.allocator) {
	sync.mutex_lock(&scope_global_mutex)
	if scope_global_refcount == 0 {
		sync.mutex_unlock(&scope_global_mutex)
		return
	}
	scope_global_refcount -= 1
	dying: ^Global_Scope
	if scope_global_refcount == 0 {
		dying = scope_global_singleton
		scope_global_singleton = nil
	}
	sync.mutex_unlock(&scope_global_mutex)
	if dying != nil {
		scope_global_destroy(dying, allocator)
	}
}

// scope_local_make builds a heap local scope over parent and pushes it
// on the context's local scope stack (C++ LocalScope; the parent is an
// explicit parameter here because context.scope() lives in the unmerged
// context module).
scope_local_make :: proc(ctx: ^Context, parent: ^Scope, allocator := context.allocator) -> ^Local_Scope {
	l := new(Local_Scope, allocator)
	l.scope = scope_make_child(parent, allocator)
	l.ctx = ctx
	append(&ctx.local_scopes, &l.scope)
	return l
}

// scope_local_destroy pops a local scope off its context stack and frees
// it (C++ ~LocalScope, which requires LIFO order).
scope_local_destroy :: proc(l: ^Local_Scope, allocator := context.allocator) {
	n := len(l.ctx.local_scopes)
	assert(n > 0 && l.ctx.local_scopes[n - 1] == &l.scope)
	pop(&l.ctx.local_scopes)
	scope_destroy(&l.scope, allocator)
	free(l, allocator)
}

// ---------------------------------------------------------------------------
// Remainder implementations (C++ names from local_scope.hh / scope.hh)
// ---------------------------------------------------------------------------

// local_scope_make builds a child scope of the context's current scope
// and pushes it on the context's local scope stack (C++ LocalScope
// ctor). Pair with local_scope_destroy. Deviation: the C++ object lives
// on the caller's stack and pushes `this`, which a value-returning Odin
// proc cannot do (the returned value is a copy); instead the stack holds
// a heap Scope shell with the same data, freed by the destroy proc. The
// shell is invisible to scope accessors, which only read .data.
local_scope_make :: proc(ctx: ^Context) -> Local_Scope {
	ls := Local_Scope{ctx = ctx}
	ls.scope = scope_make_child(context_scope(ctx))
	shell := new(Scope)
	shell^ = ls.scope
	append(&ctx.local_scopes, shell)
	return ls
}

// local_scope_destroy pops a local scope off its context stack and frees
// it (C++ ~LocalScope, which requires LIFO order; the data-identity
// assert is the equivalent of the C++ back() == this check).
local_scope_destroy :: proc(s: ^Local_Scope) {
	n := len(s.ctx.local_scopes)
	assert(n > 0)
	shell := pop(&s.ctx.local_scopes)
	assert(shell.data == s.scope.data)
	free(shell)
	scope_destroy(&s.scope)
}

// global_scope_option_registry returns the process-wide global scope's
// options registry (C++ GlobalScope::instance().option_registry()). The
// global scope must be initialized (scope_global_init).
global_scope_option_registry :: proc() -> ^Options_Registry {
	return scope_global_option_registry(scope_global_instance())
}

// hook_manager_run_hook runs hook with param (C++
// HookManager::run_hook in hook_manager.hh).
