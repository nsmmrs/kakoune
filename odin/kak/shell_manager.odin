// Port of Kakoune's src/shell_manager.{hh,cc}: run %sh{...} expansions,
// spawn shells with pipes, and serve the kak_* dynamic environment
// variables (ShellManager::eval/spawn/get_val/complete_env_var).
//
// Ownership: the manager borrows its builtin descriptors (C++
// ConstArrayView parity; the table lives with the application, in C++
// main.cc) and owns only the resolved shell path; release with
// shell_manager_destroy. Returned strings and string lists are owned in
// the passed allocator. Shell pipes (Shell) are owned descriptors;
// release with shell_manager_shell_close. Eval results own two strings;
// release with shell_manager_eval_result_free.
//
// Allocators: every allocating proc takes `allocator` and scopes
// context.allocator to it on entry, so ambient growth (append, builder
// writes) lands in the same allocator the caller frees with. The env
// reference scan (regex, iterator, offset list) runs entirely on the
// temp allocator; only the finished entries use the passed allocator.
//
// Deviations from the C++:
//   * eval is synchronous (poll loop) instead of driving the UI event
//     loop with FDWatchers; there is no busy indicator, no SIGCHLD
//     masking, and no cancellation. Exit status and stderr come back
//     in Shell_Manager_Eval_Result; the %sh wrapper keeps stdout only.
//   * The poll loop uses a 100ms timeout: a child can close its
//     outputs just before it becomes waitable, after which a
//     fifo-only poll set would never wake. Output and fifo activity
//     still wake immediately; the timeout only rechecks the child.
//   * Debug/profile logging is omitted: the debug sink is still a STUB
//     in this package, so there is nowhere to send it.
//   * The constructor's PATH prepend (<bindir>/../libexec/kak) is
//     skipped: the binary-path helper is unmerged and no kak binary
//     exists in the port yet.
//   * Unknown %val names expand to nothing instead of raising
//     runtime_error("no such variable"): the expansion signature has
//     no error channel. shell_manager_get_val_checked reports it.
//
// Integration note for the future odin/cmd main (C++ main.cc parity):
// ignore SIGPIPE (main.cc installs an empty handler). Without it,
// feeding stdin to a child that exits early kills the process instead
// of failing the write with EPIPE, which the stdin pump already
// handles by closing stdin and carrying on.
package kak

import "core:c"
import "core:mem"
import "core:os"
import "core:strings"
import posix "core:sys/posix"

// Shell_Manager_Error ports the C++ failure outcomes (runtime_error
// throws and the "no such variable" lookup miss). None is success.
Shell_Manager_Error :: enum {
	None,
	// get_val name matches no builtin (C++ throws "no such variable").
	No_Such_Variable,
	// No POSIX sh found (C++ throws "unable to find a posix shell").
	No_Shell,
	// KAKOUNE_POSIX_SHELL is set but not an executable file.
	Bad_Shell,
	// Pipe/fork/exec setup, fifo setup, or environment snapshot failed.
	Spawn_Failed,
}

// shell_manager_error_message describes err with a static string.
shell_manager_error_message :: proc(err: Shell_Manager_Error) -> string {
	switch err {
	case .None:
		return "none"
	case .No_Such_Variable:
		return "no such variable"
	case .No_Shell:
		return "unable to find a posix shell"
	case .Bad_Shell:
		return "KAKOUNE_POSIX_SHELL is not executable"
	case .Spawn_Failed:
		return "unable to spawn shell"
	}
	unreachable()
}

// shell_manager_ENV_REF_PATTERN is the C++ generate_env regex: every
// kak_<name> / kak_quoted_<name> word in the command line or params
// becomes an environment entry for the child.
shell_manager_ENV_REF_PATTERN :: `\bkak_(quoted_)?(\w+)\b`

// shell_manager_singleton is the C++ Singleton<ShellManager> instance.
// Initialise once with shell_manager_init_singleton before use.
shell_manager_singleton: Shell_Manager

// shell_manager_instance returns the singleton (C++ Singleton::instance).
shell_manager_instance :: proc() -> ^Shell_Manager {
	return &shell_manager_singleton
}

// shell_manager_init_singleton builds the singleton over the borrowed
// builtin descriptors (C++ ShellManager ctor argument).
shell_manager_init_singleton :: proc(builtin_env_vars: []Env_Var_Desc, allocator := context.allocator) -> Shell_Manager_Error {
	m, err := shell_manager_make(builtin_env_vars, allocator)
	if err != .None {
		return err
	}
	shell_manager_singleton = m
	return .None
}

// shell_manager_make_with_shell builds a manager over an explicit shell
// path, which must be executable. Borrows builtin_env_vars; owns the
// cloned shell path. Tests use this to avoid the environment.
shell_manager_make_with_shell :: proc(builtin_env_vars: []Env_Var_Desc, shell_path: string, allocator := context.allocator) -> (Shell_Manager, Shell_Manager_Error) {
	context.allocator = allocator
	if !shell_manager_is_executable(shell_path) {
		return {}, .Bad_Shell
	}
	return Shell_Manager{shell = strings.clone(shell_path, allocator), env_vars = builtin_env_vars, allocator = allocator}, .None
}

