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


CANCELLED_EXIT_CODE = 143  # conventional SIGTERM exit code


class BuildScheduler:
    """
    Запускает DAG задач с контролем параллелизма, retry,
    сохранением состояния и метриками.

    Управление:
      - request_stop()   — мгновенная остановка: прерывает текущие задачи,
                           не запускает новые, выходит из главного цикла.
      - request_pause()  — приостанавливает запуск НОВЫХ задач.
                           Уже запущенные продолжают работу до конца.
      - request_resume() — снимает паузу.

    Идемпотентность:
      - Если `markers_dir` задан, после успеха каждой задачи создаётся
        файл-маркер `<markers_dir>/<phase>/<name>.done`.
      - При старте, если маркер существует и `force=False`, задача
        помечается SKIPPED и не запускается.
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
        markers_dir: Path | None = None,
        force: bool = False,
        force_phases: set[str] | None = None,
        executors: dict[str, Executor] | None = None,
    ):
        self.dag = dag
        self.executor = executor
        self.executors = executors or {}
        self.store = store
        self.logs_dir = Path(logs_dir)
        self.max_parallel = max(1, int(max_parallel))
        self.stop_on_error = stop_on_error
        self.on_event = on_event
        self.markers_dir = Path(markers_dir) if markers_dir else None
        self.force = force
        # force_phases ограничивает игнорирование маркеров перечисленными фазами:
        # план всегда содержит префикс всех фаз до запрошенной, и «сила» не
        # должна заставлять пересобирать уже готовые главы с самого начала.
        self.force_phases = set(force_phases) if force_phases else None

        self.build_id = (
            f"{datetime.utcnow().strftime('%Y%m%d-%H%M%S')}-"
            f"{uuid.uuid4().hex[:6]}"
        )
        self.semaphore = asyncio.Semaphore(self.max_parallel)
        self.running: dict[str, asyncio.Task] = {}
        self.completed: set[str] = set()

        # --- Управление ---
        self._stop_event = asyncio.Event()
        self._pause_event = asyncio.Event()
        self._pause_event.set()  # по умолчанию не на паузе

        self.logs_dir.mkdir(parents=True, exist_ok=True)

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    async def run(self) -> bool:
        """Запускает всю сборку. Возвращает True при успехе."""
        start = datetime.utcnow()
        self.store.create_build(self.build_id, {
            "max_parallel": self.max_parallel,
            "tasks": list(self.dag.tasks.keys()),
            "markers_dir": str(self.markers_dir) if self.markers_dir else None,
            "force": self.force,
        "force_phases": sorted(self.force_phases) if self.force_phases else [],
        })
        self.store.update_build(
            self.build_id,
            status="running",
            started_at=start.isoformat(),
        )
        metrics.start_build()
        self._emit("info", None, f"Build started: {self.build_id}")

        # Один Task на весь run(): пока он не завершён — ждём stop.
        stop_waiter = asyncio.create_task(self._stop_event.wait())

        try:
            await self._main_loop(stop_waiter)
        finally:
            # 1. Аккуратно гасим waiter
            if not stop_waiter.done():
                stop_waiter.cancel()
                try:
                    await stop_waiter
                except BaseException:
                    pass

            # 2. Гарантированно завершаем оставшиеся задачи
            if self.running:
                for at in list(self.running.values()):
                    at.cancel()
                await asyncio.gather(
                    *self.running.values(),
                    return_exceptions=True,
                )
                self.running.clear()

            # 3. Помечаем не успевшие запуститься задачи
            for t in self.dag.tasks.values():
                if t.state == TaskState.PENDING:
                    t.state = TaskState.SKIPPED
                    t.error = "Build stopped before execution"
                    t.finished_at = datetime.utcnow()
                    self.store.save_task(self.build_id, t)

            # 4. Итоговый статус сборки
            end = datetime.utcnow()
            duration = (end - start).total_seconds()
            failed = any(
                t.state == TaskState.FAILED for t in self.dag.tasks.values()
            )
            if self._stop_event.is_set():
                status = "stopped"
            elif failed:
                status = "failed"
            else:
                status = "done"

            self.store.update_build(
                self.build_id,
                status=status,
                finished_at=end.isoformat(),
            )
            metrics.finish_build(status, duration)
            self._emit(
                "info", None,
                f"Build finished: {status} ({duration:.1f}s)",
            )

        return not any(
            t.state == TaskState.FAILED for t in self.dag.tasks.values()
        )

    def request_stop(self) -> None:
        """Мгновенная остановка: ставит флаг и отменяет текущие задачи."""
        if self._stop_event.is_set():
            return
        self._stop_event.set()
        for at in list(self.running.values()):
            at.cancel()

    def request_pause(self) -> None:
        """Пауза: не запускает новые задачи. Текущие продолжают работу."""
        self._pause_event.clear()

    def request_resume(self) -> None:
        """Снятие паузы."""
        self._pause_event.set()

    @property
    def is_stopped(self) -> bool:
        return self._stop_event.is_set()

    @property
    def is_paused(self) -> bool:
        return not self._pause_event.is_set()

    # ------------------------------------------------------------------
    # Main loop
    # ------------------------------------------------------------------

    async def _main_loop(self, stop_waiter: asyncio.Task) -> None:
        while True:
            # 1. Стоп?
            if self._stop_event.is_set():
                self._emit("warn", None, "Stop requested")
                return

            # 2. Запуск готовых задач (если не на паузе)
            if self._pause_event.is_set():
                self._spawn_ready()

            # 3. Всё завершено?
            if self._all_done():
                return

            # 4. Провал?
            failed = [
                t for t in self.dag.tasks.values()
                if t.state == TaskState.FAILED
            ]
            if failed and self.stop_on_error:
                self._emit(
                    "error", None,
                    f"Остановка из-за ошибки в '{failed[0].id}'",
                )
                return

            # 5. Ждём событий
            if self.running:
                # Есть запущенные задачи — ждём любую + stop
                done, _ = await asyncio.wait(
                    [*self.running.values(), stop_waiter],
                    return_when=asyncio.FIRST_COMPLETED,
                )
                if stop_waiter in done:
                    return
                for at in done:
                    self._drop_running(at)
            else:
                # Ничего не запущено
                if not self._pause_event.is_set():
                    # На паузе — ждём resume или stop
                    resume_waiter = asyncio.create_task(
                        self._pause_event.wait()
                    )
                    try:
                        done, _ = await asyncio.wait(
                            [resume_waiter, stop_waiter],
                            return_when=asyncio.FIRST_COMPLETED,
                        )
                    finally:
                        if not resume_waiter.done():
                            resume_waiter.cancel()
                            try:
                                await resume_waiter
                            except BaseException:
                                pass
                    if stop_waiter in done:
                        return
                    # resume — продолжаем цикл
                    continue
                else:
                    # Не на паузе, ничего не запущено и не всё done → deadlock
                    pending = [
                        t.id for t in self.dag.tasks.values()
                        if t.state == TaskState.PENDING
                    ]
                    self._emit(
                        "error", None,
                        f"Тупик: задачи {pending} не могут быть запущены "
                        f"(цикл или провал зависимостей)",
                    )
                    return

    def _spawn_ready(self) -> None:
        ready = self.dag.ready_tasks(self.completed)
        for task in ready:
            if len(self.running) >= self.max_parallel:
                break
            if task.id in self.running:
                continue
            if task.state != TaskState.PENDING:
                continue
            self._spawn(task)

    def _all_done(self) -> bool:
        return all(
            t.state in (TaskState.DONE, TaskState.SKIPPED)
            for t in self.dag.tasks.values()
        )

    def _spawn(self, task: Task) -> None:
        at = asyncio.create_task(self._run_task(task), name=f"task:{task.id}")
        self.running[task.id] = at

    def _drop_running(self, at: asyncio.Task) -> None:
        for tid in [tid for tid, v in self.running.items() if v is at]:
            del self.running[tid]

    # ------------------------------------------------------------------
    # Task execution
    # ------------------------------------------------------------------

    def _marker_path(self, task: Task) -> Path | None:
        if not self.markers_dir:
            return None
        return self.markers_dir / task.phase / f"{task.name}.done"

    def _executor_for(self, task: Task) -> Executor:
        """Исполнитель для задачи: указанный в ней, иначе общий."""
        if task.executor and task.executor in self.executors:
            return self.executors[task.executor]
        if task.executor and task.executor not in self.executors:
            self._emit("warn", task.id,
                       f"исполнитель '{task.executor}' не настроен — использую общий")
        return self.executor

    def _forced(self, task: Task) -> bool:
        """Игнорировать ли маркер задачи.

        force_phases задан -> только для задач из этих фаз; иначе — общий force.
        """
        if self.force_phases is not None:
            return task.phase in self.force_phases
        return self.force

    async def _run_task(self, task: Task) -> None:
        try:
            async with self.semaphore:
                # --- Проверка маркера (пропуск уже собранного) ---
                marker = self._marker_path(task)
                if marker and not self._forced(task) and marker.exists():
                    now = datetime.utcnow()
                    task.state = TaskState.SKIPPED
                    task.started_at = now
                    task.finished_at = now
                    task.exit_code = 0
                    task.error = None
                    self.completed.add(task.id)
                    self.store.save_task(self.build_id, task)
                    self._emit(
                        "info", task.id,
                        f"⏩ Пропущена (маркер: {marker.name})",
                    )
                    return

                # --- Подготовка ---
                task.started_at = datetime.utcnow()
                task.state = TaskState.RUNNING
                task.log_path = str(
                    self.logs_dir / self.build_id
                    / f"{task.id.replace('/', '__')}.log"
                )
                Path(task.log_path).parent.mkdir(parents=True, exist_ok=True)
                self.store.save_task(self.build_id, task)
                metrics.start_task(task.phase, task.name)
                self._emit(
                    "info", task.id,
                    f"▶ Запуск: {task.id}",
                )
                self.store.log_event(
                    self.build_id, f"Запуск {task.id}", task.id, "info",
                )

                # --- Попытки (retry) ---
                while True:
                    task.attempts += 1

                    try:
                        rc = await self._executor_for(task).run(
                            task, Path(task.log_path),
                        )
                    except asyncio.CancelledError:
                        task.finished_at = datetime.utcnow()
                        task.duration = (
                            task.finished_at - task.started_at
                        ).total_seconds()
                        task.exit_code = CANCELLED_EXIT_CODE
                        task.error = "Cancelled by user"
                        task.state = TaskState.FAILED
                        self.store.save_task(self.build_id, task)
                        metrics.finish_task(
                            task.phase, task.name, "cancelled",
                            task.duration,
                        )
                        self._emit(
                            "warn", task.id, f"✖ Отменена: {task.id}",
                        )
                        self.store.log_event(
                            self.build_id,
                            f"Отменена {task.id}",
                            task.id, "warn",
                        )
                        raise
                    except Exception as e:
                        rc = -1
                        task.error = f"{type(e).__name__}: {e}"
                        metrics.error(
                            task.phase, task.name, type(e).__name__,
                        )

                    task.finished_at = datetime.utcnow()
                    task.duration = (
                        task.finished_at - task.started_at
                    ).total_seconds()
                    task.exit_code = rc

                    # --- Успех ---
                    if rc == 0:
                        task.state = TaskState.DONE
                        self.completed.add(task.id)
                        metrics.finish_task(
                            task.phase, task.name, "success",
                            task.duration,
                        )
                        self._emit(
                            "info", task.id,
                            f"✔ Готово: {task.id} за {task.duration:.1f}s",
                        )
                        self.store.log_event(
                            self.build_id, f"Готово {task.id}",
                            task.id, "info",
                        )
                        # Записываем маркер
                        if marker:
                            try:
                                marker.parent.mkdir(
                                    parents=True, exist_ok=True,
                                )
                                marker.write_text(
                                    f"task={task.id}\n"
                                    f"finished="
                                    f"{task.finished_at.isoformat()}\n"
                                    f"duration={task.duration:.2f}\n"
                                    f"exit_code=0\n"
                                )
                            except Exception as e:
                                self._emit(
                                    "warn", task.id,
                                    f"Не удалось записать маркер: {e}",
                                )
                        break

                    # --- Retry ---
                    if task.attempts <= task.retries:
                        task.state = TaskState.RETRYING
                        metrics.retry(task.name)
                        self._emit(
                            "warn", task.id,
                            f"↻ Повтор {task.id} "
                            f"(попытка {task.attempts}/"
                            f"{task.retries + 1})",
                        )
                        self.store.save_task(self.build_id, task)
                        await asyncio.sleep(5)
                        continue

                    # --- Провал ---
                    task.state = TaskState.FAILED
                    metrics.finish_task(
                        task.phase, task.name, "failed", task.duration,
                    )
                    self._emit(
                        "error", task.id,
                        f"✘ Провал: {task.id} "
                        f"(exit={rc}, {task.duration:.1f}s)",
                    )
                    self.store.log_event(
                        self.build_id,
                        f"Провал {task.id} (exit={rc})",
                        task.id, "error",
                    )
                    break

                self.store.save_task(self.build_id, task)

        except asyncio.CancelledError:
            # Отмена, пришедшая ДО того, как мы успели войти в основной
            # try внутри async with (например, при ожидании семафора).
            if task.state in (TaskState.PENDING, TaskState.RUNNING):
                task.state = TaskState.FAILED
                task.error = "Cancelled before start"
                task.finished_at = datetime.utcnow()
                task.exit_code = CANCELLED_EXIT_CODE
                try:
                    self.store.save_task(self.build_id, task)
                except Exception:
                    pass
            raise

    # ------------------------------------------------------------------
    # Events
    # ------------------------------------------------------------------

    def _emit(
        self, level: str, task_id: str | None, message: str,
    ) -> None:
        line = (
            f"[{datetime.utcnow().strftime('%H:%M:%S')}] "
            f"[{level.upper()}] {message}"
        )
        print(line, flush=True)
        if self.on_event:
            try:
                self.on_event(level, task_id or "", message)
            except Exception as e:
                print(
                    f"[WARN] on_event callback failed: {e}",
                    flush=True,
                )
