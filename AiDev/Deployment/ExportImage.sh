#!/bin/bash

set -e

IMAGE_NAME="$1"
TAR_FILE_NAME="$2"
DOMAIN_USERNAME="$3"
DOMAIN_PASSWORD="$4"

LOCAL_PATH="/opt/chargoon/ai-engine-images"
MOUNT_PATH="/mnt/aiengineshare"

SHARE_ROOT="//fileserver.chargoon.net/Didgah Installation"
NETWORK_SUB_PATH="AI-Installation/AIEngineImages"

TAR_FILE_PATH="$LOCAL_PATH/$TAR_FILE_NAME"
DESTINATION_FILE="$MOUNT_PATH/$NETWORK_SUB_PATH/$TAR_FILE_NAME"

echo "========================================"
echo "Starting Docker save and copy operation"
echo "Image Name : $IMAGE_NAME"
echo "Tar File   : $TAR_FILE_NAME"
echo "========================================"

cleanup() {
    echo "Disconnecting network share..."
    sudo umount "$MOUNT_PATH" >/dev/null 2>&1 || true
}

trap cleanup EXIT

try() {

    echo "Creating local directory if not exists..."

    mkdir -p "$LOCAL_PATH"

    echo "Creating mount directory if not exists..."

    sudo mkdir -p "$MOUNT_PATH"

    echo "Removing old mounted share if exists..."

    sudo umount "$MOUNT_PATH" >/dev/null 2>&1 || true

    echo "Mounting network share..."

    sudo mount -t cifs "$SHARE_ROOT" "$MOUNT_PATH" \
        -o username="$DOMAIN_USERNAME",password="$DOMAIN_PASSWORD",vers=3.0

    if [ ! -d "$MOUNT_PATH/$NETWORK_SUB_PATH" ]; then
        echo "========================================"
        echo "Operation failed:"
        echo "Network path not found: $MOUNT_PATH/$NETWORK_SUB_PATH"
        echo "========================================"
        exit 1
    fi

    if [ -f "$TAR_FILE_PATH" ]; then
        echo "Existing file found. Removing: $TAR_FILE_PATH"
        rm -f "$TAR_FILE_PATH"
    fi

    echo "Running docker save..."

    docker save -o "$TAR_FILE_PATH" "$IMAGE_NAME"

    if [ ! -f "$TAR_FILE_PATH" ]; then
        echo "========================================"
        echo "Operation failed:"
        echo "TAR file was not created."
        echo "========================================"
        exit 1
    fi

    echo "TAR file created successfully: $TAR_FILE_PATH"

    echo "Copying file to network path..."

    cp -f "$TAR_FILE_PATH" "$DESTINATION_FILE"

    if [ ! -f "$DESTINATION_FILE" ]; then
        echo "========================================"
        echo "Operation failed:"
        echo "Failed to copy file to network path."
        echo "========================================"
        exit 1
    fi

    echo "File copied successfully."
    echo "Destination: $DESTINATION_FILE"

    echo "Removing local file..."

    rm -f "$TAR_FILE_PATH"

    echo "Local file removed successfully."

    echo "========================================"
    echo "Operation completed successfully."
    echo "========================================"
}