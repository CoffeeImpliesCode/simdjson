// SPDX-License-Identifier: Apache-2.0
//
//! Per-target assembly of the module, the flags and the archive.
//!
//! Every fact this file encodes was read out of a file in this repository, and
//! each says which one. Nothing here is a recollection of how simdjson is
//! usually built, and nothing here restates upstream's own CMake:
//! `src/CMakeLists.txt` is carried unmodified as a record of what upstream does,
//! and no CMake, autotools or `make` step runs in this graph.
//!
//! The one compilation
//! -------------------
//! Upstream's own build has exactly one source file. `src/CMakeLists.txt:204` is
//! `set(SIMDJSON_SOURCES src/simdjson.cpp)` and `:206` is
//! `add_library(simdjson ${SIMDJSON_SOURCES})`, with no `STATIC`/`SHARED`
//! keyword, so the artifact kind follows `BUILD_SHARED_LIBS` (`:193`, default
//! `OFF`). The whole kernel set arrives through that one file's own cascade:
//! `src/src/simdjson.cpp:23-49` is one `#include <KERNEL>.cpp` per
//! `SIMDJSON_IMPLEMENTATION_<ARCH>`, with `fallback.cpp` last at `:47-49`.
//!
//! So this file has two C++ translation units, not a source list to maintain:
//! `src/src/simdjson.cpp` (upstream's core, byte for byte) and `zig/bridge.cc`
//! (this fork's C ABI seam, the only file that compiles `<simdjson.h>`). Both are
//! compiled at the same `-std=c++17`, which is upstream's own default
//! (`src/cmake/developer-options.cmake:125`, applied at `:127-129`). A hand-kept
//! kernel list would be a second declaration of which kernels exist, and nothing
//! checks the two against each other.
//!
//! The four macros, and what each one is for
//! ---------------------------------------
//! They are on both translation units, on every target, in every optimize mode.
//!
//!   * `SIMDJSON_DEVELOPMENT_CHECKS=1`. Upstream adds it in a Debug configuration
//!     only (`src/CMakeLists.txt:376-379`, guarded by the comment at `:374-375`),
//!     and `src/include/simdjson/common_defs.h:304-305` auto-enables it under a
//!     debug build. **This package sets it on every target in every mode, which
//!     is this fork's decision and not upstream's default.** The cost is real and
//!     is stated wherever it matters: `DEFAULT_MAX_DEPTH` (1024,
//!     `src/include/simdjson/base.h:49`) becomes an enforced boundary in a
//!     release build, and `OUT_OF_ORDER_ITERATION` (`src/include/simdjson/error.h:46`,
//!     documented "checked when SIMDJSON_DEVELOPMENT_CHECKS=1") is compiled in.
//!     A depth limit that exists only in Debug is a limit nobody can rely on.
//!     `FORK-NOTES.md` note 8 is the full record.
//!   * `SIMDJSON_THREADS_ENABLED=1`. Upstream's `option(SIMDJSON_ENABLE_THREADS
//!     ... ON)` is at `src/CMakeLists.txt:41` and the define is added `PUBLIC` at
//!     `:382-386`, so it reaches the *installed headers'* consumers as well as
//!     the library's own; `simdjson.pc.in` puts it in `Cflags` for the same
//!     reason. The macro gates nothing on the On-Demand path and this package
//!     does not claim it does. It is passed so that a C++ consumer who links the
//!     delivered `libsimdjson` and includes the installed `include/simdjson/`
//!     tree -- which this package ships, whole and unmodified -- is not handed
//!     different declarations from the ones the library was compiled with.
//!   * `SIMDJSON_ENABLE_NAN_INF=0`. The header already defaults this to 0
//!     (`src/include/simdjson/common_defs.h:61-63`) and `src/CMakeLists.txt:355`
//!     has the CMake option default `OFF`. It is passed explicitly so that the
//!     refusal of `{"a":NaN}` is this package's stated configuration rather than
//!     an inherited one that would change silently if upstream moved the default.
//!   * `SIMDJSON_EXCEPTIONS=0`, with `-fno-exceptions -fno-rtti`. Upstream
//!     supports this configuration itself: `src/cmake/exception-flags.cmake:1` is
//!     the option, `:5` adds the define `PUBLIC` when it is `OFF` and `:27` adds
//!     `-fno-exceptions` for GCC, and `src/include/simdjson/common_defs.h:53-59`
//!     makes the header agree on its own from `__cpp_exceptions`/`_CPPUNWIND`.
//!     On-Demand accessors are `noexcept` and report through `simdjson_result<T>`,
//!     which is why the exception-free route is the intended one rather than a
//!     compromise.
//!
//! Because the On-Demand path needs no exceptions, this module sets
//! `link_libc` and `link_libcpp` and takes Zig's own bundled libc++ rather than
//! naming an external C++ runtime, let alone an external WASI SDK sysroot.
//!
//! Two include paths, both inside `src/`
//! -----------------------------------
//! `src/src/simdjson.cpp:3` is `#include <base.h>`, and `base.h` is
//! `src/src/base.h`; `:15-17` are `<generic/dependencies.h>`,
//! `<generic/stage1/dependencies.h>` and `<generic/stage2/dependencies.h>`, all
//! under `src/src/`. `:14` is `<simdjson/generic/dependencies.h>`, which is
//! `src/include/`. So `src/src` and `src/include` are the two paths, and
//! `zig/bridge.cc:35` reaches `<simdjson.h>` -- `src/include/simdjson.h` --
//! through the second of them. `zig/bridge.cc:13` also includes `"bridge.h"`,
//! its own neighbour in `zig/`, by quoted name.
//!
//! No version script, and one `.def`
//! --------------------------------
//! On ELF there is no version script. `zig/bridge.h` is plain C99 with
//! `extern "C"` guards (`:120-128`, `:679-683`) and carries no visibility macro,
//! and this package's externally linked ABI is eleven functions and no data
//! symbol -- see `bridge_abi_symbols` below. Upstream takes the opposite and
//! simpler route: `src/CMakeLists.txt:256` sets `WINDOWS_EXPORT_ALL_SYMBOLS YES`
//! on the target and does nothing about ELF visibility.
//!
//! On COFF a module-definition file is the only mechanism available, because
//! nothing in `zig/bridge.h` carries `__declspec(dllexport)` and the header
//! cannot be given one without breaking the C translation the same header exists
//! to serve. COFF has no "export everything" default, so the eleven names are
//! written into a generated `.def`. It is generated rather than hand-maintained,
//! so a header edit that added an entry point could not leave it behind.
//!
//! Darwin has no equivalent of either mechanism, and this file does not claim a
//! clean export surface there. A Darwin consumer must select by name.
//!
//! `-Dlinkage=dynamic` on a target that cannot carry one
//! -----------------------------------------------------
//! `std.Target.DynamicLinker.kind` is `.none` for WASI
//! (`lib/std/Target.zig:2345`), so a `.so` there is a file nothing can open.
//! The request is refused with a message naming the target rather than answered
//! with an archive, and `wasm32-wasi` stays in `required_targets` and is
//! covered by its static build.
//!
//! Windows is the reason this is a decision and not a lookup.
//! `DynamicLinker.kind` is `.none` there too, but only because a PE/COFF image
//! has no interpreter path -- its imports are resolved by the loader inside the
//! OS -- so a Windows target does carry a shared object, as a DLL. Keying the
//! refusal on `.none` would wrongly refuse the platform whose shared-object story
//! is most conventional. The predicate is "can a shared object exist here at
//! all", and Windows is named separately from WASI for that reason. The two
//! families must not be folded into one predicate.
//!
//! What this file is not
//! ---------------------
//! It is not the whole build graph. `build.zig` owns the options, the steps, the
//! install layout, the generated `simdjson.pc`, the licence records and the
//! cross-target matrix; this file owns one target's module, flags and archive,
//! so that `-Dtarget=`, the `check` matrix and a nested consumer build all
//! assemble a target the same way rather than three ways.
const std = @import("std");

