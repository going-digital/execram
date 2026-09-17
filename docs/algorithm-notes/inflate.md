# inflate (and zultra, libdeflate, zopfli)

Standard raw DEFLATE (RFC 1951) - no zlib or gzip wrapper, since the
depacker doesn't check a header or trailing checksum and every wrapper
byte would be pure overhead on a platform this size-conscious. Four
host-side compressors target this exact same format and share
everything else:

- **`inflate`** (`src/backends/inflate.zig`): Zig standard library's
  own `std.compress.flate.Compress` at `.level_9`. No vendored C at all
  on the host side - the only backend where that's true.
- **`zultra`** (`src/backends/zultra.zig`): a vendored, more thorough
  optimal-parse DEFLATE encoder (emmanuel-marty/zultra), usually a
  little smaller at the cost of more host-side compute. See
  `src/backends/zultra_vendor/README.md`.
- **`libdeflate`** (`src/backends/libdeflate.zig`): a vendored,
  near-optimal-parse DEFLATE encoder (ebiggers/libdeflate) at its own
  maximum compression level - measured close behind `zultra` on the
  project's own corpus (within ~0.5%), ahead of plain `inflate`. See
  `src/backends/libdeflate_vendor/README.md`.
- **`zopfli`** (`src/backends/zopfli.zig`): a vendored, iterative
  cost-based "squeeze" LZ77 parser (google/zopfli) - the original
  reference algorithm `zultra` and `libdeflate`'s own near-optimal
  parsers are inspired by/compared against. Measured a statistical tie
  with `zultra` on the project's own corpus (each wins on one of two
  test files, by tens of bytes), both ahead of `libdeflate`. See
  `src/backends/zopfli_vendor/README.md`.

All four produce bit-compatible output for the one depacker
(`stubs/inflate/`, adapted from Keir Fraser's public-domain
`inflate.S`) to decode - `backend_id` 1 covers all four; the container
format has no way to tell which one produced a given file, nor any
need to.

## Format, in brief

DEFLATE represents data as a sequence of blocks, each either stored
literally or Huffman-coded. Compressed blocks use two intertwined
techniques:

- **LZ77 back-references**: a (length, distance) pair meaning "copy
  `length` bytes from `distance` bytes back in the already-decoded
  output" - the mechanism that actually finds and exploits repeated
  data.
- **Huffman coding**: literal bytes, lengths, and distances are each
  encoded with a variable-length prefix code favoring common symbols,
  either a fixed table (fast, "static" blocks) or one built specifically
  for that block's own symbol frequencies ("dynamic" blocks, more
  overhead per block but better-fitted codes).

`inflate`'s only real choice is compression level (search effort,
`.level_9` = maximum); `zultra`, `libdeflate`, and `zopfli` do the same
job with a more exhaustive (near-)optimal-parse search for LZ77
matches specifically, at higher host-side compute cost, but are still
bounded by DEFLATE's own format ceiling (backref distances up to 32KB,
lengths up to 258 bytes) regardless of parse quality - see the ratio
numbers in `PROJECT_PLAN.md`'s M2/M3-adjacent sections for how that
ceiling compares against zx0/shrinkler on the same test data.

## Depacker

`stubs/inflate/inflate_core.s`, adapted from Keir Fraser's
`inflate.S` (Unlicense/public domain - `docs/LICENSES.md` §4). Needed
the one real dialect workaround in this whole project: it's written
for vasm's GNU-as-style syntax module, not the Motorola/Devpac syntax
every other stub uses - see `stubs/inflate/README.md` for exactly what
that meant for the build.

## In-loop decompression flicker

The trickiest register story of any backend (`docs/format-spec.md`
§8c): `inflate_core.s`'s own `build_code` subroutine (called twice, once
each for the literal/length and distance Huffman tables) clobbers A3,
the register every other backend's flash stub sets up once at the very
top of `Depack:` - so `stubs/inflate/inflate_core_flash.s` instead sets
up A3 *after both* `build_code` calls finish, right before
`decode_loop:` starts. That leaves a gap between where `FLAG_KILLTWITCH`
needs to be read (via A2, before `stubs/inflate/stub_flash.s`'s own
`Depack:` overwrites A2 with `AllocMem`'s scratch pointer a few
instructions in) and where it's actually needed (after `build_code`):
the wrapper caches it into D7 immediately after the routine's own
`movem.l d2-d7/a2-a6,-(sp)` - not before, which would save *this* code's
own D7 instead of the real caller's, violating `Depack`'s "preserves
D2-D7/A2-A6" contract - and D7 survives unclobbered across both
`build_code` calls since that routine already saves/restores all of
D0-D7 around its own body. The poke itself (`move.w d0,(a3)`) lands
right after `decode_loop`'s own `move.b d0,(a4)+`, flickering on every
decoded literal byte.
