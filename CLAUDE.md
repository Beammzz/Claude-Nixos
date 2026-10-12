# CLAUDE.md

Guidance for Claude Code (and humans) working in this repository.

## What this is

A Nix flake that repackages Anthropic's **official Claude Desktop Linux build**
(the `.deb` from the apt repo at `https://downloads.claude.ai/claude-desktop/apt/stable`)
for NixOS. The primary target is **aarch64-linux**, and x86_64-linux comes from
the same repo. The scope covers basic Claude, the Claude Code (Code tab)
integration, and Wayland.

## Layout

```
flake.nix                         packages / overlay / nixosModules / apps.update / checks / formatter
flake.lock                        nixpkgs (nixos-unstable)
pkgs/claude-desktop/package.nix   .deb -> NixOS: autoPatchelf, app.asar patches, wrapper
pkgs/claude-desktop/sources.json  GENERATED: version + per-system .deb url/hash
pkgs/claude-desktop/fhs.nix       buildFHSEnv variant (MCP servers via npx/uvx/docker)
pkgs/claude-code/package.nix      Claude Code CLI at the version the desktop pins
pkgs/claude-code/manifest.json    GENERATED: extracted from app.asar by the update script
modules/nixos.nix                 programs.claude-desktop.* NixOS module
scripts/update.sh                 run via `nix run .#update`
tests/module-eval.nix             evaluates NixOS systems with the module (checks.*.nixos-module)
```

Never hand-edit the two GENERATED files. Run `nix run .#update` instead.

## Common commands

```sh
nix run .#update                              # bump to newest apt release (both arches + CC manifest)
nix build .#claude-desktop                    # current system
nix build .#packages.aarch64-linux.claude-desktop --option extra-platforms aarch64-linux
nix flake check                               # builds packages + evaluates the module
nix flake check --all-systems                 # also evaluates aarch64 outputs
nix fmt                                       # nixfmt; run before committing
```

## How the package works (read before changing package.nix)

1. **Bundled Electron, not nixpkgs electron.** The app relies on its own
   `process.resourcesPath` (icons, `ion-dist`, helpers) and its fuses, so we
   keep `usr/lib/claude-desktop/claude-desktop` and patchelf it. Libraries
   that Chromium `dlopen()`s go in `runtimeDependencies` (that list mirrors
   nixpkgs' `electron/binary/generic.nix`). The bundled `libvulkan.so.1` is
   replaced with nixpkgs' vulkan-loader, and `chrome-sandbox` is deleted
   because it can't be setuid in the store, so Chromium uses the userns sandbox.
2. **app.asar is extracted, patched and repacked** in `buildPhase`.
   - The fuses report `EnableEmbeddedAsarIntegrityValidation`, but Electron
     doesn't enforce it on Linux, and a repacked asar has been verified to load.
   - Repacking must keep the same files unpacked: the native `.node` modules and
     `github-mcp-server`. The script builds the `--unpack` glob from the
     basenames found in the original `app.asar.unpacked`.
   - Hardcoded FHS paths (`/bin/bash`, `/bin/ps`, `/usr/bin/busctl`,
     `/usr/bin/secret-tool`, `/usr/bin/update-desktop-database`,
     `/usr/share/applications/…`) are rewritten by `patchLiteral`, which only
     **warns** when a literal disappears.
   - **The Claude Code hook is mandatory.** The release build keeps
     `process.env.CLAUDE_CODE_LOCAL_BINARY` in the CCD binary-manager
     constructor but strips the body. We restore
     `this.localBinaryInitPromise = this.initLocalBinary(...)`. If the anchor
     `process.env.CLAUDE_CODE_LOCAL_BINARY}async initLocalBinary(` disappears,
     the build fails on purpose. Find the new shape with
     `grep -o '.{300}initLocalBinary.{300}'` in the extracted `.vite/build/*.js`
     and update the patch. Match only on string literals and real property
     names (`localBinaryInitPromise`, `initLocalBinary`); minified identifiers
     change every release.
3. **The wrapper must be a shell wrapper** (`makeShellWrapper`).
   `wrapGAppsHook3` otherwise brings in the binary wrapper, which passes
   `${WAYLAND_DISPLAY:+--ozone-platform=wayland ...}` literally instead of
   expanding it at launch.
4. **Claude Code** is built from `pkgs/claude-code/manifest.json`, which is
   the exact manifest the desktop embeds: `JSON.parse('{"version":…,"manifest":…}')`
   in a `.vite/build` chunk. The recipe mirrors nixpkgs'
   `pkgs/by-name/cl/claude-code`, and `dontStrip` is required because Bun binaries.

## Testing without ARM hardware

On an x86_64 host with root, you can register qemu-user through binfmt so Nix
can build aarch64 derivations. The `P`/`O`/`C` flags matter: with only `F`,
the Python of `auto-patchelf` fails with "No module named elftools".

```sh
apt-get install -y qemu-user-static
echo ':qemu-aarch64:M::\x7f\x45\x4c\x46\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xb7\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/usr/libexec/qemu-binfmt/aarch64-binfmt-P:POCF' \
  > /proc/sys/fs/binfmt_misc/register
nix build .#packages.aarch64-linux.claude-desktop --option extra-platforms aarch64-linux
```

Under qemu-user the aarch64 app's main process boots, and the app log shows
`LOCAL OVERRIDE`. The Chromium renderer and GPU processes die with SIGTRAP,
and the userns sandbox is unavailable, so a real GUI test needs real ARM64
hardware.

### Smoke tests on x86_64 (run as a non-root user so the sandbox is used)

- X11: `dbus-run-session -- xvfb-run -a claude-desktop --enable-logging=stderr`
- Wayland: run `weston --backend=headless --renderer=pixman --socket=wayland-9`,
  then `WAYLAND_DISPLAY=wayland-9` (with `DISPLAY` unset), then launch.
- Check `~/.config/Claude/logs/main.log` for
  `[CCD] LOCAL OVERRIDE: Using local binary at /nix/store/...-claude-code-.../bin/claude`.
- GPU and EGL errors in headless runs are expected.

## Conventions

- Format with `nix fmt` (nixfmt). Keep comments explaining *why* a patch exists.
- Add new runtime libraries only for a concrete failing `dlopen`/NEEDED. Add
  new path rewrites only for code paths that run on Linux, since many
  `/usr/bin/*` literals in app.asar are macOS-only (`pgrep`, `sw_vers`, …).
- Keep aarch64-linux working first. Every package must stay buildable on both systems.
- Don't commit `result*` symlinks.
- The x86 apt `Packages` index and the arm64 one can briefly differ in their
  newest version. The update script picks the newest version present for **both**.

## Out of scope / known gaps

- Cowork workspace VM (`qemu-system-aarch64`, `/usr/share/AAVMF/AAVMF_CODE.fd`, virtiofsd).
- `/usr/bin/kwallet-query` (KWallet cookie import) isn't rewritten.
- The Debian postinst also writes an apt source and an AppArmor profile. Neither applies on NixOS.
