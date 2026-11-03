#!/bin/bash
# Temporary compatibility route for existing callers; use entrypoints/create_installer.sh.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/entrypoints/create_installer.sh" "$@"
