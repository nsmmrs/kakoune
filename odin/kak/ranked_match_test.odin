package kak

import "core:testing"

@(test)
ranked_match_test_word_boundaries :: proc(t: ^testing.T) {
	// Ported 1:1 from UnitTest test_ranked_match in src/ranked_match.cc.
	testing.expect_value(t, ranked_match_count_word_boundaries("run_all_tests", "rat"), 3)
	testing.expect_value(t, ranked_match_count_word_boundaries("run_all_tests", "at"), 2)
	testing.expect_value(t, ranked_match_count_word_boundaries("countWordBoundariesMatch", "wm"), 2)
	testing.expect_value(t, ranked_match_count_word_boundaries("countWordBoundariesMatch", "cobm"), 3)
	testing.expect_value(t, ranked_match_count_word_boundaries("countWordBoundariesMatch", "cWBM"), 4)
}

@(test)
ranked_match_test_preferred_order :: proc(t: ^testing.T) {
	// Ported 1:1 from UnitTest test_ranked_match in src/ranked_match.cc.
	preferred := proc(query, better, worse: string) -> bool {
		b := ranked_match_make(better, query)
		w := ranked_match_make(worse, query)
		return ranked_match_less(b, w)
	}
	testing.expect(t, preferred("so", "source", "source_data"))
	testing.expect(t, !preferred("so", "source_data", "source"))
	testing.expect(t, !preferred("so", "source", "source"))
	testing.expect(t, preferred("wo", "single/word", "multiw/ord"))
	testing.expect(t, preferred("foobar", "foo/bar/foobar", "foo/bar/baz"))
	testing.expect(t, preferred("db", "delete-buffer", "debug"))
	testing.expect(t, preferred("ct", "create_task", "constructor"))
	testing.expect(t, preferred("cla", "class", "class::attr"))
	testing.expect(t, preferred("meta", "meta/", "meta-a/"))
	testing.expect(t, preferred("find", "find(1p)", "findfs(8)"))
	testing.expect(t, preferred("fin", "find(1p)", "findfs(8)"))
	testing.expect(t, preferred("sys_find", "sys_find(1p)", "sys_findfs(8)"))
	testing.expect(t, preferred("", "init", "__init__"))
	testing.expect(t, preferred("ini", "init", "__init__"))
	testing.expect(t, preferred("", "a", "b"))
	testing.expect(t, preferred("expresins", "expresions", "expressionism's"))
	testing.expect(t, preferred("foo_b", "foo/bar/foo_bar.baz", "test/test_foo_bar.baz"))
	testing.expect(t, preferred("foo_b", "bar/bar_qux/foo_bar.baz", "foo/test_foo_bar.baz"))
	testing.expect(t, preferred("foo_bar", "bar/foo_bar.baz", "foo_bar/qux.baz"))
	testing.expect(t, preferred("fb", "foo_bar/", "foo.bar"))
	testing.expect(t, preferred("foo_bar", "test_foo_bar", "foo_test_bar"))
	testing.expect(t, preferred("rm.cc", "src/ranked_match.cc", "test/README.asciidoc"))
	testing.expect(t, preferred("luaremote", "src/script/LuaRemote.cpp", "tests/TestLuaRemote.cpp"))
	testing.expect(
		t,
		preferred(
			"lang/haystack/needle.c",
			"git.evilcorp.com/language/haystack/aaa/needle.c",
			"git.evilcorp.com/aaa/ng/wrong-haystack/needle.cpp",
		),
	)
	testing.expect(
		t,
		preferred(
			"evilcorp-lint/bar.go",
			"scripts/evilcorp-lint/foo/bar.go",
			"src/evilcorp-client/foo/bar.go",
		),
	)
}

@(test)
ranked_match_test_used_letters :: proc(t: ^testing.T) {
	// Ported 1:1 from UnitTest test_used_letters in src/ranked_match.cc.
	testing.expect_value(
		t,
		ranked_match_used_letters("abcd"),
		ranked_match_to_lower_letters(ranked_match_used_letters("abcdABCD")),
	)
}

