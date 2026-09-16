# zx0 (and salvador, zx0fast, salvadorfast)

Einar Saukas's ZX0 format (v2, "inverted") - an LZ77 variant designed
from the outset for a minimal 8-bit-class depacker, which is exactly
why it fits a 68000 stub in barely over 100 bytes
(`stubs/zx0/unzx0_68000.s`). Two host-side compressors target this
exact same format:

- **`zx0`** (`src/backends/zx0.zig`): the reference optimal-parse
  compressor (einar-saukas/ZX0, BSD-3-Clause). See
  `src/backends/zx0_vendor/README.md`.
- **`salvador`** (`src/backends/salvador.zig`): an independent
  optimal-parse ZX0 compressor from the same depacker's own author
  (emmanuel-marty/salvador), confirmed byte-identical at the depacker
  level by diffing its bundled copy of the 68k routine directly against
  `unzx0_68000.s` - not assumed from documentation. See
  `src/backends/salvador_vendor/README.md`.

Both produce bit-compatible output for the *same choice of* depacker -
but unlike every other backend family in this project, that choice
isn't fixed: `zx0`/`salvador` embed `unzx0_68000.s` (`backend_id` 2),
while `zx0fast`/`salvadorfast` reuse the exact same two host encoders
(byte-identical payload either way) paired with a faster depacker
instead (`unzx0_68000_fast.s`, `backend_id` 7) - see "Depacker" below.

## Format, in brief

Like DEFLATE, ZX0 encodes a stream of literals and LZ77
back-references, but the encoding itself is built around what a tiny
depacker can unpack cheaply rather than what maximizes ratio in the
abstract:

- Every symbol starts with a single bit choosing literal vs. reference,
  interleaved with a bit-oriented **Elias-gamma-family variable-length
  number** encoding for lengths and offsets - short values cost very
  few bits, without needing the lookup tables a Huffman-coded format's
  decoder does.
- A **"last offset" reuse mechanism**: a reference can cheaply say "same
  offset as last time, new length" - common in real code/data, and
  cheaper to encode than restating the offset outright.
- No separate block structure at all (unlike DEFLATE's static/dynamic
  block split) - one continuous stream, decoded by one small,
  branch-light loop.

The optimal parser's job (both `zx0` and `salvador` do this, differently
internally but to the same result) is choosing, at every position,
whichever mix of literal/reference/reused-offset actually minimizes
total encoded *bits* - not just "longest match," since a shorter match
that reuses the last offset can cost fewer bits than a longer one that
doesn't.

## Depacker

`stubs/zx0/unzx0_68000.s` (Emmanuel Marty, zlib license -
`docs/LICENSES.md` §3) - vendored essentially untouched; its own
calling convention already matched `stubs/common/runtime.i`'s `Depack`
contract closely enough that the only change needed was renaming its
entry label. The smallest and simplest depacker of the four original
backends, by a wide margin.

`stubs/zx0/unzx0_68000_fast.s` (Chris Hodges/Platon42's fork, zlib
license - `docs/LICENSES.md` §17): the same decode algorithm, with
`get_elias` inlined at each of its four call sites instead of shared
via one `bsr`/`rts` subroutine - fewer branches at decode time, more
code. Measured on `tests/corpus/hexagon.exe`: ~29% fewer decompression
cycles (14,424,900 vs. 18,594,000) for 64 more stub bytes, same
payload either way - see `stubs/zx0/README.md` for the full numbers
and the one real trade-off worth knowing (narrower, 16-bit internal
accumulators cap any single literal-run/match length at 65535, a
constraint `unzx0_68000.s` doesn't have).
