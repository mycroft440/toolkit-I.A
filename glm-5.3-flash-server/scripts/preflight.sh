#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib.sh
source "$ROOT_DIR/scripts/lib.sh"

EXPECTED_GPUS="${EXPECTED_GPUS:-8}"
MIN_GPU_MEMORY_MIB="${MIN_GPU_MEMORY_MIB:-130000}"
MIN_FREE_DISK_GIB="${MIN_FREE_DISK_GIB:-420}"
CACHE_DIR="${HF_CACHE_DIR:-/var/lib/glm53/huggingface}"

command -v nvidia-smi >/dev/null 2>&1 || die "nvidia-smi não encontrado. Use a imagem Azure Ubuntu HPC ou instale o driver NVIDIA antes."
command -v docker >/dev/null 2>&1 || die "Docker não encontrado."
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 não encontrado."

mapfile -t GPU_MEM < <(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | tr -d ' ')
GPU_COUNT="${#GPU_MEM[@]}"
(( GPU_COUNT >= EXPECTED_GPUS )) || die "São necessárias pelo menos ${EXPECTED_GPUS} GPUs para o perfil oficial H200/TP8; detectadas: ${GPU_COUNT}."

for i in "${!GPU_MEM[@]}"; do
  mem="${GPU_MEM[$i]}"
  [[ "$mem" =~ ^[0-9]+$ ]] || die "Não foi possível interpretar a VRAM da GPU $i: $mem"
  (( mem >= MIN_GPU_MEMORY_MIB )) || die "GPU $i tem ${mem} MiB; este perfil exige >= ${MIN_GPU_MEMORY_MIB} MiB por GPU."
done

mkdir -p "$CACHE_DIR"
FREE_KIB="$(df -Pk "$CACHE_DIR" | awk 'NR==2 {print $4}')"
FREE_GIB="$(( FREE_KIB / 1024 / 1024 ))"
(( FREE_GIB >= MIN_FREE_DISK_GIB )) || die "Espaço livre insuficiente em $CACHE_DIR: ${FREE_GIB} GiB. Recomendado: >= ${MIN_FREE_DISK_GIB} GiB."

if ! docker info >/dev/null 2>&1; then
  die "Docker daemon não está acessível."
fi

log "Pré-validação OK: ${GPU_COUNT} GPUs; >=${MIN_GPU_MEMORY_MIB} MiB/GPU; ${FREE_GIB} GiB livres no cache."