@(test)
ranked_match_test_used_letters_bits :: proc(t: ^testing.T) {
	testing.expect_value(t, ranked_match_used_letters("a"), Ranked_Match_Used_Letters(1))
	testing.expect_value(t, ranked_match_used_letters("b"), Ranked_Match_Used_Letters(1) << 1)
	testing.expect_value(t, ranked_match_used_letters("z"), Ranked_Match_Used_Letters(1) << 25)
	testing.expect_value(t, ranked_match_used_letters("A"), Ranked_Match_Used_Letters(1) << 26)
	testing.expect_value(t, ranked_match_used_letters("Z"), Ranked_Match_Used_Letters(1) << 51)
	testing.expect_value(t, ranked_match_used_letters("_"), Ranked_Match_Used_Letters(1) << 53)
	testing.expect_value(t, ranked_match_used_letters("-"), Ranked_Match_Used_Letters(1) << 54)
	// Digits, dots, slashes and non-ASCII bytes all set the fallback bit.
	testing.expect_value(t, ranked_match_used_letters("0"), Ranked_Match_Used_Letters(1) << 63)
	testing.expect_value(t, ranked_match_used_letters("."), Ranked_Match_Used_Letters(1) << 63)
	testing.expect_value(t, ranked_match_used_letters("/"), Ranked_Match_Used_Letters(1) << 63)
	testing.expect_value(t, ranked_match_used_letters("é"), Ranked_Match_Used_Letters(1) << 63)
	testing.expect_value(t, ranked_match_used_letters(""), Ranked_Match_Used_Letters(0))
	// Case folding merges upper bits into lower bits.
	testing.expect_value(
		t,
		ranked_match_to_lower_letters(ranked_match_used_letters("ABC")),
		ranked_match_used_letters("abc"),
	)
	testing.expect(t, ranked_match_matches(ranked_match_used_letters("ab"), ranked_match_used_letters("abc")))
	testing.expect(
		t,
		!ranked_match_matches(ranked_match_used_letters("abd"), ranked_match_used_letters("abc")),
	)
}

@(test)
ranked_match_test_match_basics :: proc(t: ^testing.T) {
	// Empty query matches everything, with no flags.
	m := ranked_match_make("anything", "")
	testing.expect(t, m.matches)
	testing.expect_value(t, ranked_match_flags_value(m.flags), 0)
	testing.expect_value(t, m.max_index, 0)
	// Empty candidate matches empty query.
	testing.expect(t, ranked_match_make("", "").matches)
	// Non-empty query never matches an empty candidate.
	testing.expect(t, !ranked_match_make("", "a").matches)
	// Query longer (in bytes) than the candidate cannot match.
	testing.expect(t, !ranked_match_make("ab", "abc").matches)
	// Missing characters do not match.
	testing.expect(t, !ranked_match_make("abc", "z").matches)
	testing.expect(t, !ranked_match_make("abc", "abcd").matches)
	testing.expect(t, ranked_match_make("abc", "abc").matches)
	// Subsequence order matters.
	testing.expect(t, ranked_match_make("abc", "ac").matches)
	testing.expect(t, !ranked_match_make("abc", "ca").matches)
}

@(test)
ranked_match_test_smartcase :: proc(t: ^testing.T) {
	// Lowercase query matches any case.
	testing.expect(t, ranked_match_make("Foo_Bar", "fb").matches)
	testing.expect(t, ranked_match_make("Foo_Bar", "foo_bar").matches)
	// Uppercase query requires exact case.
	testing.expect(t, ranked_match_make("FooBar", "FB").matches)
	testing.expect(t, ranked_match_make("FooBar", "fb").matches)
	testing.expect(t, !ranked_match_make("foobar", "FB").matches)
	testing.expect(t, !ranked_match_make("foo_bar", "B").matches)
	testing.expect(t, ranked_match_make("foo_bar", "b").matches)
}

