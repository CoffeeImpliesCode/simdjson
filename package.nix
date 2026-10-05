# Source-only package derivation for the simdjson Zig SDK.
#
# One file, consumed by both flake.nix and devenv.nix, so the two entry points
# cannot describe different packages. It builds nothing but this repository: the
# native source is upstream's `src/`, the complete simdjson 5.0.2 release tree
# imported whole, and `build.zig` owns every compile flag and the whole installed
# layout. Nothing here restates a C++ flag, fetches a tarball, reaches into a
# sibling checkout, or installs an artifact of its own.
#
# Two facts about simdjson make this file shorter than a C++ library's usually
# is, and both are properties of the vendored tree rather than of a choice made
# here.
#
# First, upstream's build is one translation unit. `src/CMakeLists.txt:204` is
# `set(SIMDJSON_SOURCES src/simdjson.cpp)` and `:206` is
# `add_library(simdjson ${SIMDJSON_SOURCES})` with no STATIC/SHARED keyword, so
# the artifact kind follows `BUILD_SHARED_LIBS` (`:193`, default OFF). The
# translation unit itself is `src/src/simdjson.cpp:1-53`: a `#define`, `<base.h>`
# at `:3`, the two charconv bodies and the four `internal/*_tables.cpp` at
# `:7-12`, the generic dependency headers at `:14-17`, `implementation.cpp` at
# `:19`, then one `.cpp` per compiled-in kernel behind
# `#if SIMDJSON_IMPLEMENTATION_<ARCH>` at `:23-49` with `fallback.cpp` last at
# `:47-49`. There is no source list for this file to hold: the graph has one
# path, and the whole kernel set arrives through that file's own cascade.
#
# Second, the On-Demand API is exception-free, so `-fno-exceptions -fno-rtti`
# plus Zig's own bundled libc++ is the intended route and no external sysroot is
# named here. Upstream supports that configuration itself --
# `src/cmake/exception-flags.cmake:1` is the `SIMDJSON_EXCEPTIONS` option, `:5`
# adds `SIMDJSON_EXCEPTIONS=0` PUBLIC when it is OFF and `:27` adds
# `-fno-exceptions` for GCC -- and `src/include/simdjson/common_defs.h:53-59`
# makes the header agree on its own from `__cpp_exceptions`/`_CPPUNWIND`.
# s2geometry's package.nix needs an installed WASI SDK 34 sysroot because *its*
# closure uses filesystem streams, Abseil synchronization and C++ unwinding;
# simdjson's six-target matrix walks `wasm32-wasi` with no such input, and
# naming one would be a claim about a closure this SDK does not have.
#
# No lock file is written here. `flake.lock` and `devenv.lock` belong to the
# driver; `devenv.yaml` states what the latter must pin when it is created.
#
# SPDX-License-Identifier: Apache-2.0
# See FORK-LICENSE.md for the grant over this fork's own files, and NOTICE.md
# for the terms that cover everything in src/ -- simdjson is dual Apache-2.0 /
# MIT and both texts ship unaltered.

{ lib
, stdenv
, zig
  # Zig's own `std.builtin.LinkMode` spelling, passed straight through as
  # `-Dlinkage`. "static" and "dynamic" are two variants of one derivation and
  # one source tree: the same `src/simdjson.cpp`, the same flags, the same
  # install layout, differing only in whether the graph archives the object or
  # links it into a shared object with a soname.
  #
  # `dynamic` is not available on every host. `std.Target.DynamicLinker.kind` is
  # `.none` for WASI (`lib/std/Target.zig:2385`), so a `.so` there would be a
  # file nothing can load; the build graph refuses that request rather than
  # answering it with an archive, and flake.nix names only systems where both
  # variants can be delivered.
, linkage ? "static"
, optimize ? "ReleaseSafe"
}:

let
  requestedLinkage =
    if builtins.elem linkage [ "static" "dynamic" ] then linkage
    else throw "package.nix: linkage must be \"static\" or \"dynamic\", not ${toString linkage}";

