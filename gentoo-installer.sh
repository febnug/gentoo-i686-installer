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

DISK=""
MNT="/mnt/gentoo"
ROOT=""
SWAP=""

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
        tar
        xz
        sha256sum
        sfdisk
        mkfs.ext4
        mkswap
        mount
        lsblk
        chroot
    )

    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "[!] Missing command: $cmd"
            missing=1
        fi
    done

    if [[ "${missing:-0}" -eq 1 ]]; then
        die "One or more required commands are missing from the live environment."
    fi

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

    command -v blockdev >/dev/null 2>&1 ||
        die "blockdev is required."

    command -v wipefs >/dev/null 2>&1 ||
        die "wipefs is required."
}

check_network() {
    log "Checking network"

    if wget -q --spider --timeout=8 https://distfiles.gentoo.org/; then
        echo "[OK] Network + HTTPS works."
    else
        echo "[!] Cannot reach distfiles.gentoo.org over HTTPS."
        echo
        echo "Try:"
        echo "    wget -S --spider https://distfiles.gentoo.org/"
        echo
        die "Network unavailable."
    fi
}

partition_name() {
    # Correctly handle /dev/sda -> /dev/sda1 and /dev/nvme0n1 -> /dev/nvme0n1p1.
    local disk="$1" number="$2"
    if [[ "$disk" =~ [0-9]$ ]]; then
        printf '%sp%s' "$disk" "$number"
    else
        printf '%s%s' "$disk" "$number"
    fi
}

