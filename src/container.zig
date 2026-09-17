//! Builds the execram v0 container (docs/format-spec.md §3) - stub code
//! ++ header (++ compressed payload, disjoint layout only) - and wraps
//! it as a two-hunk AmigaDOS load file (docs/format-spec.md §2,
//! `writeHunkExecutable`). Both the default disjoint layout and the
//! opt-in overlap layout (docs/format-spec.md §8b,
//! `stubs/common/runtime.i`'s `OverlapPayloadOffset`) use the exact same
//! two-hunk shape and the same `writeHunkExecutable` - they differ only
//! in what each hunk's own body contains: disjoint puts the compressed
//! payload in hunk 1 (`buildContainer`, freed after use); overlap puts
//! it right after the trampoline in hunk 0's own on-disk body instead
//! (`buildOverlapHunk0Body`) - relocated to its computed, margin-safe
//! tail position at runtime (`stubs/common/runtime.i`'s
//! `OverlapMovePayload`), not already positioned there on disk, or the
//! gap between the trampoline and that tail position would have to be
//! materialized as literal file bytes - leaving hunk 1 with just the
//! stub code and header (still freed after use, now much smaller).

const std = @import("std");
const flatten = @import("flatten.zig");

pub const BackendId = enum(u8) {
    store = 0,
    inflate = 1,
    zx0 = 2,
    shrinkler = 3,
    /// One ID per distinct depacker stub (matching every other value
    /// here), not per host encoder - the three lz4* CLI backends share
    /// one host-side compressor (src/backends/lz4.zig) but each embeds
    /// a genuinely different stub (stubs/lz4/README.md), unlike
    /// zultra/libdeflate/zopfli, which share both stub *and* backend_id
    /// with "inflate" because they share the exact same stub too.
    lz4_small = 4,
    lz4_normal = 5,
    lz4_fast = 6,
    /// Same ZX0-format payload as `zx0` (2), same rule as lz4 above:
    /// "zx0fast"/"salvadorfast" share the exact same two host encoders
    /// as "zx0"/"salvador" but embed a genuinely different (Platon42's)
    /// depacker stub - own ID, not a shared one.
    zx0_fast = 7,
    _,
};

const FLAG_MEM_CHIP: u8 = 1;
const FLAG_HAS_RELOCS: u8 = 2;
/// Purely informational: whether `stub_bytes` is this backend's
/// flicker-instrumented stub variant (a per-backend `stub_*_flash`
/// binary, chosen at pack time - see src/main.zig's `packWithBackend`)
/// rather than its plain one. There's no runtime branch on this bit
/// anymore (unlike FLAG_OVERLAP below) - stub *selection* is what
/// actually enables the in-loop flicker, since it lives inside each
/// backend's own hot decode loop, not in the one shared runtime.i
/// every backend's stub includes.
const FLAG_FLASH: u8 = 4;
/// docs/format-spec.md §5, §8: true overlap-in-place decompression -
/// the compressed payload lives at the resident hunk's own tail instead
/// of in a second hunk, and `safety_margin` (below) is a real value
/// instead of the always-0 it is when this flag is clear. Same
/// version_minor-only reasoning as FLAG_FLASH above: every packed file
/// carries its own matching stub, so there's no old-file/new-reader
/// compatibility question to guard (docs/format-spec.md §9).
const FLAG_OVERLAP: u8 = 8;
/// Only meaningful when FLAG_FLASH is set: redirects the in-loop
/// flicker's target from COLOR17 ($dff1a2, the mouse pointer sprite's
/// own middle color - the default) to COLOR00 ($dff180, the border/
/// background color) instead. See stubs/common/header.i's own comment
/// for where each flash-instrumented stub reads this.
const FLAG_KILLTWITCH: u8 = 16;
/// docs/format-spec.md §3: 32 bytes through v1.0, grown to 36 for
/// `trampoline_size` (docs/format-spec.md §8b's `OverlapPayloadOffset`
/// needs it; see that field's own doc below) - additive, same
/// version_minor-only reasoning as FLAG_OVERLAP/FLAG_FLASH above, and
/// `header_size` (h[8..10] below) was always the mechanism meant to let
/// the header grow like this (docs/format-spec.md §3's own note on why
/// the stub always locates the payload via that field, never a
/// hardcoded constant).
pub const HEADER_SIZE: u16 = 36;
const MAGIC = 0x45784372; // "ExCr"

