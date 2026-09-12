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

## M1/M2 end-to-end test (`run_e2e_test.sh`)

Extends the same mechanism to boot an actual `execram`-packed program,
not just the bare sentinel:

```sh
EXECRAM_KICKSTART=~/amiga/"Kickstart v1.3 ...rom" \
  EXECRAM_TEST_BACKEND=inflate \
  tests/uae/run_e2e_test.sh   # or store/zx0 (script default: store)
```

The inflate backend also needs `EXECRAM_VASM_STD` (a `vasmm68k_std`
build - see `stubs/inflate/README.md`) if it isn't on `PATH` under that
name already, and `EXECRAM_VLINK` if `vlink` isn't on `PATH`.

It builds `execram`, links `e2e/program.s` (a small program with both a
cross-hunk and a self-hunk relocation) into a real executable, packs it
with `execram pack --backend=$EXECRAM_TEST_BACKEND`, extracts the inner
stub+header+payload container (`e2e/extract_container.py`, reading the
outer hunk's own declared length - not the AmigaDOS CLI/Workbench boot
path, which real execram output normally goes through, but a much
simpler way to exercise the packed program's *runtime stub* directly),
and boots it via `e2e/loader.s` - a small disk-reading boot loader,
distinct from `boot/sentinel.s`'s plain hardware-banging one, needed
because a real depacker stub doesn't fit in the 1024-byte boot block
`sentinel.s` gets away with (the inflate stub alone is already over 1KB).
`loader.s` reads the container from the disk (starting right after its
own boot block) into a Chip RAM buffer via `trackdisk.device`, then
jumps to it.

The test program only prints its sentinel correctly if a pointer that
went through both relocations ends up correct - this is a real
functional check of decompress+allocate+relocate+jump, not just "did it
not crash". Three real bugs surfaced during development, all only
catchable by actually booting a packed program (the bare sentinel test,
with no header/payload/stub involved, couldn't have caught any of them):

- `StubEnd` was originally defined inside `stubs/common/runtime.i`,
  which is `include`d *before* each backend's own `Depack` code - so it
  pointed at the start of `Depack` instead of the true end of the
  assembled stub.
- `extract_container.py` originally scanned for the "ExCr" magic bytes
  instead of reading the hunk's declared length, and found a
  coincidental match inside the stub's own `cmp.l #MAGIC,...`
  instruction - it "passed" only because Python's slice clamping
  happened to land on the file's true end anyway. Fixed to read the
  length field directly, correct by construction rather than by
  coincidence.
- `loader.s`'s first version passed an unaligned read length straight
  through to `trackdisk.device`'s `CMD_READ`, which requires a
  512-byte-sector-aligned length and fails otherwise (confirmed by
  adding temporary serial checkpoints: execution reached `DoIO` fine,
  but `io_Error` came back non-zero). Fixed by rounding the read length
  up to the next sector - the handful of extra zero bytes that reads in
  are never examined by anything downstream.

## Larger-scale end-to-end test (`run_large_e2e_test.sh`)

`run_e2e_test.sh`'s program is deliberately tiny (a couple of
relocations, one short sentinel line) - enough to prove the mechanism,
but not enough to trust at real-world scale, or to get a meaningful
compression ratio out of. `run_large_e2e_test.sh` runs the same
mechanism against `e2e_large/gen_large_program.py`'s output instead:
several KB of real prose and 22 relocations (20 self-hunk, 2
cross-hunk), and - unlike every other test here - diffs the *entire*
serial transcript against a byte-exact expected file, not just a grep
for one sentinel line. It also prints every backend's compression ratio
on that program while it's at it (`store`/`inflate`/`zx0`), since having
a large enough test program was the prerequisite for any ratio numbers
existing at all (see `PROJECT_PLAN.md` M1-M3).

```sh
EXECRAM_KICKSTART=~/amiga/"Kickstart v1.3 ...rom" \
  EXECRAM_TEST_BACKEND=zx0 \
  tests/uae/run_large_e2e_test.sh   # or store/inflate (script default: auto)
```

The jump from a one-line sentinel to a multi-KB exact-match transcript
immediately surfaced a real bug - in the test harness, not the pack
pipeline: `pty_bridge.py`'s pty was left in the default "cooked" tty
mode, whose ONLCR output translation turns every `0x0A` the 68k code
sends into `0x0D 0x0A` on the way out. Invisible to a human eye, and to
every earlier test here (they only grepped for a sentinel substring,
tolerating the extra `0x0D` silently) - but a real difference once
`cmp`-exact comparison was actually being done. Confirmed as a
harness-only artifact, not a decompression or relocation defect, by
stripping the `0x0D` bytes from the "failing" transcript and finding an
exact match underneath. Fixed by putting the pty's slave side into raw
mode (`termios`, clearing `ONLCR`/`OPOST`) in `pty_bridge.py`, which
`run_boot_test.sh` and `run_e2e_test.sh` also benefit from even though
their weaker sentinel-substring checks never depended on it.
