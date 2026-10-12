# Claude Desktop, repackaged from Anthropic's official Debian package.
#
# The .deb ships a self-contained Electron app under /usr/lib/claude-desktop.
# We keep its bundled Electron (the app expects its own resources path and
# fuses) and make it run on NixOS by:
#   * patchelf-ing every ELF against nixpkgs libraries (autoPatchelfHook),
#   * rewriting the few FHS paths hardcoded in app.asar to store paths,
#   * re-enabling the app's CLAUDE_CODE_LOCAL_BINARY override so the Code tab
#     runs a Nix-built Claude Code instead of an unpatched downloaded binary,
#   * wrapping the launcher with native Wayland flags.
{
  lib,
  stdenv,
  fetchurl,
  dpkg,
  asar,
  autoPatchelfHook,
  makeShellWrapper,
  wrapGAppsHook3,

  # NEEDED by the bundled ELF files
  alsa-lib,
  at-spi2-atk,
  at-spi2-core,
  cairo,
  cups,
  dbus,
  expat,
  glib,
  gtk3,
  libcap_ng,
  libdrm,
  libgbm,
  libseccomp,
  libx11,
  libxcb,
  libxcomposite,
  libxdamage,
  libxext,
  libxfixes,
  libxkbcommon,
  libxrandr,
  libxtst,
  nspr,
  nss,
  pango,
  pipewire,
  systemd,

  # dlopen()ed at runtime by Chromium/Electron
  libGL,
  libnotify,
  libpulseaudio,
  libsecret,
  libxkbfile,
  libxshmfence,
  pciutils,
  vulkan-loader,

  # programs app.asar invokes by absolute path
  bashInteractive,
  desktop-file-utils,
  gjs,
  procps,
  xdg-utils,

  # Claude Code CLI used by the Code tab; null lets the app download its own
  # (which only works inside an FHS environment or with programs.nix-ld).
  claude-code ? null,
  # true: native Wayland when WAYLAND_DISPLAY is set (falls back to X11
  # otherwise). false: always X11/XWayland, e.g. for the global quick-entry
  # hotkey on compositors without a GlobalShortcuts portal.
  waylandSupport ? true,
  # Extra flags appended to every launch.
  commandLineArgs ? "",
}:

let
  sources = lib.importJSON ./sources.json;
  inherit (stdenv.hostPlatform) system;
  source = sources.platforms.${system} or (throw "claude-desktop: unsupported system ${system}");

  runtimeLibs = [
    libGL
    libnotify
    libpulseaudio
    libsecret
    libxkbfile
    libxshmfence
    pciutils
    (lib.getLib systemd)
    vulkan-loader
  ];

  # Single-quoted by escapeShellArgs, so the wrapper script expands
  # ${WAYLAND_DISPLAY:+...} at launch time rather than at build time.
  waylandFlags =
    if waylandSupport then
      "\${WAYLAND_DISPLAY:+--ozone-platform=wayland --enable-features=WaylandWindowDecorations --enable-wayland-ime=true}"
    else
      "--ozone-platform=x11";

  wrapperArgs = [
    "--prefix"
    "PATH"
    ":"
    (lib.makeBinPath [ xdg-utils ])
  ]
  ++ lib.optionals (claude-code != null) [
    "--set-default"
    "CLAUDE_CODE_LOCAL_BINARY"
    (lib.getExe claude-code)
  ]
  ++ [
    "--add-flags"
    waylandFlags
    "--add-flags"
    commandLineArgs
  ];
