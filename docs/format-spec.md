# execram container format — v0

**Status:** shipped as of v1.0. All six backends (store, inflate, zultra,
zx0, salvador, shrinkler) implement this exact format, verified against
real emulated 68k hardware (`tests/uae/`) as well as host-side unit
tests. §9's versioning policy is now live: a change to anything a stub
*must* understand needs a `version_major` bump, not a silent edit here.

Post-v1.0, §2's on-disk shape and §8's runtime algorithm were revised
(the two-hunk, free-the-scratch-hunk redesign - `docs/memory-lifecycle.md`)
without a `version_major` bump: §3's 32-byte header layout, the actual
thing a stub must understand per §9's own policy, did not change at all -
only the outer container shape and the runtime code around it did, and
execram always produces files with whatever stub its current build
embeds, so there's no old-file/new-reader compatibility question the
policy exists to guard.

Also post-v1.0: a seventh and eighth backend, `libdeflate` and
`zopfli`, were added reusing `backend_id` 1 (§4) and the existing
`inflate` stub unmodified - same "no format or stub change" shape as
`zultra`/`salvador` above, so no `version_major` bump here either. See
`PROJECT_PLAN.md`'s libdeflate/Zopfli entries for their real-hardware
verification status.

Also post-v1.0: `lz4small`/`lz4normal`/`lz4fast`, three genuinely new
depacker stubs sharing one host-side LZ4HC encoder, added as
`backend_id` 4/5/6 (§4) - purely additive (new enum values, `_` catch-
all in `src/container.zig`'s `BackendId`), so still no `version_major`
bump. See `PROJECT_PLAN.md`'s LZ4 entry.

Also post-v1.0: `zx0fast`/`salvadorfast`, a new depacker stub
(`backend_id` 7, §4) reusing `zx0`/`salvador`'s exact host encoders -
same additive shape as above, no `version_major` bump. See
`PROJECT_PLAN.md`'s zx0fast entry.

## 1. Two-layer model

execram deliberately separates two concerns that Shrinkler couples
together:

- **Compression** is a backend's problem: given N bytes, produce a
  compressed blob a matching depacker stub can turn back into exactly
  those N bytes. A backend knows nothing about hunks, relocations, or
  BSS — it's a pure byte-stream (de)compressor.
- **Relocation and layout** (flattening multiple hunks into one image,
  encoding which longwords need runtime base-address fixups, splitting
  out BSS so it's never compressed) is execram's own concern, implemented
  once, shared by every backend.

This costs a little ratio versus Shrinkler's approach of modeling
relocation bits jointly with the LZ stream's own context model — but it
means adding a fifth backend later never touches relocation or hunk
handling, and a bug in relocation fixup is one bug, not one per backend.
See [PROJECT_PLAN.md](../PROJECT_PLAN.md) §4 for the resulting build-time
architecture (host tool assembles this container; `stubs/common/` will
hold the shared reloc-fixup routine every backend's stub calls into).

## 2. On-disk shape

A packed executable is a **two**-hunk AmigaDOS load file (see
[docs/memory-lifecycle.md](memory-lifecycle.md) for why: hunk 1 is scratch
space the stub frees once decompression finishes, rather than a whole
hunk that stays resident for the process's entire life):

```
HUNK_HEADER   two hunks:
                hunk 0: size = the resident image's own allocation size
                        (§8 - code_data_size + max(bss_size,
                        reloc_stream_size), rounded up to a longword),
                        MEMF_CHIP requested iff header.flags bit 0 is set
                hunk 1: size = ceil((stub code ++ execram header ++
                        compressed payload) / 4) longwords, always
                        MEMF_ANY regardless of hunk 0's own memory type
                        (it's freed long before anything would need it
                        to be addressable from Chip-RAM-only DMA)
HUNK_CODE     hunk 0's body: stubs/common/trampoline.s, a small, fixed,
              backend-agnostic binary - AmigaDOS's LoadSeg jumps here
              directly. Far smaller than hunk 0's own declared size; the
              rest is uninitialized until hunk 1's stub decompresses
              into it (§8) - legal (confirmed against real hardware,
              see §8's own ABI note), not a hunk-format quirk.
HUNK_END
HUNK_CODE     hunk 1's body: stub code ++ execram header ++ compressed
              payload (padded to a longword boundary)
HUNK_END
```

No `HUNK_RELOC32` at all: both hunks are pure position-independent code
(PC-relative branches/references only; the only absolute addresses either
uses are genuine fixed hardware register addresses, e.g. the custom chip
base at `$dff000`, which are not relocatable program addresses). This was
proven out in the `tests/uae` boot-block stub — see
[sentinel.s](../tests/uae/boot/sentinel.s).

The **execram header is not part of the assembled stub binary** - it lives
in hunk 1, right after the stub's own code. The stub is a fixed,
pre-assembled blob embedded into the host tool at Zig-build time (see
`build.zig`) and reused unchanged across every packed output — so
per-file parameters (sizes, backend choice, ...) can never be patched
into stub instructions the way a per-file-assembled stub could. Instead
they're *data* the stub reads at runtime, exactly like Shrinkler's own
`ShrinklerDecompress.S` reads its `shr_*` header fields (see
`docs/LICENSES.md` §1b for that reference). The host tool's job when
producing hunk 1 is: `stub_bytes ++ header_bytes ++ payload_bytes`,
contiguous, with the stub locating the header via a PC-relative reference
to a label at the very end of its own code — so the assembled stub
binary's length **is** the header's offset within hunk 1, by
construction. Hunk 0's own trampoline needs no such lookup: it carries no
header-aware logic at all (§8).

This is the shape the disjoint layout (`flags` bit 3 clear) always
produces. §8b describes the opt-in overlap layout, which changes both
hunks' own sizes and contents (the compressed payload moves into hunk 0's
own on-disk body, at a computed tail offset, instead of trailing hunk 1)
but keeps this same two-hunk shape and the same trampoline/`Start:`
mechanics otherwise.

## 3. Header layout

All multi-byte fields are big-endian (native 68k byte order). All 4-byte
fields start at a 4-byte-aligned offset.

| Offset | Size | Field               | Meaning |
|-------:|-----:|----------------------|---------|
| 0      | 4    | `magic`              | ASCII `"ExCr"` |
| 4      | 1    | `version_major`       | Header layout version. A stub refuses to run a header with a newer major than it was built for. |
| 5      | 1    | `version_minor`       | Bumped for additive, backward-compatible changes (e.g. a new reserved flag bit gaining meaning). Informational only; stubs don't need to check it. |
| 6      | 1    | `backend_id`          | See §4 registry. |
| 7      | 1    | `flags`               | Bitfield, see §5. |
| 8      | 2    | `header_size`         | Total bytes of this header. The stub always uses this field to find where the payload starts — never a hardcoded constant — so a later version can grow the header and old stubs (that don't need the new fields) still skip it correctly. |
| 10     | 2    | *(reserved)*          | Must be 0. Padding to keep the fields below 4-byte-aligned. |
| 12     | 4    | `code_data_size`      | Bytes of decompressed code+data (everything except BSS). |
| 16     | 4    | `bss_size`            | Zero-filled bytes appended immediately after `code_data_size` in the final resident image. **Not present in the compressed payload** — BSS is pure zeros, compressing and decompressing it would waste time and (a little) space for nothing. |
| 20     | 4    | `reloc_stream_size`   | Bytes of the reloc stream (§6), 0 if `flags` bit 1 is clear. |
| 24     | 4    | `compressed_size`     | Bytes of the compressed payload. Disjoint layout (`flags` bit 3 clear, §8): immediately follows this header, in this same hunk. Overlap layout (bit 3 set, §8b): lives in hunk 0 instead, at a computed tail offset - this field is still what the stub reads to know how many bytes that payload is, just not where to find it directly. |
| 28     | 4    | `safety_margin`       | 0 unless `flags` bit 3 (`FLAG_OVERLAP`, §5) is set. When set, the minimum gap in bytes the compressed payload must lead the decompression output by for `Depack` to run safely sharing hunk 0 (§8b's overlap runtime algorithm) — measured per-file at pack time (`src/musashi_bench.zig`'s `measureOverlapMargin`), not a fixed per-backend constant. Read directly by `OverlapPayloadOffset` (§8b) as one input to recomputing the payload's own position - unused by the disjoint layout. |
| 32     | 4    | `trampoline_size`     | Bytes of `stubs/common/trampoline.s`'s own assembled body - the same fixed, backend-agnostic value for every file a given execram build produces. Written unconditionally regardless of layout; only `OverlapPayloadOffset` (§8b) reads it, to know how much of hunk 0's own on-disk body the trampoline itself needs before the payload can start. |

Header size in v0: 36 bytes (32 through the format's first release; grown
by 4 for `trampoline_size` when the overlap layout, §8b, was added - see
`header_size`'s own row above for why a stub never needs a hardcoded
constant to find the payload despite this).

The **resident image size** (what the running program itself actually
uses) is `code_data_size + bss_size`, computed, not stored — there's no
field for it. This is *not* the same number as hunk 0's own declared/
allocated size (§2, §8), which must additionally cover
`reloc_stream_size` when that's larger than `bss_size` (Depack writes
`code_data_size + reloc_stream_size` bytes into hunk 0, before BSS is
re-cleared over the same trailing region) — the difference, if any, is
harmless trailing padding within hunk 0's own memory, never read by the
running program.

By convention, **the flattened program's entry point is always offset 0**
of the resident image. `flatten.zig` (M1) must guarantee this; there's no
`entry_offset` field because there's nothing for it to vary.

## 4. `backend_id` registry

| Value | Backend | Milestone |
|------:|---------|-----------|
| 0     | store (no compression) | M1 |
| 1     | inflate (DEFLATE) | M2 (also used by the `zultra`, `libdeflate`, and `zopfli` CLI backends - alternative, stronger DEFLATE *encoders* producing the same format for the same depacker; there's no separate entry for any of them here because the container/stub don't need one) |
| 2     | zx0 | M3 (also used by the `salvador` CLI backend - an alternative, optimal-parse ZX0 *encoder* producing the same format for the same depacker; there's no separate `salvador` entry here for the same reason there's no separate `zultra` entry above) |
| 3     | shrinkler-class | M4 |
| 4     | lz4 (smallest depacker) | post-v1.1.0 (`lz4small` CLI backend) |
| 5     | lz4 (normal depacker) | post-v1.1.0 (`lz4normal` CLI backend) |
| 6     | lz4 (fastest depacker) | post-v1.1.0 (`lz4fast` CLI backend) - all three share one host-side LZ4HC encoder (identical payload bytes) but each embeds a genuinely different depacker stub, unlike every entry above, hence one ID per stub rather than one shared ID |
| 7     | zx0-compatible, fast depacker | post-v1.1.0 (`zx0fast`/`salvadorfast` CLI backends) - same two host encoders as `zx0`/`salvador` (2), a different (Chris Hodges/Platon42's) depacker stub, same reasoning as 4-6 above |
| 8-254 | reserved for future backends | |
| 255   | invalid / never emitted | tooling sentinel |

## 5. `flags` bitfield

| Bit | Name | Meaning when set |
|----:|------|-------------------|
| 0   | `MEM_CHIP` | Allocate hunk 0 (the resident image, §2) in Chip RAM (`MEMF_CHIP`). Clear means `MEMF_ANY` — a binary choice, decided by `execram pack` from the original executable's own hunk memory attributes (any hunk requesting Chip RAM sets it for the whole merged image) and overridable via `--mem=chip\|fast` (`src/main.zig`, `container.zig`'s `mem_chip` field). Only hunk 0 is affected either way — hunk 1 (the scratch stub+header+payload hunk) is always plain `MEMF_ANY`, regardless of this bit, since it's freed long before decompression is done and never needs Chip-RAM addressability itself. |
| 1   | `HAS_RELOCS` | A reloc stream follows the code+data in the decompressed payload (§6). If clear, `reloc_stream_size` must be 0 and the fixup pass is skipped entirely. |
| 2   | `FLASH` | Purely informational — carries no runtime meaning of its own and nothing branches on it. When set, the packed file's embedded `Depack:` is the backend's own flash-instrumented stub (`stubs/*/stub_*_flash.s`, §8c below), which writes changing data to `COLOR19` (or `COLOR00` if `FLAG_KILLTWITCH` is also set) on every iteration of its hot decode loop — a visible, continuously-updating "still alive" indicator for slow backends on real hardware, where a large file can otherwise sit at a blank screen for tens of seconds with no sign the machine hasn't hung. This bit only affects `execram info`'s own reporting; which stub a packed file actually contains is decided once, at pack time, by which binary `execram pack` chose to embed. Set by `execram pack --flash=on\|auto` when the chosen backend has a flash-instrumented stub (every backend does — §8c). |
| 3   | `OVERLAP` | True overlap-in-place decompression (§8b): still §2's ordinary two-hunk load file, but the compressed payload lives at a computed tail offset within hunk 0 itself (the resident image) instead of right after the header in hunk 1 (which is still present, still freed after use, just much smaller without the payload), and `safety_margin` above is a real, meaningful value instead of the always-0 it is when this bit is clear. Set by `execram pack --overlap=on\|auto` when the chosen backend supports the overlap layout (every backend does — §8b). |
| 4   | `KILLTWITCH` | Only meaningful when `FLAG_FLASH` (bit 2) is also set — meaningless (and never set) otherwise. When set, the flash-instrumented stub's poke target is `COLOR00` ($dff180, the border/background register) instead of `COLOR19` ($dff1a6, the mouse pointer sprite's own middle colour — the default), for programs that already use the pointer sprite for something else during decompression. Like `FLASH` itself, purely informational — the actual target address was baked into the embedded stub at pack time (read once from this same bit, before it's overwritten — see each backend's own `stub_*_flash.s`). Set by `execram pack --flash=on\|auto --killtwitch`. |
| 5-7 | *(reserved)* | Must be 0 in v0. A stub must ignore reserved bits it doesn't understand rather than reject the file — only a `version_major` bump means "you must understand this to run me correctly." |

**Known limitation, inherited from flattening multiple hunks into one:**
if the original program had some hunks that needed Chip RAM and others
that didn't, that distinction is lost — the whole merged image gets one
memory-type decision. This is the same trade-off Shrinkler's own hunk
merging makes; it's a listed non-goal to preserve in
[PROJECT_PLAN.md](../PROJECT_PLAN.md) §2, not an oversight here.

## 6. Decompressed payload contract

A backend decompresses `compressed_size` bytes of input into exactly
`code_data_size + reloc_stream_size` bytes of output, as one contiguous
stream, with **no knowledge of the split** between the two:

```
[ code_data_size bytes: the flattened code+data image ]
[ reloc_stream_size bytes: the reloc stream, consumed once and then dead ]
```

BSS is never in this stream (§3). Relocation sites only ever fall within
the `code_data_size` region — a relocation's whole purpose is "patch this
longword to contain a runtime address," and BSS by definition holds no
initial values to patch, only zeros, so it's never a relocation target on
real Amiga executables either.

## 7. Reloc stream encoding (v0, least settled part of this spec)

Each entry names one longword offset (into the `code_data_size` region)
whose current value must have the resident image's runtime base address
added to it. All such offsets are guaranteed even (68000 word/long
accesses must be at even addresses), so a stream stores `offset / 2`
deltas from the previous entry (ascending order), byte-oriented for a
simple first 68k decoder — no bit-packing in v0:

- `0x00`-`0xFD`: literal small delta (`offset/2` since the previous entry,
  0 for the very first entry).
- `0xFE`: end of stream.
- `0xFF` followed by a big-endian 4-byte longword: an escape for a delta
  that doesn't fit in a byte.

This trades some density against Shrinkler's approach of modeling reloc
bits jointly with the LZ context model — acceptable for v0 given §1's
rationale, and revisit once M1 has real reloc-count data from actual
executables to check whether it matters in practice.

## 8. Runtime algorithm

See [docs/memory-lifecycle.md](memory-lifecycle.md) for a phase-by-phase
account of what's resident in memory and where, complementing the
step-by-step algorithm below, and for the full history of how this
design reached its current shape.

The stub is split across both hunks (§2). **AmigaDOS's `LoadSeg` jumps
straight into hunk 0** - `stubs/common/trampoline.s`, identical for every
backend:

1. Compute its own runtime address via a PC-relative reference (this
   *is* hunk 0's own data start - call it `final`, since it's also where
   the resident image ends up and the eventual entry point). No header
   lookup, no backend awareness needed here at all.
2. Read the longword at `final - 4` (hunk 0's own chain-pointer field,
   written by `LoadSeg` - see the ABI note below), left-shift it by 2 to
   undo its BCPL encoding, and jump to that address **+ 4** - hunk 1's
   own data start.

Control now reaches hunk 1's code (`stubs/common/runtime.i`'s `Start:`,
or `stubs/inflate/runtime_std.i`'s for inflate/zultra), with `final`
(hunk 0's base) already in a register:

3. Locate the header via a PC-relative reference to the label right
   after hunk 1's own stub code (§2). Check `magic` and `version_major`;
   if either is wrong, there's nothing sensible to do (v0 doesn't define
   recovery behavior — there's only one major version so far).
4. No allocation: `final` already points at hunk 0's own memory,
   sized and typed by `LoadSeg` itself before any of this ran (§2).
5. Call the backend's depack routine: input = the compressed payload
   (in hunk 1, right after the header), output = `final`, directly.
   This is the only backend-specific step.
6. If `flags` bit 1 is set, walk the reloc stream (the trailing
   `reloc_stream_size` bytes of `final`, right after `code_data_size`)
   and, for each decoded offset, add `final`'s runtime address to the
   longword at `final + offset`.
7. Clear `final[code_data_size .. code_data_size + bss_size]` again,
   unconditionally. Step 5 wrote `code_data_size + reloc_stream_size`
   bytes there (code_data followed by the reloc stream, if any), which
   only fills that region with zero when `reloc_stream_size >=
   bss_size` — whenever the reloc stream is the *shorter* of the two
   (the common case), its tail leaves leftover reloc-stream bytes sitting
   where the program's BSS needs to be all-zero at entry. `bss_size` is
   always a multiple of 4 (hunk sizes are stored in longwords), so this
   is a plain longword-clear loop.
8. Detach hunk 1 from hunk 0's own chain-pointer field (`clr.l` it, so
   `LoadSeg`'s bookkeeping doesn't try to free hunk 1 a second time at
   process exit), then `FreeMem` hunk 1 - its own total size, recorded
   at *its* data-start-minus-8 by `LoadSeg`, is read back directly, no
   separate size tracking needed.
9. Jump to `final + 0`.

**ABI this depends on** (confirmed empirically under real FS-UAE across
Kickstart v1.3 r34.005/v2.05 r37.350/v3.1 r40.063, not assumed from
documentation - see the commit that introduced this design for the probe
and raw results): every hunk `LoadSeg` loads carries an 8-byte header
immediately before its own data - that hunk's own total `AllocMem`'d size
in bytes (already including this 8-byte header, exactly what `FreeMem`
needs) at `data_start - 8`, and a BCPL-shifted pointer to the next hunk's
own "+4" field (0 if none) at `data_start - 4`.

Hunk 0's own declared/allocated size (§2, §3) must be
`code_data_size + max(bss_size, reloc_stream_size)`, not just
`code_data_size + bss_size` - step 5 writes the larger of the two into
`final`'s tail, and undersizing the allocation lets it overflow into
whatever comes right after hunk 0 in memory (hunk 1, until step 8 frees
it - a real bug once, caught only by a synthetic test program whose
`reloc_stream_size` happened to exceed its `bss_size`, since every real
executable tried before it had `bss_size` dominate and masked the
overflow completely).

This is `execram pack`'s **default** layout - it isn't full in-place/
overlapping decompression the way Shrinkler's own `OverlapHeader.S` does
it (compressed and decompressed data sharing even the *same* bytes,
needing a backend-specific worst-case expansion bound to prove it's
always safe). Hunk 1 (still holding the compressed payload) and `final`
(hunk 0) are always two disjoint memory regions; Depack reads from one
and writes to the other, never overlapping. §8b below covers the
opt-in alternative that does overlap.

## 8b. Overlap-mode runtime algorithm (`FLAG_OVERLAP`)

`execram pack --overlap=on|auto` still produces §2's ordinary **two**-hunk
load file - same `writeHunkExecutable`, same trampoline, same
`stubs/common/runtime.i` `Start:` label every backend's stub already
shares. What differs is only
*where the compressed payload lives* and *what each hunk's own body
contains*:

- **Hunk 0** (`final`, the resident image): on disk, `trampoline.s`'s own
  tiny body, then zero padding, then the compressed payload itself -
  positioned at a computed tail offset (`payload_offset`) instead of hunk
  0 being otherwise empty past the trampoline. `LoadSeg` loads this
  exactly like any other hunk 0 (§8's own step 0-1): the payload simply
  ends up sitting at `payload_offset` because that's where the on-disk
  bytes put it, with no runtime repositioning needed at all.
- **Hunk 1** (the scratch hunk, still freed after use exactly as §8
  describes): `stub_bytes ++ header` only - no payload appended this
  time, so it's now typically only a few hundred bytes instead of
  carrying the whole compressed payload.

This shape is deliberately *not* what an earlier version of this design
tried (compressed payload and depacker code sharing a single hunk,
decompression output overwriting the depacker's own executing
instructions) - a genuine self-modifying-code bug caught by real-hardware
boot testing, not host-side unit tests, since those never actually
execute the assembled stub against realistically-shaped memory. Keeping
the depacker's own code in hunk 1 (never touched by `Depack`'s own
output) is what makes this safe: the two hunks stay genuinely disjoint
regions exactly as in §8, `Depack` overlapping only with *itself* (its
own input and output both living inside hunk 0), never with the code
that's actively running it.

The only step of §8's own algorithm that changes at all is how `Depack`'s
own input pointer (A0) is found - `stubs/common/runtime.i`'s `Start:`
branches on `FLAG_OVERLAP` right there and nowhere else:

- **Disjoint** (flag clear, §8's own behavior): `A0 = header_base +
  header_size` - the payload right after the header, both within hunk 1.
- **Overlap** (flag set): `A0 = final + payload_offset`, computed by a
  small subroutine (`OverlapPayloadOffset`) entirely from header fields
  already read on real hardware by the disjoint layout's own passing
  boot tests (`code_data_size`, `bss_size`, `reloc_stream_size`,
  `compressed_size`, `safety_margin`, and `trampoline_size` - §3's newest
  field, needed because hunk 0's own on-disk body must have room for the
  trampoline *before* the payload) - reproducing exactly the same
  `overlapAllocatedSize` formula `src/container.zig` used to place the
  payload on disk in the first place, so the two computations can never
  drift apart. `align4(compressed_size)`, not the raw value, is used
  throughout that formula: `payload_offset` must land on a 4-byte
  boundary or a backend whose `Depack:` does any word/long access via A0
  (store's own bulk `move.l (a0)+,(a1)+` copy loop, e.g.) hits a genuine
  68000 Address Error the moment `compressed_size` happens to be odd -
  found on real hardware before this rounding was added.

Every other step - `RelocFixup`, the BSS re-clear, detaching and
`FreeMem`-ing hunk 1, the final `jmp final+0` - is **identical** between
the two modes, reading the header directly exactly as §8 already
describes: nothing about the header's own safety changes, since hunk 1
(where it lives) is never written by `Depack` in either mode.

**Margin measurement**: `safety_margin` (§3) - the minimum gap
`payload_offset` must leave ahead of the output's own write position -
is measured empirically per file at pack time
(`src/musashi_bench.zig`'s `measureOverlapMargin`, run inside
`compressWithBackend` for every backend that supports the overlap
layout), the same approach Shrinkler's own `--overlap` mode uses
(`HunkFile.h`'s `verify()`, `docs/memory-lifecycle.md`'s Comparison
section) - not a fixed per-backend theoretical formula. `execram pack
--overlap=auto` (the default) then compares both layouts' real peak
memory footprint for this specific file (hunk 0 + hunk 1, both resident
simultaneously during decompression in either layout) and picks
whichever is smaller; small payloads, or backends like `store` that
never actually shrink the input, often keep using the disjoint layout,
since the overlap layout's own on-disk-fit and alignment overhead can
outweigh its savings there.

## 8c. In-loop decompression flicker (`FLAG_FLASH`/`FLAG_KILLTWITCH`)

An earlier design poked `COLOR00` to a fixed bright colour once, right
before `Depack:` was called, and restored it once right after - a static
"something is happening" indicator with no way to show the machine is
*still* alive partway through a long decompression (Shrinkler on a large
file can take tens of seconds of real 68000 time - see `execram bench`).
The current design instead writes changing data to a hardware colour
register on every iteration of the chosen backend's own hot decode loop,
so the flicker itself tracks real progress instead of just marking the
start and end.

**Dual stub, not a runtime branch.** Unlike `FLAG_OVERLAP` (§8b), which
branches once per `Depack` call inside the shared `stubs/common/
runtime.i`, the flicker poke sits inside a loop that can run from tens of
thousands to millions of times per decompression - a shared-stub runtime
branch would cost every packed file a few cycles per *iteration* even
with flashing disabled, not once per decompression the way `--overlap`'s
branch does. Instead, each backend ships **two independently-assembled
stubs**: its ordinary one (`stubs/<backend>/stub.s` et al.) and a
flash-instrumented sibling (`stubs/<backend>/stub_*_flash.s`, and for
inflate/zx0-family/shrinkler/lz4-family, a matching flash-instrumented
copy of their own core decode file) with the poke permanently baked into
the loop body - zero cost when off, since the plain stub simply doesn't
contain the instruction at all. `execram pack` embeds whichever binary
matches its `--flash` decision (below); `FLAG_FLASH`/`FLAG_KILLTWITCH`
themselves carry no runtime meaning at all (§5) - they exist purely so
`execram info` can report what a given packed file contains.

**Target register.** Every flash stub writes `move.w` (word - Amiga
custom chip registers are unreliable on byte-sized writes) to one of two
hardware colour registers, chosen once, at the very start of the
flash-instrumented `Depack:`, by reading `FLAG_KILLTWITCH` from the
header (still valid via A2 at that point, before any backend repurposes
it) into whichever register the backend's own register-liveness analysis
found free:

- **Default (`FLAG_KILLTWITCH` clear): `COLOR19`** ($dff1a6) - the mouse
  pointer sprite's own middle colour, a well-known cruncher trick: it
  flickers visibly even with no real pointer sprite active, without
  disturbing the screen's own background/border.
- **`--killtwitch` (`FLAG_KILLTWITCH` set): `COLOR00`** ($dff180) - the
  background/border register instead, for programs that already use the
  pointer sprite for something else during decompression.

The value written doesn't matter - each backend simply reuses whatever
register already holds live, changing decode state at the poke point
(a decoded literal byte, a loop counter, ...), so the poke costs one
instruction and no extra register pressure.

**Per-backend granularity.** Every backend pokes on (at least) its own
per-byte copy loop, with two accepted exceptions where a byte-granular
poke isn't possible without either corrupting the algorithm or requiring
disproportionate duplication:

- **lz4fast** has no shared copy loop at all - it's fully unrolled via a
  256-entry jump table into hand-duplicated `move.b` chains, several of
  which the jump table itself enters at fixed mid-block byte offsets
  (`sl_sm0+4`, `sl_sm0+2`, ...) that a poke inside the copy chain would
  silently shift and break. Its poke instead lives in the 5-instruction
  per-token dispatch trampoline that recurs identically after every
  block (33 sites, mechanically duplicated) - so lz4fast flickers once
  per LZ4 *token*, not once per byte.
- **lz4normal**'s counted `.litcopy`/`.copy` loops (used for runs of 15+
  literal/match bytes within one token) are instrumented, but its
  hand-unrolled short-run paths (under 15 bytes - the common case) are
  not, for the same "don't touch a fixed-offset-addressed unrolled
  block" reason as lz4fast; every token long enough to overflow into the
  counted loop still flickers.

Every other backend (store, inflate, zx0, zx0fast, shrinkler, lz4small)
pokes on every single decoded byte.

**Register liveness was verified directly against each backend's own
source**, not assumed from a shared table - register liveness at a given
point in a specific vendored/adapted decoder is exactly the kind of
per-file detail earlier work (§8b's own self-modifying-code and
odd-address bugs) proved unsafe to guess at. Two examples where an
initial assumption was wrong and had to be corrected before shipping:
`store`'s header-pointer register (A2) turns out to still be needed
*after* `Depack` returns (`runtime.i`'s own `RelocFixup`/BSS-clear step
re-reads it), so the flicker's address register had to be a genuinely
unused one instead; and inflate's `build_code` subroutine clobbers the
register initially assumed free "for the whole call," forcing that
backend's own address-register setup to move to after both `build_code`
calls finish, with the `FLAG_KILLTWITCH` decision itself cached into a
spare data register across that gap instead.

**`--flash` CLI (`src/main.zig`, `cmdPack`):**

- `--flash=off`: never embeds a flash-instrumented stub.
- `--flash=on`: always embeds one. Every backend has one, so (unlike
  `--overlap=on`) there is no unsupported-backend fallback case.
- `--flash=auto` (the default): embeds one only when this specific
  file's own measured decompression time exceeds 1 second - the same
  cycle count `measureOverlapMargin` (§8b) already produces for every
  backend, converted to real PAL seconds, so this decision costs nothing
  beyond what `--overlap`'s own measurement already pays for.
- `--killtwitch`: redirects the poke target to `COLOR00` (see above); has
  no effect when flashing itself is off.

## 9. Versioning policy

Pre-1.0 (i.e. until a backend actually ships and something depends on a
packed executable produced by an older execram still running under a
newer one): the format may change freely between milestones. Once that
stops being true, the policy is: `version_major` bumps for anything a
stub *must* understand to behave correctly (changing a field's meaning or
position); `version_minor` bumps for additive changes an old stub can
safely ignore (a newly-meaningful reserved flag bit, say).

## 10. Open items for later milestones

- ~~Reloc stream encoding (§7) is unvalidated against real
  executables~~ — validated: `tests/uae/e2e_large/` exercises 22
  relocations (20 self-hunk, 2 cross-hunk) and `tests/corpus/`'s
  `bss_heavy` item adds a real CODE→BSS relocation target, all
  byte-exact-verified on real hardware. No density or pattern problems
  found; §7 stands as originally specified.
- ~~The two-allocation runtime scheme (§8) can exceed memory on a base
  512KB Amiga even for programs much smaller than that~~ — fixed: the
  two post-decompression allocations (`scratch`, `final`) were merged
  into one, then that single-allocation scheme was itself replaced by
  the current two-hunk design below.
- ~~The loaded hunk (stub+header+compressed payload) is never freed,
  costing the packed file's own compressed size as permanent dead
  weight for the program's entire life~~ — fixed: adopted Shrinkler's
  own default-mode design (`docs/memory-lifecycle.md`'s "Comparison"
  section) instead of a single loaded hunk. The container is now two
  hunks (§2); hunk 1 (stub+header+payload) is freed once decompression
  finishes (§8), leaving steady-state memory at exactly the resident
  image size, matching Shrinkler's own default mode's result.
- ~~True overlap-in-place decompression (compressed and decompressed
  data sharing the *same* bytes, the way Shrinkler's `--overlap` mode
  does it, rather than two disjoint hunks) remains open~~ — shipped, for
  **every backend** (`--overlap=on|auto`, §8b, `FLAG_OVERLAP`):
  `stubs/common/runtime.i`'s `FLAG_OVERLAP` branch and
  `OverlapPayloadOffset` are shared unconditionally by every backend's
  stub - no per-backend assembly work was ever needed, only
  `src/main.zig`'s `compressWithBackend` measuring a margin
  (`supports_overlap`) for each one. Rather than a generic theoretical
  per-backend formula, `safety_margin` is measured empirically per file
  at pack time (`src/musashi_bench.zig`'s `measureOverlapMargin`), the
  same approach Shrinkler's own `--overlap` mode uses (`HunkFile.h`'s
  `verify()`). `docs/algorithm-notes/`'s per-backend entries note their
  own measured margin behavior where it's genuinely backend-specific
  (`store.md`/`zx0.md`'s sections - most other backends behave like one
  of those two: `store` near-zero, everything else data-dependent).
- CPU-tiered stubs (68000 vs. 68020+), noted as an open question in
  [PROJECT_PLAN.md](../PROJECT_PLAN.md) §10, would most naturally live as
  another `flags` bit or a small stub-selection table in the host tool,
  not a header change.
- Whether `MEM_CHIP`'s all-or-nothing merge (§5) ever needs a per-region
  escape hatch — deferred until a real program with mixed chip/fast
  hunks makes it a concrete problem rather than a theoretical one. (The
  two-hunk redesign already fixed the narrower version of this that
  applied to hunk 1 itself - it's now always `MEMF_ANY`, never forced
  into Chip RAM alongside hunk 0.)
- Whether `CacheClearU` (a 68020+ instruction-cache flush before jumping
  into freshly-decompressed code, skipped on plain 68000s) is a real gap
  on real 68020+ hardware - Shrinkler's own default and `--overlap`
  decrunch headers both do this, execram's runtime never does
  (`docs/memory-lifecycle.md`'s "Comparison" section) - not yet
  investigated.
