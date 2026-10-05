"""CLI entrypoint."""
from __future__ import annotations

import asyncio
from pathlib import Path
from typing import Optional

import typer
from rich.console import Console
from rich.table import Table

from .config import load_settings, load_tasks_config, filter_phases
from .dag import DAG
from .executor import make_executor
from .scheduler import BuildScheduler
from .state import StateStore

app = typer.Typer(help="LFS Orchestrator — DAG-based build system")
console = Console()


@app.command()
def run(
    config: str = typer.Option("config/lfs-default.yaml", "--config", "-c"),
    phase: list[str] = typer.Option(..., "--phase", "-p"),
    max_parallel: int = typer.Option(4, "--max-parallel", "-j"),
    run_tests: bool = typer.Option(False, "--run-tests"),
):
    """Запустить сборку указанных фаз."""
    settings = load_settings()
    parsed, _ = load_tasks_config(config)
    tasks = filter_phases(parsed, phase)
    dag = DAG(tasks)

    executor = make_executor(settings.executor, cwd=Path.cwd(), lfs_root=settings.root)
    store = StateStore(settings.db_path)

    console.print(f"[bold green]Запуск {len(tasks)} задач[/bold green]")
    console.print(f"DAG stats: {dag.stats()}")

    scheduler = BuildScheduler(
        dag=dag, executor=executor, store=store,
        logs_dir=Path(settings.logs_dir),
        max_parallel=max_parallel,
    )
    ok = asyncio.run(scheduler.run())
    console.print(f"[bold]{'[green]✔ Успех[/green]' if ok else '[red]✘ Провал[/red]'}[/bold]")
    raise typer.Exit(0 if ok else 1)


@app.command()
def list_builds(limit: int = 20):
    """Список сборок."""
    store = StateStore(load_settings().db_path)
    t = Table(title="Сборки")
    for col in ("ID", "Status", "Created", "Duration", "Progress"):
        t.add_column(col)
    for b in store.list_builds(limit):
        t.add_row(
            b["id"], b["status"], b["created_at"][:19],
            str(b.get("finished_at") or "-"),
            f"{b.get('progress', 0.0) * 100:.0f}%",
        )
    console.print(t)


@app.command()
def show(build_id: str):
    """Показать детали сборки."""
    store = StateStore(load_settings().db_path)
    b = store.get_build(build_id)
    if not b:
        console.print(f"[red]Сборка {build_id} не найдена[/red]")
        raise typer.Exit(1)
    console.print(f"[bold]Build: {b['id']}[/bold]  status={b['status']}")
    t = Table(title="Задачи")
    for col in ("Task", "State", "Duration", "Exit", "Attempts"):
        t.add_column(col)
    for task in b["tasks"]:
        t.add_row(
            task["task_id"], task["state"],
            f"{task['duration']:.1f}s", str(task["exit_code"]), str(task["attempts"]),
        )
    console.print(t)


if __name__ == "__main__":
    app()