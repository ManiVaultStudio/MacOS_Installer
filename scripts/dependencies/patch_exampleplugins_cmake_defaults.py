#!/usr/bin/env python3
"""Supply the CMake defaults helper missing from older ManiVault core releases."""

from __future__ import annotations

import re
import sys
from pathlib import Path

FALLBACK = """# Older ManiVault releases do not ship mv_project_defaults().
if(NOT COMMAND mv_project_defaults)
    function(mv_project_defaults)
        set(CMAKE_CXX_STANDARD 20 PARENT_SCOPE)
        set(CMAKE_CXX_STANDARD_REQUIRED ON PARENT_SCOPE)
        set(CMAKE_CXX_EXTENSIONS OFF PARENT_SCOPE)
    endfunction()
endif()

"""


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: patch_exampleplugins_cmake_defaults.py SOURCE_ROOT", file=sys.stderr)
        return 2

    source_root = Path(sys.argv[1]).expanduser().resolve()
    patched = []
    for project in source_root.iterdir():
        cmake_file = project / "CMakeLists.txt"
        if not project.is_dir() or not cmake_file.is_file():
            continue
        source = cmake_file.read_text(encoding="utf-8")
        if not re.search(r"(?m)^\s*mv_project_defaults\s*\(", source):
            continue
        if re.search(r"(?is)function\s*\(\s*mv_project_defaults\s*\)", source):
            continue
        match = re.search(r"(?m)^\s*mv_project_defaults\s*\(", source)
        assert match is not None
        cmake_file.write_text(source[:match.start()] + FALLBACK + source[match.start():], encoding="utf-8")
        patched.append(project.name)

    if patched:
        print("Added ManiVault CMake defaults compatibility to: " + ", ".join(patched), flush=True)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as exc:
        print(f"ManiVault CMake compatibility error: {exc}", file=sys.stderr)
        raise SystemExit(1)
