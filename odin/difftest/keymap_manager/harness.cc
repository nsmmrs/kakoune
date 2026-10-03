// C++ side of the keymap_manager differential harness.
//
// Reads op lines on stdin, prints one result line per line on stdout.
// String args use \xNN escapes for every byte outside printable ASCII
// (0x20..0x7E except backslash); TAB separates fields. The Odin
// counterpart implements the same decoding.
//
// KeymapManager's root constructor is private (friend Scope), so this
// TU defines `private` to `public` around the keymap_manager.hh
// include to build a root manager. Access specifiers do not affect
// layout, so the exercised code is the real one.
//
// A key is encoded `modifiers:codepoint` (both decimal ints); a key
// list is comma-joined keys (empty = no keys). A mode is the decimal
// enumerator 0..10 (None..FirstUserMode). Mapped-key listings are
// sorted by Key::val() in the harness: the C++ and Odin hash tables
// iterate in different orders.
//
// Ops (every op starts from a fresh root manager):
//   mapget <key> <mode> <mkeys> <doc> <atomic> <qkey> <qmode>
//     -> NONE | FOUND <mkeys> <escaped-doc> <atomic>
//   unmapget <key> <mode> <mkeys> <doc> <atomic> <qkey> <qmode>
//     -> (map, unmap_key, then get) NONE | FOUND ...
//   unmapall <mode> <k1> <m1> <mk1> <d1> <a1> <k2> <m2> <mk2> <d2>
//     <a2> <qmode>
//     -> G1 <r> G2 <r> MAPPED <n> <sorted-keys> (each r is NONE or
//        FOUND <mkeys> <doc> <atomic>; sorted-keys comma-joined)
//   mapped <qmode> <count> [<key> <mode> <mkeys> <doc> <atomic>]*
//     -> N <k> <sorted-comma-keys>
//   usermode <count> [<name>]*
//     -> <r1>\t<r2>...\tMODES <n> <comma-joined-names> (each r is OK
//        or ERR <escaped-what>; names escaped; insertion order; the
//        TAB joins let the driver normalize each ERR exactly)
//   parent <key> <mode> <rootkeys> <rootdoc> <childkeys|-> <childdoc>
//     <unmap>
//     -> (root maps; child optionally maps `-` = skip; child
//        optionally unmaps; get on the child) NONE | FOUND ...
//   echo <data> -> re-escaped input
//
// The driver maps C++ usermode ERR messages onto the Odin
// Keymap_Manager_Error names; any unmapped message is a mismatch.

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <iostream>
#include <string>
#include <vector>

#define private public
#include "keymap_manager.hh"
#undef private
#include "exception.hh"

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

bool parse_key(const std::string& s, Kakoune::Key& key)
{
    auto pos = s.find(':');
    if (pos == std::string::npos)
        return false;
    char* end = nullptr;
    long mod = strtol(s.c_str(), &end, 10);
    if (end != s.c_str() + pos)
        return false;
    long cp = strtol(s.c_str() + pos + 1, &end, 10);
    if (end != s.c_str() + s.size() or cp < 0 or cp > 0x7FFFFFFF)
        return false;
    key = Kakoune::Key{(Kakoune::Key::Modifiers)(int)mod, (Kakoune::Codepoint)(unsigned)cp};
    return true;
}

bool parse_keys(const std::string& s, Kakoune::KeymapManager::KeyList& keys)
{
    keys.clear();
    if (s.empty())
        return true;
    size_t start = 0;
    while (true)
    {
        size_t comma = s.find(',', start);
        std::string piece = s.substr(start, comma == std::string::npos ? comma : comma - start);
        Kakoune::Key k;
        if (not parse_key(piece, k))
            return false;
        keys.push_back(k);
        if (comma == std::string::npos)
            return true;
        start = comma + 1;
    }
}

std::string show_key(Kakoune::Key k)
{
    char buf[64];
    snprintf(buf, sizeof buf, "%d:%u", (int)k.modifiers, (unsigned)k.key);
    return buf;
}

std::string show_keys(const Kakoune::KeymapManager::KeyList& keys)
{
    std::string out;
    for (size_t i = 0; i < keys.size(); ++i)
    {
        if (i > 0)
            out += ',';
        out += show_key(keys[i]);
    }
    return out;
}

std::string show_mapping(const Kakoune::KeymapManager::KeymapInfo* info)
{
    if (info == nullptr)
        return "NONE";
    std::string doc{info->docstring.data(), (size_t)(int)info->docstring.length()};
    char buf[32];
    snprintf(buf, sizeof buf, "%d", (int)info->atomic);
    return "FOUND " + show_keys(info->keys) + " " + escape(doc) + " " + buf;
}

