#!/bin/bash
# Executes inside the Debian 13 chroot environment to finalize the OS configuration.

set -e

BOARD_ID="$1"

echo "=========================================================="
echo " Executing Debian Chroot Configuration for board $BOARD_ID..."
echo "=========================================================="

# 0. Enable non-free firmware repositories (using HTTP temporarily for bootstrapping)
echo "[*] Configuring temporary HTTP apt sources for bootstrapping..."
cat << 'EOF' > /etc/apt/sources.list
deb http://deb.debian.org/debian/ trixie main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian/ trixie main contrib non-free non-free-firmware
EOF

# 1. Update and install core dependencies
echo "[*] Updating apt and installing core dependencies..."
export DEBIAN_FRONTEND=noninteractive
apt-get install -y ca-certificates
# 1.5 Switch all repositories to HTTPS now that certificates are available
echo "[*] Switching all repositories to HTTPS for maximum security..."
cat << 'EOF' > /etc/apt/sources.list
deb https://deb.debian.org/debian/ trixie main contrib non-free non-free-firmware
deb-src https://deb.debian.org/debian/ trixie main contrib non-free non-free-firmware

deb https://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
deb-src https://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
EOF

# Refresh package lists using the secure HTTPS connection
apt-get update

# Install kernel, initramfs tools, networking tools, and utilities
apt-get install -y \
    dialog \
    network-manager \
    wpasupplicant \
    cloud-guest-utils \
    e2fsprogs \
    sudo \
    systemd \
    systemd-sysv \
    firmware-amd-graphics \
    firmware-atheros \
    alsa-ucm-conf \
    firmware-misc-nonfree \
    cloud-utils \
    zram-tools \
    command-not-found \
    bash-completion \
    libfuse2 \
    libfuse3-* \
    initramfs-tools \
    linux-image-amd64 \
    linux-headers-amd64

apt-get upgrade -y
# Force initramfs-tools to include all firmware and drivers (crucial for cross-hardware builds)
# sed -i 's/^MODULES=.*/MODULES=most/' /etc/initramfs-tools/initramfs.conf

echo "amdgpu" >> /etc/initramfs-tools/modules
echo "xhci_pci" >> /etc/initramfs-tools/modules
echo "xhci_hcd" >> /etc/initramfs-tools/modules
echo "usb_storage" >> /etc/initramfs-tools/modules
echo "uas" >> /etc/initramfs-tools/modules
echo "dwc3" >> /etc/initramfs-tools/modules
echo "dwc3-pci" >> /etc/initramfs-tools/modules
echo "phy-amd-pt" >> /etc/initramfs-tools/modules
echo "hid_generic" >> /etc/initramfs-tools/modules
echo "usbhid" >> /etc/initramfs-tools/modules
echo "i2c_hid" >> /etc/initramfs-tools/modules
echo "i2c_hid_acpi" >> /etc/initramfs-tools/modules
echo "i2c_amd_mp2" >> /etc/initramfs-tools/modules

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

# ==========================================
# DIALOG UI THEME CHEAT SHEET FOR FUTURE REFERENCE
# Syntax: parameter = (FOREGROUND, BACKGROUND, HIGHLIGHT)
# ==========================================
#
# 1. FOREGROUND: The color of the text or the border line itself.
# 2. BACKGROUND: The color of the space immediately behind the text/border.
# 3. HIGHLIGHT:  Accepts 'ON' or 'OFF'. 
#                - ON turns on the "bright" or "bold" ANSI attribute.
#                - OFF leaves the color flat/standard.
#
# AVAILABLE COLORS:
# BLACK, RED, GREEN, YELLOW, BLUE, MAGENTA, CYAN, WHITE
#
# EXAMPLES:
# screen_color = (CYAN,BLUE,ON)
#   - Text/Patterns: Bright Cyan (Because HIGHLIGHT is ON)
#   - Background: Standard Blue
#   - Result: The void behind the dialog boxes will be blue, covered in bright cyan drop-shadows or patterns.
#
# dialog_color = (BLACK,WHITE,OFF)
#   - Text: Standard Black (Because HIGHLIGHT is OFF)
#   - Background: Standard White
#   - Result: The main box will look like black text on a flat white piece of paper.
# ==========================================

# 3.5 Deploy Global UI Theme for Dialog
echo "[*] Creating global dialog theme..."
cat << 'EOF' > /etc/execboot-theme.rc
# ==========================================
# ExecBoot Dialog UI Theme
# Colors: BLACK, RED, GREEN, YELLOW, BLUE, MAGENTA, CYAN, WHITE
# Format: (foreground, background, highlight)
# ==========================================

# Enable custom colors
use_colors = ON

# Screen background (The void behind the dialog boxes)
screen_color = (CYAN,BLUE,ON)

# The dialog box background and standard text
dialog_color = (BLACK,WHITE,OFF)

# The title text at the top of the box
title_color = (BLUE,WHITE,ON)

# The border of the dialog box
border_color = (WHITE,WHITE,ON)

