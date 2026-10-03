// Port of Kakoune's src/word_db.{hh,cc}: the per-buffer word database
// used by insert-mode word completion.
//
// Types (Word_DB, Word_DB_Word_Info, ...) come from knot.odin
// (READ-ONLY shared vocabulary). This file implements the WordDB procs
// plus get_word_db.
//
// Ownership and lifecycle:
//   * word_db_make builds a value over buffer (cloning every line and
//     every distinct word with `allocator`, stored in the struct) and
//     word_db_destroy frees them; the struct itself is caller-owned.
//   * Unlike the C++ constructor, word_db_make does NOT register the
//     option watcher: the returned value has no stable address yet.
//     Call word_db_watch once the Word_DB sits at its final address
//     (word_db_get does this for its heap copy); word_db_destroy
//     unregisters again. Destroy every Word_DB before its buffer.
//   * word_db_get caches one Word_DB in buffer.values(); it is owned
//     by the buffer. word_db_release destroys that entry (C++ runs
//     ~WordDB from the Value destructor; Odin value_free cannot run
//     destructors, so buffer_destroy should call word_db_release:
//     coordinator note).
//   * word_db_find_matching returns a caller-owned list whose
//     candidates borrow the database word storage: use them before
//     the next db mutation and delete the list with the same
//     allocator.
//
// Known deviations (all forced by the wave phase, see summary):
//   * A buffer without an "extra_word_chars" option (buffer_make
//     leaves the option map empty until the scopes wire up) falls
//     back to {'_'}, the main.cc default, instead of throwing
//     option_not_found like the C++ operator[].
package kak

import "core:strings"

// Word_DB_Error is the module error enum. All current word_db procs
// are infallible; this is reserved for future fallible wrappers.
Word_DB_Error :: enum {
	None,
}

// word_db_cache_id keys the Word_DB inside buffer.values() (the C++
// function-local static ValueId). Lazily minted on first use.
@(private = "file")
word_db_cache_id: Value_Id

@(private = "file")
word_db_cache_id_ready := false

// word_db_default_extra_word_chars is the main.cc default for the
// "extra_word_chars" option, used when the buffer has no such option.
@(private = "file")
word_db_default_extra_word_chars := [1]rune{'_'}

// word_db_make builds a database over buffer (port of the WordDB
// constructor minus watcher registration: the returned value has no
// stable address, so call word_db_watch once it does). Lines and
// distinct words are cloned with allocator; free with word_db_destroy.
word_db_make :: proc(buffer: ^Buffer, allocator := context.allocator) -> Word_DB {
	db := Word_DB{
		buffer    = buffer,
		timestamp = 0,
		words     = make(map[string]Word_DB_Word_Info, allocator),
		lines     = make([dynamic]string, allocator),
		allocator = allocator,
	}
	word_db_rebuild(&db)
	return db
}

// word_db_destroy unregisters the watcher (a no-op when the db was
// never watched) and frees every owned word, line and container. It
// does not free db itself. Destroy before the buffer.
word_db_destroy :: proc(db: ^Word_DB) {
	alloc := db.allocator
	word_db_unwatch(db)
	for word in db.words {
		delete(word, alloc)
	}
	delete(db.words)
	for line in db.lines {
		delete(line, alloc)
	}
	delete(db.lines)
}

// word_db_get returns the buffer's cached database, building and
// watching it on first use (port of get_word_db). The result is
// borrowed from buffer.values(); destroy it with word_db_release.
word_db_get :: proc(buffer: ^Buffer) -> ^Word_DB {
	if !word_db_cache_id_ready {
		word_db_cache_id = value_get_free_id()
		word_db_cache_id_ready = true
	}
	vals := buffer_values(buffer)
	if word_db_cache_id in vals {
		cached, err := value_as(vals[word_db_cache_id], Word_DB)
		assert(err == .None)
		return cached
	}
	db := word_db_make(buffer, buffer.allocator)
	vals[word_db_cache_id] = value_make(db, buffer.allocator)
	cached, err := value_as(vals[word_db_cache_id], Word_DB)
	assert(err == .None)
	word_db_watch(cached)
	return cached
}

