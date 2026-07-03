FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC

RUN apt-get update \
  && echo 'tzdata tzdata/Areas select Etc' | debconf-set-selections \
  && echo 'tzdata tzdata/Zones/Etc select UTC' | debconf-set-selections \
  && apt-get install -y --no-install-recommends \
    qemu-user-static \
    qemu-system-aarch64 \
    kpartx \
    rsync \
    dosfstools \
    util-linux \
    uuid-runtime \
    gzip \
    tzdata \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /build
