# Vendored LZ4/LZ4HC compressor

Unmodified copy of four files from [lz4/lz4](https://github.com/lz4/lz4)'s
`lib/` (commit `0774d05537f9762f838f7ab541b7765f1a729cb5`, 2026-06-01,
audited 2026-09-16, see `docs/LICENSES.md`): `lz4.c`, `lz4.h`, `lz4hc.c`,
`lz4hc.h`. Not a full checkout: upstream's `lib/` also ships the LZ4
Frame format (`lz4frame.c`/`.h`), a file-oriented convenience API
(`lz4file.c`/`.h`), and `xxhash.c`/`.h` (only needed by the frame
format's own checksum) - none of which this project needs, since
`src/backends/lz4.zig` calls the raw block API directly and execram's
own container header already carries the compressed size a frame
header would otherwise redundantly re-encode (same reasoning as skipping
zlib/gzip framing for the DEFLATE-family backends).

## Why both `lz4.c` and `lz4hc.c`

`LZ4_compress_HC()` (the actual compressor used here, `lz4hc.c`) needs
several internal helpers from `lz4.c` (`LZ4_count`, shared constants) -
upstream's own `lz4hc.c` handles this via `#include "lz4.c"` guarded by
`LZ4_COMMONDEFS_ONLY`, pulling in only those `static`/inline helpers,
not a second copy of the real compressor/decompressor. `lz4.c` is
*also* compiled here as its own ordinary translation unit, for its
`LZ4_decompress_safe()` - used by this backend's own `decompress()`
for the pack-time host-side self-check, the same real, independently-
tested decoder every other backend's self-check uses (not a
hand-written reference decoder). This is exactly upstream's own
supported multi-file build: their `lib/Makefile` compiles `lz4.c` and
`lz4hc.c` as two independent `.c` files with no special flags, relying
on the `LZ4_COMMONDEFS_ONLY` guard's helpers being `static` (internal
linkage) to avoid any duplicate-symbol collision between the two - no
`-DLZ4_SRC_INCLUDED` or other special build flag needed, verified
directly by compiling both together.

## License

BSD 2-Clause (`LICENSE`, vendored verbatim, and repeated at the top of
each of the four files) - see `docs/LICENSES.md` for the full text
alongside this project's other vendored dependencies.
