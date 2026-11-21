#!/bin/bash
###############################################################################
# phase6-chapter10.sh — LFS 13.1-systemd, Глава 10: Ядро + GRUB
# Запускается ВНУТРИ chroot от root.
#
# Переменные окружения:
#   BOOT_MODE=uefi|bios              — по умолчанию uefi
#   DISK=/dev/sdX (обязателен для bios)
#   FS_ID=label|uuid|device          — способ идентификации разделов (по умолч. label)
#   FS_TAG=LFS                       — префикс меток: LFS_ROOT, LFS_SWAP, LFS_ESP
#   ROOT_PART/SWAP_PART/ESP_PART     — только для FS_ID=device
#   KERNEL_VERSION=7.1.8
#   KERNEL_JOBS=N                    — по умолчанию nproc
#   KERNEL_DEFCONFIG=/sources/lfs-defconfig
#   KERNEL_FORCE_BUILTIN=yes|no      — встраивать критичные драйверы (по умолч. yes)
#   GRUB_TIMEOUT=5
#   GRUB_DEFAULT=0
###############################################################################
set -euo pipefail

# ─── Цвета и логи ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
section() { echo; echo "==================================================================="; echo "  $*"; echo "==================================================================="; echo; }

# ─── Параметры ───────────────────────────────────────────────────────────────
BOOT_MODE="${BOOT_MODE:-uefi}"
DISK="${DISK:-}"
FS_ID="${FS_ID:-label}"
FS_TAG="${FS_TAG:-LFS}"
ROOT_PART="${ROOT_PART:-}"
SWAP_PART="${SWAP_PART:-}"
ESP_PART="${ESP_PART:-}"
KERNEL_VERSION="${KERNEL_VERSION:-7.1.8}"
KERNEL_JOBS="${KERNEL_JOBS:-$(nproc)}"
LFS_VERSION="${LFS_VERSION:-13.1-systemd}"
KERNEL_DEFCONFIG="${KERNEL_DEFCONFIG:-/sources/lfs-defconfig}"
KERNEL_FORCE_BUILTIN="${KERNEL_FORCE_BUILTIN:-yes}"
GRUB_TIMEOUT="${GRUB_TIMEOUT:-5}"
GRUB_DEFAULT="${GRUB_DEFAULT:-0}"

SOURCES="/sources"

# ─── Проверки контекста ──────────────────────────────────────────────────────
check_prereq() {
    section "Проверка предусловий"
    [[ "$(id -u)" == "0" ]] || die "Запускать от root внутри chroot"
    [[ -d /usr/bin      ]] || die "Не в chroot"
    [[ -d "$SOURCES"    ]] || die "Нет каталога $SOURCES"
    [[ -f "$SOURCES/linux-$KERNEL_VERSION.tar.xz" ]] || \
        die "Не найден архив ядра: $SOURCES/linux-$KERNEL_VERSION.tar.xz"

    case "$BOOT_MODE" in
        uefi|bios) ok "BOOT_MODE=$BOOT_MODE" ;;
        *) die "BOOT_MODE должен быть uefi или bios (получено: $BOOT_MODE)" ;;
    esac

    case "$FS_ID" in
        label|uuid|device) ok "FS_ID=$FS_ID" ;;
        *) die "FS_ID должен быть label, uuid или device (получено: $FS_ID)" ;;
    esac

    if [[ "$BOOT_MODE" == "bios" ]]; then
        [[ -n "$DISK" ]] || die "BOOT_MODE=bios требует DISK=/dev/sdX (куда ставить GRUB)"
        [[ -b "$DISK"  ]] || die "Устройство $DISK не найдено"
    fi

    if [[ "$FS_ID" == "device" ]]; then
        [[ -n "$ROOT_PART" ]] || die "FS_ID=device требует ROOT_PART"
        [[ -n "$SWAP_PART" ]] || die "FS_ID=device требует SWAP_PART"
        [[ "$BOOT_MODE" == "uefi" && -z "$ESP_PART" ]] && die "FS_ID=device+uefi требует ESP_PART"
    fi

    ok "Все предусловия выполнены"
}

