# GLM-5.3-Flash Server — Azure

Servidor mínimo para hospedar o **GLM-5.3-Flash** e expor uma **API compatível com OpenAI**. Este projeto não inclui agentes nem orquestração.

## Perfil recomendado

- Azure: `Standard_ND96isr_H200_v5`
- GPU: 8× NVIDIA H200 141 GB
- Imagem: **Ubuntu HPC 24.04** da Microsoft/Azure (`microsoft-dsvm:ubuntu-hpc:2404:latest`)
- Armazenamento persistente: pelo menos 420 GiB livres; 1 TiB é uma escolha confortável
- Runtime: Docker + vLLM
- Modelo: `zai-org/GLM-5.3-Flash` FP8
- Contexto inicial: 262.144 tokens (conservador para a primeira implantação)

A configuração padrão acompanha a receita oficial atual do vLLM para o GLM-5.3-Flash: H200, tensor parallel 8 e a imagem `vllm/vllm-openai:glm53-flash`.

Na revisão de 2 de setembro de 2026, a versão mais recente publicada da imagem Ubuntu HPC 24.04 A100+ é `24.04.2026072901`, com driver NVIDIA 580.173.02, CUDA 13.0.88, NCCL 2.30.4 e Docker/Moby 29.6.2. Você pode usar `latest`; o instalador valida o runtime real antes de iniciar o modelo.

## Instalação

```bash
git clone https://github.com/mycroft440/toolkit-I.A.git
cd toolkit-I.A/glm-5.3-flash-server
chmod +x install.sh manage.sh healthcheck.sh test-api.sh scripts/*.sh
sudo ./install.sh
```

O instalador:

1. confirma Ubuntu e driver NVIDIA;
2. reutiliza o Docker existente da imagem HPC ou instala Docker/Compose se necessário;
3. instala/configura NVIDIA Container Toolkit quando necessário;
4. gera uma API key aleatória em `.env`;
5. valida GPUs, VRAM e espaço em disco;
6. baixa as imagens Docker;
7. valida CUDA/PyTorch dentro da **mesma imagem vLLM que será usada em produção**;
8. inicia vLLM e o gateway Nginx.

A API key não é impressa automaticamente. Para vê-la quando necessário:

```bash
./manage.sh key
```

O checkpoint é baixado na primeira inicialização. Acompanhe com:

```bash
./manage.sh logs
```

Quando estiver pronto:

```bash
./manage.sh wait
./manage.sh test
```

## API

Base URL padrão no host:

```text
http://127.0.0.1:8000/v1
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

O vLLM tem endpoints que não são protegidos apenas por `--api-key`. Por isso o container vLLM **não publica porta diretamente no host**. O Nginx é o único serviço exposto e encaminha somente `/v1/`; outros caminhos, incluindo `/invocations`, recebem 404.

Por padrão, `BIND_ADDRESS=127.0.0.1`, portanto a API não fica pública. Para agentes remotos, use uma rede privada/VNet/VPN ou altere para `0.0.0.0` somente depois de limitar a porta 8000 no Azure NSG aos IPs confiáveis. Se atravessar internet pública, coloque TLS na frente da API. Não faça commit do arquivo `.env`. Veja `SECURITY.md`.

## Armazenamento e Azure Spot

O modelo FP8 tem aproximadamente 306 GiB só em pesos. O cache padrão é:

```text
/var/lib/glm53/huggingface
```

O preflight exige pelo menos 420 GiB livres nesse filesystem antes da instalação. Em uma VM criada com disco do sistema pequeno, anexe/mapeie um disco persistente ou aumente o disco antes de executar `install.sh`.

Para usar outro disco, edite `.env` antes de subir o serviço:

```bash
HF_CACHE_DIR=/mnt/model-cache/huggingface
```

Em Azure Spot, armazenamento persistente evita baixar novamente ~306 GiB se a VM precisar ser substituída.

## Operação

```bash
./manage.sh status
./manage.sh logs
./manage.sh wait
./manage.sh test
./manage.sh restart
./manage.sh update
```

`restart`/`apply` recria os containers para reaplicar mudanças do `.env`; isso é intencional e recarrega o modelo.

## Configuração

- `MODEL_ID`: checkpoint Hugging Face.
- `SERVED_MODEL_NAME`: nome usado pelos clientes OpenAI.
- `TENSOR_PARALLEL_SIZE`: 8 no perfil H200 oficial.
- `MAX_MODEL_LEN`: 262144 por padrão; aumente somente após validar estabilidade no seu workload.
- `API_PORT`: porta do gateway.
- `BIND_ADDRESS`: `127.0.0.1` por padrão; não use `0.0.0.0` sem proteção de rede/TLS.
- `HF_CACHE_DIR`: local persistente do cache/pesos.
- `API_KEY`: segredo de autenticação.
- `HF_TOKEN`: opcional para Hugging Face.

## Limites desta primeira versão

Este primeiro perfil é propositalmente conservador: ele mira o hardware oficialmente documentado, limita o contexto inicial a 262.144 tokens e não ativa MTP/DBO/FP8-KV em Hopper. Depois do teste real, essas otimizações podem ser avaliadas uma por uma. Perfis menores/mais baratos com H100 e quantização exigem validação separada.

Leia `AUDIT.md` para a revisão técnica mais recente.

## Referências upstream

- Modelo oficial: https://huggingface.co/zai-org/GLM-5.3-Flash
- Receita vLLM: https://recipes.vllm.ai/zai-org/GLM-5.3-Flash
- Segurança vLLM: https://docs.vllm.ai/en/latest/usage/security/
- Azure Ubuntu HPC: https://learn.microsoft.com/azure/virtual-machines/azure-hpc-vm-images
- Azure ND-H200-v5: https://learn.microsoft.com/azure/virtual-machines/sizes/gpu-accelerated/nd-h200-v5-series
