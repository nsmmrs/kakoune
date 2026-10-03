// Port of Kakoune's src/unique_descriptor.hh: a tiny RAII file
// descriptor wrapper (UniqueFd/UniquePid in shell_manager.hh).
//
// No destructors in Odin, so ownership is explicit: the handle is a
// plain allocator-free struct and the owner must call
// unique_descriptor_close exactly once per live handle (extra closes
// are safe no-ops). The C++ template parameter (close vs closepid)
// becomes a stored close_proc. C++ move construction/assignment
// becomes unique_descriptor_move, which transfers ownership and
// leaves the source invalid, closing the destination's old value
// first (matching the C++ swap-then-close move-assign).
package kak

import posix "core:sys/posix"

// Unique_Descriptor is an owned fd/pid plus its closer. Always
// create it with unique_descriptor_make (the bare Odin zero value
// holds fd 0, not the invalid -1, and must not be used directly).
// It owns no memory; only the descriptor lifetime is managed.
Unique_Descriptor :: struct {
	descriptor: int,
	close_proc: proc(fd: int),
}

// unique_descriptor_make wraps descriptor (default invalid -1) with
// its closer. A nil close_proc makes close a silent reset.
unique_descriptor_make :: proc(descriptor := -1, close_proc: proc(fd: int) = nil) -> Unique_Descriptor {
	return Unique_Descriptor{descriptor, close_proc}
}

// unique_descriptor_is_valid reports whether d owns a live value
// (port of explicit operator bool).
unique_descriptor_is_valid :: proc(d: Unique_Descriptor) -> bool {
	return d.descriptor != -1
}

// unique_descriptor_close releases d: calls its closer on the
// descriptor once, then resets d to invalid. Closing an invalid
// handle is a no-op, so double close is safe.
unique_descriptor_close :: proc(d: ^Unique_Descriptor) {
	if d.descriptor != -1 {
		if d.close_proc != nil {
			d.close_proc(d.descriptor)
		}
		d.descriptor = -1
		d.close_proc = nil
	}
}

// unique_descriptor_move transfers ownership from src to dst (port
// of the C++ move constructor/assignment): dst's old value is
// closed first, then dst takes src's descriptor and closer while
// src is reset to invalid. Self-move closes the handle, matching
// the C++ swap-then-close behavior.
unique_descriptor_move :: proc(dst, src: ^Unique_Descriptor) {
	if dst == src {
		unique_descriptor_close(dst)
		return
	}
	unique_descriptor_close(dst)
	dst.descriptor = src.descriptor
	dst.close_proc = src.close_proc
	src.descriptor = -1
	src.close_proc = nil
}

// unique_descriptor_close_fd is the closer for plain fds (port of
// the UniqueFd = UniqueDescriptor<::close> instantiation).
unique_descriptor_close_fd :: proc(fd: int) {
	posix.close(posix.FD(fd))
}
