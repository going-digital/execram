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
    /// Every other file `source` (transitively) `include`s/`.include`s,
    /// listed explicitly so it can be registered as a cache input below -
    /// see `addIncludedFileInputs`'s doc comment for why this exists.
    extra_includes: []const []const u8 = &.{},
    /// vasm's syntax module is chosen per invocation and can't be mixed
    /// within one assembly. Everything is Motorola/Devpac syntax
    /// (vasmm68k_mot) except the inflate stub, which needs vasm's
    /// GNU-as-style module to assemble the vendored inflate.S it
    /// includes - see stubs/inflate/README.md.
    syntax: enum { mot, std } = .mot,
};

/// Registers `path` as a cache input on `run` via `addFileInput` (tracked
/// for invalidation, but not added to argv - these files reach vasm
/// through `-I`/relative `include`, not as direct arguments). Without
/// this, Zig's build cache only hashes the top-level `.source` file
/// passed via `addFileArg`; an edit to a shared file an `include`/
/// `.include` directive pulls in (stubs/common/runtime.i, stubs/inflate/
/// runtime_std.i, etc.) is invisible to the cache key, so `zig build`
/// silently keeps serving a stale assembled stub. Confirmed directly:
/// editing runtime_std.i alone did not change stub_inflate's cached
/// output until this was added.
fn addIncludedFileInputs(b: *std.Build, run: *std.Build.Step.Run, paths: []const []const u8) void {
    for (paths) |path| run.addFileInput(b.path(path));
}

