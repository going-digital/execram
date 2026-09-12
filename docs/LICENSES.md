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

## 7. Decisions this audit changes vs. the original plan

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

## 8. Kickstart ROMs (test dependency, not a project dependency)

The FS-UAE boot tests under `tests/uae/` need a real Kickstart ROM to run
against. Kickstart ROMs are copyrighted (originally Commodore-Amiga, now
Cloanto). **They must never be committed to this repo, fetched by CI, or
otherwise redistributed by this project.** Anyone running the boot tests
supplies their own legally-obtained ROM via the `EXECRAM_KICKSTART`
environment variable (see `tests/uae/README.md`); this is why those tests
are local/dev-machine-only and excluded from `.github/workflows/ci.yml`.

## 9. Summary table

| Component | License | Vendor/adapt OK? | Obligations |
|---|---|---|---|
| Shrinkler — general codebase | Custom permissive (own text) | Yes | Include `LICENSE.txt` in source dist; don't misattribute in binary dist |
| Shrinkler — `ShrinklerDecompress.S` | Public-domain-equivalent (own text) | Yes | None |
| ZX0 — host compressor | BSD-3-Clause | Yes | Retain copyright notice + disclaimer |
| ZX0 — 68k depacker (in ZX0 repo) | zlib | Yes | Retain notice |
| unzx0_68000 | zlib | Yes | Retain notice; don't misrepresent origin |
| Keir Fraser `inflate.S` / `bootblock.S` | Unlicense (public domain) | Yes | None |
| vasm | Custom (free for M68k/AmigaOS commercial use) | Use as external tool only; don't vendor the tool itself | None on our output |
| vlink | Custom (free for AmigaOS/68k commercial use) | Use as external tool only; don't vendor the tool itself | None on our output |

**Net effect: no clean-room reimplementation is legally required for any
of the four backends.** We can adapt existing source for all of them,
provided we keep the relevant notices in `docs/algorithm-notes/` and in
the stub source files themselves, and ship a `THIRD_PARTY_LICENSES.md` (or
equivalent) alongside execram's own license once the codebase exists.
