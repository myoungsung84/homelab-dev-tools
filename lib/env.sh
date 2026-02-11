# prevent double-load
[ -n "${HOMELAB_DEV_TOOLS_LOADED:-}" ] && return
export HOMELAB_DEV_TOOLS_LOADED=1

DEVTOOLS_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

export PATH="$DEVTOOLS_ROOT/bin:$PATH"

# prompts path (for scripts)
export HDT_PROMPTS_DIR="$DEVTOOLS_ROOT/prompts"

# aliases
. "$DEVTOOLS_ROOT/lib/aliases.sh"
