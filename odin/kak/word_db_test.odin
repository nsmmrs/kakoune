// Tests for word_db.odin: a 1:1 port of the C++ UnitTest in
// src/word_db.cc, plus edge cases (empty buffer, option-driven
// rebuild, cached accessor, edit churn, allocator cleanup).
package kak

import "core:mem"
import "core:slice"
import "core:testing"

// word_db_test_make_buffer builds a scratch buffer; tests free it with
// buffer_destroy (usually via defer).
word_db_test_make_buffer :: proc(lines: []string) -> ^Buffer {
	return buffer_make("test", {}, lines, .None, .Lf, .Present, File_Fs_Status{timestamp = File_Invalid_Time})
}

// word_db_test_candidate_less orders matches by candidate, mirroring
// the C++ test's cmp_words.
word_db_test_candidate_less :: proc(a, b: Ranked_Match) -> bool {
	return a.candidate < b.candidate
}

// word_db_test_candidates sorts matches by candidate and returns their
// candidate strings, mirroring the C++ sort + eq helper. The strings
// borrow db word storage; delete the container with allocator.
word_db_test_candidates :: proc(
	matches: ^[dynamic]Ranked_Match,
	allocator := context.allocator,
) -> [dynamic]string {
	slice.sort_by(matches[:], word_db_test_candidate_less)
	res := make([dynamic]string, 0, len(matches), allocator)
	for m in matches {
		append(&res, m.candidate)
	}
	return res
}

// word_db_test_expect_words asserts the sorted candidate list equals
// want, one element at a time (slices are not comparable).
word_db_test_expect_words :: proc(t: ^testing.T, got: []string, want: []string) {
	testing.expect_value(t, len(got), len(want))
	for word, i in want {
		if i < len(got) {
			testing.expect_value(t, got[i], word)
		}
	}
}

// word_db_test_install_extra_chars installs an "extra_word_chars"
// option holding chars on the buffer's option manager (buffer_make
// leaves the map empty). The caller frees it with
// word_db_test_remove_option before destroying the buffer.
word_db_test_install_extra_chars :: proc(buffer: ^Buffer, chars: []rune) -> ^Option {
	managers := &buffer.scope.data.options
	desc := new(Option_Desc, context.allocator)
	desc^ = Option_Desc{name = "extra_word_chars", docstring = "test"}
	owned := make([dynamic]rune, len(chars), context.allocator)
	copy(owned[:], chars)
	val: Option_Value = owned
	opt := option_manager_option_make(desc, managers, val, nil, context.allocator)
	delete(owned)
	managers.options["extra_word_chars"] = opt
	return opt
}

// word_db_test_remove_option drops the name option installed on the
// buffer and frees it.
word_db_test_remove_option :: proc(buffer: ^Buffer, name: string, opt: ^Option) {
	managers := &buffer.scope.data.options
	delete_key(&managers.options, name)
	desc := opt.desc
	option_manager_option_destroy(opt)
	free(desc, context.allocator)
}

// word_db_test_set_extra_chars replaces the option value through the
// store path so watchers are notified (mirrors :set-option).
word_db_test_set_extra_chars :: proc(opt: ^Option, chars: []rune) {
	owned := make([dynamic]rune, len(chars), context.allocator)
	defer delete(owned)
	copy(owned[:], chars)
	val: Option_Value = owned
	err, _ := option_manager_option_set(opt, val)
	assert(err == .None)
}

