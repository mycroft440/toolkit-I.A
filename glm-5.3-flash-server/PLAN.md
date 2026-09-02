# Plano de implantação — GLM-5.3-Flash na Azure

## Objetivo

Entregar somente o servidor de inferência do `zai-org/GLM-5.3-Flash`, acessível por API compatível com OpenAI. Agentes, orquestração, memória e ferramentas ficam fora deste projeto.

## Decisões técnicas

- **Runtime:** vLLM oficial, via Docker.
- **Modelo padrão:** `zai-org/GLM-5.3-Flash` FP8 (320B total / 18B ativos).
- **Hardware de referência:** Azure `Standard_ND96isr_H200_v5`, 8× H200 141 GB, TP=8.
- **Imagem da VM:** Azure Ubuntu HPC 24.04, para reduzir instalação manual de driver/CUDA/NCCL/Docker.
- **API:** compatível com OpenAI em `/v1`; bind local por padrão.
- **Segurança:** vLLM usa API key; Nginx publica somente `/v1` e bloqueia endpoints não autenticados como `/invocations`.
- **Persistência:** cache Hugging Face em diretório configurável; recomendado usar armazenamento persistente com >= 420 GiB livres.
- **Recuperação:** containers com `restart: unless-stopped`; Docker habilitado no boot.
- **Perfil conservador inicial:** contexto de 262.144 tokens; sem MTP, DBO ou FP8 KV em Hopper até validação real.

## Fases

- [x] 1. Pesquisa e escolha do runtime/hardware oficial.
- [x] 2. Definir arquitetura mínima e superfície de API.
- [x] 3. Criar pré-validação de GPU, VRAM, disco e Docker.
- [x] 4. Criar instalador idempotente para Ubuntu.
- [x] 5. Criar Docker Compose para vLLM + gateway restritivo.
- [x] 6. Criar health check, teste de inferência e comandos operacionais.
- [x] 7. Criar CI estática para scripts/YAML.
- [x] 8. Auditoria pré-VM contra vLLM, Docker, NVIDIA e Azure; corrigir falhas detectáveis sem hardware.
- [ ] 9. Executar teste real em uma Azure H200 e ajustar qualquer incompatibilidade observada em runtime.
- [ ] 10. Congelar uma versão/tag depois do primeiro teste real bem-sucedido.

## Critérios de pronto

1. `nvidia-smi` enxerga 8 GPUs adequadas.
2. A imagem vLLM consegue inicializar `torch.cuda` e enxergar as 8 GPUs.
3. `docker compose up -d` sobe vLLM e gateway.
4. `/v1/models` rejeita chamada sem chave e responde com chave.
5. `/v1/chat/completions` produz resposta do GLM-5.3-Flash.
6. `/invocations` recebe 404 no gateway.
7. Alterações no `.env` são aplicadas por `./manage.sh restart`.
8. Após reboot, os containers retornam automaticamente.
