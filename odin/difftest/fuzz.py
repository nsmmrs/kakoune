#!/usr/bin/env python3
"""C++-vs-Odin differential fuzz driver for merged wave-1 modules.

Builds a C++ harness binary (g++ from real src/ code) and an Odin
counterpart (`odin build` of main.odin; `odin run` on the same directory
produces identical output, verified by --smoke-odin-run) per module,
feeds seed vectors from vectors.txt plus generated random inputs, and
diffs the outputs line by line.

Usage:
  python3 fuzz.py [--modules hash,diff,ranked_match,json,format,ranges,utf8,
                               regex,regex_vm,faces,keymap_manager,
                               parameters_parser]
                  [--count N] [--seed S] [--max-mismatch K] [--no-build]
                  [--smoke-odin-run] [--results results.log]

Exit status: 0 when every compared line agrees, 1 on any mismatch,
2 on build/setup failure.
"""

import argparse
import os
import random
import struct
import subprocess
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))          # odin/difftest
REPO = os.path.dirname(os.path.dirname(ROOT))              # repo checkout root
BINDIR = os.path.join(ROOT, "bin")

CXX = "g++"
CXX_FLAGS = ["-std=c++20", "-O1", f"-I{os.path.join(REPO, 'src')}", "-w"]

MODULES = {
    "hash": {
        "cc_srcs": ["odin/difftest/hash/harness.cc", "src/hash.cc"],
        "gen": "gen_hash",
    },
    "diff": {
        "cc_srcs": ["odin/difftest/diff/harness.cc"],
        "gen": "gen_diff",
    },
    "ranked_match": {
        "cc_srcs": ["odin/difftest/ranked_match/harness.cc",
                    "src/ranked_match.cc"],
        "gen": "gen_ranked_match",
    },
    "json": {
        "cc_srcs": ["odin/difftest/json/harness.cc", "src/json.cc",
                    "src/string.cc", "src/string_utils.cc", "src/memory.cc",
                    "src/exception.cc", "src/format.cc"],
        "gen": "gen_json",
    },
    "format": {
        "cc_srcs": ["odin/difftest/format/harness.cc", "src/format.cc",
                    "src/string.cc", "src/string_utils.cc", "src/memory.cc",
                    "src/exception.cc"],
        "gen": "gen_format",
    },
    "ranges": {
        "cc_srcs": ["odin/difftest/ranges/harness.cc"],
        "gen": "gen_ranges",
    },
    "utf8": {
        "cc_srcs": ["odin/difftest/utf8/harness.cc"],
        "gen": "gen_utf8",
    },
    "regex": {
        "cc_srcs": ["odin/difftest/regex/harness.cc", "src/regex.cc",
                    "src/regex_vm.cc", "src/string.cc", "src/string_utils.cc",
                    "src/memory.cc", "src/exception.cc", "src/format.cc",
                    "src/hash.cc"],
        "gen": "gen_regex",
    },
    "regex_vm": {
        "cc_srcs": ["odin/difftest/regex_vm/harness.cc", "src/regex_vm.cc",
                    "src/string.cc", "src/string_utils.cc", "src/memory.cc",
                    "src/exception.cc", "src/format.cc", "src/hash.cc"],
        "gen": "gen_regex_vm",
    },
    "faces": {
        "cc_srcs": ["odin/difftest/faces/harness.cc", "src/face_registry.cc",
                    "src/color.cc", "src/string.cc", "src/string_utils.cc",
                    "src/memory.cc", "src/exception.cc", "src/format.cc",
                    "src/hash.cc"],
        "gen": "gen_faces",
    },
    "keymap_manager": {
        "cc_srcs": ["odin/difftest/keymap_manager/harness.cc",
                    "src/keymap_manager.cc", "src/keys.cc", "src/string.cc",
                    "src/string_utils.cc", "src/memory.cc", "src/exception.cc",
                    "src/format.cc", "src/hash.cc"],
        "gen": "gen_keymap_manager",
    },
    "parameters_parser": {
        "cc_srcs": ["odin/difftest/parameters_parser/harness.cc",
                    "src/parameters_parser.cc", "src/string.cc",
                    "src/string_utils.cc", "src/memory.cc", "src/exception.cc",
                    "src/format.cc", "src/hash.cc", "src/ranked_match.cc"],
        "gen": "gen_parameters_parser",
    },
}

# ---------------------------------------------------------------- escaping

_HEX = "0123456789abcdef"


def esc(data: bytes) -> str:
    """Encode bytes the way both harnesses decode: printable ASCII except
    backslash passes through, everything else becomes \\xNN."""
    out = []
    for b in data:
        if 0x20 <= b <= 0x7E and b != 0x5C:
            out.append(chr(b))
        else:
            out.append("\\x" + _HEX[b >> 4] + _HEX[b & 15])
    return "".join(out)


# ---------------------------------------------------------------- generators

_ASCII_WORD = b"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
_PATH_PUNC = b"/_-.():"
_UTF8_SAMPLES = ["é".encode(), "ü".encode(), "中".encode(), "🙂".encode(),
                 "Å".encode(), "ß".encode(), "Ω".encode()]
_BAD_UTF8 = [b"\x80", b"\xff", b"\xc3", b"\xe4\xb8", b"\xc0\xaf",
             b"\xf5\x80\x80\x80", b"\xed\xa0\x80"]
_CTRL = [b"\x00", b"\x09", b"\x0a", b"\x1b", b"\x7f"]


def rbytes(rng, lo=0, hi=24, utf8=True):
    n = rng.randint(lo, hi)
    out = bytearray()
    while len(out) < n:
        r = rng.random()
        if r < 0.62:
            out.append(rng.choice(_ASCII_WORD))
        elif r < 0.72:
            out.append(rng.choice(_PATH_PUNC))
        elif r < 0.78:
            out += rng.choice(_CTRL)
        elif utf8 and r < 0.90:
            out += rng.choice(_UTF8_SAMPLES)
        elif utf8:
            out += rng.choice(_BAD_UTF8)
        else:
            out.append(rng.choice(_ASCII_WORD))
    return bytes(out[:n])


def rword(rng):
    return rbytes(rng, 1, 12, utf8=False).decode("ascii", "replace")


_EDGE_U64 = [0, 1, 2, 255, 256, 65535, 65536, 2**32 - 1, 2**32,
             2**32 + 1, 2**63 - 1, 2**63, 2**64 - 1]


def r_u64(rng):
    if rng.random() < 0.5:
        return rng.choice(_EDGE_U64)
    return rng.getrandbits(64)


