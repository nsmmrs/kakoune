// Port of Kakoune's src/debug.hh and src/debug.cc: the *debug* buffer
// sink. DebugFlags itself lives in the option_types module
// (Option_types_Debug_Flags), which already ports the enum and its
// names; this module only implements the writer.
//
// Like the C++, writing with no buffer manager falls back to stderr,
// and the debug buffer keeps a trailing empty line for the user's
// cursor. There is no Debug_Error: both procs are infallible by
// construction (writes to a live buffer cannot fail once ReadOnly is
// lifted, and creation uses a provably fresh name).
package kak

import "core:strings"

// debug_write_to_debug_buffer appends str to the *debug* buffer,
// creating it (NoUndo, Debug, ReadOnly) on first use (port of C++
// write_to_debug_buffer()).
debug_write_to_debug_buffer :: proc(str: string) {
	if !buffer_manager_has_instance {
		file_write(2, str)
		file_write(2, "\n")
		return
	}
	eol_back := len(str) != 0 && str[len(str) - 1] == '\n'
	if buf := buffer_manager_get_ifp(buffer_manager_instance(), "*debug*"); buf != nil {
		buf.flags -= {.Read_Only}
		defer buf.flags += {.Read_Only}
		text := str
		owned := ""
		if !eol_back {
			owned = strings.concatenate({str, "\n"}, context.temp_allocator)
			text = owned
		}
		_, insert_err := buffer_insert(buf, buffer_back_coord(buf), text)
		assert(insert_err == .None)
	} else {
		line := strings.concatenate({str, eol_back ? "\n" : "\n\n"}, context.temp_allocator)
		_, create_err := buffer_utils_create_buffer_from_string(
			"*debug*",
			{.No_Undo, .Debug, .Read_Only},
			line,
		)
		assert(create_err == .None)
	}
}

// debug_write_to_buffer writes str to the *debug* buffer. The client
// and input-handler ports call write_to_debug_buffer() by this name;
// it forwards to debug_write_to_debug_buffer().
debug_write_to_buffer :: proc(s: string) {
	debug_write_to_debug_buffer(s)
}
