# Raspberry Pi OS Bookworm Emulator

---

## Overview

**raspberry_emulator** provides a Dockerized QEMU environment for emulating **Raspberry Pi OS Bookworm (Debian 12, 64-bit)** targeting **Raspberry Pi 3B hardware** (`raspi3b`). The repository builds an Ubuntu 24.04 container running QEMU 8.2 (the first widely available build that includes `raspi4b` support, but falls back to `raspi3b` due to incomplete hardware emulation for Pi 4), automatically downloads the official Pi OS image, and boots the emulated Pi with full networking.

---

## Specifications

| Setting       | Value                            |
|---------------|----------------------------------|
| OS            | Raspberry Pi OS Bookworm (Debian 12) — 64-bit Lite |
| Architecture  | AArch64 (`qemu-system-aarch64`)  |
| QEMU Machine  | `raspi3b` (BCM2710, Cortex-A53)  |
| CPU           | Cortex-A53 × 4 (SMP)            |
| RAM           | 1024 MB (1 GiB) — fixed by raspi3b hardware |
| Storage       | 8 GB (sparse image, auto-expanded on first boot) |
| Default user  | `lumouser` / `lumouser`          |

---

## Prerequisites

- **Docker Desktop** with WSL2 backend (Windows) or Docker Engine (Linux)
- **docker compose** v2 or `docker-compose` v1.27+
- At least **8 GB free disk space** for the Pi OS image cache
- At least **7 GB RAM** available to Docker (guest uses 6 GB)

> [!NOTE]
> **RAM is fixed at 1 GiB.** QEMU's `raspi3b` machine type strictly mirrors real Raspberry Pi 3B hardware (BCM2710 1 GiB variant). Setting any other value will cause QEMU to refuse to start.

---

## Quick Start

**Method 1: Run a Custom Lumo Image (Recommended)**
If you are using the `raspberry_builder` repository to compile a custom `.img.gz` artifact, use the dedicated pipeline script:

```bash
bash run-emulator.sh
```
*(This automatically copies the image from the builder output and boots it in the foreground).*

**Method 2: Run a Vanilla Pi OS Image**
If you want to boot a completely fresh, stock Raspberry Pi OS image:

```bash
docker compose up --build
```
*(The official Pi OS Bookworm image downloads automatically on first run).*

First boot takes **3–5 minutes** — Pi OS expands the filesystem to 8 GB during this time. Subsequent boots are faster since the image is cached at `./work/cache/`.

---

## Accessing the Emulated Pi

