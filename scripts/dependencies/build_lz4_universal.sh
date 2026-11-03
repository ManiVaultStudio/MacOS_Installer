#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIBRARIES_ROOT="${LIBRARIES_ROOT:-$(cd "$SCRIPTS_ROOT/../libraries" && pwd)}"
mkdir -p "${LIBRARIES_ROOT}"
cd "${LIBRARIES_ROOT}"

# Download LZ4 if not present
LZ4_VERSION="${LZ4_VERSION:-1.9.4}"
if [ ! -d "lz4-${LZ4_VERSION}" ]; then
    curl -L -o lz4-${LZ4_VERSION}.tar.gz "https://github.com/lz4/lz4/archive/refs/tags/v${LZ4_VERSION}.tar.gz"
    tar -xzf lz4-${LZ4_VERSION}.tar.gz
    rm lz4-${LZ4_VERSION}.tar.gz
fi
cd lz4-${LZ4_VERSION}


rm -rf build_x86_64 build_arm64 build_universal install_x86_64 install_arm64

###################################
# Build x86_64
###################################
echo "Building LZ4 for x86_64..."
make clean
make CC="clang -arch x86_64 -mmacosx-version-min=12.0" -j${BUILD_JOBS:-2}
mkdir -p install_x86_64/lib
cp lib/liblz4.*.dylib install_x86_64/lib/

###################################
# Build arm64
###################################
echo "Building LZ4 for arm64..."
make clean
make CC="clang -arch arm64 -mmacosx-version-min=12.0" -j${BUILD_JOBS:-2}
mkdir -p install_arm64/lib
cp lib/liblz4.*.dylib install_arm64/lib/

###################################
# Create universal binary
###################################
echo "Creating universal LZ4 binary..."
mkdir -p build_universal/lib
mkdir -p build_universal/include

if [ -f "install_x86_64/lib/liblz4.1.dylib" ] && [ -f "install_arm64/lib/liblz4.1.dylib" ]; then
  lipo -create \
    install_x86_64/lib/liblz4.1.dylib \
    install_arm64/lib/liblz4.1.dylib \
    -output build_universal/lib/liblz4.1.dylib

  # Create symlinks
  cd build_universal/lib
  ln -sf liblz4.1.dylib liblz4.dylib
  cd ../..
fi

# Copy headers
cp -R lib/* build_universal/include/

# Minimal CMake config
mkdir -p build_universal/lib/cmake/lz4
cat > build_universal/lib/cmake/lz4/lz4-config.cmake << 'EOL'
set(LZ4_FOUND TRUE)
set(LZ4_VERSION 1.9.4)
set(LZ4_INCLUDE_DIRS "${CMAKE_CURRENT_LIST_DIR}/../../../include")
set(LZ4_LIBRARY_DIRS "${CMAKE_CURRENT_LIST_DIR}/..")
set(LZ4_LIBRARIES lz4)
add_library(lz4::lz4 SHARED IMPORTED)
set_target_properties(lz4::lz4 PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES "${LZ4_INCLUDE_DIRS}"
  IMPORTED_LOCATION "${LZ4_LIBRARY_DIRS}/liblz4.dylib"
)
EOL

cat > build_universal/lib/cmake/lz4/lz4-config-version.cmake << 'EOL'
set(PACKAGE_VERSION "1.9.4")
if(PACKAGE_VERSION VERSION_LESS PACKAGE_FIND_VERSION)
  set(PACKAGE_VERSION_COMPATIBLE FALSE)
else()
  set(PACKAGE_VERSION_COMPATIBLE TRUE)
  if(PACKAGE_VERSION VERSION_EQUAL PACKAGE_FIND_VERSION)
    set(PACKAGE_VERSION_EXACT TRUE)
  endif()
endif()
EOL

# pkg-config file
PKGCONFIG_DIR="build_universal/lib/pkgconfig"
mkdir -p "$PKGCONFIG_DIR"
cat > "$PKGCONFIG_DIR/liblz4.pc" <<EOL
prefix=${LIBRARIES_ROOT}/lz4-${LZ4_VERSION}/build_universal
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: liblz4
Description: LZ4 compression library
Version: 1.9.4
Cflags: -I\${includedir}
Libs: -L\${libdir} -llz4
EOL

export PKG_CONFIG_PATH="$PKGCONFIG_DIR:\$PKG_CONFIG_PATH"
echo "✅ LZ4 pkg-config file created at $PKGCONFIG_DIR"
echo "PKG_CONFIG_PATH=$PKGCONFIG_PATH"

echo "✅ Universal LZ4 built successfully"
for lib in build_universal/lib/*.dylib; do
    lipo -info "$lib"
done
