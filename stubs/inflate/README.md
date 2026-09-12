# Why this stub uses a different vasm syntax module

Every other stub in this project is Motorola/Devpac syntax
(`vasmm68k_mot`), matching `stubs/common/runtime.i`. This one needs
`vasmm68k_std` (vasm's GNU-as-style module) instead, because it
`.include`s `inflate_core.s` - a vendored/adapted copy of
[Keir Fraser's `inflate.S`](https://github.com/keirf/Amiga-Stuff/blob/master/inflate/inflate.S)
(Unlicense - see `docs/LICENSES.md` §4), which is itself written for a
real C-preprocessor pass followed by assembly in a GAS-like dialect (`0x`
hex, `.macro`/`.endm`), not Devpac/Motorola syntax.

vasm's syntax module is chosen per invocation (`vasmm68k_mot` and
`vasmm68k_std` are different binaries built from the same vasm source
tree, not different tools) and can't be mixed within one assembly, so
`runtime.i`/`header.i` needed std-syntax counterparts too:
`runtime_std.i`/`header_std.i`. They're a maintained-by-hand duplicate,
not shared with the mot-syntax originals - see the note at the top of
`runtime_std.i` for why sharing one file across both modules didn't
work out, and keep the two in sync by hand if `runtime.i`'s logic ever
changes.

## What changed going from upstream `inflate.S` to `inflate_core.s`

1. **Preprocessed** with `cpp -P -DOPT_STORAGE_OFFSTACK=1
   -DOPT_INLINE_FUNCTIONS=0` (every other option at upstream's own
   default - see the options block near the top of the original file).
   - `OPT_STORAGE_OFFSTACK=1`: inflate's ~2-3KB of scratch space comes
     from a block we `AllocMem` (see `stub.s`'s `Depack`), not the
     stack - a plain hunk-loaded process's default stack is small
     enough that we didn't want to gamble on this fitting.
   - `OPT_INLINE_FUNCTIONS=0`: costs ~15% speed and saves ~164 bytes
     per upstream's own comment, but avoids a real vasm limitation
     (below) that inlining triggers here.
2. **GNU-as m68k's auto-sizing `j<cc>` pseudo-branches** (`jeq`, `jra`,
   `jbsr`, ...) made explicit (`beq.w`, `bra.w`, `bsr.w`, ...) - vasm's
   std module doesn't implement that m68k-specific GAS extension.
   (`jsr` itself is a real 68k instruction - an indexed jump-to-
   subroutine - and was left alone.)
3. **Two macros with numeric local labels above 9** (`STREAM_NEXT_BITS`,
   `STREAM_NEXT_SYMBOL`, both using labels like `97:`/`98:`/`99:`)
   manually inlined at their call site with named labels instead of
   left as `.macro`/`.endm` blocks. Confirmed by testing: vasm's std
   module only supports single-digit (0-9) numeric local labels, and
   separately does not resolve numeric labels correctly inside macro
   bodies at all (even single-digit ones) - either problem alone would
   have broken this. `-DOPT_INLINE_FUNCTIONS=0` already made each of
   these two macros used exactly once, so inlining them by hand was a
   pure textual substitution with no semantic change - each renamed
   label was traced by hand against GAS's forward("f")/backward("b")
   nearest-occurrence resolution rules to get the mapping right.

4. **Every remaining single-digit numeric local label** (`1:`/`1b`/`1f`
   through `9:`/`9b`/`9f`, ~30 occurrences) renamed to a unique,
   descriptively-prefixed name (`.bc1`, `.dh4`, `.dl2`, ...) - added
   2026-09-12, after item 3 above (written 2026-09-11 or earlier) had
   already confirmed *single-digit* numeric locals worked fine in the
   `vasmm68k_std` build available at the time. A Homebrew package
   update to `vasmm68k` 1.8e sometime afterward silently regressed
   this: its std-syntax module's own documented local-label support
   (per upstream's `history` file) has only ever been `n$` or `.nnn`,
   never bare `n:`/`nb`/`nf` - single-digit numeric locals apparently
   only worked before by some now-lost behavior, not a documented
   feature, and stopped working entirely with this error ("identifier
   expected" at every `N:`). `vasmm68k_std -gas` does accept the syntax
   again, but switches vasm's comment character away from `;` (used
   throughout every file this stub includes) to GAS's own convention,
   which is worse, not better. Each renamed label was traced by hand
   against GAS's forward("f")/backward("b") nearest-occurrence
   resolution rules, the same rigor item 3 above already used - and
   independently double-checked by assembling both the original and
   renamed source with a real GNU binutils `as` (`;`-comments swapped
   for `|` just for that check, not committed) and confirming the two
   `.text` sections are byte-for-byte identical.

No logic was changed beyond that: same instructions, same order, just
different spellings of the same things (`.byte`/`.word`/`.long` instead
of `dc.b`/`dc.w`/`dc.l`, `0x` hex kept as-is) plus the two macro bodies
pasted inline instead of expanded by the assembler, plus item 4's
label renames.
