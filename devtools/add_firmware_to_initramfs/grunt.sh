#!/bin/bash
# Grunt specific firmware fetcher (AMD Stoney Ridge APU)
set -e

HOST_DIR="$1"
FINAL_DIR="$2"

echo "  [*] Executing Grunt (Stoney Ridge) firmware fetcher..."

# 1. Create target directories
mkdir -p "${HOST_DIR}/lib/firmware/amdgpu"
mkdir -p "${FINAL_DIR}/lib/firmware/amdgpu"

# 2. Define the upstream Linux Firmware repository URL
BASE_URL="https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/amdgpu"

# 3. Define the specific microcode binaries required for Stoney Ridge
STONEY_FILES=(
    "stoney_ce.bin"
    "stoney_me.bin"
    "stoney_mec.bin"
    "stoney_pfp.bin"
    "stoney_rlc.bin"
    "stoney_sdma.bin"
    "stoney_uvd.bin"
    "stoney_vce.bin"
)

# 4. Fetch and place the files
echo "  [*] Downloading AMDGPU Stoney binaries from upstream..."

for file in "${STONEY_FILES[@]}"; do
    echo "      -> Fetching $file..."
    # Download directly into the Host initramfs directory
    wget -q --show-progress -O "${HOST_DIR}/lib/firmware/amdgpu/${file}" "${BASE_URL}/${file}"
    
    # Mirror the downloaded file to the Final Rootfs directory
    cp "${HOST_DIR}/lib/firmware/amdgpu/${file}" "${FINAL_DIR}/lib/firmware/amdgpu/${file}"
done

echo "  [+] Grunt firmware injection complete!"