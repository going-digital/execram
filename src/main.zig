const std = @import("std");
const Io = std.Io;

// build.zig.zon itself, imported as data (build.zig wires this up) - a
// single source of truth for the version string `--version` prints,
// rather than a hand-synced constant that can drift from a release tag.
const build_zon = @import("build_zon");

const hunk = @import("hunk.zig");
const flatten = @import("flatten.zig");
const memory_groups = @import("memory_groups.zig");
const mixed_container = @import("mixed_container.zig");
const container = @import("container.zig");
const info = @import("info.zig");
const store = @import("backends/store.zig");
const inflate = @import("backends/inflate.zig");
const zx0 = @import("backends/zx0.zig");
const zultra = @import("backends/zultra.zig");
const libdeflate = @import("backends/libdeflate.zig");
const zopfli = @import("backends/zopfli.zig");
const salvador = @import("backends/salvador.zig");
const shrinkler = @import("backends/shrinkler.zig");
const lz4 = @import("backends/lz4.zig");
const musashi_bench = @import("musashi_bench.zig");

/// M0 smoke test: proves the vasm -> Zig build pipeline works end to end.
/// Real backends replace this in later milestones (see PROJECT_PLAN.md).
const stub_example = @embedFile("stub_example");

/// Hunk 0's own body for every backend alike (docs/memory-lifecycle.md's
/// "new default" - see stubs/common/trampoline.s's own header comment).
const stub_trampoline = @embedFile("stub_trampoline");

/// Depacker stubs (stubs/<name>/stub.s), assembled and embedded at
/// build time (build.zig).
const stub_store = @embedFile("stub_store");
const stub_inflate = @embedFile("stub_inflate");
const stub_zx0 = @embedFile("stub_zx0");
const stub_zx0fast = @embedFile("stub_zx0fast");
const stub_shrinkler = @embedFile("stub_shrinkler");
const stub_lz4small = @embedFile("stub_lz4small");
const stub_lz4normal = @embedFile("stub_lz4normal");
const stub_lz4fast = @embedFile("stub_lz4fast");

/// Flash-instrumented sibling of each stub above (docs/format-spec.md's
/// in-loop decompression flicker) - a separately-assembled binary per
/// backend with the COLOR17/COLOR00 poke baked directly into its hot
/// decode loop (stubs/*/stub_*_flash.s), swapped in by packWithBackend
/// whenever --flash decides this file should flicker. There is no
/// runtime branch between these and the plain stubs above - see
/// stubs/common/runtime.i's own comment on why FLAG_FLASH is purely
/// informational now.
const stub_store_flash = @embedFile("stub_store_flash");
const stub_inflate_flash = @embedFile("stub_inflate_flash");
const stub_zx0_flash = @embedFile("stub_zx0_flash");
const stub_zx0fast_flash = @embedFile("stub_zx0fast_flash");
const stub_shrinkler_flash = @embedFile("stub_shrinkler_flash");
const stub_lz4small_flash = @embedFile("stub_lz4small_flash");
const stub_lz4normal_flash = @embedFile("stub_lz4normal_flash");
const stub_lz4fast_flash = @embedFile("stub_lz4fast_flash");

/// vasm `-L` listings of the same stubs, needed only by `execram
/// bench` (via src/musashi_bench.zig's `parseDepackOffset`) to locate
/// each one's `Depack:` entry point - see that function's own doc
/// comment on why a listing, not the `-Fbin` binary alone, is needed.
const listing_store = @embedFile("stub_store_listing");
const listing_inflate = @embedFile("stub_inflate_listing");
const listing_zx0 = @embedFile("stub_zx0_listing");
const listing_zx0fast = @embedFile("stub_zx0fast_listing");
const listing_shrinkler = @embedFile("stub_shrinkler_listing");
const listing_lz4small = @embedFile("stub_lz4small_listing");
const listing_lz4normal = @embedFile("stub_lz4normal_listing");
const listing_lz4fast = @embedFile("stub_lz4fast_listing");

/// Listings for the flash stubs above - only needed by this file's own
/// "flash stub self-check" test below (locating each one's `Depack:`
/// offset for `musashi_bench.timeDepack`, exactly like the plain
/// listings above serve `execram bench`); never used by non-test code.
const listing_store_flash = @embedFile("stub_store_flash_listing");
const listing_inflate_flash = @embedFile("stub_inflate_flash_listing");
const listing_zx0_flash = @embedFile("stub_zx0_flash_listing");
const listing_zx0fast_flash = @embedFile("stub_zx0fast_flash_listing");
const listing_shrinkler_flash = @embedFile("stub_shrinkler_flash_listing");
const listing_lz4small_flash = @embedFile("stub_lz4small_flash_listing");
const listing_lz4normal_flash = @embedFile("stub_lz4normal_flash_listing");
const listing_lz4fast_flash = @embedFile("stub_lz4fast_flash_listing");

const backend_names = [_][]const u8{ "store", "inflate", "zultra", "libdeflate", "zopfli", "zx0", "salvador", "shrinkler", "lz4small", "lz4normal", "lz4fast", "zx0fast", "salvadorfast" };

/// `--backend=most`'s own backend set (and the default when `--backend`
/// is omitted entirely) - zultra and salvador only, the two backends
/// that in practice produce the smallest output for the bulk of their
/// host-side compression cost (docs/format-spec.md); store/inflate
/// rarely win and shrinkler/zx0 add much more wait than `most` users
/// are willing to spend on every pack. `--backend=auto` remains
/// available for trying every backend in `backend_names`, `most`'s
/// slower, more thorough sibling.
const most_backend_names = [_][]const u8{ "zultra", "salvador" };

/// `execram bench`'s default backend set - `store` (no compression at
/// all, rarely what anyone wants to compare against) and `zx0` (the
/// same container/depacker as `salvador`, which produces the same
/// decompression cost with a vastly faster host-side compressor - see
/// src/backends/salvador.zig - so `zx0` itself adds a lot of wait
/// with no comparison value most of the time: ~508s measured on
/// tests/corpus/hexagon.exe, 221KB, versus salvador's ~13s for the
/// same stub) are excluded by default. `libdeflate` and `zopfli` are
/// included alongside `zultra` (all three inflate-compatible) since
/// none has yet been compared broadly enough to know which one
/// deserves `--backend=most`'s slot - see PROJECT_PLAN.md. All three
/// `lz4*` backends are included too, on purpose: they compress to
/// identical payload bytes (one shared host encoder,
/// src/backends/lz4.zig - see stubs/lz4/README.md), so appearing
/// side by side in `bench`'s table with matching size/ratio columns
/// and different decompression-cycle columns *is* the size-vs-speed
/// trade-off this backend exists to make visible. `salvadorfast` is
/// included for the same reason (vs. `salvador`); `zx0fast` is
/// excluded for the same reason plain `zx0` is (shares `salvadorfast`'s
/// exact decompression cost for a vastly slower host-side compress).
/// `execram bench --all` runs every backend in `backend_names` instead.
const bench_default_backend_names = [_][]const u8{ "inflate", "zultra", "libdeflate", "zopfli", "salvador", "salvadorfast", "shrinkler", "lz4small", "lz4normal", "lz4fast" };

