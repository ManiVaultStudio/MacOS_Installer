#!/bin/bash

# ManiVault stale-lock recovery for cytosplore-viewer (macOS)

set -u

INSTALLER_DIR="$HOME/PhDProjectCodes/ManiVaultInstallerApp/ManivaultMacInstaller"
LOCK_DIR="$INSTALLER_DIR/scripts/.locks/cytosplore-viewer.pipeline.lock"

printf "\n===============================================\n"
printf " ManiVault - cytosplore-viewer lock recovery\n"
printf "===============================================\n\n"

if [ ! -d "$INSTALLER_DIR" ]; then
    printf "ERROR: ManiVault installer directory was not found:\n%s\n\n" "$INSTALLER_DIR"
    printf "Edit INSTALLER_DIR near the top of this script if your folder is elsewhere.\n"
    read -r -p "Press Enter to close..."
    exit 1
fi

if [ ! -d "$LOCK_DIR" ]; then
    printf "No pipeline lock was found. Nothing needs to be removed.\n"
    printf "You can try the installation in ManiVault Installer now.\n\n"
    read -r -p "Press Enter to close..."
    exit 0
fi

printf "Checking for an active ManiVault build...\n"

# run_project_profile.sh is the build script named in the failure log.
# If any instance is active, keep the lock rather than risk interrupting it.
ACTIVE_RUNS="$(pgrep -fl '[r]un_project_profile\.sh' 2>/dev/null || true)"

if [ -n "$ACTIVE_RUNS" ]; then
    printf "\nSAFETY STOP: A ManiVault build process appears to be running:\n\n"
    printf "%s\n\n" "$ACTIVE_RUNS"
    printf "The lock has NOT been changed. Let that build finish, then run this script again.\n"
    read -r -p "Press Enter to close..."
    exit 2
fi

printf "\nNo run_project_profile.sh process was found.\n"
printf "Lock folder:\n%s\n\n" "$LOCK_DIR"
printf "This will remove only the cytosplore-viewer pipeline lock.\n"
printf "It will NOT delete repositories, source files, dependencies, or build outputs.\n\n"

read -r -p "Remove this apparently stale lock? Type YES to continue: " CONFIRM
if [ "$CONFIRM" != "YES" ]; then
    printf "\nCancelled. The lock was left untouched.\n"
    read -r -p "Press Enter to close..."
    exit 0
fi

# Recheck immediately before removal to reduce the chance of racing a new build.
ACTIVE_RUNS="$(pgrep -fl '[r]un_project_profile\.sh' 2>/dev/null || true)"
if [ -n "$ACTIVE_RUNS" ]; then
    printf "\nSAFETY STOP: A build process appeared during the check:\n\n"
    printf "%s\n\n" "$ACTIVE_RUNS"
    printf "The lock was NOT removed.\n"
    read -r -p "Press Enter to close..."
    exit 2
fi

if rm -rf "$LOCK_DIR"; then
    printf "\nSUCCESS: The cytosplore-viewer lock was removed.\n"
    printf "You can now reopen ManiVault Installer and retry the installation.\n"
else
    printf "\nERROR: Could not remove the lock. Check folder permissions.\n"
    read -r -p "Press Enter to close..."
    exit 1
fi

printf "\n"
read -r -p "Press Enter to close..."
