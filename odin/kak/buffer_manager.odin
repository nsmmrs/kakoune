// Buffer manager ported from src/buffer_manager.{hh,cc}: the ordered
// buffer list plus the deletion trash.
//
// Buffers are owned heap objects (^Buffer): live ones in buffers,
// deleted ones in buffer_trash until buffer_manager_clear_trash. The
// manager never copies them.
package kak

// Buffer_Manager_Error reports buffer manager failures (port of the
// runtime_errors thrown by BufferManager).
Buffer_Manager_Error :: enum {
	None,
	Name_In_Use,
	No_Such_Buffer,
	Duplicate_Buffer,
	Locked,
	Removed_During_Creation,
}

// Buffer_Manager_Filter selects buffers (port of the
// FunctionRef<bool(Buffer&)> in get_buffer_matching).
Buffer_Manager_Filter :: #type proc(buf: ^Buffer) -> bool

// Buffer_Manager_Instance is the BufferManager singleton.
Buffer_Manager_Instance: Buffer_Manager

// buffer_manager_has_instance reports whether the singleton was
// initialized (port of Singleton::has_instance).
buffer_manager_has_instance := false

// buffer_manager_instance returns the singleton (port of
// Singleton::instance).
buffer_manager_instance :: proc() -> ^Buffer_Manager {
	assert(buffer_manager_has_instance)
	return &Buffer_Manager_Instance
}

// buffer_manager_instance_init initializes the singleton.
buffer_manager_instance_init :: proc(allocator := context.allocator) {
	Buffer_Manager_Instance = buffer_manager_make(allocator)
	buffer_manager_has_instance = true
}

// buffer_manager_make builds an empty buffer manager.
buffer_manager_make :: proc(allocator := context.allocator) -> Buffer_Manager {
	return Buffer_Manager {
		buffers      = make([dynamic]^Buffer, allocator),
		buffer_trash = make([dynamic]^Buffer, allocator),
		allocator    = allocator,
	}
}

// buffer_manager_destroy frees the manager (port of ~BufferManager):
// live buffers are unregistered and destroyed, trashed buffers are
// destroyed, and remaining clients are disconnected. Calls STUBBED
// buffer procs unless the manager is empty.
buffer_manager_destroy :: proc(m: ^Buffer_Manager) {
	buffers := m.buffers
	m.buffers = nil
	for buf in buffers {
		buffer_on_unregistered(buf)
		buffer_destroy(buf)
	}
	delete(buffers)
	for buf in m.buffer_trash {
		buffer_destroy(buf)
	}
	delete(m.buffer_trash)
	if client_manager_has_instance {
		client_manager_clear(client_manager_instance(), true)
	}
	m^ = Buffer_Manager{}
}

// buffer_manager_buffer_name mirrors C++ Buffer::name (the filename for
// file buffers, else the display name). It only reads knot fields so the
// manager stays testable; the coordinator may replace it with the buffer
// module's accessor at merge time.
buffer_manager_buffer_name :: proc(buf: ^Buffer) -> string {
	if .File in buf.flags {
		return buf.filename
	}
	return buf.display_name
}

// buffer_manager_is_modified mirrors C++ Buffer::is_modified. Same
// merge-time note as buffer_manager_buffer_name.
buffer_manager_is_modified :: proc(buf: ^Buffer) -> bool {
	return .File in buf.flags &&
		(buf.history_id != buf.last_save_history_id || len(buf.current_undo_group) > 0)
}

// buffer_manager_create registers a new buffer (port of
// BufferManager::create_buffer). Calls STUBBED buffer procs; only the
// duplicate-name check runs before them.
buffer_manager_create :: proc(
	m: ^Buffer_Manager,
	name: string,
	flags: Buffer_Flags,
	lines: Buffer_Lines,
	bom: Byte_Order_Mark,
	eolformat: Eol_Format,
	finaleol: Final_Eol,
	fs_status: File_Fs_Status,
) -> (
	buf: ^Buffer,
	err: Buffer_Manager_Error,
) {
	if buffer_manager_get_ifp(m, name) != nil {
		return nil, .Name_In_Use
	}
	buf = buffer_make(name, flags, lines[:], bom, eolformat, finaleol, fs_status, m.allocator)
	append(&m.buffers, buf)
	buffer_on_registered(buf)
	for trashed in m.buffer_trash {
		if trashed == buf {
			return buf, .Removed_During_Creation
		}
	}
	return buf, .None
}

