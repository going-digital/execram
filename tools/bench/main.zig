//! execram-bench: predicts a packed execram executable's exact 68000
//! decompression cost, in real CPU cycles, by running its depacker stub
//! through Musashi (src/musashi_bench.zig, src/musashi_vendor/) instead
//! of booting real emulated hardware under FS-UAE (tests/uae/). See
//! README.md (this directory) for the full rationale, this tool's
//! known limitations (no DMA/bus-contention modeling), and why it
//! exists *alongside* FS-UAE rather than replacing it.
//!
//! Usage: execram-bench <packed.exe>
//!
//! `<packed.exe>` is a real `execram pack` output file - this tool
//! reads its container header exactly the way `execram info` does
//! (src/info.zig), then hands off to src/musashi_bench.zig (shared with
//! `execram bench`, src/main.zig - that command runs the same
//! measurement on a *fresh* pack of every backend at once instead of
//! reading it back out of an already-packed file like this tool does).

const std = @import("std");
const Io = std.Io;

// tools/bench/main.zig can't reach src/*.zig with a plain relative
// `@import` (Zig refuses one that resolves outside this module's own
// root directory, tools/bench/) - see src/lib.zig's own doc comment
// and build.zig's matching comment on why this indirection exists.
const lib = @import("execram_lib");
const hunk = lib.hunk;
const info = lib.info;
const container = lib.container;
const store = lib.store;
const inflate = lib.inflate;
const zx0 = lib.zx0;
const shrinkler = lib.shrinkler;
const musashi_bench = lib.musashi_bench;

// Wired in build.zig: every stub this build can produce, plus a `-L`
// listing of the same source (a "Symbols:" section with each label's
// hex offset) used below to locate `Depack:` without hardcoding it.
const stub_store = @embedFile("stub_store");
const stub_inflate = @embedFile("stub_inflate");
const stub_zx0 = @embedFile("stub_zx0");
const stub_shrinkler = @embedFile("stub_shrinkler");
const listing_store = @embedFile("stub_store_listing");
const listing_inflate = @embedFile("stub_inflate_listing");
const listing_zx0 = @embedFile("stub_zx0_listing");
const listing_shrinkler = @embedFile("stub_shrinkler_listing");

const StubEntry = struct {
    known: info.KnownStub,
    listing: []const u8,
};

const known_stubs = [_]StubEntry{
    .{ .known = .{ .stub_name = "store", .bytes = stub_store }, .listing = listing_store },
    .{ .known = .{ .stub_name = "inflate/zultra", .bytes = stub_inflate }, .listing = listing_inflate },
    .{ .known = .{ .stub_name = "zx0/salvador", .bytes = stub_zx0 }, .listing = listing_zx0 },
    .{ .known = .{ .stub_name = "shrinkler", .bytes = stub_shrinkler }, .listing = listing_shrinkler },
};

fn backendDecompress(backend_id: u8, allocator: std.mem.Allocator, payload: []const u8, expected_len: usize) ![]u8 {
    return switch (@as(container.BackendId, @enumFromInt(backend_id))) {
        .store => store.decompress(allocator, payload, expected_len),
        .inflate => inflate.decompress(allocator, payload, expected_len),
        .zx0 => zx0.decompress(allocator, payload, expected_len),
        .shrinkler => shrinkler.decompress(allocator, payload, expected_len),
        _ => error.UnknownBackendId,
    };
}

pub fn main(init: std.process.Init) !void {
    // Arena, not a general-purpose allocator: same convention as
    // src/main.zig's own cmdPack/cmdInfo - a short-lived CLI tool that
    // exits right after printing its report doesn't need per-allocation
    // frees, only a single teardown at process exit.
    const allocator = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(allocator);

    if (args.len < 2) {
        std.debug.print("usage: execram-bench <packed.exe>\n", .{});
        return error.InvalidArguments;
    }
    const path = args[1];

    const cwd: Io.Dir = .cwd();
    const exe_bytes = try cwd.readFileAlloc(io, path, allocator, .limited(256 * 1024 * 1024));

    var file = try hunk.parse(allocator, exe_bytes);
    defer file.deinit();
    // docs/memory-lifecycle.md: hunk 0 is the trampoline, hunk 1 holds
    // the actual stub+header+payload container - see src/info.zig's own
    // identical check for the full rationale.
    if (file.hunks.len != 2 or file.hunks[0].kind != .code or file.hunks[1].kind != .code) {
        return error.NotATwoHunkCodeFile;
    }
    const container_data = file.hunks[1].data;

    var known_list: [known_stubs.len]info.KnownStub = undefined;
    for (known_stubs, 0..) |entry, i| known_list[i] = entry.known;
    const header = try info.locateHeader(container_data, &known_list);

    const stub_entry = for (known_stubs) |entry| {
        if (entry.known.bytes.ptr == header.stub.bytes.ptr) break entry;
    } else unreachable; // locateHeader only ever returns a match from known_list above

    const depack_offset = try musashi_bench.parseDepackOffset(stub_entry.listing);

    const payload = container_data[header.payloadOffset()..][0..header.compressed_size];
    const uncompressed_size = header.uncompressedSize();

    const result = try musashi_bench.timeDepack(
        allocator,
        header.stub.bytes,
        depack_offset,
        payload,
        header.compressed_size,
        uncompressed_size,
    );

    const reference_output = backendDecompress(header.backend_id, allocator, payload, uncompressed_size) catch |err| {
        std.debug.print("warning: reference decompression failed ({t}) - cycle count below is still valid, output not cross-checked\n", .{err});
        return report(header, stub_entry.known.stub_name, result, null);
    };
    defer allocator.free(reference_output);
    const matches = std.mem.eql(u8, result.output, reference_output);

    try report(header, stub_entry.known.stub_name, result, matches);
}

fn report(header: info.Header, stub_name: []const u8, result: musashi_bench.Result, matches: ?bool) !void {
    const seconds = result.seconds();
    std.debug.print("stub:              {s} (backend_id {d})\n", .{ stub_name, header.backend_id });
    std.debug.print("compressed size:   {d} bytes\n", .{header.compressed_size});
    std.debug.print("decompressed size: {d} bytes\n", .{header.uncompressedSize()});
    std.debug.print("instructions:      {d}\n", .{result.instructions});
    std.debug.print("cycles:            {d}\n", .{result.cycles});
    std.debug.print("PAL 68000 time:    {d:.4} s ({d:.1} bytes/s)\n", .{
        seconds,
        @as(f64, @floatFromInt(header.uncompressedSize())) / seconds,
    });
    if (matches) |ok| {
        std.debug.print("output check:      {s} (against {s}'s own host-side decompress)\n", .{ if (ok) "MATCH" else "MISMATCH", stub_name });
        if (!ok) return error.EmulatedOutputMismatch;
    }
    std.debug.print(
        \\
        \\Note: this is CPU instruction timing only - Musashi models no
        \\chip-RAM DMA bus contention, so real hardware (especially a
        \\depacker resident in Chip RAM, competing with the copper/
        \\blitter/audio for bus cycles) will be slower than this number,
        \\not faster. Treat it as a best-case lower bound and a way to
        \\compare backends against each other, not an exact wall-clock
        \\prediction - see tools/bench/README.md.
        \\
    , .{});
}
