#!/bin/bash
# Exit immediately if any command fails
set -e

# ==============================================================================
#  THREE-STAGE "MATRYOSHKA" KEXEC BUILD PIPELINE
# ==============================================================================
# This script builds a nested boot environment to cleanly hand off hardware state.
# 
# ARCHITECTURE & KERNEL REQUIREMENTS:
# 1. Host Kernel (Target Hardware): The locked-down kernel running on the Chromebook
#    (e.g., ChromeOS 4.14/4.19/5.4 from the RMA Shim). It has CONFIG_KEXEC=n.
#    Our out-of-tree module must be compiled against its headers.
# 2. Intermediate Kernel: A tiny "automaton" kernel (e.g., Mainline 4.14).
#    CRITICAL: Must have CONFIG_KEXEC=y. It blindly loads the final payload and jumps.
# 3. Final Target Kernel: The destination kernel (e.g., Vanilla 6.x, modern ChromeOS, etc.).
#
# PREREQUISITES (Ensure these exist before running):
# - Host BusyBox compiled at `busybox/_install`
# - Static kexec-tools binary at `kexec-tools/build/sbin/kexec`
# - Custom kexec module at `oot-kexec-module/kexec_mod.ko`
# - Custom kexec usermode tool at `usermode/custom_kexec`
# - Custom finit usermode tool at `usermode/finit_loader`
# - Intermediate (Trampoline) Kernel at `intermediate_kernel/arch/x86/boot/bzImage`
# - Final Target Kernel at `final_kernel/arch/x86/boot/bzImage`
# - Final Target Rootfs base at `final_rootfs.cpio.gz`
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
FINIT_USERMODE_SRC="$WORKSPACE/usermode/finit_loader"

# Tools and payloads for the Intermediate Stage
KEXEC_STATIC_BIN="$WORKSPACE/kexec-tools/build/sbin/kexec" 
INTERMEDIATE_KERNEL="$WORKSPACE/intermediate_kernel/arch/x86/boot/bzImage"

# The final destination
FINAL_KERNEL="$WORKSPACE/final_kernel/arch/x86/boot/bzImage"
FINAL_ROOTFS="$WORKSPACE/final_rootfs.cpio.gz" 

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
check_file "$INTERMEDIATE_KERNEL" "Intermediate Kernel"
check_file "$FINAL_KERNEL" "Final Target Kernel"
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
if [ -d "$HOST_INSTALL_DIR/lib" ]; then
    cp -a "$HOST_INSTALL_DIR/lib" "$INTERMEDIATE_BUILD_DIR/"
fi
if [ -d "$HOST_INSTALL_DIR/usr" ]; then
    cp -a "$HOST_INSTALL_DIR/usr" "$INTERMEDIATE_BUILD_DIR/"
fi

# Ensure /bin/sh exists just in case
if [ ! -e "$INTERMEDIATE_BUILD_DIR/bin/sh" ]; then
    ln -s busybox "$INTERMEDIATE_BUILD_DIR/bin/sh"
fi

# 2. Add the native kexec-tools binary (Overwriting the busybox kexec symlink if it exists)
cp "$KEXEC_STATIC_BIN" "$INTERMEDIATE_BUILD_DIR/sbin/kexec"

# 3. Inject the Final Payloads into the Matryoshka Pocket
echo "[*] Injecting Final Payloads into /payload pocket..."
cp "$FINAL_KERNEL" "$INTERMEDIATE_BUILD_DIR/payload/bzImage"
cp "$FINAL_ROOTFS" "$INTERMEDIATE_BUILD_DIR/payload/initramfs.cpio.gz"

# 4. Generate the Automated /init Script
echo "[*] Generating blind automated /init script..."
cat << 'EOF' > "$INTERMEDIATE_BUILD_DIR/init"
#!/bin/sh

# 1. Mount the core virtual filesystems so we can see hardware
mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev

# Route everything to the kernel log so we can actually see it if the display works!
exec >/dev/kmsg 2>&1

