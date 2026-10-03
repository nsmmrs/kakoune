// Port of Kakoune's src/main.cc: startup option registration, builtin
// registers/keymaps/env vars, command line parsing, and the server/client
// startup glue.
//
// This is a library module (package kak has no package-main entry yet):
// a future main package calls main_entry with the process argv. All
// public names carry the `main_` prefix.
//
// Ownership: Main_Args borrows argv; main_args_destroy releases only the
// owned client_init string and the files array. Env var getters return
// owned [dynamic]string arrays of owned strings.
package kak

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:time"
import "core:unicode/utf8"

// Main_Error reports main-module failures. Zero value None is success.
Main_Error :: enum {
	None,
	// Argument parsing failed (bad switch, wrong count, bad +line).
	Invalid_Args,
	// -ui named an unknown interface.
	Unknown_UI,
	// Switches that cannot be combined were given together.
	Incompatible_Options,
	// -s, -c and -C are mutually exclusive.
	Mutually_Exclusive,
	// The session could not be contacted or created.
	Session_Error,
	// Startup (kakrc, server init, opening files) failed.
	Startup_Error,
}

// main_error_message renders err for stderr. Caller frees the result.
main_error_message :: proc(err: Main_Error, allocator := context.allocator) -> string {
	switch err {
	case .None:
		return ""
	case .Invalid_Args:
		return strings.clone("invalid arguments", allocator)
	case .Unknown_UI:
		return strings.clone("unknown ui type", allocator)
	case .Incompatible_Options:
		return strings.clone("incompatible options", allocator)
	case .Mutually_Exclusive:
		return strings.clone("-s, -c and -C are mutually exclusive", allocator)
	case .Session_Error:
		return strings.clone("session error", allocator)
	case .Startup_Error:
		return strings.clone("startup error", allocator)
	}
	unreachable()
}

// Main_UI_Type selects the local user interface (C++ UIType).
Main_UI_Type :: enum {
	Terminal,
	Json,
	Dummy,
}

// main_parse_ui_type maps a -ui name to a UI type (C++ parse_ui_type).
main_parse_ui_type :: proc(name: string) -> (Main_UI_Type, Main_Error) {
	switch name {
	case "terminal":
		return .Terminal, .None
	case "json":
		return .Json, .None
	case "dummy":
		return .Dummy, .None
	}
	return .Terminal, .Unknown_UI
}

// Main_Server_Flag lists run_server modes (C++ ServerFlags).
Main_Server_Flag :: enum {
	Ignore_Kakrc,
	Daemon,
	Read_Only,
	Startup_Info,
}
Main_Server_Flags :: bit_set[Main_Server_Flag]

// main_kakoune_version is the Kakoune version string (C++ version).
// The build stamps the real version; the library default is "unknown".
main_kakoune_version := "unknown"

// Main_Version_Note pairs a release version with its changelog notes.
Main_Version_Note :: struct {
	version: int,
	notes:   string,
}

// main_version_notes returns the startup-info changelog (C++ version_notes).
main_version_notes :: proc() -> []Main_Version_Note {
	return main_version_notes_data[:]
}

@(private)
main_version_notes_data := [4]Main_Version_Note{
	{0, "» local scope for command line evaluation\n"},
	{
		20260521,
		`» support the {+b}\N{} escape sequence in regex (matches {+b}[^\n]{})
» count and register forwarding to user modes
» back switch added for the arrange-buffers command
`,
	},
	{
		20260412,
		`» {+u}finaleol{} option to preserve files with no final end-of-line
» {+b}%val\{buffile}{} is now empty for scratch buffers
» {+b}FocusIn{}/{+b}FocusOut{} events on suspend
» {+u}number-lines -full-relative{} switch to keep a smaller line number gutter
» {+b}<a-I>{} and {+b}<a-A>{} to select nested text objects
» {+b}kak -C <session>{} to connect-or-create a session
`,
	},
	{
		20250603,
		`» kak_* appearing in shell arguments will be added to the environment
» {+U}double underline{} support
» {+u}git apply{} can stage/revert selected changes to current buffer
» {+u}exec/eval -client{} accepts '*' and comma separated list
`,
	},
}

// main_write_stdout writes str to stdout, ignoring errors.
main_write_stdout :: proc(str: string) {
	os.write_string(os.stdout, str)
}

// main_write_stderr writes str to stderr, ignoring errors.
main_write_stderr :: proc(str: string) {
	os.write_string(os.stderr, str)
}

// main_runtime_directory returns the kak runtime directory: $KAKOUNE_RUNTIME
// when set, else <binary-dir>/../share/kak when that is a directory, else
// /usr/share/kak. Caller frees the result.
main_runtime_directory :: proc(allocator := context.allocator) -> string {
	if dir, ok := os.lookup_env("KAKOUNE_RUNTIME", allocator); ok {
		return dir
	}
	if exe, err := os.get_executable_path(allocator); err == nil {
		defer delete(exe, allocator)
		if i := strings.last_index_byte(exe, '/'); i >= 0 {
			rel := strings.concatenate({exe[:i], "/../share/kak"}, allocator)
			defer delete(rel, allocator)
			if os.is_dir(rel) {
				if abs, err := file_real_path(rel, allocator); err == .None {
					return abs
				}
			}
		}
	}
	return strings.clone("/usr/share/kak", allocator)
}

// main_config_directory returns the kak config directory:
// $KAKOUNE_CONFIG_DIR, else $XDG_CONFIG_HOME/kak, else ~/.config/kak.
// Caller frees the result.
main_config_directory :: proc(allocator := context.allocator) -> string {
	if dir, ok := os.lookup_env("KAKOUNE_CONFIG_DIR", allocator); ok && len(dir) > 0 {
		return dir
	} else if ok {
		delete(dir, allocator)
	}
	if xdg, ok := os.lookup_env("XDG_CONFIG_HOME", allocator); ok {
		defer delete(xdg, allocator)
		if len(xdg) > 0 {
			return strings.concatenate({xdg, "/kak"}, allocator)
		}
	}
	return strings.concatenate({file_homedir(), "/.config/kak"}, allocator)
}

// main_session_name_valid reports whether session is a usable session name:
// non-empty with only session characters (C++ session validation).
main_session_name_valid :: proc(session: string) -> bool {
	if len(session) == 0 {
		return false
	}
	for r in session {
		if !remote_is_session_char(r) {
			return false
		}
	}
	return true
}

// main_parse_plus_arg parses a `+...` positional argument (C++ +line handling
// in main). It returns the target coord when arg is `+<line>[:<col>]`,
// to_end when arg is `+` or `+:`, and matched=false when arg is an
// ordinary filename. Coordinates are 0-based and clamped at 0.
main_parse_plus_arg :: proc(arg: string) -> (
	coord: Maybe(Coord_Buffer),
	matched: bool,
	to_end: bool,
) {
	if len(arg) == 0 || arg[0] != '+' {
		return nil, false, false
	}
	if arg == "+" || arg == "+:" {
		return nil, true, true
	}
	rest := arg[1:]
	colon := strings.index_byte(rest, ':')
	line_str := rest
	col := 0
	if colon >= 0 {
		line_str = rest[:colon]
		if c, ok := string_utils_str_to_int_ifp(rest[colon + 1:]); ok {
			col = c - 1
		}
	}
	if line, ok := string_utils_str_to_int_ifp(line_str); ok {
		ln := max(line - 1, 0)
		col = max(col, 0)
		return Coord_Buffer{Coord_Line(ln), Coord_Byte(col)}, true, false
	}
	return nil, false, false
}

// Main_Mode is the startup mode selected by the command line.
Main_Mode :: enum {
	Server,
	Client,
	Filter,
	Pipe,
	List_Sessions,
	Show_Version,
	Show_Help,
}

// Main_Args is the parsed kak command line. Strings borrow argv except
// client_init, which is owned (plus-args append to it).
Main_Args :: struct {
	session:           string,
	connect:           bool,
	connect_or_create: bool,
	client_init:       string,
	server_init:       string,
	ignore_kakrc:      bool,
	daemon:            bool,
	pipe:              Maybe(string),
	filter_keys:       Maybe(string),
	filter_backup:     string,
	filter_quiet:      bool,
	ui:                Main_UI_Type,
	list_sessions:     bool,
	clear_sessions:    bool,
	debug_flags:       string,
	show_version:      bool,
	show_help:         bool,
	readonly:          bool,
	files:             [dynamic]string,
	init_coord:        Maybe(Coord_Buffer),
}

// main_param_desc builds the kak switch table (C++ param_desc in main).
// Caller frees the switches map.
main_param_desc :: proc(allocator := context.allocator) -> Parameters_Parser_Desc {
	switches := make(map[string]Parameters_Parser_Switch_Desc, 18, allocator)
	switches["c"] = {true, "connect to given session"}
	switches["C"] = {true, "connect to given session, create if it does not exist"}
	switches["e"] = {true, "execute argument on client initialisation"}
	switches["E"] = {true, "execute argument on server initialisation"}
	switches["n"] = {false, "do not source kakrc files on startup"}
	switches["s"] = {true, "set session name"}
	switches["d"] = {false, "run as a headless session (requires -s)"}
	switches["p"] = {true, "just send stdin as commands to the given session"}
	switches["f"] = {true, "filter: for each file, select the entire buffer and execute the given keys"}
	switches["i"] = {true, "backup the files on which a filter is applied using the given suffix"}
	switches["q"] = {false, "in filter mode, be quiet about errors applying keys"}
	switches["ui"] = {true, "set the type of user interface to use (terminal, dummy, or json)"}
	switches["l"] = {false, "list existing sessions"}
	switches["clear"] = {false, "clear dead sessions"}
	switches["debug"] = {true, "initial debug option value"}
	switches["version"] = {false, "display kakoune version and exit"}
	switches["ro"] = {false, "readonly mode"}
	switches["help"] = {false, "display a help message and quit"}
	return Parameters_Parser_Desc{
		switches        = switches,
		max_positionals = max(int),
	}
}

