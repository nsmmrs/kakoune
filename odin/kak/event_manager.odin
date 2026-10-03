// Port of Kakoune's src/event_manager.{hh,cc}: fd watchers, timers, and
// the pselect-based dispatch loop.
//
// Ownership: the caller owns every struct. event_manager_init installs
// the singleton (like the C++ Singleton constructor asserting no prior
// instance); event_manager_destroy uninstalls it and frees the watcher
// lists with the allocator given to init. FDWatcher/Timer structs are
// caller-owned (typically stack slots) that register their own address
// on init and unregister on destroy, exactly like the C++ objects that
// push `this` into the manager vectors.
//
// Callbacks are plain proc values (no closures); state reaches them via
// globals or context.user_ptr. A nil timer callback means "never
// registered", mirroring the C++ empty-Function check.
//
// Reuses Clock_Time/clock_now/clock_max/clock_add from clock.odin.
package kak

import "core:c"
import "core:time"
import posix "core:sys/posix"

// Event_Manager_Error is the module error. Zero value `None` is success.
Event_Manager_Error :: enum {
	None,
	// pselect failed with an errno other than EINTR. The returned
	// `handled` bit still follows the C++ `res > 0` exactly (false
	// here); forced fds and due timers were serviced before returning.
	Select_Failed,
	// sigaction failed in event_manager_set_signal_handler (the C++
	// ignores the failure; here it is reported).
	Signal_Failed,
}

// Event_Manager_Mode selects which watchers a dispatch round services.
// An Urgent round skips Normal watchers; a Normal round runs everything.
Event_Manager_Mode :: enum {
	Normal,
	Urgent,
}

// Event_Manager_Fd_Event is one selectable fd condition (port of the
// FdEvents bit constants; the empty set is FdEvents::None).
Event_Manager_Fd_Event :: enum {
	Read,
	Write,
	Except,
}

// Event_Manager_Fd_Events is a set of selectable fd conditions.
Event_Manager_Fd_Events :: bit_set[Event_Manager_Fd_Event; u8]

// Event_Manager_Fd_Watcher_Callback runs when a watched fd fires.
Event_Manager_Fd_Watcher_Callback :: #type proc(watcher: ^Event_Manager_Fd_Watcher, events: Event_Manager_Fd_Events, mode: Event_Manager_Mode)

// Event_Manager_Fd_Watcher watches one fd for events. Register with
// event_manager_fd_watcher_init, unregister with
// event_manager_fd_watcher_destroy. `fd == -1` disables the watcher.
Event_Manager_Fd_Watcher :: struct {
	fd:       int,
	events:   Event_Manager_Fd_Events,
	mode:     Event_Manager_Mode,
	callback: Event_Manager_Fd_Watcher_Callback,
}

// Event_Manager_Timer_Callback runs when a timer fires in its own mode.
Event_Manager_Timer_Callback :: #type proc(timer: ^Event_Manager_Timer)

// Event_Manager_Timer fires once at `date`. Register with
// event_manager_timer_init, unregister with event_manager_timer_destroy.
// A nil callback is never registered (port of the C++ empty check).
Event_Manager_Timer :: struct {
	date:     Clock_Time,
	mode:     Event_Manager_Mode,
	callback: Event_Manager_Timer_Callback,
}

// Event_Manager holds the watcher lists and the forced-fd set. Use
// event_manager_init/destroy; the singleton half mirrors C++ Singleton.
Event_Manager :: struct {
	fd_watchers: [dynamic]^Event_Manager_Fd_Watcher,
	timers:      [dynamic]^Event_Manager_Timer,
	forced:      posix.fd_set,
	has_forced:  bool,
}

// event_manager_singleton is the installed manager, if any (port of
// Singleton<EventManager>::ms_instance).
event_manager_singleton: ^Event_Manager

// event_manager_make returns an initialized manager without installing
// it. Prefer event_manager_init, which also installs the singleton.
event_manager_make :: proc(allocator := context.allocator) -> Event_Manager {
	m: Event_Manager
	m.fd_watchers = make([dynamic]^Event_Manager_Fd_Watcher, allocator)
	m.timers = make([dynamic]^Event_Manager_Timer, allocator)
	posix.FD_ZERO(&m.forced)
	return m
}

// event_manager_init initializes m and installs it as the singleton,
// asserting none is installed (like the C++ constructor).
event_manager_init :: proc(m: ^Event_Manager, allocator := context.allocator) {
	assert(event_manager_singleton == nil)
	m^ = event_manager_make(allocator)
	event_manager_singleton = m
}

// event_manager_destroy uninstalls m and frees its lists. Like the C++
// destructor, it asserts no watchers or timers are still registered.
event_manager_destroy :: proc(m: ^Event_Manager) {
	assert(len(m.fd_watchers) == 0)
	assert(len(m.timers) == 0)
	assert(event_manager_singleton == m)
	event_manager_singleton = nil
	delete(m.fd_watchers)
	delete(m.timers)
}

// event_manager_has_instance reports whether a manager is installed.
event_manager_has_instance :: proc() -> bool {
	return event_manager_singleton != nil
}

