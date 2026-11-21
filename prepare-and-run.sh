#!/bin/bash
###############################################################################
# prepare-and-run.sh — подготовка диска и запуск оркестратора LFS
#
# Делает всё, что нужно до первой сборки:
#   1. выбор диска (интерактивно или --disk)
#   2. разметка GPT + файловые системы
#   3. монтирование в /mnt/lfs (корень, boot, efi) и swap
#   4. записи в /etc/fstab по UUID
#   5. $LFS/sources: копирование или скачивание исходников + проверка md5
#   6. копирование скриптов внутрь $LFS/sources/scripts (нужно chroot-исполнителю)
#   7. глава 4: структура каталогов и пользователь lfs
#   8. venv + зависимости оркестратора, .env
#   9. запуск веб-интерфейса оркестратора
#
# Запуск (нужен root):
#     sudo bash prepare-and-run.sh
#     sudo bash prepare-and-run.sh --disk /dev/sda --yes
#     sudo bash prepare-and-run.sh --list-disks
#     sudo bash prepare-and-run.sh --skip-partition --no-run
#
# Справка: bash prepare-and-run.sh --help
###############################################################################
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"

#------------------------------------------------------------------------------
# Значения по умолчанию
#------------------------------------------------------------------------------
LFS="${LFS:-/mnt/lfs}"
LFS_TGT="${LFS_TGT:-$(uname -m)-lfs-linux-gnu}"
DISK="${DISK:-}"
ASSUME_YES=0
DO_PARTITION=1
DO_MOUNT=1
DO_FSTAB=1
DO_SOURCES=1
DO_CHAPTER4=1
DO_RUN=1
SOURCES_FROM=""
ALLOW_DOWNLOAD=0
EXECUTOR="${LFS_EXECUTOR:-}"
EXECUTOR_GIVEN=0
PORT="${ORCHESTRATOR_PORT:-8100}"
DRY_RUN=0
INSTALL_DEPS=0

# Схема разделов (совпадает с scripts/phase0-host-prep.sh)
MB_ESP_END=513
MB_BIOS_END=514
MB_BOOT_END=1014
MB_SWAP_END=3072

#------------------------------------------------------------------------------
# Оформление вывода
#------------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[1;33m'
    C_BLUE=$'\033[0;34m'; C_BOLD=$'\033[1m'; C_OFF=$'\033[0m'
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""; C_OFF=""
fi

STEP=0
step()  { STEP=$((STEP + 1)); echo; echo "${C_BOLD}${C_BLUE}══ ${STEP}. $* ${C_OFF}"; }
log()   { echo "   $*"; }
ok()    { echo "   ${C_GREEN}✓${C_OFF} $*"; }
info()  { echo "   ${C_BLUE}·${C_OFF} $*"; }
warn()  { echo "   ${C_YELLOW}!${C_OFF} $*"; }
err()   { echo "   ${C_RED}✗ $*${C_OFF}" >&2; }
die()   { err "$*"; exit 1; }

run() {
    if (( DRY_RUN )); then
        echo "   ${C_YELLOW}[dry-run]${C_OFF} $*"
        return 0
    fi
    "$@"
}

# Проверка «URL отвечает по HTTP». curl есть не везде (на чистом Debian его
# может не быть), поэтому пробуем curl → wget → python из venv. Раньше здесь
# был только curl, и при его отсутствии исправно поднявшийся оркестратор
# объявлялся «не отвечающим».
http_ok() {
    local url="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -fsS -o /dev/null --max-time 3 "$url" 2>/dev/null
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O /dev/null -T 3 "$url" 2>/dev/null
    elif [[ -x .venv/bin/python ]]; then
        .venv/bin/python - "$url" >/dev/null 2>&1 <<'PY'
import sys, urllib.request
try:
    urllib.request.urlopen(sys.argv[1], timeout=3)
except Exception:
    sys.exit(1)
PY
    else
        return 1
    fi
}

confirm() {
    local prompt="$1" answer
    (( ASSUME_YES )) && return 0
    if [[ ! -t 0 ]]; then
        warn "нет терминала для подтверждения → считаю «нет» (используйте --yes)"
        return 1
    fi
    read -rp "   $prompt [y/N]: " answer
    [[ "$answer" =~ ^[yYдД] ]]
}

usage() {
    cat <<EOF
prepare-and-run.sh — подготовка диска и запуск оркестратора LFS

Использование:
    sudo bash prepare-and-run.sh [параметры]

Параметры:
    --disk <устройство>   диск для LFS (например /dev/sda). Без него — выбор из списка
    --list-disks          показать доступные диски и выйти
    --skip-partition      не размечать (диск уже размечен) — только ФС и монтирование
    --skip-mount          не монтировать
    --skip-fstab          не трогать /etc/fstab
    --skip-sources        не копировать и не скачивать исходники
    --skip-chapter4       не выполнять главу 4 (каталоги и пользователь lfs)
    --sources <каталог>   откуда взять tarball'ы (по умолчанию ../sources)
    --download            скачать исходники по wget-list, если их нет
    --executor <тип>      local | chroot | docker (по умолчанию chroot)
    --port <номер>        порт веб-интерфейса (по умолчанию 8100)
    --no-run              только подготовить, оркестратор не запускать
    --dry-run             показать, что будет сделано, ничего не меняя
    --install-deps        поставить недостающие сборочные пакеты через apt
    --yes, -y             не спрашивать подтверждений
    -h, --help            эта справка

Внимание: разметка уничтожает все данные на выбранном диске.
EOF
}

