// Tests for the option_types port: the C++ test_option_parsing checks
// first, then edge cases for every conversion.
package kak

import "core:slice"
import "core:strings"
import "core:testing"

// option_types_test_check_strings asserts two string slices hold the
// same strings in order.
option_types_test_check_strings :: proc(t: ^testing.T, got, want: []string) {
	testing.expect_value(t, len(got), len(want))
	if len(got) != len(want) {
		return
	}
	for i := 0; i < len(want); i += 1 {
		testing.expect_value(t, got[i], want[i])
	}
}

// option_types_test_delete_map frees a map that owns its string keys.
// Takes a pointer so deferred calls see later insertions.
option_types_test_delete_map :: proc(m: ^map[string]int) {
	for k in m^ {
		delete(k)
	}
	delete(m^)
}

// option_types_test_check_map asserts two string-to-int maps are equal.
option_types_test_check_map :: proc(t: ^testing.T, got, want: map[string]int) {
	testing.expect_value(t, len(got), len(want))
	for k, v in want {
		gv, ok := got[k]
		testing.expect(t, ok)
		if ok {
			testing.expect_value(t, gv, v)
		}
	}
}

// option_types_test_delete_strings frees owned strings and their slice.
// Takes a pointer so deferred calls see the final contents (defer runs
// at scope exit, so cleanup loops must not defer per element).
option_types_test_delete_strings :: proc(strs: ^[]string) {
	for s in strs^ {
		delete(s)
	}
	delete(strs^)
}

// option_types_test_delete_string_list frees an owned string vector.
option_types_test_delete_string_list :: proc(vec: ^[dynamic]string) {
	for s in vec^ {
		delete(s)
	}
	delete(vec^)
}

// option_types_test_free_string frees one parsed string for remove procs.
option_types_test_free_string :: proc(s: string) {
	delete(s)
}

// option_types_test_free_triple frees one parsed triple for remove procs.
option_types_test_free_triple :: proc(tr: Option_types_String_Triple) {
	delete(tr.first)
	delete(tr.second)
	delete(tr.third)
}

// Ports check(123, {"123"}).
@(test)
option_types_test_int_roundtrip :: proc(t: ^testing.T) {
	repr := option_types_int_to_strings(123)
	defer delete(repr)
	defer delete(repr[0])
	option_types_test_check_strings(t, repr, []string{"123"})

	parsed, err := option_types_int_from_strings(repr)
	testing.expect_value(t, err, Option_types_Error.None)
	testing.expect_value(t, parsed, 123)
}

// Ports check(true, {"true"}).
@(test)
option_types_test_bool_roundtrip :: proc(t: ^testing.T) {
	repr := option_types_bool_to_strings(true)
	defer delete(repr)
	option_types_test_check_strings(t, repr, []string{"true"})

	parsed, err := option_types_bool_from_strings(repr)
	testing.expect_value(t, err, Option_types_Error.None)
	testing.expect_value(t, parsed, true)
}

// Ports check({"foo", "bar:", "baz"}, {"foo", "bar:", "baz"}).
@(test)
option_types_test_string_list_roundtrip :: proc(t: ^testing.T) {
	vec := []string{"foo", "bar:", "baz"}
	repr := option_types_string_list_to_strings(vec)
	defer option_types_test_delete_strings(&repr)
	option_types_test_check_strings(t, repr, vec)

	parsed := option_types_string_list_from_strings(repr)
	defer option_types_test_delete_strings(&parsed)
	option_types_test_check_strings(t, parsed, vec)
}

// Ports check({10, 20, 30}, {"10", "20", "30"}).
@(test)
option_types_test_int_list_roundtrip :: proc(t: ^testing.T) {
	vec := []int{10, 20, 30}
	repr := option_types_int_list_to_strings(vec)
	defer option_types_test_delete_strings(&repr)
	option_types_test_check_strings(t, repr, []string{"10", "20", "30"})

	parsed, err := option_types_int_list_from_strings(repr)
	defer delete(parsed)
	testing.expect_value(t, err, Option_types_Error.None)
	testing.expect(t, slice.equal(parsed, vec))
}

