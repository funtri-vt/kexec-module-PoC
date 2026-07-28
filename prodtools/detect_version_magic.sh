#!/bin/bash
# Diagnostic and production tool to parse an extracted kernel bzImage and
# output the exact configuration parameters needed to match the Version Magic.
set -e

# Calculate workspace root relative to this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$SCRIPT_DIR/.." && pwd)"

# Target raw kernel image to inspect
VMLINUZ_PATH="$WORKSPACE/extracted/vmlinuz.bin"

if [ ! -f "$VMLINUZ_PATH" ]; then
    # Fallback to check workspace root if not found in extracted/
    VMLINUZ_PATH="$WORKSPACE/vmlinuz.bin"
fi

echo "=========================================================="
echo "      Dynamic Kernel Version Magic Analyzer"
echo "=========================================================="

if [ ! -f "$VMLINUZ_PATH" ]; then
    echo "[-] Error: bzImage file not found at: $VMLINUZ_PATH"
    echo "    Please make sure you have extracted the kernel first!"
    exit 1
fi

echo "[*] Analyzing bzImage: $VMLINUZ_PATH"
FILE_OUTPUT=$(file "$VMLINUZ_PATH")
echo "  [+] Raw Header: $FILE_OUTPUT"

# Extract full version string (e.g., 4.14.75-07790-ga53de141176c)
FULL_VERSION=$(echo "$FILE_OUTPUT" | grep -o -E "version [^ ]+" | awk '{print $2}')

if [ -z "$FULL_VERSION" ]; then
    echo "[-] Error: Failed to extract version string from bzImage header."
    exit 1
fi

# Parsing the version segments
K_MAJ=$(echo "$FULL_VERSION" | cut -d. -f1)
K_MIN=$(echo "$FULL_VERSION" | cut -d. -f2)
K_SUB=$(echo "$FULL_VERSION" | cut -d. -f3 | cut -d- -f1)

# Safely extract the EXTRAVERSION segment (everything after the first hyphen)
if echo "$FULL_VERSION" | grep -q "-"; then
    K_EXT="-$(echo "$FULL_VERSION" | cut -d- -f2-)"
else
    K_EXT=""
fi

echo ""
echo "=========================================================="
echo "               Makefile Parameter Map"
echo "=========================================================="
echo "VERSION      = $K_MAJ"
echo "PATCHLEVEL   = $K_MIN"
echo "SUBLEVEL     = $K_SUB"
echo "EXTRAVERSION = $K_EXT"
echo "=========================================================="
echo ""

# Verify if preempt is enabled in the host kernel
if echo "$FILE_OUTPUT" | grep -q -i "preempt"; then
    echo "[*] Preemption Status: PREEMPT enabled"
    echo "    Make sure to set: CONFIG_PREEMPT=y"
else
    echo "[*] Preemption Status: Standard SMP (No Preempt)"
    echo "    Make sure to set: CONFIG_PREEMPT_NONE=y"
fi

echo ""
echo "=========================================================="
echo "             How to Apply in Your Build Pipeline"
echo "=========================================================="
echo "1. Apply the sed commands to the host kernel Makefile:"
echo "   sed -i 's/^VERSION = .*/VERSION = '$K_MAJ'/' Makefile"
echo "   sed -i 's/^PATCHLEVEL = .*/PATCHLEVEL = '$K_MIN'/' Makefile"
echo "   sed -i 's/^SUBLEVEL = .*/SUBLEVEL = '$K_SUB'/' Makefile"
echo "   sed -i 's/^EXTRAVERSION = .*/EXTRAVERSION = '$K_EXT'/' Makefile"
echo ""
echo "2. CRITICAL PREEMPTION OVERRIDE (to prevent trailing '+' sign):"
echo "   To stop the kernel build system from appending '+', run:"
echo "   touch .scmversion"
echo "   (This forces scripts/setlocalversion to completely bypass Git-based suffixes!)"
echo "=========================================================="
