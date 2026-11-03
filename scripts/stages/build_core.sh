#!/bin/bash

set -euo pipefail

: "${CORE_ENABLE_HEADER_PRECHECK:=true}"
: "${CORE_PRECHECK_SCOPE:=changed}"
: "${CORE_PRECHECK_INCLUDE_HEADERS:=true}"
: "${CORE_FAST_BUILD:=false}"
: "${CORE_DISABLE_PCH_FOR_BUILD:=false}"
: "${CORE_USE_CCACHE:=true}"
: "${CORE_PRECHECK_ONLY:=false}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIBRARIES_ROOT="${LIBRARIES_ROOT:-$(cd "$SCRIPTS_ROOT/../libraries" && pwd)}"
source "$SCRIPTS_ROOT/config/dependency_paths.sh"
source "$SCRIPTS_ROOT/lib/cmake_config.sh"
find_build_cmake
find_build_ninja

# --- CUPS Configuration ---
# Check if custom CUPS is available
if [ -d "$CUPS_BUILD_DIR" ]; then
    echo "✅ Using custom-built universal CUPS library"
else
    echo "❌ Universal CUPS library not found!"
    echo "💡 Run './build_cups_universal.sh' first to build the required universal CUPS library"
    echo "🚫 Only the custom-built universal CUPS library is supported"
    exit 1
fi

export PKG_CONFIG_PATH="${LIBRARIES_ROOT}/lz4-${LZ4_VERSION:-1.9.4}/build_universal/lib/pkgconfig:${LIBRARIES_ROOT}/flann/build_universal/lib/pkgconfig:${LIBRARIES_ROOT}/qads/build_universal/lib/pkgconfig:${LIBRARIES_ROOT}/hdf5-${HDF5_VERSION:-1.14.6}/install_universal_static/lib/pkgconfig:${LIBRARIES_ROOT}/zlib-${ZLIB_VERSION:-1.3.1}/build_universal/lib/pkgconfig:${LIBRARIES_ROOT}/cups-${CUPS_VERSION:-2.4.14}/build_universal/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export CMAKE_PREFIX_PATH="${LIBRARIES_ROOT}/lz4-${LZ4_VERSION:-1.9.4}/build_universal:${LIBRARIES_ROOT}/flann/build_universal:${LIBRARIES_ROOT}/qads/build_universal/lib/cmake/qads:${LIBRARIES_ROOT}/hdf5-${HDF5_VERSION:-1.14.6}/install_universal_static/share/cmake/hdf5:${LIBRARIES_ROOT}/zlib-${ZLIB_VERSION:-1.3.1}/build_universal/share/cmake/zlib:${LIBRARIES_ROOT}/cups-${CUPS_VERSION:-2.4.14}/build_universal:${CMAKE_PREFIX_PATH:-}"
QT_DIR="${QT_DIR:-$LIBRARIES_ROOT/qt/${QT_VERSION:-6.10.3}/macos}"
QT_CMAKE_DIR="$QT_DIR/lib/cmake/Qt6"
export PATH="$QT_DIR/bin:$PATH"
export CMAKE_PREFIX_PATH="$QT_CMAKE_DIR:${CMAKE_PREFIX_PATH:-}"

# --- OpenMP Configuration ---
OPENMP_VERSION="${OPENMP_VERSION:-21.1.2}"
OPENMP_BUILD_DIR="$LIBRARIES_ROOT/openmp-${OPENMP_VERSION}/build_universal"

if [ ! -d "$OPENMP_BUILD_DIR" ]; then
    echo "❌ Universal OpenMP library not found!"
    echo "💡 Run './build_openmp_universal_updated.sh' first to build the required universal OpenMP library"
    exit 1
fi

OPENMP_INCLUDE="$OPENMP_BUILD_DIR/include"
OPENMP_LIB="$OPENMP_BUILD_DIR/lib"

source "$SCRIPTS_ROOT/lib/agl_workaround.sh"