// word_db_release destroys the buffer's cached database, if any, and
// drops it from buffer.values(). A no-op without a cached entry.
word_db_release :: proc(buffer: ^Buffer) {
	if !word_db_cache_id_ready {
		return
	}
	vals := buffer_values(buffer)
	if word_db_cache_id not_in vals {
		return
	}
	val := vals[word_db_cache_id]
	if cached, err := value_as(val, Word_DB); err == .None {
		word_db_destroy(cached)
	}
	value_free(&val, buffer.allocator)
	delete_key(vals, word_db_cache_id)
}

// word_db_find_matching refreshes the database and returns every word
// matching str (port of WordDB::find_matching). The caller owns the
// list and deletes it with allocator; candidates borrow db storage.
word_db_find_matching :: proc(db: ^Word_DB, str: string, allocator := context.allocator) -> [dynamic]Ranked_Match {
	word_db_update(db)
	letters := ranked_match_used_letters(str)
	res := make([dynamic]Ranked_Match, 0, len(db.words), allocator)
	for _, info in db.words {
		match := ranked_match_make_with_letters(info.word, info.letters, str, letters)
		if match.matches {
			append(&res, match)
		}
	}
	return res
}

// word_db_get_word_occurences returns the number of occurences of word
// in the database, or 0 when absent (port of get_word_occurences,
// typo included). Like the C++ const method it does not refresh.
word_db_get_word_occurences :: proc(db: ^Word_DB, word: string) -> int {
	if info, ok := db.words[word]; ok {
		return info.refcount
	}
	return 0
}

// word_db_on_option_changed rebuilds the database when the word
// definition changes (port of on_option_changed).
word_db_on_option_changed :: proc(db: ^Word_DB, option: ^Option) {
	if option_manager_option_name(option) == "extra_word_chars" {
		word_db_rebuild(db)
	}
}

// word_db_watcher_callback adapts word_db_on_option_changed to the
// merged Option_Watcher callback shape.
word_db_watcher_callback :: proc(data: rawptr, option: rawptr) {
	word_db_on_option_changed(cast(^Word_DB)data, cast(^Option)option)
}

// word_db_watcher builds the Option_Watcher observing db.
word_db_watcher :: proc(db: ^Word_DB) -> Option_Watcher {
	return Option_Watcher{data = db, on_option_changed = word_db_watcher_callback}
}

// word_db_watch registers db on its buffer's option manager. Call
// once, after db sits at its final address.
word_db_watch :: proc(db: ^Word_DB) {
	option_manager_register_watcher(&db.buffer.scope.data.options, word_db_watcher(db))
}

// word_db_unwatch unregisters db, silently skipping a db that was
// never watched (unlike option_manager_unregister_watcher, which the
// C++ unregister_watcher parity requires to assert).
word_db_unwatch :: proc(db: ^Word_DB) {
	if db.buffer == nil {
		return
	}
	managers := &db.buffer.scope.data.options
	watcher := word_db_watcher(db)
	for w, i in managers.watchers {
		if w == watcher {
			ordered_remove(&managers.watchers, i)
			return
		}
	}
}

// word_db_extra_word_chars reads the buffer's "extra_word_chars"
// option, falling back to the main.cc default {'_'} when the buffer
// has no such option yet (see the header).
@(private = "file")
word_db_extra_word_chars :: proc(buffer: ^Buffer) -> []rune {
	if opt, err := option_manager_get_option(&buffer.scope.data.options, "extra_word_chars"); err == .None {
		if runes, ok := opt.value.([dynamic]rune); ok {
			return runes[:]
		}
	}
	return word_db_default_extra_word_chars[:]
}

