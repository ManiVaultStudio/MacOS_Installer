

#!/bin/bash
set -euo pipefail

# Function to find cmake executable
find_cmake() {
    # Check Homebrew locations first (prioritize brew cmake)
    CMAKE_LOCATIONS=(
        "/opt/homebrew/bin/cmake"  # Apple Silicon Homebrew
        "/usr/local/bin/cmake"     # Intel Homebrew
    )
    
    for location in "${CMAKE_LOCATIONS[@]}"; do
        if [ -x "$location" ]; then
            CMAKE_BIN="$location"
            echo "✅ Found Homebrew CMake at: $CMAKE_BIN"
            return 0
        fi
    done
    
    # Check if cmake is in PATH (might be homebrew if user has it in PATH)
    if command -v cmake >/dev/null 2>&1; then
        CMAKE_BIN="cmake"
        echo "✅ Found CMake in PATH: $(which cmake)"
        return 0
    fi
    
    # Fallback to other locations
    OTHER_LOCATIONS=(
        "/Applications/CMake.app/Contents/bin/cmake"
        "/usr/bin/cmake"
    )
    
    for location in "${OTHER_LOCATIONS[@]}"; do
        if [ -x "$location" ]; then
            CMAKE_BIN="$location"
            echo "✅ Found CMake at: $CMAKE_BIN"
            return 0
        fi
    done
    
    echo "❌ Error: CMake not found!"
    echo "Please install CMake using Homebrew: brew install cmake"
    echo "If you don't have Homebrew, install it from https://brew.sh/"
    echo "Alternative: Install CMake from https://cmake.org/download/"
    exit 1
}

# Find cmake executable
find_cmake

# --- User-configurable build type and architectures ---
# BUILD_TYPE: Debug, Release, RelWithDebInfo, MinSizeRel
# ARCHS: "arm64", "x86_64", "x86_64;arm64" (universal)
BUILD_TYPE="${BUILD_TYPE:-Debug}"
ARCHS="${ARCHS:-$(uname -m)}"
MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-$(sw_vers -productVersion | awk -F. '{print $1"."$2}')}"
CONFIG_LABEL="$(echo "$BUILD_TYPE" | tr '[:upper:]' '[:lower:]')"
CUSTOMIZATION_FOLDER_PRESENT="${CUSTOMIZATION_FOLDER_PRESENT:-true}"

# --- User-friendly build selection ---
CORE_BUILD="yes"
DATA_BUILD="all"
PLUGINS_BUILD="all"
TSNE_BUILD="yes"

# --- New flags for controlling rerun and post-build ---
RERUN_CMAKE="yes"
RERUN_BUILD="yes"
POST_BUILD="yes"



usage() {
    echo "Usage: $0 [--core yes|no] [--data all|none|plugin1,plugin2,...] [--plugins all|none|plugin1,plugin2,...] [--tsne yes|no] [--rerun-cmake yes|no] [--rerun-build yes|no] [--post-build yes|no]"
    echo "Example: $0 --core yes --data XSCTreeData,CellMorphologyData --plugins MEView,UMAP-Plugin --tsne no --rerun-cmake no --rerun-build no --post-build no"
    exit 1
}

# Run a command and filter noisy output without letting grep's "no matches" status fail the build.
# Returns the wrapped command's exit code.
run_filtered() {
    "$@" 2>&1 | grep -v -i -f "$SCRIPTS_DIR/config/build_output_filter.txt"
    local cmd_status=${PIPESTATUS[0]}
    local grep_status=${PIPESTATUS[1]}

    if [ "$cmd_status" -ne 0 ]; then
        return "$cmd_status"
    fi

    # grep returns 1 when all lines are filtered; treat that as success.
    if [ "$grep_status" -gt 1 ]; then
        return "$grep_status"
    fi

    return 0
}



while [[ $# -gt 0 ]]; do
    case $1 in
        --core)
            CORE_BUILD="$2"; shift 2;;
        --data)
            DATA_BUILD="$2"; shift 2;;
        --plugins)
            PLUGINS_BUILD="$2"; shift 2;;
        --tsne)
            TSNE_BUILD="$2"; shift 2;;
        --rerun-cmake)
            RERUN_CMAKE="$2"; shift 2;;
        --rerun-build)
            RERUN_BUILD="$2"; shift 2;;
        --post-build)
            POST_BUILD="$2"; shift 2;;
        --help|-h)
            usage;;
        *)
            echo "Unknown option: $1"; usage;;
    esac
done

# --- Set up debug and scripts directories ---
DEBUG_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEBUG_ROOT="$(cd "$DEBUG_SCRIPT_DIR/.." && pwd)"
SOURCE_ROOT="${SOURCE_ROOT:-$DEBUG_ROOT/../sources}"
SCRIPTS_DIR="${SCRIPTS_DIR:-$DEBUG_ROOT/../scripts}"
LIBRARIES_ROOT="${LIBRARIES_ROOT:-$(cd "$SCRIPTS_DIR/../libraries" && pwd)}"

# Keep debug outputs isolated per project/profile for cache reuse.
PROJECT_KEY="${DEBUG_PROJECT_KEY:-$(basename "$SOURCE_ROOT")}" 
# Build/install roots depend on BUILD_TYPE (lowercased label)
BUILD_LABEL="$(echo "$BUILD_TYPE" | tr '[:upper:]' '[:lower:]')"
DEBUG_BUILD_DIR="$DEBUG_ROOT/../builds/debug/$PROJECT_KEY/$BUILD_LABEL/build"
DEBUG_INSTALL_DIR="$DEBUG_ROOT/../builds/debug/$PROJECT_KEY/$BUILD_LABEL/install"
QT_DIR="${QT_DIR:-}"

resolve_qt_dir() {
    if [ -n "$QT_DIR" ] && [ -d "$QT_DIR/lib/cmake/Qt6" ]; then
        echo "Using Qt from QT_DIR: $QT_DIR"
        return 0
    fi

    local candidates=(
        "$HOME/Qt/6.10.3/macos"
        "$HOME/Qt/6.8.2/macos"
        "$HOME/Qt/6.8.1/macos"
        "/opt/homebrew/opt/qt"
        "/usr/local/opt/qt"
    )

    for candidate in "${candidates[@]}"; do
        if [ -d "$candidate/lib/cmake/Qt6" ]; then
            QT_DIR="$candidate"
            echo "Using detected Qt: $QT_DIR"
            return 0
        fi
    done

    if command -v qmake >/dev/null 2>&1; then
        local qmake_path
        qmake_path="$(command -v qmake)"
        local qmake_root
        qmake_root="$(cd "$(dirname "$qmake_path")/.." && pwd)"
        if [ -d "$qmake_root/lib/cmake/Qt6" ]; then
            QT_DIR="$qmake_root"
            echo "Using Qt inferred from qmake: $QT_DIR"
            return 0
        fi
    fi

    echo "❌ Error: Qt6 not found."
    echo "Set QT_DIR, for example: QT_DIR=\"$HOME/Qt/6.10.3/macos\""
    exit 1
}

resolve_qt_dir
QT_CMAKE_DIR="$QT_DIR/lib/cmake/Qt6"

# Function to find macOS SDK path
find_macos_sdk() {
    if command -v xcrun >/dev/null 2>&1; then
        MACOS_SDK_PATH="$(xcrun --show-sdk-path)"
        echo "✅ Found macOS SDK at: $MACOS_SDK_PATH"
        return 0
    else
        # Fallback to common Xcode location
        MACOS_SDK_PATH="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
        if [ -d "$MACOS_SDK_PATH" ]; then
            echo "✅ Using fallback macOS SDK at: $MACOS_SDK_PATH"
            return 0
        else
            echo "❌ Error: Cannot find macOS SDK"
            return 1
        fi
    fi
}

# Function to find brew executable
find_brew() {
    # Check Homebrew locations
    BREW_LOCATIONS=(
        "/opt/homebrew/bin/brew"  # Apple Silicon Homebrew
        "/usr/local/bin/brew"     # Intel Homebrew
    )
    
    for location in "${BREW_LOCATIONS[@]}"; do
        if [ -x "$location" ]; then
            BREW_BIN="$location"
            echo "✅ Found Homebrew at: $BREW_BIN"
            return 0
        fi
    done
    
    # Check if brew is in PATH
    if command -v brew >/dev/null 2>&1; then
        BREW_BIN="brew"
        echo "✅ Found brew in PATH: $(which brew)"
        return 0
    fi
    
    echo "❌ Error: Homebrew not found!"
    echo "Please install Homebrew from https://brew.sh/"
    return 1
}

# --- OpenMP Configuration ---
OPENMP_VERSION="21.1.2" 
OPENMP_BUILD_DIR="$LIBRARIES_ROOT/openmp-${OPENMP_VERSION}/build_universal"

# URL for Qt Advanced Docking System release zip (used by packaging/build helpers)
# We prefer downloading the tagged release archive instead of relying on a github clone.
QADS_ZIP_URL="https://github.com/githubuser0xFFFF/Qt-Advanced-Docking-System/archive/refs/tags/5.1.1.zip"

# Check if custom OpenMP is available
if [ -d "$OPENMP_BUILD_DIR" ]; then
    echo "✅ Using custom-built universal OpenMP library for debugging"
    OPENMP_PREFIX="$OPENMP_BUILD_DIR"
    OPENMP_INCLUDE="$OPENMP_BUILD_DIR/include"
    OPENMP_LIB="$OPENMP_BUILD_DIR/lib"
    echo "   📄 OpenMP headers: $OPENMP_INCLUDE"
    echo "   📚 OpenMP library: $OPENMP_LIB/libomp.dylib"
else
    echo "❌ Universal OpenMP library not found for debugging!"
    echo "💡 Run '../scripts/build_openmp_universal_updated.sh' to build the required universal OpenMP library"
    echo "🚫 Only the custom-built universal OpenMP library is supported for debugging"
    exit 1