/// Serializes docs/format-spec.md §3's header as hunk 1's own body:
/// `stub_bytes ++ header`, and - disjoint layout only - the compressed
/// payload right after it. `compressed_payload` is whatever bytes the
/// chosen backend's compressor produced (for `store`, that's simply
/// `image.code_data ++ image.reloc_stream` verbatim - see
/// src/backends/store.zig) - its `.len` always becomes the header's own
/// `compressed_size` field, but the bytes themselves are only embedded
/// in this function's own returned buffer when `overlap_margin` is
/// `null` (the default disjoint layout, `safety_margin` stays 0,
/// `FLAG_OVERLAP` stays clear). When `overlap_margin` is non-null (the
/// overlap layout, docs/format-spec.md §8b), the payload instead lives
/// at a computed tail offset within hunk 0 - see
/// `buildOverlapHunk0Body` - and this function's own output is just
/// `stub_bytes ++ header`, letting the caller place the payload
/// separately. `trampoline_size` is `stubs/common/trampoline.s`'s own
/// assembled length (`stub_trampoline.len` in src/main.zig) - written
/// unconditionally regardless of layout (docs/format-spec.md §8b's
/// `OverlapPayloadOffset` needs it; the disjoint layout's own runtime
/// path simply never reads it, same as any other field it doesn't need).
/// `killtwitch` only matters when `flash` is true (see FLAG_KILLTWITCH).
pub fn buildContainer(
    allocator: std.mem.Allocator,
    image: flatten.FlatImage,
    backend_id: BackendId,
    stub_bytes: []const u8,
    compressed_payload: []const u8,
    flash: bool,
    killtwitch: bool,
    overlap_margin: ?u32,
    trampoline_size: u32,
) ![]u8 {
    var flags: u8 = 0;
    if (image.mem_chip) flags |= FLAG_MEM_CHIP;
    if (image.reloc_stream.len > 1) flags |= FLAG_HAS_RELOCS; // len 1 is just the 0xFE terminator: no sites
    if (flash) flags |= FLAG_FLASH;
    if (flash and killtwitch) flags |= FLAG_KILLTWITCH;
    const is_overlap = overlap_margin != null;
    if (is_overlap) flags |= FLAG_OVERLAP;

    const total = stub_bytes.len + HEADER_SIZE + (if (is_overlap) 0 else compressed_payload.len);
    var out = try allocator.alloc(u8, total);
    errdefer allocator.free(out);

    @memcpy(out[0..stub_bytes.len], stub_bytes);
    const h = out[stub_bytes.len..][0..HEADER_SIZE];
    @memset(h, 0);
    std.mem.writeInt(u32, h[0..4], MAGIC, .big);
    h[4] = 0; // version_major
    h[5] = 3; // version_minor: bumped for FLAG_KILLTWITCH (docs/format-spec.md §9; previously 2 for FLAG_OVERLAP/trampoline_size, 1 for FLAG_FLASH)
    h[6] = @intFromEnum(backend_id);
    h[7] = flags;
    std.mem.writeInt(u16, h[8..10], HEADER_SIZE, .big);
    // h[10..12] reserved, already zeroed
    std.mem.writeInt(u32, h[12..16], @intCast(image.code_data.len), .big);
    std.mem.writeInt(u32, h[16..20], image.bss_size, .big);
    const reloc_stream_size: u32 = if (flags & FLAG_HAS_RELOCS != 0) @intCast(image.reloc_stream.len) else 0;
    std.mem.writeInt(u32, h[20..24], reloc_stream_size, .big);
    std.mem.writeInt(u32, h[24..28], @intCast(compressed_payload.len), .big);
    std.mem.writeInt(u32, h[28..32], overlap_margin orelse 0, .big); // safety_margin: real only under FLAG_OVERLAP
    std.mem.writeInt(u32, h[32..36], trampoline_size, .big);

    if (!is_overlap) @memcpy(out[stub_bytes.len + HEADER_SIZE ..], compressed_payload);
    return out;
}

const HUNK_CODE: u32 = 0x3E9;
const HUNK_END: u32 = 0x3F2;
const HUNK_HEADER: u32 = 0x3F3;
const MEMF_CHIP_BIT: u32 = 1 << 30;

