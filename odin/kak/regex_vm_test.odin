package kak

import "core:testing"

// Test helpers for the regex_vm module.

@(private = "file")
regex_vm_test_compile :: proc(
	t: ^testing.T,
	pattern: string,
	flags: Regex_Vm_Compile_Flags = {},
	loc := #caller_location,
) -> Regex_Vm_Compiled {
	prog, msg, err := regex_vm_compile(pattern, flags)
	if err != .None {
		testing.expect(t, false, msg, loc = loc)
		delete(msg)
		fallback, _, _ := regex_vm_compile("", flags)
		return fallback
	}
	return prog
}

@(private = "file")
regex_vm_test_exec :: proc(
	vm: ^Regex_Vm,
	subject: string,
	flags: Regex_Vm_Exec_Flags = {},
) -> bool {
	return regex_vm_exec(vm, subject, 0, len(subject), 0, len(subject), flags)
}

@(private = "file")
regex_vm_test_group :: proc(vm: ^Regex_Vm, subject: string, group: int) -> string {
	caps := regex_vm_captures(vm)
	if group < 0 || group * 2 + 1 >= len(caps) || caps[group * 2] < 0 {
		return ""
	}
	return subject[caps[group * 2]:caps[group * 2 + 1]]
}

@(test)
regex_vm_test_basic :: proc(t: ^testing.T) {
	// Ported 1:1 from UnitTest test_regex in src/regex_vm.cc.
	{
		prog := regex_vm_test_compile(t, `a*b`)
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Forward})
		defer regex_vm_destroy(&vm)
		testing.expect(t, regex_vm_test_exec(&vm, "b"))
		testing.expect(t, regex_vm_test_exec(&vm, "ab"))
		testing.expect(t, regex_vm_test_exec(&vm, "aaab"))
		testing.expect(t, !regex_vm_test_exec(&vm, "acb"))
		testing.expect(t, !regex_vm_test_exec(&vm, "abc"))
		testing.expect(t, !regex_vm_test_exec(&vm, ""))
	}
	{
		prog := regex_vm_test_compile(t, `^a.*b$`)
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Forward})
		defer regex_vm_destroy(&vm)
		testing.expect(t, regex_vm_test_exec(&vm, "afoob"))
		testing.expect(t, regex_vm_test_exec(&vm, "ab"))
		testing.expect(t, !regex_vm_test_exec(&vm, "bab"))
		testing.expect(t, !regex_vm_test_exec(&vm, ""))
	}
	{
		prog := regex_vm_test_compile(t, `^(foo|qux|baz)+(bar)?baz$`)
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Forward})
		defer regex_vm_destroy(&vm)
		testing.expect(t, regex_vm_test_exec(&vm, "fooquxbarbaz"))
		testing.expect_value(t, regex_vm_test_group(&vm, "fooquxbarbaz", 1), "qux")
		testing.expect(t, !regex_vm_test_exec(&vm, "fooquxbarbaze"))
		testing.expect(t, !regex_vm_test_exec(&vm, "quxbar"))
		testing.expect(t, !regex_vm_test_exec(&vm, "blahblah"))
		testing.expect(t, regex_vm_test_exec(&vm, "bazbaz"))
		testing.expect(t, regex_vm_test_exec(&vm, "quxbaz"))
	}
	{
		prog := regex_vm_test_compile(t, `.*\b(foo|bar)\b.*`)
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Forward})
		defer regex_vm_destroy(&vm)
		testing.expect(t, regex_vm_test_exec(&vm, "qux foo baz"))
		testing.expect_value(t, regex_vm_test_group(&vm, "qux foo baz", 1), "foo")
		testing.expect(t, !regex_vm_test_exec(&vm, "quxfoobaz"))
		testing.expect(t, regex_vm_test_exec(&vm, "bar"))
		testing.expect(t, !regex_vm_test_exec(&vm, "foobar"))
	}
	{
		prog := regex_vm_test_compile(t, `(foo|bar)`)
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Forward})
		defer regex_vm_destroy(&vm)
		testing.expect(t, regex_vm_test_exec(&vm, "foo"))
		testing.expect(t, regex_vm_test_exec(&vm, "bar"))
		testing.expect(t, !regex_vm_test_exec(&vm, "foobar"))
	}
	{
		prog := regex_vm_test_compile(t, `[aA]`)
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Forward})
		defer regex_vm_destroy(&vm)
		testing.expect(t, regex_vm_test_exec(&vm, "a"))
		testing.expect(t, regex_vm_test_exec(&vm, "A"))
	}
}

