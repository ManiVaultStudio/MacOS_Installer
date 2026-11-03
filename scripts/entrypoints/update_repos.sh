#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

exec "$SCRIPT_DIR/repos/update_repos.sh" "${1:-default}"
