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
    /// One ID per distinct depacker stub (matching every other value
    /// here), not per host encoder - the three lz4* CLI backends share
    /// one host-side compressor (src/backends/lz4.zig) but each embeds
    /// a genuinely different stub (stubs/lz4/README.md), unlike
    /// zultra/libdeflate/zopfli, which share both stub *and* backend_id
    /// with "inflate" because they share the exact same stub too.
    lz4_small = 4,
    lz4_normal = 5,
    lz4_fast = 6,
    _,
};

const FLAG_MEM_CHIP: u8 = 1;
const FLAG_HAS_RELOCS: u8 = 2;
/// docs/format-spec.md §5: a purely cosmetic border-colour flash while
/// `Depack:` runs (stubs/common/runtime.i's own comment has the full
/// rationale) - additive and backward-compatible (an old stub built
/// before this existed would just ignore the bit, same as any other
/// reserved one), hence the version_minor bump below rather than a
/// version_major one.
const FLAG_FLASH: u8 = 4;
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
    flash: bool,
) ![]u8 {
    var flags: u8 = 0;
    if (image.mem_chip) flags |= FLAG_MEM_CHIP;
    if (image.reloc_stream.len > 1) flags |= FLAG_HAS_RELOCS; // len 1 is just the 0xFE terminator: no sites
    if (flash) flags |= FLAG_FLASH;

    const total = stub_bytes.len + HEADER_SIZE + compressed_payload.len;
    var out = try allocator.alloc(u8, total);
    errdefer allocator.free(out);

    @memcpy(out[0..stub_bytes.len], stub_bytes);
    const h = out[stub_bytes.len..][0..HEADER_SIZE];
    @memset(h, 0);
    std.mem.writeInt(u32, h[0..4], MAGIC, .big);
    h[4] = 0; // version_major
    h[5] = 1; // version_minor: bumped for FLAG_FLASH (docs/format-spec.md §9)
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

/// Wraps `container` (buildContainer's output) and `trampoline_bytes`
/// (stubs/common/trampoline.s, assembled) as a *two*-hunk AmigaDOS load
/// file (docs/format-spec.md §2, docs/memory-lifecycle.md): hunk 0 is
/// declared at `resident_size` (the full decompressed image AmigaDOS's
/// LoadSeg allocates up front - `code_data_size + bss_size`, already a
/// multiple of 4) but its only real on-disk content is the tiny
/// trampoline; hunk 1 holds `container` (stub-minus-trampoline ++
/// header ++ compressed payload) as before, and is freed by the stub
/// itself once decompression finishes (see stubs/common/runtime.i's own
/// comment on the ABI this depends on). `mem_chip` applies only to hunk
/// 0 - hunk 1 is always plain `MEMF_ANY`, since it's scratch space for
/// the duration of decompression, not something worth taking out of the
/// scarcer Chip RAM pool even when the final resident image needs to be
/// there. No HUNK_RELOC32 anywhere - both hunks are position-independent
/// (PC-relative only).
pub fn writeHunkExecutable(
    allocator: std.mem.Allocator,
    trampoline_bytes: []const u8,
    container: []const u8,
    resident_size: u32,
    mem_chip: bool,
) ![]u8 {
    std.debug.assert(resident_size % 4 == 0);
    std.debug.assert(resident_size >= trampoline_bytes.len);

    const hunk1_padded_len = std.mem.alignForward(usize, container.len, 4);
    const hunk1_pad = hunk1_padded_len - container.len;
    const trampoline_padded_len = std.mem.alignForward(usize, trampoline_bytes.len, 4);
    const trampoline_pad = trampoline_padded_len - trampoline_bytes.len;

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
    try w32(&out, allocator, &buf4, 2); // table_size: two hunks
    try w32(&out, allocator, &buf4, 0); // first_hunk
    try w32(&out, allocator, &buf4, 1); // last_hunk
    const hunk0_size_longs: u32 = resident_size / 4;
    try w32(&out, allocator, &buf4, if (mem_chip) hunk0_size_longs | MEMF_CHIP_BIT else hunk0_size_longs);
    const hunk1_size_longs: u32 = @intCast(hunk1_padded_len / 4);
    try w32(&out, allocator, &buf4, hunk1_size_longs);

    // Hunk 0: declared at the full resident size, real body = just the
    // trampoline (deliberately smaller - confirmed safe under real
    // FS-UAE across Kickstart v1.3/v2.05/v3.1, see the commit that
    // introduced this design). AmigaDOS zero-fills nothing beyond the
    // real body for a CODE hunk, but nothing here depends on that -
    // stubs/common/runtime.i's own BSS-reclear step makes no assumption
    // about prior memory state.
    try w32(&out, allocator, &buf4, HUNK_CODE);
    try w32(&out, allocator, &buf4, @intCast(trampoline_padded_len / 4));
    try out.appendSlice(allocator, trampoline_bytes);
    try out.appendNTimes(allocator, 0, trampoline_pad);
    // Each hunk in a multi-hunk file is terminated by its own HUNK_END
    // (no relocs/symbols/debug follow either body here) - the original
    // single-hunk format only ever needed one, serving double duty as
    // both "end of that hunk's trailer" and "end of file"; two hunks
    // need one each.
    try w32(&out, allocator, &buf4, HUNK_END);

    // Hunk 1: today's existing container content, unchanged - just the
    // second hunk now instead of the first, and freed by its own code
    // once decompression finishes rather than kept resident forever.
    try w32(&out, allocator, &buf4, HUNK_CODE);
    try w32(&out, allocator, &buf4, hunk1_size_longs);
    try out.appendSlice(allocator, container);
    try out.appendNTimes(allocator, 0, hunk1_pad);

    try w32(&out, allocator, &buf4, HUNK_END);

    return out.toOwnedSlice(allocator);
}

const hunk = @import("hunk.zig");

test "writeHunkExecutable round-trips through hunk.zig" {
    const trampoline = "tramp!!"; // 7 bytes, arbitrary - real content is stubs/common/trampoline.s
    const container = "hello, this is a fake stub+header+payload blob";
    const exe_bytes = try writeHunkExecutable(std.testing.allocator, trampoline, container, 64, false);
    defer std.testing.allocator.free(exe_bytes);

    var file = try hunk.parse(std.testing.allocator, exe_bytes);
    defer file.deinit();

    try std.testing.expectEqual(@as(usize, 2), file.hunks.len);
    try std.testing.expectEqual(hunk.HunkKind.code, file.hunks[0].kind);
    try std.testing.expectEqual(hunk.MemAttr.any, file.hunks[0].mem_attr);
    // Hunk 0's real on-disk body is just the trampoline, padded to a
    // longword - not the full declared (resident, 64-byte) table size;
    // the rest is uninitialized until the stub's own Depack call fills
    // it at runtime (hunk.zig's `size_bytes` reports this hunk's own
    // restated body size, not the table's - see that field's own doc).
    try std.testing.expectEqual(@as(u32, 8), file.hunks[0].size_bytes);
    try std.testing.expectEqualSlices(u8, trampoline, file.hunks[0].data[0..trampoline.len]);

    try std.testing.expectEqual(hunk.HunkKind.code, file.hunks[1].kind);
    try std.testing.expectEqual(hunk.MemAttr.any, file.hunks[1].mem_attr);
    // The hunk is padded to a longword boundary; our container's exact
    // bytes must still appear verbatim as its prefix.
    try std.testing.expectEqualSlices(u8, container, file.hunks[1].data[0..container.len]);
}

test "writeHunkExecutable sets the Chip RAM memory flag on hunk 0 only" {
    const exe_bytes = try writeHunkExecutable(std.testing.allocator, "t", "x", 4, true);
    defer std.testing.allocator.free(exe_bytes);

    var file = try hunk.parse(std.testing.allocator, exe_bytes);
    defer file.deinit();

    try std.testing.expectEqual(hunk.MemAttr.chip, file.hunks[0].mem_attr);
    // Hunk 1 is scratch space for the duration of decompression only -
    // always plain MEMF_ANY, even when the resident image needs Chip RAM
    // (docs/memory-lifecycle.md's "Chip RAM: both buffers share one
    // decision" - this redesign is what actually fixes that, for the
    // scratch hunk's own share of it).
    try std.testing.expectEqual(hunk.MemAttr.any, file.hunks[1].mem_attr);
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
    const out = try buildContainer(std.testing.allocator, image, .store, stub, payload, false);
    defer std.testing.allocator.free(out);

    try std.testing.expectEqualSlices(u8, stub, out[0..4]);
    const h = out[4..36];
    try std.testing.expectEqual(@as(u32, MAGIC), std.mem.readInt(u32, h[0..4], .big));
    try std.testing.expectEqual(@as(u8, 0), h[4]); // version_major
    try std.testing.expectEqual(@as(u8, 1), h[5]); // version_minor (bumped for FLAG_FLASH)
    try std.testing.expectEqual(@as(u8, @intFromEnum(BackendId.store)), h[6]); // backend_id
    try std.testing.expectEqual(FLAG_MEM_CHIP, h[7]); // chip set, has_relocs/flash clear
    try std.testing.expectEqual(@as(u16, HEADER_SIZE), std.mem.readInt(u16, h[8..10], .big));
    try std.testing.expectEqual(@as(u32, 4), std.mem.readInt(u32, h[12..16], .big)); // code_data_size
    try std.testing.expectEqual(@as(u32, 8), std.mem.readInt(u32, h[16..20], .big)); // bss_size
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, h[20..24], .big)); // reloc_stream_size (no sites)
    try std.testing.expectEqual(@as(u32, 8), std.mem.readInt(u32, h[24..28], .big)); // compressed_size
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, h[28..32], .big)); // safety_margin
    try std.testing.expectEqualSlices(u8, payload, out[36..]);
}

test "buildContainer sets FLAG_FLASH when asked" {
    var image = flatten.FlatImage{
        .allocator = std.testing.allocator,
        .code_data = try std.testing.allocator.dupe(u8, &.{ 1, 2, 3, 4 }),
        .bss_size = 0,
        .reloc_stream = try std.testing.allocator.dupe(u8, &.{0xFE}),
        .mem_chip = false,
    };
    defer image.deinit();

    const out = try buildContainer(std.testing.allocator, image, .store, "STUB", "PAYLOAD!", true);
    defer std.testing.allocator.free(out);

    try std.testing.expectEqual(FLAG_FLASH, out[4..36][7]);
}
