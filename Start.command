#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
compatible_python() {
    "$1" -c 'import sys; raise SystemExit(sys.version_info < (3, 10))' >/dev/null 2>&1
}
if [ -n "${PYTHON:-}" ]; then
    if ! compatible_python "$PYTHON"; then
        echo "ManiVault Studio needs Python 3.10 or newer. The selected PYTHON is not compatible."
        exit 1
    fi
else
    PYTHON=""
    for candidate in python3 python3.14 python3.13 python3.12 python3.11 python3.10; do
        executable="$(command -v "$candidate" || true)"
        if [ -n "$executable" ] && compatible_python "$executable"; then
            PYTHON="$executable"
            break
        fi
    done
    if [ -z "$PYTHON" ]; then
        echo "ManiVault Studio needs Python 3.10 or newer. Install Python from python.org (or brew install python), then reopen Start.command."
        exit 1
    fi
fi
RUNTIME="$ROOT/.venv"
if [ -d "$RUNTIME" ] && ! compatible_python "$RUNTIME/bin/python"; then
    backup="$ROOT/.venv.previous-$(date +%Y%m%d%H%M%S)-$$"
    echo "Replacing an incompatible local Python environment (saved at $backup)."
    mv "$RUNTIME" "$backup"
fi
if [ ! -x "$RUNTIME/bin/python" ]; then
    echo "Preparing ManiVault Studio..."
    "$PYTHON" -m venv "$RUNTIME"
fi
if ! "$RUNTIME/bin/python" -c 'import openpyxl, dmgbuild' >/dev/null 2>&1; then
    "$RUNTIME/bin/python" -m pip install --disable-pip-version-check --retries 5 --timeout 60 -r "$ROOT/requirements.txt" || {
        echo "Setup could not finish. Check your internet connection, then reopen Start.command to retry."
        exit 1
    }
fi
export PATH="$RUNTIME/bin:$PATH"
cd "$ROOT"
exec "$RUNTIME/bin/python" "$ROOT/installer_app.py" "$@"
