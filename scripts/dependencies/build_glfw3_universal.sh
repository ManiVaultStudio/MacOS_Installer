#!/bin/bash
set -euo pipefail

echo "======================================"
echo "  GLFW3 Universal Build Script.   "
echo "======================================"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIBRARIES_ROOT="${LIBRARIES_ROOT:-$(cd "$SCRIPTS_ROOT/../libraries" && pwd)}"

GLFW_VERSION="${GLFW_VERSION:-3.4}"
GLFW_COMMIT="${GLFW_COMMIT-7b6aead9fb88b3623e3b3725ebb42670cbe4c579}"
GLFW_DIR="$LIBRARIES_ROOT/glfw-${GLFW_VERSION}"
GLFW_REPO="https://github.com/glfw/glfw.git"

#######################################
# Find CMake
#######################################
find_cmake() {
    if command -v cmake >/dev/null 2>&1; then
        CMAKE_BIN="cmake"
        echo "✅ Found CMake: $(which cmake)"
        return
    fi

    for p in /opt/homebrew/bin/cmake /usr/local/bin/cmake /usr/bin/cmake; do
        if [ -x "$p" ]; then
            CMAKE_BIN="$p"
            echo "✅ Found CMake: $CMAKE_BIN"
            return
        fi
    done

    echo "❌ CMake not found"
    exit 1
}

find_cmake

#######################################
# Clone / update GLFW
#######################################
mkdir -p "$LIBRARIES_ROOT"

if [ ! -d "$GLFW_DIR/.git" ]; then
    echo "📦 Cloning GLFW..."
    if [ -d "$GLFW_DIR" ] && [ "$(ls -A "$GLFW_DIR")" ]; then
        echo "❌ GLFW path exists but is not a Git checkout: $GLFW_DIR" >&2
        exit 1
    fi
    git clone --branch "$GLFW_VERSION" --depth 1 "$GLFW_REPO" "$GLFW_DIR"
else
    if [ -n "$(git -C "$GLFW_DIR" status --porcelain)" ] && [ "${ALLOW_DEPENDENCY_SOURCE_RESET:-false}" != "true" ]; then
        echo "❌ GLFW checkout has local changes; refusing to switch to $GLFW_VERSION." >&2
        exit 1
    fi
    if [ "${ALLOW_DEPENDENCY_SOURCE_RESET:-false}" = "true" ]; then
        git -C "$GLFW_DIR" reset --hard
    fi
fi
git -C "$GLFW_DIR" fetch origin "refs/tags/$GLFW_VERSION"
if [ -n "$GLFW_COMMIT" ] && [ "$(git -C "$GLFW_DIR" rev-parse FETCH_HEAD^{commit})" != "$GLFW_COMMIT" ]; then
    echo "❌ GLFW tag $GLFW_VERSION no longer resolves to the pinned commit $GLFW_COMMIT." >&2
    exit 1
fi
git -C "$GLFW_DIR" checkout --detach "${GLFW_COMMIT:-FETCH_HEAD}"

cd "$GLFW_DIR"

#######################################
# HARD CLEAN (important)
#######################################
echo "🧹 Cleaning old builds..."
rm -rf build_x86_64 build_arm64 build_universal install_x86_64 install_arm64

#######################################
# Absolute install dirs (FIX)
#######################################
INSTALL_BASE="$GLFW_DIR/install"
INSTALL_X64="$INSTALL_BASE/x86_64"
INSTALL_ARM="$INSTALL_BASE/arm64"

#######################################
# CMake flags (STATIC)
#######################################
COMMON_FLAGS=(
    -DCMAKE_BUILD_TYPE=Release
    -DGLFW_BUILD_EXAMPLES=OFF
    -DGLFW_BUILD_TESTS=OFF
    -DGLFW_BUILD_DOCS=OFF
    -DGLFW_INSTALL=ON
    -DBUILD_SHARED_LIBS=OFF
)