/// The runtime-loading build half, owned by the API role. It supplies the one
/// module that resolves the eleven entry points through the platform loader
/// instead of a link line; see `runtime/graph.zig` for what it builds and, more
/// usefully, for the one thing a caller must not do (link the archive into a
/// module that imports that dispatch).
const runtime_graph = @import("../runtime/graph.zig");

/// The package name, the artifact name and the name a dependent writes in its
/// dependency map. All three are this one string, and `zig/root.zig` reaches
/// this module as `dep.module("simdjson")`. It is also what the runtime dispatch
/// reports in its pre-load panic, because `runtime/graph.zig` passes the same
/// name to `runtime/generate.zig --library`.
pub const artifact_name = "simdjson";

/// The C ABI this package publishes: eleven functions and no data symbol.
///
/// `runtime/library.zig` binds these same eleven names as a provider's
/// requirement and refuses a provider that does not export all of them, and
/// `zig/bridge.h` declares each one unconditionally -- there is no `#if` around
/// any declaration in it and none around any definition in `zig/bridge.cc`. The
/// list is written out rather than derived because a derived list would have to
/// parse a header at configure time, and a parsed list would then be a second
/// declaration of the same surface that a header edit could silently diverge
/// from. This one is a build-time assertion about the *shape* of the ABI: it
/// has to name every name in the header, and `zig/bridge.cc`'s `static_assert`
/// block is what pins the values.
pub const bridge_abi_symbols = [_][]const u8{
    "simdjson_br_version",
    "simdjson_br_builtin_implementation",
    "simdjson_br_active_implementation",
    "simdjson_br_active_implementation_description",
    "simdjson_br_available_implementation_count",
    "simdjson_br_available_implementation_name",
    "simdjson_br_validate_utf8",
    "simdjson_br_open",
    "simdjson_br_destroy",
    "simdjson_br_input_size",
    "simdjson_br_walk",
};

