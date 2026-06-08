#!/bin/bash
# Dispatcher script to route firmware acquisition based on the active BOARD.
set -e

BOARD="$1"
HOST_DIR="$2"
FINAL_DIR="$3"

echo "=========================================================="
echo " [FIRMWARE INJECTION] Resolving dependencies for board: $BOARD"
echo "=========================================================="

if [ -z "$BOARD" ]; then
    echo "[-] Warning: BOARD variable not set! Skipping firmware injection."
    exit 0
fi

if [ -z "$HOST_DIR" ] || [ -z "$FINAL_DIR" ]; then
    echo "[-] Error: Missing target directory paths for firmware injection."
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOARD_SCRIPT="$SCRIPT_DIR/add_firmware_to_initramfs/${BOARD}.sh"

if [ -f "$BOARD_SCRIPT" ]; then
    echo "[+] Found firmware script for $BOARD. Executing..."
    bash "$BOARD_SCRIPT" "$HOST_DIR" "$FINAL_DIR"
else
    echo "[!] No specific firmware script found for $BOARD ($BOARD_SCRIPT)."
    echo "[!] Skipping external firmware injection."
fi