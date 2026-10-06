#!/bin/bash
set -euo pipefail

# В контейнере /mnt/lfs — это volume, монтируемый снаружи
if [[ ! -d /mnt/lfs ]]; then
    echo "ОШИБКА: Смонтируйте volume в /mnt/lfs: -v /path/to/lfs:/mnt/lfs"
    exit 1
fi

# Проверка привилегий
if ! mount --bind / /tmp/test 2>/dev/null; then
    echo "ПРЕДУПРЕЖДЕНИЕ: контейнер должен запускаться с --privileged"
    echo "docker run --privileged ..."
    exit 1
fi
umount /tmp/test 2>/dev/null || true

# Запуск мастер-скрипта
exec bash /root/lfs-build/build-lfs.sh "$@"