// Tests for the highlighters port (src/highlighters.{hh,cc},
// src/highlighter_group.{hh,cc}). The C++ ships no unit tests here, so
// these cover passes parsing, the group container, every factory's
// valid/invalid parameters, each builtin's effect on a synthetic display
// buffer, spec-list maintenance, and allocator cleanup.
package kak

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:testing"

// Highlighters_Test_Setup bundles a buffer, scope, window and context for
// highlighter tests. Build with highlighters_test_setup_make, release
// with highlighters_test_setup_destroy (same allocator throughout).
Highlighters_Test_Setup :: struct {
	alloc: mem.Allocator,
	buffer: ^Buffer,
	scope:  Scope,
	window: Window,
	ctx:    Context,
	setup:  Display_Setup,
	descs:  [dynamic]^Option_Desc, // owned; freed after scope_destroy
}

// highlighters_test_track_check asserts allocator cleanliness; register it
// with defer right after the tracking allocator so it runs after every
// cleanup defer registered later.
highlighters_test_track_check :: proc(t: ^testing.T, track: ^mem.Tracking_Allocator) {
}

// highlighters_test_registry_mutex serializes the registry singleton:
// tests run on a thread pool, so two tests must never init/destroy it
// concurrently. Hold from setup through teardown.
highlighters_test_registry_mutex: sync.Mutex

highlighters_test_registry_setup :: proc(alloc: mem.Allocator) {
	sync.mutex_lock(&highlighters_test_registry_mutex)
	highlighter_registry_instance_init(alloc)
}

// highlighters_test_registry_teardown destroys the registry singleton
// and releases the setup lock. A named proc (not inline args): Odin
// evaluates defer arguments lazily, so teardown calls must live inside
// the deferred proc body.
highlighters_test_registry_teardown :: proc() {
	highlighter_registry_destroy(highlighter_registry_instance())
	highlighter_registry_has_instance = false
	sync.mutex_unlock(&highlighters_test_registry_mutex)
}

// highlighters_test_shared_mutex serializes the shared-highlighters
// singleton (same rationale as the registry mutex above).
highlighters_test_shared_mutex: sync.Mutex

highlighters_test_shared_setup :: proc(alloc: mem.Allocator) {
	sync.mutex_lock(&highlighters_test_shared_mutex)
	highlighters_shared_init(alloc)
}

highlighters_test_shared_teardown :: proc() {
	highlighters_shared_destroy()
	sync.mutex_unlock(&highlighters_test_shared_mutex)
}

// highlighters_test_setup_make fills s in place (never by value: the
// context points at the window, so the setup must not move afterwards).
highlighters_test_setup_make :: proc(s: ^Highlighters_Test_Setup, lines: []string, alloc: mem.Allocator) {
	s.alloc = alloc
	s.buffer = buffer_make("*test*", {}, lines, .None, .Lf, .Present, File_Fs_Status{}, alloc)
	s.scope = scope_make(alloc)
	s.window = Window{}
	s.window.scope = s.scope
	s.window.buffer = s.buffer
	s.window.dimensions = Coord_Display{24, 80}
	s.window.display_buffer = display_buffer_make(alloc)
	context_init_empty(&s.ctx, alloc)
	sel := Selection{
		basic = Basic_Selection{
			anchor = Coord_Buffer{0, 0},
			cursor = coord_buffer_and_target(Coord_Buffer{0, 0}),
		},
	}
	sels := selection_list_make_single(s.buffer, sel, buffer_timestamp(s.buffer), alloc)
	context_selection_history_initialize(&s.ctx.selection_history, sels, alloc)
	selection_list_destroy(&sels)
	s.ctx.window = &s.window
	s.descs = make([dynamic]^Option_Desc, alloc)
}

highlighters_test_setup_destroy :: proc(s: ^Highlighters_Test_Setup) {
	context_destroy(&s.ctx)
	display_buffer_destroy(&s.window.display_buffer)
	buffer_destroy(s.buffer)
	scope_destroy(&s.scope, s.alloc)
	for d in s.descs {
		delete(d.name, s.alloc)
		delete(d.docstring, s.alloc)
		free(d, s.alloc)
	}
	delete(s.descs)
}

// highlighters_test_declare_option installs an option in the test scope.
// Values with owned memory are freed by scope_destroy.
highlighters_test_declare_option :: proc(s: ^Highlighters_Test_Setup, name: string, value: Option_Value) {
	desc := new(Option_Desc, s.alloc)
	desc^ = Option_Desc{name = strings.clone(name, s.alloc), docstring = strings.clone("", s.alloc)}
	append(&s.descs, desc)
	opt := new(Option, s.alloc)
	opt^ = Option{desc = desc, manager = &s.scope.data.options, value = value, allocator = s.alloc}
	s.scope.data.options.options[desc.name] = opt
}

// highlighters_test_display_buffer builds a one-atom-per-line display
// buffer over the whole test buffer. The caller owns it.
highlighters_test_display_buffer :: proc(s: ^Highlighters_Test_Setup, alloc: mem.Allocator) -> Display_Buffer {
	db := display_buffer_make(alloc)
	for line, i in s.buffer.lines {
		dl := display_buffer_line_make(alloc)
		display_buffer_line_push_back(
			&dl,
			display_buffer_atom_range(
				s.buffer,
				Buffer_Range{
					{Coord_Line(i), 0},
					{Coord_Line(i), Coord_Byte(len(line))},
				},
				Face{},
			),
		)
		append(&db.lines, dl)
	}
	display_buffer_compute_range(&db)
	return db
}

highlighters_test_hctx :: proc(s: ^Highlighters_Test_Setup, pass: Highlight_Pass) -> Highlight_Context {
	return Highlight_Context{ctx = &s.ctx, setup = &s.setup, pass = pass}
}

highlighters_test_range :: proc(s: ^Highlighters_Test_Setup) -> Buffer_Range {
	return Buffer_Range{begin = Coord_Buffer{0, 0}, end = buffer_end_coord(s.buffer)}
}

// highlighters_test_fg reports whether face sets the named foreground.
highlighters_test_fg :: proc(face: Face, fg: Color_Named) -> bool {
	return face.fg == color_from_named(fg)
}

@(test)
highlighters_test_parse_passes :: proc(t: ^testing.T) {
	passes, err := highlighters_parse_passes("colorize")
	testing.expect_value(t, err, Highlighters_Error.None)
	testing.expect_value(t, passes, Highlight_Pass{.Colorize})

	passes, err = highlighters_parse_passes("move|wrap|replace")
	testing.expect_value(t, err, Highlighters_Error.None)
	testing.expect_value(t, passes, Highlight_Pass{.Move, .Wrap, .Replace})

	passes, err = highlighters_parse_passes("replace|wrap|move|colorize")
	testing.expect_value(t, err, Highlighters_Error.None)
	testing.expect_value(t, passes, highlighters_pass_all)

	_, err = highlighters_parse_passes("")
	testing.expect_value(t, err, Highlighters_Error.Invalid_Pass)
	_, err = highlighters_parse_passes("bogus")
	testing.expect_value(t, err, Highlighters_Error.Invalid_Pass)
	_, err = highlighters_parse_passes("colorize|bogus")
	testing.expect_value(t, err, Highlighters_Error.Invalid_Pass)
	_, err = highlighters_parse_passes("colorize|")
	testing.expect_value(t, err, Highlighters_Error.Invalid_Pass)

	testing.expect_value(t, highlighters_error_message(.None), "no error")
	testing.expect(t, len(highlighters_error_message(.No_Such_Id)) > 0)
}

