# License audit (M0)

Audited 2026-09-11 against the commits below. **Re-verify against the exact
commit before vendoring anything** — none of these are tagged releases, and
maintainers can relicense future commits.

This audit's one big surprise: **Shrinkler is not GPL.** The whole plan's
M4 risk assessment assumed it was and treated the algorithm as
clean-room-only; that assumption was wrong and is corrected below (§1, §7).

---

## 1. Shrinkler — `askeksa/Shrinkler`

Commit audited: `17cff110fcded387fe90e632805258d9c8359e94`

Two different licenses apply within this one repo:

### 1a. Everything except the decrunch code (`LICENSE.txt`, root)

```
Shrinkler executable file compressor for Amiga

Copyright 1999-2022 Aske Simon Christensen, with exceptions noted below.

Permission is hereby granted to anyone obtaining a copy of this software
package (including accompanying documentation) to compile, use, copy,
modify, merge and/or distribute it, in whole or in part, subject to the
following conditions:

- Distribution in source code form must include a copy of this license.

- Distribution in binary form must not be misattributed, i.e. you must
  not claim (implicitly or explicitly) that you wrote it yourself.

- Distribution of the decrunch headers (Header.S, MiniHeader.S,
  OverlapHeader.S, and the .bin and .dat files generated from them) in
  binary form as part of an Amiga executable is not restricted by this
  license and does not require attribution.
  In particular, output executables from Shrinkler (which contain code
  from the decrunch headers) are to be considered original works of the
  author(s) of the corresponding input executables.

- The data decompression code (ShrinklerDecompress.S) is distributed
  alongside the Shrinkler binaries in the official archives and has its
  own license stated inside the file.

Exceptions:

- doshunks.h is part of the Amiga SDK and is Copyright 1989-1993
  Commodore-Amiga, Inc.
```

This is a permissive, attribution-required license (include the license
text in source redistributions, don't misattribute authorship in binary
form). **It is not GPL and has no copyleft/share-alike clause** — porting
or adapting this code does not obligate us to open-source execram or
license it under the same terms.

### 1b. The actual depacker — `decrunchers/ShrinklerDecompress.S`

This is the 68k range-decoder + LZ copy-loop that runs on the Amiga — the
component most relevant to our M4 backend. Its embedded header is even
more permissive than the outer license:

```
; Copyright 1999-2022 Aske Simon Christensen.
;
; The code herein is free to use, in whole or in part,
; modified or as is, for any legal purpose.
;
; No warranties of any kind are given as to its behavior
; or suitability.
```

Effectively public-domain-equivalent. `decrunchers/Header.S` and
`decrunchers/MiniHeader.S` point back to the outer `LICENSE.txt`, which
itself explicitly waives attribution for these files when embedded in an
output executable.

`doshunks.h` (Amiga SDK header, Commodore-Amiga 1989-1993) is out of
scope for us — we're writing our own hunk parser from the public hunk
format documentation, not copying Commodore's header.

## 2. ZX0 — `einar-saukas/ZX0`

Commit audited: `ecde3a2ae05061fe06469ed46df81a33b7de7d86`

- **Host-side optimal-parse C compressor:** BSD-3-Clause
  (`Copyright (c) 2021, Einar Saukas`, standard 3-clause text, verified
  against `LICENSE`).
- **68k (680x0) depacker asm shipped in this repo:** per the README,
  "available under the zlib license... you can use it in any way that
  you like."

Both are fine to vendor/adapt directly, honoring their respective notices
(BSD-3's attribution clauses for the compressor; zlib's for the depacker).

Vendored in M3: the compressor (unmodified) at
`src/backends/zx0_vendor/`. The 68k depacker actually used is
Emmanuel Marty's separate `unzx0_68000` (§3 below), not the asm shipped
in this repo - `unzx0_68000`'s own README recommends pairing it with
this repo's or Salvador's compressor.

