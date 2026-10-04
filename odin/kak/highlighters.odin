// Builtin highlighters ported from src/highlighters.{hh,cc} and the group
// container from src/highlighter_group.{hh,cc}: the per-scope Highlighters
// root, the shared registry, all 17 registered factories (fill, regex,
// dynregex, line, column, wrap, show-whitespaces, number-lines,
// show-matching, flag-lines, ranges, replace-ranges, group, ref, region,
// regions, default-region) and the 3 builtin window highlighters
// (tabulations, unprintable, selections).
//
// Design: concrete leaf highlighters share one vtable
// (highlighters_any_vtable) dispatching over the Highlighters_Payload
// union; groups, regions and region wrappers have their own vtables.
// Factories match knot's Highlighter_Factory signature, which carries no
// error channel, so invalid parameters yield nil (the C++ throws, caught
// by the add-highlighter command).
//
// Simplifications vs the C++ (all behavior-preserving):
//   * No BufferSideCache: regex/regions recompute matches per redraw.
//   * Regions matches run through regex_iterator per line instead of a
//     hand-rolled ThreadedRegexVM MatchAdder.
//   * Debug-buffer diagnostics are dropped: error paths silently keep
//     defaults (debug_write_to_debug_buffer is still a STUB in the merged
//     command_manager; calling it would panic on user errors).
//   * Ephemeral display strings (line numbers, padding, parsed specs)
//     come from context.temp_allocator: redraw-scoped scratch. The final
//     binary must reset the temp arena periodically.
//   * Dynamic-regex resets its inner highlighter whenever the source text
//     changes (the C++ also compares resolved faces; unobservable).
package kak

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"
import "core:sync"

// Highlighters_Error reports highlighter failures (port of the
// runtime_error/child_not_found throws in highlighters.cc and
// highlighter_group.cc).
Highlighters_Error :: enum {
	None,
	Wrong_Parameter_Count,
	Invalid_Parameter,
	Invalid_Face,
	Invalid_Regex,
	Invalid_Pass,
	Duplicate_Id,
	No_Such_Id,
	Wrong_Child_Type,
	No_Such_Type,
	Missing_Option,
}

// highlighters_error_message describes an error (for tests/debugging).
highlighters_error_message :: proc(err: Highlighters_Error) -> string {
	switch err {
	case .None:
		return "no error"
	case .Wrong_Parameter_Count:
		return "wrong parameter count"
	case .Invalid_Parameter:
		return "invalid parameter"
	case .Invalid_Face:
		return "invalid face specification"
	case .Invalid_Regex:
		return "invalid regex"
	case .Invalid_Pass:
		return "invalid highlight pass"
	case .Duplicate_Id:
		return "duplicate id"
	case .No_Such_Id:
		return "no such id"
	case .Wrong_Child_Type:
		return "wrong child highlighter type"
	case .No_Such_Type:
		return "no such highlighter type"
	case .Missing_Option:
		return "missing option"
	}
	return "unknown error"
}

// highlighters_parse_passes parses "colorize|move|wrap|replace" (port of
// parse_passes in highlighters.cc).
highlighters_parse_passes :: proc(str: string) -> (Highlight_Pass, Highlighters_Error) {
	passes := Highlight_Pass{}
	start := 0
	for i := 0; i <= len(str); i += 1 {
		if i == len(str) || str[i] == '|' {
			pass := str[start:i]
			switch pass {
			case "colorize":
				passes += {.Colorize}
			case "move":
				passes += {.Move}
			case "wrap":
				passes += {.Wrap}
			case "replace":
				passes += {.Replace}
			case:
				return {}, .Invalid_Pass
			}
			start = i + 1
		}
	}
	if card(passes) == 0 {
		return {}, .Invalid_Pass
	}
	return passes, .None
}

// highlighters_pass_all is the pass set of group roots (C++ All).
highlighters_pass_all :: Highlight_Pass{.Replace, .Wrap, .Move, .Colorize}

// highlighters_disabled reports whether id is in the disabled list.
highlighters_disabled :: proc(disabled_ids: []string, id: string) -> bool {
	for d in disabled_ids {
		if d == id {
			return true
		}
	}
	return false
}

// highlighters_get_column computes the display column of coord, expanding
// tabs to tabstop (clean-room port of get_column in buffer_utils.cc,
// which has no merged Odin module yet).
highlighters_get_column :: proc(buffer: ^Buffer, tabstop: int, coord: Coord_Buffer) -> Coord_Column {
	ts := tabstop
	if ts <= 0 {
		ts = 1
	}
	line := buffer.lines[int(coord.line)]
	col := Coord_Column(0)
	pos := 0
	limit := min(int(coord.column), len(line))
	for pos < limit {
		if line[pos] == '\t' {
			col = (col / Coord_Column(ts) + 1) * Coord_Column(ts)
			pos += 1
		} else {
			col += Coord_Column(unicode_codepoint_width(utf8_read_codepoint(line, &pos)))
		}
	}
	return col
}

// highlighters_option fetches a context option by name.
highlighters_option :: proc(ctx: ^Context, name: string) -> (^Option, bool) {
	opt, err := option_manager_get_option(context_options(ctx), name)
	return opt, err == .None
}

// highlighters_option_int fetches an int option value.
highlighters_option_int :: proc(ctx: ^Context, name: string) -> (int, bool) {
	opt, ok := highlighters_option(ctx, name)
	if !ok {
		return 0, false
	}
	val, is_int := option_manager_option_get(opt).(int)
	return val, is_int
}

// highlighters_option_runes borrows a []rune option value.
highlighters_option_runes :: proc(ctx: ^Context, name: string) -> ([dynamic]rune, bool) {
	opt, ok := highlighters_option(ctx, name)
	if !ok {
		return nil, false
	}
	val, is_runes := option_manager_option_get(opt).([dynamic]rune)
	return val, is_runes
}

// highlighters_option_regex borrows a Regex option value.
highlighters_option_regex :: proc(ctx: ^Context, name: string) -> (Regex, bool) {
	opt, ok := highlighters_option(ctx, name)
	if !ok {
		return {}, false
	}
	val, is_regex := option_manager_option_get(opt).(Regex)
	return val, is_regex
}

// highlighters_line_specs fetches a mutable line-specs option value.
highlighters_line_specs :: proc(ctx: ^Context, name: string) -> (^Line_And_Spec_List, bool) {
	opt, ok := highlighters_option(ctx, name)
	if !ok {
		return nil, false
	}
	#partial switch _ in opt.value {
	case Option_Timestamped_List(Line_And_Spec):
		return &opt.value.(Option_Timestamped_List(Line_And_Spec)), true
	}
	return nil, false
}

// highlighters_range_specs fetches a mutable range-specs option value.
highlighters_range_specs :: proc(ctx: ^Context, name: string) -> (^Range_And_String_List, bool) {
	opt, ok := highlighters_option(ctx, name)
	if !ok {
		return nil, false
	}
	#partial switch _ in opt.value {
	case Option_Timestamped_List(Range_And_String):
		return &opt.value.(Option_Timestamped_List(Range_And_String)), true
	}
	return nil, false
}

// highlighters_expand expands % interpolations, returning a clone of str
// when there is nothing to expand. On error returns the C++ default
// (empty string); the caller owns the result.
highlighters_expand :: proc(
	str: string,
	ctx: ^Context,
	allocator := context.allocator,
) -> string {
	shell_ctx := Shell_Context{}
	expanded, err, msg := command_manager_expand(str, ctx, &shell_ctx, allocator)
	if err != .None {
		delete(msg, allocator)
		return strings.clone("", allocator)
	}
	return expanded
}

// highlighters_expand_int expands str and parses it as an int,
// returning fallback on any error (port of the str_to_int_ifp(expand())
// idiom in the line/column highlighters).
highlighters_expand_int :: proc(str: string, ctx: ^Context, fallback: int) -> int {
	expanded := highlighters_expand(str, ctx, context.temp_allocator)
	val, ok := option_types_str_to_int_ifp(expanded)
	if !ok {
		return fallback
	}
	return val
}

// highlighters_resolve_face resolves a face spec against the context
// faces (port of context.faces()[spec]).
highlighters_resolve_face :: proc(ctx: ^Context, spec: Face_Registry_Spec) -> Face {
	return face_registry_resolve(context_faces(ctx), spec)
}

// highlighters_lookup_face resolves a face name against the context
// faces (port of context.faces()["name"]); unknown names yield Face{}.
highlighters_lookup_face :: proc(ctx: ^Context, name: string) -> Face {
	face, err := face_registry_lookup(context_faces(ctx), name, context.temp_allocator)
	if err != .None {
		return Face{}
	}
	return face
}

// highlighters_parse_face parses a face description, cloning into
// allocator (port of parse_face). The caller owns the result.
highlighters_parse_face :: proc(
	desc: string,
	allocator := context.allocator,
) -> (
	spec: Face_Registry_Spec,
	err: Highlighters_Error,
) {
	parsed, ferr := face_registry_parse(desc, allocator)
	if ferr != .None {
		return {}, .Invalid_Face
	}
	return parsed, .None
}

// NOTE: the C++ factories validate option types against the global scope
// at creation time. The Odin port deliberately skips that: other modules'
// tests init and tear down the global scope concurrently on the test
// thread pool, so any factory-time global read is a data race. Missing or
// mistyped options are handled at highlight time instead (the highlighter
// silently does nothing), which the C++ also degrades to after catching
// errors from option lookups.

// ---------------------------------------------------------------------------
// Line-specs and range-specs option maintenance
// ---------------------------------------------------------------------------

// highlighters_line_specs_postprocess sorts line-specs by line (port of
// option_list_postprocess for LineAndSpecList).
highlighters_line_specs_postprocess :: proc(list: ^[dynamic]Line_And_Spec) {
	option_manager_line_specs_sort(list)
}

// highlighters_range_specs_postprocess sorts range-specs by (first, last)
// (port of option_list_postprocess for RangeAndStringList).
highlighters_range_specs_postprocess :: proc(list: ^[dynamic]Range_And_String) {
	option_manager_range_specs_sort(list)
}

// highlighters_update_line_specs_ifn drops specs on removed lines and
// shifts the rest through buffer edits (port of update_line_specs_ifn).
highlighters_update_line_specs_ifn :: proc(buffer: ^Buffer, specs: ^Line_And_Spec_List) {
	if int(specs.prefix) == buffer_timestamp(buffer) {
		return
	}
	modifs := line_modification_compute(buffer, int(specs.prefix), context.temp_allocator)
	ins := 0
	for i := 0; i < len(specs.list); i += 1 {
		line := specs.list[i].line // 1-based user side
		// upper bound of modifs with old_line <= line - 1 (port of
		// the std::upper_bound over LineModification::old_line)
		lo, hi := 0, len(modifs)
		for lo < hi {
			mid := (lo + hi) / 2
			if modifs[mid].old_line <= line - 1 {
				lo = mid + 1
			} else {
				hi = mid
			}
		}
		if lo > 0 {
			prev := modifs[lo - 1]
			if line - 1 < prev.old_line + prev.num_removed {
				continue // line removed
			}
			line += line_modification_diff(prev)
		}
		specs.list[i].line = line
		if ins != i {
			specs.list[ins] = specs.list[i]
		}
		ins += 1
	}
	resize(&specs.list, ins)
	specs.prefix = uint(buffer_timestamp(buffer))
}

// highlighters_update_range_specs shifts range-specs through buffer edits
// (port of update_ranges for RangeAndStringList). Empty ranges (last <
// {0,0}) keep their marker; only first is updated.
highlighters_update_range_specs :: proc(buffer: ^Buffer, specs: ^Range_And_String_List) {
	timestamp := int(specs.prefix)
	if timestamp == buffer_timestamp(buffer) {
		return
	}
	sels := make([dynamic]Selection, len(specs.list), context.temp_allocator)
	for spec, i in specs.list {
		last := spec.range.last
		if option_manager_inclusive_range_empty(spec.range) {
			last = spec.range.first
		}
		sels[i] = Selection{
			basic = Basic_Selection{
				anchor = spec.range.first,
				cursor = coord_buffer_and_target(last),
			},
		}
	}
	changes_update_ranges(buffer, timestamp, sels[:])
	for &spec, i in specs.list {
		spec.range.first = sels[i].anchor
		if !option_manager_inclusive_range_empty(spec.range) {
			spec.range.last = sels[i].cursor.coord
		}
	}
	specs.prefix = uint(buffer_timestamp(buffer))
}

// highlighters_line_specs_update refreshes line-specs against the buffer
// (C++ option_update for LineAndSpecList in highlighters.cc).
highlighters_line_specs_update :: proc(opt: ^Line_And_Spec_List, ctx: ^Context) {
	highlighters_update_line_specs_ifn(context_buffer(ctx), opt)
}

// highlighters_range_specs_update refreshes range-specs against the
// buffer (C++ option_update for RangeAndStringList in highlighters.cc).
highlighters_range_specs_update :: proc(opt: ^Range_And_String_List, ctx: ^Context) {
	highlighters_update_range_specs(context_buffer(ctx), opt)
}

// highlighters_range_specs_add_from_strings parses strs as range-specs
// and merges them into the sorted list (port of option_add_from_strings
// for RangeAndString). Reports whether anything was added.
highlighters_range_specs_add_from_strings :: proc(
	list: ^[dynamic]Range_And_String,
	strs: []string,
	allocator := context.allocator,
) -> bool {
	parsed := make([dynamic]Range_And_String, 0, len(strs), context.temp_allocator)
	for s in strs {
		elem, err := option_manager_range_spec_from_string(s, allocator)
		if err != .None {
			for e in parsed {
				option_manager_range_spec_free(e, allocator)
			}
			return false
		}
		append(&parsed, elem)
	}
	if len(parsed) == 0 {
		return false
	}
	middle := len(list^)
	append(list, ..parsed[:])
	slice.sort_by(list[middle:], option_manager_range_spec_less)
	// inplace merge of the two sorted runs
	merged := make([dynamic]Range_And_String, 0, len(list^), context.temp_allocator)
	i, j := 0, middle
	for i < middle && j < len(list^) {
		if option_manager_range_spec_less(list[j], list[i]) {
			append(&merged, list[j])
			j += 1
		} else {
			append(&merged, list[i])
			i += 1
		}
	}
	for ; i < middle; i += 1 {
		append(&merged, list[i])
	}
	for ; j < len(list^); j += 1 {
		append(&merged, list[j])
	}
	copy(list[:], merged[:])
	return true
}

// ---------------------------------------------------------------------------
// Highlighters root and HighlighterGroup container
// ---------------------------------------------------------------------------

// highlighters_init_child initializes a child Highlighters root with a
// parent (port of the Highlighters(parent) constructor). The group map is
// owned, allocated with allocator.
highlighters_init_child :: proc(highlighters: ^Highlighters, parent: ^Highlighters, allocator := context.allocator) {
	highlighters.parent = parent
	highlighters.group.base = Highlighter{
		vtable = &highlighters_group_vtable,
		passes = highlighters_pass_all,
		data   = &highlighters.group,
	}
	highlighters.group.highlighters = make(map[string]^Highlighter, allocator)
	highlighters.group.order = make([dynamic]string, allocator)
	highlighters.group.allocator = allocator
}

// highlighters_destroy frees a Highlighters root's children and map (the
// root itself is owned by its scope/window).
highlighters_destroy :: proc(highlighters: ^Highlighters) {
	highlighters_group_destroy_contents(&highlighters.group)
}

// highlighters_highlight highlights through the parent chain, then the
// local group (port of Highlighters::highlight). Group ids shadow parent
// ids via the disabled list.
highlighters_highlight :: proc(
	highlighters: ^Highlighters,
	ctx: Highlight_Context,
	display_buffer: ^Display_Buffer,
	buffer_range: Buffer_Range,
) {
	disabled := make([dynamic]string, 0, len(ctx.disabled_ids) + 4, context.temp_allocator)
	append(&disabled, ..ctx.disabled_ids)
	highlighters_group_fill_unique_ids(&highlighters.group, &disabled)
	if highlighters.parent != nil {
		parent_ctx := ctx
		parent_ctx.disabled_ids = disabled[:]
		highlighters_highlight(highlighters.parent, parent_ctx, display_buffer, buffer_range)
	}
	highlighters_group_do_highlight(&highlighters.group, ctx, display_buffer, buffer_range)
}

// highlighters_compute_display_setup computes the display setup through
// the parent chain, then the local group (port of
// Highlighters::compute_display_setup).
highlighters_compute_display_setup :: proc(highlighters: ^Highlighters, ctx: Highlight_Context, setup: ^Display_Setup) {
	disabled := make([dynamic]string, 0, len(ctx.disabled_ids) + 4, context.temp_allocator)
	append(&disabled, ..ctx.disabled_ids)
	highlighters_group_fill_unique_ids(&highlighters.group, &disabled)
	if highlighters.parent != nil {
		parent_ctx := ctx
		parent_ctx.disabled_ids = disabled[:]
		highlighters_compute_display_setup(highlighters.parent, parent_ctx, setup)
	}
	highlighters_group_do_compute_display_setup(&highlighters.group, ctx, setup)
}

// highlighters_group_do_highlight runs every child (port of
// HighlighterGroup::do_highlight).
highlighters_group_do_highlight :: proc(
	group: ^Highlighter_Group,
	hctx: Highlight_Context,
	display_buffer: ^Display_Buffer,
	buffer_range: Buffer_Range,
) {
	for name in group.order {
		highlighter_highlight(group.highlighters[name], hctx, display_buffer, buffer_range)
	}
}

// highlighters_group_do_compute_display_setup runs every child's setup
// (port of HighlighterGroup::do_compute_display_setup).
highlighters_group_do_compute_display_setup :: proc(group: ^Highlighter_Group, hctx: Highlight_Context, setup: ^Display_Setup) {
	for name in group.order {
		highlighter_compute_display_setup(group.highlighters[name], hctx, setup)
	}
}

// highlighters_group_fill_unique_ids collects unique ids from every
// child (port of HighlighterGroup::fill_unique_ids). Appended ids borrow
// child memory (static strings).
highlighters_group_fill_unique_ids :: proc(group: ^Highlighter_Group, unique_ids: ^[dynamic]string) {
	for name in group.order {
		highlighter_fill_unique_ids(group.highlighters[name], unique_ids)
	}
}

