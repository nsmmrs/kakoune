// C++ side of the json differential harness. Same line protocol as the
// hash harness (see ../hash/harness.cc for escaping rules).
//
// parse results are reported in a canonical form both sides implement:
// scalars reuse the real to_json renderers, arrays join elements with
// ", ", and objects sort keys byte-wise and join `"k": v` pairs with
// ',' (matching the real to_json separators, minus map-order noise).
//
// Ops:
//   parse <doc>   -> "OK <canon>" | "NULL" (null Value) |
//                    "ERR <what>" (runtime_error) |
//                    "ERR bad_value_cast" | "ERR unknown"
//   serstr <raw>  -> to_json(StringView) of the raw bytes
//   serint <i>    -> to_json(int)
//   serbool <0|1> -> to_json(bool)
//   echo <data>   -> re-escaped input (decoder self-check)
//
// The driver maps C++ ERR texts onto the Odin Json_Error names; see README.

#include "json.hh"

#include "exception.hh"

#include <algorithm>
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

Kakoune::String canon(const Kakoune::Value& v);

Kakoune::String canon(const Kakoune::Value& v)
{
    using namespace Kakoune;
    if (v.is_a<int>())
        return to_json(v.as<int>());
    if (v.is_a<bool>())
        return to_json(v.as<bool>());
    if (v.is_a<String>())
        return to_json(StringView{v.as<String>()});
    if (v.is_a<JsonArray>())
    {
        const JsonArray& arr = v.as<JsonArray>();
        String res = "[";
        bool first = true;
        for (const Value& e : arr)
        {
            if (not first)
                res += ", ";
            first = false;
            res += canon(e);
        }
        return res + "]";
    }
    if (v.is_a<JsonObject>())
    {
        const JsonObject& obj = v.as<JsonObject>();
        std::vector<std::pair<StringView, const Value*>> items;
        for (const auto& [key, val] : obj)
            items.emplace_back(StringView{key}, &val);
        std::sort(items.begin(), items.end(),
                  [](const auto& a, const auto& b) { return a.first < b.first; });
        String res = "{";
        bool first = true;
        for (const auto& [k, vp] : items)
        {
            if (not first)
                res += ',';
            first = false;
            res += to_json(k);
            res += ": ";
            res += canon(*vp);
        }
        return res + "}";
    }
    return "<unknown-value-type>";
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
        if (op == "parse" and fields.size() == 2)
        {
            std::string doc = unescape(fields[1]);
            try
            {
                JsonResult r = parse_json(StringView{doc.data(), doc.data() + doc.size()});
                if (not r.value)
                    printf("NULL\n");
                else
                    printf("OK %s\n", canon(r.value).c_str());
            }
            catch (runtime_error& e)
            {
                printf("ERR %s\n", e.what());
            }
            catch (bad_value_cast&)
            {
                printf("ERR bad_value_cast\n");
            }
            catch (...)
            {
                printf("ERR unknown\n");
            }
        }
        else if (op == "serstr" and fields.size() == 2)
        {
            std::string raw = unescape(fields[1]);
            String out = to_json(StringView{raw.data(), raw.data() + raw.size()});
            printf("%s\n", out.c_str());
        }
        else if (op == "serint" and fields.size() == 2)
        {
            printf("%s\n", to_json(atoi(fields[1].c_str())).c_str());
        }
        else if (op == "serbool" and fields.size() == 2)
        {
            printf("%s\n", to_json(fields[1] != "0").c_str());
        }
        else if (op == "echo" and fields.size() == 2)
            printf("%s\n", escape(unescape(fields[1])).c_str());
        else
            printf("HARNESS-ERROR bad line\n");
    }
    return 0;
}