/// The six targets this SDK's `check` matrix compiles.
///
/// Not a preference list and not a subset: `zig build check` walks exactly
/// these, compiling the core, the bridge, the translated header, the facade,
/// the tests and the example for each without running any of them. `devenv.nix`
/// names the same six in its `sdk:check` task and `package.nix:105-108` names
/// the same six when it says what a Nix build is *not*, which is why the list
/// lives here and is referred to rather than restated.
///
///   * `x86_64-linux-gnu` and `aarch64-linux-gnu` -- the two Linux ABIs, and
///     the two answers to the SIMD question: at `-Dcpu=baseline` x86-64
///     compiles the scalar `fallback` kernel alone
///     (`src/include/simdjson/implementation_detection.h:75-79,101-105,137-145`),
///     while aarch64 gets `arm64` because NEON is part of that baseline (`:31-35`).
///   * `aarch64-macos-none` -- Darwin has no version script and no `.def`
///     mechanism, so this row is also the row that shows what a Mach-O shared
///     object from this graph exports.
///   * `x86_64-windows-gnu` -- the row that needs the generated `.def`, because
///     `zig/bridge.h` cannot carry `__declspec(dllexport)`.
///   * `riscv64-linux-gnu` -- where `rvv-vls` is the SIMD question
///     (`src/src/simdjson.cpp:44-46`).
///   * `wasm32-wasi` -- here because the On-Demand path is exception-free, so
///     this closure compiles and links with no external WASI SDK sysroot at all.
///     `-Dlinkage=dynamic` is refused for it; its static build is what covers
///     the row.
pub const required_targets = [_]std.Target.Query{
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .aarch64, .os_tag = .macos, .abi = .none },
    .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu },
    .{ .cpu_arch = .riscv64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .wasm32, .os_tag = .wasi },
};

/// Where the vendored upstream source lives.
///
/// `src/` is simdjson 5.0.2's own release tree, extracted whole. It is named in
/// `build.zig.zon` `.paths` so a dependent receives upstream's project rather
/// than a hand-picked subset of it, which is why a build that needed a file
/// outside the closure below would have to edit upstream to get one.
pub const source_dir = "src";

/// The two include directories `src/src/simdjson.cpp` needs.
///
/// Ordered as the module comment states: the internal sources directory first,
/// then the public one, so `<base.h>` and `<generic/...>` resolve the way
/// `src/src/simdjson.cpp` writes them and `<simdjson/...>` resolves the way a C++
/// consumer writes it.
const include_dirs = [_][]const u8{
    source_dir ++ "/src",
    source_dir ++ "/include",
};

/// This fork's own C ABI seam, and the one C++ translation unit that is not
/// upstream's bytes. It is the only place `<simdjson.h>` is compiled.
const bridge_source = "zig/bridge.cc";

/// The header the translation step reads, and the module root it produces.
const translate_header = "zig/translate.h";

/// The Zig facade, registered as `artifact_name` for a dependent and created
/// privately for a cross-target check.
const facade_source = "zig/root.zig";

/// The flags upstream's own translation unit carries.
///
/// `-fno-exceptions` and `-fno-rtti` are the module comment's fourth macro
/// spelled as flags, and `SIMDJSON_EXCEPTIONS=0` goes on the same line as a
/// `-D` because upstream adds the define and the flag together
/// (`src/cmake/exception-flags.cmake:5,27`). That pairing is a property of
/// upstream's *core* and is reproduced here unchanged.
///
/// `-fno-exceptions` is not passed to `zig/bridge.cc`; see `bridge_cpp_flags`.
const core_cpp_flags = [_][]const u8{
    "-std=c++17",
    "-fno-exceptions",
    "-fno-rtti",
};

/// The flags this fork's own C ABI seam carries.
///
/// The same `-std=c++17` and the same four macros, and the same four
/// configuration macros as the core, so the declarations it calls and the
/// definitions it links against cannot have been produced by two different
/// configurations. `-fno-rtti` is kept: nothing in the seam uses `typeid` or
/// `dynamic_cast`.
///
/// `-fno-exceptions` is dropped, and this is the one flag the two units do not
/// share. `zig/bridge.cc` reports an allocation failure as
/// `SIMDJSON_BRIDGE_OUT_OF_MEMORY` from five entry points
/// (`zig/bridge.cc:581,601,629,682,783` and their `catch` clauses), and that
/// status is in the published C ABI (`zig/bridge.h:146`) and in the Zig
/// facade's `Error.OutOfMemory` (`zig/root.zig:311,519`). Clang rejects `try`
/// outright on a `-fno-exceptions` translation unit
/// (`error: cannot use 'try' with exceptions disabled`), so the flag and the
/// catch cannot both stand.
///
/// `SIMDJSON_EXCEPTIONS=0` still holds on this unit, and that is the define
/// that decides whether *upstream's* accessors throw: it removes
/// `simdjson_result<T>`'s converting operator
/// (`src/include/simdjson/error.h:180-225`), so every result is unwrapped with
/// an explicit `.get()` and no upstream accessor can raise. What remains
/// catchable here is libc++'s own `std::bad_alloc` from `std::string`,
/// `std::unique_ptr` and `new`, which is exactly what the five handlers
/// claim. Enabling the language feature does not turn on upstream's throwing
/// interface; the macro does, and it stays 0. See `FORK-NOTES.md` note 13.
const bridge_cpp_flags = [_][]const u8{
    "-std=c++17",
    "-fno-rtti",
};

