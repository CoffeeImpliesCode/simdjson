# Flake interface for the simdjson Zig SDK.
#
# Portable counterpart to devenv.nix. Both call ./package.nix, so the package a
# flake builds and the package devenv builds are the same derivation; this file
# only decides which systems are exposed and which variants of that derivation
# they get.
#
# Canonical development is `devenv shell` (see devenv.nix and .envrc). This
# flake exists so the SDK can be built and consumed off this host. `nix develop`
# here is parity, not the canonical entry point, and it deliberately does not
# build the SDK: entering a shell must not require building a library, and for
# this SDK that library is not cheap -- the vendored core is upstream's whole
# 5.0.2 tree behind one translation unit that pulls in every per-architecture
# kernel the target can run.
#
# flake.lock is not written here: the driver owns locks.
#
# SPDX-License-Identifier: Apache-2.0

{
  description = "simdjson -- upstream's SIMD JSON parser, built to a real C ABI library with a Zig facade";

  # One fixed nixpkgs input, and the lock that resolves it. `flake.lock` sits
  # beside this file and pins exactly the revision below together with its
  # `narHash`, so a flake checked out anywhere -- including a copy this
  # package's `build.zig.zon` `.paths` carries to a dependent -- resolves this
  # nixpkgs rather than whatever the machine happens to have. That revision is
  # `c7def046b9a883d46974757852106483d741586f`; it is read out of the lock file,
  # not chosen here.
  #
  # `devenv.lock` is not in this tree and is not named by any path in it;
  # devenv.yaml states what it must pin when the driver creates it.
  inputs.nixpkgs.url =
    "github:NixOS/nixpkgs/c7def046b9a883d46974757852106483d741586f";

  outputs = { self, nixpkgs }:
    let
      # The systems whose operating system has a dynamic linker, and only
      # those. `.packages` below exposes both a `static` and a `shared`
      # attribute for every system named, so the question each entry has to
      # answer is whether `-Dlinkage=dynamic` can be *delivered* there -- not
      # whether it happens to work.
      #
      # `std.Target.DynamicLinker.kind` (`lib/std/Target.zig:2345`) is that
      # question, asked from the OS tag alone. Its `Kind` is `{ none, arch_os,
      # arch_os_abi }` (`:2336-2343`): the first family fixes the linker from
      # arch and OS, the second from arch, OS and ABI, and `none` means there is
      # no dynamic linker to name at all. `.hurd` and `.linux` are `arch_os_abi`
      # (`:2366-2368`) and `.macos` is `arch_os` (`:2358-2365`), so every system
      # below can carry a shared object, and the `.shared` attribute is a real
      # package on all four rather than an alias of the archive.
      #
      # `.wasi` is in the `none` arm (`:2385`, listed at `:2401`), which is
      # exactly why this SDK's own six-target compile matrix refuses
      # `-Dlinkage=dynamic` for its `wasm32-wasi` cell instead of silently
      # handing back an archive: a `.so` there is a file nothing can load.
      # `wasm32-wasi` stays a *compile* row (`build_support/graph.zig`,
      # `required_targets`) and is not a packaging host here, so nothing is
      # dropped by leaving it out of this list.
      #
      # Two matrix rows are also absent, deliberately and for different reasons.
      # `riscv64-linux-gnu` is a `.linux` OS, so a `shared` attribute there would
      # be expected to deliver; this flake stops at the four hosts above rather
      # than assert coverage for a host it has not been exercised on.
      # `x86_64-windows-gnu` is the interesting near-miss: `.windows` is `.none`
      # too (`lib/std/Target.zig:2380`) but only because a PE/COFF image has no
      # interpreter path -- its imports are resolved by the loader inside the OS
      # -- so a Windows target does carry a shared object, as `simdjson.dll`
      # with its import library. Naming it would mean a mingw stdenv and a
      # `bin/simdjson.dll` plus `lib/simdjson.lib` delivery layout that nothing
      # here has shaped; a Windows entry that had never been built would be a
      # promise, not a package.
      #
      # All four are Unix, which is the same boundary package.nix asserts: that
      # derivation builds for the compiler's native target, so each attribute
      # here is a host and never a cross target.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      forAllSystems = f:
        nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # `zig_0_16` is named rather than aliased: `pkgs.zig` is a moving alias and
      # this SDK is pinned to 0.16.0, which `build.zig.zon` states as its
      # `minimum_zig_version` and devenv.nix asserts on. `linkage` is the only
      # difference between the two packages below: one derivation, one source
      # tree, one C ABI in `zig/bridge.h`, eleven entry points, and the same
      # `-std=c++17 -fno-exceptions -fno-rtti` compile for both.
      #
      # What the shared variant adds is a name, not a different build:
      # `src/CMakeLists.txt:32-33` set `SIMDJSON_LIB_VERSION "34.0.0"` and
      # `SIMDJSON_LIB_SOVERSION "34"`, applied at `:251-257`, so `shared` is
      # `libsimdjson.so.34.0.0` with soname `libsimdjson.so.34`. That is
      # upstream's ABI number and not the 5.0.2 release number.
      simdjson = pkgs: linkage:
        pkgs.callPackage ./package.nix { zig = pkgs.zig_0_16; inherit linkage; };
    in
    {
      packages = forAllSystems (pkgs:
        let
          static = simdjson pkgs "static";
        in
        {
          inherit static;

          # A separate variant of the same derivation, not a second SDK.
          # "shared" names the artefact; the flag it passes is Zig's own
          # `-Dlinkage=dynamic`, and it is refused rather than downgraded on any
          # system whose OS has no dynamic linker.
          shared = simdjson pkgs "dynamic";

          # A static archive is the cheaper thing to link into a consumer, and
          # it is the variant every system above can deliver, so `.default`
          # preserves it.
          default = static;
        });

      # Portability parity only; devenv is the canonical environment. Tools only:
      # a shell that had to build the package to exist would make every shell
      # entry a native build of upstream's whole 5.0.2 tree.
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.zig_0_16
            pkgs.pkg-config
          ];

          # A default only, and only when the caller supplied neither the Zig
          # cache location nor a scratch root to derive it from. Nothing here
          # builds anything and nothing here names a store path.
          shellHook = ''
            if [ -z "''${ZIG_LOCAL_CACHE_DIR:-}" ] && [ -n "''${XDG_CACHE_HOME:-}" ]; then
              export ZIG_LOCAL_CACHE_DIR="$XDG_CACHE_HOME/simdjson/zig-local"
            fi
          '';
        };
      });
    };
}