// main_parse_args parses argv (without argv[0]) into Main_Args (C++ main's
// ParametersParser block). Pure: it never touches sessions or sockets.
main_parse_args :: proc(argv: []string, allocator := context.allocator) -> (Main_Args, Main_Error) {
	args := Main_Args{ui = .Terminal}
	for arg in argv {
		if arg == "--help" {
			args.show_help = true
			return args, .None
		}
	}
	desc := main_param_desc(allocator)
	defer delete(desc.switches)
	parser, perr := parameters_parser_parse(argv, desc, false, allocator)
	if perr != .None {
		return args, .Invalid_Args
	}
	defer parameters_parser_free(&parser)

	switch_get :: proc(parser: ^Parameters_Parser, name: string) -> (string, bool) {
		return parameters_parser_get_switch(parser, name)
	}

	if _, ok := switch_get(&parser, "help"); ok {
		args.show_help = true
		return args, .None
	}
	if _, ok := switch_get(&parser, "version"); ok {
		args.show_version = true
		return args, .None
	}
	if _, ok := switch_get(&parser, "l"); ok {
		args.list_sessions = true
	}
	if _, ok := switch_get(&parser, "clear"); ok {
		args.clear_sessions = true
	}
	if args.list_sessions || args.clear_sessions {
		return args, .None
	}
	if session, ok := switch_get(&parser, "p"); ok {
		pipe_incompat := [7]string{"c", "n", "s", "d", "e", "E", "ro"}
		for opt in pipe_incompat {
			if _, present := switch_get(&parser, opt); present {
				return args, .Incompatible_Options
			}
		}
		args.pipe = session
		return args, .None
	}

	if v, ok := switch_get(&parser, "e"); ok {
		args.client_init = strings.clone(v, allocator)
	}
	if v, ok := switch_get(&parser, "E"); ok {
		args.server_init = v
	}
	ui_name := "terminal"
	if v, ok := switch_get(&parser, "ui"); ok {
		ui_name = v
	}
	if ui, uerr := main_parse_ui_type(ui_name); uerr != .None {
		main_args_destroy(&args, allocator)
		return args, .Unknown_UI
	} else {
		args.ui = ui
	}

	if keys, ok := switch_get(&parser, "f"); ok {
		if _, ro := switch_get(&parser, "ro"); ro {
			main_args_destroy(&args, allocator)
			return args, .Incompatible_Options
		}
		args.filter_keys = keys
		if _, quiet := switch_get(&parser, "q"); quiet {
			args.filter_quiet = true
		}
		if suffix, has_suffix := switch_get(&parser, "i"); has_suffix {
			args.filter_backup = suffix
		}
		for i in 0 ..< parameters_parser_positional_count(&parser) {
			append(&args.files, parameters_parser_positional(&parser, i))
		}
		return args, .None
	}

	if v, ok := switch_get(&parser, "debug"); ok {
		args.debug_flags = v
	}
	if _, ok := switch_get(&parser, "n"); ok {
		args.ignore_kakrc = true
	}
	if _, ok := switch_get(&parser, "d"); ok {
		args.daemon = true
	}
	if _, ok := switch_get(&parser, "ro"); ok {
		args.readonly = true
	}
	c, has_c := switch_get(&parser, "c")
	big_c, has_big_c := switch_get(&parser, "C")
	s, has_s := switch_get(&parser, "s")
	count := (1 if has_c else 0) + (1 if has_big_c else 0) + (1 if has_s else 0)
	if count > 1 {
		main_args_destroy(&args, allocator)
		return args, .Mutually_Exclusive
	}
	args.connect = has_c
	args.connect_or_create = has_big_c
	if has_c {
		args.session = c
	} else if has_big_c {
		args.session = big_c
	} else if has_s {
		args.session = s
	}

	for i in 0 ..< parameters_parser_positional_count(&parser) {
		name := parameters_parser_positional(&parser, i)
		coord, matched, to_end := main_parse_plus_arg(name)
		if matched {
			if to_end {
				joined := strings.concatenate({args.client_init, "; exec gj"}, allocator)
				delete(args.client_init, allocator)
				args.client_init = joined
			} else {
				args.init_coord = coord
			}
			continue
		}
		append(&args.files, name)
	}
	return args, .None
}

// main_args_destroy releases owned Main_Args storage.
main_args_destroy :: proc(args: ^Main_Args, allocator := context.allocator) {
	delete(args.client_init, allocator)
	args.client_init = ""
	delete(args.files)
	args.files = nil
}

// main_classify_args selects the startup mode for parsed args. session_up is
// remote_check_session for -C sessions (false otherwise); passing it in
// keeps this proc pure and unit-testable.
main_classify_args :: proc(args: ^Main_Args, session_up: bool) -> (Main_Mode, Main_Error) {
	if args.show_help {
		return .Show_Help, .None
	}
	if args.show_version {
		return .Show_Version, .None
	}
	if args.list_sessions || args.clear_sessions {
		return .List_Sessions, .None
	}
	if args.pipe != nil {
		return .Pipe, .None
	}
	if args.filter_keys != nil {
		return .Filter, .None
	}
	if args.connect || (args.connect_or_create && session_up) {
		return .Client, .None
	}
	if args.daemon && len(args.session) == 0 {
		return .Server, .Invalid_Args
	}
	return .Server, .None
}

// main_server_flags computes the ServerFlags for a server start (C++ main).
// argc is the full argument count including argv[0].
main_server_flags :: proc(args: ^Main_Args, argc: int, stdin_is_tty: bool) -> Main_Server_Flags {
	flags: Main_Server_Flags
	if args.ignore_kakrc {
		flags |= {.Ignore_Kakrc}
	}
	if args.daemon {
		flags |= {.Daemon}
	}
	if args.readonly {
		flags |= {.Read_Only}
	}
	if (argc == 1 || (args.ignore_kakrc && argc == 2)) && stdin_is_tty {
		flags |= {.Startup_Info}
	}
	return flags
}

// main_client_init_for_files builds the client init commands that open the
// command line files (C++ -c branch in main). init_coord applies to the
// first file only and is consumed. Caller frees the result.
main_client_init_for_files :: proc(
	files: []string,
	init_coord: Maybe(Coord_Buffer),
	client_init: string,
	allocator := context.allocator,
) -> string {
	b := strings.builder_make(allocator)
	coord := init_coord
	for name in files {
		path, err := file_real_path(name, allocator)
		if err != .None {
			path = strings.clone(name, allocator)
		}
		escaped := string_utils_escape(path, "'", '\'', allocator)
		delete(path, allocator)
		fmt.sbprintf(&b, "edit '{}'", escaped)
		delete(escaped, allocator)
		if c, ok := coord.?; ok {
			fmt.sbprintf(&b, " {} {}", int(c.line) + 1, int(c.column) + 1)
			coord = nil
		}
		strings.write_byte(&b, ';')
	}
	strings.write_string(&b, client_init)
	return strings.to_string(b)
}

// Option validators (C++ check_* in main.cc). Each returns "" when the
// value is valid, else a static message describing the violation.

main_check_tabstop :: proc(value: Option_Value) -> string {
	if v, ok := value.(int); ok && v < 1 {
		return "tabstop should be strictly positive"
	}
	return ""
}

main_check_indentwidth :: proc(value: Option_Value) -> string {
	if v, ok := value.(int); ok && v < 0 {
		return "indentwidth should be positive or zero"
	}
	return ""
}

main_check_scrolloff :: proc(value: Option_Value) -> string {
	if v, ok := value.(Coord_Display); ok {
		if v.line < 0 || v.column < 0 {
			return "scroll offset must be positive or zero"
		}
	}
	return ""
}

main_check_timeout :: proc(value: Option_Value) -> string {
	if v, ok := value.(int); ok && v < 50 {
		return "the minimum acceptable timeout is 50 milliseconds"
	}
	return ""
}

main_check_extra_word_chars :: proc(value: Option_Value) -> string {
	if v, ok := value.([dynamic]rune); ok {
		for c in v {
			if unicode_is_blank(c) {
				return "blanks are not accepted for extra completion characters"
			}
		}
	}
	return ""
}

main_check_matching_pairs :: proc(value: Option_Value) -> string {
	if v, ok := value.([dynamic]rune); ok {
		if len(v) % 2 != 0 {
			return "matching pairs should have a pair number of element"
		}
		for c in v {
			if !unicode_is_punctuation(c, nil) {
				return "matching pairs can only be punctuation"
			}
		}
	}
	return ""
}

