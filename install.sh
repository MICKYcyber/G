#!/bin/bash
set -e

### ======================
### CONFIG
### ======================

GENTOO_BASE="https://distfiles.gentoo.org/releases/amd64/autobuilds/current-stage3-amd64-openrc/latest-stage3-amd64-openrc.tar.xz"

FS_TYPE="ext4"
SWAP="On"
SWAP_SIZE="4G"
EFI_SIZE="1G"

TIMEZONE="Europe/Berlin"

ROOT_PASSWORD="2112"
USERNAME="Fear"
USER_PASSWORD="2112"

MAKE_OPTS="-j$(nproc)"
GRAP_DRIVERS="nouveau"

USE_FLAGS="X -systemd pulseaudio pipewire alsa readline sound-server ssl v4l pam vulkan opengl dbus gtk screencast vdpau ${GRAP_DRIVERS}"

ACCEPT_LICENSE="*"
ACCEPT_KEYWORDS="~amd64"

PROFILE="default/linux/amd64/23.0"

HOSTNAME="gentoo"
LOCALE="en_US.UTF-8 UTF-8"
KEYMAP="us"

TARGET="x86_64-efi"

### ======================
### SAFETY
### ======================

trap 'echo "[ERROR] Failed at line $LINENO"; exit 1' ERR

### ======================
### AUTO DISK DETECTION (FIXED)
### ======================

DISK=$(lsblk -d -o NAME,SIZE -b | tail -n +2 | sort -k2 -nr | head -n1 | awk '{print "/dev/"$1}')

echo "[*] Auto-detected disk: $DISK"

lsblk -o NAME,SIZE,MODEL
echo ""
read -p "WARNING: This will WIPE $DISK. Press ENTER to continue or CTRL+C to abort"

### NVMe vs SATA fix
if [[ "$DISK" == /dev/nvme* ]]; then
    P="p"
else
    P=""
fi

EFI_PART="${DISK}${P}1"
SWAP_PART="${DISK}${P}2"
ROOT_PART="${DISK}${P}3"

### ======================
### PARTITIONING
### ======================

echo "[*] Partitioning disk..."

parted $DISK --script mklabel gpt

parted $DISK --script mkpart ESP fat32 1MiB 1025MiB
parted $DISK --script set 1 esp on

parted $DISK --script mkpart swap linux-swap 1025MiB $((1025 + 4096))MiB
parted $DISK --script mkpart root ext4 $((1025 + 4096))MiB 100%

### ======================
### FORMAT
### ======================

mkfs.vfat -F32 $EFI_PART
mkfs.ext4 $ROOT_PART

if [[ "$SWAP" == "On" ]]; then
    mkswap $SWAP_PART
    swapon $SWAP_PART
fi

### ======================
### MOUNT
### ======================

mount $ROOT_PART /mnt/gentoo

mkdir -p /mnt/gentoo/efi
mount $EFI_PART /mnt/gentoo/efi

mkdir -p /mnt/gentoo/{proc,sys,dev,boot,etc,home,var,tmp}

### ======================
### STAGE3
### ======================

cd /mnt/gentoo
wget $GENTOO_BASE -O stage3.tar.xz

tar xpvf stage3.tar.xz --xattrs-include='*.*' --numeric-owner

### ======================
### MAKE.CONF
### ======================

cat > /mnt/gentoo/etc/portage/make.conf <<EOF
MAKEOPTS="$MAKE_OPTS"
USE="$USE_FLAGS"
ACCEPT_LICENSE="$ACCEPT_LICENSE"
ACCEPT_KEYWORDS="$ACCEPT_KEYWORDS"
GRUB_PLATFORMS="efi-64"
EOF

### ======================
### CHROOT SETUP
### ======================

mount --types proc /proc /mnt/gentoo/proc
mount --rbind /sys /mnt/gentoo/sys
mount --make-rslave /mnt/gentoo/sys
mount --rbind /dev /mnt/gentoo/dev
mount --make-rslave /mnt/gentoo/dev

cp --dereference /etc/resolv.conf /mnt/gentoo/etc/

chroot /mnt/gentoo /bin/bash <<EOF

source /etc/profile

echo "$TIMEZONE" > /etc/timezone
emerge --config sys-libs/timezone-data

echo "$LOCALE" > /etc/locale.gen
locale-gen
eselect locale set 1

echo "$HOSTNAME" > /etc/hostname

eselect profile set "$PROFILE"

emerge sys-kernel/gentoo-kernel-bin linux-firmware

echo "root:$ROOT_PASSWORD" | chpasswd
useradd -m -G wheel,video,audio -s /bin/bash $USERNAME
echo "$USERNAME:$USER_PASSWORD" | chpasswd

emerge sudo dhcpcd

rc-update add dhcpcd default

emerge sys-boot/grub
grub-install --target=$TARGET --efi-directory=/efi
grub-mkconfig -o /boot/grub/grub.cfg

EOF

### ======================
### CLEANUP
### ======================

umount -R /mnt/gentoo
swapoff -a

echo "[✔] Install complete. Reboot now."
