#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LLM_DIR="$SCRIPT_DIR"

ENV_FILE="$LLM_DIR/.env"
COMPOSE_FILE="$LLM_DIR/compose.yml"
MODELS_DIR="$LLM_DIR/models"

# mac native state
PID_FILE="$LLM_DIR/.llama-server.pid"
LOG_FILE="$LLM_DIR/.llama-server.log"

cd "$LLM_DIR"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "❌ ERROR: $1 not found."
    exit 1
  fi
}

trim_cr() {
  printf '%s' "$1" | sed -e 's/\r$//'
}

# strip surrounding quotes (", ') + trailing CR
strip_quotes() {
  local s="${1:-}"
  s="$(trim_cr "$s")"
  # trim leading/trailing spaces (portable)
  s="$(printf '%s' "$s" | sed -e 's/^[[:space:]]\+//' -e 's/[[:space:]]\+$//')"
  if [ "${#s}" -ge 2 ]; then
    if [ "${s:0:1}" = '"' ] && [ "${s: -1}" = '"' ]; then
      s="${s:1:${#s}-2}"
    elif [ "${s:0:1}" = "'" ] && [ "${s: -1}" = "'" ]; then
      s="${s:1:${#s}-2}"
    fi
  fi
  printf '%s' "$s"
}

env_get() {
  local key="$1"
  local file="$2"
  [ -f "$file" ] || return 0

  awk -v k="$key" '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    {
      line=$0
      sub(/\r$/, "", line)
      if (index(line, k "=") == 1) {
        sub(("^" k "="), "", line)
        print line
        exit
      }
    }
  ' "$file"
}

getv() {
  local key="$1"
  local def="${2:-}"
  local val="${!key:-}"

  if [ -n "${val:-}" ]; then
    strip_quotes "$val"
    return
  fi

  val="$(env_get "$key" "$ENV_FILE" || true)"
  val="$(strip_quotes "${val:-}")"

  if [ -n "${val:-}" ]; then
    printf '%s' "$val"
  else
    printf '%s' "$def"
  fi
}

is_macos() {
  [ "$(uname -s)" = "Darwin" ]
}

# ------------------------------------------------------------
# Port helpers (mac native / general)
# ------------------------------------------------------------
port_in_use() {
  local port="$1"
  command -v lsof >/dev/null 2>&1 || return 1
  lsof -tiTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
}

print_port_pids() {
  local port="$1"
  command -v lsof >/dev/null 2>&1 || return 0
  lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true
}

# IMPORTANT:
# - macOS에서만 "내가 띄운 llama-server"는 PID_FILE로 관리하고,
# - 혹시 PID_FILE이 꼬였거나 다른 프로세스가 포트를 점유하면, 기본은 에러로 막는다.
# - 다만, LLM_FORCE_KILL_PORT=1 이면 해당 포트 리스너를 강제 종료(주의!)
kill_port_listeners_if_allowed() {
  local port pids
  port="$1"

  if [ "$(getv LLM_FORCE_KILL_PORT 0)" != "1" ]; then
    return 0
  fi

  pids="$(print_port_pids "$port")"
  [ -n "${pids:-}" ] || return 0

  echo "⚠️  LLM_FORCE_KILL_PORT=1 enabled. Killing listeners on port $port:"
  echo "$pids" | sed 's/^/ - /'

  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    kill "$pid" >/dev/null 2>&1 || true
  done <<< "$pids"

  sleep 1

  pids="$(print_port_pids "$port")"
  if [ -n "${pids:-}" ]; then
    echo "⚠️  Still listening. Force killing:"
    echo "$pids" | sed 's/^/ - /'
    while IFS= read -r pid; do
      [ -n "$pid" ] || continue
      kill -9 "$pid" >/dev/null 2>&1 || true
    done <<< "$pids"
  fi
}

# ------------------------------------------------------------
# Model download (shared)
# ------------------------------------------------------------
download_model_if_missing() {
  local model_file model_url models_dir model_path
  models_dir="$MODELS_DIR"
  model_file="$(getv MODEL_FILE "qwen2.5-7b-instruct-q4_k_m.gguf")"
  model_url="$(getv MODEL_URL "")"

  mkdir -p "$models_dir"
  model_path="$models_dir/$model_file"

  if [ -f "$model_path" ]; then
    return 0
  fi

  if [ -z "${model_url:-}" ]; then
    echo "❌ ERROR: Model file not found and MODEL_URL is empty."
    echo "       Expected: $model_path"
    exit 1
  fi

  echo "⬇️  Downloading model"
  echo "   → $model_path"
  echo "   🌐 $model_url"

  curl -L -C - --fail --retry 3 --retry-delay 2 \
    -o "$model_path" \
    "$model_url"

  echo "✅ Model download complete"
}

