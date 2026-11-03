#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPTS_ROOT/lib/cmake_config.sh"
LIBRARIES_ROOT="${LIBRARIES_ROOT:-$(cd "$SCRIPTS_ROOT/../libraries" && pwd)}"
source "$SCRIPTS_ROOT/config/project_build.sh"
source "$SCRIPTS_ROOT/lib/repo_config.sh"

if [ -z "$(json_repo_branch "${PLUGIN_REPOS:-}" "t-SNE-Analysis")" ]; then
    echo "No t-SNE-Analysis configured for this profile. Skipping t-SNE build step."
    exit 0
fi

find_build_cmake
find_build_ninja

export PKG_CONFIG_PATH="${LIBRARIES_ROOT}/lz4-${LZ4_VERSION:-1.9.4}/build_universal/lib/pkgconfig:${LIBRARIES_ROOT}/fmt-${FMT_VERSION:-11.1.4}/build_universal/lib/pkgconfig:${LIBRARIES_ROOT}/flann/build_universal/lib/pkgconfig:${LIBRARIES_ROOT}/qads/build_universal/lib/pkgconfig:${LIBRARIES_ROOT}/hdf5-${HDF5_VERSION:-1.14.6}/install_universal_static/lib/pkgconfig:${LIBRARIES_ROOT}/zlib-${ZLIB_VERSION:-1.3.1}/build_universal/lib/pkgconfig:${LIBRARIES_ROOT}/cups-${CUPS_VERSION:-2.4.14}/build_universal/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export CMAKE_PREFIX_PATH="${LIBRARIES_ROOT}/qads/build_universal/lib/cmake/qads:${LIBRARIES_ROOT}/hdf5-${HDF5_VERSION:-1.14.6}/install_universal_static/share/cmake/hdf5:${LIBRARIES_ROOT}/zlib-${ZLIB_VERSION:-1.3.1}/build_universal/share/cmake/zlib:${LIBRARIES_ROOT}/cups-${CUPS_VERSION:-2.4.14}/build_universal:${CMAKE_PREFIX_PATH:-}"

# ----------- AGL FIX FUNCTION -----------
# fix_agl_issue() {
#     local build_dir="$1"
#     echo "🔧 Checking for AGL linker issues in $build_dir..."

#     # Look for link.txt files that might contain AGL references
#     local link_files=$(find "$build_dir" -name "link.txt" -type f 2>/dev/null || true)

#     for link_file in $link_files; do
#         if grep -q "AGL" "$link_file" || grep -q "-framework AGL" "$link_file"; then
#             echo "✅ Fixing AGL reference in: $(basename $(dirname $(dirname $link_file)))"
#             # Remove AGL framework references
#             sed -i '' 's/-framework AGL//g' "$link_file"
#             sed -i '' 's/  / /g' "$link_file"
#             sed -i '' 's/ -framework$/ /g' "$link_file"
#             sed -i '' 's/^-framework / /g' "$link_file"
#         fi
#     done

#     # Also check for AGL in build.ninja files
#     local ninja_files=$(find "$build_dir" -name "build.ninja" -type f 2>/dev/null || true)
#     for ninja_file in $ninja_files; do
#         if grep -q "AGL" "$ninja_file"; then
#             echo "✅ Fixing AGL reference in build.ninja"
#             sed -i '' 's/-framework AGL//g' "$ninja_file"
#             # Clean up any resulting issues
#             sed -i '' 's/  / /g' "$ninja_file"
#             sed -i '' 's/ -framework$/ /g' "$ninja_file"
#         fi
#     done
# }

fix_agl_issue() {
    local build_dir="$1"

    echo "🔧 Removing obsolete AGL framework references..."

    find "$build_dir" -type f \( \
        -name "link.txt" -o \
        -name "build.ninja" \
    \) -exec sed -i '' \
        -e 's/-framework AGL//g' \
        -e 's/  */ /g' \
        -e 's/-framework $//g' \
        {} +

    echo "✅ AGL cleanup complete"
}

# --- Compute build/install locations (profile-aware) ---
CONFIG_LABEL="$(echo "$BUILD_TYPE" | tr '[:upper:]' '[:lower:]')"
BUILD_DIR="$BUILD_ROOT/t-SNE-Analysis"
SOURCE_INPUT="$SOURCE_ROOT/t-SNE-Analysis"
SOURCE_OVERRIDE_ROOT="$BUILD_ROOT/_source_overrides"
SOURCE_DIR="$SOURCE_OVERRIDE_ROOT/t-SNE-Analysis"
CC_BIN="${CC:-/usr/bin/cc}"
CXX_BIN="${CXX:-/usr/bin/c++}"
mkdir -p "$BUILD_DIR" "$INSTALL_DIR"

