#!/bin/bash
#
# Подготовка структуры каталогов LFS (§4.2 книги LFS 13.1-systemd)
# Идемпотентно: можно запускать сколько угодно раз.
#
set -euo pipefail

: "${LFS:?Переменная LFS не задана (например: LFS=/mnt/lfs)}"

echo "=== Подготовка структуры в $LFS ==="

# 1. Базовые каталоги
mkdir -pv "$LFS"/{etc,var}
mkdir -pv "$LFS"/usr/{bin,lib,sbin}
mkdir -pv "$LFS"/lib64
mkdir -pv "$LFS"/tools
mkdir -pv "$LFS"/sources
mkdir -pv "$LFS"/sources/logs

# 2. Симлинки bin/lib/sbin -> usr/...
for i in bin lib sbin; do
    ln -sfv "usr/$i" "$LFS/$i"
done

# 3. lib64 не должен быть симлинком — только настоящий каталог
if [ -L "$LFS/lib64" ]; then
    echo "[FIX] $LFS/lib64 — симлинк, заменяю на каталог"
    rm -f "$LFS/lib64"
    mkdir -pv "$LFS/lib64"
fi

# 4. Проверка
echo
echo "=== Проверка ls -ld ==="
ls -ld \
    "$LFS"/{bin,lib,sbin,lib64} \
    "$LFS"/usr/{bin,lib,sbin} \
    "$LFS"/{etc,var,tools,sources}

echo
echo "=== Проверка типов ==="
fail=0
for p in bin lib sbin; do
    if [ -L "$LFS/$p" ] && [ "$(readlink "$LFS/$p")" = "usr/$p" ]; then
        echo "[OK]  $LFS/$p -> usr/$p"
    else
        echo "[ERR] $LFS/$p — не симлинк на usr/$p"; fail=1
    fi
done

for p in lib64 usr/bin usr/lib usr/sbin etc var tools sources; do
    if [ -d "$LFS/$p" ]; then
        echo "[OK]  $LFS/$p — каталог"
    else
        echo "[ERR] $LFS/$p — отсутствует или не каталог"; fail=1
    fi
done

if [ "$fail" -eq 0 ]; then
    echo
    echo "=== Всё в порядке ==="
else
    echo
    echo "=== Есть проблемы, см. [ERR] выше ==="
    exit 1
fi