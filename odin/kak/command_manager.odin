// Port of Kakoune's src/command_manager.{hh,cc}: command line lexing,
// command/module registry, expansion and completion.
//
// The lexer (Command_Parser/read_token plus the parse_* helpers) is pure
// logic over the input string and is fully tested. Everything needing a
// Context (execution, expansion backends, completion sources) is ported
// faithfully but calls STUB procs from unmerged modules (context,
// option_manager, shell_manager, register_manager, alias_registry,
// completion, scope, debug); those paths are untestable until the stubs
// resolve and are listed as gaps in the test report.
//
// Error model: C++ throws runtime_error/failure/parse_error. Here every
// fallible proc returns (Command_Manager_Error, msg) where msg is an
// owned message (delete it) when err != .None and "" otherwise. .Fail
// ports C++ `failure`: it propagates through execute undecorated, while
// .Error (runtime/parse errors) gets the "line:col: 'cmd': ..." prefix.
// A returned Token/Completions is only valid when err == .None.
//
// Ownership: Token.content is always heap-allocated (even when empty),
// the caller frees it with delete (or command_manager_free_token).
// Completions candidates own their strings (command_manager_free_completions).
// The manager owns command names, docstrings and switch tables (cloned
// on registration) plus module names/commands; release with
// command_manager_destroy (callbacks' data is released through their
// destroy procs when set).
//
// Deviations from the C++:
//   * The char/Codepoint parse_quoted overloads merge into one rune-based
//     proc; behavior is identical (a multibyte char never equals an ASCII
//     delimiter, and non-ASCII delimiters compare as codepoints).
//   * Command_Func.call in knot.odin returns void, so errors raised by a
//     command body cannot propagate back through execute_single_command
//     (C++ rethrows them). Nested `fail` propagation is impossible until
//     the knot callback signature carries errors.
//   * parameters_parser_parse drops the offending token, so parameter
//     errors render with an empty name; switch-argument completion always
//     yields nothing (the merged desc drops the arg completer).
//   * FileExpand errors lose the errno detail ("name: unable to read
//     file") because the merged file module returns only File_Error.
package kak

import "core:mem"
import "core:strings"
import "core:unicode"

// Command_Manager_Error ports the C++ exception outcomes. None is success.
Command_Manager_Error :: enum {
	None,
	// C++ `failure`: control flow, propagates through execute undecorated.
	Fail,
	// C++ runtime_error/parse_error, detail carried in the owned msg.
	Error,
}

// Command_Manager_Parse_Result is the C++ ParseResult: owned content plus
// whether the closing delimiter was found.
Command_Manager_Parse_Result :: struct {
	content:    string,
	terminated: bool,
}

// Command_Manager_Completer ports C++ CommandManager::Completer (the
// stateful command line completer). last_complete_command is owned;
// release with command_manager_completer_destroy.
Command_Manager_Completer :: struct {
	last_complete_command: string,
	command_completer:     Command_Completer,
	allocator:              mem.Allocator,
}

// Command_Manager_Nested_Completer ports C++ NestedCompleter. Same
// ownership as Command_Manager_Completer.
Command_Manager_Nested_Completer :: struct {
	last_complete_command: string,
	command_completer:     Command_Completer,
	allocator:              mem.Allocator,
}

// Command_Manager_Postprocess ports the C++ expand postprocess callback
// (FunctionRef<String (String)>). It borrows s and returns an owned
// string; expand frees the result after appending it.
Command_Manager_Postprocess :: #type proc(s: string, allocator: mem.Allocator) -> string

// command_manager_singleton is the C++ Singleton<CommandManager> instance.
// Initialise once with command_manager_init_singleton before use.
command_manager_singleton: Command_Manager

// command_manager_instance returns the singleton (C++ Singleton::instance).
command_manager_instance :: proc() -> ^Command_Manager {
	return &command_manager_singleton
}

// command_manager_init_singleton initialises the singleton instance.
command_manager_init_singleton :: proc(allocator := context.allocator) {
	command_manager_singleton = command_manager_make(allocator)
}

// command_manager_make creates an empty manager (C++ CommandManager ctor).
command_manager_make :: proc(allocator := context.allocator) -> Command_Manager {
	return Command_Manager {
		commands = make(map[string]Command_Manager_Command, 0, allocator),
		modules = make(map[string]Command_Manager_Module, 0, allocator),
		allocator = allocator,
	}
}

// command_manager_free_command_value releases one command's owned strings
// and callback data (but not the map key, owned by the map slot).
command_manager_free_command_value :: proc(m: ^Command_Manager, cmd: Command_Manager_Command) {
	delete(cmd.docstring, m.allocator)
	for sw_name, sw_desc in cmd.param_desc.switches {
		delete(sw_name, m.allocator)
		delete(sw_desc.description, m.allocator)
	}
	delete(cmd.param_desc.switches)
	if cmd.func.destroy != nil {
		cmd.func.destroy(cmd.func.data, m.allocator)
	}
	if cmd.helper.destroy != nil {
		cmd.helper.destroy(cmd.helper.data, m.allocator)
	}
	if cmd.completer.destroy != nil {
		cmd.completer.destroy(cmd.completer.data, m.allocator)
	}
}

// command_manager_destroy releases all manager-owned memory.
command_manager_destroy :: proc(m: ^Command_Manager) {
	for name, cmd in m.commands {
		delete(name, m.allocator)
		command_manager_free_command_value(m, cmd)
	}
	delete(m.commands)
	for name, mod in m.modules {
		delete(name, m.allocator)
		delete(mod.commands, m.allocator)
	}
	delete(m.modules)
	m^ = {}
}

// command_manager_is_separator reports whether c ends a command (C++
// anonymous-namespace is_command_separator).
command_manager_is_separator :: proc(c: byte) -> bool {
	return c == ';' || c == '\n'
}

// command_manager_is_horizontal_blank ports C++ is_ascii_horizontal_blank
// (exactly tab, form-feed and space; newline is a separator instead).
command_manager_is_horizontal_blank :: proc(c: byte) -> bool {
	return c == '\t' || c == '\f' || c == ' '
}

// command_manager_parse_quoted reads until the closing delimiter (C++
// parse_quoted; the char and Codepoint overloads merged). A doubled
// delimiter yields one literal delimiter. The returned content is owned.
command_manager_parse_quoted :: proc(
	state: ^Parse_State,
	delimiter: rune,
	allocator := context.allocator,
) -> Command_Manager_Parse_Result {
	s := state.str
	end := len(s)
	beg := state.pos
	pos := state.pos
	b := strings.builder_make(allocator)
	for pos < end {
		cur := pos
		c := utf8_read_codepoint(s, &pos)
		if c == delimiter {
			next := pos
			single := true
			if next < end {
				probe := next
				if utf8_read_codepoint(s, &probe) == delimiter {
					single = false
				}
			}
			if single {
				strings.write_string(&b, s[beg:cur])
				state.pos = pos
				return {strings.to_string(b), true}
			}
			// Doubled delimiter: emit up to and including the first one,
			// then skip the second.
			strings.write_string(&b, s[beg:pos])
			after := pos
			_ = utf8_read_codepoint(s, &after)
			pos = after
			beg = after
		}
	}
	strings.write_string(&b, s[beg:end])
	state.pos = pos
	return {strings.to_string(b), false}
}

