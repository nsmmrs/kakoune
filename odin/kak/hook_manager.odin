// Port of Kakoune's src/hook_manager.{hh,cc}: scoped hook lists with
// regex filters, groups, Always/Once flags and a recursion guard.
//
// Hook_Manager/ Hook_Data/Hook come from knot.odin. Standalone-testable
// behavior (hook names, add/remove lists, should_run filtering) is fully
// tested; run_hook/exec/complete_hook_group call STUB procs from
// unmerged modules (context, option_manager, debug, completion) and are
// ported faithfully but untestable until the stubs resolve.
//
// Ownership: the manager owns every Hook_Data (heap-allocated with
// m.allocator), their group/commands strings (cloned on registration)
// and their filter regex (ownership transfers from the caller on
// registration: the caller must not destroy it afterwards). Release with
// hook_manager_destroy. should_run captures are always valid results;
// the caller destroys them with regex_match_results_destroy.
package kak

import "core:mem"
import "core:strings"

// Hook_Manager_To_Run is the C++ run_hook local ToRun: a hook selected
// for execution plus its match captures (owned).
Hook_Manager_To_Run :: struct {
	hook:     ^Hook_Data,
	captures: Regex_Match_Results,
}

// hook_manager_hook_descs ports the C++ enum_desc<Hook> table: the 43
// hook names in enumerator order.
hook_manager_hook_descs := [43]Enum_Desc(Hook){
	{value = .Buf_Create, name = "BufCreate"},
	{value = .Buf_New_File, name = "BufNewFile"},
	{value = .Buf_Open_File, name = "BufOpenFile"},
	{value = .Buf_Close, name = "BufClose"},
	{value = .Buf_Write_Post, name = "BufWritePost"},
	{value = .Buf_Reload, name = "BufReload"},
	{value = .Buf_Write_Pre, name = "BufWritePre"},
	{value = .Buf_Open_Fifo, name = "BufOpenFifo"},
	{value = .Buf_Close_Fifo, name = "BufCloseFifo"},
	{value = .Buf_Read_Fifo, name = "BufReadFifo"},
	{value = .Buf_Set_Option, name = "BufSetOption"},
	{value = .Client_Create, name = "ClientCreate"},
	{value = .Client_Close, name = "ClientClose"},
	{value = .Client_Renamed, name = "ClientRenamed"},
	{value = .Session_Renamed, name = "SessionRenamed"},
	{value = .Insert_Char, name = "InsertChar"},
	{value = .Insert_Delete, name = "InsertDelete"},
	{value = .Insert_Idle, name = "InsertIdle"},
	{value = .Insert_Key, name = "InsertKey"},
	{value = .Insert_Move, name = "InsertMove"},
	{value = .Insert_Completion_Hide, name = "InsertCompletionHide"},
	{value = .Insert_Completion_Show, name = "InsertCompletionShow"},
	{value = .Kak_Begin, name = "KakBegin"},
	{value = .Kak_End, name = "KakEnd"},
	{value = .Focus_In, name = "FocusIn"},
	{value = .Focus_Out, name = "FocusOut"},
	{value = .Global_Set_Option, name = "GlobalSetOption"},
	{value = .Runtime_Error, name = "RuntimeError"},
	{value = .Prompt_Idle, name = "PromptIdle"},
	{value = .Normal_Idle, name = "NormalIdle"},
	{value = .Next_Key_Idle, name = "NextKeyIdle"},
	{value = .Normal_Key, name = "NormalKey"},
	{value = .Mode_Change, name = "ModeChange"},
	{value = .Enter_Directory, name = "EnterDirectory"},
	{value = .Raw_Key, name = "RawKey"},
	{value = .Register_Modified, name = "RegisterModified"},
	{value = .Win_Close, name = "WinClose"},
	{value = .Win_Create, name = "WinCreate"},
	{value = .Win_Display, name = "WinDisplay"},
	{value = .Win_Resize, name = "WinResize"},
	{value = .Win_Set_Option, name = "WinSetOption"},
	{value = .Module_Loaded, name = "ModuleLoaded"},
	{value = .User, name = "User"},
}

// hook_manager_hook_name returns the canonical hook name (C++
// enum_desc<Hook> lookup).
hook_manager_hook_name :: proc(hook: Hook) -> string {
	name, _ := enum_to_name(hook_manager_hook_descs[:], hook)
	return name
}

