#!/bin/bash
# Script to mount a patched shimboot image, find partition 5 (or the rootfs partition),
# unpack our custom host initramfs directly into it, and safely detach.
#
# RUN THIS SCRIPT WITH SUDO: sudo ./devtools/inject_to_shim.sh <path_to_shim.bin>
# Exit immediately if any command fails
set -e

# Dynamically calculate the workspace root folder relative to this script's directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$SCRIPT_DIR/.." && pwd)"

SHIM_IMG="$1"
INITRAMFS_SRC="$WORKSPACE/initramfs.cpio.gz"
MOUNT_DIR="/tmp/shimboot_mount"

# Track if loop devices have been mapped to ensure safe cleanup
MAPPED=0

# --- EMERGENCY CLEANUP TRAP ---
# This ensures that even if any step fails or is aborted (Ctrl+C),
# we never leak mount points or loop devices.
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
    echo "[-] Error: This script must be run as root (sudo) to mount loopback loop devices."
    exit 1
fi

if [ ! -f "$SHIM_IMG" ]; then
    echo "[-] Error: Specified shimboot image does not exist: $SHIM_IMG"
    exit 1
fi

if [ ! -f "$INITRAMFS_SRC" ]; then
    echo "[-] Error: Custom initramfs payload not found at: $INITRAMFS_SRC"
    echo "    Please run devtools/final_build_step.sh first to compile it!"
    exit 1
fi

echo "=========================================================="
echo " Preparing to Inject Payload into Shimboot Image"
echo "=========================================================="
echo "[*] Shim Image: $SHIM_IMG"
echo "[*] Source Payload: $INITRAMFS_SRC"
echo ""

# --- STEP 0: DYNAMICALLY EXPAND THE RAW IMAGE & PARTITION ---
echo "[*] Step 0: Expanding raw shimboot image to ensure adequate space..."

# 1. Expand the raw .bin image by 300MB to comfortably hold our multi-stage payloads
truncate -s +1G "$SHIM_IMG"

# 2. Relocate the GPT backup header to the new end of the file
if command -v sgdisk >/dev/null 2>&1; then
    sgdisk -e "$SHIM_IMG" >/dev/null 2>&1 || true
fi

# 3. Use parted to resize partition 5 to 100% of the newly allocated space
if command -v parted >/dev/null 2>&1; then
    parted -s "$SHIM_IMG" resizepart 5 100% || true
else
    echo "  [!] Warning: 'parted' tool not found. Skipping partition table resize."
fi

# --- STEP 1: DETECT AND MOUNT GPT PARTITIONS VIA KPARTX ---
echo "[*] Step 1: Mapping GPT partitions from the raw image..."

# kpartx reads partition tables on a device and creates device maps over it
# -a: Add partition mappings, -v: Verbose output
MAP_OUTPUT=$(kpartx -av "$SHIM_IMG")
echo "$MAP_OUTPUT"

# Mark loop devices as active/mapped so the trap clean-up covers them from this point forward
MAPPED=1

# We parse the output to find loop device assignments.
LOOP_DEV=$(echo "$MAP_OUTPUT" | grep -o 'loop[0-9]\+' | head -n1)

if [ -z "$LOOP_DEV" ]; then
    echo "[-] Error: Failed to setup loopback device mapping."
    exit 1
fi

# Dynamically target Partition 5 (standard shimboot ext4 partition)
TARGET_PART="/dev/mapper/${LOOP_DEV}p5"

# Let's perform a safety check using parted/blkid to confirm this is an ext4 partition
echo "[*] Verifying partition properties of $TARGET_PART..."
if ! blkid "$TARGET_PART" | grep -q "ext4"; then
    echo "  [!] Warning: Partition 5 is not ext4. Searching GPT names for 'shimboot_rootfs'..."
    
    # Fallback search through all mapped loop partitions to find one labeled with shimboot_rootfs
    FOUND_PART=""
    for part in /dev/mapper/${LOOP_DEV}p*; do
        # Use blkid or file to check if it's ext4
        if blkid "$part" | grep -q "ext4"; then
            FOUND_PART="$part"
            break
        fi
    done
    
    if [ -n "$FOUND_PART" ]; then
        TARGET_PART="$FOUND_PART"
        echo "  [+] Found alternative ext4 rootfs partition at: $TARGET_PART"
    else
        echo "[-] Error: Could not locate an ext4 partition to mount inside the image."
        exit 1
    fi
fi

# --- STEP 1.5: GROW THE EXT4 FILESYSTEM ---
echo "[*] Step 1.5: Expanding the ext4 filesystem to utilize the newly added space..."
e2fsck -fp "$TARGET_PART" || true
resize2fs "$TARGET_PART"

# --- STEP 2: MOUNT TARGET PARTITION ---
echo "[*] Step 2: Mounting partition..."
mkdir -p "$MOUNT_DIR"
mount "$TARGET_PART" "$MOUNT_DIR"
echo "  [+] Mounted successfully at $MOUNT_DIR"

# --- STEP 3: UNPACK THE PAYLOAD WITH CLEANUP ---
echo "[*] Step 3: Unpacking initramfs filesystem directly into rootfs..."

# We navigate into the mount directory
cd "$MOUNT_DIR"

# Safely clean out old files to prevent stale binaries/configs from lingering.
# Guard prevents accidental rm -rf execution on the host root directory.
echo "  [*] Purging old rootfs structures from previous runs..."
if [ "$PWD" = "$MOUNT_DIR" ] && [ "$MOUNT_DIR" != "/" ] && [ -n "$MOUNT_DIR" ]; then
    # Delete everything except the system lost+found folder to keep ext4 happy
    find . -mindepth 1 -maxdepth 1 ! -name 'lost+found' -exec rm -rf {} +
    echo "  [+] Old rootfs cleared."
else
    echo "[-] Error: Directory guard mismatch! Wiping aborted for system safety."
    exit 1
fi

# We extract the entire host initramfs archive.
# Added the -u (--unconditional) flag to force overwriting of any remaining filesystem structures.
zcat "$INITRAMFS_SRC" | cpio -idmuv --no-absolute-filenames

echo "  [+] Extraction complete."

# Verify the presence of critical components
echo "[*] Verifying target directory structure..."
CHECK_FAILED=0
for file in "init" "lib/kexec_mod.ko" "bin/custom_kexec" "boot/target_bzImage" "boot/target_initrd.cpio.gz"; do
    if [ -f "$file" ]; then
        echo "  [+] Found: $file"
    else
        echo "  [-] Missing critical component: $file"
        CHECK_FAILED=1
    fi
done

# --- STEP 4: FLUSH WRITES ---
echo "[*] Step 4: Syncing changes..."
cd "$WORKSPACE"

# Sync guarantees any cached filesystem operations are flushed directly into the physical .bin blocks
sync

if [ $CHECK_FAILED -eq 1 ]; then
    echo "[!] WARNING: The payload was injected, but some files were missing."
    echo "    Double-check your build output files."
    exit 1
else
    echo "[SUCCESS] Payload successfully injected into $SHIM_IMG!"
    echo "          You are ready to write this file to your bootable USB!"
fi