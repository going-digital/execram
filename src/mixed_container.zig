//! v1 container: one resident per memory class and one shared scratch
//! dispatcher/depacker. Descriptors retain normal header field offsets
//! for the existing flash depackers, but relocations name a target group.
const std = @import("std");
const groups = @import("memory_groups.zig");
const container = @import("container.zig");
pub const stub = @embedFile("stub_mixed");
pub const HEADER_SIZE = 44;
pub const DESC_SIZE = 52;

pub const Part = struct {
    group: groups.Group,
    payload: []const u8,
    margin: u32,
    overlap: bool,
};
fn put(bytes: []u8, offset: usize, n: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], n, .big);
}
fn append32(a: std.mem.Allocator, list: *std.ArrayList(u8), n: u32) !void {
    var buf: [4]u8 = undefined;
    put(&buf, 0, n);
    try list.appendSlice(a, &buf);
}
fn body(a: std.mem.Allocator, out: *std.ArrayList(u8), data: []const u8) !void {
    try append32(a, out, 0x3e9);
    try append32(a, out, @intCast(std.mem.alignForward(usize, data.len, 4) / 4));
    try out.appendSlice(a, data);
    try out.appendNTimes(a, 0, (4 - data.len % 4) % 4);
    try append32(a, out, 0x3f2);
}

pub fn build(a: std.mem.Allocator, parts: []const Part, trampoline: []const u8, decoder: []const u8, depack_offset: u32, backend: container.BackendId, flash: bool, killtwitch: bool) ![]u8 {
    const decoder_offset = stub.len + HEADER_SIZE + DESC_SIZE * parts.len;
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(a);
    try scratch.appendSlice(a, stub);
    try scratch.appendNTimes(a, 0, HEADER_SIZE + DESC_SIZE * parts.len);
    try scratch.appendSlice(a, decoder);
    const sizes = try a.alloc(u32, parts.len);
    defer a.free(sizes);
    const bodies = try a.alloc([]u8, parts.len);
    defer a.free(bodies);
    var initialized: usize = 0;
    defer for (bodies[0..initialized]) |b| a.free(b);
    var code_total: u32 = 0;
    var bss_total: u32 = 0;
    var reloc_total: u32 = 0;
    var packed_total: u32 = 0;
    for (parts, 0..) |p, i| {
        const prefix: []const u8 = if (i == 0) trampoline else &.{};
        const resident = @max(container.residentTailSize(p.group.image.code_data.len, p.group.image.bss_size, p.group.image.reloc_stream.len), std.mem.alignForward(usize, prefix.len, 4));
        sizes[i] = if (p.overlap) container.overlapAllocatedSize(prefix.len, @intCast(p.payload.len), p.margin, @intCast(resident)) else @intCast(resident);
        bodies[i] = if (p.overlap) try container.buildOverlapHunk0Body(a, prefix, p.payload) else try a.dupe(u8, prefix);
        initialized += 1;
        var input: u32 = @intCast(prefix.len);
        if (!p.overlap) {
            try scratch.appendNTimes(a, 0, (4 - scratch.items.len % 4) % 4);
            input = @intCast(scratch.items.len);
            try scratch.appendSlice(a, p.payload);
        }
        // append may reallocate scratch: take descriptor slice afterward.
        const d = scratch.items[stub.len + HEADER_SIZE + i * DESC_SIZE ..][0..DESC_SIZE];
        put(d, 0, 0x45784372);
        d[4] = 1;
        d[6] = @intFromEnum(backend);
        d[7] = (if (p.group.attr == .chip) @as(u8, 1) else 0) | 2 |
            (if (p.overlap) @as(u8, 8) else 0) | (if (flash) @as(u8, 4) else 0) |
            (if (flash and killtwitch) @as(u8, 16) else 0);
        std.mem.writeInt(u16, d[8..10], DESC_SIZE, .big);
        put(d, 12, @intCast(p.group.image.code_data.len));
        put(d, 16, p.group.image.bss_size);
        put(d, 20, @intCast(p.group.image.reloc_stream.len));
        put(d, 24, @intCast(p.payload.len));
        put(d, 28, p.margin);
        put(d, 32, @intCast(prefix.len));
        put(d, 40, input);
        put(d, 44, if (p.overlap) sizes[i] - @as(u32, @intCast(std.mem.alignForward(usize, p.payload.len, 4))) else 0);
        put(d, 48, sizes[i]);
        code_total += @intCast(p.group.image.code_data.len);
        bss_total += p.group.image.bss_size;
        reloc_total += @intCast(p.group.image.reloc_stream.len);
        packed_total += @intCast(p.payload.len);
    }
    const h = scratch.items[stub.len..][0..HEADER_SIZE];
    put(h, 0, 0x45784372);
    h[4] = 1;
    h[6] = @intFromEnum(backend);
    h[7] = (if (flash) @as(u8, 4) else 0) | (if (flash and killtwitch) @as(u8, 16) else 0);
    std.mem.writeInt(u16, h[8..10], HEADER_SIZE, .big);
    put(h, 12, code_total);
    put(h, 16, bss_total);
    put(h, 20, reloc_total);
    put(h, 24, packed_total);
    put(h, 36, @intCast(parts.len));
    put(h, 40, @intCast(decoder_offset + depack_offset));
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    for ([_]u32{ 0x3f3, 0, @intCast(parts.len + 1), 0, @intCast(parts.len) }) |word| try append32(a, &out, word);
    for (parts, 0..) |p, i| {
        try append32(a, &out, (sizes[i] / 4) | (@as(u32, @intFromEnum(p.group.attr)) << 30));
        if (i == 0) try append32(a, &out, @intCast(std.mem.alignForward(usize, scratch.items.len, 4) / 4));
    }
    for (bodies, 0..) |b, i| {
        try body(a, &out, b);
        if (i == 0) try body(a, &out, scratch.items);
    }
    return out.toOwnedSlice(a);
}