// hook_manager_make creates a manager with the given parent (C++
// HookManager ctors; parent is nil for the scope-owned root).
hook_manager_make :: proc(parent: ^Hook_Manager = nil, allocator := context.allocator) -> Hook_Manager {
	m := Hook_Manager{parent = parent, allocator = allocator}
	for i in 0 ..< len(m.hooks) {
		m.hooks[i] = make([dynamic]^Hook_Data, 0, allocator)
	}
	m.running_hooks = make([dynamic]Hook_Running, 0, allocator)
	m.hooks_trash = make([dynamic]^Hook_Data, 0, allocator)
	return m
}

// hook_manager_free_data releases one heap-allocated Hook_Data.
hook_manager_free_data :: proc(data: ^Hook_Data, allocator: mem.Allocator) {
	regex_destroy(&data.filter)
	delete(data.group, allocator)
	delete(data.commands, allocator)
	free(data, allocator)
}

// hook_manager_destroy releases all manager-owned hooks and lists (C++
// HookManager dtor).
hook_manager_destroy :: proc(m: ^Hook_Manager) {
	for i in 0 ..< len(m.hooks) {
		for data in m.hooks[i] {
			hook_manager_free_data(data, m.allocator)
		}
		delete(m.hooks[i])
	}
	for data in m.hooks_trash {
		hook_manager_free_data(data, m.allocator)
	}
	delete(m.hooks_trash)
	delete(m.running_hooks)
	m^ = {}
}

// hook_manager_reparent repoints the parent manager (C++ reparent).
hook_manager_reparent :: proc(m: ^Hook_Manager, parent: ^Hook_Manager) {
	m.parent = parent
}

// hook_manager_should_run decides whether a hook fires for param (C++
// HookData::should_run): Always-only filtering, the disabled_hooks group
// check, then the filter match. The captures are always a valid results
// value; the caller destroys them with regex_match_results_destroy (which
// frees through the ambient allocator, so keep the default allocator
// unless the ambient one matches).
hook_manager_should_run :: proc(
	data: ^Hook_Data,
	only_always: bool,
	disabled_hooks: ^Regex,
	param: string,
	allocator := context.allocator,
) -> (Regex_Match_Results, bool) {
	if only_always && .Always not_in data.flags {
		return regex_match_results_make(allocator), false
	}
	if len(data.group) > 0 && !regex_empty(disabled_hooks) &&
	   regex_match_simple(data.group, disabled_hooks) {
		return regex_match_results_make(allocator), false
	}
	filter := data.filter
	captures, matched := regex_match(param, &filter, allocator)
	return captures, matched
}

// hook_manager_debug_write writes one DEBUG message built from parts to
// the *debug* buffer.
hook_manager_debug_write :: proc(parts: []string, allocator := context.allocator) {
	b := strings.builder_make(allocator)
	for part in parts {
		strings.write_string(&b, part)
	}
	msg := strings.to_string(b)
	debug_write_to_debug_buffer(msg)
	delete(msg, allocator)
}

// hook_manager_exec runs one hook's commands with hook_param* env vars
// (C++ HookData::exec). Errors from the command manager propagate with
// their owned message.
hook_manager_exec :: proc(
	data: ^Hook_Data,
	hook: Hook,
	param: string,
	ctx: ^Context,
	captures: ^Regex_Match_Results,
	allocator := context.allocator,
) -> (Command_Manager_Error, string) {
	debug_opt := option_manager_get_checked(context_options(ctx), "debug")
	debug_flags := debug_opt.value.(Option_types_Debug_Flags)
	if .Hooks in debug_flags {
		hook_manager_debug_write({"hook ", hook_manager_hook_name(hook), "(", param, ")/", data.group}, allocator)
	}

	env_vars := make(Env_Var_Map, 0, allocator)
	defer {
		for key, value in env_vars {
			delete(key, allocator)
			delete(value, allocator)
		}
		delete(env_vars)
	}
	env_vars[strings.clone("hook_param", allocator)] = strings.clone(param, allocator)
	for i in 0 ..< regex_match_results_size(captures) {
		b := strings.builder_make(allocator)
		strings.write_string(&b, "hook_param_capture_")
		strings.write_int(&b, i)
		key := strings.to_string(b)
		env_vars[key] = strings.clone(regex_match_results_substring(captures, param, i), allocator)
	}
	for nc in data.filter.compiled.named_captures {
		b := strings.builder_make(allocator)
		strings.write_string(&b, "hook_param_capture_")
		strings.write_string(&b, nc.name)
		key := strings.to_string(b)
		env_vars[key] = strings.clone(regex_match_results_substring(captures, param, nc.index), allocator)
	}

	shell_ctx := Shell_Context{env_vars = env_vars}
	return command_manager_execute(command_manager_instance(), data.commands, ctx, &shell_ctx, allocator)
}