# Everything except build outputs, version control and developer-tool state.
# Filtering by directory name rather than by an allow list means a file added
# here later is packaged without editing this file, while `.zig-cache/`,
# `zig-out/`, `.devenv/`, `.direnv/` and `result` stay out of a published output
# at any depth, including under `consumer/`. Upstream's CMake, its own CMake
# modules, its benchmarks, its fuzzers, its `singleheader/` tree and the whole
# `src/` release layout are deliberately kept: they are upstream material with
# digests in UPSTREAM.sha256, and the audit surface is the whole upstream tree.
src = lib.cleanSourceWith {
  src = ./.;
  filter = path: _type:
    let name = builtins.baseNameOf (toString path); in
    !(lib.elem name [
      ".git"
      ".direnv"
      ".devenv"
      ".devenv.flakes"
      ".devenv.flake.nix"
      ".zig-cache"
      "zig-cache"
      "zig-pkg"
      "zig-out"
      "result"
    ]);
};
in

# These packages build for the compiler's own native target. A cross build here
# would mean hand-building a libc-suffixed triple that has to track nixpkgs, so
# this derivation refuses one instead of silently producing a host-architecture
# library under a foreign name. The comparison is against stdenv's own
# platforms, which are pure values; `builtins.currentSystem` is not evaluable in
# a sandbox and is not used. A remote builder is unaffected: this compares build
# against host, not against any particular machine.
#
# It also bounds the whole packaging layer honestly. The SDK's own cross-compile
# matrix (`build_support/graph.zig`, `required_targets`) walks six targets --
# x86_64-linux-gnu, aarch64-linux-gnu, aarch64-macos-none, x86_64-windows-gnu,
# riscv64-linux-gnu and wasm32-wasi -- and that is a compile check, not a
# packaging route. A Nix build here is a native build of the host it names.
assert stdenv.buildPlatform.system == stdenv.hostPlatform.system;

