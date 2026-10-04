// Tests for the command_manager module. The lexer tests port the C++
// test_command_parsing UnitTest 1:1 (quoted, balanced, unquoted and the
// tokenizer); the rest covers token types, positions, error messages,
// the registry and requote. Execute/expand/info/completion paths need
// STUBBED procs (context, shell, completion, ...) and are untestable:
// execution, module loading, expansion, command_info and all completers
// are GAPS (see summary).
package kak

import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"

// command_manager_check_quoted mirrors the C++ check_quoted lambda (the
// char and Codepoint variants merged: one rune-based implementation).
command_manager_check_quoted :: proc(t: ^testing.T, str: string, terminated: bool, content: string) {
	ps := Parse_State{str = str, pos = 1}
	quoted := command_manager_parse_quoted(&ps, rune(str[0]))
	defer delete(quoted.content)
	testing.expect_value(t, quoted.terminated, terminated)
	testing.expect_value(t, quoted.content, content)
}

@(test)
command_manager_test_quoted_cxx :: proc(t: ^testing.T) {
	command_manager_check_quoted(t, "'abc'", true, "abc")
	command_manager_check_quoted(t, "'abc''def", false, "abc'def")
	command_manager_check_quoted(t, "'abc''def'''", true, "abc'def'")
	command_manager_check_quoted(t, "'abc''def'"[:5], true, "abc")
}

@(test)
command_manager_test_quoted_double :: proc(t: ^testing.T) {
	command_manager_check_quoted(t, `"abc"`, true, "abc")
	command_manager_check_quoted(t, `"a""b"`, true, `a"b`)
	command_manager_check_quoted(t, `"abc`, false, "abc")
}

// command_manager_check_balanced mirrors the C++ check_balanced lambda.
command_manager_check_balanced :: proc(t: ^testing.T, str: string, terminated: bool, content: string) {
	ps := Parse_State{str = str, pos = 1}
	quoted := command_manager_parse_quoted_balanced(&ps, '{', '}')
	defer delete(quoted.content)
	testing.expect_value(t, quoted.terminated, terminated)
	testing.expect_value(t, quoted.content, content)
	testing.expect_value(t, ps.pos, len(str))
}

@(test)
command_manager_test_balanced_cxx :: proc(t: ^testing.T) {
	command_manager_check_balanced(t, "{abc}", true, "abc")
	command_manager_check_balanced(t, "{abc{def}}", true, "abc{def}")
	command_manager_check_balanced(t, "{{abc}{def}", false, "{abc}{def}")
}

// command_manager_check_unquoted mirrors the C++ check_unquoted lambda.
command_manager_check_unquoted :: proc(t: ^testing.T, str: string, content: string) {
	ps := Parse_State{str = str, pos = 0}
	got := command_manager_parse_unquoted(&ps)
	defer delete(got)
	testing.expect_value(t, got, content)
}

@(test)
command_manager_test_unquoted_cxx :: proc(t: ^testing.T) {
	command_manager_check_unquoted(t, "abc def", "abc")
	command_manager_check_unquoted(t, "abc; def", "abc")
	command_manager_check_unquoted(t, "abc\\; def", "abc;")
	command_manager_check_unquoted(t, "abc\\;\\ def", "abc; def")
}

@(test)
command_manager_test_unquoted_edges :: proc(t: ^testing.T) {
	// Escaped newline inside a token is a literal newline (the escape
	// branch applies to separators too).
	command_manager_check_unquoted(t, "foo\\\nbar", "foo\nbar")
	// Backslash before a regular char is kept literally.
	command_manager_check_unquoted(t, `a\nb c`, `a\nb`)
	// Token runs to end of input.
	command_manager_check_unquoted(t, "abc", "abc")
	// Form-feed and tab are blanks; carriage return is a regular char.
	command_manager_check_unquoted(t, "a\tb", "a")
	command_manager_check_unquoted(t, "a\fb", "a")
	command_manager_check_unquoted(t, "a\rb", "a\rb")
}

