#!/bin/bash
###############################################################################
# LFS 13.1-systemd — Глава 8: Установка базового системного ПО
# Запускать ВНУТРИ chroot от root.
# Использование: bash /install-chapter8.sh 2>&1 | tee /sources/logs/chapter8.log
# Переменные:
#   RUN_TESTS=1  — включать тестовые наборы (по умолчанию 0)
###############################################################################
set -euo pipefail

SOURCES="/sources"
LOG_DIR="$SOURCES/logs"
mkdir -p "$LOG_DIR"
TS="$(date +%Y%m%d-%H%M%S)"
RUN_TESTS="${RUN_TESTS:-0}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
section() { echo; echo "==================================================================="; echo "  $*"; echo "==================================================================="; echo; }
extract() { cd "$SOURCES"; rm -rf "$2"; tar -xf "$1"; cd "$2"; }
cleanup() { cd "$SOURCES"; rm -rf "$1"; ok "Очищен $1"; }
run_tests() { [[ "$RUN_TESTS" == "1" ]]; }

check_prereq() {
    [[ "$(id -u)" == "0" ]] || die "Запускать от root внутри chroot"
    [[ -f /etc/lfs-release ]] && ok "Система LFS" || warn "Не похоже на LFS"
    ok "Предусловия выполнены"
}

# ============================================================
# 8.3 Man-pages-6.18
# ============================================================
pkg_man_pages() {
    section "8.3 Man-pages-6.18"
    extract "man-pages-6.18.tar.xz" "man-pages-6.18"
    rm -v man3/crypt*
    make -R GIT=false prefix=/usr install
    ok "Man-pages установлены"
    cleanup "man-pages-6.18"
}

# ============================================================
# 8.4 Iana-Etc-20260805
# ============================================================
pkg_iana_etc() {
    section "8.4 Iana-Etc-20260805"
    extract "iana-etc-20260805.tar.gz" "iana-etc-20260805"
    cp -v services protocols /etc
    ok "Iana-Etc установлен"
    cleanup "iana-etc-20260805"
}

