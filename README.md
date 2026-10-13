# Claude-Nixos

Claude Desktop on NixOS. This flake repackages Anthropic's **official Linux
build** (the `claude-desktop` package from `downloads.claude.ai`, the same one
Debian/Ubuntu users install with apt) for NixOS.

- **Primary target: `aarch64-linux`** (ARM64). `x86_64-linux` is built from the same apt repo too.
- **Basic Claude**: chat, projects, MCP, and the other desktop features.
- **Claude Code**: the Code tab runs a Nix-built `claude` CLI, pinned to the exact
  version the desktop release expects.
- **Wayland**: runs natively on Wayland, with client-side decorations and IME, and falls back to X11.

## Quick start

For the full step-by-step install guide (desktop-environment notes, how to
check that it works, troubleshooting), see **[instruction.md](instruction.md)**.

### NixOS module (recommended)

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    claude-desktop = {
      url = "github:Beammzz/Claude-Nixos";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, claude-desktop, ... }: {
    nixosConfigurations.my-arm-box = nixpkgs.lib.nixosSystem {
      modules = [
        claude-desktop.nixosModules.default
        {
          nixpkgs.hostPlatform = "aarch64-linux";
          programs.claude-desktop.enable = true;
        }
        ./configuration.nix
      ];
    };
  };
}
```

The flake builds its packages with `allowUnfree` internally, so you don't need
to change your own nixpkgs config.

### Without the module

```sh
nix run github:Beammzz/Claude-Nixos                     # try it
nix profile install github:Beammzz/Claude-Nixos         # install it
nix build github:Beammzz/Claude-Nixos#claude-desktop-fhs
```

The package is also available through `overlays.default` (`pkgs.claude-desktop`,
`pkgs.claude-desktop-fhs`).

## Module options

| Option | Default | What it does |
| --- | --- | --- |
| `programs.claude-desktop.enable` | `false` | Install Claude Desktop. |
| `programs.claude-desktop.wayland` | `true` | Run natively on Wayland when `WAYLAND_DISPLAY` is set. Set it to `false` to force X11/XWayland. |
| `programs.claude-desktop.claudeCode.enable` | `true` | Point the Code tab at the Nix-built, version-pinned Claude Code. If you turn it off, the app downloads its own copy and `programs.nix-ld` is enabled so that copy can run. |
| `programs.claude-desktop.claudeCode.installCli` | `false` | Also put that pinned `claude` on the system `PATH`. |
| `programs.claude-desktop.fhs` | `false` | Run inside an FHS sandbox (bubblewrap), so MCP servers started through `npx`, `uvx`, `docker` or as prebuilt binaries work. |
| `programs.claude-desktop.extraPkgs` | `pkgs: [ ]` | Extra packages visible inside the FHS sandbox. |
| `programs.claude-desktop.secretService` | `true`, or `false` on Plasma | Enables gnome-keyring so your login survives restarts. Plasma uses KWallet instead. |
| `programs.claude-desktop.package` | this flake's build | The base package. The options above are applied to it with `.override`. |

Without the module, set the same choices with `.override`:

```nix
claude-desktop.packages.aarch64-linux.claude-desktop.override {
  waylandSupport = false;          # force X11
  claude-code = null;              # let the app download Claude Code itself
  commandLineArgs = "--force-device-scale-factor=1.25";
}
```

## Wayland notes

- With `wayland = true`, the launcher adds
  `--ozone-platform=wayland --enable-features=WaylandWindowDecorations --enable-wayland-ime=true`
  whenever `WAYLAND_DISPLAY` is set. Thai, Japanese and other IMEs work through text-input.
- The **global quick-entry hotkey** needs an xdg-desktop-portal backend that implements
  **GlobalShortcuts**: KDE, GNOME 48+ or Hyprland. Portals are also used for file pickers and screen sharing. If your compositor has no
  GlobalShortcuts backend, set `wayland = false` to get the hotkey through XWayland.

## How Claude Code is wired up

The desktop app normally downloads the Claude Code binary into
`~/.config/Claude/claude-code/<version>/` and runs it. That binary is a
generic-glibc ELF, so it can't run on NixOS. This flake instead:

1. extracts the Claude Code release manifest (version and checksums) that's embedded in
   `app.asar` into `pkgs/claude-code/manifest.json`,
2. builds that exact release with Nix (`packages.<system>.claude-code`), and
3. re-enables the app's `CLAUDE_CODE_LOCAL_BINARY` override. The release build
   strips it, so it's restored with a one-line patch. The wrapper then points
   the variable at the Nix-built CLI.

The app log confirms it:
`[CCD] LOCAL OVERRIDE: Using local binary at /nix/store/…-claude-code-2.1.295/bin/claude`.
You can still export `CLAUDE_CODE_LOCAL_BINARY` yourself to use a different `claude`.

## Updating

```sh
nix run .#update            # newest release in the apt repo
nix run .#update -- 2.31226.1
nix flake check
```

The update script rewrites `pkgs/claude-desktop/sources.json` and
`pkgs/claude-code/manifest.json`.

## Not supported (yet)

- **Cowork / workspace VM**: this needs `qemu-system-aarch64`, AAVMF firmware at
  `/usr/share/AAVMF` and virtiofsd. It isn't wired up.
- Computer Use and voice dictation: Anthropic disables these on Linux.
- Importing browser cookies from KWallet. The app calls `/usr/bin/kwallet-query`
  directly, and that path isn't patched.

## Verification status

| | x86_64-linux | aarch64-linux |
| --- | --- | --- |
| Package builds, every ELF resolves (`autoPatchelf`) | ✅ | ✅ (built under qemu binfmt) |
| App launches and renders (X11 / Xvfb) | ✅ | ⚠️ the main process boots under qemu-user, but the Chromium renderer can't run there |
| Native Wayland (weston headless) | ✅ | not tested |
| Code tab uses the Nix-built Claude Code (`LOCAL OVERRIDE` in the log) | ✅ | ✅ |
| `claude --version` | ✅ 2.1.295 | ✅ 2.1.295 |
| NixOS module evaluates (every option combination) | ✅ | ✅ |

The aarch64 build hasn't been run on real ARM64 hardware yet. If you run it on
one, please report back.

Not affiliated with Anthropic. Claude Desktop is proprietary software. This
repository only contains Nix expressions that fetch Anthropic's published package.