if [ ! -d "$SOURCE_INPUT" ]; then
    echo "❌ t-SNE source directory not found: $SOURCE_INPUT"
    echo "💡 Ensure t-SNE-Analysis is listed in PLUGIN_REPOS and cloned for this profile."
    exit 1
fi
echo "Preparing isolated t-SNE source copy under $SOURCE_DIR ..."
SOURCE_TIME_STATE="$BUILD_ROOT/.source-times-$(basename "$SOURCE_DIR").json"
python3 "$SCRIPTS_ROOT/lib/source_timestamps.py" begin "$SOURCE_DIR" "$SOURCE_TIME_STATE"
mkdir -p "$SOURCE_DIR"
rsync -a --checksum --delete "$SOURCE_INPUT/" "$SOURCE_DIR/"
python3 "$SCRIPTS_ROOT/dependencies/patch_tsne_serialization_api.py" "$SOURCE_OVERRIDE_ROOT"
python3 "$SCRIPTS_ROOT/lib/source_timestamps.py" finish "$SOURCE_DIR" "$SOURCE_TIME_STATE"
echo "t-SNE source checkout remains untouched: $SOURCE_INPUT"

# Set local dependency paths
HDILIB_ROOT="$LIBRARIES_ROOT/HDILibLatestVulkan/install_universal/lib/cmake/HDILib"
MANIVAULT_DIR="$INSTALL_DIR/cmake/mv"
#QT_DIR="$LIBRARIES_ROOT/QTFromArtifactory/QT683"
#QT_DIR="$LIBRARIES_ROOT/qt_builds/qt_universal"
QT_DIR="${QT_DIR:-$SCRIPTS_ROOT/../../libraries/qt/${QT_VERSION:-6.10.3}/macos}"
QT_CMAKE_DIR="$QT_DIR/lib/cmake/Qt6"

# Use existing FLANN installation
FLANN_DIR="${LIBRARIES_ROOT}/flann/build_universal"

KOMPUTE_PREFIX="$LIBRARIES_ROOT/kompute/install_universal"
KOMPUTE_CMAKE_DIR="$KOMPUTE_PREFIX/lib/cmake/kompute"
KOMPUTE_INCLUDE="$KOMPUTE_PREFIX/include"
GLFW_CMAKE_DIR="$LIBRARIES_ROOT/glfw-${GLFW_VERSION:-3.4}/build_universal/lib/cmake/glfw3"

# Use local universal fmt installation
FMT_DIR="${LIBRARIES_ROOT}/fmt-${FMT_VERSION:-11.1.4}/build_universal"
FMT_CMAKE_DIR="${FMT_DIR}/lib/cmake/fmt"
FMT_INCLUDE_DIR="${FMT_DIR}/include"
FMT_LIB_DIR="${FMT_DIR}/lib"

echo "✅ Using local fmt:"
echo "   FMT_DIR=$FMT_DIR"
echo "   FMT_CMAKE_DIR=$FMT_CMAKE_DIR"


# --- OpenMP Configuration ---
OPENMP_VERSION="${OPENMP_VERSION:-21.1.2}"
OPENMP_BUILD_DIR="$LIBRARIES_ROOT/openmp-${OPENMP_VERSION}/build_universal"

# Check if custom OpenMP is available, otherwise try system/homebrew OpenMP
if [ -d "$OPENMP_BUILD_DIR" ]; then
    echo "✅ Using custom-built universal OpenMP library"
    export CMAKE_PREFIX_PATH="$OPENMP_BUILD_DIR:${CMAKE_PREFIX_PATH:-}"
    export PKG_CONFIG_PATH="$OPENMP_BUILD_DIR/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

    OPENMP_PREFIX="$OPENMP_BUILD_DIR"
    OPENMP_INCLUDE="$OPENMP_BUILD_DIR/include"
    OPENMP_LIB="$OPENMP_BUILD_DIR/lib"
    OPENMP_LIB_PATH="$OPENMP_LIB/libomp.dylib"
    OPENMP_COMPAT_LIB="$LIBRARIES_ROOT/libomp_compat.dylib"

    echo "🔍 OpenMP debug:"
    echo "OPENMP_LIB_PATH=$OPENMP_LIB_PATH"

    if [ -f "$OPENMP_LIB_PATH" ]; then
        if nm "$OPENMP_LIB_PATH" | grep -q "__kmpc_dispatch_deinit"; then
            echo "✅ Found __kmpc_dispatch_deinit"
        else
            echo "❌ Missing __kmpc_dispatch_deinit"
        fi
    else
        echo "❌ OpenMP library does not exist"
    fi

    if ! nm "$OPENMP_LIB_PATH" 2>/dev/null | grep -q "__kmpc_dispatch_deinit"; then
        if [ ! -f "$OPENMP_COMPAT_LIB" ]; then
            echo "ERROR: The OpenMP compatibility library is missing. Build it in the dependency stage before building t-SNE." >&2
            exit 1
        fi
        ADDITIONAL_OPENMP_LIB="$OPENMP_COMPAT_LIB"
    fi
