# Colmeia Control Plane — checklist de implementação

Status: primeiro corte vertical implementado em 2026-08-05.

## Fundação de telemetria

- [x] Modelos tipados UsageSample, FileActivityEvent, ConnectionActivityEvent, PortalActivityEvent e TelemetrySnapshot.
- [x] Fontes explícitas: exact, derived, estimated e unavailable.
- [x] Contadores ausentes permanecem ausentes; não viram zero.
- [x] TelemetryStore local em JSONL, com leitura tolerante a linha corrompida.
- [x] Idempotência por ID para retries.
- [x] Tabela de preços versionada e configurável em telemetry-pricing.json.
- [x] Orçamento por workspace, percentuais e alertas de 50%, 80% e 100%.
- [x] Métodos telemetry.*, file.activity.query e portal.activity.query.
- [x] Tópicos telemetry.*, connection.activity, file.activity e portal.activity.
- [x] Hook estruturado opcional no AgentAdapter; regex do terminal não é usada.
- [x] Sessões sem hook oficial são registradas como unavailable ao encerrar.

## Visão Execução e topologia

- [x] HUD compacto no modo execucao.
- [x] Tokens, custo, burn/min, amostras, fonte e orçamento no HUD.
- [x] Agentes ordenados pelo custo conhecido.
- [x] Conexões estáticas por padrão.
- [x] Pulso por mensagem entregue, persistido como evento auditável.
- [x] Cor semântica para mensagem, delegação, contexto, entrega, aprovação e erro.
- [x] Animação global limitada à camada de conexões e respeita reduce motion/pan/zoom.

## Próximos cortes

- [~] Extrair o frontend web embutido em HubServer.swift para recursos construíveis separadamente. O componente de telemetria já está em `Sources/ColmeiaHub/Resources/control-plane.js`; o canvas legado ainda permanece como fallback.
- [~] Instrumentar hooks oficiais de Claude, Codex e OpenCode quando os CLIs disponibilizarem os dados. O contrato `file.activity.record` e o hook tipado já estão disponíveis; nenhum número é inferido de terminal.
- [x] Emitir eventos de arquivo a partir de tool calls estruturados e confirmação Git. `file.activity.record` aceita hooks explícitos e `file.activity.scan` consulta Git diretamente, sempre com paths relativos.
- [x] Emitir eventos CDP de portal com duração, seletor, URL sanitizada, status e correlação local de screenshot.
- [x] Exibir cartões de entrega/evidências diretamente no canvas; diff continua abrindo pela evidência existente.
- [~] Implementar `deploy.request`/`deploy.confirm` com CapabilityGrant. A confirmação gera estado `approved` e trilha de auditoria; o runner ainda é responsável por executar.
- [ ] Adicionar heatmap de arquivos e timeline.
- [x] Adicionar grade hexagonal decorativa com feature flag `colmeia.visual.hexGrid`.

## Verificação

- swift build passou.
- ./test.sh passou: 206 testes em 44 suites.
- Engine temporário subiu e respondeu ao CLI pelo socket; os dados pessoais não foram alterados.
