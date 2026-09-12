# execram container format — v0

**Status:** draft, unimplemented. Nothing has shipped yet, so this format
is free to change during M1-M4 as the hunk engine and each backend get
built against it. Treat this as the contract those milestones implement
and test against, not a frozen spec — this note will be removed once a
release actually depends on format stability.

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
| 28     | 4    | `safety_margin`       | Reserved, must be 0 in v0 (see §7 — v0 always decompresses into a separate buffer, so no backend-specific expansion margin is needed yet). |

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
| 2     | zx0 | M3 |
| 3     | shrinkler-class | M4 |
| 4-254 | reserved for future backends | |
| 255   | invalid / never emitted | tooling sentinel |

## 5. `flags` bitfield

| Bit | Name | Meaning when set |
|----:|------|-------------------|
| 0   | `MEM_CHIP` | Allocate the resident image in Chip RAM (`MEMF_CHIP`). Clear means `MEMF_ANY` (or a Fast-RAM preference — TBD when M1 actually decides original-hunk memory attributes). |
| 1   | `HAS_RELOCS` | A reloc stream follows the code+data in the decompressed payload (§6). If clear, `reloc_stream_size` must be 0 and the fixup pass is skipped entirely. |
| 2-7 | *(reserved)* | Must be 0 in v0. A stub must ignore reserved bits it doesn't understand rather than reject the file — only a `version_major` bump means "you must understand this to run me correctly." |

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
2. `scratch = AllocMem(code_data_size + reloc_stream_size, MEMF_ANY)`.
3. Call the backend's depack routine: input = the compressed payload
   (still sitting in the currently-loaded hunk, right after the header),
   output = `scratch`. This is the only backend-specific step.
4. `final = AllocMem(code_data_size + bss_size, MEMF_CLEAR | chip_flag)` —
   `MEMF_CLEAR` zeros the whole block, so the BSS tail needs no explicit
   clearing loop.
5. Copy the first `code_data_size` bytes of `scratch` to `final`.
6. If `flags` bit 1 is set, walk the reloc stream (the trailing
   `reloc_stream_size` bytes of `scratch`) and, for each decoded offset,
   add `final`'s runtime address to the longword at `final + offset`.
7. `FreeMem(scratch, ...)`.
8. Jump to `final + 0`.

This always works and never needs a safety margin, at the cost of a
second allocation, a copy, and briefly holding both buffers in memory —
deliberately the simple, obviously-correct version for v0. The original
loaded hunk (stub + header + compressed payload) is left allocated for
the process's lifetime rather than freed — a small (compressed-size-sized)
permanent waste, acceptable for now.

**Future optimization, not v0:** when `bss_size >= reloc_stream_size`,
skip `scratch` entirely — decompress straight into `final`, using the
soon-to-be-BSS tail as reloc-stream scratch space, run fixup, then
explicitly zero just the BSS region afterward (instead of relying on
`MEMF_CLEAR` up front, which would otherwise get overwritten and need
re-zeroing anyway). This is Shrinkler's `OverlapHeader.S` idea in spirit —
decompressing back into memory you already hold instead of allocating
twice — generalized to the code+data/BSS/reloc-stream split here. It
needs `safety_margin` to actually mean something (a backend-specific
worst-case bound), which is why that field exists already even though
it's pinned to 0 until this lands.

## 9. Versioning policy

Pre-1.0 (i.e. until a backend actually ships and something depends on a
packed executable produced by an older execram still running under a
newer one): the format may change freely between milestones. Once that
stops being true, the policy is: `version_major` bumps for anything a
stub *must* understand to behave correctly (changing a field's meaning or
position); `version_minor` bumps for additive changes an old stub can
safely ignore (a newly-meaningful reserved flag bit, say).

## 10. Open items for later milestones

- Reloc stream encoding (§7) is unvalidated against real executables —
  M1 should check it against actual reloc counts/densities before
  treating it as settled.
- Overlap-in-place decompression (§8's future optimization) — needs a
  proven safety-margin formula per backend before it can ship; each
  backend's `docs/algorithm-notes/` entry should derive one when ready.
- CPU-tiered stubs (68000 vs. 68020+), noted as an open question in
  [PROJECT_PLAN.md](../PROJECT_PLAN.md) §10, would most naturally live as
  another `flags` bit or a small stub-selection table in the host tool,
  not a header change.
- Whether `MEM_CHIP`'s all-or-nothing merge (§5) ever needs a per-region
  escape hatch — deferred until a real program with mixed chip/fast
  hunks makes it a concrete problem rather than a theoretical one.