// command_manager_parse_quoted_balanced reads until the closing delimiter
// balancing nested pairs (C++ parse_quoted_balanced). state.pos must be
// just past the opening delimiter. The returned content is owned.
command_manager_parse_quoted_balanced :: proc(
	state: ^Parse_State,
	opening, closing: byte,
	allocator := context.allocator,
) -> Command_Manager_Parse_Result {
	s := state.str
	end := len(s)
	level := 1
	pos := state.pos
	beg := pos
	for pos < end {
		c := s[pos]
		pos += 1
		if c == opening {
			level += 1
		} else if c == closing {
			level -= 1
			if level == 0 {
				break
			}
		}
	}
	state.pos = pos
	terminated := level == 0
	cut := pos
	if terminated {
		cut -= 1
	}
	return {strings.clone(s[beg:cut], allocator), terminated}
}

// command_manager_parse_unquoted reads a bare token up to a separator or
// horizontal blank (C++ parse_unquoted). A backslash directly before a
// separator or blank escapes it (the backslash is dropped). The result is
// owned; state.pos stops at the terminator (or the end).
command_manager_parse_unquoted :: proc(
	state: ^Parse_State,
	allocator := context.allocator,
) -> string {
	s := state.str
	end := len(s)
	beg := state.pos
	pos := state.pos
	b := strings.builder_make(allocator)
	for pos < end {
		c := s[pos]
		if command_manager_is_separator(c) || command_manager_is_horizontal_blank(c) {
			strings.write_string(&b, s[beg:pos])
			if pos != beg && s[pos - 1] == '\\' {
				b.buf[len(b.buf) - 1] = c
				pos += 1
				beg = pos
				continue
			}
			state.pos = pos
			return strings.to_string(b)
		}
		pos += 1
	}
	strings.write_string(&b, s[beg:end])
	state.pos = pos
	return strings.to_string(b)
}

// command_manager_token_type maps a %x type name to its token type (C++
// token_type). Unknown names are Raw_Quoted unless throw_on_invalid, in
// which case they are a parse error with an owned message.
command_manager_token_type :: proc(
	type_name: string,
	throw_on_invalid: bool,
	allocator := context.allocator,
) -> (Token_Type, Command_Manager_Error, string) {
	switch type_name {
	case "":
		return .Raw_Quoted, .None, ""
	case "sh":
		return .Shell_Expand, .None, ""
	case "reg":
		return .Register_Expand, .None, ""
	case "opt":
		return .Option_Expand, .None, ""
	case "val":
		return .Val_Expand, .None, ""
	case "arg":
		return .Arg_Expand, .None, ""
	case "file":
		return .File_Expand, .None, ""
	case "exp":
		return .Expand, .None, ""
	}
	if throw_on_invalid {
		b := strings.builder_make(allocator)
		strings.write_string(&b, "parse error: unknown expand '")
		strings.write_string(&b, type_name)
		strings.write_string(&b, "'")
		return .Raw_Quoted, .Error, strings.to_string(b)
	}
	return .Raw_Quoted, .None, ""
}

// command_manager_skip_blanks_and_comments skips horizontal blanks,
// backslash-newline continuations and #-to-newline comments (C++
// skip_blanks_and_comments).
command_manager_skip_blanks_and_comments :: proc(state: ^Parse_State) {
	s := state.str
	for state.pos < len(s) {
		c := s[state.pos]
		if command_manager_is_horizontal_blank(c) {
			state.pos += 1
		} else if c == '\\' && state.pos + 1 < len(s) && s[state.pos + 1] == '\n' {
			state.pos += 2
		} else if c == '#' {
			for state.pos < len(s) && s[state.pos] != '\n' {
				state.pos += 1
			}
		} else {
			break
		}
	}
}

// command_manager_compute_coord counts lines/columns over s (C++
// compute_coord): newlines start a new line, every other byte is one
// column.
command_manager_compute_coord :: proc(s: string) -> Coord_Buffer {
	coord := Coord_Buffer{}
	for i := 0; i < len(s); i += 1 {
		if s[i] == '\n' {
			coord.line += 1
			coord.column = 0
		} else {
			coord.column += 1
		}
	}
	return coord
}

// command_manager_expected_delimiter_error builds the "expected a string
// delimiter" parse error message (owned).
command_manager_expected_delimiter_error :: proc(
	type_name: string,
	allocator := context.allocator,
) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "parse error: expected a string delimiter after '%")
	strings.write_string(&b, type_name)
	strings.write_string(&b, "'")
	return strings.to_string(b)
}

// command_manager_unterminated_error builds the "line:col: unterminated
// string" parse error message (owned). open and close are the delimiter
// runes shown around the "...".
command_manager_unterminated_error :: proc(
	str: string,
	content_start: int,
	type_name: string,
	open, close: rune,
	allocator := context.allocator,
) -> string {
	coord := command_manager_compute_coord(str[:content_start])
	b := strings.builder_make(allocator)
	strings.write_string(&b, "parse error: ")
	strings.write_int(&b, int(coord.line) + 1)
	strings.write_byte(&b, ':')
	strings.write_int(&b, int(coord.column) + 1)
	strings.write_string(&b, ": unterminated string '%")
	strings.write_string(&b, type_name)
	strings.write_rune(&b, open)
	strings.write_string(&b, "...")
	strings.write_rune(&b, close)
	strings.write_string(&b, "'")
	return strings.to_string(b)
}

// command_manager_parse_percent_token parses a %x<delim>... token (C++
// parse_percent_token). state.pos must be just past the '%'. The token
// content is owned; the token is only valid when err == .None.
command_manager_parse_percent_token :: proc(
	state: ^Parse_State,
	throw_on_unterminated: bool,
	allocator := context.allocator,
) -> (Token, Command_Manager_Error, string) {
	s := state.str
	pos := state.pos
	type_start := pos
	for pos < len(s) && s[pos] >= 'a' && s[pos] <= 'z' {
		pos += 1
	}
	type_name := s[type_start:pos]
	state.pos = pos
	if pos >= len(s) {
		if throw_on_unterminated {
			return {}, .Error, command_manager_expected_delimiter_error(type_name, allocator)
		}
		return Token{content = strings.clone("", allocator)}, .None, ""
	}
	read_pos := pos
	opening := utf8_read_codepoint(s, &read_pos)
	state.pos = read_pos
	if unicode.is_alpha(opening) {
		if throw_on_unterminated {
			return {}, .Error, command_manager_expected_delimiter_error(type_name, allocator)
		}
		return Token{content = strings.clone("", allocator)}, .None, ""
	}

	tok_type, type_err, type_msg := command_manager_token_type(type_name, throw_on_unterminated, allocator)
	if type_err != .None {
		return {}, type_err, type_msg
	}

	start := state.pos
	byte_pos := Units_ByteCount(start)

	if opening == '(' || opening == '[' || opening == '{' || opening == '<' {
		closing := byte('>')
		if opening == '(' {
			closing = ')'
		} else if opening == '[' {
			closing = ']'
		} else if opening == '{' {
			closing = '}'
		}
		quoted := command_manager_parse_quoted_balanced(state, byte(opening), closing, allocator)
		if throw_on_unterminated && !quoted.terminated {
			msg := command_manager_unterminated_error(s, start, type_name, opening, rune(closing), allocator)
			delete(quoted.content, allocator)
			return {}, .Error, msg
		}
		return Token{type = tok_type, pos = byte_pos, content = quoted.content, terminated = quoted.terminated}, .None, ""
	}

	quoted := command_manager_parse_quoted(state, opening, allocator)
	if throw_on_unterminated && !quoted.terminated {
		msg := command_manager_unterminated_error(s, start, type_name, opening, opening, allocator)
		delete(quoted.content, allocator)
		return {}, .Error, msg
	}
	return Token{type = tok_type, pos = byte_pos, content = quoted.content, terminated = quoted.terminated}, .None, ""
}

