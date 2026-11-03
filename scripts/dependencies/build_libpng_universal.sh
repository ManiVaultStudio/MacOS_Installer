#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIBRARIES_ROOT="${LIBRARIES_ROOT:-$(cd "$SCRIPTS_ROOT/../libraries" && pwd)}"
LIBRARIES_ROOT="$(cd "$LIBRARIES_ROOT" && pwd -P)"
LIBPNG_VERSION="${LIBPNG_VERSION:-1.6.43}"
SOURCE_DIR="$LIBRARIES_ROOT/libpng-$LIBPNG_VERSION"
BUILD_DIR="$LIBRARIES_ROOT/.build/libpng-$LIBPNG_VERSION-universal"
INSTALL_DIR="$SOURCE_DIR/build_universal"
ZLIB_DIR="$LIBRARIES_ROOT/zlib-${ZLIB_VERSION:-1.3.1}/build_universal"
ARCHS="${DEPENDENCY_ARCHS:-x86_64;arm64}"

if [ ! -f "$SOURCE_DIR/CMakeLists.txt" ]; then
    mkdir -p "$LIBRARIES_ROOT"
    archive="$LIBRARIES_ROOT/libpng-$LIBPNG_VERSION.tar.gz"
    curl --fail --location --retry 3 --output "$archive" \
        "https://github.com/pnggroup/libpng/archive/refs/tags/v$LIBPNG_VERSION.tar.gz"
    tar -xzf "$archive" -C "$LIBRARIES_ROOT"
fi

if [ ! -f "$ZLIB_DIR/lib/libz.a" ]; then
    echo "Universal zlib is required before libpng: $ZLIB_DIR/lib/libz.a" >&2
    exit 1
fi

mkdir -p "$BUILD_DIR"
cmake -S "$SOURCE_DIR" -B "$BUILD_DIR" -G "${DEPENDENCY_CMAKE_GENERATOR:-Ninja}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
    -DCMAKE_OSX_ARCHITECTURES="$ARCHS" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="${DEPENDENCY_MIN_MACOS_VERSION:-12.0}" \
    -DCMAKE_INSTALL_NAME_DIR='@rpath' \
    -DCMAKE_PREFIX_PATH="$ZLIB_DIR" \
    -DZLIB_ROOT="$ZLIB_DIR" \
    -DPNG_SHARED=ON \
    -DPNG_STATIC=OFF \
    -DPNG_TESTS=OFF \
    -DPNG_TOOLS=OFF
cmake --build "$BUILD_DIR" --parallel "${BUILD_JOBS:-2}"
cmake --install "$BUILD_DIR"

png_library="$INSTALL_DIR/lib/libpng16.dylib"
if [ ! -f "$png_library" ]; then
    echo "libpng shared library was not installed at $png_library" >&2
    exit 1
fi
for arch in ${ARCHS//;/ }; do
    lipo -verify_arch "$arch" "$png_library"
done
echo "Universal libpng $LIBPNG_VERSION installed at $INSTALL_DIR"
