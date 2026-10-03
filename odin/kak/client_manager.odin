// Client manager ported from src/client_manager.{hh,cc}: the live
// client list, free window cache, and deletion trashes.
//
// Clients and windows are owned heap objects. Free windows keep their
// last selections for reuse by later clients on the same buffer.
package kak

import "core:fmt"

// Client_Manager_Error reports client manager failures (port of the
// runtime_errors thrown by ClientManager).
Client_Manager_Error :: enum {
	None,
	No_Such_Client,
	Buffer_Error,
}

// Client_Manager_Instance is the ClientManager singleton.
Client_Manager_Instance: Client_Manager

// client_manager_has_instance reports whether the singleton was
// initialized (port of Singleton::has_instance).
client_manager_has_instance := false

// client_manager_instance returns the singleton (port of
// Singleton::instance).
client_manager_instance :: proc() -> ^Client_Manager {
	assert(client_manager_has_instance)
	return &Client_Manager_Instance
}

// client_manager_instance_init initializes the singleton.
client_manager_instance_init :: proc(allocator := context.allocator) {
	Client_Manager_Instance = client_manager_make(allocator)
	client_manager_has_instance = true
}

// client_manager_make builds an empty client manager.
client_manager_make :: proc(allocator := context.allocator) -> Client_Manager {
	return Client_Manager {
		clients      = make([dynamic]^Client, allocator),
		client_trash = make([dynamic]^Client, allocator),
		free_windows = make([dynamic]Window_And_Selections, allocator),
		window_trash = make([dynamic]^Window, allocator),
		allocator    = allocator,
	}
}

// client_manager_destroy frees the manager (port of ~ClientManager,
// which clears with disconnect). Calls STUBBED client/window procs
// unless the manager is empty.
client_manager_destroy :: proc(m: ^Client_Manager) {
	client_manager_clear(m, true)
	delete(m.clients)
	delete(m.client_trash)
	delete(m.free_windows)
	delete(m.window_trash)
	m^ = Client_Manager{}
}

// client_manager_clear removes every client and window (port of
// ClientManager::clear). With disconnect_clients, clients are removed
// through the ClientClose hook; otherwise they are destroyed directly.
// Calls STUBBED client/window procs unless the manager is empty.
client_manager_clear :: proc(m: ^Client_Manager, disconnect_clients: bool) {
	if disconnect_clients {
		for len(m.clients) > 0 {
			client_manager_remove_client(m, m.clients[0], true, 0)
		}
	} else {
		for c in m.clients {
			client_destroy(c)
		}
		clear(&m.clients)
	}
	for c in m.client_trash {
		client_destroy(c)
	}
	clear(&m.client_trash)
	for ws in m.free_windows {
		window_run_hook_in_own_context(
			ws.window,
			.Win_Close,
			buffer_manager_buffer_name(ws.window.buffer),
			"",
		)
	}
	for i := 0; i < len(m.free_windows); i += 1 {
		window_destroy(m.free_windows[i].window)
		selection_list_destroy(&m.free_windows[i].selections)
	}
	clear(&m.free_windows)
	for w in m.window_trash {
		window_destroy(w)
	}
	clear(&m.window_trash)
}

// client_manager_default_selection builds the C++ Selection{} used for
// fresh windows (origin with no goal column).
@(private = "file")
client_manager_default_selection :: proc() -> Selection {
	origin := Coord_Buffer{}
	return Selection{basic = Basic_Selection{anchor = origin, cursor = coord_buffer_and_target(origin)}}
}

// client_manager_selection_at builds the C++ Selection(coord) used for
// the initial client selections.
@(private = "file")
client_manager_selection_at :: proc(c: Coord_Buffer) -> Selection {
	return Selection{basic = Basic_Selection{anchor = c, cursor = coord_buffer_and_target(c)}}
}

// client_manager_generate_name picks the first unused client{i} name
// (port of ClientManager::generate_name). The returned string is owned.
client_manager_generate_name :: proc(m: ^Client_Manager, allocator := context.allocator) -> string {
	i := 0
	for {
		name := fmt.aprintf("client%d", i, allocator = allocator)
		if !client_manager_client_name_exists(m, name) {
			return name
		}
		delete(name, allocator)
		i += 1
	}
}