// command_manager_parser_make creates a parser over command_line (C++
// CommandParser ctor). It borrows the line.
command_manager_parser_make :: proc(command_line: string) -> Command_Parser {
	return Command_Parser{state = Parse_State{str = command_line, pos = 0}}
}

// command_manager_parser_pos returns the current byte offset (C++
// CommandParser::pos).
command_manager_parser_pos :: proc(p: ^Command_Parser) -> int {
	return p.state.pos
}

// command_manager_parser_done reports whether the input is exhausted (C++
// CommandParser::done).
command_manager_parser_done :: proc(p: ^Command_Parser) -> bool {
	return p.state.pos >= len(p.state.str)
}

// command_manager_read_token reads the next token (C++
// CommandParser::read_token). The token content is owned; ok is false at
// end of input. On error returns err with an owned message.
command_manager_read_token :: proc(
	p: ^Command_Parser,
	throw_on_unterminated: bool,
	allocator := context.allocator,
) -> (Token, bool, Command_Manager_Error, string) {
	command_manager_skip_blanks_and_comments(&p.state)
	s := p.state.str
	if p.state.pos >= len(s) {
		return {}, false, .None, ""
	}
	start := p.state.pos
	c := s[p.state.pos]
	if c == '"' || c == '\'' {
		p.state.pos += 1
		content_start := p.state.pos
		quoted := command_manager_parse_quoted(&p.state, rune(c), allocator)
		if throw_on_unterminated && !quoted.terminated {
			delete(quoted.content, allocator)
			b := strings.builder_make(allocator)
			strings.write_string(&b, "parse error: unterminated string ")
			strings.write_byte(&b, c)
			strings.write_string(&b, "...")
			strings.write_byte(&b, c)
			return {}, false, .Error, strings.to_string(b)
		}
		tok_type := Token_Type.Expand if c == '"' else Token_Type.Raw_Quoted
		return Token{type = tok_type, pos = Units_ByteCount(content_start), content = quoted.content, terminated = quoted.terminated}, true, .None, ""
	} else if c == '%' {
		p.state.pos += 1
		tok, err, msg := command_manager_parse_percent_token(&p.state, throw_on_unterminated, allocator)
		if err != .None {
			return {}, false, err, msg
		}
		return tok, true, .None, ""
	} else if command_manager_is_separator(c) {
		p.state.pos += 1
		return Token{type = .Command_Separator, pos = Units_ByteCount(p.state.pos), content = strings.clone("", allocator)}, true, .None, ""
	}
	if c == '\\' && p.state.pos + 1 < len(s) {
		next := s[p.state.pos + 1]
		if next == '%' || next == '\'' || next == '"' {
			p.state.pos += 1
		}
	}
	content := command_manager_parse_unquoted(&p.state, allocator)
	return Token{type = .Raw, pos = Units_ByteCount(start), content = content}, true, .None, ""
}

// command_manager_free_token releases a token's owned content.
command_manager_free_token :: proc(tok: ^Token, allocator := context.allocator) {
	delete(tok.content, allocator)
	tok^ = {}
}

// command_manager_resolve_alias resolves a command name through the
// aliases (C++ resolve_alias). The result is borrowed.
command_manager_resolve_alias :: proc(ctx: ^Context, name: string) -> string {
	alias := alias_registry_get(context_aliases(ctx), name)
	if len(alias) == 0 {
		return name
	}
	return alias
}

// command_manager_expand_token_single expands one token to a single owned
// string (C++ expand_token<String>). Takes ownership of token.content.
command_manager_expand_token_single :: proc(
	token: Token,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
	allocator := context.allocator,
) -> (string, Command_Manager_Error, string) {
	content := token.content
	switch token.type {
	case .Shell_Expand:
		out := shell_manager_eval(content, ctx, shell_ctx, allocator)
		delete(content, allocator)
		if len(out) > 0 && out[len(out) - 1] == '\n' {
			trimmed := strings.clone(out[:len(out) - 1], allocator)
			delete(out, allocator)
			out = trimmed
		}
		return out, .None, ""
	case .Register_Expand:
		out := strings.clone(context_main_sel_register_value(ctx, content), allocator)
		delete(content, allocator)
		return out, .None, ""
	case .Option_Expand:
		opt, get_err := option_manager_get_option(context_options(ctx), content)
		if get_err != .None {
			parts := [3]string{"option not found: '", content, "'. Use declare-option first"}
			msg := strings.concatenate(parts[:], allocator)
			delete(content, allocator)
			return "", .Error, msg
		}
		out := option_manager_option_get_as_string(opt, .Raw, allocator)
		delete(content, allocator)
		return out, .None, ""
	case .Val_Expand:
		if value, found := shell_ctx.env_vars[content]; found {
			out := strings.clone(value, allocator)
			delete(content, allocator)
			return out, .None, ""
		}
		vals := shell_manager_get_val(content, ctx, allocator)
		delete(content, allocator)
		out := string_utils_join_char(vals[:], ' ', false, allocator)
		for v in vals {
			delete(v, allocator)
		}
		delete(vals)
		return out, .None, ""
	case .Arg_Expand:
		if content == "@" {
			out := string_utils_join_char(shell_ctx.params, ' ', false, allocator)
			delete(content, allocator)
			return out, .None, ""
		}
		arg, conv_err := string_utils_str_to_int(content)
		delete(content, allocator)
		if conv_err != .None || arg < 1 {
			return "", .Error, strings.clone("invalid argument index", allocator)
		}
		if arg <= len(shell_ctx.params) {
			return strings.clone(shell_ctx.params[arg - 1], allocator), .None, ""
		}
		return strings.clone("", allocator), .None, ""
	case .File_Expand:
		data, file_err := file_read_file(content, false, allocator)
		if file_err != .None {
			b := strings.builder_make(allocator)
			strings.write_string(&b, content)
			strings.write_string(&b, ": unable to read file")
			delete(content, allocator)
			return "", .Error, strings.to_string(b)
		}
		delete(content, allocator)
		return data, .None, ""
	case .Expand:
		out, err, msg := command_manager_expand(content, ctx, shell_ctx, allocator)
		delete(content, allocator)
		return out, err, msg
	case .Raw, .Raw_Quoted:
		return content, .None, ""
	case .Command_Separator:
		unreachable()
	}
	unreachable()
}