# ─── 10.2 fstab ──────────────────────────────────────────────────────────────
resolve_id() {
    # $1 = label | uuid ; $2 = значение метки/UUID части
    # Возвращает строку вида LABEL=xxx или UUID=yyy
    case "$1" in
        label)  echo "LABEL=$2" ;;
        uuid)   echo "UUID=$2" ;;
        *)      die "resolve_id: неизвестный тип '$1'" ;;
    esac
}

find_part_by_label() {
    # $1 = метка. Ищем блочное устройство с этой меткой.
    local label="$1"
    blkid -L "$label" 2>/dev/null || true
}

create_fstab() {
    section "10.2 Создание /etc/fstab"

    local root_line swap_line esp_line="" boot_line="" boot_type=""

    case "$FS_ID" in
        label)
            # Проверяем, что метки видны
            local root_dev swap_dev esp_dev
            root_dev="$(find_part_by_label "${FS_TAG}_ROOT")"
            swap_dev="$(find_part_by_label "${FS_TAG}_SWAP")"
            [[ -n "$root_dev" ]] || die "Раздел с меткой ${FS_TAG}_ROOT не найден (blkid -L)"
            [[ -n "$swap_dev" ]] || die "Раздел с меткой ${FS_TAG}_SWAP не найден"

            root_line="$(resolve_id label "${FS_TAG}_ROOT")"
            swap_line="$(resolve_id label "${FS_TAG}_SWAP")"

            if [[ "$BOOT_MODE" == "uefi" ]]; then
                esp_dev="$(find_part_by_label "${FS_TAG}_ESP")"
                [[ -n "$esp_dev" ]] || die "Раздел с меткой ${FS_TAG}_ESP не найден"
                esp_line="$(resolve_id label "${FS_TAG}_ESP")"
            fi
            ok "Найдены разделы: root=$root_dev swap=$swap_dev ${esp_dev:+esp=$esp_dev}"
            ;;
        uuid)
            local root_dev swap_dev esp_dev
            # Если переменные не переданы — пробуем угадать по findmnt
            if [[ -z "$ROOT_PART" ]]; then
                ROOT_PART="$(findmnt -n -o SOURCE / || true)"
                [[ -n "$ROOT_PART" ]] || die "Не удалось определить корневой раздел (передайте ROOT_PART)"
            fi
            [[ -n "$SWAP_PART" ]] || die "FS_ID=uuid требует SWAP_PART=/dev/sdXN"
            [[ "$BOOT_MODE" == "uefi" && -z "$ESP_PART" ]] && die "FS_ID=uuid+uefi требует ESP_PART"

            local ru su eu
            ru="$(blkid -s UUID -o value "$ROOT_PART")"
            su="$(blkid -s UUID -o value "$SWAP_PART")"
            [[ -n "$ru" ]] || die "Не удалось получить UUID для $ROOT_PART"
            [[ -n "$su" ]] || die "Не удалось получить UUID для $SWAP_PART"
            root_line="$(resolve_id uuid "$ru")"
            swap_line="$(resolve_id uuid "$su")"
            if [[ -n "$ESP_PART" ]]; then
                eu="$(blkid -s UUID -o value "$ESP_PART")"
                [[ -n "$eu" ]] || die "Не удалось получить UUID для $ESP_PART"
                esp_line="$(resolve_id uuid "$eu")"
            fi
            ;;
        device)
            root_line="$ROOT_PART"
            swap_line="$SWAP_PART"
            [[ -n "$ESP_PART" ]] && esp_line="$ESP_PART"
            warn "FS_ID=device: fstab будет работать только на этой машине с этой разметкой"
            ;;
    esac

    # Отдельный /boot: без строки в fstab он не смонтируется при загрузке,
    # и обновлять ядро будет некуда.
    if mountpoint -q /boot 2>/dev/null; then
        local boot_dev boot_uuid
        boot_dev="$(findmnt -n -o SOURCE /boot 2>/dev/null)"
        if [[ -n "$boot_dev" ]]; then
            boot_type="$(blkid -s TYPE -o value "$boot_dev" 2>/dev/null)"
            boot_type="${boot_type:-ext2}"
            case "$FS_ID" in
                label)
                    local boot_label
                    boot_label="$(blkid -s LABEL -o value "$boot_dev" 2>/dev/null)"
                    [[ -n "$boot_label" ]] && boot_line="$(resolve_id label "$boot_label")" ;;
                device)
                    boot_line="$boot_dev" ;;
                *)
                    boot_uuid="$(blkid -s UUID -o value "$boot_dev" 2>/dev/null)"
                    boot_line="${boot_uuid:+UUID=$boot_uuid}" ;;
            esac
            boot_line="${boot_line:-$boot_dev}"
            ok "Отдельный /boot: $boot_dev ($boot_type)"
        fi
    fi

    # Собственно fstab
    {
        echo "# Begin /etc/fstab"
        echo "# file system   mount-point   type      options                 dump fsck"
        echo
        printf "%-15s %-13s %-9s %-23s %-4s %s\n" "$root_line" "/"       "ext4"   "defaults"              "1" "1"
        printf "%-15s %-13s %-9s %-23s %-4s %s\n" "$swap_line" "swap"    "swap"   "pri=1"                 "0" "0"
        if [[ -n "$boot_line" ]]; then
            printf "%-15s %-13s %-9s %-23s %-4s %s\n" "$boot_line" "/boot" "$boot_type" "defaults"         "0" "2"
        fi
        if [[ -n "$esp_line" ]]; then
            printf "%-15s %-13s %-9s %-23s %-4s %s\n" "$esp_line" "/boot/efi" "vfat" "umask=0077,shortname=winnt" "0" "2"
        fi
        echo
        printf "%-15s %-13s %-9s %-23s %-4s %s\n" "proc"      "/proc"   "proc"   "nosuid,noexec,nodev" "0" "0"
        printf "%-15s %-13s %-9s %-23s %-4s %s\n" "sysfs"     "/sys"    "sysfs"  "nosuid,noexec,nodev" "0" "0"
        printf "%-15s %-13s %-9s %-23s %-4s %s\n" "devpts"    "/dev/pts" "devpts" "gid=5,mode=620"      "0" "0"
        printf "%-15s %-13s %-9s %-23s %-4s %s\n" "tmpfs"     "/run"    "tmpfs"  "defaults,mode=0755"   "0" "0"
        echo
        echo "# End /etc/fstab"
    } > /etc/fstab

    ok "/etc/fstab создан"
    echo
    echo "─── содержимое /etc/fstab ───"
    cat /etc/fstab
    echo "─────────────────────────────"
}

