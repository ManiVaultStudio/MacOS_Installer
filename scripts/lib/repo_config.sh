#!/bin/bash
set -euo pipefail

json_repo_keys() {
    local json_text="$1"

    python3 - "$json_text" <<'PY'
import json
import sys

raw = sys.argv[1].strip()

if not raw:
    raise SystemExit(0)

data = json.loads(raw)

if not isinstance(data, dict):
    raise SystemExit("Expected JSON object")

repo_list = data.get("repos")

if isinstance(repo_list, list):
    for repo in repo_list:
        if isinstance(repo, str) and repo:
            print(repo)
    raise SystemExit(0)

if isinstance(repo_list, dict):
    for repo in repo_list.keys():
        print(repo)
    raise SystemExit(0)
PY
}


json_repo_branch() {
    local json_text="$1"
    local repo_name="$2"

    python3 - "$json_text" "$repo_name" <<'PY'
import json
import sys

raw = sys.argv[1].strip()
repo_name = sys.argv[2]

if not raw:
    raise SystemExit(0)

data = json.loads(raw)

overrides = data.get(
    "branchOverrides",
    data.get("overrides", {})
)

# Highest priority: explicit override
if repo_name in overrides:
    print(overrides[repo_name])
    raise SystemExit(0)

# Second: dictionary-style repos
repos = data.get("repos", {})

if isinstance(repos, dict):
    if repo_name in repos:
        print(repos[repo_name])
        raise SystemExit(0)

# Third: shared default branch for list-style repos
if isinstance(repos, list):
    if repo_name in repos:
        print(data.get("defaultBranch", ""))
        raise SystemExit(0)

PY
}


get_repo_branch() {
    local repo="$1"
    local core_branch="$2"

    if [ "$repo" = "core" ]; then
        echo "$core_branch"
        return
    fi

    local branch

    branch="$(json_repo_branch "${DATAPLUGIN_REPOS:-}" "$repo")"

    if [ -z "$branch" ]; then
        branch="$(json_repo_branch "${PLUGIN_REPOS:-}" "$repo")"
    fi

    echo "$branch"
}

resolve_remote_ref() {
    local remote="$1"
    local requested="$2"
    local branch_ref tag_ref

    [ -n "$requested" ] || return 1
    branch_ref="refs/heads/$requested"
    if git ls-remote --exit-code --heads "$remote" "$branch_ref" >/dev/null 2>&1; then
        echo "$branch_ref"
        return 0
    fi

    tag_ref="refs/tags/$requested"
    if git ls-remote --exit-code --tags "$remote" "$tag_ref" "$tag_ref^{}" >/dev/null 2>&1; then
        echo "$tag_ref"
        return 0
    fi

    return 1
}
