#!/usr/bin/env python3
"""ManiVault Studio desktop interface, served locally in a browser."""
from __future__ import annotations

import argparse
import datetime as dt
import concurrent.futures
import filecmp
import hashlib
import json
import mimetypes
import os
import re
import signal
import shutil
import subprocess
import sys
import threading
import time
import uuid
import urllib.error
import urllib.request
import webbrowser
import zipfile

try:
    import fcntl  # POSIX single-instance lock (macOS/Linux)
except ImportError:  # pragma: no cover - this app targets macOS
    fcntl = None  # type: ignore[assignment]
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlparse


ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "scripts" / "profiles"))
from instance_control import discover as discover_instances, shutdown_lock, validate_shutdown
from project_dependencies import evaluate as evaluate_readiness, update_requirements
from dependency_config import VERSION_VARIABLES, entries_from_rows, receipts, identity, save_receipt, version_environment
from database_io import load_database, append_log_row, atomic_save_workbook, ensure_log_schema
from profile_registry import remove_profile_file, write_managed_profile

DB = ROOT / "installer_database" / "installer_database.xlsx"
ENGINE = ROOT / "scripts" / "workflow" / "installer_engine.py"
PROJECT_PROFILES = ROOT / "scripts" / "project_profiles"
DEPENDENCY_SOURCE_URLS = {
    "openmp": "https://github.com/llvm/llvm-project.git", "lz4": "https://github.com/lz4/lz4.git",
    "flann": "https://github.com/flann-lib/flann.git", "cups": "https://github.com/OpenPrinting/cups.git",
    "qads": "https://github.com/githubuser0xFFFF/Qt-Advanced-Docking-System.git", "fmt": "https://github.com/fmtlib/fmt.git",
    "kompute": "https://github.com/KomputeProject/kompute.git", "glfw": "https://github.com/glfw/glfw.git",
    "hdilib-vulkan": "https://github.com/biovault/HDILib.git",
}
DB_LOCK = threading.RLock()
APP_STATE: dict[str, Any] = {"process": None, "run_id": "", "output": [], "started": "", "action": "", "profile": "", "status": "ready", "paused": False, "lock": threading.RLock()}
GITHUB_REF_CACHE: dict[str, tuple[float, dict[str, Any]]] = {}
GITHUB_REF_CACHE_LOCK = threading.Lock()

# A single server owns the workspace API. The OS lock is released
# automatically if the process crashes or the machine shuts down.
INSTANCE_LOCK_FILE = ROOT / ".installer_app.lock"
INSTANCE_INFO_FILE = ROOT / ".installer_app.json"
INSTANCE_LOCK_HANDLE = None



def instance_busy() -> bool:
    """Keep health independent of database reads, including during config failures."""
    process = APP_STATE["process"]
    if process is not None and process.poll() is None:
        return True
    for pid_file in (ROOT / ".installer_runtime").glob("*/pid"):
        try:
            pid = int(pid_file.read_text().strip())
            if pid <= 0: continue
            os.kill(pid, 0)
            if process_matches_run(pid, pid_file.parent.name) is not False:
                return True
        except (OSError, ValueError): continue
    return False


def inspect_instance() -> dict[str, Any]:
    """Read the owner's address without needing a healthy project database."""
    try:
        info = json.loads(INSTANCE_INFO_FILE.read_text(encoding="utf-8"))
        port, pid = int(info["port"]), int(info["pid"])
        if port not in range(1, 65536) or pid <= 0:
            return {}
    except (OSError, ValueError, KeyError, TypeError):
        return {}
    result = {"pid": pid, "port": port, "url": f"http://127.0.0.1:{port}", "responding": False, "process_alive": False}
    try:
        os.kill(pid, 0)
        result["process_alive"] = True
    except ProcessLookupError:
        pass
    except PermissionError:
        result["process_alive"] = True
    for endpoint in ("/api/health", "/"):
        try:
            with urllib.request.urlopen(result["url"] + endpoint, timeout=.6) as response:
                if response.status == 200:
                    result["responding"] = True
                    break
        except (OSError, ValueError, urllib.error.URLError):
            continue
    return result


def print_instance_status(info: dict[str, Any] | None = None) -> None:
    info = inspect_instance() if info is None else info
    if not info:
        print("No installer instance has published an address.", flush=True)
        return
    print(f"Installer URL: {info['url']}\nPort: {info['port']}\nProcess ID: {info['pid']}\nHealth: {'responding' if info['responding'] else 'not responding'}", flush=True)
    if not info["responding"]:
        print(f"Inspect the listener: lsof -nP -iTCP:{info['port']} -sTCP:LISTEN", flush=True)
        print("If it is a stalled installer, quit that process in Terminal, then reopen Start.command.", flush=True)


def acquire_single_instance() -> bool:
    """Acquire the workspace lock, or focus the already-running app."""
    global INSTANCE_LOCK_HANDLE
    if fcntl is None:
        raise RuntimeError("This app requires POSIX file locking on macOS or Linux.")

    handle = INSTANCE_LOCK_FILE.open("a+")
    try:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        handle.close()
        deadline = time.monotonic() + 5.0
        info = {}
        while time.monotonic() < deadline:
            info = inspect_instance()
            if info.get("responding"):
                if os.environ.get("INSTALLER_NO_BROWSER") != "1":
                    webbrowser.open_new_tab(info["url"])
                print("The installer is already running.", flush=True)
                print_instance_status(info)
                return False
            time.sleep(.2)
        print_instance_status(info)
        raise SystemExit("Another installer owns this workspace lock. Use the URL/port above or run: bash Start.command --status")

    INSTANCE_LOCK_HANDLE = handle
    return True


def write_instance_info(url: str, port: int) -> None:
    atomic_json_write(INSTANCE_INFO_FILE, {
        "pid": os.getpid(),
        "url": url,
        "port": port,
        "started": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
    })


def release_single_instance() -> None:
    global INSTANCE_LOCK_HANDLE
    try:
        INSTANCE_INFO_FILE.unlink(missing_ok=True)
    except OSError:
        pass
    if INSTANCE_LOCK_HANDLE is not None:
        try:
            if fcntl is not None:
                fcntl.flock(INSTANCE_LOCK_HANDLE.fileno(), fcntl.LOCK_UN)
            INSTANCE_LOCK_HANDLE.close()
        finally:
            INSTANCE_LOCK_HANDLE = None


