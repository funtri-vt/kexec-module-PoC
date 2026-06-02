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
if [ -f "$WORKSPACE/devtools/base_init_pre_pivots" ]; then
    cp "$WORKSPACE/devtools/base_init_pre_pivots" "$WORKSPACE/busybox/_install/init"
    chmod +x "$WORKSPACE/busybox/_install/init"
    echo "  [+] Base init installed and set to executable."
else
    echo "  [-] Error: Missing source file $WORKSPACE/devtools/base_init_pre_pivots"
    exit 1
fi

# 2. Setup final rootfs init script
echo "[*] Step 2: Deploying final_rootfs_init..."
if [ -f "$WORKSPACE/devtools/final_rootfs_init" ]; then
    # Ensure the destination directory exists
    mkdir -p "$WORKSPACE/final_rootfs_busybox/_install"
    
    cp "$WORKSPACE/devtools/final_rootfs_init" "$WORKSPACE/final_rootfs_busybox/_install/init"
    chmod +x "$WORKSPACE/final_rootfs_busybox/_install/init"
    echo "  [+] Final rootfs init installed and set to executable."
else
    echo "  [-] Error: Missing source file $WORKSPACE/devtools/final_rootfs_init"
    exit 1
fi

# 3. Pack the final rootfs archive (Cleaned-up pack_final_rootfs.sh logic)
echo "[*] Step 3: Packing final target rootfs archive..."
if [ -d "$WORKSPACE/final_rootfs_busybox/_install" ]; then
    # Navigate to target directory to keep path structures clean inside the archive
    cd "$WORKSPACE/final_rootfs_busybox/_install"
    
    # Pack into final_rootfs.cpio.gz at workspace root
    find . -print0 | cpio --null -ov --format=newc --owner root:root | gzip -9 > "$WORKSPACE/final_rootfs.cpio.gz"
    echo "  [+] Successfully packaged final_rootfs.cpio.gz."
else
    echo "  [-] Error: Target directory $WORKSPACE/final_rootfs_busybox/_install does not exist."
    exit 1
fi

# 4. Trigger the actual nested initramfs build pipeline using absolute paths
echo "[*] Step 4: Launching main build pipeline..."
BUILD_SCRIPT="$WORKSPACE/devtools/build_initramfs.sh"

if [ -f "$BUILD_SCRIPT" ]; then
    bash "$BUILD_SCRIPT"
else
    echo "  [-] Error: Pipeline build script not found at $BUILD_SCRIPT"
    exit 1
fi

echo "=========================================================="
echo " [SUCCESS] Workspace prepared and pipeline completed!"
echo "=========================================================="