# shrinkler

Aske Simon Christensen's Shrinkler algorithm - an LZ77 + adaptive
range coder in the same family as LZMA, with its own simpler context
model, and (per the ratio numbers in `PROJECT_PLAN.md`'s M4 section)
usually the smallest output of all six backends, at the cost of the
slowest host-side compression. Vendored and adapted directly (host
compressor and depacker both), not clean-room reimplemented - the
license audit found that explicitly permitted, correcting the project
plan's original assumption that Shrinkler was GPL (`docs/LICENSES.md`
§1, §8).

## Format, in brief

Three layers, each independent of the other two (see
`src/backends/shrinkler_vendor/LZEncoder.h`'s own module comment for
the complete bit-level specification this summarizes):

1. **Symbol structure**: literals and LZ77 references, plus a repeated-
   offset shortcut like ZX0's (same rationale: reusing the last offset
   is common and cheap to signal).
2. **Context modeling**: every bit of that structure - which kind of
   symbol comes next, each bit of a literal byte, each bit of a length
   or offset - is assigned its own *context*: a slot tracking an
   adaptively-updated probability estimate for that specific kind of
   decision. Literal bits get one context per bit-position combined
   with byte parity; kind/length/offset bits get their own separate
   context groups. This is the main way Shrinkler's model is richer
   than DEFLATE's per-block Huffman tables or ZX0's context-free bit
   encoding - probabilities adapt continuously, per bit position, for
   the entire file, not just per 32KB-window match.
3. **Entropy coding**: a binary range coder consumes those adaptive
   probabilities and produces the final bitstream - conceptually
   similar to arithmetic coding, but implemented with only integer
   arithmetic (`RangeCoder.h`/`RangeDecoder.h`), which is what makes
   decoding cheap enough for a 68000.

The host-side compressor (`src/backends/shrinkler_vendor/`) builds a
suffix array over the whole input up front (`SuffixArray.h`, an SA-IS
implementation) to find candidate matches at every position, then runs
an optimal parse (`LZParser.h`) that - like the context modeling above -
accounts for the *actual bit cost* of each candidate symbol under the
current probability estimates, not just match length, iterating a few
passes (`Pack.h`) since better probability estimates change which parse
is actually optimal.

## Depacker

`stubs/shrinkler/ShrinklerDecompress.s` - a trimmed (not rewritten) copy
of upstream's actual, shipped `ShrinklerDecompress.S`. Needed real
adapter code in `stub.s`, unlike zx0/inflate: it takes two extra inputs
(a progress-callback pointer, a parity-context flag) `runtime.i`'s
plain `Depack` contract has no way to express, and - the one genuine
bug this surfaced - its "preserves A2-A6" claim only holds in the sense
that it never *writes* those registers, not that whatever value it's
handed survives for the caller's own purposes. See `stubs/shrinkler/
stub.s`'s own comment for the full story if you're touching this file.

Only the raw decompression routine is vendored, not any of Shrinkler's
own decrunch headers or memory scheme - `docs/memory-lifecycle.md`'s
"Comparison: how Shrinkler's own decrunchers handle this" covers what
those actually do (per-hunk allocation via `LoadSeg` itself, no
`AllocMem`, and - in its default mode - the one `FreeMem` call anywhere
in the whole codebase, freeing its own scratch hunk once decompression
finishes).

## In-loop decompression flicker

A3 is the flicker's address register here too
(`stubs/shrinkler/ShrinklerDecompress_flash.s`, `docs/format-spec.md`
§8c) - confirmed free by the same kind of direct check that caught the
real A2 bug above: A3 appears only inside `ReportProgress`'s own
callback-arg code, which is dead in execram's usage (the callback
pointer/A2 is always zero, so `.nocallback` is always the path taken -
see `stub.s`'s own note on this routine's register quirks). The
flash-instrumented `stub_flash.s` sets up A3 - and reads
`FLAG_KILLTWITCH` via A2 - *before* the plain `stub.s`'s own
`suba.l a2,a2` zeroes A2 for the (unused) progress callback, the same
ordering constraint that makes A2's real value worth saving/restoring
around this call at all. Two poke sites, not one: `move.w d6,(a3)` right
after `.lit`'s `move.b d6,(a5)+` (a freshly-decoded literal byte) and
`move.w d0,(a3)` in `.copyloop` (the remaining-length counter) - full
per-byte coverage across both the literal and match-copy paths.
