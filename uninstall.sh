#!/usr/bin/env bash
set -euo pipefail

HOME_DIR="$(cd ~ && pwd)"
TARGET="$HOME_DIR/.homelab-dev-tools"

NEEDLE='homelab-dev-tools/lib/env.sh'

echo "🧹 Uninstalling homelab-dev-tools"
echo " - target : $TARGET"
echo

if echo "${SHELL:-}" | grep -q zsh || [ -f "$HOME_DIR/.zshrc" ]; then
  RC="$HOME_DIR/.zshrc"
else
  RC="$HOME_DIR/.bash_profile"
fi

remove_line_from() {
  local file="$1"
  [ -f "$file" ] || return 0

  if grep -q "$NEEDLE" "$file"; then
    echo "✂️  Removing config from: $file"
    if sed --version >/dev/null 2>&1; then
      sed -i "/$NEEDLE/d" "$file"
    else
      sed -i '' "/$NEEDLE/d" "$file"
    fi
  else
    echo "✅ No config in: $file"
  fi
}

remove_line_from "$RC"

remove_line_from "$HOME_DIR/.bashrc"
remove_line_from "$HOME_DIR/.profile"
remove_line_from "$HOME_DIR/.zprofile"

if [ -d "$TARGET" ]; then
  echo "🗑️  Removing: $TARGET"
  rm -rf "$TARGET"
else
  echo "✅ Already removed: $TARGET"
fi

echo
echo "🎉 Done"
echo "ℹ️  Open a new terminal (or reload your rc file) to fully apply changes."
