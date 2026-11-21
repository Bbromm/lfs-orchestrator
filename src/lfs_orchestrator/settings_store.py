"""Хранилище настроек, которые пользователь задаёт в веб-интерфейсе.

Настройки живут в двух местах:
    data/settings.json            — рабочая копия оркестратора
    $LFS/.lfs-state/settings.json — то же внутри chroot, читают скрипты

Файл внутри chroot нужен, чтобы передавать пароль пользователя не через
переменные окружения: ChrootExecutor пишет env в лог задачи, и пароль
оказался бы в открытом виде.
"""
from __future__ import annotations

import json
import os
import re
import stat
from pathlib import Path

# Значения по умолчанию — повторяют то, что зашито в скриптах глав 9–11.
DEFAULTS: dict = {
    "network": {
        "mode": "dhcp",          # dhcp | static
        "iface": "",             # пусто = автоопределение
        "ip": "",
        "prefix": 24,
        "gateway": "",
        "dns1": "",
        "dns2": "",
    },
    "system": {
        "hostname": "lfs",
        "timezone": "Asia/Yekaterinburg",
        "locale": "ru_RU.UTF-8",
        "keymap": "ru",
    },
    "user": {
        "name": "",
        "password": "",
        "groups": "wheel,audio,video,input,cdrom",
    },
    "extras": {
        "sudo": False,
        "pam": False,
        "nix": True,
        "ssh": False,
        "xfce": False,
    },
    "boot": {
        "mode": "auto",      # auto | uefi | bios
        "disk": "",          # пусто = диск, на котором лежит $LFS
        "esp": "",           # пусто = ESP рядом с $LFS/boot/efi
        "timeout": 5,
    },
}

USER_RE = re.compile(r"^[a-z_][a-z0-9_-]{0,31}$")
HOST_RE = re.compile(r"^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$")
IP_RE = re.compile(r"^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$")


def _ip_ok(value: str) -> bool:
    m = IP_RE.match(value or "")
    return bool(m) and all(0 <= int(g) <= 255 for g in m.groups())


def deep_merge(base: dict, patch: dict) -> dict:
    out = dict(base)
    for key, value in (patch or {}).items():
        if isinstance(value, dict) and isinstance(out.get(key), dict):
            out[key] = deep_merge(out[key], value)
        else:
            out[key] = value
    return out