@(test)
command_manager_test_tokenizer_cxx :: proc(t: ^testing.T) {
	parser := command_manager_parser_make(`foo 'bar' "baz" qux`)
	tok, ok, err, msg := command_manager_read_token(&parser, false)
	testing.expect_value(t, err, Command_Manager_Error.None)
	testing.expect(t, ok)
	defer command_manager_free_token(&tok)
	testing.expect_value(t, tok.content, "foo")
	testing.expect_value(t, tok.type, Token_Type.Raw)

	tok2, ok2, err2, _ := command_manager_read_token(&parser, false)
	testing.expect_value(t, err2, Command_Manager_Error.None)
	testing.expect(t, ok2)
	defer command_manager_free_token(&tok2)
	testing.expect_value(t, tok2.content, "bar")
	testing.expect_value(t, tok2.type, Token_Type.Raw_Quoted)

	tok3, ok3, err3, _ := command_manager_read_token(&parser, false)
	testing.expect_value(t, err3, Command_Manager_Error.None)
	testing.expect(t, ok3)
	defer command_manager_free_token(&tok3)
	testing.expect_value(t, tok3.content, "baz")
	testing.expect_value(t, tok3.type, Token_Type.Expand)

	tok4, ok4, err4, _ := command_manager_read_token(&parser, false)
	testing.expect_value(t, err4, Command_Manager_Error.None)
	testing.expect(t, ok4)
	defer command_manager_free_token(&tok4)
	testing.expect_value(t, tok4.content, "qux")

	_, done_ok, done_err, _ := command_manager_read_token(&parser, false)
	testing.expect_value(t, done_err, Command_Manager_Error.None)
	testing.expect(t, !done_ok)
	testing.expect(t, command_manager_parser_done(&parser))
	_ = msg
}

@(test)
command_manager_test_token_positions :: proc(t: ^testing.T) {
	parser := command_manager_parser_make(`ab; 'xy'`)
	tok, ok, _, _ := command_manager_read_token(&parser, false)
	testing.expect(t, ok)
	defer command_manager_free_token(&tok)
	testing.expect_value(t, tok.type, Token_Type.Raw)
	testing.expect_value(t, tok.pos, Units_ByteCount(0))

	sep, sep_ok, _, _ := command_manager_read_token(&parser, false)
	testing.expect(t, sep_ok)
	defer command_manager_free_token(&sep)
	testing.expect_value(t, sep.type, Token_Type.Command_Separator)
	// Separator pos points just past the ';', like the C++.
	testing.expect_value(t, sep.pos, Units_ByteCount(3))
	testing.expect_value(t, sep.content, "")

	quoted, quoted_ok, _, _ := command_manager_read_token(&parser, false)
	testing.expect(t, quoted_ok)
	defer command_manager_free_token(&quoted)
	// Quoted pos points just past the opening quote.
	testing.expect_value(t, quoted.pos, Units_ByteCount(5))
	testing.expect_value(t, quoted.content, "xy")
	testing.expect(t, quoted.terminated)
}

@(test)
command_manager_test_percent_tokens :: proc(t: ^testing.T) {
	parser := command_manager_parser_make(`%sh{echo} %reg/x/ %opt[a] %val(a) %arg|i| %file<f> %exp"e" %{r}`)
	expect := []Token_Type{.Shell_Expand, .Register_Expand, .Option_Expand, .Val_Expand, .Arg_Expand, .File_Expand, .Expand, .Raw_Quoted}
	want := []string{"echo", "x", "a", "a", "i", "f", "e", "r"}
	for i in 0 ..< len(expect) {
		tok, ok, err, _ := command_manager_read_token(&parser, false)
		testing.expect_value(t, err, Command_Manager_Error.None)
		testing.expect(t, ok)
		defer command_manager_free_token(&tok)
		testing.expect_value(t, tok.type, expect[i])
		testing.expect_value(t, tok.content, want[i])
		testing.expect(t, tok.terminated)
	}
	_, done_ok, _, _ := command_manager_read_token(&parser, false)
	testing.expect(t, !done_ok)
}

