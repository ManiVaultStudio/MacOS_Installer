"""Portable JSON configuration and independent local activity persistence."""

from __future__ import annotations

import os
import tempfile
import datetime as dt
from pathlib import Path
from typing import Any


HISTORY_SHEETS = {"Runs", "Logs"}


class Cell:
    def __init__(self, sheet: Any, row: int, column: int):
        self.sheet, self.row, self.column = sheet, row, column

    @property
    def value(self) -> Any:
        rows = self.sheet.rows
        return rows[self.row - 1][self.column - 1] if self.row <= len(rows) and self.column <= len(rows[self.row - 1]) else None

    @value.setter
    def value(self, value: Any) -> None:
        while len(self.sheet.rows) < self.row:
            self.sheet.rows.append([])
        row = self.sheet.rows[self.row - 1]
        row.extend([None] * max(0, self.column - len(row)))
        row[self.column - 1] = value
        self.sheet._width = max(self.sheet._width, self.column)


class Table:
    def __init__(self, title: str, rows: list | None = None):
        self.title, self.rows = title, rows if rows is not None else []
        self._width = max((len(row) for row in self.rows), default=1)

    @property
    def max_row(self) -> int:
        return max(1, len(self.rows))

    @property
    def max_column(self) -> int:
        return self._width

    def cell(self, row: int, column: int, value: Any = None) -> Cell:
        cell = Cell(self, row, column)
        if value is not None:
            cell.value = value
        return cell

    def append(self, row: Any) -> None:
        values = list(row)
        self.rows.append(values)
        self._width = max(self._width, len(values))

    def delete_rows(self, row: int, amount: int = 1) -> None:
        del self.rows[row - 1:row - 1 + amount]

    def iter_rows(self, values_only: bool = False):
        width = self.max_column
        for index, row in enumerate(self.rows, 1):
            yield tuple(row + [None] * (width - len(row))) if values_only else tuple(self.cell(index, c) for c in range(1, width + 1))


class Database:
    def __init__(self, tables: dict):
        self.tables = {name: Table(name, rows) for name, rows in tables.items()}

    @property
    def sheetnames(self) -> list:
        return list(self.tables)

    def __getitem__(self, name: str) -> Table:
        return self.tables[name]

    def __iter__(self):
        return iter(self.tables.values())

    def create_sheet(self, name: str) -> Table:
        self.tables[name] = Table(name)
        return self.tables[name]

    def close(self) -> None:
        pass


def _tables(book: Any) -> dict:
    if isinstance(book, Database):
        return {name: table.rows for name, table in book.tables.items()}
    return {sheet.title: [list(row) for row in sheet.iter_rows(values_only=True)] for sheet in book}


def _write_json(path: Path, value: Any) -> None:
    import json
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix="." + path.name, dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, indent=2, ensure_ascii=False, default=str)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(name, path)
    finally:
        Path(name).unlink(missing_ok=True)


TABLE_FILES = {
    "Projects": "projects.json",
    "Repositories": "repositories.json",
    "Dependencies": "dependencies.json",
    "InstallerAssets": "installer_assets.json",
    "ProjectDependencies": "project_dependencies.json",
    "Settings": "local/settings.json",
    "Runs": "local/runs.json",
    "Logs": "local/logs.json",
}
EMPTY_TABLES = {
    "Settings": [["Setting", "Value", "Description"], ["Out path", "application", "Installer output"], ["In path", "installer_inbox", "Installer copies"]],
    "Runs": [["Run ID", "Profile ID", "Action", "Started UTC", "Finished UTC", "Status", "DMG path", "Summary"]],
    "Logs": [["Timestamp UTC", "Run ID", "Profile ID", "Level", "Stage", "Message"]],
}


def encode_table(rows: list) -> dict:
    columns = rows[0] if rows else []
    return {"columns": columns, "records": [{column: row[index] if index < len(row) else None for index, column in enumerate(columns)} for row in rows[1:]]}


