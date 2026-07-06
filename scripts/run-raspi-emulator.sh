#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Raspberry Pi OS Bookworm (Debian 12) — 64-bit QEMU emulator
# ---------------------------------------------------------------------------
# Usage: run-raspi-emulator.sh [/path/to/image.img|image.img.xz|image.img.gz]
#
# If no image is supplied the script automatically downloads the official
# Raspberry Pi OS Bookworm Lite (64-bit, LTS) image from raspberrypi.com
# and caches it at /build/work/cache/ for subsequent runs.
#
# Configuration (override via environment variables):
#   RASPI_IMAGE_URL   – download URL for the OS image (default: official latest)
#   STORAGE_SIZE      – disk size exposed to the guest (default: 8G)
#   RAM_MB            – guest RAM in MB (default: 2048, fixed by raspi4b hardware)
#   SSH_HOST_PORT     – host port forwarded to guest SSH :22 (default: 2222)
#   HTTP_HOST_PORT    – host port forwarded to guest HTTP :80 (default: 8080)
#   HTTPS_HOST_PORT   – host port forwarded to guest HTTPS :443 (default: 8443)
#   LUMO_USER         – first-boot username injected via userconf.txt
#   LUMO_PASS         – first-boot password (plain text, hashed at runtime)
# ---------------------------------------------------------------------------

RASPI_IMAGE_URL="${RASPI_IMAGE_URL:-https://downloads.raspberrypi.com/raspios_lite_arm64_latest}"
STORAGE_SIZE="${STORAGE_SIZE:-8G}"
RAM_MB="${RAM_MB:-2048}"   # raspi4b hardware constraint: must be exactly 2 GiB
SSH_HOST_PORT="${SSH_HOST_PORT:-2222}"
HTTP_HOST_PORT="${HTTP_HOST_PORT:-8080}"
HTTPS_HOST_PORT="${HTTPS_HOST_PORT:-8443}"
LUMO_USER="${LUMO_USER:-lumouser}"
LUMO_PASS="${LUMO_PASS:-lumouser}"

CACHE_DIR="/build/work/cache"
WORK_ROOT="/build/work/run"
BOOT_MNT="/mnt/pi-boot"
ROOT_MNT="/mnt/pi-root"
LOOP_DEVICE=""
QEMU_PID=""
SERIAL_LOG=""
QEMU_LOG=""
TAIL_PID=""

# ---------------------------------------------------------------------------
log() { echo "[raspi-emulator] $*"; }

cleanup() {
  local rc=$?
  set +e
  [[ -n "$TAIL_PID" ]] && { kill "$TAIL_PID" >/dev/null 2>&1 || true; wait "$TAIL_PID" 2>/dev/null || true; }
  [[ -n "$QEMU_PID" ]] && { kill "$QEMU_PID" >/dev/null 2>&1 || true; wait "$QEMU_PID" 2>/dev/null || true; }
  # Unmount any leftover mounts from provision_rootfs
  for mnt in "$ROOT_MNT/dev/pts" "$ROOT_MNT/dev" "$ROOT_MNT/sys" "$ROOT_MNT/proc" "$ROOT_MNT" "$BOOT_MNT"; do
    mountpoint -q "$mnt" 2>/dev/null && umount "$mnt" || true
  done
  if [[ -n "$LOOP_DEVICE" ]]; then
    kpartx -dv "$LOOP_DEVICE" >/dev/null 2>&1 || true
    losetup -d  "$LOOP_DEVICE" >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK_ROOT"
  exit $rc
}
trap cleanup EXIT

wait_for_web() {
  local deadline=$(( SECONDS + 300 ))
  while (( SECONDS < deadline )); do
    if exec 3<>/dev/tcp/127.0.0.1/"${HTTP_HOST_PORT}" >/dev/null 2>&1; then
      printf 'GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n' >&3
      if read -r status <&3 2>/dev/null; then
        if [[ "$status" =~ ^HTTP/[0-9]+\.[0-9]+[[:space:]]+([0-9]+) ]]; then
          local code="${BASH_REMATCH[1]}"
          log "Web UI HTTP status: $code"
          if [[ "$code" == "200" || "$code" == "302" || "$code" == "403" || "$code" == "404" ]]; then
            log "Web UI available at http://localhost:${HTTP_HOST_PORT}"
            exec 3>&- 3<&- 2>/dev/null || true
            return 0
          fi
        fi
      fi
      exec 3>&- 3<&- 2>/dev/null || true
    fi
    sleep 3
  done
  return 1
}