@(test)
command_manager_test_percent_edges :: proc(t: ^testing.T) {
	// Doubled delimiter inside a % token yields one literal delimiter.
	parser := command_manager_parser_make(`%sh/aa//bb/`)
	tok, ok, err, _ := command_manager_read_token(&parser, true)
	testing.expect_value(t, err, Command_Manager_Error.None)
	testing.expect(t, ok)
	defer command_manager_free_token(&tok)
	testing.expect_value(t, tok.type, Token_Type.Shell_Expand)
	testing.expect_value(t, tok.content, "aa/bb")
	testing.expect_value(t, tok.pos, Units_ByteCount(4))

	// Backslash escapes %, ' and " at the start of a raw token.
	parser2 := command_manager_parser_make(`\%foo \%'`)
	esc, esc_ok, esc_err, _ := command_manager_read_token(&parser2, false)
	testing.expect_value(t, esc_err, Command_Manager_Error.None)
	testing.expect(t, esc_ok)
	defer command_manager_free_token(&esc)
	testing.expect_value(t, esc.type, Token_Type.Raw)
	testing.expect_value(t, esc.content, "%foo")
	testing.expect_value(t, esc.pos, Units_ByteCount(0))

	// Unknown % type without throw degrades to RawQuoted.
	parser3 := command_manager_parser_make(`%foo{bar}`)
	unk, unk_ok, unk_err, _ := command_manager_read_token(&parser3, false)
	testing.expect_value(t, unk_err, Command_Manager_Error.None)
	testing.expect(t, unk_ok)
	defer command_manager_free_token(&unk)
	testing.expect_value(t, unk.type, Token_Type.Raw_Quoted)
	testing.expect_value(t, unk.content, "bar")
}

// Command_Manager_Type_Case is one token_type test row.
Command_Manager_Type_Case :: struct {
	name:     string,
	tok_type: Token_Type,
}

@(test)
command_manager_test_token_type :: proc(t: ^testing.T) {
	cases := []Command_Manager_Type_Case{
		{name = "", tok_type = .Raw_Quoted},
		{name = "sh", tok_type = .Shell_Expand},
		{name = "reg", tok_type = .Register_Expand},
		{name = "opt", tok_type = .Option_Expand},
		{name = "val", tok_type = .Val_Expand},
		{name = "arg", tok_type = .Arg_Expand},
		{name = "file", tok_type = .File_Expand},
		{name = "exp", tok_type = .Expand},
	}
	for tc in cases {
		got, err, _ := command_manager_token_type(tc.name, true)
		testing.expect_value(t, err, Command_Manager_Error.None)
		testing.expect_value(t, got, tc.tok_type)
	}
	got, err, msg := command_manager_token_type("bogus", true)
	defer delete(msg)
	testing.expect_value(t, err, Command_Manager_Error.Error)
	testing.expect_value(t, msg, "parse error: unknown expand 'bogus'")
	testing.expect_value(t, got, Token_Type.Raw_Quoted)

	got2, err2, _ := command_manager_token_type("bogus", false)
	testing.expect_value(t, err2, Command_Manager_Error.None)
	testing.expect_value(t, got2, Token_Type.Raw_Quoted)
}

