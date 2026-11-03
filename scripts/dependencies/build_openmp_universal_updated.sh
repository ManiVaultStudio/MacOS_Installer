#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIBRARIES_ROOT="${LIBRARIES_ROOT:-$(cd "$SCRIPTS_ROOT/../libraries" && pwd)}"

# Function to find cmake and brew executables
find_tools() {
    # Find CMake
    CMAKE_LOCATIONS=(
        "/opt/homebrew/bin/cmake"  # Apple Silicon Homebrew
        "/usr/local/bin/cmake"     # Intel Homebrew
    )

    for location in "${CMAKE_LOCATIONS[@]}"; do
        if [ -x "$location" ]; then
            CMAKE_BIN="$location"
            echo "✅ Found Homebrew CMake at: $CMAKE_BIN"
            break
        fi
    done

    if [ -z "$CMAKE_BIN" ] && command -v cmake >/dev/null 2>&1; then
        CMAKE_BIN="cmake"
        echo "✅ Found CMake in PATH: $(which cmake)"
    fi

    if [ -z "$CMAKE_BIN" ]; then
        echo "❌ Error: CMake not found!"
        echo "Install with: brew install cmake"
        exit 1
    fi

}

find_tools

OPENMP_VERSION="${OPENMP_VERSION:-21.1.2}"

echo "🏗️  Building OpenMP version: $OPENMP_VERSION"

mkdir -p "${LIBRARIES_ROOT}"
cd "${LIBRARIES_ROOT}"

OPENMP_DIR="openmp-${OPENMP_VERSION}"

# Download OpenMP if not present
if [ ! -d "$OPENMP_DIR" ]; then
    echo "📥 Downloading LLVM OpenMP ${OPENMP_VERSION}..."
    curl -L -o "openmp-${OPENMP_VERSION}.src.tar.xz" \
        "https://github.com/llvm/llvm-project/releases/download/llvmorg-${OPENMP_VERSION}/openmp-${OPENMP_VERSION}.src.tar.xz"
    tar -xf "openmp-${OPENMP_VERSION}.src.tar.xz"
    mv "openmp-${OPENMP_VERSION}.src" "$OPENMP_DIR"
    rm "openmp-${OPENMP_VERSION}.src.tar.xz"
fi

cd "$OPENMP_DIR"

# Create temporary CMake modules to fix missing includes
echo "📦 Creating temporary CMake modules for standalone build..."
mkdir -p runtime/cmake
cat > runtime/cmake/LLVMCheckCompilerLinkerFlag.cmake << 'EOL'
# Minimal implementation of LLVMCheckCompilerLinkerFlag
include(CheckCSourceCompiles)
include(CheckCXXSourceCompiles)
include(CMakeCheckCompilerFlagCommonPatterns)

function(llvm_check_compiler_linker_flag lang flag out_var)
  if(lang STREQUAL "C")
    check_c_compiler_flag("${flag}" ${out_var})
  elseif(lang STREQUAL "CXX")
    check_cxx_compiler_flag("${flag}" ${out_var})
  else()
    set(${out_var} FALSE PARENT_SCOPE)
  endif()
endfunction()

function(llvm_check_linker_flag flag out_var)
  set(${out_var} FALSE PARENT_SCOPE)
endfunction()
EOL

cat > runtime/cmake/ExtendPath.cmake << 'EOL'
# Minimal implementation of ExtendPath
function(extend_path out_var)
  set(result_path "")
  foreach(dir ${ARGN})
    if(result_path)
      set(result_path "${result_path}:${dir}")
    else()
      set(result_path "${dir}")
    endif()
  endforeach()
  set(${out_var} "${result_path}" PARENT_SCOPE)
endfunction()
EOL

# Clean previous builds
rm -rf build_x86_64 build_arm64 build_universal install_x86_64 install_arm64 || true

###################################
# Build x86_64
###################################
echo "🔨 Building OpenMP for x86_64..."
mkdir -p build_x86_64
cd build_x86_64
$CMAKE_BIN .. \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="12.0" \
    -DCMAKE_OSX_ARCHITECTURES="x86_64" \
    -DCMAKE_INSTALL_PREFIX="../install_x86_64" \
    -DCMAKE_C_COMPILER=clang \
    -DCMAKE_CXX_COMPILER=clang++ \
    -DLIBOMP_ENABLE_SHARED=ON \
    -DLIBOMP_ENABLE_STATIC=OFF \
    -DOPENMP_ENABLE_LIBOMPTARGET=OFF \
    -DLIBOMP_INSTALL_ALIASES=ON \
    -DOPENMP_STANDALONE_BUILD=TRUE \
    -DCMAKE_DISABLE_FIND_PACKAGE_LLVM=TRUE \
    -DLIBOMP_USE_ITT_NOTIFY=OFF \
    -DLIBOMP_USE_HWLOC=OFF \
    -DOPENMP_ENABLE_TESTING=OFF \
    -DCMAKE_POLICY_DEFAULT_CMP0077=NEW \
    -DLIBOMP_ENABLE_COMPATIBILITY=ON \
    -DLIBOMP_LEGACY_OMPv1=ON

