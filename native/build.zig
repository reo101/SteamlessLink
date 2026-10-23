const std = @import("std");
const Translator = @import("translate_c").Translator;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug information") orelse false;
    const core = b.dependency("steamless_core", .{
        .target = target,
        .optimize = optimize,
    });
    const android_jni = b.dependency("android_jni", .{});
    const translate_c = b.dependency("translate_c", .{ .target = b.graph.host });
    const bindings: Translator = .init(translate_c, .{
        .name = "jni",
        .c_source_file = android_jni.path("include_jni/jni.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
        .extra_args = &.{"-ffreestanding"},
    });

    const library = b.addLibrary(.{
        .name = "steamless_protocol",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/jni.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .imports = &.{
                .{ .name = "steamless-core", .module = core.module("steamless-core") },
                .{ .name = "jni-bindings", .module = bindings.mod },
            },
        }),
    });
    b.installArtifact(library);
}
