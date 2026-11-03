#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PROFILE_INPUT="${1:-default}"
if [ -f "$PROFILE_INPUT" ]; then
    PROFILE_FILE="$PROFILE_INPUT"
else
    PROFILE_FILE="$SCRIPT_DIR/project_profiles/${PROFILE_INPUT}.env"
fi

if [ ! -f "$PROFILE_FILE" ]; then
    echo "Profile not found: $PROFILE_FILE"
    exit 1
fi

exec bash "$SCRIPT_DIR/dependencies/build_common_dependencies.sh" "$PROFILE_FILE"