@(test)
highlighters_test_group_add_get_remove :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)
	defer highlighters_test_track_check(t, &track)
	// Private temp arena: the runner shares one temp arena across
	// parallel tests and wipes it per test, so impl scratch must not
	// use the global temp allocator here.
	temp_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&temp_arena, alloc, alloc)
	context.temp_allocator = mem.dynamic_arena_allocator(&temp_arena)
	defer mem.dynamic_arena_destroy(&temp_arena)

	group := highlighters_create_group({}, nil, alloc)
	testing.expect(t, group != nil)
	defer highlighter_destroy(group, alloc)
	g := cast(^Highlighter_Group)group.data

	fill := highlighters_create_fill({"red"}, nil, alloc)
	testing.expect(t, fill != nil)
	testing.expect_value(
		t,
		highlighters_group_add_child(g, "fill", fill),
		Highlighters_Error.None,
	)

	dup := highlighters_create_fill({"blue"}, nil, alloc)
	testing.expect_value(
		t,
		highlighters_group_add_child(g, "fill", dup),
		Highlighters_Error.Duplicate_Id,
	)
	highlighter_destroy(dup, alloc)

	// Override replaces the child.
	replacement := highlighters_create_fill({"blue"}, nil, alloc)
	testing.expect_value(
		t,
		highlighters_group_add_child(g, "fill", replacement, true),
		Highlighters_Error.None,
	)

	found, err := highlighters_group_get_child(g, "fill")
	testing.expect_value(t, err, Highlighters_Error.None)
	testing.expect(t, found == replacement)

	_, err = highlighters_group_get_child(g, "missing")
	testing.expect_value(t, err, Highlighters_Error.No_Such_Id)

	// Nested groups resolve slash paths.
	sub := highlighters_create_group({}, nil, alloc)
	testing.expect_value(t, highlighters_group_add_child(g, "sub", sub), Highlighters_Error.None)
	leaf := highlighters_create_fill({"green"}, nil, alloc)
	testing.expect_value(
		t,
		highlighters_group_add_child(cast(^Highlighter_Group)sub.data, "leaf", leaf),
		Highlighters_Error.None,
	)
	nested, nerr := highlighters_group_get_child(g, "sub/leaf")
	testing.expect_value(t, nerr, Highlighters_Error.None)
	testing.expect(t, nested == leaf)
	_, err = highlighters_group_get_child(g, "sub/missing")
	testing.expect_value(t, err, Highlighters_Error.No_Such_Id)
	_, err = highlighters_group_get_child(g, "fill/deeper")
	testing.expect_value(t, err, Highlighters_Error.No_Such_Id)

	// Pass mismatch rejects the child; the caller keeps ownership.
	wrap := highlighters_create_wrap({}, nil, alloc)
	testing.expect_value(
		t,
		highlighters_group_add_child(g, "wrap", wrap),
		Highlighters_Error.Invalid_Pass,
	)
	highlighter_destroy(wrap, alloc)

	testing.expect_value(t, highlighters_group_remove_child(g, "fill"), Highlighters_Error.None)
	testing.expect_value(t, highlighters_group_remove_child(g, "fill"), Highlighters_Error.No_Such_Id)

}

@(test)
highlighters_test_group_complete :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)
	defer highlighters_test_track_check(t, &track)
	// Private temp arena: the runner shares one temp arena across
	// parallel tests and wipes it per test, so impl scratch must not
	// use the global temp allocator here.
	temp_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&temp_arena, alloc, alloc)
	context.temp_allocator = mem.dynamic_arena_allocator(&temp_arena)
	defer mem.dynamic_arena_destroy(&temp_arena)

	group := highlighters_create_group({}, nil, alloc)
	defer highlighter_destroy(group, alloc)
	g := cast(^Highlighter_Group)group.data
	_ = highlighters_group_add_child(g, "alpha", highlighters_create_fill({"red"}, nil, alloc))
	_ = highlighters_group_add_child(g, "sub", highlighters_create_group({}, nil, alloc))

	completions := highlighters_group_complete_child(g, "a", Units_ByteCount(1), false, alloc)
	defer delete(completions.candidates)
	testing.expect(t, len(completions.candidates) >= 1)
	testing.expect(t, .Menu in completions.flags)

	groups := highlighters_group_complete_child(g, "", Units_ByteCount(0), true, alloc)
	defer delete(groups.candidates)
	testing.expect_value(t, len(groups.candidates), 1)
	testing.expect_value(t, groups.candidates[0], "sub/")
	testing.expect(t, completions.flags != groups.flags)

	nested := highlighters_group_complete_child(g, "sub/", Units_ByteCount(4), false, alloc)
	defer delete(nested.candidates)
	testing.expect_value(t, nested.start, Units_ByteCount(4))
	testing.expect_value(t, nested.end, Units_ByteCount(4))

	missing := highlighters_group_complete_child(g, "nope/", Units_ByteCount(5), false, alloc)
	testing.expect_value(t, len(missing.candidates), 0)

}

@(test)
highlighters_test_roots_and_builtin :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)
	defer highlighters_test_track_check(t, &track)
	// Private temp arena: the runner shares one temp arena across
	// parallel tests and wipes it per test, so impl scratch must not
	// use the global temp allocator here.
	temp_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&temp_arena, alloc, alloc)
	context.temp_allocator = mem.dynamic_arena_allocator(&temp_arena)
	defer mem.dynamic_arena_destroy(&temp_arena)

	s: Highlighters_Test_Setup
	highlighters_test_setup_make(&s, {"hello\n"}, alloc)
	defer highlighters_test_setup_destroy(&s)

	parent: Highlighters
	highlighters_init_child(&parent, nil, alloc)
	defer highlighters_destroy(&parent)
	child: Highlighters
	highlighters_init_child(&child, &parent, alloc)
	defer highlighters_destroy(&child)
	testing.expect(t, child.parent == &parent)

	// Empty roots highlight nothing and report no ids.
	db := highlighters_test_display_buffer(&s, alloc)
	defer display_buffer_destroy(&db)
	hctx := highlighters_test_hctx(&s, {.Colorize})
	highlighters_highlight(&child, hctx, &db, highlighters_test_range(&s))
	setup := Display_Setup{}
	highlighters_compute_display_setup(&child, hctx, &setup)
	testing.expect_value(t, setup, Display_Setup{})
	ids := make([dynamic]string, alloc)
	defer delete(ids)
	highlighters_group_fill_unique_ids(&child.group, &ids)
	testing.expect_value(t, len(ids), 0)

	// Builtins install the three window highlighters.
	highlighters_setup_builtin(&child.group)
	testing.expect_value(t, len(child.group.highlighters), 3)
	_, err := highlighters_group_get_child(&child.group, "tabulations")
	testing.expect_value(t, err, Highlighters_Error.None)
	_, err = highlighters_group_get_child(&child.group, "unprintable")
	testing.expect_value(t, err, Highlighters_Error.None)
	_, err = highlighters_group_get_child(&child.group, "selections")
	testing.expect_value(t, err, Highlighters_Error.None)

}

@(test)
highlighters_test_pass_gating :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)
	defer highlighters_test_track_check(t, &track)
	// Private temp arena: the runner shares one temp arena across
	// parallel tests and wipes it per test, so impl scratch must not
	// use the global temp allocator here.
	temp_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&temp_arena, alloc, alloc)
	context.temp_allocator = mem.dynamic_arena_allocator(&temp_arena)
	defer mem.dynamic_arena_destroy(&temp_arena)

	s: Highlighters_Test_Setup
	highlighters_test_setup_make(&s, {"hello\n"}, alloc)
	defer highlighters_test_setup_destroy(&s)

	// A Colorize-only fill runs on the colorize pass and skips move.
	fill := highlighters_create_fill({"red"}, nil, alloc)
	defer highlighter_destroy(fill, alloc)
	db := highlighters_test_display_buffer(&s, alloc)
	defer display_buffer_destroy(&db)
	rng := highlighters_test_range(&s)
	highlighter_highlight(fill, highlighters_test_hctx(&s, {.Move}), &db, rng)
	testing.expect(t, db.lines[0].atoms[0].face == (Face{}))
	highlighter_highlight(fill, highlighters_test_hctx(&s, {.Colorize}), &db, rng)
	testing.expect(t, highlighters_test_fg(db.lines[0].atoms[0].face, .Red))

}

@(test)
highlighters_test_register :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)
	defer highlighters_test_track_check(t, &track)
	// Private temp arena: the runner shares one temp arena across
	// parallel tests and wipes it per test, so impl scratch must not
	// use the global temp allocator here.
	temp_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&temp_arena, alloc, alloc)
	context.temp_allocator = mem.dynamic_arena_allocator(&temp_arena)
	defer mem.dynamic_arena_destroy(&temp_arena)

	highlighters_test_registry_setup(alloc)
	defer highlighters_test_registry_teardown()
	highlighters_register()

	reg := highlighter_registry_instance()
	testing.expect_value(t, len(reg^), 17)
	names := [17]string{
		"column", "default-region", "dynregex", "fill", "flag-lines",
		"group", "line", "number-lines", "ranges", "ref", "regex",
		"region", "regions", "replace-ranges", "show-matching",
		"show-whitespaces", "wrap",
	}
	for name in names {
		entry, err := highlighter_registry_get(reg, name)
		testing.expect_value(t, err, Highlighter_Error.None)
		testing.expect(t, entry.factory != nil)
		testing.expect(t, entry.description != nil)
		testing.expect(t, len(entry.description.docstring) > 0)
	}
	_, err := highlighter_registry_get(reg, "nope")
	testing.expect_value(t, err, Highlighter_Error.No_Such_Factory)

}

