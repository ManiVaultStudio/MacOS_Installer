"""Confirmed removal with rollback until the database change commits."""
from __future__ import annotations
import shutil
import uuid
from pathlib import Path


def compact_paths(paths: list[Path]) -> list[Path]:
    unique = list(dict.fromkeys(paths))
    return [path for path in unique if not any(path != parent and path.is_relative_to(parent) for parent in unique)]


def stage(root: Path, paths: list[Path]) -> list[tuple[Path, Path]]:
    directory = root / '.installer_runtime/deleting' / uuid.uuid4().hex
    moves = []
    try:
        for path in compact_paths(paths):
            if not path.exists() and not path.is_symlink(): continue
            directory.mkdir(parents=True,exist_ok=True)
            saved = directory / str(len(moves))
            shutil.move(str(path),str(saved))
            moves.append((path,saved))
    except Exception:
        restore(moves)
        raise
    return moves


def restore(moves):
    for original,saved in reversed(moves):
        original.parent.mkdir(parents=True,exist_ok=True)
        shutil.move(str(saved),str(original))


def purge(moves):
    for _,saved in moves:
        if saved.is_dir() and not saved.is_symlink(): shutil.rmtree(saved)
        else: saved.unlink(missing_ok=True)
    if moves:
        directory=moves[0][1].parent
        directory.rmdir()
