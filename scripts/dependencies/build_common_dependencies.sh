#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROFILE_INPUT="${1:-default}"

if [ -f "$PROFILE_INPUT" ]; then
    PROFILE_FILE="$PROFILE_INPUT"
else
    PROFILE_FILE="$SCRIPTS_ROOT/project_profiles/${PROFILE_INPUT}.env"
fi

if [ ! -f "$PROFILE_FILE" ]; then
    echo "Profile not found: $PROFILE_FILE" >&2
    exit 1
fi

export SCRIPTS_ROOT
# shellcheck disable=SC1090
source "$PROFILE_FILE"

: "${QT_VERSION:=6.10.3}"
: "${LIBRARIES_ROOT:=$SCRIPTS_ROOT/../libraries}"
: "${QT_DIR:=$LIBRARIES_ROOT/qt/$QT_VERSION/macos}"
: "${VULKAN_SDK_VERSION:=1.4.350.0}"
: "${VULKAN_SDK:=$HOME/VulkanSDK/$VULKAN_SDK_VERSION/macOS}"
: "${ARCHS:=x86_64;arm64}"
export SCRIPTS_ROOT QT_VERSION QT_DIR VULKAN_SDK_VERSION ARCHS
export VULKAN_SDK

DEPENDENCY_BUILD_MODE="${DEPENDENCY_BUILD_MODE:-if-missing}"
case "$DEPENDENCY_BUILD_MODE" in
    skip|if-missing|always) ;;
    *) echo "Invalid DEPENDENCY_BUILD_MODE '$DEPENDENCY_BUILD_MODE' (use skip, if-missing, or always)." >&2; exit 2 ;;
esac

bash "$SCRIPT_DIR/check_host.sh"
source "$SCRIPTS_ROOT/config/dependency_build.sh"

# Provision Qt as a toolchain prerequisite. The manager below still installs
# manifest dependencies in their declared prerequisite order.
export LIBRARIES_ROOT DEPENDENCY_BUILD_MODE QT_DIR
bash "$SCRIPT_DIR/build_qt_universal.sh"

manager_args=(--mode "$DEPENDENCY_BUILD_MODE")
if [ -n "${DEPENDENCY_MANIFEST_FILE:-}" ]; then
    manager_args+=(--manifest "$DEPENDENCY_MANIFEST_FILE")
fi
if [ -n "${DEPENDENCIES:-}" ]; then
    manager_args+=(--dependencies "$DEPENDENCIES")
fi
exec bash "$SCRIPT_DIR/run_dependency_manager.sh" "${manager_args[@]}"
