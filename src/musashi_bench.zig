//! Drives Musashi (src/musashi_vendor/) - a standalone, C-only
//! 68000-68040 CPU-core emulator with no chip/disk/video timing of its
//! own - to run one depacker stub's `Depack:` routine in isolation and
//! measure its exact 68000 cycle cost. Shared by two callers:
//! `execram bench` (src/main.zig - packs a real input with every
//! backend and times each) and `tools/bench` (a standalone dev tool
//! that times an already-packed file instead - see that directory's
//! own README for the full story of *why* this exists, and for the
//! genuinely subtle part: detecting "the depack routine returned"
//! without overshooting past it).
//!
//! Vendoring note: unlike every other file `src/lib.zig` re-exports
//! for `tools/bench`'s benefit, this one is *also* compiled directly
//! into the shipped `execram` binary now that `execram bench` exists -
//! see docs/LICENSES.md §11 and THIRD_PARTY_LICENSES.md, both updated
//! accordingly when that command was added.

const std = @import("std");

const c = @cImport({
    @cInclude("m68k.h");
});

/// The PAL Amiga's 68000 runs at exactly twice the ~3.546895 MHz color
/// clock tests/uae/boot/sentinel.s already derives its serial baud rate
/// from (`SERPER_9600_PAL = (3546895/9600)-1`) - reused here rather than
/// introducing a second, independent "PAL clock" magic number for the
/// same real oscillator.
pub const PAL_COLOR_CLOCK_HZ: f64 = 3_546_895.0;
pub const PAL_CPU_HZ: f64 = PAL_COLOR_CLOCK_HZ * 2.0;

/// Flat memory the emulated CPU sees. 16MB is far more than any backend
/// in this project has ever needed (the largest real corpus item,
/// tests/corpus/hexagon.exe, resolves to a 221KB resident image) and
/// costs nothing but static .bss.
const MEM_SIZE: usize = 16 * 1024 * 1024;
var mem: [MEM_SIZE]u8 = undefined;

// A minimal fake Exec (AllocMem/FreeMem only, see fake_exec.s's own
// module doc for the full design) - only the inflate/zultra stub
// actually calls into it; every other stub's Depack: is fully
// self-contained and never touches address 4 (ExecBase) at all, so
// writing this in unconditionally for every run is harmless.
const fake_exec = @embedFile("fake_exec");

// Where fake_exec.s's tiny AllocMem/FreeMem routines live, and the
// fixed scratch address AllocMem always hands back (must match
// tools/bench/scratch_addr.i's own copy of FAKE_EXEC_SCRATCH_BASE -
// see that file's header comment). Everything from FAKE_EXEC_CODE_BASE
// upward is reserved exclusively for this - the dynamic stub/payload/
// output/stack layout below is never allowed to reach it (checked at
// runtime, not just by convention), and 7MB is enormously more
// headroom than any packed executable this project has ever produced
// (the largest, tests/corpus/hexagon.exe, resolves to 221KB) needs.
const FAKE_EXEC_CODE_BASE: u32 = 0x00700000;
const FAKE_EXEC_SCRATCH_BASE: u32 = 0x00710000;
// stubs/common/header.i's real Exec LVO constants - ExecBase-210 is
// FreeMem's entry, ExecBase-198 is AllocMem's (see fake_exec.s).
const EXEC_FREEMEM_LVO: u32 = 210;

// Overlap-margin tracking (measureOverlapMargin, below): when active,
// every byte read within [overlap_payload_base, +overlap_payload_len)
// and every byte written within [overlap_output_base,
// +overlap_output_len) updates these - see that function's own comment
// for the derivation. Module-scope, not passed through the call chain,
// because m68k_read/write_memory_* are fixed-signature C callbacks
// Musashi calls directly - same constraint `mem` itself already lives
// under.
var overlap_tracking = false;
var overlap_payload_base: u32 = 0;
var overlap_payload_len: u32 = 0;
var overlap_output_base: u32 = 0;
var overlap_output_len: u32 = 0;
// -1 = no payload byte consumed yet.
var overlap_max_consumed: i64 = -1;
var overlap_required_margin: i64 = 0;