// command_manager_expand_token_multi expands one token, appending the
// owned results to params (C++ expand_token<Vector<String>>). Takes
// ownership of token.content.
command_manager_expand_token_multi :: proc(
	token: Token,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
	params: ^[dynamic]string,
	allocator := context.allocator,
) -> (Command_Manager_Error, string) {
	content := token.content
	switch token.type {
	case .Shell_Expand:
		out := shell_manager_eval(content, ctx, shell_ctx, allocator)
		delete(content, allocator)
		if len(out) > 0 && out[len(out) - 1] == '\n' {
			trimmed := strings.clone(out[:len(out) - 1], allocator)
			delete(out, allocator)
			out = trimmed
		}
		append(params, out)
		return .None, ""
	case .Register_Expand:
		vals := register_manager_get_strings(content, ctx, allocator)
		delete(content, allocator)
		for v in vals {
			append(params, v)
		}
		delete(vals)
		return .None, ""
	case .Option_Expand:
		opt, get_err := option_manager_get_option(context_options(ctx), content)
		if get_err != .None {
			parts := [3]string{"option not found: '", content, "'. Use declare-option first"}
			msg := strings.concatenate(parts[:], allocator)
			delete(content, allocator)
			return .Error, msg
		}
		strs := option_manager_option_get_as_strings(opt, allocator)
		delete(content, allocator)
		for s in strs {
			append(params, s)
		}
		delete(strs)
		return .None, ""
	case .Val_Expand:
		if value, found := shell_ctx.env_vars[content]; found {
			append(params, strings.clone(value, allocator))
			delete(content, allocator)
			return .None, ""
		}
		vals := shell_manager_get_val(content, ctx, allocator)
		delete(content, allocator)
		for v in vals {
			append(params, v)
		}
		delete(vals)
		return .None, ""
	case .Arg_Expand:
		if content == "@" {
			for p in shell_ctx.params {
				append(params, strings.clone(p, allocator))
			}
			delete(content, allocator)
			return .None, ""
		}
		arg, conv_err := string_utils_str_to_int(content)
		delete(content, allocator)
		if conv_err != .None || arg < 1 {
			return .Error, strings.clone("invalid argument index", allocator)
		}
		if arg <= len(shell_ctx.params) {
			append(params, strings.clone(shell_ctx.params[arg - 1], allocator))
		} else {
			append(params, strings.clone("", allocator))
		}
		return .None, ""
	case .File_Expand:
		data, file_err := file_read_file(content, false, allocator)
		if file_err != .None {
			b := strings.builder_make(allocator)
			strings.write_string(&b, content)
			strings.write_string(&b, ": unable to read file")
			delete(content, allocator)
			return .Error, strings.to_string(b)
		}
		delete(content, allocator)
		append(params, data)
		return .None, ""
	case .Expand:
		out, err, msg := command_manager_expand(content, ctx, shell_ctx, allocator)
		delete(content, allocator)
		if err != .None {
			return err, msg
		}
		append(params, out)
		return .None, ""
	case .Raw, .Raw_Quoted:
		append(params, content)
		return .None, ""
	case .Command_Separator:
		unreachable()
	}
	unreachable()
}

// command_manager_expand_identity is the default expand postprocess: it
// clones its input (C++ `[](String s){ return s; }`).
command_manager_expand_identity :: proc(s: string, allocator: mem.Allocator) -> string {
	return strings.clone(s, allocator)
}

// command_manager_expand_impl expands %x{...} interpolations in str (C++
// expand_impl). %% yields a literal %. The result is owned.
command_manager_expand_impl :: proc(
	str: string,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
	postprocess: Command_Manager_Postprocess,
	allocator := context.allocator,
) -> (string, Command_Manager_Error, string) {
	b := strings.builder_make(allocator)
	beg := 0
	pos := 0
	for pos < len(str) {
		if str[pos] == '%' {
			pos += 1
			if pos < len(str) && str[pos] == '%' {
				strings.write_string(&b, str[beg:pos])
				pos += 1
				beg = pos
			} else {
				strings.write_string(&b, str[beg:pos - 1])
				ps := Parse_State{str = str, pos = pos}
				tok, tok_err, tok_msg := command_manager_parse_percent_token(&ps, true, allocator)
				if tok_err != .None {
					strings.builder_destroy(&b)
					return "", tok_err, tok_msg
				}
				expanded, exp_err, exp_msg := command_manager_expand_token_single(tok, ctx, shell_ctx, allocator)
				if exp_err != .None {
					strings.builder_destroy(&b)
					return "", exp_err, exp_msg
				}
				processed := postprocess(expanded, allocator)
				strings.write_string(&b, processed)
				delete(processed, allocator)
				delete(expanded, allocator)
				pos = ps.pos
				beg = pos
			}
		} else {
			pos += 1
		}
	}
	strings.write_string(&b, str[beg:pos])
	return strings.to_string(b), .None, ""
}

// command_manager_expand expands %x{...} interpolations in str (C++
// expand without postprocess). The result is owned.
command_manager_expand :: proc(
	str: string,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
	allocator := context.allocator,
) -> (string, Command_Manager_Error, string) {
	return command_manager_expand_impl(str, ctx, shell_ctx, command_manager_expand_identity, allocator)
}

// command_manager_expand_with_postprocess expands str, mapping every
// expansion through postprocess (C++ expand with postprocess). The
// result is owned.
command_manager_expand_with_postprocess :: proc(
	str: string,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
	postprocess: Command_Manager_Postprocess,
	allocator := context.allocator,
) -> (string, Command_Manager_Error, string) {
	return command_manager_expand_impl(str, ctx, shell_ctx, postprocess, allocator)
}

// command_manager_command_defined reports whether a command is registered
// (C++ CommandManager::command_defined).
command_manager_command_defined :: proc(m: ^Command_Manager, name: string) -> bool {
	_, found := m.commands[name]
	return found
}

// command_manager_register_command registers (or replaces) a command (C++
// CommandManager::register_command). The manager clones the name,
// docstring and switch table; callback structs are copied.
command_manager_register_command :: proc(
	m: ^Command_Manager,
	name: string,
	fn: Command_Func,
	docstring: string,
	param_desc: Parameters_Parser_Desc,
	flags: Command_Flags = {},
	helper: Command_Helper = {},
	completer: Command_Completer = {},
) {
	switches := make(map[string]Parameters_Parser_Switch_Desc, len(param_desc.switches), m.allocator)
	for sw_name, sw_desc in param_desc.switches {
		switches[strings.clone(sw_name, m.allocator)] = Parameters_Parser_Switch_Desc {
			takes_argument = sw_desc.takes_argument,
			description    = strings.clone(sw_desc.description, m.allocator),
		}
	}
	value := Command_Manager_Command {
		func       = fn,
		docstring  = strings.clone(docstring, m.allocator),
		param_desc = Parameters_Parser_Desc {
			switches        = switches,
			flags           = param_desc.flags,
			min_positionals = param_desc.min_positionals,
			max_positionals = param_desc.max_positionals,
		},
		flags      = flags,
		helper     = helper,
		completer  = completer,
	}
	if old, exists := m.commands[name]; exists {
		command_manager_free_command_value(m, old)
		m.commands[name] = value
		return
	}
	m.commands[strings.clone(name, m.allocator)] = value
}

// command_manager_set_command_completer replaces a command's completer
// (C++ CommandManager::set_command_completer). Unknown commands are an
// error with an owned message.
command_manager_set_command_completer :: proc(
	m: ^Command_Manager,
	name: string,
	completer: Command_Completer,
	allocator := context.allocator,
) -> (Command_Manager_Error, string) {
	cmd, found := m.commands[name]
	if !found {
		b := strings.builder_make(allocator)
		strings.write_string(&b, "no such command '")
		strings.write_string(&b, name)
		strings.write_string(&b, "'")
		return .Error, strings.to_string(b)
	}
	if cmd.completer.destroy != nil {
		cmd.completer.destroy(cmd.completer.data, m.allocator)
	}
	cmd.completer = completer
	m.commands[name] = cmd
	return .None, ""
}

// command_manager_module_defined reports whether a module is registered
// (C++ CommandManager::module_defined).
command_manager_module_defined :: proc(m: ^Command_Manager, name: string) -> bool {
	_, found := m.modules[name]
	return found
}