// highlighters_group_add_child installs a child under name (port of
// HighlighterGroup::add_child). The group clones name and takes ownership
// of child on success; the child must use the group allocator.
highlighters_group_add_child :: proc(
	group: ^Highlighter_Group,
	name: string,
	child: ^Highlighter,
	override := false,
) -> Highlighters_Error {
	if (child.passes & group.base.passes) != child.passes {
		return .Invalid_Pass
	}
	if existing, ok := group.highlighters[name]; ok {
		if !override {
			return .Duplicate_Id
		}
		existing.vtable.destroy(existing.data, group.allocator)
		free(existing, group.allocator)
		group.highlighters[name] = child
		return .None
	}
	key := strings.clone(name, group.allocator)
	group.highlighters[key] = child
	append(&group.order, strings.clone(name, group.allocator))
	return .None
}

// highlighters_group_remove_child drops the named child (port of
// HighlighterGroup::remove_child).
highlighters_group_remove_child :: proc(group: ^Highlighter_Group, id: string) -> Highlighters_Error {
	// Map keys are owned clones; find the stored key for deletion.
	for key, child in group.highlighters {
		if key == id {
			child.vtable.destroy(child.data, group.allocator)
			free(child, group.allocator)
			delete_key(&group.highlighters, key)
			delete(key, group.allocator)
			for entry, i in group.order {
				if entry == id {
					delete(group.order[i], group.allocator)
					ordered_remove(&group.order, i)
					break
				}
			}
			return .None
		}
	}
	return .No_Such_Id
}

// highlighters_group_get_child resolves a slash-separated child path
// (port of HighlighterGroup::get_child). The result is borrowed.
highlighters_group_get_child :: proc(group: ^Highlighter_Group, path: string) -> (^Highlighter, Highlighters_Error) {
	sep := strings.index_byte(path, '/')
	id := path if sep < 0 else path[:sep]
	child, ok := group.highlighters[id]
	if !ok {
		return nil, .No_Such_Id
	}
	if sep < 0 {
		return child, .None
	}
	if !highlighter_has_children(child) {
		return nil, .No_Such_Id
	}
	if found := child.vtable.get_child(child.data, path[sep + 1:], context.allocator); found != nil {
		return found, .None
	}
	return nil, .No_Such_Id
}

// highlighters_group_complete_child completes a child path (port of
// HighlighterGroup::complete_child). Candidates are owned.
highlighters_group_complete_child :: proc(
	group: ^Highlighter_Group,
	path: string,
	cursor_pos: Units_ByteCount,
	complete_group: bool,
	allocator := context.allocator,
) -> Completions {
	if sep := strings.index_byte(path, '/'); sep >= 0 {
		offset := Units_ByteCount(sep + 1)
		child, err := highlighters_group_get_child(group, path[:sep])
		if err != .None {
			return Completions{}
		}
		return completion_offset_pos(
			child.vtable.complete_child(child.data, path[sep + 1:], cursor_pos - offset, complete_group, allocator),
			offset,
		)
	}
	names := make([dynamic]string, 0, len(group.highlighters), context.temp_allocator)
	for name in group.order {
		child := group.highlighters[name]
		if complete_group && !highlighter_has_children(child) {
			continue
		}
		if highlighter_has_children(child) {
			append(&names, strings.concatenate({name, "/"}, context.temp_allocator))
		} else {
			append(&names, name)
		}
	}
	flags := Completion_Flags{.Menu} if !complete_group else Completion_Flags{}
	return Completions{
		candidates = completion_complete(path, cursor_pos, names[:], allocator),
		flags      = flags,
	}
}

// highlighters_group_destroy_contents frees every child and the map (the
// group shell itself is owned by the caller).
highlighters_group_destroy_contents :: proc(group: ^Highlighter_Group) {
	for key, child in group.highlighters {
		if child.vtable != nil && child.vtable.destroy != nil {
			child.vtable.destroy(child.data, group.allocator)
		}
		delete(key, group.allocator)
		free(child, group.allocator)
	}
	for entry in group.order {
		delete(entry, group.allocator)
	}
	delete(group.order)
	delete(group.highlighters)
}

// highlighters_child_allocator returns the allocator a new child of
// parent must use: groups and regions destroy children with their own
// allocator, so factory allocation has to match (the add-highlighter
// command allocator may be short-lived). Unknown parents fall back to
// the given allocator.
highlighters_child_allocator :: proc(parent: ^Highlighter, fallback: mem.Allocator) -> mem.Allocator {
	if parent.vtable == &highlighters_group_vtable {
		return (cast(^Highlighter_Group)(parent.data)).allocator
	}
	if parent.vtable == &highlighters_regions_vtable {
		return (cast(^Highlighters_Regions_Data)(parent.data)).allocator
	}
	return fallback
}

// Vtable adapters below: data is the ^Highlighter_Group.

highlighters_group_vtable_do_highlight :: proc(
	data: rawptr,
	hctx: Highlight_Context,
	display_buffer: ^Display_Buffer,
	buffer_range: Buffer_Range,
) {
	highlighters_group_do_highlight(cast(^Highlighter_Group)data, hctx, display_buffer, buffer_range)
}

highlighters_group_vtable_do_compute_display_setup :: proc(data: rawptr, hctx: Highlight_Context, setup: ^Display_Setup) {
	highlighters_group_do_compute_display_setup(cast(^Highlighter_Group)data, hctx, setup)
}

highlighters_group_vtable_has_children :: proc(data: rawptr) -> bool {
	return true
}

highlighters_group_vtable_get_child :: proc(data: rawptr, path: string, allocator: mem.Allocator) -> ^Highlighter {
	child, _ := highlighters_group_get_child(cast(^Highlighter_Group)data, path)
	return child
}

highlighters_group_vtable_add_child :: proc(data: rawptr, name: string, child: ^Highlighter, override: bool) {
	// Unreachable with an error through validated callers; the direct
	// proc reports errors. On failure keep caller ownership by leaking
	// nothing: the child is left for the caller.
	_ = highlighters_group_add_child(cast(^Highlighter_Group)data, name, child, override)
}

highlighters_group_vtable_remove_child :: proc(data: rawptr, id: string) {
	_ = highlighters_group_remove_child(cast(^Highlighter_Group)data, id)
}

highlighters_group_vtable_complete_child :: proc(
	data: rawptr,
	path: string,
	cursor_pos: Units_ByteCount,
	complete_group: bool,
	allocator: mem.Allocator,
) -> Completions {
	return highlighters_group_complete_child(cast(^Highlighter_Group)data, path, cursor_pos, complete_group, allocator)
}

highlighters_group_vtable_fill_unique_ids :: proc(data: rawptr, unique_ids: ^[dynamic]string) {
	highlighters_group_fill_unique_ids(cast(^Highlighter_Group)data, unique_ids)
}

highlighters_group_vtable_destroy :: proc(data: rawptr, allocator: mem.Allocator) {
	highlighters_group_destroy_contents(cast(^Highlighter_Group)data)
}

// highlighters_group_vtable dispatches heap groups (factory "group") and
// inline Highlighters roots. Read-only after load.
highlighters_group_vtable := Highlighter_VTable{
	do_highlight             = highlighters_group_vtable_do_highlight,
	do_compute_display_setup = highlighters_group_vtable_do_compute_display_setup,
	has_children             = highlighters_group_vtable_has_children,
	get_child                = highlighters_group_vtable_get_child,
	add_child                = highlighters_group_vtable_add_child,
	remove_child             = highlighters_group_vtable_remove_child,
	complete_child           = highlighters_group_vtable_complete_child,
	fill_unique_ids          = highlighters_group_vtable_fill_unique_ids,
	destroy                  = highlighters_group_vtable_destroy,
}

// Highlighters_Shared_Instance is the SharedHighlighters singleton store
// (port of SharedHighlighters in highlighter_group.hh).
Highlighters_Shared_Instance: Highlighters

// highlighters_shared_has_instance reports whether the singleton was
// initialized (port of Singleton::has_instance).
highlighters_shared_has_instance := false

// highlighters_shared_init initializes the shared singleton.
highlighters_shared_init :: proc(allocator := context.allocator) {
	highlighters_init_child(&Highlighters_Shared_Instance, nil, allocator)
	highlighters_shared_has_instance = true
}

// highlighters_shared_instance returns the shared singleton (port of
// Singleton::instance).
highlighters_shared_instance :: proc() -> ^Highlighters {
	assert(highlighters_shared_has_instance)
	return &Highlighters_Shared_Instance
}

// highlighters_shared_destroy releases the shared singleton.
highlighters_shared_destroy :: proc() {
	highlighters_destroy(&Highlighters_Shared_Instance)
	highlighters_shared_has_instance = false
}

// ---------------------------------------------------------------------------
// Display range helpers
// ---------------------------------------------------------------------------

// highlighters_apply_face merges face onto an atom (port of apply_face).
highlighters_apply_face :: proc(atom: ^Display_Atom, face: Face) {
	atom.face = face_merge(atom.face, face)
}

// highlighters_highlight_range applies face to [begin, end) of the
// display buffer (port of highlight_range in highlighters.cc).
highlighters_highlight_range :: proc(
	display_buffer: ^Display_Buffer,
	begin, end: Coord_Buffer,
	skip_replaced: bool,
	face: Face,
) {
	// Tolerate begin > end as that can be triggered by wrong encodings.
	if coord_compare(begin, end) >= 0 ||
	   coord_compare(end, display_buffer.range.begin) <= 0 ||
	   coord_compare(begin, display_buffer.range.end) >= 0 {
		return
	}
	for &line in display_buffer.lines {
		if coord_compare(line.range.end, begin) <= 0 || coord_compare(end, line.range.begin) < 0 {
			continue
		}
		i := 0
		for i < len(line.atoms) {
			atom := &line.atoms[i]
			is_replaced := atom.type == .Replaced_Range
			if !display_buffer_atom_has_range(atom^) ||
			   (skip_replaced && is_replaced) ||
			   coord_compare(end, atom.range.begin) <= 0 ||
			   coord_compare(begin, atom.range.end) >= 0 {
				i += 1
				continue
			}
			if !is_replaced && coord_compare(begin, atom.range.begin) > 0 {
				i = display_buffer_line_split_coord(&line, i, begin) + 1
			}
			atom = &line.atoms[i]
			if !is_replaced && coord_compare(end, atom.range.end) < 0 {
				i = display_buffer_line_split_coord(&line, i, end)
				highlighters_apply_face(&line.atoms[i], face)
				i += 2 // skip the highlighted atom and its tail past end
			} else {
				highlighters_apply_face(&line.atoms[i], face)
				i += 1
			}
		}
	}
}

// highlighters_replace_range_erase removes [begin, end) from the display
// buffer, merging the touched lines (port of the erase half of
// replace_range in highlighters.cc). Returns the insertion point for the
// replacement atoms, or ok=false when the range misses the buffer.
highlighters_replace_range_erase :: proc(
	display_buffer: ^Display_Buffer,
	begin, end: Coord_Buffer,
) -> (
	line: int,
	atom: int,
	ok: bool,
) {
	// Tolerate begin > end as that can be triggered by wrong encodings.
	if coord_compare(begin, end) > 0 ||
	   coord_compare(end, display_buffer.range.begin) < 0 ||
	   coord_compare(begin, display_buffer.range.end) > 0 {
		return 0, 0, false
	}
	lines := &display_buffer.lines
	first := len(lines^)
	for i in 0 ..< len(lines^) {
		if coord_compare(lines[i].range.end, begin) >= 0 {
			first = i
			break
		}
	}
	if first == len(lines^) {
		return 0, 0, false
	}
	first_atom := display_buffer_line_split_at(&lines[first], begin)
	last := len(lines^)
	for i := first; i < len(lines^); i += 1 {
		if coord_compare(lines[i].range.end, end) >= 0 {
			last = i
			break
		}
	}
	if first == last {
		end_atom := display_buffer_line_split_at(&lines[first], end)
		display_buffer_line_erase(&lines[first], first_atom, end_atom)
		return first, first_atom, true
	}
	display_buffer_line_erase(&lines[first], first_atom, len(lines[first].atoms))
	if last != len(lines^) {
		end_atom := display_buffer_line_split_at(&lines[last], end)
		display_buffer_line_erase(&lines[last], 0, end_atom)
		moved := make([dynamic]Display_Atom, len(lines[last].atoms), context.temp_allocator)
		copy(moved[:], lines[last].atoms[:])
		display_buffer_line_insert_many(&lines[first], first_atom, moved[:])
		last += 1
	}
	for i := first + 1; i < last; i += 1 {
		display_buffer_line_destroy(&lines[i])
	}
	copy(lines[first + 1:], lines[last:])
	resize(lines, len(lines^) - (last - first - 1))
	return first, first_atom, true
}

// ---------------------------------------------------------------------------
// Concrete leaf highlighters (shared vtable over a payload union)
// ---------------------------------------------------------------------------

// Highlighters_Fill fills the range with a face (port of the fill lambda).
Highlighters_Fill :: struct {
	spec: Face_Registry_Spec, // owned
}

// Highlighters_Capture_Face pairs a capture index with a face spec.
Highlighters_Capture_Face :: struct {
	capture: int,
	spec:    Face_Registry_Spec, // owned
}

// Highlighters_Regex_Data is the RegexHighlighter state (without the
// buffer-side match cache: matches are recomputed per redraw).
Highlighters_Regex_Data :: struct {
	regex:     Regex, // owned
	faces:     [dynamic]Highlighters_Capture_Face, // owned, sorted, [0] is capture 0
	has_regex: bool,
	allocator: mem.Allocator,
}

// Highlighters_Named_Face pairs a capture name with a face spec.
Highlighters_Named_Face :: struct {
	name: string, // owned
	spec: Face_Registry_Spec, // owned
}

// Highlighters_Dynamic_Regex re-resolves its regex every redraw (port of
// DynamicRegexHighlighter). The C++ fast path that reads a lone %opt{}
// directly is folded into expansion: expanding the expression yields the
// same pattern, and avoids factory-time global scope reads (see above).
Highlighters_Dynamic_Regex :: struct {
	source:       string, // owned expression
	faces:        [dynamic]Highlighters_Named_Face, // owned
	last_pattern: string, // owned
	inner:        Highlighters_Regex_Data, // owned
	allocator:    mem.Allocator,
}

// Highlighters_Line highlights one evaluated line (port of the line lambda).
Highlighters_Line :: struct {
	expr: string, // owned
	spec: Face_Registry_Spec, // owned
}

// Highlighters_Column highlights one evaluated column (port of the column
// lambda).
Highlighters_Column :: struct {
	expr:                string, // owned
	spec:                Face_Registry_Spec, // owned
	highlight_non_blank: bool,
	ruler:               string, // owned
}

// Highlighters_Wrap wraps lines to a width (port of WrapHighlighter).
Highlighters_Wrap :: struct {
	max_width:      Coord_Column,
	word_wrap:      bool,
	preserve_indent: bool,
	marker:         string, // owned
}

// Highlighters_Tabulation expands tabs (port of TabulationHighlighter).
Highlighters_Tabulation :: struct{}

// Highlighters_Show_Whitespace renders whitespace visibly (port of
// ShowWhitespacesHighlighter).
Highlighters_Show_Whitespace :: struct {
	tab:          string, // owned
	tabpad:       string, // owned
	spc:          string, // owned
	lf:           string, // owned
	nbsp:         string, // owned
	indent:       string, // owned
	only_trailing: bool,
}

// Highlighters_Line_Numbers shows line numbers (port of
// LineNumbersHighlighter).
Highlighters_Line_Numbers :: struct {
	relative:         bool,
	zero_cursor_line: bool,
	hl_cursor_line:   bool,
	separator:        string, // owned
	cursor_separator: string, // owned
	min_digits:       int,
}

// Highlighters_Matching highlights the match of the char under the cursor
// (port of show_matching_char).
Highlighters_Matching :: struct {
	match_prev: bool,
}

// Highlighters_Selections highlights selections and cursors (port of
// highlight_selections).
Highlighters_Selections :: struct{}

// Highlighters_Unprintable replaces unprintables with U+FFFD (port of
// expand_unprintable).
Highlighters_Unprintable :: struct{}

// Highlighters_Flag_Lines shows line flags (port of FlagLinesHighlighter).
Highlighters_Flag_Lines :: struct {
	option_name:  string, // owned
	default_face: string, // owned
	after:        bool,
}

// Highlighters_Ranges applies faces from a range-specs option (port of
// RangesHighlighter).
Highlighters_Ranges :: struct {
	option_name: string, // owned
}

// Highlighters_Replace_Ranges replaces ranges with display lines (port of
// ReplaceRangesHighlighter).
Highlighters_Replace_Ranges :: struct {
	option_name: string, // owned
}

// Highlighters_Reference delegates to a shared highlighter (port of
// ReferenceHighlighter).
Highlighters_Reference :: struct {
	name: string, // owned
}

// Highlighters_Payload is every leaf highlighter state.
Highlighters_Payload :: union {
	Highlighters_Fill,
	Highlighters_Regex_Data,
	Highlighters_Dynamic_Regex,
	Highlighters_Line,
	Highlighters_Column,
	Highlighters_Wrap,
	Highlighters_Tabulation,
	Highlighters_Show_Whitespace,
	Highlighters_Line_Numbers,
	Highlighters_Matching,
	Highlighters_Selections,
	Highlighters_Unprintable,
	Highlighters_Flag_Lines,
	Highlighters_Ranges,
	Highlighters_Replace_Ranges,
	Highlighters_Reference,
}

// Highlighters_Any is the shared vtable's concrete data.
Highlighters_Any :: struct {
	payload:   Highlighters_Payload,
	allocator: mem.Allocator,
}

// highlighters_any_make heap-allocates a leaf highlighter (owned; free
// with highlighter_destroy using the same allocator).
highlighters_any_make :: proc(
	passes: Highlight_Pass,
	payload: Highlighters_Payload,
	allocator := context.allocator,
) -> ^Highlighter {
	data := new(Highlighters_Any, allocator)
	data.payload = payload
	data.allocator = allocator
	return highlighter_make_owned(passes, &highlighters_any_vtable, data, allocator)
}