@(test)
ranked_match_test_flags :: proc(t: ^testing.T) {
	// Exact match sets the full ladder except OnlyWordBoundary (the
	// boundary count is 1 here, not len("foo")).
	full := ranked_match_make("foo", "foo")
	testing.expect(t, full.matches)
	for flag in Ranked_Match_Flag {
		testing.expect(t, (flag in full.flags) == (flag != .Only_Word_Boundary))
	}
	// Case-insensitive full match: smart but not exact.
	smart := ranked_match_make("Foo", "foo")
	testing.expect(t, .Smart_Full_Match in smart.flags)
	testing.expect(t, .Full_Match not_in smart.flags)
	testing.expect(t, .Prefix in smart.flags)
	testing.expect(t, .Contiguous in smart.flags)
	// Prefix query.
	prefix := ranked_match_make("foobar", "foo")
	testing.expect(t, .Prefix in prefix.flags)
	testing.expect(t, .Contiguous in prefix.flags)
	testing.expect(t, .Smart_Full_Match not_in prefix.flags)
	// Non-prefix contiguous query.
	cont := ranked_match_make("foobar", "oba")
	testing.expect(t, cont.matches)
	testing.expect(t, .Contiguous in cont.flags)
	testing.expect(t, .Prefix not_in cont.flags)
	// Pure subsequence: neither contiguous nor prefix.
	sub := ranked_match_make("foobar", "fbr")
	testing.expect(t, sub.matches)
	testing.expect(t, .Contiguous not_in sub.flags)
	testing.expect(t, .Prefix not_in sub.flags)
	// Word-boundary-only match.
	wb := ranked_match_make("run_all_tests", "rat")
	testing.expect(t, wb.matches)
	testing.expect_value(t, wb.word_boundary_match_count, 3)
	testing.expect(t, .Only_Word_Boundary in wb.flags)
	// Basename match on a path.
	base := ranked_match_make("foo/bar/foobar", "foobar")
	testing.expect(t, .Base_Name in base.flags)
	testing.expect(t, .Prefix in base.flags)
	// Query spanning directories is not a basename match.
	spanning := ranked_match_make("foo/bar", "o/b")
	testing.expect(t, spanning.matches)
	testing.expect(t, .Base_Name not_in spanning.flags)
}

@(test)
ranked_match_test_max_index :: proc(t: ^testing.T) {
	// max_index is the 0-based codepoint index of the last matched char.
	testing.expect_value(t, ranked_match_make("abc", "abc").max_index, 2)
	testing.expect_value(t, ranked_match_make("abc", "ac").max_index, 2)
	testing.expect_value(t, ranked_match_make("abc", "a").max_index, 0)
	testing.expect_value(t, ranked_match_make("aXbYc", "abc").max_index, 4)
	// Multibyte chars count as one index step.
	testing.expect_value(t, ranked_match_make("aéc", "ac").max_index, 2)
}

@(test)
ranked_match_test_full_word_match :: proc(t: ^testing.T) {
	testing.expect_value(t, ranked_match_count_full_word_match("foo bar", "bar"), 1)
	testing.expect_value(t, ranked_match_count_full_word_match("foo bar", "baz"), 0)
	// '_' splits words here (empty extra word chars, as in the C++).
	testing.expect_value(t, ranked_match_count_full_word_match("foo_bar", "bar"), 1)
	testing.expect_value(t, ranked_match_count_full_word_match("foo_bar baz", "foo baz"), 2)
	// Words longer than 100 bytes are skipped.
	long_word := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	testing.expect(t, len(long_word) == 101)
	testing.expect_value(t, ranked_match_count_full_word_match(long_word, long_word), 0)
	exact_word := long_word[:100]
	testing.expect_value(t, ranked_match_count_full_word_match(exact_word, exact_word), 1)
}

@(test)
ranked_match_test_word_splitter_edges :: proc(t: ^testing.T) {
	word, next, found := ranked_match_next_word("", 0)
	testing.expect(t, !found)
	testing.expect_value(t, next, 0)
	testing.expect_value(t, word, "")
	_, _, found = ranked_match_next_word("...///", 0)
	testing.expect(t, !found)
	word, next, found = ranked_match_next_word("..foo..", 0)
	testing.expect(t, found)
	testing.expect_value(t, word, "foo")
	testing.expect_value(t, next, 5)
	_, _, found = ranked_match_next_word("..foo..", next)
	testing.expect(t, !found)
	// Splits on '_' and '-'.
	word, next, found = ranked_match_next_word("foo_bar-baz", 0)
	testing.expect(t, found)
	testing.expect_value(t, word, "foo")
	word, next, found = ranked_match_next_word("foo_bar-baz", next)
	testing.expect(t, found)
	testing.expect_value(t, word, "bar")
	word, next, found = ranked_match_next_word("foo_bar-baz", next)
	testing.expect(t, found)
	testing.expect_value(t, word, "baz")
	_, _, found = ranked_match_next_word("foo_bar-baz", next)
	testing.expect(t, !found)
}