// command_manager_register_module registers a module's commands (C++
// CommandManager::register_module). Re-registering a loading/loaded
// module is an error with an owned message.
command_manager_register_module :: proc(
	m: ^Command_Manager,
	name: string,
	commands: string,
	allocator := context.allocator,
) -> (Command_Manager_Error, string) {
	if mod, exists := m.modules[name]; exists && mod.state != .Registered {
		b := strings.builder_make(allocator)
		strings.write_string(&b, "module already loaded: '")
		strings.write_string(&b, name)
		strings.write_string(&b, "'")
		return .Error, strings.to_string(b)
	}
	if old, exists := m.modules[name]; exists {
		delete(old.commands, m.allocator)
		old.state = .Registered
		old.commands = strings.clone(commands, m.allocator)
		m.modules[name] = old
		return .None, ""
	}
	m.modules[strings.clone(name, m.allocator)] = Command_Manager_Module {
		state    = .Registered,
		commands = strings.clone(commands, m.allocator),
	}
	return .None, ""
}

// command_manager_loaded_modules returns the owned names of loaded
// modules (C++ CommandManager::loaded_modules, a HashSet<String> here
// returned as a list). The caller frees the strings and the list.
command_manager_loaded_modules :: proc(
	m: ^Command_Manager,
	allocator := context.allocator,
) -> [dynamic]string {
	modules := make([dynamic]string, 0, allocator)
	for name, mod in m.modules {
		if mod.state == .Loaded {
			append(&modules, strings.clone(name, allocator))
		}
	}
	return modules
}

// command_manager_load_module executes a registered module's commands in
// an empty context, then runs the ModuleLoaded hook (C++
// CommandManager::load_module).
command_manager_load_module :: proc(
	m: ^Command_Manager,
	name: string,
	ctx: ^Context,
	allocator := context.allocator,
) -> (Command_Manager_Error, string) {
	mod, found := m.modules[name]
	if !found {
		b := strings.builder_make(allocator)
		strings.write_string(&b, "no such module: '")
		strings.write_string(&b, name)
		strings.write_string(&b, "'")
		return .Error, strings.to_string(b)
	}
	switch mod.state {
	case .Loading:
		b := strings.builder_make(allocator)
		strings.write_string(&b, "module '")
		strings.write_string(&b, name)
		strings.write_string(&b, "' loaded recursively")
		return .Error, strings.to_string(b)
	case .Loaded:
		return .None, ""
	case .Registered:
	// Proceed below.
	}
	mod.state = .Loading
	m.modules[name] = mod
	empty_ctx := context_make_empty(allocator)
	defer context_destroy(&empty_ctx)
	shell_ctx := Shell_Context{}
	err, msg := command_manager_execute(m, mod.commands, &empty_ctx, &shell_ctx, allocator)
	if err != .None {
		mod.state = .Registered
		m.modules[name] = mod
		return err, msg
	}
	delete(mod.commands, m.allocator)
	mod.commands = strings.clone("", m.allocator)
	mod.state = .Loaded
	m.modules[name] = mod
	hooks := context_hooks(ctx)
	hook_manager_run_hook(hooks, .Module_Loaded, name, ctx)
	return .None, ""
}

// command_manager_debug_write formats a debug message and writes it to
// the *debug* buffer. The format is prefix + joined parts.
command_manager_debug_write :: proc(parts: []string, allocator := context.allocator) {
	b := strings.builder_make(allocator)
	for part in parts {
		strings.write_string(&b, part)
	}
	msg := strings.to_string(b)
	debug_write_to_debug_buffer(msg)
	delete(msg, allocator)
}

// command_manager_execute_single_command runs one already-expanded
// command (C++ CommandManager::execute_single_command).
command_manager_execute_single_command :: proc(
	m: ^Command_Manager,
	params: []string,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
	allocator := context.allocator,
) -> (Command_Manager_Error, string) {
	if len(params) == 0 {
		return .None, ""
	}
	if m.command_depth > 100 {
		return .Error, strings.clone("maximum nested command depth hit", allocator)
	}
	m.command_depth += 1
	defer m.command_depth -= 1

	name := command_manager_resolve_alias(ctx, params[0])
	cmd, found := m.commands[name]
	if !found {
		return .Error, strings.clone("no such command", allocator)
	}

	debug_opt := option_manager_get_checked(context_options(ctx), "debug")
	debug_flags := debug_opt.value.(Option_types_Debug_Flags)
	if .Commands in debug_flags {
		joined := string_utils_join_char(params, ' ', true, allocator)
		defer delete(joined, allocator)
		command_manager_debug_write({"command ", joined}, allocator)
	}
	profile_on := .Profile in debug_flags
	profile_start := clock_now()

	pparser, perr := parameters_parser_parse(params[1:], cmd.param_desc)
	if perr != .None {
		return .Error, parameters_parser_error_message(perr, "", allocator)
	}
	defer parameters_parser_free(&pparser)

	cmd.func.call(cmd.func.data, &pparser, ctx, shell_ctx)

	if profile_on {
		microseconds := int(clock_diff(profile_start, clock_now())) / 1000
		b := strings.builder_make(allocator)
		strings.write_string(&b, "command ")
		strings.write_string(&b, params[0])
		strings.write_string(&b, " took ")
		strings.write_int(&b, microseconds)
		strings.write_string(&b, " us")
		msg := strings.to_string(b)
		debug_write_to_debug_buffer(msg)
		delete(msg, allocator)
	}
	return .None, ""
}

// command_manager_execute runs a command line, splitting it at command
// separators (C++ CommandManager::execute). .Fail propagates undecorated;
// other errors are prefixed with "line:col: 'command': ".
command_manager_execute :: proc(
	m: ^Command_Manager,
	command_line: string,
	ctx: ^Context,
	shell_ctx: ^Shell_Context,
	allocator := context.allocator,
) -> (Command_Manager_Error, string) {
	parser := command_manager_parser_make(command_line)
	// C++ Context::scope parity: innermost local scope, else window
	// scope, else global. (The buffer fallback needs unmerged context
	// procs; every real context here has a window.)
	parent_scope := &scope_global_instance().scope
	if len(ctx.local_scopes) > 0 {
		parent_scope = ctx.local_scopes[len(ctx.local_scopes) - 1]
	} else if ctx.window != nil {
		parent_scope = &ctx.window.scope
	}
	scope := scope_local_make(ctx, parent_scope, allocator)
	defer scope_local_destroy(scope, allocator)
	command_pos := 0
	params := make([dynamic]string, 0, allocator)
	defer {
		for p in params {
			delete(p, allocator)
		}
		delete(params)
	}
	for {
		tok, ok, tok_err, tok_msg := command_manager_read_token(&parser, true, allocator)
		if tok_err != .None {
			return tok_err, tok_msg
		}
		if !ok || tok.type == .Command_Separator {
			if ok {
				delete(tok.content, allocator)
			}
			exec_err, exec_msg := command_manager_execute_single_command(m, params[:], ctx, shell_ctx, allocator)
			if exec_err != .None {
				if exec_err == .Fail {
					return .Fail, exec_msg
				}
				coord := command_manager_compute_coord(command_line[:command_pos])
				b := strings.builder_make(allocator)
				strings.write_int(&b, int(coord.line) + 1)
				strings.write_byte(&b, ':')
				strings.write_int(&b, int(coord.column) + 1)
				strings.write_string(&b, ": '")
				strings.write_string(&b, params[0])
				strings.write_string(&b, "': ")
				strings.write_string(&b, exec_msg)
				delete(exec_msg, allocator)
				return .Error, strings.to_string(b)
			}
			if !ok {
				return .None, ""
			}
			for p in params {
				delete(p, allocator)
			}
			clear(&params)
			continue
		}
		if len(params) == 0 {
			command_pos = int(tok.pos)
		}
		if tok.type == .Arg_Expand && tok.content == "@" {
			delete(tok.content, allocator)
			for p in shell_ctx.params {
				append(&params, strings.clone(p, allocator))
			}
		} else {
			exp_err, exp_msg := command_manager_expand_token_multi(tok, ctx, shell_ctx, &params, allocator)
			if exp_err != .None {
				return exp_err, exp_msg
			}
		}
	}
}

