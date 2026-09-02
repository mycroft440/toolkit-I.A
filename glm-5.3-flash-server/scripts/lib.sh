#!/usr/bin/env bash
set -Eeuo pipefail

log() { printf '\033[1;34m[glm53]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[glm53][warn]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[glm53][error]\033[0m %s\n' "$*" >&2; exit 1; }

project_dir() {
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd
}

load_env() {
  local root
  root="$(project_dir)"
  [[ -f "$root/.env" ]] || die "Arquivo .env ausente. Execute ./install.sh primeiro."
  set -a
  # shellcheck disable=SC1091
  source "$root/.env"
  set +a
}
