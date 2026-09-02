# Plano de implantação — GLM-5.3-Flash na Azure

## Objetivo

Entregar somente o servidor de inferência do `zai-org/GLM-5.3-Flash`, acessível por API compatível com OpenAI. Agentes, orquestração, memória e ferramentas ficam fora deste projeto.

## Decisões técnicas

- Runtime: vLLM via Docker, usando a imagem especial do GLM-5.3-Flash.
- Hardware de referência: Azure `Standard_ND96isr_H200_v5`, 8× H200 141 GB, TP=8.
- VM: Azure Ubuntu HPC 24.04.
- API: `/v1`, protegida por API key e Nginx; bind local por padrão.
- Perfil inicial: 262.144 tokens; sem MTP, DBO, KV offload ou FP8-KV forçado em Hopper.
- Persistência: pesos + cache de compilação. Se Docker e os dois caches dividirem filesystem, mínimo agregado padrão de 520 GiB livres; 1 TiB persistente recomendado.
- Reprodutibilidade: `MODEL_REVISION=main` antes do primeiro teste; commit exato + digest da imagem depois da validação H200.
- Atualizações: `start/restart/apply` sem pull; `update` deliberado com validação, smoke test e tentativa de rollback.

## Fases

- [x] 1. Pesquisa e escolha de runtime/hardware.
- [x] 2. Arquitetura mínima e superfície OpenAI.
- [x] 3. Preflight de GPU, VRAM, parâmetros, Docker e espaço agregado.
- [x] 4. Instalador idempotente para Ubuntu HPC.
- [x] 5. Compose vLLM + gateway restritivo.
- [x] 6. Health, chat, tool calling e comandos operacionais.
- [x] 7. Segurança: bind local, gateway, SSRF/media allowlist, logs limitados.
- [x] 8. Persistência de pesos e cache vLLM.
- [x] 9. `glm-info` global + diagnóstico sem segredos.
- [x] 10. CI: Bash, ShellCheck, Compose, Nginx e regressão do symlink global.
- [x] 11. Fluxo de update validado antes/depois com rollback da imagem vLLM.
- [x] 12. Suporte a `MODEL_REVISION` para pinagem futura.
- [ ] 13. Teste real em Azure 8× H200: carregar FP8 e executar smoke test completo.
- [ ] 14. Reboot/Spot e reaproveitamento de caches.
- [ ] 15. Congelar digest, commit do checkpoint e versões após o primeiro teste bem-sucedido.

## Critérios de pronto na VM real

1. `nvidia-smi` vê as 8 H200.
2. A imagem vLLM vê 8 GPUs e FlashInfer compatível.
3. O checkpoint configurado em `MODEL_REVISION` carrega integralmente.
4. `/v1/models` exige chave e responde autenticado.
5. `/v1/chat/completions` gera conteúdo válido.
6. Tool calling nomeado retorna `tool_calls` + arguments JSON válido.
7. `/invocations` recebe 404 no gateway.
8. `glm-info` funciona de qualquer pasta.
9. `restart/apply` não troca imagem silenciosamente.
10. `update` aceita uma versão somente após health + smoke test.
11. Reboot retorna os containers e preserva os caches.
12. Digest/revisão final ficam registrados para reprodução.
