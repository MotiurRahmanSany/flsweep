#!/usr/bin/env bash
# Builds flsweep (see tool/build.sh) and installs the native binary to
# ~/.local/bin (override with FLSWEEP_INSTALL_DIR).
set -euo pipefail
cd "$(dirname "$0")/.."

"$(dirname "$0")/build.sh"

dest="${FLSWEEP_INSTALL_DIR:-$HOME/.local/bin}"
mkdir -p "$dest"
install -m 0755 build/flsweep "$dest/flsweep"

echo
echo "Installed to $dest/flsweep"
case ":$PATH:" in
  *":$dest:"*) ;;
  *)
    echo "NOTE: $dest is not on your PATH. Add it to your shell profile:"
    echo "  export PATH=\"\$PATH:$dest\""
    ;;
esac
