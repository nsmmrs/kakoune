// Shared types for the buffer-core knot (wave 5+).
//
// OWNERSHIP: coordinator-only. Port agents MUST NOT modify this file; they
// read it and implement procedures in their own <module>.odin files. If a
// field or type is missing, the agent reports it and the coordinator amends
// this file (agents re-copy it into their worktree).
//
// WHY THIS FILE EXISTS: Buffer, Scope, Context, Window, Client and the
// managers reference each other cyclically (through pointers). Odin has no
// forward declarations, so all mutually-referential struct/enum/callback
// declarations live here, in one place, owned by one author. Agents then
// work in parallel without merge conflicts.
//
// CONVENTIONS USED HERE (from the C++ mapping):
//   SafePtr<T>/UniquePtr<T>/T*/T& (observed) -> ^T (SafePtr is debug-only
//       refcount asserts in C++; release builds use raw pointers).
//   UniquePtr<T> (owned) -> ^T allocated with new(), freed by an explicit
//       destroy proc in the owning module. Never copy owning structs.
//   std::function/Function/FunctionRef -> <Name>_Callback struct of
//       {call, data, destroy}: call is always present, destroy may be nil.
//   Virtual hierarchies (Option excluded) -> {vtable, data} structs; the
//       vtable struct is declared here, concrete data structs live in the
//       implementing agent's file (private), vtables are package-level vars.
//   Option's TypedOption<T> hierarchy -> Option_Value union (closed: the
//       12 types below are every declare_option<T> instantiation in src/).
//   String/SharedString/StringDataPtr/StringView -> string. Kakoune strings
//       are immutable values; Buffer lines own them, views borrow them.
//   Vector<T>/Array<T>/TimestampedList<T> -> [dynamic]T / [N]T /
//       Option_Timestamped_List(T). HashMap<K,V> -> map[K]V.
//   Singleton<T> -> package-level instance + accessor in the owning module.
package kak

import "core:mem"

// ---------------------------------------------------------------------------
// Scope
// ---------------------------------------------------------------------------

// Scope_Data is C++ Scope::Data (scope.cc): the six per-scope managers,
// constructed with the parent scope's managers. Heap-allocated, owned by Scope.
Scope_Data :: struct {
	options:      Option_Manager,
	hooks:        Hook_Manager,
	keymaps:      Keymap_Manager,
	aliases:      Alias_Registry,
	faces:        Face_Registry,
	highlighters: Highlighters,
}

// Scope is the C++ Scope: embed with `using scope: Scope`.
Scope :: struct {
	data: ^Scope_Data,
}

// Global_Scope_Data is C++ GlobalScope::GlobalData (scope.cc).
Global_Scope_Data :: struct {
	parent:          ^Scope,
	option_registry: Options_Registry,
}

// Global_Scope is the C++ GlobalScope (the Scope base embeds first).
Global_Scope :: struct {
	using scope: Scope,
	global_data: ^Global_Scope_Data,
}

// Local_Scope is C++ LocalScope (local_scope.hh): a Scope pushed on the
// context's local scope stack for the duration of a command.
Local_Scope :: struct {
	using scope: Scope,
	ctx:     ^Context,
}

// ---------------------------------------------------------------------------
// Options
// ---------------------------------------------------------------------------

Option_Flags_Flag :: enum {
	Hidden,
}
Option_Flags :: bit_set[Option_Flags_Flag; u8]

// Option_Desc is C++ OptionDesc. Instances are heap-allocated and owned by
// Options_Registry; Option holds a pointer (stable across registry growth).
Option_Desc :: struct {
	name:      string,
	docstring: string,
	flags:     Option_Flags,
}

// Option_Value is the closed set of option value types: every
// declare_option instantiation in src/main.cc (25 builtins, including
// deduced types) plus the 9 :declare-option value types in
// src/commands.cc. Replaces TypedOption<T>.
Option_Value :: union {
	int,
	bool,
	string,
	[dynamic]string,
	[dynamic]int,
	[dynamic]rune,
	Regex,
	Coord_Display,
	Insert_Completer_Completion_List,
	Option_Timestamped_List(Line_And_Spec),
	Option_Timestamped_List(Range_And_String),
	map[string]string,
	Eol_Format,
	Final_Eol,
	Byte_Order_Mark,
	Auto_Info,
	Auto_Complete,
	[dynamic]Insert_Completer_Desc,
	Autoreload,
	File_Write_Method,
	Option_types_Debug_Flags,
}

// Option_Validator validates a candidate value, returning "" when valid or
// a (usually static) message describing the violation. Replaces the
// TypedCheckedOption validator function pointer.
Option_Validator :: #type proc(value: Option_Value) -> string

// Option is C++ Option/TypedOption: a named, typed, validated value.
Option :: struct {
	desc:      ^Option_Desc,
	manager:   ^Option_Manager,
	value:     Option_Value,
	validator: Option_Validator,
	allocator: mem.Allocator,
}

