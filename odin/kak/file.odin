// Port of Kakoune's src/file.{hh,cc}: path translation, file I/O,
// directory helpers, fs status, and the buffered writer.
//
// Ownership: every proc returning `string` allocates with `allocator`
// (default `context.allocator`); the caller frees with `delete(s)`
// (deleting "" is safe). Borrowed views (file_tmpdir, file_homedir,
// file_split_path, list_files names, mapped views) must not be freed.
// NUL-terminated syscall arguments use `context.temp_allocator` scratch.
// file_mapped_file_open pairs with file_mapped_file_close (munmap);
// file_create_file/file_open_temp_file fds are closed by the caller.
//
// C++ exceptions become File_Error returns; C++ `operator==(timespec)`
// is the builtin `==`. Reuses hash_murmur3 (hash.odin),
// utils_clamp (utils.odin), Enum_Desc/enum_to_name/enum_from_name
// (enum.odin), and event_manager_* for the non-blocking write pump.
package kak

import "core:c"
import "core:strings"
import "core:time"
import posix "core:sys/posix"

// File_Error is the module error. Zero value `None` is success; the
// C++ threw file_access_error/runtime_error where these are returned.
File_Error :: enum {
	None,
	// open/stat-source failure: open, create, mkstemp, readlink.
	Open_Failed,
	// read(2) failed mid-stream.
	Read_Failed,
	// write(2) failed.
	Write_Failed,
	// fstat failed while opening a mapped file.
	Stat_Failed,
	// mkdir failed, or a path component exists but is not a directory.
	Mkdir_Failed,
	// mmap failed.
	Map_Failed,
	// Mapped file exceeds the C++ 32-bit int length limit.
	Too_Big,
	// Expected a file but found a directory.
	Is_Directory,
	// getcwd failed, the binary path is unknown, or the platform
	// branch is unimplemented.
	Unavailable,
}

// file_parse_filename expands a leading ~/ with the home directory and
// a leading %/ with buf_dir, else returns a copy (port of
// parse_filename; "%" alone also matches, like the C++ 2-byte prefix
// compare, but needs a non-empty buf_dir). Caller frees the result.
file_parse_filename :: proc(filename: string, buf_dir := "", allocator := context.allocator) -> string {
	prefix := filename[:min(2, len(filename))]
	if prefix == "~" || prefix == "~/" {
		return strings.concatenate({file_homedir(), filename[1:]}, allocator)
	}
	if (prefix == "%" || prefix == "%/") && len(buf_dir) > 0 {
		return strings.concatenate({buf_dir, filename[1:]}, allocator)
	}
	return strings.clone(filename, allocator)
}

// file_split_path splits path at the last '/'. The directory keeps its
// trailing slash; a bare name yields ("", name). Both are views into
// path (port of split_path).
file_split_path :: proc(path: string) -> (dir, file: string) {
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '/' {
			return path[:i + 1], path[i + 1:]
		}
	}
	return "", path
}

// file_real_path resolves filename like realpath, tolerating trailing
// non-existent components (which are appended to the resolved prefix)
// and unresolvable paths (which fall back to cwd/filename). Empty in,
// empty out. Caller frees the result.
//
// Deviation: the C++ ignores getcwd failure in the fallback (reading an
// uninitialized buffer); here it yields .Unavailable.
file_real_path :: proc(filename: string, allocator := context.allocator) -> (path: string, err: File_Error) {
	if len(filename) == 0 {
		return "", .None
	}
	existing := filename
	non_existing := ""
	for {
		existing_c := strings.clone_to_cstring(existing, context.temp_allocator)
		buf: [posix.PATH_MAX + 1]byte
		if res := posix.realpath(existing_c, raw_data(buf[:])); res != nil {
			resolved := string(res)
			if len(non_existing) == 0 {
				return strings.clone(resolved, allocator), .None
			}
			dir := resolved
			for len(dir) > 0 && dir[len(dir) - 1] == '/' {
				dir = dir[:len(dir) - 1]
			}
			return strings.concatenate({dir, "/", non_existing}, allocator), .None
		}
		// Last '/' skipping the final byte (C++ rbegin()+1).
		slash := -1
		for i := len(existing) - 2; i >= 0; i -= 1 {
			if existing[i] == '/' {
				slash = i
				break
			}
		}
		if slash == -1 {
			cwd_buf: [1024]byte
			cwd := posix.getcwd(([^]c.char)(raw_data(cwd_buf[:])), 1024)
			if cwd == nil {
				return "", .Unavailable
			}
			return strings.concatenate({string(cwd), "/", filename}, allocator), .None
		}
		// The C++ keeps the slash in `existing` (it.base()) and
		// restarts `non_existing` there, relative to filename.
		existing = existing[:slash + 1]
		non_existing = filename[slash + 1:]
	}
}

