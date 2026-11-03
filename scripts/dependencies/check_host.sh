#!/bin/bash
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
if [ "$(uname -s)" != Darwin ]; then
    echo "Native installer builds require macOS." >&2
    exit 1
fi
if ! xcrun --find clang >/dev/null 2>&1; then
    echo "Apple command line tools are missing. Run xcode-select --install, finish installation, then retry." >&2
    exit 1
fi
missing=()
for tool in git cmake ninja pkg-config clang lipo make python3; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if [ "${#missing[@]}" -gt 0 ]; then
    echo "Missing build tools: ${missing[*]}. Install CMake, Ninja and pkg-config (brew install cmake ninja pkg-config), then retry." >&2
    exit 1
fi
jobs="${BUILD_JOBS:-2}"
case "$jobs" in 1|2|3|4|5|6|7|8) ;; *) echo "Build jobs must be between 1 and 8." >&2; exit 1 ;; esac
root="${LIBRARIES_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)/libraries}"
mkdir -p "$root"
free_kb=$(df -Pk "$root" | awk 'NR==2 {print $4}')
if [ "${free_kb:-0}" -lt 5242880 ]; then
    echo "Less than 5 GB of disk space is available for dependency downloads and builds. Free space and retry." >&2
    exit 1
fi
echo "Build tools ready. Parallel jobs: $jobs. Available disk: $((free_kb / 1048576)) GB."
