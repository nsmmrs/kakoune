// Tests for the debug module. No C++ UnitTest block covers debug,
// so every test below is new. All writes go through the claimed
// buffer-manager singleton (see buffer_utils_test_claim_singletons);
// the no-manager stderr fallback is untested by design (it would
// scribble on the test runner's own stderr).
//
// Buffer accesses sit behind nil/count gates and manager-liveness
// checks: a trap here would skip the singleton-mutex unlock and
// hang the other singleton tests, and a foreign teardown mid-test
// must degrade to a skip. Teardown destroys the manager only while
// it still holds our buffer, so it never nukes a foreign manager.
package kak

import "core:fmt"
import "core:testing"

// debug_test_fetch returns the live *debug* buffer, or nil after a
// skip note when the manager is gone.
debug_test_fetch :: proc(t: ^testing.T) -> ^Buffer {
	if !buffer_utils_test_manager_live() {
		fmt.println("SKIP: buffer manager lost mid-test")
		return nil
	}
	buf := buffer_manager_get_ifp(&Buffer_Manager_Instance, "*debug*")
	testing.expect(t, buf != nil)
	return buf
}

@(test)
debug_test_write :: proc(t: ^testing.T) {
	if !buffer_utils_test_claim_singletons() {
		return
	}
	tracked: ^Buffer = nil
	defer {
		buffer_utils_test_release_manager("*debug*", tracked)
	}
	buffer_manager_instance_init()
	// First write creates the buffer with the trailing empty line.
	debug_write_to_debug_buffer("hello")
	tracked = debug_test_fetch(t)
	if tracked == nil {
		return
	}
	testing.expect_value(t, tracked.flags, Buffer_Flags{.No_Undo, .Debug, .Read_Only})
	buffer_utils_test_expect_lines(t, tracked, {"hello\n", "\n"})
	// Appends keep one trailing empty line.
	debug_write_to_debug_buffer("world\n")
	if tracked = debug_test_fetch(t); tracked == nil {
		return
	}
	buffer_utils_test_expect_lines(t, tracked, {"hello\n", "world\n", "\n"})
	debug_write_to_debug_buffer("again")
	if tracked = debug_test_fetch(t); tracked == nil {
		return
	}
	buffer_utils_test_expect_lines(t, tracked, {"hello\n", "world\n", "again\n", "\n"})
	testing.expect_value(t, tracked.flags, Buffer_Flags{.No_Undo, .Debug, .Read_Only})
	// The alias writes to the same buffer.
	debug_write_to_buffer("alias\n")
	if tracked = debug_test_fetch(t); tracked == nil {
		return
	}
	buffer_utils_test_expect_lines(t, tracked, {"hello\n", "world\n", "again\n", "alias\n", "\n"})
}

@(test)
debug_test_write_starts_with_newline :: proc(t: ^testing.T) {
	if !buffer_utils_test_claim_singletons() {
		return
	}
	tracked: ^Buffer = nil
	defer {
		buffer_utils_test_release_manager("*debug*", tracked)
	}
	buffer_manager_instance_init()
	// A first write ending in newline still gains the empty line.
	debug_write_to_debug_buffer("first\n")
	tracked = debug_test_fetch(t)
	if tracked == nil {
		return
	}
	buffer_utils_test_expect_lines(t, tracked, {"first\n", "\n"})
}
