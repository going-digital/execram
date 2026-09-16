//! The "zopfli" backend: another alternative host-side compressor for
//! the exact same container/depacker as the "inflate" backend (see
//! src/backends/zopfli_vendor/README.md for why no new stub is
//! needed). Zopfli's iterative, cost-based "squeeze" LZ77 parse is the
//! original reference algorithm zultra and libdeflate's own
//! near-optimal parsers are inspired by/compared against, producing
//! standard raw DEFLATE - stubs/inflate/'s depacker doesn't know or
//! care which encoder wrote the bytes it's decompressing.

const std = @import("std");
const flatten = @import("../flatten.zig");
const inflate = @import("inflate.zig");

const c = @cImport({
    @cInclude("zopfli.h");
    @cInclude("deflate.h");
});

/// Zopfli produces standard raw DEFLATE - the same format "inflate"
/// does - so its decompression is exactly Zig's own decoder, not
/// anything Zopfli-specific. Used by main.zig's pack-time self-check.
pub const decompress = inflate.decompress;

pub fn compress(allocator: std.mem.Allocator, image: flatten.FlatImage) ![]u8 {
    const input = try std.mem.concat(allocator, u8, &.{ image.code_data, image.reloc_stream });
    defer allocator.free(input);

    var options: c.ZopfliOptions = undefined;
    c.ZopfliInitOptions(&options);

    var out: [*c]u8 = null;
    var out_size: usize = 0;
    var bp: u8 = 0;
    // btype=2 (dynamic Huffman blocks, Zopfli's own recommendation for
    // best compression), final=1 (this is the only/last "master
    // block" execram ever asks Zopfli to produce).
    c.ZopfliDeflate(&options, 2, 1, input.ptr, input.len, &bp, &out, &out_size);
    defer std.c.free(out);
    if (out_size == 0) return error.ZopfliCompressionFailed;

    return allocator.dupe(u8, out[0..out_size]);
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
    // independent check as the inflate/zultra/libdeflate backends'
    // tests - proves this is valid DEFLATE, not just "the vendored
    // library ran without crashing".
    const decoded = try decompress(std.testing.allocator, compressed, expected.len);
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualSlices(u8, expected, decoded);

    try std.testing.expect(compressed.len < expected.len);
}