// Option_Manager is C++ OptionManager. Options are heap objects (^Option)
// for pointer stability; the map owns them.
Option_Manager :: struct {
	options:   map[string]^Option,
	parent:    ^Option_Manager,
	watchers:  [dynamic]Option_Watcher,
	allocator: mem.Allocator,
}

// Options_Registry is C++ OptionsRegistry (lives in GlobalScope).
Options_Registry :: struct {
	global_manager: ^Option_Manager,
	descs:          [dynamic]^Option_Desc,
	trash:          [dynamic]^Option,
	allocator:      mem.Allocator,
}

// ---------------------------------------------------------------------------
// Hooks
// ---------------------------------------------------------------------------

// Hook is C++ Hook (hook_manager.hh). Order matches the C++ declaration.
Hook :: enum {
	Buf_Create,
	Buf_New_File,
	Buf_Open_File,
	Buf_Close,
	Buf_Write_Post,
	Buf_Reload,
	Buf_Write_Pre,
	Buf_Open_Fifo,
	Buf_Close_Fifo,
	Buf_Read_Fifo,
	Buf_Set_Option,
	Client_Create,
	Client_Close,
	Client_Renamed,
	Session_Renamed,
	Insert_Char,
	Insert_Delete,
	Insert_Idle,
	Insert_Key,
	Insert_Move,
	Insert_Completion_Hide,
	Insert_Completion_Show,
	Kak_Begin,
	Kak_End,
	Focus_In,
	Focus_Out,
	Global_Set_Option,
	Runtime_Error,
	Prompt_Idle,
	Normal_Idle,
	Next_Key_Idle,
	Normal_Key,
	Mode_Change,
	Enter_Directory,
	Raw_Key,
	Register_Modified,
	Win_Close,
	Win_Create,
	Win_Display,
	Win_Resize,
	Win_Set_Option,
	Module_Loaded,
	User,
}

Hook_Flags_Flag :: enum {
	Always,
	Once,
}
Hook_Flags :: bit_set[Hook_Flags_Flag; u8]

// Hook_Data is C++ HookManager::HookData (hook_manager.cc).
Hook_Data :: struct {
	group:    string,
	flags:    Hook_Flags,
	filter:   Regex,
	commands: string,
}

// Hook_Running tracks one in-flight run_hook (recursion guard).
Hook_Running :: struct {
	hook:  Hook,
	param: string,
}

// Hook_Manager is C++ HookManager: one hook list per Hook enumerator.
Hook_Manager :: struct {
	parent:        ^Hook_Manager,
	hooks:         [43][dynamic]^Hook_Data, // 43 = number of Hook enumerators (see knot_test)
	running_hooks: [dynamic]Hook_Running,
	hooks_trash:   [dynamic]^Hook_Data,
	allocator:     mem.Allocator,
}

// ---------------------------------------------------------------------------
// Aliases
// ---------------------------------------------------------------------------

// Alias_Registry is C++ AliasRegistry (alias_registry.hh).
Alias_Registry :: struct {
	parent:    ^Alias_Registry,
	aliases:   map[string]string,
	allocator: mem.Allocator,
}

// ---------------------------------------------------------------------------
// Highlighters
// ---------------------------------------------------------------------------

Highlight_Pass_Flag :: enum {
	Replace,
	Wrap,
	Move,
	Colorize,
}
Highlight_Pass :: bit_set[Highlight_Pass_Flag; u8]

// Highlight_Context is C++ HighlightContext.
Highlight_Context :: struct {
	ctx:      ^Context,
	setup:        ^Display_Setup,
	pass:         Highlight_Pass,
	disabled_ids: []string,
}

// Highlighter_VTable ports the virtual interface of C++ Highlighter.
// data is the concrete highlighter (agent-private struct); destroy frees it.
Highlighter_VTable :: struct {
	do_highlight:             proc(data: rawptr, ctx: Highlight_Context, display_buffer: ^Display_Buffer, buffer_range: Buffer_Range),
	do_compute_display_setup: proc(data: rawptr, ctx: Highlight_Context, setup: ^Display_Setup),
	has_children:             proc(data: rawptr) -> bool,
	get_child:                proc(data: rawptr, path: string, allocator: mem.Allocator) -> ^Highlighter,
	add_child:                proc(data: rawptr, name: string, child: ^Highlighter, override: bool),
	remove_child:             proc(data: rawptr, id: string),
	complete_child:           proc(data: rawptr, path: string, cursor_pos: Units_ByteCount, group: bool, allocator: mem.Allocator) -> Completions,
	fill_unique_ids:          proc(data: rawptr, unique_ids: ^[dynamic]string),
	destroy:                  proc(data: rawptr, allocator: mem.Allocator),
}

// Highlighter is C++ Highlighter: vtable + passes + opaque concrete data.
Highlighter :: struct {
	vtable: ^Highlighter_VTable,
	passes: Highlight_Pass,
	data:   rawptr,
}

// Highlighter_Group is C++ HighlighterGroup. Children are owned.
Highlighter_Group :: struct {
	using base:  Highlighter,
	highlighters: map[string]^Highlighter,
	allocator:   mem.Allocator,
}

