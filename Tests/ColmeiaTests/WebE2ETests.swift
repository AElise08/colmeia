import Foundation
import Testing
import ColmeiaKit
@testable import ColmeiaHub

// MARK: - Cliente TCP para testes E2E com o Hub

/// Cliente TCP raw que fala o protocolo NDJSON do Hub.
/// Usa uma DispatchQueue de fundo para ler continuamente o socket.
private final class HubE2EClient: @unchecked Sendable {
    let fd: Int32
    private let lock = NSLock()
    private var buffer = Data()
    private var requestCounter: UInt64 = 0
    private var pendingResponseId: String?
    private var pendingResponse: [String: Any]?
    private let responseSemaphore = DispatchSemaphore(value: 0)
    /// Eventos recebidos (kind=event, não-response) acumulados.
    private var _receivedEvents: [[String: Any]] = []
    private var stopped = false

    init(host: String = "127.0.0.1", port: UInt16) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw makeError("socket") }
        self.fd = fd
        var sin = sockaddr_in()
        sin.sin_family = sa_family_t(AF_INET)
        sin.sin_port = port.bigEndian
        sin.sin_addr.s_addr = inet_addr(host)
        let rc = withUnsafePointer(to: &sin) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc != 0 { Darwin.close(fd); throw makeError("connect") }
        // Start background reader
        DispatchQueue(label: "e2e-read-\(port)", qos: .userInitiated).async { [weak self] in
            self?.readLoop(fd: fd)
        }
    }

    deinit {
        stopped = true
        Darwin.close(fd)
    }

    // MARK: - Background read loop

    private func readLoop(fd: Int32) {
        var chunk = [UInt8](repeating: 0, count: 65536)
        while !stopped {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            lock.lock()
            buffer.append(contentsOf: chunk[..<n])
            processLines()
            lock.unlock()
        }
    }

    private func processLines() {
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<nl]
            buffer = buffer[buffer.index(after: nl)...]
            guard let line = String(data: lineData, encoding: .utf8),
                  let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            if let id = obj["id"] as? String, id == pendingResponseId {
                pendingResponse = obj
                responseSemaphore.signal()
            } else {
                _receivedEvents.append(obj)
            }
        }
    }

    // MARK: - API pública

    /// Envia um request e aguarda a response (bloqueante, timeout configurável).
    func call(method: String, params: [String: Any] = [:], timeout: TimeInterval = 10) throws -> [String: Any] {
        requestCounter += 1
        let id = "e2e-\(requestCounter)"
        let req: [String: Any] = ["kind": "request", "id": id, "method": method, "params": params]
        let jsonData = try JSONSerialization.data(withJSONObject: req)
        let reqStr = String(data: jsonData, encoding: .utf8) ?? ""
        print("[E2E] >> \(reqStr)")

        lock.lock()
        pendingResponseId = id
        pendingResponse = nil
        lock.unlock()

        try writeAll(jsonData + Data([0x0A]))

        guard responseSemaphore.wait(timeout: .now() + timeout) == .success else {
            lock.lock(); pendingResponseId = nil; lock.unlock()
            throw makeError("timeout call \(method)")
        }

        lock.lock()
        let resp = pendingResponse
        pendingResponseId = nil
        lock.unlock()

        guard let result = resp else { throw makeError("timeout call \(method)") }
        print("[E2E] << \(result["id"] ?? "") ok=\(result["ok"] ?? "?")")
        return result
    }

    /// Envia um evento (kind=event, sem response).
    func emit(topic: String, params: [String: Any]) throws {
        let ev: [String: Any] = ["kind": "event", "topic": topic, "params": params]
        let data = try JSONSerialization.data(withJSONObject: ev) + Data([0x0A])
        try writeAll(data)
    }

    /// Retorna e limpa a fila de eventos recebidos.
    func drainEvents() -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        let evts = _receivedEvents; _receivedEvents = []; return evts
    }

    // MARK: - IO privado

    private func writeAll(_ data: Data) throws {
        var remaining = data.count; var offset = 0
        while remaining > 0 {
            let n = data.advanced(by: offset).withUnsafeBytes { ptr in
                Darwin.send(fd, ptr.baseAddress, remaining, 0)
            }
            if n <= 0 { throw makeError("send") }
            remaining -= n; offset += n
        }
    }
}

