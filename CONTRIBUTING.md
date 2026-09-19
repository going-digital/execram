# Contributing to execram

## Building and testing

See [README.md](README.md#building) for the toolchain requirements
(Zig 0.16, vasm, vlink) and basic commands. More test suites
exist beyond `zig build test`, all local/dev-machine-only because they
need a Kickstart ROM (copyrighted - see `docs/LICENSES.md` §9, never
commit or fetch one in CI):

```sh
EXECRAM_KICKSTART=~/amiga/"Kickstart v1.3 ...rom" tests/uae/run_large_e2e_test.sh
EXECRAM_KICKSTART=~/amiga/"Kickstart v1.3 ...rom" tests/uae/run_corpus_test.sh
EXECRAM_KICKSTART=~/amiga/"Kickstart v1.3 ...rom" tests/uae/run_real_exe_test.sh
```

The first two boot a bare-metal boot block with no AmigaDOS environment
at all - fine for programs written for this test suite (which never
call `OpenLibrary`), not fine for a real one that does.
`run_real_exe_test.sh` boots real executables
(`tests/corpus/*.exe` + a paired `*.meta`) via a genuine AmigaDOS
launch instead - see that script's own header if you're adding one.

`execram bench [--all] <in>` (or `zig build bench -- <packed-exe>` for
the standalone dev-tool variant that reads an already-packed file
instead of packing fresh - `tools/bench/README.md`) predicts a
depacker's exact 68000 decompression cost in CPU cycles via Musashi
(`src/musashi_bench.zig`), needing no Kickstart ROM and no
real-time-paced boot - useful for comparing backends' speed without
FS-UAE's host-load sensitivity, but it doesn't replace the above for
correctness: it never touches relocation, `AllocMem` (beyond a minimal
fake Exec just for the one stub that needs it - `tools/bench/fake_exec.s`),
or a real AmigaDOS environment at all, and its cycle counts are a
best-case lower bound (no chip RAM bus-contention modeling), not a
validated wall-clock number.

**If your change touches `stubs/`, `src/container.zig`,
`src/flatten.zig`, or anything else in the actual pack/depack pipeline,
`zig build test` passing is necessary but not sufficient - run at least
`run_large_e2e_test.sh` before considering the change done.** This
project's real bugs (a mislocated label, an unaligned disk read, a
stray printf corrupting the build/test protocol, a clobbered register
that silently broke header reads after decompression) were *all* found
by booting a packed program under real emulated hardware, not by
`zig build test` or code review - see `tests/uae/README.md`'s bug
catalog and the git log for the specifics. A change to shared runtime
code that only passes host-side tests should not be trusted.

## Adding a new host-side compressor for an existing depacker

The cheapest way to improve a ratio: if another compressor produces the
exact same bitstream format an existing stub already decodes (confirmed
by diffing depacker source, not assumed from documentation - see how
`salvador`/`zx0` and `zultra`/`inflate` were verified), it needs no new
stub or `backend_id`, just:

1. Vendor the compressor under `src/backends/<name>_vendor/` (license
   audit first - see below).
2. `src/backends/<name>.zig`: a thin wrapper exposing `compress` and
   `decompress` with the same signatures every other backend uses (see
   `src/backends/salvador.zig` for the current shape) - `decompress`
   can delegate to another backend's if the format's genuinely shared
   (`zx0.decompress = salvador.decompress`).
3. Wire it into `src/main.zig`: add to `backend_names`, the
   `packWithBackend`/`decompressWithBackend` if-chains (reusing the
   existing stub and `container.BackendId`), the usage text.
4. A round-trip unit test, `tests/uae/run_e2e_test.sh` and
   `run_large_e2e_test.sh` with `EXECRAM_TEST_BACKEND=<name>` against
   the *existing, unmodified* stub - the fact that nothing else needed
   to change is the actual compatibility proof.
5. Add it to `run_large_e2e_test.sh`'s and `run_corpus_test.sh`'s
   backend lists, and get a fresh `tests/ratio/baseline.json` entry
   (`track_ratios.py ... --update-baseline`).

## Adding a genuinely new backend (new depacker, new `backend_id`)

Same shape as above, plus:

