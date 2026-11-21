#!/bin/bash
###############################################################################
# install-xorg-libs.sh — Сборка библиотек Xorg и Mesa для LFS 13.1-systemd
# Запускать ВНУТРИ chroot от root.
# Использование: bash install-xorg-libs.sh
###############################################################################
set -euo pipefail

# --- Настройки ---
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

# --- Функции ---
RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

extract() {
    cd "$SOURCES"
    rm -rf "$2"
    tar -xf "$1" || die "Не удалось извлечь $1"
    cd "$2"
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
[[ -d "$STOW_DIR" ]] || die "Не найден каталог $STOW_DIR. Установлен ли stow?"
mkdir -p "$STOW_DIR"

# --- 1. Базовые утилиты и протоколы ---
# Примечание: util-macros, xorgproto и xcb-proto — это "meta" пакеты, они устанавливаются напрямую в /usr
log "=== Установка базовых протоколов и макросов ==="
for pkg in util-macros-1.20.2 xorgproto-2024.1 xcb-proto-1.17.0; do
    tar -xf "$SOURCES/$pkg.tar.xz" && cd "$SOURCES/$pkg"
    ./configure --prefix=/usr && make install
    cd "$SOURCES" && rm -rf "$pkg"
done
ok "Базовые протоколы установлены"

# --- 2. libXau, libXdmcp, libxcb ---
build_stow "libXau-1.0.12" "libXau-1.0.12.tar.xz" "libXau-1.0.12"
build_stow "libXdmcp-1.1.5" "libXdmcp-1.1.5.tar.xz" "libXdmcp-1.1.5"

log "=== Сборка libxcb (сначала скрипт) ==="
extract "libxcb-1.17.0.tar.xz" "libxcb-1.17.0"
sed -i 's/#ifdef __cplusplus/#if 0/' src/c_client.py
./configure $XORG_CONFIG --without-doxygen --disable-static
make -j"$(nproc)" && make install
cd "$STOW_DIR" && stow -v --ignore='share/info/dir' "libxcb-1.17.0"
ok "libxcb установлен"
cleanup "libxcb-1.17.0"

# --- 3. Xorg Libraries (основной набор) ---
# Список из BLFS 13.1
XORG_LIBS=(
    xtrans-1.6.0
    libX11-1.8.13
    libXext-1.3.7
    libFS-1.0.10
    libICE-1.1.2
    libSM-1.2.6
    libXScrnSaver-1.2.5
    libXt-1.3.1
    libXmu-1.3.1
    libXpm-3.5.19
    libXaw-1.0.16
    libXfixes-6.0.2
    libXcomposite-0.4.7
    libXrender-0.9.12
    libXcursor-1.2.3
    libXdamage-1.1.7
    libfontenc-1.1.9
    libXfont2-2.0.8
    libXft-2.3.9
    libXi-1.8.3
    libXinerama-1.1.6
    libXrandr-1.5.5
    libXres-1.2.3
    libXtst-1.2.5
    libXv-1.0.13
    libXvMC-1.0.14
    libXxf86dga-1.1.7
    libXxf86vm-1.1.6
    libpciaccess-0.19
    libxkbfile-1.1.4
    libxshmfence-1.3.3
)

for lib in "${XORG_LIBS[@]}"; do
    build_stow "$lib" "$lib.tar.xz" "$lib"
done

# --- 4. Mesa и зависимости ---
# Установка Mako (Python-зависимость для Mesa)
log "=== Установка Mako (зависимость Mesa) ==="
extract "Mako-1.3.10.tar.gz" "Mako-1.3.10"
pip3 wheel -w dist --no-cache-dir --no-build-isolation --no-deps "$PWD"
pip3 install --no-index --find-links dist Mako
ok "Mako установлен"
cleanup "Mako-1.3.10"

# Сборка Mesa
log "=== Сборка Mesa ==="
extract "mesa-26.1.7.tar.xz" "mesa-26.1.7"
mkdir build && cd build
meson setup .. \
    --prefix="$XORG_PREFIX" \
    --buildtype=release \
    -D platforms=x11 \
    -D gallium-drivers=swrast,virgl,vmwgfx \
    -D vulkan-drivers= \
    -D glx=dri \
    -D egl=enabled \
    -D gbm=enabled \
    -D llvm=enabled \
    -D shared-glapi=enabled
ninja
ninja install
cd "$STOW_DIR" && stow -v --ignore='share/info/dir' "mesa-26.1.7"
ok "Mesa установлена"
cleanup "mesa-26.1.7"

# --- 5. libepoxy (нужен для glamor в Xorg Server) ---
log "=== Сборка libepoxy ==="
extract "libepoxy-1.5.10.tar.gz" "libepoxy-1.5.10"
mkdir build && cd build
meson setup .. --prefix="$XORG_PREFIX" --buildtype=release
ninja && ninja install
cd "$STOW_DIR" && stow -v --ignore='share/info/dir' "libepoxy-1.5.10"
ok "libepoxy установлен"
cleanup "libepoxy-1.5.10"

log "Все библиотеки Xorg и Mesa успешно установлены!"