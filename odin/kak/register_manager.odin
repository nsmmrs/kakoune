// Register manager ported from src/register_manager.{hh,cc}: value
// registers (static, dynamic, history, null) behind Register_VTable plus
// the RegisterManager singleton.
//
// Register content borrows the set values' strings (like the C++
// refcounted Strings); only the content arrays are owned. Destroy
// registers with register_manager_destroy_register using the same
// allocator passed to the make_* constructor.
package kak

import "core:mem"
import "core:strings"

// Register_Manager_Error reports register lookup failures.
Register_Manager_Error :: enum {
	None,
	No_Such_Register,
}

// Register_Manager_Static is the C++ StaticRegister data: a named,
// directly assigned value list.
@(private = "file")
Register_Manager_Static :: struct {
	register: ^Register,
	name:     string,
	content:  [dynamic]string,
}

// Register_Manager_History is the C++ HistoryRegister data: a named,
// most-recent-first value list.
@(private = "file")
Register_Manager_History :: struct {
	register: ^Register,
	name:     string,
	content:  [dynamic]string,
}

// Register_Manager_Getter computes a dynamic register's owned value list
// (port of the DynamicRegister getter: StringList(const Context&)).
Register_Manager_Getter :: #type proc(ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string

// Register_Manager_Setter handles a dynamic register assignment (port of
// the DynamicRegister setter: void(Context&, ConstArrayView<String>)).
Register_Manager_Setter :: #type proc(ctx: ^Context, values: []string)

// Register_Manager_Dynamic is the C++ DynamicRegister data. The getter
// and setter come from the caller (register_registers in main.cc).
@(private = "file")
Register_Manager_Dynamic :: struct {
	register: ^Register,
	name:     string,
	content:  [dynamic]string,
	getter:   Register_Manager_Getter,
	setter:   Register_Manager_Setter,
}

// Register_Manager_Null is the C++ NullRegister data (empty).
@(private = "file")
Register_Manager_Null :: struct {
	register: ^Register,
}

// register_manager_empty_content mirrors C++ String::ms_empty: the shared
// one-empty-string backing for empty register reads.
@(private = "file")
register_manager_empty_content := [1]string{""}

// register_manager_run_modified_hook runs RegisterModified unless the
// register disabled it (the m_disable_modified_hook check in the C++
// setters). Calls STUBBED hook procs; tests disable the hook instead.
@(private = "file")
register_manager_run_modified_hook :: proc(reg: ^Register, name: string, ctx: ^Context) {
	if utils_nested_bool_is_set(reg.disable_modified_hook) {
		return
	}
	hooks := context_hooks(ctx)
	hook_manager_run_hook(hooks, .Register_Modified, name, ctx)
}

@(private = "file")
register_manager_static_set :: proc(data: rawptr, ctx: ^Context, values: []string, restoring: bool) {
	r := cast(^Register_Manager_Static)data
	clear(&r.content)
	append(&r.content, ..values)
	register_manager_run_modified_hook(r.register, r.name, ctx)
}

@(private = "file")
register_manager_static_get :: proc(data: rawptr, ctx: ^Context, allocator: mem.Allocator) -> []string {
	r := cast(^Register_Manager_Static)data
	if len(r.content) == 0 {
		return register_manager_empty_content[:]
	}
	return r.content[:]
}

@(private = "file")
register_manager_static_get_main :: proc(data: rawptr, ctx: ^Context, main_index: int) -> string {
	r := cast(^Register_Manager_Static)data
	content := r.content[:]
	if len(content) == 0 {
		return ""
	}
	return content[clamp(main_index, 0, len(content) - 1)]
}

@(private = "file")
register_manager_static_destroy :: proc(data: rawptr, allocator: mem.Allocator) {
	r := cast(^Register_Manager_Static)data
	delete(r.content)
	free(r, allocator)
}

@(private = "file")
register_manager_history_set :: proc(data: rawptr, ctx: ^Context, values: []string, restoring: bool) {
	r := cast(^Register_Manager_History)data
	if restoring {
		clear(&r.content)
		append(&r.content, ..values)
		w := 0
		for s in r.content {
			if len(s) > 0 {
				r.content[w] = s
				w += 1
			}
		}
		resize(&r.content, w)
		register_manager_run_modified_hook(r.register, r.name, ctx)
		return
	}
	for i := len(values) - 1; i >= 0; i -= 1 {
		entry := values[i]
		w := 0
		for s in r.content {
			if s != entry {
				r.content[w] = s
				w += 1
			}
		}
		resize(&r.content, w)
		inject_at(&r.content, 0, entry)
	}
	if len(r.content) > 1000 {
		resize(&r.content, 1000)
	}
	register_manager_run_modified_hook(r.register, r.name, ctx)
}