// Port of the C++ UnitTest test_word_db: initial index, erase, insert.
@(test)
word_db_test_main_flow :: proc(t: ^testing.T) {
	lines := []string{"tchou mutch\n", "tchou kanaky tchou\n", "\n", "tchaa tchaa\n", "allo\n"}
	buffer := word_db_test_make_buffer(lines)
	defer buffer_destroy(buffer)
	db := word_db_make(buffer)
	word_db_watch(&db)
	defer word_db_destroy(&db)

	res := word_db_find_matching(&db, "")
	defer delete(res)
	got := word_db_test_candidates(&res)
	defer delete(got)
	word_db_test_expect_words(t, got[:], []string{"allo", "kanaky", "mutch", "tchaa", "tchou"})
	testing.expect_value(t, word_db_get_word_occurences(&db, "tchou"), 3)
	testing.expect_value(t, word_db_get_word_occurences(&db, "allo"), 1)

	_, err := buffer_erase(buffer, Coord_Buffer{1, 6}, Coord_Buffer{4, 0})
	testing.expect_value(t, err, Buffer_Error.None)
	res2 := word_db_find_matching(&db, "")
	defer delete(res2)
	got2 := word_db_test_candidates(&res2)
	defer delete(got2)
	word_db_test_expect_words(t, got2[:], []string{"allo", "mutch", "tchou"})

	_, err = buffer_insert(buffer, Coord_Buffer{1, 0}, "re")
	testing.expect_value(t, err, Buffer_Error.None)
	res3 := word_db_find_matching(&db, "")
	defer delete(res3)
	got3 := word_db_test_candidates(&res3)
	defer delete(got3)
	word_db_test_expect_words(t, got3[:], []string{"allo", "mutch", "retchou", "tchou"})
}

// An empty buffer indexes nothing and stays consistent through edits.
@(test)
word_db_test_empty_buffer :: proc(t: ^testing.T) {
	buffer := word_db_test_make_buffer([]string{"\n"})
	defer buffer_destroy(buffer)
	db := word_db_make(buffer)
	defer word_db_destroy(&db)

	res := word_db_find_matching(&db, "")
	defer delete(res)
	testing.expect_value(t, len(res), 0)
	testing.expect_value(t, word_db_get_word_occurences(&db, "nothing"), 0)

	_, err := buffer_insert(buffer, Coord_Buffer{0, 0}, "hello\n")
	testing.expect_value(t, err, Buffer_Error.None)
	res2 := word_db_find_matching(&db, "")
	defer delete(res2)
	testing.expect_value(t, len(res2), 1)
	testing.expect_value(t, word_db_get_word_occurences(&db, "hello"), 1)

	_, err = buffer_erase(buffer, Coord_Buffer{0, 0}, Coord_Buffer{1, 0})
	testing.expect_value(t, err, Buffer_Error.None)
	res3 := word_db_find_matching(&db, "")
	defer delete(res3)
	testing.expect_value(t, len(res3), 0)
}

// Installing "extra_word_chars" before make, then changing it through
// the option store path, rebuilds the index via the watcher, while
// unrelated option changes leave it alone.
@(test)
word_db_test_extra_word_chars :: proc(t: ^testing.T) {
	buffer := word_db_test_make_buffer([]string{"foo-bar foo_bar\n"})
	defer buffer_destroy(buffer)
	opt := word_db_test_install_extra_chars(buffer, []rune{'_', '-'})
	defer word_db_test_remove_option(buffer, "extra_word_chars", opt)

	db := word_db_make(buffer)
	word_db_watch(&db)
	defer word_db_destroy(&db)
	testing.expect_value(t, len(buffer.scope.data.options.watchers), 1)

	res := word_db_find_matching(&db, "")
	defer delete(res)
	got := word_db_test_candidates(&res)
	defer delete(got)
	word_db_test_expect_words(t, got[:], []string{"foo-bar", "foo_bar"})

	// '-' stops being a word char: "foo-bar" splits in two.
	word_db_test_set_extra_chars(opt, []rune{'_'})
	res2 := word_db_find_matching(&db, "")
	defer delete(res2)
	got2 := word_db_test_candidates(&res2)
	defer delete(got2)
	word_db_test_expect_words(t, got2[:], []string{"bar", "foo", "foo_bar"})

	// No extra word chars at all: '_' splits too.
	word_db_test_set_extra_chars(opt, []rune{})
	res3 := word_db_find_matching(&db, "")
	defer delete(res3)
	got3 := word_db_test_candidates(&res3)
	defer delete(got3)
	word_db_test_expect_words(t, got3[:], []string{"bar", "foo"})

	// An unrelated option change notifies the watcher but rebuilds nothing.
	other_desc := new(Option_Desc, context.allocator)
	other_desc^ = Option_Desc{name = "filetype", docstring = "test"}
	filetype_val: Option_Value = "kak"
	other := option_manager_option_make(other_desc, &buffer.scope.data.options, filetype_val, nil)
	buffer.scope.data.options.options["filetype"] = other
	defer word_db_test_remove_option(buffer, "filetype", other)
	new_filetype: Option_Value = "go"
	set_err, _ := option_manager_option_set(other, new_filetype)
	testing.expect_value(t, set_err, Option_Manager_Error.None)
	res4 := word_db_find_matching(&db, "")
	defer delete(res4)
	got4 := word_db_test_candidates(&res4)
	defer delete(got4)
	word_db_test_expect_words(t, got4[:], []string{"bar", "foo"})
	testing.expect_value(t, len(buffer.scope.data.options.watchers), 1)
}

