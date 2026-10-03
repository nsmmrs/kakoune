// C++ side of the ranges differential harness.
//
// Reads op lines on stdin, prints one result line per line on stdout.
// Byte strings use \xNN escapes for every byte outside printable ASCII
// (0x20..0x7E except backslash); TAB separates fields. Integer lists
// are comma-separated i64 in a single field. The Odin counterpart
// implements the same decoding.
//
// Ops (byte ops take escaped data unless noted):
//   split <data> <sep>          -> "<n>\t<p0>\t..." (pieces escaped;
//                                 n=0 prints just "0")
//   split_after <data> <sep>    -> same shape (separator kept in piece)
//   split_esc <data> <sep> <esc>-> same shape (escaper-aware)
//   reverse <data>              -> escaped reversed bytes
//   skip <data> <n>             -> escaped (n <= len(data); larger n is
//   drop <data> <n>                C++ UB, excluded from fuzzing)
//   filter <data> <pred>        -> escaped survivors
//   transform <data> <tr>       -> escaped (tr 0: b+1 mod 256, 1: 255-b)
//   enum <data>                 -> "i:byte,..." or EMPTY
//   find <data> <byte>          -> first index or -1
//   contains <data> <byte>      -> 0|1
//   all_of|any_of <data> <pred> -> 0|1
//   remove_if <data> <pred>     -> escaped survivors
//   unerase <data> <byte>       -> escaped (first match swapped out)
//   flatten [<p0> ...]          -> escaped concatenation (0+ parts)
//   concat <a> <b>              -> escaped a+b
//   accumulate <intlist> <init> <op> -> i64 (op 0: +, 1: *; values kept
//                                 small so no signed overflow occurs)
//   for_n_best <intlist> <count> <func> -> visit order, comma-separated,
//                                 or EMPTY (inputs distinct: heap order
//                                 and linear-max order agree there)
//   static_gather <intlist> <N> <exact> -> comma-separated [N] or ERR
//                                 (N is 1..4: the Odin port cannot
//                                 instantiate N=0, `0 ..< 0` is a
//                                 compile error in ranges.odin; empty
//                                 input with N>=1 dereferences end()
//                                 in the C++ (UB, segfaults) and is
//                                 excluded from fuzzing)
//   echo <data>                 -> re-escaped input (decoder self-check)
//
// preds: 0 = even byte, 1 = ASCII lowercase, 2 = high bit set.
// funcs: 0 = always true, 1 = even value, 2 = positive value.

#include "ranges.hh"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <iostream>
#include <string>
#include <vector>

namespace {

int hex_val(char c)
{
    if (c >= '0' and c <= '9')
        return c - '0';
    if (c >= 'a' and c <= 'f')
        return c - 'a' + 10;
    if (c >= 'A' and c <= 'F')
        return c - 'A' + 10;
    return -1;
}

std::string unescape(const std::string& s)
{
    std::string out;
    for (size_t i = 0; i < s.size();)
    {
        if (s[i] == '\\' and i + 3 < s.size() and s[i + 1] == 'x')
        {
            int hi = hex_val(s[i + 2]), lo = hex_val(s[i + 3]);
            if (hi >= 0 and lo >= 0)
            {
                out += (char)(hi * 16 + lo);
                i += 4;
                continue;
            }
        }
        out += s[i++];
    }
    return out;
}

std::string escape(const std::string& s)
{
    static const char* digits = "0123456789abcdef";
    std::string out;
    for (unsigned char c : s)
    {
        if (c >= 0x20 and c <= 0x7E and c != '\\')
            out += (char)c;
        else
        {
            out += "\\x";
            out += digits[c >> 4];
            out += digits[c & 15];
        }
    }
    return out;
}

std::vector<std::string> split_tabs(const std::string& line)
{
    std::vector<std::string> fields{""};
    for (char c : line)
    {
        if (c == '\t')
            fields.emplace_back();
        else
            fields.back() += c;
    }
    return fields;
}

std::vector<long long> parse_ints(const std::string& s)
{
    std::vector<long long> out;
    if (s.empty())
        return out;
    size_t i = 0;
    while (i <= s.size())
    {
        size_t j = s.find(',', i);
        if (j == std::string::npos)
            j = s.size();
        out.push_back(strtoll(s.substr(i, j - i).c_str(), nullptr, 10));
        i = j + 1;
    }
    return out;
}

std::string join_ints(const std::vector<long long>& v)
{
    if (v.empty())
        return "EMPTY";
    std::string out;
    for (size_t i = 0; i < v.size(); ++i)
    {
        if (i)
            out += ',';
        out += std::to_string(v[i]);
    }
    return out;
}

template<typename Range>
std::string gather_str(Range&& r)
{
    std::string out;
    for (char c : r)
        out += c;
    return out;
}

bool byte_pred(int id, char c)
{
    unsigned char b = (unsigned char)c;
    if (id == 0)
        return b % 2 == 0;
    if (id == 1)
        return b >= 'a' and b <= 'z';
    return b >= 0x80; // id == 2
}

struct GatherError
{
    explicit GatherError(size_t i) : index(i) {}
    size_t index;
};

} // namespace