private func makeError(_ msg: String) -> NSError {
    NSError(domain: "E2E", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: msg])
}

// MARK: - Helpers de dados

private func testTerminal(id: ULID = .generate(), nome: String = "test-terminal") -> Node {
    .terminal(.init(id: id, posicao: .init(x: 100, y: 200), tamanho: .init(w: 360, h: 260),
                    z: 0, criadoEm: Date(), nome: nome, adapter: "shell", cwd: "/tmp/test"))
}

private func testNota(id: ULID = .generate(), arquivo: String = "notes/test.md", cor: String = "#8b5cf6") -> Node {
    .nota(.init(id: id, posicao: .init(x: 500, y: 200), tamanho: .init(w: 280, h: 200),
                z: 1, criadoEm: Date(), arquivo: arquivo, cor: cor))
}

private func asDict<T: Encodable>(_ value: T) throws -> [String: Any] {
    let data = try ColmeiaJSON.encoder().encode(value)
    return try JSONSerialization.jsonObject(with: data) as! [String: Any]
}

// MARK: - Suite

@Suite("E2E — Hub WebSocket/Protocol", .serialized)
struct WebE2ETests {

    private func startHub() throws -> (HubServer, UInt16, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("e2e-\(UUID().uuidString)", isDirectory: true)
        let paths = ColmeiaPaths(root: root)
        try paths.ensureRootLayout()
        for tryPort: UInt16 in [9870, 9871, 9872, 9873, 9874, 9875, 9876] {
            let s = HubServer(paths: paths, host: "127.0.0.1", port: tryPort)
            do { try s.start(); return (s, tryPort, root) } catch { continue }
        }
        throw NSError(domain: "E2E", code: 1, userInfo: [NSLocalizedDescriptionKey: "não conseguiu bind"])
    }

    private func helloAndSubscribe(port: UInt16) throws -> HubE2EClient {
        let c = try HubE2EClient(port: port)
        Thread.sleep(forTimeInterval: 0.1)  // aguarda Hub preparar reader
        let r1 = try c.call(method: "hello", params: [
            "protocol_version": ColmeiaVersion.protocolVersion,
            "client": "e2e-test", "author": "humano:e2e-tester"
        ])
        guard (r1["ok"] as? Bool) == true else { throw makeError("hello") }
        let r2 = try c.call(method: "subscribe")
        guard (r2["ok"] as? Bool) == true else { throw makeError("subscribe") }
        return c
    }

    /// Cria uma sala e retorna o room ID.
    private func createRoom(
        _ c: HubE2EClient,
        name: String = "e2e-room",
        workspaceID: String? = nil
    ) throws -> String {
        var params: [String: Any] = ["name": name]
        if let workspaceID { params["workspace_id"] = workspaceID }
        let resp = try c.call(method: "room.create", params: params)
        guard let result = resp["result"] as? [String: Any],
              let room = result["room"] as? [String: Any],
              let rid = room["id"] as? String else { throw makeError("room.create") }
        return rid
    }

    private func joinRoom(_ c: HubE2EClient, roomID: String) throws {
        let resp = try c.call(method: "room.join", params: ["room_id": roomID])
        guard (resp["ok"] as? Bool) == true else { throw makeError("room.join") }
    }

    private func createWorkspace(_ c: HubE2EClient, nome: String = "e2e-ws") throws -> String {
        let resp = try c.call(method: "workspace.create", params: ["nome": nome])
        guard let r = resp["result"] as? [String: Any],
              let ws = r["workspace"] as? [String: Any],
              let wid = ws["id"] as? String else { throw makeError("workspace.create") }
        return wid
    }

