#!/bin/bash
###############################################################################
# lfs-config.sh — общие настройки для phase0-host-prep.sh и phase1-chapter4.sh
#
# Все значения можно переопределить переменными окружения:
#     LFS=/mnt/lfs DISK=/dev/sda bash scripts/phase1-chapter4.sh
###############################################################################

# Куда собираем и для какой архитектуры
export LFS="${LFS:-/mnt/lfs}"
export LFS_TGT="${LFS_TGT:-$(uname -m)-lfs-linux-gnu}"

#------------------------------------------------------------------------------
# Разметка. Используется ТОЛЬКО когда AUTO_PARTITION=yes —
# и это уничтожает все данные на $DISK.
#
# Схема разделов из phase0-host-prep.sh:
#   1  ESP        fat32        1 MiB    – 513 MiB
#   2  BIOS_BOOT  (без ФС)     513 MiB  – 514 MiB
#   3  BOOT       ext2         514 MiB  – 1014 MiB
#   4  SWAP       linux-swap   1014 MiB – 3 GiB
#   5  LFS        ext4         3 GiB    – 100%
#------------------------------------------------------------------------------
export AUTO_PARTITION="${AUTO_PARTITION:-no}"
export DISK="${DISK:-/dev/sda}"

export PART_EFI="${PART_EFI:-${DISK}1}"
export PART_BOOT="${PART_BOOT:-${DISK}3}"
export PART_SWAP="${PART_SWAP:-${DISK}4}"
export PART_LFS="${PART_LFS:-${DISK}5}"

export FS_EFI="${FS_EFI:-vfat}"
export FS_BOOT="${FS_BOOT:-ext2}"
export FS_LFS="${FS_LFS:-ext4}"

# Готовые исходники (если уже скачаны в другое место — phase0 их не тронет)
export LFS_SOURCES="${LFS_SOURCES:-$LFS/sources}"
export LFS_LOGS="${LFS_LOGS:-$LFS/sources/logs}"
