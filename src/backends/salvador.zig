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

/// Decompresses via salvador's own vendored decoder - an independent
/// code path from the actual 68k depacker, used both by this module's
/// own round-trip test and by main.zig's pack-time self-check (M5), and
/// by zx0.zig's own `decompress` (see that file's comment on why it
/// delegates here instead of vendoring a second ZX0 decoder).
/// `expected_len` sizes the output buffer salvador's C API needs
/// preallocated - unlike inflate's self-terminating format, ZX0 has no
/// end-of-stream marker of its own kind that doesn't need one.
pub fn decompress(allocator: std.mem.Allocator, payload: []const u8, expected_len: usize) ![]u8 {
    const out = try allocator.alloc(u8, expected_len);
    errdefer allocator.free(out);
    const decoded_size = c.salvador_decompress_buffer(payload.ptr, out.ptr, payload.len, out.len);
    if (decoded_size != expected_len) return error.SalvadorDecompressionMismatch;
    return out;
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

    // Round-trip through the real `decompress` function above (salvador's
    // own decoder) - an independent code path from the actual 68k
    // depacker, same spirit as using Zig's own Decompress for the
    // inflate/zultra backends' tests.
    const decoded = try decompress(std.testing.allocator, compressed, expected.len);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualSlices(u8, expected, decoded);
}
