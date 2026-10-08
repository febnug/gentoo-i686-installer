#!/bin/bash
#
# Gentoo x86/i686 Base Installer
# BIOS + MBR + OpenRC + ext4
#
# TEST TARGET:
#   Gentoo x86/i686
#   BIOS/Legacy
#   /dev/sda
#
# WARNING:
#   THIS WILL DESTROY /dev/sda
#

set -Eeuo pipefail

export LC_ALL=C

DISK="/dev/sda"
MNT="/mnt/gentoo"

ARCH="i686"
PROFILE="default/linux/x86/17.1"
STAGE_BASE="https://distfiles.gentoo.org/releases/x86/autobuilds/current-stage3-i686-openrc"

HOSTNAME="gentoo32"
TIMEZONE="Asia/Jakarta"

log() {
    echo
    echo "============================================================"
    echo "[+] $*"
    echo "============================================================"
}

die() {
    echo
    echo "[ERROR] $*" >&2
    exit 1
}

cleanup() {
    echo
    echo "[*] Cleaning up mounts..."

    sync || true

    umount -R "$MNT" 2>/dev/null || true
}

trap cleanup EXIT

require_root() {
    [[ "$EUID" -eq 0 ]] || die "Run this script as root."
}

check_dependencies() {
    log "Checking dependencies"

    local deps=(
        wget
        curl
        tar
        xz
        sha256sum
        sfdisk
        mkfs.ext4
        mkswap
        mount
        chroot
        grub-install
    )

    for cmd in "${deps[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || {
            echo "[!] Missing command: $cmd"
        }
    }

    command -v sfdisk >/dev/null 2>&1 ||
        die "sfdisk is required."

    command -v mkfs.ext4 >/dev/null 2>&1 ||
        die "mkfs.ext4 is required."

    command -v mkswap >/dev/null 2>&1 ||
        die "mkswap is required."

    command -v wget >/dev/null 2>&1 ||
        die "wget is required."

    command -v tar >/dev/null 2>&1 ||
        die "tar is required."
}

check_network() {
    log "Checking network"

    if ping -c 1 -W 3 distfiles.gentoo.org >/dev/null 2>&1; then
        echo "[OK] Network works."
    else
        echo "[!] DNS/network test failed."
        echo
        echo "Try:"
        echo "    ping 1.1.1.1"
        echo "    ping distfiles.gentoo.org"
        echo
        read -rp "Continue anyway? [y/N]: " answer

        [[ "$answer" =~ ^[Yy]$ ]] ||
            die "Network unavailable."
    fi
}

check_disk() {
    log "Checking target disk"

    [[ -b "$DISK" ]] ||
        die "$DISK does not exist."

    echo
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS "$DISK" || true
    echo

    echo "TARGET DISK:"
    echo "    $DISK"
    echo
    echo "ALL DATA ON THIS DISK WILL BE DESTROYED."
    echo

    read -rp "Type WIPE to continue: " confirm

    [[ "$confirm" == "WIPE" ]] ||
        die "Aborted."
}

partition_disk() {
    log "Partitioning $DISK"

    swapoff -a 2>/dev/null || true

    umount "${DISK}"* 2>/dev/null || true

    # Remove old filesystem signatures.
    wipefs -a "$DISK" || true

    # MBR/DOS partition table:
    #
    # 1 = root      7G
    # 2 = swap      remainder
    #
    # For VM disks >= 8G.
    sfdisk --wipe always "$DISK" <<EOF
label: dos

start=2048, size=+, type=83, bootable
start=, size=+, type=82
EOF

    partprobe "$DISK" 2>/dev/null || true
    sleep 2

    ROOT="${DISK}1"
    SWAP="${DISK}2"

    [[ -b "$ROOT" ]] ||
        die "Root partition $ROOT was not created."

    [[ -b "$SWAP" ]] ||
        die "Swap partition $SWAP was not created."

    log "Formatting root filesystem"

    mkfs.ext4 -F -L GENTOO_ROOT "$ROOT"

    log "Creating swap"

    mkswap -L GENTOO_SWAP "$SWAP"
}

mount_filesystems() {
    log "Mounting filesystems"

    mkdir -p "$MNT"

    mount "$ROOT" "$MNT"

    mkdir -p "$MNT"/{dev,proc,sys,run}

    mount --rbind /dev "$MNT/dev"
    mount --make-rslave "$MNT/dev"

    mount -t proc /proc "$MNT/proc"

    mount --rbind /sys "$MNT/sys"
    mount --make-rslave "$MNT/sys"

    mount --rbind /run "$MNT/run"
    mount --make-rslave "$MNT/run"
}

