"""Main scheduler: orchestrates DAG execution with parallelism."""
from __future__ import annotations

import asyncio
import uuid
from datetime import datetime
from pathlib import Path
from typing import Callable

from .dag import DAG
from .executor import Executor
from .metrics import metrics
from .state import StateStore
from .task import Task, TaskState


class BuildScheduler:
    """
    Запускает DAG задач с контролем параллелизма, retry,
    сохранением состояния и метриками.
    """

    def __init__(
        self,
        dag: DAG,
        executor: Executor,
        store: StateStore,
        logs_dir: Path,
        max_parallel: int = 4,
        stop_on_error: bool = True,
        on_event: Callable[[str, str, str], None] | None = None,
    ):
        self.dag = dag
        self.executor = executor
        self.store = store
        self.logs_dir = logs_dir
        self.max_parallel = max_parallel
        self.stop_on_error = stop_on_error
        self.on_event = on_event

        self.build_id = f"{datetime.utcnow().strftime('%Y%m%d-%H%M%S')}-{uuid.uuid4().hex[:6]}"
        self.semaphore = asyncio.Semaphore(max_parallel)
        self.running: dict[str, asyncio.Task] = {}
        self.completed: set[str] = set()
        self._stop_requested = False
        self._pause_event = asyncio.Event()
        self._pause_event.set()  # not paused initially

        self.logs_dir.mkdir(parents=True, exist_ok=True)

    # ---- Public API ----

    async def run(self) -> bool:
        """Запускает всю сборку. Возвращает True при успехе."""
        start = datetime.utcnow()
        self.store.create_build(self.build_id, {
            "max_parallel": self.max_parallel,
            "tasks": list(self.dag.tasks.keys()),
        })
        self.store.update_build(
            self.build_id, status="running",
            started_at=start.isoformat(),
        )
        metrics.start_build()

        self._emit("info", None, f"Build started: {self.build_id}")

        try:
            while True:
                if self._stop_requested:
                    self._emit("warn", None, "Stop requested")
                    break

                await self._pause_event.wait()  # block if paused

                # 1. Запускаем готовые задачи
                ready = self.dag.ready_tasks(self.completed)
                for task in ready:
                    if len(self.running) >= self.max_parallel:
                        break
                    if task.id in self.running or task.state != TaskState.PENDING:
                        continue
                    self._spawn(task)

                # 2. Проверяем, завершена ли сборка
                all_done = all(
                    t.state in (TaskState.DONE, TaskState.SKIPPED)
                    for t in self.dag.tasks.values()
                )
                if all_done:
                    break

                failed = [t for t in self.dag.tasks.values() if t.state == TaskState.FAILED]
                if failed and self.stop_on_error:
                    self._emit("error", None, f"Остановка из-за ошибки в '{failed[0].id}'")
                    break

                # 3. Ждём завершения хотя бы одной задачи
                if not self.running:
                    # тупик: задач ready нет, running нет, но не всё done
                    blocked = [t.id for t in self.dag.tasks.values()
                               if t.state == TaskState.PENDING]
                    self._emit("error", None,
                               f"Тупик: задачи {blocked} не могут быть запущены "
                               f"(цикл или провал зависимостей)")
                    break

                done, _ = await asyncio.wait(
                    self.running.values(),
                    return_when=asyncio.FIRST_COMPLETED,
                )
                for at in done:
                    for tid in [tid for tid, v in self.running.items() if v is at]:
                        del self.running[tid]

            # Ждём оставшиеся
            if self.running:
                await asyncio.gather(*self.running.values(), return_exceptions=True)

        finally:
            end = datetime.utcnow()
            duration = (end - start).total_seconds()
            failed = any(t.state == TaskState.FAILED for t in self.dag.tasks.values())
            status = "failed" if failed else "done"
            self.store.update_build(
                self.build_id, status=status, finished_at=end.isoformat(),
            )
            metrics.finish_build(status, duration)
            self._emit("info", None, f"Build finished: {status} ({duration:.1f}s)")

        return not any(t.state == TaskState.FAILED for t in self.dag.tasks.values())

    def request_stop(self):
        self._stop_requested = True

    def request_pause(self):
        self._pause_event.clear()

    def request_resume(self):
        self._pause_event.set()

    # ---- Internal ----

    def _spawn(self, task: Task) -> None:
        at = asyncio.create_task(self._run_task(task))
        self.running[task.id] = at

    async def _run_task(self, task: Task) -> None:
        async with self.semaphore:
            task.attempts += 1
            task.started_at = datetime.utcnow()
            task.state = TaskState.RUNNING
            task.log_path = str(self.logs_dir / self.build_id / f"{task.id.replace('/', '__')}.log")
            Path(task.log_path).parent.mkdir(parents=True, exist_ok=True)

            self.store.save_task(self.build_id, task)
            metrics.start_task(task.phase, task.name)
            self._emit("info", task.id, f"▶ Запуск: {task.id} (попытка {task.attempts})")
            self.store.log_event(self.build_id, f"Запуск {task.id}", task.id, "info")

            try:
                rc = await self.executor.run(task, Path(task.log_path))
            except Exception as e:
                rc = -1
                task.error = str(e)
                metrics.error(task.phase, task.name, type(e).__name__)

            task.finished_at = datetime.utcnow()
            task.duration = (task.finished_at - task.started_at).total_seconds()
            task.exit_code = rc

            if rc == 0:
                task.state = TaskState.DONE
                self.completed.add(task.id)
                metrics.finish_task(task.phase, task.name, "success", task.duration)
                self._emit("info", task.id, f"✔ Готово: {task.id} за {task.duration:.1f}s")
                self.store.log_event(self.build_id, f"Готово {task.id}", task.id, "info")
            else:
                if task.attempts <= task.retries:
                    task.state = TaskState.RETRYING
                    metrics.retry(task.name)
                    self._emit("warn", task.id,
                               f"↻ Повтор {task.id} (попытка {task.attempts}/{task.retries+1})")
                    self.store.save_task(self.build_id, task)
                    await asyncio.sleep(5)
                    return await self._run_task(task)

                task.state = TaskState.FAILED
                metrics.finish_task(task.phase, task.name, "failed", task.duration)
                self._emit("error", task.id,
                           f"✘ Провал: {task.id} (exit={rc}, {task.duration:.1f}s)")
                self.store.log_event(self.build_id,
                                     f"Провал {task.id} (exit={rc})", task.id, "error")

            self.store.save_task(self.build_id, task)

    def _emit(self, level: str, task_id: str | None, message: str) -> None:
        line = f"[{datetime.utcnow().strftime('%H:%M:%S')}] [{level.upper()}] {message}"
        print(line, flush=True)
        if self.on_event:
            self.on_event(level, task_id or "", message)