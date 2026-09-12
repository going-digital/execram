//! Builds the execram v0 container (docs/format-spec.md §3) - stub code
//! ++ header ++ compressed payload - and wraps it as a single-hunk
//! AmigaDOS load file (docs/format-spec.md §2).

const std = @import("std");
const flatten = @import("flatten.zig");

pub const BackendId = enum(u8) {
    store = 0,
    inflate = 1,
    zx0 = 2,
    shrinkler = 3,
    _,
};

const FLAG_MEM_CHIP: u8 = 1;
const FLAG_HAS_RELOCS: u8 = 2;
const HEADER_SIZE: u16 = 32;
const MAGIC = 0x45784372; // "ExCr"

/// Serializes docs/format-spec.md §3's header. `compressed_payload` is
/// whatever bytes the chosen backend's compressor produced (for
/// `store`, that's simply `image.code_data ++ image.reloc_stream`
/// verbatim - see src/backends/store.zig).
pub fn buildContainer(
    allocator: std.mem.Allocator,
    image: flatten.FlatImage,
    backend_id: BackendId,
    stub_bytes: []const u8,
    compressed_payload: []const u8,
) ![]u8 {
    var flags: u8 = 0;
    if (image.mem_chip) flags |= FLAG_MEM_CHIP;
    if (image.reloc_stream.len > 1) flags |= FLAG_HAS_RELOCS; // len 1 is just the 0xFE terminator: no sites

    const total = stub_bytes.len + HEADER_SIZE + compressed_payload.len;
    var out = try allocator.alloc(u8, total);
    errdefer allocator.free(out);

    @memcpy(out[0..stub_bytes.len], stub_bytes);
    const h = out[stub_bytes.len..][0..HEADER_SIZE];
    @memset(h, 0);
    std.mem.writeInt(u32, h[0..4], MAGIC, .big);
    h[4] = 0; // version_major
    h[5] = 0; // version_minor
    h[6] = @intFromEnum(backend_id);
    h[7] = flags;
    std.mem.writeInt(u16, h[8..10], HEADER_SIZE, .big);
    // h[10..12] reserved, already zeroed
    std.mem.writeInt(u32, h[12..16], @intCast(image.code_data.len), .big);
    std.mem.writeInt(u32, h[16..20], image.bss_size, .big);
    const reloc_stream_size: u32 = if (flags & FLAG_HAS_RELOCS != 0) @intCast(image.reloc_stream.len) else 0;
    std.mem.writeInt(u32, h[20..24], reloc_stream_size, .big);
    std.mem.writeInt(u32, h[24..28], @intCast(compressed_payload.len), .big);
    std.mem.writeInt(u32, h[28..32], 0, .big); // safety_margin: reserved, 0 in v0

    @memcpy(out[stub_bytes.len + HEADER_SIZE ..], compressed_payload);
    return out;
}

const HUNK_CODE: u32 = 0x3E9;
const HUNK_END: u32 = 0x3F2;
const HUNK_HEADER: u32 = 0x3F3;
const MEMF_CHIP_BIT: u32 = 1 << 30;

/// Wraps `container` (buildContainer's output) as a single-hunk AmigaDOS
/// load file (docs/format-spec.md §2): HUNK_HEADER, one HUNK_CODE hunk
/// holding `container` padded to a longword boundary, HUNK_END. No
/// HUNK_RELOC32 - the stub is position-independent (PC-relative only).
pub fn writeHunkExecutable(allocator: std.mem.Allocator, container: []const u8, mem_chip: bool) ![]u8 {
    const padded_len = std.mem.alignForward(usize, container.len, 4);
    const pad = padded_len - container.len;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var buf4: [4]u8 = undefined;
    const w32 = struct {
        fn f(list: *std.ArrayList(u8), a: std.mem.Allocator, b: *[4]u8, v: u32) !void {
            std.mem.writeInt(u32, b, v, .big);
            try list.appendSlice(a, b);
        }
    }.f;

    try w32(&out, allocator, &buf4, HUNK_HEADER);
    try w32(&out, allocator, &buf4, 0); // resident library name list: empty
    try w32(&out, allocator, &buf4, 1); // table_size: one hunk
    try w32(&out, allocator, &buf4, 0); // first_hunk
    try w32(&out, allocator, &buf4, 0); // last_hunk
    const size_longs: u32 = @intCast(padded_len / 4);
    try w32(&out, allocator, &buf4, if (mem_chip) size_longs | MEMF_CHIP_BIT else size_longs);

    try w32(&out, allocator, &buf4, HUNK_CODE);
    try w32(&out, allocator, &buf4, size_longs);
    try out.appendSlice(allocator, container);
    try out.appendNTimes(allocator, 0, pad);

    try w32(&out, allocator, &buf4, HUNK_END);

    return out.toOwnedSlice(allocator);
}

