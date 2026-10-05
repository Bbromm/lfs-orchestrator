"""SQLite state store: сборки, задачи, события."""
from __future__ import annotations

import json
import sqlite3
from datetime import datetime
from pathlib import Path
from typing import Any

from .task import Task, TaskState


SCHEMA = """
CREATE TABLE IF NOT EXISTS builds (
    id TEXT PRIMARY KEY,
    status TEXT NOT NULL,
    config TEXT NOT NULL,
    created_at TEXT NOT NULL,
    started_at TEXT,
    finished_at TEXT,
    current_phase TEXT,
    progress REAL DEFAULT 0.0
);

CREATE TABLE IF NOT EXISTS tasks (
    build_id TEXT NOT NULL,
    task_id TEXT NOT NULL,
    phase TEXT NOT NULL,
    name TEXT NOT NULL,
    state TEXT NOT NULL,
    script TEXT,
    args TEXT,
    deps TEXT,
    started_at TEXT,
    finished_at TEXT,
    duration REAL DEFAULT 0.0,
    exit_code INTEGER,
    log_path TEXT,
    attempts INTEGER DEFAULT 0,
    error TEXT,
    PRIMARY KEY (build_id, task_id),
    FOREIGN KEY (build_id) REFERENCES builds(id)
);

CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    build_id TEXT NOT NULL,
    ts TEXT NOT NULL,
    task_id TEXT,
    level TEXT,
    message TEXT
);

CREATE INDEX IF NOT EXISTS idx_events_build ON events(build_id, ts);
CREATE INDEX IF NOT EXISTS idx_tasks_build ON tasks(build_id);
"""


class StateStore:
    def __init__(self, db_path: str | Path):
        self.db_path = Path(db_path)
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        self._init_db()

    def _conn(self) -> sqlite3.Connection:
        conn = sqlite3.connect(str(self.db_path), timeout=30)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA journal_mode=WAL")
        return conn

    def _init_db(self) -> None:
        with self._conn() as c:
            c.executescript(SCHEMA)

    # ---------- Builds ----------

    def create_build(self, build_id: str, config: dict) -> None:
        with self._conn() as c:
            c.execute(
                "INSERT INTO builds (id, status, config, created_at) VALUES (?, ?, ?, ?)",
                (build_id, "pending", json.dumps(config), datetime.utcnow().isoformat()),
            )

    def update_build(self, build_id: str, **fields) -> None:
        allowed = {"status", "started_at", "finished_at", "current_phase", "progress"}
        sets = ", ".join(f"{k}=?" for k in fields if k in allowed)
        values = [v for k, v in fields.items() if k in allowed]
        if not sets:
            return
        with self._conn() as c:
            c.execute(f"UPDATE builds SET {sets} WHERE id=?", (*values, build_id))

    def get_build(self, build_id: str) -> dict | None:
        with self._conn() as c:
            row = c.execute("SELECT * FROM builds WHERE id=?", (build_id,)).fetchone()
        if not row:
            return None
        data = dict(row)
        data["config"] = json.loads(data["config"])
        data["tasks"] = self.get_tasks(build_id)
        return data

    def list_builds(self, limit: int = 50) -> list[dict]:
        with self._conn() as c:
            rows = c.execute(
                "SELECT * FROM builds ORDER BY created_at DESC LIMIT ?", (limit,)
            ).fetchall()
        return [dict(r) for r in rows]

    # ---------- Tasks ----------

    def save_task(self, build_id: str, task: Task) -> None:
        with self._conn() as c:
            c.execute("""
                INSERT OR REPLACE INTO tasks
                (build_id, task_id, phase, name, state, script, args, deps,
                 started_at, finished_at, duration, exit_code, log_path,
                 attempts, error)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, (
                build_id, task.id, task.phase, task.name, task.state.value,
                task.script, json.dumps(task.args), json.dumps(task.deps),
                task.started_at.isoformat() if task.started_at else None,
                task.finished_at.isoformat() if task.finished_at else None,
                task.duration, task.exit_code, task.log_path,
                task.attempts, task.error,
            ))

    def get_tasks(self, build_id: str) -> list[dict]:
        with self._conn() as c:
            rows = c.execute(
                "SELECT * FROM tasks WHERE build_id=? ORDER BY rowid", (build_id,)
            ).fetchall()
        return [dict(r) for r in rows]

    def task_log_path(self, build_id: str, task_id: str) -> str | None:
        with self._conn() as c:
            row = c.execute(
                "SELECT log_path FROM tasks WHERE build_id=? AND task_id=?",
                (build_id, task_id),
            ).fetchone()
        return row["log_path"] if row else None

    # ---------- Events ----------

    def log_event(self, build_id: str, message: str,
                  task_id: str | None = None, level: str = "info") -> None:
        with self._conn() as c:
            c.execute(
                "INSERT INTO events (build_id, ts, task_id, level, message) VALUES (?,?,?,?,?)",
                (build_id, datetime.utcnow().isoformat(), task_id, level, message),
            )

    def get_events(self, build_id: str, since_id: int = 0, limit: int = 500) -> list[dict]:
        with self._conn() as c:
            rows = c.execute(
                "SELECT * FROM events WHERE build_id=? AND id>? ORDER BY id LIMIT ?",
                (build_id, since_id, limit),
            ).fetchall()
        return [dict(r) for r in rows]