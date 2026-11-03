#!/bin/bash

set -euo pipefail

echo "======================================"
echo "   fmt Universal Static Build Script  "
echo "======================================"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIBRARIES_ROOT="${LIBRARIES_ROOT:-$(cd "$SCRIPTS_ROOT/../libraries" && pwd)}"

#######################################
# Configuration
#######################################

FMT_VERSION="${FMT_VERSION:-11.1.4}"
FMT_DIR="$LIBRARIES_ROOT/fmt-${FMT_VERSION}"
FMT_REPO="https://github.com/fmtlib/fmt.git"

MIN_MACOS_VERSION="${MIN_MACOS_VERSION:-12.0}"

# Architectures
X86_64_ARCH="x86_64"
ARM64_ARCH="arm64"

#######################################
# Find CMake
#######################################

find_cmake() {

    CMAKE_LOCATIONS=(
        "/opt/homebrew/bin/cmake"
        "/usr/local/bin/cmake"
        "/Applications/CMake.app/Contents/bin/cmake"
        "/usr/bin/cmake"
    )

    for location in "${CMAKE_LOCATIONS[@]}"; do
        if [ -x "$location" ]; then
            CMAKE_BIN="$location"
            echo "✅ Found CMake: $CMAKE_BIN"
            return 0
        fi
    done

    if command -v cmake >/dev/null 2>&1; then
        CMAKE_BIN="$(command -v cmake)"
        echo "✅ Found CMake: $CMAKE_BIN"
        return 0
    fi

    echo "❌ Error: CMake not found!"
    echo "💡 Install CMake using Homebrew:"
    echo "   brew install cmake"
    exit 1
}

#######################################
# Find Ninja
#######################################

find_ninja() {

    NINJA_LOCATIONS=(
        "/opt/homebrew/bin/ninja"
        "/usr/local/bin/ninja"
    )

    for location in "${NINJA_LOCATIONS[@]}"; do
        if [ -x "$location" ]; then
            NINJA_BIN="$location"
            echo "✅ Found Ninja: $NINJA_BIN"
            return 0
        fi
    done

    if command -v ninja >/dev/null 2>&1; then
        NINJA_BIN="$(command -v ninja)"
        echo "✅ Found Ninja: $NINJA_BIN"
        return 0
    fi

    echo "❌ Error: Ninja not found!"
    echo "💡 Install Ninja using Homebrew:"
    echo "   brew install ninja"
    exit 1
}

#######################################
# Find Git
#######################################

find_git() {

    if command -v git >/dev/null 2>&1; then
        GIT_BIN="$(command -v git)"
        echo "✅ Found Git: $GIT_BIN"
        return 0
    fi

    echo "❌ Error: Git not found!"
    exit 1
}

#######################################
# Find lipo
#######################################

find_lipo() {

    if command -v lipo >/dev/null 2>&1; then
        LIPO_BIN="$(command -v lipo)"
        echo "✅ Found lipo: $LIPO_BIN"
        return 0
    fi

    echo "❌ Error: lipo not found!"
    echo "💡 lipo is provided by Xcode Command Line Tools."
    exit 1
}

#######################################
# Check required tools
#######################################

find_cmake
find_ninja
find_git
find_lipo

#######################################
# Print configuration
#######################################

echo ""
echo "======================================"
echo " Configuration"
echo "======================================"
echo "fmt version       : $FMT_VERSION"
echo "fmt source        : $FMT_DIR"
echo "Minimum macOS    : $MIN_MACOS_VERSION"
echo "CMake             : $CMAKE_BIN"
echo "Ninja             : $NINJA_BIN"
echo "Git               : $GIT_BIN"
echo "lipo              : $LIPO_BIN"
echo "======================================"

#######################################
# Clone fmt
#######################################

mkdir -p "$LIBRARIES_ROOT"

if [ ! -d "$FMT_DIR/.git" ]; then

    echo ""
    echo "📦 Cloning fmt ${FMT_VERSION}..."

    rm -rf "$FMT_DIR"

    "$GIT_BIN" clone \
        --branch "$FMT_VERSION" \
        --depth 1 \
        "$FMT_REPO" \
        "$FMT_DIR"