#------------------------------------------------------------------------------
# Разбор аргументов
#------------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --disk)           DISK="${2:-}"; [[ -n "$DISK" ]] || die "--disk требует устройство"; shift 2 ;;
        --list-disks)     LIST_DISKS_ONLY=1; shift ;;
        --skip-partition) DO_PARTITION=0; shift ;;
        --skip-mount)     DO_MOUNT=0; shift ;;
        --skip-fstab)     DO_FSTAB=0; shift ;;
        --skip-sources)   DO_SOURCES=0; shift ;;
        --skip-chapter4)  DO_CHAPTER4=0; shift ;;
        --sources)        SOURCES_FROM="${2:-}"; [[ -n "$SOURCES_FROM" ]] || die "--sources требует каталог"; shift 2 ;;
        --download)       ALLOW_DOWNLOAD=1; shift ;;
        --executor)       EXECUTOR="${2:-}"; EXECUTOR_GIVEN=1; shift 2 ;;
        --port)           PORT="${2:-}"; shift 2 ;;
        --no-run)         DO_RUN=0; shift ;;
        --dry-run)        DRY_RUN=1; shift ;;
        --install-deps)   INSTALL_DEPS=1; shift ;;
        --yes|-y)         ASSUME_YES=1; shift ;;
        -h|--help)        usage; exit 0 ;;
        *) err "неизвестный параметр: $1"; usage; exit 2 ;;
    esac
done

#------------------------------------------------------------------------------
# Корень и базовые инструменты
#------------------------------------------------------------------------------
if [[ "$(id -u)" != "0" ]]; then
    if command -v sudo >/dev/null 2>&1 && (( ! DRY_RUN )); then
        warn "нужен root — перезапускаю через sudo"
        exec sudo bash "$SCRIPT_PATH" "$@"
    fi
    die "запускать от root"
fi

# Если исполнитель не задан явно — уважаем то, что записано в .env
if (( ! EXECUTOR_GIVEN )) && [[ -f "$SCRIPT_DIR/.env" ]]; then
    from_env="$(grep -E '^LFS_EXECUTOR=' "$SCRIPT_DIR/.env" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
    [[ -n "$from_env" ]] && EXECUTOR="$from_env"
fi
EXECUTOR="${EXECUTOR:-chroot}"

for tool in lsblk findmnt parted mkfs.ext4 mkfs.ext2 mkfs.vfat sfdisk blkid; do
    command -v "$tool" >/dev/null 2>&1 || die "не найден инструмент: $tool (apt install parted dosfstools e2fsprogs util-linux)"
done

#------------------------------------------------------------------------------
# Инструменты хоста — без них не соберётся даже binutils-pass1
#------------------------------------------------------------------------------
step "Инструменты сборки на хосте"

declare -A TOOL_PKG=(
    [gcc]=build-essential   [g++]=build-essential  [make]=build-essential
    [ld]=binutils           [as]=binutils
    [bison]=bison           [gawk]=gawk           [m4]=m4
    [patch]=patch           [makeinfo]=texinfo
    [perl]=perl             [python3]=python3
    [tar]=tar               [xz]=xz-utils         [bzip2]=bzip2
    [gzip]=gzip             [sed]=sed             [grep]=grep
    [diff]=diffutils        [find]=findutils      [awk]=gawk
)
missing_tools=()
missing_pkgs=""
for tool in "${!TOOL_PKG[@]}"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        missing_tools+=("$tool")
        pkg="${TOOL_PKG[$tool]}"
        [[ " $missing_pkgs " == *" $pkg "* ]] || missing_pkgs+="$pkg "
    fi
done

