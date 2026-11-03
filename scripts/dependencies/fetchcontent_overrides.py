#!/usr/bin/env python3
"""Return version-checked local CMake FetchContent overrides."""

from __future__ import annotations

import json
import subprocess
import sys
import argparse
import os
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("libraries_root", type=Path)
    parser.add_argument("--prepare-only", action="store_true", help="Verify and apply pinned source compatibility patches without printing CMake overrides")
    args = parser.parse_args()
    libraries_root = args.libraries_root.expanduser().resolve()
    manifest = Path(__file__).resolve().parents[2] / "installer_database/source_pins.json"
    data = json.loads(manifest.read_text(encoding="utf-8"))

    project = os.environ.get("PROFILE_NAME", "")
    requirements_path = Path(__file__).resolve().parents[2] / "installer_database/project_dependencies.json"
    requirements = json.loads(requirements_path.read_text())["records"] if requirements_path.exists() else []
    for dependency in data.get("dependencies", []):
        dependency = dict(dependency)
        assigned = [row for row in requirements if row.get("Kind") == "pin" and row.get("Dependency") == dependency["name"] and row.get("Required")]
        if project and project != "workspace" and assigned:
            matching = next((row for row in assigned if row["Profile ID"] == project), None)
            if matching is None:
                continue
            expected_version = str(dependency.get("version") or dependency.get("git_tag") or "")
            if expected_version != matching["Version"]:
                raise ValueError(f"{project} requires {dependency['name']} {matching['Version']}; registered version is {expected_version}")
            dependency["required"] = True
        name = str(dependency["name"]).strip()
        source = (libraries_root / dependency["source"]).resolve()
        if not source.is_dir():
            if dependency.get("required", False):
                raise ValueError(
                    f"Required local dependency {name} is missing: {source}. "
                    "It must be available locally so its compatibility patch "
                    "can be applied before CMake configuration."
                )
            continue
        if "\n" in str(source):
            raise ValueError(f"Dependency path contains a newline: {source}")

        if "git_tag" in dependency:
            expected = str(dependency["git_tag"]).strip()
            actual = subprocess.run(
                ["git", "describe", "--tags", "--exact-match", "HEAD"],
                cwd=source,
                capture_output=True,
                text=True,
            )
            actual_value = actual.stdout.strip()
            valid = actual.returncode == 0 and actual_value == expected
        else:
            version_file = source / str(dependency["version_file"])
            expected = str(dependency["version"]).strip()
            actual_value = version_file.read_text(encoding="utf-8").strip() if version_file.is_file() else ""
            valid = actual_value == expected
        if not valid:
            raise ValueError(f"Local {name} source at {source} must be pinned to {expected}; found {actual_value or 'unverified version'}")

        patch_name = str(dependency.get("patch_file", "")).strip()
        if patch_name:
            patch_file = (Path(__file__).parent / patch_name).resolve()
            if not patch_file.is_file():
                raise ValueError(f"Local {name} compatibility patch is missing: {patch_file}")

            patch_text = patch_file.read_text(encoding="utf-8")

            # Test whether the patch can be applied from the dependency directory.
            check = subprocess.run(
                ["patch", "--batch", "--dry-run", "--forward", "-p1"],
                cwd=source,
                input=patch_text,
                capture_output=True,
                text=True,
            )

            if check.returncode == 0:
                result = subprocess.run(
                    ["patch", "--batch", "--forward", "-p1"],
                    cwd=source,
                    input=patch_text,
                    capture_output=True,
                    text=True,
                )
                if result.returncode != 0:
                    raise ValueError(
                        f"Failed to apply the {name} compatibility patch: "
                        f"{result.stderr or result.stdout}"
                    )
                print(
                    f"Applied compatibility patch to local {name} source.",
                    file=sys.stderr,
                )
            else:
                # If forward application fails, check whether it is already applied.
                reverse = subprocess.run(
                    ["patch", "--batch", "--dry-run", "-R", "-p1"],
                    cwd=source,
                    input=patch_text,
                    capture_output=True,
                    text=True,
                )
                if reverse.returncode != 0:
                    detail = (
                        check.stderr or check.stdout
                        or reverse.stderr or reverse.stdout
                    ).strip()
                    raise ValueError(
                        f"Could not apply or verify the {name} compatibility patch: "
                        f"{detail}"
                    )

        if args.prepare_only:
            continue

        variable = str(dependency.get("cmake_variable", "")).strip()
        if not variable:
            cmake_name = "".join(char if char.isalnum() else "_" for char in name.upper())
            variable = f"FETCHCONTENT_SOURCE_DIR_{cmake_name}"
        print(f"-D{variable}={source}")

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as exc:
        print(f"FetchContent dependency override error: {exc}", file=sys.stderr)
        raise SystemExit(1)
