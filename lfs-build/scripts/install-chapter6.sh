#!/bin/bash
###############################################################################
# LFS 13.1-systemd — Глава 6: Кросс-компиляция временных инструментов
# Запускать от имени пользователя 'lfs' в $LFS/sources
# Использование: bash install-chapter6.sh 2>&1 | tee chapter6.log
###############################################################################
set -euo pipefail

LFS="${LFS:-/mnt/lfs}"
LFS_TGT="${LFS_TGT:-$(uname -m)-lfs-linux-gnu}"
SOURCES="$LFS/sources"
LOG_DIR="$SOURCES/logs"
mkdir -p "$LOG_DIR"
TS="$(date +%Y%m%d-%H%M%S)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
section() { echo; echo "==================================================================="; echo "  $*"; echo "==================================================================="; echo; }

extract() {
    cd "$SOURCES"
    rm -rf "$2"
    tar -xf "$1" || die "Не удалось извлечь $1"
    cd "$2"
}

cleanup() { cd "$SOURCES"; rm -rf "$1"; ok "Очищен $1"; }

check_prereq() {
    section "Проверка предусловий"
    [[ "$(whoami)" == "lfs" ]] || die "Запускать от имени 'lfs'"
    [[ -n "${LFS:-}"     ]] || die "\$LFS не установлена"
    [[ -n "${LFS_TGT:-}" ]] || die "\$LFS_TGT не установлена"
    [[ -d "$LFS/tools"   ]] || die "$LFS/tools отсутствует (выполните Главу 5)"
    ok "Предусловия выполнены"
}

# ============================================================
# 6.2 M4-1.4.21
# ============================================================
build_m4() {
    section "6.2 M4-1.4.21"
    extract "m4-1.4.21.tar.xz" "m4-1.4.21"

    # config.site для gnulib/glibc-2.44
    cat > "$LFS/usr/share/config.site" << EOF
ac_cv_func_posix_spawn_file_actions_addchdir=yes
ac_cv_func_posix_spawn_file_actions_addfchdir=yes
EOF

    ./configure --prefix=/usr \
                --host="$LFS_TGT" \
                --build="$(build-aux/config.guess)"
    make
    make DESTDIR="$LFS" install
    ok "M4 установлен"
    cleanup "m4-1.4.21"
}

# ============================================================
# 6.3 Ncurses-6.6
# ============================================================
build_ncurses() {
    section "6.3 Ncurses-6.6"
    extract "ncurses-6.6.tar.gz" "ncurses-6.6"

    # Сборка tic на хосте и установка в $LFS/tools
    mkdir build && pushd build
    ../configure --prefix="$LFS/tools" AWK=gawk
    make -C include
    make -C progs tic
    install progs/tic "$LFS/tools/bin"
    popd

    ./configure --prefix=/usr \
                --host="$LFS_TGT" \
                --build="$(./config.guess)" \
                --mandir=/usr/share/man \
                --with-manpage-format=normal \
                --with-shared \
                --without-normal \
                --with-cxx-shared \
                --without-debug \
                --without-ada \
                --disable-stripping \
                AWK=gawk
    make
    make DESTDIR="$LFS" install
    ln -sv libncursesw.so "$LFS/usr/lib/libncurses.so"
    sed -e 's/^#if.*XOPEN.*$/#if 1/' -i "$LFS/usr/include/curses.h"
    ok "Ncurses установлен"
    cleanup "ncurses-6.6"
}

# ============================================================
# 6.4 Bash-5.3
# ============================================================
build_bash() {
    section "6.4 Bash-5.3"
    extract "bash-5.3.tar.gz" "bash-5.3"

    ./configure --prefix=/usr \
                --build="$(sh support/config.guess)" \
                --host="$LFS_TGT" \
                --without-bash-malloc \
                --docdir=/usr/share/doc/bash-5.3
    make
    make DESTDIR="$LFS" install
    ln -sv bash "$LFS/bin/sh"
    ok "Bash установлен"
    cleanup "bash-5.3"
}

# ============================================================
# 6.5 Coreutils-9.11
# ============================================================
build_coreutils() {
    section "6.5 Coreutils-9.11"
    extract "coreutils-9.11.tar.xz" "coreutils-9.11"

    ./configure --prefix=/usr \
                --host="$LFS_TGT" \
                --build="$(build-aux/config.guess)" \
                --enable-install-program=hostname
    make
    make DESTDIR="$LFS" install

    # Перемещение chroot в /usr/sbin
    mv -v "$LFS/usr/bin/chroot"              "$LFS/usr/sbin"
    mkdir -pv "$LFS/usr/share/man/man8"
    mv -v "$LFS/usr/share/man/man1/chroot.1" "$LFS/usr/share/man/man8/chroot.8"
    sed -i 's/"1"/"8"/' "$LFS/usr/share/man/man8/chroot.8"
    ok "Coreutils установлен"
    cleanup "coreutils-9.11"
}