# ============================================================
# 8.5 Glibc-2.44
# ============================================================
pkg_glibc() {
    section "8.5 Glibc-2.44"
    extract "glibc-2.44.tar.xz" "glibc-2.44"

    patch -Np1 -i ../glibc-fhs-1.patch
    patch -Np1 -i ../glibc-2.44-upstream_fixes-1.patch

    mkdir -v build && cd build
    ../configure --prefix=/usr \
                 --disable-werror \
                 --disable-nscd \
                 libc_cv_slibdir=/usr/lib \
                 --enable-stack-protector=strong \
                 --enable-kernel=5.10
    make

    if run_tests; then
        log "Тестовый набор Glibc (может быть долго)..."
        make check || warn "Некоторые тесты Glibc могли не пройти (см. лог)"
    fi

    touch /etc/ld.so.conf
    sed '/test-installation/s@$(PERL)@echo not running@' -i ../Makefile
    make install
    sed '/RTLDLIST=/s@/usr@@g' -i /usr/bin/ldd

    # Локали (минимальный набор)
    log "Установка минимального набора локалей..."
    localedef -i C -f UTF-8 C.UTF-8
    localedef -i cs_CZ -f UTF-8 cs_CZ.UTF-8
    localedef -i de_DE -f ISO-8859-1 de_DE
    localedef -i de_DE@euro -f ISO-8859-15 de_DE@euro
    localedef -i de_DE -f UTF-8 de_DE.UTF-8
    localedef -i el_GR -f ISO-8859-7 el_GR
    localedef -i en_GB -f ISO-8859-1 en_GB
    localedef -i en_GB -f UTF-8 en_GB.UTF-8
    localedef -i en_HK -f ISO-8859-1 en_HK
    localedef -i en_PH -f ISO-8859-1 en_PH
    localedef -i en_US -f ISO-8859-1 en_US
    localedef -i en_US -f UTF-8 en_US.UTF-8
    localedef -i es_ES -f ISO-8859-15 es_ES@euro
    localedef -i es_MX -f ISO-8859-1 es_MX
    localedef -i fa_IR -f UTF-8 fa_IR
    localedef -i fr_FR -f ISO-8859-1 fr_FR
    localedef -i fr_FR@euro -f ISO-8859-15 fr_FR@euro
    localedef -i fr_FR -f UTF-8 fr_FR.UTF-8
    localedef -i is_IS -f ISO-8859-1 is_IS
    localedef -i is_IS -f UTF-8 is_IS.UTF-8
    localedef -i it_IT -f ISO-8859-1 it_IT
    localedef -i it_IT -f ISO-8859-15 it_IT@euro
    localedef -i it_IT -f UTF-8 it_IT.UTF-8
    localedef -i ja_JP -f EUC-JP ja_JP
    localedef -i ja_JP -f UTF-8 ja_JP.UTF-8
    localedef -i nl_NL@euro -f ISO-8859-15 nl_NL@euro
    localedef -i ru_RU -f KOI8-R ru_RU.KOI8-R
    localedef -i ru_RU -f UTF-8 ru_RU.UTF-8
    localedef -i se_NO -f UTF-8 se_NO.UTF-8
    localedef -i ta_IN -f UTF-8 ta_IN.UTF-8
    localedef -i tr_TR -f UTF-8 tr_TR.UTF-8
    localedef -i zh_CN -f GB18030 zh_CN.GB18030
    localedef -i zh_HK -f BIG5-HKSCS zh_HK.BIG5-HKSCS
    localedef -i zh_TW -f UTF-8 zh_TW.UTF-8

    # nsswitch.conf
    cat > /etc/nsswitch.conf << "EOF"
passwd: files systemd
group: files systemd
shadow: files systemd
hosts: mymachines resolve [!UNAVAIL=return] files myhostname dns
networks: files
protocols: files
services: files
ethers: files
rpc: files
EOF

    # tzdata
    log "Установка tzdata..."
    tar -xf "$SOURCES/tzdata2026c.tar.gz" -C /tmp
    (cd /tmp && ZONEINFO=/usr/share/zoneinfo
     mkdir -pv $ZONEINFO/{posix,right}
     for tz in etcetera southamerica northamerica europe africa antarctica asia australasia backward; do
        zic -L /dev/null -d $ZONEINFO ${tz}
        zic -L /dev/null -d $ZONEINFO/posix ${tz}
        zic -L leapseconds -d $ZONEINFO/right ${tz}
     done
     cp -v zone.tab zone1970.tab iso3166.tab $ZONEINFO
     zic -d $ZONEINFO -p America/New_York)
    ln -sfv /usr/share/zoneinfo/America/New_York /etc/localtime

    # ld.so.conf
    cat > /etc/ld.so.conf << "EOF"
/usr/local/lib
/opt/lib
include /etc/ld.so.conf.d/*.conf
EOF
    mkdir -pv /etc/ld.so.conf.d

    ok "Glibc установлена"
    cleanup "glibc-2.44"
}

# ============================================================
# Универсальный сборщик (для простых пакетов)
# ============================================================
simple_build() {
    # Параметры: name tarball dirname configure_args...
    local name="$1"; shift
    local tarball="$1"; shift
    local dirname="$1"; shift

    section "$name"
    extract "$tarball" "$dirname"
    if [[ $# -gt 0 ]]; then
        ./configure "$@"
    fi
    make
    if run_tests; then
        make check 2>/dev/null || warn "$name: некоторые тесты не прошли"
    fi
    make install
    ok "$name установлен"
    cleanup "$dirname"
}

# ============================================================
# 8.6 Zlib-1.3.2
# ============================================================
pkg_zlib() {
    section "8.6 Zlib-1.3.2"
    extract "zlib-1.3.2.tar.gz" "zlib-1.3.2"
    ./configure --prefix=/usr
    make
    run_tests && make check || true
    make install
    rm -fv /usr/lib/libz.a
    ok "Zlib установлен"
    cleanup "zlib-1.3.2"
}

# ============================================================
# 8.7 Bzip2-1.0.8
# ============================================================
pkg_bzip2() {
    section "8.7 Bzip2-1.0.8"
    extract "bzip2-1.0.8.tar.gz" "bzip2-1.0.8"
    patch -Np1 -i ../bzip2-1.0.8-install_docs-1.patch
    sed -i 's@\(ln -s -f \)$(PREFIX)/bin/@\1@' Makefile
    sed -i "s@(PREFIX)/man@(PREFIX)/share/man@g" Makefile
    make -f Makefile-libbz2_so
    make clean
    make
    make PREFIX=/usr install
    cp -av libbz2.so.* /usr/lib
    ln -sfv libbz2.so.1.0.8 /usr/lib/libbz2.so
    ln -sfv libbz2.so.1.0.8 /usr/lib/libbz2.so.1
    cp -v bzip2-shared /usr/bin/bzip2
    for i in /usr/bin/{bzcat,bunzip2}; do ln -sfv bzip2 $i; done
    rm -fv /usr/lib/libbz2.a
    ok "Bzip2 установлен"
    cleanup "bzip2-1.0.8"
}

# ============================================================
# 8.8 Xz-5.8.3
# ============================================================
pkg_xz() {
    simple_build "8.8 Xz-5.8.3" "xz-5.8.3.tar.xz" "xz-5.8.3" \
        --prefix=/usr --disable-static --docdir=/usr/share/doc/xz-5.8.3
}

# ============================================================
# 8.9 Lz4-1.10.0
# ============================================================
pkg_lz4() {
    section "8.9 Lz4-1.10.0"
    extract "lz4-1.10.0.tar.gz" "lz4-1.10.0"
    make BUILD_STATIC=no PREFIX=/usr
    run_tests && make -j1 check || true
    make BUILD_STATIC=no PREFIX=/usr install
    ok "Lz4 установлен"
    cleanup "lz4-1.10.0"
}

# ============================================================
# 8.10 Zstd-1.5.7
# ============================================================
pkg_zstd() {
    section "8.10 Zstd-1.5.7"
    extract "zstd-1.5.7.tar.gz" "zstd-1.5.7"
    make prefix=/usr
    run_tests && make check || true
    make prefix=/usr install
    rm -v /usr/lib/libzstd.a
    ok "Zstd установлен"
    cleanup "zstd-1.5.7"
}

# ============================================================
# Универсальные простые пакеты (8.11 - 8.16)
# ============================================================
pkg_file       () { simple_build "8.11 File-5.48" "file-5.48.tar.gz" "file-5.48" --prefix=/usr; }
pkg_readline   () {
    section "8.12 Readline-8.3"
    extract "readline-8.3.tar.gz" "readline-8.3"
    sed -i '/MV.*old/d' Makefile.in
    sed -i '/{OLDSUFF}/c:' support/shlib-install
    sed -i 's/-Wl,-rpath,[^ ]*//' support/shobj-conf
    sed -e '270a\
     else\
       chars_avail = 1;' \
        -e '288i\   result = -1;' \
        -i.orig input.c
    ./configure --prefix=/usr --disable-static --with-curses \
                --docdir=/usr/share/doc/readline-8.3
    make SHLIB_LIBS="-lncursesw"
    make install
    install -v -m644 doc/*.{ps,pdf,html,dvi} /usr/share/doc/readline-8.3 2>/dev/null || true
    ok "Readline установлен"
    cleanup "readline-8.3"
}
pkg_pcre2      () {
    simple_build "8.13 Pcre2-10.47" "pcre2-10.47.tar.bz2" "pcre2-10.47" \
        --prefix=/usr --docdir=/usr/share/doc/pcre2-10.47 \
        --enable-unicode --enable-jit --enable-pcre2-16 --enable-pcre2-32 \
        --enable-pcre2grep-libz --enable-pcre2grep-libbz2 \
        --enable-pcre2test-libreadline --disable-static
}
pkg_m4         () { simple_build "8.14 M4-1.4.21" "m4-1.4.21.tar.xz" "m4-1.4.21" --prefix=/usr; }
pkg_bc         () {
    section "8.15 Bc-7.0.3"
    extract "bc-7.0.3.tar.xz" "bc-7.0.3"
    CC='gcc -std=c99' ./configure --prefix=/usr -G -O3 -r
    make
    run_tests && make test || true
    make install
    ok "Bc установлен"
    cleanup "bc-7.0.3"
}
pkg_flex       () {
    section "8.16 Flex-2.6.4"
    extract "flex-2.6.4.tar.gz" "flex-2.6.4"
    ./configure --prefix=/usr --disable-static --docdir=/usr/share/doc/flex-2.6.4
    make
    run_tests && make check || true
    make install
    ln -sv flex /usr/bin/lex
    ln -sv flex.1 /usr/share/man/man1/lex.1
    ok "Flex установлен"
    cleanup "flex-2.6.4"
}

# ============================================================
# 8.17 Tcl-8.6.18
# ============================================================
pkg_tcl() {
    section "8.17 Tcl-8.6.18"
    extract "tcl8.6.18-src.tar.gz" "tcl8.6.18"
    SRCDIR="$(pwd)"
    cd unix
    ./configure --prefix=/usr --mandir=/usr/share/man --disable-rpath
    make
    sed -e "s|$SRCDIR/unix|/usr/lib|" -e "s|$SRCDIR|/usr/include|" -i tclConfig.sh
    sed -e "s|$SRCDIR/unix/pkgs/tdbc1.1.13|/usr/lib/tdbc1.1.13|" \
        -e "s|$SRCDIR/pkgs/tdbc1.1.13/generic|/usr/include|" \
        -e "s|$SRCDIR/pkgs/tdbc1.1.13/library|/usr/lib/tcl8.6|" \
        -e "s|$SRCDIR/pkgs/tdbc1.1.13|/usr/include|" \
        -i pkgs/tdbc1.1.13/tdbcConfig.sh
    sed -e "s|$SRCDIR/unix/pkgs/itcl4.3.7|/usr/lib/itcl4.3.7|" \
        -e "s|$SRCDIR/pkgs/itcl4.3.7/generic|/usr/include|" \
        -e "s|$SRCDIR/pkgs/itcl4.3.7|/usr/include|" \
        -i pkgs/itcl4.3.7/itclConfig.sh
    unset SRCDIR
    run_tests && LC_ALL=C.UTF-8 make test || true
    make install
    chmod 644 /usr/lib/libtclstub8.6.a
    chmod -v u+w /usr/lib/libtcl8.6.so
    make install-private-headers
    ln -sfv tclsh8.6 /usr/bin/tclsh
    mv -v /usr/share/man/man3/{Thread,Tcl_Thread}.3
    ok "Tcl установлен"
    cleanup "tcl8.6.18"
}

# ============================================================
# 8.18 Expect-5.45.4
# ============================================================
pkg_expect() {
    section "8.18 Expect-5.45.4"
    extract "expect5.45.4.tar.gz" "expect5.45.4"
    python3 -c 'from pty import spawn; spawn(["echo", "ok"])' || die "PTY не работают"
    patch -Np1 -i ../expect-5.45.4-gcc15-1.patch
    ./configure --prefix=/usr \
                --with-tcl=/usr/lib \
                --enable-shared \
                --disable-rpath \
                --mandir=/usr/share/man \
                --with-tclinclude=/usr/include
    make
    run_tests && make test || true
    make install
    ln -svf expect5.45.4/libexpect5.45.4.so /usr/lib
    ok "Expect установлен"
    cleanup "expect5.45.4"
}

# ============================================================
# 8.19 DejaGNU-1.6.3
# ============================================================
pkg_dejagnu() {
    section "8.19 DejaGNU-1.6.3"
    extract "dejagnu-1.6.3.tar.gz" "dejagnu-1.6.3"
    mkdir -v build && cd build
    ../configure --prefix=/usr
    makeinfo --html --no-split -o doc/dejagnu.html ../doc/dejagnu.texi
    makeinfo --plaintext -o doc/dejagnu.txt ../doc/dejagnu.texi
    run_tests && make check || true
    make install
    install -v -dm755 /usr/share/doc/dejagnu-1.6.3
    install -v -m644 doc/dejagnu.{html,txt} /usr/share/doc/dejagnu-1.6.3
    ok "DejaGNU установлен"
    cleanup "dejagnu-1.6.3"
}

# ============================================================
# 8.20 Ninja-1.13.2
# ============================================================
pkg_ninja() {
    section "8.20 Ninja-1.13.2"
    extract "ninja-1.13.2.tar.gz" "ninja-1.13.2"
    sed -i '/int Guess/a \
  int   j = 0;\
  char* jobs = getenv( "NINJAJOBS" );\
  if ( jobs != NULL ) j = atoi( jobs );\
  if ( j > 0 ) return j;\
' src/ninja.cc
    python3 configure.py --bootstrap --verbose
    install -vm755 ninja /usr/bin/
    install -vDm644 misc/bash-completion /usr/share/bash-completion/completions/ninja
    install -vDm644 misc/zsh-completion  /usr/share/zsh/site-functions/_ninja
    ok "Ninja установлен"
    cleanup "ninja-1.13.2"
}

# ============================================================
# 8.21 Pkgconf-3.0.5
# ============================================================
pkg_pkgconf() {
    section "8.21 Pkgconf-3.0.5"
    extract "pkgconf-3.0.5.tar.xz" "pkgconf-3.0.5"
    tar -xf ../meson-1.12.0.tar.gz
    mkdir build && cd build
    python3 ../meson-1.12.0/meson.py setup --prefix=/usr --buildtype=release ..
    ninja
    run_tests && ninja test || true
    ninja install
    mv /usr/share/doc/pkgconf{,-3.0.5}
    ln -sv pkgconf /usr/bin/pkg-config
    ln -sv pkgconf.1 /usr/share/man/man1/pkg-config.1
    ok "Pkgconf установлен"
    cleanup "pkgconf-3.0.5"
}

# ============================================================
# 8.22 Binutils-2.47
# ============================================================
pkg_binutils() {
    section "8.22 Binutils-2.47"
    extract "binutils-2.47.tar.xz" "binutils-2.47"
    mkdir -v build && cd build
    ../configure --prefix=/usr \
                 --sysconfdir=/etc \
                 --enable-ld=default \
                 --enable-plugins \
                 --enable-shared \
                 --disable-werror \
                 --enable-64-bit-bfd \
                 --enable-new-dtags \
                 --with-system-zlib \
                 --with-lib-path=/usr/lib \
                 --enable-default-hash-style=gnu
    make tooldir=/usr
    if run_tests; then
        make -k check || true
        grep '^FAIL:' $(find -name '*.log') || true
    fi
    make tooldir=/usr install
    rm -rfv /usr/lib/lib{bfd,ctf,ctf-nobfd,gprofng,opcodes,sframe}.a \
            /usr/share/doc/gprofng/
    ok "Binutils установлен"
    cleanup "binutils-2.47"
}

# ============================================================
# 8.23 GMP-6.3.0
# ============================================================
pkg_gmp() {
    section "8.23 GMP-6.3.0"
    extract "gmp-6.3.0.tar.xz" "gmp-6.3.0"
    sed -i '/long long t1;/,+1s/()/(...)/' configure
    ./configure --prefix=/usr --enable-cxx --disable-static \
                --docdir=/usr/share/doc/gmp-6.3.0
    make
    make html
    if run_tests; then
        make check || warn "GMP check failed"
        cat $(find -name '*.log') | grep -c ^PASS || true
    fi
    make install
    make install-html
    ok "GMP установлен"
    cleanup "gmp-6.3.0"
}

# ============================================================
# 8.24 MPFR-4.2.2
# ============================================================
pkg_mpfr() {
    section "8.24 MPFR-4.2.2"
    extract "mpfr-4.2.2.tar.xz" "mpfr-4.2.2"
    ./configure --prefix=/usr --disable-static --enable-thread-safe \
                --docdir=/usr/share/doc/mpfr-4.2.2
    make
    make html
    if run_tests; then
        make check || warn "MPFR check failed"
    fi
    make install
    make install-html
    ok "MPFR установлен"
    cleanup "mpfr-4.2.2"
}

# ============================================================
# 8.25 MPC-1.4.1
# ============================================================
pkg_mpc() {
    section "8.25 MPC-1.4.1"
    extract "mpc-1.4.1.tar.xz" "mpc-1.4.1"
    ./configure --prefix=/usr --disable-static --docdir=/usr/share/doc/mpc-1.4.1
    make
    make html
    run_tests && make check || true
    make install
    make install-html
    ok "MPC установлен"
    cleanup "mpc-1.4.1"
}

# ============================================================
# 8.26 - 8.28 Attr, Acl, Libcap
# ============================================================
pkg_attr()   { simple_build "8.26 Attr-2.6.0" "attr-2.6.0.tar.gz" "attr-2.6.0" \
               --prefix=/usr --disable-static --sysconfdir=/etc \
               --docdir=/usr/share/doc/attr-2.6.0; }
pkg_acl()    { simple_build "8.27 Acl-2.4.0" "acl-2.4.0.tar.xz" "acl-2.4.0" \
               --prefix=/usr --disable-static --docdir=/usr/share/doc/acl-2.4.0; }
pkg_libcap() {
    section "8.28 Libcap-2.78"
    extract "libcap-2.78.tar.xz" "libcap-2.78"
    sed -i '/install -m.*STA/d' libcap/Makefile
    make prefix=/usr lib=lib
    run_tests && make test || true
    make prefix=/usr lib=lib install
    ok "Libcap установлен"
    cleanup "libcap-2.78"
}

# ============================================================
# 8.29 Libxcrypt-4.5.2
# ============================================================
pkg_libxcrypt() {
    section "8.29 Libxcrypt-4.5.2"
    extract "libxcrypt-4.5.2.tar.xz" "libxcrypt-4.5.2"
    sed -i '/strchr/s/const//' lib/crypt-{sm3,gost}-yescrypt.c
    ./configure --prefix=/usr \
                --enable-hashes=strong,glibc \
                --enable-obsolete-api=no \
                --disable-static \
                --disable-failure-tokens
    make
    run_tests && make check || true
    make install
    ok "Libxcrypt установлен"
    cleanup "libxcrypt-4.5.2"
}

# ============================================================
# 8.30 Shadow-4.20.2
# ============================================================
pkg_shadow() {
    section "8.30 Shadow-4.20.2"
    extract "shadow-4.20.2.tar.xz" "shadow-4.20.2"
    find man -name Makefile.in -exec sed -i 's/getspnam\.3 / /' {} \;
    find man -name Makefile.in -exec sed -i 's/passwd\.5 / /' {} \;
    sed -e 's:#ENCRYPT_METHOD SHA512:ENCRYPT_METHOD YESCRYPT:' \
        -e 's:/var/spool/mail:/var/mail:' \
        -e '/PATH=/{s@/sbin:@@;s@/bin:@@}' \
        -i etc/login.defs
    touch /usr/bin/passwd
    ./configure --sysconfdir=/etc \
                --disable-static \
                --with-{b,yes}crypt \
                --without-libbsd \
                --disable-logind \
                --with-group-name-max-length=32
    make
    make exec_prefix=/usr install
    make -C man install-man

    # Конфигурация
    pwconv
    grpconv
    mkdir -p /etc/default
    useradd -D --gid 999
    touch /etc/sub{u,g}id
    ok "Shadow установлен"
    cleanup "shadow-4.20.2"
}

# ============================================================
# 8.31 - 8.32 Gawk, GCC
# ============================================================
pkg_gawk() {
    section "8.31 Gawk-5.4.1"
    extract "gawk-5.4.1.tar.xz" "gawk-5.4.1"
    sed -i 's/extras//' Makefile.in
    ./configure --prefix=/usr
    make
    if run_tests; then
        chown -R tester .
        su tester -c "PATH=$PATH make check" || warn "Gawk check failed"
    fi
    rm -f /usr/bin/gawk-5.4.1
    make install
    ln -sv gawk.1 /usr/share/man/man1/awk.1
    ok "Gawk установлен"
    cleanup "gawk-5.4.1"
}

pkg_gcc() {
    section "8.32 GCC-16.2.0"
    extract "gcc-16.2.0.tar.xz" "gcc-16.2.0"
    if [[ "$(uname -m)" == "x86_64" ]]; then
        sed -e '/m64=/s/lib64/lib/' -i.orig gcc/config/i386/t-linux64
    fi
    mkdir -v build && cd build
    ../configure --prefix=/usr \
                 LD=ld \
                 --enable-languages=c,c++ \
                 --enable-default-pie \
                 --enable-default-ssp \
                 --enable-host-pie \
                 --enable-targets=all \
                 --disable-multilib \
                 --disable-bootstrap \
                 --disable-fixincludes \
                 --with-system-zlib
    make
    if run_tests; then
        ulimit -s -H unlimited || true
        chown -R tester .
        su tester -c "PATH=$PATH make -k check" || warn "GCC check had failures"
        ../contrib/test_summary -t 2>/dev/null | grep -A7 Summ || true
    fi
    make install
    chown -v -R root:root "$(gcc -print-file-name=include)"{,-fixed}
    ln -svr /usr/bin/cpp /usr/lib
    ln -sv gcc.1 /usr/share/man/man1/cc.1
    ln -sfvr "$(gcc -print-prog-name=liblto_plugin.so)" /usr/lib/bfd-plugins/
    mkdir -pv /usr/share/gdb/auto-load/usr/lib
    mv -v /usr/lib/*gdb.py /usr/share/gdb/auto-load/usr/lib
    ok "GCC установлен"
    cleanup "gcc-16.2.0"
}

# ============================================================
# 8.33 - 8.38 Ncurses, Sed, Psmisc, Gettext, Bison, Grep
# ============================================================
pkg_ncurses() {
    section "8.33 Ncurses-6.6"
    extract "ncurses-6.6.tar.gz" "ncurses-6.6"
    ./configure --prefix=/usr --mandir=/usr/share/man --with-shared \
                --without-debug --without-normal --with-cxx-shared \
                --enable-pc-files --with-pkg-config-libdir=/usr/lib/pkgconfig
    make
    make DESTDIR="$PWD/dest" install
    sed -e 's/^#if.*XOPEN.*$/#if 1/' -i dest/usr/include/curses.h
    cp --remove-destination -av dest/* /
    for lib in ncurses form panel menu; do
        ln -sfv "lib${lib}w.so" "/usr/lib/lib${lib}.so"
        ln -sfv "${lib}w.pc" "/usr/lib/pkgconfig/${lib}.pc"
    done
    ln -sfv libncursesw.so /usr/lib/libcurses.so
    cp -v -R doc -T /usr/share/doc/ncurses-6.6
    ok "Ncurses установлен"
    cleanup "ncurses-6.6"
}
pkg_sed() {
    section "8.34 Sed-4.10"
    extract "sed-4.10.tar.xz" "sed-4.10"
    ./configure --prefix=/usr
    make
    make html
    if run_tests; then
        chown -R tester .
        su tester -c "PATH=$PATH make check" || warn "Sed check failed"
    fi
    make install
    install -vDm644 doc/sed.html -t /usr/share/doc/sed-4.10
    ok "Sed установлен"
    cleanup "sed-4.10"
}
pkg_psmisc() {
    section "8.35 Psmisc-23.7"
    extract "psmisc-23.7.tar.xz" "psmisc-23.7"
    ./configure --prefix=/usr
    make
    run_tests && make check || true
    make install
    ok "Psmisc установлен"
    cleanup "psmisc-23.7"
}
pkg_gettext() {
    section "8.36 Gettext-1.0"
    extract "gettext-1.0.tar.xz" "gettext-1.0"
    ./configure --prefix=/usr --disable-static --docdir=/usr/share/doc/gettext-1.0
    make
    run_tests && make check || true
    make install
    chmod -v 0755 /usr/lib/preloadable_libintl.so
    ok "Gettext установлен"
    cleanup "gettext-1.0"
}
pkg_bison() {
    simple_build "8.37 Bison-3.8.2" "bison-3.8.2.tar.xz" "bison-3.8.2" \
        --prefix=/usr --docdir=/usr/share/doc/bison-3.8.2
}
pkg_grep() {
    section "8.38 Grep-3.12"
    extract "grep-3.12.tar.xz" "grep-3.12"
    sed -i "s/echo/#echo/" src/egrep.sh
    ./configure --prefix=/usr
    make
    run_tests && make check || true
    make install
    ok "Grep установлен"
    cleanup "grep-3.12"
}

# ============================================================
# 8.39 Bash-5.3
# ============================================================
pkg_bash() {
    section "8.39 Bash-5.3"
    extract "bash-5.3.tar.gz" "bash-5.3"
    ./configure --prefix=/usr --without-bash-malloc \
                --with-installed-readline --docdir=/usr/share/doc/bash-5.3
    make
    if run_tests; then
        chown -R tester .
        LC_ALL=C.UTF-8 su -s /usr/bin/expect tester << "EOF" || true
set timeout -1
spawn make tests
expect eof
lassign [wait] _ _ _ value
exit $value
EOF
    fi
    make install
    ok "Bash установлен (перезапустите оболочку: exec /usr/bin/bash --login)"
    cleanup "bash-5.3"
}

# ============================================================
# 8.40 - 8.45 Libtool, GDBM, Gperf, Expat, Inetutils, Less
# ============================================================
pkg_libtool() {
    section "8.40 Libtool-2.6.2"
    extract "libtool-2.6.2.tar.xz" "libtool-2.6.2"
    ./configure --prefix=/usr
    make
    run_tests && make check || true
    make install
    rm -fv /usr/lib/libltdl.a
    ok "Libtool установлен"
    cleanup "libtool-2.6.2"
}
pkg_gdbm() {
    simple_build "8.41 GDBM-1.26" "gdbm-1.26.tar.gz" "gdbm-1.26" \
        --prefix=/usr --disable-static --enable-libgdbm-compat
}
pkg_gperf() {
    simple_build "8.42 Gperf-3.3" "gperf-3.3.tar.gz" "gperf-3.3" \
        --prefix=/usr --docdir=/usr/share/doc/gperf-3.3
}
pkg_expat() {
    simple_build "8.43 Expat-2.8.3" "expat-2.8.3.tar.xz" "expat-2.8.3" \
        --prefix=/usr --disable-static --docdir=/usr/share/doc/expat-2.8.3
}
pkg_inetutils() {
    section "8.44 Inetutils-2.8"
    extract "inetutils-2.8.tar.gz" "inetutils-2.8"
    sed -i 's/def HAVE_TERMCAP_TGETENT/ 1/' telnet/telnet.c
    ./configure --prefix=/usr --bindir=/usr/bin --localstatedir=/var \
                --disable-logger --disable-whois \
                --disable-rcp --disable-rexec --disable-rlogin --disable-rsh \
                --disable-servers
    make
    run_tests && make check || true
    make install
    mv -v /usr/{,s}bin/ifconfig
    ok "Inetutils установлен"
    cleanup "inetutils-2.8"
}
pkg_less() {
    simple_build "8.45 Less-704" "less-704.tar.gz" "less-704" \
        --prefix=/usr --sysconfdir=/etc
}

# ============================================================
# 8.46 Perl-5.44.0
# ============================================================
pkg_perl() {
    section "8.46 Perl-5.44.0"
    extract "perl-5.44.0.tar.xz" "perl-5.44.0"
    export BUILD_ZLIB=False
    export BUILD_BZIP2=0
    sh Configure -des \
        -D prefix=/usr -D vendorprefix=/usr \
        -D privlib=/usr/lib/perl5/5.44/core_perl \
        -D archlib=/usr/lib/perl5/5.44/core_perl \
        -D sitelib=/usr/lib/perl5/5.44/site_perl \
        -D sitearch=/usr/lib/perl5/5.44/site_perl \
        -D vendorlib=/usr/lib/perl5/5.44/vendor_perl \
        -D vendorarch=/usr/lib/perl5/5.44/vendor_perl \
        -D man1dir=/usr/share/man/man1 -D man3dir=/usr/share/man/man3 \
        -D pager="/usr/bin/less -isR" -D useshrplib -D usethreads
    make
    run_tests && TEST_JOBS=$(nproc) make test_harness || true
    make install
    unset BUILD_ZLIB BUILD_BZIP2
    ok "Perl установлен"
    cleanup "perl-5.44.0"
}

# ============================================================
# 8.47 - 8.49 Autoconf, Automake, OpenSSL
# ============================================================
pkg_autoconf() { simple_build "8.47 Autoconf-2.73" "autoconf-2.73.tar.xz" "autoconf-2.73" --prefix=/usr; }
pkg_automake() {
    section "8.48 Automake-1.18.1"
    extract "automake-1.18.1.tar.xz" "automake-1.18.1"
    ./configure --prefix=/usr --docdir=/usr/share/doc/automake-1.18.1
    make
    if run_tests; then
        make -j$(( $(nproc) > 4 ? $(nproc) : 4 )) check || warn "Automake check failed"
    fi
    make install
    ok "Automake установлен"
    cleanup "automake-1.18.1"
}
pkg_openssl() {
    section "8.49 OpenSSL-4.0.1"
    extract "openssl-4.0.1.tar.gz" "openssl-4.0.1"
    ./config --prefix=/usr --openssldir=/etc/ssl --libdir=lib shared zlib-dynamic
    make
    run_tests && make test || true
    make INSTALL_LIBS= MANSUFFIX=ssl install
    mv -v /usr/share/doc/openssl /usr/share/doc/openssl-4.0.1
    cp -vfr doc/* /usr/share/doc/openssl-4.0.1 2>/dev/null || true
    ok "OpenSSL установлен"
    cleanup "openssl-4.0.1"
}

# ============================================================
# 8.50 Libelf из Elfutils-0.195
# ============================================================
pkg_libelf() {
    section "8.50 Libelf из Elfutils-0.195"
    extract "elfutils-0.195.tar.bz2" "elfutils-0.195"
    ./configure --prefix=/usr \
                --disable-debuginfod \
                --enable-libdebuginfod=dummy
    make -C lib
    make -C libelf
    run_tests && make -k check || true
    make -C libelf install
    install -vm644 config/libelf.pc /usr/lib/pkgconfig
    rm /usr/lib/libelf.a
    ok "Libelf установлен"
    cleanup "elfutils-0.195"
}

# ============================================================
# 8.51 Libffi-3.8.0
# ============================================================
pkg_libffi() {
    section "8.51 Libffi-3.8.0"
    extract "libffi-3.8.0.tar.gz" "libffi-3.8.0"
    ./configure --prefix=/usr --disable-static --with-gcc-arch=native
    make
    run_tests && make check || true
    make install
    ok "Libffi установлен"
    cleanup "libffi-3.8.0"
}

# ============================================================
# 8.52 Sqlite-3530400
# ============================================================
pkg_sqlite() {
    section "8.52 Sqlite-3530400"
    extract "sqlite-autoconf-3530400.tar.gz" "sqlite-autoconf-3530400"
    python3 -m zipfile -e "$SOURCES/sqlite-doc-3530400.zip" .
    ./configure --prefix=/usr --disable-static --enable-fts{4,5} \
        CPPFLAGS="-D SQLITE_ENABLE_COLUMN_METADATA=1 \
                  -D SQLITE_ENABLE_UNLOCK_NOTIFY=1 \
                  -D SQLITE_ENABLE_DBSTAT_VTAB=1 \
                  -D SQLITE_SECURE_DELETE=1"
    make LDFLAGS.rpath=""
    make install
    cp -v -R sqlite-doc-3530400 -T /usr/share/doc/sqlite-3.53.4 2>/dev/null || true
    ok "Sqlite установлен"
    cleanup "sqlite-autoconf-3530400"
}

# ============================================================
# 8.53 mpdecimal-4.0.1
# ============================================================
pkg_mpdecimal() {
    section "8.53 mpdecimal-4.0.1"
    extract "mpdecimal-4.0.1.tar.gz" "mpdecimal-4.0.1"
    ./configure --prefix=/usr --disable-static --docdir=/usr/share/doc/mpdecimal-4.0.1
    make
    run_tests && make check_local || true
    make install
    ok "mpdecimal установлен"
    cleanup "mpdecimal-4.0.1"
}

# ============================================================
# 8.54 Python-3.14.7
# ============================================================
pkg_python() {
    section "8.54 Python-3.14.7"
    extract "Python-3.14.7.tar.xz" "Python-3.14.7"
    patch -Np1 -i ../Python-3.14.7-openssl_4-1.patch
    ./configure --prefix=/usr \
                --enable-shared \
                --with-system-expat \
                --enable-optimizations \
                --without-static-libpython
    make
    if run_tests; then
        make test TESTOPTS="--timeout 120" || warn "Python tests had failures"
    fi
    make install
    cat > /etc/pip.conf << EOF
[global]
root-user-action = ignore
disable-pip-version-check = true
EOF
    install -v -dm755 /usr/share/doc/python-3.14.7/html
    tar --strip-components=1 --no-same-owner --no-same-permissions \
        -C /usr/share/doc/python-3.14.7/html \
        -xvf "$SOURCES/python-3.14.7-docs-html.tar.bz2" 2>/dev/null || true
    ok "Python установлен"
    cleanup "Python-3.14.7"
}

# ============================================================
# Python-модули (8.55–8.59)
# ============================================================
pip_wheel_install() {
    # $1 = имя пакета для pip install
    pip3 wheel -w dist --no-cache-dir --no-build-isolation --no-deps "$PWD"
    pip3 install --no-index --find-links dist "$1"
}
pkg_flit_core () { section "8.55 Flit-Core-4.0.2"; extract "flit_core-4.0.2.tar.gz" "flit_core-4.0.2"; pip_wheel_install flit_core; ok "Flit-Core установлен"; cleanup "flit_core-4.0.2"; }
pkg_packaging () { section "8.56 Packaging-26.3"; extract "packaging-26.3.tar.gz" "packaging-26.3"; pip_wheel_install packaging; ok "Packaging установлен"; cleanup "packaging-26.3"; }
pkg_wheel     () { section "8.57 Wheel-0.48.0"; extract "wheel-0.48.0.tar.gz" "wheel-0.48.0"; pip_wheel_install wheel; ok "Wheel установлен"; cleanup "wheel-0.48.0"; }
pkg_setuptools() { section "8.58 Setuptools-84.0.0"; extract "setuptools-84.0.0.tar.gz" "setuptools-84.0.0"; pip_wheel_install setuptools; ok "Setuptools установлен"; cleanup "setuptools-84.0.0"; }
pkg_meson     () {
    section "8.59 Meson-1.12.0"
    extract "meson-1.12.0.tar.gz" "meson-1.12.0"
    pip_wheel_install meson
    install -vDm644 data/shell-completions/bash/meson /usr/share/bash-completion/completions/meson
    install -vDm644 data/shell-completions/zsh/_meson /usr/share/zsh/site-functions/_meson
    ok "Meson установлен"
    cleanup "meson-1.12.0"
}

# ============================================================
# 8.60 Kmod-34.2
# ============================================================
pkg_kmod() {
    section "8.60 Kmod-34.2"
    extract "kmod-34.2.tar.xz" "kmod-34.2"
    mkdir -p build && cd build
    meson setup --prefix=/usr .. --buildtype=release -D manpages=false
    ninja
    ninja install
    ok "Kmod установлен"
    cleanup "kmod-34.2"
}

# ============================================================
# 8.61 Coreutils-9.11
# ============================================================
pkg_coreutils() {
    section "8.61 Coreutils-9.11"
    extract "coreutils-9.11.tar.xz" "coreutils-9.11"
    patch -Np1 -i ../coreutils-9.11-i18n-1.patch
    autoreconf -fv
    automake -af
    FORCE_UNSAFE_CONFIGURE=1 ./configure --prefix=/usr
    make
    if run_tests; then
        make NON_ROOT_USERNAME=tester check-root || true
        groupadd -g 102 dummy -U tester || true
        chown -R tester .
        su tester -c "PATH=$PATH make -k RUN_EXPENSIVE_TESTS=yes check" < /dev/null || true
        groupdel dummy || true
    fi
    make install
    mv -v /usr/bin/chroot /usr/sbin
    mv -v /usr/share/man/man1/chroot.1 /usr/share/man/man8/chroot.8
    sed -i 's/"1"/"8"/' /usr/share/man/man8/chroot.8
    ok "Coreutils установлен"
    cleanup "coreutils-9.11"
}

# ============================================================
# 8.62 - 8.74 Diffutils ... Vim
# ============================================================
pkg_diffutils () { simple_build "8.62 Diffutils-3.12" "diffutils-3.12.tar.xz" "diffutils-3.12" --prefix=/usr; }
pkg_findutils () {
    section "8.63 Findutils-4.11.0"
    extract "findutils-4.11.0.tar.xz" "findutils-4.11.0"
    ./configure --prefix=/usr --localstatedir=/var/lib/locate
    make
    if run_tests; then
        chown -R tester .
        su tester -c "PATH=$PATH make check -k" || true
    fi
    make install
    ok "Findutils установлен"
    cleanup "findutils-4.11.0"
}
pkg_groff() {
    section "8.64 Groff-1.24.1"
    extract "groff-1.24.1.tar.gz" "groff-1.24.1"
    PAGE=A4 ./configure --prefix=/usr
    make -j1
    run_tests && make check || true
    make install
    ok "Groff установлен"
    cleanup "groff-1.24.1"
}
pkg_grub() {
    section "8.65 GRUB-2.14"
    extract "grub-2.14.tar.xz" "grub-2.14"
    unset CFLAGS CPPFLAGS CXXFLAGS LDFLAGS 2>/dev/null || true
    sed 's/--image-base/--nonexist-linker-option/' -i configure
    # BIOS
    ./configure --prefix=/usr --sysconfdir=/etc --disable-efiemu --disable-werror
    make
    make install
    # 64-bit UEFI
    make clean
    ./configure --prefix=/usr --sysconfdir=/etc --target=x86_64 --with-platform=efi \
                --disable-efiemu --disable-werror
    make
    make install
    ok "GRUB установлен (BIOS + UEFI x86_64)"
    cleanup "grub-2.14"
}
pkg_gzip() { simple_build "8.66 Gzip-1.14" "gzip-1.14.tar.xz" "gzip-1.14" --prefix=/usr; }
pkg_iproute2() {
    section "8.67 IPRoute2-7.1.0"
    extract "iproute2-7.1.0.tar.xz" "iproute2-7.1.0"
    sed -i /ARPD/d Makefile
    rm -fv man/man8/arpd.8
    make NETNS_RUN_DIR=/run/netns
    make SBINDIR=/usr/sbin install
    install -vDm644 COPYING README* -t /usr/share/doc/iproute2-7.1.0
    ok "IPRoute2 установлен"
    cleanup "iproute2-7.1.0"
}
pkg_kbd() {
    section "8.68 Kbd-2.10.0"
    extract "kbd-2.10.0.tar.xz" "kbd-2.10.0"
    patch -Np1 -i ../kbd-2.10.0-backspace-1.patch
    sed -i '/RESIZECONS_PROGS=/s/yes/no/' configure
    sed -i 's/resizecons.8 //' docs/man/man8/Makefile.in
    ./configure --prefix=/usr --disable-vlock
    make
    run_tests && make check || true
    make install
    cp -R -v docs/doc -T /usr/share/doc/kbd-2.10.0 2>/dev/null || true
    ok "Kbd установлен"
    cleanup "kbd-2.10.0"
}
pkg_libpipeline() { simple_build "8.69 Libpipeline-1.5.8" "libpipeline-1.5.8.tar.gz" "libpipeline-1.5.8" --prefix=/usr; }
pkg_make() {
    section "8.70 Make-4.4.1"
    extract "make-4.4.1.tar.gz" "make-4.4.1"
    ./configure --prefix=/usr
    make
    if run_tests; then
        chown -R tester .
        su tester -c "PATH=$PATH make check" || true
    fi
    make install
    ok "Make установлен"
    cleanup "make-4.4.1"
}
pkg_patch() { simple_build "8.71 Patch-2.8" "patch-2.8.tar.xz" "patch-2.8" --prefix=/usr; }
pkg_tar() {
    section "8.72 Tar-1.35"
    extract "tar-1.35.tar.xz" "tar-1.35"
    patch -Np1 -i ../tar-1.35-acl_fix-1.patch
    FORCE_UNSAFE_CONFIGURE=1 ./configure --prefix=/usr
    make
    run_tests && make check || true
    make install
    make -C doc install-html docdir=/usr/share/doc/tar-1.35
    ok "Tar установлен"
    cleanup "tar-1.35"
}
pkg_texinfo() {
    section "8.73 Texinfo-7.3"
    extract "texinfo-7.3.tar.xz" "texinfo-7.3"
    ./configure --prefix=/usr
    make
    run_tests && make check || true
    make install
    make TEXMF=/usr/share/texmf install-tex || true
    ok "Texinfo установлен"
    cleanup "texinfo-7.3"
}
pkg_vim() {
    section "8.74 Vim-9.2.1025"
    extract "vim-9.2.1025.tar.gz" "vim-9.2.1025"
    echo '#define SYS_VIMRC_FILE "/etc/vimrc"' >> src/feature.h
    ./configure --prefix=/usr
    make
    if run_tests; then
        chown -R tester .
        sed '/test_plugin_glvs/d' -i src/testdir/Make_all.mak
        su tester -c "TERM=xterm-256color LANG=en_US.UTF-8 make -j1 test" \
            &> "$LOG_DIR/vim-test.log" || warn "Vim tests failed"
    fi
    make install
    ln -sv vim /usr/bin/vi
    for L in /usr/share/man/{,*/}man1/vim.1; do ln -sv vim.1 "$(dirname $L)/vi.1"; done
    ln -sv ../vim/vim92/doc /usr/share/doc/vim-9.2.1025
    ok "Vim установлен"
    cleanup "vim-9.2.1025"
}

