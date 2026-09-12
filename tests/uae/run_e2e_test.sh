#!/usr/bin/env bash
# M1 FS-UAE end-to-end test: builds execram, packs a real test program
# with it (--backend=store), and boots the packed program's inner
# stub+header+payload container directly - skipping the outer AmigaDOS
# hunk-file wrapper (see e2e/extract_container.py) - via the same
# bare-metal boot-block technique as run_boot_test.sh. The test program
# (e2e/program.s) only prints its sentinel correctly if a pointer that
# went through a real cross-hunk AND a real self-hunk relocation both
# ended up correct - this checks the packed program's runtime stub
# actually decompressed, allocated, and *relocated* things correctly,
# not just "didn't crash".
#
# Requires the same things as run_boot_test.sh, plus vlink (to link the
# test program into a real hunk executable execram can pack) - this
# script builds execram itself, so Zig and vasm/vlink are all it needs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FSUAE_BIN="${EXECRAM_FSUAE:-/Applications/FS-UAE.app/Contents/MacOS/fs-uae}"
SENTINEL="EXECRAM-PACKED-OK"
BOOT_TIMEOUT_CHECKS=24 # 24 * 0.5s = 12s
VASM="${EXECRAM_VASM:-vasmm68k_mot}"
VLINK="${EXECRAM_VLINK:-vlink}"

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
(cd "$REPO_ROOT" && zig build -Dvasm="$VASM")
EXECRAM="$REPO_ROOT/zig-out/bin/execram"

echo "== assembling and linking the test program =="
PROGRAM_OBJ="$WORK_DIR/program.o"
PROGRAM_EXE="$WORK_DIR/program.exe"
"$VASM" -Fhunk -no-opt -quiet -o "$PROGRAM_OBJ" "$SCRIPT_DIR/e2e/program.s"
"$VLINK" -bamigahunk -o "$PROGRAM_EXE" "$PROGRAM_OBJ"

echo "== packing with execram (--backend=store) =="
PACKED_EXE="$WORK_DIR/packed.exe"
"$EXECRAM" pack "$PROGRAM_EXE" "$PACKED_EXE"

echo "== extracting the inner container =="
CONTAINER_BIN="$WORK_DIR/container.bin"
python3 "$SCRIPT_DIR/e2e/extract_container.py" "$PACKED_EXE" "$CONTAINER_BIN"

echo "== building test ADF =="
BOOT_BIN="$WORK_DIR/boot.bin"
python3 - "$CONTAINER_BIN" "$BOOT_BIN" <<'PYEOF'
import sys
container = open(sys.argv[1], "rb").read()
# Same 12-byte boot-block header as boot/sentinel.s: 'DOS' id, a
# checksum placeholder build_adf.py fills in, and an unused root block
# pointer - the boot protocol calls straight into the bytes after this,
# which here is our packed container's stub code.
boot_header = b"DOS" + b"\x00" + b"\x00\x00\x00\x00" + b"\x00\x00\x00\x00"
open(sys.argv[2], "wb").write(boot_header + container)
PYEOF
ADF="$WORK_DIR/e2e.adf"
python3 "$SCRIPT_DIR/boot/build_adf.py" "$BOOT_BIN" "$ADF"

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
