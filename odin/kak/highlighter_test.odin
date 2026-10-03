// Tests for the highlighter base framework (port of
// src/highlighter.{hh,cc}). The C++ ships no unit tests here, so these
// cover pass gating over empty/small display buffers, the leaf child
// errors, group-style dispatch through a fake vtable, the factory
// registry, and allocator cleanup.
package kak

import "core:mem"
import "core:strings"
import "core:testing"

// Highlighter_Test_Leaf records dispatch calls (a fake concrete leaf
// highlighter; per-test state, never shared between tests).
Highlighter_Test_Leaf :: struct {
	highlight_calls: int,
	setup_calls:     int,
	seen_lines:      int,
	seen_range:      Buffer_Range,
}

highlighter_test_leaf_do_highlight :: proc(
	data: rawptr,
	hctx: Highlight_Context,
	display_buffer: ^Display_Buffer,
	buffer_range: Buffer_Range,
) {
	leaf := cast(^Highlighter_Test_Leaf)data
	leaf.highlight_calls += 1
	leaf.seen_lines = len(display_buffer.lines)
	leaf.seen_range = buffer_range
}

highlighter_test_leaf_do_compute_display_setup :: proc(
	data: rawptr,
	hctx: Highlight_Context,
	setup: ^Display_Setup,
) {
	leaf := cast(^Highlighter_Test_Leaf)data
	leaf.setup_calls += 1
	setup.line_count += 1
}

highlighter_test_leaf_destroy :: proc(data: rawptr, allocator: mem.Allocator) {
	free(cast(^Highlighter_Test_Leaf)data, allocator)
}

// highlighter_test_leaf_vtable wires recording dispatch to the leaf
// child defaults. Read-only after load; safe for threaded tests.
highlighter_test_leaf_vtable := Highlighter_VTable{
	do_highlight             = highlighter_test_leaf_do_highlight,
	do_compute_display_setup = highlighter_test_leaf_do_compute_display_setup,
	has_children             = highlighter_leaf_has_children,
	get_child                = highlighter_leaf_get_child,
	add_child                = highlighter_leaf_add_child,
	remove_child             = highlighter_leaf_remove_child,
	complete_child           = highlighter_leaf_complete_child,
	fill_unique_ids          = highlighter_leaf_fill_unique_ids,
	destroy                  = highlighter_test_leaf_destroy,
}

// highlighter_test_make_leaf builds an owned recording leaf for passes.
highlighter_test_make_leaf :: proc(
	passes: Highlight_Pass,
	allocator := context.allocator,
) -> (
	hl: ^Highlighter,
	leaf: ^Highlighter_Test_Leaf,
) {
	data := new(Highlighter_Test_Leaf, allocator)
	return highlighter_make_owned(passes, &highlighter_test_leaf_vtable, data, allocator), data
}

// highlighter_test_hctx builds a Highlight_Context for pass (nil client
// context; dispatch never touches it).
highlighter_test_hctx :: proc(setup: ^Display_Setup, pass: Highlight_Pass) -> Highlight_Context {
	return Highlight_Context{ctx = nil, setup = setup, pass = pass, disabled_ids = nil}
}

@(test)
highlighter_test_pass_all_covers_every_pass :: proc(t: ^testing.T) {
	for pass in Highlight_Pass_Flag {
		testing.expect(t, pass in highlighter_pass_all, "All covers every pass")
	}
	testing.expect(t, highlighter_pass_all & {.Replace} != Highlight_Pass{})
	testing.expect(t, Highlight_Pass{} & highlighter_pass_all == Highlight_Pass{})
}

@(test)
highlighter_test_passes_accessor :: proc(t: ^testing.T) {
	for pass in Highlight_Pass_Flag {
		hl, _ := highlighter_test_make_leaf({pass})
		defer highlighter_destroy(hl)
		testing.expect(t, highlighter_passes(hl) == {pass})
	}
	hl, _ := highlighter_test_make_leaf(highlighter_pass_all)
	defer highlighter_destroy(hl)
	testing.expect(t, highlighter_passes(hl) == highlighter_pass_all)
	empty, _ := highlighter_test_make_leaf({})
	defer highlighter_destroy(empty)
	testing.expect(t, highlighter_passes(empty) == Highlight_Pass{})
}

