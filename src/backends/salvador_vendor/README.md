# Vendored Salvador compressor

Unmodified copy of [emmanuel-marty/salvador](https://github.com/emmanuel-marty/salvador)'s
core library (`src/`, minus `salvador.c` - the reference CLI, not
needed here), commit `1662b625a8dcd6f3f7e3491c88840611776533f5`
(audited 2026-09-12, see `docs/LICENSES.md` §7).

Salvador is "a free, open-source compressor for the ZX0 format" - an
alternative optimal-parse ZX0 compressor to the one vendored in
`src/backends/zx0_vendor/`, from the same author as
[unzx0_68000](../../../stubs/zx0/unzx0_68000.s). It produces the same
ZX0 v2 ("inverted") format that depacker already decodes, confirmed
directly rather than assumed: salvador's own repo bundles a copy of
`asm/68000/unzx0_68000.S` that is **byte-identical** to the one already
vendored in `stubs/zx0/` (diffed directly, commit-to-commit, before
writing any of this). No new depacker stub or backend_id needed - see
`src/backends/salvador.zig`.

`expand.c`/`expand.h` (Salvador's own ZX0 *decompressor*, not needed for
packing) are vendored anyway, specifically so `salvador.zig`'s test can
do a real compress-then-decompress round-trip through independent code,
the same rigor the zx0 backend's own test didn't have available at the
time (no host-side ZX0 decoder existed yet in this project).

## Licenses (three, all permissive - see `docs/LICENSES.md` §7 for full
text)

- Most files: zlib license (Emmanuel Marty) - same terms as
  `src/backends/zx0_vendor/` and `stubs/zx0/unzx0_68000.s`.
- `matchfinder.c`: CC0 (public domain).
- `libdivsufsort/`: MIT (Yuta Mori) - same upstream project as
  `src/backends/zultra_vendor/libdivsufsort/`, but a *different* fork:
  diffed directly and confirmed **not** byte-identical (this one keeps
  plain `malloc`/`free`, zultra's takes a `zalloc`/`zfree` allocator
  pair) - vendored separately rather than shared, to avoid mixing two
  independently-evolved copies of the same file.

No CMake step needed, same as `zultra_vendor/`:
`libdivsufsort/include/divsufsort_config.h` here is upstream's own
static, pre-filled header, not the `.cmake` template variant.
`libdivsufsort/lib/divsufsort.c` here uses a plain `#include
"divsufsort_private.h"` (not zultra's relative `"../include/..."`), so
it needs an explicit include path to `libdivsufsort/include/` - see
`build.zig`, matching upstream's own Makefile (`-Isrc/libdivsufsort/include -Isrc`).

Because `zultra_vendor/` and `salvador_vendor/` each vendor their own
full copy of upstream libdivsufsort, both define the same 12 global,
non-static C symbols (`divsufsort_init`, `divsufsort_destroy`,
`divsufsort_build_array`, `divbwt`, `divsufsort_version`,
`bw_transform`, `inverse_bw_transform`, `sufcheck`, `sa_search`,
`sa_simplesearch`, `sssort`, `trsort` - confirmed by direct inspection
of both trees' `divsufsort.c`/`divsufsort_utils.c`/`sssort.c`/`trsort.c`,
not just assumed from the shared upstream origin). Linking both
unmodified copies into one binary is a hard duplicate-symbol collision.
Fixed in `build.zig` by renaming only this copy's 12 symbols via `-D`
compiler flags (e.g. `-Ddivsufsort_init=salvador_divsufsort_init`) on
just this vendor's `addCSourceFiles` call - no source edits needed,
since salvador's own internal callers and `divsufsort_private.h`'s
extern declarations reference these names through the same
preprocessor macro expansion. This is the same rename idiom
`divsufsort_private.h` already uses on itself for a 64-bit build
variant (`#define sssort sssort64`), just applied from the build system
instead of from within the header.
