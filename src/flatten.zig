//! Merges a parsed HunkFile (src/hunk.zig) into the flat image + reloc
//! stream shape docs/format-spec.md §3/§6/§7 defines: one contiguous
//! code+data region, BSS excluded and appended only as a size (never
//! compressed), and a backend-agnostic reloc stream recording exactly
//! "add the final runtime base address here" for each site - the
//! target-hunk-specific part of each relocation is folded into the
//! stored value at flatten time, since we already know every hunk's
//! offset within the merged image.
//!
//! Hunks are reordered (stable) into [non-BSS hunks][BSS hunks] so BSS
//! ends up contiguous at the tail regardless of the original hunk order
//! in the file. This is safe for the "entry point is always offset 0"
//! convention (format-spec.md §3) because hunk 0 - the program's actual
//! entry point, by AmigaDOS convention - is never itself a BSS hunk in
//! any real executable, so it stays first after reordering.

const std = @import("std");
const hunk = @import("hunk.zig");

pub const FlatImage = struct {
    allocator: std.mem.Allocator,
    /// Owned, mutable - relocation sites are patched in place at flatten
    /// time (see module doc). Length is exactly code_data_size.
    code_data: []u8,
    bss_size: u32,
    /// Owned. Encoded per docs/format-spec.md §7.
    reloc_stream: []u8,
    /// Any original hunk requested Chip RAM -> the whole merged image
    /// does too (docs/format-spec.md §5's documented all-or-nothing
    /// limitation).
    mem_chip: bool,

    pub fn deinit(self: *FlatImage) void {
        self.allocator.free(self.code_data);
        self.allocator.free(self.reloc_stream);
        self.* = undefined;
    }
};

pub const FlattenError = error{
    UnexpectedBssRelocations,
    RelocOffsetNotEven,
    RelocOffsetOutOfRange,
    RelocTargetOutOfRange,
    Overflow,
} || std.mem.Allocator.Error;

/// One patch site in the merged code_data buffer, still needing the
/// final runtime base address added at load time.
const Site = struct { offset: u32 };

pub fn flatten(allocator: std.mem.Allocator, file: hunk.HunkFile) FlattenError!FlatImage {
    // Pass 1: assign each original hunk a base offset in the merged
    // layout - all non-BSS hunks first (stable order), then all BSS
    // hunks (stable order), continuing the same running offset.
    const merge_base = try allocator.alloc(u32, file.hunks.len);
    defer allocator.free(merge_base);

    var mem_chip = false;
    var code_data_size: u64 = 0;
    var bss_size: u64 = 0;
    for (file.hunks) |h| {
        if (h.mem_attr == .chip) mem_chip = true;
        if (h.kind == .bss) bss_size += h.size_bytes else code_data_size += h.size_bytes;
    }
    if (code_data_size > std.math.maxInt(u32) or bss_size > std.math.maxInt(u32)) return error.Overflow;

    {
        var offset: u32 = 0;
        for (file.hunks, 0..) |h, i| {
            if (h.kind == .bss) continue;
            merge_base[i] = offset;
            offset += h.size_bytes;
        }
        var bss_offset: u32 = @intCast(code_data_size);
        for (file.hunks, 0..) |h, i| {
            if (h.kind != .bss) continue;
            merge_base[i] = bss_offset;
            bss_offset += h.size_bytes;
        }
    }

    // Pass 2: copy non-BSS hunk bytes into place.
    var code_data = try allocator.alloc(u8, @intCast(code_data_size));
    errdefer allocator.free(code_data);
    for (file.hunks, 0..) |h, i| {
        if (h.kind == .bss) continue;
        @memcpy(code_data[merge_base[i]..][0..h.data.len], h.data);
    }

    // Pass 3: fold each relocation's target-hunk offset into the stored
    // value, and record the site for the runtime reloc stream.
    var sites: std.ArrayList(Site) = .empty;
    defer sites.deinit(allocator);

    for (file.hunks, 0..) |h, i| {
        if (h.kind == .bss) {
            if (h.relocs.len != 0) return error.UnexpectedBssRelocations;
            continue;
        }
        for (h.relocs) |r| {
            if (r.target_hunk >= file.hunks.len) return error.RelocTargetOutOfRange;
            if (r.offset % 2 != 0) return error.RelocOffsetNotEven;
            if (@as(u64, r.offset) + 4 > h.data.len) return error.RelocOffsetOutOfRange;

            const site_offset = merge_base[i] + r.offset;
            const target_base = merge_base[r.target_hunk];

            const old_value = std.mem.readInt(u32, code_data[site_offset..][0..4], .big);
            const new_value = old_value +% target_base;
            std.mem.writeInt(u32, code_data[site_offset..][0..4], new_value, .big);

            try sites.append(allocator, .{ .offset = site_offset });
        }
    }

    std.mem.sort(Site, sites.items, {}, struct {
        fn lessThan(_: void, a: Site, b: Site) bool {
            return a.offset < b.offset;
        }
    }.lessThan);

    const reloc_stream = try encodeRelocStream(allocator, sites.items);
    errdefer allocator.free(reloc_stream);

    return .{
        .allocator = allocator,
        .code_data = code_data,
        .bss_size = @intCast(bss_size),
        .reloc_stream = reloc_stream,
        .mem_chip = mem_chip,
    };
}

