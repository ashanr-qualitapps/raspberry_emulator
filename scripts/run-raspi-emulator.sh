#!/usr/bin/env bash
set -euo pipefail

if [[ $# -gt 1 ]]; then
  echo "Usage: $0 [raspios.img | /build/output/lumo-controller-final.img(.gz)]" >&2
  exit 1
fi

if [[ $# -eq 1 ]]; then
  IMAGE_PATH="$1"
else
  if [[ -f "/build/output/lumo-controller-final.img" ]]; then
    IMAGE_PATH="/build/output/lumo-controller-final.img"
  elif [[ -f "/build/output/lumo-controller-final.img.gz" ]]; then
    IMAGE_PATH="/build/output/lumo-controller-final.img.gz"
  else
    echo "Error: no image provided and no built image found at /build/output" >&2
    exit 1
  fi
fi

WORK_ROOT="/build/work"
BOOT_MNT="/mnt/pi-boot"
LOOP_DEVICE=""
QEMU_PID=""
SERIAL_LOG=""
QEMU_LOG=""
TAIL_PID=""

cleanup() {
  local rc=$?
  set +e
  if [[ -n "$TAIL_PID" ]]; then
    kill "$TAIL_PID" >/dev/null 2>&1 || true
    wait "$TAIL_PID" 2>/dev/null || true
  fi
  if [[ -n "$QEMU_PID" ]]; then
    kill "$QEMU_PID" >/dev/null 2>&1 || true
    wait "$QEMU_PID" 2>/dev/null || true
  fi
  if mountpoint -q "$BOOT_MNT"; then
    umount "$BOOT_MNT"
  fi
  if [[ -n "$LOOP_DEVICE" ]]; then
    kpartx -dv "$LOOP_DEVICE" >/dev/null 2>&1 || true
    losetup -d "$LOOP_DEVICE" >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK_ROOT"
  exit $rc
}
trap cleanup EXIT

wait_for_web() {
  local deadline=$((SECONDS + 240))
  while (( SECONDS < deadline )); do
    if exec 3<>/dev/tcp/127.0.0.1/8080 >/dev/null 2>&1; then
      printf 'GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n' >&3
      if read -r status <&3; then
        if [[ "$status" =~ ^HTTP/[0-9]+\.[0-9]+[[:space:]]+([0-9]+) ]]; then
          echo "[raspi-emulator] web UI HTTP response status: ${BASH_REMATCH[1]}"
          if [[ "${BASH_REMATCH[1]}" == "200" || "${BASH_REMATCH[1]}" == "302" || "${BASH_REMATCH[1]}" == "403" || "${BASH_REMATCH[1]}" == "404" ]]; then
            echo "[raspi-emulator] web UI available at http://localhost:8080"
            exec 3>&- 3<&-
            return 0
          fi
        fi
      fi
      exec 3>&- 3<&-
    fi
    sleep 2
  done
  return 1
}

log() {
  echo "[raspi-emulator] $*"
}

if [[ ! -f "$IMAGE_PATH" ]]; then
  echo "Error: image file not found: $IMAGE_PATH" >&2
  exit 1
fi

mkdir -p "$WORK_ROOT" "$BOOT_MNT"

log "Copying Raspberry Pi image to workdir"
mkdir -p "$WORK_ROOT"
SERIAL_LOG="$WORK_ROOT/serial.log"
QEMU_LOG="$WORK_ROOT/qemu.log"
rm -f "$SERIAL_LOG" "$QEMU_LOG"
touch "$SERIAL_LOG" "$QEMU_LOG"
log "Logging serial output to $SERIAL_LOG"
log "Logging QEMU stderr to $QEMU_LOG"
if [[ "$IMAGE_PATH" == *.gz ]]; then
  log "Decompressing gzip image from $IMAGE_PATH"
  gzip -dc "$IMAGE_PATH" > "$WORK_ROOT/image.img"
  IMAGE_PATH="$WORK_ROOT/image.img"
else
  cp "$IMAGE_PATH" "$WORK_ROOT/image.img"
  IMAGE_PATH="$WORK_ROOT/image.img"
fi

IMAGE_SIZE_BYTES=$(stat -c '%s' "$IMAGE_PATH")
if (( IMAGE_SIZE_BYTES <= 0 )); then
  echo "Error: invalid image size: $IMAGE_SIZE_BYTES" >&2
  exit 1
fi

GIB=$((1024 * 1024 * 1024))
POW2=$GIB
while (( POW2 < IMAGE_SIZE_BYTES )); do
  POW2=$(( POW2 * 2 ))
done
if (( POW2 < 2 * GIB )); then
  POW2=$((2 * GIB))
fi
if (( IMAGE_SIZE_BYTES != POW2 )); then
  log "Resizing image from ${IMAGE_SIZE_BYTES} bytes to ${POW2} bytes"
  truncate -s "$POW2" "$IMAGE_PATH"
fi

log "Attaching loop device"
LOOP_DEVICE=$(losetup --show -fP "$IMAGE_PATH")
if [[ -z "$LOOP_DEVICE" ]]; then
  echo "Error: failed to attach loop device" >&2
  exit 1
fi
log "Loop device: $LOOP_DEVICE"

BOOT_PART=""
ROOT_PART=""
if [[ -b "${LOOP_DEVICE}p1" && -b "${LOOP_DEVICE}p2" ]]; then
  BOOT_PART="${LOOP_DEVICE}p1"
  ROOT_PART="${LOOP_DEVICE}p2"
  log "Using loop partition devices: $BOOT_PART, $ROOT_PART"
else
  log "Mapping partitions with kpartx"
  kpartx -av "$LOOP_DEVICE"
  BOOT_PART="/dev/mapper/$(basename "$LOOP_DEVICE")p1"
  ROOT_PART="/dev/mapper/$(basename "$LOOP_DEVICE")p2"
fi

if [[ ! -b "$BOOT_PART" || ! -b "$ROOT_PART" ]]; then
  echo "Error: expected partition devices not present: $BOOT_PART, $ROOT_PART" >&2
  ls -l "${LOOP_DEVICE}"* || true
  ls -l /dev/mapper || true
  exit 1
fi

log "Mounting boot partition"
mount "$BOOT_PART" "$BOOT_MNT"

BOOT_KERNEL=""
for candidate in kernel8.img kernel7.img kernel.img; do
  if [[ -f "$BOOT_MNT/$candidate" ]]; then
    BOOT_KERNEL="$candidate"
    break
  fi
done

if [[ -z "$BOOT_KERNEL" ]]; then
  echo "Error: no kernel image found in boot partition" >&2
  ls -la "$BOOT_MNT" || true
  exit 1
fi

if [[ -f "$BOOT_MNT/bcm2710-rpi-3-b.dtb" ]]; then
  MACHINE="raspi3b"
  DTB_FILE="bcm2710-rpi-3-b.dtb"
elif [[ -f "$BOOT_MNT/bcm2710-rpi-2-b.dtb" ]]; then
  MACHINE="raspi2b"
  DTB_FILE="bcm2710-rpi-2-b.dtb"
elif [[ -f "$BOOT_MNT/bcm2708-rpi-zero.dtb" ]]; then
  MACHINE="raspi0"
  DTB_FILE="bcm2708-rpi-zero.dtb"
else
  echo "Error: no supported Raspberry Pi dtb found" >&2
  ls -la "$BOOT_MNT" | sed -n '1,200p'
  exit 1
fi

cp "$BOOT_MNT/$BOOT_KERNEL" "$WORK_ROOT/kernel.img"
cp "$BOOT_MNT/$DTB_FILE" "$WORK_ROOT/$DTB_FILE"

if [[ -f "$BOOT_MNT/cmdline.txt" ]]; then
  CMDLINE=$(tr -d '\n' < "$BOOT_MNT/cmdline.txt")
else
  CMDLINE="root=/dev/mmcblk0p2 rw rootwait"
fi

# Use a single known serial console for QEMU logging
CMDLINE=$(sed -E 's/console=[^ ]+//g' <<< "$CMDLINE")
CMDLINE=$(sed -E 's/\s+/ /g' <<< "$CMDLINE")
CMDLINE=$(sed -E 's/root=PARTUUID=[^ ]*/root=\/dev\/mmcblk0p2/' <<< "$CMDLINE")
CMDLINE="$CMDLINE console=ttyAMA0,115200"
CMDLINE=$(sed -E 's/^\s+|\s+$//g' <<< "$CMDLINE")

umount "$BOOT_MNT"

log "Launching Raspberry Pi emulator"
log "- machine: $MACHINE"
log "- kernel: $WORK_ROOT/kernel.img"
log "- dtb: $WORK_ROOT/$DTB_FILE"
log "- image: $WORK_ROOT/image.img"
log "- cmdline: $CMDLINE"
log "- guest HTTP forwarded to localhost:8080"
log "- guest HTTPS forwarded to localhost:8443"
log "- serial log: $SERIAL_LOG"
log "- qemu stderr: $QEMU_LOG"
log "- host work dir mount: $WORK_ROOT"

log "QEMU version: $(qemu-system-aarch64 --version | head -1)"
log "Loop device details:"
losetup -a | grep "$WORK_ROOT/image.img" || true

QEMU_CMD=(
  qemu-system-aarch64
  -M "$MACHINE"
  -m 1024
  -kernel "$WORK_ROOT/kernel.img"
  -dtb "$WORK_ROOT/$DTB_FILE"
  -drive "file=$WORK_ROOT/image.img,format=raw,if=sd"
  -netdev "user,id=net0,hostfwd=tcp::8080-:80,hostfwd=tcp::8443-:443"
  -device "usb-net,netdev=net0,mac=52:54:00:12:34:56"
  -append "$CMDLINE"
  -serial "file:$SERIAL_LOG"
  -monitor none
  -nographic
  -no-reboot
)
log "QEMU command: ${QEMU_CMD[*]}"

"${QEMU_CMD[@]}" 2>"$QEMU_LOG" &
QEMU_PID=$!

tail -F "$SERIAL_LOG" "$QEMU_LOG" &
TAIL_PID=$!

if [[ -z "$QEMU_PID" ]]; then
  echo "Error: failed to start QEMU" >&2
  exit 1
fi

log "Serial output logging to $SERIAL_LOG"
log "QEMU stderr logging to $QEMU_LOG"

if wait_for_web; then
  echo "[raspi-emulator] ready for browser access"
  wait "$QEMU_PID"
else
  echo "Error: timed out waiting for the guest web UI" >&2
  echo "[raspi-emulator] tailing last 50 lines from serial.log and qemu.log:"
  echo "--- serial.log ---"
  tail -n 50 "$SERIAL_LOG" || true
  echo "--- qemu.log ---"
  tail -n 50 "$QEMU_LOG" || true
  kill "$QEMU_PID" >/dev/null 2>&1 || true
  wait "$QEMU_PID" 2>/dev/null || true
  exit 1
fi