// Ports check({{"foo", 10}, {"b=r", 20}, {"b:z", 30}},
// {"foo=10", "b\\=r=20", "b:z=30"}). Odin map iteration order is
// random, so both sides are sorted before comparing.
@(test)
option_types_test_string_int_map_roundtrip :: proc(t: ^testing.T) {
	m := make(map[string]int)
	defer option_types_test_delete_map(&m)
	m[strings.clone("foo")] = 10
	m[strings.clone("b=r")] = 20
	m[strings.clone("b:z")] = 30

	repr := option_types_string_int_map_to_strings(m)
	defer option_types_test_delete_strings(&repr)
	want := [3]string{"foo=10", "b\\=r=20", "b:z=30"}
	slice.sort(repr)
	slice.sort(want[:])
	option_types_test_check_strings(t, repr, want[:])

	parsed, err := option_types_string_int_map_from_strings(want[:])
	defer option_types_test_delete_map(&parsed)
	testing.expect_value(t, err, Option_types_Error.None)
	option_types_test_check_map(t, parsed, m)
}

// Ports check(DebugFlags::Keys | DebugFlags::Hooks, {"hooks|keys"}).
@(test)
option_types_test_debug_flags_roundtrip :: proc(t: ^testing.T) {
	flags := Option_types_Debug_Flags{.Keys, .Hooks}
	repr := option_types_debug_flags_to_strings(flags)
	defer delete(repr)
	defer delete(repr[0])
	option_types_test_check_strings(t, repr, []string{"hooks|keys"})

	parsed, err := option_types_debug_flags_from_strings(repr)
	testing.expect_value(t, err, Option_types_Error.None)
	testing.expect(t, parsed == flags)
}

@(test)
option_types_test_int_edges :: proc(t: ^testing.T) {
	// Bad inputs fail.
	cases_1 := []string{"", "-", "abc", "12x", "+5", " 5", "--1"}
	for s in cases_1 {
		_, err := option_types_int_from_string(s)
		testing.expect_value(t, err, Option_types_Error.NotANumber)
	}
	// Quirks inherited from str_to_int.
	zero, zero_err := option_types_int_from_string("00")
	testing.expect_value(t, zero_err, Option_types_Error.None)
	testing.expect_value(t, zero, 0)
	neg_zero, _ := option_types_int_from_string("-0")
	testing.expect_value(t, neg_zero, 0)
	// 32 bit wraparound.
	wrapped, _ := option_types_int_from_string("4294967296")
	testing.expect_value(t, wrapped, 0)
	min32, _ := option_types_int_from_string("2147483648")
	testing.expect_value(t, min32, -2147483648)
	// Add/remove report whether the value changed.
	opt := 10
	changed, add_err := option_types_int_add(&opt, "5")
	testing.expect_value(t, add_err, Option_types_Error.None)
	testing.expect(t, changed)
	testing.expect_value(t, opt, 15)
	changed, _ = option_types_int_add(&opt, "0")
	testing.expect(t, !changed)
	rem_err: Option_types_Error
	changed, rem_err = option_types_int_remove(&opt, "3")
	testing.expect_value(t, rem_err, Option_types_Error.None)
	testing.expect(t, changed)
	testing.expect_value(t, opt, 12)
	_, bad_err := option_types_int_add(&opt, "xx")
	testing.expect_value(t, bad_err, Option_types_Error.NotANumber)
	testing.expect_value(t, opt, 12)
	// Multi-value inputs are rejected.
	_, none_err := option_types_int_from_strings(nil)
	testing.expect_value(t, none_err, Option_types_Error.ExpectedSingleValue)
	_, two_err := option_types_int_from_strings([]string{"1", "2"})
	testing.expect_value(t, two_err, Option_types_Error.ExpectedSingleValue)
}

