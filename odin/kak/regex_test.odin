package kak

import "core:testing"

@(private = "file")
regex_test_make :: proc(
	t: ^testing.T,
	pattern: string,
	flags: Regex_Vm_Compile_Flags = {},
	loc := #caller_location,
) -> Regex {
	re, msg, err := regex_make(pattern, flags)
	if err != .None {
		testing.expect(t, false, msg, loc = loc)
		delete(msg)
		fallback, _, _ := regex_make("", flags)
		return fallback
	}
	return re
}

@(test)
regex_test_api :: proc(t: ^testing.T) {
	re := regex_test_make(t, `(a+)-(b+)`)
	defer regex_destroy(&re)
	testing.expect(t, !regex_empty(&re))
	testing.expect_value(t, regex_str(&re), `(a+)-(b+)`)
	testing.expect_value(t, regex_mark_count(&re), 2)

	empty := regex_test_make(t, "")
	defer regex_destroy(&empty)
	testing.expect(t, regex_empty(&empty))
	testing.expect_value(t, regex_mark_count(&empty), 0)

	named := regex_test_make(t, `(?<year>\d+)-(?<month>\d+)`)
	defer regex_destroy(&named)
	testing.expect_value(t, regex_named_capture_index(&named, "year"), 1)
	testing.expect_value(t, regex_named_capture_index(&named, "month"), 2)
	testing.expect_value(t, regex_named_capture_index(&named, "day"), -1)
	testing.expect_value(t, regex_mark_count(&named), 2)

	_, msg, err := regex_make("(oops", {})
	defer delete(msg)
	testing.expect_value(t, err, Regex_Error.Compile_Error)
	testing.expect(t, len(msg) > 0)
}

@(test)
regex_test_match :: proc(t: ^testing.T) {
	re := regex_test_make(t, `(foo|bar)([0-9]+)`)
	defer regex_destroy(&re)

	res, matched := regex_match("foo42", &re)
	defer regex_match_results_destroy(&res)
	testing.expect(t, matched)
	testing.expect_value(t, regex_match_results_size(&res), 3)
	testing.expect(t, !regex_match_results_empty(&res))
	testing.expect_value(t, regex_match_results_substring(&res, "foo42", 0), "foo42")
	testing.expect_value(t, regex_match_results_substring(&res, "foo42", 1), "foo")
	testing.expect_value(t, regex_match_results_substring(&res, "foo42", 2), "42")
	whole := regex_match_results_get(&res, 0)
	testing.expect(t, whole.matched)
	testing.expect_value(t, whole.begin, 0)
	testing.expect_value(t, whole.end, 5)
	// Out of range groups are unmatched.
	missing := regex_match_results_get(&res, 9)
	testing.expect(t, !missing.matched)
	testing.expect_value(t, regex_match_results_substring(&res, "foo42", 9), "")

	res2, matched2 := regex_match("foo42x", &re)
	defer regex_match_results_destroy(&res2)
	testing.expect(t, !matched2)
	testing.expect(t, regex_match_results_empty(&res2))

	testing.expect(t, regex_match_simple("bar7", &re))
	testing.expect(t, !regex_match_simple("baz7", &re))
}

