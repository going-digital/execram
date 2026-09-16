# Vendored Zopfli compressor

Minimal subset of [google/zopfli](https://github.com/google/zopfli)
(commit `ccf9f0588d4a4509cb1040310ec122243e670ee6`, 2024-04-11, audited
2026-09-16, see `docs/LICENSES.md`) - just `libzopfli`'s core, enough
to call `ZopfliDeflate()` directly. Not a full checkout: upstream also
ships gzip/zlib container framing, `zopflipng`, and CLI programs, none
of which this project needs.

Like `zultra`, `salvador`, and `libdeflate` (see their own
`_vendor/README.md` files), Zopfli produces standard raw DEFLATE output
- exactly the format [stubs/inflate/](../../../stubs/inflate/)'s
depacker already decodes - so this needs **no new depacker stub at
all**. It plugs into the existing `inflate` backend as another
alternative host-side compressor for the exact same
container/backend_id. See `src/backends/zopfli.zig`.

This is issue #1's second suggestion for an improved DEFLATE
compressor, vendored as the original C reference implementation rather
than the `zopfli-rs` Rust port also named in that issue: `zopfli-rs` is
a plain Rust `rlib` with no C ABI, and getting one would mean a wrapper
crate, a `cargo` build step, and Rust cross-compilation added to CI for
every release target - a second toolchain this project doesn't
otherwise need. The upstream C library is the reference implementation
`zopfli-rs` itself ports, is the same permissive license, and drops
straight into the exact vendoring pattern every other backend here
already uses.

## Directory layout

Flat, not mirroring upstream's `src/zopfli/` nesting (unlike
`zultra_vendor`, nothing here does a same-directory relative
`#include "../include/..."` that would require it) - just the files
`ZopfliDeflate()` actually needs, pulled out of upstream's own
`CMakeLists.txt` `libzopfli` source list minus the container-format
files:

- `deflate.c`/`.h`, `zopfli.h` - the entry point
  (`ZopfliDeflate`/`ZopfliOptions`) and the block-level DEFLATE encoder.
- `blocksplitter.c`/`.h` - chooses block boundaries.
- `squeeze.c`/`.h`, `lz77.c`/`.h`, `cache.c`/`.h`, `hash.c`/`.h` -
  Zopfli's own iterative, cost-based "squeeze" LZ77 parse (this is the
  actual algorithm the "zopfli-like ratios" phrase in zultra's own
  README refers to).
- `tree.c`/`.h`, `katajainen.c`/`.h`, `symbols.h` - Huffman tree
  construction/length-limiting.
- `util.c`/`.h` - shared constants and `ZopfliInitOptions()`.

Not vendored: `gzip_container.c`/`.h`, `zlib_container.c`/`.h`,
`zopfli_lib.c` (gzip/zlib framing and the `ZopfliCompress()` wrapper -
`src/backends/zopfli.zig` calls `ZopfliDeflate()` directly instead,
skipping the format-dispatch layer entirely since raw DEFLATE is the
only format this project ever wants), and `zopflipng`/the CLI
`*_bin.c` files (irrelevant here).

## Modification (Apache License 2.0 SS4(b): changed files must say so)

`deflate.c`'s `PatchDistanceCodesForBuggyDecoders()` - issue #1's own
suggestion - is turned into a no-op, marked inline with a comment at
its definition. That function pads a block's distance-code Huffman
table to at least 2 entries even when the true optimum is 0 or 1,
purely to work around bugs in zlib <=1.2.1 and some old mobile phones
(see the function's own original doc comment, left intact above the
no-op). execram's own depacker isn't one of those buggy decoders, so
this workaround only ever costs bytes here for no benefit.

## License

Apache License 2.0 (`COPYING`, vendored verbatim) - see
`docs/LICENSES.md` and `THIRD_PARTY_LICENSES.md` for the full text
alongside this project's other vendored dependencies. Permissive but
not notice-free like the zlib/CC0/MIT-licensed vendors elsewhere in
this tree: redistribution must retain copyright/attribution notices
and mark modified files as changed (see "Modification" above) - the
same condition `zultra_vendor/huffman/huffutils.c` (also Apache 2.0)
already carries.
