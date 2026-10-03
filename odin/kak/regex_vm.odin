// Regex compiler and threaded VM ported from src/regex_vm.{hh,cc}.
//
// This is a Pike-style threaded NFA: regex_vm_compile parses the pattern
// into an AST and emits bytecode, and Regex_Vm executes it. Positions are
// byte offsets into the subject string (the C++ uses char iterators;
// offsets are the equivalent here, matching the merged utf8 module).
//
// Ownership: regex_vm_compile returns an owned Regex_Vm_Compiled in
// `allocator` (release with regex_vm_compiled_destroy, same allocator).
// On failure it returns an owned error message string instead (delete it);
// the program is zero and must not be destroyed. Regex_Vm borrows its
// program (the program must outlive the VM) and owns its thread/saves
// state (release with regex_vm_destroy). regex_vm_captures returns a
// borrowed slice of save pairs, valid until the next exec or destroy;
// -1 marks an unmatched save.
//
// Fidelity notes vs the C++ implementation:
//   - \d matches ASCII digits plus core:unicode numbers (C++ uses
//     locale-dependent iswdigit); \w uses unicode_is_word, so non-ASCII
//     alphanumerics come from core:unicode tables rather than iswalnum.
//   - Instruction deduplication marks live in the VM, not on the
//     program (the C++ mutates CompiledRegex.last_step during exec),
//     so one program can back several VMs. Behavior is identical.
package kak

import "core:mem"
import "core:slice"
import "core:strings"
import "core:unicode"

// Regex_Vm_Error reports compilation failures. Zero value None is success;
// detail is carried by the message string returned next to the error.
Regex_Vm_Error :: enum {
	None,
	Compile_Error,
}

// Regex_Vm_Char_Type is one character-class escape bit (\d \w \s \h and
// negations). Order matches the C++ bit values so transmute(u8) round-trips.
Regex_Vm_Char_Type :: enum u8 {
	Whitespace,
	Horizontal_Whitespace,
	Word,
	Digit,
	Not_Whitespace,
	Not_Horizontal_Whitespace,
	Not_Word,
	Not_Digit,
}

// Regex_Vm_Char_Types is a combination of character type bits
// (C++ CharacterType with bit ops).
Regex_Vm_Char_Types :: bit_set[Regex_Vm_Char_Type; u8]

// Regex_Vm_Char_Range is one inclusive codepoint interval of a class.
Regex_Vm_Char_Range :: struct {
	min, max: rune,
}

// Regex_Vm_Char_Class is a [...] class: sorted merged ranges plus type
// bits, with negative/ignore_case flags (C++ CharacterClass).
Regex_Vm_Char_Class :: struct {
	ranges:      [dynamic]Regex_Vm_Char_Range,
	ctypes:      Regex_Vm_Char_Types,
	negative:    bool,
	ignore_case: bool,
}

// Regex_Vm_Op is one bytecode operation (C++ CompiledRegex::Op).
Regex_Vm_Op :: enum u8 {
	Match,
	Literal,
	Any_Char,
	Any_Char_Except_New_Line,
	Char_Range,
	Char_Type,
	Char_Class,
	Jump,
	Split,
	Save,
	Line_Assertion,
	Subject_Assertion,
	Word_Boundary,
	Look_Around,
}

// Regex_Vm_Literal matches one codepoint, optionally case-insensitively.
Regex_Vm_Literal :: struct {
	codepoint:   rune,
	ignore_case: bool,
}

// Regex_Vm_Range_Param matches one single-byte range (C++ CharRange).
Regex_Vm_Range_Param :: struct {
	min:         u8,
	max:         u8,
	ignore_case: bool,
	negative:    bool,
}

// Regex_Vm_Class_Param refers to a Regex_Vm_Char_Class by index.
Regex_Vm_Class_Param :: struct {
	index: int,
}

// Regex_Vm_Jump_Param jumps by a relative instruction offset.
Regex_Vm_Jump_Param :: struct {
	offset: int,
}

// Regex_Vm_Save_Param records the current position into a save slot.
Regex_Vm_Save_Param :: struct {
	index: int,
}

// Regex_Vm_Split_Param forks to a relative target; prioritize_parent
// selects whether the fallthrough (greedy) or the target (lazy) runs first.
Regex_Vm_Split_Param :: struct {
	offset:             int,
	prioritize_parent:  bool,
}

// Regex_Vm_Line_Param asserts line start (is_start) or line end.
Regex_Vm_Line_Param :: struct {
	is_start: bool,
}

// Regex_Vm_Subject_Param asserts subject begin (is_begin) or subject end.
Regex_Vm_Subject_Param :: struct {
	is_begin: bool,
}

// Regex_Vm_Boundary_Param asserts a word boundary (positive) or its absence.
Regex_Vm_Boundary_Param :: struct {
	positive: bool,
}

// Regex_Vm_Lookaround_Param runs the lookaround at index, ahead (lookahead)
// or behind (lookbehind), requiring a match (positive) or a mismatch.
Regex_Vm_Lookaround_Param :: struct {
	index:       int,
	ahead:       bool,
	positive:    bool,
	ignore_case: bool,
}

// Regex_Vm_Param is the operand of one instruction (C++ Param union).
Regex_Vm_Param :: union {
	Regex_Vm_Literal,
	Regex_Vm_Range_Param,
	Regex_Vm_Char_Types,
	Regex_Vm_Class_Param,
	Regex_Vm_Jump_Param,
	Regex_Vm_Save_Param,
	Regex_Vm_Split_Param,
	Regex_Vm_Line_Param,
	Regex_Vm_Subject_Param,
	Regex_Vm_Boundary_Param,
	Regex_Vm_Lookaround_Param,
}

// Regex_Vm_Inst is one bytecode instruction.
Regex_Vm_Inst :: struct {
	op:    Regex_Vm_Op,
	param: Regex_Vm_Param,
}

// Lookaround program opcodes (C++ CompiledRegex::Lookaround). Plain
// codepoints below Lookaround_Op_Begin are literals; End terminates.
Regex_Vm_Lookaround_Any_Char :: 0xF0000
Regex_Vm_Lookaround_Any_Char_Except_New_Line :: 0xF0001
Regex_Vm_Lookaround_Char_Class :: 0xF0002
Regex_Vm_Lookaround_Char_Type :: 0xF8000
Regex_Vm_Lookaround_Op_End :: 0xFFFFF
Regex_Vm_Lookaround_End :: -1

// Regex_Vm_Named_Capture maps a (?<name>...) group name to its index.
// The name is owned (cloned from the pattern at compile time).
Regex_Vm_Named_Capture :: struct {
	name:  string,
	index: int,
}

// Regex_Vm_Start_Desc is the first-byte acceleration map: when set, a
// match start is always `offset` characters before a byte with map set
// (C++ CompiledRegex::StartDesc).
Regex_Vm_Start_Desc :: struct {
	start_byte: u8,
	offset:     int,
	bytes:      [256]bool,
}

// Regex_Vm_Compiled is a compiled pattern (C++ CompiledRegex).
// first_backward_inst is the first backward instruction index, or -1
// when the program has no backward support.
Regex_Vm_Compiled :: struct {
	instructions:       [dynamic]Regex_Vm_Inst,
	char_classes:       [dynamic]Regex_Vm_Char_Class,
	lookarounds:        [dynamic]int,
	named_captures:     [dynamic]Regex_Vm_Named_Capture,
	first_backward_inst: int,
	save_count:         int,
	forward_start:      Regex_Vm_Start_Desc,
	has_forward_start:  bool,
	backward_start:     Regex_Vm_Start_Desc,
	has_backward_start: bool,
	allocator:          mem.Allocator,
}

// Regex_Vm_Compile_Flag selects compilation variants.
Regex_Vm_Compile_Flag :: enum {
	No_Subs,
	Optimize,
	Backward,
	No_Forward,
}

// Regex_Vm_Compile_Flags is a set of Regex_Vm_Compile_Flag
// (C++ RegexCompileFlags).
Regex_Vm_Compile_Flags :: bit_set[Regex_Vm_Compile_Flag]

// Regex_Vm_Exec_Flag restricts boundary assertions during exec.
Regex_Vm_Exec_Flag :: enum {
	Not_Begin_Of_Line,
	Not_End_Of_Line,
	Not_Begin_Of_Word,
	Not_End_Of_Word,
	Not_Initial_Null,
}

// Regex_Vm_Exec_Flags is a set of Regex_Vm_Exec_Flag
// (C++ RegexExecFlags).
Regex_Vm_Exec_Flags :: bit_set[Regex_Vm_Exec_Flag]

// Regex_Vm_Mode selects the VM execution mode.
Regex_Vm_Mode :: enum {
	Forward,
	Backward,
	Search,
	Any_Match,
	No_Saves,
}

// Regex_Vm_Modes is a set of Regex_Vm_Mode (C++ RegexMode).
// Exactly one of Forward/Backward must be set.
Regex_Vm_Modes :: bit_set[Regex_Vm_Mode]

@(private = "file")
regex_vm_word_extra := [1]rune{'_'}

// regex_vm_is_word reports whether cp is a word character with the default
// extra word characters (C++ is_word default {'_'}).
regex_vm_is_word :: proc(cp: rune) -> bool {
	return unicode_is_word(cp, regex_vm_word_extra[:])
}

// regex_vm_is_digit reports whether cp is a decimal digit: ASCII 0-9, or a
// Unicode number above ASCII (C++ uses locale-dependent iswdigit).
regex_vm_is_digit :: proc(cp: rune) -> bool {
	if cp < 128 {
		return cp >= '0' && cp <= '9'
	}
	return unicode.is_number(cp)
}

// regex_vm_is_ctype reports whether cp matches any of the type bits in ct
// (C++ is_ctype).
regex_vm_is_ctype :: proc(ct: Regex_Vm_Char_Types, cp: rune) -> bool {
	if (.Word in ct || .Not_Word in ct) && regex_vm_is_word(cp) == (.Word in ct) {
		return true
	}
	if (.Whitespace in ct || .Not_Whitespace in ct) &&
	   unicode_is_blank(cp) == (.Whitespace in ct) {
		return true
	}
	if (.Horizontal_Whitespace in ct || .Not_Horizontal_Whitespace in ct) &&
	   unicode_is_horizontal_blank(cp) == (.Horizontal_Whitespace in ct) {
		return true
	}
	if (.Digit in ct || .Not_Digit in ct) && regex_vm_is_digit(cp) == (.Digit in ct) {
		return true
	}
	return false
}

// regex_vm_char_class_matches reports whether cp matches the class cc
// (C++ CharacterClass::matches). Ranges must be sorted by min.
regex_vm_char_class_matches :: proc(cc: Regex_Vm_Char_Class, cp: rune) -> bool {
	c := cp
	if cc.ignore_case {
		c = unicode_to_lower(c)
	}
	for r in cc.ranges {
		if c < r.min {
			break
		} else if c <= r.max {
			return !cc.negative
		}
	}
	matched := cc.ctypes != {} && regex_vm_is_ctype(cc.ctypes, c)
	return matched != cc.negative
}

