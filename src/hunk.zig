//! Parser for AmigaDOS hunk executables ("load files" - already linked,
//! ready to run; not linkable object files, which have a different
//! leading HUNK_UNIT/HUNK_NAME structure that vlink consumes but we
//! never see here).
//!
//! Byte layout verified by hand against a real vlink-linked test fixture
//! (see tests/fixtures/basic.s and the fixture_basic test below) and
//! against http://amiga-dev.wikidot.com/file-format:hunk. All multi-byte
//! fields are big-endian 32-bit words ("longwords" in Amiga terminology).
//!
//! Scope (see PROJECT_PLAN.md M1 and the non-goals in §2): plain,
//! non-overlay executables built from CODE/DATA/BSS hunks with 32-bit
//! (HUNK_RELOC32) relocations. HUNK_OVERLAY and friends, resident-library
//! headers with actual names, and 16-bit reloc variants are explicitly
//! out of scope for v0 and rejected with a clear error rather than
//! silently mishandled.

const std = @import("std");

const HUNK_UNIT: u32 = 0x3E7;
const HUNK_NAME: u32 = 0x3E8;
const HUNK_CODE: u32 = 0x3E9;
const HUNK_DATA: u32 = 0x3EA;
const HUNK_BSS: u32 = 0x3EB;
const HUNK_RELOC32: u32 = 0x3EC;
const HUNK_RELOC16: u32 = 0x3ED;
const HUNK_RELOC8: u32 = 0x3EE;
const HUNK_EXT: u32 = 0x3EF;
const HUNK_SYMBOL: u32 = 0x3F0;
const HUNK_DEBUG: u32 = 0x3F1;
const HUNK_END: u32 = 0x3F2;
const HUNK_HEADER: u32 = 0x3F3;
const HUNK_OVERLAY: u32 = 0x3F5;
const HUNK_BREAK: u32 = 0x3F6;
const HUNK_LIB: u32 = 0x3FA;
const HUNK_INDEX: u32 = 0x3FB;
const HUNK_RELOC32SHORT: u32 = 0x3FC;

/// Hunk type longwords may carry advisory bits above the type value
/// itself; every documented type constant fits in the low 30 bits.
const TYPE_MASK: u32 = 0x3FFFFFFF;

pub const MemAttr = enum(u2) {
    any = 0,
    chip = 1,
    fast = 2,
    extended = 3,
};

pub const HunkKind = enum { code, data, bss };

pub const Reloc = struct {
    /// Index into HunkFile.hunks of the hunk whose runtime base address
    /// gets added at `offset`.
    target_hunk: u32,
    /// Byte offset within this hunk's data of the 32-bit value to patch.
    offset: u32,
};

pub const Hunk = struct {
    kind: HunkKind,
    mem_attr: MemAttr,
    /// Borrowed from the input buffer passed to `parse` - empty for BSS.
    /// Callers must keep that buffer alive as long as this Hunk is used.
    data: []const u8,
    /// For BSS, the zero-fill length (data.len is 0). For code/data,
    /// always equal to data.len - kept as a separate field so all three
    /// kinds read the same way. This is the hunk's own *restated* size
    /// (right after its own HUNK_CODE/DATA/BSS marker in the file), not
    /// necessarily the master hunk-size table's declared/allocated size
    /// for it - the two may legally differ (this one no bigger than the
    /// table's), which `parse` permits but does not expose further; no
    /// current caller needs the table's own value.
    size_bytes: u32,
    /// Owned; freed by HunkFile.deinit.
    relocs: []Reloc,
};

pub const HunkFile = struct {
    allocator: std.mem.Allocator,
    hunks: []Hunk,

    pub fn deinit(self: *HunkFile) void {
        for (self.hunks) |hunk| self.allocator.free(hunk.relocs);
        self.allocator.free(self.hunks);
        self.* = undefined;
    }
};

pub const ParseError = error{
    Truncated,
    NotAHunkFile,
    UnsupportedExtendedMemFlags,
    UnsupportedHunkTableRange,
    UnsupportedOverlay,
    UnsupportedHunkType,
    MalformedHunk,
} || std.mem.Allocator.Error;

