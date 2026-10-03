// Tests for event_manager.odin (port of src/event_manager.{hh,cc}).
//
// No C++ UnitTest covers this module; tests are written from the
// source behavior: registration, pselect dispatch, forced fds, timers,
// mode filtering, urgent polling, and signal handlers.
//
// Parallelism note: `odin test` runs tests on worker threads, so each
// test owns disjoint callback globals, and every test that installs
// the singleton holds event_manager_test_singleton_mutex from setup
// through teardown (the remote UI lifecycle test shares it).
package kak

import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import posix "core:sys/posix"

// event_manager_test_singleton_mutex serializes singleton install and
// teardown across tests (see the parallelism note above).
event_manager_test_singleton_mutex: sync.Mutex

// --- Disjoint callback state (one owner per global; see note above). ---

// event_manager_test_fd_fired counts event_manager_test_on_fd calls.
event_manager_test_fd_fired: int

// event_manager_test_fd_events/mode record the last fd callback args.
event_manager_test_fd_events: Event_Manager_Fd_Events
event_manager_test_fd_mode: Event_Manager_Mode

// event_manager_test_timer_fired counts timer callbacks in dispatch tests.
event_manager_test_timer_fired: int

// event_manager_test_victim is destroyed mid-dispatch by the killer timer.
event_manager_test_victim: ^Event_Manager_Timer

// event_manager_test_writer_fd feeds the blocking-dispatch writer thread.
event_manager_test_writer_fd: int

// event_manager_test_direct_fired is set by the direct timer_run test.
event_manager_test_direct_fired: bool

// event_manager_test_on_fd records fd dispatches for dispatch tests.
event_manager_test_on_fd :: proc(w: ^Event_Manager_Fd_Watcher, events: Event_Manager_Fd_Events, mode: Event_Manager_Mode) {
	event_manager_test_fd_fired += 1
	event_manager_test_fd_events = events
	event_manager_test_fd_mode = mode
}

// event_manager_test_on_timer counts timer dispatches.
event_manager_test_on_timer :: proc(t: ^Event_Manager_Timer) {
	event_manager_test_timer_fired += 1
}

// event_manager_test_on_timer_killer destroys the victim timer, proving
// dispatch skips timers unregistered mid-round (the C++ contains check).
event_manager_test_on_timer_killer :: proc(t: ^Event_Manager_Timer) {
	event_manager_test_timer_fired += 1
	if event_manager_test_victim != nil {
		event_manager_timer_destroy(event_manager_test_victim)
		event_manager_test_victim = nil
	}
}

// event_manager_test_on_timer_direct flags the direct timer_run test.
event_manager_test_on_timer_direct :: proc(t: ^Event_Manager_Timer) {
	event_manager_test_direct_fired = true
}

// event_manager_test_pipe_writer wakes a blocking dispatch round from a
// helper thread, then owns and closes the write end.
event_manager_test_pipe_writer :: proc() {
	time.sleep(20 * time.Millisecond)
	buf := [1]byte{'x'}
	posix.write(posix.FD(event_manager_test_writer_fd), raw_data(buf[:]), 1)
	posix.close(posix.FD(event_manager_test_writer_fd))
}

// event_manager_test_sig_handler is a no-op C signal handler.
event_manager_test_sig_handler :: proc "c" (sig: posix.Signal) {
}

// event_manager_test_make_pipe opens a pipe, failing the test on error.
event_manager_test_make_pipe :: proc(t: ^testing.T) -> (read_fd, write_fd: int) {
	fds := [2]posix.FD{-1, -1}
	testing.expect_value(t, posix.pipe(&fds), posix.result.OK)
	return int(fds[0]), int(fds[1])
}

// event_manager_test_write_byte writes one byte, failing on short write.
event_manager_test_write_byte :: proc(t: ^testing.T, fd: int, b: byte) {
	buf := [1]byte{b}
	testing.expect_value(t, int(posix.write(posix.FD(fd), raw_data(buf[:]), 1)), 1)
}

// event_manager_test_read_byte reads one byte; the caller must ensure
// one is pending so the blocking read returns immediately.
event_manager_test_read_byte :: proc(t: ^testing.T, fd: int) -> byte {
	buf: [1]byte
	testing.expect_value(t, int(posix.read(posix.FD(fd), raw_data(buf[:]), 1)), 1)
	return buf[0]
}