// regex_vm_compiled_destroy releases all memory owned by prog.
regex_vm_compiled_destroy :: proc(prog: ^Regex_Vm_Compiled) {
	for &cc in prog.char_classes {
		delete(cc.ranges)
	}
	delete(prog.char_classes)
	for &nc in prog.named_captures {
		delete(nc.name, prog.allocator)
	}
	delete(prog.named_captures)
	delete(prog.lookarounds)
	delete(prog.instructions)
	prog^ = {}
}

// Regex_Vm_Parsed_Op is one AST node kind (C++ ParsedRegex::Op).
@(private = "file")
Regex_Vm_Parsed_Op :: enum u8 {
	Literal,
	Any_Char,
	Any_Char_Except_New_Line,
	Char_Class,
	Char_Type,
	Sequence,
	Alternation,
	Line_Start,
	Line_End,
	Word_Boundary,
	Not_Word_Boundary,
	Subject_Begin,
	Subject_End,
	Reset_Start,
	Look_Ahead,
	Negative_Look_Ahead,
	Look_Behind,
	Negative_Look_Behind,
}

// Regex_Vm_Quantifier_Infinite marks an unbounded repetition maximum.
@(private = "file")
Regex_Vm_Quantifier_Infinite :: 32767

// Regex_Vm_Quantifier is a {min,max} repetition with greediness.
@(private = "file")
Regex_Vm_Quantifier :: struct {
	min:    int,
	max:    int,
	greedy: bool,
}

// Regex_Vm_Parsed_Node is one AST node. value holds a literal codepoint, a
// char class index, char type bits, or a capture group index (-1 when the
// node saves nothing). children_end is the exclusive end of the node's
// subtree in the node array (C++ ParsedRegex::Node).
@(private = "file")
Regex_Vm_Parsed_Node :: struct {
	op:          Regex_Vm_Parsed_Op,
	ignore_case: bool,
	children_end: int,
	value:       int,
	quant:       Regex_Vm_Quantifier,
}

// Regex_Vm_Parse_Flag tracks (?i)/((?s) modifiers (C++ RegexParser::Flags).
@(private = "file")
Regex_Vm_Parse_Flag :: enum {
	Ignore_Case,
	Dot_Matches_New_Line,
}

@(private = "file")
Regex_Vm_Parse_Flags :: bit_set[Regex_Vm_Parse_Flag]

@(private = "file")
Regex_Vm_Parser :: struct {
	pattern:        string,
	pos:            int,
	nodes:          [dynamic]Regex_Vm_Parsed_Node,
	char_classes:   [dynamic]Regex_Vm_Char_Class,
	named_captures: [dynamic]Regex_Vm_Named_Capture,
	capture_count:  int,
	flags:          Regex_Vm_Parse_Flags,
	failed:         bool,
	err_msg:        string,
	allocator:      mem.Allocator,
}

@(private = "file")
Regex_Vm_Parsed :: struct {
	nodes:          [dynamic]Regex_Vm_Parsed_Node,
	char_classes:   [dynamic]Regex_Vm_Char_Class,
	named_captures: [dynamic]Regex_Vm_Named_Capture,
	capture_count:  int,
	allocator:      mem.Allocator,
}

// regex_vm_parser_destroy releases partial parser state after a failure.
@(private = "file")
regex_vm_parser_destroy :: proc(p: ^Regex_Vm_Parser) {
	for &cc in p.char_classes {
		delete(cc.ranges)
	}
	delete(p.char_classes)
	for &nc in p.named_captures {
		delete(nc.name, p.allocator)
	}
	delete(p.named_captures)
	delete(p.nodes)
}

// regex_vm_parser_fail records "regex parse error: <detail> at
// '<before><<<HERE>>><after>'" and marks the parser failed.
@(private = "file")
regex_vm_parser_fail :: proc(p: ^Regex_Vm_Parser, detail: string) {
	if p.failed {
		return
	}
	p.failed = true
	b := strings.builder_make(0, len(detail) + len(p.pattern) + 32, p.allocator)
	strings.write_string(&b, "regex parse error: ")
	strings.write_string(&b, detail)
	strings.write_string(&b, " at '")
	strings.write_string(&b, p.pattern[:p.pos])
	strings.write_string(&b, "<<<HERE>>>")
	strings.write_string(&b, p.pattern[p.pos:])
	strings.write_string(&b, "'")
	p.err_msg = strings.to_string(b)
}

// regex_vm_parser_fail_cp records a parse error with a codepoint value.
@(private = "file")
regex_vm_parser_fail_cp :: proc(p: ^Regex_Vm_Parser, prefix: string, cp: rune, suffix := "") {
	buf: [4]byte
	n := utf8_dump(cp, buf[:])
	b := strings.builder_make(0, len(prefix) + n + len(suffix), context.temp_allocator)
	strings.write_string(&b, prefix)
	strings.write_string(&b, string(buf[:n]))
	strings.write_string(&b, suffix)
	detail := strings.to_string(b)
	defer delete(detail, context.temp_allocator)
	regex_vm_parser_fail(p, detail)
}

// regex_vm_parser_fail_int records a parse error with an integer value.
@(private = "file")
regex_vm_parser_fail_int :: proc(p: ^Regex_Vm_Parser, prefix: string, v: int, suffix := "") {
	num := format_to_string_int(v, context.temp_allocator)
	defer delete(num, context.temp_allocator)
	b := strings.builder_make(0, len(prefix) + len(num) + len(suffix), context.temp_allocator)
	strings.write_string(&b, prefix)
	strings.write_string(&b, num)
	strings.write_string(&b, suffix)
	detail := strings.to_string(b)
	defer delete(detail, context.temp_allocator)
	regex_vm_parser_fail(p, detail)
}

// regex_vm_parser_fail_invalid records a bare "Invalid utf8 in regex"
// error (the C++ throwing InvalidPolicy message, without position info).
@(private = "file")
regex_vm_parser_fail_invalid :: proc(p: ^Regex_Vm_Parser) {
	if p.failed {
		return
	}
	p.failed = true
	p.err_msg = strings.clone("Invalid utf8 in regex", p.allocator)
}

// regex_vm_parser_decode decodes the codepoint at byte offset pos without
// moving the cursor. Like the C++ throwing iterator, only lead-byte class
// and truncation are validated; continuation bytes are masked blindly.
@(private = "file")
regex_vm_parser_decode :: proc(p: ^Regex_Vm_Parser, pos: int) -> rune {
	lead := p.pattern[pos]
	if lead & 0x80 == 0 {
		return rune(lead)
	}
	size := utf8_codepoint_size_byte(lead)
	if size == 1 || pos + size > len(p.pattern) {
		regex_vm_parser_fail_invalid(p)
		return -1
	}
	q := pos
	return utf8_read_codepoint(p.pattern, &q)
}

// regex_vm_parser_peek returns the codepoint under the cursor, -1 at the
// end of input, and records failure on invalid UTF-8.
@(private = "file")
regex_vm_parser_peek :: proc(p: ^Regex_Vm_Parser) -> rune {
	if p.pos >= len(p.pattern) {
		return -1
	}
	return regex_vm_parser_decode(p, p.pos)
}

// regex_vm_parser_next consumes and returns the codepoint under the cursor.
@(private = "file")
regex_vm_parser_next :: proc(p: ^Regex_Vm_Parser) -> rune {
	cp := regex_vm_parser_peek(p)
	if !p.failed && p.pos < len(p.pattern) {
		p.pos = utf8_next(p.pattern, p.pos)
	}
	return cp
}

// regex_vm_parser_at_end reports whether the cursor reached the pattern end.
@(private = "file")
regex_vm_parser_at_end :: proc(p: ^Regex_Vm_Parser) -> bool {
	return p.pos >= len(p.pattern)
}

// regex_vm_parser_add_node appends an AST node and returns its index.
@(private = "file")
regex_vm_parser_add_node :: proc(
	p: ^Regex_Vm_Parser,
	op: Regex_Vm_Parsed_Op,
	value := -1,
	quant := Regex_Vm_Quantifier{1, 1, true},
	ignore_case := false,
) -> int {
	if p.failed {
		return 0
	}
	if len(p.nodes) == 32767 {
		regex_vm_parser_fail_int(p, "regex parsed to more than ", 32767, " ast nodes")
		return 0
	}
	res := len(p.nodes)
	append(
		&p.nodes,
		Regex_Vm_Parsed_Node{
			op = op,
			ignore_case = ignore_case || .Ignore_Case in p.flags,
			children_end = res + 1,
			value = value,
			quant = quant,
		},
	)
	return res
}

@(private = "file")
regex_vm_parser_disjunction :: proc(p: ^Regex_Vm_Parser, capture := -1) -> int {
	index := regex_vm_parser_add_node(p, .Alternation, capture)
	for {
		regex_vm_parser_alternative(p, .Sequence)
		if p.failed {
			return index
		}
		if regex_vm_parser_at_end(p) || regex_vm_parser_peek(p) != '|' {
			break
		}
		regex_vm_parser_next(p)
	}
	p.nodes[index].children_end = len(p.nodes)
	return index
}

@(private = "file")
regex_vm_parser_alternative :: proc(p: ^Regex_Vm_Parser, op: Regex_Vm_Parsed_Op) -> int {
	index := regex_vm_parser_add_node(p, op)
	for {
		present := regex_vm_parser_term(p)
		if p.failed || !present {
			break
		}
	}
	p.nodes[index].children_end = len(p.nodes)
	return index
}

// regex_vm_parser_term parses one term and reports whether a term was
// present (absent is not an error).
@(private = "file")
regex_vm_parser_term :: proc(p: ^Regex_Vm_Parser) -> bool {
	for regex_vm_parser_modifiers(p) && !p.failed {
	}
	if p.failed {
		return false
	}
	if _, ok := regex_vm_parser_assertion(p); ok {
		return true
	} else if p.failed {
		return false
	}
	if node, ok := regex_vm_parser_atom(p); ok {
		p.nodes[node].quant = regex_vm_parser_quantifier(p)
		return true
	}
	return false
}

@(private = "file")
regex_vm_parser_modifiers :: proc(p: ^Regex_Vm_Parser) -> bool {
	it := p.pos
	if len(p.pattern) - it < 4 || p.pattern[it] != '(' || p.pattern[it + 1] != '?' {
		return false
	}
	it += 2
	for {
		if it >= len(p.pattern) {
			return false
		}
		m := p.pattern[it]
		it += 1
		switch m {
		case 'i':
			p.flags += {.Ignore_Case}
		case 'I':
			p.flags -= {.Ignore_Case}
		case 's':
			p.flags += {.Dot_Matches_New_Line}
		case 'S':
			p.flags -= {.Dot_Matches_New_Line}
		case ')':
			p.pos = it
			return true
		case:
			return false
		}
	}
}

