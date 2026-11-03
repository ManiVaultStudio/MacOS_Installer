#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Usage:
#   ./clear_build_install.sh [profile-name|profile-file]
PROFILE_INPUT="${1:-default}"
if [ -f "$PROFILE_INPUT" ]; then
    PROFILE_FILE="$PROFILE_INPUT"
else
    PROFILE_FILE="$SCRIPTS_ROOT/project_profiles/${PROFILE_INPUT}.env"
fi

if [ -f "$PROFILE_FILE" ]; then
    # shellcheck disable=SC1090
    source "$PROFILE_FILE"
fi

: "${PROFILE_NAME:=default}"
: "${PROJECT_FOLDER_NAME:=$PROFILE_NAME}"
: "${BUILDFILES_ROOT:=$SCRIPTS_ROOT/../builds}"
INSTALL_DIR="${INSTALL_DIR:-$BUILDFILES_ROOT/$PROFILE_NAME/install/$PROJECT_FOLDER_NAME}"
BUILD_ROOT="${BUILD_ROOT:-$BUILDFILES_ROOT/$PROFILE_NAME/build/$PROJECT_FOLDER_NAME}"

purge_and_recreate_dir() {
    local target="$1"
    local attempt

    if [ -d "$target" ]; then
        echo "Clearing contents of $target..."
        command -v chflags >/dev/null 2>&1 && chflags -R noschg,nouchg "$target" 2>/dev/null || true
        chmod -R u+w "$target" 2>/dev/null || true

        for attempt in 1 2 3; do
            rm -rf "$target" 2>/dev/null && break
            echo "Retrying cleanup for $target (attempt $attempt)..."
            find "$target" -mindepth 1 -maxdepth 10 -exec rm -rf {} + 2>/dev/null || true
        done

        if [ -d "$target" ]; then
            echo "❌ Could not fully clear $target."
            echo "   A concurrent process may still be writing there."
            echo "   Stop other builds and retry."
            exit 1
        fi
    fi

    mkdir -p "$target"
}

# Clear contents of install and build directories, including hidden files
purge_and_recreate_dir "$INSTALL_DIR"
purge_and_recreate_dir "$BUILD_ROOT"