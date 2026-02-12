#!/usr/bin/env bash
set -euo pipefail

# -------------------------
# Preflight: jq required
# -------------------------
require_jq() {
  if command -v jq >/dev/null 2>&1; then
    return 0
  fi

  local uname_out=""
  uname_out="$(uname -s 2>/dev/null || true)"

  echo "bash: jq: command not found"
  echo
  echo "⛔ ERROR: This script requires 'jq' (JSON processor)."
  echo

  if echo "$uname_out" | grep -Eqi 'MINGW|MSYS|CYGWIN'; then
    echo "🪟 Windows (Git Bash) install logs (Scoop):"
    echo
    echo "\$ jq --version"
    echo "bash: jq: command not found"
    echo
    echo "\$ scoop install jq"
    echo "Installing 'jq' (1.7.1) [64bit] ..."
    echo "jq.exe (xxx KB) [====================] 100%"
    echo "Linking ~\\scoop\\apps\\jq\\current\\jq.exe to ~\\scoop\\shims\\jq.exe"
    echo
    echo "\$ jq --version"
    echo "jq-1.7.1"
    echo
    echo "If scoop is missing:"
    echo "  (PowerShell) Set-ExecutionPolicy RemoteSigned -Scope CurrentUser"
    echo "  (PowerShell) irm get.scoop.sh | iex"
    echo "  (Git Bash)   scoop install jq"
    exit 1
  fi

  if echo "$uname_out" | grep -Eqi 'Darwin'; then
    echo "🍎 macOS install logs (Homebrew):"
    echo
    echo "\$ jq --version"
    echo "zsh: command not found: jq"
    echo
    echo "\$ brew install jq"
    echo "==> Downloading ..."
    echo "==> Pouring jq--1.7.1.arm64_ventura.bottle.tar.gz"
    echo "🍺  /opt/homebrew/Cellar/jq/1.7.1: xx files, xxMB"
    echo
    echo "\$ jq --version"
    echo "jq-1.7.1"
    exit 1
  fi

  echo "🐧 Linux install (Debian/Ubuntu):"
  echo
  echo "\$ jq --version"
  echo "jq: command not found"
  echo
  echo "\$ sudo apt update && sudo apt install -y jq"
  echo
  echo "\$ jq --version"
  echo "jq-1.7.1"
  exit 1
}

require_jq

# -------------------------
# Script dirs (dev-tools)
# -------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
PROMPTS_DIR="${HDT_PROMPTS_DIR:-$TOOLS_ROOT/prompts}"

# -------------------------
# IMPORTANT: Always operate on the caller's git repo
# -------------------------
REPO_ROOT="${HOMELAB_REPO_ROOT:-}"
if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
fi
if [ -z "$REPO_ROOT" ] || [ ! -d "$REPO_ROOT/.git" ] && [ ! -f "$REPO_ROOT/.git" ]; then
  echo "ERROR: Not inside a git repository."
  echo "TIP: run this inside a repo (or set HOMELAB_REPO_ROOT)."
  exit 1
fi
cd "$REPO_ROOT"

# -------------------------
# Config
# -------------------------
BASE_URL="${LLM_BASE_URL:-http://localhost:18080}"
MODEL="${LLM_MODEL:-}"

# NOTE:
# - Windows/Docker(8192 ctx) 기준이면 크게 문제 없음.
# - mac native(ctx 2048 등)에서는 너무 크면 아래 "자동 축소 재시도"로 해결.
MAX_CHARS="${LLM_DIFF_MAX_CHARS:-12000}"

# Retry when ctx exceeded (mac native 대비)
MAX_RETRIES="${LLM_MAX_RETRIES:-3}"

# -------------------------
# Args
# -------------------------
SHOW_DIFF=0
SYSTEM_PATH=""
USER_PATH=""
OUT_FILE=""

usage() {
  cat <<'EOF'
Usage:
  generate-commit.sh [--show-diff] [--system <path>] [--user <path>] [--out <file>]

Flags:
  --show-diff   Print the bundle that will be sent to LLM (truncated)
  --system <p>  System prompt path (default: <dev-tools>/prompts/commit.system.txt)
  --user <p>    User prompt path   (default: <dev-tools>/prompts/commit.user.txt)
  --out <file>  Write ONLY the commit message to a file (no banner). Also prints preview banner to stdout.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --show-diff) SHOW_DIFF=1; shift ;;
    --system) SYSTEM_PATH="${2:-}"; shift 2 ;;
    --user) USER_PATH="${2:-}"; shift 2 ;;
    --out) OUT_FILE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown arg: $1"; usage; exit 1 ;;
  esac
