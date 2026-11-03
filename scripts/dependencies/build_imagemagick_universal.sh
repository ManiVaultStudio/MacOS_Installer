#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIBRARIES_ROOT="${LIBRARIES_ROOT:-$(cd "$SCRIPTS_ROOT/../libraries" && pwd)}"
LIBRARIES_ROOT="$(cd "$LIBRARIES_ROOT" && pwd -P)"
IMAGEMAGICK_VERSION="${IMAGEMAGICK_VERSION:-7.1.1-36}"
SOURCE_DIR="$LIBRARIES_ROOT/ImageMagick-$IMAGEMAGICK_VERSION"
BUILD_DIR="$LIBRARIES_ROOT/.build/ImageMagick-$IMAGEMAGICK_VERSION-universal"
INSTALL_DIR="$SOURCE_DIR/build_universal"
LIBPNG_DIR="$LIBRARIES_ROOT/libpng-1.6.43/build_universal"
ARCHS="${DEPENDENCY_ARCHS:-x86_64;arm64}"

if [ ! -x "$SOURCE_DIR/configure" ]; then
    mkdir -p "$LIBRARIES_ROOT"
    archive="$LIBRARIES_ROOT/ImageMagick-$IMAGEMAGICK_VERSION.tar.gz"
    curl --fail --location --retry 3 --output "$archive" \
        "https://github.com/ImageMagick/ImageMagick/archive/refs/tags/$IMAGEMAGICK_VERSION.tar.gz"
    tar -xzf "$archive" -C "$LIBRARIES_ROOT"
fi

if [ ! -f "$LIBPNG_DIR/lib/libpng16.dylib" ]; then
    echo "Universal libpng must be installed before ImageMagick: $LIBPNG_DIR" >&2
    exit 1
fi

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
export PKG_CONFIG_PATH="$LIBPNG_DIR/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export CPPFLAGS="-I$LIBPNG_DIR/include/libpng16${CPPFLAGS:+ $CPPFLAGS}"
export LDFLAGS="-L$LIBPNG_DIR/lib -Wl,-rpath,$LIBPNG_DIR/lib${LDFLAGS:+ $LDFLAGS}"
ARCH_FLAGS=""
for arch in ${ARCHS//;/ }; do
    ARCH_FLAGS+=" -arch $arch"
done
ARCH_FLAGS+=" -mmacosx-version-min=${DEPENDENCY_MIN_MACOS_VERSION:-12.0}"
export CFLAGS="${ARCH_FLAGS}${CFLAGS:+ $CFLAGS}"
export CXXFLAGS="$CFLAGS${CXXFLAGS:+ $CXXFLAGS}"
export LDFLAGS="$ARCH_FLAGS $LDFLAGS"

"$SOURCE_DIR/configure" \
    --prefix="$INSTALL_DIR" \
    --enable-shared \
    --disable-static \
    --enable-compat \
    --with-png=yes \
    --without-jpeg \
    --without-tiff \
    --without-jxl \
    --without-openexr \
    --without-heic \
    --without-webp \
    --without-lqr \
    --without-openjp2 \
    --without-lcms \
    --without-libraw \
    --without-x \
    --without-perl
make -j"${BUILD_JOBS:-2}"
make install

shopt -s nullglob
libraries=("$INSTALL_DIR"/lib/lib*.dylib)
if [ "${#libraries[@]}" -eq 0 ]; then
    echo "ImageMagick did not install shared libraries in $INSTALL_DIR/lib" >&2
    exit 1
fi
for library in "${libraries[@]}"; do
    for arch in ${ARCHS//;/ }; do
        lipo -verify_arch "$arch" "$library"
    done
    install_name_tool -id "@rpath/$(basename "$library")" "$library"
done

echo "Universal ImageMagick $IMAGEMAGICK_VERSION installed at $INSTALL_DIR"