fi

# --- CUPS Configuration ---
CUPS_VERSION="2.4.14"
CUPS_BUILD_DIR="$LIBRARIES_ROOT/cups-${CUPS_VERSION}/build_universal"

# Check if custom CUPS is available
if [ -d "$CUPS_BUILD_DIR" ]; then
    echo "✅ Using custom-built universal CUPS library for debugging"
else
    echo "❌ Universal CUPS library not found for debugging!"
    echo "💡 Run '../scripts/build_cups_universal.sh' first to build the required universal CUPS library"
    echo "🚫 Only the custom-built universal CUPS library is supported for debugging"
    exit 1
fi

NUM_CORES=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)
BUILD_JOBS=$((NUM_CORES + 2))

# Optional repo-level parallelism (data/plugins). Keep default sequential for compatibility.
REPO_PARALLEL_JOBS="${REPO_PARALLEL_JOBS:-1}"
if ! [[ "$REPO_PARALLEL_JOBS" =~ ^[0-9]+$ ]] || [ "$REPO_PARALLEL_JOBS" -lt 1 ]; then
    echo "Warning: invalid REPO_PARALLEL_JOBS='$REPO_PARALLEL_JOBS', falling back to 1"
    REPO_PARALLEL_JOBS=1
fi
BUILD_JOBS_PER_REPO=$((BUILD_JOBS / REPO_PARALLEL_JOBS))
if [ "$BUILD_JOBS_PER_REPO" -lt 1 ]; then
    BUILD_JOBS_PER_REPO=1
fi

# Check for macOS SDK
find_macos_sdk

# ----------- AGL FIX FUNCTION -----------
fix_agl_issue() {
    local build_dir="$1"
    echo "🔧 Checking for AGL linker issues in $build_dir..."
    # Look for link.txt files that might contain AGL references
    local link_files=$(find "$build_dir" -name "link.txt" -type f 2>/dev/null || true)
    for link_file in $link_files; do
        if grep -q "AGL" "$link_file" || grep -q "-framework AGL" "$link_file"; then
            echo "✅ Fixing AGL reference in: $(basename $(dirname $(dirname $link_file)))"
            sed -i '' 's/-framework AGL//g' "$link_file"
            sed -i '' 's/AGL//g' "$link_file"
            sed -i '' 's/  / /g' "$link_file"
            sed -i '' 's/ -framework$/ /g' "$link_file"
            sed -i '' 's/^-framework / /g' "$link_file"
        fi
    done
    # Also check for AGL in build.ninja files
    local ninja_files=$(find "$build_dir" -name "build.ninja" -type f 2>/dev/null || true)
    for ninja_file in $ninja_files; do
        if grep -q "AGL" "$ninja_file"; then
            echo "✅ Fixing AGL reference in build.ninja"
            sed -i '' 's/-framework AGL//g' "$ninja_file"
            sed -i '' 's/AGL//g' "$ninja_file"
            sed -i '' 's/  / /g' "$ninja_file"
            sed -i '' 's/ -framework$/ /g' "$ninja_file"
        fi
    done
}

ensure_automoc_dirs() {
    local build_dir="$1"
    echo "Ensuring AutoMoc output directories are writable..."
    
    # Find all AutoMoc directories and ensure they exist and are writable
    find "$build_dir" -type d -name "*_autogen" 2>/dev/null | while read -r autogen_dir; do
        chmod -R u+w "$autogen_dir" 2>/dev/null || true
    done
    
    # Pre-create expected AutoMoc subdirectories for Core
    local core_autogen="$build_dir/ManiVault/Core_autogen"
    if [ -d "$core_autogen" ]; then
        mkdir -p "$core_autogen/SYS76T6PVS" 2>/dev/null || true
        chmod -R u+w "$core_autogen" 2>/dev/null || true
    fi
}

# --- Compute build-config-aware install locations ---
# Some projects install into a subfolder named after the CMake configuration (e.g., Debug/Release/RelWithDebInfo),
# while others install directly into the prefix. We compute both and prefer the config subfolder if it exists.
CONFIG_DIR="$BUILD_TYPE"
INSTALL_CONFIG_DIR="$DEBUG_INSTALL_DIR/$CONFIG_DIR"
if [ -d "$INSTALL_CONFIG_DIR" ]; then
    INSTALL_BASE="$INSTALL_CONFIG_DIR"
else
    INSTALL_BASE="$DEBUG_INSTALL_DIR"
fi
# Plugins directory used for linking/packaging
PLUGINS_DIR="$INSTALL_BASE/Plugins"
# Ensure chosen install base and plugins directory exist
mkdir -p "$INSTALL_BASE" "$PLUGINS_DIR"

# --- Common RPATH settings (added) ---
# We want all built targets (core, data plugins, analysis plugins) to resolve internal
# libraries (lz4, flann, MV_Public, etc.) from inside the app bundle Frameworks directory.
# Use both @executable_path (main app) and @loader_path (for plugins loaded indirectly).
COMMON_RPATHS="@executable_path/../Frameworks;@loader_path/../Frameworks"
COMMON_RPATH_CMAKE_ARGS="-DCMAKE_MACOSX_RPATH=ON -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON -DCMAKE_INSTALL_RPATH=$COMMON_RPATHS -DCMAKE_INSTALL_NAME_DIR=@rpath"

# Helper: safely patch a dependency path inside a binary if it exists.
safe_patch_dependency() { # binary old_path new_path
    local bin="$1"; local old="$2"; local new="$3"
    [[ ! -f "$bin" ]] && return 0
    if otool -L "$bin" 2>/dev/null | grep -q "$old"; then
        chmod +w "$bin" 2>/dev/null || true
        # only change if the binary references the old path
        if otool -L "$bin" | grep -q "$old"; then
            install_name_tool -change "$old" "$new" "$bin" 2>/dev/null || echo "Warning: failed to patch $old -> $new in $bin"
        else
            echo "Skipping change: $bin does not reference $old"
        fi
    fi
}

# --- Optional: Use ccache if available ---
if command -v ccache >/dev/null 2>&1; then
    export CC="ccache gcc"
    export CXX="ccache g++"
    echo "Using ccache for faster rebuilds."
fi

export PKG_CONFIG_PATH="$LIBRARIES_ROOT/lz4-1.9.4/build_universal/lib/pkgconfig:$LIBRARIES_ROOT/flann/build_universal/lib/pkgconfig:$LIBRARIES_ROOT/qads/build_universal/lib/pkgconfig:$LIBRARIES_ROOT/hdf5-1.14.6/install_universal_static/lib/pkgconfig:$LIBRARIES_ROOT/zlib-1.3.1/build_universal/lib/pkgconfig:$LIBRARIES_ROOT/cups-2.4.14/build_universal/lib/pkgconfig:$PKG_CONFIG_PATH"
export CMAKE_PREFIX_PATH="$QT_CMAKE_DIR:$LIBRARIES_ROOT/lz4-1.9.4/build_universal/lib/cmake/lz4:$LIBRARIES_ROOT/qads/build_universal/lib/cmake/qads:$LIBRARIES_ROOT/hdf5-1.14.6/install_universal_static/share/cmake/hdf5:$LIBRARIES_ROOT/zlib-1.3.1/build_universal/share/cmake/zlib:$LIBRARIES_ROOT/cups-2.4.14/build_universal:$CMAKE_PREFIX_PATH"

mkdir -p "$DEBUG_BUILD_DIR" "$DEBUG_INSTALL_DIR"




 # --- Build core ---
