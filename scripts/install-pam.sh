#!/bin/bash
###############################################################################
# install-pam.sh — Linux-PAM и пересборка systemd с поддержкой PAM
#
# ЗАПУСКАТЬ ОТДЕЛЬНО И ОСОЗНАННО: шаг пересобирает systemd. Если сборка или
# конфиги PAM окажутся неверными, система перестанет пускать в консоль.
#
# Что делает (по книге BLFS):
#   1. собирает и ставит Linux-PAM;
#   2. раскладывает /etc/pam.d/*;
#   3. пересобирает systemd с -Dpamconfdir=/etc/pam.d;
#   4. пересобирает shadow с --with-libpam;
#   5. пересобирает OpenSSH с --with-pam и включает UsePAM;
#   6. проверяет, что sshd и systemd линкуются с libpam.
#
# Перед изменениями делает резервную копию рабочих бинарников в /root/pam-backup.
# Откат:  bash install-pam.sh --rollback
#
# Использование:
#   bash install-pam.sh            # только показывает план, ничего не меняет
#   bash install-pam.sh --yes      # выполнить
#   bash install-pam.sh --rollback # вернуть бинарники из резервной копии
###############################################################################
set -uo pipefail

SOURCES="${SOURCES:-/sources}"
BACKUP=/root/pam-backup
DO_IT=0
ROLLBACK=0
ONLY=""

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()     { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
ok()      { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
section() { echo; echo "==================================================================="; echo "  $*"; echo "==================================================================="; echo; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes|-y)  DO_IT=1; shift ;;
        --rollback) ROLLBACK=1; shift ;;
        --only)    ONLY="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
        *) die "неизвестный аргумент: $1" ;;
    esac
done

should_run() { [[ -z "$ONLY" || "$ONLY" == "$1" ]]; }

# ─── Откат ──────────────────────────────────────────────────────────────────
do_rollback() {
    section "Откат PAM"
    [[ -d "$BACKUP" ]] || die "нет резервной копии в $BACKUP"
    local f rel
    while IFS= read -r rel; do
        f="$BACKUP/${rel#/}"
        if [[ -f "$f" ]]; then
            install -Dm"$(stat -c %a "$f")" "$f" "/$rel"
            ok "восстановлен /$rel"
        fi
    done < <(cd "$BACKUP" && find . -type f | sed 's|^\./||' | sed 's|^|/|')
    ok "бинарники возвращены. Перезагрузитесь и проверьте вход."
    exit 0
}

(( ROLLBACK )) && do_rollback