// Highlighters is C++ Highlighters (per-scope root group with parent chain).
Highlighters :: struct {
	parent: ^Highlighters,
	group:  Highlighter_Group,
}

Highlighter_Params :: []string
// Highlighter_Factory builds a concrete highlighter; parent is the owning
// group (nil for roots). Replaces C++ HighlighterFactory.
Highlighter_Factory :: #type proc(params: Highlighter_Params, parent: ^Highlighter, allocator: mem.Allocator) -> ^Highlighter

Highlighter_Desc :: struct {
	docstring: string,
	params:    Parameters_Parser_Desc,
}

Highlighter_Factory_And_Description :: struct {
	factory:     Highlighter_Factory,
	description: ^Highlighter_Desc,
}

// Highlighter_Registry is C++ HighlighterRegistry (a singleton map).
Highlighter_Registry :: map[string]Highlighter_Factory_And_Description

// ---------------------------------------------------------------------------
// Registers
// ---------------------------------------------------------------------------

// Register_VTable ports the virtual interface of C++ Register.
Register_VTable :: struct {
	set:      proc(data: rawptr, ctx: ^Context, values: []string, restoring: bool),
	get:      proc(data: rawptr, ctx: ^Context, allocator: mem.Allocator) -> []string,
	get_main: proc(data: rawptr, ctx: ^Context, main_index: int) -> string,
	destroy:  proc(data: rawptr, allocator: mem.Allocator),
}

// Register is C++ Register: vtable + opaque concrete data.
Register :: struct {
	vtable:                 ^Register_VTable,
	data:                   rawptr,
	disable_modified_hook: Utils_Nested_Bool,
}

// Register_Manager is C++ RegisterManager (a singleton map).
Register_Manager :: struct {
	registers: map[rune]^Register,
	allocator: mem.Allocator,
}

// ---------------------------------------------------------------------------
// Completion
// ---------------------------------------------------------------------------

// Candidate_List is C++ CandidateList.
Candidate_List :: [dynamic]string

Completion_Flags_Flag :: enum {
	Quoted,
	Menu,
	No_Empty,
}
Completion_Flags :: bit_set[Completion_Flags_Flag; u8]

// Completions is C++ Completions.
Completions :: struct {
	candidates: Candidate_List,
	start:      Units_ByteCount,
	end:        Units_ByteCount,
	flags:      Completion_Flags,
}

Filename_Flags_Flag :: enum {
	Only_Directories,
	Expand,
}
Filename_Flags :: bit_set[Filename_Flags_Flag; u8]

// ---------------------------------------------------------------------------
// Buffer
// ---------------------------------------------------------------------------

Buffer_Flags_Flag :: enum u16 {
	File,
	New,
	Fifo,
	No_Undo,
	No_Hooks,
	Debug,
	Read_Only,
	No_Buf_Set_Option,
	Locked,
}
Buffer_Flags :: bit_set[Buffer_Flags_Flag; u16]

Eol_Format :: enum {
	Lf,
	Crlf,
}

Byte_Order_Mark :: enum {
	None,
	Utf8,
}

Final_Eol :: enum {
	Present,
	Missing,
	If_Not_Empty,
}

Buffer_Change_Type :: enum {
	Insert,
	Erase,
}

// Buffer_Change is C++ Buffer::Change.
Buffer_Change :: struct {
	type:  Buffer_Change_Type,
	begin: Coord_Buffer,
	end:   Coord_Buffer,
}

Buffer_Modification_Type :: enum {
	Insert,
	Erase,
}

// Buffer_Modification is C++ Buffer::Modification (one atomic change).
Buffer_Modification :: struct {
	type:    Buffer_Modification_Type,
	coord:   Coord_Buffer,
	content: string,
}

// Buffer_History_Id is C++ Buffer::HistoryId. Invalid is -1.
Buffer_History_Id :: distinct int
buffer_HISTORY_FIRST :: Buffer_History_Id(0)
buffer_HISTORY_INVALID :: Buffer_History_Id(-1)

// Buffer_History_Node is C++ Buffer::HistoryNode (one undo-tree node).
Buffer_History_Node :: struct {
	parent:     Buffer_History_Id,
	redo_child: Buffer_History_Id,
	committed:  Clock_Time,
	undo_group: [dynamic]Buffer_Modification,
}

// Buffer_Lines owns the buffer text: one string per line, no newlines.
Buffer_Lines :: [dynamic]string

// Buffer_Range is a half-open [begin, end) range of buffer coords.
Buffer_Range :: Range(Coord_Buffer)

// Buffer_Iterator is C++ BufferIterator: a live (non-owning) view position.
Buffer_Iterator :: struct {
	lines:      []string,
	line:       string,
	line_count: Units_LineCount,
	coord:      Coord_Buffer,
}

