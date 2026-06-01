#!/bin/bash
# Exit immediately if any command fails
set -e

# ==============================================================================
#  THREE-STAGE "MATRYOSHKA" KEXEC BUILD PIPELINE
# ==============================================================================
# This script builds a nested boot environment to cleanly hand off hardware state.
# 
# ARCHITECTURE:
# 1. Host Rootfs: Runs on Legacy kernel. Contains `custom_kexec` & module.
# 2. Intermediate Rootfs: A tiny "automaton" rootfs that runs on the 4.14 kernel.
#    It blindly loads the final kernel using the native `kexec` tool and jumps.
# 3. Final Payload: The actual 6.12 ChromeOS Kernel and Rootfs.
#
# PREREQUISITES (Ensure these exist before running):
# - Host BusyBox compiled at `busybox/_install`
# - Static kexec-tools binary at `kexec-tools/build/sbin/kexec`
# - Custom kexec module at `oot-kexec-module/kexec_mod.ko`
# - Custom kexec usermode tool at `usermode/custom_kexec`
# - Intermediate (Trampoline) Kernel 4.14 at `intermediate_kernel/arch/x86/boot/bzImage`
# - Final Target Kernel 6.12 at `final_kernel/arch/x86/boot/bzImage`
# - Final Target Rootfs (ChromeOS) at `final_rootfs.cpio.gz`
# ==============================================================================

# Dynamically calculate the workspace root folder relative to this script's directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=========================================================="
echo " Starting Three-Stage Kexec Build Pipeline"
echo "=========================================================="
echo "[*] Project Workspace: $WORKSPACE"

# --- DEFINE ASSET PATHS ---
HOST_INSTALL_DIR="$WORKSPACE/busybox/_install"

MODULE_SRC="$WORKSPACE/oot-kexec-module/kexec_mod.ko"
USERMODE_SRC="$WORKSPACE/usermode/custom_kexec"

# Tools and payloads for the Intermediate Stage
KEXEC_STATIC_BIN="$WORKSPACE/kexec-tools/build/sbin/kexec" # Update path if needed
INTERMEDIATE_KERNEL="$WORKSPACE/intermediate_kernel/arch/x86/boot/bzImage"

# The final destination
FINAL_KERNEL="$WORKSPACE/final_kernel/arch/x86/boot/bzImage"
FINAL_ROOTFS="$WORKSPACE/final_rootfs.cpio.gz" # Your actual operational ChromeOS rootfs

# --- PRE-FLIGHT COMPILATION CHECKS ---
MISSING_ASSETS=0

echo "[*] Running pre-flight asset checks..."

check_file() {
    if [ ! -e "$1" ]; then
        echo "[-] Error: Missing $2 at: $1"
        MISSING_ASSETS=1
    else
        echo "  [+] Found $2"
    fi
}

check_file "$HOST_INSTALL_DIR" "Host BusyBox _install dir"
check_file "$MODULE_SRC" "Custom kexec module"
check_file "$USERMODE_SRC" "Usermode loader binary"
check_file "$KEXEC_STATIC_BIN" "Static kexec-tools binary"
check_file "$INTERMEDIATE_KERNEL" "Intermediate 4.14 Kernel"
check_file "$FINAL_KERNEL" "Final 6.12 Kernel"
check_file "$FINAL_ROOTFS" "Final Target Rootfs archive"

if [ $MISSING_ASSETS -eq 1 ]; then
    echo "=========================================================="
    echo "[-] Aborting initramfs build due to missing assets."
    echo "    Please compile or place the missing files at the paths above."
    exit 1
fi

# ==============================================================================
# STAGE 1: BUILD THE INTERMEDIATE RAMDISK (The Automaton)
# ==============================================================================
INTERMEDIATE_BUILD_DIR="$WORKSPACE/build_intermediate"
INTERMEDIATE_CPIO="$WORKSPACE/intermediate_initrd.cpio.gz"

echo "[*] Phase 1: Building the Intermediate (Automaton) Rootfs..."
rm -rf "$INTERMEDIATE_BUILD_DIR"
mkdir -p "$INTERMEDIATE_BUILD_DIR"/{dev,proc,sys,payload}

