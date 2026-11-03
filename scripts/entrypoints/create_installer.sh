
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_ROOT="$SCRIPT_DIR"
export SCRIPTS_ROOT

PROFILE_INPUT="${1:-default}"
if [ -f "$PROFILE_INPUT" ]; then
    PROFILE_FILE="$PROFILE_INPUT"
else
    PROFILE_FILE="$SCRIPT_DIR/project_profiles/${PROFILE_INPUT}.env"
fi

if [ ! -f "$PROFILE_FILE" ]; then
    echo "Profile not found: $PROFILE_FILE"
    exit 1
fi

# shellcheck disable=SC1090
source "$PROFILE_FILE"

: "${PROFILE_NAME:=$(basename "$PROFILE_FILE" .env)}"
: "${APP_VERSION:=1.0.0}"
: "${ARCHS:=x86_64;arm64}"
: "${MIN_MACOS_VERSION:=12.0}"
: "${DEPENDENCY_MANIFEST_FILE:=$SCRIPT_DIR/../installer_database/dependencies.json}"
: "${MIN_CORE_VERSION_MAJOR:=1}"
: "${MIN_CORE_VERSION_MINOR:=4}"
: "${MIN_CORE_VERSION_PATCH:=0}"
: "${DATAPLUGIN_REPOS:={}}"
: "${PLUGIN_REPOS:={}}"
: "${QT_VERSION:=6.10.3}"
: "${QT_DIR:=$SCRIPTS_ROOT/../libraries/qt/$QT_VERSION/macos}"
: "${VULKAN_SDK_VERSION:=1.4.350.0}"
: "${VULKAN_SDK:=$HOME/VulkanSDK/$VULKAN_SDK_VERSION/macOS}"
export SCRIPTS_ROOT PROFILE_NAME APP_VERSION ARCHS MIN_MACOS_VERSION
export DEPENDENCY_MANIFEST_FILE
export MIN_CORE_VERSION_MAJOR MIN_CORE_VERSION_MINOR MIN_CORE_VERSION_PATCH
export DATAPLUGIN_REPOS PLUGIN_REPOS
export QT_VERSION QT_DIR VULKAN_SDK_VERSION VULKAN_SDK
DRY_RUN=true python3 "$SCRIPT_DIR/profiles/validate_profile.py"

: "${PROFILE_NAME:=default}"
: "${PROJECT_FOLDER_NAME:=$PROFILE_NAME}"
: "${BUILDFILES_ROOT:=$SCRIPT_DIR/../builds}"
: "${INSTALL_DIR:=$BUILDFILES_ROOT/$PROFILE_NAME/install/$PROJECT_FOLDER_NAME}"
: "${INSTALL_COPY_DIR:=$BUILDFILES_ROOT/$PROFILE_NAME/installCopy/$PROJECT_FOLDER_NAME}"
: "${INSTALL_DMG_TEMP_DIR:=$BUILDFILES_ROOT/$PROFILE_NAME/dmg_temp_content/$PROJECT_FOLDER_NAME}"
: "${OUTPUT_DIR:=$SCRIPT_DIR/../application}"
: "${APP_NAME:=ManiVault Studio.app}"
: "${VOLUME_NAME:=Cytosplore Viewer}"
: "${APP_VERSION:=1.0.0}"
: "${CUSTOMIZATION_FOLDER_PRESENT:=true}"
 
: "${MIN_CORE_VERSION_MAJOR:=1}"
: "${MIN_CORE_VERSION_MINOR:=4}"
: "${MIN_CORE_VERSION_PATCH:=0}"
: "${MIN_CORE_VERSION_SUFFIX:=}"
: "${INSTALLER_MATERIALS_ROOT:=$SCRIPT_DIR/../installer_materials/projects/${PROFILE_NAME:-default}}"
: "${INSTALLER_MATERIALS:=$INSTALLER_MATERIALS_ROOT}"
: "${APP_ICON_FILE:=$INSTALLER_MATERIALS/appimage-cytosplore.icns}"
: "${DMG_BACKGROUND_IMAGE:=$INSTALLER_MATERIALS/dmg-background-cytosplore.png}"
 
