# Vendored Musashi 68k CPU core

Unmodified copy of the subset of
[kstenerud/Musashi](https://github.com/kstenerud/Musashi) needed to
embed its CPU-only 68000 emulation core, commit
`313ebf1bd9f4d0d93341eb5ce21fd8a119e9dbdd` (audited 2026-09-12, see
`docs/LICENSES.md` §11).

Musashi is a portable, C-only 68000-68040 instruction-set emulator with
no chip/disk/video emulation of its own - used standalone as the CPU
core inside many real emulators (MAME among them). It exists in this
repo to run a compiled depacker stub through the real 68000 instruction
set and report an exact cycle count, as a fast, host-load-insensitive
alternative to timing decompression under FS-UAE's real-time-paced boot
process (`tests/uae/`). Two callers share it via `src/musashi_bench.zig`:
`tools/bench` (a standalone dev tool, times an already-packed file) and
`execram bench` (`src/main.zig`, ships as part of the real `execram`
binary - packs a fresh input with every backend and times each at
once). Because of the latter, Musashi **is** linked into the shipped
`execram` binary and **is** part of every release archive - unlike
every dev/build/test-only tool this project depends on (vasm, vlink,
FS-UAE), which is why it's also listed in `THIRD_PARTY_LICENSES.md`,
unlike those.

## What's vendored, and what isn't

Upstream ships a lot more than the CPU core proper - a disassembler,
example programs, an MMU model, a test suite. Only what the core
actually needs to compile and run is vendored:

- `m68k.h`, `m68kconf.h`, `m68kcpu.h`, `m68kcpu.c`, `m68kmmu.h` - the
  core itself and its public API.
- `m68kfpu.c` - `m68kcpu.c` unconditionally `#include`s this regardless
  of whether FPU/68040 emulation is actually configured on, so it's
  vendored even though nothing here ever exercises 68881/68040 opcodes
  (68000-only, `M68K_CPU_TYPE_68000`, is the only CPU type
  `src/musashi_bench.zig` ever selects).
- `softfloat/` (`softfloat.c`, `softfloat.h`, `milieu.h`, `mamesf.h`,
  `softfloat-macros`, `softfloat-specialize`) - `m68kfpu.c` needs
  softfloat's implementation to link, again regardless of whether it's
  ever actually called. Confirmed by direct experience, not assumed:
  omitting `softfloat.c` produces real undefined-symbol linker errors
  (`floatx80_to_int32_round_to_zero`, `int32_to_floatx80`, etc.) even
  when building for 68000 only, and omitting `mamesf.h` produces a real
  `'mamesf.h' file not found` compile error (`milieu.h` `#include`s it
  unconditionally - it's upstream's own basic-integer-typedefs header
  for this softfloat release, not an optional MAME extra despite the
  name). `softfloat/README.txt` is the one genuinely unneeded file.
- `m68k_in.c` - not compiled directly; it's a *data file* for the code
  generator below (opcode primitive definitions in Musashi's own
  domain-specific format).
- `m68kmake.c` - the code generator itself. Musashi ships its opcode
  dispatch tables (`m68kops.c`/`m68kops.h`) as a build-time codegen
  step, not as static source: `m68kmake` reads `m68k_in.c` and emits
  them. `build.zig` compiles this as a native host tool and runs it
  (the same "compile a small C generator, run it, feed its output back
  into the real build" shape as this project's other build-time code
  generation).

Not vendored: `m68kdasm.c` (disassembler - nothing here disassembles,
only executes and counts cycles), `example/`, `test/`,
`softfloat/README.txt`.

## License

MIT (Karl Stenerud) - see `docs/LICENSES.md` §11 for the full text as
verified against upstream's own `readme.txt`. Permissive, no copyleft;
the only obligation is retaining the copyright/permission notice, which
this README and the vendored files themselves both do.

## Configuration note

`m68kconf.h` exposes a large set of compile-time `M68K_EMULATE_*` flags
for enabling/disabling specific CPU features. None of them are edited
here - `src/musashi_bench.zig` instead selects the 68000 model entirely
at runtime via `m68k_set_cpu_type(M68K_CPU_TYPE_68000)`, which is
Musashi's own documented, supported way to pick a CPU model without
touching this file, so the vendored config stays byte-identical to
upstream.