@(test)
option_types_test_uint_edges :: proc(t: ^testing.T) {
	v, err := option_types_uint_from_string("42")
	testing.expect_value(t, err, Option_types_Error.None)
	testing.expect_value(t, v, uint(42))
	wrapped, werr := option_types_uint_from_string("-1")
	testing.expect_value(t, werr, Option_types_Error.None)
	testing.expect_value(t, wrapped, max(uint))
	s := option_types_uint_to_string(42)
	defer delete(s)
	testing.expect_value(t, s, "42")
}

@(test)
option_types_test_bool_edges :: proc(t: ^testing.T) {
	cases_2 := []string{"true", "yes"}
	for s in cases_2 {
		v, err := option_types_bool_from_string(s)
		testing.expect_value(t, err, Option_types_Error.None)
		testing.expect(t, v)
	}
	cases_3 := []string{"false", "no"}
	for s in cases_3 {
		v, err := option_types_bool_from_string(s)
		testing.expect_value(t, err, Option_types_Error.None)
		testing.expect(t, !v)
	}
	cases_4 := []string{"", "1", "True", "TRUE", "y"}
	for s in cases_4 {
		_, err := option_types_bool_from_string(s)
		testing.expect_value(t, err, Option_types_Error.InvalidBool)
	}
	testing.expect_value(t, option_types_bool_to_string(false), "false")
}

@(test)
option_types_test_string_quoting :: proc(t: ^testing.T) {
	raw := option_types_string_to_string("it's", .Raw)
	defer delete(raw)
	testing.expect_value(t, raw, "it's")
	kak := option_types_string_to_string("it's", .Kakoune)
	defer delete(kak)
	testing.expect_value(t, kak, "'it''s'")
	sh := option_types_string_to_string("it's", .Shell)
	defer delete(sh)
	testing.expect_value(t, sh, "'it'\\''s'")

	opt := "foo"
	testing.expect(t, option_types_string_add(&opt, "bar"))
	testing.expect_value(t, opt, "foobar")
	delete(opt)
	opt = "foo"
	testing.expect(t, !option_types_string_add(&opt, ""))
	testing.expect_value(t, opt, "foo")
	delete(opt)
}

@(test)
option_types_test_codepoint_edges :: proc(t: ^testing.T) {
	c, err := option_types_codepoint_from_string("a")
	testing.expect_value(t, err, Option_types_Error.None)
	testing.expect_value(t, c, 'a')
	uni, uerr := option_types_codepoint_from_string("é")
	testing.expect_value(t, uerr, Option_types_Error.None)
	testing.expect_value(t, uni, 'é')
	cases_5 := []string{"", "ab", "aé"}
	for s in cases_5 {
		_, cerr := option_types_codepoint_from_string(s)
		testing.expect_value(t, cerr, Option_types_Error.NotSingleCodepoint)
	}
	q := option_types_codepoint_to_string('\'', .Kakoune)
	defer delete(q)
	testing.expect_value(t, q, "''''")
}

@(test)
option_types_test_coord_edges :: proc(t: ^testing.T) {
	c, err := option_types_coord_from_string("3,7")
	testing.expect_value(t, err, Option_types_Error.None)
	testing.expect_value(t, c, Option_types_Coord{3, 7})
	s := option_types_coord_to_string(c)
	defer delete(s)
	testing.expect_value(t, s, "3,7")
	cases_6 := []string{"3", "3,7,9", "", ",", "a,b", "3,x"}
	for bad in cases_6 {
		_, berr := option_types_coord_from_string(bad)
		testing.expect(t, berr != Option_types_Error.None)
	}
	_, cerr := option_types_coord_from_strings([]string{"1,2", "3,4"})
	testing.expect_value(t, cerr, Option_types_Error.ExpectedSingleValue)
}

