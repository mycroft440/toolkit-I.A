#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"
load_env

ORIGIN="$(api_origin)"

status="$(curl -sS -o /dev/null -w '%{http_code}' "${ORIGIN}/v1/models")"
[[ "$status" == "401" || "$status" == "403" ]] || die "Gateway/API deveria rejeitar /v1/models sem chave; HTTP recebido: $status."

status="$(curl -sS -o /dev/null -w '%{http_code}' "${ORIGIN}/invocations")"
[[ "$status" == "404" ]] || die "Gateway deveria bloquear /invocations; HTTP recebido: $status."

curl --fail-with-body -sS --max-time 30 \
  -H "Authorization: Bearer ${API_KEY}" \
  "${ORIGIN}/v1/models" >/dev/null

RESPONSE="$(
  curl --fail-with-body -sS --max-time 300 "${ORIGIN}/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer ${API_KEY}" \
    -d "$(jq -nc \
      --arg model "${SERVED_MODEL_NAME:-glm-5.3-flash}" \
      '{model:$model,messages:[{role:"user",content:"Responda de forma curta e inclua exatamente a expressão GLM OK."}],temperature:1.0,top_p:0.95,max_tokens:256,reasoning_effort:"low",chat_template_kwargs:{clear_thinking:true}}')"
)"

printf '%s\n' "$RESPONSE" | jq .
printf '%s\n' "$RESPONSE" \
  | jq -e '.choices[0].message.content | select(type=="string" and length>0)' >/dev/null \
  || die "A API respondeu, mas não retornou conteúdo de chat válido."

log "Smoke test concluído: autenticação, bloqueio de /invocations, /v1/models e chat estão funcionais."
