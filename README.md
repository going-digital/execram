# execram

An executable compressor for Amiga programs, in the spirit of
[Shrinkler](https://github.com/askeksa/Shrinkler), with pluggable
compression backends (Inflate, [ZX0](https://github.com/einar-saukas/ZX0),
and a Shrinkler-class LZMA-like algorithm).

See [PROJECT_PLAN.md](PROJECT_PLAN.md) for architecture and milestones, and
[docs/LICENSES.md](docs/LICENSES.md) for the third-party license audit
covering the reference implementations this project builds on.

## Building

Requires [Zig 0.16](https://ziglang.org/) and two builds of
[vasm](http://sun.hasenbraten.de/vasm/) on `PATH`: `vasmm68k_mot` (used
by every stub except inflate's) and `vasmm68k_std` (needed only by the
inflate stub, which includes a vendored upstream file written for a
GNU-as-style dialect — see
[stubs/inflate/README.md](stubs/inflate/README.md)). `zig build test`
additionally needs [vlink](http://sun.hasenbraten.de/vlink/) on `PATH`
to link the real test-fixture executables `src/hunk.zig`'s tests run
against.

```sh
zig build              # build ./zig-out/bin/execram
zig build test         # run unit tests (needs vlink too, see above)
zig build run -- pack  # build and run
```

If any of these aren't on `PATH`, point at them explicitly:

```sh
zig build -Dvasm=/path/to/vasmm68k_mot -Dvasm-std=/path/to/vasmm68k_std -Dvlink=/path/to/vlink
```

## Status

M1-M6 done (store, inflate, zx0, and shrinkler backends all pack and
boot real executables correctly, verified under FS-UAE) — see the
milestones in [PROJECT_PLAN.md](PROJECT_PLAN.md#7-milestones). `execram
pack [--backend=store|inflate|zultra|zx0|salvador|shrinkler|auto]
[--mem=chip|fast] [-v] <in> <out>` works today (`auto`, the default,
tries every backend and keeps the smallest result). `shrinkler` -
Shrinkler's own LZ + adaptive range coder, adapted rather than
reimplemented (see [docs/LICENSES.md](docs/LICENSES.md)) - usually
produces the smallest output of all, at the cost of the slowest
host-side compression.

`execram info <packed-exe>` reports a packed executable's container
header fields (backend, memory type, relocations, sizes, ratio)
without decompressing anything. Every `pack` also self-checks before
writing anything: it decompresses what it just produced, host-side,
and compares it byte-for-byte against the original - refusing to save
a broken executable rather than shipping one and finding out on real
hardware.

A synthetic test corpus (`tests/corpus/`) and matrix runner
(`tests/uae/run_corpus_test.sh`) boot every backend against several
purpose-built programs - no relocations at all, a Chip-RAM-resident
hunk, a large BSS actually verified zeroed at runtime, a
non-compressible payload - catching things the two original e2e
programs didn't reach; `tests/ratio/track_ratios.py` tracks every
backend's output size against a committed baseline and runs in CI
(`.github/workflows/ci.yml`), no Kickstart ROM required.

`zultra` is an alternative, stronger host-side compressor for the same
container/depacker `inflate` uses (both produce standard raw DEFLATE) —
see [src/backends/zultra_vendor/README.md](src/backends/zultra_vendor/README.md).
Likewise, `salvador` is an alternative host-side compressor for the same
container/depacker `zx0` uses (both produce the same ZX0 v2 format) —
see [src/backends/salvador_vendor/README.md](src/backends/salvador_vendor/README.md).
