// C++ side of the parameters_parser differential harness.
//
// Reads op lines on stdin, prints one result line per line on stdout.
// String args use \xNN escapes for every byte outside printable ASCII
// (0x20..0x7E except backslash); TAB separates fields. The Odin
// counterpart implements the same decoding.
//
// Ops:
//   parse <flags> <min> <max> <nsw> [<swname> <takesarg> <swdesc>]...
//     <nparams> [<param>]...
//   parseie ... (same fields; ignore_errors=true)
//     -> OK\t<npos>\t<pos...>\t<nsw>\t<name=escaped-val... (sorted)>
//        \t<state>\t<nfrom0>\t<from0...>\t<nfrom1>\t<from1...>
//     -> ERR <Class>
//     (flags bits: 1=SwitchesOnlyAtStart 2=SwitchesAsPositional
//     4=IgnoreUnknownSwitches; max<0 = unlimited; state is Switch,
//     SwitchArgument, Positional or NONE. ERR classes: Unknown_Option,
//     Missing_Option_Value, Wrong_Argument_Count, Duplicate_Switch.
//     from0/from1 are positionals_from(0)/(1).)
//   gendoc <nsw> [<swname> <takesarg> <swdesc>]*
//     -> DOC <nlines>\t<line...> (lines sorted byte-wise, escaped)
//   echo <data> -> re-escaped input
//
// Valued switches use a dummy ArgCompleter (the parser only observes
// its presence). The harness never calls state() on an empty parse:
// the C++ dereferences an empty Optional there (UB); the Odin port
// reports NONE, and the harness prints NONE too.

#include "parameters_parser.hh"

#include "completion.hh"
#include "flags.hh"

#include <algorithm>
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

Kakoune::ParameterDesc::Flags flags_of(int bits)
{
    using F = Kakoune::ParameterDesc::Flags;
    F f = F::None;
    if (bits & 1)
        f |= F::SwitchesOnlyAtStart;
    if (bits & 2)
        f |= F::SwitchesAsPositional;
    if (bits & 4)
        f |= F::IgnoreUnknownSwitches;
    return f;
}

