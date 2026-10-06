#!/usr/bin/env python3
import sys
import yaml

SRC = "config/lfs-default.yaml"
DST = "config/test.yaml"

with open(SRC) as f:
    cfg = yaml.safe_load(f)

# 1. Собираем: task_name -> список фаз, где он определён
task_to_phases = {}
for phase_name, phase in cfg["phases"].items():
    for task_name in (phase.get("tasks") or {}):
        task_to_phases.setdefault(task_name, []).append(phase_name)

dups = {t: ps for t, ps in task_to_phases.items() if len(ps) > 1}
if dups:
    print("⚠ Дубли имён задач между фазами:", file=sys.stderr)
    for t, ps in dups.items():
        print(f"  {t}: {ps}", file=sys.stderr)

# 2. Переписываем deps: сначала ищем в текущей фазе, потом глобально
unresolved = []
for phase_name, phase in cfg["phases"].items():
    for task_name, task in (phase.get("tasks") or {}).items():
        deps = task.get("deps") or []
        new_deps = []
        for d in deps:
            if "/" in d:
                new_deps.append(d)
                continue
            if phase_name in task_to_phases.get(d, []):
                new_deps.append(f"{phase_name}/{d}")
            elif len(task_to_phases.get(d, [])) == 1:
                new_deps.append(f"{task_to_phases[d][0]}/{d}")
            else:
                unresolved.append((phase_name, task_name, d))
                new_deps.append(d)  # оставим как есть, чтобы было видно
        task["deps"] = new_deps

if unresolved:
    print("❌ Не удалось однозначно разрешить:", file=sys.stderr)
    for ph, t, d in unresolved:
        print(f"  {ph}/{t} -> {d}", file=sys.stderr)

# 3. Ещё раз проверим, что все зависимости существуют
missing = []
for phase_name, phase in cfg["phases"].items():
    for task_name, task in (phase.get("tasks") or {}).items():
        for d in task.get("deps") or []:
            if "/" not in d:
                continue
            dp, _, dt = d.partition("/")
            if dp not in cfg["phases"] or dt not in (cfg["phases"][dp].get("tasks") or {}):
                missing.append((phase_name, task_name, d))

if missing:
    print("❌ Ссылки на несуществующие задачи:", file=sys.stderr)
    for ph, t, d in missing:
        print(f"  {ph}/{t} -> {d}", file=sys.stderr)

with open(DST, "w") as f:
    yaml.safe_dump(cfg, f, default_flow_style=False, sort_keys=False, allow_unicode=True)

print(f"✓ Записано: {DST}")