$CMAKE_BIN --build . --config Release -j${BUILD_JOBS:-2}
$CMAKE_BIN --install .
cd ..

###################################
# Build arm64
###################################
echo "🔨 Building OpenMP for arm64..."
mkdir -p build_arm64
cd build_arm64
$CMAKE_BIN .. \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="12.0" \
    -DCMAKE_OSX_ARCHITECTURES="arm64" \
    -DCMAKE_INSTALL_PREFIX="../install_arm64" \
    -DCMAKE_C_COMPILER=clang \
    -DCMAKE_CXX_COMPILER=clang++ \
    -DLIBOMP_ENABLE_SHARED=ON \
    -DLIBOMP_ENABLE_STATIC=OFF \
    -DOPENMP_ENABLE_LIBOMPTARGET=OFF \
    -DLIBOMP_INSTALL_ALIASES=ON \
    -DOPENMP_STANDALONE_BUILD=TRUE \
    -DCMAKE_DISABLE_FIND_PACKAGE_LLVM=TRUE \
    -DLIBOMP_USE_ITT_NOTIFY=OFF \
    -DLIBOMP_USE_HWLOC=OFF \
    -DOPENMP_ENABLE_TESTING=OFF \
    -DCMAKE_POLICY_DEFAULT_CMP0077=NEW \
    -DLIBOMP_ENABLE_COMPATIBILITY=ON \
    -DLIBOMP_LEGACY_OMPv1=ON

$CMAKE_BIN --build . --config Release -j${BUILD_JOBS:-2}
$CMAKE_BIN --install .
cd ..

###################################
# Create universal binary
###################################
echo "🔨 Creating universal OpenMP binary..."
mkdir -p build_universal/lib
mkdir -p build_universal/include

# Create universal libomp.dylib
if [ -f "install_x86_64/lib/libomp.dylib" ] && [ -f "install_arm64/lib/libomp.dylib" ]; then
    echo "✅ Creating universal libomp.dylib..."
    lipo -create \
        install_x86_64/lib/libomp.dylib \
        install_arm64/lib/libomp.dylib \
        -output build_universal/lib/libomp.dylib

    # Set proper install name
    install_name_tool -id "@rpath/libomp.dylib" build_universal/lib/libomp.dylib

    echo "✅ Universal libomp.dylib created successfully"
else
    echo "❌ Error: Could not find libomp.dylib files from individual builds"
    exit 1
fi

