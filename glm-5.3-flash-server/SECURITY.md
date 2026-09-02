# Segurança da API

## Padrão seguro

O projeto usa `BIND_ADDRESS=127.0.0.1` por padrão. O container vLLM não publica sua porta diretamente; o Nginx encaminha somente `/v1/`. Endpoints auxiliares como `/invocations` ficam bloqueados pelo gateway.

A API key é gerada aleatoriamente e o `.env` recebe permissão `600`.

## `glm-info` mostra a chave

Por solicitação de operação simplificada, `glm-info` / `./info` mostram a API key junto das demais informações de conexão. Trate a saída como **segredo**: não envie print, gravação de terminal ou log desse painel para terceiros.

Para diagnóstico que não mostra segredos, use:

```bash
./manage.sh diagnose
```

## SSRF e mídia remota

vLLM pode receber URLs de mídia. Para evitar que clientes façam o servidor consultar recursos internos/metadados da nuvem, os defaults são:

```bash
ALLOWED_MEDIA_DOMAIN=media.invalid
VLLM_MEDIA_URL_ALLOW_REDIRECTS=0
```

Se precisar de mídia remota, libere somente um domínio confiável. Não use `*`, domínio de terceiros ou host capaz de redirecionar para destinos internos.

## Agentes fora da VM

Preferência:

1. Azure VNet / IP privado;
2. VPN/Tailscale/WireGuard;
3. NSG com allowlist de IP e `BIND_ADDRESS=0.0.0.0`;
4. Internet pública somente com TLS/HTTPS + API key.

No Azure NSG, não abra TCP/8000 para `0.0.0.0/0`. Restrinja SSH/22 ao seu IP ou use Bastion.

## Atualizações

`start`, `restart` e `apply` não fazem pull de imagens. Isso reduz a chance de um tag mutável mudar silenciosamente entre reinícios.

`./manage.sh update` é deliberado: valida configuração/disco antes do download, baixa somente a imagem vLLM, valida CUDA/vLLM/FlashInfer antes de recriar e roda health + smoke test completo depois. Se o novo runtime falhar, tenta restaurar a imagem anterior.

Depois do primeiro teste H200 bem-sucedido, fixe o digest da imagem vLLM e o commit em `MODEL_REVISION`. Quando `VLLM_IMAGE` estiver em `@sha256:...`, a atualização automática é recusada por design.

## Segredos e caches

- `.env` está no `.gitignore`.
- Não cole `API_KEY`/`HF_TOKEN` em commits, issues ou logs.
- Para rotacionar a chave, altere `API_KEY` e rode `./manage.sh apply`.
- Caches Hugging Face/vLLM devem vir apenas de fontes confiáveis.
- Os diretórios de cache são criados com modo `700` e pertencem ao usuário que executou a instalação via sudo.

## Limitação do `--api-key` do vLLM

A autenticação nativa do vLLM não cobre necessariamente toda a superfície administrativa/auxiliar. Por isso o gateway limita a exposição a `/v1/`.

Referência: https://docs.vllm.ai/en/latest/usage/security/
