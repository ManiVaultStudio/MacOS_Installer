#!/usr/bin/env python3
"""Resolve and build pinned shared dependencies from dependencies.json."""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import shutil
import subprocess
import sys
import uuid
from pathlib import Path


sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from dependency_config import manifest_data, version_environment, receipts, identity, save_receipt

SCRIPT_DIR = Path(__file__).resolve().parent
SCRIPTS_ROOT = SCRIPT_DIR.parent
LIBRARIES_ROOT = Path(os.environ.get("LIBRARIES_ROOT", SCRIPTS_ROOT.parent / "libraries")).expanduser().resolve()
DEFAULT_MANIFEST = SCRIPTS_ROOT.parent / "installer_database/dependencies.json"


def load_manifest(manifest_path: Path) -> list[dict[str, object]]:
    data = manifest_data(manifest_path)
    if data.get("schemaVersion") != 1 or not isinstance(data.get("dependencies"), list):
        raise ValueError("Unsupported or invalid dependency manifest schema")
    items = data["dependencies"]
    if not all(isinstance(item, dict) for item in items):
        raise ValueError("Every dependency entry must be an object")
    names = [item.get("name") for item in items]
    if any(not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]*", name) for name in names) or len(set(names)) != len(names):
        raise ValueError("Dependency names must be non-empty and unique")
    known = set(names)
    for item in items:
        if (not isinstance(item.get("script"), str) or not isinstance(item.get("artifacts"), list)
                or not all(isinstance(value, str) and value for value in item["artifacts"])
                or not isinstance(item.get("requires", []), list)
                or not all(isinstance(value, str) and value for value in item.get("requires", []))):
            raise ValueError(f"Dependency {item.get('name')!r} needs a script and artifact list")
        if not isinstance(item.get("version"), str) or not item["version"].strip():
            raise ValueError(f"Dependency {item['name']} needs a pinned version or commit")
        if item["script"].upper() == "GENERIC" and not isinstance(item.get("recipe"), dict):
            raise ValueError(f"Dependency {item['name']} needs an object-valued generic recipe")
        script = item["script"]
        if script.upper() != "GENERIC" and (Path(script).name != script or not script.endswith(".sh")):
            raise ValueError(f"Dependency {item['name']} has an invalid build script path")
        if item.get("linkage") not in {"static", "shared", "both", "header-only"}:
            raise ValueError(f"Dependency {item['name']} needs Linkage: static, shared, both, or header-only")
        runtime_artifacts = item.get("runtimeArtifacts", [])
        if not isinstance(runtime_artifacts, list) or not all(isinstance(value, str) and value for value in runtime_artifacts):
            raise ValueError(f"Dependency {item['name']} runtimeArtifacts must be a list of paths")
        if item["linkage"] in {"shared", "both"} and not runtime_artifacts:
            raise ValueError(f"Shared dependency {item['name']} needs runtimeArtifacts for DMG staging")
        if any(Path(value).suffix and Path(value).suffix != ".dylib" for value in runtime_artifacts):
            raise ValueError(f"Dependency {item['name']} runtimeArtifacts must be .dylib files or directories")
        artifact_suffixes = {Path(str(value)).suffix for value in item["artifacts"]}
        if item["linkage"] == "static" and artifact_suffixes and ".a" not in artifact_suffixes and not any(Path(str(value)).suffix == "" for value in item["artifacts"]):
            raise ValueError(f"Static dependency {item['name']} must list its .a artifact outputs")
        if item["linkage"] == "both" and (".a" not in artifact_suffixes or not runtime_artifacts):
            raise ValueError(f"Dependency {item['name']} with Linkage 'both' must list static and runtime outputs")
        for artifact in [*item["artifacts"], *runtime_artifacts]:
            artifact = Path(str(artifact))
            if artifact.is_absolute() or ".." in artifact.parts:
                raise ValueError(f"Dependency {item['name']} has an unsafe artifact path: {artifact}")
        unknown = set(item.get("requires", [])) - known
        if unknown:
            raise ValueError(f"Dependency {item['name']} requires unknown dependencies: {', '.join(sorted(unknown))}")
    return items


def artifact_path(value: str) -> Path:
    path = Path(value)
    if path.parts and path.parts[0] in {"libs", "libraries"}:
        path = Path(*path.parts[1:])
    return (LIBRARIES_ROOT / path).resolve()


