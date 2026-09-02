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

log "Chat básico OK. Testando tool calling nomeado..."
TOOL_RESPONSE="$(
  curl --fail-with-body -sS --max-time 300 "${ORIGIN}/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer ${API_KEY}" \
    -d "$(jq -nc \
      --arg model "${SERVED_MODEL_NAME:-glm-5.3-flash}" \
      '{
        model:$model,
        messages:[{role:"user",content:"Chame a ferramenta get_test_value para responder a esta solicitação."}],
        tools:[{
          type:"function",
          function:{
            name:"get_test_value",
            description:"Ferramenta usada apenas para o smoke test do servidor.",
            parameters:{type:"object",properties:{value:{type:"string"}},required:["value"],additionalProperties:false}
          }
        }],
        tool_choice:{type:"function",function:{name:"get_test_value"}},
        max_tokens:256,
        reasoning_effort:"low",
        chat_template_kwargs:{clear_thinking:true}
      }')"
)"

printf '%s\n' "$TOOL_RESPONSE" | jq .
printf '%s\n' "$TOOL_RESPONSE" \
  | jq -e '.choices[0].message.tool_calls[0].function | (.name == "get_test_value") and (.arguments | type == "string" and length > 0)' >/dev/null \
  || die "Tool calling respondeu, mas não retornou a função nomeada no formato OpenAI esperado."

TOOL_ARGUMENTS="$(printf '%s\n' "$TOOL_RESPONSE" | jq -r '.choices[0].message.tool_calls[0].function.arguments')"
printf '%s' "$TOOL_ARGUMENTS" | jq -e 'type == "object" and has("value")' >/dev/null \
  || die "Tool calling retornou arguments que não são JSON válido conforme o schema esperado."

log "Smoke test concluído: autenticação, bloqueio de /invocations, /v1/models, chat e tool calling estão funcionais."