    private func pushSnapshot(_ c: HubE2EClient, wsID: String,
                              nodes: [[String: Any]] = [], connections: [[String: Any]] = [],
                               noteContents: [String: String]? = nil,
                               sessionStates: [[String: String]]? = nil,
                               sessionOutputs: [String: [[String: String]]]? = nil,
                               watchdogConfiguration: [String: Any]? = nil) throws {
        var params: [String: Any] = [
            "workspace_id": wsID, "nome": "e2e-ws", "seq": 1,
            "nodes": nodes, "connections": connections
        ]
        if let nc = noteContents { params["note_contents"] = nc }
        if let ss = sessionStates { params["session_states"] = ss }
        if let so = sessionOutputs { params["session_outputs"] = so }
        if let watchdogConfiguration { params["watchdog_configuration"] = watchdogConfiguration }
        let resp = try c.call(method: "workspace.pushSnapshot", params: params, timeout: 15)
        guard (resp["ok"] as? Bool) == true else { throw makeError("pushSnapshot") }
    }

    // MARK: - Testes

    @Test func roomCreateVinculaWorkspaceParaBootstrapWeb() async throws {
        let (hub, port, root) = try startHub()
        defer { hub.stop(); try? FileManager.default.removeItem(at: root) }

        let c = try helloAndSubscribe(port: port)
        let wsID = try createWorkspace(c)
        let roomID = try createRoom(c, workspaceID: wsID)
        let rooms = try c.call(method: "room.list")
        guard let result = rooms["result"] as? [[String: Any]],
              let room = result.first(where: { $0["id"] as? String == roomID }) else {
            Issue.record("sala criada não apareceu em room.list")
            return
        }
        #expect(room["workspace_id"] as? String == wsID)
    }

    @Test func missionListFuncionaSemEngineRemoto() async throws {
        let (hub, port, root) = try startHub()
        defer { hub.stop(); try? FileManager.default.removeItem(at: root) }

        let c = try helloAndSubscribe(port: port)
        let roomID = try createRoom(c)
        let empty = try c.call(method: "mission.list", params: ["room_id": roomID])
        #expect((empty["result"] as? [[String: Any]])?.isEmpty == true)

        let created = try c.call(method: "mission.create", params: [
            "room_id": roomID,
            "title": "Missão web",
            "definition_of_done": "Aparece no Hub"
        ])
        #expect(created["ok"] as? Bool == true)
        let listed = try c.call(method: "mission.list", params: ["room_id": roomID])
        #expect((listed["result"] as? [[String: Any]])?.count == 1)
        guard let missionID = ((created["result"] as? [String: Any])?["mission"] as? [String: Any])?["id"] as? String else {
            Issue.record("mission.create não retornou ID")
            return
        }
        let archived = try c.call(method: "mission.transition", params: [
            "room_id": roomID, "mission_id": missionID,
            "state": "archived", "reason": "E2E"
        ])
        #expect((((archived["result"] as? [String: Any])?["mission"] as? [String: Any])?["state"] as? String) == "archived")
    }

    @Test func noteReplacePersisteEBroadcastSemEngineRemoto() async throws {
        let (hub, port, root) = try startHub()
        defer { hub.stop(); try? FileManager.default.removeItem(at: root) }

        let c = try helloAndSubscribe(port: port)
        let wsID = try createWorkspace(c)
        let noteID = ULID.generate()
        try pushSnapshot(c, wsID: wsID, nodes: [try asDict(testNota(id: noteID))],
                         noteContents: [noteID.string: ""])

        let replaced = try c.call(method: "note.replace", params: [
            "workspace_id": wsID, "node_id": noteID.string,
            "conteudo": "# Editada na web"
        ])
        #expect((replaced["result"] as? [String: Any])?["conteudo"] as? String == "# Editada na web")

        let loaded = try c.call(method: "note.get", params: [
            "workspace_id": wsID, "node_id": noteID.string
        ])
        #expect((loaded["result"] as? [String: Any])?["conteudo"] as? String == "# Editada na web")

        // Um sync local atrasado não pode sobrescrever uma edição feita na web.
        try pushSnapshot(c, wsID: wsID, nodes: [try asDict(testNota(id: noteID))],
                         noteContents: [noteID.string: "conteúdo local antigo"])
        let afterStalePush = try c.call(method: "note.get", params: [
            "workspace_id": wsID, "node_id": noteID.string
        ])
        #expect((afterStalePush["result"] as? [String: Any])?["conteudo"] as? String == "# Editada na web")
    }

