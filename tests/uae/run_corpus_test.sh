#!/usr/bin/env bash
# M6 test matrix (PROJECT_PLAN.md): boots every backend against every
# corpus item (tests/corpus/gen_corpus.py) under FS-UAE, and reports a
# pass/fail matrix. Generalizes run_e2e_test.sh/run_large_e2e_test.sh's
# single-program-single-backend mechanism to N programs x M backends,
# each combination getting the same byte-exact transcript check the
# large e2e test introduced.
#
# Requires the same things as run_e2e_test.sh/run_large_e2e_test.sh.
# Slower than either: this boots (number of corpus items) x (number of
# backends) times.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FSUAE_BIN="${EXECRAM_FSUAE:-/Applications/FS-UAE.app/Contents/MacOS/fs-uae}"
BOOT_TIMEOUT_CHECKS=60 # 60 * 0.5s = 30s - every corpus item's transcript is short
VASM="${EXECRAM_VASM:-vasmm68k_mot}"
VASM_STD="${EXECRAM_VASM_STD:-vasmm68k_std}"
VLINK="${EXECRAM_VLINK:-vlink}"

BACKENDS=(store inflate zultra zx0 salvador shrinkler)
ITEMS=(no_relocs chip_mem bss_heavy incompressible)

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
(cd "$REPO_ROOT" && zig build -Dvasm="$VASM" -Dvasm-std="$VASM_STD") || exit 1
EXECRAM="$REPO_ROOT/zig-out/bin/execram"

echo "== generating the corpus =="
CORPUS_DIR="$WORK_DIR/corpus"
python3 "$SCRIPT_DIR/../corpus/gen_corpus.py" "$CORPUS_DIR" || exit 1

declare -A RESULTS

