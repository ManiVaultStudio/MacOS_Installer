#!/bin/bash
set -euo pipefail
# -----------------------------------------------
# ManiVault DMG Creation & Signing Script - Optimized (Enhanced)
# -----------------------------------------------

# Fail fast and propagate pipeline errors
set -eo pipefail

# Provide safer globbing and IFS usage
IFS=$'\n\t'

# Normalize PATH so Homebrew /usr/local tools are available when run from GUI shells
export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"

# --- Utility Helpers (added) ---

# Simple custom timeout fallback (used only if /usr/bin/timeout not available)
custom_timeout() { # seconds cmd...
    local timeout_duration=$1; shift
    "$@" &
    local pid=$!
    (
        sleep "$timeout_duration" && kill -0 $pid 2>/dev/null && kill -9 $pid 2>/dev/null || true
    ) &
    local killer=$!
    wait $pid 2>/dev/null
    local ec=$?
    kill $killer 2>/dev/null || true
    return $ec
}

# Central trap-based cleanup registry
_CLEANUP_TASKS=()
ACTIVE_DMG_MOUNT=""
ACTIVE_DMG_TEMP_DIR=""
register_cleanup() { _CLEANUP_TASKS+=("$*"); }
run_cleanups() {
    if [[ -n "$ACTIVE_DMG_MOUNT" && -d "$ACTIVE_DMG_MOUNT" ]]; then
        hdiutil detach "$ACTIVE_DMG_MOUNT" -force >/dev/null 2>&1 || true
    fi
    [[ -n "$ACTIVE_DMG_TEMP_DIR" ]] && rm -rf "$ACTIVE_DMG_TEMP_DIR"
    for task in "${_CLEANUP_TASKS[@]}"; do eval "$task" || true; done
}
trap run_cleanups EXIT INT TERM

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIBRARIES_ROOT="${LIBRARIES_ROOT:-$(cd "$SCRIPTS_ROOT/../libraries" && pwd)}"
# Set PKG_CONFIG_PATH and CMAKE_PREFIX_PATH here if needed, but they are generally
# for the build process, not the packaging script itself. The relevant paths for
# packaging are the library locations.
INSTALL_DIR="${INSTALL_DIR:-$SCRIPTS_ROOT/install}"
# Create a staging copy dir so original install artifacts remain pristine
INSTALL_COPY_DIR="${INSTALL_COPY_DIR:-$SCRIPTS_ROOT/installCopy}"
INSTALL_DMG_TEMP_DIR="${INSTALL_DMG_TEMP_DIR:-$SCRIPTS_ROOT/dmg_temp_content}" # New temporary directory for DMG content
INSTALLER_MATERIALS_ROOT="${INSTALLER_MATERIALS_ROOT:-$SCRIPTS_ROOT/../installer_materials/projects/${PROFILE_NAME:-default}}"
INSTALLER_MATERIALS="${INSTALLER_MATERIALS:-$INSTALLER_MATERIALS_ROOT}"

## FORCE Qt 6.10.3: Ensure this script always uses the user's Qt 6.10.3 installation
# The user requested that macdeployqt and all Qt tooling used by this packaging
# script come from the Qt 6.10.3 installation. Hard-set those paths here.
QT_DIR="${QT_DIR:-$LIBRARIES_ROOT/qt/${QT_VERSION:-6.10.3}/macos}"
QT_CMAKE_DIR="$QT_DIR/lib/cmake/Qt6"
QT_BIN_DIR="$QT_DIR/bin"

# Validate macdeployqt exists at the expected location
if [ ! -x "$QT_BIN_DIR/macdeployqt" ]; then
    echo "❌ macdeployqt not found at '$QT_BIN_DIR/macdeployqt'."
    echo "   Please ensure Qt 6.10.3 is installed at: $QT_DIR" >&2
    exit 1
fi
echo "ℹ️ Using Qt at: $QT_DIR (CMake dir: $QT_CMAKE_DIR)"

# Prefer a versioned advanced docking dylib from the shared library store.
ADVANCED_DOCKING_LIB=""
for f in "$LIBRARIES_ROOT"/qads/libqtadvanceddocking-qt6.*.dylib; do
    # shell glob will expand to pattern itself if no match; check file exists
    if [ -f "$f" ]; then
        ADVANCED_DOCKING_LIB="$f"
        break
    fi
done
# Fallback to unversioned name
if [ -z "$ADVANCED_DOCKING_LIB" ]; then
    ADVANCED_DOCKING_LIB="$LIBRARIES_ROOT/qads/libqtadvanceddocking-qt6.dylib"
fi

VULKAN_SDK_DIR="${VULKAN_SDK_DIR:-${VULKAN_SDK:-$HOME/VulkanSDK/${VULKAN_SDK_VERSION:-1.4.350.0}/macOS}}"
VULKAN_LIB=""
for candidate in "$VULKAN_SDK_DIR"/lib/libvulkan.*.dylib; do
    if [ -f "$candidate" ]; then
        VULKAN_LIB="$candidate"
        break
    fi
done
if [ -z "$VULKAN_LIB" ]; then
    echo "⚠️ Vulkan library not found under: $VULKAN_SDK_DIR/lib"
fi

# URL for Qt Advanced Docking System release zip used by build scripts
#QADS_ZIP_URL="https://github.com/githubuser0xFFFF/Qt-Advanced-Docking-System/archive/refs/tags/5.1.1.zip"


# App & DMG settings
APP_NAME="${APP_NAME:-ManiVault Studio.app}"
VOLUME_NAME="${VOLUME_NAME:-Cytosplore Viewer}"
DMG_FORMAT="${DMG_FORMAT:-UDZO}"
APP_VERSION="${APP_VERSION:-1.0.0}"
CUSTOMIZATION_FOLDER_PRESENT="${CUSTOMIZATION_FOLDER_PRESENT:-true}"
# Only set PROJECTS_SOURCE_FILE to a default if it is unset (not if empty)
if [ "${PROJECTS_SOURCE_FILE+set}" != "set" ]; then
    PROJECTS_SOURCE_FILE="$INSTALLER_MATERIALS/projects.json"
fi
APP_CONFIG_SOURCE_FILE="${APP_CONFIG_SOURCE_FILE:-$INSTALLER_MATERIALS/app.json}"
MIN_CORE_VERSION_MAJOR="${MIN_CORE_VERSION_MAJOR:-1}"
MIN_CORE_VERSION_MINOR="${MIN_CORE_VERSION_MINOR:-4}"
MIN_CORE_VERSION_PATCH="${MIN_CORE_VERSION_PATCH:-0}"
MIN_CORE_VERSION_SUFFIX="${MIN_CORE_VERSION_SUFFIX:-}"

# Optional behavior flags (can be overridden via environment)
SKIP_FINDER_UI="${SKIP_FINDER_UI:-false}"   # If true, skip Finder window customization (prevents -15260 errors)
FINDER_UI_MAX_RETRIES="${FINDER_UI_MAX_RETRIES:-5}" # Attempts for Finder customization
FINDER_UI_RETRY_DELAY="${FINDER_UI_RETRY_DELAY:-3}" # Seconds between retries

# DMG background image configuration (ported from create_dmg.sh)
# Override via environment: export DMG_BACKGROUND_IMAGE=/path/to/custom.png
# Disable via: export ENABLE_DMG_BACKGROUND=false
DMG_BACKGROUND_IMAGE="${DMG_BACKGROUND_IMAGE:-$INSTALLER_MATERIALS/dmg-background.png}"
ENABLE_DMG_BACKGROUND="${ENABLE_DMG_BACKGROUND:-true}"
DMG_BACKGROUND_STATUS="uninitialized"
APP_ICON_FILE="${APP_ICON_FILE:-$INSTALLER_MATERIALS/appimage-cytosplore.icns}"
MAIN_FOLDER_ICON_FILE="${MAIN_FOLDER_ICON_FILE:-$INSTALLER_MATERIALS/main-folder-icon.png}"
LICENSE_DIR="${LICENSE_DIR:-$INSTALLER_MATERIALS/license}"
ASSETS_DIR="${ASSETS_DIR:-$INSTALLER_MATERIALS/assets}"
EXCLUDED_PLUGINS="${EXCLUDED_PLUGINS:-}"

# DMG window & icon layout configuration (ported positioning logic)
# Override any of these via environment before running script.
DMG_WIDTH="${DMG_WIDTH:-527}"
DMG_HEIGHT="${DMG_HEIGHT:-429}"
DMG_ICON_SIZE="${DMG_ICON_SIZE:-96}"
DMG_ICON_MARGIN="${DMG_ICON_MARGIN:-60}"

# Code Signing (Simplified: always local certificate / developer machine signing)
# Set LOCAL_IDENTITY to the name/sha of the local certificate you want to use (or '-' for ad-hoc)
LOCAL_IDENTITY="-"
SKIP_GATEKEEPER=true   # Gatekeeper validation skipped for local signing

# Output directory
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPTS_ROOT/../application}"
mkdir -p "$OUTPUT_DIR"

# Register removal of transient staging area
register_cleanup "rm -rf '$SCRIPTS_ROOT/dmg_temp_content_inprogress'"

# Metrics counters (populated later)
PATCHED_BIN_COUNT=0
COPIED_LIB_COUNT=0
PLUGIN_COPIED_LIB_COUNT=0
PRE_MAC_BINARIES_SCANNED=0
PRE_MAC_DEPS_PATCHED=0
PRE_MAC_QT_FW_ADDED=0

# Only these libraries are permitted inside the app Frameworks directory.
# All other non-Qt, non-system dylibs required at runtime must reside in the Plugins
# directory (and we add appropriate RPATH entries so they can be resolved there).
ALLOWED_FRAMEWORK_LIBS=( \
    libMV_Public.dylib \
    libcups.2.dylib \
    libflann.1.9.2.dylib \
    libflann.1.9.dylib \
    libflann.dylib \
    libflann_cpp.1.9.2.dylib \
    libflann_cpp.1.9.dylib \
    libflann_cpp.dylib \
    libiconv.2.dylib \
    liblz4.1.dylib \
    libomp.dylib \
    libqtadvanceddocking.5.dylib \
    libqtadvanceddocking-qt6.dylib \
    libqtadvanceddocking.5.1.1.dylib \
    libvulkan.1.4.350.dylib \
    libvulkan.1.dylib \
    libvulkan.dylib \
)

# Optional: minimize added RPATH entries (avoids redundant @executable_path + @loader_path pairs where one suffices)
# Set MINIMAL_RPATH=false to retain legacy "belt & suspenders" behavior.
MINIMAL_RPATH="${MINIMAL_RPATH:-true}"
INTERNAL_FRAMEWORK_DATA_LIBS=(libMV_Public.dylib)
# Control whether we forcibly rewrite the main executable's references to
# libMV_Public.dylib / libImageData.dylib to explicit @executable_path paths.
# Default now: leave them as @rpath (more flexible, cleaner). Set to "true"
# to restore legacy explicit pinning behavior.
PIN_INTERNAL_LIBS="${PIN_INTERNAL_LIBS:-false}"


# -----------------------
# Helper Functions
# -----------------------

# Robust directory removal that won't abort the script under set -e if partial failures occur.
safe_remove_dir() {
    local target="$1"
    [ -z "$target" ] && return 0
    [ ! -d "$target" ] && return 0
    echo "🧽 Removing directory: $target"
    # Clear immutable flags (macOS) in case any got set
    command -v chflags >/dev/null 2>&1 && chflags -R noschg,nouchg "$target" 2>/dev/null || true
    # Ensure writable
    chmod -R u+w "$target" 2>/dev/null || true
    # Try a few times (transient file locks, Spotlight indexing, etc.)
    local attempt
    for attempt in 1 2 3; do
        rm -rf "$target" 2>/dev/null && break
        echo "   • Attempt $attempt failed; retrying..."
        sleep 1
        # Enumerate stubborn entries after second attempt for diagnostics
        if [ $attempt -ge 2 ] && [ -d "$target" ]; then
            find "$target" -maxdepth 2 -mindepth 1 2>/dev/null | head -n 5 | sed 's/^/      leftover: /'
        fi
    done
    if [ -d "$target" ]; then
        echo "⚠️ Fallback purge for stubborn directory: $target"
        # Last resort: delete contents individually then remove dirs depth-first
        find "$target" -type f -exec chmod u+w {} + 2>/dev/null || true
        find "$target" -type f -exec rm -f {} + 2>/dev/null || true
        find "$target" -depth -type d -exec rmdir {} + 2>/dev/null || true
    fi
    [ -d "$target" ] && echo "❌ Could not fully remove $target (continuing anyway)" || echo "✅ Removed $target"
}

check_tools() {
    echo "🔍 Checking for required tools..."
    local missing=0
    local tools=(install_name_tool codesign xcrun spctl hdiutil)

    for tool in "${tools[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            echo "❌ Required tool '$tool' not found."
            missing=$((missing + 1))
        fi
    done

    if [ ! -x "$QT_BIN_DIR/macdeployqt" ]; then
        echo "❌ Required tool 'macdeployqt' not found at '$QT_BIN_DIR/macdeployqt'."
        missing=$((missing + 1))
    fi

    if [ $missing -gt 0 ]; then
        echo "🚨 Missing $missing required tools. Please install them before proceeding."
        exit 1
    fi
    echo "✅ All required tools are available."
}