@(test)
option_types_test_debug_flags_edges :: proc(t: ^testing.T) {
	empty, eerr := option_types_debug_flags_from_string("")
	testing.expect_value(t, eerr, Option_types_Error.None)
	testing.expect(t, empty == {})
	es := option_types_debug_flags_to_string({})
	defer delete(es)
	testing.expect_value(t, es, "")

	all, aerr := option_types_debug_flags_from_string("hooks|shell|profile|keys|commands")
	testing.expect_value(t, aerr, Option_types_Error.None)
	testing.expect(t, all == {.Hooks, .Shell, .Profile, .Keys, .Commands})
	dup, derr := option_types_debug_flags_from_string("keys|keys")
	testing.expect_value(t, derr, Option_types_Error.None)
	testing.expect(t, dup == {.Keys})
	cases_7 := []string{"bogus", "hooks|", "|hooks", "Hooks", "hooks||keys"}
	for bad in cases_7 {
		_, berr := option_types_debug_flags_from_string(bad)
		testing.expect_value(t, berr, Option_types_Error.InvalidFlagValue)
	}

	opt: Option_types_Debug_Flags = {.Hooks}
	added, _ := option_types_debug_flags_add(&opt, "keys")
	testing.expect(t, added)
	testing.expect(t, opt == {.Hooks, .Keys})
	added, _ = option_types_debug_flags_add(&opt, "keys")
	testing.expect(t, !added)
	removed, _ := option_types_debug_flags_remove(&opt, "hooks|shell")
	testing.expect(t, removed)
	testing.expect(t, opt == {.Keys})
	removed, _ = option_types_debug_flags_remove(&opt, "shell")
	testing.expect(t, !removed)
	_, bad_add := option_types_debug_flags_add(&opt, "bogus")
	testing.expect_value(t, bad_add, Option_types_Error.InvalidFlagValue)
	testing.expect(t, opt == {.Keys})
}

@(test)
option_types_test_quoting_enum :: proc(t: ^testing.T) {
	for q in Option_types_Quoting {
		name := option_types_quoting_to_string(q)
		back, err := option_types_quoting_from_string(name)
		testing.expect_value(t, err, Option_types_Error.None)
		testing.expect(t, back == q)
	}
	_, err := option_types_quoting_from_string("bogus")
	testing.expect_value(t, err, Option_types_Error.InvalidEnumValue)
}

@(test)
option_types_test_string_list_add_remove :: proc(t: ^testing.T) {
	vec := make([dynamic]string)
	testing.expect(t, option_types_string_list_add(&vec, []string{"a", "b", "a"}))
	testing.expect(t, !option_types_string_list_add(&vec, nil))
	// Removes only the first occurrence.
	doomed := vec[0]
	testing.expect(t, option_types_string_list_remove(&vec, []string{"a"}))
	delete(doomed)
	testing.expect(t, slice.equal(vec[:], []string{"b", "a"}))
	testing.expect(t, !option_types_string_list_remove(&vec, []string{"zzz"}))
	for s in vec {
		delete(s)
	}
	delete(vec)
}

@(test)
option_types_test_int_list_add_remove :: proc(t: ^testing.T) {
	vec := make([dynamic]int)
	added, add_err := option_types_int_list_add(&vec, []string{"1", "2"})
	testing.expect_value(t, add_err, Option_types_Error.None)
	testing.expect(t, added)
	// Add parses everything first: a bad element changes nothing.
	_, bad_err := option_types_int_list_add(&vec, []string{"4", "xx"})
	testing.expect_value(t, bad_err, Option_types_Error.NotANumber)
	testing.expect(t, slice.equal(vec[:], []int{1, 2}))
	// Remove is sequential: earlier removals stand on error.
	removed, rem_err := option_types_int_list_remove(&vec, []string{"1", "xx"})
	testing.expect_value(t, rem_err, Option_types_Error.NotANumber)
	testing.expect(t, removed)
	testing.expect(t, slice.equal(vec[:], []int{2}))
	removed, rem_err = option_types_int_list_remove(&vec, []string{"99"})
	testing.expect_value(t, rem_err, Option_types_Error.None)
	testing.expect(t, !removed)
	delete(vec)
}