# ─── 10.3 Ядро ───────────────────────────────────────────────────────────────
build_kernel() {
    section "10.3 Сборка ядра Linux $KERNEL_VERSION"

    cd "$SOURCES"
    rm -rf "linux-$KERNEL_VERSION"
    tar -xf "linux-$KERNEL_VERSION.tar.xz" || die "Не удалось распаковать ядро"
    cd "linux-$KERNEL_VERSION"

    # ─── Базовая конфигурация ───
    if [[ ! -f "$KERNEL_DEFCONFIG" ]]; then
        warn "$KERNEL_DEFCONFIG не найден — используем make defconfig"
        make defconfig
    else
        log "Копирую $KERNEL_DEFCONFIG → .config"
        cp "$KERNEL_DEFCONFIG" .config
    fi

    # ─── Встраивание критичных опций (no-initramfs!) ───
    if [[ "$KERNEL_FORCE_BUILTIN" == "yes" ]]; then
        log "Встраивание критичных драйверов в ядро (built-in, не модули)..."

        # Файловые системы
        for opt in EXT4_FS VFAT_FS ISO9660_FS TMPFS TMPFS_POSIX_ACL DEVTMPFS DEVTMPFS_MOUNT \
                   PROC_FS SYSFS EFIVAR_FS; do
            ./scripts/config --enable "$opt"
        done
        # NLS для ESP
        for opt in NLS_CODEPAGE_437 NLS_ISO8859_1 NLS_UTF8; do
            ./scripts/config --enable "$opt"
        done
        # Разметка дисков
        for opt in EFI_PARTITION MSDOS_PARTITION; do
            ./scripts/config --enable "$opt"
        done
        # Дисковые контроллеры (SATA, NVMe, SCSI)
        for opt in BLK_DEV_SD ATA SATA_AHCI BLK_DEV_NVME SCSI SCSI_DISK_FS \
                   SCSI_LOWLEVEL FUSION FUSION_SPI FUSION_SAS \
                   SCSI_MPT3SAS VMWARE_PVSCSI SCSI_VMW_PVSCSI; do
            ./scripts/config --enable "$opt" 2>/dev/null || true
        done
        # CD/DVD (пригодится, если решите ставить с диска)
        for opt in BLK_DEV_SR ISO9660_FS; do
            ./scripts/config --enable "$opt"
        done
        # USB (клавиатура/мышь/флешки — без initramfs нужны в ядре)
        for opt in USB USB_XHCI_HCD USB_EHCI_HCD USB_OHCI_HCD USB_UHCI_HCD USB_STORAGE \
                   USB_HID HID_GENERIC INPUT_EVDEV INPUT_KEYBOARD INPUT_MOUSE \
                   KEYBOARD_ATKBD MOUSE_PS2 SERIO_I8042 SERIO_LIBPS2; do
            ./scripts/config --enable "$opt"
        done
        # Виртуалки (VirtIO — для тестов в QEMU/KVM)
        for opt in VIRTIO VIRTIO_PCI VIRTIO_BLK VIRTIO_NET VIRTIO_CONSOLE; do
            ./scripts/config --enable "$opt"
        done
        # Сеть. CONFIG_NET — логическая опция, модулем стать не может:
        # «--module NET» даёт недопустимое CONFIG_NET=m, и olddefconfig его
        # выбрасывает — ядро остаётся вообще без сокетов (systemd падает на
        # netlink). NIC тоже держим в ядре: initrd у нас нет.
        for opt in NET UNIX INET INET_DIAG IPV6 PACKET NETDEVICES; do
            ./scripts/config --enable "$opt"
        done
        # Драйвер NIC не включается без «вендорской» опции семейства
        for opt in NET_VENDOR_INTEL NET_VENDOR_REALTEK NET_VENDOR_VMWARE NET_VENDOR_AMD; do
            ./scripts/config --enable "$opt"
        done
        for opt in E1000 E1000E VMXNET3 PCNET32 R8169 IGB VIRTIO_NET; do
            ./scripts/config --enable "$opt" 2>/dev/null || true
        done
        # Графика (framebuffer для консоли)
        for opt in DRM DRM_FBDEV_EMULATION FRAMEBUFFER_CONSOLE FB_EFI DRM_SIMPLEDRM; do
            ./scripts/config --enable "$opt"
        done
        # x86_64 специфика
        if [[ "$(uname -m)" == "x86_64" ]]; then
            for opt in X86_X2APIC PCI_MSI IOMMU_SUPPORT IRQ_REMAP MICROCODE MICROCODE_INTEL MICROCODE_AMD; do
                ./scripts/config --enable "$opt"
            done
        fi
        # Безопасность/системное
        for opt in STACKPROTECTOR STACKPROTECTOR_STRONG RANDOMIZE_BASE RELOCATABLE \
                   INOTIFY_USER PSI CGROUPS MEMCG CGROUP_SCHED CGROUP_FREEZER; do
            ./scripts/config --enable "$opt"
        done
        # Отключаем небезопасное
        for opt in LEGACY_TIOCSTI UEVENT_HELPER; do
            ./scripts/config --disable "$opt"
        done

        # UEFI — обязательно при BOOT_MODE=uefi
        if [[ "$BOOT_MODE" == "uefi" ]]; then
            for opt in EFI EFI_STUB EFI_VARS; do
                ./scripts/config --enable "$opt"
            done
        fi

        # Выравниваем зависимости
        make olddefconfig
        ok "Критичные опции включены как built-in"
    fi

    # ─── Финальная проверка ключевых опций ───
    log "Проверка ключевых опций ядра..."
    local missing=0
    for opt in EXT4_FS VFAT_FS DEVTMPFS DEVTMPFS_MOUNT BLK_DEV_SD BLK_DEV_NVME \
               SATA_AHCI USB_HID USB_XHCI_HCD EFI_PARTITION \
               NET UNIX INET E1000; do
        if ! grep -q "^CONFIG_${opt}=y" .config; then
            warn "CONFIG_${opt} НЕ встроен в ядро (=y отсутствует)"
            missing=$((missing + 1))
        fi
    done
    (( missing == 0 )) || warn "$missing критичных опций отсутствуют — система может не загрузиться!"

    # ─── Сборка ───
    log "Компиляция ядра (make -j$KERNEL_JOBS)..."
    make -j"$KERNEL_JOBS"

    log "Установка модулей..."
    make modules_install

    # ─── Установка в /boot ───
    log "Копирование ядра в /boot..."
    local img_name="vmlinuz-$KERNEL_VERSION-lfs-$LFS_VERSION"
    if [[ -f arch/x86/boot/bzImage ]]; then
        cp -fv arch/x86/boot/bzImage "/boot/$img_name"
    elif [[ -f arch/x86/boot/bzImage ]]; then
        cp -fv vmlinuz "/boot/$img_name"
    else
        die "Не найден образ ядра (bzImage)"
    fi
    cp -fv System.map "/boot/System.map-$KERNEL_VERSION"
    cp -fv .config   "/boot/config-$KERNEL_VERSION"

    # ─── Документация ───
    mkdir -p "/usr/share/doc/linux-$KERNEL_VERSION"
    cp -r Documentation -T "/usr/share/doc/linux-$KERNEL_VERSION" 2>/dev/null || true

    cd "$SOURCES"
    ok "Ядро $KERNEL_VERSION установлено в /boot/$img_name"
}