@(private = "file")
register_manager_history_get :: proc(data: rawptr, ctx: ^Context, allocator: mem.Allocator) -> []string {
	r := cast(^Register_Manager_History)data
	if len(r.content) == 0 {
		return register_manager_empty_content[:]
	}
	return r.content[:]
}

@(private = "file")
register_manager_history_get_main :: proc(data: rawptr, ctx: ^Context, main_index: int) -> string {
	r := cast(^Register_Manager_History)data
	if len(r.content) == 0 {
		return ""
	}
	return r.content[0]
}

@(private = "file")
register_manager_history_destroy :: proc(data: rawptr, allocator: mem.Allocator) {
	r := cast(^Register_Manager_History)data
	delete(r.content)
	free(r, allocator)
}

@(private = "file")
register_manager_dynamic_set :: proc(data: rawptr, ctx: ^Context, values: []string, restoring: bool) {
	r := cast(^Register_Manager_Dynamic)data
	r.setter(ctx, values)
}

@(private = "file")
register_manager_dynamic_get :: proc(data: rawptr, ctx: ^Context, allocator: mem.Allocator) -> []string {
	r := cast(^Register_Manager_Dynamic)data
	delete(r.content)
	r.content = r.getter(ctx, allocator)
	if len(r.content) == 0 {
		return register_manager_empty_content[:]
	}
	return r.content[:]
}

@(private = "file")
register_manager_dynamic_get_main :: proc(data: rawptr, ctx: ^Context, main_index: int) -> string {
	r := cast(^Register_Manager_Dynamic)data
	content := r.content[:]
	if len(content) == 0 {
		return ""
	}
	return content[clamp(main_index, 0, len(content) - 1)]
}

@(private = "file")
register_manager_dynamic_destroy :: proc(data: rawptr, allocator: mem.Allocator) {
	r := cast(^Register_Manager_Dynamic)data
	delete(r.content)
	free(r, allocator)
}

// register_manager_readonly_setter is the C++ make_dyn_reg single-func
// setter: assigning a read-only dynamic register is an error. The C++
// throws; the vtable set returns void, so this panics until the
// coordinator makes register assignment fallible (see final report).
@(private = "file")
register_manager_readonly_setter :: proc(ctx: ^Context, values: []string) {
	panic("this register is not assignable")
}

@(private = "file")
register_manager_null_set :: proc(data: rawptr, ctx: ^Context, values: []string, restoring: bool) {}

@(private = "file")
register_manager_null_get :: proc(data: rawptr, ctx: ^Context, allocator: mem.Allocator) -> []string {
	return register_manager_empty_content[:]
}

@(private = "file")
register_manager_null_get_main :: proc(data: rawptr, ctx: ^Context, main_index: int) -> string {
	return ""
}

@(private = "file")
register_manager_null_destroy :: proc(data: rawptr, allocator: mem.Allocator) {
	r := cast(^Register_Manager_Null)data
	free(r, allocator)
}

@(private = "file")
register_manager_static_vtable := Register_VTable {
	set      = register_manager_static_set,
	get      = register_manager_static_get,
	get_main = register_manager_static_get_main,
	destroy  = register_manager_static_destroy,
}

@(private = "file")
register_manager_history_vtable := Register_VTable {
	set      = register_manager_history_set,
	get      = register_manager_history_get,
	get_main = register_manager_history_get_main,
	destroy  = register_manager_history_destroy,
}

@(private = "file")
register_manager_dynamic_vtable := Register_VTable {
	set      = register_manager_dynamic_set,
	get      = register_manager_dynamic_get,
	get_main = register_manager_dynamic_get_main,
	destroy  = register_manager_dynamic_destroy,
}

@(private = "file")
register_manager_null_vtable := Register_VTable {
	set      = register_manager_null_set,
	get      = register_manager_null_get,
	get_main = register_manager_null_get_main,
	destroy  = register_manager_null_destroy,
}

