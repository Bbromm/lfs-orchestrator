#!/bin/bash
###############################################################################
# validate-host.sh — Полная проверка хост-системы перед сборкой LFS
# Запуск: sudo bash validate-host.sh
###############################################################################
set -uo pipefail

PASS=0; WARN=0; FAIL=0
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'

pass() { echo -e "  ${GREEN}✔${NC} $*"; ((PASS++)); }
warn() { echo -e "  ${YELLOW}⚠${NC} $*"; ((WARN++)); }
fail() { echo -e "  ${RED}✘${NC} $*"; ((FAIL++)); }
header() { echo; echo -e "${BLUE}▶ $*${NC}"; }

# -----------------------------------------------------------------------------
header "1. Аппаратное обеспечение"
# -----------------------------------------------------------------------------
CPU_CORES=$(nproc 2>/dev/null || echo 0)
RAM_GB=$(( $(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024 / 1024 ))

(( CPU_CORES >= 4 )) && pass "CPU-ядер: $CPU_CORES (≥4)" || warn "CPU-ядер: $CPU_CORES (<4 — будет медленно)"
(( RAM_GB >= 8 ))    && pass "RAM: ${RAM_GB} ГБ (≥8)"     || warn "RAM: ${RAM_GB} ГБ (<8 — может не хватить)"

FREE_DISK=$(df -BG /mnt 2>/dev/null | awk 'NR==2{print $4}' | tr -d G)
[[ -n "$FREE_DISK" ]] && {
    (( FREE_DISK >= 30 )) && pass "Свободно на /mnt: ${FREE_DISK} ГБ (≥30)" \
                          || warn "Свободно на /mnt: ${FREE_DISK} ГБ (<30 — может не хватить)"
}

# -----------------------------------------------------------------------------
header "2. Хост-ядро и платформа"
# -----------------------------------------------------------------------------
KVER=$(uname -r)
KMAJOR=$(echo "$KVER" | cut -d. -f1)
KMINOR=$(echo "$KVER" | cut -d. -f2)
if (( KMAJOR > 5 )) || { (( KMAJOR == 5 )) && (( KMINOR >= 10 )); }; then
    pass "Ядро $KVER (≥5.10)"
else
    fail "Ядро $KVER (<5.10 — не поддерживается)"
fi

mount | grep -q 'devpts on /dev/pts' && pass "devpts смонтирован" || fail "devpts НЕ смонтирован"
[[ -e /dev/ptmx ]] && pass "/dev/ptmx существует" || fail "/dev/ptmx отсутствует"

# -----------------------------------------------------------------------------
header "3. Критические инструменты (минимальные версии LFS)"
# -----------------------------------------------------------------------------
check_ver() {
    local name="$1" cmd="$2" min="$3"
    if ! command -v "$cmd" >/dev/null; then
        fail "$name ($cmd) не найден"
        return
    fi
    local ver
    ver=$("$cmd" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
    if [[ -z "$ver" ]]; then
        warn "$name: не удалось определить версию"
        return
    fi
    if printf '%s\n%s\n' "$min" "$ver" | sort -V | head -1 | grep -q "^${min}$"; then
        pass "$name: $ver (≥$min)"
    else
        fail "$name: $ver (< $min)"
    fi
}

check_ver "Bash"      bash     "3.2"
check_ver "Binutils"  ld       "2.13.1"
check_ver "Bison"     bison    "2.7"
check_ver "Coreutils" sort     "8.1"
check_ver "Diffutils" diff     "2.8.1"
check_ver "Findutils" find     "4.2.31"
check_ver "Gawk"      gawk     "4.0.1"
check_ver "GCC"       gcc      "5.4"
check_ver "G++"       g++      "5.4"
check_ver "Grep"      grep     "2.5.1a"
check_ver "Gzip"      gzip     "1.3.12"
check_ver "M4"        m4       "1.4.10"
check_ver "Make"      make     "4.0"
check_ver "Patch"     patch    "2.5.4"
check_ver "Perl"      perl     "5.8.8"
check_ver "Python3"   python3  "3.4"
check_ver "Sed"       sed      "4.1.5"
check_ver "Tar"       tar      "1.22"
check_ver "Texinfo"   texi2any "5.0"
check_ver "Xz"        xz       "5.0.0"

# -----------------------------------------------------------------------------
header "4. Символьные ссылки"
# -----------------------------------------------------------------------------
check_link() {
    local path="$1" target="$2"
    if [[ -L "$path" ]]; then
        local link=$(readlink -f "$path")
        [[ "$link" == *"$target"* ]] && pass "$path → $target" || fail "$path → $link (ожидалось $target)"
    else
        fail "$path не является символьной ссылкой"
    fi
}
check_link "/bin/sh" "/bin/bash"
check_link "/usr/bin/awk" "gawk" 2>/dev/null || [[ -L /usr/bin/awk ]] && pass "/usr/bin/awk → gawk" || warn "/usr/bin/awk не ссылка"
[[ -L /usr/bin/yacc ]] && pass "/usr/bin/yacc → bison" || warn "/usr/bin/yacc не ссылка (опционально)"

# -----------------------------------------------------------------------------
header "5. Компилятор и сборка"
# -----------------------------------------------------------------------------
if echo 'int main(){}' | g++ -x c++ - -o /tmp/lfs-test 2>/dev/null; then
    pass "g++ компилирует код C++"
    rm -f /tmp/lfs-test
else
    fail "g++ НЕ компилирует (проверьте пакеты -dev)"
fi

# -----------------------------------------------------------------------------
header "6. Обязательные утилиты"
# -----------------------------------------------------------------------------
for cmd in tar wget xz bzip2 gzip patch make sed grep awk find; do
    command -v "$cmd" >/dev/null && pass "$cmd найден" || fail "$cmd НЕ найден"
done

# -----------------------------------------------------------------------------
header "7. Проверка целевого диска"
# -----------------------------------------------------------------------------
source "$(dirname "$0")/lfs-config.sh" 2>/dev/null || true
if [[ -n "${DISK:-}" ]]; then
    if [[ -b "$DISK" ]]; then
        pass "Диск $DISK существует"
        # Проверка занятости
        if lsblk "$DISK" -o NAME,MOUNTPOINT -n | grep -q '/'; then
            warn "На $DISK есть смонтированные разделы — AUTO_PARTITION уничтожит их!"
        fi
    else
        fail "Диск $DISK не найден"
    fi
fi

# -----------------------------------------------------------------------------
header "8. Права и пользователь"
# -----------------------------------------------------------------------------
[[ "$(id -u)" == "0" ]] && pass "Запуск от root" || fail "Не root (нужно sudo)"
getent passwd lfs >/dev/null && warn "Пользователь lfs уже существует" || pass "Пользователь lfs будет создан"
getent group lfs >/dev/null  && warn "Группа lfs уже существует"   || pass "Группа lfs будет создана"

# -----------------------------------------------------------------------------
header "9. Сеть"
# -----------------------------------------------------------------------------
if ping -c1 -W2 8.8.8.8 >/dev/null 2>&1; then
    pass "Интернет доступен (ICMP)"
elif curl -s --max-time 3 https://www.linuxfromscratch.org >/dev/null 2>&1; then
    pass "Интернет доступен (HTTPS)"
else
    warn "Интернет недоступен — загрузка пакетов не удастся"
fi

# -----------------------------------------------------------------------------
header "10. Свободное место и inodes"
# -----------------------------------------------------------------------------
for mnt in / /mnt /tmp; do
    [[ -d "$mnt" ]] || continue
    size=$(df -BG "$mnt" | awk 'NR==2{print $4}' | tr -d G)
    inodes=$(df -i "$mnt" | awk 'NR==2{print $4}')
    if (( size >= 1 )); then
        pass "$mnt: ${size} ГБ свободно, ${inodes} inodes"
    else
        fail "$mnt: только ${size} ГБ свободно"
    fi
done

# -----------------------------------------------------------------------------
# Итог
# -----------------------------------------------------------------------------
echo
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "  ПРОЙДЕНО: ${GREEN}${PASS}${NC}"
echo -e "  ПРЕДУПРЕЖДЕНИЙ: ${YELLOW}${WARN}${NC}"
echo -e "  ОШИБОК: ${RED}${FAIL}${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"

if (( FAIL > 0 )); then
    echo -e "${RED}❌ Сборку начинать НЕЛЬЗЯ — устраните ошибки${NC}"
    exit 1
elif (( WARN > 0 )); then
    echo -e "${YELLOW}⚠  Можно продолжать, но будьте осторожны${NC}"
    exit 0
else
    echo -e "${GREEN}✅ Всё готово к сборке!${NC}"
    exit 0
fi