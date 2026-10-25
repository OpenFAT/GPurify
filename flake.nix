{
  description = "GPurify";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig-overlay.url = "github:mitchellh/zig-overlay";
    zig-overlay.inputs.nixpkgs.follows = "nixpkgs";
    zls.url = "github:zigtools/zls";
    zls.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      zig-overlay,
      zls,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        zig = zig-overlay.packages.${system}.master;
      in
      {
        devShells.default = pkgs.mkShell {
          packages = [
            zig
            zls.packages.${system}.zls
          ];
          # One global cache per Zig store path: two builds of the same Zig version
          # sharing ~/.cache/zig evict each other's build runner on every `zig build`.
          shellHook = ''export ZIG_GLOBAL_CACHE_DIR="''${XDG_CACHE_HOME:-$HOME/.cache}/zig-${builtins.baseNameOf zig}"'';
        };
      }
    );
}