// buffer_manager_delete moves a buffer to the trash (port of
// BufferManager::delete_buffer). Deleting an unknown buffer is a silent
// no-op (recursive delete). Calls STUBBED buffer procs except for the
// locked and unknown-buffer early outs.
buffer_manager_delete :: proc(m: ^Buffer_Manager, buf: ^Buffer) -> Buffer_Manager_Error {
	if .Locked in buf.flags {
		return .Locked
	}
	idx := -1
	for b, i in m.buffers {
		if b == buf {
			idx = i
			break
		}
	}
	if idx == -1 {
		return .None
	}
	append(&m.buffer_trash, buf)
	ordered_remove(&m.buffers, idx)
	if client_manager_has_instance {
		client_manager_ensure_no_client_uses_buffer(client_manager_instance(), buf)
	}
	buffer_on_unregistered(buf)
	return .None
}

// buffer_manager_count returns the live buffer count (port of
// BufferManager::count).
buffer_manager_count :: proc(m: ^Buffer_Manager) -> int {
	return len(m.buffers)
}

// buffer_manager_get_ifp finds a buffer by display name, or by resolved
// filename for file buffers (port of BufferManager::get_buffer_ifp).
// Returns nil when nothing matches.
buffer_manager_get_ifp :: proc(m: ^Buffer_Manager, name: string) -> ^Buffer {
	parsed := file_parse_filename(name, "", context.temp_allocator)
	filename, real_err := file_real_path(parsed, context.temp_allocator)
	if real_err != .None {
		filename = parsed
	}
	for buf in m.buffers {
		if buffer_manager_buffer_name(buf) == name ||
		   (.File in buf.flags && buf.filename == filename) {
			return buf
		}
	}
	return nil
}

// buffer_manager_get_buffer_ifp finds a buffer by display name, or by
// resolved filename for file buffers, in the singleton manager (C++
// BufferManager::instance().get_buffer_ifp, as called by Buffer::set_name
// in buffer.cc). Returns nil when nothing matches.
buffer_manager_get_buffer_ifp :: proc(name: string) -> ^Buffer {
	return buffer_manager_get_ifp(buffer_manager_instance(), name)
}

// buffer_manager_get finds a buffer by name (port of
// BufferManager::get_buffer).
buffer_manager_get :: proc(
	m: ^Buffer_Manager,
	name: string,
) -> (
	buf: ^Buffer,
	err: Buffer_Manager_Error,
) {
	if found := buffer_manager_get_ifp(m, name); found != nil {
		return found, .None
	}
	return nil, .No_Such_Buffer
}

// buffer_manager_get_matching_ifp returns the most recently used buffer
// matching filter, or nil (port of
// BufferManager::get_buffer_matching_ifp).
buffer_manager_get_matching_ifp :: proc(m: ^Buffer_Manager, filter: Buffer_Manager_Filter) -> ^Buffer {
	for i := len(m.buffers) - 1; i >= 0; i -= 1 {
		if filter(m.buffers[i]) {
			return m.buffers[i]
		}
	}
	return nil
}

// buffer_manager_get_matching returns the most recently used buffer
// matching filter (port of BufferManager::get_buffer_matching).
buffer_manager_get_matching :: proc(
	m: ^Buffer_Manager,
	filter: Buffer_Manager_Filter,
) -> (
	buf: ^Buffer,
	err: Buffer_Manager_Error,
) {
	if found := buffer_manager_get_matching_ifp(m, filter); found != nil {
		return found, .None
	}
	return nil, .No_Such_Buffer
}

