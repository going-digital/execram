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

M1-M3 done (store, inflate, and zx0 backends all pack and boot real
executables correctly, verified under FS-UAE) — see the milestones in
[PROJECT_PLAN.md](PROJECT_PLAN.md#7-milestones). `execram pack
[--backend=store|inflate|zx0|auto] <in> <out>` works today (`auto`, the
default, tries every backend and keeps the smallest result); shrinkler
lands in a later milestone.
