#!/usr/bin/env bash
# M0 FS-UAE smoke test: assembles tests/uae/boot/sentinel.s, packs it into a
# bootable ADF, boots it under FS-UAE with a real Kickstart ROM, and checks
# that the sentinel line appears on the emulated serial port.
#
# This proves the toolchain (vasm) + emulator (FS-UAE) + a real Kickstart
# ROM round-trip correctly, with no OS/DOS dependency to complicate what's
# being tested. Later milestones extend this same mechanism to boot actual
# execram-packed executables instead of the bare sentinel.
#
# Requires: vasmm68k_mot on PATH, FS-UAE installed, python3, and a
# Kickstart ROM you are licensed to use (see docs/LICENSES.md - Kickstart
# ROMs are copyrighted and must NOT be committed to this repo or fetched
# in CI). Point EXECRAM_KICKSTART at your ROM file, e.g.:
#
#   EXECRAM_KICKSTART=~/amiga/"Kickstart v1.3 r34.005 (1987-12)(Commodore)(A500-A1000-A2000-CDTV)[!].rom" \
#     tests/uae/run_boot_test.sh
#
# This test is local/dev-only - it cannot run on public GitHub Actions CI
# because that would require distributing a Kickstart ROM.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FSUAE_BIN="${EXECRAM_FSUAE:-/Applications/FS-UAE.app/Contents/MacOS/fs-uae}"
SENTINEL="EXECRAM-BOOT-OK"
BOOT_TIMEOUT_CHECKS=20   # 20 * 0.5s = 10s
VASM="${EXECRAM_VASM:-vasmm68k_mot}"

if [ -z "${EXECRAM_KICKSTART:-}" ]; then
  echo "error: set EXECRAM_KICKSTART to a Kickstart ROM path (see script header)" >&2
  exit 2
fi
if [ ! -f "$EXECRAM_KICKSTART" ]; then
  echo "error: EXECRAM_KICKSTART does not exist: $EXECRAM_KICKSTART" >&2
  exit 2
fi
if [ ! -x "$FSUAE_BIN" ]; then
  echo "error: fs-uae binary not found at $FSUAE_BIN (set EXECRAM_FSUAE)" >&2
  exit 2
fi

WORK_DIR="$(mktemp -d)"
FSUAE_PID=""
BRIDGE_PID=""
cleanup() {
  [ -n "$FSUAE_PID" ] && kill "$FSUAE_PID" 2>/dev/null || true
  [ -n "$BRIDGE_PID" ] && kill "$BRIDGE_PID" 2>/dev/null || true
  wait "$FSUAE_PID" 2>/dev/null || true
  wait "$BRIDGE_PID" 2>/dev/null || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

BOOT_BIN="$WORK_DIR/sentinel.bin"
ADF="$WORK_DIR/sentinel.adf"
SERIAL_LOG="$WORK_DIR/serial.log"
SLAVE_PATH_FILE="$WORK_DIR/slave.txt"
FSUAE_LOG="$WORK_DIR/fs-uae.log"
touch "$SERIAL_LOG"

echo "== assembling sentinel boot block =="
"$VASM" -Fbin -no-opt -quiet -o "$BOOT_BIN" "$SCRIPT_DIR/boot/sentinel.s"

echo "== building test ADF =="
python3 "$SCRIPT_DIR/boot/build_adf.py" "$BOOT_BIN" "$ADF"

echo "== opening a pty bridge for the emulated serial port =="
python3 "$SCRIPT_DIR/boot/pty_bridge.py" "$SERIAL_LOG" 20 > "$SLAVE_PATH_FILE" &
BRIDGE_PID=$!
for _ in $(seq 1 20); do
  [ -s "$SLAVE_PATH_FILE" ] && break
  sleep 0.1
done
SLAVE_PATH="$(cat "$SLAVE_PATH_FILE" 2>/dev/null || true)"
if [ -z "$SLAVE_PATH" ]; then
  echo "error: pty_bridge.py did not report a slave device path" >&2
  exit 1
fi

echo "== booting under FS-UAE (Kickstart: $EXECRAM_KICKSTART) =="
"$FSUAE_BIN" \
  --kickstart_file="$EXECRAM_KICKSTART" \
  --floppy_drive_0="$ADF" \
  --floppy_drive_count=1 \
  --serial_port="$SLAVE_PATH" \
  --fullscreen=0 \
  --amiga_model=A500 \
  --window_width=200 --window_height=100 \
  >"$FSUAE_LOG" 2>&1 &
FSUAE_PID=$!

found=0
for _ in $(seq 1 "$BOOT_TIMEOUT_CHECKS"); do
  if grep -q "$SENTINEL" "$SERIAL_LOG" 2>/dev/null; then
    found=1
    break
  fi
  sleep 0.5
done

if [ "$found" -eq 1 ]; then
  echo "PASS: found '$SENTINEL' on the emulated serial port"
  exit 0
else
  echo "FAIL: '$SENTINEL' not seen within $((BOOT_TIMEOUT_CHECKS / 2))s" >&2
  echo "--- serial log ---" >&2
  xxd "$SERIAL_LOG" >&2 2>/dev/null || cat "$SERIAL_LOG" >&2
  echo "--- fs-uae log ---" >&2
  cat "$FSUAE_LOG" >&2
  exit 1
fi
