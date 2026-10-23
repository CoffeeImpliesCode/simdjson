// SPDX-License-Identifier: Apache-2.0
// See FORK-LICENSE.md for the grant over this fork's own files, and NOTICE.md
// for the terms that cover everything under src/.
//
//! Zig 0.16 build for simdjson 5.0.2.
//! `-Dcpu` selects the compiled SIMD kernel; On-Demand has no runtime fallback.
const std = @import("std");

/// Target-specific graph settings and supported targets.
const graph = @import("build_support/graph.zig");

/// Package manifest.
const manifest = @import("build.zig.zon");

/// Parsed manifest version.
const manifest_version = std.SemanticVersion.parse(manifest.version) catch
    @panic("build.zig.zon: .version is not a semantic version");

/// Package, module, and artifact name.
const lib_name = graph.artifact_name;

/// Test root.
const test_source = "tests.zig";

/// The deterministic example program.
const example_source = "smoke.zig";

/// Fixture directory shared by tests and the example.
const fixture_dir = "testdata";

/// Anonymous import used to pass the fixture path to each root.
const paths_module = "simdjson_paths";

/// Create an import that resolves the fixture path at build time.

fn addPathsModule(b: *std.Build) *std.Build.Step.Options {
    const options = b.addOptions();
    options.addOptionPath("fixture_dir", b.path(fixture_dir));
    return options;
}

/// Upstream license texts, installed unmodified.
const upstream_licences = [_][]const u8{
    source_dir_prefix ++ "LICENSE",
    source_dir_prefix ++ "LICENSE-MIT",
};

/// Prefix for paths in the upstream source tree.
const source_dir_prefix = graph.source_dir ++ "/";

