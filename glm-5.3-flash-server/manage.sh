#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"
load_env
if ! docker info >/dev/null 2>&1 && [[ "${EUID}" -ne 0 ]]; then
  exec sudo -E bash "$0" "$@"
fi
cd "$ROOT_DIR"

diagnose() {
  printf '%s\n' "=== Sistema ==="
  if [[ -r /etc/os-release ]]; then
    grep -E '^(PRETTY_NAME|VERSION_ID)=' /etc/os-release || true
  fi
  uname -srmo || true

  printf '\n%s\n' "=== NVIDIA ==="
  nvidia-smi --query-gpu=index,name,driver_version,memory.total,memory.used,utilization.gpu --format=csv || true

  printf '\n%s\n' "=== Docker ==="
  docker --version || true
  docker compose version || true

  printf '\n%s\n' "=== Imagem vLLM ==="
  docker image inspect "${VLLM_IMAGE:-vllm/vllm-openai:glm53-flash}" \
    --format '{{range .RepoDigests}}{{println .}}{{end}}' 2>/dev/null || true

  printf '\n%s\n' "=== Containers ==="
  docker compose --env-file .env ps || true

  if docker compose --env-file .env ps --services --status running | grep -qx vllm; then
    printf '\n%s\n' "=== Runtime ==="
    docker exec glm53-flash-vllm python3 -c \
      "import vllm; from importlib.metadata import version; print('vLLM', vllm.__version__); print('FlashInfer', version('flashinfer-python'))" \
      2>/dev/null || true
  fi
}

case "${1:-status}" in
  start)
    docker compose --env-file .env up -d
    ;;
  stop)
    docker compose --env-file .env stop
    ;;
  restart|apply)
    # "docker compose restart" não reaplica .env/ports/command.
    docker compose --env-file .env up -d --force-recreate
    ;;
  status)
    docker compose --env-file .env ps
    nvidia-smi --query-gpu=index,name,memory.total,memory.used,utilization.gpu --format=csv
    ;;
  logs)
    docker compose --env-file .env logs -f --tail=200 vllm gateway
    ;;
  pull|update)
    docker compose --env-file .env pull
    docker compose --env-file .env up -d --force-recreate
    ;;
  wait)
    timeout_sec="${VLLM_ENGINE_READY_TIMEOUT_S:-3600}"
    deadline=$((SECONDS + timeout_sec))
    log "Aguardando a API ficar pronta (limite configurado: ${timeout_sec}s)..."
    while (( SECONDS < deadline )); do
      if output="$("$ROOT_DIR/healthcheck.sh" 2>&1)"; then
        printf '%s\n' "$output"
        exit 0
      fi
      sleep 10
    done
    die "A API não ficou pronta dentro do limite. Execute ./manage.sh logs para diagnosticar."
    ;;
  test)
    "$ROOT_DIR/test-api.sh"
    ;;
  diagnose)
    diagnose
    ;;
  key)
    printf '%s\n' "${API_KEY}"
    ;;
  *)
    cat <<USAGE
Uso: ./manage.sh {start|stop|restart|apply|status|logs|pull|update|wait|test|diagnose|key}
USAGE
    exit 2
    ;;
esac