@(test)
option_types_test_string_list_single_string :: proc(t: ^testing.T) {
	s := option_types_string_list_to_string([]string{"a'b", "c"}, .Kakoune)
	defer delete(s)
	testing.expect_value(t, s, "'a''b' 'c'")
	raw := option_types_string_list_to_string([]string{"a'b", "c"}, .Raw)
	defer delete(raw)
	testing.expect_value(t, raw, "a'b c")
	nums := option_types_int_list_to_string([]int{1, 2})
	defer delete(nums)
	testing.expect_value(t, nums, "1 2")
}

@(test)
option_types_test_map_add_remove :: proc(t: ^testing.T) {
	m := make(map[string]int)
	defer option_types_test_delete_map(&m)
	added, add_err := option_types_string_int_map_add(&m, []string{"a=1"})
	testing.expect_value(t, add_err, Option_types_Error.None)
	testing.expect(t, added)
	// Re-adding the same entry still reports a change.
	added, _ = option_types_string_int_map_add(&m, []string{"a=1"})
	testing.expect(t, added)
	// Later duplicates win.
	_, _ = option_types_string_int_map_add(&m, []string{"a=2", "b=3"})
	testing.expect_value(t, m["a"], 2)
	// Removing with a wrong value does nothing.
	removed, _ := option_types_string_int_map_remove(&m, []string{"a=99"})
	testing.expect(t, !removed)
	// An empty value part removes unconditionally.
	removed, _ = option_types_string_int_map_remove(&m, []string{"a="})
	testing.expect(t, removed)
	testing.expect(t, "a" not_in m)
	// A matching value removes; unknown keys and bad values do not.
	removed, _ = option_types_string_int_map_remove(&m, []string{"b=3"})
	testing.expect(t, removed)
	map_rem_err: Option_types_Error
	removed, map_rem_err = option_types_string_int_map_remove(&m, []string{"zzz="})
	testing.expect_value(t, map_rem_err, Option_types_Error.None)
	testing.expect(t, !removed)
	_, _ = option_types_string_int_map_add(&m, []string{"c=4"})
	removed, _ = option_types_string_int_map_remove(&m, []string{"c=nope"})
	testing.expect(t, !removed)
	testing.expect_value(t, m["c"], 4)
	// Malformed entries are errors.
	_, no_eq := option_types_string_int_map_add(&m, []string{"novalue"})
	testing.expect_value(t, no_eq, Option_types_Error.MapExpectsKeyValue)
	_, two_eq := option_types_string_int_map_add(&m, []string{"a=b=c"})
	testing.expect_value(t, two_eq, Option_types_Error.MapExpectsKeyValue)
	_, bad_int := option_types_string_int_map_add(&m, []string{"d=xx"})
	testing.expect_value(t, bad_int, Option_types_Error.NotANumber)
	_, rem_bad := option_types_string_int_map_remove(&m, []string{"novalue"})
	testing.expect_value(t, rem_bad, Option_types_Error.MapExpectsKeyValue)
}

@(test)
option_types_test_map_escapes :: proc(t: ^testing.T) {
	// Only '=' is escaped on output; backslash passes through, and
	// unescape restores both.
	entry := option_types_string_int_map_entry("b=r", 20)
	defer delete(entry)
	testing.expect_value(t, entry, "b\\=r=20")
	back, berr := option_types_string_int_map_from_strings([]string{"b\\=r=20"})
	defer option_types_test_delete_map(&back)
	testing.expect_value(t, berr, Option_types_Error.None)
	testing.expect_value(t, back["b=r"], 20)

	bs_entry := option_types_string_int_map_entry("a\\b", 1)
	defer delete(bs_entry)
	testing.expect_value(t, bs_entry, "a\\b=1")
	bs_back, _ := option_types_string_int_map_from_strings([]string{bs_entry})
	defer option_types_test_delete_map(&bs_back)
	testing.expect_value(t, len(bs_back), 1)
	testing.expect_value(t, bs_back["a\\b"], 1)

	mix_entry := option_types_string_int_map_entry("a=b\\c", 2)
	defer delete(mix_entry)
	testing.expect_value(t, mix_entry, "a\\=b\\c=2")
	mix_back, _ := option_types_string_int_map_from_strings([]string{mix_entry})
	defer option_types_test_delete_map(&mix_back)
	testing.expect_value(t, mix_back["a=b\\c"], 2)
}