# ============================================================
# 6.6 Diffutils-3.12
# ============================================================
build_diffutils() {
    section "6.6 Diffutils-3.12"
    extract "diffutils-3.12.tar.xz" "diffutils-3.12"

    ./configure --prefix=/usr \
                --host="$LFS_TGT" \
                gl_cv_func_strcasecmp_works=yes \
                --build="$(./build-aux/config.guess)"
    make
    make DESTDIR="$LFS" install
    ok "Diffutils установлен"
    cleanup "diffutils-3.12"
}

# ============================================================
# 6.7 File-5.48
# ============================================================
build_file() {
    section "6.7 File-5.48"
    extract "file-5.48.tar.gz" "file-5.48"

    # Хостовая копия file для генерации сигнатур
    mkdir build && pushd build
    ../configure --disable-bzlib --disable-libseccomp --disable-xzlib --disable-zlib
    make
    popd

    ./configure --prefix=/usr --host="$LFS_TGT" --build="$(./config.guess)"
    make FILE_COMPILE="$(pwd)/build/src/file"
    make DESTDIR="$LFS" install
    rm -v "$LFS/usr/lib/libmagic.la"
    ok "File установлен"
    cleanup "file-5.48"
}

# ============================================================
# 6.8 Findutils-4.11.0
# ============================================================
build_findutils() {
    section "6.8 Findutils-4.11.0"
    extract "findutils-4.11.0.tar.xz" "findutils-4.11.0"

    ./configure --prefix=/usr \
                --localstatedir=/var/lib/locate \
                --host="$LFS_TGT" \
                --build="$(build-aux/config.guess)"
    make
    make DESTDIR="$LFS" install
    ok "Findutils установлен"
    cleanup "findutils-4.11.0"
}

# ============================================================
# 6.9 Gawk-5.4.1
# ============================================================
build_gawk() {
    section "6.9 Gawk-5.4.1"
    extract "gawk-5.4.1.tar.xz" "gawk-5.4.1"

    sed -i 's/extras//' Makefile.in
    ./configure --prefix=/usr \
                --host="$LFS_TGT" \
                --build="$(build-aux/config.guess)"
    make
    make DESTDIR="$LFS" install
    ok "Gawk установлен"
    cleanup "gawk-5.4.1"
}

# ============================================================
# 6.10 Grep-3.12
# ============================================================
build_grep() {
    section "6.10 Grep-3.12"
    extract "grep-3.12.tar.xz" "grep-3.12"

    ./configure --prefix=/usr --host="$LFS_TGT" --build="$(./build-aux/config.guess)"
    make
    make DESTDIR="$LFS" install
    ok "Grep установлен"
    cleanup "grep-3.12"
}

# ============================================================
# 6.11 Gzip-1.14
# ============================================================
build_gzip() {
    section "6.11 Gzip-1.14"
    extract "gzip-1.14.tar.xz" "gzip-1.14"

    ./configure --prefix=/usr --host="$LFS_TGT"
    make
    make DESTDIR="$LFS" install
    ok "Gzip установлен"
    cleanup "gzip-1.14"
}

# ============================================================
# 6.12 Make-4.4.1
# ============================================================
build_make() {
    section "6.12 Make-4.4.1"
    extract "make-4.4.1.tar.gz" "make-4.4.1"

    ./configure --prefix=/usr --host="$LFS_TGT" --build="$(build-aux/config.guess)"
    make
    make DESTDIR="$LFS" install
    ok "Make установлен"
    cleanup "make-4.4.1"
}

# ============================================================
# 6.13 Patch-2.8
# ============================================================
build_patch() {
    section "6.13 Patch-2.8"
    extract "patch-2.8.tar.xz" "patch-2.8"

    ./configure --prefix=/usr --host="$LFS_TGT" --build="$(build-aux/config.guess)"
    make
    make DESTDIR="$LFS" install
    ok "Patch установлен"
    cleanup "patch-2.8"
}

# ============================================================
# 6.14 Sed-4.10
# ============================================================
build_sed() {
    section "6.14 Sed-4.10"
    extract "sed-4.10.tar.xz" "sed-4.10"

    ./configure --prefix=/usr --host="$LFS_TGT" --build="$(./build-aux/config.guess)"
    make
    make DESTDIR="$LFS" install
    ok "Sed установлен"
    cleanup "sed-4.10"
}

