#!/usr/bin/env python3
"""Generate the LuaBridge3 bindings of one Qt module with tsujikiri.

This is a thin driver around upstream tsujikiri: it registers a few Qt specific
transform stages (see QtBindingsStage), runs the normal tsujikiri command line and
then splits the single generated file into several translation units, so the
(very template heavy) LuaBridge3 code compiles in parallel and in bounded memory.

    qt6_gen.py --input qt6_core.input.yml --parts 6 --outdir <dir>

writes <dir>/qt6_core.cpp, which defines register_qt6_core(lua_State*), and
<dir>/qt6_core_p0.cpp ... qt6_core_p5.cpp, which hold the class registrations.
"""

from __future__ import annotations

import argparse
import re
import sys
import tempfile
from pathlib import Path
from typing import Iterable, Iterator, List, Optional, Set

import clang.cindex as clang_cindex
from tsujikiri import cli as tsujikiri_cli
from tsujikiri import parser as tsujikiri_parser
from tsujikiri.ir import IRCodeInjection
from tsujikiri.tir import TIRClass, TIRConstructor, TIRFunction, TIRMethod, TIRModule, TIRParameter
from tsujikiri.transforms import TransformStage, register_stage

# ----------------------------------------------------------------------------------------
# Fully qualified type names
# ----------------------------------------------------------------------------------------
#
# tsujikiri takes parameter types from the source tokens and the other types from the type
# spelling as written, so a member of QDir declared as `Filters` is emitted as `Filters`, which
# means nothing outside of the class. Qt scopes almost everything (enums, flags, nested
# classes), so use libclang's canonical spelling instead: it is fully qualified and it also
# resolves aliases (QStringList is QList<QString>, Qt::Alignment is QFlags<Qt::AlignmentFlag>).

_spelling_getter = clang_cindex.Type.spelling.fget


def _canonical_spelling(self) -> str:
    return _spelling_getter(self.get_canonical())


clang_cindex.Type.spelling = property(_canonical_spelling)  # type: ignore[assignment]


def _canonical_type_from_tokens(cursor, tokens=None) -> str:
    return tsujikiri_parser._normalize_type_spelling(cursor.type.spelling)


tsujikiri_parser._type_from_tokens = _canonical_type_from_tokens  # type: ignore[assignment]

# Things the parser gets wrong for Qt, fixed around its class parsing:
#  * an explicit template specialization (QTypeInfo<int>) is reported as a class with the name
#    of the template; there is nothing to bind there, so it is marked;
#  * a class that is declared inside another one and defined outside of it
#    (QMetaObject::Connection) is reported as a global class `Connection`;
#  * the declaration of such a class inside the other one is reported as a second, empty class;
#  * it only counts the pure virtual methods a class declares itself, not the inherited ones;
#  * it does not know `void f() const &`, which LuaBridge3 cannot bind.
SPECIALIZATION = "qt6:specialization"
UNLINKED = "qt6:unlinked"  # needs a symbol the library the bindings are linked against does not define
ABSENT = "qt6:absent"  # none of the class's out-of-line members is defined: the class is not in the library
DECLARATION = "qt6:declaration"
LVALUE_QUALIFIED = "qt6:lvalue"  # void f() &,  void f() const &
RVALUE_QUALIFIED = "qt6:rvalue"  # void f() &&
_RECORD_CURSORS = (clang_cindex.CursorKind.CLASS_DECL, clang_cindex.CursorKind.STRUCT_DECL)
_parse_class = tsujikiri_parser._parse_class

# The (mangled) names of the functions the bindings can link against, one per line, or None when
# everything is available (a build against a full Qt). Set by --symbols; see _mark_linkage().
LINKABLE_SYMBOLS: Optional[Set[str]] = None


def _parse_class_qt(cursor, namespace, parent_name=None):
    if parent_name is None:
        parent = cursor.semantic_parent
        if parent is not None and parent.kind in _RECORD_CURSORS:
            parent_name = tsujikiri_parser._normalize_type_spelling(parent.type.get_canonical().spelling)

    ir_class = _parse_class(cursor, namespace, parent_name)

    if "<" in cursor.type.spelling:
        ir_class.attributes = list(ir_class.attributes) + [SPECIALIZATION]
    if not cursor.is_definition():
        ir_class.attributes = list(ir_class.attributes) + [DECLARATION]

    # The parser only looks at the pure virtual methods the class declares itself
    if cursor.is_definition() and cursor.is_abstract_record():
        ir_class.is_abstract = True

    _mark_ref_qualified_methods(cursor, ir_class)
    if LINKABLE_SYMBOLS is not None and cursor.is_definition():
        _mark_linkage(cursor, ir_class)
    return ir_class


