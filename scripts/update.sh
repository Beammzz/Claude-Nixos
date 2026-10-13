#!/usr/bin/env bash
# Bump pkgs/claude-desktop/sources.json and pkgs/claude-code/manifest.json to
# the newest claude-desktop release in Anthropic's apt repository.
#
# Run through the flake so every tool is on PATH:
#   nix run .#update
#   nix run .#update -- 2.31226.1   # pin an exact version instead of the newest
set -euo pipefail

REPO_URL="https://downloads.claude.ai/claude-desktop/apt/stable"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
SOURCES="$ROOT/pkgs/claude-desktop/sources.json"
MANIFEST="$ROOT/pkgs/claude-code/manifest.json"
WANTED="${1:-}"

# Debian arch -> Nix system
declare -A SYSTEMS=([arm64]=aarch64-linux [amd64]=x86_64-linux)

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Print "version filename sha256" for every stanza of a Packages index.
list_packages() {
  awk '
    /^Package:/  { pkg = $2 }
    /^Version:/  { ver = $2 }
    /^Filename:/ { file = $2 }
    /^SHA256:/   { sha = $2 }
    /^$/ { if (pkg == "claude-desktop") print ver, file, sha; pkg = ver = file = sha = "" }
    END  { if (pkg == "claude-desktop") print ver, file, sha }
  ' "$1"
}

for arch in arm64 amd64; do
  curl -fsSL "$REPO_URL/dists/stable/main/binary-$arch/Packages" -o "$WORK/Packages.$arch"
done

if [[ -z "$WANTED" ]]; then
  # Newest version present for *both* architectures.
  WANTED="$(
    comm -12 \
      <(list_packages "$WORK/Packages.arm64" | awk '{print $1}' | sort -u) \
      <(list_packages "$WORK/Packages.amd64" | awk '{print $1}' | sort -u) |
      sort -V | tail -n1
  )"
fi
[[ -n "$WANTED" ]] || { echo "error: no claude-desktop release found" >&2; exit 1; }

CURRENT="$(jq -r .version "$SOURCES" 2>/dev/null || echo none)"
echo "claude-desktop: $CURRENT -> $WANTED"

platforms='{}'
for arch in arm64 amd64; do
  read -r _ file sha < <(list_packages "$WORK/Packages.$arch" | awk -v v="$WANTED" '$1 == v' | tail -n1) || true
  [[ -n "${file:-}" ]] || { echo "error: $WANTED not published for $arch" >&2; exit 1; }
  sri="$(nix hash convert --hash-algo sha256 --to sri "$sha")"
  platforms="$(jq --arg sys "${SYSTEMS[$arch]}" --arg url "$REPO_URL/$file" --arg hash "$sri" \
    '. + {($sys): {url: $url, hash: $hash}}' <<<"$platforms")"
  [[ "$arch" == arm64 ]] && ARM64_URL="$REPO_URL/$file" && ARM64_SHA="$sha"
done

jq -n --arg version "$WANTED" --argjson platforms "$platforms" \
  '{version: $version, platforms: $platforms}' >"$SOURCES"
echo "wrote $SOURCES"

# The desktop app pins the Claude Code release it drives and embeds that
# release's manifest (version + per-platform checksums) in app.asar. Pull it
# out so pkgs/claude-code builds exactly that version.
echo "downloading $ARM64_URL to extract the pinned Claude Code manifest"
curl -fsSL "$ARM64_URL" -o "$WORK/claude-desktop.deb"
echo "$ARM64_SHA  $WORK/claude-desktop.deb" | sha256sum -c --quiet -
mkdir -p "$WORK/deb"
dpkg-deb --fsys-tarfile "$WORK/claude-desktop.deb" |
  tar -x -C "$WORK/deb" ./usr/lib/claude-desktop/resources/app.asar ./usr/lib/claude-desktop/resources/app.asar.unpacked
asar extract "$WORK/deb/usr/lib/claude-desktop/resources/app.asar" "$WORK/app"

node - "$WORK/app/.vite/build" "$MANIFEST" <<'EOF'
const fs = require("fs");
const path = require("path");
const [dir, out] = process.argv.slice(2);
const re = /JSON\.parse\('(\{"version":"[^']*?"manifest":\{[^']*?)'\)/;
for (const name of fs.readdirSync(dir)) {
  if (!name.endsWith(".js")) continue;
  const m = fs.readFileSync(path.join(dir, name), "utf8").match(re);
  if (!m) continue;
  const pin = JSON.parse(m[1]);
  const { version, buildDate, commit } = pin.manifest;
  const platforms = {};
  for (const key of ["linux-arm64", "linux-x64"]) {
    const p = pin.manifest.platforms[key];
    if (!p) throw new Error(`embedded Claude Code manifest lacks ${key}`);
    platforms[key] = { binary: p.binary, checksum: p.checksum, size: p.size };
  }
  const manifest = { version, buildDate, commit, baseUrl: pin.baseUrl, platforms };
  fs.writeFileSync(out, JSON.stringify(manifest, null, 2) + "\n");
  console.log(`wrote ${out} (claude-code ${version})`);
  process.exit(0);
}
throw new Error("embedded Claude Code manifest not found in app.asar");
EOF

echo "done. Now run: nix build .#claude-desktop && nix flake check"
