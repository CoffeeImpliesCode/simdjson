# Flake interface for the simdjson Zig SDK.
# SPDX-License-Identifier: Apache-2.0

{
  description = "simdjson -- upstream's SIMD JSON parser, built to a real C ABI library with a Zig facade";

  inputs.nixpkgs.url =
    "github:NixOS/nixpkgs/c7def046b9a883d46974757852106483d741586f";

  outputs = { self, nixpkgs }:
    let
      # Expose static and shared packages on supported Unix systems.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      forAllSystems = f:
        nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # Pin Zig and share one package derivation.
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

          # Dynamic package output.
          shared = simdjson pkgs "dynamic";

          # The static archive is the default output.
          default = static;
        });

      # Provide development tools without building the package.
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.zig_0_16
            pkgs.pkg-config
          ];

          # Set a Zig cache default only when the caller supplied none.
          shellHook = ''
            if [ -z "''${ZIG_LOCAL_CACHE_DIR:-}" ] && [ -n "''${XDG_CACHE_HOME:-}" ]; then
              export ZIG_LOCAL_CACHE_DIR="$XDG_CACHE_HOME/simdjson/zig-local"
            fi
          '';
        };
      });
    };
}