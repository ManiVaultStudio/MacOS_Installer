
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_DIR=""

source "$SCRIPTS_ROOT/lib/repo_config.sh"

# Usage:
#   ./clonerepos.sh [profile-name|profile-file]

PROFILE_INPUT="${1:-default}"

if [ -f "$PROFILE_INPUT" ]; then
    PROFILE_FILE="$PROFILE_INPUT"
else
    PROFILE_FILE="$SCRIPTS_ROOT/project_profiles/${PROFILE_INPUT}.env"
fi

if [ -f "$PROFILE_FILE" ]; then
    # shellcheck disable=SC1090
    source "$PROFILE_FILE"
    echo "Using profile: $PROFILE_FILE"
else
    echo "❌ Profile not found: $PROFILE_FILE"
    exit 1
fi

# Configuration
CORE_BRANCH="${CORE_BRANCH:-release/bican_bg}"
BASE_URL="${BASE_URL:-https://github.com/ManiVaultStudio}"
PROJECT_FOLDER_NAME="${PROJECT_FOLDER_NAME:-${PROFILE_NAME:-default}}"
: "${SOURCE_ROOT:=$SCRIPTS_ROOT/../sources/$PROJECT_FOLDER_NAME}"

SOURCE_DIR="$SOURCE_ROOT"
TARGET_DIR="$SOURCE_DIR"

# Automatically discard local repository changes.
ALLOW_DIRTY_REPO_RESET="${ALLOW_DIRTY_REPO_RESET:-true}"

REPOSITORIES=()

add_repo_unique() {
    local candidate="$1"
    local existing

    [ -n "$candidate" ] || return 0

    for existing in "${REPOSITORIES[@]:-}"; do
        if [ "$existing" = "$candidate" ]; then
            return 0
        fi
    done

    REPOSITORIES+=("$candidate")
}

# Discard tracked modifications and untracked files.
clean_repo_working_tree() {
    local repo_dir="$1"

    if [ ! -d "$repo_dir/.git" ]; then
        echo "❌ Not a Git repository: $repo_dir" >&2
        return 1
    fi

    if [ -n "$(git -C "$repo_dir" status --porcelain)" ]; then

        if [ "$ALLOW_DIRTY_REPO_RESET" != "true" ]; then
            echo "❌ Local changes detected in $(basename "$repo_dir")." >&2
            echo "Set ALLOW_DIRTY_REPO_RESET=true to discard them." >&2
            return 1
        fi

        echo "⚠ Local changes detected in $(basename "$repo_dir")."
        echo "🗑 Discarding local modifications and untracked files..."

        git -C "$repo_dir" reset --hard
        git -C "$repo_dir" clean -fd

        echo "✓ Working tree cleaned."
    else
        echo "✓ Repository working tree already clean."
    fi
}

sync_submodules_if_present() {
    local repo_dir="$1"

    if [ -f "$repo_dir/.gitmodules" ]; then
        echo "↪ Syncing submodules in $(basename "$repo_dir")..."

        (
            cd "$repo_dir"
            git submodule sync --recursive
            git submodule update --init --recursive
        )
    fi
}

# Resolve and checkout the configured branch or tag.
checkout_repo_ref() {
    local repo_dir="$1"
    local requested_ref="$2"
    local resolved_ref
    local target_branch

    cd "$repo_dir"

    if ! resolved_ref="$(resolve_remote_ref origin "$requested_ref")"; then
        echo "❌ Requested branch/tag '$requested_ref' does not exist." >&2
        return 1
    fi

    if [[ "$resolved_ref" == refs/heads/* ]]; then

        target_branch="${resolved_ref#refs/heads/}"

        git checkout -B "$target_branch" "origin/$target_branch"
        git reset --hard "origin/$target_branch"

    else

        git fetch origin "$resolved_ref"
        git checkout --detach FETCH_HEAD

    fi
}

clone_repo_with_branch_fallback() {
    local repo="$1"
    local requested_branch="$2"
    local repo_url="$BASE_URL/$repo.git"
    local repo_dir="$TARGET_DIR/$repo"
    local default_remote_branch
    local target_ref

    echo "Cloning $repo..."

    if ! git clone "$repo_url" "$repo_dir"; then
        echo "✗ Failed to clone $repo" >&2
        return 1
    fi

    cd "$repo_dir"

    default_remote_branch="$(
        git remote show origin |
        sed -n '/HEAD branch/s/.*: //p'
    )"

    if [ -z "$default_remote_branch" ]; then
        default_remote_branch="$(
            git branch -r |
            grep -v HEAD |
            head -1 |
            sed 's@origin/@@'
        )"
    fi

    echo "Repository default branch: $default_remote_branch"

    target_ref="${requested_branch:-$default_remote_branch}"

    checkout_repo_ref "$repo_dir" "$target_ref"

    cd "$TARGET_DIR"

    sync_submodules_if_present "$repo_dir"

    echo "✓ Successfully cloned $repo ($target_ref)"
}

# Build repository list.
if [ -n "${REPOSITORIES_TO_CLONE:-}" ]; then

    IFS=' ' read -r -a clone_list <<< "$REPOSITORIES_TO_CLONE"

    for repo in "${clone_list[@]}"; do
        add_repo_unique "$repo"
    done

else

    add_repo_unique "core"

    while IFS= read -r repo_name; do
        add_repo_unique "$repo_name"
    done < <(json_repo_keys "${DATAPLUGIN_REPOS:-}")

    while IFS= read -r repo_name; do
        add_repo_unique "$repo_name"
    done < <(json_repo_keys "${PLUGIN_REPOS:-}")

fi

mkdir -p "$TARGET_DIR"

echo ""
echo "Cloning/synchronizing repositories to $TARGET_DIR/"
echo "Core branch: $CORE_BRANCH"
echo "Dirty repository cleanup: $ALLOW_DIRTY_REPO_RESET"
echo "Repo count: ${#REPOSITORIES[@]}"
echo ""

cd "$TARGET_DIR"

for repo in "${REPOSITORIES[@]}"; do

    branch="$(get_repo_branch "$repo" "$CORE_BRANCH")"

    echo "Processing $repo (branch: ${branch:-default})..."

    if [ -d "$TARGET_DIR/$repo/.git" ]; then

        echo "Repository already exists: $repo"

        clean_repo_working_tree "$TARGET_DIR/$repo"

        git -C "$TARGET_DIR/$repo" fetch --all --tags

        if [ -z "$branch" ]; then
            branch="$(
                git -C "$TARGET_DIR/$repo" remote show origin |
                sed -n '/HEAD branch/s/.*: //p'
            )"
        fi

        checkout_repo_ref "$TARGET_DIR/$repo" "$branch"

        sync_submodules_if_present "$TARGET_DIR/$repo"

        echo "✓ Repository synchronized: $repo"

    else

        clone_repo_with_branch_fallback "$repo" "$branch"

    fi

    echo ""

done

echo "======================================"
echo "✓ Repository synchronization complete"
echo "======================================"
echo "All repositories are in: $TARGET_DIR/"
