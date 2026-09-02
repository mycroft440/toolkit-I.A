# Auditoria técnica — 2026-09-02

## Escopo

Revisão do bootstrap Azure, Docker/Compose, runtime NVIDIA, vLLM, gateway, smoke tests, persistência e documentação contra as fontes upstream atuais.

## Verificações confirmadas

- `Standard_ND96isr_H200_v5` fornece 8× H200 de 141 GB e é suportada pelo Ubuntu HPC.
- A receita atual do vLLM para `zai-org/GLM-5.3-Flash` usa a imagem `vllm/vllm-openai:glm53-flash`, H200, TP=8, `glm47` para tool calling e `glm45` para reasoning.
- O checkpoint oficial FP8 ocupa aproximadamente 306 GiB antes do overhead de runtime/KV.
- Docker Compose suporta reserva de GPU via `deploy.resources.reservations.devices`.
- `VLLM_API_KEY` não protege todos os endpoints do servidor vLLM; manter o vLLM atrás do gateway é necessário.
- A documentação atual do vLLM recomenda allowlist para URLs de mídia e redirects desligados para reduzir SSRF.
- O vLLM recomenda persistir também `~/.cache/vllm` para reaproveitar artefatos de compilação entre containers.

## Problemas encontrados e corrigidos

1. **Teste CUDA incompatível com a imagem Azure recomendada:** a validação passou a usar a própria imagem `vllm/vllm-openai:glm53-flash`.
2. **`restart` não reaplicava `.env`:** `restart/apply` usa `up -d --force-recreate`.
3. **Probe preso em `127.0.0.1`:** health/test calculam a origem a partir do bind.
4. **Chave impressa automaticamente:** permanece somente no `.env` (modo 600), sob comando explícito.
5. **Logs sem limite:** rotação configurada.
6. **Endpoint `/healthz` desnecessário:** removido.
7. **Smoke test incompleto:** valida auth, `/invocations`, `/v1/models` e chat.
8. **CI incompleta:** `workflow_dispatch`, ShellCheck, Compose e `nginx -t`.
9. **Variável Hugging Face antiga:** `HUGGING_FACE_HUB_TOKEN` substituída por `HF_TOKEN`.
10. **Keyring NVIDIA não idempotente:** `gpg --batch --yes`.
11. **Risco de conflito com Moby do Azure HPC:** Docker existente é reutilizado; Docker CE só é instalado quando `docker` não existe.
12. **Compose v2 ausente em instalação parcial:** há fallback para release oficial do Docker Compose com validação SHA-256.
13. **Cache de compilação efêmero:** `VLLM_CACHE_DIR` é persistido em `/root/.cache/vllm`.
14. **SSRF por mídia remota:** URLs remotas ficam bloqueadas por padrão com `media.invalid`; redirects ficam desligados.
15. **Diagnóstico insuficiente:** `./manage.sh diagnose` mostra SO, GPUs, driver, Docker, digest da imagem e versões vLLM/FlashInfer sem mostrar segredos.
16. **Preflight validava GPUs extras desnecessariamente:** agora só exige VRAM das GPUs efetivamente usadas pelo TP.
17. **Versão crítica do FlashInfer não era conferida:** o bootstrap rejeita imagem abaixo de 0.6.17 e registra a versão usada.

## Decisões mantidas

- Contexto inicial de 262.144 tokens.
- Sem MTP, DBO ou FP8 KV forçado na primeira implantação H200.
- Bind local (`127.0.0.1`) por padrão.
- `privileged` + `ipc: host`, pois a receita oficial atual do caminho Docker H200 ainda os utiliza.
- Imagem especial `glm53-flash`, sem troca automática para `latest`.

## FlashInfer: discrepância upstream

A receita declara FlashInfer **0.6.17+** nos pré-requisitos, mas a seção de troubleshooting sugere conferir **0.6.18+** caso apareça erro de inicialização Sparse-MLA.

Não vamos substituir preventivamente a imagem oficial. O instalador confirma >=0.6.17; se a H200 real apresentar o erro específico, `diagnose` registrará a versão e a atualização será feita de forma controlada.

## Reprodutibilidade

Checkpoint e imagem ainda recebem atualizações rápidas. A estratégia é não congelar uma revisão possivelmente defeituosa antes do primeiro teste H200. Após o primeiro carregamento e smoke test bem-sucedidos, registrar:

- digest da imagem;
- revisão do checkpoint;
- vLLM;
- FlashInfer;
- driver NVIDIA.

Depois disso, congelar a combinação validada.

## Validação automatizada

O GitHub Actions valida sintaxe Bash, ShellCheck, resolução do Docker Compose e sintaxe do Nginx. A validação real de CUDA/H200/modelo só pode ocorrer na VM GPU.

## Risco residual

O risco principal restante é runtime real: o GLM-5.3-Flash/vLLM é recente e ainda há mudanças upstream. A versão só deve ser classificada como comprovada depois do carregamento FP8 e smoke tests em uma Azure `Standard_ND96isr_H200_v5`.

## Fontes

- https://recipes.vllm.ai/zai-org/GLM-5.3-Flash
- https://huggingface.co/zai-org/GLM-5.3-Flash
- https://docs.vllm.ai/en/latest/deployment/docker/
- https://docs.vllm.ai/en/latest/usage/security/
- https://docs.docker.com/compose/how-tos/gpu-support/
- https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html
- https://huggingface.co/docs/huggingface_hub/main/package_reference/environment_variables
- https://learn.microsoft.com/azure/virtual-machines/sizes/gpu-accelerated/nd-h200-v5-series
- https://learn.microsoft.com/azure/virtual-machines/azure-hpc-vm-images
- https://github.com/Azure/azhpc-images/releases
