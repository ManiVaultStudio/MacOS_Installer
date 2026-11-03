#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPTS_ROOT="$SCRIPT_DIR"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPTS_ROOT

PROFILE_INPUT="${1:-manivault-master}"
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
source "$SCRIPT_DIR/config/project_build.sh"

: "${PROFILE_NAME:=default}"
: "${BUILDFILES_ROOT:=$SCRIPT_DIR/../builds}"
CORE_BUILD_DIR="$BUILD_ROOT/core"
COMPILE_DB="$CORE_BUILD_DIR/compile_commands.json"
LOG_DIR="$SCRIPT_DIR/build_logs"
mkdir -p "$LOG_DIR"
TS="$(date +%Y%m%d_%H%M%S)"
IWYU_LOG="$LOG_DIR/check_qt_includes_iwyu_${PROFILE_NAME}_${TS}.log"
BUILD_LOG="$LOG_DIR/check_qt_includes_build_${PROFILE_NAME}_${TS}.log"
SUMMARY_LOG="$LOG_DIR/check_qt_includes_summary_${PROFILE_NAME}_${TS}.log"

if [ ! -d "$CORE_BUILD_DIR" ]; then
    echo "Core build directory not found: $CORE_BUILD_DIR"
    echo "Run the build once first, then retry."
    exit 1
fi

cd "$ROOT_DIR"

echo "Profile: $PROFILE_NAME" | tee "$SUMMARY_LOG"
echo "Core build dir: $CORE_BUILD_DIR" | tee -a "$SUMMARY_LOG"

echo "Step 1/2: Attempting IWYU-based include analysis..." | tee -a "$SUMMARY_LOG"
if command -v include-what-you-use >/dev/null 2>&1 && command -v iwyu_tool.py >/dev/null 2>&1 && [ -f "$COMPILE_DB" ]; then
    echo "IWYU tools found. Running include-what-you-use over core sources." | tee -a "$SUMMARY_LOG"

    iwyu_tool.py \
        -p "$CORE_BUILD_DIR" \
        "$CORE_SOURCE_DIR/ManiVault/src" \
        > "$IWYU_LOG" 2>&1 || true

    echo "IWYU log: $IWYU_LOG" | tee -a "$SUMMARY_LOG"
    echo "Qt-related IWYU suggestions:" | tee -a "$SUMMARY_LOG"
    grep -Ei "(Qt|Q[A-Z][A-Za-z0-9_]+\.h|Q[A-Z][A-Za-z0-9_]+>)" "$IWYU_LOG" | head -n 120 | tee -a "$SUMMARY_LOG" || true
else
    echo "IWYU tools not available (include-what-you-use and/or iwyu_tool.py missing)." | tee -a "$SUMMARY_LOG"
fi

echo "Step 2/2: Full core compile pass to catch hard missing includes..." | tee -a "$SUMMARY_LOG"
(
    cd "$CORE_BUILD_DIR"
    ninja -k 0 -j "${CORES:-10}" Core
) > "$BUILD_LOG" 2>&1 || true

echo "Build log: $BUILD_LOG" | tee -a "$SUMMARY_LOG"
echo "Potential include-related failures:" | tee -a "$SUMMARY_LOG"
grep -Ei "(fatal error:|incomplete type|unknown type name|no type named|member access into incomplete type|expected namespace name|use of undeclared identifier|file not found)" "$BUILD_LOG" | head -n 160 | tee -a "$SUMMARY_LOG" || true

echo "Summary log: $SUMMARY_LOG" | tee -a "$SUMMARY_LOG"
echo "Done." | tee -a "$SUMMARY_LOG"
