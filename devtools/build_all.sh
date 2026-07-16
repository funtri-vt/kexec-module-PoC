#!/bin/bash
# Master build script to compile all components and pack the final kexec payload.
# Exit immediately if any command fails
set -e

# Dynamically calculate the workspace root folder relative to this script's directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$SCRIPT_DIR/.." && pwd)"
CORES=$(nproc) # Get number of CPU cores for fast compilation

# Determine BOARD from environment, default to "unknown" if not set
BOARD="${BOARD:-unknown}"

echo "=========================================================="
echo "  MASTER ORCHESTRATOR: KEXEC 3-STAGE PIPELINE BUILDER"
echo "=========================================================="
echo "[*] Workspace: $WORKSPACE"
echo "[*] Compiling with $CORES threads..."
echo "[*] Target Board: $BOARD"

if [ "$CACHE_HIT" = "true" ]; then
    echo "[+] CACHE RESTORED: Heavy compilation steps will be bypassed if binaries exist!"
fi
echo ""

# ==============================================================================
# CONFIGURATION VARIABLES (Edit these to customize your build sources)
# ==============================================================================
SHIM_IMG_PATH="$WORKSPACE/shimboot_$BOARD.bin" # The RMA shim file to analyze and inject

CHROMEOS_KERNEL_REPO="https://chromium.googlesource.com/chromiumos/third_party/kernel"
# Note: Host Kernel branch is determined dynamically in Phase 2

MAINLINE_KERNEL_REPO="https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git"
INTERMEDIATE_KERNEL_BRANCH="linux-4.14.y"
FINAL_KERNEL_BRANCH="linux-6.12.y"

BUSYBOX_REPO="https://git.busybox.net/busybox"
BUSYBOX_REPO_TWO="https://github.com/vda-linux/busybox_mirror"
BUSYBOX_BRANCH="1_36_stable"
# ==============================================================================

cd "$WORKSPACE"

# --- PHASE 2: DYNAMIC TARGET ANALYSIS (THE RMA SHIM) ---
echo ">>> [Phase 2] Analyzing RMA Shim for Host Kernel Version & Commit..."
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
rm temp_kern_a.bin

# Invoke our standalone detect_version_magic.sh script to parse and print debug info.
# We also capture its stdout so we can cleanly pull out our parsed Makefile variables!
echo "  [*] Invoking Version Magic Detector..."
DETECTOR_OUT=$(bash "$WORKSPACE/devtools/detect_version_magic.sh")

# Print the beautiful diagnostic block straight to the build output
echo "$DETECTOR_OUT"

# Parse the variables printed by our detector script
K_MAJ=$(echo "$DETECTOR_OUT" | grep "^VERSION" | awk -F'= ' '{print $2}' | tr -d ' ')
K_MIN=$(echo "$DETECTOR_OUT" | grep "^PATCHLEVEL" | awk -F'= ' '{print $2}' | tr -d ' ')
K_SUB=$(echo "$DETECTOR_OUT" | grep "^SUBLEVEL" | awk -F'= ' '{print $2}' | tr -d ' ')
K_EXT=$(echo "$DETECTOR_OUT" | grep "^EXTRAVERSION" | awk -F'= ' '{print $2}' | tr -d ' ')

if [ -z "$K_MAJ" ] || [ -z "$K_MIN" ]; then
    echo "[-] Error: Version Magic Detector could not parse kernel version!"
    exit 1
fi

FULL_VERSION="${K_MAJ}.${K_MIN}.${K_SUB}${K_EXT}"
HOST_VERSION="${K_MAJ}.${K_MIN}"

# Determine preemption requirements based on detector findings
NEEDS_PREEMPT=0
if echo "$DETECTOR_OUT" | grep -q "PREEMPT enabled"; then
    NEEDS_PREEMPT=1
fi

echo "  [+] Discovered Target ChromeOS Kernel Version: $HOST_VERSION"
echo "  [+] Discovered Exact Full Version String: $FULL_VERSION"


# --- PHASE 3: HOST KERNEL HEADERS PREP (WITH VERSION MAGIC SPOOFING) ---
echo ">>> [Phase 3] Preparing Host Kernel Headers & Spoofing Version Magic..."
HOST_KDIR="$WORKSPACE/host_kernel"
mkdir -p "$HOST_KDIR"
cd "$HOST_KDIR"

if [ ! -d ".git" ]; then
    git init
    git remote add origin "$CHROMEOS_KERNEL_REPO"
fi

echo "  [*] Fetching standard generic kernel branch: chromeos-$HOST_VERSION..."
git fetch --depth 1 origin "chromeos-$HOST_VERSION"
git checkout FETCH_HEAD

