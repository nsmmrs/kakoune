package kak

import "core:strings"
import "core:testing"

// backtrace_desc captures at least the test frame on glibc; off-tty
// prompt paths decline without blocking.
@(test)
backtrace_test_desc_nonempty :: proc(t: ^testing.T) {
	desc := backtrace_desc(context.allocator)
	defer delete(desc)
	testing.expect(t, len(desc) > 0, "expected at least one frame")
	testing.expect(t, strings.has_suffix(desc, "\n"), "expected trailing newline")
}

@(test)
assert_test_notify_off_tty :: proc(t: ^testing.T) {
	// Under `odin test` stdin is not a tty, so this declines
	// immediately instead of prompting.
	testing.expect(t, !assert_notify_fatal_error("boom"))
}
