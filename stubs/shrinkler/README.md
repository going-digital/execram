# Shrinkler backend provenance

- **Host-side compressor** (`src/backends/shrinkler_vendor/`): vendored
  C++ (Aske Simon Christensen's LZ + adaptive range coder + optimal
  parser), see that directory's own README.md for the exact commit,
  the deliberate build-only changes, and why it's C++ (not C like the
  other backends). zlib license, audited in `docs/LICENSES.md` §1.
- **Depacker** (`ShrinklerDecompress.s` in this directory): a trimmed
  (not renamed - see that file's own header comment) vendored copy of
  `decrunchers/ShrinklerDecompress.S` from the same commit - the actual
  decrunch code shipped and tested for over 20 years, not a clean-room
  reimplementation from the algorithm description (the license audit,
  `docs/LICENSES.md` §1b, found this is explicitly permitted -
  effectively public-domain-equivalent, more permissive even than the
  rest of the Shrinkler repo).

Unlike `unzx0_68000.s` (zx0 backend, whose calling convention already
matches `runtime.i`'s `Depack` contract almost exactly), Shrinkler's
depacker needs real adapter code: it takes two extra inputs
(`A2` = progress callback, zero to disable; `D7` = parity-context flag)
that `runtime.i`'s plain `Depack` contract (A0/A1/D0 in) has nowhere to
carry, and its own header comment's "preserves A2-A6" promise turns out
to only hold in the narrow sense that its body never *writes* those
registers - it still needs the *right* A2 handed to it, and it's this
project's own `runtime.i`, not Shrinkler, that actually depends on A2
surviving the call (`stub.s`'s own comment has the full story, including
a real bug this caused and how it was diagnosed - worth reading if
you're touching this stub).

`stub.s` sets up A2/D7, calls the depacker via a proper `bsr.w`/`rts`
pair (not a tail-branch - it needs control back to restore A2
afterward), and includes the trimmed depacker file.

## Verification note

This backend's correctness rested on more than the usual round-trip
test before it was trusted: a bug that corrupted every header field
read *after* decompression passed the host-side C++ round-trip test
*and* a real-hardware test that called `ShrinklerDecompress` directly
(bypassing `runtime.i` entirely) - it only showed up in the full
pack → boot → decompress → relocate → jump pipeline, and even there
just as silence (no serial output within the timeout), indistinguishable
at that level from a hang. If you change anything here, the full
`tests/uae/run_e2e_test.sh` / `run_large_e2e_test.sh` pair (not just
the unit test) is the actual bar, not a substitute for it.