const usage =
    \\execram - Amiga executable compressor
    \\
    \\Usage:
    \\  execram pack [--backend=store|inflate|zultra|libdeflate|zopfli|zx0|salvador|shrinkler|lz4small|lz4normal|lz4fast|zx0fast|salvadorfast|most|auto]
    \\               [--mem=chip|fast] [--overlap=on|off|auto] [-v]
    \\               [--flash=on|off|auto] [--killtwitch] <in> <out>
    \\  execram info <packed-exe>
    \\  execram bench [--all] <in>
    \\  execram --version
    \\
    \\--backend=most (the default) tries zultra and salvador and keeps
    \\whichever produces the smaller output - the two backends that
    \\usually win outright, for a fraction of --backend=auto's total
    \\compression time. --backend=auto tries every backend, most and
    \\shrinkler and zx0 included, and keeps whichever produces the
    \\smallest output overall - slower, but leaves nothing on the table.
    \\zultra, libdeflate, zopfli, and salvador are alternative
    \\compressors for the same container/depacker "inflate"
    \\("zultra"/"libdeflate"/"zopfli") and "zx0" ("salvador") use
    \\respectively - all aim for better ratios at the cost of host-side
    \\compression time.
    \\shrinkler is a from-Shrinkler LZ + adaptive range coder backend
    \\with its own container/depacker - usually the smallest output of
    \\all, also the slowest to compress.
    \\
    \\lz4small/lz4normal/lz4fast are one LZ4HC compressor paired with
    \\three different depacker stubs (72/180/3722 bytes) that trade
    \\stub code size for decompression speed - all three produce the
    \\exact same compressed payload, so unlike every other backend
    \\pair here, choosing between them is a real speed-vs-size decision
    \\for *your* program, not something execram can pick for you. LZ4's
    \\own ratio is well behind the DEFLATE/ZX0-family backends above,
    \\so these exist for programs where fast decompression (a loading
    \\screen, a demo transition) matters more than squeezing out the
    \\last few bytes - see `execram bench`.
    \\
    \\zx0fast/salvadorfast reuse zx0's/salvador's exact host encoders
    \\(byte-identical payload to "zx0"/"salvador") paired with a faster
    \\ZX0 depacker (Chris Hodges/Platon42's fork - stubs/zx0/README.md):
    \\~29% fewer decompression cycles for a 64-byte larger stub - the
    \\same kind of speed-vs-size call as lz4small/lz4normal/lz4fast,
    \\just for the ZX0 format.
    \\
    \\Memory classes are preserved by default: Chip, Fast and ordinary
    \\hunks use separate resident regions with cross-region relocations.
    \\--mem=chip|fast explicitly collapses the input into one region;
    \\fast keeps the historical meaning of ordinary MEMF_ANY memory.
    \\Forcing fast on DMA assets can break the program at runtime.
    \\
    \\--overlap controls true overlap-in-place decompression
    \\(docs/format-spec.md §8b): resident regions and the scratch hunk
    \\remain allocated while each compressed payload moves into its
    \\resident region's own tail instead of the scratch hunk, which is
    \\freed once decompression finishes exactly as in the default
    \\layout - just much smaller now, since it no longer carries the
    \\whole compressed payload. Every backend supports this.
    \\--overlap=auto (the default) measures both layouts' real peak
    \\memory footprint for this file and picks whichever is smaller -
    \\small payloads, or backends like store that never actually shrink
    \\the input, often keep using the default layout, since the overlap
    \\layout's own alignment/margin overhead can outweigh its savings
    \\there. --overlap=on forces it whenever the backend supports it
    \\(falling back to the default layout with a warning otherwise);
    \\--overlap=off always uses the
    \\default layout.
    \\
    \\-v prints per-backend sizes (in --backend=auto mode) and image
    \\statistics as packing proceeds, not just the final result.
    \\
    \\--flash writes changing data to COLOR17 (the mouse pointer
    \\sprite's own middle colour, visible as a flicker even with no
    \\real pointer sprite active) on every iteration of the chosen
    \\backend's decompression loop, so a slow decompress (shrinkler on
    \\a large file can take tens of seconds of real 68000 time - see
    \\`execram bench`) keeps showing the machine hasn't hung, not just
    \\a static "something is happening" indicator. --flash=auto (the
    \\default) enables it only when this file's own measured
    \\decompression time exceeds 1 second; --flash=on always enables
    \\it; --flash=off never does. --killtwitch redirects the target to
    \\COLOR00 (border/background) instead of COLOR17, for programs that
    \\already use the mouse pointer sprite for something else during
    \\decompression; it has no effect when flashing itself is off.
    \\
    \\Every pack self-checks before writing anything: the chosen
    \\backend's compressed output is decompressed host-side and compared
    \\byte-for-byte against the original - packing fails loudly rather
    \\than ever writing an executable that wouldn't decompress correctly
    \\on real hardware.
    \\
    \\bench packs <in> with every backend and prints a comparison table:
    \\output size, compression ratio, and decompression cost on a real
    \\68000 - exact CPU cycles and PAL (7.09MHz) time, measured by
    \\running each depacker stub's actual code through Musashi (a 68000
    \\CPU-core emulator), assuming zero interrupt/OS/DMA overhead. That
    \\last assumption matters: real hardware, especially with the
    \\depacker resident in Chip RAM, will be slower than this, not
    \\faster - treat these times as a best-case lower bound for
    \\comparing backends against each other, not a wall-clock guarantee.
    \\The size/ratio column reflects pack's own --overlap=auto/
    \\--flash=auto defaults, exactly like a plain `execram pack
    \\--backend=<name>` invocation would - so it can be noticeably
    \\larger than the backend's raw compressed-payload size whenever
    \\--overlap=auto picks the overlap layout, which trades a larger
    \\on-disk file for less peak RAM during decompression (see
    \\docs/format-spec.md §8b/§8c).
    \\
    \\bench defaults to inflate/zultra/libdeflate/zopfli/salvador/
    \\salvadorfast/shrinkler/lz4small/lz4normal/lz4fast - store adds no
    \\compression to compare, and zx0/zx0fast share salvador's/
    \\salvadorfast's exact decompression cost (same container/depacker
    \\each) for a much slower host-side compress (minutes, not seconds,
    \\on a large executable). --all runs every backend, store and
    \\zx0/zx0fast included.
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
    } else if (std.mem.eql(u8, command, "bench")) {
        cmdBench(io, arena, args[2..]) catch |err| {
            std.log.err("bench failed: {s}", .{@errorName(err)});
            return err;
        };
    } else if (std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "version")) {
        try printVersion(io);
    } else {
        try printUsage(io);
    }
}

fn printVersion(io: Io) !void {
    var stdout_buffer: [64]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const w = &stdout_writer.interface;
    try w.print("execram {s}\n", .{build_zon.version});
    try w.flush();
}