if [[ "$CORE_BUILD" == "yes" ]]; then
    echo "Configuring and building core in $BUILD_TYPE mode for architectures: $ARCHS..."
    CORE_SOURCE="$SOURCE_ROOT/core"
    CORE_BUILD_DIR="$DEBUG_BUILD_DIR/core"
    CORE_CACHE_FILE="$CORE_BUILD_DIR/CMakeCache.txt"
    HDILIB_ROOT="$LIBRARIES_ROOT/HDILib/install_universal/lib/cmake/HDILib"
    FLANN_DIR="$LIBRARIES_ROOT/flann/build_universal"
    if [[ "$RERUN_CMAKE" != "yes" && ! -f "$CORE_CACHE_FILE" ]]; then
        echo "Core cache missing at $CORE_CACHE_FILE; forcing CMake reconfigure."
        RERUN_CMAKE="yes"
    fi
    if [[ "$RERUN_CMAKE" == "yes" ]]; then
        # Clear environment variables that might interfere with OpenMP detection
        unset OMP_NUM_THREADS 2>/dev/null || true

        # Recover from interrupted Font Awesome downloads/extractions.
        # A partial cache directory can make CMake skip re-extract but still miss required files.
        FONT_AWESOME_CACHE_DIR="$CORE_BUILD_DIR/Font-Awesome-Resources"
        FONT_AWESOME_SENTINEL="$FONT_AWESOME_CACHE_DIR/Font-Awesome-5.14.0/metadata/icons.json"
        if [ -d "$FONT_AWESOME_CACHE_DIR" ] && [ ! -f "$FONT_AWESOME_SENTINEL" ]; then
            echo "Removing stale Font Awesome cache: $FONT_AWESOME_CACHE_DIR"
            rm -rf "$FONT_AWESOME_CACHE_DIR"
        fi
        
        $CMAKE_BIN -S "$CORE_SOURCE" -B "$CORE_BUILD_DIR" \
            -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
            -DMV_INSTALL_DIR="$DEBUG_INSTALL_DIR" \
            -DCMAKE_OSX_ARCHITECTURES="$ARCHS" \
            -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
            -DCMAKE_INSTALL_PREFIX="$DEBUG_INSTALL_DIR" \
            $COMMON_RPATH_CMAKE_ARGS \
            -DCMAKE_PCH_INSTANTIATE_TEMPLATES=OFF \
            -DCMAKE_DISABLE_PRECOMPILE_HEADERS=ON \
            -DSKIP_PCH_FOR_OBJCXX=ON \
            -DHDILIB_ROOT="$HDILIB_ROOT" \
            -Dflann_DIR="$FLANN_DIR/lib/cmake/flann" \
            -DQt6_DIR="$QT_CMAKE_DIR" \
            -DCMAKE_PREFIX_PATH="$OPENMP_BUILD_DIR;$QT_CMAKE_DIR" \
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
            -DCUPS_INCLUDE_DIR="$CUPS_BUILD_DIR/include" \
            -DCUPS_LIBRARIES="$CUPS_BUILD_DIR/lib/libcups.2.dylib" \
            -DOpenGL_GL_PREFERENCE=LEGACY \
            -DOPENGL_INCLUDE_DIR="$MACOS_SDK_PATH/System/Library/Frameworks/OpenGL.framework/Headers" \
            -DOPENGL_gl_LIBRARY="$MACOS_SDK_PATH/System/Library/Frameworks/OpenGL.framework" \
            -G "Ninja"
        fix_agl_issue "$CORE_BUILD_DIR"
    fi
    if [[ "$RERUN_BUILD" == "yes" ]]; then
        # Build MacThemeHelper early (mirrors build_core.sh) to surface any ObjC++/OpenGL issues sooner
        if [ -f "$CORE_BUILD_DIR/ManiVault/CMakeFiles/Core.dir/src/util/MacThemeHelper.mm.o" ]; then
            echo "MacThemeHelper.mm.o already built (cached)"
        else
            echo "Building MacThemeHelper.mm.o early to avoid sporadic build issues..."
            $CMAKE_BIN --build "$CORE_BUILD_DIR" --config "$BUILD_TYPE" --target ManiVault/CMakeFiles/Core.dir/src/util/MacThemeHelper.mm.o -j 1 || true
            fix_agl_issue "$CORE_BUILD_DIR"
        fi
        ensure_automoc_dirs "$CORE_BUILD_DIR"
        # Use -j 1 for core to avoid AutoMoc directory creation race conditions in parallel builds
        run_filtered $CMAKE_BIN --build "$CORE_BUILD_DIR" --config "$BUILD_TYPE" -j 1
        run_filtered $CMAKE_BIN --build "$CORE_BUILD_DIR" --target install --config "$BUILD_TYPE"
    fi
fi

# --- Ensure core internal data libraries (PointData, ClusterData, ColorData, ImageData, TextData) are installed ---
# These are produced by the core project itself and should NOT be treated as standalone plugin repositories.
# In earlier iterations ColorData was appended to the external PLUGINS list which caused failures because
# there is no separate directory at $SOURCE_ROOT/ColorData. We instead verify/copy them here after core install.
echo "Ensuring core internal data libraries are present..."
INTERNAL_CORE_PLUGIN_NAMES=(libPointData libClusterData libColorData libImageData libTextData)
# Determine actual install base now (core install may have created the config-specific folder)
CORE_INSTALL_CONFIG_DIR="$DEBUG_INSTALL_DIR/$BUILD_TYPE"
if [ -d "$CORE_INSTALL_CONFIG_DIR/Plugins" ]; then
    CORE_INTERNAL_PLUGINS_DIR="$CORE_INSTALL_CONFIG_DIR/Plugins"
else
    CORE_INTERNAL_PLUGINS_DIR="$DEBUG_INSTALL_DIR/Plugins"
fi
mkdir -p "$CORE_INTERNAL_PLUGINS_DIR"
for base in "${INTERNAL_CORE_PLUGIN_NAMES[@]}"; do
    target_lib="$CORE_INTERNAL_PLUGINS_DIR/${base}.dylib"
    if [ ! -f "$target_lib" ]; then
        # Try to find built artifact inside the core build tree
        found_lib=$(find "$DEBUG_BUILD_DIR/core" -maxdepth 6 -name "${base}*.dylib" 2>/dev/null | head -n 1 || true)
        if [ -n "$found_lib" ]; then
            echo "Copying missing internal core library: $(basename "$found_lib")"
            cp "$found_lib" "$target_lib" || echo "Warning: failed to copy $found_lib"
        else
            echo "Warning: internal core library ${base}.dylib not found (may indicate core build incomplete)"
        fi
    fi
done
echo "Internal core data libraries check complete."




wait_and_report_pid() {
    local pid="$1"
    local name="$2"
    if wait "$pid"; then
        return 0
    fi
    echo "✗ Build failed for $name"
    return 1
}

run_repo_queue() {
    local builder_fn="$1"
    shift
    local repos=("$@")
    local active_pids=()
    local active_names=()
    local failed=0
    local repo

    for repo in "${repos[@]}"; do
        if [ -z "$repo" ]; then
            continue
        fi

        if [ "$REPO_PARALLEL_JOBS" -le 1 ]; then
            "$builder_fn" "$repo" || failed=1
            continue
        fi

        "$builder_fn" "$repo" &
        active_pids+=("$!")
        active_names+=("$repo")

        while [ "${#active_pids[@]}" -ge "$REPO_PARALLEL_JOBS" ]; do
            wait_and_report_pid "${active_pids[0]}" "${active_names[0]}" || failed=1
            active_pids=("${active_pids[@]:1}")
            active_names=("${active_names[@]:1}")
        done
    done

    while [ "${#active_pids[@]}" -gt 0 ]; do
        wait_and_report_pid "${active_pids[0]}" "${active_names[0]}" || failed=1
        active_pids=("${active_pids[@]:1}")
        active_names=("${active_names[@]:1}")
    done

    if [ "$failed" -ne 0 ]; then
        return 1
    fi
    return 0
}

build_data_repo() {
    local repo="$1"
    echo "Configuring and building $repo in $BUILD_TYPE mode for architectures: $ARCHS..."
    if [[ "$RERUN_CMAKE" == "yes" ]]; then
        # Clear environment variables that might interfere with OpenMP detection
        unset OMP_NUM_THREADS 2>/dev/null || true

        $CMAKE_BIN -S "$SOURCE_ROOT/$repo" -B "$DEBUG_BUILD_DIR/$repo" \
            -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
            -DManiVault_DIR="$DEBUG_INSTALL_DIR/cmake/mv" \
            -DCMAKE_INSTALL_PREFIX="$DEBUG_INSTALL_DIR" \
            $COMMON_RPATH_CMAKE_ARGS \
            -DQt6_DIR="$QT_CMAKE_DIR" \
            -DCMAKE_PREFIX_PATH="$OPENMP_BUILD_DIR" \
            -DCMAKE_LIBRARY_PATH="$OPENMP_LIB" \
            -DCMAKE_INCLUDE_PATH="$OPENMP_INCLUDE" \
            -DCMAKE_C_FLAGS="-Xpreprocessor -fopenmp -I$OPENMP_INCLUDE" \
            -DCMAKE_CXX_FLAGS="-DGL_SILENCE_DEPRECATION -Xpreprocessor -fopenmp -I$OPENMP_INCLUDE" \
            -DCMAKE_EXE_LINKER_FLAGS="-L$OPENMP_LIB -lomp" \
            -DCMAKE_SHARED_LINKER_FLAGS="-L$OPENMP_LIB -lomp" \
            -DCMAKE_MODULE_LINKER_FLAGS="-L$OPENMP_LIB -lomp" \
            -DCMAKE_OSX_ARCHITECTURES="$ARCHS" \
            -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
            -DCMAKE_DISABLE_PRECOMPILE_HEADERS=OFF \
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
            -DCUPS_INCLUDE_DIR="$CUPS_BUILD_DIR/include" \
            -DCUPS_LIBRARIES="$CUPS_BUILD_DIR/lib/libcups.2.dylib" \
            -DOpenGL_GL_PREFERENCE=LEGACY \
            -DOPENGL_INCLUDE_DIR="$MACOS_SDK_PATH/System/Library/Frameworks/OpenGL.framework/Headers" \
            -DOPENGL_gl_LIBRARY="$MACOS_SDK_PATH/System/Library/Frameworks/OpenGL.framework" \
            -G Ninja
        fix_agl_issue "$DEBUG_BUILD_DIR/$repo"
    fi
    if [[ "$RERUN_BUILD" == "yes" ]]; then
        run_filtered $CMAKE_BIN --build "$DEBUG_BUILD_DIR/$repo" --config "$BUILD_TYPE" -j "$BUILD_JOBS_PER_REPO"
        run_filtered $CMAKE_BIN --build "$DEBUG_BUILD_DIR/$repo" --target install --config "$BUILD_TYPE"
        echo "✓ $repo $BUILD_TYPE build completed"
    fi
}

# --- Build data plugins ---
DATA_PLUGINS="XSCTreeData XSCTreeMetaData EphysData CellMorphologyData"
if [ "$DATA_BUILD" != "none" ]; then
    if [ "$DATA_BUILD" = "all" ]; then
        DATA_TO_BUILD="$DATA_PLUGINS"
    else
        DATA_TO_BUILD=$(echo "$DATA_BUILD" | tr ',' ' ')
    fi

    if [ "$REPO_PARALLEL_JOBS" -gt 1 ]; then
        echo "Using REPO_PARALLEL_JOBS=$REPO_PARALLEL_JOBS for data/plugin repositories (BUILD_JOBS_PER_REPO=$BUILD_JOBS_PER_REPO)"
    fi

    # shellcheck disable=SC2206
    DATA_REPO_ARRAY=($DATA_TO_BUILD)
    run_repo_queue build_data_repo "${DATA_REPO_ARRAY[@]}" || exit 1
fi




