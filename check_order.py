#!/usr/bin/env python3
"""check_order.py — ищет в конфиге зависимости, которые ломают порядок сборки.

Скрипт install-chapter8.sh строит пакеты в порядке из main(). Если в конфиге
задача зависит от той, что идёт в скрипте ПОЗЖЕ, оркестратор отложит первую
до конца сборки — и получится, что нужный пакет не установлен вовремя
(именно так pkgconf не попал в сборку до shadow).

Выводит пары «задача → зависимость», где зависимость идёт позже.
"""
from __future__ import annotations

import pathlib
import re
import sys

import yaml

BASE = pathlib.Path("/home/user/Документы/lfs/lfs-orchestrator")
CFG = BASE / "config/lfs-default.yaml"
SCRIPT = BASE / "scripts/install-chapter8.sh"

# порядок вызовов из main()
text = SCRIPT.read_text(encoding="utf-8")
main_body = text.split("main()", 1)[1]
order = re.findall(r"should_run_and_build\s+([a-z0-9_-]+)\s+", main_body)
pos = {name: i for i, name in enumerate(order)}
print(f"пакетов в порядке скрипта: {len(order)}")

cfg = yaml.safe_load(CFG.read_text(encoding="utf-8"))
tasks = cfg["phases"].get("phase8", {}).get("tasks", {})

problems = []
unknown = []
for name, t in tasks.items():
    for dep in t.get("deps") or []:
        if not dep.startswith("phase8/"):
            continue
        dep_name = dep.split("/", 1)[1]
        if dep_name not in pos:
            unknown.append((name, dep))
            continue
        if name not in pos:
            continue
        if pos[dep_name] > pos[name]:
            problems.append((name, dep_name, pos[name], pos[dep_name]))

print()
if problems:
    print("ОПЕРЕЖАЮЩИЕ ЗАВИСИМОСТИ (зависимость идёт позже задачи):")
    for name, dep, p1, p2 in sorted(problems, key=lambda x: x[2]):
        print(f"  {name:14} (#{p1:3}) → {dep:14} (#{p2:3})   разрыв {p2 - p1}")
else:
    print("опережающих зависимостей нет")

if unknown:
    print()
    print("зависимости на пакеты, которых нет в порядке скрипта:")
    for name, dep in unknown[:10]:
        print(f"  {name} → {dep}")

sys.exit(1 if problems else 0)