// Buffer is C++ Buffer: the in-memory file representation with undo history.
// Owns lines, history, changes, values. Never copy after init.
Buffer :: struct {
	using scope:          Scope,
	lines:                Buffer_Lines,
	filename:             string,
	display_name:         string,
	flags:                Buffer_Flags,
	history:              [dynamic]Buffer_History_Node,
	history_id:           Buffer_History_Id,
	last_save_history_id: Buffer_History_Id,
	current_undo_group:   [dynamic]Buffer_Modification,
	changes:              [dynamic]Buffer_Change,
	fs_status:            File_Fs_Status,
	values:               Value_Map,
	allocator:            mem.Allocator,
}

// ---------------------------------------------------------------------------
// Selection
// ---------------------------------------------------------------------------

// Basic_Selection is C++ BasicSelection: anchor + cursor (with column target).
Basic_Selection :: struct {
	anchor: Coord_Buffer,
	cursor: Coord_Buffer_And_Target,
}

// Selection is C++ Selection: a BasicSelection plus regex captures.
Selection :: struct {
	using basic: Basic_Selection,
	captures:    [dynamic]string,
}

// Selection_List is C++ SelectionList. Owns selections; borrows buffer.
Selection_List :: struct {
	main:       int,
	selections: [dynamic]Selection,
	buffer:     ^Buffer,
	timestamp:  int,
	allocator:  mem.Allocator,
}

Column_Type :: enum {
	Byte,
	Codepoint,
	Display_Column,
}

// ---------------------------------------------------------------------------
// Changes
// ---------------------------------------------------------------------------

// Forward_Changes_Tracker is C++ ForwardChangesTracker (changes.hh).
Forward_Changes_Tracker :: struct {
	cur_pos: Coord_Buffer,
	old_pos: Coord_Buffer,
}

// ---------------------------------------------------------------------------
// Display buffer
// ---------------------------------------------------------------------------

Display_Atom_Type :: enum {
	Range,
	Replaced_Range,
	Text,
}

// Display_Atom is C++ DisplayAtom: one styled run of a display line.
Display_Atom :: struct {
	face:   Face,
	type:   Display_Atom_Type,
	buffer: ^Buffer,
	range:  Buffer_Range,
	text:   string,
}

// Display_Line is C++ DisplayLine: a list of atoms plus their range.
Display_Line :: struct {
	range: Buffer_Range,
	atoms: [dynamic]Display_Atom,
}

Display_Line_List :: [dynamic]Display_Line

// Display_Buffer is C++ DisplayBuffer: the rendered lines of a window.
Display_Buffer :: struct {
	lines:     Display_Line_List,
	range:     Buffer_Range,
	timestamp: int,
}

// Display_Setup is C++ DisplaySetup (highlighter.hh).
Display_Setup :: struct {
	first_line:     Units_LineCount,
	line_count:     Units_LineCount,
	first_column:   Units_ColumnCount,
	widget_columns: Units_ColumnCount,
	scroll_offset:  Coord_Display,
}

// ---------------------------------------------------------------------------
// Word DB
// ---------------------------------------------------------------------------

// Word_DB_Word_Info is C++ WordDB::WordInfo.
Word_DB_Word_Info :: struct {
	word:     string,
	letters:  Ranked_Match_Used_Letters,
	refcount: int,
}

// Word_DB is C++ WordDB: per-buffer word index for completions.
Word_DB :: struct {
	buffer:    ^Buffer,
	timestamp: int,
	words:     map[string]Word_DB_Word_Info,
	lines:     [dynamic]string,
	allocator: mem.Allocator,
}

// ---------------------------------------------------------------------------
// Line modification
// ---------------------------------------------------------------------------

// Line_Modification is C++ LineModification.
Line_Modification :: struct {
	old_line:    Units_LineCount,
	new_line:    Units_LineCount,
	num_removed: Units_LineCount,
	num_added:   Units_LineCount,
}

Line_Range :: Range(Units_LineCount)

// Line_Range_Set is C++ LineRangeSet: a set of tracked line ranges.
Line_Range_Set :: [dynamic]Line_Range

// ---------------------------------------------------------------------------
// Context
// ---------------------------------------------------------------------------

Direction :: enum int {
	Backward = -1,
	Forward  = 1,
}

// Jump_List is C++ JumpList.
Jump_List :: struct {
	jumps:   [dynamic]Selection_List,
	current: int,
}

Context_Flags_Flag :: enum {
	Draft,
}
Context_Flags :: bit_set[Context_Flags_Flag; u8]

// Context_Selection_History_Node is C++ SelectionHistory::HistoryNode:
// an owned SelectionList (which borrows its buffer) plus tree links.
// The list carries selections, main index, buffer and timestamp, so no
// side table is needed (earlier revisions kept a KNOTFIX buffer map).
Context_Selection_History_Node :: struct {
	list:       Selection_List,
	parent:     int,
	redo_child: int,
}

// Context_Selection_History is C++ Context::SelectionHistory.
Context_Selection_History :: struct {
	ctx:    ^Context,
	history:    [dynamic]Context_Selection_History_Node,
	history_id: int,
	staging:    Maybe(Context_Selection_History_Node),
	in_edition: Utils_Nested_Bool,
}

