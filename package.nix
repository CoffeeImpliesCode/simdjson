# Source-only Nix package for the simdjson Zig SDK.
# SPDX-License-Identifier: Apache-2.0
# See FORK-LICENSE.md for the grant over this fork's own files, and NOTICE.md
# for the terms that cover everything in src/ -- simdjson is dual Apache-2.0 /
# MIT and both texts ship unaltered.

{ lib
, stdenv
, zig
  # Select static or shared linkage; dynamic requires a dynamic-linker target.
, linkage ? "static"
, optimize ? "ReleaseSafe"
}:

let
  requestedLinkage =
    if builtins.elem linkage [ "static" "dynamic" ] then linkage
    else throw "package.nix: linkage must be \"static\" or \"dynamic\", not ${toString linkage}";

# Exclude build outputs and developer-tool state from the source.
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

# Build this derivation for its native platform only.
assert stdenv.buildPlatform.system == stdenv.hostPlatform.system;

stdenv.mkDerivation {
  pname = "simdjson";
  # Match the release version recorded by upstream.
  version = "5.0.2";

  inherit src;

  strictDeps = true;

  nativeBuildInputs = [ zig ];

  # Static archives leave runtimes unresolved; shared objects include theirs.
  propagatedBuildInputs = lib.optional (requestedLinkage == "static") stdenv.cc.libc;

  # Run the package's default Zig build step during installation.
  dontConfigure = true;
  dontBuild = true;

  doCheck = false;
  dontUseZigCheck = true;

  installPhase = ''
    runHook preInstall

    # Keep Zig caches under TMPDIR, outside the source tree.
    export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
    mkdir -p "$ZIG_LOCAL_CACHE_DIR" "$ZIG_GLOBAL_CACHE_DIR"

    zig build \
      --prefix "$out" \
      -j"''${NIX_BUILD_CORES:-1}" \
      -Dcpu=baseline \
      -Doptimize=${optimize} \
      -Dlinkage=${requestedLinkage}

    runHook postInstall
  '';

  # Baseline kernels keep the store artifact independent of the build host CPU.

  # The Zig build graph owns the installed layout and license records.

  enableParallelBuilding = true;

  passthru = {
    linkage = requestedLinkage;

    # Upstream ABI version, distinct from the release number.
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
    # Upstream and fork-authored terms are listed in NOTICE.md.
    license = with lib.licenses; { apache2 = true; mit = true; };
    homepage = "https://simdjson.org/";
    platforms = lib.platforms.unix;
  };
}