def _mark_ref_qualified_methods(cursor, ir_class) -> None:
    """LuaBridge3 cannot take the address of `void f() const &`, the stage binds those with a lambda."""
    kinds = clang_cindex.RefQualifierKind
    qualified = {}
    for child in cursor.get_children():
        if child.kind != clang_cindex.CursorKind.CXX_METHOD:
            continue
        qualifier = child.type.get_ref_qualifier()
        if qualifier in (kinds.LVALUE, kinds.RVALUE):
            types = tuple(tsujikiri_parser._normalize_type_spelling(a.type.spelling) for a in child.get_arguments())
            qualified[(child.spelling, types, child.is_const_method())] = (
                LVALUE_QUALIFIED if qualifier == kinds.LVALUE else RVALUE_QUALIFIED
            )

    if not qualified:
        return
    for method in ir_class.methods:
        mark = qualified.get((method.name, tuple(p.type_spelling for p in method.parameters), method.is_const))
        if mark:
            method.attributes = list(method.attributes) + [mark]


_SOURCES: dict = {}
_BODY = re.compile(rb"\s*(?:\{|:(?!:)|try\b|=\s*(?:default|delete)\b)")


def _needs_no_symbol(cursor) -> bool:
    """A body written in the class. tsujikiri skips function bodies, and the cursor of such a member is neither a
    definition nor has a definition; what follows the declarator tells: `{`, the `:` of constructor initializers,
    `= default`, `= delete`."""
    end = cursor.extent.end
    if end.file is None:
        return False
    data = _SOURCES.get(end.file.name)
    if data is None:
        data = _SOURCES[end.file.name] = Path(end.file.name).read_bytes()
    return _BODY.match(data, end.offset) is not None


_DEFINED_OUTSIDE: dict = {}


def _defined_outside_class(tu) -> set:
    """Mangled names of the members whose body is written after the class (`inline QRect QRect::united(...) { ... }`).

    The declaration in the class has no definition to find while bodies are skipped (a constexpr body is the one
    kind that is not skipped), but the definition is a cursor of its own in the translation unit."""
    key = tu.spelling
    if key in _DEFINED_OUTSIDE:
        return _DEFINED_OUTSIDE[key]

    kinds = clang_cindex.CursorKind
    names: set = set()

    def visit(parent) -> None:
        for child in parent.get_children():
            if child.kind in (kinds.NAMESPACE, kinds.LINKAGE_SPEC):
                visit(child)
            elif child.kind in (kinds.CXX_METHOD, kinds.CONSTRUCTOR, kinds.DESTRUCTOR):
                lexical = child.lexical_parent
                if lexical is not None and lexical.kind not in (kinds.CLASS_DECL, kinds.STRUCT_DECL) and _needs_no_symbol(child):
                    names.add(child.mangled_name)

    visit(tu.cursor)
    _DEFINED_OUTSIDE[key] = names
    return names


def _is_linkable(cursor) -> Optional[bool]:
    """Whether calling `cursor` links: None if it needs no symbol at all (defined in the header, pure virtual, deleted)."""
    if cursor.is_pure_virtual_method():
        return None
    if cursor.get_definition() is not None or _needs_no_symbol(cursor):
        return None
    name = cursor.mangled_name
    if not name or name in _defined_outside_class(cursor.translation_unit):
        return None
    assert LINKABLE_SYMBOLS is not None
    if name in LINKABLE_SYMBOLS:
        return True
    # The compiler emits the complete (C1/D1) and base (C2/D2) constructor and destructor as aliases of one body
    for complete, base in (("C1", "C2"), ("D1", "D2")):
        if complete in name:
            return name.replace(complete, base) in LINKABLE_SYMBOLS
    return False


def _mark_linkage(cursor, ir_class) -> None:
    """Marks what a build against a *partial* Qt cannot call.

    The bindings take the address of (or call) every member they register, so each member that is
    declared in a header and defined in a source file has to be in the library the bindings are
    linked against. `LINKABLE_SYMBOLS` lists what that library defines. A member that is not there is
    marked UNLINKED, and a class none of whose out-of-line members is there (so it was not compiled
    into the library at all) is marked ABSENT.
    """
    kinds = clang_cindex.CursorKind
    access = clang_cindex.AccessSpecifier
    outside = defined = 0
    unlinked_methods = {}
    unlinked_ctors = set()

    for child in cursor.get_children():
        if child.kind not in (kinds.CXX_METHOD, kinds.CONSTRUCTOR, kinds.DESTRUCTOR) or child.access_specifier == access.PRIVATE:
            continue
        linkable = _is_linkable(child)
        if linkable is None:
            continue
        outside += 1
        if linkable:
            defined += 1
            continue
        types = tuple(tsujikiri_parser._normalize_type_spelling(a.type.spelling) for a in child.get_arguments())
        if child.kind == kinds.CXX_METHOD and not child.is_virtual_method():
            unlinked_methods[(child.spelling, types, child.is_const_method())] = True
        elif child.kind == kinds.CONSTRUCTOR:
            unlinked_ctors.add(types)
        elif child.kind == kinds.DESTRUCTOR:
            # A class that cannot be destroyed cannot be held by a Lua value
            outside, defined = 1, 0
            break

    if outside and not defined:
        ir_class.attributes = list(ir_class.attributes) + [ABSENT]
        return

    for method in ir_class.methods:
        if (method.name, tuple(p.type_spelling for p in method.parameters), method.is_const) in unlinked_methods:
            method.attributes = list(method.attributes) + [UNLINKED]
    for ctor in ir_class.constructors:
        if tuple(p.type_spelling for p in ctor.parameters) in unlinked_ctors:
            ctor.attributes = list(ctor.attributes) + [UNLINKED]