@(test)
highlighter_test_highlight_gating_empty_buffer :: proc(t: ^testing.T) {
	hl, leaf := highlighter_test_make_leaf({.Colorize})
	defer highlighter_destroy(hl)
	buf := display_buffer_make()
	defer display_buffer_destroy(&buf)
	setup := Display_Setup{}
	rng := Buffer_Range{{0, 0}, {0, 0}}

	// Empty buffer, matching pass: dispatches once, sees zero lines.
	highlighter_highlight(hl, highlighter_test_hctx(&setup, {.Colorize}), &buf, rng)
	testing.expect_value(t, leaf.highlight_calls, 1)
	testing.expect_value(t, leaf.seen_lines, 0)
	testing.expect(t, leaf.seen_range == rng)

	// Disjoint pass: no dispatch.
	highlighter_highlight(hl, highlighter_test_hctx(&setup, {.Move}), &buf, rng)
	highlighter_highlight(hl, highlighter_test_hctx(&setup, {.Replace, .Wrap, .Move}), &buf, rng)
	highlighter_highlight(hl, highlighter_test_hctx(&setup, {}), &buf, rng)
	testing.expect_value(t, leaf.highlight_calls, 1)

	// Overlapping multi-pass context: dispatches.
	highlighter_highlight(hl, highlighter_test_hctx(&setup, {.Move, .Colorize}), &buf, rng)
	testing.expect_value(t, leaf.highlight_calls, 2)
}

@(test)
highlighter_test_highlight_small_buffer :: proc(t: ^testing.T) {
	hl, leaf := highlighter_test_make_leaf(highlighter_pass_all)
	defer highlighter_destroy(hl)
	buf := display_buffer_make()
	defer display_buffer_destroy(&buf)
	append(&buf.lines, display_buffer_line_make_text("hello", Face{}))
	append(&buf.lines, display_buffer_line_make_text("world", Face{}))
	setup := Display_Setup{}
	rng := Buffer_Range{{0, 0}, {1, 5}}

	highlighter_highlight(hl, highlighter_test_hctx(&setup, highlighter_pass_all), &buf, rng)
	testing.expect_value(t, leaf.highlight_calls, 1)
	testing.expect_value(t, leaf.seen_lines, 2)
	testing.expect(t, leaf.seen_range == rng)

	// A highlighter with no passes never dispatches, even on All.
	nop, nop_leaf := highlighter_test_make_leaf({})
	defer highlighter_destroy(nop)
	highlighter_highlight(nop, highlighter_test_hctx(&setup, highlighter_pass_all), &buf, rng)
	testing.expect_value(t, nop_leaf.highlight_calls, 0)
}

@(test)
highlighter_test_compute_display_setup_gating :: proc(t: ^testing.T) {
	hl, leaf := highlighter_test_make_leaf({.Wrap})
	defer highlighter_destroy(hl)
	setup := Display_Setup{}

	highlighter_compute_display_setup(hl, highlighter_test_hctx(&setup, {.Move}), &setup)
	testing.expect_value(t, leaf.setup_calls, 0)
	testing.expect_value(t, setup.line_count, Units_LineCount(0))

	highlighter_compute_display_setup(hl, highlighter_test_hctx(&setup, {.Wrap}), &setup)
	highlighter_compute_display_setup(hl, highlighter_test_hctx(&setup, highlighter_pass_all), &setup)
	testing.expect_value(t, leaf.setup_calls, 2)
	testing.expect_value(t, setup.line_count, Units_LineCount(2))
}

@(test)
highlighter_test_leaf_children_errors :: proc(t: ^testing.T) {
	hl, _ := highlighter_test_make_leaf({.Colorize})
	defer highlighter_destroy(hl)
	testing.expect(t, !highlighter_has_children(hl))

	child, err := highlighter_get_child(hl, "anything")
	testing.expect_value(t, err, Highlighter_Error.No_Children)
	testing.expect(t, child == nil)

	// Rejected add keeps caller ownership: destroy the child here.
	orphan, _ := highlighter_test_make_leaf({.Move})
	testing.expect_value(t, highlighter_add_child(hl, "id", orphan), Highlighter_Error.No_Children)
	highlighter_destroy(orphan)

	testing.expect_value(t, highlighter_remove_child(hl, "id"), Highlighter_Error.No_Children)

	completions, cerr := highlighter_complete_child(hl, "id", Units_ByteCount(2), true)
	testing.expect_value(t, cerr, Highlighter_Error.No_Children)
	testing.expect_value(t, len(completions.candidates), 0)

	ids := make([dynamic]string)
	defer delete(ids)
	append(&ids, "kept")
	highlighter_fill_unique_ids(hl, &ids)
	testing.expect_value(t, len(ids), 1)
	testing.expect_value(t, ids[0], "kept")
}

