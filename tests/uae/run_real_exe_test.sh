#!/usr/bin/env bash
# Boots real (not gen_corpus.py-synthetic) executables under every
# backend, via a genuine AmigaDOS launch - unlike every other script in
# this directory, which boots a bare-metal boot block
# (tests/uae/e2e/loader.s) that jumps straight into a packed program's
# stub with no AmigaDOS environment at all (no Process, no LoadSeg, no
# libraries opened). That's fine for the synthetic corpus (deliberately
# written to bang hardware registers directly, no OpenLibrary calls
# anywhere), but a real program - one that calls OpenLibrary(),
# expects to run as a proper Process, etc. - needs the real thing.
#
# The mechanism is dramatically simpler than loader.s's own disk-image-
# building pipeline: FS-UAE (like WinUAE) auto-wraps a single AmigaDOS
# executable file pointed at as a floppy drive into a minimal bootable
# disk with a real startup-sequence, so AmigaDOS itself LoadSeg's and
# runs it exactly as it would from a real floppy or hard drive. Just
# point --floppy_drive_0 straight at execram's own packed output file -
# no loader.s, no build_disk.py, no manual disk-image assembly at all.
# Confirmed directly (not assumed): a real test-corpus program
# (tests/corpus/hexagon.exe) that failed every way under loader.s
# booted and ran correctly the very first time under this mechanism,
# once instrumented (tests/corpus/exram_serial.h) to prove it - the
# earlier failures turned out to be underneath OUR OWN test harness's
# lack of a real AmigaDOS environment, not execram's packing/relocation
# (independently verified correct via a from-scratch Python
# reimplementation of flatten.zig's own algorithm before this script
# existed - see the commit history if the details matter to you).
#
# Each real executable needs a paired <name>.meta file (shell-sourced)
# next to it in tests/corpus/, defining:
#   SENTINEL="..."       a substring that must appear over the emulated
#                         serial port once the program has started up
#                         successfully (see tests/corpus/exram_serial.h
#                         for a portable way to add this to a real
#                         program with minimal invasiveness).
#   HEARTBEAT_CHECK=1     optional (default 0). If set, passing also
#                         requires MORE serial output to arrive after
#                         the sentinel is seen - distinguishing "booted
#                         and is still running" (a demo with an
#                         infinite main loop, expected to never
#                         terminate on its own) from "booted, then hung
#                         or crashed right after the sentinel line".
#
# Requires the same things as run_e2e_test.sh.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CORPUS_DIR="$REPO_ROOT/tests/corpus"
FSUAE_BIN="${EXECRAM_FSUAE:-/Applications/FS-UAE.app/Contents/MacOS/fs-uae}"
BOOT_TIMEOUT_CHECKS=180 # 180 * 0.5s = 90s to see the sentinel - shrinkler's
# adaptive range decoder is meaningfully slower per byte on real 68000
# timing than the other backends' simpler decode loops (confirmed
# directly: hexagon.exe's real depack-to-sentinel time under shrinkler
# needed tens of seconds even on an otherwise-idle host, comfortably
# exceeding a tighter timeout that was fine for every other backend on
# the same file), and this project's largest real decompression yet
# (~221KB) makes that gap large enough to matter for a program this
# size specifically.
HEARTBEAT_WAIT_SECONDS=10 # extra time to confirm continued output afterward
VASM="${EXECRAM_VASM:-vasmm68k_mot}"

BACKENDS=(store inflate zultra zx0 salvador shrinkler)

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

