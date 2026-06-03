#!/bin/bash
# Script to clone, checkout a stable tag, configure, and statically compile kexec-tools.
# Exit immediately if any command fails
set -e

# Dynamically calculate the workspace root folder relative to this script's directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$SCRIPT_DIR/.." && pwd)"
CORES=$(nproc)

echo "=========================================================="
echo " Starting Kexec-Tools Clone & Compilation Pipeline"
echo "=========================================================="
echo "[*] Project Workspace: $WORKSPACE"

# 1. Install required host compilation dependencies if possible
echo "[*] Step 1: Checking for build dependencies..."
if command -v apt-get >/dev/null 2>&1; then
    echo "  [+] Host is running Debian/Ubuntu. Ensuring autoconf and libtool are installed..."
    # Running with sudo if available, but allowing it to fail gracefully if we lack privileges
    sudo apt-get update -qq && sudo apt-get install -y autoconf automake libtool make gcc -y || echo "  [!] Warning: Non-root or offline. Assuming build packages are present."
else
    echo "  [!] Please ensure autoconf, automake, and libtool are installed on your system."
fi

# 2. Clone the official kexec-tools repository if it doesn't exist
TARGET_DIR="$WORKSPACE/kexec-tools"
KEXEC_REPO="git://git.kernel.org/pub/scm/utils/kernel/kexec/kexec-tools.git"

if [ ! -d "$TARGET_DIR" ]; then
    echo "[*] Step 2: Cloning kexec-tools repository..."
    git clone "$KEXEC_REPO" "$TARGET_DIR"
else
    echo "[+] kexec-tools repository already exists at: $TARGET_DIR"
fi

cd "$TARGET_DIR"

# 3. Fetch all tags and checkout a stable version (e.g., v2.0.28 or v2.0.29)
echo "[*] Step 3: Fetching tags and checking out stable version..."
git fetch --tags

# Get the latest stable v2.0.x release tag dynamically
STABLE_TAG=$(git tag -l "v2.0.*" | sort -V | tail -n1)

if [ -z "$STABLE_TAG" ]; then
    STABLE_TAG="v2.0.28" # Fallback to a proven stable version
fi

echo "[+] Selected stable release tag: $STABLE_TAG"
git checkout "$STABLE_TAG" -B stable-build

# 4. Bootstrap and Configure the source tree
echo "[*] Step 4: Bootstrapping build system..."
./bootstrap

echo "[*] Step 5: Configuring compilation flags for a STATIC build..."
# LDFLAGS=-static is crucial for running without glibc dependencies inside our initramfs.
# We set prefix to a local 'build' folder inside kexec-tools so we don't mess with host paths.
./configure --prefix="$TARGET_DIR/build" LDFLAGS="-static"

# 5. Compile and install locally
echo "[*] Step 6: Compiling kexec-tools with $CORES threads..."
make -j"$CORES"

echo "[*] Step 7: Performing local installation..."
mkdir -p "$TARGET_DIR/build"
make install

# 6. Verify the binary
STATIC_BIN="$TARGET_DIR/build/sbin/kexec"
if [ -f "$STATIC_BIN" ]; then
    echo "=========================================================="
    echo "[SUCCESS] Static kexec binary built successfully!"
    echo "Location: $STATIC_BIN"
    file "$STATIC_BIN"
    echo "=========================================================="
else
    echo "[-] Error: Static binary compilation failed."
    exit 1
fi
