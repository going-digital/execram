# tools/bench: 68000 depack-cycle predictor

This standalone tool reads disjoint, non-flashing v0 packed files using
its original store,
inflate, ZX0 and Shrinkler depackers. For v1 grouped-memory files,
use `execram bench <original-executable>`; it reports the combined cost of
all region depackers and the actual grouped output size.

A dev-only tool (a separate binary from `execram` itself) that
predicts how many real 68000 CPU cycles an *already-packed* executable's
depacker stub takes to run - built around
[Musashi](https://github.com/kstenerud/Musashi) (`src/musashi_vendor/`),
a portable, C-only 68000-68040 CPU-core emulator with no chip/disk/video
timing of its own, via the shared core in `src/musashi_bench.zig`.

That same shared core also powers `execram bench` (`src/main.zig`),
which *does* ship as part of the real `execram` binary: given a raw,
unpacked input, it packs a fresh copy with every backend and prints a
comparison table (size, ratio, decompression cost) for all of them at
once, instead of this tool's one-file-at-a-time, already-packed-input
shape. Use `execram bench` for "which backend should I use on this
program"; use this tool for "how fast does this specific file I already
packed decompress" (or for testing a file this build of `execram` didn't
itself produce).

## Why this exists alongside `tests/uae/`, not instead of it

`tests/uae/` (FS-UAE) remains the tool for *correctness*: booting a
packed program on real emulated Amiga hardware exercises relocation,
`AllocMem`, chip registers, and a genuine AmigaDOS environment - things
this tool never touches at all. But FS-UAE is real-time-paced and, on
at least one development machine this project has been built on,
severely sensitive to host CPU scheduling (a backgrounded/detached
FS-UAE process was observed running at ~1-5% effective speed for over
an hour while the host was otherwise 78% idle - see the git log around
the `hexagon.exe` real-executable test work). That makes it a poor tool
for *timing* comparisons between backends: two runs of the same file
can differ by orders of magnitude for reasons that have nothing to do
with the depacker itself.

This tool sidesteps that entirely: Musashi is a deterministic
CPU-instruction interpreter with no wall-clock dependency at all, so
the same input always yields the exact same cycle count, instantly,
regardless of host load.

## What it measures, precisely

Given a real `execram pack` output file, this tool:

1. Parses the container header exactly the way `execram info` does
   (`src/info.zig`'s `locateHeader`, shared via `src/lib.zig`), to find
   the compressed payload and which stub produced it.
2. Locates that stub's `Depack:` entry point via a vasm `-L` listing
   (`build.zig` assembles one per stub alongside the usual `-Fbin`
   binary, specifically for this - `-Fbin` output alone carries no
   symbol metadata).
3. Loads the stub and payload into Musashi's emulated memory, sets up
   registers exactly per `stubs/common/runtime.i`'s calling convention
   (A0 = payload, A1 = output buffer, D0 = compressed size), and jumps
   straight into `Depack:` - bypassing `Start:`/relocation entirely,
   since those aren't what a backend choice actually changes (a
   minimal fake Exec - `fake_exec.s` - is loaded too, since one stub
   does still call into real `AllocMem`/`FreeMem` from inside its own
   `Depack:`; see below).
4. Runs to completion and sums the exact cycle cost.
5. Cross-checks the emulated output against that backend's own
   independent host-side `decompress` (the same one `execram`'s own
   pack-time self-check uses) - not just a cycle count with no
   correctness guarantee.

## Detecting "the depack routine returned", exactly

This turned out to be the one genuinely subtle part of driving a raw
CPU core (as opposed to a full system emulator, which has its own
concept of "the guest program exited"). The obvious approach - push a
synthetic return address, run in fixed-size cycle bursts, check if PC
reached it - overshoots: `m68k_execute(n)` always finishes whatever
instruction it started even past the requested budget, so once the
real `rts` lands PC exactly on the sentinel *before* that call's own
budget is exhausted, Musashi just keeps decoding whatever bytes happen
to sit there for the rest of that call. A `STOP` instruction at the
sentinel plus "wait for `m68k_execute` to return 0" (reasoning from
`m68ki_execute`'s own source, where a stopped CPU skips its main loop)
turned out not to behave as that reading suggested in practice either -
it kept returning the full requested budget rather than 0, even once PC
had visibly stopped advancing.

The approach that actually works, and the one this tool uses: request
exactly 1 cycle per call (`m68k_execute(1)`), well below any real
68000 instruction's cost, so every single call executes precisely one
instruction - then check PC *before* issuing each next call rather than
trusting the return value. This can never overshoot, by construction:
there is no possible "leftover budget" for a one-cycle request to spend
on unrelated bytes. The one wrinkle: the very first `m68k_execute` call
after `m68k_pulse_reset()` eats a fixed reset-exception cost (~40
cycles for a 68000) before executing anything real, regardless of the
requested budget - a throwaway `m68k_execute(0)` absorbs that outside
the real measurement.

## The fake Exec (`fake_exec.s`)

Every stub's `Depack:` is a pure, self-contained CPU routine exactly
matching `stubs/common/runtime.i`'s contract *except* inflate/zultra's:
it calls real `AllocMem`/`FreeMem` via `ExecBase` (`move.l 4.w,a6`) to
get its own ~2.9KB scratch block, because `inflate.S`'s
`OPT_STORAGE_OFFSTACK` convention needs that memory from somewhere
other than the stack. Confirmed directly, not guessed: with no Exec
library at all, that call jumped into whatever (zeroed) memory sat at
a huge negative offset from a null base, and the CPU spun there
decoding zeros until the step-limit safety valve tripped - while every
other backend already produced an exact cycle count with a verified
`MATCH`.

`fake_exec.s` is a real, if tiny, 68k routine - not a Zig-side special
case - assembled by vasm exactly like a real stub and loaded into a
reserved high region of emulated memory (`0x00700000` up), with
`ExecBase` (address 4) pointed at it. It only ever needs to support
`AllocMem`/`FreeMem`, and only correctly enough for how this harness
actually drives a stub: one isolated `Depack:` call per run, which for
the only stub that calls `AllocMem` at all means exactly one
`AllocMem`+matching `FreeMem` pair, never two overlapping live
allocations. That means a real allocator isn't needed - `AllocMem`
always hands back the same fixed scratch address, and `FreeMem` is a
no-op - see that file's own header comment for the exact memory layout
(the 12-byte gap between the `FreeMem`/`AllocMem` entry points is
architecturally required, not a free choice: it's the real difference
between those two Exec LVO numbers).

Verified with the same rigor as every other backend: an exact cycle
count plus a `MATCH` against inflate/zultra's own host-side
`decompress`, and re-confirmed the other four backends (which never
touch `ExecBase` at all) produce byte-identical cycle counts before
and after this was added.

## Known limitations

Musashi models CPU instruction timing only - it has no concept of Chip
RAM DMA bus contention (the copper, blitter, audio, and disk DMA all
steal bus cycles from the CPU on real hardware, especially when code
and data are resident in Chip RAM, which most depackers are). This
tool's cycle counts are therefore a **best-case lower bound**, useful
for comparing backends against each other on equal footing, not a
prediction of exact real-hardware wall-clock time. `tests/uae/` remains
the source of truth for anything that needs to be exactly right,
including timing claims that matter.

## Usage

```sh
zig build bench -- path/to/packed.exe
```

Builds `execram-bench` (always native/host target, `ReleaseFast`
regardless of the main build's `-Doptimize` - a full real-executable
depack under single-instruction-stepped emulation runs many times
slower under a Debug-mode interpreter) and runs it against the given
file.
