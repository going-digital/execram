# execram — Project Plan

**execram** is an executable compressor/cruncher for Amiga programs, in the
spirit of [Shrinkler](https://github.com/askeksa/Shrinkler): it takes an
AmigaDOS hunk executable, compresses it, and glues on a tiny 68000
decompressor stub so the result is a self-extracting executable that
decompresses itself in memory and jumps to the original entry point.

Unlike Shrinkler (which hardcodes one LZMA-like algorithm), execram is built
around a **pluggable backend** design from day one, so multiple compression
algorithms can target the same container/stub-loading mechanism:

- **Inflate** (DEFLATE) — depacker reference: Keir Fraser's
  [inflate.S](https://github.com/keirf/Amiga-Stuff/blob/master/inflate/inflate.S)
- **ZX0** (Einar Saukas) — host compressor:
  [ZX0](https://github.com/einar-saukas/ZX0), depacker reference:
  [unzx0_68000](https://github.com/emmanuel-marty/unzx0_68000)
- **Shrinkler-class** — an original LZMA-like optimal-parse + range-coder
  backend, matching Shrinkler's ratio class without reusing its (GPL) code

Decisions locked in for this plan:

- **Host tool language:** Zig 0.16
- **Backend build order:** Inflate → ZX0 → Shrinkler-class

---

## 1. Goals

- Compress AmigaDOS hunk executables and produce a smaller self-extracting
  executable that runs correctly on real 68000 Amigas (and emulators).
- Support several interchangeable compression backends behind one CLI and
  one container/stub-loading convention, selectable per-run or via
  `--backend=auto` (try all, keep the smallest working result).
- Match or approach Shrinkler-class ratios eventually, without depending on
  or redistributing Shrinkler's own (GPL) code.
- Keep the runtime decompressor stubs hand-tuned for size and speed, since
  they run on real 68000s in chip RAM before the program's own code exists.

## 2. Non-goals (v1)

- Overlay-hunk executables (`HUNK_OVERLAY`) — detect and reject with a clear
  error rather than silently mishandling them.
- Resident-library / multi-segment loader tricks beyond a single merged
  load segment (Shrinkler itself has the same restriction).
- GUI — CLI only.
- AmigaOS-native build of the host tool — it runs on the developer's
  machine (macOS/Linux/Windows), cross-targeting the Amiga executable it
  produces. An AmigaOS-native port is future work, not v1.

## 3. Prior art & licensing — must be resolved before any code is vendored

This is the highest-leverage early task, because it determines *how* each
backend gets built (adapt existing source vs. clean-room reimplementation
from a written algorithm description):

**Audited 2026-09-11 — see [`docs/LICENSES.md`](docs/LICENSES.md) for exact
license text and commit hashes.** Headline result, which corrects the
assumption this plan started with: **Shrinkler is not GPL.** Its depacker
(`ShrinklerDecompress.S`) is public-domain-equivalent, and the rest of the
codebase is a permissive attribution-only license (no copyleft). No
component here requires clean-room reimplementation on legal grounds.

| Component | Role | License (verified) | Vendor/adapt OK? |
|---|---|---|---|
| Shrinkler — general codebase | design/engineering reference | Custom permissive (own text) | Yes — include `LICENSE.txt` in source dist, don't misattribute in binary dist |
| Shrinkler — `ShrinklerDecompress.S` | depacker reference for M4 | Public-domain-equivalent | Yes — no obligations |
| ZX0 (einar-saukas/ZX0) | host compressor + 68k depacker reference | BSD-3-Clause (compressor) / zlib (depacker) | Yes — retain notices |
| unzx0_68000 (emmanuel-marty) | 68k depacker reference | zlib | Yes — retain notice, don't misrepresent origin |
| Keir Fraser's Amiga-Stuff `inflate.S` | 68k depacker reference | Unlicense (public domain) | Yes — no obligations |
| vasm | build-time assembler dependency | Custom (free for M68k/AmigaOS commercial use — our exact case) | Use as an external tool only; don't vendor the tool itself |

Practical upshot for the milestones below: each backend may adapt or port
existing source directly (keeping the relevant notice in
`docs/algorithm-notes/` and in the stub source itself) rather than requiring
a from-scratch reimplementation. Clean-room design is now an engineering
choice, not a legal requirement — see the M4 update below.

## 4. Architecture

```
                     ┌───────────────────────────┐
 input.exe  ───────► │ execram (Zig host tool)   │
 (AmigaDOS hunks)     │                           │
                     │  1. hunk.zig  (parse)     │
                     │  2. flatten.zig           │
                     │     merge hunks + build   │
                     │     flat reloc stream     │
                     │  3. backend (pick one):   │
                     │     store / inflate / zx0 │
                     │     / shrinkler-class     │
                     │  4. stub.zig              │
                     │     patch + embed the     │
                     │     matching 68k depacker │
                     └──────────────┬────────────┘
                                    ▼
                     output.exe (self-extracting):
                     [ HUNK_CODE: depacker stub ]
                     [ HUNK_DATA: compressed blob ]
                     [ HUNK_BSS:  decompress buffer ]
```

- **Backend interface** (`backend.zig`): `compress(flat_image) -> bytes` on
  the host side, paired with a fixed stub id so `stub.zig` knows which
  pre-assembled 68k binary to embed and how to patch its parameter table
  (original size, packed size, entry offset, memory requirements).
- **68k stubs are hand-written assembly**, assembled at build time by
  **vasm** (invoked as a Zig build step), and embedded into the host
  binary via `@embedFile` on the assembled raw binary — not generated by
  Zig's own codegen (Zig has no mature AmigaOS/m68k target).
- **Container format**: our own small header (magic, backend id, original
  size, packed size, load-address flags CHIP/FAST, safety margin) —
  documented in `docs/format-spec.md`, versioned from the start so old
  execram-packed executables stay decodable by future stub revisions.
- **In-place decompression safety margin**: like Shrinkler, decompression
  writes backward/overlapping into the same buffer the compressed data
  occupies; each backend must publish a worst-case expansion-per-byte
  figure so the host tool can size the safety margin correctly. Until a
  backend's margin math is verified, decompress into a separate buffer.

## 5. Proposed repo layout

```
/build.zig, /build.zig.zon      Zig 0.16 project
/src/
  main.zig                      CLI entry (pack / info)
  hunk.zig                      AmigaDOS hunk parser/writer
  flatten.zig                   hunk merge + reloc flattening
  backend.zig                   backend trait/interface + registry
  backends/
    store.zig                   no-op backend (M1 baseline)
    inflate.zig                 DEFLATE encoder (M2)
    zx0.zig                     ZX0 optimal-parse compressor (M3)
    shrinkler.zig                original LZMA-like backend (M4)
  stub.zig                      embeds + patches the matching 68k stub
/stubs/                         68k assembly, built with vasm
  common/                       shared macros (exec calls, cache flush, etc.)
  inflate/depack.s
  zx0/depack.s
  shrinkler/depack.s
/tests/
  corpus/                       sample hunk executables (rights-cleared)
  roundtrip/                    host-side pack+verify tests
  uae/                          FS-UAE headless boot-test scripts
/docs/
  LICENSES.md
  format-spec.md
  hunk-format-notes.md
  algorithm-notes/              one file per backend
PROJECT_PLAN.md                 this file
```

## 6. Toolchain

- Zig 0.16 (host tool + build system)
- vasm (Motorola syntax, m68k-amiga target) for all 68k stub assembly,
  invoked from `build.zig`
- FS-UAE (or WinUAE) + a legally-sourced Kickstart ROM, for integration
  testing — headless where possible, driven by scripts under `/tests/uae`
- GitHub Actions CI: `zig build`, `zig build test`, plus a UAE smoke-test
  job once M1 lands

## 7. Milestones

**M0 — Foundations** (~1–2 weeks)
- ~~License audit~~ ✅ done — see [`docs/LICENSES.md`](docs/LICENSES.md)
- ~~Repo scaffold~~ ✅ done — Zig 0.16 project (`build.zig`/`build.zig.zon`),
  GitHub Actions CI (`ubuntu-latest` + `macos-latest`, builds vasm from
  source since it isn't vendored — see licensing note)
- ~~vasm wired into the Zig build~~ ✅ done — `build.zig` assembles each
  `stubs/<name>/*.s` with vasm into a raw binary and embeds it via
  `@embedFile`; proven end to end with a placeholder stub
  (`stubs/example/hello.s`) and a unit test asserting the exact bytes
- ~~Container/stub format v0 documented~~ ✅ done — see
  [`docs/format-spec.md`](docs/format-spec.md): header layout, the
  code+data/BSS/reloc-stream split that keeps backends reloc-agnostic,
  the v0 runtime algorithm (always a separate scratch+final buffer, no
  safety margin needed yet), and what's still unsettled going into M1
- ~~FS-UAE test harness bootstrapped~~ ✅ done — `tests/uae/run_boot_test.sh`
  assembles a bare-metal boot block (`tests/uae/boot/sentinel.s`, no
  filesystem/Exec/DOS dependency), packs it into a bootable ADF, boots it
  under FS-UAE against a real Kickstart ROM, and checks a sentinel string
  on the emulated serial port — passing end to end against Kickstart 1.3.
  Local/dev-only by necessity: Kickstart ROMs are copyrighted and can't be
  committed or fetched in public CI (see `docs/LICENSES.md` §7 and
  `tests/uae/README.md`). Later milestones point this same mechanism at
  actual execram-packed executables instead of the sentinel.

**M1 — Hunk engine + store backend** (~2–3 weeks)
- ~~`hunk.zig`~~ ✅ done — parses HUNK_HEADER/CODE/DATA/BSS/RELOC32/
  SYMBOL/DEBUG/END; rejects HUNK_OVERLAY, subset load ranges, extended
  memory flags, and RELOC16/8/RELOC32SHORT (all explicit v0 non-goals,
  not silently mishandled). Tested against a real vlink-linked executable
  (`tests/fixtures/basic.s`, assembled+linked at `zig build test` time —
  see `docs/LICENSES.md` §5 for vlink's license, same terms as vasm),
  not just hand-rolled bytes, so the parser is checked against another
  tool's independent understanding of the format.
- ~~`flatten.zig`~~ ✅ done — merges non-BSS hunks into one code_data
  buffer (stable-reordered so BSS ends up contiguous at the tail
  regardless of original hunk order), folds each relocation's
  target-hunk offset into the stored value at flatten time (so the
  runtime stub only ever needs to add one thing: the final load
  address), and encodes the result per `docs/format-spec.md` §7. Tested
  against the same real fixture as `hunk.zig`, with hand-computed
  expected byte values, plus synthetic negative-path tests for
  out-of-range/misaligned relocations.
- ~~`store` backend + host-side writer + `pack` CLI~~ ✅ done —
  `src/backends/store.zig` (no compression, just concatenates code_data
  ++ reloc_stream), `src/container.zig` (serializes the v0 header and
  wraps it as a single-hunk AmigaDOS load file), `stubs/store/stub.s` +
  `stubs/common/{runtime.i,header.i}` (the 68k runtime: header parsing,
  AllocMem, depack, copy, reloc-fixup, jump - shared skeleton any future
  backend's stub includes). `execram pack` is wired up and working.
- ~~**Deliverable**~~ ✅ done and verified two ways:
  1. Byte-level: packing a real fixture and hand-checking every header
     field and every relocated value against independently computed
     expected bytes (both matched exactly, first try, once the Zig side
     was right).
  2. **Real hardware/emulation**: `tests/uae/run_e2e_test.sh` builds
     execram, packs a test program with both a cross-hunk and a
     self-hunk relocation, and boots the packed program's stub under
     FS-UAE against a real Kickstart ROM - it only prints its sentinel
     correctly if decompress+allocate+relocate+jump all actually
     worked. This caught a real bug (`StubEnd` pointing at the wrong
     address - see `tests/uae/README.md`) that the byte-level check
     alone couldn't have, since it never executed the stub's own code.

**M2 — Inflate backend** ✅ done
- ~~Host-side raw-DEFLATE encoder~~ — used Zig's own standard library
  (`std.compress.flate.Compress`, `.raw` container), no vendoring
  needed. `src/backends/inflate.zig`; tested by round-tripping through
  Zig's own `Decompress` as an independent check that the output is
  valid DEFLATE, not just "assembled without erroring."
- ~~Depacker stub adapted from `inflate.S`~~ — done, with real
  engineering surprises along the way (see
  `stubs/inflate/README.md`): the upstream file is written for a real
  C-preprocessor pass and a GNU-as dialect vasm's `mot` module can't
  parse at all, and vasm's `std` module (used instead) turned out to
  only support single-digit numeric local labels and not resolve them
  correctly inside macros regardless — worked around by disabling one
  upstream optimization option (`OPT_INLINE_FUNCTIONS`, ~15% speed
  cost, upstream's own documented figure) so the two affected macros
  are used exactly once each, then hand-inlining them with named labels
  instead of vasm's macro mechanism. Needed a std-syntax port of the
  shared `runtime.i`/`header.i` skeleton too, since vasm's syntax
  module can't be mixed within one assembly — accepted as contained,
  documented duplication rather than a fragile cross-file-linking
  scheme.
- Safety-margin verification for in-place decompression — still
  deferred, per `docs/format-spec.md` §8's v0 scope (separate
  scratch+final buffers, no margin needed yet); unchanged by this
  milestone.
- ~~**Deliverable**~~ ✅ `execram pack --backend=inflate` works and
  produces correctly-booting executables, verified the same two ways as
  M1's store backend: byte-level (Zig's own `Decompress` round-trip) and
  **real hardware/emulation** (`tests/uae/run_e2e_test.sh
  EXECRAM_TEST_BACKEND=inflate` boots the packed test program under
  FS-UAE against Kickstart 1.3 and confirms it prints its sentinel via a
  correctly-relocated pointer). That real-hardware test needed its own
  new tooling (`tests/uae/e2e/loader.s`, a disk-reading boot loader,
  since the inflate stub alone is already bigger than the 1024-byte
  boot block the M1 test's simpler embed-everything approach used) and
  caught a real bug in it (`trackdisk.device`'s `CMD_READ` needs a
  sector-aligned length) - see `tests/uae/README.md`.
- ~~**Ratio/speed benchmark numbers**~~ ✅ done (after M3, see below) —
  `tests/uae/run_large_e2e_test.sh` and `tests/uae/e2e_large/`.

**M3 — ZX0 backend** ✅ done
- ~~Vendor/port ZX0's optimal-parse compressor~~ — vendored unmodified
  (`src/backends/zx0_vendor/`, BSD-3-Clause), called via Zig's C
  interop (`@cImport`) rather than reimplementing the optimal-parse
  algorithm. One deliberate patch: `optimize.c`'s progress-dot
  `printf`/`fflush(stdout)` calls are removed - they don't just clutter
  our own CLI's output, they actively **deadlocked `zig build test`**,
  since raw stdout bytes corrupt the same channel Zig's test runner
  protocol uses to talk to the test binary. Found by sampling both
  processes' stacks mid-hang (both blocked waiting to read a message
  the other would never send) and tracing it to that printf - see
  `src/backends/zx0_vendor/optimize.c`'s comment.
- ~~Adapt `unzx0_68000` as the depacker stub~~ — the easiest of the
  three so far: already plain Motorola/Devpac syntax (no dialect
  workaround needed, unlike inflate), and its calling convention (A0 =
  input, A1 = output, preserves A2) already matches `runtime.i`'s
  contract almost exactly. One deliberate change: renamed the entry
  label to `Depack`.
- ~~`--backend=auto`~~ — tries every backend, keeps the smallest
  output. Confirmed correctly picking `store` for the tiny hand-written
  e2e test program (256B input; inflate/zx0's fixed stub overhead
  exceeds any compression benefit at that size, as flagged as an open
  question back in M2).
- ~~**Deliverable**~~ ✅ three working backends, each verified the same
  two ways as M1/M2 (byte-level + a real FS-UAE boot of the packed test
  program under Kickstart 1.3).

**Benchmark comparison report** ✅ done, closing the gap flagged at the
end of M2 (and again above) - `tests/uae/e2e_large/gen_large_program.py`
generates a genuinely larger test program (several KB of real prose,
22 relocations - 20 self-hunk, 2 cross-hunk - instead of two or three),
and `tests/uae/run_large_e2e_test.sh` packs it with every backend and
boots whichever one you ask for, diffing the *entire* serial transcript
against a byte-exact expected file rather than grepping for one
sentinel line. Real numbers, all three backends confirmed passing that
exact-match boot test on this program:

| backend | packed size | % of original (5784B) |
|---|---:|---:|
| store   | 5480 B | 94.7% |
| inflate | 3620 B | 62.6% |
| zx0     | 2928 B | 50.6% |

zx0 beats inflate by a wide margin here, consistent with its reputation
in the demoscene/cruncher space generally. `store`'s "compression" is
really just discarding the original hunk file's symbol table and
per-hunk headers - a reminder that even the no-compression baseline
isn't a no-op once hunks are merged.

Building the larger test program surfaced one real bug - in the test
harness, not the pack pipeline: `tests/uae/boot/pty_bridge.py`'s pty was
left in default "cooked" tty mode, whose ONLCR translation turns every
outgoing `0x0A` into `0x0D 0x0A`. Invisible to every earlier sentinel-
substring check, but a real difference under this test's byte-exact
comparison. Confirmed as a harness-only artifact (not a decompression or
relocation defect) and fixed - see `tests/uae/README.md`.

**Zultra — an alternative "inflate" compressor** ✅ done (unplanned
addition, between M3 and M4) - vendored
[emmanuel-marty/zultra](https://github.com/emmanuel-marty/zultra), "a
fast deflate implementation with zopfli-like ratios." Because it
produces standard raw DEFLATE, it needed **no new depacker stub or
backend_id at all** - `--backend=zultra` reuses `inflate`'s exact stub
and container, just with a stronger host-side encoder feeding it. On
the large test program (`tests/uae/e2e_large/`): 3556 bytes vs. plain
`inflate`'s 3620 (61.5% vs. 62.6% of the 5784-byte original) - a real
but modest improvement, and still well behind zx0's 2928 (50.6%),
consistent with DEFLATE's format ceiling relative to ZX0's design.
Verified the same two ways as every other backend: byte-level (Zig's
own `Decompress` round-trip in `src/backends/zultra.zig`'s test) and
real hardware (both `tests/uae/run_e2e_test.sh` and the byte-exact
`run_large_e2e_test.sh` pass with `EXECRAM_TEST_BACKEND=zultra`,
confirming the *existing, unmodified* inflate stub correctly
decompresses Zultra's output - exactly the compatibility claim this
integration rested on). See `src/backends/zultra_vendor/README.md` and
`docs/LICENSES.md` §6.

**Salvador — an alternative "zx0" compressor** ✅ done (unplanned
addition, between M3 and M4) - vendored
[emmanuel-marty/salvador](https://github.com/emmanuel-marty/salvador),
"a free, open-source compressor for the ZX0 format," from the same
author as `unzx0_68000`. Because it produces the same ZX0 v2
("inverted") format - confirmed directly by diffing salvador's own
bundled 68k depacker against `stubs/zx0/unzx0_68000.s` and finding them
byte-identical, not just assumed - it needed **no new depacker stub or
backend_id at all**: `--backend=salvador` reuses `zx0`'s exact stub and
container, just with a different (also optimal-parse) host-side
compressor. On the large test program (`tests/uae/e2e_large/`): 2928
bytes, identical to plain `zx0`'s 2928 (50.6% of the 5784-byte
original) - both are optimal-parse ZX0 compressors, so matching output
on this input is the expected result, not a bug. Verified the same two
ways as every other backend: byte-level (a real compress-then-decompress
round-trip through salvador's own vendored decompressor in
`src/backends/salvador.zig`'s test - stronger rigor than the original
zx0 backend's test had, since no host-side ZX0 decoder existed in this
project yet at that point) and real hardware (both
`tests/uae/run_e2e_test.sh` and the byte-exact `run_large_e2e_test.sh`
pass with `EXECRAM_TEST_BACKEND=salvador`, confirming the *existing,
unmodified* zx0 stub correctly decompresses Salvador's output).
Vendoring it also surfaced a genuine build-system issue: it bundles its
own fork of the MIT-licensed `libdivsufsort` suffix-array library,
independently forked from the *different* copy already vendored inside
`zultra_vendor/` - both define the same 12 global C symbols, which
collided at link time once both were compiled into one binary; fixed
by renaming only Salvador's copy via compiler `-D` flags (see
`build.zig`), no source edits needed. See
`src/backends/salvador_vendor/README.md` and `docs/LICENSES.md` §7.

**libdeflate — another alternative "inflate" compressor** ✅ done
(unplanned addition, post-v1.1.0, [issue #1](https://github.com/going-digital/execram/issues/1))
- vendored [ebiggers/libdeflate](https://github.com/ebiggers/libdeflate)'s
raw-DEFLATE compressor at max level (`src/backends/libdeflate_vendor/`).
Same shape as Zultra: standard raw DEFLATE, so **no new stub or
backend_id** - `--backend=libdeflate` reuses `inflate`'s stub. Measured
on two corpus programs:

| backend | hexagon.exe | hexagon2.exe |
|---|---:|---:|
| inflate | 149656 B | 149562 B |
| libdeflate | 143772 B | 143780 B |
| zultra | 143029 B | 142871 B |

~0.5% behind zultra, well ahead of `inflate` - kept as a real
alternative but not folded into `--backend=most`'s two-backend set on
this small a sample; added to `execram bench`'s default set instead.
Verified by round-trip test + `pack -v` self-check; **not yet
real-hardware tested** (no FS-UAE/ROM in this environment) - lower risk
than a new stub since the depacker is unchanged, but
`EXECRAM_TEST_BACKEND=libdeflate tests/uae/run_e2e_test.sh` is still the
bar before a release. See `docs/LICENSES.md` §12.

**Zopfli — a third alternative "inflate" compressor** ✅ done (same
issue #1) - vendored [google/zopfli](https://github.com/google/zopfli)'s
core (`ZopfliDeflate()` directly, no framing/CLI). Issue #1 named
`zopfli-rs` (Rust), but that crate has no C ABI - wrapping it would mean
a `cargo` build step and Rust cross-compilation in CI, a second
toolchain this project doesn't need. Vendored the original C reference
instead: same algorithm, drops into the same pattern. No new stub;
also applied issue #1's own suggestion (`PatchDistanceCodesForBuggyDecoders`
turned into a no-op - execram's own depacker isn't one of the decoders
it exists to placate).

| backend | hexagon.exe (packed) | hexagon2.exe payload |
|---|---:|---:|
| zultra | 144236 B | 142871 B |
| zopfli | 144172 B | 142911 B |
| libdeflate | 144976 B | 143780 B |

A statistical tie with zultra (each wins one file by tens of bytes),
both ahead of libdeflate - a genuine third contender, left out of
`most` for now, added to `bench`'s default set. Vendoring surfaced one
portability wrinkle: `lz77.c`'s word-at-a-time match compare
(`*(size_t*)ptr`, same trick glibc's `memcmp` uses) is safe on every
real target but trips Zig's Debug-build UBSan alignment trap -
suppressed with `-fno-sanitize=alignment` in `build.zig`, same fix
category as `shrinkler_shim.cpp`'s `-fno-sanitize=shift`. Same
verification status as libdeflate above (round-trip + self-check
verified, real-hardware pending). See `docs/LICENSES.md` §14.

**Huffman-relength prototype** ❌ built, verified, measured no benefit,
removed. Issue #1's second half (DeflOpt/defluff/deft4j-turtledeflate/
columbo - post-compression DEFLATE recoding) exists to recover bits
from a compressed artifact when the *original data is gone*; execram
never loses that data, so most of what those tools do is already
subsumed by running a stronger encoder directly. The one technique
still valid with source in hand: decode a stream back to tokens,
recompute provably-optimal Huffman lengths via package-merge (reused
the vendored Zopfli's own `katajainen.c`), re-emit if smaller. Built as
`src/deflate_relength.zig` (a full from-scratch DEFLATE codec), wired
into every inflate-family backend, every candidate independently
verified via Zig's own decoder before use - correctness held up,
27/27 tests passed. But measured across all four backends on both
corpus files: **zero net improvement, every time**. inflate/zultra/
libdeflate/zopfli already produce Huffman-length-optimal-or-tied
output for their own token streams - DeflOpt-class tools earn their
keep against *weak* encoders, and nothing here is weak that way.
Removed rather than shipped as dead weight; see `docs/LICENSES.md`
§13's addendum for the fuller account.

**LZ4 — a speed-over-ratio backend (lz4small/lz4normal/lz4fast)** ✅
done (unplanned addition, post-v1.1.0) - one host-side compressor
(vendored `lz4/lz4`'s `LZ4_compress_HC()` at its own max level,
`src/backends/lz4.zig`) paired with three independent depackers
(vendored arnaud-carre/lz4-68k, MIT), each trading depacker code size
for decompression speed rather than the usual ratio-vs-compression-time
trade-off every other backend here makes. Unlike every prior addition,
these three aren't alternative encoders sharing one depacker - they're
one encoder, three genuinely different depackers - so each got its own
`backend_id` (4/5/6, `src/container.zig`) instead of sharing one the
way zultra/libdeflate/zopfli share `inflate`'s.

Real numbers, `execram bench` on `tests/corpus/hexagon.exe`:

| backend | packed size | ratio | decompress cycles |
|---|---:|---:|---:|
| lz4small | 169100 B | 76.5% | 8,880,674 |
| lz4normal | 169208 B | 76.5% | 6,792,426 |
| lz4fast | 172748 B | 78.1% | 4,042,114 |
| zultra (for reference) | 144236 B | 65.2% | 43,928,880 |

Confirms the whole premise: identical payload bytes across all three
(only stub-size overhead moves the packed-size column), lz4fast
decompresses ~2.2x faster than lz4small (matching upstream's own
~2.36x claim on different test data), and even the slowest LZ4 variant
is ~5x cheaper to decompress than zultra - at a real ratio cost (LZ4's
own format ceiling is well behind DEFLATE/ZX0/Shrinkler's). Not
included in `--backend=most` (ratio is the wrong axis for this
backend to compete on); added to `execram bench`'s default set so the
trade-off is visible without a special flag.

`lz4_normal.asm` needed one mechanical fix: two `repeat 15 { ... }`
blocks upstream wrote that `vasmm68k_mot` doesn't support, unrolled by
hand into 15 literal copies each - verified byte-for-byte (the
unrolled file assembles to exactly upstream's documented 180 bytes).
All three depackers also needed real adapter code, unlike
`unzx0_68000.s`: none preserve D2-D7/A2-A6 natively (several are
treated as scratch), so each stub wraps the raw entry point in a
`movem.l`/`bsr.w`/`movem.l` save-restore pair rather than auditing
each variant's exact clobber set.

Verified by the same host-side round-trip test every backend has
(`src/backends/lz4.zig`, via the vendored library's own real
`LZ4_decompress_safe()`, not a hand-written reference decoder), by
`execram pack -v`'s self-check on both corpus files, and - unlike
libdeflate/Zopfli, which only got the host-side checks above - **on
real hardware**, for all three variants: `run_e2e_test.sh` and the
byte-exact `run_large_e2e_test.sh` (real cross-hunk/self-hunk
relocations, exact 4945-byte transcript match), the full
`run_corpus_test.sh` matrix (no_relocs/chip_mem/bss_heavy/incompressible
- 12/12 passed, including real Chip RAM residency and BSS-zero-clear
checks), and `run_real_exe_test.sh` against both real corpus programs
via a genuine AmigaDOS launch (hexagon.exe/hexagon2.exe, 626
relocations each - 6/6 passed). One real environment finding along the
way, worth recording since it cost real debugging time: the
FS-UAE build bundled with the Bartman VSCode Amiga-debug extension is
an x86_64 binary that only runs via Rosetta on this Apple Silicon
Mac, and under that build the emulated CPU never produced any serial
output at all even after 100+ real seconds - not just "slow," genuinely
stuck (cause not fully isolated - possibly a debugger-oriented build
defaulting to a paused/attached-wait state, given its own
`--version` output identifies as `remote_debug`). The native, non-Rosetta
`/Applications/FS-UAE.app` (the project's own documented default path)
booted the plain sentinel test correctly in a few seconds, and every
lz4 test above ran cleanly under it - a real lesson for this
environment: prefer the native FS-UAE.app over the debugger-extension's
bundled copy for these tests. See `stubs/lz4/README.md`, `src/backends/lz4_vendor/README.md`,
and `docs/LICENSES.md` §15/§16.

**zx0fast / salvadorfast — a faster ZX0 depacker** ✅ done (unplanned
addition, in response to a user-supplied lead: Chris Hodges/Platon42's
fork of `unzx0_68000`). Same shape as the LZ4 trio: `zx0`'s and
`salvador`'s exact host encoders (byte-identical payload either way),
paired with a different depacker stub - own `backend_id` (7), not a
shared one, matching the rule LZ4 established. The fork restructures
`unzx0_68000.s` to inline `get_elias` at each of its four call sites
instead of sharing one `bsr`/`rts` subroutine.

Evaluated before integrating (per the same "measure, don't assume" bar
as libdeflate/Zopfli/LZ4): built as a temporary, uncommitted stub,
verified correct via host-side self-check and the full real-hardware
suite, measured against the current stub via `execram bench`, then
integrated only once the numbers held up. Real numbers,
`tests/corpus/hexagon.exe`:

| | depacker size | full stub | packed size | decompress cycles |
|---|---:|---:|---:|---:|
| `unzx0_68000.s` (zx0/salvador) | 88 B | 288 B | 156532 B | 18,594,000 |
| `unzx0_68000_fast.s` (zx0fast/salvadorfast) | 138 B | 352 B | 156596 B | 14,424,900 |

~29% fewer decompression cycles for 64 more bytes in the packed
output - not smaller (the fork's own README claims ~50% on different
test data; this project's own measurement is the number to trust for
this corpus), a genuine speed-vs-size trade like the LZ4 trio, not a
strict win. One real constraint worth flagging: the fork's own header
documents narrowing several internal 32-bit accumulators to 16-bit as
part of the same optimization, capping any single literal-run or match
length at 65535 - not a concern for any program tried so far, but a
genuine limit `unzx0_68000.s` doesn't have. Not added to
`--backend=most` (same reasoning as the LZ4 trio: this is a
speed decision for the packed program's own author, not something
`most` should decide); `salvadorfast` added to `execram bench`'s
default set (fast to compress, gives the real comparison against
`salvador`), `zx0fast` excluded from it for the same reason plain `zx0`
already is (redundant decompression-cost info at a vastly slower
compress time - it now shares `salvadorfast`'s exact decompression
cost, not `salvador`'s).

Verified on real hardware, not just host-side: byte-exact
`run_large_e2e_test.sh` for both `zx0fast` and `salvadorfast`, the full
`run_corpus_test.sh` matrix (8/8), and `run_real_exe_test.sh` against
both real corpus programs via genuine AmigaDOS launches. One
provenance wrinkle: the upstream repo lives on Chris Hodges' own Gitea
instance (`git.platon42.de`), which rejected an anonymous `git clone`;
the vendored copy was sourced from a Wayback Machine snapshot of the
same file instead (extracted from the rendered source-view HTML, not a
raw diff) and independently verified by reassembling it to the exact
byte size the fork's own README claims (138 bytes) before trusting it
further - see `docs/LICENSES.md` §17 for why no commit hash is pinned
the way every other entry there is.

**Branch-size peephole audit** ✅ done - a user-prompted question ("any
possible peephole optimisations to reduce 68000 code size?") turned
into a full audit of every stub in the project via vasm's own
assembled listings (real measured branch distances, not guesswork).
Two findings:

- `stubs/common/runtime.i` (and its std-syntax mirror,
  `runtime_std.i`) had three `.w` branches whose real targets measure
  well inside short-branch range (124/114/48 bytes) - `.s` instead,
  6 bytes off *every* backend's stub, since this file is `include`d by
  all of them. Every wrapper stub with an internal
  `movem.l`/`bsr.w <vendored routine>`/`movem.l` pattern
  (`zx0fast`/`salvadorfast`, `lz4small`/`lz4normal`/`lz4fast`,
  `shrinkler`, `inflate`) had the same opportunity on that one call (6-8
  bytes away), 2 more bytes each.
- `stubs/inflate/inflate_core.s` (vendored Keir Fraser DEFLATE decoder,
  Unlicense/public domain): 34 of 45 `.w` branches were short-range-
  eligible, and fixing them exposed 2 more once the code shrank around
  them (three passes to a fixed point) - **72 bytes** total, on the one
  stub shared by `inflate`/`zultra`/`libdeflate`/`zopfli`. The file's
  own header explains why: upstream's real source uses GNU-as's
  auto-sizing `j<cc>` pseudo-branches, and the past adaptation to
  vasm's std module made them explicit as the always-safe `.w` form
  rather than computing which ones a byte displacement reaches - this
  fix restores what the auto-sizing assembler would have chosen.
  Checked every *other* vendored file the same way
  (`unzx0_68000.s`/`unzx0_68000_fast.s`, all three `lz4*.asm` variants,
  `ShrinklerDecompress.s`) and found zero opportunities in any of them
  - already hand-tuned by their original demoscene authors.

Net effect on `tests/corpus/hexagon2.exe`: `store`/`zx0`/`salvador`
-6 B, `zx0fast`/`salvadorfast`/`lz4small`/`lz4normal`/`lz4fast`/
`shrinkler` -8 B, `inflate` -80 B (6 + 2 + 72). Applies to every future
packed executable, for free, with no ratio or format change at all -
purely a smaller stub. Verified: every stub reassembles without a
"branch out of range" error (vasm's own hard stop against exactly the
mistake this kind of edit risks), the full host-side self-check suite
(25/25), byte-exact `run_large_e2e_test.sh` on all seven affected
backends, and `run_real_exe_test.sh` against both real corpus programs
on all seven (14/14) - `inflate` specifically, since it carries by far
the largest and most structurally complex change here.
- License audit (§3) confirmed Shrinkler's depacker (`ShrinklerDecompress.S`)
  is public-domain-equivalent and the rest of its codebase is permissive
  attribution-only — so this backend directly adapts/ports Shrinkler's
  actual compressor and depacker asm (crediting per `docs/LICENSES.md`),
  not a clean-room reimplementation from the algorithm description.
- ~~Host: LZ77 + adaptive range coder + context modeling + optimal
  parsing~~ — vendored Shrinkler's own C++ cruncher core
  (`src/backends/shrinkler_vendor/`, zlib license), called through a
  thin C-linkage shim, the same "vendor working code, don't clean-room
  reimplement" approach as the other three backends. Unlike those,
  this is C++ (`link_libcpp`, not `link_libc`) - Shrinkler's own
  optimal-parse LZ77 + adaptive range coder + LZMA-family context
  model, in the "--data" (raw buffer) mode.
- ~~68k range-decoder + copy-loop stub, hand-tuned, adapted from
  `ShrinklerDecompress.S`~~ — the actual routine (trimmed of the
  file-loading half it ships with, which needs dos.library and isn't
  used here), not a reimplementation, adapted into `stubs/shrinkler/`.
  Needed real adapter code, unlike zx0/inflate/zultra/salvador: it
  takes a progress-callback pointer and a parity-context flag
  `runtime.i`'s plain `Depack` contract has no way to express, and (the
  actual bug this surfaced) its own "preserves A2-A6" promise only
  holds in the sense that it never *writes* those registers - handing
  it a *different* A2 than runtime.i still needs back is still wrong,
  and an early version of this stub did exactly that. Found the hard
  way: it passed the C++ round-trip test *and* a real-hardware test
  that called the depacker directly (bypassing `runtime.i` entirely),
  and only failed in the full pack → boot → decompress → relocate →
  jump pipeline - see `stubs/shrinkler/stub.s`'s own comment for the
  full trail (isolating each layer - host encoder vs. real upstream
  Shrinkler's own CLI output byte-for-byte; the depacker alone against
  known-good compressed bytes on real hardware; the container header
  fields - before finding it).
- **Deliverable:** the best ratio of all five backends, as expected for
  Shrinkler's more sophisticated model - on the large test program
  (`tests/uae/e2e_large/`): 2832 bytes (49.0% of the 5784-byte
  original), beating zx0/salvador's shared 2928 (50.6%). Verified the
  same two ways as every other backend, plus one more given what the
  bug above took to find: byte-level (a real compress-then-decompress
  round-trip through Shrinkler's own vendored reference decoder), an
  isolated real-hardware test of the depacker alone against known-good
  compressed bytes (bypassing the container pipeline entirely, once
  the round-trip test alone proved insufficient to catch the A2 bug),
  and the full pipeline on real hardware (`run_e2e_test.sh` and the
  byte-exact `run_large_e2e_test.sh`, both with
  `EXECRAM_TEST_BACKEND=shrinkler`).

**M5 — Unified CLI polish** ✅ done
- ~~`execram pack [--backend=...] [--mem=chip|fast] [-v] in out`~~ —
  `--mem=chip|fast` overrides the auto-detected Chip/Fast RAM choice
  (warns if forcing `fast` on an input that actually requested Chip
  RAM, since that can build fine and misbehave only at runtime); `-v`
  prints per-backend sizes in `--backend=auto` mode plus image
  statistics (code/data/bss/reloc-stream sizes, detected memory type).
- ~~`execram info` (inspect a packed executable)~~ — reports every
  container header field (backend, memory type, relocations, all five
  size fields, resident size, payload ratio) without decompressing
  anything. Locating the header in a file whose stub length isn't
  already known (unlike `pack`, which just produced it) matches each
  known stub's bytes as a literal prefix (`src/info.zig`) rather than
  scanning for the "ExCr" magic - the exact trap
  `tests/uae/e2e/extract_container.py`'s own doc comment already
  warned about (a coincidental match inside the stub's own
  `cmp.l #MAGIC,...` instruction encoding).
- ~~Host-side reference decompressor per backend for pre-flight
  self-check~~ — every `pack` now decompresses what it just produced
  and compares it byte-for-byte against the original flattened image
  before writing anything, refusing to save an executable whose
  container wouldn't decompress correctly (`error.SelfCheckFailed`)
  rather than shipping it and finding out on real hardware - the same
  discipline Shrinkler's own CLI already follows (`DataFile.h`'s
  `verify()` step). Needed a `decompress` function per backend, added
  alongside each `compress` (`src/backends/*.zig`): `zx0` and `zultra`
  don't vendor their own decoders, so they delegate to `salvador`'s and
  `inflate`'s respectively - both already documented as byte-compatible
  with those formats, so no new vendoring was needed, just reuse.

**M6 — Test matrix & CI** ✅ done
- ~~Corpus of rights-cleared real + synthetic executables~~ — a
  synthetic corpus (`tests/corpus/gen_corpus.py`), each item targeting
  one axis the two existing e2e programs didn't reach: `no_relocs`
  (zero relocation sites - `FLAG_HAS_RELOCS` clear), `chip_mem` (a
  hunk explicitly requiring Chip RAM, forcing the whole packed program
  resident there), `bss_heavy` (a 64K BSS, actually read back at
  runtime to confirm `MEMF_CLEAR` really zeroed it, not just declared),
  `incompressible` (a deterministic non-repeating payload - the worst
  case for every LZ-family backend). Sourcing genuinely rights-cleared
  *real* executables turned out to be its own unresolved licensing
  question with no clean answer in the time available, so this stayed
  synthetic-only, same as the existing e2e programs - a reasonable
  scope call, not an oversight.
- ~~Headless FS-UAE boot pass/fail per corpus item per backend~~ —
  `tests/uae/run_corpus_test.sh` boots every corpus item under every
  backend (4 items x 6 backends = 24 combinations) and diffs the exact
  expected transcript each time, printing a pass/fail matrix. All 24
  passed, including two paths never exercised on real hardware before
  this: Chip RAM allocation (`chip_mem` - previously only checked at
  the host level, that the header *flag* gets set) and a large BSS
  actually coming back zeroed (`bss_heavy` - previous BSS segments were
  declared and sized but never read back to confirm).
- ~~Ratio/speed regression tracking in CI~~ —
  `tests/ratio/track_ratios.py` packs the corpus plus the two e2e
  programs with every backend and compares sizes against a committed
  baseline (`tests/ratio/baseline.json`), failing only if a backend's
  output *grows* (an improvement is reported, not treated as a
  failure - see the script's own module doc for why). Needs no FS-UAE
  or Kickstart ROM (host-side size/time measurement only), so unlike
  `tests/uae/*` this runs in `.github/workflows/ci.yml` too.

**Post-v1.0: real executables, and a new boot mechanism to test them**
The "rights-cleared real executables" half of M6's corpus item,
deferred above, got resolved directly: `tests/corpus/hexagon.exe`, a
real Amiga demo/game (Norwich Amiga Group) the author has rights to
include, instrumented with a small serial-output snippet
(`tests/corpus/exram_serial.h`) to make it observable headlessly. At
220KB with 626 relocations and a 198KB Chip-RAM hunk, it's by far the
largest, most realistic executable in any of execram's test suites -
and it surfaced a real gap in the test harness itself, not in execram:
`tests/uae/e2e/loader.s` (every other script's boot mechanism) is a
bare-metal boot block with no AmigaDOS environment at all, which the
synthetic corpus never needed (deliberately written to never call
`OpenLibrary`) but a real program does. Chasing what looked like a
packing bug (an extremely reproducible crash - identical faulting PC
and opcode no matter what was varied: register state, stack size,
chip RAM size, even independent rebuilds of the program with real
source changes) led to disassembling the actual crash site and finding
the true cause (a library call dispatched through a not-yet-open
library base - a real bug in the program's own startup order, fixed on
its own side) only after independently re-implementing `flatten.zig`'s
own relocation algorithm in Python and confirming it byte-for-byte
correct against real output - ruling out execram itself first. Even
after that fix, the *same* symptom persisted under `loader.s`, which
turned out to be the actual lesson: `loader.s` was never going to
provide what a real program's `OpenLibrary` calls need, regardless of
whether the program's own bug was fixed. `tests/uae/run_real_exe_test.sh`
solves this properly rather than working around it: FS-UAE (like
WinUAE) auto-wraps a single AmigaDOS executable file pointed at as a
floppy drive into a minimal bootable disk with a real startup-sequence,
so pointing `--floppy_drive_0` straight at execram's own packed output
gives a genuine AmigaDOS launch with dramatically less machinery than
`loader.s`'s own disk-image-building pipeline - no loader, no manual
disk assembly. The same packed output that failed under `loader.s` ran
correctly first try once boot moved to this mechanism, for five of the
six backends immediately and the sixth (`shrinkler`) once its boot
timeout was made realistic for real 68000 range-decoder timing on a
file this large (see `tests/uae/README.md`'s own account - a second,
smaller, genuinely distinct finding, not a bug either). All six now
pass under this mechanism.

**M7 — Docs & release** ✅ done
- ~~README, format spec, per-backend algorithm notes, contribution
  guide~~ — README.md rewritten for a shipped tool rather than an
  in-progress one; `docs/format-spec.md`'s stale "draft, unimplemented"
  status note updated to reflect that all six backends now implement
  it, verified on real hardware; `docs/algorithm-notes/` created (one
  page per backend *format* - store, inflate/DEFLATE, zx0, shrinkler -
  distinct from each vendor directory's own provenance-focused
  README); `CONTRIBUTING.md` added, covering the project's actual
  hard-won conventions (real-hardware verification isn't optional for
  pipeline changes, vendoring philosophy, how to add a backend).
  Also added, not originally listed here but a real gap the M0 audit's
  own summary had flagged and left open: `LICENSE` (MIT, for execram's
  own code) and `THIRD_PARTY_LICENSES.md` (consolidated notices for
  every vendored license currently in the tree, grouped by license text
  rather than duplicated per file).
- ~~v1.0 once Inflate + ZX0 are solid; Shrinkler-class ships as v1.x~~ —
  development didn't proceed in the phased order this line originally
  assumed: by the time M7 started, M1-M6 were *all* already done and
  hardware-verified, Shrinkler-class included. Shipping an
  Inflate/ZX0-only v1.0 and deferring a working, tested Shrinkler
  backend to a later release would have been artificial at that point,
  so v1.0 ships as everything in one release instead - a deliberate
  adaptation to how the work actually landed, not a scope cut.

## 8. Testing strategy

- **Round-trip tests** (host-only, fast): pack then run each backend's
  host-side reference decompressor, diff against the original flattened
  image.
- **Boot tests** (real fidelity): headless FS-UAE runs the packed
  executable and confirms success via a serial-port sentinel or in-memory
  CRC check — this is the only way to catch relocation, memory-type
  (CHIP/FAST), or stub-timing bugs that a host-side diff can't see.
- **Corpus**: a small, growing set of real and synthetic executables,
  rerun on every backend on every CI run, with ratio numbers tracked over
  time (regression = CI failure).

## 9. Risks

| Risk | Mitigation |
|---|---|
| Licensing incompatibility on any adapted 68k source | Resolved by the M0 audit (`docs/LICENSES.md`) — all four backends' reference sources are permissive or public-domain; re-verify against the exact commit pinned in the audit before vendoring, since none are tagged releases |
| 68k stub size/speed budget blown | Hand-tune in assembly from the start; track stub size as a CI-visible metric per backend |
| In-place decompression overlap bugs | Verified safety-margin math per backend; separate-buffer mode until verified; UAE boot tests as the ultimate check |
| Hunk format edge cases (multi-hunk cross-relocs, resident libs, overlays) | Explicit non-goals for v1 (overlays); broad corpus testing for the rest |
| Shrinkler-class backend (M4) is a big, open-ended effort | Sequenced last, after two working simpler backends de-risk the shared pipeline; treated as its own project phase with its own timeline slack |
| Zig 0.16 has no mature m68k/AmigaOS backend | Sidestepped entirely — 68k stubs are hand-written asm assembled by vasm, not Zig-compiled |
| Legal Kickstart ROM access for testing | Document acceptable sources (e.g., Cloanto Amiga Forever, user-owned ROM dump) in `docs/`; never redistribute ROM images |

## 10. Open questions for later phases

- CPU-tiered stubs (plain 68000 vs. 68020+ with better addressing modes),
  as Shrinkler offers — worth adding once one backend is solid.
- Whether to expose a library API (not just CLI) for integration into
  other build pipelines.
- AmigaOS-native build of the host tool, for on-Amiga cross-development.
