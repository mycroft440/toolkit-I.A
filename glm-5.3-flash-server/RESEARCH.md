# Pesquisa técnica — GLM-5.3-Flash / Azure

Data da revisão: 2026-09-02.

## Resultado

Para a primeira implantação, a combinação de menor atrito é **Azure ND-H200-v5 + Ubuntu HPC + Docker + imagem especial do vLLM para GLM-5.3-Flash**. O objetivo desta versão é confiabilidade de bootstrap, não extrair o último ponto percentual de throughput.

## Modelo

- `zai-org/GLM-5.3-Flash` é um MoE de ~321B parâmetros totais / 18B ativos.
- O checkpoint padrão é FP8 e ocupa aproximadamente 306 GiB antes de overhead de runtime/cache.
- O contexto declarado é de até 1.048.576 tokens, mas este projeto começa com 262.144 tokens.

Fonte: https://huggingface.co/zai-org/GLM-5.3-Flash

## Runtime escolhido: vLLM

A receita oficial atual do vLLM publica uma imagem específica para a integração recente do modelo:

`vllm/vllm-openai:glm53-flash`

O perfil recomendado na receita é H200 com TP=8 e inclui os parsers `glm47` (tools) e `glm45` (reasoning). O projeto replica esses parâmetros e evita substituir a imagem especial por `latest`/nightly genérico.

Fonte: https://recipes.vllm.ai/zai-org/GLM-5.3-Flash

## Por que não SGLang na primeira versão

SGLang também é oficialmente suportado, mas na semana desta implementação existem bugs abertos específicos do GLM-5.3-Flash envolvendo MTP/NextN, DP-attention, FP8 KV e caminhos de contexto longo. Isso não significa que SGLang seja inferior em geral; apenas aumenta o número de variáveis para uma instalação cujo objetivo é ser simples.

Referências:
- https://github.com/sgl-project/sglang/issues/37524
- https://github.com/sgl-project/sglang/issues/37548
- https://github.com/sgl-project/sglang/issues/36802
- https://github.com/sgl-project/sglang/issues/36830

## Riscos atuais no vLLM

O suporte ao GLM-5.3-Flash é recente. Há relatos com builds genéricos/nightly e configurações Blackwell/otimizadas que falham ou ficam instáveis. Por isso:

1. usamos a imagem especial `glm53-flash` indicada pela receita;
2. não habilitamos DBO;
3. não habilitamos MTP na primeira versão;
4. em Hopper não forçamos FP8 KV;
5. limitamos o contexto inicial a 262.144 tokens.

Referências:
- https://github.com/vllm-project/vllm/issues/54062
- https://github.com/vllm-project/vllm/issues/54317
- https://github.com/vllm-project/vllm/issues/54591

## Azure

A `Standard_ND96isr_H200_v5` fornece 8 H200 e 1.128 GB de memória de acelerador no total. A imagem Ubuntu HPC da Microsoft já vem preparada com drivers NVIDIA e componentes CUDA/NCCL, reduzindo bastante o risco do bootstrap.

Referências:
- https://learn.microsoft.com/azure/virtual-machines/sizes/gpu-accelerated/nd-h200-v5-series
- https://learn.microsoft.com/azure/virtual-machines/azure-hpc-vm-images

## Segurança

A documentação do vLLM alerta que `--api-key` não autentica todos os endpoints de inferência. Portanto o vLLM não publica sua porta diretamente; o Nginx só permite `/v1/`, bloqueando `/invocations` e outras superfícies não necessárias.

Fonte: https://docs.vllm.ai/en/latest/usage/security/

## O que testar na Azure

- reconhecimento das 8 GPUs pelo host e pelo Docker;
- carregamento integral do checkpoint FP8;
- `/v1/models`;
- chat simples com `reasoning_effort=low`;
- chat com `reasoning_effort=max`;
- tool calling;
- reboot e retomada dos containers;
- requisição progressivamente maior até 262.144 tokens antes de considerar ampliar o contexto.
