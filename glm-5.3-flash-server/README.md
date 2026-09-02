# GLM-5.3-Flash Server — Azure

Servidor mínimo para hospedar o **GLM-5.3-Flash** e expor uma **API compatível com OpenAI**. Este projeto não inclui agentes nem orquestração.

## Perfil recomendado

- Azure: `Standard_ND96isr_H200_v5`
- GPU: 8× NVIDIA H200 141 GB
- Imagem: **Ubuntu HPC 24.04** da Microsoft/Azure
- Armazenamento persistente: pelo menos 420 GiB livres; 1 TiB é uma escolha confortável
- Runtime: Docker + vLLM
- Modelo: `zai-org/GLM-5.3-Flash` FP8
- Contexto inicial: 262.144 tokens (conservador para a primeira implantação)

A configuração padrão acompanha a receita oficial atual do vLLM para o GLM-5.3-Flash: H200, tensor parallel 8 e a imagem `vllm/vllm-openai:glm53-flash`.

## Instalação

```bash
git clone https://github.com/mycroft440/toolkit-I.A.git
cd toolkit-I.A/glm-5.3-flash-server
chmod +x install.sh manage.sh healthcheck.sh test-api.sh scripts/*.sh
sudo ./install.sh
```

O instalador:

1. confirma Ubuntu e driver NVIDIA;
2. reutiliza Docker/Moby existente quando já funcional, evitando substituir desnecessariamente o stack da imagem Azure HPC;
3. instala Docker/Compose somente se necessário, com fallback verificado por SHA-256 para o Compose;
4. instala/configura NVIDIA Container Toolkit;
5. gera uma API key aleatória em `.env`;
6. valida GPUs, VRAM, disco, vLLM e FlashInfer;
7. persiste pesos do Hugging Face e cache de compilação do vLLM;
8. sobe vLLM e o gateway Nginx.

O checkpoint é baixado na primeira inicialização. Acompanhe com:

```bash
./manage.sh logs
```

Quando estiver pronto:

```bash
./manage.sh test
```

Para diagnóstico sem revelar segredos:

```bash
./manage.sh diagnose
```

## API

Base URL padrão no host:

```text
http://127.0.0.1:8000/v1
```

Veja a chave:

```bash
./manage.sh key
```

Exemplo com Python/OpenAI:

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

O container vLLM não publica sua porta diretamente no host. O Nginx só encaminha `/v1/`, e o bind padrão é `127.0.0.1`.

URLs remotas de imagens/vídeos/áudio também ficam **bloqueadas por padrão** por `ALLOWED_MEDIA_DOMAIN=media.invalid`, e redirects remotos ficam desligados. Se seus agentes precisarem enviar mídia por URL, troque esse valor por **um domínio explicitamente confiável**. Não use um domínio amplo sem necessidade.

Para agentes remotos, prefira VNet/IP privado, VPN ou allowlist no NSG. Se a API atravessar internet pública, use TLS. Veja `SECURITY.md`.

## Agentes e tool calling

Para os agentes que você criará separadamente, leia `AGENT_COMPAT.md`. Enquanto um fix upstream ainda não estiver incorporado à imagem validada, histories com `assistant.content=null` + `tool_calls` devem ser normalizados para `content=""` antes de serem reenviados ao servidor. Use `reasoning_effort`/`clear_thinking`; não reutilize flags antigas como `enable_thinking=false`.

## Armazenamento e Azure Spot

Pesos do modelo:

```text
/var/lib/glm53/huggingface
```

Cache persistente do vLLM/torch.compile:

```text
/var/lib/glm53/vllm-cache
```

O cache de compilação evita recompilar artefatos do vLLM toda vez que o container é recriado, desde que a versão/arquitetura ainda sejam compatíveis.

Para mover os caches para um disco persistente:

```bash
HF_CACHE_DIR=/mnt/model-cache/huggingface
VLLM_CACHE_DIR=/mnt/model-cache/vllm
```

## Operação

```bash
./manage.sh status
./manage.sh logs
./manage.sh wait
./manage.sh test
./manage.sh diagnose
./manage.sh restart
./manage.sh update
```

`restart`/`apply` recriam os containers, portanto mudanças em `.env`, portas e argumentos são realmente aplicadas.

## Configuração

Principais valores em `.env`:

- `MODEL_ID`: checkpoint Hugging Face.
- `SERVED_MODEL_NAME`: nome usado pelos clientes OpenAI.
- `VLLM_IMAGE`: imagem do vLLM; não troque para `latest` sem validar o GLM-5.3-Flash.
- `TENSOR_PARALLEL_SIZE`: 8 no perfil H200.
- `MAX_MODEL_LEN`: 262144 por padrão.
- `API_PORT`: porta do gateway.
- `BIND_ADDRESS`: `127.0.0.1` por padrão.
- `HF_CACHE_DIR`: cache/pesos do Hugging Face.
- `VLLM_CACHE_DIR`: cache persistente de compilação do vLLM.
- `API_KEY`: segredo de autenticação.
- `HF_TOKEN`: opcional para Hugging Face.
- `ALLOWED_MEDIA_DOMAIN`: domínio remoto permitido para mídia; o padrão inválido bloqueia URLs remotas.
- `VLLM_MEDIA_URL_ALLOW_REDIRECTS`: `0` por padrão.

## Reprodutibilidade

GLM-5.3-Flash e sua imagem de integração ainda estão recebendo atualizações rápidas. Antes do **primeiro teste real bem-sucedido** seguimos o tag oficial para receber correções upstream. Depois desse teste, o plano é registrar e congelar:

1. digest exato da imagem vLLM;
2. revisão exata do checkpoint;
3. versões vLLM/FlashInfer/driver usadas.

`./manage.sh diagnose` já mostra o digest e versões de runtime necessárias para esse congelamento.

## Limites desta primeira versão

A configuração inicial privilegia previsibilidade: 262.144 tokens de contexto e sem MTP/DBO/FP8-KV forçado em Hopper. Depois do teste real, otimizações devem ser ativadas uma por uma.

## Referências upstream

- Modelo oficial: https://huggingface.co/zai-org/GLM-5.3-Flash
- Receita vLLM: https://recipes.vllm.ai/zai-org/GLM-5.3-Flash
- Docker vLLM: https://docs.vllm.ai/en/latest/deployment/docker/
- Segurança vLLM: https://docs.vllm.ai/en/latest/usage/security/
- NVIDIA Container Toolkit: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html
- Azure Ubuntu HPC: https://learn.microsoft.com/azure/virtual-machines/azure-hpc-vm-images
- Azure ND-H200-v5: https://learn.microsoft.com/azure/virtual-machines/sizes/gpu-accelerated/nd-h200-v5-series
