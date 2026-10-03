// C++ side of the diff differential harness. Same line protocol as the
// hash harness (see ../hash/harness.cc for escaping rules).
//
// Ops:
//   diff <a>\t<b>  -> space-joined runs "K3 R1 A2", or "EMPTY" when
//                     both inputs are empty (no runs at all)
//   echo <data>     -> re-escaped input (decoder self-check)

#include "diff.hh"

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
        if (op == "diff" and fields.size() == 3)
        {
            std::string a = unescape(fields[1]), b = unescape(fields[2]);
            std::string out;
            for_each_diff(a.data(), (int)a.size(), b.data(), (int)b.size(),
                          [&](DiffOp op, int len) {
                              if (not out.empty())
                                  out += ' ';
                              out += op == DiffOp::Keep ? 'K' : op == DiffOp::Add ? 'A' : 'R';
                              out += std::to_string(len);
                          });
            printf("%s\n", out.empty() ? "EMPTY" : out.c_str());
        }
        else if (op == "echo" and fields.size() == 2)
            printf("%s\n", escape(unescape(fields[1])).c_str());
        else
            printf("HARNESS-ERROR bad line\n");
    }
    return 0;
}
