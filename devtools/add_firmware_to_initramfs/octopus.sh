#!/bin/bash
# Octopus specific firmware fetcher (Intel Gemini Lake / GLK)
set -e

HOST_DIR="$1"
FINAL_DIR="$2"

echo "  [*] Executing Octopus (Intel Gemini Lake) firmware fetcher..."

# 1. Create target directories
mkdir -p "${HOST_DIR}/lib/firmware/i915"
mkdir -p "${FINAL_DIR}/lib/firmware/i915"

# 2. Define the upstream Linux Firmware repository URL for Intel i915
BASE_URL="https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/i915"

# 3. Define the specific microcode binaries required for Gemini Lake (GLK)
# DMC handles low-power display states (Critical for fixing static)
# GuC handles graphics scheduling
# HuC handles media decoding/encoding
GLK_FILES=(
    "glk_dmc_ver1_04.bin"
    "glk_guc_70.1.1.bin"
    "glk_huc_4.0.0.bin"
)

# 4. Fetch and place the files
echo "  [*] Downloading Intel i915 GLK binaries from upstream..."

for file in "${GLK_FILES[@]}"; do
    echo "      -> Fetching $file..."
    # Download directly into the Host initramfs directory
    wget -q --show-progress -O "${HOST_DIR}/lib/firmware/i915/${file}" "${BASE_URL}/${file}"
    
    # Mirror the downloaded file to the Final Rootfs directory
    cp "${HOST_DIR}/lib/firmware/i915/${file}" "${FINAL_DIR}/lib/firmware/i915/${file}"
    chmod 644 "${HOST_DIR}/lib/firmware/i915/${file}"
    chmod 644 "${FINAL_DIR}/lib/firmware/i915/${file}"
done

echo "  [+] Octopus firmware injection complete!"