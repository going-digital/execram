/* Our own glue, not upstream ZX0 - see README.md.
 *
 * Calls the vendored optimize()/compress() with the same parameters
 * ZX0's reference CLI (zx0.c, not vendored) uses for its default mode:
 * no skip, MAX_OFFSET_ZX0 (32640, the full non-"quick" search range),
 * not backwards, invert_mode on (classic_mode off, backwards off - see
 * zx0.c's `!classic_mode && !backwards_mode`). This is the format
 * stubs/zx0/unzx0_68000.s decompresses.
 */

#include "zx0.h"
#include "shim.h"

#define MAX_OFFSET_ZX0 32640

unsigned char *zx0_compress_buffer(unsigned char *input_data, int input_size, int *output_size) {
    int delta;
    BLOCK *optimal = optimize(input_data, input_size, 0, MAX_OFFSET_ZX0);
    return compress(optimal, input_data, input_size, 0, 0, 1, output_size, &delta);
}
