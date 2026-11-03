#!/bin/bash
# Shared settings for dependency-only builds. These are intentionally separate
# from project build settings because shared libraries are built universally.
: "${DEPENDENCY_BUILD_TYPE:=Release}"
: "${DEPENDENCY_ARCHS:=x86_64;arm64}"
: "${DEPENDENCY_MIN_MACOS_VERSION:=12.0}"
: "${DEPENDENCY_CMAKE_GENERATOR:=Ninja}"
# Dependency builds intentionally use their own settings, even when launched
# from a project profile whose BUILD_TYPE/ARCHS values differ.
BUILD_TYPE="$DEPENDENCY_BUILD_TYPE"
ARCHS="$DEPENDENCY_ARCHS"
MIN_MACOS_VERSION="$DEPENDENCY_MIN_MACOS_VERSION"
: "${LIBRARIES_ROOT:=$SCRIPTS_ROOT/../libraries}"
export DEPENDENCY_BUILD_TYPE DEPENDENCY_ARCHS DEPENDENCY_MIN_MACOS_VERSION DEPENDENCY_CMAKE_GENERATOR
export BUILD_TYPE ARCHS MIN_MACOS_VERSION LIBRARIES_ROOT

# Conservative parallelism keeps dependency builds within laptop memory limits.
: "${BUILD_JOBS:=2}"
export BUILD_JOBS
export CMAKE_BUILD_PARALLEL_LEVEL="$BUILD_JOBS"
