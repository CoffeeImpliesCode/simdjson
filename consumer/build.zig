// SPDX-License-Identifier: Apache-2.0
// See ../FORK-LICENSE.md for the grant over this fork's own files.
//
//! Build wiring for the separate `consumer/` package.
//!
//! This package exists to prove one thing: that a dependent needs only
//! `dep.module("simdjson")` and gets a working, correctly linked library. If the
//! facade module stopped carrying its C artifact, or the translated
//! `zig/bridge.h` stopped matching the C++ it was compiled from, or the
//! `simdjson` module stopped resolving by name, this would stop building or stop
//! producing the answers its program checks -- and nothing inside the library
//! would notice.
//!
//! `src/main.zig` is the API surface a real dependent uses. This file is only the
//! graph that builds it, and it deliberately repeats almost nothing: the library
//! decides which artifact is delivered, which configuration macros the C++ was
//! compiled with and which headers describe it, and this package learns all of
//! that through the dependency rather than by restating it.
//!
//! `zig build run` runs it. The parent package's `zig build consumer` runs or
//! installs this package as a nested build for the selected target, linkage and
//! dispatch mode -- it installs when this host cannot execute that target -- so
//! `zig build consumer -Dlinkage=dynamic` really does check the shared object
//! and not the default archive.
//!
//! There is deliberately **no `-Dsystem` option** here, and that is not an
//! omission. This package has no system mode to forward: `build.zig` refuses to
//! configure one, because the upstream release it vendors *is* the library, so
//! there is no second source of truth about which declarations are in play to
//! begin with. `UPSTREAM.md`, "No system mode", is the record.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The delivery and dispatch options are declared here rather than ignored,
    // so `zig build run -Dlinkage=dynamic` checks the shared object instead of
    // silently checking the default archive, and so the parent package's
    // `zig build consumer` can pass a configuration through to the dependency
    // instead of dropping it on the floor.
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

    // No `link_libc` and no `link_libcpp` here on purpose. Both requirements
    // belong to the library module, which carries them
    // (`build_support/graph.zig`); a dependent states its own, and this program
    // needs nothing beyond what the library already brings. Adding either here
    // would hide a library that forgot to declare it.
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
    // Forwarded so `zig build run -Druntime=true -- --provider <path>` reaches
    // `src/main.zig`, which reads exactly that and otherwise falls through to
    // `SIMDJSON_PROVIDER`. With no arguments this is inert, so a linked run is
    // unchanged.
    if (b.args) |args| run_exe.addArgs(args);
    const run_step = b.step("run", "Build and run the consumer program");
    run_step.dependOn(&run_exe.step);
}