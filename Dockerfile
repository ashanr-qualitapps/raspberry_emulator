# ---------------------------------------------------------------------------
# Raspberry Pi OS Bookworm (Debian 12) — 64-bit QEMU Emulator
# Base image: Ubuntu 24.04 LTS
#   → ships QEMU 8.2.x which includes raspi4b (Pi 4B) machine support
#   → Debian Bookworm's QEMU build omits raspi4b; Ubuntu 24.04 does not
# ---------------------------------------------------------------------------

FROM ubuntu:24.04

# Suppress interactive prompts during apt installs
ENV DEBIAN_FRONTEND=noninteractive

# Install QEMU 8.x (raspi4b included), image utilities, network tools,
# and qemu-user-static + binfmt-support for aarch64 chroot provisioning
RUN apt-get update && apt-get install -y --no-install-recommends \
      bash \
      qemu-system-arm \
      qemu-user-static \
      binfmt-support \
      qemu-utils \
      systemd-container \
      dbus \
      ca-certificates \
      openssh-client \
      curl \
      wget \
      util-linux \
      kpartx \
      e2fsprogs \
      xz-utils \
      file \
      openssl \
      && rm -rf /var/lib/apt/lists/*

# Create build directory
WORKDIR /build

# Default entrypoint (overridden by docker-compose)
ENTRYPOINT ["/bin/bash", "-c"]
