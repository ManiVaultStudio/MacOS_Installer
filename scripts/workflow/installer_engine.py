#!/usr/bin/env python3
"""JSON-backed engine for cloning, building, and packaging installer projects."""
from __future__ import annotations

import argparse
import builtins
import datetime as dt
import json
import os
import platform
import re
import shlex
import shutil
import signal
import subprocess
import sys
import traceback
import time
import uuid
from collections import deque
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from build_performance import automatic_jobs
from dependency_config import version_environment
from database_io import load_database as open_database_store, append_log_row, atomic_save_workbook, ensure_log_schema

DB = ROOT / "installer_database" / "installer_database.xlsx"
SCRIPTS = ROOT / "scripts"
LIVE_LOG_PATH: Path | None = None
LIVE_LOG_HANDLE: Any = None
LIVE_RUNTIME_DIR: Path | None = None
RUN_FINALIZED = False
ACTIVE_CHILD: subprocess.Popen[str] | None = None
ENGINE_PAUSED = False


def emit(*args: Any, **kwargs: Any) -> None:
    """A closed app/terminal output pipe must never kill a running build."""
    output = kwargs.get("file", sys.stdout)
    try:
        builtins.print(*args, **kwargs)
    except BrokenPipeError:
        if output is sys.stdout:
            sys.stdout = open(os.devnull, "w")
        elif output is sys.stderr:
            sys.stderr = open(os.devnull, "w")


class RunLogs(deque):
    """Bound summary memory; complete output is streamed to a permanent log file."""
    def __init__(self):
        super().__init__(maxlen=4000)

    def __add__(self, other):
        return list(self) + list(other)


def table(book: Any, name: str) -> list[dict[str, Any]]:
    sheet = book[name]
    rows = list(sheet.iter_rows(values_only=True))
    if not rows:
        return []
    headers = [str(x).strip() if x is not None else "" for x in rows[0]]
    return [dict(zip(headers, row)) for row in rows[1:] if any(x is not None for x in row)]


def val(row: dict[str, Any], key: str, default: str = "") -> str:
    item = row.get(key)
    return default if item is None else str(item).strip()


def truth(item: Any) -> bool:
    return item is True or str(item).strip().lower() in {"true", "yes", "1", "y"}


def load_database() -> tuple[Any, dict[str, Any], list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]]]:
    if not DB.is_file() and not DB.with_name("projects.json").is_file():
        raise ValueError(f"Project database not found: {DB}")
    book = open_database_store(DB, include_history=False)
    required = {"Projects", "Repositories", "Dependencies", "InstallerAssets", "ProjectDependencies"}
    if not required.issubset(book.sheetnames):
        raise ValueError(f"Database is missing sheets: {', '.join(sorted(required - set(book.sheetnames)))}")
    projects, repos, deps, assets = (table(book, s) for s in ("Projects", "Repositories", "Dependencies", "InstallerAssets"))
    return book, {val(p, "Profile ID"): p for p in projects}, repos, deps, assets


def absolute(value: str, fallback: Path) -> Path:
    path = Path(value).expanduser() if value else fallback
    if not path.is_absolute():
        return (ROOT / path).resolve()
    # The seed workbook may have been created at a different checkout location.
    parts = path.parts
    if ROOT.name in parts:
        index = len(parts) - 1 - list(reversed(parts)).index(ROOT.name)
        return (ROOT.joinpath(*parts[index + 1:])).resolve()
    return path


