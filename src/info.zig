//! `execram info` (M5 - PROJECT_PLAN.md): inspects an execram-packed
//! executable and reports its container header fields, without needing
//! to decompress anything.
//!
//! Locating the header reliably (docs/format-spec.md §3's container is
//! `stub_bytes ++ header ++ payload`, and we don't otherwise know
//! `stub_bytes.len` for a file we didn't just produce ourselves)
//! matches each of the caller-supplied known stub byte arrays as a
//! literal prefix, rather than scanning for the "ExCr" magic directly -
//! `tests/uae/e2e/extract_container.py`'s own doc comment explains why
//! that's a real trap, not a theoretical one: an earlier version of
//! that script did exactly this and "passed" only by accident, because
//! it found the magic's own 4-byte encoding inside the stub's
//! `cmp.l #MAGIC,...` instruction instead of the real header.

const std = @import("std");
const Io = std.Io;
const hunk = @import("hunk.zig");

pub const KnownStub = struct {
    /// A short, human-readable name for the depacker this stub
    /// implements - not necessarily the same as any one `--backend`
    /// name, since more than one host-side compressor can share a stub
    /// (docs/format-spec.md §4's backend_id registry) and `info` can't
    /// tell which one produced a given file, only which stub decodes
    /// it.
    stub_name: []const u8,
    bytes: []const u8,
};

const FLAG_MEM_CHIP: u8 = 1;
const FLAG_HAS_RELOCS: u8 = 2;
const FLAG_FLASH: u8 = 4;
const MAGIC: u32 = 0x45784372; // "ExCr"
const HEADER_SIZE: usize = 32;

pub const InfoError = error{
    NotATwoHunkCodeFile,
    UnrecognizedStub,
    TruncatedHeader,
    BadMagic,
} || hunk.ParseError || Io.Writer.Error;

/// Every field of docs/format-spec.md §3's header, plus where it and the
/// matched stub actually sit within `container_data` - split out of
/// `printInfo` so a second caller (tools/bench, which needs the raw
/// field values and byte offsets, not a formatted report) can reuse the
/// exact same "locate the header reliably" logic rather than
/// re-deriving it and risking the two drifting apart.
pub const Header = struct {
    stub: KnownStub,
    /// == stub.bytes.len: where the header starts within container_data.
    header_offset: usize,
    version_major: u8,
    version_minor: u8,
    backend_id: u8,
    flags: u8,
    header_size: u16,
    code_data_size: u32,
    bss_size: u32,
    reloc_stream_size: u32,
    compressed_size: u32,
    safety_margin: u32,

    pub fn memChip(self: Header) bool {
        return self.flags & FLAG_MEM_CHIP != 0;
    }
    pub fn hasRelocs(self: Header) bool {
        return self.flags & FLAG_HAS_RELOCS != 0;
    }
    pub fn hasFlash(self: Header) bool {
        return self.flags & FLAG_FLASH != 0;
    }
    /// Bytes a backend's decompressor must produce from `compressed_size`
    /// bytes of payload (docs/format-spec.md §6: code+data, then the
    /// reloc stream, back to back).
    pub fn uncompressedSize(self: Header) u32 {
        return self.code_data_size + self.reloc_stream_size;
    }
    pub fn residentSize(self: Header) u32 {
        return self.code_data_size + self.bss_size;
    }
    /// Where the compressed payload starts within `container_data`.
    pub fn payloadOffset(self: Header) usize {
        return self.header_offset + self.header_size;
    }
};

/// Matches `container_data`'s leading bytes against each of
/// `known_stubs` (see that type's doc comment on why a literal prefix
/// match, not a magic-byte scan) and parses the header immediately
/// following the match.
pub fn locateHeader(container_data: []const u8, known_stubs: []const KnownStub) !Header {
    const stub = for (known_stubs) |candidate| {
        if (container_data.len >= candidate.bytes.len and
            std.mem.eql(u8, container_data[0..candidate.bytes.len], candidate.bytes))
        {
            break candidate;
        }
    } else return error.UnrecognizedStub;

    if (container_data.len < stub.bytes.len + HEADER_SIZE) return error.TruncatedHeader;
    const h = container_data[stub.bytes.len..][0..HEADER_SIZE];

    const magic = std.mem.readInt(u32, h[0..4], .big);
    if (magic != MAGIC) return error.BadMagic;

    return .{
        .stub = stub,
        .header_offset = stub.bytes.len,
        .version_major = h[4],
        .version_minor = h[5],
        .backend_id = h[6],
        .flags = h[7],
        .header_size = std.mem.readInt(u16, h[8..10], .big),
        .code_data_size = std.mem.readInt(u32, h[12..16], .big),
        .bss_size = std.mem.readInt(u32, h[16..20], .big),
        .reloc_stream_size = std.mem.readInt(u32, h[20..24], .big),
        .compressed_size = std.mem.readInt(u32, h[24..28], .big),
        .safety_margin = std.mem.readInt(u32, h[28..32], .big),
    };
}

