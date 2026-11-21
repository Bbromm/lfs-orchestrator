#!/bin/bash
###############################################################################
# install-phase12.sh — что делается ПОСЛЕ базовой системы LFS
#
# Запускается внутри chroot от root. Все параметры берёт из
# /.lfs-state/settings.json, который пишет веб-интерфейс оркестратора
# (там же, где пользователь их и задаёт).
#
# Что умеет (каждый пункт включается галочкой в интерфейсе):
#   WANT_SUDO   — собрать sudo из исходников (если его нет)
#   WANT_PAM    — Linux-PAM (НЕ автоматизировано, см. предупреждение)
#   WANT_NIX    — Nix (однопользовательский режим); для него собирается curl
#   WANT_SSH    — OpenSSH: сервер, ключи, юнит
#   WANT_XFCE   — XFCE из nixpkgs (без Nix не ставится)
#
# Пользователь (имя, пароль, группы) создаётся всегда, если задан.
#
# Использование:
#   bash install-phase12.sh              # всё, что включено в настройках
#   bash install-phase12.sh --only user  # только пользователь
###############################################################################
set -uo pipefail

SETTINGS="${LFS_SETTINGS:-/.lfs-state/settings.json}"
SOURCES="${SOURCES:-/sources}"
ONLY=""

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()     { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
ok()      { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
section() { echo; echo "==================================================================="; echo "  $*"; echo "==================================================================="; echo; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --only) ONLY="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
        *) die "неизвестный аргумент: $1" ;;
    esac
done

should_run() { [[ -z "$ONLY" || "$ONLY" == "$1" ]]; }

# ─── Чтение настроек ────────────────────────────────────────────────────────
read_settings() {
    [[ -f "$SETTINGS" ]] || { warn "нет $SETTINGS — работаю с умолчаниями"; return 0; }
    command -v python3 >/dev/null 2>&1 || { warn "нет python3 — не могу прочитать настройки"; return 0; }

    local out
    out="$(python3 - "$SETTINGS" <<'PY'
import json, shlex, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
u = d.get("user") or {}
e = d.get("extras") or {}
def q(v):
    return shlex.quote(str(v if v is not None else ""))
print(f"SET_USER={q(u.get('name',''))}")
print(f"SET_PASS={q(u.get('password',''))}")
print(f"SET_GROUPS={q(u.get('groups',''))}")
for k in ("sudo","pam","nix","ssh","xfce"):
    print(f"SET_{k.upper()}={1 if e.get(k) else 0}")
PY
)" || { warn "не удалось разобрать $SETTINGS"; return 0; }
    eval "$out"
}

SET_USER=""; SET_PASS=""; SET_GROUPS=""
SET_SUDO=0; SET_PAM=0; SET_NIX=0; SET_SSH=0; SET_XFCE=0
read_settings

want() { [[ "${1:-0}" == "1" ]]; }

