# Canonical development environment for the simdjson Zig SDK.
#
# This is the environment a contributor should be in. It installs tools and
# nothing else: `packages` deliberately does not contain the SDK's own package,
# because entering a shell must not require building a library to have it, and
# for this SDK that library is the vendored upstream 5.0.2 tree at `src/` --
# ten megabytes of it, behind two C++ translation units
# (`src/src/simdjson.cpp`, upstream's own single-TU core, and `zig/bridge.cc`,
# this fork's C ABI over it), and the core's own `#include` cascade pulls in
# every per-architecture kernel the target can run.
#
# The package itself is defined once, in ./package.nix, and shared with
# flake.nix, so the two entry points cannot describe different builds. `outputs`
# below name that same derivation lazily -- they are attributes, not builds, so
# nothing is realised until `devenv build outputs.static` or
# `devenv build outputs.shared` is actually run.
#
# devenv.lock is not written here: the driver owns locks, and devenv.yaml states
# what it must pin when it is created.
#
# Two facts about the environment a task actually runs in are handled once, in
# the `let` below, and every task uses them: devenv materialises a task as a
# generated shell program that inherits the caller's working directory, and
# `zig build` defaults both its local cache and its install prefix to
# directories inside the working tree. Neither is visible from a task body, and
# both decide whether a task can find this checkout or must write into it.
#
# SPDX-License-Identifier: Apache-2.0

{ pkgs, ... }:

