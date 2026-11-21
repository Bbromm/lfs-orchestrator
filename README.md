# LFS Orchestrator

Оркестратор сборки **Linux From Scratch 13.1-systemd** на Debian-хосте:
DAG-планировщик с параллельной сборкой независимых пакетов, точное
возобновление с любой задачи, REST API, Web UI и метрики Prometheus.

Проверено end-to-end: 9 фаз, 108 задач — от разметки чистого диска до
загружающейся системы с XFCE. Разбор всех грабель и рецепты — в
[../LFS-BUILD-JOURNAL.md](../LFS-BUILD-JOURNAL.md).

---

## Возможности

- **DAG-планировщик** — параллельная сборка независимых задач, порядок из `deps`
- **Точное возобновление** — состояние в SQLite, повторный запуск продолжает с места падения
- **REST API и Web UI** — запуск, пауза, остановка, живой лог задачи (SSE)
- **Метрики Prometheus** — `/metrics` на том же порту
- **Исполнители** — `chroot` (по умолчанию), `local`, `lfs` (от пользователя `lfs`), `root`, `ssh`
- **Пер-задачные таймауты** — `exit_code: 124` при превышении

---

## Что нужно на хосте

| Требование | Значение |
|---|---|
| ОС | Linux x86_64 (проверено на Debian 13.7 в VMware) |
| Права | root — скрипт размечает диск |
| Диск под `$LFS` | 40+ GB, **содержимое будет стёрто** |
| Пакеты | `bash`, `coreutils`, `util-linux` (`lsblk`, `findmnt`), `xz`, `wget`, `git` |
| Python | `python3` + `venv` |
| Docker | **не нужен** — сборка идёт прямо на хосте |

`--install-deps` доставляет недостающие сборочные пакеты через `apt`.

---

## Быстрый старт

```bash
git clone <репозиторий> lfs-orchestrator
cd lfs-orchestrator

sudo bash prepare-and-run.sh --list-disks
sudo bash prepare-and-run.sh --disk /dev/sda --download
```

`prepare-and-run.sh` проходит шаги сам:

1. проверяет сборочные инструменты на хосте;
2. выбирает и размечает диск (GPT: `/boot` ext2 + `/` ext4);
3. создаёт ФС, монтирует в `/mnt/lfs`, добавляет записи в `/etc/fstab`;
4. готовит `$LFS/sources` (`--download` — качает по `wget-list-lfs-13.1-systemd.txt`)
   и копирует `scripts/` внутрь `$LFS/sources/scripts`;
5. выполняет главу 4: структура каталогов и пользователь `lfs`;
6. создаёт `.venv`, ставит зависимости, пишет `.env`;
7. поднимает оркестратор (`uvicorn`) на порту **8100**.

Дальше — Web UI: <http://localhost:8100>.

### Параметры

| Параметр | Назначение |
|---|---|
| `--disk <dev>` | диск для LFS (без него — интерактивный выбор) |
| `--list-disks` | показать доступные диски и выйти |
| `--download` | скачать исходники по wget-list |
| `--sources <dir>` | взять tarball'ы из другого каталога |
| `--executor <kind>` | `chroot` (по умолчанию), `local`, `lfs`, `root`, `ssh` |
| `--port <n>` | порт Web UI (по умолчанию 8100) |
| `--no-run` | только подготовить, сервер не запускать |
| `--dry-run` | показать план, ничего не меняя |
| `--skip-partition`, `--skip-mount`, `--skip-fstab` | не трогать диск / монтирование / fstab |
| `--skip-sources`, `--skip-chapter4` | пропустить соответствующие шаги |
| `--install-deps` | доставить недостающие пакеты через `apt` |
| `--yes`, `-y` | без подтверждений |

> Разметка уничтожает данные на выбранном диске. Скрипт отказывается работать
> с диском, на котором смонтирован `/`.

### Настройки (.env)

Шаблон — [.env.example](./.env.example); существующий `.env` скрипт не
перезаписывает. Все переменные читаются с префиксом `LFS_` (`pydantic`,
`env_prefix="LFS_"`), поэтому `DB_PATH=` или `MAX_PARALLEL=` не работают —
нужны `LFS_DB_PATH=` и `LFS_MAX_PARALLEL=`.

---

## Фазы и задачи

Конфигурация — [config/lfs-default.yaml](./config/lfs-default.yaml): 9 фаз,
108 задач. Порядок задаётся `deps`, а не номером фазы.