# ============================================================
# 8.75 - 8.77 Python-модули, Systemd
# ============================================================
pkg_markupsafe () { section "8.75 MarkupSafe-3.0.3"; extract "markupsafe-3.0.3.tar.gz" "markupsafe-3.0.3"; pip_wheel_install Markupsafe; ok "MarkupSafe установлен"; cleanup "markupsafe-3.0.3"; }
pkg_jinja2     () { section "8.76 Jinja2-3.1.6"; extract "jinja2-3.1.6.tar.gz" "jinja2-3.1.6"; pip_wheel_install Jinja2; ok "Jinja2 установлен"; cleanup "jinja2-3.1.6"; }
pkg_systemd() {
    section "8.77 Systemd-261.2"
    extract "systemd-261.2.tar.gz" "systemd-261.2"
    sed -e 's/GROUP="render"/GROUP="video"/' \
        -e 's/GROUP="sgx", //' \
        -i rules.d/50-udev-default.rules.in
    mkdir -p build && cd build
    meson setup .. \
        --prefix=/usr --buildtype=release \
        -D default-dnssec=no -D firstboot=false -D install-tests=false \
        -D ldconfig=false -D sysusers=false -D rpmmacrosdir=no \
        -D homed=disabled -D man=disabled -D mode=release -D pamconfdir=no \
        -D dev-kvm-mode=0660 -D nobody-group=nogroup \
        -D sysupdate=disabled -D ukify=disabled \
        -D docdir=/usr/share/doc/systemd-261.2
    ninja
    if run_tests; then
        echo 'NAME="Linux From Scratch"' > /etc/os-release
        unshare -m ninja test || warn "Systemd tests had failures"
    fi
    ninja install
    tar -xf "$SOURCES/systemd-man-pages-261.2.tar.xz" \
        --no-same-owner --strip-components=1 -C /usr/share/man
    systemd-machine-id-setup
    systemctl preset-all
    ok "Systemd установлен"
    cleanup "systemd-261.2"
}

