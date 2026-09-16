const std = @import("std");
const Io = std.Io;

// build.zig.zon itself, imported as data (build.zig wires this up) - a
// single source of truth for the version string `--version` prints,
// rather than a hand-synced constant that can drift from a release tag.
const build_zon = @import("build_zon");

const hunk = @import("hunk.zig");
const flatten = @import("flatten.zig");
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
    \\  execram pack [--backend=store|inflate|zultra|libdeflate|zopfli|zx0|salvador|shrinkler|lz4small|lz4normal|lz4fast|most|auto]
    \\               [--mem=chip|fast] [-v] [--flash] <in> <out>
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
    \\--flash sets the border colour (COLOR00) to a fixed bright colour
    \\just before decompression starts and restores it to black just
    \\after - a purely cosmetic "something is happening" indicator for
    \\slow backends (shrinkler on a large file can take tens of seconds
    \\of real 68000 time - see `execram bench`), with nothing else on
    \\screen otherwise to show the machine hasn't hung.
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
    var flash = false;
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
        } else if (std.mem.eql(u8, arg, "--flash")) {
            flash = true;
        } else {
            try positional.append(arena, arg);
        }
    }
    if (positional.items.len != 2) {
        std.log.err("usage: execram pack [--backend=store|inflate|zultra|libdeflate|zopfli|zx0|salvador|shrinkler|lz4small|lz4normal|lz4fast|zx0fast|salvadorfast|most|auto] [--mem=chip|fast] [-v] [--flash] <in> <out>", .{});
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
        try packBest(arena, image, &backend_names, verbose, flash)
    else if (std.mem.eql(u8, backend_name, "most"))
        try packBest(arena, image, &most_backend_names, verbose, flash)
    else
        .{ try packWithBackend(arena, image, backend_name, verbose, flash), backend_name };

    try cwd.writeFile(io, .{ .sub_path = out_path, .data = exe_bytes });

    std.log.info("packed {s} -> {s} (--backend={s}, {d} -> {d} bytes)", .{
        in_path, out_path, used_backend, input_bytes.len, exe_bytes.len,
    });
}

/// Tries every backend in `names` and returns the smallest resulting
/// output, along with which backend produced it - Shrinkler's own "just
/// try it" approach to backend selection (PROJECT_PLAN.md M3), backing
/// both `--backend=most` (`most_backend_names`) and `--backend=auto`
/// (`backend_names`).
fn packBest(arena: std.mem.Allocator, image: flatten.FlatImage, names: []const []const u8, verbose: bool, flash: bool) !struct { []u8, []const u8 } {
    var best: ?[]u8 = null;
    var best_name: []const u8 = "";
    for (names) |name| {
        const candidate = try packWithBackend(arena, image, name, verbose, flash);
        if (best == null or candidate.len < best.?.len) {
            best = candidate;
            best_name = name;
        }
    }
    return .{ best.?, best_name };
}

const CompressedBackend = struct {
    payload: []u8,
    backend_id: container.BackendId,
    stub_bytes: []const u8,
    /// Only used by `execram bench` (musashi_bench.parseDepackOffset) -
    /// see that command's own comment on why it's threaded through here
    /// rather than re-derived from `stub_bytes` by identity.
    stub_listing: []const u8,
};