## 3. unzx0_68000 — `emmanuel-marty/unzx0_68000`

Commit audited: `c807773edffae8b12155a980d8031ef7701ccfa1`

zlib license, verified against `LICENSE.md`:

```
Copyright (c) 2021 Emmanuel Marty

This software is provided 'as-is', without any express or implied warranty...

Permission is granted to anyone to use this software for any purpose,
including commercial applications, and to alter it and redistribute it
freely, subject to the following restrictions:

1. The origin of this software must not be misrepresented...
2. Altered source versions must be plainly marked as such...
3. This notice may not be removed or altered from any source distribution.
```

Fully permissive for our use (adapt as the ZX0 depacker stub); just keep
the notice in the stub source and don't claim we wrote the original.

Vendored in M3 at `stubs/zx0/unzx0_68000.s`, with the entry label
renamed to `Depack` (the one deliberate change - see that file's header
comment) to match `stubs/common/runtime.i`'s calling convention.

## 4. Keir Fraser's `inflate.S` and `bootblock.S` — `keirf/Amiga-Stuff`

Commit audited: `fdf7f28e6eb8e6084581df083d37d363052527fd`

Unlicense (public domain), per the repo's `COPYING` file and the README's
"All code is public domain." No conditions at all — safe to adapt
directly with no notice obligations (though we credit both in
`stubs/inflate/inflate_core.s` and `tests/uae/e2e/loader.s` respectively,
as a matter of good practice, not legal necessity). `inflate.S` is
vendored/adapted into the shipped inflate backend's depacker stub
(M2); `bootblock.S`'s disk-reading mechanics (IORequest field offsets,
`DoIO` usage) informed `tests/uae/e2e/loader.s`, a test-only tool, not
anything shipped.

## 5. vasm and vlink (build/test-time toolchain dependencies)

### vasm

Per the official manual ("1.3 Legal", `sun.hasenbraten.de/vasm`):

```
vasm is copyright in 2002-2026 by Volker Barthelmann. This archive may be
redistributed without modifications and used for non-commercial purposes.
An exception for commercial usage is granted, provided that the target
CPU is M68k and the target OS is AmigaOS. Resulting binaries may be
distributed commercially without further licensing. In all other cases
you need my written consent. Certain modules may fall under additional
copyrights.
```