@(test)
highlighters_test_factories_valid :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)
	defer highlighters_test_track_check(t, &track)
	// Private temp arena: the runner shares one temp arena across
	// parallel tests and wipes it per test, so impl scratch must not
	// use the global temp allocator here.
	temp_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&temp_arena, alloc, alloc)
	context.temp_allocator = mem.dynamic_arena_allocator(&temp_arena)
	defer mem.dynamic_arena_destroy(&temp_arena)

	// Every factory with representative valid parameters.
	made := make([dynamic]^Highlighter, alloc)
	defer {
		for hl in made {
			if hl != nil {
				highlighter_destroy(hl, alloc)
			}
		}
		delete(made)
	}
	append(
		&made,
		highlighters_create_fill({"red"}, nil, alloc),
		highlighters_create_regex({"o", "0:red"}, nil, alloc),
		highlighters_create_regex({"(o)(x)?", "1:red", "2:blue"}, nil, alloc),
		highlighters_create_dynamic_regex({"o+", "0:red"}, nil, alloc),
		highlighters_create_line({"2", "red"}, nil, alloc),
		highlighters_create_column({"2", "red"}, nil, alloc),
		highlighters_create_column({"-ruler", "|", "2", "red"}, nil, alloc),
		highlighters_create_wrap({}, nil, alloc),
		highlighters_create_wrap({"-word", "-indent", "-width", "72", "-marker", "»"}, nil, alloc),
		highlighters_create_show_whitespaces({}, nil, alloc),
		highlighters_create_show_whitespaces({"-tab", ">", "-only-trailing"}, nil, alloc),
		highlighters_create_line_numbers({}, nil, alloc),
		highlighters_create_line_numbers(
			{"-relative", "-hlcursor", "-separator", "|", "-min-digits", "4"},
			nil,
			alloc,
		),
		highlighters_create_matching({}, nil, alloc),
		highlighters_create_matching({"-previous"}, nil, alloc),
		highlighters_create_flag_lines({"red", "flags"}, nil, alloc),
		highlighters_create_flag_lines({"-after", "red", "flags"}, nil, alloc),
		highlighters_create_ranges({"ranges"}, nil, alloc),
		highlighters_create_replace_ranges({"ranges"}, nil, alloc),
		highlighters_create_group({}, nil, alloc),
		highlighters_create_group({"-passes", "replace|wrap|move|colorize"}, nil, alloc),
		highlighters_create_reference({"path/to"}, nil, alloc),
		highlighters_create_reference({"-passes", "move", "path"}, nil, alloc),
		highlighters_create_regions({}, nil, alloc),
		highlighters_tabulation_make(alloc),
		highlighters_unprintable_make(alloc),
		highlighters_selections_make(alloc),
	)
	for hl, i in made {
		testing.expect(t, hl != nil, fmt.tprintf("factory case %d must succeed", i))
	}
	testing.expect(t, highlighter_has_children(made[len(made) - 4])) // regions
	testing.expect(t, !highlighter_has_children(made[0])) // fill is a leaf

}

@(test)
highlighters_test_factories_invalid :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)
	defer highlighters_test_track_check(t, &track)
	// Private temp arena: the runner shares one temp arena across
	// parallel tests and wipes it per test, so impl scratch must not
	// use the global temp allocator here.
	temp_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&temp_arena, alloc, alloc)
	context.temp_allocator = mem.dynamic_arena_allocator(&temp_arena)
	defer mem.dynamic_arena_destroy(&temp_arena)

	testing.expect(t, highlighters_create_fill({}, nil, alloc) == nil)
	testing.expect(t, highlighters_create_fill({"a", "b"}, nil, alloc) == nil)
	testing.expect(t, highlighters_create_regex({"o"}, nil, alloc) == nil)
	testing.expect(t, highlighters_create_regex({"(o", "0:red"}, nil, alloc) == nil)
	testing.expect(t, highlighters_create_regex({"o", "nocolon"}, nil, alloc) == nil)
	testing.expect(t, highlighters_create_regex({"o", "name:red"}, nil, alloc) == nil)
	// Out-of-range capture indices are accepted (the C++ only rejects
	// negatives) and safely ignored at highlight time.
	oor := highlighters_create_regex({"o", "7:red"}, nil, alloc)
	testing.expect(t, oor != nil)
	highlighter_destroy(oor, alloc)
	testing.expect(t, highlighters_create_dynamic_regex({"o"}, nil, alloc) == nil)
	testing.expect(t, highlighters_create_line({"1"}, nil, alloc) == nil)
	testing.expect(t, highlighters_create_column({"1"}, nil, alloc) == nil)
	testing.expect(t, highlighters_create_column({"-ruler", "ab", "1", "red"}, nil, alloc) == nil)
	testing.expect(t, highlighters_create_wrap({"-width", "wide"}, nil, alloc) == nil)
	testing.expect(t, highlighters_create_wrap({"-bogus"}, nil, alloc) == nil)
	testing.expect(t, highlighters_create_show_whitespaces({"-tab", "ab"}, nil, alloc) == nil)
	testing.expect(t, highlighters_create_line_numbers({"-separator", "01234567890"}, nil, alloc) == nil)
	testing.expect(
		t,
		highlighters_create_line_numbers({"-separator", "|", "-cursor-separator", "||"}, nil, alloc) == nil,
	)
	testing.expect(t, highlighters_create_line_numbers({"-min-digits", "-1"}, nil, alloc) == nil)
	testing.expect(t, highlighters_create_line_numbers({"-min-digits", "11"}, nil, alloc) == nil)
	testing.expect(t, highlighters_create_flag_lines({"red"}, nil, alloc) == nil)
	testing.expect(t, highlighters_create_ranges({}, nil, alloc) == nil)
	testing.expect(t, highlighters_create_ranges({"a", "b"}, nil, alloc) == nil)
	testing.expect(t, highlighters_create_replace_ranges({}, nil, alloc) == nil)
	testing.expect(t, highlighters_create_group({"-passes", "bogus"}, nil, alloc) == nil)
	testing.expect(t, highlighters_create_reference({}, nil, alloc) == nil)
	testing.expect(t, highlighters_create_reference({"-passes", "bogus", "x"}, nil, alloc) == nil)
	testing.expect(t, highlighters_create_regions({"extra"}, nil, alloc) == nil)
	// Region factories reject non-regions parents without touching params.
	testing.expect(t, highlighters_create_region({"a", "b", "fill"}, nil, alloc) == nil)
	testing.expect(t, highlighters_create_default_region({"fill"}, nil, alloc) == nil)
	leaf := highlighters_create_fill({"red"}, nil, alloc)
	defer highlighter_destroy(leaf, alloc)
	testing.expect(t, highlighters_create_region({"a", "b", "fill"}, leaf, alloc) == nil)

}

@(test)
highlighters_test_fill_and_regex :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)
	defer highlighters_test_track_check(t, &track)
	// Private temp arena: the runner shares one temp arena across
	// parallel tests and wipes it per test, so impl scratch must not
	// use the global temp allocator here.
	temp_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&temp_arena, alloc, alloc)
	context.temp_allocator = mem.dynamic_arena_allocator(&temp_arena)
	defer mem.dynamic_arena_destroy(&temp_arena)

	s: Highlighters_Test_Setup
	highlighters_test_setup_make(&s, {"foo bar foo\n", "second\n"}, alloc)
	defer highlighters_test_setup_destroy(&s)
	rng := highlighters_test_range(&s)

	fill := highlighters_create_fill({"red"}, nil, alloc)
	defer highlighter_destroy(fill, alloc)
	db := highlighters_test_display_buffer(&s, alloc)
	defer display_buffer_destroy(&db)
	highlighter_highlight(fill, highlighters_test_hctx(&s, {.Colorize}), &db, rng)
	for &line in db.lines {
		for &atom in line.atoms {
			testing.expect(t, highlighters_test_fg(atom.face, .Red))
		}
	}

	// Regex highlights only the matches, splitting atoms at boundaries.
	re := highlighters_create_regex({"foo", "0:blue"}, nil, alloc)
	defer highlighter_destroy(re, alloc)
	db2 := highlighters_test_display_buffer(&s, alloc)
	defer display_buffer_destroy(&db2)
	highlighter_highlight(re, highlighters_test_hctx(&s, {.Colorize}), &db2, rng)
	blue_runs := 0
	for &atom in db2.lines[0].atoms {
		content := display_buffer_atom_content(atom)
		if content == "foo" {
			testing.expect(t, highlighters_test_fg(atom.face, .Blue))
			blue_runs += 1
		} else {
			testing.expect(t, atom.face == (Face{}))
		}
	}
	testing.expect_value(t, blue_runs, 2)
	for &atom in db2.lines[1].atoms {
		testing.expect(t, atom.face == (Face{}))
	}

	// Empty pattern matches nothing visible (no crash, no faces).
	empty_re := highlighters_create_regex({"", "0:blue"}, nil, alloc)
	defer highlighter_destroy(empty_re, alloc)
	highlighter_highlight(empty_re, highlighters_test_hctx(&s, {.Colorize}), &db2, rng)

}

