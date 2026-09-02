#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"
load_env

curl -fsS "http://127.0.0.1:${API_PORT:-8000}/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer ${API_KEY}" \
  -d "$(jq -nc \
    --arg model "${SERVED_MODEL_NAME:-glm-5.3-flash}" \
    '{model:$model,messages:[{role:"user",content:"Responda apenas: GLM OK"}],temperature:0,max_tokens:32,reasoning_effort:"low",chat_template_kwargs:{clear_thinking:true}}')" \
  | jq .