# Copy headers from arm64 build (they should be identical)
echo "📄 Copying OpenMP headers..."
cp -R install_arm64/include/* build_universal/include/

# Create CMake config files
echo "📦 Creating CMake configuration files..."
mkdir -p build_universal/lib/cmake/OpenMP

cat > build_universal/lib/cmake/OpenMP/OpenMPConfig.cmake << EOL
# OpenMP CMake configuration file
get_filename_component(_OpenMP_INSTALL_PREFIX "\${CMAKE_CURRENT_LIST_DIR}/../../.." ABSOLUTE)

set(OpenMP_FOUND TRUE)
set(OpenMP_VERSION "${OPENMP_VERSION}")

# Include directories
set(OpenMP_INCLUDE_DIRS "\${_OpenMP_INSTALL_PREFIX}/include")
set(OpenMP_C_INCLUDE_DIRS "\${OpenMP_INCLUDE_DIRS}")
set(OpenMP_CXX_INCLUDE_DIRS "\${OpenMP_INCLUDE_DIRS}")

# Library directories and files
set(OpenMP_LIBRARY_DIRS "\${_OpenMP_INSTALL_PREFIX}/lib")
set(OpenMP_omp_LIBRARY "\${_OpenMP_INSTALL_PREFIX}/lib/libomp.dylib")
set(OpenMP_C_LIBRARIES "\${OpenMP_omp_LIBRARY}")
set(OpenMP_CXX_LIBRARIES "\${OpenMP_omp_LIBRARY}")

# Flags
set(OpenMP_C_FLAGS "-Xpreprocessor -fopenmp")
set(OpenMP_CXX_FLAGS "-Xpreprocessor -fopenmp")
set(OpenMP_C_LIB_NAMES "omp")
set(OpenMP_CXX_LIB_NAMES "omp")

# Version components
set(OpenMP_C_VERSION "\${OpenMP_VERSION}")
set(OpenMP_CXX_VERSION "\${OpenMP_VERSION}")

# Create imported targets
if(NOT TARGET OpenMP::OpenMP_C)
    add_library(OpenMP::OpenMP_C SHARED IMPORTED)
    set_target_properties(OpenMP::OpenMP_C PROPERTIES
        INTERFACE_INCLUDE_DIRECTORIES "\${OpenMP_C_INCLUDE_DIRS}"
        INTERFACE_COMPILE_OPTIONS "-Xpreprocessor;-fopenmp"
        IMPORTED_LOCATION "\${OpenMP_omp_LIBRARY}"
        IMPORTED_IMPLIB "\${OpenMP_omp_LIBRARY}"
    )
endif()

if(NOT TARGET OpenMP::OpenMP_CXX)
    add_library(OpenMP::OpenMP_CXX SHARED IMPORTED)
    set_target_properties(OpenMP::OpenMP_CXX PROPERTIES
        INTERFACE_INCLUDE_DIRECTORIES "\${OpenMP_CXX_INCLUDE_DIRS}"
        INTERFACE_COMPILE_OPTIONS "-Xpreprocessor;-fopenmp"
        IMPORTED_LOCATION "\${OpenMP_omp_LIBRARY}"
        IMPORTED_IMPLIB "\${OpenMP_omp_LIBRARY}"
    )
endif()

# Legacy compatibility
set(OPENMP_FOUND TRUE)
set(OPENMP_INCLUDE_DIRS "\${OpenMP_INCLUDE_DIRS}")
set(OPENMP_LIBRARIES "\${OpenMP_omp_LIBRARY}")

unset(_OpenMP_INSTALL_PREFIX)
EOL

cat > build_universal/lib/cmake/OpenMP/OpenMPConfigVersion.cmake << EOL
set(PACKAGE_VERSION "${OPENMP_VERSION}")
if(PACKAGE_VERSION VERSION_LESS PACKAGE_FIND_VERSION)
  set(PACKAGE_VERSION_COMPATIBLE FALSE)
else()
  set(PACKAGE_VERSION_COMPATIBLE TRUE)
  if(PACKAGE_VERSION VERSION_EQUAL PACKAGE_FIND_VERSION)
    set(PACKAGE_VERSION_EXACT TRUE)
  endif()
endif()
EOL

# Create pkg-config file
echo "📦 Creating pkg-config file..."
PKGCONFIG_DIR="build_universal/lib/pkgconfig"
mkdir -p "$PKGCONFIG_DIR"
cat > "$PKGCONFIG_DIR/openmp.pc" <<EOL
prefix=${LIBRARIES_ROOT}/${OPENMP_DIR}/build_universal
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: OpenMP
Description: OpenMP runtime library
Version: ${OPENMP_VERSION}
Cflags: -I\${includedir} -Xpreprocessor -fopenmp
Libs: -L\${libdir} -lomp
EOL

# Verify the universal binary
echo "🔍 Verifying universal binary..."
file build_universal/lib/libomp.dylib
lipo -info build_universal/lib/libomp.dylib

echo ""
echo "🎉 OpenMP universal build completed successfully!"
echo "   📦 Pinned version: $OPENMP_VERSION"
echo "   📂 Installation directory: ${LIBRARIES_ROOT}/${OPENMP_DIR}/build_universal"
echo "   📚 Library: ${LIBRARIES_ROOT}/${OPENMP_DIR}/build_universal/lib/libomp.dylib"
echo "   📄 Headers: ${LIBRARIES_ROOT}/${OPENMP_DIR}/build_universal/include"
echo "   ⚙️  CMake config: ${LIBRARIES_ROOT}/${OPENMP_DIR}/build_universal/lib/cmake/OpenMP"
echo "   📦 pkg-config: ${LIBRARIES_ROOT}/${OPENMP_DIR}/build_universal/lib/pkgconfig"
echo ""
echo "💡 To use this OpenMP build in your projects:"
echo "   export CMAKE_PREFIX_PATH=\"${LIBRARIES_ROOT}/${OPENMP_DIR}/build_universal:\$CMAKE_PREFIX_PATH\""
echo "   export PKG_CONFIG_PATH=\"${LIBRARIES_ROOT}/${OPENMP_DIR}/build_universal/lib/pkgconfig:\$PKG_CONFIG_PATH\""