// Context_Last_Select is C++ LastSelectFunc: repeatable last selection.
Context_Last_Select :: struct {
	call:    proc(data: rawptr, ctx: ^Context),
	data:    rawptr,
	destroy: proc(data: rawptr, allocator: mem.Allocator),
}

// Context is C++ Context: links client, window, input handler, selections.
Context :: struct {
	edition_level:      int,
	edition_timestamp:  int,
	flags:              Context_Flags,
	input_handler:      ^Input_Handler,
	window:             ^Window,
	client:             ^Client,
	local_scopes:       [dynamic]^Scope,
	selection_history:  Context_Selection_History,
	name:               string,
	jump_list:          Jump_List,
	last_select:        Context_Last_Select,
	hooks_disabled:     Utils_Nested_Bool,
	keymaps_disabled:   Utils_Nested_Bool,
	ensure_cursor_visible: bool,
	allocator:          mem.Allocator,
}

// Scoped_Edition is C++ ScopedEdition (RAII via make/destroy procs).
Scoped_Edition :: struct {
	ctx: ^Context,
	buffer:  ^Buffer,
}

Scoped_Selection_Edition :: struct {
	ctx: ^Context,
	valid:   bool,
}

// ---------------------------------------------------------------------------
// Normal mode commands
// ---------------------------------------------------------------------------

// Normal_Params is C++ NormalParams.
Normal_Params :: struct {
	count: int,
	reg:   rune,
}

// Normal_Cmd is C++ NormalCmd: a normal-mode builtin.
Normal_Cmd :: struct {
	docstring: string,
	func:      proc(ctx: ^Context, params: Normal_Params),
}

Paste_Mode :: enum {
	Append,
	Insert,
	Replace,
}

// ---------------------------------------------------------------------------
// Window
// ---------------------------------------------------------------------------

// Window_Setup is C++ Window::Setup: cached render inputs for redraw checks.
Window_Setup :: struct {
	position:       Coord_Display,
	dimensions:     Coord_Display,
	timestamp:      int,
	faces_hash:     uint,
	main_selection: int,
	selections:     [dynamic]Basic_Selection,
}

// Window is C++ Window: a view onto a Buffer. Never copy after init.
Window :: struct {
	using scope:          Scope,
	buffer:               ^Buffer,
	client:               ^Client,
	position:             Coord_Display,
	dimensions:           Coord_Display,
	display_buffer:       Display_Buffer,
	builtin_highlighters: Highlighters,
	resize_hook_pending:  bool,
	last_display_setup:   Display_Setup,
	last_setup:           Window_Setup,
	allocator:            mem.Allocator,
}

// ---------------------------------------------------------------------------
// Input handler
// ---------------------------------------------------------------------------

Input_Handler_Insert_Mode :: enum {
	Insert,
	Append,
	Replace,
	Insert_At_Line_Begin,
	Append_At_Line_End,
	Open_Line_Below,
	Open_Line_Above,
}

Prompt_Event :: enum {
	Change,
	Abort,
	Validate,
}

Prompt_Flags_Flag :: enum {
	Password,
	Drop_History_Entries_With_Blank_Prefix,
	Search,
	Command,
}
Prompt_Flags :: bit_set[Prompt_Flags_Flag; u8]

// Prompt_Callback is C++ PromptCallback.
Prompt_Callback :: struct {
	call:    proc(data: rawptr, text: string, event: Prompt_Event, ctx: ^Context),
	data:    rawptr,
	destroy: proc(data: rawptr, allocator: mem.Allocator),
}

// Key_Callback is C++ KeyCallback (on_next_key).
Key_Callback :: struct {
	call:    proc(data: rawptr, key: Keys_Key, ctx: ^Context),
	data:    rawptr,
	destroy: proc(data: rawptr, allocator: mem.Allocator),
}

// Input_Handler_Idle_Callback is the on_next_key idle callback
// (C++ Function<void (Timer&)>): fired when no key arrives in time.
Input_Handler_Idle_Callback :: struct {
	call:    proc(data: rawptr, timer: ^Event_Manager_Timer),
	data:    rawptr,
	destroy: proc(data: rawptr, allocator: mem.Allocator),
}

// Prompt_Completer is C++ PromptCompleter.
Prompt_Completer :: struct {
	call:    proc(data: rawptr, ctx: ^Context, text: string, cursor_pos: Units_ByteCount, allocator: mem.Allocator) -> Completions,
	data:    rawptr,
	destroy: proc(data: rawptr, allocator: mem.Allocator),
}

// Mode_Info is C++ ModeInfo.
Mode_Info :: struct {
	display_line:  Display_Line,
	normal_params: Maybe(Normal_Params),
}

// Input_Handler_Insertion is C++ InputHandler::Insertion (last-insert state).
Input_Handler_Insertion :: struct {
	recording:     Utils_Nested_Bool,
	repeating:     bool,
	mode:          Input_Handler_Insert_Mode,
	keys:          [dynamic]Keys_Key,
	disable_hooks: bool,
	count:         int,
}