Kakoune::SwitchMap switch_map_of(const std::vector<std::string>& fields, size_t at, int nsw)
{
    Kakoune::SwitchMap switches;
    for (int i = 0; i < nsw; ++i)
    {
        std::string name = unescape(fields[at + 3 * i]);
        bool takes_arg = atoi(fields[at + 3 * i + 1].c_str()) != 0;
        std::string desc = unescape(fields[at + 3 * i + 2]);
        Kakoune::SwitchDesc sw;
        if (takes_arg)
            sw.arg_completer = Kakoune::ArgCompleter{
                +[](const Kakoune::Context&, Kakoune::StringView, Kakoune::ByteCount)
                    -> Kakoune::Completions { return {}; }};
        sw.description = Kakoune::String{desc.data(), Kakoune::ByteCount{(int)desc.size()}};
        switches[Kakoune::String{name.data(), Kakoune::ByteCount{(int)name.size()}}] = std::move(sw);
    }
    return switches;
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
            if ((op == "parse" or op == "parseie") and fields.size() >= 6)
            {
                int nsw = atoi(fields[4].c_str());
                if (nsw < 0 or fields.size() < (size_t)(6 + 3 * nsw))
                {
                    printf("HARNESS-ERROR bad line\n");
                    continue;
                }
                size_t pat = 5 + 3 * nsw;
                int nparams = atoi(fields[pat].c_str());
                if (nparams < 0 or fields.size() != pat + 1 + (size_t)nparams)
                {
                    printf("HARNESS-ERROR bad line\n");
                    continue;
                }
                ParameterDesc desc;
                desc.switches = switch_map_of(fields, 5, nsw);
                desc.flags = flags_of(atoi(fields[1].c_str()));
                desc.min_positionals = (size_t)atoll(fields[2].c_str());
                long long mx = atoll(fields[3].c_str());
                desc.max_positionals = mx < 0 ? (size_t)-1 : (size_t)mx;
                Vector<String> params;
                for (int i = 0; i < nparams; ++i)
                {
                    std::string p = unescape(fields[pat + 1 + i]);
                    params.emplace_back(p.data(), ByteCount{(int)p.size()});
                }
                try
                {
                    ParametersParser parser{params, desc, op == "parseie"};
                    std::string out = "OK";
                    char buf[64];
                    snprintf(buf, sizeof buf, "\t%zu", parser.positional_count());
                    out += buf;
                    for (size_t i = 0; i < parser.positional_count(); ++i)
                    {
                        const String& s = parser[i];
                        out += "\t" + escape({s.data(), (size_t)(int)s.length()});
                    }
                    // Switches, sorted by name (hash iteration differs).
                    std::vector<std::string> sw;
                    for (auto& kv : desc.switches)
                    {
                        std::string nm{kv.key.data(), (size_t)(int)kv.key.length()};
                        auto val = parser.get_switch(
                            StringView{nm.data(), nm.data() + nm.size()});
                        if (val)
                        {
                            StringView v = *val;
                            sw.push_back(escape(nm) + "=" +
                                         escape({v.data(), (size_t)(int)v.length()}));
                        }
                    }
                    std::sort(sw.begin(), sw.end());
                    snprintf(buf, sizeof buf, "\t%zu", sw.size());
                    out += buf;
                    for (auto& s : sw)
                        out += "\t" + s;
                    const char* st = "NONE";
                    if (nparams > 0)
                    {
                        switch (parser.state())
                        {
                            case ParametersParser::State::Switch: st = "Switch"; break;
                            case ParametersParser::State::SwitchArgument: st = "SwitchArgument"; break;
                            case ParametersParser::State::Positional: st = "Positional"; break;
                        }
                    }
                    out += "\t";
                    out += st;
                    for (int first : {0, 1})
                    {
                        auto from = parser.positionals_from(first);
                        snprintf(buf, sizeof buf, "\t%zu", from.size());
                        out += buf;
                        for (auto& s : from)
                            out += "\t" + escape({s.data(), (size_t)(int)s.length()});
                    }
                    printf("%s\n", out.c_str());
                }
                catch (const unknown_option&)
                {
                    printf("ERR Unknown_Option\n");
                }
                catch (const missing_option_value&)
                {
                    printf("ERR Missing_Option_Value\n");
                }
                catch (const wrong_argument_count&)
                {
                    printf("ERR Wrong_Argument_Count\n");
                }
                catch (const runtime_error&)
                {
                    printf("ERR Duplicate_Switch\n");
                }
            }
            else if (op == "gendoc" and fields.size() >= 2)
            {
                int nsw = atoi(fields[1].c_str());
                if (nsw < 0 or fields.size() != (size_t)(2 + 3 * nsw))
                {
                    printf("HARNESS-ERROR bad line\n");
                    continue;
                }
                SwitchMap switches = switch_map_of(fields, 2, nsw);
                String doc = generate_switches_doc(switches);
                std::string text{doc.data(), (size_t)(int)doc.length()};
                std::vector<std::string> lines;
                size_t start = 0;
                while (start < text.size())
                {
                    size_t nl = text.find('\n', start);
                    if (nl == std::string::npos)
                    {
                        lines.push_back(text.substr(start));
                        break;
                    }
                    lines.push_back(text.substr(start, nl - start));
                    start = nl + 1;
                }
                std::sort(lines.begin(), lines.end());
                printf("DOC %zu", lines.size());
                for (auto& l : lines)
                    printf("\t%s", escape(l).c_str());
                printf("\n");
            }
            else if (op == "echo" and fields.size() == 2)
                printf("%s\n", escape(unescape(fields[1])).c_str());
            else
                printf("HARNESS-ERROR bad line\n");
        }
        catch (const std::exception& err)
        {
            printf("EXC %s\n", escape(err.what()).c_str());
        }
    }
    return 0;
}