# ─── План ───────────────────────────────────────────────────────────────────
if (( ! DO_IT )); then
    cat <<'EOF'

  Этот скрипт пересоберёт systemd с поддержкой PAM. Это НЕ безопасный шаг:
  при ошибке система не пустит в консоль. Запускайте только осознанно.

  Что будет сделано:
    1. Linux-PAM      -> сборка и установка в /usr
    2. /etc/pam.d/*   -> минимальный рабочий набор конфигов
    3. systemd        -> пересборка с -Dpamconfdir=/etc/pam.d
    4. shadow         -> пересборка с --with-libpam
    5. OpenSSH        -> пересборка с --with-pam, UsePAM yes
    6. проверка       -> ldd /usr/lib/systemd/systemd и /usr/sbin/sshd

  Перед шагом 3 рабочие бинарники копируются в /root/pam-backup,
  откат: bash install-pam.sh --rollback

  Запуск: bash install-pam.sh --yes

EOF
    exit 0
fi

[[ $EUID -eq 0 ]] || die "нужен root (запускайте в chroot)"

# ─── 0. Резервная копия ─────────────────────────────────────────────────────
backup_bins() {
    section "0. Резервная копия"
    mkdir -p "$BACKUP"
    local f
    for f in /usr/lib/systemd/systemd /usr/sbin/sshd /usr/bin/passwd \
             /usr/bin/su /usr/bin/login /usr/bin/sudo; do
        [[ -f "$f" ]] || continue
        install -Dm"$(stat -c %a "$f")" "$f" "$BACKUP$f"
        ok "сохранён $f"
    done
}

# ─── 1. Linux-PAM ───────────────────────────────────────────────────────────
build_pam() {
    section "1. Linux-PAM"

    if [[ -f /usr/lib/libpam.so.0 || -f /usr/lib/libpam.so ]]; then
        ok "libpam уже установлена"
        return 0
    fi

    local tarball dir
    tarball="$(find "$SOURCES" -maxdepth 1 -iname 'linux-pam-*.tar.*' | head -1)"
    [[ -n "$tarball" ]] || {
        warn "нет архива linux-pam-*.tar.* в $SOURCES"
        warn "на хосте: sudo bash fetch-extras.sh   (или скачайте с linux-pam.org)"
        return 1
    }

    dir="$(basename "$tarball" | sed -E 's/\.tar\.(gz|xz|bz2)$//')"
    cd "$SOURCES" || return 1
    rm -rf "$dir"; tar -xf "$tarball" || return 1
    cd "$dir" || return 1

    # С версии 1.7 Linux-PAM собирается только Meson (autotools убран).
    meson setup build \
        --prefix=/usr \
        --libdir=/usr/lib \
        --sysconfdir=/etc \
        --buildtype=release \
        -D docs=disabled \
        -D examples=false \
        -D audit=disabled \
        -D selinux=disabled \
        -D nis=disabled \
        -D econf=disabled \
        -D pam_lastlog=disabled \
        2>&1 | tee /tmp/pam-configure.log | tail -5
    [[ ${PIPESTATUS[0]} -eq 0 ]] || { warn "meson setup Linux-PAM не удался — см. /tmp/pam-configure.log"; return 1; }

    ninja -C build 2>&1 | tee /tmp/pam-make.log | tail -3
    [[ ${PIPESTATUS[0]} -eq 0 ]] || { warn "сборка Linux-PAM не удалась — см. /tmp/pam-make.log"; return 1; }

    ninja -C build install 2>&1 | tail -3
    ok "Linux-PAM установлена"

    # systemd ставит pam_systemd.so в /usr/lib/security
    if [[ -f /usr/lib/security/pam_systemd.so ]]; then
        ok "pam_systemd.so на месте"
    else
        warn "pam_systemd.so появится только после пересборки systemd"
    fi

    mkdir -p /etc/pam.d
    cd "$SOURCES" && rm -rf "$dir"
}

# ─── 2. Конфиги /etc/pam.d ──────────────────────────────────────────────────
write_pam_configs() {
    section "2. Конфиги /etc/pam.d"

    mkdir -p /etc/pam.d

    cat > /etc/pam.d/system-auth <<'EOF'
# Begin /etc/pam.d/system-auth
auth      required   pam_env.so
auth      required   pam_unix.so try_first_pass nullok
account   required   pam_unix.so
password  required   pam_unix.so sha512 shadow nullok
session   required   pam_limits.so
session   required   pam_unix.so
session   optional   pam_systemd.so
# End /etc/pam.d/system-auth
EOF

    cat > /etc/pam.d/other <<'EOF'
# Begin /etc/pam.d/other
auth      required   pam_deny.so
account   required   pam_deny.so
password  required   pam_deny.so
session   required   pam_deny.so
# End /etc/pam.d/other
EOF

    cat > /etc/pam.d/login <<'EOF'
# Begin /etc/pam.d/login
auth      requisite  pam_nologin.so
auth      include    system-auth
account   include    system-auth
password  include    system-auth
session   include    system-auth
# End /etc/pam.d/login
EOF

    cat > /etc/pam.d/su <<'EOF'
# Begin /etc/pam.d/su
auth      sufficient pam_rootok.so
auth      include    system-auth
account   include    system-auth
session   include    system-auth
# End /etc/pam.d/su
EOF

    cat > /etc/pam.d/passwd <<'EOF'
# Begin /etc/pam.d/passwd
password  include    system-auth
# End /etc/pam.d/passwd
EOF

    cat > /etc/pam.d/sshd <<'EOF'
# Begin /etc/pam.d/sshd
auth      required   pam_nologin.so
auth      include    system-auth
account   include    system-auth
password  include    system-auth
session   required   pam_loginuid.so
session   required   pam_motd.so
session   include    system-auth
# End /etc/pam.d/sshd
EOF

    cat > /etc/pam.d/systemd-user <<'EOF'
# Begin /etc/pam.d/systemd-user
account   include    system-auth
session   required   pam_limits.so
session   required   pam_unix.so
session   required   pam_loginuid.so
# End /etc/pam.d/systemd-user
EOF

    # shadow ставит свои login/su/passwd с упоминанием pam_selinux.so и
    # pam_console.so. В LFS PAM собран без SELinux, а pam_console устарел,
    # поэтому на каждый вход в журнал сыпалось «PAM unable to dlopen».
    # Комментируем ссылки на модули, которых нет в системе.
    local mod file
    for mod in pam_selinux.so pam_console.so; do
        [[ -f "/usr/lib/security/$mod" ]] && continue
        for file in /etc/pam.d/*; do
            [[ -f "$file" ]] || continue
            sed -i "/$mod/s/^\([^#]\)/# \1/" "$file"
        done
    done

    ok "создано 8 файлов в /etc/pam.d"
}

# ─── 3. Пересборка systemd ──────────────────────────────────────────────────
rebuild_systemd() {
    section "3. Пересборка systemd"

    local tarball dir ver
    tarball="$(find "$SOURCES" -maxdepth 1 -name 'systemd-[0-9]*.tar.*' | head -1)"
    [[ -n "$tarball" ]] || { warn "нет архива systemd-*.tar.* в $SOURCES"; return 1; }

    dir="$(basename "$tarball" | sed -E 's/\.tar\.(gz|xz|bz2)$//')"
    ver="${dir#systemd-}"

    cd "$SOURCES" || return 1
    rm -rf "$dir"; tar -xf "$tarball" || return 1
    cd "$dir" || return 1

    # Те же правки правил udev, что и в главе 8.
    sed -e 's/GROUP="render"/GROUP="video"/' -e 's/GROUP="sgx", //' \
        -i rules.d/50-udev-default.rules.in

    # Флаги повторяют главу 8 один в один, изменён только pamconfdir.
    mkdir -p build && cd build || return 1
    meson setup .. --prefix=/usr --libdir=/usr/lib --buildtype=release \
        -D default-dnssec=no -D firstboot=false -D install-tests=false \
        -D ldconfig=false -D sysusers=false -D rpmmacrosdir=no \
        -D homed=disabled -D man=disabled -D mode=release -D pamconfdir=/etc/pam.d \
        -D dev-kvm-mode=0660 -D nobody-group=nogroup \
        -D sysupdate=disabled -D ukify=disabled \
        -D docdir="/usr/share/doc/systemd-$ver" \
        2>&1 | tee /tmp/systemd-pam-setup.log | tail -5
    [[ ${PIPESTATUS[0]} -eq 0 ]] || { warn "meson setup systemd не удался — см. /tmp/systemd-pam-setup.log"; return 1; }

    ninja 2>&1 | tee /tmp/systemd-pam-build.log | tail -3
    [[ ${PIPESTATUS[0]} -eq 0 ]] || { warn "ninja systemd не удался — см. /tmp/systemd-pam-build.log"; return 1; }

    ninja install 2>&1 | tail -3

    if [[ -f "$SOURCES/systemd-man-pages-$ver.tar.xz" ]]; then
        tar -xf "$SOURCES/systemd-man-pages-$ver.tar.xz" \
            --no-same-owner --strip-components=1 -C /usr/share/man
    fi
    ok "systemd $ver пересобран с pamconfdir=/etc/pam.d"

    cd "$SOURCES" && rm -rf "$dir"
}

# ─── 4. shadow с libpam ─────────────────────────────────────────────────────
rebuild_shadow() {
    section "4. Пересборка shadow"

    local tarball dir
    tarball="$(find "$SOURCES" -maxdepth 1 -name 'shadow-*.tar.*' | head -1)"
    [[ -n "$tarball" ]] || { warn "нет архива shadow-*.tar.* в $SOURCES"; return 1; }

    dir="$(basename "$tarball" | sed -E 's/\.tar\.(gz|xz|bz2)$//')"
    cd "$SOURCES" || return 1
    rm -rf "$dir"; tar -xf "$tarball" || return 1
    cd "$dir" || return 1

    # Подготовка та же, что в главе 8.
    find man -name Makefile.in -exec sed -i 's/getspnam\.3 / /' {} \;
    find man -name Makefile.in -exec sed -i 's/passwd\.5 / /' {} \;
    sed -e 's:#ENCRYPT_METHOD SHA512:ENCRYPT_METHOD YESCRYPT:' \
        -e 's:/var/spool/mail:/var/mail:' \
        -e '/PATH=/{s@/sbin:@@;s@/bin:@@}' \
        -i etc/login.defs
    touch /usr/bin/passwd

    # К флагам главы 8 добавлен только --with-libpam.
    ./configure --sysconfdir=/etc --disable-static --with-libpam --with-bcrypt \
        --with-yescrypt --without-libbsd --disable-logind \
        --with-group-name-max-length=32 \
        2>&1 | tee /tmp/shadow-configure.log | tail -3
    [[ ${PIPESTATUS[0]} -eq 0 ]] || { warn "configure shadow не удался"; return 1; }

    make 2>&1 | tee /tmp/shadow-make.log | tail -3
    [[ ${PIPESTATUS[0]} -eq 0 ]] || { warn "make shadow не удался"; return 1; }

    make exec_prefix=/usr install 2>&1 | tail -2
    make -C man install-man 2>&1 | tail -2 || true
    pwconv 2>/dev/null || true
    grpconv 2>/dev/null || true
    ok "shadow пересобран с --with-libpam"

    cd "$SOURCES" && rm -rf "$dir"
}

# ─── 5. OpenSSH с PAM ───────────────────────────────────────────────────────
rebuild_openssh() {
    section "5. Пересборка OpenSSH с PAM"

    local tarball dir
    tarball="$(find "$SOURCES" -maxdepth 1 -name 'openssh-*.tar.*' | head -1)"
    [[ -n "$tarball" ]] || { warn "нет архива openssh-*.tar.* в $SOURCES"; return 1; }

    dir="$(basename "$tarball" | sed -E 's/\.tar\.(gz|xz|bz2)$//')"
    cd "$SOURCES" || return 1
    rm -rf "$dir"; tar -xf "$tarball" || return 1
    cd "$dir" || return 1

    ./configure --prefix=/usr \
        --sysconfdir=/etc/ssh \
        --with-privsep-path=/var/lib/sshd \
        --with-default-path=/usr/bin \
        --with-superuser-path=/usr/sbin:/usr/bin \
        --with-pid-dir=/run \
        --with-pam \
        2>&1 | tee /tmp/ssh-pam-configure.log | tail -3
    [[ ${PIPESTATUS[0]} -eq 0 ]] || { warn "configure OpenSSH с PAM не удался"; return 1; }

    make -j"$(nproc)" 2>&1 | tee /tmp/ssh-pam-make.log | tail -3
    [[ ${PIPESTATUS[0]} -eq 0 ]] || { warn "make OpenSSH не удался"; return 1; }

    make install 2>&1 | tail -2

    if grep -q '^UsePAM' /etc/ssh/sshd_config 2>/dev/null; then
        sed -i 's/^UsePAM.*/UsePAM yes/' /etc/ssh/sshd_config
    else
        sed -i '1i UsePAM yes' /etc/ssh/sshd_config
    fi
    ok "OpenSSH пересобран с --with-pam, в sshd_config стоит UsePAM yes"

    cd "$SOURCES" && rm -rf "$dir"
}

