#!/bin/bash
###############################################################################
# phase5-chapter9.sh — Глава 9: Конфигурация системы
# ЗАПУСКАЕТСЯ ВНУТРИ CHROOT от root
#
# Все параметры передаются через переменные окружения из build-lfs.sh:
#   HOSTNAME, TIMEZONE, LOCALE, KEYMAP, CONSOLE_FONT,
#   USE_DHCP, STATIC_IP, GATEWAY, DNS_PRIMARY, DNS_SECONDARY, LFS_VERSION
#
# Использование (вручную):
#   chroot $LFS /bin/bash -c "bash /configure-system.sh"
###############################################################################
set -euo pipefail

#------------------------------------------------------------------------------
# Параметры (со значениями по умолчанию)
#------------------------------------------------------------------------------
HOSTNAME="${HOSTNAME:-lfs}"
TIMEZONE="${TIMEZONE:-Europe/Moscow}"
LOCALE="${LOCALE:-ru_RU.UTF-8}"
KEYMAP="${KEYMAP:-ru}"
CONSOLE_FONT="${CONSOLE_FONT:-Lat2-Terminus16}"
USE_DHCP="${USE_DHCP:-yes}"
STATIC_IP="${STATIC_IP:-192.168.1.100}"
GATEWAY="${GATEWAY:-192.168.1.1}"
DNS_PRIMARY="${DNS_PRIMARY:-8.8.8.8}"
DNS_SECONDARY="${DNS_SECONDARY:-8.8.4.4}"
LFS_VERSION="${LFS_VERSION:-13.1-systemd}"

# Автоопределение интерфейса (можно переопределить через NET_IFACE)
NET_IFACE="${NET_IFACE:-}"

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

#------------------------------------------------------------------------------
# Проверка контекста
#------------------------------------------------------------------------------
check_prereq() {
    [[ "$(id -u)" == "0" ]] || die "Скрипт должен запускаться от root внутри chroot"
    [[ -f /etc/passwd ]]     || die "Не в chroot — нет /etc/passwd"
    [[ -f /etc/lfs-release ]] && \
        ok "Система LFS $(cat /etc/lfs-release)" || \
        warn "/etc/lfs-release отсутствует (создадим в Главе 11)"
}