// shell_manager_make resolves the POSIX shell: $KAKOUNE_POSIX_SHELL when
// set (it must be executable), else the first executable sh on _CS_PATH
// (C++ ctor). Borrows builtin_env_vars; owns the shell path.
shell_manager_make :: proc(builtin_env_vars: []Env_Var_Desc, allocator := context.allocator) -> (Shell_Manager, Shell_Manager_Error) {
	context.allocator = allocator
	if raw := posix.getenv("KAKOUNE_POSIX_SHELL"); raw != nil {
		return shell_manager_make_with_shell(builtin_env_vars, string(raw), allocator)
	}
	search_path := shell_manager_confstr_path(allocator)
	defer delete(search_path, allocator)
	found, ok := shell_manager_find_shell(search_path, allocator)
	if !ok {
		return {}, .No_Shell
	}
	defer delete(found, allocator)
	return shell_manager_make_with_shell(builtin_env_vars, found, allocator)
}

// shell_manager_destroy releases the owned shell path. The builtin
// descriptors are borrowed and stay alive with their owner.
shell_manager_destroy :: proc(m: ^Shell_Manager) {
	delete(m.shell, m.allocator)
	m^ = {}
}

// shell_manager_is_executable reports whether path names a regular file
// with any execute bit set (the C++ ctor's is_executable lambda).
shell_manager_is_executable :: proc(path: string) -> bool {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	st: posix.stat_t
	if posix.stat(cpath, &st) != .OK {
		return false
	}
	exec_bits := posix.mode_t{.IXUSR, .IXGRP, .IXOTH}
	return posix.S_ISREG(st.st_mode) && st.st_mode & exec_bits != posix.mode_t{}
}

// shell_manager_find_shell scans a colon-separated directory list for an
// executable sh (the C++ ctor's path loop). The result is owned.
shell_manager_find_shell :: proc(path_list: string, allocator := context.allocator) -> (string, bool) {
	context.allocator = allocator
	rest := path_list
	for len(rest) > 0 {
		sep := 0
		for sep < len(rest) && rest[sep] != ':' {
			sep += 1
		}
		dir := rest[:sep]
		rest = rest[min(sep + 1, len(rest)):]
		if len(dir) == 0 {
			continue
		}
		candidate := strings.concatenate({dir, "/sh"}, context.temp_allocator)
		if shell_manager_is_executable(candidate) {
			return strings.clone(candidate, allocator), true
		}
	}
	return "", false
}

// shell_manager_confstr_path returns the _CS_PATH directory list, or
// "/bin:/usr/bin" when confstr is unavailable (C++ #else branch).
// The result is owned.
shell_manager_confstr_path :: proc(allocator := context.allocator) -> string {
	context.allocator = allocator
	size := posix.confstr(posix.CS._PATH, nil, 0)
	if size <= 1 {
		return strings.clone("/bin:/usr/bin", allocator)
	}
	buf := make([]byte, int(size), context.temp_allocator)
	got := posix.confstr(posix.CS._PATH, raw_data(buf), c.size_t(size))
	if got <= 1 {
		return strings.clone("/bin:/usr/bin", allocator)
	}
	n := clamp(int(got) - 1, 0, int(size) - 1)
	return strings.clone(string(buf[:n]), allocator)
}

// shell_manager_get_val_from looks name up in m's builtins (C++
// ShellManager::get_val): exact match, or prefix match for prefix
// descriptors. Values are owned; unknown names return nil plus
// .No_Such_Variable.
shell_manager_get_val_from :: proc(m: ^Shell_Manager, name: string, ctx: ^Context, allocator := context.allocator) -> ([dynamic]string, Shell_Manager_Error) {
	context.allocator = allocator
	for desc in m.env_vars {
		if desc.func == nil {
			continue
		}
		matched := name == desc.str
		if desc.prefix {
			matched = string_utils_prefix_match(name, desc.str)
		}
		if matched {
			return desc.func(name, ctx, allocator), .None
		}
	}
	return nil, .No_Such_Variable
}

// shell_manager_get_val_checked is shell_manager_get_val_from on the
// singleton.
shell_manager_get_val_checked :: proc(name: string, ctx: ^Context, allocator := context.allocator) -> ([dynamic]string, Shell_Manager_Error) {
	return shell_manager_get_val_from(shell_manager_instance(), name, ctx, allocator)
}

// shell_manager_get_val serves %val{...} expansion (C++
// ShellManager::get_val). Unknown names expand to nothing (the C++
// throws runtime_error, which has no channel in this signature); use
// shell_manager_get_val_checked to tell them apart.
shell_manager_get_val :: proc(name: string, ctx: ^Context, allocator := context.allocator) -> [dynamic]string {
	vals, err := shell_manager_get_val_checked(name, ctx, allocator)
	if err != .None {
		return nil
	}
	return vals
}

// shell_manager_complete_env_var_from completes a %val{...} name over
// m's builtin descriptors (C++ ShellManager::complete_env_var, which
// copies matches into the result). Candidates are owned.
shell_manager_complete_env_var_from :: proc(m: ^Shell_Manager, prefix: string, cursor_pos: Units_ByteCount, allocator := context.allocator) -> Candidate_List {
	context.allocator = allocator
	names := make([]string, len(m.env_vars), context.temp_allocator)
	for desc, i in m.env_vars {
		names[i] = desc.str
	}
	// completion_complete borrows the container; clone so the caller
	// owns every candidate.
	res := completion_complete(prefix, cursor_pos, names, allocator)
	for i in 0 ..< len(res) {
		res[i] = strings.clone(res[i], allocator)
	}
	return res
}