def process_matches_run(pid: int, run_id: str) -> bool | None:
    """Return False for a reused PID, True for this engine, None if unverifiable."""
    try:
        check = subprocess.run(
            ["ps", "-p", str(pid), "-o", "command="],
            capture_output=True, text=True, timeout=3, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if check.returncode != 0 or not check.stdout.strip():
        return False
    command_line = check.stdout.strip()
    return str(ENGINE) in command_line and run_id in command_line


def local_process_is_active() -> bool:
    with APP_STATE["lock"]:
        process = APP_STATE["process"]
        return process is not None and process.poll() is None


def open_database(**options: Any):
    options.setdefault("include_history", False)
    for attempt in range(5):
        try:
            return load_database(DB, **options)
        except zipfile.BadZipFile:
            if attempt == 4:
                raise
            time.sleep(0.04 * (attempt + 1))


def ensure_dependency_schema() -> None:
    with DB_LOCK:
        workbook = open_database()
        try:
            sheet = workbook["Dependencies"]
            headers = {str(sheet.cell(1, col).value): col for col in range(1, sheet.max_column + 1)}
            changed = False
            if "Source URL" not in headers:
                column = sheet.max_column + 1
                sheet.cell(1, column).value = "Source URL"
                headers["Source URL"] = column
                changed = True
            for row in range(2, sheet.max_row + 1):
                name = str(sheet.cell(row, headers["Name"]).value or "").strip()
                cell = sheet.cell(row, headers["Source URL"])
                if not cell.value and name in DEPENDENCY_SOURCE_URLS:
                    cell.value = DEPENDENCY_SOURCE_URLS[name]
                    changed = True
            if changed:
                atomic_save_workbook(workbook, DB)
        finally:
            workbook.close()


def generated_dependency_script(name: str) -> str:
    safe = re.sub(r"[^A-Za-z0-9_]+", "_", name).strip("_")
    if not safe or not safe[0].isalpha():
        raise ValueError("Dependency name must start with a letter and contain only letters, numbers, dots, plus signs, or hyphens.")
    return f"build_{safe}.sh"


def write_dependency_script(name: str, script_name: str) -> None:
    if Path(script_name).name != script_name or not script_name.endswith(".sh"):
        raise ValueError("Build script must be a .sh file under scripts/dependencies.")
    path = ROOT / "scripts" / "dependencies" / script_name
    if path.exists():
        old = path.read_text(encoding="utf-8", errors="replace")
        if "# Generated by ManiVault Studio" not in old:
            return
    safe_name = re.sub(r"[^A-Za-z0-9_.+-]", "_", name)
    body = f'''#!/usr/bin/env bash
set -euo pipefail
# Generated by ManiVault Studio. Edit the dependency recipe in the UI.
SCRIPT_DIR="$(cd "$(dirname "${{BASH_SOURCE[0]}}")" && pwd)"
exec "${{PYTHON:-python3}}" "$SCRIPT_DIR/dependency_recipe.py" \\
  --name "${{DEPENDENCY_NAME:-{safe_name}}}" \\
  --version "${{DEPENDENCY_VERSION:?Pinned version is required}}" \\
  --linkage "${{DEPENDENCY_LINKAGE:-static}}" \\
  --recipe "${{DEPENDENCY_RECIPE_JSON:?Dependency recipe is missing}}"
'''
    path.write_text(body, encoding="utf-8")
    path.chmod(0o755)


def read_rows(sheet_name: str) -> list[dict[str, Any]]:
    with DB_LOCK:
        workbook = open_database(read_only=True, data_only=True, include_history=sheet_name in {"Runs", "Logs"}, tables=[sheet_name])
        try:
            if sheet_name not in workbook.sheetnames:
                return []
            sheet = workbook[sheet_name]
            rows = list(sheet.iter_rows(values_only=True))
            if not rows:
                return []
            headers = [str(value).strip() if value is not None else "" for value in rows[0]]
            result = [dict(zip(headers, row)) for row in rows[1:] if any(value is not None for value in row)]
            if sheet_name == "Runs":
                latest: dict[str, dict[str, Any]] = {}
                for item in result:
                    latest[str(item.get("Run ID", ""))] = item
                return list(latest.values())
            return result
        finally:
            workbook.close()


LOG_VIEW_CACHE: dict[str, tuple[int, list[dict[str, Any]]]] = {}


def log_revision(run_id: str) -> str:
    parts = [run_id]
    for path in [DB.parent / "local/logs.json", ROOT / ".installer_runtime" / run_id / "live.log"]:
        try:
            stat = path.stat()
            parts.append(f"{stat.st_mtime_ns}:{stat.st_size}")
        except OSError: parts.append("missing")
    return "|".join(parts)


def logs_for_run(run_id: str) -> list[dict[str, Any]]:
    if not run_id:
        return []
    path = DB.parent / "local/logs.json"
    revision = path.stat().st_mtime_ns if path.exists() else 0
    cached = LOG_VIEW_CACHE.get(run_id)
    if cached and cached[0] == revision:
        return cached[1]
    rows = [row for row in read_rows("Logs") if str(row.get("Run ID")) == run_id][-4000:]
    if len(LOG_VIEW_CACHE) >= 8:
        LOG_VIEW_CACHE.pop(next(iter(LOG_VIEW_CACHE)))
    LOG_VIEW_CACHE[run_id] = revision, rows
    return rows


def read_settings() -> dict[str, str]:
    defaults = {
        "Out path": str(ROOT / "application"),
        "In path": str(ROOT / "installer_inbox"),
    }
    with DB_LOCK:
        workbook = open_database()
        changed = False
        if "Settings" not in workbook.sheetnames:
            sheet = workbook.create_sheet("Settings")
            sheet.append(["Setting", "Value", "Description"])
            changed = True
        sheet = workbook["Settings"]
        if sheet.cell(1, 1).value != "Setting":
            sheet.delete_rows(1, sheet.max_row)
            sheet.append(["Setting", "Value", "Description"])
            changed = True
        values = {
            str(sheet.cell(row, 1).value): str(sheet.cell(row, 2).value or "").strip()
            for row in range(2, sheet.max_row + 1) if sheet.cell(row, 1).value
        }
        for key, value in defaults.items():
            if not values.get(key):
                values[key] = value
                stored = str(Path(value).relative_to(ROOT)) if Path(value).is_relative_to(ROOT) else value
                sheet.append([key, stored, "DMG folder path"])
                changed = True
        if changed:
            atomic_save_workbook(workbook, DB)
        workbook.close()
    for key in defaults:
        path = Path(values[key]).expanduser()
        if not path.is_absolute():
            values[key] = str(ROOT / path)
    return values


def save_settings(values: dict[str, Any]) -> dict[str, str]:
    saved: dict[str, str] = {}
    for key in ("Out path", "In path"):
        raw = str(values.get(key, "")).strip()
        if not raw or "\x00" in raw or "\n" in raw or "\r" in raw:
            raise ValueError(f"Enter a valid folder path for {key}.")
        path = Path(raw).expanduser()
        if not path.is_absolute():
            path = ROOT / path
        saved[key] = str(path.resolve())
    with DB_LOCK:
        workbook = open_database()
        if "Settings" not in workbook.sheetnames:
            sheet = workbook.create_sheet("Settings")
            sheet.append(["Setting", "Value", "Description"])
        sheet = workbook["Settings"]
        positions = {str(sheet.cell(row, 1).value): row for row in range(2, sheet.max_row + 1) if sheet.cell(row, 1).value}
        for key, value in saved.items():
            row = positions.get(key)
            if row is None:
                stored = str(Path(value).relative_to(ROOT)) if Path(value).is_relative_to(ROOT) else value
                sheet.append([key, stored, "DMG folder path"])
            else:
                sheet.cell(row, 2).value = str(Path(value).relative_to(ROOT)) if Path(value).is_relative_to(ROOT) else value
        atomic_save_workbook(workbook, DB)
        workbook.close()
    return saved


def collect_installers() -> list[dict[str, Any]]:
    found: dict[str, dict[str, Any]] = {}
    out_path = Path(read_settings()["Out path"]).expanduser().resolve()
    if not out_path.is_dir():
        return []
    for path in out_path.rglob("*.dmg"):
        resolved = path.resolve()
        if not resolved.is_file() or not resolved.is_relative_to(out_path):
            continue
        stat = resolved.stat()
        version_match = re.search(r"_v(\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?)_", resolved.name)
        project = resolved.name.split("_v", 1)[0] if "_v" in resolved.name else resolved.stem
        identifier = hashlib.sha256(str(resolved).encode()).hexdigest()
        found[identifier] = {
            "id": identifier,
            "sourcePath": str(resolved),
            "name": resolved.name,
            "project": project,
            "version": version_match.group(1) if version_match else "",
            "size": f"{stat.st_size / (1024 * 1024):.1f} MB",
            "modified": dt.datetime.fromtimestamp(stat.st_mtime, dt.timezone.utc).isoformat(timespec="seconds"),
        }
    return sorted(found.values(), key=lambda item: item["modified"], reverse=True)


def dependency_catalog() -> dict[str, Any]:
    """Combine built library recipes and verified shared source pins for the UI."""
    libraries_root = ROOT / "libraries"
    entries = entries_from_rows(read_rows("Dependencies"))
    installed_versions = receipts(libraries_root)
    items: list[dict[str, Any]] = []
    for row in read_rows("Dependencies"):
        name = str(row.get("Name") or "").strip()
        if not name:
            continue
        try:
            artifacts = json.loads(str(row.get("Artifacts JSON") or "[]"))
        except json.JSONDecodeError:
            artifacts = []
        artifact_paths = [ROOT / str(value) for value in artifacts if isinstance(value, str)]
        installed = bool(artifact_paths) and all(
            path.is_file() or (path.is_dir() and any(child.is_file() for child in path.rglob("*")))
            for path in artifact_paths
        )
        entry = next(entry for entry in entries if entry["name"] == name)
        saved = installed_versions.get(name)
        if saved and saved.get("identity") != identity(entry, entries):
            installed = False
        items.append({
            "kind": "recipe", "name": name,
            "version": str(row.get("Version / commit") or "Unpinned"),
            "installed": installed, "enabled": bool(row.get("Enabled", True)),
            "linkage": str(row.get("Linkage") or "unknown"),
            "detail": str(row.get("Build Script") or "Generic build recipe"),
            "sourceUrl": str(row.get("Source URL") or DEPENDENCY_SOURCE_URLS.get(name, "")),
            **{key: json.loads(str(row.get(column) or fallback)) for key, column, fallback in (
                ("artifacts", "Artifacts JSON", "[]"), ("runtimeArtifacts", "Runtime Files JSON", "[]"),
                ("requires", "Requires JSON", "[]"), ("recipe", "Recipe JSON", "{}"))},
        })

    manifest_path = ROOT / "installer_database" / "source_pins.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    cache_folders: dict[str, dict[str, str]] = {}
    for folder in libraries_root.iterdir() if libraries_root.is_dir() else []:
        if not folder.is_dir():
            continue
        marker = folder / ".installer-version"
        if marker.is_file():
            cache_folders[folder.name] = {"folder": folder.name, "version": marker.read_text(encoding="utf-8").strip()}
        elif (folder / ".git").exists():
            check = subprocess.run(["git", "describe", "--tags", "--exact-match", "HEAD"], cwd=folder,
                                   capture_output=True, text=True)
            if check.returncode == 0:
                cache_folders[folder.name] = {"folder": folder.name, "version": check.stdout.strip()}
    for entry in manifest.get("dependencies", []):
        name = str(entry.get("name") or "").strip()
        source_name = str(entry.get("source") or "").strip()
        if not name or not source_name:
            continue
        source = (libraries_root / source_name).resolve()
        if not source.is_relative_to(libraries_root.resolve()):
            continue
        expected = str(entry.get("version") or entry.get("git_tag") or "").strip()
        if entry.get("version_file"):
            marker = source / str(entry["version_file"])
            actual = marker.read_text(encoding="utf-8").strip() if marker.is_file() else ""
            verified = source.is_dir() and actual == expected
        else:
            check = subprocess.run(["git", "describe", "--tags", "--exact-match", "HEAD"], cwd=source,
                                   capture_output=True, text=True) if source.is_dir() else None
            actual = check.stdout.strip() if check and check.returncode == 0 else ""
            verified = actual == expected
        integration = "CPM" if str(entry.get("cmake_variable", "")).startswith("CPM_") else "FetchContent"
        items.append({"kind": "pin", "name": name, "version": expected or "Unpinned",
                      "installed": verified, "enabled": True, "linkage": integration,
                      "detail": f"libraries/{source_name}", "source": source_name,
                      "cmake_variable": str(entry.get("cmake_variable") or ""),
                      "sourceUrl": str(entry.get("sourceUrl") or "")})
        if verified:
            cache_folders[source_name] = {"folder": source_name, "version": expected}

    requirements = read_rows("ProjectDependencies")
    projects = {str(project["Profile ID"]): project for project in read_rows("Projects")}
    for item in items:
        item["projects"] = [{"id": str(row["Profile ID"]), "name": projects.get(str(row["Profile ID"]), {}).get("Display name", row["Profile ID"]), "version": str(row.get("Version") or "")}
                            for row in requirements if row.get("Dependency") == item["name"] and row.get("Kind") == item["kind"] and str(row.get("Profile ID")) in projects and str(row.get("Required")).lower() in {"true", "1", "yes"}]
        item["requiredBy"] = [other["name"] for other in items if item["kind"] == "recipe" and item["name"] in other.get("requires", []) and other.get("installed")]
    return {"items": items, "projects": [{"id": key, "name": value["Display name"]} for key, value in projects.items()], "cacheFolders": sorted(cache_folders.values(), key=lambda item: item["folder"].lower())}


def save_dependency_pin(values: dict[str, Any]) -> None:
    name = str(values.get("Name", "")).strip()
    version = str(values.get("Version", "")).strip()
    source_name = str(values.get("Source folder", "")).strip()
    source_url = str(values.get("Source URL") or "").strip()
    integration = str(values.get("Integration", "CPM")).strip()
    custom_variable = str(values.get("CMake source variable", "")).strip()
    if not re.fullmatch(r"[A-Za-z0-9_.+-]+", name) or not version or any(c in version for c in "\n\r\0"):
        raise ValueError("Enter a dependency name and pinned version.")
    if integration not in {"CPM", "FetchContent"}:
        raise ValueError("Choose CPM or FetchContent integration.")
    library_root = (ROOT / "libraries").resolve()
    if not source_name or Path(source_name).name != source_name or source_name in {".", ".."}:
        source_name = re.sub(r"[^A-Za-z0-9._-]+", "-", f"{name}-{version}").strip(".-")
    source = (library_root / source_name).resolve()
    if not source.is_relative_to(library_root):
        raise ValueError("The dependency source folder must stay inside the shared libraries cache.")
    if not source_url:
        old_manifest = json.loads((ROOT / "installer_database/source_pins.json").read_text())
        old_entry = next((entry for entry in old_manifest.get("dependencies", []) if entry.get("name") == name), {})
        source_url = str(old_entry.get("sourceUrl") or DEPENDENCY_SOURCE_URLS.get(name) or "")
    if source_url and not re.fullmatch(r"https://(?:github|gitlab)\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:\.git)?", source_url):
        raise ValueError("Use a GitHub or GitLab HTTPS repository URL.")
    # A version change always selects a new cache folder; never relabel an old checkout.
    manifest_path = ROOT / "installer_database/source_pins.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    old_entry = next((entry for entry in manifest.get("dependencies", []) if entry.get("name") == name), {})
    old_version = str(old_entry.get("version") or old_entry.get("git_tag") or "")
    if old_version != version and source_name == str(old_entry.get("source") or ""):
        source_name = re.sub(r"[^A-Za-z0-9._-]+", "-", f"{name}-{version}").strip(".-")
    pin_metadata = ({"git_tag": version} if old_entry.get("git_tag") == version
                    else {"version_file": ".installer-version", "version": version})
    variable = custom_variable or (
        f"CPM_{name}_SOURCE" if integration == "CPM"
        else "FETCHCONTENT_SOURCE_DIR_" + re.sub(r"[^A-Za-z0-9]", "_", name.upper())
    )
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_-]*", variable):
        raise ValueError("CMake source variable must contain letters, numbers, underscores, or hyphens.")

    manifest_path = ROOT / "installer_database" / "source_pins.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    entries = manifest.setdefault("dependencies", [])
    replacement = {**{k: v for k, v in old_entry.items() if k not in {"git_tag", "version", "version_file"}}, "name": name, "source": source_name, **pin_metadata, "cmake_variable": variable,
                   "sourceUrl": source_url}
    existing = next((index for index, entry in enumerate(entries) if str(entry.get("name", "")) == name), None)
    if existing is None:
        entries.append(replacement)
    else:
        # Switching the active version never removes the previous versioned cache.
        entries[existing] = replacement
    with DB_LOCK:
        workbook = open_database()
        try:
            assigned = json.loads(str(values["Projects"])) if "Projects" in values else None
            if assigned is not None and (not isinstance(assigned, list) or set(assigned) - {str(row["Profile ID"]) for row in read_rows("Projects")}):
                raise ValueError("Choose existing projects for this source.")
            preserved = any(row.get("Dependency") == name and row.get("Kind") == "pin" for row in read_rows("ProjectDependencies"))
            if existing is None and not assigned and preserved:
                assigned = None
            update_requirements(workbook, name, "pin", version, profiles=assigned,
                                update_versions=str(values.get("Update projects", "false")).lower() in {"true", "1", "yes"})
            # Pins and project assignments share the database recovery journal.
            from database_io import save_source_pins
            save_source_pins(workbook, DB, manifest)
        finally:
            workbook.close()


