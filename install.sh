#!/bin/bash
# Installs sbx: symlinks bin/sbx into ~/.local/bin and wires the zsh wrapper.
# Idempotent — safe to run again.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$HOME/.local/bin"
ln -sf "$here/bin/sbx" "$HOME/.local/bin/sbx"
echo "linked ~/.local/bin/sbx -> $here/bin/sbx"

zshrc="$HOME/.zshrc"
line='eval "$(sbx init zsh)"'
if [ -e "$zshrc" ] && grep -q 'sbx init zsh' "$zshrc"; then
  echo "~/.zshrc already sources sbx"
else
  [ -e "$zshrc" ] && cp "$zshrc" "$HOME/.zshrc.bak-sbx"
  printf '\n# sbx: per-folder Supabase accounts\n%s\n' "$line" >> "$zshrc"
  echo "appended to ~/.zshrc (backup at ~/.zshrc.bak-sbx)"
fi

case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "note: add ~/.local/bin to your PATH" ;;
esac
echo "done — open a new shell, then: sbx add <name>"