// shell_manager_complete_env_var is
// shell_manager_complete_env_var_from on the singleton.
shell_manager_complete_env_var :: proc(prefix: string, cursor_pos: Units_ByteCount, allocator := context.allocator) -> Candidate_List {
	return shell_manager_complete_env_var_from(shell_manager_instance(), prefix, cursor_pos, allocator)
}

// Shell_Manager_Env_Ref is one kak_<name> reference found in a command
// line or param: offsets into the borrowed text plus whether the
// quoted_ prefix was present (regex groups 0/2/1).
Shell_Manager_Env_Ref :: struct {
	text:                 string,
	full_begin, full_end: int,
	name_begin, name_end: int,
	quoted:               bool,
}

// shell_manager_generate_env builds the kak_* environment entries for a
// command line plus params (C++ generate_env): every kak_<name> word
// gains a kak_<name>=<value> entry, shell-quoted for kak_quoted_<name>.
// Values come from the fifo paths, the shell context overrides, then
// the builtins; unknown names are skipped. Entries are owned.
shell_manager_generate_env :: proc(m: ^Shell_Manager, cmdline: string, params: []string, ctx: ^Context, shell_ctx: ^Shell_Context, fifos: ^Shell_Manager_Fifos, allocator := context.allocator) -> [dynamic]string {
	context.allocator = allocator
	env := make([dynamic]string, 0, allocator)
	refs := shell_manager_scan_env_refs(cmdline, params)
	for r in refs {
		full := r.text[r.full_begin:r.full_end]
		if shell_manager_env_has(env[:], full) {
			continue
		}
		name := r.text[r.name_begin:r.name_end]
		quoting := Option_types_Quoting.Raw
		if r.quoted {
			quoting = .Shell
		}
		value, ok := shell_manager_env_ref_value(m, name, quoting, ctx, shell_ctx, fifos, allocator)
		if !ok {
			continue
		}
		entry := strings.concatenate({full, "=", value}, allocator)
		delete(value, allocator)
		append(&env, entry)
	}
	return env
}

// shell_manager_scan_env_refs collects every kak_<name> reference in the
// command line and params (C++ generate_env's RegexIterator walks).
// Runs entirely on the temp allocator: the regex, the iterators, and
// the returned offsets are transient (offsets borrow the inputs).
shell_manager_scan_env_refs :: proc(cmdline: string, params: []string) -> [dynamic]Shell_Manager_Env_Ref {
	context.allocator = context.temp_allocator
	refs := make([dynamic]Shell_Manager_Env_Ref, 0, context.temp_allocator)
	re, _, re_err := regex_make(shell_manager_ENV_REF_PATTERN, {}, context.temp_allocator)
	if re_err != .None {
		return refs
	}
	defer regex_destroy(&re)
	shell_manager_collect_env_refs(cmdline, &re, &refs)
	for p in params {
		shell_manager_collect_env_refs(p, &re, &refs)
	}
	return refs
}

// shell_manager_collect_env_refs appends the kak_<name> references of
// one string to refs (one C++ RegexIterator walk). Temp-scoped: refs
// and the iterator state never leave the temp allocator.
shell_manager_collect_env_refs :: proc(s: string, re: ^Regex, refs: ^[dynamic]Shell_Manager_Env_Ref) {
	context.allocator = context.temp_allocator
	it := regex_iterator_make(s, 0, len(s), re, {}, false, context.temp_allocator)
	defer regex_iterator_destroy(&it)
	for regex_iterator_next(&it) {
		whole := regex_match_results_get(&it.results, 0)
		name := regex_match_results_get(&it.results, 2)
		q := regex_match_results_get(&it.results, 1)
		if !name.matched || name.end <= name.begin {
			continue
		}
		append(
			refs,
			Shell_Manager_Env_Ref{
				text = s,
				full_begin = whole.begin,
				full_end = whole.end,
				name_begin = name.begin,
				name_end = name.end,
				quoted = q.matched,
			},
		)
	}
}

// shell_manager_env_has reports whether env already holds an entry for
// the full reference name (the C++ match_name dedup check).
shell_manager_env_has :: proc(env: []string, full_name: string) -> bool {
	for e in env {
		if len(e) > len(full_name) && e[:len(full_name)] == full_name && e[len(full_name)] == '=' {
			return true
		}
	}
	return false
}

// shell_manager_env_ref_value resolves one reference (C++ generate_env's
// get_value): fifo paths, shell context overrides, then builtins joined
// with spaces after quoting. The value is owned; ok is false when the
// name is unknown (C++ catches runtime_error and skips the entry).
shell_manager_env_ref_value :: proc(m: ^Shell_Manager, name: string, quoting: Option_types_Quoting, ctx: ^Context, shell_ctx: ^Shell_Context, fifos: ^Shell_Manager_Fifos, allocator: mem.Allocator) -> (string, bool) {
	context.allocator = allocator
	if name == "command_fifo" || name == "response_fifo" {
		if fifos == nil {
			return "", false
		}
		if name == "command_fifo" {
			return shell_manager_fifos_command_path(fifos, allocator), true
		}
		return shell_manager_fifos_response_path(fifos, allocator), true
	}
	if override, found := shell_ctx.env_vars[name]; found {
		return strings.clone(override, allocator), true
	}
	vals, verr := shell_manager_get_val_from(m, name, ctx, allocator)
	if verr != .None {
		return "", false
	}
	defer shell_manager_free_strings(&vals, allocator)
	quoted := make([]string, len(vals), context.temp_allocator)
	for v, i in vals {
		quoted[i] = option_types_apply_quoting(quoting, v, allocator)
	}
	out := string_utils_join_char(quoted, ' ', false, allocator)
	for q in quoted {
		delete(q, allocator)
	}
	return out, true
}