/// Builds a hunk file as a flat stream of big-endian longwords.
fn w32(list: *std.ArrayList(u8), a: std.mem.Allocator, b: *[4]u8, v: u32) !void {
    std.mem.writeInt(u32, b, v, .big);
    try list.appendSlice(a, b);
}

/// Wraps `hunk0_body` and `hunk1_body` as a *two*-hunk AmigaDOS load file
/// (docs/format-spec.md §2, docs/memory-lifecycle.md): hunk 0 is declared
/// at `resident_size` but its real on-disk content may be smaller (the
/// rest is uninitialized until `Depack` fills it); hunk 1 is freed by the
/// stub itself once decompression finishes (see stubs/common/runtime.i's
/// own comment on the ABI this depends on). `mem_chip` applies only to
/// hunk 0 - hunk 1 is always plain `MEMF_ANY`, since it's scratch space
/// for the duration of decompression, not something worth taking out of
/// the scarcer Chip RAM pool even when the final resident image needs to
/// be there. No HUNK_RELOC32 anywhere - both hunks are
/// position-independent (PC-relative only).
///
/// Two callers, two different `hunk0_body`/`hunk1_body`/`resident_size`
/// shapes, same underlying file format either way (docs/format-spec.md
/// §8b): the default disjoint layout passes `stubs/common/trampoline.s`
/// (hunk 0) and `buildContainer`'s full `stub_bytes ++ header ++
/// payload` (hunk 1), `resident_size` = `residentTailSize`. The overlap
/// layout passes `buildOverlapHunk0Body`'s trampoline+payload (hunk 0,
/// no padding on disk - relocated to its safe tail position at runtime,
/// `stubs/common/runtime.i`'s `OverlapMovePayload` - no separate
/// payload in hunk 1 this time) and
/// `buildContainer`'s `stub_bytes ++ header` alone (hunk 1, built with a
/// non-null `overlap_margin`), `resident_size` = `overlapAllocatedSize`.
pub fn writeHunkExecutable(
    allocator: std.mem.Allocator,
    hunk0_body: []const u8,
    hunk1_body: []const u8,
    resident_size: u32,
    mem_chip: bool,
) ![]u8 {
    std.debug.assert(resident_size % 4 == 0);
    std.debug.assert(resident_size >= hunk0_body.len);

    const hunk1_padded_len = std.mem.alignForward(usize, hunk1_body.len, 4);
    const hunk1_pad = hunk1_padded_len - hunk1_body.len;
    const hunk0_padded_len = std.mem.alignForward(usize, hunk0_body.len, 4);
    const hunk0_pad = hunk0_padded_len - hunk0_body.len;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var buf4: [4]u8 = undefined;

    try w32(&out, allocator, &buf4, HUNK_HEADER);
    try w32(&out, allocator, &buf4, 0); // resident library name list: empty
    try w32(&out, allocator, &buf4, 2); // table_size: two hunks
    try w32(&out, allocator, &buf4, 0); // first_hunk
    try w32(&out, allocator, &buf4, 1); // last_hunk
    const hunk0_size_longs: u32 = resident_size / 4;
    try w32(&out, allocator, &buf4, if (mem_chip) hunk0_size_longs | MEMF_CHIP_BIT else hunk0_size_longs);
    const hunk1_size_longs: u32 = @intCast(hunk1_padded_len / 4);
    try w32(&out, allocator, &buf4, hunk1_size_longs);

    // Hunk 0: declared at the full resident size, real body may be
    // smaller (deliberately, for the disjoint layout's plain trampoline -
    // confirmed safe under real FS-UAE across Kickstart v1.3/v2.05/v3.1,
    // see the commit that introduced this design). AmigaDOS zero-fills
    // nothing beyond the real body for a CODE hunk, but nothing here
    // depends on that - stubs/common/runtime.i's own BSS-reclear step
    // makes no assumption about prior memory state.
    try w32(&out, allocator, &buf4, HUNK_CODE);
    try w32(&out, allocator, &buf4, @intCast(hunk0_padded_len / 4));
    try out.appendSlice(allocator, hunk0_body);
    try out.appendNTimes(allocator, 0, hunk0_pad);
    // Each hunk in a multi-hunk file is terminated by its own HUNK_END
    // (no relocs/symbols/debug follow either body here) - the original
    // single-hunk format only ever needed one, serving double duty as
    // both "end of that hunk's trailer" and "end of file"; two hunks
    // need one each.
    try w32(&out, allocator, &buf4, HUNK_END);

    // Hunk 1: freed by its own code once decompression finishes rather
    // than kept resident forever (stubs/common/runtime.i).
    try w32(&out, allocator, &buf4, HUNK_CODE);
    try w32(&out, allocator, &buf4, hunk1_size_longs);
    try out.appendSlice(allocator, hunk1_body);
    try out.appendNTimes(allocator, 0, hunk1_pad);

    try w32(&out, allocator, &buf4, HUNK_END);

    return out.toOwnedSlice(allocator);
}

