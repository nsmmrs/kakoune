# C++-vs-Odin differential fuzzing for wave-1/wave-2/wave-4 ports

Each covered module has a pair of harnesses with an identical line protocol:

- `hash/`, `diff/`, `ranked_match/`, `json/`, `format/`, `ranges/`,
  `utf8/`, `regex/`, `regex_vm/`, `faces/`, `keymap_manager/`,
  `parameters_parser/` each contain:
  - `harness.cc` — compiled with `g++` against the **real** `src/` code.
  - `main.odin` — `package main`, imports the port via
    `import kak "kaksrc:kak"`; run with `odin run` or `odin build`.
  - `vectors.txt` — seed vectors, mostly mined from the C++ `UnitTest`s.
- `fuzz.py` — build + fuzz driver. Builds all 24 binaries, feeds
  seeds + generated random inputs to both sides, diffs outputs.
- `results.log` — findings, per-module verdicts, and the run log.

## Quick start

From the repo root:

```
python3 odin/difftest/fuzz.py
```

This builds into `odin/difftest/bin/` and fuzzes every module with
20,000 generated vectors (plus seeds) at the default seed. Exit 0
means every compared line agreed.

Useful flags:

```
python3 odin/difftest/fuzz.py --modules json --count 50000 --seed 7
python3 odin/difftest/fuzz.py --no-build --modules ranked_match
python3 odin/difftest/fuzz.py --smoke-odin-run   # prove odin run == built binary
python3 odin/difftest/fuzz.py --results odin/difftest/results.log
```

## Line protocol

One vector per stdin line, one result per stdout line. Fields are
separated by TAB (significant trailing tabs: `murmur3\t` hashes the
empty string). Byte strings are escaped: printable ASCII except
backslash passes through, everything else is `\xNN`. Both harnesses
implement the same decoder; every module also answers `echo` with the
re-escaped input as a decoder self-check.

Ops per module (see each `harness.cc` header comment for details):

- hash: `murmur3`, `fnv1a`, `combine`, `values`, `echo`
- diff: `diff` (prints runs like `K3 R1 A2`, or `EMPTY`), `echo`
- ranked_match: `match`, `matchL` (UsedLetters pretest ctor), `cmp`
  (prints `NA` unless both match, else both `operator<` directions),
  `letters`, `lowletters`, `echo`
- json: `parse` (prints `OK <canon>`, `NULL`, or `ERR <what>`),
  `serstr`, `serint`, `serbool`, `echo`
- format: `int`, `uint`, `hex`, `grouped`, `float` (u32 hex bits),
  `cp` (escaped UTF-8), `format` / `format_to` (print `OK <escaped>`
  or `ERR <what>`), `echo`
- ranges: `split`, `split_after`, `split_esc` (print
  `<n>\t<p0>...`), `reverse`, `skip`, `drop`, `filter`,
  `transform`, `enum`, `find`, `contains`, `all_of`, `any_of`,
  `remove_if`, `unerase`, `flatten`, `concat`, `accumulate`,
  `for_n_best`, `static_gather` (prints the array or `ERR`), `echo`
- utf8: `is_start`, `read` (prints `<cp> <newpos>`), `cp`,
  `size_byte`, `size_cp`, `next`, `finish`, `previous`,
  `charstart`, `advance`, `distance`, `prevcp`, `dump`, `width`,
  `coldist`, `advcol`, `echo`
- regex: `compile` (prints marks/saves/named captures, or
  `ERR <what>`), `match`, `matchs`, `search`, `searchs`,
  `bsearch`, `iter`/`biter` (print `N <k> [...]`), `named`,
  `flags`, `empty`, `echo`
- regex_vm: `compile` (prints saves/inst-count/classes/lookarounds/
  start-descs), `exec` (all 16 direction/search/anymatch/nosaves
  modes), `ctype`, `echo`
- faces: `merge`, `tostring`, `attrstr`, `parse`, `lookup`, `add`,
  `chain`, `flatten`, `child`, `echo` (no remove op: the Odin
  `face_registry_remove` corrupts the registry — see results.log)
- keymap_manager: `mapget`, `unmapget`, `unmapall`, `mapped`,
  `usermode`, `parent`, `echo`
- parameters_parser: `parse`, `parseie` (ignore_errors),
  `gendoc`, `echo`

Single-shot examples (equivalent; the driver uses the binaries for
speed, `--smoke-odin-run` proves they match `odin run`):