    @Test func chatWebPersisteNoSnapshotDaSala() async throws {
        let (hub, port, root) = try startHub()
        defer { hub.stop(); try? FileManager.default.removeItem(at: root) }

        let c = try helloAndSubscribe(port: port)
        let wsID = try createWorkspace(c)
        let roomID = try createRoom(c, workspaceID: wsID)
        try joinRoom(c, roomID: roomID)
        let sessionResponse = try c.call(method: "agent_session.create", params: [
            "room_id": roomID, "workspace_id": wsID,
            "node_id": ULID.generate().string, "objective": "Chat da sala"
        ])
        guard let sessionID = ((sessionResponse["result"] as? [String: Any])?["agent_session"] as? [String: Any])?["id"] as? String else {
            Issue.record("agent_session.create não retornou ID")
            return
        }
        let eventID = ULID.generate().string
        let sent = try c.call(method: "session_event.append", params: [
            "room_id": roomID, "session_id": sessionID,
            "kind": "message_sent", "payload": ["texto": "Olá do navegador"],
            "event_id": eventID
        ])
        #expect(sent["ok"] as? Bool == true)

        let snapshot = try c.call(method: "room.snapshot", params: ["room_id": roomID])
        let events = (snapshot["result"] as? [String: Any])?["events"] as? [[String: Any]]
        #expect(events?.contains(where: { event in
            event["id"] as? String == eventID &&
                (event["payload"] as? [String: Any])?["texto"] as? String == "Olá do navegador"
        }) == true)
    }

    @Test func sessionStartWebERoteadoAoSync() async throws {
        let (hub, port, root) = try startHub()
        defer { hub.stop(); try? FileManager.default.removeItem(at: root) }

        let owner = try helloAndSubscribe(port: port)
        let wsID = try createWorkspace(owner)
        let nodeID = ULID.generate()
        try pushSnapshot(owner, wsID: wsID, nodes: [try asDict(testTerminal(id: nodeID))])
        _ = try createRoom(owner, workspaceID: wsID)

        let sync = try HubE2EClient(port: port)
        let hello = try sync.call(method: "hello", params: [
            "protocol_version": ColmeiaVersion.protocolVersion,
            "client": "colmeia-sync", "author": "humano:sync-e2e"
        ])
        #expect(hello["ok"] as? Bool == true)

        let startTask = Task.detached {
            try owner.call(method: "session.start", params: [
                "workspace_id": wsID, "node_id": nodeID.string,
                "cols": 80, "rows": 24
            ], timeout: 15)
        }
        var relay: [String: Any]?
        for _ in 0..<20 where relay == nil {
            try await Task.sleep(for: .milliseconds(50))
            relay = sync.drainEvents().first { $0["topic"] as? String == "sync.session.start" }
        }
        let relayParams = relay?["params"] as? [String: Any]
        guard let relayID = relayParams?["request_id"] as? String else {
            Issue.record("Hub não enviou request_id ao sync")
            return
        }
        let sessionID = ULID.generate().string
        try sync.emit(topic: "sync.session.start.result", params: [
            "request_id": relayID,
            "session": [
                "id": sessionID, "workspace_id": wsID,
                "node_id": nodeID.string, "adapter": "shell",
                "estado": "iniciando", "iniciada_em": "2026-07-29T18:00:00Z",
                "cols": 80, "rows": 24
            ]
        ])
        let started = try await startTask.value
        #expect(started["ok"] as? Bool == true)
        #expect((((started["result"] as? [String: Any])?["session"] as? [String: Any])?["id"] as? String) == sessionID)
    }

    @Test func conviteReconectaMesmoAposPerderIdentidadeDoNavegador() async throws {
        let (hub, port, root) = try startHub()
        defer { hub.stop(); try? FileManager.default.removeItem(at: root) }

        let owner = try helloAndSubscribe(port: port)
        let roomID = try createRoom(owner)
        let inviteResponse = try owner.call(method: "member.invite", params: [
            "room_id": roomID,
            "display_name": "Browser",
            "roles": ["editor"]
        ])
        let inviteResult = inviteResponse["result"] as? [String: Any]
        guard let token = inviteResult?["invite_token"] as? String else {
            Issue.record("member.invite não retornou token")
            return
        }

        do {
            let browser = try HubE2EClient(port: port)
            let hello = try browser.call(method: "hello", params: [
                "protocol_version": ColmeiaVersion.protocolVersion,
                "client": "web-canvas",
                "author": "humano:web-estavel",
                "token": token
            ])
            #expect(hello["ok"] as? Bool == true)
            let joined = try browser.call(method: "room.join", params: [
                "room_id": roomID,
                "invite_token": token
            ])
            #expect(joined["ok"] as? Bool == true)
        }

        let reconnected = try HubE2EClient(port: port)
        let helloAgain = try reconnected.call(method: "hello", params: [
            "protocol_version": ColmeiaVersion.protocolVersion,
            "client": "web-canvas",
            "author": "humano:web-novo",
            "token": token
        ])
        #expect(helloAgain["ok"] as? Bool == true)
        #expect((helloAgain["result"] as? [String: Any])?["author"] as? String == "humano:web-estavel")
        let joinedAgain = try reconnected.call(method: "room.join", params: [
            "room_id": roomID,
            "invite_token": token
        ])
        #expect(joinedAgain["ok"] as? Bool == true)
    }

    @Test func workspaceOpenRetornaNoteContentsESessionOutputs() async throws {
        let (hub, port, root) = try startHub()
        defer { hub.stop(); try? FileManager.default.removeItem(at: root) }

        let c = try helloAndSubscribe(port: port)
        let roomID = try createRoom(c)
        try joinRoom(c, roomID: roomID)
        let wsID = try createWorkspace(c)

        let termID = ULID.generate()
        let notaID = ULID.generate()
        let sessID = ULID.generate()
        try pushSnapshot(c, wsID: wsID,
            nodes: [try asDict(testTerminal(id: termID)), try asDict(testNota(id: notaID))],
            connections: [try asDict(Connection(id: .generate(), de: termID, para: notaID, semantica: .conversa, estilo: .solida))],
            noteContents: [notaID.string: "# Teste\n\n**markdown** `code`"],
            sessionStates: [["session_id": sessID.string, "estado": "rodando", "node_id": termID.string]],
            sessionOutputs: [sessID.string: [["text": "linha 1\n", "seq": "1"], ["text": "linha 2\n", "seq": "2"]]],
            watchdogConfiguration: [
                "workspacePolicy": ["enabled": true, "staleAfter": 300.0, "nudgeInterval": 120.0, "maxNudgesPerEpisode": 2],
                "sessionOverrides": []
            ]
        )

        let open = try c.call(method: "workspace.open", params: ["id": wsID])
        guard let result = open["result"] as? [String: Any],
              let snap = result["document_snapshot"] as? [String: Any] else {
            Issue.record("sem snapshot"); return
        }
        #expect((snap["note_contents"] as? [String: String])?[notaID.string]?.contains("**markdown**") == true)
        #expect((snap["session_states"] as? [[String: String]])?.contains(where: { $0["estado"] == "rodando" }) == true)
        let outputs = snap["session_outputs"] as? [String: [[String: String]]]
        #expect(outputs?.values.flatMap { $0 }.contains(where: { $0["text"] == "linha 1\n" }) == true)
        #expect(((snap["watchdog_configuration"] as? [String: Any])?["workspacePolicy"] as? [String: Any])?["enabled"] as? Bool == true)
    }

    @Test func documentOpPropagado() async throws {
        let (hub, port, root) = try startHub()
        defer { hub.stop(); try? FileManager.default.removeItem(at: root) }

        let c1 = try helloAndSubscribe(port: port)  // Engine
        let c2 = try helloAndSubscribe(port: port)  // Web client
        let roomID = try createRoom(c1)
        try joinRoom(c1, roomID: roomID)
        try joinRoom(c2, roomID: roomID)
        let wsID = try createWorkspace(c1)
        try pushSnapshot(c1, wsID: wsID)
        _ = try c2.call(method: "workspace.open", params: ["id": wsID])
        _ = c2.drainEvents()

        // Emite document.op com node.add
        let nodeID = ULID.generate()
        try c1.emit(topic: "document.op", params: [
            "workspace_id": wsID, "seq": 2,
            "op": [
                "op_id": ULID.generate().string, "author": "humano:e2e",
                "ts": ISO8601DateFormatter().string(from: Date()),
                "payload": ["type": "nodeAdd", "node": try asDict(testTerminal(id: nodeID))]
            ]
        ])
        try await Task.sleep(for: .milliseconds(100))
        let evts1 = c2.drainEvents()
        #expect(evts1.contains(where: { ($0["topic"] as? String) == "document.op" }))

        // Emite document.op com node.delete
        try c1.emit(topic: "document.op", params: [
            "workspace_id": wsID, "seq": 3,
            "op": [
                "op_id": ULID.generate().string, "author": "humano:e2e",
                "ts": ISO8601DateFormatter().string(from: Date()),
                "payload": ["type": "nodeDelete", "id": nodeID.string]
            ]
        ])
        try await Task.sleep(for: .milliseconds(100))
        let evts2 = c2.drainEvents()
        #expect(evts2.contains(where: { ($0["topic"] as? String) == "document.op" }))
    }

    @Test func docApplyWebPersisteMoveEBroadcast() async throws {
        let (hub, port, root) = try startHub()
        defer { hub.stop(); try? FileManager.default.removeItem(at: root) }

        let c1 = try helloAndSubscribe(port: port)
        let c2 = try helloAndSubscribe(port: port)
        let wsID = try createWorkspace(c1)
        let nodeID = ULID.generate()
        try pushSnapshot(c1, wsID: wsID, nodes: [try asDict(testTerminal(id: nodeID))])
        _ = try c2.call(method: "workspace.open", params: ["id": wsID])
        _ = c1.drainEvents()
        _ = c2.drainEvents()

        let op = DocOp(
            opID: .generate(),
            author: .humano("web-e2e"),
            ts: Date(),
            payload: .nodeMove(.init(id: nodeID, posicao: .init(x: 777, y: 333)))
        )
        let apply = try c2.call(method: "doc.apply", params: [
            "workspace_id": wsID,
            "ops": [try asDict(op)]
        ])
        #expect(apply["ok"] as? Bool == true)
        try await Task.sleep(for: .milliseconds(100))
        #expect(c1.drainEvents().contains(where: { $0["topic"] as? String == "document.op" }))

        let open = try c1.call(method: "workspace.open", params: ["id": wsID])
        let result = open["result"] as? [String: Any]
        let snapshot = result?["document_snapshot"] as? [String: Any]
        let nodes = snapshot?["nodes"] as? [[String: Any]]
        let moved = nodes?.first(where: { $0["id"] as? String == nodeID.string })
        let position = moved?["posicao"] as? [String: Any]
        #expect(position?["x"] as? Double == 777)
        #expect(position?["y"] as? Double == 333)
    }

    @Test func noteAppendedPropagado() async throws {
        let (hub, port, root) = try startHub()
        defer { hub.stop(); try? FileManager.default.removeItem(at: root) }

        let c1 = try helloAndSubscribe(port: port)
        let c2 = try helloAndSubscribe(port: port)
        let roomID = try createRoom(c1)
        try joinRoom(c1, roomID: roomID)
        try joinRoom(c2, roomID: roomID)
        let wsID = try createWorkspace(c1)
        let notaID = ULID.generate()
        try pushSnapshot(c1, wsID: wsID, nodes: [try asDict(testNota(id: notaID))],
                         noteContents: [notaID.string: "# inicial"])
        _ = try c2.call(method: "workspace.open", params: ["id": wsID])
        _ = c2.drainEvents()

        try c1.emit(topic: "note.appended", params: [
            "node_id": notaID.string, "conteudo": "# atualizado\n**novo**"
        ])
        try await Task.sleep(for: .milliseconds(100))
        let evts = c2.drainEvents()
        #expect(evts.contains(where: {
            ($0["topic"] as? String) == "note.appended"
        }))
    }

    @Test func hubRestartPreservaWorkspace() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("e2e-restart-\(UUID().uuidString)", isDirectory: true)

        // Primeira execução: cria workspace com dados
        let wsID: String
        let notaID = ULID.generate()
        do {
            let paths = ColmeiaPaths(root: root)
            try paths.ensureRootLayout()
            let hub = HubServer(paths: paths, host: "127.0.0.1", port: 9881)
            try hub.start()
            let c = try helloAndSubscribe(port: 9881)
            let roomID = try createRoom(c)
            try joinRoom(c, roomID: roomID)
            wsID = try createWorkspace(c)
            try pushSnapshot(c, wsID: wsID,
                nodes: [try asDict(testNota(id: notaID))],
                noteContents: [notaID.string: "conteudo persistente"])
            hub.stop()
        }

        // Segunda execução: restart do hub
        let paths2 = ColmeiaPaths(root: root)
        try paths2.ensureRootLayout()
        let hub2 = HubServer(paths: paths2, host: "127.0.0.1", port: 9882)
        try hub2.start()
        defer { hub2.stop(); try? FileManager.default.removeItem(at: root) }

        let c2 = try helloAndSubscribe(port: 9882)
        let open = try c2.call(method: "workspace.open", params: ["id": wsID])
        guard let result = open["result"] as? [String: Any],
              let snap = result["document_snapshot"] as? [String: Any],
              let nodes = snap["nodes"] as? [[String: Any]] else {
            Issue.record("workspace.open falhou após restart"); return
        }
        #expect(nodes.count == 1)
        #expect((snap["note_contents"] as? [String: String])?[notaID.string] == "conteudo persistente")
    }

    @Test func sessionOutputEStateFlow() async throws {
        let (hub, port, root) = try startHub()
        defer { hub.stop(); try? FileManager.default.removeItem(at: root) }

        let c1 = try helloAndSubscribe(port: port)
        let c2 = try helloAndSubscribe(port: port)
        let roomID = try createRoom(c1)
        try joinRoom(c1, roomID: roomID)
        try joinRoom(c2, roomID: roomID)
        let wsID = try createWorkspace(c1)
        let sessID = ULID.generate()
        let nodeID = ULID.generate()
        try pushSnapshot(c1, wsID: wsID, nodes: [try asDict(testTerminal(id: nodeID))])
        _ = try c2.call(method: "workspace.open", params: ["id": wsID])
        _ = c2.drainEvents()

        try c1.emit(topic: "session.output", params: [
            "session_id": sessID.string,
            "data_b64": Data("hello\n".utf8).base64EncodedString()
        ])
        try await Task.sleep(for: .milliseconds(50))
        try c1.emit(topic: "session.state", params: [
            "session_id": sessID.string, "estado": "rodando", "node_id": nodeID.string
        ])
        try await Task.sleep(for: .milliseconds(100))
        let evts = c2.drainEvents()
        #expect(evts.contains(where: { ($0["topic"] as? String) == "session.output" }))
        #expect(evts.contains(where: { ($0["topic"] as? String) == "session.state" }))
    }
}
