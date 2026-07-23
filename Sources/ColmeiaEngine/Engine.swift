import Foundation
import Darwin
import ColmeiaKit

public enum ColmeiaEngineInfo {
    public static let version = ColmeiaVersion.string

    public static func banner() -> String {
        "colmeia-engine \(version) (protocolo v\(ColmeiaVersion.protocolVersion))"
    }
}

public enum EngineStartError: Error, CustomStringConvertible {
    /// §20.5 — lock detido por pid vivo: a segunda instância conecta ao socket existente.
    case alreadyRunning

    public var description: String { "outra instância do engine detém o lock" }
}

/// Daemon headless (§3.1), dono de todo estado autoritativo. Toda mutação de estado
/// roda na `stateQueue` (serial); I/O de PTY e de clientes roda em queues próprias e
/// converge para cá. A UI/CLI só falam com isto pelo protocolo §6 sobre o socket.
public final class Engine: @unchecked Sendable {
    public let paths: ColmeiaPaths
    public let registry: AdapterRegistry
    let log: EngineLog
    let stateQueue = DispatchQueue(label: "colmeia.engine.state")
    let startedAt = Date()
    /// Diretório injetado no PATH das sessões — a CLI `colmeia` mora ao lado do engine (§10.2).
    let cliDirectory: String

    // Estado (só na stateQueue)
    var workspaces: [ULID: WorkspaceState] = [:]
    var openWorkspaces: Set<ULID> = []
    var sessions: [ULID: LiveSession] = [:]
    var sessionMetas: [ULID: Session] = [:]
    var nodeSessions: [ULID: ULID] = [:]
    var approvals: [ULID: Approval] = [:]
    var routines: [ULID: Routine] = [:]
    var routineFalhas: [ULID: Int] = [:]
    var floors: [ULID: Floor] = [:]
    var activeFloor: [ULID: ULID] = [:]
    var blockingWaits: [ULID: BlockingWait] = [:]
    /// destino (node) → remetente (node) com ask bloqueante em voo — limite de profundidade §14.2.
    var blockingWaiters: [ULID: ULID] = [:]
    var clients: [ObjectIdentifier: ClientConnection] = [:]

    private var server: SocketServer?
    private var lockFD: Int32 = -1
    private var shuttingDown = false
    private var flushTimer: DispatchSourceTimer?
    private var tickTimer: DispatchSourceTimer?

    public init(paths: ColmeiaPaths = ColmeiaPaths(), registry: AdapterRegistry = .standard()) {
        self.paths = paths
        self.registry = registry
        self.log = EngineLog(url: paths.engineLog)
        let executablePath = CommandLine.arguments.first ?? ""
        self.cliDirectory = URL(fileURLWithPath: executablePath)
            .resolvingSymlinksInPath().deletingLastPathComponent().path
    }

    // MARK: - Ciclo de vida (§24.1)

    public func start() throws {
        try paths.ensureRootLayout()
        guard let fd = InstanceLock.acquire(at: paths.engineLock) else {
            throw EngineStartError.alreadyRunning
        }
        lockFD = fd
        scanWorkspaces() // ainda sem concorrência: servidor e timers só sobem depois
        let server = SocketServer(path: paths.engineSocket.path, engine: self)
        try server.start()
        self.server = server
        startTimers()
        log.info("engine_start", ColmeiaEngineInfo.banner())
    }

    /// Encerramento gracioso síncrono — para testes e para o handler de sinais.
    public func stop() {
        let done = DispatchSemaphore(value: 0)
        stateQueue.async {
            self.performShutdown(exitProcess: false) { done.signal() }
        }
        _ = done.wait(timeout: .now() + 15)
        if lockFD >= 0 {
            close(lockFD)
            lockFD = -1
        }
    }

    public func requestShutdown(exitProcess: Bool) {
        stateQueue.async {
            self.performShutdown(exitProcess: exitProcess, completion: nil)
        }
    }