// main_register_options declares the builtin global options (C++
// register_options). Errors are impossible for these static declarations.
main_register_options :: proc(reg: ^Options_Registry, allocator := context.allocator) {
	declare :: proc(reg: ^Options_Registry, name, doc: string, value: Option_Value, validator: Option_Validator, allocator: mem.Allocator) {
		_, err := option_manager_registry_declare(reg, name, doc, value, {}, validator, allocator)
		assert(err == .None)
	}
	declare(reg, "tabstop", "size of a tab character", 8, main_check_tabstop, allocator)
	declare(reg, "indentwidth", "indentation width", 4, main_check_indentwidth, allocator)
	declare(
		reg,
		"scrolloff",
		"number of lines and columns to keep visible main cursor when scrolling",
		Coord_Display{},
		main_check_scrolloff,
		allocator,
	)
	declare(reg, "eolformat", "end of line format", Eol_Format.Lf, nil, allocator)
	declare(reg, "finaleol", "write and end of line at end of file", Final_Eol.Present, nil, allocator)
	declare(reg, "BOM", "byte order mark to use when writing buffer", Byte_Order_Mark.None, nil, allocator)
	declare(reg, "incsearch", "incrementally apply search/select/split regex", true, nil, allocator)
	declare(reg, "autoinfo", "automatically display contextual help", Auto_Info{.Command, .On_Key}, nil, allocator)
	declare(reg, "autocomplete", "automatically display possible completions", Auto_Complete{.Insert, .Prompt}, nil, allocator)
	declare(reg, "aligntab", "use tab characters when possible for alignment", false, nil, allocator)
	declare(
		reg,
		"ignored_files",
		"patterns to ignore when completing filenames",
		Regex{pattern = `^(\..*|.*\.(o|so|a))$`},
		nil,
		allocator,
	)
	declare(reg, "disabled_hooks", "patterns to disable hooks whose group is matched", Regex{}, nil, allocator)
	declare(reg, "filetype", "buffer filetype", "", nil, allocator)
	path := make([dynamic]string, 0, 3, allocator)
	defer delete(path)
	append(&path, "./", "%/", "/usr/include")
	declare(reg, "path", "path to consider when trying to find a file", path, nil, allocator)
	completers := make([dynamic]Insert_Completer_Desc, 0, 2, allocator)
	defer delete(completers)
	append(&completers, Insert_Completer_Desc{mode = .Filename})
	append(&completers, Insert_Completer_Desc{mode = .Word, param = "all"})
	declare(reg, "completers", "insert mode completers to execute.", completers, nil, allocator)
	static_words := make([dynamic]string, allocator = context.temp_allocator)
	declare(reg, "static_words", "list of words to always consider for insert word completion", static_words, nil, allocator)
	declare(reg, "autoreload", "autoreload buffer when a filesystem modification is detected", Autoreload.Ask, nil, allocator)
	declare(reg, "writemethod", "how to write buffer to files", File_Write_Method.Overwrite, nil, allocator)
	declare(
		reg,
		"idle_timeout",
		"timeout, in milliseconds, before idle hooks are triggered",
		50,
		main_check_timeout,
		allocator,
	)
	declare(
		reg,
		"fs_check_timeout",
		"timeout, in milliseconds, between file system buffer modification checks",
		500,
		main_check_timeout,
		allocator,
	)
	ui_options := make(map[string]string, allocator = context.temp_allocator)
	declare(
		reg,
		"ui_options",
		`space separated list of <key>=<value> options that are passed to and interpreted by the user interface

The terminal ui supports the following options:
    <key>:                        <value>:
    terminal_assistant             clippy|cat|dilbert|none|off
    terminal_status_on_top         bool
    terminal_set_title             bool
    terminal_title                 str
    terminal_enable_mouse          bool
    terminal_synchronized          bool
    terminal_wheel_scroll_amount   int
    terminal_shift_function_key    int
    terminal_padding_char          codepoint
    terminal_padding_fill          bool
    terminal_cursor_native         bool
    terminal_info_max_width        int
`,
		ui_options,
		nil,
		allocator,
	)
	declare(
		reg,
		"modelinefmt",
		"format string used to generate the modeline",
		"%val{bufname} %val{cursor_line}:%val{cursor_char_column} {{context_info}} {{mode_info}} - %val{client}@[%val{session}]",
		nil,
		allocator,
	)
	declare(reg, "debug", "various debug flags", Option_types_Debug_Flags{}, nil, allocator)
	declare(reg, "readonly", "prevent buffers from being modified", false, nil, allocator)
	extra_word_chars := make([dynamic]rune, 0, 1, allocator)
	defer delete(extra_word_chars)
	append(&extra_word_chars, '_')
	declare(
		reg,
		"extra_word_chars",
		"Additional characters to be considered as words for insert completion",
		extra_word_chars,
		main_check_extra_word_chars,
		allocator,
	)
	matching_pairs := make([dynamic]rune, 0, 8, allocator)
	defer delete(matching_pairs)
	append(&matching_pairs, '(', ')', '{', '}', '[', ']', '<', '>')
	declare(
		reg,
		"matching_pairs",
		"set of pair of characters to be considered as matching pairs",
		matching_pairs,
		main_check_matching_pairs,
		allocator,
	)
	declare(
		reg,
		"startup_info_version",
		"version up to which startup info changes should be hidden",
		0,
		nil,
		allocator,
	)
}

// Dynamic register getters/setters (C++ register_registers lambdas).

main_reg_percent_get :: proc(ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	return main_env_single(buffer_display_name(context_buffer(ctx)), allocator)
}

main_reg_dot_get :: proc(ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	return context_selections_content(ctx, allocator)
}

main_reg_hash_get :: proc(ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	count := len(context_selections(ctx).selections)
	res := make([dynamic]string, 0, count, allocator)
	for i in 1 ..= count {
		append(&res, main_itoa(i, allocator))
	}
	return res
}

main_reg_digit_get :: proc(ctx: ^Context, index: int, allocator: mem.Allocator) -> [dynamic]string {
	sels := context_selections(ctx).selections
	res := make([dynamic]string, 0, len(sels), allocator)
	for &sel in sels {
		capture := ""
		if index < len(sel.captures) {
			capture = sel.captures[index]
		}
		append(&res, strings.clone(capture, allocator))
	}
	return res
}

main_reg_digit_set :: proc(ctx: ^Context, index: int, values: []string) {
	if len(values) == 0 {
		return
	}
	sels := &context_selections(ctx, false).selections
	for i in 0 ..< len(sels) {
		for len(sels[i].captures) < index + 1 {
			append(&sels[i].captures, "")
		}
		delete(sels[i].captures[index])
		sels[i].captures[index] = strings.clone(values[min(i, len(values) - 1)])
	}
}

main_reg_digit_0_get :: proc(ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	return main_reg_digit_get(ctx, 0, allocator)
}
main_reg_digit_0_set :: proc(ctx: ^Context, values: []string) {
	main_reg_digit_set(ctx, 0, values)
}
main_reg_digit_1_get :: proc(ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	return main_reg_digit_get(ctx, 1, allocator)
}
main_reg_digit_1_set :: proc(ctx: ^Context, values: []string) {
	main_reg_digit_set(ctx, 1, values)
}
main_reg_digit_2_get :: proc(ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	return main_reg_digit_get(ctx, 2, allocator)
}
main_reg_digit_2_set :: proc(ctx: ^Context, values: []string) {
	main_reg_digit_set(ctx, 2, values)
}
main_reg_digit_3_get :: proc(ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	return main_reg_digit_get(ctx, 3, allocator)
}
main_reg_digit_3_set :: proc(ctx: ^Context, values: []string) {
	main_reg_digit_set(ctx, 3, values)
}
main_reg_digit_4_get :: proc(ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	return main_reg_digit_get(ctx, 4, allocator)
}
main_reg_digit_4_set :: proc(ctx: ^Context, values: []string) {
	main_reg_digit_set(ctx, 4, values)
}
main_reg_digit_5_get :: proc(ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	return main_reg_digit_get(ctx, 5, allocator)
}
main_reg_digit_5_set :: proc(ctx: ^Context, values: []string) {
	main_reg_digit_set(ctx, 5, values)
}
main_reg_digit_6_get :: proc(ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	return main_reg_digit_get(ctx, 6, allocator)
}
main_reg_digit_6_set :: proc(ctx: ^Context, values: []string) {
	main_reg_digit_set(ctx, 6, values)
}
main_reg_digit_7_get :: proc(ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	return main_reg_digit_get(ctx, 7, allocator)
}
main_reg_digit_7_set :: proc(ctx: ^Context, values: []string) {
	main_reg_digit_set(ctx, 7, values)
}
main_reg_digit_8_get :: proc(ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	return main_reg_digit_get(ctx, 8, allocator)
}
main_reg_digit_8_set :: proc(ctx: ^Context, values: []string) {
	main_reg_digit_set(ctx, 8, values)
}
main_reg_digit_9_get :: proc(ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	return main_reg_digit_get(ctx, 9, allocator)
}
main_reg_digit_9_set :: proc(ctx: ^Context, values: []string) {
	main_reg_digit_set(ctx, 9, values)
}