def table_signature(rows: list) -> str:
    import hashlib
    import json
    return hashlib.sha256(json.dumps(encode_table(rows), sort_keys=True, default=str).encode()).hexdigest()


def decode_table(data: dict) -> list:
    columns = data["columns"]
    return [columns, *[[record.get(column) for column in columns] for record in data["records"]]]


def _recover(base: Path) -> None:
    """Finish a committed multi-file change after an interrupted write."""
    import json
    journal = base / ".transaction.json"
    if journal.exists():
        pending = json.loads(journal.read_text(encoding="utf-8"))
        if not set(pending).issubset((set(TABLE_FILES.values()) | {"source_pins.json"})):
            raise ValueError("Database recovery journal contains unknown files.")
        for relative, value in pending.items():
            _write_json(base / relative, value)
        journal.unlink()


def _commit(base: Path, pending: dict) -> None:
    if pending:
        _write_json(base / ".transaction.json", pending)
        _recover(base)


def _bootstrap(base: Path, legacy_workbook: Path) -> None:
    import json
    if all((base / relative).exists() for relative in TABLE_FILES.values()) and (base / "source_pins.json").exists():
        return
    legacy_config = base / "configuration.json"
    legacy_history = base / "history/activity.json"
    old = json.loads(legacy_config.read_text(encoding="utf-8")) if legacy_config.exists() else {}
    if legacy_history.exists():
        old.update(json.loads(legacy_history.read_text(encoding="utf-8")))
    if not (base / TABLE_FILES["Projects"]).exists() and not old:
        from openpyxl import load_workbook
        legacy = load_workbook(legacy_workbook, data_only=True)
        try:
            ensure_log_schema(legacy)
            old = _tables(legacy)
        finally:
            legacy.close()
    pending = {}
    if not (base / "source_pins.json").exists():
        old_pins = base.parent / "scripts/dependencies/fetchcontent_overrides.json"
        pending["source_pins.json"] = json.loads(old_pins.read_text(encoding="utf-8")) if old_pins.exists() else {"dependencies": []}
    for name, relative in TABLE_FILES.items():
        if (base / relative).exists():
            continue
        template = base / "defaults" / Path(relative).name
        if name in old:
            value = encode_table(old[name])
        elif template.exists():
            value = json.loads(template.read_text(encoding="utf-8"))
        elif name in EMPTY_TABLES:
            value = encode_table(EMPTY_TABLES[name])
        elif name == "ProjectDependencies":
            def existing_table(table_name: str) -> list:
                path = base / TABLE_FILES[table_name]
                return decode_table(json.loads(path.read_text(encoding="utf-8"))) if path.exists() else old.get(table_name, [])
            project_rows, dependency_rows = existing_table("Projects"), existing_table("Dependencies")
            projects = [dict(zip(project_rows[0], row)) for row in project_rows[1:]] if project_rows else []
            dependencies = [dict(zip(dependency_rows[0], row)) for row in dependency_rows[1:]] if dependency_rows else []
            rows = [["Profile ID", "Dependency", "Kind", "Version", "Required"]]
            for project in projects:
                for dependency in dependencies:
                    if str(dependency.get("Enabled")).lower() in {"true", "yes", "1"}:
                        rows.append([project["Profile ID"], dependency["Name"], "recipe", dependency["Version / commit"], True])
            value = encode_table(rows)
        else:
            raise ValueError(f"Database file missing: {relative}. Restore it from the repository.")
        pending[relative] = value
    _commit(base, pending)


def load_database(destination: Path, **options: Any) -> Any:
    """Read separate portable data files, importing older stores once if needed."""
    import copy
    import json
    import fcntl
    destination = Path(destination)
    base = destination.parent
    base.mkdir(parents=True, exist_ok=True)
    with (base / ".database.lock").open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        _recover(base)
        _bootstrap(base, destination)
        source_snapshot = json.loads((base / "source_pins.json").read_text(encoding="utf-8"))
        tables = {
            name: decode_table(json.loads((base / relative).read_text(encoding="utf-8")))
            for name, relative in TABLE_FILES.items()
            if (options.get("include_history", True) or name not in HISTORY_SHEETS) and (not options.get("tables") or name in options["tables"])
        }
    book = Database(tables)
    book._source_snapshot = source_snapshot
    book._database_snapshot = {} if options.get("read_only") else {name: table_signature(rows) for name, rows in _tables(book).items()}
    return book


