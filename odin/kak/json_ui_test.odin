// Tests for the json_ui module. No C++ UnitTest block covers
// json_ui, so every test below is new. Serializer tests assert the
// exact on-the-wire bytes; eval tests drive json_ui_eval through
// parsed requests; consume tests feed chunked request streams.
// Callbacks record into guarded globals (plain procs cannot close
// over test state, and the runner is multithreaded).
package kak

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

// json_ui_test_keys/_pastes record callback deliveries; guarded by
// json_ui_test_mutex.
json_ui_test_mutex: sync.Mutex
json_ui_test_keys: [dynamic]Keys_Key
json_ui_test_pastes: [dynamic]string

// json_ui_test_claim takes the recorder mutex, waiting bounded. A
// bounds trap in a holder would skip its unlock (test signals
// bypass defers), so an unbounded wait could hang the suite; the
// timeout degrades that catastrophe to a skip.
json_ui_test_claim :: proc() -> bool {
	for _ in 0 ..< 20000 {
		if sync.mutex_try_lock(&json_ui_test_mutex) {
			return true
		}
		time.sleep(100 * time.Microsecond)
	}
	fmt.println("SKIP: json recorders stayed busy")
	return false
}

json_ui_test_on_key :: proc(data: rawptr, key: Keys_Key) {
	_ = data
	append(&json_ui_test_keys, key)
}

json_ui_test_seen_data: rawptr

json_ui_test_on_key_data :: proc(data: rawptr, key: Keys_Key) {
	_ = key
	json_ui_test_seen_data = data
}

json_ui_test_on_paste :: proc(data: rawptr, content: string) {
	_ = data
	append(&json_ui_test_pastes, strings.clone(content))
}

// json_ui_test_reset clears the recorders; call with the mutex held.
json_ui_test_reset :: proc() {
	clear(&json_ui_test_keys)
	for pasted in json_ui_test_pastes {
		delete(pasted)
	}
	clear(&json_ui_test_pastes)
}

// json_ui_test_teardown clears the recorders and releases their backing
// stores so per-test tracking sees no leftover; call with the mutex held.
json_ui_test_teardown :: proc() {
	json_ui_test_reset()
	delete(json_ui_test_keys)
	delete(json_ui_test_pastes)
	json_ui_test_keys = nil
	json_ui_test_pastes = nil
}

// json_ui_test_eval_ui builds a callback-wired UI for eval tests.
json_ui_test_eval_ui :: proc() -> Json_Ui {
	return Json_Ui{
		on_key     = {json_ui_test_on_key, nil},
		on_paste   = {json_ui_test_on_paste, nil},
		allocator  = context.allocator,
	}
}

// json_ui_test_parse parses one request object; the caller frees it
// with json_free.
json_ui_test_parse :: proc(t: ^testing.T, text: string) -> Json_Value {
	val, err := json_parse(text)
	testing.expect_value(t, err, Json_Error.None)
	return val
}

@(test)
json_ui_test_color :: proc(t: ^testing.T) {
	rgb, rgb_err := color_from_rgb(255, 0, 128)
	testing.expect_value(t, rgb_err, Color_Error.None)
	hex := json_ui_to_json_color(rgb)
	defer delete(hex)
	testing.expect_value(t, hex, "#ff0080")
	padded, _ := color_from_rgb(1, 2, 3)
	padded_json := json_ui_to_json_color(padded)
	defer delete(padded_json)
	testing.expect_value(t, padded_json, "#010203")
	red := json_ui_to_json_color(color_from_named(.Red))
	defer delete(red)
	testing.expect_value(t, red, `"red"`)
	def := json_ui_to_json_color(color_from_named(.Default))
	defer delete(def)
	testing.expect_value(t, def, `"default"`)
}