@(test)
command_manager_test_parse_errors :: proc(t: ^testing.T) {
	// Unknown % type with throw.
	parser := command_manager_parser_make(`%bogus{x}`)
	_, _, err, msg := command_manager_read_token(&parser, true)
	defer delete(msg)
	testing.expect_value(t, err, Command_Manager_Error.Error)
	testing.expect_value(t, msg, "parse error: unknown expand 'bogus'")

	// Missing delimiter after the % type name.
	parser2 := command_manager_parser_make(`%sh`)
	_, _, err2, msg2 := command_manager_read_token(&parser2, true)
	defer delete(msg2)
	testing.expect_value(t, err2, Command_Manager_Error.Error)
	testing.expect_value(t, msg2, "parse error: expected a string delimiter after '%sh'")

	// Alphabetic delimiter is rejected like end of input.
	parser3 := command_manager_parser_make(`%shAfooA`)
	_, _, err3, msg3 := command_manager_read_token(&parser3, true)
	defer delete(msg3)
	testing.expect_value(t, err3, Command_Manager_Error.Error)
	testing.expect_value(t, msg3, "parse error: expected a string delimiter after '%sh'")

	// Unterminated balanced string reports line:col.
	parser4 := command_manager_parser_make("%sh{abc")
	_, _, err4, msg4 := command_manager_read_token(&parser4, true)
	defer delete(msg4)
	testing.expect_value(t, err4, Command_Manager_Error.Error)
	testing.expect_value(t, msg4, "parse error: 1:5: unterminated string '%sh{...}'")

	// Unterminated same-delimiter string.
	parser5 := command_manager_parser_make("%sh/abc")
	_, _, err5, msg5 := command_manager_read_token(&parser5, true)
	defer delete(msg5)
	testing.expect_value(t, err5, Command_Manager_Error.Error)
	testing.expect_value(t, msg5, "parse error: 1:5: unterminated string '%sh/.../'")

	// Unterminated double-quoted string.
	parser6 := command_manager_parser_make(`"abc`)
	_, _, err6, msg6 := command_manager_read_token(&parser6, true)
	defer delete(msg6)
	testing.expect_value(t, err6, Command_Manager_Error.Error)
	testing.expect_value(t, msg6, `parse error: unterminated string "..."`)

	// Unterminated single-quoted string.
	parser7 := command_manager_parser_make(`'abc`)
	_, _, err7, msg7 := command_manager_read_token(&parser7, true)
	defer delete(msg7)
	testing.expect_value(t, err7, Command_Manager_Error.Error)
	testing.expect_value(t, msg7, "parse error: unterminated string '...'")

	// Without throw, unterminated input yields unterminated tokens.
	parser8 := command_manager_parser_make(`'abc`)
	tok8, ok8, err8, _ := command_manager_read_token(&parser8, false)
	testing.expect_value(t, err8, Command_Manager_Error.None)
	testing.expect(t, ok8)
	defer command_manager_free_token(&tok8)
	testing.expect_value(t, tok8.content, "abc")
	testing.expect(t, !tok8.terminated)
}

@(test)
command_manager_test_skip_and_coord :: proc(t: ^testing.T) {
	// The skipper stops at the newline ending the comment (newline is a
	// separator token, not a blank).
	ps := Parse_State{str = "  \t\\\n  # comment\n x", pos = 0}
	command_manager_skip_blanks_and_comments(&ps)
	testing.expect_value(t, ps.pos, 16)

	coord := command_manager_compute_coord("ab\nc")
	testing.expect_value(t, coord.line, Coord_Line(1))
	testing.expect_value(t, coord.column, Coord_Byte(1))
	testing.expect_value(t, command_manager_compute_coord(""), Coord_Buffer{})
}

@(test)
command_manager_test_comments_and_separators :: proc(t: ^testing.T) {
	parser := command_manager_parser_make("foo # bar\nbaz;qux")
	tok, ok, _, _ := command_manager_read_token(&parser, false)
	testing.expect(t, ok)
	defer command_manager_free_token(&tok)
	testing.expect_value(t, tok.content, "foo")

	// The comment runs to the newline, and the newline itself is a
	// command separator token.
	nl, nl_ok, _, _ := command_manager_read_token(&parser, false)
	testing.expect(t, nl_ok)
	defer command_manager_free_token(&nl)
	testing.expect_value(t, nl.type, Token_Type.Command_Separator)

	tok2, ok2, _, _ := command_manager_read_token(&parser, false)
	testing.expect(t, ok2)
	defer command_manager_free_token(&tok2)
	testing.expect_value(t, tok2.content, "baz")

	sep, sep_ok, _, _ := command_manager_read_token(&parser, false)
	testing.expect(t, sep_ok)
	defer command_manager_free_token(&sep)
	testing.expect_value(t, sep.type, Token_Type.Command_Separator)

	// Newline is a command separator too.
	parser2 := command_manager_parser_make("a\nb")
	first, first_ok, _, _ := command_manager_read_token(&parser2, false)
	testing.expect(t, first_ok)
	defer command_manager_free_token(&first)
	nl2, nl2_ok, _, _ := command_manager_read_token(&parser2, false)
	testing.expect(t, nl2_ok)
	defer command_manager_free_token(&nl2)
	testing.expect_value(t, nl2.type, Token_Type.Command_Separator)

	// Empty and blank-only input yields no token.
	empty := command_manager_parser_make("")
	_, empty_ok, empty_err, _ := command_manager_read_token(&empty, true)
	testing.expect(t, !empty_ok)
	testing.expect_value(t, empty_err, Command_Manager_Error.None)
	blanks := command_manager_parser_make("   # only a comment")
	_, blanks_ok, _, _ := command_manager_read_token(&blanks, true)
	testing.expect(t, !blanks_ok)
}

