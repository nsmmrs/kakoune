// Tests for main.odin (port of src/main.cc argument parsing, option
// registration, registers, keymaps, env vars, and startup helpers).
//
// src/main.cc has no UnitTest block; tests are written from the C++
// behavior: switch parsing and incompatibilities, +line handling,
// session validation, builtin option defaults, and cleanup. Tests never
// start real servers or listeners.
package kak

import "core:os"
import "core:strings"
import "core:testing"

// main_test_free_strings releases an owned string list.
main_test_free_strings :: proc(list: [dynamic]string) {
	for s in list {
		delete(s)
	}
	delete(list)
}

@(test)
test_main_parse_ui_type :: proc(t: ^testing.T) {
	ui, err := main_parse_ui_type("terminal")
	testing.expect_value(t, err, Main_Error.None)
	testing.expect_value(t, ui, Main_UI_Type.Terminal)
	ui, err = main_parse_ui_type("json")
	testing.expect_value(t, err, Main_Error.None)
	testing.expect_value(t, ui, Main_UI_Type.Json)
	ui, err = main_parse_ui_type("dummy")
	testing.expect_value(t, err, Main_Error.None)
	testing.expect_value(t, ui, Main_UI_Type.Dummy)
	_, err = main_parse_ui_type("curses")
	testing.expect_value(t, err, Main_Error.Unknown_UI)
	_, err = main_parse_ui_type("")
	testing.expect_value(t, err, Main_Error.Unknown_UI)
	_, err = main_parse_ui_type("Terminal")
	testing.expect_value(t, err, Main_Error.Unknown_UI)
}

@(test)
test_main_parse_plus_arg :: proc(t: ^testing.T) {
	// +<line>[:<col>] gives a 0-based coord.
	coord, matched, to_end := main_parse_plus_arg("+12:34")
	testing.expect(t, matched && !to_end)
	testing.expect_value(t, coord.? or_else Coord_Buffer{}, Coord_Buffer{11, 33})
	coord, matched, to_end = main_parse_plus_arg("+12")
	testing.expect(t, matched && !to_end)
	testing.expect_value(t, coord.? or_else Coord_Buffer{}, Coord_Buffer{11, 0})
	// Bare + or +: jumps to end of buffer.
	_, matched, to_end = main_parse_plus_arg("+")
	testing.expect(t, matched && to_end)
	_, matched, to_end = main_parse_plus_arg("+::")
	testing.expect(t, !matched)
	_, matched, to_end = main_parse_plus_arg("+:")
	testing.expect(t, matched && to_end)
	// Bad column still consumes the line, defaulting the column to 0.
	coord, matched, _ = main_parse_plus_arg("+12:abc")
	testing.expect(t, matched)
	testing.expect_value(t, coord.? or_else Coord_Buffer{}, Coord_Buffer{11, 0})
	// Zero and negative-ish lines clamp at 0.
	coord, matched, _ = main_parse_plus_arg("+0:0")
	testing.expect(t, matched)
	testing.expect_value(t, coord.? or_else Coord_Buffer{}, Coord_Buffer{0, 0})
	// Non-numeric plus args and plain names are filenames.
	_, matched, _ = main_parse_plus_arg("+abc")
	testing.expect(t, !matched)
	_, matched, _ = main_parse_plus_arg("file.c")
	testing.expect(t, !matched)
	_, matched, _ = main_parse_plus_arg("")
	testing.expect(t, !matched)
}

@(test)
test_main_session_name_valid :: proc(t: ^testing.T) {
	testing.expect(t, main_session_name_valid("session"))
	testing.expect(t, main_session_name_valid("my-session_2"))
	testing.expect(t, main_session_name_valid("1234"))
	testing.expect(t, !main_session_name_valid(""))
	testing.expect(t, !main_session_name_valid("has space"))
	testing.expect(t, !main_session_name_valid("has/slash"))
	testing.expect(t, !main_session_name_valid("has.dot"))
	testing.expect(t, !main_session_name_valid("semi;colon"))
}

@(test)
test_main_error_message :: proc(t: ^testing.T) {
	testing.expect_value(t, main_error_message(.None), "")
	for err in Main_Error {
		if err == .None {
			continue
		}
		msg := main_error_message(err)
		testing.expect(t, len(msg) > 0, "empty message")
		delete(msg)
	}
}

