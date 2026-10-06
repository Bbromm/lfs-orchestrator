#!/bin/bash
###############################################################################
# notifier.sh — Отправка уведомлений о статусе сборки
# Подключается как hook в build-lfs.sh
###############################################################################
set -euo pipefail

# --- Конфигурация (переопределяется через переменные окружения) -----------
NOTIFY_EMAIL="${NOTIFY_EMAIL:-}"                  # user@example.com
NOTIFY_TELEGRAM_BOT="${NOTIFY_TELEGRAM_BOT:-}"    # <bot_token>
NOTIFY_TELEGRAM_CHAT="${NOTIFY_TELEGRAM_CHAT:-}"  # <chat_id>
NOTIFY_WEBHOOK_URL="${NOTIFY_WEBHOOK_URL:-}"      # https://hooks.slack.com/...

#------------------------------------------------------------------------------
# Email (требует mailutils или sendmail)
#------------------------------------------------------------------------------
send_email() {
    local subject="$1" body="$2"
    [[ -z "$NOTIFY_EMAIL" ]] && return 0
    if command -v mail >/dev/null; then
        echo "$body" | mail -s "$subject" "$NOTIFY_EMAIL"
    elif [[ -x /usr/sbin/sendmail ]]; then
        {
            echo "To: $NOTIFY_EMAIL"
            echo "Subject: $subject"
            echo ""
            echo "$body"
        } | /usr/sbin/sendmail -t
    fi
}

#------------------------------------------------------------------------------
# Telegram
#------------------------------------------------------------------------------
send_telegram() {
    local text="$1"
    [[ -z "$NOTIFY_TELEGRAM_BOT" || -z "$NOTIFY_TELEGRAM_CHAT" ]] && return 0
    curl -s -X POST "https://api.telegram.org/bot${NOTIFY_TELEGRAM_BOT}/sendMessage" \
        -d "chat_id=${NOTIFY_TELEGRAM_CHAT}" \
        -d "text=${text}" \
        -d "parse_mode=Markdown" >/dev/null || true
}

#------------------------------------------------------------------------------
# Универсальный webhook (Slack/Discord/Mattermost)
#------------------------------------------------------------------------------
send_webhook() {
    local text="$1"
    [[ -z "$NOTIFY_WEBHOOK_URL" ]] && return 0
    curl -s -X POST "$NOTIFY_WEBHOOK_URL" \
        -H 'Content-Type: application/json' \
        -d "{\"text\": \"${text}\"}" >/dev/null || true
}

#------------------------------------------------------------------------------
# Публичный API
#------------------------------------------------------------------------------
notify_phase_start() {
    local phase="$1"
    local msg="⚙ *LFS build* — начало фазы: \`${phase}\`"
    send_telegram "$msg"
    send_webhook "$msg"
    send_email "LFS build: начало ${phase}" "$msg"
}

notify_phase_done() {
    local phase="$1" duration="$2"
    local msg="✅ *LFS build* — фаза \`${phase}\` завершена за ${duration}"
    send_telegram "$msg"
    send_webhook "$msg"
    send_email "LFS build: ${phase} завершена" "$msg"
}

notify_phase_failed() {
    local phase="$1" log="$2"
    local tail="$(tail -n 20 "$log" 2>/dev/null | sed 's/`/\\`/g')"
    local msg="❌ *LFS build* — ОШИБКА в фазе \`${phase}\`\`\`${tail}\`\`\`"
    send_telegram "$msg"
    send_webhook "$msg"
    send_email "LFS build: ОШИБКА в ${phase}" "$msg"
}

notify_build_done() {
    local total_time="$1"
    local msg="🎉 *LFS build завершена!* Общее время: ${total_time}"
    send_telegram "$msg"
    send_webhook "$msg"
    send_email "LFS build завершена" "$msg"
}

# При прямом запуске — CLI-интерфейс
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        start)  notify_phase_start  "${2:-?}" ;;
        done)   notify_phase_done   "${2:-?}" "${3:-?}" ;;
        failed) notify_phase_failed "${2:-?}" "${3:-/dev/null}" ;;
        finish) notify_build_done   "${2:-?}" ;;
        test)   send_telegram "🧪 Тестовое уведомление LFS build"; echo "Отправлено (если настроено)" ;;
        *) echo "Использование: $0 {start|done|failed|finish|test} ..."; exit 1 ;;
    esac
fi