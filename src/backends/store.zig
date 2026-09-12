//! The "store" backend: no compression at all. Its "compressed" payload
//! is simply code_data ++ reloc_stream verbatim - see
//! stubs/store/stub.s for the matching depacker (a copy loop). Exists to
//! prove the container format's runtime algorithm end to end (M1)
//! before any real compression backend does, and as a baseline
//! `--backend=auto` always has available.

const std = @import("std");
const flatten = @import("../flatten.zig");

pub fn compress(allocator: std.mem.Allocator, image: flatten.FlatImage) ![]u8 {
    var out = try allocator.alloc(u8, image.code_data.len + image.reloc_stream.len);
    errdefer allocator.free(out);
    @memcpy(out[0..image.code_data.len], image.code_data);
    @memcpy(out[image.code_data.len..], image.reloc_stream);
    return out;
}

test "compress concatenates code_data and reloc_stream verbatim" {
    var image = flatten.FlatImage{
        .allocator = std.testing.allocator,
        .code_data = try std.testing.allocator.dupe(u8, &.{ 1, 2, 3 }),
        .bss_size = 0,
        .reloc_stream = try std.testing.allocator.dupe(u8, &.{ 0xAA, 0xFE }),
        .mem_chip = false,
    };
    defer image.deinit();

    const out = try compress(std.testing.allocator, image);
    defer std.testing.allocator.free(out);

    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 0xAA, 0xFE }, out);
}