/// `code_data_size + max(bss_size, reloc_stream_size)`, 4-aligned - the
/// resident image's own tail-sizing requirement (docs/format-spec.md §8:
/// Depack always writes the larger of the two into the tail before BSS
/// is re-cleared, so undersizing this lets it overflow past the end of
/// the buffer). Shared by both layouts: `writeHunkExecutable`'s hunk 0
/// (via src/main.zig's `hunk0Size`) and `overlapAllocatedSize` below need
/// exactly the same number for exactly the same reason.
pub fn residentTailSize(code_data_len: usize, bss_size: u32, reloc_stream_len: usize) u32 {
    const tail = @max(bss_size, @as(u32, @intCast(reloc_stream_len)));
    return @intCast(std.mem.alignForward(usize, code_data_len + tail, 4));
}

/// The overlap layout's required hunk-0 allocated size (docs/format-spec.md
/// §8b's overlap runtime algorithm, stubs/common/runtime.i's
/// `OverlapPayloadOffset`): the largest of -
///
///   1. on-disk fit: `trampoline_size + compressed_size` (hunk 0's own
///      on-disk body, `buildOverlapHunk0Body`, is exactly this many
///      bytes now - the payload sits right after the trampoline on
///      disk, relocated to its safe tail position by a runtime step,
///      `stubs/common/runtime.i`'s `OverlapMovePayload` - it no longer
///      needs to already BE at that tail position on disk) must
///      physically fit within the allocated size. Without this bound, a
///      backend whose compressed_size ends up close to resident_tail_size
///      - `store`, e.g., which never shrinks the input at all, so its
///      own compressed_size routinely equals resident_tail_size exactly
///      - can compute a payload offset of 0 or less, overlapping the
///      trampoline itself: a real bug found on real hardware (git
///      history) before this bound was added. This same bound also
///      guarantees `payload_offset >= trampoline_size` unconditionally,
///      which is what makes `OverlapMovePayload`'s own backward
///      (highest-address-first) copy direction always safe, regardless
///      of how much the on-disk and safe-tail positions overlap;
///   2. resident fit: `residentTailSize` above, same reason as the
///      disjoint layout's hunk 0;
///   3. overlap safety: the payload, tail-aligned, must lead the output
///      (offset 0) by at least `overlap_margin` bytes -
///      `overlap_margin + compressed_size`.
///
/// Uses `align4(compressed_size)`, not the raw value, in (1) and (3):
/// the payload's own tail-aligned start offset within hunk 0
/// (`allocated_size - compressed_size`) would otherwise be ODD whenever
/// compressed_size itself is odd, even though `allocated_size` is always
/// a multiple of 4 - a real 68000 Address Error the moment a backend's
/// `Depack:` does its first word/long read from an odd A0 (confirmed on
/// real hardware: `store`'s own bulk `move.l (a0)+,(a1)+` copy loop
/// faults immediately - see the commit that found this). Rounding
/// compressed_size up to a multiple of 4 everywhere it contributes to
/// sizing/positioning (never in the actual byte count handed to `Depack`
/// itself) keeps that offset a multiple of 4 unconditionally, at the
/// cost of at most 3 bytes of harmless trailing padding after the real
/// payload.
pub fn overlapAllocatedSize(trampoline_size: usize, compressed_size: u32, overlap_margin: u32, resident_tail_size: u32) u32 {
    const compressed_size_aligned = std.mem.alignForward(usize, compressed_size, 4);
    const on_disk_len = trampoline_size + compressed_size_aligned;
    const overlap_min: usize = @as(usize, overlap_margin) + compressed_size_aligned;
    return @intCast(std.mem.alignForward(usize, @max(on_disk_len, @max(resident_tail_size, overlap_min)), 4));
}