done

# -------------------------
# Helpers
# -------------------------
normalize_utf8() {
  if command -v iconv >/dev/null 2>&1; then
    iconv -f UTF-8 -t UTF-8//IGNORE 2>/dev/null || true
  else
    cat
  fi
}

# ✅ macOS sed 라벨/루프 이슈 제거: perl로 trim/blank 정리 (윈/리눅/맥 공통)
read_file_trim() {
  local p="$1"
  [ -f "$p" ] || return 1

  cat "$p" \
    | normalize_utf8 \
    | perl -0777 -pe '
        s/\r$//mg;           # drop CR
        s/[ \t]+$//mg;       # trim trailing spaces each line
        s/\n{3,}/\n\n/g;     # collapse 3+ newlines to 2
        s/^\n+//;            # trim leading newlines
        s/\n+\z/\n/;         # trim trailing newlines, keep one
      ' \
    || true
}

apply_template_input() {
  local tpl="$1"
  local input="$2"
  jq -nr --arg tpl "$tpl" --arg input "$input" -r \
    '$tpl | gsub("\\{\\{INPUT\\}\\}"; $input)'
}

truncate() {
  local text="$1"
  local max="$2"
  local len="${#text}"
  if [ "$len" -le "$max" ]; then
    printf '%s' "$text"
    return
  fi
  local remain=$((len - max))
  printf '%s' "${text:0:max}"
  printf '\n\n... (truncated %s chars)' "$remain"
}

print_diff_debug() {
  local bundle="$1"
  local clipped
  clipped="$(truncate "$bundle" "$MAX_CHARS")"
  echo
  echo "===== DIFF (SENT TO LLM) ====="
  echo
  printf '%s\n' "$clipped"
  echo
  echo "=============================="
  echo
}

sanitize_commit_message() {
  local text="$1"
  text="${text//$'\r\n'/$'\n'}"
  text="$(printf '%s' "$text" | sed -e 's/^[[:space:]]\+//' -e 's/[[:space:]]\+$//')"

  if printf '%s' "$text" | head -n 1 | grep -q '^```'; then
    text="$(printf '%s' "$text" \
      | sed -e '1s/^```[A-Za-z]*[[:space:]]*$//' -e '$s/^```[[:space:]]*$//' \
      | sed -e 's/^[[:space:]]\+//' -e 's/[[:space:]]\+$//')"
  fi

  if [ "${text:0:1}" = '"' ] && [ "${text: -1}" = '"' ]; then
    text="${text:1:${#text}-2}"
  elif [ "${text:0:1}" = "'" ] && [ "${text: -1}" = "'" ]; then
    text="${text:1:${#text}-2}"
  fi

  printf '%s' "$text"
}

get_untracked_files() {
  local porcelain raw_list
  porcelain="$(git status --porcelain 2>/dev/null || true)"
  [ -n "$porcelain" ] || { printf '%s' ""; return; }

  raw_list="$(printf '%s\n' "$porcelain" \
    | sed -n 's/^[?][?][[:space:]]\+//p' \
    | sed -e 's/[[:space:]]\+$//' \
    | awk 'NF')"

  [ -n "$raw_list" ] || { printf '%s' ""; return; }

  printf '%s\n' "$raw_list" | sed 's|\\|/|g'
}

format_untracked_section() {
  local files_text="$1"
  [ -n "$files_text" ] || { printf '%s' ""; return; }

  {
    echo "### UNTRACKED FILES (paths only)"
    echo
    printf '%s\n' "$files_text"
    echo
  }
}

build_diff_bundle() {
  local stat_staged status main_diff
  stat_staged="$(git diff --staged --stat 2>/dev/null || true)"
  status="$(git status --porcelain 2>/dev/null || true)"
  main_diff="$(git diff --staged 2>/dev/null || true)"

  local header
  header=$(
    cat <<EOF
### CHANGE OVERVIEW

## git diff --staged --stat
${stat_staged:-"(empty)"}

## git status --porcelain
${status:-"(empty)"}

EOF
  )

  local diff_section
  diff_section=$(
    cat <<EOF
### DIFF (STAGED ONLY)

${main_diff:-"(empty)"}

EOF
  )

  local files_text untracked_section
  files_text="$(get_untracked_files)"
  untracked_section="$(format_untracked_section "$files_text")"

  printf '%s\n%s\n%s' "$header" "$diff_section" "$untracked_section" | normalize_utf8
}