// hook_manager_add_hook registers a hook (C++ HookManager::add_hook).
// group and commands are cloned; filter ownership transfers to the
// manager. ModuleLoaded hooks also fire immediately for already-loaded
// modules (an Once hook then returns without storing); execution errors
// propagate with their owned message.
hook_manager_add_hook :: proc(
	m: ^Hook_Manager,
	hook: Hook,
	group: string,
	flags: Hook_Flags,
	filter: Regex,
	commands: string,
	ctx: ^Context,
) -> (Command_Manager_Error, string) {
	data := new(Hook_Data, m.allocator)
	data.group = strings.clone(group, m.allocator)
	data.flags = flags
	data.filter = filter
	data.commands = strings.clone(commands, m.allocator)
	if hook == .Module_Loaded {
		only_always := utils_nested_bool_is_set(ctx.hooks_disabled)
		disabled_opt := option_manager_get_checked(context_options(ctx), "disabled_hooks")
		disabled := disabled_opt.value.(Regex)
		modules := command_manager_loaded_modules(command_manager_instance())
		defer {
			for name in modules {
				delete(name)
			}
			delete(modules)
		}
		for name in modules {
			captures, should := hook_manager_should_run(data, only_always, &disabled, name)
			if !should {
				regex_match_results_destroy(&captures)
				continue
			}
			err, msg := hook_manager_exec(data, hook, name, ctx, &captures)
			regex_match_results_destroy(&captures)
			if err != .None {
				hook_manager_free_data(data, m.allocator)
				return err, msg
			}
			if .Once in data.flags {
				hook_manager_free_data(data, m.allocator)
				return .None, ""
			}
		}
	}
	append(&m.hooks[int(hook)], data)
	return .None, ""
}

// hook_manager_remove_hooks drops every hook whose group fully matches
// the pattern, parking them in the trash (C++ remove_hooks).
hook_manager_remove_hooks :: proc(m: ^Hook_Manager, pattern: ^Regex) {
	for i in 0 ..< len(m.hooks) {
		j := len(m.hooks[i]) - 1
		for j >= 0 {
			if regex_match_simple(m.hooks[i][j].group, pattern) {
				append(&m.hooks_trash, m.hooks[i][j])
				ordered_remove(&m.hooks[i], j)
			}
			j -= 1
		}
	}
}

// hook_manager_complete_hook_group completes a hook group name over this
// scope's groups (C++ complete_hook_group; parents are not consulted).
// Candidates are owned.
hook_manager_complete_hook_group :: proc(
	m: ^Hook_Manager,
	prefix: string,
	pos_in_token: Units_ByteCount,
	allocator := context.allocator,
) -> Candidate_List {
	groups := make([dynamic]string, 0, allocator)
	defer delete(groups)
	for i in 0 ..< len(m.hooks) {
		for data in m.hooks[i] {
			known := false
			for g in groups {
				if g == data.group {
					known = true
					break
				}
			}
			if !known {
				append(&groups, data.group)
			}
		}
	}
	return completion_complete_strings(prefix, pos_in_token, groups[:], allocator)
}

