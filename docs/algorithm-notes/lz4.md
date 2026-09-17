# lz4small / lz4normal / lz4fast

Yann Collet's LZ4 - an LZ77 variant designed for very cheap, very fast
decoding rather than ratio. One host-side compressor
(`src/backends/lz4.zig`, LZ4HC at its own maximum level) produces the
raw LZ4 block format; three independent 68k depackers
(arnaud-carre/lz4-68k, MIT) decode it, trading code size for speed.
Unlike every other backend pair in this project, the three aren't
alternative encoders for the same depacker - they're the same encoder
paired with three genuinely different depackers, so execram exposes
all three as separate backends rather than picking one:

| backend | depacker size | decompression speed |
|---|---:|---|
| `lz4small` | 72 bytes | baseline |
| `lz4normal` | 180 bytes | ~1.3x `lz4small` |
| `lz4fast` | 3722 bytes | ~2.2x `lz4small` |

(Speed factors from a real measurement, `execram bench` on
`tests/corpus/hexagon.exe` - see `PROJECT_PLAN.md`'s LZ4 entry for the
exact cycle counts; upstream's own README reports similar factors on
different test data.) All three produce byte-identical compressed
payloads - only the embedded stub differs, so this is a pure size (in
the depacker) vs. speed (of decompression) trade-off, not a ratio
question. `backend_id` 4/5/6 (one per stub, not one per encoder - see
`src/container.zig`'s own comment on why LZ4 breaks the "one ID per
format" pattern every earlier addition followed).

## Format, in brief

LZ4 blocks are a flat sequence of tokens, no block structure and no
entropy coding at all:

- Each token's first byte packs two 4-bit-ish length fields: a literal
  run length and a following match length, each extended by additional
  full bytes (0xFF, 0xFF, ..., non-0xFF) when the 4-bit field
  saturates - simple to decode (no Huffman tables to build), at the
  cost of literal-run/match lengths compressing less tightly than a
  proper entropy-coded format's would.
- Match offsets are a plain 16-bit little-endian value (max 64KB back),
  no variable-length encoding at all.
- No "last offset reuse" (unlike ZX0) or context modeling (unlike
  Shrinkler) - every design choice favors a short, branch-predictable
  decode loop over ratio.

This is exactly why the depacker can be 72 bytes: there's very little
to decode. LZ4HC's own "HC" (high compression) parser does real
optimal-parse-adjacent match-finding on the host side to pick the best
tokens within that fixed, simple format - the format's own ceiling is
still well behind DEFLATE/ZX0/Shrinkler's, which is the trade this
backend is for.

## Depacker

Three independent decoders, not three tuning levels of one algorithm -
see `stubs/lz4/README.md` for exactly what's vendored, the mechanical
`repeat` block expansion `lz4_normal.asm` needed for `vasmm68k_mot`,
and the register-preservation wrapper all three needed (none natively
follow `stubs/common/runtime.i`'s "preserve D2-D7/A2-A6" convention the
way `unzx0_68000.s` does).

## In-loop decompression flicker

All three flash-instrumented depackers (`docs/format-spec.md` §8c) use
A5 for the poke address - confirmed unused anywhere in any of the three
original files by direct grep, and set up in each `stub_*_flash.s`
wrapper's own `Depack:`, before the register-preservation `movem.l`, while
A2 (untouched by any of the three decoders themselves) still holds the
real header pointer for the `FLAG_KILLTWITCH` read.

`lz4small` and `lz4normal` poke on their shared counted copy loops
(`.litcopy`/`.copy`, `move.w d0,(a5)` right after each byte's own
`move.b`). For `lz4normal` specifically, that's *only* its counted
loops - runs of 15+ literal/match bytes within one token - not its
hand-unrolled short-run paths (`.small`/`.litcopys`, under 15 bytes, the
common case): those are addressed at fixed byte offsets by the format's
own jump table (`.copys+N`/`.copys2+N` for the exact remaining count),
so inserting an instruction into that unrolled block would silently
shift every one of those offsets and corrupt decoding - a mistake this
design deliberately avoids, at the cost of `lz4normal` flickering less
often than its own per-byte-everywhere siblings for typical (mostly
short-run) input.

`lz4fast` has no shared copy loop at all - fully unrolled via a
256-entry jump table into hand-duplicated `move.b` chains, for the exact
same reason above (several of *its* jump table entries also address
fixed mid-block offsets, e.g. `sl_sm0+4`/`sl_sm0+2`). Its poke instead
lives in the 5-instruction per-token dispatch trampoline
(`moveq #0,d0 / move.b (a0)+,d0 / add.w d0,d0 / move.w 0(a3,d0.w),d0 /
jmp 0(a3,d0.w)`) that recurs, byte-for-byte identical, after every one
of the file's unrolled blocks - 33 sites in total, found and edited by
an exact-string Python substitution rather than by hand (mechanical and
verifiable, rather than "trust 33 manual copy-paste edits were all
identical" - each one re-verified via `vasmm68k_mot -L`'s own listing
output afterward). This makes `lz4fast` the one backend whose flicker
granularity is per LZ4 *token*, not per byte - deliberately accepted per
`docs/format-spec.md` §8c, since token-granular flicker on a format this
fast to decode is still frequent enough in practice to read as
continuous activity.