fn compressWithBackend(arena: std.mem.Allocator, image: flatten.FlatImage, backend_name: []const u8, verbose: bool) !CompressedBackend {
    const payload, const backend_id, const stub_bytes, const stub_listing = if (std.mem.eql(u8, backend_name, "store"))
        .{ try store.compress(arena, image), container.BackendId.store, stub_store, listing_store }
    else if (std.mem.eql(u8, backend_name, "inflate"))
        .{ try inflate.compress(arena, image), container.BackendId.inflate, stub_inflate, listing_inflate }
    else if (std.mem.eql(u8, backend_name, "zultra"))
        // zultra is a different host-side compressor producing the same
        // raw-DEFLATE format as "inflate" - same backend_id, same stub,
        // see src/backends/zultra_vendor/README.md.
        .{ try zultra.compress(arena, image), container.BackendId.inflate, stub_inflate, listing_inflate }
    else if (std.mem.eql(u8, backend_name, "libdeflate"))
        // libdeflate is another host-side compressor producing the
        // same raw-DEFLATE format as "inflate"/"zultra" - same
        // backend_id, same stub, see
        // src/backends/libdeflate_vendor/README.md.
        .{ try libdeflate.compress(arena, image), container.BackendId.inflate, stub_inflate, listing_inflate }
    else if (std.mem.eql(u8, backend_name, "zopfli"))
        // zopfli is another host-side compressor producing the same
        // raw-DEFLATE format as "inflate"/"zultra"/"libdeflate" - same
        // backend_id, same stub, see
        // src/backends/zopfli_vendor/README.md.
        .{ try zopfli.compress(arena, image), container.BackendId.inflate, stub_inflate, listing_inflate }
    else if (std.mem.eql(u8, backend_name, "zx0"))
        .{ try zx0.compress(arena, image), container.BackendId.zx0, stub_zx0, listing_zx0 }
    else if (std.mem.eql(u8, backend_name, "salvador"))
        // salvador is a different host-side ZX0 compressor producing the
        // same format as "zx0" - same backend_id, same stub, see
        // src/backends/salvador_vendor/README.md.
        .{ try salvador.compress(arena, image), container.BackendId.zx0, stub_zx0, listing_zx0 }
    else if (std.mem.eql(u8, backend_name, "zx0fast"))
        // zx0fast/salvadorfast reuse zx0's/salvador's exact host
        // encoders (identical payload format/bytes) but embed Chris
        // Hodges (Platon42)'s faster-decompressing depacker stub - own
        // backend_id, see src/container.zig's BackendId doc comment
        // and stubs/zx0/README.md.
        .{ try zx0.compress(arena, image), container.BackendId.zx0_fast, stub_zx0fast, listing_zx0fast }
    else if (std.mem.eql(u8, backend_name, "salvadorfast"))
        .{ try salvador.compress(arena, image), container.BackendId.zx0_fast, stub_zx0fast, listing_zx0fast }
    else if (std.mem.eql(u8, backend_name, "shrinkler"))
        .{ try shrinkler.compress(arena, image), container.BackendId.shrinkler, stub_shrinkler, listing_shrinkler }
    else if (std.mem.eql(u8, backend_name, "lz4small"))
        // lz4small/lz4normal/lz4fast share one host-side LZ4HC
        // compressor (identical payload bytes) but each embeds a
        // genuinely different depacker stub - own backend_id per
        // variant, see src/container.zig's BackendId doc comment and
        // stubs/lz4/README.md.
        .{ try lz4.compress(arena, image), container.BackendId.lz4_small, stub_lz4small, listing_lz4small }
    else if (std.mem.eql(u8, backend_name, "lz4normal"))
        .{ try lz4.compress(arena, image), container.BackendId.lz4_normal, stub_lz4normal, listing_lz4normal }
    else if (std.mem.eql(u8, backend_name, "lz4fast"))
        .{ try lz4.compress(arena, image), container.BackendId.lz4_fast, stub_lz4fast, listing_lz4fast }
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

    return .{ .payload = payload, .backend_id = backend_id, .stub_bytes = stub_bytes, .stub_listing = stub_listing };
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
    const tail = @max(image.bss_size, @as(u32, @intCast(image.reloc_stream.len)));
    return @intCast(std.mem.alignForward(usize, image.code_data.len + tail, 4));
}

fn packWithBackend(arena: std.mem.Allocator, image: flatten.FlatImage, backend_name: []const u8, verbose: bool, flash: bool) ![]u8 {
    const compressed = try compressWithBackend(arena, image, backend_name, verbose);
    const container_bytes = try container.buildContainer(arena, image, compressed.backend_id, compressed.stub_bytes, compressed.payload, flash);
    return container.writeHunkExecutable(arena, stub_trampoline, container_bytes, hunk0Size(image), image.mem_chip);
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
    // listed here.
    const known_stubs = [_]info.KnownStub{
        .{ .stub_name = "store", .bytes = stub_store },
        .{ .stub_name = "inflate/zultra/libdeflate/zopfli", .bytes = stub_inflate },
        .{ .stub_name = "zx0/salvador", .bytes = stub_zx0 },
        .{ .stub_name = "zx0fast/salvadorfast", .bytes = stub_zx0fast },
        .{ .stub_name = "shrinkler", .bytes = stub_shrinkler },
        .{ .stub_name = "lz4small", .bytes = stub_lz4small },
        .{ .stub_name = "lz4normal", .bytes = stub_lz4normal },
        .{ .stub_name = "lz4fast", .bytes = stub_lz4fast },
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

        // flash=false: irrelevant to this command either way -
        // musashi_bench.timeDepack above jumps straight into `Depack:`,
        // bypassing `Start:` (where FLAG_FLASH's own code lives)
        // entirely, so it could never affect anything this table
        // measures.
        const container_bytes = try container.buildContainer(arena, image, compressed.backend_id, compressed.stub_bytes, compressed.payload, false);
        const exe_bytes = try container.writeHunkExecutable(arena, stub_trampoline, container_bytes, hunk0Size(image), image.mem_chip);
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