/// Builds hunk 0's own on-disk body for the overlap layout
/// (docs/format-spec.md §8b): `trampoline_bytes` (byte-identical to the
/// disjoint layout's own hunk 0 - stubs/common/trampoline.s is
/// unaffected by which layout is in use) immediately followed by the
/// compressed payload - nothing else. AmigaDOS's LoadSeg loads a hunk's
/// on-disk bytes starting at that hunk's own data front and leaves the
/// rest of its declared (larger) allocation implicit/uninitialized, so
/// this on-disk body only ever needs to be `trampoline_size +
/// compressed_size` bytes long, regardless of how large `overlap_margin`
/// (and therefore the real allocated size, `overlapAllocatedSize` above)
/// ends up being.
///
/// The payload is deliberately NOT placed at its eventual margin-safe
/// tail position here - `stubs/common/runtime.i`'s `OverlapMovePayload`
/// relocates it there at runtime, right before `Depack` runs, matching
/// Shrinkler's own `--overlap` decrunch headers (`HunkFile.h`,
/// `docs/memory-lifecycle.md`'s "Comparison" section - the same
/// on-disk-cheap, runtime-relocate design, not something novel here).
/// An earlier version of this function DID place the payload directly
/// at `payload_offset` on disk, padded with zero bytes from the
/// trampoline's end - avoiding a runtime relocation step at the cost of
/// materializing that whole gap as literal file bytes. For any backend
/// with a real compression ratio, that gap approaches the full
/// decompressed size (the margin needed for uniformly-compressible data
/// converges to decompressed_size - compressed_size), so the packed
/// file ended up barely smaller than the original, uncompressed input -
/// a real, reported bug, not just a missed optimization.
pub fn buildOverlapHunk0Body(allocator: std.mem.Allocator, trampoline_bytes: []const u8, compressed_payload: []const u8) ![]u8 {
    var out = try allocator.alloc(u8, trampoline_bytes.len + compressed_payload.len);
    errdefer allocator.free(out);
    @memcpy(out[0..trampoline_bytes.len], trampoline_bytes);
    @memcpy(out[trampoline_bytes.len..], compressed_payload);
    return out;
}

const hunk = @import("hunk.zig");

test "writeHunkExecutable round-trips through hunk.zig" {
    const trampoline = "tramp!!"; // 7 bytes, arbitrary - real content is stubs/common/trampoline.s
    const container = "hello, this is a fake stub+header+payload blob";
    const exe_bytes = try writeHunkExecutable(std.testing.allocator, trampoline, container, 64, false);
    defer std.testing.allocator.free(exe_bytes);

    var file = try hunk.parse(std.testing.allocator, exe_bytes);
    defer file.deinit();

    try std.testing.expectEqual(@as(usize, 2), file.hunks.len);
    try std.testing.expectEqual(hunk.HunkKind.code, file.hunks[0].kind);
    try std.testing.expectEqual(hunk.MemAttr.any, file.hunks[0].mem_attr);
    // Hunk 0's real on-disk body is just the trampoline, padded to a
    // longword - not the full declared (resident, 64-byte) table size;
    // the rest is uninitialized until the stub's own Depack call fills
    // it at runtime (hunk.zig's `size_bytes` reports this hunk's own
    // restated body size, not the table's - see that field's own doc).
    try std.testing.expectEqual(@as(u32, 8), file.hunks[0].size_bytes);
    try std.testing.expectEqualSlices(u8, trampoline, file.hunks[0].data[0..trampoline.len]);

    try std.testing.expectEqual(hunk.HunkKind.code, file.hunks[1].kind);
    try std.testing.expectEqual(hunk.MemAttr.any, file.hunks[1].mem_attr);
    // The hunk is padded to a longword boundary; our container's exact
    // bytes must still appear verbatim as its prefix.
    try std.testing.expectEqualSlices(u8, container, file.hunks[1].data[0..container.len]);
}