```
printf 'murmur3\tHello, World!\n' | odin/difftest/bin/hash_odin
printf 'murmur3\tHello, World!\n' | odin run odin/difftest/hash -collection:kaksrc=odin
printf 'parse\t{"b":1,"a":[true]}\n' | odin/difftest/bin/json_cc
```

## C++ build recipes

```
g++ -std=c++20 -O1 -Isrc odin/difftest/hash/harness.cc src/hash.cc -o bin/hash_cc
g++ -std=c++20 -O1 -Isrc odin/difftest/diff/harness.cc -o bin/diff_cc
g++ -std=c++20 -O1 -Isrc odin/difftest/ranked_match/harness.cc src/ranked_match.cc -o bin/ranked_match_cc
g++ -std=c++20 -O1 -Isrc odin/difftest/json/harness.cc src/json.cc src/string.cc \
    src/string_utils.cc src/memory.cc src/exception.cc src/format.cc -o bin/json_cc
g++ -std=c++20 -O1 -Isrc odin/difftest/format/harness.cc src/format.cc src/string.cc \
    src/string_utils.cc src/memory.cc src/exception.cc -o bin/format_cc
g++ -std=c++20 -O1 -Isrc odin/difftest/ranges/harness.cc -o bin/ranges_cc
g++ -std=c++20 -O1 -Isrc odin/difftest/utf8/harness.cc -o bin/utf8_cc
g++ -std=c++20 -O1 -Isrc odin/difftest/regex/harness.cc src/regex.cc src/regex_vm.cc \
    src/string.cc src/string_utils.cc src/memory.cc src/exception.cc src/format.cc \
    src/hash.cc -o bin/regex_cc
g++ -std=c++20 -O1 -Isrc odin/difftest/regex_vm/harness.cc src/regex_vm.cc src/string.cc \
    src/string_utils.cc src/memory.cc src/exception.cc src/format.cc src/hash.cc \
    -o bin/regex_vm_cc
g++ -std=c++20 -O1 -Isrc odin/difftest/faces/harness.cc src/face_registry.cc src/color.cc \
    src/string.cc src/string_utils.cc src/memory.cc src/exception.cc src/format.cc \
    src/hash.cc -o bin/faces_cc
g++ -std=c++20 -O1 -Isrc odin/difftest/keymap_manager/harness.cc src/keymap_manager.cc \
    src/keys.cc src/string.cc src/string_utils.cc src/memory.cc src/exception.cc \
    src/format.cc src/hash.cc -o bin/keymap_manager_cc
g++ -std=c++20 -O1 -Isrc odin/difftest/parameters_parser/harness.cc \
    src/parameters_parser.cc src/string.cc src/string_utils.cc src/memory.cc \
    src/exception.cc src/format.cc src/hash.cc src/ranked_match.cc \
    -o bin/parameters_parser_cc
```

(`-w` silences a pre-existing `-Winit-list-lifetime` warning in
`src/array_view.hh`, unrelated to this harness.)

```
odin build odin/difftest/<module> -collection:kaksrc=<repo>/odin -out:bin/<module>_odin
```

## Known comparison adjustments

- **json errors.** C++ reports failures as a null `Value` or a thrown
  exception; Odin returns a `Json_Error` enum. The driver maps:
  `NULL` → `Unexpected_End`; `unable to parse array/object` (bare
  bracket at end) → `Unexpected_End`; `maximum parsing depth reached`
  → `Max_Depth`; `expected :` → `Expected_Colon`;
  `unable to parse {array,object}, expected ',' or ...` →
  `Expected_Comma_Or_Close`; `unable to parse json` →
  `Unexpected_Char`; `bad_value_cast` → `Non_String_Key`;
  `<s> is not a number` → `Bad_Number`. Any unmapped C++ error
  surfaces as a mismatch for manual review.
- **json objects.** Both sides canonicalize with byte-sorted keys
  (`{"k": v,...}`); scalar rendering reuses the real `to_json` /
  `json_to_string`, so string escaping stays under test.
- **ranked_match locale.** The C++ matcher uses libc wide-character
  classes; the harness pins `LC_ALL` to `en_US.utf8` (fallback
  `C.utf8`) and prints the effective `LC_CTYPE` on stderr. Non-ASCII
  agreement is therefore "matches glibc under a UTF-8 locale"; the
  Odin port documents core:unicode tables as its deliberate
  deviation outside that.
- **ranked_match surface.** Only the public C++ API is observable
  (`operator bool`, `operator<`, `used_letters`, `to_lower`), so
  flags/counts are compared indirectly through match results and
  pairwise orderings. `cmp` prints `NA` unless both sides match
  (the Odin `ranked_match_less` asserts this precondition).
