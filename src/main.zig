const std = @import("std");
const Io = std.Io;

const hunk = @import("hunk.zig");
const flatten = @import("flatten.zig");
const container = @import("container.zig");
const store = @import("backends/store.zig");
const inflate = @import("backends/inflate.zig");

/// M0 smoke test: proves the vasm -> Zig build pipeline works end to end.
/// Real backends replace this in later milestones (see PROJECT_PLAN.md).
const stub_example = @embedFile("stub_example");

/// Depacker stubs (stubs/<name>/stub.s), assembled and embedded at
/// build time (build.zig).
const stub_store = @embedFile("stub_store");
const stub_inflate = @embedFile("stub_inflate");

const usage =
    \\execram - Amiga executable compressor
    \\
    \\Usage:
    \\  execram pack [--backend=store|inflate] <in> <out>
    \\  execram info <packed-exe>
    \\
    \\zx0/shrinkler land in later milestones - see PROJECT_PLAN.md.
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const io = init.io;

    if (args.len < 2) {
        try printUsage(io);
        return;
    }

    const command = args[1];
    if (std.mem.eql(u8, command, "pack")) {
        cmdPack(io, arena, args[2..]) catch |err| {
            std.log.err("pack failed: {s}", .{@errorName(err)});
            return err;
        };
    } else if (std.mem.eql(u8, command, "info")) {
        std.log.info("info: not yet implemented (M5)", .{});
    } else {
        try printUsage(io);
    }
}

fn cmdPack(io: Io, arena: std.mem.Allocator, args: []const []const u8) !void {
    var backend_name: []const u8 = "store";
    var positional: std.ArrayList([]const u8) = .empty;
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--backend=")) {
            backend_name = arg["--backend=".len..];
        } else {
            try positional.append(arena, arg);
        }
    }
    if (positional.items.len != 2) {
        std.log.err("usage: execram pack [--backend=store|inflate] <in> <out>", .{});
        return error.InvalidArguments;
    }

    const in_path = positional.items[0];
    const out_path = positional.items[1];

    const cwd: Io.Dir = .cwd();
    const input_bytes = try cwd.readFileAlloc(io, in_path, arena, .limited(256 * 1024 * 1024));

    var file = try hunk.parse(arena, input_bytes);
    defer file.deinit();

    var image = try flatten.flatten(arena, file);
    defer image.deinit();

    const payload, const backend_id, const stub_bytes = if (std.mem.eql(u8, backend_name, "store"))
        .{ try store.compress(arena, image), container.BackendId.store, stub_store }
    else if (std.mem.eql(u8, backend_name, "inflate"))
        .{ try inflate.compress(arena, image), container.BackendId.inflate, stub_inflate }
    else {
        std.log.err("backend '{s}' isn't implemented yet - only 'store'/'inflate' exist so far", .{backend_name});
        return error.UnsupportedBackend;
    };

    const container_bytes = try container.buildContainer(arena, image, backend_id, stub_bytes, payload);
    const exe_bytes = try container.writeHunkExecutable(arena, container_bytes, image.mem_chip);

    try cwd.writeFile(io, .{ .sub_path = out_path, .data = exe_bytes });

    std.log.info("packed {s} -> {s} ({d} -> {d} bytes)", .{ in_path, out_path, input_bytes.len, exe_bytes.len });
}

fn printUsage(io: Io) !void {
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const w = &stderr_writer.interface;
    try w.writeAll(usage);
    try w.flush();
}

test "example stub assembled correctly" {
    // stubs/example/hello.s is: moveq #42,d0 ; rts -> 70 2a 4e 75
    try std.testing.expectEqualSlices(u8, &.{ 0x70, 0x2a, 0x4e, 0x75 }, stub_example);
}

test {
    _ = hunk;
    _ = flatten;
    _ = container;
    _ = store;
    _ = inflate;
}
