// C++ side of the regex_vm differential harness (low-level VM API).
//
// Reads op lines on stdin, prints one result line per line on stdout.
// String args use \xNN escapes for every byte outside printable ASCII
// (0x20..0x7E except backslash); TAB separates fields. The Odin
// counterpart implements the same decoding. main() pins LC_ALL to
// en_US.utf8 (fallback C.utf8) like the regex harness: \w/\d/(?i)
// depend on libc wide-character classes.
//
// Ops (cflags bits: 1=NoSubs 2=Optimize 4=Backward 8=NoForward;
// mode bits: 1=Forward 2=Backward 4=Search 8=AnyMatch 16=NoSaves;
// xflags bits mirror RegexExecFlags: 2=NotBeginOfLine 4=NotEndOfLine
// 8=NotBeginOfWord 16=NotEndOfWord 32=NotInitialNull):
//   compile <pattern> <cflags>
//     -> OK saves=<s> ninst=<n> nclass=<c> nlook=<l> bwd=<0|1>
//        named=<k> [<name>=<idx> ...] F <fwddesc> B <bwdstartdesc>
//     -> ERR <escaped-what>
//     (each start desc is `-` when absent, else
//     `<startbyte>:<offset>:<64 hex digits of the 256-bit map>`)
//   exec <pattern> <cflags> <mode> <b> <e> <sb> <se> <xflags> <subject>
//     -> YES <groups> | YES (with NoSaves) | NO
//     -> ERR <escaped-what>
//   ctype <mask> <cp>  -> 0|1 (is_ctype over the raw 8-bit mask)
//   echo <data>        -> re-escaped input
//
// exec groups are the save_count/2 spans `begin:end` in byte offsets
// (`-` for unmatched). Harness rules (mirrored by the Odin side):
// Backward modes add Backward to cflags, Forward modes strip
// NoForward; b/e/sb/se are clamped into [0, len] with the end raised
// to the start when reversed.

#include "regex_vm.hh"

#include "string.hh"

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

std::string start_desc_str(const Kakoune::CompiledRegex::StartDesc* desc)
{
    if (not desc)
        return "-";
    static const char* digits = "0123456789abcdef";
    std::string map;
    for (int i = 0; i < 256; i += 4)
    {
        int v = 0;
        for (int k = 0; k < 4; ++k)
            v |= (desc->map[i + k] ? 1 : 0) << k;
        map += digits[v];
    }
    char buf[128];
    snprintf(buf, sizeof buf, "%d:%d:%s",
             (unsigned char)desc->start_byte, (int)desc->offset, map.c_str());
    return buf;
}