def update_build_dependency(values: dict[str, Any]) -> None:
    name = str(values.get("Name", "")).strip()
    existing = next((row for row in read_rows("Dependencies") if str(row.get("Name")) == name), None)
    if existing is None:
        raise ValueError("This library is no longer registered.")
    values = {**existing, **values}
    old_version = str(existing.get("Version / commit") or "")
    new_version = str(values.get("Version / commit") or "").strip()
    if name in VERSION_VARIABLES and re.match(r"^v\d", new_version):
        new_version = new_version[1:]
        values["Version / commit"] = new_version
    old_pin = old_version.split()[0] if old_version else ""
    new_pin = new_version.split()[0] if new_version else ""
    if old_version.startswith("HDF5") and old_version != new_version:
        old_parts = re.fullmatch(r"HDF5\s+(\S+)\s*/\s*zlib\s+(\S+)", old_version)
        new_parts = re.fullmatch(r"HDF5\s+(\S+)\s*/\s*zlib\s+(\S+)", new_version)
        if not new_parts:
            raise ValueError("Use HDF5 <version> / zlib <version>.")
        if old_parts:
            for field in ("Artifacts JSON", "Runtime Files JSON", "Recipe JSON"):
                if values.get(field) == existing.get(field) and values.get(field):
                    for old, new in zip(old_parts.groups(), new_parts.groups()):
                        values[field] = str(values[field]).replace(old, new)
    if old_pin and old_pin != new_pin and not old_version.startswith("HDF5"):
        for field in ("Artifacts JSON", "Runtime Files JSON", "Recipe JSON"):
            if values.get(field) == existing.get(field) and values.get(field):
                values[field] = str(values[field]).replace(old_pin, new_pin)
    version = str(values.get("Version / commit", "")).strip()
    linkage = str(values.get("Linkage", "shared")).strip()
    build_script = str(values.get("Build Script", "")).strip()
    source_url = str(values.get("Source URL") or "").strip()
    enabled = str(values.get("Enabled", "true")).lower() in {"true", "yes", "1", "on"}
    if not name or not version or linkage not in {"static", "shared", "both", "header-only"}:
        raise ValueError("Provide a version and valid library linkage type.")
    try:
        artifacts = json.loads(str((values.get("Artifacts JSON") or "[]")))
        runtime_files = json.loads(str((values.get("Runtime Files JSON") or "[]")))
        requires = json.loads(str((values.get("Requires JSON") or "[]")))
        recipe = json.loads(str((values.get("Recipe JSON") or "{}")))
    except json.JSONDecodeError as exc:
        raise ValueError(f"Dependency settings contain invalid JSON: {exc}") from exc
    if not all(isinstance(value, list) for value in (artifacts, runtime_files, requires)) or not isinstance(recipe, dict):
        raise ValueError("Dependency outputs and prerequisites must be JSON lists, and the recipe must be a JSON object.")
    candidate = {"name": name, "version": version}
    version_environment([candidate])
    if any(not isinstance(value, str) for group in (artifacts, runtime_files, requires) for value in group):
        raise ValueError("Outputs and prerequisites must contain text values.")
    known_names = {str(row.get("Name")) for row in read_rows("Dependencies")}
    if name in requires or set(requires) - known_names:
        raise ValueError("Choose registered prerequisites other than this library.")
    candidate_entries = entries_from_rows([{**row, **values} if str(row.get("Name")) == name else row for row in read_rows("Dependencies")])
    for candidate_entry in candidate_entries:
        identity(candidate_entry, candidate_entries)
        from dependency_actions import output_paths
        output_paths(ROOT, candidate_entry)
    if old_version != version:
        entries = entries_from_rows(read_rows("Dependencies"))
        for entry in entries:
            saved = receipts(ROOT / "libraries")
            if entry["name"] not in saved:
                from dependency_actions import output_paths
                paths = output_paths(ROOT, entry)
                if paths and all(path.exists() for path in paths):
                    save_receipt(ROOT / "libraries", entry, entries)
    if isinstance(recipe.get("source"), dict) and recipe["source"].get("type", "git") == "git" and source_url:
        recipe.setdefault("source", {})["url"] = source_url
        recipe["source"]["ref"] = version
    build_script = build_script or "GENERIC"
    if build_script.upper() == "GENERIC":
        build_script = generated_dependency_script(name)
        write_dependency_script(name, build_script)
    with DB_LOCK:
        workbook = open_database()
        try:
            sheet = workbook["Dependencies"]
            headers = {str(sheet.cell(1, col).value): col for col in range(1, sheet.max_column + 1)}
            target_row = next((row for row in range(2, sheet.max_row + 1)
                               if str(sheet.cell(row, headers["Name"]).value) == name), None)
            if target_row is None:
                raise ValueError(f"Build dependency {name} no longer exists.")
            sheet.cell(target_row, headers["Version / commit"]).value = version
            sheet.cell(target_row, headers["Enabled"]).value = enabled
            sheet.cell(target_row, headers["Linkage"]).value = linkage
            sheet.cell(target_row, headers["Build Script"]).value = build_script
            if "Source URL" in headers:
                sheet.cell(target_row, headers["Source URL"]).value = source_url
            sheet.cell(target_row, headers["Artifacts JSON"]).value = json.dumps(artifacts, separators=(",", ":"))
            sheet.cell(target_row, headers["Runtime Files JSON"]).value = json.dumps(runtime_files, separators=(",", ":"))
            sheet.cell(target_row, headers["Requires JSON"]).value = json.dumps(requires, separators=(",", ":"))
            sheet.cell(target_row, headers["Recipe JSON"]).value = json.dumps(recipe, separators=(",", ":"))
            assigned = json.loads(str(values["Projects"])) if "Projects" in values else None
            if assigned is not None and (not isinstance(assigned, list) or set(assigned) - {str(row["Profile ID"]) for row in read_rows("Projects")}):
                raise ValueError("Choose existing projects for this library.")
            update_requirements(workbook, name, "recipe", version, profiles=assigned,
                                update_versions=str(values.get("Update projects", "false")).lower() in {"true", "1", "yes"})
            atomic_save_workbook(workbook, DB)
        finally:
            workbook.close()


def atomic_json_write(destination: Path, data: dict[str, Any]) -> None:
    temporary = destination.with_name(f".{destination.name}.{uuid.uuid4().hex}.tmp")
    try:
        temporary.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)


def copy_installer(installer_id: str) -> str:
    installer = next((item for item in collect_installers() if item["id"] == installer_id), None)
    if installer is None:
        raise ValueError("This installer is no longer available in the configured Out path.")
    source = Path(installer["sourcePath"])
    destination_dir = Path(read_settings()["In path"]).expanduser()
    destination_dir.mkdir(parents=True, exist_ok=True)
    destination = destination_dir / source.name
    if source.resolve() == destination.resolve():
        return str(destination)
    if destination.exists():
        if filecmp.cmp(source, destination, shallow=False):
            return str(destination)
        raise ValueError(f"A different installer already exists at {destination}; move it before copying.")
    shutil.copy2(source, destination)
    return str(destination)


def record_installer_copy(run_id: str, profile: str, source: str, destination: str, error: str = "") -> None:
    with DB_LOCK:
        workbook = open_database(include_history=True, tables=["Runs", "Logs"])
        try:
            runs = workbook["Runs"]
            headers = {str(runs.cell(1, col).value): col for col in range(1, runs.max_column + 1)}
            for row in range(2, runs.max_row + 1):
                if str(runs.cell(row, headers["Run ID"]).value) != run_id:
                    continue
                if error:
                    runs.cell(row, headers["Status"]).value = "needs-attention"
                    runs.cell(row, headers["Summary"]).value = f"Installer created, but copying to the In path failed: {error}"
                else:
                    runs.cell(row, headers["DMG path"]).value = source
                    runs.cell(row, headers["Summary"]).value = f"Installer created and copied to {destination}"
                break
            logs = workbook["Logs"]
            ensure_log_schema(workbook)
            append_log_row(logs, run_id, profile, "WARNING" if error else "INFO", "installer copy",
                           error if error else f"Installer copied from Out path to In path: {destination}")
            atomic_save_workbook(workbook, DB)
        finally:
            workbook.close()

def mark_run_interrupted(run_id: str, reason: str, status: str = "interrupted") -> None:
    with DB_LOCK:
        workbook = open_database(include_history=True, tables=["Runs", "Logs"])
        try:
            sheet = workbook["Runs"]
            headers = {
                str(sheet.cell(1, col).value): col
                for col in range(1, sheet.max_column + 1)
            }

            required = {"Run ID", "Status", "Finished UTC", "Summary"}
            if not required.issubset(headers):
                raise ValueError("Runs sheet is missing required columns.")

            changed = False
            for row in range(2, sheet.max_row + 1):
                if str(sheet.cell(row, headers["Run ID"]).value) != run_id:
                    continue

                # Never overwrite a result that has already been recorded.
                if str(sheet.cell(row, headers["Status"]).value).lower() != "running":
                    break

                sheet.cell(row, headers["Status"]).value = status
                sheet.cell(row, headers["Finished UTC"]).value = (
                    dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")
                )
                sheet.cell(row, headers["Summary"]).value = reason
                changed = True
                break

            if changed:
                ensure_log_schema(workbook)
                append_log_row(
                    workbook["Logs"],
                    run_id,
                    "",
                    "ERROR",
                    "run recovery",
                    reason,
                )
                atomic_save_workbook(workbook, DB)
        finally:
            workbook.close()