// Highlighter_Test_Group is a fake container highlighter exercising the
// group side of the dispatch procs (per-test state).
Highlighter_Test_Group :: struct {
	children:        map[string]^Highlighter,
	highlight_calls: int,
	allocator:       mem.Allocator,
}

highlighter_test_group_do_highlight :: proc(
	data: rawptr,
	hctx: Highlight_Context,
	display_buffer: ^Display_Buffer,
	buffer_range: Buffer_Range,
) {
	g := cast(^Highlighter_Test_Group)data
	g.highlight_calls += 1
}

highlighter_test_group_do_compute_display_setup :: proc(
	data: rawptr,
	hctx: Highlight_Context,
	setup: ^Display_Setup,
) {
	setup.widget_columns += 1
}

highlighter_test_group_has_children :: proc(data: rawptr) -> bool {
	return true
}

highlighter_test_group_get_child :: proc(
	data: rawptr,
	path: string,
	allocator: mem.Allocator,
) -> ^Highlighter {
	g := cast(^Highlighter_Test_Group)data
	if found, ok := g.children[path]; ok {
		return found
	}
	return nil
}

highlighter_test_group_add_child :: proc(data: rawptr, name: string, child: ^Highlighter, override: bool) {
	g := cast(^Highlighter_Test_Group)data
	if !override {
		assert(g.children[name] == nil)
	}
	g.children[name] = child
}

highlighter_test_group_remove_child :: proc(data: rawptr, id: string) {
	g := cast(^Highlighter_Test_Group)data
	delete_key(&g.children, id)
}

highlighter_test_group_complete_child :: proc(
	data: rawptr,
	path: string,
	cursor_pos: Units_ByteCount,
	group: bool,
	allocator: mem.Allocator,
) -> Completions {
	g := cast(^Highlighter_Test_Group)data
	res := Completions{start = 0, end = Units_ByteCount(len(path))}
	res.candidates = make(Candidate_List, 0, len(g.children), allocator)
	for name in g.children {
		if strings.has_prefix(name, path) {
			append(&res.candidates, name)
		}
	}
	return res
}

highlighter_test_group_fill_unique_ids :: proc(data: rawptr, unique_ids: ^[dynamic]string) {
	g := cast(^Highlighter_Test_Group)data
	for name in g.children {
		append(unique_ids, name)
	}
}

highlighter_test_group_destroy :: proc(data: rawptr, allocator: mem.Allocator) {
	g := cast(^Highlighter_Test_Group)data
	delete(g.children)
	free(g, allocator)
}

// highlighter_test_group_vtable is read-only after load; safe for
// threaded tests.
highlighter_test_group_vtable := Highlighter_VTable{
	do_highlight             = highlighter_test_group_do_highlight,
	do_compute_display_setup = highlighter_test_group_do_compute_display_setup,
	has_children             = highlighter_test_group_has_children,
	get_child                = highlighter_test_group_get_child,
	add_child                = highlighter_test_group_add_child,
	remove_child             = highlighter_test_group_remove_child,
	complete_child           = highlighter_test_group_complete_child,
	fill_unique_ids          = highlighter_test_group_fill_unique_ids,
	destroy                  = highlighter_test_group_destroy,
}

