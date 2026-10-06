###############################################################################
# Dockerfile.lfs — Полная сборка LFS в Docker-контейнере
#
# Использование:
#   docker build -f Dockerfile.lfs -t lfs-builder .
#   docker run --privileged --rm -it \
#       -v /dev:/dev \
#       -v $(pwd)/output:/output \
#       lfs-builder
#
# ВНИМАНИЕ: --privileged нужен для chroot и mount. Контейнер НЕ изолирован
# полностью — используется только для чистоты окружения сборки.
###############################################################################

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV LC_ALL=C

# --- Установка хостовых зависимостей для LFS ---
RUN apt-get update && apt-get install -y \
    bash binutils bison build-essential coreutils diffutils findutils \
    gawk gcc g++ gzip m4 make patch perl python3 sed tar texinfo xz-utils \
    wget curl git ca-certificates \
    bzip2 gzip lz4 zstd \
    dosfstools e2fsprogs \
    # Для проверки хоста:
    file less bc flex \
    # Утилиты сборки:
    autoconf automake libtool pkg-config \
    # Ядро и GRUB:
    libncurses-dev libssl-dev libelf-dev \
    # Прочее:
    gettext texinfo \
    && rm -rf /var/lib/apt/lists/*

# --- Создание пользователя lfs ---
RUN groupadd lfs && \
    useradd -s /bin/bash -g lfs -m -k /dev/null lfs && \
    echo "lfs:lfs" | chpasswd

# --- Симлинки, требуемые LFS ---
RUN ln -sf /bin/bash /bin/sh && \
    ln -sf /usr/bin/gawk /usr/bin/awk && \
    ln -sf /usr/bin/bison /usr/bin/yacc

# --- Окружение сборки ---
ENV LFS=/mnt/lfs
ENV LFS_TGT=x86_64-lfs-linux-gnu
RUN mkdir -p ${LFS} && chown lfs:lfs ${LFS}

# --- Копирование скриптов сборки ---
COPY --chown=lfs:lfs build-lfs.sh /root/lfs-build/
COPY --chown=lfs:lfs lfs-config.sh /root/lfs-build/
COPY --chown=lfs:lfs scripts/ /root/lfs-build/scripts/
COPY --chown=lfs:lfs notifier.sh /root/lfs-build/
COPY --chown=lfs:lfs web-monitor.py /root/lfs-build/
RUN chmod +x /root/lfs-build/*.sh /root/lfs-build/scripts/*.sh

# --- Точка входа ---
WORKDIR /root/lfs-build
ENTRYPOINT ["/root/lfs-build/docker-entrypoint.sh"]