highlighters_any_do_highlight :: proc(
	data: rawptr,
	hctx: Highlight_Context,
	display_buffer: ^Display_Buffer,
	buffer_range: Buffer_Range,
) {
	any := cast(^Highlighters_Any)data
	switch &payload in any.payload {
	case Highlighters_Fill:
		highlighters_fill_apply(&payload, hctx, display_buffer, buffer_range)
	case Highlighters_Regex_Data:
		highlighters_regex_apply(&payload, hctx, display_buffer, buffer_range)
	case Highlighters_Dynamic_Regex:
		highlighters_dynamic_regex_apply(&payload, hctx, display_buffer, buffer_range)
	case Highlighters_Line:
		highlighters_line_apply(&payload, hctx, display_buffer, buffer_range)
	case Highlighters_Column:
		highlighters_column_apply(&payload, hctx, display_buffer, buffer_range)
	case Highlighters_Wrap:
		highlighters_wrap_apply(&payload, hctx, display_buffer, buffer_range)
	case Highlighters_Tabulation:
		highlighters_tabulation_apply(hctx, display_buffer, buffer_range)
	case Highlighters_Show_Whitespace:
		highlighters_show_whitespace_apply(&payload, hctx, display_buffer, buffer_range)
	case Highlighters_Line_Numbers:
		highlighters_line_numbers_apply(&payload, hctx, display_buffer, buffer_range)
	case Highlighters_Matching:
		highlighters_matching_apply(&payload, hctx, display_buffer, buffer_range)
	case Highlighters_Selections:
		highlighters_selections_apply(hctx, display_buffer, buffer_range)
	case Highlighters_Unprintable:
		highlighters_unprintable_apply(hctx, display_buffer, buffer_range)
	case Highlighters_Flag_Lines:
		highlighters_flag_lines_apply(&payload, hctx, display_buffer, buffer_range)
	case Highlighters_Ranges:
		highlighters_ranges_apply(&payload, hctx, display_buffer, buffer_range)
	case Highlighters_Replace_Ranges:
		highlighters_replace_ranges_apply(&payload, hctx, display_buffer, buffer_range)
	case Highlighters_Reference:
		highlighters_reference_apply(&payload, hctx, display_buffer, buffer_range)
	}
}

highlighters_any_do_compute_display_setup :: proc(data: rawptr, hctx: Highlight_Context, setup: ^Display_Setup) {
	any := cast(^Highlighters_Any)data
	switch &payload in any.payload {
	case Highlighters_Wrap:
		highlighters_wrap_setup(&payload, hctx, setup)
	case Highlighters_Tabulation:
		highlighters_tabulation_setup(hctx, setup)
	case Highlighters_Line_Numbers:
		highlighters_line_numbers_setup(&payload, hctx, setup)
	case Highlighters_Flag_Lines:
		highlighters_flag_lines_setup(&payload, hctx, setup)
	case Highlighters_Replace_Ranges:
		highlighters_replace_ranges_setup(&payload, hctx, setup)
	case Highlighters_Reference:
		highlighters_reference_setup(&payload, hctx, setup)
	case Highlighters_Fill:
	case Highlighters_Regex_Data:
	case Highlighters_Dynamic_Regex:
	case Highlighters_Line:
	case Highlighters_Column:
	case Highlighters_Show_Whitespace:
	case Highlighters_Matching:
	case Highlighters_Selections:
	case Highlighters_Unprintable:
	case Highlighters_Ranges:
		// No display setup contribution.
	}
}

highlighters_any_fill_unique_ids :: proc(data: rawptr, unique_ids: ^[dynamic]string) {
	any := cast(^Highlighters_Any)data
	#partial switch _ in any.payload {
	case Highlighters_Wrap:
		append(unique_ids, "wrap")
	case Highlighters_Line_Numbers:
		append(unique_ids, "line-numbers")
	}
}

highlighters_any_destroy :: proc(data: rawptr, allocator: mem.Allocator) {
	any := cast(^Highlighters_Any)data
	highlighters_payload_destroy(&any.payload, any.allocator)
	free(any, allocator)
}

// highlighters_any_vtable dispatches all leaf highlighters. Read-only
// after load.
highlighters_any_vtable := Highlighter_VTable{
	do_highlight             = highlighters_any_do_highlight,
	do_compute_display_setup = highlighters_any_do_compute_display_setup,
	has_children             = highlighter_leaf_has_children,
	get_child                = highlighter_leaf_get_child,
	add_child                = highlighter_leaf_add_child,
	remove_child             = highlighter_leaf_remove_child,
	complete_child           = highlighter_leaf_complete_child,
	fill_unique_ids          = highlighters_any_fill_unique_ids,
	destroy                  = highlighters_any_destroy,
}

// highlighters_spec_destroy frees a face spec's owned base name.
highlighters_spec_destroy :: proc(spec: ^Face_Registry_Spec, allocator: mem.Allocator) {
	face_registry_spec_destroy(spec, allocator)
}

// highlighters_regex_data_destroy frees regex state (not the shell).
highlighters_regex_data_destroy :: proc(r: ^Highlighters_Regex_Data) {
	if r.has_regex {
		regex_destroy(&r.regex)
		r.has_regex = false
	}
	for &cf in r.faces {
		highlighters_spec_destroy(&cf.spec, r.allocator)
	}
	delete(r.faces)
}

highlighters_payload_destroy :: proc(payload: ^Highlighters_Payload, allocator: mem.Allocator) {
	switch &p in payload {
	case Highlighters_Fill:
		highlighters_spec_destroy(&p.spec, allocator)
	case Highlighters_Regex_Data:
		highlighters_regex_data_destroy(&p)
	case Highlighters_Dynamic_Regex:
		for &f in p.faces {
			delete(f.name, allocator)
			highlighters_spec_destroy(&f.spec, allocator)
		}
		delete(p.faces)
		delete(p.source, allocator)
		delete(p.last_pattern, allocator)
		highlighters_regex_data_destroy(&p.inner)
	case Highlighters_Line:
		delete(p.expr, allocator)
		highlighters_spec_destroy(&p.spec, allocator)
	case Highlighters_Column:
		delete(p.expr, allocator)
		highlighters_spec_destroy(&p.spec, allocator)
		delete(p.ruler, allocator)
	case Highlighters_Wrap:
		delete(p.marker, allocator)
	case Highlighters_Tabulation:
	case Highlighters_Show_Whitespace:
		delete(p.tab, allocator)
		delete(p.tabpad, allocator)
		delete(p.spc, allocator)
		delete(p.lf, allocator)
		delete(p.nbsp, allocator)
		delete(p.indent, allocator)
	case Highlighters_Line_Numbers:
		delete(p.separator, allocator)
		delete(p.cursor_separator, allocator)
	case Highlighters_Matching:
	case Highlighters_Selections:
	case Highlighters_Unprintable:
	case Highlighters_Flag_Lines:
		delete(p.option_name, allocator)
		delete(p.default_face, allocator)
	case Highlighters_Ranges:
		delete(p.option_name, allocator)
	case Highlighters_Replace_Ranges:
		delete(p.option_name, allocator)
	case Highlighters_Reference:
		delete(p.name, allocator)
	}
}

// ---------------------------------------------------------------------------
// fill, regex, dynregex, line, column
// ---------------------------------------------------------------------------

highlighters_fill_apply :: proc(
	fill: ^Highlighters_Fill,
	hctx: Highlight_Context,
	display_buffer: ^Display_Buffer,
	buffer_range: Buffer_Range,
) {
	highlighters_highlight_range(
		display_buffer,
		buffer_range.begin, buffer_range.end,
		false,
		highlighters_resolve_face(hctx.ctx, fill.spec),
	)
}

// highlighters_regex_ensure_capture_0 sorts faces by capture and prepends
// an empty capture-0 face when missing (port of
// ensure_first_face_is_capture_0).
highlighters_regex_ensure_capture_0 :: proc(faces: ^[dynamic]Highlighters_Capture_Face) {
	if len(faces^) == 0 {
		return
	}
	slice.sort_by(faces[:], proc(a, b: Highlighters_Capture_Face) -> bool { return a.capture < b.capture })
	if faces[0].capture != 0 {
		inject_at(faces, 0, Highlighters_Capture_Face{capture = 0})
	}
}

// highlighters_regex_compile builds owned regex state from a pattern and
// face list. Faces are already-owned entries (moved in).
highlighters_regex_compile :: proc(
	pattern: string,
	faces: [dynamic]Highlighters_Capture_Face,
	allocator := context.allocator,
) -> (
	data: Highlighters_Regex_Data,
	err: Highlighters_Error,
) {
	data.allocator = allocator
	data.faces = faces
	highlighters_regex_ensure_capture_0(&data.faces)
	re, msg, rerr := regex_make(pattern, {.Optimize}, allocator)
	if rerr != .None {
		delete(msg, allocator)
		highlighters_regex_data_destroy(&data)
		return {}, .Invalid_Regex
	}
	data.regex = re
	data.has_regex = true
	return data, .None
}

highlighters_regex_apply :: proc(
	r: ^Highlighters_Regex_Data,
	hctx: Highlight_Context,
	display_buffer: ^Display_Buffer,
	buffer_range: Buffer_Range,
) {
	if !r.has_regex {
		return
	}
	overlaps := coord_compare(display_buffer.range.begin, buffer_range.end) < 0 &&
		coord_compare(buffer_range.begin, display_buffer.range.end) < 0
	if !overlaps {
		return
	}
	faces := make([dynamic]Face, len(r.faces), context.temp_allocator)
	for cf, i in r.faces {
		faces[i] = highlighters_resolve_face(hctx.ctx, cf.spec)
	}
	buffer := context_buffer(hctx.ctx)
	subject := buffer_string(buffer, buffer_range.begin, buffer_range.end, context.temp_allocator)
	base := selectors_offset_of_coord(buffer, buffer_range.begin)
	flags := selectors_match_flags(buffer, buffer_range.begin, buffer_range.end)
	it := regex_iterator_make(subject, 0, len(subject), &r.regex, flags, false, context.temp_allocator)
	for regex_iterator_next(&it) {
		for cf, i in r.faces {
			if faces[i] == (Face{}) {
				continue
			}
			sub := regex_match_results_get(&it.results, cf.capture)
			if !sub.matched {
				continue
			}
			begin := selectors_coord_of_offset(buffer, base + sub.begin)
			end := selectors_coord_of_offset(buffer, base + sub.end)
			highlighters_highlight_range(display_buffer, begin, end, false, faces[i])
		}
	}
}

highlighters_dynamic_regex_apply :: proc(
	d: ^Highlighters_Dynamic_Regex,
	hctx: Highlight_Context,
	display_buffer: ^Display_Buffer,
	buffer_range: Buffer_Range,
) {
	pattern := highlighters_dynamic_regex_pattern(d, hctx)
	if pattern != d.last_pattern {
		highlighters_dynamic_regex_reset(d, pattern)
	}
	if !d.inner.has_regex || len(d.inner.faces) == 0 {
		return
	}
	highlighters_regex_apply(&d.inner, hctx, display_buffer, buffer_range)
}

// highlighters_dynamic_regex_pattern evaluates the regex source. The
// result is scratch (temp allocator).
highlighters_dynamic_regex_pattern :: proc(d: ^Highlighters_Dynamic_Regex, hctx: Highlight_Context) -> string {
	return highlighters_expand(d.source, hctx.ctx, context.temp_allocator)
}

// highlighters_dynamic_regex_reset recompiles the inner highlighter for a
// new pattern (port of the reset branch of DynamicRegexHighlighter).
highlighters_dynamic_regex_reset :: proc(d: ^Highlighters_Dynamic_Regex, pattern: string) {
	if d.inner.has_regex {
		regex_destroy(&d.inner.regex)
		d.inner.has_regex = false
	}
	for &cf in d.inner.faces {
		highlighters_spec_destroy(&cf.spec, d.allocator)
	}
	clear(&d.inner.faces)
	delete(d.last_pattern, d.allocator)
	d.last_pattern = strings.clone(pattern, d.allocator)
	if len(pattern) == 0 {
		return
	}
	re, msg, rerr := regex_make(pattern, {.Optimize}, d.allocator)
	if rerr != .None {
		delete(msg, d.allocator)
		return
	}
	ok := true
	for &named in d.faces {
		capture, is_int := option_types_str_to_int_ifp(named.name)
		if !is_int {
			capture = regex_named_capture_index(&re, named.name)
		}
		if capture < 0 {
			ok = false
			break
		}
		spec := Face_Registry_Spec{face = named.spec.face, base = strings.clone(named.spec.base, d.allocator)}
		append(&d.inner.faces, Highlighters_Capture_Face{capture = capture, spec = spec})
	}
	if !ok {
		for &cf in d.inner.faces {
			highlighters_spec_destroy(&cf.spec, d.allocator)
		}
		clear(&d.inner.faces)
		regex_destroy(&re)
		return
	}
	d.inner.regex = re
	d.inner.has_regex = true
	highlighters_regex_ensure_capture_0(&d.inner.faces)
}

highlighters_line_apply :: proc(
	l: ^Highlighters_Line,
	hctx: Highlight_Context,
	display_buffer: ^Display_Buffer,
	buffer_range: Buffer_Range,
) {
	_ = buffer_range
	line := Coord_Line(highlighters_expand_int(l.expr, hctx.ctx, 0) - 1)
	if line < 0 {
		return
	}
	found := -1
	for &dl, i in display_buffer.lines {
		if dl.range.begin.line == line {
			found = i
			break
		}
	}
	if found < 0 {
		return
	}
	face := highlighters_resolve_face(hctx.ctx, l.spec)
	column := Coord_Column(0)
	dl := &display_buffer.lines[found]
	for &atom in dl.atoms {
		column += display_buffer_atom_length(atom)
		if display_buffer_atom_has_range(atom) && atom.range.begin.line != line {
			break
		}
		highlighters_apply_face(&atom, face)
	}
	remaining := window_dimensions(context_window(hctx.ctx)).column - column
	if remaining > 0 {
		pad := strings.repeat(" ", int(remaining), context.temp_allocator)
		display_buffer_line_push_back(dl, display_buffer_atom_text(pad, face))
	}
}

highlighters_column_apply :: proc(
	c: ^Highlighters_Column,
	hctx: Highlight_Context,
	display_buffer: ^Display_Buffer,
	buffer_range: Buffer_Range,
) {
	_ = buffer_range
	column := Coord_Column(highlighters_expand_int(c.expr, hctx.ctx, 0) - 1)
	if column < 0 {
		return
	}
	face := highlighters_resolve_face(hctx.ctx, c.spec)
	width := window_dimensions(context_window(hctx.ctx)).column
	if column < hctx.setup.first_column || column >= hctx.setup.first_column + width {
		return
	}
	column += hctx.setup.widget_columns - hctx.setup.first_column
	for &dl in display_buffer.lines {
		remaining := column
		found := false
		i := 0
		for i < len(dl.atoms) {
			atom_len := display_buffer_atom_length(dl.atoms[i])
			if remaining < atom_len {
				if remaining > 0 {
					i = display_buffer_line_split_col(&dl, i, remaining) + 1
				}
				if display_buffer_atom_length(dl.atoms[i]) > 1 {
					i = display_buffer_line_split_col(&dl, i, 1)
				}
				if c.highlight_non_blank {
					highlighters_apply_face(&dl.atoms[i], face)
				} else {
					content := display_buffer_atom_content(dl.atoms[i])
					pos := 0
					if len(content) > 0 && unicode_is_blank(utf8_read_codepoint(content, &pos)) {
						display_buffer_atom_replace_text(&dl.atoms[i], c.ruler)
						highlighters_apply_face(&dl.atoms[i], face)
					}
				}
				found = true
				break
			}
			remaining -= atom_len
			i += 1
		}
		if found {
			continue
		}
		if remaining > 0 {
			pad := strings.repeat(" ", int(remaining), context.temp_allocator)
			display_buffer_line_push_back(&dl, display_buffer_atom_text(pad, Face{}))
		}
		display_buffer_line_push_back(&dl, display_buffer_atom_text(c.ruler, face))
	}
}

// ---------------------------------------------------------------------------
// wrap, tabulation, show-whitespaces
// ---------------------------------------------------------------------------

// Highlighters_Wrap_Split is a candidate wrap point (port of
// WrapHighlighter::SplitPos).
Highlighters_Wrap_Split :: struct {
	atom:   int,
	byte:   int,
	column: Coord_Column,
}