/// docs/format-spec.md §7: ascending half-deltas, byte-oriented.
/// 0x00-0xFD literal, 0xFE end of stream, 0xFF + 4-byte BE escape.
fn encodeRelocStream(allocator: std.mem.Allocator, sites: []const Site) FlattenError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var prev: u32 = 0;
    for (sites) |site| {
        const half_delta = (site.offset - prev) / 2;
        if (half_delta <= 0xFD) {
            try out.append(allocator, @intCast(half_delta));
        } else {
            try out.append(allocator, 0xFF);
            var buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &buf, half_delta, .big);
            try out.appendSlice(allocator, &buf);
        }
        prev = site.offset;
    }
    try out.append(allocator, 0xFE);

    return out.toOwnedSlice(allocator);
}

test "flattens the real fixture with relocations folded in" {
    const fixture_bytes = @embedFile("fixture_basic");
    var file = try hunk.parse(std.testing.allocator, fixture_bytes);
    defer file.deinit();

    var image = try flatten(std.testing.allocator, file);
    defer image.deinit();

    // hunk0 (CODE, 28 bytes) then hunk1 (DATA, 8 bytes) -> code_data_size 36
    // hunk2 (BSS, 16 bytes) -> bss_size 16, merge_base 36
    try std.testing.expectEqual(@as(usize, 36), image.code_data.len);
    try std.testing.expectEqual(@as(u32, 16), image.bss_size);
    try std.testing.expectEqual(false, image.mem_chip);

    // move.l dataptr,a1 at code_data+8: was 0, target DATA hunk's merge
    // base (28) folded in.
    try std.testing.expectEqual(@as(u32, 28), std.mem.readInt(u32, image.code_data[8..12], .big));
    // move.l #bssvar,a2 at code_data+16: target BSS hunk's merge base (36).
    try std.testing.expectEqual(@as(u32, 36), std.mem.readInt(u32, image.code_data[16..20], .big));
    // dataptr at code_data+28 (start of the DATA hunk's region): also 36.
    try std.testing.expectEqual(@as(u32, 36), std.mem.readInt(u32, image.code_data[28..32], .big));
    // someval at code_data+32: untouched literal, not a reloc site.
    try std.testing.expectEqual(@as(u32, 0x12345678), std.mem.readInt(u32, image.code_data[32..36], .big));

    // Sites at 8, 16, 28 -> half-deltas 4, 4, 6, then the 0xFE terminator.
    try std.testing.expectEqualSlices(u8, &.{ 0x04, 0x04, 0x06, 0xFE }, image.reloc_stream);
}

test "rejects an odd reloc offset" {
    var data = [_]u8{0} ** 8;
    var relocs = [_]hunk.Reloc{.{ .target_hunk = 0, .offset = 1 }};
    var hunks = [_]hunk.Hunk{
        .{ .kind = .code, .mem_attr = .any, .data = &data, .size_bytes = 8, .relocs = &relocs },
    };
    const image = flatten(std.testing.allocator, .{ .allocator = std.testing.allocator, .hunks = &hunks });
    try std.testing.expectError(error.RelocOffsetNotEven, image);
}

test "rejects a reloc offset that doesn't fit in the hunk" {
    var data = [_]u8{0} ** 8;
    var relocs = [_]hunk.Reloc{.{ .target_hunk = 0, .offset = 6 }}; // 6+4 > 8
    var hunks = [_]hunk.Hunk{
        .{ .kind = .code, .mem_attr = .any, .data = &data, .size_bytes = 8, .relocs = &relocs },
    };
    const image = flatten(std.testing.allocator, .{ .allocator = std.testing.allocator, .hunks = &hunks });
    try std.testing.expectError(error.RelocOffsetOutOfRange, image);
}

test "rejects a reloc target hunk index out of range" {
    var data = [_]u8{0} ** 8;
    var relocs = [_]hunk.Reloc{.{ .target_hunk = 5, .offset = 0 }};
    var hunks = [_]hunk.Hunk{
        .{ .kind = .code, .mem_attr = .any, .data = &data, .size_bytes = 8, .relocs = &relocs },
    };
    const image = flatten(std.testing.allocator, .{ .allocator = std.testing.allocator, .hunks = &hunks });
    try std.testing.expectError(error.RelocTargetOutOfRange, image);
}

test "rejects relocations recorded against a BSS hunk" {
    var relocs = [_]hunk.Reloc{.{ .target_hunk = 0, .offset = 0 }};
    var hunks = [_]hunk.Hunk{
        .{ .kind = .bss, .mem_attr = .any, .data = &.{}, .size_bytes = 16, .relocs = &relocs },
    };
    const image = flatten(std.testing.allocator, .{ .allocator = std.testing.allocator, .hunks = &hunks });
    try std.testing.expectError(error.UnexpectedBssRelocations, image);
}
