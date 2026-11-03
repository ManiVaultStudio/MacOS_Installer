#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIBRARIES_ROOT="${LIBRARIES_ROOT:-$(cd "$SCRIPTS_ROOT/../libraries" && pwd)}"

# libpng version
LIBPNG_VERSION="${LIBPNG_VERSION:-1.6.43}"
LIBPNG_DIR="libpng-${LIBPNG_VERSION}"

echo "🔨 Building libpng ${LIBPNG_VERSION} for arm64..."

# Extract if not already extracted
if [ ! -d "${LIBRARIES_ROOT}/${LIBPNG_DIR}" ]; then
    if [ -f "${LIBRARIES_ROOT}/${LIBPNG_DIR}.tar.gz" ]; then
        cd "${LIBRARIES_ROOT}"
        tar -xzf "${LIBPNG_DIR}.tar.gz"
    else
        echo "❌ ${LIBPNG_DIR}.tar.gz not found in ${LIBRARIES_ROOT}!"
        exit 1
    fi
fi

cd "${LIBRARIES_ROOT}/${LIBPNG_DIR}"

# Clean previous build
make clean 2>/dev/null || true

# Configure for arm64
./configure \
    --prefix="${LIBRARIES_ROOT}/${LIBPNG_DIR}/build_arm64" \
    --host=arm64-apple-darwin \
    --build=arm64-apple-darwin \
    --enable-shared \
    --disable-static \
    CFLAGS="-arch arm64" \
    CXXFLAGS="-arch arm64" \
    LDFLAGS="-arch arm64"

# Build and install
make -j${BUILD_JOBS:-2}
make install

echo ""
echo "🎉 libpng arm64 build completed successfully!"
echo "   📦 Version: ${LIBPNG_VERSION} (arm64 build)"
echo "   📂 Installation directory: ${LIBRARIES_ROOT}/${LIBPNG_DIR}/build_arm64"
echo "   📚 Libraries: ${LIBRARIES_ROOT}/${LIBPNG_DIR}/build_arm64/lib"
echo "   📄 Headers: ${LIBRARIES_ROOT}/${LIBPNG_DIR}/build_arm64/include"
