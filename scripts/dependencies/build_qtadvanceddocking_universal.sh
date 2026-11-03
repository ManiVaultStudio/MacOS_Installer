#!/bin/bash
set -euo pipefail

# Function to find cmake executable
find_cmake() {
    # Check Homebrew locations first (prioritize brew cmake)
    CMAKE_LOCATIONS=(
        "/opt/homebrew/bin/cmake"  # Apple Silicon Homebrew
        "/usr/local/bin/cmake"     # Intel Homebrew
    )

    for location in "${CMAKE_LOCATIONS[@]}"; do
        if [ -x "$location" ]; then
            CMAKE_BIN="$location"
            echo "✅ Found Homebrew CMake at: $CMAKE_BIN"
            return 0
        fi
    done

    # Check if cmake is in PATH (might be homebrew if user has it in PATH)
    if command -v cmake >/dev/null 2>&1; then
        CMAKE_BIN="cmake"
        echo "✅ Found CMake in PATH: $(which cmake)"
        return 0
    fi

    # Fallback to other locations
    OTHER_LOCATIONS=(
        "/Applications/CMake.app/Contents/bin/cmake"
        "/usr/bin/cmake"
    )

    for location in "${OTHER_LOCATIONS[@]}"; do
        if [ -x "$location" ]; then
            CMAKE_BIN="$location"
            echo "✅ Found CMake at: $CMAKE_BIN"
            return 0
        fi
    done

    echo "❌ Error: CMake not found!"
    echo "Please install CMake using Homebrew: brew install cmake"
    echo "If you don't have Homebrew, install it from https://brew.sh/"
    echo "Alternative: Install CMake from https://cmake.org/download/"
    exit 1
}

# Find cmake executable
find_cmake

# ----------- CONFIGURATION -----------
QADS_REPO_URL="https://github.com/githubuser0xFFFF/Qt-Advanced-Docking-System.git"
QADS_TAG="${QADS_TAG:-5.1.1}"
QADS_ZIP_URL="https://github.com/githubuser0xFFFF/Qt-Advanced-Docking-System/archive/refs/tags/v${QADS_TAG}.zip"
LIBNAME="libqtadvanceddocking-qt6"
PKG_NAME="QADS"
PKG_VERSION="$QADS_TAG"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIBRARIES_ROOT="${LIBRARIES_ROOT:-$(cd "$SCRIPTS_ROOT/../libraries" && pwd)}"

QT_INSTALL_DIR="${QT_DIR:-$LIBRARIES_ROOT/qt/${QT_VERSION:-6.10.3}/macos}"
LIBS_DIR="${LIBRARIES_ROOT}"
QADS_DIR="${LIBS_DIR}/qads"

mkdir -p "$LIBS_DIR"
cd "$LIBS_DIR"

# ----------- CHECK IF ALREADY INSTALLED -----------
UNIVERSAL_LIB="${QADS_DIR}/build_universal/lib/${LIBNAME}.dylib"
if [ -f "$UNIVERSAL_LIB" ]; then
    echo "✅ $PKG_NAME already installed"
    lipo -info "$UNIVERSAL_LIB"
    exit 0
fi

# Keep the source version in sync with the catalog, preserving old source trees.
if [ -d "$QADS_DIR" ]; then
    saved_tag=""
    if [ -f "$QADS_DIR/.manivault-source-version" ]; then
        saved_tag="$(cat "$QADS_DIR/.manivault-source-version")"
    elif [ -n "${DEPENDENCY_PREVIOUS_VERSION:-}" ]; then
        saved_tag="$DEPENDENCY_PREVIOUS_VERSION"
    elif [ -d "$QADS_DIR/.git" ]; then
        saved_tag="$(git -C "$QADS_DIR" describe --tags --abbrev=0 2>/dev/null || true)"
        saved_tag="${saved_tag#v}"
    fi
    if [ -n "$saved_tag" ] && [ "$saved_tag" != "$QADS_TAG" ]; then
        previous="$LIBRARIES_ROOT/.previous_sources/qads-$(date +%Y%m%dT%H%M%S)-$$"
        mkdir -p "$(dirname "$previous")"
        mv "$QADS_DIR" "$previous"
        echo "Preserved previous QADS sources in $previous"
    fi
fi

