#!/bin/bash
# Helper script to dynamically unzip, locate Partition 3 (ROOT-A),
# mount the ChromeOS recovery rootfs, and automatically extract drivers.
#
# Usage: sudo ./devtools/extract_and_mount_recov_root_a.sh <path_to_recovery.zip_or_bin> <destination_dir> <firmware_subpath>
# Example: sudo ./devtools/extract_and_mount_recov_root_a.sh recovery.zip ./extracted_firmware lib/firmware/amdgpu
# Exit immediately if any command fails
set -e

INPUT_PATH="$1"
DEST_DIR="$2"
FIRMWARE_SUBPATH="$3"
MOUNT_DIR="/tmp/recovery_root_a_mount"
WORKSPACE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

MAPPED=0
MOUNTED=0
TEMP_BIN=""

echo "=========================================================="
echo " ChromeOS Recovery Partition 3 (ROOT-A) Automated Extractor"
echo "=========================================================="

# --- EMERGENCY TEARDOWN TRAP ---
# Guarantees loopback devices and mounts are cleaned up safely
cleanup() {
    echo ""
    echo "--------------------------------------------------------"
    echo "[*] Cleaning up partition mounts..."
    
    if [ $MOUNTED -eq 1 ]; then
        if mountpoint -q "$MOUNT_DIR" 2>/dev/null; then
            echo "  [*] Unmounting $MOUNT_DIR..."
            umount -f "$MOUNT_DIR" 2>/dev/null || umount -l "$MOUNT_DIR" 2>/dev/null || true
        fi
        rm -rf "$MOUNT_DIR"
    fi

    if [ $MAPPED -eq 1 ] && [ -n "$LOOP_DEV" ]; then
        echo "  [*] Releasing loop mappings..."
        kpartx -d "$RECOV_BIN" 2>/dev/null || true
    fi

    if [ -f "$TEMP_BIN" ]; then
        echo "  [*] Deleting extracted temporary bin..."
        rm -f "$TEMP_BIN"
    fi
    echo "  [+] Cleanup complete."
    echo "=========================================================="
}

trap cleanup EXIT

# --- PRE-FLIGHT CHECKS ---
if [ -z "$INPUT_PATH" ] || [ -z "$DEST_DIR" ] || [ -z "$FIRMWARE_SUBPATH" ]; then
    echo "[-] Error: Missing arguments!"
    echo "    Usage: sudo $0 <path/to/recovery.zip_or_bin> <destination_directory> <firmware_subpath>"
    echo "    Example: sudo $0 recovery.zip ./extracted_firmware lib/firmware/amdgpu"
    exit 1
fi

if [ "$EUID" -ne 0 ]; then
    echo "[-] Error: This script must be run as root (sudo) to map partition images."
    exit 1
fi

# Sanitize FIRMWARE_SUBPATH to strip any accidental leading slashes
FIRMWARE_SUBPATH="${FIRMWARE_SUBPATH#/}"

# --- RESOLVING INPUT TYPE ---
if [[ "$INPUT_PATH" == *.zip ]]; then
    echo "[*] Input is a compressed ZIP file. Unpacking raw image..."
    UNZIP_DIR="/tmp/unpacked_recovery_$(date +%s)"
    mkdir -p "$UNZIP_DIR"
    unzip -p "$INPUT_PATH" > "$UNZIP_DIR/recovery.bin"
    RECOV_BIN="$UNZIP_DIR/recovery.bin"
    TEMP_BIN="$RECOV_BIN" # Mark for deletion during cleanup
else
    RECOV_BIN="$INPUT_PATH"
fi

if [ ! -f "$RECOV_BIN" ]; then
    echo "[-] Error: Raw recovery binary not found at $RECOV_BIN"
    exit 1
fi

# --- MAP PARTITIONS ---
echo "[*] Mapping image partitions using kpartx..."
MAP_OUTPUT=$(kpartx -av "$RECOV_BIN")
MAPPED=1

LOOP_DEV=$(echo "$MAP_OUTPUT" | grep -o 'loop[0-9]\+' | head -n1)
if [ -z "$LOOP_DEV" ]; then
    echo "[-] Error: Failed to find mapped loop device."
    exit 1
fi

# Partition 3 is strictly defined as ROOT-A
TARGET_PART="/dev/mapper/${LOOP_DEV}p3"

# --- MOUNT ---
echo "[*] Mounting $TARGET_PART..."
mkdir -p "$MOUNT_DIR"
mount -o ro "$TARGET_PART" "$MOUNT_DIR"
MOUNTED=1

# ==============================================================================
# TEMPORARY DIAGNOSTIC DEBUG LINES
# ==============================================================================
echo "=============================================================================="
echo "[DEBUG] 1. Checking if the mount directory has files:"
ls -la "$MOUNT_DIR" || true

echo "[DEBUG] 2. Searching case-insensitively for any firmware files:"
find "$MOUNT_DIR" -iname "*stoney*" || true

echo "[DEBUG] 3. Let's see what is inside the firmware directory if it exists:"
ls -la "$MOUNT_DIR/usr/lib/firmware" 2>/dev/null || ls -la "$MOUNT_DIR/lib/firmware" 2>/dev/null || echo "[-] No firmware directory found at all!"
echo "=============================================================================="

# --- AUTOMATED COPY ---
echo "[*] Verifying target directory inside mounted image..."
FIRMWARE_SRC="$MOUNT_DIR/$FIRMWARE_SUBPATH"

if [ -d "$FIRMWARE_SRC" ]; then
    echo "[*] Extracting firmware files to destination: $DEST_DIR"
    mkdir -p "$DEST_DIR"
    cp -r "$FIRMWARE_SRC" "$DEST_DIR/"
    echo "[SUCCESS] Target files successfully cloned!"
else
    echo "[-] Error: Could not find directory inside ChromeOS image at $FIRMWARE_SRC"
    exit 1
fi