/// Fork-authored records installed beside upstream license texts.
const fork_records = [_][]const u8{
    "NOTICE.md",
    "FORK-LICENSE.md",
    "FORK-NOTES.md",
    "UPSTREAM.md",
    "CHANGELOG.md",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Linkage selects the artifact; runtime loading independently selects dispatch.
    const linkage: std.builtin.LinkMode = b.option(
        std.builtin.LinkMode,
        "linkage",
        "Deliver the native library as a static archive (the default, and what " ++
            "upstream's own CMakeLists.txt produces) or as a real shared object " ++
            "with upstream's own soname, libsimdjson.so.34. This selects the " ++
            "delivery and never the dispatch: the same two C++ translation units " ++
            "are compiled either way at the same flags.",
    ) orelse .static;

    const runtime_loaded = b.option(
        bool,
        "runtime",
        "Resolve the native entry points at run time instead of linking them. " ++
            "The facade keeps the same translated header and the same public " ++
            "types; each of the eleven entry points becomes a dispatch through " ++
            "one process-lifetime table that an explicit load(source) fills, and " ++
            "the module links no archive. Independent of -Dlinkage, which still " ++
            "decides which artifact this build delivers and installs. Default off, " ++
            "and a linked build is unchanged in every respect.",
    ) orelse false;

    // Keep the manifest version aligned with upstream.
    if (manifest_version.order(graph.upstream_version) != .eq) {
        @panic("build.zig.zon .version no longer matches the version read out " ++
            "of src/include/simdjson/simdjson_version.h; see UPSTREAM.md");
    }

    // Register the published module and artifact.
    const published = graph.addGraph(b, target, optimize, .{
        .requested = linkage,
        .runtime_loaded = runtime_loaded,
        .public = true,
    });

    b.installArtifact(published.library);
    add_pkg_config(b, published.delivered);
    install_licence_records(b);

    // Compile the example against the published module.
    const example_mod = b.createModule(.{
        .root_source_file = b.path(example_source),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    example_mod.addImport(lib_name, published.module);
    // The example uses the same fixture import as the tests.
    example_mod.addAnonymousImport(paths_module, .{
        .root_source_file = addPathsModule(b).getOutput(),
        .target = target,
        .optimize = optimize,
    });
    const example = b.addExecutable(.{
        .name = "simdjson-smoke",
        .root_module = example_mod,
    });
    b.getInstallStep().dependOn(&example.step);

    // Keep the run step separate from installation.
    const run_example = b.addRunArtifact(example);
    run_example.has_side_effects = true;
    if (b.args) |args| run_example.addArgs(args);
    b.step("smoke", "Run the deterministic example program").dependOn(&run_example.step);

    // Attach test blocks directly so the runner discovers them.
    const test_mod = b.createModule(.{
        .root_source_file = b.path(test_source),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addImport(lib_name, published.module);
    test_mod.addAnonymousImport(paths_module, .{
        .root_source_file = addPathsModule(b).getOutput(),
        .target = target,
        .optimize = optimize,
    });
    const unit_tests = b.addTest(.{
        .name = "simdjson-tests",
        .root_module = test_mod,
    });
    const run_tests = b.addRunArtifact(unit_tests);
    run_tests.has_side_effects = true;
    b.step("test", "Run the behavioural tests against the shared fixtures").dependOn(&run_tests.step);

    // Run the consumer package as a separate build.
    b.step("consumer", "Build or run the consumer/ package for the selected target")
        .dependOn(&runConsumer(b, target, optimize, linkage, runtime_loaded).step);

    // Compile every facade caller for each required target; run nothing.
    const check_step = b.step(
        "check",
        "Compile the core, the bridge, the translated header, the facade, the " ++
            "tests and the example for all six required targets without running " ++
            "any of them",
    );
    if (!target.query.isNative()) {
        add_target_check(b, check_step, target.query, optimize, linkage, runtime_loaded);
    } else {
        // Apply the selected linkage to each required target.
        for (graph.required_targets) |query| {
            add_target_check(b, check_step, query, optimize, linkage, runtime_loaded);
        }
    }

    // Report configure-time target and kernel selections.
    std.debug.print(
        "simdjson: simdjson {s}, one C++ translation unit (src/src/simdjson.cpp) " ++
            "plus this fork's zig/bridge.cc, -std=c++17 -fno-exceptions -fno-rtti, " ++
            "{s}\n",
        .{ manifest.version, macroList(b, graph.cppMacros(b, target)) },
    );
    std.debug.print("simdjson: {s}\n", .{switch (published.delivered) {
        .static => "static archive libsimdjson.a (default, and what upstream's BUILD_SHARED_LIBS=OFF produces)",
        .dynamic => b.fmt("shared object libsimdjson.so.{d}.{d}.{d}, soname libsimdjson.so.{d} (upstream's SIMDJSON_LIB_VERSION, not the release)", .{
            graph.abi_version.major,
            graph.abi_version.minor,
            graph.abi_version.patch,
            graph.abi_version.major,
        }),
    }});
    std.debug.print(
        "simdjson: {d} entry points (zig/bridge.h); the Zig facade binds On-Demand " ++
            "only, and the installed include/simdjson/ tree is upstream's complete " ++
            "public header set for a C++ consumer\n",
        .{graph.bridge_abi_symbols.len},
    );
    if (runtime_loaded) {
        // Runtime loading uses an explicit provider.
        std.debug.print(
            "simdjson: runtime-loaded dispatch (-Druntime=true); the facade module " ++
                "links no archive, a provider is named by an explicit load(source), " ++
                "and a static install cannot itself be one -- an archive is not a " ++
                "file the platform loader can open\n",
            .{},
        );
    }
    if (published.delivered == .dynamic and target.result.ofmt != .elf) {
        // Explain target-specific shared export behavior.
        std.debug.print(
            "simdjson: a {s} shared object has no export-surface mechanism in this " ++
                "graph, so it exports everything the linker kept rather than exactly " ++
                "the eleven declared names; a consumer of it must select by name\n",
            .{@tagName(target.result.ofmt)},
        );
    }
    if (published.delivered == .static and target.result.os.tag == .wasi) {
        std.debug.print(
            "simdjson: this static archive is a compile row in the matrix, not a " ++
                "loadable provider; a runtime-loaded caller on wasm32-wasi needs a " ++
                "shared object from a host that can produce one\n",
            .{},
        );
    }
}

/// Compile the test and example roots for one target.
fn add_target_check(
    b: *std.Build,
    step: *std.Build.Step,
    query: std.Target.Query,
    optimize: std.builtin.OptimizeMode,
    linkage: std.builtin.LinkMode,
    runtime_loaded: bool,
) void {
    const cross_target = b.resolveTargetQuery(query);
    // Name each target's steps with its triple.
    const triple = cross_target.result.zigTriple(b.allocator) catch @panic("unspellable target");

    const cross = graph.addGraph(b, cross_target, optimize, .{
        .requested = linkage,
        .runtime_loaded = runtime_loaded,
        .public = false,
    });

    const test_mod = b.createModule(.{
        .root_source_file = b.path(test_source),
        .target = cross_target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addImport(lib_name, cross.module);
    test_mod.addAnonymousImport(paths_module, .{
        .root_source_file = addPathsModule(b).getOutput(),
        .target = cross_target,
        .optimize = optimize,
    });
    step.dependOn(&b.addTest(.{
        .name = b.fmt("simdjson-tests-{s}", .{triple}),
        .root_module = test_mod,
    }).step);

    const example_mod = b.createModule(.{
        .root_source_file = b.path(example_source),
        .target = cross_target,
        .optimize = optimize,
        .link_libc = true,
    });
    example_mod.addImport(lib_name, cross.module);
    // Use the matrix cell's fixture import.
    example_mod.addAnonymousImport(paths_module, .{
        .root_source_file = addPathsModule(b).getOutput(),
        .target = cross_target,
        .optimize = optimize,
    });
    step.dependOn(&b.addExecutable(.{
        .name = b.fmt("simdjson-smoke-{s}", .{triple}),
        .root_module = example_mod,
    }).step);
}

/// Run the out-of-tree consumer with this build's options.
fn runConsumer(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    linkage: std.builtin.LinkMode,
    runtime_loaded: bool,
) *std.Build.Step.Run {
    const triple = target.query.zigTriple(b.allocator) catch @panic("OOM");
    defer b.allocator.free(triple);
    // Forward CPU selection so the consumer builds the same SIMD kernels.
    const cpu = target.query.serializeCpuAlloc(b.allocator) catch @panic("OOM");
    defer b.allocator.free(cpu);

    // Use the compiler running this build for the nested build.
    const run = b.addSystemCommand(&.{ b.graph.zig_exe, "build" });
    run.setName("consumer package");
    run.setCwd(b.path("consumer"));
    run.addArg(if (hostCanExecute(b, target)) "run" else "install");
    run.addArg(b.fmt("-Dtarget={s}", .{triple}));
    run.addArg(b.fmt("-Dcpu={s}", .{cpu}));
    run.addArg(b.fmt("-Doptimize={s}", .{@tagName(optimize)}));
    // Forward linkage and runtime mode to the nested build.
    run.addArg(b.fmt("-Dlinkage={s}", .{@tagName(linkage)}));
    run.addArg(b.fmt("-Druntime={s}", .{if (runtime_loaded) "true" else "false"}));
    if (b.enable_darling) run.addArg("-fdarling");
    if (b.enable_qemu) run.addArg("-fqemu");
    if (b.enable_rosetta) run.addArg("-frosetta");
    if (b.enable_wasmtime) run.addArg("-fwasmtime");
    if (b.enable_wine) run.addArg("-fwine");
    if (b.libc_runtimes_dir) |runtimes| run.addArgs(&.{ "--libc-runtimes", runtimes });
    // Keep job count and summary explicit for the nested build.
    run.addArg("-j8");
    run.addArg("--summary");
    run.addArg("all");
    // Use the consumer working directory when no cache root is set.
    if (b.cache_root.path) |cache| {
        run.addArg("--cache-dir");
        run.addArg(b.fmt("{s}/consumer", .{cache}));
    }
    // Reuse the caller's global cache.
    if (b.graph.global_cache_root.path) |global_cache| {
        run.addArg("--global-cache-dir");
        run.addArg(global_cache);
    }
    // Make the caller's install prefix absolute before forwarding it.
    const default_prefix = b.build_root.join(b.allocator, &.{"zig-out"}) catch @panic("OOM");
    if (!std.mem.eql(u8, b.install_prefix, default_prefix)) {
        const prefix = if (std.fs.path.isAbsolute(b.install_prefix))
            b.install_prefix
        else
            b.pathJoin(&.{ b.graph.cache.cwd, b.install_prefix });
        run.addArg("--prefix");
        run.addArg(prefix);
    }
    // Forward program arguments after `--`.
    if (b.args) |args| {
        run.addArg("--");
        run.addArgs(args);
    }
    // The nested build is the step's only observable effect.
    run.has_side_effects = true;
    return run;
}

/// Whether the selected target can run with the configured executors.
fn hostCanExecute(b: *std.Build, target: std.Build.ResolvedTarget) bool {
    const host = &b.graph.host.result;
    const candidate = &target.result;
    const options: std.zig.system.GetExternalExecutorOptions = .{
        .allow_darling = b.enable_darling,
        .allow_qemu = b.enable_qemu,
        .allow_wasmtime = b.enable_wasmtime,
        .allow_wine = b.enable_wine,
        // Match Run's cross-libc behavior.
        .qemu_fixes_dl = candidate.isGnuLibC() and b.libc_runtimes_dir != null,
        .link_libc = true,
    };
    return switch (std.zig.system.getExternalExecutor(b.graph.io, host, candidate, options)) {
        .native, .rosetta => true,
        // Match the enabled executor switches.
        .wine, .wasmtime, .darling => true,
        // QEMU GNU libc needs runtime libraries.
        .qemu => !(candidate.isGnuLibC() and b.libc_runtimes_dir == null),
        // Reject targets without a compatible executor.
        .bad_dl, .bad_os_or_cpu => false,
    };
}

/// Install the prefix-relative pkg-config file for the selected linkage.
fn add_pkg_config(b: *std.Build, delivered: std.builtin.LinkMode) void {
    const files = b.addWriteFiles();
    // Add the generated file to the install graph.
    const install_pc = b.addInstallFileWithDir(
        files.add("simdjson.pc", b.fmt(
            \\# simdjson.pc for the simdjson 5.0.2 SDK.
            \\#
            \\# Generated from upstream's own template src/simdjson.pc.in, which
            \\# ships unaltered in this package. build.zig's add_pkg_config names the
            \\# upstream line each field comes from. `prefix` is pcfiledir-relative
            \\# so the installed file is correct wherever --prefix put it.
            \\prefix=${{pcfiledir}}/../..
            \\exec_prefix=${{prefix}}
            \\libdir=${{prefix}}/lib
            \\includedir=${{prefix}}/include
            \\
            \\Name: simdjson
            \\Description: simdjson 5.0.2, upstream's SIMD JSON parser, as a C ABI library
            \\URL: https://simdjson.org/
            \\Version: {}
            \\
            \\Requires:
            \\Libs: -L"${{libdir}}" -lsimdjson
            \\Libs.private:{s}
            \\Cflags: -I"${{includedir}}"
            \\
        , .{
            manifest_version,
            // Static consumers need the C++ runtime at link time.
            if (delivered == .static) " -lc++" else "",
        })),
        .prefix,
        "lib/pkgconfig/simdjson.pc",
    );
    b.getInstallStep().dependOn(&install_pc.step);
}

/// Format the C++ configuration macros resolved for this target.
fn macroList(b: *std.Build, macros: []const [2][]const u8) []const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    for (macros) |macro| {
        parts.append(b.allocator, b.fmt("{s}={s}", .{ macro[0], macro[1] })) catch @panic("out of memory");
    }
    return std.mem.join(b.allocator, " ", parts.items) catch @panic("out of memory");
}

/// Install upstream license texts and this fork's records.
fn install_licence_records(b: *std.Build) void {
    for (upstream_licences) |licence| {
        // Keep each license install step reachable.
        const install_licence = b.addInstallFileWithDir(
            b.path(licence),
            .prefix,
            b.fmt("share/licenses/simdjson/{s}", .{std.fs.path.basename(licence)}),
        );
        b.getInstallStep().dependOn(&install_licence.step);
    }
    for (fork_records) |record| {
        const install_record = b.addInstallFileWithDir(
            b.path(record),
            .prefix,
            b.fmt("share/licenses/simdjson/{s}", .{record}),
        );
        b.getInstallStep().dependOn(&install_record.step);
    }
}
