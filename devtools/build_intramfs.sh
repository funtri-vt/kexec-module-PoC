#!/bin/bash
# Exit immediately if any command fails
set -e

# Define paths relative to the workspace root
WORKSPACE="" #PUT YOUR WORKSPACE DIR HERE
BUSYBOX_DIR="$WORKSPACE/busybox"
INSTALL_DIR="$BUSYBOX_DIR/_install"
TARGET_KERNEL_SRC="$WORKSPACE/kernel2/arch/x86/boot/bzImage"

echo "=========================================================="
echo " Starting Nested Initramfs Build Pipeline"
echo "=========================================================="

if [ ! -d "$INSTALL_DIR" ]; then
    echo "[-] Error: BusyBox install directory not found at $INSTALL_DIR"
    exit 1
fi

# Navigate to the BusyBox install directory
cd "$INSTALL_DIR"
echo "[*] Working in: $(pwd)"

# 1. Ensure the boot mount point exists inside the ramdisk
mkdir -p boot

# 2. Clean out old target files to keep the target filesystem lightweight
echo "[*] Removing old nested target assets to prevent recursive packaging..."
rm -f boot/target_bzImage
rm -f boot/target_initrd.cpio.gz

# 3. Package the clean filesystem structure as the target_initrd
# We save it temporarily outside of _install to avoid packing it inside itself
echo "[*] Creating target_initrd.cpio.gz..."
find . -print0 | cpio --null -ov --format=newc | gzip -9 > ../target_initrd.cpio.gz
echo "[+] Target ramdisk packaged successfully."

# 4. Copy the second kernel bzImage into the host's boot folder
echo "[*] Locating target kernel..."
if [ -f "$TARGET_KERNEL_SRC" ]; then
    cp "$TARGET_KERNEL_SRC" boot/target_bzImage
    echo "[+] Copied target bzImage from absolute path."
else
    # Fallback to the relative path
    cp ../../kernel2/arch/x86/boot/bzImage boot/target_bzImage
    echo "[+] Copied target bzImage from relative path."
fi

# 5. Move our newly created target_initrd into the host's boot folder
echo "[*] Placing target_initrd.cpio.gz into host boot directory..."
mv ../target_initrd.cpio.gz boot/target_initrd.cpio.gz

# 6. Package the final host ramdisk (which now contains the boot payloads)
echo "[*] Packaging final host initramfs..."
find . -print0 | cpio --null -ov --format=newc | gzip -9 > "$WORKSPACE/initramfs.cpio.gz"

echo "=========================================================="
echo "[SUCCESS] Build pipeline completed!"
echo "Your QEMU-ready initramfs is located at: $WORKSPACE/initramfs.cpio.gz"
echo "=========================================================="
