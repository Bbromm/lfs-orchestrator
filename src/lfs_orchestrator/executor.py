"""Executors: run tasks locally, in chroot, over SSH, or in Docker."""
from __future__ import annotations

import asyncio
import contextlib
import os
import shlex
import signal
from abc import ABC, abstractmethod
from pathlib import Path

from .task import Task


async def _terminate_tree(proc: asyncio.subprocess.Process, grace: float = 5.0) -> None:
    """Останавливает процесс вместе со всеми потомками.

    Задачи запускаются в отдельной группе (start_new_session=True), поэтому
    killpg достаёт всю цепочку: sudo → env → bash → make → cc1. Без этого
    кнопка «Остановить» убивала только верхний sudo, а сборка продолжала
    работать сиротами и ломала следующий запуск (make терял рабочий каталог).
    """
    if proc.returncode is not None:
        return

    if os.name == "nt":
        # В Windows групп процессов через asyncio нет — снимаем дерево целиком.
        with contextlib.suppress(Exception):
            killer = await asyncio.create_subprocess_exec(
                "taskkill", "/F", "/T", "/PID", str(proc.pid),
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.DEVNULL,
            )
            await killer.wait()
        with contextlib.suppress(Exception):
            await asyncio.wait_for(proc.wait(), timeout=grace)
        return

    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(proc.pid, sig)
        except (ProcessLookupError, PermissionError):
            return
        try:
            await asyncio.wait_for(proc.wait(), timeout=grace)
            return
        except asyncio.TimeoutError:
            continue
    with contextlib.suppress(Exception):
        await proc.wait()


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
                start_new_session=True,
            )
            try:
                return await asyncio.wait_for(proc.wait(), timeout=task.timeout)
            except asyncio.TimeoutError:
                await _terminate_tree(proc)
                log.write(f"\n# TIMEOUT after {task.timeout}s\n".encode())
                return 124  # conventional timeout exit code
            except asyncio.CancelledError:
                await _terminate_tree(proc)
                raise


class RootExecutor(Executor):
    """Запускает задачу от root через sudo без пароля.

    Нужен для фазы A главы 7: она делает chown, bind-mount /dev, /proc, /sys
    и входит в chroot, запуская там фазу B. Из-под обычного пользователя
    это невозможно.
    """

    def __init__(self, cwd: Path, env: dict[str, str] | None = None):
        self.cwd = cwd
        self.base_env = env or {}

    async def run(self, task: Task, log_file: Path) -> int:
        env = {**self.base_env, **task.env}
        cmd = ["sudo", "-n", "env", *[f"{k}={v}" for k, v in env.items()],
               "bash", str(self.cwd / task.script), *task.args]

        with log_file.open("wb") as log:
            log.write(f"# ROOT: {' '.join(shlex.quote(c) for c in cmd)}\n".encode())
            log.flush()

            proc = await asyncio.create_subprocess_exec(
                *cmd,
                cwd=str(self.cwd),
                stdout=log,
                stderr=asyncio.subprocess.STDOUT,
                start_new_session=True,
            )
            try:
                return await asyncio.wait_for(proc.wait(), timeout=task.timeout)
            except asyncio.TimeoutError:
                await _terminate_tree(proc)
                log.write(f"\n# TIMEOUT after {task.timeout}s\n".encode())
                return 124
            except asyncio.CancelledError:
                await _terminate_tree(proc)
                raise


class UnprivilegedExecutor(Executor):
    """Запускает задачу от непривилегированного пользователя с чистым окружением.

    Нужен для глав 2–6: они собираются на хосте от пользователя `lfs`
    с переменными из книги LFS (4.4). Окружение задаётся явно, профили
    не читаются — иначе .bash_profile с `exec env -i` съедает команду.
    """

    def __init__(self, user: str, cwd: Path, env: dict[str, str]):
        self.user = user
        self.cwd = cwd
        self.base_env = env

    async def run(self, task: Task, log_file: Path) -> int:
        env = {**self.base_env, **task.env}
        script = str(self.cwd / task.script)
        inner = "set +h; umask 022; cd " + shlex.quote(str(self.cwd)) \
            + " && bash " + shlex.quote(script) \
            + " " + " ".join(shlex.quote(a) for a in task.args)

        env_args = [f"{k}={v}" for k, v in env.items()]
        cmd = ["sudo", "-n", "-u", self.user, "env", "-i", *env_args,
               "/bin/bash", "--noprofile", "--norc", "-c", inner]

        with log_file.open("wb") as log:
            log.write(f"# USER: {self.user}\n".encode())
            log.write(f"# Executing: {' '.join(shlex.quote(c) for c in cmd)}\n".encode())
            log.write(f"# ENV: {env}\n".encode())
            log.flush()

            proc = await asyncio.create_subprocess_exec(
                *cmd,
                stdout=log,
                stderr=asyncio.subprocess.STDOUT,
                start_new_session=True,
            )
            try:
                return await asyncio.wait_for(proc.wait(), timeout=task.timeout)
            except asyncio.TimeoutError:
                await _terminate_tree(proc)
                log.write(f"\n# TIMEOUT after {task.timeout}s\n".encode())
                return 124
            except asyncio.CancelledError:
                await _terminate_tree(proc)
                raise


