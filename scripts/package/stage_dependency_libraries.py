#!/usr/bin/env python3
"""Stage only manifest-declared shared dependency libraries into a package folder."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from dependency_config import manifest_data, enabled_closure
SCRIPTS_ROOT = ROOT / "scripts"
LIBRARIES_ROOT = Path(os.environ.get("LIBRARIES_ROOT", ROOT / "libraries")).expanduser().resolve()


def digest(path: Path) -> str:
    checksum = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            checksum.update(chunk)
    return checksum.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", type=Path)
    parser.add_argument("--manifest", type=Path, default=ROOT / "installer_database/dependencies.json")
    args = parser.parse_args()
    data = manifest_data(args.manifest)
    target = args.target.resolve()
    target.mkdir(parents=True, exist_ok=True)
    staged: dict[str, str] = {}
    for item in enabled_closure(data.get("dependencies", [])):
        if item.get("linkage") not in {"shared", "both"}:
            continue
        for value in item.get("runtimeArtifacts", []):
            relative = Path(value)
            if relative.parts and relative.parts[0] in {"libs", "libraries"}:
                relative = Path(*relative.parts[1:])
            source = (LIBRARIES_ROOT / relative).resolve()
            if LIBRARIES_ROOT not in source.parents:
                raise ValueError(f"Runtime artifact escapes dependency folder: {value}")
            if not source.exists():
                raise FileNotFoundError(f"Runtime dependency {item.get('name')} is missing: {source}")
            files = sorted(source.rglob("*.dylib")) if source.is_dir() else ([source] if source.suffix == ".dylib" else [])
            if not files:
                raise ValueError(f"Runtime artifact has no .dylib files: {source}")
            for library in files:
                name = library.name
                checksum = digest(library)
                previous = staged.get(name)
                if previous and previous != checksum:
                    raise ValueError(f"Two different runtime dependencies provide {name}; assign unique install names")
                staged[name] = checksum
                destination = target / name
                if not destination.exists() or digest(destination) != checksum:
                    shutil.copy2(library, destination)
                    print(f"Staged {item.get('name')} shared library: {name}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
