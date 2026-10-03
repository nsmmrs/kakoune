package kak

import "core:testing"

// client_manager_test_make_client builds a bare Client with the given
// name (clients are normally built by the STUBBED client_make).
client_manager_test_make_client :: proc(name: string, allocator := context.allocator) -> ^Client {
	c := new(Client, allocator)
	c.input_handler.ctx.name = name
	return c
}

client_manager_test_free_client :: proc(c: ^Client, allocator := context.allocator) {
	delete(c.pending_keys)
	free(c, allocator)
}

// client_manager_test_make_window builds a bare Window on buf (windows
// are normally built by the STUBBED window_make).
client_manager_test_make_window :: proc(buf: ^Buffer, allocator := context.allocator) -> ^Window {
	w := new(Window, allocator)
	w.buffer = buf
	return w
}

client_manager_test_free_window :: proc(w: ^Window, allocator := context.allocator) {
	free(w, allocator)
}

// client_manager_test_reset releases only the manager arrays: clients
// and windows are freed individually because destroying them runs
// STUBBED client/window lifecycle procs.
client_manager_test_reset :: proc(m: ^Client_Manager) {
	delete(m.clients)
	delete(m.client_trash)
	delete(m.free_windows)
	delete(m.window_trash)
	m^ = Client_Manager{}
}

@(test)
client_manager_test_empty_count :: proc(t: ^testing.T) {
	m := client_manager_make()
	defer client_manager_test_reset(&m)
	testing.expect(t, client_manager_empty(&m))
	testing.expect_value(t, client_manager_count(&m), 0)

	c := client_manager_test_make_client("c0")
	defer client_manager_test_free_client(c)
	append(&m.clients, c)
	testing.expect(t, !client_manager_empty(&m))
	testing.expect_value(t, client_manager_count(&m), 1)
}

@(test)
client_manager_test_lookup :: proc(t: ^testing.T) {
	m := client_manager_make()
	defer client_manager_test_reset(&m)
	a := client_manager_test_make_client("alice")
	defer client_manager_test_free_client(a)
	b := client_manager_test_make_client("bob")
	defer client_manager_test_free_client(b)
	append(&m.clients, a)
	append(&m.clients, b)

	testing.expect(t, client_manager_client_name_exists(&m, "alice"))
	testing.expect(t, !client_manager_client_name_exists(&m, "mallory"))
	testing.expect(t, client_manager_get_client_ifp(&m, "bob") == b)
	testing.expect(t, client_manager_get_client_ifp(&m, "mallory") == nil)

	found, err := client_manager_get_client(&m, "alice")
	testing.expect_value(t, err, Client_Manager_Error.None)
	testing.expect(t, found == a)

	_, missing := client_manager_get_client(&m, "mallory")
	testing.expect_value(t, missing, Client_Manager_Error.No_Such_Client)
}

@(test)
client_manager_test_generate_name :: proc(t: ^testing.T) {
	m := client_manager_make()
	defer client_manager_test_reset(&m)

	first := client_manager_generate_name(&m)
	defer delete(first)
	testing.expect_value(t, first, "client0")

	c0 := client_manager_test_make_client("client0")
	defer client_manager_test_free_client(c0)
	c1 := client_manager_test_make_client("client1")
	defer client_manager_test_free_client(c1)
	append(&m.clients, c0)
	append(&m.clients, c1)
	next := client_manager_generate_name(&m)
	defer delete(next)
	testing.expect_value(t, next, "client2")
}

@(test)
client_manager_test_complete_client_name :: proc(t: ^testing.T) {
	m := client_manager_make()
	defer client_manager_test_reset(&m)
	a := client_manager_test_make_client("alice")
	defer client_manager_test_free_client(a)
	b := client_manager_test_make_client("albert")
	defer client_manager_test_free_client(b)
	c := client_manager_test_make_client("bob")
	defer client_manager_test_free_client(c)
	append(&m.clients, a)
	append(&m.clients, b)
	append(&m.clients, c)

	res := client_manager_complete_client_name(&m, "alb")
	defer delete(res)
	testing.expect_value(t, len(res), 1)
	testing.expect_value(t, res[0], "albert")

	trunc := client_manager_complete_client_name(&m, "albz", 3)
	defer delete(trunc)
	testing.expect_value(t, len(trunc), 1)
	testing.expect_value(t, trunc[0], "albert")

	none := client_manager_complete_client_name(&m, "zzz")
	defer delete(none)
	testing.expect_value(t, len(none), 0)
}

