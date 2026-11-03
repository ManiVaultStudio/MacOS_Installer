#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
    cat <<'EOF'
Usage:
    ./run_project_profile.sh <profile-name|profile-file> [--skip-update] [--skip-clean|--clean]

Examples:
  ./run_project_profile.sh default
    ./run_project_profile.sh hmba-lite --skip-update --skip-clean
  ./run_project_profile.sh ./project_profiles/default.env
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ $# -lt 1 ]; then
    usage
    exit 0
fi

PROFILE_INPUT="$1"
shift || true

SKIP_UPDATE=false
SKIP_REPO_SYNC=false
SKIP_CLEAN=true
for arg in "$@"; do
    case "$arg" in
        --skip-update) SKIP_UPDATE=true ;;
        --skip-repo-sync) SKIP_REPO_SYNC=true ;;
        --skip-clean) SKIP_CLEAN=true ;;
        --clean) SKIP_CLEAN=false ;;
        *) echo "Unknown option: $arg"; usage; exit 1 ;;
    esac
done

if [ -f "$PROFILE_INPUT" ]; then
    PROFILE_FILE="$PROFILE_INPUT"
else
    PROFILE_FILE="$SCRIPTS_ROOT/project_profiles/${PROFILE_INPUT}.env"
fi

if [ ! -f "$PROFILE_FILE" ]; then
    echo "Profile not found: $PROFILE_FILE"
    echo "Available profiles:"
    ls -1 "$SCRIPTS_ROOT/project_profiles"/*.env 2>/dev/null | xargs -n1 basename | sed 's/\.env$//' || true
    exit 1
fi

# shellcheck disable=SC1090
source "$PROFILE_FILE"

: "${PROFILE_NAME:=unnamed}"
source "$SCRIPTS_ROOT/config/project_build.sh"
: "${CORE_BRANCH:=release/bican_bg}"
: "${APP_NAME:=ManiVault Studio.app}"
: "${VOLUME_NAME:=Cytosplore Viewer}"
: "${APP_VERSION:=1.0.0}"
: "${CUSTOMIZATION_FOLDER_PRESENT:=true}"
: "${INSTALLER_MATERIALS_ROOT:=$SCRIPTS_ROOT/../installer_materials/projects/${PROFILE_NAME:-default}}"
: "${INSTALLER_MATERIALS:=$INSTALLER_MATERIALS_ROOT}"
# Only set these defaults if the variables are unset (not if they are intentionally empty)
if [ "${PROJECTS_SOURCE_FILE+set}" != "set" ]; then
    PROJECTS_SOURCE_FILE="$SCRIPTS_ROOT/../installer_materials/projects/${PROFILE_NAME:-default}/projects.json"
fi
if [ "${APP_CONFIG_SOURCE_FILE+set}" != "set" ]; then
    APP_CONFIG_SOURCE_FILE="$SCRIPTS_ROOT/../installer_materials/projects/${PROFILE_NAME:-default}/app.json"
fi
: "${APP_ICON_FILE:=$INSTALLER_MATERIALS/appimage-cytosplore.icns}"
: "${DMG_BACKGROUND_IMAGE:=$INSTALLER_MATERIALS/dmg-background-cytosplore.png}"
: "${FOLDER_ICONS_DIR:=$INSTALLER_MATERIALS/folderIcons-cytosplore}"
: "${APPLY_FOLDER_ICONS:=true}"
: "${LICENSE_DIR:=$SCRIPTS_ROOT/../installer_materials/common/license}"
: "${ASSETS_DIR:=$SCRIPTS_ROOT/../installer_materials/common/assets}"
: "${DMG_FORMAT:=UDZO}"
: "${ENABLE_DMG_BACKGROUND:=true}"
: "${SKIP_FINDER_UI:=false}"
: "${FINDER_UI_MAX_RETRIES:=5}"
: "${FINDER_UI_RETRY_DELAY:=3}"
: "${DMG_WIDTH:=527}"
: "${DMG_HEIGHT:=429}"
: "${DMG_ICON_SIZE:=96}"
: "${DMG_ICON_MARGIN:=60}"
: "${MINIMAL_RPATH:=true}"
: "${PIN_INTERNAL_LIBS:=false}"
: "${MIN_CORE_VERSION_MAJOR:=1}"
: "${MIN_CORE_VERSION_MINOR:=4}"
: "${MIN_CORE_VERSION_PATCH:=0}"
: "${DEPENDENCY_MANIFEST_FILE:=$SCRIPTS_ROOT/../installer_database/dependencies.json}"
: "${MIN_CORE_VERSION_SUFFIX:=}"
: "${RUN_COMMON_DEPENDENCY_BUILDS:=false}"
: "${PACKAGE_INSTALLER:=false}"
: "${DEPENDENCY_BUILD_MODE:=if-missing}"
: "${SKIP_CLEAN_STEP:=false}"
: "${DRY_RUN:=false}"
: "${CORE_ENABLE_HEADER_PRECHECK:=true}"
: "${CORE_PRECHECK_SCOPE:=changed}"
: "${CORE_PRECHECK_INCLUDE_HEADERS:=true}"
: "${CORE_FAST_BUILD:=true}"
: "${CORE_DISABLE_PCH_FOR_BUILD:=false}"
: "${CORE_USE_CCACHE:=true}"
: "${EXCLUDED_PLUGINS:=}"
: "${DATAPLUGIN_REPOS:={}}"
: "${PLUGIN_REPOS:={}}"
: "${DEPENDENCIES:=}"
: "${ALLOW_DIRTY_REPO_RESET:=false}"
: "${ALLOW_DEPENDENCY_SOURCE_RESET:=false}"
: "${QT_VERSION:=6.10.3}"
: "${QT_DIR:=$SCRIPTS_ROOT/../libraries/qt/$QT_VERSION/macos}"
: "${VULKAN_SDK_VERSION:=1.4.350.0}"
: "${VULKAN_SDK:=$HOME/VulkanSDK/$VULKAN_SDK_VERSION/macOS}"

export PROFILE_NAME APP_VERSION ARCHS MIN_MACOS_VERSION
export SCRIPTS_ROOT
export MIN_CORE_VERSION_MAJOR MIN_CORE_VERSION_MINOR MIN_CORE_VERSION_PATCH
export DEPENDENCY_MANIFEST_FILE
export DATAPLUGIN_REPOS PLUGIN_REPOS DEPENDENCIES
export ALLOW_DIRTY_REPO_RESET
export ALLOW_DEPENDENCY_SOURCE_RESET
export QT_VERSION QT_DIR VULKAN_SDK_VERSION VULKAN_SDK
export PROJECTS_SOURCE_FILE APP_CONFIG_SOURCE_FILE APP_ICON_FILE DMG_BACKGROUND_IMAGE
python3 "$SCRIPTS_ROOT/profiles/validate_profile.py"

LOCK_DIR="$SCRIPTS_ROOT/.locks"
LOCK_NAME="${PROFILE_NAME}.pipeline.lock"
LOCK_PATH="$LOCK_DIR/$LOCK_NAME"
mkdir -p "$LOCK_DIR"

if ! mkdir "$LOCK_PATH" 2>/dev/null; then
    LOCK_PID=""
    if [[ -f "$LOCK_PATH/pid" ]]; then
        LOCK_PID=$(<"$LOCK_PATH/pid")
    fi
    if [[ "$LOCK_PID" =~ ^[0-9]+$ ]] && kill -0 "$LOCK_PID" 2>/dev/null; then
        echo "Another pipeline run is already active for profile '$PROFILE_NAME' (PID $LOCK_PID)."
        echo "Lock path: $LOCK_PATH"
        exit 1
    fi
    # Recover a lock only when its owner is verifiably gone. mv is atomic, so
    # concurrent retries cannot remove a newly-created live lock.
    STALE_LOCK_PATH="${LOCK_PATH}.stale.$$"
    if mv "$LOCK_PATH" "$STALE_LOCK_PATH" 2>/dev/null; then
        rm -rf "$STALE_LOCK_PATH"
        if ! mkdir "$LOCK_PATH" 2>/dev/null; then
            echo "Another pipeline run started for profile '$PROFILE_NAME'."
            exit 1
        fi
    else
        echo "Another pipeline run is starting for profile '$PROFILE_NAME'."
        exit 1
    fi
fi
printf '%s\n' "$$" > "$LOCK_PATH/pid"

cleanup_lock() {
    rm -f "$LOCK_PATH/pid"
    rmdir "$LOCK_PATH" 2>/dev/null || true
}
trap cleanup_lock EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

INSTALL_DIR="${INSTALL_DIR:-$BUILDFILES_ROOT/$PROFILE_NAME/install/$PROJECT_FOLDER_NAME}"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPTS_ROOT/../application}"
: "${INSTALL_COPY_DIR:=$BUILDFILES_ROOT/$PROFILE_NAME/installCopy/$PROJECT_FOLDER_NAME}"
: "${INSTALL_DMG_TEMP_DIR:=$BUILDFILES_ROOT/$PROFILE_NAME/dmg_temp_content/$PROJECT_FOLDER_NAME}"


# Automatically choose a safe number of parallel build jobs.
detect_build_jobs() {
    local cores mem_gb jobs memory_jobs

    cores=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
    mem_gb=$(($(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 / 1024 / 1024))

    jobs=$cores

    if (( mem_gb > 0 )); then
        memory_jobs=$((mem_gb / 4))
        (( memory_jobs < 1 )) && memory_jobs=1
        (( memory_jobs < jobs )) && jobs=$memory_jobs
    else
        (( jobs > 4 )) && jobs=4
    fi

    echo "$jobs"
}

BUILD_JOBS="${BUILD_JOBS:-$(detect_build_jobs)}"
export BUILD_JOBS

echo "Parallel build jobs: $BUILD_JOBS"


export BUILD_TYPE ARCHS MIN_MACOS_VERSION CORE_BRANCH SOURCE_ROOT CORE_SOURCE_DIR BUILD_ROOT INSTALL_DIR OUTPUT_DIR
CORE_SOURCE_DIR="${CORE_SOURCE_DIR:-$SOURCE_ROOT/core}"
export CORE_SOURCE_DIR
if [ "$DRY_RUN" != "true" ] && [ ! -f "$CORE_SOURCE_DIR/CMakeLists.txt" ]; then
    echo "❌ Core source is incomplete: $CORE_SOURCE_DIR/CMakeLists.txt was not found."
    echo "Set CORE_SOURCE_DIR to a clean core checkout for this profile, or restore the missing source files."
    exit 1
fi
export INSTALL_COPY_DIR INSTALL_DMG_TEMP_DIR
export APP_NAME VOLUME_NAME APP_VERSION
export CUSTOMIZATION_FOLDER_PRESENT
export PROJECTS_SOURCE_FILE APP_CONFIG_SOURCE_FILE
export INSTALLER_MATERIALS_ROOT INSTALLER_MATERIALS
export APP_ICON_FILE DMG_BACKGROUND_IMAGE
export FOLDER_ICONS_DIR APPLY_FOLDER_ICONS LICENSE_DIR ASSETS_DIR
export DMG_FORMAT ENABLE_DMG_BACKGROUND SKIP_FINDER_UI
export FINDER_UI_MAX_RETRIES FINDER_UI_RETRY_DELAY
export DMG_WIDTH DMG_HEIGHT DMG_ICON_SIZE DMG_ICON_MARGIN
export MINIMAL_RPATH PIN_INTERNAL_LIBS
export MIN_CORE_VERSION_MAJOR MIN_CORE_VERSION_MINOR MIN_CORE_VERSION_PATCH MIN_CORE_VERSION_SUFFIX
export RUN_COMMON_DEPENDENCY_BUILDS DEPENDENCY_BUILD_MODE
export DRY_RUN
export CORE_ENABLE_HEADER_PRECHECK CORE_PRECHECK_SCOPE CORE_PRECHECK_INCLUDE_HEADERS
export CORE_FAST_BUILD CORE_DISABLE_PCH_FOR_BUILD CORE_USE_CCACHE
export EXCLUDED_PLUGINS
export DATAPLUGIN_REPOS PLUGIN_REPOS

if [ "$SKIP_CLEAN_STEP" = "true" ]; then
    SKIP_CLEAN=true
fi

run_step() {
    local cmd="$1"
    if [ "$DRY_RUN" = "true" ]; then
        echo "[DRY-RUN] $cmd"
    else
        eval "$cmd"
    fi
}

echo "========================================"
echo "Profile           : $PROFILE_NAME"
echo "Config            : $PROFILE_FILE"
echo "Build type        : $BUILD_TYPE"
echo "Architectures     : $ARCHS"
echo "Min macOS version : $MIN_MACOS_VERSION"
echo "Core branch       : $CORE_BRANCH"
echo "Source root       : $SOURCE_ROOT"
echo "Build root        : $BUILD_ROOT"
echo "Install dir       : $INSTALL_DIR"
echo "Install copy dir  : $INSTALL_COPY_DIR"
echo "DMG temp dir      : $INSTALL_DMG_TEMP_DIR"
echo "Output dir        : $OUTPUT_DIR"
echo "App bundle name   : $APP_NAME"
echo "Installer name    : $VOLUME_NAME"
echo "Version           : $APP_VERSION"
echo "Customization dir : $CUSTOMIZATION_FOLDER_PRESENT"
echo "Installer mat root: $INSTALLER_MATERIALS_ROOT"
echo "DMG background    : $DMG_BACKGROUND_IMAGE"
echo "Apply folder icons: $APPLY_FOLDER_ICONS"
echo "projects.json     : $PROJECTS_SOURCE_FILE"
echo "app.json          : $APP_CONFIG_SOURCE_FILE"
echo "Min core version  : ${MIN_CORE_VERSION_MAJOR}.${MIN_CORE_VERSION_MINOR}.${MIN_CORE_VERSION_PATCH}${MIN_CORE_VERSION_SUFFIX}"
echo "Build shared deps : $RUN_COMMON_DEPENDENCY_BUILDS"
echo "Deps build mode   : $DEPENDENCY_BUILD_MODE"
echo "Skip clean step   : $SKIP_CLEAN"
echo "Dry run           : $DRY_RUN"
echo "Excluded plugins  : $EXCLUDED_PLUGINS"
echo "Data plugins      : $DATAPLUGIN_REPOS"
echo "Plugins           : $PLUGIN_REPOS"
echo "========================================"

echo "Dependency installation is a separate workflow stage (scripts/entrypoints/install_dependencies.sh / installer_engine.py dependencies)."

if [ "$SKIP_REPO_SYNC" = true ]; then
    echo "Skipping repository synchronization; pinned checkouts were already verified."
elif [ "$SKIP_UPDATE" = false ]; then
    run_step "\"$SCRIPTS_ROOT/repos/update_repos.sh\" \"$PROFILE_FILE\""
else
    echo "Skipping repo update/reset step; ensuring missing repos are cloned only."
    run_step "\"$SCRIPTS_ROOT/repos/clonerepos.sh\" \"$PROFILE_FILE\""
fi

if [ "$SKIP_CLEAN" = "false" ]; then
    run_step "\"$SCRIPTS_ROOT/pipeline/clear_build_install.sh\" \"$PROFILE_FILE\""
else
    echo "Skipping clean step (incremental build mode)."
fi
run_step "\"$SCRIPTS_ROOT/stages/build_core.sh\""
run_step "\"$SCRIPTS_ROOT/stages/build_dataplugins.sh\""
run_step "\"$SCRIPTS_ROOT/stages/build_plugins.sh\""
if [ "$BUILD_TYPE" = "RelWithDebInfo" ] || [ "$BUILD_TYPE" = "Debug" ]; then
    run_step "\"$SCRIPTS_ROOT/package/generate_plugin_dsym.sh\""
else
    echo "Skipping dSYM generation."
fi
if [ "$PACKAGE_INSTALLER" = "true" ]; then
    run_step "\"$SCRIPTS_ROOT/package/final_create_dmgvulkan.sh\""
else
    echo "Installer packaging is a separate workflow stage; skipping DMG creation."
fi

# === Dropbox upload and wait logic ===
if [ "${UPLOAD_TO_DROPBOX:-false}" = "true" ]; then
    # Set these paths as needed for your local Dropbox sync folder
    DROPBOX_UPLOAD_DIR="$HOME/Dropbox/ToSign"   # Local Dropbox folder for upload
    DROPBOX_SIGNED_DIR="$HOME/Dropbox/Signed"   # Local Dropbox folder for signed DMGs
    SIGNED_DEST_DIR="$SCRIPTS_ROOT/../application/signeddmg"

    mkdir -p "$SIGNED_DEST_DIR"

    # Find the newest DMG in OUTPUT_DIR.
    DMG_FILE=""

    for candidate in "$OUTPUT_DIR"/*.dmg; do
        [ -f "$candidate" ] || continue

        if [ -z "$DMG_FILE" ] || [ "$candidate" -nt "$DMG_FILE" ]; then
            DMG_FILE="$candidate"
        fi
    done

    if [ -z "$DMG_FILE" ]; then
        echo "Error: No DMG file found in $OUTPUT_DIR"
        exit 1
    fi

    # Generate a unique filename with timestamp
    BASENAME=$(basename "$DMG_FILE" .dmg)
    TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
    UNIQUE_FILENAME="${BASENAME}_${TIMESTAMP}.dmg"

    # Upload to Dropbox
    "$SCRIPTS_ROOT/package/upload/send_to_dropbox.sh" "$DMG_FILE" "$DROPBOX_UPLOAD_DIR" "$UNIQUE_FILENAME"

    # Wait for signed DMG in Dropbox signed folder
    "$SCRIPTS_ROOT/package/upload/wait_for_dropbox_file.sh" "$DROPBOX_SIGNED_DIR" "$SIGNED_DEST_DIR" "$UNIQUE_FILENAME"
fi

echo "Project profile build finished successfully."