@(test)
regex_vm_test_quantifiers :: proc(t: ^testing.T) {
	// Ported 1:1 from UnitTest test_regex in src/regex_vm.cc.
	{
		prog := regex_vm_test_compile(t, `a{3,5}b`)
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Forward})
		defer regex_vm_destroy(&vm)
		testing.expect(t, !regex_vm_test_exec(&vm, "aab"))
		testing.expect(t, regex_vm_test_exec(&vm, "aaab"))
		testing.expect(t, !regex_vm_test_exec(&vm, "aaaaaab"))
		testing.expect(t, regex_vm_test_exec(&vm, "aaaaab"))
	}
	{
		prog := regex_vm_test_compile(t, `a{3}b`)
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Forward})
		defer regex_vm_destroy(&vm)
		testing.expect(t, !regex_vm_test_exec(&vm, "aab"))
		testing.expect(t, regex_vm_test_exec(&vm, "aaab"))
		testing.expect(t, !regex_vm_test_exec(&vm, "aaaab"))
	}
	{
		prog := regex_vm_test_compile(t, `a{3,}b`)
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Forward})
		defer regex_vm_destroy(&vm)
		testing.expect(t, !regex_vm_test_exec(&vm, "aab"))
		testing.expect(t, regex_vm_test_exec(&vm, "aaab"))
		testing.expect(t, regex_vm_test_exec(&vm, "aaaaab"))
	}
	{
		prog := regex_vm_test_compile(t, `a{,3}b`)
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Forward})
		defer regex_vm_destroy(&vm)
		testing.expect(t, regex_vm_test_exec(&vm, "b"))
		testing.expect(t, regex_vm_test_exec(&vm, "ab"))
		testing.expect(t, regex_vm_test_exec(&vm, "aaab"))
		testing.expect(t, !regex_vm_test_exec(&vm, "aaaab"))
	}
	{
		prog := regex_vm_test_compile(t, `(a{3,5})a+`)
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Forward})
		defer regex_vm_destroy(&vm)
		testing.expect(t, regex_vm_test_exec(&vm, "aaaaaa"))
		testing.expect_value(t, regex_vm_test_group(&vm, "aaaaaa", 1), "aaaaa")
	}
	{
		prog := regex_vm_test_compile(t, `(a{3,5}?)a+`)
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Forward})
		defer regex_vm_destroy(&vm)
		testing.expect(t, regex_vm_test_exec(&vm, "aaaaaa"))
		testing.expect_value(t, regex_vm_test_group(&vm, "aaaaaa", 1), "aaa")
	}
	{
		prog := regex_vm_test_compile(t, `(a{3,5}?)a`)
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Forward})
		defer regex_vm_destroy(&vm)
		testing.expect(t, regex_vm_test_exec(&vm, "aaaa"))
	}
	{
		prog := regex_vm_test_compile(t, `(fo+?).*`)
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Forward})
		defer regex_vm_destroy(&vm)
		testing.expect(t, regex_vm_test_exec(&vm, "foooo"))
		testing.expect_value(t, regex_vm_test_group(&vm, "foooo", 1), "fo")
	}
	{
		prog := regex_vm_test_compile(t, `(()*)`)
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Forward})
		defer regex_vm_destroy(&vm)
		testing.expect(t, !regex_vm_test_exec(&vm, " "))
	}
}

