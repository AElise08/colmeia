# Colmeia

Canvas de agentes para macOS: um quadro espacial onde nós-terminais (shell, claude-code,
codex, gemini-cli, opencode), notas e desenhos convivem em workspaces. Um daemon
(`colmeia-engine`) é o dono de PTYs, journals e do documento; a UI (SwiftUI + SwiftTerm)
e a CLI (`colmeia`) são clientes do mesmo protocolo NDJSON sobre socket unix.
Especificação completa em `~/colmeia-spec.md` (RFC 2119).

## Como buildar

Máquina de referência: MacBook M4, macOS 26, Swift 6.2.4 via CommandLineTools —
**não existe xcodebuild**; tudo é Swift Package Manager puro.

```sh
swift build              # debug (todos os targets)
swift build -c release   # release
./test.sh                # testes — NÃO use `swift test` puro (ver abaixo)
scripts/build-app.sh     # monta dist/Colmeia.app a partir do build release
```

`swift test` puro não executa nesta máquina: o `_Testing_Foundation.framework` do
CommandLineTools vem sem a pasta `Modules`, quebrando o cross-import overlay de
`import Testing`. O `./test.sh` contorna com `-F` + `-disable-cross-import-overlays` +
rpath. Esses flags não podem virar `unsafeFlags` no `Package.swift`: o SwiftPM compila
mas silenciosamente deixa de executar o produto de teste.

## Como rodar

**App empacotado** (engine embutido — a UI lança o engine que está ao lado do executável):

```sh
scripts/build-app.sh
open dist/Colmeia.app
```

**Engine + CLI standalone** (sem UI):

```sh
.build/arm64-apple-macosx/release/colmeia-engine --root ~/algum/root
# O engine cria <root>/colmeia.sock e imprime o caminho.
# Atenção: sun_path de socket unix no macOS ≈ 104 chars — use um root de caminho curto.

# A CLI é pensada para rodar DENTRO de uma sessão (o engine injeta COLMEIA_SOCKET,
# COLMEIA_WORKSPACE_ID e COLMEIA_NODE_ID no PTY), mas aceita os envs manualmente:
COLMEIA_SOCKET=... COLMEIA_WORKSPACE_ID=... COLMEIA_NODE_ID=... colmeia status
colmeia ask <nó> "mensagem" [--timeout N | --no-wait]
colmeia note "linha para a nota do nó"
```

## Estrutura

```
Package.swift            swift-tools-version 6.0; todos os targets em swiftLanguageMode(.v5)
test.sh                  wrapper obrigatório de `swift test` nesta máquina
scripts/build-app.sh     empacota dist/Colmeia.app (App + engine + CLI, Info.plist, ícone, ad-hoc sign)
Sources/
  ColmeiaKit/            compartilhado: domínio (§5), protocolo (§6), ops (§7.2),
                         eventos (§8.2), framing/cliente de socket, paths de storage (§20)
  ColmeiaEngine/         daemon: Server, Engine, PTY, LiveSession, Journal,
                         DocumentStore, Adapters, Floors, Routines
  colmeia-engine/        binário fino do daemon (§3.1)
  colmeia/               CLI companheira (§13): ask / note / status
  ColmeiaApp/            app SwiftUI do canvas (§18); SwiftTerm como emulador (§9.2)
Tests/ColmeiaTests/      suite (ColmeiaKit + ColmeiaEngine); rodar via ./test.sh
dist/                    saída de scripts/build-app.sh (não versionar)
```

## Estado vs spec

O que está implementado e verificado: engine completo (workspaces, doc ops com seq,
sessões PTY com journal contíguo, attach com replay, estados §10, mensageria ask
bloqueante/no-wait, recuperação pós-crash `morta{engine_crash}`), CLI (ask/note/status,
incl. rodando dentro do PTY), app SwiftUI (canvas, terminais, notas, desenhos, replay,
rotinas, aprovações, andares parciais), smoke real de ponta a ponta engine+CLI+cliente
NDJSON. Suíte de testes verde via `./test.sh`.

Lacunas conhecidas (consolidadas; DEVE/PODE conforme a spec):

**Engine — persistência e manutenção**
- §8.3 rotação de scrollback não implementada: journals de output crescem sem limite (meta <50MB/dia não garantida).
- §7.4 compactação do `document.jsonl`: snapshot a cada 500 ops e no close existem; descarte de ops antigas não.
- §20.4 retenção/limpeza de journals encerrados (≥30 dias) não implementada.
- §22.3 disco cheio → modo somente-leitura de novas sessões não implementado (escrita atômica temp+rename sim).
- `config.json` não é lido — limiares hardcoded (ociosa 30s, snapshot 500 ops, fila de mensagens 32, ask timeout 300s, backpressure 5000 writes).
- §3.3 auto-encerramento do engine após ~10 min ocioso (PODE) não implementado.

