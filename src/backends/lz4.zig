//! The "lz4small"/"lz4normal"/"lz4fast" backends: one host-side
//! compressor (LZ4HC, at its own maximum compression level) shared by
//! three depacker stubs that trade code size for decompression speed
//! (stubs/lz4/README.md) - all three produce and consume the exact
//! same raw LZ4 block format, so the compressed payload bytes are
//! identical regardless of which stub main.zig pairs this with; only
//! the embedded stub differs.

const std = @import("std");
const flatten = @import("../flatten.zig");

const c = @cImport({
    @cInclude("lz4.h");
    @cInclude("lz4hc.h");
});

pub fn compress(allocator: std.mem.Allocator, image: flatten.FlatImage) ![]u8 {
    const input = try std.mem.concat(allocator, u8, &.{ image.code_data, image.reloc_stream });
    defer allocator.free(input);

    const bound = c.LZ4_compressBound(@intCast(input.len));
    if (bound <= 0) return error.Lz4InputTooLarge;
    const out = try allocator.alloc(u8, @intCast(bound));
    errdefer allocator.free(out);

    const compressed_size = c.LZ4_compress_HC(
        input.ptr,
        out.ptr,
        @intCast(input.len),
        @intCast(out.len),
        c.LZ4HC_CLEVEL_MAX,
    );
    if (compressed_size <= 0) return error.Lz4CompressionFailed;

    return allocator.realloc(out, @intCast(compressed_size));
}

/// Real LZ4 decompression via the vendored library's own
/// `LZ4_decompress_safe()` - an independent code path from the actual
/// 68k depacker, used both by this module's own round-trip test and by
/// main.zig's pack-time self-check (M5), same role
/// `inflate.zig`'s Zig-stdlib decoder plays for the DEFLATE family.
pub fn decompress(allocator: std.mem.Allocator, payload: []const u8, expected_len: usize) ![]u8 {
    const out = try allocator.alloc(u8, expected_len);
    errdefer allocator.free(out);

    const decompressed_size = c.LZ4_decompress_safe(
        payload.ptr,
        out.ptr,
        @intCast(payload.len),
        @intCast(out.len),
    );
    if (decompressed_size < 0 or @as(usize, @intCast(decompressed_size)) != expected_len) {
        return error.Lz4DecompressionMismatch;
    }
    return out;
}

test "compress produces a raw LZ4 block LZ4_decompress_safe accepts" {
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

    const decoded = try decompress(std.testing.allocator, compressed, expected.len);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualSlices(u8, expected, decoded);

    try std.testing.expect(compressed.len < expected.len);
}