/// The configuration macros for one target, as `(name, value)` pairs.
///
/// Two of them are this package's decision and are the same for every target:
/// `SIMDJSON_DEVELOPMENT_CHECKS=1` and `SIMDJSON_ENABLE_NAN_INF=0` (see
/// `FORK-NOTES.md` notes 8 and 5) and `SIMDJSON_EXCEPTIONS=0`.
///
/// Two are properties of the target being built rather than of this package, and
/// upstream has a switch for each. They are resolved here, for the target this
/// graph is assembling, and never for the host: there is no host-configuration
/// path in this file, and `addLibrary` is a per-target call, so the honest form
/// of a target-varying macro is a macro read beside that target.
///
///   * `SIMDJSON_THREADS_ENABLED` turns on `document_stream`'s worker thread,
///     which is `std::thread` (`src/include/simdjson/dom/document_stream.h:46,61,62`).
///     Upstream adds the define only when its own `SIMDJSON_ENABLE_THREADS` is
///     on *and* `find_package(Threads)` succeeded
///     (`src/CMakeLists.txt:382-386`), so a target with no threads is an
///     upstream-supported configuration rather than a degraded one.
///   * `SIMDJSON_AVX512_ALLOWED` is upstream's own switch for exactly this:
///     `common_defs.h:385-388` defines it to 1 only "by default", so a build
///     whose target cannot run the icelake kernel says so. Without it the
///     icelake kernel is compiled in by default on every x86-64 target
///     (`implementation_detection.h:37-41`) for run-time selection, and its
///     AVX-512 intrinsics then have to compile without the ISA flags that a
///     baseline x86-64 CPU model does not set.
///   * `SIMDJSON_IMPLEMENTATION_ARM64` is upstream's own switch for the arm64
///     kernel, in the same `#ifndef` form as the AVX-512 one
///     (`implementation_detection.h:28-33`), and it is passed as 0 for a
///     big-endian AArch64 target. That kernel is byte-order dependent: its
///     stage-1 table and shuffle masks are built by reinterpreting 64-bit
///     integers as byte vectors
///     (`src/include/simdjson/arm64/simd.h:258-259`, and the lane literal at
///     `:264`), which places the table bytes in the opposite lane order on a
///     big-endian target. Upstream guards only its number parsing
///     (`src/include/simdjson/arm64/numberparsing_defs.h:54-58`), and observed
///     on `aarch64_be-linux` the kernel accepts malformed documents that the
///     same kernel refuses little-endian. Leaving the switch alone selects
///     upstream's scalar `fallback` kernel instead, which is correct on a
///     big-endian target -- `s390x-linux` runs it little-endian-agnostic and is
///     clean once the UTF-8 refusal above is in place -- and is a
///     build-configuration answer rather than an edit to a vendored header.
pub fn cppMacros(b: *std.Build, target: std.Build.ResolvedTarget) []const [2][]const u8 {
    var macros: std.ArrayList([2][]const u8) = .empty;
    const gpa = b.allocator;
    macros.append(gpa, .{ "SIMDJSON_DEVELOPMENT_CHECKS", "1" }) catch @panic("out of memory");
    if (targetHasThreads(target)) {
        macros.append(gpa, .{ "SIMDJSON_THREADS_ENABLED", "1" }) catch @panic("out of memory");
    }
    macros.append(gpa, .{ "SIMDJSON_ENABLE_NAN_INF", "0" }) catch @panic("out of memory");
    macros.append(gpa, .{ "SIMDJSON_EXCEPTIONS", "0" }) catch @panic("out of memory");
    if (!targetCanRunAvx512(target)) {
        macros.append(gpa, .{ "SIMDJSON_AVX512_ALLOWED", "0" }) catch @panic("out of memory");
    }
    if (!targetCanRunArm64Kernel(target)) {
        macros.append(gpa, .{ "SIMDJSON_IMPLEMENTATION_ARM64", "0" }) catch @panic("out of memory");
    }
    if (targetNeedsLoongArchHwcap(target)) {
        macros.append(gpa, .{ "HWCAP_LOONGARCH_LSX", "(1 << 4)" }) catch @panic("out of memory");
        macros.append(gpa, .{ "HWCAP_LOONGARCH_LASX", "(1 << 5)" }) catch @panic("out of memory");
    }
    return macros.items;
}

/// Whether the target's C++ runtime provides `std::thread`.
///
/// libc++ declares it only where the platform has threads, so on WebAssembly
/// the header that declares `simdjson::dom::document_stream`'s worker does not
/// compile at all with `SIMDJSON_THREADS_ENABLED` defined. The answer is a
/// property of the target's platform, not of this package's flags, and upstream
/// arrives at the same answer through `find_package(Threads)`.
fn targetHasThreads(target: std.Build.ResolvedTarget) bool {
    return target.result.os.tag != .wasi;
}

