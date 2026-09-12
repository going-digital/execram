/* Our own glue, not upstream Shrinkler - see README.md.
 *
 * Plain C-linkage declarations only, deliberately excluding any of the
 * vendored C++ headers (Pack.h, LZParser.h, ...): those use templates,
 * STL containers and other C++ features @cImport's translate-c has no
 * hope of handling, matching the same reasoning already documented in
 * src/backends/salvador_vendor/salvador_shim.h for a plain-C SIGBUS
 * (this would be worse - actual template instantiation, not just
 * bitfield structs). shrinkler_shim.cpp still includes the real
 * headers and is compiled as C++, Zig just never has to translate them.
 *
 * Named shrinkler_shim.h/.cpp, not shim.h/shim.c: @cImport's @cInclude
 * has no "including file's own directory" preference the way a plain C
 * #include does, so a same-named shim.h already used by another
 * vendored backend would shadow this one depending on -I order -
 * see src/backends/salvador_vendor/salvador_shim.h for the exact
 * collision this already caused once in this project.
 */
#ifndef EXECRAM_SHRINKLER_SHIM_H
#define EXECRAM_SHRINKLER_SHIM_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Compresses `data_len` bytes at `data` using Shrinkler's LZ + adaptive
 * range coder (preset -3 equivalent: iterations=3, length_margin=3,
 * skip_length=3000, match_patience=300, max_same_length=30 - Shrinkler
 * CLI's own default preset, see cruncher/Shrinkler.cpp's DigitParameter
 * default), with the parity context enabled (Shrinkler's own default
 * for --data mode, i.e. the *absence* of the --bytes flag). Both of
 * these are compile-time constants here, not runtime options, since
 * the depacker stub (stubs/shrinkler/stub.s) bakes in the matching
 * parity-context choice at assembly time - the two sides must agree,
 * and there is nowhere in execram's container format to carry a
 * per-file choice (see README.md).
 *
 * On success, returns a malloc()'d buffer of exactly the compressed
 * size via *out_data/*out_len - the true size is only known once
 * compression finishes (unlike zx0/salvador, there's no cheap
 * worst-case bound to preallocate against), so ownership transfers to
 * the caller; free it with shrinkler_free_buffer(). Returns 0 on
 * success, nonzero on failure (out_data/out_len left untouched).
 */
int shrinkler_compress_buffer(
    const unsigned char *data,
    size_t data_len,
    unsigned char **out_data,
    size_t *out_len
);

void shrinkler_free_buffer(unsigned char *data);

/* Decompresses Shrinkler-format `data_len` bytes at `data` (as produced
 * by shrinkler_compress_buffer above) into `out`, which must be at
 * least `out_capacity` bytes. Uses Shrinkler's own reference decoder
 * (RangeDecoder.h/LZDecoder.h) - an independent code path from the
 * actual 68k depacker, same rigor as every other backend's round-trip
 * test. Returns the decompressed size, or SIZE_MAX on error (including
 * out_capacity being too small).
 */
size_t shrinkler_decompress_buffer(
    const unsigned char *data,
    size_t data_len,
    unsigned char *out,
    size_t out_capacity
);

#ifdef __cplusplus
}
#endif

#endif
