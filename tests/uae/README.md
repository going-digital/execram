# FS-UAE boot tests

For the reserved-allocation and mixed-memory regression, run
`EXECRAM_KICKSTART=/path/to/ROM python3 tests/uae/run_mixed_memory_test.py`.
It boots the original and five backend variants through real AmigaDOS on
a 512 KB Chip + 512 KB Slow A500. Backend names can be supplied as arguments.
The bare-metal corpus loader also accepts v1's additional resident hunks.
For a targeted real-game check, set `EXECRAM_TEST_BACKEND=zultra` when running
`run_real_exe_test.sh`; omitting it keeps the full existing matrix.

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
  tests/uae/run_e2e_test.sh   # or store/zultra/zx0/salvador/shrinkler (script default: store)
```

Also needs `EXECRAM_VLINK` if `vlink` isn't on `PATH`.

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
not crash". Five real bugs surfaced during development, all only
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
- The shrinkler backend's stub zeroed A2 (Shrinkler's own "no progress
  callback" input) without saving/restoring it first, silently
  corrupting every container-header field `runtime.i` reads *after*
  decompression (it keeps the header base in A2 across the whole
  `Start` routine). This one passed both the host-side round-trip test
  *and* a real-hardware test of the depacker called directly (bypassing
  `runtime.i` entirely) - it only failed in the full pipeline, and even
  there just as silence (no sentinel within the timeout), indistinguishable
  from a hang. Found by isolating each layer in turn (host encoder vs.
  real upstream Shrinkler's own CLI output, byte-for-byte; the depacker
  alone against known-good compressed bytes on real hardware, via a
  disposable boot-block test bypassing this whole harness; then the
  container header fields) until the one thing not yet isolated - what
  `stub.s` itself handed the depacker - turned out to be the bug. See
  `stubs/shrinkler/stub.s`'s own comment.
- The two-hunk redesign (`docs/memory-lifecycle.md`) needed a rewritten
  `loader.s` that parses the real hunk file and reconstructs `LoadSeg`'s
  own memory layout by hand (this scheme fundamentally depends on a real
  hunk chain existing, which the previous bare-metal loader never built).
  Its `AllocHunk` subroutine calls the real `EXEC_AllocMem`, standard
  Amiga library code free to clobber A0/A1/D0/D1 like any other LVO
  call - A0 (the loader's own read position in the scratch disk-read
  buffer) was never saved across it, so both reconstructed hunks' bodies
  came back all-zero (`MEMF_CLEAR`'s own fill, untouched) instead of
  their real copied bytes. Found by dumping the constructed hunks' own
  memory over serial right before the final jump. Fixed by saving/
  restoring A0 around both call sites.
- The same redesign also exposed a genuine bug in the shipped runtime
  itself, not just the test loader: hunk 0's declared/allocated size
  only accounted for `code_data_size + bss_size`, not `code_data_size +
  max(bss_size, reloc_stream_size)` as `Depack` actually needs - when
  `reloc_stream_size` exceeds `bss_size`, `Depack` overflows hunk 0 into
  hunk 1's own header, corrupting the size field its later `FreeMem`
  call reads. Every real executable tried before this test program
  (`tests/corpus/hexagon.exe` included) happened to have `bss_size`
  dominate, masking the bug completely - only this program's own tiny
  profile (0 bytes BSS, a 3-byte reloc stream) exposed it. Found by
  bisecting with serial checkpoints inside the actual embedded stub code
  (not just `loader.s`) until the exact point between "before `Depack`"
  and "after `Depack`" where hunk 1's own header field changed from
  correct to corrupted. Fixed in `main.zig`'s `hunk0Size()` helper.

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
on that program while it's at it
(`store`/`inflate`/`zultra`/`zx0`/`salvador`/`shrinkler`), since having
a large enough test program was the prerequisite for any ratio numbers
existing at all (see `PROJECT_PLAN.md` M1-M3).

```sh
EXECRAM_KICKSTART=~/amiga/"Kickstart v1.3 ...rom" \
  EXECRAM_TEST_BACKEND=zx0 \
  tests/uae/run_large_e2e_test.sh   # or store/inflate/zultra/salvador/shrinkler (script default: auto)
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

## Corpus test matrix (`run_corpus_test.sh`, M6)