fn overlapTrackRead(address: c_uint) void {
    if (!overlap_tracking) return;
    if (address < overlap_payload_base or address >= overlap_payload_base + overlap_payload_len) return;
    const offset: i64 = @intCast(address - overlap_payload_base);
    if (offset > overlap_max_consumed) overlap_max_consumed = offset;
}

fn overlapTrackWrite(address: c_uint) void {
    if (!overlap_tracking) return;
    if (address < overlap_output_base or address >= overlap_output_base + overlap_output_len) return;
    const write_offset: i64 = @intCast(address - overlap_output_base);
    const bytes_written_so_far = write_offset + 1;
    const bytes_consumed_so_far = overlap_max_consumed + 1;
    const margin_needed_now = bytes_written_so_far - bytes_consumed_so_far;
    if (margin_needed_now > overlap_required_margin) overlap_required_margin = margin_needed_now;
}

export fn m68k_read_memory_8(address: c_uint) callconv(.c) c_uint {
    overlapTrackRead(address);
    return if (address < MEM_SIZE) mem[address] else 0;
}
export fn m68k_read_memory_16(address: c_uint) callconv(.c) c_uint {
    return (m68k_read_memory_8(address) << 8) | m68k_read_memory_8(address + 1);
}
export fn m68k_read_memory_32(address: c_uint) callconv(.c) c_uint {
    return (m68k_read_memory_16(address) << 16) | m68k_read_memory_16(address + 2);
}
export fn m68k_write_memory_8(address: c_uint, value: c_uint) callconv(.c) void {
    overlapTrackWrite(address);
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

/// Parses a vasm `-L` listing's own symbol table for the top-level (not
/// local/dot-suffixed) `Depack` label's offset. Handles two real,
/// confirmed-different formats seen across vasm's own history - not
/// guessed from documentation, both captured directly from real
/// listings before writing this:
///
///   - vasm 1.8e and earlier: `Depack LAB (0xd6) sec=CODE`, while a
///     stub-internal local label with the same base name reads
///     ` Depack .rbloop LAB (0xec) sec=CODE` (indented, and dotted) and
///     must not match.
///   - vasm 2.0f and later (confirmed against a freshly-built vasm from
///     the exact same URL `.github/workflows/*.yml` fetches - CI builds
///     vasm from scratch on every run, so its version silently drifts
///     out from under this project over time, unlike everything else
///     here, which is either vendored or pinned): a "Symbols by name:"
///     section, one line per *global* symbol only (local/dotted labels
///     don't appear in it at all, so no separate exclusion is needed
///     the way the older format needs one) - `Depack` followed by
///     padding whitespace, then `A:` (address-type symbol, vs. `E:` for
///     an equate/constant like the HDR_* fields), then 8 hex digits.
///
/// A real, reproduced-on-a-genuinely-clean-build incident, not a
/// theoretical concern: this function's own old-format-only
/// implementation broke every real host-side test that reaches it the
/// moment CI's freshly-built vasm happened to be 2.0f instead of
/// whatever it was when the old format was last verified - see the
/// commit that added this comment for the full incident.
pub fn parseDepackOffset(listing: []const u8) !u32 {
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "Depack LAB (0x")) {
            const rest = line["Depack LAB (0x".len..];
            const close = std.mem.indexOfScalar(u8, rest, ')') orelse continue;
            return std.fmt.parseInt(u32, rest[0..close], 16);
        }
        if (std.mem.startsWith(u8, line, "Depack") and
            (line.len == "Depack".len or line["Depack".len] == ' ' or line["Depack".len] == '\t'))
        {
            const marker = std.mem.indexOf(u8, line, "A:") orelse continue;
            const hex = std.mem.trimEnd(u8, line[marker + 2 ..], " \t\r");
            return std.fmt.parseInt(u32, hex, 16);
        }
    }
    return error.DepackLabelNotFound;
}