def missing_artifacts(item: dict[str, object], architectures: list[str], *, verify_identity: bool = True) -> list[str]:
    missing: list[str] = []
    saved = receipts(LIBRARIES_ROOT).get(str(item["name"]), {})
    if verify_identity and saved and saved.get("identity") != item.get("_identity", saved.get("identity")):
        missing.append("installed version or prerequisites changed; rebuild required")
    lipo = shutil.which("lipo") if architectures else None
    def verify_architectures(path: Path, label: str) -> None:
        if not lipo:
            return
        candidates = [path] if path.is_file() else sorted(path.rglob("*.a")) + sorted(path.rglob("*.dylib")) if path.is_dir() else []
        for candidate in candidates:
            if candidate.suffix in {".a", ".dylib"}:
                for architecture in architectures:
                    result = subprocess.run([lipo, "-verify_arch", architecture, str(candidate)], capture_output=True, text=True)
                    if result.returncode:
                        detail = (result.stderr or result.stdout).strip()
                        suffix = f"; {detail}" if detail else ""
                        missing.append(f"{label}: {candidate} (missing or invalid {architecture} slice{suffix})")
    for value in dict.fromkeys([*item["artifacts"], *item.get("runtimeArtifacts", [])]):
        path = artifact_path(str(value))
        if not path.exists():
            missing.append(str(value))
        else:
            if value in item.get("runtimeArtifacts", []) and path.is_dir() and not any(path.rglob("*.dylib")):
                missing.append(f"{value} (contains no runtime .dylib files)")
            verify_architectures(path, str(value))
    return missing


def artifacts_present(item: dict[str, object], architectures: list[str]) -> bool:
    return bool(item["artifacts"]) and not missing_artifacts(item, architectures)


