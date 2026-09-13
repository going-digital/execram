# execram container format — v0

**Status:** shipped as of v1.0. All six backends (store, inflate, zultra,
zx0, salvador, shrinkler) implement this exact format, verified against
real emulated 68k hardware (`tests/uae/`) as well as host-side unit
tests. §9's versioning policy is now live: a change to anything a stub
*must* understand needs a `version_major` bump, not a silent edit here.

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

A packed executable is a plain, single-hunk AmigaDOS load file:

```
HUNK_HEADER   (one hunk, size = ceil(total below / 4) longwords,
               MEMF_CHIP requested iff header.flags bit 0 is set)
HUNK_CODE     stub code ++ execram header ++ compressed payload
              (padded to a longword boundary, as the hunk format requires)
HUNK_END
```

No `HUNK_RELOC32` at all: the stub is pure position-independent code
(PC-relative branches/references only; the only absolute addresses it
uses are genuine fixed hardware register addresses, e.g. the custom chip
base at `$dff000`, which are not relocatable program addresses). This was
proven out in the `tests/uae` boot-block stub — see
[sentinel.s](../tests/uae/boot/sentinel.s).

The **execram header is not part of the assembled stub binary.** The stub
is a fixed, pre-assembled blob embedded into the host tool at Zig-build
time (see `build.zig`) and reused unchanged across every packed output —
so per-file parameters (sizes, backend choice, ...) can never be patched
into stub instructions the way a per-file-assembled stub could. Instead
they're *data* the stub reads at runtime, exactly like Shrinkler's own
`ShrinklerDecompress.S` reads its `shr_*` header fields (see
`docs/LICENSES.md` §1b for that reference). The host tool's job when
producing an output file is: `stub_bytes ++ header_bytes ++ payload_bytes`,
contiguous, with the stub locating the header via a PC-relative reference
to a label at the very end of its own code — so the assembled stub
binary's length **is** the header's offset within the hunk, by
construction.

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

The **resident image size** (what actually needs to stay in memory once
the program is running) is `code_data_size + bss_size`, computed, not
stored — there's no field for it.

By convention, **the flattened program's entry point is always offset 0**
of the resident image. `flatten.zig` (M1) must guarantee this; there's no
`entry_offset` field because there's nothing for it to vary.

## 4. `backend_id` registry

| Value | Backend | Milestone |
|------:|---------|-----------|
| 0     | store (no compression) | M1 |
| 1     | inflate (DEFLATE) | M2 (also used by the `zultra` CLI backend - an alternative, stronger DEFLATE *encoder* producing the same format for the same depacker; there's no separate `zultra` entry here because the container/stub don't need one) |
| 2     | zx0 | M3 (also used by the `salvador` CLI backend - an alternative, optimal-parse ZX0 *encoder* producing the same format for the same depacker; there's no separate `salvador` entry here for the same reason there's no separate `zultra` entry above) |
| 3     | shrinkler-class | M4 |
| 4-254 | reserved for future backends | |
| 255   | invalid / never emitted | tooling sentinel |

## 5. `flags` bitfield

| Bit | Name | Meaning when set |
|----:|------|-------------------|
| 0   | `MEM_CHIP` | Allocate the resident image in Chip RAM (`MEMF_CHIP`). Clear means `MEMF_ANY` — a binary choice, decided by `execram pack` from the original executable's own hunk memory attributes (any hunk requesting Chip RAM sets it for the whole merged image) and overridable via `--mem=chip\|fast` (`src/main.zig`, `container.zig`'s `mem_chip` field). |
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

The stub, on entry (position-independent, no relocation needed for
itself):

1. Locate the header via a PC-relative reference to the label right after
   its own code (§2). Check `magic` and `version_major`; if either is
   wrong, there's nothing sensible to do (v0 doesn't define recovery
   behavior — there's only one major version so far).
