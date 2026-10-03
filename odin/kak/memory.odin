// Port of Kakoune's src/memory.{hh,cc}.
//
// Meaningful in Odin: the Memory_Domain enum, the per-domain
// Memory_Stats counters, and memory_on_alloc/memory_on_dealloc (consumed by
// the `:debug`-style memory reporting in commands.cc).
//
// Subsumed by context allocators (intentionally not ported):
//   - `Allocator<T, domain>` (the STL allocator adapter): Odin procs take
//     `allocator := context.allocator` and forward it instead.
//   - `UseMemoryDomain<d>` operator new/delete overloads: Odin has no
//     per-type `new` overloads; track with `core:mem.Tracking_Allocator`
//     wrapping `context.allocator` when accounting is needed.
//   - `memory_domain()` / `Meta::Type` dispatch: no equivalent needed.
//   - The global accounting itself is kept here (not routed through a
//     Tracking_Allocator) so domain reporting stays available to callers.
package kak

// Memory_Domain classifies allocations for accounting. `Undefined` must
// stay the zero value and `Count` the last member (it sizes memory_stats).
Memory_Domain :: enum {
	Undefined,
	String,
	SharedString,
	BufferContent,
	BufferMeta,
	Options,
	Highlight,
	Regions,
	Display,
	Mapping,
	Commands,
	Hooks,
	Aliases,
	EnvVars,
	Faces,
	Values,
	Registers,
	Client,
	WordDB,
	Selections,
	Remote,
	Events,
	Completion,
	Regex,
	Count,
}

// Memory_Stats holds one domain's accounting counters.
Memory_Stats :: struct {
	allocated_bytes:        uint,
	allocation_count:       uint,
	total_allocation_count: uint,
}

// memory_stats is the global per-domain accounting table, indexed by
// domain. Ports C++ `memory_stats`.
memory_stats: [int(Memory_Domain.Count)]Memory_Stats

// memory_domain_name returns the C++ `domain_name` string for a domain.
// `Count` has no name in C++ (the switch asserts); it maps to "" here.
memory_domain_name :: proc(domain: Memory_Domain) -> string {
	switch domain {
	case .Undefined:
		return "Undefined"
	case .String:
		return "String"
	case .SharedString:
		return "SharedString"
	case .BufferContent:
		return "BufferContent"
	case .BufferMeta:
		return "BufferMeta"
	case .Options:
		return "Options"
	case .Highlight:
		return "Highlight"
	case .Regions:
		return "Regions"
	case .Display:
		return "Display"
	case .Mapping:
		return "Mapping"
	case .Commands:
		return "Commands"
	case .Hooks:
		return "Hooks"
	case .Aliases:
		return "Aliases"
	case .EnvVars:
		return "EnvVars"
	case .Faces:
		return "Faces"
	case .Values:
		return "Values"
	case .Registers:
		return "Registers"
	case .Client:
		return "Client"
	case .WordDB:
		return "WordDB"
	case .Selections:
		return "Selections"
	case .Remote:
		return "Remote"
	case .Events:
		return "Events"
	case .Completion:
		return "Completion"
	case .Regex:
		return "Regex"
	case .Count:
		return ""
	}
	unreachable()
}

// memory_on_alloc records an allocation of `size` bytes in `domain`.
// Ports C++ `on_alloc`.
memory_on_alloc :: proc(domain: Memory_Domain, size: uint) {
	stats := &memory_stats[int(domain)]
	stats.allocated_bytes += size
	stats.allocation_count += 1
	stats.total_allocation_count += 1
}

// memory_on_dealloc records a deallocation of `size` bytes in `domain`.
// Ports C++ `on_dealloc` (the C++ `kak_assert` becomes a plain assert).
memory_on_dealloc :: proc(domain: Memory_Domain, size: uint) {
	stats := &memory_stats[int(domain)]
	assert(stats.allocated_bytes >= size)
	stats.allocated_bytes -= size
	stats.allocation_count -= 1
}
