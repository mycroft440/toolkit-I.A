# Pesquisa técnica — GLM-5.3-Flash / Azure

Data da revisão: 2026-09-02.

## Resultado

Para a primeira implantação, a combinação de menor atrito continua sendo **Azure ND-H200-v5 + Ubuntu HPC 24.04 + Docker + imagem especial do vLLM para GLM-5.3-Flash**. O objetivo é confiabilidade de bootstrap, não throughput máximo.

## Modelo

- `zai-org/GLM-5.3-Flash`: ~321B parâmetros totais / 18B ativos.
- checkpoint padrão FP8: ~306 GiB antes de overhead.
- contexto declarado: até 1.048.576 tokens.
- perfil inicial deste projeto: 262.144 tokens.

## Runtime escolhido: vLLM

A receita atual usa:

`vllm/vllm-openai:glm53-flash`

com H200, TP=8, parser de tools `glm47`, parser de reasoning `glm45` e `--no-enable-flashinfer-autotune`.

Não trocamos automaticamente para `latest`, porque o suporte do GLM-5.3-Flash depende de componentes recentes específicos.

## FlashInfer

A receita lista **FlashInfer 0.6.17+** como pré-requisito para NoPE Sparse MLA. A mesma página recomenda verificar **0.6.18+** especificamente ao diagnosticar erro de inicialização Sparse-MLA.

Conclusão operacional:

- o instalador rejeita imagem com FlashInfer <0.6.17;
- mantém a imagem especial indicada pela receita;
- se a Azure apresentar erro Sparse-MLA com 0.6.17, o diagnóstico deve registrar a versão e então avaliamos uma imagem mais nova de forma controlada, em vez de trocar silenciosamente antes do teste.

Fonte: https://recipes.vllm.ai/zai-org/GLM-5.3-Flash

## Docker e Azure HPC

As imagens Azure HPC atuais já podem trazer Moby/Docker. Substituir esse stack por Docker CE sem necessidade cria risco de conflito de pacotes.

O instalador agora:

1. reutiliza Docker existente se funcional;
2. instala Docker CE só quando `docker` não existe;
3. se falta apenas Compose v2, tenta o pacote da distribuição;
4. se necessário, baixa o binário oficial do Docker Compose e confere SHA-256.

## Persistência

Persistir somente os pesos não é suficiente para reinícios rápidos. A documentação do vLLM recomenda persistir também `~/.cache/vllm`, onde ficam artefatos de torch.compile/Inductor/Triton.

Por isso há dois diretórios separados:

- `HF_CACHE_DIR`
- `VLLM_CACHE_DIR`

Fonte: https://docs.vllm.ai/en/latest/deployment/docker/

## Segurança / SSRF

A documentação do vLLM recomenda `--allowed-media-domains` porque URLs de mídia sem allowlist podem atingir serviços internos e metadados de cloud. Também recomenda `VLLM_MEDIA_URL_ALLOW_REDIRECTS=0`.

O projeto agora bloqueia URLs remotas por padrão com um domínio inválido (`media.invalid`) e redirects desligados. O operador só abre um domínio deliberadamente.

Fonte: https://docs.vllm.ai/en/latest/usage/security/

## Azure

Perfil:

- `Standard_ND96isr_H200_v5`
- 8× H200 de 141 GB
- 1.128 GB de memória de acelerador total
- NVLink
- Ubuntu HPC 24.04

Referências:
- https://learn.microsoft.com/azure/virtual-machines/sizes/gpu-accelerated/nd-h200-v5-series
- https://learn.microsoft.com/azure/virtual-machines/azure-hpc-vm-images

## Atualizações upstream e pinagem

GLM-5.3-Flash é recente e checkpoint/imagem ainda recebem correções. Pinagem prematura pode congelar um bug.

Estratégia:

1. seguir a imagem especial oficial até o primeiro boot H200 bem-sucedido;
2. rodar `./manage.sh diagnose`;
3. registrar digest da imagem e versões;
4. registrar revisão exata do checkpoint baixado;
5. só então congelar uma configuração reproduzível.

## O que testar na Azure

- 8 GPUs no host e no container;
- versão do driver;
- vLLM e FlashInfer;
- carregamento integral do FP8;
- `/v1/models` autenticado;
- rejeição sem chave;
- bloqueio de `/invocations`;
- chat `reasoning_effort=low`;
- chat `reasoning_effort=max`;
- tool calling;
- bloqueio de URL remota não permitida;
- reboot/recriação com reaproveitamento dos dois caches;
- crescimento progressivo do contexto até 262.144 tokens;
- coleta do digest/revisão para pinagem.