# ------------------------------------------------------------
# Health wait (shared) - hits /health
# ------------------------------------------------------------
wait_health() {
  local port timeout start_ts last_out out elapsed
  port="$(getv LLM_PORT 18080)"
  timeout="$(getv LLM_HEALTH_TIMEOUT_SEC 180)"

  echo
  echo "🌐 LLM endpoint: http://localhost:${port}"
  echo "⏳ Waiting for health check (timeout: ${timeout}s)"

  start_ts="$(date +%s)"
  last_out=""

  while true; do
    out="$(curl -sS --max-time 2 "http://localhost:${port}/health" || true)"
    last_out="$out"

    if [ -n "$out" ] && ! echo "$out" | grep -q "Loading model"; then
      echo "✅ LLM is ready"
      break
    fi

    elapsed="$(( $(date +%s) - start_ts ))"
    if [ "$elapsed" -ge "$timeout" ]; then
      echo "⛔ ERROR: LLM did not become ready within timeout"
      echo "Last response:"
      echo "$last_out"
      echo
      echo "🔍 Tips:"
      echo " - macOS native logs: $LOG_FILE"
      echo " - docker logs: ./llm.sh logs -f"
      exit 1
    fi

    echo "… loading (${elapsed}s / ${timeout}s)"
    sleep 2
  done
}

# ------------------------------------------------------------
# macOS native (llama.cpp + Metal)
# ------------------------------------------------------------
ensure_llama_cpp() {
  if command -v llama-server >/dev/null 2>&1; then
    return 0
  fi

  echo "⚠️ llama-server not found."

  if ! command -v brew >/dev/null 2>&1; then
    echo "❌ Homebrew not found."
    echo
    echo "👉 Install Homebrew first:"
    echo "   https://brew.sh"
    echo
    echo "Then run:"
    echo "   brew install llama.cpp"
    exit 1
  fi

  # ✅ mac only: auto-install allowed by env flag
  if [ "$(getv LLM_BREW_AUTO_INSTALL 0)" = "1" ]; then
    echo "🍺 Installing llama.cpp via Homebrew (LLM_BREW_AUTO_INSTALL=1)..."
    if ! brew install llama.cpp; then
      echo "❌ Failed to install llama.cpp"
      echo "Try manually: brew install llama.cpp"
      exit 1
    fi
  else
    echo "👉 Install it:"
    echo "   brew install llama.cpp"
    echo
    echo "Or enable auto-install in llm/.env:"
    echo "   LLM_BREW_AUTO_INSTALL=1"
    exit 1
  fi

  if ! command -v llama-server >/dev/null 2>&1; then
    echo "❌ llama-server still not found after install"
    exit 1
  fi

  echo "✅ llama.cpp installed"
}

mac_native_is_running() {
  if [ -f "$PID_FILE" ]; then
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [ -n "${pid:-}" ] && kill -0 "$pid" >/dev/null 2>&1; then
      return 0
    fi
  fi
  return 1
}

mac_native_up() {
  ensure_llama_cpp
  download_model_if_missing

  local port model_file model_path ctx threads batch ngl parallel
  port="$(getv LLM_PORT 18080)"
  model_file="$(getv MODEL_FILE "qwen2.5-7b-instruct-q4_k_m.gguf")"
  model_path="$MODELS_DIR/$model_file"

  # ✅ defaults tuned for mac (safe-ish)
  # - ctx는 env에서 올리고(예: 8192) 성능/메모리 보며 조절
  ctx="$(getv LLM_CTX 8192)"
  threads="$(getv LLM_THREADS 8)"
  batch="$(getv LLM_BATCH 256)"
  parallel="$(getv LLM_PARALLEL 1)"
  # Metal offload
  ngl="$(getv LLM_METAL_NGL 999)"

  if mac_native_is_running; then
    echo "🔁 LLM already running (mac native)."
    echo "   pid: $(cat "$PID_FILE")"
    echo "   logs: $LOG_FILE"
    wait_health
    echo "🎉 Done."
    return 0
  fi

  # If port is in use, handle only if:
  # - pidfile exists but stale => remove & proceed if port not used after that
  # - or LLM_FORCE_KILL_PORT=1 => kill listeners
  if port_in_use "$port"; then
    # try: if pidfile exists but not running, clean it
    if [ -f "$PID_FILE" ] && ! mac_native_is_running; then
      rm -f "$PID_FILE" >/dev/null 2>&1 || true
    fi

    if port_in_use "$port"; then
      # allow aggressive kill if requested
      kill_port_listeners_if_allowed "$port"

      if port_in_use "$port"; then
        echo "⚠️ Port $port already in use. PIDs:"
        print_port_pids "$port" | sed 's/^/ - /'
        echo "   Stop them manually or change LLM_PORT."
        echo "   (If you really want, set LLM_FORCE_KILL_PORT=1 in llm/.env)"
        exit 1
      fi
    fi
  fi

  echo "🚀 Starting LLM (mac native / llama.cpp + Metal)"
  echo " - model    : $model_path"
  echo " - port     : $port"
  echo " - ctx      : $ctx"
  echo " - thr      : $threads"
  echo " - batch    : $batch"
  echo " - parallel : $parallel"
  echo " - metal ngl: $ngl"
  echo " - log      : $LOG_FILE"

  : > "$LOG_FILE"

  # NOTE:
  # llama-server supports:
  # -c (ctx), -t (threads), -b (batch), --host/--port, -ngl (gpu layers), --parallel
  nohup llama-server \
    -m "$model_path" \
    -c "$ctx" \
    -t "$threads" \
    -b "$batch" \
    --parallel "$parallel" \
    --host 0.0.0.0 \
    --port "$port" \
    -ngl "$ngl" \
    >"$LOG_FILE" 2>&1 &

  echo $! > "$PID_FILE"

  wait_health
  echo "🎉 Done."
}

