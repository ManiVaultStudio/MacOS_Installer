#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIBRARIES_ROOT="${LIBRARIES_ROOT:-$(cd "$SCRIPTS_ROOT/../libraries" && pwd)}"
source "$SCRIPTS_ROOT/config/dependency_paths.sh"
source "$SCRIPTS_ROOT/config/project_build.sh"
CPM_SOURCE_CACHE="${CPM_SOURCE_CACHE:-$LIBRARIES_ROOT/cpm-cache}"
export CPM_SOURCE_CACHE
mkdir -p "$CPM_SOURCE_CACHE/cpm"
if [[ ! -s "$CPM_SOURCE_CACHE/cpm/CPM_0.42.0.cmake" && -s "$LIBRARIES_ROOT/cpm-cache/cpm/CPM_0.42.0.cmake" ]]; then
    cp "$LIBRARIES_ROOT/cpm-cache/cpm/CPM_0.42.0.cmake" "$CPM_SOURCE_CACHE/cpm/CPM_0.42.0.cmake"
fi

source "$SCRIPTS_ROOT/lib/repo_config.sh"
source "$SCRIPTS_ROOT/lib/cmake_config.sh"
source "$SCRIPTS_ROOT/lib/agl_workaround.sh"

find_build_cmake
find_build_ninja



# ============================================================
# OpenMP
# ============================================================

if [ -d "$OPENMP_BUILD_DIR" ]; then
    echo "Using custom-built universal OpenMP library."

    export CMAKE_PREFIX_PATH="$OPENMP_BUILD_DIR:${CMAKE_PREFIX_PATH:-}"
    export PKG_CONFIG_PATH="$OPENMP_BUILD_DIR/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

    OPENMP_PREFIX="$OPENMP_BUILD_DIR"
    OPENMP_INCLUDE="$OPENMP_BUILD_DIR/include"
    OPENMP_LIB="$OPENMP_BUILD_DIR/lib"

    CMAKE_PREFIX_PATH_CMAKE="\
$OPENMP_BUILD_DIR;\
$QT_DIR;\
${LIBRARIES_ROOT}/lz4-${LZ4_VERSION:-1.9.4}/build_universal;\
${LIBRARIES_ROOT}/flann/build_universal;\
${LIBRARIES_ROOT}/qads/build_universal;\
${HDF5_INSTALL_DIR};\
${HDF5_CMAKE_DIR};\
${HDF5_COMPAT_CMAKE_DIR};\
${HDF5_LIB_DIR};\
${ZLIB_ROOT};\
${ZLIB_DIR};\
${CUPS_BUILD_DIR}"
else
    echo "ERROR: Universal OpenMP library not found."
    echo "Run build_openmp_universal_updated.sh first."
    exit 1
fi

NUM_CORES=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)
BUILD_JOBS="${BUILD_JOBS:-2}"

CC_BIN="${CC:-/usr/bin/cc}"
CXX_BIN="${CXX:-/usr/bin/c++}"

find_macos_sdk

prepare_common_cmake_args
load_pinned_fetchcontent_args

# ============================================================
# Display configuration
# ============================================================

echo ""
echo "========== BUILD CONFIGURATION =========="
echo "Script directory:       $SCRIPT_DIR"
echo "Libraries directory:    $LIBRARIES_ROOT"
echo "Install directory:      $INSTALL_DIR"
echo "ManiVault directory:    $MANIVAULT_DIR"
echo "Qt directory:           $QT_CMAKE_DIR"
echo "OpenMP include:         $OPENMP_INCLUDE"
echo "OpenMP library:         $OPENMP_LIB"
echo "HDF5 install:           $HDF5_INSTALL_DIR"
echo "HDF5 CMake:             $HDF5_CMAKE_DIR"
echo "HDF5 compatibility:     $HDF5_COMPAT_CMAKE_DIR"
echo "CUPS build:             $CUPS_BUILD_DIR"
echo "ZLIB CMake:             $ZLIB_DIR"
echo "CPU cores:              $NUM_CORES"
echo "Build jobs:             $BUILD_JOBS"
echo "Build type:             $BUILD_TYPE"
echo "Architectures:          $ARCHS"
echo "Minimum macOS:          $MIN_MACOS_VERSION"
echo "========================================="
echo ""