tsujikiri_parser._parse_class = _parse_class_qt  # type: ignore[assignment]

# The classes that are not in the library (ABSENT), as one pattern; filled in by the qt6 stage
ABSENT_TYPES: Optional[re.Pattern] = None

# ----------------------------------------------------------------------------------------
# Which C++ types the support layer (support/qt6_lua.h) and LuaBridge3 can convert
# ----------------------------------------------------------------------------------------

# Class templates with a Stack<> specialization (LuaBridge3's or ours); the elements are
# checked by the compiler, see tools/find_unbindable.py.
_SUPPORTED_TEMPLATES = {
    "QList", "QVector", "QSet", "QMap", "QHash", "QFlags", "QUrlTwoFlags", "QPair",
    "std::pair", "std::optional", "std::vector", "std::map",
}

# Types that never convert to Lua. Matched anywhere in a parameter, return or field type.
_UNSUPPORTED_WORDS = re.compile(
    r"""
    \bQ?PrivateSignal\b | \bQ\w*Private\b | \bQtPrivate:: | \bQt::Private\b
  | \bQGenericArgument\b | \bQGenericReturnArgument\b
  | \bQMetaMethodArgument\b | \bQMetaMethodReturnArgument\b
  | \bQStringView\b | \bQLatin1StringView\b | \bQLatin1String\b | \bQStringRef\b
  | \bQArrayData\b | \bQTypedArrayData\b | \bQArrayDataPointer\b
  | \bQStringBuilder\b | \bQDebug\b | \bQNoDebug\b
  | \bQMetaObject::Data\b | \bQMetaObject::SuperData\b | \bQObjectData\b
  | \bQUntypedPropertyData\b | \bQPropertyBindingData\b | \bQBindable\w*
  | \bQPropertyBinding\w* | \bQPropertyObserver\w* | \bQPropertyNotifier\b | \bQPropertyData\w*
  | \bQSharedData\b | \bQSharedDataPointer\b | \bQExplicitlySharedDataPointer\b
  | \bQSharedPointer\b | \bQWeakPointer\b | \bQScopedPointer\b | \bQPointer\b
  | \bQFuture\w* | \bQPromise\b | \bQtFuture\b
  | \bQChar\s*\* | \bchar8_t\b | \b_IO_FILE\b | \bFILE\b
  | \bQMutex\w* | \bQReadWriteLock\b | \bQWaitCondition\b | \bQSemaphore\w* | \bQAtomic\w*
  | \bQBasicAtomic\w* | \bQBasicMutex\b
  | \bstd::(?!string\b|pair\b|optional\b|vector\b|map\b|string_view\b)
  | \bQEnableSharedFromThis\b
  | \bQtMetaTypePrivate\b | \bQtSharedPointer\b | \bQAssociativeIterable\b | \bQSequentialIterable\b
  | \bQMetaSequence\b | \bQMetaAssociation\b | \bQMetaContainer\b | \bQIterable\w*
  | \bQMetaType::\w*Function\b
    """,
    re.VERBOSE,
)

# Scalar types whose pointers/references are output parameters.
_SCALAR = (
    r"(?:bool|char|signed char|unsigned char|short|unsigned short|int|unsigned int|unsigned|long|unsigned long|"
    r"long long|unsigned long long|float|double|long double|"
    r"qint8|qint16|qint32|qint64|quint8|quint16|quint32|quint64|qintptr|quintptr|qsizetype|qptrdiff|"
    r"uchar|ushort|uint|ulong|qlonglong|qulonglong|qreal|qfloat16|size_t|ssize_t|char16_t|char32_t|wchar_t)"
)
_SCALAR_POINTER = re.compile(rf"\b{_SCALAR}\b\s*\*")
_CONVERTED_POINTER = re.compile(
    r"\b(?:QString|QByteArray|QChar|QVariant|QStringList|QVariantList|QVariantMap|QVariantHash|"
    r"QList<.*>|QMap<.*>|QHash<.*>|QSet<.*>|QFlags<.*>)\s*\*"
)
_TEMPLATE_NAME = re.compile(r"([A-Za-z_][\w:]*)\s*<")
_NONCONST_REF_TO_CONVERTED = re.compile(
    r"^(?:QString|QByteArray|QStringList|QVariant|QVariantList|QVariantMap|QVariantHash|QChar|QList<.*>|QMap<.*>|QHash<.*>|QSet<.*>)\s*&$"
)

# begin()/end() and friends hand out iterator types, Lua has the sequences of the converted containers
_ITERATION = re.compile(r"^(?:c?r?begin|c?r?end|constBegin|constEnd|constFirst|constLast)$")

# What begin() and end() return when they are not about iteration (QPainter::end() is a bool)
_PLAIN_RESULT = re.compile(r"(?:bool|void|int|long|long long|unsigned int|double|float)")

