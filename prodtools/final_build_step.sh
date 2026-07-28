#!/bin/bash
# Script to prepare the initramfs workspaces, pack the final rootfs, and trigger the final build pipeline.
# Exit immediately if any command fails
set -e

# Dynamically calculate the workspace root folder relative to this script's directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=========================================================="
echo " Preparing Pre-Pivot, Final Init, and Packaging..."
echo "=========================================================="
echo "[*] Project Workspace: $WORKSPACE"

# 1. Setup host base init script
echo "[*] Step 1: Deploying base_init_pre_pivots..."
if [ -f "$WORKSPACE/prodtools/base_init_pre_pivots" ]; then
    # Cleanly remove the destination first to prevent symlink-following traps
    rm -f "$WORKSPACE/busybox/_install/init"
    cp "$WORKSPACE/prodtools/base_init_pre_pivots" "$WORKSPACE/busybox/_install/init"
    chmod +x "$WORKSPACE/busybox/_install/init"
    echo "  [+] Base init installed and set to executable."
else
    echo "  [-] Error: Missing source file $WORKSPACE/prodtools/base_init_pre_pivots"
    exit 1
fi

# 1.5 Setup Shimboot handoff stub
echo "[*] Step 1.5: Deploying host_sbin_init handoff stub..."
if [ -f "$WORKSPACE/prodtools/host_sbin_init" ]; then
    mkdir -p "$WORKSPACE/busybox/_install/sbin"
    # CRITICAL FIX: Force removal of the busybox-generated symlink pointing to busybox!
    # If we do not delete this first, cp will overwrite the real /bin/busybox executable with our script!
    rm -f "$WORKSPACE/busybox/_install/sbin/init"
    cp "$WORKSPACE/prodtools/host_sbin_init" "$WORKSPACE/busybox/_install/sbin/init"
    chmod +x "$WORKSPACE/busybox/_install/sbin/init"
    echo "  [+] Shimboot /sbin/init handoff stub installed safely."
else
    echo "  [-] Error: Missing source file $WORKSPACE/prodtools/host_sbin_init"
    exit 1
fi

# 2.5. Copy licenses
echo "[*] Step 2: Deploying licensing info..."
if [ -f "$WORKSPACE/LICENSE" ]; then
    # Ensure the destination directory exists and copy to it
    mkdir -p "$WORKSPACE/busybox/_install"
    cp "$WORKSPACE/LICENSE" "$WORKSPACE/busybox/_install/KEXEC_MOD_LICENSE"
    echo "  [+] Licenses installed."
else
    echo "  [-] WARNING: Missing source file $WORKSPACE/LICENSE"
fi

echo "[*] Step 2.5: Deploying /etc/cros_boardname info..."
mkdir -p "$WORKSPACE/busybox/_install/etc/"
echo $BOARD > $WORKSPACE/busybox/_install/etc/cros_boardname
echo "  [+] /etc/cros_boardname installed."

# 4. Trigger the actual nested initramfs build pipeline using absolute paths
echo "[*] Step 4: Launching main build pipeline..."
BUILD_SCRIPT="$WORKSPACE/prodtools/build_initramfs.sh"

if [ -f "$BUILD_SCRIPT" ]; then
    bash "$BUILD_SCRIPT"
else
    echo "  [-] Error: Pipeline build script not found at $BUILD_SCRIPT"
    exit 1
fi

echo "=========================================================="
echo " [SUCCESS] Workspace prepared and pipeline completed!"
echo "=========================================================="