def external_live_run() -> dict[str, Any] | None:
    startup_grace_seconds = 90

    for run in reversed(read_rows("Runs")):
        if str(run.get("Status", "")).lower() != "running":
            continue

        run_id = str(run.get("Run ID", "")).strip()
        if not run_id:
            continue

        runtime = ROOT / ".installer_runtime" / run_id
        pid_file = runtime / "pid"
        try:
            started = dt.datetime.fromisoformat(
                str(run.get("Started UTC", "")).replace("Z", "+00:00")
            )
            if started.tzinfo is None:
                started = started.replace(tzinfo=dt.timezone.utc)
            age = (dt.datetime.now(dt.timezone.utc) - started).total_seconds()
        except (ValueError, TypeError):
            try:
                age = time.time() - runtime.stat().st_mtime
            except OSError:
                age = startup_grace_seconds + 1

        pid: int | None = None
        if pid_file.is_file():
            try:
                pid = int(pid_file.read_text(encoding="utf-8").strip())
                if pid <= 0:
                    raise ValueError("Invalid process ID")
            except (ValueError, OSError):
                pid = None

        if pid is None:
            if age > startup_grace_seconds:
                mark_run_interrupted(
                    run_id,
                    "The build did not create a valid process ID file. It may have "
                    "been terminated during startup. You can safely retry.",
                )
                continue
            # A run row can be committed a moment before the engine writes its PID.
            process_alive = True
            startup_pending = True
        else:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                mark_run_interrupted(
                    run_id,
                    "The build process is no longer running. It was interrupted "
                    "before recording a final result. You can retry.",
                )
                continue
            except PermissionError:
                # The process exists but this server cannot signal it.
                pass
            except OSError:
                # An uncertain process state must not unlock the workspace.
                process_alive = True
            else:
                identity = process_matches_run(pid, run_id)
                if identity is False:
                    mark_run_interrupted(
                        run_id,
                        "The recorded process ID now belongs to a different process. "
                        "This build is no longer running and was marked interrupted.",
                    )
                    continue
            process_alive = True
            startup_pending = False

        live_log = runtime / "live.log"
        output: list[str] = []
        if live_log.is_file():
            try:
                with live_log.open(encoding="utf-8", errors="replace") as stream:
                    output = list(deque(
                        (line.rstrip() for line in stream if line.strip()), maxlen=30
                    ))
            except OSError:
                output = []
        if not output and run.get("Summary"):
            output = [str(run["Summary"])]
        if startup_pending:
            output = output[-29:] + ["Starting build engine…"]

        try:
            workflow_stage = int(json.loads((runtime / "stage.json").read_text())["number"])
        except (OSError, ValueError, KeyError, TypeError):
            workflow_stage = None
        return {
            "workflowStage": workflow_stage,
            "run_id": run_id,
            "action": run.get("Action", "build"),
            "profile": run.get("Profile ID", ""),
            "status": "starting" if startup_pending else "running",
            "started": run.get("Started UTC", ""),
            "output": output,
            "active": process_alive,
            "external": True,
        }

    return None

