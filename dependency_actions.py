"""Dependency lifecycle operations with recoverable local uninstalls."""
from __future__ import annotations

import datetime as dt
import json
import shutil
import uuid
from pathlib import Path
from typing import Any


def output_paths(root: Path, entry: dict[str, Any]) -> list[Path]:
    paths = []
    libraries = (root / 'libraries').resolve()
    for value in [*entry.get('artifacts', []), *entry.get('runtimeArtifacts', [])]:
        path = Path(str(value))
        if path.is_absolute() or '..' in path.parts:
            raise ValueError('Dependency output paths must be relative to libraries.')
        if path.parts and path.parts[0] in {'libraries', 'libs'}:
            path = Path(*path.parts[1:])
        path = (libraries / path).resolve()
        if not path.is_relative_to(libraries) or path == libraries:
            raise ValueError('Dependency outputs must remain inside their own library folder.')
        if path not in paths:
            paths.append(path)
    return paths


def uninstall(root: Path, name: str, kind: str, entries: list[dict], pins: list[dict]) -> Path:
    """Move installed outputs to local recovery storage; leave registration intact."""
    if kind == 'recipe':
        entry = next((item for item in entries if item['name'] == name), None)
        if entry is None:
            raise ValueError('Library is no longer registered.')
        users = [item['name'] for item in entries if name in item.get('requires', [])
                 and any(path.exists() for path in output_paths(root, item))]
        if users:
            raise ValueError('Uninstall these dependent libraries first: ' + ', '.join(users))
        targets = output_paths(root, entry)
    elif kind == 'pin':
        entry = next((item for item in pins if item['name'] == name), None)
        if entry is None:
            raise ValueError('Source is no longer registered.')
        targets = output_paths(root, {'artifacts': [entry['source']]})
    else:
        raise ValueError('Choose a registered library or source.')
    # Reject shared output ownership rather than silently breaking another library.
    protected = []
    for other in entries:
        if kind != 'recipe' or other['name'] != name:
            protected.extend(output_paths(root, other))
    for other in pins:
        if kind != 'pin' or other['name'] != name:
            protected.extend(output_paths(root, {'artifacts': [other['source']]}))
    for target in targets:
        if any(target == path or target.is_relative_to(path) or path.is_relative_to(target) for path in protected):
            raise ValueError('This output is shared by another dependency and cannot be uninstalled separately.')
    targets = [path for path in targets if path.exists()]
    targets = [path for path in targets if not any(path != parent and path.is_relative_to(parent) for parent in targets)]
    if not targets:
        raise ValueError('This dependency is already uninstalled.')
    backup = root / '.installer_runtime' / 'uninstalled' / (dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%S') + '-' + uuid.uuid4().hex[:8])
    backup.mkdir(parents=True)
    moves = []
    try:
        for index, target in enumerate(targets):
            saved = backup / str(index)
            shutil.move(str(target), str(saved))
            moves.append({'original': str(target), 'saved': str(saved)})
        (backup / 'restore.json').write_text(json.dumps({'name': name, 'kind': kind, 'files': moves}, indent=2) + '\n')
    except Exception:
        for move in reversed(moves):
            shutil.move(move['saved'], move['original'])
        raise
    print(f'Uninstalled {name}. Registration and source recipes are kept. Recovery files: {backup}', flush=True)
    return backup
