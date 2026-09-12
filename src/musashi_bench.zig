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
pub fn parseDepackOffset(listing: []const u8) !u32 {
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "Depack LAB (0x")) continue;
        const rest = line["Depack LAB (0x".len..];
        const close = std.mem.indexOfScalar(u8, rest, ')') orelse continue;
        return std.fmt.parseInt(u32, rest[0..close], 16);
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
    // Layout in the emulated address space - the stub's code, then the
    // payload it reads from (A0), then the buffer it writes into (A1),
    // then a stack. Nothing here needs to match real Amiga addresses:
    // this harness jumps straight into `Depack:`, so the only contract
    // that matters is runtime.i's own register convention.
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

    // ExecBase, read by inflate/zultra's Depack: via `move.l 4.w,a6` -
    // every other stub never reads address 4 at all, so setting this
    // unconditionally is harmless for them.
    m68k_write_memory_32(4, FAKE_EXEC_CODE_BASE + EXEC_FREEMEM_LVO);

    const sp = stack_top - 4;
    m68k_write_memory_32(sp, trampoline);
    c.m68k_set_reg(c.M68K_REG_SP, sp);
    c.m68k_set_reg(c.M68K_REG_A0, payload_base);
    c.m68k_set_reg(c.M68K_REG_A1, output_base);
    c.m68k_set_reg(c.M68K_REG_D0, compressed_size);
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
    // Safety valve against a genuine infinite loop. Each single-step
    // m68k_execute(1) call costs real wall-clock time, so this bound
    // isn't just "some big number": at ~500M it took over 100s of real
    // time to actually trip on a known-hanging case (see git history),
    // a bad failure mode for a tool meant to be fast. The real
    // hexagon.exe corpus item's largest observed step count (a full
    // 216KB shrinkler decompression) was ~35.3M, so 100M keeps a
    // healthy ~2.8x margin above any real workload seen so far while
    // cutting a genuine hang's wall-clock cost roughly 5x.
    const step_limit: u64 = 100_000_000;
    while (c.m68k_get_reg(null, c.M68K_REG_PC) != trampoline) {
        total_cycles += @intCast(c.m68k_execute(1));
        steps += 1;
        if (steps > step_limit) return error.DepackNeverReturned;
    }

    const output = try allocator.dupe(u8, mem[output_base..][0..uncompressed_size]);
    return .{ .cycles = total_cycles, .instructions = steps, .output = output };
}
