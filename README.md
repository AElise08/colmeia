# Colmeia

Canvas de agentes para humanos e máquinas: um quadro espacial onde terminais (shell,
Claude Code, Codex, Gemini CLI, OpenCode), notas, portais web, desenhos e missões
convivem no mesmo workspace. Colaborativo ao vivo, local-first, open-source.

Repositório: <https://github.com/AElise08/colmeia>

Licença: MIT. O código é público; ambientes, tokens, workspaces e infraestrutura
de produção devem permanecer privados.

```text
┌─────────────────────────────────────────────────────┐
│  ┌──────────┐  ┌──────────────────┐  ┌──────────┐  │
│  │  shell    │  │  Claude Code     │  │  Nota     │  │
│  │  $ cargo  │  │  Analisando...   │  │  ┌─☐ done │  │
│  │  $ make   │  │                  │  │  └☐ todo  │  │
│  └──────────┘  └──────────────────┘  └──────────┘  │
│         ╲        ╱                      │           │
│       ┌──────────────┐            ┌────────────     │
│       │  DuckDuckGo   │            │  Missão #4      │
│       │  (portal web) │            │  Implementar…   │
│       └──────────────┘            └────────────     │
│  ┌────┐ ┌────┐ ┌────┐ ┌────┐ ┌────┐ ┌────┐        │
│  │Term│ │Nota│ │Nave│ │Con │ │Bus │ │Del │        │
│  └────┘ └────┘ └────┘ └────┘ └────┘ └────┘        │
└─────────────────────────────────────────────────────┘
```

**Para humanos:** abra no Mac ou no navegador. Crie terminais, escreva notas,
abra portais, colabore com outras pessoas em tempo real.

**Para agentes (IA):** conecte pelo protocolo NDJSON. Crie nós, leia notas,
execute comandos, participe do canvas como um membro da equipe.

---

## Sumário

