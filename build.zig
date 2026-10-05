// SPDX-License-Identifier: Apache-2.0
// See FORK-LICENSE.md for the grant over this fork's own files, and NOTICE.md
// for the terms that cover everything under src/.
//
//! Zig 0.16 build for simdjson 5.0.2.
//!
//! The compiled core is upstream's own single translation unit, byte for byte:
//! `src/src/simdjson.cpp`, which is the whole of `SIMDJSON_SOURCES` at
//! `src/CMakeLists.txt:204` and the whole of the `add_library` at `:206`. The
//! second C++ unit is this fork's own `zig/bridge.cc`, the C ABI seam. Both are
//! compiled at `-std=c++17` with `-fno-exceptions -fno-rtti`, on the same include
//! paths and under the same configuration macros, and
//! `build_support/graph.zig`'s `cppMacros` says where each of those comes from
//! and which two are resolved for the target being built.
//!
//! Nothing is downloaded, no CMake, no autotools script and no `make` runs, and
//! the default mode compiles everything from this repository rather than linking
//! an installed copy. There is no system mode: `AGENTS.md` §4 permits one only
//! where a real compiled system library exists, and the upstream release this
//! package vendors *is* the library, so a `-Dsystem` switch here would be a
//! second source of truth about which declarations are in play. The record of
//! that decision is `UPSTREAM.md`, "No system mode".
//!
//! Upstream reference: the official `simdjson-5.0.2` release tarball, tag
//! `v5.0.2`, tag commit `c9030726ebbf5f9fe9f9facb4a401f6d3ccd77a2`,
//! 8331647 bytes, sha256
//! `09de4289a26d3a0453569901a3837450b5b98a5c317d635eeee8e2a82b1ebe6b`. Those
//! five values are read out of `UPSTREAM.sha256:4-7`, which is where the pin is
//! recorded; `UPSTREAM.md` carries them in prose. This script does not restate a
//! digest of its own and does not fetch anything to check one.
//! There is no `upstream-test` step, and none is faked. Upstream *does* ship a
//! test suite -- `src/tests/`, carried whole, with `src/tests/ondemand/` among
//! it -- but it is a CMake-and-Catch2 suite built for upstream's own build
//! (`src/tests/CMakeLists.txt`), and this graph runs no CMake. So
//! `tools/check-provenance.sh` records that those sources are *present and
//! unedited* rather than claiming they were executed, and `zig build test` runs
//! this package's own tests against the fixtures under `testdata/`. Upstream's
//! suite was never deleted and is never skipped; it is simply not this graph's
//! harness, and saying so is better than a step that appears to run it.
//!
//! Entry points
//! -----------
//!   zig build           install the delivery tree, and compile the example
//!   zig build test      run the behavioural tests for the selected target
//!                       (`-Dtarget`; the host when it is absent)
//!   zig build smoke     run the example program
//!   zig build consumer  build the separate `consumer/` package, and run it when
//!                       this host can execute the selected target
//!   zig build check     compile the core, the bridge, the translated header,
//!                       the facade, the tests and the example for all six
//!                       targets in `build_support/graph.zig:required_targets`,
//!                       running nothing
//!
//!   cross-test       the same `test` step, for the published 53-platform
//!                   Zig 0.16.0 Tier 1/2 table rather than the host alone.
//!                   `cross-test` discovers `cross-test.profile.sh` from the
//!                   package root, runs `zig build test -Dtarget=TARGET` for
//!                   each of them, and executes the binary where a runner exists
//!                   and records explicit `build_only` coverage where one does
//!                   not. `test` is what the harness reaches for, and it builds
//!                   the same graph and the same test binary for whatever
//!                   `-Dtarget` says: nothing in `build()` narrows the graph to
//!                   the host.
//!
//! Options
//! -------
//!   -Dlinkage=static   a static archive, `libsimdjson.a`. This is the default,
//!                      and it is what upstream's own build produces: there is
//!                      no `STATIC`/`SHARED` keyword at `src/CMakeLists.txt:206`
//!                      and `BUILD_SHARED_LIBS` defaults `OFF` (`:193`).
//!   -Dlinkage=dynamic  a real shared object, `libsimdjson.so.34.0.0` with
//!                      `libsimdjson.so.34` and `libsimdjson.so` beside it. The
//!                      version is upstream's `SIMDJSON_LIB_VERSION`
//!                      (`src/CMakeLists.txt:32`), not the 5.0.2 release. Refused
//!                      with a message naming the target where a shared object
//!                      cannot exist; see "WASI and `-Dlinkage=dynamic`".
//!   -Druntime=true     resolve the native entry points at run time instead of
//!                      linking them. Orthogonal to `-Dlinkage`, which still
//!                      decides which artifact this build delivers and installs.
//!                      Default off; a linked build is unchanged.
//!   -Dtarget=<triple>  build for one target; `zig build check` then checks that
//!                      target only instead of the whole matrix.
//!   -Doptimize=<mode>  the caller's mode, passed to every graph below.
//!   -Dcpu=<model>      the caller's CPU selection, passed through untouched.
//!                      This is not a portability flag for simdjson: it decides
//!                      *which SIMD kernels are compiled into the artifact*, and
//!                      `#include <simdjson/ondemand.h>` is statically bound to
//!                      the builtin one (`src/include/simdjson/builtin/ondemand.h:39`),
//!                      so there is no slower kernel to fall back to at run time.
//!                      `package.nix` passes `-Dcpu=baseline` for exactly that
//!                      reason: a store path must not depend on the CPU of
//!                      whichever machine built it.
//!
//! The SIMD-fallback boundary, stated once
//! -----------------------------------------
//! This is the one thing about this library that a reader of a normal JSON
//! parser would not guess, and this package does not paper over it.
//!
//! There are two different things called "fallback" here and they are not
//! related.
//!
//! 1. **The scalar kernel is a real, compiled-in code path, not a rescue.**
//!    `src/src/simdjson.cpp:23-49` includes one `.cpp` per
//!    `SIMDJSON_IMPLEMENTATION_<ARCH>` and `#if SIMDJSON_IMPLEMENTATION_FALLBACK`
//!    pulls in `fallback.cpp` last. At `-Dcpu=baseline` on x86-64 none of
//!    `SIMDJSON_CAN_ALWAYS_RUN_HASWELL` (`__AVX2__` and friends,
//!    `src/include/simdjson/implementation_detection.h:75-79`), `_ICELAKE`
//!    (`__AVX512*`, `:46-58`) or `_WESTMERE` (`__SSE4_2__ && __PCLMUL__`,
//!    `:101-105`) is defined, so `:137-145` leaves
//!    `SIMDJSON_IMPLEMENTATION_FALLBACK` at 1 and the artifact carries the scalar
//!    kernel *alone*. That is not a degraded build: it is upstream's own answer
//!    for a target with no guaranteed SIMD, and it parses correctly at every
//!    level of the correctness boundary this package's tests cover. It is
//!    slower, and the amount slower is a fact about the kernel and the input,
//!    which is why no gate in this package asserts a speed.
//!
//! 2. **There is no runtime fallback behind a slow kernel.** A caller cannot
//!    ask for `haswell` on a machine that lacks it and get `fallback`. The
//!    On-Demand surface is bound to `SIMDJSON_BUILTIN_IMPLEMENTATION` at compile
//!    time (`src/include/simdjson/builtin/ondemand.h:11-31,39`), so whichever
//!    kernel the flags selected is the only one the facade reaches.
//!    `SIMDJSON_FORCE_IMPLEMENTATION` does not change that: it overrides the
//!    *DOM-side* run-time dispatcher, and naming a kernel that is not compiled in
//!    makes upstream latch onto the unsupported implementation so every later
//!    parse fails with `UNSUPPORTED_ARCHITECTURE`
//!    (`src/src/implementation.cpp:296-312`, latch at `:308`). That error is in
//!    `zig/root.zig`'s taxonomy as `Error.UpstreamUnsupportedArchitecture`
//!    because it is the observable consequence of that latch, not because this
//!    package asks for it.
//!
//! The honest summary for a dependent: **which kernel you get is a build-time
//! property of the flags you built with, and it is not negotiable at run time.**
//! `builtinImplementation` (`zig/root.zig`) reports it; `activeImplementation`
//! reports something else entirely -- the DOM dispatcher's choice, which is a
//! function of the host CPU *and* of the environment, which is why
//! `runtime/library.zig` does not check it and no gate may assert on it.
//! `FORK-NOTES.md` notes 6 and 7 are the records.
//!
//! What is compiled but not wrapped
//! --------------------------------
//! The installed `include/simdjson/` tree is upstream's whole public header set,
//! 234 files, unmodified. The Zig facade reaches none of it: it binds **On-Demand
//! only**, and none of upstream's class templates, namespace aliases or
//! `simdjson_result<T>` returns can cross a C ABI. So `simdjson::dom::parser`,
//! `document_stream`, `minify` and compile-time JSON are absent from the Zig
//! surface and reachable from C++ through the installed headers. That absence is
//! a decision, recorded in `FORK-NOTES.md` note 1, and `zig/root.zig` says it in
//! prose. A C++ consumer of this package has all of upstream's API.
//!
//! WASI and `-Dlinkage=dynamic`
//! ----------------------------
//! `wasm32-wasi` is in the six-target matrix because the On-Demand path is
//! exception-free: `-fno-exceptions -fno-rtti` plus Zig's own bundled libc++ is
//! the intended route, so this closure compiles and links with no external WASI
//! SDK sysroot at all. That is why it is a matrix row rather than a refusal --
//! the row that needed a sysroot in this workspace was a different library whose
//! closure uses filesystem streams, Abseil synchronization and C++ unwinding,
//! and there is nothing here for one to provide.
//!
//! It is refused for `-Dlinkage=dynamic`. `.wasi` is in the `none` arm of
//! `std.Target.DynamicLinker.kind` (`lib/std/Target.zig:2345`, listed at
//! `:2401`), so a `.so` there is a file nothing can open. The graph refuses the
//! combination rather than answering it with an archive, and the static build is
//! what covers the row. Windows is the case that makes this a decision and not
//! a lookup: `DynamicLinker.kind` is `.none` there too, but only because a
//! PE/COFF image has no interpreter path -- its imports are resolved by the
//! loader inside the OS -- so a Windows target does carry a shared object, as a
//! DLL. The predicate is "can a shared object exist here at all", and the two
//! families are named separately for that reason.
//!
//! Where the fixtures come from
//! ----------------------------
//! `test` reads `testdata/` through a module this build creates, `simdjson_paths`,
//! which carries the directory's **absolute** path, resolved from this build
//! root at configure time. That is why the fixtures are read from this
//! checkout and never from an installed prefix -- nothing in the install
//! layout installs them, so a test binary that found them under `--prefix`
//! would be reading files no gate had recorded -- and why `package.nix:163-167`
//! sets `doCheck = false`: a Nix derivation does not control where this
//! checkout is, and the fixtures are not part of the derivation's output.
//!
//! There is no installed copy of the fixtures and no generated copy either. The
//! digests in `UPSTREAM.sha256`'s last 22 records are what
//! `tools/check-provenance.sh` checks, so a fixture that drifted from its
//! recorded bytes fails the provenance gate rather than quietly changing a test's
//! answer.
const std = @import("std");