# --- Build plugins with special handling ---
# After data plugins install, the config-specific install dir likely exists; recompute paths
    INSTALL_CONFIG_DIR="$DEBUG_INSTALL_DIR/$CONFIG_DIR"
    if [ -d "$INSTALL_CONFIG_DIR" ]; then
        INSTALL_BASE="$INSTALL_CONFIG_DIR"
    else
    INSTALL_BASE="$DEBUG_INSTALL_DIR"
fi
PLUGINS_DIR="$INSTALL_BASE/Plugins"
# Ensure chosen install base and plugins directory exist
mkdir -p "$INSTALL_BASE" "$PLUGINS_DIR"

# NOTE: Core build produces several built-in data/link libraries (PointData, ClusterData, ColorData, ImageData, TextData)
# ColorData is required (referenced by ManiVaultTargets.cmake) but was missing here, causing
# a configure failure for dependent data/plugin projects due to missing libColorData.dylib.
# Add ColorData explicitly so an --plugins all build ensures the .dylib exists in Plugins.
PLUGINS="SparseH5DataAccessPlugin MEView SubsetFromSelectionPlugin UMAP-Plugin SunburstClusterPlugin DifferentialExpressionPlugin DimensionPlot GeneSurfer GradientSurferPlugin GradientSurferTransformationPlugin LinePlotViewPlugin PcaPlugin ProjectAveragesPlugin RefinePlugin Scatterplot ProjectionExplorer ATACControllerPlugin ChartLegendViewPlugin ClusterDifferentialExpressionPlugin SimianViewerPairExpCompPlugin SimianViewerMultExpCompPlugin SimianViewerPlugin XSCPhyTVuPlugin XSCLoaderPlugin XSCClusterRankPlugin XSCGeneDetectPlugin"

PLUGIN_PATH="$PLUGINS_DIR"

build_plugin() {
    local repo="$1"
    echo "Configuring and building $repo in $BUILD_TYPE mode for architectures: $ARCHS..."
    local SOURCE_DIR="$SOURCE_ROOT/$repo"
    local BUILD_DIR="$DEBUG_BUILD_DIR/$repo"
    local meview_patched="no"
    local hdf5loader_patched="no"
    mkdir -p "$BUILD_DIR"

    if [ ! -d "$SOURCE_DIR" ]; then
        echo "✗ Source directory not found for plugin: $SOURCE_DIR"
        return 1
    fi
    
    # Clear environment variables that might interfere with OpenMP detection
    unset OMP_NUM_THREADS 2>/dev/null || true
    
    local cmake_args=(
        -S "$SOURCE_DIR"
        -B "$BUILD_DIR"
        -DCMAKE_BUILD_TYPE="$BUILD_TYPE"
        -DManiVault_DIR="$DEBUG_INSTALL_DIR/cmake/mv"
        -DCMAKE_INSTALL_PREFIX="$DEBUG_INSTALL_DIR"
        -DCMAKE_MACOSX_RPATH=ON
        -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON
        -DCMAKE_INSTALL_RPATH="$COMMON_RPATHS"
        -DCMAKE_INSTALL_NAME_DIR=@rpath
        -DQt6_DIR="$QT_CMAKE_DIR"
        -DCMAKE_PREFIX_PATH="$OPENMP_BUILD_DIR;$QT_CMAKE_DIR;$LIBRARIES_ROOT/lz4-1.9.4/build_universal/lib/cmake/lz4;$LIBRARIES_ROOT/qads/build_universal/lib/cmake/qads;$LIBRARIES_ROOT/hdf5-1.14.6/install_universal_static/share/cmake/hdf5;$LIBRARIES_ROOT/zlib-1.3.1/build_universal/share/cmake/zlib"
        -DCMAKE_LIBRARY_PATH="$OPENMP_LIB"
        -DCMAKE_INCLUDE_PATH="$OPENMP_INCLUDE"
        -DCMAKE_C_FLAGS="-Xpreprocessor -fopenmp -I$OPENMP_INCLUDE"
        -DCMAKE_CXX_FLAGS="-DGL_SILENCE_DEPRECATION -Xpreprocessor -fopenmp -I$OPENMP_INCLUDE"
        -DCMAKE_EXE_LINKER_FLAGS="-L$OPENMP_LIB -lomp"
        -DCMAKE_SHARED_LINKER_FLAGS="-L$OPENMP_LIB -lomp"
        -DCMAKE_MODULE_LINKER_FLAGS="-L$OPENMP_LIB -lomp"
        -DCMAKE_OSX_ARCHITECTURES="$ARCHS"
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET"
        -DCMAKE_DISABLE_PRECOMPILE_HEADERS=ON
        -DCMAKE_IGNORE_PATH="/opt/homebrew/opt/libomp;/usr/local/opt/libomp;/opt/homebrew;/usr/local"
        -DCMAKE_FIND_USE_CMAKE_SYSTEM_PATH=OFF
        -DOpenMP_ROOT="$OPENMP_BUILD_DIR"
        -DOpenMP_C_FLAGS="-Xpreprocessor -fopenmp -I$OPENMP_INCLUDE"
        -DOpenMP_CXX_FLAGS="-Xpreprocessor -fopenmp -I$OPENMP_INCLUDE"
        -DOpenMP_C_LIB_NAMES="omp"
        -DOpenMP_CXX_LIB_NAMES="omp"
        -DOpenMP_omp_LIBRARY="$OPENMP_LIB/libomp.dylib"
        -DOpenMP_C_LIBRARY="$OPENMP_LIB/libomp.dylib"
        -DOpenMP_CXX_LIBRARY="$OPENMP_LIB/libomp.dylib"
        -DOpenMP_C_INCLUDE_DIR="$OPENMP_INCLUDE"
        -DOpenMP_CXX_INCLUDE_DIR="$OPENMP_INCLUDE"
        -DCUPS_INCLUDE_DIR="$CUPS_BUILD_DIR/include"
        -DCUPS_LIBRARIES="$CUPS_BUILD_DIR/lib/libcups.2.dylib"
        -DOpenGL_GL_PREFERENCE=LEGACY
        -DOPENGL_INCLUDE_DIR="$MACOS_SDK_PATH/System/Library/Frameworks/OpenGL.framework/Headers"
        -DOPENGL_gl_LIBRARY="$MACOS_SDK_PATH/System/Library/Frameworks/OpenGL.framework"
        -G Ninja
    )
    if [ "$repo" = "XSCPhyTVuPlugin" ] || [ "$repo" = "XSCLoaderPlugin" ]; then
        cmake_args+=(
            -DXSCTREEDATA_LINK_LIBRARY="$PLUGIN_PATH/libXSCTreeData.dylib"
            -DXSCTREEMETADATA_LINK_LIBRARY="$PLUGIN_PATH/libXSCTreeMetaData.dylib"
        )
    fi
    if [ "$repo" = "XSCClusterRankPlugin" ] || [ "$repo" = "XSCGeneDetectPlugin" ]; then
        cmake_args+=(-DXSCTREEDATA_LINK_LIBRARY="$PLUGIN_PATH/libXSCTreeData.dylib")
    fi
    if [ "$repo" = "MEView" ]; then
        echo "Patching MEView CMakeLists.txt temporarily..."
        cp "$SOURCE_DIR/CMakeLists.txt" "$SOURCE_DIR/CMakeLists.txt.backup"
        sed -i '' 's/^set(CELL_MORPHOLOGY_DATA_LINK_LIBRARY/# set(CELL_MORPHOLOGY_DATA_LINK_LIBRARY/' "$SOURCE_DIR/CMakeLists.txt"
        sed -i '' 's/^set(EPHYS_DATA_LINK_LIBRARY/# set(EPHYS_DATA_LINK_LIBRARY/' "$SOURCE_DIR/CMakeLists.txt"
        meview_patched="yes"
        cmake_args+=(
            -DCELL_MORPHOLOGY_DATA_LINK_LIBRARY="$PLUGIN_PATH/libCellMorphologyData.dylib"
            -DEPHYS_DATA_LINK_LIBRARY="$PLUGIN_PATH/libEphysData.dylib"
        )
    fi
    if [ "$repo" = "HDF5Loader" ]; then
        echo "Patching HDF5Loader CMakeLists.txt temporarily..."
        cp "$SOURCE_DIR/CMakeLists.txt" "$SOURCE_DIR/CMakeLists.txt.backup"
        sed -i '' 's/^option(USE_HDF5_ARTIFACTORY_LIBS/# option(USE_HDF5_ARTIFACTORY_LIBS/' "$SOURCE_DIR/CMakeLists.txt"
        echo "set(USE_HDF5_ARTIFACTORY_LIBS OFF CACHE BOOL \"Use the prebuilt libraries from artifactory\" FORCE)" >> "$SOURCE_DIR/CMakeLists.txt"
        echo "set(USE_EXTERNAL_HDF5 OFF CACHE BOOL \"Use external HDF5 project\" FORCE)" >> "$SOURCE_DIR/CMakeLists.txt"
        hdf5loader_patched="yes"
        # Add static HDF5/ZLIB libraries to linker flags
        ZLIB_STATIC_LIB=\"$LIBRARIES_ROOT/zlib-1.3.1/build_universal/lib/libz.a\"
        HDF5_CPP_STATIC_LIB=\"$LIBRARIES_ROOT/hdf5-1.14.6/install_universal_static/lib/libhdf5_cpp.a\"
        HDF5_STATIC_LIB=\"$LIBRARIES_ROOT/hdf5-1.14.6/install_universal_static/lib/libhdf5.a\"
        HDF5_HL_CPP_STATIC_LIB=\"$LIBRARIES_ROOT/hdf5-1.14.6/install_universal_static/lib/libhdf5_hl_cpp.a\"
        HDF5_HL_STATIC_LIB=\"$LIBRARIES_ROOT/hdf5-1.14.6/install_universal_static/lib/libhdf5_hl.a\"
        HDF5_CMAKE_DIR=\"$LIBRARIES_ROOT/hdf5-1.14.6/install_universal_static/share/cmake/hdf5\"
        HDF5_LIB_DIR=\"$LIBRARIES_ROOT/hdf5-1.14.6/install_universal_static/lib\"
        HDF5_INCLUDE_DIR=\"$LIBRARIES_ROOT/hdf5-1.14.6/install_universal_static/include\"
        ZLIB_DIR=\"$LIBRARIES_ROOT/zlib-1.3.1/build_universal/share/cmake/zlib\"
        ZLIB_INCLUDE_DIR=\"$LIBRARIES_ROOT/zlib-1.3.1/build_universal/include\"
        cmake_args+=(
            -DCMAKE_PREFIX_PATH="$LIBRARIES_ROOT/lz4-1.9.4/build_universal/lib/cmake/lz4;$HDF5_CMAKE_DIR;$HDF5_LIB_DIR;$ZLIB_DIR"
            -DHDF5_ROOT="$LIBRARIES_ROOT/hdf5-1.14.6/install_universal_static"
            -DHDF5_DIR="$HDF5_CMAKE_DIR"
            -DHDF5_INCLUDE_DIR="$HDF5_INCLUDE_DIR"
            -DZLIB_ROOT="$LIBRARIES_ROOT/zlib-1.3.1/build_universal"
            -DZLIB_INCLUDE_DIR="$ZLIB_INCLUDE_DIR"
            -DHDF5_USE_STATIC_LIBRARIES=ON
            -DCMAKE_EXE_LINKER_FLAGS="-L$OPENMP_LIB -lomp $ZLIB_STATIC_LIB $HDF5_CPP_STATIC_LIB $HDF5_STATIC_LIB $HDF5_HL_CPP_STATIC_LIB $HDF5_HL_STATIC_LIB"
            -DCMAKE_SHARED_LINKER_FLAGS="-L$OPENMP_LIB -lomp $ZLIB_STATIC_LIB $HDF5_CPP_STATIC_LIB $HDF5_STATIC_LIB $HDF5_HL_CPP_STATIC_LIB $HDF5_HL_STATIC_LIB"
            -DCMAKE_MODULE_LINKER_FLAGS="-L$OPENMP_LIB -lomp $ZLIB_STATIC_LIB $HDF5_CPP_STATIC_LIB $HDF5_STATIC_LIB $HDF5_HL_CPP_STATIC_LIB $HDF5_HL_STATIC_LIB"
        )
    fi

    if ! "$CMAKE_BIN" "${cmake_args[@]}"; then
        if [ "$hdf5loader_patched" = "yes" ] && [ -f "$SOURCE_DIR/CMakeLists.txt.backup" ]; then
            mv "$SOURCE_DIR/CMakeLists.txt.backup" "$SOURCE_DIR/CMakeLists.txt"
        fi
        if [ "$meview_patched" = "yes" ] && [ -f "$SOURCE_DIR/CMakeLists.txt.backup" ]; then
            mv "$SOURCE_DIR/CMakeLists.txt.backup" "$SOURCE_DIR/CMakeLists.txt"
        fi
        echo "✗ CMake configure failed for $repo"
        return 1
    fi
    fix_agl_issue "$BUILD_DIR"

    if [ "$hdf5loader_patched" = "yes" ]; then
        mv "$SOURCE_DIR/CMakeLists.txt.backup" "$SOURCE_DIR/CMakeLists.txt"
    fi
    if [ "$meview_patched" = "yes" ]; then
        mv "$SOURCE_DIR/CMakeLists.txt.backup" "$SOURCE_DIR/CMakeLists.txt"
    fi

    if [[ "$RERUN_BUILD" == "yes" ]]; then
        if ! run_filtered $CMAKE_BIN --build "$BUILD_DIR" --config "$BUILD_TYPE" -j "$BUILD_JOBS_PER_REPO"; then
            echo "✗ Build failed for $repo"
            return 1
        fi
        if ! run_filtered $CMAKE_BIN --build "$BUILD_DIR" --target install --config "$BUILD_TYPE"; then
            echo "✗ Install failed for $repo"
            return 1
        fi
    fi

    echo "✓ $repo $BUILD_TYPE build completed"
    echo ""
}


