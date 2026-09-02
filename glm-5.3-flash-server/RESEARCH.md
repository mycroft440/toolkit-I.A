# Pesquisa técnica — GLM-5.3-Flash / Azure

Data da revisão: 2026-09-02.

## Resultado

Para a primeira implantação, a combinação de menor atrito é **Azure ND-H200-v5 + Ubuntu HPC 24.04 + Docker + imagem especial do vLLM para GLM-5.3-Flash**. O objetivo desta versão é confiabilidade de bootstrap, não extrair o último ponto percentual de throughput.

## Modelo

- `zai-org/GLM-5.3-Flash` é um MoE de ~321B parâmetros totais / 18B ativos.
- O checkpoint padrão é FP8 e ocupa aproximadamente 306 GiB antes de overhead de runtime/cache.
- O contexto declarado é de até 1.048.576 tokens, mas este projeto começa com 262.144 tokens.
- O `generation_config.json` oficial usa `temperature=1.0` e `top_p=0.95`; o smoke test segue esses defaults.

Fonte: https://huggingface.co/zai-org/GLM-5.3-Flash

## Runtime escolhido: vLLM

A receita oficial atual do vLLM publica uma imagem específica para a integração recente do modelo:

`vllm/vllm-openai:glm53-flash`

O perfil recomendado na receita é H200 com TP=8 e inclui os parsers `glm47` (tools) e `glm45` (reasoning). O projeto replica esses parâmetros e evita substituir a imagem especial por `latest`/nightly genérico.

Fonte: https://recipes.vllm.ai/zai-org/GLM-5.3-Flash

## Azure

A `Standard_ND96isr_H200_v5` fornece 8 H200, 141 GB por GPU e 1.128 GB de memória de acelerador no total. A imagem Ubuntu HPC suporta esse SKU.

Na revisão atual, a versão mais recente publicada do Ubuntu HPC 24.04 A100+ é `microsoft-dsvm:ubuntu-hpc:2404:24.04.2026072901`, com NVIDIA 580.173.02, CUDA 13.0.88, NCCL 2.30.4 e Docker/Moby 29.6.2. Isso reforça a decisão de não amarrar o preflight a uma imagem CUDA externa arbitrária; o teste agora é executado dentro da própria imagem vLLM.

Referências:
- https://learn.microsoft.com/azure/virtual-machines/sizes/gpu-accelerated/nd-h200-v5-series
- https://learn.microsoft.com/azure/virtual-machines/azure-hpc-vm-images
- https://github.com/Azure/azhpc-images/releases

## Riscos atuais no vLLM

O suporte ao GLM-5.3-Flash é recente. Há relatos com builds genéricos/nightly e configurações Blackwell/ROCm/otimizadas que falham ou ficam instáveis. Por isso:

1. usamos a imagem especial `glm53-flash` indicada pela receita;
2. não habilitamos DBO;
3. não habilitamos MTP na primeira versão;
4. em Hopper não forçamos FP8 KV;
5. limitamos o contexto inicial a 262.144 tokens;
6. validamos o CUDA real dentro da imagem vLLM antes de subir o serviço.

Referências:
- https://github.com/vllm-project/vllm/issues/54062
- https://github.com/vllm-project/vllm/issues/54317
- https://github.com/vllm-project/vllm/issues/54591

## Docker / NVIDIA

Docker Compose suporta reserva de GPUs por `deploy.resources.reservations.devices`, com `capabilities: [gpu]`. A instalação do NVIDIA Container Toolkit e `nvidia-ctk runtime configure --runtime=docker` seguem a documentação oficial.

Referências:
- https://docs.docker.com/compose/how-tos/gpu-support/
- https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html

## Segurança

A documentação do vLLM alerta que `--api-key` não autentica todos os endpoints, incluindo `/invocations` e endpoints operacionais. Portanto o vLLM não publica sua porta diretamente; o Nginx permite somente `/v1/` e todo o resto recebe 404.

Fonte: https://docs.vllm.ai/en/latest/usage/security/

## Auditoria

A auditoria pré-VM encontrou e corrigiu problemas no teste de CUDA, reaplicação de `.env`, probe de rede, exposição de segredo, rotação de logs e smoke tests. Veja `AUDIT.md`.

## O que testar na Azure

- reconhecimento das 8 GPUs pelo host;
- `torch.cuda` dentro da imagem oficial vLLM;
- carregamento integral do checkpoint FP8;
- autenticação de `/v1/models`;
- chat simples com `reasoning_effort=low`;
- chat com `reasoning_effort=max`;
- tool calling;
- reboot e retomada dos containers;
- requisição progressivamente maior até 262.144 tokens antes de considerar ampliar o contexto.