highlighters_wrap_apply :: proc(
	w: ^Highlighters_Wrap,
	hctx: Highlight_Context,
	display_buffer: ^Display_Buffer,
	buffer_range: Buffer_Range,
) {
	_ = buffer_range
	if highlighters_disabled(hctx.disabled_ids, "wrap") {
		return
	}
	wrap_column := min(w.max_width, window_dimensions(context_window(hctx.ctx)).column - hctx.setup.widget_columns)
	if wrap_column <= 0 {
		return
	}
	buffer := context_buffer(hctx.ctx)
	tabstop, ok := highlighters_option_int(hctx.ctx, "tabstop")
	if !ok {
		return
	}
	marker_len := highlighters_wrap_capped(Coord_Column(string_utils_column_length(w.marker)), wrap_column)
	face_marker := highlighters_lookup_face(hctx.ctx, "WrapMarker")
	i := 0
	for i < len(display_buffer.lines) {
		line := &display_buffer.lines[i]
		indent := Coord_Column(0)
		if w.preserve_indent {
			indent = highlighters_wrap_capped(highlighters_wrap_line_indent(buffer, tabstop, line.range.begin.line), wrap_column)
		}
		prefix_len := max(marker_len, indent)
		pos := Highlighters_Wrap_Split{}
		for highlighters_wrap_next_split(w, line, &pos, wrap_column, prefix_len) {
			if pos.byte > 0 {
				atom_begin := line.atoms[pos.atom].range.begin
				if line.atoms[pos.atom].type == .Range {
					split_at := Coord_Buffer{atom_begin.line, atom_begin.column + Coord_Byte(pos.byte)}
					pos.atom = display_buffer_line_split_coord(line, pos.atom, split_at) + 1
				} else {
					// The C++ asserts Range here; split text by columns instead.
					content := display_buffer_atom_content(line.atoms[pos.atom])
					cols := Coord_Column(string_utils_column_length(content[:pos.byte]))
					if cols <= 0 {
						pos.atom += 1
					} else if cols < display_buffer_atom_length(line.atoms[pos.atom]) {
						pos.atom = display_buffer_line_split_col(line, pos.atom, cols) + 1
					}
				}
			}
			coord := line.atoms[pos.atom].range.begin
			if !display_buffer_atom_has_range(line.atoms[pos.atom]) {
				coord = line.range.end
			}
			new_line := display_buffer_line_extract(line, pos.atom, len(line.atoms))
			next_atom := 0
			if marker_len != 0 {
				display_buffer_line_insert(&new_line, next_atom, display_buffer_atom_text(w.marker, face_marker))
				next_atom += 1
			}
			if indent > marker_len {
				display_buffer_line_insert(
					&new_line,
					next_atom,
					display_buffer_atom_range(buffer, Buffer_Range{coord, coord}, Face{}),
				)
				pad := strings.repeat(" ", int(indent - marker_len), context.temp_allocator)
				display_buffer_atom_replace_text(&new_line.atoms[next_atom], pad)
				next_atom += 1
			}
			inject_at(&display_buffer.lines, i + 1, new_line)
			i += 1
			line = &display_buffer.lines[i]
			pos = Highlighters_Wrap_Split{atom = next_atom, column = max(marker_len, indent)}
		}
		i += 1
	}
}

highlighters_wrap_setup :: proc(w: ^Highlighters_Wrap, hctx: Highlight_Context, setup: ^Display_Setup) {
	if highlighters_disabled(hctx.disabled_ids, "wrap") {
		return
	}
	wrap_column := min(w.max_width, window_dimensions(context_window(hctx.ctx)).column - setup.widget_columns)
	if wrap_column <= 0 {
		return
	}
	// Disable horizontal scrolling when using a WrapHighlighter.
	setup.first_column = 0
	setup.scroll_offset.column = 0
}

highlighters_wrap_capped :: proc(val, max: Coord_Column) -> Coord_Column {
	return val if val < max else 0
}

highlighters_wrap_line_indent :: proc(buffer: ^Buffer, tabstop: int, line: Coord_Line) -> Coord_Column {
	l := buffer.lines[int(line)]
	col := 0
	for col < len(l) && unicode_is_horizontal_blank(rune(l[col])) {
		col += 1
	}
	return highlighters_get_column(buffer, tabstop, Coord_Buffer{line, Coord_Byte(col)})
}

highlighters_wrap_is_word :: proc(cp: rune, big: bool) -> bool {
	extra := [1]rune{'_'}
	kind := Unicode_Word_Type.Word if !big else Unicode_Word_Type.Big_Word
	return unicode_is_word(cp, extra[:], kind)
}

highlighters_wrap_next_split :: proc(
	w: ^Highlighters_Wrap,
	line: ^Display_Line,
	pos: ^Highlighters_Wrap_Split,
	wrap_column, prefix_len: Coord_Column,
) -> bool {
	last_word := Highlighters_Wrap_Split{}
	last_WORD := Highlighters_Wrap_Split{}
	update_boundaries := proc(w: ^Highlighters_Wrap, cp: rune, pos: ^Highlighters_Wrap_Split, last_word, last_WORD: ^Highlighters_Wrap_Split) {
		if w.word_wrap && !highlighters_wrap_is_word(cp, false) {
			last_word^ = pos^
		}
		if w.word_wrap && !highlighters_wrap_is_word(cp, true) {
			last_WORD^ = pos^
		}
	}
	if pos.atom < len(line.atoms) &&
	   line.atoms[pos.atom].type != .Range &&
	   pos.column + display_buffer_atom_length(line.atoms[pos.atom]) >= wrap_column {
		pos.atom += 1
		return pos.atom != len(line.atoms)
	}
	for pos.atom < len(line.atoms) && pos.column < wrap_column {
		content := display_buffer_atom_content(line.atoms[pos.atom])
		off := pos.byte
		if off >= len(content) {
			pos.atom += 1
			pos.byte = 0
			if pos.atom < len(line.atoms) &&
			   line.atoms[pos.atom].type != .Range &&
			   pos.column + display_buffer_atom_length(line.atoms[pos.atom]) >= wrap_column {
				return true
			}
			last_word = pos^
			last_WORD = pos^
			continue
		}
		cp := utf8_read_codepoint(content, &off)
		width := Coord_Column(unicode_codepoint_width(cp))
		if pos.column + width > wrap_column {
			update_boundaries(w, cp, pos, &last_word, &last_WORD)
			break
		}
		pos.column += width
		pos.byte = off
		update_boundaries(w, cp, pos, &last_word, &last_WORD)
		if off == len(content) {
			pos.atom += 1
			pos.byte = 0
			if pos.atom < len(line.atoms) &&
			   line.atoms[pos.atom].type != .Range &&
			   pos.column + display_buffer_atom_length(line.atoms[pos.atom]) >= wrap_column {
				return true
			}
			// Thanks to the pass ordering, atom boundaries should
			// always be reasonable word split points.
			last_word = pos^
			last_WORD = pos^
		}
	}
	if pos.atom == len(line.atoms) {
		return false
	}
	if w.word_wrap {
		content := display_buffer_atom_content(line.atoms[pos.atom])
		if pos.byte < len(content) {
			find_split := proc(
				pos: ^Highlighters_Wrap_Split,
				start: Highlighters_Wrap_Split,
				wrap_column, prefix_len: Coord_Column,
				content: string,
				big: bool,
			) -> bool {
				if start.column == 0 {
					return false
				}
				off := pos.byte
				if !highlighters_wrap_is_word(utf8_read_codepoint(content, &off), big) {
					return true
				}
				word_length := pos.column - start.column
				max_word_length := wrap_column - prefix_len
				for off < len(content) && word_length <= max_word_length {
					cp := utf8_read_codepoint(content, &off)
					if !highlighters_wrap_is_word(cp, big) {
						break
					}
					word_length += Coord_Column(unicode_codepoint_width(cp))
				}
				if word_length <= max_word_length {
					pos^ = start
					return true
				}
				return false
			}
			if find_split(pos, last_WORD, wrap_column, prefix_len, content, true) ||
			   find_split(pos, last_word, wrap_column, prefix_len, content, false) {
				return true
			}
		}
	}
	return true
}

highlighters_tabulation_apply :: proc(hctx: Highlight_Context, display_buffer: ^Display_Buffer, buffer_range: Buffer_Range) {
	_ = buffer_range
	tabstop, ok := highlighters_option_int(hctx.ctx, "tabstop")
	if !ok || tabstop <= 0 {
		return
	}
	buffer := context_buffer(hctx.ctx)
	for &line in display_buffer.lines {
		column := Coord_Column(0)
		cached_line := Coord_Line(-1)
		line_str := ""
		pos := 0
		i := 0
		for i < len(line.atoms) {
			if line.atoms[i].type != .Range {
				i += 1
				continue
			}
			begin := line.atoms[i].range.begin
			if begin.line != cached_line {
				cached_line = begin.line
				line_str = buffer_line(buffer, begin.line)
				pos = 0
				column = 0
			}
			assert(pos <= int(begin.column))
			end_off := int(line.atoms[i].range.end.column)
			for pos != end_off {
				rel := strings.index_byte(line_str[pos:end_off], '\t')
				if rel < 0 {
					pos = end_off
					break
				}
				next_tab := pos + rel
				for pos != next_tab {
					// Bound the decode at the tab like C++
					// read_codepoint(pos, next_tab): a truncated
					// lead yields the byte without consuming past
					// it, so pos always lands exactly on next_tab.
					column += Coord_Column(unicode_codepoint_width(utf8_read_codepoint(line_str[:next_tab], &pos)))
				}
				tabwidth := Coord_Column(tabstop) - (column % Coord_Column(tabstop))
				column += tabwidth
				if pos >= int(line.atoms[i].range.begin.column) {
					if pos != int(line.atoms[i].range.begin.column) {
						i = display_buffer_line_split_coord(&line, i, Coord_Buffer{begin.line, Coord_Byte(pos)}) + 1
					}
					if pos + 1 != end_off {
						i = display_buffer_line_split_coord(&line, i, Coord_Buffer{begin.line, Coord_Byte(pos + 1)})
					}
					display_buffer_atom_replace_text(&line.atoms[i], strings.repeat(" ", int(tabwidth), context.temp_allocator))
					i += 1
				}
				pos += 1
			}
			if i >= len(line.atoms) {
				break
			}
			i += 1
		}
	}
}

highlighters_tabulation_setup :: proc(hctx: Highlight_Context, setup: ^Display_Setup) {
	buffer := context_buffer(hctx.ctx)
	cursor := selection_list_main(context_selections(hctx.ctx)).cursor.coord
	if buffer_byte_at(buffer, cursor) != '\t' {
		return
	}
	tabstop, ok := highlighters_option_int(hctx.ctx, "tabstop")
	if !ok || tabstop <= 0 {
		return
	}
	column := highlighters_get_column(buffer, tabstop, cursor)
	width := Coord_Column(tabstop) - (column % Coord_Column(tabstop))
	win_end := setup.first_column + window_dimensions(context_window(hctx.ctx)).column - setup.widget_columns
	offset := max(column + width - win_end, 0)
	setup.first_column += offset
}

highlighters_show_whitespace_apply :: proc(
	s: ^Highlighters_Show_Whitespace,
	hctx: Highlight_Context,
	display_buffer: ^Display_Buffer,
	buffer_range: Buffer_Range,
) {
	_ = buffer_range
	tabstop, ok := highlighters_option_int(hctx.ctx, "tabstop")
	if !ok {
		return
	}
	indentwidth, _ := highlighters_option_int(hctx.ctx, "indentwidth")
	whitespace_face := highlighters_lookup_face(hctx.ctx, "Whitespace")
	indent_face := highlighters_lookup_face(hctx.ctx, "WhitespaceIndent")
	buffer := context_buffer(hctx.ctx)
	is_whitespace := proc(cp: rune) -> bool {
		return cp == '\t' || cp == ' ' || cp == '\n' || cp == 0xA0 || cp == 0x202F
	}
	for &line in display_buffer.lines {
		is_indentation := true
		i := 0
		for i < len(line.atoms) {
			if line.atoms[i].type != .Range {
				i += 1
				continue
			}
			atom_begin := line.atoms[i].range.begin
			atom_end := line.atoms[i].range.end
			last_non_space := atom_begin
			if s.only_trailing {
				c := atom_begin
				for coord_compare(c, atom_end) < 0 {
					l := buffer_line(buffer, c.line)
					line_end := len(l) if c.line != atom_end.line else int(atom_end.column)
					off := int(c.column)
					for off < line_end {
						if !is_whitespace(utf8_read_codepoint(l, &off)) {
							last_non_space = Coord_Buffer{c.line, Coord_Byte(off)}
						}
					}
					c = Coord_Buffer{c.line + 1, 0}
				}
			}
			handled := false
			c := atom_begin
			for coord_compare(c, atom_end) < 0 && !handled {
				l := buffer_line(buffer, c.line)
				line_end := len(l) if c.line != atom_end.line else int(atom_end.column)
				off := int(c.column)
				for off < line_end {
					coord := Coord_Buffer{c.line, Coord_Byte(off)}
					cp := utf8_read_codepoint(l, &off)
					face := whitespace_face
					if is_whitespace(cp) {
						if s.only_trailing && coord_compare(Coord_Buffer{c.line, Coord_Byte(off)}, last_non_space) <= 0 {
							continue
						}
						if coord != atom_begin {
							i = display_buffer_line_split_coord(&line, i, coord) + 1
						}
						it_coord := Coord_Buffer{c.line, Coord_Byte(off)}
						if coord_compare(it_coord, line.atoms[i].range.end) < 0 {
							i = display_buffer_line_split_coord(&line, i, it_coord)
						}
						if cp == '\t' && len(s.tab) != 0 && len(s.tabpad) != 0 {
							column := highlighters_get_column(buffer, tabstop, coord)
							count := Coord_Column(tabstop) - (column % Coord_Column(tabstop))
							pad_count := max(int(count) - string_utils_column_length(s.tab), 0)
							first_pad := 0
							pad_rune := utf8_read_codepoint(s.tabpad, &first_pad)
							b := strings.builder_make(context.temp_allocator)
							strings.write_string(&b, s.tab)
							for k := 0; k < pad_count; k += 1 {
								strings.write_rune(&b, pad_rune)
							}
							display_buffer_atom_replace_text(&line.atoms[i], strings.to_string(b))
						} else if cp == ' ' && is_indentation && indentwidth > 0 && len(s.indent) != 0 {
							column := highlighters_get_column(buffer, tabstop, coord)
							if column % Coord_Column(indentwidth) == 0 && column != 0 {
								display_buffer_atom_replace_text(&line.atoms[i], s.indent)
								face = indent_face
							} else {
								display_buffer_atom_replace_text(&line.atoms[i], s.spc)
							}
						} else if cp == ' ' && len(s.spc) != 0 {
							display_buffer_atom_replace_text(&line.atoms[i], s.spc)
						} else if cp == '\n' && len(s.lf) != 0 {
							display_buffer_atom_replace_text(&line.atoms[i], s.lf)
						} else if (cp == 0xA0 || cp == 0x202F) && len(s.nbsp) != 0 {
							display_buffer_atom_replace_text(&line.atoms[i], s.nbsp)
						}
						highlighters_apply_face(&line.atoms[i], face)
						handled = true
						break
					} else {
						is_indentation = false
					}
				}
				if handled {
					break
				}
				c = Coord_Buffer{c.line + 1, 0}
			}
			i += 1
		}
	}
}

// ---------------------------------------------------------------------------
// number-lines, show-matching, selections, unprintable
// ---------------------------------------------------------------------------

highlighters_line_numbers_apply :: proc(
	n: ^Highlighters_Line_Numbers,
	hctx: Highlight_Context,
	display_buffer: ^Display_Buffer,
	buffer_range: Buffer_Range,
) {
	_ = buffer_range
	if highlighters_disabled(hctx.disabled_ids, "line-numbers") {
		return
	}
	face := highlighters_lookup_face(hctx.ctx, "LineNumbers")
	face_wrapped := highlighters_lookup_face(hctx.ctx, "LineNumbersWrapped")
	face_absolute := highlighters_lookup_face(hctx.ctx, "LineNumberCursor")
	digit_count := highlighters_line_numbers_digit_count(n, hctx)
	main_line := int(selection_list_main(context_selections(hctx.ctx)).cursor.coord.line) + 1
	last_line := -1
	for &line in display_buffer.lines {
		current_line := int(line.range.begin.line) + 1
		is_cursor_line := main_line == current_line
		line_to_format := current_line
		if n.relative && (!is_cursor_line || n.zero_cursor_line) {
			line_to_format = current_line - main_line
		}
		// Odin fmt has no C-style %*d; pad manually to digit_count.
		number := fmt.tprintf("%d", abs(line_to_format))
		if len(number) < digit_count {
			spaces := strings.repeat(" ", digit_count - len(number), context.temp_allocator)
			number = strings.concatenate({spaces, number}, context.temp_allocator)
		}
		atom_face := face
		if last_line == current_line {
			atom_face = face_wrapped
		} else if n.hl_cursor_line && is_cursor_line {
			atom_face = face_absolute
		}
		separator := n.separator
		if is_cursor_line && last_line != current_line {
			separator = n.cursor_separator
		}
		display_buffer_line_insert(&line, 0, display_buffer_atom_text(number, atom_face))
		display_buffer_line_insert(&line, 1, display_buffer_atom_text(separator, face))
		last_line = current_line
	}
}

highlighters_line_numbers_setup :: proc(n: ^Highlighters_Line_Numbers, hctx: Highlight_Context, setup: ^Display_Setup) {
	if highlighters_disabled(hctx.disabled_ids, "line-numbers") {
		return
	}
	width := Coord_Column(highlighters_line_numbers_digit_count(n, hctx) + string_utils_column_length(n.separator))
	setup.widget_columns += width
}

highlighters_line_numbers_digit_count :: proc(n: ^Highlighters_Line_Numbers, hctx: Highlight_Context) -> int {
	digit_count := 0
	line_count := Coord_Line(0)
	if n.relative && n.zero_cursor_line {
		cursor_line := selection_list_main(context_selections(hctx.ctx)).cursor.coord.line + 1
		above := abs(int(hctx.setup.first_line) - int(cursor_line))
		below := abs(int(hctx.setup.first_line + hctx.setup.line_count) - int(cursor_line))
		line_count = Coord_Line(max(above, below))
	} else {
		line_count = buffer_line_count(context_buffer(hctx.ctx))
	}
	for c := line_count; c > 0; c /= 10 {
		digit_count += 1
	}
	return max(digit_count, n.min_digits)
}

