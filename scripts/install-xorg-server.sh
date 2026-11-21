#!/bin/bash
###############################################################################
# install-xorg-server.sh — Сборка Xorg Server и драйверов для LFS 13.1-systemd
# Запускать ВНУТРИ chroot от root ПОСЛЕ install-xorg-libs.sh
# Использование: bash install-xorg-server.sh
###############################################################################
set -euo pipefail

# --- Настройки (те же, что и в первом скрипте) ---
SOURCES="/sources"
STOW_DIR="/usr/local/stow"
export XORG_PREFIX="/usr/local"
export XORG_CONFIG="--prefix=$XORG_PREFIX --sysconfdir=/etc --localstatedir=/var --disable-static"
export PKG_CONFIG_PATH="$STOW_DIR/lib/pkgconfig:/usr/lib/pkgconfig:/usr/share/pkgconfig"
export LIBRARY_PATH="$STOW_DIR/lib"
export LD_LIBRARY_PATH="$STOW_DIR/lib"
export CFLAGS="-I$STOW_DIR/include"
export CXXFLAGS="-I$STOW_DIR/include"
export LDFLAGS="-L$STOW_DIR/lib"

# --- Функции (копируем из первого скрипта) ---
RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
extract() {
    cd "$SOURCES"; rm -rf "$2"; tar -xf "$1" || die "Не удалось извлечь $1"; cd "$2"
}
cleanup() { cd "$SOURCES"; rm -rf "$1"; ok "Очищен $1"; }
build_stow() {
    local name="$1"; local tarball="$2"; local dir="$3"; shift 3
    log "=== Сборка $name ==="
    extract "$tarball" "$dir"
    ./configure $XORG_CONFIG "$@" && make -j"$(nproc)" && make install
    cd "$STOW_DIR" && stow -v --ignore='share/info/dir' "$dir"
    ok "$name установлен"
    cleanup "$dir"
}

# --- Проверка контекста ---
[[ "$(id -u)" == "0" ]] || die "Запускать от root"
[[ -d "$SOURCES" ]] || die "Не найден каталог $SOURCES"

# --- 1. libxcvt и Pixman (обязательные зависимости сервера) ---
build_stow "libxcvt-0.1.3" "libxcvt-0.1.3.tar.xz" "libxcvt-0.1.3"
build_stow "pixman-0.46.4" "pixman-0.46.4.tar.xz" "pixman-0.46.4"

# --- 2. Шрифты (только font-util для сервера) ---
log "=== Установка font-util ==="
extract "font-util-1.4.1.tar.xz" "font-util-1.4.1"
./configure --prefix=/usr && make install
cleanup "font-util-1.4.1"

# --- 3. libinput (для драйвера ввода) ---
log "=== Сборка libinput ==="
extract "libinput-1.28.1.tar.gz" "libinput-1.28.1"
mkdir build && cd build
meson setup .. \
    --prefix="$XORG_PREFIX" \
    --buildtype=release \
    -D libwacom=false \
    -D debug-gui=false \
    -D tests=false \
    -D documentation=false
ninja && ninja install
cd "$STOW_DIR" && stow -v --ignore='share/info/dir' "libinput-1.28.1"
ok "libinput установлен"
cleanup "libinput-1.28.1"

# --- 4. Xorg Server ---
log "=== Сборка Xorg Server ==="
extract "xorg-server-21.1.24.tar.xz" "xorg-server-21.1.24"
mkdir build && cd build
meson setup .. \
    --prefix="$XORG_PREFIX" \
    --buildtype=release \
    -D suid_wrapper=true \
    -D systemd_logind=true \
    -D glamor=true \
    -D xorg=true \
    -D xephyr=false \
    -D xnest=false \
    -D xvfb=false \
    -D dmx=false \
    -D docs=false \
    -D devel-docs=false
ninja
ninja install
cd "$STOW_DIR" && stow -v --ignore='share/info/dir' "xorg-server-21.1.24"
ok "Xorg Server установлен"
cleanup "xorg-server-21.1.24"

# --- 5. Драйверы ввода ---
build_stow "xf86-input-libinput-1.5.0" "xf86-input-libinput-1.5.0.tar.xz" "xf86-input-libinput-1.5.0"

# --- 6. Драйвер видео для VMware ---
log "=== Сборка xf86-video-vmware ==="
extract "xf86-video-vmware-13.4.0.tar.xz" "xf86-video-vmware-13.4.0"
./configure $XORG_CONFIG --disable-vmwarectrl-client
make -j"$(nproc)" && make install
cd "$STOW_DIR" && stow -v --ignore='share/info/dir' "xf86-video-vmware-13.4.0"
ok "xf86-video-vmware установлен"
cleanup "xf86-video-vmware-13.4.0"

# --- 7. xkeyboard-config (для клавиатуры) ---
log "=== Сборка xkeyboard-config ==="
extract "xkeyboard-config-2.48.tar.xz" "xkeyboard-config-2.48"
mkdir build && cd build
meson setup .. --prefix="$XORG_PREFIX" --buildtype=release
ninja && ninja install
cd "$STOW_DIR" && stow -v --ignore='share/info/dir' "xkeyboard-config-2.48"
ok "xkeyboard-config установлен"
cleanup "xkeyboard-config-2.48"

# --- 8. Финальная настройка ---
log "=== Обновление кэша динамических библиотек ==="
ldconfig

log "=== Создание символической ссылки для драйвера modesetting ==="
mkdir -p "$XORG_PREFIX/lib/xorg/modules/drivers"
ln -sfv "$XORG_PREFIX/lib/xorg/modules/drivers/modesetting_drv.so" \
        "$XORG_PREFIX/lib/xorg/modules/drivers/vmware_drv.so" 2>/dev/null || true

log "Xorg Server и драйверы успешно установлены!"
log "После загрузки системы вы можете запустить Xorg командой 'startx' или настроить его через /etc/X11/xorg.conf."