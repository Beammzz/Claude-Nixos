# Installing Claude Desktop on NixOS (ARM64)

This guide walks through installing Claude Desktop from this flake on a NixOS
machine, configuring it, signing in, and checking that Claude Code and
Wayland work. It's written for **aarch64-linux**. On x86_64-linux every step
is the same except the `system`/`hostPlatform` value.

If you only want to try the app without changing your system, see
[Try it without installing](#try-it-without-installing).

---

## 1. Prerequisites

- NixOS on `aarch64-linux`. This guide uses `nixos-unstable`, the same nixpkgs this flake pins.
- Flakes enabled:

  ```nix
  # configuration.nix
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  ```

- A graphical session (GNOME, Plasma, Hyprland, Sway, …) with GPU drivers on:

  ```nix
  hardware.graphics.enable = true;
  ```

- A Claude account. Chat works on any plan. The **Code** tab needs Pro, Max,
  Team or Enterprise.

You don't need `allowUnfree`. The flake builds its own packages with unfree
allowed, because Claude Desktop is proprietary.

---

## 2. Add the flake to your system

If your system is already a flake (`/etc/nixos/flake.nix`), add the input and
the module:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    claude-desktop = {
      url = "github:Beammzz/Claude-Nixos";
      # reuse your nixpkgs so GTK, mesa, … aren't downloaded twice
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, claude-desktop, ... }: {
    nixosConfigurations.<hostname> = nixpkgs.lib.nixosSystem {
      modules = [
        claude-desktop.nixosModules.default
        ./configuration.nix
      ];
    };
  };
}
```

If your system isn't a flake yet, create `/etc/nixos/flake.nix` with the
content above. Keep `./configuration.nix` and `./hardware-configuration.nix`
as they are, and replace `<hostname>` with your `networking.hostName`.
`nixos-rebuild` picks up the flake automatically.

---

## 3. Enable it

In `configuration.nix`:

```nix
{
  nixpkgs.hostPlatform = "aarch64-linux";   # usually already in hardware-configuration.nix

  programs.claude-desktop.enable = true;
}
```

That's the whole setup for most people. The defaults give you:

| Feature | Default |
| --- | --- |
| Native Wayland (falls back to X11 when there's no Wayland session) | on |
| Code tab uses the Nix-built Claude Code at the version the app expects | on |
| gnome-keyring as the Secret Service, so you stay logged in | on, except on Plasma (it uses KWallet) |
| `claude` CLI on your PATH | off |
| FHS sandbox for `npx`/`uvx`/`docker` MCP servers | off |

### Common tweaks

```nix
programs.claude-desktop = {
  enable = true;

  # Put the same pinned `claude` CLI on PATH for terminal use.
  claudeCode.installCli = true;

  # Use MCP servers launched with npx / uvx / docker / downloaded binaries.
  fhs = true;
  extraPkgs = pkgs: [ pkgs.go pkgs.rustc ];   # extra tools visible inside the sandbox

  # Force X11/XWayland, e.g. if your compositor has no GlobalShortcuts portal
  # and you want the quick-entry hotkey.
  # wayland = false;
};
```

To pass extra Electron/Chromium flags, override the package:

```nix
{ inputs, ... }:
{
  programs.claude-desktop.package =
    inputs.claude-desktop.packages.aarch64-linux.claude-desktop.override {
      commandLineArgs = "--force-device-scale-factor=1.25";
    };
}
```

(Pass `inputs` to your modules with `specialArgs = { inherit inputs; };` in `nixosSystem`.)

---

## 4. Desktop-environment notes

Claude Desktop uses **xdg-desktop-portal** on Wayland for file pickers,
screen sharing and the global quick-entry hotkey (the GlobalShortcuts
portal). Most desktop modules set this up for you:

| Desktop | What to do |
| --- | --- |
| GNOME (`services.desktopManager.gnome.enable`) | Nothing. GNOME 48+ provides GlobalShortcuts. |
| Plasma 6 (`services.desktopManager.plasma6.enable`) | Nothing. KWallet stores the login and the KDE portal handles shortcuts. |
| Hyprland (`programs.hyprland.enable`) | Nothing. The Hyprland portal is added automatically. |
| Sway / niri / other wlroots | Enable a portal (`xdg.portal.enable = true;` plus `xdg-desktop-portal-wlr` or `-gtk`). If there's no GlobalShortcuts backend, set `programs.claude-desktop.wayland = false;` to get the hotkey through XWayland. |

If the portal is off, `nixos-rebuild` prints a warning from this module.

---

## 5. Build and switch

```sh
sudo nixos-rebuild switch --flake /etc/nixos#<hostname>
```

The first build downloads the ~175 MB `.deb` from `downloads.claude.ai`,
the ~90 MB Claude Code binary, and the libraries from cache.nixos.org.
Nothing heavy is compiled locally.

---

## 6. First launch and sign-in

1. Open **Claude** from your app launcher, or run `claude-desktop`.
2. Click **Get started** and sign in. The browser opens claude.ai and then
   hands the login back to the app through a `claude://` link.
