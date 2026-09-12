#!/usr/bin/env bash
# Larger-scale FS-UAE end-to-end test, extending run_e2e_test.sh's
# approach to a genuinely larger program: several KB of real prose (a
# fairer compression-ratio test than tiny/synthetic data) and 22
# relocations (20 self-hunk, 2 cross-hunk) instead of two or three -
# see e2e_large/gen_large_program.py for the full rationale.
#
# Unlike run_e2e_test.sh, this diffs the *entire* serial transcript
# against a known-exact expected output (not just grepping for one
# sentinel line) - if decompression or relocation gets even one byte
# wrong anywhere in several KB of output, this catches exactly where.
#
# Also prints real compression ratios for every backend while it's at
# it, since building a large-enough test program was the prerequisite
# for having any (see PROJECT_PLAN.md M1-M3's repeatedly-deferred
# benchmark item).
#
# Requires the same things as run_e2e_test.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FSUAE_BIN="${EXECRAM_FSUAE:-/Applications/FS-UAE.app/Contents/MacOS/fs-uae}"
BOOT_TIMEOUT_CHECKS=200 # 200 * 0.5s = 100s - several KB at a paced bit-banged baud rate takes a while
VASM="${EXECRAM_VASM:-vasmm68k_mot}"
VASM_STD="${EXECRAM_VASM_STD:-vasmm68k_std}"
VLINK="${EXECRAM_VLINK:-vlink}"
BACKEND="${EXECRAM_TEST_BACKEND:-auto}"

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

echo "== generating the large test program =="
PROGRAM_S="$WORK_DIR/large_program.s"
EXPECTED_TXT="$WORK_DIR/expected.txt"
python3 "$SCRIPT_DIR/e2e_large/gen_large_program.py" "$PROGRAM_S" "$EXPECTED_TXT"

echo "== assembling and linking the test program =="
PROGRAM_OBJ="$WORK_DIR/program.o"
PROGRAM_EXE="$WORK_DIR/program.exe"
"$VASM" -Fhunk -no-opt -quiet -o "$PROGRAM_OBJ" "$PROGRAM_S"
"$VLINK" -bamigahunk -o "$PROGRAM_EXE" "$PROGRAM_OBJ"
ORIGINAL_LEN="$(wc -c <"$PROGRAM_EXE" | tr -d ' ')"

echo "== packing with every backend (ratio comparison) =="
for b in store inflate zx0; do
  packed="$WORK_DIR/packed_$b.exe"
  "$EXECRAM" pack "--backend=$b" "$PROGRAM_EXE" "$packed" 2>&1 | sed "s/^/  /"
done

echo "== packing with execram (--backend=$BACKEND, the one actually booted below) =="
PACKED_EXE="$WORK_DIR/packed.exe"
"$EXECRAM" pack "--backend=$BACKEND" "$PROGRAM_EXE" "$PACKED_EXE"

echo "== extracting the inner container =="
CONTAINER_BIN="$WORK_DIR/container.bin"
python3 "$SCRIPT_DIR/e2e/extract_container.py" "$PACKED_EXE" "$CONTAINER_BIN"
CONTAINER_LEN="$(wc -c <"$CONTAINER_BIN" | tr -d ' ')"

echo "== assembling the disk loader (container is $CONTAINER_LEN bytes) =="
LOADER_BIN="$WORK_DIR/loader.bin"
"$VASM" -Fbin -no-opt -quiet "-DPAYLOAD_LEN=$CONTAINER_LEN" -o "$LOADER_BIN" "$SCRIPT_DIR/e2e/loader.s"

echo "== building test ADF =="
BOOT_BIN="$WORK_DIR/boot.bin"
python3 - "$CONTAINER_BIN" "$BOOT_BIN" <<'PYEOF'
import sys
container = open(sys.argv[1], "rb").read()
boot_header = b"DOS" + b"\x00" + b"\x00\x00\x00\x00" + b"\x00\x00\x00\x00"
open(sys.argv[2], "wb").write(boot_header + container)
PYEOF
ADF="$WORK_DIR/large.adf"
python3 "$SCRIPT_DIR/e2e/build_disk.py" "$LOADER_BIN" "$CONTAINER_BIN" "$ADF"

echo "== opening a pty bridge for the emulated serial port =="
SERIAL_LOG="$WORK_DIR/serial.log"
SLAVE_PATH_FILE="$WORK_DIR/slave.txt"
touch "$SERIAL_LOG"
python3 "$SCRIPT_DIR/boot/pty_bridge.py" "$SERIAL_LOG" $((BOOT_TIMEOUT_CHECKS / 2 + 10)) >"$SLAVE_PATH_FILE" &
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

EXPECTED_LEN="$(wc -c <"$EXPECTED_TXT" | tr -d ' ')"
found=0
for _ in $(seq 1 "$BOOT_TIMEOUT_CHECKS"); do
  got="$(wc -c <"$SERIAL_LOG" 2>/dev/null | tr -d ' ')"
  if [ "${got:-0}" -ge "$EXPECTED_LEN" ]; then
    found=1
    break
  fi
  sleep 0.5
done
# Give the last few bytes (and the emulator) a moment to settle either way.
sleep 1

if [ "$found" -eq 1 ] && cmp -s "$SERIAL_LOG" "$EXPECTED_TXT"; then
  echo "PASS: all $EXPECTED_LEN bytes of the transcript matched exactly (--backend=$BACKEND)"
  echo ""
  echo "Compression ratios ($ORIGINAL_LEN byte original):"
  for b in store inflate zx0; do
    packed="$WORK_DIR/packed_$b.exe"
    len="$(wc -c <"$packed" | tr -d ' ')"
    pct=$(awk "BEGIN { printf \"%.1f\", 100 * $len / $ORIGINAL_LEN }")
    echo "  $b: $len bytes ($pct%)"
  done
  exit 0
else
  echo "FAIL: transcript did not match expected output exactly (--backend=$BACKEND)" >&2
  echo "--- first difference (expected vs actual) ---" >&2
  cmp "$EXPECTED_TXT" "$SERIAL_LOG" >&2 2>&1 || true
  echo "--- serial log (${got:-0} of $EXPECTED_LEN expected bytes) ---" >&2
  cat "$SERIAL_LOG" >&2
  echo "--- fs-uae log ---" >&2
  cat "$FSUAE_LOG" >&2
  exit 1
fi
