# Third-party licenses

execram's own code (the host tool and the runtime/glue we wrote
ourselves) is MIT-licensed - see `LICENSE`. This file lists the
third-party code vendored or adapted into this repository, grouped by
license text, so it travels with any redistribution. It is a notices
file, not the audit itself - see `docs/LICENSES.md` for the full
per-component rationale, exact upstream commits, and the reasoning
behind each vendoring decision.

Nothing here covers vasm, vlink, or Kickstart ROMs: none of the three
are vendored or redistributed by this project (vasm/vlink are build/
test-time external tools; Kickstart ROMs are copyrighted and must never
be committed to or fetched by this repo - see `docs/LICENSES.md` §9).

## Shrinkler's own license (Aske Simon Christensen)

Applies to: `src/backends/shrinkler_vendor/` (all files except
`shrinkler_shim.h`/`shrinkler_shim.cpp`, execram's own glue).

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
```

## Shrinkler's decrunch code license (Aske Simon Christensen)

Applies to: `stubs/shrinkler/ShrinklerDecompress.s` (a trimmed copy of
upstream's `decrunchers/ShrinklerDecompress.S`).

```
Copyright 1999-2022 Aske Simon Christensen.

The code herein is free to use, in whole or in part,
modified or as is, for any legal purpose.

No warranties of any kind are given as to its behavior
or suitability.
```

## zlib License

Applies to: `stubs/zx0/unzx0_68000.s` (Emmanuel Marty), most of
`src/backends/zultra_vendor/` (Emmanuel Marty), most of
`src/backends/salvador_vendor/` (Emmanuel Marty).

```
This software is provided 'as-is', without any express or implied
warranty. In no event will the authors be held liable for any damages
arising from the use of this software.

Permission is granted to anyone to use this software for any purpose,
including commercial applications, and to alter it and redistribute it
freely, subject to the following restrictions:

1. The origin of this software must not be misrepresented; you must not
   claim that you wrote the original software. If you use this software
   in a product, an acknowledgment in the product documentation would be
   appreciated but is not required.
2. Altered source versions must be plainly marked as such, and must not
   be misrepresented as being the original software.
3. This notice may not be removed or altered from any source
   distribution.
```

## BSD 3-Clause License

Applies to: `src/backends/zx0_vendor/` (Copyright (c) 2021, Einar
Saukas).

```
Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.
3. Neither the name of the copyright holder nor the names of its
   contributors may be used to endorse or promote products derived from
   this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS
IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## BSD 2-Clause License

Applies to: `src/backends/lz4_vendor/` (Copyright (c) Yann Collet -
see `docs/LICENSES.md` §15 and `src/backends/lz4_vendor/README.md`).

```
Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

    * Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above
copyright notice, this list of conditions and the following disclaimer
in the documentation and/or other materials provided with the
distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## MIT License

Applies to: `src/backends/zultra_vendor/libdivsufsort/` and
`src/backends/salvador_vendor/libdivsufsort/` (two different forks of
the same upstream project, both by Yuta Mori - see
`src/backends/salvador_vendor/README.md` for how they differ), and
`src/musashi_vendor/` (Karl Stenerud - see `docs/LICENSES.md` §11 and
`src/musashi_vendor/README.md`; compiled directly into this binary via
the `bench` command, not just a build/test-time tool the way vasm and
vlink are), `src/backends/libdeflate_vendor/` (Eric Biggers and
Google LLC - see `docs/LICENSES.md` §12 and
`src/backends/libdeflate_vendor/README.md`), and `stubs/lz4/`'s three
`.asm` depackers (Arnaud Carré - see `docs/LICENSES.md` §16 and
`stubs/lz4/README.md`).

```
Permission is hereby granted, free of charge, to any person obtaining a
copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be included
in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

## CC0 1.0 Universal (Public Domain)

Applies to: `src/backends/zultra_vendor/matchfinder.c` and
`src/backends/salvador_vendor/matchfinder.c` (Emmanuel Marty).

To the extent possible under law, the author(s) have dedicated all
copyright and related and neighboring rights to this software to the
public domain worldwide. This software is distributed without any
warranty. See <https://creativecommons.org/publicdomain/zero/1.0/> for
the full legal text.

## Apache License 2.0

Applies to: `src/backends/zultra_vendor/huffman/huffutils.c` (Emmanuel
Marty) and `src/backends/zopfli_vendor/` (Google Inc. - see
`docs/LICENSES.md` §14 and `src/backends/zopfli_vendor/README.md`).

Licensed under the Apache License, Version 2.0 (the "License"); you may
not use this file except in compliance with the License. You may obtain
a copy of the License at <https://www.apache.org/licenses/LICENSE-2.0>.
Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
`huffutils.c` is included unmodified from upstream, so the Apache 2.0
"state changes" marking requirement doesn't apply to it. The Zopfli
vendor tree *is* modified (`deflate.c`'s `PatchDistanceCodesForBuggyDecoders`
turned into a no-op) - marked inline at the modification site itself,
satisfying that requirement there instead of here.

## The Unlicense (Public Domain)

Applies to: `stubs/inflate/inflate_core.s` (adapted from Keir Fraser's
`inflate.S`).

This is free and unencumbered software released into the public domain.
Anyone is free to copy, modify, publish, use, compile, sell, or
distribute this software, either in source code form or as a compiled
binary, for any purpose, commercial or non-commercial, and by any
means. See <https://unlicense.org/> for the full legal text.
