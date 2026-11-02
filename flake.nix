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
        # `zig build --fetch` in a fixed-output derivation: the one network step, so the
        # build below runs offline from a global cache seeded with its packages.
        deps = pkgs.stdenvNoCC.mkDerivation {
          name = "gpurify-zig-deps";
          src = ./.;
          nativeBuildInputs = [ zig ];
          SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
          buildPhase = ''
            export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig
            zig build --fetch
            mv $ZIG_GLOBAL_CACHE_DIR/p $out
          '';
          dontInstall = true;
          dontFixup = true;
          outputHashMode = "recursive";
          outputHash = "sha256-NVf2cvawGiNOwpO3Dwbv4qbXHpRA8uSLQ8bFobpPNZY=";
        };
        gpurify = pkgs.stdenv.mkDerivation {
          pname = "gpurify";
          version = "0.0.0";
          src = ./.;
          nativeBuildInputs = [ zig ] ++ pkgs.lib.optional pkgs.stdenv.isLinux pkgs.autoPatchelfHook;
          # Zig cannot see the libc ABI inside the sandbox, so Linux names glibc and
          # autoPatchelfHook points the loader at nixpkgs'. Baseline CPU: the result is cached
          # and run on other machines. The decks are compiled in: `bin/gpurify` is the install.
          buildPhase = ''
            export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig
            mkdir -p $ZIG_GLOBAL_CACHE_DIR && cp -r ${deps} $ZIG_GLOBAL_CACHE_DIR/p
            zig build install -Doptimize=ReleaseFast -Dcpu=baseline -Dcuda-arch=none --prefix $out \
              ${pkgs.lib.optionalString pkgs.stdenv.isLinux "-Dtarget=${pkgs.stdenv.hostPlatform.parsed.cpu.name}-linux-gnu"}
          '';
          dontInstall = true;
          meta.mainProgram = "gpurify";
        };
      in
      {
        packages.default = gpurify;
        packages.gpurify = gpurify;
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
