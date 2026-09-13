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