@(test)
regex_vm_test_search :: proc(t: ^testing.T) {
	// Ported 1:1 from UnitTest test_regex in src/regex_vm.cc.
	{
		prog := regex_vm_test_compile(t, `f.*a(.*o)`)
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Forward, .Search})
		defer regex_vm_destroy(&vm)
		testing.expect(t, regex_vm_test_exec(&vm, "blahfoobarfoobaz"))
		testing.expect_value(t, regex_vm_test_group(&vm, "blahfoobarfoobaz", 0), "foobarfoo")
		testing.expect_value(t, regex_vm_test_group(&vm, "blahfoobarfoobaz", 1), "rfoo")
		testing.expect(t, regex_vm_test_exec(&vm, "mais que fais la police"))
		testing.expect_value(t, regex_vm_test_group(&vm, "mais que fais la police", 0), "fais la po")
		testing.expect_value(t, regex_vm_test_group(&vm, "mais que fais la police", 1), " po")
	}
	{
		prog := regex_vm_test_compile(t, `foo\Kbar`)
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Forward})
		defer regex_vm_destroy(&vm)
		testing.expect(t, regex_vm_test_exec(&vm, "foobar"))
		testing.expect_value(t, regex_vm_test_group(&vm, "foobar", 0), "bar")
		testing.expect(t, !regex_vm_test_exec(&vm, "bar"))
	}
	{
		prog := regex_vm_test_compile(t, `foobaz|foo|foobar`)
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Forward, .Search})
		defer regex_vm_destroy(&vm)
		testing.expect(t, regex_vm_test_exec(&vm, "foobar"))
		testing.expect_value(t, regex_vm_test_group(&vm, "foobar", 0), "foo")
	}
	{
		prog := regex_vm_test_compile(t, `\b(?<!-)(a|b|)(?!-)\b`)
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Forward, .Search})
		defer regex_vm_destroy(&vm)
		subject := "# foo bar"
		testing.expect(t, regex_vm_test_exec(&vm, subject))
		caps := regex_vm_captures(&vm)
		testing.expect_value(t, subject[caps[0]], '#')
	}
	{
		prog := regex_vm_test_compile(t, `(?<!\\)(?:\\\\)*"`)
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Forward, .Search})
		defer regex_vm_destroy(&vm)
		testing.expect(t, regex_vm_test_exec(&vm, `foo"`))
	}
	{
		prog := regex_vm_test_compile(t, `$`)
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Forward, .Search})
		defer regex_vm_destroy(&vm)
		subject := "foo\n"
		testing.expect(t, regex_vm_test_exec(&vm, subject))
		caps := regex_vm_captures(&vm)
		testing.expect_value(t, subject[caps[0]], '\n')
	}
	{
		prog := regex_vm_test_compile(t, `д`)
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Forward, .Search})
		defer regex_vm_destroy(&vm)
		testing.expect(t, regex_vm_test_exec(&vm, "д"))
	}
	{
		prog := regex_vm_test_compile(t, "ab")
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Forward, .Search})
		defer regex_vm_destroy(&vm)
		subject := "fa😄ab"
		testing.expect(
			t,
			!regex_vm_exec(&vm, subject, 0, 4, 0, len(subject), {}),
		)
	}
	{
		prog := regex_vm_test_compile(t, ".{40}")
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Forward, .Search})
		defer regex_vm_destroy(&vm)
		testing.expect(t, regex_vm_test_exec(&vm, "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"))
	}
	{
		prog := regex_vm_test_compile(t, `(?i)FOO`)
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Forward, .Search})
		defer regex_vm_destroy(&vm)
		testing.expect(t, regex_vm_test_exec(&vm, "foo"))
	}
	{
		prog := regex_vm_test_compile(t, `.?(?=foo)`)
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Forward, .Search})
		defer regex_vm_destroy(&vm)
		subject := "afoo"
		testing.expect(t, regex_vm_test_exec(&vm, subject))
		caps := regex_vm_captures(&vm)
		testing.expect_value(t, subject[caps[0]], 'a')
	}
	{
		prog := regex_vm_test_compile(t, `(?i)(?=Foo)`)
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Forward, .Search})
		defer regex_vm_destroy(&vm)
		subject := "fOO"
		testing.expect(t, regex_vm_test_exec(&vm, subject))
		caps := regex_vm_captures(&vm)
		testing.expect_value(t, subject[caps[0]], 'f')
	}
}