@(test)
highlighters_test_dynamic_regex :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)
	defer highlighters_test_track_check(t, &track)
	// Private temp arena: the runner shares one temp arena across
	// parallel tests and wipes it per test, so impl scratch must not
	// use the global temp allocator here.
	temp_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&temp_arena, alloc, alloc)
	context.temp_allocator = mem.dynamic_arena_allocator(&temp_arena)
	defer mem.dynamic_arena_destroy(&temp_arena)

	s: Highlighters_Test_Setup
	highlighters_test_setup_make(&s, {"foo bar foo\n"}, alloc)
	defer highlighters_test_setup_destroy(&s)
	rng := highlighters_test_range(&s)

	dyn := highlighters_create_dynamic_regex({"foo", "0:green"}, nil, alloc)
	defer highlighter_destroy(dyn, alloc)
	db := highlighters_test_display_buffer(&s, alloc)
	defer display_buffer_destroy(&db)
	hctx := highlighters_test_hctx(&s, {.Colorize})
	highlighter_highlight(dyn, hctx, &db, rng)
	green_runs := 0
	for &atom in db.lines[0].atoms {
		if display_buffer_atom_content(atom) == "foo" {
			testing.expect(t, highlighters_test_fg(atom.face, .Green))
			green_runs += 1
		}
	}
	testing.expect_value(t, green_runs, 2)

	// An invalid expression resets to empty and highlights nothing.
	bad := highlighters_create_dynamic_regex({"(o", "0:green"}, nil, alloc)
	defer highlighter_destroy(bad, alloc)
	highlighter_highlight(bad, hctx, &db, rng)

}

@(test)
highlighters_test_line_and_column :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)
	defer highlighters_test_track_check(t, &track)
	// Private temp arena: the runner shares one temp arena across
	// parallel tests and wipes it per test, so impl scratch must not
	// use the global temp allocator here.
	temp_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&temp_arena, alloc, alloc)
	context.temp_allocator = mem.dynamic_arena_allocator(&temp_arena)
	defer mem.dynamic_arena_destroy(&temp_arena)

	s: Highlighters_Test_Setup
	highlighters_test_setup_make(&s, {"one\n", "two\n", "three\n"}, alloc)
	defer highlighters_test_setup_destroy(&s)
	rng := highlighters_test_range(&s)
	hctx := highlighters_test_hctx(&s, {.Colorize})

	line := highlighters_create_line({"2", "red"}, nil, alloc)
	defer highlighter_destroy(line, alloc)
	db := highlighters_test_display_buffer(&s, alloc)
	defer display_buffer_destroy(&db)
	highlighter_highlight(line, hctx, &db, rng)
	for &line_atoms, i in db.lines {
		for &atom in line_atoms.atoms {
			if i == 1 {
				testing.expect(t, highlighters_test_fg(atom.face, .Red))
			} else {
				testing.expect(t, atom.face == (Face{}))
			}
		}
	}
	// The line is padded with spaces to the window width.
	testing.expect(t, display_buffer_line_length(db.lines[1]) == s.window.dimensions.column)

	// Out-of-range and zero lines highlight nothing.
	exprs := [3]string{"0", "99", "-3"}
	for expr in exprs {
		par := [2]string{expr, "red"}
		l := highlighters_create_line(par[:], nil, alloc)
		dbx := highlighters_test_display_buffer(&s, alloc)
		highlighter_highlight(l, hctx, &dbx, rng)
		for &dl in dbx.lines {
			for &atom in dl.atoms {
				testing.expect(t, atom.face == (Face{}))
			}
		}
		display_buffer_destroy(&dbx)
		highlighter_destroy(l, alloc)
	}

	col := highlighters_create_column({"2", "blue"}, nil, alloc)
	defer highlighter_destroy(col, alloc)
	db2 := highlighters_test_display_buffer(&s, alloc)
	defer display_buffer_destroy(&db2)
	highlighter_highlight(col, hctx, &db2, rng)
	for &dl in db2.lines {
		testing.expect(t, highlighters_test_fg(dl.atoms[1].face, .Blue))
		testing.expect(t, dl.atoms[0].face == (Face{}))
	}

}

@(test)
highlighters_test_column_ruler :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)
	defer highlighters_test_track_check(t, &track)
	// Private temp arena: the runner shares one temp arena across
	// parallel tests and wipes it per test, so impl scratch must not
	// use the global temp allocator here.
	temp_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&temp_arena, alloc, alloc)
	context.temp_allocator = mem.dynamic_arena_allocator(&temp_arena)
	defer mem.dynamic_arena_destroy(&temp_arena)

	s: Highlighters_Test_Setup
	highlighters_test_setup_make(&s, {"a b\n", "   \n"}, alloc)
	defer highlighters_test_setup_destroy(&s)
	rng := highlighters_test_range(&s)

	col := highlighters_create_column({"-ruler", "|", "2", "blue"}, nil, alloc)
	defer highlighter_destroy(col, alloc)
	db := highlighters_test_display_buffer(&s, alloc)
	defer display_buffer_destroy(&db)
	highlighter_highlight(col, highlighters_test_hctx(&s, {.Colorize}), &db, rng)
	// Line 0 column 2 is blank (" ") so it is replaced by the ruler.
	testing.expect_value(t, display_buffer_atom_content(db.lines[0].atoms[1]), "|")
	testing.expect(t, highlighters_test_fg(db.lines[0].atoms[1].face, .Blue))
	// A non-blank cell keeps its content and face.
	ruler2 := highlighters_create_column({"-ruler", "|", "1", "blue"}, nil, alloc)
	defer highlighter_destroy(ruler2, alloc)
	db2 := highlighters_test_display_buffer(&s, alloc)
	defer display_buffer_destroy(&db2)
	highlighter_highlight(ruler2, highlighters_test_hctx(&s, {.Colorize}), &db2, rng)
	testing.expect_value(t, display_buffer_atom_content(db2.lines[0].atoms[0]), "a")
	testing.expect(t, db2.lines[0].atoms[0].face == (Face{}))

}

@(test)
highlighters_test_wrap :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)
	defer highlighters_test_track_check(t, &track)
	// Private temp arena: the runner shares one temp arena across
	// parallel tests and wipes it per test, so impl scratch must not
	// use the global temp allocator here.
	temp_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&temp_arena, alloc, alloc)
	context.temp_allocator = mem.dynamic_arena_allocator(&temp_arena)
	defer mem.dynamic_arena_destroy(&temp_arena)

	s: Highlighters_Test_Setup
	highlighters_test_setup_make(&s, {"0123456789abcdef\n"}, alloc)
	defer highlighters_test_setup_destroy(&s)
	highlighters_test_declare_option(&s, "tabstop", 8)
	rng := highlighters_test_range(&s)

	wrap := highlighters_create_wrap({"-width", "8"}, nil, alloc)
	defer highlighter_destroy(wrap, alloc)
	db := highlighters_test_display_buffer(&s, alloc)
	defer display_buffer_destroy(&db)
	hctx := highlighters_test_hctx(&s, {.Wrap})
	highlighter_highlight(wrap, hctx, &db, rng)
	testing.expect_value(t, len(db.lines), 3)
	testing.expect_value(t, display_buffer_atom_content(db.lines[0].atoms[0]), "01234567")
	testing.expect_value(t, display_buffer_atom_content(db.lines[1].atoms[0]), "89abcdef")

	// Setup disables horizontal scrolling.
	setup := Display_Setup{first_column = 4, scroll_offset = Coord_Display{0, 2}}
	highlighter_compute_display_setup(wrap, hctx, &setup)
	testing.expect_value(t, setup.first_column, Units_ColumnCount(0))
	testing.expect_value(t, setup.scroll_offset.column, Units_ColumnCount(0))

	// The wrap id disables the highlighter.
	disabled := [1]string{"wrap"}
	hctx_off := Highlight_Context{ctx = &s.ctx, setup = &s.setup, pass = {.Wrap}, disabled_ids = disabled[:]}
	db2 := highlighters_test_display_buffer(&s, alloc)
	defer display_buffer_destroy(&db2)
	highlighter_highlight(wrap, hctx_off, &db2, rng)
	testing.expect_value(t, len(db2.lines), 1)

	ids := make([dynamic]string, alloc)
	defer delete(ids)
	highlighter_fill_unique_ids(wrap, &ids)
	testing.expect_value(t, len(ids), 1)
	testing.expect_value(t, ids[0], "wrap")

}

@(test)
highlighters_test_tabulation :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)
	defer highlighters_test_track_check(t, &track)
	// Private temp arena: the runner shares one temp arena across
	// parallel tests and wipes it per test, so impl scratch must not
	// use the global temp allocator here.
	temp_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&temp_arena, alloc, alloc)
	context.temp_allocator = mem.dynamic_arena_allocator(&temp_arena)
	defer mem.dynamic_arena_destroy(&temp_arena)

	s: Highlighters_Test_Setup
	highlighters_test_setup_make(&s, {"a\tb\n"}, alloc)
	defer highlighters_test_setup_destroy(&s)
	highlighters_test_declare_option(&s, "tabstop", 8)
	rng := highlighters_test_range(&s)

	tab := highlighters_tabulation_make(alloc)
	defer highlighter_destroy(tab, alloc)
	db := highlighters_test_display_buffer(&s, alloc)
	defer display_buffer_destroy(&db)
	highlighter_highlight(tab, highlighters_test_hctx(&s, {.Replace}), &db, rng)
	testing.expect_value(t, len(db.lines[0].atoms), 3)
	testing.expect_value(t, display_buffer_atom_content(db.lines[0].atoms[1]), "       ")
	testing.expect_value(t, display_buffer_line_length(db.lines[0]), Coord_Column(10))

}

