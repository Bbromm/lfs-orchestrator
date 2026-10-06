#!/bin/bash
###############################################################################
# build-lfs.sh — Мастер-скрипт сборки LFS 13.1-systemd
#
# Полная автоматизация всех фаз:
#   Phase 0: Подготовка хост-системы (Гл. 2–3)
#   Phase 1: Финальные приготовления (Гл. 4)
#   Phase 2: Кросс-инструментарий (Гл. 5)
#   Phase 3: Временные инструменты (Гл. 6)
#   Phase 4: Chroot + доп. инструменты (Гл. 7)
#   Phase 5: Базовое системное ПО (Гл. 8)
#   Phase 6: Конфигурация системы (Гл. 9)
#   Phase 7: Ядро + GRUB (Гл. 10)
#   Phase 8: Финализация (Гл. 11)
#
# Использование:
#   sudo bash build-lfs.sh                  # Собрать всё
#   sudo bash build-lfs.sh --from phase2    # Начать с определённой фазы
#   sudo bash build-lfs.sh --only phase5    # Выполнить только одну фазу
#   sudo bash build-lfs.sh --status         # Показать статус
#   sudo bash build-lfs.sh --reset          # Сбросить чекпоинты
###############################################################################

set -euo pipefail

#------------------------------------------------------------------------------
# Загрузка конфигурации
#------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/lfs-config.sh"

[[ -f "$CONFIG_FILE" ]] || { echo "ОШИБКА: Не найден $CONFIG_FILE"; exit 1; }
# shellcheck source=lfs-config.sh
source "$CONFIG_FILE"

#------------------------------------------------------------------------------
# Константы
#------------------------------------------------------------------------------
STATE_DIR="${SCRIPT_DIR}/state"
SCRIPTS_DIR="${SCRIPT_DIR}/scripts"
LOG_DIR="${SCRIPT_DIR}/logs"
TS="$(date +%Y%m%d-%H%M%S)"
MASTER_LOG="${LOG_DIR}/master-${TS}.log"

mkdir -p "$STATE_DIR" "$LOG_DIR"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; MAGENTA='\033[0;35m'; CYAN='\033[0;36m'; NC='\033[0m'

