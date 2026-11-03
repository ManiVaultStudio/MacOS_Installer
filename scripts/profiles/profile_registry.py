"""Export database settings to legacy profiles without discarding custom values."""
from __future__ import annotations

import json
import re
import shlex
from pathlib import Path
from typing import Any




ASSIGNMENT = re.compile(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$")
DEFAULT_ASSIGNMENT = re.compile(r'^\s*:\s*"\$\{([A-Za-z_][A-Za-z0-9_]*):=(.*)\}"\s*$')


def _parse_assignments(path: Path) -> dict[str, str]:
    lines = path.read_text(encoding="utf-8").splitlines()
    values: dict[str, str] = {}
    index = 0
    while index < len(lines):
        default_match = DEFAULT_ASSIGNMENT.match(lines[index])
        if default_match:
            key, value = default_match.groups()
            values[key] = value
            index += 1
            continue
        match = ASSIGNMENT.match(lines[index])
        index += 1
        if not match:
            continue
        key, raw = match.groups()
        raw = raw.strip()
        if raw.startswith("'") and not raw.endswith("'"):
            chunks = [raw[1:]]
            while index < len(lines):
                piece = lines[index]
                index += 1
                if piece.endswith("'"):
                    chunks.append(piece[:-1])
                    break
                chunks.append(piece)
            raw = "\n".join(chunks)
        elif raw.startswith('"') and raw.endswith('"'):
            raw = raw[1:-1]
        elif raw.startswith("'") and raw.endswith("'"):
            raw = raw[1:-1]
        else:
            try:
                parts = shlex.split(raw, comments=True, posix=True)
                raw = parts[0] if parts else ""
            except ValueError as exc:
                raise ValueError(f"{path.name}: invalid value for {key}: {exc}") from exc
        values[key] = raw
    return values


def _profile_id(path: Path, values: dict[str, str]) -> str:
    value = values.get("PROFILE_NAME", "").strip() or path.stem
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", value):
        raise ValueError(f"{path.name}: PROFILE_NAME must contain only letters, digits, dots, underscores, or hyphens")
    return value


def write_managed_profile(path: Path, project: dict[str, Any], repositories: list[dict[str, Any]] | None = None) -> None:
    """Create a minimal discovery record for profiles created in the UI."""
    previous = path.read_text(encoding="utf-8") if path.exists() else ""
    marker = "# Managed configuration overrides"
    prefix = previous.split(marker, 1)[0].rstrip() if previous and "# Managed by ManiVault Installer Creator" not in previous else ""
    profile = str(project.get("Profile ID", "")).strip()
    if not profile:
        raise ValueError("Cannot write a project profile without an ID")
    values = {
        "PROFILE_NAME": profile, "APP_NAME": project.get("App bundle", "ManiVault Studio.app"),
        "DISPLAY_NAME": project.get("Display name", profile),
        "APP_VERSION": project.get("App version", "1.0.0"), "BUILD_TYPE": project.get("Build type", "Release"),
        "ARCHS": project.get("Architectures", "arm64;x86_64"), "MIN_MACOS_VERSION": project.get("Minimum macOS", "12.0"),
        "CORE_BRANCH": project.get("Core ref", "main"), "MIN_CORE_VERSION": project.get("Minimum core version", "1.0.0"),
        "CORE_SOURCE_DIR": project.get("Core source directory", ""),
        "CUSTOMIZATION_FOLDER_PRESENT": project.get("Customization folder", "true"),
        "DEPENDENCY_BUILD_MODE": project.get("Dependency mode", "if-missing"),
        "BASE_URL": project.get("Repository base URL", "https://github.com/ManiVaultStudio"),
    }
    grouped: dict[str, list[dict[str, Any]]] = {"plugin": [], "data_plugin": []}
    core_ref = str(project.get("Core ref", "main"))
    for row in repositories or []:
        group = str(row.get("Group", "")).lower()
        if group == "core":
            core_ref = str(row.get("Ref", core_ref))
        elif group in grouped and row.get("Enabled", True):
            grouped[group].append(row)
    values["CORE_BRANCH"] = core_ref
    for key, group in (("DATAPLUGIN_REPOS", "data_plugin"), ("PLUGIN_REPOS", "plugin")):
        pins = grouped[group]
        values[key] = json.dumps({"defaultBranch": core_ref,
                                  "repos": [str(row.get("Repository", "")) for row in pins],
                                  "branchOverrides": {str(row.get("Repository", "")): str(row.get("Ref", core_ref)) for row in pins}},
                                 separators=(",", ":"))
    path.parent.mkdir(parents=True, exist_ok=True)
    shared_defaults = {
        "APP_NAME": "ManiVault Studio.app", "BUILD_TYPE": "Release",
        "ARCHS": "x86_64;arm64", "MIN_MACOS_VERSION": "13.3",
        "CUSTOMIZATION_FOLDER_PRESENT": "true", "DEPENDENCY_BUILD_MODE": "if-missing",
    }
    values = {key: value for key, value in values.items()
              if key not in shared_defaults or str(value) != shared_defaults[key]}
    path.write_text(
        ((prefix + "\n\n" + marker + "\n") if prefix else
         "# Managed by ManiVault Installer Creator\n" + 'source "$SCRIPTS_ROOT/project_profiles/common.env.sh"\n')
        + "\n".join(f"{key}={shlex.quote(str(value))}" for key, value in values.items())
        + "\n", encoding="utf-8")


def remove_profile_file(profiles_dir: Path, profile: str) -> None:
    for path in profiles_dir.glob("*.env"):
        try:
            if _profile_id(path, _parse_assignments(path)) == profile:
                path.unlink()
        except (OSError, ValueError):
            continue