run_core_header_precheck() {
    local compile_db="$1"
    local repo_root="$2"
    local jobs="$3"

    repo_root="$(cd "$repo_root" && pwd -P)"

    if [ "$CORE_ENABLE_HEADER_PRECHECK" != "true" ]; then
        echo "Skipping core header precheck (CORE_ENABLE_HEADER_PRECHECK=false)."
        return 0
    fi

    if [ ! -f "$compile_db" ]; then
        echo "Skipping core header precheck: compile_commands.json not found."
        return 0
    fi

    if ! command -v jq >/dev/null 2>&1; then
        echo "Skipping core header precheck: jq not found."
        return 0
    fi

    local raw_list syntax_list changed_abs changed_hdr_abs hdr_list
    raw_list=$(mktemp)
    syntax_list=$(mktemp)
    changed_abs=$(mktemp)
    changed_hdr_abs=$(mktemp)
    hdr_list=$(mktemp)

    jq -r '.[] | select(.file | test("\\.(c|cc|cpp|cxx|mm)$")) | [.file, .command] | @tsv' "$compile_db" > "$raw_list"

    if [ "$CORE_PRECHECK_SCOPE" = "changed" ]; then
        (
            cd "$repo_root"
            git diff --name-only --diff-filter=ACMRTUXB HEAD -- source/core | grep -E '\.(c|cc|cpp|cxx|mm)$' || true
            git ls-files --others --exclude-standard -- source/core | grep -E '\.(c|cc|cpp|cxx|mm)$' || true
        ) | while IFS= read -r rel; do
            [ -n "$rel" ] || continue
            printf "%s/%s\n" "$repo_root" "$rel"
        done | sort -u > "$changed_abs"

        if [ ! -s "$changed_abs" ]; then
            if [ "$CORE_PRECHECK_INCLUDE_HEADERS" != "true" ]; then
                echo "Core header precheck: no changed core source files detected; skipping."
                rm -f "$raw_list" "$syntax_list" "$changed_abs" "$changed_hdr_abs" "$hdr_list"
                return 0
            fi
        fi

        (
            cd "$repo_root"
            git diff --name-only --diff-filter=ACMRTUXB HEAD -- source/core | grep -E '\.(h|hh|hpp|hxx)$' || true
            git ls-files --others --exclude-standard -- source/core | grep -E '\.(h|hh|hpp|hxx)$' || true
        ) | while IFS= read -r rel; do
            [ -n "$rel" ] || continue
            printf "%s/%s\n" "$repo_root" "$rel"
        done | sort -u > "$changed_hdr_abs"
    else
        if [ "$CORE_PRECHECK_INCLUDE_HEADERS" = "true" ]; then
            find "$repo_root/sources/core" -type f \( -name "*.h" -o -name "*.hh" -o -name "*.hpp" -o -name "*.hxx" \) | sort -u > "$changed_hdr_abs"
        fi
    fi

    while IFS=$'\t' read -r file cmd; do
        [ -n "$file" ] || continue
        [ -n "$cmd" ] || continue

        if [ "$CORE_PRECHECK_SCOPE" = "changed" ] && ! grep -Fxq "$file" "$changed_abs"; then
            continue
        fi

        local syntax_cmd
        syntax_cmd="$cmd"
        syntax_cmd="${syntax_cmd/ -c / }"
        syntax_cmd=$(echo "$syntax_cmd" | sed -E 's/ -o [^ ]+//g')
        # Strip forced PCH options so hidden include issues become visible in precheck.
        syntax_cmd=$(echo "$syntax_cmd" | sed -E 's/ -Winvalid-pch( |$)/ /g')
        syntax_cmd=$(echo "$syntax_cmd" | sed -E 's/ -Xarch_[^ ]+ -include[^ ]*cmake_pch_[^ ]*//g')
        syntax_cmd=$(echo "$syntax_cmd" | sed -E 's/ -include[^ ]*cmake_pch_[^ ]*//g')
        syntax_cmd=$(echo "$syntax_cmd" | sed -E 's/[[:space:]]+/ /g')
        syntax_cmd="$syntax_cmd -fsyntax-only"
        printf "%s\n" "$syntax_cmd" >> "$syntax_list"
    done < "$raw_list"

    if [ "$CORE_PRECHECK_INCLUDE_HEADERS" = "true" ] && [ -s "$changed_hdr_abs" ]; then
        local base_cmd header_cmd
        base_cmd=$(awk -F $'\t' '$1 ~ /\.(cc|cpp|cxx)$/ {print $2; exit}' "$raw_list")

        if [ -n "$base_cmd" ]; then
            header_cmd="$base_cmd"
            header_cmd="${header_cmd/ -c / }"
            header_cmd=$(echo "$header_cmd" | sed -E 's/ -o [^ ]+//g')
            header_cmd=$(echo "$header_cmd" | sed -E 's/ [^ ]+\.(c|cc|cpp|cxx|mm)( |$)/ /g')
            header_cmd=$(echo "$header_cmd" | sed -E 's/ -Winvalid-pch( |$)/ /g')
            header_cmd=$(echo "$header_cmd" | sed -E 's/ -Xarch_[^ ]+ -include[^ ]*cmake_pch_[^ ]*//g')
            header_cmd=$(echo "$header_cmd" | sed -E 's/ -include[^ ]*cmake_pch_[^ ]*//g')
            header_cmd=$(echo "$header_cmd" | sed -E 's/[[:space:]]+/ /g')

            while IFS= read -r hdr; do
                [ -n "$hdr" ] || continue
                printf '%s -x c++-header -fsyntax-only "%s"\n' "$header_cmd" "$hdr" >> "$hdr_list"
            done < "$changed_hdr_abs"

            cat "$hdr_list" >> "$syntax_list"
        else
            echo "Core header precheck: no C++ compile command found for header checks; skipping header-only pass."
        fi
    fi

    if [ ! -s "$syntax_list" ]; then
        echo "Core header precheck: no files selected for syntax-only check."
        rm -f "$raw_list" "$syntax_list" "$changed_abs" "$changed_hdr_abs" "$hdr_list"
        return 0
    fi

    local count source_count header_count
    source_count=$(wc -l < "$syntax_list" | tr -d ' ')
    header_count=0
    if [ -s "$hdr_list" ]; then
        header_count=$(wc -l < "$hdr_list" | tr -d ' ')
    fi
    count="$source_count"
    echo "Running core header precheck (syntax-only) on $count compile command(s) including $header_count header self-check(s)..."

    local precheck_script
    precheck_script=$(mktemp)
    {
        echo '#!/bin/bash'
        echo 'set -euo pipefail'
        cat "$syntax_list"
    } > "$precheck_script"
    chmod +x "$precheck_script"

    if ! bash "$precheck_script"; then
        echo "❌ Core header precheck failed. Fix missing includes/errors above before full build."
        rm -f "$raw_list" "$syntax_list" "$changed_abs" "$changed_hdr_abs" "$hdr_list" "$precheck_script"
        exit 1
    fi

    echo "✅ Core header precheck passed."
    rm -f "$raw_list" "$syntax_list" "$changed_abs" "$changed_hdr_abs" "$hdr_list" "$precheck_script"
}

