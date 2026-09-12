# ZX0 backend provenance

- **Host-side compressor** (`src/backends/zx0_vendor/`): vendored,
  unmodified copy of
  [einar-saukas/ZX0](https://github.com/einar-saukas/ZX0)'s `src/`
  directory (minus `zx0.c`, the reference CLI's `main()`, which isn't
  needed - see `src/backends/zx0_vendor/README.md`). BSD-3-Clause,
  audited in `docs/LICENSES.md` §2.
- **Depacker stub** (`unzx0_68000.s` in this directory): vendored copy
  of Emmanuel Marty's
  [unzx0_68000](https://github.com/emmanuel-marty/unzx0_68000), zlib
  license, audited in `docs/LICENSES.md` §3. One deliberate change: the
  entry label `zx0_decompress` is renamed to `Depack` to match
  `stubs/common/runtime.i`'s calling convention - see the header comment
  in that file for the exact commit and details.

Unlike the inflate backend, this one needed no syntax-dialect
workarounds: `unzx0_68000.s` is already plain Motorola/Devpac syntax
(same dialect as every other stub in this project except inflate's), and
its calling convention (A0 = input, A1 = output, preserves A2) already
matches `runtime.i`'s `Depack` contract almost exactly - `stub.s` is
just two `include`s and a `StubEnd` label, no adapter code needed.