template<Kakoune::RegexMode mode>
bool do_exec(const Kakoune::CompiledRegex& prog,
             const char* b, const char* e, const char* sb, const char* se,
             const char* base,
             Kakoune::RegexExecFlags xf, std::string& caps)
{
    Kakoune::ThreadedRegexVM<const char*, mode> vm{prog};
    bool found = vm.exec(b, e, sb, se, xf);
    if (found and not (mode & Kakoune::RegexMode::NoSaves))
    {
        auto captures = vm.captures();
        for (size_t i = 0; i < captures.size(); i += 2)
        {
            if (i > 0)
                caps += ' ';
            const char* first = captures[i];
            const char* second = captures[i + 1];
            if (first == nullptr or second == nullptr)
                caps += '-';
            else
            {
                char buf[64];
                snprintf(buf, sizeof buf, "%td:%td", first - base, second - base);
                caps += buf;
            }
        }
    }
    return found;
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
                StringView view{pat.data(), pat.data() + pat.size()};
                CompiledRegex prog = compile_regex(view, cflags_of(atoi(fields[2].c_str())));
                printf("OK saves=%u ninst=%zu nclass=%zu nlook=%zu bwd=%d named=%zu",
                       prog.save_count, prog.instructions.size(),
                       prog.character_classes.size(), prog.lookarounds.size(),
                       (int)(prog.first_backward_inst != (uint32_t)-1),
                       prog.named_captures.size());
                for (auto& nc : prog.named_captures)
                    printf(" %s=%u", escape({nc.name.data(), (size_t)(int)nc.name.length()}).c_str(), nc.index);
                printf(" F %s B %s\n",
                       start_desc_str(prog.forward_start_desc.get()).c_str(),
                       start_desc_str(prog.backward_start_desc.get()).c_str());
            }
            else if (op == "exec" and fields.size() == 10)
            {
                std::string pat = unescape(fields[1]);
                int cf = atoi(fields[2].c_str());
                int mode = atoi(fields[3].c_str());
                bool forward = (mode & 1) and not (mode & 2);
                bool backward = (mode & 2) and not (mode & 1);
                if (not forward and not backward)
                {
                    printf("HARNESS-ERROR bad mode\n");
                    continue;
                }
                if (backward)
                    cf |= 4;
                else
                    cf &= ~8;
                StringView view{pat.data(), pat.data() + pat.size()};
                CompiledRegex prog = compile_regex(view, cflags_of(cf));
                std::string subj = unescape(fields[9]);
                const char* base = subj.data();
                long long len = (long long)subj.size();
                long long b = atoll(fields[4].c_str()), e = atoll(fields[5].c_str());
                long long sb = atoll(fields[6].c_str()), se = atoll(fields[7].c_str());
                if (b < 0)
                    b = 0;
                if (b > len)
                    b = len;
                if (e < b)
                    e = b;
                if (e > len)
                    e = len;
                if (sb < 0)
                    sb = 0;
                if (sb > len)
                    sb = len;
                if (se < sb)
                    se = sb;
                if (se > len)
                    se = len;
                auto xf = xflags_of(atoi(fields[8].c_str()));
                bool search = mode & 4, any = mode & 8, nosaves = mode & 16;
                std::string caps;
                bool found = false;
                const char* bb = base + b;
                const char* ee = base + e;
                const char* ssb = base + sb;
                const char* sse = base + se;
                int key = (forward ? 1 : 2) | (search ? 4 : 0) | (any ? 8 : 0) | (nosaves ? 16 : 0);
                using RM = RegexMode;
                switch (key)
                {
                    case 1: found = do_exec<RM::Forward>(prog, bb, ee, ssb, sse, base, xf, caps); break;
                    case 5: found = do_exec<RM::Forward | RM::Search>(prog, bb, ee, ssb, sse, base, xf, caps); break;
                    case 9: found = do_exec<RM::Forward | RM::AnyMatch>(prog, bb, ee, ssb, sse, base, xf, caps); break;
                    case 13: found = do_exec<RM::Forward | RM::Search | RM::AnyMatch>(prog, bb, ee, ssb, sse, base, xf, caps); break;
                    case 17: found = do_exec<RM::Forward | RM::NoSaves>(prog, bb, ee, ssb, sse, base, xf, caps); break;
                    case 21: found = do_exec<RM::Forward | RM::Search | RM::NoSaves>(prog, bb, ee, ssb, sse, base, xf, caps); break;
                    case 25: found = do_exec<RM::Forward | RM::AnyMatch | RM::NoSaves>(prog, bb, ee, ssb, sse, base, xf, caps); break;
                    case 29: found = do_exec<RM::Forward | RM::Search | RM::AnyMatch | RM::NoSaves>(prog, bb, ee, ssb, sse, base, xf, caps); break;
                    case 2: found = do_exec<RM::Backward>(prog, bb, ee, ssb, sse, base, xf, caps); break;
                    case 6: found = do_exec<RM::Backward | RM::Search>(prog, bb, ee, ssb, sse, base, xf, caps); break;
                    case 10: found = do_exec<RM::Backward | RM::AnyMatch>(prog, bb, ee, ssb, sse, base, xf, caps); break;
                    case 14: found = do_exec<RM::Backward | RM::Search | RM::AnyMatch>(prog, bb, ee, ssb, sse, base, xf, caps); break;
                    case 18: found = do_exec<RM::Backward | RM::NoSaves>(prog, bb, ee, ssb, sse, base, xf, caps); break;
                    case 22: found = do_exec<RM::Backward | RM::Search | RM::NoSaves>(prog, bb, ee, ssb, sse, base, xf, caps); break;
                    case 26: found = do_exec<RM::Backward | RM::AnyMatch | RM::NoSaves>(prog, bb, ee, ssb, sse, base, xf, caps); break;
                    case 30: found = do_exec<RM::Backward | RM::Search | RM::AnyMatch | RM::NoSaves>(prog, bb, ee, ssb, sse, base, xf, caps); break;
                    default: printf("HARNESS-ERROR bad mode\n"); continue;
                }
                if (found)
                {
                    if (nosaves or caps.empty())
                        printf("YES\n");
                    else
                        printf("YES %s\n", caps.c_str());
                }
                else
                    printf("NO\n");
            }
            else if (op == "ctype" and fields.size() == 3)
            {
                int mask = atoi(fields[1].c_str());
                long cp = atol(fields[2].c_str());
                bool r = is_ctype(CharacterType{(unsigned char)(mask & 0xFF)}, (Codepoint)cp);
                printf("%d\n", (int)r);
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
