self:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.claude-desktop;
  inherit (pkgs.stdenv.hostPlatform) system;

  desktop = cfg.package.override {
    claude-code = if cfg.claudeCode.enable then cfg.package.passthru.claude-code or null else null;
    waylandSupport = cfg.wayland;
  };

  finalPackage =
    if cfg.fhs then
      self.packages.${system}.claude-desktop-fhs.override {
        claude-desktop = desktop;
        inherit (cfg) extraPkgs;
      }
    else
      desktop;
in
{
  options.programs.claude-desktop = {
    enable = lib.mkEnableOption "Claude Desktop, repackaged from Anthropic's official Debian build";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${system}.claude-desktop;
      defaultText = lib.literalExpression "claude-desktop.packages.\${system}.claude-desktop";
      description = "The (non-FHS) claude-desktop package. Options below are applied with `.override`.";
    };

    wayland = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Run natively on Wayland whenever WAYLAND_DISPLAY is set (with
        client-side window decorations and Wayland IME). Disable to force
        X11/XWayland, which makes the global quick-entry hotkey work on
        compositors without an xdg-desktop-portal GlobalShortcuts backend.
      '';
    };

    claudeCode = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Point the Code tab at a Nix-built Claude Code, pinned to the exact
          version this claude-desktop release expects. When disabled the app
          downloads its own binary, which needs programs.nix-ld (enabled
          automatically) or the FHS variant to run.
        '';
      };
      installCli = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Also put that pinned `claude` CLI on the system PATH.";
      };
    };

    fhs = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Run the app inside an FHS environment (bubblewrap) so MCP servers
        started through npx, uvx, docker or prebuilt binaries just work.
      '';
    };

    secretService = lib.mkOption {
      type = lib.types.bool;
      default = !(config.services.desktopManager.plasma6.enable or false);
      defaultText = lib.literalExpression "!config.services.desktopManager.plasma6.enable";
      description = ''
        Enable gnome-keyring as the Secret Service provider. Electron's
        safeStorage needs one (or KWallet on Plasma) to keep you logged in;
        without it the app falls back to plaintext and forgets the session.
      '';
    };

    extraPkgs = lib.mkOption {
      type = lib.types.functionTo (lib.types.listOf lib.types.package);
      default = _: [ ];
      defaultText = lib.literalExpression "pkgs: [ ]";
      example = lib.literalExpression "pkgs: [ pkgs.go pkgs.rustc ]";
      description = "Extra packages made visible inside the FHS environment (only with `fhs = true`).";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      finalPackage
    ]
    ++ lib.optional (cfg.claudeCode.installCli && desktop.claude-code != null) desktop.claude-code;

    # GNOME Shell search provider (D-Bus activated), when the release ships one.
    services.dbus.packages = [ desktop ];

    services.gnome.gnome-keyring.enable = lib.mkIf cfg.secretService (lib.mkDefault true);

    # The app-downloaded Claude Code is a generic glibc binary.
    programs.nix-ld.enable = lib.mkIf (!cfg.claudeCode.enable && !cfg.fhs) (lib.mkDefault true);

    warnings = lib.optional (cfg.wayland && !config.xdg.portal.enable) ''
      programs.claude-desktop: xdg.portal is disabled. On Wayland, Claude Desktop
      needs xdg-desktop-portal for file pickers, screen sharing and the global
      quick-entry hotkey (GlobalShortcuts). Most desktop environment modules
      enable it; otherwise set xdg.portal.enable and add a backend.
    '';
  };
}