// Error/mode/event shapes: None is zero, Normal is zero, sets behave.
@(test)
event_manager_test_enums_and_events :: proc(t: ^testing.T) {
	testing.expect_value(t, int(Event_Manager_Error.None), 0)
	testing.expect_value(t, int(Event_Manager_Mode.Normal), 0)
	empty: Event_Manager_Fd_Events
	testing.expect(t, empty == {})
	testing.expect(t, empty != {.Read})
	both := Event_Manager_Fd_Events{.Read} | Event_Manager_Fd_Events{.Write}
	testing.expect(t, .Read in both && .Write in both && .Except not_in both)
	testing.expect(t, both & {.Write} == {.Write})
}

// Unordered erase swaps with the last element; misses are a no-op.
@(test)
event_manager_test_unordered_erase :: proc(t: ^testing.T) {
	arr := make([dynamic]int, 0, 3)
	defer delete(arr)
	append(&arr, 10, 20, 30)
	event_manager_unordered_erase(&arr, 20)
	testing.expect_value(t, len(arr), 2)
	testing.expect_value(t, arr[0], 10)
	testing.expect_value(t, arr[1], 30)
	event_manager_unordered_erase(&arr, 99)
	testing.expect_value(t, len(arr), 2)
	testing.expect_value(t, arr[0], 10)
	testing.expect_value(t, arr[1], 30)
	event_manager_unordered_erase(&arr, 10)
	testing.expect_value(t, len(arr), 1)
	testing.expect_value(t, arr[0], 30)
}

// Timer::run without a manager: matching mode fires and parks at max,
// mismatching mode postpones ~10ms without firing.
@(test)
event_manager_test_timer_run_direct :: proc(t: ^testing.T) {
	event_manager_test_direct_fired = false
	past := clock_add(clock_now(), -time.Second)
	fires := Event_Manager_Timer{date = past, mode = .Normal, callback = event_manager_test_on_timer_direct}
	event_manager_timer_run(&fires, .Normal)
	testing.expect(t, event_manager_test_direct_fired)
	testing.expect_value(t, fires.date, clock_max())

	event_manager_test_direct_fired = false
	pre := clock_now()
	wait := Event_Manager_Timer{date = past, mode = .Normal, callback = event_manager_test_on_timer_direct}
	event_manager_timer_run(&wait, .Urgent)
	testing.expect(t, !event_manager_test_direct_fired)
	elapsed := clock_diff(pre, wait.date)
	testing.expect(t, elapsed >= 10*time.Millisecond)
	testing.expect(t, elapsed < 10*time.Millisecond+5*time.Second)
}

// set_signal_handler round-trips and reports bad signums.
@(test)
event_manager_test_signal_handler :: proc(t: ^testing.T) {
	old, err := event_manager_set_signal_handler(.SIGUSR1, event_manager_test_sig_handler)
	testing.expect_value(t, err, Event_Manager_Error.None)
	prev, rerr := event_manager_set_signal_handler(.SIGUSR1, old)
	testing.expect_value(t, rerr, Event_Manager_Error.None)
	testing.expect(t, prev == event_manager_test_sig_handler)

	bad_old, bad_err := event_manager_set_signal_handler(posix.Signal(9999), event_manager_test_sig_handler)
	testing.expect_value(t, bad_err, Event_Manager_Error.Signal_Failed)
	testing.expect(t, bad_old == nil)
}