# Buttons (OK, Cancel, Yes, No)
button_active_color = (WHITE,BLUE,ON)
button_inactive_color = (BLACK,WHITE,OFF)

# Progress bar / Gauge colors
gauge_color = (WHITE,BLUE,ON)
EOF

cat << 'EOF' > /usr/local/bin/install_helper_funcs.sh
#!/bin/bash

# Apply the global UI theme to all dialog commands(fine to put here as this is included by both scripts)
export DIALOGRC="/etc/execboot-theme.rc"

install_with_progress() {
    local title="$1"
    shift
    local args=("$@")

    (
        export DEBIAN_FRONTEND=noninteractive
        apt-get install -y -o APT::Status-Fd=3 "${args[@]}" 3>&1 1>/dev/tty3 2>&1 | \
        awk -F: '
        BEGIN { last_time = systime() }
        
        /^dlstatus:/ {
            pct = int($3 * 0.50)
            desc = $4
            for (i=5; i<=NF; i++) { desc = desc ":" $i }
            sub(/ \([^\)]+ remaining\)/, "", desc)
            
            now = systime()
            # STRICT DEBOUNCE: Only update once per second, OR if we hit exactly 50% (end of download phase)
            if (now - last_time >= 1 || pct == 50) {
                printf "XXX\n%d\n[Downloading] %s\nXXX\n", pct, substr(desc, 1, 55)
                fflush()
                last_time = now
            }
        }
        /^pmstatus:/ {
            pct = 50 + int($3 * 0.50)
            desc = $4
            for (i=5; i<=NF; i++) { desc = desc ":" $i }
            
            now = systime()
            # STRICT DEBOUNCE: Only update once per second, OR if we hit exactly 100%
            if (now - last_time >= 1 || pct == 100) {
                printf "XXX\n%d\n[Installing] %s\nXXX\n", pct, substr(desc, 1, 55)
                fflush()
                last_time = now
            }
        }'
    ) | dialog --title "$title" --gauge "Resolving dependencies (This may take several minutes)..." 10 75 0
}

update_with_progress() {
    local title="${1:-Updating Package Lists}"
    (
        apt-get update -y -o APT::Status-Fd=3 3>&1 1>/dev/tty3 2>&1 | \
        awk -F: '
        BEGIN { last_time = systime() }
        
        /^dlstatus:/ {
            pct = int($3 * 0.50)
            desc = $4
            for (i=5; i<=NF; i++) { desc = desc ":" $i }
            sub(/ \([^\)]+ remaining\)/, "", desc)
            
            now = systime()
            if (now - last_time >= 1 || pct == 50) {
                printf "XXX\n%d\n[Downloading] %s\nXXX\n", pct, substr(desc, 1, 55)
                fflush()
                last_time = now
            }
        }
        /^pmstatus:/ {
            pct = 50 + int($3 * 0.50)
            desc = $4
            for (i=5; i<=NF; i++) { desc = desc ":" $i }
            
            now = systime()
            if (now - last_time >= 1 || pct == 100) {
                printf "XXX\n%d\n[Installing] %s\nXXX\n", pct, substr(desc, 1, 55)
                fflush()
                last_time = now
            }
        }'
    ) | dialog --title "$title" --gauge "Connecting to repositories..." 10 75 0
}

upgrade_with_progress() {
    local title="${1:-Upgrading System Packages}"
    (
        export DEBIAN_FRONTEND=noninteractive
        apt-get upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" -o APT::Status-Fd=3 3>&1 1>/dev/tty3 2>&1 | \
        awk -F: '
        BEGIN { last_time = systime() }
        
        /^dlstatus:/ {
            pct = int($3 * 0.50)
            desc = $4
            for (i=5; i<=NF; i++) { desc = desc ":" $i }
            sub(/ \([^\)]+ remaining\)/, "", desc)
            
            now = systime()
            if (now - last_time >= 1 || pct == 50) {
                printf "XXX\n%d\n[Downloading] %s\nXXX\n", pct, substr(desc, 1, 55)
                fflush()
                last_time = now
            }
        }
        /^pmstatus:/ {
            pct = 50 + int($3 * 0.50)
            desc = $4
            for (i=5; i<=NF; i++) { desc = desc ":" $i }
            
            now = systime()
            if (now - last_time >= 1 || pct == 100) {
                printf "XXX\n%d\n[Installing] %s\nXXX\n", pct, substr(desc, 1, 55)
                fflush()
                last_time = now
            }
        }'
    ) | dialog --title "$title" --gauge "Resolving dependencies (This may take several minutes)..." 10 75 0
}
EOF


# 4. Deploy the First-Boot Setup Script
echo "[*] Deploying /usr/local/bin/firstboot-setup.sh..."
cat << 'EOF' > /usr/local/bin/firstboot-setup.sh
#!/bin/bash

source /usr/local/bin/install_helper_funcs.sh

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
    if dialog --title "Network Required" --yesno "No internet connection detected.\n\nDo you need to configure Wi-Fi?" 10 50; then
        nmtui-connect
    else
        dialog --title "Error" --msgbox "Installation cannot proceed without internet. The system will now reboot." 8 45
        reboot
        exit 1
    fi
