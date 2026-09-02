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
[[ "${ID:-}" == "ubuntu" ]] || die "O instalador automático suporta Ubuntu. Recomendado: Azure Ubuntu HPC 24.04."

log "Instalando dependências básicas..."
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gnupg jq openssl

if ! command -v nvidia-smi >/dev/null 2>&1; then
  die "Driver NVIDIA ausente. Para implantação mais simples, recrie a VM com a imagem Azure Ubuntu HPC, que já inclui o stack NVIDIA/CUDA/NCCL."
fi

install_docker_ce() {
  log "Docker não encontrado; instalando Docker Engine pelo repositório oficial..."
  local pkg
  for pkg in docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc; do
    apt-get remove -y "$pkg" >/dev/null 2>&1 || true
  done

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
}

if ! command -v docker >/dev/null 2>&1; then
  install_docker_ce
elif ! docker compose version >/dev/null 2>&1; then
  log "Docker existe, mas o plugin Compose v2 está ausente; tentando instalar o pacote da distribuição..."
  if ! apt-get install -y docker-compose-v2; then
    die "Docker está instalado, mas não foi possível instalar Docker Compose v2 automaticamente. Use a imagem Azure Ubuntu HPC atual ou instale o plugin Compose v2 manualmente."
  fi
fi
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 não está funcional."
systemctl enable --now docker

if ! command -v nvidia-ctk >/dev/null 2>&1; then
  log "Instalando NVIDIA Container Toolkit..."
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --batch --yes --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
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

if [[ "$OWNER_USER" != "root" ]]; then
  usermod -aG docker "$OWNER_USER" || true
fi

set -a
# .env é gerado localmente pelo instalador e é deliberadamente interpretado como shell env.
# shellcheck disable=SC1091
source .env
set +a
mkdir -p "${HF_CACHE_DIR:-/var/lib/glm53/huggingface}"
chmod 700 "${HF_CACHE_DIR:-/var/lib/glm53/huggingface}"

"$ROOT_DIR/scripts/preflight.sh"

log "Validando Docker Compose..."
docker compose --env-file .env config >/dev/null

log "Baixando imagens de serviço..."
docker compose --env-file .env pull

log "Validando o runtime CUDA com a própria imagem do vLLM..."
docker run --rm --gpus all \
  --entrypoint python3 \
  "${VLLM_IMAGE:-vllm/vllm-openai:glm53-flash}" \
  -c "import sys, torch, vllm; n=torch.cuda.device_count(); print(f'vLLM {vllm.__version__}; CUDA OK: {n} GPU(s); {torch.cuda.get_device_name(0) if n else \"none\"}'); sys.exit(0 if n >= ${TENSOR_PARALLEL_SIZE:-8} else 1)"

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
  ./manage.sh test
  ./manage.sh key

Endpoint no host:
  http://${BIND_ADDRESS:-127.0.0.1}:${API_PORT:-8000}/v1

A API key foi salva em .env (permissão 600) e não é exibida automaticamente.
Por segurança, o padrão escuta apenas em 127.0.0.1. Para agentes remotos, leia SECURITY.md antes de alterar BIND_ADDRESS.
MSG
