# claude-desktop inside an FHS sandbox (bubblewrap), for MCP servers and other
# tools that download generic Linux binaries or expect /usr/bin/* paths:
# `npx`/`uvx`-launched MCP servers, Docker-based servers, the app's own
# downloaded Claude Code when the Nix-built one is disabled, ...
{
  lib,
  buildFHSEnv,
  claude-desktop,
  # pkgs: [ ... ] extra packages visible inside the environment
  extraPkgs ? pkgs: [ ],
}:

buildFHSEnv {
  pname = "claude-desktop";
  inherit (claude-desktop) version;

  targetPkgs =
    pkgs:
    [ claude-desktop ]
    ++ (with pkgs; [
      bashInteractive
      coreutils
      curl
      docker-client
      git
      glibc
      nodejs
      openssl
      procps
      python3
      uv
      which
    ])
    ++ extraPkgs pkgs;

  runScript = lib.getExe claude-desktop;

  extraInstallCommands = ''
    mkdir -p $out/share
    for dir in ${claude-desktop}/share/*; do
      ln -s "$dir" "$out/share/$(basename "$dir")"
    done
  '';

  passthru = {
    inherit claude-desktop;
    inherit (claude-desktop) claude-code;
  };

  meta = claude-desktop.meta // {
    description = "${claude-desktop.meta.description} (FHS environment)";
  };
}