check_health() {
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 3 "${BASE_URL}/health" || true)"
  [ "$code" = "200" ] || return 1
  return 0
}

# globals for error handling
LLM_ERR_HTTP=""
LLM_ERR_BODY=""

call_llm() {
  local system="$1"
  local user="$2"

  local payload tmp_json tmp_utf8 tmp_body tmp_err http_code body
  tmp_json="$(mktemp -t llm-payload.XXXXXX.json)"
  tmp_utf8="$(mktemp -t llm-payload.XXXXXX.utf8.json)"
  tmp_body="$(mktemp -t llm-body.XXXXXX.json)"
  tmp_err="$(mktemp -t llm-err.XXXXXX.log)"

  payload="$(
    jq -n \
      --arg model "$MODEL" \
      --arg system "$system" \
      --arg user "$user" \
      '{
        temperature: 0.2,
        messages: [
          {role:"system", content:$system},
          {role:"user", content:$user}
        ]
      } + (if ($model|length) > 0 then {model:$model} else {} end)'
  )"

  printf '%s' "$payload" > "$tmp_json"

  # Re-encode payload to clean UTF-8 bytes
  if command -v iconv >/dev/null 2>&1; then
    if iconv -f UTF-8 -t UTF-8//IGNORE "$tmp_json" > "$tmp_utf8" 2>/dev/null; then
      :
    elif iconv -f CP949 -t UTF-8//IGNORE "$tmp_json" > "$tmp_utf8" 2>/dev/null; then
      :
    else
      LC_ALL=C tr -cd '\11\12\15\40-\176' < "$tmp_json" > "$tmp_utf8" || true
    fi
  else
    LC_ALL=C tr -cd '\11\12\15\40-\176' < "$tmp_json" > "$tmp_utf8" || true
  fi

  # ✅ 가장 안정적인 방식: body는 파일로, http_code는 stdout으로만 받기
  http_code="$(
    curl -sS \
      -o "$tmp_body" \
      -w '%{http_code}' \
      -H 'content-type: application/json; charset=utf-8' \
      --data-binary "@$tmp_utf8" \
      "${BASE_URL}/v1/chat/completions" \
      2>"$tmp_err" || true
  )"

  body="$(cat "$tmp_body" 2>/dev/null || true)"

  rm -f "$tmp_json" "$tmp_utf8" "$tmp_body" || true

  # curl이 아예 실패하면 http_code가 비거나 000인 경우가 많음
  http_code="${http_code//$'\r'/}"
  http_code="$(printf '%s' "$http_code" | tr -d '[:space:]')"
  if [ -z "${http_code:-}" ]; then
    http_code="000"
  fi

  if [ "$http_code" != "200" ]; then
    echo "ERROR: LLM request failed (HTTP ${http_code})" >&2
    echo "----- LLM ERROR BODY -----" >&2
    printf '%s\n' "${body:-}" >&2
    echo "--------------------------" >&2

    if [ "$http_code" = "000" ]; then
      echo "----- CURL ERROR (network/connection) -----" >&2
      cat "$tmp_err" >&2 || true
      echo "------------------------------------------" >&2
      echo "TIP: check server: curl -sS ${BASE_URL}/health" >&2
    fi

    rm -f "$tmp_err" || true
    return 1
  fi

  rm -f "$tmp_err" || true
  printf '%s' "$body" | jq -r '.choices[0].message.content // empty'
}

