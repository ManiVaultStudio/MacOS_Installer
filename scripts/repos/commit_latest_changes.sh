#!/bin/bash
set -euo pipefail

# Branch name to use
BRANCH_NAME="feature/mac-build-fix"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_DIR="$SCRIPTS_ROOT/../sources"

# Commit message
COMMIT_MSG="cmake changes for local mac build"

# List of repositories
REPOS=(
  "XSCPhyTVuPlugin"
  "XSCLoaderPlugin"
  "XSCClusterRankPlugin"
  "XSCGeneDetectPlugin"
)

for REPO in "${REPOS[@]}"; do
  echo "-----------------------------------"
  echo "Processing $REPO"
  echo "-----------------------------------"

  REPO_PATH="$SOURCE_DIR/$REPO"

  if [ -d "$REPO_PATH" ]; then
    cd "$REPO_PATH" || exit

    # Create and checkout branch
    git checkout -b "$BRANCH_NAME"

    # Stage changes
    git add .

    # Commit changes
    git commit -m "$COMMIT_MSG"

    # Push branch to remote
    git push -u origin "$BRANCH_NAME"

    cd - > /dev/null || exit
  else
    echo "Directory $REPO_PATH not found, skipping."
  fi
done

echo "All repositories processed."
