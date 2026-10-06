#!/bin/bash
###############################################################################
# sbu-profiler.sh — Сбор статистики SBU и прогноз времени
# Используется внутри скриптов глав для записи времени сборки.
###############################################################################
set -euo pipefail

SBU_FILE="${SBU_FILE:-/root/lfs-build/state/sbu-times.tsv}"
SBU_REFERENCE="${SBU_REFERENCE:-/root/lfs-build/state/sbu-reference}"

mkdir -p "$(dirname "$SBU_FILE")"

#------------------------------------------------------------------------------
# Запись времени сборки пакета
# time_package <name> <command...>
#------------------------------------------------------------------------------
time_package() {
    local name="$1"; shift
    local start=$(date +%s.%N)
    local rc=0

    "$@" || rc=$?

    local end=$(date +%s.%N)
    local elapsed=$(echo "$end - $start" | bc)

    # Запись в TSV: имя, секунды, дата, статус
    printf "%s\t%.2f\t%s\t%s\n" \
        "$name" "$elapsed" "$(date -Iseconds)" "$([ $rc -eq 0 ] && echo OK || echo FAIL)" \
        >> "$SBU_FILE"

    # Если это первый binutils-pass1 — сохраняем как эталон SBU
    if [[ "$name" == "binutils-pass1" && ! -f "$SBU_REFERENCE" ]]; then
        echo "$elapsed" > "$SBU_REFERENCE"
        echo "📊 SBU эталон: ${elapsed}с (binutils-pass1)"
    fi

    # Отчёт в SBU (если эталон есть)
    if [[ -f "$SBU_REFERENCE" ]]; then
        local sbu_ref=$(cat "$SBU_REFERENCE")
        local sbu=$(echo "scale=2; $elapsed / $sbu_ref" | bc)
        printf "  ⏱  %-30s %8.2fс = %5.2f SBU\n" "$name" "$elapsed" "$sbu"
    fi

    return $rc
}

#------------------------------------------------------------------------------
# Прогноз времени на основе собранных данных
# estimate_total <list of packages>
#------------------------------------------------------------------------------
estimate_total() {
    [[ -f "$SBU_REFERENCE" ]] || { echo "SBU-эталон не определён"; return; }
    local sbu_ref=$(cat "$SBU_REFERENCE")
    local total=0

    # Известные средние SBU из книги (можно дополнить)
    declare -A BOOK_SBU=(
        [binutils-pass1]=1.0 [gcc-pass1]=4.3 [glibc-tools]=1.3
        [binutils-pass2]=0.4 [gcc-pass2]=5.2
        [glibc]=11.0 [gcc]=53.0 [binutils]=1.7
        [systemd]=1.2 [python]=2.7 [perl]=1.3
        # ... остальные можно добавить
    )

    echo "Прогноз времени сборки (SBU-эталон: ${sbu_ref}с):"
    for pkg in "$@"; do
        local sbu=${BOOK_SBU[$pkg]:-1.0}
        local sec=$(echo "$sbu * $sbu_ref" | bc)
        printf "  %-30s %6.1f SBU = %s\n" "$pkg" "$sbu" "$(printf '%02d:%02d:%02d' $((sec/3600)) $((sec%3600/60)) $((sec%60)))"
        total=$(echo "$total + $sec" | bc)
    done
    printf "  %-30s %6s     %s\n" "ИТОГО:" "" \
        "$(printf '%02d:%02d:%02d' $((total/3600)) $((total%3600/60)) $((total%60)))"
}

#------------------------------------------------------------------------------
# Статистика по прошлым сборкам
#------------------------------------------------------------------------------
show_stats() {
    [[ -f "$SBU_FILE" ]] || { echo "Нет данных"; return; }
    echo "Статистика времени сборки:"
    echo "─────────────────────────────────────────────────"
    printf "%-30s %10s %10s\n" "Пакет" "Среднее (с)" "Прогонов"
    echo "─────────────────────────────────────────────────"
    awk -F'\t' '{sum[$1]+=$2; cnt[$1]++} END {for (p in sum) printf "%-30s %10.2f %10d\n", p, sum[p]/cnt[p], cnt[p]}' \
        "$SBU_FILE" | sort -k2 -n
}

#------------------------------------------------------------------------------
# CLI
#------------------------------------------------------------------------------
case "${1:-}" in
    estimate) shift; estimate_total "$@" ;;
    stats)    show_stats ;;
    reset)    rm -f "$SBU_FILE" "$SBU_REFERENCE"; echo "Сброшено" ;;
    *) echo "Использование: $0 {estimate <pkg...>|stats|reset}"; exit 1 ;;
esac