@(test)
highlighters_test_show_whitespaces :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)
	defer highlighters_test_track_check(t, &track)
	// Private temp arena: the runner shares one temp arena across
	// parallel tests and wipes it per test, so impl scratch must not
	// use the global temp allocator here.
	temp_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&temp_arena, alloc, alloc)
	context.temp_allocator = mem.dynamic_arena_allocator(&temp_arena)
	defer mem.dynamic_arena_destroy(&temp_arena)

	s: Highlighters_Test_Setup
	highlighters_test_setup_make(&s, {"a b\n"}, alloc)
	defer highlighters_test_setup_destroy(&s)
	highlighters_test_declare_option(&s, "tabstop", 8)
	highlighters_test_declare_option(&s, "indentwidth", 4)
	rng := highlighters_test_range(&s)

	ws := highlighters_create_show_whitespaces({}, nil, alloc)
	defer highlighter_destroy(ws, alloc)
	db := highlighters_test_display_buffer(&s, alloc)
	defer display_buffer_destroy(&db)
	highlighter_highlight(ws, highlighters_test_hctx(&s, {.Replace}), &db, rng)
	found_spc := false
	for &atom in db.lines[0].atoms {
		if display_buffer_atom_content(atom) == "·" {
			found_spc = true
		}
	}
	testing.expect(t, found_spc)

}

@(test)
highlighters_test_line_numbers :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)
	defer highlighters_test_track_check(t, &track)
	// Private temp arena: the runner shares one temp arena across
	// parallel tests and wipes it per test, so impl scratch must not
	// use the global temp allocator here.
	temp_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&temp_arena, alloc, alloc)
	context.temp_allocator = mem.dynamic_arena_allocator(&temp_arena)
	defer mem.dynamic_arena_destroy(&temp_arena)

	s: Highlighters_Test_Setup
	highlighters_test_setup_make(&s, {"a\n", "b\n"}, alloc)
	defer highlighters_test_setup_destroy(&s)
	rng := highlighters_test_range(&s)

	nums := highlighters_create_line_numbers({}, nil, alloc)
	defer highlighter_destroy(nums, alloc)
	db := highlighters_test_display_buffer(&s, alloc)
	defer display_buffer_destroy(&db)
	hctx := highlighters_test_hctx(&s, {.Move})
	highlighter_highlight(nums, hctx, &db, rng)
	testing.expect_value(t, display_buffer_atom_content(db.lines[0].atoms[0]), " 1")
	testing.expect_value(t, display_buffer_atom_content(db.lines[1].atoms[0]), " 2")
	testing.expect_value(t, display_buffer_atom_content(db.lines[0].atoms[1]), "│")

	setup := Display_Setup{}
	highlighter_compute_display_setup(nums, hctx, &setup)
	testing.expect(t, setup.widget_columns > 0)

	disabled := [1]string{"line-numbers"}
	hctx_off := Highlight_Context{ctx = &s.ctx, setup = &s.setup, pass = {.Move}, disabled_ids = disabled[:]}
	db2 := highlighters_test_display_buffer(&s, alloc)
	defer display_buffer_destroy(&db2)
	highlighter_highlight(nums, hctx_off, &db2, rng)
	testing.expect_value(t, len(db2.lines[0].atoms), 1)
}

@(test)
highlighters_test_matching :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)
	defer highlighters_test_track_check(t, &track)
	// Private temp arena: the runner shares one temp arena across
	// parallel tests and wipes it per test, so impl scratch must not
	// use the global temp allocator here.
	temp_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&temp_arena, alloc, alloc)
	context.temp_allocator = mem.dynamic_arena_allocator(&temp_arena)
	defer mem.dynamic_arena_destroy(&temp_arena)

	s: Highlighters_Test_Setup
	highlighters_test_setup_make(&s, {"(a)\n"}, alloc)
	defer highlighters_test_setup_destroy(&s)
	pairs := make([dynamic]rune, 2, alloc)
	pairs[0], pairs[1] = '(', ')'
	highlighters_test_declare_option(&s, "matching_pairs", pairs)
	rng := highlighters_test_range(&s)

	show := highlighters_create_matching({}, nil, alloc)
	defer highlighter_destroy(show, alloc)
	db := highlighters_test_display_buffer(&s, alloc)
	defer display_buffer_destroy(&db)
	highlighter_highlight(show, highlighters_test_hctx(&s, {.Colorize}), &db, rng)
	// The cursor sits on '('; the closer must be split out and bolded.
	bold_runs := 0
	for &atom in db.lines[0].atoms {
		if .Bold in atom.face.attributes {
			testing.expect_value(t, display_buffer_atom_content(atom), ")")
			bold_runs += 1
		}
	}
	testing.expect_value(t, bold_runs, 1)
}

@(test)
highlighters_test_selections :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)
	defer highlighters_test_track_check(t, &track)
	// Private temp arena: the runner shares one temp arena across
	// parallel tests and wipes it per test, so impl scratch must not
	// use the global temp allocator here.
	temp_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&temp_arena, alloc, alloc)
	context.temp_allocator = mem.dynamic_arena_allocator(&temp_arena)
	defer mem.dynamic_arena_destroy(&temp_arena)

	s: Highlighters_Test_Setup
	highlighters_test_setup_make(&s, {"abcd\n"}, alloc)
	defer highlighters_test_setup_destroy(&s)
	sels := context_selections(&s.ctx, false)
	sels.selections[0].anchor = Coord_Buffer{0, 1}
	sels.selections[0].cursor.coord = Coord_Buffer{0, 3}
	rng := highlighters_test_range(&s)

	sel := highlighters_selections_make(alloc)
	defer highlighter_destroy(sel, alloc)
	db := highlighters_test_display_buffer(&s, alloc)
	defer display_buffer_destroy(&db)
	highlighter_highlight(sel, highlighters_test_hctx(&s, {.Colorize}), &db, rng)
	// Selection [1,3) splits out; cursor at {0,3} splits one more char.
	testing.expect(t, len(db.lines[0].atoms) >= 3)
	primary_sel := highlighters_lookup_face(&s.ctx, "PrimarySelection")
	highlighted := 0
	for &atom in db.lines[0].atoms {
		if atom.face == primary_sel && primary_sel != (Face{}) {
			highlighted += 1
		}
	}
	testing.expect(t, highlighted >= 1)
}

@(test)
highlighters_test_unprintable :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)
	defer highlighters_test_track_check(t, &track)
	// Private temp arena: the runner shares one temp arena across
	// parallel tests and wipes it per test, so impl scratch must not
	// use the global temp allocator here.
	temp_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&temp_arena, alloc, alloc)
	context.temp_allocator = mem.dynamic_arena_allocator(&temp_arena)
	defer mem.dynamic_arena_destroy(&temp_arena)

	s: Highlighters_Test_Setup
	highlighters_test_setup_make(&s, {"a\x01b\n"}, alloc)
	defer highlighters_test_setup_destroy(&s)
	rng := highlighters_test_range(&s)

	un := highlighters_unprintable_make(alloc)
	defer highlighter_destroy(un, alloc)
	db := highlighters_test_display_buffer(&s, alloc)
	defer display_buffer_destroy(&db)
	highlighter_highlight(un, highlighters_test_hctx(&s, {.Colorize}), &db, rng)
	found := false
	for &atom in db.lines[0].atoms {
		if display_buffer_atom_content(atom) == "�" {
			found = true
		}
	}
	testing.expect(t, found)
}

@(test)
highlighters_test_flag_lines :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)
	defer highlighters_test_track_check(t, &track)
	// Private temp arena: the runner shares one temp arena across
	// parallel tests and wipes it per test, so impl scratch must not
	// use the global temp allocator here.
	temp_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&temp_arena, alloc, alloc)
	context.temp_allocator = mem.dynamic_arena_allocator(&temp_arena)
	defer mem.dynamic_arena_destroy(&temp_arena)

	s: Highlighters_Test_Setup
	highlighters_test_setup_make(&s, {"a\n", "b\n"}, alloc)
	defer highlighters_test_setup_destroy(&s)
	specs := Line_And_Spec_List{prefix = uint(buffer_timestamp(s.buffer))}
	specs.list = make([dynamic]Line_And_Spec, alloc)
	append(&specs.list, Line_And_Spec{line = 2, spec = strings.clone("»", alloc)})
	highlighters_test_declare_option(&s, "flags", specs)
	rng := highlighters_test_range(&s)

	flag := highlighters_create_flag_lines({"red", "flags"}, nil, alloc)
	defer highlighter_destroy(flag, alloc)
	db := highlighters_test_display_buffer(&s, alloc)
	defer display_buffer_destroy(&db)
	hctx := highlighters_test_hctx(&s, {.Move})
	highlighter_highlight(flag, hctx, &db, rng)
	testing.expect_value(t, display_buffer_atom_content(db.lines[1].atoms[0]), "»")
	testing.expect(t, highlighters_test_fg(db.lines[1].atoms[0].face, .Red))
	// Unflagged lines get blank padding of the same width.
	testing.expect_value(t, display_buffer_atom_content(db.lines[0].atoms[0]), " ")

	setup := Display_Setup{}
	highlighter_compute_display_setup(flag, hctx, &setup)
	testing.expect(t, setup.widget_columns > 0)

	after := highlighters_create_flag_lines({"-after", "red", "flags"}, nil, alloc)
	defer highlighter_destroy(after, alloc)
	db2 := highlighters_test_display_buffer(&s, alloc)
	defer display_buffer_destroy(&db2)
	highlighter_highlight(after, hctx, &db2, rng)
	last := &db2.lines[1].atoms[len(db2.lines[1].atoms) - 1]
	testing.expect_value(t, display_buffer_atom_content(last^), "»")
	setup2 := Display_Setup{}
	highlighter_compute_display_setup(after, hctx, &setup2)
	testing.expect_value(t, setup2.widget_columns, Units_ColumnCount(0))
}

