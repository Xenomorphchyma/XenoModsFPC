"""Copy the Windows game files of a XenoModsFPC release into a folder.

The executable, the DLLs it actually imports and the license notices, chosen
exactly like the port's own release script (.github/scripts/package.py), so
nothing unused from the build folder ends up in the archive.

    python xenomods/release_files.py <destination> [win32|win64]
"""

from __future__ import annotations

import importlib.util
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
from build_support import dependency_source, require_tool, sdl_source  # noqa: E402
from targets import BuildConfig  # noqa: E402
from windows import discover_toolchain  # noqa: E402


def upstream_packager():
    spec = importlib.util.spec_from_file_location("upstream_package", ROOT / ".github/scripts/package.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def release_files(target: str) -> dict[str, Path]:
    config = BuildConfig(target, release=True, root=ROOT)
    toolchain = discover_toolchain()
    triple = "i686-w64-mingw32" if target == "win32" else "x86_64-w64-mingw32"
    # Rangers.exe and the DLLs reachable through its imports. xvidcore.dll is
    # loaded at runtime from the game folder and is not part of the release.
    readobj = require_tool(str(toolchain / "bin/llvm-readobj"))
    files = {path.name: path for path in upstream_packager().windows_runtime_files(config.artifact, readobj)}
    files.update({name: ROOT / name for name in ("LICENSE", "NOTICE.md")})
    for source, name in (
        ("licenses/spacerangershd-fpc-fixes.txt", "spacerangershd-fpc-fixes.txt"),
        ("vendor/okgf/LICENSE", "OKGF.txt"),
        ("vendor/okgf/vendor/softfloat/COPYING.txt", "SoftFloat.txt"),
        ("vendor/fpc/rtl/COPYING.FPC", "FPC.txt"),
        ("vendor/fpc/rtl/COPYING.txt", "FPC-LGPL.txt"),
        ("vendor/fpc/packages/paszlib/readme.txt", "paszlib.txt"),
        ("vendor/fpc/packages/pasjpeg/readme.txt", "pasjpeg.txt"),
    ):
        files[f"licenses/{name}"] = ROOT / source
    files["licenses/SDL2.txt"] = sdl_source(config.work / "native") / "LICENSE.txt"
    for dependency, name in (
        ("zlib", "LICENSE"),
        ("jpeg", "LICENSE.md"),
        ("png", "LICENSE"),
        ("ogg", "COPYING"),
        ("vorbis", "COPYING"),
    ):
        files[f"licenses/{dependency}.txt"] = dependency_source(dependency) / name
    files["licenses/jpeg-IJG.txt"] = dependency_source("jpeg") / "README.ijg"
    files["licenses/LLVM.txt"] = toolchain / "LICENSE.TXT"
    files["licenses/MinGW-w64.txt"] = toolchain / triple / "share/mingw32/COPYING.MinGW-w64-runtime.txt"
    return files


def main() -> int:
    destination = Path(sys.argv[1])
    target = sys.argv[2] if len(sys.argv) > 2 else "win32"
    for name, source in release_files(target).items():
        if not source.is_file():
            raise FileNotFoundError(f"Release file is missing: {source}")
        path = destination / name
        path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
