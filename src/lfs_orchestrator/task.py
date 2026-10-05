"""Task definitions for the DAG scheduler."""
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum
from typing import Any


class TaskState(str, Enum):
    PENDING  = "pending"
    RUNNING  = "running"
    DONE     = "done"
    FAILED   = "failed"
    SKIPPED  = "skipped"
    RETRYING = "retrying"


@dataclass
class Task:
    """A single build task (one package or one phase)."""
    name: str
    script: str
    args: list[str] = field(default_factory=list)
    deps: list[str] = field(default_factory=list)
    env: dict[str, str] = field(default_factory=dict)
    timeout: int = 7200
    retries: int = 0
    sbu_estimate: float = 0.0
    phase: str = ""

    # Runtime state
    state: TaskState = TaskState.PENDING
    started_at: datetime | None = None
    finished_at: datetime | None = None
    duration: float = 0.0
    exit_code: int | None = None
    log_path: str | None = None
    attempts: int = 0
    error: str | None = None

    @property
    def id(self) -> str:
        """Unique ID: phase/task."""
        return f"{self.phase}/{self.name}" if self.phase else self.name

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "name": self.name,
            "phase": self.phase,
            "state": self.state.value,
            "script": self.script,
            "args": self.args,
            "deps": self.deps,
            "sbu_estimate": self.sbu_estimate,
            "started_at": self.started_at.isoformat() if self.started_at else None,
            "finished_at": self.finished_at.isoformat() if self.finished_at else None,
            "duration": round(self.duration, 2),
            "exit_code": self.exit_code,
            "attempts": self.attempts,
            "error": self.error,
        }