"""FastAPI REST API + WebSocket + Web UI."""
from __future__ import annotations

import asyncio
import json
from datetime import datetime
from pathlib import Path

from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect
from fastapi.responses import HTMLResponse, PlainTextResponse, FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from prometheus_client import generate_latest, CONTENT_TYPE_LATEST

from .config import load_settings, load_tasks_config, filter_phases
from .dag import DAG, DAGError
from .executor import make_executor
from .metrics import metrics
from .scheduler import BuildScheduler
from .state import StateStore
from .task import Task

settings = load_settings()
store = StateStore(settings.db_path)

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


class BuildResponse(BaseModel):
    build_id: str
    status: str


# ---------- Health ----------

@app.get("/health")
async def health():
    return {"status": "ok", "time": datetime.utcnow().isoformat()}


# ---------- Metrics ----------

@app.get("/metrics")
async def prometheus_metrics():
    return PlainTextResponse(
        generate_latest().decode(),
        media_type=CONTENT_TYPE_LATEST,
    )


# ---------- Builds ----------

@app.post("/api/builds", response_model=BuildResponse)
async def start_build(req: StartBuildRequest):
    try:
        parsed, _ = load_tasks_config(req.config_path)
        tasks = filter_phases(parsed, req.phases)
    except Exception as e:
        raise HTTPException(400, f"Ошибка конфигурации: {e}")

    if not tasks:
        raise HTTPException(400, "Нет задач для выполнения")

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

    scheduler = BuildScheduler(
        dag=dag,
        executor=executor,
        store=store,
        logs_dir=Path(settings.logs_dir),
        max_parallel=req.max_parallel or settings.max_parallel,
        stop_on_error=req.stop_on_error if req.stop_on_error is not None else settings.stop_on_error,
        on_event=lambda level, tid, msg: asyncio.create_task(_broadcast(scheduler.build_id, level, tid, msg)),
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
    return (WEB_DIR / "index.html").read_text()


@app.get("/app.js")
async def app_js():
    return FileResponse(WEB_DIR / "app.js", media_type="application/javascript")