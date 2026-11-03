"""Derive build versions and installation identity from the dependency catalog."""
from __future__ import annotations
import hashlib
import json
import re
from pathlib import Path

VERSION_VARIABLES = {'openmp': 'OPENMP_VERSION', 'lz4': 'LZ4_VERSION', 'flann': 'FLANN_VERSION',
                     'cups': 'CUPS_VERSION', 'qads': 'QADS_TAG', 'fmt': 'FMT_VERSION',
                     'glfw': 'GLFW_VERSION', 'libpng': 'LIBPNG_VERSION', 'imagemagick': 'IMAGEMAGICK_VERSION'}


def version_environment(entries: list[dict]) -> dict[str, str]:
    values = {}
    for entry in entries:
        name, version = str(entry['name']), str(entry['version'])
        pin = version.split()[0]
        if name in VERSION_VARIABLES:
            if not re.fullmatch(r"v?\d+\.\d+(?:\.\d+)*(?:[-+][A-Za-z0-9.-]+)?", pin):
                raise ValueError(f"{name} uses a release version, such as 1.2.3. Use a release tag rather than a branch.")
            values[VERSION_VARIABLES[name]] = pin.removeprefix('v')
        if name in {'flann', 'glfw'}:
            match = re.search(r'\(([a-fA-F0-9]{40})\)', version)
            values[name.upper() + '_COMMIT'] = match.group(1) if match else ''
        if name == 'kompute':
            values['KOMPUTE_REF'] = pin
        if name == 'hdilib-vulkan':
            values['HDILIB_REF'] = 'v' + pin if pin[0].isdigit() else pin
        if name == 'hdf5-zlib':
            match = re.fullmatch(r'HDF5\s+(\S+)\s*/\s*zlib\s+(\S+)', version)
            if not match:
                raise ValueError('Use “HDF5 <version> / zlib <version>” for the combined library.')
            values['HDF5_VERSION'], values['ZLIB_VERSION'] = match.groups()
    return values


def identity(entry: dict, entries: list[dict], seen: set | None = None) -> str:
    seen = set() if seen is None else seen
    name = str(entry['name'])
    if name in seen:
        raise ValueError('Dependency prerequisite cycle: ' + name)
    seen = seen | {name}
    by_name = {item['name']: item for item in entries}
    value = {key: entry.get(key) for key in ('name', 'version', 'script', 'linkage', 'recipe', 'artifacts', 'runtimeArtifacts')}
    value['requires'] = {name: identity(by_name[name], entries, seen) for name in entry.get('requires', [])}
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def receipts(libraries: Path) -> dict:
    path = libraries / '.installed-versions.json'
    return json.loads(path.read_text()) if path.exists() else {}


def save_receipt(libraries: Path, entry: dict, entries: list[dict]) -> None:
    from database_io import _write_json
    data = receipts(libraries)
    data[entry['name']] = {'version': entry['version'], 'identity': identity(entry, entries)}
    _write_json(libraries / '.installed-versions.json', data)


def entries_from_rows(rows: list[dict]) -> list[dict]:
    entries = []
    for row in rows:
        if not row.get('Name'):
            continue
        entry = {'name': str(row['Name']), 'version': str(row.get('Version / commit') or ''),
                 'script': str(row.get('Build Script') or 'GENERIC'), 'linkage': str(row.get('Linkage') or 'static')}
        for key, column, fallback in [('artifacts', 'Artifacts JSON', '[]'), ('runtimeArtifacts', 'Runtime Files JSON', '[]'),
                                      ('requires', 'Requires JSON', '[]'), ('recipe', 'Recipe JSON', '{}')]:
            entry[key] = json.loads(str(row.get(column) or fallback))
        entries.append(entry)
    return entries


def manifest_data(path: Path) -> dict:
    data = json.loads(path.read_text(encoding='utf-8'))
    if 'columns' in data and 'records' in data:
        entries = entries_from_rows(data['records'])
        for entry, row in zip(entries, [row for row in data['records'] if row.get('Name')]):
            entry['enabled'] = str(row.get('Enabled')).lower() in {'true','yes','1','on'}
        return {'schemaVersion': 1, 'dependencies': entries}
    return data


def enabled_closure(entries: list[dict]) -> list[dict]:
    by_name = {entry['name']:entry for entry in entries}
    visited, visiting, selected = set(), set(), []
    def visit(name):
        if name in visiting:
            raise ValueError('Dependency prerequisite cycle: ' + name)
        if name in visited: return
        if name not in by_name: raise ValueError('Unknown required dependency: ' + name)
        visiting.add(name)
        for requirement in by_name[name].get('requires', []): visit(requirement)
        visiting.remove(name); visited.add(name); selected.append(by_name[name])
    for entry in entries:
        if entry.get('enabled', True): visit(entry['name'])
    return selected
