const std = @import("std");

/// One 68000 depacker stub, assembled by vasm from `stubs/<name>/<source>`
/// into a raw binary and embedded into the host tool. Real backends
/// (inflate, zx0, shrinkler) register themselves here as they land in
/// their milestones; `example` is the M0 placeholder proving the pipeline.
const Stub = struct {
    name: []const u8,
    source: []const u8,
    /// Passed to vasm as `-I<dir>` when the stub `include`s shared code
    /// (stubs/common/) - see stubs/store/stub.s.
    include_dir: ?[]const u8 = null,
    /// vasm's syntax module is chosen per invocation and can't be mixed
    /// within one assembly. Everything is Motorola/Devpac syntax
    /// (vasmm68k_mot) except the inflate stub, which needs vasm's
    /// GNU-as-style module to assemble the vendored inflate.S it
    /// includes - see stubs/inflate/README.md.
    syntax: enum { mot, std } = .mot,
};

const stubs = [_]Stub{
    .{ .name = "stub_example", .source = "stubs/example/hello.s" },
    .{ .name = "stub_store", .source = "stubs/store/stub.s", .include_dir = "stubs/common" },
    .{ .name = "stub_inflate", .source = "stubs/inflate/stub.s", .include_dir = "stubs/inflate", .syntax = .std },
    .{ .name = "stub_zx0", .source = "stubs/zx0/stub.s", .include_dir = "stubs/common" },
    .{ .name = "stub_shrinkler", .source = "stubs/shrinkler/stub.s", .include_dir = "stubs/common" },
};

/// A real hunk executable built at test time (vasm assembles to a linkable
/// object, vlink links it into an AmigaDOS load file) and embedded for
/// src/hunk.zig's unit tests, so the parser is checked against real,
/// independently-produced bytes rather than a hand-rolled fixture that
/// might share the parser's own assumptions.
const Fixture = struct {
    name: []const u8,
    source: []const u8,
};

