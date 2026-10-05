"""Загрузка конфигурации: YAML (задачи) + .env (настройки)."""
from __future__ import annotations

import os
from pathlib import Path
from typing import Any

import yaml
from pydantic_settings import BaseSettings, SettingsConfigDict

from .task import Task


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_prefix="LFS_", extra="ignore")

    # Orchestrator
    orch_host: str = "0.0.0.0"
    orch_port: int = 8000
    orch_log_level: str = "INFO"

    # Storage
    db_path: str = "/data/orchestrator.db"
    logs_dir: str = "/logs"

    # LFS
    root: str = "/mnt/lfs"
    sources: str = "/mnt/lfs/sources"

    # Executor
    executor: str = "local"
    ssh_host: str = ""
    ssh_user: str = "root"
    ssh_key: str = ""

    # Parallelism
    max_parallel: int = 4
    run_tests: bool = False
    stop_on_error: bool = True


def load_settings() -> Settings:
    return Settings()


def load_tasks_config(yaml_path: str | Path) -> tuple[dict[str, dict], dict[str, Any]]:
    """
    Загружает YAML с фазами/задачами.
    Возвращает (tasks_by_phase, defaults).
    """
    with open(yaml_path) as f:
        data = yaml.safe_load(f)

    defaults = data.get("defaults", {})
    phases = data.get("phases", {})

    parsed_phases: dict[str, dict] = {}
    for phase_name, phase_cfg in phases.items():
        tasks: list[Task] = []
        for task_name, task_cfg in (phase_cfg.get("tasks") or {}).items():
            tasks.append(Task(
                name=task_name,
                phase=phase_name,
                script=task_cfg["script"],
                args=task_cfg.get("args", []),
                deps=task_cfg.get("deps", []),
                env={**defaults.get("env", {}), **task_cfg.get("env", {})},
                timeout=task_cfg.get("timeout", defaults.get("timeout", 7200)),
                retries=task_cfg.get("retries", defaults.get("retries", 0)),
                sbu_estimate=task_cfg.get("sbu_estimate", 0.0),
            ))
        parsed_phases[phase_name] = {
            "name": phase_cfg.get("name", phase_name),
            "max_parallel": phase_cfg.get("max_parallel", defaults.get("max_parallel")),
            "tasks": tasks,
        }

    return parsed_phases, defaults


def filter_phases(parsed_phases: dict, phases_to_run: list[str]) -> list[Task]:
    """Возвращает плоский список задач из указанных фаз."""
    tasks: list[Task] = []
    for phase_name in phases_to_run:
        if phase_name not in parsed_phases:
            raise ValueError(f"Неизвестная фаза: {phase_name}")
        tasks.extend(parsed_phases[phase_name]["tasks"])
    return tasks