const stubs = [_]Stub{
    .{ .name = "stub_example", .source = "stubs/example/hello.s" },
    // Hunk 0's own body for every backend alike (docs/memory-lifecycle.md's
    // "new default" - src/container.zig's writeHunkExecutable). No
    // `include`s of its own, so no include_dir/extra_includes needed.
    // The generated .lst listing goes unused (nothing needs
    // stub_trampoline's own Depack offset), harmless.
    .{ .name = "stub_trampoline", .source = "stubs/common/trampoline.s" },
    .{
        .name = "stub_store",
        .source = "stubs/store/stub.s",
        .include_dir = "stubs/common",
        .extra_includes = &.{ "stubs/common/runtime.i", "stubs/common/header.i" },
    },
    .{
        .name = "stub_inflate",
        .source = "stubs/inflate/stub.s",
        .include_dir = "stubs/inflate",
        .extra_includes = &.{ "stubs/inflate/runtime_std.i", "stubs/inflate/header_std.i", "stubs/inflate/inflate_core.s" },
        .syntax = .std,
    },
    .{
        .name = "stub_zx0",
        .source = "stubs/zx0/stub.s",
        .include_dir = "stubs/common",
        .extra_includes = &.{ "stubs/common/runtime.i", "stubs/common/header.i", "stubs/zx0/unzx0_68000.s" },
    },
    .{
        .name = "stub_shrinkler",
        .source = "stubs/shrinkler/stub.s",
        .include_dir = "stubs/common",
        .extra_includes = &.{ "stubs/common/runtime.i", "stubs/common/header.i", "stubs/shrinkler/ShrinklerDecompress.s" },
    },
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

    // Makes `@import("build_zon").version` resolve to build.zig.zon's own
    // `.version` field in main.zig - a single source of truth for the
    // version string `execram --version` prints, instead of hand-syncing
    // a separate constant on every release.
    exe_module.addAnonymousImport("build_zon", .{ .root_source_file = b.path("build.zig.zon") });

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
    // main.zig's top-level `@import("build_zon")` needs this registered
    // on *every* module compiling that file, test_module included, or
    // the import fails to resolve there even though tests never call
    // the version-printing code that actually uses it.
    test_module.addAnonymousImport("build_zon", .{ .root_source_file = b.path("build.zig.zon") });
    const exe_tests = b.addTest(.{ .root_module = test_module });

    // tools/bench (src/musashi_vendor/README.md, tools/bench/README.md):
    // a dev-only cycle-timing tool sharing its Musashi-driving core
    // (src/musashi_bench.zig) with the shipped `execram bench` command
    // (src/main.zig) - see that file's own module doc for why the split
    // exists. Always native/host target and its own module, so nothing
    // here ever affects `zig build`'s cross-compiled output for
    // `execram` itself.
    const bench_module = b.createModule(.{
        .root_source_file = b.path("tools/bench/main.zig"),
        .target = b.graph.host,
        // A dev tool, not a release artifact - always build it fast
        // rather than tracking the main build's -Doptimize, since a
        // full real-executable depack under single-instruction-stepped
        // emulation (the only overshoot-free way to get an exact cycle
        // count - see tools/bench/README.md) runs many times slower in
        // a Debug-mode interpreter than a ReleaseFast one.
        .optimize = .ReleaseFast,
    });

    // tools/bench needs execram's own container-header parsing and
    // every backend's host-side `decompress` (to cross-check the
    // emulated depack's output, the same way main.zig's pack-time
    // self-check does), but Zig won't let tools/bench/main.zig
    // `@import` src/*.zig files directly: a module's relative imports
    // can't resolve outside its own root directory (tools/bench/'s, in
    // this case) - tried, and failed with "import of file outside
    // module path". src/lib.zig is a small facade rooted *inside*
    // src/ purely so those imports become in-tree relative ones again;
    // see that file's own doc comment. This is its own module (not
    // just added onto bench_module) specifically so it can join the
    // vendor-linking loop just below and get store/inflate/zx0/
    // shrinkler's C dependencies compiled into *this* module, the one
    // that actually contains those files this time.
    const lib_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseFast,
    });
    bench_module.addImport("execram_lib", lib_module);

    // The zx0 and zultra backends' host-side compressors are vendored C
    // (docs/LICENSES.md #2, #6), not reimplemented - needed by every
    // module that runs a backend's own `decompress`, same as the stubs
    // above.
    for ([_]*std.Build.Module{ exe_module, test_module, lib_module }) |mod| {
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
            // -D_POSIX_C_SOURCE=200809L: dictionary.c's (unused by us -
            // zultra's own optional preset-dictionary-file feature,
            // never called from zultra.zig) `off_t`/`ftello` need a
            // POSIX feature-test macro exposed, which plain -std=c99
            // doesn't imply on strict libcs. Never surfaced on macOS
            // (Apple's libc doesn't gate these behind one), only found
            // by actually cross-compiling to a musl target - see
            // .github/workflows/release.yml.
            .flags = &.{ "-std=c99", "-D_POSIX_C_SOURCE=200809L" },
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

    // Musashi (src/musashi_vendor/) - src/musashi_bench.zig's own C
    // dependency. Needed by exe_module/test_module now too, not just
    // lib_module (tools/bench's dependency surface): `execram bench`
    // (src/main.zig) links it directly into the shipped binary, which
    // is *not* how this started out - see docs/LICENSES.md §11 and
    // THIRD_PARTY_LICENSES.md, both updated when that command was
    // added, for why Musashi is no longer a dev-tool-only dependency.
    for ([_]*std.Build.Module{ exe_module, test_module, lib_module }) |mod| {
        mod.addIncludePath(b.path("src/musashi_vendor"));
    }

    // Musashi ships its opcode dispatch tables as generated source, not
    // static files: `m68kmake` reads m68k_in.c's opcode primitives and
    // emits m68kops.c/m68kops.h. Compiled and run here as a native host
    // tool, same "compile a small generator, run it, feed the output
    // back into the real build" shape used for stub assembly above -
    // one shared codegen run (m68kmake itself always runs on the host
    // regardless of what exe_module/test_module are cross-compiling
    // for), its generated output added to every module that needs it.
    const m68kmake_module = b.createModule(.{
        .target = b.graph.host,
        .optimize = .ReleaseFast,
    });
    m68kmake_module.link_libc = true;
    m68kmake_module.addCSourceFile(.{ .file = b.path("src/musashi_vendor/m68kmake.c"), .flags = &.{} });
    const m68kmake_exe = b.addExecutable(.{ .name = "m68kmake", .root_module = m68kmake_module });

    const run_m68kmake = b.addRunArtifact(m68kmake_exe);
    // argv[1]: output directory (m68kmake appends FILENAME_PROTOTYPE/
    // FILENAME_TABLE itself - m68kops.h/m68kops.c). argv[2]: input file
    // - passed as an absolute path via addFileArg so it resolves
    // regardless of the run's working directory.
    const musashi_gen = run_m68kmake.addOutputDirectoryArg("musashi_gen");
    run_m68kmake.addFileArg(b.path("src/musashi_vendor/m68k_in.c"));

    for ([_]*std.Build.Module{ exe_module, test_module, lib_module }) |mod| {
        mod.addIncludePath(musashi_gen);
        mod.addCSourceFile(.{ .file = b.path("src/musashi_vendor/m68kcpu.c"), .flags = &.{} });
        mod.addCSourceFile(.{ .file = musashi_gen.path(b, "m68kops.c"), .flags = &.{} });
        // m68kcpu.c unconditionally #includes m68kfpu.c itself (not a
        // separate translation unit here - see src/musashi_vendor/README.md
        // on why compiling it again separately would double-define every
        // FPU opcode handler), so only softfloat.c needs adding on top:
        // m68kfpu.c needs softfloat's implementation to link even though
        // src/musashi_bench.zig only ever selects M68K_CPU_TYPE_68000
        // and never exercises an FPU opcode.
        mod.addCSourceFile(.{ .file = b.path("src/musashi_vendor/softfloat/softfloat.c"), .flags = &.{} });
    }

    // A minimal fake Exec (AllocMem/FreeMem only) so the inflate/zultra
    // stub can also run under Musashi - its Depack: is the only one
    // that calls into real Exec library functions for its own scratch
    // memory (see tools/bench/fake_exec.s's own module doc for the
    // full design and why it's safe to be this minimal). Assembled the
    // same way as every real stub above, needed by every module that
    // compiles src/musashi_bench.zig.
    const fake_exec_assemble = b.addSystemCommand(&.{
        vasm,
        "-Fbin",
        "-no-opt",
        "-quiet",
    });
    fake_exec_assemble.addFileArg(b.path("tools/bench/fake_exec.s"));
    fake_exec_assemble.addArg("-o");
    const fake_exec_bin = fake_exec_assemble.addOutputFileArg("fake_exec.bin");
    for ([_]*std.Build.Module{ exe_module, test_module, lib_module }) |mod| {
        mod.addAnonymousImport("fake_exec", .{ .root_source_file = fake_exec_bin });
    }

    const bench_exe = b.addExecutable(.{ .name = "execram-bench", .root_module = bench_module });
    const run_bench = b.addRunArtifact(bench_exe);
    if (b.args) |args| run_bench.addArgs(args);
    const bench_step = b.step("bench", "Run tools/bench: predict a depacker's 68000 decompression cycles for a packed executable");
    bench_step.dependOn(&run_bench.step);

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
        addIncludedFileInputs(b, assemble, stub.extra_includes);
        assemble.addFileArg(b.path(stub.source));
        assemble.addArg("-o");
        const bin = assemble.addOutputFileArg(b.fmt("{s}.bin", .{stub.name}));

        // Makes `@embedFile(stub.name)` resolve to the assembled binary's
        // bytes. Needed by both modules: main.zig's non-test code embeds
        // it unconditionally, not just from within a test block.
        exe_module.addAnonymousImport(stub.name, .{ .root_source_file = bin });
        test_module.addAnonymousImport(stub.name, .{ .root_source_file = bin });

        // A second, separate assemble invocation with `-L` (text listing,
        // including a "Symbols:" section with each label's hex offset -
        // e.g. "Depack LAB (0xd6)") for tools/bench, which needs to know
        // where a stub's `Depack:` entry point lands inside the raw
        // binary above so it can jump the emulated CPU straight there.
        // Not folded into the `-Fbin` invocation above: vasm doesn't
        // emit a listing and a raw binary from one run, and `-Fbin`'s
        // own output carries no symbol metadata at all. A second,
        // otherwise-identical assemble is simpler and more obviously
        // correct than teaching the real build to parse some other
        // output format for offsets.
        const assemble_listing = b.addSystemCommand(&.{
            switch (stub.syntax) {
                .mot => vasm,
                .std => vasm_std,
            },
            "-Fbin",
            "-no-opt",
            "-quiet",
        });
        if (stub.include_dir) |dir| {
            assemble_listing.addArg(b.fmt("-I{s}", .{dir}));
        }
        addIncludedFileInputs(b, assemble_listing, stub.extra_includes);
        // vasm rejects a concatenated "-L<path>" (confirmed directly:
        // "error 15: unknown option") - unlike some other single-letter
        // flags, it needs "-L" and the path as two separate argv
        // entries, hence addArg + addOutputFileArg rather than
        // addPrefixedOutputFileArg.
        assemble_listing.addArg("-L");
        const listing = assemble_listing.addOutputFileArg(b.fmt("{s}.lst", .{stub.name}));
        assemble_listing.addFileArg(b.path(stub.source));
        assemble_listing.addArg("-o");
        _ = assemble_listing.addOutputFileArg(b.fmt("{s}_relisted.bin", .{stub.name}));

        // exe_module/test_module need this too now: `execram bench`
        // (src/main.zig) locates each stub's `Depack:` offset exactly
        // like tools/bench does, via src/musashi_bench.zig's shared
        // `parseDepackOffset`.
        exe_module.addAnonymousImport(b.fmt("{s}_listing", .{stub.name}), .{ .root_source_file = listing });
        test_module.addAnonymousImport(b.fmt("{s}_listing", .{stub.name}), .{ .root_source_file = listing });
        bench_module.addAnonymousImport(b.fmt("{s}_listing", .{stub.name}), .{ .root_source_file = listing });
        bench_module.addAnonymousImport(stub.name, .{ .root_source_file = bin });
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