def repos_for(profile: str, rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    group_order = {"core": 0, "data_plugin": 1, "plugin": 2}
    selected = [r for r in rows if val(r, "Profile ID") == profile and truth(r.get("Enabled"))]
    for repo in selected:
        group = val(repo, "Group").lower()
        if group not in group_order:
            raise ValueError(f"Unknown repository group {group!r} for {val(repo, 'Repository')}")
        if not val(repo, "Repository") or not val(repo, "Ref"):
            raise ValueError(f"Repository and pinned ref are required in project {profile}")
    return sorted(selected, key=lambda r: (group_order[val(r, "Group").lower()], int(r.get("Order") or 0), val(r, "Repository")))



def sync_repositories(
    profile: str,
    project: dict[str, Any],
    rows: list[dict[str, Any]],
    update: bool,
    logs: list[tuple[str, str, str]],
) -> None:
    source = absolute(val(project, "Source root"), ROOT / "sources" / profile)
    source.mkdir(parents=True, exist_ok=True)

    for row in repos_for(profile, rows):
        name, ref = val(row, "Repository"), val(row, "Ref")
        folder = source / name
        url = val(row, "Clone URL") or (
            f"{val(project, 'Repository base URL', 'https://github.com/ManiVaultStudio').rstrip('/')}/{name}.git"
        )

        dirty = ""
        newly_cloned = False
        if not (folder / ".git").is_dir():
            if folder.exists():
                raise ValueError(
                    f"Cannot clone {name}: destination exists but is not a Git checkout: {folder}"
                )

            emit(f"Cloning {name} ({ref}) from {url}", flush=True)
            run_logged(
                ["git", "clone", "--no-checkout", url, str(folder)],
                cwd=ROOT, env=None, logs=logs, stage=f"clone {name}",
            )
            newly_cloned = True
        else:
            if not newly_cloned:
                dirty_result = subprocess.run(
                    ["git", "-C", str(folder), "status", "--porcelain"],
                    check=True, capture_output=True, text=True,
                )

                dirty = dirty_result.stdout.strip()
                deleted_result = subprocess.run(
                    ["git", "-C", str(folder), "ls-files", "--deleted"],
                    check=True, capture_output=True, text=True,
                )
                deleted_files = [line for line in deleted_result.stdout.splitlines() if line.strip()]
                if deleted_files:
                    sample = ", ".join(deleted_files[:3])
                    raise ValueError(
                        f"Refusing to build incomplete checkout {name}: {len(deleted_files)} tracked files are missing "
                        f"({sample}). Existing files and local edits are preserved; choose a clean source root and clone again."
                    )
        # Only the explicit Update action fetches all remote refs. Builds reuse
        # cached pins and can run without redundant network access.
        if update:
            run_logged(
                ["git", "-C", str(folder), "fetch", "--prune", "--tags", "origin"],
                cwd=ROOT, env=None, logs=logs, stage=f"fetch {name}",
            )

        # Resolve tags and branches without falling back to another ref.
        candidates = [
            f"refs/tags/{ref}",
            f"refs/remotes/origin/{ref}",
            f"refs/heads/{ref}",
            ref,
        ]

        resolved = None
        for candidate in candidates:
            result = subprocess.run(
                [
                    "git", "-C", str(folder), "rev-parse",
                    "--verify", f"{candidate}^{{commit}}",
                ],
                capture_output=True, text=True,
            )
            if result.returncode == 0:
                resolved = result
                break

        if resolved is None and not update:
            run_logged(
                ["git", "-C", str(folder), "fetch", "--tags", "origin", ref],
                cwd=ROOT, env=None, logs=logs, stage=f"fetch {name} ref",
            )
            for candidate in candidates:
                result = subprocess.run(
                    ["git", "-C", str(folder), "rev-parse", "--verify", f"{candidate}^{{commit}}"],
                    capture_output=True, text=True,
                )
                if result.returncode == 0:
                    resolved = result
                    break

        if resolved is None:
            remote = subprocess.run(
                [
                    "git", "-C", str(folder), "ls-remote",
                    "--heads", "--tags", "origin",
                    ref, f"refs/heads/{ref}", f"refs/tags/{ref}",
                ],
                capture_output=True, text=True,
            )

            if remote.returncode or not remote.stdout.strip():
                raise ValueError(
                    f"Pinned ref {ref!r} was not found for {name}; no fallback was used"
                )

            run_logged(
                ["git", "-C", str(folder), "fetch", "origin", ref],
                cwd=ROOT, env=None, logs=logs, stage=f"fetch {name} ref",
            )

            result = subprocess.run(
                [
                    "git", "-C", str(folder), "rev-parse",
                    "--verify", "FETCH_HEAD^{commit}",
                ],
                capture_output=True, text=True,
            )
            if result.returncode == 0:
                resolved = result

        if resolved is None or resolved.returncode != 0:
            detail = resolved.stderr.strip() if resolved else "Ref could not be resolved"
            raise RuntimeError(
                f"Could not resolve pinned ref {ref!r} for {name}: {detail}"
            )

        commit = resolved.stdout.strip()

        if newly_cloned:
            # Fresh clones use --no-checkout. Their initial status can look like
            # staged deletions, and HEAD may already equal the requested pin.
            # Force-populate this known-empty clone before treating it as ready.
            run_logged(
                ["git", "-C", str(folder), "checkout", "--force", "--detach", commit],
                cwd=ROOT, env=None, logs=logs, stage=f"checkout {name}",
            )
            run_logged(
                ["git", "-C", str(folder), "submodule", "sync", "--recursive"],
                cwd=ROOT, env=None, logs=logs, stage=f"sync submodules {name}",
            )
            run_logged(
                ["git", "-C", str(folder), "submodule", "update", "--init", "--recursive"],
                cwd=ROOT, env=None, logs=logs, stage=f"submodules {name}",
            )
            emit(f"Ready: {name} @ {ref}", flush=True)
            continue

        current = subprocess.run(
            ["git", "-C", str(folder), "rev-parse", "HEAD"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
        if dirty:
            if current == commit:
                message = f"Preserving local edits in {name}; checkout already matches pinned ref {ref}."
                emit(f"⚠️ {message}", flush=True)
                logs.append(("WARNING", f"checkout {name}", message))
                continue
            raise ValueError(
                f"Refusing to change {name}: local changes are present and checkout does not match pinned ref {ref}: {folder}"
            )
        if current == commit:
            emit(f"Ready: {name} @ {ref} (already pinned)", flush=True)
            continue

        run_logged(
            ["git", "-C", str(folder), "switch", "--detach", commit],
            cwd=ROOT, env=None, logs=logs, stage=f"checkout {name}",
        )

        run_logged(
            [
                "git", "-C", str(folder), "submodule",
                "sync", "--recursive",
            ],
            cwd=ROOT, env=None, logs=logs, stage=f"sync submodules {name}",
        )

        run_logged(
            [
                "git", "-C", str(folder), "submodule",
                "update", "--init", "--recursive",
            ],
            cwd=ROOT, env=None, logs=logs, stage=f"submodules {name}",
        )

        emit(f"Ready: {name} @ {ref}", flush=True)


def profile_environment(profile: str, project: dict[str, Any], assets: list[dict[str, Any]], repo_rows: list[dict[str, Any]], dependency_manifest: Path) -> tuple[Path, Path]:
    asset = next((a for a in assets if val(a, "Profile ID") == profile), {})
    source_default = ROOT / "sources" / profile
    build_default = ROOT / "builds" / profile
    source = absolute(val(project, "Source root"), source_default)
    core_source = absolute(val(project, "Core source directory"), source / "core")
    build = absolute(val(project, "Build root"), build_default)
    def project_path(key: str, default: Path) -> str:
        return str(absolute(val(project, key), default))
    base = absolute(val(asset, "Installer materials root"), ROOT / "installer_materials" / "projects" / profile)
    customize = val(project, "Customization folder", "true").lower()
    data = [r for r in repos_for(profile, repo_rows) if val(r, "Group").lower() == "data_plugin"]
    plugins = [r for r in repos_for(profile, repo_rows) if val(r, "Group").lower() == "plugin"]
    def repo_json(rows: list[dict[str, Any]]) -> str:
        names = [val(r, "Repository") for r in rows]
        refs = {val(r, "Repository"): val(r, "Ref") for r in rows}
        core = next((val(r, "Ref") for r in repos_for(profile, repo_rows) if val(r, "Group").lower() == "core"), "main")
        return json.dumps({"defaultBranch": core, "repos": names, "branchOverrides": refs}, separators=(",", ":"))
    minimum_core = val(project, "Minimum core version", "1.4.0")
    core_parts = re.match(r"^(\d+)\.(\d+)\.(\d+)(.*)$", minimum_core)
    if not core_parts:
        raise ValueError(f"Minimum core version must be semantic version format: {minimum_core}")
    def asset_path(key: str, default: Path) -> str:
        return str(absolute(val(asset, key), default))
    env_values = {
        "PROFILE_NAME": profile, "PROJECT_FOLDER_NAME": profile, "APP_VERSION": val(project, "App version", "1.0.0"),
        "APP_NAME": val(project, "App bundle", "ManiVault Studio.app"), "BUILD_TYPE": val(project, "Build type", "Release"),
        "CORE_BRANCH": val(project, "Core ref", "main"), "ARCHS": val(project, "Architectures", "arm64;x86_64"),
        "MIN_MACOS_VERSION": val(project, "Minimum macOS", "12.0"), "SOURCE_ROOT": str(source),
        "CORE_SOURCE_DIR": str(core_source), "BUILD_ROOT": str(build),
        "BUILDFILES_ROOT": str(ROOT / "builds"), "INSTALL_DIR": project_path("Install directory", build / "install" / profile),
        "INSTALL_COPY_DIR": project_path("Install copy directory", build / "installCopy" / profile),
        "INSTALL_DMG_TEMP_DIR": project_path("DMG staging directory", build / "dmg_temp_content" / profile),
        "OUTPUT_DIR": project_path("DMG output directory", ROOT / "application"),
        "VOLUME_NAME": val(project, "Display name", profile), "BASE_URL": val(project, "Repository base URL", "https://github.com/ManiVaultStudio"),
        "CUSTOMIZATION_FOLDER_PRESENT": "false" if customize in {"false", "no", "0"} else "true",
        "DEPENDENCY_BUILD_MODE": val(project, "Dependency mode", "if-missing"), "DEPENDENCY_MANIFEST_FILE": str(dependency_manifest),
        "LIBRARIES_ROOT": str(ROOT / "libraries"),
        "QT_VERSION": val(project, "Qt version", "6.10.3"), "QT_DIR": project_path("Qt directory", ROOT / "libraries" / "qt" / val(project, "Qt version", "6.10.3") / "macos"),
        "VULKAN_SDK_VERSION": val(project, "Vulkan SDK version", "1.4.350.0"),
        "VULKAN_SDK": str(absolute(val(project, "Vulkan SDK directory"), Path.home() / "VulkanSDK" / val(project, "Vulkan SDK version", "1.4.350.0") / "macOS")),
        "INSTALLER_MATERIALS_ROOT": str(base), "INSTALLER_MATERIALS": str(base),
        "PROJECTS_SOURCE_FILE": asset_path("Projects JSON", base / "projects.json"), "APP_CONFIG_SOURCE_FILE": asset_path("App JSON", base / "app.json"),
        "APP_ICON_FILE": asset_path("App icon", base / "appimage-manivault.icns"), "DMG_BACKGROUND_IMAGE": asset_path("DMG background", base / "dmg-background-manivault.png"),
        "FOLDER_ICONS_DIR": asset_path("Folder icons directory", base / "folderIcons-manivault"), "APPLY_FOLDER_ICONS": "true" if truth(asset.get("Apply folder icons")) else "false",
        "MAIN_FOLDER_ICON_FILE": asset_path("Main folder icon", base / "main-folder-icon.png"),
        "LICENSE_DIR": asset_path("License directory", ROOT / "installer_materials" / "common" / "license"), "ASSETS_DIR": asset_path("Assets directory", ROOT / "installer_materials" / "common" / "assets"),
        "MIN_CORE_VERSION_MAJOR": core_parts.group(1), "MIN_CORE_VERSION_MINOR": core_parts.group(2),
        "MIN_CORE_VERSION_PATCH": core_parts.group(3), "MIN_CORE_VERSION_SUFFIX": core_parts.group(4),
        "DATAPLUGIN_REPOS": repo_json(data), "PLUGIN_REPOS": repo_json(plugins), "RUN_COMMON_DEPENDENCY_BUILDS": "false", "PACKAGE_INSTALLER": "false",
        "CORE_BRANCH": val(next((r for r in repos_for(profile, repo_rows) if val(r, "Group").lower() == "core"), {}), "Ref", val(project, "Core ref", "main")),
    }
    manifest_entries = json.loads(dependency_manifest.read_text())["dependencies"]
    env_values.update(version_environment(manifest_entries))
    temp_dir = dependency_manifest.parent
    temp_dir.mkdir(parents=True, exist_ok=True)
    env_path = temp_dir / "project.env"
    env_path.write_text("\n".join(f"{key}={shlex.quote(str(value))}" for key, value in env_values.items()) + "\n", encoding="utf-8")
    return env_path, source


def dependency_manifest(rows: list[dict[str, Any]], path: Path) -> None:
    items = []
    for row in rows:
        name, script = val(row, "Name"), val(row, "Build Script")
        if not name:
            continue
        try:
            artifacts = json.loads(val(row, "Artifacts JSON", "[]"))
            requires = json.loads(val(row, "Requires JSON", "[]"))
            recipe = json.loads(val(row, "Recipe JSON", "{}"))
        except json.JSONDecodeError as exc:
            raise ValueError(f"Invalid JSON in dependency {name}: {exc}") from exc
        if not isinstance(artifacts, list) or not isinstance(requires, list) or not isinstance(recipe, dict):
            raise ValueError(f"Dependency {name}: artifacts/requires must be lists and recipe must be an object")
        if script.upper() != "GENERIC" and not (SCRIPTS / "dependencies" / script).is_file():
            raise ValueError(f"Dependency {name}: build script not found: {script}")
        linkage = val(row, "Linkage", "static").lower()
        if linkage not in {"static", "shared", "both", "header-only"}:
            raise ValueError(f"Dependency {name}: Linkage must be static, shared, both, or header-only")
        try:
            runtime_artifacts = json.loads(val(row, "Runtime Files JSON", "[]"))
        except json.JSONDecodeError as exc:
            raise ValueError(f"Invalid runtime files JSON in dependency {name}: {exc}") from exc
        if not isinstance(runtime_artifacts, list):
            raise ValueError(f"Dependency {name}: Runtime Files JSON must be a list")
        items.append({"enabled": truth(row.get("Enabled")), "name": name, "version": val(row, "Version / commit"), "linkage": linkage, "script": script, "artifacts": artifacts, "runtimeArtifacts": runtime_artifacts, "requires": requires, "recipe": recipe})
    path.write_text(json.dumps({"schemaVersion": 1, "dependencies": items}, indent=2) + "\n", encoding="utf-8")


def _terminate_child_tree(process: subprocess.Popen[str] | None) -> None:
    """Stop the active command and its descendants when the engine is stopped."""
    if process is None or process.poll() is not None:
        return
    try:
        if os.name == "posix":
            os.killpg(process.pid, signal.SIGCONT)
            os.killpg(process.pid, signal.SIGTERM)
        else:
            process.terminate()
    except ProcessLookupError:
        pass
    except OSError:
        try:
            process.terminate()
        except OSError:
            pass
    try:
        process.wait(timeout=8)
    except subprocess.TimeoutExpired:
        try:
            if os.name == "posix":
                os.killpg(process.pid, signal.SIGKILL)
            else:
                process.kill()
        except OSError:
            pass
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            pass


def _handle_engine_pause(signum: int, _frame: Any) -> None:
    global ENGINE_PAUSED
    ENGINE_PAUSED = signum == signal.SIGUSR1
    child = ACTIVE_CHILD
    if child is not None and child.poll() is None:
        try:
            os.killpg(child.pid, signal.SIGSTOP if ENGINE_PAUSED else signal.SIGCONT)
        except ProcessLookupError:
            pass


def _handle_engine_stop(signum: int, _frame: Any) -> None:
    # The active command has its own process group, so stopping the engine also
    # stops shell/CMake/Ninja descendants rather than leaving orphaned builds.
    _terminate_child_tree(ACTIVE_CHILD)
    raise SystemExit(128 + signum)


def workflow_stage(number, stage_logs, operation, *args, **kwargs):
    def record(status):
        message = f"[studio-stage:{number}:{status}]"
        emit(message, flush=True)
        if LIVE_RUNTIME_DIR is not None:
            try:
                temporary = LIVE_RUNTIME_DIR / 'stage.json.tmp'
                temporary.write_text(json.dumps({'number': number, 'status': status}))
                os.replace(temporary, LIVE_RUNTIME_DIR / 'stage.json')
            except OSError:
                pass
        stage_logs.append(("ERROR" if status == "failed" else "INFO", "workflow", message))
    record("running")
    try:
        result = operation(*args, **kwargs)
        if isinstance(result, int) and result != 0:
            record("failed")
        else:
            record("completed")
        return result
    except BaseException:
        record("failed")
        raise


def run_logged(command: list[str], *, cwd: Path, env: dict[str, str] | None, logs: list[tuple[str, str, str]], stage: str, continue_on_error: bool = False) -> int:
    global ACTIVE_CHILD
    while ENGINE_PAUSED:
        time.sleep(.1)
    process = subprocess.Popen(
        command, cwd=cwd, env=env, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT, text=True, bufsize=1,
        start_new_session=(os.name == "posix"),
    )
    ACTIVE_CHILD = process
    try:
        assert process.stdout is not None
        for line in process.stdout:
            line = line.rstrip("\n")
            emit(line, flush=True)
            if LIVE_LOG_HANDLE is not None:
                LIVE_LOG_HANDLE.write(line + "\n")
                LIVE_LOG_HANDLE.flush()
            upper = line.upper()
            is_error = re.search(
                r"(?:^|\b)(?:ERROR|FATAL|FAILED)\s*[:!]|CMAKE ERROR|FATAL ERROR|"
                r"NINJA: BUILD STOPPED|PROJECT BUILD FAILED|COMPILATION TERMINATED|TRACEBACK|✗",
                upper,
            )
            is_warning = re.search(r"(?:CMAKE )?WARNING(?:\b|:)|\bWARN:|⚠", upper)
            level = "ERROR" if is_error else "WARNING" if is_warning else "INFO"
            logs.append((level, stage, line))
        code = process.wait()
    except BaseException:
        _terminate_child_tree(process)
        raise
    finally:
        ACTIVE_CHILD = None
        if process.stdout is not None:
            process.stdout.close()
    if code:
        if code in {-9, 137}:
            reason = "The operating system killed the process, possibly because of memory pressure. Choose Low memory in Build limits, close large apps, and retry."
        elif code in {-15, 143}:
            reason = "The process received a termination signal. It may have been stopped by the user or another system process."
        else:
            reason = "Review the first error above. Retry reuses completed dependencies."
        detail = f"{stage} failed with exit code {code}. {reason} Command: {shlex.join(command)}"
        emit(f"ERROR: {detail}", flush=True)
        logs.append(("ERROR", stage, detail))
        if not continue_on_error:
            raise RuntimeError(detail)
    return code


def install_dependencies(dependency_path: Path, project: dict[str, Any], mode: str,
                         logs: list[tuple[str, str, str]], stage: str = "dependencies", selected: str = "") -> None:
    env = os.environ.copy()
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + env.get("PATH", "")
    env["LIBRARIES_ROOT"] = str(ROOT / "libraries")
    run_logged(["bash", str(SCRIPTS / "dependencies/check_host.sh")], cwd=ROOT, env=env, logs=logs, stage="dependency prerequisites")
    if not selected and val(project, "Profile ID") != "workspace":
        config = open_database_store(DB, include_history=False)
        try:
            required_sources = [row for row in table(config, "ProjectDependencies") if val(row, "Profile ID") == val(project, "Profile ID") and val(row, "Kind") == "pin" and truth(row.get("Required"))]
        finally:
            config.close()
        pins = json.loads((ROOT / "installer_database/source_pins.json").read_text())["dependencies"]
        for required in required_sources:
            pin = next((pin for pin in pins if pin["name"] == val(required, "Dependency")), None)
            if pin is None or str(pin.get("version") or pin.get("git_tag")) != val(required, "Version"):
                raise ValueError(f"Source requirement {val(required, 'Dependency')} needs {val(required, 'Version')}. Update its project requirement or restore that version.")
            run_logged([sys.executable, str(SCRIPTS / "dependencies/install_source.py"), str(pin["name"])], cwd=ROOT, env=env, logs=logs, stage="install source")
    qt_version = val(project, "Qt version", "6.10.3")
    qt_dir = absolute(val(project, "Qt directory"), ROOT / "libraries" / "qt" / qt_version / "macos")
    env.update({"SCRIPTS_ROOT": str(SCRIPTS), "DEPENDENCY_MANIFEST_FILE": str(dependency_path),
                "DEPENDENCY_PROJECT_ARCHS": val(project, "Architectures", "arm64;x86_64"), "PROFILE_NAME": val(project, "Profile ID"),
                "LIBRARIES_ROOT": str(ROOT / "libraries"), "QT_VERSION": qt_version,
                "QT_DIR": str(qt_dir), "DEPENDENCY_BUILD_MODE": mode})
    env.update(version_environment(json.loads(dependency_path.read_text())["dependencies"]))
    if selected:
        env["DEPENDENCIES"] = selected
    # Qt is the build toolchain prerequisite for QADS. Provision it first;
    # the dependency manager then keeps the manifest's existing order intact.
    run_logged(["bash", str(SCRIPTS / "dependencies" / "build_qt_universal.sh")], cwd=ROOT, env=env,
               logs=logs, stage=f"{stage}: Qt {qt_version}")
    run_logged(["bash", str(SCRIPTS / "dependencies" / "run_dependency_manager.sh"),
                "--manifest", str(dependency_path), "--mode", mode, *(["--dependencies", selected] if selected else [])], cwd=ROOT, env=env,
               logs=logs, stage=stage)


def build_project(env_file: Path, skip_clean: bool, logs: list[tuple[str, str, str]], *, dry_run: bool = False) -> None:
    env = os.environ.copy()
    if dry_run:
        env["DRY_RUN"] = "true"

    command = ["bash", str(SCRIPTS / "pipeline" / "run_project_profile.sh"), str(env_file),
               "--skip-update", "--skip-repo-sync"]
    command.append("--skip-clean" if skip_clean or dry_run else "--clean")
    run_logged(command, cwd=ROOT, env=env, logs=logs, stage="project build")


def package_project(env_file: Path, logs: list[tuple[str, str, str]], *, dry_run: bool = False) -> None:
    env = os.environ.copy()
    if dry_run:
        env["DRY_RUN"] = "true"
    run_logged(["bash", str(SCRIPTS / "entrypoints" / "create_installer.sh"), str(env_file)], cwd=ROOT,
               env=env, logs=logs, stage="installer package")


def diagnose_project(profile: str, project: dict[str, Any], assets: list[dict[str, Any]], repo_rows: list[dict[str, Any]], dependency_path: Path, logs: list[tuple[str, str, str]]) -> int:
    blockers = 0
    def report(ok: bool, message: str, remedy: str = "", severity: str = "ERROR") -> None:
        nonlocal blockers
        level = "INFO" if ok else severity
        line = f"{'OK' if ok else 'CHECK'}: {message}" + (f" — {remedy}" if remedy and not ok else "")
        emit(line, flush=True)
        logs.append((level, "diagnose", line))
        if not ok: blockers += 1

    report(platform.system() == "Darwin", f"Operating system: {platform.system()}", "Run builds and DMG packaging on macOS.")
    tools = ("git", "cmake", "ninja", "xcrun", "lipo", "otool", "codesign", "hdiutil")
    for tool in tools:
        report(shutil.which(tool) is not None, f"Build tool: {tool}", f"Install or add {tool} to PATH.")

    version = val(project, "Qt version", "6.10.3")
    qt_dir = ROOT / "libraries" / "qt" / version / "macos"
    report((qt_dir / "lib/cmake/Qt6/Qt6Config.cmake").is_file(), f"Qt {version} at {qt_dir}", "Set the correct Qt directory in the Projects sheet.")
    sdk_version = val(project, "Vulkan SDK version", "1.4.350.0")
    sdk_dir = absolute(val(project, "Vulkan SDK directory"), Path.home() / "VulkanSDK" / sdk_version / "macOS")
    vulkan_ready = (sdk_dir / "bin/glslc").exists() or (sdk_dir / "lib/cmake/vulkan").exists()
    report(vulkan_ready, f"Vulkan SDK {sdk_version} at {sdk_dir}", "Install that SDK version or update its directory in the Projects sheet.")
    for key in ("Build root", "Install directory", "DMG staging directory", "DMG output directory"):
        destination = absolute(val(project, key), ROOT / "builds" / profile)
        parent = destination
        while not parent.exists() and parent != parent.parent:
            parent = parent.parent
        report(parent.exists() and os.access(parent, os.W_OK), f"Writable path for {key}: {destination}", "Choose a writable location in the Projects sheet.")

    asset = next((row for row in assets if val(row, "Profile ID") == profile), {})
    for key in ("Projects JSON", "App JSON", "App icon", "DMG background", "Folder icons directory", "License directory", "Assets directory"):
        value = val(asset, key)
        if value:
            path = absolute(value, ROOT)
            report(path.exists(), f"{key}: {path}", f"Correct the {key} path in InstallerAssets.")
            if path.is_file() and path.suffix.lower() == ".json":
                try: json.loads(path.read_text(encoding="utf-8"))
                except (OSError, json.JSONDecodeError) as exc: report(False, f"{key} contains invalid JSON: {exc}", "Fix the JSON syntax before packaging.")

    source = absolute(val(project, "Source root"), ROOT.parent / "source" / profile)
    selected_repos = repos_for(profile, repo_rows)
    missing_repos: list[str] = []
    dirty_repos: list[str] = []
    incomplete_repos: list[str] = []
    mismatched_repos: list[str] = []
    for repo in selected_repos:
        name = val(repo, "Repository")
        folder = source / name
        if not (folder / ".git").is_dir():
            missing_repos.append(name)
            continue
        dirty = subprocess.run(["git", "-C", str(folder), "status", "--porcelain"], capture_output=True, text=True).stdout
        if dirty: dirty_repos.append(name)
        deleted = subprocess.run(["git", "-C", str(folder), "ls-files", "--deleted"], capture_output=True, text=True).stdout
        if deleted.strip(): incomplete_repos.append(f"{name} ({len(deleted.splitlines())} tracked files missing)")
        resolved = subprocess.run(["git", "-C", str(folder), "rev-parse", "--verify", f"{val(repo, 'Ref')}^{{commit}}"], capture_output=True, text=True)
        head = subprocess.run(["git", "-C", str(folder), "rev-parse", "HEAD"], capture_output=True, text=True)
        if resolved.returncode == 0 and head.returncode == 0 and resolved.stdout.strip() != head.stdout.strip():
            mismatched_repos.append(name)
    report(not missing_repos, f"Repository check: {len(selected_repos) - len(missing_repos)}/{len(selected_repos)} cloned", "Use Clone repositories to fetch missing sources.", "WARNING")
    report(True, f"Repository check: {len(dirty_repos)} local edits (informational)", "Clone, Update, and Full discard local changes before checking out pinned refs.",)
    report(not incomplete_repos, f"Repository content check: {len(incomplete_repos)} incomplete checkouts", "Choose a clean source root and clone the pinned repositories again; existing edits will be preserved.")
    checked_refs = len(selected_repos) - len(missing_repos)
    ref_ok = not mismatched_repos
    ref_summary = "No local refs to verify yet; run Clone repositories first" if checked_refs == 0 else f"Repository pins: {checked_refs - len(mismatched_repos)}/{checked_refs} cloned repos match their refs"
    report(ref_ok, ref_summary, "Use Update repositories to check out the declared refs.", "WARNING")
    if missing_repos:
        line = "Missing repositories: " + ", ".join(missing_repos)
        emit(line, flush=True); logs.append(("WARNING", "repository check", line))
    if dirty_repos:
        line = "Repositories with local edits: " + ", ".join(dirty_repos)
        emit(line, flush=True); logs.append(("WARNING", "repository check", line))
    if incomplete_repos:
        line = "Repositories with missing tracked files: " + ", ".join(incomplete_repos)
        emit(line, flush=True); logs.append(("ERROR", "repository check", line))
    if mismatched_repos:
        line = "Repositories at a different ref: " + ", ".join(mismatched_repos)
        emit(line, flush=True); logs.append(("WARNING", "repository check", line))

    env = os.environ.copy()
    env.update({"SCRIPTS_ROOT": str(SCRIPTS), "DEPENDENCY_MANIFEST_FILE": str(dependency_path), "ARCHS": val(project, "Architectures", "arm64;x86_64")})
    check = subprocess.run([sys.executable, str(SCRIPTS / "dependencies" / "dependency_manager.py"), "--manifest", str(dependency_path), "--check-only", "--dry-run"], cwd=ROOT, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    for line in check.stdout.splitlines():
        emit(line, flush=True)
        logs.append(("INFO" if check.returncode == 0 else "WARNING", "dependency check", line))
    report(check.returncode == 0, "Shared dependency outputs and architectures", "Use Build dependencies; inspect each missing output in Logs.", "WARNING")
    if blockers:
        emit(f"Diagnosis found {blockers} item(s) to fix. Start with the CHECK messages above, then run Check setup again.", flush=True)
        return 1
    emit("Project setup checks passed. If a build fails, open the Logs sheet and find the first failing stage.", flush=True)
    return 0


def append_run(book: Any, profile: str, action: str, started: str, status: str, summary: str, dmg: str = "", logs: list[tuple[str, str, str]] | None = None, run_id: str = "") -> None:
    # Refresh only the history being changed; never retain an entire old log
    # database during a long native build.
    book = open_database_store(DB, tables=["Runs", "Logs"] if logs else ["Runs"])
    try:
        if logs:
            ensure_log_schema(book)
        sheet = book["Runs"]
        headers = {str(sheet.cell(1, col).value): col for col in range(1, sheet.max_column + 1)}
        row = next((number for number in range(2, sheet.max_row + 1)
                    if str(sheet.cell(number, headers["Run ID"]).value) == run_id), None)
        values = {"Run ID": run_id, "Profile ID": profile, "Action": action, "Started UTC": started,
                  "Finished UTC": "" if status == "running" else dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
                  "Status": status, "DMG path": dmg, "Summary": summary}
        if row is None:
            sheet.append([values.get(str(sheet.cell(1, col).value), "") for col in range(1, sheet.max_column + 1)])
        else:
            for key, value in values.items():
                sheet.cell(row, headers[key]).value = value
        for level, stage, message in logs or []:
            append_log_row(book["Logs"], run_id, profile, level, stage, message)
        atomic_save_workbook(book, DB)

    finally:
        book.close()


def finalize_run(*args: Any, **kwargs: Any) -> None:
    """Persist a terminal run state before allowing runtime metadata cleanup."""
    global RUN_FINALIZED
    append_run(*args, **kwargs)
    RUN_FINALIZED = True


def main() -> int:
    if os.name == "posix":
        signal.signal(signal.SIGTERM, _handle_engine_stop)
        signal.signal(signal.SIGINT, _handle_engine_stop)
        signal.signal(signal.SIGUSR1, _handle_engine_pause)
        signal.signal(signal.SIGUSR2, _handle_engine_pause)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("list", "check", "clone", "update", "dependencies", "package", "build", "full", "all", "install-dependency", "uninstall-dependency"))
    parser.add_argument("profile", nargs="?")
    parser.add_argument("--dry-run", action="store_true")
    clean_group = parser.add_mutually_exclusive_group()
    clean_group.add_argument("--skip-clean", dest="skip_clean", action="store_true", default=True)
    clean_group.add_argument("--clean", dest="skip_clean", action="store_false")
    parser.add_argument("--dependency-mode", choices=("if-missing", "always", "skip"))
    parser.add_argument("--run-id", help="Use a caller-provided ID to group this operation and its activity")
    parser.add_argument("--jobs", type=int, choices=range(0, 9), default=0)
    parser.add_argument("--dependency")
    parser.add_argument("--dependency-kind", choices=("recipe", "pin"))
    args = parser.parse_args()
    args.jobs = args.jobs or automatic_jobs()
    os.environ["BUILD_JOBS"] = str(args.jobs)
    os.environ["CMAKE_BUILD_PARALLEL_LEVEL"] = str(args.jobs)
    if args.action == "list":
        book, projects, _, _, _ = load_database()
        emit(json.dumps([{"id": key, "name": val(row, "Display name", key), "version": val(row, "App version")} for key, row in projects.items()]))
        book.close()
        return 0
    if not args.profile:
        parser.error("profile is required for this action")
    profile, action = args.profile, args.action
    started = dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")
    run_id = args.run_id or str(uuid.uuid4())
    # Run IDs are used as directory names. Reject path separators and traversal.
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,119}", run_id) or run_id in {".", ".."}:
        parser.error("--run-id must be 1-120 safe filename characters (letters, digits, dot, underscore, hyphen)")
    global RUN_FINALIZED
    RUN_FINALIZED = False
    logs = RunLogs()
    book = None
    runtime_dir = ROOT / ".installer_runtime" / run_id
    try:
        book, projects, repos, deps, assets = load_database()
        all_profiles = action == "all"
        dependency_operation = action in {"install-dependency", "uninstall-dependency"}
        requirements = table(book, "ProjectDependencies")
        if profile not in projects and not all_profiles and not dependency_operation:
            raise ValueError(f"Unknown project {profile!r}. Use action 'list' to see projects.")
        if all_profiles:
            profile = "all"
            project = {}
        elif dependency_operation:
            profile = "workspace"
            qt_versions = {val(item, "Qt version", "6.10.3") for item in projects.values()}
            project = {"Profile ID": "workspace", "Display name": "Workspace", "Qt version": sorted(qt_versions)[0] if qt_versions else "6.10.3", "Architectures": "arm64;x86_64", "App version": "1.0.0"}
        else:
            project = projects[profile]
        settings = {val(row, "Setting"): val(row, "Value") for row in table(book, "Settings")} if "Settings" in book.sheetnames else {}
        if settings.get("Out path"):
            if all_profiles:
                for configured_project in projects.values():
                    configured_project["DMG output directory"] = settings["Out path"]
            else:
                project["DMG output directory"] = settings["Out path"]
        if not all_profiles and not re.fullmatch(r"\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?", val(project, "App version")):
            raise ValueError("App version must follow semantic versioning, such as 1.2.3 or 1.2.3-beta.1")
        dependency_path = runtime_dir / "dependencies.json"
        runtime_dir.mkdir(parents=True, exist_ok=True)
        global LIVE_LOG_PATH, LIVE_LOG_HANDLE, LIVE_RUNTIME_DIR
        LIVE_RUNTIME_DIR = runtime_dir
        LIVE_LOG_PATH = ROOT / "installer_database/local/run_output" / f"{run_id}.log"
        LIVE_LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        (runtime_dir / "live.log").symlink_to(LIVE_LOG_PATH)
        LIVE_LOG_HANDLE = LIVE_LOG_PATH.open("w", encoding="utf-8", buffering=1)
        # Keep the plain integer PID file for compatibility with installer_app.py.
        pid_tmp = runtime_dir / "pid.tmp"
        pid_tmp.write_text(str(os.getpid()), encoding="ascii")
        os.replace(pid_tmp, runtime_dir / "pid")
        metadata = {
            "run_id": run_id, "pid": os.getpid(), "started_utc": started,
            "executable": sys.executable, "script": str(Path(__file__).resolve()),
            "argv": sys.argv, "platform": platform.platform(),
        }
        metadata_tmp = runtime_dir / "process.json.tmp"
        metadata_tmp.write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
        os.replace(metadata_tmp, runtime_dir / "process.json")
        append_run(book, profile, action, started, "running", "Preparing project and pinned dependencies.", run_id=run_id)
        if not dependency_operation and not all_profiles:
            needed = [row for row in requirements if val(row, "Profile ID") == profile and val(row, "Kind", "recipe") == "recipe" and truth(row.get("Required"))]
            by_name = {val(row, "Name"): row for row in deps}
            problems = [f"{val(row, 'Dependency')}: needs {val(row, 'Version')}, catalog has {val(by_name.get(val(row, 'Dependency'), {}), 'Version / commit', 'no registration')}"
                        for row in needed if val(row, "Dependency") not in by_name or val(by_name[val(row, "Dependency")], "Version / commit") != val(row, "Version")]
            if problems and action in {"dependencies", "build", "full", "package"}:
                raise ValueError("Project dependency requirements need attention: " + "; ".join(problems) + ". Update project requirements or restore the matching catalog version.")
            selected_names = {val(row, "Dependency") for row in needed}
            deps = [{**row, "Enabled": val(row, "Name") in selected_names} for row in deps]
        dependency_manifest([{**row, "Enabled": True} for row in deps] if dependency_operation else deps, dependency_path)
        if all_profiles:
            selected = sorted(projects, key=lambda item: item.lower())
            if "cytosplore-viewer-500" in selected:
                selected.remove("cytosplore-viewer-500")
                selected.insert(0, "cytosplore-viewer-500")
            if "cytosplore-viewer-2026" in selected:
                selected.remove("cytosplore-viewer-2026")
                selected.insert(0, "cytosplore-viewer-2026")
            book.close()
            book = None
            failures: list[str] = []
            for project_id in selected:
                emit(f"\n===== {project_id}: repositories → dependencies → check → build → DMG =====", flush=True)
                child = [sys.executable, str(SCRIPTS / "workflow" / "installer_engine.py"), "full", project_id,
                         "--dependency-mode", args.dependency_mode or val(projects[project_id], "Dependency mode", "if-missing"),
                         "--run-id", str(uuid.uuid4()), "--jobs", str(args.jobs)]
                child.append("--skip-clean" if args.skip_clean else "--clean")
                if args.dry_run:
                    child.append("--dry-run")
                code = run_logged(child, cwd=ROOT, env=os.environ.copy(), logs=logs,
                                  stage=f"profile {project_id}", continue_on_error=True)
                if code:
                    failures.append(project_id)
            if failures:
                raise RuntimeError("Build or DMG creation failed for: " + ", ".join(failures))
            book, *_ = load_database()
            finalize_run(book, profile, action, started, "dry-run" if args.dry_run else "succeeded",
                       f"All {len(selected)} project installers were created." if not args.dry_run else "All profiles passed the workflow preview.",
                       logs=logs, run_id=run_id)
            return 0
        if args.dependency_mode:
            project["Dependency mode"] = args.dependency_mode
        env_file, source = (runtime_dir / "project.env", ROOT) if dependency_operation else profile_environment(profile, project, assets, repos, dependency_path)
        operation = "full" if action == "full" else action
        emit(f"{val(project, 'Display name', profile)} — {action}", flush=True)
        emit(f"Run ID: {run_id}", flush=True)
        append_run(book, profile, action, started, "running", "Preparing project and pinned dependencies.", run_id=run_id)
        if dependency_operation:
            if not args.dependency or not args.dependency_kind:
                raise ValueError("Choose a dependency name and type.")
            book.close()
            book = None
            if action == "uninstall-dependency":
                from dependency_actions import uninstall
                entries = json.loads(dependency_path.read_text())["dependencies"]
                pins = json.loads((ROOT / "installer_database/source_pins.json").read_text())["dependencies"]
                # Use the same lock as the dependency manager.
                import fcntl
                lock_path = SCRIPTS / ".locks/shared-dependencies.lock"
                lock_path.parent.mkdir(parents=True, exist_ok=True)
                with lock_path.open("a+") as lock:
                    try:
                        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    except BlockingIOError:
                        raise ValueError("Another dependency operation is active.")
                    recovery = uninstall(ROOT, args.dependency, args.dependency_kind, entries, pins)
                    logs.append(("INFO", "uninstall", f"Uninstalled {args.dependency}; recovery files: {recovery}. Project readiness will reflect missing outputs."))
            elif args.dependency_kind == "pin":
                run_logged([sys.executable, str(SCRIPTS / "dependencies/install_source.py"), args.dependency],
                           cwd=ROOT, env=os.environ.copy(), logs=logs, stage="install source")
            else:
                install_dependencies(dependency_path, project, "if-missing", logs, selected=args.dependency)
            book, *_ = load_database()
            finalize_run(book, profile, action, started, "succeeded", f"{args.dependency}: completed.", logs=logs, run_id=run_id)
            return 0
        if action == "check":
            code = workflow_stage(3, logs, diagnose_project, profile, project, assets, repos, dependency_path, logs)
            finalize_run(book, profile, action, started, "succeeded" if code == 0 else "needs-attention", "Setup checks passed." if code == 0 else "Review CHECK messages and Logs.", logs=logs, run_id=run_id)
            return code
        if args.dry_run:
            emit(f"Project: {profile} ({val(project, 'App version')})", flush=True)
            emit(f"Source: {source}", flush=True)
            emit(f"Repositories in order: {', '.join(val(r, 'Repository') + '@' + val(r, 'Ref') for r in repos_for(profile, repos))}", flush=True)
            emit(f"Dependencies enabled: {sum(1 for d in deps if truth(d.get('Enabled')))}", flush=True)
            emit(f"Customization: {val(project, 'Customization folder')}", flush=True)
            emit(f"Would run action: {operation}", flush=True)
            if action in {"dependencies", "build", "full"}:
                env = os.environ.copy(); env.update({"SCRIPTS_ROOT": str(SCRIPTS), "DEPENDENCY_MANIFEST_FILE": str(dependency_path), "ARCHS": val(project, "Architectures", "arm64;x86_64")})
                run_logged([sys.executable, str(SCRIPTS / "dependencies" / "dependency_manager.py"), "--manifest", str(dependency_path), "--mode", args.dependency_mode or val(project, "Dependency mode", "if-missing"), "--dry-run"], cwd=ROOT, env=env, logs=logs, stage="dependency preview")
            if action in {"build", "full"}:
                build_project(env_file, True, logs, dry_run=True)
            if action == "full":
                emit("Check setup follows dependency verification; build and DMG creation follow the check.", flush=True)
            finalize_run(book, profile, action, started, "dry-run", "No changes were made.", logs=logs, run_id=run_id)
            return 0
        book.close()
        book = None
        if action in {"clone", "update", "build", "full"}:
            # Full release runs refresh clean checkouts to the configured pins;
            # a plain build reuses local pins and clones only missing checkouts.
            workflow_stage(1, logs, sync_repositories, profile, project, repos, update=action in {"update", "full"}, logs=logs)
        if action == "dependencies":
            workflow_stage(2, logs, install_dependencies, dependency_path, project, args.dependency_mode or val(project, "Dependency mode", "if-missing"), logs)
        elif action == "package":
            workflow_stage(5, logs, package_project, env_file, logs)
        elif action in {"build", "full"}:
            workflow_stage(2, logs, install_dependencies, dependency_path, project, args.dependency_mode or val(project, "Dependency mode", "if-missing"), logs)
            if action == "full":
                code = workflow_stage(3, logs, diagnose_project, profile, project, assets, repos, dependency_path, logs)
                if code:
                    raise RuntimeError("Setup checks failed; project build and DMG creation were stopped.")
            workflow_stage(4, logs, build_project, env_file, args.skip_clean, logs)
            if action == "full":
                workflow_stage(5, logs, package_project, env_file, logs)
        emit("Completed successfully.", flush=True)
        book, *_ = load_database()
        finalize_run(book, profile, action, started, "succeeded", "Completed successfully.", logs=logs, run_id=run_id)
        return 0
    except BaseException as exc:
        interrupted = isinstance(exc, (KeyboardInterrupt, SystemExit))
        interruption_code = int(exc.code) if isinstance(exc, SystemExit) and isinstance(exc.code, int) else 130
        summary = f"Operation interrupted (exit {interruption_code}). Complete output is preserved in the run log." if interrupted else str(exc)
        emit(f"Failed: {summary}", file=sys.stderr, flush=True)
        if LIVE_LOG_HANDLE is not None:
            LIVE_LOG_HANDLE.write(f"ERROR: {summary}\n")
            LIVE_LOG_HANDLE.flush()
        if action == "dependencies":
            detail = next((message for level, stage, message in reversed(logs) if stage == "dependencies" and level in {"ERROR", "WARNING"} and (" failed" in message.lower() or "download failed" in message.lower())), "")
            if detail:
                summary = f"Dependency build stopped: {detail.lstrip('✗ ').rstrip('.')}"
        if book is None:
            try:
                book = open_database_store(DB)
            except Exception:
                book = None
        if book:
            try:
                finalize_run(book, profile, action, started, "interrupted" if interrupted else "failed", summary, logs=logs + [("ERROR", action, str(exc))], run_id=run_id)
            except Exception:
                traceback.print_exc()
        return interruption_code if interrupted else getattr(exc, "returncode", 1) or 1
    finally:
        if book:
            book.close()
        if LIVE_LOG_HANDLE is not None:
            LIVE_LOG_HANDLE.close()
            LIVE_LOG_HANDLE = None
        if RUN_FINALIZED:
            shutil.rmtree(runtime_dir, ignore_errors=True)
        else:
            emit(
                f"WARNING: Run {run_id} did not reach a confirmed terminal database state; "
                f"preserving recovery metadata in {runtime_dir}",
                file=sys.stderr, flush=True,
            )


if __name__ == "__main__":
    raise SystemExit(main())