fn cmdPack(io: Io, arena: std.mem.Allocator, args: []const []const u8) !void {
    var backend_name: []const u8 = "most";
    var mem_override: ?bool = null; // true = force chip, false = force fast/any
    var verbose = false;
    var flash_mode: FlashMode = .auto;
    var killtwitch = false;
    var overlap_mode: OverlapMode = .auto;
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
        } else if (std.mem.startsWith(u8, arg, "--overlap=")) {
            const v = arg["--overlap=".len..];
            if (std.mem.eql(u8, v, "on")) {
                overlap_mode = .on;
            } else if (std.mem.eql(u8, v, "off")) {
                overlap_mode = .off;
            } else if (std.mem.eql(u8, v, "auto")) {
                overlap_mode = .auto;
            } else {
                std.log.err("--overlap must be 'on', 'off', or 'auto', got '{s}'", .{v});
                return error.InvalidArguments;
            }
        } else if (std.mem.eql(u8, arg, "-v")) {
            verbose = true;
        } else if (std.mem.startsWith(u8, arg, "--flash=")) {
            const v = arg["--flash=".len..];
            if (std.mem.eql(u8, v, "on")) {
                flash_mode = .on;
            } else if (std.mem.eql(u8, v, "off")) {
                flash_mode = .off;
            } else if (std.mem.eql(u8, v, "auto")) {
                flash_mode = .auto;
            } else {
                std.log.err("--flash must be 'on', 'off', or 'auto', got '{s}'", .{v});
                return error.InvalidArguments;
            }
        } else if (std.mem.eql(u8, arg, "--killtwitch")) {
            killtwitch = true;
        } else {
            try positional.append(arena, arg);
        }
    }
    if (positional.items.len != 2) {
        std.log.err("usage: execram pack [--backend=store|inflate|zultra|libdeflate|zopfli|zx0|salvador|shrinkler|lz4small|lz4normal|lz4fast|zx0fast|salvadorfast|most|auto] [--mem=chip|fast] [--overlap=on|off|auto] [-v] [--flash=on|off|auto] [--killtwitch] <in> <out>", .{});
        return error.InvalidArguments;
    }

    const in_path = positional.items[0];
    const out_path = positional.items[1];

    const cwd: Io.Dir = .cwd();
    const input_bytes = try cwd.readFileAlloc(io, in_path, arena, .limited(256 * 1024 * 1024));

    var file = try hunk.parse(arena, input_bytes);
    defer file.deinit();

    if (mem_override == null and memory_groups.needed(file)) {
        const grouped_exe = try packMemoryGroups(arena, file, backend_name, verbose, flash_mode, killtwitch, overlap_mode);
        try cwd.writeFile(io, .{ .sub_path = out_path, .data = grouped_exe });
        std.log.info("packed {s} -> {s} (preserved memory classes, {d} -> {d} bytes)", .{ in_path, out_path, input_bytes.len, grouped_exe.len });
        return;
    }

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
        try packBest(arena, image, &backend_names, verbose, flash_mode, killtwitch, overlap_mode)
    else if (std.mem.eql(u8, backend_name, "most"))
        try packBest(arena, image, &most_backend_names, verbose, flash_mode, killtwitch, overlap_mode)
    else
        .{ try packWithBackend(arena, image, backend_name, verbose, flash_mode, killtwitch, overlap_mode), backend_name };

    try cwd.writeFile(io, .{ .sub_path = out_path, .data = exe_bytes });

    std.log.info("packed {s} -> {s} (--backend={s}, {d} -> {d} bytes)", .{
        in_path, out_path, used_backend, input_bytes.len, exe_bytes.len,
    });
}

/// `--overlap`'s own three states (docs/format-spec.md §8's overlap
/// runtime algorithm): `off` always uses today's disjoint two-hunk
/// layout; `on` uses the overlap layout whenever the chosen backend has
/// one, falling back to disjoint with a warning otherwise; `auto` (the
/// default) picks whichever layout has the smaller peak memory
/// footprint for this specific file, per backend.
const OverlapMode = enum { on, off, auto };

/// `--flash`'s own three states, mirroring `OverlapMode` exactly: `off`
/// never embeds a flash-instrumented stub; `on` always does (every
/// backend has one now, so there's no fallback case to warn about,
/// unlike `--overlap=on`); `auto` (the default) embeds one only when
/// this file's own measured decompression time
/// (CompressedBackend.seconds) exceeds 1 second.
const FlashMode = enum { on, off, auto };

/// Tries every backend in `names` and returns the smallest resulting
/// output, along with which backend produced it - Shrinkler's own "just
/// try it" approach to backend selection (PROJECT_PLAN.md M3), backing
/// both `--backend=most` (`most_backend_names`) and `--backend=auto`
/// (`backend_names`).
fn packBest(arena: std.mem.Allocator, image: flatten.FlatImage, names: []const []const u8, verbose: bool, flash_mode: FlashMode, killtwitch: bool, overlap_mode: OverlapMode) !struct { []u8, []const u8 } {
    var best: ?[]u8 = null;
    var best_name: []const u8 = "";
    for (names) |name| {
        const candidate = try packWithBackend(arena, image, name, verbose, flash_mode, killtwitch, overlap_mode);
        if (best == null or candidate.len < best.?.len) {
            best = candidate;
            best_name = name;
        }
    }
    return .{ best.?, best_name };
}

fn packMemoryGroups(arena: std.mem.Allocator, file: hunk.HunkFile, name: []const u8, verbose: bool, flash_mode: FlashMode, killtwitch: bool, overlap_mode: OverlapMode) ![]u8 {
    const groups = try memory_groups.build(arena, file);
    defer memory_groups.deinit(arena, groups);
    const names: []const []const u8 = if (std.mem.eql(u8, name, "auto")) &backend_names else if (std.mem.eql(u8, name, "most")) &most_backend_names else &.{name};
    var best: ?[]u8 = null;
    var best_name: []const u8 = "";
    for (names) |candidate| {
        const grouped_exe = try packGroupsBackend(arena, groups, candidate, verbose, flash_mode, killtwitch, overlap_mode, null);
        if (best == null or grouped_exe.len < best.?.len) {
            if (best) |old| arena.free(old);
            best = grouped_exe;
            best_name = candidate;
        } else arena.free(grouped_exe);
    }
    std.log.info("selected {s}; resident memory classes preserved across {d} regions", .{ best_name, groups.len });
    return best.?;
}

fn flashListing(id: container.BackendId) []const u8 {
    return switch (id) {
        .store => listing_store_flash,
        .inflate => listing_inflate_flash,
        .zx0 => listing_zx0_flash,
        .zx0_fast => listing_zx0fast_flash,
        .shrinkler => listing_shrinkler_flash,
        .lz4_small => listing_lz4small_flash,
        .lz4_normal => listing_lz4normal_flash,
        .lz4_fast => listing_lz4fast_flash,
        else => unreachable,
    };
}

const GroupMetrics = struct { cycles: u64 = 0 };

fn packGroupsBackend(arena: std.mem.Allocator, groups: []const memory_groups.Group, name: []const u8, verbose: bool, flash_mode: FlashMode, killtwitch: bool, overlap_mode: OverlapMode, metrics: ?*GroupMetrics) ![]u8 {
    const parts = try arena.alloc(mixed_container.Part, groups.len);
    defer arena.free(parts);
    var initialized: usize = 0;
    defer for (parts[0..initialized]) |p| arena.free(p.payload);
    var representative: CompressedBackend = undefined;
    var seconds: f64 = 0;
    for (groups, 0..) |g, i| {
        const compressed = try compressWithBackend(arena, g.image, name, verbose);
        if (metrics) |m| {
            const expected = try std.mem.concat(arena, u8, &.{ g.image.code_data, g.image.reloc_stream });
            defer arena.free(expected);
            const measured = try musashi_bench.timeDepack(arena, compressed.stub_bytes, try musashi_bench.parseDepackOffset(compressed.stub_listing), compressed.payload, @intCast(compressed.payload.len), @intCast(expected.len));
            defer arena.free(measured.output);
            if (!std.mem.eql(u8, expected, measured.output)) return error.EmulatedOutputMismatch;
            m.cycles += measured.cycles;
        }
        representative = compressed;
        seconds += compressed.seconds;
        const prefix = if (i == 0) stub_trampoline.len else 0;
        const resident = @max(container.residentTailSize(g.image.code_data.len, g.image.bss_size, g.image.reloc_stream.len), std.mem.alignForward(u32, @intCast(prefix), 4));
        const margin = compressed.overlap_margin.?;
        const overlapped = container.overlapAllocatedSize(prefix, @intCast(compressed.payload.len), margin, resident);
        // Compare each region's contribution to peak memory; the shared
        // dispatcher and descriptor table cost the same in either layout.
        const overlap = switch (overlap_mode) {
            .on => true,
            .off => false,
            .auto => overlapped < resident + std.mem.alignForward(usize, compressed.payload.len, 4),
        };
        parts[i] = .{ .group = g, .payload = compressed.payload, .margin = margin, .overlap = overlap };
        initialized += 1;
    }
    const flash = flash_mode == .on or (flash_mode == .auto and seconds > 1.0);
    const decoder = if (flash) representative.flash_stub_bytes else representative.stub_bytes;
    const listing = if (flash) flashListing(representative.backend_id) else representative.stub_listing;
    return mixed_container.build(arena, parts, stub_trampoline, decoder, try musashi_bench.parseDepackOffset(listing), representative.backend_id, flash, killtwitch);
}

