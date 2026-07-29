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

echo "[*] Copying license to intermediate rootfs..."
if [ -f "$WORKSPACE/LICENSE" ]; then
    # Ensure the destination directory exists and copy to it
    mkdir -p "$INTERMEDIATE_BUILD_DIR"
    cp "$WORKSPACE/LICENSE" "$INTERMEDIATE_BUILD_DIR/KEXEC_MOD_LICENSE"
    echo "[+] Licenses installed."
else
    echo "[-] WARNING: Missing source file $WORKSPACE/LICENSE"
fi

echo "[*] Adding /etc/cros_boardname to intermediate rootfs..."
mkdir -p "$INTERMEDIATE_BUILD_DIR/etc/"
echo $BOARD > $INTERMEDIATE_BUILD_DIR/etc/cros_boardname
echo "[+] /etc/cros_boardname installed."

# Ensure /bin/sh exists just in case
if [ ! -e "$INTERMEDIATE_BUILD_DIR/bin/sh" ]; then
    ln -s busybox "$INTERMEDIATE_BUILD_DIR/bin/sh"
fi

# 2. Add the native kexec-tools binary (Overwriting the busybox kexec symlink if it exists)
cp "$KEXEC_STATIC_BIN" "$INTERMEDIATE_BUILD_DIR/sbin/kexec"

# 3. Generate the Automated /init Script
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
echo "===================================================="
echo ""

echo "[AUTOMATON] Parsing and loading final target kernel..."

# Extract the target_console dynamically passed from the Host environment
CMDLINE=$(cat /proc/cmdline)
TARGET_CONSOLE_ARG=""
TARGET_TTY="ttyS0,115200" # Fallback if missing

BOARD_ID_ARG=""
BOARD_ID=""
BOARD_ID_SRC=""

for arg in $CMDLINE; do
    case "$arg" in
        target_console=*)
            TARGET_CONSOLE_ARG="$arg"
            TARGET_TTY="${arg#target_console=}"
            ;;
        board_id=*)
            BOARD_ID_SRC="cmdline"
            BOARD_ID_ARG="$arg"
            BOARD_ID="${arg#board_id=}"
            ;;
    esac
done


if [ -z "$BOARD_ID" ]; then
    BOARD_ID="$(cat /etc/cros_boardname)"
    BOARD_ID_ARG="$(cat /etc/cros_boardname)"
    BOARD_ID_SRC="file"
fi

echo "[AUTOMATON] Relaying detected console parameter: $TARGET_CONSOLE_ARG"
echo "[AUTOMATON] Relaying detected board id from $BOARD_ID_SRC : $BOARD_ID"

EXTRA_BOOT_ARGS=""

if [ "$BOARD_ID" = "grunt" ]; then # this might be useful later, but make sure to set them up individually?: || [ "$BOARD_ID" = "zork" ] || [ "$BOARD_ID" = "treeya" ]
    # --- PHASE 1: GPU BRAIN-WIPE ---
    echo "[AUTOMATON] Forcing GPU PCI Reset to clear dirty RMA state for $BOARD_ID..."
    if [ -d /sys/bus/pci/devices/0000:00:01.0 ]; then
        echo "0000:00:01.0" > /sys/bus/pci/drivers/amdgpu/unbind 2>/dev/null || true
        echo 1 > /sys/bus/pci/devices/0000:00:01.0/reset 2>/dev/null || true
        echo "[AUTOMATON] GPU reset pulse sent!"
    else
        echo "[AUTOMATON] Warning: GPU 0000:00:01.0 not found!"
    fi

    # Phase 2: construct boot args to make apuart console work for AMD boards
    EXTRA_BOOT_ARGS="earlycon=uart8250,mmio32,0xfedc6000,4430n8 console=uart,mmio32,0xfedc6000,4430n8 ignore_loglevel board_id=$BOARD_ID panic=10 pm_async=0"
fi


# PRODUCTION: Dynamically locate, mount, and kexec into the Debian partition
echo "[AUTOMATON] Searching for Debian rootfs partition..."
TARGET_DEV=""
for i in $(seq 1 15); do
    TARGET_DEV=$(blkid -t PARTLABEL="execboot_rootfs:debian" -o device | head -n1)
    [ -n "$TARGET_DEV" ] && break
    sleep 1
done

if [ -z "$TARGET_DEV" ]; then
    echo "[-] FATAL: Could not find PARTLABEL=execboot_rootfs:debian after 15 seconds!"
    while true; do sleep 1; done
fi

echo "[AUTOMATON] Found Debian partition at $TARGET_DEV. Mounting..."
mkdir -p /mnt/debian
mount -o ro "$TARGET_DEV" /mnt/debian

TARGET_KERNEL=$(ls /mnt/debian/boot/vmlinuz-* | head -n 1)
TARGET_INITRD=$(ls /mnt/debian/boot/initrd.img-* | head -n 1)

if [ -z "$TARGET_KERNEL" ] || [ -z "$TARGET_INITRD" ]; then
    echo "[-] FATAL: Kernel or Initramfs missing in /boot on $TARGET_DEV!"
    while true; do sleep 1; done
fi
echo "[AUTOMATON] Extracting reliable PARTUUID for target device..."
TARGET_PARTUUID=$(blkid -s PARTUUID -o value "$TARGET_DEV")

if [ -z "$TARGET_PARTUUID" ]; then
    echo "[-] FATAL: Could not determine PARTUUID for $TARGET_DEV!"
    while true; do sleep 1; done
fi

echo "[AUTOMATON] Loading kernel: $TARGET_KERNEL"
# Note: Added 'rootwait' to allow USB enumeration and switched to 'PARTUUID=' syntax
/sbin/kexec -l "$TARGET_KERNEL" \
    --initrd="$TARGET_INITRD" \
    --command-line="root=PARTUUID=$TARGET_PARTUUID rootwait rw console=$TARGET_TTY $EXTRA_BOOT_ARGS"

echo "[AUTOMATON] Unmounting target partition..."
umount /mnt/debian

# Execute the native handoff (this properly shuts down the UART!)
echo "[AUTOMATON] Executing native kexec jump NOW."
/sbin/kexec -e

# We should never reach this point
echo "[-] FATAL: kexec jump failed!"
while true; do sleep 1; done
EOF

# 4. Pack the Intermediate Ramdisk
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