@(test)
json_ui_test_attrs :: proc(t: ^testing.T) {
	empty := json_ui_to_json_attrs({})
	defer delete(empty)
	testing.expect_value(t, empty, "[]")
	one := json_ui_to_json_attrs({.Bold})
	defer delete(one)
	testing.expect_value(t, one, `["bold"]`)
	// C++ order (not enum order), comma without space.
	ordered := json_ui_to_json_attrs({.Strikethrough, .Bold})
	defer delete(ordered)
	testing.expect_value(t, ordered, `["bold","strikethrough"]`)
	all := json_ui_to_json_attrs({.Underline, .Curly_Underline, .Double_Underline, .Reverse, .Blink, .Bold, .Dim, .Italic, .Final_Fg, .Final_Bg, .Final_Attr, .Strikethrough})
	defer delete(all)
	testing.expect_value(
		t,
		all,
		`["underline","curly_underline","double_underline","reverse","blink","bold","dim","italic","final_fg","final_bg","final_attr","strikethrough"]`,
	)
}

@(test)
json_ui_test_face :: proc(t: ^testing.T) {
	face := Face{fg = color_from_named(.Red), bg = color_from_named(.Default), underline = color_from_named(.Blue), attributes = {.Bold, .Italic}}
	got := json_ui_to_json_face(face)
	defer delete(got)
	testing.expect_value(
		t,
		got,
		`{ "fg": "red", "bg": "default", "underline": "blue", "attributes": ["bold","italic"] }`,
	)
	plain := json_ui_to_json_face(Face{})
	defer delete(plain)
	testing.expect_value(
		t,
		plain,
		`{ "fg": "default", "bg": "default", "underline": "default", "attributes": [] }`,
	)
}

@(test)
json_ui_test_atom :: proc(t: ^testing.T) {
	atom := display_buffer_atom_text("hi", Face{})
	got := json_ui_to_json_atom(atom)
	defer delete(got)
	face := json_ui_to_json_face(Face{}, context.temp_allocator)
	want := strings.concatenate({`{ "face": `, face, `, "contents": "hi" }`}, context.temp_allocator)
	testing.expect_value(t, got, want)
	escaped := display_buffer_atom_text("a\"b\\c\n", Face{})
	escaped_json := json_ui_to_json_atom(escaped)
	defer delete(escaped_json)
	testing.expect(t, strings.contains(escaped_json, "\"a\\\"b\\\\c\\u000a\""))
}

@(test)
json_ui_test_line :: proc(t: ^testing.T) {
	line := display_buffer_line_make()
	defer display_buffer_line_destroy(&line)
	append(&line.atoms, display_buffer_atom_text("a", Face{}))
	append(&line.atoms, display_buffer_atom_text("b", Face{}))
	got := json_ui_to_json_line(line)
	defer delete(got)
	atom_a := json_ui_to_json_atom(line.atoms[0], context.temp_allocator)
	atom_b := json_ui_to_json_atom(line.atoms[1], context.temp_allocator)
	want := strings.concatenate({"[", atom_a, ", ", atom_b, "]"}, context.temp_allocator)
	testing.expect_value(t, got, want)
	bare := display_buffer_line_make()
	defer display_buffer_line_destroy(&bare)
	bare_json := json_ui_to_json_line(bare)
	defer delete(bare_json)
	testing.expect_value(t, bare_json, "[]")
}

@(test)
json_ui_test_lines_coord_column :: proc(t: ^testing.T) {
	line := display_buffer_line_make()
	defer display_buffer_line_destroy(&line)
	append(&line.atoms, display_buffer_atom_text("x", Face{}))
	lines := [1]Display_Line{line}
	got := json_ui_to_json_lines(lines[:])
	defer delete(got)
	inner := json_ui_to_json_line(line, context.temp_allocator)
	want := strings.concatenate({"[", inner, "]"}, context.temp_allocator)
	testing.expect_value(t, got, want)
	none := json_ui_to_json_lines(nil)
	defer delete(none)
	testing.expect_value(t, none, "[]")
	coord := json_ui_to_json_coord({3, 7})
	defer delete(coord)
	testing.expect_value(t, coord, `{ "line": 3, "column": 7 }`)
	column := json_ui_to_json_column(42)
	defer delete(column)
	testing.expect_value(t, column, "42")
}