# ─── 5.5 logind ─────────────────────────────────────────────────────────────
# Без systemd-logind нет ни сессий (loginctl), ни кнопок «Выход/Перезагрузка»
# в XFCE: xfce4-session спрашивает разрешения именно у него.
enable_logind() {
    section "5.5 systemd-logind"

    local unit_src=/usr/lib/systemd/system/systemd-logind.service
    if [[ ! -f "$unit_src" ]]; then
        warn "нет $unit_src — logind не включить"
        return 1
    fi

    mkdir -p /etc/systemd/system/multi-user.target.wants

    if [[ ! -e /etc/systemd/system/dbus-org.freedesktop.login1.service ]]; then
        ln -sf "$unit_src" /etc/systemd/system/dbus-org.freedesktop.login1.service
        ok "logind: добавлен алиас D-Bus org.freedesktop.login1"
    else
        ok "logind: алиас D-Bus уже есть"
    fi

    if [[ ! -e /etc/systemd/system/multi-user.target.wants/systemd-logind.service ]]; then
        ln -sf "$unit_src" /etc/systemd/system/multi-user.target.wants/systemd-logind.service
        ok "logind: включён в multi-user.target"
    else
        ok "logind: уже включён"
    fi

    local us=/usr/lib/systemd/system/systemd-user-sessions.service
    if [[ -f "$us" && ! -e /etc/systemd/system/multi-user.target.wants/systemd-user-sessions.service ]]; then
        ln -sf "$us" /etc/systemd/system/multi-user.target.wants/systemd-user-sessions.service
        ok "systemd-user-sessions включён"
    fi
}

