"""Generate source/mods/xeno/XenoFieldMap.inc for the XenoModsFPC plugin host.

Plugins never hardcode object offsets: they ask the host for "TShip" /
"ChameleonActive" and receive the offset, size and declared type that this
build actually uses. The table is regenerated from the interface sections of
the game sources, so it follows every rebuild of the executable.

    python xenomods/gen_fieldmap.py          # write the include
    python xenomods/gen_fieldmap.py --check  # fail when it is out of date
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "source/mods/xeno/XenoFieldMap.inc"
UNITS_OUTPUT = ROOT / "source/mods/xeno/XenoFieldMapUnits.inc"
# Units whose object model plugins work with.
SOURCE_DIRS = ("source/game", "source/screens", "source/audio", "source/core", "source/mods", "source")
# Xeno units use the host themselves; the map never needs their types.
SKIP_PREFIX = "Xeno"
# Units XenoPluginHost needs besides the mapped ones (kept in one uses list
# so nothing is listed twice).
HOST_UNITS = (
    "Classes", "SysUtils", "Math", "Dynlibs", "GameDiagnostics", "GameSystem", "GameEvents", "EC_Str", "EC_Struct",
    "EC_BlockPar", "EC_Expression", "EC_FileStream", "NativeScriptLibrary", "GameObjectRegistry", "GI_MessageLoop",
    "GI_GraphButton", "GI_Label", "GR_Sound", "GR_Music", "GR_Main", "aGalaxy", "aShip", "aPlayer", "fHangar",
)

TYPE_START = re.compile(r"^  (T\w+)\s*=\s*(packed\s+)?(class|record)\b(\s*\(([\w.]+)\))?\s*(;)?", re.I)
FIELD = re.compile(r"^    ([A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*)\s*:\s*([^;=]+);\s*(//.*)?$")
MEMBER_KEYWORDS = re.compile(
    r"^\s*(procedure|function|constructor|destructor|property|class|operator|case)\b", re.I
)
VISIBILITY = re.compile(r"^\s*(strict\s+)?(private|protected|public|published)\s*$", re.I)


def interface_part(text: str) -> str:
    match = re.search(r"^implementation\b", text, re.I | re.M)
    return text[: match.start()] if match else text


def parse_unit(path: Path):
    text = path.read_text(encoding="utf-8", errors="replace")
    unit = re.search(r"^\s*unit\s+(\w+)\s*;", text, re.I | re.M)
    if not unit or unit.group(1).startswith(SKIP_PREFIX):
        return None, []
    lines = interface_part(text).splitlines()
    types = []
    index = 0
    while index < len(lines):
        start = TYPE_START.match(lines[index])
        index += 1
        if not start or start.group(6):  # forward declaration "TName = class;"
            continue
        name, kind = start.group(1), start.group(3).lower()
        fields = []
        hidden = False
        while index < len(lines):
            line = lines[index]
            if re.match(r"^  end\s*;", line):
                index += 1
                break
            visibility = VISIBILITY.match(line)
            if visibility:
                hidden = visibility.group(2).lower() in ("private", "protected")
            elif kind == "record" and re.match(r"^\s*case\b", line, re.I):
                # Variant parts: the fields after "case" overlap; stop here.
                hidden = True
            elif MEMBER_KEYWORDS.match(line):
                pass
            else:
                field = FIELD.match(line)
                if field and not hidden and "procedure" not in field.group(2).lower() \
                        and "function" not in field.group(2).lower():
                    for item in field.group(1).split(","):
                        fields.append((item.strip(), " ".join(field.group(2).split())))
            index += 1
        if fields:
            types.append((name, kind, fields))
    return unit.group(1), types


def generate() -> tuple[str, str]:
    seen: set[str] = set()
    units: list[str] = []
    entries: list[str] = []
    files: list[Path] = []
    for directory in SOURCE_DIRS:
        base = ROOT / directory
        pattern = "*.pas"
        files.extend(sorted(base.glob(pattern)) if directory == "source" else sorted(base.rglob(pattern)))
    for path in files:
        unit, types = parse_unit(path)
        if not unit or not types:
            continue
        used = False
        for name, kind, fields in types:
            if name.lower() in seen:
                continue
            seen.add(name.lower())
            used = True
            for field, type_text in fields:
                if kind == "class":
                    address = f"PtrUInt(@{name}(nil).{field})"
                    size = f"SizeOf({name}(nil).{field})"
                else:
                    address = f"PtrUInt(@P{name}Map(nil)^.{field})"
                    size = f"SizeOf(P{name}Map(nil)^.{field})"
                type_literal = type_text.replace("'", "''")
                entries.append(f"  AddField('{name}', '{field}', {address}, {size}, '{type_literal}');")
            if kind == "class":
                entries.append(f"  AddClass('{name}', {name});")
        if used:
            units.append(unit)
    record_types = []
    for path in files:
        unit, types = parse_unit(path)
        for name, kind, _ in types:
            if kind == "record" and unit in units:
                record_types.append(f"  P{name}Map = ^{name};")
    record_types = sorted(set(record_types))
    header = "// Generated by xenomods/gen_fieldmap.py; do not edit.\n"
    body = header
    if record_types:
        body += "type\n" + "\n".join(record_types) + "\n\n"
    body += "procedure FillFieldMap(AddField: TAddFieldProc; AddClass: TAddClassProc);\nbegin\n" + "\n".join(entries) + "\nend;\n"
    ordered: list[str] = []
    for unit in (*HOST_UNITS, *units):
        if unit.lower() not in {item.lower() for item in ordered}:
            ordered.append(unit)
    unit_list = header + "".join(f"  {unit},\n" for unit in ordered) + "  XenoModsHost;\n"
    return body, unit_list


def main() -> int:
    body, unit_list = generate()
    if "--check" in sys.argv:
        current = (OUTPUT.read_text(encoding="utf-8") if OUTPUT.exists() else "",
                   UNITS_OUTPUT.read_text(encoding="utf-8") if UNITS_OUTPUT.exists() else "")
        if current != (body, unit_list):
            print("XenoFieldMap is out of date: run python xenomods/gen_fieldmap.py", file=sys.stderr)
            return 1
        return 0
    OUTPUT.write_text(body, encoding="utf-8", newline="\r\n")
    UNITS_OUTPUT.write_text(unit_list, encoding="utf-8", newline="\r\n")
    print(f"{OUTPUT.relative_to(ROOT)}: {body.count('AddField')} fields, {body.count('AddClass')} classes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
