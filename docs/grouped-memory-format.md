# Grouped memory container, v1.0

By default, inputs with more than one HUNK memory class, or any explicit
Fast requirement, use this format. Ordinary-only and Chip-only inputs keep
v0. Explicit `--mem` overrides retain the old single-region behavior.

The host retains each hunk's **allocation size**, separately from its body
length. Code/data tails are zero-padded before compression; BSS reserves
its full allocation without adding bytes to the compressed code/data.
Within each class, non-BSS hunks precede BSS, preserving relative order.
Group zero contains the original entry hunk; other classes follow in
first-occurrence order. There are at most three groups: ANY, CHIP, FAST.
Extended HUNK memory flags remain unsupported.

## Load file

Hunk order is resident group 0, scratch, then remaining resident groups.
Every resident is a HUNK_CODE allocation with its original class in the
size table. Scratch uses MEMF_ANY. Group 0 begins on disk with the normal
trampoline. Other groups need no executable prefix. Each group independently
uses either a disjoint payload in scratch or an overlapping payload directly
after its prefix in the resident hunk. All bodies are longword-padded.

The per-group allocation is at least the prefix size and
`align4(code_data_size + max(bss_size, reloc_stream_size))`. Overlap adds
the same bounds as v0: prefix plus aligned compressed size, and measured
margin plus aligned compressed size. Auto selects overlap when it lowers
that region's contribution to peak memory. Compression streams do not
cross group boundaries. All original allocations coexist until program
exit; packing does not guarantee that arbitrary programs fit a given machine.

## Scratch structure

`mixed.s dispatcher | header | descriptors | selected depacker stub | disjoint payloads`

All integer fields are big-endian. The 44-byte header retains the v0
field offsets through byte 35, with major=1, minor=0. Code/data, BSS,
relocation and compressed sizes are totals over all groups. Backend ID
still identifies one of the existing depackers. Header flags report flash
and killtwitch. At offset 36 is a u32 group count; offset 40 holds the
u32 byte offset of the selected `Depack` entry from scratch's data start.

Each 52-byte group descriptor begins with the existing 36-byte header
shape: its own sizes, flags, overlap margin and prefix size. Its header
size is 52. `HAS_RELOCS` is set; even an empty stream has a terminator.
The embedded decoder receives the descriptor in A2, preserving the existing
flash wrappers' field offsets. Additional u32 fields:

| Offset | Meaning |
|---|---|
| 36 | Runtime resident base, initialized to zero on disk |
| 40 | Input offset from scratch (disjoint) or resident base (overlap) |
| 44 | Destination offset for moving an overlapping payload to the safe tail |
| 48 | Resident allocation size in bytes |

## Relocations and execution

Relocations use a target-group byte (0–2), followed by the v0 half-delta
encoding: 0–253 directly, or 255 followed by four unaligned big-endian
bytes. A standalone 254 in the target position ends the stream. Offsets
are sorted within each source group. The stored addend already includes
the target hunk's offset in its group; runtime adds that group's base.
This format needs a major-version bump because v0 cannot interpret it.

The dispatcher resolves every resident base from the LoadSeg chain before
decoding. For each region it moves any overlapping input backward to the
safe tail, calls the selected depacker, applies relocations, then clears
BSS. It saves D2–D7/A2–A6 outside the legacy depacker wrappers: some wrappers
set flash/parity registers before their own register saves.

Finally it replaces group 0's link to scratch with scratch's next link,
frees scratch using the normal LoadSeg allocation header, and jumps to
group 0. Other residents remain linked for AmigaDOS UnLoadSeg. No extra
full-image buffer is allocated; DEFLATE still uses its small decoder workspace.

## Verification

Host tests load hunks at non-contiguous addresses with allocation guards,
then execute the trampoline, dispatcher and actual depacker under Musashi.
They check cross-region relocation values, BSS, reserved tails, and the
retained chain for all eight depackers, overlap off/on/auto and flash off/on.
`run_mixed_memory_test.py` separately checks real LoadSeg allocation and
execution on a 512 KB Chip + 512 KB Slow A500, including a writable reserved
code tail and Chip-addressable data/BSS. The original input must boot first.