// client_manager_create_client registers a new client on init_buffer (or
// the most recently used buffer), reusing a free window when one fits
// (port of ClientManager::create_client). The manager takes ownership of
// ui, env_vars, and a generated name; a caller-provided name is
// borrowed. Returns nil when hooks moved the client to the trash during
// creation. Calls STUBBED client/window/context/command procs.
//
// NOTE: the C++ wraps the ClientCreate hook and init command execution in
// try/catch(runtime_error), printing the error as status and running the
// RuntimeError hook. The stubs below are infallible translations of the
// C++ signatures; the coordinator wires error handling here when the
// real fallible procs merge.
client_manager_create_client :: proc(
	m: ^Client_Manager,
	ui: ^User_Interface,
	ui_type: Main_UI_Type,
	pid: int,
	name: string,
	env_vars: Env_Var_Map,
	init_cmds: string,
	init_buffer: string,
	init_coord: Maybe(Coord_Buffer),
	on_exit: Client_On_Exit_Callback,
) -> (
	client: ^Client,
	err: Client_Manager_Error,
) {
	buffers := buffer_manager_instance()
	buf: ^Buffer
	if len(init_buffer) > 0 {
		buf = buffer_manager_get_ifp(buffers, init_buffer)
	}
	if buf == nil {
		first, first_err := buffer_manager_get_first(buffers)
		if first_err != .None {
			return nil, .Buffer_Error
		}
		buf = first
	}

	buf.flags += {.Locked}
	ws := client_manager_get_free_window(m, buf)
	client_name := name
	if len(client_name) == 0 {
		client_name = client_manager_generate_name(m, m.allocator)
	}
	c := client_make(ui, ui_type, ws.window, ws.selections, pid, env_vars, client_name, on_exit, m.allocator)
	append(&m.clients, c)

	ctx := &c.input_handler.ctx
	if buffer_manager_buffer_name(context_buffer(ctx)) == "*scratch*" {
		faces := context_faces(ctx)
		info_face, info_err := face_registry_lookup(faces, "Information", m.allocator)
		assert(info_err == .None)
		line := client_display_line_from_text(
			"This *scratch* buffer won't be automatically saved",
			info_face,
			m.allocator,
		)
		context_print_status_simple(ctx, line)
	}

	if coord, ok := init_coord.?; ok {
		sels := context_selections_write_only(ctx)
		selection_list_destroy(sels)
		sels^ = selection_list_make_single(
			buf,
			client_manager_selection_at(buffer_clamp(buf, coord)),
			buffer_timestamp(buf),
			m.allocator,
		)
		window_center_line(context_window(ctx), coord.line)
	}

	buf.flags -= {.Locked}

	hooks := context_hooks(ctx)
	hook_manager_run_hook(hooks, .Client_Create, ctx.name, ctx)
	sh_ctx := Shell_Context{}
	if exec_err, exec_msg := command_manager_execute(command_manager_instance(), init_cmds, ctx, &sh_ctx, m.allocator); exec_err == .Kill_Session {
		// C++ lets kill_session unwind quietly; clients are gone.
		delete(exec_msg, m.allocator)
	} else if exec_err != .None {
		// C++ catch (runtime_error): report the failure, run RuntimeError.
		// kill_session unwinds silently past this boundary.
		defer delete(exec_msg, m.allocator)
		if exec_err != .Kill_Session {
			err_faces := context_faces(ctx)
			err_face, err_face_err := face_registry_lookup(err_faces, "Error", m.allocator)
			assert(err_face_err == .None)
			// from_text clones for client ownership; the message dies
			// after the hook below is done with it.
			err_line := client_display_line_from_text(exec_msg, err_face, m.allocator)
			context_print_status_simple(ctx, err_line)
			hook_manager_run_hook(hooks, .Runtime_Error, exec_msg, ctx)
		}
	}

	for existing in m.clients {
		if existing == c {
			return c, .None
		}
	}
	return nil, .None
}