@(test)
json_ui_test_styles :: proc(t: ^testing.T) {
	testing.expect_value(t, json_ui_to_json_menu_style(.Prompt), `"prompt"`)
	testing.expect_value(t, json_ui_to_json_menu_style(.Search), `"search"`)
	testing.expect_value(t, json_ui_to_json_menu_style(.Inline), `"inline"`)
	testing.expect_value(t, json_ui_to_json_info_style(.Prompt), `"prompt"`)
	testing.expect_value(t, json_ui_to_json_info_style(.Inline), `"inline"`)
	testing.expect_value(t, json_ui_to_json_info_style(.Inline_Above), `"inlineAbove"`)
	testing.expect_value(t, json_ui_to_json_info_style(.Inline_Below), `"inlineBelow"`)
	testing.expect_value(t, json_ui_to_json_info_style(.Menu_Doc), `"menuDoc"`)
	testing.expect_value(t, json_ui_to_json_info_style(.Modal), `"modal"`)
	testing.expect_value(t, json_ui_to_json_status_style(.Status), `"status"`)
	testing.expect_value(t, json_ui_to_json_status_style(.Command), `"command"`)
	testing.expect_value(t, json_ui_to_json_status_style(.Search), `"search"`)
	testing.expect_value(t, json_ui_to_json_status_style(.Prompt), `"prompt"`)
}

@(test)
json_ui_test_options :: proc(t: ^testing.T) {
	empty: User_Interface_Options = {}
	defer delete(empty)
	got_empty := json_ui_to_json_options(empty)
	defer delete(got_empty)
	testing.expect_value(t, got_empty, "{}")
	single := make(User_Interface_Options)
	defer delete(single)
	single["key"] = "v\"x"
	got_single := json_ui_to_json_options(single)
	defer delete(got_single)
	testing.expect_value(t, got_single, `{"key": "v\"x"}`)
	multi := make(User_Interface_Options)
	defer delete(multi)
	multi["a"] = "1"
	multi["b"] = "2"
	got_multi := json_ui_to_json_options(multi)
	defer delete(got_multi)
	// Member order follows map order; check shape, not order.
	testing.expect(t, strings.contains(got_multi, `"a": "1"`))
	testing.expect(t, strings.contains(got_multi, `"b": "2"`))
	testing.expect(t, !strings.contains(got_multi, ", "))
}

@(test)
json_ui_test_format_rpc :: proc(t: ^testing.T) {
	bare := json_ui_format_rpc("menu_hide")
	defer delete(bare)
	testing.expect_value(t, bare, "{ \"jsonrpc\": \"2.0\", \"method\": \"menu_hide\", \"params\": [] }\n")
	params := [2]string{`"a"`, `1`}
	call := json_ui_format_rpc("menu_select", params[:])
	defer delete(call)
	testing.expect_value(t, call, "{ \"jsonrpc\": \"2.0\", \"method\": \"menu_select\", \"params\": [\"a\", 1] }\n")
}

@(test)
json_ui_test_error_messages :: proc(t: ^testing.T) {
	testing.expect_value(t, json_ui_error_message(.None), "")
	for err in Json_Ui_Error {
		if err == .None {
			continue
		}
		testing.expect(t, len(json_ui_error_message(err)) != 0)
	}
	testing.expect_value(t, json_ui_parse_error_message(.None), "")
	for err in Json_Error {
		if err == .None {
			continue
		}
		testing.expect(t, len(json_ui_parse_error_message(err)) != 0)
	}
	testing.expect_value(t, json_ui_parse_error_message(.Max_Depth), "maximum parsing depth reached")
	testing.expect_value(t, json_ui_parse_error_message(.Expected_Colon), "expected :")
}

@(test)
json_ui_test_unwrap :: proc(t: ^testing.T) {
	line := display_buffer_line_make()
	defer display_buffer_line_destroy(&line)
	wrapped := User_Interface_Display_Line{opaque = &line}
	testing.expect(t, json_ui_unwrap_line(wrapped) == &line)
	db := Display_Buffer{}
	wrapped_db := cast(^User_Interface_Display_Buffer)&db
	testing.expect(t, json_ui_unwrap_buffer(wrapped_db) == &db)
}