// file_compact_path makes filename relative to the cwd when it is
// inside it, else shortens a home-dir prefix to ~, else returns a copy
// (port of compact_path). Caller frees the result.
file_compact_path :: proc(filename: string, allocator := context.allocator) -> (path: string, err: File_Error) {
	real_filename, real_err := file_real_path(filename, context.temp_allocator)
	if real_err != .None {
		return "", real_err
	}
	cwd_buf: [1024]byte
	cwd := posix.getcwd(([^]c.char)(raw_data(cwd_buf[:])), 1024)
	if cwd == nil {
		return "", .Unavailable
	}
	real_cwd, cwd_err := file_real_path(string(cwd), context.temp_allocator)
	if cwd_err != .None {
		return "", cwd_err
	}
	real_cwd_slash := strings.concatenate({real_cwd, "/"}, context.temp_allocator)
	if strings.has_prefix(real_filename, real_cwd_slash) {
		return strings.clone(real_filename[len(real_cwd_slash):], allocator), .None
	}
	home := file_homedir()
	for len(home) > 0 && home[len(home) - 1] == '/' {
		home = home[:len(home) - 1]
	}
	if len(home) > 0 && strings.has_prefix(real_filename, home) {
		return strings.concatenate({"~", real_filename[len(home):]}, allocator), .None
	}
	return strings.clone(filename, allocator), .None
}

// file_tmpdir returns $TMPDIR without its final slash, or /tmp when
// unset or empty. Borrowed from the environment (port of tmpdir).
file_tmpdir :: proc() -> string {
	raw := posix.getenv("TMPDIR")
	if raw == nil {
		return "/tmp"
	}
	s := string(raw)
	if len(s) == 0 {
		return "/tmp"
	}
	if s[len(s) - 1] == '/' {
		return s[:len(s) - 1]
	}
	return s
}

// file_homedir returns $HOME, or the passwd entry when unset or empty.
// Borrowed (port of homedir).
//
// Deviation: the C++ dereferences the getpwuid result unconditionally;
// a missing entry yields "" here instead of crashing.
file_homedir :: proc() -> string {
	if raw := posix.getenv("HOME"); raw != nil && len(string(raw)) > 0 {
		return string(raw)
	}
	pw := posix.getpwuid(posix.geteuid())
	if pw == nil || pw.pw_dir == nil {
		return ""
	}
	return string(pw.pw_dir)
}

// file_get_kak_binary_path returns the current executable path (Linux:
// /proc/self/exe). Caller frees the result.
file_get_kak_binary_path :: proc(allocator := context.allocator) -> (path: string, err: File_Error) {
	when ODIN_OS == .Linux {
		buf: [2048]byte
		res := posix.readlink("/proc/self/exe", raw_data(buf[:]), 2048)
		if res != -1 && res < 2048 {
			return strings.clone(string(buf[:int(res)]), allocator), .None
		}
		return "", .Unavailable
	} else {
		return "", .Unavailable
	}
}

// file_fd_readable polls whether fd has data to read (zero-timeout
// select, port of fd_readable). Out-of-range fds report false (raw
// FD_SET would be undefined behavior in C++).
file_fd_readable :: proc(fd: int) -> bool {
	assert(fd >= 0)
	if fd >= posix.FD_SETSIZE {
		return false
	}
	rfds: posix.fd_set
	posix.FD_ZERO(&rfds)
	posix.FD_SET(posix.FD(fd), &rfds)
	tv := posix.timeval{}
	return posix.select(c.int(fd + 1), &rfds, nil, nil, &tv) == 1
}