// client_manager_empty reports whether no client exists (port of
// ClientManager::empty).
client_manager_empty :: proc(m: ^Client_Manager) -> bool {
	return len(m.clients) == 0
}

// client_manager_count returns the live client count (port of
// ClientManager::count).
client_manager_count :: proc(m: ^Client_Manager) -> int {
	return len(m.clients)
}

// client_manager_process_pending_inputs pumps every client until none
// has input left (port of ClientManager::process_pending_inputs).
// Index-based: processing may mutate the client list. Calls STUBBED
// client procs unless no client exists.
client_manager_process_pending_inputs :: proc(m: ^Client_Manager) -> bool {
	processed := false
	for {
		had_input := false
		i := 0
		for i < len(m.clients) {
			if !client_is_ui_ok(m.clients[i]) {
				client_manager_remove_client(m, m.clients[i], false, -1)
				continue
			}
			got := client_process_pending_inputs(m.clients[i])
			had_input = got || had_input
			processed = processed || had_input
			i += 1
		}
		if !had_input {
			break
		}
	}
	return processed
}

// client_manager_has_pending_inputs reports whether any client holds
// unprocessed keys (port of ClientManager::has_pending_inputs). The
// per-client check is a field read (has_pending_inputs is
// !m_pending_keys.empty() in C++).
client_manager_has_pending_inputs :: proc(m: ^Client_Manager) -> bool {
	for c in m.clients {
		if len(c.pending_keys) > 0 {
			return true
		}
	}
	return false
}

// client_manager_remove_client moves a client to the trash, runs
// ClientClose, and exits it (port of ClientManager::remove_client).
// Removing an unknown client asserts trash membership and returns.
// Calls STUBBED hook procs.
client_manager_remove_client :: proc(m: ^Client_Manager, client: ^Client, graceful: bool, status: int) {
	idx := -1
	for c, i in m.clients {
		if c == client {
			idx = i
			break
		}
	}
	if idx == -1 {
		found := false
		for c in m.client_trash {
			if c == client {
				found = true
				break
			}
		}
		assert(found)
		return
	}
	append(&m.client_trash, client)
	ordered_remove(&m.clients, idx)

	ctx := &client.input_handler.ctx
	hooks := context_hooks(ctx)
	hook_manager_run_hook(hooks, .Client_Close, ctx.name, ctx)

	client.on_exit.call(client.on_exit.data, status)

	if !graceful && len(m.clients) == 0 {
		buffer_manager_backup_modified(buffer_manager_instance())
	}
}

// client_manager_get_free_window takes the cached window for buf, or
// builds a fresh window with default selections (port of
// ClientManager::get_free_window). Calls STUBBED window/selection
// procs on both paths.
client_manager_get_free_window :: proc(m: ^Client_Manager, buf: ^Buffer) -> Window_And_Selections {
	registered := false
	for b in buffer_manager_instance().buffers {
		if b == buf {
			registered = true
			break
		}
	}
	assert(registered)
	for i := len(m.free_windows) - 1; i >= 0; i -= 1 {
		if m.free_windows[i].window.buffer == buf {
			res := m.free_windows[i]
			ordered_remove(&m.free_windows, i)
			selection_list_update(&res.selections)
			return res
		}
	}
	return Window_And_Selections {
		window     = window_make(buf, m.allocator),
		selections = selection_list_make_single(buf, client_manager_default_selection(), buffer_timestamp(buf), m.allocator),
	}
}

// client_manager_add_free_window caches a window for reuse, or trashes
// it when its buffer is gone (port of
// ClientManager::add_free_window). Calls a STUBBED window proc on the
// cache path.
client_manager_add_free_window :: proc(m: ^Client_Manager, window: ^Window, selections: Selection_List) {
	known := false
	for b in buffer_manager_instance().buffers {
		if b == window.buffer {
			known = true
			break
		}
	}
	if !known {
		append(&m.window_trash, window)
		return
	}
	window_clear_display_buffer(window)
	// The C++ takes selections by value (deep vector copy); a header
	// copy would alias the caller's array and double-free it (ASan
	// heap-use-after-free via input_handler_destroy + clear).
	sel := selections
	cloned := selection_list_clone(&sel, m.allocator)
	append(&m.free_windows, Window_And_Selections{window = window, selections = cloned})
}

