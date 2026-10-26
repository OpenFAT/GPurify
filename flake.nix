{
  description = "GPurify";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig-overlay.url = "github:mitchellh/zig-overlay";
    zig-overlay.inputs.nixpkgs.follows = "nixpkgs";
    zls.url = "github:zigtools/zls";
    zls.inputs.nixpkgs.follows = "nixpkgs";
    # OpenROAD alone, from a revision Hydra built it at: at newer pins its
    # dependency or-tools is marked broken, so nothing evaluates or is cached.
    nixpkgs-openroad.url = "github:NixOS/nixpkgs/f45c6f04c2f013f004bf94e284e95d72898d9393";
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      zig-overlay,
      zls,
      nixpkgs-openroad,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        zig = zig-overlay.packages.${system}.master;
        default = pkgs.mkShell {
          packages = [
            zig
            zls.packages.${system}.zls
          ];
          # One global cache per Zig store path: two builds of the same Zig version
          # sharing ~/.cache/zig evict each other's build runner on every `zig build`.
          shellHook = ''export ZIG_GLOBAL_CACHE_DIR="''${XDG_CACHE_HOME:-$HOME/.cache}/zig-${builtins.baseNameOf zig}"'';
        };
      in
      {
        devShells.default = default;
        # The independent tools the comparison tests run against, pinned by
        # flake.lock so a tool's version changes only in a reviewed commit:
        # `nix develop .#comparison -c zig build test -Dcomparison-tests=true`.
        devShells.comparison = pkgs.mkShell {
          inputsFrom = [ default ];
          inherit (default) shellHook;
          packages = [
            pkgs.klayout
            pkgs.netgen-vlsi
            pkgs.magic-vlsi
            pkgs.ngspice
            pkgs.fastcap
            pkgs.fasthenry
            pkgs.yosys
            nixpkgs-openroad.legacyPackages.${system}.openroad
          ];
        };
      }
    );
}
