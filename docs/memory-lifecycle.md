# Memory lifecycle: from `LoadSeg` to the payload's entry point

A phase-by-phase account of what's resident in memory, and where, between
AmigaDOS finishing `LoadSeg` on a packed executable and the stub jumping
into the decompressed program. Complements `docs/format-spec.md` §8 (the
runtime algorithm itself, and the history of why it looks like this) -
this page is about the *memory*, not the instructions: what exists, where,
for how long, and what (if anything) is ever freed.

The short version: **one `AllocMem` call, zero `FreeMem` calls, two
buffers resident at once, for the entire run.** No third buffer, no
in-place overlap, nothing ever reclaimed before the jump.

## The two buffers

| | What it is | Who allocated it | When it goes away |
|---|---|---|---|
| **The loaded hunk** | stub code ++ execram header ++ still-compressed payload (`docs/format-spec.md` §2) | AmigaDOS itself, via `LoadSeg`, before the stub's first instruction ever runs | Never, while the process is alive - it's the process's own code segment, not memory execram controls (see "What never happens" below) |
| **`final`** | the decompressed, relocated, resident program image | the stub, one `AllocMem` call (`stubs/common/runtime.i`) | Never, while the process is alive - it *becomes* the running program, there's nothing to free it into |

Both are real, simultaneously-resident allocations for the stub's entire
run and for the rest of the program's life afterward. There is never a
third buffer - see "Not true in-place decompression" below for how that
differs from what a `safety_margin`-based scheme would need.

## Phase by phase

**0. Before `Start:` runs.** AmigaDOS has just finished `LoadSeg`-ing the
packed executable. The only memory in this picture is the loaded hunk -
the whole file, stub and header and compressed payload together, exactly
as written to disk (padded to a longword, `docs/format-spec.md` §2).
`final` doesn't exist yet; nothing has been allocated by the stub at all.

