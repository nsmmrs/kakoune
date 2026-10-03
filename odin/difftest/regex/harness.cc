// C++ side of the regex differential harness (high-level Regex API).
//
// Reads op lines on stdin, prints one result line per line on stdout.
// String args use \xNN escapes for every byte outside printable ASCII
// (0x20..0x7E except backslash); TAB separates fields. The Odin
// counterpart implements the same decoding.
//
// The locale matters: the C++ engine uses libc wide-character classes
// (iswalnum for \w/\b, iswdigit for \d, towlower for (?i)); main()
// pins LC_ALL to en_US.utf8 (fallback C.utf8) and reports the
// effective LC_CTYPE on stderr, like the ranked_match harness.
//
// Ops (cflags bits: 1=NoSubs 2=Optimize 4=Backward 8=NoForward;
// xflags bits mirror RegexExecFlags: 2=NotBeginOfLine 4=NotEndOfLine
// 8=NotBeginOfWord 16=NotEndOfWord 32=NotInitialNull):
//   compile <pattern> <cflags>
//     -> OK marks=<m> saves=<s> named=<n> [<name>=<idx> ...]
//     -> ERR <escaped-what>
//   match <pattern> <cflags> <subject>
//   matchs <pattern> <cflags> <subject>   (no captures)
//   search <pattern> <cflags> <begin> <end> <xflags> <subject>
//   searchs <pattern> <cflags> <begin> <end> <xflags> <subject>
//   bsearch <pattern> <cflags> <begin> <end> <xflags> <subject>
//   iter <pattern> <cflags> <begin> <end> <xflags> <subject>
//     -> N <k> [<match> ...] (TRUNC suffix past 500 matches)
//   biter <pattern> <cflags> <begin> <end> <xflags> <subject>
//   named <pattern> <cflags> <name>  -> <idx>
//   flags <bol> <eol> <bow> <eow>    -> <int>
//   empty <pattern> <cflags>         -> 0|1
//   echo <data>                      -> re-escaped input
//
// match/search/bsearch print YES <groups> or NO, where <groups> is the
// space-joined per-group span `begin:end` in byte offsets (`-` for an
// unmatched group). matchs/searchs print bare YES/NO. Any op that
// compiles prints ERR <escaped-what> when compilation fails.
//
// Harness rules (mirrored by the Odin side): forward exec ops strip
// NoForward from cflags (a NoForward program cannot run forward);
// backward ops add Backward; begin/end are clamped into [0, len] with
// end raised to begin when begin > end.

#include "regex.hh"

#include <clocale>
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

Kakoune::RegexCompileFlags cflags_of(int bits)
{
    using CF = Kakoune::RegexCompileFlags;
    CF f = CF::None;
    if (bits & 1)
        f |= CF::NoSubs;
    if (bits & 2)
        f |= CF::Optimize;
    if (bits & 4)
        f |= CF::Backward;
    if (bits & 8)
        f |= CF::NoForward;
    return f;
}

Kakoune::RegexExecFlags xflags_of(int bits)
{
    using XF = Kakoune::RegexExecFlags;
    XF f = XF::None;
    if (bits & 2)
        f |= XF::NotBeginOfLine;
    if (bits & 4)
        f |= XF::NotEndOfLine;
    if (bits & 8)
        f |= XF::NotBeginOfWord;
    if (bits & 16)
        f |= XF::NotEndOfWord;
    if (bits & 32)
        f |= XF::NotInitialNull;
    return f;
}