// json_ui_test_eval feeds text through json_parse and json_ui_eval
// with the recorders wired; call with the mutex held.
json_ui_test_eval :: proc(t: ^testing.T, ui: ^Json_Ui, text: string) -> Json_Ui_Error {
	val := json_ui_test_parse(t, text)
	defer json_free(val)
	return json_ui_eval(ui, val)
}

// json_ui_test_expect_key checks recorded key index against want. The
// length gate matters: a bounds trap would skip the mutex unlock and
// hang the other recorder tests.
json_ui_test_expect_key :: proc(t: ^testing.T, index: int, want: Keys_Key) {
	testing.expect(t, index < len(json_ui_test_keys))
	if index < len(json_ui_test_keys) {
		testing.expect_value(t, json_ui_test_keys[index], want)
	}
}

@(test)
json_ui_test_eval_keys :: proc(t: ^testing.T) {
	if !json_ui_test_claim() {
		return
	}
	defer sync.mutex_unlock(&json_ui_test_mutex)
	json_ui_test_reset()
	defer json_ui_test_teardown()
	ui := json_ui_test_eval_ui()
	err := json_ui_test_eval(t, &ui, `{"jsonrpc": "2.0", "method": "keys", "params": ["xy", "<ret>"]}`)
	testing.expect_value(t, err, Json_Ui_Error.None)
	testing.expect_value(t, len(json_ui_test_keys), 3)
	json_ui_test_expect_key(t, 0, Keys_Key{keys_MOD_NONE, 'x'})
	json_ui_test_expect_key(t, 1, Keys_Key{keys_MOD_NONE, 'y'})
	json_ui_test_expect_key(t, 2, Keys_Key{keys_MOD_NONE, keys_RETURN})
	// Non-string params and bad descriptions fail.
	testing.expect_value(
		t,
		json_ui_test_eval(t, &ui, `{"jsonrpc": "2.0", "method": "keys", "params": [1]}`),
		Json_Ui_Error.Bad_Keys,
	)
	testing.expect_value(
		t,
		json_ui_test_eval(t, &ui, `{"jsonrpc": "2.0", "method": "keys", "params": ["<s-1>"]}`),
		Json_Ui_Error.Key_Error,
	)
}

@(test)
json_ui_test_eval_paste :: proc(t: ^testing.T) {
	if !json_ui_test_claim() {
		return
	}
	defer sync.mutex_unlock(&json_ui_test_mutex)
	json_ui_test_reset()
	defer json_ui_test_teardown()
	ui := json_ui_test_eval_ui()
	// Note "anb": the JSON port does not interpret escapes (like
	// the C++), so "\n" parses to "n".
	err := json_ui_test_eval(t, &ui, `{"jsonrpc": "2.0", "method": "paste", "params": ["a\nb"]}`)
	testing.expect_value(t, err, Json_Ui_Error.None)
	testing.expect_value(t, len(json_ui_test_pastes), 1)
	if len(json_ui_test_pastes) == 1 {
		testing.expect_value(t, json_ui_test_pastes[0], "anb")
	}
	testing.expect_value(
		t,
		json_ui_test_eval(t, &ui, `{"jsonrpc": "2.0", "method": "paste", "params": []}`),
		Json_Ui_Error.Bad_Paste,
	)
	testing.expect_value(
		t,
		json_ui_test_eval(t, &ui, `{"jsonrpc": "2.0", "method": "paste", "params": [7]}`),
		Json_Ui_Error.Bad_Paste,
	)
	// Without a paste callback the request still succeeds.
	bare := Json_Ui{on_key = {json_ui_test_on_key, nil}, allocator = context.allocator}
	testing.expect_value(
		t,
		json_ui_test_eval(t, &bare, `{"jsonrpc": "2.0", "method": "paste", "params": ["z"]}`),
		Json_Ui_Error.None,
	)
}

