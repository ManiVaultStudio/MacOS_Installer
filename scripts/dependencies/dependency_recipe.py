#!/usr/bin/env python3
"""Build a pinned dependency using a small, reusable recipe."""
from __future__ import annotations

import argparse
import json
import os
import shlex
import subprocess
import sys
import tarfile
import urllib.request
import zipfile
from pathlib import Path
from cmake_config import configure_command


def run(argv: list[str], cwd: Path | None = None, env: dict[str, str] | None = None) -> None:
    print("$ " + shlex.join(argv), flush=True)
    subprocess.run(argv, cwd=cwd, env=env, check=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--name", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--linkage", choices=("static", "shared", "both", "header-only"), required=True)
    parser.add_argument("--recipe", required=True)
    args = parser.parse_args()
    recipe = json.loads(args.recipe)
    root = Path(os.environ.get("LIBRARIES_ROOT", Path(__file__).resolve().parents[2] / "libraries")).resolve()
    source_base = Path(recipe.get("sourceRoot", root / "sources")).expanduser().resolve()
    build_base = Path(recipe.get("buildRoot", root / args.name / "build")).expanduser().resolve()
    prefix = Path(recipe.get("prefix", root / args.name / "install")).expanduser().resolve()
    source_base.mkdir(parents=True, exist_ok=True)
    build_base.mkdir(parents=True, exist_ok=True)
    source = source_base / args.name
    source_info = recipe.get("source", {})
    kind = source_info.get("type", "git")
    ref = str(source_info.get("ref", args.version))
    if kind == "git":
        url = source_info.get("url")
        if not url:
            raise ValueError("Git recipe source.url is required")
        if (source / ".git").is_dir():
            dirty = subprocess.run(["git", "status", "--porcelain"], cwd=source, capture_output=True, text=True, check=True).stdout
            if dirty:
                raise RuntimeError(f"Refusing to update dirty dependency checkout: {source}")
            run(["git", "fetch", "--tags", "origin"], source)
            run(["git", "checkout", "--detach", ref], source)
            run(["git", "reset", "--hard", ref], source)
        elif source.exists():
            raise RuntimeError(f"Source path exists but is not a Git checkout: {source}")
        else:
            run(["git", "clone", "--no-checkout", str(url), str(source)])
            run(["git", "checkout", "--detach", ref], source)
    elif kind == "archive":
        url = source_info.get("url")
        digest = source_info.get("sha256")
        if not url or not digest:
            raise ValueError("Archive recipes require source.url and source.sha256")
        archive = source_base / f"{args.name}-{args.version}.archive"
        if not archive.exists():
            urllib.request.urlretrieve(url, archive)
        import hashlib
        checksum = hashlib.sha256()
        with archive.open("rb") as source_file:
            for chunk in iter(lambda: source_file.read(1024 * 1024), b""):
                checksum.update(chunk)
        if checksum.hexdigest().lower() != str(digest).lower():
            raise RuntimeError(f"SHA-256 check failed for {archive}")
        extracted = source_base / f"{args.name}-{args.version}"
        extracted.mkdir(exist_ok=True)
        if zipfile.is_zipfile(archive):
            with zipfile.ZipFile(archive) as item:
                for member in item.infolist():
                    target = (extracted / member.filename).resolve()
                    if extracted not in target.parents and target != extracted:
                        raise RuntimeError("Archive contains an unsafe path")
                item.extractall(extracted)
        else:
            with tarfile.open(archive) as item:
                for member in item.getmembers():
                    target = (extracted / member.name).resolve()
                    if extracted not in target.parents and target != extracted:
                        raise RuntimeError("Archive contains an unsafe path")
                    if member.issym() or member.islnk() or not (member.isfile() or member.isdir()):
                        raise RuntimeError("Archive contains a link or special file")
                item.extractall(extracted)
        source = extracted
    else:
        raise ValueError(f"Unsupported source type: {kind}")

    subdirectory = recipe.get("sourceDirectory", "")
    if subdirectory:
        source = (source / subdirectory).resolve()
        if source_base not in source.parents and source != source_base:
            raise ValueError("Recipe source directory escapes the source root")
    if not source.is_dir():
        raise RuntimeError(f"Recipe source directory is missing: {source}")
    system = recipe.get("buildSystem", "cmake")
    env = os.environ.copy()
    env.update({str(k): str(v) for k, v in recipe.get("environment", {}).items()})
    if args.linkage == "header-only" and system != "headers":
        raise ValueError("Header-only recipes must use buildSystem 'headers' with includeDirectories")
    if args.linkage != "header-only" and system == "headers":
        raise ValueError("buildSystem 'headers' is only valid for header-only dependencies")
    env["BUILD_SHARED_LIBS"] = "ON" if args.linkage == "shared" else "OFF"
    archs = [x for x in env.get("ARCHS", "arm64;x86_64").split(";") if x]
    minimum = env.get("MIN_MACOS_VERSION", "12.0")
    prefix.mkdir(parents=True, exist_ok=True)
    if system == "cmake":
        options = [str(v) for v in recipe.get("cmakeArgs", [])]
        variants = ("static", "shared") if args.linkage == "both" else (() if args.linkage == "header-only" else (args.linkage,))
        for variant in variants:
            variant_prefix = prefix / variant if args.linkage == "both" else prefix
            build = build_base / variant if args.linkage == "both" else build_base / "build"
            build.mkdir(parents=True, exist_ok=True)
            shared = "ON" if variant == "shared" else "OFF"
            run(configure_command(str(source), str(build), str(variant_prefix), archs, minimum,
                                  [*options, f"-DBUILD_SHARED_LIBS={shared}"], env), source, env)
            run(["cmake", "--build", str(build), "--parallel", env.get("BUILD_JOBS", "4")], source, env)
            run(["cmake", "--install", str(build)], source, env)
    elif system in {"make", "autotools"}:
        if args.linkage == "both":
            raise ValueError("Linkage 'both' requires CMake or explicit command steps so builds cannot overwrite each other")
        configure = [*map(str, recipe.get("configureArgs", []))]
        configure += ["--enable-shared", "--disable-static"] if args.linkage == "shared" else ["--disable-shared", "--enable-static"]
        if system == "autotools":
            run(["./configure", f"--prefix={prefix}", *map(str, configure)], source, env)
        run(["make", "-j", env.get("BUILD_JOBS", "4"), *map(str, recipe.get("makeArgs", []))], source, env)
        run(["make", "install"], source, env)
    elif system == "commands":
        for step in recipe.get("steps", []):
            directory = (source / step.get("directory", ".")).resolve()
            if source not in directory.parents and directory != source:
                raise ValueError("Recipe command directory escapes its source")
            if not isinstance(step.get("argv"), list) or not all(isinstance(part, str) for part in step["argv"]):
                raise ValueError("Each recipe step needs an argv list of strings")
            run([part.replace("{prefix}", str(prefix)).replace("{source}", str(source)) for part in step["argv"]], directory, env)
    elif system == "headers" and args.linkage == "header-only":
        import shutil
        include_dirs = recipe.get("includeDirectories", ["include"])
        for include_dir in include_dirs:
            source_dir = (source / include_dir).resolve()
            if source not in source_dir.parents or not source_dir.is_dir():
                raise ValueError(f"Header directory is missing or outside source: {include_dir}")
            relative = Path(include_dir)
            target = prefix / relative if relative.parts and relative.parts[0] == "include" else prefix / "include" / source_dir.name
            shutil.copytree(source_dir, target, dirs_exist_ok=True)
    else:
        raise ValueError(f"Unsupported build system: {system}")
    print(f"Installed {args.name} {args.version} to {prefix}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError, json.JSONDecodeError) as exc:
        print(f"Dependency recipe failed: {exc}", file=sys.stderr)
        raise SystemExit(getattr(exc, "returncode", 1) or 1)