const CompressedBackend = struct {
    payload: []u8,
    backend_id: container.BackendId,
    stub_bytes: []const u8,
    /// This backend's flash-instrumented sibling stub (stubs/*/stub_*_flash.s)
    /// - a drop-in replacement for `stub_bytes` wherever --flash decides
    /// this file should flicker (packWithBackend's own `use_flash`).
    flash_stub_bytes: []const u8,
    /// Only used by `execram bench` (musashi_bench.parseDepackOffset) -
    /// see that command's own comment on why it's threaded through here
    /// rather than re-derived from `stub_bytes` by identity.
    stub_listing: []const u8,
    /// Minimum safety_margin this compressed payload needs for the
    /// overlap layout (musashi_bench.measureOverlapMargin,
    /// docs/format-spec.md §8b) - every backend supports this today
    /// (every stub shares the same `stubs/common/runtime.i`, which
    /// branches on FLAG_OVERLAP entirely at runtime, so there's no
    /// separate overlap stub to track here), so this is only ever null
    /// if a future backend's stub genuinely can't support it for some
    /// backend-specific reason.
    overlap_margin: ?u32,
    /// This backend's own measured decompression time, in real PAL
    /// seconds - the same cycle count `overlap_margin`'s own Musashi run
    /// already produces (musashi_bench.OverlapMeasurement.cycles),
    /// reused here so `--flash=auto`'s ">1 second" decision
    /// (packWithBackend) costs nothing extra: no second emulation pass.
    /// 0.0 whenever `overlap_margin` is null (nothing was measured).
    seconds: f64,
};

fn compressWithBackend(arena: std.mem.Allocator, image: flatten.FlatImage, backend_name: []const u8, verbose: bool) !CompressedBackend {
    const payload, const backend_id, const stub_bytes, const flash_stub_bytes, const stub_listing, const supports_overlap = if (std.mem.eql(u8, backend_name, "store"))
        .{ try store.compress(arena, image), container.BackendId.store, stub_store, stub_store_flash, listing_store, true }
    else if (std.mem.eql(u8, backend_name, "inflate"))
        .{ try inflate.compress(arena, image), container.BackendId.inflate, stub_inflate, stub_inflate_flash, listing_inflate, true }
    else if (std.mem.eql(u8, backend_name, "zultra"))
        // zultra is a different host-side compressor producing the same
        // raw-DEFLATE format as "inflate" - same backend_id, same stub,
        // see src/backends/zultra_vendor/README.md.
        .{ try zultra.compress(arena, image), container.BackendId.inflate, stub_inflate, stub_inflate_flash, listing_inflate, true }
    else if (std.mem.eql(u8, backend_name, "libdeflate"))
        // libdeflate is another host-side compressor producing the
        // same raw-DEFLATE format as "inflate"/"zultra" - same
        // backend_id, same stub, see
        // src/backends/libdeflate_vendor/README.md.
        .{ try libdeflate.compress(arena, image), container.BackendId.inflate, stub_inflate, stub_inflate_flash, listing_inflate, true }
    else if (std.mem.eql(u8, backend_name, "zopfli"))
        // zopfli is another host-side compressor producing the same
        // raw-DEFLATE format as "inflate"/"zultra"/"libdeflate" - same
        // backend_id, same stub, see
        // src/backends/zopfli_vendor/README.md.
        .{ try zopfli.compress(arena, image), container.BackendId.inflate, stub_inflate, stub_inflate_flash, listing_inflate, true }
    else if (std.mem.eql(u8, backend_name, "zx0"))
        .{ try zx0.compress(arena, image), container.BackendId.zx0, stub_zx0, stub_zx0_flash, listing_zx0, true }
    else if (std.mem.eql(u8, backend_name, "salvador"))
        // salvador is a different host-side ZX0 compressor producing the
        // same format as "zx0" - same backend_id, same stub, see
        // src/backends/salvador_vendor/README.md.
        .{ try salvador.compress(arena, image), container.BackendId.zx0, stub_zx0, stub_zx0_flash, listing_zx0, true }
    else if (std.mem.eql(u8, backend_name, "zx0fast"))
        // zx0fast/salvadorfast reuse zx0's/salvador's exact host
        // encoders (identical payload format/bytes) but embed Chris
        // Hodges (Platon42)'s faster-decompressing depacker stub - own
        // backend_id, see src/container.zig's BackendId doc comment
        // and stubs/zx0/README.md.
        .{ try zx0.compress(arena, image), container.BackendId.zx0_fast, stub_zx0fast, stub_zx0fast_flash, listing_zx0fast, true }
    else if (std.mem.eql(u8, backend_name, "salvadorfast"))
        .{ try salvador.compress(arena, image), container.BackendId.zx0_fast, stub_zx0fast, stub_zx0fast_flash, listing_zx0fast, true }
    else if (std.mem.eql(u8, backend_name, "shrinkler"))
        .{ try shrinkler.compress(arena, image), container.BackendId.shrinkler, stub_shrinkler, stub_shrinkler_flash, listing_shrinkler, true }
    else if (std.mem.eql(u8, backend_name, "lz4small"))
        // lz4small/lz4normal/lz4fast share one host-side LZ4HC
        // compressor (identical payload bytes) but each embeds a
        // genuinely different depacker stub - own backend_id per
        // variant, see src/container.zig's BackendId doc comment and
        // stubs/lz4/README.md.
        .{ try lz4.compress(arena, image), container.BackendId.lz4_small, stub_lz4small, stub_lz4small_flash, listing_lz4small, true }
    else if (std.mem.eql(u8, backend_name, "lz4normal"))
        .{ try lz4.compress(arena, image), container.BackendId.lz4_normal, stub_lz4normal, stub_lz4normal_flash, listing_lz4normal, true }
    else if (std.mem.eql(u8, backend_name, "lz4fast"))
        .{ try lz4.compress(arena, image), container.BackendId.lz4_fast, stub_lz4fast, stub_lz4fast_flash, listing_lz4fast, true }
    else {
        std.log.err("backend '{s}' isn't implemented yet - only 'store'/'inflate'/'zultra'/'libdeflate'/'zopfli'/'zx0'/'salvador'/'shrinkler'/'lz4small'/'lz4normal'/'lz4fast'/'zx0fast'/'salvadorfast'/'most'/'auto' exist so far", .{backend_name});
        return error.UnsupportedBackend;
    };

    // M5 pre-flight self-check: decompress what was just produced,
    // host-side, and confirm it reconstructs the original bytes exactly
    // before ever writing a container to disk (or, from `execram
    // bench`, before ever trusting a Musashi-measured cycle count).
    // Every backend here is vendored/adapted third-party code, not
    // something formally proven correct, so this is cheap, meaningful
    // insurance - the same "always verify before saving" discipline
    // Shrinkler's own CLI follows (DataFile.h's own verify() step).
    const expected = try std.mem.concat(arena, u8, &.{ image.code_data, image.reloc_stream });
    const decoded = decompressWithBackend(arena, backend_name, payload, expected.len) catch |err| {
        std.log.err("self-check failed for backend '{s}': decompression errored ({s}) - refusing to trust this backend's output", .{ backend_name, @errorName(err) });
        return error.SelfCheckFailed;
    };
    if (!std.mem.eql(u8, decoded, expected)) {
        std.log.err("self-check failed for backend '{s}': decompressed output does not match the original bytes - refusing to trust this backend's output", .{backend_name});
        return error.SelfCheckFailed;
    }
    if (verbose) {
        std.log.info("  {s}: {d} -> {d} bytes (self-check OK)", .{ backend_name, expected.len, payload.len });
    }

    // Overlap-margin measurement (docs/format-spec.md §8b): runs
    // unconditionally whenever this backend supports the overlap layout,
    // regardless of --overlap mode - cheap (already proven fast enough
    // for `execram bench`'s own per-backend timing), and keeps this
    // function free of --overlap-aware branching; that decision belongs
    // entirely to packWithBackend.
    const overlap_margin: ?u32, const seconds: f64 = if (supports_overlap) blk: {
        const depack_offset = try musashi_bench.parseDepackOffset(stub_listing);
        const measurement = try musashi_bench.measureOverlapMargin(stub_bytes, depack_offset, payload, @intCast(payload.len), @intCast(expected.len));
        const decompress_seconds = @as(f64, @floatFromInt(measurement.cycles)) / musashi_bench.PAL_CPU_HZ;
        if (verbose) {
            std.log.info("  {s}: overlap safety_margin = {d} bytes, decompress ~{d:.3}s", .{ backend_name, measurement.margin, decompress_seconds });
        }
        break :blk .{ measurement.margin, decompress_seconds };
    } else .{ null, 0.0 };

    return .{
        .payload = payload,
        .backend_id = backend_id,
        .stub_bytes = stub_bytes,
        .flash_stub_bytes = flash_stub_bytes,
        .stub_listing = stub_listing,
        .overlap_margin = overlap_margin,
        .seconds = seconds,
    };
}