# A result that is an iterator (QJsonObject::insert returns one)
_ITERATOR_TYPE = re.compile(r"::(?:const_|reverse_|const_reverse_)?iterator\b|::(?:Const)?Iterator\b")

# Where the Lua keywords would make `obj:end()` a syntax error.
_LUA_KEYWORDS = {
    "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if", "in", "local",
    "nil", "not", "or", "repeat", "return", "then", "true", "until", "while",
}


def is_unsupported_type(spelling: str, *, is_parameter: bool = False) -> bool:
    """True when `spelling` cannot be passed to or returned to Lua."""
    t = " ".join(spelling.split())
    if ABSENT_TYPES is not None and ABSENT_TYPES.search(t):
        return True
    # rvalue references, function types/pointers, arrays, unnamed types, parameter packs
    if "&&" in t or "(" in t or "[" in t or "..." in t:
        return True
    # a member of a template instance (QList<T>::iterator) is not the template itself
    if re.search(r">\s*::", t):
        return True
    if "**" in t.replace(" ", ""):
        return True
    if re.search(r"\bvoid\s*\*", t):
        return True
    if _SCALAR_POINTER.search(t) and not re.search(r"\bconst\s+char\s*\*\s*(?:const)?$", t):
        return True
    if _UNSUPPORTED_WORDS.search(t) or _CONVERTED_POINTER.search(t):
        return True
    for name in _TEMPLATE_NAME.findall(t):
        if name not in _SUPPORTED_TEMPLATES:
            return True
    # Non-const references are out parameters: a value copy would silently lose the result.
    if is_parameter and t.endswith("&") and not t.startswith("const "):
        base = t[:-1].strip()
        if re.fullmatch(_SCALAR, base):
            return True
        if _NONCONST_REF_TO_CONVERTED.match(t):
            return True
    return False


def camel_to_snake(name: str) -> str:
    s1 = re.sub("(.)([A-Z][a-z]+)", r"\1_\2", name)
    return re.sub("([a-z0-9])([A-Z])", r"\1_\2", s1).lower()


# ----------------------------------------------------------------------------------------
# IR helpers
# ----------------------------------------------------------------------------------------


def walk_classes(classes: Iterable[TIRClass]) -> Iterator[TIRClass]:
    for cls in classes:
        yield cls
        yield from walk_classes(cls.inner_classes)  # type: ignore[arg-type]


def method_signature(owner: str, name: str, params: Iterable) -> str:
    return f"{owner}::{name}({', '.join(p.type_spelling for p in params)})"


def load_signature_list(path: Optional[str]) -> Set[str]:
    """One signature per line (`QFoo::bar(int, const QString &)`), `#` starts a comment."""
    if not path:
        return set()
    entries = set()
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            entries.add(line)
    return entries


# ----------------------------------------------------------------------------------------
# The Qt stage
# ----------------------------------------------------------------------------------------


# The classes the last run bound, for the pointer specializations (tools/qt6_pointers.py)
BOUND_CLASSES: List[str] = []