safe_patch_dependency() {
    local bin="$1"; local old="$2"; local new="$3"
    [[ ! -f "$bin" ]] && return 0
    if otool -L "$bin" 2>/dev/null | grep -q "$old"; then
        chmod +w "$bin" 2>/dev/null || true
        if install_name_tool -change "$old" "$new" "$bin" 2>/dev/null; then
            PATCHED_BIN_COUNT=$((PATCHED_BIN_COUNT + 1))
        else
            echo "⚠️ Failed to patch $old in $(basename "$bin")"
        fi
    fi
}

# Verify that a library exists & is readable by otool
verify_library() {
    local lib="$1"
    if [[ ! -f "$lib" ]]; then
        echo "❌ Missing library: $lib"; return 1; fi
    if ! otool -L "$lib" >/dev/null 2>&1; then
        echo "❌ Corrupt / unreadable library: $lib"; return 1; fi
    return 0
}

prepare_projects_json() {
    local src="$1"
    local dst="$2"

    if [ ! -f "$src" ]; then
        echo "⚠️ projects.json source not found at $src"
        return 0
    fi

    if command -v jq >/dev/null 2>&1; then
        if jq \
            --argjson major "$MIN_CORE_VERSION_MAJOR" \
            --argjson minor "$MIN_CORE_VERSION_MINOR" \
            --argjson patch "$MIN_CORE_VERSION_PATCH" \
            --arg suffix "$MIN_CORE_VERSION_SUFFIX" \
            '.projects |= map(.coreVersion = {major: $major, minor: $minor, patch: $patch, suffix: $suffix})' \
            "$src" > "$dst"; then
            echo "   • Parameterized projects.json coreVersion to ${MIN_CORE_VERSION_MAJOR}.${MIN_CORE_VERSION_MINOR}.${MIN_CORE_VERSION_PATCH}${MIN_CORE_VERSION_SUFFIX}"
            return 0
        fi
    fi

    cp -f "$src" "$dst"
    echo "   • Copied projects.json without version override (jq unavailable or failed)"
}

# (Removed verify_signing_identity – no longer needed in simplified local-only signing mode)

final_summary() {
    echo "--------------------------------------------"
    echo "📊 Summary"
    echo "   Patched dependency references : $PATCHED_BIN_COUNT"
    echo "   Copied external libraries     : $COPIED_LIB_COUNT"
    echo "   Copied plugin-only libraries  : $PLUGIN_COPIED_LIB_COUNT"
    if [ ${PRE_MAC_BINARIES_SCANNED:-0} -gt 0 ]; then
        echo "   Pre-mac binaries scanned       : $PRE_MAC_BINARIES_SCANNED"
        echo "   Pre-mac deps normalized        : $PRE_MAC_DEPS_PATCHED"
    fi
    if [ ${PRE_MAC_QT_FW_ADDED:-0} -gt 0 ]; then
        echo "   Pre-mac Qt frameworks added    : $PRE_MAC_QT_FW_ADDED"
    fi
    echo "   Output directory              : $OUTPUT_DIR"
    echo "   Framework policy              : restricted (only whitelisted dylibs in Frameworks)"
    echo "   Plugin RPATH patching         : applied (see logs for per-plugin details)"
    echo "   Signing mode                  : ${SIGNING_MODE:-unknown}"
    echo "   Staging abs path check        : ${STAGING_ABS_STATUS:-unknown}"
    echo "   Final app abs path check      : ${FINAL_ABS_STATUS:-unknown}"
    echo "   Plugins abs path check        : ${PLUGINS_ABS_STATUS:-not-run}"
    echo "   DMG background                : ${DMG_BACKGROUND_STATUS:-n/a}"
    echo "   DMG layout (WxH / icon / margin): ${DMG_WIDTH}x${DMG_HEIGHT} / ${DMG_ICON_SIZE} / ${DMG_ICON_MARGIN}"
    echo "   Customization folder         : ${CUSTOMIZATION_FOLDER_PRESENT:-n/a}"
    if [ -n "$FINAL_DMG_PATH" ] && [ -f "$FINAL_DMG_PATH" ]; then
        echo "   Final DMG                     : $FINAL_DMG_PATH"
        if command -v shasum >/dev/null 2>&1; then
            echo "   Final DMG SHA-256             : $(shasum -a 256 "$FINAL_DMG_PATH" | cut -d' ' -f1)"
        fi
    fi
    if [ -n "${AUTO_INTERNAL_COPIED:-}" ]; then
        if [ -n "${AUTO_INTERNAL_SKIPPED_PLUGINS:-}" ]; then
            echo "   Auto-detected internal libs   : copied=$AUTO_INTERNAL_COPIED missing=$AUTO_INTERNAL_MISSING skipped_plugins=$AUTO_INTERNAL_SKIPPED_PLUGINS"
        else
            echo "   Auto-detected internal libs   : copied=$AUTO_INTERNAL_COPIED missing=$AUTO_INTERNAL_MISSING"
        fi
    fi
    echo "--------------------------------------------"
}

patch_paths_in_staging() { # operates on INSTALL_COPY_DIR if exists else INSTALL_DIR
    local root="${INSTALL_COPY_DIR:-$INSTALL_DIR}"
    [ -d "$root" ] || return 0
    echo "🔄 Patching absolute dependency paths inside $root ..."
    # Collect binaries & dylibs (portable, avoids Bash 4+ 'mapfile' builtin)
    local bins=()
    while IFS= read -r -d '' f; do
        bins+=("$f")
    done < <(find "$root" -type f ! -path "*.dSYM/*" \( -name "*.dylib" -o -perm -111 \) -print0)
    for b in "${bins[@]}"; do
        safe_patch_dependency "$b" "/usr/local/lib/liblz4.1.dylib" "@rpath/liblz4.1.dylib"
        safe_patch_dependency "$b" "/opt/homebrew/lib/liblz4.1.dylib" "@rpath/liblz4.1.dylib"
        # Generic absolute path conversion
        while IFS= read -r dep; do
            [[ -z "$dep" ]] && continue
            [[ "$dep" =~ ^@ ]] && continue
            [[ "$dep" =~ ^/System/Library/Frameworks/ ]] && continue
            [[ "$dep" =~ ^/usr/lib/libSystem ]] && continue
            [[ "$dep" =~ ^/usr/lib/libc\+\+ ]] && continue
            [[ "$dep" =~ ^/usr/lib/libresolv ]] && continue
            safe_patch_dependency "$b" "$dep" "@rpath/$(basename "$dep")"
        done < <(otool -L "$b" 2>/dev/null | awk '{print $1}' | grep -E '/Users/|/usr/local/|/opt/homebrew/' || true)
    done
    # Verification pass for lingering LZ4
    local leftovers
    leftovers=$(printf '%s\n' "${bins[@]}" | xargs otool -L 2>/dev/null | grep -E '/usr/local/lib/liblz4.1.dylib|/opt/homebrew/lib/liblz4.1.dylib' || true)
    if [ -n "$leftovers" ]; then
        echo "⚠️ Second attempt patch for leftover LZ4 references"
        while read -r line; do
            local dep=$(echo "$line" | awk '{print $1}')
            for b in "${bins[@]}"; do
                safe_patch_dependency "$b" "$dep" "@rpath/liblz4.1.dylib"
            done
        done <<< "$leftovers"
        # Re-check
        if printf '%s\n' "${bins[@]}" | xargs otool -L 2>/dev/null | grep -q -E '/usr/local/lib/liblz4.1.dylib|/opt/homebrew/lib/liblz4.1.dylib'; then
            echo "❌ Unable to remove all absolute LZ4 references"; exit 1; fi
    fi
    echo "✅ Path patching complete"
}

# Ensure flann-related dylibs copied into the staged app Frameworks directory do not
# retain absolute references to Homebrew-installed liblz4 before macdeployqt runs.
# This is needed because these flann libs are injected AFTER the initial staging
# absolute-path scrub (patch_paths_in_staging) and thus would otherwise keep any
# /usr/local/lib or /opt/homebrew/lib install_name references to liblz4.1.dylib.
fix_flann_lz4_references_pre_mac() { # app_frameworks_dir
    local fw_dir="$1"
    [ -d "$fw_dir" ] || return 0
    echo "🔧 Pre-macdeployqt: normalizing flann -> lz4 references in Frameworks"
    local f
    while IFS= read -r -d '' f; do
        safe_patch_dependency "$f" "/usr/local/lib/liblz4.1.dylib" "@rpath/liblz4.1.dylib"
        safe_patch_dependency "$f" "/opt/homebrew/lib/liblz4.1.dylib" "@rpath/liblz4.1.dylib"
    done < <(find "$fw_dir" -maxdepth 1 -type f \( -name 'libflann*.dylib' -o -name 'libflann_cpp*.dylib' \) -print0 2>/dev/null || true)
}