for item in "${ITEMS[@]}"; do
  echo "== assembling and linking corpus item: $item =="
  ITEM_OBJ="$WORK_DIR/$item.o"
  ITEM_EXE="$WORK_DIR/$item.exe"
  if ! "$VASM" -Fhunk -no-opt -quiet -o "$ITEM_OBJ" "$CORPUS_DIR/$item.s"; then
    for b in "${BACKENDS[@]}"; do RESULTS["$item:$b"]="FAIL(asm)"; done
    continue
  fi
  if ! "$VLINK" -bamigahunk -o "$ITEM_EXE" "$ITEM_OBJ"; then
    for b in "${BACKENDS[@]}"; do RESULTS["$item:$b"]="FAIL(link)"; done
    continue
  fi
  EXPECTED_FILE="$CORPUS_DIR/$item.expected"
  EXPECTED_LEN="$(wc -c <"$EXPECTED_FILE" | tr -d ' ')"

  for backend in "${BACKENDS[@]}"; do
    echo "-- $item / $backend --"
    PACKED="$WORK_DIR/${item}_${backend}.exe"
    if ! "$EXECRAM" pack "--backend=$backend" "$ITEM_EXE" "$PACKED" 2>&1 | sed 's/^/   /'; then
      echo "   FAIL(pack)"
      RESULTS["$item:$backend"]="FAIL(pack)"
      continue
    fi

    CONTAINER_BIN="$WORK_DIR/${item}_${backend}_container.bin"
    if ! python3 "$SCRIPT_DIR/e2e/extract_container.py" "$PACKED" "$CONTAINER_BIN" >/dev/null; then
      echo "   FAIL(extract)"
      RESULTS["$item:$backend"]="FAIL(extract)"
      continue
    fi
    CONTAINER_LEN="$(wc -c <"$CONTAINER_BIN" | tr -d ' ')"

    LOADER_BIN="$WORK_DIR/${item}_${backend}_loader.bin"
    if ! "$VASM" -Fbin -no-opt -quiet "-DPAYLOAD_LEN=$CONTAINER_LEN" -o "$LOADER_BIN" "$SCRIPT_DIR/e2e/loader.s"; then
      echo "   FAIL(loader)"
      RESULTS["$item:$backend"]="FAIL(loader)"
      continue
    fi

    ADF="$WORK_DIR/${item}_${backend}.adf"
    if ! python3 "$SCRIPT_DIR/e2e/build_disk.py" "$LOADER_BIN" "$CONTAINER_BIN" "$ADF" >/dev/null; then
      echo "   FAIL(disk)"
      RESULTS["$item:$backend"]="FAIL(disk)"
      continue
    fi

    SERIAL_LOG="$WORK_DIR/${item}_${backend}_serial.log"
    SLAVE_PATH_FILE="$WORK_DIR/${item}_${backend}_slave.txt"
    touch "$SERIAL_LOG"
    python3 "$SCRIPT_DIR/boot/pty_bridge.py" "$SERIAL_LOG" $((BOOT_TIMEOUT_CHECKS / 2 + 10)) >"$SLAVE_PATH_FILE" &
    CUR_BRIDGE_PID=$!
    for _ in $(seq 1 20); do
      [ -s "$SLAVE_PATH_FILE" ] && break
      sleep 0.1
    done
    SLAVE_PATH="$(cat "$SLAVE_PATH_FILE" 2>/dev/null || true)"
    if [ -z "$SLAVE_PATH" ]; then
      echo "   FAIL(bridge)"
      RESULTS["$item:$backend"]="FAIL(bridge)"
      kill "$CUR_BRIDGE_PID" 2>/dev/null
      wait "$CUR_BRIDGE_PID" 2>/dev/null
      CUR_BRIDGE_PID=""
      continue
    fi

    FSUAE_LOG="$WORK_DIR/${item}_${backend}_fsuae.log"
    "$FSUAE_BIN" \
      --kickstart_file="$EXECRAM_KICKSTART" \
      --floppy_drive_0="$ADF" \
      --floppy_drive_count=1 \
      --serial_port="$SLAVE_PATH" \
      --fullscreen=0 \
      --amiga_model=A500 \
      --window_width=200 --window_height=100 \
      >"$FSUAE_LOG" 2>&1 &
    CUR_FSUAE_PID=$!

    found=0
    for _ in $(seq 1 "$BOOT_TIMEOUT_CHECKS"); do
      got="$(wc -c <"$SERIAL_LOG" 2>/dev/null | tr -d ' ')"
      if [ "${got:-0}" -ge "$EXPECTED_LEN" ]; then
        found=1
        break
      fi
      sleep 0.5
    done
    sleep 0.5

    kill "$CUR_FSUAE_PID" 2>/dev/null
    kill "$CUR_BRIDGE_PID" 2>/dev/null
    wait "$CUR_FSUAE_PID" 2>/dev/null
    wait "$CUR_BRIDGE_PID" 2>/dev/null
    CUR_FSUAE_PID=""
    CUR_BRIDGE_PID=""

    if [ "$found" -eq 1 ] && cmp -s "$SERIAL_LOG" "$EXPECTED_FILE"; then
      echo "   PASS"
      RESULTS["$item:$backend"]="PASS"
    else
      echo "   FAIL(transcript)"
      RESULTS["$item:$backend"]="FAIL(transcript)"
      echo "   --- first difference (expected vs actual) ---"
      cmp "$EXPECTED_FILE" "$SERIAL_LOG" 2>&1 | sed 's/^/   /'
    fi
  done
done

echo ""
echo "=== Corpus test matrix ==="

# Computed in a plain loop, not inside the `column` pipeline below: a
# `for`/`done | column` pipeline runs the loop in a subshell, so a
# variable set inside it (overall_pass) would never be visible out here.
overall_pass=1
for item in "${ITEMS[@]}"; do
  for b in "${BACKENDS[@]}"; do
    [ "${RESULTS["$item:$b"]:-?}" = "PASS" ] || overall_pass=0
  done
done

{
  header="item"
  for b in "${BACKENDS[@]}"; do header+=$'\t'"$b"; done
  echo "$header"
  for item in "${ITEMS[@]}"; do
    row="$item"
    for b in "${BACKENDS[@]}"; do
      row+=$'\t'"${RESULTS["$item:$b"]:-?}"
    done
    echo "$row"
  done
} | column -t -s $'\t'

echo ""
if [ "$overall_pass" -eq 1 ]; then
  echo "PASS: every corpus item passed under every backend"
  exit 0
else
  echo "FAIL: at least one (corpus item, backend) combination failed - see the matrix and per-combination output above" >&2
  exit 1
fi
