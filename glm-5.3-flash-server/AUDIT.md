# Auditoria técnica — 2026-09-02

## Escopo

Revisão do bootstrap Azure, Docker/Compose, runtime NVIDIA, vLLM, gateway, smoke tests, persistência e documentação contra as fontes upstream atuais.

## Verificações confirmadas

- `Standard_ND96isr_H200_v5` fornece 8× H200 de 141 GB e é suportada pelo Ubuntu HPC.
- A receita atual do vLLM para `zai-org/GLM-5.3-Flash` usa a imagem `vllm/vllm-openai:glm53-flash`, H200, TP=8, `glm47` para tool calling e `glm45` para reasoning.
- O checkpoint oficial FP8 ocupa aproximadamente 306 GiB antes do overhead de runtime/KV.
- Docker Compose suporta reserva de GPU via `deploy.resources.reservations.devices`.
- `VLLM_API_KEY` não protege todos os endpoints do servidor vLLM; manter o vLLM atrás do gateway é necessário.

## Problemas encontrados e corrigidos

1. **Teste CUDA incompatível com a imagem Azure recomendada:** o instalador usava `nvidia/cuda:13.2.0...` só para testar GPU. O Ubuntu HPC A100+ mais recente disponível para H200 usa driver 580.173.02 / CUDA 13.0, então esse teste externo podia falhar apesar de o runtime real ser compatível. Agora a validação roda `torch.cuda` dentro da própria imagem `vllm/vllm-openai:glm53-flash`.
2. **`restart` não reaplicava `.env`:** `docker compose restart` não recria containers. Agora `restart/apply` usa `up -d --force-recreate`, aplicando API key, bind, contexto e demais parâmetros alterados.
3. **Probe preso em `127.0.0.1`:** health/test falhavam se `BIND_ADDRESS` fosse configurado para um IP privado específico. Agora os scripts calculam o endereço de probe a partir do bind.
4. **Chave impressa automaticamente:** o instalador mostrava a API key no stdout. Agora ela fica somente no `.env` (modo 600) e é exibida apenas sob comando explícito `./manage.sh key`.
5. **Logs sem limite:** logs Docker poderiam crescer indefinidamente e consumir o disco. Foram adicionados limites de rotação.
6. **Endpoint operacional extra no Nginx:** `/healthz` não era necessário e contrariava a política de publicar somente `/v1/`. Foi removido.
7. **Smoke test incompleto:** agora valida autenticação sem chave, bloqueio de `/invocations`, `/v1/models` autenticado e geração de chat.
8. **CI sem execução manual e sem validar Nginx:** adicionados `workflow_dispatch` e `nginx -t`.

## Decisões mantidas

- Contexto inicial de 262.144 tokens.
- Sem MTP, DBO ou FP8 KV na primeira implantação H200.
- Bind local (`127.0.0.1`) por padrão.
- `privileged` + `ipc: host`, porque a receita oficial atual do vLLM usa esses parâmetros no caminho Docker H200.

## Risco residual

O suporte do GLM-5.3-Flash no vLLM é recente e ainda existem issues abertas em caminhos otimizados e/ou outros hardwares. A única validação que falta para classificar esta versão como comprovada em produção é executar o carregamento e smoke test em uma Azure `Standard_ND96isr_H200_v5` real.

## Fontes

- https://recipes.vllm.ai/zai-org/GLM-5.3-Flash
- https://huggingface.co/zai-org/GLM-5.3-Flash
- https://docs.vllm.ai/en/latest/usage/security/
- https://docs.docker.com/compose/how-tos/gpu-support/
- https://learn.microsoft.com/azure/virtual-machines/sizes/gpu-accelerated/nd-h200-v5-series
- https://learn.microsoft.com/azure/virtual-machines/azure-hpc-vm-images
- https://github.com/Azure/azhpc-images/releases