@(test)
command_manager_test_registry :: proc(t: ^testing.T) {
	m := command_manager_make()
	defer command_manager_destroy(&m)
	desc := Parameters_Parser_Desc {
		switches        = map[string]Parameters_Parser_Switch_Desc{},
		min_positionals = 0,
		max_positionals = max(int),
	}
	defer delete(desc.switches)
	testing.expect(t, !command_manager_command_defined(&m, "echo"))

	command_manager_register_command(&m, "echo", {}, "doc one", desc)
	testing.expect(t, command_manager_command_defined(&m, "echo"))
	// Re-registering replaces the docstring.
	command_manager_register_command(&m, "echo", {}, "doc two", desc, {.Hidden})
	testing.expect_value(t, m.commands["echo"].docstring, "doc two")
	testing.expect(t, .Hidden in m.commands["echo"].flags)

	err, msg := command_manager_set_command_completer(&m, "echo", {})
	testing.expect_value(t, err, Command_Manager_Error.None)
	testing.expect_value(t, msg, "")
	err2, msg2 := command_manager_set_command_completer(&m, "missing", {})
	defer delete(msg2)
	testing.expect_value(t, err2, Command_Manager_Error.Error)
	testing.expect_value(t, msg2, "no such command 'missing'")
}

@(test)
command_manager_test_modules :: proc(t: ^testing.T) {
	m := command_manager_make()
	defer command_manager_destroy(&m)
	testing.expect(t, !command_manager_module_defined(&m, "mod"))

	err, msg := command_manager_register_module(&m, "mod", "echo hi")
	testing.expect_value(t, err, Command_Manager_Error.None)
	testing.expect_value(t, msg, "")
	testing.expect(t, command_manager_module_defined(&m, "mod"))
	// Re-registering over Registered replaces the commands.
	err, msg = command_manager_register_module(&m, "mod", "echo yo")
	testing.expect_value(t, err, Command_Manager_Error.None)
	testing.expect_value(t, m.modules["mod"].commands, "echo yo")

	loaded := command_manager_loaded_modules(&m)
	defer {
		for name in loaded {
			delete(name)
		}
		delete(loaded)
	}
	testing.expect_value(t, len(loaded), 0)

	// A loading/loaded module cannot be re-registered.
	mod := m.modules["mod"]
	mod.state = .Loaded
	m.modules["mod"] = mod
	err2, msg2 := command_manager_register_module(&m, "mod", "echo no")
	defer delete(msg2)
	testing.expect_value(t, err2, Command_Manager_Error.Error)
	testing.expect_value(t, msg2, "module already loaded: 'mod'")

	loaded2 := command_manager_loaded_modules(&m)
	defer {
		for name in loaded2 {
			delete(name)
		}
		delete(loaded2)
	}
	testing.expect_value(t, len(loaded2), 1)
	testing.expect_value(t, loaded2[0], "mod")
}

// command_manager_make_cands builds owned-candidate Completions for the
// requote tests.
command_manager_make_cands :: proc(values: []string, start: Units_ByteCount = 0) -> Completions {
	cands := make([dynamic]string, 0, len(values))
	for v in values {
		append(&cands, strings.clone(v))
	}
	return Completions{candidates = cands, start = start, end = 0}
}

@(test)
command_manager_test_requote :: proc(t: ^testing.T) {
	// Already-quoted completions pass through untouched.
	c := command_manager_make_cands({"%x"})
	c.flags = {.Quoted}
	defer command_manager_free_completions(&c)
	// requote takes ownership; keep the result in c for cleanup.
	c = command_manager_requote(c, .Raw)
	testing.expect_value(t, c.candidates[0], "%x")
	testing.expect(t, .Quoted in c.flags)
}

