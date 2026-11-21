#!/bin/bash
###############################################################################
# configure-system.sh — LFS 13.1-systemd, Глава 9: Конфигурация системы
# ЗАПУСКАЕТСЯ ВНУТРИ CHROOT от root (сразу после главы 8).
#
# Использование:
#   bash /configure-system.sh
#
# Параметры — через переменные окружения:
#   HOSTNAME, TIMEZONE, LOCALE, KEYMAP, CONSOLE_FONT,
#   USE_DHCP, STATIC_IP, GATEWAY, DNS_PRIMARY, DNS_SECONDARY,
#   LFS_VERSION, NET_IFACE
###############################################################################
set -euo pipefail

#------------------------------------------------------------------------------
# Параметры (значения по умолчанию — под вашу систему)
#------------------------------------------------------------------------------
HOSTNAME="${HOSTNAME:-mylfs}"
TIMEZONE="${TIMEZONE:-Asia/Yekaterinburg}"
LOCALE="${LOCALE:-en_US.UTF-8}"
KEYMAP="${KEYMAP:-ru}"
CONSOLE_FONT="${CONSOLE_FONT:-Lat2-Terminus16}"
USE_DHCP="${USE_DHCP:-yes}"
STATIC_IP="${STATIC_IP:-192.168.1.100}"
GATEWAY="${GATEWAY:-192.168.1.1}"
DNS_PRIMARY="${DNS_PRIMARY:-8.8.8.8}"
DNS_SECONDARY="${DNS_SECONDARY:-8.8.4.4}"
LFS_VERSION="${LFS_VERSION:-13.1-systemd}"
NET_IFACE="${NET_IFACE:-}"
PREFIX="${PREFIX:-24}"

#------------------------------------------------------------------------------
# Вспомогательные функции
#------------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; MAGENTA='\033[0;35m'; NC='\033[0m'