test "writeHunkExecutable sets the Chip RAM memory flag on hunk 0 only" {
    const exe_bytes = try writeHunkExecutable(std.testing.allocator, "t", "x", 4, true);
    defer std.testing.allocator.free(exe_bytes);

    var file = try hunk.parse(std.testing.allocator, exe_bytes);
    defer file.deinit();

    try std.testing.expectEqual(hunk.MemAttr.chip, file.hunks[0].mem_attr);
    // Hunk 1 is scratch space for the duration of decompression only -
    // always plain MEMF_ANY, even when the resident image needs Chip RAM
    // (docs/memory-lifecycle.md's "Chip RAM: both buffers share one
    // decision" - this redesign is what actually fixes that, for the
    // scratch hunk's own share of it).
    try std.testing.expectEqual(hunk.MemAttr.any, file.hunks[1].mem_attr);
}

test "buildContainer serializes the header per docs/format-spec.md" {
    var image = flatten.FlatImage{
        .allocator = std.testing.allocator,
        .code_data = try std.testing.allocator.dupe(u8, &.{ 1, 2, 3, 4 }),
        .bss_size = 8,
        .reloc_stream = try std.testing.allocator.dupe(u8, &.{0xFE}), // no sites, just the terminator
        .mem_chip = true,
    };
    defer image.deinit();

    const stub = "STUB";
    const payload = "PAYLOAD!"; // 8 bytes, arbitrary for this test
    const out = try buildContainer(std.testing.allocator, image, .store, stub, payload, false, false, null, 7);
    defer std.testing.allocator.free(out);

    try std.testing.expectEqualSlices(u8, stub, out[0..4]);
    const h = out[4..40];
    try std.testing.expectEqual(@as(u32, MAGIC), std.mem.readInt(u32, h[0..4], .big));
    try std.testing.expectEqual(@as(u8, 0), h[4]); // version_major
    try std.testing.expectEqual(@as(u8, 3), h[5]); // version_minor (bumped for FLAG_KILLTWITCH)
    try std.testing.expectEqual(@as(u8, @intFromEnum(BackendId.store)), h[6]); // backend_id
    try std.testing.expectEqual(FLAG_MEM_CHIP, h[7]); // chip set, has_relocs/flash/overlap clear
    try std.testing.expectEqual(@as(u16, HEADER_SIZE), std.mem.readInt(u16, h[8..10], .big));
    try std.testing.expectEqual(@as(u32, 4), std.mem.readInt(u32, h[12..16], .big)); // code_data_size
    try std.testing.expectEqual(@as(u32, 8), std.mem.readInt(u32, h[16..20], .big)); // bss_size
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, h[20..24], .big)); // reloc_stream_size (no sites)
    try std.testing.expectEqual(@as(u32, 8), std.mem.readInt(u32, h[24..28], .big)); // compressed_size
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, h[28..32], .big)); // safety_margin
    try std.testing.expectEqual(@as(u32, 7), std.mem.readInt(u32, h[32..36], .big)); // trampoline_size
    try std.testing.expectEqualSlices(u8, payload, out[40..]);
}

test "buildContainer sets FLAG_FLASH when asked" {
    var image = flatten.FlatImage{
        .allocator = std.testing.allocator,
        .code_data = try std.testing.allocator.dupe(u8, &.{ 1, 2, 3, 4 }),
        .bss_size = 0,
        .reloc_stream = try std.testing.allocator.dupe(u8, &.{0xFE}),
        .mem_chip = false,
    };
    defer image.deinit();

    const out = try buildContainer(std.testing.allocator, image, .store, "STUB", "PAYLOAD!", true, false, null, 7);
    defer std.testing.allocator.free(out);

    try std.testing.expectEqual(FLAG_FLASH, out[4..40][7]);
}

test "buildContainer sets FLAG_KILLTWITCH only alongside FLAG_FLASH" {
    var image = flatten.FlatImage{
        .allocator = std.testing.allocator,
        .code_data = try std.testing.allocator.dupe(u8, &.{ 1, 2, 3, 4 }),
        .bss_size = 0,
        .reloc_stream = try std.testing.allocator.dupe(u8, &.{0xFE}),
        .mem_chip = false,
    };
    defer image.deinit();

    // flash=true, killtwitch=true: both bits set.
    const out1 = try buildContainer(std.testing.allocator, image, .store, "STUB", "PAYLOAD!", true, true, null, 7);
    defer std.testing.allocator.free(out1);
    try std.testing.expectEqual(FLAG_FLASH | FLAG_KILLTWITCH, out1[4..40][7]);

    // flash=false, killtwitch=true: killtwitch is meaningless without
    // flash, so it must NOT be set - a --killtwitch pass with no actual
    // flashing shouldn't silently claim a target register that's never
    // used.
    const out2 = try buildContainer(std.testing.allocator, image, .store, "STUB", "PAYLOAD!", false, true, null, 7);
    defer std.testing.allocator.free(out2);
    try std.testing.expectEqual(@as(u8, 0), out2[4..40][7]);
}