// word_db_add_words indexes the words of line (port of add_words).
// New words are cloned with the db allocator and shared between the
// map key and the info struct (one backing store, freed once).
@(private = "file")
word_db_add_words :: proc(db: ^Word_DB, line: string, extra_word_chars: []rune) {
	splitter := word_splitter_make(line, extra_word_chars)
	it := word_splitter_begin(splitter)
	for !word_splitter_iterator_at_end(it) {
		word := word_splitter_iterator_value(it)
		if word in db.words {
			info := db.words[word]
			info.refcount += 1
			db.words[word] = info
		} else {
			owned := strings.clone(word, db.allocator)
			db.words[owned] = Word_DB_Word_Info{word = owned, letters = ranked_match_used_letters(owned), refcount = 1}
		}
		word_splitter_iterator_next(&it)
	}
}

// word_db_remove_words drops one index count per word of line, freeing
// words whose refcount reaches zero (port of remove_words).
@(private = "file")
word_db_remove_words :: proc(db: ^Word_DB, line: string, extra_word_chars: []rune) {
	splitter := word_splitter_make(line, extra_word_chars)
	it := word_splitter_begin(splitter)
	for !word_splitter_iterator_at_end(it) {
		word := word_splitter_iterator_value(it)
		info, ok := db.words[word]
		assert(ok && info.refcount > 0)
		info.refcount -= 1
		if info.refcount == 0 {
			// Remove the slot BEFORE freeing the key bytes:
			// delete_key compares stored keys during probing.
			delete_key(&db.words, word)
			delete(info.word, db.allocator)
		} else {
			db.words[word] = info
		}
		word_splitter_iterator_next(&it)
	}
}

// word_db_rebuild re-indexes the whole buffer (port of rebuild_db).
@(private = "file")
word_db_rebuild :: proc(db: ^Word_DB) {
	buffer := db.buffer
	alloc := db.allocator
	for word in db.words {
		delete(word, alloc)
	}
	clear(&db.words)
	for line in db.lines {
		delete(line, alloc)
	}
	clear(&db.lines)
	extra_word_chars := word_db_extra_word_chars(buffer)
	reserve(&db.lines, int(buffer_line_count(buffer)))
	for line in 0 ..< int(buffer_line_count(buffer)) {
		append(&db.lines, strings.clone(buffer_line(buffer, Units_LineCount(line)), alloc))
		word_db_add_words(db, db.lines[len(db.lines) - 1], extra_word_chars)
	}
	db.timestamp = buffer_timestamp(buffer)
}

// word_db_update incrementally re-indexes lines changed since
// db.timestamp (port of update_db).
@(private = "file")
word_db_update :: proc(db: ^Word_DB) {
	buffer := db.buffer
	modifs := line_modification_compute(buffer, db.timestamp, context.temp_allocator)
	db.timestamp = buffer_timestamp(buffer)
	if len(modifs) == 0 {
		return
	}
	alloc := db.allocator
	extra_word_chars := word_db_extra_word_chars(buffer)
	new_lines := make([dynamic]string, 0, int(buffer_line_count(buffer)), alloc)
	old_line: Units_LineCount = 0
	for modif in modifs {
		assert(Units_LineCount(0) <= modif.new_line && modif.new_line <= buffer_line_count(buffer))
		assert(modif.new_line < buffer_line_count(buffer) || modif.num_added == 0)
		assert(old_line <= modif.old_line)
		for old_line < modif.old_line {
			append(&new_lines, db.lines[int(old_line)])
			old_line += 1
		}
		assert(Units_LineCount(len(new_lines)) == modif.new_line)
		for old_line < modif.old_line + modif.num_removed {
			assert(int(old_line) < len(db.lines))
			word_db_remove_words(db, db.lines[int(old_line)], extra_word_chars)
			delete(db.lines[int(old_line)], alloc)
			old_line += 1
		}
		for l in 0 ..< int(modif.num_added) {
			append(&new_lines, strings.clone(buffer_line(buffer, modif.new_line + Units_LineCount(l)), alloc))
			word_db_add_words(db, new_lines[len(new_lines) - 1], extra_word_chars)
		}
	}
	for int(old_line) != len(db.lines) {
		append(&new_lines, db.lines[int(old_line)])
		old_line += 1
	}
	delete(db.lines)
	db.lines = new_lines
}