# ============================================================
# 8.78 - 8.82 D-Bus ... E2fsprogs
# ============================================================
pkg_dbus() {
    section "8.78 D-Bus-1.16.2"
    extract "dbus-1.16.2.tar.xz" "dbus-1.16.2"
    mkdir build && cd build
    meson setup --prefix=/usr --buildtype=release --wrap-mode=nofallback ..
    ninja
    run_tests && ninja test || true
    ninja install
    ln -sfv /etc/machine-id /var/lib/dbus
    ok "D-Bus установлен"
    cleanup "dbus-1.16.2"
}
pkg_mandb() {
    section "8.79 Man-DB-2.13.1"
    extract "man-db-2.13.1.tar.xz" "man-db-2.13.1"
    ./configure --prefix=/usr \
                --docdir=/usr/share/doc/man-db-2.13.1 \
                --sysconfdir=/etc \
                --disable-setuid \
                --enable-cache-owner=bin \
                --with-browser=/usr/bin/lynx \
                --with-vgrind=/usr/bin/vgrind \
                --with-grap=/usr/bin/grap
    make
    run_tests && make check || true
    make install
    ok "Man-DB установлен"
    cleanup "man-db-2.13.1"
}
pkg_procps() {
    section "8.80 Procps-ng-4.0.7"
    extract "procps-ng-4.0.7.tar.xz" "procps-ng-4.0.7"
    ./configure --prefix=/usr \
                --docdir=/usr/share/doc/procps-ng-4.0.7 \
                --disable-static --disable-kill \
                --enable-watch8bit --with-systemd
    make
    if run_tests; then
        chown -R tester .
        su tester -c "PATH=$PATH make check" || true
    fi
    make install
    ok "Procps-ng установлен"
    cleanup "procps-ng-4.0.7"
}
pkg_util_linux() {
    section "8.81 Util-linux-2.42.2"
    extract "util-linux-2.42.2.tar.xz" "util-linux-2.42.2"
    ./configure --bindir=/usr/bin --libdir=/usr/lib --runstatedir=/run \
                --sbindir=/usr/sbin \
                --disable-chfn-chsh --disable-login --disable-nologin \
                --disable-su --disable-setpriv --disable-runuser \
                --disable-pylibmount --disable-liblastlog2 --disable-static \
                --without-python \
                ADJTIME_PATH=/var/lib/hwclock/adjtime \
                --docdir=/usr/share/doc/util-linux-2.42.2
    make
    if run_tests; then
        touch /etc/fstab
        chown -R tester .
        su tester -c "make -k check" || true
    fi
    make install
    ok "Util-linux установлен"
    cleanup "util-linux-2.42.2"
}
pkg_e2fsprogs() {
    section "8.82 E2fsprogs-1.47.4"
    extract "e2fsprogs-1.47.4.tar.gz" "e2fsprogs-1.47.4"
    mkdir -v build && cd build
    ../configure --prefix=/usr --sysconfdir=/etc \
                 --enable-elf-shlibs \
                 --disable-libblkid --disable-libuuid \
                 --disable-uuidd --disable-fsck
    make
    run_tests && make check || true
    make install
    rm -fv /usr/lib/{libcom_err,libe2p,libext2fs,libss}.a
    gunzip -v /usr/share/info/libext2fs.info.gz
    install-info --dir-file=/usr/share/info/dir /usr/share/info/libext2fs.info
    ok "E2fsprogs установлен"
    cleanup "e2fsprogs-1.47.4"
}

