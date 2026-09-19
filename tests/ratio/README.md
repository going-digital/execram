# Compression regression baseline

Run the same checks used by CI and releases:

```sh
zig build test
zig build -Doptimize=ReleaseFast
python3 tests/ratio/track_ratios.py ./zig-out/bin/execram vasmm68k_mot vlink
```

The baseline covers all thirteen backend choices across eight programs
(104 measurements). Any size increase or missing baseline entry fails the
check. Timing values are informational, not pass/fail criteria. ReleaseFast
avoids spending CI time compressing the real corpus with debug C encoders;
it does not change the selected compression settings.

Set `EXECRAM_RATIO_REPORT=/tmp/ratios.json` to retain measurements without
changing the baseline. Review the differences before accepting an update.
`--update-baseline` remains an explicit maintainer operation.

## September 2026 baseline refresh

The previous baseline was last updated in commit `05076a5`, before the
two-hunk runtime, overlap, and flash changes. CI at `080b2d8` already failed
with 40–120 byte increases on the ordinary-memory synthetic programs.
Those exact increases remain: the single-region runtime bytes did not
change in this fix. Resetting the threshold or ignoring small regressions
would hide future changes, so the strict check is retained with reviewed
current sizes instead.

Mixed-memory `chip_mem`, `hexagon`, and `hexagon2` now use v1: separate
compression streams and resident allocations, a shared dispatcher, and
cross-region relocation records. Their output sizes consequently change.
For example, chip_mem/store is 940 bytes (previous baseline 412); the
additional structure preserves memory placement rather than forcing the
whole program into Chip RAM. Hexagon/zultra is 144672 bytes (previous
baseline 144216); Hexagon/inflate improves to 150360 (previous 150844).
Reserved allocation tails are also retained instead of being silently
lost. These are deliberate correctness costs, verified by CPU-runtime
and FS-UAE tests, not unexplained compressor regressions.

The refresh also adds hexagon2 and the seven previously untracked backend
choices. It was measured with Zig 0.16.0; all nineteen assembled stub
binaries were compared byte-for-byte between local vasm 1.8e and CI's
vasm 2.0f and matched.