def gen_hash(rng, count):
    vecs = []
    for _ in range(count):
        r = rng.random()
        # Bias lengths 0..9 to cover every murmur tail path (len&3)
        # and the empty input.
        if r < 0.35:
            data = rbytes(rng, 0, 9)
        elif r < 0.45:
            data = bytes(rng.getrandbits(8) for _ in range(rng.randint(0, 64)))
        else:
            data = rbytes(rng, 0, 120)
        vecs.append(("murmur3\t" + esc(data) if rng.random() < 0.5
                     else "fnv1a\t" + esc(data)))
    for _ in range(count // 4):
        if rng.random() < 0.5:
            vecs.append("combine\t%d\t%d" % (r_u64(rng), r_u64(rng)))
        else:
            args = [str(r_u64(rng)) for _ in range(rng.randint(1, 4))]
            vecs.append("values\t" + "\t".join(args))
    return vecs


def _mutate(rng, data, alphabet=b"abcdefXYZ019 _-", n_edits=3):
    data = bytearray(data)
    for _ in range(rng.randint(1, n_edits)):
        op = rng.random()
        if op < 0.4 and data:  # substitute
            data[rng.randrange(len(data))] = rng.choice(alphabet)
        elif op < 0.7:  # insert
            data[rng.randrange(len(data) + 1):rng.randrange(len(data) + 1)] = \
                bytes([rng.choice(alphabet)])
        elif data:  # delete
            del data[rng.randrange(len(data))]
    return bytes(data)


def gen_diff(rng, count):
    vecs = []
    for _ in range(count):
        r = rng.random()
        if r < 0.25:
            a = rbytes(rng, 0, 40, utf8=False)
            vecs.append("diff\t%s\t%s" % (esc(a), esc(_mutate(rng, a))))
        elif r < 0.45:
            # Small alphabet forces long ambiguous alignments.
            a = bytes(rng.choice(b"ab") for _ in range(rng.randint(0, 30)))
            b = bytes(rng.choice(b"ab") for _ in range(rng.randint(0, 30)))
            vecs.append("diff\t%s\t%s" % (esc(a), esc(b)))
        elif r < 0.60:
            a = rbytes(rng, 0, 30)
            vecs.append("diff\t%s\t%s" % (esc(a), esc(a)))
        elif r < 0.75:
            a = rbytes(rng, 0, 60)
            b = rbytes(rng, 0, 60)
            vecs.append("diff\t%s\t%s" % (esc(a), esc(b)))
        elif r < 0.90:
            # Shared prefix/suffix with a differing middle.
            pre = rbytes(rng, 0, 20, utf8=False)
            suf = rbytes(rng, 0, 20, utf8=False)
            m1 = rbytes(rng, 0, 15, utf8=False)
            m2 = rbytes(rng, 0, 15, utf8=False)
            vecs.append("diff\t%s\t%s" % (esc(pre + m1 + suf),
                                            esc(pre + m2 + suf)))
        else:
            # Long inputs heading for the cost-limit fallback path.
            a = rbytes(rng, 100, 400, utf8=False)
            b = rbytes(rng, 100, 400, utf8=False)
            vecs.append("diff\t%s\t%s" % (esc(a), esc(b)))
    return vecs


def _rpath(rng):
    parts = []
    for _ in range(rng.randint(1, 4)):
        w = rword(rng)
        if rng.random() < 0.3:
            w += rng.choice([".cc", ".hh", ".py", ".md", "/", ".baz"])
        parts.append(w)
    s = "/".join(parts)
    if rng.random() < 0.3:
        s = rng.choice(["src/", "test/", "foo/bar/"]) + s
    return s


def _rquery(rng, cand):
    # A subsequence of the candidate (likely match) or a mutation of one.
    c = cand.encode() if isinstance(cand, str) else cand
    if not c or rng.random() < 0.25:
        return rbytes(rng, 0, 8)
    keep = bytearray()
    for b in c:
        if rng.random() < 0.5:
            keep.append(b)
    q = bytes(keep)[: rng.randint(0, 10)]
    if rng.random() < 0.3:
        q = _mutate(rng, q, n_edits=1)
    return q


def gen_ranked_match(rng, count):
    vecs = []
    for _ in range(count):
        r = rng.random()
        if r < 0.45:
            c = _rpath(rng)
            q = _rquery(rng, c)
            op = "match" if rng.random() < 0.5 else "matchL"
            vecs.append("%s\t%s\t%s" % (op, esc(c.encode()), esc(q)))
        elif r < 0.70:
            a = _rpath(rng).encode()
            if rng.random() < 0.6:
                # Siblings sharing words/prefix: a subsequence query then
                # usually matches both, exercising the real ordering.
                b = _mutate(rng, a, n_edits=rng.randint(1, 4))
                q = _rquery(rng, a)
                if not q:
                    q = _rquery(rng, b)
            else:
                b = _rpath(rng).encode()
                q = rbytes(rng, 0, 10)
            vecs.append("cmp\t%s\t%s\t%s" % (esc(q), esc(a), esc(b)))
        elif r < 0.85:
            # Raw byte soup incl. UTF-8 and invalid sequences.
            c = rbytes(rng, 0, 24)
            q = _rquery(rng, c)
            op = "match" if rng.random() < 0.5 else "matchL"
            vecs.append("%s\t%s\t%s" % (op, esc(c), esc(q)))
        else:
            if rng.random() < 0.5:
                vecs.append("letters\t" + esc(rbytes(rng, 0, 40)))
            else:
                vecs.append("lowletters\t%d" % r_u64(rng))
    return vecs


def _rjson_value(rng, depth):
    if depth <= 0 or rng.random() < 0.35:
        return rng.choice([
            lambda: str(rng.choice([0, 1, -1, 42, 2**31 - 1, 2**31,
                                    2**32 - 1, 2**32, -2**31, -2**31 - 1,
                                    10**30, -(10**30),
                                    rng.randint(-10**6, 10**6)])),
            lambda: rng.choice(["true", "false"]),
            # Raw bytes (incl. NUL/controls/UTF-8); only \ and " are
            # JSON-escaped. latin1 round-trips the bytes below.
            lambda: '"' + rbytes(rng, 0, 16).replace(b"\\", b"\\\\")
            .replace(b'"', b'\\"').decode("latin1") + '"',
        ])()
    if rng.random() < 0.5:
        n = rng.randint(0, 4)
        return "[" + ", ".join(_rjson_value(rng, depth - 1)
                               for _ in range(n)) + "]"
    n = rng.randint(0, 4)
    keys = set()
    items = []
    for _ in range(n):
        k = rword(rng) or "k"
        if k in keys and rng.random() < 0.7:
            pass  # keep the duplicate key sometimes
        keys.add(k)
        items.append('"%s": %s' % (k, _rjson_value(rng, depth - 1)))
    return "{" + ", ".join(items) + "}"


_JSON_TOKENS = ["true", "false", "null", "True", "TRUE", "01", "-", "--1",
                "-0", "+", "+1", "1.", ".5", "1e3", "0x1", "00", "- 1",
                "[", "]", "{", "}", '"', ":", ",", " ", "\t", "\n", "\x00",
                "\xff", "a", "'x'", "tr ue", "fals", "nul"]


def gen_json(rng, count):
    vecs = []
    for _ in range(count):
        r = rng.random()
        if r < 0.40:
            doc = _rjson_value(rng, rng.randint(0, 5))
            vecs.append("parse\t" + esc(doc.encode("latin1")))
        elif r < 0.55:
            # Valid doc, then truncated or byte-mutated.
            doc = _rjson_value(rng, rng.randint(1, 4)).encode("latin1")
            cut = rng.randint(0, len(doc))
            doc = doc[:cut]
            if rng.random() < 0.5 and doc:
                doc = _mutate(rng, doc, alphabet=b'[]{}":, truefals0123-\x00',
                              n_edits=2)
            vecs.append("parse\t" + esc(doc))
        elif r < 0.70:
            # Token soup.
            doc = "".join(rng.choice(_JSON_TOKENS)
                          for _ in range(rng.randint(1, 8)))
            vecs.append("parse\t" + esc(doc.encode("latin1")))
        elif r < 0.78:
            # Nesting depth around the 100 limit.
            d = rng.randint(90, 108)
            doc = "[" * d + "]" * d
            if rng.random() < 0.3:
                doc = doc[: rng.randint(0, len(doc))]
            vecs.append("parse\t" + esc(doc.encode()))
        elif r < 0.86:
            # Numbers around the 32-bit edges.
            n = rng.choice(["0", "-0", "1", "-1", "2147483647", "2147483648",
                            "4294967295", "4294967296", "9223372036854775807",
                            "-2147483648", "-2147483649", "-4294967296",
                            "9" * rng.randint(1, 25),
                            "-" + "9" * rng.randint(1, 25),
                            "0" * rng.randint(1, 8)])
            if rng.random() < 0.3:
                n += rng.choice([" ", "x", ".", "-", "+"])
            vecs.append("parse\t" + esc(n.encode()))
        else:
            # Serializers.
            k = rng.random()
            if k < 0.6:
                vecs.append("serstr\t" + esc(rbytes(rng, 0, 40)))
            elif k < 0.8:
                vecs.append("serint\t%d" %
                            rng.choice([0, 1, -1, 2**31 - 1, -2**31,
                                        rng.randint(-2**31, 2**31 - 1)]))
            else:
                vecs.append("serbool\t%d" % rng.randint(0, 1))
    return vecs


# Width-agreement pool: codepoints where glibc wcwidth (under en_US.utf8)
# and the Odin core:unicode tables agree, verified by an exhaustive
# 0..0x10FFFF probe (see results.log). Widths here span {0, 1, 2}:
# U+0301 and U+200B are 0; CJK/emoji/fullwidth are 2; the rest 1.
_WIDTH_POOL = [0x00, 0x30, 0x41, 0x61, 0x7F, 0xDF, 0xE9, 0xFC, 0xC5,
               0x3A9, 0x627, 0x903, 0x1100, 0x200B, 0x20AC, 0x21E7,
               0x2211, 0x2500, 0x301, 0x3041, 0x3042, 0x4E2D, 0xAC00,
               0xD55C, 0xFF00, 0xFF21, 0x1F642]
# Pool members with width >= 1 (drops U+0301, U+200B): data built from
# these keeps backward column-advance in bounds (columns >= chars).
_WIDTH1_POOL = [c for c in _WIDTH_POOL if c not in (0x301, 0x200B)]
# >0x10FFFF values with probe-verified width agreement (both sides 1).
_HUGE_WIDTH_OK = [0x110000, 0x1FFFFF, 0x200000, 0x7FFFFFFF]
_ASCII_SOUP = bytes(range(0x00, 0x80))


def _pool_data(rng, pool, lo=0, hi=12):
    """Encode n random pool codepoints; return (bytes, char boundaries)."""
    n = rng.randint(lo, hi)
    out = bytearray()
    bounds = [0]
    for _ in range(n):
        out += chr(rng.choice(pool)).encode("utf-8")
        bounds.append(len(out))
    return bytes(out), bounds


def _rpool(rng, pool=_WIDTH_POOL, lo=0, hi=12):
    return _pool_data(rng, pool, lo, hi)[0]


def _starts_before(data, pos):
    return sum(1 for b in data[:pos] if b & 0xC0 != 0x80)


_EDGE_I64 = [0, 1, -1, 127, -128, 255, -129, 2**31 - 1, -2**31,
             2**31, -2**31 - 1, 2**63 - 1, -2**63]
_GROUPED_MAX = 10**18 - 1  # 19+ digits overrun the C++ InplaceString<23>
_EDGE_CP = [0, 1, 0x41, 0x7F, 0x80, 0x7FF, 0x800, 0xD7FF, 0xD800,
            0xDFFF, 0xE000, 0xFFFF, 0x10000, 0x10FFFF, 0x110000,
            0x1FFFFF, 0x200000, 0x7FFFFFFF]
_EDGE_F32 = ["00000000", "80000000", "7f800000", "ff800000", "7fc00000",
             "ffc00000", "00000001", "007fffff", "7f7fffff", "00800000",
             "3fc00000", "4f2b0cd1", "51907a15", "4e3bae0b"]


def r_i64(rng):
    if rng.random() < 0.5:
        return rng.choice(_EDGE_I64)
    return rng.randint(-2**63, 2**63 - 1)


def r_cp(rng):
    """A codepoint in the shared [0, INT32_MAX] domain (negatives are
    unrepresentable as C++ char32_t; see README)."""
    if rng.random() < 0.4:
        return rng.choice(_EDGE_CP)
    if rng.random() < 0.6:
        return rng.randint(0, 0x10FFFF)
    return rng.randint(0, 0x7FFFFFFF)


_FMT_INDEX = ["", "0", "1", "2", "3", "9", "-1", "-2", "x", " 0", "0 ",
              "00", "01", "4294967296", "4294967297",
              "99999999999999999999999", "-4294967296"]
_FMT_WIDTH = ["0", "1", "2", "5", "10", "40", "64", "05", "00", "-3",
              "-1", "", "4294967296", "x", " 5"]


def _fmt_piece(rng):
    r = rng.random()
    if r < 0.30:
        return ("{%s}" % rng.choice(_FMT_INDEX)).encode()
    if r < 0.50:
        return ("{%s:%s}" % (rng.choice(_FMT_INDEX),
                             rng.choice(_FMT_WIDTH))).encode()
    if r < 0.60:
        return rng.choice([b"{", b"}", b"\\{", b"\\", b"{:", b":}",
                           b"::", b"{{", b"}}"])
    if r < 0.75:
        return (rword(rng) + rng.choice([" ", "", "%", "  "])).encode()
    if r < 0.85:
        return _rpool(rng, hi=3)
    # fmt is never width-measured, so full byte soup (incl. invalid
    # UTF-8) is safe here.
    return rbytes(rng, 0, 10)


def _fparam(rng):
    """A format param: ASCII soup or agreement-pool words. Byte soup
    with high bytes is avoided: params are width-measured for padding,
    and truncated decodes could land on width-deviation codepoints."""
    r = rng.random()
    if r < 0.55:
        return bytes(rng.choice(_ASCII_SOUP)
                     for _ in range(rng.randint(0, 24)))
    if r < 0.80:
        return _rpool(rng, hi=4)
    if r < 0.90:
        return b""
    return (_rpool(rng, lo=1, hi=2) +
            bytes(rng.choice(_ASCII_SOUP) for _ in range(rng.randint(0, 8))))


def _gen_format_call(rng, op):
    fmt = b"".join(_fmt_piece(rng) for _ in range(rng.randint(1, 6)))[:120]
    params = [_fparam(rng) for _ in range(rng.randint(0, 3))]
    vec = op + "\t" + esc(fmt)
    if op == "format_to":
        if rng.random() < 0.3:
            bufsz = rng.randint(0, 8)
        else:
            bufsz = rng.randint(0, 120)
        vec = "format_to\t%d\t%s" % (bufsz, esc(fmt))
    for p in params:
        vec += "\t" + esc(p)
    return vec


def gen_format(rng, count):
    vecs = []
    for _ in range(count):
        r = rng.random()
        if r < 0.15:
            vecs.append("int\t%d" % r_i64(rng))
        elif r < 0.25:
            v = rng.choice(_EDGE_U64) if rng.random() < 0.5 \
                else rng.getrandbits(64)
            vecs.append("uint\t%d" % v)
        elif r < 0.35:
            v = rng.choice(_EDGE_U64) if rng.random() < 0.5 \
                else rng.getrandbits(64)
            vecs.append("hex\t%d" % v)
        elif r < 0.45:
            if rng.random() < 0.5:
                v = rng.choice([0, 1, 999, 1000, 10**6 - 1, 10**15,
                                _GROUPED_MAX, _GROUPED_MAX - 1])
            else:
                v = rng.randint(0, _GROUPED_MAX)
            vecs.append("grouped\t%d" % v)
        elif r < 0.60:
            if rng.random() < 0.4:
                vecs.append("float\t" + rng.choice(_EDGE_F32))
            else:
                vecs.append("float\t%08x" % rng.getrandbits(32))
        elif r < 0.70:
            vecs.append("cp\t%d" % r_cp(rng))
        elif r < 0.90:
            vecs.append(_gen_format_call(rng, "format"))
        else:
            vecs.append(_gen_format_call(rng, "format_to"))
    return vecs


def _intlist(rng, lo, hi, vmin, vmax, distinct=False):
    n = rng.randint(lo, hi)
    if distinct:
        vals = rng.sample(range(vmin, vmax + 1), min(n, vmax - vmin + 1))
    else:
        vals = [rng.randint(vmin, vmax) for _ in range(n)]
    return ",".join(str(v) for v in vals)


def _split_data(rng, sep):
    if rng.random() < 0.65:
        alpha = bytes([sep]) + bytes(
            rng.sample([b for b in _ASCII_WORD if b != sep], 4))
        n = rng.randint(0, 30)
        return bytes(rng.choice(alpha) for _ in range(n))
    if rng.random() < 0.5:
        return rbytes(rng, 0, 30)
    return _rpool(rng, hi=6)


def gen_ranges(rng, count):
    vecs = []
    for _ in range(count):
        r = rng.random()
        if r < 0.30:
            sep = rng.choice([44, 44, 0, 255, 97, rng.randint(0, 255)])
            data = _split_data(rng, sep)
            k = rng.random()
            if k < 0.45:
                vecs.append("split\t%s\t%d" % (esc(data), sep))
            elif k < 0.70:
                vecs.append("split_after\t%s\t%d" % (esc(data), sep))
            else:
                escaper = sep if rng.random() < 0.25 \
                    else rng.choice([92, rng.randint(0, 255)])
                vecs.append("split_esc\t%s\t%d\t%d" %
                            (esc(data), sep, escaper))
        elif r < 0.42:
            data = rbytes(rng, 0, 40)
            k = rng.random()
            if k < 0.35:
                vecs.append("reverse\t" + esc(data))
            elif k < 0.70:
                # n <= len: larger counts are C++ UB (std::next past end).
                vecs.append("skip\t%s\t%d" % (esc(data),
                                                rng.randint(0, len(data))))
            else:
                vecs.append("drop\t%s\t%d" % (esc(data),
                                                rng.randint(0, len(data))))
        elif r < 0.67:
            data = rbytes(rng, 0, 40)
            if rng.random() < 0.5 and data:
                byte = rng.choice([rng.choice(data), rng.randint(0, 255)])
            else:
                byte = rng.choice([0, 255, rng.randint(0, 255)])
            pred = rng.randint(0, 2)
            op = rng.choice(["filter", "transform", "enum", "find",
                             "contains", "all_of", "any_of", "remove_if",
                             "unerase"])
            if op in ("enum",):
                vecs.append("enum\t" + esc(data))
            elif op in ("find", "contains", "unerase"):
                vecs.append("%s\t%s\t%d" % (op, esc(data), byte))
            else:
                vecs.append("%s\t%s\t%d" % (op, esc(data), pred))
        elif r < 0.75:
            if rng.random() < 0.5:
                parts = [_rpool(rng, hi=4)
                         for _ in range(rng.randint(0, 4))]
                vec = "flatten" + "".join("\t" + esc(p) for p in parts)
                vecs.append(vec)
            else:
                vecs.append("concat\t%s\t%s" %
                            (esc(rbytes(rng, 0, 30)),
                             esc(rbytes(rng, 0, 30))))
        elif r < 0.83:
            if rng.random() < 0.6:
                # Sums stay far from i64 overflow.
                vecs.append("accumulate\t%s\t%d\t0" %
                            (_intlist(rng, 0, 12, -1000, 1000),
                             rng.randint(-100000, 100000)))
            else:
                # Products: tiny values only (signed overflow is UB).
                vecs.append("accumulate\t%s\t%d\t1" %
                            (_intlist(rng, 0, 8, -3, 3),
                             rng.randint(-10, 10)))
        elif r < 0.91:
            if rng.random() < 0.8:
                lst = _intlist(rng, 0, 10, -50, 50, distinct=True)
            else:
                lst = _intlist(rng, 0, 8, -10**6, 10**6, distinct=True)
            n = len(lst.split(",")) if lst else 0
            vecs.append("for_n_best\t%s\t%d\t%d" %
                        (lst, rng.randint(0, n + 2), rng.randint(0, 2)))
        else:
            # Non-empty only: empty input with N>=1 dereferences end().
            vecs.append("static_gather\t%s\t%d\t%d" %
                        (_intlist(rng, 1, 6, -999, 999),
                         rng.randint(1, 4), rng.randint(0, 1)))
    return vecs


def gen_utf8(rng, count):
    vecs = []
    for _ in range(count):
        r = rng.random()
        if r < 0.08:
            b = rng.choice([0, 65, 127, 128, 191, 192, 223, 224, 239,
                            240, 247, 248, 255, rng.randint(0, 255)])
            vecs.append(("%s\t%d" % ("is_start" if rng.random() < 0.5
                                      else "size_byte", b)))
        elif r < 0.24:
            data = rbytes(rng, 0, 40)
            pos = rng.randint(0, len(data))
            op = "read" if rng.random() < 0.6 else "cp"
            vecs.append("%s\t%s\t%d" % (op, esc(data), pos))
        elif r < 0.32:
            vecs.append("size_cp\t%d" % r_cp(rng))
        elif r < 0.44:
            data = rbytes(rng, 0, 40)
            pos = rng.randint(0, len(data))
            vecs.append("%s\t%s\t%d" %
                        (rng.choice(["next", "finish", "previous"]),
                         esc(data), pos))
        elif r < 0.52:
            data = rbytes(rng, 0, 40)
            pos = rng.randint(0, len(data))
            vecs.append("charstart\t%s\t%d" % (esc(data), pos))
        elif r < 0.62:
            data = rbytes(rng, 0, 40)
            pos = rng.randint(0, len(data))
            # Backward motion must not pass begin (OOB read in C++).
            lo = -_starts_before(data, pos)
            vecs.append("advance\t%s\t%d\t%d" %
                        (esc(data), pos, rng.randint(lo, 8)))
        elif r < 0.68:
            vecs.append("distance\t" + esc(rbytes(rng, 0, 60)))
        elif r < 0.76:
            data = rbytes(rng, 0, 40)
            vecs.append("prevcp\t%s\t%d" %
                        (esc(data), rng.randint(0, len(data))))
        elif r < 0.82:
            vecs.append("dump\t%d" % r_cp(rng))
        elif r < 0.90:
            k = rng.random()
            if k < 0.40:
                vecs.append("width\t%d" % rng.choice(_WIDTH_POOL))
            elif k < 0.70:
                vecs.append("width\t%d" % rng.randint(0, 0x7F))
            elif k < 0.90:
                vecs.append("width\t%d" %
                            rng.choice([-1, -128, -61, -2147483648,
                                        rng.randint(-2**31, -1)]))
            else:
                vecs.append("width\t%d" % rng.choice(_HUGE_WIDTH_OK))
        elif r < 0.95:
            vecs.append("coldist\t" + esc(_rpool(rng, hi=12)))
        else:
            if rng.random() < 0.6:
                data, _ = _pool_data(rng, _WIDTH_POOL, 0, 12)
                vecs.append("advcol\t%s\t%d\t%d" %
                            (esc(data), rng.randint(0, len(data)),
                             rng.randint(0, 10)))
            else:
                # Backward: width>=1 data, boundary pos, bounded d.
                data, bounds = _pool_data(rng, _WIDTH1_POOL, 0, 12)
                bi = rng.randrange(len(bounds))
                vecs.append("advcol\t%s\t%d\t%d" %
                            (esc(data), bounds[bi],
                             rng.randint(-bi, 0)))
    return vecs


# ---------------------------------------------------------------- regex shared

_RX_LIT = [b"a", b"b", b"c", b"f", b"x", b"o", b"0", b"1", b"7",
           b" ", b".", b"-", b"_", b"/", b"e", b"A", b"B", b"Z",
           b"9", b":", b"Z"]
_RX_LIT_UNI = ["é".encode(), "ü".encode(), "中".encode(), "🙂".encode(),
               "д".encode(), "ß".encode(), "Ω".encode(), "à".encode(),
               "İ".encode(), "Σ".encode(), "ﬁ".encode(), "ő".encode()]
_RX_META_ESC = [b"\\.", b"\\*", b"\\+", b"\\?", b"\\(", b"\\)", b"\\[",
                b"\\]", b"\\{", b"\\}", b"\\|", b"\\\\", b"\\^", b"\\$"]
_RX_CTRL_ESC = [b"\\f", b"\\n", b"\\r", b"\\t", b"\\v", b"\\0", b"\\cA",
                b"\\cm", b"\\cZ", b"\\x41", b"\\x00", b"\\x7f",
                b"\\u000041", b"\\u01F642", b"\\u0000e9"]
_RX_CTYPES = [b"\\d", b"\\D", b"\\w", b"\\W", b"\\s", b"\\S", b"\\h",
              b"\\H", b"\\N"]
_RX_ANCHORS = [b"^", b"$", b"\\A", b"\\z", b"\\b", b"\\B"]
_RX_QUANTS = [b"", b"", b"*", b"+", b"?", b"*?", b"+?", b"??",
              b"{0}", b"{1}", b"{2}", b"{3}", b"{0,1}", b"{1,2}",
              b"{2,4}", b"{0,}", b"{1,}", b"{2,}", b"{,2}", b"{,}",
              b"{2}?", b"{1,3}?", b"{5}", b"{3,2}", b"{0,0}"]
_RX_BIG_QUANTS = [b"{999}", b"{1000}", b"{1001}", b"{0,1000}",
                  b"{0,1001}"]
_RX_MODIFIERS = [b"(?i)", b"(?I)", b"(?s)", b"(?S)", b"(?is)",
                 b"(?iS)", b"(?si)"]
_RX_CLASS_ESC = [b"\\d", b"\\w", b"\\s", b"\\h", b"\\D", b"\\W",
                 b"\\S", b"\\H", b"\\t", b"\\n", b"\\r", b"\\x41",
                 b"\\u00007a", b"\\\\", b"\\-", b"\\]", b"\\^"]
_RX_CLASS_SINGLE = [b"a", b"z", b"A", b"Z", b"0", b"9", b"_", b" ",
                    b".", b"/", b"[", b"(", "é".encode(), "ß".encode()]
_RX_RANGES = [(b"a", b"z"), (b"A", b"Z"), (b"0", b"9"), (b"a", b"c"),
              (b"b", b"d"), (b"X", b"Z"), (b"0", b"1"), (b"/", b"9")]

# Invalid patterns: every C++ parse_error message should appear.
_RX_INVALID = [b"(a", b"[a", b"a{2", b"\\Qab", b"(?<n", b"(?<n>x",
               b"(?=", b"(?<!a", b"\\q", b"\\E", b"\\k", b"a\\",
               b"[\\b]", b"[\\N]", b"[\\B]", b"[z-a]", b"a{", b"a{-1}",
               b"a{2x}", b"*a", b"a**", b")", b"]", b"a}", b"(?P<n>)",
               b"(?<>", b"(?<a-b>)", b"(?=a*)", b"(?=(a))",
               b"(?=a|b)", b"a{1001}", b"\\x4", b"\\xz1", b"\\u123",
               b"\\c", b"\\c1", b"[a-", b"\\", b"(?i", b"a{1,2",
               b"(a))", b"((a)", b"[", b"(?<9lives>a)", b"(?<!a{2})"]


def _rx_class(rng):
    n = rng.randint(1, 4)
    parts = []
    if rng.random() < 0.25:
        parts.append(b"^")
    for _ in range(n):
        r = rng.random()
        if r < 0.28:
            a, b = rng.choice(_RX_RANGES)
            parts.append(a + b"-" + b)
        elif r < 0.45:
            parts.append(rng.choice(_RX_CLASS_SINGLE))
        elif r < 0.62:
            parts.append(rng.choice(_RX_CLASS_ESC))
        elif r < 0.72:
            parts.append(b"-")
        elif r < 0.82 and _RX_LIT_UNI:
            parts.append(rng.choice(_RX_LIT_UNI))
        else:
            a = rng.choice(_RX_LIT)
            parts.append(a + b"-" + a)
    return b"[" + b"".join(parts) + b"]"


def _rx_look_body(rng):
    # Lookarounds admit only literals, any-chars and classes, with no
    # quantifiers or alternations.
    n = rng.randint(0, 3)
    parts = []
    for _ in range(n):
        r = rng.random()
        if r < 0.5:
            parts.append(rng.choice(_RX_LIT))
        elif r < 0.65:
            parts.append(b".")
        elif r < 0.8:
            parts.append(_rx_class(rng))
        else:
            parts.append(rng.choice(_RX_CTRL_ESC + _RX_META_ESC))
    return b"".join(parts)


def _rx_atom(rng):
    r = rng.random()
    if r < 0.30:
        if rng.random() < 0.2:
            return rng.choice(_RX_LIT_UNI)
        return rng.choice(_RX_LIT)
    if r < 0.38:
        return rng.choice(_RX_META_ESC)
    if r < 0.44:
        return rng.choice(_RX_CTRL_ESC)
    if r < 0.54:
        return rng.choice(_RX_CTYPES)
    if r < 0.58:
        return b"."
    if r < 0.68:
        return _rx_class(rng)
    if r < 0.72:
        return rng.choice(_RX_ANCHORS)
    if r < 0.75:
        return b"\\K"
    if r < 0.78:
        lit = b"".join(rng.choice(_RX_LIT) for _ in range(rng.randint(1, 4)))
        if rng.random() < 0.7:
            return b"\\Q" + lit + b"\\E"
        return b"\\Q" + lit
    if rng.random() < 0.2:
        return rng.choice(_RX_LIT_UNI)
    return rng.choice(_RX_LIT)


def _rx_disjunction(rng, depth):
    n = 1 if depth >= 3 or rng.random() < 0.6 else 2
    return b"|".join(_rx_sequence(rng, depth) for _ in range(n))


def _rx_sequence(rng, depth):
    n = rng.randint(1, 4)
    parts = []
    if rng.random() < 0.12:
        parts.append(rng.choice(_RX_MODIFIERS))
    for _ in range(n):
        r = rng.random()
        if r < 0.7 or depth >= 3:
            atom = _rx_atom(rng)
            if atom in _RX_ANCHORS or atom == b"\\K":
                parts.append(atom)
            else:
                q = rng.choice(_RX_QUANTS)
                if q == b"" and rng.random() < 0.03:
                    q = rng.choice(_RX_BIG_QUANTS)
                parts.append(atom + q)
        elif r < 0.82:
            inner = _rx_disjunction(rng, depth + 1)
            k = rng.random()
            if k < 0.5:
                g = b"(" + inner + b")"
            elif k < 0.7:
                g = b"(?:" + inner + b")"
            else:
                nm = "".join(rng.choice("abcXYZ019_")
                              for _ in range(rng.randint(1, 6))).encode()
                g = b"(?<" + nm + b">" + inner + b")"
            parts.append(g + rng.choice(_RX_QUANTS))
        else:
            op = rng.choice([b"(?=", b"(?!", b"(?<=", b"(?<!"])
            parts.append(op + _rx_look_body(rng) + b")")
    return b"".join(parts)


def _rx_pattern_decodable(data):
    """Whether every decode position holds ASCII or a complete lead
    sequence (the Odin parser's accept rule). Advances skip trailing
    continuation bytes like C++ to_next, so orphans after a consumed
    char never decode. C++ agrees with Odin on all accepted inputs;
    on rejected inputs C++ Pass-accepts (the inner
    read_codepoint_multibyte call drops the throwing policy) while
    Odin reports 'Invalid utf8 in regex'."""
    pos, n = 0, len(data)
    while pos < n:
        b = data[pos]
        if b & 0x80 == 0:
            pos += 1
            continue
        if b & 0xE0 == 0xC0:
            size = 2
        elif b & 0xF0 == 0xE0:
            size = 3
        elif b & 0xF8 == 0xF0:
            size = 4
        else:
            return False
        if pos + size > n:
            return False
        pos += 1
        while pos < n and data[pos] & 0xC0 == 0x80:
            pos += 1
    return True


def _rx_pattern(rng):
    r = rng.random()
    if r < 0.12:
        # Invalid pattern: fixed specimen, truncation, or mutation.
        # Truncations/mutations that break UTF-8 decodability are
        # retried: undecodable patterns are an Odin-stricter class
        # (C++ Pass-accepts them), pinned by seeds instead.
        for _ in range(10):
            k = rng.random()
            if k < 0.5:
                cand = rng.choice(_RX_INVALID)
            else:
                p = _rx_disjunction(rng, 0)
                if k < 0.75 and len(p) > 1:
                    cand = p[:rng.randint(1, len(p) - 1)]
                else:
                    p = bytearray(p)
                    if p and rng.random() < 0.7:
                        p[rng.randrange(len(p))] = rng.choice(
                            b"([{\\?*+|")
                    else:
                        pos = rng.randrange(len(p) + 1)
                        p[pos:pos] = bytes([rng.choice(b"([{\\?*+|")])
                    cand = bytes(p)
            if _rx_pattern_decodable(cand):
                return cand
        return rng.choice(_RX_INVALID)
    if r < 0.20:
        # Case-insensitivity focus: (?i)/(?I) over mixed-case literals.
        lit = b"".join(rng.choice([b"a", b"A", b"b", b"B", b"c", b"C",
                                   b"z", b"Z", b"0", b"e", b"E"])
                       for _ in range(rng.randint(1, 5)))
        mod = rng.choice([b"(?i)", b"(?i)", b"(?I)"])
        return mod + lit + rng.choice(_RX_QUANTS)
    if r < 0.26:
        # Boundary focus: anchors over word-ish soup.
        return rng.choice(_RX_ANCHORS) + _rx_sequence(rng, 1) + \
            rng.choice(_RX_ANCHORS + [b""])
    return _rx_disjunction(rng, 0)


def _rx_subject(rng, pattern=b""):
    alpha = bytearray(b"abfox019 \t.,_-")
    for b in pattern:
        if 32 <= b <= 126 and b not in b"\\()[]{}|+*?^$.":
            alpha.append(b)
    alpha += b"\xc3\xa9\xc3\xbc\xe4\xb8\xad"
    r = rng.random()
    n = rng.randint(0, 40)
    if r < 0.15:
        # Word soup for \b.
        words = []
        for _ in range(rng.randint(0, 5)):
            wlen = rng.randint(0, 8)
            words.append(bytes(rng.choice(b"abcXYZ019_")
                               for _ in range(wlen)))
        sep = rng.choice([b" ", b"  ", b", ", b".", b"-", b"\n", b""])
        return sep.join(words)[:40]
    if r < 0.30:
        # Multiline: 1-4 lines joined by \n.
        lines = []
        for _ in range(rng.randint(1, 4)):
            llen = rng.randint(0, 12)
            lines.append(bytes(rng.choice(alpha) for _ in range(llen)))
        return b"\n".join(lines)[:40]
    if r < 0.38 and pattern:
        # Derived from the pattern's own literals.
        lits = bytes(b for b in pattern
                     if 32 <= b <= 126 and b not in b"\\()[]{}|+*?^$.")
        if lits:
            base = bytes(rng.choice(lits) for _ in
                         range(rng.randint(0, 12)))
            return _mutate(rng, base, alphabet=bytes(alpha),
                           n_edits=2)[:40]
    if r < 0.46:
        # Mixed case for (?i).
        words = []
        for _ in range(rng.randint(0, 4)):
            w = "".join(rng.choice("aAbBcCeEzZ019")
                        for _ in range(rng.randint(0, 8))).encode()
            words.append(w)
        return b" ".join(words)[:40]
    out = bytes(rng.choice(alpha) for _ in range(n))
    if rng.random() < 0.10:
        out += rng.choice(_BAD_UTF8)
    if rng.random() < 0.08 and len(out) < 40:
        pos = rng.randint(0, len(out))
        out = out[:pos] + b"\x00" + out[pos:]
    return out[:40]


# Focused census slices. (1) The tolower-wrap bug: (?i) patterns with
# ranges-bearing classes or non-ASCII literals over subjects holding
# lone high bytes (which Pass-decode to negative runes; Odin wraps
# them to Latin-1, C++ passes the huge value through). (2) Valid
# non-ASCII (?i): case pairs the libc-vs-table deviation could split.
# (3) Valid non-ASCII ctype: \w \d \b over letters/digits outside
# ASCII (the documented iswalnum/iswdigit-vs-tables gap).
_RX_WRAP_PATS = [b"(?i)x[a\\w]", b"(?i)x[a\\d]", b"(?i)x[0\\W]",
                 b"(?i)x[A\\S]", b"(?i)x[a\\W]",
                 "(?i)x[À-Þ]".encode(), "(?i)x[ß-ÿ]".encode(),
                 "(?i)x[¼-¾]".encode(), "(?i)x[Þ-þ]".encode(),
                 "(?i)x[±-»]".encode(), "(?i)x[µ-ÿ]".encode(),
                 "(?i)x¼".encode(), "(?i)xß".encode(),
                 "(?i)xé".encode(), "(?i)xþ".encode(),
                 "(?i)xÿ".encode(), "(?i)[ß]".encode(),
                 "(?i)(?=¼).".encode(), "(?i)(?<=¼)x".encode(),
                 "(?i)x(?=ß).".encode()]
_RX_WRAP_INFIX = [bytes([b]) for b in
                  (0x80, 0x9C, 0xA9, 0xB2, 0xB3, 0xB9, 0xBC, 0xBE,
                   0xC0, 0xDE, 0xDF, 0xE0, 0xFE, 0xFF)]
_RX_CI_WORDS = ["ß".encode(), "ẞ".encode(), "ss".encode(), "SS".encode(),
                "İ".encode(), "i".encode(), "I".encode(),
                "Σ".encode(), "σ".encode(), "ς".encode(),
                "ſ".encode(), "S".encode(), "s".encode(),
                "é".encode(), "É".encode(), "ü".encode(),
                "Ω".encode(), "ω".encode(), "д".encode(), "Д".encode()]
_RX_NW_WORDS = ["¼".encode(), "¹".encode(), "²".encode(), "⅐".encode(),
                "é".encode(), "ß".encode(), "中".encode(), "д".encode(),
                "Ω".encode(), "ﬁ".encode(), "ő".encode(), "a".encode(),
                "0".encode(), "_".encode(), " ".encode()]


def _rx_focused(rng):
    """Return a (pattern, subject-core) census pair, or None."""
    r = rng.random()
    if r < 0.045:
        pat = rng.choice(_RX_WRAP_PATS)
        infix = rng.choice(_RX_WRAP_INFIX)
        if pat.startswith(b"(?i)(?<="):
            core = infix + b"x"
        elif pat.startswith(b"(?i)(?="):
            core = infix
        elif pat == "(?i)[ß]".encode():
            core = infix
        else:
            core = b"x" + infix
        return pat, core
    if r < 0.065:
        # Valid-Unicode (?i): literal/case pair both sides of a fold.
        a = rng.choice(_RX_CI_WORDS)
        b = rng.choice(_RX_CI_WORDS)
        return b"(?i)" + a, b
    if r < 0.085:
        # Valid-Unicode ctype: classes over non-ASCII words/digits.
        cls = rng.choice([b"[\\w]", b"[\\d]", b"[\\w]+", b"\\b\\w+\\b",
                          b"[\\W]", b"[\\D]", b"\\b", b"\\w\\b\\w"])
        core = b"".join(rng.choice(_RX_NW_WORDS)
                        for _ in range(rng.randint(1, 4)))
        return cls, core
    return None


def _rflags(rng, backward_ok):
    r = rng.random()
    if r < 0.60:
        return 0
    if r < 0.75:
        return 2
    if r < 0.83:
        return 1
    if backward_ok and r < 0.91:
        return 4
    return rng.choice([3, 5, 6, 7, 12 if backward_ok else 3])


def gen_regex(rng, count):
    vecs = []
    for _ in range(count):
        r = rng.random()
        if r < 0.15:
            op = "compile"
        elif r < 0.40:
            op = "match"
        elif r < 0.45:
            op = "matchs"
        elif r < 0.65:
            op = "search"
        elif r < 0.70:
            op = "searchs"
        elif r < 0.80:
            op = "bsearch"
        elif r < 0.88:
            op = "iter"
        elif r < 0.92:
            op = "biter"
        elif r < 0.95:
            op = "named"
        elif r < 0.97:
            op = "flags"
        else:
            op = "empty"
        if op == "flags":
            vecs.append("flags\t%d\t%d\t%d\t%d" %
                        (rng.randint(0, 1), rng.randint(0, 1),
                         rng.randint(0, 1), rng.randint(0, 1)))
            continue
        pat = _rx_pattern(rng)
        backward = op in ("bsearch", "biter")
        cf = _rflags(rng, backward)
        foc = None
        if op in ("match", "matchs", "search", "searchs", "bsearch",
                  "iter", "biter"):
            foc = _rx_focused(rng)
        if op == "compile":
            vecs.append("compile\t%s\t%d" % (esc(pat), cf))
        elif op in ("match", "matchs"):
            if foc is not None:
                pat, subj = foc
            else:
                subj = _rx_subject(rng, pat)
            vecs.append("%s\t%s\t%d\t%s" % (op, esc(pat), cf, esc(subj)))
        elif op == "named":
            nm = "".join(rng.choice("abcXYZ019_")
                         for _ in range(rng.randint(0, 6)))
            vecs.append("named\t%s\t%d\t%s" % (esc(pat), cf, nm))
        elif op == "empty":
            vecs.append("empty\t%s\t%d" % (esc(pat), cf))
        else:
            if foc is not None:
                pat, core = foc
                pre = bytes(rng.choice(b"ab019 _,.")
                            for _ in range(rng.randint(0, 4)))
                post = bytes(rng.choice(b"ab019 _,.")
                             for _ in range(rng.randint(0, 4)))
                subj = pre + core + post
                lo = len(pre)
                hi = len(pre) + len(core)
                b = rng.choice([0, lo, rng.randint(0, len(subj))])
                e = rng.choice([len(subj), hi,
                                rng.randint(0, len(subj))])
            else:
                subj = _rx_subject(rng, pat)
                b = rng.randint(0, len(subj))
                e = rng.randint(0, len(subj))
            if rng.random() < 0.7 and b > e:
                b, e = e, b
            xf = rng.choice([0, 0, 0, rng.randint(0, 63)])
            vecs.append("%s\t%s\t%d\t%d\t%d\t%d\t%s" %
                        (op, esc(pat), cf, b, e, xf, esc(subj)))
    return vecs


_RX_CTYPE_CPS = [0, 1, 9, 10, 13, 32, 48, 57, 65, 90, 95, 97, 122,
                 127, 128, 160, 168, 170, 178, 179, 185, 188, 233,
                 937, 945, 1080, 12288, 12354, 19968, 1048, 1632,
                 1776, 2534, 8304, 8544, 65296, 0x10FFFF, 0x110000,
                 0x1FFFFF, 0x7FFFFFFF]


def gen_regex_vm(rng, count):
    vecs = []
    for _ in range(count):
        r = rng.random()
        if r < 0.25:
            pat = _rx_pattern(rng)
            vecs.append("compile\t%s\t%d" %
                        (esc(pat), rng.choice([0, 0, 1, 2, 3, 4, 5,
                                                6, 7, 8, 12, 15])))
        elif r < 0.85:
            pat = _rx_pattern(rng)
            backward = rng.random() < 0.3
            mode = (2 if backward else 1) | \
                (4 if rng.random() < 0.6 else 0) | \
                (8 if rng.random() < 0.25 else 0) | \
                (16 if rng.random() < 0.25 else 0)
            cf = _rflags(rng, backward)
            foc = _rx_focused(rng)
            if foc is not None:
                pat, core = foc
                pre = bytes(rng.choice(b"ab019 _,.")
                            for _ in range(rng.randint(0, 4)))
                post = bytes(rng.choice(b"ab019 _,.")
                             for _ in range(rng.randint(0, 4)))
                subj = pre + core + post
            else:
                subj = _rx_subject(rng, pat)
            # Nested windows (search inside subject, like every real
            # caller): a search outside the subject is C++ UB (the
            # boundary assertions read pos-1/pos) and panics the Odin
            # port, so that class is excluded (see results.log).
            # Windows may still split characters; the harness clamps.
            sb = rng.randint(0, len(subj))
            se = rng.randint(sb, len(subj))
            b = rng.randint(sb, se)
            e = rng.randint(b, se)
            if rng.random() < 0.1:
                b, e = e, b  # harness raises end to begin
            xf = rng.choice([0, 0, rng.randint(0, 63)])
            vecs.append("exec\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%s" %
                        (esc(pat), cf, mode, b, e, sb, se, xf, esc(subj)))
        else:
            mask = rng.choice([0, 1, 2, 4, 8, 16, 32, 64, 128, 255,
                               rng.randint(0, 255), rng.randint(0, 255)])
            k = rng.random()
            if k < 0.55:
                cp = rng.randint(0, 127)
            elif k < 0.85:
                cp = rng.choice(_RX_CTYPE_CPS)
            else:
                cp = rng.randint(0, 0x2FFFF)
            vecs.append("ctype\t%d\t%d" % (mask, cp))
    return vecs


# ---------------------------------------------------------------- faces

_FACE_NAMED = ["default", "black", "red", "green", "yellow", "blue",
               "magenta", "cyan", "white", "bright-black",
               "bright-red", "bright-green", "bright-yellow",
               "bright-blue", "bright-magenta", "bright-cyan",
               "bright-white"]
_FACE_ATTRS = "ucUrbBdisfgaF"


def _rface_color(rng, valid=True):
    r = rng.random()
    if r < 0.5:
        return rng.choice(_FACE_NAMED)
    if r < 0.75:
        return "rgb:%02x%02x%02x" % (rng.randint(0, 255),
                                     rng.randint(0, 255),
                                     rng.randint(0, 255))
    a = rng.randint(17, 255) if valid else rng.randint(0, 255)
    if not valid and rng.random() < 0.3:
        # Malformed hex.
        return "rgba:" + "".join(rng.choice("0123456789abcdefXYZ")
                                 for _ in range(rng.choice([6, 7, 8])))
    return "rgba:%02x%02x%02x%02x" % (rng.randint(0, 255),
                                      rng.randint(0, 255),
                                      rng.randint(0, 255), a)


def _rface_attrs(rng):
    n = rng.randint(0, 5)
    return "".join(rng.sample(_FACE_ATTRS, min(n, len(_FACE_ATTRS))))


def _rface(rng):
    return "%s|%s|%s|%s" % (_rface_color(rng), _rface_color(rng),
                             _rface_color(rng), _rface_attrs(rng))


def _rface_desc(rng):
    """A face description with no ',' or '+' after '@' (those are C++
    out-of-bounds reads; the Odin port reports Invalid_Description)."""
    r = rng.random()
    if r < 0.55:
        fg = rng.choice([_rface_color(rng), "", "red", "Default"])
        desc = fg
        if rng.random() < 0.5:
            desc += "," + rng.choice([_rface_color(rng), "", "blue"])
            if rng.random() < 0.4:
                desc += "," + rng.choice([_rface_color(rng), "green"])
        if rng.random() < 0.35:
            attrs = _rface_attrs(rng)
            if rng.random() < 0.2:
                attrs += rng.choice("xyz?!q")
            desc += "+" + attrs
        if rng.random() < 0.3:
            desc += "@" + rng.choice(["Base", "Default", "Information",
                                      "X", "", "red"])
        return desc.encode()
    if r < 0.8:
        # Mutation of a structured description.
        data = _mutate(rng, _rface_desc(rng),
                       alphabet=b"rgb:,+@wYUHu", n_edits=2)
    else:
        # ASCII soup (controls included, TAB/newline escaped by esc):
        # bytes >= 0x80 take different word-class paths in C++
        # (is_word false) and Odin (unicode tables), pinned by seeds.
        data = bytes(rng.randint(0, 0x7F) for _ in range(rng.randint(0, 20)))
    at = data.find(b"@")
    if at >= 0:
        data = data[:at + 1] + bytes(b for b in data[at + 1:]
                                     if b not in b",+")
    return data


def _face_desc_ok(desc):
    at = desc.find(b"@")
    if at >= 0 and any(b in b",+" for b in desc[at + 1:]):
        return False
    return True


def _rface_name(rng):
    # ASCII only (see _rface_desc): high bytes diverge in word class.
    r = rng.random()
    if r < 0.5:
        return "".join(rng.choice("abcXYZ019_")
                       for _ in range(rng.randint(1, 8))).encode()
    if r < 0.6:
        return rng.choice(["Default", "Information", "red",
                           "NewFace"]).encode()
    if r < 0.7:
        return b""
    return bytes(rng.randint(0, 0x7F) for _ in range(rng.randint(0, 10)))


def gen_faces(rng, count):
    vecs = []
    for _ in range(count):
        r = rng.random()
        if r < 0.20:
            vecs.append("merge\t%s\t%s" % (esc(_rface(rng).encode()),
                                             esc(_rface(rng).encode())))
        elif r < 0.30:
            vecs.append("tostring\t" + esc(_rface(rng).encode()))
        elif r < 0.38:
            vecs.append("attrstr\t" + _rface_attrs(rng))
        elif r < 0.63:
            d = _rface_desc(rng)
            assert _face_desc_ok(d), d
            vecs.append("parse\t" + esc(d))
        elif r < 0.75:
            d = _rface_desc(rng)
            assert _face_desc_ok(d), d
            vecs.append("lookup\t" + esc(d))
        elif r < 0.85:
            d = _rface_desc(rng)
            assert _face_desc_ok(d), d
            vecs.append("add\t%s\t%s\t%d" % (esc(_rface_name(rng)),
                                                esc(d), rng.randint(0, 1)))
        elif r < 0.90:
            ds = [_rface_desc(rng) for _ in range(3)]
            assert all(map(_face_desc_ok, ds))
            vecs.append("chain\t%s\t%s\t%d\t%s\t%s\t%d\t%s" %
                        (esc(_rface_name(rng)), esc(ds[0]),
                         rng.randint(0, 1), esc(_rface_name(rng)),
                         esc(ds[1]), rng.randint(0, 1), esc(ds[2])))
        elif r < 0.95:
            ds = [_rface_desc(rng) for _ in range(2)]
            assert all(map(_face_desc_ok, ds))
            vecs.append("flatten\t%s\t%s\t%s\t%s" %
                        (esc(_rface_name(rng)), esc(ds[0]),
                         esc(_rface_name(rng)), esc(ds[1])))
        else:
            ds = [_rface_desc(rng) for _ in range(2)]
            assert all(map(_face_desc_ok, ds))
            vecs.append("child\t%s\t%s\t%s" % (esc(_rface_name(rng)),
                                                  esc(ds[0]), esc(ds[1])))
    return vecs


# ---------------------------------------------------------------- keymap_manager

_KEY_MODS = [0, 1, 2, 3, 4, 5, 6, 7, -1, -2, 2047, 4095,
             0x7FFFFFFF, -0x80000000]
_KEY_CPS = [0, 97, 98, 65, 48, 32, 233, 0xD800, 0xDFFF, 0xE000,
            0x10FFFF, 0x110000, 0x1FFFFF, 0x7FFFFFFF]
_KEYMODES = list(range(0, 11))


def _rkey(rng):
    if rng.random() < 0.6:
        mod = rng.choice(_KEY_MODS[:8])
    elif rng.random() < 0.7:
        mod = rng.randint(0, 2047)
    else:
        mod = rng.choice(_KEY_MODS)
    if rng.random() < 0.6:
        cp = rng.choice(_KEY_CPS[:6])
    elif rng.random() < 0.7:
        cp = rng.randint(0, 0x2FFFF)
    else:
        cp = rng.choice(_KEY_CPS)
    return "%d:%d" % (mod, cp)


def _rkeys(rng, lo=0, hi=4):
    return ",".join(_rkey(rng) for _ in range(rng.randint(lo, hi)))


def _rkeymode_name(rng):
    r = rng.random()
    if r < 0.4:
        return "".join(rng.choice("abcdefxyz")
                       for _ in range(rng.randint(1, 8))).encode()
    if r < 0.55:
        return rng.choice(["normal", "insert", "prompt", "menu",
                           "goto", "view", "user", "object",
                           "combine"]).encode()
    if r < 0.65:
        return b""
    if r < 0.85:
        return rbytes(rng, 0, 10)
    return rng.choice(_UTF8_SAMPLES)


def gen_keymap_manager(rng, count):
    vecs = []
    for _ in range(count):
        r = rng.random()
        if r < 0.25:
            vecs.append("mapget\t%s\t%d\t%s\t%s\t%d\t%s\t%d" %
                        (_rkey(rng), rng.choice(_KEYMODES),
                         _rkeys(rng), esc(rbytes(rng, 0, 16)),
                         rng.randint(0, 1), _rkey(rng),
                         rng.choice(_KEYMODES)))
        elif r < 0.40:
            vecs.append("unmapget\t%s\t%d\t%s\t%s\t%d\t%s\t%d" %
                        (_rkey(rng), rng.choice(_KEYMODES),
                         _rkeys(rng), esc(rbytes(rng, 0, 16)),
                         rng.randint(0, 1), _rkey(rng),
                         rng.choice(_KEYMODES)))
        elif r < 0.52:
            vecs.append("unmapall\t%d\t%s\t%d\t%s\t%s\t%d\t%s\t%d\t%s\t%s\t%d\t%d" %
                        (rng.choice(_KEYMODES), _rkey(rng),
                         rng.choice(_KEYMODES), _rkeys(rng),
                         esc(rbytes(rng, 0, 12)), rng.randint(0, 1),
                         _rkey(rng), rng.choice(_KEYMODES),
                         _rkeys(rng), esc(rbytes(rng, 0, 12)),
                         rng.randint(0, 1), rng.choice(_KEYMODES)))
        elif r < 0.72:
            n = rng.randint(0, 4)
            parts = ["mapped", str(rng.choice(_KEYMODES)), str(n)]
            for _ in range(n):
                parts += [_rkey(rng), str(rng.choice(_KEYMODES)),
                          _rkeys(rng), esc(rbytes(rng, 0, 12)),
                          str(rng.randint(0, 1))]
            vecs.append("\t".join(parts))
        elif r < 0.87:
            n = rng.randint(0, 4)
            names = [esc(_rkeymode_name(rng)) for _ in range(n)]
            # Sometimes repeat a name to hit Already_Defined.
            if n >= 2 and rng.random() < 0.3:
                names[-1] = names[0]
            vecs.append("\t".join(["usermode", str(n)] + names))
        else:
            ck = "-" if rng.random() < 0.4 else _rkeys(rng)
            vecs.append("parent\t%s\t%d\t%s\t%s\t%s\t%s\t%d" %
                        (_rkey(rng), rng.choice(_KEYMODES),
                         _rkeys(rng), esc(rbytes(rng, 0, 12)), ck,
                         esc(rbytes(rng, 0, 12)), rng.randint(0, 1)))
    return vecs


# ---------------------------------------------------------------- parameters_parser

_PP_SWITCH_NAMES = [b"a", b"foo", b"bar", b"long-name", b"x", b"",
                    b"switch", b"Foo", b"0"]


def _rpp_switches(rng, ascii_only=False):
    n = rng.randint(0, 3)
    out = []
    for _ in range(n):
        r = rng.random()
        if r < 0.6:
            nm = rng.choice(_PP_SWITCH_NAMES)
        elif ascii_only or r < 0.75:
            nm = rword(rng).encode()
        elif r < 0.9:
            nm = rbytes(rng, 0, 8)
        else:
            nm = rng.choice(_UTF8_SAMPLES)
        takes = rng.randint(0, 1)
        if ascii_only:
            desc = rword(rng).encode()
            if rng.random() < 0.5:
                desc += b" " + rword(rng).encode()
        else:
            desc = rbytes(rng, 0, 16)
        out += [esc(nm), str(takes), esc(desc)]
    return [str(n)] + out


def _rpp_params(rng, known):
    n = rng.randint(0, 6)
    out = []
    for _ in range(n):
        r = rng.random()
        if r < 0.30 and known:
            out.append(b"-" + rng.choice(known))
        elif r < 0.45:
            out.append(b"-" + rbytes(rng, 0, 6))
        elif r < 0.55:
            out.append(b"--")
        elif r < 0.62:
            out.append(b"-")
        elif r < 0.80:
            out.append(rbytes(rng, 0, 12))
        else:
            out.append(rng.choice([b"pos", b"value", b"x", b""]))
    return [str(n)] + [esc(p) for p in out]


def gen_parameters_parser(rng, count):
    vecs = []
    for _ in range(count):
        r = rng.random()
        if r < 0.90:
            op = "parse" if rng.random() < 0.78 else "parseie"
            flags = rng.randint(0, 7)
            lo = rng.randint(0, 2)
            hi = rng.choice([-1, -1, 0, 1, 2, 3, 5])
            sw = _rpp_switches(rng)
            # Recover the known names for param generation.
            known = []
            for i in range(int(sw[0])):
                # Names were escaped; params need raw bytes + dash.
                # Re-derive: the escape is injective on our inputs, so
                # unescape here.
                e = sw[1 + 3 * i]
                raw = bytearray()
                j = 0
                while j < len(e):
                    if e[j:j + 2] == "\\x" and j + 3 < len(e) + 1:
                        raw.append(int(e[j + 2:j + 4], 16))
                        j += 4
                    else:
                        raw.append(ord(e[j]))
                        j += 1
                known.append(bytes(raw))
            params = _rpp_params(rng, known)
            vecs.append("\t".join([op, str(flags), str(lo), str(hi)] +
                                  sw + params))
        else:
            # gendoc over ASCII only: alignment uses display widths
            # (wcwidth vs unicode tables differ on non-ASCII).
            vecs.append("\t".join(["gendoc"] + _rpp_switches(
                rng, ascii_only=True)))
    return vecs


# ---------------------------------------------------------------- normalize

def _norm_json_cc(line):
    """Map a C++ json-harness output line onto the expected Odin line."""
    if line == "NULL":
        return "ERR Unexpected_End"
    if line.startswith("ERR "):
        msg = line[4:]
        table = {
            "maximum parsing depth reached": "ERR Max_Depth",
            "expected :": "ERR Expected_Colon",
            "unable to parse array, expected ',' or ']'":
                "ERR Expected_Comma_Or_Close",
            "unable to parse object, expected ',' or '}'":
                "ERR Expected_Comma_Or_Close",
            "unable to parse json": "ERR Unexpected_Char",
            "unable to parse array": "ERR Unexpected_End",
            "unable to parse object": "ERR Unexpected_End",
            "bad_value_cast": "ERR Non_String_Key",
        }
        if msg in table:
            return table[msg]
        if msg.endswith(" is not a number"):
            return "ERR Bad_Number"
        return line  # unknown: surface as mismatch for manual review
    return line


def _norm_format_cc(line):
    """Map a C++ format-harness output line onto the Odin line."""
    if line.startswith("ERR "):
        msg = line[4:]
        if msg == "format string error, unclosed '{'":
            return "ERR Unclosed_Brace"
        if msg == "format string parameter index too big":
            return "ERR Param_Index_Too_Big"
        if msg == "buffer is too small":
            return "ERR Buffer_Too_Small"
        if msg.endswith(" is not a number"):
            return "ERR Invalid_Number"
        return line  # unknown: surface as mismatch for manual review
    return line


def _norm_faces_cc(line):
    """Map a C++ faces-harness ERR line onto the Odin error name."""
    if line.startswith("ERR "):
        msg = line[4:]
        if msg.startswith("invalid face description"):
            return "ERR Invalid_Description"
        if msg.startswith("no such face attribute:"):
            return "ERR Unknown_Attribute"
        if msg.startswith("unable to parse color:") or \
           msg.startswith("invalid digit") or \
           msg == "Colors alpha must be > 16":
            return "ERR Invalid_Color"
        if msg.startswith("face '") and msg.endswith("' already defined"):
            return "ERR Already_Defined"
        if msg.startswith("invalid face name:"):
            return "ERR Invalid_Name"
        if msg == "face cycle detected":
            return "ERR Face_Cycle"
        return line  # unknown: surface as mismatch for manual review
    return line


def _norm_keymap_cc(line):
    """Map C++ keymap-harness ERR tokens (TAB-separated in usermode
    output) onto the Odin error names."""
    if "ERR " not in line:
        return line

    def norm_tok(tok):
        if tok.startswith("ERR "):
            msg = tok[4:]
            if msg.startswith("'") and \
               msg.endswith("' is already a regular mode"):
                return "ERR Regular_Mode"
            if msg.startswith("user mode '") and \
               msg.endswith("' already defined"):
                return "ERR Already_Defined"
            if msg.startswith("invalid mode name: '"):
                return "ERR Invalid_Name"
        return tok

    return "\t".join(norm_tok(t) for t in line.split("\t"))


NORMALIZE = {
    "hash": (lambda s: s),
    "diff": (lambda s: s),
    "ranked_match": (lambda s: s),
    "json": _norm_json_cc,
    "format": _norm_format_cc,
    "ranges": (lambda s: s),
    "utf8": (lambda s: s),
    "regex": (lambda s: s),
    "regex_vm": (lambda s: s),
    "faces": _norm_faces_cc,
    "keymap_manager": _norm_keymap_cc,
    "parameters_parser": (lambda s: s),
}


def _f32_key(spelling):
    """Canonical key for a float rendering: the f32 bits it parses to,
    with all NaNs (any sign/payload/case) mapping to one key."""
    try:
        v = float(spelling)
    except ValueError:
        return ("text", spelling)
    b = struct.unpack("<I", struct.pack("<f", v))[0]
    if (b & 0x7F800000) == 0x7F800000 and (b & 0x7FFFFF) != 0:
        return ("nan", 0)
    return ("bits", b)


def _eq_default(in_line, c, o):
    return c == o


_FORMAT_IMPL_ERRS = {"ERR Param_Index_Too_Big", "ERR Invalid_Number",
                     "ERR Unclosed_Brace"}


def _eq_format(in_line, c, o):
    # Shortest-round-trip spellings are only specified up to round-trip:
    # to_chars and generic_ftoa differ in inf/nan styling and rare
    # last-digit ties, so float lines compare by parsed f32 bits.
    if in_line.startswith("float\t"):
        return _f32_key(c) == _f32_key(o)
    if c == o:
        return True
    if in_line.startswith("format_to\t"):
        # Either true error is accepted: the C++ throws mid-write, so a
        # buffer overflow can precede (and hide) a later placeholder
        # error, while the Odin port reports the placeholder error
        # first (sticky overflow flag). Both errors are facts about
        # the input; only their precedence differs.
        if (c == "ERR Buffer_Too_Small" and o in _FORMAT_IMPL_ERRS) or \
           (o == "ERR Buffer_Too_Small" and c in _FORMAT_IMPL_ERRS):
            return True
    return False


COMPARE = {
    "hash": _eq_default,
    "diff": _eq_default,
    "ranked_match": _eq_default,
    "json": _eq_default,
    "format": _eq_format,
    "ranges": _eq_default,
    "utf8": _eq_default,
    "regex": _eq_default,
    "regex_vm": _eq_default,
    "faces": _eq_default,
    "keymap_manager": _eq_default,
    "parameters_parser": _eq_default,
}


# ---------------------------------------------------------------- build & run

def build_module(module):
    os.makedirs(BINDIR, exist_ok=True)
    cc_bin = os.path.join(BINDIR, module + "_cc")
    cmd = [CXX] + CXX_FLAGS + [os.path.join(REPO, s)
                               for s in MODULES[module]["cc_srcs"]] + \
        ["-o", cc_bin]
    p = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True)
    if p.returncode != 0:
        return "C++ build failed:\n" + p.stderr
    odin_dir = os.path.join(ROOT, module)
    odin_bin = os.path.join(BINDIR, module + "_odin")
    cmd = ["odin", "build", odin_dir,
           "-collection:kaksrc=" + os.path.join(REPO, "odin"),
           "-out:" + odin_bin]
    p = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True)
    if p.returncode != 0:
        return "Odin build failed:\n" + p.stderr
    return None