// shell_manager_free_strings releases a list of owned strings and the
// list itself. Scopes the allocator: dynamic arrays free through the
// ambient one.
shell_manager_free_strings :: proc(list: ^[dynamic]string, allocator: mem.Allocator) {
	context.allocator = allocator
	for s in list^ {
		delete(s, allocator)
	}
	delete(list^)
}

// Shell_Manager_Fifos ports C++ ShellManager::CommandFifos: the mkdtemp
// directory holding the command/response fifo pair, the held-open
// command fifo read end, and the accumulated partial command bytes.
// Release with shell_manager_fifos_destroy.
Shell_Manager_Fifos :: struct {
	base_dir:   string,
	command_fd: posix.FD,
	command:    [dynamic]byte,
	allocator:  mem.Allocator,
}

// shell_manager_cmdline_needs_fifos reports whether the command line or
// params mention the fifo variables, in which case eval creates the
// pair up front (C++ creates it lazily on first reference; the bare
// substring test is a superset of the regex matches, so no reference
// is ever missed and the only cost of a false positive is an unused
// directory that eval destroys again).
shell_manager_cmdline_needs_fifos :: proc(cmdline: string, params: []string) -> bool {
	if strings.contains(cmdline, "command_fifo") || strings.contains(cmdline, "response_fifo") {
		return true
	}
	for p in params {
		if strings.contains(p, "command_fifo") || strings.contains(p, "response_fifo") {
			return true
		}
	}
	return false
}

// shell_manager_fifos_make creates the fifo directory and pair and
// opens the command fifo read end (C++ CommandFifos ctor).
shell_manager_fifos_make :: proc(allocator := context.allocator) -> (Shell_Manager_Fifos, Shell_Manager_Error) {
	context.allocator = allocator
	f := Shell_Manager_Fifos{command_fd = posix.FD(-1), allocator = allocator}
	// mkdtemp needs a NUL-terminated mutable template; concatenate
	// returns an exact-length string, so stage through a +1 buffer.
	template := strings.concatenate({file_tmpdir(), "/kak-fifo.XXXXXX"}, allocator)
	defer delete(template, allocator)
	buf := make([]byte, len(template) + 1, allocator)
	defer delete(buf, allocator)
	copy(buf, template)
	if posix.mkdtemp(raw_data(buf)) == nil {
		return {}, .Spawn_Failed
	}
	f.base_dir = strings.clone(string(buf[:len(buf) - 1]), allocator)
	cmd_path := shell_manager_fifos_command_path(&f, context.temp_allocator)
	rsp_path := shell_manager_fifos_response_path(&f, context.temp_allocator)
	mode := posix.mode_t{.IRUSR, .IWUSR}
	if posix.mkfifo(strings.clone_to_cstring(cmd_path, context.temp_allocator), mode) != .OK ||
	   posix.mkfifo(strings.clone_to_cstring(rsp_path, context.temp_allocator), mode) != .OK {
		shell_manager_fifos_destroy(&f)
		return {}, .Spawn_Failed
	}
	shell_manager_fifos_reopen_command(&f)
	if f.command_fd == posix.FD(-1) {
		shell_manager_fifos_destroy(&f)
		return {}, .Spawn_Failed
	}
	f.command = make([dynamic]byte, 0, allocator)
	return f, .None
}

// shell_manager_fifos_destroy closes the read end, unlinks both fifos,
// and removes the directory (C++ CommandFifos dtor). Safe on partial
// state after a failed make.
shell_manager_fifos_destroy :: proc(f: ^Shell_Manager_Fifos) {
	context.allocator = f.allocator
	if f.command_fd != posix.FD(-1) {
		posix.close(f.command_fd)
		f.command_fd = posix.FD(-1)
	}
	cmd_path := shell_manager_fifos_command_path(f, context.temp_allocator)
	rsp_path := shell_manager_fifos_response_path(f, context.temp_allocator)
	posix.unlink(strings.clone_to_cstring(cmd_path, context.temp_allocator))
	posix.unlink(strings.clone_to_cstring(rsp_path, context.temp_allocator))
	posix.rmdir(strings.clone_to_cstring(f.base_dir, context.temp_allocator))
	delete(f.command)
	delete(f.base_dir, f.allocator)
	f.command = nil
	f.base_dir = ""
}

// shell_manager_fifos_command_path returns the owned command fifo path.
shell_manager_fifos_command_path :: proc(f: ^Shell_Manager_Fifos, allocator := context.allocator) -> string {
	return strings.concatenate({f.base_dir, "/command-fifo"}, allocator)
}

// shell_manager_fifos_response_path returns the owned response fifo path.
shell_manager_fifos_response_path :: proc(f: ^Shell_Manager_Fifos, allocator := context.allocator) -> string {
	return strings.concatenate({f.base_dir, "/response-fifo"}, allocator)
}