const Cursor = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn u32be(self: *Cursor) ParseError!u32 {
        if (self.pos + 4 > self.bytes.len) return error.Truncated;
        const v = std.mem.readInt(u32, self.bytes[self.pos..][0..4], .big);
        self.pos += 4;
        return v;
    }

    fn take(self: *Cursor, n: usize) ParseError![]const u8 {
        if (self.pos + n > self.bytes.len) return error.Truncated;
        const s = self.bytes[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }
};

/// Parses `bytes` as an AmigaDOS hunk load file. Borrows `bytes` for the
/// lifetime of the returned HunkFile (code/data hunks reference it
/// directly, no copy) - the caller must keep it alive until done.
pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) ParseError!HunkFile {
    var c = Cursor{ .bytes = bytes };

    if ((try c.u32be()) != HUNK_HEADER) return error.NotAHunkFile;

    // Resident-library name list: a sequence of (length_in_longwords,
    // name bytes) pairs, terminated by a zero length. Real programs
    // (not resident-module headers) have an empty list here - we just
    // skip past whatever's there since we don't use these names.
    while (true) {
        const name_longs = try c.u32be();
        if (name_longs == 0) break;
        _ = try c.take(@as(usize, name_longs) * 4);
    }

    const table_size = try c.u32be();
    const first_hunk = try c.u32be();
    const last_hunk = try c.u32be();
    if (first_hunk != 0 or (table_size > 0 and last_hunk != table_size - 1)) {
        // A genuine subset load range only happens for overlay segments;
        // treat it the same as an explicit HUNK_OVERLAY (see below).
        return error.UnsupportedOverlay;
    }

    const mem_attrs = try allocator.alloc(MemAttr, table_size);
    defer allocator.free(mem_attrs);
    const planned_sizes = try allocator.alloc(u32, table_size);
    defer allocator.free(planned_sizes);

    for (0..table_size) |i| {
        const size_word = try c.u32be();
        const attr_bits: u2 = @intCast(size_word >> 30);
        const attr: MemAttr = @enumFromInt(attr_bits);
        if (attr == .extended) return error.UnsupportedExtendedMemFlags;
        mem_attrs[i] = attr;
        planned_sizes[i] = (size_word & 0x3FFFFFFF) * 4;
    }

    var hunks = try std.ArrayList(Hunk).initCapacity(allocator, table_size);
    errdefer {
        for (hunks.items) |hunk| allocator.free(hunk.relocs);
        hunks.deinit(allocator);
    }

    for (0..table_size) |i| {
        const raw_type = (try c.u32be()) & TYPE_MASK;
        const kind: HunkKind = switch (raw_type) {
            HUNK_CODE => .code,
            HUNK_DATA => .data,
            HUNK_BSS => .bss,
            HUNK_OVERLAY => return error.UnsupportedOverlay,
            HUNK_LIB, HUNK_INDEX => return error.UnsupportedOverlay,
            else => return error.UnsupportedHunkType,
        };

        const length_longs = try c.u32be();
        const size_bytes = length_longs * 4;
        // A hunk's own restated size (here) may be smaller than the
        // master table's declared/allocated size (`planned_sizes[i]`,
        // checked above) - LoadSeg allocates the table's amount but only
        // reads this many real bytes from the file into the start of
        // it, leaving the rest uninitialized. Confirmed real, legal
        // AmigaDOS behavior (not just tolerated, actively relied on by
        // e.g. Shrinkler's own crunched output) via a real FS-UAE
        // experiment across three Kickstart versions - see the commit
        // that introduced execram's own two-hunk container
        // (docs/memory-lifecycle.md) for the probe and raw results. It
        // may never be *larger* - that would mean the file's body
        // overruns what was actually allocated for it.
        if (size_bytes > planned_sizes[i]) return error.MalformedHunk;

        const data: []const u8 = if (kind == .bss) &.{} else try c.take(size_bytes);

        var relocs: std.ArrayList(Reloc) = .empty;
        errdefer relocs.deinit(allocator);

        trailer: while (true) {
            const t = (try c.u32be()) & TYPE_MASK;
            switch (t) {
                HUNK_RELOC32 => try readReloc32Block(&c, allocator, &relocs),
                HUNK_SYMBOL => try skipSymbolTable(&c),
                HUNK_DEBUG => try skipLengthPrefixed(&c),
                HUNK_END => break :trailer,
                HUNK_RELOC32SHORT, HUNK_RELOC16, HUNK_RELOC8 => return error.UnsupportedHunkType,
                else => return error.UnsupportedHunkType,
            }
        }

        hunks.appendAssumeCapacity(.{
            .kind = kind,
            .mem_attr = mem_attrs[i],
            .data = data,
            .size_bytes = size_bytes,
            .relocs = try relocs.toOwnedSlice(allocator),
        });
    }

    return .{ .allocator = allocator, .hunks = try hunks.toOwnedSlice(allocator) };
}