@(test)
option_types_test_triple :: proc(t: ^testing.T) {
	tri := Option_types_String_Triple{"a", "b", "c"}
	s := option_types_string_triple_to_string(tri, .Raw)
	defer delete(s)
	testing.expect_value(t, s, "a|b|c")
	back, err := option_types_string_triple_from_string(s)
	defer delete(back.first)
	defer delete(back.second)
	defer delete(back.third)
	testing.expect_value(t, err, Option_types_Error.None)
	testing.expect(t, back == tri)

	tricky := Option_types_String_Triple{"a|b", "c\\d", "e"}
	ts := option_types_string_triple_to_string(tricky, .Raw)
	defer delete(ts)
	testing.expect_value(t, ts, "a\\|b|c\\\\d|e")
	tback, terr := option_types_string_triple_from_string(ts)
	defer delete(tback.first)
	defer delete(tback.second)
	defer delete(tback.third)
	testing.expect_value(t, terr, Option_types_Error.None)
	testing.expect(t, tback == tricky)

	q := option_types_string_triple_to_string(tri, .Kakoune)
	defer delete(q)
	testing.expect_value(t, q, "'a|b|c'")

	cases_8 := []string{"a|b", "a|", "", "a\\|b|c|d|e"}
	for bad in cases_8 {
		_, berr := option_types_string_triple_from_string(bad)
		testing.expect(t, berr != Option_types_Error.None)
	}
	_, few := option_types_string_triple_from_string("a|b")
	testing.expect_value(t, few, Option_types_Error.TupleTooFewElements)
	_, many := option_types_string_triple_from_string("a|b|c|d")
	testing.expect_value(t, many, Option_types_Error.TupleTooManyElements)
	_, serr := option_types_string_triple_from_strings(nil)
	testing.expect_value(t, serr, Option_types_Error.ExpectedSingleValue)
}

@(test)
option_types_test_prefixed_list :: proc(t: ^testing.T) {
	// Empty input yields zero values.
	empty, eerr := option_types_prefixed_list_from_strings(
		string, string, nil,
		option_types_string_from_string, option_types_string_from_string,
	)
	defer delete(empty.list)
	testing.expect_value(t, eerr, Option_types_Error.None)
	testing.expect_value(t, empty.prefix, "")
	testing.expect_value(t, len(empty.list), 0)

	// String prefix with a string list round-trips.
	pl, perr := option_types_prefixed_list_from_strings(
		string, string, []string{"pfx", "a", "b"},
		option_types_string_from_string, option_types_string_from_string,
	)
	testing.expect_value(t, perr, Option_types_Error.None)
	defer delete(pl.prefix)
	defer option_types_test_delete_string_list(&pl.list)
	testing.expect_value(t, pl.prefix, "pfx")
	repr := option_types_prefixed_list_to_strings(
		pl, option_types_string_to_string, option_types_string_to_string,
	)
	defer option_types_test_delete_strings(&repr)
	option_types_test_check_strings(t, repr, []string{"pfx", "a", "b"})

	single := option_types_prefixed_list_to_string(
		pl, .Raw, option_types_string_to_string, option_types_string_to_string,
	)
	defer delete(single)
	testing.expect_value(t, single, "pfx a b")
}