- [Modos de uso](#modos-de-uso)
  - [Modo A: local (só seu Mac)](#modo-a-local-só-seu-mac)
  - [Modo B: VPS (compartilhado)](#modo-b-vps-compartilhado)
  - [Modo C: só VPS, sem Mac](#modo-c-só-vps-sem-mac)
- [Para humanos: como usar](#para-humanos-como-usar)
- [Para agentes: protocolo](#para-agentes-protocolo)
- [Arquitetura](#arquitetura)
- [Build & desenvolvimento](#build--desenvolvimento)

---

## Modos de uso

### Modo A: local (só seu Mac)

Tudo roda no seu computador. Outras pessoas acessam pela LAN ou VPN.

```
┌── Seu Mac ──────────────────────────────────┐
│  Colmeia.app                                 │
│  ├── Engine (PTYs, journal, documento)       │
│  ├── Hub (servidor web + WebSocket)          │
│  ├── App SwiftUI (canvas nativo)             │
│  └── Web canvas (xterm.js, portais, notas)   │
└──────────────────────────────────────────────┘
         │ porta 9620
         ▼
  http://192.168.1.42:9620  ← amigos na LAN
  http://100.x.x.x:9620     ← amigos via Tailscale
```

**Setup:**

```bash
# 1. Build
git clone https://github.com/AElise08/colmeia.git
cd colmeia
./scripts/build-app.sh

# 2. Roda
open dist/Colmeia.app

# 3. Compartilhe o link
# Na LAN: http://$(ipconfig getifaddr en0):9620
# Via Tailscale: http://$(tailscale ip -4):9620
```

O Hub local já serve o canvas web completo: terminal xterm.js, notas com cor
por pessoa, portal DuckDuckGo, busca, exclusão, presença com cursor remoto.

### Modo B: VPS (compartilhado — modelo atual)

O Engine roda no seu Mac (máxima performance), o Hub roda numa VPS (disponível
24/7 para outras pessoas).

```
┌── Seu Mac ──────────┐    ┌── VPS ──────────────────┐
│  Engine              │◄──►│  colmeia-sync (ponte)   │
│  App SwiftUI (opc.)  │    │  HubServer (porta 9620) │
│  colmeia-sync        │    │  └── Web canvas (HTTP)  │
└──────────────────────┘    └─────────────────────────┘
                                     │
                                     ▼
                     http://vps:9620/join/ABCD  ← qualquer pessoa
```

**Setup:**

```bash
# No seu Mac (já tem o app):
scripts/build-app.sh
open dist/Colmeia.app
# Configure no app ou via COLMEIA_HUB_URL/COLMEIA_HUB_TOKEN

# Na VPS, configure o host e o token por ambiente:
# Roda o Hub (binary ou via systemd)
colmeia-hub --port 9620 --token SEU_TOKEN
```

Acesse o link de invite do Hub para entrar na sala pelo navegador.

### Modo C: só VPS, sem Mac

Tudo roda no servidor. Você acessa exclusivamente pelo navegador (Windows,
Chromebook, celular, qualquer dispositivo).

```
┌── VPS ───────────────────────────────────────┐
│  Engine (Linux)                               │
│  colmeia-sync (localhost)                     │
│  HubServer (porta 9620)                       │
│  └── Web canvas completo (xterm.js + tudo)    │
└───────────────────────────────────────────────┘
         │
         ▼
  http://vps:9620  ← qualquer dispositivo, qualquer lugar
```

**Setup:**

```bash
# Na VPS (Ubuntu/Debian):
sudo apt install swift          # ou baixe o toolchain
swift build -c release
scp .build/release/colmeia-engine vps:/usr/local/bin/
scp .build/release/ColmeiaHub  vps:/usr/local/bin/

# systemd service para o Engine
cat > /etc/systemd/system/colmeia-engine.service <<'EOF'
[Unit]
Description=Colmeia Engine
After=network.target

[Service]
ExecStart=/usr/local/bin/colmeia-engine --root /var/lib/colmeia
Restart=always
User=colmeia

[Install]
WantedBy=multi-user.target
EOF

# systemd service para o Hub
cat > /etc/systemd/system/colmeia-hub.service <<'EOF'
[Unit]
Description=Colmeia Hub
After=colmeia-engine.service

[Service]
ExecStart=/usr/local/bin/colmeia-hub --port 9620
Restart=always
User=colmeia

[Install]
WantedBy=multi-user.target
EOF
```

**⚠️ Limitações do modo C (só navegador):**
- Sem app nativo: sem SwiftTerm (emulador mais rápido), sem notificações macOS, sem atalhos Cmd
- Latência de rede: tecla → echo visual ~20-50ms (vs 0ms local)
- Depende de o VPS estar rodando 24/7

---

## Para humanos: como usar

### Canvas web (navegador)

| Botão | O que faz |
|---|---|
| **Terminal** | Cria um terminal novo (xterm.js, shell real) |
| **Nota** | Cria uma nota colorida (cor por autor) |
| **Navegador** | Abre um portal DuckDuckGo embutido |
| **Conectar** | Link `colmeia://join/...` para abrir no Mac |
| **Buscar** | Filtra nós por nome, URL ou conteúdo de nota |
| **Excluir** | Remove nó ou conexão selecionado |
| **Enquadrar** | Centraliza a vista no nó selecionado |

Atalhos de teclado:
- `Delete`/`Backspace` — exclui nó selecionado
- Click + drag — move nós
- Dois cliques em nota — edita conteúdo
- Scroll — zoom no canvas

### App Mac nativo

O app nativo (SwiftUI) tem tudo que o web canvas tem, mais:
- Emulador terminal SwiftTerm (0ms latência)
- Atalhos macOS (Cmd+C/V, Cmd+Q, Cmd+W, etc.)
- Notificações nativas (watchdog, menção, aprovação)
- Drag-and-drop do Finder
- Desempenho de desenho acelerado por Metal
- Múltiplos andares (floors) com viewport próprio

---

## Para agentes: protocolo

Agentes conectam via protocolo NDJSON sobre TCP (socket local ou remoto).

### Conectar

```json
{"request":{"id":"h1","method":"hello","params":{"protocol_version":"0.1","client":"meu-agente","author":"humano"}}}
```

### Listar nós

```json
{"request":{"id":"h2","method":"workspace.list"}}
```
Resposta:
```json
{"response":{"id":"h2","result":[{"id":"01J...","nome":"Meu Workspace"}]}}
```

### Criar nó

```json
{"request":{"id":"h3","method":"node.create","params":{"workspace_id":"01J...","tipo":"terminal","nome":"meu-shell","floor":null}}}
```

### Escrever nota

```json
{"request":{"id":"h4","method":"note.replace","params":{"workspace_id":"01J...","node_id":"01K...","conteudo":"# Análise\nResultado: sucesso\n"}}}
```

### Ler nota

```json
{"request":{"id":"h5","method":"note.get","params":{"workspace_id":"01J...","node_id":"01K..."}}}
```

### Executar comando (session.input)

```json
{"request":{"id":"h6","method":"session.input","params":{"session_id":"01K...","data_b64":"bHMgLWxhCg=="}}}
```

### Escutar eventos (tempo real)

```json
{"request":{"id":"h7","method":"subscribe","params":{"topics":["session.output","session.state","document.op"]}}}
```

Eventos chegam como:
```json
{"event":{"topic":"session.output","params":{"session_id":"01K...","data_b64":"dG90YWwgMzI="}}}
```

### Exemplo completo (Python)

```python
import socket, json, base64

sock = socket.socket()
sock.connect(("127.0.0.1", 9622))

def send(obj):
    sock.sendall((json.dumps(obj) + "\n").encode())

# Hello
send({"request": {"id": "1", "method": "hello",
      "params": {"protocol_version": "0.1", "client": "bot", "author": "humano"}}})
# Aguarda response do hello...

# Lista workspaces
send({"request": {"id": "2", "method": "workspace.list"}})

# Cria nota
send({"request": {"id": "3", "method": "note.replace",
      "params": {"workspace_id": "01J...", "node_id": "01K...",
                 "conteudo": "Nota criada por um agente!"}}})
```

---

## Arquitetura

```text
┌──────────────┐     socket unix      ┌──────────────┐
│  App Mac     │◄────────────────────►│   Engine      │
│  (SwiftUI)   │     NDJSON           │   (Swift)     │
│  CanvasView  │                      │   PTYs        │
│  SwiftTerm   │                      │   Journal     │
└──────┬───────┘                      │   Document    │
       │                              └──────┬───────┘
       │ TCP/9622                            │
       ▼                                     ▼
┌──────────────┐                    ┌──────────────┐
│  Web Canvas   │                   │  colmeia-sync │
│  (xterm.js)   │                   │  (ponte)      │
│  Hub HTTP     │                   │  Engine↔Hub   │
└──────┬───────┘                    └──────┬───────┘
       │                                    │
       ▼ TCP/9620                           ▼ TCP/9620
┌─────────────────────────────────────────────────────┐
│                   Hub Server                         │
│  (WebSocket, salas, presença, snapshot, forward)     │
│  ┌─────┐ ┌─────┐ ┌─────┐                             │
│  │Sala1│ │Sala2│ │Sala3│ ← RoomStore, WorkspaceStore │
│  └─────┘ └─────┘ └─────┘                             │
└─────────────────────────────────────────────────────┘
```

### Componentes

| Componente | Papel | Roda em |
|---|---|---|
| **Engine** | Dono de PTYs, journal, documento, sessões | Mac ou VPS |
| **HubServer** | Servidor de salas, WebSocket, snapshots, presença | VPS ou Mac |
| **colmeia-sync** | Ponte bidirecional Engine ↔ Hub | Mac |
| **App (SwiftUI)** | Canvas nativo macOS | Mac |
| **Web canvas** | Canvas no navegador (xterm.js, CSS, JS) | Navegador |
| **CLI (`colmeia`)** | Companion de terminal (ask, note, status) | Mac ou VPS |

### Protocolo

O protocolo é NDJSON sobre TCP, com três tipos de mensagem:
- **`request`** — chamada de método (hello, node.create, session.input, etc.)
- **`response`** — resposta a um request (ok com result, ou error)
- **`event`** — evento assíncrono (session.output, document.op, presence.update)

Todas as mensagens são delimitadas por `\n` (0x0A). Binário (output de PTY)
vai como base64 nos campos `data_b64`.

---

## Build & desenvolvimento

### Segurança antes de publicar

- Nunca commitamos tokens, chaves SSH, certificados, `.env`, workspaces ou `dist/`.
- O Hub público deve usar HTTPS/WSS atrás de um proxy TLS.
- O Engine local pode acessar PTYs e arquivos; não exponha o socket do Engine na internet.
- Configure `HUB_TOKEN`, `COLMEIA_HUB_HOST` e `COLMEIA_REMOTE_SSH_TARGET` apenas por ambiente.
- O código é open source, mas a infraestrutura de produção não é parte do repositório.

```bash
git clone https://github.com/AElise08/colmeia.git
cd colmeia

# Build de debug
swift build

# Build de release
swift build -c release

# Build o app .app
scripts/build-app.sh

# Roda
open dist/Colmeia.app

# Testes
./test.sh          # NÃO use `swift test` puro (veja abaixo)

# Smoke test opcional da automação real do portal (requer Chrome instalado)
COLMEIA_BROWSER_TESTS=1 ./test.sh --filter AgentCapabilitiesTests
```

**⚠️ `swift test` puro não funciona:** o CommandLineTools 6.2.4 vem sem o módulo
`_Testing_Foundation.framework/Modules`, quebrando `import Testing`. O
`./test.sh` contorna com `-F` + `-disable-cross-import-overlays` + rpath.

### Criar um invite para compartilhar

No app Mac, crie uma sala e copie o link de invite. O link tem formato:
```
http://vps:9620/join/01KYQC3NRVZ4T8Q795PFBM7SK1/01KYQD3EY56NJY4J8M2YF24PF4
```

Ou via CLI:
```bash
colmeia room create --nome "minha-sala"
```

---

## Licença

Apache-2.0 — veja [LICENSE](LICENSE).