/// Hunk 0's own declared/allocated size (src/container.zig's
/// writeHunkExecutable). NOT simply code_data_size + bss_size: Depack
/// writes code_data_size + reloc_stream_size bytes into hunk 0 (the
/// reloc stream occupies the same trailing region BSS ends up in,
/// before RelocFixup consumes it and the BSS-reclear step zeroes that
/// region for real - docs/memory-lifecycle.md), so hunk 0 must be sized
/// for whichever of the two is larger, exactly like the single-
/// allocation scheme's own AllocMem size before it (stubs/common/
/// runtime.i's history) - dropping that `max` here reintroduces the
/// same overflow it fixed, just one level up: a real bug, caught by
/// tests/uae/run_e2e_test.sh's own tiny test program (0 bytes BSS, a
/// 3-byte reloc stream - reloc_stream_size > bss_size, unlike every
/// real-world program tried before it, which all happened to have
/// bss_size dominate) after the two-hunk redesign, not before. Rounded
/// up to a longword: unlike AllocMem's own byte-granular size argument,
/// a HUNK_HEADER size-table entry is a count of longwords.
fn hunk0Size(image: flatten.FlatImage) u32 {
    return @max(container.residentTailSize(image.code_data.len, image.bss_size, image.reloc_stream.len), std.mem.alignForward(u32, @intCast(stub_trampoline.len), 4));
}

fn packWithBackend(arena: std.mem.Allocator, image: flatten.FlatImage, backend_name: []const u8, verbose: bool, flash_mode: FlashMode, killtwitch: bool, overlap_mode: OverlapMode) ![]u8 {
    const compressed = try compressWithBackend(arena, image, backend_name, verbose);
    return buildPackedExecutable(arena, image, backend_name, verbose, compressed, flash_mode, killtwitch, overlap_mode);
}