@(test)
highlighter_test_group_add_remove_get :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)

	gdata := new(Highlighter_Test_Group, alloc)
	gdata.children = make(map[string]^Highlighter, 4, alloc)
	gdata.allocator = alloc
	group := highlighter_make_owned(highlighter_pass_all, &highlighter_test_group_vtable, gdata, alloc)
	testing.expect(t, highlighter_has_children(group))

	a, _ := highlighter_test_make_leaf({.Colorize}, alloc)
	b, _ := highlighter_test_make_leaf({.Move}, alloc)
	testing.expect_value(t, highlighter_add_child(group, "alpha", a), Highlighter_Error.None)
	testing.expect_value(t, highlighter_add_child(group, "beta", b), Highlighter_Error.None)

	found, err := highlighter_get_child(group, "alpha", alloc)
	testing.expect_value(t, err, Highlighter_Error.None)
	testing.expect(t, found == a)

	missing, merr := highlighter_get_child(group, "gamma", alloc)
	testing.expect_value(t, merr, Highlighter_Error.No_Such_Child)
	testing.expect(t, missing == nil)

	ids := make([dynamic]string, alloc)
	highlighter_fill_unique_ids(group, &ids)
	testing.expect_value(t, len(ids), 2)
	delete(ids)

	completions, cerr := highlighter_complete_child(group, "alp", Units_ByteCount(3), true, alloc)
	testing.expect_value(t, cerr, Highlighter_Error.None)
	testing.expect_value(t, len(completions.candidates), 1)
	testing.expect_value(t, completions.candidates[0], "alpha")
	delete(completions.candidates)

	testing.expect_value(t, highlighter_remove_child(group, "alpha"), Highlighter_Error.None)
	gone, gerr := highlighter_get_child(group, "alpha", alloc)
	testing.expect_value(t, gerr, Highlighter_Error.No_Such_Child)
	testing.expect(t, gone == nil)

	// Group holds borrowed refs only in this fake; free explicitly.
	highlighter_destroy(a, alloc)
	highlighter_destroy(b, alloc)
	highlighter_destroy(group, alloc)
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
highlighter_test_group_highlight_dispatch :: proc(t: ^testing.T) {
	gdata := new(Highlighter_Test_Group)
	gdata.children = make(map[string]^Highlighter)
	gdata.allocator = context.allocator
	group := highlighter_make_owned({.Replace}, &highlighter_test_group_vtable, gdata)
	defer highlighter_destroy(group)
	buf := display_buffer_make()
	defer display_buffer_destroy(&buf)
	setup := Display_Setup{}
	rng := Buffer_Range{{0, 0}, {0, 0}}

	highlighter_highlight(
		group,
		highlighter_test_hctx(&setup, {.Replace}),
		&buf,
		rng,
	)
	testing.expect_value(t, gdata.highlight_calls, 1)
	highlighter_compute_display_setup(group, highlighter_test_hctx(&setup, {.Replace}), &setup)
	testing.expect_value(t, setup.widget_columns, Units_ColumnCount(1))
}

// highlighter_test_factory builds a recording leaf (borrowed by the
// registry test; no shared mutable state).
highlighter_test_factory :: proc(
	params: Highlighter_Params,
	parent: ^Highlighter,
	allocator: mem.Allocator,
) -> ^Highlighter {
	data := new(Highlighter_Test_Leaf, allocator)
	return highlighter_make_owned(highlighter_pass_all, &highlighter_test_leaf_vtable, data, allocator)
}

@(test)
highlighter_test_registry_add_get :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)

	reg := highlighter_registry_make(alloc)
	desc := Highlighter_Desc{docstring = "test highlighter"}
	highlighter_registry_add(&reg, "test", highlighter_test_factory, &desc)

	entry, err := highlighter_registry_get(&reg, "test")
	testing.expect_value(t, err, Highlighter_Error.None)
	testing.expect(t, entry.factory == highlighter_test_factory)
	testing.expect(t, entry.description == &desc)

	// Factories build working highlighters.
	built := entry.factory(nil, nil, alloc)
	testing.expect(t, highlighter_passes(built) == highlighter_pass_all)
	highlighter_destroy(built, alloc)

	_, merr := highlighter_registry_get(&reg, "missing")
	testing.expect_value(t, merr, Highlighter_Error.No_Such_Factory)

	highlighter_registry_destroy(&reg)
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
highlighter_test_owned_lifecycle_cleanup :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)

	hl, leaf := highlighter_test_make_leaf({.Wrap, .Move}, alloc)
	testing.expect_value(t, leaf.highlight_calls, 0)
	highlighter_destroy(hl, alloc)
	testing.expect_value(t, len(track.allocation_map), 0)
}