@(private = "file")
regex_vm_parser_assertion :: proc(p: ^Regex_Vm_Parser) -> (int, bool) {
	if regex_vm_parser_at_end(p) {
		return 0, false
	}
	switch regex_vm_parser_peek(p) {
	case '^':
		regex_vm_parser_next(p)
		return regex_vm_parser_add_node(p, .Line_Start), true
	case '$':
		regex_vm_parser_next(p)
		return regex_vm_parser_add_node(p, .Line_End), true
	case '\\':
		next_pos := utf8_next(p.pattern, p.pos)
		if next_pos >= len(p.pattern) {
			return 0, false
		}
		esc := regex_vm_parser_decode(p, next_pos)
		if p.failed {
			return 0, false
		}
		node := -1
		switch esc {
		case 'b':
			node = regex_vm_parser_add_node(p, .Word_Boundary)
		case 'B':
			node = regex_vm_parser_add_node(p, .Not_Word_Boundary)
		case 'A':
			node = regex_vm_parser_add_node(p, .Subject_Begin)
		case 'z':
			node = regex_vm_parser_add_node(p, .Subject_End)
		case 'K':
			node = regex_vm_parser_add_node(p, .Reset_Start)
		case:
			return 0, false
		}
		p.pos = utf8_next(p.pattern, next_pos)
		return node, true
	case '(':
		it := p.pos + 1
		if len(p.pattern) - it <= 2 || p.pattern[it] != '?' {
			return 0, false
		}
		it += 1
		op := Regex_Vm_Parsed_Op.Look_Ahead
		switch p.pattern[it] {
		case '=':
			op = .Look_Ahead
			it += 1
		case '!':
			op = .Negative_Look_Ahead
			it += 1
		case '<':
			it += 1
			if it >= len(p.pattern) {
				return 0, false
			}
			switch p.pattern[it] {
			case '=':
				op = .Look_Behind
			case '!':
				op = .Negative_Look_Behind
			case:
				return 0, false
			}
			it += 1
		case:
			return 0, false
		}
		p.pos = it
		lookaround := regex_vm_parser_alternative(p, op)
		if p.failed {
			return 0, false
		}
		// The C++ captures the end position and dereferences it when the
		// closing paren is missing, which throws "Invalid utf8 in regex"
		// at the end of input.
		if regex_vm_parser_at_end(p) {
			regex_vm_parser_fail_invalid(p)
			return 0, false
		}
		end_cp := regex_vm_parser_peek(p)
		if p.failed {
			return 0, false
		}
		if regex_vm_parser_next(p) != ')' {
			if end_cp == '|' {
				regex_vm_parser_fail(p, "Alternations cannot be used in lookarounds")
			} else {
				regex_vm_parser_fail(p, "unclosed parenthesis")
			}
			return 0, false
		}
		regex_vm_parser_validate_lookaround(p, lookaround)
		return lookaround, !p.failed
	}
	return 0, false
}

@(private = "file")
regex_vm_parser_atom :: proc(p: ^Regex_Vm_Parser) -> (int, bool) {
	if regex_vm_parser_at_end(p) {
		return 0, false
	}
	cp := regex_vm_parser_peek(p)
	if p.failed {
		return 0, false
	}
	switch cp {
	case '.':
		regex_vm_parser_next(p)
		op := Regex_Vm_Parsed_Op.Any_Char_Except_New_Line
		if .Dot_Matches_New_Line in p.flags {
			op = .Any_Char
		}
		return regex_vm_parser_add_node(p, op), true
	case '(':
		regex_vm_parser_next(p)
		capture_group := -1
		it := p.pos
		if len(p.pattern) - it < 2 || p.pattern[it] != '?' {
			capture_group = p.capture_count
			p.capture_count += 1
		} else if p.pattern[it + 1] == ':' {
			p.pos = it + 2
		} else if p.pattern[it + 1] == '<' {
			name_start := it + 2
			end := name_start
			// Byte based, as in C++ (on x86 char is signed, so this
			// only ever accepts ASCII word characters).
			for end < len(p.pattern) && regex_vm_is_ascii_word(p.pattern[end]) {
				end += 1
			}
			if end >= len(p.pattern) || p.pattern[end] != '>' {
				regex_vm_parser_fail(p, "named captures should be only ascii word characters")
				return 0, false
			}
			capture_group = p.capture_count
			p.capture_count += 1
			append(
				&p.named_captures,
				Regex_Vm_Named_Capture{
					name = strings.clone(p.pattern[name_start:end], p.allocator),
					index = capture_group,
				},
			)
			p.pos = end + 1
		}
		if p.failed {
			return 0, false
		}
		content := regex_vm_parser_disjunction(p, capture_group)
		if p.failed {
			return 0, false
		}
		if regex_vm_parser_at_end(p) || regex_vm_parser_next(p) != ')' {
			regex_vm_parser_fail(p, "unclosed parenthesis")
			return 0, false
		}
		return content, true
	case '\\':
		regex_vm_parser_next(p)
		node := regex_vm_parser_atom_escape(p)
		return node, !p.failed
	case '[':
		regex_vm_parser_next(p)
		node := regex_vm_parser_character_class(p)
		return node, !p.failed
	case '|', ')':
		return 0, false
	case:
		if strings.contains_rune("^$.*+?[]{}", cp) ||
		   (cp >= 0xF0000 && cp <= 0xFFFFF) {
			regex_vm_parser_fail_cp(p, "unexpected '", cp, "'")
			return 0, false
		}
		regex_vm_parser_next(p)
		return regex_vm_parser_add_node(p, .Literal, int(cp)), true
	}
}

// regex_vm_class_escape maps a character class escape letter to its type bits.
@(private = "file")
regex_vm_class_escape :: proc(cp: rune) -> (Regex_Vm_Char_Types, bool) {
	switch cp {
	case 'd':
		return {.Digit}, true
	case 'D':
		return {.Not_Digit}, true
	case 'w':
		return {.Word}, true
	case 'W':
		return {.Not_Word}, true
	case 's':
		return {.Whitespace}, true
	case 'S':
		return {.Not_Whitespace}, true
	case 'h':
		return {.Horizontal_Whitespace}, true
	case 'H':
		return {.Not_Horizontal_Whitespace}, true
	}
	return {}, false
}

// regex_vm_is_ascii_word reports whether b is an ASCII word byte.
@(private = "file")
regex_vm_is_ascii_word :: proc(b: byte) -> bool {
	return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') ||
		(b >= '0' && b <= '9') || b == '_'
}

// regex_vm_control_escape maps a control escape letter to its codepoint.
@(private = "file")
regex_vm_control_escape :: proc(cp: rune) -> (rune, bool) {
	switch cp {
	case 'f':
		return '\f', true
	case 'n':
		return '\n', true
	case 'r':
		return '\r', true
	case 't':
		return '\t', true
	case 'v':
		return '\v', true
	}
	return 0, false
}

@(private = "file")
regex_vm_parser_read_hex :: proc(p: ^Regex_Vm_Parser, count: int) -> rune {
	res := 0
	for _ in 0 ..< count {
		if regex_vm_parser_at_end(p) {
			regex_vm_parser_fail(p, "unterminated hex sequence")
			return 0
		}
		digit := regex_vm_parser_next(p)
		if p.failed {
			return 0
		}
		digit_value := -1
		if digit >= '0' && digit <= '9' {
			digit_value = int(digit - '0')
		} else if digit >= 'a' && digit <= 'f' {
			digit_value = 0xa + int(digit - 'a')
		} else if digit >= 'A' && digit <= 'F' {
			digit_value = 0xa + int(digit - 'A')
		} else {
			regex_vm_parser_fail_cp(p, "invalid hex digit '", digit, "'")
			return 0
		}
		res = res * 16 + digit_value
	}
	return rune(res)
}

@(private = "file")
regex_vm_parser_atom_escape :: proc(p: ^Regex_Vm_Parser) -> int {
	// The C++ dereferences the cursor here without an end check, which
	// throws "Invalid utf8 in regex" at the end of input.
	if regex_vm_parser_at_end(p) {
		regex_vm_parser_fail_invalid(p)
		return 0
	}
	cp := regex_vm_parser_next(p)
	if p.failed {
		return 0
	}
	if cp == 'N' {
		return regex_vm_parser_add_node(p, .Any_Char_Except_New_Line)
	}
	if cp == 'Q' {
		escaped := regex_vm_parser_add_node(p, .Sequence)
		end_mark := strings.index(p.pattern[p.pos:], "\\E")
		quote_end := len(p.pattern) if end_mark < 0 else p.pos + end_mark
		for p.pos < quote_end {
			lit := regex_vm_parser_next(p)
			if p.failed {
				return 0
			}
			regex_vm_parser_add_node(p, .Literal, int(lit))
		}
		p.nodes[escaped].children_end = len(p.nodes)
		if quote_end < len(p.pattern) {
			p.pos += 2
		}
		return escaped
	}
	if ct, ok := regex_vm_class_escape(cp); ok {
		return regex_vm_parser_add_node(p, .Char_Type, int(transmute(u8)ct))
	}
	if value, ok := regex_vm_control_escape(cp); ok {
		return regex_vm_parser_add_node(p, .Literal, int(value))
	}
	if cp == '0' {
		return regex_vm_parser_add_node(p, .Literal, 0)
	} else if cp == 'c' {
		if regex_vm_parser_at_end(p) {
			regex_vm_parser_fail(p, "unterminated control escape")
			return 0
		}
		ctrl := regex_vm_parser_next(p)
		if p.failed {
			return 0
		}
		if (ctrl >= 'a' && ctrl <= 'z') || (ctrl >= 'A' && ctrl <= 'Z') {
			return regex_vm_parser_add_node(p, .Literal, int(ctrl) % 32)
		}
		regex_vm_parser_fail_cp(p, "Invalid control escape character '", ctrl, "'")
		return 0
	} else if cp == 'x' {
		return regex_vm_parser_add_node(p, .Literal, int(regex_vm_parser_read_hex(p, 2)))
	} else if cp == 'u' {
		return regex_vm_parser_add_node(p, .Literal, int(regex_vm_parser_read_hex(p, 6)))
	}
	if strings.contains_rune("^$\\.*+?()[]{}|", cp) {
		return regex_vm_parser_add_node(p, .Literal, int(cp))
	}
	regex_vm_parser_fail_cp(p, "unknown atom escape '", cp, "'")
	return 0
}

// regex_vm_normalize_ranges sorts ranges by min and merges overlapping or
// adjacent ones.
@(private = "file")
regex_vm_normalize_ranges :: proc(ranges: ^[dynamic]Regex_Vm_Char_Range) {
	if len(ranges) == 0 {
		return
	}
	slice.sort_by(ranges[:], proc(a, b: Regex_Vm_Char_Range) -> bool { return a.min < b.min })
	pos := 0
	for next := 1; next < len(ranges); next += 1 {
		if ranges[pos].max + 1 >= ranges[next].min {
			if ranges[next].max > ranges[pos].max {
				ranges[pos].max = ranges[next].max
			}
		} else {
			pos += 1
			ranges[pos] = ranges[next]
		}
	}
	resize(ranges, pos + 1)
}