stdenv.mkDerivation {
  pname = "simdjson";
  # `src/include/simdjson/simdjson_version.h:7` is
  # `#define SIMDJSON_VERSION "5.0.2"`, and `src/CMakeLists.txt:12-19` is the
  # `project(simdjson ... VERSION 5.0.2 ...)` that agrees with it. This is the
  # release number. It is *not* the ABI number: see the passthru note below.
  version = "5.0.2";

  inherit src;

  strictDeps = true;

  # Zig compiles, links, archives and translates the bridge header itself, and
  # the build graph names no external binutils, no `cmake` and no `make`, so
  # none is pulled in here. There is deliberately no `patchelf` either: the graph
  # adds no rpath, `std.Build.LibraryOptions` has no rpath field at all
  # (`lib/std/Build.zig:823-840`), and the `-rpath` Zig does add goes to whatever
  # *links* a dynamic artifact (`lib/std/Build/Step/Compile.zig:1192-1199`) --
  # and this derivation installs no program, only the library, its headers, the
  # pkg-config record and the licence material. An installed `DT_RUNPATH` naming
  # the Zig cache would be a finding to gate, not something this build writes.
  nativeBuildInputs = [ zig ];

  # What a consumer of this output has to find at link time, and it is not the
  # same for the two variants.
  #
  # `static` leaves both runtimes undefined in `libsimdjson.a`: the bridge
  # module sets `link_libc` and `link_libcpp` (`build_support/graph.zig`), and a
  # library step archives objects rather than linking them, so whoever links
  # this archive resolves libc and libc++ on their own link line. The generated
  # `simdjson.pc` records the C++ runtime in `Libs.private`, which is exactly the
  # pkg-config place for a private dependency; libc belongs here.
  #
  # `dynamic` links both into the image: `libsimdjson.so.34` carries its own
  # libc++, so there is no `-lc++` left for a consumer to find and propagating
  # one would advertise a dependency the artifact does not have. Naming one
  # variant and not the other is the point; naming both would be a second
  # record for the same fact, which is how a delivery and its description start
  # to disagree.
  propagatedBuildInputs = lib.optional (requestedLinkage == "static") stdenv.cc.libc;

  # The real work is one `zig build` in installPhase below, and the step is the
  # *default* step: this SDK's build graph installs through `b.installArtifact`
  # and `getInstallStep()` and registers no step named `install`, so
  # `zig build install` would fail with an unknown-step error. Disabling
  # configure and build keeps the Zig setup hook from running a first,
  # differently-flagged build of its own; `dontInstall` is deliberately NOT set,
  # because that is what would disable the real install phase.
  dontConfigure = true;
  dontBuild = true;

  # The driver owns every gate for this SDK, and a Nix build is not a
  # verification receipt. No check phase is declared here rather than a check
  # phase that runs something smaller than the real gates; `zig build test` also
  # reaches `testdata/` by a build-root-relative path a derivation does not
  # control. Receipts live with whoever ran the gate.
  doCheck = false;
  dontUseZigCheck = true;

  installPhase = ''
    runHook preInstall

    # Both caches go under the Nix-provided TMPDIR, outside the unpacked source
    # tree, so a build cannot write into $src and so two parallel derivations
    # cannot share state. Any caller-supplied cache variables are left alone:
    # they are the caller's scratch, not this file's to clear.
    export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
    mkdir -p "$ZIG_LOCAL_CACHE_DIR" "$ZIG_GLOBAL_CACHE_DIR"

    # build.zig owns the source list, the C++ flags, the generated pkg-config
    # file and every installed path. Declaring any of them here as well would
    # create a second place where they can disagree with the build graph.
    zig build \
      --prefix "$out" \
      -j"''${NIX_BUILD_CORES:-1}" \
      -Dcpu=baseline \
      -Doptimize=${optimize} \
      -Dlinkage=${requestedLinkage}

    runHook postInstall
  '';

  # `-Dcpu=baseline` is not a generic portability flag here; it decides which
  # SIMD kernels are compiled into the artifact, and it is the correct choice
  # for a derivation because a Nix build must not depend on the CPU of whichever
  # machine happened to build it. `-Dcpu=baseline` resolves
  # `cpu_model = .baseline` (`lib/std/Target/Query.zig:282-283`, documented at
  # `:170-172`), and Zig's x86-64 baseline feature set is
  # `lib/std/Target/x86.zig:4591-4609`: `sse2`, `x87`, `mmx`, `cmov` and no
  # `sse4_2`, no `pclmul`, no `avx`, no `avx2`.
  #
  # simdjson reads exactly those macros. `SIMDJSON_CAN_ALWAYS_RUN_HASWELL` needs
  # `__AVX2__` (`src/include/simdjson/implementation_detection.h:75-79`, and
  # `__BMI__ __PCLMUL__ __LZCNT__` too at `:83-87`),
  # `SIMDJSON_CAN_ALWAYS_RUN_ICELAKE` needs the `__AVX512*` set (`:46-50`,
  # `:54-58`), and `SIMDJSON_CAN_ALWAYS_RUN_WESTMERE` needs
  # `__SSE4_2__ && __PCLMUL__` (`:101-105`). None of them is defined at baseline
  # on x86-64, so every one is 0, `SIMDJSON_IMPLEMENTATION_FALLBACK` stays 1
  # (`:137-145`) and the compiled-in set is the scalar `fallback` kernel alone.
  # On an aarch64 host the answer differs: NEON is part of the aarch64 baseline,
  # so `SIMDJSON_CAN_ALWAYS_RUN_ARM64` is 1 (`:31-35`) and the artifact carries
  # `arm64` with `fallback` compiled out.
  #
  # That is the right thing for a *store path* and the wrong thing for a caller
  # who wants the widest kernel on their own machine: `#include
  # <simdjson/ondemand.h>` is statically bound to the builtin kernel
  # (`src/include/simdjson/builtin/ondemand.h:11-31`, and `:39` aliases
  # `simdjson::ondemand = SIMDJSON_BUILTIN_IMPLEMENTATION::ondemand`), so there
  # is no run-time fallback behind a slow one. `-Dcpu=native` is a local build
  # decision, not one a reproducible derivation may make for its callers.
  #
  # `-Doptimize=ReleaseSafe` keeps Zig's own runtime checks in the shipped
  # library. simdjson's development checks are a separate thing and are on in
  # every configuration this graph builds -- `SIMDJSON_DEVELOPMENT_CHECKS` is
  # what makes `DEFAULT_MAX_DEPTH` (1024, `src/include/simdjson/base.h:49`)
  # enforceable at all
  # (`src/include/simdjson/generic/ondemand/parser.h:344`) -- so the fork
  # decision is stated by the graph, not re-decided here.

  # The layout this derivation produces is the build graph's, not this file's:
  # $out/lib/libsimdjson.a (or libsimdjson.so.34.0.0 with libsimdjson.so.34
  # and libsimdjson.so beside it), $out/include/simdjson/ with the whole
  # upstream public header tree, $out/include/simdjson_bridge.h beside it,
  # $out/lib/pkgconfig/simdjson.pc, and $out/share/licenses/simdjson/ with
  # upstream's two grants beside this fork's own records. Both variants keep
  # that shape; only the artifact kind differs.
  #
  # Nothing here installs a licence or an artifact, and that is deliberate. The
  # graph is the only writer of `share/licenses/simdjson/`. A second writer is
  # how one output ends up with two licence records that disagree about what
  # they cover -- one that lists files the shipped artifact does not contain,
  # and one that misses files it does -- and a licence set that does not match
  # the artifact beside it is the one failure a redistributable binary cannot
  # recover from. `zig build --prefix $out` and `nix build` therefore produce
  # one layout by construction rather than two that have to be kept in
  # agreement.

  enableParallelBuilding = true;

  passthru = {
    # The validated spelling, so this attribute cannot carry a value the
    # install phase would have refused.
    linkage = requestedLinkage;

    # The shared object's soname is upstream's own ABI number and is *not* the
    # release number: `src/CMakeLists.txt:32-33` are
    # `set(SIMDJSON_LIB_VERSION "34.0.0" CACHE STRING ...)` and
    # `set(SIMDJSON_LIB_SOVERSION "34" CACHE STRING ...)`, with the comment at
    # `:31` "These version numbers are modified by tools/release.py". They are
    # applied as `VERSION` and `SOVERSION` at `:251-257`. So a shared upstream
    # build is `libsimdjson.so.34.0.0` with soname `libsimdjson.so.34`, and the
    # `5.0.2` in `version` above is a different fact.
    #
    # `std.SemanticVersion` has three components where an ELF shared object has
    # four, so the graph expresses the ABI as `{ .major = 34, .minor = 0,
    # .patch = 0 }` and produces exactly those two names. This is the name a
    # runtime-loaded consumer has to ask for by path or by system.
    abi_version = "34.0.0";
    soname = "libsimdjson.so.34";

    inherit src;
  };

  meta = {
    description = "simdjson 5.0.2, upstream's SIMD JSON parser, built to a ${if requestedLinkage == "dynamic" then "shared" else "static"} C ABI library with a Zig facade";
    longDescription = ''
      The complete simdjson 5.0.2 release source -- the one-translation-unit
      core, the per-architecture kernels it selects from at compile time, the
      full public header tree, upstream's own CMake build, its benchmarks and
      its published test data -- imported whole and compiled with Zig. No CMake,
      no autotools, no build-time download and no WASI sysroot: the On-Demand
      API is exception-free, so Zig's own bundled libc++ is the whole C++
      runtime. Ships the library, the public headers, a pkg-config file and both
      upstream licence grants.

      The compiled core is upstream's own source list, one file:
      src/src/simdjson.cpp, whose own #include cascade pulls in the charconv
      bodies, the internal tables, the runtime CPU dispatcher and exactly those
      architecture kernels this target can run. Which kernel that is, is decided
      by the compile flags: -Dcpu=baseline compiles the scalar fallback alone on
      x86-64 and arm64 on aarch64.
    '';
    # The compiled core is upstream's, and it is dual Apache-2.0 / MIT. The
    # shipped tree is not one licence: the fork's own build, facade, runtime
    # route, tests, example, consumer package and packaging layer are under the
    # owner's Apache-2.0 grant, which is a subset of what upstream already
    # offers. This is the attribute set rather than a single id, because this is
    # where a consumer looks and neither term covers the whole tree alone.
    # NOTICE.md is the per-file inventory.
    license = with lib.licenses; { apache2 = true; mit = true; };
    # Upstream's own `HOMEPAGE_URL`, src/CMakeLists.txt:17.
    homepage = "https://simdjson.org/";
    platforms = lib.platforms.unix;
  };
}