#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIBRARIES_ROOT="${LIBRARIES_ROOT:-$(cd "$SCRIPTS_ROOT/../libraries" && pwd)}"

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

# Function to find pkg-config executable
find_pkgconfig() {
    # Check Homebrew locations first
    PKGCONFIG_LOCATIONS=(
        "/opt/homebrew/bin/pkg-config"  # Apple Silicon Homebrew
        "/usr/local/bin/pkg-config"     # Intel Homebrew
    )

    for location in "${PKGCONFIG_LOCATIONS[@]}"; do
        if [ -x "$location" ]; then
            PKG_CONFIG_BIN="$location"
            echo "✅ Found pkg-config at: $PKG_CONFIG_BIN"
            export PKG_CONFIG_EXECUTABLE="$PKG_CONFIG_BIN"
            return 0
        fi
    done

    # Check if pkg-config is in PATH
    if command -v pkg-config >/dev/null 2>&1; then
        PKG_CONFIG_BIN="pkg-config"
        export PKG_CONFIG_EXECUTABLE="$(which pkg-config)"
        echo "✅ Found pkg-config in PATH: $PKG_CONFIG_EXECUTABLE"
        return 0
    fi

    echo "❌ Error: pkg-config not found!"
    echo "Please install pkg-config using Homebrew: brew install pkg-config"
    exit 1
}

# Find pkg-config executable
find_pkgconfig
export PKG_CONFIG_PATH="${LIBRARIES_ROOT}/lz4-${LZ4_VERSION:-1.9.4}/build_universal/lib/pkgconfig:${LIBRARIES_ROOT}/flann/build_universal/lib/pkgconfig:${LIBRARIES_ROOT}/qads/build_universal/lib/pkgconfig:${LIBRARIES_ROOT}/hdf5-${HDF5_VERSION:-1.14.6}/install_universal_static/lib/pkgconfig:${LIBRARIES_ROOT}/zlib-${ZLIB_VERSION:-1.3.1}/build_universal/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export CMAKE_PREFIX_PATH="${LIBRARIES_ROOT}/lz4-${LZ4_VERSION:-1.9.4}/build_universal:${LIBRARIES_ROOT}/qads/build_universal/lib/cmake/qads:${LIBRARIES_ROOT}/hdf5-${HDF5_VERSION:-1.14.6}/install_universal_static/share/cmake/hdf5:${LIBRARIES_ROOT}/zlib-${ZLIB_VERSION:-1.3.1}/build_universal/share/cmake/zlib:${CMAKE_PREFIX_PATH:-}"
HDILIB_SRC="${LIBRARIES_ROOT}/HDILib"
BUILD_DIR="${HDILIB_SRC}/build_universal"
INSTALL_DIR="${HDILIB_SRC}/install_universal"

# Clone HDILib repo if not present
if [ ! -d "$HDILIB_SRC/.git" ]; then
    echo "🔄 Cloning HDILib repository..."
    git clone https://github.com/biovault/HDILib.git "$HDILIB_SRC"
else
    echo "✅ HDILib repository already exists."
fi

# Set FLANN path
FLANN_DIR="${LIBRARIES_ROOT}/flann/build_universal"

# Set LZ4 path
LZ4_DIR="${LIBRARIES_ROOT}/lz4-${LZ4_VERSION:-1.9.4}/build_universal"

# --- OpenMP Configuration ---
OPENMP_VERSION="${OPENMP_VERSION:-21.1.2}"
OPENMP_BUILD_DIR="$LIBRARIES_ROOT/openmp-${OPENMP_VERSION}/build_universal"

# Check if custom OpenMP is available
if [ -d "$OPENMP_BUILD_DIR" ]; then
    echo "✅ Using custom-built universal OpenMP library"
    export CMAKE_PREFIX_PATH="$OPENMP_BUILD_DIR:${CMAKE_PREFIX_PATH:-}"
    export PKG_CONFIG_PATH="$OPENMP_BUILD_DIR/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

    OPENMP_INCLUDE="$OPENMP_BUILD_DIR/include"
    OPENMP_LIB="$OPENMP_BUILD_DIR/lib"
else
    echo "❌ Universal OpenMP library not found!"
    echo "💡 Run './build_openmp_universal_updated.sh' first to build the required universal OpenMP library"
    echo "🚫 Only the custom-built universal OpenMP library is supported"
    exit 1
fi

echo "=============================================="
echo " 🛠  Building HDILib Universal (Release x86_64 + arm64)"
echo "=============================================="

# Verify FLANN exists
if [ ! -d "$FLANN_DIR/include" ]; then
    echo "❌ ERROR: FLANN include directory not found: $FLANN_DIR/include"
    exit 1
fi

if [ ! -f "$FLANN_DIR/lib/libflann_cpp.dylib" ]; then
    echo "❌ ERROR: FLANN shared library not found: $FLANN_DIR/lib/libflann_cpp.dylib"
    exit 1
fi

# Clean previous build
echo "🧹 Cleaning old HDILib build..."
rm -rf "$BUILD_DIR" "$INSTALL_DIR"
mkdir -p "$BUILD_DIR"

# Configure HDILib CMake - use manual FLANN configuration
echo "🏗  Configuring HDILib CMake..."
cd "$BUILD_DIR"

# Clear environment variables that might interfere with OpenMP detection
unset OMP_NUM_THREADS 2>/dev/null || true

$CMAKE_BIN "$HDILIB_SRC" \
    -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="12.0" \
    -DCMAKE_OSX_ARCHITECTURES="x86_64;arm64" \
    -DCMAKE_PREFIX_PATH="$OPENMP_BUILD_DIR;$FLANN_DIR;$LZ4_DIR" \
    -DCMAKE_LIBRARY_PATH="$OPENMP_LIB" \
    -DCMAKE_INCLUDE_PATH="$OPENMP_INCLUDE" \
    -DCMAKE_C_FLAGS="-Xpreprocessor -fopenmp -I$OPENMP_INCLUDE" \
    -DCMAKE_CXX_FLAGS="-DGL_SILENCE_DEPRECATION -I$FLANN_DIR/include -Xpreprocessor -fopenmp -I$OPENMP_INCLUDE" \
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
    -DFLANN_FOUND=ON \
    -DFLANN_INCLUDE_DIR="$FLANN_DIR/include" \
    -DFLANN_LIBRARY="$FLANN_DIR/lib/libflann_cpp.dylib" \
    -DFLANN_VERSION=1.9.2 \
    -DFLANN_USE_STATIC=OFF \
    -Dlz4_DIR="$LZ4_DIR/lib/cmake/lz4"

# Build HDILib
echo "🏗  Building HDILib..."
$CMAKE_BIN --build . --config Release -- -j${BUILD_JOBS:-2}

# Install
echo "📦 Installing HDILib..."
$CMAKE_BIN --install .

echo "✅ HDILib build completed! Installed at $INSTALL_DIR"