# Generic absolute dependency scanner + normalizer prior to macdeployqt.
# Scans BOTH the app bundle binaries AND the sibling Plugins directory and
# rewrites any absolute references (build tree, Homebrew, user paths) to
# @rpath/<basename>, excluding system / standard libraries.
pre_mac_check_and_patch_dependencies() { # app_path
    local app_path="$1"
    [ -d "$app_path" ] || return 0
    local plugin_dir="$(dirname "$app_path")/Plugins"
    echo "🔍 Pre-macdeployqt: scanning for absolute dependency paths (app + Plugins)"
    local targets=()
    # Collect executables, dylibs, .so inside app
    while IFS= read -r -d '' f; do targets+=("$f"); done < <(find "$app_path" -type f \( -name '*.dylib' -o -name '*.so' -o -perm -111 \) -print0 2>/dev/null)
    # Collect plugin dylibs (non-recursive for now)
    if [ -d "$plugin_dir" ]; then
        while IFS= read -r -d '' f; do targets+=("$f"); done < <(find "$plugin_dir" -type f -name '*.dylib' -print0 2>/dev/null)
    fi
    local bin dep base patched_this
    for bin in "${targets[@]}"; do
        [ -f "$bin" ] || continue
        PRE_MAC_BINARIES_SCANNED=$((PRE_MAC_BINARIES_SCANNED+1))
        # Enumerate dependency lines, skip header (first line) using NR>1
        while IFS= read -r dep; do
            [ -z "$dep" ] && continue
            case "$dep" in
                @*) continue;;
                /System/Library/*) continue;;
                /usr/lib/libSystem.*) continue;;
                /usr/lib/libc++*) continue;;
                /usr/lib/libresolv*) continue;;
            esac
            # Only patch obvious build/homebrew/user paths
            if echo "$dep" | grep -qE '/Users/|/usr/local/|/opt/homebrew/'; then
                base=$(basename "$dep")
                chmod +w "$bin" 2>/dev/null || true
                if install_name_tool -change "$dep" "@rpath/$base" "$bin" 2>/dev/null; then
                    PRE_MAC_DEPS_PATCHED=$((PRE_MAC_DEPS_PATCHED+1))
                    PATCHED_BIN_COUNT=$((PATCHED_BIN_COUNT+1))
                fi
            fi
        done < <(otool -L "$bin" 2>/dev/null | awk 'NR>1 {print $1}')
    done
    echo "✅ Pre-macdeployqt scan complete (binaries=$PRE_MAC_BINARIES_SCANNED, deps_normalized=$PRE_MAC_DEPS_PATCHED)"
}

# Detect Qt framework dependencies in plugin + app binaries that are *not* yet present
# in the app's Frameworks directory (notably QtTest.framework) and copy them from the
# Qt installation *before* running macdeployqt so macdeployqt can process/sign them.
ensure_qt_frameworks_for_plugins_pre_mac() { # app_path
    local app_path="$1"
    local app_frameworks="$app_path/Contents/Frameworks"
    local plugin_dir="$(dirname "$app_path")/Plugins"
    [ -d "$plugin_dir" ] || return 0
    mkdir -p "$app_frameworks"
    echo "🔍 Pre-macdeployqt: scanning plugin + app binaries for missing Qt frameworks"
    local tmp_dep
    tmp_dep=$(mktemp)
    # Collect binaries (plugins + app exe/libs)
    find "$plugin_dir" -type f -name '*.dylib' -print0 2>/dev/null | \
        xargs -0 otool -L 2>/dev/null | awk 'NR>1 {print $1}' >> "$tmp_dep" || true
    find "$app_path" -type f \( -name '*.dylib' -o -name '*.so' -o -perm -111 \) -print0 2>/dev/null | \
        xargs -0 otool -L 2>/dev/null | awk 'NR>1 {print $1}' >> "$tmp_dep" || true
    # Extract unique Qt framework base names from @rpath/Qt*.framework paths
    local fw f base src
    sort -u "$tmp_dep" | grep -E '@rpath/Qt[A-Za-z0-9]+\.framework' | while IFS= read -r f; do
        base=$(echo "$f" | sed -E 's|^@rpath/(Qt[^/]+)\.framework.*|\1|')
        [ -z "$base" ] && continue
        # Skip if already present
        [ -d "$app_frameworks/${base}.framework" ] && continue
        # Locate in Qt installation (common layouts)
        for src in "$QT_DIR/lib/${base}.framework" "$QT_DIR/../lib/${base}.framework" "$QT_DIR/${base}.framework"; do
            if [ -d "$src" ]; then
                echo "📦 Copying required Qt framework: ${base}.framework"
                cp -R "$src" "$app_frameworks/" 2>/dev/null || { echo "⚠️ Failed to copy $base"; continue; }
                PRE_MAC_QT_FW_ADDED=$((PRE_MAC_QT_FW_ADDED+1))
                break
            fi
        done
        if [ ! -d "$app_frameworks/${base}.framework" ]; then
            echo "⚠️ Qt framework ${base}.framework referenced but not found in Qt install paths"
        fi
    done
    rm -f "$tmp_dep" 2>/dev/null || true
    echo "✅ Qt framework plugin dependency scan complete (added=$PRE_MAC_QT_FW_ADDED)"
}

# Dynamically verify that every referenced Qt*.framework dependency found in the app & plugin binaries
# exists inside the app Frameworks directory (replaces static hard-coded framework list verification).
verify_qt_frameworks_present() { # app_path
    local app_path="$1"; local app_frameworks="$app_path/Contents/Frameworks"; [ -d "$app_path" ] || return 0
    local tmp_refs; tmp_refs=$(mktemp)
    # Collect all dependency lines from app + its frameworks + (sibling) Plugins
    local plugin_dir="$(dirname "$app_path")/Plugins"
    find "$app_path" -type f \( -name '*.dylib' -o -name '*.so' -o -perm -111 \) -print0 2>/dev/null | \
        xargs -0 otool -L 2>/dev/null | awk 'NR>1 {print $1}' >> "$tmp_refs" || true
    if [ -d "$plugin_dir" ]; then
        find "$plugin_dir" -type f -name '*.dylib' -print0 2>/dev/null | \
            xargs -0 otool -L 2>/dev/null | awk 'NR>1 {print $1}' >> "$tmp_refs" || true
    fi
    # Extract unique Qt framework basenames
    sort -u "$tmp_refs" | grep -E '@rpath/Qt[^/]+\.framework' | \
        sed -E 's|^@rpath/(Qt[^/]+)\.framework.*|\1|' | sort -u | while read -r fw; do
            [ -z "$fw" ] && continue
            if [ ! -d "$app_frameworks/${fw}.framework" ]; then
                echo "⚠️ Missing Qt framework referenced by binaries: ${fw}.framework"
            fi
        done
    rm -f "$tmp_refs" 2>/dev/null || true
}

# Ensure a populated external Plugins directory (ported logic from legacy script)
# NOTE (Plugin Packaging Policy):
#   Per updated requirement, plugin dylibs found in the build output
#   (Release/Plugins) MUST ONLY be copied next to the .app inside the
#   DMG staging structure. They should NOT be pre-populated into the
#   intermediate install / installCopy tree to avoid duplication and
#   accidental inclusion elsewhere. The early helper below is therefore
#   reduced to only creating an empty placeholder if needed and will
#   NOT copy from Release/Plugins.
ensure_plugins_directory() {
    local root_dir="$INSTALL_DIR"
    local plugins_dir="$root_dir/Plugins"
    if [ ! -d "$plugins_dir" ]; then
        echo "📁 (Policy) Creating empty Plugins directory (no early copy): $plugins_dir"
        mkdir -p "$plugins_dir"
    else
        echo "ℹ️ (Policy) Existing Plugins directory left unchanged (no early copy)"
    fi
}


# Explicit helper to replace the staged app's icon inside dmg_temp_content before macdeployqt runs.
# This satisfies the requirement to ensure the Cytosplore Viewer.app inside the staging tree already
# contains the desired icon, while the later logic in prepare_and_package_app reinforces it post-macdeployqt.
replace_staged_app_icon() {
    local staged_app="$INSTALL_DMG_TEMP_DIR/$VOLUME_NAME/$VOLUME_NAME/$VOLUME_NAME.app"
    local icon_source="$APP_ICON_FILE"
    [ -d "$staged_app" ] || { echo "ℹ️ Staged app not yet present for early icon replacement"; return 0; }
    if [ -f "$icon_source" ]; then
        echo "🖼️  (Early) Replacing staged app icon with $icon_source"
        mkdir -p "$staged_app/Contents/Resources"
        cp -f "$icon_source" "$staged_app/Contents/Resources/appimage.icns"
        # Defer Info.plist edit until after macdeployqt (done later) to avoid being overwritten.
    else
        echo "⚠️ Icon source $icon_source not found for early replacement"
    fi
}


# --- Core Functions ---

prepare_and_package_app() {
    echo "🛠️ Stage: Finalizing app inside staged volume (nested folder layout)..."
    # App bundle now lives inside a nested folder named "$VOLUME_NAME" at DMG root
    local app_path="$INSTALL_DMG_TEMP_DIR/$VOLUME_NAME/$VOLUME_NAME/$VOLUME_NAME.app"
    local app_contents="$app_path/Contents"
    local app_frameworks="$app_contents/Frameworks"
    [ -d "$app_path" ] || { echo "❌ Expected staged app bundle not found at: $app_path"; exit 1; }
    chmod -R u+w "$app_path" || true
    [ -f "$app_contents/PkgInfo" ] || echo "APPL????" > "$app_contents/PkgInfo" || true
    inject_additional_libraries "$app_frameworks"
    # --- EARLY COPY of internal project libraries (libMV_Public & libImageData) ---
    # These were previously copied AFTER macdeployqt which left their internal Qt
    # dependency references pointing at absolute build / Qt install paths.
    # By copying them BEFORE macdeployqt, the deployment tool can rewrite those
    # references to bundled Qt frameworks (eliminating hard‑coded Qt paths).
    echo "📦 (Early) Copying internal project libraries prior to macdeployqt..."
    local mv_public_src image_data_src
    mv_public_src=$(find "$INSTALL_DIR" -type f -name "libMV_Public.dylib" -print -quit)
    [ -n "$mv_public_src" ] && cp -f "$mv_public_src" "$app_frameworks/libMV_Public.dylib" || echo "⚠️ libMV_Public.dylib not found (early phase)"
    image_data_src=$(find "$INSTALL_DIR" -type f -name "libImageData.dylib" -print -quit)
    [ -n "$image_data_src" ] && cp -f "$image_data_src" "$app_frameworks/libImageData.dylib" || echo "⚠️ libImageData.dylib not found (early phase)"
    # Assign stable install IDs now so macdeployqt respects @rpath form
    for _ilib in libMV_Public.dylib libImageData.dylib; do
        [ -f "$app_frameworks/$_ilib" ] && install_name_tool -id "@rpath/$_ilib" "$app_frameworks/$_ilib" 2>/dev/null || true
    done
    # Opportunistically scrub absolute Qt paths inside these freshly copied libs
    # in case macdeployqt leaves any remnants (defensive pass).
    for _ilib in libMV_Public.dylib libImageData.dylib; do
        local _p="$app_frameworks/$_ilib"
        [ -f "$_p" ] || continue
        chmod u+w "$_p" 2>/dev/null || true
        otool -L "$_p" 2>/dev/null | awk 'NR>1 {print $1}' | while read -r dep; do
            [ -z "$dep" ] && continue
            case "$dep" in
                @*|/System/Library/*|/usr/lib/libSystem.*|/usr/lib/libc++*|/usr/lib/libresolv*) continue ;;
            esac
            # Framework path -> canonical @rpath/QtX.framework/Versions/A/QtX
            if [[ "$dep" == *Qt*.framework* ]]; then
                _fwbase=$(echo "$dep" | sed -E 's#.*/(Qt[^/]+)\.framework.*#\1#')
                [ -n "$_fwbase" ] || continue
                install_name_tool -change "$dep" "@rpath/${_fwbase}.framework/Versions/A/${_fwbase}" "$_p" 2>/dev/null || true
                continue
            fi
            if [[ "$dep" =~ /Users/|/usr/local/|/opt/homebrew/ ]]; then
                install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$_p" 2>/dev/null || true
            fi
        done
    done
    # Patch flann dylibs we just injected so any lingering absolute liblz4 refs are @rpath-based before broader normalization
    fix_flann_lz4_references_pre_mac "$app_frameworks"
    # Ensure any Qt frameworks required solely by external plugins (e.g. QtTest) are present before macdeployqt
    ensure_qt_frameworks_for_plugins_pre_mac "$app_path"
    # Generic absolute dependency rewrite across app + Plugins
    pre_mac_check_and_patch_dependencies "$app_path"
    # Ensure plugin-required internal framework/data dylibs exist before macdeployqt scans dependencies.
    copy_internal_data_libraries "$app_frameworks"
    auto_detect_and_copy_internal_libs "$app_frameworks"
    echo "📦 Running macdeployqt (staged volume app)..."
    local deploy_args=( "$app_path" -verbose=1 -always-overwrite )
    local bundle_executable=""
    local bundle_executable_path=""
    if [ -f "$app_contents/Info.plist" ] && command -v /usr/libexec/PlistBuddy >/dev/null 2>&1; then
        bundle_executable=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$app_contents/Info.plist" 2>/dev/null || true)
    fi
    if [ -n "$bundle_executable" ] && [ -f "$app_contents/MacOS/$bundle_executable" ]; then
        bundle_executable_path="$app_contents/MacOS/$bundle_executable"
    else
        bundle_executable_path=$(find "$app_contents/MacOS" -maxdepth 1 -type f -perm -111 -print -quit 2>/dev/null || true)
    fi
    if [ -n "$bundle_executable_path" ] && [ -f "$bundle_executable_path" ]; then
        echo "   • macdeployqt executable hint: $bundle_executable_path"
        deploy_args+=( "-executable=$bundle_executable_path" )
    else
        echo "⚠️ Could not determine bundle executable path; running macdeployqt without explicit -executable hint"
    fi
    "$QT_BIN_DIR/macdeployqt" "${deploy_args[@]}" || { echo "❌ macdeployqt failed"; exit 1; }
    # macdeployqt may prune alias filenames even though ManiVault's main binary
    # links the versioned Advanced Docking Framework soname. Recreate the
    # required aliases after Qt deployment so the shipped app resolves the exact
    # load command recorded in its Mach-O binary.
    local qads_runtime_source=""
    for qads_candidate in \
        "$app_frameworks/libqtadvanceddocking-qt6.dylib" \
        "$app_frameworks/libqtadvanceddocking.5.1.1.dylib" \
        "$app_frameworks/libqtadvanceddocking.5.dylib" \
        "$ADVANCED_DOCKING_LIB"; do
        if [ -f "$qads_candidate" ]; then
            qads_runtime_source="$qads_candidate"
            break
        fi
    done
    if [ -z "$qads_runtime_source" ]; then
        echo "❌ Qt Advanced Docking library is missing from the staged app."
        exit 1
    fi
    for qads_alias in libqtadvanceddocking-qt6.dylib libqtadvanceddocking.5.dylib libqtadvanceddocking.5.1.1.dylib; do
        qads_target="$app_frameworks/$qads_alias"
        if [ "$qads_runtime_source" != "$qads_target" ]; then
            cp -f "$qads_runtime_source" "$qads_target"
        fi
        install_name_tool -id "@rpath/$qads_alias" "$qads_target"
    done
    echo "✅ Restored Qt Advanced Docking runtime aliases required by the app executable."
    # Dynamic verification of Qt frameworks actually referenced
    verify_qt_frameworks_present "$app_path"

    # Record the release identity in the application bundle as well as its DMG filename.
    if [ ! -f "$app_contents/Info.plist" ]; then
        echo "❌ Application Info.plist is missing; cannot stamp release version $APP_VERSION." >&2
        exit 1
    fi
    local bundle_build_version="${APP_VERSION%%[-+]*}" plist_key plist_value
    for plist_key in CFBundleShortVersionString CFBundleVersion; do
        if [ "$plist_key" = "CFBundleShortVersionString" ]; then
            plist_value="$APP_VERSION"
        else
            plist_value="$bundle_build_version"
        fi
        if ! /usr/libexec/PlistBuddy -c "Set :$plist_key $plist_value" "$app_contents/Info.plist" 2>/dev/null; then
            /usr/libexec/PlistBuddy -c "Add :$plist_key string $plist_value" "$app_contents/Info.plist" || {
                echo "❌ Could not set $plist_key in the application bundle." >&2
                exit 1
            }
        fi
    done
    echo "🏷️  Application bundle version set to $APP_VERSION ($bundle_build_version)."

    # --- Replace application icon (requested change) ---
    # We do this AFTER macdeployqt so that any plist modifications by macdeployqt do not overwrite ours.
    local icon_source="$APP_ICON_FILE"
    if [ -f "$icon_source" ]; then
        echo "🖼️  Setting custom application icon from $icon_source"
        mkdir -p "$app_contents/Resources"
        cp -f "$icon_source" "$app_contents/Resources/appimage.icns"
        # Update CFBundleIconFile (use name without extension per convention)
        if [ -f "$app_contents/Info.plist" ]; then
            # Try PlistBuddy first; fall back to plutil
            if command -v /usr/libexec/PlistBuddy >/dev/null 2>&1; then
                /usr/libexec/PlistBuddy -c "Delete :CFBundleIconFile" "$app_contents/Info.plist" 2>/dev/null || true
                /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string appimage" "$app_contents/Info.plist" 2>/dev/null || \
                    echo "⚠️ PlistBuddy failed to set CFBundleIconFile"
            else
                plutil -replace CFBundleIconFile -string appimage "$app_contents/Info.plist" 2>/dev/null || \
                    echo "⚠️ plutil failed to set CFBundleIconFile"
            fi
        else
            echo "⚠️ Info.plist not found when attempting to set icon"
        fi
    else
        echo "⚠️ Icon file not found at $icon_source (skipping icon replacement)"
    fi
    # --- New: Attempt to copy additional internal data libraries required by plugins ---
    copy_internal_data_libraries "$app_frameworks"
    # Dynamically detect actually referenced internal libraries (beyond static list) and copy them.
    # Skips common external/Qt/system libs. Enabled by default; disable with AUTO_INTERNAL_LIB_DETECT=false.
    auto_detect_and_copy_internal_libs "$app_frameworks"
    echo "🔧 Final path cleanup and RPATH configuration..."
    # Add Framework RPATHs once per binary (minimal mode optionally uses only @executable_path variant for executables)
    local all_binaries
    all_binaries=$(find "$app_path" -type f \( -name "*.dylib" -o -name "*.so" -o -perm -111 \))
    for bin in $all_binaries; do
        local add_loader=true
        # Prefer keeping both for safety unless MINIMAL_RPATH=true AND file is an executable (not a dylib)
        if [ "$MINIMAL_RPATH" = "true" ] && [[ "$(basename "$bin")" != lib* ]]; then
            add_loader=false
        fi
        # Skip adding RPATHs to internal framework data libs (resolution handled by consumers)
        local basebin="$(basename "$bin")"
        for skiplib in "${INTERNAL_FRAMEWORK_DATA_LIBS[@]}"; do
            if [ "$basebin" = "$skiplib" ]; then
                add_loader=false
                continue 2
            fi
        done
        otool -l "$bin" 2>/dev/null | grep -q "@executable_path/../Frameworks" || install_name_tool -add_rpath "@executable_path/../Frameworks" "$bin" 2>/dev/null || true
        if [ "$add_loader" = true ]; then
            otool -l "$bin" 2>/dev/null | grep -q "@loader_path/../Frameworks" || install_name_tool -add_rpath "@loader_path/../Frameworks" "$bin" 2>/dev/null || true
        fi
        # Normalize any remaining absolute deps to @rpath
        while IFS= read -r dep; do
            [ -z "$dep" ] && continue
            safe_patch_dependency "$bin" "$dep" "@rpath/$(basename "$dep")"
        done < <(otool -L "$bin" 2>/dev/null | awk 'NR>1 {print $1}' | grep -E "/Users/|/usr/local/|/opt/homebrew/" || true)
    done

    # --- Additional targeted dependency rewrites for main executable (ported logic) ---
    patch_main_executable_dependencies "$app_path"
    # Enforce that only approved libraries remain inside Frameworks; others relocated to Plugins
    enforce_framework_policy "$app_path"
    echo "✅ App bundle finalization complete."
}

