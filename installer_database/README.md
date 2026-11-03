# Installer databases

Shared configuration has one file per concern: `projects.json`, `repositories.json`, `dependencies.json`, `source_pins.json`, `project_dependencies.json`, and `installer_assets.json`.

`defaults/runs.json` and `defaults/logs.json` are deliberately empty and belong in Git, alongside `defaults/settings.json`. The app copies these into `local/` for each machine. Only the copies change as operations run. All of `local/` is ignored, including full run-output files.

The workbook is legacy input only. The app never writes it. Workbook Git filters and hook scripts are no longer needed and have been removed.

The UI and build engine share the same configuration. Multi-file writes use `.transaction.json` for crash recovery and `.database.lock` for synchronization; both are local and ignored.
