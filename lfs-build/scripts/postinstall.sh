#!/bin/bash
###############################################################################
# postinstall.sh — Глава 11: Финализация
# ЗАПУСКАЕТСЯ ВНУТРИ CHROOT от root
###############################################################################
set -euo pipefail

LFS_VERSION="${LFS_VERSION:-13.1-systemd}"

log() { echo -e "\033[0;34m[$(date +%H:%M:%S)]\033[0m $*"; }
ok()  { echo -e "\033[0;32m[OK]\033[0m $*"; }

# 11.1 /etc/lfs-release
echo "$LFS_VERSION" > /etc/lfs-release
ok "/etc/lfs-release: $LFS_VERSION"

# /etc/lsb-release
cat > /etc/lsb-release << EOF
DISTRIB_ID="Linux From Scratch"
DISTRIB_RELEASE="$LFS_VERSION"
DISTRIB_CODENAME="custom"
DISTRIB_DESCRIPTION="Linux From Scratch"
EOF
ok "/etc/lsb-release создан"

# /etc/os-release (уже может существовать — обновляем)
cat > /etc/os-release << EOF
NAME="Linux From Scratch"
VERSION="$LFS_VERSION"
ID=lfs
PRETTY_NAME="Linux From Scratch $LFS_VERSION"
VERSION_CODENAME="custom"
HOME_URL="https://www.linuxfromscratch.org/lfs/"
RELEASE_TYPE="stable"
EOF
ok "/etc/os-release создан"

# Финальный отчёт
echo
echo "╔════════════════════════════════════════════════════════════╗"
echo "║              🎉 Сборка LFS завершена!                       ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo
echo "Система LFS $LFS_VERSION готова к загрузке."
echo
echo "Следующие шаги:"
echo "  1. Установите пароль root:  passwd root"
echo "  2. Выйдите из chroot:        exit"
echo "  3. Размонтируйте ФС (см. Главу 11.3)"
echo "  4. Перезагрузитесь:          reboot"
echo
ok "Глава 11 завершена"