/// Whether the target's CPU model can run the icelake kernel.
///
/// The question is asked of the resolved target, so `-Dcpu=` decides it: a
/// caller who builds for a host that has AVX-512 keeps the kernel, and the six
/// baseline cross targets do not. A non-x86-64 target is not asked, because
/// `SIMDJSON_AVX512_ALLOWED` is read only by the x86-64 implementation detection.
fn targetCanRunAvx512(target: std.Build.ResolvedTarget) bool {
    if (target.result.cpu.arch != .x86_64) return true;
    return std.Target.x86.featureSetHas(target.result.cpu.features, .avx512f);
}

/// Whether the target's byte order lets the arm64 kernel read a block of input
/// the way its masks were written for.
///
/// The question is asked of the resolved target's architecture, never of the
/// host, because `addLibrary` is a per-target call. Zig carries the byte order
/// in the architecture itself -- the big-endian AArch64 target is
/// `Arch.aarch64_be`, a distinct value rather than a flag on `aarch64`
/// (`lib/std/Target.zig:1328`) -- so both are named. A non-AArch64 target is not
/// asked at all: `SIMDJSON_IMPLEMENTATION_ARM64` is read only by upstream's
/// AArch64 implementation detection
/// (`src/include/simdjson/implementation_detection.h:28-33`), and for every
/// other architecture the arm64 kernel is not a candidate to begin with.
fn targetCanRunArm64Kernel(target: std.Build.ResolvedTarget) bool {
    return switch (target.result.cpu.arch) {
        .aarch64 => true,
        .aarch64_be => false,
        else => true,
    };
}

/// Whether the target's C library headers leave upstream's LoongArch ISA
/// detection without the two kernel capability constants it reads.
///
/// `src/src/internal/isadetection.h:298,301` reads `HWCAP_LOONGARCH_LSX` and
/// `HWCAP_LOONGARCH_LASX` straight out of `<sys/auxv.h>`, with no `#ifndef` guard
/// of its own, and the only Linux headers that define them are the kernel's
/// `arch/loongarch/include/uapi/asm/hwcap.h`, which a C library does not have to
/// ship. The pinned toolchain does not, and the cell did not compile:
/// `use of undeclared identifier 'HWCAP_LOONGARCH_LSX'`.
///
/// Upstream already answers this exact gap for its AArch64 branch, in the same
/// file and for the same reason: it defines the kernel's own values itself,
/// behind `#ifndef` guards, because it deliberately does not include
/// `<asm/hwcap.h>` (`:86-97`). The two values passed here are those kernel
/// constants, `HWCAP_LOONGARCH_LSX (1 << 4)` and `HWCAP_LOONGARCH_LASX (1 << 5)`
/// (Linux `arch/loongarch/include/uapi/asm/hwcap.h:10-11`). They are passed as
/// the same token sequence the kernel header uses, so a toolchain that does
/// define them redefines them identically and no diagnostic follows.
///
/// This is asked of the resolved target, never of the host, and only for
/// `loongarch64`, where upstream's LoongArch branch is the only code that reads
/// them.
fn targetNeedsLoongArchHwcap(target: std.Build.ResolvedTarget) bool {
    return target.result.cpu.arch == .loongarch64;
}

/// Upstream's release, read out of `src/include/simdjson/simdjson_version.h:7`
/// (`#define SIMDJSON_VERSION "5.0.2"`), which `src/CMakeLists.txt:15` and the
/// `Version:` template at `simdjson.pc.in:8` both resolve to.
///
/// `build.zig.zon .version` carries the same string and `build()` refuses to
/// configure when the two disagree, so this constant, the manifest, the
/// generated `simdjson.pc` and the installed soname cannot describe three
/// different releases.
pub const upstream_version: std.SemanticVersion = .{ .major = 5, .minor = 0, .patch = 2 };

/// The shared object's ABI version, which is **not** the release number.
///
/// `src/CMakeLists.txt:32-33` are `set(SIMDJSON_LIB_VERSION "34.0.0" ...)` and
/// `set(SIMDJSON_LIB_SOVERSION "34" ...)`, with the comment at `:31` "These
/// version numbers are modified by tools/release.py", applied as `VERSION` and
/// `SOVERSION` at `:253-254`. `std.SemanticVersion` has exactly three
/// components where an ELF shared object has four, so `{ .major = 34, .minor = 0,
/// .patch = 0 }` produces exactly the two names upstream's own build would:
/// `libsimdjson.so.34.0.0` with soname `libsimdjson.so.34`.
///
/// The runtime-loaded route names that soname in every document that shows a
/// provider path, and `UPSTREAM.md` says why the two numbers differ.
/// `FORK-NOTES.md` note 19 is the record.
pub const abi_version: std.SemanticVersion = .{ .major = 34, .minor = 0, .patch = 0 };

