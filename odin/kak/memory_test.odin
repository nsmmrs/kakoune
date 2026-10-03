// Tests for the memory module ported from src/memory.hh.
// No C++ UnitTest covers memory.hh; these assert the ported behavior.
package kak

import "core:testing"

// Every domain maps to its C++ domain_name() string.
@(test)
memory_test_domain_names :: proc(t: ^testing.T) {
	testing.expect_value(t, memory_domain_name(.Undefined), "Undefined")
	testing.expect_value(t, memory_domain_name(.String), "String")
	testing.expect_value(t, memory_domain_name(.SharedString), "SharedString")
	testing.expect_value(t, memory_domain_name(.BufferContent), "BufferContent")
	testing.expect_value(t, memory_domain_name(.BufferMeta), "BufferMeta")
	testing.expect_value(t, memory_domain_name(.Options), "Options")
	testing.expect_value(t, memory_domain_name(.Highlight), "Highlight")
	testing.expect_value(t, memory_domain_name(.Regions), "Regions")
	testing.expect_value(t, memory_domain_name(.Display), "Display")
	testing.expect_value(t, memory_domain_name(.Mapping), "Mapping")
	testing.expect_value(t, memory_domain_name(.Commands), "Commands")
	testing.expect_value(t, memory_domain_name(.Hooks), "Hooks")
	testing.expect_value(t, memory_domain_name(.Aliases), "Aliases")
	testing.expect_value(t, memory_domain_name(.EnvVars), "EnvVars")
	testing.expect_value(t, memory_domain_name(.Faces), "Faces")
	testing.expect_value(t, memory_domain_name(.Values), "Values")
	testing.expect_value(t, memory_domain_name(.Registers), "Registers")
	testing.expect_value(t, memory_domain_name(.Client), "Client")
	testing.expect_value(t, memory_domain_name(.WordDB), "WordDB")
	testing.expect_value(t, memory_domain_name(.Selections), "Selections")
	testing.expect_value(t, memory_domain_name(.Remote), "Remote")
	testing.expect_value(t, memory_domain_name(.Events), "Events")
	testing.expect_value(t, memory_domain_name(.Completion), "Completion")
	testing.expect_value(t, memory_domain_name(.Regex), "Regex")
}

// Count is the sentinel: no name, like the C++ fallthrough.
@(test)
memory_test_count_has_no_name :: proc(t: ^testing.T) {
	testing.expect_value(t, memory_domain_name(.Count), "")
}

// Enum layout: Undefined is zero, Count sizes the stats table.
@(test)
memory_test_enum_layout :: proc(t: ^testing.T) {
	testing.expect_value(t, int(Memory_Domain.Undefined), 0)
	testing.expect_value(t, len(memory_stats), int(Memory_Domain.Count))
	testing.expect_value(t, int(Memory_Domain.Count), 24)
}

// on_alloc accumulates bytes and both counters.
@(test)
memory_test_on_alloc :: proc(t: ^testing.T) {
	before := memory_stats[int(Memory_Domain.String)]
	memory_on_alloc(.String, 100)
	memory_on_alloc(.String, 50)
	after := memory_stats[int(Memory_Domain.String)]
	testing.expect_value(t, after.allocated_bytes - before.allocated_bytes, uint(150))
	testing.expect_value(t, after.allocation_count - before.allocation_count, uint(2))
	testing.expect_value(t, after.total_allocation_count - before.total_allocation_count, uint(2))
	memory_on_dealloc(.String, 100)
	memory_on_dealloc(.String, 50)
}

// on_dealloc releases bytes and the live count but not the total.
@(test)
memory_test_on_dealloc :: proc(t: ^testing.T) {
	memory_on_alloc(.BufferMeta, 64)
	before := memory_stats[int(Memory_Domain.BufferMeta)]
	memory_on_dealloc(.BufferMeta, 64)
	after := memory_stats[int(Memory_Domain.BufferMeta)]
	testing.expect_value(t, before.allocated_bytes - after.allocated_bytes, uint(64))
	testing.expect_value(t, before.allocation_count - after.allocation_count, uint(1))
	testing.expect_value(t, after.total_allocation_count - before.total_allocation_count, uint(0))
}

// Domains are accounted independently.
@(test)
memory_test_domains_independent :: proc(t: ^testing.T) {
	before_display := memory_stats[int(Memory_Domain.Display)]
	before_hooks := memory_stats[int(Memory_Domain.Hooks)]
	memory_on_alloc(.Display, 8)
	after_display := memory_stats[int(Memory_Domain.Display)]
	after_hooks := memory_stats[int(Memory_Domain.Hooks)]
	testing.expect_value(t, after_display.allocation_count - before_display.allocation_count, uint(1))
	testing.expect_value(t, after_hooks, before_hooks)
	memory_on_dealloc(.Display, 8)
}

// Zero-size alloc still counts as one allocation, like the C++.
@(test)
memory_test_zero_size_alloc :: proc(t: ^testing.T) {
	before := memory_stats[int(Memory_Domain.Regex)]
	memory_on_alloc(.Regex, 0)
	after := memory_stats[int(Memory_Domain.Regex)]
	testing.expect_value(t, after.allocated_bytes - before.allocated_bytes, uint(0))
	testing.expect_value(t, after.allocation_count - before.allocation_count, uint(1))
	memory_on_dealloc(.Regex, 0)
}