else

    echo ""
    echo "✅ fmt source already exists:"
    echo "   $FMT_DIR"

    cd "$FMT_DIR"

    echo "🔄 Checking out fmt ${FMT_VERSION}..."

    "$GIT_BIN" fetch --tags >/dev/null 2>&1 || true

    "$GIT_BIN" checkout "$FMT_VERSION"

fi

cd "$FMT_DIR"

#######################################
# Clean previous builds
#######################################

echo ""
echo "🧹 Cleaning old builds..."

rm -rf \
    build_x86_64 \
    build_arm64 \
    build_universal \
    install_x86_64 \
    install_arm64

#######################################
# Common CMake flags
#######################################

COMMON_FLAGS=(

    # Release build
    -DCMAKE_BUILD_TYPE=Release

    # Build static library
    -DBUILD_SHARED_LIBS=OFF

    # Disable tests
    -DFMT_TEST=OFF

    # Disable documentation
    -DFMT_DOC=OFF

    # Install fmt
    -DFMT_INSTALL=ON

    # macOS deployment target
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_MACOS_VERSION"

)

#######################################
# Build function
#######################################

build_arch() {

    local ARCH="$1"

    local BUILD_DIR="$FMT_DIR/build_${ARCH}"
    local INSTALL_DIR="$FMT_DIR/install_${ARCH}"

    echo ""
    echo "======================================"
    echo " Building fmt for ${ARCH}"
    echo "======================================"

    echo "Build directory:"
    echo "  $BUILD_DIR"

    echo "Install directory:"
    echo "  $INSTALL_DIR"

    #######################################
    # Clean architecture build
    #######################################

    rm -rf "$BUILD_DIR"
    rm -rf "$INSTALL_DIR"

    mkdir -p "$BUILD_DIR"

    #######################################
    # Configure
    #######################################

    echo ""
    echo "⚙️ Configuring fmt for ${ARCH}..."

    "$CMAKE_BIN" \
        -S "$FMT_DIR" \
        -B "$BUILD_DIR" \
        -G Ninja \
        "${COMMON_FLAGS[@]}" \
        -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR"

    #######################################
    # Build
    #######################################

    echo ""
    echo "🔨 Building fmt for ${ARCH}..."

    "$CMAKE_BIN" \
        --build "$BUILD_DIR" \
        --config Release \
        --parallel "${BUILD_JOBS:-2}"

    #######################################
    # Install
    #######################################

    echo ""
    echo "📦 Installing fmt for ${ARCH}..."

    "$CMAKE_BIN" \
        --install "$BUILD_DIR"

    #######################################
    # Verify architecture library
    #######################################

    local ARCH_LIB="$INSTALL_DIR/lib/libfmt.a"

    if [ ! -f "$ARCH_LIB" ]; then
        echo ""
        echo "❌ fmt library was not created for ${ARCH}:"
        echo "   $ARCH_LIB"
        exit 1
    fi

    echo ""
    echo "✅ fmt ${ARCH} build complete"

    echo "Library:"
    echo "   $ARCH_LIB"

    echo "Architecture:"
    "$LIPO_BIN" -info "$ARCH_LIB"

}

#######################################
# Build x86_64
#######################################

build_arch "$X86_64_ARCH"

#######################################
# Build arm64
#######################################

build_arch "$ARM64_ARCH"

#######################################
# Create universal output
#######################################

echo ""
echo "======================================"
echo " Creating Universal fmt Library"
echo "======================================"

UNIVERSAL="$FMT_DIR/build_universal"

UNIVERSAL_LIB="$UNIVERSAL/lib"
UNIVERSAL_INCLUDE="$UNIVERSAL/include"
UNIVERSAL_CMAKE="$UNIVERSAL/lib/cmake/fmt"
UNIVERSAL_PKGCONFIG="$UNIVERSAL/lib/pkgconfig"

#######################################
# Clean universal output
#######################################

rm -rf "$UNIVERSAL"

#######################################
# Create directories
#######################################

mkdir -p \
    "$UNIVERSAL_LIB" \
    "$UNIVERSAL_INCLUDE" \
    "$UNIVERSAL_CMAKE" \
    "$UNIVERSAL_PKGCONFIG"

