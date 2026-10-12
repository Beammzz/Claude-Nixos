{
  description = "Claude Desktop (official Debian build) repackaged for NixOS, with Claude Code and Wayland";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;
      # aarch64-linux is the primary target; x86_64-linux comes for free from
      # the same apt repository.
      systems = [
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAllSystems =
        f:
        lib.genAttrs systems (
          system:
          f (
            import nixpkgs {
              inherit system;
              config.allowUnfree = true;
              overlays = [ self.overlays.default ];
            }
          )
        );
    in
    {
      overlays.default = final: _prev: {
        claude-desktop = final.callPackage ./pkgs/claude-desktop/package.nix {
          claude-code = final.callPackage ./pkgs/claude-code/package.nix { };
        };
        claude-desktop-fhs = final.callPackage ./pkgs/claude-desktop/fhs.nix { };
      };

      packages = forAllSystems (pkgs: {
        inherit (pkgs) claude-desktop claude-desktop-fhs;
        inherit (pkgs.claude-desktop) claude-code;
        default = pkgs.claude-desktop;
      });

      apps = forAllSystems (pkgs: {
        default = {
          type = "app";
          program = lib.getExe pkgs.claude-desktop;
          meta.description = "Run Claude Desktop";
        };
        update = {
          type = "app";
          program = lib.getExe (
            pkgs.writeShellApplication {
              name = "claude-desktop-update";
              runtimeInputs = with pkgs; [
                asar
                coreutils
                curl
                dpkg
                gawk
                git
                gnutar
                jq
                nix
                nodejs
                xz
              ];
              text = builtins.readFile ./scripts/update.sh;
            }
          );
          meta.description = "Bump claude-desktop to the newest apt release";
        };
      });

      nixosModules.default = import ./modules/nixos.nix self;
      nixosModules.claude-desktop = self.nixosModules.default;

      checks = forAllSystems (pkgs: {
        inherit (pkgs) claude-desktop claude-desktop-fhs;
        inherit (pkgs.claude-desktop) claude-code;
        # Evaluates whole NixOS systems using the module (nothing is built).
        nixos-module = pkgs.writeText "claude-desktop-module-eval.json" (
          builtins.unsafeDiscardStringContext (
            builtins.toJSON (
              import ./tests/module-eval.nix {
                inherit self nixpkgs;
                inherit (pkgs.stdenv.hostPlatform) system;
              }
            )
          )
        );
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
