#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"

if [[ -f "$ROOT_DIR/.env" ]]; then
  load_env
fi

TP_SIZE="${TENSOR_PARALLEL_SIZE:-8}"
EXPECTED_GPUS="${EXPECTED_GPUS:-$TP_SIZE}"
MIN_GPU_MEMORY_MIB="${MIN_GPU_MEMORY_MIB:-130000}"
MIN_HF_FREE_GIB="${MIN_FREE_DISK_GIB:-420}"
MIN_DOCKER_FREE_GIB="${MIN_DOCKER_FREE_DISK_GIB:-80}"
MIN_VLLM_CACHE_FREE_GIB="${MIN_VLLM_CACHE_FREE_DISK_GIB:-20}"
HF_CACHE_PATH="${HF_CACHE_DIR:-/var/lib/glm53/huggingface}"
VLLM_CACHE_PATH="${VLLM_CACHE_DIR:-/var/lib/glm53/vllm-cache}"
MAX_LEN="${MAX_MODEL_LEN:-262144}"
API_LISTEN_PORT="${API_PORT:-8000}"
READY_TIMEOUT="${VLLM_ENGINE_READY_TIMEOUT_S:-3600}"

# MAX_LEN e READY_TIMEOUT são lidos indiretamente por nome no loop abaixo.
# shellcheck disable=SC2034
: "$MAX_LEN" "$READY_TIMEOUT"
for value_name in TP_SIZE EXPECTED_GPUS MIN_GPU_MEMORY_MIB MIN_HF_FREE_GIB MIN_DOCKER_FREE_GIB MIN_VLLM_CACHE_FREE_GIB MAX_LEN API_LISTEN_PORT READY_TIMEOUT; do
  value="${!value_name}"
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || die "${value_name} deve ser inteiro positivo; recebido: ${value}."
done
(( API_LISTEN_PORT <= 65535 )) || die "API_PORT deve estar entre 1 e 65535."
(( EXPECTED_GPUS >= TP_SIZE )) || die "EXPECTED_GPUS não pode ser menor que TENSOR_PARALLEL_SIZE."

[[ -n "${MODEL_ID:-}" ]] || die "MODEL_ID não pode ficar vazio."
[[ -n "${MODEL_REVISION:-}" ]] || die "MODEL_REVISION não pode ficar vazio. Use main antes do primeiro pin ou um commit/tag validado."
[[ -n "${SERVED_MODEL_NAME:-}" ]] || die "SERVED_MODEL_NAME não pode ficar vazio."
[[ -n "${VLLM_IMAGE:-}" ]] || die "VLLM_IMAGE não pode ficar vazio."
[[ -n "${API_KEY:-}" && "${API_KEY}" != "CHANGE_ME" ]] || die "API_KEY ausente ou ainda definida como CHANGE_ME."
[[ "${VLLM_MEDIA_URL_ALLOW_REDIRECTS:-0}" =~ ^[01]$ ]] || die "VLLM_MEDIA_URL_ALLOW_REDIRECTS deve ser 0 ou 1."
[[ "${ALLOWED_MEDIA_DOMAIN:-media.invalid}" != *[[:space:]]* ]] || die "ALLOWED_MEDIA_DOMAIN aceita um único domínio sem espaços neste perfil."

command -v nvidia-smi >/dev/null 2>&1 || die "nvidia-smi não encontrado. Use a imagem Azure Ubuntu HPC ou instale o driver NVIDIA antes."
command -v docker >/dev/null 2>&1 || die "Docker não encontrado."
docker compose version >/dev/null 2>&1 || die "Docker Compose não encontrado."
docker info >/dev/null 2>&1 || die "Docker daemon não está acessível."

