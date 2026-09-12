//! The "zx0" backend: real ZX0 compression via a vendored/adapted
//! optimal-parse compressor (einar-saukas/ZX0, BSD-3-Clause - see
//! src/backends/zx0_vendor/README.md and docs/LICENSES.md §2), matching
//! the depacker in stubs/zx0/ (Emmanuel Marty's `unzx0_68000.s`, zlib
//! license - docs/LICENSES.md §3).

const std = @import("std");
const flatten = @import("../flatten.zig");
const salvador = @import("salvador.zig");

const c = @cImport({
    @cInclude("shim.h");
});

/// zx0_vendor has no decompressor of its own (it didn't exist yet when
/// this backend was written) - salvador is a byte-compatible ZX0
/// compressor for the exact same depacker (see
/// src/backends/salvador_vendor/README.md), and its own vendored
/// decoder happens to cover this backend's needs too. Used by
/// main.zig's pack-time self-check (M5).
pub const decompress = salvador.decompress;

pub fn compress(allocator: std.mem.Allocator, image: flatten.FlatImage) ![]u8 {
    const input = try std.mem.concat(allocator, u8, &.{ image.code_data, image.reloc_stream });
    defer allocator.free(input);

    var output_size: c_int = 0;
    const c_output = c.zx0_compress_buffer(input.ptr, @intCast(input.len), &output_size);
    if (c_output == null) return error.Zx0CompressionFailed;
    defer std.c.free(c_output);

    return allocator.dupe(u8, c_output[0..@intCast(output_size)]);
}

test "compress produces a smaller, non-empty result for compressible input" {
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

    try std.testing.expect(compressed.len > 0);
    try std.testing.expect(compressed.len < image.code_data.len + image.reloc_stream.len);
}