// main_register_registers installs the builtin registers (C++
// register_registers): static a-z "^@, history /|:\, dynamic % . # 0-9,
// and the null _ register.
main_register_registers :: proc(m: ^Register_Manager, allocator := context.allocator) {
	// NOTE: register names are borrowed (make_static/make_history keep
	// the slice and destroy never frees it), so static storage is used.
	static_names := "abcdefghijklmnopqrstuvwxyz\"^@"
	for i := 0; i < len(static_names); i += 1 {
		register_manager_add(
			m,
			rune(static_names[i]),
			register_manager_make_static(static_names[i:i + 1], allocator),
		)
	}
	history_names := "/|:\\"
	for i := 0; i < len(history_names); i += 1 {
		register_manager_add(
			m,
			rune(history_names[i]),
			register_manager_make_history(history_names[i:i + 1], allocator),
		)
	}
	register_manager_add(m, '%', register_manager_make_dynamic_readonly("%", main_reg_percent_get, allocator))
	register_manager_add(m, '.', register_manager_make_dynamic_readonly(".", main_reg_dot_get, allocator))
	register_manager_add(m, '#', register_manager_make_dynamic_readonly("#", main_reg_hash_get, allocator))
	register_manager_add(m, '0', register_manager_make_dynamic("0", main_reg_digit_0_get, main_reg_digit_0_set, allocator))
	register_manager_add(m, '1', register_manager_make_dynamic("1", main_reg_digit_1_get, main_reg_digit_1_set, allocator))
	register_manager_add(m, '2', register_manager_make_dynamic("2", main_reg_digit_2_get, main_reg_digit_2_set, allocator))
	register_manager_add(m, '3', register_manager_make_dynamic("3", main_reg_digit_3_get, main_reg_digit_3_set, allocator))
	register_manager_add(m, '4', register_manager_make_dynamic("4", main_reg_digit_4_get, main_reg_digit_4_set, allocator))
	register_manager_add(m, '5', register_manager_make_dynamic("5", main_reg_digit_5_get, main_reg_digit_5_set, allocator))
	register_manager_add(m, '6', register_manager_make_dynamic("6", main_reg_digit_6_get, main_reg_digit_6_set, allocator))
	register_manager_add(m, '7', register_manager_make_dynamic("7", main_reg_digit_7_get, main_reg_digit_7_set, allocator))
	register_manager_add(m, '8', register_manager_make_dynamic("8", main_reg_digit_8_get, main_reg_digit_8_set, allocator))
	register_manager_add(m, '9', register_manager_make_dynamic("9", main_reg_digit_9_get, main_reg_digit_9_set, allocator))
	register_manager_add(m, '_', register_manager_make_null(allocator))
}

// main_register_keymaps installs the default normal-mode key mappings
// (C++ register_keymaps): arrows to hjkl, shifted arrows to HJKL,
// Home/End to alt-h/alt-l.
main_register_keymaps :: proc(m: ^Keymap_Manager) {
	map_one :: proc(m: ^Keymap_Manager, key: Keys_Key, to: Keys_Key) {
		mapping := [1]Keys_Key{to}
		keymap_manager_map_key(m, key, .Normal, mapping[:], "")
	}
	map_one(m, {keys_MOD_NONE, keys_LEFT}, {keys_MOD_NONE, 'h'})
	map_one(m, {keys_MOD_NONE, keys_RIGHT}, {keys_MOD_NONE, 'l'})
	map_one(m, {keys_MOD_NONE, keys_DOWN}, {keys_MOD_NONE, 'j'})
	map_one(m, {keys_MOD_NONE, keys_UP}, {keys_MOD_NONE, 'k'})
	map_one(m, {keys_MOD_SHIFT, keys_LEFT}, {keys_MOD_NONE, 'H'})
	map_one(m, {keys_MOD_SHIFT, keys_RIGHT}, {keys_MOD_NONE, 'L'})
	map_one(m, {keys_MOD_SHIFT, keys_DOWN}, {keys_MOD_NONE, 'J'})
	map_one(m, {keys_MOD_SHIFT, keys_UP}, {keys_MOD_NONE, 'K'})
	map_one(m, {keys_MOD_NONE, keys_END}, {keys_MOD_ALT, 'l'})
	map_one(m, {keys_MOD_NONE, keys_HOME}, {keys_MOD_ALT, 'h'})
	map_one(m, {keys_MOD_SHIFT, keys_END}, {keys_MOD_ALT, 'L'})
	map_one(m, {keys_MOD_SHIFT, keys_HOME}, {keys_MOD_ALT, 'H'})
}

// Builtin environment variables (C++ builtin_env_vars). Each getter returns
// an owned [dynamic]string of owned strings.

// main_itoa formats n. Caller frees the result.
main_itoa :: proc(n: int, allocator := context.allocator) -> string {
	buf: [32]byte
	return strings.clone(strconv.write_int(buf[:], i64(n), 10), allocator)
}

// main_env_single wraps one string as an owned single-element list.
main_env_single :: proc(s: string, allocator: mem.Allocator) -> [dynamic]string {
	res := make([dynamic]string, 0, 1, allocator)
	append(&res, strings.clone(s, allocator))
	return res
}

// main_env_int wraps one int as an owned single-element list.
main_env_int :: proc(n: int, allocator: mem.Allocator) -> [dynamic]string {
	res := make([dynamic]string, 0, 1, allocator)
	append(&res, main_itoa(n, allocator))
	return res
}

// main_codepoint_string encodes one codepoint. Caller frees the result.
main_codepoint_string :: proc(c: rune, allocator := context.allocator) -> string {
	buf, size := utf8.encode_rune(c)
	return strings.clone(string(buf[:size]), allocator)
}

// main_env_selection_content returns the owned text of sel in buf.
main_env_selection_content :: proc(buf: ^Buffer, sel: Selection, allocator: mem.Allocator) -> string {
	return strings.clone(buffer_substr(buf, selection_basic_min(sel.basic), selection_basic_max(sel.basic)), allocator)
}

// main_env_char_length counts the characters covered by sel in buf.
main_env_char_length :: proc(buf: ^Buffer, sel: Selection) -> int {
	return utf8.rune_count(buffer_substr(buf, selection_basic_min(sel.basic), selection_basic_max(sel.basic)))
}

// main_env_opt_int reads an int option, returning fallback when missing.
main_env_opt_int :: proc(ctx: ^Context, name: string, fallback: int) -> int {
	if opt, err := option_manager_get_option(context_options(ctx), name); err == .None {
		if v, ok := opt.value.(int); ok {
			return v
		}
	}
	return fallback
}

// main_env_selections_main_first formats all selections with the main one
// first (C++ main_sel_first).
main_env_selections_main_first :: proc(
	ctx: ^Context,
	column_type: Column_Type,
	tabstop: Coord_Column,
	allocator: mem.Allocator,
) -> [dynamic]string {
	buf := context_buffer(ctx)
	sels := context_selections(ctx).selections
	res := make([dynamic]string, 0, len(sels), allocator)
	if len(sels) == 0 {
		return res
	}
	main := selection_list_main_index(context_selections(ctx))
	for k in 0 ..< len(sels) {
		s, _ := selection_to_string(column_type, buf, sels[(main + k) % len(sels)], tabstop, allocator)
		append(&res, s)
	}
	return res
}

main_env_bufname :: proc(name: string, ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	return main_env_single(buffer_display_name(context_buffer(ctx)), allocator)
}

main_env_buffile :: proc(name: string, ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	return main_env_single(buffer_filename(context_buffer(ctx)), allocator)
}

main_env_buflist :: proc(name: string, ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	buffers := buffer_manager_instance().buffers
	res := make([dynamic]string, 0, len(buffers), allocator)
	for b in buffers {
		append(&res, strings.clone(buffer_display_name(b), allocator))
	}
	return res
}

main_env_buf_line_count :: proc(name: string, ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	return main_env_int(int(buffer_line_count(context_buffer(ctx))), allocator)
}

main_env_timestamp :: proc(name: string, ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	return main_env_int(buffer_timestamp(context_buffer(ctx)), allocator)
}

main_env_history_id :: proc(name: string, ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	return main_env_int(int(buffer_current_history_id(context_buffer(ctx))), allocator)
}

main_env_selection :: proc(name: string, ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	res := make([dynamic]string, 0, 1, allocator)
	append(&res, main_env_selection_content(context_buffer(ctx), selection_list_main(context_selections(ctx))^, allocator))
	return res
}

main_env_selections :: proc(name: string, ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	return context_selections_content(ctx, allocator)
}

main_env_runtime :: proc(name: string, ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	res := make([dynamic]string, 0, 1, allocator)
	append(&res, main_runtime_directory(allocator))
	return res
}

main_env_config :: proc(name: string, ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	res := make([dynamic]string, 0, 1, allocator)
	append(&res, main_config_directory(allocator))
	return res
}

main_env_version :: proc(name: string, ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	return main_env_single(main_kakoune_version, allocator)
}

main_env_opt :: proc(name: string, ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	res := make([dynamic]string, 0, 1, allocator)
	if opt, err := option_manager_get_option(context_options(ctx), name[4:]); err == .None {
		for s in option_manager_option_get_as_strings(opt, allocator) {
			append(&res, s)
		}
	}
	return res
}

main_env_main_reg :: proc(name: string, ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	res := make([dynamic]string, 0, 1, allocator)
	if reg, err := register_manager_get_by_name(register_manager_instance(), name[9:]); err == .None {
		append(&res, strings.clone(register_manager_get_main(reg, ctx, selection_list_main_index(context_selections(ctx))), allocator))
	}
	return res
}

main_env_reg :: proc(name: string, ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	res := make([dynamic]string, 0, 1, allocator)
	if reg, err := register_manager_get_by_name(register_manager_instance(), name[4:]); err == .None {
		for s in register_manager_get_values(reg, ctx, allocator) {
			append(&res, strings.clone(s, allocator))
		}
	}
	return res
}

main_env_client_env :: proc(name: string, ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	return main_env_single(client_get_env_var(context_client(ctx), name[11:]), allocator)
}

