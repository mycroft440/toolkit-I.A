# Pesquisa técnica — GLM-5.3-Flash / Azure

Data da revisão: 2026-09-02.

## Resultado

A combinação de menor atrito para a primeira implantação continua sendo **Azure ND-H200-v5 + Ubuntu HPC 24.04 + Docker + imagem especial do vLLM para GLM-5.3-Flash**. A meta é previsibilidade de bootstrap, não throughput máximo.

## Modelo e runtime

- `zai-org/GLM-5.3-Flash`: ~321B parâmetros totais / 18B ativos.
- checkpoint padrão nativo FP8: cerca de 306 GiB de pesos antes de runtime/KV.
- contexto declarado: até 1.048.576 tokens.
- perfil inicial: 262.144 tokens.
- imagem: `vllm/vllm-openai:glm53-flash`.
- H200: TP=8, `glm47` para tools, `glm45` para reasoning, `--no-enable-flashinfer-autotune`.
- Hopper não deve forçar FP8 KV para este modelo; o perfil usa o comportamento BF16 KV.

Fonte: https://recipes.vllm.ai/zai-org/GLM-5.3-Flash

## FlashInfer

A receita lista FlashInfer 0.6.17+ para NoPE Sparse MLA; troubleshooting recomenda verificar 0.6.18+ se ocorrer o erro específico de inicialização Sparse-MLA. O bootstrap rejeita <0.6.17 e `diagnose` mostra a versão efetiva.

## Reprodutibilidade do modelo

vLLM suporta `--revision` e `--tokenizer-revision` com branch, tag ou commit. O projeto usa:

```bash
MODEL_REVISION=main
```

antes do primeiro H200. O mesmo valor é passado ao modelo e tokenizer. Depois do primeiro smoke test real, a revisão deve ser trocada pelo commit exato que funcionou.

Fonte: https://docs.vllm.ai/en/latest/cli/serve/

## Docker / Azure HPC

Azure HPC pode trazer Moby/Docker. Substituir um stack funcional por Docker CE cria risco desnecessário, então o instalador reutiliza Docker existente e só instala o que falta. O fallback do plugin Compose usa release oficial e verifica SHA-256.

Operações normais (`start/restart/apply`) usam `--pull never`; somente `update` faz pull deliberado. Reexecutar `install.sh` usa política `missing`, preservando tags já presentes.

## Armazenamento

Há três consumidores relevantes:

- pesos/cache Hugging Face: reserva padrão 420 GiB livres;
- Docker: 80 GiB;
- cache vLLM/torch.compile: 20 GiB.

O preflight agrupa por filesystem. Se os três estiverem no mesmo disco, exige **520 GiB livres**. Para Azure/Spot, 1 TiB persistente oferece margem mais segura e evita depender de armazenamento temporário para o checkpoint.

## Segurança / SSRF

URLs remotas de mídia ficam bloqueadas por `ALLOWED_MEDIA_DOMAIN=media.invalid`; redirects ficam desligados. O vLLM não publica porta diretamente e o Nginx expõe somente `/v1/`.

Fonte: https://docs.vllm.ai/en/latest/usage/security/

## Atualização controlada

O fluxo de `./manage.sh update` foi desenhado para reduzir quebra por tags mutáveis:

1. validar GPUs, configuração e espaço antes do download;
2. guardar ID da imagem vLLM atual;
3. puxar somente o serviço vLLM;
4. validar CUDA, vLLM e FlashInfer na imagem nova;
5. recriar com `--pull never`;
6. esperar `/v1/models`;
7. rodar chat + tool calling;
8. em falha, tentar restaurar a imagem anterior.

Se `VLLM_IMAGE` estiver pinada por digest, a atualização automática é recusada.

## Issues recentes

Triagem de setembro/2026 encontrou problemas em B200/GB200, Ada, ROCm, DBO, DCP, MTP e KV offloading. O perfil inicial H200/TP8 evita esses caminhos.

Dois problemas afetam clientes/agentes independentemente de GPU:

- `#54337`: `assistant.content=null + tool_calls`; issue fechada, porém PR proposta `#54368` ainda aberta/não mesclada nesta revisão. Workaround no cliente continua recomendado até verificar a imagem real.
- `#54744`: flags antigas `enable_thinking/thinking=false` podem fazer reasoning vazar em `content`; issue segue aberta. Use `reasoning_effort` + `clear_thinking`.

## Teste final na Azure

Ainda precisa ser feito com hardware real:

- 8 H200 no host/container;
- carregamento integral do FP8;
- chat low/max;
- tool calling nomeado e auto;
- contexto crescente até 262.144;
- reboot/Spot + reutilização dos caches;
- captura do digest/revisão para pinagem.
