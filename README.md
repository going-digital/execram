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
`vasmm68k_mot` binary) on `PATH`.

```sh
zig build              # build ./zig-out/bin/execram
zig build test         # run unit tests
zig build run -- pack  # build and run
```

If `vasmm68k_mot` isn't on `PATH`, point at it explicitly:

```sh
zig build -Dvasm=/path/to/vasmm68k_mot
```

## Status

Early scaffolding (M0) — see the milestones in
[PROJECT_PLAN.md](PROJECT_PLAN.md#7-milestones). Not yet functional.
