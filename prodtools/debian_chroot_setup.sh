#!/bin/bash
# Executes inside the Debian 13 chroot environment to finalize the OS configuration.

set -e

echo "=========================================================="
echo " Executing Debian Chroot Configuration..."
echo "=========================================================="

# 0. Enable non-free firmware repositories
echo "[*] Configuring apt sources for non-free-firmware..."
cat << 'EOF' > /etc/apt/sources.list
deb http://deb.debian.org/debian/ trixie main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian/ trixie main contrib non-free non-free-firmware
EOF

# 1. Update and install core dependencies
echo "[*] Updating apt and installing core dependencies..."
export DEBIAN_FRONTEND=noninteractive
apt-get update

# Install kernel, initramfs tools, networking tools, and utilities
apt-get install -y \
    linux-image-amd64 \
    initramfs-tools \
    whiptail \
    network-manager \
    wpasupplicant \
    cloud-guest-utils \
    e2fsprogs \
    sudo \
    systemd \
    systemd-sysv \
    firmware-amd-graphics

# Force initramfs-tools to include all firmware and drivers (crucial for cross-hardware builds)
sed -i 's/^MODULES=.*/MODULES=most/' /etc/initramfs-tools/initramfs.conf

echo "amdgpu" >> /etc/initramfs-tools/modules
echo "xhci_pci" >> /etc/initramfs-tools/modules
echo "xhci_hcd" >> /etc/initramfs-tools/modules
echo "usb_storage" >> /etc/initramfs-tools/modules
echo "uas" >> /etc/initramfs-tools/modules
echo "dwc3" >> /etc/initramfs-tools/modules
echo "dwc3-pci" >> /etc/initramfs-tools/modules
echo "phy-amd-pt" >> /etc/initramfs-tools/modules


# --- FORCE AMDGPU FIRMWARE INCLUSION ---
echo "[*] Creating initramfs hook to force-pack AMD firmware..."

mkdir -p /etc/initramfs-tools/hooks
cat << 'EOF' > /etc/initramfs-tools/hooks/force_amdgpu
#!/bin/sh
PREREQ=""
prereqs() { echo "$PREREQ"; }
case $1 in
    prereqs) prereqs; exit 0 ;;
esac

. /usr/share/initramfs-tools/hook-functions

# Unconditionally copy the entire amdgpu firmware directory into the initrd
if [ -d /lib/firmware/amdgpu ]; then
    mkdir -p "${DESTDIR}/lib/firmware"
    cp -a /lib/firmware/amdgpu "${DESTDIR}/lib/firmware/"
    echo "  [+] Hook triggered: AMDGPU firmware copied to initrd."
fi
EOF

# Make the hook executable so initramfs-tools actually runs it
chmod +x /etc/initramfs-tools/hooks/force_amdgpu

# Now build the initramfs
echo "[*] Generating final initramfs..."
update-initramfs -u -k all

# 2. Configure /etc/fstab to use our GPT Partition Name
echo "[*] Configuring /etc/fstab for PARTLABEL mounting..."
echo "PARTLABEL=execboot_rootfs:debian  /  ext4  errors=remount-ro  0  1" > /etc/fstab

# 3. Set a default hostname
echo "debian-execboot" > /etc/hostname

# 4. Deploy the First-Boot Setup Script
echo "[*] Deploying /usr/local/bin/firstboot-setup.sh..."
cat << 'EOF' > /usr/local/bin/firstboot-setup.sh
#!/bin/bash

# Redirect I/O directly to tty1 for UI rendering
exec < /dev/tty1 > /dev/tty1 2>&1

echo "=========================================================="
echo " ExecBoot: First Boot Environment Setup"
echo "=========================================================="

# --- Phase 1: Auto-Expand Partition ---
# Dynamically determine the root block device (use -e to evaluate UUIDs/symlinks to real paths)
ROOT_DEV=$(findmnt -n -e -o SOURCE /)

# Extract the base disk (e.g., /dev/sda) and partition number (e.g., 5)
DISK="/dev/$(lsblk -no PKNAME "$ROOT_DEV" | head -n1)"
PARTNUM=$(lsblk -no PARTN "$ROOT_DEV" | head -n1)

# Strip any hidden whitespace or non-numeric characters from the lsblk output
PARTNUM="${PARTNUM//[^0-9]/}"

if [ -n "$DISK" ] && [ -n "$PARTNUM" ]; then
    echo "Expanding $DISK partition $PARTNUM..."
    growpart "$DISK" "$PARTNUM" || true
    resize2fs "$ROOT_DEV" || true
else
    echo "Warning: Could not safely determine root disk for expansion. Skipping..."
fi

# --- Phase 2: Network Initialization ---
# FIX: Changed 'then' to 'do'
while ! ping -c 1 -W 3 deb.debian.org &> /dev/null; do
    if whiptail --title "Network Required" --yesno "No internet connection detected.\n\nDo you need to configure Wi-Fi?" 10 50; then
        nmtui-connect
    else
        whiptail --title "Error" --msgbox "Installation cannot proceed without internet. The system will now reboot." 8 45
        reboot
        exit 1
    fi