let
  # Kept as a value rather than inlined, so the version assertion below and the
  # package list cannot disagree about which compiler is meant. `pkgs.zig` is a
  # moving alias; this SDK is pinned to 0.16.0, which `build.zig.zon` also
  # states as its `minimum_zig_version`.
  zig = pkgs.zig_0_16;

  # One derivation per linkage, called exactly the way flake.nix calls it, so a
  # `devenv build` and a `nix build` of the same variant are the same build.
  mk = linkage: pkgs.callPackage ./package.nix { inherit zig linkage; };

  # The directory this module was evaluated against. `./.` is a path literal
  # resolved relative to the file that names it, so it is this checkout and
  # never the directory `devenv` was started from. `builtins.toString`
  # converts that path instead of interpolating it into a string, so what the
  # tasks below receive is this working tree: a plain `${./.}` would carry the
  # path's store context and copy this whole SDK into the read-only store, and
  # that copy is not the tree `build.zig` and `UPSTREAM.sha256` describe. No
  # host path is written in this file -- the value is read out of the module's
  # own location, so it tracks wherever this checkout is.
  sdk_root = builtins.toString ./.;
  consumer_root = builtins.toString ./. + "/consumer";

  # Where a task's build output goes. `zig build` keeps its local cache in
  # `.zig-cache/` and installs into `zig-out/`, both relative to the working
  # directory, and this checkout is a working tree on a volume mount that has to
  # stay byte-identical to what `UPSTREAM.sha256` describes. A directory the
  # caller exported always wins and is never overwritten; otherwise it comes from
  # `XDG_CACHE_HOME`, then `TMPDIR`, and this file names no location of its own.
  #
  # The two directories are named apart because upstream's own tree makes them
  # worth naming apart. The local cache holds this target's objects, and for
  # simdjson that includes a separate compile of every compiled-in kernel
  # (`src/src/simdjson.cpp:23-49`); the global cache holds what does not depend
  # on the target, which is the translate-c run and the parts of libc++ that
  # `-fno-exceptions -fno-rtti` does not change. Sharing one directory between
  # them would make a `-Dtarget` change evict the target-independent work.
  zig_caches = ''
    if [ -z "''${ZIG_LOCAL_CACHE_DIR:-}" ]; then
      if [ -n "''${XDG_CACHE_HOME:-}" ]; then
        export ZIG_LOCAL_CACHE_DIR="$XDG_CACHE_HOME/simdjson/zig-local-cache"
      elif [ -n "''${TMPDIR:-}" ]; then
        export ZIG_LOCAL_CACHE_DIR="$TMPDIR/simdjson/zig-local-cache"
      fi
    fi
    if [ -z "''${ZIG_GLOBAL_CACHE_DIR:-}" ]; then
      if [ -n "''${XDG_CACHE_HOME:-}" ]; then
        export ZIG_GLOBAL_CACHE_DIR="$XDG_CACHE_HOME/simdjson/zig-global-cache"
      elif [ -n "''${TMPDIR:-}" ]; then
        export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/simdjson/zig-global-cache"
      fi
    fi
    if [ -n "''${ZIG_LOCAL_CACHE_DIR:-}" ]; then
      mkdir -p "$ZIG_LOCAL_CACHE_DIR"
    fi
    if [ -n "''${ZIG_GLOBAL_CACHE_DIR:-}" ]; then
      mkdir -p "$ZIG_GLOBAL_CACHE_DIR"
    fi
  '';

  # The same rule with the one extra requirement a task has: it must be able to
  # name that directory. An environment with nowhere outside the checkout to
  # write stops here, with the reason, instead of filling the tree.
  require_external_output = ''
    if [ -z "''${ZIG_LOCAL_CACHE_DIR:-}" ]; then
      echo "simdjson devenv: ZIG_LOCAL_CACHE_DIR, XDG_CACHE_HOME and TMPDIR are all unset," >&2
      echo "so there is nowhere outside this checkout to put build output." >&2
      echo "Export one of them at approved scratch, then run the task again." >&2
      exit 1
    fi
  '';

  # What every task below starts with. devenv materialises a task as a
  # generated shell program that inherits the caller's working directory, so
  # `devenv --from path:<sdk>` entered from a scratch project directory would
  # otherwise run each of these bodies where there is no `build.zig` and no
  # `UPSTREAM.sha256`. A per-task `cwd` would not reach that generated
  # program, and `$DEVENV_ROOT` is the scratch project itself -- exactly what
  # these bodies must not build in.
  in_sdk = ''
    ${zig_caches}
    ${require_external_output}
    cd "${sdk_root}" || exit 1
  '';

  # The flags every native build here shares: this workspace's eight jobs,
  # fixed, then the printed step list and a local cache outside the checkout.
  # `"''$@"` stays after them, so whatever a caller appended is still passed
  # on and still comes later; `devenv tasks run` forwards no argument of its
  # own, so it is the empty list on that route.
  native_flags = ''
    -j8 --summary all --cache-dir "$ZIG_LOCAL_CACHE_DIR/native" "''$@"
  '';

  # The consumer package is a second build graph with its own manifest, and it
  # resolves this SDK as a relative path dependency, so it gets its own cache
  # directory rather than sharing one with the library it depends on.
  consumer_flags = ''
    -j8 --summary all --cache-dir "$ZIG_LOCAL_CACHE_DIR/consumer" "''$@"
  '';

  # The prefix the runtime-loaded tasks install a provider into. It is named
  # once here so the two tasks below and the file name they hand to the loader
  # cannot disagree: the provider is the unversioned `libsimdjson.so` beside the
  # versioned file, because that is the one `install` publishes next to the
  # soname `libsimdjson.so.34` (`src/CMakeLists.txt:33`, applied at `:251-257`).
  runtime_prefix = "$ZIG_LOCAL_CACHE_DIR/prefix/dynamic";
  runtime_provider = "$ZIG_LOCAL_CACHE_DIR/prefix/dynamic/lib/libsimdjson.so";