@(test)
json_ui_test_eval_mouse :: proc(t: ^testing.T) {
	if !json_ui_test_claim() {
		return
	}
	defer sync.mutex_unlock(&json_ui_test_mutex)
	json_ui_test_reset()
	defer json_ui_test_teardown()
	ui := json_ui_test_eval_ui()
	testing.expect_value(
		t,
		json_ui_test_eval(t, &ui, `{"jsonrpc": "2.0", "method": "mouse_move", "params": [3, 7]}`),
		Json_Ui_Error.None,
	)
	testing.expect_value(t, len(json_ui_test_keys), 1)
	if len(json_ui_test_keys) == 1 {
		testing.expect_value(t, json_ui_test_keys[0].modifiers, keys_MOD_MOUSE_POS)
		testing.expect_value(t, keys_coord(json_ui_test_keys[0]), Keys_Coord{3, 7})
	}
	json_ui_test_reset()
	testing.expect_value(
		t,
		json_ui_test_eval(t, &ui, `{"jsonrpc": "2.0", "method": "mouse_press", "params": ["right", 1, 2]}`),
		Json_Ui_Error.None,
	)
	if len(json_ui_test_keys) == 1 {
		testing.expect_value(
			t,
			json_ui_test_keys[0].modifiers,
			keys_MOD_MOUSE_PRESS | keys_button_modifier(.Right),
		)
		testing.expect_value(t, keys_coord(json_ui_test_keys[0]), Keys_Coord{1, 2})
	}
	json_ui_test_reset()
	testing.expect_value(
		t,
		json_ui_test_eval(t, &ui, `{"jsonrpc": "2.0", "method": "mouse_release", "params": ["middle", 0, 0]}`),
		Json_Ui_Error.None,
	)
	if len(json_ui_test_keys) == 1 {
		testing.expect_value(
			t,
			json_ui_test_keys[0].modifiers,
			keys_MOD_MOUSE_RELEASE | keys_button_modifier(.Middle),
		)
	}
	testing.expect_value(
		t,
		json_ui_test_eval(t, &ui, `{"jsonrpc": "2.0", "method": "mouse_move", "params": [1]}`),
		Json_Ui_Error.Bad_Mouse,
	)
	testing.expect_value(
		t,
		json_ui_test_eval(t, &ui, `{"jsonrpc": "2.0", "method": "mouse_press", "params": [1, 2, 3]}`),
		Json_Ui_Error.Bad_Mouse,
	)
	testing.expect_value(
		t,
		json_ui_test_eval(t, &ui, `{"jsonrpc": "2.0", "method": "mouse_press", "params": ["bogus", 1, 2]}`),
		Json_Ui_Error.Key_Error,
	)
}

@(test)
json_ui_test_eval_scroll_menu_resize :: proc(t: ^testing.T) {
	if !json_ui_test_claim() {
		return
	}
	defer sync.mutex_unlock(&json_ui_test_mutex)
	json_ui_test_reset()
	defer json_ui_test_teardown()
	ui := json_ui_test_eval_ui()
	testing.expect_value(
		t,
		json_ui_test_eval(t, &ui, `{"jsonrpc": "2.0", "method": "scroll", "params": [3, 1, 2]}`),
		Json_Ui_Error.None,
	)
	testing.expect_value(t, len(json_ui_test_keys), 1)
	if len(json_ui_test_keys) == 1 {
		testing.expect_value(t, keys_scroll_amount(json_ui_test_keys[0]), 3)
		testing.expect_value(t, keys_coord(json_ui_test_keys[0]), Keys_Coord{1, 2})
	}
	testing.expect_value(
		t,
		json_ui_test_eval(t, &ui, `{"jsonrpc": "2.0", "method": "scroll", "params": [1, 2]}`),
		Json_Ui_Error.Bad_Scroll,
	)
	json_ui_test_reset()
	testing.expect_value(
		t,
		json_ui_test_eval(t, &ui, `{"jsonrpc": "2.0", "method": "menu_select", "params": [7]}`),
		Json_Ui_Error.None,
	)
	json_ui_test_expect_key(t, 0, Keys_Key{keys_MOD_MENU_SELECT, rune(7)})
	testing.expect_value(
		t,
		json_ui_test_eval(t, &ui, `{"jsonrpc": "2.0", "method": "menu_select", "params": []}`),
		Json_Ui_Error.Bad_Menu_Select,
	)
	json_ui_test_reset()
	testing.expect_value(
		t,
		json_ui_test_eval(t, &ui, `{"jsonrpc": "2.0", "method": "resize", "params": [24, 80]}`),
		Json_Ui_Error.None,
	)
	testing.expect_value(t, ui.dimensions, Coord_Display{24, 80})
	json_ui_test_expect_key(t, 0, keys_resize(Keys_Coord{24, 80}))
	testing.expect_value(
		t,
		json_ui_test_eval(t, &ui, `{"jsonrpc": "2.0", "method": "resize", "params": [24]}`),
		Json_Ui_Error.Bad_Resize,
	)
	testing.expect_value(
		t,
		json_ui_test_eval(t, &ui, `{"jsonrpc": "2.0", "method": "resize", "params": ["a", "b"]}`),
		Json_Ui_Error.Bad_Resize,
	)
}

