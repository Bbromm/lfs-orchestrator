"""Prometheus metrics export."""
from __future__ import annotations

from prometheus_client import Counter, Gauge, Histogram, CollectorRegistry


class Metrics:
    def __init__(self, registry: CollectorRegistry | None = None):
        self.registry = registry

        self.builds_total = Counter(
            "lfs_builds_total", "Всего сборок", ["status"],
            registry=registry,
        )
        self.builds_active = Gauge(
            "lfs_builds_active", "Активные сборки",
            registry=registry,
        )
        self.build_duration = Histogram(
            "lfs_build_duration_seconds", "Длительность сборки",
            buckets=[60, 300, 900, 1800, 3600, 7200, 14400, 28800],
            registry=registry,
        )

        self.tasks_total = Counter(
            "lfs_tasks_total", "Всего задач",
            ["phase", "package", "status"],
            registry=registry,
        )
        self.tasks_active = Gauge(
            "lfs_tasks_active", "Активные задачи",
            registry=registry,
        )
        self.task_duration = Histogram(
            "lfs_task_duration_seconds", "Длительность задачи",
            ["phase", "package"],
            buckets=[10, 30, 60, 120, 300, 600, 1800, 3600],
            registry=registry,
        )
        self.current_phase = Gauge(
            "lfs_current_phase", "Текущая фаза (1 = активна)",
            ["phase"],
            registry=registry,
        )
        self.errors_total = Counter(
            "lfs_errors_total", "Ошибки",
            ["phase", "package", "reason"],
            registry=registry,
        )
        self.retries_total = Counter(
            "lfs_retries_total", "Повторы",
            ["package"],
            registry=registry,
        )

    # ---- helper methods ----
    def start_build(self):
        self.builds_active.inc()

    def finish_build(self, status: str, duration: float):
        self.builds_active.dec()
        self.builds_total.labels(status=status).inc()
        self.build_duration.observe(duration)

    def start_task(self, phase: str, package: str):
        self.tasks_active.inc()
        self.current_phase.labels(phase=phase).set(1)

    def finish_task(self, phase: str, package: str, status: str, duration: float):
        self.tasks_active.dec()
        self.tasks_total.labels(phase=phase, package=package, status=status).inc()
        self.task_duration.labels(phase=phase, package=package).observe(duration)

    def error(self, phase: str, package: str, reason: str):
        self.errors_total.labels(phase=phase, package=package, reason=reason).inc()

    def retry(self, package: str):
        self.retries_total.labels(package=package).inc()


metrics = Metrics()