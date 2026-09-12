const std = @import("std");
const Io = std.Io;

const hunk = @import("hunk.zig");
const flatten = @import("flatten.zig");
const container = @import("container.zig");
const info = @import("info.zig");
const store = @import("backends/store.zig");
const inflate = @import("backends/inflate.zig");
const zx0 = @import("backends/zx0.zig");
const zultra = @import("backends/zultra.zig");
const salvador = @import("backends/salvador.zig");
const shrinkler = @import("backends/shrinkler.zig");

/// M0 smoke test: proves the vasm -> Zig build pipeline works end to end.
/// Real backends replace this in later milestones (see PROJECT_PLAN.md).
const stub_example = @embedFile("stub_example");

/// Depacker stubs (stubs/<name>/stub.s), assembled and embedded at
/// build time (build.zig).
const stub_store = @embedFile("stub_store");
const stub_inflate = @embedFile("stub_inflate");
const stub_zx0 = @embedFile("stub_zx0");
const stub_shrinkler = @embedFile("stub_shrinkler");

const backend_names = [_][]const u8{ "store", "inflate", "zultra", "zx0", "salvador", "shrinkler" };

const usage =
    \\execram - Amiga executable compressor
    \\
    \\Usage:
    \\  execram pack [--backend=store|inflate|zultra|zx0|salvador|shrinkler|auto]
    \\               [--mem=chip|fast] [-v] <in> <out>
    \\  execram info <packed-exe>
    \\
    \\--backend=auto (the default) tries every backend and keeps
    \\whichever produces the smallest output. zultra and salvador are
    \\alternative compressors for the same container/depacker "inflate"
    \\and "zx0" use respectively - both aim for better ratios at the
    \\cost of host-side compression time. shrinkler is a from-Shrinkler
    \\LZ + adaptive range coder backend with its own container/depacker -
    \\usually the smallest output of all, also the slowest to compress.
    \\
    \\--mem overrides the Chip/Fast RAM choice that's otherwise
    \\auto-detected from the input's own hunk memory attributes (any
    \\hunk requesting Chip RAM makes the whole packed program resident
    \\in Chip RAM at runtime). --mem=fast on a program that actually
    \\needs Chip RAM (custom chip DMA, audio/blitter buffers, ...) will
    \\build successfully but can fail or misbehave when run - only
    \\override this if you're sure.
    \\
    \\-v prints per-backend sizes (in --backend=auto mode) and image
    \\statistics as packing proceeds, not just the final result.
    \\
    \\Every pack self-checks before writing anything: the chosen
    \\backend's compressed output is decompressed host-side and compared
    \\byte-for-byte against the original - packing fails loudly rather
    \\than ever writing an executable that wouldn't decompress correctly
    \\on real hardware.
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
        cmdInfo(io, arena, args[2..]) catch |err| {
            std.log.err("info failed: {s}", .{@errorName(err)});
            return err;
        };
    } else {
        try printUsage(io);
    }
}

fn cmdPack(io: Io, arena: std.mem.Allocator, args: []const []const u8) !void {
    var backend_name: []const u8 = "auto";
    var mem_override: ?bool = null; // true = force chip, false = force fast/any
    var verbose = false;
    var positional: std.ArrayList([]const u8) = .empty;
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--backend=")) {
            backend_name = arg["--backend=".len..];
        } else if (std.mem.startsWith(u8, arg, "--mem=")) {
            const v = arg["--mem=".len..];
            if (std.mem.eql(u8, v, "chip")) {
                mem_override = true;
            } else if (std.mem.eql(u8, v, "fast")) {
                mem_override = false;
            } else {
                std.log.err("--mem must be 'chip' or 'fast', got '{s}'", .{v});
                return error.InvalidArguments;
            }
        } else if (std.mem.eql(u8, arg, "-v")) {
            verbose = true;
        } else {
            try positional.append(arena, arg);
        }
    }
    if (positional.items.len != 2) {
        std.log.err("usage: execram pack [--backend=store|inflate|zultra|zx0|salvador|shrinkler|auto] [--mem=chip|fast] [-v] <in> <out>", .{});
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

    if (mem_override) |forced| {
        if (!forced and image.mem_chip) {
            std.log.warn("--mem=fast overrides an auto-detected Chip RAM requirement - only do this if you're certain nothing in this program depends on Chip RAM addressability (custom chip DMA, audio/blitter buffers, ...)", .{});
        }
        image.mem_chip = forced;
    }

    if (verbose) {
        std.log.info("image: {d} bytes code+data, {d} bytes bss, {d} bytes reloc stream, mem={s}", .{
            image.code_data.len, image.bss_size, image.reloc_stream.len, if (image.mem_chip) "chip" else "any/fast",
        });
    }

    const exe_bytes, const used_backend = if (std.mem.eql(u8, backend_name, "auto"))
        try packAuto(arena, image, verbose)
    else
        .{ try packWithBackend(arena, image, backend_name, verbose), backend_name };

    try cwd.writeFile(io, .{ .sub_path = out_path, .data = exe_bytes });

    std.log.info("packed {s} -> {s} (--backend={s}, {d} -> {d} bytes)", .{
        in_path, out_path, used_backend, input_bytes.len, exe_bytes.len,
    });
}

/// Tries every backend in `backend_names` and returns the smallest
/// resulting output, along with which backend produced it - Shrinkler's
/// own "just try it" approach to backend selection (PROJECT_PLAN.md M3).
fn packAuto(arena: std.mem.Allocator, image: flatten.FlatImage, verbose: bool) !struct { []u8, []const u8 } {
    var best: ?[]u8 = null;
    var best_name: []const u8 = "";
    for (backend_names) |name| {
        const candidate = try packWithBackend(arena, image, name, verbose);
        if (best == null or candidate.len < best.?.len) {
            best = candidate;
            best_name = name;
        }
    }
    return .{ best.?, best_name };
}