def logs_with_live_fallback(runs: list[dict[str, Any]], logs: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Expose a run's live output until its completed log rows are saved."""
    logged_ids = {str(row.get("Run ID", "")) for row in logs}
    result = list(logs)
    severity = re.compile(r"\b(error|failed|failure|fatal|warning|warn)\b", re.IGNORECASE)
    for run in runs:
        run_id = str(run.get("Run ID", "")).strip()
        if not run_id or run_id in logged_ids:
            continue
        live_log = ROOT / ".installer_runtime" / run_id / "live.log"
        if not live_log.is_file():
            continue
        try:
            with live_log.open(encoding="utf-8", errors="replace") as stream:
                lines = list(deque(stream, maxlen=4000))
        except OSError:
            continue
        for line in lines:
            message_text = line.strip()
            if not message_text:
                continue
            match = severity.search(message_text)
            level = "ERROR" if match and match.group(1).lower() in {"error", "failed", "failure", "fatal"} else "WARNING" if match else "INFO"
            result.append({"Run ID": run_id, "Profile ID": run.get("Profile ID", ""),
                           "Level": level, "Stage": "live output", "Message": message_text})
    return result


def run_engine(payload: dict[str, Any]) -> None:
    with APP_STATE["lock"]:
        process = APP_STATE["process"]
        run_id = APP_STATE["run_id"]
        profile = APP_STATE["profile"]
        action = APP_STATE["action"]
        started = APP_STATE["started"]
    if process is None:
        return

    code = -1
    try:
        if process.stdout is not None:
            for line in process.stdout:
                with APP_STATE["lock"]:
                    marker = re.search(r"\[studio-stage:(\d):(running|completed|failed)\]", line)
                    if marker:
                        APP_STATE["workflowStage"] = int(marker[1])
                    APP_STATE["output"].append(line.rstrip())
                    APP_STATE["output"] = APP_STATE["output"][-500:]
        code = process.wait()

        if code == 0 and action in {"full", "all", "package"}:
            with APP_STATE["lock"]:
                APP_STATE["output"].append("Build complete. Copying the new DMG from Out path to In path…")
            try:
                started_time = dt.datetime.fromisoformat(started)
                cutoff = started_time if action == "all" else started_time - dt.timedelta(seconds=10)
                recent = [item for item in collect_installers()
                          if dt.datetime.fromisoformat(item["modified"]) >= cutoff]
                if recent:
                    copied = []
                    for installer in (recent if action == "all" else recent[:1]):
                        destination = copy_installer(installer["id"])
                        record_installer_copy(run_id, installer["project"], installer["sourcePath"], destination)
                        copied.append(destination)
                    line = f"Copied {len(copied)} installer(s) to the configured In path."
                else:
                    line = "Build finished, but no new DMG was found in the configured Out path."
                    record_installer_copy(run_id, profile, "", "", line)
            except Exception as exc:
                line = f"Installer created, but copy to the configured In path failed: {exc}"
                try:
                    record_installer_copy(run_id, profile, "", "", str(exc))
                except Exception:
                    pass
            with APP_STATE["lock"]:
                APP_STATE["output"].append(line)
                APP_STATE["output"] = APP_STATE["output"][-500:]
    except Exception as exc:
        with APP_STATE["lock"]:
            APP_STATE["output"].append(f"Engine monitor error: {exc}")
        code = process.poll() if process.poll() is not None else -1
    finally:
        try:
            if process.stdout is not None:
                process.stdout.close()
        except OSError:
            pass
        rows = read_rows("Runs")
        run_row = next((row for row in rows if row.get("Run ID") == run_id), {})
        recorded_status = str(run_row.get("Status") or "").lower()
        if recorded_status == "running":
            # The engine exited without finalizing its own run record.
            recovery_status = "interrupted" if code in {-9, 137, -15, 143, 130} else "failed"
            mark_run_interrupted(
                run_id,
                (f"Engine exit code {code}. " +
                 ("The operating system killed the engine; possible memory pressure. Choose Low memory in Build limits and retry. " if code in {-9, 137} else
                  "The engine received a termination signal. " if code in {-15, 143} else
                  "The engine stopped before finalizing the run. ") +
                 "Recent output: " + " | ".join(APP_STATE["output"][-6:])),
                status=recovery_status,
            )
            recorded_status = recovery_status
        if not recorded_status:
            recorded_status = "succeeded" if code == 0 else "failed"
        with APP_STATE["lock"]:
            APP_STATE["status"] = recorded_status
            APP_STATE["process"] = None
            APP_STATE["paused"] = False

def pause_or_resume(paused: bool) -> None:
    with APP_STATE["lock"]:
        process = APP_STATE["process"]
        if process is None or process.poll() is not None:
            raise ValueError("Pause and resume are available for an active build started from this app.")
        if APP_STATE["paused"] == paused:
            return
        try:
            os.killpg(process.pid, signal.SIGUSR1 if paused else signal.SIGUSR2)
        except OSError as exc:
            raise ValueError(f"Could not {'pause' if paused else 'resume'} the build: {exc}") from exc
        APP_STATE["paused"] = paused
        APP_STATE["status"] = "paused" if paused else "running"


def validate_build_settings(payload: dict[str, Any]) -> tuple[int, str]:
    """Use the same limits for direct builds and installer creation."""
    raw = payload.get("jobs", 0)
    try:
        jobs = int(raw)
    except (TypeError, ValueError):
        raise ValueError("Choose Auto or between 1 and 8 build jobs.") from None
    if isinstance(raw, bool) or str(raw) != str(jobs) or jobs not in range(0, 9):
        raise ValueError("Choose Auto or between 1 and 8 build jobs.")
    mode = str(payload.get("mode", "if-missing"))
    if mode not in {"skip", "always", "if-missing"}:
        raise ValueError("Choose Build missing, Rebuild dependencies, or Use installed dependencies.")
    return jobs, mode


def start_run(payload: dict[str, Any]) -> None:
    action = str(payload.get("action", ""))
    profile = str(payload.get("profile", ""))
    if action not in {"check", "clone", "update", "dependencies", "package", "build", "full", "all", "install-dependency", "uninstall-dependency"}:
        raise ValueError("Choose a valid installer action.")
    if action == "all":
        profile = "all"
    elif action in {"install-dependency", "uninstall-dependency"}:
        profile = "workspace"
    elif profile not in {str(row.get("Profile ID")) for row in read_rows("Projects")}:
        raise ValueError("Choose a project first.")
    jobs, mode = validate_build_settings(payload)
    run_id = str(uuid.uuid4())
    command = [sys.executable, str(ENGINE), action, profile, "--dependency-mode", mode, "--run-id", run_id]
    if action in {"install-dependency", "uninstall-dependency"}:
        name, kind = str(payload.get("name", "")), str(payload.get("kind", ""))
        if kind not in {"recipe", "pin"} or not any(item["name"] == name and item["kind"] == kind for item in dependency_catalog()["items"]):
            raise ValueError("Choose a registered dependency.")
        command.extend(["--dependency", name, "--dependency-kind", kind])
    command.extend(["--jobs", str(jobs)])
    if payload.get("dry"):
        command.append("--dry-run")
    if action in {"build", "full", "all"}:
        command.append("--skip-clean" if payload.get("reuse", True) else "--clean")
    with APP_STATE["lock"]:
        active = APP_STATE["process"]
        if active is not None and active.poll() is None:
            raise ValueError("An installer operation is already running. Wait for it to finish before starting another.")
        if external_live_run() is not None:
            raise ValueError("A build is already running for this workspace. Wait for it to finish before starting another operation.")
        started = dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")
        with DB_LOCK:
            workbook = open_database(include_history=True, tables=["Runs"])
            try:
                headers = [str(workbook["Runs"].cell(1, col).value) for col in range(1, workbook["Runs"].max_column + 1)]
                row = {"Run ID": run_id, "Profile ID": profile, "Action": action, "Started UTC": started, "Finished UTC": "", "Status": "running", "Summary": "Starting operation."}
                workbook["Runs"].append([row.get(header, "") for header in headers])
                atomic_save_workbook(workbook, DB)
            finally:
                workbook.close()
        try:
            process = subprocess.Popen(command, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1, start_new_session=True)
        except OSError as exc:
            mark_run_interrupted(run_id, f"Could not start the build engine: {exc}", status="failed")
            raise ValueError(f"Could not start the build engine: {exc}") from exc
        APP_STATE.update({"process": process, "run_id": run_id, "output": [], "started": started, "action": action, "profile": profile, "status": "running", "paused": False, "workflowStage": None})
    threading.Thread(target=run_engine, args=(payload,), daemon=True).start()


def append_sheet_row(sheet: str, headers: list[str], values: dict[str, Any]) -> None:
    with DB_LOCK:
        workbook = open_database()
        try:
            ws = workbook[sheet]
            current = {str(ws.cell(row=1, column=i).value): i for i in range(1, ws.max_column + 1)}
            for header in headers:
                if header not in current:
                    current[header] = len(current) + 1
                    ws.cell(1, current[header]).value = header
            row = [values.get(str(ws.cell(1, col).value), "") for col in range(1, ws.max_column + 1)]
            ws.append(row)
            if sheet == "Dependencies":
                assigned = json.loads(str(values.get("Projects") or "[]"))
                known = {str(row["Profile ID"]) for row in read_rows("Projects")}
                if not isinstance(assigned, list) or set(assigned) - known:
                    raise ValueError("Choose existing projects for this library.")
                preserved = any(str(row.get("Dependency")) == str(values["Name"]) and row.get("Kind") == "recipe" for row in read_rows("ProjectDependencies"))
                update_requirements(workbook, str(values["Name"]), "recipe", str(values["Version / commit"]), profiles=assigned if assigned or not preserved else None)
            atomic_save_workbook(workbook, DB)
        finally:
            workbook.close()


def add_entry(payload: dict[str, Any]) -> None:
    values = {str(k): str(v).strip() for k, v in payload.get("values", {}).items()}
    kind = payload.get("kind")
    if kind == "repository":
        profile = values.get("Profile ID", "")
        project = next((row for row in read_rows("Projects") if row.get("Profile ID") == profile), None)
        if not project:
            raise ValueError("Choose an existing project first.")
        repository, ref = values.get("Repository", ""), values.get("Ref", "")
        if not repository or not ref:
            raise ValueError("Enter the repository name and its branch or tag.")
        if not re.fullmatch(r"[A-Za-z0-9_.+-]+", repository) or any(char in ref for char in "\n\r\0"):
            raise ValueError("Use a repository name made of letters, numbers, dots, underscores, plus signs, or hyphens.")
        if any(row.get("Profile ID") == profile and row.get("Repository") == repository for row in read_rows("Repositories")):
            raise ValueError(f"‘{repository}’ is already pinned to this project.")
        if values.get("Group", "plugin") not in {"plugin", "data_plugin"}:
            raise ValueError("Choose Plug-in or Data plug-in.")
        values["Order"] = max((int(row.get("Order") or 0) for row in read_rows("Repositories") if row.get("Profile ID") == profile), default=0) + 1
        values["Clone URL"] = values.get("Clone URL") or f"{str(project.get('Repository base URL') or 'https://github.com/ManiVaultStudio').rstrip('/')}/{repository}.git"
        values["Enabled"] = True
        append_sheet_row("Repositories", ["Profile ID", "Order", "Group", "Repository", "Ref", "Clone URL", "Enabled"], values)
    elif kind == "dependency":
        name = values.get("Name", "").strip()
        version = values.get("Version / commit", "").strip()
        if any(row.get("Name") == name for row in read_rows("Dependencies")):
            raise ValueError("This library already exists. Use Edit recipe to change it.")
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]*", name) or not version or any(char in version for char in "\n\r\0"):
            raise ValueError("Enter a dependency name and pinned version.")
        for key in ("Artifacts JSON", "Runtime Files JSON", "Requires JSON", "Recipe JSON"):
            decoded = json.loads(values.get(key) or ("{}" if key == "Recipe JSON" else "[]"))
            if key == "Recipe JSON" and not isinstance(decoded, dict):
                raise ValueError("Build recipe must be a JSON object.")
            if key != "Recipe JSON" and not isinstance(decoded, list):
                raise ValueError(f"{key} must be a JSON list.")
        script_name = values.get("Build Script", "GENERIC") or "GENERIC"
        if script_name.upper() == "GENERIC":
            script_name = generated_dependency_script(name)
            values["Build Script"] = script_name
            if not values.get("Recipe JSON") or values["Recipe JSON"] == "{}":
                source_url = values.get("Source URL", "").strip()
                if not source_url:
                    raise ValueError("Enter a GitHub source URL for the generated build script.")
                values["Recipe JSON"] = json.dumps({"source": {"type": "git", "url": source_url, "ref": version},
                                                    "buildSystem": "headers" if values.get("Linkage") == "header-only" else "cmake", "cmakeArgs": [],
                                                    "buildRoot": f"libraries/{name}/build", "prefix": f"libraries/{name}/install"})
            if not json.loads(values.get("Artifacts JSON") or "[]"):
                output = f"libraries/{name}/install/{'include' if values.get('Linkage') == 'header-only' else 'lib'}"
                values["Artifacts JSON"] = json.dumps([output])
                if values.get("Linkage") == "shared" and not json.loads(values.get("Runtime Files JSON") or "[]"):
                    values["Runtime Files JSON"] = json.dumps([output])
            write_dependency_script(name, script_name)
        elif Path(script_name).name != script_name or not (ROOT / "scripts" / "dependencies" / script_name).is_file():
            raise ValueError("Choose a build script that exists in scripts/dependencies.")
        values["Enabled"] = values.get("Enabled", "true").lower() in {"true", "yes", "1"}
        append_sheet_row("Dependencies", ["Name", "Version / commit", "Enabled", "Linkage", "Build Script", "Artifacts JSON", "Runtime Files JSON", "Requires JSON", "Recipe JSON", "Source URL"], values)
    elif kind == "project":
        profile = values.get("Profile ID", "")
        display_name = values.get("Display name", "")
        if not profile or not display_name or any(row.get("Profile ID") == profile for row in read_rows("Projects")):
            raise ValueError("Enter a project name and a unique project ID.")
        if not all(c.isalnum() or c in "._-" for c in profile) or not profile[0].isalnum():
            raise ValueError("Project ID can contain letters, numbers, dots, underscores, and hyphens.")
        if not re.fullmatch(r"\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?", values.get("App version", "")):
            raise ValueError("Use a semantic version, such as 1.0.0.")
        template_id = values.get("Template profile", "")
        template = next((row for row in read_rows("Projects") if row.get("Profile ID") == template_id), None)
        if not template:
            raise ValueError("Choose an existing project profile to copy its build settings and materials.")
        template_assets = next((row for row in read_rows("InstallerAssets") if row.get("Profile ID") == template_id), None)
        if not template_assets:
            raise ValueError("The chosen starter project has no installer materials entry. Choose another profile.")
        template_repositories = [row for row in read_rows("Repositories") if row.get("Profile ID") == template_id]
        if not template_repositories:
            raise ValueError("The chosen starter project has no repository pins to copy.")

        old_root = str(template_assets.get("Installer materials root") or f"installer_materials/projects/{template_id}")
        source_assets = (ROOT / old_root).resolve()
        new_root = f"installer_materials/projects/{profile}"
        destination_assets = ROOT / new_root
        if not source_assets.is_relative_to((ROOT / "installer_materials" / "projects").resolve()) or not source_assets.is_dir():
            raise ValueError("The starter project’s installer materials folder is missing or outside the projects folder.")
        created_assets = not destination_assets.exists()
        if created_assets:
            shutil.copytree(source_assets, destination_assets)
        elif not destination_assets.is_dir():
            raise ValueError(f"The installer materials path for ‘{profile}’ exists and is not a folder.")
        saved = False
        try:
            with DB_LOCK:
                workbook = open_database()
                try:
                    project_sheet = workbook["Projects"]
                    project_headers = [str(project_sheet.cell(1, col).value) for col in range(1, project_sheet.max_column + 1)]
                    cloned = dict(template)
                    cloned.update({
                        "Profile ID": profile, "Display name": display_name, "App version": values["App version"],
                        "Source root": f"sources/{profile}", "Build root": f"builds/{profile}/build/{profile}",
                        "Install directory": f"builds/{profile}/install/{profile}",
                        "Install copy directory": f"builds/{profile}/installCopy/{profile}",
                        "DMG staging directory": f"builds/{profile}/dmg_temp_content/{profile}",
                    })
                    project_sheet.append([cloned.get(header, "") for header in project_headers])

                    repository_sheet = workbook["Repositories"]
                    repository_headers = [str(repository_sheet.cell(1, col).value) for col in range(1, repository_sheet.max_column + 1)]
                    for repository in template_repositories:
                        repository["Profile ID"] = profile
                        repository_sheet.append([repository.get(header, "") for header in repository_headers])

                    assets_sheet = workbook["InstallerAssets"]
                    assets_headers = [str(assets_sheet.cell(1, col).value) for col in range(1, assets_sheet.max_column + 1)]
                    assets = dict(template_assets)
                    assets["Profile ID"] = profile
                    for key, value in list(assets.items()):
                        if isinstance(value, str) and value.startswith(old_root):
                            assets[key] = new_root + value[len(old_root):]
                    assets["Installer materials root"] = new_root
                    assets_sheet.append([assets.get(header, "") for header in assets_headers])
                    required_sheet = workbook["ProjectDependencies"]
                    required_rows = list(required_sheet.iter_rows(values_only=True))
                    required_headers = required_rows[0]
                    for required in [dict(zip(required_headers, row)) for row in required_rows[1:]]:
                        if str(required.get("Profile ID")) == template_id:
                            required["Profile ID"] = profile
                            required_sheet.append([required.get(header) for header in required_headers])
                    atomic_save_workbook(workbook, DB)
                    saved = True
                finally:
                    workbook.close()
        except Exception:
            if not saved and created_assets:
                shutil.rmtree(destination_assets, ignore_errors=True)
            raise
    else:
        raise ValueError("Unknown project data type.")
    if kind in {"project", "repository"}:
        profile_row = next((row for row in read_rows("Projects") if row.get("Profile ID") == profile), None)
        if profile_row:
            write_managed_profile(PROJECT_PROFILES / f"{profile}.env", profile_row,
                                  [row for row in read_rows("Repositories") if row.get("Profile ID") == profile])