# ============================================================
# 8.83-8.85 Stripping, Cleanup
# ============================================================
do_stripping() {
    section "8.84 Stripping (опционально)"
    read -rp "Выполнять stripping? Это уменьшит размер системы на ~2 ГБ [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { warn "Stripping пропущен"; return; }

    save_usrlib="$(cd /usr/lib; ls ld-linux*[^g] 2>/dev/null)
             libc.so.6
             libthread_db.so.1
             libquadmath.so.0.0.0
             libstdc++.so.6.0.36
             libitm.so.1.0.0
             libatomic.so.1.2.0"

    cd /usr/lib
    for LIB in $save_usrlib; do
        [ -f "$LIB" ] || continue
        objcopy --only-keep-debug --compress-debug-sections=zstd "$LIB" "$LIB.dbg"
        cp "$LIB" "/tmp/$LIB"
        strip --strip-unneeded "/tmp/$LIB"
        objcopy --add-gnu-debuglink="$LIB.dbg" "/tmp/$LIB"
        install -vm755 "/tmp/$LIB" /usr/lib
        rm "/tmp/$LIB"
    done

    online_usrbin="bash find strip"
    online_usrlib="libbfd-2.47.20260726.so
                   libsframe.so.3.0.0
                   libhistory.so.8.3
                   libncursesw.so.6.6
                   libm.so.6
                   libreadline.so.8.3
                   libz.so.1.3.2
                   libzstd.so.1.5.7
                   $(cd /usr/lib; find libnss*.so* -type f 2>/dev/null)"

    for BIN in $online_usrbin; do
        cp "/usr/bin/$BIN" "/tmp/$BIN"
        strip --strip-unneeded "/tmp/$BIN"
        install -vm755 "/tmp/$BIN" /usr/bin
        rm "/tmp/$BIN"
    done
    for LIB in $online_usrlib; do
        cp "/usr/lib/$LIB" "/tmp/$LIB"
        strip --strip-unneeded "/tmp/$LIB"
        install -vm755 "/tmp/$LIB" /usr/lib
        rm "/tmp/$LIB"
    done
    ok "Stripping выполнен"
}
do_cleanup() {
    section "8.85 Cleaning Up"
    rm -rf /tmp/{*,.*} 2>/dev/null || true
    find /usr/lib /usr/libexec -name \*.la -delete
    find /usr -depth -name "$(uname -m)-lfs-linux-gnu"* | xargs rm -rf
    userdel -r tester 2>/dev/null || true
    ok "Очистка завершена"
}

