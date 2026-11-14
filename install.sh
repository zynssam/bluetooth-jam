#!/usr/bin/env bash
# =====================================================================
#  install.sh — makes the scripts executable and adds a "bt-jam"
#  command so you can start the jam from any terminal.
#  Uninstall:  ./install.sh --uninstall
# =====================================================================

JAM_HOME="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
BIN_DIR="$HOME/.local/bin"
LINK="$BIN_DIR/bt-jam"

if [[ ${1:-} == --uninstall ]]; then
  rm -f "$LINK" && echo "Removed $LINK"
  exit 0
fi

chmod +x "$JAM_HOME"/*.sh "$JAM_HOME"/lib/*.sh "$JAM_HOME"/tests/*.sh 2>/dev/null
mkdir -p "$BIN_DIR"
ln -sf "$JAM_HOME/jam.sh" "$LINK"
echo "✔ Installed: type  bt-jam  in any terminal."

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "⚠ $BIN_DIR isn't on your PATH yet. Add this line to ~/.bashrc:"
     echo "    export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

echo
"$JAM_HOME/check_deps.sh"
