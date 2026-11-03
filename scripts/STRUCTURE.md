# Scripts Structure

This folder is organized by responsibility.

## User-Facing Actions

The repository root `installer_app.py` is the desktop interface and
`installer_database/installer_database.xlsx` is the project database. `workflow/installer_engine.py` is the
single user-facing workflow for project clone/update, dependency setup, build,
and package actions. It translates JSON settings into the established
internal build stages. A full run refreshes pinned repositories, installs and
verifies shared dependencies, builds core/data plug-ins/plug-ins, then creates
and verifies the DMG. `profiles/validate_profile.py` checks release versions,
repository groupings, config paths, and dependency names before builds.

The workflow entrypoints live in `entrypoints/`:

- `workflow/installer_engine.py`: JSON-backed project operations and run logging.
- `profiles/`: profile synchronization and profile validation code.
- `config/`: shared project/dependency settings and build output filtering.
- `install_dependencies.sh`: profile entrypoint for shared dependencies.
- `clean_project.sh`: clear the active build and install roots.
- `clone_repos.sh` / `update_repos.sh`: synchronize profile repositories.
- `build_project.sh`: run the full project pipeline.
- `create_installer.sh`: package the installer from an existing profile build.

Legacy profile environment files load `project_profiles/common.env.sh` first;
profile values that follow it override shared defaults. The database remains the
desktop app's canonical profile store.

## Canonical Folders

- `entrypoints/`
  - Small user-facing shell commands that route to the maintained workflow stages.
- `pipeline/`
  - `run_project_profile.sh`: Main project-level orchestration entrypoint.
  - `clear_build_install.sh`: Project-level cleanup for build/install roots.
- `repos/`
  - `clonerepos.sh`: Clone repositories using project profile parameters.
  - `update_repos.sh`: Update repositories using project profile parameters.
- `stages/`
  - `build_core.sh`, `build_dataplugins.sh`, `build_plugins.sh`: Project build stages.
  - `plugins/build_tsne_plugin.sh`: Specialized t-SNE plug-in builder called by
    the plug-in stage; it is an implementation helper, not a separate workflow stage.
  - `check_core_headers.sh` and `diagnostics/check_core_qt_includes.sh`: optional
    core diagnostics.
- `config/`
  - `project_build.sh`: Common project build type, architecture, source/build/install roots, and output paths.
  - `dependency_build.sh`: Independent shared-dependency build type, architecture, deployment target, and install root.
- `lib/`
  - `cmake_config.sh`: Shared project CMake/Ninja/SDK discovery, common CMake
    arguments, and pinned FetchContent arguments. Stage-specific CMake options
    stay with their core, data plug-in, or plug-in build stage.
- `dependencies/`
  - `build_common_dependencies.sh`: Shared dependency orchestration for all projects.
  - `installer_database/dependencies.json` and `dependency_manager.py`: Pinned dependency catalog,
    prerequisite ordering, and post-build artifact verification.
  - `installer_database/source_pins.json`: Version pins and local source mappings used by
    each CMake stage; compatibility patches are prepared during dependency setup.
  - `dependency_recipe.py`: reusable builder for pinned Git/archive sources and
    CMake, Make, Autotools, or explicit command recipes.
  - `cmake_config.py`: Shared CMake command construction for dependency recipes.
  - `run_dependency_manager.sh`: One entrypoint for dependency setup and pinned
    FetchContent compatibility preparation.
  - `../package/stage_dependency_libraries.py`: packages only the shared runtime
    files declared in the dependency catalog.
  - Concrete shared-library builders such as `build_openmp_universal_updated.sh`, `build_lz4_universal.sh`, `build_flann_universal.sh`, `build_cups_universal.sh`, `build_qt_universal.sh`, `build_qtadvanceddocking_universal.sh`, `build_hdilib.sh`, `build_imagemagick.sh`, `build_libpng_arm64.sh`, and `build_combined_hdf5_zlib_universal.sh` live here.
- `package/`
  - `final_create_dmgvulkan.sh`: The maintained packaging and DMG implementation.
  - `upload/`: Optional Dropbox upload and signed installer handoff helpers.
- `project_profiles/`
  - Legacy `.env` profiles used by direct script entrypoints. The desktop app
    reads project configuration from the separate database files.
- Runtime data folders (`sources/`, `builds/`, and `libraries/`) and the
  project-specific `installer_materials/` are at the repository root, outside
  this folder because they contain data and generated outputs, not scripts.

## Utility Scripts

- `pipeline/cleartempFolder.sh`: User cache cleanup helper.
- `repos/commit_latest_changes.sh`: Batch repository commit/push helper.
- `dependencies/install_universal_dependent_libraries.sh`: Legacy dependency installer retained under the dependency folder.

## End-to-End Verification

Use dry-run mode to verify the full pipeline sequence without running heavy builds:

```bash
DRY_RUN=true ./entrypoints/build_project.sh manivault-installer --skip-update --skip-clean
```
