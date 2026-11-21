#!/bin/bash
###############################################################################
# install-phase13-desktop.sh — графический рабочий стол поверх собранной LFS
#
# Ставит через Nix: Xorg, XFCE, шрифты. Из исходников ничего не собирается,
# всё берётся из бинарного кэша nixpkgs.
#
# Запускается в chroot от root, повторный запуск безопасен.
#
# После этого шага в консоли (tty) можно запустить:
#   startx
# и получить рабочий стол XFCE.
#
# Использование:
#   bash install-phase13-desktop.sh                 # все стадии
#   bash install-phase13-desktop.sh --only xorg     # одна стадия
#
# Стадии: xorg, xfce, system, pam, polkit, profile, user, autostart
###############################################################################
set -uo pipefail

SETTINGS="${LFS_SETTINGS:-/.lfs-state/settings.json}"
ONLY=""

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()     { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
ok()      { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
section() { echo; echo "==================================================================="; echo "  $*"; echo "==================================================================="; echo; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --only) ONLY="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
        *) echo "неизвестный аргумент: $1" >&2; exit 2 ;;
    esac
done

should_run() { [[ -z "$ONLY" || "$ONLY" == "$1" ]]; }

NIX_BIN=/nix/var/nix/profiles/default/bin
export PATH="$NIX_BIN:/usr/sbin:/usr/bin:/sbin:/bin"
export NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
export HOME=/root

# ─── Имя пользователя для ~/.xinitrc ────────────────────────────────────────
SET_USER=""
if [[ -f "$SETTINGS" ]] && command -v python3 >/dev/null 2>&1; then
    SET_USER="$(python3 - "$SETTINGS" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
    print((d.get("user") or {}).get("name") or "")
except Exception:
    print("")
PY
)"
fi
[[ -n "$SET_USER" ]] || SET_USER=user

# ─── Установка пакетов из nixpkgs ───────────────────────────────────────────
# Один недоступный атрибут валит весь профиль, поэтому пакеты ставятся
# пачками, а при отказе пачки — по одному, с записью неудачных.
NIX_FAILED=()

nix_install_one() {
    local attr="$1"
    if nix profile install "nixpkgs#$attr" >>/tmp/nix-desktop.log 2>&1; then
        return 0
    fi
    NIX_FAILED+=("$attr")
    return 1
}

nix_install_batch() {
    local title="$1"; shift
    local attrs=("$@")
    log "ставлю $title: ${attrs[*]}"

    local args=()
    for a in "${attrs[@]}"; do args+=("nixpkgs#$a"); done

    if nix profile install "${args[@]}" >>/tmp/nix-desktop.log 2>&1; then
        ok "$title установлен"
        return 0
    fi

    warn "пачка «$title» не встала целиком — пробую по одному"
    local a
    for a in "${attrs[@]}"; do
        nix_install_one "$a" && ok "  $a" || warn "  $a — не удалось"
    done
}

install_xorg() {
    section "13.1 Xorg"

    nix_install_batch "сервер Xorg" \
        xorg.xorgserver xorg.xinit xorg.xauth xorg.xkeyboardconfig xorg.xkbcomp \
        xorg.xf86inputlibinput xorg.xf86inputevdev xorg.xf86inputkeyboard \
        xorg.xrandr xorg.xset xorg.xrdb xorg.xprop xorg.xmodmap \
        xorg.iceauth xorg.setxkbmap

    # Видеодрайвер VMware: при работающем KMS (vmwgfx) X сам берёт modesetting,
    # но DDX vmware не мешает и помогает на старых сборках.
    nix_install_one xorg.xf86videovmware >/dev/null 2>&1 || true
}

install_xfce() {
    section "13.2 XFCE"

    nix_install_batch "XFCE" \
        xfce.xfce4-session xfce.xfwm4 xfce.xfce4-panel xfce.xfdesktop \
        xfce.xfce4-settings xfce.thunar xfce.xfce4-terminal xfce.tumbler \
        xfce.xfce4-appfinder

    nix_install_batch "шрифты" dejavu_fonts liberation_ttf
}

