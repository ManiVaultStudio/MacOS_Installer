#!/bin/bash
set -euo pipefail
# === CONFIG ===
# Usage: ./wait_for_dropbox_file.sh <dropbox_folder> <destination_folder> <filename>
# Waits for <filename> to appear in <dropbox_folder> and copies it to <destination_folder>/<filename>

DROPBOX_FOLDER="$1"
DESTINATION_FOLDER="$2"
FILENAME="$3"
MAX_WAIT_MINUTES=15     # max wait time
CHECK_INTERVAL=30       # seconds between checks

if [ -z "$DROPBOX_FOLDER" ] || [ -z "$DESTINATION_FOLDER" ] || [ -z "$FILENAME" ]; then
  echo "Usage: $0 <dropbox_folder> <destination_folder> <filename>"
  exit 1
fi


# === DERIVED ===
MAX_WAIT_SECONDS=$((MAX_WAIT_MINUTES * 60))
ELAPSED=0
FILE_PATH="$DROPBOX_FOLDER/$FILENAME"

echo "Waiting for $FILENAME in Dropbox (max ${MAX_WAIT_MINUTES} min)..."

# === FUNCTION: check if file is stable ===
is_file_stable() {
  local file="$1"

  if [ ! -f "$file" ]; then
    return 1
  fi

  size1=$(stat -f%z "$file")
  sleep 2
  size2=$(stat -f%z "$file")

  if [ "$size1" -eq "$size2" ]; then
    return 0
  else
    return 1
  fi
}

# === LOOP ===
while [ "$ELAPSED" -lt "$MAX_WAIT_SECONDS" ]; do
  if [ -f "$FILE_PATH" ]; then
    echo "File detected. Checking if fully downloaded..."

    if is_file_stable "$FILE_PATH"; then
      echo "File is stable. Copying..."
      mkdir -p "$DESTINATION_FOLDER"
      cp "$FILE_PATH" "$DESTINATION_FOLDER/$FILENAME"
      echo "File copied successfully to $DESTINATION_FOLDER/$FILENAME."
      exit 0
    else
      echo "File still downloading... waiting."
    fi
  fi

  sleep "$CHECK_INTERVAL"
  ELAPSED=$((ELAPSED + CHECK_INTERVAL))
done

echo "File not found within ${MAX_WAIT_MINUTES} minutes."
exit 1