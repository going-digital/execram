# Vendored Zultra compressor

Unmodified copy of [emmanuel-marty/zultra](https://github.com/emmanuel-marty/zultra)'s
core library (`src/`, minus `tool/` - the reference CLI and its bundled
zlib, neither needed here), commit
`5490882fd561a8eae93c8004a46d11e641e46a0b` (audited 2026-09-12, see
`docs/LICENSES.md` §6).

Zultra is "a fast deflate implementation with zopfli-like ratios" - a
much stronger DEFLATE *encoder* than a naive one (closer to zopfli's
exhaustive-search ratios, at more practical speed), producing standard
raw DEFLATE output. Since that's exactly the format
[stubs/inflate/](../../../stubs/inflate/)'s depacker already decodes,
this needs **no new depacker stub at all** - it plugs into the existing
`inflate` backend as an alternative, better host-side compressor for
the exact same container/backend_id. See `src/backends/zultra.zig`.

## Directory layout

Mirrors upstream's `src/` tree exactly (`libdivsufsort/lib/divsufsort.c`
uses a relative `#include "../include/..."`, so the nesting matters, not
just which files are present).

## Licenses (three, all permissive - see `docs/LICENSES.md` §6 for the
full text of each)

- Most files: zlib license (Emmanuel Marty) - same terms as
  `stubs/zx0/unzx0_68000.s`.
- `matchfinder.c`: CC0 (public domain).
- `huffman/huffutils.c`: Apache License 2.0.
- `libdivsufsort/`: MIT (Yuta Mori) - a separate upstream project
  vendored inside zultra.

No CMake step needed: `libdivsufsort/include/divsufsort_config.h` here
is upstream's own static, pre-filled header (not the `.cmake` template
variant, which isn't vendored), with sane defaults for any modern
Unix-like target - confirmed by compiling the whole thing with a plain
`cc -Isrc` before wiring it into `build.zig`, matching how upstream's
own plain Makefile builds it.
