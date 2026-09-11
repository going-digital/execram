# execram

An executable compressor for Amiga programs, in the spirit of
[Shrinkler](https://github.com/askeksa/Shrinkler), with pluggable
compression backends (Inflate, [ZX0](https://github.com/einar-saukas/ZX0),
and a Shrinkler-class LZMA-like algorithm).

See [PROJECT_PLAN.md](PROJECT_PLAN.md) for architecture and milestones, and
[docs/LICENSES.md](docs/LICENSES.md) for the third-party license audit
covering the reference implementations this project builds on.

## Building

Requires [Zig 0.16](https://ziglang.org/) and
[vasm](http://sun.hasenbraten.de/vasm/) (the `m68k`/`mot` build, i.e. the
`vasmm68k_mot` binary) on `PATH`. `zig build test` additionally needs
[vlink](http://sun.hasenbraten.de/vlink/) on `PATH` to link the real
test-fixture executables `src/hunk.zig`'s tests run against — plain
`zig build`/`zig build run` don't need it.

```sh
zig build              # build ./zig-out/bin/execram
zig build test         # run unit tests (needs vlink too, see above)
zig build run -- pack  # build and run
```

If `vasmm68k_mot`/`vlink` aren't on `PATH`, point at them explicitly:

```sh
zig build -Dvasm=/path/to/vasmm68k_mot -Dvlink=/path/to/vlink
```

## Status

Early scaffolding (M0) — see the milestones in
[PROJECT_PLAN.md](PROJECT_PLAN.md#7-milestones). Not yet functional.
