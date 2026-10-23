// SPDX-License-Identifier: Apache-2.0
// See ../FORK-LICENSE.md for the grant over this fork's own files.
//
//! Minimal external package using `dep.module("simdjson")`.
//! The dependency supplies artifacts and configuration; this package does not restate them.
//! The parent consumer step forwards linkage and runtime options.
//! No system option exists because the library has no system-source mode.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Forward linkage and runtime options so the executable checks the selected configuration.
    const linkage = b.option(
        std.builtin.LinkMode,
        "linkage",
        "Which delivery of libsimdjson to check. Forwarded to the dependency; " ++
            "it decides the artifact, never anything in this package.",
    ) orelse .static;
    const runtime_loaded = b.option(
        bool,
        "runtime",
        "Check the dependency's runtime-loading dispatch instead of a linked " ++
            "one. Forwarded to the dependency. A program built this way has to " ++
            "name a provider with an explicit load() before any native call, " ++
            "which is src/main.zig's business and not this file's.",
    ) orelse false;

    const dep = b.dependency("simdjson", .{
        .target = target,
        .optimize = optimize,
        .linkage = linkage,
        .runtime = runtime_loaded,
    });

    // The dependency owns libc/libcpp requirements; do not mask a missing declaration here.
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("simdjson", dep.module("simdjson"));

    const exe = b.addExecutable(.{
        .name = "simdjson-consumer",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    run_exe.has_side_effects = true;
    // Forward run arguments so runtime mode can receive `--provider`.
    if (b.args) |args| run_exe.addArgs(args);
    const run_step = b.step("run", "Build and run the consumer program");
    run_step.dependOn(&run_exe.step);
}