# ─── 12.1 Пользователь ──────────────────────────────────────────────────────
create_user() {
    section "12.1 Пользователь"

    if [[ -z "$SET_USER" ]]; then
        warn "имя пользователя не задано в настройках — пропуск"
        return 0
    fi

    local groups_csv="$SET_GROUPS"
    local -a existing=()
    local g
    IFS=',' read -ra glist <<< "$groups_csv"
    for g in "${glist[@]}"; do
        g="$(echo "$g" | tr -d ' ')"
        [[ -z "$g" ]] && continue
        if getent group "$g" >/dev/null 2>&1; then
            existing+=("$g")
        else
            groupadd "$g" 2>/dev/null && existing+=("$g") || warn "группа '$g' не создана"
        fi
    done

    if getent passwd "$SET_USER" >/dev/null 2>&1; then
        ok "пользователь '$SET_USER' уже есть"
        if [[ ${#existing[@]} -gt 0 ]]; then
            usermod -aG "$(IFS=,; echo "${existing[*]}")" "$SET_USER" && \
                ok "группы обновлены: ${existing[*]}"
        fi
    else
        local args=(-m -s /bin/bash -c "$SET_USER")
        [[ ${#existing[@]} -gt 0 ]] && args+=(-G "$(IFS=,; echo "${existing[*]}")")
        useradd "${args[@]}" "$SET_USER" || die "не удалось создать пользователя"
        ok "пользователь '$SET_USER' создан (домашний каталог /home/$SET_USER)"
    fi

    if [[ -n "$SET_PASS" ]]; then
        printf '%s:%s\n' "$SET_USER" "$SET_PASS" | chpasswd || die "не удалось задать пароль"
        ok "пароль задан"
    else
        warn "пароль не задан — войти можно только через su от root"
    fi

    local uid
    uid="$(id -u "$SET_USER" 2>/dev/null)"
    id "$SET_USER" 2>/dev/null | sed 's/^/     /'
    [[ -n "$uid" ]] && ok "UID=$uid"
}

# ─── 12.2 sudo ──────────────────────────────────────────────────────────────
install_sudo() {
    section "12.2 sudo"

    if command -v sudo >/dev/null 2>&1; then
        ok "sudo уже установлен: $(sudo --version 2>/dev/null | head -1)"
        return 0
    fi

    local tarball
    tarball="$(find "$SOURCES" -maxdepth 1 -name 'sudo-*.tar.*' 2>/dev/null | head -1)"
    if [[ -z "$tarball" ]]; then
        warn "нет архива sudo-*.tar.* в $SOURCES"
        warn "скачайте sudo с https://www.sudo.ws/dist/ и положите в $SOURCES, затем повторите"
        return 1
    fi

    local dir
    dir="$(basename "$tarball" | sed -E 's/\.tar\.(gz|xz|bz2)$//')"
    cd "$SOURCES" || return 1
    rm -rf "$dir"
    tar -xf "$tarball" || { warn "не удалось распаковать $tarball"; return 1; }
    cd "$dir" || return 1

    # OpenSSL 4 сделал ASN1_OCTET_STRING непрозрачным: hostcheck.c читает
    # поле ->length напрямую и не собирается. Переводим на аксессор.
    if [[ -f lib/iolog/hostcheck.c ]] &&
       grep -q 'd\.iPAddress->length' lib/iolog/hostcheck.c; then
        sed -i 's/current_name->d\.iPAddress->length/ASN1_STRING_length(current_name->d.iPAddress)/g' \
            lib/iolog/hostcheck.c
        log "hostcheck.c: доступ к ASN1_OCTET_STRING через ASN1_STRING_length() (OpenSSL 4)"
    fi

    ./configure --prefix=/usr \
        --libexecdir=/usr/lib \
        --with-secure-path \
        --with-all-insults \
        --with-env-editor \
        --docdir="/usr/share/doc/sudo-${dir#sudo-}" \
        --with-passprompt="[sudo] пароль для %p: " \
        2>&1 | tee /tmp/sudo-configure.log | tail -3
    [[ ${PIPESTATUS[0]} -eq 0 ]] || { warn "configure sudo не удался — см. /tmp/sudo-configure.log"; return 1; }

    make -j"$(nproc)" 2>&1 | tee /tmp/sudo-make.log | tail -3
    [[ ${PIPESTATUS[0]} -eq 0 ]] || { warn "make sudo не удался — см. /tmp/sudo-make.log"; return 1; }

    make install 2>&1 | tail -3

    mkdir -p /etc/sudoers.d
    # `make install` кладёт заводской шаблон sudoers, где строка %wheel
    # закомментирована. Поэтому правило даём отдельным файлом и не трогаем шаблон.
    local wheel_rule="/etc/sudoers.d/10-wheel"
    if [[ ! -f "$wheel_rule" ]]; then
        printf '%%wheel ALL=(ALL:ALL) ALL\n' > "$wheel_rule"
        chmod 440 "$wheel_rule"
        ok "правило для группы wheel добавлено: $wheel_rule"
    else
        ok "правило для группы wheel уже есть"
    fi
    if ! grep -q '^@includedir /etc/sudoers.d' /etc/sudoers 2>/dev/null; then
        printf '@includedir /etc/sudoers.d\n' >> /etc/sudoers
        ok "в /etc/sudoers добавлен @includedir /etc/sudoers.d"
    fi
    ok "sudo установлен"

    cd "$SOURCES" && rm -rf "$dir"
}

# ─── 12.3 PAM ───────────────────────────────────────────────────────────────
install_pam() {
    section "12.3 Linux-PAM"

    warn "Linux-PAM ставится вручную — автоматизация опасна."
    cat <<'EOF'

     Порядок (по книге BLFS):
       1. собрать Linux-PAM
       2. пересобрать systemd с  -D pamconfdir=/etc/pam.d
       3. пересобрать shadow, util-linux, openssh с поддержкой PAM
       4. проверить вход: login, su, sshd

     Если пересобрать systemd неправильно, система перестанет пускать
     в консоль. Поэтому шаг оставлен ручным и НЕ выполняется автоматически.

     Флаг в настройках сохранён, чтобы вы не забыли, что PAM выбран.

EOF
    ok "шаг пропущен намеренно (см. текст выше)"
}

# ─── 12.4 curl ──────────────────────────────────────────────────────────────
# Нужен установщику Nix: в базовом LFS нет ни curl, ни wget, и nix-install.sh
# без них отказывается работать. Собирается против openssl 4 из главы 8.
install_curl() {
    section "12.4 curl"

    if command -v curl >/dev/null 2>&1; then
        ok "curl уже установлен: $(curl --version 2>/dev/null | head -1)"
        return 0
    fi

    # Корневые сертификаты нужны уже при проверке HTTPS ниже.
    if [[ ! -f /etc/ssl/certs/ca-certificates.crt && -f "$SOURCES/ca-certificates.crt" ]]; then
        install -v -Dm644 "$SOURCES/ca-certificates.crt" /etc/ssl/certs/ca-certificates.crt
        ok "корневые сертификаты скопированы из $SOURCES"
    fi

    local tarball
    tarball="$(find "$SOURCES" -maxdepth 1 -name 'curl-*.tar.*' 2>/dev/null | head -1)"
    if [[ -z "$tarball" ]]; then
        warn "нет архива curl-*.tar.* в $SOURCES"
        warn "запустите на хосте:  sudo bash fetch-extras.sh"
        return 1
    fi

    local dir
    dir="$(basename "$tarball" | sed -E 's/\.tar\.(gz|xz|bz2)$//')"
    cd "$SOURCES" || return 1
    rm -rf "$dir"
    tar -xf "$tarball" || { warn "не удалось распаковать $tarball"; return 1; }
    cd "$dir" || return 1

    ./configure --prefix=/usr \
        --sysconfdir=/etc \
        --with-openssl \
        --with-ca-bundle=/etc/ssl/certs/ca-certificates.crt \
        --without-libpsl \
        --without-libidn2 \
        --disable-ldap \
        2>&1 | tee /tmp/curl-configure.log | tail -3
    if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
        warn "configure curl не удался — см. /tmp/curl-configure.log"
        tail -8 /tmp/curl-configure.log 2>/dev/null | sed 's/^/     /'
        return 1
    fi

    make -j"$(nproc)" 2>&1 | tee /tmp/curl-make.log | tail -3
    [[ ${PIPESTATUS[0]} -eq 0 ]] || { warn "make curl не удался — см. /tmp/curl-make.log"; return 1; }

    make install 2>&1 | tail -2
    make install-doc >/dev/null 2>&1 || true

    if command -v curl >/dev/null 2>&1; then
        ok "curl установлен: $(curl --version 2>/dev/null | head -1)"
        # проверяем, что HTTPS реально работает с нашими корневыми сертификатами
        if curl -fsS --max-time 20 -o /dev/null https://nixos.org/ 2>/dev/null; then
            ok "HTTPS проверен: nixos.org доступен"
        else
            warn "curl не смог открыть https://nixos.org — проверьте сеть и /etc/ssl/certs"
        fi
    else
        warn "curl не появился в PATH после установки"
        return 1
    fi

    cd "$SOURCES" && rm -rf "$dir"
}

# ─── 12.5 Nix ───────────────────────────────────────────────────────────────
# Профиль Nix должен подхватываться при входе. В LFS /etc/profile не обходит
# /etc/profile.d, поэтому подключаем файл профиля явно.
write_nix_profile() {
    mkdir -p /etc/profile.d /etc/nix
    cat > /etc/profile.d/nix.sh <<'EOF'
# Nix (однопользовательский режим) — добавлено фазой 12 LFS-оркестратора
if [ -e /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
    . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
fi
export NIX_SSL_CERT_FILE="${NIX_SSL_CERT_FILE:-/etc/ssl/certs/ca-certificates.crt}"
export PATH="/nix/var/nix/profiles/default/bin:$PATH"
EOF
    chmod 644 /etc/profile.d/nix.sh
    ok "/etc/profile.d/nix.sh записан"

    if ! grep -q 'profile.d/nix.sh' /etc/profile 2>/dev/null; then
        cat >> /etc/profile <<'EOF'

# Nix — подключение профиля (добавлено фазой 12 LFS-оркестратора)
if [ -r /etc/profile.d/nix.sh ]; then
    . /etc/profile.d/nix.sh
fi
EOF
        ok "профиль Nix подключён к /etc/profile"
    fi

    # Nix здесь однопользовательский (установлен под root), поэтому писать в
    # /nix может только root и любая работа с nix идёт через sudo. В штатном
    # /etc/sudoers есть Defaults secure_path без /nix, из-за чего «sudo nix»
    # падает с «nix: command not found». Drop-in добавляет каталог в PATH.
    mkdir -p /etc/sudoers.d
    cat > /etc/sudoers.d/30-nix <<'EOF'
# Nix установлен в single-user режиме под root, поэтому все операции с ним
# идут через sudo. Без этого каталога в secure_path sudo не находит nix
# и печатает "nix: command not found".
Defaults secure_path="/nix/var/nix/profiles/default/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
EOF
    chmod 440 /etc/sudoers.d/30-nix
    if command -v visudo >/dev/null 2>&1 && ! visudo -cf /etc/sudoers.d/30-nix >/dev/null 2>&1; then
        rm -f /etc/sudoers.d/30-nix
        warn "/etc/sudoers.d/30-nix не прошёл проверку — удалён"
    else
        ok "sudo видит nix (secure_path)"
    fi
}

install_nix() {
    section "12.5 Nix"

    export PATH="/nix/var/nix/profiles/default/bin:/usr/local/bin:/usr/bin:/bin"
    export NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
    write_nix_profile

    if command -v nix >/dev/null 2>&1; then
        ok "Nix уже установлен: $(nix --version 2>/dev/null)"
        return 0
    fi

    # Nix качает store по HTTPS — ему нужен набор корневых сертификатов.
    if [[ ! -f /etc/ssl/certs/ca-certificates.crt && -f "$SOURCES/ca-certificates.crt" ]]; then
        install -v -Dm644 "$SOURCES/ca-certificates.crt" /etc/ssl/certs/ca-certificates.crt
        ok "корневые сертификаты скопированы из $SOURCES"
    fi

    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        warn "установщику Nix нужен curl или wget — в системе нет ни того, ни другого"
        warn "сначала должен выполниться шаг 12.4 (curl)"
        return 1
    fi

    local installer=""
    if [[ -f "$SOURCES/nix-install.sh" ]]; then
        installer="$SOURCES/nix-install.sh"
        ok "использую заранее скачанный $installer"
    elif command -v curl >/dev/null 2>&1; then
        log "скачиваю установщик Nix (curl)…"
        curl -fsSL https://nixos.org/nix/install -o /tmp/nix-install.sh 2>/dev/null \
            && installer=/tmp/nix-install.sh
    fi

    if [[ -z "$installer" ]]; then
        warn "не удалось получить установщик Nix"
        warn "запустите на хосте:  sudo bash fetch-extras.sh"
        return 1
    fi

    log "устанавливаю Nix (однопользовательский режим)…"
    # Nix 2.36 в однопользовательском режиме всё равно берёт build-users-group
    # из умолчаний и требует несуществующую группу nixbld, а сборку пытается
    # вести в песочнице через user namespaces — в chroot их нет. Оба умолчания
    # перекрываем до установки, иначе install падает.
    mkdir -p /etc/nix
    if [[ ! -f /etc/nix/nix.conf ]]; then
        cat > /etc/nix/nix.conf <<'EOF'
build-users-group =
sandbox = false
experimental-features = nix-command flakes
EOF
        ok "создан /etc/nix/nix.conf (без build-users-group и песочницы)"
    fi

    if sh "$installer" --no-daemon --yes >/tmp/nix-install.log 2>&1; then
        ok "Nix установлен"
        mkdir -p /etc/nix
        grep -E "^experimental-features" /etc/nix/nix.conf >/dev/null 2>&1 || {
            printf 'experimental-features = nix-command flakes\n' >> /etc/nix/nix.conf
        }
        ok "включены nix-command и flakes"

        write_nix_profile
        ok "проверка: $(nix --version 2>&1)"
    else
        warn "установка Nix не удалась — см. /tmp/nix-install.log"
        tail -8 /tmp/nix-install.log 2>/dev/null | sed 's/^/     /'
        return 1
    fi
    rm -f /tmp/nix-install.sh
}

# ─── 12.6 OpenSSH ───────────────────────────────────────────────────────────
install_ssh() {
    section "12.6 OpenSSH"

    if command -v sshd >/dev/null 2>&1; then
        ok "sshd уже установлен"
        return 0
    fi

    local tarball
    tarball="$(find "$SOURCES" -maxdepth 1 -name 'openssh-*.tar.*' 2>/dev/null | head -1)"
    if [[ -z "$tarball" ]]; then
        warn "нет архива openssh-*.tar.* в $SOURCES"
        warn "положите openssh-9.x.tar.gz в $SOURCES и повторите"
        return 1
    fi

    local dir
    dir="$(basename "$tarball" | sed -E 's/\.tar\.(gz|xz|bz2)$//')"
    cd "$SOURCES" || return 1
    rm -rf "$dir"
    tar -xf "$tarball" || return 1
    cd "$dir" || return 1

    install -v -g sys -m700 -d /var/lib/sshd
    groupadd -g 50 sshd 2>/dev/null || true
    useradd -c 'sshd PrivSep' -d /var/lib/sshd -g sshd \
            -s /bin/false -u 50 sshd 2>/dev/null || true

    ./configure --prefix=/usr \
        --sysconfdir=/etc/ssh \
        --with-privsep-path=/var/lib/sshd \
        --with-default-path=/usr/bin \
        --with-superuser-path=/usr/sbin:/usr/bin \
        --with-pid-dir=/run \
        2>&1 | tee /tmp/ssh-configure.log | tail -3
    [[ ${PIPESTATUS[0]} -eq 0 ]] || { warn "configure openssh не удался"; return 1; }

    make -j"$(nproc)" 2>&1 | tee /tmp/ssh-make.log | tail -3
    [[ ${PIPESTATUS[0]} -eq 0 ]] || { warn "make openssh не удался"; return 1; }

    make install 2>&1 | tail -2
    install -v -m755 -d /etc/ssh
    install -v -m700 -d /var/lib/sshd

    # sshd нужен отдельный непривилегированный пользователь для privsep,
    # иначе он падает с «Privilege separation user sshd does not exist».
    if ! getent group sshd >/dev/null 2>&1; then
        groupadd -g 50 sshd && ok "группа sshd создана"
    fi
    if ! getent passwd sshd >/dev/null 2>&1; then
        useradd -c 'sshd PrivSep' -d /var/lib/sshd -g sshd -s /bin/false -u 50 sshd \
            && ok "пользователь sshd создан"
    fi
    # Каталог privsep обязан принадлежать root (не sshd!) и быть 700,
    # иначе sshd пишет «must be owned by root and not group or world-writable».
    chown root:root /var/lib/sshd
    chmod 700 /var/lib/sshd

    ssh-keygen -A >/dev/null 2>&1 && ok "ключи сервера созданы"

    # UsePAM допустим только если sshd собран с PAM: в базовом LFS PAM нет,
    # и sshd ругается «Unsupported option UsePAM» на каждую строку конфига.
    local pam_line=""
    if ldd /usr/sbin/sshd 2>/dev/null | grep -q 'libpam'; then
        pam_line="UsePAM yes"
    fi

    cat > /etc/ssh/sshd_config <<EOF
Port 22
PermitRootLogin no
PasswordAuthentication yes
PermitEmptyPasswords no
${pam_line}
Subsystem sftp /usr/libexec/sftp-server
EOF

    cat > /etc/systemd/system/sshd.service <<'EOF'
[Unit]
Description=OpenSSH server
After=network.target

[Service]
ExecStart=/usr/sbin/sshd -D
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    systemctl enable sshd.service >/dev/null 2>&1 && ok "юнит sshd включён"
    ok "sshd установлен (порт 22, вход root запрещён)"

    cd "$SOURCES" && rm -rf "$dir"
}

# ─── 12.7 XFCE ──────────────────────────────────────────────────────────────
install_xfce() {
    section "12.7 Графическая оболочка XFCE"

    if ! command -v nix >/dev/null 2>&1; then
        warn "XFCE ставится через Nix, но Nix не установлен — пропуск"
        return 1
    fi

    export PATH="/nix/var/nix/profiles/default/bin:$PATH"
    log "ставлю XFCE 4.20 из nixpkgs (может занять 10–20 минут)…"
    if nix profile add nixpkgs#xfce.xfce4-session nixpkgs#xfce.thunar >/tmp/nix-xfce.log 2>&1; then
        ok "XFCE установлен в профиль Nix"
        cat <<'EOF'

     Дальше нужен графический вход. Варианты:
       · lightdm + xfce4-session через Nix
       · либо старт вручную из консоли:  xfce4-session

     Для графики также нужны Xorg-драйверы и шрифты — проще всего
     поставить их тем же Nix-профилем.

EOF
    else
        warn "установка XFCE не удалась — см. /tmp/nix-xfce.log"
        tail -5 /tmp/nix-xfce.log 2>/dev/null | sed 's/^/     /'
        return 1
    fi
}

# ─── Запуск ─────────────────────────────────────────────────────────────────
echo "###### LFS фаза 12 — начало: $(date) ######"
echo "Настройки: $SETTINGS"
echo "  пользователь: ${SET_USER:-<не задан>}"
echo "  sudo=$(want $SET_SUDO) pam=$(want $SET_PAM) nix=$(want $SET_NIX) ssh=$(want $SET_SSH) xfce=$(want $SET_XFCE)"
echo

RC=0
run_step() {   # run_step <имя> <команда...>
    local name="$1"; shift
    if ! "$@"; then
        warn "шаг '$name' завершился с ошибкой"
        RC=1
    fi
}

should_run user && run_step user       create_user
should_run sudo && want $SET_SUDO && run_step sudo install_sudo
should_run pam  && want $SET_PAM  && install_pam
# curl нужен установщику Nix — собираем его до 12.5, если Nix вообще выбран
should_run curl && want $SET_NIX  && run_step curl install_curl
should_run nix  && want $SET_NIX  && run_step nix  install_nix
should_run ssh  && want $SET_SSH  && run_step ssh  install_ssh
should_run xfce && want $SET_XFCE && run_step xfce install_xfce

echo
if [[ $RC -eq 0 ]]; then
    echo "###### LFS фаза 12 — завершена: $(date) ######"
else
    echo "###### LFS фаза 12 — завершена С ОШИБКАМИ: $(date) ######"
fi
exit $RC