echo ""
echo "===================================================="
echo "  [AUTOMATON] SUCCESS: WE ARE ALIVE IN STAGE 2!"
echo "  [AUTOMATON] FIRMWARE INJECTED AND SIGHT RESTORED!"
echo "===================================================="
echo ""

echo "[AUTOMATON] Parsing and loading final target kernel..."

# Extract the target_console dynamically passed from the Host environment
CMDLINE=$(cat /proc/cmdline)
TARGET_CONSOLE_ARG=""
TARGET_TTY="ttyS0,115200" # Fallback if missing

for arg in $CMDLINE; do
    case "$arg" in
        target_console=*)
            TARGET_CONSOLE_ARG="$arg"
            TARGET_TTY="${arg#target_console=}"
            ;;
    esac
done

echo "[AUTOMATON] Relaying detected console parameter: $TARGET_CONSOLE_ARG"

# Load the final kernel natively using kexec-tools
# - Merged dynamic console variables to ensure correct physical output
# - Appended TARGET_CONSOLE_ARG so the final kernel can parse it too
/sbin/kexec -l /payload/bzImage \
    --initrd=/payload/initramfs.cpio.gz \
    --command-line="console=tty0 console=$TARGET_TTY $TARGET_CONSOLE_ARG root=/dev/ram0 rw debug earlyprintk=serial,ttyS0,115200 loglevel=8 initcall_debug cros_debug cros_secure=0 reset_devices i8042.reset i8042.nomux amd_iommu=off iommu=soft amdgpu.sg_display=0 amdgpu.runpm=0 amdgpu.aspm=0"

# Execute the native handoff (this properly shuts down the UART!)
echo "[AUTOMATON] Executing native kexec jump NOW."
/sbin/kexec -e

# We should never reach this point
echo "[-] FATAL: kexec jump failed!"
while true; do sleep 1; done
EOF

# 5. Pack the Intermediate Ramdisk
echo "[*] Packaging intermediate_initrd.cpio.gz (This may take a moment)..."

# ==============================================================================
# PERMISSION SLEDGEHAMMER
# Force correct execution bits so the new kernel doesn't throw EACCES (-13)
# ==============================================================================
echo "[*] Enforcing correct executable permissions..."
chmod 755 "$INTERMEDIATE_BUILD_DIR/init"
chmod -R 755 "$INTERMEDIATE_BUILD_DIR/bin" "$INTERMEDIATE_BUILD_DIR/sbin" 2>/dev/null || true
if [ -d "$INTERMEDIATE_BUILD_DIR/usr" ]; then
    chmod -R 755 "$INTERMEDIATE_BUILD_DIR/usr" 2>/dev/null || true
fi

cd "$INTERMEDIATE_BUILD_DIR"
# The --owner root:root flag ensures the kernel sees the files as natively owned
find . -print0 | cpio --null -ov --format=newc --owner root:root | gzip -9 > "$INTERMEDIATE_CPIO"
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
cp "$FINIT_USERMODE_SRC" "bin/finit_loader"

# 2. Stage the Intermediate Kernel and Ramdisk
echo "[*] Staging Intermediate kernel and ramdisk into /boot..."
cp "$INTERMEDIATE_KERNEL" "boot/target_bzImage"
cp "$INTERMEDIATE_CPIO" "boot/target_initrd.cpio.gz"

# 3. Pack the final Host Ramdisk
echo "[*] Packaging final host initramfs..."
# Ensure the host init is executable as well
if [ -f "init" ]; then chmod 755 init; fi
find . -print0 | cpio --null -ov --format=newc --owner root:root | gzip -9 > "$WORKSPACE/initramfs.cpio.gz"

echo "=========================================================="
echo "[SUCCESS] Three-Stage Pipeline Completed Successfully!"
echo "Your bootable Host initramfs is located at: $WORKSPACE/initramfs.cpio.gz"
echo "=========================================================="
