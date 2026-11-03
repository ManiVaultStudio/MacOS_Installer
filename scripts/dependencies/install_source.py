#!/usr/bin/env python3
"""Install a registered source pin without changing its saved configuration."""
from __future__ import annotations
import argparse
import fcntl
import json
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def install_source(name: str, root: Path = ROOT) -> Path:
    manifest_path = root / 'installer_database/source_pins.json'
    entry = next((item for item in json.loads(manifest_path.read_text())['dependencies'] if item['name'] == name), None)
    if entry is None:
        raise ValueError('Source is no longer registered.')
    libraries = (root / 'libraries').resolve()
    source = (libraries / entry['source']).resolve()
    if source == libraries or not source.is_relative_to(libraries):
        raise ValueError('Source folder must remain inside libraries.')
    version = str(entry.get('version') or entry.get('git_tag') or '')
    marker = source / str(entry.get('version_file') or '.installer-version')
    if source.is_dir():
        if marker.is_file() and marker.read_text().strip() == version:
            print(f'{name} {version} is already installed.')
            return source
        check = subprocess.run(['git', '-C', str(source), 'rev-parse', 'HEAD'], capture_output=True, text=True)
        expected = subprocess.run(['git', '-C', str(source), 'rev-parse', '--verify', f'{version}^{{commit}}'], capture_output=True, text=True)
        if check.returncode == expected.returncode == 0 and check.stdout.strip() == expected.stdout.strip():
            if entry.get('version_file'):
                marker.write_text(version + '\n')
            return source
        raise ValueError('The cache folder contains another version. Change version to use a new cache folder.')
    url = str(entry.get('sourceUrl') or '')
    if not re.fullmatch(r'https://(?:github|gitlab)\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:\.git)?', url):
        raise ValueError('Set this source’s repository URL before installing.')
    libraries.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix='.source-install-', dir=libraries))
    try:
        checkout = temporary / 'checkout'
        subprocess.run(['git', 'clone', '--no-checkout', url, str(checkout)], check=True)
        subprocess.run(['git', '-C', str(checkout), 'fetch', 'origin', version], check=True)
        subprocess.run(['git', '-C', str(checkout), 'checkout', '--detach', 'FETCH_HEAD'], check=True)
        subprocess.run(['git', '-C', str(checkout), 'submodule', 'update', '--init', '--recursive'], check=True)
        if entry.get('version_file'):
            (checkout / str(entry['version_file'])).write_text(version + '\n')
        source.parent.mkdir(parents=True, exist_ok=True)
        checkout.rename(source)
    finally:
        shutil.rmtree(temporary, ignore_errors=True)
    print(f'Installed {name} {version}.', flush=True)
    return source


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('name')
    args = parser.parse_args()
    lock_path = ROOT / 'scripts/.locks/shared-dependencies.lock'
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open('a+') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            install_source(args.name)
        except (OSError, ValueError, subprocess.CalledProcessError) as exc:
            parser.exit(1, f'Source installation failed: {exc}\n')