@(test)
regex_vm_test_classes :: proc(t: ^testing.T) {
	// Ported 1:1 from UnitTest test_regex in src/regex_vm.cc.
	{
		prog := regex_vm_test_compile(t, `[àb-dX-Z-]{3,5}`)
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Forward})
		defer regex_vm_destroy(&vm)
		testing.expect(t, regex_vm_test_exec(&vm, "cà-Y"))
		testing.expect(t, !regex_vm_test_exec(&vm, "àeY"))
		testing.expect(t, regex_vm_test_exec(&vm, "dcbàX"))
		testing.expect(t, !regex_vm_test_exec(&vm, "efg"))
	}
	{
		prog := regex_vm_test_compile(t, `\d{3}`)
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Forward})
		defer regex_vm_destroy(&vm)
		testing.expect(t, regex_vm_test_exec(&vm, "123"))
		testing.expect(t, !regex_vm_test_exec(&vm, "1x3"))
	}
	{
		prog := regex_vm_test_compile(t, `[-\d]+`)
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Forward})
		defer regex_vm_destroy(&vm)
		testing.expect(t, regex_vm_test_exec(&vm, "123-456"))
		testing.expect(t, !regex_vm_test_exec(&vm, "123_456"))
	}
	{
		prog := regex_vm_test_compile(t, `[ \H]+`)
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Forward})
		defer regex_vm_destroy(&vm)
		testing.expect(t, regex_vm_test_exec(&vm, "abc "))
		testing.expect(t, !regex_vm_test_exec(&vm, "a \t"))
	}
	{
		prog := regex_vm_test_compile(t, `[^\]]+`)
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Forward})
		defer regex_vm_destroy(&vm)
		testing.expect(t, !regex_vm_test_exec(&vm, "a]c"))
		testing.expect(t, regex_vm_test_exec(&vm, "abc"))
	}
	{
		prog := regex_vm_test_compile(t, `[^:\n]+`)
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Forward})
		defer regex_vm_destroy(&vm)
		testing.expect(t, !regex_vm_test_exec(&vm, "\nbc"))
		testing.expect(t, regex_vm_test_exec(&vm, "abc"))
	}
	{
		prog := regex_vm_test_compile(t, `(?:foo)+`)
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Forward})
		defer regex_vm_destroy(&vm)
		testing.expect(t, regex_vm_test_exec(&vm, "foofoofoo"))
		testing.expect(t, !regex_vm_test_exec(&vm, "barbarbar"))
	}
	{
		prog := regex_vm_test_compile(t, `[d-ea-dcf-k]+`)
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Forward})
		defer regex_vm_destroy(&vm)
		testing.expect(t, regex_vm_test_exec(&vm, "abcde"))
	}
	{
		prog := regex_vm_test_compile(t, `(?i)[a-c]+`)
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Forward})
		defer regex_vm_destroy(&vm)
		testing.expect(t, regex_vm_test_exec(&vm, "bCa"))
	}
	{
		prog := regex_vm_test_compile(t, `[\t-\r]+`)
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Forward})
		defer regex_vm_destroy(&vm)
		testing.expect(t, regex_vm_test_exec(&vm, "\t\n\v\f\r"))
	}
	{
		prog := regex_vm_test_compile(t, `[\t-\r]\h+[\t-\r]`)
		defer regex_vm_compiled_destroy(&prog)
		testing.expect_value(t, len(prog.char_classes), 1)
		vm := regex_vm_make(&prog, {.Forward})
		defer regex_vm_destroy(&vm)
		testing.expect(t, regex_vm_test_exec(&vm, "\n  \f"))
	}
	{
		prog := regex_vm_test_compile(t, `[^\x00-\x7F]+`)
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Forward})
		defer regex_vm_destroy(&vm)
		testing.expect(t, !regex_vm_test_exec(&vm, "ascii"))
		testing.expect(t, regex_vm_test_exec(&vm, "←↑→↓"))
		testing.expect(t, regex_vm_test_exec(&vm, "😄😊😉"))
	}
	{
		prog := regex_vm_test_compile(t, `[^\u000000-\u00ffff]+`)
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Forward})
		defer regex_vm_destroy(&vm)
		testing.expect(t, !regex_vm_test_exec(&vm, "ascii"))
		testing.expect(t, !regex_vm_test_exec(&vm, "←↑→↓"))
		testing.expect(t, regex_vm_test_exec(&vm, "😄😊😉"))
	}
	{
		prog := regex_vm_test_compile(t, `(?i)[a-z]+`)
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Forward})
		defer regex_vm_destroy(&vm)
		testing.expect(t, regex_vm_test_exec(&vm, "ABC"))
	}
	{
		prog := regex_vm_test_compile(t, `Foo(?i)f[oB]+`)
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Forward})
		defer regex_vm_destroy(&vm)
		testing.expect(t, regex_vm_test_exec(&vm, "FooFOoBb"))
	}
}

