"""Executors: run tasks locally, in chroot, over SSH, or in Docker."""
from __future__ import annotations

import asyncio
import os
import shlex
from abc import ABC, abstractmethod
from pathlib import Path

from .task import Task


class Executor(ABC):
    """Базовый интерфейс исполнителя."""

    @abstractmethod
    async def run(self, task: Task, log_file: Path) -> int:
        """Запустить задачу. Возвращает exit code (0 = успех)."""


class LocalExecutor(Executor):
    """Запускает bash-скрипт локально (на хосте оркестратора)."""

    def __init__(self, cwd: Path, env: dict[str, str] | None = None):
        self.cwd = cwd
        self.base_env = env or {}

    async def run(self, task: Task, log_file: Path) -> int:
        env = {**os.environ, **self.base_env, **task.env}
        cmd = ["bash", str(self.cwd / task.script)] + task.args

        with log_file.open("wb") as log:
            log.write(f"# Executing: {' '.join(shlex.quote(c) for c in cmd)}\n".encode())
            log.write(f"# CWD: {self.cwd}\n".encode())
            log.write(f"# ENV: {task.env}\n".encode())
            log.flush()

            proc = await asyncio.create_subprocess_exec(
                *cmd,
                cwd=str(self.cwd),
                env=env,
                stdout=log,
                stderr=asyncio.subprocess.STDOUT,
            )
            try:
                return await asyncio.wait_for(proc.wait(), timeout=task.timeout)
            except asyncio.TimeoutError:
                proc.kill()
                await proc.wait()
                log.write(f"\n# TIMEOUT after {task.timeout}s\n".encode())
                return 124  # conventional timeout exit code


class ChrootExecutor(Executor):
    """Запускает задачу внутри chroot($LFS)."""

    def __init__(self, lfs_root: Path, cwd_inside: str = "/sources"):
        self.lfs_root = lfs_root
        self.cwd_inside = cwd_inside

    async def run(self, task: Task, log_file: Path) -> int:
        env_args = []
        for k, v in task.env.items():
            env_args += [f"{k}={v}"]
        env_args += ["HOME=/root", "TERM=xterm", "PATH=/usr/bin:/usr/sbin"]

        inner = f"cd {self.cwd_inside} && bash {task.script} " + " ".join(shlex.quote(a) for a in task.args)

        cmd = [
            "chroot", str(self.lfs_root),
            "/usr/bin/env", "-i", *env_args,
            "/bin/bash", "--login", "-c", inner,
        ]

        with log_file.open("wb") as log:
            log.write(f"# CHROOT: {' '.join(shlex.quote(c) for c in cmd)}\n".encode())
            log.flush()
            proc = await asyncio.create_subprocess_exec(
                *cmd, stdout=log, stderr=asyncio.subprocess.STDOUT,
            )
            try:
                return await asyncio.wait_for(proc.wait(), timeout=task.timeout)
            except asyncio.TimeoutError:
                proc.kill()
                await proc.wait()
                return 124


class SSHExecutor(Executor):
    """Запускает задачу на удалённом хосте через SSH."""

    def __init__(self, host: str, user: str = "root", key: str | None = None):
        self.host = host
        self.user = user
        self.key = key

    async def run(self, task: Task, log_file: Path) -> int:
        env_prefix = " ".join(f"{k}={shlex.quote(v)}" for k, v in task.env.items())
        remote_cmd = (
            f"cd /root/lfs-build && "
            f"{env_prefix} bash {task.script} " +
            " ".join(shlex.quote(a) for a in task.args)
        )

        ssh_args = ["ssh", "-o", "StrictHostKeyChecking=no", "-o", "BatchMode=yes"]
        if self.key:
            ssh_args += ["-i", self.key]
        ssh_args += [f"{self.user}@{self.host}", remote_cmd]

        with log_file.open("wb") as log:
            log.write(f"# SSH to {self.host}: {' '.join(shlex.quote(c) for c in ssh_args)}\n".encode())
            log.flush()
            proc = await asyncio.create_subprocess_exec(
                *ssh_args, stdout=log, stderr=asyncio.subprocess.STDOUT,
            )
            try:
                return await asyncio.wait_for(proc.wait(), timeout=task.timeout)
            except asyncio.TimeoutError:
                proc.kill()
                await proc.wait()
                return 124


class DockerExecutor(Executor):
    """Запускает задачу в Docker-контейнере."""

    def __init__(self, image: str = "lfs-builder:latest", container_name: str | None = None):
        self.image = image
        self.container_name = container_name

    async def run(self, task: Task, log_file: Path) -> int:
        env_args = []
        for k, v in task.env.items():
            env_args += ["-e", f"{k}={v}"]

        cmd = [
            "docker", "run", "--rm", "--privileged",
            "-v", "/mnt/lfs:/mnt/lfs",
            "-v", "/root/lfs-build:/root/lfs-build",
            *env_args,
            self.image,
            "bash", f"/root/lfs-build/{task.script}", *task.args,
        ]

        with log_file.open("wb") as log:
            log.write(f"# DOCKER: {' '.join(shlex.quote(c) for c in cmd)}\n".encode())
            log.flush()
            proc = await asyncio.create_subprocess_exec(
                *cmd, stdout=log, stderr=asyncio.subprocess.STDOUT,
            )
            try:
                return await asyncio.wait_for(proc.wait(), timeout=task.timeout)
            except asyncio.TimeoutError:
                proc.kill()
                await proc.wait()
                return 124


def make_executor(kind: str, **kwargs) -> Executor:
    """Фабрика исполнителей."""
    kind = kind.lower()
    if kind == "local":
        return LocalExecutor(cwd=Path(kwargs.get("cwd", ".")), env=kwargs.get("env"))
    if kind == "chroot":
        return ChrootExecutor(lfs_root=Path(kwargs["lfs_root"]))
    if kind == "ssh":
        return SSHExecutor(host=kwargs["host"], user=kwargs.get("user", "root"), key=kwargs.get("key"))
    if kind == "docker":
        return DockerExecutor(image=kwargs.get("image", "lfs-builder:latest"))
    raise ValueError(f"Неизвестный тип executor: {kind}")