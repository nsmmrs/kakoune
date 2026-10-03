package kak

import "core:testing"

// knot.odin holds shared type declarations only; these tests pin the
// enumerator order/counts imported from C++ and prove the big structs
// are constructible (agents implement the procedures).

@(test)
test_knot_enumerator_counts :: proc(t: ^testing.T) {
	// Last enumerator of each C++ enum class, in declaration order.
	testing.expect_value(t, int(Hook.User), 42)
	testing.expect_value(t, int(Token_Type.Command_Separator), 9)
	testing.expect_value(t, int(Buffer_Flags_Flag.Locked), 8)
	testing.expect_value(t, int(Input_Handler_Insert_Mode.Open_Line_Above), 6)
	testing.expect_value(t, int(Client_Pending_Ui_Flag.Refresh), 7)
	testing.expect_value(t, int(Direction.Forward), 1)
	testing.expect_value(t, int(Direction.Backward), -1)
	testing.expect_value(t, int(buffer_HISTORY_INVALID), -1)
}

@(test)
test_knot_bitsets :: proc(t: ^testing.T) {
	flags := Buffer_Flags{.File, .Locked}
	testing.expect(t, .File in flags)
	testing.expect(t, .Locked in flags)
	testing.expect(t, .Fifo not_in flags)
	passes := Highlight_Pass{.Replace, .Colorize}
	testing.expect(t, .Replace in passes)
	testing.expect(t, .Wrap not_in passes)
}

@(test)
test_knot_option_value_union :: proc(t: ^testing.T) {
	// Every declare_option<T> instantiation must fit the union.
	values := make([dynamic]Option_Value, context.allocator)
	defer delete(values)
	append(&values, 42)
	append(&values, true)
	append(&values, "str")
	ds := make([dynamic]string, context.allocator)
	defer delete(ds)
	append(&ds, "a")
	append(&values, ds)
	di := make([dynamic]int, context.allocator)
	defer delete(di)
	append(&di, 1)
	append(&values, di)
	dr := make([dynamic]rune, context.allocator)
	defer delete(dr)
	append(&dr, 'x')
	append(&values, dr)
	append(&values, Regex{})
	append(&values, Coord_Display{})
	append(&values, Insert_Completer_Completion_List{})
	append(&values, Option_Timestamped_List(Line_And_Spec){})
	append(&values, Option_Timestamped_List(Range_And_String){})
	m := make(map[string]string, context.allocator)
	defer delete(m)
	m["k"] = "v"
	append(&values, m)
	testing.expect_value(t, len(values), 12)
	n_int := 0
	for v in values {
		if _, ok := v.(int); ok {
			n_int += 1
		}
	}
	testing.expect_value(t, n_int, 1)
}

@(test)
test_knot_core_structs_construct :: proc(t: ^testing.T) {
	b: Buffer
	testing.expect_value(t, b.history_id, Buffer_History_Id(0))
	ctx: Context
	testing.expect(t, ctx.window == nil)
	w: Window
	testing.expect(t, w.buffer == nil)
	c: Client
	testing.expect_value(t, c.pid, 0)
	ih: Input_Handler
	// Zero value is 0; the C++ -1 default is established by the init
	// proc (agents), not the type declaration.
	testing.expect_value(t, ih.recording_level, 0)
	om: Option_Manager
	testing.expect(t, om.parent == nil)
	hm: Hook_Manager
	testing.expect_value(t, len(hm.hooks), 43)
	sm: Shell_Manager
	testing.expect_value(t, sm.shell, "")
	srv: Server
	testing.expect(t, srv.is_daemon == false)
	_ = t
}
