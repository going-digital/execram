# store

The baseline backend: no compression at all. The "compressed" payload
is `code_data ++ reloc_stream`, byte-for-byte (`src/backends/store.zig`).
Its depacker (`stubs/store/stub.s`) is a plain longword copy loop from
the container's payload straight into the resident buffer
`stubs/common/runtime.i` already allocated - there is nothing to
decode.

## Why it exists

Two reasons, one from each end of the project's life:

- **M1**: proved the container format's runtime algorithm (AllocMem,
  copy, relocation fixup, jump) end to end before any real
  decompressor existed to test against. If something was wrong with
  the shared machinery in `runtime.i`, it needed to show up here first,
  not be confused with a compression bug.
- **Ongoing**: a floor `--backend=auto` always has available. Every
  compressor here can, on sufficiently small or already-dense input,
  produce output *larger* than the original (container header and stub
  overhead have to go somewhere) - `store` is what `auto` falls back to
  when every real compressor loses that trade, and it's also the
  fastest possible "compression" for a quick pack/verify cycle during
  development.

## Format

None. `Depack:` is a plain copy loop from the compressed payload
straight into the buffer `stubs/common/runtime.i` already allocated for
the resident image (`Start:` decompresses directly into `final`, not a
separate scratch buffer - see `docs/format-spec.md` §8) - `store`'s own
`Depack:` is *literally* that copy loop, since there's nothing to
decode. `RelocFixup`, if the header says it's needed, is shared by every
backend already, also in `stubs/common/runtime.i`.

## Overlap-mode margin

`store` supports the overlap layout (`docs/format-spec.md` §8b) - its
`Depack:` (`stubs/store/depack_core.s`) is completely unchanged; the same
one routine serves both layouts, since `stubs/common/runtime.i`'s
`Start:` branches on `FLAG_OVERLAP` only in how it locates `Depack`'s own
input, not in which stub gets assembled. Since it reads and writes in
strict lockstep - one longword (or, for the last 0-3 bytes, one byte)
read from A0 immediately followed by the matching write to A1, never
getting ahead in one direction before catching up in the other - the
write pointer never leads the read pointer by more than a few bytes at
any point during decompression. `src/musashi_bench.zig`'s
`measureOverlapMargin`, run against real input, confirms this
empirically: 0 bytes on every input tried so far (`execram pack
--backend=store --overlap=on -v` prints the measured margin for any
given file). Not assumed as a fixed constant - `execram pack` always
measures the real payload being packed, per `docs/format-spec.md` §8b -
but store's own copy-loop structure means it should stay at or near 0
for any input.

Because `store` never actually shrinks its input, `compressed_size`
routinely equals (or nearly equals) the resident image's own
`residentTailSize`, which in turn means the overlap layout's own
on-disk-fit requirement (room for the trampoline before the payload,
`docs/format-spec.md` §8b) - not the (near-zero) margin - is usually
what decides the allocated size for this specific backend. `--overlap=auto`
often prefers the disjoint layout for `store` as a result: the overlap
layout only wins on peak memory when there's real compression to avoid
double-buffering, and `store` provides none.
