# Vendored libdeflate compressor

Minimal subset of [ebiggers/libdeflate](https://github.com/ebiggers/libdeflate)
(commit `92e6a0db9fa848d742f9eb286c92afc60f2c3dda`, 2026-08-22, audited
2026-09-16, see `docs/LICENSES.md`), just enough to call
`libdeflate_deflate_compress()` at its highest compression level. Not a
full checkout: upstream also ships zlib/gzip framing,
decompression, and CLI programs, none of which this project needs -
see "Directory layout" below for exactly what was pulled and why.

Like `zultra` and `salvador` (see their own `_vendor/README.md`
files), libdeflate produces standard raw DEFLATE output - exactly the
format [stubs/inflate/](../../../stubs/inflate/)'s depacker already
decodes - so this needs **no new depacker stub at all**. It plugs into
the existing `inflate` backend as another alternative host-side
compressor for the exact same container/backend_id. See
`src/backends/libdeflate.zig`.

## Directory layout

Mirrors upstream's own tree (just a subset of it), so upstream's
relative `#include`s resolve unmodified:

- `libdeflate.h`, `common_defs.h` - top-level public header and shared
  compiler/platform macros.
- `lib/deflate_compress.c` (+ its own `.h`/constants) - the actual
  encoder. This is the only thing this vendor tree exists for.
- `lib/hc_matchfinder.h`, `lib/ht_matchfinder.h`, `lib/bt_matchfinder.h`,
  `lib/matchfinder_common.h` - the match-finders `deflate_compress.c`
  includes directly (hash-chain, hash table, and binary-tree, the last
  needed because upstream's `SUPPORT_NEAR_OPTIMAL_PARSING` is
  unconditionally on - see that file's own `#define`).
- `lib/lib_common.h`, `lib/cpu_features_common.h`, `lib/utils.c` -
  shared helpers `deflate_compress.c` and the matchfinders pull in.
- `lib/x86/`, `lib/arm/` (`cpu_features.{c,h}`, `matchfinder_impl.h`) -
  runtime SIMD dispatch for the matchfinders' `matchfinder_rebase()`.
  Both are compiled unconditionally on every target, exactly like
  upstream's own `CMakeLists.txt` does (`LIB_SOURCES` there lists both
  `lib/arm/cpu_features.c` and `lib/x86/cpu_features.c` regardless of
  build target) - each guards its own body behind
  `X86_CPU_FEATURES_KNOWN`/`ARM_CPU_FEATURES_KNOWN`, compiling to
  nothing on the arch it doesn't apply to. `lib/riscv/` isn't vendored:
  not one of this project's release targets (see top-level README's
  Building section).

Not vendored: `lib/adler32*.c`, `lib/crc32*.c`, `lib/zlib_*.c`,
`lib/gzip_*.c`, `lib/deflate_decompress.c`, `lib/decompress_template.h`
(zlib/gzip framing and every decompression path - this backend only
ever calls the compressor, and reuses `inflate.zig`'s own Zig decoder
for the self-check/round-trip, same as `zultra`/`salvador`), and
`programs/` (upstream's own CLI, irrelevant here).

## License

MIT (`COPYING`, vendored verbatim) - see `docs/LICENSES.md` for the
full text alongside this project's other vendored dependencies.
