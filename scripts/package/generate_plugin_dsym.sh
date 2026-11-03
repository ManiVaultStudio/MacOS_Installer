#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

INSTALL_DIR="${INSTALL_DIR:-}"

if [ -z "$INSTALL_DIR" ]; then
    echo "ERROR: INSTALL_DIR not set"
    exit 1
fi

PLUGIN_DIR="$INSTALL_DIR/Plugins"
DEBUG_SYMBOL_DIR="$INSTALL_DIR/../debug_symbols"

if [ ! -d "$PLUGIN_DIR" ]; then
    echo "No Plugins directory found:"
    echo "$PLUGIN_DIR"
    exit 0
fi

mkdir -p "$DEBUG_SYMBOL_DIR"

echo "Generating dSYM files"
echo "Plugin directory:"
echo "$PLUGIN_DIR"

echo "Debug symbols output:"
echo "$DEBUG_SYMBOL_DIR"

find "$PLUGIN_DIR" \
    -type d -name "*.dSYM" -prune -o \
    \( -name "*.dylib" -o -name "*.so" \) \
    -type f -print |
while read -r LIB; do

    echo "----------------------------------------"
    echo "Processing:"
    echo "$LIB"

    #
    # Verify this is actually a Mach-O binary
    #
    if ! file "$LIB" | grep -q "Mach-O"; then
        echo "Skipping (not Mach-O):"
        echo "$LIB"
        continue
    fi

    #
    # Preserve relative path inside debug_symbols
    #
    REL_PATH="${LIB#$PLUGIN_DIR/}"

    DSYM_DIR="$DEBUG_SYMBOL_DIR/${REL_PATH}.dSYM"

    mkdir -p "$(dirname "$DSYM_DIR")"

    if [ -d "$DSYM_DIR" ]; then
        echo "Already exists:"
        echo "$DSYM_DIR"
        continue
    fi

    echo "Creating:"
    echo "$DSYM_DIR"

    #
    # Generate dSYM
    #
    if dsymutil "$LIB" -o "$DSYM_DIR"; then
        echo "Created:"
        echo "$DSYM_DIR"
    else
        echo "WARNING: dsymutil failed for:"
        echo "$LIB"
    fi

done

echo "----------------------------------------"
echo "dSYM generation completed."
echo "Symbols stored in:"
echo "$DEBUG_SYMBOL_DIR"