# Colmeia 0.3.0 — Public beta

## Resumo

O Colmeia 0.3.0 é um beta público local-first para organizar trabalho humano
e agentes de IA em um canvas visual. O Engine mantém PTYs e arquivos locais;
o Hub compartilha apenas o estado autorizado da Sala.

## Destaques

- Canvas semântico com Missões, agentes, notas, decisões, entregas e presença.
- Salas do Hub com convites, papéis e sincronização de layout dos objetos.
- Replay offline durável com request IDs estáveis e idempotência no Hub.
- Transporte WebSocket local e listener WSS com falha fechada sem TLS.
- Persistência e recuperação de workspaces, sessões, journals e outbox.
- Controles de aprovação humana, grants e execução de worker com escopo restrito.
- CLI `colmeia` para contexto, notas, status, missões e entregas.

## Segurança e privacidade

- PTYs, shell, cookies, credenciais e paths privados não são enviados ao Hub.
- WSS remoto exige identidade TLS configurada; não há fallback silencioso para
  transporte inseguro.
- O Hub valida identidade, convite, sala e papel antes de mutações e eventos.
- Tokens, certificados e dados de workspace devem ser fornecidos fora do
  repositório.

## Validação

- Suíte completa: **203 testes em 43 suites**.
- Smoke test WebSocket, layout persistente, replay idempotente e WSS fail-closed.
- Artefato macOS de release gerado em `dist/Colmeia.app`.

## Escopo conhecido

- O data-plane completo de workspace ainda não foi migrado para CRDT; a
  colaboração atual é compatível com o modelo local-first e sincroniza estado
  semântico autorizado.
- Assinatura Apple de distribuição e notarização dependem das credenciais da
  equipe que publica o aplicativo.
- Para colaboração remota, o operador precisa configurar certificado PKCS#12,
  token, reverse proxy e backup conforme `docs/HUB_DEPLOYMENT.md`.

## Instalação para beta

1. Obtenha o `.app` assinado/notarizado pelo distribuidor.
2. Abra o Colmeia em macOS 15 ou posterior.
3. Para Hub remoto, configure WSS antes de convidar outra identidade.
4. Use um workspace descartável durante a primeira demo.
