#!/usr/bin/env bash
set -euo pipefail

repo_dir="${1:?Usage: ensure_submodules.sh REPOSITORY_DIRECTORY}"
if [[ ! -d "$repo_dir/.git" && ! -f "$repo_dir/.git" ]]; then
    echo "ERROR: Not a Git repository: $repo_dir" >&2
    exit 1
fi
if [[ ! -f "$repo_dir/.gitmodules" ]]; then
    exit 0
fi

echo "Initializing pinned submodules for $(basename "$repo_dir")..."
git -C "$repo_dir" submodule sync --recursive
git -C "$repo_dir" submodule update --init --recursive
