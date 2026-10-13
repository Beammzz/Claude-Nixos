# Evaluates a minimal NixOS system that uses the module, for every option
# combination that changes the package graph. Used by `nix flake check`.
{
  self,
  nixpkgs,
  system,
}:
let
  eval =
    cfg:
    (nixpkgs.lib.nixosSystem {
      modules = [
        self.nixosModules.default
        {
          nixpkgs.hostPlatform = system;
          boot.loader.grub.enable = false;
          fileSystems."/" = {
            device = "none";
            fsType = "tmpfs";
          };
          system.stateVersion = "26.05";
          programs.claude-desktop = {
            enable = true;
          }
          // cfg;
        }
      ];
    }).config;
  configs = [
    { }
    { wayland = false; }
    { fhs = true; }
    {
      claudeCode.enable = false;
      claudeCode.installCli = false;
    }
    { claudeCode.installCli = true; }
  ];
in
map (
  cfg:
  let
    c = eval cfg;
  in
  {
    inherit cfg;
    toplevel = c.system.build.toplevel.drvPath;
    nixLd = c.programs.nix-ld.enable;
    keyring = c.services.gnome.gnome-keyring.enable;
    packages = map (p: p.name) (
      builtins.filter (p: nixpkgs.lib.hasPrefix "claude" (p.name or "")) c.environment.systemPackages
    );
    warnings = c.warnings;
  }
) configs