const fixtures = [_]Fixture{
    .{ .name = "fixture_basic", .source = "tests/fixtures/basic.s" },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const vasm = b.option(
        []const u8,
        "vasm",
        "Path to the vasmm68k_mot binary used to assemble 68k stubs",
    ) orelse "vasmm68k_mot";
    const vasm_std = b.option(
        []const u8,
        "vasm-std",
        "Path to the vasmm68k_std binary, needed only for the inflate stub (see stubs/inflate/README.md)",
    ) orelse "vasmm68k_std";
    const vlink = b.option(
        []const u8,
        "vlink",
        "Path to the vlink binary used to link test-fixture executables",
    ) orelse "vlink";

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{ .name = "execram", .root_module = exe_module });

    // A *separate* module for the test binary, sharing the same root
    // source file but not the same Module object as `exe` - so
    // test-only anonymous imports (the vlink-dependent fixtures below)
    // never leak into the plain `zig build`/`zig build run` path. They
    // did, briefly: reusing exe.root_module for exe_tests meant
    // `zig build` (no test target at all) started requiring vlink too.
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe_tests = b.addTest(.{ .root_module = test_module });

    // The zx0 and zultra backends' host-side compressors are vendored C
    // (docs/LICENSES.md #2, #6), not reimplemented - needed by both
    // modules, same as the stubs above.
    for ([_]*std.Build.Module{ exe_module, test_module }) |mod| {
        mod.link_libc = true;
        mod.addIncludePath(b.path("src/backends/zx0_vendor"));
        mod.addCSourceFiles(.{
            .root = b.path("src/backends/zx0_vendor"),
            .files = &.{ "compress.c", "memory.c", "optimize.c", "shim.c" },
            .flags = &.{"-std=c99"},
        });

        mod.addIncludePath(b.path("src/backends/zultra_vendor"));
        mod.addCSourceFiles(.{
            .root = b.path("src/backends/zultra_vendor"),
            .files = &.{
                "blockdeflate.c",
                "dictionary.c",
                "frame.c",
                "libzultra.c",
                "matchfinder.c",
                "huffman/bitwriter.c",
                "huffman/huffencoder.c",
                "huffman/huffutils.c",
                "libdivsufsort/lib/divsufsort.c",
                "libdivsufsort/lib/divsufsort_utils.c",
                "libdivsufsort/lib/sssort.c",
                "libdivsufsort/lib/trsort.c",
            },
            .flags = &.{"-std=c99"},
        });

        // salvador_vendor's own files use a bare `#include
        // "divsufsort.h"` (unlike zultra_vendor's, which reference it
        // via a path relative to zultra_vendor's own root) - needs an
        // explicit include path straight to libdivsufsort/include, not
        // just the vendor root, matching upstream's own Makefile flags
        // (see src/backends/salvador_vendor/README.md).
        mod.addIncludePath(b.path("src/backends/salvador_vendor"));
        mod.addIncludePath(b.path("src/backends/salvador_vendor/libdivsufsort/include"));
        mod.addCSourceFiles(.{
            .root = b.path("src/backends/salvador_vendor"),
            .files = &.{
                "matchfinder.c",
                "shrink.c",
                "expand.c",
                "salvador_shim.c",
                "libdivsufsort/lib/divsufsort.c",
                "libdivsufsort/lib/divsufsort_utils.c",
                "libdivsufsort/lib/sssort.c",
                "libdivsufsort/lib/trsort.c",
            },
            // zultra_vendor above vendors a *different* fork of the same
            // upstream libdivsufsort (see
            // src/backends/salvador_vendor/README.md) - both define the
            // same 12 global, non-static symbols (confirmed by direct
            // inspection of both trees, not just the first 5 the linker
            // happened to report), so linking both unmodified into one
            // binary is a hard duplicate-symbol collision. Renamed only
            // salvador's copy via -D, the same preprocessor-rename idiom
            // divsufsort_private.h already uses itself for a 64-bit
            // variant (`#define sssort sssort64`) - no source edits
            // needed, and salvador's own internal callers/declarations
            // (divsufsort_private.h's extern prototypes, matchfinder.c's
            // calls) pick up the rename automatically since they use the
            // same macro-expanded names.
            .flags = &.{
                "-std=c99",
                "-Ddivsufsort_init=salvador_divsufsort_init",
                "-Ddivsufsort_destroy=salvador_divsufsort_destroy",
                "-Ddivsufsort_build_array=salvador_divsufsort_build_array",
                "-Ddivbwt=salvador_divbwt",
                "-Ddivsufsort_version=salvador_divsufsort_version",
                "-Dbw_transform=salvador_bw_transform",
                "-Dinverse_bw_transform=salvador_inverse_bw_transform",
                "-Dsufcheck=salvador_sufcheck",
                "-Dsa_search=salvador_sa_search",
                "-Dsa_simplesearch=salvador_sa_simplesearch",
                "-Dsssort=salvador_sssort",
                "-Dtrsort=salvador_trsort",
            },
        });

        // The shrinkler backend's host-side compressor is vendored C++
        // (docs/LICENSES.md #1), not C like the others - Shrinkler's
        // own LZ optimal parser/range coder (src/backends/shrinkler_vendor/README.md).
        // Needs link_libcpp (not just link_libc) for the C++ standard
        // library (<vector>, <algorithm>, ...) the vendored headers use.
        mod.link_libcpp = true;
        // Needed for @cImport's @cInclude("shrinkler_shim.h") to find
        // it (no "including file's own directory" preference the way
        // a real C #include has - see salvador_shim.h's own comment).
        // Safe to put on the module's *global* include path, unlike a
        // first attempt at this: that one also carried this
        // directory's own `assert.h`, which deliberately shadows the
        // *system* assert.h (upstream's own single-translation-unit
        // design) and so also shadowed it for every other vendor's
        // unrelated `#include <assert.h>` once this directory was
        // globally visible - see shrinkler_assert.h's own comment for
        // the rename that fixed this.
        mod.addIncludePath(b.path("src/backends/shrinkler_vendor"));
        mod.addCSourceFiles(.{
            .root = b.path("src/backends/shrinkler_vendor"),
            .files = &.{"shrinkler_shim.cpp"},
            // -fno-sanitize=shift: RangeCoder.h's `dest_bit` starts at
            // -1 and gets left-shifted on the very first code() call
            // (`dest_bit << BIT_PRECISION`) - implementation-defined
            // (not undefined - the C++ standard just doesn't mandate
            // two's-complement) but universally consistent on every
            // real compiler/architecture, and upstream's own shipped
            // behavior for 20+ years. Zig's Debug builds add UBSan
            // shift-trapping to vendored C/C++ too, which crashes on
            // this - not a bug in the vendored math (verified: the
            // subsequent round-trip test we run passes once this trap
            // is disabled), so this is suppressed rather than editing
            // vendored numeric code to dodge a sanitizer upstream never
            // built against.
            .flags = &.{ "-std=c++11", "-fno-sanitize=shift" },
        });
    }

    for (stubs) |stub| {
        const assemble = b.addSystemCommand(&.{
            switch (stub.syntax) {
                .mot => vasm,
                .std => vasm_std,
            },
            "-Fbin", // raw binary output, no hunk/object wrapper
            "-no-opt", // no branch/addressing-mode relaxation: keep stub timing predictable
            "-quiet",
        });
        if (stub.include_dir) |dir| {
            assemble.addArg(b.fmt("-I{s}", .{dir}));
        }
        assemble.addFileArg(b.path(stub.source));
        assemble.addArg("-o");
        const bin = assemble.addOutputFileArg(b.fmt("{s}.bin", .{stub.name}));

        // Makes `@embedFile(stub.name)` resolve to the assembled binary's
        // bytes. Needed by both modules: main.zig's non-test code embeds
        // it unconditionally, not just from within a test block.
        exe_module.addAnonymousImport(stub.name, .{ .root_source_file = bin });
        test_module.addAnonymousImport(stub.name, .{ .root_source_file = bin });
    }

    for (fixtures) |fixture| {
        const assemble = b.addSystemCommand(&.{
            vasm,
            "-Fhunk", // linkable object, not raw binary - vlink needs this
            "-no-opt",
            "-quiet",
        });
        assemble.addFileArg(b.path(fixture.source));
        assemble.addArg("-o");
        const obj = assemble.addOutputFileArg(b.fmt("{s}.o", .{fixture.name}));

        const link = b.addSystemCommand(&.{ vlink, "-bamigahunk" });
        link.addArg("-o");
        const linked = link.addOutputFileArg(b.fmt("{s}.exe", .{fixture.name}));
        link.addFileArg(obj);

        // Test-only: makes `@embedFile(fixture.name)` resolve to the
        // linked executable's bytes inside src/hunk.zig's tests.
        test_module.addAnonymousImport(fixture.name, .{
            .root_source_file = linked,
        });
    }

    b.installArtifact(exe);

    const run_step = b.step("run", "Run execram");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_tests.step);
}
