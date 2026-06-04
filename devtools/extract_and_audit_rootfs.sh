#!/bin/bash
# Recursive Rootfs Extraction and Binary Integrity Auditor Script
#
# This script extracts:
# 1. The Host Kernel (from partition 2)
# 2. The Host Initramfs (partition 4 structure)
# 3. Standalone custom injected payloads
# 4. The target kernel, module, and intermediate / final rootfs layers
#
# It then audits all compiled binaries inside the extracted layers to verify
# static compilation vs. dynamic linker/library path configurations to prevent
# "Failed to execute /init (error -2)" failures.
#
# RUN THIS SCRIPT WITH SUDO: sudo ./devtools/extract_and_audit_rootfs.sh <path_to_shim.bin>
#
# Exit immediately if any command fails
set -e

# Dynamically calculate the workspace root folder relative to this script's directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$SCRIPT_DIR/.." && pwd)"

SHIM_IMG="$1"
EXTRACT_DIR="$WORKSPACE/extracted"
MOUNT_DIR="/tmp/shimboot_extract_mount"
AUDIT_LOG="$EXTRACT_DIR/audit_report.txt"

# Track loop mapping state for emergency cleanup trap
MAPPED=0

# --- EMERGENCY CLEANUP TRAP ---
cleanup() {
    echo ""
    echo "=========================================================="
    echo "[*] Performing teardown and cleaning up environment..."
    
    if [ -d "$MOUNT_DIR" ]; then
        if mountpoint -q "$MOUNT_DIR" 2>/dev/null; then
            echo "  [*] Unmounting $MOUNT_DIR..."
            umount -f "$MOUNT_DIR" 2>/dev/null || umount -l "$MOUNT_DIR" 2>/dev/null || true
        fi
        echo "  [*] Removing temporary mount folder..."
        rm -rf "$MOUNT_DIR"
    fi

    if [ $MAPPED -eq 1 ]; then
        echo "  [*] Releasing loopback partitions for $SHIM_IMG..."
        kpartx -d "$SHIM_IMG" 2>/dev/null || true
    fi
    echo "  [+] Cleanup complete."
    echo "=========================================================="
}

# Bind cleanup to EXIT signals
trap cleanup EXIT

# --- PRE-FLIGHT CHECKS ---
if [ -z "$SHIM_IMG" ]; then
    echo "[-] Error: Please specify the path to your shimboot .bin file."
    echo "    Usage: sudo $0 <path_to_shimboot_image.bin>"
    exit 1
fi

if [ "$EUID" -ne 0 ]; then
    echo "[-] Error: This script must be run as root (sudo) to map loopback devices and mount partitions."
    exit 1
fi

if [ ! -f "$SHIM_IMG" ]; then
    echo "[-] Error: Specified shimboot image does not exist: $SHIM_IMG"
    exit 1
fi

echo "=========================================================="
echo " Preparing Recursive Extraction & Rootfs Integrity Audit"
echo "=========================================================="
echo "[*] Shim Image: $SHIM_IMG"
echo "[*] Workspace Folder: $WORKSPACE"
echo "[*] Target Extraction Folder: $EXTRACT_DIR"
echo ""

# Setup directories cleanly
rm -rf "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR/host_initramfs_root"
mkdir -p "$EXTRACT_DIR/target_initrd_root"

# Start Audit Log
echo "==========================================================" > "$AUDIT_LOG"
echo " ROOTFS FORENSICS INTEGRITY AUDIT REPORT" >> "$AUDIT_LOG"
echo " Date: $(date)" >> "$AUDIT_LOG"
echo " Image: $SHIM_IMG" >> "$AUDIT_LOG"
echo "==========================================================" >> "$AUDIT_LOG"

# --- STEP 1: EXTRACT HOST KERNEL FROM PARTITION 2 (KERN-A) ---
echo "[*] Step 1: Extracting Host Kernel from Partition 2 (Kern-A)..."
PART2_START=$(cgpt show -i 2 -b "$SHIM_IMG")
PART2_SIZE=$(cgpt show -i 2 -s "$SHIM_IMG")