// shell_manager_fifos_reopen_command (re)opens the command fifo read
// end (C++ CommandFifos ctor open / reset_fd after each command).
// Leaves command_fd invalid on error.
shell_manager_fifos_reopen_command :: proc(f: ^Shell_Manager_Fifos) {
	if f.command_fd != posix.FD(-1) {
		posix.close(f.command_fd)
		f.command_fd = posix.FD(-1)
	}
	path := shell_manager_fifos_command_path(f, context.temp_allocator)
	fd := posix.open(strings.clone_to_cstring(path, context.temp_allocator), posix.O_Flags{.NONBLOCK})
	if fd != posix.FD(-1) {
		f.command_fd = fd
	}
}

// shell_manager_invalid_shell returns a Shell with no live descriptors
// (the knot Shell's bare zero value would hold fd 0, which must never
// be used directly, so error paths return this instead).
shell_manager_invalid_shell :: proc() -> Shell {
	return Shell{
		pid   = unique_descriptor_make(),
		stdin = unique_descriptor_make(),
		out   = unique_descriptor_make(),
		err   = unique_descriptor_make(),
	}
}

// shell_manager_shell_close releases a spawned shell: terminates and
// reaps the child, then closes every pipe (C++ Shell destruction).
shell_manager_shell_close :: proc(sh: ^Shell) {
	unique_descriptor_close(&sh.pid)
	unique_descriptor_close(&sh.stdin)
	unique_descriptor_close(&sh.out)
	unique_descriptor_close(&sh.err)
}

// shell_manager_close_pid terminates and reaps a spawned shell (C++
// closepid). Used as the Shell.pid closer.
shell_manager_close_pid :: proc(pid: int) {
	posix.kill(posix.pid_t(pid), .SIGTERM)
	status: c.int = 0
	for {
		r := posix.waitpid(posix.pid_t(pid), &status, posix.Wait_Flags{})
		if int(r) == pid {
			return
		}
		if int(r) < 0 && posix.errno() != .EINTR {
			return
		}
	}
}

// shell_manager_spawn runs cmdline with the generated kak_* environment
// and returns the live child with its pipes (C++ ShellManager::spawn).
// Like the C++, fifo variables are left out here (no fifo pair exists
// outside eval). Release the result with shell_manager_shell_close.
shell_manager_spawn :: proc(m: ^Shell_Manager, cmdline: string, ctx: ^Context, open_stdin: bool, shell_ctx: ^Shell_Context, allocator := context.allocator) -> (Shell, Shell_Manager_Error) {
	context.allocator = allocator
	kak_env := shell_manager_generate_env(m, cmdline, shell_ctx.params, ctx, shell_ctx, nil, allocator)
	defer shell_manager_free_strings(&kak_env, allocator)
	pid, stdin_fd, stdout_fd, stderr_fd, err := shell_manager_spawn_shell(m.shell, cmdline, shell_ctx.params, kak_env[:], open_stdin, allocator)
	if err != .None {
		return shell_manager_invalid_shell(), err
	}
	return Shell{
		pid   = unique_descriptor_make(int(pid), shell_manager_close_pid),
		stdin = unique_descriptor_make(int(stdin_fd), unique_descriptor_close_fd),
		out   = unique_descriptor_make(int(stdout_fd), unique_descriptor_close_fd),
		err   = unique_descriptor_make(int(stderr_fd), unique_descriptor_close_fd),
	}, .None
}

// shell_manager_make_pipe creates a pipe pair (C++ spawn_shell's
// make_pipe lambda).
shell_manager_make_pipe :: proc() -> (read_fd, write_fd: posix.FD, ok: bool) {
	fds: [2]posix.FD
	if posix.pipe(&fds) != .OK {
		return posix.FD(-1), posix.FD(-1), false
	}
	return fds[0], fds[1], true
}

// shell_manager_close_if_valid closes fd unless it is invalid.
shell_manager_close_if_valid :: proc(fd: posix.FD) {
	if fd != posix.FD(-1) {
		posix.close(fd)
	}
}

// shell_manager_dup_to dups oldfd onto newfd and closes oldfd, unless
// they are already the same (C++ spawn_shell's renamefd lambda).
shell_manager_dup_to :: proc(oldfd, newfd: posix.FD) {
	if oldfd != newfd {
		posix.dup2(oldfd, newfd)
		posix.close(oldfd)
	}
}

// shell_manager_build_argv builds the nil-terminated argv for
// `sh -c cmdline` (C++ spawn_shell's execparams): with params, the
// shell path becomes $0 followed by the params. Owns every entry;
// release with shell_manager_free_cstrings.
shell_manager_build_argv :: proc(shell_path, cmdline: string, params: []string, allocator: mem.Allocator) -> [dynamic]cstring {
	context.allocator = allocator
	argv := make([dynamic]cstring, 0, 4 + len(params), allocator)
	append(&argv, strings.clone_to_cstring("sh", allocator))
	append(&argv, strings.clone_to_cstring("-c", allocator))
	append(&argv, strings.clone_to_cstring(cmdline, allocator))
	if len(params) > 0 {
		append(&argv, strings.clone_to_cstring(shell_path, allocator))
		for p in params {
			append(&argv, strings.clone_to_cstring(p, allocator))
		}
	}
	append(&argv, nil)
	return argv
}