detect_target_disk() {
    log "Detecting available hard disks / SSDs"

    local -a candidates=()
    local name type removable size model mountpoints root_source root_parent
    local i=0 choice

    command -v lsblk >/dev/null 2>&1 || die "lsblk is required."
    command -v findmnt >/dev/null 2>&1 || die "findmnt is required."

    # Avoid offering the disk containing the currently mounted root filesystem.
    root_source="$(findmnt -nro SOURCE / 2>/dev/null || true)"
    if [[ -n "$root_source" && "$root_source" == /dev/* ]]; then
        root_parent="$(lsblk -nro PKNAME "$root_source" 2>/dev/null | head -n1 || true)"
        if [[ -n "$root_parent" ]]; then
            root_source="/dev/$root_parent"
        fi
    fi

    echo
    printf '%-4s %-16s %-9s %-8s %-7s %s\n' "No." "DEVICE" "SIZE" "TYPE" "RM" "MODEL"
    printf '%-4s %-16s %-9s %-8s %-7s %s\n' "---" "------" "----" "----" "--" "-----"

    while read -r name type removable size model; do
        [[ "$type" == "disk" ]] || continue
        [[ -b "$name" ]] || continue
        # Skip removable disks (often the installer USB) by default.
        [[ "$removable" == "0" ]] || continue
        # Skip the disk hosting the currently running root filesystem, when identifiable.
        [[ -n "$root_source" && "$name" == "$root_source" ]] && continue

        # Never offer disks with mounted descendants, to reduce accidental destruction.
        mountpoints="$(lsblk -nrpo MOUNTPOINT "$name" | sed '/^[[:space:]]*$/d' || true)"
        [[ -z "$mountpoints" ]] || continue

        candidates+=("$name")
        ((i+=1))
        printf '%-4s %-16s %-9s %-8s %-7s %s\n' "$i" "$name" "$size" "$type" "$removable" "${model:-Unknown}"
    done < <(lsblk -dnpo NAME,TYPE,RM,SIZE,MODEL)

    ((${#candidates[@]} > 0)) || die "No eligible non-removable, unmounted disk found. Check lsblk output and target disk mounts."

    echo
    read -r -p "Select target disk number (all data on it will be destroyed): " choice
    [[ "$choice" =~ ^[0-9]+$ ]] || die "Invalid disk selection."
    (( choice >= 1 && choice <= ${#candidates[@]} )) || die "Selection out of range."

    DISK="${candidates[$((choice-1))]}"
    ROOT="$(partition_name "$DISK" 1)"
    SWAP="$(partition_name "$DISK" 2)"

    echo
    echo "Selected target disk:"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL "$DISK"
    echo
    echo "WARNING: ALL DATA ON $DISK WILL BE DESTROYED."
    read -r -p "Type WIPE to confirm this exact disk: " confirm
    [[ "$confirm" == "WIPE" ]] || die "Aborted."
}

partition_disk() {
    log "Partitioning $DISK"

    swapoff -a 2>/dev/null || true
    umount "${ROOT:-$(partition_name "$DISK" 1)}" "${SWAP:-$(partition_name "$DISK" 2)}" 2>/dev/null || true

    log "Removing old partition/filesystem signatures"
    wipefs -a "$DISK"

    local sector_size total_sectors swap_bytes swap_sectors first_sector root_sectors swap_start

    sector_size="$(blockdev --getss "$DISK")"
    total_sectors="$(blockdev --getsz "$DISK")"
    swap_bytes=$((2 * 1024 * 1024 * 1024))
    swap_sectors=$(( (swap_bytes + sector_size - 1) / sector_size ))
    first_sector=2048

    (( total_sectors > first_sector + swap_sectors )) ||
        die "Disk is too small for root + 2 GiB swap."

    root_sectors=$((total_sectors - first_sector - swap_sectors))
    swap_start=$((first_sector + root_sectors))

    echo
    echo "[+] Partition layout:"
    echo "    $DISK"
    echo "    ├── ${DISK}1  root  ext4  $((root_sectors * sector_size / 1024 / 1024 / 1024)) GiB"
    echo "    └── ${DISK}2  swap  2 GiB"
    echo

    sfdisk --wipe always "$DISK" <<EOF
label: dos
unit: sectors

start=$first_sector, size=$root_sectors, type=83, bootable
start=$swap_start, size=$swap_sectors, type=82
EOF

    partprobe "$DISK" 2>/dev/null || true
    udevadm settle 2>/dev/null || true
    sleep 2

    [[ -b "$ROOT" ]] || die "Root partition $ROOT was not created."
    [[ -b "$SWAP" ]] || die "Swap partition $SWAP was not created."

    log "Formatting root filesystem"
    mkfs.ext4 -F -L GENTOO_ROOT "$ROOT"

    log "Creating swap"
    mkswap -L GENTOO_SWAP "$SWAP"

    echo
    lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS "$DISK"
}

mount_filesystems() {
    log "Mounting filesystems"

    mkdir -p "$MNT"

    mount "$ROOT" "$MNT"

    mkdir -p "$MNT"/{dev,proc,sys,run}

    mount --rbind /dev "$MNT/dev"
    mount --make-rslave "$MNT/dev"

    mount -t proc proc "$MNT/proc"

    mount --rbind /sys "$MNT/sys"
    mount --make-rslave "$MNT/sys"

    mount --rbind /run "$MNT/run"
    mount --make-rslave "$MNT/run"
}

download_stage3() {
    log "Downloading current Gentoo i686 OpenRC Stage3"

    local stage_dir="$MNT/root/stage3"
    local latest_file latest_url checksum_file

    mkdir -p "$stage_dir"
    cd "$stage_dir"

    latest_file="$(
        wget -qO- "$STAGE_BASE/latest-stage3-i686-openrc.txt" |
        awk '$1 !~ /^#/ && $1 ~ /^stage3-i686-openrc-.*\.tar\.xz$/ {print $1}' |
        tail -n 1
    )"

    [[ -n "$latest_file" ]] ||
        die "Could not determine current i686 OpenRC Stage3 filename."

    latest_url="$STAGE_BASE/$latest_file"
    checksum_file="$latest_file.sha256"

    echo "[+] Stage3: $latest_file"

    wget -c --tries=5 --timeout=30 "$latest_url"
    wget -c --tries=5 --timeout=30 "$STAGE_BASE/$checksum_file"

    log "Verifying Stage3 SHA256"
    sha256sum -c "$checksum_file"

    log "Extracting Stage3"

    tar xpf "$latest_file" \
        --xattrs-include='*' \
        --numeric-owner \
        -C "$MNT"

    rm -rf "$stage_dir"
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

prepare_chroot() {
    log "Preparing Gentoo chroot"

    # Keep DNS from the installer environment when possible.
    # configure_dns() already wrote known-good resolvers for the chroot.
    [[ -e "$MNT/etc/resolv.conf" ]] || configure_dns
}

create_install_script() {
    log "Creating inside-chroot installer"

    cat > "$MNT/root/gentoo-chroot.sh" <<'CHROOT_SCRIPT'
#!/bin/bash

set -Eeuo pipefail

export LC_ALL=C

HOSTNAME="gentoo32"
TIMEZONE="Asia/Jakarta"
TARGET_DISK="__TARGET_DISK__"

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

ACCEPT_LICENSE="*"

GRUB_PLATFORMS="pc"

USE="alsa dbus ipv6 openrc pam"

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

echo "$TIMEZONE" > /etc/timezone

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
# Do not source /etc/profile while `set -u` is active.
# Some Gentoo profile fragments reference optional variables such as
# DEBUGINFO_URLS; sourcing them here can abort the installer.

log "Setting hostname"

echo "$HOSTNAME" > /etc/hostname

cat > /etc/hosts <<'EOF'
127.0.0.1       localhost
127.0.1.1       gentoo32
::1             localhost
EOF

log "Preparing kernel USE flags"

# Current Gentoo distribution kernels require initramfs support,
# and installkernel needs dracut to generate the initramfs.
# Configure these explicitly so emerge does not stop asking for
# --autounmask-write / --autounmask-continue.
mkdir -p /etc/portage/package.use

cat > /etc/portage/package.use/zz-gentoo-installer <<'EOF'
sys-kernel/gentoo-kernel-bin initramfs
sys-kernel/installkernel dracut
EOF

log "Installing essential packages"

emerge --update --newuse \
    sys-kernel/gentoo-kernel-bin \
    sys-boot/grub \
    net-misc/dhcpcd \
    net-misc/networkmanager \
    app-admin/sudo \
    app-editors/nano

log "Verifying installed kernel"

if ! ls /boot/vmlinuz-* >/dev/null 2>&1; then
    die "Kernel image was not installed in /boot."
fi

if ! ls /boot/initramfs-* >/dev/null 2>&1; then
    die "Kernel initramfs was not generated in /boot."
fi

log "Configuring networking"

# NetworkManager provides nmcli and manages Wi-Fi/Ethernet.
# Do not run dhcpcd and NetworkManager together on the same interface.
rc-update del dhcpcd default 2>/dev/null || true
rc-service dhcpcd stop 2>/dev/null || true
rc-update add NetworkManager default

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
    "$TARGET_DISK"

log "Generating GRUB configuration"

grub-mkconfig -o /boot/grub/grub.cfg

log "Verifying networking"

command -v nmcli >/dev/null 2>&1 ||
    die "NetworkManager/nmcli was not installed."

rc-update show default | grep -q 'NetworkManager' ||
    rc-update add NetworkManager default

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

    sed -i "s|__TARGET_DISK__|$DISK|g" "$MNT/root/gentoo-chroot.sh"
    chmod +x "$MNT/root/gentoo-chroot.sh"
}

run_chroot() {
    log "Entering Gentoo chroot"

    [[ -x "$MNT/root/gentoo-chroot.sh" ]] || die "Chroot installer was not created."
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
    echo "Target : auto-detected disk selection"
    echo "Arch   : i686"
    echo "Init   : OpenRC"
    echo "Boot   : BIOS/MBR"
    echo "FS     : ext4"
    echo

    check_dependencies
    detect_target_disk
    check_network

    partition_disk
    mount_filesystems
    download_stage3
    configure_dns
    configure_fstab
    prepare_chroot
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
