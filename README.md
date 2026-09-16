# execram

execram is an executable compressor for Amiga programs, in the spirit
of [Shrinkler](https://github.com/askeksa/Shrinkler): it takes an
AmigaDOS load file and produces a smaller one that decompresses itself
back to the original in memory when run, with no runtime dependency
beyond AmigaDOS's own `LoadSeg`. Unlike Shrinkler, it supports several
interchangeable compression backends rather than just one.

## How it works

- **Flatten.** The input's hunks (code/data/BSS, relocations) are
  flattened into a single image plus a relocation stream - the
  compressor never has to understand hunks or relocations itself.
- **Compress.** One of several pluggable backends compresses that
  image: DEFLATE ([inflate](docs/algorithm-notes/inflate.md)),
  [ZX0](docs/algorithm-notes/zx0.md), [Shrinkler's own LZ77 +
  adaptive range coder](docs/algorithm-notes/shrinkler.md), or
  [LZ4](docs/algorithm-notes/lz4.md) (trading ratio for much faster
  decompression) - plus `zultra`, `libdeflate`, `zopfli`, and
  `salvador`, alternative, stronger host-side compressors that reuse
  the inflate and ZX0 depackers respectively rather than needing stubs
  of their own.
- **Package.** The compressed payload is wrapped with a small 68k
  depacker stub into a new two-hunk AmigaDOS executable: a tiny
  resident hunk sized for the decompressed program, and a scratch hunk
  (stub + payload) that decompresses in place and is freed before the
  program itself runs - see
  [docs/memory-lifecycle.md](docs/memory-lifecycle.md).
- **Verify.** Before anything is written to disk, execram decompresses
  its own output host-side and checks it byte-for-byte against the
  original - it refuses to save a broken executable rather than ship
  one and find out on real hardware.

See [docs/format-spec.md](docs/format-spec.md) for the exact container
format every backend's stub implements.

## Usage

Prebuilt binaries for Linux (x86_64/aarch64/arm), macOS
(x86_64/aarch64), and Windows (x86_64/aarch64) are published on the
[Releases page](../../releases) for every tagged version; see
[Building](#building) below to build from source instead.

```sh
execram pack [--backend=store|inflate|zultra|libdeflate|zopfli|zx0|salvador|shrinkler|lz4small|lz4normal|lz4fast|zx0fast|salvadorfast|most|auto]
             [--mem=chip|fast] [-v] [--flash] <in> <out>
```

Packs `<in>` into `<out>`. `--backend=most`, the default, tries
`zultra` and `salvador` and keeps whichever is smaller - the two
backends that usually win, without paying for an exhaustive search;
`--backend=auto` tries all thirteen and keeps the smallest overall.
`shrinkler` - Shrinkler's own LZ + adaptive range coder, adapted rather
than reimplemented - usually produces the smallest output of all, at
the cost of the slowest host-side compression. `lz4small`/`lz4normal`/
`lz4fast` are one LZ4HC compressor paired with three different
depacker stubs (72/180/3722 bytes) that trade stub size for
decompression speed - all three produce identical payload bytes, so
picking between them is a real speed-vs-size call for your own
program, not something execram decides for you (see `execram bench`).
`zx0fast`/`salvadorfast` make the same trade for the ZX0 format:
`zx0`'s/`salvador`'s exact host encoders paired with a faster depacker
(Chris Hodges/Platon42's fork), ~29% fewer decompression cycles for a
64-byte larger stub. Chip vs. Fast RAM is normally auto-detected from
the input; `--mem` overrides it.

```sh
execram info <packed-exe>
```

Reports a packed executable's container header (backend, memory type,
relocations, sizes, ratio) without decompressing anything.

```sh
execram bench [--all] <in>
```

Packs `<in>` with several backends and prints a comparison table:
output size, compression ratio, and 68000 decompression cost in exact
CPU cycles, measured by running each depacker stub through
[Musashi](https://github.com/kstenerud/Musashi) (a 68000 CPU-core
emulator) rather than a real-time-paced emulator boot.

## Building

Requires [Zig 0.16](https://ziglang.org/) and
[vasm](http://sun.hasenbraten.de/vasm/)'s Motorola/Devpac build
(`vasmm68k_mot`) on `PATH`. `zig build test` additionally needs
[vlink](http://sun.hasenbraten.de/vlink/) on `PATH` to link the real
test-fixture executables `src/hunk.zig`'s tests run against.

```sh
zig build              # build ./zig-out/bin/execram
zig build test         # run unit tests (needs vlink too, see above)
zig build run -- pack  # build and run
```

If any of these aren't on `PATH`, point at them explicitly:

```sh
zig build -Dvasm=/path/to/vasmm68k_mot -Dvlink=/path/to/vlink
```

## Status

v1.0: all six backends pack and boot real Amiga executables correctly,
verified against real emulated 68k hardware, not just host-side tests -
see [PROJECT_PLAN.md](PROJECT_PLAN.md#7-milestones) for the full
milestone history and [CONTRIBUTING.md](CONTRIBUTING.md) for how the
test suite (a synthetic corpus, a Musashi-based cycle-exact matrix, and
real third-party executables booted under FS-UAE) is organized.

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
