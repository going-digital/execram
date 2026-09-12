# Vendored Shrinkler compressor

Vendored from [askeksa/Shrinkler](https://github.com/askeksa/Shrinkler)'s
`cruncher/` directory, commit `17cff110fcded387fe90e632805258d9c8359e94`
(audited 2026-09-12, see `docs/LICENSES.md` §1). Not the reference CLI
(`Shrinkler.cpp`, `HunkFile.h`, `doshunks.h`, `DecrunchHeaders.h` and
its bundled `.dat`/`.bin` decrunch headers - none needed here, since
execram has its own container format and hunk parser) - just the core
LZ + adaptive range coder library, in "--data" mode (compress a raw
byte buffer, not an AmigaDOS executable): `AmigaWords.h`, `Coder.h`,
`CountingCoder.h`, `CuckooHash.h`, `Decoder.h`, `Heap.h`, `LZDecoder.h`,
`LZEncoder.h`, `LZParser.h`, `MatchFinder.h`, `Pack.h`, `RangeCoder.h`,
`RangeDecoder.h`, `SizeMeasuringCoder.h`, `SuffixArray.h`.

Shrinkler is the reference for "the Shrinkler-class backend" this whole
project was scoped around from the start (`PROJECT_PLAN.md` M4) - an
LZ77 + adaptive range coder + context modeling + optimal parser, in the
LZMA family but with its own simpler context scheme (see
`LZEncoder.h`'s own module comment for the full bit-format
description). Its depacker (`stubs/shrinkler/ShrinklerDecompress.s`) is
adapted directly from Shrinkler's own shipped, tested decrunch code,
not a clean-room reimplementation - the license audit (§1) found this
is explicitly permitted, unlike the GPL the project plan originally
(incorrectly) assumed.

## `@cImport`, not direct vendoring of C++ templates

Unlike the C backends (zx0/zultra/salvador), this is vendored C++, and
`shrinkler_shim.h`/`shrinkler_shim.cpp` (our own glue, not upstream)
expose only 3 plain C-linkage functions to `@cImport` - see
`shrinkler_shim.h`'s own comment for why: the full header chain
(`Pack.h`'s templates, `LZParser.h`'s STL containers, ...) crashed
Zig's `translate-c` (a SIGBUS in the `aro` C frontend), the same class
of problem `salvador_shim.h` hit with plain bitfield structs, just
worse here since it's real template instantiation.

Only `shrinkler_shim.cpp` is compiled (see `build.zig`) - every other
file here is header-only, `#include`d transitively through it, matching
upstream's own design (its only `.cpp` is the CLI's `Shrinkler.cpp`,
not vendored). This matters for `RangeCoder.h`'s non-inline static
member definitions (`RangeCoder::sizetable`/`sizetable_init`) - defining
those in more than one translation unit would be an ODR violation, so
there must never be a second `.cpp` in this directory.

## Deliberate changes from upstream (three, all documented at their
## exact site too - this is a summary, not the only place to look)

1. **`Pack.h`**: `packData()`'s two unconditional `printf` calls
   (status-line output, not gated by its own `show_progress` parameter)
   are removed. They wrote raw text to stdout, corrupting the same
   channel `zig build test` uses to talk to the test binary over Zig's
   `--listen=-` protocol, hanging the test runner - the exact bug class
   already hit and fixed once in this project, see
   `src/backends/zx0_vendor/optimize.c`'s own comment on the identical
   symptom in a completely different vendored library.
2. **`assert.h` renamed to `shrinkler_assert.h`** (and the three
   `#include "assert.h"` sites updated to match): upstream deliberately
   shadows the *system* `assert.h` within its own single-translation-
   unit build, which broke once this directory had to sit on the
   module's *global* include path (for `@cImport` to find
   `shrinkler_shim.h` - see above) - see `shrinkler_assert.h`'s own
   comment for the exact failure this caused in an unrelated vendored
   library (`salvador_vendor/libdivsufsort`) before the rename.
3. **`shrinkler_shim.cpp`'s own `-fno-sanitize=shift` compile flag**
   (not a source change, but adapts *how* vendored code is built):
   `RangeCoder.h`'s `dest_bit` starts at -1 and gets left-shifted on
   the very first `code()` call - implementation-defined, not
   undefined, and Shrinkler's own 20+-year shipped behavior on every
   real compiler, but Zig's Debug builds add UBSan shift-trapping to
   vendored C/C++ too, crashing on it - see `build.zig`'s own comment.

## Context-count deviation from `DataFile.h` (not a bug, see
## `shrinkler_shim.cpp`'s own comment for the full reasoning)

`shrinkler_shim.cpp` sizes the `RangeCoder`/`RangeDecoder`'s context
array as `LZEncoder::NUM_CONTEXTS` alone (1025), not upstream's own
`DataFile.h::compress()`, which always adds `NUM_RELOC_CONTEXTS` (256,
defined in the *not-vendored* `HunkFile.h`) even in `--data` mode where
no relocation contexts are ever addressed. Proven bit-for-bit
equivalent (each context's adaptive probability evolves independently
of how many other unused slots exist in the array) rather than assumed
- see the code comment for the full argument. `stubs/shrinkler`'s own
context table is sized 1536 regardless (upstream's own fixed constant,
comfortably larger than either number), so this never needed to match
anything on the depacker side either.

## Fixed compression parameters, not exposed as CLI options

`shrinkler_shim.cpp` hardcodes Shrinkler's own "-3" preset defaults
(`iterations=3, length_margin=3, skip_length=3000, match_patience=300,
max_same_length=30` - see `cruncher/Shrinkler.cpp`'s own
`DigitParameter preset` default) and parity-context enabled (Shrinkler's
own default for `--data` mode, i.e. the *absence* of its `--bytes`
flag). Both are compile-time constants, not runtime options: the
depacker stub (`stubs/shrinkler/stub.s`) bakes in the matching
parity-context choice at assembly time (`moveq #1,d7`), and there's
nowhere in execram's own container format to carry a per-file choice
that both host and depacker would need to agree on - see
`shrinkler_shim.h`'s own comment.

## License

zlib license (`Copyright (c) 1999-2022 Aske Simon Christensen`) - same
permissive terms audited in full in `docs/LICENSES.md` §1, including
the specific extra-permissive note that applies to the *depacker*
(§1b) but not this host-side compressor.
