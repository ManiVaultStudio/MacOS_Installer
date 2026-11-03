#!/bin/bash
# Shared macOS CMake toolchain and pinned FetchContent configuration.
# Source this file from project build stages; keep project-specific flags local.

find_build_cmake() {
    local candidate
    for candidate in /opt/homebrew/bin/cmake /usr/local/bin/cmake; do
        if [[ -x "$candidate" ]]; then CMAKE_BIN="$candidate"; break; fi
    done
    if [[ -z "${CMAKE_BIN:-}" ]] && command -v cmake >/dev/null 2>&1; then CMAKE_BIN="$(command -v cmake)"; fi
    if [[ -z "${CMAKE_BIN:-}" ]]; then echo "ERROR: CMake is required. Install CMake before building." >&2; return 1; fi
    echo "Using CMake: $CMAKE_BIN"
}

find_build_ninja() {
    if ! command -v ninja >/dev/null 2>&1; then
        echo "ERROR: Ninja is required. Install Ninja before building." >&2
        return 1
    fi
    NINJA_BIN="$(command -v ninja)"
    echo "Using Ninja: $NINJA_BIN"
}

find_macos_sdk() {
    if command -v xcrun >/dev/null 2>&1; then
        MACOS_SDK_PATH="$(xcrun --show-sdk-path)"
    elif [[ -d /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk ]]; then
        MACOS_SDK_PATH="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
    else
        echo "ERROR: Cannot find the macOS SDK. Install Xcode command line tools." >&2
        return 1
    fi
    echo "Using macOS SDK: $MACOS_SDK_PATH"
}

prepare_common_cmake_args() {
    : "${BUILD_TYPE:=Release}"
    : "${ARCHS:=x86_64;arm64}"
    : "${MIN_MACOS_VERSION:=12.0}"
    : "${CC_BIN:=/usr/bin/cc}"
    : "${CXX_BIN:=/usr/bin/c++}"
    CMAKE_COMMON_ARGS=(
        "-DCMAKE_BUILD_TYPE=$BUILD_TYPE"
        "-DCMAKE_POLICY_VERSION_MINIMUM=3.5"
        "-DCMAKE_C_COMPILER=$CC_BIN"
        "-DCMAKE_CXX_COMPILER=$CXX_BIN"
        "-DCMAKE_OSX_ARCHITECTURES=$ARCHS"
        "-DCMAKE_OSX_DEPLOYMENT_TARGET=$MIN_MACOS_VERSION"
        -DFETCHCONTENT_UPDATES_DISCONNECTED=ON
        -G Ninja
    )
    if command -v ccache >/dev/null 2>&1; then
        CMAKE_COMMON_ARGS+=("-DCMAKE_C_COMPILER_LAUNCHER=$(command -v ccache)" "-DCMAKE_CXX_COMPILER_LAUNCHER=$(command -v ccache)")
    fi
}

load_pinned_fetchcontent_args() {
    local argument output
    CMAKE_FETCHCONTENT_ARGS=()
    output="$(python3 "$SCRIPTS_ROOT/dependencies/fetchcontent_overrides.py" "$LIBRARIES_ROOT")" || return 1
    while IFS= read -r argument; do
        [[ -n "$argument" ]] && CMAKE_FETCHCONTENT_ARGS+=("$argument")
    done <<< "$output"
}

run_ninja_install() {
    local build_dir="$1"
    local build_jobs="${BUILD_JOBS:-4}"
    local build_type="${BUILD_TYPE:-Release}"

    "$CMAKE_BIN" --build "$build_dir" --target install --config "$build_type" --parallel "$build_jobs"
}
