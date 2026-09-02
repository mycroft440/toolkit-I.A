#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"
load_env
cd "$ROOT_DIR"

require_docker_access() {
  if docker info >/dev/null 2>&1; then
    return 0
  fi
  if [[ "${EUID}" -ne 0 ]]; then
    exec sudo -E bash "$0" "$@"
  fi
  die "Docker daemon não está acessível."
}

validate_deployment_config() {
  "$ROOT_DIR/scripts/preflight.sh"
  docker compose --env-file .env config >/dev/null
}

validate_runtime_image() {
  docker run --rm --gpus all \
    --entrypoint python3 \
    "${VLLM_IMAGE:-vllm/vllm-openai:glm53-flash}" \
    -c "import sys, torch, vllm; from importlib.metadata import version; from packaging.version import Version; n=torch.cuda.device_count(); fi=version('flashinfer-python'); print(f'vLLM {vllm.__version__}; FlashInfer {fi}; CUDA OK: {n} GPU(s); {torch.cuda.get_device_name(0) if n else \"none\"}'); sys.exit(0 if n >= ${TENSOR_PARALLEL_SIZE:-8} and Version(fi) >= Version('0.6.17') else 1)"
}

wait_for_api() {
  local timeout_sec="${1:-${VLLM_ENGINE_READY_TIMEOUT_S:-3600}}"
  local deadline=$((SECONDS + timeout_sec))
  while (( SECONDS < deadline )); do
    if "$ROOT_DIR/healthcheck.sh" >/dev/null 2>&1; then
      return 0
    fi
    sleep 10
  done
  return 1
}

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
  docker info --format 'DockerRootDir={{.DockerRootDir}}' 2>/dev/null || true

  printf '\n%s\n' "=== Imagem vLLM ==="
  docker image inspect "${VLLM_IMAGE:-vllm/vllm-openai:glm53-flash}" \
    --format '{{range .RepoDigests}}{{println .}}{{end}}' 2>/dev/null || true

  printf '\n%s\n' "=== Modelo configurado ==="
  printf 'MODEL_ID=%s\nMODEL_REVISION=%s\n' "${MODEL_ID:-zai-org/GLM-5.3-Flash}" "${MODEL_REVISION:-main}"

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
  gpu_names="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | sort -u | paste -sd ',' - | sed 's/,/, /g' || true)"
  host_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' || true)"
  if [[ -z "$host_ip" ]]; then
    host_ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi

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
Revisão modelo:     ${MODEL_REVISION:-main}
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
./manage.sh test         Smoke test: API + chat + tool calling
./manage.sh diagnose     Diagnóstico técnico
./manage.sh restart      Reaplicar .env sem puxar imagens novas
./manage.sh update       Atualizar vLLM com validação e rollback
./manage.sh key          Mostrar somente a API key
============================================================
INFO

  if [[ "${BIND_ADDRESS:-127.0.0.1}" == "127.0.0.1" ]]; then
    warn "A API está acessível somente na própria VPS. Para agentes remotos, configure rede privada/VPN/NSG/TLS conforme SECURITY.md."
  fi
}

rollback_vllm_image() {
  local old_vllm_id="$1"
  [[ -n "$old_vllm_id" ]] || return 1
  docker tag "$old_vllm_id" "${VLLM_IMAGE:-vllm/vllm-openai:glm53-flash}" || return 1
  docker compose --env-file .env up -d --force-recreate --pull never || return 1
  return 0
}