class SettingsStore:
    def __init__(self, path: Path, lfs_root: Path):
        self.path = Path(path)
        self.lfs_root = Path(lfs_root)
        self.lfs_path = self.lfs_root / ".lfs-state" / "settings.json"

    # -- чтение/запись --------------------------------------------------
    def load(self) -> dict:
        data: dict = {}
        if self.path.exists():
            try:
                data = json.loads(self.path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                data = {}
        return deep_merge(DEFAULTS, data)

    def save(self, patch: dict) -> dict:
        merged = deep_merge(self.load(), patch)
        errors = validate(merged)
        if errors:
            raise ValueError("; ".join(errors))

        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text(
            json.dumps(merged, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        self._publish(merged)
        return merged

    def _publish(self, data: dict) -> None:
        """Копия внутрь $LFS, чтобы её читали скрипты в chroot."""
        try:
            self.lfs_path.parent.mkdir(parents=True, exist_ok=True)
            self.lfs_path.write_text(
                json.dumps(data, ensure_ascii=False, indent=2) + "\n",
                encoding="utf-8",
            )
            os.chmod(self.lfs_path, stat.S_IRUSR | stat.S_IWUSR)  # 0600
        except OSError:
            pass

    # -- то, что нужно задачам ------------------------------------------
    def env_for_phase(self, phase: str) -> dict[str, str]:
        """Переменные для скриптов соответствующей фазы."""
        s = self.load()
        net, sysd = s["network"], s["system"]

        if phase == "phase9":
            env = {
                "HOSTNAME": sysd["hostname"],
                "TIMEZONE": sysd["timezone"],
                "LOCALE": sysd["locale"],
                "KEYMAP": sysd["keymap"],
                "USE_DHCP": "yes" if net["mode"] == "dhcp" else "no",
                "STATIC_IP": net["ip"] or "",
                "PREFIX": str(net["prefix"] or 24),
                "GATEWAY": net["gateway"] or "",
                "DNS_PRIMARY": net["dns1"] or "",
                "DNS_SECONDARY": net["dns2"] or "",
                "NET_IFACE": net["iface"] or "",
            }
            return {k: v for k, v in env.items() if v != ""}

        if phase in ("phase10", "phase11"):
            env = {
                "HOSTNAME": sysd["hostname"],
                "TIMEZONE": sysd["timezone"],
                "LOCALE": sysd["locale"],
            }
            if phase == "phase10":
                env.update(self._boot_env())
            return env
        if phase == "phase12":
            extras = s["extras"]
            return {
                "LFS_SETTINGS": "/.lfs-state/settings.json",
                "WANT_SUDO": "yes" if extras.get("sudo") else "no",
                "WANT_PAM": "yes" if extras.get("pam") else "no",
                "WANT_NIX": "yes" if extras.get("nix") else "no",
                "WANT_SSH": "yes" if extras.get("ssh") else "no",
                "WANT_XFCE": "yes" if extras.get("xfce") else "no",
            }

        return {}

    # -- параметры загрузчика --------------------------------------------
    def _boot_env(self) -> dict[str, str]:
        """Определяет диск, разделы и режим загрузки.

        Значения из интерфейса имеют приоритет: на реальной машине
        автоопределение может выбрать не ту сетевуху/диск/ESP.
        """
        import subprocess

        def sh(cmd: list[str]) -> str:
            try:
                out = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
                return out.stdout.strip()
            except Exception:
                return ""

        boot = self.load().get("boot") or {}
        uefi = os.path.isdir("/sys/firmware/efi")

        mode = boot.get("mode") or "auto"
        if mode == "auto":
            mode = "uefi" if uefi else "bios"

        lfs = str(self.lfs_root)
        root_part = sh(["findmnt", "-n", "-o", "SOURCE", lfs]) or ""
        if not root_part.startswith("/dev/"):
            root_part = ""

        env: dict[str, str] = {
            "BOOT_MODE": mode,
            "FS_ID": "uuid",
        }
        if root_part:
            env["ROOT_PART"] = root_part

        disk = boot.get("disk") or ""
        if not disk and root_part:
            pk = sh(["lsblk", "-no", "PKNAME", root_part])
            if pk:
                disk = pk if pk.startswith("/dev/") else f"/dev/{pk}"
        if disk:
            env["DISK"] = disk

        swap = ""
        swaps: list[str] = []
        # /proc/swaps читается без PATH и без root — надёжнее, чем swapon
        try:
            with open("/proc/swaps", encoding="utf-8") as fh:
                for line in fh.read().splitlines()[1:]:
                    name = line.split()[0] if line.split() else ""
                    if name.startswith("/dev/"):
                        swaps.append(name)
        except OSError:
            pass
        if not swaps:
            swaps = [
                line.strip()
                for line in sh(["swapon", "--show=NAME", "--noheadings"]).splitlines()
                if line.strip().startswith("/dev/")
            ]
        if swaps:
            # На хосте может быть свой swap (например, раздел Debian).
            # Берём тот, что на том же диске, где корень LFS.
            root_pk = sh(["lsblk", "-no", "PKNAME", root_part]) if root_part else ""
            swap = swaps[0]
            for cand in swaps:
                if root_pk and sh(["lsblk", "-no", "PKNAME", cand]) == root_pk:
                    swap = cand
                    break
        if swap:
            env["SWAP_PART"] = swap

        esp = boot.get("esp") or ""
        if not esp:
            esp = sh(["findmnt", "-n", "-o", "SOURCE", f"{lfs}/boot/efi"])
        # ESP нужен только при загрузке через UEFI: в BIOS-режиме запись
        # в fstab для /boot/efi лишняя и может задержать загрузку.
        if esp.startswith("/dev/") and mode == "uefi":
            env["ESP_PART"] = esp

        try:
            env["GRUB_TIMEOUT"] = str(int(boot.get("timeout", 5)))
        except (TypeError, ValueError):
            env["GRUB_TIMEOUT"] = "5"

        return env

    # -- вид для интерфейса ---------------------------------------------
    def public(self) -> dict:
        """Настройки без пароля — пароль наружу не отдаём."""
        data = self.load()
        out = json.loads(json.dumps(data))
        password_set = bool(data["user"].get("password"))
        out["user"]["password"] = ""
        out["user"]["password_set"] = password_set
        return out


def validate(data: dict) -> list[str]:
    errors: list[str] = []
    net = data.get("network") or {}
    sysd = data.get("system") or {}
    user = data.get("user") or {}

    if net.get("mode") not in ("dhcp", "static"):
        errors.append("режим сети должен быть dhcp или static")

    if net.get("mode") == "static":
        if not _ip_ok(net.get("ip", "")):
            errors.append("некорректный IP-адрес")
        try:
            prefix = int(net.get("prefix", 24))
            if not 1 <= prefix <= 32:
                errors.append("префикс сети должен быть от 1 до 32")
        except (TypeError, ValueError):
            errors.append("префикс сети должен быть числом")
        if not _ip_ok(net.get("gateway", "")):
            errors.append("некорректный шлюз")
        if net.get("dns1") and not _ip_ok(net["dns1"]):
            errors.append("некорректный основной DNS")
        if net.get("dns2") and not _ip_ok(net["dns2"]):
            errors.append("некорректный дополнительный DNS")

    if net.get("iface") and not re.fullmatch(r"[A-Za-z0-9_.:@-]{1,15}", net["iface"]):
        errors.append("некорректное имя интерфейса")

    boot = data.get("boot") or {}
    if boot.get("mode") not in ("auto", "uefi", "bios"):
        errors.append("режим загрузки должен быть auto, uefi или bios")
    for key, label in (("disk", "диск для GRUB"), ("esp", "раздел ESP")):
        value = boot.get(key) or ""
        if value and not re.fullmatch(r"/dev/[A-Za-z0-9/_-]+", value):
            errors.append(f"{label}: путь должен быть вида /dev/sda")
    try:
        timeout = int(boot.get("timeout", 5))
        if not 0 <= timeout <= 60:
            errors.append("таймаут меню GRUB должен быть 0–60 секунд")
    except (TypeError, ValueError):
        errors.append("таймаут меню GRUB должен быть числом")

    if not HOST_RE.match(sysd.get("hostname", "")):
        errors.append("некорректное имя машины (латиница, цифры, дефис)")

    if not re.fullmatch(r"[A-Za-z_]{2,6}\.[A-Za-z0-9-]+", sysd.get("locale", "")):
        errors.append("некорректная локаль (например ru_RU.UTF-8)")

    if not re.fullmatch(r"[A-Za-z]+/[A-Za-z_+-]+", sysd.get("timezone", "")):
        errors.append("некорректный часовой пояс (например Asia/Yekaterinburg)")

    if user.get("name"):
        if not USER_RE.match(user["name"]):
            errors.append("имя пользователя: строчная латиница, цифры, «_», «-», до 32 символов")
        password = user.get("password") or ""
        if password and len(password) < 5:
            errors.append("пароль короче 5 символов")
        groups = user.get("groups") or ""
        for g in [x.strip() for x in groups.split(",") if x.strip()]:
            if not re.fullmatch(r"[a-z_][a-z0-9_-]{0,31}", g):
                errors.append(f"некорректное имя группы: {g}")

    return errors