    private func startTimers() {
        let flush = DispatchSource.makeTimerSource(queue: stateQueue)
        flush.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500))
        flush.setEventHandler { [weak self] in self?.flushTick() }
        flush.resume()
        flushTimer = flush

        let tick = DispatchSource.makeTimerSource(queue: stateQueue)
        tick.schedule(deadline: .now() + 1, repeating: 1)
        tick.setEventHandler { [weak self] in self?.schedulerTick() }
        tick.resume()
        tickTimer = tick
    }

    /// Flush de journals ≤ 1s (§8.1) — tick de 500 ms.
    private func flushTick() {
        for session in sessions.values {
            session.journal.flush()
        }
    }

    /// Tick de 1s (§24.1/§24.4): rotinas, silêncio, escalada TERM→KILL, timeouts de ask.
    private func schedulerTick() {
        guard !shuttingDown else { return }
        let now = Date()
        for session in sessions.values where session.estado.isViva {
            if let deadline = session.killDeadline, deadline <= now, let pty = session.pty {
                if PTY.isAlive(pid: pty.pid) {
                    PTY.signal(pid: pty.pid, SIGKILL)
                }
                session.killDeadline = nil
            }
            if session.estado != .iniciando {
                runHeuristics(session, ultimoChunk: Data())
            }
        }
        for wait in Array(blockingWaits.values) where wait.deadline <= now {
            finishWait(wait, extra: ["timeout": .bool(true)])
        }
        for (id, routine) in routines {
            guard routine.habilitada, let proxima = routine.proximaExecucao, proxima <= now else { continue }
            _ = executeRoutine(id)
        }
    }

    // MARK: - Boot: scan, recuperação, reconciliação

    private func scanWorkspaces() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: paths.workspacesDir, includingPropertiesForKeys: nil)
        else { return }
        for entry in entries {
            guard let wsID = ULID(entry.lastPathComponent) else { continue }
            guard let workspace = try? AtomicJSON.read(Workspace.self, from: paths.workspaceFile(wsID)) else {
                log.warn("workspace_illegivel", "workspace.json ilegível em \(entry.lastPathComponent)")
                continue
            }
            guard let state = try? WorkspaceState(paths: paths, workspace: workspace) else { continue }
            workspaces[wsID] = state
            if let notice = state.corruptionNotice {
                log.warn("document_corrupted", notice, workspaceID: wsID)
            }
            recoverSessions(wsID)
            loadRoutines(wsID)
            loadFloorsAndReconcile(wsID)
        }
    }

    /// §21.3 — sessões vivas no crash viram `morta {engine_crash}`, journals reparados.
    private func recoverSessions(_ wsID: ULID) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: paths.sessionsDir(wsID), includingPropertiesForKeys: nil)
        else { return }
        for entry in entries where entry.lastPathComponent.hasSuffix(".meta.json") {
            guard var meta = try? AtomicJSON.read(Session.self, from: entry) else { continue }
            if meta.estado.isViva {
                let journalURL = paths.sessionJournal(workspace: wsID, session: meta.id)
                let result = JournalReader.read(url: journalURL, repair: true)
                if result.corrupted {
                    log.warn(
                        "journal_corrupted",
                        "\(result.quarantinedBytes) bytes em quarentena",
                        sessionID: meta.id, workspaceID: wsID)
                }
                if let journal = try? SessionJournal(url: journalURL, lastSeq: result.events.last?.seq ?? 0) {
                    journal.append(
                        .state(StateEventPayload(de: meta.estado, para: .morta, motivo: "engine_crash")),
                        author: .sistema)
                    journal.seal()
                }
                meta.estado = .morta
                meta.estadoDesde = Date()
                meta.encerradaEm = Date()
                meta.pid = nil
                try? AtomicJSON.write(meta, to: entry)
            }
            sessionMetas[meta.id] = meta
        }
    }

    private func loadRoutines(_ wsID: ULID) {
        guard let file = try? AtomicJSON.read(RoutinesFile.self, from: paths.routinesFile(wsID)) else { return }
        for var routine in file.routines where routine.workspaceID == wsID {
            // §17.4 — nunca retroativo: recalcula a partir de agora
            routine.proximaExecucao = routine.habilitada
                ? RoutineScheduling.proximaExecucao(
                    agenda: routine.agenda, agora: Date(),
                    jaExecutou: routine.ultimaExecucao != nil)
                : nil
            routines[routine.id] = routine
            if let falhas = file.falhas[routine.id.string] {
                routineFalhas[routine.id] = falhas
            }
        }
    }

    private func saveRoutines(_ wsID: ULID) {
        let list = routines.values.filter { $0.workspaceID == wsID }.sorted { $0.id < $1.id }
        var falhas: [String: Int] = [:]
        for routine in list {
            if let count = routineFalhas[routine.id], count > 0 {
                falhas[routine.id.string] = count
            }
        }
        try? AtomicJSON.write(RoutinesFile(routines: list, falhas: falhas), to: paths.routinesFile(wsID))
    }

    /// §16.4 — reconciliar floors.json × disco na inicialização; NUNCA remover silenciosamente.
    private func loadFloorsAndReconcile(_ wsID: ULID) {
        let fm = FileManager.default
        var list = (try? AtomicJSON.read([Floor].self, from: paths.floorsFile(wsID))) ?? []
        var changed = false
        for index in list.indices where list[index].estado == .ativo {
            var isDir: ObjCBool = false
            if !fm.fileExists(atPath: list[index].caminho, isDirectory: &isDir) || !isDir.boolValue {
                list[index].estado = .orfao
                changed = true
                log.warn("floor_orfao", "registro sem worktree: \(list[index].nome)", workspaceID: wsID)
            }
        }
        if let raiz = workspaces[wsID]?.workspace.caminhoRaiz {
            let base = FloorPaths.base(caminhoRaiz: raiz)
            let registrados = Set(list.filter { $0.estado == .ativo || $0.estado == .orfao }.map {
                URL(fileURLWithPath: $0.caminho).standardizedFileURL.path
            })
            if let dirs = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: base), includingPropertiesForKeys: nil) {
                for dir in dirs {
                    let path = dir.standardizedFileURL.path
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue,
                          !registrados.contains(path)
                    else { continue }
                    list.append(Floor(
                        id: ULID.generate(), nome: dir.lastPathComponent, origem: wsID,
                        mecanismo: .gitWorktree, branch: nil, caminho: path,
                        estado: .orfao, criadoEm: Date(), nos: []))
                    changed = true
                    log.warn("floor_orfao", "worktree sem registro: \(path)", workspaceID: wsID)
                }
            }
        }
        for floor in list {
            floors[floor.id] = floor
        }
        if changed {
            saveFloors(wsID)
            for floor in list where floor.estado == .orfao {
                broadcast(.floorChanged, ws: wsID, FloorChangedTopicPayload(floor: floor))
            }
        }
    }

    private func saveFloors(_ wsID: ULID) {
        let list = floors.values.filter { $0.origem == wsID }.sorted { $0.id < $1.id }
        try? AtomicJSON.write(list, to: paths.floorsFile(wsID))
    }

    // MARK: - Clientes

    func addClient(fd: Int32) {
        guard !shuttingDown else {
            close(fd)
            return
        }
        let client = ClientConnection(fd: fd, engine: self)
        clients[ObjectIdentifier(client)] = client
        client.startReading()
    }

    func dropClient(_ client: ClientConnection, motivo: String) {
        guard clients.removeValue(forKey: ObjectIdentifier(client)) != nil else { return }
        client.closeConnection()
        log.info("client_disconnect", "\(client.clientName): \(motivo)")
    }

    func receive(line: Data, from client: ClientConnection) {
        if let envelope = try? SocketFraming.decodeLine(Envelope.self, from: line) {
            if case .request(let request) = envelope {
                dispatch(request, from: client)
            }
            return
        }
        // §22.5 — malformado: erro se houver id; sem id, ignorado e logado; reincidência → desconexão.
        let now = Date()
        client.malformedTimestamps.append(now)
        client.malformedTimestamps.removeAll { $0 < now.addingTimeInterval(-60) }
        if let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
           let id = object["id"] as? String {
            client.respond(id: id, error: ProtocolError(name: .invalid_params, message: "envelope inválido"))
        } else {
            log.warn("malformed_request", "linha ilegível de \(client.clientName)")
        }
        if client.malformedTimestamps.count > 20 {
            client.send(.event(EventMessage(
                topic: .engineWarning,
                params: (try? JSONValue(encoding: EngineWarningTopicPayload(
                    name: "too_many_malformed", message: "desconectando: excesso de mensagens inválidas"))) ?? .object([:]))))
            dropClient(client, motivo: "reincidência de JSON inválido")
        }
    }

    // MARK: - Publicação de eventos (§6.5)

    func broadcast(_ topic: ColmeiaTopic, ws: ULID?, _ payload: some Encodable) {
        guard let params = try? JSONValue(encoding: payload) else { return }
        let envelope = Envelope.event(EventMessage(topic: topic, params: params))
        for client in clients.values where client.helloDone {
            guard let entry = client.subscriptions[topic] else { continue }
            if let filter = entry, let ws, !filter.contains(ws) { continue }
            client.send(envelope)
        }
    }

    /// `session.output` só para attachados (§6.5), com piso de seq por cliente —
    /// emenda replay+vivo sem buraco nem duplicata (§8.4).
    private func publishOutput(_ session: LiveSession, seq: UInt64, dataB64: String) {
        guard let params = try? JSONValue(encoding: SessionOutputTopicPayload(
            sessionID: session.id, seq: seq, dataB64: dataB64))
        else { return }
        let envelope = Envelope.event(EventMessage(topic: .sessionOutput, params: params))
        for client in clients.values where client.attached.contains(session.id) {
            let floor = client.outputFloor[session.id] ?? 0
            guard seq > floor else { continue }
            client.outputFloor[session.id] = seq
            client.send(envelope)
        }
    }

    // MARK: - Dispatch (§6.4)

    private func respondEncodable(_ client: ClientConnection, id: String, _ value: some Encodable) {
        if let json = try? JSONValue(encoding: value) {
            client.respond(id: id, result: json)
        } else {
            client.respond(id: id, error: ProtocolError(name: .internal_error, message: "falha ao serializar resultado"))
        }
    }

    func dispatch(_ request: RequestMessage, from client: ClientConnection) {
        let method = request.knownMethod
        if !client.helloDone, method != .hello {
            client.respond(id: request.id, error: ProtocolError(
                name: .invalid_params, message: "handshake `hello` é obrigatório antes de \(request.method) (§6.3)"))
            return
        }
        do {
            switch method {
            case .hello:
                respondEncodable(client, id: request.id, try handleHello(request, client))
            case .workspaceList:
                let list = workspaces.values
                    .sorted { $0.workspace.atualizadoEm > $1.workspace.atualizadoEm }
                    .map { state in
                        WorkspaceSummary(
                            id: state.workspace.id, nome: state.workspace.nome,
                            caminhoRaiz: state.workspace.caminhoRaiz,
                            atualizadoEm: state.workspace.atualizadoEm)
                    }
                respondEncodable(client, id: request.id, list)
            case .workspaceCreate:
                respondEncodable(client, id: request.id, try handleWorkspaceCreate(request))
            case .workspaceOpen:
                let params = try request.decodeParams(WorkspaceOpenParams.self)
                let state = try requireWorkspace(params.id)
                state.aberto = true
                openWorkspaces.insert(params.id)
                respondEncodable(client, id: request.id, WorkspaceOpenResult(
                    workspace: state.workspace, documentSnapshot: decoratedSnapshot(state)))
            case .workspaceClose:
                let params = try request.decodeParams(WorkspaceCloseParams.self)
                let state = try requireWorkspace(params.id)
                try? state.writeSnapshot() // §7.4b
                try? state.saveWorkspace()
                state.aberto = false
                openWorkspaces.remove(params.id)
                respondEncodable(client, id: request.id, EmptyResult())
            case .workspaceDelete:
                let params = try request.decodeParams(WorkspaceDeleteParams.self)
                try handleWorkspaceDelete(params)
                respondEncodable(client, id: request.id, EmptyResult())
            case .workspaceUpdate:
                let params = try request.decodeParams(WorkspaceUpdateParams.self)
                let state = try requireWorkspace(params.id)
                if let nome = params.nome { state.workspace.nome = nome }
                if let caminho = params.caminhoRaiz { state.workspace.caminhoRaiz = caminho }
                if let viewport = params.viewport {
                    guard Viewport.zoomRange.contains(viewport.zoom) else {
                        throw ProtocolError(name: .invalid_params, message: "zoom fora de 0.1–4.0 (§5.1)")
                    }
                    state.workspace.viewport = viewport
                }
                state.workspace.atualizadoEm = Date()
                try? state.saveWorkspace()
                respondEncodable(client, id: request.id, WorkspaceResult(workspace: state.workspace))
            case .docApply:
                let params = try request.decodeParams(DocApplyParams.self)
                let state = try requireWorkspace(params.workspaceID)
                var seqFinal = state.seq
                for proposal in params.ops {
                    let applied = try state.applyProposal(proposal, liveNodeIDs: liveNodeIDs)
                    seqFinal = applied.seq ?? seqFinal
                    broadcast(.documentOp, ws: params.workspaceID, DocumentOpTopicPayload(
                        workspaceID: params.workspaceID, op: applied, seq: applied.seq ?? 0))
                }
                try? state.saveWorkspace()
                respondEncodable(client, id: request.id, DocApplyResult(seqFinal: seqFinal))
            case .docSnapshot:
                let params = try request.decodeParams(DocSnapshotParams.self)
                let state = try requireWorkspace(params.workspaceID)
                try? state.writeSnapshot()
                respondEncodable(client, id: request.id, DocSnapshotResult(documentSnapshot: decoratedSnapshot(state)))
            case .docHistory:
                let params = try request.decodeParams(DocHistoryParams.self)
                let state = try requireWorkspace(params.workspaceID)
                respondEncodable(client, id: request.id, DocHistoryResult(
                    ops: state.history(desdeSeq: params.desdeSeq, ateSeq: params.ateSeq)))
            case .sessionStart:
                let params = try request.decodeParams(SessionStartParams.self)
                respondEncodable(client, id: request.id, SessionResult(session: try handleSessionStart(params)))
            case .sessionAttach:
                let params = try request.decodeParams(SessionAttachParams.self)
                respondEncodable(client, id: request.id, try handleSessionAttach(params, client))
            case .sessionInput:
                let params = try request.decodeParams(SessionInputParams.self)
                let live = try requireLiveSession(params.sessionID)
                guard let data = Data(base64Encoded: params.dataB64) else {
                    throw ProtocolError(name: .invalid_params, message: "data_b64 inválido")
                }
                sessionInput(live, data: data, author: client.author, terminalInput: true)
                respondEncodable(client, id: request.id, EmptyResult())
            case .sessionResize:
                let params = try request.decodeParams(SessionResizeParams.self)
                let live = try requireLiveSession(params.sessionID)
                guard params.cols > 0, params.rows > 0 else {
                    throw ProtocolError(name: .invalid_params, message: "geometria inválida")
                }
                live.cols = params.cols
                live.rows = params.rows
                if let pty = live.pty {
                    PTY.resize(master: pty.master, pid: pty.pid, cols: params.cols, rows: params.rows)
                }
                live.journal.append(
                    .resize(ResizeEventPayload(cols: params.cols, rows: params.rows)),
                    author: client.author)
                respondEncodable(client, id: request.id, EmptyResult())
            case .sessionKill:
                let params = try request.decodeParams(SessionKillParams.self)
                let live = try requireLiveSession(params.sessionID)
                if let pty = live.pty {
                    if params.sinal == .kill {
                        PTY.signal(pid: pty.pid, SIGKILL)
                    } else {
                        PTY.signal(pid: pty.pid, SIGTERM) // §9.1.5: TERM → 5s → KILL
                        live.killDeadline = Date().addingTimeInterval(5)
                    }
                }
                respondEncodable(client, id: request.id, EmptyResult())
            case .sessionList:
                let params = try request.decodeParams(SessionListParams.self)
                var list = Array(sessionMetas.values)
                for live in sessions.values {
                    list.removeAll { $0.id == live.id }
                    list.append(live.dto())
                }
                if let wsID = params.workspaceID {
                    list = list.filter { $0.workspaceID == wsID }
                }
                respondEncodable(client, id: request.id, list.sorted { $0.iniciadaEm < $1.iniciadaEm })
            case .sessionReplay:
                let params = try request.decodeParams(SessionReplayParams.self)
                respondEncodable(client, id: request.id, try handleSessionReplay(params))
            case .approvalList:
                let params = try request.decodeParams(ApprovalListParams.self)
                var list = Array(approvals.values)
                if let wsID = params.workspaceID {
                    list = list.filter { sessionMetas[$0.sessionID]?.workspaceID == wsID }
                }
                if let estado = params.estado {
                    list = list.filter { $0.estado == estado }
                }
                respondEncodable(client, id: request.id, list.sorted { $0.criadaEm < $1.criadaEm })
            case .approvalResolve:
                let params = try request.decodeParams(ApprovalResolveParams.self)
                respondEncodable(client, id: request.id, ApprovalResult(
                    approval: try handleApprovalResolve(params, author: client.author)))
            case .messageSend:
                try handleMessageSend(request, client) // responde por conta própria (bloqueante)
            case .noteAppend:
                let params = try request.decodeParams(NoteAppendParams.self)
                respondEncodable(client, id: request.id, try handleNoteAppend(params, author: client.author))
            case .routineCreate:
                let params = try request.decodeParams(RoutineCreateParams.self)
                respondEncodable(client, id: request.id, RoutineResult(routine: try handleRoutineCreate(params)))
            case .routineUpdate:
                let params = try request.decodeParams(RoutineUpdateParams.self)
                respondEncodable(client, id: request.id, RoutineResult(routine: try handleRoutineUpdate(params)))
            case .routineDelete:
                let params = try request.decodeParams(RoutineDeleteParams.self)
                guard let routine = routines.removeValue(forKey: params.id) else {
                    throw ProtocolError(name: .routine_not_found, message: "rotina \(params.id) não existe")
                }
                routineFalhas.removeValue(forKey: params.id)
                saveRoutines(routine.workspaceID)
                respondEncodable(client, id: request.id, EmptyResult())
            case .routineList:
                let params = try request.decodeParams(RoutineListParams.self)
                _ = try requireWorkspace(params.workspaceID)
                let list = routines.values.filter { $0.workspaceID == params.workspaceID }
                    .sorted { $0.id < $1.id }
                respondEncodable(client, id: request.id, list)
            case .routineRunNow:
                let params = try request.decodeParams(RoutineRunNowParams.self)
                guard routines[params.routineID] != nil else {
                    throw ProtocolError(name: .routine_not_found, message: "rotina \(params.routineID) não existe")
                }
                let resultado = executeRoutine(params.routineID)
                respondEncodable(client, id: request.id, RoutineRunNowResult(resultado: resultado))
            case .floorCreate:
                let params = try request.decodeParams(FloorCreateParams.self)
                respondEncodable(client, id: request.id, FloorResult(floor: try handleFloorCreate(params)))
            case .floorSwitch:
                let params = try request.decodeParams(FloorSwitchParams.self)
                respondEncodable(client, id: request.id, try handleFloorSwitch(params))
            case .floorLand:
                let params = try request.decodeParams(FloorLandParams.self)
                try handleFloorLand(params, requestID: request.id, client: client)
            case .floorDiscard:
                let params = try request.decodeParams(FloorDiscardParams.self)
                try handleFloorDiscard(params, requestID: request.id, client: client)
            case .floorList:
                let params = try request.decodeParams(FloorListParams.self)
                _ = try requireWorkspace(params.workspaceID)
                let list = floors.values.filter { $0.origem == params.workspaceID }
                    .sorted { $0.criadoEm < $1.criadoEm }
                respondEncodable(client, id: request.id, list)
            case .subscribe:
                let params = try request.decodeParams(SubscribeParams.self)
                for topic in params.topics {
                    if let wsID = params.workspaceID {
                        if let existing = client.subscriptions[topic], var set = existing {
                            set.insert(wsID)
                            client.subscriptions[topic] = set
                        } else if client.subscriptions[topic] == nil {
                            client.subscriptions[topic] = Set([wsID])
                        } // já assina todos → mantém
                    } else {
                        client.subscriptions[topic] = Set<ULID>?.none
                    }
                }
                respondEncodable(client, id: request.id, EmptyResult())
            case .unsubscribe:
                let params = try request.decodeParams(UnsubscribeParams.self)
                for topic in params.topics {
                    client.subscriptions.removeValue(forKey: topic)
                }
                respondEncodable(client, id: request.id, EmptyResult())
            case .engineStatus:
                let ativas = sessions.values.filter { $0.estado.isViva }.count
                respondEncodable(client, id: request.id, EngineStatusResult(
                    sessionsAtivas: ativas,
                    workspacesAbertos: openWorkspaces.count,
                    uptime: Date().timeIntervalSince(startedAt),
                    versao: ColmeiaVersion.string))
            case .engineShutdown:
                let params = try request.decodeParams(EngineShutdownParams.self)
                guard params.confirmar else {
                    throw ProtocolError(name: .confirmation_required, message: "engine.shutdown exige confirmar: true")
                }
                performShutdown(exitProcess: true) { [weak client] in
                    client?.respond(id: request.id, result: (try? JSONValue(encoding: EmptyResult())) ?? .object([:]))
                }
            case nil:
                throw ProtocolError(name: .invalid_params, message: "método desconhecido: \(request.method)")
            }
        } catch let error as ProtocolError {
            client.respond(id: request.id, error: error)
        } catch is DecodingError {
            client.respond(id: request.id, error: ProtocolError(name: .invalid_params, message: "params inválidos para \(request.method)"))
        } catch {
            client.respond(id: request.id, error: ProtocolError(name: .internal_error, message: "\(error)"))
        }
    }

    // MARK: - Helpers de estado

    func requireWorkspace(_ id: ULID) throws -> WorkspaceState {
        guard let state = workspaces[id] else {
            throw ProtocolError(name: .workspace_not_found, message: "workspace \(id) não existe")
        }
        return state
    }

    func requireLiveSession(_ id: ULID) throws -> LiveSession {
        if let live = sessions[id], live.estado.isViva { return live }
        if sessionMetas[id] != nil {
            throw ProtocolError(name: .session_not_running, message: "sessão \(id) não está rodando")
        }
        throw ProtocolError(name: .session_not_found, message: "sessão \(id) não existe")
    }

    var liveNodeIDs: Set<ULID> {
        Set(sessions.values.filter { $0.estado.isViva }.map { $0.nodeID })
    }

    /// TerminalNode.session_id é estado de runtime: decorado na resposta, nunca persistido.
    func decoratedSnapshot(_ state: WorkspaceState) -> DocumentSnapshot {
        var snapshot = state.snapshot()
        snapshot.nodes = snapshot.nodes.map { node in
            guard case .terminal(var terminal) = node else { return node }
            if let sid = nodeSessions[terminal.id], sessions[sid]?.estado.isViva == true {
                terminal.sessionID = sid
            } else {
                terminal.sessionID = nil
            }
            return .terminal(terminal)
        }
        return snapshot
    }

    // MARK: - hello (§6.3)

    private func handleHello(_ request: RequestMessage, _ client: ClientConnection) throws -> HelloResult {
        let params = try request.decodeParams(HelloParams.self)
        guard params.protocolVersion == ColmeiaVersion.protocolVersion else {
            throw ProtocolError(
                name: .protocol_version_mismatch,
                message: "engine fala v\(ColmeiaVersion.protocolVersion), cliente pediu v\(params.protocolVersion)")
        }
        var author = params.author
        if case .agente(let nodeIDString) = author {
            let exists = ULID(nodeIDString).map { nid in
                workspaces.values.contains { $0.nodes[nid] != nil }
            } ?? false
            if !exists { author = .humanoLocal } // §6.3: node inexistente → humano:local
        }
        client.author = author
        client.clientName = params.client
        client.helloDone = true
        return HelloResult(
            protocolVersion: ColmeiaVersion.protocolVersion,
            engineVersion: ColmeiaVersion.string,
            engineStartedEm: startedAt)
    }

    // MARK: - workspace.*

    private func handleWorkspaceCreate(_ request: RequestMessage) throws -> WorkspaceResult {
        let params = try request.decodeParams(WorkspaceCreateParams.self)
        guard !params.nome.isEmpty else {
            throw ProtocolError(name: .invalid_params, message: "nome vazio")
        }
        let now = Date()
        let workspace = Workspace(
            id: ULID.generate(), nome: params.nome, caminhoRaiz: params.caminhoRaiz,
            viewport: Viewport(), criadoEm: now, atualizadoEm: now)
        let state = try WorkspaceState(paths: paths, workspace: workspace)
        try state.saveWorkspace()
        workspaces[workspace.id] = state
        return WorkspaceResult(workspace: workspace)
    }

    private func handleWorkspaceDelete(_ params: WorkspaceDeleteParams) throws {
        _ = try requireWorkspace(params.id)
        guard params.confirmar else {
            throw ProtocolError(name: .confirmation_required, message: "workspace.delete exige confirmar: true")
        }
        let vivas = sessions.values.contains { $0.workspaceID == params.id && $0.estado.isViva }
        guard !vivas else {
            throw ProtocolError(name: .session_already_running, message: "workspace tem sessões ativas (§6.4)")
        }
        workspaces.removeValue(forKey: params.id)
        openWorkspaces.remove(params.id)
        for (id, routine) in routines where routine.workspaceID == params.id {
            routines.removeValue(forKey: id)
            routineFalhas.removeValue(forKey: id)
            _ = routine
        }
        for (id, floor) in floors where floor.origem == params.id {
            floors.removeValue(forKey: id)
            _ = floor
        }
        for (id, meta) in sessionMetas where meta.workspaceID == params.id {
            sessionMetas.removeValue(forKey: id)
            _ = meta
        }
        try? FileManager.default.removeItem(at: paths.workspaceDir(params.id))
    }

    // MARK: - session.* (§9, §24.2, §24.3)

    private func handleSessionStart(_ params: SessionStartParams) throws -> Session {
        let state = try requireWorkspace(params.workspaceID)
        guard let node = state.terminalNode(params.nodeID) else {
            throw ProtocolError(name: .node_not_found, message: "TerminalNode \(params.nodeID) não existe")
        }
        if let sid = nodeSessions[params.nodeID], sessions[sid]?.estado.isViva == true {
            throw ProtocolError(name: .session_already_running, message: "nó já tem sessão viva: \(sid)")
        }
        guard let adapter = registry.find(node.adapter) else {
            throw ProtocolError(name: .adapter_not_found, message: "adapter \(node.adapter) não registrado")
        }
        let plan = adapter.launch(LaunchConfig(node: node, workspace: state.workspace))
        var executable = plan.executavel
        var args = plan.args
        if let override = node.comandoOverride, !override.isEmpty {
            // §10.2 — override substitui executável+args do adapter, mantendo a env
            executable = "/bin/sh"
            args = ["-c", override]
        } else if !adapter.disponivel() {
            throw ProtocolError(name: .adapter_launch_failed, message: "binário de \(node.adapter) não encontrado (§22.2)")
        }

        let sessionID = ULID.generate()
        var env = ProcessInfo.processInfo.environment
        for (key, value) in plan.envExtra { env[key] = value }
        env[ColmeiaEnv.socket] = paths.engineSocket.path
        env[ColmeiaEnv.sessionID] = sessionID.string
        env[ColmeiaEnv.nodeID] = node.id.string
        env[ColmeiaEnv.workspaceID] = state.workspace.id.string
        env["TERM"] = "xterm-256color"
        env["PATH"] = cliDirectory + ":" + (env["PATH"] ?? "/usr/bin:/bin")

        var cwd = node.cwd
        if cwd.isEmpty { cwd = state.workspace.caminhoRaiz ?? NSHomeDirectory() }
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir) || !isDir.boolValue {
            cwd = NSHomeDirectory()
        }

        let journal = try SessionJournal(url: paths.sessionJournal(workspace: params.workspaceID, session: sessionID))
        let live = LiveSession(
            id: sessionID, workspaceID: params.workspaceID, nodeID: node.id, nodeNome: node.nome,
            adapterID: node.adapter, monitorar: node.monitorarAtividade, journal: journal,
            cols: 120, rows: 32)
        do {
            live.pty = try PTY.spawn(
                executable: executable, args: args, environment: env, cwd: cwd,
                cols: live.cols, rows: live.rows)
        } catch {
            journal.append(
                .state(StateEventPayload(de: .iniciando, para: .morta, motivo: "adapter_launch_failed")),
                author: .sistema)
            journal.seal()
            live.estado = .morta
            live.estadoDesde = Date()
            live.encerradaEm = Date()
            live.exited = true
            saveMeta(live.dto())
            throw ProtocolError(name: .adapter_launch_failed, message: "\(error)")
        }
        sessions[sessionID] = live
        nodeSessions[node.id] = sessionID
        saveMeta(live.dto())
        startReader(live)
        log.info("session_start", "\(node.nome) (\(node.adapter))", sessionID: sessionID, workspaceID: params.workspaceID)
        return live.dto()
    }

    private func startReader(_ live: LiveSession) {
        guard let pty = live.pty else { return }
        let master = pty.master
        let pid = pty.pid
        let queue = DispatchQueue(label: "colmeia.session.read.\(live.id.string)")
        queue.async { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 32 * 1024) // §9.4 — chunk máx 32 KiB
            while true {
                let count = read(master, &buffer, buffer.count)
                if count > 0 {
                    let chunk = Data(bytes: buffer, count: count)
                    // §24.2 — journal primeiro, publicação depois
                    let event = live.journal.append(
                        .output(OutputEventPayload(dataB64: chunk.base64EncodedString())),
                        author: .agente(live.nodeID.string))
                    guard let self, let event else { continue }
                    self.stateQueue.async {
                        self.onOutput(live, chunk: chunk, seq: event.seq)
                    }
                } else if count < 0 && errno == EINTR {
                    continue
                } else {
                    break // EOF/EIO — processo saiu
                }
            }
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            self?.stateQueue.async {
                self?.onExit(live, status: status)
            }
        }
    }

    private func onOutput(_ session: LiveSession, chunk: Data, seq: UInt64) {
        session.lastOutputAt = Date()
        session.lastActivityAt = session.lastOutputAt
        session.appendRecent(chunk)
        if let wait = blockingWaits[session.id], wait.delivered {
            wait.accum.append(chunk)
            wait.sawOutput = true
        }
        publishOutput(session, seq: seq, dataB64: chunk.base64EncodedString())
        if session.estado == .iniciando {
            transition(session, to: .rodando, motivo: "primeiro_output") // §11.2
        } else if session.estado == .ociosa {
            transition(session, to: .rodando, motivo: "output")
        }
        runHeuristics(session, ultimoChunk: chunk)
    }

    private func onExit(_ session: LiveSession, status: Int32) {
        guard !session.exited else { return }
        session.exited = true
        session.killDeadline = nil
        let exitedNormally = (status & 0x7F) == 0
        let code = (status >> 8) & 0xFF
        let final: SessionEstado = (exitedNormally && code == 0) ? .encerrada : .morta
        let motivo = exitedNormally ? "exit_\(code)" : "sinal_\(status & 0x7F)"
        if session.pendingApprovalID != nil {
            finalizePendingApproval(session, como: .expirada, motivo: "sessao_encerrou")
        }
        transition(session, to: final, motivo: motivo)
        session.journal.seal()
        if let pty = session.pty {
            close(pty.master)
            session.pty = nil
        }
        if nodeSessions[session.nodeID] == session.id {
            nodeSessions.removeValue(forKey: session.nodeID)
        }
        if let wait = blockingWaits[session.id] {
            finishWait(wait, extra: ["erro": .string("sessao_encerrada")])
        }
        session.fila.removeAll()
        saveMeta(session.dto())
        sessions.removeValue(forKey: session.id)
        log.info("session_end", motivo, sessionID: session.id, workspaceID: session.workspaceID)
    }

    /// §24.3 — journal ANTES do PTY.
    func sessionInput(_ session: LiveSession, data: Data, author: Author, terminalInput: Bool) {
        session.journal.append(.input(InputEventPayload(dataB64: data.base64EncodedString())), author: author)
        if let pty = session.pty {
            _ = PTY.writeAll(fd: pty.master, data)
        }
        session.lastActivityAt = Date()
        if terminalInput, session.pendingApprovalID != nil {
            session.inputSincePendingApproval = true // §12.1b
        }
        if session.estado == .esperandoHumano || session.estado == .ociosa {
            transition(session, to: .rodando, motivo: "input")
        }
    }

    private func handleSessionAttach(_ params: SessionAttachParams, _ client: ClientConnection) throws -> SessionAttachResult {
        let desde = params.desdeSeq ?? 1
        let dto: Session
        let journalURL: URL
        if let live = sessions[params.sessionID] {
            dto = live.dto()
            journalURL = live.journal.url
        } else if let meta = sessionMetas[params.sessionID] {
            dto = meta
            journalURL = meta.journal.map { URL(fileURLWithPath: $0) }
                ?? paths.sessionJournal(workspace: meta.workspaceID, session: meta.id)
        } else {
            throw ProtocolError(name: .session_not_found, message: "sessão \(params.sessionID) não existe")
        }
        let events = JournalReader.read(url: journalURL, repair: false).events.filter { $0.seq >= desde }
        client.attached.insert(params.sessionID)
        let floor = max(events.last?.seq ?? 0, client.outputFloor[params.sessionID] ?? 0)
        client.outputFloor[params.sessionID] = floor
        return SessionAttachResult(session: dto, replay: events)
    }

    private func handleSessionReplay(_ params: SessionReplayParams) throws -> SessionReplayResult {
        let journalURL: URL
        if let live = sessions[params.sessionID] {
            journalURL = live.journal.url
        } else if let meta = sessionMetas[params.sessionID] {
            journalURL = meta.journal.map { URL(fileURLWithPath: $0) }
                ?? paths.sessionJournal(workspace: meta.workspaceID, session: meta.id)
        } else {
            throw ProtocolError(name: .session_not_found, message: "sessão \(params.sessionID) não existe")
        }
        var events = JournalReader.read(url: journalURL, repair: false).events
        if let desde = params.desdeSeq { events = events.filter { $0.seq >= desde } }
        if let ate = params.ateSeq { events = events.filter { $0.seq <= ate } }
        return SessionReplayResult(events: events)
    }

    func saveMeta(_ dto: Session) {
        sessionMetas[dto.id] = dto
        try? AtomicJSON.write(dto, to: metaURL(workspace: dto.workspaceID, session: dto.id))
    }

    private func metaURL(workspace: ULID, session: ULID) -> URL {
        paths.sessionsDir(workspace).appendingPathComponent("\(session.string).meta.json")
    }

    // MARK: - Máquina de estados (§11)

    func transition(_ session: LiveSession, to novo: SessionEstado, motivo: String?) {
        guard session.estado != novo else { return }
        let de = session.estado
        session.estado = novo
        session.estadoDesde = Date()
        if !novo.isViva {
            session.encerradaEm = Date()
        }
        session.journal.append(
            .state(StateEventPayload(de: de, para: novo, motivo: motivo)), author: .sistema)
        broadcast(.sessionState, ws: session.workspaceID, SessionStateTopicPayload(
            sessionID: session.id, estado: novo, motivo: motivo))
        saveMeta(session.dto())
        if novo == .esperandoHumano || novo == .ociosa {
            completeBlockingWait(session) // resposta antes da próxima entrega
            deliverQueued(session) // §14.2 entrega adiada
        }
    }

    // MARK: - Heurísticas (§10.3–10.5)

    private func runHeuristics(_ session: LiveSession, ultimoChunk: Data) {
        guard session.estado.isViva, session.estado != .iniciando else { return }
        guard session.monitorar, !session.degraded, let adapter = registry.find(session.adapterID) else {
            fallbackClassify(session)
            return
        }
        let contexto = session.contexto(ultimoChunk: ultimoChunk)
        do {
            if let draft = try adapter.detectApproval(contexto) {
                upsertApproval(session, draft: draft)
                return
            }
            if session.pendingApprovalID != nil {
                // prompt sumiu (§10.4): resolvida no terminal ou expirada
                finalizePendingApproval(
                    session,
                    como: session.inputSincePendingApproval ? .resolvidaNoTerminal : .expirada,
                    motivo: "prompt_sumiu")
            }
            if let estado = try adapter.classify(contexto) {
                applyClassified(session, estado)
            } else {
                fallbackClassify(session)
            }
        } catch {
            degrade(session, error: error)
        }
    }

    private func applyClassified(_ session: LiveSession, _ estado: SessionEstado) {
        guard session.pendingApprovalID == nil else { return } // preso em aprovacao_pendente até resolver
        switch estado {
        case .rodando, .esperandoHumano, .ociosa:
            transition(session, to: estado, motivo: "classify")
        default:
            break // aprovacao_pendente vem pela via do detect; estados finais vêm do processo
        }
    }

    /// shell e qualquer classify nil: rodando/ociosa por atividade de I/O (§10.3).
    private func fallbackClassify(_ session: LiveSession) {
        guard session.pendingApprovalID == nil else { return }
        if session.estado == .rodando, session.silencioSeg > AdapterHeuristics.limiarOciosaSeg {
            transition(session, to: .ociosa, motivo: "silencio")
        }
    }

    /// §10.5 — falha de heurística nunca degrada o terminal.
    private func degrade(_ session: LiveSession, error: Error) {
        guard !session.degraded else { return }
        session.degraded = true
        session.journal.append(
            .system(SystemEventPayload(name: "adapter_degradado", message: "\(error)")),
            author: .sistema)
        broadcast(.engineWarning, ws: session.workspaceID, EngineWarningTopicPayload(
            name: "adapter_degradado",
            message: "heurística de \(session.adapterID) falhou; sessão \(session.id) segue como shell comum"))
        log.warn("adapter_degradado", "\(error)", sessionID: session.id, workspaceID: session.workspaceID)
    }

    // MARK: - Aprovações (§12, §24.5)

    private func upsertApproval(_ session: LiveSession, draft: ApprovalDraft) {
        if let pendingID = session.pendingApprovalID, var approval = approvals[pendingID] {
            // §12.2 — mesmo pedido re-renderizado: atualiza, não duplica
            if approval.resumo != draft.resumo || approval.opcoes != draft.opcoes {
                approval.resumo = draft.resumo
                approval.opcoes = draft.opcoes
                approvals[pendingID] = approval
            }
            if session.estado != .aprovacaoPendente {
                transition(session, to: .aprovacaoPendente, motivo: "approval")
            }
            return
        }
        let approval = Approval(
            id: ULID.generate(), sessionID: session.id, nodeNome: session.nodeNome,
            resumo: draft.resumo, opcoes: draft.opcoes, estado: .pendente, criadaEm: Date())
        approvals[approval.id] = approval
        session.pendingApprovalID = approval.id
        session.inputSincePendingApproval = false
        session.journal.append(
            .approval(ApprovalEventPayload(approvalID: approval.id, acao: .criada)), author: .sistema)
        broadcast(.approvalCreated, ws: session.workspaceID, ApprovalTopicPayload(approval: approval))
        transition(session, to: .aprovacaoPendente, motivo: "approval_detectada")
    }

    private func finalizePendingApproval(_ session: LiveSession, como estado: ApprovalEstado, motivo: String) {
        guard let pendingID = session.pendingApprovalID else { return }
        session.pendingApprovalID = nil
        let hadInput = session.inputSincePendingApproval
        session.inputSincePendingApproval = false
        guard var approval = approvals[pendingID], approval.estado == .pendente else { return }
        approval.estado = estado
        approval.resolvidaEm = Date()
        if estado == .resolvidaNoTerminal, hadInput {
            approval.resolvidaPor = .humanoLocal
        }
        approvals[pendingID] = approval
        session.journal.append(
            .approval(ApprovalEventPayload(approvalID: pendingID, acao: .resolvida)), author: .sistema)
        broadcast(.approvalResolved, ws: session.workspaceID, ApprovalTopicPayload(approval: approval))
        if session.estado == .aprovacaoPendente, session.estado.isViva {
            transition(session, to: .rodando, motivo: motivo)
        }
    }

    private func handleApprovalResolve(_ params: ApprovalResolveParams, author: Author) throws -> Approval {
        guard var approval = approvals[params.approvalID] else {
            throw ProtocolError(name: .approval_not_found, message: "approval \(params.approvalID) não existe")
        }
        guard approval.estado == .pendente else {
            throw ProtocolError(name: .approval_already_resolved, message: "estado atual: \(approval.estado.rawValue)")
        }
        guard let live = sessions[approval.sessionID], live.estado.isViva else {
            throw ProtocolError(name: .session_not_running, message: "sessão da approval não está viva")
        }
        guard let adapter = registry.find(live.adapterID),
              let bytes = adapter.injectReply(approval, decisao: params.decisao, opcaoIndex: params.opcaoIndex),
              !bytes.isEmpty
        else {
            // §10.4 — nunca chutar bytes
            throw ProtocolError(name: .invalid_params, message: "adapter não mapeia essa resposta")
        }
        sessionInput(live, data: bytes, author: author, terminalInput: false)
        approval.estado = params.decisao == .aprovar ? .aprovada : .negada
        approval.resolvidaEm = Date()
        approval.resolvidaPor = author
        approvals[approval.id] = approval
        live.pendingApprovalID = nil
        live.inputSincePendingApproval = false
        live.journal.append(
            .approval(ApprovalEventPayload(approvalID: approval.id, acao: .resolvida, decisao: params.decisao)),
            author: author)
        broadcast(.approvalResolved, ws: live.workspaceID, ApprovalTopicPayload(approval: approval))
        if live.estado == .aprovacaoPendente {
            transition(live, to: .rodando, motivo: "approval_resolvida")
        }
        return approval
    }

    // MARK: - Mensageria (§14)

    /// Limite da fila FIFO por destino (definido-pela-implementação, §14.2).
    static let filaMaxPorDestino = 32
    static let askTimeoutDefaultSeg = 300

    private func handleMessageSend(_ request: RequestMessage, _ client: ClientConnection) throws {
        let params = try request.decodeParams(MessageSendParams.self)
        let state = try requireWorkspace(params.workspaceID)
        guard state.nodes[params.deNode] != nil else {
            throw ProtocolError(name: .node_not_found, message: "remetente \(params.deNode) não existe")
        }
        guard let destino = state.terminalPorNome(params.paraNome) else {
            throw ProtocolError(name: .node_not_found, message: "nenhum nó chamado \"\(params.paraNome)\"")
        }
        guard let destSid = nodeSessions[destino.id], let dest = sessions[destSid], dest.estado.isViva else {
            throw ProtocolError(name: .node_not_found, message: "\"\(params.paraNome)\" está sem sessão viva (§14.1)")
        }
        // timeout_seg == 0 → --no-wait; ausente → bloqueante com default
        let timeoutSeg = params.timeoutSeg ?? Engine.askTimeoutDefaultSeg
        let blocking = timeoutSeg > 0
        if blocking {
            var depth = 1
            var cursor = params.deNode
            while let waiter = blockingWaiters[cursor], depth <= 8 {
                depth += 1
                cursor = waiter
            }
            guard depth <= 4 else {
                throw ProtocolError(name: .invalid_params, message: "profundidade de conversa bloqueante excede 4 (§14.2)")
            }
            guard blockingWaits[destSid] == nil else {
                throw ProtocolError(name: .invalid_params, message: "destino já tem ask bloqueante em andamento")
            }
        }
        let messageID = ULID.generate()
        // §14.1.2 — journal do remetente
        if let senderSid = nodeSessions[params.deNode], let sender = sessions[senderSid] {
            sender.journal.append(
                .message(MessageEventPayload(
                    direcao: .enviada, contraparte: destino.id, texto: params.texto, messageID: messageID)),
                author: .agente(params.deNode.string))
        }
        let message = QueuedMessage(id: messageID, deNode: params.deNode, texto: params.texto, enqueuedAt: Date())
        if blocking {
            let requestID = request.id
            let wait = BlockingWait(
                messageID: messageID, senderNode: params.deNode, destNode: destino.id,
                destSession: destSid, deadline: Date().addingTimeInterval(Double(timeoutSeg)),
                respond: { [weak client] value in
                    client?.respond(id: requestID, result: value)
                })
            blockingWaits[destSid] = wait
            blockingWaiters[destino.id] = params.deNode
        }
        if dest.estado == .esperandoHumano || dest.estado == .ociosa {
            deliver(message, to: dest)
        } else {
            guard dest.fila.count < Engine.filaMaxPorDestino else {
                if let wait = blockingWaits[destSid], wait.messageID == messageID {
                    blockingWaits.removeValue(forKey: destSid)
                    blockingWaiters.removeValue(forKey: destino.id)
                }
                dest.journal.append(
                    .system(SystemEventPayload(name: "fila_cheia", message: "mensagem de \(params.deNode) recusada")),
                    author: .sistema)
                throw ProtocolError(name: .invalid_params, message: "fila de entrega do destino cheia (§22.4)")
            }
            dest.fila.append(message) // §14.2 — nunca atropelar um agente no meio de um turno
        }
        if !blocking {
            respondEncodable(client, id: request.id, MessageSendResult(messageID: messageID))
        }
    }

    private func deliver(_ message: QueuedMessage, to dest: LiveSession) {
        dest.journal.append(
            .message(MessageEventPayload(
                direcao: .recebida, contraparte: message.deNode, texto: message.texto, messageID: message.id)),
            author: .agente(message.deNode.string))
        if let wait = blockingWaits[dest.id], wait.messageID == message.id {
            wait.delivered = true
            wait.accum = Data()
            wait.sawOutput = false
        }
        // default DEVE ser texto puro + \r (§14.1.3)
        sessionInput(dest, data: Data((message.texto + "\r").utf8), author: .agente(message.deNode.string), terminalInput: false)
        broadcast(.messageDelivered, ws: dest.workspaceID, MessageDeliveredTopicPayload(
            de: message.deNode, para: dest.nodeID, texto: message.texto, messageID: message.id))
        ensureConversaConnection(ws: dest.workspaceID, entre: message.deNode, e: dest.nodeID)
    }

    private func deliverQueued(_ session: LiveSession) {
        guard session.estado == .esperandoHumano || session.estado == .ociosa else { return }
        guard !session.fila.isEmpty else { return }
        let message = session.fila.removeFirst()
        deliver(message, to: session) // entrega vira input → rodando; o resto espera a próxima janela
    }

    private func completeBlockingWait(_ session: LiveSession) {
        guard let wait = blockingWaits[session.id], wait.delivered, wait.sawOutput else { return }
        let resposta = TerminalText.stripANSI(TerminalText.decodeLossy(wait.accum))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        finishWait(wait, extra: ["resposta": .string(resposta)])
    }

    private func finishWait(_ wait: BlockingWait, extra: [String: JSONValue]) {
        blockingWaits.removeValue(forKey: wait.destSession)
        if blockingWaiters[wait.destNode] == wait.senderNode {
            blockingWaiters.removeValue(forKey: wait.destNode)
        }
        var object: [String: JSONValue] = ["message_id": .string(wait.messageID.string)]
        for (key, value) in extra { object[key] = value }
        wait.respond(.object(object))
    }

    /// §14.2 — primeira troca entre dois nós cria Connection {conversa} no documento.
    private func ensureConversaConnection(ws: ULID, entre a: ULID, e b: ULID) {
        guard a != b, let state = workspaces[ws] else { return }
        let exists = state.connections.values.contains {
            $0.semantica == .conversa && (($0.de == a && $0.para == b) || ($0.de == b && $0.para == a))
        }
        guard !exists else { return }
        let connection = Connection(id: ULID.generate(), de: a, para: b, semantica: .conversa, estilo: .tracejada)
        let op = DocOp(
            opID: ULID.generate(), author: .sistema, ts: Date(),
            payload: .connectionAdd(ConnectionAddOpPayload(connection: connection)))
        if let applied = try? state.applyProposal(op, liveNodeIDs: liveNodeIDs) {
            broadcast(.documentOp, ws: ws, DocumentOpTopicPayload(
                workspaceID: ws, op: applied, seq: applied.seq ?? 0))
        }
    }

    // MARK: - Notas (§13.3)

    private func handleNoteAppend(_ params: NoteAppendParams, author: Author) throws -> NoteAppendResult {
        let state = try requireWorkspace(params.workspaceID)
        guard let origem = state.terminalNode(params.nodeIDOrigem) else {
            throw ProtocolError(name: .node_not_found, message: "terminal \(params.nodeIDOrigem) não existe")
        }
        var notaID: ULID?
        for connection in state.connections.values
        where connection.semantica == .escritaDeNota && connection.de == origem.id {
            if case .nota = state.nodes[connection.para] {
                notaID = connection.para
                break
            }
        }
        if notaID == nil {
            // criar NotaNode adjacente e conectar (§13.3)
            let nid = ULID.generate()
            let nota = NotaNode(
                id: nid,
                posicao: Ponto(x: origem.posicao.x + origem.tamanho.w + 48, y: origem.posicao.y),
                tamanho: Tamanho(w: 260, h: 200), z: origem.z, criadoEm: Date(),
                arquivo: "notes/\(nid.string).md", cor: "amarela", ultimaFonte: author)
            let addNode = DocOp(
                opID: ULID.generate(), author: author, ts: Date(),
                payload: .nodeAdd(NodeAddOpPayload(node: .nota(nota))))
            let addConn = DocOp(
                opID: ULID.generate(), author: author, ts: Date(),
                payload: .connectionAdd(ConnectionAddOpPayload(connection: Connection(
                    id: ULID.generate(), de: origem.id, para: nid,
                    semantica: .escritaDeNota, estilo: .solida))))
            for op in [addNode, addConn] {
                let applied = try state.applyProposal(op, liveNodeIDs: liveNodeIDs)
                broadcast(.documentOp, ws: params.workspaceID, DocumentOpTopicPayload(
                    workspaceID: params.workspaceID, op: applied, seq: applied.seq ?? 0))
            }
            notaID = nid
        }
        guard let notaID else {
            throw ProtocolError(name: .internal_error, message: "falha ao resolver NotaNode")
        }
        let noteURL = paths.noteFile(workspace: params.workspaceID, node: notaID)
        try FileManager.default.createDirectory(
            at: noteURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var bloco = ""
        if let attrs = try? FileManager.default.attributesOfItem(atPath: noteURL.path),
           (attrs[.size] as? Int ?? 0) > 0 {
            bloco += "\n\n---\n"
        }
        bloco += "_\(author.rawValue) — \(ColmeiaJSON.string(from: Date()))_\n\n\(params.texto)\n"
        if let handle = FileHandle(forWritingAtPath: noteURL.path) {
            handle.seekToEndOfFile()
            handle.write(Data(bloco.utf8))
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: noteURL.path, contents: Data(bloco.utf8))
        }
        let updateOp = DocOp(
            opID: ULID.generate(), author: author, ts: Date(),
            payload: .nodeUpdate(NodeUpdateOpPayload(
                id: notaID, campos: .object(["ultima_fonte": .string(author.rawValue)]))))
        if let applied = try? state.applyProposal(updateOp, liveNodeIDs: liveNodeIDs) {
            broadcast(.documentOp, ws: params.workspaceID, DocumentOpTopicPayload(
                workspaceID: params.workspaceID, op: applied, seq: applied.seq ?? 0))
        }
        let resumo = String(params.texto.split(separator: "\n").first?.prefix(120) ?? "")
        if let sid = nodeSessions[origem.id], let live = sessions[sid] {
            live.journal.append(.note(NoteEventPayload(notaNodeID: notaID, resumo: resumo)), author: author)
        }
        broadcast(.noteAppended, ws: params.workspaceID, NoteAppendedTopicPayload(
            nodeID: notaID, fonte: author, resumo: resumo))
        return NoteAppendResult(notaNodeID: notaID)
    }

    // MARK: - Rotinas (§17, §24.4)

    private func handleRoutineCreate(_ params: RoutineCreateParams) throws -> Routine {
        let state = try requireWorkspace(params.workspaceID)
        guard state.terminalNode(params.alvo) != nil else {
            throw ProtocolError(name: .routine_target_missing, message: "alvo \(params.alvo) não é TerminalNode do workspace")
        }
        var routine = Routine(
            id: ULID.generate(), nome: params.nome, workspaceID: params.workspaceID,
            alvo: params.alvo, comando: params.comando, agenda: params.agenda,
            notificar: params.notificar, habilitada: params.habilitada)
        routine.proximaExecucao = routine.habilitada
            ? RoutineScheduling.proximaExecucao(agenda: routine.agenda, agora: Date(), jaExecutou: false)
            : nil
        routines[routine.id] = routine
        saveRoutines(params.workspaceID)
        return routine
    }

    private func handleRoutineUpdate(_ params: RoutineUpdateParams) throws -> Routine {
        guard var routine = routines[params.id] else {
            throw ProtocolError(name: .routine_not_found, message: "rotina \(params.id) não existe")
        }
        if let nome = params.nome { routine.nome = nome }
        if let alvo = params.alvo {
            guard workspaces[routine.workspaceID]?.terminalNode(alvo) != nil else {
                throw ProtocolError(name: .routine_target_missing, message: "alvo \(alvo) não é TerminalNode do workspace")
            }
            routine.alvo = alvo
        }
        if let comando = params.comando { routine.comando = comando }
        if let agenda = params.agenda { routine.agenda = agenda }
        if let notificar = params.notificar { routine.notificar = notificar }
        if let habilitada = params.habilitada {
            routine.habilitada = habilitada
            if habilitada { routineFalhas[routine.id] = 0 }
        }
        routine.proximaExecucao = routine.habilitada
            ? RoutineScheduling.proximaExecucao(
                agenda: routine.agenda, agora: Date(),
                jaExecutou: routine.ultimaExecucao != nil && routine.agenda.tipo == .once)
            : nil
        routines[routine.id] = routine
        saveRoutines(routine.workspaceID)
        return routine
    }

    func executeRoutine(_ id: ULID) -> RoutineResultado {
        guard var routine = routines[id] else { return .puladaAlvoAusente }
        let state = workspaces[routine.workspaceID]
        let alvoExiste = state?.terminalNode(routine.alvo) != nil
        let live = nodeSessions[routine.alvo].flatMap { sessions[$0] }
        let resultado = RoutineScheduling.elegibilidade(
            alvoExiste: alvoExiste,
            sessaoViva: live?.estado.isViva ?? false,
            estado: live?.estado)
        switch resultado {
        case .executada:
            routineFalhas[id] = 0
            if let live {
                sessionInput(live, data: Data((routine.comando + "\r").utf8), author: .sistema, terminalInput: false)
                live.journal.append(
                    .system(SystemEventPayload(name: "routine_executada", message: routine.nome)),
                    author: .sistema)
            }
            broadcast(.routineFired, ws: routine.workspaceID, RoutineFiredTopicPayload(
                routineID: id, resultado: .executada))
        case .puladaAlvoAusente:
            let falhas = (routineFalhas[id] ?? 0) + 1
            routineFalhas[id] = falhas
            log.warn("routine_pulada", "\(routine.nome): alvo ausente (\(falhas)x)", workspaceID: routine.workspaceID)
            if falhas >= RoutineScheduling.maxFalhasConsecutivas {
                routine.habilitada = false // §17.3 — auto-desabilitar após 3
                broadcast(.engineWarning, ws: routine.workspaceID, EngineWarningTopicPayload(
                    name: "routine_auto_desabilitada",
                    message: "rotina \"\(routine.nome)\" desabilitada após \(falhas) falhas consecutivas"))
            }
        case .puladaOcupado:
            live?.journal.append(
                .system(SystemEventPayload(name: "routine_pulada_ocupado", message: routine.nome)),
                author: .sistema)
        }
        routine.ultimaExecucao = UltimaExecucao(ts: Date(), resultado: resultado)
        routine.proximaExecucao = routine.habilitada
            ? RoutineScheduling.proximaExecucao(
                agenda: routine.agenda, agora: Date(),
                jaExecutou: routine.agenda.tipo == .once) // once já teve sua chance
            : nil
        routines[id] = routine
        saveRoutines(routine.workspaceID)
        return resultado
    }

    // MARK: - Andares (§16, §24.6)

    private func handleFloorCreate(_ params: FloorCreateParams) throws -> Floor {
        let state = try requireWorkspace(params.workspaceID)
        guard let raiz = state.workspace.caminhoRaiz, Git.isRepo(raiz) else {
            throw ProtocolError(
                name: .floor_mechanism_unavailable,
                message: "workspace sem repo git; clone APFS não implementado nesta versão")
        }
        let nomeS = sanitizarNome(params.nome)
        guard !nomeS.isEmpty else {
            throw ProtocolError(name: .invalid_params, message: "nome de andar inválido após sanitização (§23.3)")
        }
        let base = FloorPaths.base(caminhoRaiz: raiz)
        let caminho = FloorPaths.worktree(caminhoRaiz: raiz, nomeSanitizado: nomeS)
        guard caminhoContido(caminho, em: base), caminho != base else {
            throw ProtocolError(name: .invalid_params, message: "containment violado (§23.3)")
        }
        guard !FileManager.default.fileExists(atPath: caminho) else {
            throw ProtocolError(name: .invalid_params, message: "já existe andar em \(caminho)")
        }
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: base), withIntermediateDirectories: true)
        let branch = params.branch ?? "andar/\(nomeS)"
        var result = Git.run(["-C", raiz, "worktree", "add", caminho, "-b", branch], cwd: nil)
        if result.status != 0 {
            // branch já existe → usa sem -b
            result = Git.run(["-C", raiz, "worktree", "add", caminho, branch], cwd: nil)
        }
        guard result.status == 0 else {
            throw ProtocolError(name: .internal_error, message: "git worktree add: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let floor = Floor(
            id: ULID.generate(), nome: params.nome, origem: params.workspaceID,
            mecanismo: .gitWorktree, branch: branch, caminho: caminho,
            estado: .ativo, criadoEm: Date(), nos: [])
        floors[floor.id] = floor
        saveFloors(params.workspaceID)
        broadcast(.floorChanged, ws: params.workspaceID, FloorChangedTopicPayload(floor: floor))
        return floor
    }

    private func handleFloorSwitch(_ params: FloorSwitchParams) throws -> FloorSwitchResult {
        guard var floor = floors[params.floorID] else {
            throw ProtocolError(name: .floor_not_found, message: "andar \(params.floorID) não existe")
        }
        if floor.estado == .orfao {
            // readoção (§16.4): voltar a ativo
            floor.estado = .ativo
            floors[floor.id] = floor
            saveFloors(floor.origem)
            broadcast(.floorChanged, ws: floor.origem, FloorChangedTopicPayload(floor: floor))
        }
        guard floor.estado == .ativo else {
            throw ProtocolError(name: .invalid_params, message: "andar não está ativo (\(floor.estado.rawValue))")
        }
        activeFloor[floor.origem] = floor.id
        return FloorSwitchResult(floor: floor, nos: .array(floor.nos.map { .string($0.string) }))
    }

    private func floorLiveSessions(_ floor: Floor) -> [LiveSession] {
        floor.nos.compactMap { nodeSessions[$0] }.compactMap { sessions[$0] }.filter { $0.estado.isViva }
    }

    private func handleFloorLand(_ params: FloorLandParams, requestID: String, client: ClientConnection) throws {
        guard let floor = floors[params.floorID] else {
            throw ProtocolError(name: .floor_not_found, message: "andar \(params.floorID) não existe")
        }
        guard floor.estado == .ativo else {
            throw ProtocolError(name: .invalid_params, message: "andar não está ativo (\(floor.estado.rawValue))")
        }
        let vivas = floorLiveSessions(floor)
        guard vivas.isEmpty || params.confirmar else {
            throw ProtocolError(name: .confirmation_required, message: "andar tem sessões vivas; confirmar: true encerra (§16.3)")
        }
        killAndWait(vivas) { [weak self, weak client] in
            guard let self else { return }
            guard var floor = self.floors[params.floorID] else { return }
            // §24.6 — worktree sujo: usuária resolve; engine não mescla
            if Git.isDirty(floor.caminho) {
                client?.respond(id: requestID, error: ProtocolError(
                    name: .floor_dirty, message: "worktree tem mudanças não commitadas (§16.3)"))
                return
            }
            let raiz = self.workspaces[floor.origem]?.workspace.caminhoRaiz ?? floor.caminho
            // §23.3 — sempre o caminho REGISTRADO em floors.json
            let result = Git.run(["-C", raiz, "worktree", "remove", floor.caminho], cwd: nil)
            guard result.status == 0 else {
                client?.respond(id: requestID, error: ProtocolError(
                    name: .internal_error, message: "git worktree remove: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"))
                return
            }
            self.archiveFloorNodes(floor)
            floor.estado = .aterrissado
            self.floors[floor.id] = floor
            if self.activeFloor[floor.origem] == floor.id {
                self.activeFloor.removeValue(forKey: floor.origem)
            }
            self.saveFloors(floor.origem)
            self.broadcast(.floorChanged, ws: floor.origem, FloorChangedTopicPayload(floor: floor))
            client?.respond(id: requestID, result: (try? JSONValue(encoding: EmptyResult())) ?? .object([:]))
        }
    }

    private func handleFloorDiscard(_ params: FloorDiscardParams, requestID: String, client: ClientConnection) throws {
        guard let floor = floors[params.floorID] else {
            throw ProtocolError(name: .floor_not_found, message: "andar \(params.floorID) não existe")
        }
        guard floor.estado == .ativo || floor.estado == .orfao else {
            throw ProtocolError(name: .invalid_params, message: "andar não é descartável (\(floor.estado.rawValue))")
        }
        guard params.confirmar else {
            throw ProtocolError(name: .confirmation_required, message: "floor.discard perde trabalho não commitado; exige confirmar: true (§16.4)")
        }
        let vivas = floorLiveSessions(floor)
        killAndWait(vivas) { [weak self, weak client] in
            guard let self else { return }
            guard var floor = self.floors[params.floorID] else { return }
            let raiz = self.workspaces[floor.origem]?.workspace.caminhoRaiz ?? floor.caminho
            let result = Git.run(["-C", raiz, "worktree", "remove", "--force", floor.caminho], cwd: nil)
            if result.status != 0 {
                // clone/órfão fora do controle do git: remover só o caminho registrado, com containment
                if let base = self.workspaces[floor.origem]?.workspace.caminhoRaiz.map(FloorPaths.base(caminhoRaiz:)),
                   caminhoContido(floor.caminho, em: base), floor.caminho != base {
                    try? FileManager.default.removeItem(atPath: floor.caminho)
                }
                _ = Git.run(["-C", raiz, "worktree", "prune"], cwd: nil)
            }
            self.archiveFloorNodes(floor)
            floor.estado = .descartado
            self.floors[floor.id] = floor
            if self.activeFloor[floor.origem] == floor.id {
                self.activeFloor.removeValue(forKey: floor.origem)
            }
            self.saveFloors(floor.origem)
            self.broadcast(.floorChanged, ws: floor.origem, FloorChangedTopicPayload(floor: floor))
            client?.respond(id: requestID, result: (try? JSONValue(encoding: EmptyResult())) ?? .object([:]))
        }
    }

    /// §16.3.4 — nós arquivados via `node.delete` com `anterior` preservado para histórico.
    private func archiveFloorNodes(_ floor: Floor) {
        guard let state = workspaces[floor.origem] else { return }
        for nodeID in floor.nos where state.nodes[nodeID] != nil {
            let op = DocOp(
                opID: ULID.generate(), author: .sistema, ts: Date(),
                payload: .nodeDelete(NodeDeleteOpPayload(id: nodeID)))
            if let applied = try? state.applyProposal(op, liveNodeIDs: liveNodeIDs) {
                broadcast(.documentOp, ws: floor.origem, DocumentOpTopicPayload(
                    workspaceID: floor.origem, op: applied, seq: applied.seq ?? 0))
            }
        }
    }

    // MARK: - Kill gracioso (TERM → 5s → KILL)

    private func killAndWait(_ list: [LiveSession], completion: @escaping () -> Void) {
        for session in list where session.estado.isViva {
            if let pty = session.pty {
                PTY.signal(pid: pty.pid, SIGTERM)
                session.killDeadline = Date().addingTimeInterval(5)
            }
        }
        pollSessionsEnded(ids: list.map { $0.id }, deadline: Date().addingTimeInterval(12), completion: completion)
    }

    private func pollSessionsEnded(ids: [ULID], deadline: Date, completion: @escaping () -> Void) {
        let pending = ids.filter { sessions[$0]?.estado.isViva == true }
        if pending.isEmpty || Date() > deadline {
            completion()
            return
        }
        // escalada TERM→KILL mesmo com o tick parado (shutdown)
        let now = Date()
        for id in pending {
            if let session = sessions[id], let dl = session.killDeadline, dl <= now, let pty = session.pty {
                PTY.signal(pid: pty.pid, SIGKILL)
                session.killDeadline = nil
            }
        }
        stateQueue.asyncAfter(deadline: .now() + .milliseconds(200)) { [weak self] in
            self?.pollSessionsEnded(ids: ids, deadline: deadline, completion: completion)
        }
    }

    // MARK: - Shutdown (§6.4 engine.shutdown)

    private func performShutdown(exitProcess: Bool, completion: (() -> Void)?) {
        guard !shuttingDown else {
            completion?()
            return
        }
        shuttingDown = true
        log.info("engine_shutdown", "iniciando shutdown gracioso")
        let vivas = sessions.values.filter { $0.estado.isViva }
        killAndWait(Array(vivas)) { [weak self] in
            guard let self else { return }
            for state in self.workspaces.values {
                try? state.writeSnapshot()
                try? state.saveWorkspace()
            }
            for session in self.sessions.values {
                session.journal.seal()
            }
            self.flushTimer?.cancel()
            self.tickTimer?.cancel()
            completion?()
            // deixa as responses drenarem antes de derrubar as conexões
            self.stateQueue.asyncAfter(deadline: .now() + .milliseconds(200)) {
                for client in self.clients.values {
                    client.closeConnection()
                }
                self.clients.removeAll()
                self.server?.stop()
                self.log.info("engine_shutdown", "encerrado")
                if exitProcess {
                    exit(0)
                }
            }
        }
    }
}