@(test)
highlighters_test_ranges :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)
	defer highlighters_test_track_check(t, &track)
	// Private temp arena: the runner shares one temp arena across
	// parallel tests and wipes it per test, so impl scratch must not
	// use the global temp allocator here.
	temp_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&temp_arena, alloc, alloc)
	context.temp_allocator = mem.dynamic_arena_allocator(&temp_arena)
	defer mem.dynamic_arena_destroy(&temp_arena)

	s: Highlighters_Test_Setup
	highlighters_test_setup_make(&s, {"abcd\n"}, alloc)
	defer highlighters_test_setup_destroy(&s)
	specs := Range_And_String_List{prefix = uint(buffer_timestamp(s.buffer))}
	specs.list = make([dynamic]Range_And_String, alloc)
	append(
		&specs.list,
		Range_And_String{
			range = Inclusive_Buffer_Range{first = Coord_Buffer{0, 1}, last = Coord_Buffer{0, 2}},
			spec = strings.clone("red", alloc),
		},
	)
	highlighters_test_declare_option(&s, "ranges", specs)
	rng := highlighters_test_range(&s)

	r := highlighters_create_ranges({"ranges"}, nil, alloc)
	defer highlighter_destroy(r, alloc)
	db := highlighters_test_display_buffer(&s, alloc)
	defer display_buffer_destroy(&db)
	highlighter_highlight(r, highlighters_test_hctx(&s, {.Colorize}), &db, rng)
	// The highlighted text covers exactly "bc".
	covered := strings.builder_make(context.temp_allocator)
	for &atom in db.lines[0].atoms {
		if highlighters_test_fg(atom.face, .Red) {
			strings.write_string(&covered, display_buffer_atom_content(atom))
		}
	}
	testing.expect_value(t, strings.to_string(covered), "bc")
}

@(test)
highlighters_test_replace_ranges :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)
	defer highlighters_test_track_check(t, &track)
	// Private temp arena: the runner shares one temp arena across
	// parallel tests and wipes it per test, so impl scratch must not
	// use the global temp allocator here.
	temp_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&temp_arena, alloc, alloc)
	context.temp_allocator = mem.dynamic_arena_allocator(&temp_arena)
	defer mem.dynamic_arena_destroy(&temp_arena)

	s: Highlighters_Test_Setup
	highlighters_test_setup_make(&s, {"hello\n"}, alloc)
	defer highlighters_test_setup_destroy(&s)
	// The selection must fully cover the replaced range.
	sels := context_selections(&s.ctx, false)
	sels.selections[0].cursor.coord = Coord_Buffer{0, 4}
	specs := Range_And_String_List{prefix = uint(buffer_timestamp(s.buffer))}
	specs.list = make([dynamic]Range_And_String, alloc)
	append(
		&specs.list,
		Range_And_String{
			range = Inclusive_Buffer_Range{first = Coord_Buffer{0, 0}, last = Coord_Buffer{0, 1}},
			spec = strings.clone("XY", alloc),
		},
	)
	highlighters_test_declare_option(&s, "ranges", specs)
	rng := highlighters_test_range(&s)

	r := highlighters_create_replace_ranges({"ranges"}, nil, alloc)
	defer highlighter_destroy(r, alloc)
	db := highlighters_test_display_buffer(&s, alloc)
	defer display_buffer_destroy(&db)
	highlighter_highlight(r, highlighters_test_hctx(&s, {.Replace}), &db, rng)
	testing.expect_value(t, display_buffer_atom_content(db.lines[0].atoms[0]), "XY")
	testing.expect_value(t, db.lines[0].atoms[0].type, Display_Atom_Type.Replaced_Range)
	testing.expect_value(t, display_buffer_atom_content(db.lines[0].atoms[1]), "llo\n")

	// A range only partially covered by a selection is left alone.
	sels.selections[0].anchor = Coord_Buffer{0, 0}
	sels.selections[0].cursor.coord = Coord_Buffer{0, 0}
	db2 := highlighters_test_display_buffer(&s, alloc)
	defer display_buffer_destroy(&db2)
	highlighter_highlight(r, highlighters_test_hctx(&s, {.Replace}), &db2, rng)
	testing.expect_value(t, len(db2.lines[0].atoms), 1)
}

@(test)
highlighters_test_reference :: proc(t: ^testing.T) {
	// The recursion guard is a process-global stack; drop its backing
	// here so per-test tracking sees no leftover.
	defer {
		delete(Highlighters_Running_Refs)
		Highlighters_Running_Refs = nil
	}
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)
	defer highlighters_test_track_check(t, &track)
	// Private temp arena: the runner shares one temp arena across
	// parallel tests and wipes it per test, so impl scratch must not
	// use the global temp allocator here.
	temp_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&temp_arena, alloc, alloc)
	context.temp_allocator = mem.dynamic_arena_allocator(&temp_arena)
	defer mem.dynamic_arena_destroy(&temp_arena)

	s: Highlighters_Test_Setup
	highlighters_test_setup_make(&s, {"hello\n"}, alloc)
	defer highlighters_test_setup_destroy(&s)
	rng := highlighters_test_range(&s)

	highlighters_test_shared_setup(alloc)
	defer highlighters_test_shared_teardown()
	shared := highlighters_shared_instance()
	testing.expect(t, highlighters_shared_has_instance)
	_ = highlighters_group_add_child(&shared.group, "shared-red", highlighters_create_fill({"red"}, nil, alloc))

	ref := highlighters_create_reference({"shared-red"}, nil, alloc)
	defer highlighter_destroy(ref, alloc)
	db := highlighters_test_display_buffer(&s, alloc)
	defer display_buffer_destroy(&db)
	highlighter_highlight(ref, highlighters_test_hctx(&s, {.Colorize}), &db, rng)
	testing.expect(t, highlighters_test_fg(db.lines[0].atoms[0].face, .Red))

	// Missing targets are a silent no-op.
	missing := highlighters_create_reference({"nope"}, nil, alloc)
	defer highlighter_destroy(missing, alloc)
	db2 := highlighters_test_display_buffer(&s, alloc)
	defer display_buffer_destroy(&db2)
	highlighter_highlight(missing, highlighters_test_hctx(&s, {.Colorize}), &db2, rng)
	testing.expect(t, db2.lines[0].atoms[0].face == (Face{}))

	// A self-referential group terminates via the recursion guard.
	loop := highlighters_create_group({}, nil, alloc)
	_ = highlighters_group_add_child(
		cast(^Highlighter_Group)loop.data,
		"self",
		highlighters_create_reference({"loop"}, nil, alloc),
	)
	_ = highlighters_group_add_child(&shared.group, "loop", loop)
	recurse := highlighters_create_reference({"loop"}, nil, alloc)
	defer highlighter_destroy(recurse, alloc)
	highlighter_highlight(recurse, highlighters_test_hctx(&s, {.Colorize}), &db2, rng)
	testing.expect_value(t, len(Highlighters_Running_Refs), 0)
}