else
    echo "❌ Universal OpenMP library not found!"
    echo "� Run './build_openmp.sh' first to build the required universal OpenMP library"
    echo "   $OPENMP_BUILD_DIR/lib/libomp.dylib"
    echo "🚫 Or install system OpenMP with: brew install libomp"
    exit 1
fi

# Get number of available CPU cores
NUM_CORES=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)
BUILD_JOBS="${BUILD_JOBS:-2}"

find_macos_sdk

# Create symlink to fix the library path issue
FLANN_CMAKE_DIR="${FLANN_DIR}/lib/cmake"
mkdir -p "$FLANN_CMAKE_DIR"

# Don't change directory - just create absolute path symlinks
ln -sf "${FLANN_DIR}/lib/libflann_cpp.dylib" "$FLANN_CMAKE_DIR/"
ln -sf "${FLANN_DIR}/lib/libflann.dylib" "$FLANN_CMAKE_DIR/"

# Also create symlinks for lz4 to ensure it can be found
LZ4_CMAKE_DIR="${LIBRARIES_ROOT}/lz4-${LZ4_VERSION:-1.9.4}/build_universal/lib/cmake"
ln -sf "${LIBRARIES_ROOT}/lz4-${LZ4_VERSION:-1.9.4}/build_universal/lib/liblz4.dylib" "$LZ4_CMAKE_DIR/"

echo "Building with $BUILD_JOBS parallel jobs..."

echo "Building for macOS (universal binary) with Ninja..."

# Clear environment variables that might interfere with OpenMP detection
unset OMP_NUM_THREADS 2>/dev/null || true
# Do not clear dependency discovery paths.
# CMake and pkg-config need these for qads/hdf5/zlib/cups/lz4.
unset CMAKE_FRAMEWORK_PATH

KOMPUTE_BOOTSTRAP="$BUILD_DIR/kompute_bootstrap.cmake"

cat > "$KOMPUTE_BOOTSTRAP" <<EOF
set(kompute_DIR "$KOMPUTE_CMAKE_DIR")
find_package(kompute CONFIG REQUIRED)
EOF

prepare_common_cmake_args
load_pinned_fetchcontent_args