// The singleton lifecycle plus every dispatch behavior, sequential in
// one proc so no two managers are ever installed at once.
@(test)
event_manager_test_dispatch :: proc(t: ^testing.T) {
	sync.mutex_lock(&event_manager_test_singleton_mutex)
	defer sync.mutex_unlock(&event_manager_test_singleton_mutex)

	// Without a manager, urgent polling is a silent no-op.
	testing.expect(t, !event_manager_has_instance())
	handled, herr := event_manager_handle_urgent_events()
	testing.expect(t, !handled)
	testing.expect_value(t, herr, Event_Manager_Error.None)

	manager: Event_Manager
	event_manager_init(&manager)
	testing.expect(t, event_manager_has_instance())
	testing.expect(t, event_manager_instance() == &manager)

	// Registration: watchers and timers append, destroy unregisters, a
	// nil-callback timer never registers.
	watcher: Event_Manager_Fd_Watcher
	event_manager_fd_watcher_init(&watcher, 3, {.Read}, .Normal, event_manager_test_on_fd)
	testing.expect_value(t, len(manager.fd_watchers), 1)
	timer: Event_Manager_Timer
	event_manager_timer_init(&timer, clock_max(), event_manager_test_on_timer)
	testing.expect_value(t, len(manager.timers), 1)
	ghost: Event_Manager_Timer
	event_manager_timer_init(&ghost, clock_max(), nil)
	testing.expect_value(t, len(manager.timers), 1)
	event_manager_timer_destroy(&ghost)
	testing.expect_value(t, len(manager.timers), 1)
	event_manager_fd_watcher_destroy(&watcher)
	testing.expect_value(t, len(manager.fd_watchers), 0)
	event_manager_timer_destroy(&timer)
	testing.expect_value(t, len(manager.timers), 0)

	// Readable fd dispatch: fires with Read, reports activity.
	rfd, wfd := event_manager_test_make_pipe(t)
	defer posix.close(posix.FD(rfd))
	defer posix.close(posix.FD(wfd))
	event_manager_test_write_byte(t, wfd, 'a')
	event_manager_test_fd_fired = 0
	read_watcher: Event_Manager_Fd_Watcher
	event_manager_fd_watcher_init(&read_watcher, rfd, {.Read}, .Normal, event_manager_test_on_fd)
	handled, herr = event_manager_handle_next_events(.Normal, time.Duration(0))
	testing.expect_value(t, herr, Event_Manager_Error.None)
	testing.expect(t, handled)
	testing.expect_value(t, event_manager_test_fd_fired, 1)
	testing.expect_value(t, event_manager_test_fd_events, Event_Manager_Fd_Events{.Read})
	testing.expect_value(t, event_manager_test_fd_mode, Event_Manager_Mode.Normal)
	event_manager_fd_watcher_destroy(&read_watcher)
	testing.expect_value(t, event_manager_test_read_byte(t, rfd), 'a')

	// Urgent rounds skip Normal watchers but run Urgent ones.
	rfd2, wfd2 := event_manager_test_make_pipe(t)
	defer posix.close(posix.FD(rfd2))
	defer posix.close(posix.FD(wfd2))
	event_manager_test_write_byte(t, wfd2, 'b')
	normal_watcher: Event_Manager_Fd_Watcher
	event_manager_fd_watcher_init(&normal_watcher, rfd2, {.Read}, .Normal, event_manager_test_on_fd)
	urgent_watcher: Event_Manager_Fd_Watcher
	event_manager_fd_watcher_init(&urgent_watcher, rfd2, {.Read}, .Urgent, event_manager_test_on_fd)
	event_manager_test_fd_fired = 0
	handled, herr = event_manager_handle_next_events(.Urgent, time.Duration(0))
	testing.expect_value(t, herr, Event_Manager_Error.None)
	testing.expect(t, handled)
	// Exactly one fires: find dispatches the first matching fd watcher,
	// and the Normal one is skipped in Urgent mode.
	testing.expect_value(t, event_manager_test_fd_fired, 1)
	testing.expect_value(t, event_manager_test_fd_mode, Event_Manager_Mode.Urgent)
	event_manager_fd_watcher_destroy(&normal_watcher)
	event_manager_fd_watcher_destroy(&urgent_watcher)
	testing.expect_value(t, event_manager_test_read_byte(t, rfd2), 'b')

	// Watcher accessors: reset_fd, disable, close_fd, direct fields.
	rfd3, wfd3 := event_manager_test_make_pipe(t)
	spare: Event_Manager_Fd_Watcher
	event_manager_fd_watcher_init(&spare, rfd3, {.Read, .Write}, .Urgent, event_manager_test_on_fd)
	event_manager_fd_watcher_reset_fd(&spare, wfd3)
	testing.expect_value(t, spare.fd, wfd3)
	testing.expect(t, spare.events == {.Read, .Write} && spare.mode == .Urgent)
	event_manager_fd_watcher_disable(&spare)
	testing.expect_value(t, spare.fd, -1)
	// Disabled watchers are skipped: silent, no activity.
	event_manager_test_fd_fired = 0
	handled, herr = event_manager_handle_next_events(.Normal, time.Duration(0))
	testing.expect(t, !handled && event_manager_test_fd_fired == 0)
	// Out-of-range fds are skipped too (C++ FD_SET would be UB).
	event_manager_fd_watcher_reset_fd(&spare, posix.FD_SETSIZE + 5)
	handled, herr = event_manager_handle_next_events(.Normal, time.Duration(0))
	testing.expect(t, !handled && event_manager_test_fd_fired == 0)
	event_manager_fd_watcher_destroy(&spare)
	posix.close(posix.FD(rfd3))
	posix.close(posix.FD(wfd3))
	rfd4, wfd4 := event_manager_test_make_pipe(t)
	closer: Event_Manager_Fd_Watcher
	event_manager_fd_watcher_init(&closer, rfd4, {.Read}, .Normal, event_manager_test_on_fd)
	event_manager_fd_watcher_close_fd(&closer)
	testing.expect_value(t, closer.fd, -1)
	event_manager_fd_watcher_close_fd(&closer) // second close is a no-op
	event_manager_fd_watcher_destroy(&closer)
	posix.close(posix.FD(wfd4))

	// Forced fds are serviced as Read even with no select activity: an
	// idle pipe, a watcher with no select bits, and a due timer to clamp
	// the cleared timeout back to zero so the round cannot block.
	rfd5, wfd5 := event_manager_test_make_pipe(t)
	defer posix.close(posix.FD(rfd5))
	defer posix.close(posix.FD(wfd5))
	forced_watcher: Event_Manager_Fd_Watcher
	event_manager_fd_watcher_init(&forced_watcher, rfd5, {}, .Normal, event_manager_test_on_fd)
	clamp_timer: Event_Manager_Timer
	event_manager_timer_init(&clamp_timer, clock_add(clock_now(), -time.Second), event_manager_test_on_timer)
	event_manager_test_fd_fired = 0
	event_manager_test_timer_fired = 0
	event_manager_force_signal(rfd5)
	testing.expect(t, manager.has_forced)
	handled, herr = event_manager_handle_next_events(.Normal, 5*time.Second)
	testing.expect_value(t, herr, Event_Manager_Error.None)
	testing.expect(t, !handled) // pselect saw nothing; forced + timer did
	testing.expect_value(t, event_manager_test_fd_fired, 1)
	testing.expect_value(t, event_manager_test_fd_events, Event_Manager_Fd_Events{.Read})
	testing.expect_value(t, event_manager_test_timer_fired, 1)
	testing.expect(t, !manager.has_forced)
	// The forced bit is spent: an immediate round stays silent.
	event_manager_test_fd_fired = 0
	handled, herr = event_manager_handle_next_events(.Normal, time.Duration(0))
	testing.expect(t, !handled && event_manager_test_fd_fired == 0)
	event_manager_fd_watcher_destroy(&forced_watcher)
	event_manager_timer_destroy(&clamp_timer)

	// Due timer fires and parks; future timer waits; urgent polling
	// fires urgent timers without a manager round-trip.
	event_manager_test_timer_fired = 0
	due: Event_Manager_Timer
	event_manager_timer_init(&due, clock_add(clock_now(), -time.Second), event_manager_test_on_timer)
	future_date := clock_add(clock_now(), time.Hour)
	future: Event_Manager_Timer
	event_manager_timer_init(&future, future_date, event_manager_test_on_timer)
	handled, herr = event_manager_handle_next_events(.Normal, time.Duration(0))
	testing.expect_value(t, herr, Event_Manager_Error.None)
	testing.expect_value(t, event_manager_test_timer_fired, 1)
	testing.expect_value(t, due.date, clock_max())
	testing.expect_value(t, future.date, future_date)
	urgent_due: Event_Manager_Timer
	event_manager_timer_init(&urgent_due, clock_add(clock_now(), -time.Second), event_manager_test_on_timer, .Urgent)
	event_manager_test_timer_fired = 0
	handled, herr = event_manager_handle_urgent_events()
	testing.expect_value(t, herr, Event_Manager_Error.None)
	testing.expect(t, !handled)
	testing.expect_value(t, event_manager_test_timer_fired, 1)
	testing.expect_value(t, urgent_due.date, clock_max())
	event_manager_timer_destroy(&due)
	event_manager_timer_destroy(&future)
	event_manager_timer_destroy(&urgent_due)

	// A Normal timer postponed by an Urgent round fires on the next
	// Normal round after its 10ms delay elapses.
	event_manager_test_timer_fired = 0
	mismatched: Event_Manager_Timer
	event_manager_timer_init(&mismatched, clock_add(clock_now(), -time.Second), event_manager_test_on_timer)
	handled, herr = event_manager_handle_next_events(.Urgent, time.Duration(0))
	testing.expect_value(t, event_manager_test_timer_fired, 0)
	testing.expect(t, mismatched.date > clock_now())
	time.sleep(50 * time.Millisecond)
	handled, herr = event_manager_handle_next_events(.Normal, time.Duration(0))
	testing.expect_value(t, event_manager_test_timer_fired, 1)
	testing.expect_value(t, mismatched.date, clock_max())
	event_manager_timer_destroy(&mismatched)

	// A timer unregistered by an earlier callback in the same round is
	// skipped (killer runs first: it was registered first).
	event_manager_test_timer_fired = 0
	victim: Event_Manager_Timer
	killer: Event_Manager_Timer
	event_manager_test_victim = &victim
	event_manager_timer_init(&killer, clock_add(clock_now(), -time.Second), event_manager_test_on_timer_killer)
	event_manager_timer_init(&victim, clock_add(clock_now(), -time.Second), event_manager_test_on_timer)
	handled, herr = event_manager_handle_next_events(.Normal, time.Duration(0))
	testing.expect_value(t, event_manager_test_timer_fired, 1)
	testing.expect(t, victim.date < clock_max()) // never ran, never parked
	testing.expect_value(t, killer.date, clock_max())
	testing.expect(t, event_manager_test_victim == nil)
	event_manager_timer_destroy(&killer)
	testing.expect_value(t, len(manager.timers), 0)

	// A nil timeout blocks until activity: the helper thread writes one
	// byte after 20ms and the round reports it.
	rfd6, wfd6 := event_manager_test_make_pipe(t)
	defer posix.close(posix.FD(rfd6))
	block_watcher: Event_Manager_Fd_Watcher
	event_manager_fd_watcher_init(&block_watcher, rfd6, {.Read}, .Normal, event_manager_test_on_fd)
	event_manager_test_fd_fired = 0
	event_manager_test_writer_fd = wfd6
	writer := thread.create_and_start(event_manager_test_pipe_writer)
	handled, herr = event_manager_handle_next_events(.Normal, nil)
	thread.join(writer)
	thread.destroy(writer)
	testing.expect_value(t, herr, Event_Manager_Error.None)
	testing.expect(t, handled)
	testing.expect_value(t, event_manager_test_fd_fired, 1)
	testing.expect_value(t, event_manager_test_read_byte(t, rfd6), 'x')
	event_manager_fd_watcher_destroy(&block_watcher)

	// File I/O with a manager installed (non-blocking pump wiring).
	io_tmp := strings.concatenate({file_tmpdir(), "/kak_event_manager_test_io"}, context.temp_allocator)
	os.remove(io_tmp)
	testing.expect_value(t, file_write_to_file(io_tmp, "hello"), File_Error.None)
	io_content, io_err := file_read_file(io_tmp)
	testing.expect_value(t, io_err, File_Error.None)
	testing.expect_value(t, io_content, "hello")
	delete(io_content)
	io_fd, io_cerr := file_create_file(io_tmp)
	testing.expect_value(t, io_cerr, File_Error.None)
	testing.expect(t, io_fd >= 0)
	posix.close(posix.FD(io_fd))
	os.remove(io_tmp)
	testing.expect(t, !file_exists(io_tmp))

	// Teardown uninstalls; urgent polling is a no-op again.
	testing.expect_value(t, len(manager.fd_watchers), 0)
	testing.expect_value(t, len(manager.timers), 0)
	event_manager_destroy(&manager)
	testing.expect(t, !event_manager_has_instance())
	handled, herr = event_manager_handle_urgent_events()
	testing.expect(t, !handled)
	testing.expect_value(t, herr, Event_Manager_Error.None)
}