// shell_manager_build_envp builds the nil-terminated environment: the
// process environment plus the kak_* entries (C++ spawn_shell's
// envptrs). Owns every entry; release with
// shell_manager_free_cstrings. Reports false when the process
// environment cannot be snapshotted.
shell_manager_build_envp :: proc(kak_env: []string, allocator: mem.Allocator) -> ([dynamic]cstring, bool) {
	context.allocator = allocator
	base, os_err := os.environ(allocator)
	if os_err != nil {
		return nil, false
	}
	defer delete(base, allocator)
	envp := make([dynamic]cstring, 0, len(base) + len(kak_env) + 1, allocator)
	for e in base {
		append(&envp, strings.clone_to_cstring(e, allocator))
		delete(e, allocator)
	}
	for e in kak_env {
		append(&envp, strings.clone_to_cstring(e, allocator))
	}
	append(&envp, nil)
	return envp, true
}

// shell_manager_free_cstrings releases a nil-terminated cstring list
// and the list itself. Scopes the allocator: dynamic arrays free
// through the ambient one.
shell_manager_free_cstrings :: proc(list: ^[dynamic]cstring, allocator: mem.Allocator) {
	context.allocator = allocator
	for s in list^ {
		if s != nil {
			delete(s, allocator)
		}
	}
	delete(list^)
}

// shell_manager_spawn_shell forks and execs `shell -c cmdline` with the
// given params and extra environment (C++ anonymous spawn_shell). All
// strings are prepared before the fork; the child only dups fds and
// execs. Returns the parent-side pipe ends on success.
shell_manager_spawn_shell :: proc(shell_path: string, cmdline: string, params: []string, kak_env: []string, open_stdin: bool, allocator: mem.Allocator) -> (pid: posix.pid_t, stdin_fd, stdout_fd, stderr_fd: posix.FD, err: Shell_Manager_Error) {
	context.allocator = allocator
	stdin_fd = posix.FD(-1)
	stdout_fd = posix.FD(-1)
	stderr_fd = posix.FD(-1)

	stdin_read, stdin_write: posix.FD
	if open_stdin {
		r, w, ok := shell_manager_make_pipe()
		if !ok {
			return 0, stdin_fd, stdout_fd, stderr_fd, .Spawn_Failed
		}
		stdin_read, stdin_write = r, w
	} else {
		devnull := posix.open("/dev/null", posix.O_Flags{})
		if devnull == posix.FD(-1) {
			return 0, stdin_fd, stdout_fd, stderr_fd, .Spawn_Failed
		}
		stdin_read = devnull
		stdin_write = posix.FD(-1)
	}
	stdout_read, stdout_write, out_ok := shell_manager_make_pipe()
	if !out_ok {
		shell_manager_close_if_valid(stdin_read)
		shell_manager_close_if_valid(stdin_write)
		return 0, stdin_fd, stdout_fd, stderr_fd, .Spawn_Failed
	}
	stderr_read, stderr_write, err_ok := shell_manager_make_pipe()
	if !err_ok {
		shell_manager_close_if_valid(stdin_read)
		shell_manager_close_if_valid(stdin_write)
		shell_manager_close_if_valid(stdout_read)
		shell_manager_close_if_valid(stdout_write)
		return 0, stdin_fd, stdout_fd, stderr_fd, .Spawn_Failed
	}

	shell_cstr := strings.clone_to_cstring(shell_path, allocator)
	defer delete(shell_cstr, allocator)
	argv := shell_manager_build_argv(shell_path, cmdline, params, allocator)
	defer shell_manager_free_cstrings(&argv, allocator)
	envp, env_ok := shell_manager_build_envp(kak_env, allocator)
	if !env_ok {
		shell_manager_close_if_valid(stdin_read)
		shell_manager_close_if_valid(stdin_write)
		shell_manager_close_if_valid(stdout_read)
		shell_manager_close_if_valid(stdout_write)
		shell_manager_close_if_valid(stderr_read)
		shell_manager_close_if_valid(stderr_write)
		return 0, stdin_fd, stdout_fd, stderr_fd, .Spawn_Failed
	}
	defer shell_manager_free_cstrings(&envp, allocator)

	pid = posix.fork()
	if int(pid) < 0 {
		shell_manager_close_if_valid(stdin_read)
		shell_manager_close_if_valid(stdin_write)
		shell_manager_close_if_valid(stdout_read)
		shell_manager_close_if_valid(stdout_write)
		shell_manager_close_if_valid(stderr_read)
		shell_manager_close_if_valid(stderr_write)
		return 0, stdin_fd, stdout_fd, stderr_fd, .Spawn_Failed
	}
	if pid == 0 {
		// The child never returns: defers above run in the parent only.
		shell_manager_child_exec(shell_cstr, argv, envp, stdin_read, stdin_write, stdout_read, stdout_write, stderr_read, stderr_write)
	}
	shell_manager_close_if_valid(stdin_read)
	shell_manager_close_if_valid(stdout_write)
	shell_manager_close_if_valid(stderr_write)
	return pid, stdin_write, stdout_read, stderr_read, .None
}

// shell_manager_child_exec dups the pipes onto 0/1/2 and execs the
// shell. Runs after fork: raw syscalls only, no allocation, never
// returns (C++ vfork child branch, with fork instead of vfork).
shell_manager_child_exec :: proc(shell_path: cstring, argv, envp: [dynamic]cstring, stdin_read, stdin_write, stdout_read, stdout_write, stderr_read, stderr_write: posix.FD) -> ! {
	shell_manager_dup_to(stdin_read, posix.FD(0))
	shell_manager_dup_to(stdout_write, posix.FD(1))
	shell_manager_dup_to(stderr_write, posix.FD(2))
	shell_manager_close_if_valid(stdin_write)
	shell_manager_close_if_valid(stdout_read)
	shell_manager_close_if_valid(stderr_read)
	posix.execve(shell_path, raw_data(argv), raw_data(envp))
	msg := "shell_manager: execve failed\n"
	posix.write(posix.FD(2), raw_data(msg), c.size_t(len(msg)))
	posix._exit(-1)
}

