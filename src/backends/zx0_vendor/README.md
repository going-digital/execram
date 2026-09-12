# Vendored ZX0 compressor

`compress.c`, `memory.c`, `optimize.c`, `zx0.h` are unmodified copies of
[einar-saukas/ZX0](https://github.com/einar-saukas/ZX0)'s `src/`
directory, commit `ecde3a2ae05061fe06469ed46df81a33b7de7d86` (audited
2026-09-11, see `docs/LICENSES.md` §2 - BSD-3-Clause, per-file headers
preserved as-is). `zx0.c` (the reference CLI's `main()`) is intentionally
not vendored - `shim.c` (ours, not upstream) calls `optimize()` and
`compress()` directly with the same parameters that CLI uses for its
default (non-classic, non-backwards, non-quick) mode, which is the
format `stubs/zx0/unzx0_68000.s` decompresses.

`src/backends/zx0.zig` calls `zx0_compress_buffer` (declared in
`shim.h`) via `@cImport`, copies the result into a Zig-allocated slice,
and frees the C-allocated buffer.