if [ "$PLUGINS_BUILD" != "none" ]; then
    if [ "$PLUGINS_BUILD" = "all" ]; then
        PLUGINS_TO_BUILD="$PLUGINS"
    else
        PLUGINS_TO_BUILD=$(echo "$PLUGINS_BUILD" | tr ',' ' ')
    fi

    if [[ "$RERUN_CMAKE" == "yes" || "$RERUN_BUILD" == "yes" ]]; then
        # shellcheck disable=SC2206
        PLUGIN_REPO_ARRAY=($PLUGINS_TO_BUILD)
        run_repo_queue build_plugin "${PLUGIN_REPO_ARRAY[@]}" || exit 1
    fi
fi





 # --- Build t-SNE-Analysis ---
if [[ "$TSNE_BUILD" == "yes" ]]; then
    echo "Configuring and building t-SNE-Analysis in $BUILD_TYPE mode for architectures: $ARCHS..."
    TSNE_SOURCE="$SOURCE_ROOT/t-SNE-Analysis"
    TSNE_BUILD_DIR="$DEBUG_BUILD_DIR/t-SNE-Analysis"
    mkdir -p "$TSNE_BUILD_DIR"
    HDILIB_ROOT="$LIBRARIES_ROOT/HDILib/install_universal/lib/cmake/HDILib"
    MANIVAULT_DIR="$DEBUG_INSTALL_DIR/cmake/mv"
    FLANN_DIR="$LIBRARIES_ROOT/flann/build_universal"
    FLANN_CMAKE_DIR="$FLANN_DIR/lib/cmake/flann"
    CMAKE_PREFIX_PATH_TSNE="$FLANN_DIR;$QT_DIR;$LIBRARIES_ROOT/lz4-1.9.4/build_universal/lib/cmake/lz4;$LIBRARIES_ROOT/qads/build_universal/lib/cmake/qads;$LIBRARIES_ROOT/hdf5-1.14.6/install_universal_static/share/cmake/hdf5;$LIBRARIES_ROOT/zlib-1.3.1/build_universal/share/cmake/zlib;$LIBRARIES_ROOT/cups-2.4.14/build_universal"

    if [[ "$RERUN_CMAKE" == "yes" ]]; then
        $CMAKE_BIN -S "$TSNE_SOURCE" -B "$TSNE_BUILD_DIR" \
            -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
            -DMV_SNE_USE_ARTIFACTORY_LIBS=OFF \
            -DHDILIB_ROOT="$HDILIB_ROOT" \
            -DManiVault_DIR="$MANIVAULT_DIR" \
            -DCMAKE_INSTALL_PREFIX="$DEBUG_INSTALL_DIR" \
            $COMMON_RPATH_CMAKE_ARGS \
            -DLZ4_INCLUDE_DIR="$LIBRARIES_ROOT/lz4-1.9.4/build_universal/include" \
            -DLZ4_LIBRARY="$LIBRARIES_ROOT/lz4-1.9.4/build_universal/lib/liblz4.1.dylib" \
            -DQt6_DIR="$QT_CMAKE_DIR" \
            -Dflann_DIR="$FLANN_CMAKE_DIR" \
            -DCMAKE_PREFIX_PATH="$CMAKE_PREFIX_PATH_TSNE" \
            -DCMAKE_C_FLAGS="-Xpreprocessor -fopenmp -I$OPENMP_INCLUDE" \
            -DCMAKE_CXX_FLAGS="-DGL_SILENCE_DEPRECATION -I$FLANN_DIR/include -Xpreprocessor -fopenmp -I$OPENMP_INCLUDE" \
            -DCMAKE_EXE_LINKER_FLAGS="-L$OPENMP_LIB -lomp -L${FLANN_DIR}/lib" \
            -DCMAKE_SHARED_LINKER_FLAGS="-L$OPENMP_LIB -lomp -L${FLANN_DIR}/lib" \
            -DCMAKE_MODULE_LINKER_FLAGS="-L$OPENMP_LIB -lomp -L${FLANN_DIR}/lib" \
            -DCMAKE_OSX_ARCHITECTURES="$ARCHS" \
                -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
            -DOpenGL_GL_PREFERENCE=LEGACY \
            -DOPENGL_INCLUDE_DIR="$MACOS_SDK_PATH/System/Library/Frameworks/OpenGL.framework/Headers" \
            -DOPENGL_gl_LIBRARY="$MACOS_SDK_PATH/System/Library/Frameworks/OpenGL.framework" \
            -DCUPS_INCLUDE_DIR="$CUPS_BUILD_DIR/include" \
            -DCUPS_LIBRARIES="$CUPS_BUILD_DIR/lib/libcups.2.dylib" \
            -G Ninja
        fix_agl_issue "$TSNE_BUILD_DIR"
    fi
    if [[ "$RERUN_BUILD" == "yes" ]]; then
        run_filtered $CMAKE_BIN --build "$TSNE_BUILD_DIR" --config "$BUILD_TYPE" -j "$BUILD_JOBS"
        run_filtered $CMAKE_BIN --build "$TSNE_BUILD_DIR" --target install --config "$BUILD_TYPE"
        echo "✓ t-SNE-Analysis $BUILD_TYPE build completed"
    fi
fi


# Re-evaluate install base now that builds/installs may have created config subfolder
INSTALL_CONFIG_DIR="$DEBUG_INSTALL_DIR/$CONFIG_DIR"
if [ -d "$INSTALL_CONFIG_DIR" ]; then
    INSTALL_BASE="$INSTALL_CONFIG_DIR"
else
    INSTALL_BASE="$DEBUG_INSTALL_DIR"
fi
PLUGINS_DIR="$INSTALL_BASE/Plugins"
mkdir -p "$INSTALL_BASE" "$PLUGINS_DIR"