- **json positions.** `json_parse` does not return `new_pos`, so input
  offsets are not compared, only values and error classes.
- **format errors.** The driver maps C++ `what()` strings onto the
  Odin `Format_Error` names: `format string error, unclosed '{'` →
  `Unclosed_Brace`; `format string parameter index too big` →
  `Param_Index_Too_Big` (both sides agree negative indices are an
  error: the C++ compares against `params.size()` after converting
  to `size_t`); `<s> is not a number` → `Invalid_Number`;
  `buffer is too small` → `Buffer_Too_Small`. Any other `what()`
  surfaces as a mismatch for manual review. `what()` is escaped by
  the harness (it embeds the raw index/width field, which may hold
  newlines).
- **format_to precedence.** When a `format_to` input both overflows
  its buffer and has an invalid later placeholder, the C++ reports
  `Buffer_Too_Small` (it throws mid-write) while the Odin port
  reports the placeholder error (sticky overflow flag, checked
  last). Either true error is accepted for `format_to` vectors.
- **format floats.** `float` lines compare semantically: both
  spellings must parse to the same f32 bits (all NaN spellings are
  one class). `to_chars` prints `inf`/`-inf`/`nan`/`-nan` where
  `generic_ftoa` prints `Inf`/`-Inf`/`NaN`, and the two shortest-
  formatting implementations differ in rare last-digit ties (both
  spellings round-trip; 3 patterns found in 60k random bit patterns,
  no others in fuzzing).
- **format domains.** `grouped` is fuzzed only below 10^18 (19+
  digits overrun the C++ `InplaceString<23>`; the Odin port sizes
  exactly). `cp` is fuzzed over [0, INT32_MAX]: negative runes are
  unrepresentable as C++ `char32_t` (the Odin port encodes their low
  byte instead of emitting nothing). Generated widths are small or
  wrap small, so padding stays bounded.
- **ranges domains.** `skip`/`drop` counts are capped at the input
  length (`std::next` past the end is C++ UB; the Odin port clamps).
  `accumulate` values/inits are small enough that no signed overflow
  occurs. `for_n_best` inputs are distinct (heap-pop order and the
  port's linear-max order agree on distinct values; ties are
  implementation-defined). `static_gather` needs a non-empty input
  (the C++ dereferences `end()` on empty ranges — it segfaults) and
  N in 1..4 (the Odin port cannot instantiate N=0: `0 ..< 0` is a
  compile error in `ranges.odin`). Untested by design: `gather`
  (trivial copy), the member-pointer `transform` overload (no Odin
  equivalent).
- **utf8 charstart at end.** `character_start(s, len(s))` on a
  non-empty string returns `len` in C++ (it reads `*end()`, which is
  NUL for `std::string`) but the last character's start in Odin.
  This is a genuine single-point divergence and the only one found:
  every other utf8 vector agrees.
- **utf8 widths.** `codepoint_width` is libc `wcwidth` in C++ but
  `core:unicode` tables in Odin; an exhaustive 0..0x10FFFF probe
  found 66,015 codepoints (5.9%) where they differ, mostly
  unassigned-in-wide-block (glibc 1, tables 2) and format/zero-width
  characters (glibc 0, tables 1). Width-touching fuzz inputs
  (`width`, `coldist`, `advcol`, format padding params) therefore
  draw from a probe-verified agreement pool spanning widths {0,1,2};
  the harnesses pin `LC_ALL` to `en_US.utf8` (fallback `C.utf8`).
- **utf8 domains.** `size_cp`/`dump` are fuzzed over [0, INT32_MAX]:
  above that the C++ `char32_t` and Odin `rune` (i32) disagree by
  representation (negative runes yield size 1 in Odin — pinned by
  `utf8_test` — versus 0 in C++). Backward `advance`/`advcol` steps
  are bounded so the C++ never walks past `begin` (an out-of-bounds
  read there; the Odin port clamps at 0). `coldist`/`advcol` have no
  `utf8.odin` counterpart: their loops are transcribed in
  `main.odin` over the ported decode + width primitives.
- **regex locale.** Like ranked_match, the C++ engine uses libc
  wide-character classes (`iswalnum` for `\w`/`\b`, `iswdigit` for
  `\d`, `towlower` for `(?i)`); both regex harnesses pin `LC_ALL` to
  `en_US.utf8` (fallback `C.utf8`). The port documents
  `core:unicode` tables as its deliberate deviation outside ASCII.