Kakoune::KeymapMode mode_of(const std::string& s)
{
    return (Kakoune::KeymapMode)atoi(s.c_str());
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
            if ((op == "mapget" or op == "unmapget") and fields.size() == 8)
            {
                KeymapManager mgr;
                Key key, qkey;
                KeymapManager::KeyList mkeys;
                if (not parse_key(unescape(fields[1]), key) or
                    not parse_keys(unescape(fields[3]), mkeys) or
                    not parse_key(unescape(fields[6]), qkey))
                {
                    printf("HARNESS-ERROR bad key\n");
                    continue;
                }
                std::string doc = unescape(fields[4]);
                mgr.map_key(key, mode_of(fields[2]), KeymapManager::KeyList{mkeys},
                            String{doc.data(), ByteCount{(int)doc.size()}},
                            atoi(fields[5].c_str()) != 0);
                if (op == "unmapget")
                    mgr.unmap_key(key, mode_of(fields[2]));
                printf("%s\n", show_mapping(mgr.get_mapping(qkey, mode_of(fields[7]))).c_str());
            }
            else if (op == "unmapall" and fields.size() == 13)
            {
                KeymapManager mgr;
                Key k1, k2;
                KeymapManager::KeyList mk1, mk2;
                if (not parse_key(unescape(fields[2]), k1) or
                    not parse_keys(unescape(fields[4]), mk1) or
                    not parse_key(unescape(fields[7]), k2) or
                    not parse_keys(unescape(fields[9]), mk2))
                {
                    printf("HARNESS-ERROR bad key\n");
                    continue;
                }
                std::string d1 = unescape(fields[5]), d2 = unescape(fields[10]);
                mgr.map_key(k1, mode_of(fields[3]), KeymapManager::KeyList{mk1},
                            String{d1.data(), ByteCount{(int)d1.size()}},
                            atoi(fields[6].c_str()) != 0);
                mgr.map_key(k2, mode_of(fields[8]), KeymapManager::KeyList{mk2},
                            String{d2.data(), ByteCount{(int)d2.size()}},
                            atoi(fields[11].c_str()) != 0);
                mgr.unmap_keys(mode_of(fields[1]));
                std::string g1 = show_mapping(mgr.get_mapping(k1, mode_of(fields[3])));
                std::string g2 = show_mapping(mgr.get_mapping(k2, mode_of(fields[8])));
                auto mapped = mgr.get_mapped_keys(mode_of(fields[12]));
                std::sort(mapped.begin(), mapped.end(),
                          [](Key a, Key b) { return a.val() < b.val(); });
                printf("G1 %s G2 %s MAPPED %zu %s\n", g1.c_str(), g2.c_str(),
                       mapped.size(), show_keys(mapped).c_str());
            }
            else if (op == "mapped" and fields.size() >= 3)
            {
                int count = atoi(fields[2].c_str());
                if (count < 0 or fields.size() != (size_t)(3 + 5 * count))
                {
                    printf("HARNESS-ERROR bad line\n");
                    continue;
                }
                KeymapManager mgr;
                bool bad = false;
                for (int i = 0; i < count; ++i)
                {
                    Key key;
                    KeymapManager::KeyList mkeys;
                    if (not parse_key(unescape(fields[3 + 5 * i]), key) or
                        not parse_keys(unescape(fields[5 + 5 * i]), mkeys))
                    {
                        bad = true;
                        break;
                    }
                    std::string doc = unescape(fields[6 + 5 * i]);
                    mgr.map_key(key, mode_of(fields[4 + 5 * i]), KeymapManager::KeyList{mkeys},
                                String{doc.data(), ByteCount{(int)doc.size()}},
                                atoi(fields[7 + 5 * i].c_str()) != 0);
                }
                if (bad)
                {
                    printf("HARNESS-ERROR bad key\n");
                    continue;
                }
                auto mapped = mgr.get_mapped_keys(mode_of(fields[1]));
                std::sort(mapped.begin(), mapped.end(),
                          [](Key a, Key b) { return a.val() < b.val(); });
                printf("N %zu %s\n", mapped.size(), show_keys(mapped).c_str());
            }
            else if (op == "usermode" and fields.size() >= 2)
            {
                int count = atoi(fields[1].c_str());
                if (count < 0 or fields.size() != (size_t)(2 + count))
                {
                    printf("HARNESS-ERROR bad line\n");
                    continue;
                }
                KeymapManager mgr;
                std::string out;
                for (int i = 0; i < count; ++i)
                {
                    if (i > 0)
                        out += '\t';
                    std::string name = unescape(fields[2 + i]);
                    try
                    {
                        mgr.add_user_mode(String{name.data(), ByteCount{(int)name.size()}});
                        out += "OK";
                    }
                    catch (const runtime_error& err)
                    {
                        StringView what = err.what();
                        std::string msg{what.data(), (size_t)(int)what.length()};
                        out += "ERR " + escape(msg);
                    }
                }
                auto& modes = mgr.user_modes();
                std::string ml;
                for (size_t i = 0; i < modes.size(); ++i)
                {
                    if (i > 0)
                        ml += ',';
                    std::string nm{modes[i].data(), (size_t)(int)modes[i].length()};
                    ml += escape(nm);
                }
                printf("%s%sMODES %zu %s\n", out.c_str(), out.empty() ? "" : "\t",
                       modes.size(), ml.c_str());
            }
            else if (op == "parent" and fields.size() == 8)
            {
                KeymapManager root;
                KeymapManager sub{root};
                Key key;
                KeymapManager::KeyList rkeys, ckeys;
                std::string cks = unescape(fields[5]);
                if (not parse_key(unescape(fields[1]), key) or
                    not parse_keys(unescape(fields[3]), rkeys) or
                    (cks != "-" and not parse_keys(cks, ckeys)))
                {
                    printf("HARNESS-ERROR bad key\n");
                    continue;
                }
                std::string rdoc = unescape(fields[4]), cdoc = unescape(fields[6]);
                root.map_key(key, mode_of(fields[2]), KeymapManager::KeyList{rkeys},
                             String{rdoc.data(), ByteCount{(int)rdoc.size()}}, false);
                if (cks != "-")
                    sub.map_key(key, mode_of(fields[2]), KeymapManager::KeyList{ckeys},
                                String{cdoc.data(), ByteCount{(int)cdoc.size()}}, false);
                if (atoi(fields[7].c_str()) != 0)
                    sub.unmap_key(key, mode_of(fields[2]));
                printf("%s\n", show_mapping(sub.get_mapping(key, mode_of(fields[2]))).c_str());
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