@(test)
highlighters_test_regions :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)
	defer highlighters_test_track_check(t, &track)
	// Private temp arena: the runner shares one temp arena across
	// parallel tests and wipes it per test, so impl scratch must not
	// use the global temp allocator here.
	temp_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&temp_arena, alloc, alloc)
	context.temp_allocator = mem.dynamic_arena_allocator(&temp_arena)
	defer mem.dynamic_arena_destroy(&temp_arena)

	highlighters_test_registry_setup(alloc)
	defer highlighters_test_registry_teardown()
	highlighters_register()

	s: Highlighters_Test_Setup
	highlighters_test_setup_make(&s, {"code /* c */ more\n"}, alloc)
	defer highlighters_test_setup_destroy(&s)
	rng := highlighters_test_range(&s)

	regions := highlighters_create_regions({}, nil, alloc)
	defer highlighter_destroy(regions, alloc)
	rdata := cast(^Highlighters_Regions_Data)regions.data
	comment_params := [4]string{"/\\*", "\\*/", "fill", "red"}
	comment := highlighters_create_region(comment_params[:], regions, alloc)
	testing.expect(t, comment != nil)
	if comment == nil {
		return
	}
	testing.expect_value(t, highlighters_regions_add_child(rdata, "comment", comment), Highlighters_Error.None)
	default_params := [2]string{"fill", "blue"}
	default := highlighters_create_default_region(default_params[:], regions, alloc)
	testing.expect(t, default != nil)
	if default == nil {
		return
	}
	testing.expect_value(t, highlighters_regions_add_child(rdata, "default", default), Highlighters_Error.None)

	// Only region wrappers may be added; only one default may exist.
	orphan := highlighters_create_fill({"red"}, nil, alloc)
	testing.expect_value(
		t,
		highlighters_regions_add_child(rdata, "nope", orphan),
		Highlighters_Error.Wrong_Child_Type,
	)
	highlighter_destroy(orphan, alloc)
	other_default := highlighters_create_default_region(default_params[:], regions, alloc)
	testing.expect_value(
		t,
		highlighters_regions_add_child(rdata, "other", other_default),
		Highlighters_Error.Duplicate_Id,
	)
	highlighter_destroy(other_default, alloc)
	rejected, _ := highlighters_regions_get_child(rdata, "nope")
	testing.expect(t, rejected == nil)

	db := highlighters_test_display_buffer(&s, alloc)
	defer display_buffer_destroy(&db)
	highlighter_highlight(regions, highlighters_test_hctx(&s, {.Colorize}), &db, rng)
	red_text := strings.builder_make(context.temp_allocator)
	blue_text := strings.builder_make(context.temp_allocator)
	for &atom in db.lines[0].atoms {
		if highlighters_test_fg(atom.face, .Red) {
			strings.write_string(&red_text, display_buffer_atom_content(atom))
		}
		if highlighters_test_fg(atom.face, .Blue) {
			strings.write_string(&blue_text, display_buffer_atom_content(atom))
		}
	}
	testing.expect_value(t, strings.to_string(red_text), "/* c */")
	testing.expect_value(t, strings.to_string(blue_text), "code  more\n")

	// Region factories validate patterns and delegate types.
	bad_begin := [3]string{"(bad", "x", "fill"}
	testing.expect(t, highlighters_create_region(bad_begin[:], regions, alloc) == nil)
	bad_end := [3]string{"a", "(bad", "fill"}
	testing.expect(t, highlighters_create_region(bad_end[:], regions, alloc) == nil)
	bad_type := [3]string{"a", "b", "nope"}
	testing.expect(t, highlighters_create_region(bad_type[:], regions, alloc) == nil)
	empty_begin := [3]string{"", "b", "fill"}
	testing.expect(t, highlighters_create_region(empty_begin[:], regions, alloc) == nil)
	bad_default := [1]string{"nope"}
	testing.expect(t, highlighters_create_default_region(bad_default[:], regions, alloc) == nil)

	found, err := highlighters_regions_get_child(rdata, "comment")
	testing.expect_value(t, err, Highlighters_Error.None)
	testing.expect(t, found == comment)
	testing.expect_value(t, highlighters_regions_remove_child(rdata, "default"), Highlighters_Error.None)
	testing.expect_value(t, highlighters_regions_remove_child(rdata, "default"), Highlighters_Error.No_Such_Id)
	completions := highlighters_regions_complete_child(rdata, "", Units_ByteCount(0), false, alloc)
	defer delete(completions.candidates)
	testing.expect(t, len(completions.candidates) >= 1)
}

@(test)
highlighters_test_spec_updates :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)
	defer highlighters_test_track_check(t, &track)
	// Private temp arena: the runner shares one temp arena across
	// parallel tests and wipes it per test, so impl scratch must not
	// use the global temp allocator here.
	temp_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&temp_arena, alloc, alloc)
	context.temp_allocator = mem.dynamic_arena_allocator(&temp_arena)
	defer mem.dynamic_arena_destroy(&temp_arena)

	s: Highlighters_Test_Setup
	highlighters_test_setup_make(&s, {"a\n", "b\n", "c\n"}, alloc)
	defer highlighters_test_setup_destroy(&s)

	// Line specs shift with inserted lines and drop removed ones.
	line_specs := Line_And_Spec_List{prefix = uint(buffer_timestamp(s.buffer))}
	line_specs.list = make([dynamic]Line_And_Spec, alloc)
	defer delete(line_specs.list)
	append(&line_specs.list, Line_And_Spec{line = 2, spec = "x"})
	append(&line_specs.list, Line_And_Spec{line = 3, spec = "y"})
	_, insert_err := buffer_insert(s.buffer, Coord_Buffer{0, 0}, "new\n")
	testing.expect_value(t, insert_err, Buffer_Error.None)
	highlighters_line_specs_update(&line_specs, &s.ctx)
	testing.expect_value(t, len(line_specs.list), 2)
	testing.expect_value(t, line_specs.list[0].line, Coord_Line(3))
	testing.expect_value(t, line_specs.list[1].line, Coord_Line(4))
	_, erase_err := buffer_erase(s.buffer, Coord_Buffer{0, 0}, Coord_Buffer{1, 0})
	testing.expect_value(t, erase_err, Buffer_Error.None)
	append(&line_specs.list, Line_And_Spec{line = 1, spec = "gone"})
	_, erase_err2 := buffer_erase(s.buffer, Coord_Buffer{0, 0}, Coord_Buffer{1, 0})
	testing.expect_value(t, erase_err2, Buffer_Error.None)
	highlighters_line_specs_update(&line_specs, &s.ctx)
	for spec in line_specs.list {
		testing.expect(t, spec.spec != "gone")
	}
	// A current prefix is a no-op.
	prefix := line_specs.prefix
	highlighters_line_specs_update(&line_specs, &s.ctx)
	testing.expect_value(t, line_specs.prefix, prefix)

	// Range specs shift with edits.
	range_specs := Range_And_String_List{prefix = uint(buffer_timestamp(s.buffer))}
	range_specs.list = make([dynamic]Range_And_String, alloc)
	defer {
		// Every element owns its spec string (the literal below is
		// cloned, parsed additions arrive owned), so free each.
		for e in range_specs.list {
			option_manager_range_spec_free(e, alloc)
		}
		delete(range_specs.list)
	}
	append(
		&range_specs.list,
		Range_And_String{
			range = Inclusive_Buffer_Range{first = Coord_Buffer{0, 0}, last = Coord_Buffer{0, 0}},
			spec = strings.clone("red", alloc),
		},
	)
	_, _ = buffer_insert(s.buffer, Coord_Buffer{0, 0}, "top\n")
	highlighters_range_specs_update(&range_specs, &s.ctx)
	testing.expect_value(t, range_specs.list[0].range.first, Coord_Buffer{1, 0})
	testing.expect_value(t, int(range_specs.prefix), buffer_timestamp(s.buffer))

	// Sorting and add-from-strings keep lists ordered.
	highlighters_line_specs_postprocess(&line_specs.list)
	for i in 1 ..< len(line_specs.list) {
		testing.expect(t, line_specs.list[i - 1].line <= line_specs.list[i].line)
	}
	add_params := [1]string{"1.1,1.2|blue"}
	added := highlighters_range_specs_add_from_strings(&range_specs.list, add_params[:], alloc)
	testing.expect(t, added)
	testing.expect(t, len(range_specs.list) == 2)
	highlighters_range_specs_postprocess(&range_specs.list)
	testing.expect(t, !highlighters_range_specs_add_from_strings(&range_specs.list, {}, alloc))
	bogus := [1]string{"bogus"}
	testing.expect(t, !highlighters_range_specs_add_from_strings(&range_specs.list, bogus[:], alloc))
}

