"""DAG scheduler: topological ordering + parallel execution planning."""
from __future__ import annotations

from collections import defaultdict
from typing import Iterable

from .task import Task, TaskState


class DAGError(Exception):
    """Raised when the DAG is invalid (cycle, missing dep, etc.)."""


class DAG:
    """Directed Acyclic Graph of tasks."""

    def __init__(self, tasks: Iterable[Task]):
        self.tasks: dict[str, Task] = {t.id: t for t in tasks}
        self._validate()

    def _validate(self) -> None:
        # 1. Проверка на существование зависимостей
        for tid, task in self.tasks.items():
            for dep in task.deps:
                if dep not in self.tasks:
                    raise DAGError(
                        f"Задача '{tid}' ссылается на несуществующую зависимость '{dep}'"
                    )

        # 2. Проверка на циклы (DFS)
        WHITE, GRAY, BLACK = 0, 1, 2
        color: dict[str, int] = {tid: WHITE for tid in self.tasks}

        def dfs(tid: str, path: list[str]) -> None:
            if color[tid] == GRAY:
                cycle = " → ".join(path + [tid])
                raise DAGError(f"Обнаружен цикл: {cycle}")
            if color[tid] == BLACK:
                return
            color[tid] = GRAY
            for dep in self.tasks[tid].deps:
                dfs(dep, path + [tid])
            color[tid] = BLACK

        for tid in self.tasks:
            if color[tid] == WHITE:
                dfs(tid, [])

    def ready_tasks(self, completed: set[str]) -> list[Task]:
        """Задачи, у которых все зависимости выполнены, а сами они ещё pending."""
        ready: list[Task] = []
        for task in self.tasks.values():
            if task.state != TaskState.PENDING:
                continue
            if all(d in completed for d in task.deps):
                ready.append(task)
        return ready

    def blocked_by(self, task_id: str) -> list[str]:
        """Какие зависимости ещё не выполнены для задачи."""
        task = self.tasks[task_id]
        done = {t.id for t in self.tasks.values() if t.state == TaskState.DONE}
        return [d for d in task.deps if d not in done]

    def topological_order(self) -> list[str]:
        """Возвращает линейный порядок (для отчётов / отладки)."""
        visited: set[str] = set()
        order: list[str] = []

        def visit(tid: str) -> None:
            if tid in visited:
                return
            visited.add(tid)
            for dep in self.tasks[tid].deps:
                visit(dep)
            order.append(tid)

        for tid in self.tasks:
            visit(tid)
        return order

    def to_dot(self) -> str:
        """Экспорт в Graphviz DOT (для визуализации)."""
        lines = ["digraph LFS {"]
        lines.append('  rankdir=LR;')
        lines.append('  node [shape=box, style=rounded];')
        for task in self.tasks.values():
            color = {
                TaskState.PENDING: "lightgray",
                TaskState.RUNNING: "gold",
                TaskState.DONE:    "lightgreen",
                TaskState.FAILED:  "lightpink",
                TaskState.SKIPPED: "white",
            }.get(task.state, "white")
            lines.append(f'  "{task.id}" [fillcolor={color}, style="rounded,filled"];')
            for dep in task.deps:
                lines.append(f'  "{dep}" -> "{task.id}";')
        lines.append("}")
        return "\n".join(lines)

    def stats(self) -> dict:
        counts = defaultdict(int)
        for t in self.tasks.values():
            counts[t.state.value] += 1
        return dict(counts)