class QtBindingsStage(TransformStage):
    """Applies everything that is specific to Qt, in the order that matters.

    YAML::

      stage: qt6
      source: "/QtCore/"          # regex searched in the declaring header's path
      namespaces: ["", "QTest"]   # namespaces whose classes are bound
      enums: ["Qt::.*"]           # namespace level enums (regex on the qualified name)
      functions: ["QTest::.*"]    # namespace level functions (regex on the qualified name)
      holder: "qt6::QtOwned"      # container for QObject derived classes
      leaked: ["QStandardItem"]   # classes (and what derives from them) Qt takes over, Lua never deletes them
      unbindable: path/to/list    # signatures the compiler rejected (tools/find_unbindable.py), or a list of such files
      compact_enums: false        # register enum values from tables (qt6::addClassEnum), not one lambda per value
    """

    name = "qt6"

    def __init__(self, **kwargs) -> None:
        self.source = re.compile(kwargs["source"])
        self.namespaces: List[str] = kwargs.get("namespaces", [""])
        self.enums = [re.compile(p) for p in kwargs.get("enums", [])]
        self.functions = [re.compile(p) for p in kwargs.get("functions", [])]
        self.holder: str = kwargs.get("holder", "qt6::QtOwned")
        self.leaked_holder: str = kwargs.get("leaked_holder", "qt6::QtLeaked")
        self.enum_names: Set[str] = set()
        self.leaked: Set[str] = set(kwargs.get("leaked", []))
        self.compact_enums: bool = bool(kwargs.get("compact_enums", False))
        entries: Set[str] = set()
        listed = kwargs.get("unbindable") or []
        for path in [listed] if isinstance(listed, str) else listed:
            entries |= load_signature_list(path)
        self.unbindable_classes = {e[len("class "):] for e in entries if e.startswith("class ")}
        self.unbindable = {e for e in entries if not e.startswith("class ")}

    # -- steps ------------------------------------------------------------------------

    def apply(self, module: TIRModule) -> None:
        self._matched = True
        by_name = {c.qualified_name: c for c in walk_classes(module.classes)}  # type: ignore[arg-type]

        # What the normal filters (class blacklist, system header exclusion) already dropped
        # belongs to nobody. Everything dropped from here on may still be bound by another module.
        self._absent(by_name)
        blacklisted = {q for q, c in by_name.items() if not c.emit}

        for qualified in self.unbindable_classes:
            if qualified in by_name:
                by_name[qualified].emit = False
                blacklisted.add(qualified)

        for cls in walk_classes(module.classes):  # type: ignore[arg-type]
            if SPECIALIZATION in cls.attributes or DECLARATION in cls.attributes:
                cls.emit = False

        self.enum_names = {e.qualified_name for e in module.enums}
        for cls in walk_classes(module.classes):  # type: ignore[arg-type]
            self.enum_names.update(e.qualified_name for e in cls.enums)

        self._scope(module)
        self._enums(module)
        self._functions(module)
        for cls in walk_classes(module.classes):  # type: ignore[arg-type]
            if cls.emit:
                self._members(cls)
        self._policy(module, by_name, blacklisted)
        if self.compact_enums:
            self._compact_enums(module)

    @staticmethod
    def _absent(by_name: dict) -> None:
        """Classes the library does not contain are no bindings, and no type of a member either (--symbols)."""
        global ABSENT_TYPES
        absent = sorted((q for q, c in by_name.items() if ABSENT in c.attributes), key=len, reverse=True)
        ABSENT_TYPES = None
        if not absent:
            return
        for qualified in absent:
            by_name[qualified].emit = False
        # `QUrl` is a class, `QUrl::ParsingMode` an enumeration declared in it: that needs no symbol
        names = "|".join(re.escape(q) for q in absent)
        ABSENT_TYPES = re.compile(rf"(?<![\w:])(?:{names})(?![\w])(?!\s*::)")

    def _compact_enums(self, module: TIRModule) -> None:
        """Enum values are data: one table per enum and one call that registers it, instead of a lambda
        and a LuaBridge3 property for every value (the values of Qt's enums are most of what is registered:
        QLocale alone has 900 of them). The template skips an enum that is not emitted.

        The values are the ones libclang computed, so the registration is code that cannot fail to compile.
        """

        def table(enum) -> str:
            values = ", ".join(f'{{"{v.binding_name}", {v.value}LL}}' for v in enum.values if v.emit)
            return f"static const qt6::EnumValue values[] = {{{values}}}; "

        for enum in module.enums:
            if not enum.emit or not any(v.emit for v in enum.values):
                continue
            namespace = "_".join(enum.qualified_name.split("::")[:-1])
            call = f'qt6::addNamespaceEnum(L, "{namespace}", "{enum.binding_name}", values, {sum(1 for v in enum.values if v.emit)});'
            module.code_injections.append(IRCodeInjection(position="end", code=f"{{ {table(enum)}{call} }}"))
            enum.emit = False

        for cls in walk_classes(module.classes):  # type: ignore[arg-type]
            if not cls.emit:
                continue
            for enum in cls.enums:
                if not enum.emit or not any(v.emit for v in enum.values):
                    continue
                unscoped = "false" if enum.is_scoped else "true"
                call = f'qt6::addClassEnum(L, "{cls.rename or cls.name}", "{enum.binding_name}", {unscoped}, values, {sum(1 for v in enum.values if v.emit)});'
                module.code_injections.append(IRCodeInjection(position="end", code=f"{{ {table(enum)}{call} }}"))
                enum.emit = False

    def _in_scope(self, cls: TIRClass) -> bool:
        return bool(self.source.search((cls.source_file or "").replace("\\", "/"))) and (
            cls.namespace in self.namespaces
        )

    def _scope(self, module: TIRModule) -> None:
        def suppress(cls: TIRClass) -> None:
            cls.emit = False
            for inner in cls.inner_classes:
                suppress(inner)  # type: ignore[arg-type]

        for cls in module.classes:
            if cls.emit and not self._in_scope(cls):  # type: ignore[arg-type]
                suppress(cls)  # type: ignore[arg-type]

    def _enums(self, module: TIRModule) -> None:
        for enum in module.enums:
            enum.emit = (
                enum.emit
                and not enum.is_anonymous
                and bool(enum.values)
                and any(p.fullmatch(enum.qualified_name) for p in self.enums)
            )
        for cls in walk_classes(module.classes):  # type: ignore[arg-type]
            for enum in cls.enums:
                if enum.is_anonymous or not enum.values:
                    enum.emit = False

    def _functions(self, module: TIRModule) -> None:
        for fn in module.functions:
            fn.emit = (
                fn.emit
                and not fn.is_operator
                and not fn.is_deprecated
                and any(p.fullmatch(fn.qualified_name) for p in self.functions)
            )
            if not fn.emit:
                continue

            returned, drop_return = self._return_policy(fn.return_type)
            usable = self._usable_parameters(fn.parameters)
            owner = fn.qualified_name.rsplit("::", 1)[0] if "::" in fn.qualified_name else ""
            if not returned or usable is None:
                fn.emit = False
                continue

            truncated = len(usable) != len(fn.parameters)
            fn.parameters = usable  # type: ignore[assignment]
            if self._listed(owner, fn.name, fn.parameters):
                fn.emit = False
                continue

            if truncated or drop_return:
                params = ", ".join(f"{p.type_spelling} p{i}" for i, p in enumerate(fn.parameters))
                args = ", ".join(f"p{i}" for i in range(len(fn.parameters)))
                call = f"{fn.qualified_name}({args})"
                fn.wrapper_code = (
                    f"[]({params}) -> void {{ {call}; }}" if drop_return else f"[]({params}) -> decltype(auto) {{ return {call}; }}"
                )
            else:
                types = ", ".join(p.type_spelling for p in fn.parameters)
                fn.wrapper_code = f"static_cast<{fn.return_type} (*)({types})>(&{fn.qualified_name})"

    @staticmethod
    def _return_policy(spelling: str):
        """(can be returned, return value is dropped). An iterator is of no use in Lua, but insert() should still insert."""
        if _ITERATOR_TYPE.search(spelling):
            return True, True
        return (not is_unsupported_type(spelling)), False

    @staticmethod
    def _usable_parameters(parameters):
        """The parameters as Lua can pass them: all, or without a defaulted tail it cannot (`bool *ok = nullptr`). None if impossible."""
        for index, parameter in enumerate(parameters):
            if is_unsupported_type(parameter.type_spelling, is_parameter=True):
                if all(tail.default_value for tail in parameters[index:]):
                    return list(parameters[:index])
                return None
        return list(parameters)

    def _members(self, cls: TIRClass) -> None:
        owner = cls.qualified_name

        for method in cls.methods:
            if not method.emit:
                continue
            if method.is_conversion_operator and method.conversion_target_type == "bool" and not method.is_deprecated:
                # `if (result)` has no Lua equivalent: result:to_bool()
                method.is_operator = False
                method.operator_type = None
                method.is_conversion_operator = False
                method.rename = "to_bool"

            if (
                RVALUE_QUALIFIED in method.attributes
                or UNLINKED in method.attributes
                or method.is_deprecated
                or method.is_varargs
                or method.is_conversion_operator
                or (_ITERATION.match(method.name) and not _PLAIN_RESULT.fullmatch(method.return_type))
            ):
                method.emit = False
                continue

            returned, drop_return = self._return_policy(method.return_type)
            usable = self._usable_parameters(method.parameters)
            if not returned or usable is None:
                method.emit = False
                continue

            truncated = len(usable) != len(method.parameters)
            method.parameters = usable  # type: ignore[assignment]
            if self._listed(owner, method.name, method.parameters):
                method.emit = False
                continue

            if method.binding_name in _LUA_KEYWORDS or camel_to_snake(method.name) in _LUA_KEYWORDS:
                method.rename = method.name + "_"

            method.wrapper_code = self._method_pointer(owner, method, as_lambda=truncated, drop_return=drop_return)

        self._enums_first(cls)

        for ctor in cls.constructors:
            if not ctor.emit:
                continue
            usable = self._usable_parameters(ctor.parameters)
            if ctor.is_deleted or ctor.is_deprecated or ctor.is_varargs or usable is None or UNLINKED in ctor.attributes:
                ctor.emit = False
                continue

            ctor.parameters = usable  # type: ignore[assignment]
            if self._listed(owner, "<init>", ctor.parameters):
                ctor.emit = False

        # Public data members are not bound, read them through the accessors
        for fld in cls.fields:
            fld.emit = False

    def _enums_first(self, cls: TIRClass) -> None:
        """LuaBridge3 takes the first overload whose parameter types accept the arguments, and a number is an int and an enum
        alike. C++ tells QHostAddress(QHostAddress::LocalHost) from QHostAddress(quint32) by the type, Lua cannot; the
        constant is what a script passes, so the overloads with enums come first."""

        def enums(parameters) -> int:
            return sum(1 for p in parameters if p.type_spelling in self.enum_names or p.type_spelling.startswith(("QFlags<", "const QFlags<")))

        order: dict = {}
        for method in cls.methods:
            order.setdefault((method.name, method.is_static), len(order))
        cls.methods.sort(key=lambda m: (order[(m.name, m.is_static)], -enums(m.parameters)))  # stable
        cls.constructors.sort(key=lambda c: -enums(c.parameters))

    @staticmethod
    def _method_pointer(owner: str, method: TIRMethod, *, as_lambda: bool = False, drop_return: bool = False) -> str:
        """The expression LuaBridge3 is given for a method.

        `&Class::name` fails when the class has a function template of the same name (an overload
        set with a template cannot be deduced) and for `f() const &`. A cast to the exact type
        works around the first, a lambda around the second. A lambda is also what calls a method
        with fewer arguments than it has (the ones Lua cannot pass keep their defaults) and what
        throws away a return value that is of no use in Lua.
        """
        types = ", ".join(p.type_spelling for p in method.parameters)

        if as_lambda or drop_return or LVALUE_QUALIFIED in method.attributes:
            params = "".join(f"{', ' if i or not method.is_static else ''}{p.type_spelling} p{i}" for i, p in enumerate(method.parameters))
            args = ", ".join(f"p{i}" for i in range(len(method.parameters)))
            result = "void" if drop_return else "decltype(auto)"
            if method.is_static:
                call = f"{owner}::{method.spelling}({args})"
                return f"[]({params.lstrip(', ')}) -> {result} {{ {'' if drop_return else 'return '}{call}; }}"

            const = "const " if method.is_const else ""
            call = f"self->{method.spelling}({args})"
            return f"[]({const}{owner}* self{params}) -> {result} {{ {'' if drop_return else 'return '}{call}; }}"

        if method.is_static:
            return f"static_cast<{method.return_type} (*)({types})>(&{owner}::{method.spelling})"

        const = " const" if method.is_const else ""
        return f"static_cast<{method.return_type} ({owner}::*)({types}){const}>(&{owner}::{method.spelling})"

    def _copy_constructor(self, cls: TIRClass) -> None:
        """tsujikiri lists the constructors the class declares, and QPoint(point) is not among them."""
        if cls.is_abstract or cls.has_deleted_copy_constructor or cls.copyable is False:
            return

        copy = f"const {cls.qualified_name} &"
        if any(len(c.parameters) == 1 and c.parameters[0].type_spelling in (copy, f"{cls.qualified_name} &&") for c in cls.constructors if c.emit):
            return
        if cls.qualified_name in ("QFlag", "QIncompatibleFlag"):
            return

        parameter = TIRParameter(name="other", type_spelling=copy)
        if self._listed(cls.qualified_name, "<init>", [parameter]):
            return
        cls.constructors.append(TIRConstructor(parameters=[parameter]))  # type: ignore[list-item]

    def _shadowed_statics(self, module: TIRModule, by_name: dict) -> None:
        """LuaBridge3 finds the instance methods of a class before its static functions, so QFile.exists(path)
        would call file:exists(). Such a static is bound as `name__static` and put in place of the hidden one
        when the registration is done (qt6::aliasStatic)."""

        def instance_names(cls: TIRClass, seen: Set[str]) -> Set[str]:
            if cls.qualified_name in seen:
                return set()
            seen.add(cls.qualified_name)
            names = {camel_to_snake(m.binding_name) for m in cls.methods if m.emit and not m.is_static}
            for base in cls.bases:
                if base.qualified_name in by_name:
                    names |= instance_names(by_name[base.qualified_name], seen)
            return names

        for cls in walk_classes(module.classes):  # type: ignore[arg-type]
            if not cls.emit:
                continue
            statics = {camel_to_snake(m.binding_name) for m in cls.methods if m.emit and m.is_static}
            if not statics:
                continue
            hidden = statics & instance_names(cls, set())
            for method in cls.methods:
                if method.emit and method.is_static and camel_to_snake(method.binding_name) in hidden:
                    method.rename = method.binding_name + "__static"
            for name in sorted(hidden):
                module.code_injections.append(
                    IRCodeInjection(position="end", code=f'qt6::aliasStatic(L, "{cls.rename or cls.name}", "{name}");')
                )

    def _listed(self, owner: str, name: str, parameters) -> bool:
        """`Owner::name` drops every overload, `Owner::name(types)` exactly one."""
        return f"{owner}::{name}" in self.unbindable or method_signature(owner, name, parameters) in self.unbindable

    def _policy(self, module: TIRModule, by_name: dict, blacklisted: Set[str]) -> None:
        qobject_derived: dict = {}

        def derives_from_qobject(qname: str, seen: Set[str]) -> bool:
            if qname == "QObject":
                return True
            if qname in qobject_derived:
                return qobject_derived[qname]
            cls = by_name.get(qname)
            result = False
            if cls is not None and qname not in seen:
                seen.add(qname)
                result = any(derives_from_qobject(b.qualified_name, seen) for b in cls.bases)
            qobject_derived[qname] = result
            return result

        leaked_cache: dict = {}

        def is_leaked(qname: str, seen: Set[str]) -> bool:
            if qname in self.leaked:
                return True
            if qname in leaked_cache:
                return leaked_cache[qname]
            cls = by_name.get(qname)
            result = False
            if cls is not None and qname not in seen:
                seen.add(qname)
                result = any(is_leaked(b.qualified_name, seen) for b in cls.bases)
            leaked_cache[qname] = result
            return result

        for cls in walk_classes(module.classes):  # type: ignore[arg-type]
            # Nested classes share one flat Lua namespace: QFoo::Bar becomes QFoo_Bar
            if "::" in cls.qualified_name:
                cls.rename = cls.qualified_name.replace("::", "_")

            for base in cls.bases:
                target = by_name.get(base.qualified_name)
                if "<" in base.qualified_name or target is None or base.qualified_name in blacklisted:
                    base.emit = False

            if not cls.emit:
                continue

            if cls.is_abstract:
                cls.force_abstract = True

            if not any(m.emit and m.name == "operator==" for m in cls.methods):
                cls.code_injections.append(
                    IRCodeInjection(position="end", code=f".addFunction(\"__eq\", &qt6::equals<{cls.qualified_name}>)")
                )

            if is_leaked(cls.qualified_name, set()):
                cls.holder_type = self.leaked_holder
            elif derives_from_qobject(cls.qualified_name, set()):
                cls.holder_type = self.holder
            else:
                self._copy_constructor(cls)


        self._shadowed_statics(module, by_name)

        BOUND_CLASSES.clear()
        BOUND_CLASSES.extend(sorted({c.qualified_name for c in walk_classes(module.classes) if c.emit}))  # type: ignore[arg-type]