const hunk = @import("hunk.zig");

test "writeHunkExecutable round-trips through hunk.zig" {
    const container = "hello, this is a fake stub+header+payload blob";
    const exe_bytes = try writeHunkExecutable(std.testing.allocator, container, false);
    defer std.testing.allocator.free(exe_bytes);

    var file = try hunk.parse(std.testing.allocator, exe_bytes);
    defer file.deinit();

    try std.testing.expectEqual(@as(usize, 1), file.hunks.len);
    try std.testing.expectEqual(hunk.HunkKind.code, file.hunks[0].kind);
    try std.testing.expectEqual(hunk.MemAttr.any, file.hunks[0].mem_attr);
    // The hunk is padded to a longword boundary; our container's exact
    // bytes must still appear verbatim as its prefix.
    try std.testing.expectEqualSlices(u8, container, file.hunks[0].data[0..container.len]);
}

test "writeHunkExecutable sets the Chip RAM memory flag" {
    const exe_bytes = try writeHunkExecutable(std.testing.allocator, "x", true);
    defer std.testing.allocator.free(exe_bytes);

    var file = try hunk.parse(std.testing.allocator, exe_bytes);
    defer file.deinit();

    try std.testing.expectEqual(hunk.MemAttr.chip, file.hunks[0].mem_attr);
}

test "buildContainer serializes the header per docs/format-spec.md" {
    var image = flatten.FlatImage{
        .allocator = std.testing.allocator,
        .code_data = try std.testing.allocator.dupe(u8, &.{ 1, 2, 3, 4 }),
        .bss_size = 8,
        .reloc_stream = try std.testing.allocator.dupe(u8, &.{0xFE}), // no sites, just the terminator
        .mem_chip = true,
    };
    defer image.deinit();

    const stub = "STUB";
    const payload = "PAYLOAD!"; // 8 bytes, arbitrary for this test
    const out = try buildContainer(std.testing.allocator, image, .store, stub, payload);
    defer std.testing.allocator.free(out);

    try std.testing.expectEqualSlices(u8, stub, out[0..4]);
    const h = out[4..36];
    try std.testing.expectEqual(@as(u32, MAGIC), std.mem.readInt(u32, h[0..4], .big));
    try std.testing.expectEqual(@as(u8, 0), h[4]); // version_major
    try std.testing.expectEqual(@as(u8, @intFromEnum(BackendId.store)), h[6]); // backend_id
    try std.testing.expectEqual(FLAG_MEM_CHIP, h[7]); // chip set, has_relocs clear (no real sites)
    try std.testing.expectEqual(@as(u16, HEADER_SIZE), std.mem.readInt(u16, h[8..10], .big));
    try std.testing.expectEqual(@as(u32, 4), std.mem.readInt(u32, h[12..16], .big)); // code_data_size
    try std.testing.expectEqual(@as(u32, 8), std.mem.readInt(u32, h[16..20], .big)); // bss_size
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, h[20..24], .big)); // reloc_stream_size (no sites)
    try std.testing.expectEqual(@as(u32, 8), std.mem.readInt(u32, h[24..28], .big)); // compressed_size
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, h[28..32], .big)); // safety_margin
    try std.testing.expectEqualSlices(u8, payload, out[36..]);
}