@(test)
client_manager_test_has_pending_inputs :: proc(t: ^testing.T) {
	m := client_manager_make()
	defer client_manager_test_reset(&m)
	testing.expect(t, !client_manager_has_pending_inputs(&m))

	c := client_manager_test_make_client("c0")
	defer client_manager_test_free_client(c)
	append(&m.clients, c)
	testing.expect(t, !client_manager_has_pending_inputs(&m))

	append(&c.pending_keys, Keys_Key{})
	testing.expect(t, client_manager_has_pending_inputs(&m))
}

@(test)
client_manager_test_process_pending_empty :: proc(t: ^testing.T) {
	m := client_manager_make()
	defer client_manager_test_reset(&m)
	testing.expect(t, !client_manager_process_pending_inputs(&m))
	// The non-empty path calls STUBBED client procs (see summary).
}

@(test)
client_manager_test_redraw_empty :: proc(t: ^testing.T) {
	m := client_manager_make()
	defer client_manager_test_reset(&m)
	client_manager_redraw_clients(&m)
}

@(test)
client_manager_test_clear_empty :: proc(t: ^testing.T) {
	m := client_manager_make()
	defer client_manager_test_reset(&m)
	client_manager_clear(&m, false)
	client_manager_clear(&m, true)
	client_manager_clear_window_trash(&m)
	client_manager_clear_client_trash(&m)
	testing.expect(t, client_manager_empty(&m))
}

@(test)
client_manager_test_ensure_no_client_noop :: proc(t: ^testing.T) {
	m := client_manager_make()
	defer client_manager_test_reset(&m)
	buf := buffer_manager_test_make_buffer("a", "", {})
	defer buffer_manager_test_free_buffer(buf)

	// No clients and no cached windows: nothing happens, no STUB runs.
	client_manager_ensure_no_client_uses_buffer(&m, buf)
	testing.expect_value(t, len(m.window_trash), 0)
}

@(test)
client_manager_test_ensure_no_client_keeps_others :: proc(t: ^testing.T) {
	m := client_manager_make()
	defer client_manager_test_reset(&m)
	a := buffer_manager_test_make_buffer("a", "", {})
	defer buffer_manager_test_free_buffer(a)
	b := buffer_manager_test_make_buffer("b", "", {})
	defer buffer_manager_test_free_buffer(b)
	w := client_manager_test_make_window(b)
	defer client_manager_test_free_window(w)
	append(&m.free_windows, Window_And_Selections{window = w})

	// Cached windows on other buffers are kept without touching STUBs.
	client_manager_ensure_no_client_uses_buffer(&m, a)
	testing.expect_value(t, len(m.free_windows), 1)
	testing.expect_value(t, len(m.window_trash), 0)
	// The removal path calls STUBBED window procs (see summary).
}

@(test)
client_manager_test_add_free_window_unknown_buffer :: proc(t: ^testing.T) {
	buffer_manager_instance_init()
	defer client_manager_test_reset_buffer_singleton()

	m := client_manager_make()
	defer client_manager_test_reset(&m)
	buf := buffer_manager_test_make_buffer("gone", "", {})
	defer buffer_manager_test_free_buffer(buf)
	w := client_manager_test_make_window(buf)

	// The buffer is not registered: the window goes to the trash.
	client_manager_add_free_window(&m, w, Selection_List{})
	testing.expect_value(t, len(m.free_windows), 0)
	testing.expect_value(t, len(m.window_trash), 1)

	// The trash owns nothing destroyable here; release the bare window.
	clear(&m.window_trash)
	client_manager_test_free_window(w)
	// The cache path calls a STUBBED window proc (see summary).
}

// client_manager_test_reset_buffer_singleton tears down the buffer
// singleton initialized above (empty: no STUB runs).
client_manager_test_reset_buffer_singleton :: proc() {
	buffer_manager_destroy(buffer_manager_instance())
	buffer_manager_has_instance = false
}
