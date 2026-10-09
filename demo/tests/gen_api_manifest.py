#!/usr/bin/env python3
"""Turn the generated LuaBridge3 bindings into a Lua table describing the bound API.

The tests have to know every class, constructor and function tsujikiri bound, and that list
changes whenever Qt or the tsujikiri configuration does. Reading it back from the generated
files keeps the tests in sync without a checked-in copy that could rot.

Usage: gen_api_manifest.py <generated dir> <qt6_api.lua>

Each generated file registers its part of the API in one fluent chain:

    luabridge::getGlobalNamespace(L).beginNamespace("qt6")
      .beginNamespace("Qt") .addProperty(...) ... .endNamespace()        namespace level enums
      .addFunction("mouse_click", ...)                                   namespace level functions
      .beginClass<T>("T") | .deriveClass<T, Base...>("T")
        .addConstructor<...>() | .addConstructorFrom<Holder<T>, void(...), ...>()
        .addFunction("name", ...) .addStaticFunction("name", ...) .addStaticProperty("name", ...)
        .addIndexMetaMethod(...)
      .endClass()
    .endNamespace();

The scanner below walks that chain call by call, whatever the arguments contain (lambdas,
casts, strings), and fails on anything it does not know instead of producing a weaker manifest.
"""

import re
import sys
from pathlib import Path

KNOWN_CALLS = {
    "beginNamespace", "endNamespace", "beginClass", "deriveClass", "endClass",
    "addConstructor", "addConstructorFrom", "addFunction", "addStaticFunction",
    "addStaticProperty", "addProperty", "addIndexMetaMethod",
}


def skip_string(text, i):
    """`i` is at a quote: returns the index after the literal."""
    quote = text[i]
    i += 1
    while text[i] != quote:
        i += 2 if text[i] == "\\" else 1
    return i + 1


def balanced(text, i, opening, closing):
    """`i` is at `opening`: returns the index after the matching `closing`."""
    depth = 0
    while True:
        ch = text[i]
        if ch in "\"'":
            i = skip_string(text, i)
            continue
        if ch == opening:
            depth += 1
        elif ch == closing:
            depth -= 1
            if depth == 0:
                return i + 1
        elif ch in "([{" and opening != ch:
            # Another bracket kind nested inside: skip it as a whole
            pair = {"(": ")", "[": "]", "{": "}"}[ch]
            i = balanced(text, i, ch, pair)
            continue
        i += 1


def split_top_level(text, sep=","):
    """Split on `sep` ignoring separators nested in <>, () or []."""
    parts, depth, current, i = [], 0, [], 0
    while i < len(text):
        ch = text[i]
        if ch in "\"'":
            end = skip_string(text, i)
            current.append(text[i:end])
            i = end
            continue
        if ch in "<([":
            depth += 1
        elif ch in ">)]":
            depth -= 1
        if ch == sep and depth == 0:
            parts.append("".join(current).strip())
            current = []
        else:
            current.append(ch)
        i += 1
    tail = "".join(current).strip()
    if tail:
        parts.append(tail)
    return parts


def scan_calls(chain):
    """Yields (name, template arguments or None, argument text) of the calls at the top level of the chain."""
    i = 0
    while True:
        i = chain.find(".", i)
        if i < 0:
            return
        match = re.compile(r"\.([A-Za-z_]\w*)").match(chain, i)
        if not match:
            i += 1
            continue

        name = match.group(1)
        j = match.end()
        while chain[j].isspace():
            j += 1

        targs = None
        if chain[j] == "<":
            # Template arguments: angle brackets nest, brackets of other kinds are skipped
            depth, k = 0, j
            while True:
                ch = chain[k]
                if ch in "\"'":
                    k = skip_string(chain, k)
                    continue
                if ch in "([{":
                    k = balanced(chain, k, ch, {"(": ")", "[": "]", "{": "}"}[ch])
                    continue
                if ch == "<":
                    depth += 1
                elif ch == ">":
                    depth -= 1
                    if depth == 0:
                        break
                k += 1
            targs = chain[j + 1:k]
            j = k + 1
            while chain[j].isspace():
                j += 1

        if chain[j] != "(":
            i = match.end()
            continue

        end = balanced(chain, j, "(", ")")
        yield name, targs, chain[j + 1:end - 1]
        i = end


def constructor_signatures(call, targs):
    """`void (*)(int), void (*)(const QPoint &)` or `Holder<T>, void(int)` -> [["int"], ["const QPoint &"]]"""
    signatures = []
    parts = split_top_level(targs)
    if call == "addConstructorFrom":
        parts = parts[1:]  # the first argument is the holder
    for sig in parts:
        match = re.fullmatch(r"void\s*(?:\(\*\))?\s*\((.*)\)", sig, re.DOTALL)
        if not match:
            raise SystemExit(f"unrecognised constructor signature: {sig!r}")
        signatures.append(split_top_level(match.group(1)))
    return signatures


