# Development shell and tasks for the simdjson SDK.
# SPDX-License-Identifier: Apache-2.0

{ pkgs, ... }:

let
  # Use the pinned Zig 0.17.0 compiler.
  zig = pkgs.zig_0_17;

  # Build the same Nix derivation as flake.nix.
  mk = linkage: pkgs.callPackage ./package.nix { inherit zig linkage; };

  # Anchor tasks to this checkout, not the caller's directory.
  sdk_root = builtins.toString ./.;
  consumer_root = builtins.toString ./. + "/consumer";

  # Keep caches outside the source tree; caller paths take precedence.
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

  # Refuse tasks that have no external cache directory.
  require_external_output = ''
    if [ -z "''${ZIG_LOCAL_CACHE_DIR:-}" ]; then
      echo "simdjson devenv: ZIG_LOCAL_CACHE_DIR, XDG_CACHE_HOME and TMPDIR are all unset," >&2
      echo "so there is nowhere outside this checkout to put build output." >&2
      echo "Export one of them at approved scratch, then run the task again." >&2
      exit 1
    fi
  '';

  # Run project tasks from the SDK root.
  in_sdk = ''
    ${zig_caches}
    ${require_external_output}
    cd "${sdk_root}" || exit 1
  '';

  # Forward common build flags and caller arguments.
  native_flags = ''
    -j8 --summary all --cache-dir "$ZIG_LOCAL_CACHE_DIR/native" "''$@"
  '';

  # Keep the consumer cache separate from the library cache.
  consumer_flags = ''
    -j8 --summary all --cache-dir "$ZIG_LOCAL_CACHE_DIR/consumer" "''$@"
  '';

  # Provider installed for runtime-loaded consumer tasks.
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
      assertion = zig.version == "0.17.0";
      message = "The simdjson SDK requires Zig 0.17.0; nixpkgs resolved zig_0_17 to ${zig.version}";
    }
  ];

  # Preserve caller cache settings in the shell.
  enterShell = ''
    ${zig_caches}
  '';

  # Lazy outputs; entering the shell does not build them.
  outputs.static = mk "static";
  outputs.shared = mk "dynamic";
  outputs.default = mk "static";

  tasks = {
    # Install outside the checkout; the build graph owns the delivery layout.
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

    # Shared variant of the same source and flags.
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

    # Tests use the external cache and fixtures from this checkout.
    "sdk:test" = {
      description = "Run the behavioural tests against testdata/ for the selected target";
      exec = ''
        ${in_sdk}
        zig build test ${native_flags}
      '';
    };

    # Keep simdjson development checks enabled in ReleaseSafe.
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

    # Compile all six declared targets; the WASI cell uses static linkage.
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

    # Shared check refuses WASI, which has no dynamic linker.
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

    # Build and run the separate consumer package.
    "sdk:consumer" = {
      description = "Build and run the separate consumer package against this SDK";
      exec = ''
        ${in_sdk}
        cd "${consumer_root}"
        zig build run ${consumer_flags}
      '';
    };

    # Install the shared provider, then pass its path to the runtime consumer.
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

    # Check source files and digests from the checkout root.
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

    # Build package outputs from the caller's project.
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