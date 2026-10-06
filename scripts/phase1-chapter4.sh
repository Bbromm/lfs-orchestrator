#!/bin/bash
###############################################################################
# phase1-chapter4.sh — Глава 4: Финальные приготовления
###############################################################################
set -euo pipefail
source "$(dirname "$0")/../lfs-config.sh"

log()  { echo -e "\033[0;34m[$(date +%H:%M:%S)]\033[0m $*"; }
ok()   { echo -e "\033[0;32m[OK]\033[0m $*"; }

#------------------------------------------------------------------------------
# 4.2 Ограниченная структура каталогов
#------------------------------------------------------------------------------
log "Создание структуры каталогов..."
mkdir -pv "$LFS"/{etc,var} "$LFS"/usr/{bin,lib,sbin}
for i in bin lib sbin; do
    ln -sv "usr/$i" "$LFS/$i"
done
case "$(uname -m)" in
    x86_64) mkdir -pv "$LFS/lib64" ;;
esac
mkdir -pv "$LFS/tools"
ok "Структура каталогов создана"

#------------------------------------------------------------------------------
# 4.3 Добавление пользователя lfs
#------------------------------------------------------------------------------
log "Создание пользователя lfs..."
if ! getent group lfs >/dev/null; then
    groupadd lfs
fi
if ! getent passwd lfs >/dev/null; then
    useradd -s /bin/bash -g lfs -m -k /dev/null lfs
fi
ok "Пользователь lfs добавлен (пароль не установлен — используйте su - lfs от root)"

# Права владельца
chown -v lfs "$LFS"/usr{,/*} "$LFS"/var "$LFS"/etc "$LFS"/tools
case "$(uname -m)" in
    x86_64) chown -v lfs "$LFS/lib64" ;;
esac

#------------------------------------------------------------------------------
# 4.4 Настройка окружения пользователя lfs
#------------------------------------------------------------------------------
log "Настройка .bash_profile и .bashrc..."

cat > /home/lfs/.bash_profile << "EOF"
exec env -i HOME=$HOME TERM=$TERM PS1='\u:\w\$ ' /bin/bash
EOF

cat > /home/lfs/.bashrc << EOF
set +h
umask 022
LFS=$LFS
LC_ALL=POSIX
LFS_TGT=$LFS_TGT
PATH=/usr/bin
if [ ! -L /bin ]; then PATH=/bin:\$PATH; fi
PATH=\$LFS/tools/bin:\$PATH
CONFIG_SITE=\$LFS/usr/share/config.site
export LFS LC_ALL LFS_TGT PATH CONFIG_SITE
export MAKEFLAGS=-j\$(nproc)
EOF

chown -v lfs:lfs /home/lfs/.bash_profile /home/lfs/.bashrc
ok "Окружение lfs настроено"

# Отключаем /etc/bash.bashrc (может мешать)
[[ -e /etc/bash.bashrc ]] && mv -v /etc/bash.bashrc /etc/bash.bashrc.NOUSE || true

ok "Глава 4 завершена"