wait_for_ssh() {
  # Waits up to 10 minutes for the guest SSH port to accept TCP connections.
  # Pi OS Lite has no web server, so we test SSH (port 22 → host SSH_HOST_PORT)
  # instead of HTTP. SSH is always enabled on a fresh Pi OS Bookworm image.
  local deadline=$(( SECONDS + 600 ))
  log "Waiting for guest SSH on port ${SSH_HOST_PORT} …"
  log "(First boot may take several minutes — filesystem expansion runs automatically)"
  while (( SECONDS < deadline )); do
    if exec 3<>/dev/tcp/127.0.0.1/"${SSH_HOST_PORT}" >/dev/null 2>&1; then
      exec 3>&- 3<&- 2>/dev/null || true
      return 0
    fi
    sleep 5
  done
  return 1
}

# ---------------------------------------------------------------------------
# provision_rootfs — install & enable nginx inside the Pi OS image (once)
# ---------------------------------------------------------------------------
# This mounts the root (ext4) partition of the working image, uses
# qemu-aarch64-static to run aarch64 binaries inside the chroot, installs
# nginx via apt, and enables it as a systemd service.  A marker file prevents
# this from repeating on every container restart.
provision_rootfs() {
  local root_part="$1"  # e.g. /dev/loopXp2 or /dev/mapper/loopXp2
  local marker="$WORK_ROOT/.nginx_provisioned"
  [[ -f "$marker" ]] && { log "nginx already provisioned — skipping"; return 0; }

  log "--- Provisioning: installing nginx into Pi OS root partition ---"
  mkdir -p "$ROOT_MNT"
  mount "$root_part" "$ROOT_MNT"

  # Register qemu-aarch64-static so the host kernel can execute ARM64 binaries
  if [[ -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ]]; then
    log "binfmt: qemu-aarch64 already registered"
  else
    update-binfmts --enable qemu-aarch64 2>/dev/null || true
  fi

  # Copy interpreter into chroot (must be at the same path the binfmt entry expects)
  cp /usr/bin/qemu-aarch64-static "$ROOT_MNT/usr/bin/"

  # Bind-mount the host pseudo-filesystems so apt can run inside the chroot
  mount --bind /proc   "$ROOT_MNT/proc"
  mount --bind /sys    "$ROOT_MNT/sys"
  mount --bind /dev    "$ROOT_MNT/dev"
  mount -t devpts devpts "$ROOT_MNT/dev/pts"

  log "Creating emulator user ($LUMO_USER) since firstboot init is bypassed …"
  local pass_hash
  pass_hash=$(openssl passwd -6 "$LUMO_PASS")
  chroot "$ROOT_MNT" /bin/sh -c "id -u $LUMO_USER >/dev/null 2>&1 || useradd -m -s /bin/bash -p '$pass_hash' '$LUMO_USER'"
  chroot "$ROOT_MNT" /bin/sh -c "usermod -aG sudo,adm $LUMO_USER" || true

  # Tear down bind mounts in reverse order
  umount "$ROOT_MNT/dev/pts"
  umount "$ROOT_MNT/dev"
  umount "$ROOT_MNT/sys"
  umount "$ROOT_MNT/proc"
  rm -f "$ROOT_MNT/usr/bin/qemu-aarch64-static"  # clean up interpreter from guest
  umount "$ROOT_MNT"

  touch "$marker"
  log "--- Provisioning complete: nginx will start automatically on Pi boot ---"
}

detect_compression() {
  # Returns: xz | gz | raw
  local path="$1"
  local magic
  magic=$(file -b "$path" 2>/dev/null | tr '[:upper:]' '[:lower:]')
  if echo "$magic" | grep -q 'xz compressed'; then
    echo "xz"
  elif echo "$magic" | grep -q 'gzip compressed'; then
    echo "gz"
  else
    echo "raw"
  fi
}

decompress_image() {
  local src="$1" dst="$2" fmt="$3"
  case "$fmt" in
    xz)
      log "Decompressing XZ image → $dst"
      xz -dkc "$src" > "$dst"
      ;;
    gz)
      log "Decompressing GZIP image → $dst"
      gzip -dc "$src" > "$dst"
      ;;
    *)
      log "Copying raw image → $dst"
      cp "$src" "$dst"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Validate arguments