main_env_session :: proc(name: string, ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	return main_env_single(remote_server_instance().session, allocator)
}

main_env_client :: proc(name: string, ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	return main_env_single(ctx.name, allocator)
}

main_env_client_pid :: proc(name: string, ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	return main_env_int(client_pid(context_client(ctx)), allocator)
}

main_env_client_list :: proc(name: string, ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	clients := client_manager_instance().clients
	res := make([dynamic]string, 0, len(clients), allocator)
	for c in clients {
		append(&res, strings.clone(c.input_handler.ctx.name, allocator))
	}
	return res
}

main_env_modified :: proc(name: string, ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	if buffer_is_modified(context_buffer(ctx)) {
		return main_env_single("true", allocator)
	}
	return main_env_single("false", allocator)
}

main_env_cursor_line :: proc(name: string, ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	return main_env_int(int(selection_list_main(context_selections(ctx)).cursor.line) + 1, allocator)
}

main_env_cursor_column :: proc(name: string, ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	return main_env_int(int(selection_list_main(context_selections(ctx)).cursor.column) + 1, allocator)
}

main_env_cursor_char_value :: proc(name: string, ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	buf := context_buffer(ctx)
	cursor := selection_list_main(context_selections(ctx)).cursor.coord
	value := 0
	if int(cursor.line) < len(buf.lines) {
		line := buf.lines[int(cursor.line)]
		if int(cursor.column) < len(line) {
			r, _ := utf8.decode_rune_in_string(line[int(cursor.column):])
			value = int(r)
		}
	}
	return main_env_int(value, allocator)
}

main_env_cursor_char_column :: proc(name: string, ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	buf := context_buffer(ctx)
	cursor := selection_list_main(context_selections(ctx)).cursor.coord
	count := 0
	if int(cursor.line) < len(buf.lines) {
		line := buf.lines[int(cursor.line)]
		end := min(int(cursor.column), len(line))
		count = utf8.rune_count(line[:end])
	}
	return main_env_int(count + 1, allocator)
}

main_env_cursor_display_column :: proc(name: string, ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	buf := context_buffer(ctx)
	cursor := selection_list_main(context_selections(ctx)).cursor.coord
	col := buffer_utils_get_column(buf, Coord_Column(main_env_opt_int(ctx, "tabstop", 8)), cursor)
	return main_env_int(int(col) + 1, allocator)
}

main_env_cursor_byte_offset :: proc(name: string, ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	buf := context_buffer(ctx)
	cursor := selection_list_main(context_selections(ctx)).cursor.coord
	return main_env_int(int(buffer_distance(buf, Coord_Buffer{}, cursor)), allocator)
}

main_env_recording_register :: proc(name: string, ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	if reg := context_input_handler(ctx).recording_reg; reg != 0 {
		buf, size := utf8.encode_rune(reg)
		return main_env_single(string(buf[:size]), allocator)
	}
	return main_env_single("", allocator)
}

main_env_selection_desc :: proc(name: string, ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	res := make([dynamic]string, 0, 1, allocator)
	s, _ := selection_to_string(.Byte, context_buffer(ctx), selection_list_main(context_selections(ctx))^, -1, allocator)
	append(&res, s)
	return res
}

main_env_selections_desc :: proc(name: string, ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	return main_env_selections_main_first(ctx, .Byte, -1, allocator)
}

main_env_selections_char_desc :: proc(name: string, ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	return main_env_selections_main_first(ctx, .Codepoint, -1, allocator)
}

main_env_selections_display_column_desc :: proc(name: string, ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	return main_env_selections_main_first(ctx, .Display_Column, Coord_Column(main_env_opt_int(ctx, "tabstop", 8)), allocator)
}

main_env_selection_length :: proc(name: string, ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	return main_env_int(main_env_char_length(context_buffer(ctx), selection_list_main(context_selections(ctx))^), allocator)
}

main_env_selections_length :: proc(name: string, ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	buf := context_buffer(ctx)
	sels := context_selections(ctx).selections
	res := make([dynamic]string, 0, len(sels), allocator)
	for &sel in sels {
		append(&res, main_itoa(main_env_char_length(buf, sel), allocator))
	}
	return res
}

main_env_selection_count :: proc(name: string, ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	return main_env_int(len(context_selections(ctx).selections), allocator)
}

main_env_window_width :: proc(name: string, ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	return main_env_int(int(context_window(ctx).dimensions.column), allocator)
}

main_env_window_height :: proc(name: string, ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	return main_env_int(int(context_window(ctx).dimensions.line), allocator)
}

main_env_user_modes :: proc(name: string, ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	modes := keymap_manager_user_modes(context_keymaps(ctx))^
	res := make([dynamic]string, 0, len(modes), allocator)
	for m in modes {
		append(&res, strings.clone(m, allocator))
	}
	return res
}

main_env_window_range :: proc(name: string, ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	win := context_window(ctx)
	setup := win.last_display_setup
	width := int(win.dimensions.column) - int(setup.widget_columns)
	res := make([dynamic]string, 0, 4, allocator)
	append(&res, main_itoa(int(setup.first_line), allocator))
	append(&res, main_itoa(int(setup.first_column), allocator))
	append(&res, main_itoa(int(setup.line_count), allocator))
	append(&res, main_itoa(width, allocator))
	return res
}

main_env_history :: proc(name: string, ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	return buffer_utils_history_as_strings(buffer_history(context_buffer(ctx)), allocator)
}

main_env_history_since :: proc(name: string, ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	history := buffer_history(context_buffer(ctx))
	start := 0
	if n, err := string_utils_str_to_int(name[14:]); err == .None {
		start = clamp(n + 1, 0, len(history))
	}
	return buffer_utils_history_as_strings(history[start:], allocator)
}

main_env_uncommitted_modifications :: proc(name: string, ctx: ^Context, allocator: mem.Allocator) -> [dynamic]string {
	return buffer_utils_undo_group_as_strings(context_buffer(ctx).current_undo_group[:], allocator)
}

// main_builtin_env_vars returns the builtin dynamic env var table (C++
// builtin_env_vars). The shell manager borrows it; the caller frees the
// slice with the same allocator.
main_builtin_env_vars :: proc(allocator := context.allocator) -> []Env_Var_Desc {
	descs := make([]Env_Var_Desc, 41, allocator)
	descs[0] = {"bufname", false, main_env_bufname}
	descs[1] = {"buffile", false, main_env_buffile}
	descs[2] = {"buflist", false, main_env_buflist}
	descs[3] = {"buf_line_count", false, main_env_buf_line_count}
	descs[4] = {"timestamp", false, main_env_timestamp}
	descs[5] = {"history_id", false, main_env_history_id}
	descs[6] = {"selection", false, main_env_selection}
	descs[7] = {"selections", false, main_env_selections}
	descs[8] = {"runtime", false, main_env_runtime}
	descs[9] = {"config", false, main_env_config}
	descs[10] = {"version", false, main_env_version}
	descs[11] = {"opt_", true, main_env_opt}
	descs[12] = {"main_reg_", true, main_env_main_reg}
	descs[13] = {"reg_", true, main_env_reg}
	descs[14] = {"client_env_", true, main_env_client_env}
	descs[15] = {"session", false, main_env_session}
	descs[16] = {"client", false, main_env_client}
	descs[17] = {"client_pid", false, main_env_client_pid}
	descs[18] = {"client_list", false, main_env_client_list}
	descs[19] = {"modified", false, main_env_modified}
	descs[20] = {"cursor_line", false, main_env_cursor_line}
	descs[21] = {"cursor_column", false, main_env_cursor_column}
	descs[22] = {"cursor_char_value", false, main_env_cursor_char_value}
	descs[23] = {"cursor_char_column", false, main_env_cursor_char_column}
	descs[24] = {"cursor_display_column", false, main_env_cursor_display_column}
	descs[25] = {"cursor_byte_offset", false, main_env_cursor_byte_offset}
	descs[26] = {"recording_register", false, main_env_recording_register}
	descs[27] = {"selection_desc", false, main_env_selection_desc}
	descs[28] = {"selections_desc", false, main_env_selections_desc}
	descs[29] = {"selections_char_desc", false, main_env_selections_char_desc}
	descs[30] = {"selections_display_column_desc", false, main_env_selections_display_column_desc}
	descs[31] = {"selection_length", false, main_env_selection_length}
	descs[32] = {"selections_length", false, main_env_selections_length}
	descs[33] = {"selection_count", false, main_env_selection_count}
	descs[34] = {"window_width", false, main_env_window_width}
	descs[35] = {"window_height", false, main_env_window_height}
	descs[36] = {"user_modes", false, main_env_user_modes}
	descs[37] = {"window_range", false, main_env_window_range}
	descs[38] = {"history", false, main_env_history}
	descs[39] = {"history_since_", true, main_env_history_since}
	descs[40] = {"uncommitted_modifications", false, main_env_uncommitted_modifications}
	return descs
}

// Dummy UI (C++ DummyUI in make_ui): a no-op interface that reports 24x80.

main_dummy_ui_is_ok :: proc(data: rawptr) -> bool {
	return true
}

main_dummy_ui_menu_show :: proc(
	data: rawptr,
	choices: []User_Interface_Display_Line,
	anchor: Coord_Display,
	fg, bg: Face,
	style: User_Interface_Menu_Style,
) {
}

main_dummy_ui_menu_select :: proc(data: rawptr, selected: int) {
}

