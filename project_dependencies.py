"""Project requirements and derived readiness; status is never stored as a stale flag."""
from __future__ import annotations


def truth(value):
    return str(value).lower() in {'true', '1', 'yes', 'on'}


def evaluate(projects: list[dict], requirements: list[dict], catalog: list[dict]) -> list[dict]:
    installed = {(item['kind'], item['name']): item for item in catalog}
    result = []
    for project in projects:
        missing = []
        profile = str(project['Profile ID'])
        for row in requirements:
            if str(row.get('Profile ID')) != profile or not truth(row.get('Required')):
                continue
            item = installed.get((row.get('Kind', 'recipe'), row.get('Dependency')))
            expected = str(row.get('Version') or '')
            reason = 'Not registered' if item is None else 'Version mismatch' if expected != item['version'] else 'Not installed' if not item['installed'] else ''
            if reason:
                missing.append({'name': row['Dependency'], 'kind': row.get('Kind', 'recipe'), 'version': expected, 'reason': reason})
        result.append({**project, 'Dependency status': 'missing' if missing else 'ready', 'Missing dependencies': missing})
    return result


def update_requirements(book, name: str, kind: str, version: str, *, profiles: list[str] | None = None, update_versions: bool = False):
    sheet = book['ProjectDependencies']
    rows = list(sheet.iter_rows(values_only=True))
    columns = rows[0]
    values = [dict(zip(columns, row)) for row in rows[1:]]
    if profiles is not None:
        previous_versions = {str(row['Profile ID']): row.get('Version') for row in values if row.get('Dependency') == name and row.get('Kind') == kind}
        values = [row for row in values if not (row.get('Dependency') == name and row.get('Kind') == kind)]
        values.extend({'Profile ID': profile, 'Dependency': name, 'Kind': kind, 'Version': version if update_versions else previous_versions.get(profile, version), 'Required': True} for profile in profiles)
    elif update_versions:
        for row in values:
            if row.get('Dependency') == name and row.get('Kind') == kind:
                row['Version'] = version
    sheet.delete_rows(2, sheet.max_row)
    for row in values:
        sheet.append([row.get(column) for column in columns])