def update_project_settings(values: dict[str, Any]) -> None:
    profile = str(values.get("Profile ID", "")).strip()
    if not profile:
        raise ValueError("Choose the project profile to edit.")
    existing = next((row for row in read_rows("Projects") if str(row.get("Profile ID")) == profile), None)
    if existing is None:
        raise ValueError("This project no longer exists.")
    values = {**existing, **values}
    for version_key, directory_key in (("Qt version", "Qt directory"), ("Vulkan SDK version", "Vulkan SDK directory")):
        old_version, new_version = str(existing.get(version_key) or ""), str(values.get(version_key) or "")
        if old_version and old_version != new_version and values.get(directory_key) == existing.get(directory_key):
            values[directory_key] = str(values.get(directory_key) or "").replace(old_version, new_version)
    version = str(values.get("App version", "")).strip()
    if not re.fullmatch(r"\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?", version):
        raise ValueError("Use a semantic version, such as 1.2.3.")
    if str(values.get("Build type", "")) not in {"Release", "RelWithDebInfo", "Debug"}:
        raise ValueError("Choose Release, RelWithDebInfo, or Debug.")
    if str(values.get("Dependency mode", "")) not in {"if-missing", "always", "skip"}:
        raise ValueError("Choose a valid dependency handling option.")
    architectures = [item.strip() for item in str(values.get("Architectures", "")).split(";") if item.strip()]
    if not architectures or any(item not in {"arm64", "x86_64"} for item in architectures):
        raise ValueError("Architectures must use arm64, x86_64, or both separated with a semicolon.")
    if not str(values.get("Display name", "")).strip():
        raise ValueError("Project name is required.")
    fields = ("Display name", "App version", "Architectures", "Minimum macOS", "Minimum core version", "Core source directory",
              "Build type", "Repository base URL", "Dependency mode", "Customization folder", "Qt version",
              "Qt directory", "Vulkan SDK version", "Vulkan SDK directory")
    with DB_LOCK:
        workbook = open_database()
        try:
            sheet = workbook["Projects"]
            headers = {str(sheet.cell(1, col).value): col for col in range(1, sheet.max_column + 1)}
            profile_col = headers.get("Profile ID")
            row = next((index for index in range(2, sheet.max_row + 1)
                        if str(sheet.cell(index, profile_col).value) == profile), None)
            if row is None:
                raise ValueError("This project profile no longer exists.")
            for name in fields:
                if name in headers:
                    sheet.cell(row, headers[name]).value = str(values.get(name) or "").strip()
            atomic_save_workbook(workbook, DB)
        finally:
            workbook.close()
    profile_row = next((row for row in read_rows("Projects") if row.get("Profile ID") == profile), None)
    if profile_row:
        write_managed_profile(PROJECT_PROFILES / f"{profile}.env", profile_row,
                              [row for row in read_rows("Repositories") if row.get("Profile ID") == profile])

def deletion_plan(payload: dict[str, Any]) -> dict[str, Any]:
    from dependency_actions import output_paths
    from dependency_config import entries_from_rows
    from file_deletion import compact_paths
    kind, values = str(payload.get("kind", "")), payload.get("values", {})
    candidates: list[Path] = []
    protected: list[Path] = []
    affected: list[str] = []
    projects = read_rows("Projects")
    assets = read_rows("InstallerAssets")
    def local(raw: Any) -> Path | None:
        if not raw: return None
        value = Path(str(raw)).expanduser()
        return (value if value.is_absolute() else ROOT / value).resolve()
    def project_paths(project):
        result = [local(project.get(key)) for key in ("Source root", "Build root", "Install directory", "Install copy directory", "DMG staging directory")]
        own_assets = next((asset for asset in assets if asset.get("Profile ID") == project.get("Profile ID")), {})
        result.append(local(own_assets.get("Installer materials root")))
        return [path for path in result if path]
    if kind == "installer":
        item = next((item for item in collect_installers() if item["id"] == str(values.get("id"))), None)
        if item is None: raise ValueError("Installer is no longer available.")
        candidates = [Path(item["sourcePath"])]
    elif kind == "project":
        profile = str(values.get("Profile ID", ""))
        project = next((row for row in projects if str(row.get("Profile ID")) == profile), None)
        if project is None: raise ValueError("Project is no longer registered.")
        if len(projects) <= 1: raise ValueError("Keep at least one project.")
        candidates = project_paths(project)
        protected = [path for other in projects if str(other.get("Profile ID")) != profile for path in project_paths(other)]
        affected = [str(project["Display name"])]
    elif kind == "repository":
        profile, name = str(values.get("Profile ID")), str(values.get("Repository"))
        if Path(name).name != name or name in {".",".."}: raise ValueError("Invalid repository name.")
        project = next((row for row in projects if str(row.get("Profile ID")) == profile), None)
        if project is None: raise ValueError("Project is no longer registered.")
        candidates = [local(project.get("Source root")) / name, local(project.get("Build root")) / name,
                      local(project.get("Build root")) / "_source_overrides" / name]
        protected = [path for other in projects if str(other.get("Profile ID")) != profile for path in project_paths(other)]
        affected = [str(project["Display name"])]
    elif kind in {"dependency", "dependency-pin"}:
        name = str(values.get("Name"))
        entries = entries_from_rows(read_rows("Dependencies"))
        pins = json.loads((DB.parent / "source_pins.json").read_text())["dependencies"]
        item = next((entry for entry in (entries if kind == "dependency" else pins) if entry["name"] == name), None)
        if item is None: raise ValueError("Dependency is no longer registered.")
        if kind == "dependency":
            outputs = output_paths(ROOT,item)
            candidates = [ROOT / "libraries" / path.relative_to((ROOT/"libraries").resolve()).parts[0] for path in outputs]
        else: candidates = output_paths(ROOT,{"artifacts":[item["source"]]})
        protected = [path for entry in entries if kind != "dependency" or entry["name"] != name for path in output_paths(ROOT,entry)]
        protected += [path for pin in pins if kind != "dependency-pin" or pin["name"] != name for path in output_paths(ROOT,{"artifacts":[pin["source"]]})]
        ids = {str(row["Profile ID"]) for row in read_rows("ProjectDependencies") if row.get("Dependency") == name and row.get("Kind") == ("recipe" if kind == "dependency" else "pin")}
        affected = [str(project["Display name"]) for project in projects if str(project["Profile ID"]) in ids]
    else:
        raise ValueError("Choose a project, plug-in, dependency or installer.")
    allowed_roots = [(ROOT / folder).resolve() for folder in ("sources","builds","libraries","installer_materials/projects")]
    files, skipped = [], []
    for path in compact_paths([path.resolve() for path in candidates]):
        if not path.exists(): continue
        owned = kind == "installer" or any(path != base and path.is_relative_to(base) for base in allowed_roots)
        shared = any(path == other or path.is_relative_to(other) or other.is_relative_to(path) for other in protected)
        if not owned or shared: skipped.append(str(path))
        else: files.append(str(path))
    return {"files": files, "protected": skipped, "affectedProjects": affected}


def delete_files_and_entry(payload: dict[str, Any]) -> dict[str, Any]:
    from file_deletion import stage, restore, purge
    if payload.get("confirmed") is not True:
        raise ValueError("Confirm permanent deletion first.")
    with DB_LOCK:
        plan = deletion_plan(payload)
        moves = stage(ROOT, [Path(path) for path in plan["files"]])
        try:
            if payload.get("kind") == "installer":
                workbook = open_database(include_history=True, tables=["Runs"])
                try:
                    sheet = workbook["Runs"]
                    headers = {str(sheet.cell(1,col).value):col for col in range(1,sheet.max_column+1)}
                    for row in range(2,sheet.max_row+1):
                        if str(sheet.cell(row,headers["DMG path"]).value) in plan["files"]:
                            sheet.cell(row,headers["DMG path"]).value = ""
                    atomic_save_workbook(workbook, DB)
                finally: workbook.close()
            else: remove_entry(payload)
        except Exception:
            restore(moves)
            raise
    purge(moves)
    return plan


def remove_entry(payload: dict[str, Any]) -> None:
    kind = str(payload.get("kind", ""))
    values = payload.get("values", {})
    with DB_LOCK:
        workbook = open_database(include_history=kind in {"run", "logs"})
        try:
            if kind in {"run", "logs"}:
                run_id = str(values.get("Run ID", "")).strip()
                if not run_id:
                    raise ValueError("Choose a run first.")
                run_sheet = workbook["Runs"]
                run_headers = {str(run_sheet.cell(1, col).value): col for col in range(1, run_sheet.max_column + 1)}
                run_col = run_headers.get("Run ID")
                run_row = next((row for row in range(2, run_sheet.max_row + 1) if str(run_sheet.cell(row, run_col).value) == run_id), None)
                if run_row is None:
                    raise ValueError("This run is no longer in the activity history.")
                if str(run_sheet.cell(run_row, run_headers.get("Status")).value).lower() == "running":
                    raise ValueError("An active run cannot be deleted.")
                log_sheet = workbook["Logs"]
                log_headers = {str(log_sheet.cell(1, col).value): col for col in range(1, log_sheet.max_column + 1)}
                log_run_col = log_headers.get("Run ID")
                for row in range(log_sheet.max_row, 1, -1):
                    if str(log_sheet.cell(row, log_run_col).value) == run_id:
                        log_sheet.delete_rows(row)
                if kind == "run":
                    run_sheet.delete_rows(run_row)
            elif kind == "project":
                profile = str(values.get("Profile ID", ""))
                sheet = workbook["Projects"]
                headers = {str(sheet.cell(1, col).value): col for col in range(1, sheet.max_column + 1)}
                id_col = headers.get("Profile ID")
                found = next((row for row in range(2, sheet.max_row + 1) if str(sheet.cell(row, id_col).value) == profile), None)
                if found is None:
                    raise ValueError("This project profile is no longer in the project list.")
                if sheet.max_row <= 2:
                    raise ValueError("Keep at least one project profile in the manager.")
                sheet.delete_rows(found)
                for sheet_name in ("Repositories", "InstallerAssets", "ProjectDependencies"):
                    target = workbook[sheet_name]
                    target_headers = {str(target.cell(1, col).value): col for col in range(1, target.max_column + 1)}
                    profile_col = target_headers.get("Profile ID")
                    for row in range(target.max_row, 1, -1):
                        if str(target.cell(row, profile_col).value) == profile:
                            target.delete_rows(row)
            elif kind == "dependency":
                name = str(values.get("Name", ""))
                sheet = workbook["Dependencies"]
                headers = {str(sheet.cell(1, c).value): c for c in range(1, sheet.max_column + 1)}
                found = next((r for r in range(2, sheet.max_row + 1) if str(sheet.cell(r, headers["Name"]).value) == name), None)
                if found is None:
                    raise ValueError("This library is no longer registered.")
                for r in range(2, sheet.max_row + 1):
                    if r != found and name in json.loads(str(sheet.cell(r, headers["Requires JSON"]).value or "[]")):
                        raise ValueError("Another library requires this library. Remove that prerequisite first.")
                sheet.delete_rows(found)
            elif kind == "dependency-pin":
                manifest_path = ROOT / "installer_database/source_pins.json"
                manifest = json.loads(manifest_path.read_text())
                name = str(values.get("Name", ""))
                manifest["dependencies"] = [item for item in manifest.get("dependencies", []) if item.get("name") != name]
                from database_io import save_source_pins
                save_source_pins(workbook, DB, manifest)
                return
            elif kind == "repository":
                profile, name = str(values.get("Profile ID", "")), str(values.get("Repository", ""))
                order = str(values.get("Order", ""))
                sheet = workbook["Repositories"]
                headers = {str(sheet.cell(1, col).value): col for col in range(1, sheet.max_column + 1)}
                profile_col, order_col = headers.get("Profile ID"), headers.get("Order")
                name_col, group_col = headers.get("Repository"), headers.get("Group")
                found = next((row for row in range(2, sheet.max_row + 1)
                              if str(sheet.cell(row, profile_col).value) == profile
                              and str(sheet.cell(row, order_col).value) == order
                              and str(sheet.cell(row, name_col).value) == name), None)
                if found is None:
                    raise ValueError("This repository pin is no longer in the project.")
                if str(sheet.cell(found, group_col).value) == "core":
                    raise ValueError("The core repository is required and cannot be removed here.")
                sheet.delete_rows(found)
            else:
                raise ValueError("Choose a project or plug-in to remove.")
            atomic_save_workbook(workbook, DB)
        finally:
            workbook.close()
    if kind in {"run", "logs"}:
        output = ROOT / "installer_database/local/run_output" / f"{run_id}.log"
        output.unlink(missing_ok=True)
    if kind == "project":
        remove_profile_file(PROJECT_PROFILES, profile)
    elif kind == "repository":
        project = next(row for row in read_rows("Projects") if str(row.get("Profile ID")) == profile)
        write_managed_profile(PROJECT_PROFILES / f"{profile}.env", project,
                              [row for row in read_rows("Repositories") if str(row.get("Profile ID")) == profile])


