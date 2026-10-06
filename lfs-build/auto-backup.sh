#!/bin/bash
###############################################################################
# auto-backup.sh — Автоматическое резервное копирование после каждой фазы
# Экономит часы при сбое на поздних этапах.
###############################################################################
set -euo pipefail

LFS="${LFS:-/mnt/lfs}"
BACKUP_DIR="${BACKUP_DIR:-/backups/lfs}"
KEEP_BACKUPS="${KEEP_BACKUPS:-3}"   # Сколько последних бэкапов хранить
TS="$(date +%Y%m%d-%H%M%S)"

mkdir -p "$BACKUP_DIR"

log()  { echo -e "\033[0;34m[$(date +%H:%M:%S)]\033[0m $*"; }
ok()   { echo -e "\033[0;32m[OK]\033[0m $*"; }

#------------------------------------------------------------------------------
# Создание бэкапа фазы
#------------------------------------------------------------------------------
create_backup() {
    local phase="$1"
    local archive="${BACKUP_DIR}/lfs-${phase}-${TS}.tar.zst"

    log "Создание бэкапа фазы $phase → $archive"

    # Отмонтируем виртуальные ФС, чтобы не тащить их в архив
    local mounted=()
    for mnt in dev/pts dev proc sys run; do
        if mountpoint -q "$LFS/$mnt" 2>/dev/null; then
            mounted+=("$mnt")
            umount "$LFS/$mnt" 2>/dev/null || true
        fi
    done

    # Создание архива с zstd (быстрее и меньше, чем gzip)
    if command -v zstd >/dev/null; then
        tar -C "$LFS" -I 'zstd -T0 -3' -cpf "$archive" . 2>/dev/null || \
        tar -C "$LFS" -czpf "${archive%.zst}.gz" .
    else
        tar -C "$LFS" -czpf "${archive%.zst}.gz" .
        archive="${archive%.zst}.gz"
    fi

    # Обратно монтируем
    for mnt in "${mounted[@]}"; do
        case "$mnt" in
            dev/pts) mount -vt devpts devpts -o gid=5,mode=0620 "$LFS/dev/pts" ;;
            dev)     mount -v --bind /dev "$LFS/dev" ;;
            proc)    mount -vt proc proc "$LFS/proc" ;;
            sys)     mount -vt sysfs sysfs "$LFS/sys" ;;
            run)     mount -vt tmpfs tmpfs "$LFS/run" ;;
        esac
    done

    local size=$(du -h "$archive" | cut -f1)
    ok "Бэкап создан: $archive ($size)"
}

#------------------------------------------------------------------------------
# Восстановление из бэкапа
#------------------------------------------------------------------------------
restore_backup() {
    local archive="$1"
    [[ -f "$archive" ]] || { echo "Архив не найден: $archive"; exit 1; }

    echo "⚠  ВНИМАНИЕ: будет уничтожено всё в $LFS и восстановлено из $archive"
    read -rp "Продолжить? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || exit 0

    cd "$LFS"
    rm -rf ./*
    tar -xpf "$archive"
    ok "Восстановлено из $archive"
}

#------------------------------------------------------------------------------
# Ротация старых бэкапов
#------------------------------------------------------------------------------
rotate() {
    log "Ротация (хранить $KEEP_BACKUPS последних)"
    for phase in phase0 phase1 phase2 phase3 phase4 phase5 phase6 phase7 phase8; do
        local count=$(ls -1t "$BACKUP_DIR"/lfs-${phase}-*.tar.* 2>/dev/null | wc -l)
        if (( count > KEEP_BACKUPS )); then
            ls -1t "$BACKUP_DIR"/lfs-${phase}-*.tar.* | tail -n +$((KEEP_BACKUPS+1)) | while read -r f; do
                log "Удаление старого: $f"
                rm -f "$f"
            done
        fi
    done
}

#------------------------------------------------------------------------------
# CLI
#------------------------------------------------------------------------------
case "${1:-}" in
    create)  create_backup "${2:-manual}" ;;
    restore) restore_backup "${2:-}" ;;
    rotate)  rotate ;;
    list)
        echo "Доступные бэкапы:"
        ls -lht "$BACKUP_DIR"/lfs-*.tar.* 2>/dev/null || echo "  (нет бэкапов)"
        ;;
    *)
        echo "Использование: $0 {create <phase>|restore <archive>|rotate|list}"
        exit 1
        ;;
esac