# ============================================================
main() {
    echo "###### LFS Глава 8 — Начало: $(date) ######"
    echo "RUN_TESTS=$RUN_TESTS (1=вкл, 0=выкл)"
    check_prereq

    # Порядок соответствует книге
    pkg_man_pages
    pkg_iana_etc
    pkg_glibc
    pkg_zlib
    pkg_bzip2
    pkg_xz
    pkg_lz4
    pkg_zstd
    pkg_file
    pkg_readline
    pkg_pcre2
    pkg_m4
    pkg_bc
    pkg_flex
    pkg_tcl
    pkg_expect
    pkg_dejagnu
    pkg_ninja
    pkg_pkgconf
    pkg_binutils
    pkg_gmp
    pkg_mpfr
    pkg_mpc
    pkg_attr
    pkg_acl
    pkg_libcap
    pkg_libxcrypt
    pkg_shadow
    pkg_gawk
    pkg_gcc
    pkg_ncurses
    pkg_sed
    pkg_psmisc
    pkg_gettext
    pkg_bison
    pkg_grep
    pkg_bash
    pkg_libtool
    pkg_gdbm
    pkg_gperf
    pkg_expat
    pkg_inetutils
    pkg_less
    pkg_perl
    pkg_autoconf
    pkg_automake
    pkg_openssl
    pkg_libelf
    pkg_libffi
    pkg_sqlite
    pkg_mpdecimal
    pkg_python
    pkg_flit_core
    pkg_packaging
    pkg_wheel
    pkg_setuptools
    pkg_meson
    pkg_kmod
    pkg_coreutils
    pkg_diffutils
    pkg_findutils
    pkg_groff
    pkg_grub
    pkg_gzip
    pkg_iproute2
    pkg_kbd
    pkg_libpipeline
    pkg_make
    pkg_patch
    pkg_tar
    pkg_texinfo
    pkg_vim
    pkg_markupsafe
    pkg_jinja2
    pkg_systemd
    pkg_dbus
    pkg_mandb
    pkg_procps
    pkg_util_linux
    pkg_e2fsprogs

    do_stripping
    do_cleanup

    section "Глава 8 завершена"
    ok "Все пакеты установлены. Логи: $LOG_DIR/"
    echo "Не забудьте: passwd root — установить пароль root"
}
main "$@" 2>&1 | tee "$LOG_DIR/chapter8-$TS.log"
exit "${PIPESTATUS[0]}"