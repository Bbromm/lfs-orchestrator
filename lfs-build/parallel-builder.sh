#!/bin/bash
###############################################################################
# parallel-builder.sh — Параллельная сборка независимых пакетов
# ЗАПУСКАЕТСЯ ВНУТРИ CHROOT от root
#
# Использование:
#   bash /parallel-builder.sh              # max 4 параллельных сборки
#   MAX_PARALLEL=2 bash /parallel-builder.sh
###############################################################################
set -euo pipefail

SOURCES="/sources"
LOG_DIR="$SOURCES/logs/parallel"
mkdir -p "$LOG_DIR"
MAX_PARALLEL="${MAX_PARALLEL:-4}"
RUN_TESTS="${RUN_TESTS:-0}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; MAGENTA='\033[0;35m'; NC='\033[0m'

log()  { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

#------------------------------------------------------------------------------
# Реестр пакетов: имя | функция | зависимости
#------------------------------------------------------------------------------
declare -A PKG_FUNC
declare -A PKG_DEPS

register() {
    local name="$1" func="$2" deps="$3"
    PKG_FUNC["$name"]="$func"
    PKG_DEPS["$name"]="$deps"
}

# -----------------------------------------------------------------------------
# Пакеты, которые можно собирать параллельно (без взаимных зависимостей)
# Порядок и группировка — согласно главе 8
# -----------------------------------------------------------------------------

# Группа 1: независимые утилиты сжатия
register zlib       build_zlib       ""
register bzip2      build_bzip2      ""
register xz         build_xz         ""
register lz4        build_lz4        ""
register zstd       build_zstd       ""

# Группа 2: низкоуровневые утилиты
register file       build_file       ""
register m4         build_m4         ""
register bc         build_bc         ""
register flex       build_flex       ""
register psmisc     build_psmisc     ""
register less       build_less       ""
register gperf      build_gperf      ""
register expat      build_expat      ""

# Группа 3: GMP/MPFR/MPC независимы друг от друга
register gmp        build_gmp        ""
register mpfr       build_mpfr       "gmp"    # MPFR зависит от GMP
register mpc        build_mpc        "gmp mpfr"

# Группа 4: независимые системные библиотеки
register attr       build_attr       ""
register acl        build_acl        "attr"
register libcap     build_libcap     "attr"
register libffi     build_libffi     ""
register sqlite     build_sqlite     ""

# Группа 5: утилиты времени компиляции
register readline   build_readline   ""
register pcre2      build_pcre2      ""
register gdbm       build_gdbm       ""

# Группа 6: инструменты разработки (зависят от многих выше)
register gawk       build_gawk       "mpfr"
register bison      build_bison      "m4"
register grep       build_grep       "pcre2"
register diffutils  build_diffutils  ""
register findutils  build_findutils  ""
register make       build_make       ""
register patch      build_patch      "attr"
register sed        build_sed        "acl attr"
register tar        build_tar        "acl attr"

# Группа 7: Python-стек (строгая последовательность)
register mpdecimal  build_mpdecimal  ""
register python     build_python     "mpdecimal expat libffi sqlite zlib"
register flit_core  build_flit_core  "python"
register packaging  build_packaging  "python flit_core"
register wheel      build_wheel      "python flit_core packaging"
register setuptools build_setuptools "python wheel"
register meson      build_meson      "python setuptools wheel"
register markupsafe build_markupsafe "python setuptools wheel"
register jinja2     build_jinja2     "python markupsafe"

# Группа 8: высокоуровневые (после всех выше)
register kmod       build_kmod       "zstd openssl"
register systemd    build_systemd    "kmod jinja2 meson openssl pcre2 util_linux"
register dbus       build_dbus       "systemd util_linux"

#------------------------------------------------------------------------------
# Реализации сборщиков (упрощённые; детали — в install-chapter8.sh)
#------------------------------------------------------------------------------
simple_build() {
    local name="$1" tarball="$2" dirname="$3"; shift 3
    cd "$SOURCES"
    rm -rf "$dirname"
    tar -xf "$tarball" || { warn "[$name] extract failed"; return 1; }
    cd "$dirname" || return 1

    if [[ $# -gt 0 ]]; then
        ./configure "$@" > "$LOG_DIR/$name-configure.log" 2>&1 || { warn "[$name] configure failed"; return 1; }
    fi
    make > "$LOG_DIR/$name-make.log" 2>&1 || { warn "[$name] make failed"; return 1; }
    if [[ "$RUN_TESTS" == "1" ]]; then
        make check >> "$LOG_DIR/$name-make.log" 2>&1 || warn "[$name] check failed (ignored)"
    fi
    make install > "$LOG_DIR/$name-install.log" 2>&1 || { warn "[$name] install failed"; return 1; }

    cd "$SOURCES"
    rm -rf "$dirname"
    ok "[$name] установлен"
    return 0
}

build_zlib       () { simple_build zlib      zlib-1.3.2.tar.gz       zlib-1.3.2 --prefix=/usr && rm -fv /usr/lib/libz.a; }
build_bzip2      () {
    cd "$SOURCES"; rm -rf bzip2-1.0.8; tar -xf bzip2-1.0.8.tar.gz; cd bzip2-1.0.8
    patch -Np1 -i ../bzip2-1.0.8-install_docs-1.patch >/dev/null
    sed -i 's@\(ln -s -f \)$(PREFIX)/bin/@\1@' Makefile
    sed -i "s@(PREFIX)/man@(PREFIX)/share/man@g" Makefile
    make -f Makefile-libbz2_so >/dev/null 2>&1; make clean >/dev/null
    make >/dev/null 2>&1; make PREFIX=/usr install >/dev/null 2>&1
    cp -av libbz2.so.* /usr/lib >/dev/null
    ln -sfv libbz2.so.1.0.8 /usr/lib/libbz2.so
    ln -sfv libbz2.so.1.0.8 /usr/lib/libbz2.so.1
    cp -v bzip2-shared /usr/bin/bzip2 >/dev/null
    ln -sfv bzip2 /usr/bin/bzcat; ln -sfv bzip2 /usr/bin/bunzip2
    rm -fv /usr/lib/libbz2.a
    cd "$SOURCES"; rm -rf bzip2-1.0.8; ok "[bzip2] установлен"
}
build_xz         () { simple_build xz        xz-5.8.3.tar.xz          xz-5.8.3         --prefix=/usr --disable-static --docdir=/usr/share/doc/xz-5.8.3; }
build_lz4        () {
    cd "$SOURCES"; rm -rf lz4-1.10.0; tar -xf lz4-1.10.0.tar.gz; cd lz4-1.10.0
    make BUILD_STATIC=no PREFIX=/usr >/dev/null 2>&1
    make BUILD_STATIC=no PREFIX=/usr install >/dev/null 2>&1
    cd "$SOURCES"; rm -rf lz4-1.10.0; ok "[lz4] установлен"
}
build_zstd       () {
    cd "$SOURCES"; rm -rf zstd-1.5.7; tar -xf zstd-1.5.7.tar.gz; cd zstd-1.5.7
    make prefix=/usr >/dev/null 2>&1
    make prefix=/usr install >/dev/null 2>&1
    rm -fv /usr/lib/libzstd.a
    cd "$SOURCES"; rm -rf zstd-1.5.7; ok "[zstd] установлен"
}
build_file       () { simple_build file      file-5.48.tar.gz         file-5.48        --prefix=/usr; }
build_m4         () { simple_build m4        m4-1.4.21.tar.xz         m4-1.4.21        --prefix=/usr; }
build_bc         () {
    cd "$SOURCES"; rm -rf bc-7.0.3; tar -xf bc-7.0.3.tar.xz; cd bc-7.0.3
    CC='gcc -std=c99' ./configure --prefix=/usr -G -O3 -r >/dev/null
    make >/dev/null 2>&1; make install >/dev/null 2>&1
    cd "$SOURCES"; rm -rf bc-7.0.3; ok "[bc] установлен"
}
build_flex       () {
    simple_build flex flex-2.6.4.tar.gz flex-2.6.4 --prefix=/usr --disable-static --docdir=/usr/share/doc/flex-2.6.4 || return 1
    ln -sv flex /usr/bin/lex 2>/dev/null; ln -sv flex.1 /usr/share/man/man1/lex.1 2>/dev/null
}
build_psmisc     () { simple_build psmisc    psmisc-23.7.tar.xz       psmisc-23.7      --prefix=/usr; }
build_less       () { simple_build less      less-704.tar.gz          less-704         --prefix=/usr --sysconfdir=/etc; }
build_gperf      () { simple_build gperf     gperf-3.3.tar.gz         gperf-3.3        --prefix=/usr --docdir=/usr/share/doc/gperf-3.3; }
build_expat      () { simple_build expat     expat-2.8.3.tar.xz       expat-2.8.3      --prefix=/usr --disable-static --docdir=/usr/share/doc/expat-2.8.3; }

build_gmp        () {
    cd "$SOURCES"; rm -rf gmp-6.3.0; tar -xf gmp-6.3.0.tar.xz; cd gmp-6.3.0
    sed -i '/long long t1;/,+1s/()/(...)/' configure
    ./configure --prefix=/usr --enable-cxx --disable-static --docdir=/usr/share/doc/gmp-6.3.0 >/dev/null
    make >/dev/null 2>&1; make html >/dev/null 2>&1; make install >/dev/null 2>&1; make install-html >/dev/null 2>&1
    cd "$SOURCES"; rm -rf gmp-6.3.0; ok "[gmp] установлен"
}
build_mpfr       () { simple_build mpfr      mpfr-4.2.2.tar.xz        mpfr-4.2.2       --prefix=/usr --disable-static --enable-thread-safe --docdir=/usr/share/doc/mpfr-4.2.2; }
build_mpc        () { simple_build mpc       mpc-1.4.1.tar.xz         mpc-1.4.1        --prefix=/usr --disable-static --docdir=/usr/share/doc/mpc-1.4.1; }
build_attr       () { simple_build attr      attr-2.6.0.tar.gz        attr-2.6.0       --prefix=/usr --disable-static --sysconfdir=/etc --docdir=/usr/share/doc/attr-2.6.0; }
build_acl        () { simple_build acl       acl-2.4.0.tar.xz         acl-2.4.0        --prefix=/usr --disable-static --docdir=/usr/share/doc/acl-2.4.0; }
build_libcap     () {
    cd "$SOURCES"; rm -rf libcap-2.78; tar -xf libcap-2.78.tar.xz; cd libcap-2.78
    sed -i '/install -m.*STA/d' libcap/Makefile
    make prefix=/usr lib=lib >/dev/null 2>&1
    make prefix=/usr lib=lib install >/dev/null 2>&1
    cd "$SOURCES"; rm -rf libcap-2.78; ok "[libcap] установлен"
}
build_libffi     () { simple_build libffi    libffi-3.8.0.tar.gz      libffi-3.8.0     --prefix=/usr --disable-static --with-gcc-arch=native; }
build_sqlite     () {
    cd "$SOURCES"; rm -rf sqlite-autoconf-3530400; tar -xf sqlite-autoconf-3530400.tar.gz; cd sqlite-autoconf-3530400
    python3 -m zipfile -e "$SOURCES/sqlite-doc-3530400.zip" . 2>/dev/null || true
    ./configure --prefix=/usr --disable-static --enable-fts{4,5} \
        CPPFLAGS="-D SQLITE_ENABLE_COLUMN_METADATA=1 -D SQLITE_ENABLE_UNLOCK_NOTIFY=1 -D SQLITE_ENABLE_DBSTAT_VTAB=1 -D SQLITE_SECURE_DELETE=1" >/dev/null
    make LDFLAGS.rpath="" >/dev/null 2>&1; make install >/dev/null 2>&1
    cd "$SOURCES"; rm -rf sqlite-autoconf-3530400; ok "[sqlite] установлен"
}
build_readline   () {
    cd "$SOURCES"; rm -rf readline-8.3; tar -xf readline-8.3.tar.gz; cd readline-8.3
    sed -i '/MV.*old/d' Makefile.in
    sed -i '/{OLDSUFF}/c:' support/shlib-install
    sed -i 's/-Wl,-rpath,[^ ]*//' support/shobj-conf
    sed -e '270a\     else\
       chars_avail = 1;' -e '288i\   result = -1;' -i.orig input.c
    ./configure --prefix=/usr --disable-static --with-curses --docdir=/usr/share/doc/readline-8.3 >/dev/null
    make SHLIB_LIBS="-lncursesw" >/dev/null 2>&1; make install >/dev/null 2>&1
    cd "$SOURCES"; rm -rf readline-8.3; ok "[readline] установлен"
}
build_pcre2      () {
    cd "$SOURCES"; rm -rf pcre2-10.47; tar -xf pcre2-10.47.tar.bz2; cd pcre2-10.47
    ./configure --prefix=/usr --docdir=/usr/share/doc/pcre2-10.47 \
        --enable-unicode --enable-jit --enable-pcre2-16 --enable-pcre2-32 \
        --enable-pcre2grep-libz --enable-pcre2grep-libbz2 \
        --enable-pcre2test-libreadline --disable-static >/dev/null
    make >/dev/null 2>&1; make install >/dev/null 2>&1
    cd "$SOURCES"; rm -rf pcre2-10.47; ok "[pcre2] установлен"
}
build_gdbm       () { simple_build gdbm      gdbm-1.26.tar.gz         gdbm-1.26        --prefix=/usr --disable-static --enable-libgdbm-compat; }
build_gawk       () { simple_build gawk      gawk-5.4.1.tar.xz        gawk-5.4.1       --prefix=/usr; }
build_bison      () { simple_build bison     bison-3.8.2.tar.xz       bison-3.8.2      --prefix=/usr --docdir=/usr/share/doc/bison-3.8.2; }
build_grep       () {
    cd "$SOURCES"; rm -rf grep-3.12; tar -xf grep-3.12.tar.xz; cd grep-3.12
    sed -i "s/echo/#echo/" src/egrep.sh
    ./configure --prefix=/usr >/dev/null
    make >/dev/null 2>&1; make install >/dev/null 2>&1
    cd "$SOURCES"; rm -rf grep-3.12; ok "[grep] установлен"
}
build_diffutils  () { simple_build diffutils diffutils-3.12.tar.xz   diffutils-3.12   --prefix=/usr; }
build_findutils  () { simple_build findutils findutils-4.11.0.tar.xz findutils-4.11.0 --prefix=/usr --localstatedir=/var/lib/locate; }
build_make       () { simple_build make      make-4.4.1.tar.gz        make-4.4.1       --prefix=/usr; }
build_patch      () { simple_build patch     patch-2.8.tar.xz         patch-2.8        --prefix=/usr; }
build_sed        () { simple_build sed       sed-4.10.tar.xz          sed-4.10         --prefix=/usr; }
build_tar        () {
    cd "$SOURCES"; rm -rf tar-1.35; tar -xf tar-1.35.tar.xz; cd tar-1.35
    patch -Np1 -i ../tar-1.35-acl_fix-1.patch >/dev/null
    FORCE_UNSAFE_CONFIGURE=1 ./configure --prefix=/usr >/dev/null
    make >/dev/null 2>&1; make install >/dev/null 2>&1
    make -C doc install-html docdir=/usr/share/doc/tar-1.35 >/dev/null 2>&1 || true
    cd "$SOURCES"; rm -rf tar-1.35; ok "[tar] установлен"
}
build_mpdecimal  () { simple_build mpdecimal mpdecimal-4.0.1.tar.gz   mpdecimal-4.0.1  --prefix=/usr --disable-static --docdir=/usr/share/doc/mpdecimal-4.0.1; }
build_python     () {
    cd "$SOURCES"; rm -rf Python-3.14.7; tar -xf Python-3.14.7.tar.xz; cd Python-3.14.7
    patch -Np1 -i ../Python-3.14.7-openssl_4-1.patch >/dev/null
    ./configure --prefix=/usr --enable-shared --with-system-expat \
                --enable-optimizations --without-static-libpython >/dev/null
    make >/dev/null 2>&1; make install >/dev/null 2>&1
    cat > /etc/pip.conf << 'EOF'
[global]
root-user-action = ignore
disable-pip-version-check = true
EOF
    cd "$SOURCES"; rm -rf Python-3.14.7; ok "[python] установлен"
}
pip_pkg() {
    local name="$1" pkg="$2" tarball="$3" dirname="$4"
    cd "$SOURCES"; rm -rf "$dirname"; tar -xf "$tarball"; cd "$dirname"
    pip3 wheel -w dist --no-cache-dir --no-build-isolation --no-deps "$PWD" >/dev/null 2>&1
    pip3 install --no-index --find-links dist "$pkg" >/dev/null 2>&1
    cd "$SOURCES"; rm -rf "$dirname"; ok "[$name] установлен"
}
build_flit_core  () { pip_pkg flit_core  flit_core  flit_core-4.0.2.tar.gz  flit_core-4.0.2; }
build_packaging  () { pip_pkg packaging  packaging  packaging-26.3.tar.gz  packaging-26.3; }
build_wheel      () { pip_pkg wheel      wheel      wheel-0.48.0.tar.gz    wheel-0.48.0; }
build_setuptools () { pip_pkg setuptools setuptools setuptools-84.0.0.tar.gz setuptools-84.0.0; }
build_meson      () {
    pip_pkg meson meson meson-1.12.0.tar.gz meson-1.12.0
    cd "$SOURCES"; rm -rf meson-1.12.0; tar -xf meson-1.12.0.tar.gz; cd meson-1.12.0
    install -vDm644 data/shell-completions/bash/meson /usr/share/bash-completion/completions/meson 2>/dev/null || true
    install -vDm644 data/shell-completions/zsh/_meson /usr/share/zsh/site-functions/_meson 2>/dev/null || true
    cd "$SOURCES"; rm -rf meson-1.12.0
}
build_markupsafe () { pip_pkg markupsafe Markupsafe markupsafe-3.0.3.tar.gz markupsafe-3.0.3; }
build_jinja2     () { pip_pkg jinja2     Jinja2     jinja2-3.1.6.tar.gz    jinja2-3.1.6; }
build_kmod       () {
    cd "$SOURCES"; rm -rf kmod-34.2; tar -xf kmod-34.2.tar.xz; cd kmod-34.2
    mkdir -p build; cd build
    meson setup --prefix=/usr .. --buildtype=release -D manpages=false >/dev/null
    ninja >/dev/null 2>&1; ninja install >/dev/null 2>&1
    cd "$SOURCES"; rm -rf kmod-34.2; ok "[kmod] установлен"
}
build_systemd    () { warn "[systemd] требует ручной сборки (используйте install-chapter8.sh)"; return 0; }
build_dbus       () { warn "[dbus] требует ручной сборки"; return 0; }

#------------------------------------------------------------------------------
# Планировщик с учётом зависимостей
#------------------------------------------------------------------------------
declare -A PKG_STATE     # not_started | running | done | failed
declare -A PKG_PID

for name in "${!PKG_FUNC[@]}"; do PKG_STATE["$name"]="not_started"; done

deps_ok() {
    local name="$1"
    local deps="${PKG_DEPS[$name]}"
    for d in $deps; do
        [[ "${PKG_STATE[$d]:-}" == "done" ]] || return 1
    done
    return 0
}

any_running() {
    for n in "${!PKG_STATE[@]}"; do
        [[ "${PKG_STATE[$n]}" == "running" ]] && return 0
    done
    return 1
}

total_pkgs=${#PKG_FUNC[@]}
done_pkgs=0
failed_pkgs=0
declare -a failed_list

log "Планировщик: $total_pkgs пакетов, макс. параллельно: $MAX_PARALLEL"

while (( done_pkgs + failed_pkgs < total_pkgs )); do
    # Запуск новых задач
    for name in "${!PKG_FUNC[@]}"; do
        [[ "${PKG_STATE[$name]}" == "not_started" ]] || continue
        deps_ok "$name" || continue

        # Лимит параллелизма
        running=$(jobs -rp | wc -l)
        (( running >= MAX_PARALLEL )) && break

        PKG_STATE["$name"]="running"
        log "▶ Запуск: $name (зависимости: ${PKG_DEPS[$name]:-нет})"

        (
            if "${PKG_FUNC[$name]}"; then
                echo "DONE:$name"
            else
                echo "FAIL:$name"
            fi
        ) &
        PKG_PID["$name"]=$!
    done

    # Проверка завершившихся
    wait -n 2>/dev/null || true

    for name in "${!PKG_STATE[@]}"; do
        [[ "${PKG_STATE[$name]}" == "running" ]] || continue
        if ! kill -0 "${PKG_PID[$name]}" 2>/dev/null; then
            if wait "${PKG_PID[$name]}" 2>/dev/null; then
                PKG_STATE["$name"]="done"
                (( done_pkgs++ ))
                ok "✔ Завершено: $name"
            else
                PKG_STATE["$name"]="failed"
                (( failed_pkgs++ ))
                failed_list+=("$name")
                warn "✘ Провал: $name"
            fi
        fi
    done
done

#------------------------------------------------------------------------------
# Итог
#------------------------------------------------------------------------------
echo
log "═══════════════════════════════════════════════════════════"
log "Итог параллельной сборки:"
log "  Успешно: $done_pkgs / $total_pkgs"
log "  Провалов: $failed_pkgs"
[[ $failed_pkgs -gt 0 ]] && { warn "Провалившиеся пакеты:"; printf '    - %s\n' "${failed_list[@]}"; }
log "═══════════════════════════════════════════════════════════"

[[ $failed_pkgs -eq 0 ]] || exit 1