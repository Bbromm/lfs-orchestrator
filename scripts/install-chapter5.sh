#!/bin/bash
###############################################################################
# LFS 13.1-systemd — Глава 5: Компиляция кросс-инструментария
#
# Назначение: автоматизация шагов 5.2 – 5.6 книги LFS
#             (Binutils pass1, GCC pass1, Linux API Headers, Glibc, Libstdc++)
#
# Требования:
#   - Скрипт запускается от имени пользователя 'lfs'
#   - Переменная $LFS установлена (например, /mnt/lfs)
#   - Переменная $LFS_TGT установлена (например, x86_64-lfs-linux-gnu)
#   - Все исходные tarball'ы находятся в $LFS/sources
#   - Окружение настроено согласно разделу 4.4 книги
#
# Использование:
#   su - lfs
#   bash install-chapter5.sh 2>&1 | tee chapter5.log
###############################################################################

# Строгий режим: выход при ошибке, при неинициализированной переменной,
# при ошибке в конвейере
# Коды возврата конвейеров важны: `make ... | tee log` без pipefail
# возвращает код tee, и провал сборки выглядел как успех.
set -o pipefail
CURRENT_STAGE=""
cleanup_on_signal() {
    echo "[$(date)] Получен SIGTERM, прерываю стадию '$CURRENT_STAGE'..."
    # Убить дочерние процессы (make, gcc, patch, tar)
    pkill -TERM -P $$ 2>/dev/null || true
    sleep 2
    pkill -KILL -P $$ 2>/dev/null || true
    exit 143
}
trap cleanup_on_signal SIGTERM SIGINT

# и в main() перед каждой стадией:
# CURRENT_STAGE=glibc
# should_run glibc && build_glibc

#-----------------------------------------------------------------------------
# Константы и переменные
#-----------------------------------------------------------------------------
LFS="${LFS:-/mnt/lfs}"
LFS_TGT="${LFS_TGT:-$(uname -m)-lfs-linux-gnu}"
SOURCES="$LFS/sources"
LOG_DIR="$LFS/sources/logs"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
MAIN_LOG="$LOG_DIR/chapter5-$TIMESTAMP.log"

# Каталог логов нужен до запуска main: основной лог открывается через tee,
# и при отсутствии каталога tee молча теряет весь вывод.
mkdir -p "$LOG_DIR" 2>/dev/null || true

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

#-----------------------------------------------------------------------------
# Вспомогательные функции
#-----------------------------------------------------------------------------
log() {
    echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"
}

ok() {
    echo -e "${GREEN}[OK]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

die() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
    exit 2
}

#-----------------------------------------------------------------------------
# Разбор аргументов командной строки
#-----------------------------------------------------------------------------
ONLY=""
ASSUME_YES="${ASSUME_YES:-0}"
[[ -t 0 ]] || ASSUME_YES=1     # нет TTY (оркестратор/docker без -it) → не спрашивать

while [[ $# -gt 0 ]]; do
    case "$1" in
        --only)   ONLY="${2:-}"; [[ -n "$ONLY" ]] || die "--only требует имя стадии"; shift 2 ;;
        --yes|-y) ASSUME_YES=1; shift ;;
        -h|--help)
            cat <<EOF
Использование: $0 [--only <stage>] [--yes]

Стадии: binutils-pass1 | gcc-pass1 | linux-headers | glibc | libstdcpp
EOF
            exit 0 ;;
        *) die "Неизвестный аргумент: $1" ;;
    esac
done

should_run() {
    [[ -z "$ONLY" || "$ONLY" == "$1" ]]
}



# Извлечение tarball'а и переход в каталог сборки
extract() {
    local tarball="$1"
    local dirname="$2"

    log "Извлечение $tarball..."
    cd "$SOURCES"
    rm -rf "$dirname"
    tar -xf "$tarball" || die "Не удалось извлечь $tarball"
    cd "$dirname" || die "Каталог $dirname не найден после извлечения"
    ok "Извлечено в $SOURCES/$dirname"
}

# Удаление каталога сборки после успешной установки
cleanup() {
    local dirname="$1"
    cd "$SOURCES"
    rm -rf "$dirname"
    ok "Очищен каталог $dirname"
}

# Печать разделителя секции
section() {
    echo ""
    echo "==================================================================="
    echo "  $*"
    echo "==================================================================="
    echo ""
}