register_stage(QtBindingsStage.name, QtBindingsStage)


# ----------------------------------------------------------------------------------------
# Splitting the generated file
# ----------------------------------------------------------------------------------------

_CLASS_MARKER = re.compile(r"^//@@CLASS (\S+)\n", re.MULTILINE)


def split_output(text: str, parts: int, module: str):
    """Returns (header, [function body per part], footer)."""
    try:
        header, rest = text.split("//@@BEGIN_BODY\n", 1)
        body, footer = rest.split("//@@END_BODY\n", 1)
    except ValueError:
        raise SystemExit("qt6_gen: the generated file lacks the //@@ markers; is qt6.output.tpl in use?")

    pieces = _CLASS_MARKER.split(body)
    preamble = pieces[0]  # namespace level enums and functions
    chunks = pieces[2::2]  # pieces alternate: preamble, name, chunk, name, chunk ...

    # Balanced by line count: one member is one line
    weights = [chunk.count("\n") + 1 for chunk in chunks]
    total = sum(weights) + preamble.count("\n")
    target = total / parts
    result: List[List[str]] = [[] for _ in range(parts)]
    result[0].append(preamble)
    acc = preamble.count("\n")
    index = 0
    for chunk, weight in zip(chunks, weights):
        while index < parts - 1 and acc >= target * (index + 1):
            index += 1
        result[index].append(chunk)
        acc += weight
    return header, ["".join(r) for r in result], footer