test "buildContainer sets FLAG_OVERLAP and safety_margin when given a margin" {
    var image = flatten.FlatImage{
        .allocator = std.testing.allocator,
        .code_data = try std.testing.allocator.dupe(u8, &.{ 1, 2, 3, 4 }),
        .bss_size = 0,
        .reloc_stream = try std.testing.allocator.dupe(u8, &.{0xFE}),
        .mem_chip = false,
    };
    defer image.deinit();

    const out = try buildContainer(std.testing.allocator, image, .store, "STUB", "PAYLOAD!", false, false, 1234, 7);
    defer std.testing.allocator.free(out);

    const h = out[4..40];
    try std.testing.expectEqual(FLAG_OVERLAP, h[7]);
    try std.testing.expectEqual(@as(u32, 1234), std.mem.readInt(u32, h[28..32], .big));
}

test "buildContainer leaves FLAG_OVERLAP clear and safety_margin 0 when overlap_margin is null" {
    var image = flatten.FlatImage{
        .allocator = std.testing.allocator,
        .code_data = try std.testing.allocator.dupe(u8, &.{ 1, 2, 3, 4 }),
        .bss_size = 0,
        .reloc_stream = try std.testing.allocator.dupe(u8, &.{0xFE}),
        .mem_chip = false,
    };
    defer image.deinit();

    const out = try buildContainer(std.testing.allocator, image, .store, "STUB", "PAYLOAD!", false, false, null, 7);
    defer std.testing.allocator.free(out);

    const h = out[4..40];
    try std.testing.expectEqual(@as(u8, 0), h[7] & FLAG_OVERLAP);
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, h[28..32], .big));
}

test "residentTailSize takes the larger of bss_size and reloc_stream_len, 4-aligned" {
    try std.testing.expectEqual(@as(u32, 12), residentTailSize(4, 8, 1)); // bss dominates: 4+8=12, already aligned
    try std.testing.expectEqual(@as(u32, 16), residentTailSize(4, 2, 10)); // reloc dominates: 4+10=14 -> 16
    try std.testing.expectEqual(@as(u32, 8), residentTailSize(5, 0, 0)); // neither: 5+0=5 -> 8
}

test "overlapAllocatedSize picks the largest of the three lower bounds" {
    // resident_tail_size dominates: on_disk=8+8=16, overlap_min=4+8=12, resident=1000
    try std.testing.expectEqual(@as(u32, 1000), overlapAllocatedSize(8, 8, 4, 1000));
    // overlap margin dominates: on_disk=8+8=16, resident=32, overlap_min=500+8=508 (already aligned)
    try std.testing.expectEqual(@as(u32, 508), overlapAllocatedSize(8, 8, 500, 32));
    // on-disk fit (trampoline_size) dominates: on_disk=100+8=108, overlap_min=4+8=12, resident=32
    try std.testing.expectEqual(@as(u32, 108), overlapAllocatedSize(100, 8, 4, 32));
    // compressed_size's own alignment padding pushes on_disk/overlap_min past resident:
    // align4(50)=52, on_disk=4+52=56, overlap_min=4+52=56, resident=10 -> 56
    try std.testing.expectEqual(@as(u32, 56), overlapAllocatedSize(4, 50, 4, 10));
}