Our entire target is M68k/AmigaOS, so we sit squarely inside the
commercial-use exception, and the depacker stub binaries vasm produces
for us are explicitly clear to distribute commercially. To avoid any
question about redistributing the vasm *archive itself* (the exception's
wording covers commercial *use*/*output*, not unambiguously
redistribution of vasm as a tool), we will **not vendor vasm's binary or
source in this repo** — it's documented as an external build-time
toolchain requirement (`docs/` install notes), same as requiring a C
compiler.

### vlink

Verified against `vlink.texi` in the upstream source (Frank Wille,
2025-vintage source pulled 2026-09-11), section "Legal":

```
vlink is copyright 1995-2025 by Frank Wille.

This archive may be redistributed without modifications and used
for non-commercial purposes.

An exception for commercial usage is granted, provided that the
target OS is AmigaOS/68k. Resulting binaries may be distributed
commercially without further licensing.

In all other cases you need my written consent.
```

Same terms and same exception as vasm, and for the same reason: our
target is AmigaOS/68k. Used the same way — external build/test-time
tool (M1 uses it to link test-fixture executables for `hunk.zig`'s unit
tests), never vendored in this repo.

## 6. Zultra — `emmanuel-marty/zultra`

Commit audited: `5490882fd561a8eae93c8004a46d11e641e46a0b`

"A fast deflate implementation with zopfli-like ratios and a streaming
API" - an alternative host-side compressor for the `inflate` backend's
existing depacker (M2), producing the same standard raw-DEFLATE format,
so no new depacker or backend_id is needed. Three licenses apply within
the vendored subset (core library only, per `src/backends/zultra_vendor/README.md`
- the reference CLI and its bundled zlib are not vendored, neither is
needed):

- **Most files:** zlib license (`Copyright (c) 2019 Emmanuel Marty`),
  verified against `LICENSE.zlib.md` - identical terms to
  `unzx0_68000` (§3).
- **`src/matchfinder.c`:** CC0 1.0 Universal (public domain), verified
  against `LICENSE.cc0.md`.
- **`src/huffman/huffutils.c`:** Apache License 2.0, verified against
  `LICENSE.Apache2.0.md`. Permissive but not notice-free like the
  others: redistribution must retain copyright/attribution notices and
  mark any modified files as changed. We haven't modified this file, so
  the retained-notice condition is trivially met by vendoring it as-is.
- **`src/libdivsufsort/`** (a separate upstream project - Yuta Mori's
  suffix-array library - vendored inside zultra): MIT license, verified
  against `src/libdivsufsort/LICENSE`.

All four are permissive with no copyleft; fine to vendor directly,
honoring each file's own notice per the details above.

## 7. Salvador — `emmanuel-marty/salvador`

Commit audited: `1662b625a8dcd6f3f7e3491c88840611776533f5`

"A free, open-source compressor for the ZX0 format" - an alternative
optimal-parse host-side compressor for the `zx0` backend's existing
depacker, from the same author as `unzx0_68000` (§3). Confirmed to
produce the same ZX0 v2 ("inverted") format by diffing salvador's own
bundled copy of `asm/68000/unzx0_68000.S` directly against the one
already vendored in `stubs/zx0/` and finding them byte-identical - not
just assumed from format documentation - so no new depacker or
backend_id is needed (`src/backends/salvador.zig`). Two licenses apply
within the vendored subset (core library plus its own ZX0 decompressor,
vendored to enable a real round-trip test; the reference CLI is not
vendored, per `src/backends/salvador_vendor/README.md`):

- **Most files:** zlib license (`Copyright (c) Emmanuel Marty`),
  identical terms to `unzx0_68000` (§3) and Zultra's own files (§6).
- **`src/matchfinder.c`:** CC0 1.0 Universal (public domain), same terms
  as Zultra's `src/matchfinder.c` (§6) - verified against
  `LICENSE.cc0.md`.
- **`src/libdivsufsort/`:** MIT license, verified against
  `libdivsufsort/LICENSE`. Same upstream project as Zultra's own
  `libdivsufsort/` (§6), but a **different fork** - diffed directly and
  confirmed not byte-identical (this one keeps plain `malloc`/`free`,
  Zultra's takes a `zalloc`/`zfree` allocator pair) - so vendored and
  audited separately rather than assumed identical. Both forks define
  the same 12 global C symbols, which collide at link time when both
  are vendored into one binary; resolved in `build.zig` by renaming
  only Salvador's copy via compiler `-D` flags (no source changes, no
  license implications - the code itself is untouched).

All three are permissive with no copyleft; fine to vendor directly,
honoring each file's own notice per the details above.

## 8. Decisions this audit changes vs. the original plan

The plan (`PROJECT_PLAN.md`) originally assumed Shrinkler was GPL and
required M4 (the Shrinkler-class backend) to be built purely from a
clean-room reading of the public algorithm description, with no source
reuse. That assumption was wrong:

- **`ShrinklerDecompress.S` (the depacker) can be directly adapted or
  ported**, not just referenced — its license is maximally permissive
  ("free to use, in whole or in part, modified or as is, for any legal
  purpose").
- **The host-side C++ compressor can also be studied and adapted**, not
  just clean-room reimplemented, as long as we (a) include a copy of
  `LICENSE.txt` in our source distribution and (b) don't misattribute
  authorship in binary distributions. This is a substantially lower bar
  than copyleft and meaningfully de-risks M4.
- Clean-room reimplementation is no longer *required*, but may still be
  chosen for engineering reasons (Zig vs. C++, wanting a from-scratch
  design) — that's now an engineering call, not a legal one.

`PROJECT_PLAN.md` §3 and §7 (M4) should be updated to reflect this — see
the accompanying edit.

## 9. Kickstart ROMs (test dependency, not a project dependency)

The FS-UAE boot tests under `tests/uae/` need a real Kickstart ROM to run
against. Kickstart ROMs are copyrighted (originally Commodore-Amiga, now
Cloanto). **They must never be committed to this repo, fetched by CI, or
otherwise redistributed by this project.** Anyone running the boot tests
supplies their own legally-obtained ROM via the `EXECRAM_KICKSTART`
environment variable (see `tests/uae/README.md`); this is why those tests
are local/dev-machine-only and excluded from `.github/workflows/ci.yml`.

## 10. Summary table

| Component | License | Vendor/adapt OK? | Obligations |
|---|---|---|---|
| Shrinkler — general codebase | Custom permissive (own text) | Yes | Include `LICENSE.txt` in source dist; don't misattribute in binary dist |
| Shrinkler — `ShrinklerDecompress.S` | Public-domain-equivalent (own text) | Yes | None |
| ZX0 — host compressor | BSD-3-Clause | Yes | Retain copyright notice + disclaimer |
| ZX0 — 68k depacker (in ZX0 repo) | zlib | Yes | Retain notice |
| unzx0_68000 | zlib | Yes | Retain notice; don't misrepresent origin |
| Keir Fraser `inflate.S` / `bootblock.S` | Unlicense (public domain) | Yes | None |
| Zultra — general codebase | zlib | Yes | Retain notice |
| Zultra — `src/matchfinder.c` | CC0 1.0 | Yes | None |
| Zultra — `src/huffman/huffutils.c` | Apache 2.0 | Yes | Retain notices; mark changed files |
| Zultra — `src/libdivsufsort/` | MIT | Yes | Retain notice |
| Salvador — general codebase | zlib | Yes | Retain notice |
| Salvador — `src/matchfinder.c` | CC0 1.0 | Yes | None |
| Salvador — `src/libdivsufsort/` (different fork than Zultra's) | MIT | Yes | Retain notice |
| libdeflate | MIT | Yes | Retain notice |
| Zopfli | Apache 2.0 | Yes | Retain notice; mark changed files |
| LZ4/LZ4HC | BSD 2-Clause | Yes | Retain notice |
| lz4-68k | MIT | Yes | Retain notice |
| vasm | Custom (free for M68k/AmigaOS commercial use) | Use as external tool only; don't vendor the tool itself | None on our output |
| vlink | Custom (free for AmigaOS/68k commercial use) | Use as external tool only; don't vendor the tool itself | None on our output |
| Musashi | MIT | Yes (see §11) | Retain notice |

**Net effect: no clean-room reimplementation is legally required for any
of the four backends.** We can adapt existing source for all of them,
provided we keep the relevant notices in `docs/algorithm-notes/` and in
the stub source files themselves, and ship a `THIRD_PARTY_LICENSES.md` (or
equivalent) alongside execram's own license once the codebase exists.

## 11. Musashi — `kstenerud/Musashi`

Commit audited: `313ebf1bd9f4d0d93341eb5ce21fd8a119e9dbdd`

A portable, C-only 68000-68040 CPU-core emulator (no chip/disk/video
emulation), used here to run a compiled depacker stub through the real
68000 instruction set and get an exact cycle count for its
decompression time, instead of a real-time-paced, host-load-sensitive
FS-UAE wall-clock measurement. Originally added purely to power
`tools/bench` (a dev-only tool - see that directory's README), a
dev-tool-only dependency deliberately kept out of the shipped
`execram` binary. That changed when `execram bench` (src/main.zig)
landed: it links the same Musashi core (via src/musashi_bench.zig)
directly into the real, released binary, so Musashi is now a genuine
runtime dependency of execram itself, not just a dev tool's. Per
upstream's `readme.txt` ("LICENSE AND COPYRIGHT"):

```
Copyright © 1998-2001 Karl Stenerud

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

MIT, permissive, no copyleft - fine to vendor directly, honoring the
notice. Vendored at `src/musashi_vendor/` (subset only - see that
directory's README for exactly what and why). **Added to
`THIRD_PARTY_LICENSES.md`**, unlike vasm/vlink (§5): those never ship
in any form, while Musashi now does, compiled directly into the
`execram` binary that `execram bench` is part of - it meets
`THIRD_PARTY_LICENSES.md`'s own scope ("travels with any
redistribution" of execram) that it didn't when this was written.

## 12. libdeflate — `ebiggers/libdeflate`

Commit audited: `92e6a0db9fa848d742f9eb286c92afc60f2c3dda`

"Heavily optimized library for DEFLATE/zlib/gzip compression and
decompression" (issue #1's first suggestion) - another alternative
host-side compressor for the `inflate` backend's existing depacker,
same shape as Zultra (§6): produces standard raw DEFLATE, so no new
depacker or backend_id is needed (`src/backends/libdeflate.zig`). Only
the compressor half is vendored - decompression, zlib/gzip framing, and
the CLI programs are not, per `src/backends/libdeflate_vendor/README.md`.

- **Whole vendored subset:** MIT license (`Copyright 2016 Eric Biggers,
  Copyright 2024 Google LLC`), verified against the project's own
  `COPYING`, vendored verbatim at
  `src/backends/libdeflate_vendor/COPYING`.

Permissive, no copyleft; fine to vendor directly, honoring the notice.

## 13. Post-compression DEFLATE recoders (issue #1's second half)

Not integrated (or vendored) yet - noted here so a license read is on
record before anyone reaches for one. Issue #1 also names DeflOpt,
defluff, deft4j/turtledeflate, and columbo as post-compression
Huffman/block recoding tools that operate on an already-valid DEFLATE
stream (no new depacker needed, same shape as §12/§6/§7). Their license
status differs sharply and should be (re-)checked at whichever point
one is actually picked up, not assumed from this note:

- **DeflOpt:** closed-source freeware, no published source and no
  redistribution/adaptation license - not vendorable at all, only
  usable (if at all) as an external, separately-installed tool a user
  runs themselves, never bundled or linked into execram.
- **defluff:** distributed as a forum-thread attachment (encode.su),
  not a maintained repo with a clear license file as of this audit -
  needs a real license read, not an assumption, before any vendoring.
- **deft4j / turtledeflate:** both on GitHub; license unread as of this
  audit.
- **columbo:** on GitHub (`ace-dent/columbo`), alpha quality per its own
  `Alpha testing` issue as of this audit; license unread.

**Update:** none of these four ended up vendored. A prototype of the
one technique among them still valid given execram's own architecture
(source data is never lost here, unlike the use case these tools
target) found zero real-world benefit and was removed - see
`PROJECT_PLAN.md`'s "Huffman-relength prototype" entry. The license
notes above are otherwise unaffected.

## 14. Zopfli — `google/zopfli`

Commit audited: `ccf9f0588d4a4509cb1040310ec122243e670ee6`

Issue #1's second DEFLATE-compressor suggestion, vendored as the
original C reference implementation (`libzopfli`'s core only, not
`zopflipng` or the CLI) rather than the `zopfli-rs` Rust port also
named there - `zopfli-rs` is a plain Rust `rlib` with no C ABI, and
wrapping it would mean a `cargo`-based build step and Rust cross-
compilation added to CI for every release target, a second toolchain
this project doesn't otherwise need. The upstream C library is the
reference implementation `zopfli-rs` itself ports, under the same
license, and drops into the exact vendoring pattern already used for
Zultra/Salvador/libdeflate. Another alternative host-side compressor
for the `inflate` backend's existing depacker: produces standard raw
DEFLATE, so no new depacker or backend_id is needed
(`src/backends/zopfli.zig`).

- **Whole vendored subset:** Apache License 2.0 (`Copyright 2011 Google
  Inc.`), verified against the project's own `COPYING`, vendored
  verbatim at `src/backends/zopfli_vendor/COPYING`. Same license as
  Zultra's own `src/huffman/huffutils.c` (§6) - permissive but not
  notice-free: redistribution must retain copyright/attribution
  notices and mark modified files as changed.
- **Modification:** `deflate.c`'s `PatchDistanceCodesForBuggyDecoders()`
  - issue #1's own suggestion - turned into a no-op (marked inline at
    its definition, per §4(b)'s "state changes made" requirement). That
    function pads a block's distance-code Huffman table to at least 2
    entries purely to work around bugs in zlib <=1.2.1 and some old
    mobile phones; execram's own depacker isn't one of those, so the
    workaround only cost bytes here for no benefit. See
    `src/backends/zopfli_vendor/README.md`.

Permissive, no copyleft; fine to vendor directly, honoring the notice
and the changed-file marking above.

Benchmarked against Zultra and libdeflate (§6, §12) - a statistical tie
with Zultra, both ahead of libdeflate; see `PROJECT_PLAN.md`'s Zopfli
entry for the numbers.

## 15. LZ4/LZ4HC — `lz4/lz4`

Commit audited: `0774d05537f9762f838f7ab541b7765f1a729cb5`

Host-side compressor for the new `lz4small`/`lz4normal`/`lz4fast`
backends: `LZ4_compress_HC()` at its own maximum level, plus
`LZ4_decompress_safe()` for the pack-time host-side self-check. Only
four files vendored (`lz4.c`/`.h`, `lz4hc.c`/`.h`) - not the LZ4 Frame
format or the file-API convenience wrapper, neither needed since this
backend uses the raw block API directly (`src/backends/lz4_vendor/README.md`).

- **All four files:** BSD 2-Clause (`Copyright (c) Yann Collet`),
  verified against the project's own `lib/LICENSE`, vendored verbatim
  at `src/backends/lz4_vendor/LICENSE`.

Permissive, no copyleft; fine to vendor directly, honoring the notice.

## 16. lz4-68k — `arnaud-carre/lz4-68k`

Commit audited: `773f8a083764d2fd001408f65ffcb94ae8e13a6c`

Three independent 68k depackers for the raw LZ4 block format above,
trading depacker code size for decompression speed (72/180/3722 bytes
- see `stubs/lz4/README.md` and `docs/algorithm-notes/lz4.md`). Unlike
every other backend in this project, these three aren't alternative
encoders sharing one depacker - they're one encoder paired with three
genuinely different depackers, so each gets its own `backend_id`
(`src/container.zig`).

- **All three `.asm` files:** MIT license (`Copyright (c) 2021 Arnaud
  Carré`), verified against the project's own `LICENSE`, vendored
  verbatim at `stubs/lz4/LICENSE`.
- **Modifications** (both documented inline at their exact location,
  per good practice - MIT doesn't require marking changes the way
  Apache 2.0 does):
  - `lz4_normal.asm`: two `repeat 15 { ... }` blocks, a form
    `vasmm68k_mot` doesn't support, mechanically unrolled into 15
    literal copies of the same instruction each - verified
    byte-for-byte, the unrolled file assembles to exactly upstream's
    own documented 180 bytes.
  - All three: wrapped in a `movem.l d2-d7/a2-a6,-(a7)` /
    `bsr.w lz4_depack` / `movem.l (a7)+,d2-d7/a2-a6` pair
    (`stubs/lz4/stub_{small,normal,fast}.s`) - none natively preserve
    the registers `stubs/common/runtime.i`'s `Depack` contract
    requires (they treat several as scratch, written for a simpler
    calling convention than execram's).

Permissive, no copyleft; fine to vendor/adapt directly, honoring the
notice.
