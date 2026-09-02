# Compatibilidade com agentes

Este servidor expõe o GLM-5.3-Flash no formato OpenAI. Como o suporte upstream ainda evolui, aplique estas regras nos agentes clientes.

## 1. `assistant.content=null` + `tool_calls`

Clientes OpenAI podem armazenar uma resposta de ferramenta assim:

```json
{
  "role": "assistant",
  "content": null,
  "tool_calls": [...]
}
```

O problema foi reportado em `vllm-project/vllm#54337`: determinados templates GLM podem renderizar `None` literalmente no contexto, degradando sessões longas com ferramentas. A issue está marcada como encerrada, porém a PR protocolar proposta para normalizar `null` (`#54368`) continua aberta/não incorporada no momento desta revisão.

Portanto, até confirmar a versão efetivamente presente na imagem validada da sua VPS, normalize no cliente:

```python
def normalize_glm_messages(messages):
    normalized = []
    for message in messages:
        message = dict(message)
        if (
            message.get("role") == "assistant"
            and message.get("tool_calls")
            and message.get("content") is None
        ):
            message["content"] = ""
        normalized.append(message)
    return normalized
```

Referências:
- https://github.com/vllm-project/vllm/issues/54337
- https://github.com/vllm-project/vllm/pull/54368

## 2. Raciocínio do GLM-5.3

Use:

- `reasoning_effort`: `low`, `high` ou `max`;
- `chat_template_kwargs.clear_thinking=true` quando estiver reenviando histórico de chat.

Evite `enable_thinking=false` e `thinking=false`. A issue `#54744` continua aberta: no GLM-5.3 essas flags antigas podem desligar a extração do parser sem desligar o thinking do template, fazendo scratchpad/`</think>` aparecerem em `message.content`.

Referência:
- https://github.com/vllm-project/vllm/issues/54744

## 3. Tool calling

O servidor é iniciado com:

- `--tool-call-parser glm47`;
- `--enable-auto-tool-choice`.

O `./manage.sh test` força também uma chamada de função nomeada e valida `tool_calls` + `arguments` JSON. Isso deve ser executado sempre depois de atualizar a imagem vLLM.

Para workflows críticos, prefira ferramenta nomeada/required quando você precisa garantir a estrutura da chamada, em vez de depender sempre de `auto`.

## 4. Mídia remota

URLs remotas ficam bloqueadas por padrão. Se um agente precisar receber imagem/vídeo/áudio por URL, libere apenas um domínio confiável em `ALLOWED_MEDIA_DOMAIN`; redirects continuam desligados por padrão.

## 5. Depois do primeiro teste H200

Após confirmar carregamento + chat + tool calling em H200, congele o digest da imagem e `MODEL_REVISION` no commit exato do checkpoint validado. Só troque um deles em uma atualização controlada e repita o smoke test completo.