# ─── 6. Проверка ────────────────────────────────────────────────────────────
verify_pam() {
    section "6. Проверка"

    local f bad=0
    # Сам PID 1 с libpam не линкуется: PAM живёт в pam_systemd.so и в утилитах
    # shadow/openssh, поэтому проверяем именно их.
    for f in /usr/lib/security/pam_systemd.so /usr/sbin/sshd /usr/bin/passwd /usr/bin/su /usr/bin/login; do
        [[ -f "$f" ]] || { warn "нет $f"; bad=$((bad + 1)); continue; }
        if [[ "$f" == *pam_systemd.so ]] || ldd "$f" 2>/dev/null | grep -q libpam; then
            ok "$f — с PAM"
        else
            warn "$f НЕ линкуется с libpam"
            bad=$((bad + 1))
        fi
    done

    for f in /etc/pam.d/system-auth /etc/pam.d/login /etc/pam.d/sshd /etc/pam.d/systemd-user; do
        [[ -f "$f" ]] && ok "$f на месте" || { warn "нет $f"; bad=$((bad + 1)); }
    done

    if grep -q 'pam_systemd.so' /etc/pam.d/system-auth 2>/dev/null; then
        ok "system-auth регистрирует сессию в logind (pam_systemd)"
    else
        warn "в system-auth нет pam_systemd — loginctl не увидит сессии"
        bad=$((bad + 1))
    fi

    echo
    if (( bad == 0 )); then
        ok "PAM подключён. Перезагрузитесь и проверьте вход в консоль и по SSH."
        ok "Откат при проблемах: bash install-pam.sh --rollback"
    else
        warn "есть проблемы ($bad). Не перезагружайтесь вслепую:"
        warn "  · проверьте /tmp/*-pam-*.log"
        warn "  · откат: bash install-pam.sh --rollback"
    fi
    return 0
}

# ─── Запуск ─────────────────────────────────────────────────────────────────
echo "###### Linux-PAM — начало: $(date) ######"

backup_bins

RC=0
should_run pam     && { build_pam         || RC=1; }
should_run configs && { write_pam_configs; }
should_run systemd && { rebuild_systemd   || RC=1; }
should_run shadow  && { rebuild_shadow    || RC=1; }
should_run openssh && { rebuild_openssh   || RC=1; }
should_run logind  && { enable_logind     || RC=1; }
should_run verify  && verify_pam

echo
if (( RC == 0 )); then
    echo "###### Linux-PAM — завершено: $(date) ######"
else
    echo "###### Linux-PAM — завершено С ОШИБКАМИ: $(date) ######"
    echo "Откат: bash install-pam.sh --rollback"
fi
exit $RC
