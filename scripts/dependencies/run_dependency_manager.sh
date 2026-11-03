#!/bin/bash
# The only entrypoint that establishes shared dependency build settings.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPTS_ROOT/config/dependency_build.sh"
python3 "$SCRIPT_DIR/dependency_manager.py" "$@"
python3 "$SCRIPT_DIR/fetchcontent_overrides.py" "$LIBRARIES_ROOT" --prepare-only
