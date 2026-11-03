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

# --- OpenMP Configuration ---
OPENMP_VERSION="${OPENMP_VERSION:-21.1.2}"
OPENMP_BUILD_DIR="$LIBRARIES_ROOT/openmp-${OPENMP_VERSION}/build_universal"

# Check if custom OpenMP is available
if [ -d "$OPENMP_BUILD_DIR" ]; then
    echo "✅ Using custom-built universal OpenMP library"
    export CMAKE_PREFIX_PATH="$OPENMP_BUILD_DIR:${CMAKE_PREFIX_PATH:-}"
    export PKG_CONFIG_PATH="$OPENMP_BUILD_DIR/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

    OPENMP_PREFIX="$OPENMP_BUILD_DIR"
    OPENMP_INCLUDE="$OPENMP_BUILD_DIR/include"
    OPENMP_LIB="$OPENMP_BUILD_DIR/lib"

    # Set OpenMP-specific CMake variables
    OPENMP_CMAKE_FLAGS=(
        "-DOpenMP_ROOT=$OPENMP_PREFIX"
        "-DOpenMP_C_FLAGS=-Xpreprocessor -fopenmp"
        "-DOpenMP_CXX_FLAGS=-Xpreprocessor -fopenmp"
        "-DOpenMP_C_LIB_NAMES=omp"
        "-DOpenMP_CXX_LIB_NAMES=omp"
        "-DOpenMP_omp_LIBRARY=$OPENMP_LIB/libomp.dylib"
        "-DCMAKE_EXE_LINKER_FLAGS=-L$OPENMP_LIB -lomp"
        "-DCMAKE_SHARED_LINKER_FLAGS=-L$OPENMP_LIB -lomp"
    )
else
    echo "❌ Universal OpenMP library not found!"
    echo "💡 Run './build_openmp_universal_updated.sh' first to build the required universal OpenMP library"
    echo "🚫 Only the custom-built universal OpenMP library is supported"
    exit 1
fi

mkdir -p "${LIBRARIES_ROOT}"
cd "${LIBRARIES_ROOT}"

FLANN_VERSION="${FLANN_VERSION:-1.9.2}"
FLANN_COMMIT="${FLANN_COMMIT-c50f296b0b27e14667d272b37acc63f949b305c4}"
FLANN_DIR="$LIBRARIES_ROOT/flann"
if [ ! -d "$FLANN_DIR/.git" ]; then
    if [ -d "$FLANN_DIR" ] && [ "$(ls -A "$FLANN_DIR")" ]; then
        echo "❌ FLANN path exists but is not a Git checkout: $FLANN_DIR" >&2
        exit 1
    fi
    git clone --branch "$FLANN_VERSION" --depth 1 https://github.com/flann-lib/flann.git "$FLANN_DIR"
else
    if [ -n "$(git -C "$FLANN_DIR" status --porcelain)" ] && [ "${ALLOW_DEPENDENCY_SOURCE_RESET:-false}" != "true" ]; then
        echo "❌ FLANN checkout has local changes; refusing to switch to $FLANN_VERSION." >&2
        exit 1
    fi
    if [ "${ALLOW_DEPENDENCY_SOURCE_RESET:-false}" = "true" ]; then
        git -C "$FLANN_DIR" reset --hard
    fi
fi
git -C "$FLANN_DIR" fetch origin "refs/tags/$FLANN_VERSION"
if [ -n "$FLANN_COMMIT" ] && [ "$(git -C "$FLANN_DIR" rev-parse FETCH_HEAD^{commit})" != "$FLANN_COMMIT" ]; then
    echo "❌ FLANN tag $FLANN_VERSION no longer resolves to the pinned commit $FLANN_COMMIT." >&2
    exit 1
fi
git -C "$FLANN_DIR" checkout --detach "${FLANN_COMMIT:-FETCH_HEAD}"
cd "$FLANN_DIR"

# Clean previous builds
rm -rf build_x86_64 build_arm64 build_universal install_x86_64 install_arm64

###################################
# Build x86_64
###################################
echo "Building FLANN for x86_64..."
export PKG_CONFIG_PATH="${LIBRARIES_ROOT}/lz4-${LZ4_VERSION:-1.9.4}/build_universal/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
mkdir -p build_x86_64
cd build_x86_64
$CMAKE_BIN .. \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DBUILD_MATLAB_BINDINGS=OFF \
    -DBUILD_PYTHON_BINDINGS=OFF \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="12.0" \
    -DBUILD_EXAMPLES=OFF \
    -DBUILD_TESTS=OFF \
    -DBUILD_SHARED_LIBS=ON \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=x86_64 \
    -DCMAKE_INSTALL_PREFIX=../install_x86_64 \
    -DUSE_OPENMP=ON \
    "${OPENMP_CMAKE_FLAGS[@]}"