# ============================================================
# 6.15 Tar-1.35
# ============================================================
build_tar() {
    section "6.15 Tar-1.35"
    extract "tar-1.35.tar.xz" "tar-1.35"

    ./configure --prefix=/usr --host="$LFS_TGT" --build="$(build-aux/config.guess)"
    make
    make DESTDIR="$LFS" install
    ok "Tar установлен"
    cleanup "tar-1.35"
}

# ============================================================
# 6.16 Xz-5.8.3
# ============================================================
build_xz() {
    section "6.16 Xz-5.8.3"
    extract "xz-5.8.3.tar.xz" "xz-5.8.3"

    ./configure --prefix=/usr \
                --host="$LFS_TGT" \
                --build="$(build-aux/config.guess)" \
                --disable-static \
                --docdir=/usr/share/doc/xz-5.8.3
    make
    make DESTDIR="$LFS" install
    rm -v "$LFS/usr/lib/liblzma.la"
    ok "Xz установлен"
    cleanup "xz-5.8.3"
}

# ============================================================
# 6.17 Binutils-2.47 — Pass 2
# ============================================================
build_binutils_pass2() {
    section "6.17 Binutils-2.47 — Pass 2"
    extract "binutils-2.47.tar.xz" "binutils-2.47"

    # Обход несоответствия libtool
    sed '6031s/$add_dir//' -i ltmain.sh

    mkdir -v build && cd build
    ../configure --prefix=/usr \
                 --build="$(../config.guess)" \
                 --host="$LFS_TGT" \
                 --disable-nls \
                 --enable-shared \
                 --enable-gprofng=no \
                 --disable-werror \
                 --enable-64-bit-bfd \
                 --enable-new-dtags \
                 --enable-default-hash-style=gnu
    make
    make DESTDIR="$LFS" install

    rm -v "$LFS"/usr/lib/lib{bfd,ctf,ctf-nobfd,opcodes,sframe}.{a,la}
    ok "Binutils pass 2 установлен"
    cleanup "binutils-2.47"
}

# ============================================================
# 6.18 GCC-16.2.0 — Pass 2
# ============================================================
build_gcc_pass2() {
    section "6.18 GCC-16.2.0 — Pass 2"
    extract "gcc-16.2.0.tar.xz" "gcc-16.2.0"

    # GMP/MPFR/MPC
    tar -xf ../mpfr-4.2.2.tar.xz && mv -v mpfr-4.2.2 mpfr
    tar -xf ../gmp-6.3.0.tar.xz  && mv -v gmp-6.3.0  gmp
    tar -xf ../mpc-1.4.1.tar.xz  && mv -v mpc-1.4.1  mpc

    # На x86_64 — lib вместо lib64
    if [[ "$(uname -m)" == "x86_64" ]]; then
        sed -e '/m64=/s/lib64/lib/' -i.orig gcc/config/i386/t-linux64
    fi

    mkdir -v build && cd build

    # Снять переменные оптимизации
    unset CFLAGS CXXFLAGS LDFLAGS 2>/dev/null || true

    ../configure --build="$(../config.guess)" \
                 --host="$LFS_TGT" \
                 --target="$LFS_TGT" \
                 --prefix=/usr \
                 --with-build-sysroot="$LFS" \
                 --enable-default-pie \
                 --enable-default-ssp \
                 --disable-fixincludes \
                 --disable-nls \
                 --disable-multilib \
                 --disable-libatomic \
                 --disable-libgomp \
                 --disable-libquadmath \
                 --disable-libsanitizer \
                 --disable-libssp \
                 --disable-libvtv \
                 --enable-languages=c,c++ \
                 CXX_FOR_TARGET="$LFS_TGT-gcc -nostdinc++" \
                 LDFLAGS_FOR_TARGET="-L$PWD/$LFS_TGT/libgcc" \
                 target_configargs=gcc_cv_target_thread_file=posix
    make
    make DESTDIR="$LFS" install
    ln -sv gcc "$LFS/usr/bin/cc"
    ok "GCC pass 2 установлен"
    cleanup "gcc-16.2.0"
}

# ============================================================
main() {
    echo "###### LFS Глава 6 — Начало: $(date) ######"
    check_prereq

    build_m4
    build_ncurses
    build_bash
    build_coreutils
    build_diffutils
    build_file
    build_findutils
    build_gawk
    build_grep
    build_gzip
    build_make
    build_patch
    build_sed
    build_tar
    build_xz
    build_binutils_pass2
    build_gcc_pass2

    section "Глава 6 завершена"
    echo "Инструменты в $LFS/tools/bin:"
    ls -1 "$LFS/tools/bin" | head -20
    ok "Все пакеты Главы 6 установлены. Логи в $LOG_DIR/"
}
main "$@" 2>&1 | tee "$LOG_DIR/chapter6-$TS.log"
exit "${PIPESTATUS[0]}"