log()     { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*" | tee -a "$MASTER_LOG"; }
ok()      { echo -e "${GREEN}[OK]${NC} $*"       | tee -a "$MASTER_LOG"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"    | tee -a "$MASTER_LOG"; }
die()     { echo -e "${RED}[ERROR]${NC} $*"      | tee -a "$MASTER_LOG"; exit 1; }
phase()   { echo; echo -e "${MAGENTA}════════════════════════════════════════════════════════════════${NC}" | tee -a "$MASTER_LOG"
            echo -e "${MAGENTA}  $*${NC}" | tee -a "$MASTER_LOG"
            echo -e "${MAGENTA}════════════════════════════════════════════════════════════════${NC}" | tee -a "$MASTER_LOG"; echo; }

confirm() {
    [[ "$FORCE_YES" == "yes" ]] && return 0
    local msg="$1"
    read -rp "$(echo -e "${YELLOW}$msg [y/N]${NC} ")" ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

#------------------------------------------------------------------------------
# Управление чекпоинтами
#------------------------------------------------------------------------------
is_done()  { [[ -f "${STATE_DIR}/$1.done" ]]; }
mark_done(){ touch "${STATE_DIR}/$1.done"; ok "Фаза '$1' помечена как завершённая"; }
reset_all(){ rm -rf "${STATE_DIR:?}"/*; ok "Все чекпоинты сброшены"; }

show_status() {
    echo "Статус фаз сборки:"
    for p in phase0 phase1 phase2 phase3 phase4 phase5 phase6 phase7 phase8; do
        if is_done "$p"; then
            echo -e "  ${GREEN}✔${NC} $p"
        else
            echo -e "  ${RED}✘${NC} $p (не выполнена)"
        fi
    done
}

#------------------------------------------------------------------------------
# Универсальная обёртка для запуска фазы
#------------------------------------------------------------------------------
run_phase() {
    local name="$1"
    local script="$2"
    shift 2
    local args=("$@")

    if [[ "$RESUME_MODE" == "yes" ]] && is_done "$name"; then
        warn "Фаза '$name' уже выполнена (пропуск). Для повтора: rm ${STATE_DIR}/$name.done"
        return 0
    fi

    phase "Фаза $name: $script"

    if [[ ! -f "$script" ]]; then
        die "Скрипт не найден: $script"
    fi

    local phase_log="${LOG_DIR}/${name}-${TS}.log"
    log "Лог фазы: $phase_log"

    if bash "$script" "${args[@]}" 2>&1 | tee "$phase_log"; then
        mark_done "$name"
        return 0
    else
        warn "Фаза '$name' завершилась с ошибкой (см. $phase_log)"
        if [[ "$STOP_ON_ERROR" == "1" ]]; then
            die "Остановка из-за STOP_ON_ERROR=1"
        fi
        return 1
    fi
}

#------------------------------------------------------------------------------
# Проверка хост-системы
#------------------------------------------------------------------------------
check_host() {
    phase "Проверка хост-системы"

    [[ "$(id -u)" == "0" ]] || die "Мастер-скрипт должен запускаться от root"

    log "Хост-система: $(uname -a)"
    log "Архитектура: $(uname -m)"

    # Проверка version-check.sh (Глава 2.2)
    if [[ -f "${SCRIPT_DIR}/version-check.sh" ]]; then
        log "Запуск version-check.sh..."
        bash "${SCRIPT_DIR}/version-check.sh" 2>&1 | tee -a "$MASTER_LOG" || \
            die "Хост-система не соответствует требованиям"
        ok "Хост-система соответствует требованиям"
    else
        warn "version-check.sh не найден — пропуск проверки (см. Главу 2.2)"
    fi

    # Проверка обязательных утилит
    local needed=(tar wget xz bzip2 gzip gcc make bison)
    for cmd in "${needed[@]}"; do
        command -v "$cmd" >/dev/null || die "Утилита '$cmd' не найдена"
    done
    ok "Обязательные утилиты на месте"
}

#------------------------------------------------------------------------------
# ФАЗА 0: Подготовка хост-системы (Главы 2–3)
#------------------------------------------------------------------------------
phase0_host_prep() {
    local script="${SCRIPTS_DIR}/phase0-host-prep.sh"
    run_phase "phase0" "$script"
}

#------------------------------------------------------------------------------
# ФАЗА 1: Финальные приготовления (Глава 4)
#------------------------------------------------------------------------------
phase1_chapter4() {
    local script="${SCRIPTS_DIR}/phase1-chapter4.sh"
    run_phase "phase1" "$script"
}

#------------------------------------------------------------------------------
# ФАЗА 2: Кросс-инструментарий (Глава 5)
#------------------------------------------------------------------------------
phase2_chapter5() {
    local script="${SCRIPTS_DIR}/install-chapter5.sh"
    # Скрипт запускается от имени lfs
    log "Запуск главы 5 от имени пользователя lfs..."

    # Проверка, что инструменты Главы 4 настроены
    [[ -f "$LFS/tools/bin/../.chapter4-done" ]] 2>/dev/null || true

    if [[ "$RESUME_MODE" == "yes" ]] && is_done "phase2"; then
        warn "Фаза 'phase2' уже выполнена (пропуск)"
        return 0
    fi

    phase "Фаза phase2: Глава 5 — Кросс-инструментарий"

    local phase_log="${LOG_DIR}/phase2-${TS}.log"
    if sudo -u lfs -i bash -c "cd '$LFS/sources' && bash '$script'" 2>&1 | tee "$phase_log"; then
        mark_done "phase2"
    else
        warn "Фаза phase2 завершилась с ошибкой"
        [[ "$STOP_ON_ERROR" == "1" ]] && die "Остановка"
    fi
}

#------------------------------------------------------------------------------
# ФАЗА 3: Временные инструменты (Глава 6)
#------------------------------------------------------------------------------
phase3_chapter6() {
    local script="${SCRIPTS_DIR}/install-chapter6.sh"

    if [[ "$RESUME_MODE" == "yes" ]] && is_done "phase3"; then
        warn "Фаза 'phase3' уже выполнена (пропуск)"
        return 0
    fi

    phase "Фаза phase3: Глава 6 — Временные инструменты"

    local phase_log="${LOG_DIR}/phase3-${TS}.log"
    if sudo -u lfs -i bash -c "cd '$LFS/sources' && bash '$script'" 2>&1 | tee "$phase_log"; then
        mark_done "phase3"
    else
        warn "Фаза phase3 завершилась с ошибкой"
        [[ "$STOP_ON_ERROR" == "1" ]] && die "Остановка"
    fi
}

#------------------------------------------------------------------------------
# ФАЗА 4: Chroot + доп. инструменты (Глава 7)
#------------------------------------------------------------------------------
phase4_chapter7() {
    local script="${SCRIPTS_DIR}/install-chapter7.sh"

    if [[ "$RESUME_MODE" == "yes" ]] && is_done "phase4"; then
        warn "Фаза 'phase4' уже выполнена (пропуск)"
        return 0
    fi

    phase "Фаза phase4: Глава 7 — Chroot + доп. инструменты"

    local phase_log="${LOG_DIR}/phase4-${TS}.log"
    # Скрипт сам обрабатывает обе фазы A и B
    if bash "$script" --phase-a 2>&1 | tee "$phase_log"; then
        mark_done "phase4"
    else
        warn "Фаза phase4 завершилась с ошибкой"
        [[ "$STOP_ON_ERROR" == "1" ]] && die "Остановка"
    fi
}

#------------------------------------------------------------------------------
# ФАЗА 5: Базовое системное ПО (Глава 8) — внутри chroot
#------------------------------------------------------------------------------
phase5_chapter8() {
    local script="${SCRIPTS_DIR}/install-chapter8.sh"

    if [[ "$RESUME_MODE" == "yes" ]] && is_done "phase5"; then
        warn "Фаза 'phase5' уже выполнена (пропуск)"
        return 0
    fi

    phase "Фаза phase5: Глава 8 — Базовое системное ПО (внутри chroot)"

    # Копируем скрипт внутрь chroot
    cp -v "$script" "$LFS/install-chapter8.sh"
    chmod +x "$LFS/install-chapter8.sh"

    # Убедимся, что виртуальные ФС смонтированы
    mountpoint -q "$LFS/dev"  || mount -v --bind /dev "$LFS/dev"
    mountpoint -q "$LFS/proc" || mount -vt proc proc "$LFS/proc"
    mountpoint -q "$LFS/sys"  || mount -vt sysfs sysfs "$LFS/sys"
    mountpoint -q "$LFS/run"  || mount -vt tmpfs tmpfs "$LFS/run"

    local phase_log="${LOG_DIR}/phase5-${TS}.log"
    if chroot "$LFS" /usr/bin/env -i \
            HOME=/root \
            TERM="$TERM" \
            PS1='(lfs chroot) \u:\w\$ ' \
            PATH=/usr/bin:/usr/sbin \
            MAKEFLAGS="-j$(nproc)" \
            TESTSUITEFLAGS="-j$(nproc)" \
            RUN_TESTS="$RUN_TESTS" \
            /bin/bash --login -c "bash /install-chapter8.sh" \
            2>&1 | tee "$phase_log"; then
        mark_done "phase5"
    else
        warn "Фаза phase5 завершилась с ошибкой"
        [[ "$STOP_ON_ERROR" == "1" ]] && die "Остановка"
    fi
}

#------------------------------------------------------------------------------
# ФАЗА 6: Конфигурация системы (Глава 9) — внутри chroot
#------------------------------------------------------------------------------
phase6_chapter9() {
    local script="${SCRIPTS_DIR}/phase5-chapter9.sh"

    if [[ "$RESUME_MODE" == "yes" ]] && is_done "phase6"; then
        warn "Фаза 'phase6' уже выполнена (пропуск)"
        return 0
    fi

    phase "Фаза phase6: Глава 9 — Конфигурация системы"

    cp -v "$script" "$LFS/configure-system.sh"
    chmod +x "$LFS/configure-system.sh"

    local phase_log="${LOG_DIR}/phase6-${TS}.log"
    if chroot "$LFS" /usr/bin/env -i \
            HOME=/root \
            TERM="$TERM" \
            PS1='(lfs chroot) \u:\w\$ ' \
            PATH=/usr/bin:/usr/sbin \
            HOSTNAME="$HOSTNAME" \
            TIMEZONE="$TIMEZONE" \
            LOCALE="$LOCALE" \
            KEYMAP="$KEYMAP" \
            CONSOLE_FONT="$CONSOLE_FONT" \
            USE_DHCP="$USE_DHCP" \
            STATIC_IP="$STATIC_IP" \
            GATEWAY="$GATEWAY" \
            DNS_PRIMARY="$DNS_PRIMARY" \
            DNS_SECONDARY="$DNS_SECONDARY" \
            LFS_VERSION="$LFS_VERSION" \
            /bin/bash --login -c "bash /configure-system.sh" \
            2>&1 | tee "$phase_log"; then
        mark_done "phase6"
    else
        warn "Фаза phase6 завершилась с ошибкой"
        [[ "$STOP_ON_ERROR" == "1" ]] && die "Остановка"
    fi
}

#------------------------------------------------------------------------------
# ФАЗА 7: Ядро + GRUB (Глава 10) — внутри chroot
#------------------------------------------------------------------------------
phase7_chapter10() {
    local script="${SCRIPTS_DIR}/phase6-chapter10.sh"

    if [[ "$RESUME_MODE" == "yes" ]] && is_done "phase7"; then
        warn "Фаза 'phase7' уже выполнена (пропуск)"
        return 0
    fi

    phase "Фаза phase7: Глава 10 — Ядро + GRUB"

    cp -v "$script" "$LFS/build-kernel.sh"
    chmod +x "$LFS/build-kernel.sh"

    # Копируем custom defconfig, если есть
    if [[ -f "${SCRIPT_DIR}/kernel/lfs-defconfig" ]]; then
        cp -v "${SCRIPT_DIR}/kernel/lfs-defconfig" "$LFS/lfs-defconfig"
    fi

    local phase_log="${LOG_DIR}/phase7-${TS}.log"
    if chroot "$LFS" /usr/bin/env -i \
            HOME=/root \
            TERM="$TERM" \
            PS1='(lfs chroot) \u:\w\$ ' \
            PATH=/usr/bin:/usr/sbin \
            KERNEL_CONFIG_METHOD="$KERNEL_CONFIG_METHOD" \
            KERNEL_JOBS="$KERNEL_JOBS" \
            LFS_VERSION="$LFS_VERSION" \
            DISK="$DISK" \
            USE_UEFI="$USE_UEFI" \
            /bin/bash --login -c "bash /build-kernel.sh" \
            2>&1 | tee "$phase_log"; then
        mark_done "phase7"
    else
        warn "Фаза phase7 завершилась с ошибкой"
        [[ "$STOP_ON_ERROR" == "1" ]] && die "Остановка"
    fi
}

#------------------------------------------------------------------------------
# ФАЗА 8: Финализация (Глава 11)
#------------------------------------------------------------------------------
phase8_finalize() {
    if [[ "$RESUME_MODE" == "yes" ]] && is_done "phase8"; then
        warn "Фаза 'phase8' уже выполнена (пропуск)"
        return 0
    fi

    phase "Фаза phase8: Глава 11 — Финализация"

    cp -v "${SCRIPTS_DIR}/postinstall.sh" "$LFS/postinstall.sh"
    chmod +x "$LFS/postinstall.sh"

    local phase_log="${LOG_DIR}/phase8-${TS}.log"
    if chroot "$LFS" /usr/bin/env -i \
            HOME=/root \
            TERM="$TERM" \
            PS1='(lfs chroot) \u:\w\$ ' \
            PATH=/usr/bin:/usr/sbin \
            LFS_VERSION="$LFS_VERSION" \
            /bin/bash --login -c "bash /postinstall.sh" \
            2>&1 | tee "$phase_log"; then
        mark_done "phase8"
    else
        warn "Фаза phase8 завершилась с ошибкой"
        [[ "$STOP_ON_ERROR" == "1" ]] && die "Остановка"
    fi
}

#------------------------------------------------------------------------------
# Итоговый отчёт
#------------------------------------------------------------------------------
final_report() {
    phase "🎉 Сборка LFS завершена!"

    echo "Версия: $LFS_VERSION"
    echo "Корень LFS: $LFS"
    echo "Логи: $LOG_DIR/"
    echo "Чекпоинты: $STATE_DIR/"
    echo ""

    # Проверка, что все фазы завершены
    local all_ok=1
    for p in phase0 phase1 phase2 phase3 phase4 phase5 phase6 phase7 phase8; do
        is_done "$p" || all_ok=0
    done

    if (( all_ok )); then
        ok "Все фазы успешно завершены!"
        echo ""
        echo "Следующие шаги:"
        echo "  1. Установить пароль root:"
        echo "       chroot $LFS /usr/bin/passwd root"
        echo "  2. Размонтировать виртуальные ФС:"
        echo "       umount -v $LFS/dev/pts"
        echo "       umount -v $LFS/dev"
        echo "       umount -v $LFS/run"
        echo "       umount -v $LFS/proc"
        echo "       umount -v $LFS/sys"
        echo "       umount -v $LFS"
        echo "  3. Перезагрузиться и выбрать LFS в меню GRUB"
    else
        warn "Некоторые фазы не завершены. Проверьте: bash $0 --status"
    fi
}

#------------------------------------------------------------------------------
# Разбор аргументов
#------------------------------------------------------------------------------
FROM_PHASE=""
ONLY_PHASE=""
ACTION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --from)   FROM_PHASE="$2"; shift 2 ;;
        --only)   ONLY_PHASE="$2"; shift 2 ;;
        --status) ACTION="status";  shift ;;
        --reset)  ACTION="reset";   shift ;;
        -h|--help)
            cat << EOF
Использование: bash build-lfs.sh [ОПЦИИ]

Опции:
  --from <phase>    Начать с указанной фазы (phase0..phase8)
  --only <phase>    Выполнить только одну фазу
  --status          Показать статус фаз
  --reset           Сбросить все чекпоинты
  -h, --help        Показать эту справку
EOF
            exit 0
            ;;
        *) die "Неизвестный аргумент: $1" ;;
    esac
done

#------------------------------------------------------------------------------
# Список фаз по порядку
#------------------------------------------------------------------------------
ALL_PHASES=(
    "phase0:phase0_host_prep"
    "phase1:phase1_chapter4"
    "phase2:phase2_chapter5"
    "phase3:phase3_chapter6"
    "phase4:phase4_chapter7"
    "phase5:phase5_chapter8"
    "phase6:phase6_chapter9"
    "phase7:phase7_chapter10"
    "phase8:phase8_finalize"
)

#------------------------------------------------------------------------------
# Главная логика
#------------------------------------------------------------------------------
main() {
    echo "" | tee -a "$MASTER_LOG"
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}" | tee -a "$MASTER_LOG"
    echo -e "${CYAN}║     LFS 13.1-systemd — Полная автоматическая сборка          ║${NC}" | tee -a "$MASTER_LOG"
    echo -e "${CYAN}║     Начало: $(date)                             ║${NC}" | tee -a "$MASTER_LOG"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}" | tee -a "$MASTER_LOG"
    echo "" | tee -a "$MASTER_LOG"

    # Специальные действия
    if [[ "$ACTION" == "status" ]]; then show_status; exit 0; fi
    if [[ "$ACTION" == "reset"  ]]; then reset_all; exit 0; fi

    # Проверка хоста (только если не --only)
    [[ -z "$ONLY_PHASE" ]] && check_host

    # Фильтрация фаз
    local run_list=()
    if [[ -n "$ONLY_PHASE" ]]; then
        for entry in "${ALL_PHASES[@]}"; do
            [[ "${entry%%:*}" == "$ONLY_PHASE" ]] && run_list+=("$entry")
        done
        [[ ${#run_list[@]} -gt 0 ]] || die "Фаза '$ONLY_PHASE' не найдена"
    elif [[ -n "$FROM_PHASE" ]]; then
        local started=0
        for entry in "${ALL_PHASES[@]}"; do
            if [[ "${entry%%:*}" == "$FROM_PHASE" ]]; then started=1; fi
            (( started )) && run_list+=("$entry")
        done
        [[ ${#run_list[@]} -gt 0 ]] || die "Фаза '$FROM_PHASE' не найдена"
    else
        run_list=("${ALL_PHASES[@]}")
    fi

    # Выполнение
    for entry in "${run_list[@]}"; do
        local pname="${entry%%:*}"
        local pfunc="${entry##*:}"
        "$pfunc" || {
            warn "Фаза $pname завершилась с ошибкой"
            [[ "$STOP_ON_ERROR" == "1" ]] && exit 1
        }
    done

    final_report
}

main "$@" 2>&1 | tee -a "$MASTER_LOG"
exit "${PIPESTATUS[0]}"