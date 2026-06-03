#!/bin/bash
# Script to mount a patched shimboot image, extract the host kernel from Partition 2,
# mount Partition 4, copy out all target payloads, and rebuild the host initramfs archive.
#
# RUN THIS SCRIPT WITH SUDO: sudo ./devtools/extract_from_shim.sh <path_to_shim.bin>
# Exit immediately if any command fails
set -e

# Dynamically calculate the workspace root folder relative to this script's directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$SCRIPT_DIR/.." && pwd)"

SHIM_IMG="$1"
EXTRACT_DIR="$WORKSPACE/extracted"
MOUNT_DIR="/tmp/shimboot_extract_mount"

# Track if loop devices have been mapped to ensure safe cleanup
MAPPED=0

# --- EMERGENCY CLEANUP TRAP ---
# Guarantees we never leak loopback mappings or mount points on failure or abort.
cleanup() {
    echo ""
    echo "=========================================================="
    echo "[*] Performing teardown and cleaning up environment..."
    
    if [ -d "$MOUNT_DIR" ]; then
        if mountpoint -q "$MOUNT_DIR" 2>/dev/null; then
            echo "  [*] Unmounting $MOUNT_DIR..."
            umount -f "$MOUNT_DIR" 2>/dev/null || umount -l "$MOUNT_DIR" 2>/dev/null || true
        fi
        echo "  [*] Removing temporary mount folder..."
        rm -rf "$MOUNT_DIR"
    fi

    if [ $MAPPED -eq 1 ]; then
        echo "  [*] Releasing loopback partitions for $SHIM_IMG..."
        kpartx -d "$SHIM_IMG" 2>/dev/null || true
    fi
    echo "  [+] Cleanup complete."
    echo "=========================================================="
}

# Bind our cleanup function to the shell EXIT signal
trap cleanup EXIT

# --- PRE-FLIGHT CHECKS ---
if [ -z "$SHIM_IMG" ]; then
    echo "[-] Error: Please specify the path to your shimboot .bin file."
    echo "    Usage: sudo $0 <path_to_shimboot_image.bin>"
    exit 1
fi

if [ "$EUID" -ne 0 ]; then
    echo "[-] Error: This script must be run as root (sudo) to map loopback devices and mount systems."
    exit 1
fi

if [ ! -f "$SHIM_IMG" ]; then
    echo "[-] Error: Specified shimboot image does not exist: $SHIM_IMG"
    exit 1
fi

echo "=========================================================="
echo " Preparing to Extract Payloads from Shimboot Image"
echo "=========================================================="
echo "[*] Shim Image: $SHIM_IMG"
echo "[*] Destination: $EXTRACT_DIR"
echo ""

# Create extraction directory if it doesn't exist
mkdir -p "$EXTRACT_DIR"

# --- STEP 1: EXTRACT HOST KERNEL FROM PARTITION 2 (KERN-A) ---
echo "[*] Step 1: Extracting Host Kernel from Partition 2 (Kern-A)..."
PART2_START=$(cgpt show -i 2 -b "$SHIM_IMG")
PART2_SIZE=$(cgpt show -i 2 -s "$SHIM_IMG")

if [ -n "$PART2_START" ] && [ -n "$PART2_SIZE" ]; then
    echo "  [*] Extracting Kern-A sectors (Start: $PART2_START, Size: $PART2_SIZE)..."
    dd if="$SHIM_IMG" of="/tmp/temp_kern_a.bin" bs=512 skip="$PART2_START" count="$PART2_SIZE" status=none
    
    echo "  [*] Stripping signed ChromeOS vblock wrapper..."
    if futility vbutil_kernel --get-vmlinuz /tmp/temp_kern_a.bin --vmlinuz-out "$EXTRACT_DIR/vmlinuz.bin" 2>/dev/null; then
        echo "  [+] Success! Host kernel extracted to: $EXTRACT_DIR/vmlinuz.bin"
    else
        echo "  [!] Warning: Failed to strip vblock wrapper using futility. Copying raw partition bin..."
        cp /tmp/temp_kern_a.bin "$EXTRACT_DIR/vmlinuz_raw.bin"
    fi
    rm -f /tmp/temp_kern_a.bin
else
    echo "  [-] Error: Could not parse Partition 2 coordinates from partition table."
    exit 1
fi

# --- STEP 2: DETECT AND MAP GPT PARTITIONS VIA KPARTX ---
echo "[*] Step 2: Mapping GPT partitions from raw image..."
MAP_OUTPUT=$(kpartx -av "$SHIM_IMG")
echo "$MAP_OUTPUT"

MAPPED=1

LOOP_DEV=$(echo "$MAP_OUTPUT" | grep -o 'loop[0-9]\+' | head -n1)
if [ -z "$LOOP_DEV" ]; then
    echo "[-] Error: Failed to setup loopback device mapping."
    exit 1
fi

TARGET_PART="/dev/mapper/${LOOP_DEV}p4"

# Validate that Partition 4 contains an ext4 filesystem
if ! blkid "$TARGET_PART" | grep -q "ext4"; then
    echo "[-] Error: Partition 4 is not formatted as ext4 or is unreadable."
    exit 1
fi

# --- STEP 3: MOUNT TARGET PARTITION 4 ---
echo "[*] Step 3: Mounting partition 4..."
mkdir -p "$MOUNT_DIR"
mount -o ro "$TARGET_PART" "$MOUNT_DIR" # Mount as read-only for extraction safety
echo "  [+] Mounted successfully at $MOUNT_DIR"

# --- STEP 4: EXTRACT INJECTED PAYLOADS AND BINARIES ---
echo "[*] Step 4: Extracting standalone payloads and compiled components..."
cd "$MOUNT_DIR"

# Copy out the specific files we injected into Partition 4
COPY_FAILED=0
for item in "boot/target_bzImage" "boot/target_initrd.cpio.gz" "lib/kexec_mod.ko" "bin/custom_kexec" "bin/finit_loader"; do
    if [ -f "$item" ]; then
        dest_name=$(basename "$item")
        cp "$item" "$EXTRACT_DIR/$dest_name"
        echo "  [+] Extracted payload: $item -> $EXTRACT_DIR/$dest_name"
    else
        echo "  [-] Missing target file in Partition 4: $item"
        COPY_FAILED=1
    fi
done

# --- STEP 5: RE-PACK THE HOST INITRAMFS ---
echo "[*] Step 5: Archiving Partition 4 directory structure back to initramfs..."
# Since the whole partition holds the uncompressed host initramfs, packing it 
# back using cpio reconstructs your original host initramfs payload exactly!
if find . -mindepth 1 ! -name 'lost+found' | cpio -o -H newc 2>/dev/null | gzip -9 > "$EXTRACT_DIR/extracted_initramfs.cpio.gz"; then
    echo "  [+] Rebuilt Host Initramfs successfully compiled to: $EXTRACT_DIR/extracted_initramfs.cpio.gz"
else
    echo "  [-] Error: Failed to package Partition 4 directories into initramfs archive."
    exit 1
fi

# Go back to the workspace root before cleanup
cd "$WORKSPACE"

echo "=========================================================="
if [ $COPY_FAILED -eq 1 ]; then
    echo "[!] EXTRACTION COMPLETED WITH WARNINGS"
    echo "    Host kernel and rebuilt initramfs are ready, but some custom payloads were missing."
else
    echo "[SUCCESS] ALL PAYLOADS EXTRACTED SUCCESSFULLY!"
fi
echo "    Look in your '$EXTRACT_DIR/' folder for the extracted assets."
echo "=========================================================="