@(test)
test_main_param_desc :: proc(t: ^testing.T) {
	desc := main_param_desc()
	defer delete(desc.switches)
	testing.expect_value(t, len(desc.switches), 18)
	testing.expect(t, desc.switches["c"].takes_argument)
	testing.expect(t, desc.switches["ui"].takes_argument)
	testing.expect(t, !desc.switches["n"].takes_argument)
	testing.expect(t, !desc.switches["d"].takes_argument)
	testing.expect_value(t, desc.max_positionals, max(int))
}

@(test)
test_main_parse_args_basic :: proc(t: ^testing.T) {
	argv := []string{"-s", "work", "-e", "echo hi", "-E", "echo srv", "a.txt", "b.txt"}
	args, err := main_parse_args(argv)
	defer main_args_destroy(&args)
	testing.expect_value(t, err, Main_Error.None)
	testing.expect_value(t, args.session, "work")
	testing.expect_value(t, args.client_init, "echo hi")
	testing.expect_value(t, args.server_init, "echo srv")
	testing.expect_value(t, args.ui, Main_UI_Type.Terminal)
	testing.expect_value(t, len(args.files), 2)
	testing.expect_value(t, args.files[0], "a.txt")
	testing.expect(t, args.init_coord == nil)
}

@(test)
test_main_parse_args_plus :: proc(t: ^testing.T) {
	argv := []string{"+10:5", "a.txt"}
	args, err := main_parse_args(argv)
	defer main_args_destroy(&args)
	testing.expect_value(t, err, Main_Error.None)
	testing.expect_value(t, args.init_coord.? or_else Coord_Buffer{}, Coord_Buffer{9, 4})
	testing.expect_value(t, len(args.files), 1)

	argv = []string{"+:", "-e", "eval x"}
	args2, err2 := main_parse_args(argv)
	defer main_args_destroy(&args2)
	testing.expect_value(t, err2, Main_Error.None)
	testing.expect_value(t, args2.client_init, "eval x; exec gj")
	testing.expect_value(t, len(args2.files), 0)
}

@(test)
test_main_parse_args_exclusive :: proc(t: ^testing.T) {
	exclusive := [3][]string{{"-s", "a", "-c", "b"}, {"-c", "a", "-C", "b"}, {"-s", "a", "-C", "b"}}
	for argv in exclusive {
		args, err := main_parse_args(argv)
		main_args_destroy(&args)
		testing.expect_value(t, err, Main_Error.Mutually_Exclusive)
	}
	args, err := main_parse_args([]string{"-s", "a"})
	defer main_args_destroy(&args)
	testing.expect_value(t, err, Main_Error.None)
	testing.expect_value(t, args.session, "a")
}

@(test)
test_main_parse_args_pipe :: proc(t: ^testing.T) {
	args, err := main_parse_args([]string{"-p", "work"})
	defer main_args_destroy(&args)
	testing.expect_value(t, err, Main_Error.None)
	testing.expect_value(t, args.pipe.? or_else "", "work")

	pipe_cases := [7][]string{
		{"-p", "work", "-c", "x"},
		{"-p", "work", "-n"},
		{"-p", "work", "-s", "x"},
		{"-p", "work", "-d"},
		{"-p", "work", "-e", "x"},
		{"-p", "work", "-E", "x"},
		{"-p", "work", "-ro"},
	}
	for argv in pipe_cases {
		args2, err2 := main_parse_args(argv)
		main_args_destroy(&args2)
		testing.expect_value(t, err2, Main_Error.Incompatible_Options)
	}
}

@(test)
test_main_parse_args_filter :: proc(t: ^testing.T) {
	argv := []string{"-f", "xyz", "-q", "-i", ".bak", "a.txt"}
	args, err := main_parse_args(argv)
	defer main_args_destroy(&args)
	testing.expect_value(t, err, Main_Error.None)
	testing.expect_value(t, args.filter_keys.? or_else "", "xyz")
	testing.expect(t, args.filter_quiet)
	testing.expect_value(t, args.filter_backup, ".bak")
	testing.expect_value(t, len(args.files), 1)

	args2, err2 := main_parse_args([]string{"-f", "xyz", "-ro"})
	main_args_destroy(&args2)
	testing.expect_value(t, err2, Main_Error.Incompatible_Options)
}

