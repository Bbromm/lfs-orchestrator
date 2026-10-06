#!/bin/bash
###############################################################################
# phase6-chapter10.sh — Глава 10: Ядро + GRUB
# ЗАПУСКАЕТСЯ ВНУТРИ CHROOT
###############################################################################
set -euo pipefail

log()  { echo -e "\033[0;34m[$(date +%H:%M:%S)]\033[0m $*"; }
ok()   { echo -e "\033[0;32m[OK]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
die()  { echo -e "\033[0;31m[ERROR]\033[0m $*" >&2; exit 1; }

LFS_VERSION="${LFS_VERSION:-13.1-systemd}"
KERNEL_VERSION="7.1.8"
KERNEL_CONFIG_METHOD="${KERNEL_CONFIG_METHOD:-menuconfig}"
KERNEL_JOBS="${KERNEL_JOBS:-$(nproc)}"
USE_UEFI="${USE_UEFI:-yes}"

cd /sources

#------------------------------------------------------------------------------
# 10.2 /etc/fstab
#------------------------------------------------------------------------------
log "Создание /etc/fstab..."
if [[ ! -f /etc/fstab.generated ]]; then
    cat > /etc/fstab << "EOF"
# Begin /etc/fstab
# file system  mount-point  type     options             dump  fsck
#                                                              order
/dev/sda5      /            ext4     defaults            1     1
/dev/sda4      swap         swap     pri=1               0     0
proc           /proc        proc     nosuid,noexec,nodev 0     0
sysfs          /sys         sysfs    nosuid,noexec,nodev 0     0
devpts         /dev/pts     devpts   gid=5,mode=620      0     0
tmpfs          /run         tmpfs    defaults            0     0
devtmpfs       /dev         devtmpfs mode=0755,nosuid    0     0
EOF
    touch /etc/fstab.generated
    ok "/etc/fstab создан (ПРОВЕРЬТЕ ИМЕНА РАЗДЕЛОВ!)"
fi

#------------------------------------------------------------------------------
# 10.3 Ядро Linux
#------------------------------------------------------------------------------
log "Сборка ядра Linux $KERNEL_VERSION..."

# Извлечение
rm -rf "linux-$KERNEL_VERSION"
tar -xf "linux-$KERNEL_VERSION.tar.xz"
cd "linux-$KERNEL_VERSION"

# Конфигурация
case "$KERNEL_CONFIG_METHOD" in
    defconfig)
        log "Использование defconfig + обязательные опции книги..."
        make defconfig

        # Применяем обязательные опции (упрощённо)
        ./scripts/config --enable DEVTMPFS
        ./scripts/config --enable DEVTMPFS_MOUNT
        ./scripts/config --enable TMPFS
        ./scripts/config --enable TMPFS_POSIX_ACL
        ./scripts/config --enable INOTIFY_USER
        ./scripts/config --enable PSI
        ./scripts/config --enable CGROUPS
        ./scripts/config --enable MEMCG
        ./scripts/config --enable RELOCATABLE
        ./scripts/config --enable RANDOMIZE_BASE
        ./scripts/config --enable STACKPROTECTOR
        ./scripts/config --enable STACKPROTECTOR_STRONG
        ./scripts/config --enable INET
        ./scripts/config --enable IPV6
        ./scripts/config --enable TTY
        ./scripts/config --enable DRM
        ./scripts/config --enable DRM_FBDEV_EMULATION
        ./scripts/config --enable DRM_SIMPLEDRM
        ./scripts/config --enable FRAMEBUFFER_CONSOLE
        ./scripts/config --enable BLK_DEV_NVME
        ./scripts/config --disable LEGACY_TIOCSTI
        ./scripts/config --disable UEVENT_HELPER

        if [[ "$USE_UEFI" == "yes" ]]; then
            ./scripts/config --enable EFI
            ./scripts/config --enable EFI_STUB
            ./scripts/config --enable VFAT_FS
            ./scripts/config --enable EFIVAR_FS
            ./scripts/config --enable NLS_CODEPAGE_437
            ./scripts/config --enable NLS_ISO8859_1
        fi

        # x86_64: x2APIC, MSI, IOMMU
        if [[ "$(uname -m)" == "x86_64" ]]; then
            ./scripts/config --enable X86_X2APIC
            ./scripts/config --enable PCI_MSI
            ./scripts/config --enable IOMMU_SUPPORT
            ./scripts/config --enable IRQ_REMAP
        fi

        make olddefconfig
        ;;
    menuconfig)
        log "Интерактивная настройка ядра (make menuconfig)..."
        make menuconfig </dev/tty >/dev/tty
        ;;
    custom)
        if [[ -f /lfs-defconfig ]]; then
            cp /lfs-defconfig .config
            make olddefconfig
            ok "Использован /lfs-defconfig"
        else
            die "KERNEL_CONFIG_METHOD=custom, но /lfs-defconfig не найден"
        fi
        ;;
    *)
        die "Неизвестный KERNEL_CONFIG_METHOD=$KERNEL_CONFIG_METHOD"
        ;;
esac

# Компиляция
log "Компиляция ядра (make -j$KERNEL_JOBS)..."
make -j"$KERNEL_JOBS"

log "Установка модулей..."
make modules_install

# Копирование в /boot
log "Копирование образа ядра в /boot..."
cp -iv arch/x86/boot/bzImage "/boot/vmlinuz-$KERNEL_VERSION-lfs-$LFS_VERSION"
cp -iv System.map /boot/System.map-$KERNEL_VERSION
cp -iv .config /boot/config-$KERNEL_VERSION

# Документация
cp -r Documentation -T /usr/share/doc/linux-$KERNEL_VERSION

# Права
chown -R 0:0 .

cd /sources
ok "Ядро установлено"

#------------------------------------------------------------------------------
# 10.4 GRUB
#------------------------------------------------------------------------------
log "Настройка GRUB..."

if [[ "$USE_UEFI" == "yes" ]]; then
    # UEFI
    mountpoint -q /boot/efi || mount -v /boot/efi 2>/dev/null || true
    grub-install --target=x86_64-efi --removable --boot-directory=/boot --efi-directory=/boot/efi
else
    # BIOS
    grub-install "$DISK" --target=i386-pc --boot-directory=/boot
fi

# Конфигурация GRUB
cat > /boot/grub/grub.cfg << EOF
# Begin /boot/grub/grub.cfg
set default=0
set timeout=5

insmod part_gpt
insmod ext2

set root=(hd0,5)
set gfxpayload=1024x768x32

menuentry "GNU/Linux, Linux $KERNEL_VERSION-lfs-$LFS_VERSION" {
    linux   /boot/vmlinuz-$KERNEL_VERSION-lfs-$LFS_VERSION root=/dev/sda5 ro
}
EOF

ok "GRUB настроен"
ok "Глава 10 завершена — система готова к загрузке"