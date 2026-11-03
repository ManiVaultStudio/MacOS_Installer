#!/bin/bash
set -euo pipefail

echo "Cleaning macOS user-level temporary and cache files..."

rm -rf ~/Library/Caches/* 2>/dev/null
rm -rf ~/Library/Logs/* 2>/dev/null
rm -rf ~/Library/Saved\ Application\ State/* 2>/dev/null
rm -rf ~/.Trash/* 2>/dev/null

rm -rf ~/Library/Containers/com.apple.mail/Data/Library/Mail\ Downloads/* 2>/dev/null
rm -rf ~/Library/Caches/com.apple.Safari/* 2>/dev/null
rm -rf ~/Library/Safari/History.db 2>/dev/null

rm -rf ~/Library/Developer/Xcode/DerivedData/* 2>/dev/null
rm -rf ~/Library/Developer/CoreSimulator/Caches/* 2>/dev/null
rm -rf ~/Library/Application\ Support/MobileSync/Backup/* 2>/dev/null

rm -rf ~/Library/Logs/DiagnosticReports/* 2>/dev/null
rm -rf ~/Library/Caches/com.apple.QuickLook.thumbnailcache/* 2>/dev/null

echo "✅ User-level cleanup complete! You may want to reboot."

#rm -rf /var/folders/7d/l4lpqvwn69l43g_mpml8nznw0000gn/T/*
#/var/folders/
