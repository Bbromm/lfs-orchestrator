"""Готовые описания задач LFS (программное представление YAML)."""
from __future__ import annotations

from .task import Task


def chapter5_tasks() -> list[Task]:
    return [
        Task(name="binutils-pass1", phase="phase5", script="scripts/install-chapter5.sh",
             args=["--only", "binutils-pass1"], deps=[], sbu_estimate=1.0),
        Task(name="gcc-pass1", phase="phase5", script="scripts/install-chapter5.sh",
             args=["--only", "gcc-pass1"], deps=["phase5/binutils-pass1"], sbu_estimate=4.3),
        Task(name="linux-headers", phase="phase5", script="scripts/install-chapter5.sh",
             args=["--only", "linux-headers"], deps=["phase5/gcc-pass1"], sbu_estimate=0.1),
        Task(name="glibc", phase="phase5", script="scripts/install-chapter5.sh",
             args=["--only", "glibc"], deps=["phase5/linux-headers"], sbu_estimate=1.3),
        Task(name="libstdcpp", phase="phase5", script="scripts/install-chapter5.sh",
             args=["--only", "libstdcpp"], deps=["phase5/glibc"], sbu_estimate=0.3),
    ]


# Аналогично — chapter6_tasks(), chapter7_tasks(), chapter8_tasks() и т.д.
# Полное описание удобнее держать в YAML (см. config/lfs-default.yaml).