// register_manager_make_static builds an owned StaticRegister for name.
register_manager_make_static :: proc(name: string, allocator := context.allocator) -> ^Register {
	reg := new(Register, allocator)
	data := new(Register_Manager_Static, allocator)
	data.register = reg
	data.name = name
	data.content = make([dynamic]string, allocator)
	reg.vtable = &register_manager_static_vtable
	reg.data = data
	return reg
}

// register_manager_make_history builds an owned HistoryRegister for name.
register_manager_make_history :: proc(name: string, allocator := context.allocator) -> ^Register {
	reg := new(Register, allocator)
	data := new(Register_Manager_History, allocator)
	data.register = reg
	data.name = name
	data.content = make([dynamic]string, allocator)
	reg.vtable = &register_manager_history_vtable
	reg.data = data
	return reg
}

// register_manager_make_dynamic builds an owned DynamicRegister (port of
// the two-func make_dyn_reg).
register_manager_make_dynamic :: proc(
	name: string,
	getter: Register_Manager_Getter,
	setter: Register_Manager_Setter,
	allocator := context.allocator,
) -> ^Register {
	reg := new(Register, allocator)
	data := new(Register_Manager_Dynamic, allocator)
	data.register = reg
	data.name = name
	data.content = make([dynamic]string, allocator)
	data.getter = getter
	data.setter = setter
	reg.vtable = &register_manager_dynamic_vtable
	reg.data = data
	return reg
}

// register_manager_make_dynamic_readonly builds an owned read-only
// DynamicRegister (port of the single-func make_dyn_reg).
register_manager_make_dynamic_readonly :: proc(
	name: string,
	getter: Register_Manager_Getter,
	allocator := context.allocator,
) -> ^Register {
	return register_manager_make_dynamic(name, getter, register_manager_readonly_setter, allocator)
}

// register_manager_make_null builds an owned NullRegister.
register_manager_make_null :: proc(allocator := context.allocator) -> ^Register {
	reg := new(Register, allocator)
	data := new(Register_Manager_Null, allocator)
	data.register = reg
	reg.vtable = &register_manager_null_vtable
	reg.data = data
	return reg
}

// register_manager_destroy_register frees a register built by make_*
// (same allocator). Content strings are borrowed and not freed.
register_manager_destroy_register :: proc(reg: ^Register, allocator := context.allocator) {
	reg.vtable.destroy(reg.data, allocator)
	free(reg, allocator)
}

// register_manager_set assigns values (port of Register::set).
register_manager_set :: proc(reg: ^Register, ctx: ^Context, values: []string, restoring := false) {
	reg.vtable.set(reg.data, ctx, values, restoring)
}

// register_manager_get_values reads the value list (port of Register::get;
// empty registers read as one empty string). The result borrows register
// memory except for dynamic registers, whose content is refreshed.
register_manager_get_values :: proc(
	reg: ^Register,
	ctx: ^Context,
	allocator := context.allocator,
) -> []string {
	return reg.vtable.get(reg.data, ctx, allocator)
}

// register_manager_get_main reads the main selection's value (port of
// Register::get_main).
register_manager_get_main :: proc(reg: ^Register, ctx: ^Context, main_index: int) -> string {
	return reg.vtable.get_main(reg.data, ctx, main_index)
}

// register_manager_save copies the value list (port of Register::save).
// The array is owned; the strings are borrowed.
register_manager_save :: proc(
	reg: ^Register,
	ctx: ^Context,
	allocator := context.allocator,
) -> [dynamic]string {
	values := register_manager_get_values(reg, ctx, allocator)
	res := make([dynamic]string, len(values), allocator)
	copy(res[:], values)
	return res
}

// register_manager_restore assigns a saved value list (port of
// Register::restore).
register_manager_restore :: proc(reg: ^Register, ctx: ^Context, info: []string) {
	register_manager_set(reg, ctx, info, true)
}

// register_manager_modified_hook_disabled exposes the hook guard (port of
// Register::modified_hook_disabled).
register_manager_modified_hook_disabled :: proc(reg: ^Register) -> ^Utils_Nested_Bool {
	return &reg.disable_modified_hook
}

// Register_Manager_Name_Entry is one long register name (port of the
// static reg_names map).
@(private = "file")
Register_Manager_Name_Entry :: struct {
	name: string,
	code: rune,
}

@(private = "file")
register_manager_reg_names := [10]Register_Manager_Name_Entry{
	{"slash", '/'},
	{"dquote", '"'},
	{"pipe", '|'},
	{"caret", '^'},
	{"arobase", '@'},
	{"percent", '%'},
	{"dot", '.'},
	{"hash", '#'},
	{"underscore", '_'},
	{"colon", ':'},
}

