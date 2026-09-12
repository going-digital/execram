//! The "zultra" backend: an alternative, stronger host-side compressor
//! for the exact same container/depacker as the "inflate" backend (see
//! src/backends/zultra_vendor/README.md for why no new stub is needed).
//! Zultra aims for zopfli-like ratios at more practical speed than an
//! exhaustive search, producing standard raw DEFLATE -
//! stubs/inflate/'s depacker doesn't know or care which encoder wrote
//! the bytes it's decompressing.

const std = @import("std");
const flatten = @import("../flatten.zig");
const inflate = @import("inflate.zig");

const c = @cImport({
    @cInclude("libzultra.h");
});

/// Zultra produces standard raw DEFLATE - the same format "inflate"
/// does - so its decompression is exactly Zig's own decoder, not
/// anything Zultra-specific. Used by main.zig's pack-time self-check.
pub const decompress = inflate.decompress;

pub fn compress(allocator: std.mem.Allocator, image: flatten.FlatImage) ![]u8 {
    const input = try std.mem.concat(allocator, u8, &.{ image.code_data, image.reloc_stream });
    defer allocator.free(input);

    const bound = c.zultra_memory_bound(input.len, c.ZULTRA_FLAG_DEFLATE_FRAMING, 0);
    const out = try allocator.alloc(u8, bound);
    errdefer allocator.free(out);

    const compressed_size = c.zultra_memory_compress(
        input.ptr,
        input.len,
        out.ptr,
        out.len,
        c.ZULTRA_FLAG_DEFLATE_FRAMING,
        0,
    );
    if (compressed_size == std.math.maxInt(usize)) return error.ZultraCompressionFailed;

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
    // independent check as the inflate backend's test - proves this is
    // valid DEFLATE, not just "the vendored library ran without
    // crashing".
    const decoded = try decompress(std.testing.allocator, compressed, expected.len);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualSlices(u8, expected, decoded);

    try std.testing.expect(compressed.len < expected.len);
}
