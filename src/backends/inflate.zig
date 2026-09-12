//! The "inflate" backend: real DEFLATE compression via Zig's standard
//! library (`std.compress.flate`), matching the depacker in
//! stubs/inflate/ (a vendored/adapted Keir Fraser `inflate.S` - see
//! stubs/inflate/README.md). Raw DEFLATE, no zlib/gzip wrapper: the
//! depacker doesn't need one and it's a few bytes of pure overhead.

const std = @import("std");
const flatten = @import("../flatten.zig");

pub fn compress(allocator: std.mem.Allocator, image: flatten.FlatImage) ![]u8 {
    // Compress.init asserts the output writer's buffer is > 8 bytes;
    // Allocating.init alone starts with an empty buffer.
    var allocating: std.Io.Writer.Allocating = try .initCapacity(allocator, 256);
    defer allocating.deinit();

    var window_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var compressor = try std.compress.flate.Compress.init(
        &allocating.writer,
        &window_buffer,
        .raw,
        .level_9,
    );

    try compressor.writer.writeAll(image.code_data);
    try compressor.writer.writeAll(image.reloc_stream);
    try compressor.finish();

    return allocating.toOwnedSlice();
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

    // Round-trip through Zig's own decompressor as an independent check
    // that what we wrote is valid DEFLATE, not just "assembled without
    // erroring" - mirrors using vlink to check hunk.zig against another
    // tool's understanding of the hunk format.
    var reader: std.Io.Reader = .fixed(compressed);
    var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var decompressor: std.compress.flate.Decompress = .init(&reader, .raw, &decompress_buffer);

    const decoded = try decompressor.reader.allocRemaining(std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(decoded);

    const expected = try std.mem.concat(std.testing.allocator, u8, &.{ image.code_data, image.reloc_stream });
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualSlices(u8, expected, decoded);

    // A real compressor, unlike "store" - this input compresses.
    try std.testing.expect(compressed.len < expected.len);
}
