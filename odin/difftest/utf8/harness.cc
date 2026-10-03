// C++ side of the utf8 differential harness.
//
// Reads op lines on stdin, prints one result line per line on stdout.
// Byte strings use \xNN escapes for every byte outside printable ASCII
// (0x20..0x7E except backslash); TAB separates fields. The Odin
// counterpart implements the same decoding.
//
// Codepoints print as signed i32: invalid/truncated decodes yield
// sign-extended bytes on both sides.
//
// Ops:
//   is_start <byte>             -> 0|1
//   read <data> <pos>           -> "<cp> <newpos>" (pos <= len)
//   cp <data> <pos>             -> "<cp>" (decode without advancing)
//   size_byte <byte>            -> 1..4
//   size_cp <u32>               -> 0..4 (domain [0, INT32_MAX]; above
//                                 that the C++ char32_t and Odin rune
//                                 representations diverge)
//   next|finish|previous|charstart <data> <pos> -> byte offset
//   advance <data> <pos> <d>    -> byte offset (backward d is bounded so
//                                 the C++ never walks past begin: that is
//                                 an out-of-bounds read there, while the
//                                 Odin port clamps at 0)
//   distance <data>             -> character count
//   prevcp <data> <pos>         -> "<cp>" (character ending at pos)
//   dump <u32>                  -> escaped encoding (empty when cp >
//                                 0x10FFFF; domain [0, INT32_MAX] as
//                                 for size_cp)
//   width <i32>                 -> terminal columns (libc wcwidth; the
//                                 harness pins a UTF-8 locale. Inputs
//                                 come from the probe-verified agreement
//                                 pool, ASCII, negatives, and a few
//                                 verified huge values: glibc wcwidth and
//                                 the Odin core:unicode tables disagree
//                                 on ~66k codepoints, exhaustively
//                                 characterized; see README)
//   coldist <data>              -> column count (data built from the
//                                 agreement pool for the same reason)
//   advcol <data> <pos> <d>     -> byte offset, column-measured advance
//                                 (backward d uses width>=1 data and is
//                                 bounded like advance)
//   echo <data>                 -> re-escaped input (decoder self-check)

#include "utf8.hh"

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

} // namespace

int main()
{
    using namespace Kakoune;
    // Column widths go through libc wcwidth.
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
        if (op == "is_start" and fields.size() == 2)
        {
            char b = (char)strtol(fields[1].c_str(), nullptr, 10);
            printf("%d\n", utf8::is_character_start(b) ? 1 : 0);
        }
        else if (op == "read" and fields.size() == 3)
        {
            std::string data = unescape(fields[1]);
            size_t pos = (size_t)strtoull(fields[2].c_str(), nullptr, 10);
            auto it = data.begin() + (pos <= data.size() ? pos : data.size());
            Codepoint cp = utf8::read_codepoint(it, data.end());
            printf("%d %ld\n", (int32_t)cp, (long)(it - data.begin()));
        }
        else if (op == "cp" and fields.size() == 3)
        {
            std::string data = unescape(fields[1]);
            size_t pos = (size_t)strtoull(fields[2].c_str(), nullptr, 10);
            auto it = data.begin() + (pos <= data.size() ? pos : data.size());
            printf("%d\n", (int32_t)utf8::codepoint(it, data.end()));
        }
        else if (op == "size_byte" and fields.size() == 2)
        {
            char b = (char)strtol(fields[1].c_str(), nullptr, 10);
            printf("%d\n", (int)utf8::codepoint_size(b));
        }
        else if (op == "size_cp" and fields.size() == 2)
        {
            long long v = strtoll(fields[1].c_str(), nullptr, 10);
            printf("%d\n", (int)utf8::codepoint_size((Codepoint)v));
        }
        else if ((op == "next" or op == "finish" or op == "previous" or op == "charstart")
                 and fields.size() == 3)
        {
            std::string data = unescape(fields[1]);
            size_t pos = (size_t)strtoull(fields[2].c_str(), nullptr, 10);
            auto it = data.begin() + (pos <= data.size() ? pos : data.size());
            auto res = it;
            if (op == "next")
                res = utf8::next(it, data.end());
            else if (op == "finish")
                res = utf8::finish(it, data.end());
            else if (op == "previous")
                res = utf8::previous(it, data.begin());
            else
                res = utf8::character_start(it, data.begin());
            printf("%ld\n", (long)(res - data.begin()));
        }
        else if (op == "advance" and fields.size() == 4)
        {
            std::string data = unescape(fields[1]);
            size_t pos = (size_t)strtoull(fields[2].c_str(), nullptr, 10);
            int d = atoi(fields[3].c_str());
            auto it = data.begin() + (pos <= data.size() ? pos : data.size());
            auto res = utf8::advance(it, data.end(), CharCount{d});
            printf("%ld\n", (long)(res - data.begin()));
        }
        else if (op == "distance" and fields.size() == 2)
        {
            std::string data = unescape(fields[1]);
            printf("%d\n", (int)utf8::distance(data.begin(), data.end()));
        }
        else if (op == "prevcp" and fields.size() == 3)
        {
            std::string data = unescape(fields[1]);
            size_t pos = (size_t)strtoull(fields[2].c_str(), nullptr, 10);
            auto it = data.begin() + (pos <= data.size() ? pos : data.size());
            printf("%d\n", (int32_t)utf8::prev_codepoint(it, data.begin()));
        }
        else if (op == "dump" and fields.size() == 2)
        {
            long long v = strtoll(fields[1].c_str(), nullptr, 10);
            char buf[4];
            // As in to_string(Codepoint): dump advances the cursor.
            char* cur = buf;
            utf8::dump(cur, (Codepoint)v);
            printf("%s\n", escape(std::string(buf, cur)).c_str());
        }
        else if (op == "width" and fields.size() == 2)
        {
            long v = strtol(fields[1].c_str(), nullptr, 10);
            printf("%d\n", (int)codepoint_width((Codepoint)v));
        }
        else if (op == "coldist" and fields.size() == 2)
        {
            std::string data = unescape(fields[1]);
            printf("%d\n", (int)utf8::column_distance(data.begin(), data.end()));
        }
        else if (op == "advcol" and fields.size() == 4)
        {
            std::string data = unescape(fields[1]);
            size_t pos = (size_t)strtoull(fields[2].c_str(), nullptr, 10);
            int d = atoi(fields[3].c_str());
            auto it = data.begin() + (pos <= data.size() ? pos : data.size());
            auto res = utf8::advance(it, data.end(), ColumnCount{d});
            printf("%ld\n", (long)(res - data.begin()));
        }
        else if (op == "echo" and fields.size() == 2)
            printf("%s\n", escape(unescape(fields[1])).c_str());
        else
            printf("HARNESS-ERROR bad line\n");
    }
    return 0;
}
