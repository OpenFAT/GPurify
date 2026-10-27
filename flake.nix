{
  description = "GPurify";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig-overlay.url = "github:mitchellh/zig-overlay";
    zig-overlay.inputs.nixpkgs.follows = "nixpkgs";
    zls.url = "github:zigtools/zls";
    zls.inputs.nixpkgs.follows = "nixpkgs";
    # The comparison tools, from one revision Hydra built and cached them all
    # at: newer pins mark OpenROAD's or-tools broken and leave KLayout uncached
    # (its Qt6 bindings then fail to build from source).
    nixpkgs-tools.url = "github:NixOS/nixpkgs/f45c6f04c2f013f004bf94e284e95d72898d9393";
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      zig-overlay,
      zls,
      nixpkgs-tools,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        tools = nixpkgs-tools.legacyPackages.${system};
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
        # The user docs: mdBook, and the TeX set that renders their CircuiTikZ
        # diagrams to SVG (docs/diagrams/render.sh), apart from the default
        # shell so the test jobs don't fetch TeX: `nix develop .#docs`.
        devShells.docs = pkgs.mkShell {
          packages = [
            pkgs.mdbook
            (pkgs.texliveBasic.withPackages (
              ps: with ps; [
                circuitikz
                dvisvgm
                etoolbox
                lm
                pgf
                siunitx
                standalone
                xcolor
                xkeyval
                xstring
              ]
            ))
          ];
        };
        # The independent tools the comparison tests run against, pinned by
        # flake.lock so a tool's version changes only in a reviewed commit:
        # `nix develop .#comparison -c zig build test -Dcomparison-tests=true`.
        devShells.comparison = pkgs.mkShell {
          inputsFrom = [ default ];
          inherit (default) shellHook;
          packages = [
            tools.klayout
            tools.netgen-vlsi
            tools.magic-vlsi
            tools.ngspice
            tools.fastcap
            tools.fasthenry
            tools.yosys
            tools.openroad
          ];
        };
      }
    );
}
