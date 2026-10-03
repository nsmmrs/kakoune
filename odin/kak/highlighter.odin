// Highlighter base framework ported from src/highlighter.{hh,cc}: the
// pass-gated dispatch (highlight, compute_display_setup), the default
// leaf behavior (no children), and the factory registry singleton.
//
// Concrete highlighters (the later highlighters wave) provide their own
// Highlighter_VTable implementations; leaf highlighters reuse the
// highlighter_leaf_* defaults for the child-management slots.
// Highlighters built with highlighter_make_owned are freed with
// highlighter_destroy using the same allocator.
package kak

import "core:mem"

// Highlighter_Error reports highlighter failures (port of the
// runtime_error throws in the C++ base virtuals and of failed lookups).
Highlighter_Error :: enum {
	None,
	No_Children, // leaf highlighter holds no children
	No_Such_Child, // group has no child at the requested path
	No_Such_Factory, // registry has no factory under the name
}

// highlighter_pass_all is C++ HighlightPass::All.
highlighter_pass_all :: Highlight_Pass{.Replace, .Wrap, .Move, .Colorize}

// highlighter_make builds a stack highlighter value (port of the
// Highlighter(passes) constructor plus vtable wiring).
highlighter_make :: proc(passes: Highlight_Pass, vtable: ^Highlighter_VTable, data: rawptr) -> Highlighter {
	return Highlighter{vtable = vtable, passes = passes, data = data}
}

// highlighter_make_owned heap-allocates a highlighter (owned; free with
// highlighter_destroy using the same allocator).
highlighter_make_owned :: proc(
	passes: Highlight_Pass,
	vtable: ^Highlighter_VTable,
	data: rawptr,
	allocator := context.allocator,
) -> ^Highlighter {
	hl := new(Highlighter, allocator)
	hl^ = highlighter_make(passes, vtable, data)
	return hl
}

// highlighter_destroy frees a highlighter built by highlighter_make_owned
// (same allocator). The vtable destroy frees the concrete data.
highlighter_destroy :: proc(hl: ^Highlighter, allocator := context.allocator) {
	hl.vtable.destroy(hl.data, allocator)
	free(hl, allocator)
}

// highlighter_highlight runs one highlight pass when the context pass
// overlaps the highlighter passes (port of Highlighter::highlight). The
// C++ reports runtime errors to the debug buffer; Odin do_highlight
// implementations cannot throw, so no recovery path is needed.
highlighter_highlight :: proc(
	hl: ^Highlighter,
	hctx: Highlight_Context,
	display_buffer: ^Display_Buffer,
	buffer_range: Buffer_Range,
) {
	if card(hctx.pass & hl.passes) > 0 {
		hl.vtable.do_highlight(hl.data, hctx, display_buffer, buffer_range)
	}
}

// highlighter_compute_display_setup adjusts the display setup when the
// context pass overlaps the highlighter passes (port of
// Highlighter::compute_display_setup).
highlighter_compute_display_setup :: proc(hl: ^Highlighter, hctx: Highlight_Context, setup: ^Display_Setup) {
	if card(hctx.pass & hl.passes) > 0 {
		hl.vtable.do_compute_display_setup(hl.data, hctx, setup)
	}
}

// highlighter_passes returns the passes (port of Highlighter::passes).
highlighter_passes :: proc(hl: ^Highlighter) -> Highlight_Pass {
	return hl.passes
}

// highlighter_has_children reports whether the highlighter can hold
// children (port of Highlighter::has_children).
highlighter_has_children :: proc(hl: ^Highlighter) -> bool {
	return hl.vtable.has_children(hl.data)
}

// highlighter_get_child looks a child up by path (port of
// Highlighter::get_child). The child is borrowed from the group.
highlighter_get_child :: proc(
	hl: ^Highlighter,
	path: string,
	allocator := context.allocator,
) -> (
	child: ^Highlighter,
	err: Highlighter_Error,
) {
	if !hl.vtable.has_children(hl.data) {
		return nil, .No_Children
	}
	if found := hl.vtable.get_child(hl.data, path, allocator); found != nil {
		return found, .None
	}
	return nil, .No_Such_Child
}

// highlighter_add_child installs a child (port of
// Highlighter::add_child). The group takes ownership of child on
// success; on error the caller retains ownership.
highlighter_add_child :: proc(
	hl: ^Highlighter,
	name: string,
	child: ^Highlighter,
	override := false,
) -> Highlighter_Error {
	if !hl.vtable.has_children(hl.data) {
		return .No_Children
	}
	hl.vtable.add_child(hl.data, name, child, override)
	return .None
}