// command_manager_command_info describes the last command on the line
// (C++ CommandManager::command_info). The info strings are owned; release
// with command_manager_free_info.
command_manager_command_info :: proc(
	m: ^Command_Manager,
	ctx: ^Context,
	command_line: string,
	allocator := context.allocator,
) -> (Command_Info, bool) {
	parser := command_manager_parser_make(command_line)
	tokens := make([dynamic]Token, 0, allocator)
	defer {
		for &t in tokens {
			delete(t.content, allocator)
		}
		delete(tokens)
	}
	for {
		tok, ok, tok_err, tok_msg := command_manager_read_token(&parser, false, allocator)
		if tok_err != .None {
			delete(tok_msg, allocator)
			return {}, false
		}
		if !ok {
			break
		}
		if tok.type == .Command_Separator {
			for &t in tokens {
				delete(t.content, allocator)
			}
			clear(&tokens)
			delete(tok.content, allocator)
			continue
		}
		append(&tokens, tok)
	}
	if len(tokens) == 0 {
		return {}, false
	}
	first := tokens[0].type
	if first != .Raw && first != .Raw_Quoted {
		return {}, false
	}
	name := command_manager_resolve_alias(ctx, tokens[0].content)
	cmd, found := m.commands[name]
	if !found {
		return {}, false
	}

	b := strings.builder_make(allocator)
	if len(cmd.docstring) > 0 {
		strings.write_string(&b, cmd.docstring)
		strings.write_byte(&b, '\n')
	}
	if cmd.helper.call != nil {
		hparams := make([dynamic]string, 0, allocator)
		defer delete(hparams)
		for i := 1; i < len(tokens); i += 1 {
			t := tokens[i].type
			if t == .Raw || t == .Raw_Quoted || t == .Expand {
				append(&hparams, tokens[i].content)
			}
		}
		helpstr := cmd.helper.call(cmd.helper.data, ctx, hparams[:], allocator)
		defer delete(helpstr, allocator)
		if len(helpstr) > 0 {
			strings.write_string(&b, helpstr)
			strings.write_byte(&b, '\n')
		}
	}
	aliases := alias_registry_aliases_for(context_aliases(ctx), name, allocator)
	defer delete(aliases)
	if len(aliases) > 0 {
		strings.write_string(&b, "Aliases:")
		for a in aliases {
			strings.write_byte(&b, ' ')
			strings.write_string(&b, a)
		}
		strings.write_byte(&b, '\n')
	}
	if len(cmd.param_desc.switches) > 0 {
		doc := parameters_parser_generate_switches_doc(cmd.param_desc.switches, allocator)
		defer delete(doc, allocator)
		indented := string_utils_indent(doc, "    ", allocator)
		defer delete(indented, allocator)
		strings.write_string(&b, "Switches:\n")
		strings.write_string(&b, indented)
	}
	return Command_Info{name = strings.clone(name, allocator), info = strings.to_string(b)}, true
}

// command_manager_free_info releases a Command_Info's owned strings.
command_manager_free_info :: proc(info: ^Command_Info, allocator := context.allocator) {
	delete(info.name, allocator)
	delete(info.info, allocator)
	info^ = {}
}

// command_manager_complete_command_name completes a command name over
// visible commands and aliases (C++ complete_command_name). Candidates
// are owned.
command_manager_complete_command_name :: proc(
	m: ^Command_Manager,
	ctx: ^Context,
	query: string,
	allocator := context.allocator,
) -> Completions {
	names := make([dynamic]string, 0, allocator)
	defer delete(names)
	for name, cmd in m.commands {
		if .Hidden not_in cmd.flags {
			append(&names, name)
		}
	}
	flat_aliases := alias_registry_flatten(context_aliases(ctx), allocator)
	defer delete(flat_aliases)
	for e in flat_aliases {
		append(&names, e.alias)
	}
	candidates := completion_complete_strings(query, Units_ByteCount(len(query)), names[:], allocator)
	return Completions{candidates = candidates, start = 0, end = Units_ByteCount(len(query)), flags = {.Menu, .No_Empty}}
}

// command_manager_complete_module_name completes a module name over
// registered (not yet loaded) modules (C++ complete_module_name).
// Candidates are owned.
command_manager_complete_module_name :: proc(
	m: ^Command_Manager,
	query: string,
	allocator := context.allocator,
) -> Completions {
	names := make([dynamic]string, 0, allocator)
	defer delete(names)
	for name, mod in m.modules {
		if mod.state == .Registered {
			append(&names, name)
		}
	}
	candidates := completion_complete_strings(query, Units_ByteCount(len(query)), names[:], allocator)
	return Completions{candidates = candidates, start = 0, end = Units_ByteCount(len(query))}
}

// command_manager_complete_expansion completes inside an expansion token
// (C++ complete_expansion). Candidates are owned.
command_manager_complete_expansion :: proc(
	ctx: ^Context,
	token: Token,
	start, cursor_pos, pos_in_token: Units_ByteCount,
	allocator := context.allocator,
) -> (Completions, Command_Manager_Error, string) {
	switch token.type {
	case .Register_Expand:
		candidates := register_manager_complete_register_name(token.content, pos_in_token, allocator)
		return Completions{candidates = candidates, start = start, end = cursor_pos}, .None, ""
	case .Option_Expand:
		candidates := option_manager_registry_complete_name(scope_global_option_registry(scope_global_instance()), token.content, pos_in_token, allocator)
		return Completions{candidates = candidates, start = start, end = cursor_pos}, .None, ""
	case .Shell_Expand:
		completions := completion_shell_complete(ctx, token.content, pos_in_token, allocator)
		return command_manager_offset_pos(completions, start), .None, ""
	case .Val_Expand:
		candidates := shell_manager_complete_env_var(token.content, pos_in_token, allocator)
		return Completions{candidates = candidates, start = start, end = cursor_pos}, .None, ""
	case .File_Expand:
		opt := option_manager_get_checked(context_options(ctx), "ignored_files")
		ignored := opt.value.(Regex)
		candidates := completion_complete_filename(token.content, &ignored, pos_in_token, {.Expand}, allocator)
		return Completions{candidates = candidates, start = start, end = cursor_pos}, .None, ""
	case .Raw, .Raw_Quoted, .Expand, .Arg_Expand, .Command_Separator:
		return {}, .Error, strings.clone("unknown expansion", allocator)
	}
	unreachable()
}