@(private = "file")
regex_vm_parser_read_escaped_char :: proc(p: ^Regex_Vm_Parser) -> rune {
	// The C++ dereferences the cursor here without an end check, which
	// throws "Invalid utf8 in regex" at the end of input.
	if regex_vm_parser_at_end(p) {
		regex_vm_parser_fail_invalid(p)
		return 0
	}
	cp := regex_vm_parser_next(p)
	if p.failed {
		return 0
	}
	if value, ok := regex_vm_control_escape(cp); ok {
		return value
	}
	if cp == 'x' {
		return regex_vm_parser_read_hex(p, 2)
	}
	if cp == 'u' {
		return regex_vm_parser_read_hex(p, 6)
	}
	if !strings.contains_rune("^$\\.*+?()[]{}|-", cp) {
		regex_vm_parser_fail_cp(p, "unknown character class escape '", cp, "'")
		return 0
	}
	return cp
}

@(private = "file")
regex_vm_parser_character_class :: proc(p: ^Regex_Vm_Parser) -> int {
	char_class := Regex_Vm_Char_Class{
		ranges = make([dynamic]Regex_Vm_Char_Range, 0, 4, p.allocator),
		ignore_case = .Ignore_Case in p.flags,
		negative = !regex_vm_parser_at_end(p) && regex_vm_parser_peek(p) == '^',
	}
	if char_class.negative {
		regex_vm_parser_next(p)
	}
	for !regex_vm_parser_at_end(p) && regex_vm_parser_peek(p) != ']' {
		if p.failed {
			break
		}
		cp := regex_vm_parser_next(p)
		if p.failed {
			break
		}
		if cp == '-' {
			append(&char_class.ranges, Regex_Vm_Char_Range{'-', '-'})
			continue
		}
		if regex_vm_parser_at_end(p) {
			break
		}
		if cp == '\\' {
			if ct, ok := regex_vm_class_escape(regex_vm_parser_peek(p)); ok {
				char_class.ctypes += ct
				regex_vm_parser_next(p)
				continue
			}
			cp = regex_vm_parser_read_escaped_char(p)
			if p.failed {
				break
			}
		}
		rng := Regex_Vm_Char_Range{cp, cp}
		// The C++ dereferences the cursor here without an end check,
		// which throws "Invalid utf8 in regex" at the end of input.
		if regex_vm_parser_at_end(p) {
			regex_vm_parser_fail_invalid(p)
			break
		}
		if regex_vm_parser_peek(p) == '-' {
			regex_vm_parser_next(p)
			if regex_vm_parser_at_end(p) {
				break
			}
			if regex_vm_parser_peek(p) != ']' {
				cp = regex_vm_parser_next(p)
				if p.failed {
					break
				}
				if cp == '\\' {
					cp = regex_vm_parser_read_escaped_char(p)
					if p.failed {
						break
					}
				}
				rng.max = cp
				if rng.min > rng.max {
					regex_vm_parser_fail(p, "invalid range specified")
					break
				}
			} else {
				append(&char_class.ranges, rng)
				rng = {'-', '-'}
			}
		}
		if p.failed {
			break
		}
		append(&char_class.ranges, rng)
	}
	if p.failed {
		delete(char_class.ranges)
		return 0
	}
	if regex_vm_parser_at_end(p) {
		delete(char_class.ranges)
		regex_vm_parser_fail(p, "unclosed character class")
		return 0
	}
	regex_vm_parser_next(p)

	if !char_class.ignore_case {
		could_ignore_case := true
		for r in char_class.ranges {
			lower_found := false
			upper_found := false
			for o in char_class.ranges {
				if o == (Regex_Vm_Char_Range{unicode_to_lower(r.min), unicode_to_lower(r.max)}) {
					lower_found = true
				}
				if o == (Regex_Vm_Char_Range{unicode_to_upper(r.min), unicode_to_upper(r.max)}) {
					upper_found = true
				}
			}
			if !lower_found || !upper_found {
				could_ignore_case = false
			}
		}
		char_class.ignore_case = could_ignore_case
	}
	if char_class.ignore_case {
		for &r in char_class.ranges {
			r.min = unicode_to_lower(r.min)
			r.max = unicode_to_lower(r.max)
		}
	}
	regex_vm_normalize_ranges(&char_class.ranges)

	if char_class.ctypes == {} && !char_class.negative &&
	   len(char_class.ranges) == 1 &&
	   char_class.ranges[0].min == char_class.ranges[0].max {
		lit := int(char_class.ranges[0].min)
		ignore_case := char_class.ignore_case
		delete(char_class.ranges)
		return regex_vm_parser_add_node(p, .Literal, lit, {1, 1, true}, ignore_case)
	}
	if char_class.ctypes != {} && !char_class.negative && len(char_class.ranges) == 0 {
		ct := int(transmute(u8)char_class.ctypes)
		delete(char_class.ranges)
		return regex_vm_parser_add_node(p, .Char_Type, ct)
	}
	class_id := -1
	for existing, i in p.char_classes {
		if regex_vm_char_class_equal(existing, char_class) {
			class_id = i
			break
		}
	}
	if class_id < 0 {
		class_id = len(p.char_classes)
		append(&p.char_classes, char_class)
	} else {
		delete(char_class.ranges)
	}
	return regex_vm_parser_add_node(p, .Char_Class, class_id)
}

@(private = "file")
regex_vm_parser_read_bound :: proc(p: ^Regex_Vm_Parser) -> (int, bool) {
	res := 0
	start := p.pos
	for p.pos < len(p.pattern) {
		cp := regex_vm_parser_decode(p, p.pos)
		if p.failed {
			return 0, false
		}
		if cp < '0' || cp > '9' {
			if p.pos == start {
				return 0, false
			}
			return res, true
		}
		res = res * 10 + int(cp - '0')
		if res > 1000 {
			// The C++ advances past the digit only after this check,
			// so the error position is at the offending digit.
			regex_vm_parser_fail_int(p, "Explicit quantifier is too big, maximum is ", 1000)
			return 0, false
		}
		p.pos = utf8_next(p.pattern, p.pos)
	}
	return res, true
}

@(private = "file")
regex_vm_parser_check_greedy :: proc(p: ^Regex_Vm_Parser) -> bool {
	if regex_vm_parser_at_end(p) || regex_vm_parser_peek(p) != '?' {
		return true
	}
	regex_vm_parser_next(p)
	return false
}

@(private = "file")
regex_vm_parser_quantifier :: proc(p: ^Regex_Vm_Parser) -> Regex_Vm_Quantifier {
	if regex_vm_parser_at_end(p) {
		return {1, 1, true}
	}
	switch regex_vm_parser_peek(p) {
	case '*':
		regex_vm_parser_next(p)
		return {0, Regex_Vm_Quantifier_Infinite, regex_vm_parser_check_greedy(p)}
	case '+':
		regex_vm_parser_next(p)
		return {1, Regex_Vm_Quantifier_Infinite, regex_vm_parser_check_greedy(p)}
	case '?':
		regex_vm_parser_next(p)
		return {0, 1, regex_vm_parser_check_greedy(p)}
	case '{':
		regex_vm_parser_next(p)
		min, min_ok := regex_vm_parser_read_bound(p)
		if p.failed {
			return {1, 1, true}
		}
		if !min_ok {
			min = 0
		}
		max := min
		// The C++ dereferences the cursor here without an end check,
		// which throws "Invalid utf8 in regex" at the end of input.
		if regex_vm_parser_at_end(p) {
			regex_vm_parser_fail_invalid(p)
			return {1, 1, true}
		}
		if regex_vm_parser_peek(p) == ',' {
			regex_vm_parser_next(p)
			bound, bound_ok := regex_vm_parser_read_bound(p)
			if p.failed {
				return {1, 1, true}
			}
			max = bound if bound_ok else Regex_Vm_Quantifier_Infinite
			if regex_vm_parser_at_end(p) {
				regex_vm_parser_fail_invalid(p)
				return {1, 1, true}
			}
		}
		cp := regex_vm_parser_next(p)
		if p.failed {
			return {1, 1, true}
		}
		if cp != '}' {
			regex_vm_parser_fail(p, "expected closing bracket")
			return {1, 1, true}
		}
		return {min, max, regex_vm_parser_check_greedy(p)}
	}
	return {1, 1, true}
}

@(private = "file")
regex_vm_parser_validate_lookaround :: proc(p: ^Regex_Vm_Parser, index: int) {
	it := regex_vm_child_iter_make(p.nodes[:], index, false)
	for {
		child, ok := regex_vm_child_iter_next(&it)
		if !ok {
			break
		}
		op := p.nodes[child].op
		if op != .Literal && op != .Char_Class && op != .Char_Type &&
		   op != .Any_Char && op != .Any_Char_Except_New_Line {
			regex_vm_parser_fail(
				p,
				"Lookaround can only contain literals, any chars or character classes",
			)
			return
		}
		if op == .Literal &&
		   p.nodes[child].value >= Regex_Vm_Lookaround_Any_Char &&
		   p.nodes[child].value < Regex_Vm_Lookaround_Op_End {
			regex_vm_parser_fail(
				p,
				"Lookaround does not support literals codepoint between 0xF0000 and 0xFFFFD",
			)
			return
		}
		if p.nodes[child].quant != (Regex_Vm_Quantifier{1, 1, true}) {
			regex_vm_parser_fail(p, "Quantifiers cannot be used in lookarounds")
			return
		}
	}
}

// regex_vm_parse parses the pattern into an AST (C++ RegexParser::parse).
// On success the caller owns the returned arrays; on failure partial state
// is released and an owned error message is returned instead.
@(private = "file")
regex_vm_parse :: proc(
	re: string,
	allocator: mem.Allocator,
) -> (parsed: Regex_Vm_Parsed, err_msg: string, err: Regex_Vm_Error) {
	p := Regex_Vm_Parser{
		pattern = re,
		nodes = make([dynamic]Regex_Vm_Parsed_Node, 0, len(re) + 1, allocator),
		char_classes = make([dynamic]Regex_Vm_Char_Class, 0, allocator),
		named_captures = make([dynamic]Regex_Vm_Named_Capture, 0, allocator),
		capture_count = 1,
		flags = {.Dot_Matches_New_Line},
		allocator = allocator,
	}
	root := regex_vm_parser_disjunction(&p, 0)
	if p.failed {
		regex_vm_parser_destroy(&p)
		return {}, p.err_msg, .Compile_Error
	}
	assert(root == 0)
	parsed = Regex_Vm_Parsed{
		nodes = p.nodes,
		char_classes = p.char_classes,
		named_captures = p.named_captures,
		capture_count = p.capture_count,
		allocator = allocator,
	}
	return parsed, "", .None
}

// Regex_Vm_Child_Iter iterates the direct children of an AST node in
// forward or reverse order without allocating (C++ Children).
@(private = "file")
Regex_Vm_Child_Iter :: struct {
	nodes:    []Regex_Vm_Parsed_Node,
	pos:      int,
	end:      int,
	parent:   int,
	backward: bool,
}

@(private = "file")
regex_vm_child_iter_make :: proc(
	nodes: []Regex_Vm_Parsed_Node,
	index: int,
	backward: bool,
) -> Regex_Vm_Child_Iter {
	if backward {
		return {nodes, regex_vm_child_find_prev(nodes, index, nodes[index].children_end), index, index, true}
	}
	return {nodes, index + 1, nodes[index].children_end, index, false}
}

