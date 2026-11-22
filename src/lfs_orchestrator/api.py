"""FastAPI REST API + WebSocket + Web UI."""
from __future__ import annotations

import asyncio
import json
import os
from datetime import datetime
from pathlib import Path

from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect
from fastapi.responses import HTMLResponse, PlainTextResponse, FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from prometheus_client import generate_latest, CONTENT_TYPE_LATEST

from .config import load_settings, load_tasks_config, filter_phases
from .dag import DAG, DAGError
from .executor import Executor, make_executor
from .metrics import metrics
from .scheduler import BuildScheduler
from .settings_store import SettingsStore
from .state import StateStore
from .task import Task

settings = load_settings()
store = StateStore(settings.db_path)
app_settings = SettingsStore(Path("data/settings.json"), Path(settings.root))

app = FastAPI(title="LFS Orchestrator", version="1.0.0")

# ---- Active builds registry ----
active_builds: dict[str, BuildScheduler] = {}


# ---------- Models ----------

class StartBuildRequest(BaseModel):
    phases: list[str] = Field(default_factory=lambda: ["phase5"])
    config_path: str = "config/lfs-default.yaml"
    max_parallel: int | None = None
    run_tests: bool | None = None
    stop_on_error: bool | None = None
    force: bool = False 

class BuildResponse(BaseModel):
    build_id: str
    status: str


# ---------- Health ----------

@app.get("/health")
async def health():
    return {"status": "ok", "time": datetime.utcnow().isoformat()}


@app.get("/api/phases")
async def list_phases(config_path: str = "config/lfs-default.yaml"):
    """Фазы из конфига: какие есть и сколько в них задач.

    default_phases — что предложить в интерфейсе: первая фаза, где ещё
    есть несобранные задачи.
    """
    try:
        parsed, _ = load_tasks_config(config_path)
    except Exception as e:
        raise HTTPException(400, f"Ошибка конфигурации: {e}")

    markers_root = Path(settings.root) / ".lfs-state"
    out = []
    default: list[str] = []
    for name, ph in parsed.items():
        tasks = ph["tasks"]
        pending = [
            t for t in tasks
            if not (markers_root / t.phase / f"{t.name}.done").exists()
        ]
        out.append({
            "name": name,
            "title": ph.get("name", name),
            "tasks": len(tasks),
            "pending": len(pending),
        })
        if pending and not default:
            default.append(name)

    # вместе с первой незавершённой добавим следующие, чтобы сборка шла подряд
    if default:
        idx = [p["name"] for p in out].index(default[0])
        default = [p["name"] for p in out[idx:]]

    return {
        "phases": out,
        "default_phases": default or ([out[-1]["name"]] if out else []),
        "markers_dir": str(markers_root),
        "executor": settings.executor,
    }


# ---------- Metrics ----------

@app.get("/metrics")
async def prometheus_metrics():
    return PlainTextResponse(
        generate_latest().decode(),
        media_type=CONTENT_TYPE_LATEST,
    )


# ---------- Settings (то, что спрашиваем в интерфейсе) ----------

@app.get("/api/settings")
async def get_settings():
    return app_settings.public()


@app.put("/api/settings")
async def put_settings(patch: dict):
    try:
        saved = app_settings.save(patch)
    except ValueError as exc:
        raise HTTPException(400, str(exc))
    return {
        "ok": True,
        "settings": app_settings.public(),
        "published_to": str(app_settings.lfs_path),
        "user": saved["user"]["name"] or None,
    }


# ---------- Builds ----------