// Shell_Manager_Eval_Result is the owned outcome of
// shell_manager_eval_full: captured stdout and stderr plus the exit
// code (C++ eval's pair, whose stderr the C++ forwards to the debug
// buffer instead).
Shell_Manager_Eval_Result :: struct {
	output: string,
	stderr: string,
	status: int,
}

// shell_manager_eval_result_free releases a result's owned strings.
shell_manager_eval_result_free :: proc(res: ^Shell_Manager_Eval_Result, allocator := context.allocator) {
	delete(res.output, allocator)
	delete(res.stderr, allocator)
	res^ = {}
}

// shell_manager_eval_full_from runs cmdline with the generated kak_*
// environment, feeds it stdin_content, and captures both outputs (C++
// ShellManager::eval). Without .Wait_For_Stdout it stops draining once
// the child exits, like the C++ Flags::None path.
shell_manager_eval_full_from :: proc(m: ^Shell_Manager, cmdline: string, ctx: ^Context, shell_ctx: ^Shell_Context, stdin_content: string = "", flags: Shell_Flags = {.Wait_For_Stdout}, allocator := context.allocator) -> (Shell_Manager_Eval_Result, Shell_Manager_Error) {
	context.allocator = allocator

	fifos: Shell_Manager_Fifos
	have_fifos := false
	if shell_manager_cmdline_needs_fifos(cmdline, shell_ctx.params) {
		f, ferr := shell_manager_fifos_make(allocator)
		if ferr != .None {
			return {}, .Spawn_Failed
		}
		fifos = f
		have_fifos = true
	}
	defer if have_fifos {
		shell_manager_fifos_destroy(&fifos)
	}

	kak_env := shell_manager_generate_env(m, cmdline, shell_ctx.params, ctx, shell_ctx, have_fifos ? &fifos : nil, allocator)
	defer shell_manager_free_strings(&kak_env, allocator)

	pid, stdin_fd, stdout_fd, stderr_fd, serr := shell_manager_spawn_shell(m.shell, cmdline, shell_ctx.params, kak_env[:], true, allocator)
	if serr != .None {
		return {}, serr
	}

	out_b := strings.builder_make(allocator)
	err_b := strings.builder_make(allocator)

	stdin_open := true
	stdin_off := 0
	stdin_bytes := transmute([]byte)(stdin_content)
	if len(stdin_bytes) == 0 {
		posix.close(stdin_fd)
		stdin_open = false
	}
	out_open := true
	err_open := true

	status: c.int = 0
	terminated := shell_manager_waitpid_nohang(pid, &status)

	chunk: [4096]byte
	for !terminated || stdin_open || (.Wait_For_Stdout in flags && (out_open || err_open)) {
		stdin_idx, out_idx, err_idx, cmd_idx := -1, -1, -1, -1
		pfds: [4]posix.pollfd
		nfds := 0
		if stdin_open {
			pfds[nfds] = posix.pollfd{fd = stdin_fd, events = {.OUT}}
			stdin_idx = nfds
			nfds += 1
		}
		if out_open {
			pfds[nfds] = posix.pollfd{fd = stdout_fd, events = {.IN}}
			out_idx = nfds
			nfds += 1
		}
		if err_open {
			pfds[nfds] = posix.pollfd{fd = stderr_fd, events = {.IN}}
			err_idx = nfds
			nfds += 1
		}
		if have_fifos && fifos.command_fd != posix.FD(-1) {
			pfds[nfds] = posix.pollfd{fd = fifos.command_fd, events = {.IN}}
			cmd_idx = nfds
			nfds += 1
		}
		if nfds == 0 {
			// Nothing left to pump: reap and stop.
			status = shell_manager_waitpid_block(pid)
			terminated = true
			break
		}
		// Bounded park: a child can close its outputs (all EOFs
		// consumed) just before it becomes waitable, after which a
		// fifo-only poll set would never wake. Rechecking the child
		// every 100ms bounds that race; output and fifo activity
		// still wake immediately.
		n := posix.poll(raw_data(pfds[:]), posix.nfds_t(nfds), 100)
		if n < 0 {
			if posix.errno() == .EINTR {
				if shell_manager_waitpid_nohang(pid, &status) {
					terminated = true
				}
				continue
			}
			// Hard poll failure: stop the child and bail out with
			// partial output rather than hanging.
			posix.kill(pid, .SIGTERM)
			status = shell_manager_waitpid_block(pid)
			terminated = true
			break
		}
		if stdin_idx >= 0 && pfds[stdin_idx].revents != {} {
			if .OUT in pfds[stdin_idx].revents {
				remaining := len(stdin_bytes) - stdin_off
				w := posix.write(stdin_fd, raw_data(stdin_bytes[stdin_off:]), c.size_t(remaining))
				if w < 0 {
					if posix.errno() != .EINTR {
						posix.close(stdin_fd)
						stdin_open = false
					}
				} else {
					stdin_off += int(w)
					if stdin_off >= len(stdin_bytes) {
						posix.close(stdin_fd)
						stdin_open = false
					}
				}
			} else {
				posix.close(stdin_fd)
				stdin_open = false
			}
		}
		if out_idx >= 0 && pfds[out_idx].revents != {} {
			out_open = shell_manager_pump_fd(stdout_fd, &out_b, chunk[:])
		}
		if err_idx >= 0 && pfds[err_idx].revents != {} {
			err_open = shell_manager_pump_fd(stderr_fd, &err_b, chunk[:])
		}
		if cmd_idx >= 0 && pfds[cmd_idx].revents != {} {
			shell_manager_pump_command_fifo(&fifos, ctx, shell_ctx, chunk[:], allocator)
		}
		if !terminated && shell_manager_waitpid_nohang(pid, &status) {
			terminated = true
		}
	}
	if out_open {
		posix.close(stdout_fd)
	}
	if err_open {
		posix.close(stderr_fd)
	}
	if stdin_open {
		posix.close(stdin_fd)
	}
	res := Shell_Manager_Eval_Result{
		output = strings.to_string(out_b),
		stderr = strings.to_string(err_b),
		status = -1,
	}
	if posix.WIFEXITED(status) {
		res.status = int(posix.WEXITSTATUS(status))
	}
	return res, .None
}

