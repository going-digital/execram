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

**M4 — Shrinkler-class backend** (~4–8+ weeks, highest effort, now lower-risk)
- License audit (§3) confirmed Shrinkler's depacker (`ShrinklerDecompress.S`)
  is public-domain-equivalent and the rest of its codebase is permissive
  attribution-only — so this backend may directly study/adapt/port
  Shrinkler's actual compressor design and depacker asm (crediting per
  `docs/LICENSES.md`), rather than being restricted to a clean-room
  reimplementation from the algorithm description
- Host: LZ77 + adaptive range coder + context modeling + optimal parsing
  (port or reimplement in Zig, informed directly by Shrinkler's source)
- 68k range-decoder + copy-loop stub, hand-tuned, adapted from
  `ShrinklerDecompress.S` where useful
- **Deliverable:** fourth backend competitive with Shrinkler's ratio class
  (a target, not a guarantee — still the long pole of the whole project,
  but the legal uncertainty that made it the highest-risk milestone is gone)

**M5 — Unified CLI polish** (~1–2 weeks)
- `execram pack [--backend=...] [--mem=chip|fast] [-v] in out`
- `execram info` (inspect a packed executable)
- Host-side reference decompressor per backend for pre-flight self-check

**M6 — Test matrix & CI** (ongoing from M1)
- Corpus of rights-cleared real + synthetic executables
- Headless FS-UAE boot pass/fail per corpus item per backend
- Ratio/speed regression tracking in CI

**M7 — Docs & release**
- README, format spec, per-backend algorithm notes, contribution guide
- v1.0 once Inflate + ZX0 are solid; Shrinkler-class ships as v1.x

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
