// Port of Kakoune's src/format.{hh,cc}.
//
// Placeholders: `{}` takes params in order, `{n}` takes params[n],
// `{n:w}` / `{:w}` left-pad the value to w columns with spaces, and
// a `0` flag (`{:02}`) pads with zeros instead. `\{` escapes a brace
// (any other backslash is literal) and `}` outside a placeholder is
// literal. After an explicit `{n}` the next implicit `{}` takes
// params[n+1], exactly like the C++.
//
// Ports `to_string`, `Hex`/`hex`, `Grouped`/`grouped`, `format`,
// `format_to` and `format_with`. C++ `InplaceString` is an
// implementation detail of the by-value `format_param` conversion
// and is not ported: every conversion here returns an owned string.
// C++ `String`/`StringView` params become `[]string`, and the
// `FunctionRef` append callback becomes Format_Append with an
// explicit context pointer (Odin procs cannot close over state).
//
// The C++ `runtime_error` throws become Format_Error. Index and
// width fields are parsed with string_utils_str_to_int, and padding
// widths are measured with string_utils_column_length.
//
// Ownership: procs returning `string` allocate with `allocator`
// (default `context.allocator`); the caller frees with
// `delete(s, allocator)`. Nothing is allocated on the error path.
// format_to_buffer writes into the caller's buffer (NUL-terminated
// like the C++) and returns a slice of it.
package kak

import "base:intrinsics"
import "core:strconv"
import "core:strings"

// Format_Error reports formatting failures. Zero value `None` is success.
Format_Error :: enum {
	None,
	// A '{' placeholder was never closed.
	Unclosed_Brace,
	// A placeholder index is negative, not a number is Invalid_Number,
	// or beyond the end of params (the C++ indexes out of bounds,
	// which is undefined behavior for a negative index).
	Param_Index_Too_Big,
	// A placeholder index or width field is not a valid integer
	// (C++ throws runtime_error via str_to_int).
	Invalid_Number,
	// format_to_buffer output (plus the NUL) does not fit the buffer.
	Buffer_Too_Small,
}

// Format_Hex wraps an integer for lowercase hexadecimal conversion
// (port of C++ Hex; see format_hex).
Format_Hex :: struct {
	val: uint,
}

// format_hex wraps val for hexadecimal conversion (port of C++ hex).
format_hex :: proc(val: uint) -> Format_Hex {
	return {val}
}

// Format_Grouped wraps an integer for thousands-separated decimal
// conversion (port of C++ Grouped; see format_grouped).
Format_Grouped :: struct {
	val: uint,
}

// format_grouped wraps val for grouped conversion (port of C++ grouped).
format_grouped :: proc(val: uint) -> Format_Grouped {
	return {val}
}

// format_to_string_int converts any integer type to decimal (port of
// the int/unsigned/long/unsigned long/long long to_string overloads).
// Caller frees the result.
format_to_string_int :: proc(val: $T, allocator := context.allocator) -> string where intrinsics.type_is_integer(T) {
	// Wide enough for u128 max (39 digits) plus a sign.
	digits: [40]byte
	n := 0
	v := val
	if v == 0 {
		digits[0] = '0'
		n = 1
	}
	for v != 0 {
		d := v % 10
		if d < 0 {
			d = -d
		}
		digits[n] = byte('0' + d)
		n += 1
		v /= 10
	}
	b := strings.builder_make(0, n + 1, allocator)
	if val < 0 {
		strings.write_byte(&b, '-')
	}
	for i := n - 1; i >= 0; i -= 1 {
		strings.write_byte(&b, digits[i])
	}
	return strings.to_string(b)
}

// format_to_string_hex converts to lowercase hex without any prefix
// (port of to_string(Hex); std::to_chars base 16 is lowercase).
// Caller frees the result.
format_to_string_hex :: proc(val: Format_Hex, allocator := context.allocator) -> string {
	digits: [16]byte
	n := 0
	v := val.val
	if v == 0 {
		digits[0] = '0'
		n = 1
	}
	for v != 0 {
		d := v % 16
		if d < 10 {
			digits[n] = byte('0' + d)
		} else {
			digits[n] = byte('a' + (d - 10))
		}
		n += 1
		v /= 16
	}
	b := strings.builder_make(0, n, allocator)
	for i := n - 1; i >= 0; i -= 1 {
		strings.write_byte(&b, digits[i])
	}
	return strings.to_string(b)
}

// format_to_string_grouped converts to decimal with ',' thousands
// separators (port of to_string(Grouped)). Caller frees the result.
//
// Deviation: the C++ writes into a fixed 23-byte buffer, which
// overflows for values whose grouped form exceeds 23 bytes (any
// uint64 above 999,999,999,999,999); here the result is exactly sized.
format_to_string_grouped :: proc(val: Format_Grouped, allocator := context.allocator) -> string {
	digits: [20]byte
	n := 0
	v := val.val
	if v == 0 {
		digits[0] = '0'
		n = 1
	}
	for v != 0 {
		digits[n] = byte('0' + (v % 10))
		n += 1
		v /= 10
	}
	b := strings.builder_make(0, n + (n - 1) / 3, allocator)
	written := 0
	for i := n - 1; i >= 0; i -= 1 {
		// Comma before every group of three digits but the first:
		// i+1 is the count of digits from here to the end.
		if written > 0 && (i + 1) % 3 == 0 {
			strings.write_byte(&b, ',')
			written += 1
		}
		strings.write_byte(&b, digits[i])
		written += 1
	}
	return strings.to_string(b)
}

