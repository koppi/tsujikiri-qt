#!/usr/bin/env python3
"""Finds the members of the generated bindings that the compiler rejects.

Some Qt members cannot be bound however carefully the types are filtered (an operator Qt
deleted, a method of a class whose destructor is protected, a type LuaBridge3 cannot
convert ...). They are only found by compiling the generated code, so this tool reads the
output of the compiler, maps every error back to the member that produced it and appends it to
qt6_unbindable.txt, which tools/qt6_gen.py applies on the next run.

    cmake --build build -k 0 2> build.log       # or compile single parts with -fsyntax-only
    tools/find_unbindable.py build.log --list qt6_unbindable.txt [--dry-run]

Run it again until the build is clean: an error that breaks the parse of a statement hides
the ones after it (they are reported as `cascade` and skipped, they show up in the next round).
"""

from __future__ import annotations

import argparse
import re
import sys
from collections import defaultdict
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple

GENERATED = re.compile(r"(?P<file>[^\s:]*qt6_\w+_p\d+\.cpp):(?P<line>\d+):(?P<col>\d+):")
DIAGNOSTIC = re.compile(r"^(?P<file>[^\s:][^:]*):(?P<line>\d+):(?P<col>\d+): (?P<kind>error|fatal error): (?P<message>.*)$")

# Errors that only say "an earlier statement did not parse"
CASCADE = re.compile(r"expected primary-expression|expected .* before|request for member .* non-class type|"
                     r"missing template arguments|template argument \d+ is invalid|"
                     r"has no member named|expected unqualified-id|stray|expected .*;|"
                     r"no matching function for call to .*beginClass<<expression error>|"
                     r"type/value mismatch at argument 1")

CLASS_LINE = re.compile(r"\.(?:beginClass|deriveClass)<(?P<cls>[^,>]+(?:<[^>]*>)?[^,>]*)")
CTOR_LINE = re.compile(r"\.addConstructor(?:From)?<")
MEMBER_CAST_LINE = re.compile(r"\((?P<owner>[\w:]+)::\*\)\((?P<sig>.*)\)(?: const)?>\(&[\w:]+::(?P<name>operator[^\s,)]+|\w+)\)")
STATIC_CAST_LINE = re.compile(r"\(\*\)\((?P<sig>.*)\)>\(&(?P<owner>[\w:]+)::(?P<name>operator[^\s,)]+|\w+)\)")
OVERLOAD_LINE = re.compile(r"(?:constOverload|nonConstOverload|overload)<(?P<sig>.*)>\(&(?P<owner>[\w:]+)::(?P<name>operator[^\s,)]+|\w+)\)")
SELF_LINE = re.compile(r"->\s*decltype\(auto\)\s*\{\s*return\s+self->(?P<name>\w+)\(")
STATIC_LAMBDA_LINE = re.compile(r"return\s+(?P<owner>[\w:]+)::(?P<name>\w+)\(")
POINTER_LINE = re.compile(r"&(?P<owner>[\w:]+)::(?P<name>operator[^\s,)]+|\w+)\)?")
PROPERTY_LINE = re.compile(r"\.addStaticProperty\(\"(?P<name>\w+)\"")


def read_lines(path: Path, cache: Dict[Path, List[str]]) -> List[str]:
    if path not in cache:
        cache[path] = path.read_text(encoding="utf-8").splitlines()
    return cache[path]


def owner_class(lines: List[str], index: int) -> Optional[str]:
    """The class whose registration chain the line (0 based) belongs to."""
    for i in range(index, -1, -1):
        match = CLASS_LINE.search(lines[i])
        if match:
            return match.group("cls").strip()
        if lines[i].lstrip().startswith(".endClass()") and i != index:
            return None
    return None


def classify(lines: List[str], line_number: int) -> Optional[Tuple[str, str]]:
    """Maps a generated line to ('class', Class) or ('member', 'Class::name[(signature)]')."""
    index = line_number - 1
    text = lines[index]
    cls = owner_class(lines, index)

    if CLASS_LINE.search(text):
        return ("class", CLASS_LINE.search(text).group("cls").strip())
    if CTOR_LINE.search(text):
        return ("member", f"{cls}::<init>") if cls else None

    match = MEMBER_CAST_LINE.search(text) or STATIC_CAST_LINE.search(text) or OVERLOAD_LINE.search(text)
    if match:
        signature = match.group("sig")
        return ("member", f"{match.group('owner')}::{match.group('name')}({signature})")

    match = SELF_LINE.search(text)
    if match and cls:
        return ("member", f"{cls}::{match.group('name')}")

    match = STATIC_LAMBDA_LINE.search(text)
    if match and "addStatic" not in text and "[](" in text:
        return ("member", f"{match.group('owner')}::{match.group('name')}")

    match = POINTER_LINE.search(text)
    if match:
        return ("member", f"{match.group('owner')}::{match.group('name')}")

    match = PROPERTY_LINE.search(text)
    if match and cls:
        return ("enum", f"{cls}::{match.group('name')}")

    return None