# --- Set up build and install directories ---
BUILD_LABEL="$(echo "$BUILD_TYPE" | tr '[:upper:]' '[:lower:]')"
BUILD_DIR="$BUILD_ROOT/core"
SOURCE_INPUT="${CORE_SOURCE_DIR:-$SOURCE_ROOT/core}"
SOURCE_OVERRIDE_ROOT="$BUILD_ROOT/_source_overrides"
SOURCE_DIR="$SOURCE_OVERRIDE_ROOT/core"
if [ ! -f "$SOURCE_INPUT/CMakeLists.txt" ]; then
    echo "❌ Core source is incomplete: $SOURCE_INPUT/CMakeLists.txt was not found."
    echo "Set CORE_SOURCE_DIR to a clean core checkout for this profile, or restore the missing source files."
    exit 1
fi
echo "Preparing isolated core source copy under $SOURCE_OVERRIDE_ROOT ..."
SOURCE_TIME_STATE="$BUILD_ROOT/.source-times-$(basename "$SOURCE_DIR").json"
python3 "$SCRIPTS_ROOT/lib/source_timestamps.py" begin "$SOURCE_DIR" "$SOURCE_TIME_STATE"
mkdir -p "$SOURCE_DIR"
rsync -a --checksum --delete "$SOURCE_INPUT/" "$SOURCE_DIR/"
# ManiVault's CMakeLists pins this header-only dependency with SOURCE_DIR inside
# the isolated Core copy. Seed that location from the version-checked cache.
# Prepare the pinned bfloat16 dependency at the location expected by Core.
BIOVAULT_BFLOAT16_CACHE="$LIBRARIES_ROOT/biovault_bfloat16-1.0.2"