done

# --- Phase 3: User Account Provisioning ---
NEW_USER=""
while [ -z "$NEW_USER" ]; do
    NEW_USER=$(whiptail --title "User Creation" --inputbox "Enter a new username (lowercase only):" 10 40 3>&1 1>&2 2>&3)
done

PASSWORD=""
PASSWORD_CONFIRM="x"
# FIX: Ensure password is not empty and that both entries match
while [ -z "$PASSWORD" ] || [ "$PASSWORD" != "$PASSWORD_CONFIRM" ]; do
    PASSWORD=$(whiptail --title "User Creation" --passwordbox "Enter password for $NEW_USER:" 10 40 3>&1 1>&2 2>&3)
    PASSWORD_CONFIRM=$(whiptail --title "User Creation" --passwordbox "Confirm password:" 10 40 3>&1 1>&2 2>&3)

    if [ "$PASSWORD" != "$PASSWORD_CONFIRM" ]; then
        whiptail --title "Error" --msgbox "Passwords do not match. Please try again." 8 40
    fi
done

echo "Creating user $NEW_USER..."
useradd -m -s /bin/bash -G sudo "$NEW_USER"
echo "$NEW_USER:$PASSWORD" | chpasswd

whiptail --title "Success" --msgbox "User $NEW_USER created successfully and added to the sudo group." 8 45

# --- Phase 4: Payload Selection ---
CHOICE=$(whiptail --title "System Setup" --menu "Internet Connected!\n\nChoose a Desktop Environment to install:" 15 50 4 \
"1" "GNOME Desktop" \
"2" "KDE Plasma" \
"3" "XFCE Minimal" \
"4" "CLI Only (Skip)" 3>&1 1>&2 2>&3)

echo "Updating package databases..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y

case $CHOICE in
    1) apt-get install -y task-gnome-desktop ;;
    2) apt-get install -y task-kde-desktop ;;
    3) apt-get install -y task-xfce-desktop ;;
    4|*) echo "Skipping DE installation." ;; # Catch-all for CLI or if user pressed Cancel
esac

# --- Phase 5: Teardown & Handoff ---
echo "Setup complete! Disabling first-boot script..."
systemctl disable firstboot-setup.service

whiptail --title "Complete" --msgbox "Installation finished. Press OK to start your environment." 8 45

# FIX: Only isolate graphical target if a GUI was actually installed
if [[ "$CHOICE" =~ ^[1-3]$ ]]; then
    systemctl isolate graphical.target
else
    # Drop to terminal instead of hanging trying to load a missing GUI
    systemctl isolate multi-user.target 
fi
EOF

chmod +x /usr/local/bin/firstboot-setup.sh

# 5. Deploy the Systemd Service
echo "[*] Deploying /etc/systemd/system/firstboot-setup.service..."
cat << 'EOF' > /etc/systemd/system/firstboot-setup.service
[Unit]
Description=First Boot TUI Setup Script
After=network.target NetworkManager.service systemd-user-sessions.service
Before=getty@tty1.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/firstboot-setup.sh
StandardInput=tty-force
StandardOutput=inherit
StandardError=inherit
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
TimeoutSec=0

[Install]
WantedBy=multi-user.target
EOF

# 6. Enable the first-boot service
echo "[*] Arming the first-boot service..."
systemctl enable firstboot-setup.service

echo "[*] Installing Blind Log Dumper service..."

# 1. Create the dump script
cat << 'EOF' > /usr/local/bin/dump-logs.sh
#!/bin/bash
# Wait 45 seconds to let all display drivers and background services settle
sleep 45

# Create/Overwrite the log file in the root directory
LOGFILE="/root/boot_dmesg.log"

echo "================ DMESG ================" > $LOGFILE
dmesg >> $LOGFILE
echo -e "\n================ LSPCI ================" >> $LOGFILE
lspci -k >> $LOGFILE
echo -e "\n================ JOURNAL ================" >> $LOGFILE
journalctl -b -n 500 --no-pager >> $LOGFILE

# Force flush all cached writes to the physical USB blocks
sync
sync
EOF

chmod +x /usr/local/bin/dump-logs.sh

# 2. Create the systemd service to run it on boot
cat << 'EOF' > /etc/systemd/system/blind-logger.service
[Unit]
Description=Blind Log Dumper for Headless Debugging
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/dump-logs.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# 3. Enable the service so it runs automatically
systemctl enable blind-logger.service

echo "[+] Blind Log Dumper installed and enabled."

echo "[*] Creating and setting up user accounts..."
echo "root:root" | chpasswd

useradd -m -s /bin/bash debuguser
echo "debuguser:debug" | chpasswd
usermod -aG sudo debuguser

# 7. Cleanup
echo "[*] Cleaning up chroot environment..."
apt-get clean
rm -rf /var/lib/apt/lists/*

echo "=========================================================="
echo " [SUCCESS] Debian chroot configuration complete!"
echo "=========================================================="