/// What one caller asks this file to build.
pub const Options = struct {
    /// Which delivery the caller asked for. What it selects is the artifact and
    /// nothing else about the compilation: both variants compile the same two
    /// translation units at the same flags.
    requested: std.builtin.LinkMode,
    /// Whether the module dispatches through the runtime loader instead of a
    /// link line. Orthogonal to `requested`, which still decides which artifact
    /// this target builds and installs: delivery and dispatch are separate
    /// questions, and the whole point of the runtime route is that a caller may
    /// name a provider this tree did not build.
    runtime_loaded: bool,
    /// Whether the module is registered under `artifact_name` for a dependent
    /// (`dep.module("simdjson")`) or created privately.
    ///
    /// A cross-target check needs the private form. Modules are registered by
    /// name against the whole build graph, so registering `simdjson` once per
    /// matrix target would leave only the last of them reachable and silently
    /// stop checking the rest.
    public: bool,
};

/// One target's library and facade.
pub const Graph = struct {
    /// The compiled library. This package has no system mode -- see the module
    /// comment in `build.zig` -- so this is never null.
    library: *std.Build.Step.Compile,
    /// The facade module, with `c` bound to the translated `zig/bridge.h` for
    /// the library this graph compiled, and `rt` bound to the loader core.
    module: *std.Build.Module,
    /// The translation step itself. `build.zig` hands it to `runtime/graph.zig`
    /// under `-Druntime`, and it is the step whose output the generated
    /// dispatch describes.
    translate: *std.Build.Step.TranslateC,
    /// The linkage this target can actually carry, after the refusal below.
    delivered: std.builtin.LinkMode,
    /// The artifact name this graph reports. The published graph says
    /// `artifact_name`; a check graph carries the target triple, because six
    /// steps all called "simdjson" make `--summary all` impossible to read.
    name: []const u8,
};

/// Builds one target's library and facade.
///
/// `build` calls this for the published graph and for `-Dtarget=`, and
/// `build_support/graph.zig` is also reached once per matrix cell from
/// `build`'s own `add_target_check`. Every route into a target's assembly goes
/// through here, so naming a target by hand and walking the matrix cannot be
/// given two different answers. Nothing has been compiled when this returns: it
/// is a configure-time call, and the `-Dlinkage=dynamic` refusal below is a
/// stop rather than a warning hung off a later step.
pub fn addGraph(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    options: Options,
) Graph {
    const delivered = deliveredLinkage(target, options.requested);
    const name = artifactName(b, target, options.public);

    const library = addLibrary(b, target, optimize, delivered, name);
    const translate = addTranslate(b, target, optimize);

    const module = if (options.public)
        b.addModule(artifact_name, .{
            .root_source_file = b.path(facade_source),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        })
    else
        b.createModule(.{
            .root_source_file = b.path(facade_source),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });

    if (options.runtime_loaded) {
        // A loaded provider must arrive through the platform loader, so the
        // link line names nothing. Linking the archive as well would make the
        // linker resolve the same symbols statically and the runtime route
        // would quietly be a linked one. The artifact is still built and
        // installed: delivery and dispatch are separate questions, and the whole
        // point of the mode is that a caller may name a provider this tree did
        // not build.
        //
        // `runtime/graph.zig:createModule` creates the one core-module instance
        // the generated dispatch uses and re-exports `LoadSource`/`LoadError`
        // from it, so a *second* core module is not created here. Two instances
        // would be two sets of types, and `simdjson.load(source)` would be
        // handing the facade's type to a function expecting the dispatch's.
        module.addImport("c", runtime_graph.createModule(b, translate, target, optimize));
    } else {
        // The translated header is imported, never registered. `b.addModule("c")`
        // would make `dep.module("c")` resolve and hand a dependent the same
        // declarations without the library that satisfies them; `simdjson.c` on
        // the facade is the supported way in and carries the facade's own
        // linkage.
        module.addImport("c", translate.createModule());
        module.addImport("rt", runtime_graph.createCoreModule(b, target, optimize));
        module.linkLibrary(library);
    }

    // The same include paths the core was compiled with, on the module a
    // dependent actually imports, so a dependent that compiles its own C++
    // against this package finds the headers the core was built against rather
    // than whatever is installed on the machine it happens to build on. The
    // `zig/` directory is there too, so a dependent that wants to include
    // `simdjson_bridge.h` reaches it by its own name.
    for (include_dirs) |dir| module.addIncludePath(b.path(dir));
    module.addIncludePath(b.path("zig"));

    return .{
        .library = library,
        .module = module,
        .translate = translate,
        .delivered = delivered,
        .name = name,
    };
}