@(test)
option_types_test_prefixed_list_triples :: proc(t: ^testing.T) {
	// CompletionList shape: string prefix, triple elements.
	cl, err := option_types_prefixed_list_from_strings(
		string, Option_types_String_Triple, []string{"ctx", "a|b|c", "d|e|f"},
		option_types_string_from_string, option_types_string_triple_from_string,
	)
	testing.expect_value(t, err, Option_types_Error.None)
	defer delete(cl.prefix)
	testing.expect_value(t, cl.prefix, "ctx")
	testing.expect_value(t, len(cl.list), 2)
	testing.expect(t, cl.list[0] == Option_types_String_Triple{"a", "b", "c"})
	// Capture owned parts before add/remove shift the list.
	p0 := cl.list[0]
	p1 := cl.list[1]
	defer delete(p0.first)
	defer delete(p0.second)
	defer delete(p0.third)
	defer delete(p1.first)
	defer delete(p1.second)
	defer delete(p1.third)

	repr := option_types_prefixed_list_to_strings(
		cl, option_types_string_to_string, option_types_string_triple_to_string,
	)
	defer option_types_test_delete_strings(&repr)
	option_types_test_check_strings(t, repr, []string{"ctx", "a|b|c", "d|e|f"})

	added, aerr := option_types_prefixed_list_add(
		&cl, []string{"g|h|i"}, option_types_string_triple_from_string,
	)
	testing.expect_value(t, aerr, Option_types_Error.None)
	testing.expect(t, added)
	testing.expect_value(t, len(cl.list), 3)
	p2 := cl.list[2]
	defer delete(p2.first)
	defer delete(p2.second)
	defer delete(p2.third)
	removed, rerr := option_types_prefixed_list_remove(
		&cl,
		[]string{"d|e|f"},
		option_types_string_triple_from_string,
		option_types_test_free_triple,
	)
	testing.expect_value(t, rerr, Option_types_Error.None)
	testing.expect(t, removed)
	testing.expect_value(t, len(cl.list), 2)
	// Freed manually: the list grew after creation, so a deferred
	// header copy would be stale.
	delete(cl.list)
}

@(test)
option_types_test_type_names :: proc(t: ^testing.T) {
	testing.expect_value(t, option_types_int_type_name(), "int")
	testing.expect_value(t, option_types_bool_type_name(), "bool")
	testing.expect_value(t, option_types_string_type_name(), "str")
	testing.expect_value(t, option_types_codepoint_type_name(), "codepoint")
	testing.expect_value(t, option_types_coord_type_name(), "coord")
	testing.expect_value(t, option_types_string_list_type_name(), "str-list")
	testing.expect_value(t, option_types_int_list_type_name(), "int-list")
	testing.expect_value(t, option_types_string_int_map_type_name(), "str-to-int-map")
	testing.expect_value(
		t,
		option_types_debug_flags_type_name(),
		"flags(hooks|shell|profile|keys|commands)",
	)
	testing.expect_value(t, option_types_quoting_type_name(), "enum(raw|kakoune|shell)")
}

@(test)
option_types_test_split_primitives :: proc(t: ^testing.T) {
	empty := option_types_split("", ',', context.allocator)
	defer delete(empty)
	testing.expect_value(t, len(empty), 0)
	trail := option_types_split("a,", ',')
	defer delete(trail)
	option_types_test_check_strings(t, trail, []string{"a", ""})
	both := option_types_split(",", ',')
	defer delete(both)
	option_types_test_check_strings(t, both, []string{"", ""})

	esc := option_types_split_escaped("a\\=b=c", '=', '\\')
	defer delete(esc)
	option_types_test_check_strings(t, esc, []string{"a\\=b", "c"})
	esc_empty := option_types_split_escaped("", '=', '\\')
	defer delete(esc_empty)
	testing.expect_value(t, len(esc_empty), 0)

	kept := option_types_unescape("a\\xb", "=\\", '\\')
	defer delete(kept)
	testing.expect_value(t, kept, "a\\xb")
	trailing := option_types_unescape("ab\\", "=\\", '\\')
	defer delete(trailing)
	testing.expect_value(t, trailing, "ab\\")
	doubled := option_types_unescape("a\\\\b", "=\\", '\\')
	defer delete(doubled)
	testing.expect_value(t, doubled, "a\\b")

	plain := option_types_escape("a=b\\c", "=", '\\')
	defer delete(plain)
	testing.expect_value(t, plain, "a\\=b\\c")
}

@(test)
option_types_test_error_messages :: proc(t: ^testing.T) {
	testing.expect_value(t, option_types_error_message(.None), "")
	for err in Option_types_Error {
		if err == .None {
			continue
		}
		testing.expect(t, len(option_types_error_message(err)) > 0)
	}
}