def run_pair(module, lines, timeout=600):
    blob = ("\n".join(lines) + "\n").encode()
    outs = {}
    for side in ("cc", "odin"):
        exe = os.path.join(BINDIR, "%s_%s" % (module, side))
        try:
            p = subprocess.run([exe], input=blob, capture_output=True,
                               timeout=timeout)
        except subprocess.TimeoutExpired:
            return None, "%s side timed out" % side
        if p.returncode != 0:
            return None, "%s side exited %d: %s" % (
                side, p.returncode, p.stderr.decode()[:2000])
        # backslashreplace is injective (bytes -> str), so comparing the
        # decoded text is exactly as strong as comparing bytes, while
        # keeping mismatch reports printable. Raw >=0x80 bytes legitimately
        # appear in json output: to_json only escapes \\, \" and <=0x1F.
        text = p.stdout.decode("ascii", errors="backslashreplace")
        got = text.split("\n")
        if got and got[-1] == "":
            got.pop()
        outs[side] = got
    return outs, ""


def check_module(module, lines, max_mismatch):
    norm = NORMALIZE[module]
    eq = COMPARE[module]
    outs, err = run_pair(module, lines)
    if outs is None:
        return None, err
    cc, od = outs["cc"], outs["odin"]
    if len(cc) != len(lines) or len(od) != len(lines):
        return None, "line count: in=%d cc=%d odin=%d" % (
            len(lines), len(cc), len(od))

    def is_bad(in_line, c, o):
        if c.startswith("HARNESS-ERROR") or o.startswith("HARNESS-ERROR"):
            return True
        return not eq(in_line, norm(c), o)

    def is_harness_err(c, o):
        return c.startswith("HARNESS-ERROR") or o.startswith("HARNESS-ERROR")

    mism = []
    harness_errs = 0
    for i, (in_line, c, o) in enumerate(zip(lines, cc, od)):
        if is_bad(in_line, c, o):
            if is_harness_err(c, o):
                harness_errs += 1
            if len(mism) < max_mismatch:
                mism.append((i, in_line, c, o))
    total_bad = sum(1 for t in zip(lines, cc, od) if is_bad(*t))
    return {"total": len(lines), "bad": total_bad,
            "shown": mism, "harness_errs": harness_errs}, ""


