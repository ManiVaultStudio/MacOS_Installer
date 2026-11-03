
#!/bin/bash
set -euo pipefail

# Installs Qt Base and the permitted add-on modules used by these projects.
#
# Excludes GPL-only modules and explicitly excluded modules such as Qt Charts.
# Qt Base already contains Qt Concurrent, Network, SQL, XML, Widgets,
# QML, Quick, Test, PrintSupport, and other essential components.
#
# Qt WebEngine is explicitly required.
#
# IMPORTANT:
# Open-source availability does not automatically establish redistribution
# compliance. Check LGPL and third-party licensing obligations separately.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DEFAULT_LIBRARIES_ROOT="$SCRIPTS_ROOT/../libraries"

LIBRARIES_ROOT="${LIBRARIES_ROOT:-$DEFAULT_LIBRARIES_ROOT}"
mkdir -p "$LIBRARIES_ROOT"
LIBRARIES_ROOT="$(cd "$LIBRARIES_ROOT" && pwd -P)"

QT_VERSION="${QT_VERSION:-6.10.3}"
QT_ARCH="${QT_ARCH:-clang_64}"

QT_DIR="${QT_DIR:-$LIBRARIES_ROOT/qt/$QT_VERSION/macos}"

DEPENDENCY_BUILD_MODE="${DEPENDENCY_BUILD_MODE:-if-missing}"

MODULES_MARKER="$QT_DIR/.manivault-opensource-modules-$QT_VERSION"

AQTVENV="$LIBRARIES_ROOT/.tools/aqtinstall"
AQTBIN="$AQTVENV/bin/aqt"
# One Qt download/extraction at a time limits memory pressure on smaller Macs.
export AQT_CONFIG="${AQT_CONFIG:-$SCRIPTS_ROOT/config/aqt.ini}"

# ---------------------------------------------------------------------------
# Verify the installed Qt kit.
# ---------------------------------------------------------------------------

verify_qt() {
    local root="${1:-$QT_DIR}"
    local missing=0
    local binary
    local arch
    local framework_binary
    local package

    echo "Verifying Qt installation at $root"

    if [ ! -f "$root/lib/cmake/Qt6/Qt6Config.cmake" ]; then
        echo "Qt6 CMake package is missing" >&2
        missing=1
    fi

    if [ ! -x "$root/bin/macdeployqt" ]; then
        echo "macdeployqt is missing" >&2
        missing=1
    fi

    # Essential frameworks, including Qt Concurrent.
    for binary in QtCore QtGui QtWidgets QtConcurrent; do

        framework_binary="$root/lib/$binary.framework/Versions/A/$binary"

        if [ ! -f "$framework_binary" ]; then
            echo "Qt framework binary is missing: $framework_binary" >&2
            missing=1
            continue
        fi

        for arch in x86_64 arm64; do
            if ! lipo -verify_arch "$arch" "$framework_binary" >/dev/null 2>&1; then
                echo "Qt $binary is missing the $arch architecture" >&2
                missing=1
            fi
        done
    done

    # Verify essential CMake components.
    for package in Qt6Concurrent Qt6WebEngineCore Qt6WebEngineWidgets; do

        if [ ! -f "$root/lib/cmake/$package/${package}Config.cmake" ]; then
            echo "Required Qt component is missing: $package" >&2
            missing=1
        fi

    done

    return "$missing"
}

# ---------------------------------------------------------------------------
# Reuse an existing complete installation when possible.
# ---------------------------------------------------------------------------

if [ "$DEPENDENCY_BUILD_MODE" = "if-missing" ] \
    && [ -f "$MODULES_MARKER" ] \
    && verify_qt; then

    echo "Qt $QT_VERSION and its open-source modules are already installed."
    echo "Location: $QT_DIR"
    exit 0
fi

# ---------------------------------------------------------------------------
# Skip mode.
# ---------------------------------------------------------------------------

if [ "$DEPENDENCY_BUILD_MODE" = "skip" ]; then

    if [ ! -f "$MODULES_MARKER" ]; then
        echo "Qt $QT_VERSION open-source modules are missing." >&2
        echo "Run Build dependencies first." >&2
        exit 1
    fi

    if verify_qt; then
        echo "Qt $QT_VERSION is ready at $QT_DIR"
        exit 0
    fi

    exit 1
fi

# ---------------------------------------------------------------------------
# Validate the host.
# ---------------------------------------------------------------------------

if [ "$(uname -s)" != "Darwin" ]; then
    echo "This Qt installation script requires macOS." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Prepare the shared installation directory.
# ---------------------------------------------------------------------------

mkdir -p "$(dirname "$QT_DIR")"

QT_DIR="$(cd "$(dirname "$QT_DIR")" && pwd -P)/$(basename "$QT_DIR")"

# ---------------------------------------------------------------------------
# Prepare the pinned aqtinstall environment.
# ---------------------------------------------------------------------------

if [ ! -x "$AQTVENV/bin/python" ] || ! "$AQTVENV/bin/python" -c "import aqt" >/dev/null 2>&1; then

    echo "Preparing aqtinstall in $AQTVENV"

    mkdir -p "$(dirname "$AQTVENV")"

    python3 -m venv "$AQTVENV"

    "$AQTVENV/bin/python" -m pip install \
        --disable-pip-version-check --retries 5 --timeout 60 \
        'aqtinstall==3.3.0'

fi

# ---------------------------------------------------------------------------
# Excluded modules.
#
# These include GPL-only modules from the Qt 6.10 licensing documentation,
# as well as modules explicitly excluded from this distribution kit.
#
# GPL modules can be redistributed under GPL, but may require your
# application to comply with GPL. They are intentionally excluded here.
# ---------------------------------------------------------------------------

