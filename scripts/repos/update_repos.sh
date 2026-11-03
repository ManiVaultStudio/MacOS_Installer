
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BASE_URL="${BASE_URL:-https://github.com/ManiVaultStudio}"

# Usage:
#   ./update_repos.sh [profile-name|profile-file]

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

source "$SCRIPTS_ROOT/lib/repo_config.sh"

PROJECT_FOLDER_NAME="${PROJECT_FOLDER_NAME:-${PROFILE_NAME:-default}}"
SOURCE_DIR="${SOURCE_ROOT:-$SCRIPTS_ROOT/../sources/$PROJECT_FOLDER_NAME}"

CORE_BRANCH="${CORE_BRANCH:-release/bican_bg}"

# Automatically discard local changes before updating.
ALLOW_DIRTY_REPO_RESET="${ALLOW_DIRTY_REPO_RESET:-true}"

REPOSITORIES=()

changed_repos=()
unchanged_repos=()

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
            echo "❌ Refusing to reset '$repo_dir': local changes detected." >&2
            return 1
        fi

        echo "⚠ Local changes detected in $(basename "$repo_dir")."
        echo "🗑 Discarding local modifications and untracked files..."

        git -C "$repo_dir" reset --hard
        git -C "$repo_dir" clean -fd

        echo "✓ Local changes discarded."

    else

        echo "✓ Working tree already clean."

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

get_repo_branch() {
    local repo="$1"

    if [ "$repo" = "core" ]; then
        echo "$CORE_BRANCH"
        return
    fi

    local branch=""

    branch="$(
        json_repo_branch "${DATAPLUGIN_REPOS:-}" "$repo" |
        tr -d '[:space:]'
    )"

    if [ -z "$branch" ]; then
        branch="$(
            json_repo_branch "${PLUGIN_REPOS:-}" "$repo" |
            tr -d '[:space:]'
        )"
    fi

    echo "$branch"
}

checkout_repo_ref() {
    local repo_dir="$1"
    local requested_ref="$2"

    local resolved_ref
    local target_branch

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
    local repo_dir="$3"

    local repo_url="$BASE_URL/$repo.git"
    local default_remote_branch
    local target_ref

    echo "Cloning $repo..."

    if ! git clone "$repo_url" "$repo_dir"; then
        echo "✗ Failed to clone $repo" >&2
        return 1
    fi

    default_remote_branch="$(
        git -C "$repo_dir" remote show origin |
        sed -n '/HEAD branch/s/.*: //p'
    )"

    if [ -z "$default_remote_branch" ]; then
        default_remote_branch="$(
            git -C "$repo_dir" branch -r |
            grep -v HEAD |
            head -1 |
            sed 's@origin/@@'
        )"
    fi

    target_ref="${requested_branch:-$default_remote_branch}"

    echo "Repository default branch: $default_remote_branch"

    git -C "$repo_dir" fetch --all --tags

    checkout_repo_ref "$repo_dir" "$target_ref"

    sync_submodules_if_present "$repo_dir"

    echo "✓ Successfully cloned $repo ($target_ref)"
}

update_one_repo() {
    local repo_name="$1"
    local dir="$SOURCE_DIR/$repo_name"

    local branch
    local old_head
    local new_head

    branch="$(get_repo_branch "$repo_name")"

    echo ""
    echo "======================================"
    echo "Processing: $repo_name"
    echo "Branch: ${branch:-default}"
    echo "Directory: $dir"
    echo "======================================"

    # Clone if repository does not exist.
    if [ ! -d "$dir" ]; then

        echo "Repository does not exist. Cloning..."

        clone_repo_with_branch_fallback \
            "$repo_name" \
            "$branch" \
            "$dir"

        changed_repos+=("$repo_name")

        return 0
    fi

    if [ ! -d "$dir/.git" ]; then
        echo "❌ $repo_name exists but is not a Git repository." >&2
        return 1
    fi

    echo "Updating $repo_name..."

    # Clean local modifications before fetching/updating.
    clean_repo_working_tree "$dir"

    cd "$dir"

    old_head="$(git rev-parse HEAD)"

    # Fetch all remote branches and tags.
    git fetch --all --tags

    # Use remote default branch if no branch was configured.
    if [ -z "$branch" ]; then
        branch="$(
            git remote show origin |
            sed -n '/HEAD branch/s/.*: //p'
        )"
    fi

    if [ -z "$branch" ]; then
        echo "❌ Unable to determine target branch for $repo_name." >&2
        return 1
    fi

    echo "Target reference: $branch"

    checkout_repo_ref "$dir" "$branch"

    new_head="$(git rev-parse HEAD)"

    if [ "$old_head" = "$new_head" ]; then
        unchanged_repos+=("$repo_name")
        echo "✓ Already up to date: $repo_name"
    else
        changed_repos+=("$repo_name")
        echo "✓ Updated: $repo_name"
    fi

    sync_submodules_if_present "$dir"

    cd "$SOURCE_DIR"
}

# Build repository list.
if [ -n "${UPDATE_REPOS_LIST:-}" ]; then

    IFS=' ' read -r -a repo_list <<< "$UPDATE_REPOS_LIST"

    for repo_name in "${repo_list[@]}"; do
        add_repo_unique "$repo_name"
    done

elif [ -n "${REPOSITORIES_TO_CLONE:-}" ]; then

    IFS=' ' read -r -a repo_list <<< "$REPOSITORIES_TO_CLONE"

    for repo_name in "${repo_list[@]}"; do
        add_repo_unique "$repo_name"
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

mkdir -p "$SOURCE_DIR"

echo ""
echo "======================================"
echo "ManiVault Repository Update"
echo "======================================"
echo "Source directory: $SOURCE_DIR"
echo "Core branch: $CORE_BRANCH"
echo "Dirty repository cleanup: $ALLOW_DIRTY_REPO_RESET"
echo "Repository count: ${#REPOSITORIES[@]}"
echo ""

if [ ${#REPOSITORIES[@]} -eq 0 ]; then

    echo "No repositories configured for this profile."

else

    for repo_name in "${REPOSITORIES[@]}"; do
        update_one_repo "$repo_name"
    done

fi

echo ""
echo "======================================"
echo "Repository Update Summary"
echo "======================================"

if [ ${#changed_repos[@]} -gt 0 ]; then

    echo ""
    echo "Repositories cloned or updated:"

    for repo in "${changed_repos[@]}"; do
        echo "  ✓ $repo"
    done

fi

if [ ${#unchanged_repos[@]} -gt 0 ]; then

    echo ""
    echo "Repositories already up to date:"

    for repo in "${unchanged_repos[@]}"; do
        echo "  - $repo"
    done

fi

echo ""
echo "======================================"
echo "✓ All repositories processed"
echo "======================================"