@(private = "file")
regex_vm_child_find_prev :: proc(nodes: []Regex_Vm_Parsed_Node, parent, pos: int) -> int {
	child := parent + 1
	if child == pos {
		return parent
	}
	for nodes[child].children_end != pos {
		child = nodes[child].children_end
	}
	return child
}

@(private = "file")
regex_vm_child_iter_next :: proc(it: ^Regex_Vm_Child_Iter) -> (int, bool) {
	if it.pos == it.end {
		return 0, false
	}
	res := it.pos
	if it.backward {
		it.pos = regex_vm_child_find_prev(it.nodes, it.end, it.pos)
	} else {
		it.pos = it.nodes[it.pos].children_end
	}
	return res, true
}

@(private = "file")
regex_vm_char_class_equal :: proc(a, b: Regex_Vm_Char_Class) -> bool {
	if a.ctypes != b.ctypes || a.negative != b.negative || a.ignore_case != b.ignore_case {
		return false
	}
	if len(a.ranges) != len(b.ranges) {
		return false
	}
	for r, i in a.ranges {
		if r != b.ranges[i] {
			return false
		}
	}
	return true
}

@(private = "file")
Regex_Vm_Compiler :: struct {
	parsed:    ^Regex_Vm_Parsed,
	prog:      ^Regex_Vm_Compiled,
	flags:     Regex_Vm_Compile_Flags,
	failed:    bool,
	err_msg:   string,
	allocator: mem.Allocator,
}

@(private = "file")
regex_vm_compiler_push_inst :: proc(
	c: ^Regex_Vm_Compiler,
	op: Regex_Vm_Op,
	param: Regex_Vm_Param = nil,
) -> int {
	if c.failed {
		return 0
	}
	if len(c.prog.instructions) >= 32767 {
		c.failed = true
		num := format_to_string_int(32767, context.temp_allocator)
		defer delete(num, context.temp_allocator)
		b := strings.builder_make(
			0,
			len("regex compiled to more than ") + len(num) + len(" instructions"),
			c.allocator,
		)
		strings.write_string(&b, "regex compiled to more than ")
		strings.write_string(&b, num)
		strings.write_string(&b, " instructions")
		c.err_msg = strings.to_string(b)
		return 0
	}
	res := len(c.prog.instructions)
	append(&c.prog.instructions, Regex_Vm_Inst{op, param})
	return res
}

@(private = "file")
regex_vm_compiler_push_lookaround :: proc(c: ^Regex_Vm_Compiler, index: int, backward, ignore_case: bool) -> int {
	res := len(c.prog.lookarounds)
	it := regex_vm_child_iter_make(c.parsed.nodes[:], index, backward)
	for {
		child, ok := regex_vm_child_iter_next(&it)
		if !ok {
			break
		}
		character := c.parsed.nodes[child]
		op := Regex_Vm_Lookaround_End
		switch character.op {
		case .Literal:
			op = character.value
			if ignore_case {
				op = int(unicode_to_lower(rune(character.value)))
			}
		case .Any_Char:
			op = Regex_Vm_Lookaround_Any_Char
		case .Any_Char_Except_New_Line:
			op = Regex_Vm_Lookaround_Any_Char_Except_New_Line
		case .Char_Class:
			op = Regex_Vm_Lookaround_Char_Class + character.value
		case .Char_Type:
			op = Regex_Vm_Lookaround_Char_Type | character.value
		case .Sequence, .Alternation, .Line_Start, .Line_End, .Word_Boundary,
		     .Not_Word_Boundary, .Subject_Begin, .Subject_End, .Reset_Start,
		     .Look_Ahead, .Negative_Look_Ahead, .Look_Behind, .Negative_Look_Behind:
			unreachable()
		}
		append(&c.prog.lookarounds, op)
	}
	append(&c.prog.lookarounds, Regex_Vm_Lookaround_End)
	return res
}

@(private = "file")
regex_vm_compiler_compile_node_inner :: proc(c: ^Regex_Vm_Compiler, index: int, backward: bool) -> int {
	if c.failed {
		return 0
	}
	node := c.parsed.nodes[index]
	start_pos := len(c.prog.instructions)
	ignore_case := node.ignore_case
	save := (node.op == .Alternation || node.op == .Sequence) &&
		(node.value == 0 || (node.value != -1 && .No_Subs not_in c.flags))
	if save {
		slot := node.value * 2
		if backward {
			slot = node.value * 2 + 1
		}
		regex_vm_compiler_push_inst(c, .Save, Regex_Vm_Save_Param{slot})
	}
	goto_inner_end_offsets := make([dynamic]int, 0, 4, context.temp_allocator)
	defer delete(goto_inner_end_offsets)
	switch node.op {
	case .Literal:
		cp := rune(node.value)
		if ignore_case {
			cp = unicode_to_lower(cp)
		}
		regex_vm_compiler_push_inst(c, .Literal, Regex_Vm_Literal{cp, ignore_case})
	case .Any_Char:
		regex_vm_compiler_push_inst(c, .Any_Char)
	case .Any_Char_Except_New_Line:
		regex_vm_compiler_push_inst(c, .Any_Char_Except_New_Line)
	case .Char_Class:
		char_class := c.parsed.char_classes[node.value]
		if len(char_class.ranges) == 1 && char_class.ctypes == {} &&
		   char_class.ranges[0].max <= 0xFF {
			regex_vm_compiler_push_inst(
				c,
				.Char_Range,
				Regex_Vm_Range_Param{
					u8(char_class.ranges[0].min),
					u8(char_class.ranges[0].max),
					char_class.ignore_case,
					char_class.negative,
				},
			)
		} else {
			regex_vm_compiler_push_inst(c, .Char_Class, Regex_Vm_Class_Param{node.value})
		}
	case .Char_Type:
		regex_vm_compiler_push_inst(
			c,
			.Char_Type,
			transmute(Regex_Vm_Char_Types)u8(node.value),
		)
	case .Sequence:
		it := regex_vm_child_iter_make(c.parsed.nodes[:], index, backward)
		for {
			child, ok := regex_vm_child_iter_next(&it)
			if !ok {
				break
			}
			regex_vm_compiler_compile_node(c, child, backward)
		}
	case .Alternation:
		it := regex_vm_child_iter_make(c.parsed.nodes[:], index, false)
		for {
			child, ok := regex_vm_child_iter_next(&it)
			if !ok {
				break
			}
			if child != index + 1 {
				regex_vm_compiler_push_inst(c, .Split)
			}
		}
		split_pos := len(c.prog.instructions)
		end := node.children_end
		it2 := regex_vm_child_iter_make(c.parsed.nodes[:], index, false)
		for {
			child, ok := regex_vm_child_iter_next(&it2)
			if !ok {
				break
			}
			node_start := regex_vm_compiler_compile_node(c, child, backward)
			if child != index + 1 {
				split_pos -= 1
				c.prog.instructions[split_pos].param = Regex_Vm_Split_Param{
					node_start - split_pos,
					true,
				}
			}
			if c.parsed.nodes[child].children_end != end {
				jump := regex_vm_compiler_push_inst(c, .Jump)
				append(&goto_inner_end_offsets, jump)
			}
		}
	case .Look_Ahead, .Negative_Look_Ahead:
		regex_vm_compiler_push_inst(
			c,
			.Look_Around,
			Regex_Vm_Lookaround_Param{
				regex_vm_compiler_push_lookaround(c, index, false, ignore_case),
				true,
				node.op == .Look_Ahead,
				ignore_case,
			},
		)
	case .Look_Behind, .Negative_Look_Behind:
		regex_vm_compiler_push_inst(
			c,
			.Look_Around,
			Regex_Vm_Lookaround_Param{
				regex_vm_compiler_push_lookaround(c, index, true, ignore_case),
				false,
				node.op == .Look_Behind,
				ignore_case,
			},
		)
	case .Line_Start:
		regex_vm_compiler_push_inst(c, .Line_Assertion, Regex_Vm_Line_Param{true})
	case .Line_End:
		regex_vm_compiler_push_inst(c, .Line_Assertion, Regex_Vm_Line_Param{false})
	case .Word_Boundary:
		regex_vm_compiler_push_inst(c, .Word_Boundary, Regex_Vm_Boundary_Param{true})
	case .Not_Word_Boundary:
		regex_vm_compiler_push_inst(c, .Word_Boundary, Regex_Vm_Boundary_Param{false})
	case .Subject_Begin:
		regex_vm_compiler_push_inst(c, .Subject_Assertion, Regex_Vm_Subject_Param{true})
	case .Subject_End:
		regex_vm_compiler_push_inst(c, .Subject_Assertion, Regex_Vm_Subject_Param{false})
	case .Reset_Start:
		regex_vm_compiler_push_inst(c, .Save, Regex_Vm_Save_Param{0})
	}
	if c.failed {
		return 0
	}
	for fixup in goto_inner_end_offsets {
		end_pos := len(c.prog.instructions)
		c.prog.instructions[fixup].param = Regex_Vm_Jump_Param{end_pos - fixup}
	}
	if save {
		slot := node.value * 2 + 1 if !backward else node.value * 2
		regex_vm_compiler_push_inst(c, .Save, Regex_Vm_Save_Param{slot})
	}
	return start_pos
}

@(private = "file")
regex_vm_compiler_compile_node :: proc(c: ^Regex_Vm_Compiler, index: int, backward: bool) -> int {
	if c.failed {
		return 0
	}
	start_pos := len(c.prog.instructions)
	goto_ends := make([dynamic]int, 0, 4, context.temp_allocator)
	defer delete(goto_ends)
	quant := c.parsed.nodes[index].quant
	if quant.min == 0 {
		split_pos := regex_vm_compiler_push_inst(
			c,
			.Split,
			Regex_Vm_Split_Param{0, quant.greedy},
		)
		append(&goto_ends, split_pos)
	}
	inner_pos := regex_vm_compiler_compile_node_inner(c, index, backward)
	for _ in 1 ..< quant.min {
		inner_pos = regex_vm_compiler_compile_node_inner(c, index, backward)
	}
	if quant.max == Regex_Vm_Quantifier_Infinite {
		back := inner_pos - len(c.prog.instructions)
		regex_vm_compiler_push_inst(c, .Split, Regex_Vm_Split_Param{back, !quant.greedy})
	} else {
		low := max(1, quant.min)
		for _ in low ..< quant.max {
			split_pos := regex_vm_compiler_push_inst(
				c,
				.Split,
				Regex_Vm_Split_Param{0, quant.greedy},
			)
			append(&goto_ends, split_pos)
			regex_vm_compiler_compile_node_inner(c, index, backward)
		}
	}
	if !c.failed {
		for fixup in goto_ends {
			end_pos := len(c.prog.instructions)
			param := c.prog.instructions[fixup].param.(Regex_Vm_Split_Param)
			param.offset = end_pos - fixup
			c.prog.instructions[fixup].param = param
		}
	}
	return start_pos
}

