// C++ side of the faces differential harness (face + face_registry).
//
// Reads op lines on stdin, prints one result line per line on stdout.
// String args use \xNN escapes for every byte outside printable ASCII
// (0x20..0x7E except backslash); TAB separates fields. The Odin
// counterpart implements the same decoding.
//
// FaceRegistry's root constructor is private (friend Scope), so this
// TU defines `private` to `public` around the face_registry.hh
// include to build a root registry. Access specifiers do not affect
// layout, so the exercised code is the real one.
//
// A face value is encoded as `fg|bg|ul|attrs`: each color is a palette
// name, `rgb:rrggbb` or `rgba:rrggbbaa` (parsed by the real
// str_to_color), and attrs is a subset of the parse_face attribute
// characters `ucUrbBdis fg aF` (`F` = FinalFg|FinalBg|FinalAttr).
// Faces print via the real to_string(Face): `fg,bg,ul[+attrs]`.
//
// Ops (every op starts from a fresh root registry with the 29 default
// faces unless noted):
//   merge <face1> <face2>  -> OK <to_string(merged)>
//   tostring <face>         -> OK <to_string(face)>
//   attrstr <attrs>         -> OK <to_string(Attribute)> (empty allowed)
//   parse <facedesc>        -> OK <to_string(face)> @<escaped-base>
//                            (base empty when there is none)
//                         -> ERR <escaped-what>
//   lookup <facedesc>       -> OK <to_string(face)> | ERR <escaped-what>
//   add <name> <facedesc> <override>
//                         -> OK <to_string(resolved name)>
//                          | ERR <escaped-what>
//   chain <n1> <f1> <o1> <n2> <f2> <o2> <lookupdesc>
//                         -> ADD1 <OK|ERR> ADD2 <OK|ERR> LU <OK <face>|ERR>
//                            (ERR details are dropped here; the add/lookup
//                            ops compare them exactly)
//   flatten <n1> <f1> <n2> <f2>
//                         -> N <k> [<name>=<face>@<base> ...] (TAB-joined,
//                            sorted by name; adds use override=0 and
//                            failures are ignored)
//   (no remove op: face_registry_remove in the Odin port frees the
//   entry's key before delete_key, leaving a ghost entry and
//   corrupting the heap -- see results.log)
//   child <name> <facedesc> <lookupdesc>
//                         -> ADD <OK|ERR> LU <OK <face>|ERR>
//                            (add to a child scope, lookup in the child)
//   echo <data>             -> re-escaped input
//
// The driver maps C++ ERR messages onto the Odin Face_Registry_Error
// names (see fuzz.py); any unmapped message is a mismatch for review.
// Inputs that place `,` or `+` after `@` are excluded: the C++ builds
// a reversed range / overruns the string there (the Odin port reports
// Invalid_Description instead, a documented deviation).

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <iostream>
#include <string>
#include <vector>

#define private public
#include "face_registry.hh"
#undef private

// Defined (but not declared) in face_registry.cc.
namespace Kakoune { String to_string(Attribute attributes); }

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

std::vector<std::string> split_pipe(const std::string& s)
{
    std::vector<std::string> parts{""};
    for (char c : s)
    {
        if (c == '|')
            parts.emplace_back();
        else
            parts.back() += c;
    }
    return parts;
}

Kakoune::Attribute attrs_of(const std::string& s, bool& ok)
{
    using Attr = Kakoune::Attribute;
    Attr a = Attr::Normal;
    for (char c : s)
    {
        switch (c)
        {
            case 'u': a |= Attr::Underline; break;
            case 'c': a |= Attr::CurlyUnderline; break;
            case 'U': a |= Attr::DoubleUnderline; break;
            case 'r': a |= Attr::Reverse; break;
            case 'b': a |= Attr::Bold; break;
            case 'B': a |= Attr::Blink; break;
            case 'd': a |= Attr::Dim; break;
            case 'i': a |= Attr::Italic; break;
            case 's': a |= Attr::Strikethrough; break;
            case 'f': a |= Attr::FinalFg; break;
            case 'g': a |= Attr::FinalBg; break;
            case 'a': a |= Attr::FinalAttr; break;
            case 'F': a |= Attr::Final; break;
            default: ok = false; return a;
        }
    }
    return a;
}

Kakoune::Color color_of(const std::string& s)
{
    return Kakoune::str_to_color(Kakoune::StringView{s.data(), s.data() + s.size()});
}

// Throws runtime_error("harness bad face") on malformed input (never on
// fuzzer output: the generator only emits valid faces).
Kakoune::Face face_of(const std::string& s)
{
    auto parts = split_pipe(s);
    if (parts.size() != 4)
        throw Kakoune::runtime_error("harness bad face");
    bool ok = true;
    Kakoune::Attribute a = attrs_of(parts[3], ok);
    if (not ok)
        throw Kakoune::runtime_error("harness bad face");
    return Kakoune::Face{color_of(parts[0]), color_of(parts[1]), a, color_of(parts[2])};
}

std::string show_face(const Kakoune::Face& f)
{
    Kakoune::String s = Kakoune::to_string(f);
    return {s.data(), (size_t)(int)s.length()};
}