`run_e2e_test.sh` and `run_large_e2e_test.sh` each probe one shape of
program (a couple of relocations; several KB of prose with 22
relocations). `run_corpus_test.sh` generalizes to N programs x every
backend: it boots each of `tests/corpus/gen_corpus.py`'s items
(`no_relocs`, `chip_mem`, `bss_heavy`, `incompressible` - see that
directory's own README for what each one targets) under every backend
in turn, diffing the exact expected transcript each time, and prints a
pass/fail matrix at the end.

```sh
EXECRAM_KICKSTART=~/amiga/"Kickstart v1.3 ...rom" \
  tests/uae/run_corpus_test.sh
```

Slower than the other two scripts here by design - it boots (corpus
items) x (backends) times, not once - so expect it to take several
minutes. `chip_mem` in particular was worth adding: forcing a packed
program's whole resident block into Chip RAM
(`stubs/common/runtime.i`'s `MEMF_CHIP` path) had only ever been
checked at the host level (`container.zig`'s unit test, which just
confirms the header *flag* gets set) before this matrix put it under a
real depacker on real (emulated) hardware for the first time.
`bss_heavy` similarly goes further than `run_large_e2e_test.sh`'s own
BSS segment (declared, sized, but never read back): it actually samples
BSS bytes at runtime and reports whether `AllocMem`'s `MEMF_CLEAR`
really zeroed a nontrivial (64K) region.

Requires the same things as `run_e2e_test.sh`/`run_large_e2e_test.sh`.

## Real-executable test (`run_real_exe_test.sh`)

Every other script here boots a bare-metal boot block
(`tests/uae/e2e/loader.s`) that jumps straight into a packed program's
stub with no AmigaDOS environment at all - no `Process`, no `LoadSeg`,
no libraries opened. Fine for the synthetic corpus, deliberately
written to never call `OpenLibrary`; not fine for a real program that
does. `run_real_exe_test.sh` boots real executables
(`tests/corpus/*.exe` with a paired `*.meta` - see that directory's own
README and this script's own header) via a genuine AmigaDOS launch
instead, and does it with dramatically less machinery than
`loader.s`'s own disk-image-building pipeline: FS-UAE (like WinUAE)
auto-wraps a single AmigaDOS executable file pointed at as a floppy
drive into a minimal bootable disk with a real startup-sequence, so
just pointing `--floppy_drive_0` straight at execram's own packed
output is enough - no loader, no manual disk assembly.

```sh
EXECRAM_KICKSTART=~/amiga/"Kickstart v1.3 ...rom" \
  tests/uae/run_real_exe_test.sh
```

This exists because of a real, fully-chased-down false alarm:
`tests/corpus/hexagon.exe` (a real Amiga demo, 220KB, 626 relocations,
a 198KB Chip-RAM hunk) failed identically under `loader.s` no matter
what was varied - register state, stack size, chip RAM size, even
across independent rebuilds of the program itself with real source
changes - always the exact same faulting PC and opcode. That
consistency turned out to be the tell: a from-scratch Python
reimplementation of `flatten.zig`'s own merge/relocation algorithm,
checked directly against execram's real output, proved the relocation
math byte-for-byte correct (626 sites, the full code+data region) well
before this script existed, and disassembling the actual crash site
identified the mechanism precisely (a library call dispatched through
a not-yet-open library base, a real bug in the program's own startup
order - nothing to do with execram). What `loader.s` could never
explain was why `OpenLibrary` itself wasn't succeeding at all - and the
answer was simply that a bare-metal boot block was never going to
provide what a real program expects. Once boots moved to a genuine
AmigaDOS launch, the exact same packed output (no execram change at
all) ran correctly first try - for five of the six backends, on the
first attempt. The sixth, `shrinkler`, is a second real, distinct
finding worth recording separately: it initially came back
`FAIL(no-sentinel)` at this script's original 30-second timeout, with
nothing unusual in FS-UAE's own log (no exception, no crash - just
quiet, ordinary execution right up to the point it got killed).
Shrinkler's adaptive range decoder does meaningfully more per-bit work
on real 68000 timing than the other backends' simpler decode loops
(a `mulu.w` alone costs 38-70 cycles, executed multiple times per
decoded bit), and this project had never asked it to decompress
anything close to 221KB before - a longer, targeted retest confirmed
it does complete and boot correctly, just slower, which is why
`BOOT_TIMEOUT_CHECKS` here is considerably more generous than the
other scripts' - see that constant's own comment.