@(test)
json_ui_test_eval_envelope :: proc(t: ^testing.T) {
	if !json_ui_test_claim() {
		return
	}
	defer sync.mutex_unlock(&json_ui_test_mutex)
	json_ui_test_reset()
	defer json_ui_test_teardown()
	ui := json_ui_test_eval_ui()
	testing.expect_value(t, json_ui_test_eval(t, &ui, `[1, 2]`), Json_Ui_Error.Not_An_Object)
	testing.expect_value(
		t,
		json_ui_test_eval(t, &ui, `{"method": "keys", "params": []}`),
		Json_Ui_Error.Bad_Protocol,
	)
	testing.expect_value(
		t,
		json_ui_test_eval(t, &ui, `{"jsonrpc": "1.0", "method": "keys", "params": []}`),
		Json_Ui_Error.Bad_Protocol,
	)
	testing.expect_value(
		t,
		json_ui_test_eval(t, &ui, `{"jsonrpc": "2.0", "params": []}`),
		Json_Ui_Error.Bad_Method,
	)
	testing.expect_value(
		t,
		json_ui_test_eval(t, &ui, `{"jsonrpc": "2.0", "method": 1, "params": []}`),
		Json_Ui_Error.Bad_Method,
	)
	testing.expect_value(
		t,
		json_ui_test_eval(t, &ui, `{"jsonrpc": "2.0", "method": "keys"}`),
		Json_Ui_Error.Bad_Params,
	)
	testing.expect_value(
		t,
		json_ui_test_eval(t, &ui, `{"jsonrpc": "2.0", "method": "keys", "params": {}}`),
		Json_Ui_Error.Bad_Params,
	)
	testing.expect_value(
		t,
		json_ui_test_eval(t, &ui, `{"jsonrpc": "2.0", "method": "bogus", "params": []}`),
		Json_Ui_Error.Unknown_Method,
	)
	testing.expect_value(t, len(json_ui_test_keys), 0)
}