# The constructor LuaBridge3 instantiated, as the compiler names it in the context of an error
CONSTRUCTOR = re.compile(r"constructor<(?P<cls>[\w:]+), std::tuple<(?P<args>[^<>]*(?:<[^<>]*>[^<>]*)*)>\s*>")


def normalize_type(spelling: str) -> str:
    """`const QPoint&` -> `const QPoint &`, the way tsujikiri prints a type."""
    text = re.sub(r"\s*([&*]+)", r" \1", spelling.strip())
    return re.sub(r"\s+", " ", text)


def split_arguments(text: str) -> List[str]:
    parts, depth, current = [], 0, []
    for ch in text:
        depth += ch in "<(["
        depth -= ch in ">)]"
        if ch == "," and depth == 0:
            parts.append("".join(current).strip())
            current = []
        else:
            current.append(ch)
    tail = "".join(current).strip()
    return parts + [tail] if tail else parts


def parse_log(log: str):
    """Yields (message, generated file, generated line, source line of the diagnostic, text of the diagnostic block)."""
    block_refs: List[Tuple[str, int]] = []
    block_text: List[str] = []
    for raw in log.splitlines():
        diag = DIAGNOSTIC.match(raw)
        if diag:
            refs = list(block_refs)
            if "qt6_" in diag.group("file") and GENERATED.match(raw):
                refs.append((diag.group("file"), int(diag.group("line"))))
            text = "\n".join(block_text + [raw])
            block_refs, block_text = [], []
            if refs:
                yield diag.group("message"), refs[-1][0], refs[-1][1], raw, text
            continue

        block_text.append(raw)
        if len(block_text) > 60:
            block_text.pop(0)

        match = GENERATED.search(raw)
        if match and ("required from" in raw or "In function" in raw or "in instantiation" in raw.lower()):
            block_refs.append((match.group("file"), int(match.group("line"))))
        elif raw and not raw.startswith((" ", "\t")) and "required from" not in raw and not match:
            if raw.endswith(":") or "In instantiation" in raw or raw.startswith("In file included"):
                continue


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("log", nargs="+", help="compiler output")
    parser.add_argument("--list", required=True, help="qt6_unbindable.txt")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    cache: Dict[Path, List[str]] = {}
    found: Dict[str, Set[str]] = defaultdict(set)
    unknown: List[str] = []
    cascades = 0

    for log_path in args.log:
        log = Path(log_path).read_text(encoding="utf-8", errors="replace")
        for message, file, line, raw, block in parse_log(log):
            if CASCADE.search(message):
                cascades += 1
                continue

            # A constructor LuaBridge3 could not instantiate names its signature: drop that one
            constructor = CONSTRUCTOR.search(block)
            if constructor:
                types = [normalize_type(a) for a in split_arguments(constructor.group("args"))]
                found["member"].add(f"{constructor.group('cls')}::<init>({', '.join(types)})")
                continue

            path = Path(file)
            if not path.exists():
                unknown.append(f"{raw}")
                continue

            result = classify(read_lines(path, cache), line)
            if result is None:
                unknown.append(f"{path.name}:{line}: {message}\n    {read_lines(path, cache)[line - 1].strip()}")
                continue

            kind, name = result
            found[kind].add(name)

    list_path = Path(args.list)
    existing = set()
    if list_path.exists():
        existing = {l.split("#", 1)[0].strip() for l in list_path.read_text(encoding="utf-8").splitlines()}

    # A precise constructor entry (the copy constructor of a class that cannot be copied) beats the wildcard
    # the same errors produce for the class: the other constructors are fine
    precise = {name.split("::<init>(")[0] for name in found["member"] if "::<init>(" in name}
    found["member"] = {name for name in found["member"] if not (name.endswith("::<init>") and name[: -len("::<init>")] in precise)}

    new_entries = []
    for kind in ("class", "member"):
        for name in sorted(found[kind]):
            entry = f"class {name}" if kind == "class" else name
            if entry not in existing:
                new_entries.append(entry)

    print(f"{cascades} follow-on errors skipped, {len(new_entries)} new entries, {len(unknown)} errors not understood")
    for entry in new_entries:
        print(f"  + {entry}")
    for kind in ("enum",):
        for name in sorted(found[kind]):
            print(f"  ! enum value that does not compile: {name}")
    for item in unknown[:60]:
        print(f"  ? {item}")

    if new_entries and not args.dry_run:
        with list_path.open("a", encoding="utf-8") as out:
            for entry in new_entries:
                out.write(entry + "\n")

    return 0


if __name__ == "__main__":
    sys.exit(main())
