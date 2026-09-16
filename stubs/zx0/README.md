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

## zx0fast / salvadorfast (fast depacker variant)

- **Depacker stub** (`unzx0_68000_fast.s`): vendored copy of Chris
  Hodges (Platon42)'s fork of `unzx0_68000` -
  [git.platon42.de/chrisly42/unzx0_68000](https://git.platon42.de/chrisly42/unzx0_68000)
  (zlib license, same terms as `unzx0_68000.s` above), audited in
  `docs/LICENSES.md` §17. Same ZX0 depacker algorithm, restructured to
  inline `get_elias` at each of its four call sites instead of sharing
  one `bsr`/`rts` subroutine - fewer branches, more code.

Unlike `unzx0_68000.s`, this fork's own header says it "trashes:
d0-d2/a2" - it doesn't preserve D2/A2 itself, so `stub_fast.s` wraps it
in a `movem.l`/`bsr.w`/`movem.l` pair (same category of adapter the lz4
stubs need - see `stubs/lz4/README.md`).

Measured directly against `unzx0_68000.s` on `tests/corpus/hexagon.exe`
(`execram bench`, both paired with the same `salvador` host encoder):

| | depacker size | full stub | decompress cycles |
|---|---:|---:|---:|
| `unzx0_68000.s` (zx0/salvador) | 88 B | 288 B | 18,594,000 |
| `unzx0_68000_fast.s` (zx0fast/salvadorfast) | 138 B | 352 B | 14,424,900 |

~29% fewer decompression cycles for 64 more bytes in the stub - the
payload itself is byte-identical (same host encoder either way), so
this is a pure speed-vs-stub-size trade, not a ratio one. One real
constraint worth knowing before choosing it: this fork's own header
also narrows several internal accumulators from 32-bit to 16-bit as
part of the same optimization, capping any single literal-run or match
length it can correctly decode at 65535 - not a concern for any
program tried so far, but a genuine limit `unzx0_68000.s` doesn't have.
