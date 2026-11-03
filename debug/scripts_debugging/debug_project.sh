#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS_ROOT="$REPO_ROOT/scripts"

BUILD_ONLY="false"
PROJECT=""
QUICK_MODE="false"
FORCE_RECONFIGURE="false"
SKIP_POST_BUILD="false"
ARCH_OPTION=""
CLEAN_REBUILD="false"
NO_REBUILD="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --build-only)
            BUILD_ONLY="true"
            shift
            ;;
        --quick)
            QUICK_MODE="true"
            shift
            ;;
        --reconfigure)
            FORCE_RECONFIGURE="true"
            shift
            ;;
        --skip-post-build)
            SKIP_POST_BUILD="true"
            shift
            ;;
        --clean-rebuild)
            CLEAN_REBUILD="true"
            shift
            ;;
        --no-rebuild)
            NO_REBUILD="true"
            shift
            ;;
        --arch)
            if [ $# -lt 2 ]; then
                echo "Missing value for --arch"
                exit 1
            fi
            ARCH_OPTION="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [--build-only] [--quick] [--reconfigure] [--clean-rebuild] [--no-rebuild] [--skip-post-build] [--arch native|arm64|x86_64|universal] <project>"
            echo "Projects: manivault-installer, cytosplore-installer, manivault-installer-main, debug-simple"
            exit 0
            ;;
        *)
            if [ -z "$PROJECT" ]; then
                PROJECT="$1"
                shift
            else
                echo "Unknown option: $1"
                exit 1
            fi
            ;;
    esac
done

if [ -z "$PROJECT" ]; then
    echo "Usage: $0 [--build-only] [--quick] [--reconfigure] [--clean-rebuild] [--no-rebuild] [--skip-post-build] [--arch native|arm64|x86_64|universal] <project>"
    echo "Projects: manivault-installer, cytosplore-installer, manivault-installer-main, debug-simple"
    exit 1
fi

if [ "$CLEAN_REBUILD" = "true" ] && [ "$NO_REBUILD" = "true" ]; then
    echo "--clean-rebuild and --no-rebuild cannot be used together"
    exit 1
fi

PROJECT_LOWER="$(printf '%s' "$PROJECT" | tr '[:upper:]' '[:lower:]')"

case "$PROJECT_LOWER" in
    manivault-installer)
        PROFILE="scripts/project_profiles/manivault-installer.env"
        SOURCE_FOLDER="manivault-studio"
        DEBUG_PROJECT_KEY="manivault-installer"
        ;;
    cytosplore-installer)
        PROFILE="scripts/project_profiles/cytosploreviewer-installer.env"
        SOURCE_FOLDER="cytosplore-viewer"
        DEBUG_PROJECT_KEY="cytosplore-installer"
        ;;
    manivault-installer-main)
        PROFILE="scripts/project_profiles/manivault-installer-master.env"
        SOURCE_FOLDER="manivault-studio-main"
        DEBUG_PROJECT_KEY="manivault-installer-main"
        ;;
    debug-simple)
        PROFILE="scripts/project_profiles/debug-simple.env"
        SOURCE_FOLDER="debug-simple"
        DEBUG_PROJECT_KEY="debug-simple"
        ;;
    *)
        echo "Unknown project: $PROJECT"
        echo "Supported: manivault-installer, cytosplore-installer, manivault-installer-main, debug-simple"
        exit 1
        ;;
esac

PROFILE_FILE="$REPO_ROOT/$PROFILE"
if [ ! -f "$PROFILE_FILE" ]; then
    echo "Profile not found: $PROFILE_FILE"
    exit 1
fi

SOURCE_ROOT="$REPO_ROOT/sources/$SOURCE_FOLDER"

collect_profile_repos() {
    PLUGIN_BLOB="${PLUGIN_REPOS:-"{}"}" \
    DATA_BLOB="${DATAPLUGIN_REPOS:-"{}"}" \
    python3 - <<'PY'
import json
import os

def parse_repos(raw_value):
    try:
        data = json.loads(raw_value)
    except Exception:
        return []
    repos = data.get("repos", [])
    if not isinstance(repos, list):
        return []
    return [repo for repo in repos if isinstance(repo, str)]

seen = set()
for repo in parse_repos(os.environ.get("DATA_BLOB", "{}")) + parse_repos(os.environ.get("PLUGIN_BLOB", "{}")):
    if repo in seen:
        continue
    seen.add(repo)
    print(repo)
PY
}

