# LZ4 backend provenance

- **Host-side compressor** (`src/backends/lz4_vendor/`): vendored,
  unmodified `lz4.c`/`lz4.h`/`lz4hc.c`/`lz4hc.h` from
  [lz4/lz4](https://github.com/lz4/lz4)'s `lib/` (BSD-2-Clause),
  audited in `docs/LICENSES.md`. `LZ4_compress_HC()` at
  `LZ4HC_CLEVEL_MAX` is the only compressor entry point used; see that
  directory's own README for exactly why just these four files.
- **Depacker** (`lz4_smallest.asm`/`lz4_normal.asm`/`lz4_fastest.asm` in
  this directory): vendored from
  [arnaud-carre/lz4-68k](https://github.com/arnaud-carre/lz4-68k), MIT
  license. Three complete, independent decoders for the same raw LZ4
  block format, trading code size for decompression speed - unlike
  every other backend in this project, execram exposes this as three
  separate backends (`lz4small`/`lz4normal`/`lz4fast`) rather than
  picking one, since which end of that trade-off is right depends on
  the program being packed, not something execram can decide for you:

  | source | stub size | speed (upstream's own measurement) |
  |---|---:|---|
  | `lz4_smallest.asm` | 72 bytes | 1.0x (baseline) |
  | `lz4_normal.asm` | 180 bytes | 1.53x |
  | `lz4_fastest.asm` | 3722 bytes | 2.36x |

  All three compress to the *exact same payload bytes* (one host-side
  encoder, `src/backends/lz4.zig`, shared by all three CLI backends) -
  only the embedded stub differs, so `execram bench`'s size column is
  identical across all three and only its decompression-cycle column
  moves, exactly the trade-off this backend exists to expose.

## Modifications

- `lz4_normal.asm`: two `repeat 15 { ... }` blocks (vasm's Motorola-
  syntax module, `vasmm68k_mot`, doesn't support that block form -
  confirmed directly, `error 2: unknown mnemonic <repeat>`) were
  mechanically unrolled into 15 literal copies of the same instruction
  each - identical generated code, marked inline at each site. Verified
  byte-for-byte: the unrolled file assembles to exactly 180 bytes,
  matching upstream's own documented size.
- None of the three decoders natively preserve D2-D7/A2-A6 the way
  `stubs/common/runtime.i`'s `Depack` contract requires (they were
  written for a simpler "just call and trust the caller doesn't need
  its own registers back" convention, matching lz4-68k's own Atari ST
  demo use case, not execram's - all three treat several of those
  registers as scratch: D2/D4/A3/A4 at minimum, more in the fastest
  variant's generated jump table). `stub_small.s`/`stub_normal.s`/
  `stub_fast.s` each wrap the raw `lz4_depack` entry point in a
  `movem.l d2-d7/a2-a6,-(a7)` / `bsr.w lz4_depack` / `movem.l
  (a7)+,d2-d7/a2-a6` pair rather than auditing and hand-preserving only
  the registers each variant happens to clobber - correct regardless of
  the exact clobber set, at a fixed ~8-byte cost per stub (negligible
  next to any of the three, especially `lz4_fastest.asm`'s 3.7KB).

## Format

Raw LZ4 *block* format (no frame header/magic number/checksum -
`lz4_frame.asm`'s own header parsing isn't vendored, same reasoning as
DEFLATE without a zlib/gzip wrapper elsewhere in this project: execram's
own container header already carries `compressed_size`, so a second,
redundant framing layer is pure overhead). `Depack`'s D0 input
(compressed size) is exactly what upstream's own `lz4_depack` expects
in D0 already - no translation needed.