// regex_vm_compiler_start_desc_node folds one AST node into the start
// description; the result reports whether subsequent nodes are still
// relevant (i.e. the node can match empty).
@(private = "file")
regex_vm_compiler_start_desc_node :: proc(
	c: ^Regex_Vm_Compiler,
	index: int,
	desc: ^Regex_Vm_Start_Desc,
	backward: bool,
) -> bool {
	add_multi_byte := proc(desc: ^Regex_Vm_Start_Desc) {
		for i in 0b11000000 ..< 0b11111000 {
			desc.bytes[i] = true
		}
	}
	node := c.parsed.nodes[index]
	switch node.op {
	case .Literal:
		if node.value < 128 {
			if node.ignore_case {
				desc.bytes[unicode_to_lower(rune(node.value))] = true
				desc.bytes[unicode_to_upper(rune(node.value))] = true
			} else {
				desc.bytes[node.value] = true
			}
		} else {
			add_multi_byte(desc)
		}
		return node.quant.min == 0
	case .Any_Char:
		if desc.offset + node.quant.max <= 255 {
			desc.offset += node.quant.max
			return true
		}
		for &b in desc.bytes {
			b = true
		}
		return node.quant.min == 0
	case .Any_Char_Except_New_Line:
		if desc.offset + node.quant.max <= 255 {
			desc.offset += node.quant.max
			return true
		}
		for cp in 0 ..< 128 {
			if cp != '\n' {
				desc.bytes[cp] = true
			}
		}
		return node.quant.min == 0
	case .Char_Class:
		char_class := c.parsed.char_classes[node.value]
		if char_class.ctypes == {} && !char_class.negative && !char_class.ignore_case {
			for r in char_class.ranges {
				lo := min(128, int(r.min))
				hi := min(128, int(r.max) + 1)
				for cp in lo ..< hi {
					desc.bytes[cp] = true
				}
				if r.max >= 128 {
					add_multi_byte(desc)
				}
			}
		} else {
			for cp in 0 ..< 128 {
				if desc.bytes[cp] || regex_vm_char_class_matches(char_class, rune(cp)) {
					desc.bytes[cp] = true
				}
			}
		}
		add_multi_byte(desc)
		return node.quant.min == 0
	case .Char_Type:
		for cp in 0 ..< 128 {
			if regex_vm_is_ctype(transmute(Regex_Vm_Char_Types)u8(node.value), rune(cp)) {
				desc.bytes[cp] = true
			}
		}
		add_multi_byte(desc)
		return node.quant.min == 0
	case .Sequence:
		it := regex_vm_child_iter_make(c.parsed.nodes[:], index, backward)
		for {
			child, ok := regex_vm_child_iter_next(&it)
			if !ok {
				break
			}
			if !regex_vm_compiler_start_desc_node(c, child, desc, backward) {
				return node.quant.min == 0
			}
		}
		return true
	case .Alternation:
		all_consumed := node.quant.min != 0
		it := regex_vm_child_iter_make(c.parsed.nodes[:], index, false)
		for {
			child, ok := regex_vm_child_iter_next(&it)
			if !ok {
				break
			}
			if regex_vm_compiler_start_desc_node(c, child, desc, backward) {
				all_consumed = false
			}
		}
		return !all_consumed
	case .Line_Start, .Line_End, .Word_Boundary, .Not_Word_Boundary,
	     .Subject_Begin, .Subject_End, .Reset_Start, .Look_Ahead,
	     .Negative_Look_Ahead, .Look_Behind, .Negative_Look_Behind:
		return true
	}
	unreachable()
}

@(private = "file")
regex_vm_compiler_compute_start_desc :: proc(
	c: ^Regex_Vm_Compiler,
	backward: bool,
) -> (
	desc: Regex_Vm_Start_Desc,
	ok: bool,
) {
	if regex_vm_compiler_start_desc_node(c, 0, &desc, backward) {
		return {}, false
	}
	any_false := false
	for b in desc.bytes {
		if !b {
			any_false = true
			break
		}
	}
	if !any_false {
		return {}, false
	}
	count := 0
	single := 0
	for b, i in desc.bytes {
		if b {
			count += 1
			single = i
		}
	}
	if count == 1 {
		desc.start_byte = u8(single)
	}
	return desc, true
}

@(private = "file")
regex_vm_compiler_optimize :: proc(c: ^Regex_Vm_Compiler, begin, end: int) {
	if .Optimize not_in c.flags || c.failed {
		return
	}
	is_jump := proc(op: Regex_Vm_Op) -> bool { return op == .Jump || op == .Split }
	targeted := make([]bool, end - begin, context.temp_allocator)
	defer delete(targeted, context.temp_allocator)
	for i in begin ..< end {
		inst := c.prog.instructions[i]
		if is_jump(inst.op) {
			target := 0
			#partial switch param in inst.param {
			case Regex_Vm_Jump_Param:
				target = i + param.offset
			case Regex_Vm_Split_Param:
				target = i + param.offset
			}
			targeted[target - begin] = true
		}
	}
	is_assertion := proc(op: Regex_Vm_Op) -> bool {
		return op == .Line_Assertion || op == .Subject_Assertion ||
			op == .Word_Boundary || op == .Look_Around
	}
	block_begin := begin
	for block_begin < end {
		block_end := block_begin + 1
		for block_end < end && !is_jump(c.prog.instructions[block_end].op) &&
		    !targeted[block_end - begin] {
			block_end += 1
		}
		// Move saves after all assertions on the same character.
		i := block_begin
		j := block_begin + 1
		for j < block_end {
			if c.prog.instructions[i].op == .Save &&
			   is_assertion(c.prog.instructions[j].op) {
				c.prog.instructions[i], c.prog.instructions[j] =
					c.prog.instructions[j], c.prog.instructions[i]
			}
			i += 1
			j += 1
		}
		block_begin = block_end
	}
}

// regex_vm_compile compiles the pattern re into bytecode (C++ compile_regex).
// On success the caller owns the program; on failure the caller owns the
// error message and the program is zero.
regex_vm_compile :: proc(
	re: string,
	flags: Regex_Vm_Compile_Flags,
	allocator := context.allocator,
) -> (
	prog: Regex_Vm_Compiled,
	err_msg: string,
	err: Regex_Vm_Error,
) {
	parsed, parse_msg, parse_err := regex_vm_parse(re, allocator)
	if parse_err != .None {
		return {}, parse_msg, parse_err
	}
	prog.allocator = allocator
	prog.instructions = make([dynamic]Regex_Vm_Inst, 0, len(parsed.nodes) + 1, allocator)
	prog.lookarounds = make([dynamic]int, 0, allocator)
	prog.first_backward_inst = -1
	c := Regex_Vm_Compiler{parsed = &parsed, prog = &prog, flags = flags, allocator = allocator}
	if .No_Forward not_in flags {
		if desc, ok := regex_vm_compiler_compute_start_desc(&c, false); ok {
			prog.forward_start = desc
			prog.has_forward_start = true
		}
		forward_begin := len(prog.instructions)
		regex_vm_compiler_compile_node(&c, 0, false)
		regex_vm_compiler_optimize(&c, forward_begin, len(prog.instructions))
		regex_vm_compiler_push_inst(&c, .Match)
	}
	if .Backward in flags {
		prog.first_backward_inst = len(prog.instructions)
		if desc, ok := regex_vm_compiler_compute_start_desc(&c, true); ok {
			prog.backward_start = desc
			prog.has_backward_start = true
		}
		backward_begin := len(prog.instructions)
		regex_vm_compiler_compile_node(&c, 0, true)
		regex_vm_compiler_optimize(&c, backward_begin, len(prog.instructions))
		regex_vm_compiler_push_inst(&c, .Match)
	}
	if c.failed {
		regex_vm_compiled_destroy(&prog)
		for &cc in parsed.char_classes {
			delete(cc.ranges)
		}
		delete(parsed.char_classes)
		for &nc in parsed.named_captures {
			delete(nc.name, allocator)
		}
		delete(parsed.named_captures)
		delete(parsed.nodes)
		return {}, c.err_msg, .Compile_Error
	}
	prog.char_classes = parsed.char_classes
	prog.named_captures = parsed.named_captures
	prog.save_count = parsed.capture_count * 2
	delete(parsed.nodes)
	return prog, "", .None
}

// Regex_Vm_Thread is one NFA thread: an instruction index plus a saves
// pool index (-1 when the thread saved nothing yet).
@(private = "file")
Regex_Vm_Thread :: struct {
	inst:  int,
	saves: int,
}

// Regex_Vm_Saves is one pooled capture vector with a reference count.
// Unmatched slots hold -1. When on the free list, next_free links it.
@(private = "file")
Regex_Vm_Saves :: struct {
	refcount:  int,
	next_free: int,
	pos:       []int,
}

// Regex_Vm_Exec_Config bundles the search range, subject range, and flags
// of one exec call (C++ ThreadedRegexVM::ExecConfig).
@(private = "file")
Regex_Vm_Exec_Config :: struct {
	begin:         int,
	end:           int,
	subject_begin: int,
	subject_end:   int,
	flags:         Regex_Vm_Exec_Flags,
}

// Regex_Vm is a threaded regex VM. It borrows prog (which must outlive
// the VM) and owns its thread stacks, saves pool, and step marks.
Regex_Vm :: struct {
	prog:       ^Regex_Vm_Compiled,
	mode:       Regex_Vm_Modes,
	current:    [dynamic]Regex_Vm_Thread,
	next:       [dynamic]Regex_Vm_Thread,
	saves:      [dynamic]Regex_Vm_Saves,
	step_marks: []u16,
	first_free: int,
	captures:   int,
	found_match: bool,
	allocator:  mem.Allocator,
}

// regex_vm_make creates a VM for prog in the given mode. Exactly one of
// Forward/Backward must be set, and prog must support that direction.
regex_vm_make :: proc(
	prog: ^Regex_Vm_Compiled,
	mode: Regex_Vm_Modes,
	allocator := context.allocator,
) -> Regex_Vm {
	forward := .Forward in mode
	backward := .Backward in mode
	assert(forward != backward)
	if forward {
		assert(prog.first_backward_inst != 0)
	} else {
		assert(prog.first_backward_inst >= 0)
	}
	return Regex_Vm{
		prog = prog,
		mode = mode,
		current = make([dynamic]Regex_Vm_Thread, 0, 4, allocator),
		next = make([dynamic]Regex_Vm_Thread, 0, 4, allocator),
		saves = make([dynamic]Regex_Vm_Saves, 0, allocator),
		step_marks = make([]u16, len(prog.instructions), allocator),
		first_free = -1,
		captures = -1,
		allocator = allocator,
	}
}

// regex_vm_destroy releases all VM state (but not the borrowed program).
regex_vm_destroy :: proc(vm: ^Regex_Vm) {
	for &s in vm.saves {
		delete(s.pos, vm.allocator)
	}
	delete(vm.saves)
	delete(vm.next)
	delete(vm.current)
	delete(vm.step_marks, vm.allocator)
	vm^ = {}
}

