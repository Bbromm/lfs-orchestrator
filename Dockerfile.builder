FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        bash bison build-essential bzip2 \
        ca-certificates coreutils curl diffutils file findutils \
        flex gawk gcc g++ gettext git \
        gzip m4 make patch perl python3 \
        sed sudo tar texinfo wget xz-utils \
    && rm -rf /var/lib/apt/lists/*

ARG LFS_UID=1000
ARG LFS_GID=1000
RUN groupadd -g ${LFS_GID} lfs \
 && useradd  -u ${LFS_UID} -g ${LFS_GID} -m -s /bin/bash lfs \
 && echo 'lfs ALL=(ALL) NOPASSWD:ALL' >/etc/sudoers.d/lfs

RUN mkdir -p /root/lfs-build /mnt/lfs /logs /mnt/lfs/sources
WORKDIR /root/lfs-build
CMD ["/bin/bash"]