in
{
  packages = [
    zig
    pkgs.pkg-config
  ];

  assertions = [
    {
      assertion = zig.version == "0.16.0";
      message = "The simdjson SDK requires Zig 0.16.0; nixpkgs resolved zig_0_16 to ${zig.version}";
    }
  ];

  # The shell hook exports the same two directories the tasks use, by the same
  # rule, so an ordinary `devenv shell` session also leaves this checkout alone.
  # A value the caller exported is kept exactly as it is, and with nothing to
  # choose from the hook chooses nothing: only a task, which has to name the
  # directory, refuses to run.
  enterShell = ''
    ${zig_caches}
  '';

  # Lazy on purpose: naming a derivation realises nothing, and entering the
  # shell does not build either variant. `devenv build outputs.<name>` is the
  # real packaging route.
  outputs.static = mk "static";
  outputs.shared = mk "dynamic";
  outputs.default = mk "static";

  # Every task name here is `namespace:name` and nothing else. devenv 2.x
  # accepts alphanumerics, `:`, `-` and `_` in a task name and rejects anything
  # else before any shell runs, so the names that would read more naturally
  # with a third colon are spelled with a second one.
  tasks = {
    # Delivery output goes outside the checkout. The default step installs --
    # this SDK's build graph installs through `b.installArtifact` and
    # `getInstallStep()` and registers no step named `install`, so
    # `zig build install` would fail with an unknown-step error -- and
    # `zig-out/` is a directory in the working tree, so the prefix is named
    # here. The pkg-config record is prefix-relative through `${pcfiledir}`, so
    # the installed tree is the same shape wherever it lands.
    #
    # No `-Dcpu` is passed on this route and none should be: the default for a
    # native build is the host CPU, and that is the point of building here rather
    # than through package.nix. `src/include/simdjson/builtin/ondemand.h:39`
    # aliases `simdjson::ondemand` to `SIMDJSON_BUILTIN_IMPLEMENTATION::ondemand`,
    # so the On-Demand surface is statically bound to one compiled-in kernel and
    # there is no slower kernel to fall back to at run time. A local build gets
    # this machine's `haswell` or `icelake`; the packaged build pins `-Dcpu=baseline`
    # because a store path must not depend on the machine that produced it, and
    # at baseline x86-64 that means the scalar `fallback` kernel alone
    # (`src/include/simdjson/implementation_detection.h:75-79,101-105,137-145`).
    "sdk:install" = {
      description = ''
        Compile and install the delivery tree -- the library as an archive, the
        C ABI header, the whole upstream public header tree, the pkg-config
        record and the licence material -- under the external cache rather than
        in this checkout (default step).
      '';
      exec = ''
        ${in_sdk}
        zig build --prefix "$ZIG_LOCAL_CACHE_DIR/prefix/static" ${native_flags}
      '';
    };

    # The same tree as a real shared object. `libsimdjson.so.34.0.0` with
    # `libsimdjson.so.34` and `libsimdjson.so` beside it: that soname is
    # upstream's own `SIMDJSON_LIB_SOVERSION` (`src/CMakeLists.txt:32-33`) and
    # not the 5.0.2 release number. Nothing is recompiled differently -- the same
    # `src/src/simdjson.cpp` and the same `zig/bridge.cc` at the same
    # `-std=c++17 -fno-exceptions -fno-rtti`; only the link changes.
    "sdk:install:shared" = {
      description = ''
        Compile and install the same delivery tree with the library as a shared
        object carrying upstream's soname, under its own external prefix.
      '';
      exec = ''
        ${in_sdk}
        zig build -Dlinkage=dynamic --prefix "${runtime_prefix}" ${native_flags}
      '';
    };

    # These run or compile; none of them installs, so each needs only the
    # external cache directory. `test` reads the shared fixtures under
    # `testdata/` through the build-created `simdjson_paths` module, which
    # names that directory relative to the build root -- so it runs from this
    # checkout and never from an installed prefix.
    "sdk:test" = {
      description = "Run the behavioural tests against testdata/ for the selected target";
      exec = ''
        ${in_sdk}
        zig build test ${native_flags}
      '';
    };

    # simdjson's development checks are on in every configuration this graph
    # builds, not only in Debug: `SIMDJSON_DEVELOPMENT_CHECKS` is what makes
    # `DEFAULT_MAX_DEPTH` -- 1024, `src/include/simdjson/base.h:49` -- enforced
    # at all (`src/include/simdjson/generic/ondemand/parser.h:344`). A
    # Debug-only boundary would be a boundary in one gate and not in the other,
    # so the tests are run in both.
    "sdk:test:release-safe" = {
      description = "Run the behavioural tests in ReleaseSafe, with the depth limit still enforced";
      exec = ''
        ${in_sdk}
        zig build test -Doptimize=ReleaseSafe ${native_flags}
      '';
    };

    "sdk:smoke" = {
      description = "Run the example that prints the kernels this host selected and checks its own answers";
      exec = ''
        ${in_sdk}
        zig build smoke ${native_flags}
      '';
    };

    # All six of the SDK's own matrix cells, with no `-Dtarget`, so the full set:
    # x86_64-linux-gnu, aarch64-linux-gnu, aarch64-macos-none,
    # x86_64-windows-gnu, riscv64-linux-gnu and wasm32-wasi
    # (`build_support/graph.zig`, `required_targets`). Passing `-Dtarget=...`
    # narrows it to that one cell.
    #
    # wasm32-wasi is in that list because the On-Demand path is exception-free:
    # `-fno-exceptions -fno-rtti` plus Zig's own bundled libc++ is the intended
    # route, so this SDK compiles and links it with no external WASI SDK sysroot
    # at all. s2geometry's graph needs an installed WASI SDK 34 sysroot because
    # *its* closure uses filesystem streams, Abseil synchronization and C++
    # unwinding; there is nothing here for one to provide.
    "sdk:check" = {
      description = ''
        Compile and link the core, the bridge, the translated header, the
        facade, the tests and the example for all six required targets,
        including wasm32-wasi, without running any of them.
      '';
      exec = ''
        ${in_sdk}
        zig build check ${native_flags}
      '';
    };

    # The same six cells against the shared object, with one honest difference:
    # the wasm32-wasi cell fails with a message naming the target. `.wasi` is
    # `.none` for `std.Target.DynamicLinker.kind` (`lib/std/Target.zig:2385`), so
    # a `.so` there would be a file nothing can load, and the graph refuses the
    # request rather than answering it with an archive. The other five compile.
    "sdk:check:shared" = {
      description = ''
        The same six-target compile check against the shared object. The
        wasm32-wasi cell is refused with a message naming it; the other five
        still compile.
      '';
      exec = ''
        ${in_sdk}
        zig build check -Dlinkage=dynamic ${native_flags}
      '';
    };

    # The dependent package in `consumer/`, built and run as itself. It resolves
    # this SDK through a relative path dependency in its own manifest and
    # reaches it only through `dep.module("simdjson")`, so this is the proof that
    # the published module carries the compiled library and that the translated
    # `zig/bridge.h` still matches the C++ it was compiled from -- neither of
    # which anything inside this repository would notice.
    "sdk:consumer" = {
      description = "Build and run the separate consumer package against this SDK";
      exec = ''
        ${in_sdk}
        cd "${consumer_root}"
        zig build run ${consumer_flags}
      '';
    };

    # The runtime route is a separate configuration of the same graph: the
    # facade dispatches through one process-lifetime table instead of a link
    # line, and the artifact stops being something the module links and becomes
    # what a provider *is*. It has to exist on disk before anything can be run
    # against it, so this task installs it first and then names it explicitly.
    # Nothing is loaded by default and no other file is tried: the provider is
    # the one path below, the unversioned `libsimdjson.so` this tree just
    # installed beside its soname.
    "sdk:consumer:loaded" = {
      description = ''
        Run the consumer package against the runtime-loaded configuration, with
        the provider named on its command line.
      '';
      exec = ''
        ${in_sdk}
        zig build -Dlinkage=dynamic --prefix "${runtime_prefix}" ${native_flags}
        cd "${consumer_root}"
        zig build run -Druntime=true ${consumer_flags} -- --provider "${runtime_provider}"
      '';
    };

    # The checker runs against this checkout's own bytes and file set, which is
    # what `UPSTREAM.sha256` describes, so it is entered here rather than in the
    # directory the task happened to start in. It is a source-integrity check,
    # not a build gate: nothing in it compiles upstream's tree.
    "sdk:provenance" = {
      description = ''
        Run tools/check-provenance.sh over this checkout: the recorded digests
        of the vendored upstream tree and of the shared fixtures under
        testdata/, and the file set they describe. This is a source-integrity
        check, not a build gate; it compiles nothing and runs nothing.
      '';
      exec = ''
        ${in_sdk}
        bash tools/check-provenance.sh
      '';
    };

    # These two are the only bodies that do not enter this checkout, and that is
    # deliberate. They run a nested `devenv build`, which reads the project the
    # caller entered -- under `--from path:<sdk>` that is the scratch project
    # holding `.devenv/` and the driver-created lock -- and its delivery output
    # is a store path, never a directory in this tree. Changing directory here
    # would point the nested command at a directory with no devenv state at all.
    "package:static" = {
      description = ''
        Build the static Nix variant through devenv's own lazy output.
        -Dcpu=baseline makes it reproducible, and at that baseline x86-64
        compiles the scalar fallback kernel alone.
      '';
      exec = "devenv build outputs.static";
    };

    "package:shared" = {
      description = ''
        Build the shared Nix variant through devenv's own lazy output. The
        result is libsimdjson.so.34.0.0 with soname libsimdjson.so.34.
      '';
      exec = "devenv build outputs.shared";
    };
  };
}