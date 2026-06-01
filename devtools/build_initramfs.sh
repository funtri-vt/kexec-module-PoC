#!/bin/bash
# Exit immediately if any command fails
set -e

# Dynamically calculate the workspace root folder relative to this script's directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$SCRIPT_DIR/.." && pwd)"

BUSYBOX_DIR="$WORKSPACE/busybox"
INSTALL_DIR="$BUSYBOX_DIR/_install"
TARGET_KERNEL_SRC="$WORKSPACE/kernel2/arch/x86/boot/bzImage"

# Sources of our custom built components
MODULE_SRC="$WORKSPACE/oot-kexec-module/kexec_mod.ko"
USERMODE_SRC="$WORKSPACE/usermode/custom_kexec"

echo "=========================================================="
echo " Starting Automated Nested Initramfs Build Pipeline"
echo "=========================================================="
echo "[*] Project Workspace: $WORKSPACE"

if [ ! -d "$INSTALL_DIR" ]; then
    echo "[-] Error: BusyBox install directory not found at $INSTALL_DIR"
    echo "    Please build BusyBox first using 'make install'."
    exit 1
fi

# --- PRE-FLIGHT COMPILATION CHECKS ---
MISSING_ASSETS=0

if [ ! -f "$MODULE_SRC" ]; then
    echo "[-] Error: Kernel module not found at: $MODULE_SRC"
    echo "    Please compile it by running 'make' inside 'oot-kexec-module/'."
    MISSING_ASSETS=1
fi

if [ ! -f "$USERMODE_SRC" ]; then
    echo "[-] Error: Usermode binary not found at: $USERMODE_SRC"
    echo "    Please compile it by running 'gcc -static -o custom_kexec custom_kexec.c' inside 'usermode/'."
    MISSING_ASSETS=1
fi

if [ $MISSING_ASSETS -eq 1 ]; then
    echo "[-] Aborting initramfs build due to missing compiled assets."
    exit 1
fi

# Ensure necessary system directories exist inside BusyBox target
mkdir -p "$INSTALL_DIR/lib"
mkdir -p "$INSTALL_DIR/bin"
mkdir -p "$INSTALL_DIR/boot"

# --- COPY CUSTOM COMPONENTS ---
echo "[*] Pre-loading custom kexec module into target filesystem..."
cp "$MODULE_SRC" "$INSTALL_DIR/lib/kexec_mod.ko"

echo "[*] Pre-loading custom loader binary into target filesystem..."
cp "$USERMODE_SRC" "$INSTALL_DIR/bin/custom_kexec"

# Navigate to the BusyBox install directory
cd "$INSTALL_DIR"
echo "[*] Working directory switched to BusyBox root: $(pwd)"

# --- NESTED CPIO STAGE ---
# Clean out old target boot payloads to prevent infinite recursion
echo "[*] Clearing out previous nested boot structures..."
rm -f boot/target_bzImage
rm -f boot/target_initrd.cpio.gz

# Package the clean BusyBox filesystem (now containing custom loader/modules)
# into a temporary target ramdisk file
echo "[*] Generating compressed target_initrd.cpio.gz..."
find . -print0 | cpio --null -ov --format=newc | gzip -9 > "$BUSYBOX_DIR/target_initrd.cpio.gz"
echo "[+] Target ramdisk successfully built."

# --- STAGE TARGET PAYLOADS FOR HOST BOOT ---
echo "[*] Locating target kernel..."
if [ -f "$TARGET_KERNEL_SRC" ]; then
    cp "$TARGET_KERNEL_SRC" boot/target_bzImage
    echo "[+] Copied target bzImage from absolute path."
else
    # Fallback to relative paths
    cp ../../kernel2/arch/x86/boot/bzImage boot/target_bzImage
    echo "[+] Copied target bzImage from relative path."
fi

# Move the newly compiled nested ramdisk into our host's boot folder
echo "[*] Copying nested target_initrd.cpio.gz into host boot/ directory..."
mv "$BUSYBOX_DIR/target_initrd.cpio.gz" boot/target_initrd.cpio.gz

# --- BUILD FINAL HOST RAMDISK ---
echo "[*] Packaging final host initramfs..."
find . -print0 | cpio --null -ov --format=newc | gzip -9 > "$WORKSPACE/initramfs.cpio.gz"

echo "=========================================================="
echo "[SUCCESS] Nested pipeline completed successfully!"
echo "Your bootable host initramfs is located at: $WORKSPACE/initramfs.cpio.gz"
echo "=========================================================="
