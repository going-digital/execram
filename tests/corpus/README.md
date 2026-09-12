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