log()  { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
section() { echo; echo -e "${MAGENTA}────────────────────────────────────────────────────────────${NC}";
            echo -e "${MAGENTA}  $*${NC}";
            echo -e "${MAGENTA}────────────────────────────────────────────────────────────${NC}"; }

# Идемпотентные помощники
safe_ln() { ln -sfv -- "$@"; }

#------------------------------------------------------------------------------
check_prereq() {
    [[ "$(id -u)" == "0" ]] || die "Скрипт должен запускаться от root внутри chroot"
    [[ -f /etc/passwd      ]] || die "Не в chroot — нет /etc/passwd"
    [[ -d /usr/lib/systemd ]] || die "systemd не установлен — проверьте главу 8"
    if [[ -f /etc/lfs-release ]]; then
        ok "Система LFS $(cat /etc/lfs-release)"
    else
        warn "/etc/lfs-release отсутствует (обычно создаётся в Главе 11)"
    fi
}

#------------------------------------------------------------------------------
# 9.2.1 Network Interface Configuration
#------------------------------------------------------------------------------
configure_network() {
    section "9.2.1 Настройка сети (systemd-networkd)"

    mkdir -pv /etc/systemd/network

    # ФИКС #4: безопасное автоопределение интерфейса
    if [[ -z "$NET_IFACE" ]]; then
        local found=""
        if [[ -d /sys/class/net ]]; then
            shopt -s nullglob
            for iface in /sys/class/net/*; do
                local name
                name="$(basename "$iface")"
                [[ "$name" == "lo" ]] && continue
                found="$name"
                break
            done
            shopt -u nullglob
        fi
        NET_IFACE="${found:-enp0s3}"
        if [[ -n "$found" ]]; then
            log "Автоопределение интерфейса: $NET_IFACE"
        else
            warn "Интерфейс не найден в /sys/class/net — использую enp0s3"
            warn "Переопределите: NET_IFACE=eth0 bash $0"
        fi
    fi
    ok "Сетевой интерфейс: $NET_IFACE"

    # Чистим возможные старые конфиги с другим именем интерфейса
    rm -fv /etc/systemd/network/10-eth-*.network 2>/dev/null || true

    if [[ "$USE_DHCP" == "yes" ]]; then
        log "Настройка DHCP для $NET_IFACE"
        cat > /etc/systemd/network/10-eth-dhcp.network << EOF
[Match]
Name=$NET_IFACE

[Network]
DHCP=ipv4

[DHCPv4]
UseDomains=true
EOF
        ok "Создан /etc/systemd/network/10-eth-dhcp.network (DHCP)"
    else
        log "Настройка статического IP для $NET_IFACE"
        cat > /etc/systemd/network/10-eth-static.network << EOF
[Match]
Name=$NET_IFACE

[Network]
Address=$STATIC_IP/$PREFIX
Gateway=$GATEWAY
DNS=$DNS_PRIMARY
DNS=$DNS_SECONDARY
Domains=$HOSTNAME.local
EOF
        ok "Создан /etc/systemd/network/10-eth-static.network (статический)"
    fi
}

#------------------------------------------------------------------------------
# 9.2.2 /etc/resolv.conf
#------------------------------------------------------------------------------
configure_resolv_conf() {
    section "9.2.2 Создание /etc/resolv.conf"

    if [[ "$USE_DHCP" == "yes" ]]; then
        # ФИКС #2: при DHCP используем systemd-resolved как источник DNS.
        # stub-resolv.conf будет создан самим resolved при первой загрузке.
        log "DHCP: /etc/resolv.conf → /run/systemd/resolve/stub-resolv.conf"
        log "(systemd-resolved будет включён ниже, в configure_systemd)"
        # Убираем возможный обычный файл перед симлинком
        [[ -f /etc/resolv.conf && ! -L /etc/resolv.conf ]] && rm -fv /etc/resolv.conf
        safe_ln /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
        ok "/etc/resolv.conf → stub-resolv.conf"
    else
        cat > /etc/resolv.conf << EOF
# Begin /etc/resolv.conf

domain $HOSTNAME.local
nameserver $DNS_PRIMARY
nameserver $DNS_SECONDARY

# End /etc/resolv.conf
EOF
        ok "/etc/resolv.conf создан (статический)"
    fi
}

#------------------------------------------------------------------------------
# 9.2.3 /etc/hostname
#------------------------------------------------------------------------------
configure_hostname() {
    section "9.2.3 Настройка hostname"
    echo "$HOSTNAME" > /etc/hostname
    ok "/etc/hostname: $HOSTNAME"
}

#------------------------------------------------------------------------------
# 9.2.4 /etc/hosts
#------------------------------------------------------------------------------
configure_hosts() {
    section "9.2.4 Настройка /etc/hosts"
    cat > /etc/hosts << EOF
# Begin /etc/hosts

127.0.0.1    localhost.localdomain localhost
127.0.1.1    $HOSTNAME.local $HOSTNAME
::1          ip6-localhost ip6-loopback
ff02::1      ip6-allnodes
ff02::2      ip6-allrouters

# End /etc/hosts
EOF
    ok "/etc/hosts создан"
}

#------------------------------------------------------------------------------
# 9.3 Проверка systemd-udevd
#------------------------------------------------------------------------------
check_udev() {
    section "9.3 Проверка systemd-udevd"
    if [[ -x /usr/lib/systemd/systemd-udevd ]]; then
        ok "systemd-udevd найден"
    else
        die "systemd-udevd отсутствует — проверьте установку systemd"
    fi
    [[ -f /usr/lib/udev/rules.d/50-udev-default.rules ]] && \
        ok "udev default rules на месте" || \
        warn "udev default rules отсутствуют"
}

#------------------------------------------------------------------------------
# 9.4 Правила udev (шаблон)
#------------------------------------------------------------------------------
configure_udev_rules() {
    section "9.4 Управление устройствами (опционально)"
    if [[ ! -f /etc/udev/rules.d/83-duplicate_devs.rules ]]; then
        cat > /etc/udev/rules.d/83-duplicate_devs.rules << 'EOF'
# Persistent symlinks for webcam and tuner
# Отредактируйте под свои устройства (udevadm info -a -p /sys/class/...)
# KERNEL=="video*", ATTRS{idProduct}=="1910", ATTRS{idVendor}=="0d81", SYMLINK+="webcam"
# KERNEL=="video*", ATTRS{device}=="0x036f", ATTRS{vendor}=="0x109e", SYMLINK+="tvtuner"
EOF
        ok "Создан шаблон /etc/udev/rules.d/83-duplicate_devs.rules"
    else
        ok "Правила udev уже существуют (пропуск)"
    fi
}

#------------------------------------------------------------------------------
# 9.5 Системные часы
#------------------------------------------------------------------------------
configure_clock() {
    section "9.5 Настройка системных часов"

    # В chroot hwclock не работает (нет доступа к RTC), поэтому
    # просто фиксируем UTC — рекомендованный LFS-режим.
    if [[ ! -f /etc/adjtime ]]; then
        cat > /etc/adjtime << 'EOF'
0.0 0 0.0
0
UTC
EOF
        ok "/etc/adjtime создан (UTC)"
    else
        ok "/etc/adjtime уже существует"
    fi

    # Часовой пояс
    if [[ -f "/usr/share/zoneinfo/$TIMEZONE" ]]; then
        safe_ln "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
        ok "Часовой пояс: $TIMEZONE"
    else
        warn "Часовой пояс '$TIMEZONE' не найден в /usr/share/zoneinfo"
        warn "Первые доступные зоны:"
        find /usr/share/zoneinfo -maxdepth 1 -type d 2>/dev/null | head -10 | sed 's/^/    /'
        if [[ -f /usr/share/zoneinfo/UTC ]]; then
            safe_ln /usr/share/zoneinfo/UTC /etc/localtime
            warn "Использован UTC как fallback"
        fi
    fi
}

#------------------------------------------------------------------------------
# 9.6 Linux Console
#------------------------------------------------------------------------------
configure_console() {
    section "9.6 Настройка консоли Linux"
    cat > /etc/vconsole.conf << EOF
# Begin /etc/vconsole.conf
KEYMAP=$KEYMAP
FONT=$CONSOLE_FONT
# End /etc/vconsole.conf
EOF
    ok "/etc/vconsole.conf создан (KEYMAP=$KEYMAP, FONT=$CONSOLE_FONT)"

    # Проверка шрифта
    local f
    for f in "/usr/share/consolefonts/${CONSOLE_FONT}.psfu.gz" \
             "/usr/share/consolefonts/${CONSOLE_FONT}.psf.gz" \
             "/usr/share/consolefonts/${CONSOLE_FONT}"; do
        [[ -f "$f" ]] && { ok "Шрифт консоли найден: $f"; return; }
    done
    warn "Шрифт консоли '$CONSOLE_FONT' не найден в /usr/share/consolefonts"
    warn "Доступные шрифты (первые 10):"
    ls /usr/share/consolefonts/ 2>/dev/null | head -10 | sed 's/^/    /' || true

    # Проверка keymap
    if [[ ! -f "/usr/share/kbd/keymaps/i386/qwerty/${KEYMAP}.map.gz" ]] && \
       [[ ! -f "/usr/share/kbd/keymaps/i386/qwertz/${KEYMAP}.map.gz" ]] && \
       ! find /usr/share/kbd/keymaps -name "${KEYMAP}.map.gz" 2>/dev/null | grep -q .; then
        warn "Раскладка '$KEYMAP' не найдена в /usr/share/kbd/keymaps"
    fi
}

#------------------------------------------------------------------------------
# 9.7 System Locale
#------------------------------------------------------------------------------
configure_locale() {
    section "9.7 Настройка локали системы"

    cat > /etc/locale.conf << EOF
LANG=$LOCALE
EOF
    ok "/etc/locale.conf создан (LANG=$LOCALE)"

    # Проверка наличия локали
    if LC_ALL="$LOCALE" locale charmap >/dev/null 2>&1; then
        ok "Локаль '$LOCALE' доступна"
    else
        warn "Локаль '$LOCALE' не установлена"
        warn "Сгенерируйте её в главе 8 (glibc): localedef -i ${LOCALE%.*} -f ${LOCALE##*.} $LOCALE"
        warn "Доступные локали:"
        locale -a 2>/dev/null | head -20 | sed 's/^/    /' || true
    fi

    # /etc/profile
    cat > /etc/profile << 'EOF'
# Begin /etc/profile

# Очищаем унаследованные LC_*/LANG
for i in $(locale); do
    unset ${i%=*}
done

if [[ "$TERM" = linux ]]; then
    # Linux console: не все локали имеют глифы
    export LANG=C.UTF-8
else
    if [[ -f /etc/locale.conf ]]; then
        source /etc/locale.conf
    fi
    for i in $(locale); do
        key="${i%=*}"
        if [[ -v "$key" ]]; then
            export "$key"
        fi
    done
fi

# End /etc/profile
EOF
    ok "/etc/profile создан"
}

#------------------------------------------------------------------------------
# 9.8 /etc/inputrc
#------------------------------------------------------------------------------
configure_inputrc() {
    section "9.8 Создание /etc/inputrc"
    cat > /etc/inputrc << 'EOF'
# Begin /etc/inputrc
set horizontal-scroll-mode Off
set meta-flag On
set input-meta On
set convert-meta Off
set output-meta On
set bell-style none

"\eOd": backward-word
"\eOc": forward-word

# linux console
"\e[1~": beginning-of-line
"\e[4~": end-of-line
"\e[5~": beginning-of-history
"\e[6~": end-of-history
"\e[3~": delete-char
"\e[2~": quoted-insert

# xterm
"\eOH": beginning-of-line
"\eOF": end-of-line

# Konsole
"\e[H": beginning-of-line
"\e[F": end-of-line
# End /etc/inputrc
EOF
    ok "/etc/inputrc создан"
}

#------------------------------------------------------------------------------
# 9.9 /etc/shells
#------------------------------------------------------------------------------
configure_shells() {
    section "9.9 Создание /etc/shells"
    cat > /etc/shells << 'EOF'
# Begin /etc/shells

/bin/sh
/bin/bash

# End /etc/shells
EOF
    ok "/etc/shells создан"
}

#------------------------------------------------------------------------------
# 9.10 Systemd Usage and Configuration
#------------------------------------------------------------------------------
configure_systemd() {
    section "9.10 Настройка systemd"

    # 9.10.2 — отключить очистку экрана на tty1
    mkdir -pv /etc/systemd/system/getty@tty1.service.d
    cat > /etc/systemd/system/getty@tty1.service.d/noclear.conf << 'EOF'
[Service]
TTYVTDisallocate=no
EOF
    ok "Отключена очистка экрана при загрузке (getty@tty1)"

    # 9.10.8 — ограничение core dumps
    mkdir -pv /etc/systemd/coredump.conf.d
    cat > /etc/systemd/coredump.conf.d/maxuse.conf << 'EOF'
[Coredump]
MaxUse=5G
EOF
    ok "Ограничение core dumps: 5G"

    # /tmp на tmpfs — по умолчанию у systemd
    log "По умолчанию /tmp монтируется как tmpfs (см. 9.10.3 для отключения)"

    # tmpfiles.d
    [[ -d /usr/lib/tmpfiles.d ]] && ok "tmpfiles.d на месте" || warn "/usr/lib/tmpfiles.d отсутствует"

    # ФИКС #1 и #2: явно включаем сетевые службы ДО preset-all
    if command -v systemctl >/dev/null 2>&1; then
        log "Включение systemd-networkd..."
        systemctl enable systemd-networkd 2>/dev/null || warn "systemd-networkd enable не сработал"

        if [[ "$USE_DHCP" == "yes" ]]; then
            log "Включение systemd-resolved (для DNS по DHCP)..."
            systemctl enable systemd-resolved 2>/dev/null || warn "systemd-resolved enable не сработал"
        fi

        log "Применение systemd preset-all..."
        systemctl preset-all 2>/dev/null || warn "systemctl preset-all не сработал в chroot (нормально)"
    else
        warn "systemctl не найден — пропускаю включение служб"
    fi

    ok "Базовая конфигурация systemd завершена"
}

#------------------------------------------------------------------------------
# Вспомогательные проверки-заглушки
#------------------------------------------------------------------------------
ensure_ld_so_conf() {
    if [[ ! -f /etc/ld.so.conf ]]; then
        warn "/etc/ld.so.conf отсутствует — создаём"
        cat > /etc/ld.so.conf << 'EOF'
# Begin /etc/ld.so.conf
/usr/local/lib
/opt/lib
include /etc/ld.so.conf.d/*.conf
# End /etc/ld.so.conf
EOF
        mkdir -pv /etc/ld.so.conf.d
        ok "/etc/ld.so.conf создан"
    else
        ok "/etc/ld.so.conf уже существует"
    fi
}

ensure_nsswitch() {
    if [[ ! -f /etc/nsswitch.conf ]]; then
        warn "/etc/nsswitch.conf отсутствует — создаём"
        cat > /etc/nsswitch.conf << 'EOF'
# Begin /etc/nsswitch.conf
passwd: files systemd
group: files systemd
shadow: files systemd
hosts: mymachines resolve [!UNAVAIL=return] files myhostname dns
networks: files
protocols: files
services: files
ethers: files
rpc: files
# End /etc/nsswitch.conf
EOF
        ok "/etc/nsswitch.conf создан"
    else
        ok "/etc/nsswitch.conf уже существует"
    fi
}

ensure_os_release() {
    if [[ ! -f /etc/os-release ]] || ! grep -q "^NAME=" /etc/os-release 2>/dev/null; then
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
    else
        ok "/etc/os-release уже существует"
    fi
}

#------------------------------------------------------------------------------
# Итоговая проверка
#------------------------------------------------------------------------------
final_check() {
    section "Итоговая проверка Главы 9"

    local files=(
        "/etc/hostname"
        "/etc/hosts"
        "/etc/resolv.conf"
        "/etc/adjtime"
        "/etc/localtime"
        "/etc/vconsole.conf"
        "/etc/locale.conf"
        "/etc/profile"
        "/etc/inputrc"
        "/etc/shells"
        "/etc/os-release"
        "/etc/nsswitch.conf"
        "/etc/ld.so.conf"
    )

    local missing=0 f
    for f in "${files[@]}"; do
        # ФИКС #3: -L || -e — учитываем и висячие симлинки
        if [[ -L "$f" || -e "$f" ]]; then
            printf "  ${GREEN}✔${NC} %s\n" "$f"
        else
            printf "  ${RED}✘${NC} %s (отсутствует)\n" "$f"
            ((missing++))
        fi
    done

    # Сетевые конфиги
    if compgen -G "/etc/systemd/network/*.network" >/dev/null; then
        ok "Сетевые конфиги: $(find /etc/systemd/network -maxdepth 1 -name '*.network' -printf '%f ' 2>/dev/null)"
    else
        warn "/etc/systemd/network/*.network отсутствуют"
    fi

    # Службы systemd
    if [[ -L /etc/systemd/system/multi-user.target.wants/systemd-networkd.service ]]; then
        ok "systemd-networkd включён (автозапуск)"
    else
        warn "systemd-networkd НЕ включён — сеть не поднимется после boot"
    fi

    if [[ "$USE_DHCP" == "yes" ]]; then
        if [[ -L /etc/systemd/system/multi-user.target.wants/systemd-resolved.service ]] \
           || [[ -L /etc/systemd/system/dbus-org.freedesktop.resolve1.service ]]; then
            ok "systemd-resolved включён"
        else
            warn "systemd-resolved НЕ включён — DNS по DHCP не заработает"
        fi
    fi

    if (( missing > 0 )); then
        warn "Отсутствует $missing файлов — проверьте вывод выше"
    else
        ok "Все конфигурационные файлы на месте"
    fi

    echo
    log "Параметры системы:"
    echo "    Hostname:     $HOSTNAME"
    echo "    Timezone:     $TIMEZONE"
    echo "    Locale:       $LOCALE"
    echo "    Keymap:       $KEYMAP"
    echo "    Console font: $CONSOLE_FONT"
    echo "    Network:      $( [[ "$USE_DHCP" == "yes" ]] && echo "DHCP ($NET_IFACE)" || echo "Static $STATIC_IP ($NET_IFACE)" )"
    echo
}

#------------------------------------------------------------------------------
# MAIN
#------------------------------------------------------------------------------
main() {
    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║  LFS $LFS_VERSION — Глава 9: Конфигурация системы         ║"
    echo "║  Начало: $(date)                          ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""

    check_prereq

    configure_network
    configure_resolv_conf
    configure_hostname
    configure_hosts
    check_udev
    configure_udev_rules
    configure_clock
    configure_console
    configure_locale
    configure_inputrc
    configure_shells
    configure_systemd

    ensure_ld_so_conf
    ensure_nsswitch
    ensure_os_release

    final_check

    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║  Глава 9 завершена: $(date)               ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""
}

main "$@"