safe_update() {
  local image="${VLLM_IMAGE:-vllm/vllm-openai:glm53-flash}"
  local old_vllm_id="" new_vllm_id="" timeout_sec

  [[ "$image" != *@sha256:* ]] || die "VLLM_IMAGE está fixada por digest. Para atualizar, escolha explicitamente um novo digest/tag no .env e rode ./manage.sh apply."

  log "Validando configuração, GPUs e espaço em disco antes do download..."
  validate_deployment_config
  old_vllm_id="$(docker image inspect "$image" --format '{{.Id}}' 2>/dev/null || true)"

  log "Baixando somente a imagem vLLM atualizada..."
  docker compose --env-file .env pull vllm
  new_vllm_id="$(docker image inspect "$image" --format '{{.Id}}' 2>/dev/null || true)"
  [[ -n "$new_vllm_id" ]] || die "A imagem vLLM não ficou disponível após o pull."

  log "Validando CUDA/vLLM/FlashInfer da imagem baixada antes de trocar o servidor..."
  if ! validate_runtime_image; then
    if [[ -n "$old_vllm_id" && "$old_vllm_id" != "$new_vllm_id" ]]; then
      docker tag "$old_vllm_id" "$image" || true
    fi
    die "A imagem nova falhou na validação. O servidor em execução não foi recriado."
  fi

  if [[ -n "$old_vllm_id" && "$old_vllm_id" == "$new_vllm_id" ]]; then
    log "A imagem vLLM já está na versão mais recente desse tag; nenhuma recriação foi necessária."
    return 0
  fi

  docker compose --env-file .env up -d --force-recreate --pull never
  timeout_sec="${VLLM_ENGINE_READY_TIMEOUT_S:-3600}"
  log "Aguardando a versão atualizada ficar saudável..."
  if wait_for_api "$timeout_sec"; then
    log "API carregou. Executando smoke test completo, incluindo tool calling..."
    if "$ROOT_DIR/test-api.sh"; then
      log "Atualização concluída e validada."
      return 0
    fi
  fi

  if [[ -n "$old_vllm_id" && "$old_vllm_id" != "$new_vllm_id" ]]; then
    warn "A atualização falhou no health/smoke test; restaurando a imagem vLLM anterior."
    if rollback_vllm_image "$old_vllm_id"; then
      wait_for_api "$timeout_sec" || warn "A imagem anterior foi restaurada, mas a API ainda não ficou saudável; verifique os logs."
    else
      warn "Não foi possível concluir o rollback automaticamente."
    fi
  fi
  die "Atualização rejeitada. Execute ./manage.sh logs e ./manage.sh diagnose para detalhes."
}

case "${1:-status}" in
  start)
    require_docker_access "$@"
    validate_deployment_config
    docker compose --env-file .env up -d --pull never
    ;;
  stop)
    require_docker_access "$@"
    docker compose --env-file .env stop
    ;;
  restart|apply)
    require_docker_access "$@"
    validate_deployment_config
    docker compose --env-file .env up -d --force-recreate --pull never
    ;;
  status)
    require_docker_access "$@"
    docker compose --env-file .env ps
    nvidia-smi --query-gpu=index,name,memory.total,memory.used,utilization.gpu --format=csv
    ;;
  logs)
    require_docker_access "$@"
    docker compose --env-file .env logs -f --tail=200 vllm gateway
    ;;
  pull|update)
    require_docker_access "$@"
    safe_update
    ;;
  wait)
    timeout_sec="${VLLM_ENGINE_READY_TIMEOUT_S:-3600}"
    log "Aguardando a API ficar pronta (limite configurado: ${timeout_sec}s)..."
    if wait_for_api "$timeout_sec"; then
      "$ROOT_DIR/healthcheck.sh"
      exit 0
    fi
    die "A API não ficou pronta dentro do limite. Execute ./manage.sh logs para diagnosticar."
    ;;
  test)
    "$ROOT_DIR/test-api.sh"
    ;;
  diagnose)
    require_docker_access "$@"
    diagnose
    ;;
  info)
    show_info
    ;;
  key)
    printf '%s\n' "${API_KEY}"
    ;;
  *)
    cat <<USAGE
Uso: ./manage.sh {start|stop|restart|apply|status|logs|pull|update|wait|test|diagnose|info|key}
USAGE
    exit 2
    ;;
esac
