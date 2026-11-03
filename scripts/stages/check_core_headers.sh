#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_ROOT="$SCRIPT_DIR"
export SCRIPTS_ROOT

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

# shellcheck disable=SC1090
source "$PROFILE_FILE"

# Resolve profile defaults similarly to the main pipeline, but isolate precheck artifacts.
: "${PROFILE_NAME:=default}"
: "${SOURCE_ROOT:=$SCRIPT_DIR/../sources}"
: "${BUILDFILES_ROOT:=$SCRIPT_DIR/../builds}"
: "${BUILD_ROOT:=$BUILDFILES_ROOT/$PROFILE_NAME/headercheck/build}"
: "${INSTALL_DIR:=$BUILDFILES_ROOT/$PROFILE_NAME/headercheck/install}"

# Speed-focused defaults for precheck runs.
CORE_ENABLE_HEADER_PRECHECK="${CORE_ENABLE_HEADER_PRECHECK:-true}"
CORE_PRECHECK_SCOPE="${CORE_PRECHECK_SCOPE:-changed}"
CORE_PRECHECK_INCLUDE_HEADERS="${CORE_PRECHECK_INCLUDE_HEADERS:-true}"
CORE_PRECHECK_ONLY=true

export BUILD_TYPE ARCHS MIN_MACOS_VERSION SOURCE_ROOT BUILD_ROOT INSTALL_DIR
export CORE_ENABLE_HEADER_PRECHECK CORE_PRECHECK_SCOPE CORE_PRECHECK_INCLUDE_HEADERS CORE_PRECHECK_ONLY

exec "$SCRIPT_DIR/stages/build_core.sh"
