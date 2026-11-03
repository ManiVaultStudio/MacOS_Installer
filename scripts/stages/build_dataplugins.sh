#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIBRARIES_ROOT="${LIBRARIES_ROOT:-$(cd "$SCRIPTS_ROOT/../libraries" && pwd)}"
source "$SCRIPTS_ROOT/config/dependency_paths.sh"
source "$SCRIPTS_ROOT/config/project_build.sh"
source "$SCRIPTS_ROOT/lib/repo_config.sh"
source "$SCRIPTS_ROOT/lib/cmake_config.sh"
source "$SCRIPTS_ROOT/lib/agl_workaround.sh"

find_build_cmake
find_build_ninja

export PKG_CONFIG_PATH="${LIBRARIES_ROOT}/lz4-${LZ4_VERSION:-1.9.4}/build_universal/lib/pkgconfig:${LIBRARIES_ROOT}/flann/build_universal/lib/pkgconfig:${LIBRARIES_ROOT}/qads/build_universal/lib/pkgconfig:${LIBRARIES_ROOT}/hdf5-${HDF5_VERSION:-1.14.6}/install_universal_static/lib/pkgconfig:${LIBRARIES_ROOT}/zlib-${ZLIB_VERSION:-1.3.1}/build_universal/lib/pkgconfig:${LIBRARIES_ROOT}/cups-${CUPS_VERSION:-2.4.14}/build_universal/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export CMAKE_PREFIX_PATH="${LIBRARIES_ROOT}/qads/build_universal:${LIBRARIES_ROOT}/hdf5-${HDF5_VERSION:-1.14.6}/install_universal_static:${LIBRARIES_ROOT}/zlib-${ZLIB_VERSION:-1.3.1}/build_universal:${LIBRARIES_ROOT}/cups-${CUPS_VERSION:-2.4.14}/build_universal:${CMAKE_PREFIX_PATH:-}"


# --- OpenMP Configuration ---
# Check if custom OpenMP is available
if [ -d "$OPENMP_BUILD_DIR" ]; then
    echo "✅ Using custom-built universal OpenMP library"
    export CMAKE_PREFIX_PATH="$OPENMP_BUILD_DIR:${CMAKE_PREFIX_PATH:-}"
    export PKG_CONFIG_PATH="$OPENMP_BUILD_DIR/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

    OPENMP_PREFIX="$OPENMP_BUILD_DIR"
    OPENMP_INCLUDE="$OPENMP_BUILD_DIR/include"
    OPENMP_LIB="$OPENMP_BUILD_DIR/lib"
    CMAKE_PREFIX_PATH_CMAKE="$OPENMP_BUILD_DIR;$QT_DIR;${LIBRARIES_ROOT}/lz4-${LZ4_VERSION:-1.9.4}/build_universal;${LIBRARIES_ROOT}/flann/build_universal;${LIBRARIES_ROOT}/qads/build_universal;${LIBRARIES_ROOT}/hdf5-${HDF5_VERSION:-1.14.6}/install_universal_static;${HDF5_CMAKE_DIR};${HDF5_LIB_DIR};${LIBRARIES_ROOT}/zlib-${ZLIB_VERSION:-1.3.1}/build_universal;${ZLIB_DIR};${LIBRARIES_ROOT}/cups-${CUPS_VERSION:-2.4.14}/build_universal"
else
    echo "❌ Universal OpenMP library not found!"
    echo "💡 Run './build_openmp_universal_updated.sh' first to build the required universal OpenMP library"
    echo "🚫 Only the custom-built universal OpenMP library is supported"
    exit 1
fi
NUM_CORES=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)
BUILD_JOBS="${BUILD_JOBS:-2}"
CC_BIN="${CC:-/usr/bin/cc}"
CXX_BIN="${CXX:-/usr/bin/c++}"

# Check for macOS SDK
find_macos_sdk
prepare_common_cmake_args
load_pinned_fetchcontent_args

echo "=== Build Configuration ==="
echo "Script directory: $SCRIPT_DIR"
echo "Install directory: $INSTALL_DIR"
echo "ManiVault directory: $MANIVAULT_DIR"
echo "Qt directory: $QT_CMAKE_DIR"
echo "OpenMP include: $OPENMP_INCLUDE"
echo "OpenMP lib: $OPENMP_LIB"
echo "CPU cores detected: $NUM_CORES"
echo "Building with $BUILD_JOBS parallel jobs"
echo "Building for macOS (universal binary) with Ninja"
echo "=========================="
echo ""

# Create install directory if it doesn't exist
mkdir -p "$INSTALL_DIR"

# Option to parallelize builds
PARALLEL_BUILD=false  # Set to false to run sequentially
repos=()
while IFS= read -r repo_name; do
    [ -n "$repo_name" ] && repos+=("$repo_name")
done < <(json_repo_keys "${DATAPLUGIN_REPOS:-}")