// buffer_manager_make_latest moves a buffer to the back of the list
// (port of BufferManager::make_latest).
buffer_manager_make_latest :: proc(m: ^Buffer_Manager, buf: ^Buffer) {
	idx := -1
	for b, i in m.buffers {
		if b == buf {
			idx = i
			break
		}
	}
	assert(idx != -1)
	for i := idx; i < len(m.buffers) - 1; i += 1 {
		m.buffers[i] = m.buffers[i + 1]
	}
	m.buffers[len(m.buffers) - 1] = buf
}

// buffer_manager_arrange moves the named buffers to the front (or the
// back when to_back), preserving their order (port of
// BufferManager::arrange_buffers).
buffer_manager_arrange :: proc(
	m: ^Buffer_Manager,
	buffers: []string,
	to_back: bool,
) -> Buffer_Manager_Error {
	indices := make([dynamic]int, 0, len(buffers), context.temp_allocator)
	for name in buffers {
		parsed := file_parse_filename(name, "", context.temp_allocator)
		filename, real_err := file_real_path(parsed, context.temp_allocator)
		if real_err != .None {
			filename = parsed
		}
		idx := -1
		for b, i in m.buffers {
			if b.display_name == name || (.File in b.flags && b.filename == filename) {
				idx = i
				break
			}
		}
		if idx == -1 {
			return .No_Such_Buffer
		}
		for j in indices {
			if j == idx {
				return .Duplicate_Buffer
			}
		}
		append(&indices, idx)
	}
	res := make([dynamic]^Buffer, 0, len(m.buffers), m.allocator)
	for i in indices {
		append(&res, m.buffers[i])
	}
	for b, i in m.buffers {
		found := false
		for j in indices {
			if j == i {
				found = true
				break
			}
		}
		if !found {
			append(&res, b)
		}
	}
	if to_back && len(indices) > 0 {
		k := len(indices)
		head := make([]^Buffer, k, context.temp_allocator)
		copy(head, res[:k])
		for i := 0; i < len(res) - k; i += 1 {
			res[i] = res[i + k]
		}
		copy(res[len(res) - k:], head)
	}
	delete(m.buffers)
	m.buffers = res
	return .None
}

// buffer_manager_get_first returns the most recently used buffer,
// creating *scratch* when every buffer is a debug buffer (port of
// BufferManager::get_first_buffer). The creation path calls STUBBED
// buffer procs.
buffer_manager_get_first :: proc(m: ^Buffer_Manager) -> (buf: ^Buffer, err: Buffer_Manager_Error) {
	all_debug := true
	for b in m.buffers {
		if .Debug not_in b.flags {
			all_debug = false
			break
		}
	}
	if all_debug {
		lines := make(Buffer_Lines, 1, m.allocator)
		lines[0] = "\n"
		created, create_err := buffer_manager_create(
			m,
			"*scratch*",
			{},
			lines,
			.None,
			.Lf,
			.Present,
			File_Fs_Status{},
		)
		if create_err != .None {
			delete(lines)
			return nil, create_err
		}
		return created, .None
	}
	return m.buffers[len(m.buffers) - 1], .None
}

// buffer_manager_backup_modified writes backup files for modified,
// writable file buffers (port of
// BufferManager::backup_modified_buffers). Backup failures are ignored:
// both call sites are last-resort paths (client teardown, fatal
// signals) where the C++ would throw past the boundary.
buffer_manager_backup_modified :: proc(m: ^Buffer_Manager) {
	for buf in m.buffers {
		if .File in buf.flags && buffer_manager_is_modified(buf) && .Read_Only not_in buf.flags {
			_ = buffer_utils_write_to_backup_file(buf)
		}
	}
}

// buffer_manager_clear_trash destroys trashed buffers (port of
// BufferManager::clear_buffer_trash). Calls STUBBED buffer procs
// unless the trash is empty.
buffer_manager_clear_trash :: proc(m: ^Buffer_Manager) {
	for buf in m.buffer_trash {
		buffer_destroy(buf)
	}
	clear(&m.buffer_trash)
}

// buffer_utils_write_to_backup_file merged from the buffer_utils module;
// stub deleted.
