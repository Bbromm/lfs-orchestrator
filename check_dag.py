#!/usr/bin/env python3
"""check_dag.py — проверка конфигов оркестратора настоящим классом DAG.

Использование:
    python3 check_dag.py <config.yaml> [<config2.yaml> ...]

Проверяет:
  * существование файлов скриптов;
  * что каждый `--only <stage>` есть в VALID_STAGES своего скрипта
    (или в case-списке для скриптов, где VALID_STAGES нет);
  * что сборка DAG проходит и для каждой фазы отдельно, и для всех вместе.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "src"))

from lfs_orchestrator.dag import DAG, DAGError  # noqa: E402
from lfs_orchestrator.task import Task  # noqa: E402


def stages_of(script: Path) -> set[str] | None:
    """Допустимые стадии скрипта."""
    if not script.exists():
        return None
    text = script.read_text(encoding="utf-8", errors="replace")

    m = re.search(r"VALID_STAGES=\((.*?)\)", text, re.S)
    if m:
        return set(m.group(1).split())

    # fallback: case-список вида  binutils-pass1|gcc-pass1|...) die "..."
    m = re.search(r"case\s+\"\$ONLY\"\s+in(.*?)\n\s*esac", text, re.S)
    if m:
        body = m.group(1)
        out: set[str] = set()
        for line in body.splitlines():
            line = line.strip()
            if ")" not in line or line.startswith("*"):
                continue
            head = line.split(")", 1)[0]
            for part in head.split("|"):
                part = part.strip().strip('"').strip("'")
                if part and re.fullmatch(r"[A-Za-z0-9_.-]+", part):
                    out.add(part)
        return out or None
    return None


def load(cfg_path: Path):
    data = yaml.safe_load(cfg_path.read_text(encoding="utf-8"))
    defaults = data.get("defaults") or {}
    tasks: list[Task] = []
    for phase_name, phase in (data.get("phases") or {}).items():
        for name, t in (phase.get("tasks") or {}).items():
            tasks.append(Task(
                name=name,
                phase=phase_name,
                script=t["script"],
                args=t.get("args") or [],
                deps=t.get("deps") or [],
                timeout=t.get("timeout", defaults.get("timeout", 7200)),
            ))
    return tasks


def problem(level: str, msg: str) -> None:
    print(f"  {level} {msg}")


def check_config(cfg: Path) -> int:
    print("=" * 76)
    print("КОНФИГ:", cfg)
    if not cfg.exists():
        problem("ОШИБКА", "файл не найден")
        return 1

    tasks = load(cfg)
    by_id = {t.id: t for t in tasks}
    phases = sorted({t.phase for t in tasks}, key=lambda p: list(dict.fromkeys(t.phase for t in tasks)).index(p))
    print("  задач:", len(tasks), "| фазы:", ", ".join(f"{p}({sum(1 for t in tasks if t.phase == p)})" for p in phases))

    issues = 0

    # 1. скрипты и стадии
    for t in tasks:
        script = ROOT / t.script
        if not script.exists():
            problem("ОШИБКА", f"{t.id}: нет файла {t.script}")
            issues += 1
            continue
        if "--only" in t.args:
            i = t.args.index("--only")
            stage = t.args[i + 1] if i + 1 < len(t.args) else None
            known = stages_of(script)
            if not stage:
                problem("ОШИБКА", f"{t.id}: --only без значения")
                issues += 1
            elif known is None:
                problem("ИНФО", f"{t.id}: у {t.script} нет списка стадий — пропускаю сверку")
            elif stage not in known:
                problem("ОШИБКА", f"{t.id}: стадии '{stage}' нет в {t.script}")
                issues += 1

    # 2. зависимости
    for t in tasks:
        for d in t.deps:
            if d not in by_id:
                problem("ОШИБКА", f"{t.id}: зависимость '{d}' не существует")
                issues += 1

    # 3. DAG по фазам — ИНФО: межфазные зависимости в изоляции не разрешаются,
    #    это нормально; реальный запуск идёт кумулятивно (п. 5) или целиком (п. 4).
    order = list(dict.fromkeys(t.phase for t in tasks))
    for ph in order:
        subset = [t for t in tasks if t.phase == ph]
        try:
            DAG(subset)
            print(f"  OK       DAG для {ph} в изоляции ({len(subset)} задач)")
        except DAGError:
            print(f"  ИНФО     {ph} в изоляции зависит от других фаз — это норма")

    # 4. DAG целиком
    try:
        DAG(tasks)
        print(f"  OK       DAG целиком ({len(tasks)} задач)")
    except DAGError as exc:
        problem("DAGERROR", f"целиком: {exc}")
        issues += 1

    # 5. кумулятивно, как реально запускают фазы
    for i in range(1, len(order) + 1):
        combo = order[:i]
        subset = [t for t in tasks if t.phase in combo]
        try:
            DAG(subset)
        except DAGError as exc:
            problem("DAGERROR", f"{'+'.join(combo)}: {exc}")
            issues += 1

    print(f"  → замечаний: {issues}")
    return issues


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    total = 0
    for arg in sys.argv[1:]:
        total += check_config(Path(arg))
    print()
    print("ИТОГО замечаний:", total)
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main())
