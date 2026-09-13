# execram

An executable compressor for Amiga programs, in the spirit of
[Shrinkler](https://github.com/askeksa/Shrinkler), with pluggable
compression backends: DEFLATE ([inflate](docs/algorithm-notes/inflate.md)),
[ZX0](docs/algorithm-notes/zx0.md), and
[Shrinkler's own LZ77 + adaptive range coder](docs/algorithm-notes/shrinkler.md) -
plus alternative, stronger host-side compressors (`zultra`, `salvador`)
for the DEFLATE and ZX0 depackers respectively, sharing them without
needing a new stub.

v1.0: every backend packs and boots real Amiga executables correctly,
verified against real emulated 68k hardware, not just host-side tests -
see [Status](#status) below and [PROJECT_PLAN.md](PROJECT_PLAN.md) for
the full milestone history.

Prebuilt binaries for Linux (x86_64/aarch64/arm), macOS
(x86_64/aarch64), and Windows (x86_64/aarch64) are published on the
[Releases page](../../releases) for every tagged version - see
[CONTRIBUTING.md](CONTRIBUTING.md#releasing) for how those are built.
Building from source (below) is the only option for anything not
tagged yet.

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

`tests/uae/run_real_exe_test.sh` boots real, third-party executables
(not written for this test suite) the same way AmigaDOS actually
would - a genuine launch via FS-UAE's own auto-boot of a single
executable file, not the bare-metal boot block every other script here
uses, since a real program's own `OpenLibrary` calls need a real
environment to succeed in.

`zultra` is an alternative, stronger host-side compressor for the same
container/depacker `inflate` uses (both produce standard raw DEFLATE) —
see [src/backends/zultra_vendor/README.md](src/backends/zultra_vendor/README.md).
Likewise, `salvador` is an alternative host-side compressor for the same
container/depacker `zx0` uses (both produce the same ZX0 v2 format) —
see [src/backends/salvador_vendor/README.md](src/backends/salvador_vendor/README.md).

`execram bench [--all] <in>` packs an executable with every backend
(all six with `--all`; otherwise inflate/zultra/salvador/shrinkler -
store adds no compression to compare, and zx0 shares salvador's exact
decompression cost for a much slower host-side compress) and prints a
table: output size, compression ratio, and 68000 depack cost in exact
CPU cycles - measured by actually running each depacker stub through
[Musashi](https://github.com/kstenerud/Musashi), a 68000 CPU-core
emulator, instead of FS-UAE's real-time-paced boot process. Useful for
comparing backends' decompression speed without host-load noise, though
it's a best-case lower bound (no chip RAM bus-contention modeling)
rather than a wall-clock prediction. `tools/bench/` is a separate,
dev-only tool built on the same Musashi core for timing an
already-packed file one at a time - see
[tools/bench/README.md](tools/bench/README.md).

## Documentation

- [PROJECT_PLAN.md](PROJECT_PLAN.md) - architecture, milestones, and the reasoning behind each
- [docs/format-spec.md](docs/format-spec.md) - the container format every backend's stub implements
- [docs/memory-lifecycle.md](docs/memory-lifecycle.md) - what's resident in memory, where, and for how long, from `LoadSeg` to the payload's entry point
- [docs/algorithm-notes/](docs/algorithm-notes/) - how each backend's compression format actually works
- [docs/LICENSES.md](docs/LICENSES.md) - the full third-party license audit
- [CONTRIBUTING.md](CONTRIBUTING.md) - building, testing, and adding a backend

## License

execram's own code is [MIT-licensed](LICENSE). Several vendored
third-party components carry their own separate (all permissive, none
copyleft) licenses - see [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md)
for the consolidated notices and [docs/LICENSES.md](docs/LICENSES.md)
for the full audit behind them.