- A new stub under `stubs/<name>/`, built on
  `stubs/common/runtime.i`'s `Depack` contract (see that file's own
  header comment for the exact calling convention: A0/A1/D0 in,
  D2-D7/A2-A6 preserved, free to clobber D0/D1/A0/A1). If the
  depacker's own calling convention doesn't already match, write a
  small adapter in `stub.s` rather than editing the vendored asm - and
  if the depacker needs more registers than the contract preserves for
  its own purposes (a progress callback, a mode flag), make sure your
  adapter *restores* anything `runtime.i` still needs afterward, not
  just supplies what the depacker needs going in. Getting this
  backwards is exactly the shrinkler backend's one real correctness bug
  (see `stubs/shrinkler/stub.s`'s own comment) - it passed every
  host-side test and even a real-hardware test of the depacker called
  directly, and only failed in the full pipeline.
- The next free `backend_id` in `src/container.zig`'s `BackendId` enum
  and `docs/format-spec.md` §4's registry.
- A new page in `docs/algorithm-notes/`.

## Vendoring philosophy

Prefer adapting real, shipped, tested third-party code over clean-room
reimplementation, provided the license actually permits it - check
first, in `docs/LICENSES.md`, before vendoring anything. Every backend
in this project followed that path once its license was cleared. When
you do vendor something:

- Keep the vendored files as close to byte-identical to upstream as
  possible. Every deliberate deviation (a renamed entry label, a
  removed `printf` that corrupted the test protocol, a `-D`-renamed
  symbol to fix a link collision) gets documented as a comment *at the
  exact site*, not just in the commit message - see any `*_vendor/`
  directory's files for the pattern to follow.
- Add a license audit entry to `docs/LICENSES.md` (exact upstream
  commit, license text or a precise reference to it) before the vendor
  directory lands, and an entry to `THIRD_PARTY_LICENSES.md` if it's a
  new license type not already covered there.
- Write a `README.md` in the vendor directory itself covering
  provenance, license, and exactly what (if anything) was changed and
  why - `src/backends/shrinkler_vendor/README.md` is a thorough
  example.

## Code style

- Comments explain *why*, not what the code already says. When you
  discover something non-obvious (a tool's quirk, a silent trap, a
  register convention that looks safe but isn't), write it down at the
  file where it matters, so the next person hits the explanation before
  they hit the bug.
- Match the surrounding file's comment density and tone rather than
  either terse code with no rationale or narrating obvious lines.
- Commit messages for anything nontrivial should document the actual
  debugging trail for real bugs found (what broke, how it was
  diagnosed, what the fix was and why) - not just "fix bug in X". The
  git log is itself part of this project's documentation.

## Releasing

Push a tag matching `v*` (e.g. `v1.0.1`) to `main` -
`.github/workflows/release.yml` takes it from there: re-runs
`zig build test` as its own gate, then cross-compiles execram for all
seven target platforms from a single `ubuntu-latest` runner (one of
Zig's own strengths - no per-OS runner needed for the build itself),
packages each as an archive, and publishes a GitHub Release once every
target has uploaded successfully (a draft the whole time before that,
so a partial/broken release is never visible if one target fails).

Bump `build.zig.zon`'s own `.version` field to match before tagging -
`execram --version` reads it directly, so the two should never drift.
The release gate runs `zig build test` and the same compression-ratio
check as CI, using a ReleaseFast executable. A passing unit suite alone
cannot publish output that exceeds the reviewed size baseline.

After changing the memory layout, also run:

```sh
EXECRAM_KICKSTART=~/amiga/KICK13.ROM python3 tests/uae/run_mixed_memory_test.py
```

This boots the original and packed reserved-tail/mixed-memory fixture
through real AmigaDOS LoadSeg on a 512 KB Chip + 512 KB Slow A500. Host
runtime tests additionally exercise all eight depackers, both flash modes,
all overlap modes, explicit Fast memory, cross-region relocations, BSS,
allocation guards, and the retained LoadSeg chain.

Cross-compiling to a target this project had never built for before
(`arm-linux-musleabihf`, by way of validating the whole matrix) found a
real, previously-latent bug: `zultra_vendor/dictionary.c`'s unused
(by us) preset-dictionary-file feature used `off_t`/`ftello` without
the POSIX feature-test macro musl's headers gate them behind under
plain `-std=c99` - invisible on macOS, whose libc doesn't gate these
the same way, so nothing before this had ever hit it. See `build.zig`'s
own comment on the fix (`-D_POSIX_C_SOURCE=200809L`, not a source
edit). Verified the whole matrix builds and links cleanly, and smoke-
tested the one target matching this development machine's own
architecture against the existing test corpus - real execution on real
hardware for the other six targets (particularly the 32-bit ARM one)
hasn't been separately verified beyond that.
