# FS-UAE boot tests

Headless-ish (FS-UAE still opens a small window) boot tests that run real
assembled 68k code under a real Kickstart ROM in FS-UAE, checking success
via the emulated serial port. This is the only way to catch relocation,
memory-type, or stub-timing bugs that a host-side diff can't see (see
`PROJECT_PLAN.md` §8).

## Why this can't run on public CI

Kickstart ROMs are copyrighted (Commodore/Cyberlogic, distributed today by
Cloanto). They must not be committed to this repo or fetched by a public
GitHub Actions runner. These tests are **local/dev-machine only** — point
`EXECRAM_KICKSTART` at a ROM you're licensed to use. A self-hosted CI
runner with a ROM provisioned out-of-band (not in this repo) could run
these too, but public `.github/workflows/ci.yml` never will.

## Running

```sh
EXECRAM_KICKSTART=~/amiga/"Kickstart v1.3 r34.005 (1987-12)(Commodore)(A500-A1000-A2000-CDTV)[!].rom" \
  tests/uae/run_boot_test.sh
```

Requires `vasmm68k_mot` on `PATH`, FS-UAE installed at the default macOS
app path (override with `EXECRAM_FSUAE`), and `python3`.

## How it works

1. `boot/sentinel.s` — a bare-metal AmigaDOS boot block (no filesystem,
   Exec, or DOS calls) that bangs the serial hardware registers directly
   to emit `EXECRAM-BOOT-OK`, then hangs.
2. `boot/build_adf.py` — pads the assembled boot block to 1024 bytes,
   computes and patches in the Amiga boot-block checksum, and writes it
   as the first two sectors of a blank 880K ADF image.
3. `boot/pty_bridge.py` — opens a real pty and copies whatever's written
   to it into a log file. FS-UAE's `serial_port` option needs a real pty:
   a plain FIFO was tried first and silently produced zero bytes (FS-UAE
   probes modem-control ioctls that behave differently against a FIFO vs.
   a pty on macOS).
4. `run_boot_test.sh` — assembles the boot block, builds the ADF, opens
   the pty bridge, boots FS-UAE with `serial_port` pointed at it, and
   greps the resulting log for the sentinel within a 10-second timeout.

Note: `sentinel.s` paces its serial output with a fixed delay loop rather
than polling the TBE (transmit-buffer-empty) bit as the Amiga Hardware
Reference Manual describes — that bit never went high under FS-UAE's
serial emulation in testing here. A fixed delay is fine for a one-shot
sentinel with nothing else going on; a real depacker stub with actual
timing constraints would need to revisit this.

## M1 end-to-end test (`run_e2e_test.sh`)

Extends the same mechanism to boot an actual `execram`-packed program,
not just the bare sentinel:

```sh
EXECRAM_KICKSTART=~/amiga/"Kickstart v1.3 ...rom" tests/uae/run_e2e_test.sh
```

It builds `execram`, links `e2e/program.s` (a small program with both a
cross-hunk and a self-hunk relocation) into a real executable, packs it
with `execram pack` (`--backend=store`), extracts the inner
stub+header+payload container (`e2e/extract_container.py`, reading the
outer hunk's own declared length - not the AmigaDOS CLI/Workbench boot
path, which real execram output normally goes through, but a much
simpler way to exercise the packed program's *runtime stub* directly),
wraps that in a boot-block header, and boots it the same way
`run_boot_test.sh` does.

The test program only prints its sentinel correctly if a pointer that
went through both relocations ends up correct - this is a real
functional check of decompress+allocate+relocate+jump, not just "did it
not crash". It caught a real bug during development: `StubEnd` was
originally defined inside `stubs/common/runtime.i`, which is `include`d
*before* each backend's own `Depack` code - so it pointed at the start
of `Depack` instead of the true end of the assembled stub. The bare
sentinel test (which has no header/payload to locate) couldn't have
caught that; only booting an actual packed program could.

A second bug surfaced in the test's own tooling, not the pack pipeline:
an earlier version of `extract_container.py` scanned for the "ExCr"
magic bytes instead of reading the hunk's declared length, and found a
coincidental match inside the stub's own `cmp.l #MAGIC,...` instruction
- it still "passed" only because Python's slice clamping happened to
land on the file's true end anyway. Fixed to read the length field
directly, which is correct by construction rather than by coincidence.