if (( ${#missing_tools[@]} == 0 )); then
    ok "все инструменты на месте ($(gcc -dumpversion 2>/dev/null) gcc, $(make --version 2>/dev/null | head -1))"
else
    warn "нет инструментов: ${missing_tools[*]}"
    warn "пакеты Debian: $missing_pkgs"
    if (( INSTALL_DEPS )); then
        if command -v apt-get >/dev/null 2>&1; then
            info "устанавливаю через apt-get…"
            if run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $missing_pkgs; then
                ok "установлено"
            else
                err "apt-get не справился — поставьте вручную: apt install $missing_pkgs"
            fi
        else
            err "apt-get не найден — поставьте пакеты вручную"
        fi
    else
        err "сборка не начнётся. Запустите с --install-deps или поставьте вручную:"
        err "    apt install $missing_pkgs"
        die "не хватает инструментов сборки"
    fi
fi

#------------------------------------------------------------------------------
# Работа с дисками
#------------------------------------------------------------------------------
disk_model() { lsblk -dno MODEL "$1" 2>/dev/null | sed 's/ *$//'; }
disk_size()  { lsblk -dno SIZE  "$1" 2>/dev/null; }

all_disks() {
    lsblk -dno NAME,TYPE | awk '$2=="disk" {print "/dev/"$1}'
}

root_disk() {
    local src
    src="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
    [[ -z "$src" ]] && return 0
    src="$(readlink -f "$src")"
    # /dev/nvme0n1p1 -> /dev/nvme0n1 ; /dev/sda1 -> /dev/sda
    lsblk -no PKNAME "$src" 2>/dev/null | head -1 | sed 's|^|/dev/|'
}

disk_is_safe() {
    local d="$1" pk mounts
    d="$(readlink -f "$d")"
    [[ -b "$d" ]] || { echo "не блочное устройство"; return 1; }

    pk="$(root_disk)"
    if [[ -n "$pk" && "$(readlink -f "$pk")" == "$d" ]]; then
        echo "на этом диске находится корневая файловая система (/ )"
        return 1
    fi

    mounts="$(lsblk -nlo MOUNTPOINT "$d" 2>/dev/null | tr -d ' ' | grep -vE '^$|^\[' || true)"
    if [[ -n "$mounts" ]]; then
        # Разделы, смонтированные в наш же $LFS, — это уже подготовленный диск
        local foreign=""
        while IFS= read -r mp; do
            [[ -z "$mp" ]] && continue
            [[ "$mp" == "$LFS" || "$mp" == "$LFS"/* ]] || foreign+="$mp "
        done <<< "$mounts"
        if [[ -n "$foreign" ]]; then
            echo "на диске есть смонтированные разделы: $foreign"
            return 1
        fi
    fi
    return 0
}

show_disks() {
    local pk
    pk="$(root_disk)"
    printf "   %-4s %-14s %-8s %-22s %s\n" "№" "УСТРОЙСТВО" "РАЗМЕР" "МОДЕЛЬ" "ПРИМЕЧАНИЕ"
    local i=1
    for d in $(all_disks); do
        local note=""
        if [[ -n "$pk" && "$(readlink -f "$d")" == "$(readlink -f "$pk")" ]]; then
            note="${C_RED}система — нельзя${C_OFF}"
        else
            local mounts foreign=""
            mounts="$(lsblk -nlo MOUNTPOINT "$d" 2>/dev/null | tr -d ' ' | grep -vE '^$|^\[' || true)"
            while IFS= read -r mp; do
                [[ -z "$mp" ]] && continue
                [[ "$mp" == "$LFS" || "$mp" == "$LFS"/* ]] || foreign+="$mp "
            done <<< "$mounts"
            if [[ -n "$foreign" ]]; then
                note="${C_YELLOW}занят: $foreign${C_OFF}"
            elif [[ -n "$mounts" ]]; then
                note="${C_GREEN}уже подготовлен для LFS${C_OFF}"
            fi
        fi
        printf "   %-4s %-14s %-8s %-22s %s\n" "$i" "$d" "$(disk_size "$d")" "$(disk_model "$d")" "$note"
        DISK_LIST[$i]="$d"
        i=$((i + 1))
    done
}

if (( ${LIST_DISKS_ONLY:-0} )); then
    echo "${C_BOLD}Доступные диски${C_OFF}"
    declare -A DISK_LIST
    show_disks
    exit 0
fi

declare -A DISK_LIST

choose_disk() {
    if [[ -n "$DISK" ]]; then
        local why
        why="$(disk_is_safe "$DISK")" || die "диск $DISK не подходит: $why"
        return 0
    fi

    echo "${C_BOLD}Выберите диск для LFS${C_OFF}"
    show_disks

    local answer
    while true; do
        if [[ ! -t 0 ]]; then
            die "не указан --disk и нет терминала для выбора"
        fi
        read -rp "   номер диска (q — выход): " answer
        [[ "$answer" =~ ^[qQ]$ ]] && { echo "   отменено"; exit 1; }
        [[ "$answer" =~ ^[0-9]+$ ]] || { warn "введите номер"; continue; }
        DISK="${DISK_LIST[$answer]:-}"
        [[ -n "$DISK" ]] || { warn "нет такого номера"; continue; }
        local why
        why="$(disk_is_safe "$DISK")" && break
        err "диск $DISK не подходит: $why"
        DISK=""
    done
}

#------------------------------------------------------------------------------
# Шаг: диск и разметка
#------------------------------------------------------------------------------
step "Выбор диска"
choose_disk
PART_EFI="${DISK}1"
PART_BOOT="${DISK}3"
PART_SWAP="${DISK}4"
PART_LFS="${DISK}5"
ok "диск: ${C_BOLD}$DISK${C_OFF} ($(disk_size "$DISK"), $(disk_model "$DISK"))"
info "разделы: EFI ${PART_EFI} · BOOT ${PART_BOOT} · SWAP ${PART_SWAP} · LFS ${PART_LFS}"

if (( DO_PARTITION )); then
    step "Разметка диска"

    expected_fs() {
        case "$1" in
            "$PART_EFI")  echo "vfat" ;;
            "$PART_BOOT") echo "ext2" ;;
            "$PART_SWAP") echo "swap" ;;
            "$PART_LFS")  echo "ext4" ;;
        esac
    }

    already=1
    for p in "$PART_EFI" "$PART_BOOT" "$PART_SWAP" "$PART_LFS"; do
        want="$(expected_fs "$p")"
        have="$(lsblk -dno FSTYPE "$p" 2>/dev/null | tr -d ' ')"
        [[ -b "$p" && "$have" == "$want" ]] || { already=0; break; }
    done

    if (( already )); then
        info "диск уже размечен по нужной схеме — разметка не требуется"
        info "(принудительно переразметить: умonт+разметка вручную или удалите разделы)"
    else
        echo "   ${C_RED}ВНИМАНИЕ: все данные на $DISK будут уничтожены.${C_OFF}"
        echo "   Схема: GPT, ESP 512М · BIOS_BOOT 1М · BOOT 500М · SWAP 2Г · LFS — остальное"

        # Всё, что смонтировано с этого диска, придётся размонтировать
        mounted_here="$(lsblk -nlo MOUNTPOINT "$DISK" 2>/dev/null | tr -d ' ' | grep -vE '^$|^\[' || true)"
        if [[ -n "$mounted_here" ]]; then
            warn "с диска смонтировано: $(echo "$mounted_here" | tr '\n' ' ')"
            if ! confirm "Размонтировать и разметить $DISK заново?"; then
                die "отменено пользователем"
            fi
            while IFS= read -r mp; do
                [[ -z "$mp" ]] && continue
                run umount "$mp" || die "не удалось размонтировать $mp"
                ok "размонтирован $mp"
            done <<< "$mounted_here"
            if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$PART_SWAP"; then
                run swapoff "$PART_SWAP" && ok "swap $PART_SWAP выключен"
            fi
        elif ! confirm "Разметить $DISK?"; then
            die "отменено пользователем"
        fi

        if (( ! DRY_RUN )); then
            parted -s "$DISK" mklabel gpt || die "parted: не удалось создать таблицу GPT"
            parted -s "$DISK" mkpart ESP fat32 1MiB "${MB_ESP_END}MiB"                 || die "parted: раздел ESP"
            parted -s "$DISK" set 1 esp on                                             || die "parted: флаг esp"
            parted -s "$DISK" mkpart BIOS_BOOT "${MB_ESP_END}MiB" "${MB_BIOS_END}MiB"  || die "parted: раздел BIOS_BOOT"
            parted -s "$DISK" set 2 bios_grub on                                       || die "parted: флаг bios_grub"
            parted -s "$DISK" mkpart BOOT ext2 "${MB_BIOS_END}MiB" "${MB_BOOT_END}MiB" || die "parted: раздел BOOT"
            parted -s "$DISK" mkpart SWAP linux-swap "${MB_BOOT_END}MiB" "${MB_SWAP_END}MiB" || die "parted: раздел SWAP"
            parted -s "$DISK" mkpart LFS ext4 "${MB_SWAP_END}MiB" 100%                  || die "parted: раздел LFS"
            partprobe "$DISK" 2>/dev/null || true
            sleep 2
        fi

        for p in "$PART_EFI" "$PART_BOOT" "$PART_SWAP" "$PART_LFS"; do
            [[ -b "$p" ]] || die "после разметки нет раздела $p — проверьте parted -l $DISK"
        done
        ok "разметка создана"
    fi
else
    step "Разметка диска — пропущена (--skip-partition)"
    for p in "$PART_LFS" "$PART_BOOT" "$PART_EFI"; do
        [[ -b "$p" ]] || die "нет раздела $p — разметьте диск без --skip-partition"
    done
    ok "разделы на месте"
fi

#------------------------------------------------------------------------------
# Шаг: файловые системы
#------------------------------------------------------------------------------
step "Файловые системы"
mk_if_empty() {
    local part="$1" kind="$2" label="${3:-}"
    [[ -b "$part" ]] || { warn "нет раздела $part — пропуск"; return 0; }
    local current
    current="$(lsblk -dno FSTYPE "$part" 2>/dev/null | tr -d ' ')"
    if [[ -n "$current" ]]; then
        if [[ "$current" == "$kind" || ( "$kind" == "vfat" && "$current" == "vfat" ) ]]; then
            info "$part: уже $current"
        else
            warn "$part: сейчас $current, ожидалось $kind — переформатирую"
            confirm "Переформатировать $part в $kind?" || die "отменено"
            mk_force "$part" "$kind" "$label"
        fi
        return 0
    fi
    mk_force "$part" "$kind" "$label"
}

mk_force() {
    local part="$1" kind="$2" label="${3:-}"
    case "$kind" in
        vfat) run mkfs.vfat -F 32 "$part" ;;
        ext2) run mkfs.ext2 -q ${label:+-L "$label"} "$part" ;;
        ext4) run mkfs.ext4 -q ${label:+-L "$label"} "$part" ;;
        swap) run mkswap "$part" ;;
        *) die "неизвестный тип ФС: $kind" ;;
    esac
    ok "$part → $kind${label:+ (метка $label)}"
}

mk_if_empty "$PART_EFI"  vfat ESP
mk_if_empty "$PART_BOOT" ext2 BOOT
mk_if_empty "$PART_SWAP" swap
mk_if_empty "$PART_LFS"  ext4 lfs

#------------------------------------------------------------------------------
# Шаг: монтирование
#------------------------------------------------------------------------------
mkdir -p "$LFS"

if (( DO_MOUNT )); then
    step "Монтирование"
    is_mounted() { mountpoint -q "$1"; }

    if is_mounted "$LFS"; then
        info "$LFS уже смонтирован ($(findmnt -n -o SOURCE "$LFS"))"
    else
        run mount "$PART_LFS" "$LFS" || die "не удалось смонтировать $PART_LFS"
        ok "$PART_LFS → $LFS"
    fi

    mkdir -p "$LFS/boot"
    if is_mounted "$LFS/boot"; then
        info "$LFS/boot уже смонтирован"
    else
        run mount "$PART_BOOT" "$LFS/boot" || warn "не удалось смонтировать $PART_BOOT"
        (( DRY_RUN )) || ok "$PART_BOOT → $LFS/boot"
    fi

    mkdir -p "$LFS/boot/efi"
    if is_mounted "$LFS/boot/efi"; then
        info "$LFS/boot/efi уже смонтирован"
    else
        run mount "$PART_EFI" "$LFS/boot/efi" || warn "не удалось смонтировать $PART_EFI"
        (( DRY_RUN )) || ok "$PART_EFI → $LFS/boot/efi"
    fi

    if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$PART_SWAP"; then
        info "swap $PART_SWAP уже включён"
    else
        run swapon "$PART_SWAP" 2>/dev/null && ok "swap $PART_SWAP включён" || warn "swap не включён"
    fi

    run chown root:root "$LFS"
    run chmod 755 "$LFS"
else
    step "Монтирование — пропущено (--skip-mount)"
    is_mounted() { mountpoint -q "$1"; }
    is_mounted "$LFS" || die "$LFS не смонтирован, а --skip-mount указан"
    ok "$LFS смонтирован"
fi

#------------------------------------------------------------------------------
# Шаг: /etc/fstab
#------------------------------------------------------------------------------
# Печатает ТОЛЬКО строку для fstab. Если запись уже есть — ничего не печатает
# и возвращает 1 (иначе текст сообщений попадал в /etc/fstab).
fstab_line() {
    local spec="$1" mp="$2" fstype="$3" opts="$4"
    local uuid
    uuid="$(blkid -s UUID -o value "$spec" 2>/dev/null || true)"
    [[ -n "$uuid" ]] || return 1
    grep -qs "UUID=$uuid" /etc/fstab && return 1
    printf 'UUID=%s  %s  %s  %s  0 0\n' "$uuid" "$mp" "$fstype" "$opts"
}

if (( DO_FSTAB )); then
    step "Записи в /etc/fstab"
    if (( DRY_RUN )); then
        info "dry-run: fstab не изменяется"
    else
        cp -a /etc/fstab "/etc/fstab.bak-$(date +%Y%m%d-%H%M%S)"
        added=0
        add_line() {
            local line="$1"
            [[ -z "$line" ]] && return 0
            printf '%s\n' "$line" >> /etc/fstab
            added=$((added + 1))
        }
        add_line "$(fstab_line "$PART_LFS"  "$LFS"          ext4 "defaults,nofail,x-systemd.device-timeout=15")"
        add_line "$(fstab_line "$PART_BOOT" "$LFS/boot"     ext2 "defaults,nofail")"
        add_line "$(fstab_line "$PART_EFI"  "$LFS/boot/efi" vfat "umask=0077,nofail")"
        swap_uuid="$(blkid -s UUID -o value "$PART_SWAP" 2>/dev/null || true)"
        if [[ -n "$swap_uuid" ]] && ! grep -qs "UUID=$swap_uuid" /etc/fstab; then
            add_line "UUID=$swap_uuid  swap  swap  defaults,nofail  0 0"
        fi
        if (( added )); then
            ok "fstab обновлён: добавлено записей $added (бэкап рядом)"
        else
            info "fstab уже содержит все записи"
        fi
    fi
else
    step "Записи в /etc/fstab — пропущены (--skip-fstab)"
fi

#------------------------------------------------------------------------------
# Шаг: исходники
#------------------------------------------------------------------------------
if (( DO_SOURCES )); then
    step "Исходники в $LFS/sources"
    run mkdir -p "$LFS/sources"
    run chmod a+wt "$LFS/sources"

    if [[ -z "$SOURCES_FROM" ]]; then
        for cand in "$SCRIPT_DIR/../sources" "$SCRIPT_DIR/sources"; do
            [[ -d "$cand" ]] && { SOURCES_FROM="$(cd "$cand" && pwd)"; break; }
        done
    fi

    have_tarballs=0
    if [[ -d "$LFS/sources" ]] && compgen -G "$LFS/sources/*.tar.*" >/dev/null 2>&1; then
        have_tarballs=1
    fi

    if (( have_tarballs )); then
        ok "исходники уже лежат в $LFS/sources ($(ls "$LFS"/sources/*.tar.* 2>/dev/null | wc -l) архивов)"
    elif [[ -n "$SOURCES_FROM" && -d "$SOURCES_FROM" ]]; then
        info "копирую из $SOURCES_FROM"
        run cp -a "$SOURCES_FROM/." "$LFS/sources/"
        ok "скопировано: $(ls "$LFS"/sources/*.tar.* 2>/dev/null | wc -l) архивов"
    elif (( ALLOW_DOWNLOAD )); then
        info "скачиваю по wget-list"
        run wget -q -O "$LFS/sources/wget-list-systemd" \
            https://www.linuxfromscratch.org/lfs/view/13.1-systemd/wget-list-systemd
        run wget -q -O "$LFS/sources/md5sums" \
            https://www.linuxfromscratch.org/lfs/view/13.1-systemd/md5sums
        run wget --input-file="$LFS/sources/wget-list-systemd" --continue \
            --directory-prefix="$LFS/sources" --no-verbose
        ok "скачано"
    else
        warn "исходников нет и копировать неоткуда (--sources / --download)"
    fi

    if [[ -f "$LFS/sources/md5sums" ]] && (( ! DRY_RUN )); then
        info "проверка md5…"
        bad="$(cd "$LFS/sources" && LC_ALL=C md5sum -c md5sums 2>/dev/null | grep -v ': OK$' || true)"
        if [[ -z "$bad" ]]; then
            ok "все контрольные суммы совпали ($(wc -l < "$LFS/sources/md5sums") записей)"
        else
            warn "проблемы с архивами:"
            echo "$bad" | sed 's/^/       /'
        fi
    fi

    # Скрипты сборки должны быть ВНУТРИ chroot: /sources/scripts
    step "Скрипты сборки внутрь \$LFS/sources/scripts"
    if [[ -d "$SCRIPT_DIR/scripts" ]]; then
        run mkdir -p "$LFS/sources/scripts"
        if command -v rsync >/dev/null 2>&1; then
            run rsync -a --delete "$SCRIPT_DIR/scripts/" "$LFS/sources/scripts/"
        else
            run rm -rf "$LFS/sources/scripts"
            run mkdir -p "$LFS/sources/scripts"
            run cp -a "$SCRIPT_DIR/scripts/." "$LFS/sources/scripts/"
        fi
        ok "скриптов скопировано: $(ls "$LFS"/sources/scripts/*.sh 2>/dev/null | wc -l)"
    else
        warn "каталог $SCRIPT_DIR/scripts не найден"
    fi
else
    step "Исходники — пропущены (--skip-sources)"
fi

#------------------------------------------------------------------------------
# Шаг: глава 4
#------------------------------------------------------------------------------
if (( DO_CHAPTER4 )); then
    step "Глава 4: структура каталогов и пользователь lfs"
    if [[ ! -x "$SCRIPT_DIR/scripts/phase1-chapter4.sh" && ! -f "$SCRIPT_DIR/scripts/phase1-chapter4.sh" ]]; then
        warn "нет scripts/phase1-chapter4.sh — пропуск"
    elif [[ -f "$LFS/etc/lfs-release" ]]; then
        info "система уже собрана — пропуск"
    elif [[ -L "$LFS/bin" && -d "$LFS/tools" ]]; then
        # Структура уже создана. Повторный запуск главы 4 сделал бы
        # вложенные симлинки вида /usr/bin/bin -> usr/bin.
        info "структура каталогов и пользователь lfs уже готовы — пропуск"
    else
        if run bash "$SCRIPT_DIR/scripts/phase1-chapter4.sh"; then
            (( DRY_RUN )) || ok "глава 4 выполнена"
        else
            warn "глава 4 завершилась с ошибкой — проверьте вывод выше"
        fi
    fi
else
    step "Глава 4 — пропущена (--skip-chapter4)"
fi

#------------------------------------------------------------------------------
# Шаг: окружение оркестратора
#------------------------------------------------------------------------------
step "Окружение оркестратора"
cd "$SCRIPT_DIR" || die "не удалось перейти в $SCRIPT_DIR"

if [[ ! -x ".venv/bin/python" ]]; then
    if (( DRY_RUN )); then
        info "dry-run: создал бы venv и поставил зависимости"
    else
        info "создаю venv…"
        if ! python3 -m venv .venv 2>/tmp/venv.err; then
            err "не удалось создать venv:"
            sed 's/^/       /' /tmp/venv.err
            die "установите: apt install python3-venv"
        fi
        ok "venv создан"
    fi
else
    info "venv уже есть"
fi

# Проверяем не наличие файла pip, а работоспособность окружения: venv мог
# остаться недоделанным (каталог есть, pip и site-packages пустые) — тогда
# проверка «-x .venv/bin/pip» молча пропускала установку зависимостей, и
# оркестратор падал на «No module named uvicorn».
VENV_IMPORTS="import fastapi, uvicorn, pydantic_settings, yaml, typer, aiosqlite"
venv_ready() { [[ -x .venv/bin/python ]] && .venv/bin/python -c "$VENV_IMPORTS" >/dev/null 2>&1; }

if (( DRY_RUN )); then
    :
elif venv_ready; then
    ok "зависимости на месте"
else
    if [[ -d .venv ]]; then
        info "venv неполный — пересоздаю"
        rm -rf .venv
        python3 -m venv .venv 2>/tmp/venv.err || {
            err "не удалось создать venv:"
            sed 's/^/       /' /tmp/venv.err
            die "установите: apt install python3-venv"
        }
        ok "venv создан"
    fi

    if [[ ! -x .venv/bin/pip ]]; then
        info "pip отсутствует — ставлю через ensurepip"
        if ! .venv/bin/python -m ensurepip --upgrade >/tmp/venv.err 2>&1; then
            err "ensurepip не сработал:"
            sed 's/^/       /' /tmp/venv.err
            die "установите: apt install python3-venv"
        fi
    fi

    info "ставлю зависимости…"
    .venv/bin/pip install -q --upgrade pip >/dev/null 2>&1 || true
    if ! .venv/bin/pip install -q -r requirements.txt >/tmp/pip.log 2>&1; then
        err "pip install не удался:"
        tail -15 /tmp/pip.log | sed 's/^/       /'
        die "проверьте requirements.txt"
    fi
    if venv_ready; then
        ok "зависимости установлены"
    else
        err "модули не импортируются после установки:"
        .venv/bin/python -c "$VENV_IMPORTS" 2>&1 | tail -5 | sed 's/^/       /'
        die "проверьте requirements.txt"
    fi
fi

# .env — только если его нет (не перезаписываем настройки пользователя)
step "Файл настроек .env"
if [[ -f .env ]]; then
    info ".env уже существует — не трогаю"
    info "исполнитель из .env: $EXECUTOR"
    # .env от старых версий скрипта содержал ORCH_*/MAX_PARALLEL — такие имена
    # pydantic игнорирует, и настройки молча брались по умолчанию.
    if grep -qE '^(ORCH_|MAX_PARALLEL=|RUN_TESTS=|STOP_ON_ERROR=|LFS=)' .env 2>/dev/null; then
        warn ".env содержит переменные без префикса LFS_ — они игнорируются"
        warn "правильные имена: LFS_ROOT, LFS_DB_PATH, LFS_LOGS_DIR, LFS_MAX_PARALLEL (см. .env.example)"
    fi
else
    if (( DRY_RUN )); then
        info "dry-run: .env не создаётся"
    else
        cat > .env <<EOF
# Сгенерировано prepare-and-run.sh $(date '+%Y-%m-%d %H:%M:%S')
# ВАЖНО: pydantic читает настройки с префиксом LFS_ (env_prefix="LFS_"),
# поэтому нужны LFS_ROOT, LFS_DB_PATH, LFS_MAX_PARALLEL и т.д.
# Голые имена (DB_PATH=, MAX_PARALLEL=) молча игнорируются.
LFS_ROOT=$LFS
LFS_SOURCES=$LFS/sources
LFS_TGT=$LFS_TGT
LFS_EXECUTOR=$EXECUTOR
LFS_ORCH_HOST=0.0.0.0
LFS_ORCH_PORT=$PORT
LFS_ORCH_LOG_LEVEL=INFO
LFS_DB_PATH=$SCRIPT_DIR/data/orchestrator.db
LFS_LOGS_DIR=$SCRIPT_DIR/logs
LFS_MAX_PARALLEL=1
LFS_RUN_TESTS=false
LFS_STOP_ON_ERROR=true
EOF
        ok ".env создан (исполнитель: $EXECUTOR)"
    fi
fi

#------------------------------------------------------------------------------
# Шаг: проверка исполнителя
#------------------------------------------------------------------------------
step "Проверка исполнителя: $EXECUTOR"
case "$EXECUTOR" in
    docker)
        if ! command -v docker >/dev/null 2>&1; then
            warn "docker не установлен, а в .env LFS_EXECUTOR=docker"
            warn "либо установите docker, либо укажите --executor chroot (или local)"
        elif ! docker info >/dev/null 2>&1; then
            warn "docker установлен, но демон недоступен (systemctl start docker)"
        else
            ok "docker доступен: $(docker --version 2>/dev/null | head -1)"
        fi
        ;;
    chroot)
        ok "chroot: задачи пойдут внутри $LFS"
        info "годится для глав 7B–11; главы 5–6 собираются НА ХОСТЕ от пользователя lfs"
        info "для них запускайте отдельно с --executor local"
        ;;
    local)
        ok "local: задачи выполняются на хосте в каталоге оркестратора"
        info "годится для глав 2–6; главы 7B–11 требуют chroot"
        ;;
    ssh)
        warn "исполнитель ssh требует настроенного доступа к целевому хосту"
        ;;
    *)
        die "неизвестный исполнитель: $EXECUTOR (допустимо: local, chroot, docker, ssh)"
        ;;
esac

#------------------------------------------------------------------------------
# Шаг: запуск
#------------------------------------------------------------------------------
if (( DO_RUN )); then
    step "Запуск оркестратора"
    mkdir -p logs run

    pidfile="run/orchestrator.pid"
    if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
        old="$(cat "$pidfile")"
        info "оркестратор уже запущен (PID $old) — перезапускаю"
        kill "$old" 2>/dev/null || true
        sleep 2
    fi

    if (( DRY_RUN )); then
        info "dry-run: uvicorn lfs_orchestrator.api:app --port $PORT"
    else
        logfile="logs/orchestrator-ui.log"
        echo "=== запуск $(date '+%Y-%m-%d %H:%M:%S') ===" >> "$logfile"
        ORCH_SRC="$SCRIPT_DIR/src"
        ORCH_SOURCES="$LFS/sources"
        PYTHONPATH="$ORCH_SRC" \
        LFS="$LFS" LFS_SOURCES="$ORCH_SOURCES" LFS_TGT="$LFS_TGT" \
        LFS_EXECUTOR="$EXECUTOR" \
        nohup .venv/bin/python -m uvicorn lfs_orchestrator.api:app \
            --host 0.0.0.0 --port "$PORT" >> "$logfile" 2>&1 &
        echo $! > "$pidfile"

        # ждём до 20 секунд
        ready=0
        for _ in $(seq 1 20); do
            sleep 1
            if http_ok "http://127.0.0.1:$PORT/"; then
                ready=1
                break
            fi
            if ! kill -0 "$(cat "$pidfile")" 2>/dev/null; then
                break
            fi
        done

        if (( ready )); then
            ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
            ok "оркестратор отвечает"
            echo
            echo "   ${C_BOLD}Веб-интерфейс:${C_OFF} http://${ip:-127.0.0.1}:$PORT/"
            echo "   ${C_BOLD}Локально:${C_OFF}     http://127.0.0.1:$PORT/"
            echo "   ${C_BOLD}Лог:${C_OFF}          $SCRIPT_DIR/$logfile"
            echo "   ${C_BOLD}PID:${C_OFF}          $(cat "$pidfile")"
            echo
            echo "   Остановить:  kill \$(cat $SCRIPT_DIR/$pidfile)"
        else
            err "оркестратор не отвечает — последние строки лога:"
            tail -25 "$logfile" 2>/dev/null | sed 's/^/       /'
            warn "частые причины: занят порт $PORT, ошибка импорта, не найден .env"
        fi
    fi
else
    step "Запуск оркестратора — пропущен (--no-run)"
fi

#------------------------------------------------------------------------------
# Итог
#------------------------------------------------------------------------------
step "Итог"
echo "   LFS:        $LFS"
findmnt -n -o TARGET,SOURCE,FSTYPE "$LFS"           2>/dev/null | sed 's/^/   /'
findmnt -n -o TARGET,SOURCE,FSTYPE "$LFS/boot"      2>/dev/null | sed 's/^/   /'
findmnt -n -o TARGET,SOURCE,FSTYPE "$LFS/boot/efi"  2>/dev/null | sed 's/^/   /'
echo "   Исходники:  $(ls "$LFS"/sources/*.tar.* 2>/dev/null | wc -l) архивов"
echo "   Скрипты:    $(ls "$LFS"/sources/scripts/*.sh 2>/dev/null | wc -l) файлов в \$LFS/sources/scripts"
echo "   Пользователь lfs: $(getent passwd lfs >/dev/null && echo есть || echo нет)"
echo "   Исполнитель: $EXECUTOR"
echo
echo "   Дальше: соберите главы через веб-интерфейс или CLI:"
echo "     cd $SCRIPT_DIR"
echo "     PYTHONPATH=src .venv/bin/python -m lfs_orchestrator run -p phase5 --max-parallel 1"
echo