@(test)
command_manager_test_requote_raw :: proc(t: ^testing.T) {
	// At token start, % and blanks trigger single-quote wrapping.
	c := command_manager_make_cands({"%foo", "a b", "plain"})
	defer command_manager_free_completions(&c)
	c = command_manager_requote(c, .Raw)
	testing.expect_value(t, c.candidates[0], "'%foo'")
	testing.expect_value(t, c.candidates[1], "'a b'")
	testing.expect_value(t, c.candidates[2], "plain")

	// Past token start, blanks trigger backslash escaping instead.
	c2 := command_manager_make_cands({"a b", "a;b"}, 3)
	defer command_manager_free_completions(&c2)
	c2 = command_manager_requote(c2, .Raw)
	testing.expect_value(t, c2.candidates[0], `a\ b`)
	testing.expect_value(t, c2.candidates[1], `a\;b`)

	// RawQuoted just marks the range quoted.
	c3 := command_manager_make_cands({"a b"})
	defer command_manager_free_completions(&c3)
	c3 = command_manager_requote(c3, .Raw_Quoted)
	testing.expect_value(t, c3.candidates[0], "a b")
	testing.expect(t, .Quoted in c3.flags)

	// Other token types pass through (the C++ assert path).
	c4 := command_manager_make_cands({"a b"})
	defer command_manager_free_completions(&c4)
	c4 = command_manager_requote(c4, .Expand)
	testing.expect_value(t, c4.candidates[0], "a b")
	testing.expect(t, .Quoted not_in c4.flags)
}

@(test)
command_manager_test_offset_pos :: proc(t: ^testing.T) {
	c := Completions{start = 2, end = 5, flags = {.Menu}}
	shifted := command_manager_offset_pos(c, 3)
	testing.expect_value(t, shifted.start, Units_ByteCount(5))
	testing.expect_value(t, shifted.end, Units_ByteCount(8))
	testing.expect_value(t, shifted.flags, Completion_Flags{.Menu})
}

@(test)
command_manager_test_completer_lifecycle :: proc(t: ^testing.T) {
	c := command_manager_completer_make()
	testing.expect_value(t, c.last_complete_command, "")
	command_manager_completer_destroy(&c)
	n := command_manager_nested_completer_make()
	testing.expect_value(t, n.last_complete_command, "")
	command_manager_nested_completer_destroy(&n)
}

@(test)
command_manager_test_execute_aborts_list_on_error :: proc(t: ^testing.T) {
	// Regression: a failing builtin must abort the `;` list (C++
	// throws out of the command into execute). The void
	// Command_Func.call cannot return the failure, so wrappers stash
	// it on the context for execute_single_command to convert.
	sync.lock(&test_commands_singleton_mutex)
	defer sync.unlock(&test_commands_singleton_mutex)
	f := test_commands_setup()
	defer test_commands_teardown(f)
	test_commands_setup_singletons(f)
	defer test_commands_teardown_singletons()

	buf := test_commands_make_buffer(f, "*test*", {}, {"hello"})
	ctx := test_commands_make_context(f, buf)
	defer context_destroy(&ctx)

	dir, derr := os.temp_directory(f.allocator)
	testing.expect_value(t, derr, os.ERROR_NONE)
	defer delete(dir, f.allocator)
	target := strings.concatenate({dir, "/kak-cm-test-abort.txt"}, f.allocator)
	defer delete(target, f.allocator)
	defer os.remove(target)

	sc := test_commands_make_shell(f)
	defer test_commands_free_shell(f, &sc)
	cmd := strings.concatenate(
		{"fail stop-here; echo -to-file ", target, " -- reached"},
		f.allocator,
	)
	defer delete(cmd, f.allocator)
	exec_err, exec_msg := command_manager_execute(command_manager_instance(), cmd, &ctx, &sc, f.allocator)
	defer if exec_err != .None {
		delete(exec_msg, f.allocator)
	}
	// Fail propagates undecorated like the C++ failure.
	testing.expect_value(t, exec_err, Commands_Error.Fail)
	testing.expect_value(t, exec_msg, "stop-here")
	// The echo past the `;` never ran.
	_, stat_err := os.stat(target, f.allocator)
	testing.expect(t, stat_err != os.ERROR_NONE)
}