/// The --overlap/--flash decision and container/hunk assembly, factored
/// out of `packWithBackend` so `cmdBench`'s own size/ratio column can go
/// through the exact same logic - given a `CompressedBackend` it
/// already has in hand (from its own Musashi timing pass) - without
/// either hand-duplicating this decision (and risking it drifting out
/// of sync with what a real `execram pack` invocation actually
/// produces) or paying for a second, redundant `compressWithBackend`
/// call just to get a size number.
fn buildPackedExecutable(arena: std.mem.Allocator, image: flatten.FlatImage, backend_name: []const u8, verbose: bool, compressed: CompressedBackend, flash_mode: FlashMode, killtwitch: bool, overlap_mode: OverlapMode) ![]u8 {
    const resident_tail = hunk0Size(image);

    // --flash decision: every backend has its own flash-instrumented
    // stub now (no fallback case, unlike --overlap=on), so `.on` always
    // takes it. `.auto` uses compressed.seconds - the exact cycle count
    // the overlap-margin measurement above already produced, converted
    // to real PAL seconds - so this costs nothing extra to decide.
    const use_flash = switch (flash_mode) {
        .off => false,
        .on => true,
        .auto => compressed.seconds > 1.0,
    };
    if (verbose) {
        std.log.info("  {s}: flash {s} - decompress ~{d:.3}s", .{ backend_name, if (use_flash) "on" else "off", compressed.seconds });
    }
    const stub_bytes = if (use_flash) compressed.flash_stub_bytes else compressed.stub_bytes;

    // Overlap-mode hunk 1 (docs/format-spec.md §8b): stub_bytes ++
    // header only, no payload this time (buildContainer omits it
    // whenever it's given a margin) - still resident alongside hunk 0
    // for the duration of decompression, same as the disjoint layout's
    // own hunk 1, just far smaller since it no longer carries the whole
    // compressed payload.
    const overlap_hunk1_size: u32 = @intCast(std.mem.alignForward(usize, stub_bytes.len + container.HEADER_SIZE, 4));

    const use_overlap = switch (overlap_mode) {
        .off => false,
        .on => blk: {
            if (compressed.overlap_margin == null) {
                std.log.warn("--overlap=on requested but backend '{s}' doesn't support the overlap layout yet - falling back to the disjoint two-hunk layout", .{backend_name});
                break :blk false;
            }
            break :blk true;
        },
        .auto => blk: {
            const margin = compressed.overlap_margin orelse break :blk false;
            // Disjoint's real peak: hunk 0 (the resident image) and hunk 1
            // (stub+header+payload) are both resident simultaneously
            // during decompression (docs/memory-lifecycle.md).
            const disjoint_hunk1_size: u32 = @intCast(std.mem.alignForward(usize, stub_bytes.len + container.HEADER_SIZE + compressed.payload.len, 4));
            const disjoint_peak = resident_tail + disjoint_hunk1_size;
            const overlap_allocated = container.overlapAllocatedSize(stub_trampoline.len, @intCast(compressed.payload.len), margin, resident_tail);
            const overlap_peak = overlap_allocated + overlap_hunk1_size;
            if (verbose) {
                std.log.info("  {s}: overlap auto - disjoint peak {d} bytes vs overlap peak {d} bytes -> {s}", .{
                    backend_name, disjoint_peak, overlap_peak, if (overlap_peak < disjoint_peak) "overlap" else "disjoint",
                });
            }
            break :blk overlap_peak < disjoint_peak;
        },
    };

    if (use_overlap) {
        const margin = compressed.overlap_margin.?;
        const allocated_size = container.overlapAllocatedSize(stub_trampoline.len, @intCast(compressed.payload.len), margin, resident_tail);
        // The payload sits right after the trampoline on disk (cheap -
        // container.zig's own buildOverlapHunk0Body doc comment) and
        // gets relocated to its margin-safe tail position at runtime
        // (stubs/common/runtime.i's OverlapMovePayload), not positioned
        // there directly on disk.
        const hunk0_body = try container.buildOverlapHunk0Body(arena, stub_trampoline, compressed.payload);
        const hunk1_body = try container.buildContainer(arena, image, compressed.backend_id, stub_bytes, compressed.payload, use_flash, killtwitch, margin, @intCast(stub_trampoline.len));
        return container.writeHunkExecutable(arena, hunk0_body, hunk1_body, allocated_size, image.mem_chip);
    }
    const container_bytes = try container.buildContainer(arena, image, compressed.backend_id, stub_bytes, compressed.payload, use_flash, killtwitch, null, @intCast(stub_trampoline.len));
    return container.writeHunkExecutable(arena, stub_trampoline, container_bytes, resident_tail, image.mem_chip);
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
    else if (std.mem.eql(u8, backend_name, "libdeflate"))
        return libdeflate.decompress(allocator, payload, expected_len)
    else if (std.mem.eql(u8, backend_name, "zopfli"))
        return zopfli.decompress(allocator, payload, expected_len)
    else if (std.mem.eql(u8, backend_name, "zx0"))
        return zx0.decompress(allocator, payload, expected_len)
    else if (std.mem.eql(u8, backend_name, "zx0fast"))
        return zx0.decompress(allocator, payload, expected_len)
    else if (std.mem.eql(u8, backend_name, "salvador"))
        return salvador.decompress(allocator, payload, expected_len)
    else if (std.mem.eql(u8, backend_name, "salvadorfast"))
        return salvador.decompress(allocator, payload, expected_len)
    else if (std.mem.eql(u8, backend_name, "shrinkler"))
        return shrinkler.decompress(allocator, payload, expected_len)
    else if (std.mem.eql(u8, backend_name, "lz4small") or
        std.mem.eql(u8, backend_name, "lz4normal") or
        std.mem.eql(u8, backend_name, "lz4fast"))
        return lz4.decompress(allocator, payload, expected_len)
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
    // listed here. One entry serves both layouts for a given backend
    // (docs/format-spec.md §8b): runtime.i itself branches on
    // FLAG_OVERLAP, so the disjoint and overlap containers embed the
    // exact same stub bytes.
    const known_stubs = [_]info.KnownStub{
        .{ .stub_name = "grouped memory", .bytes = mixed_container.stub },
        .{ .stub_name = "store", .bytes = stub_store },
        .{ .stub_name = "inflate/zultra/libdeflate/zopfli", .bytes = stub_inflate },
        .{ .stub_name = "zx0/salvador", .bytes = stub_zx0 },
        .{ .stub_name = "zx0fast/salvadorfast", .bytes = stub_zx0fast },
        .{ .stub_name = "shrinkler", .bytes = stub_shrinkler },
        .{ .stub_name = "lz4small", .bytes = stub_lz4small },
        .{ .stub_name = "lz4normal", .bytes = stub_lz4normal },
        .{ .stub_name = "lz4fast", .bytes = stub_lz4fast },
        .{ .stub_name = "store (flash)", .bytes = stub_store_flash },
        .{ .stub_name = "inflate/zultra/libdeflate/zopfli (flash)", .bytes = stub_inflate_flash },
        .{ .stub_name = "zx0/salvador (flash)", .bytes = stub_zx0_flash },
        .{ .stub_name = "zx0fast/salvadorfast (flash)", .bytes = stub_zx0fast_flash },
        .{ .stub_name = "shrinkler (flash)", .bytes = stub_shrinkler_flash },
        .{ .stub_name = "lz4small (flash)", .bytes = stub_lz4small_flash },
        .{ .stub_name = "lz4normal (flash)", .bytes = stub_lz4normal_flash },
        .{ .stub_name = "lz4fast (flash)", .bytes = stub_lz4fast_flash },
    };

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const w = &stdout_writer.interface;
    try info.printInfo(arena, w, exe_bytes, &known_stubs);
    try w.flush();
}

