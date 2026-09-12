# Contributing to execram

## Building and testing

See [README.md](README.md#building) for the toolchain requirements
(Zig 0.16, two vasm builds, vlink) and basic commands. Two more test
suites exist beyond `zig build test`, both local/dev-machine-only
because they need a Kickstart ROM (copyrighted - see
`docs/LICENSES.md` §9, never commit or fetch one in CI):

```sh
EXECRAM_KICKSTART=~/amiga/"Kickstart v1.3 ...rom" tests/uae/run_large_e2e_test.sh
EXECRAM_KICKSTART=~/amiga/"Kickstart v1.3 ...rom" tests/uae/run_corpus_test.sh
```

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