# ─── Интеграция Nix-дерева с системой ───────────────────────────────────────
integrate() {
    section "13.3 Интеграция с системой"

    # Xorg ищет данные раскладок в /usr/share/X11/xkb, а в базовом LFS их нет.
    # В nixpkgs share/X11/xkb — символическая ссылка, поэтому без -type d.
    local xkb_dir locale_dir
    xkb_dir="$(find /nix/store -maxdepth 4 -path '*xkeyboard-config*/share/X11/xkb' 2>/dev/null | head -1)"
    if [[ -n "$xkb_dir" ]]; then
        mkdir -p /usr/share/X11
        ln -sfn "$xkb_dir" /usr/share/X11/xkb
        ok "раскладки: /usr/share/X11/xkb -> $xkb_dir"
    else
        warn "не нашёл xkeyboard-config в /nix/store — раскладка может не загрузиться"
    fi

    locale_dir="$(find /nix/store -maxdepth 4 -path '*xorg-libX11*/share/X11/locale' 2>/dev/null | head -1)"
    if [[ -n "$locale_dir" ]]; then
        mkdir -p /usr/share/X11
        ln -sfn "$locale_dir" /usr/share/X11/locale
        ok "locale: /usr/share/X11/locale -> $locale_dir"
    fi

    # fontconfig в базовом LFS отсутствует, поэтому даём ему готовый конфиг
    # с каталогом шрифтов из профиля Nix. Кешей два: системный (пишется от
    # root, поэтому 1777 — иначе пользователь получает «No writable cache
    # directories») и пользовательский через XDG.
    mkdir -p /etc/fonts /var/cache/fontconfig
    chmod 1777 /var/cache/fontconfig
    if [[ ! -f /etc/fonts/fonts.conf ]] || ! grep -q 'prefix="xdg"' /etc/fonts/fonts.conf; then
        cat > /etc/fonts/fonts.conf <<'EOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <dir>/usr/share/fonts</dir>
  <dir>/nix/var/nix/profiles/default/share/fonts</dir>
  <cachedir>/var/cache/fontconfig</cachedir>
  <cachedir prefix="xdg">fontconfig</cachedir>
</fontconfig>
EOF
        ok "/etc/fonts/fonts.conf записан"
    else
        ok "/etc/fonts/fonts.conf уже настроен"
    fi

    # Xorg должен уметь переключать виртуальные консоли — без setuid он этого
    # не может. Права на файл в /nix/store слетят при garbage collection.
    local xorg_bin
    xorg_bin="$(readlink -f "$(command -v Xorg 2>/dev/null || true)" 2>/dev/null)"
    if [[ -n "$xorg_bin" && -f "$xorg_bin" ]]; then
        chmod u+s "$xorg_bin" && ok "Xorg помечен setuid: $xorg_bin"
    else
        warn "бинарник Xorg не найден — startx не заработает"
    fi

    # Драйверы ввода (libinput/evdev) — отдельные пакеты Nix, и xorg-server
    # собран без встроенного их списка. Без этого конфига Xorg пишет
    # «No input driver specified» и мышь с клавиатурой не работают совсем:
    #  • ModulePath — чтобы драйвер вообще нашёлся (аргумент -modulepath
    #    setuid-сервер не принимает, поэтому только через файл);
    #  • InputClass — чтобы udev-бэкенд попробовал его загрузить.
    local mods dir all_mods keymap kbd_opts
    mods="$(dirname "$xorg_bin")/../lib/xorg/modules"
    all_mods="$mods"
    for dir in /nix/store/*-xf86-input-*/lib/xorg/modules; do
        [[ -d "$dir" ]] && all_mods="$all_mods,$dir"
    done

    # Раскладку берём из настроек формы (system.keymap); в консоли она уже
    # настроена главой 9, а X нужен свой XkbLayout.
    keymap=""
    if [[ -f "$SETTINGS" ]] && command -v python3 >/dev/null 2>&1; then
        keymap="$(python3 - "$SETTINGS" <<'PY'
import json, sys
try:
    print((json.load(open(sys.argv[1], encoding="utf-8")).get("system") or {}).get("keymap") or "")
except Exception:
    print("")
PY
)"
    fi
    kbd_opts=""
    if [[ -n "$keymap" && "$keymap" != "us" ]]; then
        kbd_opts="    Option \"XkbLayout\" \"$keymap,us\"
    Option \"XkbOptions\" \"grp:alt_shift_toggle\""
        ok "раскладка X: $keymap,us (переключение Alt+Shift)"
    else
        kbd_opts='    Option "XkbLayout" "us"'
    fi

    mkdir -p /etc/X11
    cat > /etc/X11/xorg.conf <<EOF
