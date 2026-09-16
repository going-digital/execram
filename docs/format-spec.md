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
| 24     | 4    | `compressed_size`     | Bytes of the compressed payload, immediately following this header. |
| 28     | 4    | `safety_margin`       | Reserved, must be 0 in v0 (see §8 — the compressed payload and the buffer being decompressed into never overlap in v0, so no backend-specific expansion margin is needed yet). |

Header size in v0: 32 bytes.

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
| 4-254 | reserved for future backends | |
| 255   | invalid / never emitted | tooling sentinel |

## 5. `flags` bitfield

| Bit | Name | Meaning when set |
|----:|------|-------------------|
| 0   | `MEM_CHIP` | Allocate hunk 0 (the resident image, §2) in Chip RAM (`MEMF_CHIP`). Clear means `MEMF_ANY` — a binary choice, decided by `execram pack` from the original executable's own hunk memory attributes (any hunk requesting Chip RAM sets it for the whole merged image) and overridable via `--mem=chip\|fast` (`src/main.zig`, `container.zig`'s `mem_chip` field). Only hunk 0 is affected either way — hunk 1 (the scratch stub+header+payload hunk) is always plain `MEMF_ANY`, regardless of this bit, since it's freed long before decompression is done and never needs Chip-RAM addressability itself. |
| 1   | `HAS_RELOCS` | A reloc stream follows the code+data in the decompressed payload (§6). If clear, `reloc_stream_size` must be 0 and the fixup pass is skipped entirely. |
| 2   | `FLASH` | Purely cosmetic, no effect on decoding: the stub sets `COLOR00` (the background/border colour register, `$dff180`) to a fixed bright colour immediately before calling the backend's `Depack:`, and restores it to black immediately after — a visible "something is happening" indicator for slow backends on real hardware, where a large file can otherwise sit at a blank screen for tens of seconds with no sign the machine hasn't hung. Set by `execram pack --flash`. |
| 3-7 | *(reserved)* | Must be 0 in v0. A stub must ignore reserved bits it doesn't understand rather than reject the file — only a `version_major` bump means "you must understand this to run me correctly." |

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

This isn't full in-place/overlapping decompression the way Shrinkler's
own `OverlapHeader.S` does it (compressed and decompressed data sharing
even the *same* bytes, needing a backend-specific worst-case expansion
bound to prove it's always safe) - `safety_margin` remains reserved
and pinned to 0 for that reason. Hunk 1 (still holding the compressed
payload) and `final` (hunk 0) are always two disjoint memory regions;
Depack reads from one and writes to the other, never overlapping.

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
  image size, matching Shrinkler's own default mode's result. True
  overlap-in-place decompression (compressed and decompressed data
  sharing the *same* bytes, the way Shrinkler's `--overlap` mode does
  it, rather than two disjoint hunks) remains open - it needs a proven
  safety-margin formula per backend before it can ship; each backend's
  `docs/algorithm-notes/` entry should derive one when ready.
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