mapfile -t GPU_MEM < <(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | tr -d ' ')
mapfile -t GPU_NAME < <(nvidia-smi --query-gpu=name --format=csv,noheader)
GPU_COUNT="${#GPU_MEM[@]}"
(( GPU_COUNT >= EXPECTED_GPUS )) || die "São necessárias pelo menos ${EXPECTED_GPUS} GPUs para TP=${TP_SIZE}; detectadas: ${GPU_COUNT}."
if (( GPU_COUNT > EXPECTED_GPUS )); then
  warn "Foram detectadas ${GPU_COUNT} GPUs, mas TP=${TP_SIZE}; GPUs extras poderão ficar ociosas."
fi

for ((i=0; i<EXPECTED_GPUS; i++)); do
  mem="${GPU_MEM[$i]}"
  [[ "$mem" =~ ^[0-9]+$ ]] || die "Não foi possível interpretar a VRAM da GPU $i: $mem"
  (( mem >= MIN_GPU_MEMORY_MIB )) || die "GPU $i (${GPU_NAME[$i]:-desconhecida}) tem ${mem} MiB; este perfil exige >= ${MIN_GPU_MEMORY_MIB} MiB por GPU."
done

mkdir -p "$HF_CACHE_PATH" "$VLLM_CACHE_PATH" || die "Não foi possível criar os diretórios de cache."
DOCKER_ROOT="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
[[ -n "$DOCKER_ROOT" ]] || die "Não foi possível descobrir DockerRootDir."

declare -A REQUIRED_GIB=()
declare -A FREE_GIB=()
declare -A FS_LABELS=()

add_disk_requirement() {
  local path="$1" required="$2" label="$3" probe="$1" device free_kib free_gib
  if ! df -Pk "$probe" >/dev/null 2>&1; then
    probe="$(dirname -- "$path")"
  fi
  df -Pk "$probe" >/dev/null 2>&1 || die "Não foi possível medir espaço livre para ${label} em ${path}."
  device="$(df -Pk "$probe" | awk 'NR==2 {print $1}')"
  free_kib="$(df -Pk "$probe" | awk 'NR==2 {print $4}')"
  [[ -n "$device" && "$free_kib" =~ ^[0-9]+$ ]] || die "Falha ao interpretar filesystem de ${label}."
  free_gib="$(( free_kib / 1024 / 1024 ))"
  REQUIRED_GIB["$device"]="$(( ${REQUIRED_GIB[$device]:-0} + required ))"
  FREE_GIB["$device"]="$free_gib"
  if [[ -n "${FS_LABELS[$device]:-}" ]]; then
    FS_LABELS["$device"]+=" + ${label}"
  else
    FS_LABELS["$device"]="$label"
  fi
}

add_disk_requirement "$HF_CACHE_PATH" "$MIN_HF_FREE_GIB" "pesos/Hugging Face"
add_disk_requirement "$VLLM_CACHE_PATH" "$MIN_VLLM_CACHE_FREE_GIB" "cache vLLM"
add_disk_requirement "$DOCKER_ROOT" "$MIN_DOCKER_FREE_GIB" "Docker"

for device in "${!REQUIRED_GIB[@]}"; do
  required="${REQUIRED_GIB[$device]}"
  free="${FREE_GIB[$device]}"
  (( free >= required )) || die "Espaço insuficiente em ${device} (${FS_LABELS[$device]}): ${free} GiB livres; mínimo agregado recomendado: ${required} GiB."
  log "Disco OK em ${device}: ${free} GiB livres para ${FS_LABELS[$device]} (mínimo agregado ${required} GiB)."
done

DRIVER_VERSION="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n1 | tr -d ' ')"
GPU_SUMMARY="$(printf '%s\n' "${GPU_NAME[@]:0:EXPECTED_GPUS}" | sort -u | paste -sd ';' -)"
log "Pré-validação OK: ${EXPECTED_GPUS}/${GPU_COUNT} GPUs validadas (${GPU_SUMMARY}); TP=${TP_SIZE}; driver ${DRIVER_VERSION}; >=${MIN_GPU_MEMORY_MIB} MiB/GPU."
