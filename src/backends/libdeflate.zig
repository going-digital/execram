//! The "libdeflate" backend: another alternative host-side compressor
//! for the exact same container/depacker as the "inflate" backend (see
//! src/backends/libdeflate_vendor/README.md for why no new stub is
//! needed). libdeflate's own near-optimal parser aims for ratios
//! competitive with zultra at libdeflate's own maximum compression
//! level, producing standard raw DEFLATE - stubs/inflate/'s depacker
//! doesn't know or care which encoder wrote the bytes it's
//! decompressing.

const std = @import("std");
const flatten = @import("../flatten.zig");
const inflate = @import("inflate.zig");

const c = @cImport({
    @cInclude("libdeflate.h");
});

/// libdeflate's own scale tops out at 12 ("slowest", its best ratio) -
/// see libdeflate.h's own doc comment on libdeflate_alloc_compressor().
const compression_level = 12;

/// libdeflate produces standard raw DEFLATE - the same format
/// "inflate" does - so its decompression is exactly Zig's own decoder,
/// not anything libdeflate-specific. Used by main.zig's pack-time
/// self-check.
pub const decompress = inflate.decompress;

pub fn compress(allocator: std.mem.Allocator, image: flatten.FlatImage) ![]u8 {
    const input = try std.mem.concat(allocator, u8, &.{ image.code_data, image.reloc_stream });
    defer allocator.free(input);

    const compressor = c.libdeflate_alloc_compressor(compression_level) orelse return error.OutOfMemory;
    defer c.libdeflate_free_compressor(compressor);

    const bound = c.libdeflate_deflate_compress_bound(compressor, input.len);
    const out = try allocator.alloc(u8, bound);
    errdefer allocator.free(out);

    const compressed_size = c.libdeflate_deflate_compress(compressor, input.ptr, input.len, out.ptr, out.len);
    if (compressed_size == 0) return error.LibdeflateCompressionFailed;

    return allocator.realloc(out, compressed_size);
}

test "compress produces a raw DEFLATE stream Zig's own decompressor accepts" {
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

    // Round-trip through Zig's own decompressor (via the real
    // `decompress` function above, shared with inflate's), same
    // independent check as the inflate/zultra backends' tests - proves
    // this is valid DEFLATE, not just "the vendored library ran
    // without crashing".
    const decoded = try decompress(std.testing.allocator, compressed, expected.len);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualSlices(u8, expected, decoded);

    try std.testing.expect(compressed.len < expected.len);
}
