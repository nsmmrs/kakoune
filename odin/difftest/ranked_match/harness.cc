// C++ side of the ranked_match differential harness. Same line protocol
// as the hash harness (see ../hash/harness.cc for escaping rules).
//
// The locale matters: the C++ matcher uses libc wide-character classes
// (iswalnum/iswlower/...) while the Odin port uses core:unicode tables.
//main() pins LC_ALL to en_US.utf8 (fallback C.utf8) and reports the
// effective LC_CTYPE on stderr so results.log can record it.
//
// Ops (RankedMatch exposes matches/ordering/used_letters publicly,
// so the oracle covers exactly that observable surface):
//   match <cand>\t<query>      -> 0|1
//   matchL <cand>\t<query>     -> 0|1 (UsedLetters pretest ctor)
//   cmp <query>\t<a>\t<b>      -> "NA" unless both match,
//                                  else "<a<b> <b<a>" as 0|1 0|1
//   letters <s>                 -> uint64 decimal (used_letters)
//   lowletters <u64>            -> uint64 decimal (to_lower mask)
//   echo <data>                 -> re-escaped input (decoder self-check)

#include "ranked_match.hh"

#include <clocale>
#include <cstdint>
#include <cstdio>
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

Kakoune::StringView view_of(const std::string& s)
{
    return {s.data(), s.data() + s.size()};
}

} // namespace

int main()
{
    using namespace Kakoune;
    if (not setlocale(LC_ALL, "en_US.utf8"))
        setlocale(LC_ALL, "C.utf8");
    fprintf(stderr, "difftest-locale: %s\n", setlocale(LC_CTYPE, nullptr));

    std::string line;
    while (std::getline(std::cin, line))
    {
        if (not line.empty() and line.back() == '\r')
            line.pop_back();
        auto fields = split_tabs(line);
        const std::string& op = fields[0];
        if (op == "match" and fields.size() == 3)
        {
            std::string c = unescape(fields[1]), q = unescape(fields[2]);
            RankedMatch m{view_of(c), view_of(q)};
            printf("%d\n", (int)(bool)m);
        }
        else if (op == "matchL" and fields.size() == 3)
        {
            std::string c = unescape(fields[1]), q = unescape(fields[2]);
            RankedMatch m{view_of(c), used_letters(view_of(c)),
                          view_of(q), used_letters(view_of(q))};
            printf("%d\n", (int)(bool)m);
        }
        else if (op == "cmp" and fields.size() == 4)
        {
            std::string q = unescape(fields[1]);
            std::string a = unescape(fields[2]), b = unescape(fields[3]);
            RankedMatch A{view_of(a), view_of(q)}, B{view_of(b), view_of(q)};
            if (not A or not B)
                printf("NA\n");
            else
                printf("%d %d\n", (int)(A < B), (int)(B < A));
        }
        else if (op == "letters" and fields.size() == 2)
        {
            std::string s = unescape(fields[1]);
            printf("%llu\n", (unsigned long long)used_letters(view_of(s)));
        }
        else if (op == "lowletters" and fields.size() == 2)
        {
            auto v = (UsedLetters)strtoull(fields[1].c_str(), nullptr, 10);
            printf("%llu\n", (unsigned long long)to_lower(v));
        }
        else if (op == "echo" and fields.size() == 2)
            printf("%s\n", escape(unescape(fields[1])).c_str());
        else
            printf("HARNESS-ERROR bad line\n");
    }
    return 0;
}
