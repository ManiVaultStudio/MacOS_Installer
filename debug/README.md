# Run and debug the installer app

## Debug the desktop app in VS Code

1. Open this folder as a workspace in VS Code and select the Python interpreter with the packages in `requirements.txt` installed.
2. Open **Run and Debug** and choose **Installer creator** to start the desktop interface with breakpoints enabled.
3. Choose **Check project setup** to step through environment and configuration diagnostics, or **Preview build pipeline** to inspect a non-writing build plan.
4. Build output and error details appear in the app and are saved to the workbook's `Runs` and `Logs` sheets. Use **Open project database** to inspect the selected project's repository pins and installer paths.

The same checks are available from the VS Code task picker as **Installer: check setup** and **Installer: preview build**. The Python launch configurations point directly at the source files, so breakpoints work in the UI, database handling, and build orchestration code.

## Debug the native ManiVault app

The native helpers remain available when the packaged application itself needs debugging:

```bash
./debug/scripts_debugging/debug_project.sh manivault-installer
./debug/scripts_debugging/debug_project.sh cytosplore-installer
./debug/scripts_debugging/debug_project.sh --quick manivault-installer
./debug/scripts_debugging/debug_project.sh --no-rebuild manivault-installer
./debug/scripts_debugging/debug_project.sh --clean-rebuild manivault-installer
```

Native repositories are read from `sources/<project>/`. Debug build and install products are isolated under `builds/debug/<project>/<debug-or-release>/`. Set `QT_DIR` when Qt cannot be detected automatically. Use `--build-only` to prepare native debug artifacts without launching the app.

## When a build fails

Start with **Check project setup**. Resolve any missing tool, project checkout, path, customization JSON, dependency output, or CPU architecture issue it reports. For a build failure, open the most recent row in `Runs`, then review its `Logs` entries by stage. Retry a failed dependency with the dependency-only action before rebuilding the application. A clean native rebuild is available through `--clean-rebuild`; it clears only that project's native debug cache.