# 1. Provide minimal binaries (Copy all symlinks from the host)
echo "[*] Copying BusyBox utilities to intermediate rootfs..."
cp -a "$HOST_INSTALL_DIR/bin" "$INTERMEDIATE_BUILD_DIR/"
cp -a "$HOST_INSTALL_DIR/sbin" "$INTERMEDIATE_BUILD_DIR/"
if [ -d "$HOST_INSTALL_DIR/usr" ]; then
    cp -a "$HOST_INSTALL_DIR/usr" "$INTERMEDIATE_BUILD_DIR/"
fi

# Ensure /bin/sh exists just in case
if [ ! -e "$INTERMEDIATE_BUILD_DIR/bin/sh" ]; then
    ln -s busybox "$INTERMEDIATE_BUILD_DIR/bin/sh"
fi

# 2. Add the native kexec-tools binary (Overwriting the busybox kexec symlink if it exists)
cp "$KEXEC_STATIC_BIN" "$INTERMEDIATE_BUILD_DIR/sbin/kexec"
chmod +x "$INTERMEDIATE_BUILD_DIR/sbin/kexec"

# 3. Inject the Final Payloads into the Matryoshka Pocket
echo "[*] Injecting Final 6.12 Payloads into /payload pocket..."
cp "$FINAL_KERNEL" "$INTERMEDIATE_BUILD_DIR/payload/bzImage"
cp "$FINAL_ROOTFS" "$INTERMEDIATE_BUILD_DIR/payload/initramfs.cpio.gz"

# 4. Generate the Automated /init Script
echo "[*] Generating blind automated /init script..."
cat << 'EOF' > "$INTERMEDIATE_BUILD_DIR/init"
#!/bin/sh

# NO REDIRECTION. This uses the kernel's inherited stdout/stderr console.
echo ""
echo "===================================================="
echo "  SUCCESS: PIECE OF CAKE! WE ARE ALIVE IN USERSPACE!"
echo "===================================================="
echo ""

# Mount minimal filesystems
mkdir -p /proc /sys /dev
mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev

echo "[*] Filesystems mounted successfully. Parsing and loading final kernel..."

# Load the final kernel natively using kexec-tools
/sbin/kexec -l /payload/bzImage \
    --initrd=/payload/initramfs.cpio.gz \
    --command-line="console=tty0 console=ttyS0,115200 root=/dev/ram0 rw"

# Execute the native handoff (this properly shuts down the UART!)
echo "[*] Executing native kexec jump NOW."
/sbin/kexec -e

# We should never reach this point
echo "[-] FATAL: kexec jump failed!"
while true; do sleep 1; done
EOF
chmod +x "$INTERMEDIATE_BUILD_DIR/init"

# 5. Pack the Intermediate Ramdisk
echo "[*] Packaging intermediate_initrd.cpio.gz (This may take a moment)..."
cd "$INTERMEDIATE_BUILD_DIR"
find . -print0 | cpio --null -ov --format=newc | gzip -9 > "$INTERMEDIATE_CPIO"
cd "$WORKSPACE"

# Clean up build dir
rm -rf "$INTERMEDIATE_BUILD_DIR"

# ==============================================================================
# STAGE 2: BUILD THE FINAL HOST RAMDISK
# ==============================================================================
echo "[*] Phase 2: Building the Host Launcher Rootfs..."
cd "$HOST_INSTALL_DIR"

mkdir -p lib bin boot

# Clean out old payloads
rm -f boot/target_bzImage
rm -f boot/target_initrd.cpio.gz

# 1. Load Custom Kexec Assets
echo "[*] Injecting custom kexec module and loader binary..."
cp "$MODULE_SRC" "lib/kexec_mod.ko"
cp "$USERMODE_SRC" "bin/custom_kexec"

# 2. Stage the Intermediate Kernel and Ramdisk
echo "[*] Staging Intermediate 4.14 kernel and ramdisk into /boot..."
cp "$INTERMEDIATE_KERNEL" "boot/target_bzImage"
cp "$INTERMEDIATE_CPIO" "boot/target_initrd.cpio.gz"

# 3. Pack the final Host Ramdisk
echo "[*] Packaging final host initramfs..."
find . -print0 | cpio --null -ov --format=newc | gzip -9 > "$WORKSPACE/initramfs.cpio.gz"

echo "=========================================================="
echo "[SUCCESS] Three-Stage Pipeline Completed Successfully!"
echo "Your bootable Host initramfs is located at: $WORKSPACE/initramfs.cpio.gz"
echo "=========================================================="