# ==================================================================
# THE SPOOFING HACK & PREEMPTION / SCM OVERRIDES
# ==================================================================
echo "  [*] Spoofing Kernel Makefile to perfectly match Version Magic: $FULL_VERSION"
sed -i "s/^VERSION.*/VERSION = $K_MAJ/" Makefile
sed -i "s/^PATCHLEVEL.*/PATCHLEVEL = $K_MIN/" Makefile
sed -i "s/^SUBLEVEL.*/SUBLEVEL = $K_SUB/" Makefile
sed -i "s/^EXTRAVERSION.*/EXTRAVERSION = $K_EXT/" Makefile

# CRITICAL VERSION MATCHING FIX:
# Force touch of .scmversion to prevent scripts/setlocalversion from appending a trailing '+' sign!
echo "  [*] Writing SCM version override (.scmversion) to prevent '+' suffix..."
touch .scmversion

echo "  [*] Attempting to extract original .config from vmlinuz.bin..."
if ./scripts/extract-ikconfig "$WORKSPACE/vmlinuz.bin" > .config 2>/dev/null; then
    echo "  [+] Success! Original .config ripped from kernel."
    make olddefconfig
else
    echo "  [!] IKCONFIG not found. Falling back to default config..."
    make defconfig
    
    # Manually match Version Magic if preempt was detected
    if [ $NEEDS_PREEMPT -eq 1 ]; then
        echo "  [*] Enabling CONFIG_PREEMPT to match version magic..."
        ./scripts/config --enable CONFIG_PREEMPT
        ./scripts/config --disable CONFIG_PREEMPT_NONE
        make olddefconfig
    fi
fi

# Force CONFIG_KEXEC off to mirror the locked-down environment
echo "  [*] Disabling CONFIG_KEXEC to ensure module compatibility..."
./scripts/config --disable CONFIG_KEXEC

make olddefconfig

echo "  [*] Generating module headers..."
make modules_prepare -j"$CORES"

# Clean up the extracted kernel image now that we have the headers/config
rm -f "$WORKSPACE/vmlinuz.bin"


# --- PHASE 4: INTERMEDIATE KERNEL BUILD (The Automaton) ---
echo ">>> [Phase 4] Building Intermediate Kernel ($INTERMEDIATE_KERNEL_BRANCH)..."
INT_KDIR="$WORKSPACE/intermediate_kernel"

if [ "$CACHE_HIT" = "true" ] && [ -f "$INT_KDIR/arch/x86/boot/bzImage" ]; then
    echo "  [+] Cached intermediate kernel found! Skipping compilation."
else
    if [ ! -d "$INT_KDIR" ]; then
        git clone --depth 1 -b "$INTERMEDIATE_KERNEL_BRANCH" "$MAINLINE_KERNEL_REPO" "$INT_KDIR"
    fi
    cd "$INT_KDIR"
    make defconfig
    
    # Force CONFIG_KEXEC ON for the jump capability
    ./scripts/config --enable CONFIG_KEXEC
    
    # --- BLINDING THE AUTOMATON ---
    echo "  [*] Disabling Graphics on Automaton to prevent double-init crash..."
    ./scripts/config --disable CONFIG_DRM_AMDGPU
    ./scripts/config --disable CONFIG_FRAMEBUFFER_CONSOLE
    
    # Keep Input enabled in case we add emergency debug shells
    ./scripts/config --enable CONFIG_USB_SUPPORT
    ./scripts/config --enable CONFIG_USB_XHCI_HCD
    ./scripts/config --enable CONFIG_KEYBOARD_CROS_EC
    
    make olddefconfig
    make -j"$CORES" bzImage
fi


# --- PHASE 5: FINAL KERNEL BUILD (The Destination) ---
echo ">>> [Phase 5] Building Final Target Kernel ($FINAL_KERNEL_BRANCH)..."
FIN_KDIR="$WORKSPACE/final_kernel"

if [ "$CACHE_HIT" = "true" ] && [ -f "$FIN_KDIR/arch/x86/boot/bzImage" ]; then
    echo "  [+] Cached final target kernel found! Skipping compilation."
    cd "$FIN_KDIR"
    echo "  [*] Installing cached kernel modules to final rootfs staging..."
    mkdir -p "$WORKSPACE/final_rootfs_busybox/_install"
    make INSTALL_MOD_PATH="$WORKSPACE/final_rootfs_busybox/_install" modules_install