@(test)
regex_vm_test_escapes :: proc(t: ^testing.T) {
	// Ported 1:1 from UnitTest test_regex in src/regex_vm.cc.
	{
		prog := regex_vm_test_compile(t, `\Q{}[]*+?\Ea+`)
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Forward})
		defer regex_vm_destroy(&vm)
		testing.expect(t, regex_vm_test_exec(&vm, "{}[]*+?aa"))
	}
	{
		prog := regex_vm_test_compile(t, `\Q...`)
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Forward})
		defer regex_vm_destroy(&vm)
		testing.expect(t, regex_vm_test_exec(&vm, "..."))
		testing.expect(t, !regex_vm_test_exec(&vm, "bla"))
	}
	{
		prog := regex_vm_test_compile(t, `\0\x0A\u00260e\u00260F`)
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Forward})
		defer regex_vm_destroy(&vm)
		subject_bytes := [?]byte{0, '\n', 0xE2, 0x98, 0x8E, 0xE2, 0x98, 0x8F}
		testing.expect(t, regex_vm_test_exec(&vm, string(subject_bytes[:])))
	}
	{
		prog := regex_vm_test_compile(t, `a(?<=\N)\N+(?=.\N)\s(?S)d.+(?!.)\s(?<!\N)g`)
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Forward})
		defer regex_vm_destroy(&vm)
		testing.expect(t, regex_vm_test_exec(&vm, "abc\ndef\ng"))
		testing.expect(t, !regex_vm_test_exec(&vm, "abc\ndef g"))
	}
}

@(test)
regex_vm_test_lookaround :: proc(t: ^testing.T) {
	// Ported 1:1 from UnitTest test_regex in src/regex_vm.cc.
	{
		prog := regex_vm_test_compile(t, `(?=fo[\w]).`)
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Forward, .Search})
		defer regex_vm_destroy(&vm)
		testing.expect(t, regex_vm_test_exec(&vm, "barfoo"))
		testing.expect_value(t, regex_vm_test_group(&vm, "barfoo", 0), "f")
	}
	{
		prog := regex_vm_test_compile(t, `(?<!f).`)
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Forward})
		defer regex_vm_destroy(&vm)
		testing.expect(t, regex_vm_test_exec(&vm, "f"))
	}
	{
		prog := regex_vm_test_compile(t, `(?!f[oa]o)...`)
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Forward})
		defer regex_vm_destroy(&vm)
		testing.expect(t, !regex_vm_test_exec(&vm, "foo"))
		testing.expect(t, regex_vm_test_exec(&vm, "qux"))
	}
	{
		prog := regex_vm_test_compile(t, `...(?<=f\w.)`)
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Forward})
		defer regex_vm_destroy(&vm)
		testing.expect(t, regex_vm_test_exec(&vm, "foo"))
		testing.expect(t, !regex_vm_test_exec(&vm, "qux"))
	}
	{
		prog := regex_vm_test_compile(t, `...(?<!foo)`)
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Forward})
		defer regex_vm_destroy(&vm)
		testing.expect(t, !regex_vm_test_exec(&vm, "foo"))
		testing.expect(t, regex_vm_test_exec(&vm, "qux"))
	}
	{
		prog := regex_vm_test_compile(t, `(?=)`)
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Forward})
		defer regex_vm_destroy(&vm)
		testing.expect(t, regex_vm_test_exec(&vm, ""))
	}
}

