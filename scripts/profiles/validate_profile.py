#!/usr/bin/env python3
"""Validate repository selections and release metadata from a sourced profile."""

from __future__ import annotations

import json
import subprocess
import os
import re
import shutil
import sys
from pathlib import Path


SEMVER = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$")
SAFE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")


def fail(message: str) -> None:
    print(f"Profile validation error: {message}", file=sys.stderr)
    raise SystemExit(2)


def repository_map(label: str, raw: str) -> tuple[list[str], dict[str, str]]:
    try:
        data = json.loads(raw or "{}")
    except json.JSONDecodeError as exc:
        fail(f"{label} is not valid JSON: {exc}")
    if not isinstance(data, dict):
        fail(f"{label} must be a JSON object")
    repos = data.get("repos", [])
    if isinstance(repos, list):
        names = repos
        default = data.get("defaultBranch", "")
        if default and not isinstance(default, str):
            fail(f"{label}.defaultBranch must be a string")
    elif isinstance(repos, dict):
        names = list(repos)
        if any(not isinstance(branch, str) or not branch.strip() for branch in repos.values()):
            fail(f"{label}.repos branch values must be non-empty strings")
    else:
        fail(f"{label}.repos must be a list or object")
    if any(not isinstance(name, str) or not SAFE_NAME.fullmatch(name) for name in names):
        fail(f"{label} contains an invalid repository name")
    if len(set(names)) != len(names):
        fail(f"{label} contains duplicate repositories")
    overrides = data.get("branchOverrides", data.get("overrides", {}))
    if not isinstance(overrides, dict):
        fail(f"{label}.branchOverrides must be a JSON object")
    unknown = set(overrides) - set(names)
    if unknown:
        fail(f"{label} has branch overrides for repositories not selected: {', '.join(sorted(unknown))}")
    if any(not SAFE_NAME.fullmatch(key) or not isinstance(branch, str) or not branch.strip() for key, branch in overrides.items()):
        fail(f"{label} contains an invalid branch override")
    return names, overrides


def main() -> None:
    profile = os.environ.get("PROFILE_NAME", "")
    if not SAFE_NAME.fullmatch(profile):
        fail("PROFILE_NAME must be a safe project identifier")
    version = os.environ.get("APP_VERSION", "")
    if not SEMVER.fullmatch(version):
        fail(f"APP_VERSION '{version}' must follow semantic versioning (MAJOR.MINOR.PATCH)")
    archs = os.environ.get("ARCHS", "x86_64;arm64").split(";")
    if not archs or any(arch not in {"arm64", "x86_64"} for arch in archs) or len(set(archs)) != len(archs):
        fail("ARCHS must contain arm64 and/or x86_64, separated by semicolons")
    if not re.fullmatch(r"\d+(?:\.\d+){0,2}", os.environ.get("MIN_MACOS_VERSION", "12.0")):
        fail("MIN_MACOS_VERSION must be a macOS version such as 13.3 or 26")
    for key in ("MIN_CORE_VERSION_MAJOR", "MIN_CORE_VERSION_MINOR", "MIN_CORE_VERSION_PATCH"):
        if not os.environ.get(key, "0").isdigit():
            fail(f"{key} must be a non-negative integer")

    data_names, _ = repository_map("DATAPLUGIN_REPOS", os.environ.get("DATAPLUGIN_REPOS", "{}"))
    plugin_names, _ = repository_map("PLUGIN_REPOS", os.environ.get("PLUGIN_REPOS", "{}"))
    overlap = set(data_names) & set(plugin_names)
    if overlap:
        fail(f"repositories cannot be both data plugins and plugins: {', '.join(sorted(overlap))}")

    selected_dependencies = os.environ.get("DEPENDENCIES", "").replace(",", " ").split()
    if len(selected_dependencies) != len(set(selected_dependencies)):
        fail("DEPENDENCIES contains duplicate entries")
    scripts_root = Path(os.environ.get("SCRIPTS_ROOT", "scripts"))
    dependency_manifest = Path(os.environ.get("DEPENDENCY_MANIFEST_FILE", scripts_root.parent / "installer_database/dependencies.json")).expanduser()
    if not dependency_manifest.is_absolute():
        dependency_manifest = scripts_root / dependency_manifest
    try:
        sys.path.insert(0, str(scripts_root.parent.resolve()))
        from dependency_config import manifest_data as read_manifest_data
        manifest_data = read_manifest_data(dependency_manifest)
        known_dependencies = {
            item["name"]: item for item in manifest_data["dependencies"]
            if isinstance(item, dict) and isinstance(item.get("name"), str)
        }
    except (OSError, KeyError, TypeError, json.JSONDecodeError) as exc:
        fail(f"dependency manifest is invalid: {exc}")
    unknown_dependencies = set(selected_dependencies) - set(known_dependencies)
    if unknown_dependencies:
        fail(f"DEPENDENCIES names are not in the dependency manifest: {', '.join(sorted(unknown_dependencies))}")
    for key in ("PROJECTS_SOURCE_FILE", "APP_CONFIG_SOURCE_FILE", "APP_ICON_FILE", "DMG_BACKGROUND_IMAGE"):
        value = os.environ.get(key, "").strip()
        if value:
            path = Path(value).expanduser()
            if not path.is_absolute():
                path = Path(os.environ.get("SCRIPTS_ROOT", ".")) / path
            if not path.exists():
                fail(f"{key} does not exist: {path}")

    if os.environ.get("DRY_RUN", "false") != "true":
        if sys.platform != "darwin":
            fail("installer builds require macOS")
        missing_tools = [name for name in ("git", "cmake", "ninja", "xcrun") if shutil.which(name) is None]
        if missing_tools:
            fail(f"required build tools are missing from PATH: {', '.join(missing_tools)}")
        qt_dir = Path(os.environ.get("QT_DIR", "libraries/qt/" + os.environ.get("QT_VERSION", "6.10.3") + "/macos")).expanduser()
        if not (qt_dir / "lib" / "cmake" / "Qt6" / "Qt6Config.cmake").is_file():
            fail(f"Qt {os.environ.get('QT_VERSION', '')} was not found at {qt_dir}; set QT_DIR in the profile")
        for framework in ("QtCore", "QtGui", "QtWidgets"):
            binary = qt_dir / "lib" / f"{framework}.framework" / "Versions" / "A" / framework
            if not binary.is_file() or any(subprocess.run(["lipo", "-verify_arch", arch, str(binary)], capture_output=True).returncode for arch in ("x86_64", "arm64")):
                fail(f"Qt {framework} at {binary} must include x86_64 and arm64 slices")
        vulkan_sdk = Path(os.environ.get("VULKAN_SDK", "")).expanduser()
        if not (vulkan_sdk / "bin" / "glslc").exists() and not (vulkan_sdk / "lib" / "cmake" / "vulkan").exists():
            fail(f"Vulkan SDK was not found at {vulkan_sdk}; set VULKAN_SDK in the profile")
    print(f"Profile '{profile}' is valid (app version {version}; {len(data_names)} data plugins; {len(plugin_names)} plugins).")


if __name__ == "__main__":
    main()
