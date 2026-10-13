# Claude Code CLI at the exact version the desktop app pins.
#
# claude-desktop normally downloads this binary into ~/.config/Claude at
# runtime, but the download is a generic-glibc ELF that cannot run on NixOS.
# Building it here from the manifest embedded in app.asar (see
# scripts/update.sh) gives a patched binary with identical version and
# checksums, which claude-desktop is pointed at via CLAUDE_CODE_LOCAL_BINARY.
#
# Recipe follows nixpkgs' pkgs/by-name/cl/claude-code.
{
  lib,
  stdenvNoCC,
  fetchurl,
  makeBinaryWrapper,
  autoPatchelfHook,
  zstd,
  alsa-lib,
  procps,
  ripgrep,
  bubblewrap,
  socat,
  manifest ? lib.importJSON ./manifest.json,
}:

let
  inherit (stdenvNoCC.hostPlatform) system;
  platformKey =
    {
      aarch64-linux = "linux-arm64";
      x86_64-linux = "linux-x64";
    }
    .${system} or (throw "claude-code: unsupported system ${system}");
  entry = manifest.platforms.${platformKey};
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "claude-code";
  inherit (manifest) version;

  src = fetchurl {
    url = "${manifest.baseUrl}/${finalAttrs.version}/${platformKey}/${entry.binary}";
    sha256 = entry.checksum;
  };

  dontUnpack = true;
  dontBuild = true;
  # Bun single-file executable: stripping drops the embedded script and leaves
  # a bare bun runtime.
  dontStrip = true;

  nativeBuildInputs = [
    autoPatchelfHook
    makeBinaryWrapper
    zstd
  ];

  strictDeps = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin
    unzstd -q $src -o $out/bin/claude
    chmod 755 $out/bin/claude

    wrapProgram $out/bin/claude \
      --set DISABLE_AUTOUPDATER 1 \
      --set DISABLE_INSTALLATION_CHECKS 1 \
      --set USE_BUILTIN_RIPGREP 0 \
      --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [ alsa-lib ]} \
      --prefix PATH : ${
        lib.makeBinPath [
          # tree-kill needs ps
          procps
          ripgrep
          # sandboxed Bash tool
          bubblewrap
          socat
        ]
      }

    runHook postInstall
  '';

  meta = {
    description = "Claude Code CLI, pinned to the version claude-desktop expects";
    homepage = "https://claude.com/product/claude-code";
    license = lib.licenses.unfree;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    platforms = [
      "aarch64-linux"
      "x86_64-linux"
    ];
    mainProgram = "claude";
  };
})
