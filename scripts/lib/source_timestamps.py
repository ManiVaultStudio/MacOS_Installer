#!/usr/bin/env python3
"""Keep unchanged patched source timestamps stable across incremental builds."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
import time
from pathlib import Path


def files(root: Path):
    if not root.exists(): return
    for directory, names, filenames in os.walk(root):
        names[:] = [name for name in names if name != '.git']
        for name in filenames:
            path = Path(directory) / name
            if path.is_file() and not path.is_symlink(): yield path


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(262144), b''): h.update(chunk)
    return h.hexdigest()


def metadata(path: Path):
    stat = path.stat()
    return [stat.st_mtime_ns, stat.st_size, stat.st_ctime_ns]


def cached_fingerprints(state: Path):
    try: return json.loads(state.with_suffix('.cache.json').read_text())
    except (OSError, ValueError): return {}


def begin(root: Path, state: Path):
    cache = cached_fingerprints(state)
    snapshot = {}
    for path in files(root):
        key = str(path.relative_to(root))
        info = metadata(path)
        previous = cache.get(key)
        checksum = previous[0] if previous and previous[1:] == info else digest(path)
        if previous and checksum != previous[0] and info[0] <= previous[1]:
            stat = path.stat()
            os.utime(path, ns=(stat.st_atime_ns, max(time.time_ns(), previous[1]+1)))
            info = metadata(path)
        snapshot[key] = [checksum, *info]
    state.parent.mkdir(parents=True, exist_ok=True)
    state.write_text(json.dumps(snapshot))


def finish(root: Path, state: Path):
    snapshot = json.loads(state.read_text()) if state.exists() else {}
    cache = {}
    preserved = 0
    for path in files(root):
        key = str(path.relative_to(root))
        previous = snapshot.get(key)
        info = metadata(path)
        checksum = previous[0] if previous and previous[1:] == info else digest(path)
        if previous is not None:
            stat = path.stat()
            if checksum == previous[0]:
                if stat.st_mtime_ns != previous[1]:
                    os.utime(path, ns=(stat.st_atime_ns, previous[1]))
                preserved += 1
            elif stat.st_mtime_ns <= previous[1]:
                os.utime(path, ns=(stat.st_atime_ns, max(time.time_ns(), previous[1]+1)))
        cache[key] = [checksum, *metadata(path)]
    state.with_suffix('.cache.json').write_text(json.dumps(cache))
    state.unlink(missing_ok=True)
    print(f'Incremental source preparation: {preserved} unchanged files kept stable.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('begin','finish'))
    parser.add_argument('root', type=Path)
    parser.add_argument('state', type=Path)
    args = parser.parse_args()
    (begin if args.operation == 'begin' else finish)(args.root,args.state)
