//! The "shrinkler" backend: Shrinkler's own LZ + adaptive range coder
//! (docs/LICENSES.md #1), the highest-ratio backend in execram (M4 -
//! PROJECT_PLAN.md). Unlike inflate/zx0's drop-in-compatible formats,
//! this is Shrinkler's own bitstream, decoded on the Amiga side by a
//! directly adapted copy of its actual depacker
//! (stubs/shrinkler/ShrinklerDecompress.s), not a from-scratch
//! reimplementation - see that file and shrinkler_vendor/README.md for
//! the license basis (permissive, decrunch code public-domain-
//! equivalent).

const std = @import("std");
const flatten = @import("../flatten.zig");

const c = @cImport({
    @cInclude("shrinkler_shim.h");
});

pub fn compress(allocator: std.mem.Allocator, image: flatten.FlatImage) ![]u8 {
    const input = try std.mem.concat(allocator, u8, &.{ image.code_data, image.reloc_stream });
    defer allocator.free(input);

    var out_data: [*c]u8 = undefined;
    var out_len: usize = undefined;
    if (c.shrinkler_compress_buffer(input.ptr, input.len, &out_data, &out_len) != 0) {
        return error.ShrinklerCompressionFailed;
    }
    defer c.shrinkler_free_buffer(out_data);

    const result = try allocator.alloc(u8, out_len);
    @memcpy(result, out_data[0..out_len]);
    return result;
}

test "compress produces a smaller result that shrinkler's own decompressor accepts" {
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

    // Round-trip through Shrinkler's own reference decoder
    // (RangeDecoder.h/LZDecoder.h) - an independent code path from the
    // actual 68k depacker, same spirit as every other backend's test.
    const decoded = try std.testing.allocator.alloc(u8, expected.len + 16);
    defer std.testing.allocator.free(decoded);
    const decoded_size = c.shrinkler_decompress_buffer(compressed.ptr, compressed.len, decoded.ptr, decoded.len);
    try std.testing.expect(decoded_size != std.math.maxInt(usize));
    try std.testing.expectEqualSlices(u8, expected, decoded[0..decoded_size]);
}