fn readReloc32Block(c: *Cursor, allocator: std.mem.Allocator, relocs: *std.ArrayList(Reloc)) ParseError!void {
    while (true) {
        const count = try c.u32be();
        if (count == 0) return;
        const target_hunk = try c.u32be();
        for (0..count) |_| {
            const offset = try c.u32be();
            try relocs.append(allocator, .{ .target_hunk = target_hunk, .offset = offset });
        }
    }
}

fn skipSymbolTable(c: *Cursor) ParseError!void {
    while (true) {
        const name_longs = try c.u32be();
        if (name_longs == 0) return;
        _ = try c.take(@as(usize, name_longs) * 4); // name
        _ = try c.u32be(); // value
    }
}

/// HUNK_DEBUG: a length-prefixed opaque blob we don't need the contents
/// of (line-number/symbolic debug info).
fn skipLengthPrefixed(c: *Cursor) ParseError!void {
    const length_longs = try c.u32be();
    _ = try c.take(@as(usize, length_longs) * 4);
}

test "parses a real vlink-linked executable" {
    const fixture_bytes = @embedFile("fixture_basic");
    var file = try parse(std.testing.allocator, fixture_bytes);
    defer file.deinit();

    try std.testing.expectEqual(@as(usize, 3), file.hunks.len);

    const code = file.hunks[0];
    const data = file.hunks[1];
    const bss = file.hunks[2];

    try std.testing.expectEqual(HunkKind.code, code.kind);
    try std.testing.expectEqual(HunkKind.data, data.kind);
    try std.testing.expectEqual(HunkKind.bss, bss.kind);

    try std.testing.expectEqual(@as(u32, 28), code.size_bytes);
    try std.testing.expectEqual(@as(u32, 8), data.size_bytes);
    try std.testing.expectEqual(@as(u32, 16), bss.size_bytes);
    try std.testing.expectEqual(@as(usize, 0), bss.data.len);

    // move.l dataptr,a1 at code+8 -> reloc onto hunk 1 (DATA)
    // move.l #bssvar,a2 at code+16 -> reloc onto hunk 2 (BSS)
    try std.testing.expectEqual(@as(usize, 2), code.relocs.len);
    try std.testing.expectEqual(@as(u32, 1), code.relocs[0].target_hunk);
    try std.testing.expectEqual(@as(u32, 8), code.relocs[0].offset);
    try std.testing.expectEqual(@as(u32, 2), code.relocs[1].target_hunk);
    try std.testing.expectEqual(@as(u32, 16), code.relocs[1].offset);

    // dataptr (offset 0 in DATA) holds the address of bssvar -> reloc onto hunk 2 (BSS)
    try std.testing.expectEqual(@as(usize, 1), data.relocs.len);
    try std.testing.expectEqual(@as(u32, 2), data.relocs[0].target_hunk);
    try std.testing.expectEqual(@as(u32, 0), data.relocs[0].offset);

    try std.testing.expectEqual(@as(usize, 0), bss.relocs.len);

    // someval (offset 4 in DATA) = 0x12345678, stored verbatim (not relocated)
    try std.testing.expectEqual(@as(u32, 0x12345678), std.mem.readInt(u32, data.data[4..8], .big));
}

test "rejects a non-hunk file" {
    const not_a_hunk = [_]u8{ 'n', 'o', 'p', 'e', 0, 0, 0, 0 };
    try std.testing.expectError(error.NotAHunkFile, parse(std.testing.allocator, &not_a_hunk));
}

test "rejects a truncated header" {
    var header_only: [4]u8 = undefined;
    std.mem.writeInt(u32, &header_only, HUNK_HEADER, .big);
    try std.testing.expectError(error.Truncated, parse(std.testing.allocator, &header_only));
}
