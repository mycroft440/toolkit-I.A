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

case "${1:-status}" in
  start)
    docker compose --env-file .env up -d
    ;;
  stop)
    docker compose --env-file .env stop
    ;;
  restart)
    docker compose --env-file .env restart
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
    docker compose --env-file .env up -d
    ;;
  wait)
    timeout_sec="${VLLM_ENGINE_READY_TIMEOUT_S:-3600}"
    deadline=$((SECONDS + timeout_sec))
    log "Aguardando a API ficar pronta (limite configurado: ${timeout_sec}s)..."
    while (( SECONDS < deadline )); do
      if "$ROOT_DIR/healthcheck.sh" >/dev/null 2>&1; then
        "$ROOT_DIR/healthcheck.sh"
        exit 0
      fi
      sleep 10
    done
    die "A API não ficou pronta dentro do limite. Execute ./manage.sh logs para diagnosticar."
    ;;
  test)
    "$ROOT_DIR/test-api.sh"
    ;;
  key)
    printf '%s\n' "${API_KEY}"
    ;;
  *)
    cat <<USAGE
Uso: ./manage.sh {start|stop|restart|status|logs|pull|update|wait|test|key}
USAGE
    exit 2
    ;;
esac
