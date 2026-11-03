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

    # Find Homebrew to get the latest version
    BREW_LOCATIONS=(
        "/opt/homebrew/bin/brew"
        "/usr/local/bin/brew"
    )

    for location in "${BREW_LOCATIONS[@]}"; do
        if [ -x "$location" ]; then
            BREW_BIN="$location"
            echo "✅ Found Homebrew at: $BREW_BIN"
            break
        fi
    done

    if [ -z "$BREW_BIN" ] && command -v brew >/dev/null 2>&1; then
        BREW_BIN="brew"
        echo "✅ Found Homebrew in PATH"
    fi
}

find_tools

# Get the latest ImageMagick version from GitHub if available
IMAGEMAGICK_VERSION="${IMAGEMAGICK_VERSION:-7.1.1-36}"
echo "📦 Using ImageMagick version: $IMAGEMAGICK_VERSION"

echo "🏗️  Building ImageMagick version: $IMAGEMAGICK_VERSION"

mkdir -p "${LIBRARIES_ROOT}"
cd "${LIBRARIES_ROOT}"

IMAGEMAGICK_DIR="ImageMagick-${IMAGEMAGICK_VERSION}"

# Download ImageMagick if not present
if [ ! -d "$IMAGEMAGICK_DIR" ]; then
    echo "📥 Downloading ImageMagick ${IMAGEMAGICK_VERSION}..."
    curl -L -o "ImageMagick-${IMAGEMAGICK_VERSION}.tar.gz" \
        "https://github.com/ImageMagick/ImageMagick/archive/refs/tags/${IMAGEMAGICK_VERSION}.tar.gz"
    tar -xzf "ImageMagick-${IMAGEMAGICK_VERSION}.tar.gz"
    # Note: GitHub archives extract to a directory named differently
    # mv "ImageMagick-${IMAGEMAGICK_VERSION}" "$IMAGEMAGICK_DIR" || true
    rm "ImageMagick-${IMAGEMAGICK_VERSION}.tar.gz"
fi
cd "$IMAGEMAGICK_DIR"

# Clean previous builds
rm -rf build_arm64 build_universal || true

###################################
# Build arm64
###################################
echo "🔨 Building ImageMagick for arm64..."
mkdir -p build_arm64
cd build_arm64

# Set PKG_CONFIG_PATH to find our custom libpng
export PKG_CONFIG_PATH="${LIBRARIES_ROOT}/libpng-1.6.43/build_arm64/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

# Explicitly set PNG paths as environment variables (not configure arguments)
export PNG_CFLAGS="-I${LIBRARIES_ROOT}/libpng-1.6.43/build_arm64/include/libpng16"
export PNG_LIBS="-L${LIBRARIES_ROOT}/libpng-1.6.43/build_arm64/lib -lpng16 -lz"

../configure \
    --prefix="$PWD/../build_universal" \
    --host=arm64-apple-darwin \
    --build=arm64-apple-darwin \
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
    CFLAGS="-arch arm64" \
    CXXFLAGS="-arch arm64" \
    LDFLAGS="-arch arm64"

make -j${BUILD_JOBS:-2}
make install
cd ..

###################################
# Set install names
###################################
echo "� Setting install names for libraries..."
for lib in build_universal/lib/lib*.dylib; do
    libname=$(basename "$lib")
    install_name_tool -id "@rpath/$libname" "$lib"
done

# Modify pkg-config files
echo "� Modifying pkg-config files..."
for pc in build_universal/lib/pkgconfig/*.pc; do
    # Modify prefix in the .pc file
    sed -i '' "s|prefix=.*|prefix=${LIBRARIES_ROOT}/${IMAGEMAGICK_DIR}/build_universal|" "$pc"
done

# Verify the universal binaries
echo "🔍 Verifying arm64 binaries..."
echo "Libraries:"
for lib in build_universal/lib/lib*.dylib; do
    echo "  $(basename "$lib"): $(lipo -info "$lib")"
done
echo "Executables:"
for exe in build_universal/bin/*; do
    echo "  $(basename "$exe"): $(lipo -info "$exe")"
done

echo ""
echo "🎉 ImageMagick arm64 build completed successfully!"
echo "   📦 Version: $IMAGEMAGICK_VERSION (arm64 build)"
echo "   📂 Installation directory: ${LIBRARIES_ROOT}/${IMAGEMAGICK_DIR}/build_universal"
echo "   📚 Libraries: ${LIBRARIES_ROOT}/${IMAGEMAGICK_DIR}/build_universal/lib"
echo "   📄 Headers: ${LIBRARIES_ROOT}/${IMAGEMAGICK_DIR}/build_universal/include"
echo "   ⚙️  Binaries: ${LIBRARIES_ROOT}/${IMAGEMAGICK_DIR}/build_universal/bin"
echo "   📦 pkg-config: ${LIBRARIES_ROOT}/${IMAGEMAGICK_DIR}/build_universal/lib/pkgconfig"
echo ""
echo "💡 To use this ImageMagick build in your projects:"
echo "   export CMAKE_PREFIX_PATH=\"${LIBRARIES_ROOT}/${IMAGEMAGICK_DIR}/build_universal:\$CMAKE_PREFIX_PATH\""
echo "   export PKG_CONFIG_PATH=\"${LIBRARIES_ROOT}/${IMAGEMAGICK_DIR}/build_universal/lib/pkgconfig:\$PKG_CONFIG_PATH\""
echo "   export PATH=\"${LIBRARIES_ROOT}/${IMAGEMAGICK_DIR}/build_universal/bin:\$PATH\""