if [[ ! -s "$BIOVAULT_BFLOAT16_CACHE/biovault_bfloat16.h" ]]; then
    echo "ERROR: Cached biovault_bfloat16 1.0.2 header is missing:"
    echo "  $BIOVAULT_BFLOAT16_CACHE/biovault_bfloat16.h"
    exit 1
fi

# Detect the Core CMake root from the actual biovault_bfloat16
# dependency declaration. Support both known ManiVault source layouts.

BIOVAULT_CORE_ROOT=""

# Layout 1: Core root is the top-level core directory (Master).
if [[ -f "$SOURCE_DIR/CMakeLists.txt" ]] && \
   [[ -f "$SOURCE_DIR/cmake/DownloadDependencies.cmake" ]] && \
   grep -Eq 'SOURCE_DIR[[:space:]]+\$\{MV_ROOT_DIR\}/external/biovault/biovault_bfloat16' \
       "$SOURCE_DIR/cmake/DownloadDependencies.cmake"; then

    BIOVAULT_CORE_ROOT="$SOURCE_DIR"

# Layout 2: Core root is nested under core/ManiVault (500).
elif [[ -f "$SOURCE_DIR/ManiVault/CMakeLists.txt" ]] && \
     grep -Eq 'SOURCE_DIR[[:space:]]+\$\{CMAKE_CURRENT_SOURCE_DIR\}/external/biovault/biovault_bfloat16' \
         "$SOURCE_DIR/ManiVault/CMakeLists.txt"; then

    BIOVAULT_CORE_ROOT="$SOURCE_DIR/ManiVault"
fi

if [[ -z "$BIOVAULT_CORE_ROOT" ]]; then
    echo "ERROR: Could not identify the Core CMake root and biovault_bfloat16 dependency declaration."
    echo "Checked source tree: $SOURCE_DIR"
    exit 1
fi

BIOVAULT_BFLOAT16_SOURCE="$BIOVAULT_CORE_ROOT/external/biovault/biovault_bfloat16"

mkdir -p "$BIOVAULT_BFLOAT16_SOURCE"

rsync -a --exclude='.installer-version' \
    "$BIOVAULT_BFLOAT16_CACHE/" "$BIOVAULT_BFLOAT16_SOURCE/"

if [[ ! -s "$BIOVAULT_BFLOAT16_SOURCE/biovault_bfloat16.h" ]]; then
    echo "ERROR: Failed to prepare biovault_bfloat16 at:"
    echo "  $BIOVAULT_BFLOAT16_SOURCE"
    exit 1
fi

echo "Prepared biovault_bfloat16 for Core at: $BIOVAULT_BFLOAT16_SOURCE"
# Seed Core's configure-time Font Awesome downloads from the shared cache so a
# clean build can reuse the pinned archives without relying on a prior build tree.
FONT_AWESOME_CACHE_DIR="$LIBRARIES_ROOT/font-awesome-cache"
FONT_AWESOME_BUILD_CACHE="$BUILD_DIR/Font-Awesome-Resources"
mkdir -p "$FONT_AWESOME_BUILD_CACHE"
for version in 5.14.0 6.7.2; do
    archive="$FONT_AWESOME_CACHE_DIR/Font-Awesome-$version.tar.gz"
    if [[ -s "$archive" ]]; then
        cp "$archive" "$FONT_AWESOME_BUILD_CACHE/"
    fi
done
if [[ "${PROFILE_NAME:-}" == "manivault-studio-main" ]]; then
    python3 "$SCRIPTS_ROOT/dependencies/patch_manivault_main_qt_includes.py" "$SOURCE_OVERRIDE_ROOT"
fi
echo "Core source checkout remains untouched: $SOURCE_INPUT"
CC_BIN="${CC:-/usr/bin/cc}"
CXX_BIN="${CXX:-/usr/bin/c++}"
mkdir -p "$BUILD_DIR" "$INSTALL_DIR"