def write_parts(text: str, parts: int, module: str, outdir: Path) -> None:
    header, bodies, footer = split_output(text, parts, module)
    outdir.mkdir(parents=True, exist_ok=True)

    for i, body in enumerate(bodies):
        end_injection = footer if i == parts - 1 else ""
        source = (
            f"{header}\n"
            f"void {module}_p{i}(lua_State* L)\n{{\n"
            f"  luabridge::getGlobalNamespace(L)\n    .beginNamespace(\"qt6\")\n"
            f"{body}"
            f"    .endNamespace();\n"
            f"{end_injection}"
            f"}}\n"
        )
        write_if_changed(outdir / f"{module}_p{i}.cpp", source)

    calls = "".join(f"  {module}_p{i}(L);\n" for i in range(parts))
    decls = "".join(f"void {module}_p{i}(lua_State* L);\n" for i in range(parts))
    master = (
        f"// DO NOT EDIT - Auto-generated by tsujikiri (see tools/qt6_gen.py)\n"
        f"struct lua_State;\n\n{decls}\n"
        f"void register_{module}(lua_State* L)\n{{\n{calls}}}\n"
    )
    write_if_changed(outdir / f"{module}.cpp", master)


def write_if_changed(path: Path, content: str) -> None:
    """Keeps timestamps stable so the compiler does not rebuild untouched parts."""
    if path.exists() and path.read_text(encoding="utf-8") == content:
        return
    path.write_text(content, encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--input", required=True, help="tsujikiri input config of the module (qt6_<module>.input.yml)")
    parser.add_argument("--parts", type=int, required=True, help="number of translation units to split the classes into")
    parser.add_argument("--outdir", required=True)
    parser.add_argument("--formats-dir", help="directory with the qt6 output format")
    parser.add_argument("--classes-file", help="write the qualified names of the bound classes here")
    parser.add_argument("--jobs", default="1")
    parser.add_argument("--symbols", help="file with the mangled names of the functions the bindings can link against (a partial Qt)")
    args = parser.parse_args()

    if args.symbols:
        global LINKABLE_SYMBOLS
        LINKABLE_SYMBOLS = {line.strip() for line in Path(args.symbols).read_text(encoding="utf-8").splitlines() if line.strip()}

    input_path = Path(args.input)
    module = input_path.stem.replace(".input", "")
    outdir = Path(args.outdir)

    with tempfile.TemporaryDirectory(prefix="qt6_gen_") as tmp:
        generated = Path(tmp) / f"{module}.cpp"
        argv = ["tsujikiri", "--input", str(input_path), "--target", "qt6", str(generated), "--strict", "--jobs", args.jobs]
        if args.formats_dir:
            argv += ["--formats-dir", args.formats_dir]
        sys.argv = argv
        try:
            tsujikiri_cli.main()
        except SystemExit as exc:
            if exc.code not in (0, None):
                raise
        write_parts(generated.read_text(encoding="utf-8"), args.parts, module, outdir)

    if args.classes_file:
        write_if_changed(Path(args.classes_file), "".join(f"{name}\n" for name in BOUND_CLASSES))


if __name__ == "__main__":
    main()
