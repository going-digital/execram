# inflate (and zultra)

Standard raw DEFLATE (RFC 1951) - no zlib or gzip wrapper, since the
depacker doesn't check a header or trailing checksum and every wrapper
byte would be pure overhead on a platform this size-conscious. Two
host-side compressors target this exact same format and share
everything else:

- **`inflate`** (`src/backends/inflate.zig`): Zig standard library's
  own `std.compress.flate.Compress` at `.level_9`. No vendored C at all
  on the host side - the only backend where that's true.
- **`zultra`** (`src/backends/zultra.zig`): a vendored, more thorough
  optimal-parse DEFLATE encoder (emmanuel-marty/zultra), usually a
  little smaller at the cost of more host-side compute. See
  `src/backends/zultra_vendor/README.md`.

Both produce bit-compatible output for the one depacker
(`stubs/inflate/`, adapted from Keir Fraser's public-domain
`inflate.S`) to decode - `backend_id` 1 covers both; the container
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
`.level_9` = maximum); `zultra` does the same job with a more
exhaustive optimal-parse search for LZ77 matches specifically, at
higher host-side compute cost, but is still bounded by DEFLATE's own
format ceiling (backref distances up to 32KB, lengths up to 258 bytes)
regardless of parse quality - see the ratio numbers in
`PROJECT_PLAN.md`'s M2/M3-adjacent sections for how that ceiling
compares against zx0/shrinkler on the same test data.

## Depacker

`stubs/inflate/inflate_core.s`, adapted from Keir Fraser's
`inflate.S` (Unlicense/public domain - `docs/LICENSES.md` §4). Needed
the one real dialect workaround in this whole project: it's written
for vasm's GNU-as-style syntax module, not the Motorola/Devpac syntax
every other stub uses - see `stubs/inflate/README.md` for exactly what
that meant for the build.
