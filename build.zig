const std = @import("std");

/// One 68000 depacker stub, assembled by vasm from `stubs/<name>/<source>`
/// into a raw binary and embedded into the host tool. Real backends
/// (inflate, zx0, shrinkler) register themselves here as they land in
/// their milestones; `example` is the M0 placeholder proving the pipeline.
const Stub = struct {
    name: []const u8,
    source: []const u8,
};

const stubs = [_]Stub{
    .{ .name = "stub_example", .source = "stubs/example/hello.s" },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const vasm = b.option(
        []const u8,
        "vasm",
        "Path to the vasmm68k_mot binary used to assemble 68k stubs",
    ) orelse "vasmm68k_mot";

    const exe = b.addExecutable(.{
        .name = "execram",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    for (stubs) |stub| {
        const assemble = b.addSystemCommand(&.{
            vasm,
            "-Fbin", // raw binary output, no hunk/object wrapper
            "-no-opt", // no branch/addressing-mode relaxation: keep stub timing predictable
            "-quiet",
        });
        assemble.addFileArg(b.path(stub.source));
        assemble.addArg("-o");
        const bin = assemble.addOutputFileArg(b.fmt("{s}.bin", .{stub.name}));

        // Makes `@embedFile(stub.name)` resolve to the assembled binary's
        // bytes inside src/main.zig (or anything else importing this module).
        exe.root_module.addAnonymousImport(stub.name, .{
            .root_source_file = bin,
        });
    }

    b.installArtifact(exe);

    const run_step = b.step("run", "Run execram");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_tests.step);
}
