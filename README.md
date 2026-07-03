### Raspberry Emulator README

---

## Overview
**raspberry_emulator** provides a Dockerized QEMU environment for emulating Raspberry Pi images and testing ARM workloads such as LAMP web applications. The repository includes a Docker Compose service that builds an Alpine-based container with QEMU, mounts host images and project files, and runs an emulator script.

---

## Features
- **Lightweight base** using Alpine Linux for smaller images  
- **QEMU system emulation** for ARM and AArch64 images  
- **Volume mounts** for Pi images, build artifacts, and web app files  
- **Port forwarding** to expose services from the emulated Pi to the host  
- **Scriptable entrypoint** so existing emulator scripts run unchanged

---

## Prerequisites
- **Docker Desktop** with WSL2 backend on Windows or Docker Engine on Linux  
- **docker-compose** v1.27+ or Compose v2 CLI  
- QEMU-compatible Raspberry Pi image file such as Raspberry Pi OS Lite or Desktop  
- Sufficient disk space and RAM for the emulated image

---

## Quick Start

1. **Place your Pi image** in the repository or a known host path, for example `../lumo_image_builder/output_image/raspbian.img`.  
2. **Ensure scripts** are present in `./scripts` and executable. The default entrypoint runs `run-raspi-emulator.sh`.  
3. **Build and start** the service:
```bash
docker compose up --build
```
4. **Access forwarded ports** on the host, for example `http://localhost:8080` if the emulated image runs a web server and the emulator script forwards port 80 to 8080.

---

## Docker Compose Notes
**Service**: `lumo-emulator`  
**Key behaviors**:
- Runs in **privileged** mode to allow device passthrough when required  
- Mounts host `/dev` into the container for device access when needed  
- Uses volumes to persist and share the Pi image and working files

**Example volumes mapping**
- `./scripts:/build/scripts:ro` read-only scripts  
- `./work:/build/work` working directory for builds and temporary files  
- `../lumo_image_builder/output_image:/build/output:ro` read-only Pi images and artifacts  
- `/dev:/dev` device access for passthrough

---

## Example Dockerfile for Alpine
Place this file as `Dockerfile.alpine` and reference it in `docker-compose.yml` build section.

```dockerfile
FROM alpine:3.18

RUN apk add --no-cache \
    bash \
    qemu-system \
    qemu-system-arm \
    qemu-system-aarch64 \
    qemu-img \
    ca-certificates \
    openssh-client \
    curl \
    util-linux

WORKDIR /build

ENTRYPOINT ["/bin/bash", "-c"]
```

---

## Example docker-compose.yml
Use this compose file to build the Alpine image and run the emulator service.

```yaml
version: '3.9'
services:
  lumo-emulator:
    build:
      context: .
      dockerfile: Dockerfile.alpine
    privileged: true
    volumes:
      - "./scripts:/build/scripts:ro"
      - "./work:/build/work"
      - "../lumo_image_builder/output_image:/build/output:ro"
      - "/dev:/dev"
    ports:
      - "8080:8080"
      - "8443:8443"
    working_dir: /build
    entrypoint: []
    command: >
      bash -lc "set -e; mkdir -p /build/work; bash /build/scripts/run-raspi-emulator.sh"
    restart: "no"
```

---

## Volumes and Storage Strategy
**Recommended patterns**
- **Host bind mounts** for development files so edits on the host are immediately visible inside the emulator. Example `- ./work:/build/work`.  
- **Named volumes** for persistent service data such as databases. Example `- db_data:/var/lib/mysql`.  
- **Bind mount Pi image** to a stable host path to avoid copying large images into containers. Example `- /path/to/raspbian.img:/build/output/raspbian.img:ro`.

**Remove volumes**
```bash
docker compose down
docker volume rm <volume_name>
```

---

## Running a LAMP Web App in the Emulator
1. Use a **Lite** or **Desktop** Raspberry Pi image depending on whether you need a GUI.  
2. Boot the image in QEMU via the emulator script. Ensure networking is enabled and ports are forwarded.  
3. Inside the emulated system install LAMP:
```bash
sudo apt update
sudo apt install -y apache2 mariadb-server php libapache2-mod-php php-mysql
```
4. Mount your web app into `/var/www/html` using the host bind mount so you can edit files on the host and test inside the emulator.  
5. Use `ab` or `siege` for lightweight performance checks but validate final performance on real Pi hardware.

---

## GUI Images
**If you need a desktop UI** use Raspberry Pi OS Desktop or Ubuntu MATE images. Allocate at least **1–2 GB RAM** and more disk space. GUI images are heavier and slower under QEMU.

---

## CI Integration Tips
- Use **multiarch/qemu-user-static** to register QEMU emulation in CI runners.  
- Prefer **Debian ARM base images** or Alpine for containerized tests rather than booting full `.img` files when speed is critical.  
- Snapshot or export container state for reproducible test runs.

---

## Troubleshooting
- **Emulator fails to boot**: verify kernel and device tree compatibility for the chosen image. Newer Pi models often require custom kernels or DTBs.  
- **Slow performance**: enable host acceleration where available or reduce emulated CPU count and memory to match expectations. QEMU pure emulation is slower than native hardware.  
- **Networking issues**: use `-net user,hostfwd=tcp::8080-:80` style forwarding in QEMU or map Docker ports to container ports.  
- **Permission errors with /dev**: ensure Docker is running with `privileged: true` and the host user has appropriate permissions.

---

## Contributing
**How to contribute**
- Open issues for bugs and feature requests  
- Submit pull requests with clear descriptions and tests where applicable  
- Keep Dockerfiles minimal and document any added packages

**Coding style**
- Shell scripts should be POSIX compatible where possible  
- Use `set -euo pipefail` in scripts to fail fast and avoid silent errors

---

## License
**MIT License**  
Include a `LICENSE` file in the repository root if not already present.

---

## Contact
**Maintainer** Ashan  
Repository issues are the preferred channel for questions, bug reports, and feature requests.

---