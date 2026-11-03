#!/bin/bash
set -euo pipefail

echo "======================================"
echo "  Kompute Universal Build Script"
echo "======================================"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIBRARIES_ROOT="${LIBRARIES_ROOT:-$(cd "$SCRIPTS_ROOT/../libraries" && pwd)}"

KOMPUTE_DIR="$LIBRARIES_ROOT/kompute"
KOMPUTE_REPO="https://github.com/KomputeProject/kompute.git"

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
# Ensure Kompute exists
#######################################
mkdir -p "$LIBRARIES_ROOT"

if [ ! -d "$KOMPUTE_DIR/.git" ]; then
    if [ -d "$KOMPUTE_DIR" ] && [ "$(ls -A "$KOMPUTE_DIR")" ]; then
        echo "❌ Kompute path exists but is not a Git checkout: $KOMPUTE_DIR" >&2
        echo "   Move it aside manually, then rerun dependency setup." >&2
        exit 1
    else
        echo "📦 Cloning Kompute..."
        git clone "$KOMPUTE_REPO" "$KOMPUTE_DIR"
    fi
else
    echo "📦 Kompute repo exists → OK"
fi

HDILIB_SRC="$LIBRARIES_ROOT/HDILibLatestVulkan"
HDILIB_REF="${HDILIB_REF:-v2.0.1}"
if [ ! -d "$HDILIB_SRC/.git" ]; then
    echo "📦 HDILib not found — cloning it first (needed for tSNE.patch)..."
    git clone --branch "$HDILIB_REF" --depth 1 https://github.com/biovault/HDILib.git "$HDILIB_SRC"
fi
if [ -d "$HDILIB_SRC/.git" ]; then
    if [ -n "$(git -C "$HDILIB_SRC" status --porcelain)" ] && [ "${ALLOW_DEPENDENCY_SOURCE_RESET:-false}" != "true" ]; then
        echo "❌ HDILib checkout has local changes; refusing to change its pinned version." >&2
        exit 1
    fi
    if [ "${ALLOW_DEPENDENCY_SOURCE_RESET:-false}" = "true" ]; then
        git -C "$HDILIB_SRC" reset --hard
    fi
    git -C "$HDILIB_SRC" fetch origin "$HDILIB_REF"
    if [ "$(git -C "$HDILIB_SRC" rev-parse HEAD)" != "$(git -C "$HDILIB_SRC" rev-parse FETCH_HEAD)" ]; then
        git -C "$HDILIB_SRC" checkout --detach FETCH_HEAD
    fi
fi

#######################################
# Pin to the exact commit + patch that
# HDILib's Vulkan backend requires
# (see libs/HDILibLatestVulkan/vcpkg-overlays/kompute/portfile.cmake)
#######################################
KOMPUTE_REF="${KOMPUTE_REF:-342af81a671099ff590effc30af18551db063917}"
PATCH_FILE="$LIBRARIES_ROOT/HDILibLatestVulkan/vcpkg-overlays/kompute/tSNE.patch"

if [ ! -f "$PATCH_FILE" ]; then
    echo "❌ ERROR: tSNE.patch not found at $PATCH_FILE"
    echo "   Make sure HDILib has been cloned first (run build_hdilibvulkan.sh once, or"
echo "   'git clone --branch $HDILIB_REF https://github.com/biovault/HDILib.git' manually)"
    exit 1
fi

echo "======================================"
echo " Pinning Kompute to $KOMPUTE_REF and applying tSNE.patch"
echo "======================================"
cd "$KOMPUTE_DIR"
git fetch origin "$KOMPUTE_REF" 2>/dev/null || git fetch --all
CURRENT_KOMPUTE_REF="$(git rev-parse HEAD)"
KOMPUTE_TARGET_COMMIT="$(git rev-parse "$KOMPUTE_REF^{commit}")"
PATCH_ALREADY_APPLIED=false
if git apply --reverse --check "$PATCH_FILE" 2>/dev/null; then
    PATCH_ALREADY_APPLIED=true
fi
if [ "$CURRENT_KOMPUTE_REF" != "$KOMPUTE_TARGET_COMMIT" ]; then
    if [ "$PATCH_ALREADY_APPLIED" = "true" ]; then
        echo "❌ Kompute has the tSNE patch applied on an unexpected commit; inspect it and reset manually to $KOMPUTE_REF." >&2
        exit 1
    fi
    if [ -n "$(git status --porcelain)" ] && [ "${ALLOW_DEPENDENCY_SOURCE_RESET:-false}" != "true" ]; then
        echo "❌ Refusing to reset a modified Kompute checkout. Set ALLOW_DEPENDENCY_SOURCE_RESET=true only if its changes are disposable." >&2
        exit 1
    fi
    git checkout --detach "$KOMPUTE_TARGET_COMMIT"
    git reset --hard "$KOMPUTE_TARGET_COMMIT"
    PATCH_ALREADY_APPLIED=false
elif [ "$PATCH_ALREADY_APPLIED" != "true" ] && [ -n "$(git status --porcelain)" ] && [ "${ALLOW_DEPENDENCY_SOURCE_RESET:-false}" != "true" ]; then
    echo "❌ Kompute checkout has local changes; refusing to apply the dependency patch on top of them." >&2
    exit 1
fi

if [ "$PATCH_ALREADY_APPLIED" != "true" ] && git apply --check "$PATCH_FILE" 2>/dev/null; then
    git apply "$PATCH_FILE"
    echo "✅ tSNE.patch applied"