/// `execram bench <in>`: packs `in` with every backend and prints a
/// comparison table - output size, compression ratio, and 68000
/// decompression cost measured by actually running each backend's
/// depacker stub through Musashi (src/musashi_bench.zig - shared with
/// the standalone tools/bench dev tool, which measures an
/// already-packed file's stub instead of packing fresh with every
/// backend at once; see that tool's own README for why *it* remains a
/// separate, native-host-only binary while this command ships as part
/// of `execram` itself).
fn cmdBench(io: Io, arena: std.mem.Allocator, args: []const []const u8) !void {
    var all = false;
    var positional: std.ArrayList([]const u8) = .empty;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--all")) {
            all = true;
        } else {
            try positional.append(arena, arg);
        }
    }
    if (positional.items.len != 1) {
        std.log.err("usage: execram bench [--all] <in>", .{});
        return error.InvalidArguments;
    }
    const in_path = positional.items[0];
    const backends: []const []const u8 = if (all) &backend_names else &bench_default_backend_names;

    const cwd: Io.Dir = .cwd();
    const input_bytes = try cwd.readFileAlloc(io, in_path, arena, .limited(256 * 1024 * 1024));

    var file = try hunk.parse(arena, input_bytes);
    defer file.deinit();

    if (memory_groups.needed(file)) {
        const groups = try memory_groups.build(arena, file);
        defer memory_groups.deinit(arena, groups);
        var buffer: [4096]u8 = undefined;
        var output: Io.File.Writer = .init(.stdout(), io, &buffer);
        const writer = &output.interface;
        try writer.writeAll("backend          size   ratio         cycles    PAL time   check\n");
        try writer.flush();
        for (backends) |name| {
            std.log.info("compressing memory regions with {s}...", .{name});
            var metrics = GroupMetrics{};
            const exe = try packGroupsBackend(arena, groups, name, false, .auto, false, .auto, &metrics);
            defer arena.free(exe);
            const ratio = 100.0 * @as(f64, @floatFromInt(exe.len)) / @as(f64, @floatFromInt(input_bytes.len));
            const seconds = @as(f64, @floatFromInt(metrics.cycles)) / musashi_bench.PAL_CPU_HZ;
            try writer.print("{s:<12} {d:>8} {d:>6.1}% {d:>14} {d:>9.4}s      OK\n", .{ name, exe.len, ratio, metrics.cycles, seconds });
            try writer.flush();
        }
        try writer.writeAll("\nCycles sum the region depackers; exclude dispatcher, relocation, OS and DMA overhead.\n");
        try writer.flush();
        return;
    }

    var image = try flatten.flatten(arena, file);
    defer image.deinit();

    // The same bytes every backend is actually asked to reproduce
    // (docs/format-spec.md §6) - computed once, reused both to size
    // the emulated output buffer and to cross-check what Musashi
    // actually produced against what the backend's own host-side
    // decompress already proved correct (compressWithBackend's own
    // self-check, above) - two independent decoders (host Zig/C vs.
    // the real 68k stub under emulation) agreeing is a meaningfully
    // stronger guarantee than either alone. This project has hit a
    // real bug before that passed every host-side test and only
    // surfaced once the actual depacker stub ran (see
    // stubs/shrinkler/stub.s's own comment) - this check exists
    // because of that history, not as generic caution.
    const expected = try std.mem.concat(arena, u8, &.{ image.code_data, image.reloc_stream });

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const w = &stdout_writer.interface;

    try w.print("{s:<10} {s:>10} {s:>7}  {s:>13} {s:>10} {s:>7}\n", .{
        "backend", "size", "ratio", "cycles", "PAL time", "check",
    });
    try w.flush();
    for (backends) |name| {
        // zx0/salvador/shrinkler's optimal-parse host-side compression
        // can take minutes on a large real executable (zx0 in
        // particular - ~508s measured on tests/corpus/hexagon.exe,
        // 221KB, unrelated to anything Musashi times) - a progress line
        // per backend, flushed immediately, so a slow run doesn't look
        // hung. Goes to stderr (std.log), keeping the table itself on
        // stdout clean to pipe/parse.
        std.log.info("compressing with {s}...", .{name});

        const compressed = try compressWithBackend(arena, image, name, false);

        const depack_offset = try musashi_bench.parseDepackOffset(compressed.stub_listing);
        const result = try musashi_bench.timeDepack(
            arena,
            compressed.stub_bytes,
            depack_offset,
            compressed.payload,
            @intCast(compressed.payload.len),
            @intCast(expected.len),
        );

        // .auto/.auto/false: exactly `execram pack`'s own defaults - so
        // this table's size/ratio column always matches what a plain
        // `execram pack --backend=<name>` invocation actually produces,
        // --overlap and --flash included, rather than only the raw
        // disjoint/non-flash container size (which can be dramatically
        // smaller than what --overlap=auto actually picks whenever the
        // overlap layout's own on-disk zero-padding - materializing the
        // safety_margin gap as literal bytes, unlike the disjoint
        // layout's implicit hunk-size-vs-data-length allocation - grows
        // the file well past its compressed payload size). Musashi's
        // own timing above already ran the plain (non-flash) stub
        // directly against `Depack:` regardless of what gets embedded
        // here - a flash poke never touches the read/write pointers or
        // register state RelocFixup/timing depend on - so which stub
        // buildPackedExecutable ends up choosing has no bearing on the
        // cycles/PAL time columns.
        const exe_bytes = try buildPackedExecutable(arena, image, name, false, compressed, .auto, false, .auto);
        const ratio = @as(f64, @floatFromInt(exe_bytes.len)) / @as(f64, @floatFromInt(input_bytes.len)) * 100.0;

        const matches = std.mem.eql(u8, result.output, expected);
        try w.print("{s:<10} {d:>10} {d:>6.1}% {d:>14} {d:>9.4}s {s:>7}\n", .{
            name, exe_bytes.len, ratio, result.cycles, result.seconds(), if (matches) "OK" else "MISMATCH",
        });
        try w.flush();
        if (!matches) {
            std.log.err("bench: '{s}' backend's emulated 68000 output does not match its own host-side decompress - this is a real correctness bug, not a timing artifact", .{name});
            return error.EmulatedOutputMismatch;
        }
    }
    try w.print(
        \\
        \\Note: decompression cost is CPU instruction timing only, from
        \\actually running each depacker on Musashi (a 68000 CPU-core
        \\emulator) - it assumes zero interrupt/OS/DMA overhead, so real
        \\hardware (especially with the depacker resident in Chip RAM,
        \\competing with the copper/blitter/audio for bus cycles) will
        \\be slower than this, not faster. Treat these times as a
        \\best-case lower bound for comparing backends against each
        \\other, not a wall-clock guarantee.
        \\
    , .{});
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

/// Overlap-margin sanity check against adversarial input (docs/format-
/// spec.md §10: "each backend's algorithm-notes entry should derive
/// [a margin] when ready" - measureOverlapMargin's own doc comment
/// flags incompressible data as one of the "usual suspects" worth
/// testing against, since it stresses the read/write gap harder than
/// typical compressible data does). A deterministic non-repeating byte
/// sequence, same idea as tests/corpus/gen_corpus.py's own
/// "incompressible" generator, reimplemented directly in Zig so this
/// runs as a fast host-side test with no FS-UAE/Python dependency.
fn incompressibleFlatImage(allocator: std.mem.Allocator, len: usize) !flatten.FlatImage {
    const code_data = try allocator.alloc(u8, len);
    var x: u32 = 0x2545F491; // arbitrary nonzero xorshift32 seed
    for (code_data) |*b| {
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        b.* = @truncate(x);
    }
    return .{
        .allocator = allocator,
        .code_data = code_data,
        .bss_size = 16,
        .reloc_stream = try allocator.dupe(u8, &.{0xFE}), // no sites, just the terminator
        .mem_chip = false,
    };
}

test "overlap margin stays bounded on incompressible input (store, zx0)" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Small enough that zx0's optimal-parse compressor stays fast (real
    // corpus files take minutes - docs/main.zig's own usage text on
    // `bench`), large enough to exercise a real read/write gap.
    const image = try incompressibleFlatImage(arena, 4096);

    for ([_][]const u8{ "store", "zx0" }) |backend_name| {
        const compressed = try compressWithBackend(arena, image, backend_name, false);
        try std.testing.expect(compressed.overlap_margin != null);
        const margin = compressed.overlap_margin.?;
        // No formal upper bound is proven (that's exactly the open item
        // this test exists to eventually help close), but a margin
        // anywhere near the payload's own size would indicate something
        // has gone very wrong (e.g. tracking the wrong region) rather
        // than genuine backend behavior - both store and zx0 read/write
        // in small, bounded steps per docs/algorithm-notes/.
        try std.testing.expect(margin < compressed.payload.len);

        const resident_tail = hunk0Size(image);
        const allocated_size = container.overlapAllocatedSize(stub_trampoline.len, @intCast(compressed.payload.len), margin, resident_tail);
        try std.testing.expect(allocated_size >= stub_trampoline.len + compressed.payload.len);
        try std.testing.expect(allocated_size >= resident_tail);
        try std.testing.expect(allocated_size >= @as(u32, margin) + compressed.payload.len);

        const packed_bytes = try packWithBackend(arena, image, backend_name, false, .off, false, .on);
        try std.testing.expect(packed_bytes.len > 0);
    }
}

test "every backend supports the overlap layout" {
    // docs/format-spec.md §10: overlap support is universal now
    // (stubs/common/runtime.i's FLAG_OVERLAP branch is shared
    // unconditionally by every stub) - regression test that
    // compressWithBackend actually measures a margin for each one,
    // not just store/zx0 (the two originally-scoped backends already
    // covered by the more detailed test above). A small image keeps
    // even the optimal-parse backends (zx0/salvador) fast here.
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const image = try incompressibleFlatImage(arena, 512);

    for (backend_names) |backend_name| {
        const compressed = try compressWithBackend(arena, image, backend_name, false);
        try std.testing.expect(compressed.overlap_margin != null);

        const packed_bytes = try packWithBackend(arena, image, backend_name, false, .off, false, .on);
        try std.testing.expect(packed_bytes.len > 0);
    }
}