@(test)
ranked_match_test_basename_start :: proc(t: ^testing.T) {
	testing.expect_value(t, ranked_match_basename_start(""), 0)
	testing.expect_value(t, ranked_match_basename_start("a"), 0)
	testing.expect_value(t, ranked_match_basename_start("/"), 0)
	testing.expect_value(t, ranked_match_basename_start("foo"), 0)
	testing.expect_value(t, ranked_match_basename_start("meta/"), 0)
	testing.expect_value(t, ranked_match_basename_start("a/b"), 2)
	testing.expect_value(t, ranked_match_basename_start("foo/bar/"), 4)
	testing.expect_value(t, ranked_match_basename_start("foo/bar/baz"), 8)
	testing.expect_value(t, ranked_match_basename_start("/foo"), 1)
}

@(test)
ranked_match_test_sequence_number_tiebreak :: proc(t: ^testing.T) {
	a := ranked_match_make("dup", "dup")
	b := ranked_match_make("dup", "dup")
	ranked_match_set_input_sequence_number(&a, 1)
	ranked_match_set_input_sequence_number(&b, 2)
	testing.expect(t, ranked_match_less(a, b))
	testing.expect(t, !ranked_match_less(b, a))
	testing.expect(t, !ranked_match_less(a, a))
}

@(test)
ranked_match_test_letters_prefilter_agrees :: proc(t: ^testing.T) {
	// The UsedLetters prefilter must never reject a real match nor accept
	// a non-match differently than the unfiltered constructor.
	corpus := [][2]string{
		{"source", "so"},
		{"source_data", "so"},
		{"single/word", "wo"},
		{"multiw/ord", "wo"},
		{"foo/bar/foobar", "foobar"},
		{"foo/bar/baz", "foobar"},
		{"delete-buffer", "db"},
		{"debug", "db"},
		{"src/ranked_match.cc", "rm.cc"},
		{"test/README.asciidoc", "rm.cc"},
		{"src/script/LuaRemote.cpp", "luaremote"},
		{"foobar", "FB"},
		{"FooBar", "FB"},
		{"abc", "z"},
		{"ab", "abc"},
		{"", ""},
		{"", "a"},
		{"meta/", "meta"},
		{"foo_bar/", "fb"},
	}
	for pair in corpus {
		candidate, query := pair[0], pair[1]
		plain := ranked_match_make(candidate, query)
		filtered := ranked_match_make_with_letters(
			candidate,
			ranked_match_used_letters(candidate),
			query,
			ranked_match_used_letters(query),
		)
		testing.expect_value(t, filtered.matches, plain.matches)
		if plain.matches {
			testing.expect_value(t, filtered, plain)
		}
	}
}

@(test)
ranked_match_test_unicode_edges :: proc(t: ^testing.T) {
	// Exact multibyte match still reaches FullMatch via byte equality.
	testing.expect(t, .Full_Match in ranked_match_make("héllo", "héllo").flags)
	testing.expect(t, ranked_match_make("héllo", "hllo").matches)
	// The OnlyWordBoundary quirk: the codepoint count is compared against
	// the byte length, so a multibyte query never sets it.
	m := ranked_match_make("é", "é")
	testing.expect(t, m.matches)
	testing.expect_value(t, m.word_boundary_match_count, 1)
	testing.expect(t, .Only_Word_Boundary not_in m.flags)
	// Smartcase subsequence matches across case, but the byte-wise
	// contiguous search cannot match É (0xC3 0x89) with é (0xC3 0xA9).
	accent := ranked_match_make("École", "é")
	testing.expect(t, accent.matches)
	testing.expect(t, .Contiguous not_in accent.flags)
	testing.expect(t, .Base_Name in accent.flags)
}