#######################################
# Build function (FIXED)
#######################################
build_arch() {
    ARCH=$1
    BUILD_DIR="$GLFW_DIR/build_$ARCH"
    INSTALL_DIR="$INSTALL_BASE/$ARCH"

    echo "======================================"
    echo " Building $ARCH"
    echo "======================================"

    mkdir -p "$BUILD_DIR"

    cd "$BUILD_DIR"

    $CMAKE_BIN .. \
        "${COMMON_FLAGS[@]}" \
        -DCMAKE_OSX_ARCHITECTURES=$ARCH \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR"

    $CMAKE_BIN --build . --config Release
    $CMAKE_BIN --install .

    cd "$GLFW_DIR"
}

#######################################
# Build both architectures
#######################################
build_arch "x86_64"
build_arch "arm64"

#######################################
# Universal output
#######################################
echo "======================================"
echo " Creating universal GLFW3"
echo "======================================"

UNIVERSAL="$GLFW_DIR/build_universal"

mkdir -p "$UNIVERSAL/lib"
mkdir -p "$UNIVERSAL/include"

#######################################
# Copy headers
#######################################
cp -R "$INSTALL_ARM/include/"* "$UNIVERSAL/include/"

#######################################
# Merge static library
#######################################
LIB_X64="$INSTALL_X64/lib/libglfw3.a"
LIB_ARM="$INSTALL_ARM/lib/libglfw3.a"
OUT_LIB="$UNIVERSAL/lib/libglfw3.a"

if [ ! -f "$LIB_X64" ] || [ ! -f "$LIB_ARM" ]; then
    echo "❌ Missing libraries:"
    echo "x86_64: $LIB_X64"
    echo "arm64 : $LIB_ARM"
    exit 1
fi

echo "🔗 Merging universal static library..."
lipo -create "$LIB_X64" "$LIB_ARM" -output "$OUT_LIB"

#######################################
# CMake config (clean)
#######################################
mkdir -p "$UNIVERSAL/lib/cmake/glfw3"

cat > "$UNIVERSAL/lib/cmake/glfw3/glfw3Config.cmake" <<EOL
set(GLFW3_FOUND TRUE)
set(GLFW3_VERSION ${GLFW_VERSION})

set(GLFW3_INCLUDE_DIR "\${CMAKE_CURRENT_LIST_DIR}/../../../include")
set(GLFW3_LIB "\${CMAKE_CURRENT_LIST_DIR}/../libglfw3.a")

add_library(glfw3 STATIC IMPORTED GLOBAL)

set_target_properties(glfw3 PROPERTIES
    IMPORTED_LOCATION "\${GLFW3_LIB}"
    INTERFACE_INCLUDE_DIRECTORIES "\${GLFW3_INCLUDE_DIR}"
)

target_link_libraries(glfw3 INTERFACE
    "-framework Cocoa"
    "-framework IOKit"
    "-framework CoreVideo"
    "-framework OpenGL"
)
EOL

cat > "$UNIVERSAL/lib/cmake/glfw3/glfw3ConfigVersion.cmake" <<EOL
set(PACKAGE_VERSION "${GLFW_VERSION}")

if(PACKAGE_VERSION VERSION_LESS PACKAGE_FIND_VERSION)
    set(PACKAGE_VERSION_COMPATIBLE FALSE)
else()
    set(PACKAGE_VERSION_COMPATIBLE TRUE)
    if(PACKAGE_VERSION VERSION_EQUAL PACKAGE_FIND_VERSION)
        set(PACKAGE_VERSION_EXACT TRUE)
    endif()
endif()
EOL

#######################################
# pkg-config
#######################################
mkdir -p "$UNIVERSAL/lib/pkgconfig"

cat > "$UNIVERSAL/lib/pkgconfig/glfw3.pc" <<EOL
prefix=${UNIVERSAL}
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: GLFW
Description: Multi-platform OpenGL/Vulkan window library
Version: ${GLFW_VERSION}

Cflags: -I\${includedir}
Libs: -L\${libdir} -lglfw3 -framework Cocoa -framework IOKit -framework CoreVideo -framework OpenGL
EOL

export PKG_CONFIG_PATH="$UNIVERSAL/lib/pkgconfig:\$PKG_CONFIG_PATH"

#######################################
# Verify
#######################################
echo "======================================"
echo "🔎 VERIFY"
echo "======================================"

lipo -info "$OUT_LIB"

echo "======================================"
echo "✅ GLFW3 UNIVERSAL BUILD COMPLETE"
echo "📦 Output: $UNIVERSAL"
echo "======================================"
