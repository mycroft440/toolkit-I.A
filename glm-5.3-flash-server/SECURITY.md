# Segurança da API

## Padrão seguro

O projeto usa `BIND_ADDRESS=127.0.0.1` por padrão. Isso evita publicar a API na internet por acidente.

O vLLM recebe uma API key forte gerada pelo instalador e fica atrás de um gateway Nginx que publica somente `/v1/`. Endpoints como `/invocations` ficam bloqueados.

## Se os agentes estiverem fora da VM

Escolha uma destas opções, em ordem de preferência:

1. **Azure VNet / IP privado:** agentes e servidor se comunicam pela rede privada.
2. **VPN/Tailscale/WireGuard:** mantenha a API privada e acesse pela rede sobreposta.
3. **NSG com allowlist de IP:** altere `BIND_ADDRESS=0.0.0.0`, mas permita TCP/8000 somente dos IPs fixos dos agentes.
4. **Internet pública:** use TLS (HTTPS) em um reverse proxy e mantenha a API key. Não envie Bearer tokens em HTTP público.

Depois de alterar `.env`:

```bash
./manage.sh restart
```

## Azure NSG

- SSH/22: permita apenas seu IP administrativo ou use Azure Bastion.
- API/8000: não crie regra `0.0.0.0/0`.
- Portas internas do vLLM/NCCL: não exponha; o Compose não as publica no host.

## Segredos

- `.env` está no `.gitignore`.
- Não cole a API key em commits, issues ou logs públicos.
- Para rotacionar a chave, altere `API_KEY` no `.env` e reinicie os containers.

## Limitação do `--api-key` do vLLM

A autenticação nativa do vLLM não cobre todos os endpoints. Por isso o gateway Nginx permite somente `/v1/`.

Referência: https://docs.vllm.ai/en/latest/usage/security/
