# Memory lifecycle: from `LoadSeg` to the payload's entry point

A phase-by-phase account of what's resident in memory, and where, between
AmigaDOS finishing `LoadSeg` on a packed executable and the stub jumping
into the decompressed program. Complements `docs/format-spec.md` §8 (the
runtime algorithm itself) - this page is about the *memory*, not the
instructions: what exists, where, for how long, and what (if anything) is
ever freed.

For mixed memory classes, [v1's grouped layout](grouped-memory-format.md)
keeps one resident region per class, plus a shared scratch hunk. LoadSeg
allocates each with its original ANY/CHIP/FAST requirement. Each region
is decompressed directly into its own allocation, cross-region relocations
are applied, and only scratch is detached and freed. There is no temporary
full-program output buffer. Explicit Fast-only inputs also use this layout.
The two-hunk account below describes v0's single resident region.

The short version: **AmigaDOS's own `LoadSeg` does every allocation - the
runtime itself makes none at all.** Two hunks are resident throughout
decompression; the second is freed by the stub's own code the moment it's
no longer needed, leaving exactly one hunk - the running program itself -
resident for the rest of the process's life.

## The two hunks

| | What it is | Who allocated it | When it goes away |
|---|---|---|---|
| **Hunk 0** (`final`) | the decompressed, relocated, resident program image | `LoadSeg`, before the trampoline's first instruction ever runs | Never, while the process is alive - it *becomes* the running program |
| **Hunk 1** | stub code ++ execram header ++ still-compressed payload (`docs/format-spec.md` §2) | `LoadSeg`, at the same time as hunk 0 | Freed by hunk 1's own code, once decompression finishes (see "What never happens" below) |

Both are real, simultaneously-resident allocations for the whole time
decompression takes. There is never a third buffer - see "Not true
in-place decompression" below for how that differs from what a
`safety_margin`-based scheme would need.

## Phase by phase

**0. Before the trampoline runs.** AmigaDOS's `LoadSeg` has just finished
allocating *both* hunks and linking them together - hunk 0's own
chain-pointer field points at hunk 1 (`docs/format-spec.md` §8's own ABI
note) - exactly like loading any other multi-hunk file, nothing
execram-specific about it yet. Hunk 0 is freshly allocated but not
necessarily zeroed beyond whatever `LoadSeg` happened to leave there -
nothing later depends on it starting zeroed (see step 4). Hunk 1 holds
the real file bytes: stub code, header, and compressed payload, exactly
as packed.

**1. The trampoline (`stubs/common/trampoline.s`), hunk 0's own entry
point.** `LoadSeg` jumps here directly - this is the whole packed file's
entry point. It computes its own address (`final` - this label *is* hunk
0's data start), reads hunk 0's own chain-pointer field to find hunk 1,
and jumps into hunk 1's own code with `final` held in a register. This is
the **only** point where the two hunks are connected explicitly -
everything from here on just treats `final` as a plain address handed
in, not something to rediscover.

**2. `Start:` entry (`stubs/common/runtime.i` / `stubs/inflate/
runtime_std.i`).** Locates the header via its own PC-relative lookup
(within hunk 1's own data, unrelated to `final`). Checks `magic`/
`version_major`. **No allocation happens here, or anywhere else in the
runtime** - `final` already points at real, correctly-sized,
correctly-typed memory, decided entirely by what `LoadSeg` did before any
of this ran.

**3. `Depack`.** The backend's depacker reads the compressed payload from
hunk 1 (right after the header) and writes `code_data_size +
reloc_stream_size` decompressed bytes directly into `final` (hunk 0),
starting at offset 0. No intermediate buffer: whatever the backend
decodes lands in `final` immediately, in its final resident position.
Hunk 1 is only ever *read* here, never written.

**4. `RelocFixup`, if `flags` bit 1 is set.** By this point `final` is
self-contained: the reloc stream `Depack` just wrote to `final`'s tail
(`final + code_data_size`) is read back out of `final` itself to patch
longwords earlier in `final`'s own `code_data` region. Hunk 1 isn't
touched at all in this step.

**5. BSS re-clear.** `final`'s tail - the same bytes that just held the
reloc stream - gets zeroed again, unconditionally, because that region is
also the program's real BSS and it must start at zero. This step makes no
assumption about what was in that memory beforehand, not even that
`LoadSeg` zeroed hunk 0's own allocation in the first place (step 0) -
whatever was there, real or leftover reloc-stream bytes, gets overwritten
with zero here regardless.

**6. Detach and free hunk 1.** Hunk 0's own chain-pointer field is
cleared (so `LoadSeg`'s bookkeeping doesn't try to free hunk 1 a second
time when the process eventually exits), then hunk 1 is `FreeMem`'d -
its own recorded total size, read back from its own data-start-minus-8,
needs no separate tracking anywhere. **This is the one point in the whole
run where anything is freed**, and it's the entire reason this design
exists: unlike the single-hunk scheme it replaced, hunk 1 (the compressed
file bytes, now fully consumed) doesn't have to sit in memory for the
rest of the process's life.

**7. Return from `FreeMem` into `final+0` - and after.** The runtime
pushes the payload entry address and tail-jumps to Exec's `FreeMem`.
Its return enters the payload directly, restoring the original stack
pointer and preserving the caller's return address. No instruction runs
from scratch after it is freed, and no executable stack stub is needed.
Control passes to the payload's own
entry point. `final` (hunk 0) is now simply the running program's
resident image; nothing about it changes at handoff. Hunk 1 no longer
exists at all - `FreeMem` returned its memory to Exec's free pool in the
previous step.

## `final`'s tail means two different things at two different times

```
  offset 0                code_data_size          code_data_size + max(bss_size, reloc_stream_size)
  |------------------------|-------------------------------|
  |       code + data       |         tail region            |
  |------------------------|-------------------------------|

  after LoadSeg   (step 0): uninitialized (whatever    uninitialized
                            LoadSeg happened to leave)
  after Depack    (step 3): final code/data            reloc stream (reloc_stream_size bytes) +
                                                        whatever was already there, out to bss_size,
                                                        if bss_size is larger
  after RelocFixup(step 4): patched in place            unchanged (already consumed)
  after BSS clear (step 5): unchanged                  zero - now genuinely BSS
```

The tail region is sized to whichever of `bss_size` or `reloc_stream_size`
is larger (`docs/format-spec.md` §8's own note on why undersizing it lets
`Depack` overflow into hunk 1), because it plays both roles in turn, never
at the same time: first it's scratch space for a reloc stream that gets
fully consumed, then it's the program's own BSS. Unlike the earlier
single-allocation scheme (see "History" below), nothing here ever relies
on `MEMF_CLEAR` - there isn't an `AllocMem` call to request it from in the
first place, and step 5's unconditional clear was already written to make
no assumption about prior state, so the design didn't need to change when
`AllocMem` went away entirely.

## What never happens

- **No `AllocMem` call exists anywhere in the runtime.** `LoadSeg` is the
  only allocator, for both hunks, before either the trampoline's or
  `Start:`'s first instruction ever runs.
- **Hunk 0 (`final`) is never freed.** There's nothing to free it *into*
  - it becomes the running program.
- **Hunk 1 *is* freed - the one `FreeMem` call in the whole runtime**,
  once decompression, relocation, and the BSS re-clear are all done with
  it (step 6). This is the one respect in which the current design
  differs from a strict "nothing is ever freed" reading of an earlier
  version of this page - see "History".
- **No third buffer ever exists.** `Depack` writes straight into `final`;
  there is no separate decompression-scratch area at any point.

The real, permanent consequence that follows: **an execram-packed
program's steady-state memory, once running, is exactly its resident
image size** - the compressed file's own bytes (hunk 1) are reclaimed,
not carried as dead weight for the rest of the process's life. This
wasn't always true (see "History") and matches what Shrinkler's own
default decrunch header already does (see "Comparison" below).

## Not true in-place decompression (the default layout)

This page's phase-by-phase account above is all true of `execram pack`'s
**default** layout: hunk 1 (still holding the compressed payload, until
step 6 frees it) and `final` (hunk 0) are always two disjoint memory
regions - `Depack` reads from one and writes to the other, never the same
address twice for different reasons. This is *not* the same thing as
Shrinkler's own `OverlapHeader.S`-style overlapping decompression, where
the compressed and decompressed data share the very same bytes and a
backend-specific worst-case expansion bound has to prove that's always
safe. `safety_margin` (`docs/format-spec.md` §3) stays 0 and `flags` bit
3 stays clear for exactly this reason whenever this layout is in use - it
doesn't need a margin, because it never overlaps anything.

execram now also has an opt-in layout that *does* overlap -
`--overlap=on|auto`, `FLAG_OVERLAP`, `docs/format-spec.md` §8b - covered
in its own row in the Comparison table below, right alongside the
Shrinkler `--overlap` row it was always modeled on.

## History: from one loaded hunk that's never freed, to two hunks and one `FreeMem` call

The current design is the second replacement of an original scheme, in
two steps:

**Two allocations to one (single-hunk era).** The stub originally
allocated a `scratch` buffer for `Depack`'s raw output, copied it into a
separately-allocated `final`, fixed up `final`, then freed `scratch`.
Simple and obviously correct, but it genuinely ran out of memory on real,
memory-constrained hardware: the packed file's own loaded hunk (stub +
header + compressed payload, back when it was a single hunk) was never
freed - it was the process's own code segment for its whole lifetime, not
memory under the runtime's control - so at the moment `final` was
allocated but `scratch` not yet freed, all three had to fit in memory
simultaneously. Confirmed directly on a real 221KB program packed with
`zultra`: a peak of ~564KB (144KB loaded hunk + 216KB scratch + 218KB
final), comfortably over a base Amiga's entire 512KB before Kickstart's
own overhead - it packed and self-checked fine on the host, and even
decompressed correctly under emulation, but had nowhere to get to on an
actual 512KB machine. Merging the two post-decompression allocations into
one (`scratch` and `final` combined, `Depack` writing straight into what
becomes `final`) fixed the immediate crash - `git log --oneline
--grep="512KB"` finds that commit - but the single loaded hunk itself
still stayed resident and unfreed for the packed program's entire life,
carrying its own compressed size as permanent dead weight.

**One loaded hunk to two hunks, one of them freed (current).** Reading
Shrinkler's own default decrunch header (see "Comparison" below) directly
suggested the fix: don't rely on a single AmigaDOS-loaded hunk holding
everything - split the packed file into two hunks instead, let `LoadSeg`
allocate both, and free the one that turns out to be pure scratch once
decompression is done. The ABI this depends on (how `LoadSeg` links and
sizes hunks in memory) was confirmed empirically under real FS-UAE across
three Kickstart versions before any code was written against it - see
`docs/format-spec.md` §8's own ABI note - and the redesign itself
surfaced one further latent bug in the process: hunk 0's own declared
size needs `max(bss_size, reloc_stream_size)`, not just `bss_size` (the
same fact the single-allocation era's own tail-sizing already knew, but
one that got dropped when translating "how big to `AllocMem`" into "how
big to declare hunk 0" - masked by every real test program tried before
it happening to have `bss_size` dominate). This page and
`docs/format-spec.md` describe only the current, shipped design; the
commit that introduced it has the full trail if the details matter.

## Comparison: how Shrinkler's own decrunchers handle this

execram vendors Shrinkler's raw LZ77+range-decoder routine
(`stubs/shrinkler/ShrinklerDecompress.s` - `docs/algorithm-notes/shrinkler.md`)
but not any of its three original decrunch headers, memory scheme
included - the container, allocation, and handoff mechanics documented
above are execram's own design throughout, even though the current one
now matches Shrinkler's own default mode's *result*. Reading the real
upstream source (`askeksa/Shrinkler` at `17cff110fcded387fe90e632805258d9c8359e94`,
the exact commit `docs/LICENSES.md` §1 already audits) directly informed
that redesign (see "History" above), and remains instructive for how far
past it Shrinkler's own more aggressive modes go.

**Shrinkler never flattens hunks.** A crunched Shrinkler executable keeps
the original program's exact hunk count, sizes, and per-hunk memory type,
and appends exactly one extra hunk (`newnumhunks = numhunks + 1` in
`cruncher/HunkFile.h`'s `crunch()`). AmigaDOS's `LoadSeg` allocates *all*
of these - the N real hunks plus the one extra - before any of
Shrinkler's own code runs, exactly like loading any ordinary multi-hunk
program. There is no `AllocMem` call anywhere in any of its three decrunch
headers (`decrunchers/Header.S`, `MiniHeader.S`, `OverlapHeader.S`) -
`LoadSeg` itself is the only allocator, for every buffer, in every mode -
the same property execram's own two-hunk design now shares, at the
smaller scale of exactly two hunks rather than N+1.

Three build-time modes, three different outcomes for that one extra hunk:

- **Default (`Header.S`)**: the extra hunk holds the decrunch code plus
  one combined compressed bitstream for the whole program. A tiny
  trampoline (`Header1`, appended into hunk 0's own memory) walks
  AmigaDOS's own hunk-chain linked list - every loaded hunk carries a
  pointer to the next one, written by `LoadSeg` itself - to reach it,
  then `Header2` decodes each original hunk's share of the stream
  **directly into that hunk's own already-allocated final memory**, hunk
  by hunk, applying relocations against those now-final addresses as it
  goes. Once every hunk is done, it flushes the instruction cache
  (`CacheClearU`, skipped on plain 68000s which have none) and then -
  **the one `FreeMem` call in Shrinkler's entire codebase** - frees that
  one extra hunk before jumping into the finished program. execram's own
  design (above) is the same shape at a smaller scale: one scratch hunk,
  one `FreeMem` call, freed before the jump - the difference is
  Shrinkler's trampoline lives inside a *real* program hunk it later
  overwrites with that hunk's own decompressed content, where execram's
  trampoline hunk (hunk 0) *is* the whole flattened image directly, since
  execram never preserves per-original-hunk structure to begin with (§1's
  rationale).
- **`--mini`**: the smallest possible decrunch header, restricted to a
  single-hunk input. Its own extra hunk (decrunch code + compressed
  data) is never freed - `MiniHeader.S` contains no `FreeMem` call at
  all. This mode ends up in the situation execram's *old*, single-hunk
  design was in, not its current one.
- **`--overlap`**: true in-place decompression - the mode execram's own
  `safety_margin` field (`docs/format-spec.md` §3, §8b) now implements
  for every backend (below). No shared scratch hunk exists at
  all - at pack time, `HunkFile.h`'s `verify()` actually *runs* the
  decompression for each hunk and measures the worst-case gap between
  its read and write pointers (`front_overlap_margin`), a proven number
  for that specific compressed output, not a generic theoretical bound -
  then bakes `hunksize = max(original_memsize, margin-based minimum)`
  into that hunk's own inflated `LoadSeg` allocation. At runtime, each
  hunk moves its own embedded compressed bytes to its own tail and
  decodes forward from its own start, the proven margin guaranteeing the
  write pointer never overtakes the read pointer. The only hunk added is
  `OverlapHeader`'s own tiny entry stub (no bulk data in it at all,
  since every real hunk now carries its own) - never freed either, but
  a few hundred bytes of decrunch code, not a whole compressed payload.

execram's own `--overlap` mode (`docs/format-spec.md` §8b) takes a
noticeably different shape from Shrinkler's own `--overlap` at the
hunk-structure level, even though the underlying idea (compressed and
decompressed data sharing a buffer, a proven-not-assumed margin
separating them, and - see below - a runtime memmove from a cheap
on-disk position to that safe position) is now the same: Shrinkler adds
one genuinely new hunk (its tiny `OverlapHeader` entry stub) on top of N
real per-original hunks, each of which then decompresses *itself* in
place. execram instead keeps its *existing* two-hunk shape
(`docs/format-spec.md` §2) unchanged - hunk 0 the resident image, hunk 1
the depacker stub + header, still freed after use exactly as the default
layout already does - and just moves *where the compressed payload
physically sits*: into hunk 0's own on-disk body (right after the
trampoline), relocated by the runtime to a computed tail offset before
`Depack` runs, instead of trailing hunk 1. Hunk 1's own code is never at
risk from `Depack`'s output (which only ever touches hunk 0), so there's
no analogue of Shrinkler's never-freed entry stub here at all - execram's
overlap layout frees *everything* scratch, same as its default layout,
gaining only the compressed payload's own hunk-1 footprint back (a much
smaller hunk 1, not a whole extra hunk).

`src/musashi_bench.zig`'s `measureOverlapMargin` plays `verify()`'s own
role - it actually runs the depacker under real 68k emulation and
measures the true worst-case read/write gap for the specific file being
packed, the same "proven for this input, not a generic bound" approach,
run inside `compressWithBackend` for every backend that supports the
overlap layout. `execram pack --overlap=auto` (the default) then picks
disjoint or overlap per file by comparing both layouts' real peak memory
footprint (hunk 0 + hunk 1, both resident simultaneously in either
layout), rather than Shrinkler's own build-time mode selection.

**A runtime "move the payload to where it needs to be" step does exist**
- `stubs/common/runtime.i`'s `OverlapMovePayload`, a plain backward
`move.l -(a0),-(a1)` copy loop, run once right before `Depack`, the same
shape as Shrinkler's own per-hunk memmove. An earlier version of this
page (and the code it described) claimed execram's own payload "already
lands at the right on-disk offset the moment `LoadSeg` loads hunk 0" -
true, but it turned out to be the wrong design: placing the payload
directly at its final, margin-safe tail offset *on disk* meant every
byte between the trampoline's end and that offset had to be
materialized as literal file padding, since AmigaDOS's own "declared
hunk size > on-disk data length" trick only ever leaves a hunk's *tail*
implicit, never a gap in its middle. For any backend with a real
compression ratio, that offset sits close to the full decompressed
size (§8b's own margin-measurement note: the margin needed for
uniformly-compressible data converges to decompressed_size -
compressed_size), so the packed file ended up barely smaller than the
original, uncompressed input - a real, reported bug (confirmed on a
221KB real program packed with `shrinkler --overlap=on`: 218848 bytes,
against 142120 without it). Reading Shrinkler's own decrunch headers
more carefully - specifically *why* they bother with a runtime memmove
at all, rather than just writing the payload straight to its safe
position like this page originally assumed was possible for free -
is what surfaced the fix: store the payload cheaply at hunk 0's own
front on disk, and pay one small, fixed runtime cost (proportional to
the compressed payload's own size, not to anything about the
decompression loop itself) to relocate it before decompression begins.

| | Extra scratch beyond the resident program | Ever freed? | Steady-state dead weight |
|---|---|---|---|
| execram (current, default) | one hunk (stub+header+compressed payload) | **yes** - the one `FreeMem` call in the runtime | none |
| execram `--overlap` (opt-in, every backend) | one much smaller hunk (stub+header only - the payload moved into hunk 0 itself) | **yes** - the same `FreeMem` call, now freeing far less | none |
| execram (old, single-hunk) | the whole loaded hunk (stub+header+compressed payload) | never | full compressed file size, forever |
| Shrinkler default | one extra hunk (decrunch code + whole combined bitstream) | **yes** - the one `FreeMem` call in Shrinkler's codebase | none |
| Shrinkler `--mini` | one extra hunk (decrunch code + compressed data) | never | full compressed data size, forever |
| Shrinkler `--overlap` | none (each hunk carries its own compressed tail) | n/a - no scratch hunk holds bulk data | a few hundred bytes (the entry stub only) |

Unlike Shrinkler's own `--overlap` (whose `OverlapHeader` entry stub is
never freed at all), execram's overlap layout frees hunk 1 in full,
matching its own default layout's mechanism exactly - `--mem=chip` still
only ever affects hunk 0 (§5's own note), never hunk 1, in either layout.

Both execram runtimes call `CacheClearU` after all decompression,
relocation and BSS clearing, before freeing scratch and entering the
resident program. This pushes dirty data-cache lines to memory and
invalidates stale instructions, including the overwritten entry trampoline.
The call is guarded by `ExecBase.lib_Version >= 37`; older Exec versions
lack this API and skip it. Cached CPUs running older Exec versions still
need a separate cache-coherency solution.