find_macos_sdk
prepare_common_cmake_args
load_pinned_fetchcontent_args


# --- Get shared build job count ---
NUM_CORES=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
BUILD_JOBS="${BUILD_JOBS:-$NUM_CORES}"
echo "Using $BUILD_JOBS parallel build jobs (detected $NUM_CORES CPU cores)"


# --- CMake configuration options ---
CMAKE_OPTS=(
  "${CMAKE_COMMON_ARGS[@]}"
  "${CMAKE_FETCHCONTENT_ARGS[@]}"
  -DMV_INSTALL_DIR="$INSTALL_DIR"
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
    -DCMAKE_DISABLE_PRECOMPILE_HEADERS=ON
  -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR"
  -DCMAKE_PREFIX_PATH="$OPENMP_BUILD_DIR;$QT_CMAKE_DIR"
  -DCMAKE_LIBRARY_PATH="$OPENMP_LIB"
  -DCMAKE_INCLUDE_PATH="$OPENMP_INCLUDE"
  -DCMAKE_EXE_LINKER_FLAGS="-L$OPENMP_LIB -lomp"
  -DCMAKE_SHARED_LINKER_FLAGS="-L$OPENMP_LIB -lomp"
  -DCMAKE_MODULE_LINKER_FLAGS="-L$OPENMP_LIB -lomp"
  -DCMAKE_IGNORE_PATH="/opt/homebrew/opt/libomp;/usr/local/opt/libomp;/opt/homebrew;/usr/local"
  -DCMAKE_FIND_USE_CMAKE_SYSTEM_PATH=OFF
  -DOpenMP_ROOT="$OPENMP_BUILD_DIR"
  -DOpenMP_C_FLAGS="-Xpreprocessor -fopenmp -I$OPENMP_INCLUDE"
  -DOpenMP_CXX_FLAGS="-DGL_SILENCE_DEPRECATION -Xpreprocessor -fopenmp -I$OPENMP_INCLUDE"
  -DOpenMP_C_LIB_NAMES="omp"
  -DOpenMP_CXX_LIB_NAMES="omp"
  -DOpenMP_omp_LIBRARY="$OPENMP_LIB/libomp.dylib"
  -DOpenMP_C_LIBRARY="$OPENMP_LIB/libomp.dylib"
  -DOpenMP_CXX_LIBRARY="$OPENMP_LIB/libomp.dylib"
  -DOpenMP_C_INCLUDE_DIR="$OPENMP_INCLUDE"
  -DOpenMP_CXX_INCLUDE_DIR="$OPENMP_INCLUDE"
  -DCUPS_INCLUDE_DIR="$CUPS_BUILD_DIR/include"
  -DCUPS_LIBRARIES="$CUPS_BUILD_DIR/lib/libcups.2.dylib"
  -DOpenGL_GL_PREFERENCE=LEGACY
  -DOPENGL_INCLUDE_DIR="$MACOS_SDK_PATH/System/Library/Frameworks/OpenGL.framework/Headers"
  -DOPENGL_gl_LIBRARY="$MACOS_SDK_PATH/System/Library/Frameworks/OpenGL.framework"
)

CMAKE_OPTS+=( -DCMAKE_UNITY_BUILD=OFF )

# The pinned local Qt Advanced Docking source is an archive without Git tag
# metadata, so provide its declared release version explicitly.
if [[ -d "$LIBRARIES_ROOT/advanced_docking-5.1.1" ]]; then
    CMAKE_OPTS+=( -DADS_VERSION=5.1.1 )
fi

if [ "$CORE_DISABLE_PCH_FOR_BUILD" = "true" ]; then
        CMAKE_OPTS+=(
            -DCMAKE_PCH_INSTANTIATE_TEMPLATES=OFF
            -DSKIP_PCH_FOR_OBJCXX=ON
        )
fi

if [ "$CORE_USE_CCACHE" = "true" ] && command -v ccache >/dev/null 2>&1; then
        CMAKE_OPTS+=(
            -DCMAKE_C_COMPILER_LAUNCHER=ccache
            -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
        )
fi