@(test)
json_ui_test_consume :: proc(t: ^testing.T) {
	if !json_ui_test_claim() {
		return
	}
	defer sync.mutex_unlock(&json_ui_test_mutex)
	json_ui_test_reset()
	defer json_ui_test_teardown()
	ui := json_ui_test_eval_ui()
	// Nothing runs without a key callback; input is retained.
	unwired := Json_Ui{allocator = context.allocator, requests = strings.clone(" ", context.allocator)}
	defer delete(unwired.requests)
	json_ui_consume_requests(&unwired)
	testing.expect_value(t, unwired.requests, " ")
	// Two requests in one buffer both run; the buffer drains.
	ui.requests = strings.clone(
		"{\"jsonrpc\": \"2.0\", \"method\": \"keys\", \"params\": [\"a\"]}\n{\"jsonrpc\": \"2.0\", \"method\": \"keys\", \"params\": [\"b\"]}",
		context.allocator,
	)
	defer delete(ui.requests)
	json_ui_consume_requests(&ui)
	testing.expect_value(t, len(json_ui_test_keys), 2)
	if len(json_ui_test_keys) == 2 {
		testing.expect_value(t, json_ui_test_keys[0].key, 'a')
		testing.expect_value(t, json_ui_test_keys[1].key, 'b')
	}
	testing.expect_value(t, ui.requests, "")
	// A trailing partial request waits for the rest.
	json_ui_test_reset()
	delete(ui.requests)
	ui.requests = strings.clone("{\"jsonrpc\": \"2.0\", \"method\": \"keys\", \"params\": [\"c", context.allocator)
	json_ui_consume_requests(&ui)
	testing.expect_value(t, len(json_ui_test_keys), 0)
	rest := strings.concatenate({ui.requests, "\"]}"}, context.allocator)
	delete(ui.requests)
	ui.requests = rest
	json_ui_consume_requests(&ui)
	testing.expect_value(t, len(json_ui_test_keys), 1)
	if len(json_ui_test_keys) == 1 {
		testing.expect_value(t, json_ui_test_keys[0].key, 'c')
	}
	testing.expect_value(t, ui.requests, "")
}

@(test)
json_ui_test_consume_salvage :: proc(t: ^testing.T) {
	if !json_ui_test_claim() {
		return
	}
	defer sync.mutex_unlock(&json_ui_test_mutex)
	json_ui_test_reset()
	defer json_ui_test_teardown()
	// A bad line is dropped (with one stderr line) and the good
	// request after it still runs.
	ui := json_ui_test_eval_ui()
	ui.requests = strings.clone(
		"{\"a\": nope}\n{\"jsonrpc\": \"2.0\", \"method\": \"keys\", \"params\": [\"q\"]}",
		context.allocator,
	)
	defer delete(ui.requests)
	json_ui_consume_requests(&ui)
	testing.expect_value(t, len(json_ui_test_keys), 1)
	if len(json_ui_test_keys) == 1 {
		testing.expect_value(t, json_ui_test_keys[0].key, 'q')
	}
	testing.expect_value(t, ui.requests, "")
}

@(test)
json_ui_test_vtable_plumbing :: proc(t: ^testing.T) {
	ui := Json_Ui{allocator = context.allocator, dimensions = {10, 20}}
	iface := user_interface_make(&ui, &json_ui_vtable)
	testing.expect_value(t, user_interface_dimensions(&iface), Coord_Display{10, 20})
	ui.watcher.fd = 0
	testing.expect(t, user_interface_is_ok(&iface))
	ui.watcher.fd = -1
	testing.expect(t, !user_interface_is_ok(&iface))
	user_interface_set_on_key(&iface, {json_ui_test_on_key, nil})
	testing.expect(t, ui.on_key.call != nil)
	user_interface_set_on_paste(&iface, {json_ui_test_on_paste, nil})
	testing.expect(t, ui.on_paste.call != nil)
}

@(test)
json_ui_test_callback_receives_data :: proc(t: ^testing.T) {
	if !json_ui_test_claim() {
		return
	}
	defer sync.mutex_unlock(&json_ui_test_mutex)
	json_ui_test_reset()
	defer json_ui_test_teardown()
	// The client reaches the UI through the callback data (this wiring
	// delivers scripted keys to the input handler).
	marker: int = 42
	ui := json_ui_test_eval_ui()
	ui.requests = strings.clone(
		"{\"jsonrpc\": \"2.0\", \"method\": \"keys\", \"params\": [\"q\"]}",
		context.allocator,
	)
	defer delete(ui.requests)
	ui.on_key = {json_ui_test_on_key_data, &marker}
	json_ui_test_seen_data = nil
	json_ui_consume_requests(&ui)
	testing.expect(t, json_ui_test_seen_data == rawptr(&marker), "key callback must receive its data")
}