main_dummy_ui_menu_hide :: proc(data: rawptr) {
}

main_dummy_ui_info_show :: proc(
	data: rawptr,
	title: ^User_Interface_Display_Line,
	content: []User_Interface_Display_Line,
	anchor: Coord_Display,
	face: Face,
	style: User_Interface_Info_Style,
) {
}

main_dummy_ui_info_hide :: proc(data: rawptr) {
}

main_dummy_ui_draw :: proc(
	data: rawptr,
	display_buffer: ^User_Interface_Display_Buffer,
	cursor_pos: Coord_Display,
	default_face, padding_face: Face,
	widget_columns: Coord_Column,
) {
}

main_dummy_ui_draw_status :: proc(
	data: rawptr,
	prompt, content: ^User_Interface_Display_Line,
	cursor_pos: Coord_Column,
	mode_line: ^User_Interface_Display_Line,
	default_face: Face,
	style: User_Interface_Status_Style,
) {
}

main_dummy_ui_dimensions :: proc(data: rawptr) -> Coord_Display {
	return Coord_Display{24, 80}
}

main_dummy_ui_refresh :: proc(data: rawptr, force: bool) {
}

main_dummy_ui_set_on_key :: proc(data: rawptr, callback: User_Interface_On_Key_Callback) {
}

main_dummy_ui_set_on_paste :: proc(data: rawptr, callback: User_Interface_On_Paste_Callback) {
}

main_dummy_ui_set_ui_options :: proc(data: rawptr, options: User_Interface_Options) {
}

@(private)
main_dummy_ui_vtable := User_Interface_VTable{
	is_ok          = main_dummy_ui_is_ok,
	menu_show      = main_dummy_ui_menu_show,
	menu_select    = main_dummy_ui_menu_select,
	menu_hide      = main_dummy_ui_menu_hide,
	info_show      = main_dummy_ui_info_show,
	info_hide      = main_dummy_ui_info_hide,
	draw           = main_dummy_ui_draw,
	draw_status    = main_dummy_ui_draw_status,
	dimensions     = main_dummy_ui_dimensions,
	refresh        = main_dummy_ui_refresh,
	set_on_key     = main_dummy_ui_set_on_key,
	set_on_paste   = main_dummy_ui_set_on_paste,
	set_ui_options = main_dummy_ui_set_ui_options,
}

// main_make_dummy_ui builds a heap dummy UI. Free with main_destroy_ui.
main_make_dummy_ui :: proc(allocator := context.allocator) -> ^User_Interface {
	ui := new(User_Interface, allocator)
	ui^ = User_Interface{data = nil, vtable = &main_dummy_ui_vtable}
	return ui
}

// main_make_ui builds the local UI for ui_type (C++ make_ui).
main_make_ui :: proc(ui_type: Main_UI_Type, allocator := context.allocator) -> ^User_Interface {
	switch ui_type {
	case .Terminal:
		return terminal_ui_make_ui(allocator)
	case .Json:
		return json_ui_make_ui(allocator)
	case .Dummy:
		return main_make_dummy_ui(allocator)
	}
	unreachable()
}

// main_destroy_ui releases a UI built by main_make_ui.
main_destroy_ui :: proc(ui: ^User_Interface, ui_type: Main_UI_Type, allocator := context.allocator) {
	switch ui_type {
	case .Terminal:
		terminal_ui_destroy_ui(ui, allocator)
	case .Json:
		json_ui_destroy_ui(ui, allocator)
	case .Dummy:
		free(ui, allocator)
	}
}

// main_show_startup_info shows the changelog since last_version (C++
// show_startup_info). The client takes ownership of the built lines.
main_show_startup_info :: proc(client: ^Client, last_version: int) {
	alloc := client.allocator
	faces := scope_faces(&scope_global_instance().scope)
	version_face := Face{attributes = {.Bold}}
	info := make(Display_Line_List, 0, alloc)
	for note in main_version_notes() {
		if note.version != 0 && note.version <= last_version {
			continue
		}
		if note.version == 0 {
			append(&info, client_display_line_from_text("• Development version", version_face, alloc))
		} else {
			year, month, day := note.version / 10000, (note.version / 100) % 100, note.version % 100
			append(
				&info,
				client_display_line_from_text(
					fmt.tprintf("• Kakoune v{}.{:02}.{:02}", year, month, day),
					version_face,
					alloc,
				),
			)
		}
		lines := strings.split(note.notes, "\n", alloc)
		defer delete(lines, alloc)
		for line in lines {
			if len(line) == 0 {
				continue
			}
			if parsed, err := display_buffer_parse_line(line, faces, nil, alloc); err == .None {
				append(&info, parsed)
			}
		}
	}
	if len(info) == 0 {
		delete(info)
		return
	}
	title_atoms := make([dynamic]Display_Atom, 0, 3, alloc)
	append(
		&title_atoms,
		Display_Atom{
			face = version_face,
			type = .Text,
			text = fmt.aprintf("Kakoune {}", main_kakoune_version, allocator = alloc),
		},
	)
	append(&title_atoms, Display_Atom{type = .Text, text = strings.clone(", more info at ", alloc)})
	append(
		&title_atoms,
		Display_Atom{
			face = Face{attributes = {.Underline}},
			type = .Text,
			text = strings.clone(":doc changelog", alloc),
		},
	)
	client_info_show(client, Display_Line{atoms = title_atoms}, info, Coord_Buffer{}, .Prompt)
}

// Server/client runtime state (C++ file-static local_client,
// convert_to_client_pending, run_server's terminate).
main_local_client: ^Client = nil
main_convert_to_client_pending := false
main_terminate := false

// main_fork_server_to_background double-forks the server into the
// background (C++ fork_server_to_background). Returns the child pid in
// the parent and 0 in the daemonized child.
main_fork_server_to_background :: proc(session: string) -> int {
	if pid := posix.fork(); pid != 0 {
		return int(pid)
	}
	posix.setsid()
	if posix.fork() != 0 {
		os.exit(0)
	}
	main_write_stderr(
		fmt.tprintf(
			"Kakoune forked server to background ({}), for session '{}'\n",
			posix.getpid(),
			session,
		),
	)
	return 0
}

@(private)
main_old_sigtstp_handler: Event_Manager_Signal_Handler = nil

main_sigtstp_handler :: proc "c" (sig: posix.Signal) {
	context = runtime.default_context()
	cm := client_manager_instance()
	if client_manager_count(cm) == 1 &&
	   len(cm.clients) > 0 &&
	   cm.clients[0] == main_local_client &&
	   !remote_server_instance().is_daemon {
		if main_old_sigtstp_handler != nil {
			main_old_sigtstp_handler(sig)
		}
		return
	}
	main_convert_to_client_pending = true
	event_manager_set_signal_handler(.SIGTSTP, main_old_sigtstp_handler)
}

// main_create_local_ui builds the server's local UI and arms the SIGTSTP
// convert-to-client handler (C++ create_local_ui).
main_create_local_ui :: proc(ui_type: Main_UI_Type, allocator := context.allocator) -> ^User_Interface {
	ui := main_make_ui(ui_type, allocator)
	old, _ := event_manager_set_signal_handler(.SIGTSTP, main_sigtstp_handler)
	main_old_sigtstp_handler = old
	return ui
}

main_client_on_exit_call :: proc(data: rawptr, status: int) {
	(^int)(data)^ = status
}

// main_run_client connects to session and runs the event loop until the
// session ends or the UI breaks (C++ run_client). Returns the exit status.
main_run_client :: proc(
	session: string,
	name: string,
	client_init: string,
	init_coord: Maybe(Coord_Buffer),
	ui_type: Main_UI_Type,
	suspend: bool,
	allocator := context.allocator,
) -> int {
	ui := main_make_ui(ui_type, allocator)
	defer main_destroy_ui(ui, ui_type, allocator)

	stdin_fd: Maybe(int) = nil
	if ui_type == .Terminal && posix.isatty(0) == false {
		if duped := posix.dup(0); duped != posix.FD(-1) {
			stdin_fd = int(duped)
		}
		if tty := posix.open("/dev/tty", {}); tty != posix.FD(-1) {
			posix.dup2(tty, 0)
			posix.close(tty)
		}
	}
	defer if fd, ok := stdin_fd.?; ok {
		posix.close(posix.FD(fd))
	}

	em: Event_Manager
	event_manager_init(&em, allocator)
	defer event_manager_destroy(&em)

	env, _ := env_vars_get(allocator)
	defer env_vars_free(&env, allocator)

	client: Remote_Client
	if err := remote_client_init(
		&client,
		session,
		name,
		ui,
		int(posix.getpid()),
		env,
		client_init,
		init_coord,
		stdin_fd,
		allocator,
	); err != .None {
		main_write_stderr("disconnected\ndisconnecting\n")
		return -1
	}
	defer remote_client_destroy(&client)

	if suspend {
		posix.kill(posix.getpid(), .SIGTSTP)
	}
	for client.exit_status == nil && user_interface_is_ok(ui) {
		event_manager_handle_next_events(.Normal)
	}
	if status, ok := client.exit_status.?; ok {
		return status
	}
	return -1
}

