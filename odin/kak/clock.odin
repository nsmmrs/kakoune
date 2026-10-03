// Port of Kakoune's src/clock.hh (steady_clock + time_point).
//
// Clock_Time is monotonic nanoseconds since an arbitrary epoch, read
// from core:time's monotonic tick source (CLOCK_MONOTONIC on Linux).
// It is a distinct int rather than time.Tick because Tick's field is
// private (no max sentinel constructible) and Tick has no ordering;
// here ==, !=, <, <=, >, >= all work, matching C++ time_point.
// Durations are core:time.Duration (distinct i64 nanoseconds).
package kak

import "core:time"

// Clock_Time is a monotonic-clock reading (port of C++ TimePoint).
Clock_Time :: distinct i64

// clock_now returns the current monotonic time (port of Clock::now()).
clock_now :: proc() -> Clock_Time {
	return Clock_Time(i64(time.tick_diff(time.Tick{}, time.tick_now())))
}

// clock_max is the largest representable time, used as the "disabled"
// timer sentinel (port of TimePoint::max()).
clock_max :: proc() -> Clock_Time {
	return Clock_Time(max(i64))
}

// clock_add shifts t forward by d (port of time_point + duration).
clock_add :: proc(t: Clock_Time, d: time.Duration) -> Clock_Time {
	return t + Clock_Time(i64(d))
}

// clock_diff returns later - earlier as a duration, negative when
// later precedes earlier (port of time_point - time_point).
clock_diff :: proc(earlier, later: Clock_Time) -> time.Duration {
	return time.Duration(i64(later - earlier))
}