# Resolve app bundles emitted by single- and multi-configuration CMake generators.
resolve_installed_app_bundle() {
    local install_root="$1"
    local configured_build_type="${BUILD_TYPE:-Release}"
    local candidate
    # Prefer the selected configuration so a stale root-level app cannot mask
    # the bundle produced by the current build.
    for candidate in \
        "$install_root/$configured_build_type/$APP_NAME" \
        "$install_root/Release/$APP_NAME" \
        "$install_root/$APP_NAME"; do
        if [ -d "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

# New: create initial staged volume structure before macdeployqt
create_initial_staging_structure() {
    echo "📁 Creating initial staged volume layout (nested) inside '$INSTALL_DMG_TEMP_DIR' ..."
    local volume_root="$INSTALL_DMG_TEMP_DIR/$VOLUME_NAME"              # This folder becomes DMG root contents
    local nested_dir="$volume_root/$VOLUME_NAME"                        # Actual visible folder inside DMG
    mkdir -p "$nested_dir/License" "$nested_dir/Plugins"
    mkdir -p "$nested_dir/Customization"
    local source_app
    source_app=$(resolve_installed_app_bundle "$INSTALL_DIR") || {
        echo "❌ Source app bundle '$APP_NAME' not found under '$INSTALL_DIR' or its build configuration directory." >&2
        exit 1
    }
    echo "   • Using installed app bundle: $source_app"
    cp -a "$source_app" "$nested_dir/$VOLUME_NAME.app"
    # Applications symlink should live one level ABOVE the nested Cytosplore Viewer folder per updated requirement
    # Final DMG root layout:
    #   Cytosplore Viewer/  (folder containing app, Plugins, etc.)
    #   Applications -> /Applications
    ( cd "$volume_root" && [ -L Applications ] || ln -s /Applications Applications ) 2>/dev/null || true
    # Plugin copy policy: copy only now into nested folder's Plugins directory
    if [ -d "$INSTALL_DIR/Release/Plugins" ]; then
        echo "   • Copying plugins from Release/Plugins (policy: copy only at staging)"
        # Copy plugin dylibs but exclude library dependencies that must live in Frameworks
        find "$INSTALL_DIR/Release/Plugins" -type f -name "*.dylib" \
            ! -name 'libqtadvanceddocking*' ! -name 'libqads*' -exec cp -f {} "$nested_dir/Plugins/" \; 2>/dev/null || true
    elif [ -d "$INSTALL_DIR/Plugins" ]; then
        echo "   • Fallback: copying existing Plugins directory (legacy scenario)"
        # Copy plugin dylibs excluding advanceddocking/qads library files (these belong in Frameworks)
        find "$INSTALL_DIR/Plugins" -type f -name "*.dylib" \
            ! -name 'libqtadvanceddocking*' ! -name 'libqads*' -exec cp -f {} "$nested_dir/Plugins/" \; 2>/dev/null || true
        # Copy non-dylib resources (icons, confs) as-is
        find "$INSTALL_DIR/Plugins" -type f \! -name "*.dylib" -exec cp -f {} "$nested_dir/Plugins/" \; 2>/dev/null || true
    else
        echo "   • No plugin sources found (Release/Plugins or Plugins)"
    fi

    # Optional post-copy exclusion of specific plugin dylibs.
    # Space-separated values in EXCLUDED_PLUGINS, supporting exact names or globs, e.g.:
    # EXCLUDED_PLUGINS="libA.dylib libExampleDataPlugin_p1.4_*.dylib"
    if [ -n "$EXCLUDED_PLUGINS" ]; then
        local excluded removed_any
        for excluded in $EXCLUDED_PLUGINS; do
            removed_any=false
            while IFS= read -r match_path; do
                [ -z "$match_path" ] && continue
                rm -f "$match_path" 2>/dev/null || true
                echo "   • Excluded plugin: $(basename "$match_path")"
                removed_any=true
            done < <(find "$nested_dir/Plugins" -maxdepth 1 -type f -name "$excluded" 2>/dev/null || true)

            if [ "$removed_any" = false ]; then
                echo "   • Exclusion pattern matched nothing: $excluded"
            fi
        done
    fi

    # Stage per-plugin runtime dependency folders (e.g. FreeImage, hwy)
    # Keep these out of Plugins root so Qt does not attempt to load them as plugins.
    if [ -d "$INSTALL_DIR/Release/PluginDependencies" ]; then
        echo "   • Copying PluginDependencies from Release/PluginDependencies"
        mkdir -p "$nested_dir/PluginDependencies"
        cp -a "$INSTALL_DIR/Release/PluginDependencies/." "$nested_dir/PluginDependencies/" 2>/dev/null || true
    elif [ -d "$INSTALL_DIR/PluginDependencies" ]; then
        echo "   • Fallback: copying PluginDependencies from PluginDependencies"
        mkdir -p "$nested_dir/PluginDependencies"
        cp -a "$INSTALL_DIR/PluginDependencies/." "$nested_dir/PluginDependencies/" 2>/dev/null || true
    else
        echo "   • No PluginDependencies directory found"
    fi

    # Plugin dependency folders can persist between package runs. Refresh CUPS
    # from the pinned universal dependency build so these copies cannot retain
    # stale architectures or deployment targets from an older build.
    local cups_runtime="$LIBRARIES_ROOT/cups-${CUPS_VERSION:-2.4.14}/build_universal/lib/libcups.2.dylib"
    if [ -f "$cups_runtime" ] && [ -d "$nested_dir/PluginDependencies" ]; then
        while IFS= read -r -d '' plugin_cups; do
            cp -f "$cups_runtime" "$plugin_cups"
            install_name_tool -id "@rpath/libcups.2.dylib" "$plugin_cups" 2>/dev/null || true
            verify_library "$plugin_cups" || { echo "❌ Verification failed for $plugin_cups"; exit 1; }
            echo "   • Refreshed plugin CUPS runtime: ${plugin_cups#"$nested_dir/"}"
        done < <(find "$nested_dir/PluginDependencies" -type f -name 'libcups.2.dylib' -print0)
    fi

    # Copy debug symbols separately
    if [ -d "$INSTALL_DIR/../debug_symbols" ]; then
        echo "   • Copying debug symbols"
        mkdir -p "$nested_dir/debug_symbols"
        cp -a "$INSTALL_DIR/../debug_symbols/." "$nested_dir/debug_symbols/"
    else
        echo "   • No debug symbols found"
    fi

    # Diagnostic: list staged plugins and ensure forbidden libs are not present
    echo "   • Plugins staged (count): $(find "$nested_dir/Plugins" -type f | wc -l)"
    ls -1 "$nested_dir/Plugins" 2>/dev/null || true
    if ls "$nested_dir/Plugins"/libqtadvanceddocking* 1>/dev/null 2>&1 || ls "$nested_dir/Plugins"/libqads* 1>/dev/null 2>&1; then
        echo "❌ Found advanceddocking/qads library in staged Plugins (not allowed). Aborting packaging." >&2
        ls -l "$nested_dir/Plugins"/libqtadvanceddocking* "$nested_dir/Plugins"/libqads* 2>/dev/null || true
        exit 1
    fi
    if [ -d "$LICENSE_DIR" ]; then echo "   • Copying license"; cp -a "$LICENSE_DIR/." "$nested_dir/License/" 2>/dev/null || true; fi
    if [ "$CUSTOMIZATION_FOLDER_PRESENT" = "true" ]; then
        # --- Robust: Always remove stale files if env var is empty ---
        # --- Robust: Always remove/copy only if env var is set and non-empty ---
        if [ -n "$PROJECTS_SOURCE_FILE" ]; then
            prepare_projects_json "$PROJECTS_SOURCE_FILE" "$nested_dir/Customization/projects.json"
        else
            rm -f "$nested_dir/Customization/projects.json"
            echo "   • Skipping and removing projects.json (PROJECTS_SOURCE_FILE is empty)"
        fi
        if [ -n "$APP_CONFIG_SOURCE_FILE" ] && [ -f "$APP_CONFIG_SOURCE_FILE" ]; then
            cp -f "$APP_CONFIG_SOURCE_FILE" "$nested_dir/Customization/app.json" 2>/dev/null || true
            echo "   • Copied app.json from $APP_CONFIG_SOURCE_FILE"
        else
            rm -f "$nested_dir/Customization/app.json"
            echo "⚠️ app.json source not found at $APP_CONFIG_SOURCE_FILE or variable is empty; removed any stale app.json"
        fi
        if [ -n "$ASSETS_DIR" ] && [ -d "$ASSETS_DIR" ]; then
            echo "   • Copying assets/ -> Customization/assets"
            mkdir -p "$nested_dir/Customization/assets"
            cp -a "$ASSETS_DIR/." "$nested_dir/Customization/assets/" 2>/dev/null || true
        else
            rm -rf "$nested_dir/Customization/assets"
            echo "   • No assets/ directory at $ASSETS_DIR (skipping and removing any stale assets/)"
        fi
        if [ -n "$LICENSE_DIR" ] && [ -d "$LICENSE_DIR" ]; then
            echo "   • Copying license"
            cp -a "$LICENSE_DIR/." "$nested_dir/License/" 2>/dev/null || true
        else
            rm -rf "$nested_dir/License"
            echo "   • No license directory at $LICENSE_DIR (skipping and removing any stale License/)"
        fi
        if [ -n "$DMG_BACKGROUND_IMAGE" ] && [ -f "$DMG_BACKGROUND_IMAGE" ] && [ "$ENABLE_DMG_BACKGROUND" = "true" ]; then
            echo "   • Using DMG background image: $DMG_BACKGROUND_IMAGE"
            # (background image logic remains unchanged)
        else
            echo "   • Skipping DMG background image (DMG_BACKGROUND_IMAGE is empty or not enabled)"
        fi
        if [ -n "$APP_ICON_FILE" ] && [ -f "$APP_ICON_FILE" ]; then
            echo "   • Using app icon: $APP_ICON_FILE"
            # (icon copy logic remains unchanged)
        else
            echo "   • Skipping app icon (APP_ICON_FILE is empty or not found)"
        fi
    else
        echo "   • Skipping Customization folder and materials for this profile"
        # Keep Customization present but empty for profiles that disable customization content.
        # The folder icon is applied later in this function.
        find "$nested_dir/Customization" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
    fi

    # Apply folder icons after all content is staged so later copies or cleanup
    # cannot remove the custom Finder icon metadata. Keep License present even
    # when a project has no bundled license files.
    mkdir -p "$nested_dir/License"
    if command -v swift >/dev/null 2>&1; then
        swift "$SCRIPTS_ROOT/package/apply_default_folder_icons.swift" \
            "$nested_dir" "image:$MAIN_FOLDER_ICON_FILE" \
            "$nested_dir/License" doc.text.fill \
            "$nested_dir/Plugins" puzzlepiece.fill \
            "$nested_dir/Customization" slider.horizontal.3 \
            "$nested_dir/Customization/assets" photo.stack.fill \
            "$nested_dir/PluginDependencies" link \
            || echo "⚠️ Default folder icons could not be applied; standard folder icons will be used."
    else
        echo "⚠️ Swift is unavailable; standard folder icons will be used."
    fi

    echo "✅ Initial staged volume ready (nested folder): $nested_dir"
}

# Enhanced library injection borrowed & condensed from reference script
inject_additional_libraries() { # target_frameworks_dir
    local target="$1"
    mkdir -p "$target"

    # Ordered list of candidate libs
    local libs=( \
        "$LIBRARIES_ROOT/lz4-${LZ4_VERSION:-1.9.4}/build_universal/lib/liblz4.1.dylib" \
        "$LIBRARIES_ROOT/openmp-${OPENMP_VERSION:-21.1.2}/build_universal/lib/libomp.dylib" \
        "$LIBRARIES_ROOT/cups-${CUPS_VERSION:-2.4.14}/build_universal/lib/libcups.2.dylib" \
        "$LIBRARIES_ROOT/flann/build_universal/lib/libflann.dylib" \
        "$LIBRARIES_ROOT/flann/build_universal/lib/libflann_cpp.1.9.dylib" \
        "$ADVANCED_DOCKING_LIB" \
        "$VULKAN_LIB" \
    )
    for path in "${libs[@]}"; do
        if [ -f "$path" ]; then
            local name=$(basename "$path")
            echo "   - Copying $name"
            cp -f "$path" "$target/$name"
            install_name_tool -id "@rpath/$name" "$target/$name" 2>/dev/null || true
            verify_library "$target/$name" || { echo "❌ Verification failed for $name"; exit 1; }
            COPIED_LIB_COUNT=$((COPIED_LIB_COUNT + 1))
        else
            echo "⚠️ Missing optional library: $path"
        fi
    done

    # FLANN symlink expectations
    if [ -f "$target/libflann.dylib" ]; then
        [ -e "$target/libflann.1.9.dylib" ] || ln -sf libflann.dylib "$target/libflann.1.9.dylib" || true
        [ -e "$target/libflann.1.9.2.dylib" ] || ln -sf libflann.dylib "$target/libflann.1.9.2.dylib" || true
    fi
    if [ -f "$target/libflann_cpp.1.9.dylib" ]; then
        [ -e "$target/libflann_cpp.1.9.2.dylib" ] || ln -sf libflann_cpp.1.9.dylib "$target/libflann_cpp.1.9.2.dylib" || true
        [ -e "$target/libflann_cpp.dylib" ] || ln -sf libflann_cpp.1.9.dylib "$target/libflann_cpp.dylib" || true
    fi
    if [ -f "$target/libvulkan.1.4.350.dylib" ]; then
        [ -e "$target/libvulkan.1.dylib" ] || ln -sf libvulkan.1.4.350.dylib "$target/libvulkan.1.dylib" || true
        [ -e "$target/libvulkan.dylib" ] || ln -sf libvulkan.1.dylib "$target/libvulkan.dylib" || true
    fi
    # Ensure all expected advanced docking aliases are present.
    # Some binaries link against the major-soname form (.4) while others use
    # the qt6 or fully versioned filename; keep all three to avoid dyld misses.
    local qads_src=""
    for cand in \
        "$target/libqtadvanceddocking-qt6.dylib" \
        "$target/libqtadvanceddocking.5.1.1.dylib" \
        "$target/$(basename "$ADVANCED_DOCKING_LIB")"; do
        if [ -f "$cand" ]; then
            qads_src="$cand"
            break
        fi
    done
    if [ -n "$qads_src" ]; then
        for alias in libqtadvanceddocking-qt6.dylib libqtadvanceddocking.5.1.1.dylib libqtadvanceddocking.5.dylib; do
            [ "$qads_src" = "$target/$alias" ] || cp -f "$qads_src" "$target/$alias" 2>/dev/null || true
            [ -f "$target/$alias" ] && install_name_tool -id "@rpath/$alias" "$target/$alias" 2>/dev/null || true
        done
    fi
    # Attempt to bundle libiconv.2.dylib if not already present (parity with legacy behavior)
    if [ ! -f "$target/libiconv.2.dylib" ]; then
        for cand in \
            "/opt/miniconda3/lib/libiconv.2.dylib" \
            "/usr/local/lib/libiconv.2.dylib" \
            "/opt/homebrew/lib/libiconv.2.dylib"; do
            if [ -f "$cand" ]; then
                echo "   - Copying libiconv.2.dylib from $cand"
                cp -f "$cand" "$target/libiconv.2.dylib" 2>/dev/null || true
                install_name_tool -id "@rpath/libiconv.2.dylib" "$target/libiconv.2.dylib" 2>/dev/null || true
                break
            fi
        done
    fi

    # Shared dependencies added through the project database declare their
    # runtime files in the manifest. Stage them here; framework policy below
    # keeps non-approved third-party libraries in the sibling Plugins folder.
    local dependency_manifest="${DEPENDENCY_MANIFEST_FILE:-$SCRIPTS_ROOT/../installer_database/dependencies.json}"
    python3 "$SCRIPTS_ROOT/package/stage_dependency_libraries.py" "$target" --manifest "$dependency_manifest"
    for path in "$target"/*.dylib; do
        [ -f "$path" ] || continue
        local name="$(basename "$path")"
        install_name_tool -id "@rpath/$name" "$path" 2>/dev/null || true
        verify_library "$path" || { echo "❌ Verification failed for $name"; exit 1; }
    done
}

# Helper: test whether a basename is in ALLOWED_FRAMEWORK_LIBS
is_allowed_framework_lib() {
    local name="$1"; local a
    # Allow exact whitelist matches
    for a in "${ALLOWED_FRAMEWORK_LIBS[@]}"; do
        [ "$a" = "$name" ] && return 0
    done
    # Also allow common variant prefixes so versioned/unversioned builds are accepted
    case "$name" in
        libqtadvanceddocking*|libqads* ) return 0 ;;
    esac
    return 1
}

# Ensure that any non-allowed dylibs that slipped into Frameworks are moved to Plugins.
enforce_framework_policy() { # app_path
    local app_path="$1"
    local fw_dir="$app_path/Contents/Frameworks"
    local plugins_dir="$(dirname "$app_path")/Plugins"
    [ -d "$fw_dir" ] || return 0
    mkdir -p "$plugins_dir"
    local moved=0 kept=0
    while IFS= read -r -d '' dylib; do
        local base="$(basename "$dylib")"
        if is_allowed_framework_lib "$base"; then
            kept=$((kept+1))
            continue
        fi
        echo "🚚 Moving non-allowed framework lib -> Plugins: $base"
        mv -f "$dylib" "$plugins_dir/$base" 2>/dev/null || cp -f "$dylib" "$plugins_dir/$base" && rm -f "$dylib" 2>/dev/null || true
        moved=$((moved+1))
    done < <(find "$fw_dir" -maxdepth 1 -type f -name 'lib*.dylib' -print0 2>/dev/null)
    echo "✅ Framework policy enforcement (kept=$kept moved=$moved)"
    # Add RPATHs for any binaries that may need to locate these moved libs
    ensure_plugins_rpaths "$app_path"
}

# Add @executable_path/../Plugins and @loader_path/../Plugins RPATHs where missing
ensure_plugins_rpaths() { # app_path
    local app_path="$1"
    local binaries
    binaries=$(find "$app_path" -type f \( -name '*.dylib' -o -name '*.so' -o -perm -111 \) 2>/dev/null)
    for b in $binaries; do
        chmod u+w "$b" 2>/dev/null || true
        otool -l "$b" 2>/dev/null | grep -q '@executable_path/../Plugins' || install_name_tool -add_rpath '@executable_path/../Plugins' "$b" 2>/dev/null || true
        otool -l "$b" 2>/dev/null | grep -q '@loader_path/../Plugins' || install_name_tool -add_rpath '@loader_path/../Plugins' "$b" 2>/dev/null || true
    done
}

# Patch specific dependencies inside the main executable to explicit @executable_path/../Frameworks paths.
# This mirrors legacy behavior; typically @rpath is sufficient, but some downstream launchers/tools
# expect resolved install_name entries. Controlled via ENABLE_MAIN_EXPLICIT_PATHS (default true).
patch_main_executable_dependencies() { # app_bundle_path
    local app_path="$1"
    local enable="${ENABLE_MAIN_EXPLICIT_PATHS:-true}"
    [ "$enable" = "true" ] || { echo "ℹ️ Skipping explicit main executable dependency rewrites (disabled)"; return 0; }
    local exe
    exe=$(find "$app_path/Contents/MacOS" -type f -perm -111 -maxdepth 1 -print -quit 2>/dev/null || true)
    [ -n "$exe" ] || { echo "⚠️ Main executable not found for explicit dependency patch"; return 0; }
    echo "🔧 Applying explicit dependency path rewrites to $(basename "$exe")"
    # Rationale: Pin critical internal libs to @executable_path to ensure deterministic
    # resolution regardless of future RPATH changes and to improve diagnostic clarity.
    # Map of old->new (space separated). Only patch if old appears in otool output.
    local mappings=(
        # Internal data libs only pinned if PIN_INTERNAL_LIBS=true (otherwise we retain @rpath form)
        $( [ "$PIN_INTERNAL_LIBS" = "true" ] && echo '"@rpath/libMV_Public.dylib:@executable_path/../Frameworks/libMV_Public.dylib"' )
        $( [ "$PIN_INTERNAL_LIBS" = "true" ] && echo '"@rpath/libImageData.dylib:@executable_path/../Frameworks/libImageData.dylib"' )
        "@rpath/libomp.dylib:@executable_path/../Frameworks/libomp.dylib"
        "@rpath/libcups.2.dylib:@executable_path/../Frameworks/libcups.2.dylib"
        "@rpath/libqtadvanceddocking.5.dylib:@executable_path/../Frameworks/libqtadvanceddocking.5.dylib"
        "@rpath/libqtadvanceddocking.5.1.1.dylib:@executable_path/../Frameworks/libqtadvanceddocking.5.1.1.dylib"
        "@rpath/libqtadvanceddocking-qt6.dylib:@executable_path/../Frameworks/libqtadvanceddocking-qt6.dylib"
        "@rpath/liblz4.1.dylib:@executable_path/../Frameworks/liblz4.1.dylib"
    )
    local pair old new
    for pair in "${mappings[@]}"; do
        old="${pair%%:*}"; new="${pair##*:}"
        if otool -L "$exe" 2>/dev/null | grep -q "$old"; then
            install_name_tool -change "$old" "$new" "$exe" 2>/dev/null || echo "⚠️ Failed to rewrite $old -> $new"
        fi
    done
    echo "✅ Explicit dependency patching for main executable complete"
}

# Dedupe RPATH entries in a binary (remove duplicates while preserving first occurrence order)
dedupe_rpaths() { # file
    local bin="$1"
    [ -f "$bin" ] || return 0
    local rpaths unique seen tmpfile
    rpaths=$(otool -l "$bin" 2>/dev/null | awk '/LC_RPATH/{getline;getline;print $2}') || true
    [ -n "$rpaths" ] || return 0
    local line
    for line in $rpaths; do
        if printf '%s\n' "$seen" | grep -qx "$line"; then
            continue
        fi
        seen="$seen\n$line"
        unique+=" $line"
    done
    # Count original vs unique; if same length no action.
    local orig_count uniq_count
    orig_count=$(printf '%s\n' $rpaths | wc -l | tr -d ' ')
    uniq_count=$(printf '%s\n' $unique | wc -w | tr -d ' ')
    [ "$orig_count" = "$uniq_count" ] && return 0
    chmod u+w "$bin" 2>/dev/null || true
    # Delete all then re-add unique (order preserved by iteration)
    for line in $rpaths; do install_name_tool -delete_rpath "$line" "$bin" 2>/dev/null || true; done
    for line in $unique; do install_name_tool -add_rpath "$line" "$bin" 2>/dev/null || true; done
    echo "   • Deduped RPATHs in $(basename "$bin") ($orig_count -> $uniq_count)"
}

# Scan for duplicate dependency load commands (same dylib listed more than once)
scan_duplicate_loads() { # file
    local bin="$1"
    otool -L "$bin" 2>/dev/null | awk 'NR>1 {print $1}' | sort | uniq -d || true
}

# Validate presence of allowed framework libs and optionally abort if missing.
validate_framework_libs() { # app_bundle
    local app="$1"; local fw="$app/Contents/Frameworks"; local missing=()

    has_any_flann_variant() { # frameworks_dir family_prefix
        local dir="$1"; local fam="$2"
        [ -f "$dir/${fam}.dylib" ] && return 0
        [ -f "$dir/${fam}.1.9.dylib" ] && return 0
        [ -f "$dir/${fam}.1.9.2.dylib" ] && return 0
        return 1
    }

    for lib in "${ALLOWED_FRAMEWORK_LIBS[@]}"; do
        case "$lib" in
            libflann.dylib|libflann.1.9.dylib|libflann.1.9.2.dylib|libflann_cpp.dylib|libflann_cpp.1.9.dylib|libflann_cpp.1.9.2.dylib)
                # Handled by family-level checks below so aliases are optional.
                continue
                ;;
            libqtadvanceddocking-qt6.dylib|libqtadvanceddocking.5.dylib|libqtadvanceddocking.5.1.1.dylib)
                # Validate this library family together below. The main app may
                # reference different names depending on the core release.
                continue
                ;;
        esac
        [ -f "$fw/$lib" ] || missing+=("$lib")
    done

    has_any_flann_variant "$fw" "libflann" || missing+=("libflann{.dylib|.1.9.dylib|.1.9.2.dylib}")
    has_any_flann_variant "$fw" "libflann_cpp" || missing+=("libflann_cpp{.dylib|.1.9.dylib|.1.9.2.dylib}")
    for qads_alias in libqtadvanceddocking-qt6.dylib libqtadvanceddocking.5.dylib libqtadvanceddocking.5.1.1.dylib; do
        [ -f "$fw/$qads_alias" ] || missing+=("$qads_alias")
    done

    if [ ${#missing[@]} -gt 0 ]; then
        echo "❌ Missing expected framework libs: ${missing[*]}"; return 1
    fi
    return 0
}

# Ensure universal LZ4 presence (mirrors legacy logic expectation)
ensure_lz4_present() {
    local lz4_path="$LIBRARIES_ROOT/lz4-${LZ4_VERSION:-1.9.4}/build_universal/lib/liblz4.1.dylib"
    if [ ! -f "$lz4_path" ]; then
        echo "⚠️ LZ4 universal library not found at $lz4_path (continuing; may already be bundled elsewhere)"
        return 1
    fi
    return 0
}

# Verify no unexpected absolute dependency paths remain in a tree
verify_no_abs_paths() { # dir
    local root="$1"; local allow_fail="${2:-false}"; local tmp
    [ -d "$root" ] || return 0
    tmp=$(mktemp)
    # Collect binaries
    find "$root" -type f \( -name "*.dylib" -o -name "*.so" -o -perm -111 \) -print0 | \
        xargs -0 otool -L 2>/dev/null | awk '{print $1}' | \
        grep -E '/Users/|/usr/local/|/opt/homebrew/' | \
        grep -v -E '^/System/|^/usr/lib/lib(System|c\+\+|resolv)' || true > "$tmp"
    if [ -s "$tmp" ]; then
        echo "❌ Found remaining absolute dependency references in $root:" >&2
        sed 's/^/    /' "$tmp" >&2
        if [ "$allow_fail" != "true" ]; then
            rm -f "$tmp"; return 1
        fi
    else
        echo "✅ No disallowed absolute dependency paths remain in $root"
    fi
    rm -f "$tmp"
    return 0
}

# Code signing (local identity or ad-hoc when LOCAL_IDENTITY='-')
sign_app_bundle() {
    local app_path="$INSTALL_DMG_TEMP_DIR/$VOLUME_NAME/$VOLUME_NAME/$VOLUME_NAME.app"
    local staged_root="$(dirname "$app_path")"
    [ -d "$app_path" ] || { echo "❌ Cannot sign; app missing at $app_path"; return 1; }
    local identity="$LOCAL_IDENTITY"
    SIGNING_MODE=$([ "$identity" = "-" ] && echo 'ad-hoc' || echo "identity:$identity")
    echo "🔏 Signing mode: $SIGNING_MODE"
    local sign_failed=0
    local sign_output

    sign_target() {
        local target="$1"
        sign_output=$(codesign --force --sign "$identity" "$target" 2>&1) || {
            echo "❌ Code signing failed for: $target"
            echo "$sign_output"
            sign_failed=1
            return 1
        }
    }

    # Sign nested helper app bundles inside frameworks before sealing the frameworks.
    while IFS= read -r -d '' helper_app; do
        sign_target "$helper_app"
    done < <(find "$app_path/Contents/Frameworks" -type d -name "*.app" -print0 2>/dev/null || true)

    # Then sign framework bundles themselves.
    while IFS= read -r -d '' fw; do
        sign_target "$fw"
    done < <(find "$app_path/Contents/Frameworks" -type d -name "*.framework" -print0 2>/dev/null || true)

    # Sign standalone dylibs in Contents/Frameworks (not inside .framework bundles).
    while IFS= read -r -d '' fw_bin; do
        sign_target "$fw_bin"
    done < <(find "$app_path/Contents/Frameworks" -maxdepth 1 -type f \( -name "*.dylib" -o -name "*.so" -o -perm -111 \) -print0 2>/dev/null || true)

    # Sign Qt plug-ins inside the app bundle before the app executable is sealed.
    while IFS= read -r -d '' plugin; do
        sign_target "$plugin"
    done < <(find "$app_path/Contents/PlugIns" -type f \( -name "*.dylib" -o -name "*.so" -o -perm -111 \) -print0 2>/dev/null || true)

    # Sign PluginDependencies and Plugins directories (sibling to app bundle).
    while IFS= read -r -d '' f; do
        sign_target "$f"
    done < <(find "$staged_root/PluginDependencies" "$staged_root/Plugins" -type f \( -name "*.dylib" -o -name "*.so" \) -print0 2>/dev/null || true)

    # Sign the app executable after its framework dependencies are sealed.
    while IFS= read -r -d '' exe; do
        sign_target "$exe"
    done < <(find "$app_path/Contents/MacOS" -maxdepth 1 -type f -perm -111 -print0 2>/dev/null || true)

    # Finally sign the app bundle root.
    sign_target "$app_path"

    if [ $sign_failed -ne 0 ]; then
        echo "❌ One or more staged binaries failed code signing"
        return 1
    fi

    # Verify the app bundle and every staged dylib/helper that can be loaded at runtime.
    while IFS= read -r -d '' f; do
        if ! sign_output=$(codesign --verify --strict --verbose=2 "$f" 2>&1); then
            echo "❌ Code signature verification failed for: $f"
            echo "$sign_output"
            return 1
        fi
    done < <(find "$app_path/Contents" "$staged_root/Plugins" "$staged_root/PluginDependencies" -type f \( -name "*.dylib" -o -name "*.so" -o -perm -111 \) -print0 2>/dev/null)

    echo "✅ Staged app payload signed and verified"
}

# Create DMG from staged volume directory

create_dmg() {
    echo "📦 Creating DMG with dmgbuild (nested folder at root)..."

    local volume_dir="$INSTALL_DMG_TEMP_DIR/$VOLUME_NAME"
    [ -d "$volume_dir/$VOLUME_NAME" ] || {
        echo "❌ Nested folder missing: $volume_dir/$VOLUME_NAME"
        return 1
    }

    if ! python3 -c "import dmgbuild" >/dev/null 2>&1; then
        echo "❌ dmgbuild is not installed for python3." >&2
        echo "   Run: python3 -m pip install --user dmgbuild" >&2
        return 1
    fi

    local profile_suffix="${PROFILE_NAME:-project}"
    FINAL_DMG_PATH="$OUTPUT_DIR/${VOLUME_NAME}_${profile_suffix}_v${APP_VERSION}_$(date +'%Y%m%d_%H%M%S').dmg"

    local temp_root settings bg_value="None" bg_ext
    temp_root=$(mktemp -d "${TMPDIR:-/tmp}/mvdmg.XXXXXX") || {
        echo "❌ Could not create temporary directory."
        return 1
    }
    ACTIVE_DMG_TEMP_DIR="$temp_root"
    settings="$temp_root/dmgbuild_settings.py"

    # ---------------------------------------------------------
    # 1. Background image (copied into temp dir, keeps its extension)
    # ---------------------------------------------------------
    DMG_BACKGROUND_STATUS="disabled"
    if [ "$ENABLE_DMG_BACKGROUND" = "true" ]; then
        if [ -f "$DMG_BACKGROUND_IMAGE" ]; then
            bg_ext="${DMG_BACKGROUND_IMAGE##*.}"
            cp -f "$DMG_BACKGROUND_IMAGE" "$temp_root/background.$bg_ext"
            bg_value="\"$temp_root/background.$bg_ext\""
            DMG_BACKGROUND_STATUS="applied"
            echo "🖼️ Background image: $DMG_BACKGROUND_IMAGE"
        else
            DMG_BACKGROUND_STATUS="image-missing"
            echo "⚠️ Background image not found: $DMG_BACKGROUND_IMAGE"
        fi
    fi

    # ---------------------------------------------------------
    # 2. Icon positions (window points)
    # ---------------------------------------------------------
    local left_x=$((DMG_ICON_MARGIN + 80))
    local right_x=$((DMG_WIDTH - DMG_ICON_SIZE - DMG_ICON_MARGIN))
    local center_y=$(((DMG_HEIGHT / 2) - 20))

    # ---------------------------------------------------------
    # 3. Write dmgbuild settings
    # ---------------------------------------------------------
    cat > "$settings" <<EOF
format = "UDZO"
filesystem = "HFS+"
volume_name = "$VOLUME_NAME"

files = ["$volume_dir/$VOLUME_NAME"]
symlinks = {"Applications": "/Applications"}

background = $bg_value

show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

window_rect = ((100, 100), ($DMG_WIDTH, $DMG_HEIGHT))
default_view = "icon-view"
show_icon_preview = False
include_icon_view_settings = True
include_list_view_settings = False
arrange_by = None
grid_offset = (0, 0)
grid_spacing = 100
scroll_position = (0, 0)
label_pos = "bottom"
text_size = 12
icon_size = $DMG_ICON_SIZE

icon_locations = {
    "$VOLUME_NAME": ($left_x, $center_y),
    "Applications": ($right_x, $center_y),
}
EOF

    # ---------------------------------------------------------
    # 4. Build the DMG (no Finder, no mounting by hand)
    # ---------------------------------------------------------
    echo "💿 Building DMG with dmgbuild..."
    if ! python3 -m dmgbuild -s "$settings" "$VOLUME_NAME" "$FINAL_DMG_PATH"; then
        echo "❌ dmgbuild failed."
        rm -f "$FINAL_DMG_PATH"
        rm -rf "$temp_root"
        ACTIVE_DMG_TEMP_DIR=""
        return 1
    fi

    # ---------------------------------------------------------
    # 5. Verify
    # ---------------------------------------------------------
    if [ ! -s "$FINAL_DMG_PATH" ] || ! hdiutil verify "$FINAL_DMG_PATH" >/dev/null; then
        echo "❌ DMG creation or verification failed."
        rm -f "$FINAL_DMG_PATH"
        rm -rf "$temp_root"
        ACTIVE_DMG_TEMP_DIR=""
        return 1
    fi
    echo "✅ DMG integrity verified."

    # ---------------------------------------------------------
    # 6. Post-build validation (unchanged from original)
    # ---------------------------------------------------------
    local staged_app_path="$INSTALL_DMG_TEMP_DIR/$VOLUME_NAME/$VOLUME_NAME/$VOLUME_NAME.app"
    if [ -d "$staged_app_path" ]; then
        echo "🔍 Post-package validation (framework libs + RPATH hygiene)"
        if validate_framework_libs "$staged_app_path"; then
            local main_exe
            main_exe=$(find "$staged_app_path/Contents/MacOS" -maxdepth 1 -type f -perm -111 -print -quit 2>/dev/null || true)
            if [ -n "$main_exe" ]; then
                dedupe_rpaths "$main_exe" || true
                local dups
                dups=$(scan_duplicate_loads "$main_exe")
                if [ -n "$dups" ]; then
                    echo "⚠️ Duplicate dependency load commands detected:"
                    echo "$dups" | sed 's/^/   - /'
                fi
            fi
        else
            echo "⚠️ Validation reported missing framework libs (continuing)."
        fi
    fi

    rm -rf "$temp_root"
    ACTIVE_DMG_TEMP_DIR=""

    echo ""
    echo "=========================================="
    echo "✅ DMG CREATED SUCCESSFULLY"
    echo "📦 File: $FINAL_DMG_PATH"
    echo "🖼️ Background: $DMG_BACKGROUND_STATUS"
    echo "=========================================="
}

# Notarization stub (expand if credentials available)
notarize_dmg() {
    local dmg="$1"
    echo "ℹ️ Notarization stub invoked for $dmg (no operation)." # Placeholder; integrate notarytool if needed
}

# Patch RPATHs and dependency references for plugin dylibs so they can locate
# internal Framework libraries when loaded at runtime from the Plugins folder
# inside the final DMG volume. This function is intentionally idempotent so it
# can be re-run without harm.
patch_plugin_rpaths() {
    echo "🔧 Patching plugin RPATHs (nested layout)..."
    local plugin_dir="$INSTALL_DMG_TEMP_DIR/$VOLUME_NAME/$VOLUME_NAME/Plugins"
    local app_frameworks="$INSTALL_DMG_TEMP_DIR/$VOLUME_NAME/$VOLUME_NAME/$VOLUME_NAME.app/Contents/Frameworks"
    # NOTE: Any previous references to tmp_refs here were erroneous (leftover from framework auto-detect scope).
    # This function should only touch actual plugin dylibs in $plugin_dir.
    # Collect plugin dylibs (non-recursive – adjust if nested structure is introduced later)
    local plugins=()
    while IFS= read -r -d '' p; do plugins+=("$p"); done < <(find "$plugin_dir" -type f -name "*.dylib" -maxdepth 1 -print0 2>/dev/null || true)

    if [ ${#plugins[@]} -eq 0 ]; then
        echo "ℹ️ No plugin dylibs found to patch"; return 0; fi

    local added_rpath_count=0 patched_dep_count=0 file
    for file in "${plugins[@]}"; do
        chmod u+w "$file" 2>/dev/null || true
        local plugin_name
        plugin_name="$(basename "$file" | sed -E 's/^lib(.*)_p[^_]*_c.*\.dylib$/\1/')"

        # Ensure required RPATH entries (minimal mode: only @loader_path/../Frameworks for plugin dylibs)
        if ! otool -l "$file" 2>/dev/null | grep -q "@loader_path/../Frameworks"; then
            install_name_tool -add_rpath "@loader_path/../Frameworks" "$file" 2>/dev/null && added_rpath_count=$((added_rpath_count+1)) || true
        fi
        # In nested layout, plugins live beside app bundle; this points to app Frameworks.
        if ! otool -l "$file" 2>/dev/null | grep -q "@loader_path/../$VOLUME_NAME.app/Contents/Frameworks"; then
            install_name_tool -add_rpath "@loader_path/../$VOLUME_NAME.app/Contents/Frameworks" "$file" 2>/dev/null && added_rpath_count=$((added_rpath_count+1)) || true
        fi
        # Allow same-folder plugin dependency resolution (e.g., libPointData.dylib in Plugins).
        if ! otool -l "$file" 2>/dev/null | grep -q "path @loader_path (offset"; then
            install_name_tool -add_rpath "@loader_path" "$file" 2>/dev/null && added_rpath_count=$((added_rpath_count+1)) || true
        fi
        # Prefer per-plugin dependency folder when present (e.g., PluginDependencies/ImageLoaderPlugin).
        if [ -n "$plugin_name" ] && [ -d "$INSTALL_DMG_TEMP_DIR/$VOLUME_NAME/$VOLUME_NAME/PluginDependencies/$plugin_name" ]; then
            if ! otool -l "$file" 2>/dev/null | grep -q "@loader_path/../PluginDependencies/$plugin_name"; then
                install_name_tool -add_rpath "@loader_path/../PluginDependencies/$plugin_name" "$file" 2>/dev/null && added_rpath_count=$((added_rpath_count+1)) || true
            fi
        fi
        if [ "$MINIMAL_RPATH" != "true" ]; then
            if ! otool -l "$file" 2>/dev/null | grep -q "@executable_path/../Frameworks"; then
                install_name_tool -add_rpath "@executable_path/../Frameworks" "$file" 2>/dev/null && added_rpath_count=$((added_rpath_count+1)) || true
            fi
        fi

        # Rewrite absolute dependencies pointing to local build locations -> @rpath/<name>
        # Use 'NR>1' to skip the header line; append '|| true' after grep to neutralize non-zero exit when no matches
        while IFS= read -r dep; do
            [ -z "$dep" ] && continue
            case "$dep" in
                */System/Library/*|/usr/lib/libSystem.*|/usr/lib/libc++*|/usr/lib/libresolv*) continue;;
            esac
            local base="$(basename "$dep")"
            if install_name_tool -change "$dep" "@rpath/$base" "$file" 2>/dev/null; then
                patched_dep_count=$((patched_dep_count+1))
            fi
        done < <(otool -L "$file" 2>/dev/null | awk 'NR>1 {print $1}' | grep -E '/Users/|/usr/local/|/opt/homebrew/' || true)

        # If the plugin directly references sibling internal libs by full path inside the bundle,
        # normalize them to @rpath as well (sometimes happens after ad‑hoc builds)
        while IFS= read -r dep; do
            [ -z "$dep" ] && continue
            local base="$(basename "$dep")"
            if install_name_tool -change "$dep" "@rpath/$base" "$file" 2>/dev/null; then
                patched_dep_count=$((patched_dep_count+1))
            fi
        done < <(otool -L "$file" 2>/dev/null | awk 'NR>1 {print $1}' | grep -F "$app_frameworks" 2>/dev/null || true)

        # Rewrite inter-plugin dependencies from @rpath/libXPlugin*.dylib -> @loader_path/libXPlugin*.dylib
        # so that plugins only live in the Plugins directory and are not required in Frameworks.
        while IFS= read -r idep; do
            [ -z "$idep" ] && continue
            local base="$(basename "$idep")"
            if install_name_tool -change "$idep" "@loader_path/$base" "$file" 2>/dev/null; then
                patched_dep_count=$((patched_dep_count+1))
            fi
        done < <(otool -L "$file" 2>/dev/null | awk 'NR>1 {print $1}' | grep -E '^@rpath/lib.*Plugin.*\.dylib' || true)

        # If a dylib was moved from Frameworks -> Plugins, it may still carry Qt framework
        # references in the form @loader_path/QtX.framework/... which now points to Plugins.
        # Normalize these to @rpath/QtX.framework/... so they resolve via plugin RPATH entries.
        while IFS= read -r qdep; do
            [ -z "$qdep" ] && continue
            local qnew="@rpath/${qdep#@loader_path/}"
            if install_name_tool -change "$qdep" "$qnew" "$file" 2>/dev/null; then
                patched_dep_count=$((patched_dep_count+1))
            fi
        done < <(otool -L "$file" 2>/dev/null | awk 'NR>1 {print $1}' | grep -E '^@loader_path/Qt[^/]+\.framework/Versions/A/Qt[^/]+$' || true)

        # Normalize @loader_path/libX.dylib when the library is not expected to be
        # physically co-located with the plugin (common for cups/omp/lz4/flann in Frameworks).
        while IFS= read -r ldep; do
            [ -z "$ldep" ] && continue
            local base="${ldep#@loader_path/}"
            # Keep explicit inter-plugin local links unchanged.
            [[ "$base" == *Plugin*.dylib ]] && continue
            if [ -f "$app_frameworks/$base" ] || [ -f "$plugin_dir/$base" ]; then
                if install_name_tool -change "$ldep" "@rpath/$base" "$file" 2>/dev/null; then
                    patched_dep_count=$((patched_dep_count+1))
                fi
            fi
        done < <(otool -L "$file" 2>/dev/null | awk 'NR>1 {print $1}' | grep -E '^@loader_path/lib[^/]+\.dylib$' || true)
    done

    echo "✅ Plugin RPATH patching complete (added_rpaths=$added_rpath_count, deps_rewritten=$patched_dep_count)"
}

# Remove any plugin libraries accidentally copied into Frameworks (due to earlier runs) if
# nothing outside the Plugins directory depends on them. This keeps packaging tidy.
cleanup_framework_plugin_duplicates() {
    local app_frameworks="$INSTALL_DMG_TEMP_DIR/$VOLUME_NAME/$VOLUME_NAME/$VOLUME_NAME.app/Contents/Frameworks"
    local plugin_dir="$INSTALL_DMG_TEMP_DIR/$VOLUME_NAME/$VOLUME_NAME/Plugins"
    [ -d "$app_frameworks" ] || return 0
    [ -d "$plugin_dir" ] || return 0
    local removed=0 kept=0
    while IFS= read -r -d '' fw_plugin; do
        local base="$(basename "$fw_plugin")"
        # Only consider if a counterpart exists in Plugins dir
        [ -f "$plugin_dir/$base" ] || continue
        # Check if any binary OUTSIDE Plugins still links to @rpath/$base or @executable_path/../Frameworks/$base
    if grep -rl --null "$base" "$INSTALL_DMG_TEMP_DIR/$VOLUME_NAME/$VOLUME_NAME/$VOLUME_NAME.app/Contents" 2>/dev/null | grep -v '/Plugins/' | head -n1 >/dev/null; then
            kept=$((kept+1))
            continue
        fi
        echo "🧹 Removing duplicate framework plugin: $base"
        rm -f "$fw_plugin" 2>/dev/null || true
        removed=$((removed+1))
    done < <(find "$app_frameworks" -maxdepth 1 -type f -name 'lib*Plugin*.dylib' -print0 2>/dev/null)
    echo "✅ Plugin framework cleanup: removed=$removed kept=$kept"
}

# Verify that plugin dylibs have no disallowed absolute paths post-patching
verify_plugins_abs_paths() {
    local plugin_dir="$INSTALL_DMG_TEMP_DIR/$VOLUME_NAME/$VOLUME_NAME/Plugins"
    if [ ! -d "$plugin_dir" ]; then
        PLUGINS_ABS_STATUS=skipped
        return 0
    fi
    if verify_no_abs_paths "$plugin_dir"; then
        PLUGINS_ABS_STATUS=pass
    else
        PLUGINS_ABS_STATUS=fail
        return 1
    fi
}

# Ensure plugin dylibs do not retain @loader_path/Qt*.framework references.
# Those references make dyld look inside Plugins/ for Qt frameworks, which are
# bundled in the app Frameworks directory and must be resolved via @rpath.
verify_no_plugin_loader_qt_framework_refs() {
    local plugin_dir="$INSTALL_DMG_TEMP_DIR/$VOLUME_NAME/$VOLUME_NAME/Plugins"
    [ -d "$plugin_dir" ] || return 0

    local offenders
    offenders=$(find "$plugin_dir" -type f -name "*.dylib" -print0 2>/dev/null | \
        xargs -0 otool -L 2>/dev/null | \
        awk 'NR>1 {print $1}' | \
        grep -E '^@loader_path/Qt[^/]+\.framework/Versions/A/Qt[^/]+$' || true)

    if [ -n "$offenders" ]; then
        echo "❌ Plugin Qt framework references still use @loader_path (should be @rpath):"
        echo "$offenders" | sed 's/^/    /'
        return 1
    fi

    echo "✅ Plugin Qt framework references are normalized (no @loader_path/Qt*.framework remains)"
    return 0
}

# Ensure @loader_path/libX.dylib references in plugins are resolvable from the
# Plugins directory; unresolved entries indicate a broken install_name that should
# have been normalized to @rpath during packaging.
verify_no_broken_plugin_loader_local_dylib_refs() {
    local plugin_dir="$INSTALL_DMG_TEMP_DIR/$VOLUME_NAME/$VOLUME_NAME/Plugins"
    [ -d "$plugin_dir" ] || return 0

    local plugin dep base offenders=""
    while IFS= read -r -d '' plugin; do
        while IFS= read -r dep; do
            [ -z "$dep" ] && continue
            base="${dep#@loader_path/}"
            [ -f "$plugin_dir/$base" ] && continue
            offenders+="$plugin -> $dep\n"
        done < <(otool -L "$plugin" 2>/dev/null | awk 'NR>1 {print $1}' | grep -E '^@loader_path/lib[^/]+\.dylib$' || true)
    done < <(find "$plugin_dir" -type f -name "*.dylib" -maxdepth 1 -print0 2>/dev/null || true)

    if [ -n "$offenders" ]; then
        echo "❌ Broken plugin-local @loader_path dylib references detected:"
        printf "%b" "$offenders" | sed 's/^/    /'
        return 1
    fi

    echo "✅ Plugin @loader_path/lib*.dylib references are resolvable"
    return 0
}

# Newly added: copy internal data libraries that plugins depend upon (e.g., libClusterData.dylib)
copy_internal_data_libraries() { # target_frameworks_dir
    local target="$1"
    local search_root="$INSTALL_DIR"
    # Candidate internal libs inferred from plugin dependency names (will be copied if found)
    local candidates=(
        libClusterData.dylib
        libPointData.dylib
        libXSCTreeData.dylib
        libXSCTreeMetaData.dylib
        libElectrophysiologyData.dylib
        libSampleScopeData.dylib
        libSharedParametersData.dylib
        libTasksData.dylib
        libTutorialData.dylib
        libCellMorphologyData.dylib
        libLogging.dylib
    )
    echo "📦 Scanning for additional internal data libraries required by plugins..."
    local lib
    for lib in "${candidates[@]}"; do
        [ -f "$target/$lib" ] && continue
        local found
        found=$(find "$search_root" -type f -name "$lib" -print -quit 2>/dev/null || true)
        if [ -n "$found" ]; then
            echo "   - Copying $lib"
            cp -f "$found" "$target/$lib"
            install_name_tool -id "@rpath/$lib" "$target/$lib" 2>/dev/null || true
            COPIED_LIB_COUNT=$((COPIED_LIB_COUNT + 1))
        else
            echo "   • Not located (optional / may not exist): $lib"
        fi
    done
}

# Dynamically detect actually referenced internal libraries (beyond static list) and copy them.
# Skips common external/Qt/system libs. Enabled by default; disable with AUTO_INTERNAL_LIB_DETECT=false.
auto_detect_and_copy_internal_libs() { # target_frameworks_dir
    local target="$1"
    local enable="${AUTO_INTERNAL_LIB_DETECT:-true}"
    [ "$enable" = "true" ] || { echo "ℹ️ Auto internal lib detection disabled"; return 0; }
    echo "🔍 Auto-detecting referenced internal libraries..."
    local app_root="$INSTALL_DMG_TEMP_DIR/$VOLUME_NAME/$VOLUME_NAME/$VOLUME_NAME.app"
    local scan_roots=("$app_root/Contents/MacOS" "$app_root/Contents/Frameworks" "$INSTALL_DMG_TEMP_DIR/$VOLUME_NAME/$VOLUME_NAME/Plugins")
    local tmp_refs
    tmp_refs=$(mktemp)
    local f
    for root in "${scan_roots[@]}"; do
        [ -d "$root" ] || continue
        while IFS= read -r -d '' f; do
            otool -L "$f" 2>/dev/null | awk '{print $1}' >> "$tmp_refs" || true
    done < <(find "$root" -type f \( -name "*.dylib" -o -name "*.so" -o -perm -111 \) -print0 2>/dev/null)
    done
    grep -E '^@rpath/lib.*\.dylib$' "$tmp_refs" | sed 's|^@rpath/||' | sort -u > "$tmp_refs.filtered"
    # Exclude known external libs (Qt, flann, cups, omp, lz4, qads, qtadvanceddocking)
    grep -v -E '^(libQt|libflann|libcups|libomp|liblz4|libqads|libqtadvanceddocking)' "$tmp_refs.filtered" > "$tmp_refs.final"
    # Classify candidates into (a) plugin dylibs (skip – must remain in Plugins) and (b) real internal framework/data libs
    local plugin_skip_file="${tmp_refs}.plugins" copy_candidates_file="${tmp_refs}.copy"
    local plugin_dir="$INSTALL_DMG_TEMP_DIR/$VOLUME_NAME/$VOLUME_NAME/Plugins"
    while IFS= read -r cname; do
        [ -z "$cname" ] && continue
        # Heuristic: treat anything containing 'Plugin' (case sensitive) as a plugin library
        if [[ "$cname" == *Plugin*.dylib ]]; then
            echo "$cname" >> "$plugin_skip_file"
            continue
        fi
        # If an identically named file already exists in Plugins directory, also treat as plugin even if name lacks 'Plugin'
        if [ -d "$plugin_dir" ] && [ -f "$plugin_dir/$cname" ]; then
            echo "$cname" >> "$plugin_skip_file"
            continue
        fi
        echo "$cname" >> "$copy_candidates_file"
    done < "$tmp_refs.final"

    echo "   Candidate referenced internal libs:"
    if [ -s "$copy_candidates_file" ]; then
        sed 's/^/     • /' "$copy_candidates_file" || true
    else
        echo "     • (none eligible after filtering)"
    fi
    if [ -s "$plugin_skip_file" ]; then
        echo "   Skipped plugin libraries (remain in Plugins directory):"
        sed 's/^/     • /' "$plugin_skip_file" || true
    fi

    local missing_needed=0 copied=0 name found_path skipped_plugins=0
    # Count skipped plugins for summary
    [ -s "$plugin_skip_file" ] && skipped_plugins=$(wc -l < "$plugin_skip_file" | tr -d ' ')
    local plugins_dir="$INSTALL_DMG_TEMP_DIR/$VOLUME_NAME/$VOLUME_NAME/Plugins"
    mkdir -p "$plugins_dir"
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        # Skip if already in allowed list & exists in Frameworks
        if is_allowed_framework_lib "$name"; then
            [ -f "$target/$name" ] && continue
        fi
        # Determine destination: only allowed libs go to Frameworks, others -> Plugins
        local dest_dir
        if is_allowed_framework_lib "$name"; then
            dest_dir="$target"
        else
            dest_dir="$plugins_dir"
        fi
        # Keep third-party runtime deps in PluginDependencies folders; do not place them in Plugins root
        # where Qt plugin scanning attempts to treat them as Qt plugins.
        if [ "$dest_dir" = "$plugins_dir" ] && [[ "$name" == libFreeImage* || "$name" == libhwy* ]]; then
            continue
        fi
        [ -f "$dest_dir/$name" ] && continue
        found_path=$(find "$INSTALL_COPY_DIR" -type f -name "$name" -print -quit 2>/dev/null || true)
        if [ -n "$found_path" ]; then
            echo "   - Auto-copying $name -> $(basename "$dest_dir")"
            cp -f "$found_path" "$dest_dir/$name" 2>/dev/null || { echo "⚠️ Copy failed for $name"; continue; }
            if [ "$dest_dir" = "$target" ]; then
                install_name_tool -id "@rpath/$name" "$dest_dir/$name" 2>/dev/null || true
                COPIED_LIB_COUNT=$((COPIED_LIB_COUNT + 1))
            else
                PLUGIN_COPIED_LIB_COUNT=$((PLUGIN_COPIED_LIB_COUNT + 1))
            fi
            copied=$((copied+1))
        else
            echo "   ⚠️ Referenced but not found in staging: $name"
            missing_needed=$((missing_needed+1))
        fi
    done < "$copy_candidates_file"
    AUTO_INTERNAL_MISSING=$missing_needed
    AUTO_INTERNAL_COPIED=$copied
    AUTO_INTERNAL_SKIPPED_PLUGINS=$skipped_plugins
    rm -f "$tmp_refs" "$tmp_refs.filtered" "$tmp_refs.final" "$plugin_skip_file" "$copy_candidates_file" 2>/dev/null || true
    echo "✅ Auto-detection pass complete (copied=$copied, missing=$missing_needed, skipped_plugins=$skipped_plugins)"
}

# --- Main Execution Flow
# -----------------------

main() {
    echo "🚀 Starting ManiVault DMG Creation & Signing..."
    echo "--------------------------------------------"

    # --- Phase 1: Preparation ---
    pre_run_cleanup() {
        echo "🧹 Performing pre-run cleanup..."
        safe_remove_dir "$INSTALL_DMG_TEMP_DIR"
        safe_remove_dir "$INSTALL_COPY_DIR"
        mkdir -p "$INSTALL_DMG_TEMP_DIR" "$INSTALL_COPY_DIR"
    }
    pre_run_cleanup
    check_tools

    # --- Phase 1.5: Create staging copy ---
    local installed_app
    installed_app=$(resolve_installed_app_bundle "$INSTALL_DIR") || {
        echo "❌ App bundle '$APP_NAME' was not found in '$INSTALL_DIR' or its build configuration directory." >&2
        exit 1
    }
    echo "📋 Creating staging copy (install -> installCopy) ..."
    echo "   • Detected app bundle: $installed_app"
    cp -a "$INSTALL_DIR/." "$INSTALL_COPY_DIR/"
    chmod -R u+w "$INSTALL_COPY_DIR" || true

    # Patch binaries inside staging before final packaging
    ensure_lz4_present || true
    patch_paths_in_staging
    if verify_no_abs_paths "$INSTALL_COPY_DIR"; then STAGING_ABS_STATUS=pass; else STAGING_ABS_STATUS=fail; echo "❌ Absolute path verification failed post-staging"; exit 1; fi

    # (Plugin Policy) We no longer copy plugins into install/ here; final copy occurs during staging.
    # Switch INSTALL_DIR to staging copy context for remaining steps
    INSTALL_DIR="$INSTALL_COPY_DIR"

    # --- Phase 2: Build initial staging structure ---
    create_initial_staging_structure
    # Early icon replacement inside dmg_temp_content (reinforced later after macdeployqt)
    replace_staged_app_icon

    # --- Phase 3: Finalize app (macdeployqt etc.) ---
    prepare_and_package_app
    # Verify again after macdeployqt adjustments
    if verify_no_abs_paths "$INSTALL_DMG_TEMP_DIR/$VOLUME_NAME/$VOLUME_NAME/$VOLUME_NAME.app"; then FINAL_ABS_STATUS=pass; else FINAL_ABS_STATUS=fail; echo "❌ Absolute path verification failed after app finalization"; exit 1; fi

    # --- Phase 3.5: Patch plugin RPATHs (ensure they can resolve internal data libs) ---
    patch_plugin_rpaths
    verify_plugins_abs_paths || { echo "❌ Plugin absolute path verification failed"; exit 1; }
    verify_no_plugin_loader_qt_framework_refs || { echo "❌ Plugin Qt framework reference verification failed"; exit 1; }
    verify_no_broken_plugin_loader_local_dylib_refs || { echo "❌ Broken plugin-local loader_path dylib references found"; exit 1; }
    cleanup_framework_plugin_duplicates || true
    # Re-enforce framework policy (in case auto-detect added something later)
    enforce_framework_policy "$INSTALL_DMG_TEMP_DIR/$VOLUME_NAME/$VOLUME_NAME/$VOLUME_NAME.app"
    # Framework policy may move additional libs from Frameworks -> Plugins.
    # Patch plugin RPATH/dependency rewrites again so newly moved libs resolve Qt frameworks correctly.
    patch_plugin_rpaths
    verify_plugins_abs_paths || { echo "❌ Plugin absolute path verification failed (post-policy)"; exit 1; }
    verify_no_plugin_loader_qt_framework_refs || { echo "❌ Plugin Qt framework reference verification failed (post-policy)"; exit 1; }
    verify_no_broken_plugin_loader_local_dylib_refs || { echo "❌ Broken plugin-local loader_path dylib references found (post-policy)"; exit 1; }
    # Prune duplicate RPATH entries in final app & plugins
    prune_duplicate_rpaths "$INSTALL_DMG_TEMP_DIR/$VOLUME_NAME/$VOLUME_NAME/$VOLUME_NAME.app" || true
    prune_duplicate_rpaths "$INSTALL_DMG_TEMP_DIR/$VOLUME_NAME/$VOLUME_NAME/Plugins" || true
    # Validation: ensure no plugin dylibs remain in Frameworks (enforces separation)
    local frameworks_dir="$INSTALL_DMG_TEMP_DIR/$VOLUME_NAME/$VOLUME_NAME/$VOLUME_NAME.app/Contents/Frameworks"
    if [ -d "$frameworks_dir" ]; then
        local stray
        stray=$(find "$frameworks_dir" -maxdepth 1 -type f -name 'lib*Plugin*.dylib' | head -n1 || true)
        if [ -n "$stray" ]; then
            echo "❌ Plugin library still present in Frameworks after cleanup: $stray" >&2
            echo "   This indicates an unresolved dependency from outside Plugins. Failing build." >&2
            exit 1
        fi
    fi

    # --- Phase 4: Code Signing ---
    sign_app_bundle

    # --- Phase 5: DMG Creation ---
    create_dmg

    # --- Phase 6: Notarization ---
    if [ -n "$FINAL_DMG_PATH" ]; then
        notarize_dmg "$FINAL_DMG_PATH"
    else
        echo "⚠️ FINAL_DMG_PATH not set; skipping notarization phase"
    fi

    final_summary
    echo "\n🎉 Final process completed successfully!"
    echo "--------------------------------------------"
}

    # Deduplicate any repeated LC_RPATH entries to keep binaries tidy
    prune_duplicate_rpaths() { # dir
        local root="$1"; [ -d "$root" ] || return 0
        echo "🧹 Pruning duplicate RPATH entries under $root ..."
        while IFS= read -r -d '' bin; do
            local paths seen=""
            paths=$(otool -l "$bin" 2>/dev/null | awk '/LC_RPATH/{flag=1;next}/cmd/{flag=0}flag && /path/{print $2}')
            [ -z "$paths" ] && continue
            local p
            for p in $paths; do
                if printf '%s\n' "$seen" | grep -qx "$p"; then
                    install_name_tool -delete_rpath "$p" "$bin" 2>/dev/null || true
                else
                    seen="$seen\n$p"
                fi
            done
        done < <(find "$root" -type f ! -path "*.dSYM/*" \( -name '*.dylib' -o -name '*.so' -o -perm -111 \) -print0)
        echo "✅ Duplicate RPATH pruning complete for $root"
    }

# Run the main function
main