// file_fd_writable polls whether fd accepts a write (port of
// fd_writable; same out-of-range rule as file_fd_readable).
file_fd_writable :: proc(fd: int) -> bool {
	assert(fd >= 0)
	if fd >= posix.FD_SETSIZE {
		return false
	}
	wfds: posix.fd_set
	posix.FD_ZERO(&wfds)
	posix.FD_SET(posix.FD(fd), &wfds)
	tv := posix.timeval{}
	return posix.select(c.int(fd + 1), nil, &wfds, nil, &tv) == 1
}

// file_read_fd reads fd to EOF; text mode strips '\r' bytes (port of
// read_fd). Caller frees the result.
file_read_fd :: proc(fd: int, text := false, allocator := context.allocator) -> (content: string, err: File_Error) {
	b := strings.builder_make(allocator)
	buf: [256]byte
	for {
		n := posix.read(posix.FD(fd), raw_data(buf[:]), 256)
		if n == 0 {
			break
		}
		if n < 0 {
			strings.builder_destroy(&b)
			return "", .Read_Failed
		}
		chunk := string(buf[:int(n)])
		if text {
			start := 0
			for i := 0; i < len(chunk); i += 1 {
				if chunk[i] == '\r' {
					strings.write_string(&b, chunk[start:i])
					start = i + 1
				}
			}
			strings.write_string(&b, chunk[start:])
		} else {
			strings.write_string(&b, chunk)
		}
	}
	return strings.to_string(b), .None
}

// file_read_file opens filename read-only and reads it (port of
// read_file). Caller frees the result.
file_read_file :: proc(filename: string, text := false, allocator := context.allocator) -> (content: string, err: File_Error) {
	cname := strings.clone_to_cstring(filename, context.temp_allocator)
	raw := posix.open(cname, posix.O_Flags{})
	if raw == -1 {
		return "", .Open_Failed
	}
	defer posix.close(raw)
	return file_read_fd(int(raw), text, allocator)
}

// file_write writes all of data to fd. Non-atomic mode (the default)
// marks the fd non-blocking and pumps urgent events on EAGAIN when a
// manager is installed; atomic mode blocks (port of write<atomic>;
// the C++ template bit becomes a runtime flag with identical
// semantics). Flags are always restored.
//
// Deviation: the C++ truncates the length to 32-bit int; here the full
// length is written.
file_write :: proc(fd: int, data: string, atomic := false) -> File_Error {
	flags := posix.fcntl(posix.FD(fd), .GETFL)
	if !atomic && event_manager_has_instance() {
		posix.fcntl(posix.FD(fd), .SETFL, flags | posix.O_NONBLOCK)
	}
	defer posix.fcntl(posix.FD(fd), .SETFL, flags)

	buf := transmute([]byte)(data)
	total := len(data)
	pos := 0
	for pos < total {
		n := posix.write(posix.FD(fd), raw_data(buf[pos:]), c.size_t(total - pos))
		if n != -1 {
			pos += int(n)
		} else if posix.errno() == .EAGAIN && !atomic && event_manager_has_instance() {
			event_manager_handle_next_events(.Urgent, time.Duration(0))
		} else {
			return .Write_Failed
		}
	}
	return .None
}

// file_write_to_file creates/truncates filename (mode 0644) and writes
// data with a non-atomic write (port of write_to_file).
file_write_to_file :: proc(filename: string, data: string) -> File_Error {
	fd, create_err := file_create_file(filename)
	if create_err != .None {
		return create_err
	}
	defer posix.close(posix.FD(fd))
	return file_write(fd, data)
}

// file_create_file opens filename O_CREAT|O_WRONLY|O_TRUNC (mode 0644,
// plus O_NONBLOCK when a manager is installed), retrying through
// urgent-event polls on ENXIO (FIFO with no reader yet). Returns the
// open fd (port of create_file); the caller closes it.
file_create_file :: proc(filename: string) -> (fd: int, err: File_Error) {
	cname := strings.clone_to_cstring(filename, context.temp_allocator)
	flags: posix.O_Flags = {.CREAT, .WRONLY, .TRUNC}
	if event_manager_has_instance() {
		flags += {.NONBLOCK}
	}
	for {
		raw := posix.open(cname, flags, posix.mode_t{.IRUSR, .IWUSR, .IRGRP, .IROTH})
		if raw != -1 {
			return int(raw), .None
		}
		if posix.errno() == .ENXIO && event_manager_has_instance() {
			event_manager_handle_next_events(.Urgent, time.Millisecond)
		} else {
			return -1, .Open_Failed
		}
	}
}