$CMAKE_BIN "${CMAKE_COMMON_ARGS[@]}" "${CMAKE_FETCHCONTENT_ARGS[@]}" -S "$SOURCE_DIR" -B "$BUILD_DIR" \
    -DMV_SNE_USE_ARTIFACTORY_LIBS=OFF \
    -DHDILIB_ROOT="$HDILIB_ROOT" \
    -DManiVault_DIR="$MANIVAULT_DIR" \
    -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
    -DQt6_DIR="$QT_CMAKE_DIR" \
    -Dflann_DIR="${FLANN_DIR}/lib/cmake/flann" \
    -Dfmt_DIR="${FMT_CMAKE_DIR}" \
    -DCMAKE_PROJECT_INCLUDE="$KOMPUTE_BOOTSTRAP" \
    -DCMAKE_PREFIX_PATH="$OPENMP_BUILD_DIR;${FLANN_DIR};${FLANN_DIR}/lib/cmake/flann;${FMT_DIR};${FMT_CMAKE_DIR};${QT_DIR};${KOMPUTE_CMAKE_DIR};${GLFW_CMAKE_DIR};${LIBRARIES_ROOT}/qads/build_universal/lib/cmake/qads;${LIBRARIES_ROOT}/hdf5-${HDF5_VERSION:-1.14.6}/install_universal_static/share/cmake/hdf5;${LIBRARIES_ROOT}/zlib-${ZLIB_VERSION:-1.3.1}/build_universal/share/cmake/zlib;${LIBRARIES_ROOT}/cups-${CUPS_VERSION:-2.4.14}/build_universal" \
    -DCUPS_INCLUDE_DIR="${LIBRARIES_ROOT}/cups-${CUPS_VERSION:-2.4.14}/build_universal/include" \
    -DCUPS_LIBRARIES="${LIBRARIES_ROOT}/cups-${CUPS_VERSION:-2.4.14}/build_universal/lib/libcups.2.dylib" \
    -DCMAKE_LIBRARY_PATH="$OPENMP_LIB;${FLANN_DIR}/lib;${FMT_LIB_DIR};${LIBRARIES_ROOT}/lz4-${LZ4_VERSION:-1.9.4}/build_universal/lib;${LIBRARIES_ROOT}/cups-${CUPS_VERSION:-2.4.14}/build_universal/lib" \
    -DCMAKE_INCLUDE_PATH="$KOMPUTE_INCLUDE;$OPENMP_INCLUDE;${FLANN_DIR}/include;${FMT_INCLUDE_DIR};${LIBRARIES_ROOT}/lz4-${LZ4_VERSION:-1.9.4}/build_universal/include;${LIBRARIES_ROOT}/cups-${CUPS_VERSION:-2.4.14}/build_universal/include" \
    -Dlz4_DIR="${LIBRARIES_ROOT}/lz4-${LZ4_VERSION:-1.9.4}/build_universal/lib/cmake/lz4" \
    -DCMAKE_C_FLAGS="-Xpreprocessor -fopenmp -I$OPENMP_INCLUDE" \
    -DCMAKE_CXX_FLAGS="-DGL_SILENCE_DEPRECATION -I$KOMPUTE_INCLUDE -I$FLANN_DIR/include -Xpreprocessor -fopenmp -I$OPENMP_INCLUDE" \
    -DCMAKE_EXE_LINKER_FLAGS="-L$OPENMP_LIB -lomp -L${FLANN_DIR}/lib -Wl,-rpath,$OPENMP_LIB ${ADDITIONAL_OPENMP_LIB:-}" \
    -DCMAKE_SHARED_LINKER_FLAGS="-L$OPENMP_LIB -lomp -L${FLANN_DIR}/lib ${ADDITIONAL_OPENMP_LIB:-}" \
    -DCMAKE_MODULE_LINKER_FLAGS="-L$OPENMP_LIB -lomp -L${FLANN_DIR}/lib ${ADDITIONAL_OPENMP_LIB:-}" \
    -DCMAKE_IGNORE_PATH="/opt/homebrew;/usr/local;/usr/local/opt/libomp;/opt/homebrew/opt/libomp" \
    -DOpenMP_ROOT="$OPENMP_BUILD_DIR" \
    -DOpenMP_C_FLAGS="-Xpreprocessor -fopenmp -I$OPENMP_INCLUDE" \
    -DOpenMP_CXX_FLAGS="-Xpreprocessor -fopenmp -I$OPENMP_INCLUDE" \
    -DOpenMP_C_LIB_NAMES="omp" \
    -DOpenMP_CXX_LIB_NAMES="omp" \
    -DOpenMP_omp_LIBRARY="$OPENMP_LIB_PATH" \
    -DOpenMP_C_LIBRARY="$OPENMP_LIB_PATH" \
    -DOpenMP_CXX_LIBRARY="$OPENMP_LIB_PATH" \
    -DOpenMP_C_INCLUDE_DIR="$OPENMP_INCLUDE" \
    -DOpenMP_CXX_INCLUDE_DIR="$OPENMP_INCLUDE" \
    -DOPENGL_gl_LIBRARY="$MACOS_SDK_PATH/System/Library/Frameworks/OpenGL.framework" \
    -DOPENGL_INCLUDE_DIR="$MACOS_SDK_PATH/System/Library/Frameworks/OpenGL.framework/Headers" \
    -DOPENGL_glu_LIBRARY="" \
    -DOpenGL_GL_PREFERENCE=LEGACY \
    -DPKG_CONFIG_EXECUTABLE="$SCRIPTS_ROOT/tools/bin/pkg-config" \
    -DCMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY=OFF \
    -DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF \
    -DCMAKE_FIND_USE_CMAKE_SYSTEM_PATH=OFF \
    -DCMAKE_FIND_USE_INSTALL_PREFIX=OFF

# Remove obsolete AGL framework references generated by dependencies
if grep -R "AGL" "$BUILD_DIR" >/dev/null 2>&1; then
    echo "⚠️ Found AGL references, removing..."
    fix_agl_issue "$BUILD_DIR"
else
    echo "✅ No AGL references found"
fi


echo "Building and installing t-SNE-Analysis with $BUILD_JOBS jobs..."
if ! ninja -C "$BUILD_DIR" -j "$BUILD_JOBS" install 2>&1 | grep -v -i -f "$SCRIPTS_ROOT/config/build_output_filter.txt"; then
    echo "❌ Build failed for t-SNE-Analysis. Applying AGL fix and retrying..."
    fix_agl_issue "$BUILD_DIR"
    echo "Retrying build for t-SNE-Analysis..."
    ninja -C "$BUILD_DIR" -j "$BUILD_JOBS" install 2>&1 | grep -v -i -f "$SCRIPTS_ROOT/config/build_output_filter.txt"
fi

echo "Build completed!"