@app.post("/api/builds", response_model=BuildResponse)
async def start_build(req: StartBuildRequest):
    try:
        parsed, _ = load_tasks_config(req.config_path)
    except Exception as e:
        raise HTTPException(400, f"Ошибка конфигурации: {e}")

    # Запрошенные фазы могут ссылаться на задачи предыдущих. Берём набор
    # от начала списка до последней запрошенной фазы: уже собранное
    # пропустится по маркерам, а зависимости всегда разрешатся.
    order = list(parsed)
    requested = [p for p in req.phases if p in parsed]
    unknown = [p for p in req.phases if p not in parsed]
    if unknown:
        raise HTTPException(400, f"Неизвестные фазы: {', '.join(unknown)}")
    if not requested:
        raise HTTPException(400, "Нет фаз для выполнения")

    # Две сборки одновременно работать не могут: они пишут в один и тот же
    # $LFS/sources и удаляют каталоги друг у друга (make теряет рабочий каталог).
    if active_builds:
        running = ", ".join(sorted(active_builds))
        raise HTTPException(
            409,
            f"Уже идёт сборка ({running}). Остановите её и дождитесь завершения.",
        )

    last = max(order.index(p) for p in requested)
    phases = order[: last + 1]

    try:
        tasks = filter_phases(parsed, phases)
    except Exception as e:
        raise HTTPException(400, f"Ошибка конфигурации: {e}")

    if not tasks:
        raise HTTPException(400, "Нет задач для выполнения")

    # Настройки из интерфейса превращаются в переменные окружения задач:
    # сеть и имя машины для главы 9, пользователь и компоненты для главы 12.
    for task in tasks:
        phase_env = app_settings.env_for_phase(task.phase)
        if phase_env:
            task.env = {**task.env, **phase_env}

    try:
        dag = DAG(tasks)
    except DAGError as e:
        raise HTTPException(400, f"Некорректный граф: {e}")

    executor = make_executor(
        settings.executor,
        cwd=Path.cwd(),
        lfs_root=settings.root,
        host=settings.ssh_host,
        user=settings.ssh_user,
        key=settings.ssh_key,
    )

    # Исполнители для задач, которым нужен другой контекст:
    #   lfs    — главы 2–6, на хосте от пользователя lfs
    #   chroot — главы 7B–11, внутри $LFS
    lfs_env = {
        "HOME": "/home/lfs",
        "USER": "lfs",
        "LOGNAME": "lfs",
        "TERM": "xterm",
        "LFS": settings.root,
        "LFS_TGT": os.environ.get("LFS_TGT", "x86_64-lfs-linux-gnu"),
        "LC_ALL": "POSIX",
        "PATH": f"{settings.root}/tools/bin:/usr/bin:/bin",
        "CONFIG_SITE": f"{settings.root}/usr/share/config.site",
        "MAKEFLAGS": f"-j{os.cpu_count() or 1}",
    }
    executors: dict[str, Executor] = {}
    for kind in ("root", "lfs", "chroot", "local"):
        try:
            executors[kind] = make_executor(
                kind,
                cwd=Path.cwd(),
                lfs_root=settings.root,
                env=lfs_env,
                host=settings.ssh_host,
                user=settings.ssh_user,
                key=settings.ssh_key,
            )
        except Exception:
            pass

    scheduler = BuildScheduler(
        dag=dag,
        executor=executor,
        executors=executors,
        store=store,
        logs_dir=Path(settings.logs_dir),
        max_parallel=req.max_parallel or settings.max_parallel,
        stop_on_error=req.stop_on_error if req.stop_on_error is not None else settings.stop_on_error,
        on_event=lambda level, tid, msg: asyncio.create_task(_broadcast(scheduler.build_id, level, tid, msg)),
        markers_dir=Path(settings.root) / ".lfs-state",
        force=req.force,
        force_phases=set(requested) if req.force else None,
    )
    active_builds[scheduler.build_id] = scheduler

    # запускаем в фоне
    asyncio.create_task(_run_scheduler(scheduler))

    return BuildResponse(build_id=scheduler.build_id, status="started")


async def _run_scheduler(scheduler: BuildScheduler):
    try:
        ok = await scheduler.run()
        scheduler.store.update_build(
            scheduler.build_id,
            status="done" if ok else "failed",
        )
    finally:
        active_builds.pop(scheduler.build_id, None)


@app.get("/api/builds")
async def list_builds(limit: int = 50):
    return store.list_builds(limit)


