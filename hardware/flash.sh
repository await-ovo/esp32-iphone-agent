#!/usr/bin/env bash
# Build and flash the board (needs arduino-cli and the esp32 core 3.3.x).
# Usage: hardware/flash.sh [port] [--debug] [--build-only]
#   --debug       log commands on UART at 115200 baud
#   --build-only  compile only (prints flash/RAM usage)
# BLE host: h2zero NimBLE-Arduino (arduino-cli lib install "NimBLE-Arduino"); its buffer sizes live in
# hid_bridge/nimble_cfg.h, force-included into every C/C++ file below.
# This N16R8 board is flashed through USB-to-UART; esptool handles the bootloader reset.
set -euo pipefail
cd "$(dirname "$0")"
FQBN="esp32:esp32:esp32s3:USBMode=default,CDCOnBoot=default,FlashSize=16M,PSRAM=opi,PartitionScheme=default_8MB"
port() { for p in /dev/cu.usbmodem* /dev/ttyACM*; do [[ -e $p ]] && { echo "$p"; return; }; done; }
PORT="" DEFS="" BUILD_ONLY=0
for a in "$@"; do
  case $a in
    --debug) DEFS+=" -DDEBUG_SERIAL=1" ;;
    --build-only) BUILD_ONLY=1 ;;
    --*) echo "unknown option: $a" >&2; exit 1 ;;
    *) PORT=$a ;;
  esac
done
[[ $PWD != *" "* ]] || { echo "the -include path below cannot contain spaces: $PWD"; exit 1; }
DEFS+=" -include $PWD/hid_bridge/nimble_cfg.h"
FLAGS=(--build-property "compiler.cpp.extra_flags=$DEFS" --build-property "compiler.c.extra_flags=$DEFS")

arduino-cli compile -b "$FQBN" "${FLAGS[@]}" --output-dir build hid_bridge
(( BUILD_ONLY )) && exit 0
PORT=${PORT:-$(port)}
arduino-cli upload -b "$FQBN" -p "$PORT" --upload-property "upload.speed=115200" --input-dir build hid_bridge
