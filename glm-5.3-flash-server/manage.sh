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

show_info() {
  local origin status gpu_count gpu_names host_ip remote_url
  origin="$(api_origin)"
  status="OFFLINE"
  if curl -fsS --max-time 4 -H "Authorization: Bearer ${API_KEY}" "${origin}/v1/models" >/dev/null 2>&1; then
    status="ONLINE"
  fi

  gpu_count="$(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | wc -l | tr -d ' ' || true)"
  gpu_names="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | sort -u | paste -sd ', ' - || true)"
  host_ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"

  case "${BIND_ADDRESS:-127.0.0.1}" in
    127.0.0.1|localhost) remote_url="DESATIVADO (API somente local)" ;;
    0.0.0.0)
      if [[ -n "$host_ip" ]]; then remote_url="http://${host_ip}:${API_PORT:-8000}/v1"; else remote_url="http://IP_DA_VM:${API_PORT:-8000}/v1"; fi
      ;;
    *) remote_url="http://${BIND_ADDRESS}:${API_PORT:-8000}/v1" ;;
  esac

  cat <<INFO
============================================================
 GLM-5.3-FLASH — INFORMAÇÕES DA API
============================================================
Status:             ${status}
Modelo:             ${SERVED_MODEL_NAME:-glm-5.3-flash}
Checkpoint:         ${MODEL_ID:-zai-org/GLM-5.3-Flash}
Base URL local:     ${origin}/v1
Acesso remoto:      ${remote_url}
Bind:               ${BIND_ADDRESS:-127.0.0.1}
Porta:              ${API_PORT:-8000}
API key:            ${API_KEY}
Contexto máximo:    ${MAX_MODEL_LEN:-262144} tokens
Tensor Parallel:    ${TENSOR_PARALLEL_SIZE:-8}
Imagem vLLM:        ${VLLM_IMAGE:-vllm/vllm-openai:glm53-flash}
GPUs detectadas:    ${gpu_count:-0}
Modelo(s) de GPU:   ${gpu_names:-indisponível}
Cache HuggingFace:  ${HF_CACHE_DIR:-/var/lib/glm53/huggingface}
Cache vLLM:         ${VLLM_CACHE_DIR:-/var/lib/glm53/vllm-cache}
Mídia remota:       ${ALLOWED_MEDIA_DOMAIN:-bloqueada}

PARA USAR A API
---------------
Base URL: ${origin}/v1
Model:    ${SERVED_MODEL_NAME:-glm-5.3-flash}
Header:   Authorization: Bearer <API_KEY_ACIMA>

Teste:
  export GLM_BASE_URL='${origin}/v1'
  export GLM_API_KEY='<API_KEY_ACIMA>'
  curl "$GLM_BASE_URL/models" -H "Authorization: Bearer $GLM_API_KEY"

COMANDOS
--------
glm-info                 Mostrar este painel de qualquer pasta
./info                   Mostrar este painel dentro do projeto
./manage.sh status       Status dos containers e GPUs
./manage.sh logs         Logs do servidor
./manage.sh wait         Aguardar a API ficar pronta
./manage.sh test         Smoke test completo
./manage.sh diagnose     Diagnóstico técnico
./manage.sh restart      Reaplicar .env e recriar containers
./manage.sh update       Atualizar imagens
./manage.sh key          Mostrar somente a API key
============================================================
INFO

  if [[ "${BIND_ADDRESS:-127.0.0.1}" == "127.0.0.1" ]]; then
    warn "A API está acessível somente na própria VPS. Para agentes remotos, configure rede privada/VPN/NSG/TLS conforme SECURITY.md."
  fi
}

case "${1:-status}" in
  start) docker compose --env-file .env up -d ;;
  stop) docker compose --env-file .env stop ;;
  restart|apply)
    docker compose --env-file .env up -d --force-recreate
    ;;
  status)
    docker compose --env-file .env ps
    nvidia-smi --query-gpu=index,name,memory.total,memory.used,utilization.gpu --format=csv
    ;;
  logs) docker compose --env-file .env logs -f --tail=200 vllm gateway ;;
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
  test) "$ROOT_DIR/test-api.sh" ;;
  diagnose) diagnose ;;
  info) show_info ;;
  key) printf '%s\n' "${API_KEY}" ;;
  *)
    cat <<USAGE
Uso: ./manage.sh {start|stop|restart|apply|status|logs|pull|update|wait|test|diagnose|info|key}
USAGE
    exit 2
    ;;
esac
