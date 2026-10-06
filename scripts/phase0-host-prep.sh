#!/bin/bash
###############################################################################
# phase0-host-prep.sh — Главы 2–3: подготовка хост-системы
# Разметка диска, монтирование, загрузка исходников
###############################################################################
set -euo pipefail
source "$(dirname "$0")/../lfs-config.sh"

log()   { echo -e "\033[0;34m[$(date +%H:%M:%S)]\033[0m $*"; }
ok()    { echo -e "\033[0;32m[OK]\033[0m $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m $*"; }
die()   { echo -e "\033[0;31m[ERROR]\033[0m $*" >&2; exit 1; }

#------------------------------------------------------------------------------
# 2.4 Разметка диска (только если AUTO_PARTITION=yes)
#------------------------------------------------------------------------------
if [[ "$AUTO_PARTITION" == "yes" ]]; then
    warn "АВТОМАТИЧЕСКАЯ РАЗМЕТКА ДИСКА $DISK — ВСЕ ДАННЫЕ БУДУТ УНИЧТОЖЕНЫ!"
    read -rp "Вы уверены? Введите 'I-UNDERSTAND' для продолжения: " ans
    [[ "$ans" == "I-UNDERSTAND" ]] || die "Отменено"

    # GPT + разделы
    parted -s "$DISK" mklabel gpt
    parted -s "$DISK" mkpart ESP fat32 1MiB 513MiB
    parted -s "$DISK" set 1 esp on
    parted -s "$DISK" mkpart BIOS_BOOT 513MiB 514MiB
    parted -s "$DISK" set 2 bios_grub on
    parted -s "$DISK" mkpart BOOT ext2 514MiB 1014MiB
    parted -s "$DISK" mkpart SWAP linux-swap 1014MiB 3GiB
    parted -s "$DISK" mkpart LFS ext4 3GiB 100%
    ok "Разметка завершена"
fi

#------------------------------------------------------------------------------
# 2.5 Создание файловых систем
#------------------------------------------------------------------------------
log "Создание файловых систем..."
[[ -b "$PART_EFI"  ]] && mkfs.vfat -F 32 "$PART_EFI"
[[ -b "$PART_BOOT" ]] && mkfs -v -t "$FS_BOOT" "$PART_BOOT"
[[ -b "$PART_SWAP" ]] && mkswap "$PART_SWAP"
mkfs -v -t "$FS_LFS" "$PART_LFS"
ok "Файловые системы созданы"

#------------------------------------------------------------------------------
# 2.6 $LFS и umask
#------------------------------------------------------------------------------
export LFS
umask 022
ok "\$LFS=$LFS, umask=022"

#------------------------------------------------------------------------------
# 2.7 Монтирование
#------------------------------------------------------------------------------
log "Монтирование разделов..."
mkdir -pv "$LFS"
mount -v -t "$FS_LFS" "$PART_LFS" "$LFS"
[[ -b "$PART_BOOT" ]] && { mkdir -pv "$LFS/boot"; mount -v -t "$FS_BOOT" "$PART_BOOT" "$LFS/boot"; }
[[ -b "$PART_EFI"  ]] && { mkdir -pv "$LFS/boot/efi"; mount -v -t "$FS_EFI" "$PART_EFI" "$LFS/boot/efi"; }
[[ -b "$PART_SWAP" ]] && swapon -v "$PART_SWAP"
ok "Разделы смонтированы"

# Установка владельца
chown root:root "$LFS"
chmod 755 "$LFS"

#------------------------------------------------------------------------------
# 3.1 Создание $LFS/sources
#------------------------------------------------------------------------------
mkdir -pv "$LFS/sources"
chmod -v a+wt "$LFS/sources"

#------------------------------------------------------------------------------
# 3.2 Загрузка пакетов
#------------------------------------------------------------------------------
cd "$LFS/sources"
if [[ ! -f "wget-list-systemd" ]]; then
    log "Загрузка wget-list-systemd и md5sums..."
    wget -q https://www.linuxfromscratch.org/lfs/view/13.1-systemd/wget-list-systemd -O wget-list-systemd
    wget -q https://www.linuxfromscratch.org/lfs/view/13.1-systemd/md5sums -O md5sums
fi

if [[ -n "$(find . -maxdepth 1 -name '*.tar.*' -print -quit 2>/dev/null)" ]]; then
    ok "Исходники уже загружены (пропуск)"
else
    log "Загрузка пакетов (может занять 10–30 минут)..."
    wget --input-file=wget-list-systemd --continue --directory-prefix="$LFS/sources" \
         --no-verbose 2>&1 | tail -5
    ok "Загрузка завершена"
fi

log "Проверка MD5-сумм..."
pushd "$LFS/sources"
md5sum -c md5sums 2>&1 | grep -v ': OK' || true
popd

chown root:root "$LFS/sources/"*
ok "Главы 2–3 завершены"