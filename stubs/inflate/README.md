# `inflate_core.s` provenance and conversion history

`inflate_core.s` is a vendored/adapted copy of
[Keir Fraser's `inflate.S`](https://github.com/keirf/Amiga-Stuff/blob/master/inflate/inflate.S)
(Unlicense - see `docs/LICENSES.md` §4), a real DEFLATE decompressor for
the 68000. Upstream is written for a real C-preprocessor pass followed
by assembly in a GAS-like dialect (`0x` hex, `.macro`/`.endm`, numeric
local labels), not Devpac/Motorola syntax - getting it to assemble
under this project's toolchain took several steps, most of which are
now historical (this stub uses ordinary `vasmm68k_mot` today, like
every other stub in the project - see `inflate_core.s`'s own header
comment for the condensed version of this history).

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
   std module (used for this step, at the time) didn't implement that
   m68k-specific GAS extension. (`jsr` itself is a real 68k instruction
   - an indexed jump-to-subroutine - and was left alone.)
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
5. **(2026-09-16) 36 of the `.w` branches from steps 2-3 shrunk to
   `.s`** (72 bytes smaller): those steps chose the safe, always-
   correct `.w` (word displacement) form for every GAS auto-sizing
   pseudo-branch rather than computing which ones a byte displacement
   actually reaches. Measured directly from vasm's own assembled
   listing, re-measured after each fix since shrinking one branch can
   pull a later target within range of an earlier one (three passes,
   converging at 0 remaining) - restores what upstream's own auto-
   sizing assembler would have chosen. No logic changed: same
   branches, same targets, only the encoding size.
6. **(2026-09-16) Converted from vasm's std syntax to mot
   (Motorola/Devpac) syntax**, so this stub no longer needs a second
   vasm toolchain. Three kinds of change:
   - `.byte` -> `dc.b`, `0x` hex -> `$` hex: mechanical directive/
     literal spelling, no value change.
   - Whitespace tightened around a handful of parenthesized arithmetic
     expressions (e.g. `#(16 +1)/2` -> `#(16+1)/2`): mot's expression
     parser is whitespace-sensitive there in a way std's wasn't. No
     value change - confirmed by re-deriving each edited expression by
     hand.
   - Every step-4 local label's leading dot stripped (`.dh4` -> `dh4`,
     ...). vasm's mot module scopes a `.name` label to the nearest
     preceding non-dot ("real") label, unlike std's flat namespace -
     and this file interleaves real labels (`c_16`, `c_17`, `c_18`,
     `c_lit`, `codelen_le_8`, `codelen_gt_8`) inside routine bodies in
     a way that crosses those scope boundaries (e.g.
     `dynamic_huffman`'s `.dh5`/`.dh6`/`.dh8` are each defined and
     referenced from opposite sides of a `c_1N`/`c_lit` label) -
     confirmed as the actual failure mode by reproducing it (mot
     reported "undefined symbol" for exactly the labels on the far
     side of such a boundary). Since step 4 already gave every local
     label a globally-unique name (precisely so std mode's flat
     namespace wouldn't collide), making them ordinary global labels
     under mot is a safe, purely mechanical change - it's exactly how
     std mode already treated them.

   Separately (not a local-label issue), `dispatch:`'s
   `dc.b <label>-<label>` entries hit a vasm-mot quirk: "data out of
   range" for a `dc.b` byte-difference between two labels, regardless
   of the computed value's actual size (confirmed via a real assembled
   listing that the true deltas are 24 and 42, comfortably within a
   byte) - worked around by precomputing each via its own `=` symbol
   first (`DISPATCH_STATIC_OFS = static_huffman-uncompressed_block`)
   and emitting that symbol instead of the raw expression, which
   vasm-mot accepts without complaint.

   Verified byte-identical against the pre-conversion std-syntax build
   at every level: `inflate_core.s` alone (766 bytes, same MD5), and
   the full assembled `stub.s` (`vasmm68k_std` on the old sources vs.
   `vasmm68k_mot` on the new ones - byte-for-byte identical output).

No logic was changed by any of the above beyond what's noted: same
instructions, same order, same branch targets - just different
spellings of the same things, two macro bodies pasted inline instead
of expanded by the assembler, and label renames.
