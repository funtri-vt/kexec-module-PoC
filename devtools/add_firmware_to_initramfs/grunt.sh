#!/bin/bash
# Grunt specific firmware fetcher (AMD Stoney Ridge APU)
# Uses configuration JSON and automated recovery extraction tools.
set -e

HOST_DIR="$1"
FINAL_DIR="$2"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_FILE="$SCRIPT_DIR/grunt.json"

echo "=========================================================="
echo " [*] Executing Configuration-Driven Grunt Firmware Fetcher"
echo "=========================================================="

# Ensure jq is installed
if ! command -v jq >/dev/null 2>&1; then
    echo "[-] Error: 'jq' is required to parse the board configurations."
    exit 1
fi

# 1. Parse JSON configuration
RECOVERY_URL=$(jq -r '.recovery_url' "$CONFIG_FILE")
FIRMWARE_SUBPATH=$(jq -r '.firmware_subpath' "$CONFIG_FILE")
readarray -t STONEY_FILES < <(jq -r '.files[]' "$CONFIG_FILE")

echo "  [+] Loaded recovery URL: $RECOVERY_URL"
echo "  [+] Target firmware path: $FIRMWARE_SUBPATH"

# 2. Setup workspaces
TEMP_DOWNLOAD_DIR="/tmp/firmware_download"
TEMP_EXTRACT_DIR="/tmp/firmware_extracted"
mkdir -p "$TEMP_DOWNLOAD_DIR"
mkdir -p "$TEMP_EXTRACT_DIR"

ZIP_NAME=$(basename "$RECOVERY_URL")
ZIP_PATH="$TEMP_DOWNLOAD_DIR/$ZIP_NAME"

# Create destination directories
mkdir -p "${HOST_DIR}/${FIRMWARE_SUBPATH}"
mkdir -p "${FINAL_DIR}/${FIRMWARE_SUBPATH}"

# 3. Download the Recovery Zip
echo "  [*] Downloading official ChromeOS recovery image..."
wget -q --show-progress -O "$ZIP_PATH" "$RECOVERY_URL"

# 4. Invoke the generic recovery mounter and extractor
echo "  [*] Calling generic recovery image partition extractor..."
sudo bash "$WORKSPACE/devtools/extract_and_mount_recov_root_a.sh" "$ZIP_PATH" "$TEMP_EXTRACT_DIR" "$FIRMWARE_SUBPATH"

# 5. Extract and filter the configured files from the mounted workspace
echo "  [*] Copying specified firmware files into targets..."
EXTRACTED_SRC_DIR="$TEMP_EXTRACT_DIR/$(basename "$FIRMWARE_SUBPATH")"

for file in "${STONEY_FILES[@]}"; do
    SRC_FILE="$EXTRACTED_SRC_DIR/$file"
    if [ -f "$SRC_FILE" ]; then
        echo "      -> Packing $file"
        cp "$SRC_FILE" "${HOST_DIR}/${FIRMWARE_SUBPATH}/$file"
        cp "$SRC_FILE" "${FINAL_DIR}/${FIRMWARE_SUBPATH}/$file"
    else
        echo "      [!] Warning: Configured file $file was not found in recovery rootfs!"
    fi
done

# 6. Clean up temporary download workspace
echo "  [*] Cleaning up download directories..."
rm -rf "$TEMP_DOWNLOAD_DIR"
rm -rf "$TEMP_EXTRACT_DIR"

echo "  [+] Grunt firmware pipeline successfully completed!"
echo "=========================================================="