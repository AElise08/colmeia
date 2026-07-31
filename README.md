# Colmeia

<p align="center">
  <img src="docs/colmeia-banner.svg" alt="Colmeia - a visual workspace for people and AI agents" width="100%">
</p>

<p align="center">
  <strong>Um espaço visual para pessoas e agentes de IA trabalharem juntos.</strong><br>
  <strong>A visual workspace where people and AI agents can work together.</strong>
</p>

<p align="center">
  <a href="#portugues">Português</a> | <a href="#english">English</a> | <a href="docs/SPEC.md">Specification</a> | <a href="LICENSE">MIT License</a>
</p>

> Status: alpha. Colmeia is usable for local experimentation, but its protocol,
> storage layout, and collaboration UX may still change.

---

<a id="portugues"></a>
## Português

### O que é

Colmeia é um canvas local-first para coordenar trabalho técnico entre humanos e
agentes de IA. Em vez de espalhar contexto entre janelas, terminais, anotações e
chats, você organiza a execução em um espaço visual compartilhado.

Cada workspace pode reunir terminais, agentes, notas, conexões, portais web,
missões, decisões, entregas e presença colaborativa. O Engine local mantém o
controle dos PTYs e dos arquivos; o Hub opcional replica somente o contexto que
pode ser compartilhado com segurança.

### Para quem é

- Desenvolvedores trabalhando com Claude Code, Codex, OpenCode, Gemini CLI ou shell.
- Pessoas que coordenam várias tarefas ou agentes em paralelo.
- Pequenas equipes que querem visualizar responsabilidade, contexto e entregas.

### O que já funciona

- Canvas nativo macOS e canvas no navegador.
- Terminais reais, replay de sessão e journals persistentes.
- Notas Markdown, checklists, cadeias de notas e anexos de imagem.
- Comunicação entre agentes com `ask`, `list` e `check`.
- Papel **Rainha** para coordenar conexões e terminais no workspace.
- Portais automatizáveis: navegar, avaliar JavaScript, clicar, preencher,
  enviar teclas, screenshot e PDF.
- Salas, convites, presença, missões, decisões, entregas e memória de workspace.
- Hub opcional para colaboração remota, sem expor PTY ou paths locais.

### Começar localmente

Requisitos: macOS 15+, Swift 6 e Command Line Tools. Chrome ou Chromium é
necessário apenas para automação de portais.

```bash
git clone https://github.com/AElise08/colmeia.git
cd colmeia

# Tudo em modo debug
swift build

# Testes desta máquina
./test.sh

# App macOS empacotado
./scripts/build-app.sh
open dist/Colmeia.app
```

`./test.sh` é o comando de teste suportado neste ambiente. O `swift test` puro
não encontra o framework `Testing` no Command Line Tools instalado.

### Linha de comando

Dentro de um terminal gerenciado, a CLI recebe o contexto do workspace
automaticamente.

```bash
# Descobrir o workspace e os agentes
colmeia list
colmeia status --json

# Ler output de outro agente
colmeia check "nome-do-agente" --stream

# Trabalhar com contexto persistente
colmeia note "Decisão: usar o contrato v2"
colmeia note connected
colmeia note chain <node-id>

# Criar e automatizar um portal
colmeia portal open https://example.com --nome exemplo
colmeia portal command <portal-id> eval "document.title"

# Coordenar como Rainha
colmeia connect <node-a> <node-b>
```

Use `colmeia --help` para a referência completa dos comandos.

### Arquitetura

```text
macOS app / CLI                    Browser
      |                               |
      +----- NDJSON / WebSocket ------+
                      |
                Colmeia Engine
          PTYs, journals, document, notes
                      |
                 optional sync
                      |
                 Colmeia Hub
    rooms, invites, presence, snapshots, events
```

O Engine é local e confiável pela pessoa operadora. Ele não deve ser exposto
diretamente à internet. O Hub é uma camada de coordenação: para uso externo,
coloque-o atrás de TLS, autenticação, rate limiting e backups.

### Desenvolvimento

