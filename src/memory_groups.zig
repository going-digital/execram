//! One flat region per original memory class. Relocation records retain
//! the target region, so no Chip/Fast requirement is lost by flattening.
const std = @import("std");
const hunk = @import("hunk.zig");
const flat = @import("flatten.zig");

pub const Group = struct {
    image: flat.FlatImage,
    attr: hunk.MemAttr,
};

pub fn needed(file: hunk.HunkFile) bool {
    if (file.hunks.len == 0) return false;
    for (file.hunks) |h| {
        if (h.mem_attr != file.hunks[0].mem_attr or h.mem_attr == .fast) return true;
    }
    return false;
}

pub fn deinit(a: std.mem.Allocator, groups: []Group) void {
    for (groups) |*g| g.image.deinit();
    a.free(groups);
}

pub fn build(a: std.mem.Allocator, file: hunk.HunkFile) ![]Group {
    if (file.hunks.len == 0 or file.hunks[0].kind == .bss) return error.InvalidEntryHunk;
    var total: u64 = 0;
    for (file.hunks) |h| total += h.allocationSize();
    if (total > std.math.maxInt(u32)) return error.Overflow;
    var attrs: std.ArrayList(hunk.MemAttr) = .empty;
    defer attrs.deinit(a);
    const group_ids = try a.alloc(u8, file.hunks.len);
    defer a.free(group_ids);
    const bases = try a.alloc(u32, file.hunks.len);
    defer a.free(bases);
    for (file.hunks, 0..) |h, i| {
        const index = std.mem.indexOfScalar(hunk.MemAttr, attrs.items, h.mem_attr) orelse blk: {
            try attrs.append(a, h.mem_attr);
            break :blk attrs.items.len - 1;
        };
        group_ids[i] = @intCast(index);
    }
    const groups = try a.alloc(Group, attrs.items.len);
    var initialized: usize = 0;
    errdefer {
        for (groups[0..initialized]) |*g| g.image.deinit();
        a.free(groups);
    }
    for (attrs.items, 0..) |attr, g| {
        var subset: std.ArrayList(hunk.Hunk) = .empty;
        defer subset.deinit(a);
        for (file.hunks, 0..) |h, i| {
            if (group_ids[i] != g) continue;
            var copy = h;
            copy.relocs = &.{};
            try subset.append(a, copy);
        }
        groups[g] = .{ .attr = attr, .image = try flat.flatten(a, .{ .allocator = a, .hunks = subset.items }) };
        initialized += 1;
        var code_offset: u32 = 0;
        var bss_offset: u32 = @intCast(groups[g].image.code_data.len);
        for (file.hunks, 0..) |h, i| {
            if (group_ids[i] != g) continue;
            if (h.kind == .bss) {
                bases[i] = bss_offset;
                bss_offset += h.allocationSize();
            } else {
                bases[i] = code_offset;
                code_offset += h.allocationSize();
            }
        }
    }
    const Site = struct { offset: u32, target: u8 };
    for (groups, 0..) |*group, g| {
        var sites: std.ArrayList(Site) = .empty;
        defer sites.deinit(a);
        for (file.hunks, 0..) |h, i| {
            if (group_ids[i] != g) continue;
            if (h.kind == .bss and h.relocs.len != 0) return error.UnexpectedBssRelocations;
            for (h.relocs) |r| {
                if (r.target_hunk >= file.hunks.len) return error.RelocTargetOutOfRange;
                if (r.offset % 2 != 0) return error.RelocOffsetNotEven;
                if (@as(u64, r.offset) + 4 > h.data.len) return error.RelocOffsetOutOfRange;
                const offset = bases[i] + r.offset;
                const value = group.image.code_data[offset..][0..4];
                std.mem.writeInt(u32, value, std.mem.readInt(u32, value, .big) +% bases[r.target_hunk], .big);
                try sites.append(a, .{ .offset = offset, .target = group_ids[r.target_hunk] });
            }
        }
        std.mem.sort(Site, sites.items, {}, struct {
            fn less(_: void, x: Site, y: Site) bool {
                return x.offset < y.offset;
            }
        }.less);
        var stream: std.ArrayList(u8) = .empty;
        defer stream.deinit(a);
        var prev: u32 = 0;
        for (sites.items) |site| {
            try stream.append(a, site.target);
            const delta = (site.offset - prev) / 2;
            if (delta <= 0xFD) {
                try stream.append(a, @intCast(delta));
            } else {
                try stream.append(a, 0xFF);
                var buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &buf, delta, .big);
                try stream.appendSlice(a, &buf);
            }
            prev = site.offset;
        }
        try stream.append(a, 0xFE);
        const encoded = try stream.toOwnedSlice(a);
        a.free(group.image.reloc_stream);
        group.image.reloc_stream = encoded;
    }
    return groups;
}

test "group order keeps the Chip entry first and folds offsets after reserved tails" {
    const a = std.testing.allocator;
    var code = [_]u8{0} ** 4;
    var data = [_]u8{0} ** 4;
    var reloc = [_]hunk.Reloc{.{ .offset = 0, .target_hunk = 2 }};
    var hunks = [_]hunk.Hunk{
        .{ .kind = .code, .mem_attr = .chip, .data = &code, .size_bytes = 4, .relocs = &reloc },
        .{ .kind = .data, .mem_attr = .any, .data = &data, .size_bytes = 4, .allocated_size = 16, .relocs = &.{} },
        .{ .kind = .data, .mem_attr = .any, .data = &data, .size_bytes = 4, .relocs = &.{} },
    };
    const regions = try build(a, .{ .allocator = a, .hunks = &hunks });
    defer deinit(a, regions);
    try std.testing.expectEqual(hunk.MemAttr.chip, regions[0].attr);
    try std.testing.expectEqual(hunk.MemAttr.any, regions[1].attr);
    try std.testing.expectEqual(@as(u32, 16), std.mem.readInt(u32, regions[0].image.code_data[0..4], .big));
    try std.testing.expectEqualSlices(u8, &.{ 1, 0, 0xfe }, regions[0].image.reloc_stream);
    try std.testing.expectEqual(@as(usize, 20), regions[1].image.code_data.len);
}