$CMAKE_BIN --build . --config Release
$CMAKE_BIN --install .
cd ..

###################################
# Build arm64
###################################
echo "Building FLANN for arm64..."
export PKG_CONFIG_PATH="${LIBRARIES_ROOT}/lz4-${LZ4_VERSION:-1.9.4}/build_universal/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
mkdir -p build_arm64
cd build_arm64
$CMAKE_BIN .. \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DBUILD_MATLAB_BINDINGS=OFF \
    -DBUILD_PYTHON_BINDINGS=OFF \
    -DBUILD_EXAMPLES=OFF \
    -DBUILD_TESTS=OFF \
    -DBUILD_SHARED_LIBS=ON \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_INSTALL_PREFIX=../install_arm64 \
    -DUSE_OPENMP=ON \
    "${OPENMP_CMAKE_FLAGS[@]}"
$CMAKE_BIN --build . --config Release
$CMAKE_BIN --install .
cd ..

###################################
# Create universal binary
###################################
echo "Creating universal FLANN binary..."
mkdir -p build_universal/lib
mkdir -p build_universal/include

# Merge libraries
for libname in libflann_cpp libflann; do
    if [ -f "install_x86_64/lib/${libname}.1.9.2.dylib" ] && [ -f "install_arm64/lib/${libname}.1.9.2.dylib" ]; then
        lipo -create \
            install_x86_64/lib/${libname}.1.9.2.dylib \
            install_arm64/lib/${libname}.1.9.2.dylib \
            -output build_universal/lib/${libname}.1.9.2.dylib

        # Create symlinks
        cd build_universal/lib
        ln -sf ${libname}.1.9.2.dylib ${libname}.dylib
        ln -sf ${libname}.1.9.2.dylib ${libname}.1.9.dylib
        cd ../..
    fi
done

# Copy headers
cp -R install_arm64/include/* build_universal/include/

# DON'T copy the problematic CMake config files - we'll create our own simple ones
mkdir -p build_universal/lib/cmake/flann

# Create a minimal flann-config.cmake that doesn't reference static libraries
cat > build_universal/lib/cmake/flann/flann-config.cmake << 'EOL'
# FLANN CMake configuration file
set(FLANN_FOUND TRUE)
set(FLANN_VERSION 1.9.2)

# Include directories
set(FLANN_INCLUDE_DIRS "${CMAKE_CURRENT_LIST_DIR}/../../../include")

# Library directories
set(FLANN_LIBRARY_DIRS "${CMAKE_CURRENT_LIST_DIR}/..")

# Libraries
set(FLANN_LIBRARIES flann_cpp)

# Import targets (simplified)
add_library(flann::flann_cpp SHARED IMPORTED)
set_target_properties(flann::flann_cpp PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES "${FLANN_INCLUDE_DIRS}"
  IMPORTED_LOCATION "${FLANN_LIBRARY_DIRS}/libflann_cpp.dylib"
)

add_library(flann::flann SHARED IMPORTED)
set_target_properties(flann::flann PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES "${FLANN_INCLUDE_DIRS}"
  IMPORTED_LOCATION "${FLANN_LIBRARY_DIRS}/libflann.dylib"
)

# Note: This FLANN build is compiled with OpenMP
EOL

# Create a minimal flann-config-version.cmake
cat > build_universal/lib/cmake/flann/flann-config-version.cmake << 'EOL'
set(PACKAGE_VERSION "1.9.2")
if(PACKAGE_VERSION VERSION_LESS PACKAGE_FIND_VERSION)
  set(PACKAGE_VERSION_COMPATIBLE FALSE)
else()
  set(PACKAGE_VERSION_COMPATIBLE TRUE)
  if(PACKAGE_VERSION VERSION_EQUAL PACKAGE_FIND_VERSION)
    set(PACKAGE_VERSION_EXACT TRUE)
  endif()
endif()
EOL

###################################
# Create pkg-config file
###################################
PKGCONFIG_DIR="build_universal/lib/pkgconfig"
mkdir -p "$PKGCONFIG_DIR"

cat > "$PKGCONFIG_DIR/flann.pc" <<EOL
prefix=${LIBRARIES_ROOT}/flann/build_universal
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: FLANN
Description: Fast Library for Approximate Nearest Neighbors
Version: 1.9.2
Cflags: -I\${includedir}
Libs: -L\${libdir} -lflann_cpp
EOL

export PKG_CONFIG_PATH="$PKGCONFIG_DIR:\$PKG_CONFIG_PATH"
echo "✅ FLANN pkg-config file created at $PKGCONFIG_DIR"
echo "PKG_CONFIG_PATH=${PKG_CONFIG_PATH:-}"

echo "✅ Universal FLANN built successfully"
for lib in build_universal/lib/*.dylib; do
    lipo -info "$lib"
done
