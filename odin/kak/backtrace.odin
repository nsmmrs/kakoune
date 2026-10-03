// Stack backtraces ported from src/backtrace.{hh,cc} (glibc path).
//
// Linux-first like the rest of the port: frames come from libc
// backtrace(3)/backtrace_symbols(3) via a foreign import.
package kak

import "core:c"
import "core:fmt"
import "core:strings"

foreign import backtrace_libc "system:c"

@(default_calling_convention = "c")
foreign backtrace_libc {
	@(link_name = "backtrace")
	backtrace_c :: proc(stackframes: [^]rawptr, size: c.int) -> c.int ---
	@(link_name = "backtrace_symbols")
	backtrace_symbols_c :: proc(stackframes: [^]rawptr, size: c.int) -> [^]cstring ---
	@(link_name = "free")
	backtrace_free :: proc(ptr: rawptr) ---
}

// Backtrace_Error is the per-module error enum. Capture cannot fail;
// an empty capture yields an empty description.
Backtrace_Error :: enum {
	None,
}

// Backtrace_Max_Frames caps capture (C++ Backtrace::max_frames).
Backtrace_Max_Frames :: 16

// Backtrace holds captured stack frames (C++ Backtrace).
Backtrace :: struct {
	frames: [Backtrace_Max_Frames]rawptr,
	num:    int,
}

// backtrace_make captures the current stack (C++ Backtrace ctor).
backtrace_make :: proc() -> Backtrace {
	bt: Backtrace
	bt.num = int(backtrace_c(raw_data(bt.frames[:]), Backtrace_Max_Frames))
	if bt.num < 0 {
		bt.num = 0
	}
	return bt
}

// backtrace_desc_of renders captured frames, one symbol per line
// (C++ Backtrace::desc). The result is owned (allocator).
backtrace_desc_of :: proc(bt: ^Backtrace, allocator := context.allocator) -> string {
	if bt.num <= 0 {
		return ""
	}
	syms := backtrace_symbols_c(raw_data(bt.frames[:]), c.int(bt.num))
	if syms == nil {
		return ""
	}
	defer backtrace_free(syms)
	b := strings.builder_make(allocator)
	for i in 0 ..< bt.num {
		fmt.sbprintf(&b, "%s\n", string(syms[i]))
	}
	return strings.to_string(b)
}

// backtrace_desc captures and renders the current stack in one call.
// The result is owned (allocator).
backtrace_desc :: proc(allocator := context.allocator) -> string {
	bt := backtrace_make()
	return backtrace_desc_of(&bt, allocator)
}