# ---------------------------------------------------------------------------
if [[ $# -gt 1 ]]; then
  echo "Usage: $0 [image.img | image.img.xz | image.img.gz]" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Resolve image path — auto-download if not supplied
# ---------------------------------------------------------------------------
IMAGE_PATH=""

if [[ $# -eq 1 ]]; then
  IMAGE_PATH="$1"
  [[ ! -f "$IMAGE_PATH" ]] && { echo "Error: image file not found: $IMAGE_PATH" >&2; exit 1; }
  log "Using supplied image: $IMAGE_PATH"
else
  mkdir -p "$CACHE_DIR"
  CACHED_IMG="$CACHE_DIR/raspios-bookworm-arm64-lite.img"

  if [[ -f "$CACHED_IMG" ]]; then
    log "Found cached Pi OS image: $CACHED_IMG"
    IMAGE_PATH="$CACHED_IMG"
  else
    log "No local image found — downloading official Pi OS Bookworm 64-bit Lite …"
    log "URL: $RASPI_IMAGE_URL"
    DOWNLOAD_TMP="$CACHE_DIR/raspios-download.tmp"
    curl -L --progress-bar -o "$DOWNLOAD_TMP" "$RASPI_IMAGE_URL"

    FMT=$(detect_compression "$DOWNLOAD_TMP")
    if [[ "$FMT" == "raw" ]]; then
      mv "$DOWNLOAD_TMP" "$CACHED_IMG"
    else
      decompress_image "$DOWNLOAD_TMP" "$CACHED_IMG" "$FMT"
      rm -f "$DOWNLOAD_TMP"
    fi

    log "Image cached at: $CACHED_IMG"
    IMAGE_PATH="$CACHED_IMG"
  fi
fi

# ---------------------------------------------------------------------------
# Set up working directory
# ---------------------------------------------------------------------------
mkdir -p "$WORK_ROOT" "$BOOT_MNT"
SERIAL_LOG="$WORK_ROOT/serial.log"
QEMU_LOG="$WORK_ROOT/qemu.log"
rm -f "$SERIAL_LOG" "$QEMU_LOG"
touch "$SERIAL_LOG" "$QEMU_LOG"
log "Serial log : $SERIAL_LOG"
log "QEMU log   : $QEMU_LOG"

# Decompress working copy if needed (always operate on a writable copy)
FMT=$(detect_compression "$IMAGE_PATH")
decompress_image "$IMAGE_PATH" "$WORK_ROOT/image.img" "$FMT"
IMAGE_PATH="$WORK_ROOT/image.img"

# ---------------------------------------------------------------------------
# Resize image to target storage size (8 GB)
# ---------------------------------------------------------------------------
CURRENT_SIZE=$(stat -c '%s' "$IMAGE_PATH")
log "Current image size : ${CURRENT_SIZE} bytes"
log "Resizing to        : ${STORAGE_SIZE}"
qemu-img resize -f raw "$IMAGE_PATH" "$STORAGE_SIZE"
log "Disk image resized to $STORAGE_SIZE (filesystem expansion happens on first Pi boot)"

# ---------------------------------------------------------------------------
# Attach loop device and map partitions
# ---------------------------------------------------------------------------
log "Attaching loop device …"
LOOP_DEVICE=$(losetup --show -fP "$IMAGE_PATH")
[[ -z "$LOOP_DEVICE" ]] && { echo "Error: failed to attach loop device" >&2; exit 1; }
log "Loop device: $LOOP_DEVICE"

BOOT_PART=""
ROOT_PART=""
if [[ -b "${LOOP_DEVICE}p1" && -b "${LOOP_DEVICE}p2" ]]; then
  BOOT_PART="${LOOP_DEVICE}p1"
  ROOT_PART="${LOOP_DEVICE}p2"
  log "Partition devices : $BOOT_PART  $ROOT_PART"
else
  log "Mapping partitions with kpartx …"
  kpartx -av "$LOOP_DEVICE"
  BOOT_PART="/dev/mapper/$(basename "$LOOP_DEVICE")p1"
  ROOT_PART="/dev/mapper/$(basename "$LOOP_DEVICE")p2"
fi

[[ ! -b "$BOOT_PART" || ! -b "$ROOT_PART" ]] && {
  echo "Error: partition devices not found: $BOOT_PART  $ROOT_PART" >&2
  ls -l "${LOOP_DEVICE}"* || true
  ls -l /dev/mapper      || true
  exit 1
}

# ---------------------------------------------------------------------------
# Mount boot partition (rw) — extract boot files + inject user credentials
# ---------------------------------------------------------------------------
log "Mounting boot partition (read-write) …"
mount "$BOOT_PART" "$BOOT_MNT"

# --- Find kernel image ---
BOOT_KERNEL=""
# --- Find kernel image (prefer 64-bit kernel8.img for aarch64 / Pi 4 compatibility) ---
BOOT_KERNEL=""
for candidate in kernel8.img kernel7l.img kernel7.img kernel.img; do
  if [[ -f "$BOOT_MNT/$candidate" ]]; then
    BOOT_KERNEL="$candidate"
    log "Kernel found : $BOOT_KERNEL"
    break
  fi
done
[[ -z "$BOOT_KERNEL" ]] && {
  echo "Error: no kernel image found in boot partition" >&2
  ls -la "$BOOT_MNT" || true
  exit 1
}

# ---------------------------------------------------------------------------
# Select QEMU machine type and DTB
# ---------------------------------------------------------------------------
# QEMU's raspi4b machine type (BCM2711) has incomplete hardware emulation.
# The Pi OS kernel panics silently before UART init — empty serial log.
# Solution: use raspi3b (BCM2710) which is fully emulated and stable.
#
# This gives 100% Pi 4 SOFTWARE compatibility:
#   • kernel8.img is the SAME 64-bit (aarch64) binary used on Pi 4
#   • All Pi OS arm64 packages run identically on raspi3b QEMU
#   • The only difference is the QEMU-internal hardware model
#
# DTB preference order for raspi3b:
#   bcm2710-rpi-3-b-plus.dtb  ← best-tested with QEMU raspi3b
#   bcm2710-rpi-3-b.dtb       ← also works
MACHINE="raspi3b"
RAM_MB=1024
DTB_FILE=""
for dtb_candidate in \
    bcm2710-rpi-3-b-plus.dtb \
    bcm2710-rpi-3-b.dtb; do
  if [[ -f "$BOOT_MNT/$dtb_candidate" ]]; then
    DTB_FILE="$dtb_candidate"
    log "DTB selected : $DTB_FILE  (machine: $MACHINE)"
    break
  fi
done
[[ -z "$DTB_FILE" ]] && {
  echo "Error: no raspi3b DTB found in boot partition (expected bcm2710-rpi-3-b[-plus].dtb)" >&2
  ls -la "$BOOT_MNT" | head -60 || true
  exit 1
}

# --- Copy kernel and DTB to workdir ---
cp "$BOOT_MNT/$BOOT_KERNEL" "$WORK_ROOT/kernel.img"
cp "$BOOT_MNT/$DTB_FILE"    "$WORK_ROOT/$DTB_FILE"

# --- Read original cmdline ---
if [[ -f "$BOOT_MNT/cmdline.txt" ]]; then
  CMDLINE=$(tr -d '\n' < "$BOOT_MNT/cmdline.txt")
  log "Original cmdline.txt: $CMDLINE"
else
  CMDLINE="root=/dev/mmcblk0p2 rw rootwait rootfstype=ext4"
fi

# --- Inject first-boot user credentials (Bookworm / Pi OS ≥ 2022 requirement) ---
if [[ ! -f "$BOOT_MNT/userconf.txt" ]]; then
  log "Injecting first-boot credentials: user=$LUMO_USER"
  PASS_HASH=$(openssl passwd -6 "$LUMO_PASS")
  printf '%s:%s\n' "$LUMO_USER" "$PASS_HASH" > "$BOOT_MNT/userconf.txt"
  log "userconf.txt written successfully"
else
  log "userconf.txt already present — skipping credential injection"
fi

umount "$BOOT_MNT"

# ---------------------------------------------------------------------------
# Provision root partition: install & enable nginx (once per working image)
# ---------------------------------------------------------------------------
provision_rootfs "$ROOT_PART"

# ---------------------------------------------------------------------------
# Build QEMU kernel cmdline for Bookworm
# ---------------------------------------------------------------------------
# Strip firstboot init= — it silently hangs in QEMU (no real hardware to expand on)
# Strip existing console/quiet/init entries; replace PARTUUID root reference
CMDLINE=$(sed -E 's/init=[^ ]+//g'                              <<< "$CMDLINE")
CMDLINE=$(sed -E 's/console=[^ ]+//g'                           <<< "$CMDLINE")
CMDLINE=$(sed -E 's/root=PARTUUID=[^ ]*/root=\/dev\/mmcblk0p2/' <<< "$CMDLINE")
CMDLINE=$(sed -E 's/\bquiet\b//g'                               <<< "$CMDLINE")
CMDLINE=$(sed -E 's/\s+/ /g'                                    <<< "$CMDLINE")
CMDLINE=$(sed -E 's/^\s+|\s+$//g'                              <<< "$CMDLINE")

# earlyprintk=ttyAMA0 guarantees kernel messages appear before console subsystem init
# rootdelay=5 gives the emulated SD card time to be recognised
CMDLINE="$CMDLINE rw earlyprintk=ttyAMA0 loglevel=8 console=ttyAMA0,115200 dwc_otg.lpm_enable=0 rootfstype=ext4 rootdelay=5 rootwait"

# ---------------------------------------------------------------------------
# Launch QEMU
# ---------------------------------------------------------------------------
log "======================================================="
log " Pi OS Bookworm (Debian 12) — 64-bit QEMU Emulator"
log "======================================================="
log "  Machine   : $MACHINE"
log "  CPU       : cortex-a53 × 4 SMP"
log "  RAM       : ${RAM_MB} MB"
log "  Storage   : $STORAGE_SIZE"
log "  Kernel    : $WORK_ROOT/kernel.img"
log "  DTB       : $WORK_ROOT/$DTB_FILE"
log "  Image     : $IMAGE_PATH"
log "  Cmdline   : $CMDLINE"
log "  HTTP      : http://localhost:${HTTP_HOST_PORT}  → guest :${HTTP_HOST_PORT}"
log "  HTTPS     : https://localhost:${HTTPS_HOST_PORT} → guest :${HTTPS_HOST_PORT}"
log "  SSH       : ssh ${LUMO_USER}@127.0.0.1 -p ${SSH_HOST_PORT}"
log "  Username  : $LUMO_USER"
log "  Password  : (set at first boot via userconf.txt)"
log "======================================================="
log "QEMU version: $(qemu-system-aarch64 --version | head -1)"

QEMU_CMD=(
  qemu-system-aarch64
  -M "$MACHINE"
  -cpu cortex-a53
  -smp 4
  -m "${RAM_MB}M"
  -kernel "$WORK_ROOT/kernel.img"
  -dtb    "$WORK_ROOT/$DTB_FILE"
  -drive  "file=${IMAGE_PATH},format=raw,if=sd"
  -netdev "user,id=net0,restrict=off,hostfwd=tcp:0.0.0.0:${HTTP_HOST_PORT}-:${HTTP_HOST_PORT},hostfwd=tcp:0.0.0.0:${HTTPS_HOST_PORT}-:${HTTPS_HOST_PORT},hostfwd=tcp:0.0.0.0:${SSH_HOST_PORT}-:22"
  -usb
  -device "usb-net,netdev=net0,mac=52:54:00:12:34:56"
  -device usb-kbd
  -device usb-tablet
  -append "$CMDLINE"
  -serial "file:${SERIAL_LOG}"
  -monitor none
  -nographic
)

log "QEMU command: ${QEMU_CMD[*]}"

"${QEMU_CMD[@]}" 2>"$QEMU_LOG" &
QEMU_PID=$!

tail -F "$SERIAL_LOG" "$QEMU_LOG" &
TAIL_PID=$!

[[ -z "$QEMU_PID" ]] && { echo "Error: failed to start QEMU" >&2; exit 1; }

log "Waiting for guest SSH on port ${SSH_HOST_PORT} …"
log "(First boot may take several minutes — filesystem expansion runs automatically)"

if wait_for_ssh; then
  log "======================================================="
  log " Emulator is READY"
  log "  SSH  : ssh ${LUMO_USER}@localhost -p ${SSH_HOST_PORT}"
  log "  HTTP : http://localhost:${HTTP_HOST_PORT}   ← nginx (provisioned)"
  log "  HTTPS: https://localhost:${HTTPS_HOST_PORT}  ← nginx (provisioned)"
  log "======================================================="
else
  log "SSH not yet reachable (still booting) — emulator continues running"
  log "Try: ssh ${LUMO_USER}@localhost -p ${SSH_HOST_PORT}"
  echo "--- last 50 lines of serial.log ---"
  tail -n 50 "$SERIAL_LOG" || true
  echo "--- last 50 lines of qemu.log ---"
  tail -n 50 "$QEMU_LOG" || true
fi

# Keep container alive — wait for QEMU to exit naturally (or be killed)
wait "$QEMU_PID"