ensure_sources_available() {
    local required_repos=("core")
    local parsed_repos
    local repo
    local missing_repos=()
    local repo_path

    parsed_repos="$(collect_profile_repos)"
    while IFS= read -r repo; do
        [ -n "$repo" ] || continue
        required_repos+=("$repo")
    done <<< "$parsed_repos"

    for repo in "${required_repos[@]}"; do
        repo_path="$SOURCE_ROOT/$repo"
        if [ ! -d "$repo_path" ]; then
            missing_repos+=("$repo")
        fi
    done

    if [ "${#missing_repos[@]}" -eq 0 ]; then
        return 0
    fi

    echo "Missing source repositories for $PROJECT_LOWER: ${missing_repos[*]}"
    echo "Running automatic clone for profile '$PROJECT_LOWER'..."
    if ! "$REPO_ROOT/scripts/entrypoints/clone_repos.sh" "$PROFILE_FILE"; then
        echo "Automatic clone failed for profile '$PROJECT_LOWER'."
        echo "Please run manually and retry:"
        echo "  $REPO_ROOT/scripts/entrypoints/clone_repos.sh $PROFILE_FILE"
        return 1
    fi

    missing_repos=()
    for repo in "${required_repos[@]}"; do
        repo_path="$SOURCE_ROOT/$repo"
        if [ ! -d "$repo_path" ]; then
            missing_repos+=("$repo")
        fi
    done

    if [ "${#missing_repos[@]}" -ne 0 ]; then
        echo "Source repositories are still missing after clone: ${missing_repos[*]}"
        return 1
    fi

    return 0
}

remove_tree_strict() {
    local target="$1"
    local attempt

    [ -e "$target" ] || return 0

    for attempt in 1 2 3; do
        # macOS builds can leave immutable flags or read-only files behind.
        chflags -R nouchg,noschg "$target" >/dev/null 2>&1 || true
        chmod -R u+w "$target" >/dev/null 2>&1 || true
        rm -rf "$target" >/dev/null 2>&1 || true

        [ -e "$target" ] || return 0
    done

    echo "Failed to remove path after retries: $target"
    return 1
}

# Preserve explicit caller overrides before sourcing profile files.
REQUESTED_BUILD_TYPE="${BUILD_TYPE-}"
REQUESTED_ARCHS="${ARCHS-}"
REQUESTED_MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET-}"

# shellcheck disable=SC1090
source "$PROFILE_FILE"

# Profiles may define SOURCE_ROOT for release pipelines; force debug wrapper source root.
SOURCE_ROOT="$REPO_ROOT/sources/$SOURCE_FOLDER"

if ! ensure_sources_available; then
    exit 1
fi

# Debug wrapper defaults are independent from release profile defaults.
BUILD_TYPE="${REQUESTED_BUILD_TYPE:-Debug}"
ARCHS="${REQUESTED_ARCHS:-$(uname -m)}"
MACOSX_DEPLOYMENT_TARGET="${REQUESTED_MACOSX_DEPLOYMENT_TARGET:-$(sw_vers -productVersion | awk -F. '{print $1"."$2}')}"

if [ -n "$ARCH_OPTION" ]; then
    case "$ARCH_OPTION" in
        native)
            ARCHS="$(uname -m)"
            ;;
        arm64|x86_64)
            ARCHS="$ARCH_OPTION"
            ;;
        universal)
            ARCHS="x86_64;arm64"
            ;;
        *)
            echo "Unsupported --arch value: $ARCH_OPTION"
            echo "Use one of: native, arm64, x86_64, universal"
            exit 1
            ;;
    esac
fi

BUILD_LABEL="$(echo "$BUILD_TYPE" | tr '[:upper:]' '[:lower:]')"
PROJECT_BUILD_DIR="$REPO_ROOT/builds/debug/$DEBUG_PROJECT_KEY/$BUILD_LABEL/build"
PROJECT_INSTALL_DIR="$REPO_ROOT/builds/debug/$DEBUG_PROJECT_KEY/$BUILD_LABEL/install"
CORE_BUILD_DIR="$PROJECT_BUILD_DIR/core"
CORE_CACHE_FILE="$CORE_BUILD_DIR/CMakeCache.txt"

if [ "$CLEAN_REBUILD" = "true" ]; then
    echo "Cleaning debug cache for $DEBUG_PROJECT_KEY ($BUILD_TYPE)"
    remove_tree_strict "$PROJECT_BUILD_DIR"
    remove_tree_strict "$PROJECT_INSTALL_DIR"
fi

# Fast default for local debug: configure once, then incrementally rebuild.
if [ "$NO_REBUILD" = "true" ]; then
    # If no valid cache/install exists yet, do the initial build once.
    if [ -f "$CORE_CACHE_FILE" ] && [ -d "$PROJECT_INSTALL_DIR" ]; then
        RERUN_CMAKE="no"
        RERUN_BUILD="no"
        POST_BUILD="no"
    else
        echo "No reusable debug artifacts found for $DEBUG_PROJECT_KEY; running initial build."
        RERUN_CMAKE="yes"
        RERUN_BUILD="yes"
        POST_BUILD="yes"
    fi