@(test)
test_main_parse_args_ui :: proc(t: ^testing.T) {
	args, err := main_parse_args([]string{"-ui", "json"})
	defer main_args_destroy(&args)
	testing.expect_value(t, err, Main_Error.None)
	testing.expect_value(t, args.ui, Main_UI_Type.Json)

	args2, err2 := main_parse_args([]string{"-ui", "bogus"})
	main_args_destroy(&args2)
	testing.expect_value(t, err2, Main_Error.Unknown_UI)
}

@(test)
test_main_parse_args_modes :: proc(t: ^testing.T) {
	args, err := main_parse_args([]string{"--help"})
	testing.expect_value(t, err, Main_Error.None)
	testing.expect(t, args.show_help)
	main_args_destroy(&args)

	args, err = main_parse_args([]string{"-help"})
	testing.expect_value(t, err, Main_Error.None)
	testing.expect(t, args.show_help)
	main_args_destroy(&args)

	args, err = main_parse_args([]string{"-version"})
	testing.expect_value(t, err, Main_Error.None)
	testing.expect(t, args.show_version)
	main_args_destroy(&args)

	args, err = main_parse_args([]string{"-l", "-clear"})
	testing.expect_value(t, err, Main_Error.None)
	testing.expect(t, args.list_sessions && args.clear_sessions)
	main_args_destroy(&args)

	// Unknown switches and missing values are invalid.
	args, err = main_parse_args([]string{"-bogus"})
	testing.expect_value(t, err, Main_Error.Invalid_Args)
	main_args_destroy(&args)
	args, err = main_parse_args([]string{"-s"})
	testing.expect_value(t, err, Main_Error.Invalid_Args)
	main_args_destroy(&args)
	// Empty argv is a plain server start.
	args, err = main_parse_args(nil)
	testing.expect_value(t, err, Main_Error.None)
	testing.expect_value(t, len(args.files), 0)
	main_args_destroy(&args)
}

@(test)
test_main_classify_args :: proc(t: ^testing.T) {
	// Plain args start a server.
	args, _ := main_parse_args(nil)
	defer main_args_destroy(&args)
	mode, err := main_classify_args(&args, false)
	testing.expect_value(t, err, Main_Error.None)
	testing.expect_value(t, mode, Main_Mode.Server)

	// -c always connects.
	args_c, _ := main_parse_args([]string{"-c", "work"})
	defer main_args_destroy(&args_c)
	mode, _ = main_classify_args(&args_c, false)
	testing.expect_value(t, mode, Main_Mode.Client)

	// -C connects only when the session is up.
	args_C, _ := main_parse_args([]string{"-C", "work"})
	defer main_args_destroy(&args_C)
	mode, _ = main_classify_args(&args_C, true)
	testing.expect_value(t, mode, Main_Mode.Client)
	mode, _ = main_classify_args(&args_C, false)
	testing.expect_value(t, mode, Main_Mode.Server)

	// Daemon mode without a session name is invalid.
	args_d, _ := main_parse_args([]string{"-d"})
	defer main_args_destroy(&args_d)
	_, err = main_classify_args(&args_d, false)
	testing.expect_value(t, err, Main_Error.Invalid_Args)
	args_ds, _ := main_parse_args([]string{"-d", "-s", "work"})
	defer main_args_destroy(&args_ds)
	mode, err = main_classify_args(&args_ds, false)
	testing.expect_value(t, err, Main_Error.None)
	testing.expect_value(t, mode, Main_Mode.Server)

	// Direct modes pass through.
	mode_argv := [5][]string{{"-p", "s"}, {"-f", "k"}, {"-version"}, {"-help"}, {"-l"}}
	mode_want := [5]Main_Mode{.Pipe, .Filter, .Show_Version, .Show_Help, .List_Sessions}
	for i in 0 ..< 5 {
		a, _ := main_parse_args(mode_argv[i])
		defer main_args_destroy(&a)
		m, _ := main_classify_args(&a, false)
		testing.expect_value(t, m, mode_want[i])
	}
}

