#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIBRARIES_ROOT="${LIBRARIES_ROOT:-$(cd "$SCRIPTS_ROOT/../libraries" && pwd)}"

CUPS_VERSION="${CUPS_VERSION:-2.4.14}"
DEPENDENCY_MIN_MACOS_VERSION="${DEPENDENCY_MIN_MACOS_VERSION:-12.0}"
export MACOSX_DEPLOYMENT_TARGET="$DEPENDENCY_MIN_MACOS_VERSION"

echo "🏗️  Building CUPS version: $CUPS_VERSION"

mkdir -p "${LIBRARIES_ROOT}"
cd "${LIBRARIES_ROOT}"

CUPS_DIR="cups-${CUPS_VERSION}"

# Download CUPS if not present
if [ ! -d "$CUPS_DIR" ]; then
    echo "📥 Downloading CUPS ${CUPS_VERSION}..."
    curl -L -o "cups-${CUPS_VERSION}-source.tar.gz" \
        "https://github.com/OpenPrinting/cups/releases/download/v${CUPS_VERSION}/cups-${CUPS_VERSION}-source.tar.gz"
    tar -xzf "cups-${CUPS_VERSION}-source.tar.gz"
    rm "cups-${CUPS_VERSION}-source.tar.gz"
fi

cd "$CUPS_DIR"

# Clean previous builds
rm -rf install_x86_64 install_arm64 || true
make clean

###################################
# Build x86_64
###################################
echo "🔨 Building CUPS for x86_64..."

# Configure with proper local installation paths
./configure \
    --prefix="${LIBRARIES_ROOT}/${CUPS_DIR}/install_x86_64" \
    --localstatedir="${LIBRARIES_ROOT}/${CUPS_DIR}/install_x86_64/var" \
    --sysconfdir="${LIBRARIES_ROOT}/${CUPS_DIR}/install_x86_64/etc" \
    --with-rundir="${LIBRARIES_ROOT}/${CUPS_DIR}/install_x86_64/var/run" \
    --with-logdir="${LIBRARIES_ROOT}/${CUPS_DIR}/install_x86_64/var/log" \
    --with-domainsocket="${LIBRARIES_ROOT}/${CUPS_DIR}/install_x86_64/var/run/cups.sock" \
    --host=x86_64-apple-darwin \
    --enable-shared \
    --disable-static \
    --disable-gssapi \
    --disable-launchd \
    --without-tls \
    CC="clang -arch x86_64" \
    CXX="clang++ -arch x86_64" \
    CFLAGS="-mmacosx-version-min=$DEPENDENCY_MIN_MACOS_VERSION" \
    LDFLAGS="-arch x86_64 -mmacosx-version-min=$DEPENDENCY_MIN_MACOS_VERSION"

make -j${BUILD_JOBS:-2}

# Copy libraries and headers manually since install may fail
mkdir -p "${LIBRARIES_ROOT}/${CUPS_DIR}/install_x86_64/lib"
mkdir -p "${LIBRARIES_ROOT}/${CUPS_DIR}/install_x86_64/include"

echo "Checking cups dir for dylibs..."
ls -la cups/ | grep dylib || echo "No dylibs in cups/"
ls -la cups/.libs/ | grep dylib 2>/dev/null || echo "No .libs or no dylibs in .libs"

