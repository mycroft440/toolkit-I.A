#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"

if [[ "${EUID}" -ne 0 ]]; then
  exec sudo -E bash "$0" "$@"
fi

cd "$ROOT_DIR"
OWNER_USER="${SUDO_USER:-root}"
OWNER_GROUP="$(id -gn "$OWNER_USER")"

if [[ ! -r /etc/os-release ]]; then
  die "Não foi possível identificar o sistema operacional."
fi
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || die "O instalador automático suporta Ubuntu. Recomendado: Azure Ubuntu HPC."

log "Instalando dependências básicas..."
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gnupg jq openssl

if ! command -v nvidia-smi >/dev/null 2>&1; then
  die "Driver NVIDIA ausente. Para implantação mais simples, recrie a VM com a imagem Azure Ubuntu HPC, que já inclui o stack NVIDIA/CUDA/NCCL."
fi

if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  log "Instalando Docker Engine e Docker Compose pelo repositório oficial..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  cat >/etc/apt/sources.list.d/docker.sources <<DOCKER_REPO
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
DOCKER_REPO
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
systemctl enable --now docker

if ! command -v nvidia-ctk >/dev/null 2>&1; then
  log "Instalando NVIDIA Container Toolkit..."
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt-get update
  apt-get install -y nvidia-container-toolkit
fi

log "Configurando runtime NVIDIA no Docker..."
nvidia-ctk runtime configure --runtime=docker
systemctl restart docker

if [[ ! -f .env ]]; then
  cp .env.example .env
  log "Arquivo .env criado."
fi

CURRENT_KEY="$(grep -E '^API_KEY=' .env | head -n1 | cut -d= -f2- || true)"
if [[ -z "$CURRENT_KEY" || "$CURRENT_KEY" == "CHANGE_ME" ]]; then
  GENERATED_KEY="$(openssl rand -hex 32)"
  if grep -q '^API_KEY=' .env; then
    sed -i "s/^API_KEY=.*/API_KEY=${GENERATED_KEY}/" .env
  else
    printf '\nAPI_KEY=%s\n' "$GENERATED_KEY" >> .env
  fi
  log "API key segura gerada automaticamente."
else
  log "Mantendo API key existente."
fi
chmod 600 .env
chown "$OWNER_USER:$OWNER_GROUP" .env

# Permite operação sem sudo após novo login, sem depender disso durante a instalação.
if [[ "$OWNER_USER" != "root" ]]; then
  usermod -aG docker "$OWNER_USER" || true
fi

# shellcheck disable=SC1091
set -a; source .env; set +a
mkdir -p "${HF_CACHE_DIR:-/var/lib/glm53/huggingface}"
chmod 700 "${HF_CACHE_DIR:-/var/lib/glm53/huggingface}"

"$ROOT_DIR/scripts/preflight.sh"

log "Validando acesso das GPUs dentro de um container..."
docker run --rm --gpus all nvidia/cuda:13.2.0-base-ubuntu24.04 nvidia-smi >/dev/null

log "Validando Docker Compose..."
docker compose --env-file .env config >/dev/null

log "Baixando imagens de serviço..."
docker compose --env-file .env pull

log "Subindo GLM-5.3-Flash..."
docker compose --env-file .env up -d

cat <<MSG

Instalação iniciada com sucesso.
A primeira inicialização precisa baixar o checkpoint do GLM-5.3-Flash para:
  ${HF_CACHE_DIR:-/var/lib/glm53/huggingface}

Comandos úteis:
  ./manage.sh status
  ./manage.sh logs
  ./manage.sh wait
  ./test-api.sh

Endpoint no host:
  http://${BIND_ADDRESS:-127.0.0.1}:${API_PORT:-8000}/v1

API key:
  $(grep '^API_KEY=' .env | cut -d= -f2-)

Por segurança, o padrão escuta apenas em 127.0.0.1. Para agentes remotos, leia SECURITY.md antes de alterar BIND_ADDRESS.
MSG