def repository_ref_for(profile: str, order: str, repository: str) -> dict[str, Any]:
    row = next((item for item in read_rows("Repositories")
                if str(item.get("Profile ID")) == profile and str(item.get("Order")) == order
                and str(item.get("Repository")) == repository), None)
    if not row:
        raise ValueError("This repository pin is no longer in the selected project.")
    return row


def update_repository_ref(values: dict[str, Any]) -> None:
    profile = str(values.get("Profile ID", "")).strip()
    order = str(values.get("Order", "")).strip()
    repository = str(values.get("Repository", "")).strip()
    ref = str(values.get("Ref", "")).strip()
    if not profile or not repository or not ref or any(char in ref for char in "\n\r\0"):
        raise ValueError("Choose a project and enter a branch, tag, or commit.")
    with DB_LOCK:
        workbook = open_database()
        try:
            sheet = workbook["Repositories"]
            columns = {str(sheet.cell(1, col).value): col for col in range(1, sheet.max_column + 1)}
            found = next((row for row in range(2, sheet.max_row + 1)
                          if str(sheet.cell(row, columns["Profile ID"]).value) == profile
                          and str(sheet.cell(row, columns["Order"]).value) == order
                          and str(sheet.cell(row, columns["Repository"]).value) == repository), None)
            if found is None:
                raise ValueError("This repository pin is no longer in the selected project.")
            group = str(sheet.cell(found, columns["Group"]).value or "plugin").lower()
            sheet.cell(found, columns["Ref"]).value = ref
            if group == "core":
                projects = workbook["Projects"]
                pcols = {str(projects.cell(1, col).value): col for col in range(1, projects.max_column + 1)}
                prow = next((row for row in range(2, projects.max_row + 1)
                             if str(projects.cell(row, pcols["Profile ID"]).value) == profile), None)
                if prow is not None:
                    projects.cell(prow, pcols["Core ref"]).value = ref
            atomic_save_workbook(workbook, DB)
        finally:
            workbook.close()
    project = next(row for row in read_rows("Projects") if str(row.get("Profile ID")) == profile)
    write_managed_profile(PROJECT_PROFILES / f"{profile}.env", project,
                          [row for row in read_rows("Repositories") if str(row.get("Profile ID")) == profile])