// main_run_server starts a session server and runs the main loop (C++
// run_server). Returns the process exit status.
main_run_server :: proc(
	session: string,
	server_init: string,
	client_init: string,
	init_buffer: string,
	init_coord: Maybe(Coord_Buffer),
	flags: Main_Server_Flags,
	ui_type: Main_UI_Type,
	debug_flags: string,
	files: []string,
	allocator := context.allocator,
) -> int {
	main_terminate = false
	term_handler :: proc "c" (sig: posix.Signal) {
		main_terminate = true
	}
	event_manager_set_signal_handler(.SIGTERM, term_handler)
	event_manager_set_signal_handler(.SIGINT, term_handler)
	if .Daemon in flags && len(session) == 0 {
		main_write_stderr("-d needs a session name to be specified with -s\n")
		return -1
	}

	em: Event_Manager
	event_manager_init(&em, allocator)
	defer event_manager_destroy(&em)

	server: Server
	session_name := session
	pid_name: string
	if len(session_name) == 0 {
		pid_name = main_itoa(int(posix.getpid()), allocator)
		defer delete(pid_name, allocator)
		session_name = pid_name
	}
	if err := remote_server_init(&server, session_name, .Daemon in flags, allocator); err != .None {
		return -1
	}
	defer remote_server_destroy(&server)

	env_descs := main_builtin_env_vars(allocator)
	defer delete(env_descs)
	scope_global_init(allocator)
	defer scope_global_deinit(allocator)
	shell_manager_init_singleton(env_descs, allocator)
	command_manager_init_singleton(allocator)
	register_manager_instance_init(allocator)
	highlighter_registry_instance_init(allocator)
	client_manager_instance_init(allocator)
	buffer_manager_instance_init(allocator)

	main_register_options(scope_global_option_registry(scope_global_instance()), allocator)
	main_register_registers(register_manager_instance(), allocator)
	main_register_keymaps(scope_keymaps(&scope_global_instance().scope))
	commands_register_all(command_manager_instance())
	highlighters_register()

	global := scope_global_instance()
	if opt, err := option_manager_get_option(scope_options(&global.scope), "debug"); err == .None {
		if parsed, perr := option_types_debug_flags_from_string(debug_flags); perr == .None {
			option_manager_option_set(opt, parsed, false)
		}
	}
	debug_write_to_debug_buffer("*** This is the debug buffer, where debug info will be written ***")

	startup_error := false
	if .Ignore_Kakrc not_in flags {
		init_ctx: Context
		context_init_empty(&init_ctx, allocator)
		defer context_destroy(&init_ctx)
		runtime := main_runtime_directory(allocator)
		defer delete(runtime, allocator)
		shell_ctx := Shell_Context{}
		if err, msg := command_manager_execute(
			command_manager_instance(),
			fmt.tprintf("source {}/kakrc", runtime),
			&init_ctx,
			&shell_ctx,
			allocator,
		); err != .None {
			startup_error = true
			debug_write_to_debug_buffer(fmt.tprintf("error while parsing kakrc:\n    {}", msg))
			delete(msg, allocator)
		}
	}

	{
		empty_ctx: Context
		context_init_empty(&empty_ctx, allocator)
		defer context_destroy(&empty_ctx)
		cwd, _ := file_real_path(".", allocator)
		defer delete(cwd, allocator)
		hook_manager_run_hook(scope_hooks(&global.scope), .Enter_Directory, cwd, &empty_ctx)
		hook_manager_run_hook(scope_hooks(&global.scope), .Kak_Begin, session, &empty_ctx)
	}

	if len(server_init) != 0 {
		init_ctx: Context
		context_init_empty(&init_ctx, allocator)
		defer context_destroy(&init_ctx)
		shell_ctx := Shell_Context{}
		// NOTE: the C++ also propagates kill_session's exit status here;
		// the Odin command manager has no kill channel yet, so every
		// failure is reported as a startup error.
		if err, msg := command_manager_execute(
			command_manager_instance(),
			server_init,
			&init_ctx,
			&shell_ctx,
			allocator,
		); err != .None {
			startup_error = true
			debug_write_to_debug_buffer(fmt.tprintf("error while running server init commands:\n    {}", msg))
			delete(msg, allocator)
		}
	}

	for file in files {
		buf, oerr := buffer_utils_open_or_create_file_buffer(file, {}, allocator)
		if oerr != .None || buf == nil {
			startup_error = true
			debug_write_to_debug_buffer(fmt.tprintf("error while opening file '{}'", file))
			continue
		}
		if .Read_Only in flags {
			buf.flags |= {.Read_Only}
			if opt, err := option_manager_get_local_option(
				scope_options(&buf.scope),
				"readonly",
				allocator,
			); err == .None {
				option_manager_option_set(opt, true)
			}
		}
	}

	exit_status := 0
	if ui_type == .Terminal && posix.isatty(0) == false {
		if fd := posix.dup(0); fd != posix.FD(-1) {
			if tty := posix.open("/dev/tty", {}); tty != posix.FD(-1) {
				posix.dup2(tty, 0)
				posix.close(tty)
			}
			buffer_utils_create_fifo_buffer("*stdin*", int(fd), Buffer_Flags{}, .Not_Initially)
		}
	}

	cm := client_manager_instance()
	bm := buffer_manager_instance()
	if !server.is_daemon {
		env, _ := env_vars_get(allocator)
		defer env_vars_free(&env, allocator)
		on_exit := Client_On_Exit_Callback{call = main_client_on_exit_call, data = &exit_status}
		local, cerr := client_manager_create_client(
			cm,
			main_create_local_ui(ui_type, allocator),
			int(posix.getpid()),
			"",
			env,
			client_init,
			init_buffer,
			init_coord,
			on_exit,
		)
		if cerr == .None {
			main_local_client = local
		}
		if startup_error && main_local_client != nil {
			faces := scope_faces(&global.scope)
			client_print_status(
				main_local_client,
				Display_Line{},
				client_display_line_from_text(
					"error during startup, see `:buffer *debug*` for details",
					client_face(faces, "Error"),
					main_local_client.allocator,
				),
				-1,
				.Status,
			)
		}
		if .Startup_Info in flags && main_local_client != nil {
			last_version := 0
			if opt, err := option_manager_get_option(
				scope_options(&global.scope),
				"startup_info_version",
			); err == .None {
				if v, ok := opt.value.(int); ok {
					last_version = v
				}
			}
			main_show_startup_info(main_local_client, last_version)
		}
	}

	for !main_terminate &&
	    (!client_manager_empty(cm) || remote_server_negotiating(&server) || server.is_daemon) {
		client_manager_redraw_clients(cm)
		timeout: Maybe(time.Duration) = nil
		if client_manager_has_pending_inputs(cm) {
			timeout = 0
		}
		for {
			handled, _ := event_manager_handle_next_events(.Normal, timeout)
			if !handled {
				break
			}
			if client_manager_process_pending_inputs(cm) {
				break
			}
			timeout = 0
		}
		client_manager_process_pending_inputs(cm)
		client_manager_clear_client_trash(cm)
		client_manager_clear_window_trash(cm)
		buffer_manager_clear_trash(bm)
		option_manager_registry_clear_trash(scope_global_option_registry(global))

		if main_local_client != nil {
			still_there := false
			for c in cm.clients {
				if c == main_local_client {
					still_there = true
					break
				}
			}
			if !still_there {
				main_local_client = nil
				if (!client_manager_empty(cm) || server.is_daemon) &&
				   main_fork_server_to_background(server.session) != 0 {
					os.exit(exit_status)
				}
			} else if main_convert_to_client_pending {
				// NOTE: the C++ re-execs this process as a client here via
				// an exception; without it, stay a server and clear the flag.
				main_convert_to_client_pending = false
			}
		}
	}

	{
		empty_ctx: Context
		context_init_empty(&empty_ctx, allocator)
		defer context_destroy(&empty_ctx)
		hook_manager_run_hook(scope_hooks(&global.scope), .Kak_End, "", &empty_ctx)
	}
	return exit_status
}