// word_db_get caches one database per buffer; word_db_release drops it.
@(test)
word_db_test_cached_get :: proc(t: ^testing.T) {
	buffer := word_db_test_make_buffer([]string{"alpha beta\n"})
	defer buffer_destroy(buffer)

	first := word_db_get(buffer)
	second := word_db_get(buffer)
	testing.expect(t, first == second)

	res := word_db_find_matching(first, "alp")
	defer delete(res)
	testing.expect_value(t, len(res), 1)
	testing.expect_value(t, res[0].candidate, "alpha")
	testing.expect_value(t, word_db_get_word_occurences(first, "beta"), 1)

	// A second buffer gets its own entry.
	other := word_db_test_make_buffer([]string{"gamma\n"})
	defer buffer_destroy(other)
	third := word_db_get(other)
	testing.expect(t, third != first)
	testing.expect_value(t, word_db_get_word_occurences(third, "gamma"), 1)

	word_db_release(buffer)
	testing.expect_value(t, len(buffer.scope.data.options.watchers), 0)
	rebuilt := word_db_get(buffer)
	testing.expect(t, rebuilt != first)
	testing.expect_value(t, word_db_get_word_occurences(rebuilt, "alpha"), 1)

	word_db_release(buffer)
	word_db_release(other)
	word_db_release(other) // releasing twice is a no-op
	testing.expect_value(t, len(buffer.values), 0)
	testing.expect_value(t, len(other.values), 0)
}

// Rapid insert/erase churn across several lines keeps refcounts exact:
// three changes fold at once (two inserts, then an erase removing a
// whole line), then everything is erased.
@(test)
word_db_test_edit_churn :: proc(t: ^testing.T) {
	buffer := word_db_test_make_buffer([]string{"one two\n", "three four\n", "five six\n"})
	defer buffer_destroy(buffer)
	db := word_db_make(buffer)
	defer word_db_destroy(&db)

	_, err := buffer_insert(buffer, Coord_Buffer{0, 0}, "zero ")
	testing.expect_value(t, err, Buffer_Error.None)
	_, err = buffer_insert(buffer, Coord_Buffer{2, 0}, "zero ")
	testing.expect_value(t, err, Buffer_Error.None)
	_, err = buffer_erase(buffer, Coord_Buffer{1, 0}, Coord_Buffer{2, 0})
	testing.expect_value(t, err, Buffer_Error.None)

	res := word_db_find_matching(&db, "")
	defer delete(res)
	got := word_db_test_candidates(&res)
	defer delete(got)
	word_db_test_expect_words(t, got[:], []string{"five", "one", "six", "two", "zero"})
	testing.expect_value(t, word_db_get_word_occurences(&db, "zero"), 2)
	testing.expect_value(t, word_db_get_word_occurences(&db, "two"), 1)

	// Erase everything: the index empties without dangling refcounts.
	_, err = buffer_erase(buffer, Coord_Buffer{0, 0}, buffer_end_coord(buffer))
	testing.expect_value(t, err, Buffer_Error.None)
	res2 := word_db_find_matching(&db, "")
	defer delete(res2)
	testing.expect_value(t, len(res2), 0)
	testing.expect_value(t, len(db.words), 0)
}

