#!/bin/bash
# Exit immediately if any command fails
set -e

# Dynamically calculate the workspace root folder
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$SCRIPT_DIR/.." && pwd)"
CORES=$(nproc)

echo "=========================================================="
echo "  MASTER ORCHESTRATOR: KEXEC 3-STAGE PIPELINE BUILDER"
echo "=========================================================="

# ==============================================================================
# CONFIGURATION VARIABLES (Edit these to customize your build sources)
# ==============================================================================
BOARD="grunt"
SHIM_IMG_PATH="$WORKSPACE/shimboot_$BOARD.bin" # The RMA shim file to analyze and inject

CHROMEOS_KERNEL_REPO="https://chromium.googlesource.com/chromiumos/third_party/kernel"
# Note: Host Kernel branch is determined dynamically in Phase 2

MAINLINE_KERNEL_REPO="https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git"
INTERMEDIATE_KERNEL_BRANCH="linux-4.14.y"
FINAL_KERNEL_BRANCH="linux-6.12.y"

BUSYBOX_REPO="https://git.busybox.net/busybox"
BUSYBOX_BRANCH="1_36_stable"
# ==============================================================================

cd "$WORKSPACE"

# --- PHASE 2: DYNAMIC TARGET ANALYSIS (THE RMA SHIM) ---
echo ">>> [Phase 2] Analyzing RMA Shim for Host Kernel Version..."
if [ ! -f "$SHIM_IMG_PATH" ]; then
    echo "[-] Error: Shim image not found at $SHIM_IMG_PATH!"
    echo "    Please place your downloaded shimboot.bin here."
    exit 1
fi

# Find the start sector and size of Partition 2 (Kern-A)
PART2_START=$(cgpt show -i 2 -b "$SHIM_IMG_PATH")
PART2_SIZE=$(cgpt show -i 2 -s "$SHIM_IMG_PATH")

echo "  [*] Extracting Kern-A (Start: $PART2_START, Size: $PART2_SIZE sectors)..."
dd if="$SHIM_IMG_PATH" of="temp_kern_a.bin" bs=512 skip="$PART2_START" count="$PART2_SIZE" status=none

# Extract the raw bzImage from the signed ChromeOS vblock wrapper
echo "  [*] Stripping ChromeOS vblock to extract raw bzImage..."
futility vbutil_kernel --get-vmlinuz temp_kern_a.bin --vmlinuz-out vmlinuz.bin

# The 'file' utility natively parses the uncompressed x86 bzImage setup header to find the version string
# Example file output: "vmlinuz.bin: Linux kernel x86 boot executable bzImage, version 4.14.214..."
HOST_VERSION=$(file vmlinuz.bin | grep -o -E "version [0-9]+\.[0-9]+" | awk '{print $2}')

rm temp_kern_a.bin vmlinuz.bin

if [ -z "$HOST_VERSION" ]; then
    echo "[-] Error: Could not determine host kernel version from the extracted bzImage!"
    exit 1
fi
echo "  [+] Discovered Target ChromeOS Kernel Version: $HOST_VERSION"


# --- PHASE 3: HOST KERNEL HEADERS PREP ---
echo ">>> [Phase 3] Preparing Host Kernel Headers (ChromeOS $HOST_VERSION)..."
HOST_KDIR="$WORKSPACE/host_kernel"
if [ ! -d "$HOST_KDIR" ]; then
    git clone --depth 1 -b "chromeos-$HOST_VERSION" "$CHROMEOS_KERNEL_REPO" "$HOST_KDIR"
fi
cd "$HOST_KDIR"
make defconfig
# Force CONFIG_KEXEC off to mirror the locked-down environment
sed -i 's/CONFIG_KEXEC=y/# CONFIG_KEXEC is not set/' .config
make modules_prepare -j"$CORES"


# --- PHASE 4: INTERMEDIATE KERNEL BUILD (The Automaton) ---
echo ">>> [Phase 4] Building Intermediate Kernel ($INTERMEDIATE_KERNEL_BRANCH)..."
INT_KDIR="$WORKSPACE/intermediate_kernel"
if [ ! -d "$INT_KDIR" ]; then
    git clone --depth 1 -b "$INTERMEDIATE_KERNEL_BRANCH" "$MAINLINE_KERNEL_REPO" "$INT_KDIR"
fi
cd "$INT_KDIR"
make defconfig
# Force CONFIG_KEXEC ON for the jump capability
sed -i 's/# CONFIG_KEXEC is not set/CONFIG_KEXEC=y/' .config
make -j"$CORES" bzImage


# --- PHASE 5: FINAL KERNEL BUILD (The Destination) ---
echo ">>> [Phase 5] Building Final Target Kernel ($FINAL_KERNEL_BRANCH)..."
FIN_KDIR="$WORKSPACE/final_kernel"
if [ ! -d "$FIN_KDIR" ]; then
    git clone --depth 1 -b "$FINAL_KERNEL_BRANCH" "$MAINLINE_KERNEL_REPO" "$FIN_KDIR"
fi
cd "$FIN_KDIR"
make defconfig
make -j"$CORES" bzImage


# --- PHASE 6: KEXEC-TOOLS COMPILATION ---
echo ">>> [Phase 6] Building static kexec-tools..."
cd "$WORKSPACE"
bash ./devtools/setup_kexec_tools.sh


# --- PHASE 7: BUSYBOX COMPILATION (Host & Final) ---
echo ">>> [Phase 7] Building BusyBox Environments..."
BB_DIR="$WORKSPACE/busybox"
if [ ! -d "$BB_DIR" ]; then
    git clone --depth 1 -b "$BUSYBOX_BRANCH" "$BUSYBOX_REPO" "$BB_DIR"
fi
cd "$BB_DIR"
make defconfig
# Enable static build and disable Traffic Control to prevent build errors
sed -i 's/# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config
sed -i 's/CONFIG_TC=y/# CONFIG_TC is not set/' .config

echo "  [*] Compiling BusyBox binary..."
make -j"$CORES"

echo "  [*] Installing to Host Rootfs (_install)..."
make install

echo "  [*] Installing to Final Rootfs (final_rootfs_busybox/_install)..."
mkdir -p "$WORKSPACE/final_rootfs_busybox/_install"
make CONFIG_PREFIX="$WORKSPACE/final_rootfs_busybox/_install" install


# --- PHASE 8: OUT-OF-TREE TOOLS COMPILATION ---
echo ">>> [Phase 8] Compiling Out-Of-Tree Kexec Module & Usermode Loader..."
cd "$WORKSPACE/oot-kexec-module"
# Pass our explicitly prepared ChromeOS headers path to the Makefile
make KDIR="$HOST_KDIR"

cd "$WORKSPACE/usermode"
gcc -static -o custom_kexec custom_kexec.c


# --- PHASE 9: PAYLOAD ASSEMBLY & INJECTION ---
echo ">>> [Phase 9] Assembling nested payloads and injecting into Shim..."
cd "$WORKSPACE"

# 1. Trigger the packing logic
bash ./devtools/final_build_step.sh

# 2. Inject to the target shim
sudo bash ./devtools/inject_to_shim.sh "$SHIM_IMG_PATH"

echo "=========================================================="
echo " [COMPLETE] PIPELINE EXECUTED SUCCESSFULLY!"
echo " The file $SHIM_IMG_PATH is ready to be flashed."
echo "=========================================================="