// Input_Mode_VTable ports the virtual interface of C++ InputMode
// (input_handler.cc). Concrete modes are agent-private structs.
Input_Mode_VTable :: struct {
	on_key:             proc(data: rawptr, key: Keys_Key),
	paste:              proc(data: rawptr, content: string),
	on_raw_key:         proc(data: rawptr),
	on_enabled:         proc(data: rawptr, from_pop: bool),
	on_disabled:        proc(data: rawptr, from_push: bool),
	refresh_ifn:        proc(data: rawptr),
	take_pending_count: proc(data: rawptr) -> uint,
	mode_info:          proc(data: rawptr, allocator: mem.Allocator) -> Mode_Info,
	keymap_mode:        proc(data: rawptr) -> Keymap_Manager_Mode,
	name:               proc(data: rawptr) -> string,
	destroy:            proc(data: rawptr, allocator: mem.Allocator),
}

// Input_Mode is C++ InputMode: vtable + input handler + opaque mode data.
Input_Mode :: struct {
	vtable:        ^Input_Mode_VTable,
	input_handler: ^Input_Handler,
	data:          rawptr,
}

// Input_Handler_Key_Error_Kind ports the C++ key-failure exception
// types: runtime_error vs no_selections_remaining (which -itersel
// swallows per selection).
Input_Handler_Key_Error_Kind :: enum {
	Runtime,
	No_Selections_Remaining,
}

// Input_Handler_Key_Error is the sticky C++ escaping-exception
// equivalent for key handling: normal_fail records it, execute-keys
// takes it to abort the remaining keys.
Input_Handler_Key_Error :: struct {
	kind:    Input_Handler_Key_Error_Kind,
	message: string, // owned by Input_Handler.allocator
}

// Input_Handler is C++ InputHandler. Owns context (by value) and mode stack.
Input_Handler :: struct {
	ctx:              Context,
	mode_stack:       [dynamic]^Input_Mode,
	last_insert:      Input_Handler_Insertion,
	handle_key_level: int,
	recording_reg:    rune,
	recorded_keys:    [dynamic]Keys_Key,
	recording_level:  int,
	// Sticky failure from the last mishandled key (C++ exception
	// escaping handle_key). execute-keys clears it before running
	// and takes it after each key to abort; interactive handling
	// leaves display to normal_fail.
	key_error: Maybe(Input_Handler_Key_Error),
	allocator: mem.Allocator,
}

Auto_Info_Flag :: enum {
	Command,
	On_Key,
	Normal,
}
Auto_Info :: bit_set[Auto_Info_Flag; u8]

Auto_Complete_Flag :: enum {
	Insert,
	Prompt,
}
Auto_Complete :: bit_set[Auto_Complete_Flag; u8]

On_Hidden_Cursor :: enum {
	Preserve_Selections,
	Move_Cursor,
	Move_Cursor_And_Anchor,
}

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------

// Client_Menu is the C++ Client::Menu state.
Client_Menu :: struct {
	items:     [dynamic]Display_Line,
	anchor:    Coord_Buffer,
	ui_anchor: Maybe(Coord_Display),
	style:     User_Interface_Menu_Style,
	selected:  int,
}

// Client_Info is the C++ Client::Info state.
Client_Info :: struct {
	title:     Display_Line,
	content:   Display_Line_List,
	anchor:    Coord_Buffer,
	ui_anchor: Maybe(Coord_Display),
	style:     User_Interface_Info_Style,
}

Client_Pending_Ui_Flag :: enum {
	Menu_Show,
	Menu_Select,
	Menu_Hide,
	Info_Show,
	Info_Hide,
	Status_Line,
	Draw,
	Refresh,
}
Client_Pending_Ui :: bit_set[Client_Pending_Ui_Flag; u8]

Client_Pending_Clear_Flag :: enum {
	Info,
	Status_Line,
}
Client_Pending_Clear :: bit_set[Client_Pending_Clear_Flag; u8]

// Client_On_Exit_Callback is C++ Client::OnExitCallback.
Client_On_Exit_Callback :: struct {
	call:    proc(data: rawptr, status: int),
	data:    rawptr,
	destroy: proc(data: rawptr, allocator: mem.Allocator),
}

// Client is C++ Client. Owns ui, window, input handler. Never copy.
Client :: struct {
	ui:                          ^User_Interface,
	ui_type:                     Main_UI_Type,
	window:                      ^Window,
	pid:                         int,
	on_exit:                     Client_On_Exit_Callback,
	env_vars:                    Env_Var_Map,
	input_handler:               Input_Handler,
	status_prompt:               Display_Line,
	status_content:              Display_Line,
	status_cursor_pos:           Units_ColumnCount,
	status_style:                User_Interface_Status_Style,
	mode_line:                   Display_Line,
	ui_pending:                  Client_Pending_Ui,
	pending_clear:               Client_Pending_Clear,
	menu:                        Client_Menu,
	info:                        Client_Info,
	pending_keys:                [dynamic]Keys_Key,
	buffer_reload_dialog_opened: bool,
	allocator:                   mem.Allocator,
}