cp cups/*.dylib "${LIBRARIES_ROOT}/${CUPS_DIR}/install_x86_64/lib/" 2>/dev/null || true
cp cups/.libs/*.dylib "${LIBRARIES_ROOT}/${CUPS_DIR}/install_x86_64/lib/" 2>/dev/null || true
cp cups/*.h "${LIBRARIES_ROOT}/${CUPS_DIR}/install_x86_64/include/" 2>/dev/null || true

echo "After cp, checking install_x86_64/lib/"
ls -la "${LIBRARIES_ROOT}/${CUPS_DIR}/install_x86_64/lib/" | head -10

make install-exec || true
make install-data || true

###################################
# Build arm64
###################################
echo "🔨 Building CUPS for arm64..."

make clean

# Configure with proper local installation paths
./configure \
    --prefix="${LIBRARIES_ROOT}/${CUPS_DIR}/install_arm64" \
    --localstatedir="${LIBRARIES_ROOT}/${CUPS_DIR}/install_arm64/var" \
    --sysconfdir="${LIBRARIES_ROOT}/${CUPS_DIR}/install_arm64/etc" \
    --with-rundir="${LIBRARIES_ROOT}/${CUPS_DIR}/install_arm64/var/run" \
    --with-logdir="${LIBRARIES_ROOT}/${CUPS_DIR}/install_arm64/var/log" \
    --with-domainsocket="${LIBRARIES_ROOT}/${CUPS_DIR}/install_arm64/var/run/cups.sock" \
    --host=aarch64-apple-darwin \
    --enable-shared \
    --disable-static \
    --disable-gssapi \
    --disable-launchd \
    --without-tls \
    CC="clang -arch arm64" \
    CXX="clang++ -arch arm64" \
    CFLAGS="-mmacosx-version-min=$DEPENDENCY_MIN_MACOS_VERSION" \
    LDFLAGS="-arch arm64 -mmacosx-version-min=$DEPENDENCY_MIN_MACOS_VERSION"

make -j${BUILD_JOBS:-2}

# Copy libraries and headers manually since install may fail
mkdir -p "${LIBRARIES_ROOT}/${CUPS_DIR}/install_arm64/lib"
mkdir -p "${LIBRARIES_ROOT}/${CUPS_DIR}/install_arm64/include"

echo "Checking cups dir for dylibs..."
ls -la cups/ | grep dylib || echo "No dylibs in cups/"
ls -la cups/.libs/ | grep dylib 2>/dev/null || echo "No .libs or no dylibs in .libs"

cp cups/*.dylib "${LIBRARIES_ROOT}/${CUPS_DIR}/install_arm64/lib/" 2>/dev/null || true
cp cups/.libs/*.dylib "${LIBRARIES_ROOT}/${CUPS_DIR}/install_arm64/lib/" 2>/dev/null || true
cp cups/*.h "${LIBRARIES_ROOT}/${CUPS_DIR}/install_arm64/include/" 2>/dev/null || true

echo "After cp, checking install_arm64/lib/"
ls -la "${LIBRARIES_ROOT}/${CUPS_DIR}/install_arm64/lib/" | head -10

make install-exec || true
make install-data || true

cd ..

###################################
# Create universal binary
###################################
echo "🔨 Creating universal CUPS binary..."
mkdir -p ${CUPS_DIR}/build_universal/lib
mkdir -p ${CUPS_DIR}/build_universal/include

# Create universal libcups.2.dylib
if [ -f "${CUPS_DIR}/install_x86_64/lib/libcups.2.dylib" ] && [ -f "${CUPS_DIR}/install_arm64/lib/libcups.2.dylib" ]; then
    echo "✅ Creating universal libcups.2.dylib..."
    lipo -create \
        ${CUPS_DIR}/install_x86_64/lib/libcups.2.dylib \
        ${CUPS_DIR}/install_arm64/lib/libcups.2.dylib \
        -output ${CUPS_DIR}/build_universal/lib/libcups.2.dylib

    # Set proper install name
    install_name_tool -id "@rpath/libcups.2.dylib" ${CUPS_DIR}/build_universal/lib/libcups.2.dylib

    echo "✅ Universal libcups.2.dylib created successfully"
else
    echo "❌ Error: Could not find libcups.2.dylib files from individual builds"
    exit 1
fi

# Copy other libraries if they exist
for lib in libcupsimage.2.dylib libcupsmime.1.dylib libcupsppdc.1.dylib; do
    if [ -f "${CUPS_DIR}/install_x86_64/lib/$lib" ] && [ -f "${CUPS_DIR}/install_arm64/lib/$lib" ]; then
        echo "✅ Creating universal $lib..."
        lipo -create \
            ${CUPS_DIR}/install_x86_64/lib/$lib \
            ${CUPS_DIR}/install_arm64/lib/$lib \
            -output ${CUPS_DIR}/build_universal/lib/$lib
        install_name_tool -id "@rpath/$lib" ${CUPS_DIR}/build_universal/lib/$lib
    fi
done

# Copy headers from arm64 build (they should be identical)
echo "📄 Copying CUPS headers..."
cp -R ${CUPS_DIR}/install_arm64/include/* ${CUPS_DIR}/build_universal/include/

# Create CMake config files
echo "📦 Creating CMake configuration files..."
mkdir -p ${CUPS_DIR}/build_universal/lib/cmake/CUPS

cat > ${CUPS_DIR}/build_universal/lib/cmake/CUPS/CUPSConfig.cmake << EOL
# CUPS CMake configuration file
get_filename_component(_CUPS_INSTALL_PREFIX "\${CMAKE_CURRENT_LIST_DIR}/../../.." ABSOLUTE)

set(CUPS_FOUND TRUE)
set(CUPS_VERSION "${CUPS_VERSION}")

# Include directories
set(CUPS_INCLUDE_DIRS "\${_CUPS_INSTALL_PREFIX}/include")
set(CUPS_C_INCLUDE_DIRS "\${CUPS_INCLUDE_DIRS}")

# Library directories and files
set(CUPS_LIBRARY_DIRS "\${_CUPS_INSTALL_PREFIX}/lib")
set(CUPS_LIBRARIES "\${_CUPS_INSTALL_PREFIX}/lib/libcups.2.dylib")

# Flags
set(CUPS_C_FLAGS "")
set(CUPS_CXX_FLAGS "")

# Version components
set(CUPS_C_VERSION "\${CUPS_VERSION}")

# Create imported targets
if(NOT TARGET CUPS::CUPS)
    add_library(CUPS::CUPS SHARED IMPORTED)
    set_target_properties(CUPS::CUPS PROPERTIES
        INTERFACE_INCLUDE_DIRECTORIES "\${CUPS_C_INCLUDE_DIRS}"
        IMPORTED_LOCATION "\${_CUPS_INSTALL_PREFIX}/lib/libcups.2.dylib"
        IMPORTED_IMPLIB "\${_CUPS_INSTALL_PREFIX}/lib/libcups.2.dylib"
    )
endif()

# Legacy compatibility
set(CUPS_FOUND TRUE)

unset(_CUPS_INSTALL_PREFIX)
EOL

cat > ${CUPS_DIR}/build_universal/lib/cmake/CUPS/CUPSConfigVersion.cmake << EOL
set(PACKAGE_VERSION "${CUPS_VERSION}")
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
PKGCONFIG_DIR="${CUPS_DIR}/build_universal/lib/pkgconfig"
mkdir -p "$PKGCONFIG_DIR"
cat > "$PKGCONFIG_DIR/cups.pc" <<EOL
prefix=${LIBRARIES_ROOT}/${CUPS_DIR}/build_universal
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: CUPS
Description: Common Unix Printing System
Version: ${CUPS_VERSION}
Cflags: -I\${includedir}
Libs: -L\${libdir} -lcups
EOL

# Verify the universal binary
echo "🔍 Verifying universal binary..."
file ${CUPS_DIR}/build_universal/lib/libcups.2.dylib
lipo -info ${CUPS_DIR}/build_universal/lib/libcups.2.dylib

# Clean up intermediate build directories
rm -rf ${CUPS_DIR}/install_x86_64 ${CUPS_DIR}/install_arm64

echo ""
echo "🎉 CUPS universal build completed successfully!"
echo "   📦 Version: $CUPS_VERSION"
echo "   📂 Installation directory: ${LIBRARIES_ROOT}/${CUPS_DIR}/build_universal"
echo "   📚 Library: ${LIBRARIES_ROOT}/${CUPS_DIR}/build_universal/lib/libcups.2.dylib"
echo "   📄 Headers: ${LIBRARIES_ROOT}/${CUPS_DIR}/build_universal/include"
echo "   ⚙️  CMake config: ${LIBRARIES_ROOT}/${CUPS_DIR}/build_universal/lib/cmake/CUPS"
echo "   📦 pkg-config: ${LIBRARIES_ROOT}/${CUPS_DIR}/build_universal/lib/pkgconfig"
echo ""
echo "💡 To use this CUPS build in your projects:"
echo "   export CMAKE_PREFIX_PATH=\"${LIBRARIES_ROOT}/${CUPS_DIR}/build_universal:\$CMAKE_PREFIX_PATH\""
echo "   export PKG_CONFIG_PATH=\"${LIBRARIES_ROOT}/${CUPS_DIR}/build_universal/lib/pkgconfig:\$PKG_CONFIG_PATH\""