# ============================================================
# Plugin list
# ============================================================

repos=()

while IFS= read -r repo_name; do
    [ -n "$repo_name" ] && repos+=("$repo_name")
done < <(json_repo_keys "${PLUGIN_REPOS:-}")

if [ ${#repos[@]} -eq 0 ]; then
    echo "No plugins configured for this profile. Skipping plugin build."
    exit 0
fi

# ============================================================
# Build individual plugin
# ============================================================

build_plugin() {
    local repo="$1"

    echo ""
    echo "========================================="
    echo "Building $repo"
    echo "========================================="

    if [[ "$repo" == "t-SNE-Analysis" ]]; then
        if [ -z "$(json_repo_branch "${PLUGIN_REPOS:-}" "$repo")" ]; then
            echo "No t-SNE-Analysis configured. Skipping."
            return 0
        fi

        echo "Using dedicated t-SNE build script."

        "$SCRIPTS_ROOT/stages/plugins/build_tsne_plugin.sh"

        echo "Completed $repo."
        return 0
    fi

    local SOURCE_DIR="$SOURCE_ROOT/$repo"
    local BUILD_DIR="$BUILD_ROOT/$repo"

    if [[ "$repo" == "ExamplePlugins" ]]; then
        local override_root="$BUILD_ROOT/_source_overrides"
        local override_source="$override_root/ExamplePlugins"
        echo "Preparing isolated ExamplePlugins source copy under $override_source ..."
        mkdir -p "$override_root"
        local source_time_state="$BUILD_ROOT/.source-times-ExamplePlugins.json"
        python3 "$SCRIPTS_ROOT/lib/source_timestamps.py" begin "$override_source" "$source_time_state"
        mkdir -p "$override_source"
        rsync -a --checksum --delete "$SOURCE_DIR/" "$override_source/"
        python3 "$SCRIPTS_ROOT/dependencies/patch_exampleplugins_cmake_defaults.py" "$override_root"
        python3 "$SCRIPTS_ROOT/lib/source_timestamps.py" finish "$override_source" "$source_time_state"
        SOURCE_DIR="$override_source"
    fi


    bash "$SCRIPTS_ROOT/repos/ensure_submodules.sh" "$SOURCE_DIR"

    # --------------------------------------------------------
    # UMAP dependency overlay
    # The installer applies the pinned UMAPPP patch centrally.
    # Do not apply the plugin-local UMAPPP patch a second time.
    # Keep the original plugin checkout unchanged.
    # --------------------------------------------------------
    if [[ "$repo" == "UMAP-Plugin" ]]; then
        local override_root="$BUILD_ROOT/_source_overrides"
        local override_source="$override_root/UMAP-Plugin"

        echo "Preparing isolated UMAP-Plugin source overlay at $override_source ..."
        mkdir -p "$override_source"
        rsync -a --exclude='.git' "$SOURCE_DIR/" "$override_source/"

        local umap_dependencies_file="$override_source/cmake/GetExternalDependencies.cmake"

        if [[ ! -f "$umap_dependencies_file" ]]; then
            echo "ERROR: UMAP dependency file not found: $umap_dependencies_file"
            return 1
        fi

        python3 - "$umap_dependencies_file" <<'PYTHON'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text()

# These dependencies are patched centrally by the installer registry.
# Use the unpatched CPM helper in the plugin overlay to avoid applying
# the original plugin-local patches a second time.
dependencies = ("umappp", "knncolle_hnsw", "knncolle_annoy")

for name in dependencies:
    pattern = re.compile(
        r'^([ \t]*)fetch_cpm_repo_patch\(\s*'
        + re.escape(name)
        + r'\s+("[^"]+")\s+([^\s)]+)\s+"[^"]+"\s*\)',
        re.MULTILINE,
    )

    text, replacements = pattern.subn(
        lambda match: (
            f"{match.group(1)}fetch_cpm_repo("
            f"{name} {match.group(2)} {match.group(3)})"
        ),
        text,
    )

    if replacements != 1:
        raise SystemExit(
            f"ERROR: Expected exactly one patched declaration for "
            f"{name}; found {replacements}."
        )

    if re.search(
        r'^[ \t]*fetch_cpm_repo_patch\(\s*'
        + re.escape(name)
        + r'\b',
        text,
        re.MULTILINE,
    ):
        raise SystemExit(f"ERROR: Local patch declaration remains for {name}.")

if path.read_text() != text:
    path.write_text(text)
print("Central-patch protection prepared for UMAPPP, HNSW and Annoy.")
PYTHON

        if [[ $? -ne 0 ]]; then
            echo "ERROR: Could not prepare UMAP dependency overlay."
            return 1
        fi

        SOURCE_DIR="$override_source"
        BUILD_DIR="$BUILD_ROOT/UMAP-Plugin-overlay"
    fi

    echo "Source: $SOURCE_DIR"
    echo "Build:  $BUILD_DIR"

    mkdir -p "$BUILD_DIR"

    echo "Configuring CMake for $repo..."

    local ZLIB_STATIC_LIB="${ZLIB_ROOT}/lib/libz.a"
    local HDF5_CPP_STATIC_LIB="${HDF5_LIB_DIR}/libhdf5_cpp.a"
    local HDF5_STATIC_LIB="${HDF5_LIB_DIR}/libhdf5.a"
    local HDF5_HL_CPP_STATIC_LIB="${HDF5_LIB_DIR}/libhdf5_hl_cpp.a"
    local HDF5_HL_STATIC_LIB="${HDF5_LIB_DIR}/libhdf5_hl.a"

    # --------------------------------------------------------
    # CMake arguments
    # --------------------------------------------------------

    local cmake_args=(
        "${CMAKE_COMMON_ARGS[@]}"
        -S "$SOURCE_DIR"
        -B "$BUILD_DIR"

        -DCMAKE_DISABLE_PRECOMPILE_HEADERS=ON
        "-DCMAKE_MODULE_PATH=$SCRIPTS_ROOT/cmake"

        "-DCMAKE_PREFIX_PATH=$CMAKE_PREFIX_PATH_CMAKE"

        "-DCUPS_INCLUDE_DIR=${CUPS_BUILD_DIR}/include"
        "-DCUPS_LIBRARIES=${CUPS_BUILD_DIR}/lib/libcups.2.dylib"

        "-DCMAKE_LIBRARY_PATH=$OPENMP_LIB"
        "-DCMAKE_INCLUDE_PATH=$OPENMP_INCLUDE"

        -DCMAKE_FIND_PACKAGE_PREFER_CONFIG=ON

        "-DManiVault_DIR=$MANIVAULT_DIR"
        "-DCMAKE_INSTALL_PREFIX=$INSTALL_DIR"
        "-DQt6_DIR=$QT_CMAKE_DIR"

        "-DCMAKE_C_FLAGS=-Xpreprocessor -fopenmp -I$OPENMP_INCLUDE"
        "-DCMAKE_CXX_FLAGS=-DGL_SILENCE_DEPRECATION -Xpreprocessor -fopenmp -I$OPENMP_INCLUDE"

        "-DCMAKE_EXE_LINKER_FLAGS=-L$OPENMP_LIB -lomp $ZLIB_STATIC_LIB $HDF5_CPP_STATIC_LIB $HDF5_STATIC_LIB $HDF5_HL_CPP_STATIC_LIB $HDF5_HL_STATIC_LIB"
        "-DCMAKE_SHARED_LINKER_FLAGS=-L$OPENMP_LIB -lomp $ZLIB_STATIC_LIB $HDF5_CPP_STATIC_LIB $HDF5_STATIC_LIB $HDF5_HL_CPP_STATIC_LIB $HDF5_HL_STATIC_LIB"
        "-DCMAKE_MODULE_LINKER_FLAGS=-L$OPENMP_LIB -lomp $ZLIB_STATIC_LIB $HDF5_CPP_STATIC_LIB $HDF5_STATIC_LIB $HDF5_HL_CPP_STATIC_LIB $HDF5_HL_STATIC_LIB"

        "-DCMAKE_IGNORE_PATH=/opt/homebrew/opt/libomp;/usr/local/opt/libomp;/opt/homebrew;/usr/local"
        -DCMAKE_FIND_USE_CMAKE_SYSTEM_PATH=OFF

        "-DOpenMP_ROOT=$OPENMP_BUILD_DIR"
        "-DOpenMP_C_FLAGS=-Xpreprocessor -fopenmp -I$OPENMP_INCLUDE"
        "-DOpenMP_CXX_FLAGS=-Xpreprocessor -fopenmp -I$OPENMP_INCLUDE"

        -DOpenMP_C_LIB_NAMES=omp
        -DOpenMP_CXX_LIB_NAMES=omp

        "-DOpenMP_omp_LIBRARY=$OPENMP_LIB/libomp.dylib"
        "-DOpenMP_C_LIBRARY=$OPENMP_LIB/libomp.dylib"
        "-DOpenMP_CXX_LIBRARY=$OPENMP_LIB/libomp.dylib"

        "-DOpenMP_C_INCLUDE_DIR=$OPENMP_INCLUDE"
        "-DOpenMP_CXX_INCLUDE_DIR=$OPENMP_INCLUDE"

        -DOpenGL_GL_PREFERENCE=LEGACY
        "-DOPENGL_INCLUDE_DIR=$MACOS_SDK_PATH/System/Library/Frameworks/OpenGL.framework/Headers"
        "-DOPENGL_gl_LIBRARY=$MACOS_SDK_PATH/System/Library/Frameworks/OpenGL.framework"

        "-Dhdf5_DIR=$SCRIPTS_ROOT/cmake/hdf5"
        "-DCups_DIR=$SCRIPTS_ROOT/cmake/Cups"
    )

    # Use the central dependency catalog's verified, pinned CMake source paths.
    cmake_args+=("${CMAKE_FETCHCONTENT_ARGS[@]}")

    # CppIrlba exports irlba, which links to Eigen's "eigen" target.
    # Enable Eigen's own CMake export set so CppIrlba can export correctly.
    if [[ "$repo" == "UMAP-Plugin" ]]; then
        cmake_args+=(
            -DEIGEN_BUILD_CMAKE_PACKAGE=ON
        )
    fi

    # --------------------------------------------------------
    # Plugin-specific library settings
    # --------------------------------------------------------

    if [[ "$repo" == "XSCPhyTVuPlugin" ||
          "$repo" == "XSCLoaderPlugin" ||
          "$repo" == "XSCGeneDetectPlugin" ]]; then

        cmake_args+=(
            "-DXSCTREEDATA_LINK_LIBRARY=$PLUGIN_INSTALL_DIR/libXSCTreeData.dylib"
            "-DXSCTREEMETADATA_LINK_LIBRARY=$PLUGIN_INSTALL_DIR/libXSCTreeMetaData.dylib"
        )
    fi

    # HDF5Loader must link the already-built shared HDF5/zlib artifacts.
    # Enabling its package-based path avoids a second, private HDF5 clone/build.
    if [[ "$repo" == "HDF5Loader" ]]; then
        cmake_args+=(
            -DMV_H5_USE_VCPKG=ON
            -DFETCHCONTENT_UPDATES_DISCONNECTED=ON
        )
    fi

    # Conda's macOS OpenSSL package provides shared libraries, not libcrypto.a.
    # JupyterPlugin consumes OpenSSL through xeus-zmq, so avoid a stale/global
    # static-link preference that points the linker at a nonexistent archive.
    if [[ "$repo" == "JupyterPlugin" ]]; then
        cmake_args+=(
            -DOPENSSL_USE_STATIC_LIBS=OFF
            "-DOPENSSL_ROOT_DIR=${CONDA_PREFIX:-}/"
        )
    fi

    if [[ "$repo" == "XSCClusterRankPlugin" ]]; then
        cmake_args+=(
            "-DXSCTREEDATA_LINK_LIBRARY=$PLUGIN_INSTALL_DIR/libXSCTreeData.dylib"
        )
    fi

    # --------------------------------------------------------
    # MEView temporary patch
    # --------------------------------------------------------

    if [[ "$repo" == "MEView" ]]; then
        echo "Creating a temporary MEView source overlay under the build directory..."
        local patch_source_dir="$BUILD_ROOT/_source_overrides/MEView"
        mkdir -p "$(dirname "$patch_source_dir")"
        local meview_time_state="$BUILD_ROOT/.source-times-MEView.json"
        python3 "$SCRIPTS_ROOT/lib/source_timestamps.py" begin "$patch_source_dir" "$meview_time_state"
        mkdir -p "$patch_source_dir"
        rsync -a --checksum --delete --exclude='.git' "$SOURCE_DIR/" "$patch_source_dir/"
        SOURCE_DIR="$patch_source_dir"
        local patched_cmake_file="$SOURCE_DIR/CMakeLists.txt"

        sed -i '' \
            's/^set(CELL_MORPHOLOGY_DATA_LINK_LIBRARY/# set(CELL_MORPHOLOGY_DATA_LINK_LIBRARY/' \
            "$patched_cmake_file"

        sed -i '' \
            's/^set(EPHYS_DATA_LINK_LIBRARY/# set(EPHYS_DATA_LINK_LIBRARY/' \
            "$patched_cmake_file"

        cmake_args+=(
            "-DCELL_MORPHOLOGY_DATA_LINK_LIBRARY=$PLUGIN_INSTALL_DIR/libCellMorphologyData.dylib"
            "-DEPHYS_DATA_LINK_LIBRARY=$PLUGIN_INSTALL_DIR/libEphysData.dylib"
        )
    fi

    # --------------------------------------------------------
    # Configure
    # --------------------------------------------------------
    if [[ "$repo" == "MEView" ]]; then
        python3 "$SCRIPTS_ROOT/lib/source_timestamps.py" finish "$SOURCE_DIR" "$meview_time_state"
    fi

    unset OMP_NUM_THREADS 2>/dev/null || true

    if ! "$CMAKE_BIN" "${cmake_args[@]}"; then
        echo "ERROR: CMake configuration failed for $repo."
        return 1
    fi

    # --------------------------------------------------------
    # Restore any temporary source patch
    # --------------------------------------------------------

    fix_agl_issue "$BUILD_DIR"

    # --------------------------------------------------------
    # Build and install
    # --------------------------------------------------------

    echo "Building and installing $repo with $BUILD_JOBS jobs..."

    if ! run_ninja_install "$BUILD_DIR"; then
        echo "Build failed. Applying AGL workaround and retrying once..."

        fix_agl_issue "$BUILD_DIR"

        if ! run_ninja_install "$BUILD_DIR"; then
            echo "ERROR: Build failed again for $repo."
            return 1
        fi
    fi

    echo "Completed $repo successfully."
    echo ""
}

# ============================================================
# Build plugins
# ============================================================

PARALLEL_BUILD=false

if [ "$PARALLEL_BUILD" = true ]; then
    for repo in "${repos[@]}"; do
        build_plugin "$repo" &
    done

    wait
else
    for repo in "${repos[@]}"; do
        build_plugin "$repo"
    done
fi

# ============================================================
# Summary
# ============================================================

echo ""
echo "========================================="
echo "BUILD SUMMARY"
echo "========================================="
echo "All configured repositories built successfully."
echo "Installation directory: $INSTALL_DIR"
echo "========================================="
