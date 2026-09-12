//! The "salvador" backend: an alternative optimal-parse ZX0 compressor
//! for the exact same depacker as the "zx0" backend (see
//! src/backends/salvador_vendor/README.md - confirmed by diffing
//! salvador's own bundled copy of the 68k depacker against
//! stubs/zx0/unzx0_68000.s and finding them byte-identical, not just
//! assumed compatible from format documentation).

const std = @import("std");
const flatten = @import("../flatten.zig");

const c = @cImport({
    @cInclude("salvador_shim.h");
});

pub fn compress(allocator: std.mem.Allocator, image: flatten.FlatImage) ![]u8 {
    const input = try std.mem.concat(allocator, u8, &.{ image.code_data, image.reloc_stream });
    defer allocator.free(input);

    const bound = c.salvador_max_compressed_size(input.len);
    const out = try allocator.alloc(u8, bound);
    errdefer allocator.free(out);

    const compressed_size = c.salvador_compress_buffer(input.ptr, out.ptr, input.len, out.len);
    if (compressed_size == std.math.maxInt(usize)) return error.SalvadorCompressionFailed;

    return allocator.realloc(out, compressed_size);
}

test "compress produces a smaller result that salvador's own decompressor accepts" {
    var image = flatten.FlatImage{
        .allocator = std.testing.allocator,
        .code_data = try std.testing.allocator.dupe(u8, "hello hello hello hello, execram execram execram"),
        .bss_size = 0,
        .reloc_stream = try std.testing.allocator.dupe(u8, &.{0xFE}),
        .mem_chip = false,
    };
    defer image.deinit();

    const compressed = try compress(std.testing.allocator, image);
    defer std.testing.allocator.free(compressed);

    const expected = try std.mem.concat(std.testing.allocator, u8, &.{ image.code_data, image.reloc_stream });
    defer std.testing.allocator.free(expected);
    try std.testing.expect(compressed.len < expected.len);

    // Round-trip through salvador's own decompressor - an independent
    // code path from the actual 68k depacker, same spirit as using
    // Zig's own Decompress for the inflate/zultra backends' tests.
    const decoded = try std.testing.allocator.alloc(u8, expected.len + 16);
    defer std.testing.allocator.free(decoded);
    const decoded_size = c.salvador_decompress_buffer(compressed.ptr, decoded.ptr, compressed.len, decoded.len);
    try std.testing.expectEqual(expected.len, decoded_size);
    try std.testing.expectEqualSlices(u8, expected, decoded[0..decoded_size]);
}