pub const Result = struct {
    cycles: u64,
    instructions: u64,
    /// Owned by the caller (allocated with the `allocator` passed to
    /// `timeDepack`) - the emulated Depack: routine's raw output,
    /// `uncompressed_size` bytes, for the caller to verify itself (see
    /// tools/bench/main.zig and src/main.zig's own cross-checks against
    /// each backend's independent host-side `decompress`).
    output: []u8,

    pub fn seconds(self: Result) f64 {
        return @as(f64, @floatFromInt(self.cycles)) / PAL_CPU_HZ;
    }
};

const Setup = struct {
    stub_base: u32,
    payload_base: u32,
    output_base: u32,
    stack_top: u32,
    trampoline: u32,
};

/// Shared by `timeDepack` and `measureOverlapMargin`: lays out the
/// stub, payload, output buffer, and stack in the emulated address
/// space (nothing here needs to match real Amiga addresses - both
/// callers jump straight into `Depack:`, so the only contract that
/// matters is runtime.i's own register convention), embeds fake_exec,
/// and resets the CPU. Doesn't set A0/A1/D0/PC - callers differ only
/// in `compressed_size`/`depack_offset`, set by `startRun` below.
fn setupRun(stub_bytes: []const u8, payload: []const u8, uncompressed_size: u32) !Setup {
    const stub_base: u32 = 0x1000;
    const stub_len: u32 = @intCast(stub_bytes.len);
    const payload_base: u32 = std.mem.alignForward(u32, stub_base + stub_len, 4);
    const output_base: u32 = std.mem.alignForward(u32, payload_base + @as(u32, @intCast(payload.len)), 4);
    const stack_size: u32 = 16384;
    const stack_top: u32 = std.mem.alignForward(u32, output_base + uncompressed_size, 4) + stack_size;
    // Bounded by FAKE_EXEC_CODE_BASE, not MEM_SIZE: that whole upper
    // region is reserved for fake_exec.s and its scratch buffer (see
    // those constants' own comment) and must never overlap this
    // dynamic layout.
    if (stack_top >= FAKE_EXEC_CODE_BASE) return error.PackedFileTooLargeForBenchMemory;

    // A sentinel return address, not a real one: chosen far past
    // anything this harness ever places in `mem`, so it can never
    // collide with a real code/data address. It's only ever compared
    // against PC (to detect the depack routine's own `rts`), never
    // fetched as an instruction - see the single-step loop below on why
    // that's true by construction, not by luck.
    const trampoline: u32 = 0xFFFF0000;

    @memset(&mem, 0);
    @memcpy(mem[stub_base..][0..stub_len], stub_bytes);
    @memcpy(mem[payload_base..][0..payload.len], payload);
    @memcpy(mem[FAKE_EXEC_CODE_BASE..][0..fake_exec.len], fake_exec);

    c.m68k_init();
    c.m68k_set_cpu_type(c.M68K_CPU_TYPE_68000);
    c.m68k_pulse_reset();

    return .{
        .stub_base = stub_base,
        .payload_base = payload_base,
        .output_base = output_base,
        .stack_top = stack_top,
        .trampoline = trampoline,
    };
}

/// Places the initial register state and absorbs the fixed reset-
/// exception cost (see the throwaway `m68k_execute(0)` comment below) -
/// after this, the caller's own single-step loop can begin.
fn startRun(setup: Setup, depack_offset: u32, compressed_size: u32) void {
    // ExecBase, read by inflate/zultra's Depack: via `move.l 4.w,a6` -
    // every other stub never reads address 4 at all, so setting this
    // unconditionally is harmless for them.
    m68k_write_memory_32(4, FAKE_EXEC_CODE_BASE + EXEC_FREEMEM_LVO);

    const sp = setup.stack_top - 4;
    m68k_write_memory_32(sp, setup.trampoline);
    c.m68k_set_reg(c.M68K_REG_SP, sp);
    c.m68k_set_reg(c.M68K_REG_A0, setup.payload_base);
    c.m68k_set_reg(c.M68K_REG_A1, setup.output_base);
    c.m68k_set_reg(c.M68K_REG_D0, compressed_size);
    c.m68k_set_reg(c.M68K_REG_PC, setup.stub_base + depack_offset);

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
}