@(test)
regex_vm_test_backward :: proc(t: ^testing.T) {
	// Ported 1:1 from UnitTest test_regex in src/regex_vm.cc.
	{
		prog := regex_vm_test_compile(t, `fo{1,}`, {.Backward})
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Backward, .Search})
		defer regex_vm_destroy(&vm)
		subject := "foo1fooo2"
		testing.expect(t, regex_vm_test_exec(&vm, subject))
		caps := regex_vm_captures(&vm)
		testing.expect_value(t, subject[caps[1]], '2')
	}
	{
		prog := regex_vm_test_compile(t, `(?<=f)oo(b[ae]r)?(?=baz)`, {.Backward})
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Backward, .Search})
		defer regex_vm_destroy(&vm)
		subject := "foobarbazfoobazfooberbaz"
		testing.expect(t, regex_vm_test_exec(&vm, subject))
		testing.expect_value(t, regex_vm_test_group(&vm, subject, 0), "oober")
		testing.expect_value(t, regex_vm_test_group(&vm, subject, 1), "ber")
	}
	{
		prog := regex_vm_test_compile(t, `(baz|boz|foo|qux)(?<!baz)(?<!o)`, {.Backward})
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Backward, .Search})
		defer regex_vm_destroy(&vm)
		subject := "quxbozfoobaz"
		testing.expect(t, regex_vm_test_exec(&vm, subject))
		testing.expect_value(t, regex_vm_test_group(&vm, subject, 0), "boz")
	}
	{
		prog := regex_vm_test_compile(t, `foo`, {.Backward})
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Backward, .Search})
		defer regex_vm_destroy(&vm)
		subject := "foofoo"
		testing.expect(t, regex_vm_test_exec(&vm, subject))
		caps := regex_vm_captures(&vm)
		testing.expect_value(t, caps[1], len(subject))
	}
	{
		prog := regex_vm_test_compile(t, `$`, {.Backward})
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Backward, .Search})
		defer regex_vm_destroy(&vm)
		subject := "foo\nbar\nbaz\nqux"
		testing.expect(t, regex_vm_test_exec(&vm, subject, {.Not_End_Of_Line}))
		caps := regex_vm_captures(&vm)
		testing.expect_value(t, subject[caps[0]:], "\nqux")
		testing.expect(t, regex_vm_test_exec(&vm, subject))
		caps = regex_vm_captures(&vm)
		testing.expect_value(t, subject[caps[0]:], "")
	}
	{
		prog := regex_vm_test_compile(t, `^`, {.Backward})
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Backward, .Search})
		defer regex_vm_destroy(&vm)
		testing.expect(t, !regex_vm_test_exec(&vm, "foo", {.Not_Begin_Of_Line}))
		testing.expect(t, regex_vm_test_exec(&vm, "foo"))
		subject := "foo\nbar"
		testing.expect(t, regex_vm_test_exec(&vm, subject))
		caps := regex_vm_captures(&vm)
		testing.expect_value(t, subject[caps[0]:], "bar")
	}
	{
		prog := regex_vm_test_compile(t, `\A\w+`, {.Backward})
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Backward, .Search})
		defer regex_vm_destroy(&vm)
		subject := "foo\nbar\nbaz"
		testing.expect(t, regex_vm_test_exec(&vm, subject))
		testing.expect_value(t, regex_vm_test_group(&vm, subject, 0), "foo")
	}
	{
		prog := regex_vm_test_compile(t, `\b\w+\z`, {.Backward})
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Backward, .Search})
		defer regex_vm_destroy(&vm)
		subject := "foo\nbar\nbaz"
		testing.expect(t, regex_vm_test_exec(&vm, subject))
		testing.expect_value(t, regex_vm_test_group(&vm, subject, 0), "baz")
	}
	{
		prog := regex_vm_test_compile(t, "a[^\n]*\n|\n", {.Backward})
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Backward, .Search})
		defer regex_vm_destroy(&vm)
		subject := "foo\nbar\nb"
		testing.expect(t, regex_vm_test_exec(&vm, subject))
		testing.expect_value(t, regex_vm_test_group(&vm, subject, 0), "ar\n")
	}
}

@(test)
regex_vm_test_start_desc :: proc(t: ^testing.T) {
	// Ported 1:1 from UnitTest test_regex in src/regex_vm.cc.
	{
		prog := regex_vm_test_compile(t, "(.{3,4}|f)oo")
		defer regex_vm_compiled_destroy(&prog)
		testing.expect(t, prog.has_forward_start)
		testing.expect_value(t, prog.forward_start.offset, 4)
		for c in 0 ..< 256 {
			testing.expect_value(
				t,
				prog.forward_start.bytes[c],
				c == 'f' || c == 'o',
			)
		}
		vm := regex_vm_make(&prog, {.Forward, .Search})
		defer regex_vm_destroy(&vm)
		testing.expect(t, regex_vm_test_exec(&vm, "xxxoo"))
		testing.expect(t, regex_vm_test_exec(&vm, "xfoo"))
		testing.expect(t, !regex_vm_test_exec(&vm, "😄xoo"))
	}
	{
		prog := regex_vm_test_compile(t, "oo(.{3,4}|f)", {.Backward})
		defer regex_vm_compiled_destroy(&prog)
		testing.expect(t, prog.has_backward_start)
		testing.expect_value(t, prog.backward_start.offset, 4)
		for c in 0 ..< 256 {
			testing.expect_value(
				t,
				prog.backward_start.bytes[c],
				c == 'f' || c == 'o',
			)
		}
		vm := regex_vm_make(&prog, {.Backward, .Search})
		defer regex_vm_destroy(&vm)
		testing.expect(t, regex_vm_test_exec(&vm, "ooxxx"))
		testing.expect(t, regex_vm_test_exec(&vm, "oofx"))
		testing.expect(t, !regex_vm_test_exec(&vm, "oox😄"))
	}
}