std::string show_attrs(Kakoune::Attribute a)
{
    Kakoune::String s = Kakoune::to_string(a);
    return {s.data(), (size_t)(int)s.length()};
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
        try
        {
            if (op == "merge" and fields.size() == 3)
            {
                Face m = merge_faces(face_of(unescape(fields[1])), face_of(unescape(fields[2])));
                printf("OK %s\n", show_face(m).c_str());
            }
            else if (op == "tostring" and fields.size() == 2)
                printf("OK %s\n", show_face(face_of(unescape(fields[1]))).c_str());
            else if (op == "attrstr" and fields.size() == 2)
            {
                bool ok = true;
                Attribute a = attrs_of(unescape(fields[1]), ok);
                if (not ok)
                    printf("HARNESS-ERROR bad attrs\n");
                else
                    printf("OK %s\n", show_attrs(a).c_str());
            }
            else if (op == "parse" and fields.size() == 2)
            {
                std::string desc = unescape(fields[1]);
                FaceSpec spec = parse_face(StringView{desc.data(), desc.data() + desc.size()});
                printf("OK %s @%s\n", show_face(spec.face).c_str(), escape({spec.base.data(), (size_t)(int)spec.base.length()}).c_str());
            }
            else if (op == "lookup" and fields.size() == 2)
            {
                FaceRegistry reg;
                std::string desc = unescape(fields[1]);
                Face f = reg[StringView{desc.data(), desc.data() + desc.size()}];
                printf("OK %s\n", show_face(f).c_str());
            }
            else if (op == "add" and fields.size() == 4)
            {
                FaceRegistry reg;
                std::string name = unescape(fields[1]);
                std::string desc = unescape(fields[2]);
                reg.add_face(StringView{name.data(), name.data() + name.size()},
                             StringView{desc.data(), desc.data() + desc.size()},
                             atoi(fields[3].c_str()) != 0);
                Face f = reg[StringView{name.data(), name.data() + name.size()}];
                printf("OK %s\n", show_face(f).c_str());
            }
            else if (op == "chain" and fields.size() == 8)
            {
                FaceRegistry reg;
                std::string r1 = "OK", r2 = "OK";
                try
                {
                    std::string n = unescape(fields[1]), d = unescape(fields[2]);
                    reg.add_face(StringView{n.data(), n.data() + n.size()},
                                 StringView{d.data(), d.data() + d.size()},
                                 atoi(fields[3].c_str()) != 0);
                }
                catch (...) { r1 = "ERR"; }
                try
                {
                    std::string n = unescape(fields[4]), d = unescape(fields[5]);
                    reg.add_face(StringView{n.data(), n.data() + n.size()},
                                 StringView{d.data(), d.data() + d.size()},
                                 atoi(fields[6].c_str()) != 0);
                }
                catch (...) { r2 = "ERR"; }
                std::string lu;
                try
                {
                    std::string d = unescape(fields[7]);
                    lu = "OK " + show_face(reg[StringView{d.data(), d.data() + d.size()}]);
                }
                catch (...) { lu = "ERR"; }
                printf("ADD1 %s ADD2 %s LU %s\n", r1.c_str(), r2.c_str(), lu.c_str());
            }
            else if (op == "flatten" and fields.size() == 5)
            {
                FaceRegistry reg;
                for (int i = 0; i < 2; ++i)
                {
                    try
                    {
                        std::string n = unescape(fields[1 + 2 * i]), d = unescape(fields[2 + 2 * i]);
                        reg.add_face(StringView{n.data(), n.data() + n.size()},
                                     StringView{d.data(), d.data() + d.size()}, false);
                    }
                    catch (...) {}
                }
                std::vector<std::string> entries;
                for (auto& item : reg.flatten_faces())
                {
                    std::string nm{item.key.data(), (size_t)(int)item.key.length()};
                    std::string bs{item.value.base.data(), (size_t)(int)item.value.base.length()};
                    entries.push_back(escape(nm) + "=" + show_face(item.value.face) + "@" + escape(bs));
                }
                std::sort(entries.begin(), entries.end());
                printf("N %zu", entries.size());
                for (auto& e : entries)
                    printf("\t%s", e.c_str());
                printf("\n");
            }
            else if (op == "child" and fields.size() == 4)
            {
                FaceRegistry root;
                FaceRegistry sub{root};
                std::string add;
                try
                {
                    std::string n = unescape(fields[1]), d = unescape(fields[2]);
                    sub.add_face(StringView{n.data(), n.data() + n.size()},
                                 StringView{d.data(), d.data() + d.size()}, false);
                    add = "OK";
                }
                catch (...) { add = "ERR"; }
                std::string lu;
                try
                {
                    std::string d = unescape(fields[3]);
                    lu = "OK " + show_face(sub[StringView{d.data(), d.data() + d.size()}]);
                }
                catch (...) { lu = "ERR"; }
                printf("ADD %s LU %s\n", add.c_str(), lu.c_str());
            }
            else if (op == "echo" and fields.size() == 2)
                printf("%s\n", escape(unescape(fields[1])).c_str());
            else
                printf("HARNESS-ERROR bad line\n");
        }
        catch (const runtime_error& err)
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