// file_open_temp_file creates a mkstemp file ".<base>.kak.XXXXXX" next
// to filename's resolved location and returns its fd and path (port of
// open_temp_file; the C++ buffer overload's out-param becomes the owned
// return). Caller closes the fd, deletes the path, and unlinks it.
file_open_temp_file :: proc(filename: string, allocator := context.allocator) -> (fd: int, path: string, err: File_Error) {
	real, real_err := file_real_path(filename, context.temp_allocator)
	if real_err != .None {
		return -1, "", real_err
	}
	dir, base := file_split_path(real)
	template: string
	if len(dir) == 0 {
		template = strings.concatenate({".", base, ".kak.XXXXXX"}, context.temp_allocator)
	} else {
		// dir keeps its trailing slash, so this formats the same
		// doubled slash as the C++ "{}/.{}.kak.XXXXXX".
		template = strings.concatenate({dir, "/.", base, ".kak.XXXXXX"}, context.temp_allocator)
	}
	if len(template) + 1 > posix.PATH_MAX {
		return -1, "", .Open_Failed
	}
	buf: [posix.PATH_MAX]byte
	copy(buf[:], template)
	buf[len(template)] = 0
	// mkstemp edits the XXXXXX suffix in place, keeping the length.
	raw := posix.mkstemp(cstring(raw_data(buf[:])))
	if raw == -1 {
		return -1, "", .Open_Failed
	}
	return int(raw), strings.clone(string(buf[:len(template)]), allocator), .None
}

// File_Mapped_File is a read-only private mmap of a file (port of
// MappedFile). Open pairs with close; empty files map to empty data
// with the fstat timestamp kept.
File_Mapped_File :: struct {
	data:     []byte,
	modified: posix.timespec,
}

// file_mapped_file_open mmaps filename read-only. Directories yield
// .Is_Directory; a zero-size file succeeds with empty data.
//
// Deviation: the C++ ignores fstat failure (reading a garbage stat);
// here it yields .Stat_Failed.
file_mapped_file_open :: proc(filename: string) -> (mapped: File_Mapped_File, err: File_Error) {
	cname := strings.clone_to_cstring(filename, context.temp_allocator)
	raw := posix.open(cname, posix.O_Flags{.NONBLOCK})
	if raw == -1 {
		return {}, .Open_Failed
	}
	defer posix.close(raw)
	st: posix.stat_t
	if posix.fstat(raw, &st) != .OK {
		return {}, .Stat_Failed
	}
	if posix.S_ISDIR(st.st_mode) {
		return {}, .Is_Directory
	}
	if st.st_size == 0 {
		return File_Mapped_File{{}, st.st_mtim}, .None
	}
	addr := posix.mmap(nil, c.size_t(st.st_size), posix.Prot_Flags{.READ}, posix.Map_Flags{.PRIVATE}, raw, 0)
	if addr == posix.MAP_FAILED {
		return {}, .Map_Failed
	}
	return File_Mapped_File{([^]byte)(addr)[:int(st.st_size)], st.st_mtim}, .None
}

// file_mapped_file_close unmaps the file. Do not reslice data before
// closing: munmap needs the original base and length.
file_mapped_file_close :: proc(m: ^File_Mapped_File) {
	if len(m.data) > 0 {
		posix.munmap(raw_data(m.data), c.size_t(len(m.data)))
		m.data = {}
	}
}

// file_mapped_file_bytes views the mapping as bytes.
file_mapped_file_bytes :: proc(m: File_Mapped_File) -> []byte {
	return m.data
}

// file_mapped_file_view views the mapping as a string (port of the
// StringView conversion, including its 32-bit int length limit).
file_mapped_file_view :: proc(m: File_Mapped_File) -> (view: string, err: File_Error) {
	if len(m.data) > int(max(i32)) {
		return "", .Too_Big
	}
	return string(m.data), .None
}

// File_Write_Method selects the file-saving strategy (port of
// WriteMethod).
File_Write_Method :: enum {
	Overwrite,
	Replace,
}