/// Compiles the two C++ translation units and installs the delivery tree.
///
/// Two units, one include-path pair, one flag list, one macro set -- the module
/// comment says where each comes from. What a shared artifact adds is its own
/// requirements and nothing about the compilation: the soname, position-
/// independent code and, on COFF, the generated `.def`.
fn addLibrary(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    delivered: std.builtin.LinkMode,
    name: []const u8,
) *std.Build.Step.Compile {
    const files = b.addWriteFiles();

    const library = b.addLibrary(.{
        .name = name,
        .linkage = delivered,
        // Null for a static archive, which has no soname and no versioned file
        // name. See `abi_version` for where the numbers come from.
        .version = if (delivered == .dynamic) abi_version else null,
        // COFF only. ELF deliberately gets no version script, and Darwin gets
        // neither: see the module comment.
        .win32_module_definition = if (delivered == .dynamic and target.result.ofmt == .coff)
            files.add("simdjson.def", def_file)
        else
            null,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            // libc and the C++ runtime. `zig/bridge.cc` uses `std::unique_ptr`,
            // `std::string` and `std::string_view`, and `src/src/simdjson.cpp`
            // uses the standard library throughout, so neither unit is
            // freestanding. Zig's own bundled libc++ is the whole C++ runtime
            // here, which is why no external sysroot is named.
            .link_libc = true,
            .link_libcpp = true,
            // A shared library is position-independent whether or not this says
            // so; naming it makes the requirement explicit.
            .pic = if (delivered == .dynamic) true else null,
        }),
    });
    const module = library.root_module;

    for (include_dirs) |dir| module.addIncludePath(b.path(dir));
    // `zig/bridge.cc:13` includes `"bridge.h"`, its own neighbour. The quoted
    // include resolves against the including file's directory, so this path is
    // belt and braces rather than the mechanism -- it is here so a future seam
    // file in another directory is covered by the same statement.
    module.addIncludePath(b.path("zig"));

    for (cppMacros(b, target)) |macro| module.addCMacro(macro[0], macro[1]);

    // Upstream's own core, byte for byte, at its own default standard.
    module.addCSourceFile(.{
        .file = b.path(source_dir ++ "/src/simdjson.cpp"),
        .flags = &core_cpp_flags,
        .language = .cpp,
    });
    // This fork's seam, compiled at the same standard and under the same macros,
    // so the declarations it calls and the definitions it links against cannot
    // have been produced by two different configurations.
    module.addCSourceFile(.{
        .file = b.path(bridge_source),
        .flags = &bridge_cpp_flags,
        .language = .cpp,
    });

    installHeaders(b, library);
    return library;
}