# Создано LFS-оркестратором (фаза 13): драйверы ввода из Nix.
Section "Files"
    ModulePath "$all_mods"
EndSection

Section "InputClass"
    Identifier "Nix libinput pointer"
    MatchIsPointer "on"
    Driver "libinput"
EndSection

Section "InputClass"
    Identifier "Nix libinput keyboard"
    MatchIsKeyboard "on"
    Driver "libinput"
$kbd_opts
EndSection

Section "InputClass"
    Identifier "Nix libinput touchpad"
    MatchIsTouchpad "on"
    Driver "libinput"
EndSection
EOF
    ok "/etc/X11/xorg.conf создан (ModulePath + InputClass)"
}

# ─── Профиль Nix в /etc/profile ─────────────────────────────────────────────
# В LFS /etc/profile не обходит /etc/profile.d, поэтому подключаем явно:
# иначе после входа startx и любые nix-команды просто не находятся.
ensure_nix_profile() {
    section "13.6 Профиль Nix"

    mkdir -p /etc/profile.d
    cat > /etc/profile.d/nix.sh <<'EOF'
# Nix (однопользовательский режим) — добавлено LFS-оркестратором
if [ -e /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
    . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
fi
export NIX_SSL_CERT_FILE="${NIX_SSL_CERT_FILE:-/etc/ssl/certs/ca-certificates.crt}"
export PATH="/nix/var/nix/profiles/default/bin:$PATH"
EOF
    chmod 644 /etc/profile.d/nix.sh

    if ! grep -q 'profile.d/nix.sh' /etc/profile 2>/dev/null; then
        cat >> /etc/profile <<'EOF'

# Nix — подключение профиля (добавлено LFS-оркестратором)
if [ -r /etc/profile.d/nix.sh ]; then
    . /etc/profile.d/nix.sh
fi
EOF
        ok "профиль Nix подключён к /etc/profile"
    else
        ok "профиль Nix уже подключён"
    fi
}

# ─── .xinitrc пользователя ──────────────────────────────────────────────────
configure_user() {
    section "13.4 Сессия пользователя $SET_USER"

    local home
    home="$(getent passwd "$SET_USER" | cut -d: -f6)"
    if [[ -z "$home" || ! -d "$home" ]]; then
        warn "домашний каталог $SET_USER не найден — пропуск"
        return 1
    fi

    # Файл наш, поэтому перезаписываем всегда: при обновлении фазы он должен
    # получать свежие переменные окружения.
    cat > "$home/.xinitrc" <<'EOF'
#!/bin/sh
# Запуск рабочего стола XFCE (создано фазой 13 LFS-оркестратора)

# Профиль Nix: бинарники и сертификаты (/etc/profile его не подключает)
export PATH="/nix/var/nix/profiles/default/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export NIX_SSL_CERT_FILE="/etc/ssl/certs/ca-certificates.crt"

export XDG_DATA_DIRS="/nix/var/nix/profiles/default/share:/usr/share:/usr/local/share"
export XDG_CONFIG_DIRS="/nix/var/nix/profiles/default/etc/xdg:/etc/xdg"

# Часть пакетов XFCE лежит в store, но не попала в профиль. В share dbus ищет
# .service-файлы (xfconfd), а настройки по умолчанию — в etc/xdg: внутри лежит
# xfce4/xfconf/xfce-perchannel-xml, откуда берётся имя failsafe-сессии. Именно
# etc/xdg, а не etc — иначе xfce4-session падает с «Unable to load a failsafe
# session».
for d in /nix/store/*-xfconf-*/share /nix/store/*-xfce4-session-*/share \
         /nix/store/*-xfce4-panel-*/share /nix/store/*-thunar-*/share; do
    [ -d "$d" ] && XDG_DATA_DIRS="$d:$XDG_DATA_DIRS"
done
for d in /nix/store/*-xfconf-*/etc/xdg /nix/store/*-xfce4-session-*/etc/xdg \
         /nix/store/*-xfce4-panel-*/etc/xdg /nix/store/*-xfwm4-*/etc/xdg; do
    [ -d "$d" ] && XDG_CONFIG_DIRS="$d:$XDG_CONFIG_DIRS"
done
export XDG_DATA_DIRS XDG_CONFIG_DIRS

# logind-сессии в базовом LFS нет (нет PAM), поэтому каталог создаём сами
XDG_RUNTIME_DIR="/run/user/$(id -u)"
export XDG_RUNTIME_DIR
[ -d "$XDG_RUNTIME_DIR" ] || { mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"; }

# XFCE нужна шина сеанса: без неё dbus не активирует xfconfd, а без xfconfd
# xfce4-session не находит failsafe-сессию и рабочий стол не стартует.
if command -v dbus-run-session >/dev/null 2>&1; then
    exec dbus-run-session -- startxfce4
fi
exec startxfce4
EOF
        chmod 644 "$home/.xinitrc"
        ok "$home/.xinitrc обновлён"

    chown "$SET_USER":"$SET_USER" "$home/.xinitrc" 2>/dev/null || true

    # Группы, без которых X не получит доступ к устройствам ввода и видео
    local g
    for g in video input; do
        getent group "$g" >/dev/null 2>&1 || { warn "нет группы $g"; continue; }
        id -nG "$SET_USER" | tr ' ' '\n' | grep -qx "$g" || {
            usermod -aG "$g" "$SET_USER" && ok "$SET_USER добавлен в $g"
        }
    done

    return 0
}

# ─── 13.6a PAM ──────────────────────────────────────────────────────────────
# Без pam_systemd logind не создаёт сессии, а polkit не понимает, кто сидит
# за консолью: кнопки питания в XFCE остаются серыми, а /run/user/<uid>
# приходится создавать вручную.
install_pam() {
    section "13.6a PAM"

    if [[ -f /usr/lib/security/pam_systemd.so ]] \
       && grep -q 'pam_systemd' /etc/pam.d/system-auth 2>/dev/null; then
        ok "PAM с pam_systemd уже настроен"
        systemctl enable systemd-logind systemd-user-sessions >/dev/null 2>&1 || true
        return 0
    fi

    local script
    script="$(dirname "$0")/install-pam.sh"
    if [[ ! -f "$script" ]]; then
        warn "нет $script — PAM не установлен, кнопки питания работать не будут"
        return 1
    fi

    log "запуск install-pam.sh --yes (пересборка systemd, shadow, openssh)"
    if bash "$script" --yes; then
        ok "PAM установлен"
    else
        warn "install-pam.sh завершился с ошибкой"
        return 1
    fi
}

# ─── 13.7 polkit ────────────────────────────────────────────────────────────
# Без polkit logind отвечает «Access denied» на CanPowerOff/CanReboot, и XFCE
# не показывает кнопки «Выход/Перезагрузка/Выключение». Политика
# org.freedesktop.login1.policy уже установлена вместе с systemd — нужен сам
# демон и его D-Bus-активация.
install_polkit() {
    section "13.7 polkit"

    if ! command -v pkcheck >/dev/null 2>&1; then
        nix_install_one polkit >/dev/null 2>&1 || true
    fi

    # У polkit два выхода в store: -bin (pkcheck) и основной (lib, share).
    # Префикс берём по основному выходу, иначе не будет lib/polkit-1/polkitd.
    local prefix
    prefix="$(ls -d /nix/store/*-polkit-[0-9]* 2>/dev/null | grep -v -- '-bin$' | grep -v '\.drv$' | head -1)"
    if [[ -z "$prefix" || ! -x "$prefix/lib/polkit-1/polkitd" ]]; then
        warn "polkit не установился — кнопки питания в XFCE останутся недоступными"
        return 1
    fi
    ok "polkit: $prefix"

    # polkitd сбрасывает привилегии на polkituser («Successfully changed to
    # user polkituser» в отладке) — без этого пользователя демон не стартует.
    if ! grep -q '^polkituser:' /etc/passwd; then
        useradd -r -s /sbin/nologin -d /var/lib/polkit-1 polkituser 2>/dev/null \
            || useradd -r -s /sbin/nologin polkituser
        ok "пользователь polkituser создан"
    fi
    install -d -o polkituser -g polkituser -m 700 /var/lib/polkit-1 2>/dev/null || true

    # D-Bus. Право own нужно и root, и polkituser: соединение принадлежит тому,
    # под кем реально работает демон. Файл Nix-пакета не копируем — он может
    # ссылаться на его собственных пользователей.
    install -d /etc/dbus-1/system.d
    cat > /etc/dbus-1/system.d/org.freedesktop.PolicyKit1.conf <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE busconfig PUBLIC
 "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <policy user="root">
    <allow own="org.freedesktop.PolicyKit1"/>
  </policy>
  <policy user="polkituser">
    <allow own="org.freedesktop.PolicyKit1"/>
  </policy>
  <policy context="default">
    <allow send_destination="org.freedesktop.PolicyKit1"/>
    <allow send_destination="org.freedesktop.PolicyKit1" send_interface="org.freedesktop.DBus.Properties"/>
  </policy>
</busconfig>
EOF
    ok "D-Bus policy установлена"

    if [[ -f "$prefix/share/dbus-1/system-services/org.freedesktop.PolicyKit1.service" ]]; then
        install -Dm644 "$prefix/share/dbus-1/system-services/org.freedesktop.PolicyKit1.service" \
            /usr/share/dbus-1/system-services/org.freedesktop.PolicyKit1.service
        ok "D-Bus активация установлена"
    fi

    # polkit 127 ищет .policy в /etc/polkit-1/actions (плюс /run, /usr/local/share,
    # /run/current-system/sw), но не в /usr/share — туда копировать бесполезно.
    install -d /etc/polkit-1/actions /etc/polkit-1/rules.d /run/polkit-1
    if compgen -G "$prefix/share/polkit-1/actions/*.policy" >/dev/null 2>&1; then
        cp -f "$prefix"/share/polkit-1/actions/*.policy /etc/polkit-1/actions/
        ok "политики действий: $(ls /etc/polkit-1/actions | wc -l) файлов"
    else
        warn "нет $prefix/share/polkit-1/actions/*.policy"
    fi
    if [[ ! -f /etc/polkit-1/actions/org.freedesktop.login1.policy ]]; then
        warn "нет org.freedesktop.login1.policy — кнопки питания не появятся"
    fi

    cat > /etc/systemd/system/polkit.service <<EOF
[Unit]
Description=PolicyKit daemon
Wants=dbus.service
After=dbus.service

[Service]
Type=dbus
BusName=org.freedesktop.PolicyKit1
ExecStart=$prefix/lib/polkit-1/polkitd --no-debug
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    mkdir -p /etc/systemd/system/multi-user.target.wants
    if [[ ! -e /etc/systemd/system/multi-user.target.wants/polkit.service ]]; then
        ln -sf /etc/systemd/system/polkit.service \
            /etc/systemd/system/multi-user.target.wants/polkit.service
        ok "polkit.service включён"
    fi

    # Право own проверяется при подключении к шине, поэтому после правки
    # политики нужен reload конфигурации dbus (не restart — он рвёт соединение
    # logind, и тот больше не занимает org.freedesktop.login1).
    systemctl reload dbus >/dev/null 2>&1 || true
    systemctl daemon-reload
    systemctl reset-failed polkit >/dev/null 2>&1 || true
    systemctl restart polkit >/dev/null 2>&1 || systemctl start polkit >/dev/null 2>&1

    if busctl list --no-pager 2>/dev/null | grep -q 'org.freedesktop.PolicyKit1.*polkitd'; then
        ok "polkitd занял имя на шине"
    else
        warn "polkitd не занял org.freedesktop.PolicyKit1"
    fi

    # Если dbus перезапускали вручную, logind теряет своё имя и остаётся
    # «activatable»: CanPowerOff тогда висит 25 с и падает по таймауту.
    if ! busctl list --no-pager 2>/dev/null | grep -q 'org.freedesktop.login1 .*systemd-logind'; then
        warn "logind без имени на шине — перезапускаю"
        systemctl restart systemd-logind >/dev/null 2>&1 || true
        sleep 1
    fi

    local can
    can="$(timeout 15 busctl call org.freedesktop.login1 /org/freedesktop/login1 \
        org.freedesktop.login1.Manager CanPowerOff 2>&1)"
    case "$can" in
        *'"yes"'*)       ok "CanPowerOff: yes" ;;
        *challenge*)     ok "CanPowerOff: challenge (для локальной сессии seat0 будет yes)" ;;
        *)               warn "CanPowerOff: $can" ;;
    esac
}

# ─── 13.8a Автозапуск графической сессии ────────────────────────────────────
# Рабочий стол должен подниматься сам, без ввода startx. Дисплей-менеджер
# (lightdm и т.п.) тянет за собой лишние зависимости, поэтому используется
# схема «agetty --autologin + startx из профиля bash»: вход всё равно идёт
# через login и PAM, так что logind видит нормальную локальную сессию,
# а значит polkit и кнопки питания продолжают работать.
install_autostart() {
    section "13.8a Автозапуск графической сессии"

    if [[ -z "$SET_USER" ]]; then
        warn "SET_USER не определён — автозапуск пропущен"
        return 1
    fi

    local home
    home="$(getent passwd "$SET_USER" | cut -d: -f6)"
    if [[ -z "$home" || ! -d "$home" ]]; then
        warn "домашний каталог $SET_USER не найден — автозапуск пропущен"
        return 1
    fi

    local agetty=""
    local p
    for p in /sbin/agetty /usr/bin/agetty /bin/agetty; do
        [[ -x "$p" ]] && { agetty="$p"; break; }
    done
    if [[ -z "$agetty" ]]; then
        warn "agetty не найден — автозапуск пропущен"
        return 1
    fi

    install -d /etc/systemd/system/getty@tty1.service.d
    cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<EOF
[Service]
ExecStart=
ExecStart=-$agetty --autologin $SET_USER --noclear %I \$TERM
EOF
    ok "автологин $SET_USER на tty1"

    # startx запускается из профиля login-сессии только на первой консоли:
    # по SSH и на остальных tty остаётся обычная оболочка.
    if ! grep -q 'LFS-AUTOSTART' "$home/.bash_profile" 2>/dev/null; then
        cat >> "$home/.bash_profile" <<'EOF'

# LFS-AUTOSTART: рабочий стол на первой консоли
if [ -z "${DISPLAY:-}" ] && [ "$(tty)" = "/dev/tty1" ] && command -v startx >/dev/null 2>&1; then
    startx
fi
EOF
        chown "$SET_USER":"$SET_USER" "$home/.bash_profile" 2>/dev/null || true
        ok "$home/.bash_profile дополнен"
    else
        ok "$home/.bash_profile уже настроен"
    fi

    systemctl daemon-reload 2>/dev/null || true
    systemctl enable getty@tty1.service >/dev/null 2>&1 || true
    ok "getty@tty1 включён — рабочий стол поднимется при загрузке"
}

# ─── 13.8 Проверка ──────────────────────────────────────────────────────────
verify() {
    section "13.5 Проверка"

    local missing=0 b
    for b in Xorg startx xauth startxfce4 xfce4-session xfwm4 xfce4-panel xfdesktop; do
        if command -v "$b" >/dev/null 2>&1; then
            ok "$b: $(command -v "$b")"
        else
            warn "нет в PATH: $b"
            missing=$((missing + 1))
        fi
    done

    if [[ -n "$(find /nix/store -maxdepth 4 -type d -name 'xkeyboard-config*' 2>/dev/null | head -1)" ]]; then
        ok "xkeyboard-config в store есть"
    fi

    echo
    if (( missing == 0 )); then
        ok "всё на месте — рабочий стол ставится командой startx из консоли"
    else
        warn "не найдено $missing команд(ы) — см. /tmp/nix-desktop.log"
    fi

    if (( ${#NIX_FAILED[@]} )); then
        warn "не установились пакеты: ${NIX_FAILED[*]}"
    fi
    return 0
}

# ─── Запуск ─────────────────────────────────────────────────────────────────
echo "###### LFS фаза 13 (графика) — начало: $(date) ######"

if ! command -v nix >/dev/null 2>&1; then
    warn "Nix не установлен — сначала должна выполниться фаза 12"
    echo "###### LFS фаза 13 — пропущена ######"
    exit 1
fi
ok "Nix: $(nix --version)"

RC=0
should_run xorg    && { install_xorg    || RC=1; }
should_run xfce    && { install_xfce    || RC=1; }
should_run system  && { integrate       || RC=1; }
should_run pam     && { install_pam     || RC=1; }
should_run polkit  && { install_polkit  || RC=1; }
should_run profile && { ensure_nix_profile || RC=1; }
should_run user    && { configure_user  || RC=1; }
should_run autostart && { install_autostart || RC=1; }
verify || true

echo
if [[ $RC -eq 0 ]]; then
    echo "###### LFS фаза 13 — завершена: $(date) ######"
else
    echo "###### LFS фаза 13 — завершена С ОШИБКАМИ: $(date) ######"
fi
exit $RC