// Register_Manager_Instance is the RegisterManager singleton.
Register_Manager_Instance: Register_Manager

// register_manager_has_instance reports whether the singleton was
// initialized (port of Singleton::has_instance).
register_manager_has_instance := false

// register_manager_instance returns the singleton (port of
// Singleton::instance).
register_manager_instance :: proc() -> ^Register_Manager {
	assert(register_manager_has_instance)
	return &Register_Manager_Instance
}

// register_manager_instance_init initializes the singleton.
register_manager_instance_init :: proc(allocator := context.allocator) {
	Register_Manager_Instance = register_manager_make(allocator)
	register_manager_has_instance = true
}

// register_manager_make builds an empty register manager.
register_manager_make :: proc(allocator := context.allocator) -> Register_Manager {
	return Register_Manager {
		registers = make(map[rune]^Register, 8, allocator),
		allocator = allocator,
	}
}

// register_manager_destroy frees the manager and its registers.
register_manager_destroy :: proc(m: ^Register_Manager) {
	for _, reg in m.registers {
		register_manager_destroy_register(reg, m.allocator)
	}
	delete(m.registers)
	m^ = Register_Manager{}
}

// register_manager_add installs a register (port of
// RegisterManager::add_register). The manager takes ownership.
register_manager_add :: proc(m: ^Register_Manager, c: rune, reg: ^Register) {
	assert(reg != nil)
	assert(m.registers[c] == nil)
	m.registers[c] = reg
}

// register_manager_get looks a register up by codepoint, lowercased
// (port of RegisterManager::operator[](Codepoint)).
register_manager_get :: proc(
	m: ^Register_Manager,
	c: rune,
) -> (
	reg: ^Register,
	err: Register_Manager_Error,
) {
	lower := unicode_to_lower(c)
	if r, ok := m.registers[lower]; ok {
		return r, .None
	}
	return nil, .No_Such_Register
}

// register_manager_get_by_name looks a register up by name: a single
// character or a long name like "slash" (port of
// RegisterManager::operator[](StringView)).
register_manager_get_by_name :: proc(
	m: ^Register_Manager,
	reg: string,
) -> (
	found: ^Register,
	err: Register_Manager_Error,
) {
	if len(reg) == 1 {
		return register_manager_get(m, rune(reg[0]))
	}
	for entry in register_manager_reg_names {
		if entry.name == reg {
			return register_manager_get(m, entry.code)
		}
	}
	return nil, .No_Such_Register
}

// register_manager_complete_name completes a register name (port of
// RegisterManager::complete_register_name). Candidates borrow the
// static name table; free only the returned array.
register_manager_complete_name :: proc(
	m: ^Register_Manager,
	prefix: string,
	cursor_pos: Units_ByteCount,
	allocator := context.allocator,
) -> Candidate_List {
	names := make([dynamic]string, 0, len(register_manager_reg_names), context.temp_allocator)
	for entry in register_manager_reg_names {
		append(&names, entry.name)
	}
	return completion_complete(prefix, cursor_pos, names[:], allocator)
}

// ---------------------------------------------------------------------------
// Remainder implementations (C++ names from register_manager.hh)
// ---------------------------------------------------------------------------

// register_manager_get_strings returns the named register's values (C++
// RegisterManager::operator[] + Register::get, combined). The array is
// owned; the strings borrow register content, like register_manager_save.
// Deviation: the C++ throws runtime_error for an unknown register but
// this signature (fixed by the STUB contract) has no error channel, so
// it panics with the C++ message instead.
register_manager_get_strings :: proc(
	reg: string,
	ctx: ^Context,
	allocator := context.allocator,
) -> [dynamic]string {
	found, err := register_manager_get_by_name(register_manager_instance(), reg)
	if err != .None {
		panic(strings.concatenate({"no such register: '", reg, "'"}))
	}
	return register_manager_save(found, ctx, allocator)
}

// register_manager_complete_register_name completes a register name
// (C++ RegisterManager::complete_register_name). Candidates borrow the
// static name table; free only the returned array.
register_manager_complete_register_name :: proc(
	prefix: string,
	cursor_pos: Units_ByteCount,
	allocator := context.allocator,
) -> Candidate_List {
	return register_manager_complete_name(register_manager_instance(), prefix, cursor_pos, allocator)
}
