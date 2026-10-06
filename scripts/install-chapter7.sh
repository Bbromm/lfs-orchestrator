#!/bin/bash
###############################################################################
# LFS 13.1-systemd — Глава 7: Chroot и временные инструменты
# Скрипт состоит из двух фаз:
#   Фаза A (вне chroot, root): разделы 7.2–7.4, вход в chroot
#   Фаза B (внутри chroot, root): разделы 7.5–7.14
#
# Использование:
#   1) От root: bash install-chapter7.sh --phase-a
#   2) (Скрипт сам выполнит chroot и вызовет фазу B внутри)
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

extract() { cd "$SOURCES"; rm -rf "$2"; tar -xf "$1"; cd "$2"; }
cleanup() { cd "$SOURCES"; rm -rf "$1"; ok "Очищен $1"; }

# ============================================================
# ФАЗА A: Подготовка и вход в chroot (от root вне chroot)
# ============================================================
phase_a() {
    section "Фаза A — Подготовка chroot"
    [[ "$(id -u)" == "0" ]] || die "Фаза A должна запускаться от root"
    [[ -n "${LFS:-}" ]] || die "\$LFS не установлена"

    # 7.2 Changing Ownership
    log "7.2 Смена владельца..."
    chown --from lfs -R root:root "$LFS"/{usr,var,etc,tools}
    case "$(uname -m)" in
        x86_64) chown --from lfs -R root:root "$LFS/lib64" ;;
    esac
    ok "Владелец изменён на root"

    # 7.3 Preparing Virtual Kernel File Systems
    log "7.3 Создание каталогов для виртуальных ФС..."
    mkdir -pv "$LFS"/{dev,proc,sys,run}

    log "7.3.1 Bind-mount /dev..."
    mount -v --bind /dev "$LFS/dev"

    log "7.3.2 Монтирование виртуальных ФС..."
    mount -vt devpts devpts -o gid=5,mode=0620 "$LFS/dev/pts"
    mount -vt proc proc "$LFS/proc"
    mount -vt sysfs sysfs "$LFS/sys"
    mount -vt tmpfs tmpfs "$LFS/run"

    if [ -h "$LFS/dev/shm" ]; then
        install -v -d -m 1777 "$LFS$(realpath /dev/shm)"
    else
        mount -vt tmpfs -o nosuid,nodev tmpfs "$LFS/dev/shm"
    fi
    ok "Виртуальные ФС смонтированы"

    # 7.4 Entering Chroot
    section "Фаза A — Вход в chroot и запуск фазы B"
    log "Копирование фазы B в chroot..."
    cp -v "$0" "$LFS/install-chapter7-phaseB.sh"
    chmod +x "$LFS/install-chapter7-phaseB.sh"

    log "Вход в chroot и выполнение фазы B..."
    chroot "$LFS" /usr/bin/env -i \
        HOME=/root \
        TERM="$TERM" \
        PS1='(lfs chroot) \u:\w\$ ' \
        PATH=/usr/bin:/usr/sbin \
        MAKEFLAGS="-j$(nproc)" \
        TESTSUITEFLAGS="-j$(nproc)" \
        LFS="$LFS" \
        LFS_TGT="$LFS_TGT" \
        /bin/bash --login -c "bash /install-chapter7-phaseB.sh"

    ok "Фаза A завершена. Chroot-сессия закрыта."
}

