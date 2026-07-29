#!/bin/bash
# Script to mount a patched shimboot image, find partition 4 (or the rootfs partition),
# unpack our custom host initramfs directly into it, and safely detach.
#
# RUN THIS SCRIPT WITH SUDO: sudo ./prodtools/inject_to_shim.sh <path_to_shim.bin>
# Exit immediately if any command fails
set -e
set -o pipefail

# check dependencies
for cmd in kpartx cgpt e2fsck resize2fs mkfs.ext4 truncate cpio zcat mount umount; do
  command -v $cmd >/dev/null || { echo "Missing required: $cmd"; exit 1; }
done
# Dynamically calculate the workspace root folder relative to this script's directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$SCRIPT_DIR/.." && pwd)"

SHIM_IMG="$1"
INITRAMFS_SRC="$WORKSPACE/initramfs.cpio.gz"
DEBIAN_SRC="$WORKSPACE/debian_rootfs.ext4"
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
    echo "    Please run prodtools/final_build_step.sh first to compile it!"
    exit 1
fi

if [ ! -f "$DEBIAN_SRC" ]; then
    echo "[-] Error: Debian rootfs image not found at: $DEBIAN_SRC"
    echo "    Please run prodtools/build_debian_rootfs.sh first to create it!"
    exit 1
fi

echo "=========================================================="
echo " Preparing to Inject Payload into Shimboot Image"
echo "=========================================================="
echo "[*] Shim Image: $SHIM_IMG"
echo "[*] Source Payload: $INITRAMFS_SRC"
echo ""

# --- STEP 1: DETECT AND MOUNT GPT PARTITIONS VIA KPARTX ---
echo "[*] Step 1: Mapping GPT partitions from the raw image..."

# kpartx reads partition tables on a device and creates device maps over it
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

# We target Partition 4 as the primary destination for our payload injection
TARGET_PART="/dev/mapper/${LOOP_DEV}p4"

# --- STEP 2: ENSURE FILE SYSTEM EXISTENCE & TYPE ON PARTITION 4 ---
echo "[*] Checking filesystem state on $TARGET_PART..."
FS_TYPE=$(blkid -o value -s TYPE "$TARGET_PART" || echo "none")

if [ "$FS_TYPE" != "ext4" ]; then
    echo "  [!] Destination partition 4 is currently formatted as '$FS_TYPE'. Creating new ext4 filesystem..."
    # Format partition 4 with ext4 so we can cleanly write to it
    mkfs.ext4 -F -O ^metadata_csum,^has_journal "$TARGET_PART"
    echo "  [+] Partition 4 formatted successfully to ext4."
else
    echo "  [+] Verified Partition 4 is already ext4."
fi

# --- STEP 3: MOUNT TARGET PARTITION ---
echo "[*] Step 3: Mounting partition..."
mkdir -p "$MOUNT_DIR"
mount "$TARGET_PART" "$MOUNT_DIR"
echo "  [+] Mounted successfully at $MOUNT_DIR"

# --- STEP 4: UNPACK THE PAYLOAD WITH CLEANUP ---
echo "[*] Step 4: Unpacking initramfs filesystem directly into rootfs..."

# We navigate into the mount directory
cd "$MOUNT_DIR"

# Safely clean out old files to prevent stale binaries/configs from lingering.
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
zcat "$INITRAMFS_SRC" | cpio -idmuv --no-absolute-filenames

echo "  [+] Extraction complete."

# Verify the presence of critical components
echo "[*] Verifying target directory structure..."
CHECK_FAILED=0
for file in "init" "lib/kexec_mod.ko" "bin/custom_kexec" "bin/finit_loader" "boot/target_bzImage" "boot/target_initrd.cpio.gz"; do
    if [ -f "$file" ]; then
        echo "  [+] Found: $file"
    else
        echo "  [-] Missing critical component: $file"
        CHECK_FAILED=1
    fi
done

# --- STEP 4.5: SHRINK FILESYSTEM AND TRUNCATE IMAGE ---
echo "[*] Step 4.5: Shrinking partition 4 and truncating image..."
cd "$WORKSPACE"

echo "  [*] Unmounting partition to safely resize..."
umount "$MOUNT_DIR"

echo "  [*] Resizing ext4 filesystem on $TARGET_PART to 500M..."
e2fsck -y -f "$TARGET_PART" || true
resize2fs "$TARGET_PART" 500M

echo "  [*] Releasing loopback mappings to modify GPT..."
kpartx -d "$SHIM_IMG" 2>/dev/null || true
MAPPED=0

echo "  [*] Updating GPT partition table for Partition 4 (500MB)..."
cgpt add -i 4 -s 1024000 "$SHIM_IMG"

P4_START=$(cgpt show -i 4 -b "$SHIM_IMG")
P4_SIZE=$(cgpt show -i 4 -s "$SHIM_IMG")
[ -n "$P4_START" ] && [ -n "$P4_SIZE" ] || { echo "Failed to read partition info"; exit 1; }
P4_END=$((P4_START + P4_SIZE))
# --- STEP 4.6: INJECT DEBIAN ROOTFS TO PARTITION 5 ---
echo "[*] Step 4.6: Adding Partition 5 and injecting Debian Rootfs..."
DEBIAN_BYTES=$(stat -c%s "$DEBIAN_SRC")
# Round up to nearest sector (512 bytes)
DEBIAN_SECTORS=$(( (DEBIAN_BYTES + 511) / 512 ))

P5_START=$P4_END
P5_SIZE=$DEBIAN_SECTORS
P5_END=$((P5_START + P5_SIZE))

# Pad 2048 sectors (1MB) + 33 sectors for GPT backup
NEW_SECTORS=$((P5_END + 2100))
NEW_BYTES=$((NEW_SECTORS * 512))

echo "  [*] Truncating raw image file to $NEW_BYTES bytes to fit new payload..."
truncate -s "$NEW_BYTES" "$SHIM_IMG"

echo "  [*] Repairing GPT headers to align with new file size..."
cgpt repair "$SHIM_IMG"

echo "  [*] Updating GPT partition table for Partition 5..."
cgpt add -i 5 -b "$P5_START" -s "$P5_SIZE" -l "execboot_rootfs:debian" "$SHIM_IMG"

echo "  [*] Writing Debian rootfs to Partition 5..."
dd if="$DEBIAN_SRC" of="$SHIM_IMG" bs=512 seek="$P5_START" count="$P5_SIZE" conv=notrunc status=progress

echo "  [*] Repairing GPT headers after injection and truncation..."
cgpt repair "$SHIM_IMG" || true

# --- STEP 5: FLUSH WRITES ---
echo "[*] Step 5: Syncing changes..."

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