: "${FOLDER_ICONS_DIR:=$INSTALLER_MATERIALS/folderIcons-cytosplore}"
: "${APPLY_FOLDER_ICONS:=true}"
: "${LICENSE_DIR:=$SCRIPT_DIR/../installer_materials/common/license}"
: "${ASSETS_DIR:=$SCRIPT_DIR/../installer_materials/common/assets}"
: "${EXCLUDED_PLUGINS:=}"

# Only set defaults if variable is unset (not if empty)
if [ "${PROJECTS_SOURCE_FILE+set}" != "set" ]; then
    PROJECTS_SOURCE_FILE="$SCRIPT_DIR/../installer_materials/projects/${PROFILE_NAME:-default}/projects.json"
fi
if [ "${APP_CONFIG_SOURCE_FILE+set}" != "set" ]; then
    APP_CONFIG_SOURCE_FILE="$SCRIPT_DIR/../installer_materials/projects/${PROFILE_NAME:-default}/app.json"
fi
if [ "${MIN_CORE_VERSION_MAJOR+set}" != "set" ]; then
    MIN_CORE_VERSION_MAJOR=1
fi
if [ "${MIN_CORE_VERSION_MINOR+set}" != "set" ]; then
    MIN_CORE_VERSION_MINOR=4
fi
if [ "${MIN_CORE_VERSION_PATCH+set}" != "set" ]; then
    MIN_CORE_VERSION_PATCH=0
fi
if [ "${MIN_CORE_VERSION_SUFFIX+set}" != "set" ]; then
    MIN_CORE_VERSION_SUFFIX=""
fi
if [ "${INSTALLER_MATERIALS_ROOT+set}" != "set" ]; then
    INSTALLER_MATERIALS_ROOT="$SCRIPT_DIR/../installer_materials/projects/${PROFILE_NAME:-default}"
fi
if [ "${INSTALLER_MATERIALS+set}" != "set" ]; then
    INSTALLER_MATERIALS="$INSTALLER_MATERIALS_ROOT"
fi
if [ "${APP_ICON_FILE+set}" != "set" ]; then
    APP_ICON_FILE="$INSTALLER_MATERIALS/appimage-cytosplore.icns"
fi
if [ "${DMG_BACKGROUND_IMAGE+set}" != "set" ]; then
    DMG_BACKGROUND_IMAGE="$INSTALLER_MATERIALS/dmg-background-cytosplore.png"
fi
if [ "${FOLDER_ICONS_DIR+set}" != "set" ]; then
    FOLDER_ICONS_DIR="$INSTALLER_MATERIALS/folderIcons-cytosplore"
fi
if [ "${APPLY_FOLDER_ICONS+set}" != "set" ]; then
    APPLY_FOLDER_ICONS=true
fi
if [ "${LICENSE_DIR+set}" != "set" ]; then
    LICENSE_DIR="$INSTALLER_MATERIALS/license"
fi
if [ "${ASSETS_DIR+set}" != "set" ]; then
    ASSETS_DIR="$INSTALLER_MATERIALS/assets"
fi
if [ "${EXCLUDED_PLUGINS+set}" != "set" ]; then
    EXCLUDED_PLUGINS=""
fi

export INSTALL_DIR INSTALL_COPY_DIR INSTALL_DMG_TEMP_DIR OUTPUT_DIR
export APP_NAME VOLUME_NAME APP_VERSION CUSTOMIZATION_FOLDER_PRESENT
export PROJECTS_SOURCE_FILE APP_CONFIG_SOURCE_FILE
export MIN_CORE_VERSION_MAJOR MIN_CORE_VERSION_MINOR MIN_CORE_VERSION_PATCH MIN_CORE_VERSION_SUFFIX
export INSTALLER_MATERIALS_ROOT INSTALLER_MATERIALS APP_ICON_FILE DMG_BACKGROUND_IMAGE
export FOLDER_ICONS_DIR APPLY_FOLDER_ICONS LICENSE_DIR ASSETS_DIR EXCLUDED_PLUGINS

exec "$SCRIPT_DIR/package/final_create_dmgvulkan.sh"
