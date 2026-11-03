# Projects, repositories, dependencies, and releases

Project, repository, library, source-pin, project-requirement and installer-asset data have separate JSON files under `installer_database/`. Machine settings and history live under ignored `installer_database/local/`. Excel is not required.

## Add a project

1. In **Build workflow**, use **Add → Project**. Name it, choose a working template and set its version. Its ID, materials, repositories and dependency requirements are copied automatically.
2. Select it as the build target. **Project & plug-ins** edits that target's settings and pins.
3. Use **Add → Plug-in**, **Version**, or **Remove** for repositories. Core cannot be removed.
4. Use **Create installer** in the header for the release workflow. Preview and incremental options live in the build rail.

## Shared dependencies

**Dependencies** is global. Use **Add** to register a library or source, then **Install**. Project usage and version-update policy live in its settings/version form. Missing or mismatched requirements appear in the affected project's readiness status. Uninstall preserves recovery files; removing a catalog entry preserves project requirements so a re-added matching dependency can satisfy them again.

## Add or pin repositories

Repository names are GitHub repositories under `BASE_URL` (default:
`https://github.com/ManiVaultStudio`). Each configured repository is cloned if
missing and updated to the selected branch during a normal build. For example:

```bash
DATAPLUGIN_REPOS='{"defaultBranch":"release/2.0","repos":["CellData","SpatialData"]}'
PLUGIN_REPOS='{"defaultBranch":"release/2.0","repos":["Scatterplot"],"branchOverrides":{"Scatterplot":"release/2.0.1"}}'
```

`--skip-update` clones missing repositories but leaves existing checkouts alone.
Normal updates refuse to reset any checkout with local changes or untracked
files. Commit or stash those files before updating. The opt-in
`ALLOW_DIRTY_REPO_RESET=true` permits tracked changes to be reset and should be
used only when those local changes are disposable. Untracked files are retained.

## Add a build dependency

The seed dependency catalog is in `Dependencies` in JSON configuration. Each entry
records a version/commit, enabled state, linkage (`static`, `shared`, `both`, or
`header-only`), build outputs, runtime files, prerequisites, and either a
specialized script or a reusable `GENERIC` recipe. The manager builds
dependencies in prerequisite order, checks expected outputs and architectures,
and stages declared dynamic libraries into the DMG. Static libraries are used
at link time and are not copied as runtime files. Direct scripts read the same catalog by default.

To add one:

1. Use **Dependencies → Add → Build library** to register a library. Provide a stable name, version
   or commit, outputs, prerequisite names, and set `Enabled` to true.
2. Choose the linkage type. List static/shared build outputs under `Artifacts JSON`;
   for `shared` or `both`, list the runtime `.dylib` paths (or a folder
   containing them) in `Runtime Files JSON`. Those declared dynamic libraries
   are architecture-checked and staged for packaging automatically.
3. For ordinary dependencies, choose `GENERIC` and provide recipe JSON with a
   pinned Git source or URL plus SHA-256 checked archive, build system, and
   build arguments. The common builder supports CMake, Make, Autotools,
   header-only copies, or explicit argv steps. CMake recipes use separate
   build/install locations for `both` linkage. Never place shell command
   strings in recipes.
4. For a dependency with a special patch or project-specific process, add a
   dedicated script under `scripts/dependencies/` and enter its filename.
   Build outputs and the version pin must match the project build stage.
5. Preview through the app, then use **Build dependencies** and confirm the
   expected outputs before ordinary `if-missing` use.

   ```sh
   python3 scripts/dependencies/dependency_manager.py --dry-run
   ./scripts/entrypoints/install_dependencies.sh <profile>
   ```

`DEPENDENCY_BUILD_MODE` supports `if-missing`, `always`, and `skip`. Use
`if-missing` for ordinary development. `always` rebuilds pinned dependencies.
`skip` performs no builds and fails early unless every selected artifact exists
for the profile's target architectures.

Shared dependency builds use one cross-profile lock, so simultaneous project
builds cannot modify the same dependency outputs at once.

The Kompute and HDILib source checkouts are pinned to exact upstream refs. If
their managed checkouts contain local changes, the build stops instead of
discarding them. Set `ALLOW_DEPENDENCY_SOURCE_RESET=true` only when those source
changes can be discarded.

## Toolchain configuration

`QT_VERSION` defaults to `6.10.3`. The dependency entrypoint provisions Qt
under `libraries/qt/<QT_VERSION>/macos`; the build-dependencies action also
bootstraps its pinned `aqtinstall` helper automatically. Qt is provisioned as
a toolchain prerequisite, then the dependency manager follows the existing
manifest order. Current Qt macOS
desktop archives are universal. The Qt script installs the base desktop kit
and every additional desktop module available for the pinned version (including
`qttools` and other optional libraries), then verifies `QtCore`, `QtGui`, and
`QtWidgets` contain both `x86_64` and `arm64` and checks for the CMake package
and `macdeployqt`. Installer-app builds always use the
Qt copy in `libraries`; direct shell builds can set `QT_DIR` to another
universal kit. Packaging uses the selected kit's `macdeployqt` and bundles the
Qt frameworks used by the app into the app bundle. CMake, Ninja, Xcode command
line tools, and the Vulkan SDK must be
available on the build machine.

## Release checklist

- Advance `APP_VERSION` using semantic versioning.
- Pin core and every plugin/data-plugin branch for reproducible releases.
- Set the minimum supported core version independently from the app version.
- Review installer app/projects JSON and project assets.
- Validate the profile and dependency manifest; complete a dry run.
- Build/package, then verify the generated DMG contents and architecture.
- Record signing/notarization results with the exact versioned DMG.
