// Fatal-error prompt ported from src/assert.{hh,cc}.
//
// Only notify_fatal_error is ported: the C++ on_assert_failed feeds the
// kak_assert macro, whose role the Odin `assert` builtin already plays,
// and assert_failed (an exception type) has no Odin equivalent.
package kak

import "core:fmt"
import posix "core:sys/posix"

// Assert_Error is the per-module error enum. The prompt cannot fail;
// decline/absence of a tty is a false return, not an error.
Assert_Error :: enum {
	None,
}

// assert_notify_fatal_error prompts on the terminal when both stdio
// streams are ttys (C++ notify_fatal_error): q (or read error) declines,
// i ignores. Returns false without prompting off-tty. Like the C++,
// msg is advisory only; the prompt carries the pid.
assert_notify_fatal_error :: proc(msg: string) -> bool {
	_ = msg
	if !posix.isatty(posix.STDOUT_FILENO) || !posix.isatty(posix.STDIN_FILENO) {
		return false
	}
	prompt := fmt.tprintf(
		"\x1b[;31;5;1mKakoune fatal error, q: exit, i: ignore or debug pid {}\x1b[0m",
		posix.getpid(),
	)
	bytes := transmute([]byte)(prompt)
	_ = posix.write(posix.STDOUT_FILENO, raw_data(bytes), len(bytes))
	for {
		c: u8 = 0
		if posix.read(posix.STDIN_FILENO, &c, 1) < 0 || c == 'q' {
			return false
		} else if c == 'i' {
			return true
		}
	}
}
