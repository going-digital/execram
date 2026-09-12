# Test corpus (M6)

`gen_corpus.py` generates a small set of synthetic Amiga programs, each
built to exercise one axis of packer behavior that `tests/uae/e2e/`'s
two existing test programs don't reach on their own:

| Item | Axis exercised |
|---|---|
| `no_relocs` | Zero relocation sites at all (`FLAG_HAS_RELOCS` clear) |
| `chip_mem` | A hunk explicitly requiring Chip RAM, forcing the whole packed program resident there at runtime |
| `bss_heavy` | A large (64K) BSS, and actually reads it back at runtime to confirm `MEMF_CLEAR` really zeroed it |
| `incompressible` | A deterministic, non-repeating payload - the worst case for every LZ-family backend |

See each `item_*` function's own docstring in `gen_corpus.py` for the
full rationale.

Consumers:

- `tests/uae/run_corpus_test.sh` boots every item under every backend
  in FS-UAE and checks the exact expected transcript comes back over
  the emulated serial port (needs a Kickstart ROM - see that script's
  own header).
- `tests/ratio/track_ratios.py` packs every item (plus the two existing
  e2e programs) with every backend and tracks output size against a
  committed baseline - no FS-UAE or ROM needed, so this one also runs
  in CI.

Regenerate on demand (`gen_corpus.py <out_dir>`) - nothing here is
checked into the repo as static files; both consumers generate fresh
copies into their own temp directories on every run, the same
discipline `tests/uae/e2e_large/gen_large_program.py` already
established.

## Real executables

Unlike everything above, a real executable (not written for this test
suite - a real program someone actually built) *is* checked directly
into this directory as a static binary, paired with a `<name>.meta`
file describing how to verify it booted correctly - see
`tests/uae/run_real_exe_test.sh`'s own header for the exact format and
why it needs a fundamentally different boot mechanism than
`run_corpus_test.sh`'s (a real program expects a genuine AmigaDOS
launch - `OpenLibrary`, a real `Process`, ... - that the synthetic
corpus's bare-metal boot block deliberately never needed).

- `hexagon.exe` - "Decahexagon", a real Amiga demo/game
  (Norwich Amiga Group), instrumented with `exram_serial.h` (a small,
  portable serial-output snippet - not part of execram itself, just
  enough to make a real program observable headlessly the same way
  every synthetic corpus item already is) to print a boot sentinel and
  a per-frame heartbeat. 220KB, 626 relocations, a 198KB Chip-RAM
  hunk - by far the largest, most realistic executable in any of
  execram's test suites, and the first one to surface a genuine
  cross-check worth recording: an early, very reproducible-looking
  crash (identical PC and opcode no matter what was varied - register
  state, stack size, chip RAM size) turned out to be neither an
  execram bug nor a memory-sizing problem, but `tests/uae/loader.s`'s
  bare-metal environment being unable to satisfy this program's own
  `OpenLibrary` calls - resolved by building `run_real_exe_test.sh`
  instead of chasing it further under the wrong boot mechanism. See
  that script's own header and the git log around when this file was
  added for the full trail if it matters to you.