# --- Post-build: Copy required libraries and frameworks for debug run ---
APP_NAME="${APP_NAME:-ManiVault Studio.app}"
APP_PATH="$INSTALL_BASE/$APP_NAME"
FRAMEWORKS_PATH="$APP_PATH/Contents/Frameworks"
QT_BIN_DIR="$QT_DIR/bin"

echo "\n=== Post-build: Ensuring required libraries for debug app ==="
mkdir -p "$FRAMEWORKS_PATH"

# Generate PkgInfo file
echo "APPL????" > "$APP_PATH/Contents/PkgInfo"

# Copy QtTest.framework to Frameworks
QT_TEST_FRAMEWORK_SRC="$QT_DIR/lib/QtTest.framework"
if [ -d "$QT_TEST_FRAMEWORK_SRC" ]; then
    cp -R "$QT_TEST_FRAMEWORK_SRC" "$FRAMEWORKS_PATH/" || echo "Warning: Could not copy QtTest.framework"
else
    echo "Warning: QtTest.framework not found at $QT_TEST_FRAMEWORK_SRC"
fi

# Copy Qt frameworks
for fw in QtCore QtGui QtWidgets QtWebEngineCore QtWebEngineWidgets QtQuick QtWebChannel QtNetwork QtPositioning QtQmlModels QtQml QtTest; do
    src="$QT_DIR/lib/${fw}.framework"
    if [ -d "$src" ]; then
        cp -R "$src" "$FRAMEWORKS_PATH/" || echo "Warning: Could not copy $fw framework"
    fi
done


# Copy Advanced Docking library
ADVANCED_DOCKING_LIB_RELEASE="$LIBRARIES_ROOT/qads/libqtadvanceddocking-qt6.dylib"
ADVANCED_DOCKING_LIB_DEBUG="$LIBRARIES_ROOT/libqtadvanceddockingd-qt6.dylib"
ADVANCED_DOCKING_EXPECTED_NAME_RELEASE="libqtadvanceddocking.5.1.1.dylib"
ADVANCED_DOCKING_EXPECTED_NAME_DEBUG="libqtadvanceddockingd.5.1.1.dylib"
if [ -f "$ADVANCED_DOCKING_LIB_RELEASE" ]; then
    cp "$ADVANCED_DOCKING_LIB_RELEASE" "$FRAMEWORKS_PATH/$ADVANCED_DOCKING_EXPECTED_NAME_RELEASE"
    # set id only if different
    if ! otool -D "$FRAMEWORKS_PATH/$ADVANCED_DOCKING_EXPECTED_NAME_RELEASE" | grep -q "@rpath/$ADVANCED_DOCKING_EXPECTED_NAME_RELEASE"; then
        install_name_tool -id "@rpath/$ADVANCED_DOCKING_EXPECTED_NAME_RELEASE" "$FRAMEWORKS_PATH/$ADVANCED_DOCKING_EXPECTED_NAME_RELEASE"
    fi
fi
if [ -f "$ADVANCED_DOCKING_LIB_DEBUG" ]; then
    cp "$ADVANCED_DOCKING_LIB_DEBUG" "$FRAMEWORKS_PATH/$ADVANCED_DOCKING_EXPECTED_NAME_DEBUG"
    install_name_tool -id "@rpath/$ADVANCED_DOCKING_EXPECTED_NAME_DEBUG" "$FRAMEWORKS_PATH/$ADVANCED_DOCKING_EXPECTED_NAME_DEBUG"
else
    # Always copy and rename the release library as the debug version
    if [ -f "$ADVANCED_DOCKING_LIB_RELEASE" ]; then
        cp "$ADVANCED_DOCKING_LIB_RELEASE" "$FRAMEWORKS_PATH/$ADVANCED_DOCKING_EXPECTED_NAME_DEBUG"
        install_name_tool -id "@rpath/$ADVANCED_DOCKING_EXPECTED_NAME_DEBUG" "$FRAMEWORKS_PATH/$ADVANCED_DOCKING_EXPECTED_NAME_DEBUG"
    fi
fi



# Copy OpenMP library from Homebrew location
if [ -f "$OPENMP_LIB/libomp.dylib" ]; then
    cp "$OPENMP_LIB/libomp.dylib" "$FRAMEWORKS_PATH/libomp.dylib"
    if ! otool -D "$FRAMEWORKS_PATH/libomp.dylib" | grep -q "@rpath/libomp.dylib"; then
        install_name_tool -id "@rpath/libomp.dylib" "$FRAMEWORKS_PATH/libomp.dylib"
    fi
    echo "Copied libomp.dylib from Homebrew to Frameworks."
else
    echo "Warning: libomp.dylib not found at $OPENMP_LIB/libomp.dylib"
fi

PLUGINS_SRC="$PLUGINS_DIR"
PLUGINS_DEST="$APP_PATH/Contents/Plugins"
mkdir -p "$PLUGINS_DEST"

# Copy FLANN libraries
FLANN_LIB_DIR="$LIBRARIES_ROOT/flann/build_universal/lib"
if [ -d "$FLANN_LIB_DIR" ]; then
    cp "$FLANN_LIB_DIR"/libflann*.dylib "$FRAMEWORKS_PATH/" 2>/dev/null || true
    # Also copy debug versions if present
    cp "$FLANN_LIB_DIR"/libflannd*.dylib "$FRAMEWORKS_PATH/" 2>/dev/null || true
    cp "$FLANN_LIB_DIR"/libflann_cpp*.dylib "$FRAMEWORKS_PATH/" 2>/dev/null || true
    cp "$FLANN_LIB_DIR"/libflann_cppd*.dylib "$FRAMEWORKS_PATH/" 2>/dev/null || true
    # Create symlink for libflann.1.9.dylib if libflann.dylib exists
    if [ -f "$FRAMEWORKS_PATH/libflann.dylib" ]; then
        # Create real libflann_cpp.1.9.dylib with correct install name
        cp "$FRAMEWORKS_PATH/libflann.dylib" "$FRAMEWORKS_PATH/libflann_cpp.1.9.dylib"
        install_name_tool -id "@rpath/libflann_cpp.1.9.dylib" "$FRAMEWORKS_PATH/libflann_cpp.1.9.dylib"
        # Create symlink for libflann.1.9.dylib
        ln -sf libflann.dylib "$FRAMEWORKS_PATH/libflann.1.9.dylib"
    fi
    # Fallback for versioned names
    if [ ! -f "$FRAMEWORKS_PATH/libflann.dylib" ]; then
        if [ -f "$FRAMEWORKS_PATH/libflann.1.9.2.dylib" ]; then
            ln -sf libflann.1.9.2.dylib "$FRAMEWORKS_PATH/libflann.1.9.dylib"
        fi
        if [ -f "$FRAMEWORKS_PATH/libflann_cpp.1.9.2.dylib" ]; then
            ln -sf libflann_cpp.1.9.2.dylib "$FRAMEWORKS_PATH/libflann_cpp.1.9.dylib"
        fi
    fi
    # Fix FLANN library install names
    for libfile in "$FRAMEWORKS_PATH"/libflann*.dylib; do
        if [[ -f "$libfile" && ! -L "$libfile" ]]; then
            if ! otool -D "$libfile" | grep -q "@rpath/$(basename "$libfile")"; then
                install_name_tool -id "@rpath/$(basename "$libfile")" "$libfile" 2>/dev/null || true
            fi
        fi
    done
fi


# Copy lz4 library
LZ4_LIB_RELEASE="$LIBRARIES_ROOT/lz4-1.9.4/build_universal/lib/liblz4.1.dylib"
LZ4_LIB_DEBUG="$LIBRARIES_ROOT/lz4-1.9.4/build_universal/lib/liblz4.1d.dylib"
if [ -f "$LZ4_LIB_RELEASE" ]; then
    cp "$LZ4_LIB_RELEASE" "$FRAMEWORKS_PATH/liblz4.1.dylib"
    if ! otool -D "$FRAMEWORKS_PATH/liblz4.1.dylib" | grep -q "@rpath/liblz4.1.dylib"; then
        install_name_tool -id "@rpath/liblz4.1.dylib" "$FRAMEWORKS_PATH/liblz4.1.dylib"
    fi
fi
if [ -f "$LZ4_LIB_DEBUG" ]; then
    cp "$LZ4_LIB_DEBUG" "$FRAMEWORKS_PATH/liblz4.1d.dylib"
fi

# Copy CUPS library
CUPS_LIB="$CUPS_BUILD_DIR/lib/libcups.2.dylib"
if [ -f "$CUPS_LIB" ]; then
    cp "$CUPS_LIB" "$FRAMEWORKS_PATH/libcups.2.dylib"
    if ! otool -D "$FRAMEWORKS_PATH/libcups.2.dylib" | grep -q "@rpath/libcups.2.dylib"; then
        install_name_tool -id "@rpath/libcups.2.dylib" "$FRAMEWORKS_PATH/libcups.2.dylib"
    fi
    echo "Copied libcups.2.dylib to Frameworks."
else
    echo "Warning: libcups.2.dylib not found at $CUPS_LIB"
fi

