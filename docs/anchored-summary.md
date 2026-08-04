## Objective
- Bridge local macOS Engine ↔ VPS Hub so workspace data created in the App appears in the web browser in real time

## Important Details
- Engine (`colmeia-engine`) is macOS‑only (PTY code); does not compile on Linux. VPS runs only the Hub.
- Hub on VPS had `COLMEIA_ENGINE_URL=tcp://127.0.0.1:9622` → blocking `connect()` caused the Hub to hang (TCP SYN timeout ~127 s). Fixed: non‑blocking socket + `poll()` with timeout.
- Hub now starts `EngineConnection` in background: persistent TCP socket, auto‑reconnect with exponential backoff. If Engine unreachable, the Hub continues serving local data.
- `callEngine` replaced by `engineConn.call(method:params:completion:)` for room.create sync and the `default:` catch‑all in `dispatch()`.
- `EngineConnection.readLoop()` parses `response` messages → resolves pending RPCs; parses `event` messages → forwards to `hub?.broadcast()`.
- Subscription bug fixed: `client.subscriptions[topic] = nil` was removing the dictionary key; changed to `Set<ULID>()` (empty set = no filter). Non‑optional dictionary type `[ColmeiaTopic: Set<ULID>]`.
- `WorkspaceStore` now persists to JSON files in `<root>/workspaces/<ulid>.json` via `save()` / `loadAll()`; Hub loads saved workspaces on startup.
- New sync tool `colmeia-sync` (target in Package.swift): connects to local Engine (`tcp://127.0.0.1:9622`) and remote Hub (`vps:9620`), pushes workspace snapshots, subscribes to `document.op`/`session.state` events and forwards them bidirectionally.
- Hub now has `workspace.list` and `doc.apply` handlers (previously fell through to the `default:` Engine-forwarding case, which hung when no Engine was reachable).
- `WorkspaceCreateParams` gained optional `id: ULID?` field so the sync tool can preserve the Engine's workspace ID when creating on Hub.
- Full sync verified: Engine workspace "Novo projeto" (6 nodes, 5 connections) is now replicated to the Hub with the same workspace ID.

## Work State
### Completed
- Non‑blocking Engine connect with `poll()` timeout (Linux/macOS)
- `EngineConnection` class: persistent TCP socket, auto‑reconnect, pending‑RPC tracking, event forwarding to Hub broadcast
- Replace one‑off `callEngine` calls with `engineConn.call(method:params:completion:)`
- Subscription fix: `Set<ULID>()` instead of `nil`
- `WorkspaceStore` JSON persistence; Hub loads on startup
- `colmeia-sync` tool: connects Engine ↔ Hub, syncs workspaces, forwards events in real time
- Hub `workspace.list` and `doc.apply` handlers added (previously broken)
- `WorkspaceCreateParams.id` made optional for ID preservation across sync
- Build/deploy of updated `colmeia-hub` on VPS successful
- End‑to‑end test: Engine "Novo projeto" with 6 nodes + 5 connections appears on Hub

### Active
- (none)

### Blocked
- `colmeia-engine` does not compile on Linux; sync must run on the user's macOS machine alongside the Engine
- Web browser at `/join/<room>/<invite>` still shows empty canvas (needs WebSocket fix or invite flow test)

## Next Move
1. Test that the web browser at the Hub URL now shows the synced canvas (nodes + connections)
2. If still empty, debug the WebSocket subscription/event delivery path

## Relevant Files
- `/Users/melissa/app/colmeia-canvas/Sources/ColmeiaHub/HubServer.swift`: all Hub changes (EngineConnection, workspaceList/docApply handlers, subscription fix, WorkspaceStore, non‑blocking connect)
- `/Users/melissa/app/colmeia-canvas/Sources/colmeia-sync/main.swift`: sync tool source
- `/Users/melissa/app/colmeia-canvas/Sources/ColmeiaKit/Protocol/Methods.swift`: `WorkspaceCreateParams.id` field, `HelloParams`, `WorkspaceSummary`, `WorkspaceOpenResult`
- `/Users/melissa/app/colmeia-canvas/Sources/ColmeiaKit/Storage/ColmeiaPaths.swift`: `workspacesDir` property
- `/Users/melissa/app/colmeia-canvas/Package.swift`: products + targets for colmeia-hub, colmeia-sync, colmeia-tcp-bridge