@(test)
test_main_server_flags :: proc(t: ^testing.T) {
	args, _ := main_parse_args(nil)
	defer main_args_destroy(&args)
	// Bare `kak` on a tty shows startup info.
	testing.expect_value(t, main_server_flags(&args, 1, true), Main_Server_Flags{.Startup_Info})
	testing.expect_value(t, main_server_flags(&args, 1, false), Main_Server_Flags{})
	testing.expect_value(t, main_server_flags(&args, 3, true), Main_Server_Flags{})

	args_n, _ := main_parse_args([]string{"-n"})
	defer main_args_destroy(&args_n)
	testing.expect_value(
		t,
		main_server_flags(&args_n, 2, true),
		Main_Server_Flags{.Ignore_Kakrc, .Startup_Info},
	)

	args_rd, _ := main_parse_args([]string{"-ro", "-d", "-s", "x"})
	defer main_args_destroy(&args_rd)
	testing.expect(
		t,
		main_server_flags(&args_rd, 5, true) == Main_Server_Flags{.Read_Only, .Daemon},
	)
}

@(test)
test_main_client_init_for_files :: proc(t: ^testing.T) {
	// Coordinates apply to the first file only. Paths are absolutized.
	abs_a, _ := file_real_path("missing-a.txt")
	defer delete(abs_a)
	abs_b, _ := file_real_path("missing-b.txt")
	defer delete(abs_b)
	init := main_client_init_for_files(
		[]string{"missing-a.txt", "missing-b.txt"},
		Coord_Buffer{9, 4},
		"echo done",
	)
	defer delete(init)
	want := strings.concatenate({"edit '", abs_a, "' 10 5;edit '", abs_b, "';echo done"})
	defer delete(want)
	testing.expect(t, init == want, init)
	// No files keeps the init commands alone.
	empty := main_client_init_for_files(nil, nil, "echo done")
	defer delete(empty)
	testing.expect_value(t, empty, "echo done")
}

@(test)
test_main_validators :: proc(t: ^testing.T) {
	testing.expect_value(t, main_check_tabstop(8), "")
	testing.expect_value(t, main_check_tabstop(0), "tabstop should be strictly positive")
	testing.expect_value(t, main_check_indentwidth(0), "")
	testing.expect_value(t, main_check_indentwidth(-1), "indentwidth should be positive or zero")
	testing.expect_value(t, main_check_scrolloff(Coord_Display{0, 0}), "")
	testing.expect_value(
		t,
		main_check_scrolloff(Coord_Display{-1, 0}),
		"scroll offset must be positive or zero",
	)
	testing.expect_value(t, main_check_timeout(50), "")
	testing.expect_value(
		t,
		main_check_timeout(49),
		"the minimum acceptable timeout is 50 milliseconds",
	)
	blanks := make([dynamic]rune, 0, 2)
	defer delete(blanks)
	append(&blanks, '_', ' ')
	testing.expect_value(
		t,
		main_check_extra_word_chars(blanks),
		"blanks are not accepted for extra completion characters",
	)
	now_blanks := make([dynamic]rune, 0, 2)
	defer delete(now_blanks)
	append(&now_blanks, '_', '-')
	testing.expect_value(t, main_check_extra_word_chars(now_blanks), "")
	odd := make([dynamic]rune, 0, 2)
	defer delete(odd)
	append(&odd, '(', ')')
	testing.expect_value(t, main_check_matching_pairs(odd), "")
	append(&odd, '{')
	testing.expect_value(
		t,
		main_check_matching_pairs(odd),
		"matching pairs should have a pair number of element",
	)
	letters := make([dynamic]rune, 0, 2)
	defer delete(letters)
	append(&letters, 'a', 'b')
	testing.expect_value(
		t,
		main_check_matching_pairs(letters),
		"matching pairs can only be punctuation",
	)
	// Wrong-typed values pass through (the option system checks types).
	testing.expect_value(t, main_check_tabstop("x"), "")
}

