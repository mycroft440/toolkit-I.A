# GLM-5.3-Flash Server — Azure

Servidor mínimo para hospedar o **GLM-5.3-Flash** e expor uma **API compatível com OpenAI**. Este projeto não inclui agentes nem orquestração.

## Perfil recomendado

- Azure: `Standard_ND96isr_H200_v5`
- GPU: 8× NVIDIA H200 141 GB
- Imagem: **Ubuntu HPC 24.04** da Microsoft/Azure
- Runtime: Docker + vLLM
- Modelo: `zai-org/GLM-5.3-Flash` FP8
- Contexto inicial: 262.144 tokens
- Armazenamento: se pesos, Docker e cache vLLM estiverem no mesmo filesystem, o preflight exige por padrão **520 GiB livres**; **1 TiB persistente** é a escolha recomendada.

A configuração acompanha a receita atual do vLLM para H200: tensor parallel 8, imagem `vllm/vllm-openai:glm53-flash`, parser de tools `glm47` e parser de reasoning `glm45`. Hopper usa KV em BF16 neste perfil; não forçamos FP8 KV.

## Instalação

```bash
git clone https://github.com/mycroft440/toolkit-I.A.git
cd toolkit-I.A/glm-5.3-flash-server
sudo ./install.sh
```

O instalador confirma Ubuntu/driver, reutiliza Docker/Moby existente quando possível, instala Compose/NVIDIA Container Toolkit se necessário, gera a API key, valida GPUs/VRAM/discos, valida CUDA/vLLM/FlashInfer com a própria imagem de inferência e sobe vLLM + Nginx.

Reexecutar `install.sh` não atualiza silenciosamente uma imagem vLLM já instalada: imagens existentes são preservadas. Atualizações deliberadas devem usar `./manage.sh update`.

A primeira inicialização baixa o checkpoint. Acompanhe com:

```bash
./manage.sh logs
./manage.sh wait
./manage.sh test
```

O smoke test valida autenticação, bloqueio de `/invocations`, `/v1/models`, chat e **tool calling** no formato OpenAI.

## Informações da API

Depois da instalação, de qualquer pasta:

```bash
glm-info
```

Dentro do projeto também funcionam:

```bash
./info
./manage.sh info
```

O painel mostra status, modelo, revisão configurada, URL, bind, porta, API key, contexto, GPUs, caches e comandos úteis. Ele exibe a API key deliberadamente; não compartilhe capturas ou a saída desse comando.

Base URL local padrão:

```text
http://127.0.0.1:8000/v1
```

Exemplo Python:

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://127.0.0.1:8000/v1",
    api_key="SUA_CHAVE",
)

response = client.chat.completions.create(
    model="glm-5.3-flash",
    messages=[{"role": "user", "content": "Olá"}],
    extra_body={
        "reasoning_effort": "max",
        "chat_template_kwargs": {"clear_thinking": True},
    },
)
print(response.choices[0].message.content)
```

## Segurança

O vLLM não publica porta diretamente no host. O Nginx encaminha somente `/v1/`; outros caminhos recebem 404. O bind padrão é `127.0.0.1`.

URLs remotas de mídia ficam bloqueadas por padrão (`ALLOWED_MEDIA_DOMAIN=media.invalid`) e redirects ficam desligados. Para agentes remotos, prefira VNet/IP privado ou VPN; se usar NSG, restrinja TCP/8000 aos IPs confiáveis. Internet pública requer TLS/HTTPS + API key. Veja `SECURITY.md`.

## Agentes e tool calling

Leia `AGENT_COMPAT.md`. O problema `assistant.content=null` + `tool_calls` foi reportado no upstream; a issue foi encerrada, mas a PR de correção protocolar `#54368` continua aberta/não incorporada no momento desta revisão. Até confirmar a imagem efetivamente instalada, normalize esse conteúdo para string vazia no cliente.

Para GLM-5.3 use `reasoning_effort` (`low`, `high`, `max`) e `clear_thinking`. Evite flags antigas `enable_thinking`/`thinking=false`, pois existe issue upstream aberta em que elas podem fazer o reasoning aparecer no campo `content`.

