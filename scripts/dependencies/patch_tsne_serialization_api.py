#!/usr/bin/env python3
"""Adapt t-SNE serialization calls to the current ManiVault utility API."""

from __future__ import annotations

import re
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: patch_tsne_serialization_api.py SOURCE_ROOT", file=sys.stderr)
        return 2

    source_root = Path(sys.argv[1]).expanduser().resolve()
    files = (
        source_root / "t-SNE-Analysis/src/HSNE/HsneScaleAction.cpp",
        source_root / "t-SNE-Analysis/src/HSNE/HsneAnalysisPlugin.cpp",
    )
    changed = 0
    for path in files:
        if not path.is_file():
            continue
        original = path.read_text(encoding="utf-8")
        updated = original.replace("rawDataToVariantMap(", "bytesToBlobVariantMap(")
        updated = updated.replace(
            "populateDataBufferFromVariantMap(variantMap, bytes.data());",
            "populateBytesFromBlobMap(variantMap, bytes.data(), static_cast<std::uint64_t>(bytes.size()));",
        )
        updated = updated.replace(
            "populateDataBufferFromVariantMap(drillIndices, reinterpret_cast<char*>(drillIndicesVec.data()))",
            "populateBytesFromBlobMap(drillIndices, reinterpret_cast<char*>(drillIndicesVec.data()), static_cast<std::uint64_t>(drillIndicesVec.size() * sizeof(uint32_t)))",
        )
        if path.name == "HsneAnalysisPlugin.cpp":
            updated = updated.replace("bytesFromVariantMap(", "bytesFromBlobVariantMap(")
            helper_pattern = re.compile(
                r"    QByteArray bytesFromBlobVariantMap\(const QVariantMap& variantMap\)\s*\{.*?\n    \}\n\n",
                re.S,
            )
            updated, _ = helper_pattern.subn("", updated, count=1)
        if updated != original:
            path.write_text(updated, encoding="utf-8")
            changed += 1
    print(f"Updated t-SNE serialization API in {changed} file(s).", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