#######################################
# Copy headers
#######################################

echo ""
echo "📚 Copying fmt headers..."

cp -R \
    "$FMT_DIR/install_arm64/include/"* \
    "$UNIVERSAL_INCLUDE/"

#######################################
# Architecture-specific libraries
#######################################

LIB_X86_64="$FMT_DIR/install_x86_64/lib/libfmt.a"
LIB_ARM64="$FMT_DIR/install_arm64/lib/libfmt.a"

OUT_LIB="$UNIVERSAL_LIB/libfmt.a"

#######################################
# Verify architecture libraries
#######################################

if [ ! -f "$LIB_X86_64" ]; then

    echo ""
    echo "❌ Missing x86_64 fmt library:"
    echo "   $LIB_X86_64"

    exit 1

fi

if [ ! -f "$LIB_ARM64" ]; then

    echo ""
    echo "❌ Missing arm64 fmt library:"
    echo "   $LIB_ARM64"

    exit 1

fi

#######################################
# Create universal static library
#######################################

echo ""
echo "🔗 Creating universal static fmt library..."

"$LIPO_BIN" -create \
    "$LIB_X86_64" \
    "$LIB_ARM64" \
    -output "$OUT_LIB"

#######################################
# Verify universal library
#######################################

echo ""
echo "🔍 Verifying universal fmt library..."

"$LIPO_BIN" -info "$OUT_LIB"

#######################################
# Create fmtConfig.cmake
#######################################

echo ""
echo "📝 Creating fmt CMake configuration..."

cat > "$UNIVERSAL_CMAKE/fmtConfig.cmake" <<EOF
# fmt CMake configuration
# Universal static fmt library

set(fmt_FOUND TRUE)
set(FMT_FOUND TRUE)

set(fmt_VERSION "${FMT_VERSION}")
set(FMT_VERSION "${FMT_VERSION}")

set(fmt_INCLUDE_DIRS
    "\${CMAKE_CURRENT_LIST_DIR}/../../../include"
)

set(FMT_INCLUDE_DIR
    "\${CMAKE_CURRENT_LIST_DIR}/../../../include"
)

set(fmt_LIBRARY
    "\${CMAKE_CURRENT_LIST_DIR}/../../libfmt.a"
)

set(FMT_LIBRARY
    "\${CMAKE_CURRENT_LIST_DIR}/../../libfmt.a"
)

# Header-only target
if(NOT TARGET fmt::fmt-header-only)

    add_library(
        fmt::fmt-header-only
        INTERFACE
        IMPORTED
    )

    set_target_properties(
        fmt::fmt-header-only
        PROPERTIES
        INTERFACE_INCLUDE_DIRECTORIES
        "\${fmt_INCLUDE_DIRS}"
    )

endif()

# Static fmt target
if(NOT TARGET fmt::fmt)

    add_library(
        fmt::fmt
        STATIC
        IMPORTED
    )

    set_target_properties(
        fmt::fmt
        PROPERTIES

        IMPORTED_LOCATION
        "\${fmt_LIBRARY}"

        INTERFACE_INCLUDE_DIRECTORIES
        "\${fmt_INCLUDE_DIRS}"

    )

endif()

# Compatibility alias
if(NOT TARGET fmt)

    add_library(
        fmt
        ALIAS
        fmt::fmt
    )

endif()

EOF

#######################################
# Create fmtConfigVersion.cmake
#######################################

echo "📝 Creating fmt CMake version configuration..."

cat > "$UNIVERSAL_CMAKE/fmtConfigVersion.cmake" <<EOF

set(PACKAGE_VERSION "${FMT_VERSION}")

if(PACKAGE_VERSION VERSION_LESS PACKAGE_FIND_VERSION)

    set(PACKAGE_VERSION_COMPATIBLE FALSE)

else()

    set(PACKAGE_VERSION_COMPATIBLE TRUE)

    if(PACKAGE_VERSION VERSION_EQUAL PACKAGE_FIND_VERSION)

        set(PACKAGE_VERSION_EXACT TRUE)

    endif()

endif()

EOF

#######################################
# Create lowercase compatibility files
#######################################

cp \
    "$UNIVERSAL_CMAKE/fmtConfig.cmake" \
    "$UNIVERSAL_CMAKE/fmt-config.cmake"

