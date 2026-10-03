// Tests for clock.odin (port of src/clock.hh).
//
// No C++ UnitTest covers this header; tests are written from how
// TimePoint/Clock are used (event_manager timers, idle/fs-check
// timeouts): monotonic now, max sentinel, comparisons, and
// duration arithmetic.
package kak

import "core:testing"
import "core:time"

// the clock never runs backwards
@(test)
test_clock_monotonic :: proc(t: ^testing.T) {
	prev := clock_now()
	for _ in 0 ..< 100 {
		now := clock_now()
		testing.expect(t, now >= prev)
		prev = now
	}
}

// max is the disabled-timer sentinel, above any real reading
@(test)
test_clock_max :: proc(t: ^testing.T) {
	testing.expect_value(t, clock_max(), Clock_Time(max(i64)))
	testing.expect(t, clock_now() < clock_max())
	testing.expect(t, clock_max() != clock_now())
}

// add/diff round-trip like time_point +/- duration
@(test)
test_clock_add_diff :: proc(t: ^testing.T) {
	start := clock_now()
	later := clock_add(start, 5 * time.Millisecond)
	testing.expect_value(t, clock_diff(start, later), 5 * time.Millisecond)
	testing.expect_value(t, clock_diff(later, start), -5 * time.Millisecond)
	// zero and negative durations
	testing.expect_value(t, clock_add(start, 0), start)
	back := clock_add(start, -time.Second)
	testing.expect_value(t, clock_diff(back, start), time.Second)
	// ordering follows from arithmetic
	testing.expect(t, back < start)
	testing.expect(t, start < later)
	testing.expect(t, later <= later)
	testing.expect(t, later != start)
}

// elapsed wall time over a real sleep lands in a sane bound
@(test)
test_clock_elapsed :: proc(t: ^testing.T) {
	start := clock_now()
	time.sleep(5 * time.Millisecond)
	elapsed := clock_diff(start, clock_now())
	testing.expect(t, elapsed >= 5 * time.Millisecond)
	testing.expect(t, elapsed < 5 * time.Second)
}
