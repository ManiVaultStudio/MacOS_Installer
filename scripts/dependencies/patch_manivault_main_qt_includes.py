#!/usr/bin/env python3
"""Apply the Qt 6.10 QUuid include fix to ManiVault Studio Main's pinned core."""
from __future__ import annotations

import sys
from pathlib import Path


source_root = Path(sys.argv[1])


def ensure_include(relative: str, include: str, anchor: str) -> None:
    path = source_root / "core" / "ManiVault" / relative
    if not path.is_file():
        raise SystemExit(f"ManiVault Main source file was not found: {path}")
    text = path.read_text(encoding="utf-8")
    if include in text:
        return
    if anchor not in text:
        raise SystemExit(f"Could not locate the include insertion point in {path}")
    path.write_text(text.replace(anchor, anchor + f"\n{include}", 1), encoding="utf-8")
    print(f"Added {include} to {path.relative_to(source_root)}.")


ensure_include("src/actions/GroupAction.cpp", "#include <QUuid>", "#include <QHBoxLayout>")
ensure_include("src/util/Version.cpp", "#include <QRegularExpression>", '#include "Version.h"')