/// The per-target assembly. It owns the two C++ translation units, the four
/// configuration macros, the include paths, the translation step and the
/// `-Dlinkage=dynamic` refusal, and it names the six `check` targets this package
/// promises. `build.zig` owns everything else.
const graph = @import("build_support/graph.zig");

/// `build.zig.zon` itself. `@import` of the manifest is how a build script reads
/// `.version` without a second copy of it.
const manifest = @import("build.zig.zon");

/// `build.zig.zon .version`, parsed.
///
/// The parse is the loud part: a manifest whose `.version` is not a semantic
/// version fails to configure here rather than being silently compared as
/// something else.
const manifest_version = std.SemanticVersion.parse(manifest.version) catch
    @panic("build.zig.zon: .version is not a semantic version");

/// The package, artifact and module name. One string, in
/// `build_support/graph.zig`, so the four places that print it cannot disagree.
const lib_name = graph.artifact_name;

/// Test root.
const test_source = "tests.zig";

/// The deterministic example program.
const example_source = "smoke.zig";

/// The shared fixture directory the test root and the example read.
///
/// It is named here and given to both as a build-created import rather than
/// compiled in or copied: `testdata/` is 22 recorded fixtures and a
/// 631515-byte JSON document, and embedding any of that in a binary would be a
/// second copy of material `UPSTREAM.sha256` already pins.
///
/// The path handed over is **absolute**, resolved at configure time from this
/// build root. A relative path would be resolved against the test binary's
/// working directory instead, and that directory is the caller's: `devenv.nix`
/// enters this checkout before running `zig build test`, `package.nix` runs in a
/// sandbox with its own cwd, and the cross-test harness runs each cell from its
/// own scratch. An absolute path is the only spelling that is right in all
/// three.
const fixture_dir = "testdata";