download_stage3() {
    log "Downloading current Gentoo i686 OpenRC Stage3"

    mkdir -p "$MNT/root/stage3"

    cd "$MNT/root/stage3"

    local latest_file
    latest_file="$(
        wget -qO- \
        "$STAGE_BASE/latest-stage3-i686-openrc.txt" |
        grep -E '^stage3-i686-openrc-.*\.tar\.xz$' |
        tail -n 1
    )"

    [[ -n "$latest_file" ]] ||
        die "Could not determine current Stage3."

    echo "[+] Stage3:"
    echo "    $latest_file"

    wget -c \
        "$STAGE_BASE/$latest_file"

    wget -c \
        "$STAGE_BASE/$latest_file.sha256"

    log "Verifying Stage3 SHA256"

    sha256sum -c "$latest_file.sha256"

    log "Extracting Stage3"

    tar xpvf "$latest_file" \
        --xattrs-include='*.*' \
        --numeric-owner \
        -C "$MNT"

    rm -rf "$MNT/root/stage3"
}

configure_dns() {
    log "Configuring DNS"

    rm -f "$MNT/etc/resolv.conf"

    cat > "$MNT/etc/resolv.conf" <<EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
}

configure_fstab() {
    log "Generating fstab"

    local root_uuid
    local swap_uuid

    root_uuid="$(blkid -s UUID -o value "$ROOT")"
    swap_uuid="$(blkid -s UUID -o value "$SWAP")"

    cat > "$MNT/etc/fstab" <<EOF
# Gentoo x86/i686

UUID=$root_uuid    /       ext4    noatime        0 1
UUID=$swap_uuid    none    swap    sw             0 0
EOF
}

copy_resolv_for_chroot() {
    cp -L /etc/resolv.conf "$MNT/etc/resolv.conf" 2>/dev/null || true
}

prepare_chroot() {
    log "Preparing Gentoo chroot"

    cp -L /etc/resolv.conf "$MNT/etc/resolv.conf"

    # Copy timezone information.
    if [[ -e "/usr/share/zoneinfo/$TIMEZONE" ]]; then
        mkdir -p "$MNT/etc"
        cp "/usr/share/zoneinfo/$TIMEZONE" "$MNT/etc/localtime"
    fi
}