# ─── 10.4 GRUB ───────────────────────────────────────────────────────────────
install_grub() {
    section "10.4 Установка GRUB"

    if [[ "$BOOT_MODE" == "uefi" ]]; then
        # Проверка, что ESP смонтирован
        if ! mountpoint -q /boot/efi; then
            die "/boot/efi не смонтирован. Смонтируйте ESP и повторите."
        fi
        if ! [[ -d /sys/firmware/efi ]]; then
            warn "/sys/firmware/efi отсутствует — вы в chroot; для установки GRUB нужен доступ к EFI"
        fi
        log "grub-install (UEFI, --removable)..."
        grub-install --target=x86_64-efi \
                     --efi-directory=/boot/efi \
                     --boot-directory=/boot \
                     --bootloader-id=LFS \
                     --removable
        ok "GRUB установлен в UEFI"
    else
        log "grub-install (BIOS, $DISK)..."
        grub-install --target=i386-pc \
                     --boot-directory=/boot \
                     "$DISK"
        ok "GRUB установлен в MBR диска $DISK"
    fi

    # ─── Настройка /etc/default/grub ───
    log "Настройка /etc/default/grub..."
    mkdir -p /etc/default
    cat > /etc/default/grub << EOF
# Begin /etc/default/grub
GRUB_DEFAULT=$GRUB_DEFAULT
GRUB_TIMEOUT=$GRUB_TIMEOUT
GRUB_DISTRIBUTOR="LFS"
GRUB_CMDLINE_LINUX_DEFAULT=""
GRUB_CMDLINE_LINUX=""

# Для BIOS — используем 1024x768 до загрузки драйвера
GRUB_GFXMODE=1024x768
GRUB_GFXPAYLOAD_LINUX=keep

# Отключаем os-prober (мы не ищем другие ОС)
GRUB_DISABLE_OS_PROBER=true

# Тихий режим (уберите, если хотите больше отладочной информации при загрузке)
GRUB_TERMINAL_OUTPUT=console
# End /etc/default/grub
EOF
    ok "/etc/default/grub создан"

    # ─── Генерация grub.cfg ───
    log "Генерация /boot/grub/grub.cfg (grub-mkconfig)..."
    if [[ -f /etc/fstab ]]; then
        # grub-mkconfig умеет строить menuentry автоматически
        grub-mkconfig -o /boot/grub/grub.cfg || \
            die "grub-mkconfig упал. Проверьте /etc/default/grub и /etc/fstab"
    else
        die "/etc/fstab отсутствует — grub-mkconfig не сможет собрать конфиг"
    fi

    # Проверяем, что в grub.cfg действительно есть menuentry
    if ! grep -q "menuentry" /boot/grub/grub.cfg; then
        warn "grub.cfg сгенерирован, но НЕ содержит ни одного menuentry!"
        warn "Проверьте, что ядро лежит в /boot и /etc/fstab корректен."
        warn "Может потребоваться ручное вмешательство в /boot/grub/grub.cfg."
    else
        ok "grub.cfg содержит menuentry — система должна загрузиться"
    fi

    # Ядро 6.10+ без initrd не понимает root=UUID= и root=LABEL=:
    # early_lookup_bdev() принимает только /dev/*, PARTUUID=, PARTLABEL= и
    # major:minor. grub-mkconfig пишет именно UUID=, поэтому переводим
    # командную строку на PARTUUID — он так же стабилен, но ядру понятен.
    local root_uuid root_partuuid
    root_uuid="$(awk '$2 == "/" && $1 ~ /^UUID=/ { sub(/^UUID=/, "", $1); print $1; exit }' /etc/fstab)"
    if [[ -n "$root_uuid" ]]; then
        root_partuuid="$(blkid -t "UUID=$root_uuid" -s PARTUUID -o value 2>/dev/null | head -1)"
        if [[ -n "$root_partuuid" ]]; then
            sed -i "s|root=UUID=$root_uuid|root=PARTUUID=$root_partuuid|g" /boot/grub/grub.cfg
            ok "root= переведён на PARTUUID=$root_partuuid"
        else
            warn "не удалось получить PARTUUID корня — остаётся root=UUID="
            warn "ядро 6.10+ без initrd такую запись не поймёт: нужен initrd или root=/dev/…"
        fi
    fi

    # ─── Превью grub.cfg ───
    echo
    echo "─── /boot/grub/grub.cfg (первые 60 строк) ───"
    head -60 /boot/grub/grub.cfg
    echo "────────────────────────────────────────────"
}

# ─── MAIN ────────────────────────────────────────────────────────────────────
main() {
    echo
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║  LFS $LFS_VERSION — Глава 10: Ядро + GRUB                  ║"
    echo "║  BOOT_MODE=$BOOT_MODE  FS_ID=$FS_ID  DISK=${DISK:-(auto)}  ║"
    echo "║  Начало: $(date)                          ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo

    check_prereq
    create_fstab
    build_kernel
    install_grub

    section "Глава 10 завершена"
    ok "Система готова к загрузке"
    echo
    echo "Проверьте перед перезагрузкой:"
    echo "  • /etc/fstab        — правильные разделы"
    echo "  • /boot/grub/grub.cfg — menuentry с вашим ядром"
    echo "  • /boot/vmlinuz-*    — образ ядра на месте"
    echo "  • пароль root установлен: passwd root"
    echo
    echo "Затем выйдите из chroot, размонтируйте ФС и перезагрузитесь:"
    echo "  exit"
    echo "  sudo umount -R /mnt/lfs"
    echo "  sudo reboot"
    echo
}

main "$@"
