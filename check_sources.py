#!/usr/bin/env python3
"""check_sources.py — сверка архивов в sources/ с тем, что требуют скрипты + md5.

    1. Собирает имена архивов, которые запрашивают скрипты (extract/simple_build).
    2. Сравнивает с фактическим содержимым sources/.
    3. Проверяет md5 каждого архива по sources/md5sums.
    4. Показывает архивы, которые скриптами не используются.
"""
from __future__ import annotations

import hashlib
import pathlib
import re
import sys

BASE = pathlib.Path("/home/user/Документы/lfs")
SRC = BASE / "sources"
SCRIPTS = BASE / "lfs-orchestrator" / "scripts"

EXT = r"(?:tar\.(?:xz|gz|bz2|zst)|tgz|tar)"
IN_SCRIPT = re.compile(r'"([\w.+-]+\.' + EXT + r')"')
IS_ARCHIVE = re.compile(r"[\w.+-]+\.(?:" + EXT + r")")


def archive_name(name: str) -> bool:
    return bool(IS_ARCHIVE.fullmatch(name))


def md5(path: pathlib.Path) -> str:
    h = hashlib.md5()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main() -> int:
    if not SRC.is_dir():
        print("нет каталога", SRC)
        return 1

    files = sorted(p.name for p in SRC.iterdir() if p.is_file())
    archives = [n for n in files if archive_name(n)]
    others = [n for n in files if n not in archives]

    print("=" * 76)
    print(f"sources/: {len(files)} файлов, из них архивов {len(archives)}, прочих {len(others)}")

    required: dict[str, set[str]] = {}
    for sh in sorted(SCRIPTS.glob("*.sh")):
        text = sh.read_text(encoding="utf-8", errors="replace")
        for m in IN_SCRIPT.finditer(text):
            required.setdefault(m.group(1), set()).add(sh.name)

    present = set(archives)
    missing = {a: f for a, f in required.items() if a not in present}
    unused = [a for a in archives if a not in required]

    print(f"Требуется скриптами: {len(required)} архивов")

    print()
    if missing:
        print(f"✗ ОТСУТСТВУЮТ ({len(missing)}):")
        for a, names in sorted(missing.items()):
            print(f"    {a}   ← {', '.join(sorted(names))}")
    else:
        print("✓ все требуемые архивы на месте")

    if unused:
        print(f"\n· не используются скриптами ({len(unused)}):")
        for a in unused:
            print(f"    {a}")

    md5f = SRC / "md5sums"
    print()
    print("=" * 76)
    if not md5f.exists():
        print("md5sums нет — проверка целостности невозможна")
        return 0

    expected: dict[str, str] = {}
    for line in md5f.read_text(encoding="utf-8", errors="replace").splitlines():
        parts = line.split()
        if len(parts) >= 2:
            expected[parts[-1].lstrip("*")] = parts[0]
    print(f"md5sums: {len(expected)} записей")

    bad, ok, nohash = [], 0, []
    for name in archives:
        want = expected.get(name)
        if not want:
            nohash.append(name)
            continue
        got = md5(SRC / name)
        if got == want:
            ok += 1
        else:
            bad.append((name, want, got))

    print(f"  совпало: {ok}")
    if bad:
        print(f"  ✗ НЕ СОВПАЛО ({len(bad)}):")
        for name, want, got in bad:
            print(f"      {name}")
            print(f"        ожидалось {want}")
            print(f"        получено  {got}")
    if nohash:
        print(f"  ? нет в md5sums ({len(nohash)}): {', '.join(nohash[:8])}"
              + (" …" if len(nohash) > 8 else ""))

    return 1 if (bad or missing) else 0


if __name__ == "__main__":
    sys.exit(main())