def parse_file(path, classes, namespaces, functions, cpp_to_lua):
    source = path.read_text(encoding="utf-8")
    start = source.index('.beginNamespace("qt6")')
    chain = source[start:]

    stack = []  # open namespaces and the class being registered
    current = None
    for call, targs, args in scan_calls(chain):
        if call not in KNOWN_CALLS:
            raise SystemExit(f"{path.name}: unknown call .{call}()")

        name_match = re.match(r'\s*"([^"]*)"', args)
        name = name_match.group(1) if name_match else None

        if call == "beginNamespace":
            stack.append(name)
            if len(stack) == 2:
                namespaces.setdefault(name, {"values": [], "tables": []})
            elif len(stack) == 3:
                namespaces[stack[1]]["tables"].append(name)
        elif call == "endNamespace":
            stack.pop()
        elif call in ("beginClass", "deriveClass"):
            if current is not None:
                raise SystemExit(f"{path.name}: {name}: the previous class was not closed")
            template = split_top_level(targs)
            cpp_type, bases = template[0], template[1:]
            current = {
                "name": name, "cpp": cpp_type, "bases": [cpp_to_lua.get(b, b) for b in bases],
                "ctors": [], "methods": [], "statics": [], "properties": [],
            }
            cpp_to_lua[cpp_type] = name
        elif call == "endClass":
            classes.append(current)
            current = None
        elif current is None:
            # Namespace level
            if call == "addFunction":
                functions.append(".".join(stack[1:] + [name]))
            elif call == "addProperty" and len(stack) == 2:
                namespaces[stack[1]]["values"].append(name)
            elif call == "addProperty" and len(stack) == 3:
                pass  # the values of an enum table repeat those of the namespace
            else:
                raise SystemExit(f"{path.name}: .{call}() outside of a class")
        elif call in ("addConstructor", "addConstructorFrom"):
            current["ctors"].extend(constructor_signatures(call, targs))
        elif call == "addFunction":
            current["methods"].append(name)
        elif call == "addStaticFunction":
            current["statics"].append(name)
        elif call == "addStaticProperty":
            current["properties"].append(name)
        # addIndexMetaMethod: nothing to record
    if current is not None:
        raise SystemExit(f"{path.name}: {current['name']} was not closed")


def lua_string(value):
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def lua_list(values):
    return "{" + ", ".join(lua_string(v) for v in values) + "}"


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)

    generated, output = Path(sys.argv[1]), Path(sys.argv[2])
    files = sorted(generated.glob("qt6_*_p[0-9]*.cpp"), key=lambda p: (p.stem.rsplit("_p", 1)[0], int(p.stem.rsplit("_p", 1)[1])))
    if not files:
        raise SystemExit(f"no generated bindings in {generated}")

    # Registration order is the order of the modules in register_qt6(): bases come first
    register = (generated / "qt6_register.cpp").read_text(encoding="utf-8")
    order = re.findall(r"register_(qt6_\w+)\(L\);", register)
    files.sort(key=lambda p: (order.index(p.stem.rsplit("_p", 1)[0]), int(p.stem.rsplit("_p", 1)[1])))

    classes, namespaces, functions, cpp_to_lua = [], {}, [], {}
    for path in files:
        parse_file(path, classes, namespaces, functions, cpp_to_lua)

    lines = ["-- Generated by gen_api_manifest.py from the tsujikiri output, do not edit.", "return {", "  classes = {"]
    for cls in classes:
        ctors = ", ".join(lua_list(c) for c in cls["ctors"])
        lines.append(
            f"    {{ name = {lua_string(cls['name'])}, cpp = {lua_string(cls['cpp'])}, bases = {lua_list(cls['bases'])}, "
            f"ctors = {{{ctors}}}, methods = {lua_list(cls['methods'])}, statics = {lua_list(cls['statics'])}, "
            f"properties = {lua_list(cls['properties'])} }},"
        )
    lines.append("  },")
    lines.append("  namespaces = {")
    for name, content in namespaces.items():
        lines.append(f"    [{lua_string(name)}] = {{ values = {lua_list(content['values'])}, tables = {lua_list(content['tables'])} }},")
    lines.append("  },")
    lines.append(f"  functions = {lua_list(functions)},")
    lines.append("}")
    output.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"{len(classes)} classes, {sum(len(c['methods']) + len(c['statics']) for c in classes)} functions -> {output}")


if __name__ == "__main__":
    main()