/// The name of the import `tests.zig` and `smoke.zig` use to find `fixture_dir`.
///
/// It is an **anonymous** import, not a registered module: `simdjson_paths`
/// exists only for this package's own two roots, and registering it under that
/// name would make `dep.module("simdjson_paths")` resolve for a dependent that
/// has no `testdata/` of its own. An anonymous import is scoped to the one
/// module that declares it, which is exactly the scope wanted. Neither
/// `tests.zig` nor `smoke.zig` can name a path into this tree to get at the
/// bytes; both read the module and nothing else.
const paths_module = "simdjson_paths";

/// Creates the options step that carries `fixture_dir` to one root.
///
/// `b.addOptions` is the mechanism rather than a hand-written source file,
/// because it resolves its `path` argument to an absolute path at step time and
/// declares a dependency on it, which is what makes a moved or deleted
/// `testdata/` a build failure rather than a runtime "file not found" inside a
/// test binary that reported success. There is no `build_support/paths.zig` for
/// the same reason: a checked-in stub that only wraps one string would be a
/// second spelling of `fixture_dir`.
///
/// One step per root, not one shared between them: a `Step.Options` output is a
/// single generated file, and sharing it would make the six matrix cells and the
/// published graph read one another's configuration.

fn addPathsModule(b: *std.Build) *std.Build.Step.Options {
    const options = b.addOptions();
    options.addOptionPath("fixture_dir", b.path(fixture_dir));
    return options;
}

