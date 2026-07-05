#!/usr/bin/env bash
set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

# ==========================================
# [AI CONTEXT]
# This script acts as the entry point for testing the Lumo Controller system locally.
# DEPENDENCIES: It expects `raspberry_builder` to have successfully executed its pipeline 
# and generated a `.img.gz` artifact in its `output_image` directory.
# DATA FLOW:
# 1. Finds the `lumo-controller-final.img.gz` built by the sibling repository.
# 2. Decompresses it and forcefully overrides the local emulator cache.
# 3. Spins up the `docker-compose` stack in the foreground to boot QEMU.
# ==========================================

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
BUILDER_DIR="$DIR/../raspberry_builder"
FINAL_IMAGE="$BUILDER_DIR/output_image/lumo-controller-final.img.gz"

echo -e "${BLUE}🚀 Starting Lumo Emulator Pipeline...${NC}"

if [ ! -f "$FINAL_IMAGE" ]; then
    echo -e "${RED}⚠️  Warning: Cannot find a built image from raspberry_builder!${NC}"
    echo "Expected path: $FINAL_IMAGE"
    echo -e "${GREEN}The emulator will automatically download and boot a fresh, Vanilla Raspberry Pi OS from the internet instead.${NC}"
else
    echo -e "\n${BLUE}🚚 [Step 1] Loading image from Builder...${NC}"
    mkdir -p "$DIR/work/cache/"

    # Replace the emulator's raw image with our newly built image
    echo "Decompressing $FINAL_IMAGE to emulator cache..."
    gzip -dc "$FINAL_IMAGE" > "$DIR/work/cache/raspios-bookworm-arm64-lite.img"
fi

echo -e "\n${BLUE}🖥️  [Step 2] Booting the image in QEMU emulator...${NC}"

# Clean any previous emulator state
docker compose down -v
docker compose build --no-cache

# Start the emulator in the foreground so the user sees the output
echo -e "${GREEN}✅ Emulator is starting! You should see the QEMU boot sequence shortly.${NC}"
echo -e "${BLUE}💡 Press Ctrl+C at any time to shut down the virtual machine.${NC}\n"

docker compose up
