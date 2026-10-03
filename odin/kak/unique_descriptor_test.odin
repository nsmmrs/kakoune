// Tests for unique_descriptor.odin (port of src/unique_descriptor.hh).
//
// No C++ UnitTest covers this header; tests are written from the
// header's contract: default -1, bool conversion, idempotent close,
// move transfers ownership, and move-assign closes the old value.
package kak

import "core:testing"
import posix "core:sys/posix"

// Recording closer state. Thread-local fixed buffer: `odin test`
// runs tests on multiple threads, so a shared global would race,
// and a fixed buffer avoids leaking a dynamic array.
@(private, thread_local)
unique_descriptor_test_calls: [8]int

@(private, thread_local)
unique_descriptor_test_call_count: int

@(private)
unique_descriptor_test_record :: proc(fd: int) {
	n := unique_descriptor_test_call_count
	if n < len(unique_descriptor_test_calls) {
		unique_descriptor_test_calls[n] = fd
		unique_descriptor_test_call_count = n + 1
	}
}

@(private)
unique_descriptor_test_reset :: proc() {
	unique_descriptor_test_call_count = 0
}

@(private)
unique_descriptor_test_call :: proc(i: int) -> int {
	return unique_descriptor_test_calls[i]
}

@(private)
unique_descriptor_test_count :: proc() -> int {
	return unique_descriptor_test_call_count
}

// default handle is invalid and closing it calls nothing
@(test)
test_unique_descriptor_default_invalid :: proc(t: ^testing.T) {
	unique_descriptor_test_reset()
	d := unique_descriptor_make(-1, unique_descriptor_test_record)
	testing.expect(t, !unique_descriptor_is_valid(d))
	testing.expect_value(t, d.descriptor, -1)
	unique_descriptor_close(&d)
	testing.expect_value(t, unique_descriptor_test_count(), 0)
	// make() with defaults is invalid too
	e := unique_descriptor_make()
	testing.expect(t, !unique_descriptor_is_valid(e))
	testing.expect_value(t, e.descriptor, -1)
	unique_descriptor_close(&e)
	testing.expect_value(t, unique_descriptor_test_count(), 0)
}

// close invokes the closer once with the fd, then invalidates;
// a second close is a no-op
@(test)
test_unique_descriptor_close_once :: proc(t: ^testing.T) {
	unique_descriptor_test_reset()
	d := unique_descriptor_make(42, unique_descriptor_test_record)
	testing.expect(t, unique_descriptor_is_valid(d))
	unique_descriptor_close(&d)
	testing.expect(t, !unique_descriptor_is_valid(d))
	testing.expect_value(t, unique_descriptor_test_count(), 1)
	testing.expect_value(t, unique_descriptor_test_call(0), 42)
	unique_descriptor_close(&d)
	testing.expect_value(t, unique_descriptor_test_count(), 1)
}

// nil closer: close just resets without calling anything
@(test)
test_unique_descriptor_close_nil_proc :: proc(t: ^testing.T) {
	d := unique_descriptor_make(7)
	testing.expect(t, unique_descriptor_is_valid(d))
	unique_descriptor_close(&d)
	testing.expect(t, !unique_descriptor_is_valid(d))
}

// move transfers ownership and leaves the source invalid (port of
// the move constructor)
@(test)
test_unique_descriptor_move_transfers :: proc(t: ^testing.T) {
	unique_descriptor_test_reset()
	src := unique_descriptor_make(11, unique_descriptor_test_record)
	dst := unique_descriptor_make()
	unique_descriptor_move(&dst, &src)
	testing.expect(t, !unique_descriptor_is_valid(src))
	testing.expect(t, unique_descriptor_is_valid(dst))
	testing.expect_value(t, dst.descriptor, 11)
	testing.expect_value(t, unique_descriptor_test_count(), 0)
	// the closer moved along: closing dst releases the fd
	unique_descriptor_close(&dst)
	testing.expect_value(t, unique_descriptor_test_count(), 1)
	testing.expect_value(t, unique_descriptor_test_call(0), 11)
}

// move closes the destination's old value first (port of the
// swap-then-close move assignment)
@(test)
test_unique_descriptor_move_closes_old_dst :: proc(t: ^testing.T) {
	unique_descriptor_test_reset()
	src := unique_descriptor_make(1, unique_descriptor_test_record)
	dst := unique_descriptor_make(2, unique_descriptor_test_record)
	unique_descriptor_move(&dst, &src)
	testing.expect_value(t, dst.descriptor, 1)
	testing.expect(t, !unique_descriptor_is_valid(src))
	testing.expect_value(t, unique_descriptor_test_count(), 1)
	testing.expect_value(t, unique_descriptor_test_call(0), 2)
	unique_descriptor_close(&dst)
	testing.expect_value(t, unique_descriptor_test_count(), 2)
	testing.expect_value(t, unique_descriptor_test_call(1), 1)
}

// moving from an invalid source closes dst and leaves both invalid
@(test)
test_unique_descriptor_move_from_invalid :: proc(t: ^testing.T) {
	unique_descriptor_test_reset()
	src := unique_descriptor_make()
	dst := unique_descriptor_make(3, unique_descriptor_test_record)
	unique_descriptor_move(&dst, &src)
	testing.expect(t, !unique_descriptor_is_valid(dst))
	testing.expect(t, !unique_descriptor_is_valid(src))
	testing.expect_value(t, unique_descriptor_test_count(), 1)
	testing.expect_value(t, unique_descriptor_test_call(0), 3)
}

// self-move closes the handle, like the C++ swap-with-self
@(test)
test_unique_descriptor_self_move_closes :: proc(t: ^testing.T) {
	unique_descriptor_test_reset()
	d := unique_descriptor_make(9, unique_descriptor_test_record)
	unique_descriptor_move(&d, &d)
	testing.expect(t, !unique_descriptor_is_valid(d))
	testing.expect_value(t, unique_descriptor_test_count(), 1)
	testing.expect_value(t, unique_descriptor_test_call(0), 9)
}

// end to end with a real pipe: closing the write end through the
// handle makes the read end see EOF
@(test)
test_unique_descriptor_real_fd :: proc(t: ^testing.T) {
	fds: [2]posix.FD
	testing.expect_value(t, posix.pipe(&fds), posix.result.OK)
	write_end := unique_descriptor_make(int(fds[1]), unique_descriptor_close_fd)
	unique_descriptor_close(&write_end)
	testing.expect(t, !unique_descriptor_is_valid(write_end))
	buf: [1]byte
	n := posix.read(fds[0], raw_data(buf[:]), len(buf))
	testing.expect_value(t, n, 0) // EOF: write end is really closed
	posix.close(fds[0])
}
