import Foundation
import ColmeiaKit

struct SyncError: Error, CustomStringConvertible {
    let message: String
    init(_ m: String) { message = m }
    var description: String { message }
}

func tcpConnect(host: String, port: UInt16) throws -> Int32 {
    var hints = addrinfo()
    hints.ai_family = AF_INET
    #if canImport(Darwin)
    hints.ai_socktype = SOCK_STREAM
    #else
    hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
    #endif
    var res: UnsafeMutablePointer<addrinfo>?
    let portStr = String(port)
    let st = host.withCString { h in portStr.withCString { p in getaddrinfo(h, p, &hints, &res) } }
    guard st == 0, let info = res else { throw SyncError("getaddrinfo \(host):\(port)") }
    defer { freeaddrinfo(res) }
    let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
    guard fd >= 0 else { throw SyncError("socket") }
    #if canImport(Darwin)
    var one: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    guard Darwin.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 else { close(fd); throw SyncError("connect") }
    #elseif canImport(Glibc)
    guard Glibc.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 else { close(fd); throw SyncError("connect") }
    #endif
    return fd
}

final class SyncConn {
    let fd: Int32
    let name: String
    private let rq: DispatchQueue
    private let wl = NSLock()
    var onEvent: ((EventMessage) -> Void)?
    var onDisconnect: (() -> Void)?
    private var pending: [String: (JSONValue?, Error?) -> Void] = [:]
    private let pl = NSLock()
    private var alive = true

    init(fd: Int32, name: String) {
        self.fd = fd
        self.name = name
        self.rq = DispatchQueue(label: "sync-\(name)")
    }

    func start() { rq.async { [weak self] in self?.loop() } }

    private func loop() {
        let lb = SocketFraming.LineBuffer()
        var c = [UInt8](repeating: 0, count: 65536)
        while alive {
            #if canImport(Darwin)
            let n = Darwin.read(fd, &c, c.count)
            #elseif canImport(Glibc)
            let n = Glibc.read(fd, &c, c.count)
            #endif
            guard n > 0 else {
                alive = false
                onDisconnect?()
                break
            }
            for line in lb.append(Data(bytes: c, count: n)) {
                guard let env = try? SocketFraming.decodeLine(Envelope.self, from: line) else { continue }
                switch env {
                case .response(let r):
                    pl.lock(); let cb = pending.removeValue(forKey: r.id); pl.unlock()
                    if let cb {
                        if r.ok { cb(r.result ?? .object([:]), nil) }
                        else { cb(nil, r.error ?? SyncError("\(r.id) falhou")) }
                    }
                case .event(let e): onEvent?(e)
                case .request: break
                }
            }
        }
    }

    func call<T: Decodable>(_ method: String, params: JSONValue? = nil, timeout s: Int = 10) throws -> T {
        let id = "s-\(name)-\(ULID.generate().string)"
        let sem = DispatchSemaphore(value: 0)
        var result: T?; var err: Error?
        pl.lock(); pending[id] = { val, er in
            if let er { err = er } else if let val { result = try? val.decode(as: T.self) }
            sem.signal()
        }; pl.unlock()
        send(.request(RequestMessage(id: id, method: method, params: params)))
        let deadline = DispatchTime.now() + .seconds(s)
        guard sem.wait(timeout: deadline) == .success else {
            pl.lock(); pending.removeValue(forKey: id); pl.unlock()
            throw SyncError("\(name): \(method) timed out after 10s")
        }
        if let err { throw err }
        guard let result else { throw SyncError("\(name): \(method) sem resposta") }
        return result
    }

    func callVoid(_ method: String, params: JSONValue? = nil, timeout: Int = 10) throws {
        let _: JSONValue = try call(method, params: params, timeout: timeout)
    }