test "overlapAllocatedSize keeps the payload offset a multiple of 4 for odd compressed_size" {
    // Regression test for a real 68000 Address Error found on real
    // hardware (git history): stubs/common/runtime.i's
    // OverlapPayloadOffset computes payload_offset =
    // allocated_size - align4(compressed_size) (never the raw value)
    // for exactly this reason - an allocated_size that's always a
    // multiple of 4 would otherwise leave payload_offset ODD whenever
    // compressed_size itself is odd, fatal the first time a backend's
    // Depack does a word/long access via A0 (store's own bulk
    // `move.l (a0)+,(a1)+` copy loop, e.g.). Mirror that same
    // computation here, not `allocated_size - compressed_size`.
    inline for (.{ 1, 3, 5, 216111 }) |odd_compressed_size| {
        const allocated_size = overlapAllocatedSize(20, odd_compressed_size, 4, 8);
        const compressed_size_aligned = std.mem.alignForward(u32, odd_compressed_size, 4);
        const payload_offset = allocated_size - compressed_size_aligned;
        try std.testing.expectEqual(@as(u32, 0), payload_offset % 4);
    }
}

test "buildOverlapHunk0Body places the payload right after the trampoline, no padding" {
    const trampoline = "TR"; // 2 bytes, arbitrary - real content is stubs/common/trampoline.s
    const payload = "PAYLOAD"; // 7 bytes, arbitrary
    const body = try buildOverlapHunk0Body(std.testing.allocator, trampoline, payload);
    defer std.testing.allocator.free(body);

    // On-disk body is exactly trampoline.len + payload.len - no padding
    // out to the eventual (much larger, margin-driven) allocated size:
    // OverlapMovePayload (stubs/common/runtime.i) relocates the payload
    // to its safe tail position at runtime instead.
    try std.testing.expectEqual(@as(usize, 9), body.len);
    try std.testing.expectEqualSlices(u8, trampoline, body[0..2]);
    try std.testing.expectEqualSlices(u8, payload, body[2..9]);
}

test "overlap layout round-trips through hunk.zig as two hunks, payload right after the trampoline in hunk 0" {
    const trampoline = "tramp!!"; // 7 bytes, arbitrary - real content is stubs/common/trampoline.s
    const payload = "COMPRESSEDPAYLOAD!!"; // 19 bytes, arbitrary
    const hunk0_body = try buildOverlapHunk0Body(std.testing.allocator, trampoline, payload);
    defer std.testing.allocator.free(hunk0_body);
    const hunk1_body = "STUB+HEADER, NO PAYLOAD THIS TIME"; // stands in for buildContainer's own overlap-mode output (stub_bytes ++ header only)
    // Declared allocated size is much larger than the on-disk body -
    // this is the whole point: the gap (where OverlapMovePayload will
    // relocate the payload to at runtime) is never materialized on disk.
    const allocated_size: u32 = std.mem.alignForward(u32, @intCast(hunk0_body.len), 4) + 200;

    const exe_bytes = try writeHunkExecutable(std.testing.allocator, hunk0_body, hunk1_body, allocated_size, false);
    defer std.testing.allocator.free(exe_bytes);

    var file = try hunk.parse(std.testing.allocator, exe_bytes);
    defer file.deinit();

    try std.testing.expectEqual(@as(usize, 2), file.hunks.len);
    try std.testing.expectEqual(hunk.HunkKind.code, file.hunks[0].kind);
    try std.testing.expectEqual(hunk.MemAttr.any, file.hunks[0].mem_attr);
    // Hunk 0's real on-disk body is trampoline ++ payload only - smaller
    // than the declared allocated_size, same "declared bigger than real
    // body" pattern the disjoint layout's own hunk 0 already uses.
    try std.testing.expectEqualSlices(u8, trampoline, file.hunks[0].data[0..trampoline.len]);
    try std.testing.expectEqualSlices(u8, payload, file.hunks[0].data[trampoline.len..][0..payload.len]);
    // On-disk data length is trampoline+payload rounded up to a
    // longword (hunk sizes are always a whole number of longwords) -
    // nowhere near the much larger declared allocated_size.
    try std.testing.expectEqual(std.mem.alignForward(usize, trampoline.len + payload.len, 4), file.hunks[0].data.len);

    try std.testing.expectEqual(hunk.HunkKind.code, file.hunks[1].kind);
    try std.testing.expectEqual(hunk.MemAttr.any, file.hunks[1].mem_attr);
    // Hunk 1 carries just the stub+header - no payload appended, unlike
    // the disjoint layout's own hunk 1.
    try std.testing.expectEqualSlices(u8, hunk1_body, file.hunks[1].data[0..hunk1_body.len]);
}