/// Both upstream licence texts, installed verbatim beside this fork's records.
///
/// `src/LICENSE` is the Apache License 2.0 and `src/LICENSE-MIT` is the MIT
/// License, both carrying `Copyright 2018-2025 The simdjson authors`. Upstream
/// offers a **choice** -- `src/README.md:269` says "This code is made available
/// under the Apache License 2.0 as well as under the MIT License. As a user, you
/// can pick the license you prefer" -- and both are shipped, because reducing a
/// dual grant to one label is the mistake `AGENTS.md` §8 warns about and
/// `FORK-LICENSE.md` §6 refuses to make.
const upstream_licences = [_][]const u8{
    source_dir_prefix ++ "LICENSE",
    source_dir_prefix ++ "LICENSE-MIT",
};

/// `src/`, as a prefix. Named once so the licence list and the graph's own
/// constant cannot be typed two ways.
const source_dir_prefix = graph.source_dir ++ "/";

/// The licence and provenance records this fork installs beside upstream's own
/// texts. Each is a file in this repository and each is Apache-2.0 under
/// `FORK-LICENSE.md`; none of them is upstream's.
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

    // `-Dlinkage` selects the delivery. `-Druntime` selects the dispatch, and the
    // two are orthogonal: this option says which artifact this build delivers and
    // installs, the other says whether the Zig facade calls it through a link
    // line or through one process-lifetime table an explicit `load` fills. Under
    // `-Druntime` nothing is linked into the facade module at all, so a caller
    // may name a provider this tree did not build -- and the artifact is still
    // built and installed, so a caller may equally name the one it did.
    //
    // Static is the default because it is upstream's own default:
    // `src/CMakeLists.txt:206` has no linkage keyword and `BUILD_SHARED_LIBS`
    // is `OFF` at `:193`.
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

    // `build.zig.zon .version` and the version this build stamps into
    // `simdjson.pc`, names into the shared object's file name and documents in
    // four other places are one fact. `std.SemanticVersion.parse` fails loudly
    // rather than wrapping a non-version, and the comparison catches a manifest
    // edited without the source it describes.
    if (manifest_version.order(graph.upstream_version) != .eq) {
        @panic("build.zig.zon .version no longer matches the version read out " ++
            "of src/include/simdjson/simdjson_version.h; see UPSTREAM.md");
    }

    // `build_support/graph.zig` is the only place a target's graph is assembled,
    // and this is the published one: registered as `simdjson`, so
    // `dep.module("simdjson")` reaches it, and installed under the bare
    // artifact name.
    const published = graph.addGraph(b, target, optimize, .{
        .requested = linkage,
        .runtime_loaded = runtime_loaded,
        .public = true,
    });

    b.installArtifact(published.library);
    add_pkg_config(b, published.delivered);
    install_licence_records(b);

    // `zig build` also compiles the example. The example is the cheapest thing
    // that proves the facade, the translated header and the compiled C++ agree
    // on types, symbols and link-time dependencies. It is compiled, not
    // installed: it is a proof, not a deliverable.
    const example_mod = b.createModule(.{
        .root_source_file = b.path(example_source),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    example_mod.addImport(lib_name, published.module);
    // The example reads the same fixtures under `fixture_dir` as the tests, so
    // it needs the same build-created import. `zig build` compiles the example,
    // and a `smoke.zig` that could not find `testdata/` would fail here rather
    // than quietly printing nothing.
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

    // `zig build smoke` deliberately does not depend on the install step:
    // installing is `zig build`'s job and conflating the two would make a smoke
    // run depend on the install layout.
    const run_example = b.addRunArtifact(example);
    run_example.has_side_effects = true;
    if (b.args) |args| run_example.addArgs(args);
    b.step("smoke", "Run the deterministic example program").dependOn(&run_example.step);

    // The test root is `tests.zig`, which names the test blocks; a root that
    // only re-exported them would discover no tests and still exit zero.
    // `addRunArtifact` rather than a plain compile, so this is a real runnable
    // test step for whatever `-Dtarget` names: a foreign target is left to
    // whichever executor the cross-test harness detects, and this build does not
    // decide that.
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

    // The separate consumer package, built as its own `zig build`. It runs when
    // this host can execute the selected target and installs when it cannot,
    // which is `hostCanExecute` rather than a query predicate: a cross-compiled
    // consumer binary cannot run here, and a native one can run under an enabled
    // executor. An install is compile evidence and nothing more.
    b.step("consumer", "Build or run the consumer/ package for the selected target")
        .dependOn(&runConsumer(b, target, optimize, linkage, runtime_loaded).step);

    // The cross-target gate. Compiling the core, the bridge, the translated
    // header, the facade, the tests and the example for each target is what
    // makes this a check of the facade rather than of an unreferenced C++
    // archive: Zig analyses a function body only when something calls it, and
    // `tests.zig` and `smoke.zig` call the facade. Nothing runs here, so every
    // result this step produces is compile evidence and not a claim that a
    // cross-built binary executed.
    const check_step = b.step(
        "check",
        "Compile the core, the bridge, the translated header, the facade, the " ++
            "tests and the example for all six required targets without running " ++
            "any of them",
    );
    if (!target.query.isNative()) {
        add_target_check(b, check_step, target.query, optimize, linkage, runtime_loaded);
    } else {
        // One matrix, whatever the delivery. `-Dlinkage=dynamic` walks the same
        // six targets and reaches `graph.deliveredLinkage` inside each one, so
        // the `wasm32-wasi` cell stops with a message naming it rather than
        // handing back an archive. `-Dlinkage` selects the artifact; it does not
        // select the set of targets.
        for (graph.required_targets) |query| {
            add_target_check(b, check_step, query, optimize, linkage, runtime_loaded);
        }
    }

    // Which kernel set this configuration compiled, which artifact it hands
    // back and which dispatch it uses are facts worth reading out of the build
    // rather than inferring from a cache directory. These are configure-time
    // lines, not gate results: nothing has been compiled when they print, and
    // the kernel name in particular is a *preprocessor* answer that a kernel
    // selection macro computed -- see the module comment on the SIMD-fallback
    // boundary for why no gate may assert on it.
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
        // Dispatch is a separate fact from delivery, and a runtime-loaded build
        // links nothing into the facade module: the caller names a provider with
        // an explicit `load(source)` and the eleven symbols arrive through the
        // platform loader. Printing it here is what keeps "the library is still
        // built and installed" from reading as "the module links it".
        std.debug.print(
            "simdjson: runtime-loaded dispatch (-Druntime=true); the facade module " ++
                "links no archive, a provider is named by an explicit load(source), " ++
                "and a static install cannot itself be one -- an archive is not a " ++
                "file the platform loader can open\n",
            .{},
        );
    }
    if (published.delivered == .dynamic and target.result.ofmt != .elf) {
        // See `build_support/graph.zig`: no version script on ELF, a generated
        // `.def` on COFF, and nothing at all on Mach-O. Said here rather than
        // left to be discovered by `nm`.
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

/// Compiles the full graph, the tests and the example for one matrix target and
/// attaches all of them to `step`.
///
/// Building the test binary and the example is what makes this a check of the
/// facade rather than of an unreferenced archive. The full core closure and the
/// bridge are compiled by the same graph, so a target that cannot build simdjson
/// fails here rather than at the first install. Nothing is run here.
fn add_target_check(
    b: *std.Build,
    step: *std.Build.Step,
    query: std.Target.Query,
    optimize: std.builtin.OptimizeMode,
    linkage: std.builtin.LinkMode,
    runtime_loaded: bool,
) void {
    const cross_target = b.resolveTargetQuery(query);
    // The triple names the cross artifacts. Six targets in one build graph
    // otherwise produce six steps called "simdjson", which makes `--summary all`
    // useless for telling them apart.
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
    // Same reason as the published example above: `smoke.zig` reads the shared
    // fixtures, so a matrix cell's example needs the same build-created import.
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

/// Runs the consumer package as its own `zig build` in `consumer/`.
///
/// The consumer is a separate package on purpose: a manifest dependency here
/// would close a cycle, because its manifest points back at this package by path.
/// Running it as a separate build is what makes the proof real -- that a package
/// which only writes `b.dependency("simdjson", ...)` and `dep.module("simdjson")`
/// gets a working, correctly linked library, with the archive and both runtimes
/// arriving through the module and nothing else.
///
/// Everything this build resolved travels with it: the target and CPU, the
/// optimize mode, the linkage and dispatch shapes, the executor switches, both
/// cache directories, the install prefix, the job width and the summary. An
/// argument left behind would be a proof of a configuration nobody asked for.
///
/// Run when this host can execute the selected target, and install otherwise:
/// `hostCanExecute` asks exactly what `std.Build.Step.Run` asks of a foreign
/// binary, so the decision here and the nested run cannot disagree.
fn runConsumer(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    linkage: std.builtin.LinkMode,
    runtime_loaded: bool,
) *std.Build.Step.Run {
    const triple = target.query.zigTriple(b.allocator) catch @panic("OOM");
    defer b.allocator.free(triple);
    // The same query's other half. The triple above names the architecture, the
    // OS and the ABI; it carries no CPU model and no feature set
    // (`lib/std/Target/Query.zig:421-423`), and `cpu` is a separate option of its
    // own (`lib/std/Build.zig:1479-1483`). `serializeCpu` writes `native` for a
    // query that named no CPU and `baseline` for a cross query that named none,
    // and `Target.Query.parseCpu` recognises both spellings, so the nested
    // `standardTargetOptions` resolves this build's selection rather than one of
    // its own. This is not cosmetic for this package: `-Dcpu` decides which SIMD
    // kernels are compiled in, so dropping it would make the consumer check a
    // different core than the one this build produced.
    const cpu = target.query.serializeCpuAlloc(b.allocator) catch @panic("OOM");
    defer b.allocator.free(cpu);

    // `b.graph.zig_exe` is the compiler running this build script, so the nested
    // build is the same toolchain rather than whatever is on PATH.
    const run = b.addSystemCommand(&.{ b.graph.zig_exe, "build" });
    run.setName("consumer package");
    run.setCwd(b.path("consumer"));
    run.addArg(if (hostCanExecute(b, target)) "run" else "install");
    run.addArg(b.fmt("-Dtarget={s}", .{triple}));
    run.addArg(b.fmt("-Dcpu={s}", .{cpu}));
    run.addArg(b.fmt("-Doptimize={s}", .{@tagName(optimize)}));
    // Both options have to reach the nested build or the consumer would silently
    // check the default graph and say nothing about the configuration that was
    // asked for. Both *spellings* go, not only the true one, so a cell's
    // configuration is stated rather than inferred from a default and neither
    // flag can be dropped on the way down.
    run.addArg(b.fmt("-Dlinkage={s}", .{@tagName(linkage)}));
    run.addArg(b.fmt("-Druntime={s}", .{if (runtime_loaded) "true" else "false"}));
    if (b.enable_darling) run.addArg("-fdarling");
    if (b.enable_qemu) run.addArg("-fqemu");
    if (b.enable_rosetta) run.addArg("-frosetta");
    if (b.enable_wasmtime) run.addArg("-fwasmtime");
    if (b.enable_wine) run.addArg("-fwine");
    if (b.libc_runtimes_dir) |runtimes| run.addArgs(&.{ "--libc-runtimes", runtimes });
    // The nested build carries this workspace's job count and summary in its own
    // command line. Nothing can append a `-j` to a `Run` step's command, so a
    // nested build left to derive its own width takes `cpu_count - 1` instead,
    // and the consumer this step proves would compile at a different width from
    // the build that asked for it -- and at a different width again on whichever
    // machine runs the gate. `--summary all` is for the same reader: the nested
    // build is a separate graph whose steps are named after the consumer
    // package, and a failure inside it is otherwise one unnamed line.
    run.addArg("-j8");
    run.addArg("--summary");
    run.addArg("all");
    // A null `path` means "the current directory", and the working directory is
    // already the consumer package, so the default is right.
    if (b.cache_root.path) |cache| {
        run.addArg("--cache-dir");
        run.addArg(b.fmt("{s}/consumer", .{cache}));
    }
    // The global cache is inherited whole rather than subdirectoryed: it is one
    // shared store of packages and hashes, so a nested build left to resolve its
    // own would write outside the root this workspace approved.
    if (b.graph.global_cache_root.path) |global_cache| {
        run.addArg("--global-cache-dir");
        run.addArg(global_cache);
    }
    // The install prefix this invocation resolved, handed on when the caller
    // named one. A nested `zig build` left to resolve its own installs into
    // `consumer/zig-out` -- a build artefact inside a source package -- rather
    // than into the directory the caller asked for. A relative `--prefix` would
    // resolve against `consumer/`, so it is made absolute before it is handed
    // on. `DESTDIR` needs no forwarding: the nested build inherits the
    // environment this one ran with.
    const default_prefix = b.build_root.join(b.allocator, &.{"zig-out"}) catch @panic("OOM");
    if (!std.mem.eql(u8, b.install_prefix, default_prefix)) {
        const prefix = if (std.fs.path.isAbsolute(b.install_prefix))
            b.install_prefix
        else
            b.pathJoin(&.{ b.graph.cache.cwd, b.install_prefix });
        run.addArg("--prefix");
        run.addArg(prefix);
    }
    // The caller's own arguments, last and behind `--`: `--` is where the build
    // runner stops parsing options and keeps the rest as `b.args`, so this `--`
    // has to follow every argument above. Only what the caller typed after `--`
    // belongs to the program, and `--provider <path>` is how a runtime-loaded
    // consumer names its provider (`consumer/src/main.zig`).
    if (b.args) |args| {
        run.addArg("--");
        run.addArgs(args);
    }
    // The nested build is the step's only observable effect.
    run.has_side_effects = true;
    return run;
}

/// True when this build can execute `target`'s binaries.
///
/// `std.zig.system.getExternalExecutor` (`lib/std/zig/system.zig:42`) is the
/// predicate `std.Build.Step.Run` applies to the artifact it is about to spawn
/// (`lib/std/Build/Step/Run.zig:1268`), and `allow_*` carries this build's own
/// executor switches, so the two cannot disagree. `link_libc` holds in every mode
/// this package builds; the `.qemu` arm carries `Run`'s own second gate.
fn hostCanExecute(b: *std.Build, target: std.Build.ResolvedTarget) bool {
    const host = &b.graph.host.result;
    const candidate = &target.result;
    const options: std.zig.system.GetExternalExecutorOptions = .{
        .allow_darling = b.enable_darling,
        .allow_qemu = b.enable_qemu,
        .allow_wasmtime = b.enable_wasmtime,
        .allow_wine = b.enable_wine,
        // `consumer/` builds its executable with `b.addExecutable` and no
        // linkage, so `Run`'s musl half of `need_cross_libc` never holds here.
        .qemu_fixes_dl = candidate.isGnuLibC() and b.libc_runtimes_dir != null,
        .link_libc = true,
    };
    return switch (std.zig.system.getExternalExecutor(b.graph.io, host, candidate, options)) {
        .native, .rosetta => true,
        // Reachable only for an executor the switches above enabled, each of
        // which `Run` gates on the same switch and nothing else.
        .wine, .wasmtime, .darling => true,
        // Not a yes on its own: `Run` fails a cross GNU libc target given no
        // `--libc-runtimes`, so this step installs it instead. Every other QEMU
        // case still runs.
        .qemu => !(candidate.isGnuLibC() and b.libc_runtimes_dir == null),
        // Same OS and CPU with no dynamic linker to load, or an architecture and
        // system this build has no enabled executor for.
        .bad_dl, .bad_os_or_cpu => false,
    };
}

/// Writes `lib/pkgconfig/simdjson.pc` and installs it.
///
/// Upstream ships a template, `src/simdjson.pc.in`, and this file is the
/// generated result of it. Every field below names the upstream line it comes
/// from, and the two that are *not* upstream's say why.
///
///   * `Name`, `Description`, `Version` -- `src/include/simdjson/simdjson_version.h:7`
///     and `src/simdjson.pc.in:5-8`, whose `Version:` field is the template
///     placeholder `@PROJECT_VERSION@` that `src/CMakeLists.txt:15` supplies. The
///     conventional `.pc` name for the
///     library is `simdjson.pc` and its conventional library name is
///     `-lsimdjson`, which is what a C consumer writes.
///   * `prefix` is `${pcfiledir}/../..` rather than a substituted absolute path.
///     This graph does not know where `--prefix` will point when it writes the
///     file, and pkg-config resolves `${pcfiledir}` against the `.pc` it found,
///     so the installed file is correct wherever the prefix landed -- including
///     a Nix store path that is only known at build time. That is what
///     `devenv.nix:179-181` means by "the pkg-config record is prefix-relative
///     through `${pcfiledir}`".
///   * `Libs` is `-L"${libdir}" -lsimdjson` in both variants, because the library
///     *name* does not change with linkage: a C consumer asks for `-lsimdjson` and
///     the linker resolves it to `libsimdjson.a` or, through the
///     `libsimdjson.so` symlink, to the shared object.
///   * `Libs.private` names the C++ runtime for a **static** consumer only, and
///     nothing at all for a shared one. That asymmetry is `package.nix:134-149`
///     and it is the point: `static` leaves libc and libc++ undefined in
///     `libsimdjson.a`, because a library step archives objects rather than
///     linking them, so whoever links the archive resolves both on their own link
///     line; `dynamic` links both into the image, so a `-lc++` propagated to a
///     shared consumer would advertise a dependency the artifact does not have.
///     Naming one variant and not the other is correct. Naming both would be a
///     second record for the same fact, which is how a delivery and its
///     description start to disagree.
///   * `Cflags` is `-I"${includedir}"` and nothing else. There is no
///     `-DTHREADS_ENABLED=1` here to copy from `simdjson.pc.in:464-468`: upstream's
///     own `Cflags` carries `-DSIMDJSON_THREADS_ENABLED=1` because it is `PUBLIC`
///     on the CMake target (`src/CMakeLists.txt:385`) and so reaches a consumer of
///     the installed headers. This package compiles a C ABI whose only consumer
///     header, `simdjson_bridge.h`, reads none of the four configuration macros
///     (`zig/translate.h` says why), so advertising them here would put a define
///     on a consumer's line that changes nothing about the declarations it
///     describes. A **C++** consumer of the installed `include/simdjson/` tree
///     does need `SIMDJSON_THREADS_ENABLED=1`, and gets it by compiling with it
///     itself or through upstream's own `simdjson.pc`; that asymmetry between
///     the two interfaces is recorded here rather than papered over with a define
///     that is wrong for one of them.
fn add_pkg_config(b: *std.Build, delivered: std.builtin.LinkMode) void {
    const files = b.addWriteFiles();
    // The returned step is bound to the install step. `addInstallFileWithDir`
    // *creates* a `Step.InstallFile` and nothing more -- dropping the return
    // value builds nothing and installs nothing, and the omission is silent: the
    // step exists, it is simply never in the graph, so an install that was
    // missing its `.pc` file would still report success.
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
            // The C++ runtime, for a static consumer only. See the function
            // comment for why the two variants differ.
            if (delivered == .static) " -lc++" else "",
        })),
        .prefix,
        "lib/pkgconfig/simdjson.pc",
    );
    b.getInstallStep().dependOn(&install_pc.step);
}