// A multi-line insert followed by an erase spanning it exercises the
// merged line-modification folding (erase swallowing earlier inserts).
@(test)
word_db_test_erase_swallows_insert :: proc(t: ^testing.T) {
	buffer := word_db_test_make_buffer([]string{"keep\n"})
	defer buffer_destroy(buffer)
	db := word_db_make(buffer)
	defer word_db_destroy(&db)

	// Both changes accumulate before the next refresh, so they fold
	// into one update.
	_, err := buffer_insert(buffer, Coord_Buffer{0, 4}, "\nAAA\nBBB\nCCC")
	testing.expect_value(t, err, Buffer_Error.None)
	_, err = buffer_erase(buffer, Coord_Buffer{1, 0}, Coord_Buffer{3, 3})
	testing.expect_value(t, err, Buffer_Error.None)

	res := word_db_find_matching(&db, "")
	defer delete(res)
	got := word_db_test_candidates(&res)
	defer delete(got)
	word_db_test_expect_words(t, got[:], []string{"keep"})
	testing.expect_value(t, word_db_get_word_occurences(&db, "keep"), 1)
}

// A missing "extra_word_chars" option falls back to the {'_'}
// default; unknown words report zero occurences.
@(test)
word_db_test_missing_option_fallback :: proc(t: ^testing.T) {
	buffer := word_db_test_make_buffer([]string{"foo_bar baz-qux\n"})
	defer buffer_destroy(buffer)
	db := word_db_make(buffer)
	defer word_db_destroy(&db)

	testing.expect_value(t, word_db_get_word_occurences(&db, "foo_bar"), 1)
	testing.expect_value(t, word_db_get_word_occurences(&db, "baz"), 1)
	testing.expect_value(t, word_db_get_word_occurences(&db, "qux"), 1)
	testing.expect_value(t, word_db_get_word_occurences(&db, "baz-qux"), 0)
	testing.expect_value(t, word_db_get_word_occurences(&db, ""), 0)

	res := word_db_find_matching(&db, "zzz_no_match")
	defer delete(res)
	testing.expect_value(t, len(res), 0)
}

// Every word_db allocation is freed: make, an edit, find_matching and
// destroy leave the tracking allocator empty.
@(test)
word_db_test_allocator_cleanup :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	alloc := mem.tracking_allocator(&track)
	defer mem.tracking_allocator_destroy(&track)

	// The buffer itself uses the default allocator so only word_db
	// allocations are tracked.
	buffer := word_db_test_make_buffer([]string{"tchou mutch\n", "allo\n"})
	defer buffer_destroy(buffer)
	{
		db := word_db_make(buffer, alloc)
		defer word_db_destroy(&db)

		_, err := buffer_insert(buffer, Coord_Buffer{1, 4}, " kanaky")
		testing.expect_value(t, err, Buffer_Error.None)
		res := word_db_find_matching(&db, "", alloc)
		defer delete(res)
		testing.expect_value(t, len(res), 4)
		testing.expect_value(t, word_db_get_word_occurences(&db, "kanaky"), 1)
	}
	testing.expect_value(t, len(track.allocation_map), 0)
}

// word_db_test_remove_words_drops_slots erases every indexed word and
// requires the slots to be gone (no ghost entries).
// Regression test: remove_words freed the key bytes before delete_key,
// whose probing compares stored keys, so zero-refcount slots survived
// with dangling keys.
@(test)
word_db_test_remove_words_drops_slots :: proc(t: ^testing.T) {
	lines := []string{"alpha beta\n"}
	buffer := word_db_test_make_buffer(lines)
	defer buffer_destroy(buffer)
	// Poison-on-free (see test_poison_allocator_proc) so a
	// delete-before-delete_key regression fails deterministically.
	poison_backing := context.allocator
	poison := mem.Allocator{test_poison_allocator_proc, &poison_backing}
	db := word_db_make(buffer, poison)
	word_db_watch(&db)
	defer word_db_destroy(&db)

	testing.expect_value(t, word_db_get_word_occurences(&db, "alpha"), 1)
	testing.expect_value(t, word_db_get_word_occurences(&db, "beta"), 1)
	_, err := buffer_erase(buffer, Coord_Buffer{0, 0}, Coord_Buffer{0, 10})
	testing.expect_value(t, err, Buffer_Error.None)
	// find_matching refreshes the db (applying the erase) first.
	res := word_db_find_matching(&db, "")
	defer delete(res)
	testing.expect_value(t, len(res), 0)
	testing.expect_value(t, len(db.words), 0)
}