// client_manager_ensure_no_client_uses_buffer forgets buf in every
// client and drops cached windows on it through the WinClose hook
// (port of ClientManager::ensure_no_client_uses_buffer). Calls
// STUBBED context/window/selection procs unless no client exists and
// no cached window uses buf.
client_manager_ensure_no_client_uses_buffer :: proc(m: ^Client_Manager, buf: ^Buffer) {
	for c in m.clients {
		context_forget_buffer(&c.input_handler.ctx, buf)
	}
	removed := make([dynamic]Window_And_Selections, 0, context.temp_allocator)
	w := 0
	for i := 0; i < len(m.free_windows); i += 1 {
		if m.free_windows[i].window.buffer == buf {
			append(&removed, m.free_windows[i])
		} else {
			m.free_windows[w] = m.free_windows[i]
			w += 1
		}
	}
	resize(&m.free_windows, w)
	for i := 0; i < len(removed); i += 1 {
		window_run_hook_in_own_context(
			removed[i].window,
			.Win_Close,
			buffer_manager_buffer_name(buf),
			"",
		)
		append(&m.window_trash, removed[i].window)
		selection_list_destroy(&removed[i].selections)
	}
}

// client_manager_clear_window_trash destroys trashed windows (port of
// ClientManager::clear_window_trash). Calls STUBBED window procs
// unless the trash is empty.
client_manager_clear_window_trash :: proc(m: ^Client_Manager) {
	for w in m.window_trash {
		window_destroy(w)
	}
	clear(&m.window_trash)
}

// client_manager_clear_client_trash destroys trashed clients (port of
// ClientManager::clear_client_trash). Calls STUBBED client procs
// unless the trash is empty.
client_manager_clear_client_trash :: proc(m: ^Client_Manager) {
	for c in m.client_trash {
		client_destroy(c)
	}
	clear(&m.client_trash)
}

// client_manager_client_name_exists reports whether name is taken (port
// of ClientManager::client_name_exists).
client_manager_client_name_exists :: proc(m: ^Client_Manager, name: string) -> bool {
	return client_manager_get_client_ifp(m, name) != nil
}

// client_manager_get_client_ifp finds a client by name, or nil (port of
// ClientManager::get_client_ifp). Client names live in the input
// handler context; this only reads knot fields.
client_manager_get_client_ifp :: proc(m: ^Client_Manager, name: string) -> ^Client {
	for c in m.clients {
		if c.input_handler.ctx.name == name {
			return c
		}
	}
	return nil
}

// client_manager_get_client finds a client by name (port of
// ClientManager::get_client).
client_manager_get_client :: proc(
	m: ^Client_Manager,
	name: string,
) -> (
	client: ^Client,
	err: Client_Manager_Error,
) {
	if found := client_manager_get_client_ifp(m, name); found != nil {
		return found, .None
	}
	return nil, .No_Such_Client
}

// client_manager_redraw_clients redraws every client (port of
// ClientManager::redraw_clients). Calls STUBBED client procs unless
// no client exists.
client_manager_redraw_clients :: proc(m: ^Client_Manager) {
	for c in m.clients {
		client_redraw_ifn(c)
	}
}

// client_manager_complete_client_name completes a client name (port of
// ClientManager::complete_client_name). Candidates borrow the client
// names; free only the returned array.
client_manager_complete_client_name :: proc(
	m: ^Client_Manager,
	prefix: string,
	cursor_pos: Units_ByteCount = -1,
	allocator := context.allocator,
) -> Candidate_List {
	names := make([dynamic]string, 0, len(m.clients), context.temp_allocator)
	for c in m.clients {
		append(&names, c.input_handler.ctx.name)
	}
	return completion_complete(prefix, cursor_pos, names[:], allocator)
}

// Shared stubs: context_hooks and hook_manager_run_hook are also used by
// register_manager.odin (register modified hooks). They live here, in
// the alphabetically-first needing module, so they are defined once.


