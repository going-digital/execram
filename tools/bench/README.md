# tools/bench: 68000 depack-cycle predictor

A dev-only tool, separate from the shipped `execram` binary, that
predicts how many real 68000 CPU cycles a packed executable's depacker
stub takes to run - built around
[Musashi](https://github.com/kstenerud/Musashi) (`src/musashi_vendor/`),
a portable, C-only 68000-68040 CPU-core emulator with no chip/disk/video
timing of its own.

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
   straight into `Depack:` - bypassing `Start:`/`AllocMem`/relocation
   entirely, since those aren't what a backend choice actually changes.
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

**The `inflate`/`zultra` stub doesn't work with this tool yet.** Every
other backend's `Depack:` is a pure, self-contained CPU routine exactly
matching `stubs/common/runtime.i`'s contract - jumping straight into it
with no surrounding OS environment is enough. `stubs/inflate/stub.s`'s
`Depack:` isn't: it calls real `AllocMem`/`FreeMem` via `ExecBase`
(`move.l 4.w,a6`) to get its own ~2.9KB scratch block, because
`inflate.S`'s `OPT_STORAGE_OFFSTACK` convention needs that memory from
somewhere other than the stack. This harness provides no `ExecBase`,
no Exec library, nothing at address 4 - so that call jumps into
whatever (zeroed) memory sits at a huge negative offset from a null
base, and the CPU spins there, decoding zeros, until the step-limit
safety valve trips (`error: DepackNeverReturned`). Confirmed to be
exactly this, not a cycle-counting bug: every other backend produces
an exact cycle count with a verified `MATCH` against that backend's
own host-side `decompress`.

Fixing this needs a minimal fake Exec: a tiny hand-written `AllocMem`/
`FreeMem` implementation (a bump allocator over a fixed scratch region
is enough - inflate never frees anything it can't immediately give
back) installed at the `EXEC_AllocMem`/`EXEC_FreeMem` offsets from
whatever address `ExecBase` (read from address 4) is set to point at,
plus writing that pointer into the emulated memory before jumping into
`Depack:`. Not yet done - out of scope for what this tool needed to
prove first (the cycle-counting technique itself, and that it works
end to end for three of the four backend families).

## Usage

```sh
zig build bench -- path/to/packed.exe
```

Builds `execram-bench` (always native/host target, `ReleaseFast`
regardless of the main build's `-Doptimize` - a full real-executable
depack under single-instruction-stepped emulation runs many times
slower under a Debug-mode interpreter) and runs it against the given
file.