if [ ${#repos[@]} -eq 0 ]; then
    echo "No dataplugins configured for this profile. Skipping dataplugin build step."
    exit 0
fi

build_repo() {
    local repo="$1"
    echo "=== Building $repo ==="
    SOURCE_DIR="$SOURCE_ROOT/$repo"
    BUILD_DIR="$BUILD_ROOT/$repo"
    bash "$SCRIPTS_ROOT/repos/ensure_submodules.sh" "$SOURCE_DIR"
    echo "Source: $SOURCE_DIR"
    echo "Build: $BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    echo "Configuring CMake for $repo..."

    # Clear environment variables that might interfere with OpenMP detection
    unset OMP_NUM_THREADS 2>/dev/null || true

    "$CMAKE_BIN" "${CMAKE_COMMON_ARGS[@]}" "${CMAKE_FETCHCONTENT_ARGS[@]}" -S "$SOURCE_DIR" -B "$BUILD_DIR" \
        -DCMAKE_DISABLE_PRECOMPILE_HEADERS=ON \
        -DCMAKE_MODULE_PATH="$SCRIPTS_ROOT/cmake" \
        -Dhdf5_DIR="$SCRIPTS_ROOT/cmake/hdf5" \
        -DCups_DIR="$SCRIPTS_ROOT/cmake/Cups" \
        -DManiVault_DIR="$MANIVAULT_DIR" \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
        -DQt6_DIR="$QT_CMAKE_DIR" \
        -DCMAKE_PREFIX_PATH="$CMAKE_PREFIX_PATH_CMAKE" \
        -DCMAKE_LIBRARY_PATH="$OPENMP_LIB" \
        -DCMAKE_INCLUDE_PATH="$OPENMP_INCLUDE" \
        -DCMAKE_C_FLAGS="-Xpreprocessor -fopenmp -I$OPENMP_INCLUDE" \
        -DCMAKE_CXX_FLAGS="-DGL_SILENCE_DEPRECATION -Xpreprocessor -fopenmp -I$OPENMP_INCLUDE" \
        -DCMAKE_EXE_LINKER_FLAGS="-L$OPENMP_LIB -lomp" \
        -DCMAKE_SHARED_LINKER_FLAGS="-L$OPENMP_LIB -lomp" \
        -DCMAKE_MODULE_LINKER_FLAGS="-L$OPENMP_LIB -lomp" \
        -DCMAKE_IGNORE_PATH="/opt/homebrew/opt/libomp;/usr/local/opt/libomp;/opt/homebrew;/usr/local" \
        -DCMAKE_FIND_USE_CMAKE_SYSTEM_PATH=OFF \
        -DOpenMP_ROOT="$OPENMP_BUILD_DIR" \
        -DOpenMP_C_FLAGS="-Xpreprocessor -fopenmp -I$OPENMP_INCLUDE" \
        -DOpenMP_CXX_FLAGS="-Xpreprocessor -fopenmp -I$OPENMP_INCLUDE" \
        -DOpenMP_C_LIB_NAMES="omp" \
        -DOpenMP_CXX_LIB_NAMES="omp" \
        -DOpenMP_omp_LIBRARY="$OPENMP_LIB/libomp.dylib" \
        -DOpenMP_C_LIBRARY="$OPENMP_LIB/libomp.dylib" \
        -DOpenMP_CXX_LIBRARY="$OPENMP_LIB/libomp.dylib" \
        -DOpenMP_C_INCLUDE_DIR="$OPENMP_INCLUDE" \
        -DOpenMP_CXX_INCLUDE_DIR="$OPENMP_INCLUDE" \
        -DCUPS_ROOT="$CUPS_BUILD_DIR" \
        -DCUPS_INCLUDE_DIR="${LIBRARIES_ROOT}/cups-${CUPS_VERSION:-2.4.14}/build_universal/include" \
        -DCUPS_LIBRARIES="$CUPS_BUILD_DIR/lib/libcups.2.dylib" \
        -DOpenGL_GL_PREFERENCE=LEGACY \
        -DOPENGL_INCLUDE_DIR="$MACOS_SDK_PATH/System/Library/Frameworks/OpenGL.framework/Headers" \
        -DOPENGL_gl_LIBRARY="$MACOS_SDK_PATH/System/Library/Frameworks/OpenGL.framework"

    # Apply AGL fix after CMake configuration
    fix_agl_issue "$BUILD_DIR"

    echo "Building and installing $repo with $BUILD_JOBS jobs..."

    if ! run_ninja_install "$BUILD_DIR"; then
        echo "Build failed for $repo. Applying AGL workaround and retrying once..."
        fix_agl_issue "$BUILD_DIR"

        if ! run_ninja_install "$BUILD_DIR"; then
            echo "ERROR: Build failed again for $repo."
            return 1
        fi
    fi

    echo "✓ $repo build completed successfully"
    echo ""
}

if [ "$PARALLEL_BUILD" = true ]; then
    for repo in "${repos[@]}"; do
        build_repo "$repo" &
    done
    wait
else
    for repo in "${repos[@]}"; do
        build_repo "$repo"
    done
fi

echo "=== Build Summary ==="
echo "All repositories built successfully!"
echo "Installation directory: $INSTALL_DIR"
echo "=========================="