if [ -n "$PART2_START" ] && [ -n "$PART2_SIZE" ]; then
    dd if="$SHIM_IMG" of="/tmp/temp_kern_a.bin" bs=512 skip="$PART2_START" count="$PART2_SIZE" status=none
    
    if command -v futility >/dev/null 2>&1; then
        if futility vbutil_kernel --get-vmlinuz /tmp/temp_kern_a.bin --vmlinuz-out "$EXTRACT_DIR/vmlinuz.bin" 2>/dev/null; then
            echo "  [+] Success! Host kernel extracted to: $EXTRACT_DIR/vmlinuz.bin"
        else
            echo "  [!] Warning: Failed to strip signed vblock wrapper using futility. Saving raw partition bin..."
            cp /tmp/temp_kern_a.bin "$EXTRACT_DIR/vmlinuz_raw.bin"
        fi
    else
        echo "  [!] futility not installed. Saving raw partition binary..."
        cp /tmp/temp_kern_a.bin "$EXTRACT_DIR/vmlinuz_raw.bin"
    fi
    rm -f /tmp/temp_kern_a.bin
else
    echo "  [-] Error: Could not parse Partition 2 coordinates."
    exit 1
fi

# --- STEP 2: DETECT AND MAP GPT PARTITIONS VIA KPARTX ---
echo "[*] Step 2: Mapping GPT partitions from raw image..."
MAP_OUTPUT=$(kpartx -av "$SHIM_IMG")
MAPPED=1

LOOP_DEV=$(echo "$MAP_OUTPUT" | grep -o 'loop[0-9]\+' | head -n1)
if [ -z "$LOOP_DEV" ]; then
    echo "[-] Error: Failed to setup loopback device mapping."
    exit 1
fi

TARGET_PART="/dev/mapper/${LOOP_DEV}p4"

# Validate that Partition 4 contains an ext4 filesystem
if ! blkid "$TARGET_PART" | grep -q "ext4"; then
    echo "[-] Error: Partition 4 is not formatted as ext4 or is unreadable."
    exit 1
fi

# --- STEP 3: MOUNT TARGET PARTITION 4 ---
echo "[*] Step 3: Mounting Partition 4..."
mkdir -p "$MOUNT_DIR"
mount -o ro "$TARGET_PART" "$MOUNT_DIR"
echo "  [+] Mounted successfully at $MOUNT_DIR"

# --- STEP 4: EXTRACT INTERMEDIATE (HOST) INITRAMFS ---
echo "[*] Step 4: Extracting and unpacking Intermediate (Host) Initramfs..."
cd "$MOUNT_DIR"
# Unpack host partition structure directly to filesystem directories for analysis
cp -a . "$EXTRACT_DIR/host_initramfs_root/"
echo "  [+] Intermediate rootfs extracted cleanly to: $EXTRACT_DIR/host_initramfs_root"

# --- STEP 5: DECOMPRESS TARGET INITRD PAYLOAD ---
echo "[*] Step 5: Finding and unpacking nested Target Initrd..."
TARGET_INITRD_PATH="$EXTRACT_DIR/host_initramfs_root/boot/target_initrd.cpio.gz"

if [ -f "$TARGET_INITRD_PATH" ]; then
    echo "  [*] Decompressing target_initrd.cpio.gz..."
    cd "$EXTRACT_DIR/target_initrd_root"
    zcat "$TARGET_INITRD_PATH" | cpio -idmv --no-absolute-filenames > /dev/null 2>&1 || true
    echo "  [+] Target initrd extracted cleanly to: $EXTRACT_DIR/target_initrd_root"
else
    echo "  [!] Warning: target_initrd.cpio.gz not found inside Partition 4 payload tree."
fi

# --- STEP 6: EXECUTE STATIC LINKAGE AND SYSTEM INTEGRITY FORENSICS ---
echo "[*] Step 6: Performing deep security audit of extracted targets..."
echo "" >> "$AUDIT_LOG"
echo "=== TARGET INITRD AUDIT ===" >> "$AUDIT_LOG"