@(test)
test_main_register_options :: proc(t: ^testing.T) {
	manager: Option_Manager
	option_manager_init_root(&manager)
	defer option_manager_destroy(&manager)
	reg: Options_Registry
	option_manager_registry_init(&reg, &manager)
	defer option_manager_registry_destroy(&reg)
	main_register_options(&reg)

	testing.expect_value(t, len(manager.options), 27)
	opt, err := option_manager_get_option(&manager, "tabstop")
	testing.expect_value(t, err, Option_Manager_Error.None)
	testing.expect(t, opt.value.(int) == 8)
	testing.expect(t, opt.validator != nil)

	opt, _ = option_manager_get_option(&manager, "autoinfo")
	testing.expect(t, opt.value.(Auto_Info) == Auto_Info{.Command, .On_Key})
	opt, _ = option_manager_get_option(&manager, "path")
	testing.expect_value(t, opt.value.([dynamic]string)[1], "%/")
	opt, _ = option_manager_get_option(&manager, "completers")
	descs := opt.value.([dynamic]Insert_Completer_Desc)
	testing.expect_value(t, len(descs), 2)
	testing.expect_value(t, descs[0].mode, Insert_Completer_Desc_Mode.Filename)
	testing.expect_value(t, descs[1].param.? or_else "", "all")
	opt, _ = option_manager_get_option(&manager, "matching_pairs")
	testing.expect_value(t, len(opt.value.([dynamic]rune)), 8)
	opt, _ = option_manager_get_option(&manager, "ignored_files")
	testing.expect_value(t, opt.value.(Regex).pattern, `^(\..*|.*\.(o|so|a))$`)
	opt, _ = option_manager_get_option(&manager, "startup_info_version")
	testing.expect(t, opt.value.(int) == 0)
	// Validators run through the stored proc.
	opt, _ = option_manager_get_option(&manager, "idle_timeout")
	testing.expect(t, opt.validator(10) != "")
	testing.expect_value(t, opt.validator(100), "")
}

@(test)
test_main_register_registers :: proc(t: ^testing.T) {
	m := register_manager_make()
	defer register_manager_destroy(&m)
	main_register_registers(&m)

	// 26 letters + " ^ @, 4 history, % . #, 10 digits, _.
	testing.expect_value(t, len(m.registers), 29 + 4 + 3 + 10 + 1)
	for c in "az\"^@/%#._019" {
		_, err := register_manager_get(&m, c)
		testing.expect_value(t, err, Register_Manager_Error.None)
	}
	_, err := register_manager_get(&m, '!')
	testing.expect(t, err != .None)
}

@(test)
test_main_register_keymaps :: proc(t: ^testing.T) {
	m := keymap_manager_init()
	defer keymap_manager_destroy(&m)
	main_register_keymaps(&m)

	info := keymap_manager_get_mapping(&m, {keys_MOD_NONE, keys_LEFT}, .Normal)
	testing.expect(t, info != nil)
	testing.expect_value(t, len(info.keys), 1)
	testing.expect_value(t, info.keys[0], Keys_Key{keys_MOD_NONE, 'h'})
	info = keymap_manager_get_mapping(&m, {keys_MOD_SHIFT, keys_UP}, .Normal)
	testing.expect_value(t, info.keys[0], Keys_Key{keys_MOD_NONE, 'K'})
	info = keymap_manager_get_mapping(&m, {keys_MOD_NONE, keys_HOME}, .Normal)
	testing.expect_value(t, info.keys[0], Keys_Key{keys_MOD_ALT, 'h'})
	info = keymap_manager_get_mapping(&m, {keys_MOD_SHIFT, keys_END}, .Normal)
	testing.expect_value(t, info.keys[0], Keys_Key{keys_MOD_ALT, 'L'})
	// Insert mode is untouched.
	testing.expect(t, keymap_manager_get_mapping(&m, {keys_MOD_NONE, keys_LEFT}, .Insert) == nil)
}

@(test)
test_main_builtin_env_vars :: proc(t: ^testing.T) {
	descs := main_builtin_env_vars()
	defer delete(descs)
	testing.expect_value(t, len(descs), 41)
	testing.expect_value(t, descs[0].str, "bufname")
	testing.expect(t, !descs[0].prefix)
	testing.expect_value(t, descs[11].str, "opt_")
	testing.expect(t, descs[11].prefix)
	testing.expect_value(t, descs[12].str, "main_reg_")
	testing.expect(t, descs[12].prefix)
	testing.expect_value(t, descs[39].str, "history_since_")
	testing.expect(t, descs[39].prefix)
	testing.expect_value(t, descs[40].str, "uncommitted_modifications")
	for d in descs {
		testing.expect(t, d.func != nil)
	}
}