highlighters_matching_apply :: proc(
	m: ^Highlighters_Matching,
	hctx: Highlight_Context,
	display_buffer: ^Display_Buffer,
	buffer_range: Buffer_Range,
) {
	_ = buffer_range
	face := highlighters_lookup_face(hctx.ctx, "MatchingChar")
	pairs, ok := highlighters_option_runes(hctx.ctx, "matching_pairs")
	if !ok {
		return
	}
	rng := display_buffer.range
	buffer := context_buffer(hctx.ctx)
	for &sel in context_selections(hctx.ctx).selections {
		pos := sel.cursor.coord
		if coord_compare(pos, rng.begin) < 0 || coord_compare(pos, rng.end) >= 0 {
			continue
		}
		c := pos
		match := highlighters_matching_find(pairs, highlighters_rune_at(buffer, c))
		matching_prev := match < 0 && m.match_prev
		if m.match_prev && match < 0 {
			if c == (Coord_Buffer{0, 0}) {
				continue
			}
			c = buffer_char_prev(buffer, c)
			match = highlighters_matching_find(pairs, highlighters_rune_at(buffer, c))
		}
		if match < 0 {
			continue
		}
		if matching_prev {
			highlighters_highlight_range(display_buffer, c, buffer_char_next(buffer, c), false, face)
		}
		if match % 2 == 0 {
			if match + 1 >= len(pairs) {
				continue
			}
			opening := pairs[match]
			closing := pairs[match + 1]
			level := 0
			for coord_compare(c, rng.end) < 0 {
				cp := highlighters_rune_at(buffer, c)
				if cp == opening {
					level += 1
				} else if cp == closing {
					level -= 1
					if level == 0 {
						highlighters_highlight_range(display_buffer, c, buffer_char_next(buffer, c), false, face)
						break
					}
				}
				c = buffer_char_next(buffer, c)
			}
		} else if coord_compare(pos, rng.begin) > 0 {
			opening := pairs[match - 1]
			closing := pairs[match]
			level := 0
			for {
				cp := highlighters_rune_at(buffer, c)
				if cp == closing {
					level += 1
				} else if cp == opening {
					level -= 1
					if level == 0 {
						highlighters_highlight_range(display_buffer, c, buffer_char_next(buffer, c), false, face)
						break
					}
				}
				if coord_compare(c, rng.begin) <= 0 {
					break
				}
				c = buffer_char_prev(buffer, c)
			}
		}
	}
}

// highlighters_matching_find returns the pair index of cp, or -1.
highlighters_matching_find :: proc(pairs: [dynamic]rune, cp: rune) -> int {
	for p, i in pairs {
		if p == cp {
			return i
		}
	}
	return -1
}

// highlighters_rune_at decodes the codepoint at c (which must be valid).
highlighters_rune_at :: proc(buffer: ^Buffer, c: Coord_Buffer) -> rune {
	l := buffer_line(buffer, c.line)
	off := int(c.column)
	if off >= len(l) {
		return rune(-1)
	}
	return utf8_read_codepoint(l, &off)
}

highlighters_selections_apply :: proc(hctx: Highlight_Context, display_buffer: ^Display_Buffer, buffer_range: Buffer_Range) {
	_ = buffer_range
	buffer := context_buffer(hctx.ctx)
	sel_faces := [6]Face{
		highlighters_lookup_face(hctx.ctx, "PrimarySelection"),
		highlighters_lookup_face(hctx.ctx, "SecondarySelection"),
		highlighters_lookup_face(hctx.ctx, "PrimaryCursor"),
		highlighters_lookup_face(hctx.ctx, "SecondaryCursor"),
		highlighters_lookup_face(hctx.ctx, "PrimaryCursorEol"),
		highlighters_lookup_face(hctx.ctx, "SecondaryCursorEol"),
	}
	selections := context_selections(hctx.ctx)
	for &sel, i in selections.selections {
		forward := coord_compare(sel.anchor, sel.cursor.coord) <= 0
		begin := sel.anchor if forward else buffer_char_next(buffer, sel.cursor.coord)
		end := sel.cursor.coord if forward else buffer_char_next(buffer, sel.anchor)
		primary := i == selections.main
		highlighters_highlight_range(display_buffer, begin, end, false, sel_faces[0] if primary else sel_faces[1])
	}
	for &sel, i in selections.selections {
		coord := sel.cursor.coord
		primary := i == selections.main
		eol := Coord_Byte(len(buffer_line(buffer, coord.line)) - 1) == coord.column
		idx := 2 + (2 if eol else 0) + (0 if primary else 1)
		highlighters_highlight_range(display_buffer, coord, buffer_char_next(buffer, coord), false, sel_faces[idx])
	}
}

highlighters_unprintable_apply :: proc(hctx: Highlight_Context, display_buffer: ^Display_Buffer, buffer_range: Buffer_Range) {
	_ = buffer_range
	is_printable := proc(cp: rune) -> bool {
		if cp < 0xFF {
			return cp == '\n' || cp >= ' '
		} else if cp == 0x2028 || cp == 0x2029 || (cp >= 0xFFF9 && cp <= 0xFFFB) {
			return false
		}
		return true
	}
	buffer := context_buffer(hctx.ctx)
	error_face := highlighters_lookup_face(hctx.ctx, "Error")
	for &line in display_buffer.lines {
		i := 0
		for i < len(line.atoms) {
			if line.atoms[i].type != .Range {
				i += 1
				continue
			}
			begin := line.atoms[i].range.begin
			line_data := buffer_line(buffer, begin.line)
			off := int(begin.column)
			end_off := int(line.atoms[i].range.end.column)
			for off < end_off {
				next := off
				cp := utf8_read_codepoint(line_data, &next)
				if !is_printable(cp) {
					if Coord_Byte(off) != begin.column {
						i = display_buffer_line_split_coord(&line, i, Coord_Buffer{begin.line, Coord_Byte(off)}) + 1
					}
					if Coord_Byte(next) < line.atoms[i].range.end.column {
						i = display_buffer_line_split_coord(&line, i, Coord_Buffer{begin.line, Coord_Byte(next)})
					}
					display_buffer_atom_replace_text(&line.atoms[i], "�")
					line.atoms[i].face = error_face
					break
				}
				off = next
			}
			i += 1
		}
	}
}

// ---------------------------------------------------------------------------
// flag-lines, ranges, replace-ranges, ref
// ---------------------------------------------------------------------------

highlighters_flag_lines_apply :: proc(
	f: ^Highlighters_Flag_Lines,
	hctx: Highlight_Context,
	display_buffer: ^Display_Buffer,
	buffer_range: Buffer_Range,
) {
	_ = buffer_range
	specs, ok := highlighters_line_specs(hctx.ctx, f.option_name)
	if !ok {
		return
	}
	buffer := context_buffer(hctx.ctx)
	highlighters_update_line_specs_ifn(buffer, specs)
	def_face := highlighters_lookup_face(hctx.ctx, f.default_face)
	faces := context_faces(hctx.ctx)
	display_lines := make([dynamic]Display_Line, 0, len(specs.list), context.temp_allocator)
	for spec in specs.list {
		dl, err := display_buffer_parse_line(spec.spec, faces, nil, context.temp_allocator)
		if err != .None {
			return
		}
		append(&display_lines, dl)
		for &atom in display_lines[len(display_lines) - 1].atoms {
			atom.face = face_merge(def_face, atom.face)
		}
	}
	width := Coord_Column(0)
	for &dl in display_lines {
		width = max(width, display_buffer_line_length(dl))
	}
	empty := display_buffer_atom_text(strings.repeat(" ", int(width), context.temp_allocator), def_face)
	for &line in display_buffer.lines {
		line_num := int(line.range.begin.line) + 1
		idx := -1
		for spec, i in specs.list {
			if int(spec.line) == line_num {
				idx = i
				break
			}
		}
		if f.after {
			if idx >= 0 {
				display_buffer_line_insert_many(&line, len(line.atoms), display_lines[idx].atoms[:])
			}
			continue
		}
		if idx < 0 {
			display_buffer_line_insert(&line, 0, empty)
		} else {
			atoms := display_lines[idx].atoms[:]
			display_buffer_line_insert_many(&line, 0, atoms)
			pad_width := width - display_buffer_line_length(display_lines[idx])
			if pad_width != 0 {
				pad := display_buffer_atom_text(
					strings.repeat(" ", int(pad_width), context.temp_allocator),
					def_face,
				)
				display_buffer_line_insert(&line, len(atoms), pad)
			}
		}
	}
}

highlighters_flag_lines_setup :: proc(f: ^Highlighters_Flag_Lines, hctx: Highlight_Context, setup: ^Display_Setup) {
	if f.after {
		return
	}
	specs, ok := highlighters_line_specs(hctx.ctx, f.option_name)
	if !ok {
		return
	}
	buffer := context_buffer(hctx.ctx)
	highlighters_update_line_specs_ifn(buffer, specs)
	faces := context_faces(hctx.ctx)
	width := Coord_Column(0)
	for spec in specs.list {
		dl, err := display_buffer_parse_line(spec.spec, faces, nil, context.temp_allocator)
		if err != .None {
			return
		}
		width = max(width, display_buffer_line_length(dl))
	}
	setup.widget_columns += width
}

highlighters_ranges_apply :: proc(
	r: ^Highlighters_Ranges,
	hctx: Highlight_Context,
	display_buffer: ^Display_Buffer,
	buffer_range: Buffer_Range,
) {
	_ = buffer_range
	specs, ok := highlighters_range_specs(hctx.ctx, r.option_name)
	if !ok {
		return
	}
	buffer := context_buffer(hctx.ctx)
	highlighters_update_range_specs(buffer, specs)
	faces := context_faces(hctx.ctx)
	for spec in specs.list {
		face, err := face_registry_lookup(faces, spec.spec, context.temp_allocator)
		if err != .None {
			continue
		}
		first := spec.range.first
		last := spec.range.last
		if buffer_is_valid(buffer, first) && buffer_is_valid(buffer, last) && !buffer_is_end(buffer, last) {
			highlighters_highlight_range(display_buffer, first, buffer_char_next(buffer, last), false, face)
		}
	}
}

// highlighters_replace_ranges_valid checks spec coords (port of the
// ReplaceRangesHighlighter::is_valid helper).
highlighters_replace_ranges_valid :: proc(buffer: ^Buffer, c: Coord_Buffer) -> bool {
	return c.line >= 0 && c.column >= 0 &&
		c.line < buffer_line_count(buffer) &&
		c.column <= Coord_Byte(len(buffer_line(buffer, c.line)))
}

// highlighters_replace_ranges_fully_selected reports whether the range
// lies within a single selection (port of is_fully_selected).
highlighters_replace_ranges_fully_selected :: proc(selections: ^Selection_List, rng: Inclusive_Buffer_Range) -> bool {
	for &sel in selections.selections {
		if coord_compare(selection_basic_max(sel.basic), rng.first) < 0 {
			continue
		}
		sel_min := selection_basic_min(sel.basic)
		sel_max := selection_basic_max(sel.basic)
		return coord_compare(sel_min, rng.last) > 0 ||
			(coord_compare(sel_min, rng.first) <= 0 && coord_compare(sel_max, rng.last) >= 0)
	}
	return true
}

highlighters_replace_ranges_apply :: proc(
	r: ^Highlighters_Replace_Ranges,
	hctx: Highlight_Context,
	display_buffer: ^Display_Buffer,
	buffer_range: Buffer_Range,
) {
	_ = buffer_range
	specs, ok := highlighters_range_specs(hctx.ctx, r.option_name)
	if !ok {
		return
	}
	buffer := context_buffer(hctx.ctx)
	selections := context_selections(hctx.ctx)
	highlighters_update_range_specs(buffer, specs)
	faces := context_faces(hctx.ctx)
	for spec in specs.list {
		rng := spec.range
		if !highlighters_replace_ranges_valid(buffer, rng.first) ||
		   (!option_manager_inclusive_range_empty(rng) &&
			   !highlighters_replace_ranges_valid(buffer, rng.last)) ||
		   !highlighters_replace_ranges_fully_selected(selections, rng) {
			continue
		}
		end := rng.first if option_manager_inclusive_range_empty(rng) else buffer_char_next(buffer, rng.last)
		line_idx, atom_idx, erased := highlighters_replace_range_erase(display_buffer, rng.first, end)
		if !erased {
			continue
		}
		rest := spec.spec
		first_chunk := true
		for {
			chunk := rest
			if nl := strings.index_byte(rest, '\n'); nl >= 0 {
				chunk = rest[:nl]
				rest = rest[nl + 1:]
			} else {
				rest = ""
			}
			if !first_chunk {
				moved := display_buffer_line_extract(&display_buffer.lines[line_idx], atom_idx, len(display_buffer.lines[line_idx].atoms))
				inject_at(&display_buffer.lines, line_idx + 1, moved)
				line_idx += 1
				atom_idx = 0
			}
			first_chunk = false
			dl, err := display_buffer_parse_line(chunk, faces, nil, context.temp_allocator)
			if err != .None {
				break
			}
			for i in 0 ..< len(dl.atoms) {
				atom := dl.atoms[i]
				display_buffer_atom_replace_range(&atom, Buffer_Range{rng.first, end})
				display_buffer_line_insert(&display_buffer.lines[line_idx], atom_idx, atom)
				atom_idx += 1
			}
			if len(rest) == 0 {
				break
			}
		}
	}
}

highlighters_replace_ranges_setup :: proc(r: ^Highlighters_Replace_Ranges, hctx: Highlight_Context, setup: ^Display_Setup) {
	specs, ok := highlighters_range_specs(hctx.ctx, r.option_name)
	if !ok {
		return
	}
	buffer := context_buffer(hctx.ctx)
	selections := context_selections(hctx.ctx)
	highlighters_update_range_specs(buffer, specs)
	for spec in specs.list {
		rng := spec.range
		if !highlighters_replace_ranges_valid(buffer, rng.first) ||
		   (!option_manager_inclusive_range_empty(rng) &&
			   !highlighters_replace_ranges_valid(buffer, rng.last)) ||
		   !highlighters_replace_ranges_fully_selected(selections, rng) {
			continue
		}
		last := rng.first if option_manager_inclusive_range_empty(rng) else buffer_char_next(buffer, rng.last)
		if rng.first.line < setup.first_line && last.line >= setup.first_line {
			setup.first_line = rng.first.line
		}
		if last.line >= setup.first_line &&
		   rng.first.line <= setup.first_line + setup.line_count &&
		   rng.first.line != last.line {
			added := Coord_Line(strings.count(spec.spec, "\n"))
			removed := last.line - rng.first.line
			setup.line_count += removed - added
		}
	}
}

// Highlighters_Running_Ref tracks an in-flight ref expansion (port of the
// running_refs static in ReferenceHighlighter).
Highlighters_Running_Ref :: struct {
	name:  string,
	range: Buffer_Range,
}

// Highlighters_Running_Refs is the ref recursion guard (C++ static).
Highlighters_Running_Refs: [dynamic]Highlighters_Running_Ref

highlighters_reference_apply :: proc(
	r: ^Highlighters_Reference,
	hctx: Highlight_Context,
	display_buffer: ^Display_Buffer,
	buffer_range: Buffer_Range,
) {
	if !highlighters_shared_has_instance {
		return
	}
	for running in Highlighters_Running_Refs {
		if running.name == r.name && running.range == buffer_range {
			return
		}
	}
	append(&Highlighters_Running_Refs, Highlighters_Running_Ref{name = r.name, range = buffer_range})
	defer pop(&Highlighters_Running_Refs)
	target, err := highlighters_group_get_child(&highlighters_shared_instance().group, r.name)
	if err != .None {
		return
	}
	highlighter_highlight(target, hctx, display_buffer, buffer_range)
}

highlighters_reference_setup :: proc(r: ^Highlighters_Reference, hctx: Highlight_Context, setup: ^Display_Setup) {
	if !highlighters_shared_has_instance {
		return
	}
	target, err := highlighters_group_get_child(&highlighters_shared_instance().group, r.name)
	if err != .None {
		return
	}
	highlighter_compute_display_setup(target, hctx, setup)
}

// ---------------------------------------------------------------------------
// regions, region, default-region
// ---------------------------------------------------------------------------

// Highlighters_Region_Data wraps a delegate highlighter with region
// delimiters (port of RegionsHighlighter::RegionHighlighter).
Highlighters_Region_Data :: struct {
	delegate:      ^Highlighter, // owned
	begin:         string, // owned regex
	end:           string, // owned regex
	recurse:       string, // owned regex, may be ""
	match_capture: bool,
	is_default:    bool,
	allocator:     mem.Allocator,
}

// Highlighters_Regions_Data holds region children (port of
// RegionsHighlighter state; matches are recomputed per redraw instead of
// the C++ buffer-side cache).
Highlighters_Regions_Data :: struct {
	regions:        map[string]^Highlighter, // owned region wrappers
	order:          [dynamic]string, // insertion order; owns clones of names
	default_region: string, // owned, "" when none
	allocator:      mem.Allocator,
}

// highlighters_regions_make heap-allocates an empty regions highlighter
// (owned; free with highlighter_destroy using the same allocator).
highlighters_regions_make :: proc(allocator := context.allocator) -> ^Highlighter {
	data := new(Highlighters_Regions_Data, allocator)
	data.regions = make(map[string]^Highlighter, allocator)
	data.order = make([dynamic]string, data.allocator)
	data.allocator = allocator
	return highlighter_make_owned({.Colorize}, &highlighters_regions_vtable, data, allocator)
}

// highlighters_region_make heap-allocates a region wrapper (owned; free
// with highlighter_destroy using the same allocator). Takes ownership of
// delegate; clones the patterns.
highlighters_region_make :: proc(
	delegate: ^Highlighter,
	begin, end, recurse: string,
	match_capture: bool,
	allocator := context.allocator,
) -> ^Highlighter {
	data := new(Highlighters_Region_Data, allocator)
	data.delegate = delegate
	data.begin = strings.clone(begin, allocator)
	data.end = strings.clone(end, allocator)
	data.recurse = strings.clone(recurse, allocator)
	data.match_capture = match_capture
	data.allocator = allocator
	return highlighter_make_owned(delegate.passes, &highlighters_region_vtable, data, allocator)
}

// highlighters_region_make_default heap-allocates a default-region wrapper.
highlighters_region_make_default :: proc(delegate: ^Highlighter, allocator := context.allocator) -> ^Highlighter {
	hl := highlighters_region_make(delegate, "", "", "", false, allocator)
	(cast(^Highlighters_Region_Data)hl.data).is_default = true
	return hl
}

// highlighters_is_region reports whether hl is a region wrapper.
highlighters_is_region :: proc(hl: ^Highlighter) -> bool {
	return hl.vtable == &highlighters_region_vtable
}

// highlighters_is_regions reports whether hl is a regions container or a
// region wrapper chain leading to one (port of is_regions).
highlighters_is_regions :: proc(hl: ^Highlighter) -> bool {
	if hl == nil {
		return false
	}
	if hl.vtable == &highlighters_regions_vtable {
		return true
	}
	if hl.vtable == &highlighters_region_vtable {
		return highlighters_is_regions((cast(^Highlighters_Region_Data)hl.data).delegate)
	}
	return false
}