done

# --- Phase 3: User Account Provisioning ---
NEW_USER=""
while [ -z "$NEW_USER" ]; do
    NEW_USER=$(dialog --title "User Creation" --inputbox "Enter a new username (lowercase only):" 10 40 3>&1 1>&2 2>&3)
done

PASSWORD=""
PASSWORD_CONFIRM="x"
# FIX: Ensure password is not empty and that both entries match
while [ -z "$PASSWORD" ] || [ "$PASSWORD" != "$PASSWORD_CONFIRM" ]; do
    PASSWORD=$(dialog --title "User Creation" --passwordbox "Enter password for $NEW_USER:" 10 40 3>&1 1>&2 2>&3)
    PASSWORD_CONFIRM=$(dialog --title "User Creation" --passwordbox "Confirm password:" 10 40 3>&1 1>&2 2>&3)

    if [ "$PASSWORD" != "$PASSWORD_CONFIRM" ]; then
        dialog --title "Error" --msgbox "Passwords do not match. Please try again." 8 40
    fi
done

echo "Creating user $NEW_USER..."
useradd -m -s /bin/bash -G sudo "$NEW_USER"
echo "$NEW_USER:$PASSWORD" | chpasswd

dialog --title "Success" --msgbox "User $NEW_USER created successfully and added to the sudo group." 8 45

# --- Phase 4: Payload Selection ---
CHOICE=$(dialog --title "System Setup" --menu "Internet Connected!\n\nChoose a Desktop Environment to install:" 15 50 4 \
"1" "GNOME Desktop" \
"2" "KDE Plasma" \
"3" "XFCE Minimal" \
"4" "CLI Only (Skip)" 3>&1 1>&2 2>&3)

echo "Updating package databases..."
export DEBIAN_FRONTEND=noninteractive
update_with_progress

# Prevent services (like sddm/gdm3) from starting during installation and freezing the TTY
echo -e '#!/bin/sh\nexit 101' > /usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d

case $CHOICE in
    1) install_with_progress "Installing GNOME Desktop..." task-gnome-desktop ;;
    2) install_with_progress "Installing KDE Plasma..." task-kde-desktop ;;
    3) install_with_progress "Installing XFCE Minimal..." task-xfce-desktop ;;
    4|*) echo "Skipping DE installation." ;;
esac

# Remove the block so services can start normally on the next boot
rm -f /usr/sbin/policy-rc.d

# --- Phase 5: Teardown & Handoff ---
echo "Phase 1 complete! Disabling first-boot script..."
systemctl disable firstboot-setup.service

echo "Arming Phase 2 kernel upgrade..."
systemctl enable secondboot-setup.service

dialog --title "Phase 1 Complete" --msgbox "Desktop installation finished.\n\nThe system will now reboot to finalize the kernel upgrade." 10 50

reboot
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

# 7. Deploy the Second-Boot Kernel Setup Script
echo "[*] Deploying /usr/local/bin/secondboot-setup.sh..."
cat << 'EOF' > /usr/local/bin/secondboot-setup.sh
#!/bin/bash

source /usr/local/bin/install_helper_funcs.sh

# Redirect I/O directly to tty1
exec < /dev/tty1 > /dev/tty1 2>&1

echo "=========================================================="
echo " ExecBoot: Phase 2 - Kernel Configuration"
echo "=========================================================="

echo "Waiting for network connection to establish..."
while ! ping -c 1 -W 3 deb.debian.org &> /dev/null; do
    sleep 2
done
echo "Network connected!"

export DEBIAN_FRONTEND=noninteractive

echo "Configuring backports repository for kernel upgrade..."
echo "deb https://deb.debian.org/debian trixie-backports main contrib non-free non-free-firmware" > /etc/apt/sources.list.d/backports.list

echo "Updating package databases..."
update_with_progress

# Temporarily block services from starting during Phase 2 upgrades to protect tty1
echo -e '#!/bin/sh\nexit 101' > /usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d

echo "Upgrading kernel and headers from backports..."
install_with_progress "Upgrading Kernel to Backports Version" -t trixie-backports linux-image-amd64 linux-headers-amd64

echo "Upgrading system..."
upgrade_with_progress

rm -f /usr/sbin/policy-rc.d

echo "Setup fully complete! Disabling second-boot service..."
systemctl disable secondboot-setup.service

dialog --title "Complete" --msgbox "System setup is fully complete! Press OK to reboot into your new desktop environment." 8 50

reboot
EOF

chmod +x /usr/local/bin/secondboot-setup.sh

# 8. Deploy the Second-Boot Systemd Service
echo "[*] Deploying /etc/systemd/system/secondboot-setup.service..."
cat << 'EOF' > /etc/systemd/system/secondboot-setup.service
[Unit]
Description=Second Boot TUI Setup Script (Kernel Upgrade)
After=network.target NetworkManager.service systemd-user-sessions.service
Before=getty@tty1.service display-manager.service sddm.service gdm3.service lightdm.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/secondboot-setup.sh
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