**1. `AllocMem` (format-spec §8 step 2).** The stub computes one size,
`code_data_size + max(bss_size, reloc_stream_size)`, and makes one
`AllocMem` call, `MEMF_CLEAR` and optionally `MEMF_CHIP`
(`stubs/common/runtime.i`'s `Start:`). This is the only allocation that
ever happens. `final` now exists, freshly zeroed, at a fresh address
disjoint from the loaded hunk - the two never overlap in v0 (see below).
This is also the moment of **peak memory use**: both buffers are resident
from here until the jump, and nothing gets smaller or goes away before
then.

**2. `Depack` (step 3).** The backend's depacker reads the compressed
payload from the loaded hunk (right after the header) and writes
`code_data_size + reloc_stream_size` decompressed bytes directly into
`final`, starting at offset 0. No intermediate buffer: whatever the
backend decodes lands in `final` immediately, in its final resident
position. The loaded hunk is only ever *read* here, never written.

**3. `RelocFixup` (step 4), if `flags` bit 1 is set.** By this point
`final` is self-contained: the reloc stream `Depack` just wrote to
`final`'s tail (`final + code_data_size`) is read back out of `final`
itself to patch longwords earlier in `final`'s own `code_data` region
(`stubs/common/runtime.i`'s `RelocFixup`). The loaded hunk isn't touched
at all in this step - by now it holds nothing anything still needs.

**4. BSS re-clear (step 5).** `final`'s tail - the same bytes that just
held the reloc stream - gets zeroed again, unconditionally, because that
region is also the program's real BSS and it must start at zero
(`stubs/common/runtime.i`'s own comment on why `AllocMem`'s `MEMF_CLEAR`
alone isn't enough: it only zeroed this region *before* steps 2-3 wrote
over it). This is the one point where `final`'s own tail changes meaning
mid-flight - see the diagram below.

**5. `jmp (a4)` (step 6) - and after.** Control passes to `final + 0`,
the payload's own entry point. `final` is now simply the running
program's resident image; nothing about it changes at handoff. The loaded
hunk, however, **is still sitting in memory, unfreed, and stays there for
the rest of the process's life** - the running program never reads it
again, but nothing ever gives it back either. See below.

## `final`'s tail means two different things at two different times

```
  offset 0                code_data_size          code_data_size + max(bss_size, reloc_stream_size)
  |------------------------|-------------------------------|
  |       code + data       |         tail region            |
  |------------------------|-------------------------------|

  after AllocMem  (step 1): zero (MEMF_CLEAR)      zero
  after Depack    (step 2): final code/data        reloc stream (reloc_stream_size bytes) +
                                                    zero padding out to bss_size, if bss_size is larger
  after RelocFixup(step 3): patched in place        unchanged (already consumed)
  after BSS clear (step 4): unchanged              zero again - now genuinely BSS
```

The tail region is sized to whichever of `bss_size` or `reloc_stream_size`
is larger, because it plays both roles in turn, never at the same time:
first it's scratch space for a reloc stream that gets fully consumed, then
it's the program's own BSS. `docs/format-spec.md` §8 has the full
step-by-step; this is the same fact, viewed as data rather than as code.

## Chip RAM: both buffers share one decision

The `MEM_CHIP` flag (`docs/format-spec.md` §5) drives *two* independent
requests for the same memory type, not one:

- The loaded hunk's own memory type is decided at `LoadSeg` time by the
  `HUNK_HEADER`'s size-longs field, which `container.zig`'s
  `writeHunkExecutable` sets `MEMF_CHIP_BIT` on whenever `mem_chip` is
  true - AmigaDOS itself honors this when it allocates memory for the
  hunk it's about to load, before the stub's first instruction runs.
- `final`'s `AllocMem` call (`stubs/common/runtime.i`) separately ORs in
  `MEMF_CHIP` from the *same* header flag bit.

So a Chip-RAM-requiring program doesn't just cost more total memory while
packed - both the still-resident loaded hunk *and* `final` compete for
the same, much smaller Chip RAM pool at once, for the program's whole
life. This is a direct consequence of the "no separate per-region memory
type" limitation `docs/format-spec.md` §5 already documents; it's worth
knowing it applies to the loaded hunk too, not just the resident image.

## What never happens

- **No `FreeMem` call exists anywhere in the current runtime.** `final`
  is allocated once and never freed by the stub - there's nothing to free
  it *into*, since it becomes the running program. (An earlier,
  since-replaced version of this runtime *did* call `FreeMem` once, on a
  now-removed second allocation - see "History" below. That allocation no
  longer exists, and the current runtime has no `FreeMem` call at all.)
- **The loaded hunk is never freed either, by anything, ever, while the
  process runs.** This isn't a missed optimization - a running AmigaDOS
  process's own code segment isn't something the process can free itself;
  DOS reclaims it only when the process's seglist is unloaded, normally
  at process exit. This was already true even under the old
  two-allocation scheme (only the scratch buffer was ever freed, never
  the loaded hunk) - see `stubs/common/runtime.i`'s own comment.
- **No third buffer ever exists.** `Depack` writes straight into `final`;
  there is no separate decompression-scratch area at any point.

One real, permanent consequence follows from the first two points
together: **an execram-packed program costs its own compressed file size
as dead weight for its entire run**, on top of the resident image size -
memory a plain, unpacked executable would never have spent at all. This
is the price of compression; the runtime doesn't hide it, it just keeps
that cost to exactly one extra buffer (the loaded hunk itself), not two.

## Not true in-place decompression

The loaded hunk (still holding the compressed payload) and `final` are
always two disjoint memory regions in v0 - `Depack` reads from one and
writes to the other, never the same address twice for different reasons.
This is *not* the same thing as Shrinkler's own `OverlapHeader.S`-style
overlapping decompression, where the compressed and decompressed data
share the very same bytes and a backend-specific worst-case expansion
bound has to prove that's always safe. `safety_margin`
(`docs/format-spec.md` §3) stays reserved and pinned to 0 for exactly
this reason - v0 doesn't need it, because it never overlaps anything.
`docs/format-spec.md` §10 tracks true overlap-in-place decompression as a
separate, still-open item.

## History: why this used to be three buffers, briefly, and no longer is

The current single-`AllocMem` design replaced an earlier version that
allocated `final` and a separate `scratch` buffer (for `Depack`'s output,
before a copy-and-fixup pass moved it into `final`), then freed `scratch`.
That version was simpler to read but, for a brief window, needed **three**
buffers resident simultaneously - the loaded hunk, `scratch`, and
`final` - because the loaded hunk is never freed (see above) and
`scratch` couldn't be freed until after `final` was already allocated and
filled. On a real 221KB program packed with `zultra`, that peak reached
~564KB (144KB loaded hunk + 216KB scratch + 218KB final), safely over a
base 512KB Amiga's *entire* memory even though the packed file itself was
well under 512KB - confirmed by a real hardware crash report, root-caused
and fixed in the commit that removed `scratch` entirely. The full
before/after story, with the exact numbers, lives in
`docs/format-spec.md` §8 and that commit's own message
(`git log --oneline --grep="512KB"` finds it) - this page describes only
the current, shipped design.