/// Parses `exe_bytes` (a whole file's contents) and writes a
/// human-readable report to `w`. `known_stubs` should be every stub
/// this build of execram knows how to produce (main.zig's embedded
/// stub_* constants) - matched longest-first isn't needed since real
/// stubs never happen to be prefixes of one another, but each is still
/// checked structurally (a byte-for-byte prefix match), not guessed.
pub fn printInfo(
    allocator: std.mem.Allocator,
    w: *Io.Writer,
    exe_bytes: []const u8,
    known_stubs: []const KnownStub,
) !void {
    var file = try hunk.parse(allocator, exe_bytes);
    defer file.deinit();

    // docs/format-spec.md §2 / docs/memory-lifecycle.md: hunk 0 is the
    // trampoline (declared at the full resident size, tiny real body -
    // nothing `info` needs to read there), hunk 1 holds the actual
    // stub+header+payload container this function reports on.
    if (file.hunks.len != 2 or file.hunks[0].kind != .code or file.hunks[1].kind != .code) {
        return error.NotATwoHunkCodeFile;
    }
    const container_data = file.hunks[1].data;
    const header = try locateHeader(container_data, known_stubs);

    const mem_chip = header.memChip();
    const has_relocs = header.hasRelocs();
    const has_flash = header.hasFlash();
    const uncompressed_size = header.uncompressedSize();
    const resident_size = header.residentSize();

    try w.print("execram container (v{d}.{d}, stub \"{s}\", {d} bytes)\n", .{
        header.version_major, header.version_minor, header.stub.stub_name, header.stub.bytes.len,
    });
    try w.print("  backend_id:          {d} ({s})\n", .{ header.backend_id, backendIdName(header.backend_id) });
    try w.print("  memory:              {s}\n", .{if (mem_chip) "chip" else "any/fast"});
    try w.print("  relocations:         {s}\n", .{if (has_relocs) "yes" else "none"});
    try w.print("  border flash:        {s}\n", .{if (has_flash) "yes" else "no"});
    try w.print("  header size:         {d} bytes\n", .{header.header_size});
    try w.print("  code+data size:      {d} bytes\n", .{header.code_data_size});
    try w.print("  bss size:            {d} bytes\n", .{header.bss_size});
    try w.print("  reloc stream size:   {d} bytes\n", .{header.reloc_stream_size});
    try w.print("  compressed size:     {d} bytes\n", .{header.compressed_size});
    try w.print("  safety margin:       {d} bytes\n", .{header.safety_margin});
    try w.print("  resident at runtime: {d} bytes (code+data+bss)\n", .{resident_size});
    if (uncompressed_size > 0) {
        const ratio = @as(f64, @floatFromInt(header.compressed_size)) / @as(f64, @floatFromInt(uncompressed_size)) * 100.0;
        try w.print("  payload ratio:       {d:.1}% ({d} -> {d} bytes)\n", .{ ratio, uncompressed_size, header.compressed_size });
    }
    try w.print("  packed file size:    {d} bytes\n", .{exe_bytes.len});
}

fn backendIdName(id: u8) []const u8 {
    return switch (id) {
        0 => "store",
        1 => "inflate-compatible (inflate, zultra, libdeflate, or zopfli)",
        2 => "zx0-compatible (zx0 or salvador)",
        3 => "shrinkler",
        4 => "lz4 (smallest depacker, 72 bytes)",
        5 => "lz4 (normal depacker, 180 bytes)",
        6 => "lz4 (fastest depacker, 3722 bytes)",
        else => "unknown",
    };
}

const flatten = @import("flatten.zig");
const container = @import("container.zig");

test "printInfo reports a real container's fields" {
    const allocator = std.testing.allocator;

    var image = flatten.FlatImage{
        .allocator = allocator,
        .code_data = try allocator.dupe(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }),
        .bss_size = 100,
        .reloc_stream = try allocator.dupe(u8, &.{ 0x04, 0xFE }), // one site, then terminator
        .mem_chip = true,
    };
    defer image.deinit();

    const stub = "FAKESTUB"; // 8 bytes, arbitrary - not a real assembled stub
    const payload = "COMPRESSEDPAYLOAD!!"; // 19 bytes, arbitrary
    const container_bytes = try container.buildContainer(allocator, image, .zx0, stub, payload, false);
    defer allocator.free(container_bytes);
    const resident_size = @as(u32, @intCast(image.code_data.len)) + image.bss_size;
    const exe_bytes = try container.writeHunkExecutable(allocator, "FAKETRAMPOLINE!!", container_bytes, resident_size, image.mem_chip);
    defer allocator.free(exe_bytes);

    const known_stubs = [_]KnownStub{.{ .stub_name = "fake", .bytes = stub }};

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try printInfo(allocator, &out.writer, exe_bytes, &known_stubs);

    const report = out.written();
    try std.testing.expect(std.mem.indexOf(u8, report, "stub \"fake\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "backend_id:          2 (zx0-compatible (zx0 or salvador))") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "memory:              chip") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "relocations:         yes") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "border flash:        no") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "code+data size:      8 bytes") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "bss size:            100 bytes") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "reloc stream size:   2 bytes") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "compressed size:     19 bytes") != null);
}

test "printInfo rejects a file with no recognized stub" {
    const allocator = std.testing.allocator;
    const exe_bytes = try container.writeHunkExecutable(allocator, "FAKETRAMPOLINE!!", "not a real container at all", 32, false);
    defer allocator.free(exe_bytes);

    const known_stubs = [_]KnownStub{.{ .stub_name = "fake", .bytes = "FAKESTUB" }};

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.testing.expectError(error.UnrecognizedStub, printInfo(allocator, &out.writer, exe_bytes, &known_stubs));
}