// highlighter_remove_child drops the named child (port of
// Highlighter::remove_child).
highlighter_remove_child :: proc(hl: ^Highlighter, id: string) -> Highlighter_Error {
	if !hl.vtable.has_children(hl.data) {
		return .No_Children
	}
	hl.vtable.remove_child(hl.data, id)
	return .None
}

// highlighter_complete_child completes a child path (port of
// Highlighter::complete_child). On error returns zero Completions; on
// success the candidates borrow group memory and only the returned
// array needs freeing.
highlighter_complete_child :: proc(
	hl: ^Highlighter,
	path: string,
	cursor_pos: Units_ByteCount,
	group: bool,
	allocator := context.allocator,
) -> (
	completions: Completions,
	err: Highlighter_Error,
) {
	if !hl.vtable.has_children(hl.data) {
		return Completions{}, .No_Children
	}
	return hl.vtable.complete_child(hl.data, path, cursor_pos, group, allocator), .None
}

// highlighter_fill_unique_ids appends the child ids (port of
// Highlighter::fill_unique_ids). Appended strings borrow group memory.
highlighter_fill_unique_ids :: proc(hl: ^Highlighter, unique_ids: ^[dynamic]string) {
	hl.vtable.fill_unique_ids(hl.data, unique_ids)
}

// Leaf defaults below (port of the C++ base-class virtuals): concrete
// leaf highlighters install these in their vtables for the
// child-management slots. The dispatch procs above translate them to
// Highlighter_Error (the C++ throws instead).

// highlighter_leaf_has_children always reports no children.
highlighter_leaf_has_children :: proc(data: rawptr) -> bool {
	return false
}

// highlighter_leaf_get_child always misses (nil).
highlighter_leaf_get_child :: proc(data: rawptr, path: string, allocator: mem.Allocator) -> ^Highlighter {
	return nil
}

// highlighter_leaf_add_child ignores the child (unreachable through
// highlighter_add_child, which rejects leaves first).
highlighter_leaf_add_child :: proc(data: rawptr, name: string, child: ^Highlighter, override: bool) {
}

// highlighter_leaf_remove_child ignores the id (unreachable through
// highlighter_remove_child, which rejects leaves first).
highlighter_leaf_remove_child :: proc(data: rawptr, id: string) {
}

// highlighter_leaf_complete_child returns no candidates (unreachable
// through highlighter_complete_child, which rejects leaves first).
highlighter_leaf_complete_child :: proc(
	data: rawptr,
	path: string,
	cursor_pos: Units_ByteCount,
	group: bool,
	allocator: mem.Allocator,
) -> Completions {
	return Completions{}
}

// highlighter_leaf_fill_unique_ids appends nothing.
highlighter_leaf_fill_unique_ids :: proc(data: rawptr, unique_ids: ^[dynamic]string) {
}

// Highlighter_Registry_Instance is the HighlighterRegistry singleton store.
Highlighter_Registry_Instance: Highlighter_Registry

// highlighter_registry_has_instance reports whether the singleton was
// initialized (port of Singleton::has_instance).
highlighter_registry_has_instance := false

// highlighter_registry_instance returns the singleton (port of
// Singleton::instance).
highlighter_registry_instance :: proc() -> ^Highlighter_Registry {
	assert(highlighter_registry_has_instance)
	return &Highlighter_Registry_Instance
}

// highlighter_registry_instance_init initializes the singleton.
highlighter_registry_instance_init :: proc(allocator := context.allocator) {
	Highlighter_Registry_Instance = highlighter_registry_make(allocator)
	highlighter_registry_has_instance = true
}

// highlighter_registry_make builds an empty registry.
highlighter_registry_make :: proc(allocator := context.allocator) -> Highlighter_Registry {
	return make(Highlighter_Registry, 8, allocator)
}

// highlighter_registry_destroy frees the registry map. Factories and
// descriptions are static/borrowed, not freed.
highlighter_registry_destroy :: proc(reg: ^Highlighter_Registry) {
	delete(reg^)
	reg^ = nil
}

// highlighter_registry_add installs a factory (takes no ownership;
// name, factory and description are borrowed/static).
highlighter_registry_add :: proc(
	reg: ^Highlighter_Registry,
	name: string,
	factory: Highlighter_Factory,
	description: ^Highlighter_Desc,
) {
	reg^[name] = Highlighter_Factory_And_Description{factory = factory, description = description}
}

// highlighter_registry_get looks a factory up by name.
highlighter_registry_get :: proc(
	reg: ^Highlighter_Registry,
	name: string,
) -> (
	entry: Highlighter_Factory_And_Description,
	err: Highlighter_Error,
) {
	if found, ok := reg^[name]; ok {
		return found, .None
	}
	return {}, .No_Such_Factory
}
