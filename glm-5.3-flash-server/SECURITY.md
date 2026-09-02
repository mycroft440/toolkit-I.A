# Segurança da API

## Padrão seguro

O projeto usa `BIND_ADDRESS=127.0.0.1` por padrão. Isso evita publicar a API na internet por acidente.

O vLLM recebe uma API key forte gerada pelo instalador e fica atrás de Nginx, que publica somente `/v1/`. Endpoints não necessários, como `/invocations`, ficam bloqueados pelo gateway.

## SSRF e mídia remota

vLLM pode receber URLs de mídia em workloads multimodais. Sem restrição de domínio, um cliente poderia tentar fazer o servidor acessar recursos internos da rede ou metadados da nuvem.

Por isso os defaults são:

```bash
ALLOWED_MEDIA_DOMAIN=media.invalid
VLLM_MEDIA_URL_ALLOW_REDIRECTS=0
```

`media.invalid` é deliberadamente inválido e efetivamente bloqueia mídia remota por URL.

Se precisar de mídia remota, use somente um domínio confiável, por exemplo:

```bash
ALLOWED_MEDIA_DOMAIN=media.exemplo.com
```

Depois:

```bash
./manage.sh apply
```

Não use `*`, um domínio controlado por terceiros ou um host que possa redirecionar para destinos internos.

## Se os agentes estiverem fora da VM

Escolha, em ordem de preferência:

1. **Azure VNet / IP privado**.
2. **VPN/Tailscale/WireGuard**.
3. **NSG com allowlist de IP**, alterando `BIND_ADDRESS=0.0.0.0` apenas depois de restringir TCP/8000.
4. **Internet pública**, somente com TLS/HTTPS e API key.

## Azure NSG

- SSH/22: permita apenas seu IP administrativo ou use Azure Bastion.
- API/8000: não crie regra `0.0.0.0/0`.
- Portas internas do vLLM/NCCL: não exponha.

## Segredos

- `.env` está no `.gitignore`.
- `.env` recebe permissão `600`.
- O instalador não imprime a API key automaticamente.
- Não cole a chave em commits, issues ou logs públicos.
- Para rotacionar: altere `API_KEY` e rode `./manage.sh apply`.

## Cache

Os caches Hugging Face e vLLM devem vir apenas de fontes confiáveis. Não reutilize cache recebido de terceiros.

## Diagnóstico

`./manage.sh diagnose` mostra SO, GPUs, driver, Docker, digest da imagem e versões vLLM/FlashInfer, mas não imprime `API_KEY` nem `HF_TOKEN`.

## Limitação do `--api-key` do vLLM

A autenticação nativa do vLLM não cobre toda a superfície administrativa/auxiliar. O gateway Nginx limita a exposição a `/v1/` justamente para reduzir esse risco.

Referência: https://docs.vllm.ai/en/latest/usage/security/
