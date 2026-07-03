# Lumo Emulator

This folder provides a dedicated Docker-based emulator service for the built Raspberry Pi image.

## Purpose

The emulator boots the built `lumo-controller-final.img` artifact from `../lumo_image_builder/output_image/` using QEMU.

## Files

- `docker-compose.yml` - emulator Docker Compose service
- `Dockerfile` - container image with QEMU and mount tools
- `scripts/run-raspi-emulator.sh` - emulator launch script
- `work/` - host-mounted working directory for logs and temporary image files

## Run the emulator

From `D:\apps\lumo_controller_instance_two\lumo_emulator`:

```bash
docker compose build
docker compose run --rm --service-ports lumo-emulator
```

The service will use the built image artifact from:

```bash
../lumo_image_builder/output_image/lumo-controller-final.img.gz
```

If you want the emulator to use an already-uncompressed image, place it in the same output folder as:

```bash
../lumo_image_builder/output_image/lumo-controller-final.img
```

## Browser access

When the guest boots, open:

```bash
http://localhost:8080
https://localhost:8443
```

If the guest does not expose HTTPS, use the HTTP URL.

## Logs and debugging

Emulator logs are written into the host-mounted `work/` folder:

- `work/serial.log` — guest serial console output
- `work/qemu.log` — QEMU stderr output

If the emulator exits early, inspect logs with:

```bash
docker compose logs --tail=200 lumo-emulator
```

and check the host files:

```bash
cat work/serial.log
cat work/qemu.log
```