// event_manager_instance returns the installed manager, asserting one
// is installed (like Singleton::instance).
event_manager_instance :: proc() -> ^Event_Manager {
	assert(event_manager_singleton != nil)
	return event_manager_singleton
}

// event_manager_unordered_erase removes the first occurrence of val by
// swapping with the last element. Missing values are a no-op, exactly
// like C++ unordered_erase.
event_manager_unordered_erase :: proc(arr: ^[dynamic]$T, val: T) {
	for i := 0; i < len(arr); i += 1 {
		if arr[i] == val {
			arr[i] = arr[len(arr) - 1]
			pop(arr)
			return
		}
	}
}

// event_manager_fd_watcher_init registers w with the installed manager
// (which must exist, like the C++ constructor calling instance()).
event_manager_fd_watcher_init :: proc(w: ^Event_Manager_Fd_Watcher, fd: int, events: Event_Manager_Fd_Events, mode: Event_Manager_Mode, callback: Event_Manager_Fd_Watcher_Callback) {
	w.fd = fd
	w.events = events
	w.mode = mode
	w.callback = callback
	append(&event_manager_instance().fd_watchers, w)
}

// event_manager_fd_watcher_destroy unregisters w. Like C++
// unordered_erase, destroying an unregistered watcher is a no-op.
event_manager_fd_watcher_destroy :: proc(w: ^Event_Manager_Fd_Watcher) {
	if event_manager_has_instance() {
		event_manager_unordered_erase(&event_manager_instance().fd_watchers, w)
	}
}

// event_manager_fd_watcher_run invokes the watcher's callback.
event_manager_fd_watcher_run :: proc(w: ^Event_Manager_Fd_Watcher, events: Event_Manager_Fd_Events, mode: Event_Manager_Mode) {
	w.callback(w, events, mode)
}

// event_manager_fd_watcher_reset_fd repoints the watcher at a new fd.
event_manager_fd_watcher_reset_fd :: proc(w: ^Event_Manager_Fd_Watcher, fd: int) {
	w.fd = fd
}

// event_manager_fd_watcher_close_fd closes the watched fd (if any) and
// disables the watcher. The close result is ignored, like the C++.
event_manager_fd_watcher_close_fd :: proc(w: ^Event_Manager_Fd_Watcher) {
	if w.fd != -1 {
		posix.close(posix.FD(w.fd))
		w.fd = -1
	}
}

// event_manager_fd_watcher_disable stops watching without closing.
event_manager_fd_watcher_disable :: proc(w: ^Event_Manager_Fd_Watcher) {
	w.fd = -1
}

// event_manager_timer_init registers t unless the callback is nil or no
// manager is installed (port of the C++ constructor condition).
event_manager_timer_init :: proc(t: ^Event_Manager_Timer, date: Clock_Time, callback: Event_Manager_Timer_Callback, mode := Event_Manager_Mode.Normal) {
	t.date = date
	t.mode = mode
	t.callback = callback
	if callback != nil && event_manager_has_instance() {
		append(&event_manager_instance().timers, t)
	}
}

// event_manager_timer_destroy unregisters t under the same condition
// the constructor registers (nil callback or no manager: no-op).
event_manager_timer_destroy :: proc(t: ^Event_Manager_Timer) {
	if t.callback != nil && event_manager_has_instance() {
		event_manager_unordered_erase(&event_manager_instance().timers, t)
	}
}

// event_manager_timer_disable parks the timer at the max sentinel so it
// never fires.
event_manager_timer_disable :: proc(t: ^Event_Manager_Timer) {
	t.date = clock_max()
}

// event_manager_timer_run fires the timer: in its own mode it parks at
// the max sentinel and invokes the callback; in the other mode it is
// postponed by 10ms (port of Timer::run).
event_manager_timer_run :: proc(t: ^Event_Manager_Timer, mode: Event_Manager_Mode) {
	assert(t.callback != nil)
	if mode == t.mode {
		t.date = clock_max()
		t.callback(t)
	} else {
		t.date = clock_add(clock_now(), 10 * time.Millisecond)
	}
}

