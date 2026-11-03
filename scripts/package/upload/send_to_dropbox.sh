#!/bin/bash
set -euo pipefail

# === CONFIG ===
# Usage: ./send_to_dropbox.sh <source_file> <dropbox_folder> [filename]
# If filename is not provided, a timestamped name will be generated.

SOURCE_FILE="$1"
DROPBOX_FOLDER="$2"
FILENAME="$3"

if [ -z "$SOURCE_FILE" ] || [ -z "$DROPBOX_FOLDER" ]; then
  echo "Usage: $0 <source_file> <dropbox_folder> [filename]"
  exit 1
fi

# Generate a unique filename with timestamp if not provided
if [ -z "$FILENAME" ]; then
  BASENAME=$(basename "$SOURCE_FILE" .dmg)
  TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
  FILENAME="${BASENAME}_${TIMESTAMP}.dmg"
fi

# === CHECKS ===
if [ ! -f "$SOURCE_FILE" ]; then
  echo "Error: Source file does not exist: $SOURCE_FILE"
  exit 1
fi

if [ ! -d "$DROPBOX_FOLDER" ]; then
  echo "Error: Dropbox folder does not exist: $DROPBOX_FOLDER"
  exit 1
fi

# === ACTION ===
cp "$SOURCE_FILE" "$DROPBOX_FOLDER/$FILENAME"

# If you want to MOVE instead of COPY, use:
# mv "$SOURCE_FILE" "$DROPBOX_FOLDER/$FILENAME"

echo "File successfully sent to Dropbox as $FILENAME."