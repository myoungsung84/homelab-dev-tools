# prevent double-load
[ -n "${HOMELAB_DEV_TOOLS_LOADED:-}" ] && return
export HOMELAB_DEV_TOOLS_LOADED=1

# Resolve this file path robustly:
# - bash: BASH_SOURCE[0]
# - zsh : ${(%):-%N} (path of current sourced file)
if [ -n "${BASH_SOURCE:-}" ] && [ -n "${BASH_SOURCE[0]:-}" ]; then
  _HDT_THIS_FILE="${BASH_SOURCE[0]}"
elif [ -n "${ZSH_VERSION:-}" ]; then
  _HDT_THIS_FILE="${(%):-%N}"
else
  _HDT_THIS_FILE="$0"
fi

# Compute root (.. from lib/)
DEVTOOLS_ROOT="$(cd -- "$(dirname -- "$_HDT_THIS_FILE")/.." && pwd)"

export PATH="$DEVTOOLS_ROOT/bin:$PATH"
export HDT_PROMPTS_DIR="$DEVTOOLS_ROOT/prompts"

# aliases
. "$DEVTOOLS_ROOT/lib/aliases.sh"

unset _HDT_THIS_FILE