@app.get("/api/builds/{build_id}")
async def get_build(build_id: str):
    b = store.get_build(build_id)
    if not b:
        raise HTTPException(404, "Сборка не найдена")
    if build_id in active_builds:
        b["live"] = True
        b["dag_dot"] = active_builds[build_id].dag.to_dot()
        b["dag_stats"] = active_builds[build_id].dag.stats()
    return b


@app.post("/api/builds/{build_id}/stop")
async def stop_build(build_id: str):
    if build_id not in active_builds:
        raise HTTPException(404, "Активная сборка не найдена")
    active_builds[build_id].request_stop()
    return {"status": "stopping"}


@app.post("/api/builds/{build_id}/pause")
async def pause_build(build_id: str):
    if build_id not in active_builds:
        raise HTTPException(404, "Активная сборка не найдена")
    active_builds[build_id].request_pause()
    return {"status": "paused"}


@app.post("/api/builds/{build_id}/resume")
async def resume_build(build_id: str):
    if build_id not in active_builds:
        raise HTTPException(404, "Активная сборка не найдена")
    active_builds[build_id].request_resume()
    return {"status": "running"}


@app.get("/api/builds/{build_id}/events")
async def get_events(build_id: str, since_id: int = 0, limit: int = 500):
    return store.get_events(build_id, since_id, limit)


@app.get("/api/builds/{build_id}/tasks/{task_id:path}/log")
async def get_task_log(build_id: str, task_id: str, tail: int = 200):
    log_path = store.task_log_path(build_id, task_id)
    if not log_path or not Path(log_path).exists():
        raise HTTPException(404, "Лог не найден")
    lines = Path(log_path).read_text(errors="replace").splitlines()
    return PlainTextResponse("\n".join(lines[-tail:]))


@app.get("/api/builds/{build_id}/dag.dot")
async def get_dag_dot(build_id: str):
    if build_id in active_builds:
        return PlainTextResponse(active_builds[build_id].dag.to_dot())
    # реконструкция из БД не поддерживается — только для активных
    raise HTTPException(404, "DAG доступен только для активных сборок")


# ---------- WebSocket ----------

class WSManager:
    def __init__(self):
        self.connections: dict[str, list[WebSocket]] = {}

    async def connect(self, build_id: str, ws: WebSocket):
        await ws.accept()
        self.connections.setdefault(build_id, []).append(ws)

    def disconnect(self, build_id: str, ws: WebSocket):
        if build_id in self.connections:
            self.connections[build_id] = [c for c in self.connections[build_id] if c is not ws]

    async def broadcast(self, build_id: str, message: dict):
        for ws in list(self.connections.get(build_id, [])):
            try:
                await ws.send_json(message)
            except Exception:
                self.disconnect(build_id, ws)


ws_manager = WSManager()


async def _broadcast(build_id: str, level: str, task_id: str, message: str):
    await ws_manager.broadcast(build_id, {
        "ts": datetime.utcnow().isoformat(),
        "level": level,
        "task_id": task_id,
        "message": message,
    })


@app.websocket("/ws/logs/{build_id}")
async def ws_logs(ws: WebSocket, build_id: str):
    await ws_manager.connect(build_id, ws)
    try:
        while True:
            await ws.receive_text()  # heartbeat
    except WebSocketDisconnect:
        ws_manager.disconnect(build_id, ws)


# ---------- Web UI ----------

WEB_DIR = Path(__file__).parent / "web"


@app.get("/", response_class=HTMLResponse)
async def index():
    return HTMLResponse(
        (WEB_DIR / "index.html").read_text(),
        headers={"Cache-Control": "no-store, must-revalidate"},
    )


@app.get("/app.js")
async def app_js():
    # no-store: иначе браузер держит старый интерфейс после правок
    return FileResponse(
        WEB_DIR / "app.js",
        media_type="application/javascript",
        headers={"Cache-Control": "no-store, must-revalidate"},
    )
