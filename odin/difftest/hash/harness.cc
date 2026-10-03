// C++ side of the hash differential harness.
//
// Reads op lines on stdin, prints one result line per line on stdout.
// String args use \xNN escapes for every byte outside printable ASCII
// (0x20..0x7E except backslash); TAB separates fields, so TAB never
// appears literally. The Odin counterpart implements the same decoding.
//
// Ops:
//   murmur3 <data>            -> uint32 decimal
//   fnv1a <data>              -> uint32 decimal
//   combine <u64> <u64>       -> uint64 decimal
//   values <u64> [<u64> ...]  -> uint64 decimal (hash_values fold, 1-4 args)
//   echo <data>               -> re-escaped input (decoder self-check)

#include "hash.hh"

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
    std::string line;
    while (std::getline(std::cin, line))
    {
        if (not line.empty() and line.back() == '\r')
            line.pop_back();
        auto fields = split_tabs(line);
        const std::string& op = fields[0];
        if (op == "murmur3" and fields.size() == 2)
        {
            std::string data = unescape(fields[1]);
            printf("%u\n", (unsigned)murmur3(data.data(), data.size()));
        }
        else if (op == "fnv1a" and fields.size() == 2)
        {
            std::string data = unescape(fields[1]);
            printf("%u\n", (unsigned)fnv1a(data.data(), data.size()));
        }
        else if (op == "combine" and fields.size() == 3)
        {
            size_t a = (size_t)strtoull(fields[1].c_str(), nullptr, 10);
            size_t b = (size_t)strtoull(fields[2].c_str(), nullptr, 10);
            printf("%zu\n", combine_hash(a, b));
        }
        else if (op == "values" and fields.size() >= 2 and fields.size() <= 5)
        {
            size_t v[4] = {};
            for (size_t i = 1; i < fields.size(); ++i)
                v[i - 1] = (size_t)strtoull(fields[i].c_str(), nullptr, 10);
            size_t r = v[0];
            if (fields.size() == 3)
                r = hash_values(v[0], v[1]);
            else if (fields.size() == 4)
                r = hash_values(v[0], v[1], v[2]);
            else if (fields.size() == 5)
                r = hash_values(v[0], v[1], v[2], v[3]);
            printf("%zu\n", r);
        }
        else if (op == "echo" and fields.size() == 2)
            printf("%s\n", escape(unescape(fields[1])).c_str());
        else
            printf("HARNESS-ERROR bad line\n");
    }
    return 0;
}
