#!/bin/bash
# Remove the obsolete AGL framework from generated CMake link commands.
fix_agl_issue() {
    local build_dir="$1"
    echo "🔧 Checking for AGL linker issues..."

    local link_file
    while IFS= read -r -d '' link_file; do
        if grep -q "AGL" "$link_file"; then
            echo "✅ Fixing AGL reference in: $(basename "$(dirname "$(dirname "$link_file")")")"
            sed -i '' 's/-framework AGL//g; s/AGL//g; s/  / /g; s/ -framework$/ /g; s/^-framework / /g' "$link_file"
        fi
    done < <(find "$build_dir" -name link.txt -type f -print0 2>/dev/null)

    local ninja_file
    while IFS= read -r -d '' ninja_file; do
        if grep -q "AGL" "$ninja_file"; then
            echo "✅ Fixing AGL reference in build.ninja"
            sed -i '' 's/-framework AGL//g; s/AGL//g; s/  / /g; s/ -framework$/ /g' "$ninja_file"
        fi
    done < <(find "$build_dir" -name build.ninja -type f -print0 2>/dev/null)
}