// shell_manager_eval_full is shell_manager_eval_full_from on the
// singleton.
shell_manager_eval_full :: proc(cmdline: string, ctx: ^Context, shell_ctx: ^Shell_Context, stdin_content: string = "", flags: Shell_Flags = {.Wait_For_Stdout}, allocator := context.allocator) -> (Shell_Manager_Eval_Result, Shell_Manager_Error) {
	return shell_manager_eval_full_from(shell_manager_instance(), cmdline, ctx, shell_ctx, stdin_content, flags, allocator)
}

// shell_manager_eval runs cmdline for %sh{...} expansion and returns the
// owned stdout (C++ ShellManager::eval with empty stdin and
// WaitForStdout, first of the pair). Failures yield an empty string;
// use shell_manager_eval_full to tell them apart.
shell_manager_eval :: proc(cmdline: string, ctx: ^Context, shell_ctx: ^Shell_Context, allocator := context.allocator) -> string {
	res, err := shell_manager_eval_full(cmdline, ctx, shell_ctx, "", {.Wait_For_Stdout}, allocator)
	if err != .None {
		shell_manager_eval_result_free(&res, allocator)
		return strings.clone("", allocator)
	}
	delete(res.stderr, allocator)
	return res.output
}

// shell_manager_pump_fd reads one chunk from fd into b. Returns false
// when fd reached EOF (or a hard error) and was closed.
shell_manager_pump_fd :: proc(fd: posix.FD, b: ^strings.Builder, chunk: []byte) -> bool {
	for {
		n := posix.read(fd, raw_data(chunk), c.size_t(len(chunk)))
		if n > 0 {
			strings.write_string(b, string(chunk[:int(n)]))
			return true
		}
		if n == 0 {
			posix.close(fd)
			return false
		}
		if posix.errno() == .EINTR {
			continue
		}
		// poll said readable, so any other error means the stream is
		// dead; close to avoid spinning on it.
		posix.close(fd)
		return false
	}
}

// shell_manager_pump_command_fifo drains the command fifo: each writer
// session (open, write, close) executes as Kakoune commands, then the
// read end reopens (C++ CommandFifos watcher callback). Execute errors
// are dropped: the debug sink is still a STUB in this package.
shell_manager_pump_command_fifo :: proc(f: ^Shell_Manager_Fifos, ctx: ^Context, shell_ctx: ^Shell_Context, chunk: []byte, allocator: mem.Allocator) {
	context.allocator = allocator
	for {
		n := posix.read(f.command_fd, raw_data(chunk), c.size_t(len(chunk)))
		if n > 0 {
			append(&f.command, ..chunk[:int(n)])
			continue
		}
		if n == 0 {
			cmd_err, cmd_msg := command_manager_execute(command_manager_instance(), string(f.command[:]), ctx, shell_ctx, allocator)
			if cmd_err != .None {
				delete(cmd_msg, allocator)
			}
			clear(&f.command)
			shell_manager_fifos_reopen_command(f)
			return
		}
		if posix.errno() == .EINTR {
			continue
		}
		if posix.errno() == .EAGAIN {
			return
		}
		clear(&f.command)
		shell_manager_fifos_reopen_command(f)
		return
	}
}

// shell_manager_waitpid_nohang polls for child termination (C++
// waitpid(..., WNOHANG) checks). Any error other than EINTR counts as
// terminated so the drain loop cannot spin forever.
shell_manager_waitpid_nohang :: proc(pid: posix.pid_t, status: ^c.int) -> bool {
	for {
		r := posix.waitpid(pid, status, posix.Wait_Flags{.NOHANG})
		if int(r) == int(pid) {
			return true
		}
		if int(r) >= 0 {
			return false
		}
		if posix.errno() == .EINTR {
			continue
		}
		return true
	}
}

// shell_manager_waitpid_block reaps the child (C++ waitpid without
// WNOHANG), retrying on EINTR.
shell_manager_waitpid_block :: proc(pid: posix.pid_t) -> c.int {
	status: c.int = 0
	for {
		r := posix.waitpid(pid, &status, posix.Wait_Flags{})
		if int(r) == int(pid) {
			return status
		}
		if int(r) < 0 && posix.errno() != .EINTR {
			return status
		}
	}
}