# Helper: find first existing path among candidates
find_first_existing() {
    for candidate in "$@"; do
        if [ -f "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

# Copy libMV_Public.dylib to Frameworks (try multiple locations across layouts)
MV_PUBLIC_SRC=$(find_first_existing \
    "$INSTALL_BASE/lib/libMV_Public.dylib" \
    "$PLUGINS_DIR/libMV_Public.dylib" \
    "$DEBUG_INSTALL_DIR/lib/libMV_Public.dylib" \
    "$DEBUG_INSTALL_DIR/Plugins/libMV_Public.dylib" \
    "$DEBUG_INSTALL_DIR/$CONFIG_DIR/lib/libMV_Public.dylib" \
    "$DEBUG_INSTALL_DIR/$CONFIG_DIR/Plugins/libMV_Public.dylib") || true
if [ -n "$MV_PUBLIC_SRC" ]; then
    cp "$MV_PUBLIC_SRC" "$FRAMEWORKS_PATH/libMV_Public.dylib"
    if ! otool -D "$FRAMEWORKS_PATH/libMV_Public.dylib" | grep -q "@rpath/libMV_Public.dylib"; then
        install_name_tool -id "@rpath/libMV_Public.dylib" "$FRAMEWORKS_PATH/libMV_Public.dylib"
    fi
else
    echo "Warning: libMV_Public.dylib not found in expected locations"
fi


# Copy libImageData.dylib to Frameworks (prefer current config Plugins)
IMAGE_DATA_SRC="$PLUGINS_DIR/libImageData.dylib"
if [ -f "$IMAGE_DATA_SRC" ]; then
    cp "$IMAGE_DATA_SRC" "$FRAMEWORKS_PATH/libImageData.dylib"
    if ! otool -D "$FRAMEWORKS_PATH/libImageData.dylib" | grep -q "@rpath/libImageData.dylib"; then
        install_name_tool -id "@rpath/libImageData.dylib" "$FRAMEWORKS_PATH/libImageData.dylib"
    fi
    echo "Copied libImageData.dylib from $CONFIG_DIR/Plugins to Frameworks."
else
    echo "Warning: libImageData.dylib not found in expected locations ($PLUGINS_DIR)"
fi

# Copy license file to Contents/license
LICENSE_SRC="$INSTALL_BASE/license/LICENSE"
LICENSE_DEST="$APP_PATH/Contents/license"
if [ -f "$LICENSE_SRC" ]; then
    mkdir -p "$(dirname "$LICENSE_DEST")"
    cp "$LICENSE_SRC" "$LICENSE_DEST"
else
    echo "Warning: License file not found at $LICENSE_SRC"
fi


## Copy plugins if needed
PLUGINS_SRC="$PLUGINS_DIR"
PLUGINS_DEST="$APP_PATH/Contents/Plugins"
if [ -d "$PLUGINS_SRC" ]; then
    mkdir -p "$PLUGINS_DEST"
    cp -R "$PLUGINS_SRC"/* "$PLUGINS_DEST/" 2>/dev/null || true
fi
## Copy any additional debug plugin libraries if present
if [ -d "$PLUGINS_SRC" ]; then
    find "$PLUGINS_SRC" -name "*.dylib" -or -name "*.so" | while read plugin_lib; do
        cp "$plugin_lib" "$PLUGINS_DEST/"
    done
fi

# Post-build: Copy projects.json and app.json to Customization folder beside app bundle


# Copy .json files only when customization folder is enabled
CUSTOMIZATION_PATH="$INSTALL_BASE/Customization"
INSTALLER_MATERIALS_DIR="${INSTALLER_MATERIALS_ROOT:-$SCRIPTS_DIR/../installer_materials/projects/${PROFILE_NAME:-default}}"

customization_flag="$(printf '%s' "$CUSTOMIZATION_FOLDER_PRESENT" | tr '[:upper:]' '[:lower:]')"
if [[ "$customization_flag" == "true" ]]; then
    mkdir -p "$CUSTOMIZATION_PATH"
    for json_file in projects.json app.json; do
        SRC_JSON="$INSTALLER_MATERIALS_DIR/$json_file"
        if [ -f "$SRC_JSON" ]; then
            cp "$SRC_JSON" "$CUSTOMIZATION_PATH/"
            echo "Copied $json_file to $CUSTOMIZATION_PATH."
        else
            echo "Warning: $SRC_JSON not found, $json_file not copied."
        fi
    done
else
    rm -rf "$CUSTOMIZATION_PATH"
    echo "Customization folder disabled by profile (CUSTOMIZATION_FOLDER_PRESENT=$CUSTOMIZATION_FOLDER_PRESENT)."
fi


# Run macdeployqt to fix up Qt dependencies
if [ -x "$QT_BIN_DIR/macdeployqt" ]; then
    "$QT_BIN_DIR/macdeployqt" "$APP_PATH" -verbose=1 || echo "Warning: macdeployqt failed"
else
    echo "Warning: macdeployqt not found at $QT_BIN_DIR/macdeployqt"
fi



# Ensure main executable has correct rpath and lz4 dependency
EXE_PATH=$(find "$APP_PATH/Contents/MacOS" -type f -perm +111 -print -quit)
if [ -n "$EXE_PATH" ]; then
    if ! otool -l "$EXE_PATH" | grep -q "path @executable_path/../Frameworks"; then
        install_name_tool -add_rpath "@executable_path/../Frameworks" "$EXE_PATH"
    else
        echo "RPATH @executable_path/../Frameworks already present in $EXE_PATH"
    fi
    # Fix lz4 dependency in main executable
    otool -L "$EXE_PATH" | grep "/usr/local/lib/liblz4.1.dylib" >/dev/null 2>&1 && install_name_tool -change "/usr/local/lib/liblz4.1.dylib" "@rpath/liblz4.1.dylib" "$EXE_PATH"
fi

# Fix lz4 dependency in all Frameworks dylibs
for fw_dylib in "$FRAMEWORKS_PATH"/*.dylib; do
    if [[ -f "$fw_dylib" ]]; then
        safe_patch_dependency "$fw_dylib" "/usr/local/lib/liblz4.1.dylib" "@rpath/liblz4.1.dylib"
        safe_patch_dependency "$fw_dylib" "/opt/homebrew/lib/liblz4.1.dylib" "@rpath/liblz4.1.dylib"
    fi
done

echo "\n=== Post-build: Fixing liblz4.1.dylib dependency in plugins ==="
LZ4_FRAMEWORKS_PATH="$FRAMEWORKS_PATH/liblz4.1.dylib"
PLUGINS_PATH="$APP_PATH/Contents/Plugins"
for plugin_dylib in "$PLUGINS_PATH"/*.dylib; do
    if [[ -f "$plugin_dylib" ]]; then
        safe_patch_dependency "$plugin_dylib" "/usr/local/lib/liblz4.1.dylib" "@rpath/liblz4.1.dylib"
        safe_patch_dependency "$plugin_dylib" "/opt/homebrew/lib/liblz4.1.dylib" "@rpath/liblz4.1.dylib"
    fi
done




echo "\n=== Final patch: Patching liblz4.1.dylib linkage in all binaries ==="
find "$DEBUG_INSTALL_DIR" -type f \( -name "*.dylib" -o -perm +111 \) | while read BIN; do
    safe_patch_dependency "$BIN" "/usr/local/lib/liblz4.1.dylib" "@rpath/liblz4.1.dylib"
    safe_patch_dependency "$BIN" "/opt/homebrew/lib/liblz4.1.dylib" "@rpath/liblz4.1.dylib"
done

echo "\n=== Final patch: Ensuring rpath for all plugin dylibs ==="
for plugin_dylib in "$PLUGINS_DIR"/*.dylib; do
    if [[ -f "$plugin_dylib" ]]; then
        chmod +w "$plugin_dylib"
        if ! otool -l "$plugin_dylib" | grep -q "path @executable_path/../Frameworks"; then
            install_name_tool -add_rpath "@executable_path/../Frameworks" "$plugin_dylib"
        else
            echo "RPATH @executable_path/../Frameworks already present in $plugin_dylib"
        fi
        if ! otool -l "$plugin_dylib" | grep -q "path @loader_path/../Frameworks"; then
            install_name_tool -add_rpath "@loader_path/../Frameworks" "$plugin_dylib"
        else
            echo "RPATH @loader_path/../Frameworks already present in $plugin_dylib"
        fi
    fi
done

# Code sign the app bundle for development (ad-hoc signing)
echo "\n=== Code signing the app bundle for development ==="
if command -v codesign >/dev/null 2>&1; then
    codesign --force --deep --sign - "$APP_PATH" || echo "Warning: Code signing failed"
    echo "App bundle signed with ad-hoc signature."
else
    echo "Warning: codesign command not found, app may not run due to code signing requirements."
fi

echo "=== $BUILD_TYPE build completed! ==="
echo "Installation directory: $DEBUG_INSTALL_DIR"

echo "\n=== Final patch: Forcibly patching liblz4.1.dylib linkage in all plugin dylibs (recursive, with chmod, including TsneAnalysisPlugin and HsneAnalysisPlugin) ==="
find "$PLUGINS_DIR" -type f -name "*.dylib" | while read plugin_dylib; do
    if [[ -f "$plugin_dylib" ]]; then
        safe_patch_dependency "$plugin_dylib" "/usr/local/lib/liblz4.1.dylib" "@rpath/liblz4.1.dylib"
        safe_patch_dependency "$plugin_dylib" "/opt/homebrew/lib/liblz4.1.dylib" "@rpath/liblz4.1.dylib"
    fi
done
# Extra: Patch all plugin dylibs in the final Plugins destination (in case some are copied after previous patch)
PLUGINS_FINAL_DEST="$APP_PATH/Contents/Plugins"
if [ -d "$PLUGINS_FINAL_DEST" ]; then
    # Patch all plugin dylibs
    find "$PLUGINS_FINAL_DEST" -type f -name "*.dylib" | while read plugin_dylib; do
        if [[ -f "$plugin_dylib" ]]; then
            chmod +w "$plugin_dylib"
            safe_patch_dependency "$plugin_dylib" "/usr/local/lib/liblz4.1.dylib" "@rpath/liblz4.1.dylib"
            safe_patch_dependency "$plugin_dylib" "/opt/homebrew/lib/liblz4.1.dylib" "@rpath/liblz4.1.dylib"
        fi
    done
    # Explicitly patch TsneAnalysisPlugin and HsneAnalysisPlugin dylibs if present
    for plugin_dylib in "$PLUGINS_FINAL_DEST"/libTsneAnalysisPlugin*.dylib "$PLUGINS_FINAL_DEST"/libHsneAnalysisPlugin*.dylib; do
        if [[ -f "$plugin_dylib" ]]; then
            chmod +w "$plugin_dylib"
            safe_patch_dependency "$plugin_dylib" "/usr/local/lib/liblz4.1.dylib" "@rpath/liblz4.1.dylib"
            safe_patch_dependency "$plugin_dylib" "/opt/homebrew/lib/liblz4.1.dylib" "@rpath/liblz4.1.dylib"
        fi
    done
fi

# Example usage with new flags:
# ./build_debug.sh --core yes --data XSCTreeData,CellMorphologyData --plugins MEView,UMAP-Plugin --tsne yes --rerun-cmake yes --rerun-build yes --post-build yes
# ./build_debug.sh --core yes --data all --plugins all --tsne no --rerun-cmake no --rerun-build yes --post-build yes
# ./build_debug.sh --core yes --data XSCTreeData,CellMorphologyData --plugins MEView,UMAP-Plugin --rerun-cmake no --rerun-build no --post-build no
# ./build_debug.sh --core no --data none --plugins all --tsne yes --rerun-cmake no --rerun-build no --post-build no
# ./build_debug.sh --core no --data none --plugins MEView,UMAP-Plugin --tsne no --rerun-cmake yes --rerun-build no --post-build yes
# ./build_debug.sh --core no --data none --plugins Scatterplot --tsne no --rerun-cmake no --rerun-build no --post-build no

#for relwithdebinfo
#otool -L /Users/soumyadeepbasu/PhDProjectCodes/HMBAViewerInstallerCreation/debug/relwithdebinfo_install/RelWithDebInfo/Plugins/libTsneAnalysisPlugin_p1.0.0_c1.4.0.dylib /Users/soumyadeepbasu/PhDProjectCodes/HMBAViewerInstallerCreation/debug/relwithdebinfo_install/RelWithDebInfo/Plugins/libHsneAnalysisPlugin_p1.0.0_c1.4.0.dylib
#chmod +w /Users/soumyadeepbasu/PhDProjectCodes/HMBAViewerInstallerCreation/debug/relwithdebinfo_install/RelWithDebInfo/Plugins/libTsneAnalysisPlugin_p1.0.0_c1.4.0.dylib /Users/soumyadeepbasu/PhDProjectCodes/HMBAViewerInstallerCreation/debug/relwithdebinfo_install/RelWithDebInfo/Plugins/libHsneAnalysisPlugin_p1.0.0_c1.4.0.dylib && install_name_tool -change /usr/local/lib/liblz4.1.dylib @rpath/liblz4.1.dylib /Users/soumyadeepbasu/PhDProjectCodes/HMBAViewerInstallerCreation/debug/relwithdebinfo_install/RelWithDebInfo/Plugins/libTsneAnalysisPlugin_p1.0.0_c1.4.0.dylib && install_name_tool -change /usr/local/lib/liblz4.1.dylib @rpath/liblz4.1.dylib /Users/soumyadeepbasu/PhDProjectCodes/HMBAViewerInstallerCreation/debug/relwithdebinfo_install/RelWithDebInfo/Plugins/libHsneAnalysisPlugin_p1.0.0_c1.4.0.dylib
#otool -L /Users/soumyadeepbasu/PhDProjectCodes/HMBAViewerInstallerCreation/debug/relwithdebinfo_install/RelWithDebInfo/Plugins/libTsneAnalysisPlugin_p1.0.0_c1.4.0.dylib /Users/soumyadeepbasu/PhDProjectCodes/HMBAViewerInstallerCreation/debug/relwithdebinfo_install/RelWithDebInfo/Plugins/libHsneAnalysisPlugin_p1.0.0_c1.4.0.dylib

#for debug
#otool -L /Users/soumyadeepbasu/PhDProjectCodes/HMBAViewerInstallerCreation/debug/debug_install/Debug/Plugins/libTsneAnalysisPlugin_p1.0.0_c1.4.0.dylib /Users/soumyadeepbasu/PhDProjectCodes/HMBAViewerInstallerCreation/debug/debug_install/Debug/Plugins/libHsneAnalysisPlugin_p1.0.0_c1.4.0.dylib
#chmod +w /Users/soumyadeepbasu/PhDProjectCodes/HMBAViewerInstallerCreation/debug/debug_install/Debug/Plugins/libTsneAnalysisPlugin_p1.0.0_c1.4.0.dylib /Users/soumyadeepbasu/PhDProjectCodes/HMBAViewerInstallerCreation/debug/debug_install/Debug/Plugins/libHsneAnalysisPlugin_p1.0.0_c1.4.0.dylib && install_name_tool -change /usr/local/lib/liblz4.1.dylib @rpath/liblz4.1.dylib /Users/soumyadeepbasu/PhDProjectCodes/HMBAViewerInstallerCreation/debug/debug_install/Debug/Plugins/libTsneAnalysisPlugin_p1.0.0_c1.4.0.dylib && install_name_tool -change /usr/local/lib/liblz4.1.dylib @rpath/liblz4.1.dylib /Users/soumyadeepbasu/PhDProjectCodes/HMBAViewerInstallerCreation/debug/debug_install/Debug/Plugins/libHsneAnalysisPlugin_p1.0.0_c1.4.0.dylib
#otool -L /Users/soumyadeepbasu/PhDProjectCodes/HMBAViewerInstallerCreation/debug/debug_install/Debug/Plugins/libTsneAnalysisPlugin_p1.0.0_c1.4.0.dylib /Users/soumyadeepbasu/PhDProjectCodes/HMBAViewerInstallerCreation/debug/debug_install/Debug/Plugins/libHsneAnalysisPlugin_p1.0.0_c1.4.0.dylib   

#for release
#otool -L /Users/soumyadeepbasu/PhDProjectCodes/HMBAViewerInstallerCreation/debug/release_install/Release/Plugins/libTsneAnalysisPlugin_p1.0.0_c1.4.0.dylib /Users/soumyadeepbasu/PhDProjectCodes/HMBAViewerInstallerCreation/debug/release_install/Release/Plugins/libHsneAnalysisPlugin_p1.0.0_c1.4.0.dylib
#chmod +w /Users/soumyadeepbasu/PhDProjectCodes/HMBAViewerInstallerCreation/debug/release_install/Release/Plugins/libTsneAnalysisPlugin_p1.0.0_c1.4.0.dylib /Users/soumyadeepbasu/PhDProjectCodes/HMBAViewerInstallerCreation/debug/release_install/Release/Plugins/libHsneAnalysisPlugin_p1.0.0_c1.4.0.dylib && install_name_tool -change /usr/local/lib/liblz4.1.dylib @rpath/liblz4.1.dylib /Users/soumyadeepbasu/PhDProjectCodes/HMBAViewerInstallerCreation/debug/release_install/Release/Plugins/libTsneAnalysisPlugin_p1.0.0_c1.4.0.dylib && install_name_tool -change /usr/local/lib/liblz4.1.dylib @rpath/liblz4.1.dylib /Users/soumyadeepbasu/PhDProjectCodes/HMBAViewerInstallerCreation/debug/release_install/Release/Plugins/libHsneAnalysisPlugin_p1.0.0_c1.4.0.dylib
#otool -L /Users/soumyadeepbasu/PhDProjectCodes/HMBAViewerInstallerCreation/debug/release_install/Release/Plugins/libTsneAnalysisPlugin_p1.0.0_c1.4.0.dylib /Users/soumyadeepbasu/PhDProjectCodes/HMBAViewerInstallerCreation/debug/release_install/Release/Plugins/libHsneAnalysisPlugin_p1.0.0_c1.4.0.dylib   

# for minsizerel 
#otool -L /Users/soumyadeepbasu/PhDProjectCodes/HMBAViewerInstallerCreation/debug/minsizerel_install/MinSizeRel/Plugins/libTsneAnalysisPlugin_p1.0.0_c1.4.0.dylib /Users/soumyadeepbasu/PhDProjectCodes/HMBAViewerInstallerCreation/debug/minsizerel_install/MinSizeRel/Plugins/libHsneAnalysisPlugin_p1.0.0_c1.4.0.dylib
#chmod +w /Users/soumyadeepbasu/PhDProjectCodes/HMBAViewerInstallerCreation/debug/minsizerel_install/MinSizeRel/Plugins/libTsneAnalysisPlugin_p1.0.0_c1.4.0.dylib /Users/soumyadeepbasu/PhDProjectCodes/HMBAViewerInstallerCreation/debug/minsizerel_install/MinSizeRel/Plugins/libHsneAnalysisPlugin_p1.0.0_c1.4.0.dylib && install_name_tool -change /usr/local/lib/liblz4.1.dylib @rpath/liblz4.1.dylib /Users/soumyadeepbasu/PhDProjectCodes/HMBAViewerInstallerCreation/debug/minsizerel_install/MinSizeRel/Plugins/libTsneAnalysisPlugin_p1.0.0_c1.4.0.dylib && install_name_tool -change /usr/local/lib/liblz4.1.dylib @rpath/liblz4.1.dylib /Users/soumyadeepbasu/PhDProjectCodes/HMBAViewerInstallerCreation/debug/minsizerel_install/MinSizeRel/Plugins/libHsneAnalysisPlugin_p1.0.0_c1.4.0.dylib
#otool -L /Users/soumyadeepbasu/PhDProjectCodes/HMBAViewerInstallerCreation/debug/minsizerel_install/MinSizeRel/Plugins/libTsneAnalysisPlugin_p1.0.0_c1.4.0.dylib /Users/soumyadeepbasu/PhDProjectCodes/HMBAViewerInstallerCreation/debug/minsizerel_install/MinSizeRel/Plugins/libHsneAnalysisPlugin_p1.0.0_c1.4.0.dylib