// hook_manager_run_hook runs a hook's commands (C++ run_hook): parent
// scope hooks first, then this scope's, with a recursion guard. Per-hook
// errors are reported to the *debug* buffer and the status line; nothing
// propagates.
hook_manager_run_hook :: proc(m: ^Hook_Manager, hook: Hook, param: string, ctx: ^Context) {
	only_always := utils_nested_bool_is_set(ctx.hooks_disabled)
	disabled_opt := option_manager_get_checked(context_options(ctx), "disabled_hooks")
	disabled := disabled_opt.value.(Regex)
	debug_opt := option_manager_get_checked(context_options(ctx), "debug")
	debug_flags := debug_opt.value.(Option_types_Debug_Flags)

	to_run := make([dynamic]Hook_Manager_To_Run, 0, context.allocator)
	defer {
		for &tr in to_run {
			regex_match_results_destroy(&tr.captures)
		}
		delete(to_run)
	}
	for data in m.hooks[int(hook)] {
		captures, should := hook_manager_should_run(data, only_always, &disabled, param)
		if should {
			append(&to_run, Hook_Manager_To_Run{hook = data, captures = captures})
		} else {
			regex_match_results_destroy(&captures)
		}
	}

	hook_name := hook_manager_hook_name(hook)
	for rh in m.running_hooks {
		if rh.hook == hook && rh.param == param {
			hook_manager_debug_write({"recursive call of hook ", hook_name, "/", param, ", not executing"}, context.allocator)
			return
		}
	}

	append(&m.running_hooks, Hook_Running{hook = hook, param = param})
	defer {
		pop(&m.running_hooks)
		if len(m.running_hooks) == 0 {
			for data in m.hooks_trash {
				hook_manager_free_data(data, m.allocator)
			}
			clear(&m.hooks_trash)
		}
	}

	if m.parent != nil {
		hook_manager_run_hook(m.parent, hook, param, ctx)
	}

	profile_on := .Profile in debug_flags
	profile_start := clock_now()

	hook_error := false
	for &tr in to_run {
		trashed := false
		for t in m.hooks_trash {
			if t == tr.hook {
				trashed = true
				break
			}
		}
		if trashed {
			continue
		}
		err, msg := hook_manager_exec(tr.hook, hook, param, ctx, &tr.captures)
		if err != .None {
			hook_error = true
			hook_manager_debug_write(
				{"error running hook ", hook_name, "(", param, ")/", tr.hook.group, ": ", msg},
				context.allocator,
			)
			delete(msg, context.allocator)
		} else if .Once in tr.hook.flags {
			hook_list := &m.hooks[int(hook)]
			for idx in 0 ..< len(hook_list) {
				if hook_list[idx] == tr.hook {
					append(&m.hooks_trash, hook_list[idx])
					ordered_remove(hook_list, idx)
					break
				}
			}
		}
	}

	if profile_on {
		microseconds := int(clock_diff(profile_start, clock_now())) / 1000
		b := strings.builder_make(context.allocator)
		strings.write_string(&b, "hook '")
		strings.write_string(&b, hook_name)
		strings.write_string(&b, "(")
		strings.write_string(&b, param)
		strings.write_string(&b, ")' took ")
		strings.write_int(&b, microseconds)
		strings.write_string(&b, " us")
		msg := strings.to_string(b)
		debug_write_to_debug_buffer(msg)
		delete(msg, context.allocator)
	}

	if hook_error {
		face := Face{}
		if found_face, face_err := face_registry_lookup(context_faces(ctx), "Error", context.allocator); face_err == .None {
			face = found_face
		}
		b := strings.builder_make(context.allocator)
		strings.write_string(&b, "Error running hooks for '")
		strings.write_string(&b, hook_name)
		strings.write_string(&b, "' '")
		strings.write_string(&b, param)
		strings.write_string(&b, "', see *debug* buffer")
		text := strings.to_string(b)
		defer delete(text, context.allocator)
		atoms := make([dynamic]Display_Atom, 0, 1, context.allocator)
		defer delete(atoms)
		append(&atoms, Display_Atom{face = face, type = .Text, text = text})
		line := Display_Line{atoms = atoms}
		context_print_status(ctx, Display_Line{}, line, Units_ColumnCount(-1), User_Interface_Status_Style.Status)
	}
}

// ---------------------------------------------------------------------------
// STUBS: called-but-unmerged procs (STUB protocol). Shared stubs
// (debug_write_to_debug_buffer, context_options, option_manager_get,
// option_manager_get_debug_flags, completion_complete_strings) live in
// command_manager.odin.
// ---------------------------------------------------------------------------

// C++ Context::faces (context.hh).
// C++ Context::print_status(DisplayLine) (context.hh).