cp \
    "$UNIVERSAL_CMAKE/fmtConfigVersion.cmake" \
    "$UNIVERSAL_CMAKE/fmt-config-version.cmake"

#######################################
# Create pkg-config file
#######################################

echo ""
echo "📝 Creating fmt pkg-config file..."

cat > "$UNIVERSAL_PKGCONFIG/fmt.pc" <<EOF

prefix=${UNIVERSAL}

exec_prefix=\${prefix}

libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: fmt
Description: Fast and safe C++ formatting library
Version: ${FMT_VERSION}

Cflags: -I\${includedir}
Libs: -L\${libdir} -lfmt

EOF

#######################################
# Final verification
#######################################

echo ""
echo "======================================"
echo " VERIFYING fmt UNIVERSAL LIBRARY"
echo "======================================"

#######################################
# Verify library
#######################################

if [ ! -f "$OUT_LIB" ]; then

    echo "❌ Universal fmt library was not created:"
    echo "   $OUT_LIB"

    exit 1

fi

echo ""
echo "📦 Universal static library:"
echo "   $OUT_LIB"

echo ""
echo "🔍 Architecture:"
"$LIPO_BIN" -info "$OUT_LIB"

echo ""
echo "🔍 File type:"
file "$OUT_LIB"

#######################################
# Verify headers
#######################################

if [ ! -d "$UNIVERSAL_INCLUDE/fmt" ]; then

    echo ""
    echo "❌ fmt headers were not installed correctly:"
    echo "   $UNIVERSAL_INCLUDE/fmt"

    exit 1

fi

echo ""
echo "📚 Include directory:"
echo "   $UNIVERSAL_INCLUDE"

#######################################
# Verify CMake package
#######################################

if [ ! -f "$UNIVERSAL_CMAKE/fmtConfig.cmake" ]; then

    echo ""
    echo "❌ fmt CMake package was not created:"
    echo "   $UNIVERSAL_CMAKE/fmtConfig.cmake"

    exit 1

fi

if [ ! -f "$UNIVERSAL_CMAKE/fmtConfigVersion.cmake" ]; then

    echo ""
    echo "❌ fmt CMake version package was not created:"
    echo "   $UNIVERSAL_CMAKE/fmtConfigVersion.cmake"

    exit 1

fi

echo ""
echo "⚙️ CMake package:"
echo "   $UNIVERSAL_CMAKE/fmtConfig.cmake"

#######################################
# Verify pkg-config
#######################################

if [ ! -f "$UNIVERSAL_PKGCONFIG/fmt.pc" ]; then

    echo ""
    echo "❌ fmt pkg-config file was not created:"
    echo "   $UNIVERSAL_PKGCONFIG/fmt.pc"

    exit 1

fi

echo ""
echo "📄 pkg-config:"
echo "   $UNIVERSAL_PKGCONFIG/fmt.pc"

#######################################
# Final output
#######################################

echo ""
echo "======================================"
echo "✅ fmt UNIVERSAL STATIC BUILD COMPLETE"
echo "======================================"

echo ""
echo "fmt version:"
echo "  $FMT_VERSION"

echo ""
echo "Universal prefix:"
echo "  $UNIVERSAL"

echo ""
echo "Static library:"
echo "  $OUT_LIB"

echo ""
echo "CMake package:"
echo "  $UNIVERSAL_CMAKE"

echo ""
echo "Include directory:"
echo "  $UNIVERSAL_INCLUDE"

echo ""
echo "pkg-config:"
echo "  $UNIVERSAL_PKGCONFIG/fmt.pc"

echo ""
echo "Use this in t-SNE-Analysis:"
echo ""
echo "FMT_DIR=\"$UNIVERSAL\""
echo "FMT_CMAKE_DIR=\"$UNIVERSAL_CMAKE\""
echo "FMT_INCLUDE_DIR=\"$UNIVERSAL_INCLUDE\""
echo "FMT_LIB_DIR=\"$UNIVERSAL_LIB\""

echo ""
echo "CMake:"
echo "  -Dfmt_DIR=\"\$FMT_CMAKE_DIR\""

echo ""
echo "======================================"