int main()
{
    using namespace Kakoune;
    std::string line;
    while (std::getline(std::cin, line))
    {
        if (not line.empty() and line.back() == '\r')
            line.pop_back();
        auto fields = split_tabs(line);
        const std::string& op = fields[0];
        if (op == "split" and fields.size() == 3)
        {
            std::string data = unescape(fields[1]);
            char sep = (char)strtol(fields[2].c_str(), nullptr, 10);
            std::vector<std::string> pieces;
            for (auto p : data | split<std::string>(sep))
                pieces.push_back(p);
            printf("%zu", pieces.size());
            for (auto& p : pieces)
                printf("\t%s", escape(p).c_str());
            printf("\n");
        }
        else if (op == "split_after" and fields.size() == 3)
        {
            std::string data = unescape(fields[1]);
            char sep = (char)strtol(fields[2].c_str(), nullptr, 10);
            std::vector<std::string> pieces;
            for (auto p : data | split_after<std::string>(sep))
                pieces.push_back(p);
            printf("%zu", pieces.size());
            for (auto& p : pieces)
                printf("\t%s", escape(p).c_str());
            printf("\n");
        }
        else if (op == "split_esc" and fields.size() == 4)
        {
            std::string data = unescape(fields[1]);
            char sep = (char)strtol(fields[2].c_str(), nullptr, 10);
            char esc = (char)strtol(fields[3].c_str(), nullptr, 10);
            std::vector<std::string> pieces;
            for (auto p : data | split<std::string>(sep, esc))
                pieces.push_back(p);
            printf("%zu", pieces.size());
            for (auto& p : pieces)
                printf("\t%s", escape(p).c_str());
            printf("\n");
        }
        else if (op == "reverse" and fields.size() == 2)
        {
            std::string data = unescape(fields[1]);
            printf("%s\n", escape(gather_str(data | reverse())).c_str());
        }
        else if (op == "skip" and fields.size() == 3)
        {
            std::string data = unescape(fields[1]);
            size_t n = (size_t)strtoull(fields[2].c_str(), nullptr, 10);
            printf("%s\n", escape(gather_str(data | skip(n))).c_str());
        }
        else if (op == "drop" and fields.size() == 3)
        {
            std::string data = unescape(fields[1]);
            size_t n = (size_t)strtoull(fields[2].c_str(), nullptr, 10);
            printf("%s\n", escape(gather_str(data | drop(n))).c_str());
        }
        else if (op == "filter" and fields.size() == 3)
        {
            std::string data = unescape(fields[1]);
            int id = atoi(fields[2].c_str());
            auto pred = [id](char c) { return byte_pred(id, c); };
            printf("%s\n", escape(gather_str(data | filter(pred))).c_str());
        }
        else if (op == "transform" and fields.size() == 3)
        {
            std::string data = unescape(fields[1]);
            int id = atoi(fields[2].c_str());
            auto tr = [id](char c) -> char {
                unsigned char b = (unsigned char)c;
                return (char)(id == 0 ? (unsigned char)(b + 1) : (unsigned char)(255 - b));
            };
            printf("%s\n", escape(gather_str(data | transform(tr))).c_str());
        }
        else if (op == "enum" and fields.size() == 2)
        {
            std::string data = unescape(fields[1]);
            if (data.empty())
                printf("EMPTY\n");
            else
            {
                bool first = true;
                for (auto [i, c] : data | enumerate())
                {
                    if (not first)
                        printf(",");
                    first = false;
                    printf("%zu:%u", i, (unsigned)(unsigned char)c);
                }
                printf("\n");
            }
        }
        else if (op == "find" and fields.size() == 3)
        {
            std::string data = unescape(fields[1]);
            char v = (char)strtol(fields[2].c_str(), nullptr, 10);
            auto it = find(data, v);
            printf("%ld\n", it == data.end() ? -1L : (long)(it - data.begin()));
        }
        else if (op == "contains" and fields.size() == 3)
        {
            std::string data = unescape(fields[1]);
            char v = (char)strtol(fields[2].c_str(), nullptr, 10);
            printf("%d\n", contains(data, v) ? 1 : 0);
        }
        else if ((op == "all_of" or op == "any_of") and fields.size() == 3)
        {
            std::string data = unescape(fields[1]);
            int id = atoi(fields[2].c_str());
            auto pred = [id](char c) { return byte_pred(id, c); };
            bool r = op == "all_of" ? all_of(data, pred) : any_of(data, pred);
            printf("%d\n", r ? 1 : 0);
        }
        else if (op == "remove_if" and fields.size() == 3)
        {
            std::string data = unescape(fields[1]);
            int id = atoi(fields[2].c_str());
            auto pred = [id](char c) { return byte_pred(id, c); };
            data.erase(remove_if(data, pred), data.end());
            printf("%s\n", escape(data).c_str());
        }
        else if (op == "unerase" and fields.size() == 3)
        {
            std::string data = unescape(fields[1]);
            char v = (char)strtol(fields[2].c_str(), nullptr, 10);
            std::vector<char> vec(data.begin(), data.end());
            unordered_erase(vec, v);
            printf("%s\n", escape(std::string(vec.begin(), vec.end())).c_str());
        }
        else if (op == "flatten" and fields.size() >= 1)
        {
            std::vector<std::string> parts;
            for (size_t i = 1; i < fields.size(); ++i)
                parts.push_back(unescape(fields[i]));
            printf("%s\n", escape(gather_str(parts | flatten())).c_str());
        }
        else if (op == "concat" and fields.size() == 3)
        {
            std::string a = unescape(fields[1]);
            std::string b = unescape(fields[2]);
            printf("%s\n", escape(gather_str(concatenated(a, b))).c_str());
        }
        else if (op == "accumulate" and fields.size() == 4)
        {
            auto vec = parse_ints(fields[1]);
            long long init = strtoll(fields[2].c_str(), nullptr, 10);
            int id = atoi(fields[3].c_str());
            // init + 0 is a prvalue: passing the lvalue deduces Init
            // as long long&, which cannot bind the result.
            long long r;
            if (id == 0)
                r = accumulate(vec, init + 0,
                               [](long long a, long long b) { return a + b; });
            else
                r = accumulate(vec, init + 0,
                               [](long long a, long long b) { return a * b; });
            printf("%lld\n", r);
        }
        else if (op == "for_n_best" and fields.size() == 4)
        {
            auto vec = parse_ints(fields[1]);
            size_t count = (size_t)strtoull(fields[2].c_str(), nullptr, 10);
            int id = atoi(fields[3].c_str());
            std::vector<long long> visited;
            auto less = [](long long a, long long b) { return a < b; };
            auto func = [id, &visited](long long v) {
                visited.push_back(v);
                if (id == 0)
                    return true;
                if (id == 1)
                    return v % 2 == 0;
                return v > 0;
            };
            for_n_best(vec, count, less, func);
            printf("%s\n", join_ints(visited).c_str());
        }
        else if (op == "static_gather" and fields.size() == 4)
        {
            auto vec = parse_ints(fields[1]);
            int n = atoi(fields[2].c_str());
            bool exact = fields[3] != "0";
            try
            {
                std::vector<long long> out;
                // N and exact_size are template parameters: instantiate each.
                #define GATHER(N, EXACT) \
                    { auto arr = vec | static_gather<GatherError, N, EXACT>(); \
                      out.assign(arr.begin(), arr.end()); }
                if (exact and n == 1) { GATHER(1, true); }
                else if (exact and n == 2) { GATHER(2, true); }
                else if (exact and n == 3) { GATHER(3, true); }
                else if (exact and n == 4) { GATHER(4, true); }
                else if (not exact and n == 1) { GATHER(1, false); }
                else if (not exact and n == 2) { GATHER(2, false); }
                else if (not exact and n == 3) { GATHER(3, false); }
                else if (not exact and n == 4) { GATHER(4, false); }
                else { printf("HARNESS-ERROR bad line\n"); continue; }
                #undef GATHER
                printf("%s\n", join_ints(out).c_str());
            }
            catch (GatherError&)
            {
                printf("ERR\n");
            }
        }
        else if (op == "echo" and fields.size() == 2)
            printf("%s\n", escape(unescape(fields[1])).c_str());
        else
            printf("HARNESS-ERROR bad line\n");
    }
    return 0;
}