3. Quit and reopen the app. You should still be signed in. If you're not, see
   [Troubleshooting](#troubleshooting).

---

## 7. Check that everything works

### Wayland

```sh
ps -eo args | grep -m1 'lib/claude-desktop/claude-desktop '
```

In a Wayland session the output should include `--ozone-platform=wayland`.

### Claude Code (Code tab)

Open the **Code** tab once, then run:

```sh
grep 'LOCAL OVERRIDE' ~/.config/Claude/logs/main.log
```

Expected output:

```
[CCD] LOCAL OVERRIDE: Using local binary at /nix/store/…-claude-code-2.1.295/bin/claude
```

That line means the app is using the Nix-built Claude Code instead of
downloading a binary that can't run on NixOS.

### CLI (only with `claudeCode.installCli = true`)

```sh
claude --version
```

---

## Try it without installing

```sh
nix run github:Beammzz/Claude-Nixos                   # the app
nix run github:Beammzz/Claude-Nixos#claude-code -- --version
nix profile install github:Beammzz/Claude-Nixos      # per-user install, no module
```

Without the module, keyring, portal and nix-ld settings are up to you. See
[Troubleshooting](#troubleshooting).

---

## Updating

The app has no built-in updater on NixOS. You update it through the flake:

```sh
# take the newest version published in this repo
nix flake update claude-desktop --flake /etc/nixos
sudo nixos-rebuild switch --flake /etc/nixos#<hostname>
```

Maintainers bump the version in this repo with `nix run .#update` (see `CLAUDE.md`).

---

## Troubleshooting

**I'm logged out every time I restart the app.**
No Secret Service is running. The log shows
`[safeStorage] isEncryptionAvailable=false … backend=basic_text`.
Keep `programs.claude-desktop.secretService = true` (gnome-keyring), or use
KWallet on Plasma. The keyring also has to unlock when you log in. NixOS
sets this up for the `login` PAM service and for GDM. greetd (tuigreet,
regreet, …) reuses the `login` stack, so it needs nothing extra. With another
greeter, set `security.pam.services.<name>.enableGnomeKeyring = true;`.

**Sign-in finishes in the browser but the app never notices.**
Check that the `claude://` handler is registered:

```sh
xdg-mime query default x-scheme-handler/claude   # expect com.anthropic.Claude.desktop
xdg-mime default com.anthropic.Claude.desktop x-scheme-handler/claude   # fix it
```

**The window is blurry or uses XWayland.**
Check that `programs.claude-desktop.wayland` isn't `false` and that
`WAYLAND_DISPLAY` is set in the session. You don't need `NIXOS_OZONE_WL`.

**The quick-entry hotkey doesn't work on Wayland.**
Your compositor has no GlobalShortcuts portal. Use GNOME 48+, Plasma or
Hyprland, or set `wayland = false`.

**An MCP server fails with "not found" or "No such file or directory".**
Servers started with `npx`, `uvx`, `docker` or as downloaded binaries need
the FHS sandbox: `programs.claude-desktop.fhs = true;`. Add any extra tools
they need through `extraPkgs`.

**The app exits with "No usable sandbox!".**
Unprivileged user namespaces are disabled, often by a hardened kernel or
profile. Re-enable them:

```nix
security.allowUserNamespaces = true;
boot.kernel.sysctl."kernel.unprivileged_userns_clone" = 1;  # hardened kernels only
```

**The screen is black or the app crashes on start (GPU or driver problems).**
Make sure `hardware.graphics.enable = true;`. As a test, run
`claude-desktop --disable-gpu`. If that helps, make it permanent with
`commandLineArgs` (see [Common tweaks](#common-tweaks)).

**The Code tab says Claude Code is missing.**
Run the `grep 'LOCAL OVERRIDE'` check from step 7. If the line is absent,
check `claudeCode.enable` and look for `[CCD]` errors in
`~/.config/Claude/logs/main.log`.

**Where are my data and logs?**
`~/.config/Claude/`. The logs are in `~/.config/Claude/logs/`. Delete the
directory to reset the app completely.

---

## Not supported yet

- Cowork (workspace VM): it needs qemu, AAVMF firmware and virtiofsd, and
  isn't wired up yet.
- Computer Use and voice dictation: Anthropic disables these on Linux.
- Importing browser cookies from KWallet.

The aarch64 package has been run on an ASUS ProArt PZ13 (Snapdragon X,
Hyprland): it renders natively on Wayland and through XWayland, and it uses
the Nix-built Claude Code. If you run it on other ARM64 hardware, please open
an issue with how it went and attach `~/.config/Claude/logs/main.log`.
