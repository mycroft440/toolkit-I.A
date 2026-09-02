# Compatibilidade com agentes

Este servidor expõe o GLM-5.3-Flash em formato OpenAI, mas o suporte upstream ainda está mudando rapidamente. Para agentes com tool calling, aplique estas regras no cliente.

## 1. `assistant.content=null` + `tool_calls`

Clientes OpenAI frequentemente armazenam uma resposta de ferramenta assim:

```json
{
  "role": "assistant",
  "content": null,
  "tool_calls": [...]
}
```

Há um bug upstream aberto em que `content: null` pode virar o texto literal `None` ao passar pelo chat template do GLM. Em sessões longas isso pode degradar o contexto.

Até a correção upstream entrar na imagem validada, normalize para string vazia antes de reenviar o histórico:

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

Use essa função antes de cada requisição que reenvia um histórico com tool calls.

Issue/PR upstream:
- https://github.com/vllm-project/vllm/issues/54337
- https://github.com/vllm-project/vllm/pull/54368

## 2. Controle de raciocínio do GLM-5.3

Use:

- `reasoning_effort`: `low`, `high` ou `max`.
- `chat_template_kwargs.clear_thinking=true` para cenários normais de chat/histórico.

Evite enviar as flags antigas `enable_thinking` ou `thinking` para tentar desligar o raciocínio. Há um bug upstream recente em que essas flags podem fazer o parser parar de separar o raciocínio mesmo enquanto o template continua gerando-o, causando vazamento do scratchpad no campo de conteúdo.

Issue:
- https://github.com/vllm-project/vllm/issues/54744

## 3. Mídia remota

URLs remotas ficam bloqueadas no servidor por padrão. Se o agente precisar de mídia por URL, abra somente um domínio confiável em `ALLOWED_MEDIA_DOMAIN` no `.env`.

## 4. Após o primeiro teste H200

Depois de confirmar o servidor na Azure, congele o digest da imagem/revisão do modelo. Quando uma correção upstream importante para agentes for incorporada, atualize em uma bateria controlada e rode novamente os smoke tests.
