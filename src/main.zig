const std = @import("std");
const Io = std.Io;

/// M0 smoke test: proves the vasm -> Zig build pipeline works end to end.
/// `stub_example` is the assembled bytes of stubs/example/hello.s, embedded
/// at build time by build.zig. Real backends replace this in later
/// milestones (see PROJECT_PLAN.md).
const stub_example = @embedFile("stub_example");

const usage =
    \\execram - Amiga executable compressor
    \\
    \\Usage:
    \\  execram pack --backend=<store|inflate|zx0|shrinkler|auto> <in> <out>
    \\  execram info <packed-exe>
    \\
    \\Not yet implemented - see PROJECT_PLAN.md for the milestone plan.
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
        std.log.info("pack: not yet implemented (M1+)", .{});
    } else if (std.mem.eql(u8, command, "info")) {
        std.log.info("info: not yet implemented (M1+)", .{});
    } else {
        try printUsage(io);
    }
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