- **regex windows.** `exec` search windows are always nested inside
  the subject window, like every real caller: a search outside the
  subject is C++ UB (the boundary assertions read `pos-1`/`pos`)
  and panics the Odin port (`regex_vm.odin` bounds check). Repro:
  `exec\t^\t0\t1\t0\t0\t4\t4\t0\tabcdef` (C++ `NO`, Odin
  panic). Windows may still split characters and dangle off the
  ends (the harness clamps); `NoForward` is stripped for forward
  exec ops and `Backward` is forced for backward ones, on both
  sides.
- **regex invalid patterns.** The Odin parser reports `Invalid utf8
  in regex` for invalid lead bytes and truncated sequences that the
  C++ accepts: `read_codepoint`'s inner `read_codepoint_multibyte`
  call drops the throwing policy (it uses default `Pass`), so only
  end-of-input dereferences throw in C++. Fuzz patterns stay in the
  agreement domain (checked by `_rx_pattern_decodable`); 8 seeds pin
  the gap, plus agreement pins for orphan continuations (skipped by
  both sides) and blind-masked sequences (surrogates, `\xc3(`).
- **regex ctype census.** `ctype` compares `is_ctype` over raw
  8-bit masks; all 32,768 ASCII (mask, cp) pairs agree exhaustively.
  Non-ASCII pairs split exactly on the documented
  libc-vs-tables gap (single-bit and multi-bit masks verified
  against an independent `Kakoune::is_ctype` oracle).
- **faces construction.** `FaceRegistry`'s root constructor is
  private (`friend Scope`), so the C++ harness defines `private` to
  `public` around the include — access specifiers do not affect
  layout, so the exercised code is the real one. Same for
  `KeymapManager`. Error `what()` strings are mapped onto the Odin
  enums (`invalid face description` → `Invalid_Description`,
  `no such face attribute` → `Unknown_Attribute`, color failures →
  `Invalid_Color`, `already defined` → `Already_Defined`,
  `invalid face name` → `Invalid_Name`, `face cycle detected` →
  `Face_Cycle`; keymap `... is already a regular mode` →
  `Regular_Mode`, `user mode ... already defined` →
  `Already_Defined`, `invalid mode name` → `Invalid_Name`).
- **faces domains.** Descriptions placing `,` or `+` after `@` are
  excluded: the C++ builds a reversed range / walks off the end
  (the Odin port reports `Invalid_Description`, a documented
  deviation). Face hashes are not compared: attribute bit positions
  are an implementation detail that differs by design on both sides.
  `flatten` entries are name-sorted in the harness (hash iteration
  order differs).
- **faces high bytes.** Bytes ≥ 0x80 take different word-class
  paths (`is_word` is false in C++ for negative `char`, Unicode
  tables in Odin), so fuzz descriptions/names are ASCII (controls
  included); 8 seeds pin the gap plus control-byte agreement pins.
- **keymap_manager order.** Listings are sorted by `Key::val()` in
  the harness (hash iteration order differs); modes are 0..10,
  modifiers/`user_modes` output is insertion-ordered.
- **parameters_parser surface.** Error classes (not messages) are
  compared: `unknown_option`, `missing_option_value`,
  `wrong_argument_count` are distinct C++ types, duplicates are
  `runtime_error`. `state()` is never called on an empty C++ parse
  (it dereferences an empty `Optional` — UB); the harness prints
  `NONE` there, matching the port. Valued switches use a dummy
  `ArgCompleter` (the parser only observes its presence).
  `gendoc` lines are byte-sorted in the harness and ASCII-only (its
  alignment uses display widths, same `wcwidth` reason as utf8).

## Reproducing a mismatch

A failure prints the offending input line plus both outputs, e.g.:

```
  --- vector #1234
  in:   parse\t{"a":1,}
  c++:  ERR unable to parse object, expected ',' or '}'
  odin: ERR Expected_Comma_Or_Close
```

(The example above is *not* a mismatch: the driver normalizes it. A
real mismatch shows lines that differ after normalization.) Feed the
`in:` line to each binary by hand:

```
printf '%s\n' 'parse\t{"a":1,}' | odin/difftest/bin/json_cc
printf '%s\n' 'parse\t{"a":1,}' | odin/difftest/bin/json_odin
```

Note: the shell must pass a literal TAB where `\t` appears. Every
run is seeded (`--seed`, default 20261003), so re-running with the
same seed and count reproduces the exact vector stream.
