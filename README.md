# LFS Orchestrator

Промышленный оркестратор для сборки Linux From Scratch 13.1-systemd.

## Возможности

- **DAG-планировщик** — параллельная сборка независимых пакетов
- **Точное возобновление** — продолжение с любой точки
- **REST API** — управление через HTTP
- **Web UI** — мониторинг в реальном времени
- **Prometheus метрики** — интеграция с Grafana
- **Множество исполнителей** — local, chroot, SSH, Docker

## Быстрый старт

```bash
# 1. Клонирование
git clone https://github.com/Bbromm/lfs-orchestrator.git
cd lfs-orchestrator

# 2. Конфигурация
cp .env.example .env
# отредактируйте .env

# 3. Запуск стека (orchestrator + prometheus + grafana)
docker compose up -d

# 4. Открыть Web UI
open http://localhost:8000
# Grafana: http://localhost:3000 (admin/admin)
# Prometheus: http://localhost:9090

# 5. Запустить сборку
curl -X POST http://localhost:8000/api/builds \
    -H "Content-Type: application/json" \
    -d '{"phases": ["phase5","phase6"], "run_tests": false}'