@(test)
command_manager_test_execute_failure_leaves_no_leaks :: proc(t: ^testing.T) {
	// A failing builtin through execute must not leak: report
	// consumes the message, and the headless status print destroys
	// its lines (C++ moves the message into the throw; DisplayLines
	// are RAII). Explicit teardowns so the leak check observes them.
	sync.lock(&test_commands_singleton_mutex)
	defer sync.unlock(&test_commands_singleton_mutex)
	// Baseline before setup: teardown frees setup allocations too,
	// so only a pre-setup baseline cancels out.
	testing.expect_value(t, context.allocator.procedure, mem.tracking_allocator_proc)
	track := cast(^mem.Tracking_Allocator)context.allocator.data
	baseline_count := len(track.allocation_map)
	baseline_bad := len(track.bad_free_array)
	f := test_commands_setup()
	test_commands_setup_singletons(f)
	buf := test_commands_make_buffer(f, "*test*", {}, {"hello"})
	ctx := test_commands_make_context(f, buf)

	sc := test_commands_make_shell(f)
	exec_err, exec_msg := command_manager_execute(
		command_manager_instance(),
		"fail stop-here",
		&ctx,
		&sc,
		f.allocator,
	)
	testing.expect_value(t, exec_err, Commands_Error.Fail)
	testing.expect_value(t, exec_msg, "stop-here")
	delete(exec_msg, f.allocator)
	test_commands_free_shell(f, &sc)
	context_destroy(&ctx)
	test_commands_teardown_singletons()
	test_commands_teardown(f)
	testing.expect_value(t, len(track.allocation_map), baseline_count)
	testing.expect_value(t, len(track.bad_free_array), baseline_bad)
}

@(test)
command_manager_test_execute_buffer_option_fallback :: proc(t: ^testing.T) {
	// Regression: execute's LocalScope must parent to the context
	// buffer scope when no window or local scope applies (C++
	// LocalScope(context) parents to context.scope()); parenting to
	// global hid buffer-local options from window-less hook contexts.
	sync.lock(&test_commands_singleton_mutex)
	defer sync.unlock(&test_commands_singleton_mutex)
	f := test_commands_setup()
	defer test_commands_teardown(f)
	test_commands_setup_singletons(f)
	defer test_commands_teardown_singletons()

	reg := &f.global.global_data.option_registry
	_, _ = option_manager_registry_declare(reg, "_", "", "")

	buf := test_commands_make_buffer(f, "*test*", {}, {"hello"})
	ctx := test_commands_make_context(f, buf)
	defer context_destroy(&ctx)
	// NOTE: no pinned local scope here: the window-less buffer
	// context must fall back to the buffer scope on its own.

	local, lerr := option_manager_get_local_option(&buf.scope.data.options, "_", f.allocator)
	testing.expect_value(t, lerr, Option_Manager_Error.None)
	_, _ = option_manager_option_set_from_strings(local, {"k"})

	dir, derr := os.temp_directory(f.allocator)
	testing.expect_value(t, derr, os.ERROR_NONE)
	defer delete(dir, f.allocator)
	target := strings.concatenate({dir, "/kak-cm-test-bufopt.txt"}, f.allocator)
	defer delete(target, f.allocator)
	defer os.remove(target)

	sc := test_commands_make_shell(f)
	defer test_commands_free_shell(f, &sc)
	cmd := strings.concatenate({"echo -to-file ", target, " -- %opt{_}"}, f.allocator)
	defer delete(cmd, f.allocator)
	exec_err, exec_msg := command_manager_execute(command_manager_instance(), cmd, &ctx, &sc, f.allocator)
	if exec_err != .None {
		delete(exec_msg, f.allocator)
	}
	testing.expect_value(t, exec_err, Commands_Error.None)
	data, rerr := file_read_file(target, false, f.allocator)
	defer delete(data, f.allocator)
	testing.expect_value(t, rerr, File_Error.None)
	testing.expect_value(t, data, "k")
}