// format_to_string_float converts a float with shortest
// round-trip general formatting (port of to_string(float), which
// uses std::to_chars with chars_format::general). Caller frees the
// result.
//
// Deviation: digits come from core:strconv's shortest formatting
// rather than libc's to_chars; the two agree on every golden in
// format_test.odin but are distinct implementations, so exotic
// values could differ in exponent styling.
format_to_string_float :: proc(val: f32, allocator := context.allocator) -> string {
	buf: [64]byte
	// generic_ftoa always emits a sign; to_chars only emits '-'.
	out := strconv.generic_ftoa(buf[:], f64(val), 'g', -1, 32)
	if len(out) > 0 && out[0] == '+' {
		out = out[1:]
	}
	return strings.clone(string(out), allocator)
}

// format_to_string_codepoint encodes one codepoint as UTF-8 (port of
// to_string(Codepoint), via utf8_dump). Caller frees the result.
format_to_string_codepoint :: proc(cp: rune, allocator := context.allocator) -> string {
	buf: [4]byte
	n := utf8_dump(cp, buf[:])
	return strings.clone(string(buf[:n]), allocator)
}

// format_to_string converts one value to its display string. Grouped
// port of the C++ to_string overloads (the StronglyTypedNumber
// overload has no Odin counterpart: no such types are ported yet).
format_to_string :: proc {
	format_to_string_int,
	format_to_string_hex,
	format_to_string_grouped,
	format_to_string_float,
	format_to_string_codepoint,
}

// Format_Append receives one output piece; ctx is opaque caller
// state (port of the FunctionRef<void (StringView)> parameter).
Format_Append :: proc(ctx: rawptr, s: string)

// format_impl expands fmt against params, delivering literal spans,
// padding and param values to append in order. It is the shared
// engine behind format_format, format_to_buffer and format_with
// (port of C++ format_impl).
@(private = "file")
format_impl :: proc(fmt: string, params: []string, append: Format_Append, ctx: rawptr) -> Format_Error {
	implicit := 0
	i := 0
	for i < len(fmt) {
		open := -1
		for j := i; j < len(fmt); j += 1 {
			if fmt[j] == '{' {
				open = j
				break
			}
		}
		if open == -1 {
			append(ctx, fmt[i:])
			break
		}
		if open != i && fmt[open - 1] == '\\' {
			append(ctx, fmt[i:open - 1])
			append(ctx, "{")
			i = open + 1
			continue
		}
		append(ctx, fmt[i:open])
		close := -1
		for j := open; j < len(fmt); j += 1 {
			if fmt[j] == '}' {
				close = j
				break
			}
		}
		if close == -1 {
			return .Unclosed_Brace
		}
		colon := close
		for j := open + 1; j < close; j += 1 {
			if fmt[j] == ':' {
				colon = j
				break
			}
		}
		index := implicit
		if open + 1 != colon {
			v, err := string_utils_str_to_int(fmt[open + 1:colon])
			if err != .None {
				return .Invalid_Number
			}
			index = v
		}
		if index < 0 || index >= len(params) {
			return .Param_Index_Too_Big
		}
		if colon != close {
			padding := " "
			spec := colon + 1
			if spec < close && fmt[spec] == '0' {
				padding = "0"
				spec += 1
			}
			width, err := string_utils_str_to_int(fmt[spec:close])
			if err != .None {
				return .Invalid_Number
			}
			// One append call per pad char, like the C++ loop.
			for _ in string_utils_column_length(params[index]) ..< width {
				append(ctx, padding)
			}
		}
		append(ctx, params[index])
		implicit = index + 1
		i = close + 1
	}
	return .None
}

// format_format expands fmt against params (port of C++ format).
// Caller frees the result; nothing is allocated on the error path.
format_format :: proc(fmt: string, params: []string, allocator := context.allocator) -> (string, Format_Error) {
	capacity := len(fmt)
	for p in params {
		capacity += len(p)
	}
	b := strings.builder_make(0, capacity, allocator)
	collect :: proc(ctx: rawptr, s: string) {
		strings.write_string((^strings.Builder)(ctx), s)
	}
	if err := format_impl(fmt, params, collect, &b); err != .None {
		strings.builder_destroy(&b)
		return "", err
	}
	return strings.to_string(b), .None
}

// Format_Buffer_State is the Format_Append context for
// format_to_buffer: the target buffer, the bytes written, and a
// sticky overflow flag (the C++ throws mid-write instead).
@(private = "file")
Format_Buffer_State :: struct {
	buf:      []byte,
	pos:      int,
	overflow: bool,
}

// format_to_buffer expands fmt against params into buf, NUL-terminates
// it, and returns the written bytes as a slice of buf (port of C++
// format_to). Like the C++, output that exactly fills buf still fails,
// because the NUL needs one byte.
format_to_buffer :: proc(buf: []byte, fmt: string, params: []string) -> (string, Format_Error) {
	st := Format_Buffer_State{buf, 0, false}
	collect :: proc(ctx: rawptr, s: string) {
		st := (^Format_Buffer_State)(ctx)
		for i := 0; i < len(s); i += 1 {
			if st.pos >= len(st.buf) {
				st.overflow = true
				return
			}
			st.buf[st.pos] = s[i]
			st.pos += 1
		}
	}
	if err := format_impl(fmt, params, collect, &st); err != .None {
		return "", err
	}
	if st.overflow || st.pos >= len(st.buf) {
		return "", .Buffer_Too_Small
	}
	st.buf[st.pos] = 0
	return string(st.buf[:st.pos]), .None
}

// format_with expands fmt against params, delivering each piece to
// append (port of C++ format_with).
format_with :: proc(append: Format_Append, ctx: rawptr, fmt: string, params: []string) -> Format_Error {
	return format_impl(fmt, params, append, ctx)
}