/// The configuration macros one target resolved to, as one printable line.
///
/// The banner prints what the target being built actually received rather than
/// a literal: two of the five are resolved per target (`graph.cppMacros`), so a
/// fixed string would misreport exactly the cross-target builds the `check` gate
/// exists to compile.
fn macroList(b: *std.Build, macros: []const [2][]const u8) []const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    for (macros) |macro| {
        parts.append(b.allocator, b.fmt("{s}={s}", .{ macro[0], macro[1] })) catch @panic("out of memory");
    }
    return std.mem.join(b.allocator, " ", parts.items) catch @panic("out of memory");
}

/// Installs the carried licence texts and this fork's records under
/// `share/licenses/simdjson/`.
///
/// A private repository removes no upstream obligation. Both of upstream's
/// grants install verbatim -- `src/LICENSE` is the Apache License 2.0 and
/// `src/LICENSE-MIT` is the MIT License, and `src/README.md:269` offers a
/// choice between them -- beside the records this fork added around them:
/// `NOTICE.md` is the per-file inventory, `FORK-LICENSE.md` the grant over the
/// fork's own files, `FORK-NOTES.md` the decisions, `UPSTREAM.md` the pin.
///
/// `build_support/graph.zig` is the only writer of this directory. A second
/// writer is how one output ends up with two licence records that disagree
/// about what they cover, and a licence set that does not match the artifact
/// beside it is the one failure a redistributable binary cannot recover from.
fn install_licence_records(b: *std.Build) void {
    for (upstream_licences) |licence| {
        // Bound, for the reason `add_pkg_config` says.
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