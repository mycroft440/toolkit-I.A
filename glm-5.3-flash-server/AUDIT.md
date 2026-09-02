# Auditoria técnica — 2026-09-02

## Escopo

Revisão repetida do bootstrap Azure, Docker/Compose, NVIDIA Container Toolkit, vLLM, GLM-5.3-Flash, Nginx, API OpenAI, tool calling, segurança, persistência, atualização/rollback, `glm-info`, CI e documentação.

## Base confirmada

- Alvo: Azure `Standard_ND96isr_H200_v5`, 8× H200 141 GB.
- Runtime: imagem especial `vllm/vllm-openai:glm53-flash` indicada pela receita atual do GLM-5.3-Flash.
- Perfil inicial: TP=8, 262.144 tokens, `glm47` para tools, `glm45` para reasoning, sem DBO/MTP/KV offload/FP8-KV forçado em Hopper.
- FlashInfer mínimo validado pelo bootstrap: 0.6.17; a receita recomenda checar 0.6.18+ se houver erro específico de Sparse-MLA.

## Problemas encontrados e corrigidos ao longo das auditorias

1. teste CUDA genérico podia divergir da imagem real; agora testa a própria imagem vLLM;
2. `restart` não reaplicava `.env`; agora recria containers;
3. health/test presos em 127.0.0.1; agora respeitam o bind para probes locais;
4. API key era impressa automaticamente na instalação; removido;
5. logs Docker sem rotação; corrigido;
6. `/healthz` desnecessário no gateway; removido;
7. smoke test incompleto; ampliado para auth, bloqueio, models, chat e tool calling;
8. CI ganhou Bash, ShellCheck, Compose, Nginx e teste do symlink global;
9. variável Hugging Face antiga substituída por `HF_TOKEN`;
10. keyring NVIDIA tornado idempotente (`gpg --batch --yes`);
11. possível conflito com Moby do Azure HPC; Docker existente é reutilizado;
12. fallback do Compose usa release oficial + SHA-256;
13. cache de compilação vLLM passou a ser persistente;
14. mídia remota bloqueada por domínio inválido + redirects desligados para reduzir SSRF;
15. `diagnose` mostra driver/GPU/Docker/digest/runtime sem mostrar segredos;
16. preflight passou a validar apenas GPUs efetivamente exigidas e parâmetros numéricos;
17. FlashInfer passou a ser verificado antes de carregar o modelo;
18. compatibilidade `content=null + tool_calls` documentada;
19. flags antigas de thinking documentadas como inseguras para GLM-5.3;
20. **bug real em `glm-info` global**: symlink fazia `BASH_SOURCE` apontar para `/usr/local/bin`; reproduzido e corrigido com `readlink -f`;
21. `info/key/test` escalavam para sudo sem necessidade; removido;
22. `info` não tinha modo executável no Git; corrigido para `100755`;
23. CI agora executa o launcher através de um symlink real e impede regressão;
24. caches `root:root` modo 700 dificultavam operação posterior sem sudo; continuam 700, mas pertencem ao usuário instalador;
25. preflight só media espaço dos pesos; agora mede também Docker + cache vLLM e **soma requisitos quando compartilham filesystem**;
26. com defaults no mesmo filesystem, o mínimo agregado passa a 520 GiB livres (420 + 80 + 20);
27. reexecutar `install.sh` podia puxar tags novas; agora usa pull somente se a imagem estiver ausente;
28. `start/restart/apply` passam a usar `--pull never`, impedindo atualização silenciosa;
29. `update` passa a validar configuração/disco antes do pull e baixa apenas vLLM;
30. imagem vLLM nova é testada em CUDA/vLLM/FlashInfer antes de recriar o servidor;
31. `update` só é aceito após health + smoke test completo; em falha tenta retag/recriar a imagem anterior;
32. imagem fixada por digest não é atualizada automaticamente;
33. foi adicionado `MODEL_REVISION`, enviado a `--revision` e `--tokenizer-revision`, para permitir pin do checkpoint após o teste real;
34. `glm-info`/`diagnose` passam a mostrar a revisão configurada;
35. smoke test ganhou uma função nomeada para validar de fato o parser `glm47` e `tool_calls` OpenAI.

## Issues upstream triadas

Os problemas recentes mais graves encontrados estão associados a B200/GB200, Ada, ROCm, DBO, DCP, MTP ou KV offloading. O perfil conservador H200/TP8 não habilita esses caminhos.

Para agentes existem dois pontos independentes de GPU:

- `#54337` (`content=null + tool_calls`) está marcado como fechado, mas a PR proposta `#54368` continua aberta/não mesclada nesta revisão; mantenha normalização no cliente até validar a imagem instalada.
- `#54744` continua aberto: `enable_thinking/thinking=false` pode fazer reasoning vazar em `content`; use `reasoning_effort` + `clear_thinking`.

## Reprodutibilidade

Antes do primeiro H200 real:

- `VLLM_IMAGE=vllm/vllm-openai:glm53-flash`;
- `MODEL_REVISION=main`.

Depois de carregar o modelo e passar chat + tool calling, registrar e fixar:

- digest da imagem;
- commit do checkpoint em `MODEL_REVISION`;
- vLLM;
- FlashInfer;
- driver NVIDIA.

## Estado da validação

GitHub Actions valida sintaxe Bash, ShellCheck, Compose, Nginx e o comportamento do `glm-info` global. A única classe de teste que permanece impossível sem a VM é o runtime completo em 8× H200: download/carregamento FP8, alocação KV, inferência, tool calling sob GPU e reboot/Spot.

## Fontes principais

- https://recipes.vllm.ai/zai-org/GLM-5.3-Flash
- https://docs.vllm.ai/en/latest/cli/serve/
- https://docs.vllm.ai/en/latest/usage/security/
- https://github.com/vllm-project/vllm/issues/54337
- https://github.com/vllm-project/vllm/pull/54368
- https://github.com/vllm-project/vllm/issues/54744
- https://learn.microsoft.com/azure/virtual-machines/sizes/gpu-accelerated/nd-h200-v5-series
- https://learn.microsoft.com/azure/virtual-machines/azure-hpc-vm-images