python3 "$SCRIPTS_ROOT/lib/source_timestamps.py" finish "$SOURCE_DIR" "$SOURCE_TIME_STATE"

# --- Configure CMake ---
echo "Configuring CMake..."
unset OMP_NUM_THREADS 2>/dev/null || true
if ! "$CMAKE_BIN" -S "$SOURCE_DIR" -B "$BUILD_DIR" "${CMAKE_OPTS[@]}"; then
    qads_cmake="$LIBRARIES_ROOT/advanced_docking-5.1.1/src/CMakeLists.txt"
    if [ ! -f "$qads_cmake" ]; then
        qads_cmake="$BUILD_DIR/_deps/advanced_docking-src/src/CMakeLists.txt"
    fi
    if [ ! -f "$qads_cmake" ]; then
        qads_cmake="$BUILD_DIR/core/_deps/advanced_docking-src/src/CMakeLists.txt"
    fi
    if [ ! -f "$qads_cmake" ]; then
        echo "❌ CMake configuration failed and the downloaded Advanced Docking source was not found for the Qt6 compatibility fix." >&2
        exit 1
    fi
    python3 "$SCRIPTS_ROOT/dependencies/patch_qt6_private_target.py" "$qads_cmake"
    echo "Retrying CMake configuration with the Qt6 private GUI target enabled..."
    "$CMAKE_BIN" -S "$SOURCE_DIR" -B "$BUILD_DIR" "${CMAKE_OPTS[@]}"
fi
fix_agl_issue "$BUILD_DIR"

run_core_header_precheck "$BUILD_DIR/compile_commands.json" "$SCRIPTS_ROOT/.." "$BUILD_JOBS"

if [ "$CORE_PRECHECK_ONLY" = "true" ]; then
    echo "CORE_PRECHECK_ONLY=true, skipping full core compile/install."
    exit 0
fi




echo "Detecting MacThemeHelper.mm.o target..."

MAC_THEME_TARGET=""
if command -v ninja >/dev/null 2>&1; then
    MAC_THEME_TARGET=$(
        ninja -C "$BUILD_DIR" -t targets all 2>/dev/null |
        awk -F ': ' '/MacThemeHelper\.mm\.o:/ {
            print $1
            exit
        }' || true
    )
fi


if [ -n "$MAC_THEME_TARGET" ]; then
    echo "Found target: $MAC_THEME_TARGET"

    if ! "$CMAKE_BIN" --build "$BUILD_DIR" \
        --config "$BUILD_TYPE" \
        --target "$MAC_THEME_TARGET" \
        -j "$BUILD_JOBS"; then

        echo "MacThemeHelper target build failed; checking AGL references..."
        fix_agl_issue "$BUILD_DIR"

        echo "Retrying MacThemeHelper target..."
        "$CMAKE_BIN" --build "$BUILD_DIR" \
            --config "$BUILD_TYPE" \
            --target "$MAC_THEME_TARGET" \
            -j "$BUILD_JOBS"
    fi
else
    echo "MacThemeHelper object target not found; continuing with normal build."
fi




echo "Building and installing the project using $BUILD_JOBS jobs..."

BUILD_LOG=$(mktemp "${TMPDIR:-/tmp}/core-build.XXXXXX")

if "$CMAKE_BIN" --build "$BUILD_DIR" \
    --target install --config "$BUILD_TYPE" -j "$BUILD_JOBS" >"$BUILD_LOG" 2>&1; then

    grep -v -i -f "$SCRIPTS_ROOT/config/build_output_filter.txt" \
        "$BUILD_LOG" || true
    rm -f "$BUILD_LOG"
else
    BUILD_STATUS=$?

    cat "$BUILD_LOG"
    echo "Build failed with exit code $BUILD_STATUS."
    echo "Checking for AGL linker issues..."
    fix_agl_issue "$BUILD_DIR"

    echo "Retrying build once..."
    if ! "$CMAKE_BIN" --build "$BUILD_DIR" \
        --target install --config "$BUILD_TYPE" -j "$BUILD_JOBS"; then
        echo "Retry failed. Original build log: $BUILD_LOG"
        exit 1
    fi

    rm -f "$BUILD_LOG"
fi



echo "Build completed successfully!"
