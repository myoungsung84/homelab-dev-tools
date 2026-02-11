#!/usr/bin/env bash
set -euo pipefail

SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

HOME_DIR="$(cd ~ && pwd)"
TARGET="$HOME_DIR/.homelab-dev-tools"

LINE='[ -f "$HOME/.homelab-dev-tools/lib/env.sh" ] && . "$HOME/.homelab-dev-tools/lib/env.sh"'

echo "📦 Installing homelab-dev-tools"
echo " - source : $SRC"
echo " - target : $TARGET"
echo

if [ ! -d "$SRC/bin" ] || [ ! -d "$SRC/lib" ] || [ ! -f "$SRC/lib/env.sh" ]; then
  echo "❌ ERROR: invalid source layout (need bin/, lib/, lib/env.sh)"
  ls -al "$SRC" | sed 's/^/  /'
  exit 1
fi

echo "🧹 Cleaning target"
rm -rf "$TARGET"
mkdir -p "$TARGET"

echo "📋 Copying (tar pipe)..."
(
  cd "$SRC"
  tar -cf - . | (cd "$TARGET" && tar -xf -)
)

echo "🔍 Verifying target..."
if [ ! -f "$TARGET/lib/env.sh" ]; then
  echo "❌ INSTALL FAILED: missing $TARGET/lib/env.sh"
  echo "Target listing:"
  ls -al "$TARGET" | sed 's/^/  /'
  exit 1
fi

echo "✅ Installed bin:"
ls -al "$TARGET/bin" | sed 's/^/  /'
echo

if echo "${SHELL:-}" | grep -q zsh || [ -f "$HOME_DIR/.zshrc" ]; then
  RC="$HOME_DIR/.zshrc"
else
  RC="$HOME_DIR/.bash_profile"
fi
[ -f "$RC" ] || touch "$RC"

if grep -q 'homelab-dev-tools/lib/env.sh' "$RC"; then
  echo "🔁 Already configured: $RC"
else
  echo "➕ Updating: $RC"
  echo >> "$RC"
  echo "$LINE" >> "$RC"
fi

echo
echo "🔄 Reloading: $RC"

if [ -n "${BASH_VERSION:-}" ]; then
  source "$RC" || true
fi

hash -r 2>/dev/null || true

echo
echo "🎉 Done"
echo "✅ Try:"
echo "   which llm"
echo "   llm up"