else
    if [ "$CLEAN_REBUILD" = "true" ] || [ "$FORCE_RECONFIGURE" = "true" ]; then
        RERUN_CMAKE="yes"
    else
        if [ -f "$CORE_CACHE_FILE" ]; then
            RERUN_CMAKE="no"
        else
            RERUN_CMAKE="yes"
        fi
    fi
    RERUN_BUILD="yes"
    POST_BUILD="yes"
fi

if [ "$SKIP_POST_BUILD" = "true" ]; then
    POST_BUILD="no"
fi

profile_values="$({
    PLUGIN_BLOB="${PLUGIN_REPOS:-"{}"}" \
    DATA_BLOB="${DATAPLUGIN_REPOS:-"{}"}" \
    APP_NAME_VALUE="${APP_NAME:-ManiVault Studio.app}" \
    python3 - <<'PY'
import json
import os

def parse_repos(raw_value):
    try:
        data = json.loads(raw_value)
    except Exception:
        return []
    repos = data.get("repos", [])
    if not isinstance(repos, list):
        return []
    return [repo for repo in repos if isinstance(repo, str)]

plugin_repos = parse_repos(os.environ.get("PLUGIN_BLOB", "{}"))
data_repos = parse_repos(os.environ.get("DATA_BLOB", "{}"))

tsne_build = "yes" if "t-SNE-Analysis" in plugin_repos else "no"
plugin_repos = [repo for repo in plugin_repos if repo != "t-SNE-Analysis"]

print(f'DATA_BUILD="{",".join(data_repos) if data_repos else "none"}"')
print(f'PLUGINS_BUILD="{",".join(plugin_repos) if plugin_repos else "none"}"')
print(f'TSNE_BUILD="{tsne_build}"')
print(f'APP_NAME="{os.environ.get("APP_NAME_VALUE", "ManiVault Studio.app")}"')
PY
})"

eval "$profile_values"

if [ "$QUICK_MODE" = "true" ]; then
    DATA_BUILD="none"
    PLUGINS_BUILD="none"
    TSNE_BUILD="no"
fi

if [ "$NO_REBUILD" = "true" ]; then
    APP_BUNDLE_CONFIG_PATH="$PROJECT_INSTALL_DIR/$BUILD_TYPE/$APP_NAME"
    APP_BUNDLE_FLAT_PATH="$PROJECT_INSTALL_DIR/$APP_NAME"

    if [ ! -d "$APP_BUNDLE_CONFIG_PATH" ] && [ ! -d "$APP_BUNDLE_FLAT_PATH" ]; then
        echo "No reusable app bundle found for $DEBUG_PROJECT_KEY."
        echo "Expected one of:"
        echo "  $APP_BUNDLE_CONFIG_PATH"
        echo "  $APP_BUNDLE_FLAT_PATH"
        echo "Run an initial build first:"
        echo "  ./debug/scripts_debugging/debug_project.sh $PROJECT"
        exit 1
    fi

    if [ "$BUILD_ONLY" = "true" ]; then
        echo "Reusing existing build artifacts for $DEBUG_PROJECT_KEY (no rebuild)."
        exit 0
    fi

    BUILD_TYPE="$BUILD_TYPE" APP_NAME="$APP_NAME" DEBUG_PROJECT_KEY="$DEBUG_PROJECT_KEY" SOURCE_ROOT="$SOURCE_ROOT" "$SCRIPT_DIR/run_debug.sh" --mode vscode --non-interactive
    exit 0
fi

BUILD_TYPE="$BUILD_TYPE" ARCHS="$ARCHS" MACOSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" APP_NAME="$APP_NAME" CUSTOMIZATION_FOLDER_PRESENT="${CUSTOMIZATION_FOLDER_PRESENT:-true}" INSTALLER_MATERIALS_ROOT="${INSTALLER_MATERIALS_ROOT:-$REPO_ROOT/installer_materials/projects/$PROFILE_NAME}" \
    DEBUG_PROJECT_KEY="$DEBUG_PROJECT_KEY" \
    SOURCE_ROOT="$SOURCE_ROOT" \
    "$SCRIPT_DIR/build_debug.sh" \
    --core yes \
    --data "$DATA_BUILD" \
    --plugins "$PLUGINS_BUILD" \
    --tsne "$TSNE_BUILD" \
    --rerun-cmake "$RERUN_CMAKE" \
    --rerun-build "$RERUN_BUILD" \
    --post-build "$POST_BUILD"

if [ "$BUILD_ONLY" = "true" ]; then
    exit 0
fi

BUILD_TYPE="$BUILD_TYPE" APP_NAME="$APP_NAME" DEBUG_PROJECT_KEY="$DEBUG_PROJECT_KEY" SOURCE_ROOT="$SOURCE_ROOT" "$SCRIPT_DIR/run_debug.sh" --mode vscode --non-interactive
