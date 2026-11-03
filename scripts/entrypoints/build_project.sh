#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PRECHECK_CORE_ONLY=false
UPLOAD_TO_DROPBOX=false
FORWARD_ARGS=()

for arg in "$@"; do
    if [ "$arg" = "--precheck-core-only" ]; then
        PRECHECK_CORE_ONLY=true
    elif [[ "$arg" == --upload-to-dropbox=* ]]; then
        val="${arg#*=}"
        if [ "$val" = "true" ]; then
            UPLOAD_TO_DROPBOX=true
        fi
    else
        FORWARD_ARGS+=("$arg")
    fi
done

if [ "$PRECHECK_CORE_ONLY" = "true" ]; then
    PROFILE_INPUT="${FORWARD_ARGS[0]:-default}"
    exec "$SCRIPT_DIR/stages/check_core_headers.sh" "$PROFILE_INPUT"
fi

if [ "$UPLOAD_TO_DROPBOX" = "true" ]; then
    exec "$SCRIPT_DIR/pipeline/run_project_profile.sh" "${FORWARD_ARGS[@]}" --upload-to-dropbox
else
    exec "$SCRIPT_DIR/pipeline/run_project_profile.sh" "${FORWARD_ARGS[@]}"
fi