```bash
# Todos os produtos
swift build

# Testes determinísticos
./test.sh

# Smoke test de Chrome para portais automatizados
COLMEIA_BROWSER_TESTS=1 ./test.sh --filter AgentCapabilitiesTests

# Checagem de performance sem GUI
./scripts/benchmark.sh
```

Leia [`docs/SPEC.md`](docs/SPEC.md) para o contrato de segurança, arquitetura e
protocolo. O repositório tem scripts de deploy, mas credenciais e infraestrutura
de produção devem ficar fora do Git.

### Licença e marca

O código é distribuído sob a licença [MIT](LICENSE). O nome, o logotipo e a
identidade visual Colmeia são tratados separadamente pela política em
[`TRADEMARKS.md`](TRADEMARKS.md), que evita que outra distribuição se apresente
como a versão oficial do projeto.

---

<a id="english"></a>
## English

### What is Colmeia?

Colmeia is a local-first visual workspace for people and AI agents. Think of it
as a **Figma for AI agents**: your project is a spatial canvas, while agents can
research, write, review, operate tools, and prepare work for that canvas.

Instead of losing context between terminals, chat threads, browser tabs, and
notes, Colmeia keeps the work connected. You can move between the canvas and an
agent coordination room, see which agent is primary, switch models without
discarding the conversation, and return to the project when the work is ready.

### Why it is useful

- **One project context.** Terminals, Markdown notes, agents, portals,
  connections, missions, decisions, and deliveries live together.
- **Clear agent roles.** A workspace has a persistent primary agent. Delegated
  workers can be reused, parked, and resumed without creating duplicate
  identities or losing their history.
- **Readable conversations.** Agent Chat shows human messages, real assistant
  replies, tool activity, delegations, approvals, and status cards. Raw ANSI
  redraws and terminal menus stay in the terminal view instead of polluting the
  transcript.
- **Human control.** Approvals and deliveries can be reviewed in the chat. A
  primary agent waits for delegated work to finish before continuing.
- **Local-first by default.** The Engine owns local PTYs and private workspace
  data. Remote collaboration is optional and goes through the Hub's rooms,
  invitations, presence, and sanitized shared state.

The local Engine owns PTYs, journals, and private workspace data. The optional
Hub coordinates rooms, invites, presence, and sanitized shared state without
turning a remote service into shell access.

### Highlights

- Native macOS canvas and browser canvas.
- Real terminal sessions with replayable journals and isolated agent homes.
- Agent Chat with model selection, keyboard-friendly messaging, attachments,
  approvals, semantic events, and readable responses.
- Delegation records with explicit `queued`, `running`, `waitingApproval`,
  `completed`, `failed`, and `canceled` states.
- Browser portals with navigation, JavaScript evaluation, click, fill, key,
  screenshot, and PDF automation.
- Collaborative rooms, invitations, presence, missions, decisions, deliveries,
  memory, and workspace-scoped context.

### Quick Start

```bash
git clone https://github.com/AElise08/colmeia.git
cd colmeia
swift build
./test.sh
./scripts/build-app.sh
open dist/Colmeia.app
```

Use `colmeia --help` for the complete CLI reference. Read [`docs/SPEC.md`](docs/SPEC.md)
for the protocol and security model.

### Agent workflow

1. Open a workspace and choose its primary agent.
2. Send a message from Agent Chat or open a terminal on the canvas.
3. Delegate a focused task to a compatible worker when needed.
4. Review tool activity and resolve approvals in the conversation.
5. The primary agent resumes only after the delegated work reports an explicit
   completion or failure.
6. Return to the canvas to inspect notes, files, connections, and deliveries.

### Security Model

Keep the Engine private. It can run terminals and access local workspace state.
When running a Hub for other people, use HTTPS/WSS, authentication, a dedicated
service user, rate limits, backups, and a reverse proxy. Never commit tokens,
SSH keys, certificates, `.env` files, or production workspace data.

### License And Name

Colmeia is released under the [MIT License](LICENSE). The project name, logo, and
visual identity are covered separately by [`TRADEMARKS.md`](TRADEMARKS.md), which
prevents misrepresentation as the official Colmeia project.

---

## Contributing

Issues and pull requests are welcome. Before sending a change, run `./test.sh`
and avoid including generated files, credentials, local workspace data, or
production infrastructure details.
