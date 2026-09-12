//! execram-bench: predicts a packed execram executable's exact 68000
//! decompression cost, in real CPU cycles, by running its depacker stub
//! through Musashi (src/musashi_vendor) - a standalone, C-only
//! 68000-68040 CPU-core emulator with no chip/disk/video timing of its
//! own - instead of booting real emulated hardware under FS-UAE
//! (tests/uae/). See README.md (this directory) for the full rationale,
//! this tool's known limitations (no DMA/bus-contention modeling), and
//! why it exists *alongside* FS-UAE rather than replacing it.
//!
//! Usage: execram-bench <packed.exe>
//!
//! `<packed.exe>` is a real `execram pack` output file - this tool
//! reads its container header exactly the way `execram info` does
//! (src/info.zig), jumps the emulated CPU straight into the matching
//! stub's `Depack:` entry point (stubs/common/runtime.i's calling
//! convention: A0 = compressed payload, A1 = output buffer, D0 =
//! compressed size), and measures cycles from there to `rts` - the
//! same portion of work the real stub's `Start:` routine hands off to
//! once AllocMem/relocation are done, which is the part any backend
//! choice actually varies.

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

const c = @cImport({
    @cInclude("m68k.h");
});

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

/// The PAL Amiga's 68000 runs at exactly twice the ~3.546895 MHz color
/// clock tests/uae/boot/sentinel.s already derives its serial baud rate
/// from (`SERPER_9600_PAL = (3546895/9600)-1`) - reused here rather than
/// introducing a second, independent "PAL clock" magic number for the
/// same real oscillator.
const PAL_COLOR_CLOCK_HZ: f64 = 3_546_895.0;
const PAL_CPU_HZ: f64 = PAL_COLOR_CLOCK_HZ * 2.0;

/// Flat memory the emulated CPU sees. 16MB is far more than any backend
/// in this project has ever needed (the largest real corpus item,
/// tests/corpus/hexagon.exe, resolves to a 221KB resident image) and
/// costs nothing but static .bss in this native host tool.
const MEM_SIZE: usize = 16 * 1024 * 1024;
var mem: [MEM_SIZE]u8 = undefined;

export fn m68k_read_memory_8(address: c_uint) callconv(.c) c_uint {
    return if (address < MEM_SIZE) mem[address] else 0;
}
export fn m68k_read_memory_16(address: c_uint) callconv(.c) c_uint {
    return (m68k_read_memory_8(address) << 8) | m68k_read_memory_8(address + 1);
}
export fn m68k_read_memory_32(address: c_uint) callconv(.c) c_uint {
    return (m68k_read_memory_16(address) << 16) | m68k_read_memory_16(address + 2);
}
export fn m68k_write_memory_8(address: c_uint, value: c_uint) callconv(.c) void {
    if (address < MEM_SIZE) mem[address] = @truncate(value);
}
export fn m68k_write_memory_16(address: c_uint, value: c_uint) callconv(.c) void {
    m68k_write_memory_8(address, value >> 8);
    m68k_write_memory_8(address + 1, value & 0xff);
}
export fn m68k_write_memory_32(address: c_uint, value: c_uint) callconv(.c) void {
    m68k_write_memory_16(address, value >> 16);
    m68k_write_memory_16(address + 2, value & 0xffff);
}

