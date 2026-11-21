#!/bin/bash
###############################################################################
# fetch-extras.sh — докачать пакеты, которых нет в наборе базового LFS
#
# Базовый LFS не содержит sudo, openssh, curl, wget и сертификатов.
# Всё это нужно для фазы 12 (пользователь, SSH, Nix, графика).
#
# Запускать на ХОСТЕ (Debian), нужен curl:
#     sudo bash fetch-extras.sh              # основное
#     sudo bash fetch-extras.sh --xorg       # плюс 14 архивов Xorg
#     sudo bash fetch-extras.sh --list       # только показать список
#
# Куда качает: ../sources (рядом с каталогом оркестратора),
# либо --to <каталог>.
# Каждый файл проверяется на HTTP 200; по итогам пишется extra-sha256sums,
# повторный запуск сверяет контрольные суммы и не качает заново.
###############################################################################
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${LFS_SOURCES:-$SCRIPT_DIR/../sources}"
DO_XORG=0
LIST_ONLY=0

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${BLUE}·${NC} $*"; }
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}!${NC} $*"; }
err()  { echo -e "${RED}✗${NC} $*"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --xorg) DO_XORG=1; shift ;;
        --list) LIST_ONLY=1; shift ;;
        --to)   DEST="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) err "неизвестный аргумент: $1"; exit 2 ;;
    esac
done

command -v curl >/dev/null 2>&1 || { err "нужен curl: apt install curl"; exit 1; }

# ─── Список: имя файла → URL ────────────────────────────────────────────────
CORE=(
"sudo-1.9.17p2.tar.gz|https://www.sudo.ws/dist/sudo-1.9.17p2.tar.gz"
"openssh-10.6p2.tar.gz|https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-10.6p2.tar.gz"
"curl-8.23.0.tar.xz|https://curl.se/download/curl-8.23.0.tar.xz"
"wget-1.25.0.tar.gz|https://ftp.gnu.org/gnu/wget/wget-1.25.0.tar.gz"
"nix-install.sh|https://nixos.org/nix/install"
"Linux-PAM-1.7.0.tar.xz|https://github.com/linux-pam/linux-pam/releases/download/v1.7.0/Linux-PAM-1.7.0.tar.xz"
)

# Xorg нужен только если собирать графику из исходников (без Nix).
XORG=(
"Mako-1.3.10.tar.gz|https://files.pythonhosted.org/packages/source/M/Mako/Mako-1.3.10.tar.gz"
"font-util-1.4.1.tar.xz|https://xorg.freedesktop.org/releases/individual/font/font-util-1.4.1.tar.xz"
"libXau-1.0.12.tar.xz|https://xorg.freedesktop.org/releases/individual/lib/libXau-1.0.12.tar.xz"
"libXdmcp-1.1.5.tar.xz|https://xorg.freedesktop.org/releases/individual/lib/libXdmcp-1.1.5.tar.xz"
"libepoxy-1.5.10.tar.gz|https://download.gnome.org/sources/libepoxy/1.5/libepoxy-1.5.10.tar.gz"
"libxcb-1.17.0.tar.xz|https://xorg.freedesktop.org/releases/individual/lib/libxcb-1.17.0.tar.xz"
"libxcvt-0.1.3.tar.xz|https://xorg.freedesktop.org/releases/individual/lib/libxcvt-0.1.3.tar.xz"
"pixman-0.46.4.tar.xz|https://xorg.freedesktop.org/releases/individual/lib/pixman-0.46.4.tar.xz"
"xf86-input-libinput-1.5.0.tar.xz|https://xorg.freedesktop.org/releases/individual/driver/xf86-input-libinput-1.5.0.tar.xz"
"xf86-video-vmware-13.4.0.tar.xz|https://xorg.freedesktop.org/releases/individual/driver/xf86-video-vmware-13.4.0.tar.xz"
"xkeyboard-config-2.48.tar.xz|https://xorg.freedesktop.org/releases/individual/data/xkeyboard-config/xkeyboard-config-2.48.tar.xz"
"xorg-server-21.1.24.tar.xz|https://xorg.freedesktop.org/releases/individual/xserver/xorg-server-21.1.24.tar.xz"
"mesa-26.1.7.tar.xz|https://archive.mesa3d.org/mesa-26.1.7.tar.xz"
"libinput-1.28.1.tar.gz|https://gitlab.freedesktop.org/libinput/libinput/-/archive/1.28.1/libinput-1.28.1.tar.gz"
)

