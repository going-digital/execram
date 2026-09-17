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

## Overlap-mode margin

`zx0`/`salvador` support the overlap layout (`docs/format-spec.md` §8b) -
`unzx0_68000.s`'s own `Depack:` is completely unchanged; the same one
routine serves both layouts, since `stubs/common/runtime.i`'s `Start:`
branches on `FLAG_OVERLAP` only in how it locates `Depack`'s own input,
not in which stub gets assembled (confirmed by direct inspection before
this design was written: every read of the compressed input is strictly
forward, post-increment only, via A0 - no lookahead or backward re-read
anywhere; back-references only ever read from the *output*, via A1/A2, a
separate, non-overlapping concern).

Unlike `store` (`docs/algorithm-notes/store.md`'s own section), ZX0's
margin is genuinely **data-dependent**, not near-zero: a long literal
run or a match copying many output bytes per compressed byte consumed
can let the write pointer race ahead of what's actually been read from
the compressed stream, before the next match's own back-reference "pays
back" some of that ratio. There is no fixed constant that's provably
safe for every input - `execram pack --backend=zx0|salvador --overlap=on`
always measures the real margin for the specific file being packed
(`src/musashi_bench.zig`'s `measureOverlapMargin`, `docs/format-spec.md`
§8b), the same per-file "proven for this input" approach Shrinkler's own
`--overlap` mode uses (`docs/memory-lifecycle.md`'s Comparison section),
not a generic theoretical bound. Incompressible input (long literal runs,
few or no matches) is the adversarial case worth testing against - see
`src/main.zig`'s own `"overlap margin stays bounded on incompressible
input"` test.

Applies identically to `unzx0_68000_fast.s` (`zx0fast`/`salvadorfast`) -
same fundamental forward-read, no-lookahead structure, just fewer
branches - whenever `src/main.zig`'s `compressWithBackend` starts
measuring a margin for it too; no stub or runtime change is needed to
extend `--overlap` there, only that one wiring decision (PROJECT_PLAN.md
scope for this pass; see `docs/format-spec.md` §10).

## In-loop decompression flicker

Both depackers' flash-instrumented siblings
(`stubs/zx0/unzx0_68000_flash.s`, `stubs/zx0/unzx0_68000_fast_flash.s`,
`docs/format-spec.md` §8c) use A3 for the poke address, confirmed via
direct grep to appear nowhere in either original file. `unzx0_68000.s`'s
own entry point already matches the `Depack` contract directly, so its
flash stub (`stubs/zx0/stub_flash.s`) sets up A3 at the very top, before
calling in - `FLAG_KILLTWITCH` is read via A2 while it's still the real
header pointer. `unzx0_68000_fast.s`'s entry label
(`zx0_decompress:`, not `Depack:` - it needs a thin wrapper regardless,
since it trashes D0-D2/A2) means A2 isn't reliably valid at *its* own
entry, so `stubs/zx0/stub_fast_flash.s` does the A3 setup itself, in the
wrapper, before the `bsr.s zx0_decompress` call. Both poke
`move.w d0,(a3)` (the `dbf`/`dbra` loop counter) in `.copy_lits` and
`.copy_match`/`.do_copy_offs` - every decoded byte, in both variants.