/// Translates `zig/translate.h` into the `c` module the facade imports.
///
/// That header's whole job is to name this package's own `zig/bridge.h`: it
/// includes nothing else, and `zig/bridge.h:123-124` includes only `<stddef.h>`
/// and `<stdint.h>`, neither of which declares a function. That is why
/// `runtime/graph.zig` has an empty `libc_noise` list: there is no C-library
/// declaration in the translation for a provider to be asked for.
///
/// The macros below are not the four C++ ones. `zig/bridge.h` is plain C99 and
/// reads none of them; what it *does* read is
/// `SIMDJSON_BRIDGE_NO_OFFSET` (`zig/bridge.h:311`), which is a `#define` in the
/// header itself and so needs nothing on this line. The translation gets the
/// include paths so a future aggregate header that reached `zig/bridge.h` by
/// angle brackets is covered on the same route the C++ units use.
fn addTranslate(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.TranslateC {
    const translate = b.addTranslateC(.{
        .root_source_file = b.path(translate_header),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    for (include_dirs) |dir| translate.addIncludePath(b.path(dir));
    translate.addIncludePath(b.path("zig"));
    return translate;
}

/// Installs everything a C or C++ consumer of this package needs beside the
/// library, so that installing the artifact is enough.
///
/// Four things, and the shape of the tree is the one `package.nix:231-237`
/// describes:
///
///   * `include/simdjson/` -- upstream's **complete** public header tree,
///     unmodified. 234 files, installed as a directory rather than a list of
///     five hand-named headers, because the directory is the interface: a C++
///     consumer that includes `<simdjson/ondemand.h>` reaches
///     `include/simdjson/builtin/ondemand.h` behind it, and a header list that
///     had to be edited when upstream added a file would be a second
///     declaration of the same closure. Nothing here is dropped for being
///     uncompiled by *this* graph: the DOM API, `document_stream`, the minifier
///     and compile-time JSON are all absent from the Zig facade and all
///     reachable from this installed tree.
///   * `include/simdjson.h` -- the umbrella upstream's own documentation tells a
///     consumer to include (`src/include/simdjson.h:11`), beside that tree.
///   * `include/simdjson_bridge.h` -- this fork's C ABI, installed under a
///     different name on purpose. `zig/bridge.h` and the installed copy are the
///     same bytes and the same ABI, but the installed name says what the header
///     is: the one a C consumer compiles to reach a `libsimdjson` that was
///     built here, which is *not* upstream's C++ API and is not reachable any
///     other way from C.
///   * nothing else. No `.pc`, no licence file and no generated dispatch are
///     installed from here; `build.zig` writes those, because a second writer is
///     how one output ends up with two records that disagree about what they
///     cover.
fn installHeaders(b: *std.Build, library: *std.Build.Step.Compile) void {
    // A directory install, so the whole tree travels and no per-file list
    // exists to fall behind upstream.
    const dir = b.addInstallDirectory(.{
        .source_dir = b.path(source_dir ++ "/include/simdjson"),
        .install_dir = .prefix,
        .install_subdir = "include/simdjson",
    });
    b.getInstallStep().dependOn(&dir.step);

    for ([_][]const u8{ source_dir ++ "/include/simdjson.h", "zig/bridge.h" }) |header| {
        library.installHeader(b.path(header), switch (std.mem.eql(u8, header, "zig/bridge.h")) {
            true => "simdjson_bridge.h",
            false => "simdjson.h",
        });
    }
}

/// The generated COFF module definition.
///
/// One `EXPORTS` line per name in `bridge_abi_symbols`, so a header that gained
/// an entry point and a `.def` that did not is a build failure rather than a
/// DLL missing a function at link time in a consumer. No `DATA` keyword appears,
/// and that is the whole of this package's externally linked ABI: eleven
/// functions and no data symbol (`runtime/library.zig` says the same about what
/// a provider must export).
/// Composed at comptime rather than built with a writer: the input is a
/// comptime-known array of comptime-known names, so a runtime loop and a
/// runtime allocation would both be work whose result cannot vary.
const def_file = def_file_comptime();

/// The body of `def_file`, as a comptime block rather than a `for` expression:
/// Zig 0.16 has no `for`-expression, so the accumulation is a `var` rebinding.
/// Same result, same comptime evaluation.
fn def_file_comptime() []const u8 {
    const indent = "    ";
    var out: []const u8 = "EXPORTS\n";
    for (bridge_abi_symbols) |symbol| out = out ++ indent ++ symbol ++ "\n";
    return out;
}

/// The name a compiled artifact carries in this build graph.
///
/// The published graph installs `libsimdjson.a` -- or `libsimdjson.so.34.0.0`,
/// which is the name a C consumer's `-lsimdjson` resolves to through the
/// `libsimdjson.so` symlink beside it. A check graph installs nothing, so its
/// artifacts carry the target triple instead: six targets share one build graph
/// and six steps all called "simdjson" make `--summary all` impossible to read.
pub fn artifactName(b: *std.Build, target: std.Build.ResolvedTarget, public: bool) []const u8 {
    if (public) return artifact_name;
    const triple = target.result.zigTriple(b.allocator) catch @panic("unspellable target");
    return b.fmt("{s}-{s}", .{ artifact_name, triple });
}

/// Whether this target's OS has a dynamic linker at all, and therefore whether
/// it can carry a shared object.
///
/// Windows uses its PE/COFF loader without an interpreter path -- its imports
/// are resolved by the loader inside the OS -- so it does carry one, as a DLL.
/// Every other shared target needs a real dynamic linker. WASI has neither:
/// `std.Target.DynamicLinker.kind` is `.none` for it
/// (`lib/std/Target.zig:2345`, listed at `:2401`), and a `.so` there is a file
/// nothing can open.
pub fn targetHasDynamicLinker(target: std.Build.ResolvedTarget) bool {
    return target.result.os.tag == .windows or
        std.Target.DynamicLinker.kind(target.result.os.tag) != .none;
}

/// The linkage this target delivers, or a refusal when it cannot carry what was
/// asked for.
///
/// There is no substitution here, deliberately. Handing back a static archive
/// under a request for a shared object would be a result the caller did not ask
/// for and cannot tell from support: a loader would open nothing, or -- worse --
/// a linker would resolve the archive and the caller would believe it had a
/// shared dependency. So a shared request on a target that cannot carry one
/// stops here, with a message naming the target, the reason, and the way out.
///
/// `addGraph` is the only caller, so the artifact, the declarations paired with
/// it, the generated `simdjson.pc` and the installed soname cannot describe
/// different linkages.
pub fn deliveredLinkage(
    target: std.Build.ResolvedTarget,
    requested: std.builtin.LinkMode,
) std.builtin.LinkMode {
    if (requested == .dynamic and !targetHasDynamicLinker(target)) {
        // `std.debug.panic` with a format string, not `@panic` on a
        // concatenated one: `@tagName` of a run-time tag is not comptime known
        // and `++` on a slice has to be, so the message is formatted at run
        // time.
        std.debug.panic(
            "simdjson: -Dlinkage=dynamic was asked for {s}, which has no dynamic " ++
                "linker: std.Target.DynamicLinker.kind is .none for it, so it cannot " ++
                "carry a shared object at all. This build does not substitute a static " ++
                "archive for a requested shared object. Build that target with the " ++
                "default -Dlinkage=static, which is what upstream's own " ++
                "src/CMakeLists.txt:206 produces when BUILD_SHARED_LIBS is OFF (:193), " ++
                "and what its single-translation-unit core is written for. That target " ++
                "stays in the check matrix and is covered by its static build.",
            .{@tagName(target.result.os.tag)},
        );
    }
    return requested;
}