is_excluded_module() {

    case "$1" in

        # GPL-only Qt modules.
        qtcoap)
            return 0
            ;;
        qtgraphs)
            return 0
            ;;
        qtgrpc)
            return 0
            ;;
        qthttpserver)
            return 0
            ;;
        qtlottie)
            return 0
            ;;
        qtmqtt)
            return 0
            ;;
        qtnetworkauth)
            return 0
            ;;
        qtqmlcompiler)
            return 0
            ;;
        qtquick3d)
            return 0
            ;;
        qtquick3dphysics)
            return 0
            ;;
        qtquicktimeline)
            return 0
            ;;
        qtvirtualkeyboard)
            return 0
            ;;
        qtwaylandcompositor)
            return 0
            ;;

        # Explicitly excluded modules.
        qtcharts)
            return 0
            ;;
        qtdatavis3d)
            return 0
            ;;
        qtpurchasing)
            return 0
            ;;
        qtcanvaspainter)
            return 0
            ;;

        *)
            return 1
            ;;

    esac
}

# ---------------------------------------------------------------------------
# Discover every available Qt add-on for this version and architecture.
# ---------------------------------------------------------------------------

echo "Discovering available Qt $QT_VERSION modules..."

retry() {
    local attempt
    for attempt in 1 2 3; do
        if "$@"; then return 0; fi
        echo "Qt download attempt $attempt failed. Retrying..." >&2
        sleep "$((attempt * 2))"
    done
    echo "Qt download failed after three attempts. Check network/proxy access to download.qt.io and retry Build dependencies; completed libraries are reused." >&2
    return 1
}
AVAILABLE_MODULES="$(retry "$AQTVENV/bin/python" -m aqt list-qt mac desktop --modules "$QT_VERSION" "$QT_ARCH")"

QT_MODULES=()
EXCLUDED_MODULES=()

while IFS= read -r module; do

    # Ignore anything that isn't a module identifier.
    [[ "$module" =~ ^qt[a-zA-Z0-9]+$ ]] || continue

    if is_excluded_module "$module"; then
        EXCLUDED_MODULES+=("$module")
        continue
    fi

    # Keep downloads focused on modules used by the projects. Extra permitted
    # modules can be requested explicitly without changing this script.
    case " ${QT_EXTRA_MODULES:-} qtwebengine qtwebchannel qtpositioning qtimageformats qtsvg qtshadertools " in
        *" $module "*) QT_MODULES+=("$module") ;;
    esac

done < <(
    printf '%s\n' "$AVAILABLE_MODULES" |
        tr '[:space:]' '\n'
)

# ---------------------------------------------------------------------------
# Ensure that WebEngine is available.
# ---------------------------------------------------------------------------

if [[ ! " ${QT_MODULES[*]} " =~ [[:space:]]qtwebengine[[:space:]] ]]; then

    echo "ERROR: Qt WebEngine is not available for Qt $QT_VERSION $QT_ARCH." >&2
    echo "Cannot provision the requested Qt installation." >&2
    exit 1

fi

# ---------------------------------------------------------------------------
# Display the selected modules.
# ---------------------------------------------------------------------------

echo
echo "============================================================"
echo "Qt $QT_VERSION"
echo "Architecture: $QT_ARCH"
echo "Installation: $QT_DIR"
echo "============================================================"

echo
echo "Installing required permitted open-source modules:"

printf '  %s\n' "${QT_MODULES[@]}"

echo
echo "Excluded modules:"

if [ "${#EXCLUDED_MODULES[@]}" -gt 0 ]; then
    printf '  %s\n' "${EXCLUDED_MODULES[@]}"
else
    echo "  None"
fi

echo
echo "============================================================"

# ---------------------------------------------------------------------------
# Install Qt Base and all selected add-on modules.
#
# Qt Concurrent is included in Qt Base.
# Qt WebEngine is explicitly included in QT_MODULES.
# ---------------------------------------------------------------------------

echo
echo "Installing universal Qt $QT_VERSION..."

retry "$AQTVENV/bin/python" -m aqt install-qt \
    mac \
    desktop \
    "$QT_VERSION" \
    "$QT_ARCH" \
    --outputdir "$(dirname "$(dirname "$QT_DIR")")" \
    --modules "${QT_MODULES[@]}"

# ---------------------------------------------------------------------------
# Verify the installation.
# ---------------------------------------------------------------------------

echo
echo "Verifying Qt installation..."

verify_qt

# ---------------------------------------------------------------------------
# Save installation metadata.
# ---------------------------------------------------------------------------

{
    echo "Qt version: $QT_VERSION"
    echo "Architecture: $QT_ARCH"
    echo "Installation: $QT_DIR"
    echo
    echo "Installed add-on modules:"
    printf '%s\n' "${QT_MODULES[@]}"
    echo
    echo "Excluded modules:"
    printf '%s\n' "${EXCLUDED_MODULES[@]}"
} > "$MODULES_MARKER"

# ---------------------------------------------------------------------------
# Complete.
# ---------------------------------------------------------------------------

echo
echo "============================================================"
echo "Qt $QT_VERSION installation completed successfully."
echo "============================================================"

echo "Qt directory: $QT_DIR"
echo "Qt Concurrent: available"
echo "Qt WebEngine: available"
echo "Universal architectures: x86_64, arm64"
echo "Open-source add-on modules: ${#QT_MODULES[@]}"

echo
echo "Ready for project builds."
