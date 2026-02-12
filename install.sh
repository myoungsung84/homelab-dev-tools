#!/usr/bin/env bash
set -euo pipefail

SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

HOME_DIR="$(cd ~ && pwd)"
TARGET="$HOME_DIR/.homelab-dev-tools"

LINE='[ -f "$HOME/.homelab-dev-tools/lib/env.sh" ] && . "$HOME/.homelab-dev-tools/lib/env.sh"'

BACKUP_DIR="$HOME_DIR/llm-model-backup"
MODEL_DIR_REL="llm/models"

echo "📦 Installing homelab-dev-tools"
echo " - source : $SRC"
echo " - target : $TARGET"
echo

# ------------------------------------------------------------
# Validate source layout
# ------------------------------------------------------------
if [ ! -d "$SRC/bin" ] || [ ! -d "$SRC/lib" ] || [ ! -f "$SRC/lib/env.sh" ]; then
  echo "❌ ERROR: invalid source layout (need bin/, lib/, lib/env.sh)"
  ls -al "$SRC" | sed 's/^/  /'
  exit 1
fi

# ------------------------------------------------------------
# Backup models (if exists)
# ------------------------------------------------------------
if [ -d "$TARGET/$MODEL_DIR_REL" ]; then
  echo "💾 Backing up models..."
  rm -rf "$BACKUP_DIR"
  mkdir -p "$BACKUP_DIR"
  cp -a "$TARGET/$MODEL_DIR_REL/." "$BACKUP_DIR/" 2>/dev/null || true
  echo "✅ Model backup: $BACKUP_DIR"
else
  echo "ℹ️  No existing models to back up."
fi

# ------------------------------------------------------------
# Clean + copy
# ------------------------------------------------------------
echo "🧹 Cleaning target"
rm -rf "$TARGET"
mkdir -p "$TARGET"

echo "📋 Copying (tar pipe)..."
(
  cd "$SRC"
  tar -cf - . | (cd "$TARGET" && tar -xf -)
)

# ------------------------------------------------------------
# Verify
# ------------------------------------------------------------
echo "🔍 Verifying target..."
if [ ! -f "$TARGET/lib/env.sh" ]; then
  echo "❌ INSTALL FAILED: missing $TARGET/lib/env.sh"
  echo "Target listing:"
  ls -al "$TARGET" | sed 's/^/  /'
  exit 1
fi

# ------------------------------------------------------------
# Restore models
# ------------------------------------------------------------
if [ -d "$BACKUP_DIR" ] && [ "$(ls -A "$BACKUP_DIR" 2>/dev/null || true)" != "" ]; then
  echo "♻️  Restoring models..."
  mkdir -p "$TARGET/$MODEL_DIR_REL"
  cp -a "$BACKUP_DIR/." "$TARGET/$MODEL_DIR_REL/" 2>/dev/null || true
  echo "✅ Models restored: $TARGET/$MODEL_DIR_REL"
else
  echo "ℹ️  No model backup to restore."
fi

# ------------------------------------------------------------
# Fix permissions
# ------------------------------------------------------------
echo "🔧 Fixing permissions..."

# 1) bin entrypoints (always executable)
chmod +x "$TARGET/bin/"* 2>/dev/null || true

# 2) all shell scripts (*.sh), excluding heavy / unsafe dirs
find "$TARGET" -type d \( \
    -name .git -o \
    -name node_modules -o \
    -name dist -o \
    -name out -o \
    -name build -o \
    -name releases \
  \) -prune -false -o \
  -type f -name '*.sh' -print0 \
  | xargs -0 chmod +x 2>/dev/null || true

echo "✅ Installed bin:"
ls -al "$TARGET/bin" | sed 's/^/  /'
echo

# ------------------------------------------------------------
# RC selection
# - zsh preferred if detected
# ------------------------------------------------------------
if echo "${SHELL:-}" | grep -q zsh || [ -f "$HOME_DIR/.zshrc" ]; then
  RC="$HOME_DIR/.zshrc"
else
  RC="$HOME_DIR/.bash_profile"
fi
[ -f "$RC" ] || touch "$RC"

# ------------------------------------------------------------
# Append loader line once
# ------------------------------------------------------------
if grep -q 'homelab-dev-tools/lib/env.sh' "$RC"; then
  echo "🔁 Already configured: $RC"
else
  echo "➕ Updating: $RC"
  echo >> "$RC"
  echo "$LINE" >> "$RC"
fi

# ------------------------------------------------------------
# Finish
# ------------------------------------------------------------
echo
echo "🔄 Reloading: $RC"
echo "ℹ️ For changes to take effect in this terminal, run:"
echo "   source \"$RC\""
echo "   hash -r"
echo
echo "✅ After reload, try:"
echo "   which llm"
echo "   llm up"

echo
echo "🎉 Done"