2. `final = AllocMem(code_data_size + max(bss_size, reloc_stream_size), MEMF_CLEAR | chip_flag)`.
   One allocation, not two (see below for why that used to be two and
   isn't anymore) — sized to hold whichever tail is larger: the real
   BSS the program needs at runtime, or the reloc stream the next step
   still has to read (they occupy the same trailing region, just at
   different times — the reloc stream is fully consumed by step 4
   before anything cares what "BSS" actually contains there).
3. Call the backend's depack routine: input = the compressed payload
   (still sitting in the currently-loaded hunk, right after the header),
   output = `final`, directly. This is the only backend-specific step.
4. If `flags` bit 1 is set, walk the reloc stream (the trailing
   `reloc_stream_size` bytes of `final`, right after `code_data_size`)
   and, for each decoded offset, add `final`'s runtime address to the
   longword at `final + offset`.
5. Clear `final[code_data_size .. code_data_size + bss_size]` again,
   unconditionally. Step 3 wrote `code_data_size + reloc_stream_size`
   bytes there (code_data followed by the reloc stream, if any), which
   only fills that region with zero when `reloc_stream_size >=
   bss_size` — whenever the reloc stream is the *shorter* of the two
   (the common case), its tail leaves leftover reloc-stream bytes sitting
   where the program's BSS needs to be all-zero at entry. `AllocMem`'s
   own `MEMF_CLEAR` doesn't help here either: it only zeroed this region
   *before* steps 3–4 wrote all over it. `bss_size` is always a multiple
   of 4 (hunk sizes are stored in longwords), so this is a plain
   longword-clear loop.
6. Jump to `final + 0`.

**This replaced an earlier two-allocation version** (`scratch =
AllocMem(code_data_size + reloc_stream_size, MEMF_ANY)`, depack into
`scratch`, `final = AllocMem(code_data_size + bss_size, MEMF_CLEAR)`,
copy `scratch`'s first `code_data_size` bytes to `final`, fix up
`final`, `FreeMem(scratch, ...)`, jump). That version was simple and
obviously correct, but genuinely ran out of memory on real, memory-
constrained hardware: the original loaded hunk (this stub + header +
compressed payload) is never freed — it's the process's own code
segment for its whole lifetime, not memory under our control — so at
the moment `final` was allocated but `scratch` not yet freed, all
three had to fit in memory simultaneously. Confirmed directly on a
real 221KB program packed with zultra: a peak of ~564KB (144KB packed
+ 216KB scratch + 218KB final), comfortably over a base Amiga's entire
512KB before Kickstart's own overhead - it packed and self-checked
fine on the host, and even decompressed correctly under emulation, but
had nowhere to get to on an actual 512KB machine. The one-allocation
version above needs ~354KB instead for the same file (the packed
image plus one buffer, not two), by decompressing straight into the
buffer that becomes the resident image instead of a separate one that
gets thrown away.

This isn't full in-place/overlapping decompression the way Shrinkler's
own `OverlapHeader.S` does it (compressed and decompressed data sharing
even the *same* bytes, needing a backend-specific worst-case expansion
bound to prove it's always safe) - `safety_margin` remains reserved
and pinned to 0 for that reason. It's a narrower, always-safe
simplification: the compressed payload and the buffer being decompressed
into never overlap (the payload stays in the original hunk throughout),
only the *two post-decompression allocations* got merged into one.

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
  two post-decompression allocations (`scratch`, `final`) are merged
  into one (§8). True overlap-in-place decompression (compressed and
  decompressed data sharing the *same* bytes, not just one merged
  post-decompression buffer) remains open - it needs a proven
  safety-margin formula per backend before it can ship; each backend's
  `docs/algorithm-notes/` entry should derive one when ready.
- CPU-tiered stubs (68000 vs. 68020+), noted as an open question in
  [PROJECT_PLAN.md](../PROJECT_PLAN.md) §10, would most naturally live as
  another `flags` bit or a small stub-selection table in the host tool,
  not a header change.
- Whether `MEM_CHIP`'s all-or-nothing merge (§5) ever needs a per-region
  escape hatch — deferred until a real program with mixed chip/fast
  hunks makes it a concrete problem rather than a theoretical one.