/// Parses a vasm `-L` listing's "Symbols:" section for the top-level
/// (not local/dot-suffixed) `Depack` label's offset - e.g. a real
/// listing's own line reads `Depack LAB (0xd6) sec=CODE`, while a
/// stub-internal local label with the same base name reads
/// ` Depack .rbloop LAB (0xec) sec=CODE` (indented, and dotted) and must
/// not match. Confirmed against a real listing before writing this,
/// not guessed from the format's documentation - see build.zig's own
/// comment on why a listing is needed at all (`-Fbin` output carries no
/// symbol metadata).
fn parseDepackOffset(listing: []const u8) !u32 {
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "Depack LAB (0x")) continue;
        const rest = line["Depack LAB (0x".len..];
        const close = std.mem.indexOfScalar(u8, rest, ')') orelse continue;
        return std.fmt.parseInt(u32, rest[0..close], 16);
    }
    return error.DepackLabelNotFound;
}

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
    if (file.hunks.len != 1 or file.hunks[0].kind != .code) {
        return error.NotASingleCodeHunkFile;
    }
    const container_data = file.hunks[0].data;

    var known_list: [known_stubs.len]info.KnownStub = undefined;
    for (known_stubs, 0..) |entry, i| known_list[i] = entry.known;
    const header = try info.locateHeader(container_data, &known_list);

    const stub_entry = for (known_stubs) |entry| {
        if (entry.known.bytes.ptr == header.stub.bytes.ptr) break entry;
    } else unreachable; // locateHeader only ever returns a match from known_list above

    const depack_offset = try parseDepackOffset(stub_entry.listing);

    const payload = container_data[header.payloadOffset()..][0..header.compressed_size];
    const uncompressed_size = header.uncompressedSize();

    // Layout in the emulated address space - the stub's code, then the
    // payload it reads from (A0), then the buffer it writes into (A1),
    // then a stack. Nothing here needs to match real Amiga addresses:
    // this harness jumps straight into `Depack:`, bypassing
    // Start:/AllocMem/relocation entirely (docs/format-spec.md's
    // container header isn't even copied into emulated memory), so the
    // only contract that matters is runtime.i's own register
    // convention.
    const stub_base: u32 = 0x1000;
    const stub_len: u32 = @intCast(header.stub.bytes.len);
    const payload_base: u32 = std.mem.alignForward(u32, stub_base + stub_len, 4);
    const output_base: u32 = std.mem.alignForward(u32, payload_base + @as(u32, @intCast(payload.len)), 4);
    const stack_size: u32 = 16384;
    const stack_top: u32 = std.mem.alignForward(u32, output_base + uncompressed_size, 4) + stack_size;
    if (stack_top >= MEM_SIZE) return error.PackedFileTooLargeForBenchMemory;

    // A sentinel return address, not a real one: chosen far past
    // anything this harness ever places in `mem`, so it can never
    // collide with a real code/data address. It's only ever compared
    // against PC (to detect the depack routine's own `rts`), never
    // fetched as an instruction - see the single-step loop below on why
    // that's true by construction, not by luck.
    const trampoline: u32 = 0xFFFF0000;

    @memset(&mem, 0);
    @memcpy(mem[stub_base..][0..stub_len], header.stub.bytes);
    @memcpy(mem[payload_base..][0..payload.len], payload);

    c.m68k_init();
    c.m68k_set_cpu_type(c.M68K_CPU_TYPE_68000);
    c.m68k_pulse_reset();

    const sp = stack_top - 4;
    m68k_write_memory_32(sp, trampoline);
    c.m68k_set_reg(c.M68K_REG_SP, sp);
    c.m68k_set_reg(c.M68K_REG_A0, payload_base);
    c.m68k_set_reg(c.M68K_REG_A1, output_base);
    c.m68k_set_reg(c.M68K_REG_D0, header.compressed_size);
    c.m68k_set_reg(c.M68K_REG_PC, stub_base + depack_offset);

    // m68k_execute() always finishes whatever instruction it started,
    // even past the requested budget - so a naive "run N cycles, then
    // check if PC reached the trampoline" loop overshoots: once the
    // real routine's last `rts` lands PC exactly on the trampoline
    // *before* that call's own budget is exhausted, Musashi just keeps
    // decoding whatever bytes happen to sit at/after it for the
    // remainder of that same call. The only overshoot-free fix is
    // single-stepping: request 1 cycle (well below any real
    // instruction's cost) so every call executes exactly one
    // instruction, and check PC *before* each next call rather than
    // trusting the return value. The very first call after reset is a
    // separate wrinkle (m68k_execute() eats a fixed ~40-cycle reset
    // exception cost before running anything real, returning early if
    // asked for fewer cycles than that) - a throwaway m68k_execute(0)
    // absorbs it outside the real measurement.
    _ = c.m68k_execute(0);
    var total_cycles: u64 = 0;
    var steps: u64 = 0;
    // Safety valve against a genuine infinite loop (inflate/zultra's
    // stub hits exactly this - see tools/bench/README.md's "Known
    // limitations"). Each single-step m68k_execute(1) call costs real
    // wall-clock time, so this bound isn't just "some big number": at
    // ~500M it took over 100s of real time to actually trip on that
    // known-hanging case, a bad failure mode for a tool meant to be
    // fast. The real hexagon.exe corpus item's largest observed step
    // count (a full 216KB shrinkler decompression) was ~35.3M, so 100M
    // keeps a healthy ~2.8x margin above any real workload seen so far
    // while cutting a genuine hang's wall-clock cost roughly 5x.
    const step_limit: u64 = 100_000_000;
    while (c.m68k_get_reg(null, c.M68K_REG_PC) != trampoline) {
        total_cycles += @intCast(c.m68k_execute(1));
        steps += 1;
        if (steps > step_limit) return error.DepackNeverReturned;
    }

    const emulated_output = mem[output_base..][0..uncompressed_size];
    const reference_output = backendDecompress(header.backend_id, allocator, payload, uncompressed_size) catch |err| {
        std.debug.print("warning: reference decompression failed ({t}) - cycle count below is still valid, output not cross-checked\n", .{err});
        return report(header, stub_entry.known.stub_name, total_cycles, steps, null);
    };
    defer allocator.free(reference_output);
    const matches = std.mem.eql(u8, emulated_output, reference_output);

    try report(header, stub_entry.known.stub_name, total_cycles, steps, matches);
}

fn report(header: info.Header, stub_name: []const u8, total_cycles: u64, steps: u64, matches: ?bool) !void {
    const seconds = @as(f64, @floatFromInt(total_cycles)) / PAL_CPU_HZ;
    std.debug.print("stub:              {s} (backend_id {d})\n", .{ stub_name, header.backend_id });
    std.debug.print("compressed size:   {d} bytes\n", .{header.compressed_size});
    std.debug.print("decompressed size: {d} bytes\n", .{header.uncompressedSize()});
    std.debug.print("instructions:      {d}\n", .{steps});
    std.debug.print("cycles:            {d}\n", .{total_cycles});
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