## Armazenamento e Azure Spot

Defaults:

```text
HF_CACHE_DIR=/var/lib/glm53/huggingface
VLLM_CACHE_DIR=/var/lib/glm53/vllm-cache
```

O preflight reserva logicamente, por padrão:

- 420 GiB livres para pesos/cache Hugging Face;
- 80 GiB livres para Docker;
- 20 GiB livres para cache vLLM/compilação.

Se esses caminhos estiverem no mesmo filesystem, os requisitos são somados: **520 GiB livres**. Como há crescimento de cache, logs e futuras versões, recomendamos um disco persistente de **1 TiB**. Para Spot, não dependa apenas de armazenamento temporário da VM se quiser evitar novo download do modelo após substituição da máquina.

Para usar um disco persistente montado:

```bash
HF_CACHE_DIR=/mnt/model-cache/huggingface
VLLM_CACHE_DIR=/mnt/model-cache/vllm
```

## Operação segura

```bash
glm-info
./manage.sh status
./manage.sh logs
./manage.sh wait
./manage.sh test
./manage.sh diagnose
./manage.sh restart
./manage.sh update
```

`start`, `restart` e `apply` usam `--pull never`: eles não trocam a imagem validada por acidente. `update` é o caminho deliberado de atualização: valida a configuração e o espaço **antes** do download, baixa apenas o serviço vLLM, verifica CUDA/vLLM/FlashInfer antes de recriar, espera a API, roda o smoke test completo e tenta restaurar a imagem anterior se health/tool calling falharem.

Se `VLLM_IMAGE` estiver fixada por digest (`@sha256:`), `update` não troca esse pin automaticamente.

## Reprodutibilidade

O modelo e a imagem ainda recebem atualizações. O `.env` inclui:

```bash
MODEL_REVISION=main
```

vLLM recebe esse valor em `--revision` e `--tokenizer-revision`. Antes do primeiro teste real usamos `main` para acompanhar correções necessárias. Depois do primeiro carregamento H200 + smoke test bem-sucedido, registre e congele:

1. digest exato da imagem vLLM;
2. commit/revisão exata do checkpoint em `MODEL_REVISION`;
3. versões vLLM, FlashInfer e driver NVIDIA.

`./manage.sh diagnose` mostra o digest e as versões do runtime; `glm-info` mostra a revisão configurada.

## Configuração principal

- `MODEL_ID`: checkpoint Hugging Face.
- `MODEL_REVISION`: branch/tag/commit do modelo e tokenizer; `main` inicialmente.
- `SERVED_MODEL_NAME`: nome para clientes OpenAI.
- `VLLM_IMAGE`: imagem vLLM.
- `TENSOR_PARALLEL_SIZE`: 8 no perfil H200.
- `MAX_MODEL_LEN`: 262144 inicialmente.
- `API_PORT`: porta do gateway.
- `BIND_ADDRESS`: `127.0.0.1` por padrão.
- `HF_CACHE_DIR` / `VLLM_CACHE_DIR`: caches persistentes.
- `API_KEY`: segredo de autenticação.
- `HF_TOKEN`: opcional.
- `ALLOWED_MEDIA_DOMAIN`: domínio permitido para mídia remota; default inválido bloqueia URLs.
- `VLLM_MEDIA_URL_ALLOW_REDIRECTS`: `0` por padrão.

## Limite de validação atual

Bash, ShellCheck, Compose, Nginx e o comportamento do symlink global `glm-info` são validados no GitHub Actions. A validação decisiva que não pode ser simulada sem o hardware é carregar o checkpoint FP8 e executar chat/tool calling em uma Azure `Standard_ND96isr_H200_v5` real.

## Referências

- https://recipes.vllm.ai/zai-org/GLM-5.3-Flash
- https://docs.vllm.ai/en/latest/cli/serve/
- https://docs.vllm.ai/en/latest/usage/security/
- https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html
- https://learn.microsoft.com/azure/virtual-machines/azure-hpc-vm-images
- https://learn.microsoft.com/azure/virtual-machines/sizes/gpu-accelerated/nd-h200-v5-series
