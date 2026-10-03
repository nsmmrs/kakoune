// C++ side of the format differential harness.
//
// Reads op lines on stdin, prints one result line per line on stdout.
// String args use \xNN escapes for every byte outside printable ASCII
// (0x20..0x7E except backslash); TAB separates fields. The Odin
// counterpart implements the same decoding.
//
// Formatting output is re-escaped (params may embed NUL bytes, which
// printf("%s") would truncate), so format ops print "OK <escaped>".
//
// Ops:
//   int <i64>                  -> decimal (to_string(long long))
//   uint <u64>                 -> decimal (to_string(unsigned long))
//   hex <u64>                  -> lowercase hex, no prefix
//   grouped <u64>              -> thousands-separated decimal; values
//                               with 19+ digits (>= 10^18) overrun the
//                               C++ InplaceString<23> and are excluded
//                               from fuzzing (the Odin port sizes exactly)
//   float <u32 hex bits>       -> shortest round-trip general format
//   cp <i32>                   -> to_string(Codepoint), escaped; only
//                               [0, INT32_MAX] is fuzzed (negative runes
//                               are unrepresentable as C++ char32_t and
//                               the Odin port encodes their low byte)
//   format <fmt> [<p0> ...]    -> "OK <escaped>" | "ERR <what>"
//   format_to <bufsz> <fmt> [<p0> ...] -> same, via a fixed buffer
//   echo <data>                -> re-escaped input (decoder self-check)
//
// The driver maps C++ ERR texts onto the Odin Format_Error names;
// float lines are compared semantically (both spellings must parse to
// the same f32 bits, NaN == NaN). See README.

#include "format.hh"

#include "exception.hh"

#include <bit>
#include <clocale>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
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

Kakoune::StringView to_view(const std::string& s)
{
    return {s.data(), s.data() + s.size()};
}

std::string escape_view(Kakoune::StringView s)
{
    return escape(std::string{s.data(), (size_t)(int)s.length()});
}

} // namespace

int main()
{
    using namespace Kakoune;
    // Padding widths go through libc wcwidth via column_length.
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
        if (op == "int" and fields.size() == 2)
        {
            long long v = strtoll(fields[1].c_str(), nullptr, 10);
            StringView s = to_string(v);
            printf("%.*s\n", (int)s.length(), s.data());
        }
        else if (op == "uint" and fields.size() == 2)
        {
            unsigned long v = strtoul(fields[1].c_str(), nullptr, 10);
            StringView s = to_string(v);
            printf("%.*s\n", (int)s.length(), s.data());
        }
        else if (op == "hex" and fields.size() == 2)
        {
            size_t v = (size_t)strtoull(fields[1].c_str(), nullptr, 10);
            StringView s = to_string(hex(v));
            printf("%.*s\n", (int)s.length(), s.data());
        }
        else if (op == "grouped" and fields.size() == 2)
        {
            size_t v = (size_t)strtoull(fields[1].c_str(), nullptr, 10);
            StringView s = to_string(grouped(v));
            printf("%.*s\n", (int)s.length(), s.data());
        }
        else if (op == "float" and fields.size() == 2)
        {
            uint32_t u = (uint32_t)strtoul(fields[1].c_str(), nullptr, 16);
            float f = std::bit_cast<float>(u);
            StringView s = to_string(f);
            printf("%.*s\n", (int)s.length(), s.data());
        }
        else if (op == "cp" and fields.size() == 2)
        {
            long v = strtol(fields[1].c_str(), nullptr, 10);
            StringView s = to_string((Codepoint)v);
            std::string raw{s.data(), (size_t)s.length()};
            printf("%s\n", escape(raw).c_str());
        }
        else if (op == "format" and fields.size() >= 2)
        {
            std::string fmt = unescape(fields[1]);
            std::vector<std::string> ps;
            for (size_t i = 2; i < fields.size(); ++i)
                ps.push_back(unescape(fields[i]));
            std::vector<StringView> params;
            for (auto& p : ps)
                params.push_back(to_view(p));
            try
            {
                String res = format(to_view(fmt), {params.data(), params.size()});
                std::string raw{res.data(), (size_t)res.length()};
                printf("OK %s\n", escape(raw).c_str());
            }
            catch (runtime_error& e)
            {
                // what() embeds the offending index/width field, which
                // may contain raw newlines; escape to keep one line.
                printf("ERR %s\n", escape_view(e.what()).c_str());
            }
            catch (...)
            {
                printf("ERR unknown\n");
            }
        }
        else if (op == "format_to" and fields.size() >= 3)
        {
            long bufsz = strtol(fields[1].c_str(), nullptr, 10);
            std::string fmt = unescape(fields[2]);
            std::vector<std::string> ps;
            for (size_t i = 3; i < fields.size(); ++i)
                ps.push_back(unescape(fields[i]));
            std::vector<StringView> params;
            for (auto& p : ps)
                params.push_back(to_view(p));
            std::vector<char> buf(bufsz < 0 ? 0 : (size_t)bufsz);
            try
            {
                StringView res = format_to({buf.data(), buf.size()}, to_view(fmt),
                                           {params.data(), params.size()});
                std::string raw{res.data(), (size_t)res.length()};
                printf("OK %s\n", escape(raw).c_str());
            }
            catch (runtime_error& e)
            {
                printf("ERR %s\n", escape_view(e.what()).c_str());
            }
            catch (...)
            {
                printf("ERR unknown\n");
            }
        }
        else if (op == "echo" and fields.size() == 2)
            printf("%s\n", escape(unescape(fields[1])).c_str());
        else
            printf("HARNESS-ERROR bad line\n");
    }
    return 0;
}