# ----------- CLONE REPO -----------
if [ ! -d "$QADS_DIR" ]; then
    echo "📥 Downloading QADS release zip from $QADS_ZIP_URL"
    tmpzip="/tmp/qads-${QADS_TAG}.zip"
    rm -f "$tmpzip"
    if command -v curl >/dev/null 2>&1; then
        curl -L -o "$tmpzip" "$QADS_ZIP_URL"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$tmpzip" "$QADS_ZIP_URL"
    else
        echo "❌ Neither curl nor wget found to download $QADS_ZIP_URL"; exit 1
    fi
    mkdir -p "$QADS_DIR"
    # Unzip into a temporary directory then move contents to qads dir
    tmpdir=$(mktemp -d)
    unzip -q "$tmpzip" -d "$tmpdir"
    # The archive contains a top-level folder like Qt-Advanced-Docking-System-5.1.1
    extracted_root=$(find "$tmpdir" -maxdepth 1 -type d -name "*Qt-Advanced-Docking-System*" -print -quit)
    if [ -z "$extracted_root" ]; then
        # Try fallback: first subdir
        extracted_root=$(find "$tmpdir" -mindepth 1 -maxdepth 1 -type d -print -quit)
    fi
    if [ -z "$extracted_root" ]; then
        echo "❌ Failed to locate extracted QADS root inside zip"; rm -rf "$tmpdir" "$tmpzip"; exit 1
    fi
    # Move extracted contents into qads directory
    mv "$extracted_root"/* "$QADS_DIR/"
    # Some projects derive version info from git metadata. Since we downloaded a zip
    # (no .git), create a short repo and add a tag matching the release so CMake's
    # git-based version detection succeeds.
    if command -v git >/dev/null 2>&1; then
        (cd "$QADS_DIR" && git init -q || true)
        (cd "$QADS_DIR" && git add -A >/dev/null 2>&1 || true)
        (cd "$QADS_DIR" && git commit -m "imported QADS ${QADS_TAG} release" >/dev/null 2>&1 || true)
        # Create both bare and v-prefixed tags to maximize compatibility
        (cd "$QADS_DIR" && git tag -a "${QADS_TAG}" -m "${QADS_TAG}" >/dev/null 2>&1 || true)
        (cd "$QADS_DIR" && git tag -a "v${QADS_TAG}" -m "v${QADS_TAG}" >/dev/null 2>&1 || true)
    else
        echo "⚠️ git not available; CMake may fail to determine project version from git metadata"
    fi
    rm -rf "$tmpdir" "$tmpzip"
fi
printf '%s\n' "$QADS_TAG" > "$QADS_DIR/.manivault-source-version"
cd "$QADS_DIR"

# ----------- CLEAN OLD BUILDS -----------
rm -rf build_x86_64 build_arm64 build_universal install_x86_64 install_arm64

# ----------- MANUALLY INSPECT AND FIX AGL ISSUE -----------
echo "🔧 Manually inspecting and fixing AGL dependency..."

# Check for AGL references
if grep -q "AGL" src/CMakeLists.txt; then
    echo "Found AGL references in src/CMakeLists.txt"
    # Create a backup
    cp src/CMakeLists.txt src/CMakeLists.txt.backup

    # Remove AGL from target_link_libraries
    sed -i '' 's/AGL//g' src/CMakeLists.txt
    sed -i '' 's/OpenGL::GL AGL/OpenGL::GL/g' src/CMakeLists.txt
    sed -i '' 's/OpenGL::GL  AGL/OpenGL::GL/g' src/CMakeLists.txt

    echo "✅ Removed AGL from src/CMakeLists.txt"
fi

# Check for other AGL references in the repository
if find . -name "*.cmake" -o -name "CMakeLists.txt" | xargs grep -l "AGL"; then
    echo "Found AGL references in other CMake files:"
    find . -name "*.cmake" -o -name "CMakeLists.txt" | xargs grep -l "AGL"

    # Remove AGL from all CMake files
    find . -name "*.cmake" -o -name "CMakeLists.txt" | xargs sed -i '' 's/AGL//g'
    echo "✅ Removed AGL from all CMake files"
fi

# Qt6's platform-native interface is private API, so request GuiPrivate on
# macOS as well as Linux. Share the compatibility helper with the core's CPM copy.
python3 "$SCRIPT_DIR/patch_qt6_private_target.py" "$QADS_DIR/src/CMakeLists.txt"

# ----------- BUILD FUNCTION -----------
build_arch() {
    local arch=$1
    local build_dir="build_$arch"
    local install_dir="install_$arch"
    mkdir -p "$build_dir"
    cd "$build_dir"

    # Use explicit linker flags to avoid AGL
    $CMAKE_BIN .. \
        -DCMAKE_PREFIX_PATH="$QT_INSTALL_DIR" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES=$arch \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="12.0" \
        -DCMAKE_INSTALL_PREFIX=../$install_dir \
        -DCMAKE_EXE_LINKER_FLAGS="-framework OpenGL" \
        -DCMAKE_SHARED_LINKER_FLAGS="-framework OpenGL" \
        -DCMAKE_MODULE_LINKER_FLAGS="-framework OpenGL"

    # First try to build normally
    if ! $CMAKE_BIN --build . --config Release --target qtadvanceddocking-qt6 -j${BUILD_JOBS:-2}; then
        echo "❌ Build failed. Trying to manually fix linker flags..."

        # If build fails, try to manually edit the link.txt file
        local link_file="src/CMakeFiles/qtadvanceddocking-qt6.dir/link.txt"
        if [ -f "$link_file" ]; then
            echo "Manually fixing linker flags in $link_file"
            sed -i '' 's/-framework AGL//g' "$link_file"
            sed -i '' 's/AGL//g' "$link_file"

            # Try building again
            $CMAKE_BIN --build . --config Release --target qtadvanceddocking-qt6 -j${BUILD_JOBS:-2}
        else
            echo "❌ Could not find link.txt file"
            exit 1
        fi
    fi

    $CMAKE_BIN --install .
    cd ..
}

# ----------- BUILD BOTH ARCHS -----------
echo "🔨 Building $PKG_NAME for x86_64..."
build_arch x86_64

echo "🔨 Building $PKG_NAME for arm64..."
build_arch arm64

# ----------- VERIFY BUILDS -----------
X86_LIB="install_x86_64/lib/${LIBNAME}.dylib"
ARM_LIB="install_arm64/lib/${LIBNAME}.dylib"
if [ ! -f "$X86_LIB" ] || [ ! -f "$ARM_LIB" ]; then
    echo "❌ Could not find built $PKG_NAME dylib for both architectures."
    echo "x86_64: $X86_LIB"
    echo "arm64: $ARM_LIB"
    exit 1
fi

# ----------- CREATE UNIVERSAL BINARY -----------
echo "🔗 Creating universal $PKG_NAME binary..."
mkdir -p build_universal/lib
mkdir -p build_universal/include

lipo -create "$X86_LIB" "$ARM_LIB" -output build_universal/lib/${LIBNAME}.dylib

# ----------- COPY HEADERS -----------
cp -r install_arm64/include/* build_universal/include/ 2>/dev/null || true

# ----------- CREATE CMAKE CONFIG -----------
mkdir -p build_universal/lib/cmake/qads
cat > build_universal/lib/cmake/qads/qads-config.cmake << EOL
set(QADS_FOUND TRUE)
set(QADS_INCLUDE_DIRS "\${CMAKE_CURRENT_LIST_DIR}/../../../include")
set(QADS_LIBRARY_DIRS "\${CMAKE_CURRENT_LIST_DIR}/..")
set(QADS_LIBRARIES qtadvanceddocking-qt6)

add_library(qads::qtadvanceddocking-qt6 SHARED IMPORTED)
set_target_properties(qads::qtadvanceddocking-qt6 PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES "\${QADS_INCLUDE_DIRS}"
  IMPORTED_LOCATION "\${QADS_LIBRARY_DIRS}/${LIBNAME}.dylib"
)
EOL

cat > build_universal/lib/cmake/qads/qads-config-version.cmake << EOL
set(PACKAGE_VERSION "${PKG_VERSION}")
if(PACKAGE_VERSION VERSION_LESS PACKAGE_FIND_VERSION)
  set(PACKAGE_VERSION_COMPATIBLE FALSE)
else()
  set(PACKAGE_VERSION_COMPATIBLE TRUE)
  if(PACKAGE_VERSION VERSION_EQUAL PACKAGE_FIND_VERSION)
    set(PACKAGE_VERSION_EXACT TRUE)
  endif()
endif()
EOL

# ----------- CREATE PKG-CONFIG FILE -----------
PKGCONFIG_DIR="build_universal/lib/pkgconfig"
mkdir -p "$PKGCONFIG_DIR"

cat > "$PKGCONFIG_DIR/qads.pc" <<EOL
prefix=${QADS_DIR}/build_universal
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: ${PKG_NAME}
Description: Qt Advanced Docking System
Version: ${PKG_VERSION}
Cflags: -I\${includedir}
Libs: -L\${libdir} -lqtadvanceddocking-qt6
EOL

export PKG_CONFIG_PATH="$PKGCONFIG_DIR:${PKG_CONFIG_PATH:-}"
echo "✅ $PKG_NAME pkg-config file created at $PKGCONFIG_DIR"
echo "PKG_CONFIG_PATH=$PKG_CONFIG_PATH"

# ----------- SYMLINK / INSTALL VERSIONED & UNIVERSAL LIB -----------
VERSIONED_LIB=""
for d in install_arm64/lib install_x86_64/lib; do
    if [ -d "$d" ]; then
        # prefer a filename that contains an extra dot+number after the base name
        candidate=$(ls "$d"/${LIBNAME}*.dylib 2>/dev/null | grep -E "${LIBNAME}\.[0-9]" | head -n1 || true)
        if [ -n "$candidate" ]; then
            VERSIONED_LIB=$(basename "$candidate")
            break
        fi
    fi
done
# fallback: pick any matching dylib from install dirs
if [ -z "$VERSIONED_LIB" ]; then
    for d in install_arm64/lib install_x86_64/lib; do
        if [ -d "$d" ]; then
            candidate=$(ls "$d"/${LIBNAME}*.dylib 2>/dev/null | head -n1 || true)
            if [ -n "$candidate" ]; then
                VERSIONED_LIB=$(basename "$candidate")
                break
            fi
        fi
    done
fi

if [ -n "$VERSIONED_LIB" ]; then
    echo "ℹ️ Found versioned lib: $VERSIONED_LIB — placing into ${QADS_DIR} (keep source and binary together)"
    # Prefer copying the arm64 build as a stable source; fallback to x86_64
    if [ -f "install_arm64/lib/$VERSIONED_LIB" ]; then
        cp "install_arm64/lib/$VERSIONED_LIB" "${QADS_DIR}/$VERSIONED_LIB" 2>/dev/null || true
    elif [ -f "install_x86_64/lib/$VERSIONED_LIB" ]; then
        cp "install_x86_64/lib/$VERSIONED_LIB" "${QADS_DIR}/$VERSIONED_LIB" 2>/dev/null || true
    else
        # If nothing found in installs, try copying from build_universal
        if [ -f "build_universal/lib/$VERSIONED_LIB" ]; then
            cp "build_universal/lib/$VERSIONED_LIB" "${QADS_DIR}/$VERSIONED_LIB" 2>/dev/null || true
        fi
    fi
    # Ensure an unversioned name exists inside the qads folder for consumers that expect it
    ln -sf "${QADS_DIR}/$VERSIONED_LIB" "${QADS_DIR}/${LIBNAME}.dylib"
else
    # No versioned lib found — copy the unversioned universal lib into the qads folder
    if [ -f "build_universal/lib/${LIBNAME}.dylib" ]; then
        cp "build_universal/lib/${LIBNAME}.dylib" "${QADS_DIR}/${LIBNAME}.dylib" 2>/dev/null || true
    fi
fi

# Ensure the universal (lipo-created) unversioned dylib is always available in the
# top-level qads dir. This prevents other scripts from accidentally picking an
# arch-specific copy that may have been placed there from per-arch installs.
if [ -f "build_universal/lib/${LIBNAME}.dylib" ]; then
    cp -f "build_universal/lib/${LIBNAME}.dylib" "${QADS_DIR}/${LIBNAME}.dylib" 2>/dev/null || true
    echo "✅ Installed universal ${LIBNAME}.dylib into ${QADS_DIR}/"
fi
echo "✅ Universal $PKG_NAME built successfully"
lipo -info "build_universal/lib/${LIBNAME}.dylib"

# Ensure any versioned name also points to the same universal binary and that
# both files inside ${QADS_DIR} are the lipo-created (multi-arch) dylib.
if [ -f "build_universal/lib/${LIBNAME}.dylib" ]; then
    # If a versioned library name was detected earlier, overwrite it with the universal copy
    if [ -n "${VERSIONED_LIB:-}" ]; then
        echo "ℹ️ Overwriting versioned lib ${VERSIONED_LIB} with universal binary"
        cp -f "build_universal/lib/${LIBNAME}.dylib" "${QADS_DIR}/${VERSIONED_LIB}" 2>/dev/null || true
        # Set stable install id
        if [ -f "${QADS_DIR}/${VERSIONED_LIB}" ]; then
            install_name_tool -id "@rpath/${VERSIONED_LIB}" "${QADS_DIR}/${VERSIONED_LIB}" 2>/dev/null || true
        fi
    fi

    # Ensure unversioned name also has correct install id
    if [ -f "${QADS_DIR}/${LIBNAME}.dylib" ]; then
        install_name_tool -id "@rpath/${LIBNAME}.dylib" "${QADS_DIR}/${LIBNAME}.dylib" 2>/dev/null || true
    fi

    # Verify the copied files are universal (contain both x86_64 and arm64)
    for check in "${QADS_DIR}/${LIBNAME}.dylib" ${QADS_DIR}/${VERSIONED_LIB:-}; do
        [ -f "$check" ] || continue
        info=$(lipo -info "$check" 2>/dev/null || true)
        echo "ℹ️ lipo info for $check: $info"
        if ! echo "$info" | grep -q 'x86_64' || ! echo "$info" | grep -q 'arm64'; then
            echo "❌ Error: $check is not a universal (fat) binary: $info"
            exit 1
        fi
    done
fi

echo "✅ Universal $PKG_NAME built successfully"
lipo -info "build_universal/lib/${LIBNAME}.dylib"