create_install_script() {
    log "Creating inside-chroot installer"

    cat > "$MNT/root/gentoo-chroot.sh" <<'CHROOT_SCRIPT'
#!/bin/bash

set -Eeuo pipefail

export LC_ALL=C

HOSTNAME="gentoo32"
TIMEZONE="Asia/Jakarta"

log() {
    echo
    echo "------------------------------------------------------------"
    echo "[CHROOT] $*"
    echo "------------------------------------------------------------"
}

die() {
    echo "[CHROOT ERROR] $*" >&2
    exit 1
}

[[ "$(id -u)" -eq 0 ]] ||
    die "Must run as root."

log "Configuring Portage"

mkdir -p /etc/portage

# Conservative i686 flags.
#
# Do not use -march=native because the resulting system
# will then depend on the CPU used during installation.
cat > /etc/portage/make.conf <<'EOF'
COMMON_FLAGS="-O2 -pipe"

CFLAGS="${COMMON_FLAGS}"
CXXFLAGS="${COMMON_FLAGS}"

MAKEOPTS="-j2"

FEATURES="ccache"

ACCEPT_LICENSE="*"

GRUB_PLATFORMS="pc"

VIDEO_CARDS=""

INPUT_DEVICES="libinput"

USE="X alsa dbus elogind ipv6 openrc pam"

EMERGE_DEFAULT_OPTS="--ask=n"

GENTOO_MIRRORS="https://distfiles.gentoo.org"
EOF

log "Configuring repository"

mkdir -p /etc/portage/repos.conf

cat > /etc/portage/repos.conf/gentoo.conf <<'EOF'
[DEFAULT]
main-repo = gentoo

[gentoo]
location = /var/db/repos/gentoo
sync-type = rsync
sync-uri = rsync://rsync.gentoo.org/gentoo-portage
auto-sync = yes
EOF

log "Updating Portage tree"

if command -v emerge-webrsync >/dev/null 2>&1; then
    emerge-webrsync
else
    emerge --sync
fi

log "Selecting x86 profile"

PROFILE_FOUND=0

if eselect profile list >/dev/null 2>&1; then
    if eselect profile list | grep -q "default/linux/x86/17.1"; then
        eselect profile set default/linux/x86/17.1
        PROFILE_FOUND=1
    fi
fi

if [[ "$PROFILE_FOUND" -eq 0 ]]; then
    echo "[!] Could not automatically select x86/17.1."
    echo
    eselect profile list || true
fi

log "Updating @world"

emerge --update --deep --newuse @world

log "Setting timezone"

if [[ -e "/usr/share/zoneinfo/$TIMEZONE" ]]; then
    ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
fi

echo "UTC" > /etc/timezone

log "Configuring locale"

cat > /etc/locale.gen <<'EOF'
en_US.UTF-8 UTF-8
C.UTF-8 UTF-8
EOF

locale-gen

if command -v eselect >/dev/null 2>&1; then
    eselect locale set en_US.utf8 || true
fi

env-update
source /etc/profile

log "Setting hostname"

echo "$HOSTNAME" > /etc/hostname

cat > /etc/hosts <<'EOF'
127.0.0.1       localhost
127.0.1.1       gentoo32
::1             localhost
EOF

log "Installing essential packages"

emerge \
    sys-kernel/gentoo-kernel-bin \
    sys-boot/grub \
    net-misc/dhcpcd \
    app-admin/sudo \
    app-editors/nano

log "Configuring networking"

cat > /etc/conf.d/net <<'EOF'
config_eth0="dhcp"
EOF

ln -sf /etc/init.d/net.lo /etc/init.d/net.eth0

rc-update add net.eth0 default

log "Configuring root password"

echo
echo "Set ROOT password:"
passwd

log "Creating normal user"

if ! id gentoo >/dev/null 2>&1; then
    useradd \
        -m \
        -G users,wheel \
        -s /bin/bash \
        gentoo
fi

echo
echo "Set password for user 'gentoo':"
passwd gentoo

log "Configuring sudo"

mkdir -p /etc/sudoers.d

cat > /etc/sudoers.d/wheel <<'EOF'
%wheel ALL=(ALL:ALL) ALL
EOF

chmod 0440 /etc/sudoers.d/wheel

log "Configuring kernel"

if [[ -d /usr/src/linux ]]; then
    echo "[+] Kernel source available at /usr/src/linux"
fi

log "Installing GRUB bootloader"

grub-install \
    --target=i386-pc \
    --recheck \
    /dev/sda

log "Generating GRUB configuration"

grub-mkconfig -o /boot/grub/grub.cfg

log "Enabling important services"

rc-update add dhcpcd default 2>/dev/null || true

log "Checking installed kernel"

ls -lh /boot

log "Checking root filesystem"

mountpoint -q /proc || true

log "Gentoo base installation completed"

echo
echo "============================================================"
echo " Gentoo x86/i686 installation completed!"
echo "============================================================"
echo
echo "Hostname : $HOSTNAME"
echo "Arch     : x86/i686"
echo "Init     : OpenRC"
echo "Boot     : GRUB BIOS/i386-pc"
echo
echo "Reboot after leaving chroot."
echo

CHROOT_SCRIPT

    chmod +x "$MNT/root/gentoo-chroot.sh"
}

run_chroot() {
    log "Entering Gentoo chroot"

    chroot "$MNT" /bin/bash /root/gentoo-chroot.sh
}

cleanup_before_reboot() {
    log "Final cleanup"

    rm -f "$MNT/root/gentoo-chroot.sh"

    sync

    umount -R "$MNT" || true

    swapoff "$SWAP" 2>/dev/null || true
}

main() {
    require_root

    echo
    echo "============================================================"
    echo "       GENTOO x86/i686 AUTOMATIC INSTALLER"
    echo "============================================================"
    echo
    echo "Target : $DISK"
    echo "Arch   : i686"
    echo "Init   : OpenRC"
    echo "Boot   : BIOS/MBR"
    echo "FS     : ext4"
    echo

    check_dependencies
    check_network
    check_disk

    partition_disk
    mount_filesystems
    configure_dns
    configure_fstab
    prepare_chroot
    download_stage3
    create_install_script
    run_chroot

    cleanup_before_reboot

    trap - EXIT

    echo
    echo "============================================================"
    echo " INSTALLATION FINISHED"
    echo "============================================================"
    echo
    echo "Remove the Gentoo installer ISO from the VM."
    echo
    read -rp "Reboot now? [y/N]: " reboot_now

    if [[ "$reboot_now" =~ ^[Yy]$ ]]; then
        reboot
    fi
}

main "$@"