@(test)
regex_vm_test_named_captures :: proc(t: ^testing.T) {
	// Ported 1:1 from UnitTest test_regex in src/regex_vm.cc.
	prog := regex_vm_test_compile(t, `(?<year>\d+)-(?<month>\d+)-(?<day>\d+)`)
	defer regex_vm_compiled_destroy(&prog)
	vm := regex_vm_make(&prog, {.Forward})
	defer regex_vm_destroy(&vm)
	subject := "2019-01-03"
	testing.expect(t, regex_vm_test_exec(&vm, subject))
	testing.expect_value(t, regex_vm_test_group(&vm, subject, 1), "2019")
	testing.expect_value(t, regex_vm_test_group(&vm, subject, 2), "01")
	testing.expect_value(t, regex_vm_test_group(&vm, subject, 3), "03")
	testing.expect_value(t, len(prog.named_captures), 3)
	testing.expect_value(t, prog.named_captures[0].name, "year")
	testing.expect_value(t, prog.named_captures[0].index, 1)
	testing.expect_value(t, prog.named_captures[1].name, "month")
	testing.expect_value(t, prog.named_captures[1].index, 2)
	testing.expect_value(t, prog.named_captures[2].name, "day")
	testing.expect_value(t, prog.named_captures[2].index, 3)
}

@(test)
regex_vm_test_parse_errors :: proc(t: ^testing.T) {
	// Ported 1:1 from UnitTest test_regex in src/regex_vm.cc.
	check := proc(t: ^testing.T, re, expected: string) {
		_, msg, err := regex_vm_compile(re, {})
		defer delete(msg)
		testing.expect_value(t, err, Regex_Vm_Error.Compile_Error)
		testing.expect_value(t, msg, expected)
	}
	check(
		t,
		"(?=a*)",
		"regex parse error: Quantifiers cannot be used in lookarounds at '(?=a*)<<<HERE>>>'",
	)
	check(
		t,
		"(?=(a))",
		"regex parse error: Lookaround can only contain literals, any chars or character classes at '(?=(a))<<<HERE>>>'",
	)
	check(
		t,
		"(?=a|b)",
		"regex parse error: Alternations cannot be used in lookarounds at '(?=a|<<<HERE>>>b)'",
	)
	// Found by differential fuzzing against the C++ implementation: the
	// bound error points at the offending digit, and an unclosed
	// lookaround at the end of input reports "Invalid utf8 in regex"
	// (the C++ dereferences the end iterator there).
	check(
		t,
		"a{1001}",
		"regex parse error: Explicit quantifier is too big, maximum is 1000 at 'a{100<<<HERE>>>1}'",
	)
	check(t, "(?=\\K", "Invalid utf8 in regex")
}