// Safety valve against a genuine infinite loop. Each single-step
// m68k_execute(1) call costs real wall-clock time, so this bound isn't
// just "some big number": at ~500M it took over 100s of real time to
// actually trip on a known-hanging case (see git history), a bad
// failure mode for a tool meant to be fast. The real hexagon.exe corpus
// item's largest observed step count (a full 216KB shrinkler
// decompression) was ~35.3M, so 100M keeps a healthy ~2.8x margin above
// any real workload seen so far while cutting a genuine hang's
// wall-clock cost roughly 5x.
const step_limit: u64 = 100_000_000;

const RunResult = struct { cycles: u64, steps: u64 };

/// Single-steps until PC reaches `trampoline` (see setupRun's own
/// comment on why single-stepping, not a cycle budget, is the only
/// overshoot-free way to detect `Depack:`'s own `rts`).
fn runToCompletion(trampoline: u32) !RunResult {
    var total_cycles: u64 = 0;
    var steps: u64 = 0;
    while (c.m68k_get_reg(null, c.M68K_REG_PC) != trampoline) {
        total_cycles += @intCast(c.m68k_execute(1));
        steps += 1;
        if (steps > step_limit) return error.DepackNeverReturned;
    }
    return .{ .cycles = total_cycles, .steps = steps };
}

/// Runs `stub_bytes`'s `Depack:` routine (at `depack_offset` within it)
/// against `payload`, exactly per stubs/common/runtime.i's calling
/// convention (A0 = payload, A1 = output buffer, D0 = compressed_size)
/// - bypassing `Start:`/`AllocMem`/relocation entirely, since those
/// aren't what a backend choice actually changes. Returns the exact
/// cycle count and the raw decompressed output.
pub fn timeDepack(
    allocator: std.mem.Allocator,
    stub_bytes: []const u8,
    depack_offset: u32,
    payload: []const u8,
    compressed_size: u32,
    uncompressed_size: u32,
) !Result {
    const setup = try setupRun(stub_bytes, payload, uncompressed_size);
    startRun(setup, depack_offset, compressed_size);
    const run = try runToCompletion(setup.trampoline);

    const output = try allocator.dupe(u8, mem[setup.output_base..][0..uncompressed_size]);
    return .{ .cycles = run.cycles, .instructions = run.steps, .output = output };
}

/// Runs `stub_bytes`'s `Depack:` exactly as `timeDepack` does, but
/// measures the minimum `safety_margin` (docs/format-spec.md §3, §8,
/// §10) this one input needs for true overlap-in-place decompression -
/// compressed payload and decompressed output sharing a single buffer,
/// payload starting `safety_margin` bytes ahead of the output region's
/// own start - rather than the two disjoint regions `timeDepack` itself
/// uses.
///
/// Derivation: for the payload to sit at `output_base + margin`, every
/// write to output offset `w` (address `output_base + w`) must land
/// strictly before the next not-yet-consumed payload byte, at address
/// `output_base + margin + bytes_consumed_so_far`. That's
/// `w < margin + bytes_consumed_so_far`, i.e. `margin >
/// w - bytes_consumed_so_far`, i.e. (since integers) `margin >=
/// (w + 1) - bytes_consumed_so_far`. `overlapTrackWrite` (above)
/// computes exactly that bound - `bytes_written_so_far -
/// bytes_consumed_so_far` - at every write and keeps the running
/// maximum across the whole run in `overlap_required_margin`, using the
/// disjoint layout's own offsets from `payload_base`/`output_base`
/// (real addresses never matter, only offsets into each region).
///
/// Only a lower bound for *this* input - a real per-backend margin
/// (docs/algorithm-notes/) needs this run against enough varied/
/// worst-case inputs (incompressible data, and data that front-loads
/// long back-references, are the usual suspects) to trust the result
/// as a proven formula rather than a one-off measurement.
pub const OverlapMeasurement = struct {
    margin: u32,
    /// This run's own exact cycle count (same `RunResult.cycles`
    /// `timeDepack` itself returns, from the identical
    /// setupRun/startRun/runToCompletion machinery) - exposed so a
    /// caller that already needs to run this measurement (every backend,
    /// for the overlap margin) can also get an exact decompression-time
    /// estimate for free, rather than running a second, separate
    /// `timeDepack` pass whose cost would be redundant with this one
    /// (see src/main.zig's own `--flash=auto` use of this).
    cycles: u64,
};