class ChrootExecutor(Executor):
    """Запускает задачу внутри chroot($LFS)."""

    def __init__(self, lfs_root: Path, cwd_inside: str = "/sources",
                 jobs: int | None = None):
        self.lfs_root = lfs_root
        self.cwd_inside = cwd_inside
        # Без MAKEFLAGS make внутри chroot собирает в один поток —
        # glibc и gcc из-за этого идут в разы дольше.
        self.jobs = jobs or (os.cpu_count() or 1)

    async def run(self, task: Task, log_file: Path) -> int:
        env = dict(task.env)
        env.setdefault("MAKEFLAGS", f"-j{self.jobs}")
        env.setdefault("TESTSUITEFLAGS", f"-j{self.jobs}")

        env_args = []
        for k, v in env.items():
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
                start_new_session=True,
            )
            try:
                return await asyncio.wait_for(proc.wait(), timeout=task.timeout)
            except asyncio.TimeoutError:
                await _terminate_tree(proc)
                log.write(f"\n# TIMEOUT after {task.timeout}s\n".encode())
                return 124
            except asyncio.CancelledError:
                await _terminate_tree(proc)
                raise


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
                start_new_session=True,
            )
            try:
                return await asyncio.wait_for(proc.wait(), timeout=task.timeout)
            except asyncio.TimeoutError:
                await _terminate_tree(proc)
                log.write(f"\n# TIMEOUT after {task.timeout}s\n".encode())
                return 124
            except asyncio.CancelledError:
                await _terminate_tree(proc)
                raise


class DockerExecutor(Executor):
    def __init__(self, image: str = "lfs-builder:latest"):
        self.image = image

    async def run(self, task: Task, log_file: Path) -> int:
        import shlex, uuid as _uuid
        cname = (
            f"lfs-task-{task.id.replace('/', '-').replace('_', '-')}-"
            f"{_uuid.uuid4().hex[:6]}"
        )

        env_args = []
        for k, v in task.env.items():
            env_args += ["-e", f"{k}={v}"]

        run_cmd = [
            "docker", "run", "-d", "--name", cname, "--privileged",
            "--user", "lfs",
            "-v", "/mnt/lfs:/mnt/lfs",
            "-v", "/root/lfs-build:/lfs-build",
            "-w", "/lfs-build",
            *env_args,
            self.image,
            "bash", f"/lfs-build/{task.script}", *task.args,
        ]

        with log_file.open("wb") as log:
            log.write(
                f"# DOCKER RUN: "
                f"{' '.join(shlex.quote(c) for c in run_cmd)}\n".encode()
            )
            log.flush()

            run_proc = await asyncio.create_subprocess_exec(
                *run_cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
            )
            stdout, _ = await run_proc.communicate()
            if run_proc.returncode != 0:
                log.write(stdout)
                return run_proc.returncode

            logs_proc = await asyncio.create_subprocess_exec(
                "docker", "logs", "-f", cname,
                stdout=log, stderr=asyncio.subprocess.STDOUT,
            )

            try:
                wait_proc = await asyncio.create_subprocess_exec(
                    "docker", "wait", cname,
                    stdout=asyncio.subprocess.PIPE,
                )
                try:
                    out, _ = await asyncio.wait_for(
                        wait_proc.communicate(), timeout=task.timeout,
                    )
                    rc = int((out or b"1").strip() or "1")
                except asyncio.TimeoutError:
                    wait_proc.kill()
                    await self._docker_stop(cname)
                    log.write(b"\n# TIMEOUT\n")
                    return 124
            except asyncio.CancelledError:
                await self._docker_stop(cname)
                log.write(b"\n# CANCELLED by user\n")
                raise
            finally:
                if logs_proc.returncode is None:
                    logs_proc.terminate()
                try:
                    await asyncio.wait_for(logs_proc.wait(), timeout=5)
                except asyncio.TimeoutError:
                    logs_proc.kill()
                # подчищаем контейнер
                try:
                    rm = await asyncio.create_subprocess_exec(
                        "docker", "rm", "-f", cname,
                        stdout=asyncio.subprocess.DEVNULL,
                        stderr=asyncio.subprocess.DEVNULL,
                    )
                    await rm.wait()
                except Exception:
                    pass
            return rc

    @staticmethod
    async def _docker_stop(cname: str, timeout: int = 30) -> None:
        proc = await asyncio.create_subprocess_exec(
            "docker", "stop", "-t", str(timeout), cname,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL,
        )
        try:
            await asyncio.wait_for(proc.wait(), timeout=timeout + 10)
        except asyncio.TimeoutError:
            proc.kill()
            await proc.wait()

def make_executor(kind: str, **kwargs) -> Executor:
    """Фабрика исполнителей."""
    kind = kind.lower()
    if kind == "local":
        return LocalExecutor(cwd=Path(kwargs.get("cwd", ".")), env=kwargs.get("env"))
    if kind in ("lfs", "unprivileged"):
        # user из kwargs сюда не годится: там SSH-пользователь (обычно root).
        # Главы 2–6 по книге собираются от пользователя lfs, и скрипты это
        # проверяют (`whoami` == lfs), поэтому имя задаётся отдельно.
        return UnprivilegedExecutor(
            user=kwargs.get("lfs_user") or "lfs",
            cwd=Path(kwargs.get("cwd", ".")),
            env=kwargs.get("env") or {},
        )
    if kind == "root":
        return RootExecutor(cwd=Path(kwargs.get("cwd", ".")), env=kwargs.get("env"))
    if kind == "chroot":
        return ChrootExecutor(lfs_root=Path(kwargs["lfs_root"]))
    if kind == "ssh":
        return SSHExecutor(host=kwargs["host"], user=kwargs.get("user", "root"), key=kwargs.get("key"))
    if kind == "docker":
        return DockerExecutor(image=kwargs.get("image", "lfs-builder:latest"))
    raise ValueError(f"Неизвестный тип executor: {kind}")