else
    if [ ! -d "$FIN_KDIR" ]; then
        git clone --depth 1 -b "$FINAL_KERNEL_BRANCH" "$MAINLINE_KERNEL_REPO" "$FIN_KDIR"
    fi
    cd "$FIN_KDIR"
    make defconfig
    
    # --- HARDWARE ENABLEMENT FOR DISPLAY & INPUT ---
    echo "  [*] Enabling Target Hardware Configs (DRM, Framebuffer, USB, CROS EC)..."
    ./scripts/config --module CONFIG_DRM_AMDGPU
    ./scripts/config --enable CONFIG_FRAMEBUFFER_CONSOLE
    ./scripts/config --enable CONFIG_USB_SUPPORT
    ./scripts/config --enable CONFIG_USB_XHCI_HCD
    ./scripts/config --enable CONFIG_KEYBOARD_CROS_EC

    # Core Networking & Wireless Stack
    ./scripts/config --enable CONFIG_NET
    ./scripts/config --enable CONFIG_WIRELESS
    ./scripts/config --module CONFIG_CFG80211
    ./scripts/config --module CONFIG_MAC80211

    #grunt 8250 serial drivers and stuff
    ./scripts/config --enable CONFIG_SERIAL_8250
    ./scripts/config --enable CONFIG_SERIAL_8250_CONSOLE
    ./scripts/config --enable CONFIG_SERIAL_8250_PCI
    ./scripts/config --enable CONFIG_SERIAL_8250_ACPI
    ./scripts/config --enable CONFIG_SERIAL_8250_DW

    # Common Chromebook Wi-Fi Drivers
    # grunt wifi drivers
    ./scripts/config --module CONFIG_ATH10K
    ./scripts/config --module CONFIG_ATH10K_PCI
    
    make olddefconfig
    echo "  [*] Compiling Kernel and Modules..."
    make -j"$CORES" bzImage modules
    
    echo "  [*] Installing kernel modules to final rootfs staging..."
    mkdir -p "$WORKSPACE/final_rootfs_busybox/_install"
    make INSTALL_MOD_PATH="$WORKSPACE/final_rootfs_busybox/_install" modules_install
fi


# --- PHASE 6: KEXEC-TOOLS COMPILATION ---
echo ">>> [Phase 6] Building static kexec-tools..."
cd "$WORKSPACE"

if [ "$CACHE_HIT" = "true" ] && [ -f "$WORKSPACE/kexec-tools/build/sbin/kexec" ]; then
    echo "  [+] Cached static kexec-tools binary found! Skipping compilation."
else
    bash ./devtools/setup_kexec_tools.sh
fi


# --- PHASE 7: BUSYBOX COMPILATION (Host & Final) ---
echo ">>> [Phase 7] Building BusyBox Environments..."
BB_DIR="$WORKSPACE/busybox"

if [ "$CACHE_HIT" = "true" ] && [ -d "$BB_DIR/_install" ]; then
    echo "  [+] Cached BusyBox environments found! Skipping compilation."
    echo "  [*] Populating final target installation trees..."
    cd "$BB_DIR"
    mkdir -p "$WORKSPACE/final_rootfs_busybox/_install"
    make CONFIG_PREFIX="$WORKSPACE/final_rootfs_busybox/_install" install
else
    if [ ! -d "$BB_DIR" ]; then
        git clone --depth 1 -b "$BUSYBOX_BRANCH" "$BUSYBOX_REPO" "$BB_DIR" || git clone --depth 1 -b "$BUSYBOX_BRANCH" "$BUSYBOX_REPO_TWO" "$BB_DIR"
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
fi


# --- PHASE 8: OUT-OF-TREE TOOLS COMPILATION ---
echo ">>> [Phase 8] Compiling Out-Of-Tree Kexec Module & Usermode Loader..."
cd "$WORKSPACE/oot-kexec-module"
make clean || true
# Pass our explicitly prepared ChromeOS headers path to the Makefile
make KDIR="$HOST_KDIR"

echo "=========================================================="
echo " [*] DYNAMIC VERIFICATION: FRESH COMPILATION HASH"
echo "=========================================================="
sha256sum "$WORKSPACE/oot-kexec-module/kexec_mod.ko"
echo "=========================================================="

cd "$WORKSPACE/usermode"
gcc -static -o custom_kexec custom_kexec.c 
gcc -static -o finit_loader finit_loader.c

# --- PHASE 8.5: FIRMWARE ACQUISITION ---
echo ">>> [Phase 8.5] Injecting Proprietary Firmware Blobs..."
cd "$WORKSPACE"
bash ./devtools/add_firmware_to_initramfs.sh "$BOARD" "$WORKSPACE/busybox/_install" "$WORKSPACE/final_rootfs_busybox/_install"

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