mac_native_down() {
  local port pid
  port="$(getv LLM_PORT 18080)"

  if mac_native_is_running; then
    pid="$(cat "$PID_FILE")"
    echo "🧹 Stopping LLM (mac native) pid=$pid"
    kill "$pid" >/dev/null 2>&1 || true

    # wait a bit then force
    for _ in 1 2 3 4 5; do
      if kill -0 "$pid" >/dev/null 2>&1; then
        sleep 1
      else
        break
      fi
    done
    if kill -0 "$pid" >/dev/null 2>&1; then
      echo "⚠️  Force kill pid=$pid"
      kill -9 "$pid" >/dev/null 2>&1 || true
    fi

    rm -f "$PID_FILE"
  else
    rm -f "$PID_FILE" >/dev/null 2>&1 || true
  fi

  # ✅ if something still holds the port, offer best-effort kill only when allowed
  if port_in_use "$port"; then
    if [ "$(getv LLM_FORCE_KILL_PORT 0)" = "1" ]; then
      kill_port_listeners_if_allowed "$port"
    fi
  fi

  if port_in_use "$port"; then
    echo "⚠️  Port $port is still in use."
    echo "PIDs:"
    print_port_pids "$port" | sed 's/^/ - /'
    echo "✅ LLM down (mac native) but port is occupied by another process."
  else
    echo "✅ LLM down (mac native)"
  fi
}

mac_native_status() {
  local port
  port="$(getv LLM_PORT 18080)"

  if mac_native_is_running; then
    echo "✅ mac native running"
    echo " - pid : $(cat "$PID_FILE")"
    echo " - log : $LOG_FILE"
    echo " - url : http://localhost:${port}"
    return 0
  fi

  echo "⛔ mac native not running"
  if port_in_use "$port"; then
    echo "⚠️ but port $port is in use by:"
    print_port_pids "$port" | sed 's/^/ - /'
  fi
}

mac_native_logs() {
  local follow="${1:-}"
  if [ ! -f "$LOG_FILE" ]; then
    echo "No log file: $LOG_FILE"
    exit 0
  fi
  if [ "$follow" = "-f" ]; then
    tail -n 200 -f "$LOG_FILE"
  else
    tail -n 200 "$LOG_FILE"
  fi
}

# ------------------------------------------------------------
# Docker path (linux/windows)
# ------------------------------------------------------------
docker_running() {
  docker info >/dev/null 2>&1
}

compose() {
  local project
  project="$(getv LLM_PROJECT llm)"

  docker compose \
    -p "$project" \
    --project-directory "$LLM_DIR" \
    --env-file "$ENV_FILE" \
    -f "$COMPOSE_FILE" \
    --ansi never \
    "$@"
}

detect_profile() {
  local p
  p="$(getv LLM_PROFILE cpu)"
  case "$p" in
    cpu|gpu) echo "$p" ;;
    auto)
      if command -v nvidia-smi >/dev/null 2>&1; then
        if docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi >/dev/null 2>&1; then
          echo "gpu"
          return
        fi
      fi
      echo "cpu"
      ;;
    *)
      echo "cpu"
      ;;
  esac
}

list_llm_containers() {
  docker ps --format '{{.Names}}' | grep -E '^(llm-cpu|llm-gpu)$' || true
}

force_kill_llm_containers_if_any() {
  local still
  still="$(list_llm_containers)"
  if [ -n "$still" ]; then
    echo "⚠️  Containers still running after compose down. Forcing stop/rm:"
    echo "$still" | sed 's/^/ - /'
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      docker rm -f "$name" >/dev/null 2>&1 || true
    done <<< "$still"
    echo "🧹 LLM down (forced)"
  else
    echo "✅ LLM down"
  fi
}