in
stdenv.mkDerivation (finalAttrs: {
  pname = "claude-desktop";
  inherit (sources) version;

  src = fetchurl {
    inherit (source) url hash;
  };

  nativeBuildInputs = [
    asar
    autoPatchelfHook
    dpkg
    makeShellWrapper
    wrapGAppsHook3
  ];

  buildInputs = [
    alsa-lib
    at-spi2-atk
    at-spi2-core
    cairo
    cups
    dbus
    expat
    glib
    gtk3
    libcap_ng
    libdrm
    libgbm
    libseccomp
    libx11
    libxcb
    libxcomposite
    libxdamage
    libxext
    libxfixes
    libxkbcommon
    libxrandr
    libxtst
    nspr
    nss
    pango
    pipewire
    (lib.getLib stdenv.cc.cc)
    (lib.getLib systemd)
  ];

  runtimeDependencies = runtimeLibs;

  # The launcher is wrapped by hand below.
  dontWrapGApps = true;

  unpackPhase = ''
    runHook preUnpack
    dpkg-deb --fsys-tarfile "$src" | tar -x --no-same-owner --no-same-permissions
    runHook postUnpack
  '';

  # Patch app.asar: rewrite hardcoded FHS paths and re-enable the Claude Code
  # binary override. Minified identifiers change every release, so patterns
  # match only on string literals and stable property names.
  buildPhase = ''
    runHook preBuild

    appdir=usr/lib/claude-desktop
    resources=$appdir/resources

    asar extract $resources/app.asar app

    # Replace a literal in every bundled JS file containing it; warn (not
    # fail) when a release stops using it.
    patchLiteral() {
      local from="$1" to="$2" files
      files=$(grep -rlF -- "$from" app/.vite || true)
      if [ -z "$files" ]; then
        echo "warning: app.asar no longer contains $from" >&2
        return 0
      fi
      for f in $files; do
        substituteInPlace "$f" --replace-quiet "$from" "$to"
      done
    }

    patchLiteral '"/bin/bash"' '"${lib.getExe bashInteractive}"'
    patchLiteral '"/bin/ps"' '"${lib.getExe' procps "ps"}"'
    patchLiteral '"/usr/bin/busctl"' '"${lib.getExe' systemd "busctl"}"'
    patchLiteral '"/usr/bin/secret-tool"' '"${lib.getExe' libsecret "secret-tool"}"'
    patchLiteral '"/usr/bin/update-desktop-database"' '"${lib.getExe' desktop-file-utils "update-desktop-database"}"'
    # Source of the per-user launcher entry the app writes to
    # ~/.local/share/applications (adds jump-list actions).
    patchLiteral '`/usr/share/applications/''${' "\`$out/share/applications/\''${"

    # The constructor of the Claude Code binary manager evaluates
    # process.env.CLAUDE_CODE_LOCAL_BINARY but its dev-only body was stripped
    # from release builds. Restore it so the override path (which already
    # exists end-to-end: getLocalBinaryPath -> resolution "local_override")
    # becomes reachable.
    ccdFrom='process.env.CLAUDE_CODE_LOCAL_BINARY}async initLocalBinary('
    ccdTo='process.env.CLAUDE_CODE_LOCAL_BINARY&&(this.localBinaryInitPromise=this.initLocalBinary(process.env.CLAUDE_CODE_LOCAL_BINARY))}async initLocalBinary('
    ccdFile=$(grep -rlF -- "$ccdFrom" app/.vite || true)
    if [ -z "$ccdFile" ]; then
      echo "error: CLAUDE_CODE_LOCAL_BINARY hook not found in app.asar; update the patch in package.nix" >&2
      exit 1
    fi
    substituteInPlace $ccdFile --replace-fail "$ccdFrom" "$ccdTo"

    # Repack, keeping exactly the files the original left unpacked (native
    # .node modules and bundled executables) outside the archive.
    unpackGlob=$(cd $resources/app.asar.unpacked && find . -type f -printf '%f\n' | sort -u | paste -sd, -)
    case "$unpackGlob" in
      *,*) unpackGlob="{$unpackGlob}" ;;
    esac
    rm -rf $resources/app.asar $resources/app.asar.unpacked
    asar pack app $resources/app.asar --unpack "$unpackGlob"
    rm -rf app

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib $out/bin
    cp -r usr/lib/claude-desktop $out/lib/claude-desktop
    cp -r usr/share $out/share
    rm -rf $out/share/lintian

    lib=$out/lib/claude-desktop

    # Chromium's setuid helper cannot be setuid in the store; Electron uses
    # the user-namespace sandbox instead.
    rm -f $lib/chrome-sandbox

    # Use nixpkgs' Vulkan loader so ICDs from /run/opengl-driver are found.
    rm -f $lib/libvulkan.so.1
    ln -s ${lib.getLib vulkan-loader}/lib/libvulkan.so.1 $lib/libvulkan.so.1

    # Things the Debian postinst would have installed system-wide.
    if [ -f $lib/resources/linux-mime/com.anthropic.Claude.xml ]; then
      install -Dm644 $lib/resources/linux-mime/com.anthropic.Claude.xml \
        $out/share/mime/packages/com.anthropic.Claude.xml
    fi
    sp=$lib/resources/gnome-search-provider
    if [ -d $sp ]; then
      install -Dm644 $sp/com.anthropic.Claude.search-provider.ini \
        $out/share/gnome-shell/search-providers/com.anthropic.Claude.search-provider.ini
      install -Dm644 $sp/com.anthropic.Claude.SearchProvider.service \
        $out/share/dbus-1/services/com.anthropic.Claude.SearchProvider.service
      substituteInPlace $out/share/dbus-1/services/com.anthropic.Claude.SearchProvider.service \
        --replace-quiet /usr/bin/gjs ${lib.getExe gjs} \
        --replace-quiet /usr/lib/claude-desktop $lib
    fi

    runHook postInstall
  '';

  preFixup = ''
    # Shell (not binary) wrapper: the Wayland flags expand at launch time.
    makeShellWrapper $out/lib/claude-desktop/claude-desktop $out/bin/claude-desktop \
      "''${gappsWrapperArgs[@]}" \
      ${lib.escapeShellArgs wrapperArgs}

    # Terminal launcher shipped by some releases (Debian links it as /usr/bin/ccd).
    if [ -x $out/lib/claude-desktop/resources/bin/ccd ]; then
      ln -s $out/lib/claude-desktop/resources/bin/ccd $out/bin/ccd
    fi
  '';

  passthru = {
    inherit claude-code;
    updateScript = ../../scripts/update.sh;
  };

  meta = {
    description = "Claude desktop app (official Debian build, repackaged for NixOS)";
    homepage = "https://claude.ai/download";
    license = lib.licenses.unfree;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    platforms = builtins.attrNames sources.platforms;
    mainProgram = "claude-desktop";
  };
})