// regex_vm_captures returns the borrowed save pairs of the last match
// (begin/end byte offsets, -1 when unmatched), or an empty slice when the
// last exec found nothing. Valid until the next exec or destroy.
regex_vm_captures :: proc(vm: ^Regex_Vm) -> []int {
	if vm.captures >= 0 {
		return vm.saves[vm.captures].pos
	}
	return {}
}

@(private = "file")
regex_vm_new_saves :: proc(vm: ^Regex_Vm, copy_from: int) -> int {
	count := vm.prog.save_count
	if vm.first_free >= 0 {
		res := vm.first_free
		vm.first_free = vm.saves[res].next_free
		assert(vm.saves[res].refcount == 1)
		if copy_from >= 0 {
			copy(vm.saves[res].pos, vm.saves[copy_from].pos)
		} else {
			for &slot in vm.saves[res].pos {
				slot = -1
			}
		}
		return res
	}
	pos := make([]int, count, vm.allocator)
	if copy_from >= 0 {
		copy(pos, vm.saves[copy_from].pos)
	} else {
		for &slot in pos {
			slot = -1
		}
	}
	append(&vm.saves, Regex_Vm_Saves{refcount = 1, pos = pos})
	return len(vm.saves) - 1
}

@(private = "file")
regex_vm_release_saves :: proc(vm: ^Regex_Vm, index: int) {
	if index < 0 {
		return
	}
	if vm.saves[index].refcount == 1 {
		vm.saves[index].next_free = vm.first_free
		vm.first_free = index
	} else {
		vm.saves[index].refcount -= 1
	}
}

// regex_vm_prev_char returns the character start at or before pos - 1,
// bounded below by lower (C++ utf8::previous).
@(private = "file")
regex_vm_prev_char :: proc(s: string, pos, lower: int) -> int {
	p := pos
	if p > lower {
		p -= 1
	}
	for p > lower && !utf8_is_character_start(s[p]) {
		p -= 1
	}
	return p
}

// regex_vm_next_char returns the character start at or after pos + 1,
// bounded above by upper (C++ utf8::next).
@(private = "file")
regex_vm_next_char :: proc(s: string, pos, upper: int) -> int {
	p := pos
	if p < upper {
		p += 1
	}
	for p < upper && !utf8_is_character_start(s[p]) {
		p += 1
	}
	return p
}

@(private = "file")
regex_vm_is_line_start :: proc(subject: string, pos: int, config: Regex_Vm_Exec_Config) -> bool {
	if pos == config.subject_begin {
		return .Not_Begin_Of_Line not_in config.flags
	}
	return subject[pos - 1] == '\n'
}

@(private = "file")
regex_vm_is_line_end :: proc(subject: string, pos: int, config: Regex_Vm_Exec_Config) -> bool {
	if pos == config.subject_end {
		return .Not_End_Of_Line not_in config.flags
	}
	return subject[pos] == '\n'
}

@(private = "file")
regex_vm_is_word_boundary :: proc(subject: string, pos: int, config: Regex_Vm_Exec_Config) -> bool {
	if pos == config.subject_begin {
		return .Not_Begin_Of_Word not_in config.flags
	}
	if pos == config.subject_end {
		return .Not_End_Of_Word not_in config.flags
	}
	prev_start := regex_vm_prev_char(subject, pos, config.subject_begin)
	prev_cp := utf8_codepoint(subject[:config.subject_end], prev_start)
	cp := utf8_codepoint(subject[:config.subject_end], pos)
	return regex_vm_is_word(prev_cp) != regex_vm_is_word(cp)
}

@(private = "file")
regex_vm_lookaround :: proc(
	vm: ^Regex_Vm,
	param: Regex_Vm_Lookaround_Param,
	pos: int,
	subject: string,
	config: Regex_Vm_Exec_Config,
) -> bool {
	p := pos
	if !param.ahead {
		if p == config.subject_begin {
			return vm.prog.lookarounds[param.index] == Regex_Vm_Lookaround_End
		}
		p = regex_vm_prev_char(subject, p, config.subject_begin)
	}
	it := param.index
	for vm.prog.lookarounds[it] != Regex_Vm_Lookaround_End {
		if param.ahead && p == config.subject_end {
			return false
		}
		cp := utf8_codepoint(subject[:config.subject_end], p)
		if param.ignore_case {
			cp = unicode_to_lower(cp)
		}
		op := vm.prog.lookarounds[it]
		if op == Regex_Vm_Lookaround_Any_Char {
		} else if op == Regex_Vm_Lookaround_Any_Char_Except_New_Line {
			if cp == '\n' {
				return false
			}
		} else if op >= Regex_Vm_Lookaround_Char_Class && op < Regex_Vm_Lookaround_Char_Type {
			class_index := op - Regex_Vm_Lookaround_Char_Class
			if !regex_vm_char_class_matches(vm.prog.char_classes[class_index], cp) {
				return false
			}
		} else if op >= Regex_Vm_Lookaround_Char_Type && op < Regex_Vm_Lookaround_Op_End {
			if !regex_vm_is_ctype(transmute(Regex_Vm_Char_Types)u8(op & 0xFF), cp) {
				return false
			}
		} else if op != int(cp) {
			return false
		}
		if !param.ahead && p == config.subject_begin {
			return vm.prog.lookarounds[it + 1] == Regex_Vm_Lookaround_End
		}
		if param.ahead {
			p = regex_vm_next_char(subject, p, config.subject_end)
		} else {
			p = regex_vm_prev_char(subject, p, config.subject_begin)
		}
		it += 1
	}
	return true
}

// regex_vm_step_current_thread runs one thread until it consumes the
// current character, matches, or fails.
@(private = "file")
regex_vm_step_current_thread :: proc(
	vm: ^Regex_Vm,
	subject: string,
	pos: int,
	cp: rune,
	current_step: u16,
	config: Regex_Vm_Exec_Config,
) {
	thread := pop(&vm.current)
	insts := vm.prog.instructions[:]
	for {
		idx := thread.inst
		thread.inst += 1
		inst := insts[idx]
		// Another thread already executed this instruction for this
		// step, so this thread is redundant and can be dropped.
		if vm.step_marks[idx] == current_step {
			regex_vm_release_saves(vm, thread.saves)
			return
		}
		vm.step_marks[idx] = current_step
		switch inst.op {
		case .Match:
			search := .Search in vm.mode
			if (pos != config.end && !search) ||
			   (.Not_Initial_Null in config.flags && pos == config.begin) {
				regex_vm_release_saves(vm, thread.saves)
				return
			}
			regex_vm_release_saves(vm, vm.captures)
			vm.captures = thread.saves
			vm.found_match = true
			// Remove lower priority threads.
			for len(vm.current) > 0 {
				regex_vm_release_saves(vm, pop(&vm.current).saves)
			}
			return
		case .Literal:
			param := inst.param.(Regex_Vm_Literal)
			want := param.codepoint
			have := unicode_to_lower(cp) if param.ignore_case else cp
			if pos != config.end && want == have {
				append(&vm.next, thread)
				return
			}
			regex_vm_release_saves(vm, thread.saves)
			return
		case .Any_Char:
			append(&vm.next, thread)
			return
		case .Any_Char_Except_New_Line:
			if pos != config.end && cp != '\n' {
				append(&vm.next, thread)
				return
			}
			regex_vm_release_saves(vm, thread.saves)
			return
		case .Char_Range:
			param := inst.param.(Regex_Vm_Range_Param)
			actual := unicode_to_lower(cp) if param.ignore_case else cp
			if pos != config.end &&
			   (actual >= rune(param.min) && actual <= rune(param.max)) != param.negative {
				append(&vm.next, thread)
				return
			}
			regex_vm_release_saves(vm, thread.saves)
			return
		case .Char_Type:
			param := inst.param.(Regex_Vm_Char_Types)
			if pos != config.end && regex_vm_is_ctype(param, cp) {
				append(&vm.next, thread)
				return
			}
			regex_vm_release_saves(vm, thread.saves)
			return
		case .Char_Class:
			param := inst.param.(Regex_Vm_Class_Param)
			if pos != config.end &&
			   regex_vm_char_class_matches(vm.prog.char_classes[param.index], cp) {
				append(&vm.next, thread)
				return
			}
			regex_vm_release_saves(vm, thread.saves)
			return
		case .Jump:
			param := inst.param.(Regex_Vm_Jump_Param)
			thread.inst = idx + param.offset
		case .Split:
			param := inst.param.(Regex_Vm_Split_Param)
			target := idx + param.offset
			if vm.step_marks[target] != current_step {
				if thread.saves >= 0 {
					vm.saves[thread.saves].refcount += 1
				}
				cont := thread.inst
				if !param.prioritize_parent {
					cont, target = target, cont
				}
				append(&vm.current, Regex_Vm_Thread{target, thread.saves})
				thread.inst = cont
			}
		case .Save:
			if .No_Saves not_in vm.mode {
				param := inst.param.(Regex_Vm_Save_Param)
				if thread.saves < 0 {
					thread.saves = regex_vm_new_saves(vm, -1)
				} else if vm.saves[thread.saves].refcount > 1 {
					old := thread.saves
					vm.saves[old].refcount -= 1
					thread.saves = regex_vm_new_saves(vm, old)
				}
				vm.saves[thread.saves].pos[param.index] = pos
			}
		case .Line_Assertion:
			param := inst.param.(Regex_Vm_Line_Param)
			holds := regex_vm_is_line_start(subject, pos, config) if param.is_start else regex_vm_is_line_end(subject, pos, config)
			if !holds {
				regex_vm_release_saves(vm, thread.saves)
				return
			}
		case .Subject_Assertion:
			param := inst.param.(Regex_Vm_Subject_Param)
			want := config.subject_begin if param.is_begin else config.subject_end
			if pos != want {
				regex_vm_release_saves(vm, thread.saves)
				return
			}
		case .Word_Boundary:
			param := inst.param.(Regex_Vm_Boundary_Param)
			if regex_vm_is_word_boundary(subject, pos, config) != param.positive {
				regex_vm_release_saves(vm, thread.saves)
				return
			}
		case .Look_Around:
			param := inst.param.(Regex_Vm_Lookaround_Param)
			if regex_vm_lookaround(vm, param, pos, subject, config) != param.positive {
				regex_vm_release_saves(vm, thread.saves)
				return
			}
		}
	}
}

@(private = "file")
regex_vm_find_next_start :: proc(
	subject: string,
	start, end: int,
	desc: Regex_Vm_Start_Desc,
	forward: bool,
) -> int {
	pos := start
	if desc.start_byte != 0 {
		for pos != end {
			if forward {
				if subject[pos] == desc.start_byte {
					return regex_vm_retreat(subject, pos, start, desc.offset)
				}
				pos += 1
			} else {
				prev := regex_vm_prev_char(subject, pos, end)
				if subject[prev] == desc.start_byte {
					return regex_vm_advance_bounded(subject, pos, start, desc.offset)
				}
				pos = prev
			}
		}
	}
	for pos != end {
		if forward {
			if desc.bytes[subject[pos]] {
				return regex_vm_retreat(subject, pos, start, desc.offset)
			}
			pos += 1
		} else {
			prev := regex_vm_prev_char(subject, pos, end)
			if desc.bytes[subject[prev]] {
				return regex_vm_advance_bounded(subject, pos, start, desc.offset)
			}
			pos = prev
		}
	}
	return pos
}