// Region vtable: forward everything to the delegate.

highlighters_region_vtable_do_highlight :: proc(
	data: rawptr,
	hctx: Highlight_Context,
	display_buffer: ^Display_Buffer,
	buffer_range: Buffer_Range,
) {
	highlighter_highlight((cast(^Highlighters_Region_Data)data).delegate, hctx, display_buffer, buffer_range)
}

highlighters_region_vtable_do_compute_display_setup :: proc(data: rawptr, hctx: Highlight_Context, setup: ^Display_Setup) {
	highlighters_region_setup(cast(^Highlighters_Region_Data)data, hctx, setup)
}

highlighters_region_setup :: proc(r: ^Highlighters_Region_Data, hctx: Highlight_Context, setup: ^Display_Setup) {
	highlighter_compute_display_setup(r.delegate, hctx, setup)
}

highlighters_region_vtable_has_children :: proc(data: rawptr) -> bool {
	return highlighter_has_children((cast(^Highlighters_Region_Data)data).delegate)
}

highlighters_region_vtable_get_child :: proc(data: rawptr, path: string, allocator: mem.Allocator) -> ^Highlighter {
	delegate := (cast(^Highlighters_Region_Data)data).delegate
	if !highlighter_has_children(delegate) {
		return nil
	}
	return delegate.vtable.get_child(delegate.data, path, allocator)
}

highlighters_region_vtable_add_child :: proc(data: rawptr, name: string, child: ^Highlighter, override: bool) {
	delegate := (cast(^Highlighters_Region_Data)data).delegate
	if highlighter_has_children(delegate) {
		delegate.vtable.add_child(delegate.data, name, child, override)
	}
}

highlighters_region_vtable_remove_child :: proc(data: rawptr, id: string) {
	delegate := (cast(^Highlighters_Region_Data)data).delegate
	if highlighter_has_children(delegate) {
		delegate.vtable.remove_child(delegate.data, id)
	}
}

highlighters_region_vtable_complete_child :: proc(
	data: rawptr,
	path: string,
	cursor_pos: Units_ByteCount,
	complete_group: bool,
	allocator: mem.Allocator,
) -> Completions {
	delegate := (cast(^Highlighters_Region_Data)data).delegate
	if !highlighter_has_children(delegate) {
		return Completions{}
	}
	return delegate.vtable.complete_child(delegate.data, path, cursor_pos, complete_group, allocator)
}

highlighters_region_vtable_fill_unique_ids :: proc(data: rawptr, unique_ids: ^[dynamic]string) {
	highlighter_fill_unique_ids((cast(^Highlighters_Region_Data)data).delegate, unique_ids)
}

highlighters_region_vtable_destroy :: proc(data: rawptr, allocator: mem.Allocator) {
	r := cast(^Highlighters_Region_Data)data
	r.delegate.vtable.destroy(r.delegate.data, r.allocator)
	free(r.delegate, r.allocator)
	delete(r.begin, r.allocator)
	delete(r.end, r.allocator)
	delete(r.recurse, r.allocator)
	free(r, allocator)
}

// highlighters_region_vtable forwards region wrappers to their delegate.
// Read-only after load.
highlighters_region_vtable := Highlighter_VTable{
	do_highlight             = highlighters_region_vtable_do_highlight,
	do_compute_display_setup = highlighters_region_vtable_do_compute_display_setup,
	has_children             = highlighters_region_vtable_has_children,
	get_child                = highlighters_region_vtable_get_child,
	add_child                = highlighters_region_vtable_add_child,
	remove_child             = highlighters_region_vtable_remove_child,
	complete_child           = highlighters_region_vtable_complete_child,
	fill_unique_ids          = highlighters_region_vtable_fill_unique_ids,
	destroy                  = highlighters_region_vtable_destroy,
}

// Regions container operations.

highlighters_regions_add_child :: proc(
	data: ^Highlighters_Regions_Data,
	name: string,
	child: ^Highlighter,
	override := false,
) -> Highlighters_Error {
	if !highlighters_is_region(child) {
		return .Wrong_Child_Type
	}
	if existing, ok := data.regions[name]; ok && !override {
		_ = existing
		return .Duplicate_Id
	}
	region := cast(^Highlighters_Region_Data)child.data
	if region.is_default {
		if len(data.default_region) != 0 {
			return .Duplicate_Id
		}
		delete(data.default_region, data.allocator)
		data.default_region = strings.clone(name, data.allocator)
	}
	if existing, ok := data.regions[name]; ok {
		existing.vtable.destroy(existing.data, data.allocator)
		free(existing, data.allocator)
		data.regions[name] = child
		return .None
	}
	key := strings.clone(name, data.allocator)
	data.regions[key] = child
	append(&data.order, strings.clone(name, data.allocator))
	return .None
}

highlighters_regions_remove_child :: proc(data: ^Highlighters_Regions_Data, id: string) -> Highlighters_Error {
	if id == data.default_region {
		delete(data.default_region, data.allocator)
		data.default_region = ""
	}
	for key, child in data.regions {
		if key == id {
			child.vtable.destroy(child.data, data.allocator)
			free(child, data.allocator)
			delete_key(&data.regions, key)
			delete(key, data.allocator)
			for entry, i in data.order {
				if entry == id {
					delete(data.order[i], data.allocator)
					ordered_remove(&data.order, i)
					break
				}
			}
			return .None
		}
	}
	return .No_Such_Id
}

highlighters_regions_get_child :: proc(data: ^Highlighters_Regions_Data, path: string) -> (^Highlighter, Highlighters_Error) {
	sep := strings.index_byte(path, '/')
	id := path if sep < 0 else path[:sep]
	child, ok := data.regions[id]
	if !ok {
		return nil, .No_Such_Id
	}
	if sep < 0 {
		return child, .None
	}
	if !highlighter_has_children(child) {
		return nil, .No_Such_Id
	}
	if found := child.vtable.get_child(child.data, path[sep + 1:], context.allocator); found != nil {
		return found, .None
	}
	return nil, .No_Such_Id
}

highlighters_regions_complete_child :: proc(
	data: ^Highlighters_Regions_Data,
	path: string,
	cursor_pos: Units_ByteCount,
	complete_group: bool,
	allocator := context.allocator,
) -> Completions {
	if sep := strings.index_byte(path, '/'); sep >= 0 {
		offset := Units_ByteCount(sep + 1)
		child, err := highlighters_regions_get_child(data, path[:sep])
		if err != .None {
			return Completions{}
		}
		return completion_offset_pos(
			child.vtable.complete_child(child.data, path[sep + 1:], cursor_pos - offset, complete_group, allocator),
			offset,
		)
	}
	names := make([dynamic]string, 0, len(data.regions), context.temp_allocator)
	for name in data.order {
		append(&names, name)
	}
	flags := Completion_Flags{.Menu} if !complete_group else Completion_Flags{}
	return Completions{
		candidates = completion_complete(path, cursor_pos, names[:], allocator),
		flags      = flags,
	}
}

highlighters_regions_vtable_do_highlight :: proc(
	data: rawptr,
	hctx: Highlight_Context,
	display_buffer: ^Display_Buffer,
	buffer_range: Buffer_Range,
) {
	highlighters_regions_apply(cast(^Highlighters_Regions_Data)data, hctx, display_buffer, buffer_range)
}

highlighters_regions_vtable_do_compute_display_setup :: proc(data: rawptr, hctx: Highlight_Context, setup: ^Display_Setup) {
	// The C++ RegionsHighlighter has no setup contribution.
}

highlighters_regions_vtable_has_children :: proc(data: rawptr) -> bool {
	return true
}

highlighters_regions_vtable_get_child :: proc(data: rawptr, path: string, allocator: mem.Allocator) -> ^Highlighter {
	child, _ := highlighters_regions_get_child(cast(^Highlighters_Regions_Data)data, path)
	return child
}

highlighters_regions_vtable_add_child :: proc(data: rawptr, name: string, child: ^Highlighter, override: bool) {
	_ = highlighters_regions_add_child(cast(^Highlighters_Regions_Data)data, name, child, override)
}

highlighters_regions_vtable_remove_child :: proc(data: rawptr, id: string) {
	_ = highlighters_regions_remove_child(cast(^Highlighters_Regions_Data)data, id)
}

highlighters_regions_vtable_complete_child :: proc(
	data: rawptr,
	path: string,
	cursor_pos: Units_ByteCount,
	complete_group: bool,
	allocator: mem.Allocator,
) -> Completions {
	return highlighters_regions_complete_child(
		cast(^Highlighters_Regions_Data)data,
		path,
		cursor_pos,
		complete_group,
		allocator,
	)
}

highlighters_regions_vtable_fill_unique_ids :: proc(data: rawptr, unique_ids: ^[dynamic]string) {
	// The C++ RegionsHighlighter keeps the empty base implementation.
}

highlighters_regions_vtable_destroy :: proc(data: rawptr, allocator: mem.Allocator) {
	data := cast(^Highlighters_Regions_Data)data
	for key, child in data.regions {
		child.vtable.destroy(child.data, data.allocator)
		free(child, data.allocator)
		delete(key, data.allocator)
	}
	for entry in data.order {
		delete(entry, data.allocator)
	}
	delete(data.order)
	delete(data.regions)
	delete(data.default_region, data.allocator)
	free(data, allocator)
}

// highlighters_regions_vtable dispatches regions containers. Read-only
// after load.
highlighters_regions_vtable := Highlighter_VTable{
	do_highlight             = highlighters_regions_vtable_do_highlight,
	do_compute_display_setup = highlighters_regions_vtable_do_compute_display_setup,
	has_children             = highlighters_regions_vtable_has_children,
	get_child                = highlighters_regions_vtable_get_child,
	add_child                = highlighters_regions_vtable_add_child,
	remove_child             = highlighters_regions_vtable_remove_child,
	complete_child           = highlighters_regions_vtable_complete_child,
	fill_unique_ids          = highlighters_regions_vtable_fill_unique_ids,
	destroy                  = highlighters_regions_vtable_destroy,
}

// Highlighters_Regex_Match is one delimiter match (port of RegexMatch).
Highlighters_Regex_Match :: struct {
	line:        Coord_Line,
	begin:       Coord_Byte,
	end:         Coord_Byte,
	capture_pos: u16,
	capture_len: u16,
}

highlighters_regex_match_begin_coord :: proc(m: Highlighters_Regex_Match) -> Coord_Buffer {
	return Coord_Buffer{m.line, m.begin}
}

highlighters_regex_match_end_coord :: proc(m: Highlighters_Regex_Match) -> Coord_Buffer {
	return Coord_Buffer{m.line, m.end}
}

highlighters_regex_match_capture :: proc(m: Highlighters_Regex_Match, buffer: ^Buffer) -> string {
	if m.capture_len == 0 {
		return ""
	}
	l := buffer_line(buffer, m.line)
	start := int(m.begin) + int(m.capture_pos)
	return l[start:start + int(m.capture_len)]
}

// Highlighters_Region_Key identifies a match list (port of RegexKey).
Highlighters_Region_Key :: struct {
	pattern:        string,
	match_captures: bool,
}

// Highlighters_Region is one segmented region (port of Region).
Highlighters_Region :: struct {
	begin:       Coord_Buffer,
	end:         Coord_Buffer,
	highlighter: ^Highlighter,
}

// highlighters_regions_collect gathers delimiter matches for every
// region pattern over [first_line, last_line) (per-line regex_iterator
// equivalent of the C++ MatchAdder).
highlighters_regions_collect :: proc(
	buffer: ^Buffer,
	data: ^Highlighters_Regions_Data,
	first_line, last_line: Coord_Line,
) -> map[Highlighters_Region_Key][dynamic]Highlighters_Regex_Match {
	matches := make(map[Highlighters_Region_Key][dynamic]Highlighters_Regex_Match, context.temp_allocator)
	// Compile each unique pattern once.
	compiled := make(map[Highlighters_Region_Key]Regex, context.temp_allocator)
	for _, child in data.regions {
		region := cast(^Highlighters_Region_Data)child.data
		if region.is_default {
			continue
		}
		patterns := [3]string{region.begin, region.end, region.recurse}
		for pattern in patterns {
			if len(pattern) == 0 {
				continue
			}
			key := Highlighters_Region_Key{pattern, region.match_capture}
			if key in compiled {
				continue
			}
			flags := Regex_Vm_Compile_Flags{.Optimize}
			if !region.match_capture {
				flags += {.No_Subs}
			}
			re, msg, rerr := regex_make(pattern, flags, context.temp_allocator)
			if rerr != .None {
				delete(msg, context.temp_allocator)
				continue
			}
			compiled[key] = re
			matches[key] = make([dynamic]Highlighters_Regex_Match, context.temp_allocator)
		}
	}
	for key, &re in compiled {
		list := &matches[key]
		for line := first_line; line < last_line; line += 1 {
			subject := buffer_line(buffer, line)
			it := regex_iterator_make(subject, 0, len(subject), &re, {.Not_End_Of_Line}, false, context.temp_allocator)
			for regex_iterator_next(&it) {
				whole := regex_match_results_get(&it.results, 0)
				sub := regex_match_results_get(&it.results, 1)
				with_capture := regex_mark_count(&re) > 0 && sub.matched &&
					whole.end - whole.begin < 65535
				pos, ln: u16
				if with_capture {
					pos = u16(sub.begin - whole.begin)
					ln = u16(sub.end - sub.begin)
				}
				append(
					list,
					Highlighters_Regex_Match{
						line = line,
						begin = Coord_Byte(whole.begin),
						end = Coord_Byte(whole.end),
						capture_pos = pos,
						capture_len = ln,
					},
				)
			}
		}
	}
	return matches
}

// highlighters_regions_find_matching_end finds the end delimiter closing
// a region opened at beg_pos (port of find_matching_end). Returns the
// index into end_matches, or -1.
highlighters_regions_find_matching_end :: proc(
	buffer: ^Buffer,
	beg_pos: Coord_Buffer,
	end_matches, recurse_matches: []Highlighters_Regex_Match,
	capture: string,
	use_capture: bool,
) -> int {
	ei, ri := 0, 0
	recurse_level := 0
	pos := beg_pos
	for {
		for ei < len(end_matches) &&
			coord_compare(highlighters_regex_match_begin_coord(end_matches[ei]), pos) < 0 {
			ei += 1
		}
		for ri < len(recurse_matches) &&
			coord_compare(highlighters_regex_match_begin_coord(recurse_matches[ri]), pos) < 0 {
			ri += 1
		}
		if ei == len(end_matches) {
			return -1
		}
		for ri < len(recurse_matches) &&
			coord_compare(
				highlighters_regex_match_end_coord(recurse_matches[ri]),
				highlighters_regex_match_end_coord(end_matches[ei]),
			) <= 0 {
			if !use_capture || highlighters_regex_match_capture(recurse_matches[ri], buffer) == capture {
				recurse_level += 1
			}
			ri += 1
		}
		if !use_capture || highlighters_regex_match_capture(end_matches[ei], buffer) == capture {
			if recurse_level == 0 {
				return ei
			}
			recurse_level -= 1
		}
		end_coord := highlighters_regex_match_end_coord(end_matches[ei])
		if pos != end_coord {
			pos = end_coord
		}
		ei += 1
	}
}

// highlighters_regions_find_next_begin finds the region with the leftmost
// opening at or after pos (port of find_next_begin).
highlighters_regions_find_next_begin :: proc(
	buffer: ^Buffer,
	region_list: []^Highlighter,
	matches: map[Highlighters_Region_Key][dynamic]Highlighters_Regex_Match,
	pos: Coord_Buffer,
) -> (
	region: int,
	match: int,
	found: bool,
) {
	best_begin := Coord_Buffer{}
	for child, i in region_list {
		rgn := cast(^Highlighters_Region_Data)child.data
		list, ok := matches[Highlighters_Region_Key{rgn.begin, rgn.match_capture}]
		if !ok {
			continue
		}
		mi := 0
		for mi < len(list) &&
			coord_compare(highlighters_regex_match_begin_coord(list[mi]), pos) < 0 {
			mi += 1
		}
		if mi == len(list) {
			continue
		}
		if !found || coord_compare(highlighters_regex_match_begin_coord(list[mi]), best_begin) < 0 {
			region, match, found = i, mi, true
			best_begin = highlighters_regex_match_begin_coord(list[mi])
		}
	}
	return region, match, found
}

// highlighters_regions_compute segments range into regions (port of
// get_regions_for_range). The result is owned (temp allocator).
highlighters_regions_compute :: proc(
	buffer: ^Buffer,
	data: ^Highlighters_Regions_Data,
	matches: map[Highlighters_Region_Key][dynamic]Highlighters_Regex_Match,
	range: Buffer_Range,
) -> [dynamic]Highlighters_Region {
	region_list := make([dynamic]^Highlighter, 0, len(data.regions), context.temp_allocator)
	for name in data.order {
		child := data.regions[name]
		if !(cast(^Highlighters_Region_Data)child.data).is_default {
			append(&region_list, child)
		}
	}
	regions := make([dynamic]Highlighters_Region, 0, context.temp_allocator)
	pos := range.begin
	for {
		ri, mi, found := highlighters_regions_find_next_begin(buffer, region_list[:], matches, pos)
		if !found {
			break
		}
		child := region_list[ri]
		region := cast(^Highlighters_Region_Data)child.data
		beg := matches[Highlighters_Region_Key{region.begin, region.match_capture}][mi]
		end_matches := matches[Highlighters_Region_Key{region.end, region.match_capture}][:]
		recurse_matches: []Highlighters_Regex_Match
		if len(region.recurse) != 0 {
			recurse_matches = matches[Highlighters_Region_Key{region.recurse, region.match_capture}][:]
		}
		capture := ""
		if region.match_capture {
			capture = highlighters_regex_match_capture(beg, buffer)
		}
		ei := highlighters_regions_find_matching_end(
			buffer,
			highlighters_regex_match_end_coord(beg),
			end_matches,
			recurse_matches,
			capture,
			region.match_capture,
		)
		if ei < 0 || coord_compare(highlighters_regex_match_end_coord(end_matches[ei]), range.end) >= 0 {
			// The region continues past the range end.
			if coord_compare(highlighters_regex_match_begin_coord(beg), range.end) < 0 {
				append(
					&regions,
					Highlighters_Region{
						highlighters_regex_match_begin_coord(beg),
						range.end,
						child,
					},
				)
			}
			break
		}
		end_coord := highlighters_regex_match_end_coord(end_matches[ei])
		append(
			&regions,
			Highlighters_Region{highlighters_regex_match_begin_coord(beg), end_coord, child},
		)
		// With empty begin and end matches, advance one column to
		// avoid an infinite loop.
		if end_coord == highlighters_regex_match_begin_coord(beg) {
			end_coord.column += 1
		}
		pos = end_coord
	}
	return regions
}

