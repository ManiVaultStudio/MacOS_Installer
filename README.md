# ManiVault Studio

The app builds macOS DMG installers from portable JSON configuration. Excel is not required.

## Start

Double-click **Start.command**, or run `bash Start.command`. It creates an isolated Python environment and installs the app requirements with retries. Install Python 3.10 or newer and Git first. The launcher selects a compatible Python and rebuilds an incompatible copied environment. Native builds also need Apple's command line tools (`xcode-select --install`), CMake, Ninja and pkg-config (`brew install cmake ninja pkg-config`), and the selected project's Vulkan SDK.

To inspect an already-running app, use `bash Start.command --status` (URL, port, PID and health), or `bash Start.command --print-port` for just its port. `--listen-port 58000` selects a port; `--no-browser` starts without opening a tab. A held lock reports its owner/address and a listener-inspection command instead of a traceback.

## Create an installer

**Create installer** is the primary action in the header. Choose a project, confirm its release version, and choose **Build project and package** or **Use existing build**. The release version is saved to that project's authoritative configuration and used in generated build settings and packaging.

The main navigation has four areas:

- **Build workflow**: select a build target. **Workflow** shows build progress and recent builds; **Project & plug-ins** manages that same target's settings and repositories. Changing the target never changes a global view.
- **Dependencies**: shared library/source catalog, installation, recovery-based uninstall, versions and project usage.
- **Installers**: all DMGs in the workspace output folder. Expand **Folders** to change output/copy destinations.
- **Activity**: all runs on this Mac, compact log summaries and downloadable full output.

Lists fit their page size to the available screen space, with search and previous/next controls.

The single **Add** menu is contextual: projects/plug-ins within Build workflow, sources/libraries within Dependencies. Remove actions stay beside their entries. Theme selection appears only in the header; the adjacent layout menu controls density and motion.

## Dependencies and affected projects

Dependency entries show which projects require them. **Install** runs as a logged background operation. **Uninstall** moves declared outputs to `.installer_runtime/uninstalled/` for recovery and keeps the registration and project requirements. Installed dependent libraries block unsafe uninstalls; affected projects show missing dependencies until matching outputs are restored.

Version edits offer **Update affected project requirements** or **Keep current project requirements**. Keeping an old requirement produces an explicit version mismatch and blocks builds using the wrong version. Registered prerequisites are included automatically. Existing source compatibility patches are preserved when editing pins. A new upstream version may still need different compatibility patches; source compatibility cannot be guaranteed by changing a version string.

## Separate data files

All active shared configuration is under `installer_database/`:

| File | Purpose |
| --- | --- |
| `projects.json` | Project release/build settings |
| `repositories.json` | Core and plug-in pins |
| `dependencies.json` | Build library recipes and versions |
| `source_pins.json` | Cached source pins and compatibility patches |
| `project_dependencies.json` | Project requirements and expected versions |
| `installer_assets.json` | Installer artwork and customization paths |
| `defaults/settings.json` | Initial output/copy folder defaults |
| `defaults/runs.json`, `defaults/logs.json` | Empty history templates committed to the repository |

Machine-specific settings, runs, logs and complete per-run output live under `installer_database/local/`, excluded from Git. A fresh clone copies the empty templates; later runs never change them. Existing history is migrated locally. The original workbook is retained as a legacy backup and is no longer written by the app. The obsolete workbook commit-filter Python files and hook were removed.

Related file changes use a recovery journal and stale-write checks. Database configuration is authoritative; profile files no longer overwrite it on each dashboard refresh. Legacy shell profiles retain custom values and receive generated overrides when the app edits them.

## Interrupted dependency builds

