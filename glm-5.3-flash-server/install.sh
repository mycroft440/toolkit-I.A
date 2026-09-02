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
COMPOSE_VERSION="${DOCKER_COMPOSE_VERSION:-v5.5.0}"

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

install_compose_plugin_fallback() {
  local arch asset base tmpdir expected actual
  case "$(uname -m)" in
    x86_64|amd64) arch="x86_64" ;;
    aarch64|arm64) arch="aarch64" ;;
    *) die "Arquitetura não suportada pelo fallback do Docker Compose: $(uname -m)" ;;
  esac

  asset="docker-compose-linux-${arch}"
  base="https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}"
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir:-}"' RETURN

  log "Instalando Docker Compose ${COMPOSE_VERSION} pelo release oficial (fallback)..."
  curl -fsSL "${base}/${asset}" -o "${tmpdir}/${asset}"
  curl -fsSL "${base}/${asset}.sha256" -o "${tmpdir}/${asset}.sha256"
  expected="$(awk '{print $1}' "${tmpdir}/${asset}.sha256")"
  actual="$(sha256sum "${tmpdir}/${asset}" | awk '{print $1}')"
  [[ -n "$expected" && "$expected" == "$actual" ]] || die "Checksum do Docker Compose não confere."

  install -m 0755 -d /usr/local/lib/docker/cli-plugins
  install -m 0755 "${tmpdir}/${asset}" /usr/local/lib/docker/cli-plugins/docker-compose
  rm -rf "$tmpdir"
  trap - RETURN
}

if ! command -v docker >/dev/null 2>&1; then
  install_docker_ce
elif ! docker compose version >/dev/null 2>&1; then
  log "Docker existe, mas o plugin Compose está ausente; tentando pacote da distribuição..."
  apt-get install -y docker-compose-v2 >/dev/null 2>&1 || true
  if ! docker compose version >/dev/null 2>&1; then
    install_compose_plugin_fallback
  fi
fi
docker compose version >/dev/null 2>&1 || die "Docker Compose não está funcional."
systemctl enable --now docker

if ! command -v nvidia-ctk >/dev/null 2>&1; then
  log "Instalando NVIDIA Container Toolkit..."
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --batch --yes --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
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

# Atalhos de informações da API.
chmod 0755 "$ROOT_DIR/info"
ln -sfn "$ROOT_DIR/info" /usr/local/bin/glm-info

set -a
# shellcheck disable=SC1091
source .env
set +a
HF_CACHE_PATH="${HF_CACHE_DIR:-/var/lib/glm53/huggingface}"
VLLM_CACHE_PATH="${VLLM_CACHE_DIR:-/var/lib/glm53/vllm-cache}"
mkdir -p "$HF_CACHE_PATH" "$VLLM_CACHE_PATH"
chown "$OWNER_USER:$OWNER_GROUP" "$HF_CACHE_PATH" "$VLLM_CACHE_PATH"
chmod 700 "$HF_CACHE_PATH" "$VLLM_CACHE_PATH"

"$ROOT_DIR/scripts/preflight.sh"

log "Validando Docker Compose..."
docker compose --env-file .env config >/dev/null

# Reexecutar install.sh não deve atualizar silenciosamente um runtime já validado.
log "Garantindo imagens necessárias sem substituir tags já presentes..."
docker compose --env-file .env pull --policy missing

log "Validando CUDA/vLLM/FlashInfer com a própria imagem de inferência..."
docker run --rm --gpus all \
  --entrypoint python3 \
  "${VLLM_IMAGE:-vllm/vllm-openai:glm53-flash}" \
  -c "import sys, torch, vllm; from importlib.metadata import version; from packaging.version import Version; n=torch.cuda.device_count(); fi=version('flashinfer-python'); print(f'vLLM {vllm.__version__}; FlashInfer {fi}; CUDA OK: {n} GPU(s); {torch.cuda.get_device_name(0) if n else \"none\"}'); sys.exit(0 if n >= ${TENSOR_PARALLEL_SIZE:-8} and Version(fi) >= Version('0.6.17') else 1)"

log "Subindo GLM-5.3-Flash..."
docker compose --env-file .env up -d --pull never

cat <<MSG

Instalação iniciada com sucesso.
A primeira inicialização precisa baixar o checkpoint do GLM-5.3-Flash para:
  ${HF_CACHE_PATH}

Para ver todas as informações da API a qualquer momento:
  glm-info

Ou dentro desta pasta:
  ./info
  ./manage.sh info

Outros comandos úteis:
  ./manage.sh status
  ./manage.sh logs
  ./manage.sh wait
  ./manage.sh test
  ./manage.sh diagnose
  ./manage.sh key

Endpoint no host:
  http://${BIND_ADDRESS:-127.0.0.1}:${API_PORT:-8000}/v1

A API key foi salva em .env (permissão 600) e não é exibida automaticamente na instalação.
URLs remotas de mídia ficam bloqueadas por padrão; veja SECURITY.md para liberar somente domínios confiáveis.
Por segurança, o padrão escuta apenas em 127.0.0.1. Para agentes remotos, leia SECURITY.md antes de alterar BIND_ADDRESS.
MSG