ITEMS=("${CORE[@]}")
(( DO_XORG )) && ITEMS+=("${XORG[@]}")

echo "Каталог: $DEST"
echo "Пакетов в списке: ${#ITEMS[@]}$( (( DO_XORG )) && echo ' (включая Xorg)')"
echo

if (( LIST_ONLY )); then
    for item in "${ITEMS[@]}"; do
        printf "  %-38s %s\n" "${item%%|*}" "${item##*|}"
    done
    exit 0
fi

mkdir -p "$DEST" || { err "не удалось создать $DEST"; exit 1; }
SUMS="$DEST/extra-sha256sums"
touch "$SUMS"

downloaded=0; skipped=0; failed=0
failed_list=()

for item in "${ITEMS[@]}"; do
    name="${item%%|*}"
    url="${item##*|}"
    file="$DEST/$name"

    if [[ -f "$file" ]]; then
        want="$(grep -F "  $name" "$SUMS" 2>/dev/null | awk '{print $1}' | head -1)"
        if [[ -n "$want" ]]; then
            got="$(sha256sum "$file" | awk '{print $1}')"
            if [[ "$got" == "$want" ]]; then
                ok "$name — уже есть, сумма совпала"
                skipped=$((skipped + 1))
                continue
            fi
            warn "$name — сумма не совпала, перекачиваю"
            rm -f "$file"
        else
            ok "$name — уже есть (без сверки)"
            skipped=$((skipped + 1))
            sha256sum "$file" >> "$SUMS"
            continue
        fi
    fi

    code="$(curl -sIL --max-time 30 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null)"
    if [[ "$code" != "200" ]]; then
        err "$name — недоступен (HTTP $code)"
        failed_list+=("$name|HTTP $code|$url")
        failed=$((failed + 1))
        continue
    fi

    log "качаю $name…"
    if curl -fsSL --max-time 600 -o "$file.part" "$url"; then
        mv -f "$file.part" "$file"
        sha="$(sha256sum "$file" | awk '{print $1}')"
        grep -vF "  $name" "$SUMS" > "$SUMS.tmp" 2>/dev/null || true
        mv -f "$SUMS.tmp" "$SUMS"
        echo "$sha  $name" >> "$SUMS"
        size="$(du -h "$file" | cut -f1)"
        ok "$name — скачан ($size)"
        downloaded=$((downloaded + 1))
    else
        rm -f "$file.part"
        err "$name — ошибка загрузки"
        failed_list+=("$name|ошибка загрузки|$url")
        failed=$((failed + 1))
    fi
done

# ─── Сертификаты ────────────────────────────────────────────────────────────
if [[ -f /etc/ssl/certs/ca-certificates.crt ]]; then
    cp -f /etc/ssl/certs/ca-certificates.crt "$DEST/ca-certificates.crt"
    ok "ca-certificates.crt — скопирован с хоста ($(du -h "$DEST/ca-certificates.crt" | cut -f1))"
else
    warn "на хосте нет /etc/ssl/certs/ca-certificates.crt"
fi

echo
echo "──────────────────────────────────────────────"
echo "скачано: $downloaded, уже было: $skipped, ошибок: $failed"
if (( failed )); then
    echo
    echo "не удалось получить:"
    for f in "${failed_list[@]}"; do
        IFS='|' read -r n c u <<< "$f"
        echo "  $n  ($c)"
        echo "     $u"
    done
    echo
    echo "Эти файлы можно скачать вручную и положить в $DEST"
fi
echo
echo "Контрольные суммы: $SUMS"
echo
