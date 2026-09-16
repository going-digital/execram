# Algorithm notes

One page per backend *format* (not per host-side compressor, since more
than one compressor can target the same depacker - see each note's own
intro): a conceptual explanation of how the compression actually works,
distinct from `docs/LICENSES.md` (the legal audit) and each vendored
directory's own `README.md` (provenance: exact upstream commit, exactly
what was changed and why).

- [store.md](store.md) - no compression, the M1 baseline and `auto`'s floor
- [inflate.md](inflate.md) - standard DEFLATE (`inflate`, `zultra`, `libdeflate`, and `zopfli`)
- [zx0.md](zx0.md) - ZX0's depacker-minimal LZ77 (`zx0` and `salvador`)
- [shrinkler.md](shrinkler.md) - LZ77 + adaptive range coding, the LZMA-family backend
- [lz4.md](lz4.md) - LZ4, trading ratio for decompression speed (`lz4small`/`lz4normal`/`lz4fast`)