// event_manager_handle_next_events waits for (nil timeout: blocks until)
// the next fd event or due timer, dispatches it, and reports whether
// pselect saw activity (`res > 0`, exactly like the C++ return).
//
// A pending forced fd clears the timeout (port of `timeout.reset()`),
// and the earliest timer clamps it. EINTR from pselect is success with
// `handled == false`; other errnos yield .Select_Failed.
event_manager_handle_next_events :: proc(mode: Event_Manager_Mode, timeout: Maybe(time.Duration) = nil, sigmask: ^posix.sigset_t = nil) -> (handled: bool, err: Event_Manager_Error) {
	m := event_manager_instance()

	max_fd := 0
	rfds, wfds, efds: posix.fd_set
	posix.FD_ZERO(&rfds)
	posix.FD_ZERO(&wfds)
	posix.FD_ZERO(&efds)
	for w in m.fd_watchers {
		if w.mode == .Normal && mode == .Urgent {
			continue
		}
		fd := w.fd
		if fd == -1 {
			continue
		}
		// Deviation: out-of-range fds are undefined behavior in C++
		// (raw FD_SET); here they are skipped.
		if fd < 0 || fd >= posix.FD_SETSIZE {
			continue
		}
		max_fd = max(fd, max_fd)
		if .Read in w.events {
			posix.FD_SET(posix.FD(fd), &rfds)
		}
		if .Write in w.events {
			posix.FD_SET(posix.FD(fd), &wfds)
		}
		if .Except in w.events {
			posix.FD_SET(posix.FD(fd), &efds)
		}
	}

	effective := timeout
	if m.has_forced {
		effective = nil
	}

	if len(m.timers) > 0 {
		next := m.timers[0].date
		for t in m.timers[1:] {
			if t.date < next {
				next = t.date
			}
		}
		if next != clock_max() {
			remaining := clock_diff(clock_now(), next)
			remaining = max(remaining, time.Duration(0))
			if current, ok := effective.?; ok {
				effective = min(current, remaining)
			} else {
				effective = remaining
			}
		}
	}

	ts: posix.timespec
	ts_ptr: ^posix.timespec
	if limit, ok := effective.?; ok {
		// Truncation toward zero matches duration_cast<seconds>.
		total := i64(limit)
		ts = posix.timespec {
			tv_sec  = posix.time_t(total / 1_000_000_000),
			tv_nsec = c.long(total % 1_000_000_000),
		}
		ts_ptr = &ts
	}

	res := posix.pselect(c.int(max_fd + 1), &rfds, &wfds, &efds, ts_ptr, sigmask)
	// Capture immediately: callbacks below may clobber errno.
	select_errno := posix.errno()

	// Copy forced fds *after* select so handlers that fired during the
	// call are serviced in this round (port of the C++ comment).
	m.has_forced = false
	forced := m.forced
	posix.FD_ZERO(&m.forced)

	for fd := 0; fd < max_fd + 1; fd += 1 {
		events: Event_Manager_Fd_Events
		if posix.FD_ISSET(posix.FD(fd), &forced) {
			events += {.Read}
		}
		if res > 0 {
			if posix.FD_ISSET(posix.FD(fd), &rfds) {
				events += {.Read}
			}
			if posix.FD_ISSET(posix.FD(fd), &wfds) {
				events += {.Write}
			}
			if posix.FD_ISSET(posix.FD(fd), &efds) {
				events += {.Except}
			}
		}
		if events != {} {
			for w in m.fd_watchers {
				if w.fd == fd {
					event_manager_fd_watcher_run(w, events, mode)
					break
				}
			}
		}
	}

	// Copy the timer list: callbacks may register/unregister timers.
	now := clock_now()
	pending := make([dynamic]^Event_Manager_Timer, 0, len(m.timers), context.temp_allocator)
	defer delete(pending)
	append(&pending, ..m.timers[:])
	for t in pending {
		still_registered := false
		for current in m.timers {
			if current == t {
				still_registered = true
				break
			}
		}
		if still_registered && t.date <= now {
			event_manager_timer_run(t, mode)
		}
	}

	if res > 0 {
		return true, .None
	}
	if res == 0 || select_errno == .EINTR {
		return false, .None
	}
	return false, .Select_Failed
}

// event_manager_force_signal marks fd so its watcher runs with a Read
// event on the next dispatch round (serviced even if pselect saw no
// activity). Out-of-range fds are ignored (C++ FD_SET would be UB).
event_manager_force_signal :: proc(fd: int) {
	if fd < 0 || fd >= posix.FD_SETSIZE {
		return
	}
	m := event_manager_instance()
	posix.FD_SET(posix.FD(fd), &m.forced)
	m.has_forced = true
}

// event_manager_handle_urgent_events polls urgent watchers and timers
// once (zero timeout), if a manager is installed. It reports the
// round outcome; without a manager it is a (false, .None) no-op.
event_manager_handle_urgent_events :: proc() -> (handled: bool, err: Event_Manager_Error) {
	if event_manager_has_instance() {
		return event_manager_handle_next_events(.Urgent, time.Duration(0))
	}
	return false, .None
}

// Event_Manager_Signal_Handler is a C signal handler (port of C++
// SignalHandler).
Event_Manager_Signal_Handler :: #type proc "c" (posix.Signal)

// event_manager_set_signal_handler installs handler for signum with
// SA_RESTART and returns the previous handler (port of
// set_signal_handler; the C++ ignores sigaction failure, here it
// yields (.Signal_Failed) with a nil handler).
event_manager_set_signal_handler :: proc(signum: posix.Signal, handler: Event_Manager_Signal_Handler) -> (old: Event_Manager_Signal_Handler, err: Event_Manager_Error) {
	new_action, old_action: posix.sigaction_t
	posix.sigemptyset(&new_action.sa_mask)
	new_action.sa_handler = handler
	new_action.sa_flags = {.RESTART}
	if posix.sigaction(signum, &new_action, &old_action) != .OK {
		return nil, .Signal_Failed
	}
	return old_action.sa_handler, .None
}
