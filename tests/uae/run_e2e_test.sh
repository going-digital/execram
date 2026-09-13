#!/usr/bin/env bash
# M1/M2 FS-UAE end-to-end test: builds execram, packs a real test
# program with it, and boots the packed program via a disk-reading boot
# loader (e2e/loader.s) that parses the real two-hunk AmigaDOS load file
# execram produces (docs/format-spec.md §2, docs/memory-lifecycle.md)
# and rebuilds the same in-memory layout a genuine LoadSeg would -
# run_boot_test.sh's simpler bare-metal sentinel embeds everything
# directly in the 1024-byte boot block instead, which no longer fits
# once a real depacker stub is involved.
# The test program (e2e/program.s) only prints its sentinel correctly if
# a pointer that went through a real cross-hunk AND a real self-hunk
# relocation both ended up correct - this checks the packed program's
# runtime stub actually decompressed, allocated, and *relocated* things
# correctly, not just "didn't crash".
#
# Requires the same things as run_boot_test.sh, plus vlink (to link the
# test program into a real hunk executable execram can pack) - this
# script builds execram itself, so Zig and vasm/vlink are all it needs.
#
# EXECRAM_TEST_BACKEND selects which backend to pack with (default
# store); the inflate backend also needs EXECRAM_VASM_STD (a
# vasmm68k_std build - see stubs/inflate/README.md) if it isn't on PATH
# under that name already.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FSUAE_BIN="${EXECRAM_FSUAE:-/Applications/FS-UAE.app/Contents/MacOS/fs-uae}"
SENTINEL="EXECRAM-PACKED-OK"
BOOT_TIMEOUT_CHECKS=24 # 24 * 0.5s = 12s
VASM="${EXECRAM_VASM:-vasmm68k_mot}"
VASM_STD="${EXECRAM_VASM_STD:-vasmm68k_std}"
VLINK="${EXECRAM_VLINK:-vlink}"
BACKEND="${EXECRAM_TEST_BACKEND:-store}"

if [ -z "${EXECRAM_KICKSTART:-}" ]; then
  echo "error: set EXECRAM_KICKSTART to a Kickstart ROM path (see run_boot_test.sh's header)" >&2
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

echo "== building execram =="
(cd "$REPO_ROOT" && zig build -Dvasm="$VASM" -Dvasm-std="$VASM_STD")
EXECRAM="$REPO_ROOT/zig-out/bin/execram"

echo "== assembling and linking the test program =="
PROGRAM_OBJ="$WORK_DIR/program.o"
PROGRAM_EXE="$WORK_DIR/program.exe"
"$VASM" -Fhunk -no-opt -quiet -o "$PROGRAM_OBJ" "$SCRIPT_DIR/e2e/program.s"
"$VLINK" -bamigahunk -o "$PROGRAM_EXE" "$PROGRAM_OBJ"

echo "== packing with execram (--backend=$BACKEND) =="
PACKED_EXE="$WORK_DIR/packed.exe"
"$EXECRAM" pack "--backend=$BACKEND" "$PROGRAM_EXE" "$PACKED_EXE"

echo "== validating the packed file's shape =="
CONTAINER_BIN="$WORK_DIR/container.bin"
python3 "$SCRIPT_DIR/e2e/extract_container.py" "$PACKED_EXE" "$CONTAINER_BIN"
CONTAINER_LEN="$(wc -c <"$CONTAINER_BIN" | tr -d ' ')"

echo "== assembling the disk loader (container is $CONTAINER_LEN bytes) =="
# Depacker stubs don't fit in a 1024-byte boot block (the inflate one
# alone is already over 1KB), unlike run_boot_test.sh's bare sentinel -
# so this loads the container from disk instead of embedding it in the
# boot block directly. See e2e/loader.s.
LOADER_BIN="$WORK_DIR/loader.bin"
"$VASM" -Fbin -no-opt -quiet "-DPAYLOAD_LEN=$CONTAINER_LEN" -o "$LOADER_BIN" "$SCRIPT_DIR/e2e/loader.s"

echo "== building test ADF =="
ADF="$WORK_DIR/e2e.adf"
python3 "$SCRIPT_DIR/e2e/build_disk.py" "$LOADER_BIN" "$CONTAINER_BIN" "$ADF"

echo "== opening a pty bridge for the emulated serial port =="
SERIAL_LOG="$WORK_DIR/serial.log"
SLAVE_PATH_FILE="$WORK_DIR/slave.txt"
touch "$SERIAL_LOG"
python3 "$SCRIPT_DIR/boot/pty_bridge.py" "$SERIAL_LOG" 20 >"$SLAVE_PATH_FILE" &
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
FSUAE_LOG="$WORK_DIR/fs-uae.log"
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
  echo "PASS: found '$SENTINEL' - the packed program's stub decompressed, allocated, relocated, and jumped into the real program correctly"
  exit 0
else
  echo "FAIL: '$SENTINEL' not seen within $((BOOT_TIMEOUT_CHECKS / 2))s" >&2
  echo "--- serial log ---" >&2
  xxd "$SERIAL_LOG" >&2 2>/dev/null || cat "$SERIAL_LOG" >&2
  echo "--- fs-uae log ---" >&2
  cat "$FSUAE_LOG" >&2
  exit 1
fi
