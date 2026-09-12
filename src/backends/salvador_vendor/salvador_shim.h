/* Our own glue, not upstream salvador - see README.md.
 *
 * Declares only the functions salvador.zig actually calls, rather than
 * exposing libsalvador.h/shrink.h/expand.h to @cImport directly:
 * shrink.h defines several bitfield-heavy internal structs
 * (salvador_arrival, salvador_match, ...) that aren't needed here and
 * that crashed Zig's translate-c (a SIGBUS inside the `aro` C frontend)
 * when the full header chain was exposed to @cImport. This sidesteps
 * that entirely - salvador_shim.c still includes the real headers (so
 * the compiler checks these declarations match), Zig just never has to
 * translate them.
 *
 * Named salvador_shim.h/.c, not the more obvious shim.h/shim.c: @cImport's
 * @cInclude has no "including file's own directory" to prefer the way a
 * plain C #include does (there's no real file doing the including - it
 * builds a synthetic translation unit from the global module include
 * path alone), so a same-named shim.h already used by another vendored
 * backend (zx0_vendor's) would shadow this one depending on -I order,
 * silently pulling in the wrong declarations. Confirmed by hitting
 * exactly that: @cInclude("shim.h") here resolved to zx0_vendor/shim.h
 * instead, and the resulting undefined-symbol error looked nothing like
 * a naming collision until traced back.
 */
#ifndef EXECRAM_SALVADOR_SHIM_H
#define EXECRAM_SALVADOR_SHIM_H

#include <stddef.h>

#define EXECRAM_FLG_IS_INVERTED 1 /* matches libsalvador.h's FLG_IS_INVERTED */

size_t salvador_compress_buffer(
    const unsigned char *pInputData,
    unsigned char *pOutBuffer,
    size_t nInputSize,
    size_t nMaxOutBufferSize
);

size_t salvador_max_compressed_size(size_t nInputSize);

size_t salvador_decompress_buffer(
    const unsigned char *pInputData,
    unsigned char *pOutData,
    size_t nInputSize,
    size_t nMaxOutBufferSize
);

#endif
