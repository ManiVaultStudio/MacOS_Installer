# Project profiles

Every `.env` file in this folder is an installer build profile. The desktop app
syncs this folder into its project list when it starts and whenever the
dashboard refreshes. Add a valid profile file and it becomes selectable; remove
the file and its project, repository pins, and installer asset registration are
removed from the active list. Saved run history is retained. Use **Duplicate
profile** to scaffold a variant, then review it before building.

Each profile needs a unique `PROFILE_NAME`, `APP_VERSION`, and `CORE_BRANCH`.
Keep the version semantic (for example `1.5.1`). Repository groups are read from
`DATAPLUGIN_REPOS` and `PLUGIN_REPOS` when present. Copy an existing profile as
a starting point so architecture, minimum macOS version, toolkit versions, and
installer material paths are explicit. Refresh the dashboard after adding or
removing a file while it is open.

```sh
./scripts/entrypoints/build_project.sh manivault-installer
./scripts/entrypoints/create_installer.sh manivault-installer
DRY_RUN=true ./scripts/entrypoints/build_project.sh manivault-installer --skip-update --skip-clean
```

Profiles define the product version, core ref, build architectures, and
repository groups. Keep importer repositories in `DATAPLUGIN_REPOS`; put other
plugins in `PLUGIN_REPOS`. Both values are JSON objects with a shared
`defaultBranch` and optional per-repository `branchOverrides`. Pin a release to
a branch or tag. A missing pin is an error; the updater will not silently
switch to a repository's default branch.

`APP_VERSION` uses semantic versioning. The package step stamps it into the app
bundle and the DMG filename. `MIN_CORE_VERSION_MAJOR/MINOR/PATCH/SUFFIX` is the
minimum compatible core version and is separate from the app's release version.

Dependency builds are managed by
`installer_database/dependencies.json`.
Profiles may set `DEPENDENCIES` to select a smaller set; prerequisite entries
are included automatically. See the repository's
[project and release guide](../../PROJECTS_AND_DEPENDENCIES.md) for adding
profiles, repositories, and native dependencies.
