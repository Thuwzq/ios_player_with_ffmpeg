#!/bin/bash

#
#  update_ffmpeg.sh
#  ios_player_with_ffmpeg
#
#  Created by liebentwei on 2026/1/20.
#

# Source directory
SOURCE_DIR="/Users/liebentwei/Code/FFmpeg_with_tquic/build/ios/thin/arm64"
# Target directory (script location)
TARGET_DIR="$(cd "$(dirname "$0")" && pwd)"

# Check if source directory exists
if [ ! -d "$SOURCE_DIR" ]; then
    echo "Error: Source directory does not exist: $SOURCE_DIR"
    exit 1
fi

# Only copy these two folders
FOLDERS=("lib" "include")

echo "Starting to copy lib and include from $SOURCE_DIR to $TARGET_DIR"

# Clean up existing folders first
echo "Cleaning up existing folders..."
for folder_name in "${FOLDERS[@]}"; do
    target_path="$TARGET_DIR/$folder_name"
    if [ -d "$target_path" ]; then
        echo "  Removing existing directory: $folder_name"
        rm -rf "$target_path"
    fi
done

# Copy folders
for folder_name in "${FOLDERS[@]}"; do
    source_path="$SOURCE_DIR/$folder_name"
    target_path="$TARGET_DIR/$folder_name"
    
    # Check if source folder exists
    if [ ! -d "$source_path" ]; then
        echo "  ✗ $folder_name not found in source directory, skipping"
        continue
    fi
    
    echo "Copying folder: $folder_name"
    
    # Copy folder
    cp -R "$source_path" "$target_path"
    
    if [ $? -eq 0 ]; then
        echo "  ✓ $folder_name copied successfully"
    else
        echo "  ✗ $folder_name copy failed"
    fi
done

echo "Copy completed!"