Builds default to Auto parallelism, sized to CPU and available memory (up to eight jobs). **Build limits → Low memory** uses one. Qt downloads/extracts serially with longer timeouts and retries, using [aqtinstall's documented configuration](https://aqtinstall.readthedocs.io/en/v3.3.0/configuration.html). Host tools are checked before downloads.

Normal termination signals now finalize runs as interrupted. If the OS kills the engine before it can finalize, the app records its exit code and recent output. Complete output is streamed to a per-run file; only a bounded summary is kept in memory. Activity offers **Full log** for diagnosis. An OS kill is not proof of its cause; inspect the exit code and last output. The original issue on another Mac still needs a fresh-machine retest.

## One engine, one dependency manager

The UI and command-line entry point use `scripts/workflow/installer_engine.py`. Dependency builds go through `scripts/dependencies/dependency_manager.py`, which handles prerequisites, linkage, output verification, architecture checks, and a shared build lock. New generic recipes support pinned Git sources or SHA-256 checked archives and CMake, Make, Autotools, header-only copies, or explicit argument-list build steps. CMake recipes can build static, shared, or separate static and shared outputs. Existing specialized scripts remain for dependencies with project-specific patches or build steps.

For command-line use:

```sh
python3 scripts/workflow/installer_engine.py list
python3 scripts/workflow/installer_engine.py check <project-id>
python3 scripts/workflow/installer_engine.py clone <project-id>
python3 scripts/workflow/installer_engine.py dependencies <project-id>
python3 scripts/workflow/installer_engine.py full <project-id> --dry-run
python3 scripts/workflow/installer_engine.py full <project-id>
```

The final full-build stages reuse the established ManiVault build and DMG packaging steps, with project configuration generated from the selected configuration tables. Those internal build stages remain available through the existing shell scripts. The **Dependencies** action provisions Qt as a universal shared dependency under `libraries/qt/<version>/macos`, bootstraps its pinned download helper, and installs the required Qt modules with three download attempts. DMG packaging uses that Qt kit's `macdeployqt` and bundles the Qt frameworks the app uses.

## When a build fails

1. Run **Check setup** in the app, or `python3 scripts/workflow/installer_engine.py check <project-id>`. It checks macOS tools, Qt/Vulkan paths, customization files, repository checkouts, and dependency outputs/architectures.
2. Open **Activity**, select the failed run, and download **Full log** if needed. Start with the first error or failing stage; later messages may only be follow-on failures.
3. For a missing library or wrong CPU architecture, use **Dependencies** and review its expected artifact paths. For a dirty repository, commit or stash the local changes before updating. For a missing repository, use **Clone repositories** and verify its URL and pinned ref in the project manager.
4. If a dynamic library is absent from the packaged app, check that its `.dylib` path or containing output folder appears in **Runtime Files JSON** for that dependency. If that check passes but loading still fails, inspect the first `otool`/`install_name_tool` error in the packaging log and confirm the DMG has the required architecture.

Previews run the dependency planner and build-profile validation without cloning or building:

```sh
python3 scripts/workflow/installer_engine.py dependencies <project-id> --dry-run
python3 scripts/workflow/installer_engine.py full <project-id> --dry-run
```

## Dropbox signing (optional)

The legacy pipeline can upload a completed unsigned DMG to `~/Dropbox/ToSign` and retrieve its signed counterpart from `~/Dropbox/Signed`. Configure the local Dropbox client and folders before enabling that workflow in a project profile.

For detailed project onboarding and dependency examples, see [Projects and dependencies](PROJECTS_AND_DEPENDENCIES.md).

## Project layout

- `installer_app.py` is the desktop interface; `scripts/workflow/installer_engine.py` runs the project workflows.
- `scripts/` contains executable build, clone, packaging, and helper scripts only.
- `sources/<project>/` contains project repository checkouts. These folders are created by Clone.
- `builds/<project>/` contains generated builds, installs, DMG staging, and outputs.
- `builds/debug/<project>/<configuration>/` contains native IDE debug builds and installs.
- `libraries/` contains dependency source archives, checkouts, build trees, and installed outputs. Dependency artifact paths are relative to this directory.
- `installer_materials/common/` contains shared assets and licenses. `installer_materials/projects/<project>/` contains each project's JSON, icon, background, and folder icon overrides.
- `debug/` contains debugging instructions and the native debug helper scripts, not build outputs.

When adding a project in the desktop app, a project-specific installer materials folder is seeded from the ManiVault template. Edit its `InstallerAssets` configuration entry to point to alternate JSON or artwork files. Shared license and splash assets remain in `installer_materials/common/`.

## Moving to another Mac

Clone the updated repository and open `Start.command`. Do not copy `.venv`, Qt helper environments or generated build folders from another computer. Retry failed dependency operations after fixing the reported cause; verified completed libraries are reused.

## Faster repeat builds

Incremental mode is enabled by default. Unchanged patched sources keep their timestamps, so Ninja reuses compiled output. Build/install use one target traversal. Optional `ccache` is used automatically when available (`brew install ccache`). Turn Incremental off when a clean rebuild is needed. First-time universal builds still compile both Mac architectures.

In Activity, click anywhere on a log row to toggle selection. Shift-click selects a range of visible rows; **Copy selected** copies them together. Drag text to highlight part of a message. Additional log and history actions are under **More**.

Workflow stages display completed (green), running (accent), failed (red), paused/stopped (amber), or skipped states. New runs record explicit stage events. Activity and Dependencies fit the viewport; dependencies scroll inside their panel. The moving activity line indicates ongoing work, alongside elapsed time and the current stage. It does not show a completion percentage or a guessed countdown.

The header instance badge lists this user’s Studio servers, ports and process IDs. Extra responsive instances can be stopped after confirmation; busy instances and the last responsive instance are protected. The final instance is stopped from Terminal using the provided command. Appearance settings offer density, text size, surface style and reduced/standard/expressive motion; themes remain in the header selector. **Build options → Plan only** rehearses saved settings without downloading, compiling or packaging, and saves a preview run without changing the release version.

The dashboard fetches log history only in Activity, and unchanged logs use a revision token. Idle polling runs every ten seconds; active runs update every two seconds, while hidden tabs pause workspace fetches. Hidden log rows are released from the page, and run lists redraw only when their content changes. Source fingerprints are cached by file size, nanosecond modification time and change time, avoiding repeat hashing while still detecting edited files.