audit_binary() {
    local bin_path="$1"
    local bin_label="$2"
    if [ -f "$bin_path" ] || [ -L "$bin_path" ]; then
        echo "--------------------------------------------------------" >> "$AUDIT_LOG"
        echo "Binary Audit: $bin_label ($bin_path)" >> "$AUDIT_LOG"
        
        # Check if the binary is a symbolic link
        if [ -L "$bin_path" ]; then
            local target_symlink=$(readlink "$bin_path")
            echo "  Type: Symlink" >> "$AUDIT_LOG"
            echo "  Points to: $target_symlink" >> "$AUDIT_LOG"
            
            # Warn if symlink has absolute system path targeting build-host directories
            if [[ "$target_symlink" == /* ]]; then
                echo "  [!] WARNING: Absolute symlink detected. This may fail on device boot!" >> "$AUDIT_LOG"
            fi
        else
            echo "  Type: Executable / Script File" >> "$AUDIT_LOG"
            
            # Print physical file attributes (Checks for static linkage)
            local file_info=$(file "$bin_path")
            echo "  File Details: $file_info" >> "$AUDIT_LOG"
            
            # Check shebang for scripts
            if head -n 1 "$bin_path" | grep -q '^#!'; then
                local shebang=$(head -n 1 "$bin_path")
                echo "  Script Shebang: $shebang" >> "$AUDIT_LOG"
                
                # Check for carriage return characters
                if head -n 1 "$bin_path" | xxd | grep -q '0d'; then
                    echo "  [!] CRITICAL: Script contains DOS/Windows carriage returns (CRLF)!" >> "$AUDIT_LOG"
                fi
                
                # Extract requested interpreter path
                local interpreter=$(echo "$shebang" | sed -r 's/^#! *([^ ]+).*/\1/')
                echo "  Requested Interpreter: $interpreter" >> "$AUDIT_LOG"
            fi
            
            # Check for dynamic linking issues
            if echo "$file_info" | grep -q "dynamically linked"; then
                echo "  [!] WARNING: Binary is DYNAMICALLY LINKED!" >> "$AUDIT_LOG"
                
                if command -v ldd >/dev/null 2>&1; then
                    echo "  Libraries Required:" >> "$AUDIT_LOG"
                    ldd "$bin_path" | sed 's/^/    /' >> "$AUDIT_LOG"
                fi
            else
                echo "  Link Status: OK (Statically Compiled Binary)" >> "$AUDIT_LOG"
            fi
        fi
    else
        echo "--------------------------------------------------------" >> "$AUDIT_LOG"
        echo "Binary Audit: $bin_label ($bin_path) -> [MISSING]" >> "$AUDIT_LOG"
    fi
}

# Audit Host (Intermediate) Initramfs Layer
echo "=== INTERMEDIATE HOST INITRAMFS FORENSICS ===" >> "$AUDIT_LOG"
audit_binary "$EXTRACT_DIR/host_initramfs_root/init" "Base Init Process"
audit_binary "$EXTRACT_DIR/host_initramfs_root/bin/busybox" "Busybox Executable"
audit_binary "$EXTRACT_DIR/host_initramfs_root/bin/sh" "System Shell Interpreter"
audit_binary "$EXTRACT_DIR/host_initramfs_root/bin/finit_loader" "Dynamic Module Loader"

# Audit Target (Final) Initramfs Layer
echo "" >> "$AUDIT_LOG"
echo "=== FINAL TARGET INITRD FORENSICS ===" >> "$AUDIT_LOG"
audit_binary "$EXTRACT_DIR/target_initrd_root/init" "Final Target Init Process"
audit_binary "$EXTRACT_DIR/target_initrd_root/bin/busybox" "Final Busybox Executable"
audit_binary "$EXTRACT_DIR/target_initrd_root/bin/sh" "Final System Shell Interpreter"

# Return to workspace context
cd "$WORKSPACE"

echo "=========================================================="
echo " [SUCCESS] EXTRACTION AND Deep Audit Completed!"
echo "--------------------------------------------------------"
echo "  All intermediate and target systems have been extracted."
echo "  Review the audit report file for dynamic linking and shell errors:"
echo "  -> $AUDIT_LOG"
echo ""
cat "$AUDIT_LOG"
echo "=========================================================="