// Highlighters_Region_Applier highlights region slices in place (port of
// ForwardHighlighterApplier).
Highlighters_Region_Applier :: struct {
	db:       ^Display_Buffer,
	hctx:     Highlight_Context,
	cur_line: int,
	cur_atom: int,
}

highlighters_region_applier_apply :: proc(
	applier: ^Highlighters_Region_Applier,
	begin, end: Coord_Buffer,
	child: ^Highlighter,
) {
	if begin == end {
		return
	}
	lines := &applier.db.lines
	for applier.cur_line < len(lines^) &&
		coord_compare(lines[applier.cur_line].range.end, begin) <= 0 {
		applier.cur_line += 1
		applier.cur_atom = 0
	}
	if applier.cur_line == len(lines^) {
		return
	}
	if coord_compare(lines[applier.cur_line].range.begin, end) >= 0 {
		return
	}
	region_lines := make([dynamic]Display_Line, 0, context.temp_allocator)
	insert_pos := make([dynamic][2]int, 0, context.temp_allocator)
	for applier.cur_line < len(lines^) &&
		coord_compare(lines[applier.cur_line].range.begin, end) < 0 {
		line := &lines[applier.cur_line]
		first := len(line.atoms)
		for j := applier.cur_atom; j < len(line.atoms); j += 1 {
			if display_buffer_atom_has_range(line.atoms[j]) &&
			   coord_compare(line.atoms[j].range.end, begin) > 0 {
				first = j
				break
			}
		}
		if first != len(line.atoms) &&
		   line.atoms[first].type == .Range &&
		   coord_compare(line.atoms[first].range.begin, begin) < 0 {
			first = display_buffer_line_split_coord(line, first, begin) + 1
		}
		idx := first
		last := len(line.atoms)
		for j := first; j < len(line.atoms); j += 1 {
			if display_buffer_atom_has_range(line.atoms[j]) &&
			   coord_compare(line.atoms[j].range.end, end) > 0 {
				last = j
				break
			}
		}
		if last != len(line.atoms) &&
		   line.atoms[last].type == .Range &&
		   coord_compare(line.atoms[last].range.begin, end) < 0 {
			last = display_buffer_line_split_coord(line, last, end) + 1
		}
		if idx != last {
			append(&insert_pos, [2]int{applier.cur_line, idx})
			append(&region_lines, display_buffer_line_extract(line, idx, last))
		}
		if idx != len(line.atoms) {
			break
		}
		applier.cur_line += 1
		applier.cur_atom = 0
	}
	if len(region_lines) == 0 {
		return
	}
	region_display := Display_Buffer{lines = region_lines}
	display_buffer_compute_range(&region_display)
	highlighter_highlight(child, applier.hctx, &region_display, Buffer_Range{begin, end})
	for ip, k in insert_pos {
		atoms := region_display.lines[k].atoms[:]
		display_buffer_line_insert_many(&lines[ip[0]], ip[1], atoms)
		if ip[0] == applier.cur_line {
			applier.cur_atom = ip[1] + len(atoms)
		}
	}
	for &rl in region_display.lines {
		display_buffer_line_destroy(&rl)
	}
}

highlighters_regions_apply :: proc(
	data: ^Highlighters_Regions_Data,
	hctx: Highlight_Context,
	display_buffer: ^Display_Buffer,
	buffer_range: Buffer_Range,
) {
	if len(data.regions) == 0 {
		return
	}
	display_range := display_buffer.range
	buffer := context_buffer(hctx.ctx)
	last_line := min(buffer_line_count(buffer), buffer_range.end.line + 1)
	matches := highlighters_regions_collect(buffer, data, buffer_range.begin.line, last_line)
	regions := highlighters_regions_compute(buffer, data, matches, buffer_range)
	correct := proc(buffer: ^Buffer, c: Coord_Buffer) -> Coord_Buffer {
		if !buffer_is_end(buffer, c) && Coord_Byte(len(buffer_line(buffer, c.line))) == c.column {
			return Coord_Buffer{c.line + 1, 0}
		}
		return c
	}
	lo := len(regions)
	for i in 0 ..< len(regions) {
		if coord_compare(regions[i].end, display_range.begin) >= 0 {
			lo = i
			break
		}
	}
	hi := lo
	for hi < len(regions) && coord_compare(regions[hi].begin, display_range.end) < 0 {
		hi += 1
	}
	default_child, apply_default := data.regions[data.default_region]
	if len(data.default_region) == 0 {
		apply_default = false
	}
	last_begin := buffer_range.begin if lo == 0 else regions[lo - 1].end
	applier := Highlighters_Region_Applier{db = display_buffer, hctx = hctx}
	for i := lo; i < hi; i += 1 {
		if apply_default && coord_compare(last_begin, regions[i].begin) < 0 {
			highlighters_region_applier_apply(&applier, correct(buffer, last_begin), correct(buffer, regions[i].begin), default_child)
		}
		highlighters_region_applier_apply(&applier, correct(buffer, regions[i].begin), correct(buffer, regions[i].end), regions[i].highlighter)
		last_begin = regions[i].end
	}
	if apply_default && coord_compare(last_begin, display_range.end) < 0 {
		highlighters_region_applier_apply(&applier, correct(buffer, last_begin), buffer_range.end, default_child)
	}
	display_buffer_compute_range(display_buffer)
}

// ---------------------------------------------------------------------------
// Factories, descriptions, registration, builtins
// ---------------------------------------------------------------------------

// highlighters_parse_args parses factory params (transient; the parser
// borrows params and lives in temp storage).
highlighters_parse_args :: proc(
	params: Highlighter_Params,
	desc: Parameters_Parser_Desc,
) -> (
	parser: Parameters_Parser,
	ok: bool,
) {
	p, err := parameters_parser_parse(params, desc, false, context.temp_allocator)
	return p, err == .None
}

// highlighters_switch_string fetches a string switch value or a default.
highlighters_switch_string :: proc(parser: ^Parameters_Parser, name, default: string) -> string {
	if val, ok := parameters_parser_get_switch(parser, name); ok {
		return val
	}
	return default
}

// highlighters_switch_bool reports whether a flag switch was given.
highlighters_switch_bool :: proc(parser: ^Parameters_Parser, name: string) -> bool {
	_, ok := parameters_parser_get_switch(parser, name)
	return ok
}

highlighters_create_fill :: proc(params: Highlighter_Params, parent: ^Highlighter, allocator: mem.Allocator) -> ^Highlighter {
	_ = parent
	if len(params) != 1 {
		return nil
	}
	spec, err := highlighters_parse_face(params[0], allocator)
	if err != .None {
		return nil
	}
	return highlighters_any_make({.Colorize}, Highlighters_Fill{spec = spec}, allocator)
}

highlighters_create_regex :: proc(params: Highlighter_Params, parent: ^Highlighter, allocator: mem.Allocator) -> ^Highlighter {
	_ = parent
	if len(params) < 2 {
		return nil
	}
	// Compile first: capture names resolve against it.
	re, msg, rerr := regex_make(params[0], {.Optimize}, allocator)
	if rerr != .None {
		delete(msg, allocator)
		return nil
	}
	faces := make([dynamic]Highlighters_Capture_Face, 0, len(params) - 1, allocator)
	fail := proc(re: ^Regex, faces: ^[dynamic]Highlighters_Capture_Face, allocator: mem.Allocator) -> ^Highlighter {
		regex_destroy(re)
		for &cf in faces^ {
			highlighters_spec_destroy(&cf.spec, allocator)
		}
		delete(faces^)
		return nil
	}
	for spec in params[1:] {
		colon := strings.index_byte(spec, ':')
		if colon < 0 {
			return fail(&re, &faces, allocator)
		}
		capture, is_int := option_types_str_to_int_ifp(spec[:colon])
		if !is_int {
			capture = regex_named_capture_index(&re, spec[:colon])
		}
		if capture < 0 {
			return fail(&re, &faces, allocator)
		}
		parsed, err := highlighters_parse_face(spec[colon + 1:], allocator)
		if err != .None {
			return fail(&re, &faces, allocator)
		}
		append(&faces, Highlighters_Capture_Face{capture = capture, spec = parsed})
	}
	highlighters_regex_ensure_capture_0(&faces)
	data := Highlighters_Regex_Data{regex = re, faces = faces, has_regex = true, allocator = allocator}
	return highlighters_any_make({.Colorize}, data, allocator)
}

highlighters_create_dynamic_regex :: proc(
	params: Highlighter_Params,
	parent: ^Highlighter,
	allocator: mem.Allocator,
) -> ^Highlighter {
	_ = parent
	if len(params) < 2 {
		return nil
	}
	faces := make([dynamic]Highlighters_Named_Face, 0, len(params) - 1, allocator)
	for spec in params[1:] {
		colon := strings.index_byte(spec, ':')
		if colon < 0 {
			for &f in faces {
				delete(f.name, allocator)
				highlighters_spec_destroy(&f.spec, allocator)
			}
			delete(faces)
			return nil
		}
		parsed, err := highlighters_parse_face(spec[colon + 1:], allocator)
		if err != .None {
			for &f in faces {
				delete(f.name, allocator)
				highlighters_spec_destroy(&f.spec, allocator)
			}
			delete(faces)
			return nil
		}
		append(&faces, Highlighters_Named_Face{name = strings.clone(spec[:colon], allocator), spec = parsed})
	}
	data := Highlighters_Dynamic_Regex{
		source       = strings.clone(params[0], allocator),
		faces        = faces,
		last_pattern = strings.clone("", allocator),
		inner        = Highlighters_Regex_Data{allocator = allocator},
		allocator    = allocator,
	}
	data.inner.faces = make([dynamic]Highlighters_Capture_Face, allocator)
	return highlighters_any_make({.Colorize}, data, allocator)
}

highlighters_create_line :: proc(params: Highlighter_Params, parent: ^Highlighter, allocator: mem.Allocator) -> ^Highlighter {
	_ = parent
	if len(params) != 2 {
		return nil
	}
	spec, err := highlighters_parse_face(params[1], allocator)
	if err != .None {
		return nil
	}
	data := Highlighters_Line{expr = strings.clone(params[0], allocator), spec = spec}
	return highlighters_any_make({.Colorize}, data, allocator)
}

highlighters_create_column :: proc(params: Highlighter_Params, parent: ^Highlighter, allocator: mem.Allocator) -> ^Highlighter {
	_ = parent
	highlighters_descs_init()
	parser, ok := highlighters_parse_args(params, Highlighters_Desc_Column.params)
	if !ok || parameters_parser_positional_count(&parser) != 2 {
		return nil
	}
	ruler := highlighters_switch_string(&parser, "ruler", " ")
	if utf8_distance(ruler) > 1 {
		return nil
	}
	spec, err := highlighters_parse_face(parameters_parser_positional(&parser, 1), allocator)
	if err != .None {
		return nil
	}
	data := Highlighters_Column{
		expr                = strings.clone(parameters_parser_positional(&parser, 0), allocator),
		spec                = spec,
		highlight_non_blank = !highlighters_switch_bool(&parser, "ruler"),
		ruler               = strings.clone(ruler, allocator),
	}
	return highlighters_any_make({.Colorize}, data, allocator)
}

highlighters_create_wrap :: proc(params: Highlighter_Params, parent: ^Highlighter, allocator: mem.Allocator) -> ^Highlighter {
	_ = parent
	highlighters_descs_init()
	parser, ok := highlighters_parse_args(params, Highlighters_Desc_Wrap.params)
	if !ok {
		return nil
	}
	max_width := Coord_Column(max(int))
	if val, has := parameters_parser_get_switch(&parser, "width"); has {
		width, err := option_types_str_to_int(val)
		if err != .None {
			return nil
		}
		max_width = Coord_Column(width)
	}
	data := Highlighters_Wrap{
		max_width       = max_width,
		word_wrap       = highlighters_switch_bool(&parser, "word"),
		preserve_indent = highlighters_switch_bool(&parser, "indent"),
		marker          = strings.clone(highlighters_switch_string(&parser, "marker", ""), allocator),
	}
	return highlighters_any_make({.Wrap}, data, allocator)
}

// highlighters_tabulation_make builds the builtin tabulations highlighter.
highlighters_tabulation_make :: proc(allocator := context.allocator) -> ^Highlighter {
	return highlighters_any_make({.Replace}, Highlighters_Tabulation{}, allocator)
}

// highlighters_unprintable_make builds the builtin unprintable highlighter.
highlighters_unprintable_make :: proc(allocator := context.allocator) -> ^Highlighter {
	return highlighters_any_make({.Colorize}, Highlighters_Unprintable{}, allocator)
}

// highlighters_selections_make builds the builtin selections highlighter.
highlighters_selections_make :: proc(allocator := context.allocator) -> ^Highlighter {
	return highlighters_any_make({.Colorize}, Highlighters_Selections{}, allocator)
}

highlighters_create_show_whitespaces :: proc(
	params: Highlighter_Params,
	parent: ^Highlighter,
	allocator: mem.Allocator,
) -> ^Highlighter {
	_ = parent
	highlighters_descs_init()
	parser, ok := highlighters_parse_args(params, Highlighters_Desc_Show_Whitespaces.params)
	if !ok {
		return nil
	}
	get := proc(parser: ^Parameters_Parser, name, fallback: string, allocator: mem.Allocator) -> (string, bool) {
		value := highlighters_switch_string(parser, name, fallback)
		if utf8_distance(value) > 1 {
			return "", false
		}
		return strings.clone(value, allocator), true
	}
	tab, ok1 := get(&parser, "tab", "→", allocator)
	tabpad, ok2 := get(&parser, "tabpad", " ", allocator)
	spc, ok3 := get(&parser, "spc", "·", allocator)
	lf, ok4 := get(&parser, "lf", "¬", allocator)
	nbsp, ok5 := get(&parser, "nbsp", "⍽", allocator)
	indent, ok6 := get(&parser, "indent", "│", allocator)
	if !(ok1 && ok2 && ok3 && ok4 && ok5 && ok6) {
		owned := [6]string{tab, tabpad, spc, lf, nbsp, indent}
		for s in owned {
			delete(s, allocator)
		}
		return nil
	}
	data := Highlighters_Show_Whitespace{
		tab           = tab,
		tabpad        = tabpad,
		spc           = spc,
		lf            = lf,
		nbsp          = nbsp,
		indent        = indent,
		only_trailing = highlighters_switch_bool(&parser, "only-trailing"),
	}
	return highlighters_any_make({.Replace}, data, allocator)
}

highlighters_create_line_numbers :: proc(
	params: Highlighter_Params,
	parent: ^Highlighter,
	allocator: mem.Allocator,
) -> ^Highlighter {
	_ = parent
	highlighters_descs_init()
	parser, ok := highlighters_parse_args(params, Highlighters_Desc_Line_Numbers.params)
	if !ok {
		return nil
	}
	separator := highlighters_switch_string(&parser, "separator", "│")
	cursor_separator := highlighters_switch_string(&parser, "cursor-separator", separator)
	if len(separator) > 10 {
		return nil
	}
	if string_utils_column_length(cursor_separator) != string_utils_column_length(separator) {
		return nil
	}
	min_digits := 2
	if val, has := parameters_parser_get_switch(&parser, "min-digits"); has {
		digits, err := option_types_str_to_int(val)
		if err != .None {
			return nil
		}
		min_digits = digits
	}
	if min_digits < 0 || min_digits > 10 {
		return nil
	}
	relative := highlighters_switch_bool(&parser, "relative")
	full_relative := highlighters_switch_bool(&parser, "full-relative")
	data := Highlighters_Line_Numbers{
		relative         = relative || full_relative,
		zero_cursor_line = full_relative,
		hl_cursor_line   = highlighters_switch_bool(&parser, "hlcursor"),
		separator        = strings.clone(separator, allocator),
		cursor_separator = strings.clone(cursor_separator, allocator),
		min_digits       = min_digits,
	}
	return highlighters_any_make({.Move}, data, allocator)
}

highlighters_create_matching :: proc(params: Highlighter_Params, parent: ^Highlighter, allocator: mem.Allocator) -> ^Highlighter {
	_ = parent
	highlighters_descs_init()
	parser, ok := highlighters_parse_args(params, Highlighters_Desc_Show_Matching.params)
	if !ok {
		return nil
	}
	return highlighters_any_make(
		{.Colorize},
		Highlighters_Matching{match_prev = highlighters_switch_bool(&parser, "previous")},
		allocator,
	)
}

highlighters_create_flag_lines :: proc(
	params: Highlighter_Params,
	parent: ^Highlighter,
	allocator: mem.Allocator,
) -> ^Highlighter {
	_ = parent
	switches := make(map[string]Parameters_Parser_Switch_Desc, 1, context.temp_allocator)
	switches["after"] = {false, "display at line end"}
	desc := Parameters_Parser_Desc{
		switches        = switches,
		flags           = {.Switches_Only_At_Start},
		min_positionals = 2,
		max_positionals = 2,
	}
	parser, ok := highlighters_parse_args(params, desc)
	if !ok {
		return nil
	}
	option_name := parameters_parser_positional(&parser, 1)
	data := Highlighters_Flag_Lines{
		option_name  = strings.clone(option_name, allocator),
		default_face = strings.clone(parameters_parser_positional(&parser, 0), allocator),
		after        = highlighters_switch_bool(&parser, "after"),
	}
	return highlighters_any_make({.Move}, data, allocator)
}