#-----------------------------------------------------------------------------
# Проверка предусловий
#-----------------------------------------------------------------------------
check_prerequisites() {
    section "Проверка предусловий"

    [[ "$(whoami)" == "lfs" ]] || die "Скрипт должен запускаться от имени пользователя 'lfs'"
    ok "Пользователь: lfs"

    [[ -n "${LFS:-}" ]] || die "Переменная \$LFS не установлена"
    ok "\$LFS = $LFS"

    [[ -n "${LFS_TGT:-}" ]] || die "Переменная \$LFS_TGT не установлена"
    ok "\$LFS_TGT = $LFS_TGT"

    [[ -d "$LFS/tools" ]] || die "Каталог $LFS/tools не существует. Выполните раздел 4.2"
    ok "Каталог $LFS/tools существует"

    [[ -d "$SOURCES" ]] || die "Каталог $SOURCES не существует"
    ok "Каталог $SOURCES существует"

    mkdir -p "$LOG_DIR"
    ok "Каталог логов: $LOG_DIR"

    # Проверка обязательных tarball'ов
    local required=(
        "binutils-2.47.tar.xz"
        "gcc-16.2.0.tar.xz"
        "gmp-6.3.0.tar.xz"
        "mpfr-4.2.2.tar.xz"
        "mpc-1.4.1.tar.xz"
        "linux-7.1.8.tar.xz"
        "glibc-2.44.tar.xz"
        "glibc-fhs-1.patch"
        "glibc-2.44-upstream_fixes-1.patch"
    )
    local missing=()
    for f in "${required[@]}"; do
        [[ -f "$SOURCES/$f" ]] || missing+=("$f")
    done
    if (( ${#missing[@]} > 0 )); then
        printf "Отсутствуют файлы:\n"
        printf '  - %s\n' "${missing[@]}"
        die "Загрузите отсутствующие файлы в $SOURCES"
    fi
    ok "Все необходимые tarball'ы и патчи найдены"

    # Проверка, что предыдущие версии инструментов не конфликтуют
    if [[ "$ASSUME_YES" == "1" ]]; then
        warn "ASSUME_YES=1 — продолжаем без подтверждения"
    else
        read -rp 'Продолжить? [y/N] ' ans
        [[ "$ans" =~ ^[yY]$ ]] || die "Отменено пользователем"
    fi
}

#-----------------------------------------------------------------------------
# 5.2 Binutils-2.47 — Pass 1
#-----------------------------------------------------------------------------
build_binutils_pass1() {
    section "5.2 Binutils-2.47 — Pass 1"

    extract "binutils-2.47.tar.xz" "binutils-2.47"

    mkdir -v build && cd build

    log "configure..."
    ../configure --prefix="$LFS/tools" \
                 --with-sysroot="$LFS" \
                 --target="$LFS_TGT" \
                 --disable-nls \
                 --enable-gprofng=no \
                 --disable-werror \
                 --enable-new-dtags \
                 --enable-default-hash-style=gnu \
        2>&1 | tee "$LOG_DIR/binutils-pass1-configure.log" || die "ошибка, лог: $LOG_DIR/binutils-pass1-configure.log"

    log "make..."
    make 2>&1 | tee "$LOG_DIR/binutils-pass1-make.log" || die "ошибка, лог: $LOG_DIR/binutils-pass1-make.log"

    log "make install..."
    make install 2>&1 | tee "$LOG_DIR/binutils-pass1-install.log" || die "ошибка, лог: $LOG_DIR/binutils-pass1-install.log"

    ok "Binutils pass 1 установлен"

    cd "$SOURCES"
    cleanup "binutils-2.47"
}

#-----------------------------------------------------------------------------
# 5.3 GCC-16.2.0 — Pass 1
#-----------------------------------------------------------------------------
build_gcc_pass1() {
    section "5.3 GCC-16.2.0 — Pass 1"

    extract "gcc-16.2.0.tar.xz" "gcc-16.2.0"

    # Распаковка GMP, MPFR, MPC внутрь дерева GCC
    log "Распаковка GMP/MPFR/MPC внутрь GCC..."
    tar -xf ../mpfr-4.2.2.tar.xz
    mv -v mpfr-4.2.2 mpfr
    tar -xf ../gmp-6.3.0.tar.xz
    mv -v gmp-6.3.0 gmp
    tar -xf ../mpc-1.4.1.tar.xz
    mv -v mpc-1.4.1 mpc
    ok "GMP/MPFR/MPC на месте"

    # На x86_64 — использовать 'lib' вместо 'lib64'
    if [[ "$(uname -m)" == "x86_64" ]]; then
        log "Патч gcc/config/i386/t-linux64 (lib64 → lib)..."
        sed -e '/m64=/s/lib64/lib/' -i.orig gcc/config/i386/t-linux64
        ok "Патч применён"
    fi

    mkdir -v build && cd build

    log "configure..."
    ../configure --target="$LFS_TGT" \
                 --prefix="$LFS/tools" \
                 --with-glibc-version=2.44 \
                 --with-sysroot="$LFS" \
                 --with-newlib \
                 --without-headers \
                 --enable-default-pie \
                 --enable-default-ssp \
                 --disable-fixincludes \
                 --disable-nls \
                 --disable-shared \
                 --disable-multilib \
                 --disable-threads \
                 --disable-libatomic \
                 --disable-libgomp \
                 --disable-libquadmath \
                 --disable-libssp \
                 --disable-libvtv \
                 --disable-libstdcxx \
                 --enable-languages=c,c++ \
        2>&1 | tee "$LOG_DIR/gcc-pass1-configure.log" || die "ошибка, лог: $LOG_DIR/gcc-pass1-configure.log"

    log "make (это может занять несколько минут)..."
    make 2>&1 | tee "$LOG_DIR/gcc-pass1-make.log" || die "ошибка, лог: $LOG_DIR/gcc-pass1-make.log"

    log "make install..."
    make install 2>&1 | tee "$LOG_DIR/gcc-pass1-install.log" || die "ошибка, лог: $LOG_DIR/gcc-pass1-install.log"

    # Создание полного internal limits.h
    log "Создание полного limits.h..."
    local incdir
    incdir="$("$LFS_TGT-gcc" -print-file-name=include 2>/dev/null)"
    if [[ -z "$incdir" || ! -d "$incdir" ]]; then
        die "кросс-gcc не установлен: не удалось получить каталог include"
    fi
    cat ../gcc/limitx.h ../gcc/glimits.h ../gcc/limity.h > "$incdir/limits.h" \
        || die "не удалось записать $incdir/limits.h"
    ok "limits.h создан: $incdir/limits.h"

    ok "GCC pass 1 установлен"

    cd "$SOURCES"
    cleanup "gcc-16.2.0"
}

#-----------------------------------------------------------------------------
# 5.4 Linux-7.1.8 API Headers
#-----------------------------------------------------------------------------
build_linux_headers() {
    section "5.4 Заголовки API Linux-7.1.8"

    extract "linux-7.1.8.tar.xz" "linux-7.1.8"

    log "make mrproper..."
    make mrproper 2>&1 | tee "$LOG_DIR/linux-headers-mrproper.log" || die "ошибка, лог: $LOG_DIR/linux-headers-mrproper.log"

    log "make headers..."
    make headers 2>&1 | tee "$LOG_DIR/linux-headers-make.log" || die "ошибка, лог: $LOG_DIR/linux-headers-make.log"

    log "Удаление не-заголовочных файлов..."
    find usr/include -type f ! -name '*.h' -delete

    log "Копирование в $LFS/usr..."
    cp -rv usr/include "$LFS/usr" 2>&1 | tee "$LOG_DIR/linux-headers-copy.log" || die "ошибка, лог: $LOG_DIR/linux-headers-copy.log"

    ok "Заголовки API Linux установлены"

    cd "$SOURCES"
    cleanup "linux-7.1.8"
}

#-----------------------------------------------------------------------------
# 5.5 Glibc-2.44
#-----------------------------------------------------------------------------
build_glibc() {
    section "5.5 Glibc-2.44"

    extract "glibc-2.44.tar.xz" "glibc-2.44"

    # Символьные ссылки LSB / ld-linux
    log "Создание символьных ссылок динамического загрузчика..."
    case "$(uname -m)" in
        i?86)
            ln -sfv ld-linux.so.2 "$LFS/lib/ld-lsb.so.3"
            ;;
        x86_64)
            ln -sfv ../lib/ld-linux-x86-64.so.2 "$LFS/lib64"
            ln -sfv ../lib/ld-linux-x86-64.so.2 "$LFS/lib64/ld-lsb-x86-64.so.3"
            ;;
    esac
    ok "Символьные ссылки созданы"

    # Патчи
    log "Применение glibc-fhs-1.patch..."
    patch -Np1 -i ../glibc-fhs-1.patch 2>&1 | tee "$LOG_DIR/glibc-fhs-patch.log" || die "ошибка, лог: $LOG_DIR/glibc-fhs-patch.log"

    log "Применение glibc-2.44-upstream_fixes-1.patch..."
    patch -Np1 -i ../glibc-2.44-upstream_fixes-1.patch 2>&1 | tee "$LOG_DIR/glibc-upstream-patch.log" || die "ошибка, лог: $LOG_DIR/glibc-upstream-patch.log"

    mkdir -v build && cd build

    log "Создание configparms..."
    echo "rootsbindir=/usr/sbin" > configparms

    log "configure..."
    ../configure --prefix=/usr \
                 --host="$LFS_TGT" \
                 --build="$(../scripts/config.guess)" \
                 --disable-nscd \
                 libc_cv_slibdir=/usr/lib \
                 --enable-kernel=5.10 \
        2>&1 | tee "$LOG_DIR/glibc-configure.log" || die "ошибка, лог: $LOG_DIR/glibc-configure.log"

    log "make (это может занять несколько минут)..."
    make 2>&1 | tee "$LOG_DIR/glibc-make.log" || die "ошибка, лог: $LOG_DIR/glibc-make.log"

    log "make DESTDIR=$LFS install..."
    make DESTDIR="$LFS" install 2>&1 | tee "$LOG_DIR/glibc-install.log" || die "ошибка, лог: $LOG_DIR/glibc-install.log"

    log "Патч ldd (RTLDLIST)..."
    sed '/RTLDLIST=/s@/usr@@g' -i "$LFS/usr/bin/ldd"

    # Sanity checks (5.5.1)
    sanity_check_toolchain

    ok "Glibc установлена"

    cd "$SOURCES"
    cleanup "glibc-2.44"
}

#-----------------------------------------------------------------------------
# Sanity-check кросс-инструментария (раздел 5.5.1 книги)
#-----------------------------------------------------------------------------
sanity_check_toolchain() {
    section "Sanity-check кросс-инструментария"

    cd "$SOURCES"

    log "Компиляция dummy-программы..."
    echo 'int main(){}' | "$LFS_TGT-gcc" -x c - -v -Wl,--verbose \
        &> dummy.log || die "Компиляция dummy не удалась"

    # 1. Проверка интерпретатора
    log "1. Проверка пути интерпретатора..."
    if "$LFS_TGT-readelf" -l a.out | grep -q ": /lib"; then
        ok "Интерпретатор найден (путь без /mnt/lfs)"
    else
        die "Интерпретатор не найден или содержит \$LFS"
    fi

    # 2. Проверка start files
    log "2. Проверка start files..."
    if grep -E -q "$LFS/lib.*/S?crt[1in].*succeeded" dummy.log; then
        ok "crt*.o найдены в \$LFS"
    else
        die "crt*.o не найдены"
    fi

    # 3. Проверка заголовков
    log "3. Проверка пути заголовков..."
    if grep -q "$LFS/usr/include" dummy.log; then
        ok "Заголовки ищутся в \$LFS/usr/include"
    else
        die "Заголовки не ищутся в \$LFS/usr/include"
    fi

    # 4. Проверка search paths компоновщика
    log "4. Проверка search paths компоновщика..."
    if grep -q 'SEARCH.*/usr/lib' dummy.log; then
        ok "SEARCH_DIR содержит /usr/lib"
    else
        warn "SEARCH_DIR не содержит /usr/lib (проверьте вручную)"
    fi

    # 5. Проверка libc
    log "5. Проверка libc..."
    if grep -q "/lib.*/libc.so.6 " dummy.log; then
        ok "libc.so.6 найдена в \$LFS"
    else
        die "libc.so.6 не найдена"
    fi

    # 6. Проверка динамического компоновщика
    log "6. Проверка динамического компоновщика..."
    if grep -q "found ld-linux" dummy.log; then
        ok "Динамический компоновщик найден"
    else
        die "Динамический компоновщик не найден"
    fi

    # Очистка
    rm -v a.out dummy.log
    ok "Sanity-check пройден успешно"
}

#-----------------------------------------------------------------------------
# 5.6 Libstdc++ из GCC-16.2.0
#-----------------------------------------------------------------------------
build_libstdcpp() {
    section "5.6 Libstdc++ из GCC-16.2.0"

    # Нужно снова распаковать GCC (pass1 его удалил)
    extract "gcc-16.2.0.tar.xz" "gcc-16.2.0"

    mkdir -v build && cd build

    log "configure Libstdc++..."
    ../libstdc++-v3/configure --host="$LFS_TGT" \
                              --build="$(../config.guess)" \
                              CXX="$LFS_TGT-gcc" \
                              --prefix=/usr \
                              --disable-multilib \
                              --disable-nls \
                              --disable-libstdcxx-pch \
                              --with-gxx-include-dir="/tools/$LFS_TGT/include/c++/16.2.0" \
        2>&1 | tee "$LOG_DIR/libstdcpp-configure.log" || die "ошибка, лог: $LOG_DIR/libstdcpp-configure.log"

    log "make..."
    make 2>&1 | tee "$LOG_DIR/libstdcpp-make.log" || die "ошибка, лог: $LOG_DIR/libstdcpp-make.log"

    log "make DESTDIR=$LFS install..."
    make DESTDIR="$LFS" install 2>&1 | tee "$LOG_DIR/libstdcpp-install.log" || die "ошибка, лог: $LOG_DIR/libstdcpp-install.log"

    log "Удаление .la файлов libtool..."
    rm -v "$LFS"/usr/lib/lib{stdc++{,exp,fs},supc++}.la

    ok "Libstdc++ установлена"

    cd "$SOURCES"
    cleanup "gcc-16.2.0"
}

#-----------------------------------------------------------------------------
# Итоговая проверка
#-----------------------------------------------------------------------------
final_summary() {
    section "Итоговая проверка Главы 5"

    echo "Установленные инструменты в $LFS/tools/bin:"
    ls -1 "$LFS/tools/bin" 2>/dev/null | head -20 || true
    echo "..."

    echo ""
    echo "Установленные инструменты в $LFS/tools/$LFS_TGT/bin:"
    ls -1 "$LFS/tools/$LFS_TGT/bin" 2>/dev/null | head -20 || true
    echo "..."

    echo ""
    echo "Версии ключевых инструментов:"
    "$LFS_TGT-gcc" --version | head -1  || true
    "$LFS_TGT-ld"  --version | head -1  || true
    "$LFS_TGT-as"  --version | head -1  || true

    echo ""
    echo "Заголовки Glibc:"
    ls -1 "$LFS/usr/include/stdio.h" 2>/dev/null && ok "stdio.h на месте" || warn "stdio.h отсутствует"

    echo ""
    echo "Библиотеки Glibc:"
    ls -1 "$LFS/usr/lib/libc.so.6" 2>/dev/null && ok "libc.so.6 на месте" || warn "libc.so.6 отсутствует"

    echo ""
    ok "Глава 5 завершена. Все логи: $LOG_DIR/"
}

#-----------------------------------------------------------------------------
# Главная функция
#-----------------------------------------------------------------------------
main() {
    echo ""
    echo "#################################################################"
    echo "#  LFS 13.1-systemd — Глава 5: Кросс-инструментарий              #"
    echo "#  Начало: $(date)                        #"
    echo "#################################################################"
    echo ""

    if [[ -n "$ONLY" ]]; then
        case "$ONLY" in
            binutils-pass1|gcc-pass1|linux-headers|glibc|libstdcpp) ;;
            *) die "Стадия '$ONLY' не существует. Допустимые: binutils-pass1, gcc-pass1, linux-headers, glibc, libstdcpp" ;;
        esac
        echo ">>> Режим --only: будет выполнена только стадия '$ONLY'"
    fi

    check_prerequisites

    should_run binutils-pass1 && build_binutils_pass1
    should_run gcc-pass1      && build_gcc_pass1
    should_run linux-headers  && build_linux_headers
    should_run glibc          && build_glibc
    should_run libstdcpp      && build_libstdcpp


    if [[ -z "$ONLY" ]]; then
        final_summary
    fi

    echo ""
    echo "#################################################################"
    echo "#  Завершено: $(date)                     #"
    echo "#  Основной лог: $MAIN_LOG"
    echo "#################################################################"
    echo ""
}

# Запуск с логированием всего вывода
main "$@" 2>&1 | tee "$MAIN_LOG"
exit "${PIPESTATUS[0]}"