#------------------------------------------------------------------------------
# 9.2.1 Network Interface Configuration Files
#------------------------------------------------------------------------------
configure_network() {
    section "9.2.1 Настройка сети (systemd-networkd)"

    mkdir -pv /etc/systemd/network

    # Определяем имя интерфейса
    if [[ -z "$NET_IFACE" ]]; then
        # Пробуем найти в /sys/class/net, исключая lo
        for iface in /sys/class/net/*; do
            name=$(basename "$iface")
            [[ "$name" == "lo" ]] && continue
            NET_IFACE="$name"
            break
        done
        # Если не нашли — используем enp0s3 как типичный для VirtualBox
        NET_IFACE="${NET_IFACE:-enp0s3}"
        warn "Автоопределение интерфейса: $NET_IFACE (переопределите через NET_IFACE)"
    fi
    ok "Сетевой интерфейс: $NET_IFACE"

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
Address=$STATIC_IP/24
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

    # При использовании systemd-resolved файл создаётся автоматически,
    # но для chroot и совместимости создаём статический
    if [[ "$USE_DHCP" == "no" ]]; then
        cat > /etc/resolv.conf << EOF
# Begin /etc/resolv.conf

domain $HOSTNAME.local
nameserver $DNS_PRIMARY
nameserver $DNS_SECONDARY

# End /etc/resolv.conf
EOF
        ok "/etc/resolv.conf создан (статический)"
    else
        # При DHCP создаём заглушку — systemd-resolved заменит на boot
        log "DHCP: /etc/resolv.conf будет управляться systemd-resolved"
        if [[ ! -L /etc/resolv.conf ]]; then
            ln -sfv /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
            ok "Создана ссылка на stub-resolv.conf"
        fi
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
# 9.3 Overview of Device and Module Handling
#------------------------------------------------------------------------------
# Чисто информационный раздел — никаких действий не требуется.
# Но проверим, что systemd-udevd на месте.
check_udev() {
    section "9.3 Проверка systemd-udevd"

    if [[ -x /usr/lib/systemd/systemd-udevd ]]; then
        ok "systemd-udevd найден"
    else
        die "systemd-udevd отсутствует — проверьте установку systemd"
    fi

    # Проверка базовых udev-правил
    [[ -f /usr/lib/udev/rules.d/50-udev-default.rules ]] && \
        ok "udev default rules на месте" || \
        warn "udev default rules отсутствуют"
}

#------------------------------------------------------------------------------
# 9.4 Managing Devices — опциональные правила
#------------------------------------------------------------------------------
configure_udev_rules() {
    section "9.4 Управление устройствами (опционально)"

    # Если пользователь хочет persistent symlinks для камер/тюнеров —
    # создаём шаблонный файл, который можно отредактировать позже.
    if [[ ! -f /etc/udev/rules.d/83-duplicate_devs.rules ]]; then
        cat > /etc/udev/rules.d/83-duplicate_devs.rules << 'EOF'
# Persistent symlinks for webcam and tuner
# Отредактируйте под свои устройства (используйте `udevadm info -a -p /sys/class/...`)
# KERNEL=="video*", ATTRS{idProduct}=="1910", ATTRS{idVendor}=="0d81", SYMLINK+="webcam"
# KERNEL=="video*", ATTRS{device}=="0x036f", ATTRS{vendor}=="0x109e", SYMLINK+="tvtuner"
EOF
        ok "Создан шаблон /etc/udev/rules.d/83-duplicate_devs.rules"
    else
        ok "Правила udev уже существуют (пропуск)"
    fi
}

#------------------------------------------------------------------------------
# 9.5 System Clock — /etc/adjtime
#------------------------------------------------------------------------------
configure_clock() {
    section "9.5 Настройка системных часов"

    # Определяем, использует ли хост local time или UTC.
    # По умолчанию — UTC (рекомендуется).
    local RTC_MODE="UTC"
    if command -v hwclock >/dev/null 2>&1; then
        if hwclock --localtime --show >/dev/null 2>&1; then
            local hw_time=$(hwclock --localtime --show 2>/dev/null | head -1 || true)
            local sys_time=$(date '+%Y-%m-%d %H:%M:%S')
            # Грубая проверка: если разница < 5 минут — local
            if [[ -n "$hw_time" ]]; then
                local hw_epoch=$(date -d "$hw_time" +%s 2>/dev/null || echo 0)
                local sys_epoch=$(date +%s)
                local diff=$(( hw_epoch > sys_epoch ? hw_epoch - sys_epoch : sys_epoch - hw_epoch ))
                (( diff < 300 )) && RTC_MODE="LOCAL"
            fi
        fi
    fi

    if [[ "$RTC_MODE" == "LOCAL" ]]; then
        log "Аппаратные часы установлены в LOCAL time"
        cat > /etc/adjtime << 'EOF'
0.0 0 0.0
0
LOCAL
EOF
    else
        log "Аппаратные часы установлены в UTC (рекомендуется)"
        # Файл /etc/adjtime создаст systemd-timedated при первом boot.
        # Для явности — создаём UTC по умолчанию:
        cat > /etc/adjtime << 'EOF'
0.0 0 0.0
0
UTC
EOF
    fi

    # Настройка часового пояса через /etc/localtime
    if [[ -f "/usr/share/zoneinfo/$TIMEZONE" ]]; then
        ln -sfv "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
        ok "Часовой пояс: $TIMEZONE"
    else
        warn "Часовой пояс '$TIMEZONE' не найден в /usr/share/zoneinfo"
        warn "Доступные варианты: посмотрите /usr/share/zoneinfo/"
        # Fallback
        if [[ -f /usr/share/zoneinfo/UTC ]]; then
            ln -sfv /usr/share/zoneinfo/UTC /etc/localtime
            warn "Использован UTC как fallback"
        fi
    fi

    # Попытка timedatectl (может не работать в chroot — не критично)
    if command -v timedatectl >/dev/null 2>&1; then
        timedatectl set-timezone "$TIMEZONE" 2>/dev/null || \
            warn "timedatectl недоступен в chroot (нормально — применится при boot)"
    fi
}

#------------------------------------------------------------------------------
# 9.6 Linux Console — /etc/vconsole.conf
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

    # Проверка наличия шрифта
    if [[ ! -f "/usr/share/consolefonts/${CONSOLE_FONT}.psfu.gz" && \
          ! -f "/usr/share/consolefonts/${CONSOLE_FONT}.psf.gz" && \
          ! -f "/usr/share/consolefonts/${CONSOLE_FONT}" ]]; then
        warn "Шрифт консоли '$CONSOLE_FONT' не найден в /usr/share/consolefonts"
        warn "Доступные шрифты (первые 10):"
        ls /usr/share/consolefonts/ 2>/dev/null | head -10 | sed 's/^/    /'
    else
        ok "Шрифт консоли найден"
    fi
}

#------------------------------------------------------------------------------
# 9.7 System Locale — /etc/locale.conf, /etc/profile
#------------------------------------------------------------------------------
configure_locale() {
    section "9.7 Настройка локали системы"

    # /etc/locale.conf
    cat > /etc/locale.conf << EOF
LANG=$LOCALE
EOF
    ok "/etc/locale.conf создан (LANG=$LOCALE)"

    # Проверка, что локаль установлена
    if LC_ALL="$LOCALE" locale charmap >/dev/null 2>&1; then
        ok "Локаль '$LOCALE' доступна"
    else
        warn "Локаль '$LOCALE' не установлена"
        warn "Установите её: localedef -i ${LOCALE%.*} -f ${LOCALE##*.} $LOCALE"
        warn "Доступные локали: locale -a | head"
    fi

    # /etc/profile с обработкой локали для Linux console
    cat > /etc/profile << 'EOF'
# Begin /etc/profile

# Если работаем в Linux console — используем C.UTF-8 (нет глифов для многого)
# Иначе — читаем /etc/locale.conf
for i in $(locale); do
    unset ${i%=*}
done

if [[ "$TERM" = linux ]]; then
    export LANG=C.UTF-8
else
    if [ -f /etc/locale.conf ]; then
        source /etc/locale.conf
    fi
    for i in $(locale); do
        key=${i%=*}
        if [[ -v $key ]]; then
            export $key
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
# Modified by Chris Lynn <roryo@roryo.dynup.net>

# Allow the command prompt to wrap to the next line
set horizontal-scroll-mode Off

# Enable 8-bit input
set meta-flag On
set input-meta On

# Turns off 8th bit stripping
set convert-meta Off

# Keep the 8th bit for display
set output-meta On

# none, visible or audible
set bell-style none

# All of the following map the escape sequence of the value
# contained in the 1st argument to the readline specific functions
"\eOd": backward-word
"\eOc": forward-word

# for linux console
"\e[1~": beginning-of-line
"\e[4~": end-of-line
"\e[5~": beginning-of-history
"\e[6~": end-of-history
"\e[3~": delete-char
"\e[2~": quoted-insert

# for xterm
"\eOH": beginning-of-line
"\eOF": end-of-line

# for Konsole
"\e[H": beginning-of-line
"\e[F": end-of-line

# uncomment for history search mode with up/down
# "\e[A": history-search-backward
# "\e[B": history-search-forward

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

    # --- 9.10.2 Отключение очистки экрана при загрузке (опционально) ---
    mkdir -pv /etc/systemd/system/getty@tty1.service.d
    cat > /etc/systemd/system/getty@tty1.service.d/noclear.conf << 'EOF'
[Service]
TTYVTDisallocate=no
EOF
    ok "Отключена очистка экрана при загрузке (getty@tty1)"

    # --- 9.10.3 /tmp как tmpfs ---
    # По умолчанию systemd монтирует /tmp как tmpfs.
    # Раскомментируйте, если хотите отключить:
    # systemctl mask tmp.mount
    log "По умолчанию /tmp монтируется как tmpfs (см. 9.10.3 для отключения)"
    ok "/tmp: используется tmpfs (по умолчанию systemd)"

    # --- 9.10.4 Автосоздание/удаление файлов (tmpfiles.d) ---
    if [[ -d /usr/lib/tmpfiles.d ]]; then
        ok "tmpfiles.d на месте"
    else
        warn "/usr/lib/tmpfiles.d отсутствует"
    fi

    # --- 9.10.5 Override поведения служб — пример (закомментирован) ---
    # mkdir -pv /etc/systemd/system/foobar.service.d
    # cat > /etc/systemd/system/foobar.service.d/foobar.conf << EOF
    # [Service]
    # Restart=always
    # RestartSec=30
    # EOF

    # --- 9.10.8 Ограничение core dumps (опционально, но полезно) ---
    mkdir -pv /etc/systemd/coredump.conf.d
    cat > /etc/systemd/coredump.conf.d/maxuse.conf << 'EOF'
[Coredump]
MaxUse=5G
EOF
    ok "Ограничение core dumps: 5G"

    # --- 9.10.9 Long Running Processes ---
    # По умолчанию systemd убивает все процессы при выходе из сессии.
    # Для удобства можно разрешить lingering.
    # Оставлено на усмотрение пользователя — не меняем.

    # --- Применение systemd пресетов (активация служб по умолчанию) ---
    if command -v systemctl >/dev/null 2>&1; then
        systemctl preset-all 2>/dev/null || \
            warn "systemctl preset-all не сработал в chroot (применится при boot)"
    fi

    ok "Базовая конфигурация systemd завершена"
}

#------------------------------------------------------------------------------
# Дополнительно: /etc/ld.so.conf (обычно создаётся в Главе 8.5, но проверим)
#------------------------------------------------------------------------------
ensure_ld_so_conf() {
    if [[ ! -f /etc/ld.so.conf ]]; then
        warn "/etc/ld.so.conf отсутствует — создаём"
        cat > /etc/ld.so.conf << 'EOF'
# Begin /etc/ld.so.conf
/usr/local/lib
/opt/lib

# Add an include directory
include /etc/ld.so.conf.d/*.conf
# End /etc/ld.so.conf
EOF
        mkdir -pv /etc/ld.so.conf.d
        ok "/etc/ld.so.conf создан"
    else
        ok "/etc/ld.so.conf уже существует"
    fi
}

#------------------------------------------------------------------------------
# Дополнительно: /etc/nsswitch.conf (проверка)
#------------------------------------------------------------------------------
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

#------------------------------------------------------------------------------
# Дополнительно: /etc/os-release (для systemd)
#------------------------------------------------------------------------------
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

    local missing=0
    for f in "${files[@]}"; do
        if [[ -e "$f" ]]; then
            printf "  ${GREEN}✔${NC} %s\n" "$f"
        else
            printf "  ${RED}✘${NC} %s (отсутствует)\n" "$f"
            ((missing++))
        fi
    done

    # Сетевые конфиги
    if compgen -G "/etc/systemd/network/*.network" >/dev/null; then
        ok "Сетевые конфиги в /etc/systemd/network/"
    else
        warn "/etc/systemd/network/*.network отсутствуют"
    fi

    if (( missing > 0 )); then
        warn "Отсутствует $missing файлов — проверьте вывод выше"
    else
        ok "Все конфигурационные файлы на месте"
    fi

    # Сводка параметров
    echo
    log "Параметры системы:"
    echo "    Hostname:     $HOSTNAME"
    echo "    Timezone:     $TIMEZONE"
    echo "    Locale:       $LOCALE"
    echo "    Keymap:       $KEYMAP"
    echo "    Console font: $CONSOLE_FONT"
    echo "    Network:      $( [[ "$USE_DHCP" == "yes" ]] && echo "DHCP" || echo "Static ($STATIC_IP)" )"
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

    # Дополнительные проверки/создания
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