// file_write_method_descs is the canonical name table (port of the
// enum_desc overload), shared by the to/from-name helpers.
file_write_method_descs := [2]Enum_Desc(File_Write_Method){{.Overwrite, "overwrite"}, {.Replace, "replace"}}

// file_write_method_to_name maps a method to its canonical name.
file_write_method_to_name :: proc(method: File_Write_Method) -> (name: string, ok: bool) {
	return enum_to_name(file_write_method_descs[:], method)
}

// file_write_method_from_name parses a canonical method name.
file_write_method_from_name :: proc(name: string) -> (method: File_Write_Method, ok: bool) {
	return enum_from_name(file_write_method_descs[:], name)
}

// file_find_file searches filename: absolute paths and ~/ paths are
// stated directly, otherwise each of paths (run through
// file_parse_filename with buf_dir) is tried in order, returning the
// first regular file. "" means not found (port of find_file); the
// caller deletes non-empty results.
file_find_file :: proc(filename: string, buf_dir: string, paths: []string, allocator := context.allocator) -> string {
	st: posix.stat_t
	if len(filename) > 0 && filename[0] == '/' {
		cname := strings.clone_to_cstring(filename, context.temp_allocator)
		if posix.stat(cname, &st) == .OK && posix.S_ISREG(st.st_mode) {
			return strings.clone(filename, allocator)
		}
		return ""
	}
	if strings.has_prefix(filename, "~/") {
		candidate := strings.concatenate({file_homedir(), filename[1:]}, context.temp_allocator)
		cname := strings.clone_to_cstring(candidate, context.temp_allocator)
		if posix.stat(cname, &st) == .OK && posix.S_ISREG(st.st_mode) {
			return strings.clone(candidate, allocator)
		}
		return ""
	}
	for p in paths {
		candidate := file_parse_filename(p, buf_dir, context.temp_allocator)
		if len(candidate) > 0 && candidate[len(candidate) - 1] != '/' {
			candidate = strings.concatenate({candidate, "/"}, context.temp_allocator)
		}
		candidate = strings.concatenate({candidate, filename}, context.temp_allocator)
		cname := strings.clone_to_cstring(candidate, context.temp_allocator)
		if posix.stat(cname, &st) == .OK && posix.S_ISREG(st.st_mode) {
			return strings.clone(candidate, allocator)
		}
	}
	return ""
}

// file_exists reports whether filename stats (port of file_exists).
file_exists :: proc(filename: string) -> bool {
	cname := strings.clone_to_cstring(filename, context.temp_allocator)
	st: posix.stat_t
	return posix.stat(cname, &st) == .OK
}

// file_regular_file_exists reports whether filename stats and is a
// regular file (port of regular_file_exists).
file_regular_file_exists :: proc(filename: string) -> bool {
	cname := strings.clone_to_cstring(filename, context.temp_allocator)
	st: posix.stat_t
	if posix.stat(cname, &st) != .OK {
		return false
	}
	return posix.S_ISREG(st.st_mode)
}

// File_List_Files_Callback receives one directory entry: the bare name
// (with a trailing '/' for subdirectories) and its stat. The name is
// scratch, valid only for the call (the C++ aliases its format buffer
// the same way); copy to retain.
File_List_Files_Callback :: #type proc(name: string, st: posix.stat_t)

// file_list_files calls callback for each entry of dirname ("./" when
// empty), skipping unstatable names. An unopenable directory is a
// silent no-op, like the C++ (port of list_files).
file_list_files :: proc(dirname: string, callback: File_List_Files_Callback) {
	path: cstring
	if len(dirname) == 0 {
		path = "./"
	} else {
		path = strings.clone_to_cstring(dirname, context.temp_allocator)
	}
	dir := posix.opendir(path)
	if dir == nil {
		return
	}
	defer posix.closedir(dir)
	for {
		entry := posix.readdir(dir)
		if entry == nil {
			break
		}
		name := string(cstring(&entry.d_name[0]))
		if len(name) == 0 {
			continue
		}
		joined: string
		if len(dirname) == 0 || dirname[len(dirname) - 1] == '/' {
			joined = strings.concatenate({dirname, name}, context.temp_allocator)
		} else {
			joined = strings.concatenate({dirname, "/", name}, context.temp_allocator)
		}
		cjoined := strings.clone_to_cstring(joined, context.temp_allocator)
		st: posix.stat_t
		if posix.stat(cjoined, &st) != .OK {
			continue
		}
		if posix.S_ISDIR(st.st_mode) {
			callback(strings.concatenate({name, "/"}, context.temp_allocator), st)
		} else {
			callback(name, st)
		}
	}
}