@(test)
regex_test_search :: proc(t: ^testing.T) {
	re := regex_test_make(t, `[0-9]+`)
	defer regex_destroy(&re)

	res, matched := regex_search("abc123def", 0, 9, &re)
	defer regex_match_results_destroy(&res)
	testing.expect(t, matched)
	testing.expect_value(t, regex_match_results_substring(&res, "abc123def", 0), "123")

	// Search range excludes the digits.
	res2, matched2 := regex_search("abc123def", 0, 3, &re)
	defer regex_match_results_destroy(&res2)
	testing.expect(t, !matched2)

	testing.expect(t, regex_search_simple("abc123def", 0, 9, &re))
	testing.expect(t, !regex_search_simple("abcdef", 0, 6, &re))

	// Boundary flags affect assertions at the subject edges: pos 4 is a
	// genuine line start, so Not_Begin_Of_Line does not matter there, but
	// pos 0 is only a line start without the flag.
	bol := regex_test_make(t, `^bar`)
	defer regex_destroy(&bol)
	testing.expect(t, regex_search_simple("foo\nbar", 4, 7, &bol))
	testing.expect(t, regex_search_simple("foo\nbar", 4, 7, &bol, {.Not_Begin_Of_Line}))
	sol := regex_test_make(t, `^foo`)
	defer regex_destroy(&sol)
	testing.expect(t, regex_search_simple("foo\nbar", 0, 7, &sol))
	testing.expect(
		t,
		!regex_search_simple("foo\nbar", 0, 7, &sol, {.Not_Begin_Of_Line}),
	)
	flags := regex_match_flags(true, false, true, false)
	testing.expect_value(
		t,
		flags,
		Regex_Vm_Exec_Flags{.Not_End_Of_Line, .Not_End_Of_Word},
	)
}

@(test)
regex_test_backward_search :: proc(t: ^testing.T) {
	re := regex_test_make(t, `o+`, {.Backward})
	defer regex_destroy(&re)
	subject := "foo boo"
	res, matched := regex_backward_search(subject, 0, len(subject), &re)
	defer regex_match_results_destroy(&res)
	testing.expect(t, matched)
	testing.expect_value(t, regex_match_results_substring(&res, subject, 0), "oo")
	m := regex_match_results_get(&res, 0)
	testing.expect_value(t, m.begin, 5)
	testing.expect_value(t, m.end, 7)
}

@(test)
regex_test_iterator :: proc(t: ^testing.T) {
	re := regex_test_make(t, `[0-9]+`)
	defer regex_destroy(&re)
	subject := "a1b22c333"
	it := regex_iterator_make(subject, 0, len(subject), &re)
	defer regex_iterator_destroy(&it)
	count := 0
	for regex_iterator_next(&it) {
		count += 1
	}
	testing.expect_value(t, count, 3)

	it2 := regex_iterator_make(subject, 0, len(subject), &re)
	defer regex_iterator_destroy(&it2)
	testing.expect(t, regex_iterator_next(&it2))
	testing.expect_value(t, regex_match_results_substring(&it2.results, subject, 0), "1")
	testing.expect(t, regex_iterator_next(&it2))
	testing.expect_value(t, regex_match_results_substring(&it2.results, subject, 0), "22")
	testing.expect(t, regex_iterator_next(&it2))
	testing.expect_value(t, regex_match_results_substring(&it2.results, subject, 0), "333")
	testing.expect(t, !regex_iterator_next(&it2))

	// Empty matches advance without looping forever.
	empty_re := regex_test_make(t, `x*`)
	defer regex_destroy(&empty_re)
	it3 := regex_iterator_make("ab", 0, 2, &empty_re)
	defer regex_iterator_destroy(&it3)
	empty_count := 0
	for regex_iterator_next(&it3) {
		empty_count += 1
		testing.expect(t, empty_count < 10)
	}
	testing.expect_value(t, empty_count, 3)

	// Backward iteration finds matches from the end.
	back_re := regex_test_make(t, `[0-9]+`, {.Backward})
	defer regex_destroy(&back_re)
	it4 := regex_iterator_make(subject, 0, len(subject), &back_re, {}, true)
	defer regex_iterator_destroy(&it4)
	testing.expect(t, regex_iterator_next(&it4))
	testing.expect_value(t, regex_match_results_substring(&it4.results, subject, 0), "333")
	testing.expect(t, regex_iterator_next(&it4))
	testing.expect_value(t, regex_match_results_substring(&it4.results, subject, 0), "22")
	testing.expect(t, regex_iterator_next(&it4))
	testing.expect_value(t, regex_match_results_substring(&it4.results, subject, 0), "1")
	testing.expect(t, !regex_iterator_next(&it4))
}