def fetch_github_refs(source_url: str) -> dict[str, Any]:
    source_url = source_url.strip()
    match = re.search(r"github\.com[:/]([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+?)(?:\.git)?/?$", source_url, re.I)
    if not match:
        raise ValueError("Enter a GitHub repository URL to fetch branches and tags.")
    owner, repo = match.groups()
    slug = f"{owner}/{repo}"
    with GITHUB_REF_CACHE_LOCK:
        cached = GITHUB_REF_CACHE.get(slug)
        if cached and time.time() - cached[0] < 300:
            return cached[1]

    def read(kind: str) -> list[dict[str, str]]:
        endpoint = f"https://api.github.com/repos/{slug}/{kind}?per_page=100"
        request = urllib.request.Request(endpoint, headers={
            "Accept": "application/vnd.github+json", "User-Agent": "ManiVault-Installer-Creator"
        })
        try:
            with urllib.request.urlopen(request, timeout=6) as response:
                data = json.loads(response.read().decode("utf-8"))
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
            raise ValueError(f"GitHub could not load {kind} for {slug}: {exc}") from exc
        if not isinstance(data, list):
            raise ValueError(f"GitHub returned an unexpected {kind} list for {slug}.")
        return [{"name": str(item.get("name", "")), "sha": str(item.get("commit", {}).get("sha", ""))}
                for item in data if item.get("name")]

    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        branches_future = pool.submit(read, "branches")
        tags_future = pool.submit(read, "tags")
        result = {"repository": slug, "branches": branches_future.result(), "tags": tags_future.result()}
    with GITHUB_REF_CACHE_LOCK:
        GITHUB_REF_CACHE[slug] = (time.time(), result)
    return result


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_: Any) -> None:
        return

    
    def handle_error(self, request, client_address):
        exc_type, exc_value, _ = sys.exc_info()

        if isinstance(
            exc_value,
            (
                BrokenPipeError,
                ConnectionResetError,
                ConnectionAbortedError,
            ),
        ):
            return

        super().handle_error(request, client_address)


    def send_json(self, data: dict[str, Any], code: int = 200) -> None:
        try:
            body = json.dumps(data, default=str).encode("utf-8")

            self.send_response(code)
            self.send_header(
                "Content-Type",
                "application/json; charset=utf-8"
            )
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()

            self.wfile.write(body)

        except (BrokenPipeError, ConnectionResetError):
            # The browser closed the connection before receiving
            # the complete response. This is not a server failure.
            return

    def do_GET(self) -> None:  # noqa: N802
        try:
            self.handle_get()
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as exc:
            self.send_json({"error": str(exc)}, 400)

    def handle_get(self) -> None:
        if urlparse(self.path).path == "/":
            page = (ROOT / "ui/index.html").read_text(encoding="utf-8")
            body = page.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif urlparse(self.path).path == "/api/health":
            busy = instance_busy()
            self.send_json({"ok": True, "pid": os.getpid(), "port": self.server.server_address[1], "instanceControl": 1, "busy": busy})
        elif urlparse(self.path).path == "/api/instances":
            self.send_json({"instances": discover_instances(ROOT, os.getpid())})
        elif urlparse(self.path).path == "/ui/app.js":
            body = (ROOT / "ui/app.js").read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "application/javascript; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            self.wfile.write(body)
        elif urlparse(self.path).path == "/ui/styles.css":
            asset = ROOT / "ui" / "styles.css"
            body = asset.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "text/css; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            self.wfile.write(body)
        elif urlparse(self.path).path == "/brand-icon.png":
            icon = ROOT / "installer_materials" / "projects" / "manivault-studio" / "main-folder-icon.png"
            if not icon.is_file():
                self.send_error(404, "ManiVault brand icon not found")
                return
            body = icon.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "public, max-age=3600")
            self.end_headers()
            self.wfile.write(body)
        elif urlparse(self.path).path == "/api/state":
            with APP_STATE["lock"]:
                process = APP_STATE["process"]
                process_active = process is not None and process.poll() is None
                live = {
                    "run_id": APP_STATE["run_id"], "action": APP_STATE["action"],
                    "profile": APP_STATE["profile"], "status": APP_STATE["status"],
                    "started": APP_STATE["started"], "output": list(APP_STATE["output"])[-30:], "workflowStage": APP_STATE.get("workflowStage"),
                    "active": process_active, "paused": APP_STATE["paused"],
                } if APP_STATE["run_id"] else None
            if live is None or not live["active"]:
                live = external_live_run() or live
            runs = read_rows("Runs")[-100:]
            query = parse_qs(urlparse(self.path).query)
            requested_run = query.get("run", [""])[0]
            log_run_id = requested_run if any(str(run.get("Run ID")) == requested_run for run in runs) else str(runs[-1].get("Run ID") or "") if runs else ""
            log_fields = {}
            if query.get("logs", ["1"])[0] != "0":
                revision = log_revision(log_run_id)
                log_fields = {"logRunId": log_run_id, "logRevision": revision}
                if query.get("logRevision", [""])[0] != revision:
                    relevant = [run for run in runs if str(run.get("Run ID")) == log_run_id]
                    log_fields["logs"] = logs_with_live_fallback(relevant, logs_for_run(log_run_id))
            catalog = dependency_catalog()
            projects = evaluate_readiness(read_rows("Projects"), read_rows("ProjectDependencies"), catalog["items"])
            self.send_json({"projects":projects,"repositories":read_rows("Repositories"),"runs":runs,**log_fields,"settings":read_settings(),"live":live})
        elif urlparse(self.path).path == "/run-output":
            run_id = parse_qs(urlparse(self.path).query).get("id", [""])[0]
            if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,119}", run_id):
                raise ValueError("Choose a valid run.")
            output = ROOT / "installer_database/local/run_output" / f"{run_id}.log"
            if output.exists() and output.stat().st_size:
                body = output.read_bytes()
            else:
                body = "\n".join(str(row.get("Message") or "") for row in read_rows("Logs") if str(row.get("Run ID")) == run_id).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Disposition", f'attachment; filename="run-{run_id}.log"')
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif urlparse(self.path).path == "/api/run-logs":
            run_id = parse_qs(urlparse(self.path).query).get("id", [""])[0]
            relevant = [run for run in read_rows("Runs") if str(run.get("Run ID")) == run_id]
            self.send_json({"logs": logs_with_live_fallback(relevant, logs_for_run(run_id)), "logRevision": log_revision(run_id)})
        elif urlparse(self.path).path == "/api/github-refs":
            query = parse_qs(urlparse(self.path).query)
            try:
                refs = fetch_github_refs(query.get("url", [""])[0])
                self.send_json(refs)
            except Exception as exc:
                self.send_json({"error": str(exc)}, 400)
        elif urlparse(self.path).path == "/api/installers":
            items = collect_installers()
            self.send_json({"installers": [{key: value for key, value in item.items() if key != "sourcePath"} for item in items], "settings": read_settings()})
        elif urlparse(self.path).path == "/api/dependencies":
            self.send_json(dependency_catalog())
        elif urlparse(self.path).path == "/download":
            requested = parse_qs(urlparse(self.path).query).get("id", [""])[0]
            record = next((item for item in collect_installers() if item["id"] == requested), None)
            if record is None:
                self.send_error(404, "Installer not found")
                return
            path = Path(record["sourcePath"])
            if not path.is_file():
                self.send_error(404, "Installer not found")
                return
            self.send_response(200)
            self.send_header("Content-Type", mimetypes.guess_type(path.name)[0] or "application/octet-stream")
            self.send_header("Content-Length", str(path.stat().st_size))
            self.send_header("Content-Disposition", f'attachment; filename="{path.name}"')
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            with path.open("rb") as stream:
                while chunk := stream.read(1024 * 1024):
                    self.wfile.write(chunk)
        else:
            self.send_error(404)

    def do_POST(self) -> None:  # noqa: N802
        try:
            length = int(self.headers.get("Content-Length", "0"))
            payload = json.loads(self.rfile.read(length) or b"{}")
            route = urlparse(self.path).path
            if route in {"/api/instance/shutdown", "/api/instances/stop"}:
                if self.headers.get("Content-Type", "").split(";")[0] != "application/json":
                    raise ValueError("Instance controls require a JSON request.")
                origin = self.headers.get("Origin")
                if origin and origin != f"http://127.0.0.1:{self.server.server_address[1]}":
                    raise ValueError("Instance controls must be used from this local app.")
            if route == "/api/instance/shutdown":
                if payload.get("confirmed") is not True:
                    raise ValueError("Confirm stopping this app instance first.")
                with shutdown_lock():
                    busy = instance_busy()
                    validate_shutdown(discover_instances(ROOT, os.getpid()), int(payload.get("pid", 0)), os.getpid(), busy)
                    self.send_json({"ok": True})
                    self.server.shutdown()
            elif route == "/api/instances/stop":
                if payload.get("confirmed") is not True:
                    raise ValueError("Confirm stopping the selected app instance first.")
                target = next((item for item in discover_instances(ROOT, os.getpid()) if item["pid"] == int(payload.get("pid", 0))), None)
                if not target or not target["canStop"]:
                    raise ValueError("This instance cannot be stopped here. Refresh the list or use Terminal.")
                request = urllib.request.Request(f'http://127.0.0.1:{target["port"]}/api/instance/shutdown', data=json.dumps({"pid": target["pid"], "confirmed": True}).encode(), headers={"Content-Type": "application/json"})
                try:
                    with urllib.request.urlopen(request, timeout=8) as response:
                        result = json.load(response)
                except urllib.error.HTTPError as exc:
                    raise ValueError(json.loads(exc.read()).get("error", "The other instance could not stop.")) from None
                self.send_json(result)
            elif route == "/api/create-installer":
                with APP_STATE["lock"]:
                    process = APP_STATE["process"]
                    if (process is not None and process.poll() is None) or external_live_run() is not None:
                        raise ValueError("Wait for the current operation to finish before creating another installer.")
                    validate_build_settings(payload)
                    if payload.get("action") not in {"full", "package"}:
                        raise ValueError("Choose to build a project or package an existing build.")
                    if not payload.get("dry"):
                        update_project_settings({"Profile ID": payload.get("profile"), "App version": payload.get("version")})
                    start_run(payload)
                self.send_json({"ok": True})
            elif route == "/api/run":
                start_run(payload)
                self.send_json({"ok":True})
            elif route == "/api/browse-folder":
                name = str(payload.get("name", ""))
                prompts = {"Out path": "Choose where installer DMGs are created and listed", "In path": "Choose where installer DMGs are copied"}
                if name not in prompts:
                    raise ValueError("Choose the Out path or In path field first.")
                result = subprocess.run(["osascript", "-e", f'POSIX path of (choose folder with prompt "{prompts[name]}")'], text=True, capture_output=True)
                if result.returncode:
                    raise ValueError("Folder selection was cancelled.")
                self.send_json({"path": result.stdout.strip()})
            elif route == "/api/open-folder":
                name = str(payload.get("name", ""))
                if name not in {"Out path", "In path"}:
                    raise ValueError("Choose the Out path or In path field first.")
                raw_path = str(payload.get("path", "")).strip()
                if not raw_path or "\x00" in raw_path or "\n" in raw_path or "\r" in raw_path:
                    raise ValueError(f"Enter a valid folder path for {name}.")
                folder = Path(raw_path).expanduser()
                if not folder.is_absolute():
                    folder = ROOT / folder
                folder = folder.resolve()
                folder.mkdir(parents=True, exist_ok=True)
                subprocess.Popen(["open", str(folder)])
                self.send_json({"path": str(folder)})
            elif route == "/api/stop":
                with APP_STATE["lock"]:
                    process = APP_STATE["process"]
                if process is not None and process.poll() is None:
                    try:
                        if APP_STATE["paused"]:
                            os.killpg(process.pid, signal.SIGCONT)
                        os.killpg(process.pid, signal.SIGTERM)
                    except OSError:
                        process.terminate()
                with APP_STATE["lock"]:
                    APP_STATE["paused"] = False
                self.send_json({"ok":True})
            elif route in {"/api/pause", "/api/resume"}:
                pause_or_resume(route == "/api/pause")
                self.send_json({"paused": APP_STATE["paused"]})
            elif route == "/api/add":
                with APP_STATE["lock"]:
                    process = APP_STATE["process"]
                if (process is not None and process.poll() is None) or (process is None and external_live_run() is not None): raise ValueError("Wait for the running operation to finish before editing project data.")
                add_entry(payload)
                self.send_json({"ok":True})
            elif route == "/api/project/update":
                with APP_STATE["lock"]:
                    process = APP_STATE["process"]
                if (process is not None and process.poll() is None) or (process is None and external_live_run() is not None):
                    raise ValueError("Wait for the active operation to finish before changing project settings.")
                update_project_settings(payload.get("values", {}))
                self.send_json({"ok":True})
            elif route == "/api/repository/update":
                with APP_STATE["lock"]:
                    process = APP_STATE["process"]
                if (process is not None and process.poll() is None) or (process is None and external_live_run() is not None):
                    raise ValueError("Wait for the active build to finish before changing repository versions.")
                update_repository_ref(payload.get("values", {}))
                self.send_json({"ok":True})
            elif route == "/api/deletion-plan":
                self.send_json(deletion_plan(payload))
            elif route == "/api/remove":
                with APP_STATE["lock"]:
                    process = APP_STATE["process"]
                if (process is not None and process.poll() is None) or (process is None and external_live_run() is not None):
                    raise ValueError("Wait for the active operation to finish before removing project data.")
                if payload.get("deleteFiles"):
                    result = delete_files_and_entry(payload)
                    self.send_json({"ok":True, **result})
                else:
                    remove_entry(payload)
                    self.send_json({"ok":True})
            elif route == "/api/dependencies":
                with APP_STATE["lock"]:
                    process = APP_STATE["process"]
                if (process is not None and process.poll() is None) or (process is None and external_live_run() is not None):
                    raise ValueError("Wait for the active operation to finish before changing dependency versions.")
                mode = str(payload.get("mode", "pin"))
                values = payload.get("values", {})
                if mode == "recipe":
                    update_build_dependency(values)
                elif mode == "pin":
                    save_dependency_pin(values)
                else:
                    raise ValueError("Choose a cached dependency pin or build library.")
                self.send_json({"ok": True, "dependencies": dependency_catalog()})
            elif route == "/api/settings":
                with APP_STATE["lock"]:
                    process = APP_STATE["process"]
                if (process is not None and process.poll() is None) or (process is None and external_live_run() is not None): raise ValueError("Wait for the running operation to finish before changing installer paths.")
                self.send_json({"settings": save_settings(payload.get("values", {}))})
            elif route == "/api/copy-installer":
                with APP_STATE["lock"]:
                    process = APP_STATE["process"]
                if (process is not None and process.poll() is None) or (process is None and external_live_run() is not None): raise ValueError("Wait for the active build to finish before copying installers.")
                destinations = [copy_installer(str(payload.get("id", "")))]
                self.send_json({"copied":len(destinations),"destination":read_settings()["In path"]})
            elif route == "/api/open-database":
                subprocess.Popen(["open" if sys.platform == "darwin" else "xdg-open", str(DB.parent)])
                self.send_json({"ok":True})
            else:
                self.send_json({"error":"Unknown action."}, 404)
        except Exception as exc:
            self.send_json({"error":str(exc)}, 400)


def main() -> None:
    parser = argparse.ArgumentParser(description="Build macOS installers from the local project databases.")
    parser.add_argument("--status", action="store_true", help="Print the running app's URL, port, process ID and health without starting another server.")
    parser.add_argument("--print-port", action="store_true", help="Print only the recorded port of a live or responding installer.")
    parser.add_argument("--listen-port", type=int, help="Start on a specific port; 0 chooses an available port.")
    parser.add_argument("--no-browser", action="store_true", help="Run without opening a browser tab.")
    args = parser.parse_args()
    if args.status:
        print_instance_status()
        return
    if args.print_port:
        info = inspect_instance()
        if info and (info["responding"] or info["process_alive"]):
            print(info["port"], flush=True)
            return
        raise SystemExit("No running installer was found. Use --status for the last known address.")
    if args.no_browser:
        os.environ["INSTALLER_NO_BROWSER"] = "1"
    if args.listen_port is not None:
        if args.listen_port not in range(0, 65536):
            parser.error("Port must be between 0 and 65535.")
        os.environ["INSTALLER_PORT"] = str(args.listen_port)
    if not acquire_single_instance():
        return

    server = None
    try:
        ensure_dependency_schema()
        try:
            with DB_LOCK:
                workbook = open_database(include_history=True, tables=["Runs", "Logs"])
                try:
                    if ensure_log_schema(workbook):
                        atomic_save_workbook(workbook, DB)
                finally:
                    workbook.close()
        except Exception as exc:
            print(f"Activity log schema check failed: {exc}", file=sys.stderr, flush=True)

        port = int(os.environ.get("INSTALLER_PORT", "0"))
        server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
        server.daemon_threads = True
        url = f"http://127.0.0.1:{server.server_address[1]}"
        write_instance_info(url, server.server_address[1])
        print(f"ManiVault Studio is ready: {url} (port {server.server_address[1]}, PID {os.getpid()})", flush=True)
        if os.environ.get("INSTALLER_NO_BROWSER") != "1":
            threading.Timer(0.45, lambda: webbrowser.open_new_tab(url)).start()
        server.serve_forever()
    except KeyboardInterrupt:
        print("ManiVault Studio is shutting down.", flush=True)
    finally:
        if server is not None:
            server.server_close()
        release_single_instance()


if __name__ == "__main__":
    main()
