#!/usr/bin/env bash
# Downloads the latest flsweep native binary from GitHub Releases and
# installs it to ~/.local/bin. Auto-detects OS and architecture.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/MotiurRahmanSany/flsweep/main/install.sh | bash
set -euo pipefail

repo="MotiurRahmanSany/flsweep"

# 1. Detect OS.
case "$(uname -s)" in
  Linux) os="linux" ;;
  Darwin) os="macos" ;;
  *) echo "Unsupported OS: $(uname -s) — build from source instead." >&2; exit 1 ;;
esac

# 2. Detect arch.
case "$(uname -m)" in
  x86_64|amd64) arch="x64" ;;
  arm64|aarch64) arch="arm64" ;;
  *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

target="${os}-${arch}"

# 3. Resolve the latest release tag.
latest="$(curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" \
  | grep -oP '"tag_name"\s*:\s*"\K[^"]+' 2>/dev/null \
  || curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" \
     | grep -oE '"tag_name"\s*:\s*"[^"]+"' | sed 's/.*"\(.*\)"/\1/')"
latest="${latest#v}"

# 4. Download the matching artifact.
name="flsweep-${latest}-${target}"
url="https://github.com/${repo}/releases/download/v${latest}/${name}.zip"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

if [ "$os" = "linux" ]; then
  url="https://github.com/${repo}/releases/download/v${latest}/${name}.tar.gz"
  echo "Downloading ${name}.tar.gz …"
  curl -fsSL "$url" -o "$tmp/flsweep.tar.gz"
  tar -xzf "$tmp/flsweep.tar.gz" -C "$tmp"
else
  echo "Downloading ${name}.zip …"
  curl -fsSL "$url" -o "$tmp/flsweep.zip"
  unzip -q "$tmp/flsweep.zip" -d "$tmp"
fi

# 5. Install.
dest="${FLSWEEP_INSTALL_DIR:-$HOME/.local/bin}"
mkdir -p "$dest"
if [ -f "$tmp/flsweep" ]; then
  install -m 0755 "$tmp/flsweep" "$dest/flsweep"
elif [ -f "$tmp/flsweep.exe" ]; then
  cp "$tmp/flsweep.exe" "$dest/flsweep.exe"
fi

echo
echo "Installed flsweep ${latest} to ${dest}/flsweep"
case ":$PATH:" in
  *":$dest:"*) ;;
  *)
    echo
    echo "NOTE: $dest is not on your PATH. Add it to your shell profile:"
    echo '  export PATH="$PATH:~/.local/bin"'
    ;;
esac