| Service | Address                                        |
|---------|------------------------------------------------|
| SSH     | `ssh lumouser@localhost -p 2222`               |
| HTTP    | [http://localhost:8080](http://localhost:8080) |
| HTTPS   | [https://localhost:8443](https://localhost:8443) |

**Default credentials**

| Field    | Value      |
|----------|------------|
| Username | `lumouser` |
| Password | `lumouser` |

> [!IMPORTANT]
> Credentials are injected via `userconf.txt` on the first boot. If you want to change them, update `LUMO_USER` and `LUMO_PASS` in `docker-compose.yml` **before the first run**, or delete `./work/cache/raspios-bookworm-arm64-lite.img` to trigger a fresh download and re-injection.

---

## Configuration

All settings are controlled via environment variables in `docker-compose.yml`:

| Variable          | Default                                                    | Description                             |
|-------------------|------------------------------------------------------------|-----------------------------------------|
| `RASPI_IMAGE_URL` | Official Bookworm Lite 64-bit redirect URL                 | Override to use a local or custom image |
| `STORAGE_SIZE`    | `8G`                                                       | Guest disk size                         |
| `RAM_MB`          | `6144`                                                     | Guest RAM in MB                         |
| `SSH_HOST_PORT`   | `2222`                                                     | Host SSH port                           |
| `HTTP_HOST_PORT`  | `8080`                                                     | Host HTTP port                          |
| `HTTPS_HOST_PORT` | `8443`                                                     | Host HTTPS port                         |
| `LUMO_USER`       | `lumouser`                                                 | First-boot username                     |
| `LUMO_PASS`       | `lumouser`                                                 | First-boot password (hashed at runtime) |

### Using a pre-downloaded image

Place your `*.img` (or `*.img.xz`) file anywhere accessible and pass it as an argument, or bind-mount it:

```yaml
# docker-compose.yml override
volumes:
  - "/path/to/your.img:/build/work/cache/raspios-bookworm-arm64-lite.img:ro"
```

---

## Image Caching

Downloaded images are stored in `./work/cache/` on the host. This directory is persisted across container restarts via the `./work:/build/work` volume mount.

```
./work/
  cache/
    raspios-bookworm-arm64-lite.img   ← cached OS image (auto-downloaded)
  run/
    image.img                         ← working copy (deleted on exit)
    kernel.img
    serial.log
    qemu.log
```

---

## Storage — 8 GB Sparse Disk

The emulator resizes the Pi OS image to 8 GB using `qemu-img resize`. The file is **sparse** on the host filesystem — it only consumes actual written bytes, not the full 8 GB.

Pi OS Bookworm's built-in first-boot `init_resize.sh` automatically expands the root filesystem (`/dev/mmcblk0p2`) to fill the 8 GB space on the first boot.

Verify inside the guest after boot:
```bash
df -h /
# Filesystem      Size  Used Avail Use% Mounted on
# /dev/mmcblk0p2  7.7G  1.8G  5.6G  24% /
```

---

## Volumes and Port Summary

| Volume / Mount               | Purpose                                      |
|------------------------------|----------------------------------------------|
| `./scripts:/build/scripts:ro`| Emulator scripts (read-only)                 |
| `./work:/build/work`         | Persistent image cache and runtime work dir  |
| `/dev:/dev`                  | Loop-device and kpartx access (privileged)   |

| Host Port | Guest Port | Protocol |
|-----------|------------|----------|
| `2222`    | `22`       | SSH      |
| `8080`    | `80`       | HTTP     |
| `8443`    | `443`      | HTTPS    |

---

## Running a LAMP Stack

```bash
# SSH into the emulated Pi
ssh lumouser@localhost -p 2222

# Update and install LAMP
sudo apt update && sudo apt upgrade -y
sudo apt install -y apache2 mariadb-server php libapache2-mod-php php-mysql

# Enable and start services
sudo systemctl enable --now apache2 mariadb

# Verify
curl http://localhost   # from inside the guest
# or from the host:
curl http://localhost:8080
```

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Container exits immediately | Check `docker compose logs` — likely a kernel or DTB mismatch |
| No serial output for > 5 min | Normal on first boot (filesystem resize) — wait or tail `./work/run/serial.log` |
| SSH connection refused | Pi may still be booting; wait for `sshd` to start (can take 2–3 min on first boot) |
| `qemu-img resize` fails | Ensure Docker has write access to `./work/` |
| Out of memory (OOM) | Increase Docker Desktop memory limit to ≥ 7 GB |
| Image already cached but wrong version | Delete `./work/cache/raspios-bookworm-arm64-lite.img` to trigger a fresh download |

---

## CI Integration Tips

- Mount the cached image as a read-only volume in CI to skip the download step.
- Use `multiarch/qemu-user-static` for lightweight userspace emulation tests that don't need a full boot.
- Snapshot `./work/cache/` between pipeline runs for fast restarts.

---

## Contributing

- Open issues for bugs and feature requests
- Submit pull requests with clear descriptions
- Keep Dockerfiles minimal; document any added packages
- Shell scripts use `set -euo pipefail` — maintain that standard

---

## License

MIT License — include a `LICENSE` file in the repository root.

---

## Maintainer

**Ashan** — use repository issues for questions, bugs, and feature requests.

---