shopt -s nullglob
META_FILES=("$CORPUS_DIR"/*.meta)
shopt -u nullglob
if [ ${#META_FILES[@]} -eq 0 ]; then
  echo "No *.meta files found in $CORPUS_DIR - nothing to test. See this script's own header." >&2
  exit 0
fi

WORK_DIR="$(mktemp -d)"
CUR_FSUAE_PID=""
CUR_BRIDGE_PID=""
cleanup() {
  [ -n "$CUR_FSUAE_PID" ] && kill "$CUR_FSUAE_PID" 2>/dev/null
  [ -n "$CUR_BRIDGE_PID" ] && kill "$CUR_BRIDGE_PID" 2>/dev/null
  [ -n "$CUR_FSUAE_PID" ] && wait "$CUR_FSUAE_PID" 2>/dev/null
  [ -n "$CUR_BRIDGE_PID" ] && wait "$CUR_BRIDGE_PID" 2>/dev/null
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

echo "== building execram =="
(cd "$REPO_ROOT" && zig build -Dvasm="$VASM") || exit 1
EXECRAM="$REPO_ROOT/zig-out/bin/execram"

declare -A RESULTS
ITEMS=()

for meta_path in "${META_FILES[@]}"; do
  name="$(basename "$meta_path" .meta)"
  exe_path="$CORPUS_DIR/$name.exe"
  if [ ! -f "$exe_path" ]; then
    echo "error: $meta_path has no matching $exe_path - skipping" >&2
    continue
  fi
  ITEMS+=("$name")

  # Reset per-item: SENTINEL/HEARTBEAT_CHECK from a previous .meta must
  # not leak into this one if this one doesn't set them.
  SENTINEL=""
  HEARTBEAT_CHECK=0
  # shellcheck disable=SC1090
  source "$meta_path"
  if [ -z "$SENTINEL" ]; then
    echo "error: $meta_path did not set SENTINEL - skipping" >&2
    continue
  fi

  for backend in "${BACKENDS[@]}"; do
    echo "-- $name / $backend --"
    PACKED="$WORK_DIR/${name}_${backend}.exe"
    if ! "$EXECRAM" pack "--backend=$backend" "$exe_path" "$PACKED" 2>&1 | sed 's/^/   /'; then
      echo "   FAIL(pack)"
      RESULTS["$name:$backend"]="FAIL(pack)"
      continue
    fi

    SERIAL_LOG="$WORK_DIR/${name}_${backend}_serial.log"
    SLAVE_PATH_FILE="$WORK_DIR/${name}_${backend}_slave.txt"
    touch "$SERIAL_LOG"
    python3 "$SCRIPT_DIR/boot/pty_bridge.py" "$SERIAL_LOG" $((BOOT_TIMEOUT_CHECKS / 2 + HEARTBEAT_WAIT_SECONDS + 10)) >"$SLAVE_PATH_FILE" &
    CUR_BRIDGE_PID=$!
    for _ in $(seq 1 20); do
      [ -s "$SLAVE_PATH_FILE" ] && break
      sleep 0.1
    done
    SLAVE_PATH="$(cat "$SLAVE_PATH_FILE" 2>/dev/null || true)"
    if [ -z "$SLAVE_PATH" ]; then
      echo "   FAIL(bridge)"
      RESULTS["$name:$backend"]="FAIL(bridge)"
      kill "$CUR_BRIDGE_PID" 2>/dev/null
      wait "$CUR_BRIDGE_PID" 2>/dev/null
      CUR_BRIDGE_PID=""
      continue
    fi

    FSUAE_LOG="$WORK_DIR/${name}_${backend}_fsuae.log"
    # Straight at the packed executable file - no disk image built by
    # us at all. See this script's own header for why this works.
    "$FSUAE_BIN" \
      --kickstart_file="$EXECRAM_KICKSTART" \
      --floppy_drive_0="$PACKED" \
      --floppy_drive_count=1 \
      --serial_port="$SLAVE_PATH" \
      --fullscreen=0 \
      --amiga_model=A500 \
      --window_width=200 --window_height=100 \
      >"$FSUAE_LOG" 2>&1 &
    CUR_FSUAE_PID=$!

    found=0
    for _ in $(seq 1 "$BOOT_TIMEOUT_CHECKS"); do
      if grep -qF "$SENTINEL" "$SERIAL_LOG" 2>/dev/null; then
        found=1
        break
      fi
      sleep 0.5
    done

    if [ "$found" -ne 1 ]; then
      echo "   FAIL(no-sentinel)"
      RESULTS["$name:$backend"]="FAIL(no-sentinel)"
    elif [ "$HEARTBEAT_CHECK" = "1" ]; then
      n1="$(wc -c <"$SERIAL_LOG" | tr -d ' ')"
      sleep "$HEARTBEAT_WAIT_SECONDS"
      n2="$(wc -c <"$SERIAL_LOG" | tr -d ' ')"
      if [ "${n2:-0}" -gt "${n1:-0}" ]; then
        echo "   PASS (sentinel + still running: $n1 -> $n2 bytes)"
        RESULTS["$name:$backend"]="PASS"
      else
        echo "   FAIL(no-heartbeat) (stuck at $n1 bytes for ${HEARTBEAT_WAIT_SECONDS}s after sentinel)"
        RESULTS["$name:$backend"]="FAIL(no-heartbeat)"
      fi
    else
      echo "   PASS (sentinel seen)"
      RESULTS["$name:$backend"]="PASS"
    fi

    kill "$CUR_FSUAE_PID" 2>/dev/null
    kill "$CUR_BRIDGE_PID" 2>/dev/null
    wait "$CUR_FSUAE_PID" 2>/dev/null
    wait "$CUR_BRIDGE_PID" 2>/dev/null
    CUR_FSUAE_PID=""
    CUR_BRIDGE_PID=""

    if [ "${RESULTS["$name:$backend"]}" != "PASS" ]; then
      echo "   --- serial log so far ---"
      cat "$SERIAL_LOG" | sed 's/^/   /'
      echo "   --- fs-uae log tail ---"
      tail -10 "$FSUAE_LOG" | sed 's/^/   /'
    fi
  done
done

echo ""
echo "=== Real-executable test matrix ==="

overall_pass=1
for name in "${ITEMS[@]}"; do
  for b in "${BACKENDS[@]}"; do
    [ "${RESULTS["$name:$b"]:-?}" = "PASS" ] || overall_pass=0
  done
done

{
  header="item"
  for b in "${BACKENDS[@]}"; do header+=$'\t'"$b"; done
  echo "$header"
  for name in "${ITEMS[@]}"; do
    row="$name"
    for b in "${BACKENDS[@]}"; do
      row+=$'\t'"${RESULTS["$name:$b"]:-?}"
    done
    echo "$row"
  done
} | column -t -s $'\t'

echo ""
if [ "$overall_pass" -eq 1 ]; then
  echo "PASS: every real executable passed under every backend"
  exit 0
else
  echo "FAIL: at least one (executable, backend) combination failed - see above" >&2
  exit 1
fi