test "flash-instrumented stubs decompress correctly under Musashi" {
    // Runs each of the 8 distinct flash-instrumented stubs' own
    // `Depack:` through Musashi in isolation (musashi_bench.timeDepack,
    // the same mechanism `execram bench` uses), exactly like the plain
    // stubs are already proven correct host-side (compressWithBackend's
    // own self-check) - confirms the flicker poke inserted into each
    // backend's hot decode loop (docs/format-spec.md §8c) doesn't
    // corrupt decompression on a real (emulated) 68000, not just under
    // Zig's own host-side reimplementation. One representative backend
    // name per distinct flash stub binary (skipping zultra/libdeflate/
    // zopfli/salvador/salvadorfast - alternate host compressors that
    // embed the exact same flash stub as inflate/zx0 respectively,
    // already covered here).
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const image = try incompressibleFlatImage(arena, 512);
    const expected = try std.mem.concat(arena, u8, &.{ image.code_data, image.reloc_stream });

    const cases = [_]struct { backend_name: []const u8, flash_listing: []const u8 }{
        .{ .backend_name = "store", .flash_listing = listing_store_flash },
        .{ .backend_name = "inflate", .flash_listing = listing_inflate_flash },
        .{ .backend_name = "zx0", .flash_listing = listing_zx0_flash },
        .{ .backend_name = "zx0fast", .flash_listing = listing_zx0fast_flash },
        .{ .backend_name = "shrinkler", .flash_listing = listing_shrinkler_flash },
        .{ .backend_name = "lz4small", .flash_listing = listing_lz4small_flash },
        .{ .backend_name = "lz4normal", .flash_listing = listing_lz4normal_flash },
        .{ .backend_name = "lz4fast", .flash_listing = listing_lz4fast_flash },
    };

    for (cases) |case| {
        const compressed = try compressWithBackend(arena, image, case.backend_name, false);
        const depack_offset = try musashi_bench.parseDepackOffset(case.flash_listing);
        const result = try musashi_bench.timeDepack(
            arena,
            compressed.flash_stub_bytes,
            depack_offset,
            compressed.payload,
            @intCast(compressed.payload.len),
            @intCast(expected.len),
        );
        try std.testing.expectEqualSlices(u8, expected, result.output);
    }
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
    _ = libdeflate;
    _ = zopfli;
    _ = salvador;
    _ = shrinkler;
    _ = lz4;
    _ = musashi_bench;
}

test "grouped runtime preserves memory classes, reserved tails, BSS and cross-region relocations" {
    const a = std.testing.allocator;
    var code = [_]u8{0} ** 640;
    var data = [_]u8{0} ** 16;
    // Cross-region addend points into the data hunk's reserved tail.
    std.mem.writeInt(u32, code[0..4], 28, .big);
    var code_relocs = [_]hunk.Reloc{ .{ .offset = 0, .target_hunk = 1 }, .{ .offset = 600, .target_hunk = 2 } };
    var data_relocs = [_]hunk.Reloc{.{ .offset = 2, .target_hunk = 0 }};
    var hunks = [_]hunk.Hunk{
        .{ .kind = .code, .mem_attr = .any, .data = &code, .size_bytes = code.len, .allocated_size = 1024, .relocs = &code_relocs },
        .{ .kind = .data, .mem_attr = .chip, .data = &data, .size_bytes = data.len, .allocated_size = 32, .relocs = &data_relocs },
        .{ .kind = .bss, .mem_attr = .fast, .data = &.{}, .size_bytes = 4, .allocated_size = 64, .relocs = &.{} },
    };
    const groups = try memory_groups.build(a, .{ .allocator = a, .hunks = &hunks });
    defer memory_groups.deinit(a, groups);
    for ([_][]const u8{ "store", "inflate", "salvador", "salvadorfast", "shrinkler", "lz4small", "lz4normal", "lz4fast" }) |name| {
        for ([_]OverlapMode{ .off, .on, .auto }) |overlap| {
            for ([_]FlashMode{ .off, .on }) |flash| {
                // Compression helpers use an arena (the CLI's ownership
                // model); retain test allocator leak checks around it.
                var arena = std.heap.ArenaAllocator.init(a);
                defer arena.deinit();
                const exe = try packGroupsBackend(arena.allocator(), groups, name, false, flash, true, overlap, null);
                var parsed = try hunk.parse(a, exe);
                defer parsed.deinit();
                try std.testing.expectEqual(hunk.MemAttr.any, parsed.hunks[0].mem_attr);
                try std.testing.expectEqual(hunk.MemAttr.chip, parsed.hunks[2].mem_attr);
                try std.testing.expectEqual(hunk.MemAttr.fast, parsed.hunks[3].mem_attr);
                const loaded = try musashi_bench.runExecutable(a, exe);
                defer {
                    for (loaded) |h| a.free(h.bytes);
                    a.free(loaded);
                }
                try std.testing.expectEqual(loaded[2].base + 28, std.mem.readInt(u32, loaded[0].bytes[0..4], .big));
                try std.testing.expectEqual(loaded[3].base, std.mem.readInt(u32, loaded[0].bytes[600..604], .big));
                try std.testing.expectEqual(loaded[0].base, std.mem.readInt(u32, loaded[2].bytes[2..6], .big));
                for (loaded[0].bytes[640..1024]) |b| try std.testing.expectEqual(@as(u8, 0), b);
                for (loaded[3].bytes[0..64]) |b| try std.testing.expectEqual(@as(u8, 0), b);
                try std.testing.expectEqual((loaded[2].base - 4) / 4, loaded[0].next);
                try std.testing.expectEqual((loaded[3].base - 4) / 4, loaded[2].next);
                try std.testing.expectEqual(@as(u32, 0), loaded[3].next);
            }
        }
    }
}

test "tiny disjoint executable fits its trampoline and reaches entry" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var bytes = [_]u8{ 0x4e, 0x75, 0x4e, 0x71 };
    var reloc = [_]u8{0xfe};
    const image = flatten.FlatImage{ .allocator = a, .code_data = &bytes, .bss_size = 0, .reloc_stream = &reloc, .mem_chip = false };
    const exe = try packWithBackend(arena.allocator(), image, "store", false, .off, false, .off);
    const loaded = try musashi_bench.runExecutable(a, exe);
    defer {
        for (loaded) |h| a.free(h.bytes);
        a.free(loaded);
    }
    try std.testing.expectEqualSlices(u8, &bytes, loaded[0].bytes[0..4]);
}

test "single explicit Fast region uses MEMF_FAST and detaches scratch" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var bytes = [_]u8{ 0x4e, 0x75, 0x4e, 0x71 };
    var hunks = [_]hunk.Hunk{.{ .kind = .code, .mem_attr = .fast, .data = &bytes, .size_bytes = 4, .allocated_size = 64, .relocs = &.{} }};
    const file = hunk.HunkFile{ .allocator = a, .hunks = &hunks };
    try std.testing.expect(memory_groups.needed(file));
    const groups = try memory_groups.build(a, file);
    defer memory_groups.deinit(a, groups);
    const exe = try packGroupsBackend(arena.allocator(), groups, "store", false, .off, false, .auto, null);
    var parsed = try hunk.parse(a, exe);
    defer parsed.deinit();
    try std.testing.expectEqual(hunk.MemAttr.fast, parsed.hunks[0].mem_attr);
    const loaded = try musashi_bench.runExecutable(a, exe);
    defer {
        for (loaded) |h| a.free(h.bytes);
        a.free(loaded);
    }
    try std.testing.expectEqualSlices(u8, &bytes, loaded[0].bytes[0..4]);
    try std.testing.expectEqual(@as(u32, 0), loaded[0].next);
    var report: Io.Writer.Allocating = .init(a);
    defer report.deinit();
    try info.printInfo(a, &report.writer, exe, &.{.{ .stub_name = "grouped", .bytes = mixed_container.stub }});
    try std.testing.expect(std.mem.indexOf(u8, report.written(), "region 0: fast") != null);
}