@(test)
highlighters_test_range_helpers :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)
	defer highlighters_test_track_check(t, &track)
	// Private temp arena: the runner shares one temp arena across
	// parallel tests and wipes it per test, so impl scratch must not
	// use the global temp allocator here.
	temp_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&temp_arena, alloc, alloc)
	context.temp_allocator = mem.dynamic_arena_allocator(&temp_arena)
	defer mem.dynamic_arena_destroy(&temp_arena)

	s: Highlighters_Test_Setup
	highlighters_test_setup_make(&s, {"abcdef\n", "gh\n"}, alloc)
	defer highlighters_test_setup_destroy(&s)
	red := Face{fg = color_from_named(.Red)}

	// Empty display buffers are a no-op.
	empty_db := display_buffer_make(alloc)
	defer display_buffer_destroy(&empty_db)
	highlighters_highlight_range(&empty_db, Coord_Buffer{0, 0}, Coord_Buffer{0, 1}, false, red)

	db := highlighters_test_display_buffer(&s, alloc)
	defer display_buffer_destroy(&db)
	// Reversed and out-of-range inputs highlight nothing.
	highlighters_highlight_range(&db, Coord_Buffer{0, 3}, Coord_Buffer{0, 1}, false, red)
	highlighters_highlight_range(&db, Coord_Buffer{9, 0}, Coord_Buffer{9, 2}, false, red)
	for &line in db.lines {
		for &atom in line.atoms {
			testing.expect(t, atom.face == (Face{}))
		}
	}
	// skip_replaced leaves Replaced_Range atoms alone.
	db.lines[0].atoms[0].type = .Replaced_Range
	highlighters_highlight_range(&db, Coord_Buffer{0, 0}, Coord_Buffer{0, 6}, true, red)
	testing.expect(t, db.lines[0].atoms[0].face == (Face{}))
	db.lines[0].atoms[0].type = .Range
	highlighters_highlight_range(&db, Coord_Buffer{0, 0}, Coord_Buffer{0, 6}, false, red)
	testing.expect(t, highlighters_test_fg(db.lines[0].atoms[0].face, .Red))

	// Single-line erase returns the gap; misses report false.
	db2 := highlighters_test_display_buffer(&s, alloc)
	defer display_buffer_destroy(&db2)
	li, ai, ok := highlighters_replace_range_erase(&db2, Coord_Buffer{0, 1}, Coord_Buffer{0, 3})
	testing.expect(t, ok)
	testing.expect_value(t, li, 0)
	testing.expect_value(t, ai, 1)
	testing.expect_value(t, display_buffer_atom_content(db2.lines[0].atoms[0]), "a")
	testing.expect_value(t, display_buffer_atom_content(db2.lines[0].atoms[1]), "def\n")
	_, _, ok = highlighters_replace_range_erase(&db2, Coord_Buffer{9, 0}, Coord_Buffer{9, 1})
	testing.expect(t, !ok)
	// Multi-line erase merges the survivors into one line.
	_, _, ok = highlighters_replace_range_erase(&db2, Coord_Buffer{0, 0}, Coord_Buffer{1, 1})
	testing.expect(t, ok)
	testing.expect_value(t, len(db2.lines), 1)
	testing.expect_value(t, display_buffer_atom_content(db2.lines[0].atoms[0]), "h\n")

	// Column computation expands tabs.
	s2: Highlighters_Test_Setup
	highlighters_test_setup_make(&s2, {"a\tb\n"}, alloc)
	defer highlighters_test_setup_destroy(&s2)
	testing.expect_value(t, highlighters_get_column(s2.buffer, 8, Coord_Buffer{0, 0}), Coord_Column(0))
	testing.expect_value(t, highlighters_get_column(s2.buffer, 8, Coord_Buffer{0, 1}), Coord_Column(1))
	testing.expect_value(t, highlighters_get_column(s2.buffer, 8, Coord_Buffer{0, 2}), Coord_Column(8))
}

@(test)
highlighters_test_wrap_words :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)
	defer highlighters_test_track_check(t, &track)
	// Private temp arena: the runner shares one temp arena across
	// parallel tests and wipes it per test, so impl scratch must not
	// use the global temp allocator here.
	temp_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&temp_arena, alloc, alloc)
	context.temp_allocator = mem.dynamic_arena_allocator(&temp_arena)
	defer mem.dynamic_arena_destroy(&temp_arena)

	s: Highlighters_Test_Setup
	highlighters_test_setup_make(&s, {"aa bb cc dd ee\n"}, alloc)
	defer highlighters_test_setup_destroy(&s)
	highlighters_test_declare_option(&s, "tabstop", 8)
	rng := highlighters_test_range(&s)

	params := [3]string{"-word", "-width", "7"}
	wrap := highlighters_create_wrap(params[:], nil, alloc)
	defer highlighter_destroy(wrap, alloc)
	db := highlighters_test_display_buffer(&s, alloc)
	defer display_buffer_destroy(&db)
	highlighter_highlight(wrap, highlighters_test_hctx(&s, {.Wrap}), &db, rng)
	testing.expect(t, len(db.lines) > 1)
	// Wrapping preserves the text: joining all atoms recovers the line.
	joined := strings.builder_make(context.temp_allocator)
	for &line in db.lines {
		for &atom in line.atoms {
			strings.write_string(&joined, display_buffer_atom_content(atom))
		}
	}
	testing.expect_value(t, strings.to_string(joined), "aa bb cc dd ee\n")
	for &line in db.lines {
		testing.expect(t, display_buffer_line_length(line) <= Coord_Column(7))
	}
}

// Regions with tied begin positions resolve in insertion order (port of
// the C++ HashMap item order; regression: Odin map order let a later
// line_comment region shadow an earlier doctest region).
@(test)
highlighters_test_regions_tie_breaks_by_insertion_order :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)
	defer highlighters_test_track_check(t, &track)
	temp_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&temp_arena, alloc, alloc)
	context.temp_allocator = mem.dynamic_arena_allocator(&temp_arena)
	defer mem.dynamic_arena_destroy(&temp_arena)

	highlighters_test_registry_setup(alloc)
	defer highlighters_test_registry_teardown()
	highlighters_register()

	s: Highlighters_Test_Setup
	highlighters_test_setup_make(&s, {"/// fence\n"}, alloc)
	defer highlighters_test_setup_destroy(&s)
	rng := highlighters_test_range(&s)

	regions := highlighters_create_regions({}, nil, alloc)
	defer highlighter_destroy(regions, alloc)
	rdata := cast(^Highlighters_Regions_Data)regions.data
	// Both regions open at column 0; the first added must win.
	first_params := [4]string{"//[/]", "$", "fill", "red"}
	first := highlighters_create_region(first_params[:], regions, alloc)
	testing.expect(t, first != nil)
	if first == nil {
		return
	}
	testing.expect_value(t, highlighters_regions_add_child(rdata, "first", first), Highlighters_Error.None)
	second_params := [4]string{"//", "$", "fill", "blue"}
	second := highlighters_create_region(second_params[:], regions, alloc)
	testing.expect(t, second != nil)
	if second == nil {
		return
	}
	testing.expect_value(t, highlighters_regions_add_child(rdata, "second", second), Highlighters_Error.None)

	db := highlighters_test_display_buffer(&s, alloc)
	defer display_buffer_destroy(&db)
	highlighter_highlight(regions, highlighters_test_hctx(&s, {.Colorize}), &db, rng)
	red_text := strings.builder_make(context.temp_allocator)
	blue_text := strings.builder_make(context.temp_allocator)
	for &atom in db.lines[0].atoms {
		if highlighters_test_fg(atom.face, .Red) {
			strings.write_string(&red_text, display_buffer_atom_content(atom))
		}
		if highlighters_test_fg(atom.face, .Blue) {
			strings.write_string(&blue_text, display_buffer_atom_content(atom))
		}
	}
	testing.expect_value(t, strings.to_string(red_text), "/// fence")
	testing.expect_value(t, strings.to_string(blue_text), "")
}

// Group children apply in insertion order (port of the C++ HashMap item
// order; regression: Odin map order applied fill over regex
// non-deterministically, flapping comment/todo highlighting).
@(test)
highlighters_test_group_applies_children_in_insertion_order :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	alloc := mem.tracking_allocator(&track)
	defer highlighters_test_track_check(t, &track)
	temp_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&temp_arena, alloc, alloc)
	context.temp_allocator = mem.dynamic_arena_allocator(&temp_arena)
	defer mem.dynamic_arena_destroy(&temp_arena)

	highlighters_test_registry_setup(alloc)
	defer highlighters_test_registry_teardown()
	highlighters_register()

	s: Highlighters_Test_Setup
	highlighters_test_setup_make(&s, {"TODO: fix\n"}, alloc)
	defer highlighters_test_setup_destroy(&s)
	rng := highlighters_test_range(&s)

	group := highlighters_create_group({}, nil, alloc)
	testing.expect(t, group != nil)
	if group == nil {
		return
	}
	defer highlighter_destroy(group, alloc)
	gdata := cast(^Highlighter_Group)group.data
	under := highlighters_create_fill({"blue"}, nil, alloc)
	testing.expect_value(t, highlighters_group_add_child(gdata, "under", under), Highlighters_Error.None)
	over_params := [2]string{"TODO", "0:red"}
	over := highlighters_create_regex(over_params[:], nil, alloc)
	testing.expect(t, over != nil)
	if over == nil {
		return
	}
	testing.expect_value(t, highlighters_group_add_child(gdata, "over", over), Highlighters_Error.None)

	db := highlighters_test_display_buffer(&s, alloc)
	defer display_buffer_destroy(&db)
	highlighter_highlight(group, highlighters_test_hctx(&s, {.Colorize}), &db, rng)
	red_text := strings.builder_make(context.temp_allocator)
	for &atom in db.lines[0].atoms {
		if highlighters_test_fg(atom.face, .Red) {
			strings.write_string(&red_text, display_buffer_atom_content(atom))
		}
	}
	testing.expect_value(t, strings.to_string(red_text), "TODO")
}