| Фаза | Задач | Что делает | Скрипт |
|---|---:|---|---|
| `phase5` | 5 | глава 5 — кросс-инструментарий | [scripts/install-chapter5.sh](./scripts/install-chapter5.sh) |
| `phase6` | 17 | глава 6 — временные инструменты | [scripts/install-chapter6.sh](./scripts/install-chapter6.sh) |
| `phase7` | 1 | глава 7 — chroot и временные инструменты | [scripts/install-chapter7.sh](./scripts/install-chapter7.sh) |
| `phase8` | 80 | глава 8 — базовое системное ПО | [scripts/install-chapter8.sh](./scripts/install-chapter8.sh) |
| `phase9` | 1 | глава 9 — конфигурация системы | [scripts/phase5-chapter9.sh](./scripts/phase5-chapter9.sh) |
| `phase10` | 1 | глава 10 — ядро и GRUB | [scripts/phase6-chapter10.sh](./scripts/phase6-chapter10.sh) |
| `phase11` | 1 | финализация | [scripts/postinstall.sh](./scripts/postinstall.sh) |
| `phase12` | 1 | после базы: пользователь, sudo, curl, Nix, SSH | [scripts/install-phase12.sh](./scripts/install-phase12.sh) |
| `phase13` | 1 | рабочий стол: PAM, Xorg + XFCE через Nix, polkit, автозапуск | [scripts/install-phase13-desktop.sh](./scripts/install-phase13-desktop.sh) |

`phase12` и `phase13` — надстройки над книгой: после главы 11 в системе нет ни
SSH, ни графики, ни способа поставить пакеты. Nix выбран потому, что в LFS
нет пакетного менеджера, а `phase13` собирается таким образом, чтобы не
пересобирать Xorg и XFCE из исходников.

Проверка конфигурации перед сборкой:

```bash
python3 check_dag.py config/lfs-default.yaml      # скрипты, --only, сборка DAG
python3 check_order.py config/lfs-default.yaml    # зависимости «раньше по книге»
python3 check_sources.py                          # наличие архивов и md5
```

---

## Web UI и REST API

Порт задаётся `--port` у `prepare-and-run.sh` или `LFS_ORCH_PORT` в `.env`, по умолчанию **8100**.

| Что | Адрес |
|---|---|
| Web UI | <http://localhost:8100/> |
| Health | <http://localhost:8100/health> |
| Метрики | <http://localhost:8100/metrics> |
| Фазы | <http://localhost:8100/api/phases> |

Ручки: `POST /api/builds`, `GET /api/builds`, `GET /api/builds/{id}`,
`POST /api/builds/{id}/{stop,pause,resume}`, `GET /api/builds/{id}/events` (SSE),
`GET /api/builds/{id}/tasks/{task}/log`, `GET /api/builds/{id}/dag.dot`,
`GET|PUT /api/settings`.

```bash
curl -X POST http://localhost:8100/api/builds \
    -H 'Content-Type: application/json' \
    -d '{"phase": "phase5"}'

curl -s http://localhost:8100/api/builds/<build_id> | python3 -m json.tool
```

CLI без сервера:

```bash
PYTHONPATH=src .venv/bin/python -m lfs_orchestrator run -p phase5 --max-parallel 1
PYTHONPATH=src .venv/bin/python -m lfs_orchestrator list-builds
PYTHONPATH=src .venv/bin/python -m lfs_orchestrator show <build_id>
```

Логи задач: `logs/<build_id>/<task_id>.log`.

---

## Вспомогательные скрипты

| Скрипт | Зачем |
|---|---|
| `fetch-extras.sh` | докачивает то, чего нет в базовом LFS: `sudo`, `openssh`, `curl`, `wget`, сертификаты, Linux-PAM. `--xorg` добавляет архивы Xorg, `--list` показывает список. Запускать на хосте **до** `phase12` |
| `check_dag.py` | проверяет, что скрипты и `--only`-стадии из конфига существуют, и что DAG собирается |
| `check_order.py` | ищет зависимости на пакеты, которые скрипт собирает позже |
| `check_sources.py` | сверяет `sources/` с требуемым скриптами и проверяет md5 |
| `install-pam.sh` | Linux-PAM + пересборка `systemd`/`shadow`/`openssh` с PAM. Без аргументов — план, `--yes` — выполнить, `--rollback` — откат. Фаза 13 вызывает его сама (стадия `pam`) |
| `lfs-config.sh` | общие переменные для скриптов главы 4 |

---

## Правила написания скриптов стадий

Скрипты `install-chapterN.sh` обязаны:

1. Поддерживать `--only <stage>` — оркестратор всегда передаёт именно его.
2. Не задавать интерактивных вопросов при отсутствии TTY (`[[ -t 0 ]]`),
   иначе задача упадёт на `read` с EOF.
3. Возвращать 0 при успехе и ненулевой код при ошибке (`124` ставит сам
   оркестратор по таймауту).
4. Определять `log`/`ok`/`warn`/`die` **до** разбора аргументов.
5. Быть сохранёнными с **LF**, а не CRLF: иначе внутри chroot скрипт падает с
   `bash: scripts/install-chapter8.sh: /bin/bash^M: bad interpreter`.

Шаблон верхней части:

```bash
#!/bin/bash
set -euo pipefail

LFS="${LFS:-/mnt/lfs}"
LFS_TGT="${LFS_TGT:-$(uname -m)-lfs-linux-gnu}"
SOURCES="$LFS/sources"
LOG_DIR="$SOURCES/logs"

log()  { echo -e "[$(date +%H:%M:%S)] $*"; }
ok()   { echo -e "[OK] $*"; }
warn() { echo -e "[WARN] $*"; }
die()  { echo -e "[ERROR] $*" >&2; exit 2; }

ONLY=""
ASSUME_YES="${ASSUME_YES:-0}"
[[ -t 0 ]] || ASSUME_YES=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --only)    ONLY="${2:-}"; [[ -n "$ONLY" ]] || die "--only требует имя стадии"; shift 2 ;;
        --yes|-y)  ASSUME_YES=1; shift ;;
        -h|--help) echo "Использование: $0 [--only <stage>] [--yes]"; exit 0 ;;
        *)         die "Неизвестный аргумент: $1" ;;
    esac
done

should_run() { [[ -z "$ONLY" || "$ONLY" == "$1" ]]; }
```

Обязательный `main` и запуск:

```bash
main() {
    check_prerequisites
    should_run binutils-pass1 && build_binutils_pass1
    should_run gcc-pass1      && build_gcc_pass1
    should_run linux-headers  && build_linux_headers
    should_run glibc          && build_glibc
    should_run libstdcpp      && build_libstdcpp
}

main "$@" 2>&1 | tee "$MAIN_LOG"
exit "${PIPESTATUS[0]}"
```

---

## Конфигурация задач

```yaml
version: 13.1-systemd
defaults:
  executor: chroot
  timeout: 7200
  retries: 0
  env:
    LFS: /mnt/lfs
    LFS_TGT: x86_64-lfs-linux-gnu

phases:
  phase5:
    executor: lfs
    name: Глава 5 — Кросс-инструментарий
    tasks:
      binutils-pass1:
        script: scripts/install-chapter5.sh
        args:
        - --only
        - binutils-pass1
        deps: []
        sbu_estimate: 1.0
        timeout: 3600
      gcc-pass1:
        script: scripts/install-chapter5.sh
        args:
        - --only
        - gcc-pass1
        deps:
        - phase5/binutils-pass1
        timeout: 7200
```

Правила:

- `args` всегда содержит `["--only", "<stage>"]`;
- `deps` — полные имена задач `<фаза>/<задача>`;
- `timeout` — жёсткий лимит в секундах, по истечении `exit_code: 124`;
- `sbu_estimate` — оценка времени, информативно;
- `executor` можно задать на уровне фазы и на уровне задачи.

---

## Устранение неполадок

### Задача падает: `/bin/bash^M: bad interpreter`

Скрипт сохранён с CRLF. Конвертируйте:

```bash
sed -i 's/\r$//' scripts/*.sh
```

### `Unable to load a failsafe session` в XFCE

Нет шины сеанса или неверный `XDG_CONFIG_DIRS`. В `~/.xinitrc` должно быть:

```sh
XDG_CONFIG_DIRS="/nix/var/nix/profiles/default/etc/xdg:…"   # именно etc/xdg
exec dbus-run-session -- startxfce4
```

Без `dbus-run-session` D-Bus не активирует `xfconfd`, без `etc/xdg` не
находится имя failsafe-сессии.

### В XFCE нет кнопок «Перезагрузка / Выключение»

XFCE спрашивает `CanPowerOff` у `systemd-logind`, тот — у polkit. Проверка:

```bash
busctl list --no-pager | grep -Ei 'login1|PolicyKit'   # у имён должен быть владелец
busctl call org.freedesktop.login1 /org/freedesktop/login1 \
    org.freedesktop.login1.Manager CanPowerOff
```

Типичные причины: нет `polkitd`; в `/etc/dbus-1/system.d/org.freedesktop.PolicyKit1.conf`
право `own` выдано только root, хотя демон работает под `polkituser`; после
`systemctl restart dbus` logind потерял своё имя — помогает
`systemctl restart systemd-logind`.

### `Failed to activate service 'org.freedesktop.login1': timed out`

Тот же случай: logind без имени на шине. Перезапустите `systemd-logind`.

### X не стартует: `No input driver specified`

У Nix-сборки `xorg-server` нет встроенного списка драйверов. Нужен
`/etc/X11/xorg.conf` с `ModulePath` и секциями `InputClass` → `Driver "libinput"`
(подробности в журнале).

### Ядро не пересобирается инкрементально (ошибки objtool)

После правки `.config` нужна чистая пересборка (`make clean`): инкрементальная
ломает objtool.

### Nix качает очень медленно

Норма для этого стенда — ~600 КБ/с, полный Xorg + XFCE занимает ~45 минут.

---

## Журнал сборки

Полная история с диагностикой и рецептами —
[../LFS-BUILD-JOURNAL.md](../LFS-BUILD-JOURNAL.md).