void print_caps(const Kakoune::MatchResults<const char*>& res, const char* base, bool comma)
{
    for (size_t i = 0; i < res.size(); ++i)
    {
        if (i > 0)
            putchar(comma ? ',' : ' ');
        auto m = res[i];
        if (not m.matched)
            printf("-");
        else
            printf("%td:%td", m.first - base, m.second - base);
    }
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
        try
        {
            if (op == "compile" and fields.size() == 3)
            {
                std::string pat = unescape(fields[1]);
                Regex re{StringView{pat.data(), pat.data() + pat.size()}, cflags_of(atoi(fields[2].c_str()))};
                printf("OK marks=%zu saves=%u named=%zu",
                       re.mark_count(), re.impl()->save_count,
                       re.impl()->named_captures.size());
                for (auto& nc : re.impl()->named_captures)
                    printf(" %s=%u", escape({nc.name.data(), (size_t)(int)nc.name.length()}).c_str(), nc.index);
                printf("\n");
            }
            else if ((op == "match" or op == "matchs") and fields.size() == 4)
            {
                std::string pat = unescape(fields[1]);
                int cf = atoi(fields[2].c_str()) & ~8;
                Regex re{StringView{pat.data(), pat.data() + pat.size()}, cflags_of(cf)};
                std::string subj = unescape(fields[3]);
                const char* b = subj.data();
                const char* e = b + subj.size();
                if (op == "matchs")
                    printf("%s\n", regex_match(b, e, re) ? "YES" : "NO");
                else
                {
                    MatchResults<const char*> res;
                    if (regex_match(b, e, res, re))
                    {
                        printf("YES");
                        if (res.size())
                            putchar(' ');
                        print_caps(res, b, false);
                        printf("\n");
                    }
                    else
                        printf("NO\n");
                }
            }
            else if ((op == "search" or op == "searchs" or op == "bsearch") and fields.size() == 7)
            {
                std::string pat = unescape(fields[1]);
                int cf = atoi(fields[2].c_str());
                if (op == "bsearch")
                    cf |= 4;
                else
                    cf &= ~8;
                Regex re{StringView{pat.data(), pat.data() + pat.size()}, cflags_of(cf)};
                std::string subj = unescape(fields[6]);
                const char* base = subj.data();
                long long len = (long long)subj.size();
                long long b = atoll(fields[3].c_str()), e = atoll(fields[4].c_str());
                if (b < 0)
                    b = 0;
                if (b > len)
                    b = len;
                if (e < b)
                    e = b;
                if (e > len)
                    e = len;
                auto flags = xflags_of(atoi(fields[5].c_str()));
                if (op == "searchs")
                    printf("%s\n", regex_search(base + b, base + e, base, base + len, re, flags) ? "YES" : "NO");
                else
                {
                    MatchResults<const char*> res;
                    bool found = op == "bsearch"
                        ? backward_regex_search(base + b, base + e, base, base + len, res, re, flags)
                        : regex_search(base + b, base + e, base, base + len, res, re, flags);
                    if (found)
                    {
                        printf("YES");
                        if (res.size())
                            putchar(' ');
                        print_caps(res, base, false);
                        printf("\n");
                    }
                    else
                        printf("NO\n");
                }
            }
            else if ((op == "iter" or op == "biter") and fields.size() == 7)
            {
                std::string pat = unescape(fields[1]);
                int cf = atoi(fields[2].c_str());
                if (op == "biter")
                    cf |= 4;
                else
                    cf &= ~8;
                Regex re{StringView{pat.data(), pat.data() + pat.size()}, cflags_of(cf)};
                std::string subj = unescape(fields[6]);
                const char* base = subj.data();
                long long len = (long long)subj.size();
                long long b = atoll(fields[3].c_str()), e = atoll(fields[4].c_str());
                if (b < 0)
                    b = 0;
                if (b > len)
                    b = len;
                if (e < b)
                    e = b;
                if (e > len)
                    e = len;
                auto flags = xflags_of(atoi(fields[5].c_str()));
                std::string out;
                int count = 0;
                bool trunc = false;
                if (op == "biter")
                {
                    RegexIterator<const char*, RegexMode::Backward> it{
                        base + b, base + e, base, base + len, re, flags};
                    for (auto jt = it.begin(); jt != it.end(); ++jt)
                    {
                        if (count == 500)
                        {
                            trunc = true;
                            break;
                        }
                        if (count > 0)
                            out += ' ';
                        const auto& res = *jt;
                        for (size_t i = 0; i < res.size(); ++i)
                        {
                            if (i > 0)
                                out += ',';
                            auto m = res[i];
                            if (not m.matched)
                                out += '-';
                            else
                            {
                                char buf[64];
                                snprintf(buf, sizeof buf, "%td:%td",
                                         m.first - base, m.second - base);
                                out += buf;
                            }
                        }
                        ++count;
                    }
                }
                else
                {
                    RegexIterator<const char*> it{
                        base + b, base + e, base, base + len, re, flags};
                    for (auto jt = it.begin(); jt != it.end(); ++jt)
                    {
                        if (count == 500)
                        {
                            trunc = true;
                            break;
                        }
                        if (count > 0)
                            out += ' ';
                        const auto& res = *jt;
                        for (size_t i = 0; i < res.size(); ++i)
                        {
                            if (i > 0)
                                out += ',';
                            auto m = res[i];
                            if (not m.matched)
                                out += '-';
                            else
                            {
                                char buf[64];
                                snprintf(buf, sizeof buf, "%td:%td",
                                         m.first - base, m.second - base);
                                out += buf;
                            }
                        }
                        ++count;
                    }
                }
                printf("N %d%s%s%s\n", count, out.empty() ? "" : " ",
                       out.c_str(), trunc ? " TRUNC" : "");
            }
            else if (op == "named" and fields.size() == 4)
            {
                std::string pat = unescape(fields[1]);
                int cf = atoi(fields[2].c_str()) & ~8;
                Regex re{StringView{pat.data(), pat.data() + pat.size()}, cflags_of(cf)};
                std::string name = unescape(fields[3]);
                printf("%d\n", re.named_capture_index(StringView{name.data(), name.data() + name.size()}));
            }
            else if (op == "flags" and fields.size() == 5)
            {
                auto xf = match_flags(atoi(fields[1].c_str()), atoi(fields[2].c_str()),
                                      atoi(fields[3].c_str()), atoi(fields[4].c_str()));
                printf("%d\n", (int)xf);
            }
            else if (op == "empty" and fields.size() == 3)
            {
                std::string pat = unescape(fields[1]);
                int cf = atoi(fields[2].c_str()) & ~8;
                Regex re{StringView{pat.data(), pat.data() + pat.size()}, cflags_of(cf)};
                printf("%d\n", (int)re.empty());
            }
            else if (op == "echo" and fields.size() == 2)
                printf("%s\n", escape(unescape(fields[1])).c_str());
            else
                printf("HARNESS-ERROR bad line\n");
        }
        catch (const regex_error& err)
        {
            StringView what = err.what();
            std::string msg{what.data(), (size_t)(int)what.length()};
            printf("ERR %s\n", escape(msg).c_str());
        }
        catch (const std::exception& err)
        {
            printf("EXC %s\n", escape(err.what()).c_str());
        }
    }
    return 0;
}