def ordered_closure(selected: list[str], by_name: dict[str, dict[str, object]]) -> list[dict[str, object]]:
    result: list[dict[str, object]] = []
    visiting: set[str] = set()
    visited: set[str] = set()

    def visit(name: str) -> None:
        if name in visiting:
            raise ValueError(f"Dependency cycle detected at {name}")
        if name in visited:
            return
        visiting.add(name)
        item = by_name[name]
        for requirement in item.get("requires", []):
            visit(str(requirement))
        visiting.remove(name)
        visited.add(name)
        result.append(item)

    for name in selected:
        if name not in by_name:
            raise ValueError(f"Unknown dependency {name!r}. Available: {', '.join(by_name)}")
        visit(name)
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("skip", "if-missing", "always"), default="if-missing")
    parser.add_argument("--dependencies", help="Comma or space separated dependency names; defaults to the full manifest")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--check-only", action="store_true", help="Report missing outputs without implying builds are disabled")
    parser.add_argument("--manifest", type=Path, default=Path(os.environ.get("DEPENDENCY_MANIFEST_FILE", DEFAULT_MANIFEST)))
    args = parser.parse_args()

    try:
        items = load_manifest(args.manifest)
        by_name = {str(item["name"]): item for item in items}
        for item in items:
            item["_identity"] = identity(item, items)
        requested = args.dependencies or os.environ.get("DEPENDENCIES", "").strip()
        selected = requested.replace(",", " ").split() if requested else [str(item["name"]) for item in items if item.get("enabled", True)]
        ordered = ordered_closure(selected, by_name)
    except (OSError, json.JSONDecodeError, ValueError) as exc:
        print(f"Dependency configuration error: {exc}", file=sys.stderr)
        return 2

    architectures = os.environ.get("ARCHS", "").split(";")
    architectures = [arch for arch in architectures if arch]
    lock_handle = None
    try:
        if not args.dry_run:
            lock_path = SCRIPTS_ROOT / ".locks" / "shared-dependencies.lock"
            lock_path.parent.mkdir(parents=True, exist_ok=True)
            lock_handle = lock_path.open("a+", encoding="utf-8")
            try:
                fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                lock_handle.close()
                print("Another project is building shared dependencies. Wait for it to finish before retrying.", file=sys.stderr)
                return 1
            lock_handle.seek(0)
            lock_handle.truncate()
            lock_handle.write(f"pid={os.getpid()}\n")
            lock_handle.flush()

        if args.check_only:
            absent = [(str(item["name"]), missing_artifacts(item, architectures)) for item in ordered]
            absent = [(name, paths) for name, paths in absent if paths]
            if absent:
                print("Required dependency outputs are missing or have the wrong architecture:", file=sys.stderr)
                for name, paths in absent:
                    print(f"  {name}: {', '.join(paths)}", file=sys.stderr)
                return 1
            print("All required dependency outputs and architectures were verified.")
            return 0

        if args.mode == "skip":
            absent = [(str(item["name"]), missing_artifacts(item, architectures)) for item in ordered]
            absent = [(name, paths) for name, paths in absent if paths]
            if absent:
                print("Dependency builds are disabled, but required outputs are missing or have the wrong architecture:", file=sys.stderr)
                for name, paths in absent:
                    print(f"  {name}: {', '.join(paths)}", file=sys.stderr)
                return 1
            print("Dependency builds are disabled; all selected outputs were verified.")
            return 0

        for item in ordered:
            name, version = str(item["name"]), str(item.get("version", "unspecified"))
            missing = missing_artifacts(item, architectures)
            if args.mode == "if-missing" and not missing:
                print(f"✓ {name} {version}: artifacts present")
                continue
            script = SCRIPT_DIR / str(item["script"])
            generic_recipe = str(item["script"]).upper() == "GENERIC"
            if generic_recipe:
                script = SCRIPT_DIR / "dependency_recipe.py"
            if not script.is_file():
                print(f"✗ {name}: build script not found: {script}", file=sys.stderr)
                return 2
            if not args.dry_run:
                for requirement in item.get("requires", []):
                    dependency = by_name[str(requirement)]
                    if not artifacts_present(dependency, architectures):
                        print(f"✗ {name}: required dependency {requirement} is still missing artifacts", file=sys.stderr)
                        return 2
            print(f"▶ {name} {version} [{item['linkage']}]: {'would build' if args.dry_run else 'building'} ({script.name})")
            if args.dry_run:
                continue
            command = [sys.executable, str(script), "--name", name, "--version", version, "--linkage", str(item["linkage"]), "--recipe", json.dumps(item.get("recipe", {}))] if generic_recipe else ["bash", str(script)]
            previous = receipts(LIBRARIES_ROOT).get(name, {}).get("version", "")
            build_env = dict(os.environ, **version_environment(items), DEPENDENCY_PREVIOUS_VERSION=previous, DEPENDENCY_NAME=name, DEPENDENCY_VERSION=version,
                             DEPENDENCY_LINKAGE=str(item["linkage"]),
                             DEPENDENCY_RECIPE_JSON=json.dumps(item.get("recipe", {})))
            source_roots = {"flann": "flann", "qads": "qads", "kompute": "kompute", "hdilib-vulkan": "HDILibLatestVulkan"}
            if previous and previous != version and name in source_roots:
                source_root = LIBRARIES_ROOT / source_roots[name]
                if source_root.is_symlink():
                    raise ValueError(f"{name} uses an external source link. Choose a local source folder before changing its version.")
                if source_root.exists():
                    backup = LIBRARIES_ROOT / ".previous_sources" / f"{name}-{uuid.uuid4().hex[:10]}"
                    backup.parent.mkdir(parents=True, exist_ok=True)
                    shutil.move(str(source_root), str(backup))
                    print(f"Preserved previous {name} source and outputs in {backup}", flush=True)
            completed = subprocess.run(command, cwd=SCRIPTS_ROOT, env=build_env, check=False)
            if completed.returncode:
                print(f"✗ {name} failed with exit code {completed.returncode}. Retry Build dependencies to resume; verified outputs are reused.", file=sys.stderr)
                if completed.returncode in (-9, 137):
                    print("The process was killed, possibly due to memory pressure. Close other apps and retry with BUILD_JOBS=1.", file=sys.stderr)
                return completed.returncode
            missing = missing_artifacts(item, architectures, verify_identity=False)
            if missing:
                print(f"✗ {name} completed but expected artifacts are missing:", file=sys.stderr)
                for path in missing:
                    print(f"  - {path}", file=sys.stderr)
                return 1
            save_receipt(LIBRARIES_ROOT, item, items)
            print(f"✓ {name} {version}: verified")

        print("Dependency handling complete.")
        return 0

    finally:
        if lock_handle is not None:
            lock_handle.close()


if __name__ == "__main__":
    raise SystemExit(main())