def atomic_save_workbook(workbook: Any, destination: Path) -> None:
    """Commit changed tables together and reject edits to stale data."""
    import copy
    import json
    import fcntl
    base = Path(destination).parent
    tables = _tables(workbook)
    before = getattr(workbook, "_database_snapshot", {})
    with (base / ".database.lock").open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        _recover(base)
        pending = {}
        for name, rows in tables.items():
            if table_signature(rows) == before.get(name):
                continue
            relative = TABLE_FILES[name]
            path = base / relative
            current = decode_table(json.loads(path.read_text(encoding="utf-8"))) if path.exists() else None
            if name in before and (current is None or table_signature(current) != before[name]):
                raise ValueError("Data changed in another process. Refresh and retry your changes.")
            pending[relative] = encode_table(rows)
        if hasattr(workbook, "_pending_source_pins"):
            current_pins = json.loads((base / "source_pins.json").read_text(encoding="utf-8"))
            if current_pins != workbook._source_snapshot:
                raise ValueError("Source pins changed in another process. Refresh and retry.")
            pending["source_pins.json"] = workbook._pending_source_pins
        _commit(base, pending)
    if hasattr(workbook, "_pending_source_pins"):
        workbook._source_snapshot = copy.deepcopy(workbook._pending_source_pins)
        del workbook._pending_source_pins
    workbook._database_snapshot = {name: table_signature(rows) for name, rows in tables.items()}


def save_source_pins(workbook: Any, destination: Path, manifest: dict) -> None:
    workbook._pending_source_pins = manifest
    atomic_save_workbook(workbook, destination)


def ensure_log_schema(workbook: Any) -> bool:
    """Add the timestamp column and repair rows written against the old headers."""
    sheet = workbook["Logs"]
    headers = [str(sheet.cell(1, col).value or "").strip() for col in range(1, sheet.max_column + 1)]
    if "Timestamp UTC" in headers:
        return False

    run_sheet = workbook["Runs"]
    run_headers = {str(run_sheet.cell(1, col).value or "").strip(): col for col in range(1, run_sheet.max_column + 1)}
    run_col = run_headers.get("Run ID")
    known_run_ids = {
        str(run_sheet.cell(row, run_col).value).strip()
        for row in range(2, run_sheet.max_row + 1)
        if run_col and run_sheet.cell(row, run_col).value
    }

    # Existing rows were written as [timestamp, run ID, profile, level, stage, message]
    # even though the original sheet only had five headers. Keep those rows in place;
    # shift legacy five-field rows one column right to fit the corrected layout.
    data_width = sheet.max_column
    for row in range(2, sheet.max_row + 1):
        values = [sheet.cell(row, col).value for col in range(1, data_width + 1)]
        if len(values) > 1 and str(values[1] or "").strip() in known_run_ids:
            continue
        for col in range(data_width, 0, -1):
            sheet.cell(row, col + 1).value = sheet.cell(row, col).value
        sheet.cell(row, 1).value = None

    for col, header in enumerate(headers, start=2):
        sheet.cell(1, col).value = header
    sheet.cell(1, 1).value = "Timestamp UTC"
    return True


def append_log_row(sheet: Any, run_id: str, profile: str, level: str, stage: str, message: str) -> None:
    headers = [str(sheet.cell(1, col).value or "").strip() for col in range(1, sheet.max_column + 1)]
    values = {
        "Timestamp UTC": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        "Run ID": run_id,
        "Profile ID": profile,
        "Level": level,
        "Stage": stage,
        "Message": message[:32000],
    }
    sheet.append([values.get(header, "") for header in headers])