elif [ "$PATCH_ALREADY_APPLIED" != "true" ]; then
    echo "❌ ERROR: tSNE.patch failed to apply cleanly against $KOMPUTE_REF"
    echo "   Try: cd $KOMPUTE_DIR && git apply --reject --whitespace=fix $PATCH_FILE"
    echo "   then inspect any .rej files for manual conflict resolution."
    exit 1
fi
cd "$SCRIPTS_ROOT"

#######################################
# HARD CLEAN (FIX FOR _deps ISSUE)
#######################################
echo "🧹 Cleaning old builds..."

rm -rf "$KOMPUTE_DIR/build_x86_64" || true
rm -rf "$KOMPUTE_DIR/build_arm64" || true
rm -rf "$KOMPUTE_DIR/install_x86_64" || true
rm -rf "$KOMPUTE_DIR/install_arm64" || true
rm -rf "$KOMPUTE_DIR/install_universal" || true

# kill stubborn CMake fetch artifacts
find "$KOMPUTE_DIR" -name "_deps" -type d -exec rm -rf {} + 2>/dev/null || true

#######################################
# Build folders
#######################################
BUILD_X64="$KOMPUTE_DIR/build_x86_64"
BUILD_ARM="$KOMPUTE_DIR/build_arm64"
INSTALL_X64="$KOMPUTE_DIR/install_x86_64"
INSTALL_ARM="$KOMPUTE_DIR/install_arm64"
INSTALL_UNI="$KOMPUTE_DIR/install_universal"

mkdir -p "$INSTALL_UNI"

: "${VULKAN_SDK_VERSION:=1.4.350.0}"
: "${VULKAN_SDK:=$HOME/VulkanSDK/$VULKAN_SDK_VERSION/macOS}"
export VULKAN_SDK
export PATH="$VULKAN_SDK/bin:$PATH"
export DYLD_LIBRARY_PATH="$VULKAN_SDK/lib:${DYLD_LIBRARY_PATH:-}"

#######################################
# CMake flags
#######################################
COMMON_FLAGS=(
    -DCMAKE_BUILD_TYPE=Release
    -DKOMPUTE_OPT_BUILD_TESTS=OFF
    -DKOMPUTE_OPT_BUILD_PYTHON=OFF
    -DKOMPUTE_OPT_BUILD_DOCS=OFF
    -DKOMPUTE_OPT_INSTALL=ON
    -DKOMPUTE_OPT_DISABLE_VULKAN_VERSION_CHECK=ON
    -DVulkan_DIR="$VULKAN_SDK/lib/cmake/vulkan"
)

#######################################
# Build x86_64
#######################################
echo "======================================"
echo " Building x86_64"
echo "======================================"

mkdir -p "$BUILD_X64"
cd "$BUILD_X64"

$CMAKE_BIN .. \
    "${COMMON_FLAGS[@]}" \
    -DCMAKE_OSX_ARCHITECTURES=x86_64 \
    -DCMAKE_INSTALL_PREFIX="$INSTALL_X64"

$CMAKE_BIN --build . --config Release
$CMAKE_BIN --install .

#######################################
# Build arm64
#######################################
echo "======================================"
echo " Building arm64"
echo "======================================"

mkdir -p "$BUILD_ARM"
cd "$BUILD_ARM"

$CMAKE_BIN .. \
    "${COMMON_FLAGS[@]}" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_INSTALL_PREFIX="$INSTALL_ARM"

$CMAKE_BIN --build . --config Release
$CMAKE_BIN --install .

#######################################
# Universal merge (static libs)
#######################################
echo "======================================"
echo " Creating universal package"
echo "======================================"
INSTALL_UNI="$KOMPUTE_DIR/install_universal"
mkdir -p "$INSTALL_UNI/lib/cmake/kompute"
mkdir -p "$INSTALL_UNI/include"

cp -R "$INSTALL_ARM/include/"* "$INSTALL_UNI/include/" 2>/dev/null || true

KOMPUTE_STATIC_LIBS=(libkompute.a libkp_logger.a libfmt.a)

for lib in "${KOMPUTE_STATIC_LIBS[@]}"; do
    arm_lib="$INSTALL_ARM/lib/$lib"
    x64_lib="$INSTALL_X64/lib/$lib"
    if [ -f "$arm_lib" ] && [ -f "$x64_lib" ]; then
        lipo -create "$x64_lib" "$arm_lib" -output "$INSTALL_UNI/lib/$lib"
        echo "✅ Fused $lib -> $(lipo -info "$INSTALL_UNI/lib/$lib")"
    elif [ -f "$arm_lib" ]; then
        echo "⚠️  Missing x86_64 counterpart for $lib; copying arm64-only"
        cp "$arm_lib" "$INSTALL_UNI/lib/$lib"
    elif [ -f "$x64_lib" ]; then
        echo "⚠️  Missing arm64 counterpart for $lib; copying x86_64-only"
        cp "$x64_lib" "$INSTALL_UNI/lib/$lib"
    else
        echo "⚠️  $lib not found in either architecture build, skipping"
    fi
done

echo "🧠 Copying real kompute CMake package files..."
cp -R "$INSTALL_ARM/lib/cmake/kompute/"* "$INSTALL_UNI/lib/cmake/kompute/"
echo "✅ Kompute CMake package copied to $INSTALL_UNI/lib/cmake/kompute/"

#######################################
# EXPORT for HDILib
#######################################
export CMAKE_PREFIX_PATH="$INSTALL_UNI:${CMAKE_PREFIX_PATH:-}"
echo "======================================"
echo "✅ KOMPUTE BUILD COMPLETE"
echo "   Install: $INSTALL_UNI"
echo "======================================"