// regex_vm_retreat moves back count characters from pos, stopping at lower
// (C++ utf8::advance with a negative count).
@(private = "file")
regex_vm_retreat :: proc(subject: string, pos, lower, count: int) -> int {
	p := pos
	for _ in 0 ..< count {
		if p == lower {
			break
		}
		p = regex_vm_prev_char(subject, p, lower)
	}
	return p
}

// regex_vm_advance_bounded moves forward count characters from pos,
// stopping at upper.
@(private = "file")
regex_vm_advance_bounded :: proc(subject: string, pos, upper, count: int) -> int {
	p := pos
	for _ in 0 ..< count {
		if p == upper {
			break
		}
		p = regex_vm_next_char(subject, p, upper)
	}
	return p
}

// regex_vm_exec runs the program over the search range (C++ exec_program).
// idle, when not nil, runs every 16M steps as a progress hook.
regex_vm_exec :: proc(
	vm: ^Regex_Vm,
	subject: string,
	search_begin, search_end: int,
	subject_begin, subject_end: int,
	flags: Regex_Vm_Exec_Flags,
	idle: proc() = nil,
) -> bool {
	forward := .Forward in vm.mode
	assert(.Backward in vm.mode != forward)
	if .Not_Initial_Null in flags && search_begin == search_end {
		return false
	}
	config := Regex_Vm_Exec_Config{
		begin = search_begin if forward else search_end,
		end = search_end if forward else search_begin,
		subject_begin = subject_begin,
		subject_end = subject_end,
		flags = flags,
	}
	clear(&vm.current)
	clear(&vm.next)
	// Release leftover next threads on every return, as the C++ does.
	defer for len(vm.next) > 0 {
		regex_vm_release_saves(vm, pop(&vm.next).saves)
	}
	regex_vm_release_saves(vm, vm.captures)
	vm.captures = -1
	vm.found_match = false

	inst_begin := 0
	inst_end := len(vm.prog.instructions)
	has_start := vm.prog.has_forward_start
	if !forward {
		inst_begin = vm.prog.first_backward_inst
		has_start = vm.prog.has_backward_start
	}
	start_desc := &vm.prog.forward_start if forward else &vm.prog.backward_start
	next_start := config.begin
	if has_start {
		if .Search in vm.mode {
			next_start = regex_vm_find_next_start(
				subject,
				config.begin,
				config.end,
				start_desc^,
				forward,
			)
		}
		// A non-null start description means at least one char is consumed.
		if next_start == config.end {
			return false
		}
		if .Search not_in vm.mode {
			first := subject[config.begin] if forward else subject[config.begin - 1]
			if !start_desc.bytes[first] {
				return false
			}
		}
	}
	append(&vm.current, Regex_Vm_Thread{inst_begin, -1})

	// Start wrapped so the first increment resets all marks: each exec
	// begins with fresh deduplication state, as in the C++.
	current_step: u16 = max(u16)
	idle_count: u8 = 0
	pos := next_start
	for pos != config.end {
		current_step += 1
		if current_step == 0 {
			// Wrapped: reset marks to avoid collisions (step 0 is never valid).
			idle_count += 1
			if idle_count == 0 && idle != nil {
				idle()
			}
			for i in inst_begin ..< inst_end {
				vm.step_marks[i] = 0
			}
			current_step = 1
		}
		next := pos
		cp: rune
		if forward {
			cp = utf8_read_codepoint(subject[:config.end], &next)
		} else {
			next = regex_vm_prev_char(subject, pos, config.end)
			cp = utf8_codepoint(subject[:config.begin], next)
		}
		for len(vm.current) > 0 {
			regex_vm_step_current_thread(vm, subject, pos, cp, current_step, config)
		}
		if .Search in vm.mode && !vm.found_match {
			if has_start {
				if pos == next_start {
					next_start = regex_vm_find_next_start(
						subject,
						next,
						config.end,
						start_desc^,
						forward,
					)
				}
				if len(vm.next) == 0 {
					next = next_start
				}
			}
			if !has_start || next == next_start {
				append(&vm.next, Regex_Vm_Thread{inst_begin, -1})
			}
		} else if len(vm.next) == 0 || (vm.found_match && .Any_Match in vm.mode) {
			return vm.found_match
		}
		pos = next
		// Swap: current takes next's threads in push (FIFO) order.
		clear(&vm.current)
		for i := len(vm.next) - 1; i >= 0; i -= 1 {
			append(&vm.current, vm.next[i])
		}
		clear(&vm.next)
	}
	current_step += 1
	if current_step == 0 {
		for i in inst_begin ..< inst_end {
			vm.step_marks[i] = 0
		}
		current_step = 1
	}
	for len(vm.current) > 0 {
		regex_vm_step_current_thread(vm, subject, pos, -1, current_step, config)
	}
	return vm.found_match
}

@(private = "file")
regex_vm_dump_write_int :: proc(b: ^strings.Builder, v: int) {
	num := format_to_string_int(v, context.temp_allocator)
	defer delete(num, context.temp_allocator)
	strings.write_string(b, num)
}

// regex_vm_dump renders the program's instructions and start descriptions
// for debugging (C++ dump_regex). The caller owns the returned string.
regex_vm_dump :: proc(prog: ^Regex_Vm_Compiled, allocator := context.allocator) -> string {
	b := strings.builder_make(0, len(prog.instructions) * 32, allocator)
	for inst, index in prog.instructions {
		strings.write_byte(&b, ' ')
		regex_vm_dump_write_int(&b, index / 100)
		regex_vm_dump_write_int(&b, (index / 10) % 10)
		regex_vm_dump_write_int(&b, index % 10)
		strings.write_string(&b, "     ")
		switch inst.op {
		case .Literal:
			param := inst.param.(Regex_Vm_Literal)
			strings.write_string(&b, "literal ")
			if param.ignore_case {
				strings.write_string(&b, "(ignore case) ")
			}
			regex_vm_dump_write_int(&b, int(param.codepoint))
			strings.write_byte(&b, '\n')
		case .Any_Char:
			strings.write_string(&b, "any char\n")
		case .Any_Char_Except_New_Line:
			strings.write_string(&b, "anything but newline\n")
		case .Char_Range:
			param := inst.param.(Regex_Vm_Range_Param)
			strings.write_string(&b, "character range ")
			if param.ignore_case {
				strings.write_string(&b, "(ignore case) ")
			}
			strings.write_byte(&b, '[')
			if param.negative {
				strings.write_byte(&b, '^')
			}
			regex_vm_dump_write_int(&b, int(param.min))
			strings.write_byte(&b, '-')
			regex_vm_dump_write_int(&b, int(param.max))
			strings.write_string(&b, "]\n")
		case .Char_Type:
			param := inst.param.(Regex_Vm_Char_Types)
			strings.write_string(&b, "character type ")
			regex_vm_dump_write_int(&b, int(transmute(u8)param))
			strings.write_byte(&b, '\n')
		case .Char_Class:
			param := inst.param.(Regex_Vm_Class_Param)
			strings.write_string(&b, "character class ")
			regex_vm_dump_write_int(&b, param.index)
			strings.write_byte(&b, '\n')
		case .Jump:
			param := inst.param.(Regex_Vm_Jump_Param)
			strings.write_string(&b, "jump ")
			regex_vm_dump_write_int(&b, param.offset)
			strings.write_string(&b, " (")
			regex_vm_dump_write_int(&b, (index + param.offset) / 100)
			regex_vm_dump_write_int(&b, ((index + param.offset) / 10) % 10)
			regex_vm_dump_write_int(&b, (index + param.offset) % 10)
			strings.write_string(&b, ")\n")
		case .Split:
			param := inst.param.(Regex_Vm_Split_Param)
			strings.write_string(&b, "split (prioritize ")
			strings.write_string(&b, "parent" if param.prioritize_parent else "child")
			strings.write_string(&b, ") ")
			regex_vm_dump_write_int(&b, param.offset)
			strings.write_string(&b, " (")
			regex_vm_dump_write_int(&b, (index + param.offset) / 100)
			regex_vm_dump_write_int(&b, ((index + param.offset) / 10) % 10)
			regex_vm_dump_write_int(&b, (index + param.offset) % 10)
			strings.write_string(&b, ")\n")
		case .Save:
			param := inst.param.(Regex_Vm_Save_Param)
			strings.write_string(&b, "save ")
			regex_vm_dump_write_int(&b, param.index)
			strings.write_byte(&b, '\n')
		case .Line_Assertion:
			param := inst.param.(Regex_Vm_Line_Param)
			strings.write_string(&b, "line ")
			strings.write_string(&b, "start\n" if param.is_start else "end\n")
		case .Subject_Assertion:
			param := inst.param.(Regex_Vm_Subject_Param)
			strings.write_string(&b, "subject ")
			strings.write_string(&b, "begin\n" if param.is_begin else "end\n")
		case .Word_Boundary:
			param := inst.param.(Regex_Vm_Boundary_Param)
			if !param.positive {
				strings.write_string(&b, "not ")
			}
			strings.write_string(&b, "word boundary\n")
		case .Look_Around:
			param := inst.param.(Regex_Vm_Lookaround_Param)
			if !param.positive {
				strings.write_string(&b, "negative ")
			}
			strings.write_string(&b, "look ")
			strings.write_string(&b, "ahead " if param.ahead else "behind ")
			if param.ignore_case {
				strings.write_string(&b, " (ignore case)")
			}
			strings.write_string(&b, " (")
			it := param.index
			for prog.lookarounds[it] != Regex_Vm_Lookaround_End {
				buf: [4]byte
				n := utf8_dump(rune(prog.lookarounds[it]), buf[:])
				strings.write_string(&b, string(buf[:n]))
				it += 1
			}
			strings.write_string(&b, ")\n")
		case .Match:
			strings.write_string(&b, "match\n")
		}
	}
	dump_desc := proc(b: ^strings.Builder, desc: Regex_Vm_Start_Desc, name: string) {
		strings.write_string(b, name)
		strings.write_string(b, " start desc: [")
		for c in 0 ..< 256 {
			if desc.bytes[c] {
				if c < 32 {
					strings.write_string(b, "<0x")
					digits := "0123456789abcdef"
					if c >= 16 {
						strings.write_byte(b, digits[c / 16])
					}
					strings.write_byte(b, digits[c % 16])
					strings.write_byte(b, '>')
				} else {
					strings.write_byte(b, u8(c))
				}
			}
		}
		strings.write_string(b, "]+")
		regex_vm_dump_write_int(b, desc.offset)
		strings.write_byte(b, '\n')
	}
	if prog.has_forward_start {
		dump_desc(&b, prog.forward_start, "forward")
	}
	if prog.has_backward_start {
		dump_desc(&b, prog.backward_start, "backward")
	}
	return strings.to_string(b)
}