# ============================================================
# ФАЗА B: Внутри chroot (от root)
# ============================================================
phase_b() {
    section "Фаза B — Установка временных инструментов (внутри chroot)"

    [[ "$(id -u)" == "0" ]] || die "Фаза B должна запускаться от root"
    [[ -d /usr/bin ]] || die "Не в chroot-среде (нет /usr/bin)"

    # 7.5 Creating Directories
    log "7.5 Создание каталогов..."
    mkdir -pv /{boot,home,mnt,opt,srv}
    mkdir -pv /etc/{opt,sysconfig}
    mkdir -pv /lib/firmware
    mkdir -pv /media/{floppy,cdrom}
    mkdir -pv /usr/{,local/}{include,src}
    mkdir -pv /usr/lib/locale
    mkdir -pv /usr/local/{bin,lib,sbin}
    mkdir -pv /usr/{,local/}share/{color,dict,doc,info,locale,man}
    mkdir -pv /usr/{,local/}share/{misc,terminfo,zoneinfo}
    mkdir -pv /usr/{,local/}share/man/man{1..8}
    mkdir -pv /var/{cache,local,log,mail,opt,spool}
    mkdir -pv /var/lib/{color,misc,locate}
    ln -sfv /run /var/run
    ln -sfv /run/lock /var/lock
    install -dv -m 0750 /root
    install -dv -m 1777 /tmp /var/tmp
    ok "Каталоги созданы"

    # 7.6 Creating Essential Files and Symlinks
    log "7.6 Создание основных файлов и симлинков..."
    ln -sv /proc/self/mounts /etc/mtab

    cat > /etc/hosts << EOF
127.0.0.1  localhost $(hostname)
::1        localhost
EOF

    cat > /etc/passwd << "EOF"
root:x:0:0:root:/root:/bin/bash
bin:x:1:1:bin:/dev/null:/usr/bin/false
daemon:x:6:6:Daemon User:/dev/null:/usr/bin/false
messagebus:x:18:18:D-Bus Message Daemon User:/run/dbus:/usr/bin/false
systemd-journal-gateway:x:73:73:systemd Journal Gateway:/:/usr/bin/false
systemd-journal-remote:x:74:74:systemd Journal Remote:/:/usr/bin/false
systemd-journal-upload:x:75:75:systemd Journal Upload:/:/usr/bin/false
systemd-network:x:76:76:systemd Network Management:/:/usr/bin/false
systemd-resolve:x:77:77:systemd Resolver:/:/usr/bin/false
systemd-timesync:x:78:78:systemd Time Synchronization:/:/usr/bin/false
systemd-coredump:x:79:79:systemd Core Dumper:/:/usr/bin/false
uuidd:x:80:80:UUID Generation Daemon User:/dev/null:/usr/bin/false
systemd-oom:x:81:81:systemd Out Of Memory Daemon:/:/usr/bin/false
nobody:x:65534:65534:Unprivileged User:/dev/null:/usr/bin/false
EOF

    cat > /etc/group << "EOF"
root:x:0:
bin:x:1:daemon
sys:x:2:
kmem:x:3:
tape:x:4:
tty:x:5:
daemon:x:6:
floppy:x:7:
disk:x:8:
lp:x:9:
dialout:x:10:
audio:x:11:
video:x:12:
utmp:x:13:
clock:x:14:
cdrom:x:15:
adm:x:16:
messagebus:x:18:
systemd-journal:x:23:
input:x:24:
mail:x:34:
kvm:x:61:
systemd-journal-gateway:x:73:
systemd-journal-remote:x:74:
systemd-journal-upload:x:75:
systemd-network:x:76:
systemd-resolve:x:77:
systemd-timesync:x:78:
systemd-coredump:x:79:
uuidd:x:80:
systemd-oom:x:81:
wheel:x:97:
users:x:999:
nogroup:x:65534:
EOF

    echo "tester:x:101:101::/home/tester:/bin/bash" >> /etc/passwd
    echo "tester:x:101:" >> /etc/group
    install -o tester -d /home/tester

    exec /usr/bin/bash --login << 'EOSH'
touch /var/log/{btmp,lastlog,faillog,wtmp}
chgrp -v utmp /var/log/lastlog
chmod -v 664  /var/log/lastlog
chmod -v 600  /var/log/btmp
EOSH
    ok "Основные файлы созданы"

    # 7.7 Gettext-1.0
    section "7.7 Gettext-1.0"
    extract "gettext-1.0.tar.xz" "gettext-1.0"
    ./configure --disable-shared
    make
    cp -v gettext-tools/src/{msgfmt,msgmerge,xgettext} /usr/bin
    ok "Gettext установлен"
    cleanup "gettext-1.0"

    # 7.8 Bison-3.8.2
    section "7.8 Bison-3.8.2"
    extract "bison-3.8.2.tar.xz" "bison-3.8.2"
    ./configure --prefix=/usr --docdir=/usr/share/doc/bison-3.8.2
    make
    make install
    ok "Bison установлен"
    cleanup "bison-3.8.2"

    # 7.9 Perl-5.44.0
    section "7.9 Perl-5.44.0"
    extract "perl-5.44.0.tar.xz" "perl-5.44.0"
    sh Configure -des \
        -D prefix=/usr \
        -D vendorprefix=/usr \
        -D useshrplib \
        -D privlib=/usr/lib/perl5/5.44/core_perl \
        -D archlib=/usr/lib/perl5/5.44/core_perl \
        -D sitelib=/usr/lib/perl5/5.44/site_perl \
        -D sitearch=/usr/lib/perl5/5.44/site_perl \
        -D vendorlib=/usr/lib/perl5/5.44/vendor_perl \
        -D vendorarch=/usr/lib/perl5/5.44/vendor_perl
    make
    make install
    ok "Perl установлен"
    cleanup "perl-5.44.0"

    # 7.10 Zlib-1.3.2
    section "7.10 Zlib-1.3.2"
    extract "zlib-1.3.2.tar.gz" "zlib-1.3.2"
    ./configure --prefix=/usr
    make
    make install
    rm -fv /usr/lib/libz.a
    ok "Zlib установлен"
    cleanup "zlib-1.3.2"

    # 7.11 mpdecimal-4.0.1
    section "7.11 mpdecimal-4.0.1"
    extract "mpdecimal-4.0.1.tar.gz" "mpdecimal-4.0.1"
    ./configure --prefix=/usr --disable-static --docdir=/usr/share/doc/mpdecimal-4.0.1
    make
    make install
    ok "mpdecimal установлен"
    cleanup "mpdecimal-4.0.1"

    # 7.12 Python-3.14.7
    section "7.12 Python-3.14.7"
    extract "Python-3.14.7.tar.xz" "Python-3.14.7"
    ./configure --prefix=/usr --enable-shared --without-ensurepip --without-static-libpython
    make
    make install
    ok "Python установлен"
    cleanup "Python-3.14.7"

    # 7.13 Texinfo-7.3
    section "7.13 Texinfo-7.3"
    extract "texinfo-7.3.tar.xz" "texinfo-7.3"
    ./configure --prefix=/usr
    make
    make install
    ok "Texinfo установлен"
    cleanup "texinfo-7.3"

    # 7.14 Util-linux-2.42.2
    section "7.14 Util-linux-2.42.2"
    extract "util-linux-2.42.2.tar.xz" "util-linux-2.42.2"
    mkdir -pv /var/lib/hwclock
    ./configure --libdir=/usr/lib \
                --runstatedir=/run \
                --disable-chfn-chsh \
                --disable-login \
                --disable-nologin \
                --disable-su \
                --disable-setpriv \
                --disable-runuser \
                --disable-pylibmount \
                --disable-static \
                --disable-liblastlog2 \
                --without-python \
                ADJTIME_PATH=/var/lib/hwclock/adjtime \
                --docdir=/usr/share/doc/util-linux-2.42.2
    make
    make install
    ok "Util-linux установлен"
    cleanup "util-linux-2.42.2"

    section "Глава 7 завершена"
    ok "Все временные инструменты установлены"
}

# ============================================================
# Точка входа
# ============================================================
case "${1:-}" in
    --phase-a) phase_a ;;
    --phase-b) phase_b ;;
    *) die "Использование: bash install-chapter7.sh --phase-a  (от root вне chroot)" ;;
esac

exit 0