#!/bin/bash
# Script to create a raw ext4 image and debootstrap Debian 13 (Trixie) into it.
# This image will later be dumped into Partition 5 of the shimboot image.

set -e
set -o pipefail

BOARD="$1"

# Dynamically calculate the workspace root folder
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$SCRIPT_DIR/.." && pwd)"

IMAGE_FILE="$WORKSPACE/debian_rootfs.ext4"
MOUNT_DIR="/tmp/debian_build"
CHROOT_SCRIPT="$WORKSPACE/prodtools/debian_chroot_setup.sh"

echo "=========================================================="
echo " Phase: Building Debian 13 (Trixie) Base Rootfs"
echo "=========================================================="

# --- PRE-FLIGHT CHECKS ---
if [ "$EUID" -ne 0 ]; then
    echo "[-] Error: This script must be run as root (sudo) to use debootstrap and mount."
    exit 1
fi

if ! command -v debootstrap >/dev/null 2>&1; then
    echo "[-] Error: debootstrap is not installed. Please install it (e.g., sudo apt install debootstrap)."
    exit 1
fi

if [ ! -f "$CHROOT_SCRIPT" ]; then
    echo "[-] Error: Chroot setup script not found at $CHROOT_SCRIPT!"
    echo "    Please create this script before running the builder."
    exit 1
fi

# --- EMERGENCY CLEANUP TRAP ---
cleanup() {
    echo "=========================================================="
    echo "[*] Cleaning up build environment..."

    # Unmount virtual filesystems safely
    for dir in dev sys proc; do
        if mountpoint -q "$MOUNT_DIR/$dir" 2>/dev/null; then
            echo "  [*] Unmounting $MOUNT_DIR/$dir..."
            umount "$MOUNT_DIR/$dir" || umount -l "$MOUNT_DIR/$dir" || true
        fi
    done

    # Unmount main rootfs
    if mountpoint -q "$MOUNT_DIR" 2>/dev/null; then
        echo "  [*] Unmounting main filesystem at $MOUNT_DIR..."
        umount "$MOUNT_DIR" || umount -l "$MOUNT_DIR" || true
    fi

    if [ -d "$MOUNT_DIR" ]; then
        rmdir "$MOUNT_DIR" 2>/dev/null || true
    fi

    echo "  [+] Cleanup complete."
    echo "=========================================================="
}
trap cleanup EXIT

# --- STEP 1: CREATE AND FORMAT IMAGE ---
echo "[*] Step 1: Creating 3.5GB sparse image file..."
# We create a raw ext4 filesystem (no partition table) because it will be dd'd directly into a GPT partition later.
truncate -s 3500M "$IMAGE_FILE"
mkfs.ext4 -F -O ^metadata_csum,^has_journal -L DEB_ROOT "$IMAGE_FILE"

# --- STEP 2: MOUNT IMAGE ---
echo "[*] Step 2: Mounting image to $MOUNT_DIR..."
mkdir -p "$MOUNT_DIR"
mount -o loop "$IMAGE_FILE" "$MOUNT_DIR"

# --- STEP 3: DEBOOTSTRAP ---
echo "[*] Step 3: Running debootstrap for Debian 13 (Trixie)..."
# This downloads the base system
debootstrap --arch=amd64 trixie "$MOUNT_DIR" http://deb.debian.org/debian/

# --- STEP 4: BIND VIRTUAL FILESYSTEMS ---
echo "[*] Step 4: Binding virtual filesystems for chroot operations..."
mount --bind /dev "$MOUNT_DIR/dev"
mount --bind /sys "$MOUNT_DIR/sys"
mount --bind /proc "$MOUNT_DIR/proc"

# --- STEP 5: PREPARE AND EXECUTE CHROOT SCRIPT ---
echo "[*] Step 5: Injecting and executing chroot setup script..."
cp "$CHROOT_SCRIPT" "$MOUNT_DIR/tmp/debian_chroot_setup.sh"
chmod +x "$MOUNT_DIR/tmp/debian_chroot_setup.sh"

echo "  [*] Entering Chroot..."
# Execute the chroot environment, passing control to the setup script
chroot "$MOUNT_DIR" /bin/bash -c '/tmp/debian_chroot_setup.sh "$1"' -- "$BOARD"

echo "  [+] Chroot execution completed successfully."

# The EXIT trap will automatically unmount everything when the script completes cleanly.
echo "[SUCCESS] Debian rootfs image successfully built at: $IMAGE_FILE"