// file_make_directory creates dir and missing parents (port of
// make_directory; mode passes to mkdir with umask(0) like the C++).
file_make_directory :: proc(dir: string, mode: posix.mode_t) -> File_Error {
	i := 0
	for i < len(dir) {
		j := i + 1
		for j < len(dir) && dir[j] != '/' {
			j += 1
		}
		prefix := dir[:j]
		cname := strings.clone_to_cstring(prefix, context.temp_allocator)
		st: posix.stat_t
		if posix.stat(cname, &st) == .OK {
			if !posix.S_ISDIR(st.st_mode) {
				return .Mkdir_Failed
			}
		} else {
			old := posix.umask(posix.mode_t{})
			created := posix.mkdir(cname, mode)
			posix.umask(old)
			if created != .OK {
				return .Mkdir_Failed
			}
		}
		if j >= len(dir) {
			break
		}
		i = j
	}
	return .None
}

// File_Invalid_Time marks a missing file's timestamp (port of
// InvalidTime; the C++ timespec operator== is the builtin ==).
File_Invalid_Time :: posix.timespec{tv_sec = -1, tv_nsec = -1}

// File_Fs_Status snapshots a file's mtime, size, and content hash (port
// of FsStatus).
File_Fs_Status :: struct {
	timestamp: posix.timespec,
	file_size: int,
	hash:      uint,
}

// file_get_fs_timestamp stats filename's mtime, or File_Invalid_Time
// when it does not stat (port of get_fs_timestamp).
file_get_fs_timestamp :: proc(filename: string) -> posix.timespec {
	cname := strings.clone_to_cstring(filename, context.temp_allocator)
	st: posix.stat_t
	if posix.stat(cname, &st) != .OK {
		return File_Invalid_Time
	}
	return st.st_mtim
}

// file_get_fs_status mmaps filename and snapshots mtime, size, and the
// murmur3 content hash (port of get_fs_status).
file_get_fs_status :: proc(filename: string) -> (status: File_Fs_Status, err: File_Error) {
	mapped, map_err := file_mapped_file_open(filename)
	if map_err != .None {
		return {}, map_err
	}
	defer file_mapped_file_close(&mapped)
	return File_Fs_Status{timestamp = mapped.modified, file_size = len(mapped.data), hash = hash_murmur3(string(mapped.data))}, .None
}

// File_Buffered_Writer batches small writes into Buf_Size-byte flushes
// (port of BufferedWriter<atomic, buffer_size>; the atomic template bit
// is the runtime `atomic` field). There is no destructor: flush
// explicitly (defer file_buffered_writer_flush) before closing the fd.
File_Buffered_Writer :: struct($Buf_Size: int) {
	fd:     int,
	atomic: bool,
	pos:    int,
	buffer: [Buf_Size]byte,
}

// file_buffered_writer_make returns a 4096-byte writer on fd (the C++
// default buffer size).
file_buffered_writer_make :: proc(fd: int, atomic := false) -> File_Buffered_Writer(4096) {
	return {fd = fd, atomic = atomic}
}

// file_buffered_writer_write buffers data, flushing full blocks (port
// of BufferedWriter::write).
file_buffered_writer_write :: proc(w: ^File_Buffered_Writer($N), data: string) -> File_Error {
	rest := data
	for len(rest) > 0 {
		write_len := utils_clamp(len(rest), 0, N - w.pos)
		copy(w.buffer[w.pos:], rest[:write_len])
		w.pos += write_len
		if w.pos == N {
			if err := file_buffered_writer_flush(w); err != .None {
				return err
			}
		}
		rest = rest[write_len:]
	}
	return .None
}

// file_buffered_writer_flush writes the buffered bytes (port of
// BufferedWriter::flush).
file_buffered_writer_flush :: proc(w: ^File_Buffered_Writer($N)) -> File_Error {
	if err := file_write(w.fd, string(w.buffer[:w.pos]), w.atomic); err != .None {
		return err
	}
	w.pos = 0
	return .None
}
