/* Our own glue, not upstream salvador - see README.md and shim.h. */

#include <stddef.h> /* shrink.h/expand.h use size_t without including it themselves */
#include "libsalvador.h"
#include "salvador_shim.h"

size_t salvador_max_compressed_size(size_t nInputSize) {
    return salvador_get_max_compressed_size(nInputSize);
}

size_t salvador_compress_buffer(
    const unsigned char *pInputData,
    unsigned char *pOutBuffer,
    size_t nInputSize,
    size_t nMaxOutBufferSize
) {
    return salvador_compress(pInputData, pOutBuffer, nInputSize, nMaxOutBufferSize,
        FLG_IS_INVERTED, 0, 0, NULL, NULL);
}

size_t salvador_decompress_buffer(
    const unsigned char *pInputData,
    unsigned char *pOutData,
    size_t nInputSize,
    size_t nMaxOutBufferSize
) {
    return salvador_decompress(pInputData, pOutData, nInputSize, nMaxOutBufferSize, 0, FLG_IS_INVERTED);
}