pub fn measureOverlapMargin(
    stub_bytes: []const u8,
    depack_offset: u32,
    payload: []const u8,
    compressed_size: u32,
    uncompressed_size: u32,
) !OverlapMeasurement {
    const setup = try setupRun(stub_bytes, payload, uncompressed_size);

    overlap_tracking = true;
    defer overlap_tracking = false;
    overlap_payload_base = setup.payload_base;
    overlap_payload_len = compressed_size;
    overlap_output_base = setup.output_base;
    overlap_output_len = uncompressed_size;
    overlap_max_consumed = -1;
    overlap_required_margin = 0;

    startRun(setup, depack_offset, compressed_size);
    const run = try runToCompletion(setup.trampoline);

    return .{ .margin = @intCast(overlap_required_margin), .cycles = run.cycles };
}

/// Test harness for the whole LoadSeg runtime, including relocation and
/// scratch detachment. Non-contiguous allocations expose accidental
/// assumptions that the resident regions share one base address.
pub const LoadedHunk = struct { base: u32, bytes: []u8, next: u32 };
pub fn runExecutable(a: std.mem.Allocator, exe: []const u8) ![]LoadedHunk {
    const hunk = @import("hunk.zig");
    var file = try hunk.parse(a, exe);
    defer file.deinit();
    const loaded = try a.alloc(LoadedHunk, file.hunks.len);
    var initialized: usize = 0;
    errdefer {
        for (loaded[0..initialized]) |h| a.free(h.bytes);
        a.free(loaded);
    }
    @memset(&mem, 0xA5);
    overlap_tracking = false;
    var address: u32 = 0x10000;
    for (file.hunks, 0..) |h, i| {
        loaded[i] = .{ .base = address, .bytes = try a.alloc(u8, h.allocationSize()), .next = 0 };
        initialized += 1;
        address = std.mem.alignForward(u32, address + h.allocationSize() + 4096, 4);
        if (address >= FAKE_EXEC_CODE_BASE - 32768) return error.PackedFileTooLargeForBenchMemory;
    }
    for (file.hunks, 0..) |h, i| {
        const base = loaded[i].base;
        @memcpy(mem[base..][0..h.data.len], h.data);
        m68k_write_memory_32(base - 8, h.allocationSize() + 8);
        m68k_write_memory_32(base - 4, if (i + 1 < loaded.len) (loaded[i + 1].base - 4) / 4 else 0);
    }
    @memcpy(mem[FAKE_EXEC_CODE_BASE..][0..fake_exec.len], fake_exec);
    m68k_write_memory_32(4, FAKE_EXEC_CODE_BASE + EXEC_FREEMEM_LVO);
    c.m68k_init();
    c.m68k_set_cpu_type(c.M68K_CPU_TYPE_68000);
    c.m68k_pulse_reset();
    c.m68k_set_reg(c.M68K_REG_SP, address + 16384);
    c.m68k_set_reg(c.M68K_REG_PC, loaded[0].base);
    _ = c.m68k_execute(0);
    _ = c.m68k_execute(1); // leave the trampoline before waiting for entry
    var steps: usize = 0;
    while (c.m68k_get_reg(null, c.M68K_REG_PC) != loaded[0].base) {
        const pc = c.m68k_get_reg(null, c.M68K_REG_PC);
        if (steps > 1000000 or (pc < loaded[0].base and pc < FAKE_EXEC_CODE_BASE)) {
            return error.RuntimeDidNotReachEntry;
        }
        _ = c.m68k_execute(1);
        steps += 1;
    }
    for (loaded) |*h| {
        @memcpy(h.bytes, mem[h.base..][0..h.bytes.len]);
        h.next = m68k_read_memory_32(h.base - 4);
        for (mem[h.base + h.bytes.len ..][0..16]) |byte| {
            if (byte != 0xA5) return error.ResidentBufferOverrun;
        }
        for (mem[h.base - 24 ..][0..16]) |byte| {
            if (byte != 0xA5) return error.ResidentBufferUnderrun;
        }
    }
    return loaded;
}
