#!/usr/bin/env bash
# KISS NixOS bootstrap: GPT + LUKS2 + Btrfs(zstd, 四子卷) + systemd-boot
# 用法: sudo bash bootstrap.sh [磁盘] [密钥文件]
# 注意: 会清空目标磁盘
set -euo pipefail

DISK="${1:-/dev/nvme0n1}"
KEY="${2:-/tmp/luks.key}"
OPTS="compress=zstd:3,noatime"

[ -b "$DISK" ] || { echo "no such block device: $DISK" >&2; exit 1; }
[ -b "${DISK}p1" -o -f "$KEY" ] || true

echo ">>> 清空并重建分区表: $DISK"
wipefs -a -f "$DISK"
sfdisk --wipe always "$DISK" <<EOF
label: gpt
/dev/nvme0n1p1 : size=2GiB, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="ESP"
/dev/nvme0n1p2 : type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="cryptroot"
EOF
partprobe "$DISK"
udevadm settle

echo ">>> LUKS2 格式化 (argon2id)"
cryptsetup luksFormat --type luks2 --label cryptroot --key-file "$KEY" --batch-mode "${DISK}p2"
cryptsetup open --key-file "$KEY" "${DISK}p2" cryptroot

echo ">>> Btrfs + 子卷"
mkfs.btrfs -f -L nixos /dev/mapper/cryptroot
mkdir -p /mnt
mount /dev/mapper/cryptroot /mnt
btrfs subvolume create /mnt/@root /mnt/@home /mnt/@nix /mnt/@log
umount /mnt

echo ">>> 挂载子卷"
mount -o "$OPTS,subvol=@root" /dev/mapper/cryptroot /mnt
mkdir -p /mnt/home /mnt/nix /mnt/var/log /mnt/boot
mount -o "$OPTS,subvol=@home" /dev/mapper/cryptroot /mnt/home
mount -o "$OPTS,subvol=@nix"  /dev/mapper/cryptroot /mnt/nix
mount -o "$OPTS,subvol=@log"  /dev/mapper/cryptroot /mnt/var/log

echo ">>> EFI 分区 (FAT32, 2GiB)"
mkfs.fat -F 32 -n BOOT "${DISK}p1"
mount "${DISK}p1" /mnt/boot

echo ">>> 完成，当前挂载："
findmnt -R /mnt