// command_manager_complete_expand completes inside a "..." Expand token,
// descending into an unterminated %x{...} (C++ complete_expand).
command_manager_complete_expand :: proc(
	ctx: ^Context,
	prefix: string,
	start, cursor_pos, pos_in_token: Units_ByteCount,
	allocator := context.allocator,
) -> (Completions, Command_Manager_Error, string) {
	ps := Parse_State{str = prefix, pos = 0}
	for ps.pos < len(prefix) {
		if prefix[ps.pos] == '%' {
			ps.pos += 1
			if ps.pos < len(prefix) && prefix[ps.pos] == '%' {
				ps.pos += 1
				continue
			}
			tok, tok_err, tok_msg := command_manager_parse_percent_token(&ps, false, allocator)
			if tok_err != .None {
				return {}, tok_err, tok_msg
			}
			if tok.terminated {
				delete(tok.content, allocator)
				continue
			}
			if tok.type == .Raw || tok.type == .Raw_Quoted {
				delete(tok.content, allocator)
				return Completions{}, .None, ""
			}
			comp, comp_err, comp_msg := command_manager_complete_expansion(ctx, tok, start + tok.pos, cursor_pos, pos_in_token - tok.pos, allocator)
			delete(tok.content, allocator)
			return comp, comp_err, comp_msg
		}
		ps.pos += 1
	}
	return Completions{}, .None, ""
}

// command_manager_offset_pos shifts a completion range (C++ offset_pos).
command_manager_offset_pos :: proc(completions: Completions, offset: Units_ByteCount) -> Completions {
	c := completions
	c.start += offset
	c.end += offset
	return c
}

// command_manager_requote quotes completion candidates for their token
// context (C++ requote). Takes ownership of completions and returns the
// adjusted value.
command_manager_requote :: proc(
	completions: Completions,
	token_type: Token_Type,
	allocator := context.allocator,
) -> Completions {
	c := completions
	if .Quoted in c.flags {
		return c
	}
	if token_type == .Raw {
		at_token_start := c.start == 0
		for &cand in c.candidates {
			needs_quote := at_token_start && len(cand) > 0 && cand[0] == '%'
			if !needs_quote {
				for i := 0; i < len(cand); i += 1 {
					ch := cand[i]
					if ch == ';' || ch == '\n' || ch == ' ' || ch == '\t' {
						needs_quote = true
						break
					}
				}
			}
			if needs_quote {
				replacement := string_utils_quote(cand, allocator) if at_token_start else string_utils_escape(cand, ";\n \t", '\\', allocator)
				delete(cand, allocator)
				cand = replacement
			}
		}
		return c
	}
	if token_type == .Raw_Quoted {
		c.flags += {.Quoted}
	}
	return c
}

// command_manager_free_completions releases a Completions' owned strings
// and candidate list.
command_manager_free_completions :: proc(c: ^Completions, allocator := context.allocator) {
	for cand in c.candidates {
		delete(cand, allocator)
	}
	delete(c.candidates)
	c^ = {}
}

// command_manager_completer_make creates a Completer (C++ Completer ctor).
command_manager_completer_make :: proc(allocator := context.allocator) -> Command_Manager_Completer {
	return Command_Manager_Completer{last_complete_command = strings.clone("", allocator), allocator = allocator}
}

// command_manager_completer_destroy releases a Completer.
command_manager_completer_destroy :: proc(c: ^Command_Manager_Completer) {
	delete(c.last_complete_command, c.allocator)
	c^ = {}
}

// command_manager_complete completes the command line at the cursor (C++
// CommandManager::Completer::operator()).
command_manager_complete :: proc(
	completer: ^Command_Manager_Completer,
	ctx: ^Context,
	command_line: string,
	cursor_pos: Units_ByteCount,
	allocator := context.allocator,
) -> (Completions, Command_Manager_Error, string) {
	m := command_manager_instance()
	prefix := command_line[:min(int(cursor_pos), len(command_line))]
	parser := command_manager_parser_make(prefix)
	tokens := make([dynamic]Token, 0, allocator)
	defer {
		for &t in tokens {
			delete(t.content, allocator)
		}
		delete(tokens)
	}

	is_last_token := true
	for {
		tok, ok, tok_err, tok_msg := command_manager_read_token(&parser, false, allocator)
		if tok_err != .None {
			return {}, tok_err, tok_msg
		}
		if !ok {
			break
		}
		if tok.type == .Command_Separator {
			for &t in tokens {
				delete(t.content, allocator)
			}
			clear(&tokens)
			delete(tok.content, allocator)
			continue
		}
		append(&tokens, tok)
		if command_manager_parser_pos(&parser) >= int(cursor_pos) {
			is_last_token = false
			break
		}
	}

	if is_last_token {
		append(&tokens, Token{type = .Raw, pos = Units_ByteCount(len(prefix)), content = strings.clone("", allocator)})
	}
	token := tokens[len(tokens) - 1]
	if token.terminated {
		return Completions{}, .None, ""
	}
	start := token.pos
	pos_in_token := cursor_pos - start

	if len(tokens) == 1 && (token.type == .Raw || token.type == .Raw_Quoted) {
		c := command_manager_complete_command_name(m, ctx, prefix, allocator)
		return command_manager_offset_pos(command_manager_requote(c, token.type, allocator), start), .None, ""
	}

	switch token.type {
	case .Register_Expand, .Option_Expand, .Shell_Expand, .Val_Expand, .File_Expand:
		return command_manager_complete_expansion(ctx, token, start, cursor_pos, pos_in_token, allocator)
	case .Raw, .Raw_Quoted:
		command_name := tokens[0].content
		cmd, found := m.commands[command_manager_resolve_alias(ctx, command_name)]
		if !found {
			return Completions{}, .None, ""
		}
		if command_name != completer.last_complete_command {
			delete(completer.last_complete_command, completer.allocator)
			completer.last_complete_command = strings.clone(command_name, completer.allocator)
			completer.command_completer = cmd.completer
		}
		raw_params := make([dynamic]string, 0, allocator)
		defer delete(raw_params)
		for i := 1; i < len(tokens); i += 1 {
			append(&raw_params, tokens[i].content)
		}
		pparser, perr := parameters_parser_parse(raw_params[:], cmd.param_desc, true)
		if perr != .None {
			return {}, .Error, parameters_parser_error_message(perr, "", allocator)
		}
		defer parameters_parser_free(&pparser)
		state, state_ok := parameters_parser_state(&pparser)
		if state_ok && state == .Switch {
			query := token.content
			if len(query) > 0 {
				query = query[1:]
			}
			switch_names := make([dynamic]string, 0, allocator)
			defer delete(switch_names)
			for sw_name in cmd.param_desc.switches {
				_, used := parameters_parser_get_switch(&pparser, sw_name)
				if !used {
					append(&switch_names, sw_name)
				}
			}
			append(&switch_names, "-")
			switches := completion_complete_strings(query, pos_in_token, switch_names[:], allocator)
			if len(switches) == 0 {
				delete(switches)
				return Completions{}, .None, ""
			}
			return Completions{candidates = switches, start = start + 1, end = cursor_pos, flags = {.Menu}}, .None, ""
		}
		if state_ok && state == .Switch_Argument {
			// The merged Parameters_Parser_Switch_Desc drops the switch
			// argument completer, so switch arguments cannot complete.
			return Completions{}, .None, ""
		}
		if completer.command_completer.call == nil {
			return Completions{}, .None, ""
		}
		positionals := make([dynamic]string, 0, allocator)
		defer delete(positionals)
		for i := 0; i < parameters_parser_positional_count(&pparser); i += 1 {
			append(&positionals, parameters_parser_positional(&pparser, i))
		}
		index := len(positionals) - 1
		c := completer.command_completer.call(completer.command_completer.data, ctx, positionals[:], index, pos_in_token, allocator)
		return command_manager_offset_pos(command_manager_requote(c, token.type, allocator), start), .None, ""
	case .Expand:
		return command_manager_complete_expand(ctx, token.content, start, cursor_pos, pos_in_token, allocator)
	case .Arg_Expand, .Command_Separator:
		return Completions{}, .None, ""
	}
	// Unreachable: the switch above is exhaustive over Token_Type.
	return Completions{}, .None, ""
}