highlighters_create_option_ranges :: proc(
	params: Highlighter_Params,
	allocator: mem.Allocator,
) -> (
	name: string,
	ok: bool,
) {
	if len(params) != 1 {
		return "", false
	}
	return strings.clone(params[0], allocator), true
}

highlighters_create_ranges :: proc(params: Highlighter_Params, parent: ^Highlighter, allocator: mem.Allocator) -> ^Highlighter {
	_ = parent
	name, ok := highlighters_create_option_ranges(params, allocator)
	if !ok {
		return nil
	}
	return highlighters_any_make({.Colorize}, Highlighters_Ranges{option_name = name}, allocator)
}

highlighters_create_replace_ranges :: proc(
	params: Highlighter_Params,
	parent: ^Highlighter,
	allocator: mem.Allocator,
) -> ^Highlighter {
	_ = parent
	name, ok := highlighters_create_option_ranges(params, allocator)
	if !ok {
		return nil
	}
	return highlighters_any_make({.Replace}, Highlighters_Replace_Ranges{option_name = name}, allocator)
}

highlighters_create_group :: proc(params: Highlighter_Params, parent: ^Highlighter, allocator: mem.Allocator) -> ^Highlighter {
	_ = parent
	highlighters_descs_init()
	parser, ok := highlighters_parse_args(params, Highlighters_Desc_Group.params)
	if !ok {
		return nil
	}
	passes, err := highlighters_parse_passes(highlighters_switch_string(&parser, "passes", "colorize"))
	if err != .None {
		return nil
	}
	group := new(Highlighter_Group, allocator)
	group.base = Highlighter{vtable = &highlighters_group_vtable, passes = passes, data = group}
	group.highlighters = make(map[string]^Highlighter, allocator)
	group.order = make([dynamic]string, allocator)
	group.allocator = allocator
	return &group.base
}

highlighters_create_reference :: proc(params: Highlighter_Params, parent: ^Highlighter, allocator: mem.Allocator) -> ^Highlighter {
	_ = parent
	highlighters_descs_init()
	parser, ok := highlighters_parse_args(params, Highlighters_Desc_Ref.params)
	if !ok || parameters_parser_positional_count(&parser) != 1 {
		return nil
	}
	passes, err := highlighters_parse_passes(highlighters_switch_string(&parser, "passes", "colorize"))
	if err != .None {
		return nil
	}
	return highlighters_any_make(
		passes,
		Highlighters_Reference{name = strings.clone(parameters_parser_positional(&parser, 0), allocator)},
		allocator,
	)
}

highlighters_create_regions :: proc(params: Highlighter_Params, parent: ^Highlighter, allocator: mem.Allocator) -> ^Highlighter {
	_ = parent
	if len(params) != 0 {
		return nil
	}
	return highlighters_regions_make(allocator)
}

// highlighters_region_delegate builds the delegate highlighter for a
// region/default-region from the type name and delegate params.
highlighters_region_delegate :: proc(
	type: string,
	delegate_params: Highlighter_Params,
	allocator: mem.Allocator,
) -> ^Highlighter {
	if !highlighter_registry_has_instance {
		return nil
	}
	entry, err := highlighter_registry_get(highlighter_registry_instance(), type)
	if err != .None {
		return nil
	}
	return entry.factory(delegate_params, nil, allocator)
}

// highlighters_compiles reports whether pattern is a valid regex.
highlighters_compiles :: proc(pattern: string) -> bool {
	re, msg, err := regex_make(pattern, {.Optimize}, context.temp_allocator)
	if err != .None {
		delete(msg, context.temp_allocator)
		return false
	}
	regex_destroy(&re)
	return true
}

highlighters_create_region :: proc(params: Highlighter_Params, parent: ^Highlighter, allocator: mem.Allocator) -> ^Highlighter {
	if !highlighters_is_regions(parent) {
		return nil
	}
	highlighters_descs_init()
	parser, ok := highlighters_parse_args(params, Highlighters_Desc_Region.params)
	if !ok || parameters_parser_positional_count(&parser) < 3 {
		return nil
	}
	begin := parameters_parser_positional(&parser, 0)
	end := parameters_parser_positional(&parser, 1)
	if len(begin) == 0 || len(end) == 0 {
		return nil
	}
	if !highlighters_compiles(begin) || !highlighters_compiles(end) {
		return nil
	}
	recurse := highlighters_switch_string(&parser, "recurse", "")
	if len(recurse) != 0 && !highlighters_compiles(recurse) {
		return nil
	}
	delegate := highlighters_region_delegate(
		parameters_parser_positional(&parser, 2),
		parameters_parser_positionals_from(&parser, 3),
		allocator,
	)
	if delegate == nil {
		return nil
	}
	return highlighters_region_make(
		delegate,
		begin,
		end,
		recurse,
		highlighters_switch_bool(&parser, "match-capture"),
		allocator,
	)
}

highlighters_create_default_region :: proc(
	params: Highlighter_Params,
	parent: ^Highlighter,
	allocator: mem.Allocator,
) -> ^Highlighter {
	if !highlighters_is_regions(parent) {
		return nil
	}
	desc := Parameters_Parser_Desc{
		flags           = {.Switches_Only_At_Start},
		min_positionals = 1,
		max_positionals = max(int),
	}
	parser, ok := highlighters_parse_args(params, desc)
	if !ok || parameters_parser_positional_count(&parser) < 1 {
		return nil
	}
	delegate := highlighters_region_delegate(
		parameters_parser_positional(&parser, 0),
		parameters_parser_positionals_from(&parser, 1),
		allocator,
	)
	if delegate == nil {
		return nil
	}
	return highlighters_region_make_default(delegate, allocator)
}

// Highlighter descriptions (process-lifetime; initialized once by
// highlighters_descs_init).
Highlighters_Desc_Fill:             Highlighter_Desc
Highlighters_Desc_Regex:            Highlighter_Desc
Highlighters_Desc_Dynamic_Regex:    Highlighter_Desc
Highlighters_Desc_Line:             Highlighter_Desc
Highlighters_Desc_Column:           Highlighter_Desc
Highlighters_Desc_Wrap:             Highlighter_Desc
Highlighters_Desc_Show_Whitespaces: Highlighter_Desc
Highlighters_Desc_Line_Numbers:     Highlighter_Desc
Highlighters_Desc_Show_Matching:    Highlighter_Desc
Highlighters_Desc_Flag_Lines:       Highlighter_Desc
Highlighters_Desc_Ranges:           Highlighter_Desc
Highlighters_Desc_Replace_Ranges:   Highlighter_Desc
Highlighters_Desc_Group:            Highlighter_Desc
Highlighters_Desc_Ref:              Highlighter_Desc
Highlighters_Desc_Region:           Highlighter_Desc
Highlighters_Desc_Regions:          Highlighter_Desc
Highlighters_Desc_Default_Region:   Highlighter_Desc
highlighters_descs_ready := false

// highlighters_descs_mutex serializes description construction: factories
// (and parallel tests) may trigger it from any thread.
highlighters_descs_mutex: sync.Mutex

// highlighters_switch_desc builds a switch description entry.
highlighters_switch_desc :: proc(
	switches: ^map[string]Parameters_Parser_Switch_Desc,
	name: string,
	takes_argument: bool,
	description: string,
) {
	switches^[name] = Parameters_Parser_Switch_Desc{takes_argument = takes_argument, description = description}
}

// highlighters_descs_init builds the factory descriptions once. The maps
// are process-lifetime (like C++ statics), so they use the heap
// allocator explicitly: context.allocator may be a per-test rollback
// arena that is wiped when the test ends.
highlighters_descs_init :: proc() {
	sync.mutex_lock(&highlighters_descs_mutex)
	defer sync.mutex_unlock(&highlighters_descs_mutex)
	if highlighters_descs_ready {
		return
	}
	alloc := runtime.heap_allocator()
	Highlighters_Desc_Fill = {"Fill the whole highlighted range with the given face", {}}
	Highlighters_Desc_Regex = {
		"Parameters: <regex> <capture num>:<face> <capture num>:<face>...\nHighlights the matches for captures from the regex with the given faces",
		{},
	}
	Highlighters_Desc_Dynamic_Regex = {
		"Parameters: <expr> <capture num>:<face> <capture num>:<face>...\nEvaluate expression at every redraw to gather a regex",
		{},
	}
	Highlighters_Desc_Line = {
		"Parameters: <value string> <face>\nHighlight the line given by evaluating <value string> with <face>",
		{},
	}
	column_switches := make(map[string]Parameters_Parser_Switch_Desc, alloc)
	highlighters_switch_desc(
		&column_switches,
		"ruler",
		true,
		"replace empty or whitespace cells with the given character. When provided, <face> is not applied to non-empty cells",
	)
	Highlighters_Desc_Column = {
		"Parameters: [-ruler <character>] <column> <face>\nHighlight the column <column> with <face>",
		{switches = column_switches, min_positionals = 2, max_positionals = 2},
	}
	wrap_switches := make(map[string]Parameters_Parser_Switch_Desc, alloc)
	highlighters_switch_desc(&wrap_switches, "word", false, "wrap at word boundaries instead of codepoint boundaries")
	highlighters_switch_desc(&wrap_switches, "indent", false, "preserve line indentation of the wrapped line")
	highlighters_switch_desc(&wrap_switches, "width", true, "wrap at the given column instead of the window's width")
	highlighters_switch_desc(&wrap_switches, "marker", true, "insert the given text at the beginning of the wrapped line")
	Highlighters_Desc_Wrap = {
		"Parameters: [-word] [-indent] [-width <max_width>] [-marker <marker_text>]\nWrap lines to window width",
		{switches = wrap_switches},
	}
	whitespace_switches := make(map[string]Parameters_Parser_Switch_Desc, alloc)
	highlighters_switch_desc(&whitespace_switches, "tab", true, "replace tabulations with the given character")
	highlighters_switch_desc(&whitespace_switches, "tabpad", true, "append as many of the given character as is necessary to honor `tabstop`")
	highlighters_switch_desc(&whitespace_switches, "spc", true, "replace spaces with the given character")
	highlighters_switch_desc(&whitespace_switches, "lf", true, "replace line feeds with the given character")
	highlighters_switch_desc(&whitespace_switches, "nbsp", true, "replace non-breakable spaces with the given character")
	highlighters_switch_desc(
		&whitespace_switches,
		"indent",
		true,
		"replace first space of every indent with the given character according to `indentwidth`",
	)
	highlighters_switch_desc(&whitespace_switches, "only-trailing", false, "only highlighting trailing whitespaces")
	Highlighters_Desc_Show_Whitespaces = {
		"Parameters: [-tab <separator>] [-tabpad <separator>] [-lf <separator>] [-spc <separator>] [-nbsp <separator>] [-indent <separator>]\nDisplay whitespaces using symbols",
		{switches = whitespace_switches},
	}
	numbers_switches := make(map[string]Parameters_Parser_Switch_Desc, alloc)
	highlighters_switch_desc(&numbers_switches, "relative", false, "show line numbers relative to the main cursor line")
	highlighters_switch_desc(
		&numbers_switches,
		"full-relative",
		false,
		"show line numbers relative to the main cursor line and the main cursor line as 0",
	)
	highlighters_switch_desc(
		&numbers_switches,
		"separator",
		true,
		"string to separate the line numbers column from the rest of the buffer (default '|')",
	)
	highlighters_switch_desc(
		&numbers_switches,
		"cursor-separator",
		true,
		"identical to -separator but applies only to the line of the cursor (default is the same value passed to -separator)",
	)
	highlighters_switch_desc(
		&numbers_switches,
		"min-digits",
		true,
		"use at least the given number of columns to display line numbers (default 2)",
	)
	highlighters_switch_desc(&numbers_switches, "hlcursor", false, "highlight the cursor line with a separate face")
	Highlighters_Desc_Line_Numbers = {
		"Parameters: [-relative] [-hlcursor] [-separators <separator|separator:cursor|cursor:up:down>] [-min-digits <cols>]\nDisplay line numbers",
		{switches = numbers_switches},
	}
	matching_switches := make(map[string]Parameters_Parser_Switch_Desc, alloc)
	highlighters_switch_desc(&matching_switches, "previous", false, "")
	Highlighters_Desc_Show_Matching = {
		"Apply the MatchingChar face to the char matching the one under the cursor",
		{switches = matching_switches, flags = {.Switches_Only_At_Start}},
	}
	Highlighters_Desc_Flag_Lines = {
		"Parameters: <face> <option name>\nDisplay flags specified in the line-spec option <option name> with <face>",
		{},
	}
	Highlighters_Desc_Ranges = {
		"Parameters: <option name>\nUse the range-specs option given as parameter to highlight buffer\neach spec is interpreted as a face to apply to the range",
		{},
	}
	Highlighters_Desc_Replace_Ranges = {
		"Parameters: <option name>\nUse the range-specs option given as parameter to highlight buffer\neach spec is interpreted as a display line to display in place of the range",
		{},
	}
	group_switches := make(map[string]Parameters_Parser_Switch_Desc, alloc)
	highlighters_switch_desc(
		&group_switches,
		"passes",
		true,
		"flags(colorize|move|wrap|replace) kind of highlighters can be put in the group (default colorize)",
	)
	Highlighters_Desc_Group = {
		"Parameters: [-passes <passes>]\nCreates a group that can contain other highlighters",
		{switches = group_switches, flags = {.Switches_Only_At_Start}},
	}
	ref_switches := make(map[string]Parameters_Parser_Switch_Desc, alloc)
	highlighters_switch_desc(
		&ref_switches,
		"passes",
		true,
		"flags(colorize|move|wrap|replace) kind of highlighters that can be referenced (default colorize)",
	)
	Highlighters_Desc_Ref = {
		"Parameters: [-passes <passes>] <path>\nReference the highlighter at <path> in shared highlighters",
		{switches = ref_switches, flags = {.Switches_Only_At_Start}, min_positionals = 1, max_positionals = 1},
	}
	region_switches := make(map[string]Parameters_Parser_Switch_Desc, alloc)
	highlighters_switch_desc(
		&region_switches,
		"match-capture",
		false,
		"only consider region ending/recurse delimiters whose first capture group match the region beginning delimiter",
	)
	highlighters_switch_desc(
		&region_switches,
		"recurse",
		true,
		"make the region end on the first ending delimiter that does not close the given parameter",
	)
	Highlighters_Desc_Region = {
		"Parameters:  [-match-capture] [-recurse <recurse>] <opening> <closing> <type> <params>...\nDefine a region for a regions highlighter, and apply the given delegate\nhighlighter as defined by <type> and eventual <params>...\nThe region starts at <begin> match and ends at the first <end>",
		{
			switches = region_switches,
			flags = {.Switches_Only_At_Start, .Ignore_Unknown_Switches},
			min_positionals = 3,
			max_positionals = max(int),
		},
	}
	Highlighters_Desc_Regions = {
		"Holds child region highlighters and segments the buffer in ranges based on those regions\ndefinitions. The regions highlighter finds the next region to start by finding which\nof its child region has the leftmost starting point from current position. In between\nregions, the default-region child highlighter is applied (if such a child exists)",
		{},
	}
	Highlighters_Desc_Default_Region = {
		"Parameters: <delegate_type> <delegate_params>...\nDefine the default region of a regions highlighter",
		{},
	}
	highlighters_descs_ready = true
}

// highlighters_register installs every builtin factory (port of
// register_highlighters). The registry singleton must be initialized.
highlighters_register :: proc() {
	highlighters_descs_init()
	reg := highlighter_registry_instance()
	highlighter_registry_add(reg, "column", highlighters_create_column, &Highlighters_Desc_Column)
	highlighter_registry_add(reg, "default-region", highlighters_create_default_region, &Highlighters_Desc_Default_Region)
	highlighter_registry_add(reg, "dynregex", highlighters_create_dynamic_regex, &Highlighters_Desc_Dynamic_Regex)
	highlighter_registry_add(reg, "fill", highlighters_create_fill, &Highlighters_Desc_Fill)
	highlighter_registry_add(reg, "flag-lines", highlighters_create_flag_lines, &Highlighters_Desc_Flag_Lines)
	highlighter_registry_add(reg, "group", highlighters_create_group, &Highlighters_Desc_Group)
	highlighter_registry_add(reg, "line", highlighters_create_line, &Highlighters_Desc_Line)
	highlighter_registry_add(reg, "number-lines", highlighters_create_line_numbers, &Highlighters_Desc_Line_Numbers)
	highlighter_registry_add(reg, "ranges", highlighters_create_ranges, &Highlighters_Desc_Ranges)
	highlighter_registry_add(reg, "ref", highlighters_create_reference, &Highlighters_Desc_Ref)
	highlighter_registry_add(reg, "regex", highlighters_create_regex, &Highlighters_Desc_Regex)
	highlighter_registry_add(reg, "region", highlighters_create_region, &Highlighters_Desc_Region)
	highlighter_registry_add(reg, "regions", highlighters_create_regions, &Highlighters_Desc_Regions)
	highlighter_registry_add(
		reg,
		"replace-ranges",
		highlighters_create_replace_ranges,
		&Highlighters_Desc_Replace_Ranges,
	)
	highlighter_registry_add(reg, "show-matching", highlighters_create_matching, &Highlighters_Desc_Show_Matching)
	highlighter_registry_add(
		reg,
		"show-whitespaces",
		highlighters_create_show_whitespaces,
		&Highlighters_Desc_Show_Whitespaces,
	)
	highlighter_registry_add(reg, "wrap", highlighters_create_wrap, &Highlighters_Desc_Wrap)
}

// highlighters_setup_builtin installs the window builtins (port of
// setup_builtin_highlighters): tabulations, unprintable, selections.
highlighters_setup_builtin :: proc(group: ^Highlighter_Group) {
	_ = highlighters_group_add_child(group, "tabulations", highlighters_tabulation_make(group.allocator))
	_ = highlighters_group_add_child(group, "unprintable", highlighters_unprintable_make(group.allocator))
	_ = highlighters_group_add_child(group, "selections", highlighters_selections_make(group.allocator))
}