Autoreload :: enum {
	Yes,
	No,
	Ask,
}

// Busy_Indicator_Previous_Status saves the status line under a busy message.
Busy_Indicator_Previous_Status :: struct {
	prompt:     Display_Line,
	content:    Display_Line,
	cursor_pos: Units_ColumnCount,
	style:      User_Interface_Status_Style,
}

// Busy_Indicator is C++ BusyIndicator (RAII via make/destroy procs).
Busy_Indicator :: struct {
	ctx:         ^Context,
	timer:           Event_Manager_Timer,
	previous_status: Maybe(Busy_Indicator_Previous_Status),
}

// ---------------------------------------------------------------------------
// Managers
// ---------------------------------------------------------------------------

// Buffer_Manager is C++ BufferManager (a singleton).
Buffer_Manager :: struct {
	buffers:      [dynamic]^Buffer,
	buffer_trash: [dynamic]^Buffer,
	allocator:    mem.Allocator,
}

// Window_And_Selections is C++ WindowAndSelections (free window cache).
Window_And_Selections :: struct {
	window:     ^Window,
	selections: Selection_List,
}

// Client_Manager is C++ ClientManager (a singleton).
Client_Manager :: struct {
	clients:       [dynamic]^Client,
	client_trash:  [dynamic]^Client,
	free_windows:  [dynamic]Window_And_Selections,
	window_trash:  [dynamic]^Window,
	allocator:     mem.Allocator,
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

Command_Parameters :: []string

// Command_Func is C++ CommandFunc. call returns the C++
// throwing-command outcome: None on success, otherwise an owned
// message the dispatcher propagates (like the escaping C++
// exception) to a reporting boundary.
Command_Func :: struct {
	call:    proc(data: rawptr, parser: ^Parameters_Parser, ctx: ^Context, shell_context: ^Shell_Context) -> (Commands_Error, string),
	data:    rawptr,
	destroy: proc(data: rawptr, allocator: mem.Allocator),
}

// Command_Completer is C++ CommandCompleter.
Command_Completer :: struct {
	call:    proc(data: rawptr, ctx: ^Context, params: Command_Parameters, token_to_complete: int, pos_in_token: Units_ByteCount, allocator: mem.Allocator) -> Completions,
	data:    rawptr,
	destroy: proc(data: rawptr, allocator: mem.Allocator),
}

// Command_Helper is C++ CommandHelper.
Command_Helper :: struct {
	call:    proc(data: rawptr, ctx: ^Context, params: Command_Parameters, allocator: mem.Allocator) -> string,
	data:    rawptr,
	destroy: proc(data: rawptr, allocator: mem.Allocator),
}

Command_Flags_Flag :: enum {
	Hidden,
}
Command_Flags :: bit_set[Command_Flags_Flag; u8]

Command_Info :: struct {
	name: string,
	info: string,
}

Token_Type :: enum {
	Raw,
	Raw_Quoted,
	Expand,
	Shell_Expand,
	Register_Expand,
	Option_Expand,
	Val_Expand,
	Arg_Expand,
	File_Expand,
	Command_Separator,
}

// Token is C++ Token (command line lexer token).
Token :: struct {
	type:       Token_Type,
	pos:        Units_ByteCount,
	content:    string,
	terminated: bool,
}

// Parse_State is C++ ParseState: remaining input + byte offset.
Parse_State :: struct {
	str: string,
	pos: int,
}

// Command_Parser is C++ CommandParser (command line tokenizer).
Command_Parser :: struct {
	state: Parse_State,
}

// Command_Manager_Command is one registered command.
Command_Manager_Command :: struct {
	func:      Command_Func,
	docstring: string,
	param_desc: Parameters_Parser_Desc,
	flags:     Command_Flags,
	helper:    Command_Helper,
	completer: Command_Completer,
}

Command_Manager_Module_State :: enum {
	Registered,
	Loading,
	Loaded,
}

Command_Manager_Module :: struct {
	state:    Command_Manager_Module_State,
	commands: string,
}

// Command_Manager is C++ CommandManager (a singleton).
Command_Manager :: struct {
	commands:      map[string]Command_Manager_Command,
	command_depth: int,
	modules:       map[string]Command_Manager_Module,
	// suppress_reports counts active try-guarded executions: while
	// nonzero, commands_report and normal_fail stay silent (a caught
	// failure must not pollute the status line; only the flag in
	// Input_Handler records it for exec-abort purposes).
	suppress_reports: int,
	allocator:     mem.Allocator,
}

// ---------------------------------------------------------------------------
// Shell
// ---------------------------------------------------------------------------

// Shell_Context is C++ ShellContext.
Shell_Context :: struct {
	params:   []string,
	env_vars: Env_Var_Map,
}

// Env_Var_Desc is C++ EnvVarDesc: one builtin dynamic env var.
Env_Var_Desc :: struct {
	str:     string,
	prefix:  bool,
	func:    proc(name: string, ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string,
}

Shell_Flags_Flag :: enum {
	Wait_For_Stdout,
}
Shell_Flags :: bit_set[Shell_Flags_Flag; u8]

// Shell is C++ Shell: a spawned child with pipes.
Shell :: struct {
	pid: Unique_Descriptor,
	stdin:  Unique_Descriptor,
	out: Unique_Descriptor,
	err: Unique_Descriptor,
}

// Shell_Manager is C++ ShellManager (a singleton).
Shell_Manager :: struct {
	shell:     string,
	env_vars:  []Env_Var_Desc,
	allocator: mem.Allocator,
}

// ---------------------------------------------------------------------------
// Remote (client/server)
// ---------------------------------------------------------------------------

Remote_Buffer :: [dynamic]u8

// Remote_Client is C++ RemoteClient: local UI end of a remote session.
Remote_Client :: struct {
	ui:             ^User_Interface,
	socket_watcher: ^Event_Manager_Fd_Watcher,
	send_buffer:    Remote_Buffer,
	exit_status:    Maybe(int),
	allocator:      mem.Allocator,
}

// Remote_Msg_Reader is C++ MsgReader (remote.cc): framed message reader.
Remote_Msg_Reader :: struct {
	stream:    Remote_Buffer,
	read_pos:  int,
	write_pos: int,
}

// Remote_Accepter is C++ Server::Accepter (remote.cc): one handshake.
Remote_Accepter :: struct {
	socket_watcher: Event_Manager_Fd_Watcher,
	reader:         Remote_Msg_Reader,
}

// Server is C++ Server (a singleton): the session listener.
Server :: struct {
	session:    string,
	is_daemon:  bool,
	listener:   ^Event_Manager_Fd_Watcher,
	accepters:  [dynamic]^Remote_Accepter,
	allocator:  mem.Allocator,
}

// ---------------------------------------------------------------------------
// Insert completer
// ---------------------------------------------------------------------------

Insert_Completer_Desc_Mode :: enum {
	Word,
	Option,
	Filename,
	Line,
}

// Insert_Completer_Desc is C++ InsertCompleterDesc (option element type).
Insert_Completer_Desc :: struct {
	mode:  Insert_Completer_Desc_Mode,
	param: Maybe(string),
}

// Completion_Candidate is C++ CompletionCandidate (a string triple).
Completion_Candidate :: struct {
	completion: string,
	menu_entry: string,
	on_select:  string,
}

// Insert_Completer_Completion_List is C++ CompletionList (option value type).
Insert_Completer_Completion_List :: Option_types_Prefixed_List(string, Completion_Candidate)

// Insert_Completion_Candidate is C++ InsertCompletion::Candidate.
Insert_Completion_Candidate :: struct {
	completion: string,
	on_select:  string,
	menu_entry: Display_Line,
}

// Insert_Completion is C++ InsertCompletion.
Insert_Completion :: struct {
	candidates: [dynamic]Insert_Completion_Candidate,
	begin:      Coord_Buffer,
	end:        Coord_Buffer,
	timestamp:  int,
}

// Insert_Completer_Complete_Func builds completions for explicit completion.
Insert_Completer_Complete_Func :: #type proc(sels: ^Selection_List, options: ^Option_Manager, faces: ^Face_Registry, allocator: mem.Allocator) -> Insert_Completion

// Insert_Completer is C++ InsertCompleter. Borrows context/options/faces.
Insert_Completer :: struct {
	ctx:            ^Context,
	options:            ^Option_Manager,
	faces:              ^Face_Registry,
	completions:        Insert_Completion,
	inserted_ranges:    [dynamic]Buffer_Range,
	current_candidate:  int,
	enabled:            bool,
	explicit_completer: Insert_Completer_Complete_Func,
}

// ---------------------------------------------------------------------------
// Selectors
// ---------------------------------------------------------------------------

Selectors_Object_Flags_Flag :: enum {
	To_Begin,
	To_End,
	Inner,
	Nested,
}
Selectors_Object_Flags :: bit_set[Selectors_Object_Flags_Flag; u8]

// ---------------------------------------------------------------------------
// Highlighter option types
// ---------------------------------------------------------------------------

// Inclusive_Buffer_Range is C++ InclusiveBufferRange (option element type).
Inclusive_Buffer_Range :: struct {
	first: Coord_Buffer,
	last:  Coord_Buffer,
}

// Line_And_Spec is C++ LineAndSpec (a line number + face/flag spec).
Line_And_Spec :: struct {
	line: Coord_Line,
	spec: string,
}

// Line_And_Spec_List is the "line-specs" option value type.
Line_And_Spec_List :: Option_Timestamped_List(Line_And_Spec)

// Range_And_String is C++ RangeAndString (a range + face/flag spec).
Range_And_String :: struct {
	range: Inclusive_Buffer_Range,
	spec:  string,
}

// Range_And_String_List is the "range-specs" option value type.
Range_And_String_List :: Option_Timestamped_List(Range_And_String)