// command_manager_nested_completer_make creates a NestedCompleter (C++
// NestedCompleter ctor).
command_manager_nested_completer_make :: proc(allocator := context.allocator) -> Command_Manager_Nested_Completer {
	return Command_Manager_Nested_Completer{last_complete_command = strings.clone("", allocator), allocator = allocator}
}

// command_manager_nested_completer_destroy releases a NestedCompleter.
command_manager_nested_completer_destroy :: proc(c: ^Command_Manager_Nested_Completer) {
	delete(c.last_complete_command, c.allocator)
	c^ = {}
}

// command_manager_nested_complete completes a nested command's token
// (C++ CommandManager::NestedCompleter::operator()).
command_manager_nested_complete :: proc(
	completer: ^Command_Manager_Nested_Completer,
	ctx: ^Context,
	params: Command_Parameters,
	token_to_complete: int,
	pos_in_token: Units_ByteCount,
	allocator := context.allocator,
) -> (Completions, Command_Manager_Error, string) {
	m := command_manager_instance()
	raw := params[token_to_complete]
	prefix := raw[:min(int(pos_in_token), len(raw))]
	if token_to_complete == 0 {
		return command_manager_complete_command_name(m, ctx, prefix, allocator), .None, ""
	}
	command_name := params[0]
	if command_name != completer.last_complete_command {
		delete(completer.last_complete_command, completer.allocator)
		completer.last_complete_command = strings.clone(command_name, completer.allocator)
		if cmd, found := m.commands[command_manager_resolve_alias(ctx, command_name)]; found {
			completer.command_completer = cmd.completer
		}
	}
	if completer.command_completer.call == nil {
		return Completions{}, .None, ""
	}
	return completer.command_completer.call(completer.command_completer.data, ctx, params[1:], token_to_complete - 1, pos_in_token, allocator), .None, ""
}

// ---------------------------------------------------------------------------
// STUBS: called-but-unmerged procs (STUB protocol). Each body is exactly
// one panic line; signatures adapt the C++ headers. Shared stubs used by
// hook_manager.odin also live here so they are defined exactly once.
// ---------------------------------------------------------------------------

// C++ write_to_debug_buffer (debug.hh).
debug_write_to_debug_buffer :: proc(str: string) {
	panic("STUB: debug_write_to_debug_buffer")
}

// C++ Context::options (context.hh).
// C++ OptionManager::operator[] (option_manager.hh). Returns the named
// option (borrowed).
// C++ Option::get<DebugFlags> (option_manager.hh). NOTE: knot.odin's
// Option_Value union has no DebugFlags variant (see the final report),
// so typed reads go through this stub until the union grows one.
// C++ complete() template (completion.hh), adapted to []string: rank the
// borrowed candidates against query and return the owned winners.
completion_complete_strings :: proc(query: string, cursor_pos: Units_ByteCount, candidates: []string, allocator := context.allocator) -> Candidate_List {
	panic("STUB: completion_complete_strings")
}

// C++ Context::aliases (context.hh).
context_aliases :: proc(ctx: ^Context) -> ^Alias_Registry {
	panic("STUB: context_aliases")
}

// C++ AliasRegistry::operator[] (alias_registry.hh). Borrowed result, ""
// when the alias is undefined.
// C++ AliasRegistry::aliases_for (alias_registry.hh). Borrowed names in
// an owned list.
// C++ AliasRegistry::flatten_aliases (alias_registry.hh), names only:
// borrowed names in an owned list.
alias_registry_flatten_alias_names :: proc(reg: ^Alias_Registry, allocator := context.allocator) -> [dynamic]string {
	panic("STUB: alias_registry_flatten_alias_names")
}

// C++ Context::hooks (context.hh).
// C++ Context::main_sel_register_value (context.hh). Borrowed result.
context_main_sel_register_value :: proc(ctx: ^Context, reg: string) -> string {
	panic("STUB: context_main_sel_register_value")
}

// C++ Option::get_as_string (option_manager.hh). Owned result.
option_get_as_string :: proc(opt: ^Option, quoting: Option_types_Quoting, allocator := context.allocator) -> string {
	panic("STUB: option_get_as_string")
}

// C++ Option::get_as_strings (option_manager.hh). Owned strings.
option_get_as_strings :: proc(opt: ^Option, allocator := context.allocator) -> [dynamic]string {
	panic("STUB: option_get_as_strings")
}

// C++ ShellManager::eval with empty stdin and WaitForStdout
// (shell_manager.hh): the owned stdout.
shell_manager_eval :: proc(cmdline: string, ctx: ^Context, shell_ctx: ^Shell_Context, allocator := context.allocator) -> string {
	panic("STUB: shell_manager_eval")
}

// C++ ShellManager::get_val (shell_manager.hh). Owned strings.
shell_manager_get_val :: proc(name: string, ctx: ^Context, allocator := context.allocator) -> [dynamic]string {
	panic("STUB: shell_manager_get_val")
}

// C++ ShellManager::complete_env_var (shell_manager.hh).
shell_manager_complete_env_var :: proc(prefix: string, cursor_pos: Units_ByteCount, allocator := context.allocator) -> Candidate_List {
	panic("STUB: shell_manager_complete_env_var")
}

// C++ RegisterManager::operator[] + Register::get (register_manager.hh),
// combined: the owned register values.
register_manager_get_strings :: proc(reg: string, ctx: ^Context, allocator := context.allocator) -> [dynamic]string {
	panic("STUB: register_manager_get_strings")
}

// C++ RegisterManager::complete_register_name (register_manager.hh).
register_manager_complete_register_name :: proc(prefix: string, cursor_pos: Units_ByteCount, allocator := context.allocator) -> Candidate_List {
	panic("STUB: register_manager_complete_register_name")
}

// C++ GlobalScope::instance().option_registry() (scope.hh).
global_scope_option_registry :: proc() -> ^Options_Registry {
	panic("STUB: global_scope_option_registry")
}

// C++ OptionsRegistry::complete_option_name (option_manager.hh).
options_registry_complete_option_name :: proc(reg: ^Options_Registry, prefix: string, cursor_pos: Units_ByteCount, allocator := context.allocator) -> Candidate_List {
	panic("STUB: options_registry_complete_option_name")
}

// C++ shell_complete (completion.hh).
// C++ complete_filename (completion.hh).
// C++ LocalScope ctor/dtor (local_scope.hh).
local_scope_make :: proc(ctx: ^Context) -> Local_Scope {
	panic("STUB: local_scope_make")
}

local_scope_destroy :: proc(s: ^Local_Scope) {
	panic("STUB: local_scope_destroy")
}

// C++ Context(EmptyContextFlag)/dtor (context.hh).
context_make_empty :: proc(allocator := context.allocator) -> Context {
	panic("STUB: context_make_empty")
}

context_destroy :: proc(ctx: ^Context) {
	panic("STUB: context_destroy")
}