// main_run_filter applies keys to each file buffer and to stdin (C++
// run_filter). Returns 0.
main_run_filter :: proc(
	keystr: string,
	files: []string,
	quiet: bool,
	suffix_backup: string,
	allocator := context.allocator,
) -> int {
	scope_global_init(allocator)
	defer scope_global_deinit(allocator)
	em: Event_Manager
	event_manager_init(&em, allocator)
	defer event_manager_destroy(&em)
	env_descs := main_builtin_env_vars(allocator)
	defer delete(env_descs)
	shell_manager_init_singleton(env_descs, allocator)
	register_manager_instance_init(allocator)
	buffer_manager_instance_init(allocator)
	main_register_options(scope_global_option_registry(scope_global_instance()), allocator)
	main_register_registers(register_manager_instance(), allocator)

	keys, kerr := keys_parse(keystr, allocator)
	if kerr != .None {
		main_write_stderr(fmt.tprintf("error: bad keys '{}'\n", keystr))
		return 0
	}
	defer delete(keys)

	apply_to_buffer :: proc(buf: ^Buffer, keys: Keys_Key_List, quiet: bool, allocator: mem.Allocator) {
		sels := [1]Selection{
			{
				basic = {
					anchor = Coord_Buffer{},
					cursor = coord_buffer_and_target(buffer_back_coord(buf)),
				},
			},
		}
		list := selection_list_make(buf, sels[:], buffer_timestamp(buf), allocator)
		defer selection_list_destroy(&list)
		handler: Input_Handler
		input_handler_init(&handler, list, {.Draft}, "", allocator)
		defer input_handler_destroy(&handler)
		for key in keys {
			input_handler_handle_key(&handler, key)
		}
		_ = quiet
	}

	bm := buffer_manager_instance()
	// The C++ wraps the whole loop in try/catch: the first failure
	// aborts everything left, reports `error: {what}` unconditionally,
	// then still clears the trash and returns 0.
	ferr := Buffer_Utils_Error.None
	for file in files {
		if ferr != .None {
			break
		}
		buf, oerr := buffer_utils_open_file_buffer(file, {.No_Hooks}, allocator)
		if oerr != .None {
			ferr = oerr
			break
		}
		if len(suffix_backup) != 0 {
			name := strings.concatenate({buffer_filename(buf), suffix_backup}, allocator)
			defer delete(name, allocator)
			werr := buffer_utils_write_buffer_to_file(buf, name, .Overwrite)
			if werr != .None {
				buffer_manager_delete(bm, buf)
				ferr = werr
				break
			}
		}
		apply_to_buffer(buf, keys, quiet, allocator)
		werr := buffer_utils_write_buffer_to_file(buf, buffer_filename(buf), .Overwrite)
		buffer_manager_delete(bm, buf)
		if werr != .None {
			ferr = werr
			break
		}
	}
	if ferr == .None && posix.isatty(0) == false {
		if content, err := file_read_fd(0, false, allocator); err == .None {
			defer delete(content, allocator)
			buf, cerr := buffer_utils_create_buffer_from_string("*stdin*", {.No_Hooks}, content, allocator)
			if cerr != .None {
				ferr = cerr
			} else {
				apply_to_buffer(buf, keys, quiet, allocator)
				werr := buffer_utils_write_buffer_to_fd(buf, 1)
				buffer_manager_delete(bm, buf)
				if werr != .None {
					ferr = werr
				}
			}
		}
	}
	if ferr != .None {
		main_write_stderr(fmt.tprintf("error: {}\n", buffer_utils_error_message(ferr)))
	}
	buffer_manager_clear_trash(bm)
	return 0
}

// main_run_pipe sends stdin to session as commands (C++ run_pipe).
main_run_pipe :: proc(session: string, allocator := context.allocator) -> int {
	if content, err := file_read_fd(0, false, allocator); err == .None {
		defer delete(content, allocator)
		if serr := remote_send_command(session, content, allocator); serr != .None {
			main_write_stderr("disconnecting\n")
			return -1
		}
		return 0
	}
	return -1
}

@(private)
main_list_flag := false
@(private)
main_clear_flag := false

main_session_list_callback :: proc(name: string, st: posix.stat_t) {
	if len(name) > 0 && name[0] == '.' {
		return
	}
	up, _ := remote_check_session(name)
	if main_list_flag {
		main_write_stdout(fmt.tprintf("{}{}\n", name, "" if up else " (dead)"))
	}
	if !up && main_clear_flag {
		if path, err := remote_session_path(name, true, context.temp_allocator); err == .None {
			os.remove(path)
		}
	}
}

// main_list_sessions lists and optionally clears dead sessions (C++ -l).
main_list_sessions :: proc(list, clear: bool, allocator := context.allocator) -> int {
	main_list_flag = list
	main_clear_flag = clear
	dir := remote_session_directory(allocator)
	defer delete(dir, allocator)
	file_list_files(dir, main_session_list_callback)
	return 0
}

// main_show_usage prints the usage message (C++ show_usage). Returns 0.
main_show_usage :: proc(program: string, allocator := context.allocator) -> int {
	desc := main_param_desc(allocator)
	defer delete(desc.switches)
	doc := parameters_parser_generate_switches_doc(desc.switches, allocator)
	defer delete(doc, allocator)
	main_write_stdout(
		fmt.tprintf(
			"Usage: {} [options] [file]... [+<line>[:<col>]|+:]\n\nOptions:\n{}\n" +
			"Prefixing a positional argument with a plus (`+`) sign will place the\n" +
			"cursor at a given set of coordinates, or the end of the buffer if the plus\n" +
			"sign is followed only by a colon (`:`)\n",
			program,
			doc,
		),
	)
	return 0
}

main_noop_handler :: proc "c" (sig: posix.Signal) {
}

main_fatal_handler :: proc "c" (sig: posix.Signal) {
	context = runtime.default_context()
	terminal_ui_restore_terminal()
	name := "unknown"
	if sig == .SIGSEGV {
		name = "SIGSEGV"
	} else if sig == .SIGFPE {
		name = "SIGFPE"
	} else if sig == .SIGQUIT {
		name = "SIGQUIT"
	} else if sig == .SIGPIPE {
		name = "SIGPIPE"
	} else if sig == .SIGTERM {
		name = "SIGTERM"
	}
	msg := fmt.tprintf(
		"Received {}, exiting.\nPid: {}\nCallstack:\n{}",
		name,
		posix.getpid(),
		backtrace_desc(context.temp_allocator),
	)
	main_write_stderr(msg)
	assert_notify_fatal_error(msg)
	// NOTE: singletons may be only partially constructed here; the C++
	// guards with has_instance, mirrored by the nil/initialized checks.
	if remote_server_singleton != nil {
		remote_server_close_session(remote_server_instance())
	}
	if buffer_manager_has_instance {
		buffer_manager_backup_modified(buffer_manager_instance())
	}
	if sig == .SIGSEGV {
		// Re-raise with the default handler to generate a core dump.
		event_manager_set_signal_handler(.SIGSEGV, nil)
		posix.kill(posix.getpid(), .SIGSEGV)
	}
	// NOTE: the C++ calls abort() here; 134 is the SIGABRT exit status.
	os.exit(134)
}

// main_install_signal_handlers installs the fatal-signal handlers (C++
// top of main). SIGTTOU ignores and SIGPIPE/SIGINT/SIGCHLD no-op.
main_install_signal_handlers :: proc() {
	event_manager_set_signal_handler(.SIGSEGV, main_fatal_handler)
	event_manager_set_signal_handler(.SIGFPE, main_fatal_handler)
	event_manager_set_signal_handler(.SIGQUIT, main_fatal_handler)
	event_manager_set_signal_handler(.SIGTERM, main_fatal_handler)
	event_manager_set_signal_handler(.SIGPIPE, main_noop_handler)
	event_manager_set_signal_handler(.SIGINT, main_noop_handler)
	event_manager_set_signal_handler(.SIGCHLD, main_noop_handler)
	event_manager_set_signal_handler(.SIGTTOU, main_noop_handler)
}

// main_entry is the kak entry point for a future `package main` (C++
// main): parse argv, classify the mode, and dispatch. argv includes the
// program name at index 0. Returns the process exit status.
main_entry :: proc(argv: []string, allocator := context.allocator) -> int {
	main_install_signal_handlers()
	program := "kak"
	rest: []string
	if len(argv) > 0 {
		program = argv[0]
		rest = argv[1:]
	}
	args, perr := main_parse_args(rest, allocator)
	if perr != .None {
		desc := main_param_desc(allocator)
		defer delete(desc.switches)
		doc := parameters_parser_generate_switches_doc(desc.switches, allocator)
		defer delete(doc, allocator)
		main_write_stderr(fmt.tprintf("Error while parsing parameters\nValid switches:\n{}", doc))
		return -1
	}
	defer main_args_destroy(&args, allocator)

	session_up := false
	if args.connect_or_create {
		if up, err := remote_check_session(args.session); err == .None {
			session_up = up
		}
	}
	mode, cerr := main_classify_args(&args, session_up)
	if cerr != .None {
		msg := main_error_message(cerr, context.temp_allocator)
		main_write_stderr(fmt.tprintf("error: {}\n", msg))
		return -1
	}

	status := -1
	switch mode {
	case .Show_Help:
		status = main_show_usage(program, allocator)
	case .Show_Version:
		main_write_stdout(fmt.tprintf("Kakoune {}\n", main_kakoune_version))
		status = 0
	case .List_Sessions:
		status = main_list_sessions(args.list_sessions, args.clear_sessions, allocator)
	case .Pipe:
		status = main_run_pipe(args.pipe.? or_else "", allocator)
	case .Filter:
		status = main_run_filter(
			args.filter_keys.? or_else "",
			args.files[:],
			args.filter_quiet,
			args.filter_backup,
			allocator,
		)
	case .Client:
		if args.ignore_kakrc || args.daemon || len(args.server_init) != 0 || args.readonly {
			main_write_stderr("error: -n/-d/-E/-ro incompatible with connecting to an existing session\n")
			return -1
		}
		init := main_client_init_for_files(args.files[:], args.init_coord, args.client_init, allocator)
		defer delete(init, allocator)
		status = main_run_client(args.session, "", init, args.init_coord, args.ui, false, allocator)
	case .Server:
		flags := main_server_flags(&args, len(argv), bool(posix.isatty(0)))
		init_buffer := ""
		if len(args.files) > 0 {
			init_buffer = args.files[0]
		}
		status = main_run_server(
			args.session,
			args.server_init,
			args.client_init,
			init_buffer,
			args.init_coord,
			flags,
			args.ui,
			args.debug_flags,
			args.files[:],
			allocator,
		)
	}
	return status
}

// --- Stubs: called-but-unmerged procs (STUB protocol; coordinator deletes
// these when the real procs merge) ---

commands_register_all :: proc(m: ^Command_Manager) {
	panic("STUB: commands_register_all")
}

// buffer_utils open/create/write/history procs merged from the
// buffer_utils module; stubs deleted. (main's write_to_file/write_to_fd
// guesses were renamed to write_buffer_to_file/write_buffer_to_fd.)
