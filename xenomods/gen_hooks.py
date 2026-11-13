"""Instrument the game sources so that plugins can hook any routine by name.

The build copies source/ into a mirror and compiles the mirror instead. In the
mirror every routine with a body (methods, constructors, destructors and unit
routines) is split in two, without moving a single line:

    function TShip.Foo__XB12(A: Integer): Boolean;   <- the original body
    ...
    end;
    ...
    <wrappers, hook paths, invokers and descriptors of the whole unit, on the
     line where initialization (or the final end.) begins>

The wrapper keeps the original name, header and virtual slot:

    function TShip.Foo(A: Integer): Boolean;
    begin
      if XenoHkSlots[12] = nil then Result := Foo__XB12(A) else Result := Foo__XH12(A);
    end;

so an unhooked routine costs one extra check and call. Foo__XH12 hands the
arguments to XenoHookRuntime (and the plugin host), which runs the handlers
around the body. Each unit registers a descriptor per routine at
initialization; the plugin host finds hooks by "TShip.Foo" or "Unit.Routine".
Line numbers never change, so compiler messages and stack traces point to the
original sources.

    python xenomods/gen_hooks.py --out DIR [--list FILE]   # write a mirror
    python xenomods/gen_hooks.py --stats                   # parse only

Routines are left alone when wrapping them could change their meaning: inline
and external routines, nested routines, headers that contain conditional
directives, and the Xeno units themselves. xenomods/hooks_exclude.txt lists
units and routines that stay unwrapped for speed.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "source"
EXCLUDE_FILE = Path(__file__).resolve().parent / "hooks_exclude.txt"
RUNTIME_UNIT = "XenoHookRuntime"
# XENO_HOOKS_PROFILE=1: every wrapper counts its calls (see --xeno-hook-profile).
PROFILE = os.environ.get("XENO_HOOKS_PROFILE", "0") == "1"
SKIP_UNIT_PREFIX = "Xeno"

ROUTINE_WORDS = {"procedure", "function", "constructor", "destructor"}
SECTION_WORDS = {
    "type", "const", "var", "threadvar", "resourcestring", "label", "procedure", "function",
    "constructor", "destructor", "class", "begin", "initialization", "finalization",
    "implementation", "interface", "end", "uses", "exports", "operator", "asm",
}
DIRECTIVES = {
    "cdecl", "stdcall", "register", "pascal", "safecall", "winapi", "platform", "deprecated",
    "experimental", "library", "export", "external", "varargs", "inline", "assembler",
    "nostackframe", "noreturn", "overload", "forward", "static", "virtual", "override", "abstract",
    "dynamic", "reintroduce", "final", "message", "dispid", "local", "far", "near", "compilerproc",
    "interrupt", "iocheck", "unimplemented", "hardfloat", "vectorcall", "mwpascal", "oldfpccall",
    "softfloat", "saveregisters", "ms_abi_default", "sysv_abi_default", "noinline",
}
CALLING_CONVENTIONS = {"cdecl", "stdcall", "register", "pascal", "safecall", "winapi", "vectorcall",
                       "mwpascal", "oldfpccall", "softfloat", "hardfloat"}
# Directives that keep a routine as is.
UNWRAPPABLE = {"inline", "external", "forward", "abstract", "assembler", "nostackframe",
               "compilerproc", "interrupt", "varargs", "message", "noreturn"}
RESERVED = {
    "and", "array", "as", "asm", "begin", "case", "class", "const", "constructor", "destructor",
    "div", "do", "downto", "else", "end", "except", "file", "finalization", "finally", "for",
    "function", "goto", "if", "implementation", "in", "inherited", "initialization", "interface",
    "is", "label", "mod", "nil", "not", "object", "of", "on", "or", "packed", "procedure",
    "program", "property", "raise", "record", "repeat", "resourcestring", "set", "shl", "shr",
    "then", "threadvar", "to", "try", "type", "unit", "until", "uses", "var", "while", "with", "xor",
}


class ParseError(Exception):
    pass


@dataclass
class Token:
    kind: str  # ident, num, str, sym
    text: str
    start: int
    end: int
    cond: tuple
    low: str = ""

    def __post_init__(self):
        self.low = self.text.lower()


@dataclass
class Param:
    mode: str
    names: list
    type: str | None
    default: str | None

    def render(self) -> str:
        text = (self.mode + " " if self.mode else "") + ", ".join(self.names)
        if self.type is not None:
            text += ": " + self.type
        if self.default is not None:
            text += " = " + self.default
        return text


@dataclass
class Header:
    kind: str                # procedure, function, constructor, destructor
    is_class: bool
    names: list              # qualified name parts
    params: list | None      # None when the implementation omits them
    result: str | None
    directives: list         # rendered directives, e.g. ["virtual", "overload"]
    start: int               # first token index
    end: int                 # index after the final ';'
    name_tok: int            # token index of the last name part
    kind_tok: int
    has_directive: bool = False

    @property
    def dirs(self) -> set:
        return {d.split()[0].lower() for d in self.directives}

    def signature_key(self) -> tuple | None:
        if self.params is None:
            return None
        key = []
        for param in self.params:
            for _ in param.names:
                key.append((param.mode.lower(), norm(param.type)))
        return tuple(key)


@dataclass
class MethodDecl:
    header: Header
    owner: str               # class/object name
    owner_kind: str          # class or object


@dataclass
class Routine:
    header: Header
    begin_tok: int
    end_tok: int             # the closing 'end'
    semi_tok: int            # its ';'
    has_with: bool = False
    alternative: bool = False


@dataclass
class UnitInfo:
    name: str
    path: Path
    text: str
    tokens: list
    directive_spans: list
    impl_tok: int = -1
    uses_tok: int = -1       # 'uses' of the implementation section
    uses_end_tok: int = -1   # its ';'
    init_tok: int = -1       # initialization / begin of the unit body
    init_kind: str = ""
    final_tok: int = -1      # finalization
    end_dot_tok: int = -1    # 'end' of 'end.'
    interface_routines: list = field(default_factory=list)
    methods: dict = field(default_factory=dict)   # owner lower -> list[MethodDecl]
    owner_kinds: dict = field(default_factory=dict)
    routines: list = field(default_factory=list)


def norm(type_text: str | None) -> str | None:
    return None if type_text is None else re.sub(r"\s+", "", type_text).lower()


# ---------------------------------------------------------------- tokenizer

IDENT = re.compile(r"&?[A-Za-z_][A-Za-z0-9_]*")
NUMBER = re.compile(r"\$[0-9A-Fa-f]+|%[01]+|&[0-7]+|\d+(\.\d+)?([eE][+-]?\d+)?")
SYMBOLS = (":=", "..", "<=", ">=", "<>", "**", "+=", "-=", "*=", "/=")


class Conditions:
    """Tracks the conditional-compilation context as $IF expressions."""

    def __init__(self):
        self.frames: list[list[str]] = []  # each frame: branch conditions so far

    def current(self) -> tuple:
        result = []
        for frame in self.frames:
            parts = [f"not {p}" for p in frame[:-1]]
            if frame[-1] != "ELSE":
                parts.append(frame[-1])
            result.append(" and ".join(parts))
        return tuple(result)

    def directive(self, body: str):
        match = re.match(r"\s*(\w+)\s*(.*)$", body, re.S)
        if not match:
            return
        word, rest = match.group(1).upper(), match.group(2).strip()
        name = rest.split()[0] if rest.split() else ""
        if word == "IFDEF":
            self.frames.append([f"defined({name})"])
        elif word == "IFNDEF":
            self.frames.append([f"(not defined({name}))"])
        elif word == "IF":
            self.frames.append([f"({rest})"])
        elif word == "IFOPT":
            self.frames.append(["IFOPT"])
        elif word == "ELSEIF":
            if self.frames:
                self.frames[-1].append(f"({rest})")
        elif word == "ELSE":
            if self.frames:
                self.frames[-1].append("ELSE")
        elif word in ("ENDIF", "IFEND"):
            if self.frames:
                self.frames.pop()


def tokenize(text: str):
    tokens: list[Token] = []
    directives: list[tuple[int, int]] = []
    conditions = Conditions()
    cond = ()
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c in " \t\r\n\f﻿":
            i += 1
            continue
        if text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j
            continue
        if c == "{":
            j = text.find("}", i + 1)
            if j < 0:
                raise ParseError(f"unterminated comment at {i}")
            if text.startswith("{$", i):
                conditions.directive(text[i + 2:j])
                cond = conditions.current()
                directives.append((i, j + 1))
            i = j + 1
            continue
        if text.startswith("(*", i):
            j = text.find("*)", i + 2)
            if j < 0:
                raise ParseError(f"unterminated comment at {i}")
            if text.startswith("(*$", i):
                conditions.directive(text[i + 3:j])
                cond = conditions.current()
                directives.append((i, j + 2))
            i = j + 2
            continue
        if c == "'" or c == "#":
            # A string constant: 'abc', 'it''s', #13#10, 'a'#13'b'.
            j = i
            while j < n and text[j] in "'#":
                if text[j] == "'":
                    j += 1
                    while j < n:
                        if text[j] == "'":
                            if j + 1 < n and text[j + 1] == "'":
                                j += 2
                                continue
                            j += 1
                            break
                        j += 1
                else:
                    j += 1
                    m = NUMBER.match(text, j)
                    if not m:
                        raise ParseError(f"bad character constant at {i}")
                    j = m.end()
            tokens.append(Token("str", text[i:j], i, j, cond))
            i = j
            continue
        m = IDENT.match(text, i)
        if m and not (c == "&" and text[i + 1:i + 2].isdigit()):
            tokens.append(Token("ident", m.group(0).lstrip("&"), i, m.end(), cond))
            i = m.end()
            continue
        m = NUMBER.match(text, i)
        if m:
            tokens.append(Token("num", m.group(0), i, m.end(), cond))
            i = m.end()
            continue
        for symbol in SYMBOLS:
            if text.startswith(symbol, i):
                tokens.append(Token("sym", symbol, i, i + len(symbol), cond))
                i += len(symbol)
                break
        else:
            tokens.append(Token("sym", c, i, i + 1, cond))
            i += 1
    return tokens, directives


def join_tokens(tokens: list[Token]) -> str:
    out = ""
    prev = None
    for tok in tokens:
        text = tok.text
        if prev is None:
            out = text
        elif text in (",", ")", "]", ";", ".") or prev in ("(", "[", ".", "@", "^")                 or (text in ("(", "[") and (prev[-1].isalnum() or prev in (")", "]"))):
            out += text
        else:
            out += " " + text
        prev = text
    return out


# ------------------------------------------------------------------- parser

class Parser:
    def __init__(self, info: UnitInfo):
        self.u = info
        self.t = info.tokens
        self.i = 0

    # helpers
    def low(self, k: int = 0) -> str:
        j = self.i + k
        return self.t[j].low if j < len(self.t) else ""

    def text(self, k: int = 0) -> str:
        j = self.i + k
        return self.t[j].text if j < len(self.t) else ""

    def expect(self, value: str):
        if self.low() != value:
            tok = self.t[self.i] if self.i < len(self.t) else None
            line = self.u.text.count("\n", 0, tok.start) + 1 if tok else "EOF"
            raise ParseError(f"{self.u.path.name}:{line}: expected '{value}', found '{self.text()}'")
        self.i += 1

    def line(self, index: int | None = None) -> int:
        index = self.i if index is None else index
        index = min(index, len(self.t) - 1)
        return self.u.text.count("\n", 0, self.t[index].start) + 1

    def is_directive_here(self) -> bool:
        return self.low() in DIRECTIVES and self.low(1) not in (":", ",", "=")

    def skip_balanced_to_semicolon(self):
        """Skip a declaration up to its ';' (parentheses, records and classes nest)."""
        depth = 0
        while self.i < len(self.t):
            low = self.low()
            if low in ("(", "["):
                depth += 1
            elif low in (")", "]"):
                depth -= 1
            elif (low == "record" or (low == "object" and self.low(-1) != "of")) and self.t[self.i].kind == "ident":
                self.skip_block_to_end()
                continue
            elif low == "class" and self.low(1) not in ("of", ";", "(") and self.low(-1) == "=":
                self.skip_block_to_end()
                continue
            elif low == ";" and depth == 0:
                self.i += 1
                return
            self.i += 1
        raise ParseError(f"{self.u.path.name}: unexpected end of file")

    def skip_block_to_end(self):
        """At 'record'/'object'/'class': skip to its matching 'end'."""
        depth = 0
        while self.i < len(self.t):
            low = self.low()
            if low in ("record", "interface", "dispinterface") or (low == "object" and self.low(-1) != "of")                     or (low == "class" and depth == 0):
                depth += 1
            elif low == "class" and self.low(-1) == "=" and self.low(1) not in ("of", ";"):
                depth += 1
            elif low == "end":
                depth -= 1
                if depth == 0:
                    self.i += 1
                    return
            self.i += 1
        raise ParseError(f"{self.u.path.name}: unterminated record")

    def skip_directives(self) -> list:
        directives = []
        while self.is_directive_here():
            start = self.i
            while self.low() != ";":
                if self.i >= len(self.t):
                    raise ParseError("unterminated directive")
                self.i += 1
            directives.append(join_tokens(self.t[start:self.i]))
            self.i += 1
        return directives

    # headers
    def parse_params(self) -> list:
        self.expect("(")
        params = []
        while self.low() != ")":
            mode = ""
            if self.low() in ("const", "var", "out", "constref") and self.t[self.i + 1].kind == "ident" \
                    and self.low(1) not in (":", ","):
                mode = self.low()
                self.i += 1
            names = [self.text()]
            self.i += 1
            while self.low() == ",":
                self.i += 1
                names.append(self.text())
                self.i += 1
            type_text = default = None
            if self.low() == ":":
                self.i += 1
                start = self.i
                depth = 0
                while not (depth == 0 and self.low() in (";", ")", "=")):
                    if self.low() in ("(", "["):
                        depth += 1
                    elif self.low() in (")", "]"):
                        depth -= 1
                    self.i += 1
                type_text = join_tokens(self.t[start:self.i])
                if self.low() == "=":
                    self.i += 1
                    start = self.i
                    depth = 0
                    while not (depth == 0 and self.low() in (";", ")")):
                        if self.low() in ("(", "["):
                            depth += 1
                        elif self.low() in (")", "]"):
                            depth -= 1
                        self.i += 1
                    default = join_tokens(self.t[start:self.i])
            params.append(Param(mode, names, type_text, default))
            if self.low() == ";":
                self.i += 1
        self.expect(")")
        return params

    def parse_header(self) -> Header:
        start = self.i
        is_class = False
        if self.low() == "class":
            is_class = True
            self.i += 1
        kind_tok = self.i
        kind = self.low()
        self.i += 1
        names = [self.text()]
        self.i += 1
        while self.low() == ".":
            self.i += 1
            names.append(self.text())
            self.i += 1
        name_tok = self.i - 1
        params = None
        if self.low() == "(":
            params = self.parse_params()
        result = None
        if self.low() == ":":
            self.i += 1
            rstart = self.i
            while self.low() != ";":
                self.i += 1
            result = join_tokens(self.t[rstart:self.i])
        self.expect(";")
        directives = self.skip_directives()
        header = Header(kind, is_class, names, params, result, directives, start, self.i, name_tok, kind_tok)
        span_start, span_end = self.t[start].start, self.t[self.i - 1].end
        header.has_directive = any(span_start <= a < span_end for a, _ in self.u.directive_spans)
        return header

    # sections
    def parse_type_section(self, in_interface: bool):
        while self.t[self.i].kind == "ident" and self.low() not in SECTION_WORDS and self.low(1) == "=":
            name = self.text()
            self.i += 2
            if self.low() == "packed":
                self.i += 1
            if self.low() in ("class", "object") and self.low(1) not in ("of",):
                owner_kind = self.low()
                self.i += 1
                if self.low() in ("abstract", "sealed"):
                    self.i += 1
                if self.low() == "(":
                    while self.low() != ")":
                        self.i += 1
                    self.i += 1
                if self.low() == ";":  # forward or empty
                    self.i += 1
                    continue
                self.parse_class_body(name, owner_kind)
                self.expect(";")
                self.skip_directives()
            elif self.low() in ("record", "interface", "dispinterface") and self.low(1) != ";":
                self.skip_block_to_end()
                self.expect(";")
            else:
                self.skip_balanced_to_semicolon()
                self.skip_directives()

    def parse_class_body(self, owner: str, owner_kind: str):
        self.u.owner_kinds[owner.lower()] = owner_kind
        methods = self.u.methods.setdefault(owner.lower(), [])
        while self.low() != "end":
            low = self.low()
            if low in ("private", "protected", "public", "published", "strict", "automated"):
                self.i += 1
            elif low in ROUTINE_WORDS or (low == "class" and self.low(1) in ROUTINE_WORDS):
                header = self.parse_header()
                methods.append(MethodDecl(header, owner, owner_kind))
            elif low == "property" or (low == "class" and self.low(1) == "property"):
                self.skip_balanced_to_semicolon()
                while self.low() in ("default", "nodefault", "stored") and self.low(1) == ";":
                    self.i += 2
            elif low in ("var", "class") and self.low(1) == "var":
                self.i += 2 if low == "class" else 1
            elif low in ("type", "const"):
                raise ParseError(f"{self.u.path.name}:{self.line()}: nested {low} in {owner}")
            elif low == "case":
                raise ParseError(f"{self.u.path.name}:{self.line()}: variant part in {owner}")
            else:
                self.skip_balanced_to_semicolon()
                self.skip_directives()
        self.i += 1

    def skip_entries(self):
        """const/var/label entries up to the next section keyword."""
        while self.i < len(self.t) and not (self.t[self.i].kind == "ident" and self.low() in SECTION_WORDS):
            self.skip_balanced_to_semicolon()
            self.skip_directives()

    def parse_block(self):
        """Declarations of a routine followed by its statement part."""
        while True:
            low = self.low()
            if low in ("const", "var", "label", "threadvar", "resourcestring"):
                self.i += 1
                self.skip_entries()
            elif low == "type":
                self.i += 1
                self.parse_type_section(False)
            elif low in ROUTINE_WORDS or (low == "class" and self.low(1) in ROUTINE_WORDS):
                header = self.parse_header()
                if not header.dirs & {"external", "forward"}:
                    self.parse_block()
            elif low in ("begin", "asm"):
                return self.parse_statements()
            else:
                raise ParseError(f"{self.u.path.name}:{self.line()}: unexpected '{self.text()}' in a routine")

    def parse_statements(self) -> tuple[int, int, int, bool]:
        begin = self.i
        depth = 0
        has_with = False
        while self.i < len(self.t):
            low = self.low()
            if self.t[self.i].kind == "ident":
                if low in ("begin", "case", "try", "asm"):
                    depth += 1
                elif low == "with":
                    has_with = True
                elif low == "end":
                    depth -= 1
                    if depth == 0:
                        end = self.i
                        self.i += 1
                        self.expect(";")
                        return begin, end, self.i - 1, has_with
            self.i += 1
        raise ParseError(f"{self.u.path.name}: unterminated routine body")

    def parse(self):
        u = self.u
        section = "none"
        while self.i < len(self.t):
            low = self.low()
            if low == "unit":
                while self.low() != ";":
                    self.i += 1
                self.i += 1
                u.name = self.t[1].text
            elif low == "interface":
                section = "interface"
                self.i += 1
            elif low == "implementation":
                section = "implementation"
                u.impl_tok = self.i
                self.i += 1
                if self.low() == "uses":
                    u.uses_tok = self.i
                    while self.low() != ";":
                        self.i += 1
                    u.uses_end_tok = self.i
                    self.i += 1
            elif low == "uses":
                while self.low() != ";":
                    self.i += 1
                self.i += 1
            elif low == "type":
                self.i += 1
                self.parse_type_section(section == "interface")
            elif low in ("const", "var", "threadvar", "resourcestring", "label"):
                self.i += 1
                self.skip_entries()
            elif low in ROUTINE_WORDS or (low == "class" and self.low(1) in ROUTINE_WORDS):
                header = self.parse_header()
                if section == "interface":
                    u.interface_routines.append(header)
                elif not header.dirs & {"external", "forward"}:
                    begin, end, semi, has_with = self.parse_block()
                    routine = Routine(header, begin, end, semi, has_with)
                    # {$IFDEF A} begin ... end; {$ELSE} begin ... end; {$ENDIF}
                    while self.low() == "begin" and self.t[self.i].cond != self.t[semi].cond:
                        _, _, semi, _ = self.parse_statements()
                        routine.alternative = True
                    u.routines.append(routine)
            elif low in ("initialization", "begin"):
                u.init_tok = self.i
                u.init_kind = low
                self.skip_unit_body()
            elif low == "finalization":
                u.final_tok = self.i
                self.skip_unit_body()
            elif low == "end" and self.low(1) == ".":
                u.end_dot_tok = self.i
                return
            else:
                raise ParseError(f"{u.path.name}:{self.line()}: unexpected '{self.text()}'")
        raise ParseError(f"{u.path.name}: no 'end.'")

    def skip_unit_body(self):
        self.i += 1
        depth = 0
        while self.i < len(self.t):
            low = self.low()
            if self.t[self.i].kind == "ident":
                if low in ("begin", "case", "try", "asm"):
                    depth += 1
                elif low == "end":
                    if depth == 0:
                        return
                    depth -= 1
                elif low == "finalization" and depth == 0:
                    return
            self.i += 1


# ---------------------------------------------------------------- generator

def pascal_string(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def cond_open(cond: tuple) -> str:
    return "{$IF " + " and ".join(f"({c})" for c in cond) + "}" if cond else ""


def cond_close(cond: tuple) -> str:
    return "{$ENDIF}" if cond else ""


@dataclass
class Plan:
    routine: Routine
    index: int
    owner: str | None          # class name for methods
    owner_kind: str | None
    decl: MethodDecl | None
    interface_decl: Header | None
    params: list               # parameters with names used by the generated code
    name: str                  # short routine name
    full_name: str


class Instrumenter:
    def __init__(self, info: UnitInfo, excluded: set):
        self.u = info
        self.excluded = excluded
        self.plans: list[Plan] = []
        self.skipped: dict[str, int] = {}

    def skip(self, reason: str):
        self.skipped[reason] = self.skipped.get(reason, 0) + 1

    def find_decl(self, header: Header) -> MethodDecl | None:
        owner = header.names[0].lower()
        candidates = [d for d in self.u.methods.get(owner, []) if d.header.names[-1].lower() == header.names[-1].lower()]
        key = header.signature_key()
        if key is None:
            return candidates[0] if len(candidates) == 1 else None
        for decl in candidates:
            if decl.header.signature_key() == key:
                return decl
        return None

    def find_interface(self, header: Header) -> Header | None:
        name = header.names[-1].lower()
        candidates = [h for h in self.u.interface_routines if h.names[-1].lower() == name]
        key = header.signature_key()
        if key is None:
            return candidates[0] if len(candidates) == 1 else None
        for candidate in candidates:
            if candidate.signature_key() == key:
                return candidate
        return None

    def plan(self):
        for routine in self.u.routines:
            h = routine.header
            tokens = self.u.tokens
            if h.has_directive or routine.alternative or tokens[h.start].cond != tokens[routine.semi_tok].cond:
                self.skip("conditional header")
                continue
            if h.dirs & UNWRAPPABLE:
                self.skip("inline/external")
                continue
            if len(h.names) > 2:
                self.skip("nested type")
                continue
            decl = interface_decl = None
            owner = owner_kind = None
            if len(h.names) == 2:
                owner = h.names[0]
                decl = self.find_decl(h)
                if decl is None:
                    self.skip("no declaration")
                    continue
                owner_kind = decl.owner_kind
                if decl.header.dirs & UNWRAPPABLE or decl.header.has_directive:
                    self.skip("inline/external")
                    continue
                if h.is_class and h.kind in ("constructor", "destructor"):
                    self.skip("class constructor")
                    continue
                if owner_kind == "object" and h.kind in ("constructor", "destructor"):
                    self.skip("object constructor")
                    continue
                params = h.params if h.params is not None else (decl.header.params or [])
                full = f"{owner}.{h.names[-1]}"
            else:
                interface_decl = self.find_interface(h)
                if interface_decl is not None and interface_decl.dirs & UNWRAPPABLE:
                    self.skip("inline/external")
                    continue
                if h.params is None and interface_decl is not None:
                    params = interface_decl.params or []
                else:
                    params = h.params or []
                full = f"{self.u.name}.{h.names[-1]}"
            if f"{self.u.name}.{full}".lower() in self.excluded or full.lower() in self.excluded:
                self.skip("excluded")
                continue
            if any(p.type and p.type.lower().startswith("array of const") for p in params):
                self.skip("array of const")
                continue
            self.plans.append(Plan(routine, len(self.plans), owner, owner_kind, decl, interface_decl,
                                   params, h.names[-1], full))

    # code pieces
    def arg_names(self, plan: Plan) -> list[str]:
        return [name for p in plan.params for name in p.names]

    def call_args(self, plan: Plan) -> str:
        names = self.arg_names(plan)
        return "(" + ", ".join(names) + ")" if names else ""

    def header_text(self, plan: Plan, new_name: str, *, kind: str | None = None, params: list | None = None,
                    qualified: bool = True, directives: list | None = None) -> str:
        h = plan.routine.header
        kind = kind or h.kind
        result = h.result
        if result is None and plan.decl is not None:
            result = plan.decl.header.result
        if result is None and plan.interface_decl is not None:
            result = plan.interface_decl.result
        text = ("class " if h.is_class else "") + kind + " "
        text += (f"{plan.owner}." if plan.owner and qualified else "") + new_name
        params = plan.params if params is None else params
        if params:
            text += "(" + "; ".join(p.render() for p in params) + ")"
        if kind == "function" and result:
            text += ": " + result
        text += ";"
        for directive in directives or []:
            text += " " + directive + ";"
        return text

    def helper_directives(self, plan: Plan) -> list:
        source = plan.decl.header if plan.decl else (plan.interface_decl or plan.routine.header)
        kept = [d for d in source.directives if d.split()[0].lower() in CALLING_CONVENTIONS | {"static"}]
        return kept

    def helper_kind(self, plan: Plan) -> str:
        return "procedure" if plan.routine.header.kind == "destructor" else plan.routine.header.kind

    def result_type(self, plan: Plan) -> str | None:
        h = plan.routine.header
        if h.kind == "constructor":
            return plan.owner
        result = h.result
        if result is None and plan.decl is not None:
            result = plan.decl.header.result
        if result is None and plan.interface_decl is not None:
            result = plan.interface_decl.result
        return result if h.kind == "function" else None

    def self_expr(self, plan: Plan) -> str:
        h = plan.routine.header
        if plan.owner is None or "static" in self.helper_dirs(plan):
            return "nil"
        if plan.owner_kind == "object":
            return "Pointer(@Self)"
        return "Pointer(Self)"

    def helper_dirs(self, plan: Plan) -> set:
        return {d.split()[0].lower() for d in self.helper_directives(plan)}

    def invokable(self, plan: Plan) -> bool:
        for p in plan.params:
            if p.type is None or p.type.lower().startswith("array of"):
                return False
        return True

    def flags(self, plan: Plan) -> int:
        h = plan.routine.header
        flags = 0
        if h.is_class:
            flags |= 1
        if "static" in self.helper_dirs(plan):
            flags |= 2
        if plan.owner_kind == "object":
            flags |= 4
        if self.invokable(plan):
            flags |= 8
        if plan.decl and plan.decl.header.dirs & {"virtual", "override", "dynamic"}:
            flags |= 16
        return flags

    def generated(self, plan: Plan) -> str:
        n = plan.index
        h = plan.routine.header
        kind = h.kind
        name = plan.name
        xb, xh = f"{name}__XB{n}", f"{name}__XH{n}"
        args = self.call_args(plan)
        result = self.result_type(plan)
        is_function = kind == "function"
        names = self.arg_names(plan)
        parts = []

        # Invoker: calls the routine through its wrapper.
        invoker = "nil"
        if self.invokable(plan):
            invoker = f"@XenoHkI{n}"
            types = []
            for p in plan.params:
                for _ in p.names:
                    types.append(p.type)
            decls = "".join(f" XenoP{i} = ^{t};" for i, t in enumerate(types))
            if result:
                decls += f" XenoPR = ^{result};"
            call_args = "(" + ", ".join(f"XenoP{i}(XenoA^[{i}])^" for i in range(len(types))) + ")" if types else ""
            static = "static" in self.helper_dirs(plan)
            if plan.owner is None:
                target = f"{name}{call_args}"
            elif kind == "constructor":
                target = f"{plan.owner}.{name}{call_args}"
            elif h.is_class or static:
                target = f"{plan.owner}.{name}{call_args}"
            elif plan.owner_kind == "object":
                decls += f" XenoPS = ^{plan.owner};"
                target = f"XenoPS(XenoS)^.{name}{call_args}"
            else:
                target = f"{plan.owner}(XenoS).{name}{call_args}"
            body = f"XenoPR(XenoR)^ := {target}" if result else target
            type_section = f" type{decls}" if decls else ""
            parts.append(f"procedure XenoHkI{n}(XenoS: Pointer; XenoA: PXenoHkArgs; XenoR: Pointer);{type_section} "
                         f"begin {body}; end;")

        # Argument table and descriptor.
        arg_ref = "nil"
        if names:
            entries = []
            for p in plan.params:
                mode = {"": 0, "const": 1, "var": 2, "out": 3, "constref": 4}[p.mode.lower()]
                size = "0" if p.type is None or p.type.lower().startswith("array of") else f"SizeOf({p.type})"
                for arg in p.names:
                    entries.append(f"(Name: {pascal_string(arg)}; TypeName: {pascal_string(p.type or '')}; "
                                   f"Mode: {mode}; Size: {size})")
            parts.append(f"const XenoHkG{n}: array[0..{len(entries) - 1}] of TXenoHkArg = ({', '.join(entries)});")
            arg_ref = f"@XenoHkG{n}"
        params_text = "(" + "; ".join(p.render() for p in plan.params) + ")" if plan.params else ""
        kinds = {"procedure": 0, "function": 1, "constructor": 2, "destructor": 3}
        result_size = f"SizeOf({result})" if result and kind != "constructor" else ("SizeOf(Pointer)" if result else "0")
        class_ref = plan.owner if plan.owner and plan.owner_kind == "class" else "nil"
        parts.append(
            f"const XenoHkD{n}: TXenoHkDesc = (Slot: @XenoHkSlots[{n}]; UnitName: {pascal_string(self.u.name)}; "
            f"ClassName: {pascal_string(plan.owner or '')}; MethodName: {pascal_string(name)}; "
            f"Params: {pascal_string(params_text)}; ResultType: {pascal_string(result or '')}; "
            f"Kind: {kinds[kind]}; Flags: {self.flags(plan)}; ResultSize: {result_size}; ArgCount: {len(names)}; "
            f"Args: {arg_ref}; Invoke: {invoker}; ClassRef: {class_ref}; "
            f"Counter: {f'@XenoHkCounts[{n}]' if PROFILE else 'nil'});")

        # Hook path.
        helper_kind = self.helper_kind(plan)
        directives = self.helper_directives(plan)
        xh_header = self.header_text(plan, xh, kind=helper_kind, directives=directives)
        arg_count = max(len(names), 1)
        fill = " ".join(f"XenoA[{i}] := @{arg};" for i, arg in enumerate(names))
        result_ptr = "@Result" if is_function else "nil"
        call = f"Result := {xb}{args}" if is_function else f"{xb}{args}"
        parts.append(
            f"{xh_header} var XenoC: TXenoHkCall; XenoA: array[0..{arg_count - 1}] of Pointer; begin {fill} "
            f"if XenoHookEnter(XenoC, @XenoHkD{n}, {self.self_expr(plan)}, PXenoHkArgs(@XenoA), {result_ptr}) then "
            f"try {call}; XenoC.OriginalRan := 1; finally XenoHookLeave(XenoC); end else XenoHookLeave(XenoC); end;")

        # Wrapper with the original header.
        wrapper = self.header_text(plan, name, params=h.params if h.params is not None else None,
                                   directives=[d for d in h.directives])
        if h.params is None:
            # Keep the implementation's own (omitted) parameter list.
            wrapper = self.header_text(plan, name, params=[], directives=[d for d in h.directives])
        fast = f"Result := {xb}{args}" if is_function else f"{xb}{args}"
        slow = f"Result := {xh}{args}" if is_function else f"{xh}{args}"
        count = f"Inc(XenoHkCounts[{n}]); " if PROFILE else ""
        parts.append(f"{wrapper} begin {count}if XenoHkSlots[{n}] = nil then {fast} else {slow}; end;")
        return " ".join(parts)

    def edits(self) -> list[tuple[int, int, str]]:
        """(start, end, replacement) edits on the unit text."""
        u = self.u
        t = u.tokens
        edits = []
        if not self.plans:
            return edits
        count = len(self.plans)
        # uses + slots.
        slots = f" var XenoHkSlots: array[0..{count - 1}] of Pointer;"
        if PROFILE:
            slots += f" XenoHkCounts: array[0..{count - 1}] of Cardinal;"
        if u.uses_tok >= 0:
            # Our unit goes first; the original clause continues it. When the
            # clause itself is conditional, the other branch ends ours.
            cond = t[u.uses_tok].cond
            if t[u.uses_end_tok].cond != cond:
                raise ParseError(f"{u.path.name}: uses clause spans conditional branches")
            other = ""
            if cond:
                expr = " and ".join(f"({c})" for c in cond)
                other = "{$IF not (" + expr + ")};" + slots + "{$ENDIF}"
            edits.append((t[u.impl_tok].end, t[u.impl_tok].end, f" uses {RUNTIME_UNIT}{other}"))
            edits.append((t[u.uses_tok].start, t[u.uses_tok].end, ","))
            edits.append((t[u.uses_end_tok].end, t[u.uses_end_tok].end, slots))
        else:
            edits.append((t[u.impl_tok].end, t[u.impl_tok].end, f" uses {RUNTIME_UNIT};{slots}"))

        decl_additions: dict[int, list[str]] = {}
        tail: list[str] = []
        for plan in self.plans:
            r = plan.routine
            h = r.header
            n = plan.index
            cond = t[h.start].cond
            # Rename the body routine in place.
            if h.kind == "destructor":
                edits.append((t[h.kind_tok].start, t[h.kind_tok].end, "procedure"))
            edits.append((t[h.name_tok].start, t[h.name_tok].end, f"{plan.name}__XB{n}"))
            # A routine declared only in the implementation needs a forward
            # declaration of its wrapper for recursive calls.
            if plan.owner is None and plan.interface_decl is None:
                forward = self.header_text(plan, plan.name, params=h.params or [],
                                           directives=[d for d in h.directives] + ["forward"])
                edits.append((t[h.start].start, t[h.start].start, forward + " "))
            # Body rewrites.
            for k in range(r.begin_tok, r.end_tok):
                tok = t[k]
                if tok.low == "inherited" and plan.owner:
                    following = t[k + 1]
                    if not (following.kind == "ident" and following.low not in RESERVED):
                        edits.append((tok.end, tok.end, f" {plan.name}{self.call_args(plan)}"))
                elif h.kind == "function" and tok.kind == "ident" and tok.low == plan.name.lower() \
                        and t[k + 1].text == ":=" and t[k - 1].text != "." and not r.has_with:
                    edits.append((tok.start, tok.end, "Result"))
            # Class declaration of the helpers.
            if plan.decl is not None:
                decl = plan.decl.header
                helper_kind = self.helper_kind(plan)
                directives = self.helper_directives(plan)
                params = decl.params or []
                xb = self.header_text(plan, f"{plan.name}__XB{n}", kind=helper_kind, params=params,
                                      qualified=False, directives=directives)
                xh = self.header_text(plan, f"{plan.name}__XH{n}", kind=helper_kind, params=params,
                                      qualified=False, directives=directives)
                text = f"{cond_open(cond)} {xb} {xh} {cond_close(cond)}"
                decl_additions.setdefault(t[decl.end - 1].end, []).append(text)
            # Wrapper, hook path, invoker and descriptor go to the end of the
            # unit: the original bodies stay as close together as in the
            # plain build, which keeps hot code dense in the CPU caches.
            tail.append(f"{cond_open(cond)} {self.generated(plan)} {cond_close(cond)}")
        for position, texts in decl_additions.items():
            edits.append((position, position, " " + " ".join(texts)))
        if u.init_tok >= 0:
            tail_pos = t[u.init_tok].start
        elif u.final_tok >= 0:
            tail_pos = t[u.final_tok].start
        else:
            tail_pos = t[u.end_dot_tok].start
        edits.append((tail_pos, tail_pos, " ".join(tail) + " "))

        # Registration.
        lines = []
        for plan in self.plans:
            cond = t[plan.routine.header.start].cond
            lines.append(f"{cond_open(cond)}XenoHookRegister(@XenoHkD{plan.index});{cond_close(cond)}")
        registration = " ".join(lines)
        if u.init_tok >= 0 and u.init_kind == "initialization":
            edits.append((t[u.init_tok].end, t[u.init_tok].end, " " + registration))
        elif u.init_tok >= 0:  # 'begin' ... 'end.'
            edits.append((t[u.init_tok].end, t[u.init_tok].end, " " + registration))
        elif u.final_tok >= 0:
            edits.append((t[u.final_tok].start, t[u.final_tok].start, "initialization " + registration + " "))
        else:
            edits.append((t[u.end_dot_tok].start, t[u.end_dot_tok].start, "initialization " + registration + " "))
        return edits


def apply(text: str, edits: list) -> str:
    # Insertions at the same position keep their order of creation.
    ordered = sorted(enumerate(edits), key=lambda item: (item[1][0], item[0]))
    out = []
    last = 0
    for _, (start, end, replacement) in ordered:
        if start < last:
            raise ParseError(f"overlapping edits at {start}")
        out.append(text[last:start])
        out.append(replacement)
        last = end
    out.append(text[last:])
    return "".join(out)


def load_excluded() -> set:
    if not EXCLUDE_FILE.is_file():
        return set()
    result = set()
    for line in EXCLUDE_FILE.read_text(encoding="utf-8").splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            result.add(line.lower())
    return result


def instrument(path: Path, excluded: set, listing: list) -> tuple[str | None, Instrumenter | None, str | None]:
    text = path.read_text(encoding="utf-8-sig")
    match = re.search(r"^\s*unit\s+(\w+)\s*;", text, re.I | re.M)
    if not match:
        return None, None, None
    name = match.group(1)
    if name.startswith(SKIP_UNIT_PREFIX) or name.lower() in excluded:
        return None, None, None
    try:
        tokens, directives = tokenize(text)
        info = UnitInfo(name, path, text, tokens, directives)
        Parser(info).parse()
        tool = Instrumenter(info, excluded)
        tool.plan()
        result = apply(text, tool.edits())
    except ParseError as error:
        return None, None, str(error)
    for plan in tool.plans:
        params = "(" + "; ".join(p.render() for p in plan.params) + ")" if plan.params else ""
        result_type = tool.result_type(plan)
        kind = plan.routine.header.kind
        listing.append(f"{plan.full_name}{params}{': ' + result_type if result_type and kind == 'function' else ''}"
                       f"    [{name}, {kind}]")
    return result, tool, None


def write_if_changed(path: Path, data: bytes):
    if path.is_file() and path.read_bytes() == data:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


def build_mirror(out: Path, listing_file: Path | None = None, verbose: bool = True) -> int:
    excluded = load_excluded()
    listing: list[str] = []
    wanted: set[Path] = set()
    total = 0
    skipped: dict[str, int] = {}
    failures = []
    for path in sorted(SOURCE.rglob("*")):
        if not path.is_file():
            continue
        relative = path.relative_to(SOURCE)
        target = out / relative
        wanted.add(target)
        data = path.read_bytes()
        if path.suffix.lower() == ".pas":
            text, tool, error = instrument(path, excluded, listing)
            if error:
                failures.append(error)
            if text is not None:
                data = text.encode("utf-8")
                total += len(tool.plans)
                for reason, count in tool.skipped.items():
                    skipped[reason] = skipped.get(reason, 0) + count
        write_if_changed(target, data)
    for path in sorted(out.rglob("*"), reverse=True):
        if path.is_file() and path not in wanted:
            path.unlink()
        elif path.is_dir() and not any(path.iterdir()):
            path.rmdir()
    if listing_file is not None:
        listing.sort(key=str.lower)
        write_if_changed(listing_file, ("\n".join(listing) + "\n").encode("utf-8"))
    if verbose:
        print(f"Xeno hooks: {total} routines wrapped; skipped: "
              + ", ".join(f"{k} {v}" for k, v in sorted(skipped.items())), flush=True)
        for failure in failures:
            print(f"Xeno hooks: unit left unwrapped: {failure}", flush=True)
    return total


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--out", type=Path, help="mirror directory to write")
    parser.add_argument("--list", type=Path, help="write the list of hookable routines")
    parser.add_argument("--stats", action="store_true", help="parse only and print statistics")
    args = parser.parse_args()
    if args.stats or not args.out:
        excluded = load_excluded()
        listing: list[str] = []
        total = 0
        for path in sorted(SOURCE.rglob("*.pas")):
            _, tool, error = instrument(path, excluded, listing)
            if error:
                print("FAIL", error)
            elif tool:
                total += len(tool.plans)
        print("wrapped", total)
        return 0
    build_mirror(args.out.resolve(), args.list)
    return 0


if __name__ == "__main__":
    sys.exit(main())
