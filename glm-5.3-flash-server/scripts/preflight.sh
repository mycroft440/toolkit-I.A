#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
source "$ROOT_DIR/scripts/lib.sh"

if [[ -f "$ROOT_DIR/.env" ]]; then
  load_env
fi

TP_SIZE="${TENSOR_PARALLEL_SIZE:-8}"
EXPECTED_GPUS="${EXPECTED_GPUS:-$TP_SIZE}"
MIN_GPU_MEMORY_MIB="${MIN_GPU_MEMORY_MIB:-130000}"
MIN_FREE_DISK_GIB="${MIN_FREE_DISK_GIB:-420}"
CACHE_DIR="${HF_CACHE_DIR:-/var/lib/glm53/huggingface}"

[[ "$TP_SIZE" =~ ^[1-9][0-9]*$ ]] || die "TENSOR_PARALLEL_SIZE deve ser inteiro positivo."
[[ "$EXPECTED_GPUS" =~ ^[1-9][0-9]*$ ]] || die "EXPECTED_GPUS deve ser inteiro positivo."
[[ "$MIN_GPU_MEMORY_MIB" =~ ^[1-9][0-9]*$ ]] || die "MIN_GPU_MEMORY_MIB deve ser inteiro positivo."
[[ "$MIN_FREE_DISK_GIB" =~ ^[1-9][0-9]*$ ]] || die "MIN_FREE_DISK_GIB deve ser inteiro positivo."

command -v nvidia-smi >/dev/null 2>&1 || die "nvidia-smi não encontrado. Use a imagem Azure Ubuntu HPC ou instale o driver NVIDIA antes."
command -v docker >/dev/null 2>&1 || die "Docker não encontrado."
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 não encontrado."

mapfile -t GPU_MEM < <(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | tr -d ' ')
mapfile -t GPU_NAME < <(nvidia-smi --query-gpu=name --format=csv,noheader)
GPU_COUNT="${#GPU_MEM[@]}"
(( GPU_COUNT >= EXPECTED_GPUS )) || die "São necessárias pelo menos ${EXPECTED_GPUS} GPUs para TP=${EXPECTED_GPUS}; detectadas: ${GPU_COUNT}."
if (( GPU_COUNT > EXPECTED_GPUS )); then
  warn "Foram detectadas ${GPU_COUNT} GPUs, mas TP=${EXPECTED_GPUS}; GPUs extras poderão ficar ociosas."
fi

for i in "${!GPU_MEM[@]}"; do
  mem="${GPU_MEM[$i]}"
  [[ "$mem" =~ ^[0-9]+$ ]] || die "Não foi possível interpretar a VRAM da GPU $i: $mem"
  (( mem >= MIN_GPU_MEMORY_MIB )) || die "GPU $i (${GPU_NAME[$i]:-desconhecida}) tem ${mem} MiB; este perfil exige >= ${MIN_GPU_MEMORY_MIB} MiB por GPU."
done

mkdir -p "$CACHE_DIR"
FREE_KIB="$(df -Pk "$CACHE_DIR" | awk 'NR==2 {print $4}')"
[[ "$FREE_KIB" =~ ^[0-9]+$ ]] || die "Não foi possível medir o espaço livre em $CACHE_DIR."
FREE_GIB="$(( FREE_KIB / 1024 / 1024 ))"
(( FREE_GIB >= MIN_FREE_DISK_GIB )) || die "Espaço livre insuficiente em $CACHE_DIR: ${FREE_GIB} GiB. Recomendado: >= ${MIN_FREE_DISK_GIB} GiB."

docker info >/dev/null 2>&1 || die "Docker daemon não está acessível."

DRIVER_VERSION="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n1 | tr -d ' ')"
GPU_SUMMARY="$(printf '%s\n' "${GPU_NAME[@]}" | sort -u | paste -sd ';' -)"
log "Pré-validação OK: ${GPU_COUNT} GPUs (${GPU_SUMMARY}); driver ${DRIVER_VERSION}; >=${MIN_GPU_MEMORY_MIB} MiB/GPU; ${FREE_GIB} GiB livres no cache."