    func send(_ env: Envelope) {
        guard let d = try? SocketFraming.encodeLine(env) else { return }
        wl.lock(); defer { wl.unlock() }
        var frame = d; frame.append(0x0A)
        frame.withUnsafeBytes { buf in
            var off = 0
            while off < buf.count {
                #if canImport(Darwin)
                let w = Darwin.write(fd, buf.baseAddress!.advanced(by: off), buf.count - off)
                #elseif canImport(Glibc)
                let w = Glibc.write(fd, buf.baseAddress!.advanced(by: off), buf.count - off)
                #endif
                if w > 0 { off += w } else if w < 0 && errno == EINTR { continue } else { break }
            }
        }
    }

    func close() {
        alive = false
        #if canImport(Darwin)
        Darwin.close(fd)
        #elseif canImport(Glibc)
        Glibc.close(fd)
        #endif
    }
}

@main
enum SyncTool {
    static func main() throws {
        signal(SIGPIPE, SIG_IGN)
        #if canImport(Darwin)
        Darwin.setlinebuf(stdout)
        #elseif canImport(Glibc)
        Glibc.setlinebuf(stdout)
        #endif
        let hubHost = CommandLine.arguments.dropFirst().first
            ?? ProcessInfo.processInfo.environment["COLMEIA_HUB_HOST"]
            ?? "127.0.0.1"
        let hubPort = UInt16(CommandLine.arguments.dropFirst().dropFirst().first ?? "9620") ?? 9620
        let hubToken = CommandLine.arguments.dropFirst().dropFirst().dropFirst().first
            ?? ProcessInfo.processInfo.environment["COLMEIA_HUB_TOKEN"]
            ?? ""

        print("sync: engine \(ProcessInfo.processInfo.hostName) → hub \(hubHost):\(hubPort)")

        let ef = try tcpConnect(host: "127.0.0.1", port: 9622)
        let eng = SyncConn(fd: ef, name: "eng"); eng.start()
        _ = try eng.callVoid("hello", params: try JSONValue(encoding: HelloParams(
            protocolVersion: ColmeiaVersion.protocolVersion, client: "colmeia-sync", author: .humanoLocal)))
        print("engine: hello OK")

        let list: [WorkspaceSummary] = try eng.call("workspace.list")
        print("engine: \(list.count) workspaces")

        let hf = try tcpConnect(host: hubHost, port: hubPort)
        let hub = SyncConn(fd: hf, name: "hub"); hub.start()
        _ = try hub.callVoid("hello", params: try JSONValue(encoding: HelloParams(
            protocolVersion: ColmeiaVersion.protocolVersion, client: "colmeia-sync",
            author: .humanoLocal, token: hubToken.isEmpty ? nil : hubToken)))
        print("hub: hello OK")
        _ = try hub.callVoid("subscribe")
        print("hub: subscribed")

        let opLock = NSLock()
        var awaitingHubEcho: Set<ULID> = []
        var awaitingEngineEcho: Set<ULID> = []
        let noteLock = NSLock()
        var awaitingEngineNote: Set<ULID> = []
        var nodeToWorkspace: [ULID: ULID] = [:]
        var attachedSessions: Set<ULID> = []
        let remoteApplyQueue = DispatchQueue(label: "sync-remote-document-apply")

        eng.onEvent = { ev in
            if ev.knownTopic == .documentOp,
               let payload = try? ev.decodeParams(DocumentOpTopicPayload.self) {
                opLock.lock()
                if awaitingEngineEcho.remove(payload.op.opID) != nil {
                    opLock.unlock()
                    return
                }
                awaitingHubEcho.insert(payload.op.opID)
                opLock.unlock()
                hub.send(.event(ev))
            } else if ev.knownTopic == .noteAppended,
                      let payload = try? ev.decodeParams(NoteAppendedTopicPayload.self) {
                noteLock.lock()
                let isEcho = awaitingEngineNote.remove(payload.nodeID) != nil
                noteLock.unlock()
                if !isEcho { hub.send(.event(ev)) }
            } else if ev.knownTopic == .sessionState {
                hub.send(.event(ev))
                if let payload = try? ev.decodeParams(SessionStateTopicPayload.self),
                   payload.estado.isViva {
                    noteLock.lock()
                    let shouldAttach = attachedSessions.insert(payload.sessionID).inserted
                    noteLock.unlock()
                    if shouldAttach {
                        remoteApplyQueue.async {
                            let _: SessionAttachResult? = try? eng.call("session.attach", params: try? JSONValue(encoding: SessionAttachParams(
                                sessionID: payload.sessionID
                            )))
                        }
                    }
                }
            } else if ev.knownTopic == .sessionOutput {
                hub.send(.event(ev))
            } else if ev.knownTopic == .watchdogAlert {
                hub.send(.event(ev))
            }
        }
        hub.onEvent = { ev in
            if ev.topic == "sync.session.start",
               let request = try? ev.decodeParams(SyncSessionStartRequest.self) {
                remoteApplyQueue.async {
                    do {
                        let params = request.start
                        let result: SessionResult = try eng.call("session.start", params: try JSONValue(encoding: params))
                        noteLock.lock()
                        nodeToWorkspace[params.nodeID] = params.workspaceID
                        let shouldAttach = attachedSessions.insert(result.session.id).inserted
                        noteLock.unlock()
                        hub.send(.event(EventMessage(topic: .sessionState, params: .object([
                            "session_id": .string(result.session.id.string),
                            "workspace_id": .string(params.workspaceID.string),
                            "node_id": .string(params.nodeID.string),
                            "estado": .string(result.session.estado.rawValue)
                        ]))))
                        if shouldAttach {
                            let _: SessionAttachResult = try eng.call("session.attach", params: try JSONValue(encoding: SessionAttachParams(
                                sessionID: result.session.id
                            )))
                        }
                        hub.send(.event(EventMessage(
                            topic: "sync.session.start.result",
                            params: try JSONValue(encoding: SyncSessionStartResult(
                                requestID: request.requestID, session: result.session
                            ))
                        )))
                    } catch {
                        print("remote session.start FAILED: \(error)")
                        let protocolError = (error as? ProtocolError) ?? ProtocolError(
                            name: .internal_error, message: "\(error)")
                        if let response = try? JSONValue(encoding: SyncSessionStartResult(
                            requestID: request.requestID, error: protocolError
                        )) {
                            hub.send(.event(EventMessage(
                                topic: "sync.session.start.result", params: response
                            )))
                        }
                    }
                }
            } else if ev.topic == "sync.session.input",
               let params = try? ev.decodeParams(SessionInputParams.self) {
                remoteApplyQueue.async {
                    do { try eng.callVoid("session.input", params: try JSONValue(encoding: params)) }
                    catch { print("remote session.input FAILED: \(error)") }
                }
            } else if ev.topic == "sync.session.resize",
                      let params = try? ev.decodeParams(SessionResizeParams.self) {
                remoteApplyQueue.async {
                    do { try eng.callVoid("session.resize", params: try JSONValue(encoding: params)) }
                    catch { print("remote session.resize FAILED: \(error)") }
                }
            } else if ev.knownTopic == .documentOp,
               let payload = try? ev.decodeParams(DocumentOpTopicPayload.self) {
                opLock.lock()
                if awaitingHubEcho.remove(payload.op.opID) != nil {
                    opLock.unlock()
                    return
                }
                awaitingEngineEcho.insert(payload.op.opID)
                opLock.unlock()
                remoteApplyQueue.async {
                    do {
                        try eng.callVoid("doc.apply", params: try JSONValue(encoding: DocApplyParams(
                            workspaceID: payload.workspaceID,
                            ops: [payload.op]
                        )))
                    } catch {
                        opLock.lock()
                        awaitingEngineEcho.remove(payload.op.opID)
                        opLock.unlock()
                        print("remote doc.apply FAILED: \(error)")
                    }
                }
            } else if ev.knownTopic == .noteAppended,
                      let payload = try? ev.decodeParams(NoteAppendedTopicPayload.self),
                      let conteudo = payload.conteudo {
                noteLock.lock()
                let workspaceID = nodeToWorkspace[payload.nodeID]
                if workspaceID != nil { awaitingEngineNote.insert(payload.nodeID) }
                noteLock.unlock()
                guard let workspaceID else { return }
                remoteApplyQueue.async {
                    do {
                        try eng.callVoid("note.replace", params: try JSONValue(encoding: NoteReplaceParams(
                            workspaceID: workspaceID, nodeID: payload.nodeID, conteudo: conteudo
                        )))
                    } catch {
                        noteLock.lock()
                        awaitingEngineNote.remove(payload.nodeID)
                        noteLock.unlock()
                        print("remote note.replace FAILED: \(error)")
                    }
                }
            }
        }
        try eng.callVoid("subscribe", params: try JSONValue(encoding: SubscribeParams(
            topics: [.documentOp, .sessionState, .sessionOutput, .noteAppended, .watchdogAlert]
        )))
        print("engine: subscribed")

        eng.onDisconnect = { exit(1) }
        hub.onDisconnect = { exit(1) }

        for ws in list {
            let open: WorkspaceOpenResult = try eng.call("workspace.open", params: try JSONValue(encoding: ["id": ws.id.string]))
            let nodes = open.documentSnapshot.nodes
            let conns = open.documentSnapshot.connections
            let seq = open.documentSnapshot.seq
            noteLock.lock()
            for node in nodes { nodeToWorkspace[node.id] = ws.id }
            noteLock.unlock()

            // Conteúdo editado no Hub enquanto o Mac estava offline é autoritativo.
            // Aplique-o no arquivo local antes de montar e enviar o novo snapshot.
            if let remote: WorkspaceOpenResult = try? hub.call("workspace.open",
                params: try JSONValue(encoding: ["id": ws.id.string])),
               let remoteNotes = remote.documentSnapshot.noteContents {
                let localNodeIDs = Set(nodes.map(\.id))
                for (nodeIDString, conteudo) in remoteNotes {
                    guard let nodeID = ULID(nodeIDString), localNodeIDs.contains(nodeID) else { continue }
                    noteLock.lock(); awaitingEngineNote.insert(nodeID); noteLock.unlock()
                    do {
                        try eng.callVoid("note.replace", params: try JSONValue(encoding: NoteReplaceParams(
                            workspaceID: ws.id, nodeID: nodeID, conteudo: conteudo
                        )))
                    } catch {
                        noteLock.lock(); awaitingEngineNote.remove(nodeID); noteLock.unlock()
                        print("remote startup note.replace FAILED: \(error)")
                    }
                }
            }

            // Coleta conteúdos de notas
            var noteContents: [String: String] = [:]
            for n in nodes {
                if case .nota(let nota) = n {
                    let noteParams: [String: JSONValue] = [
                        "workspace_id": .string(ws.id.string),
                        "node_id": .string(nota.id.string)
                    ]
                    if let rec: NoteRecord = try? eng.call("note.get", params: try JSONValue(encoding: noteParams)) {
                        noteContents[nota.id.string] = rec.conteudo
                        print("    nota \(nota.id) → \(rec.conteudo.utf8.count) bytes")
                    }
                }
            }

            // Coleta estados e output das sessões
            var sessionStates: [[String: String]] = []
            var sessionOutputs: [String: [[String: String]]] = [:]
            if let sessions: [Session] = try? eng.call("session.list",
                params: try JSONValue(encoding: ["workspace_id": ws.id.string])) {
                for s in sessions {
                    var lastReplaySeq: UInt64 = 0
                    sessionStates.append([
                        "session_id": s.id.string,
                        "estado": s.estado.rawValue,
                        "node_id": s.nodeID.string,
                        "updated_at": ISO8601DateFormatter().string(from: s.estadoDesde ?? s.encerradaEm ?? s.iniciadaEm)
                    ])
                    if let replay: SessionReplayResult = try? eng.call("session.replay",
                        // Um replay inteiro pode ter dezenas de milhares de eventos e
                        // ultrapassar o limite de backpressure antes de sair do Engine.
                        // O snapshot web precisa só de contexto inicial, não do journal todo.
                        params: try JSONValue(encoding: SessionReplayParams(
                            sessionID: s.id,
                            limit: 500
                        )),
                        timeout: 3) {
                        var buf: [[String: String]] = []
                        for ev in replay.events.suffix(500) {
                            lastReplaySeq = max(lastReplaySeq, ev.seq)
                            if case .output(let o) = ev.payload,
                               let data = Data(base64Encoded: o.dataB64),
                               let text = String(data: data, encoding: .utf8) {
                                buf.append(["kind": "output", "data_b64": o.dataB64,
                                            "text": text, "seq": String(ev.seq)])
                            } else if case .resize(let resize) = ev.payload {
                                buf.append(["kind": "resize", "cols": String(resize.cols),
                                            "rows": String(resize.rows), "seq": String(ev.seq)])
                            } else if case .system(let system) = ev.payload {
                                buf.append(["kind": "system", "text": "\n[sistema] \(system.message)\n", "seq": String(ev.seq)])
                            } else if case .message(let message) = ev.payload {
                                buf.append(["kind": "message", "text": "\n[mensagem \(message.direcao.rawValue)] \(message.texto)\n", "seq": String(ev.seq)])
                            }
                        }
                        sessionOutputs[s.id.string] = buf
                        print("    sessão \(s.id) → \(replay.events.count) eventos, enviando \(buf.count)")
                    }
                    if s.estado.isViva {
                        let attach: SessionAttachResult? = try? eng.call("session.attach",
                            params: try JSONValue(encoding: SessionAttachParams(
                                sessionID: s.id,
                                desdeSeq: lastReplaySeq > 0 ? lastReplaySeq + 1 : nil
                            )), timeout: 5)
                        if attach != nil {
                            noteLock.lock(); attachedSessions.insert(s.id); noteLock.unlock()
                        }
                    }
                }
            }

            // Envia snapshot completo e atômico para o Hub
            let encodedNodes: JSONValue
            let encodedConns: JSONValue
            let encodedNC: JSONValue
            let encodedSS: JSONValue
            let encodedSO: JSONValue
            do {
                encodedNodes = try JSONValue(encoding: nodes)
                encodedConns = try JSONValue(encoding: conns)
                encodedNC = try JSONValue(encoding: noteContents)
                encodedSS = try JSONValue(encoding: sessionStates)
                encodedSO = try JSONValue(encoding: sessionOutputs)
            } catch {
                print("  ERRO codificando snapshot: \(error)")
                _ = try? eng.callVoid("workspace.close",
                    params: try JSONValue(encoding: ["id": ws.id.string]))
                continue
            }
            let watchdog: WatchdogGetResult? = try? eng.call("watchdog.get", params: try JSONValue(encoding:
                WatchdogGetParams(workspaceID: ws.id)
            ))
            var snapshot: [String: JSONValue] = [
                "workspace_id": .string(ws.id.string),
                "nome": .string(ws.nome),
                "seq": .number(Double(seq)),
                "nodes": encodedNodes,
                "connections": encodedConns,
                "note_contents": encodedNC,
                "session_states": encodedSS,
                "session_outputs": encodedSO
            ]
            if let watchdog, let encoded = try? JSONValue(encoding: watchdog.configuration) {
                snapshot["watchdog_configuration"] = encoded
                if let history = watchdog.history,
                   let encodedHistory = try? JSONValue(encoding: history) {
                    snapshot["watchdog_history"] = encodedHistory
                }
            }
            do {
                let encodedSnapshot = try JSONValue(encoding: snapshot)
                try hub.callVoid("workspace.pushSnapshot", params: encodedSnapshot, timeout: 120)
                print("  pushSnapshot OK")
            } catch {
                print("  pushSnapshot FAILED: \(error)")
            }
            print("  \(ws.nome) → \(nodes.count) nós, \(conns.count) conexões, \(noteContents.count) notas, \(sessionStates.count) sessões")

            _ = try? eng.callVoid("workspace.close", params: try JSONValue(encoding: ["id": ws.id.string]))
        }

        print("sync: forwarding events (Ctrl+C)")
        dispatchMain()
    }
}
