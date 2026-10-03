# C++-vs-Odin differential fuzzing for wave-1 ports

Each covered module has a pair of harnesses with an identical line protocol:

- `hash/`, `diff/`, `ranked_match/`, `json/` each contain:
  - `harness.cc` — compiled with `g++` against the **real** `src/` code.
  - `main.odin` — `package main`, imports the port via
    `import kak "kaksrc:kak"`; run with `odin run` or `odin build`.
  - `vectors.txt` — seed vectors, mostly mined from the C++ `UnitTest`s.
- `fuzz.py` — build + fuzz driver. Builds all 8 binaries, feeds
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