**Engine — funcionalidades**
- §16 clone APFS para workspace sem git não implementado (retorna `floor_mechanism_unavailable`, permitido — é PODE). `Floor.nos` nunca é populado automaticamente: a spec não define op/param para vincular nó→andar, então `floor.land`/`floor.discard` arquivam só o que estiver em `Floor.nos` (na prática vazio até UI/spec definirem o vínculo).
- Adapters codex/gemini-cli/opencode: launch correto + classify básico (spinner/silêncio); `detect_approval` só no claude-code. Heurísticas do claude-code validadas contra fixture sintética do menu numerado atual, sem hooks Notification/Stop. Título OSC não é parseado (`tituloOSC` sempre nil; BEL é detectado).
- §6.5 backpressure sem coalescência de chunks — cliente que não drena é desconectado com `engine.warning` após 5000 writes pendentes (nada se perde: journal + re-attach).
- §17.4 `pendente_atrasada` para rotina `once` no passado não modelada (`proxima_execucao` fica nil; UI decide).
- Mensageria bloqueante: resposta heurística depende da transição para `esperando_humano`/`ociosa` — com adapter shell isso só vem pelo fallback de 30s de silêncio.

**Contratos definidos-pela-implementação (extensões §0 — renegociáveis)**
- `message.send` bloqueante: campo de extensão `resposta` (string) no result; timeout responde ok `{message_id, timeout: true}` (não é erro dedicado); CLI mapeia ProtocolError com "timeout" no nome → exit 2. Bloqueante = `timeout_seg` presente; `--no-wait` = `timeout_seg: 0`.
- §13.4 idade do estado: campo de extensão `estado_desde` em cada item de `session.list` (fallback da CLI: `encerrada_em`/`iniciada_em`).
- `DocumentSnapshot` (§7.4 não fixa schema): `{workspace_id, seq, nodes, connections, criado_em}`.
- `FloorSwitchResult.nos` ficou `JSONValue` genérico — §6.4 escreve `{floor, nos}` sem definir a forma; decidir quando §16 evoluir.
- Node tipo `portal` reconhecido no enum mas `Node.init(from:)` lança erro — spec marca portal como [v1.5], sem schema na v1.
- `MessageDeliveredTopicPayload.de/para` tipados como ULID (node-ids); §6.5 não fixa tipo.
- Layout §20.1 estendido com `sessions/<id>.meta.json` (Session DTO persistido) — necessário para `session.list`/replay de encerradas e recuperação pós-crash; leitores ignoram (campo extra, §0).
- Exit codes da CLI fora do contrato do ask: erro de uso → 64 (EX_USAGE); protocolo genérico → 1; contexto/conexão → 3; watchdog local de note/status → 3. Corrida estreita no watchdog do ask: engine vivo porém travado pode sair 3 (connectionClosed) em vez de 2; timeouts sinalizados pelo engine sempre saem 2.

**UI (ColmeiaApp)**
- Notificações §19 exigem bundle `.app` (guard por `Bundle.main.bundleIdentifier`); no-op como executável SPM cru — ativas via `dist/Colmeia.app`.
- Andares §18.5 parcial: barra fina + criar/alternar/aterrissar/descartar tipados; falta atenuação dos nós do andar-base, viewport próprio por andar, fluxo de readoção de órfãos (só rotulados no menu).
- Atalhos ⌃A tmux-like (1–9 workspace, Tab, f, n, a, setas de foco espacial) e "Espaço = zoom no nó" do Apêndice B não implementados — só os essenciais.
- Seletor de workspaces não mostra contagem de sessões por estado (§18.5 DEVERIA) — só nome + check do ativo.
- Clique de notificação foca o nó só se ele estiver no workspace aberto; não troca de workspace.
- Rotina auto-desabilitada não gera notificação própria (protocolo não expõe evento dedicado; `routine.list` é re-buscada em `routine.fired`).
- Borracha por interseção (§15.2 PODE) não existe — apagar = "apagar último traço" no menu de contexto ou undo.
- Zoom por `scaleEffect`: cliques dentro do SwiftTerm com zoom ≠ 100% podem ter offset de hit-testing; texto pode borrar em zoom baixo (mitigado: <40% vira cartão semântico).
- Conteúdo de nota lido/escrito direto em `notes/<id>.md` pela UI (protocolo §6.4 não tem método de leitura/escrita para humano; UI age como "editor externo", sancionado por §15.1; edições externas via file-watch).
- Preferência de editor (§18.7): primeiro detectado (VS Code > Zed > Xcode); chave UserDefaults `colmeia.editor-preferido` existe, sem UI de escolha.
- `SocketClient.events` é AsyncStream de consumidor único; reconexão com backoff (§22.5) é responsabilidade do cliente — a UI implementa a dela, o Kit não tem auto-reconnect.

**Testes e desempenho**
- Sem testes automatizados para: floors com repo git real, mensageria A→B com dois PTYs vivos, `approval.resolve` ponta-a-ponta, crash SIGKILL→recuperação (código coberto só pelo smoke manual), `note.append`, `workspace.delete`, target ColmeiaApp inteiro.
- Timeout do ask bloqueante (engine devolve `{message_id, timeout: true}` → CLI exit 2) coberto por inspeção + fake, não exercitado contra o engine real.
- Metas de desempenho §21.1/§25.8 (60fps com 10 terminais etc.) não medidas.
- `JSONValue.number` é Double: seq > 2^53 perderia precisão via JSONValue genérico (irrelevante na prática; structs tipados decodificam UInt64 direto).
- `swift test` puro quebrado nesta máquina (defeito do CLT, ver "Como buildar").