# parse llama.cpp exceed-context error payload (best-effort)
# returns "n_prompt_tokens n_ctx"
parse_exceed_ctx() {
  local body="$1"
  # body might be json: {"error":{"code":400,"message":"...","type":"exceed_context_size_error","n_prompt_tokens":4742,"n_ctx":2048}}
  printf '%s' "$body" | jq -r '
    if (.error.type? // "") == "exceed_context_size_error"
    then "\(.error.n_prompt_tokens // 0) \(.error.n_ctx // 0)"
    else ""
    end
  ' 2>/dev/null || true
}

# -------------------------
# Main
# -------------------------
DEFAULT_SYSTEM_PATH="$PROMPTS_DIR/commit.system.txt"
DEFAULT_USER_PATH="$PROMPTS_DIR/commit.user.txt"

SYSTEM_PATH_ABS="${SYSTEM_PATH:-$DEFAULT_SYSTEM_PATH}"
USER_PATH_ABS="${USER_PATH:-$DEFAULT_USER_PATH}"

if ! check_health; then
  echo "ERROR: LLM server is not reachable."
  echo "TIP: Start it first: llm up"
  exit 1
fi

if git diff --staged --quiet; then
  echo "ERROR: No staged changes. (staged-only mode)"
  echo "TIP: stage files first: git add -A"
  exit 1
fi

bundle="$(build_diff_bundle)"
if [ -z "$(printf '%s' "$bundle" | tr -d '[:space:]')" ]; then
  echo "INFO: No changes found."
  exit 0
fi

if [ "$SHOW_DIFF" -eq 1 ]; then
  print_diff_debug "$bundle"
fi

system_tpl="$(read_file_trim "$SYSTEM_PATH_ABS" || true)"
user_tpl="$(read_file_trim "$USER_PATH_ABS" || true)"

if [ -z "$system_tpl" ]; then
  echo "ERROR: Cannot read system prompt: $SYSTEM_PATH_ABS"
  exit 1
fi
if [ -z "$user_tpl" ]; then
  echo "ERROR: Cannot read user prompt: $USER_PATH_ABS"
  exit 1
fi

# ✅ 자동 축소 재시도 루프 (맥 ctx 2048 같은 경우 대비)
attempt=1
cur_max="$MAX_CHARS"
raw=""
msg=""

while [ "$attempt" -le "$MAX_RETRIES" ]; do
  input="$(truncate "$bundle" "$cur_max")"
  user_prompt="$(apply_template_input "$user_tpl" "$input")"

  if raw="$(call_llm "$system_tpl" "$user_prompt")"; then
    msg="$(sanitize_commit_message "${raw:-}")"
    break
  fi

  # 실패 처리
  http="${LLM_ERR_HTTP:-}"
  body="${LLM_ERR_BODY:-}"

  # exceed ctx면 자동으로 더 자르고 재시도
  if [ "$http" = "400" ]; then
    parsed="$(parse_exceed_ctx "$body")"
    if [ -n "$parsed" ]; then
      n_prompt="$(printf '%s' "$parsed" | awk '{print $1}')"
      n_ctx="$(printf '%s' "$parsed" | awk '{print $2}')"

      if [ "${n_prompt:-0}" -gt 0 ] && [ "${n_ctx:-0}" -gt 0 ]; then
        # 축소 비율: n_ctx / n_prompt_tokens 에 안전계수 0.85
        # (char 기반이므로 대충 줄이되, 과감하게 줄여서 한번에 통과시키는 쪽)
        new_max="$(awk -v m="$cur_max" -v a="$n_prompt" -v c="$n_ctx" '
          BEGIN{
            r = (c / a) * 0.85;
            if (r > 0.95) r = 0.95;
            if (r < 0.20) r = 0.20;
            printf("%d", m * r);
          }')"

        if [ "$new_max" -lt 2000 ]; then
          new_max=2000
        fi

        echo "⚠️  LLM context exceeded (prompt=${n_prompt}, ctx=${n_ctx}). Retrying with smaller diff..."
        echo "   - attempt: ${attempt}/${MAX_RETRIES}"
        echo "   - max chars: ${cur_max} → ${new_max}"
        cur_max="$new_max"
        attempt=$((attempt + 1))
        continue
      fi
    fi
  fi

  # 그 외 에러는 그대로 출력하고 종료
  echo "ERROR: LLM request failed (HTTP ${http:-unknown})" >&2
  echo "----- LLM ERROR BODY -----" >&2
  printf '%s\n' "$body" >&2
  echo "--------------------------" >&2
  exit 1
done

if [ -z "${msg:-}" ]; then
  echo "ERROR: Empty response from LLM (or retries exhausted)."
  echo "TIP: increase ctx on the server OR reduce diff via LLM_DIFF_MAX_CHARS"
  exit 1
fi

if [ -n "$OUT_FILE" ]; then
  printf '%s\n' "$msg" > "$OUT_FILE"
fi

echo
echo "===== COMMIT MESSAGE ====="
echo
printf '%s\n' "$msg"
echo
echo "=========================="
echo