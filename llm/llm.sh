#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LLM_DIR="$SCRIPT_DIR"
TOOLS_ROOT="$(cd -- "$LLM_DIR/.." && pwd)"

ENV_FILE="$LLM_DIR/.env"
COMPOSE_FILE="$LLM_DIR/compose.yml"
MODELS_DIR="$LLM_DIR/models"

cd "$LLM_DIR"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "❌ ERROR: $1 not found."
    exit 1
  fi
}

docker_running() {
  docker info >/dev/null 2>&1
}

trim_cr() {
  printf '%s' "$1" | sed -e 's/\r$//'
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
    echo "$val"
    return
  fi

  val="$(env_get "$key" "$ENV_FILE" || true)"
  val="$(trim_cr "${val:-}")"

  if [ -n "${val:-}" ]; then
    echo "$val"
  else
    echo "$def"
  fi
}

compose() {
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
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
      echo "🔍 Check logs:"
      echo "   ./llm.sh logs -f"
      exit 1
    fi

    echo "… loading (${elapsed}s / ${timeout}s)"
    sleep 2
  done
}

usage() {
  cat <<'EOF'
Usage: ./llm.sh <command> [options]

Commands:
  up                 Start LLM server (cpu/gpu/auto via LLM_PROFILE)
  down [--clean]     Stop LLM server (optionally remove orphans)
  restart            Restart LLM server
  status             Show compose ps
  logs [-f]          Show logs

Env (read from llm/.env, or process env):
  LLM_PROFILE=cpu|gpu|auto
  LLM_PORT=18080
  MODEL_FILE=...
  MODEL_URL=...
  LLM_HEALTH_TIMEOUT_SEC=180
EOF
}

need_cmd docker
need_cmd curl

if ! docker_running; then
  echo "⛔ ERROR: Docker is not running. Start Docker Desktop first."
  exit 1
fi

if [ ! -f "$COMPOSE_FILE" ]; then
  echo "❌ ERROR: compose file not found: $COMPOSE_FILE"
  exit 1
fi

if [ ! -f "$ENV_FILE" ]; then
  echo "❌ ERROR: env file not found: $ENV_FILE"
  echo "   Create llm/.env (or copy from llm/.env.example if you have one)."
  exit 1
fi

CMD="${1:-help}"
shift || true

case "$CMD" in
  up)
    download_model_if_missing
    profile="$(detect_profile)"

    compose down --remove-orphans >/dev/null 2>&1 || true

    echo "🚀 Starting LLM (profile: $profile)"
    compose --profile "$profile" up -d
    compose ps
    wait_health
    echo "🎉 Done."
    ;;

  down)
    remove_orphans=0
    for arg in "$@"; do
      case "$arg" in
        --clean|--remove-orphans) remove_orphans=1 ;;
      esac
    done

    if [ "$remove_orphans" -eq 1 ]; then
      compose down --remove-orphans
      echo "🧹 LLM down (orphans removed)"
    else
      compose down
      echo "✅ LLM down"
    fi
    ;;

  restart)
    "$0" down --remove-orphans
    "$0" up
    ;;

  status)
    compose ps
    ;;

  logs)
    compose logs "$@"
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
