const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("steamless-core", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const generator = b.addExecutable(.{
        .name = "generate-kotlin-protocol",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/generate_kotlin_protocol.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const generate = b.addRunArtifact(generator);
    generate.addArg(b.option([]const u8, "kotlin-output", "Kotlin protocol output file") orelse "zig-out/ProtocolConstants.kt");
    b.step("generate-kotlin", "Generate Kotlin protocol constants and descriptors").dependOn(&generate.step);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tests = b.addTest(.{ .root_module = test_module });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