@(test)
regex_vm_test_edge_cases :: proc(t: ^testing.T) {
	// Empty pattern matches empty (and only empty in full-match mode).
	{
		prog := regex_vm_test_compile(t, "")
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Forward})
		defer regex_vm_destroy(&vm)
		testing.expect(t, regex_vm_test_exec(&vm, ""))
		testing.expect(t, !regex_vm_test_exec(&vm, "a"))
		search := regex_vm_make(&prog, {.Forward, .Search})
		defer regex_vm_destroy(&search)
		testing.expect(t, regex_vm_test_exec(&search, "abc"))
		caps := regex_vm_captures(&search)
		testing.expect_value(t, caps[0], 0)
		testing.expect_value(t, caps[1], 0)
	}
	// Nested groups capture inner and outer spans.
	{
		prog := regex_vm_test_compile(t, `((a)(b))`)
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Forward})
		defer regex_vm_destroy(&vm)
		subject := "ab"
		testing.expect(t, regex_vm_test_exec(&vm, subject))
		testing.expect_value(t, regex_vm_test_group(&vm, subject, 0), "ab")
		testing.expect_value(t, regex_vm_test_group(&vm, subject, 1), "ab")
		testing.expect_value(t, regex_vm_test_group(&vm, subject, 2), "a")
		testing.expect_value(t, regex_vm_test_group(&vm, subject, 3), "b")
	}
	// Unmatched groups report -1 saves.
	{
		prog := regex_vm_test_compile(t, `(a)|(b)`)
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Forward})
		defer regex_vm_destroy(&vm)
		testing.expect(t, regex_vm_test_exec(&vm, "b"))
		caps := regex_vm_captures(&vm)
		testing.expect_value(t, caps[2], -1)
		testing.expect_value(t, regex_vm_test_group(&vm, "b", 2), "b")
	}
	// Anchors and subject assertions.
	{
		prog := regex_vm_test_compile(t, `\Afoo\z`)
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Forward, .Search})
		defer regex_vm_destroy(&vm)
		testing.expect(t, regex_vm_test_exec(&vm, "foo"))
		testing.expect(t, !regex_vm_test_exec(&vm, "foo\n"))
		testing.expect(t, !regex_vm_test_exec(&vm, "xfoo"))
	}
	// Word boundaries, positive and negative.
	{
		prog := regex_vm_test_compile(t, `\bfoo\b`)
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Forward, .Search})
		defer regex_vm_destroy(&vm)
		testing.expect(t, regex_vm_test_exec(&vm, "a foo b"))
		testing.expect(t, !regex_vm_test_exec(&vm, "afoobar"))
		nb := regex_vm_test_compile(t, `\Bfoo\B`)
		defer regex_vm_compiled_destroy(&nb)
		nvm := regex_vm_make(&nb, {.Forward, .Search})
		defer regex_vm_destroy(&nvm)
		testing.expect(t, regex_vm_test_exec(&nvm, "afoob"))
		testing.expect(t, !regex_vm_test_exec(&nvm, "a foo b"))
	}
	// Case-insensitive matching and flags toggling.
	{
		prog := regex_vm_test_compile(t, `(?i)a(?I)a`)
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Forward})
		defer regex_vm_destroy(&vm)
		testing.expect(t, regex_vm_test_exec(&vm, "aa"))
		testing.expect(t, regex_vm_test_exec(&vm, "Aa"))
		testing.expect(t, !regex_vm_test_exec(&vm, "aA"))
		dot := regex_vm_test_compile(t, `.`)
		defer regex_vm_compiled_destroy(&dot)
		dvm := regex_vm_make(&dot, {.Forward})
		defer regex_vm_destroy(&dvm)
		testing.expect(t, regex_vm_test_exec(&dvm, "\n"))
	}
	// Dot behavior with (?s)/(?S) modifiers.
	{
		prog := regex_vm_test_compile(t, `(?S).`)
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Forward})
		defer regex_vm_destroy(&vm)
		testing.expect(t, !regex_vm_test_exec(&vm, "\n"))
		testing.expect(t, regex_vm_test_exec(&vm, "x"))
	}
	// Greedy vs lazy star over the same subject.
	{
		prog := regex_vm_test_compile(t, `(a*)(a+)`)
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Forward})
		defer regex_vm_destroy(&vm)
		subject := "aaa"
		testing.expect(t, regex_vm_test_exec(&vm, subject))
		testing.expect_value(t, regex_vm_test_group(&vm, subject, 1), "aa")
		testing.expect_value(t, regex_vm_test_group(&vm, subject, 2), "a")
		lazy := regex_vm_test_compile(t, `(a*?)(a+)`)
		defer regex_vm_compiled_destroy(&lazy)
		lvm := regex_vm_make(&lazy, {.Forward})
		defer regex_vm_destroy(&lvm)
		testing.expect(t, regex_vm_test_exec(&lvm, subject))
		testing.expect_value(t, regex_vm_test_group(&lvm, subject, 1), "")
		testing.expect_value(t, regex_vm_test_group(&lvm, subject, 2), "aaa")
	}
	// Malformed patterns report errors and free partial state.
	{
		_, msg, err := regex_vm_compile("(foo", {})
		defer delete(msg)
		testing.expect_value(t, err, Regex_Vm_Error.Compile_Error)
		testing.expect(t, len(msg) > 0)
	}
	{
		_, msg, err := regex_vm_compile("[abc", {})
		defer delete(msg)
		testing.expect_value(t, err, Regex_Vm_Error.Compile_Error)
	}
	{
		// min > max compiles in C++ (no validation), so it must here too.
		prog, msg, err := regex_vm_compile("a{2,1}b", {})
		testing.expect_value(t, err, Regex_Vm_Error.None)
		testing.expect_value(t, msg, "")
		regex_vm_compiled_destroy(&prog)
	}
	// No_Subs still captures group 0 but no subgroups.
	{
		prog := regex_vm_test_compile(t, `(a)(b)`, {.No_Subs})
		defer regex_vm_compiled_destroy(&prog)
		vm := regex_vm_make(&prog, {.Forward})
		defer regex_vm_destroy(&vm)
		subject := "ab"
		testing.expect(t, regex_vm_test_exec(&vm, subject))
		testing.expect_value(t, regex_vm_test_group(&vm, subject, 0), "ab")
		caps := regex_vm_captures(&vm)
		testing.expect_value(t, caps[2], -1)
	}
}