fn packWithBackend(arena: std.mem.Allocator, image: flatten.FlatImage, backend_name: []const u8, verbose: bool) ![]u8 {
    const payload, const backend_id, const stub_bytes = if (std.mem.eql(u8, backend_name, "store"))
        .{ try store.compress(arena, image), container.BackendId.store, stub_store }
    else if (std.mem.eql(u8, backend_name, "inflate"))
        .{ try inflate.compress(arena, image), container.BackendId.inflate, stub_inflate }
    else if (std.mem.eql(u8, backend_name, "zultra"))
        // zultra is a different host-side compressor producing the same
        // raw-DEFLATE format as "inflate" - same backend_id, same stub,
        // see src/backends/zultra_vendor/README.md.
        .{ try zultra.compress(arena, image), container.BackendId.inflate, stub_inflate }
    else if (std.mem.eql(u8, backend_name, "zx0"))
        .{ try zx0.compress(arena, image), container.BackendId.zx0, stub_zx0 }
    else if (std.mem.eql(u8, backend_name, "salvador"))
        // salvador is a different host-side ZX0 compressor producing the
        // same format as "zx0" - same backend_id, same stub, see
        // src/backends/salvador_vendor/README.md.
        .{ try salvador.compress(arena, image), container.BackendId.zx0, stub_zx0 }
    else if (std.mem.eql(u8, backend_name, "shrinkler"))
        .{ try shrinkler.compress(arena, image), container.BackendId.shrinkler, stub_shrinkler }
    else {
        std.log.err("backend '{s}' isn't implemented yet - only 'store'/'inflate'/'zultra'/'zx0'/'salvador'/'shrinkler'/'auto' exist so far", .{backend_name});
        return error.UnsupportedBackend;
    };

    // M5 pre-flight self-check: decompress what was just produced,
    // host-side, and confirm it reconstructs the original bytes exactly
    // before ever writing a container to disk. Every backend here is
    // vendored/adapted third-party code, not something formally proven
    // correct, so this is cheap, meaningful insurance - the same
    // "always verify before saving" discipline Shrinkler's own CLI
    // follows (DataFile.h's own verify() step).
    const expected = try std.mem.concat(arena, u8, &.{ image.code_data, image.reloc_stream });
    const decoded = decompressWithBackend(arena, backend_name, payload, expected.len) catch |err| {
        std.log.err("self-check failed for backend '{s}': decompression errored ({s}) - refusing to write a broken executable", .{ backend_name, @errorName(err) });
        return error.SelfCheckFailed;
    };
    if (!std.mem.eql(u8, decoded, expected)) {
        std.log.err("self-check failed for backend '{s}': decompressed output does not match the original bytes - refusing to write a broken executable", .{backend_name});
        return error.SelfCheckFailed;
    }
    if (verbose) {
        std.log.info("  {s}: {d} -> {d} bytes (self-check OK)", .{ backend_name, expected.len, payload.len });
    }

    const container_bytes = try container.buildContainer(arena, image, backend_id, stub_bytes, payload);
    return container.writeHunkExecutable(arena, container_bytes, image.mem_chip);
}

/// Mirrors packWithBackend's own dispatch, one function per backend
/// name rather than a function-pointer table: keeps each backend's
/// concrete error set intact (no anyerror-coercion needed) and matches
/// this file's existing plain-if-chain style.
fn decompressWithBackend(allocator: std.mem.Allocator, backend_name: []const u8, payload: []const u8, expected_len: usize) ![]u8 {
    if (std.mem.eql(u8, backend_name, "store"))
        return store.decompress(allocator, payload, expected_len)
    else if (std.mem.eql(u8, backend_name, "inflate"))
        return inflate.decompress(allocator, payload, expected_len)
    else if (std.mem.eql(u8, backend_name, "zultra"))
        return zultra.decompress(allocator, payload, expected_len)
    else if (std.mem.eql(u8, backend_name, "zx0"))
        return zx0.decompress(allocator, payload, expected_len)
    else if (std.mem.eql(u8, backend_name, "salvador"))
        return salvador.decompress(allocator, payload, expected_len)
    else if (std.mem.eql(u8, backend_name, "shrinkler"))
        return shrinkler.decompress(allocator, payload, expected_len)
    else
        unreachable; // packWithBackend already validated backend_name above
}

fn cmdInfo(io: Io, arena: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len != 1) {
        std.log.err("usage: execram info <packed-exe>", .{});
        return error.InvalidArguments;
    }

    const cwd: Io.Dir = .cwd();
    const exe_bytes = try cwd.readFileAlloc(io, args[0], arena, .limited(256 * 1024 * 1024));

    // Every stub this build can produce - info.zig matches one of these
    // as a literal prefix to reliably locate the header (see that
    // file's own module doc for why not to scan for the magic bytes
    // directly). stub_example is never produced by `pack`, so it's not
    // listed here.
    const known_stubs = [_]info.KnownStub{
        .{ .stub_name = "store", .bytes = stub_store },
        .{ .stub_name = "inflate/zultra", .bytes = stub_inflate },
        .{ .stub_name = "zx0/salvador", .bytes = stub_zx0 },
        .{ .stub_name = "shrinkler", .bytes = stub_shrinkler },
    };

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const w = &stdout_writer.interface;
    try info.printInfo(arena, w, exe_bytes, &known_stubs);
    try w.flush();
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
    _ = info;
    _ = store;
    _ = inflate;
    _ = zx0;
    _ = zultra;
    _ = salvador;
    _ = shrinkler;
}