docker_up() {
  download_model_if_missing
  local profile
  profile="$(detect_profile)"

  # 전환 시 찌꺼기 방지
  compose down --remove-orphans || true
  force_kill_llm_containers_if_any >/dev/null 2>&1 || true

  echo "🚀 Starting LLM (docker profile: $profile)"
  compose --profile "$profile" up -d
  compose ps
  wait_health
  echo "🎉 Done."
}

docker_down() {
  local remove_orphans=0
  for arg in "$@"; do
    case "$arg" in
      --clean|--remove-orphans) remove_orphans=1 ;;
    esac
  done

  if [ "$remove_orphans" -eq 1 ]; then
    compose down --remove-orphans || true
  else
    compose down || true
  fi

  force_kill_llm_containers_if_any
}

usage() {
  cat <<'EOF'
Usage: ./llm.sh <command> [options]

Commands:
  up                 Start LLM server
  down [--clean]     Stop LLM server
  restart            Restart LLM server
  status             Show status
  logs [-f]          Show logs

Mode:
  - macOS: native llama.cpp (llama-server) + Metal (default)
  - other OS: docker compose (cpu/gpu/auto via LLM_PROFILE)

Env (read from llm/.env, or process env):
  Common:
    LLM_PORT=18080
    MODEL_FILE=...           (quotes allowed)
    MODEL_URL=...            (quotes allowed)
    LLM_HEALTH_TIMEOUT_SEC=180

  Docker-only:
    LLM_PROJECT=llm
    LLM_PROFILE=cpu|gpu|auto

  macOS native-only (optional tuning):
    LLM_CTX=8192
    LLM_THREADS=8
    LLM_BATCH=256
    LLM_PARALLEL=1
    LLM_METAL_NGL=999        (Metal offload layers; set 0 for CPU-only)

  macOS convenience (optional):
    LLM_BREW_AUTO_INSTALL=1  (auto brew install llama.cpp)
    LLM_FORCE_KILL_PORT=1    (DANGEROUS: kill anything listening on LLM_PORT)
EOF
}

CMD="${1:-help}"
shift || true

case "$CMD" in
  up)
    need_cmd curl

    if [ ! -f "$ENV_FILE" ]; then
      echo "❌ ERROR: env file not found: $ENV_FILE"
      echo "   Create llm/.env (or copy from llm/.env.example if you have one)."
      exit 1
    fi

    if is_macos; then
      mac_native_up
    else
      need_cmd docker
      if ! docker_running; then
        echo "⛔ ERROR: Docker is not running."
        exit 1
      fi
      if [ ! -f "$COMPOSE_FILE" ]; then
        echo "❌ ERROR: compose file not found: $COMPOSE_FILE"
        exit 1
      fi
      docker_up
    fi
    ;;

  down)
    if is_macos; then
      mac_native_down
    else
      need_cmd docker
      if ! docker_running; then
        echo "⛔ ERROR: Docker is not running."
        exit 1
      fi
      if [ ! -f "$ENV_FILE" ]; then
        echo "❌ ERROR: env file not found: $ENV_FILE"
        exit 1
      fi
      if [ ! -f "$COMPOSE_FILE" ]; then
        echo "❌ ERROR: compose file not found: $COMPOSE_FILE"
        exit 1
      fi
      docker_down "$@"
    fi
    ;;

  restart)
    "$0" down --remove-orphans || true
    "$0" up
    ;;

  status)
    if is_macos; then
      mac_native_status
    else
      need_cmd docker
      if ! docker_running; then
        echo "⛔ ERROR: Docker is not running."
        exit 1
      fi
      if [ ! -f "$ENV_FILE" ]; then
        echo "❌ ERROR: env file not found: $ENV_FILE"
        exit 1
      fi
      if [ ! -f "$COMPOSE_FILE" ]; then
        echo "❌ ERROR: compose file not found: $COMPOSE_FILE"
        exit 1
      fi
      compose ps
    fi
    ;;

  logs)
    if is_macos; then
      mac_native_logs "${1:-}"
    else
      need_cmd docker
      if ! docker_running; then
        echo "⛔ ERROR: Docker is not running."
        exit 1
      fi
      if [ ! -f "$ENV_FILE" ]; then
        echo "❌ ERROR: env file not found: $ENV_FILE"
        exit 1
      fi
      if [ ! -f "$COMPOSE_FILE" ]; then
        echo "❌ ERROR: compose file not found: $COMPOSE_FILE"
        exit 1
      fi
      compose logs "$@"
    fi
    ;;

  help|-h|--help|"")
    usage
    ;;

  *)
    echo "❌ Unknown command: $CMD"
    usage
    exit 1
    ;;
esac