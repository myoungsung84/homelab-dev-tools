# ============================================================
# Git shortcuts
# ============================================================

alias gp='git pull'
alias gpp='git push'
alias gs='git status'
alias gl='git log --oneline --graph --decorate'

# ============================================================
# LLM / Git tools (bin/ 에 있는 실행 파일)
# ============================================================

alias gc='gc'
alias gpr='gpr'
alias gpm='gpm'

# ============================================================
# Shell helpers
# ============================================================

alias lg='lazygit'
alias cls='clear'
alias ll='ls -alF'
alias la='ls -A'

# ============================================================
# Functions
# ============================================================

tree () {
  local target="."
  local level=4

  if [ $# -ge 1 ]; then
    if [[ "$1" =~ ^[0-9]+$ ]]; then
      level="$1"
    else
      target="$1"
    fi
  fi

  if [ $# -ge 2 ]; then
    if [[ "$2" =~ ^[0-9]+$ ]]; then
      level="$2"
    fi
  fi

  eza --tree "$target" --level="$level" --icons=never --all \
    --ignore-glob='.git|node_modules|dist|out|build|releases|vendor|.next|coverage|.cache|.turbo|.pnpm-store|.venv|venv|__pycache__|.idea|.vscode|.DS_Store|Thumbs.db'
}
