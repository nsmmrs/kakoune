#!/usr/bin/env python3
"""C++-vs-Odin differential fuzz driver for merged wave-1 modules.

Builds a C++ harness binary (g++ from real src/ code) and an Odin
counterpart (`odin build` of main.odin; `odin run` on the same directory
produces identical output, verified by --smoke-odin-run) per module,
feeds seed vectors from vectors.txt plus generated random inputs, and
diffs the outputs line by line.

Usage:
  python3 fuzz.py [--modules hash,diff,ranked_match,json] [--count N]
                  [--seed S] [--max-mismatch K] [--no-build]
                  [--smoke-odin-run] [--results results.log]

Exit status: 0 when every compared line agrees, 1 on any mismatch,
2 on build/setup failure.
"""

import argparse
import os
import random
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


NORMALIZE = {
    "hash": (lambda s: s),
    "diff": (lambda s: s),
    "ranked_match": (lambda s: s),
    "json": _norm_json_cc,
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
    outs, err = run_pair(module, lines)
    if outs is None:
        return None, err
    cc, od = outs["cc"], outs["odin"]
    if len(cc) != len(lines) or len(od) != len(lines):
        return None, "line count: in=%d cc=%d odin=%d" % (
            len(lines), len(cc), len(od))
    mism = []
    harness_errs = 0
    for i, (in_line, c, o) in enumerate(zip(lines, cc, od)):
        if c.startswith("HARNESS-ERROR") or o.startswith("HARNESS-ERROR"):
            harness_errs += 1
            if len(mism) < max_mismatch:
                mism.append((i, in_line, c, o))
            continue
        if norm(c) != o:
            if len(mism) < max_mismatch:
                mism.append((i, in_line, c, o))
    total_bad = sum(1 for c, o in zip(cc, od)
                    if norm(c) != o or c.startswith("HARNESS-ERROR")
                    or o.startswith("HARNESS-ERROR"))
    return {"total": len(lines), "bad": total_bad,
            "shown": mism, "harness_errs": harness_errs}, ""


def load_seeds(module):
    path = os.path.join(ROOT, module, "vectors.txt")
    with open(path, "r", encoding="ascii") as f:
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
        rng = random.Random(args.seed + hash(m) % 1000003)
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