@(test)
test_main_env_simple_getters :: proc(t: ^testing.T) {
	// Getters that need no live editor state.
	version := main_env_version("", nil, context.allocator)
	testing.expect_value(t, len(version), 1)
	testing.expect_value(t, version[0], main_kakoune_version)
	main_test_free_strings(version)

	ctx := Context{name = "client0"}
	client := main_env_client("", &ctx, context.allocator)
	testing.expect_value(t, client[0], "client0")
	main_test_free_strings(client)

	os.set_env("KAKOUNE_RUNTIME", "/tmp/kak-runtime")
	runtime := main_env_runtime("", nil, context.allocator)
	testing.expect_value(t, runtime[0], "/tmp/kak-runtime")
	main_test_free_strings(runtime)
	os.unset_env("KAKOUNE_RUNTIME")
	os.set_env("KAKOUNE_CONFIG_DIR", "/tmp/kak-config")
	config := main_env_config("", nil, context.allocator)
	testing.expect_value(t, config[0], "/tmp/kak-config")
	main_test_free_strings(config)
	os.unset_env("KAKOUNE_CONFIG_DIR")
}

@(test)
test_main_directories :: proc(t: ^testing.T) {
	os.set_env("KAKOUNE_RUNTIME", "/tmp/kak-runtime")
	dir := main_runtime_directory()
	testing.expect_value(t, dir, "/tmp/kak-runtime")
	delete(dir)
	os.unset_env("KAKOUNE_RUNTIME")

	os.set_env("KAKOUNE_CONFIG_DIR", "/tmp/kak-config")
	cfg := main_config_directory()
	testing.expect_value(t, cfg, "/tmp/kak-config")
	delete(cfg)
	os.unset_env("KAKOUNE_CONFIG_DIR")

	// XDG fallback (only when KAKOUNE_CONFIG_DIR is unset).
	os.set_env("XDG_CONFIG_HOME", "/tmp/xdg")
	cfg = main_config_directory()
	testing.expect_value(t, cfg, "/tmp/xdg/kak")
	delete(cfg)
	os.unset_env("XDG_CONFIG_HOME")
}

@(test)
test_main_version_notes :: proc(t: ^testing.T) {
	notes := main_version_notes()
	testing.expect_value(t, len(notes), 4)
	testing.expect_value(t, notes[0].version, 0)
	testing.expect_value(t, notes[3].version, 20250603)
	for n in notes {
		testing.expect(t, len(n.notes) > 0)
	}
}

@(test)
test_main_itoa_codepoint :: proc(t: ^testing.T) {
	ints := [3]int{0, -42, 123456}
	int_want := [3]string{"0", "-42", "123456"}
	for i in 0 ..< 3 {
		got := main_itoa(ints[i])
		testing.expect_value(t, got, int_want[i])
		delete(got)
	}
	cps := [2]rune{'a', 'é'}
	cp_want := [2]string{"a", "é"}
	for i in 0 ..< 2 {
		got := main_codepoint_string(cps[i])
		testing.expect_value(t, got, cp_want[i])
		delete(got)
	}
}

@(test)
test_main_dummy_ui :: proc(t: ^testing.T) {
	ui := main_make_dummy_ui()
	defer main_destroy_ui(ui, .Dummy)
	testing.expect(t, user_interface_is_ok(ui))
	testing.expect_value(t, ui.vtable.dimensions(nil), Coord_Display{24, 80})
	// Every vtable entry is callable and inert.
	ui.vtable.menu_show(nil, nil, {}, {}, {}, .Prompt)
	ui.vtable.menu_select(nil, 0)
	ui.vtable.menu_hide(nil)
	ui.vtable.info_show(nil, nil, nil, {}, {}, .Prompt)
	ui.vtable.info_hide(nil)
	ui.vtable.draw(nil, nil, {}, {}, {}, 0)
	ui.vtable.draw_status(nil, nil, nil, 0, nil, {}, .Status)
	ui.vtable.refresh(nil, true)
	ui.vtable.set_on_key(nil, {})
	ui.vtable.set_on_paste(nil, {})
	ui.vtable.set_ui_options(nil, nil)
	// main_make_ui routes Dummy to the same implementation.
	ui2 := main_make_ui(.Dummy)
	defer main_destroy_ui(ui2, .Dummy)
	testing.expect(t, ui2.vtable == ui.vtable)
}