def load_seeds(module):
    path = os.path.join(ROOT, module, "vectors.txt")
    # UTF-8: regex seeds embed raw non-ASCII characters (the harnesses
    # pass raw >=0x80 bytes through; ASCII seeds are unaffected).
    with open(path, "r", encoding="utf-8") as f:
        return [ln.rstrip("\n") for ln in f if ln.strip() != ""]


def smoke_odin_run(modules):
    """Verify `odin run` on each main.odin prints what the built Odin
    binary prints for a couple of seed vectors."""
    for module in modules:
        seeds = load_seeds(module)[:2]
        blob = ("\n".join(seeds) + "\n").encode()
        ref = subprocess.run([os.path.join(BINDIR, module + "_odin")],
                             input=blob, capture_output=True)
        got = subprocess.run(
            ["odin", "run", os.path.join(ROOT, module),
             "-collection:kaksrc=" + os.path.join(REPO, "odin")],
            input=blob, capture_output=True, cwd=REPO, timeout=300)
        if got.returncode != 0:
            return "odin run %s failed: %s" % (
                module, got.stderr.decode()[:1000])
        if got.stdout != ref.stdout:
            return "odin run %s differs from built binary" % module
        print("  odin-run smoke %s: OK" % module, flush=True)
    return None


def _stable_offset(name):
    """Stable per-module stream offset. (Python's hash() is salted per
    process, so it must not feed the seed: identical --seed runs would
    generate different streams.)"""
    h = 0
    for ch in name:
        h = (h * 31 + ord(ch)) % 1000003
    return h


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--modules", default=",".join(MODULES),
                    help="comma-separated subset to run")
    ap.add_argument("--count", type=int, default=20000,
                    help="generated vectors per module (plus seeds)")
    ap.add_argument("--seed", type=int, default=20261003)
    ap.add_argument("--max-mismatch", type=int, default=10)
    ap.add_argument("--no-build", action="store_true")
    ap.add_argument("--smoke-odin-run", action="store_true")
    ap.add_argument("--results", default=None,
                    help="append the summary report to this file")
    args = ap.parse_args()

    modules = [m.strip() for m in args.modules.split(",")]
    for m in modules:
        if m not in MODULES:
            print("unknown module: %s" % m, file=sys.stderr)
            return 2

    report = []
    if not args.no_build:
        for m in modules:
            print("building %s ..." % m, flush=True)
            err = build_module(m)
            if err:
                print(err, file=sys.stderr)
                return 2
        print("builds OK", flush=True)

    if args.smoke_odin_run:
        err = smoke_odin_run(modules)
        if err:
            print(err, file=sys.stderr)
            return 2

    failed = False
    for m in modules:
        rng = random.Random(args.seed + _stable_offset(m))
        lines = load_seeds(m)
        n_seed = len(lines)
        lines += globals()[MODULES[m]["gen"]](rng, args.count)
        print("fuzzing %s: %d vectors (%d seeds) ..." % (m, len(lines),
                                                              n_seed),
              flush=True)
        res, err = check_module(m, lines, args.max_mismatch)
        if res is None:
            print("  ERROR: %s" % err)
            report.append("%s: ERROR %s" % (m, err))
            failed = True
            continue
        status = "OK" if res["bad"] == 0 else "MISMATCH"
        print("  %s: %d/%d agree" % (status, res["total"] - res["bad"],
                                    res["total"]),
              flush=True)
        report.append("%s: %d vectors (%d seeds), %d mismatches" %
                      (m, res["total"], n_seed, res["bad"]))
        if res["bad"]:
            failed = True
            for i, in_line, c, o in res["shown"]:
                print("  --- vector #%d" % i)
                print("  in:   %s" % in_line)
                print("  c++:  %s" % c)
                print("  odin: %s" % o)
                report.append("  vector #%d in=%r c++=%r odin=%r" %
                              (i, in_line, c, o))
            if res["bad"] > len(res["shown"]):
                print("  ... and %d more" % (res["bad"] - len(res["shown"])))

    print("RESULT: " + ("FAIL" if failed else "PASS"), flush=True)
    if args.results:
        with open(args.results, "a", encoding="utf-8") as f:
            f.write("fuzz.py seed=%d count=%d modules=%s\n" %
                    (args.seed, args.count, ",".join(modules)))
            for ln in report:
                f.write(ln + "\n")
            f.write("RESULT: %s\n" % ("FAIL" if failed else "PASS"))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())