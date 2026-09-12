/* Our own glue, not upstream ZX0 - see README.md. */
#ifndef EXECRAM_ZX0_SHIM_H
#define EXECRAM_ZX0_SHIM_H

/* Compresses input_data[0..input_size) into a freshly malloc'd buffer,
 * using ZX0's default (non-classic, non-backwards) format - the one
 * stubs/zx0/unzx0_68000.s decompresses. Returns NULL on failure.
 * *output_size receives the compressed length. Caller must free() the
 * returned pointer. */
unsigned char *zx0_compress_buffer(unsigned char *input_data, int input_size, int *output_size);

#endif
