import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
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

/// O Codex CLI persiste o histórico dentro de `CODEX_HOME`. Cada agente do
/// Colmeia ganha uma casa própria: assim a sua conversa pode ser retomada sem
/// o risco de o comando `resume --last` escolher uma conversa de outro terminal.
enum CodexAgentHome {
    static func prepare(
        paths: ColmeiaPaths,
        workspaceID: ULID,
        nodeID: ULID,
        inheritedEnvironment: [String: String]
    ) throws -> URL {
        let home = paths.workspaceDir(workspaceID)
            .appendingPathComponent("codex", isDirectory: true)
            .appendingPathComponent(nodeID.string, isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: home, withIntermediateDirectories: true)

        // Autenticação e preferências continuam sendo as da pessoa usuária. Nós
        // só separamos os dados voláteis (histórico, sessões e state) do agente.
        let originalRoot = inheritedEnvironment["CODEX_HOME"].map(URL.init(fileURLWithPath:))
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        for filename in ["auth.json", "config.toml"] {
            let original = originalRoot.appendingPathComponent(filename)
            let link = home.appendingPathComponent(filename)
            guard fm.fileExists(atPath: original.path),
                  !fm.fileExists(atPath: link.path) else { continue }
            try fm.createSymbolicLink(atPath: link.path, withDestinationPath: original.path)
        }
        return home
    }

    static func hasSession(in home: URL) -> Bool {
        let sessions = home.appendingPathComponent("sessions", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: sessions, includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return false }
        for case let file as URL in enumerator where file.pathExtension == "jsonl" {
            return true
        }
        return false
    }
}

/// Daemon headless (§3.1), dono de todo estado autoritativo. Toda mutação de estado
/// roda na `stateQueue` (serial); I/O de PTY e de clientes roda em queues próprias e
/// converge para cá. A UI/CLI só falam com isto pelo protocolo §6 sobre o socket.
public final class Engine: @unchecked Sendable {
    /// Tempo para o processo tratar SIGTERM antes da escalada. Um terminal
    /// interativo não deve deixar a UI esperando vários segundos para encerrar.
    static let sessionKillGrace: TimeInterval = 1
    public let paths: ColmeiaPaths
    /// Porta TCP opcional para túnel remoto (0 = desligado).
    public let engineTCPPort: UInt16
    public let registry: AdapterRegistry
    let log: EngineLog
    let stateQueue = DispatchQueue(label: "colmeia.engine.state")
    let startedAt = Date()
    /// Diretório injetado no PATH das sessões — a CLI `colmeia` mora ao lado do engine (§10.2).
    let cliDirectory: String
    /// Env base herdada pelos PTYs (§10.2), saneada em `handleSessionStart` — injetável em testes.
    var baseEnvironment: [String: String] = ProcessInfo.processInfo.environment

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
    var deliveryStores: [ULID: DeliveryStore] = [:]
    var watchdogConfigurations: [ULID: WorkerWatchdogConfiguration] = [:]
    var workerArchives: [ULID: WorkerArchiveService] = [:]
    var delegations: [ULID: [ULID: Delegation]] = [:]
    var delegationWaiters: [ULID: [(Delegation) -> Void]] = [:]
    var semanticEvents: [ULID: [SemanticEvent]] = [:]
    var watchdogAlertedSessions: Set<ULID> = []
    let watchdog = WorkerWatchdogService()
    var portalBrowsers: [ULID: PortalBrowserSession] = [:]
    var roomStores: [ULID: RoomStore] = [:]
    var missionStores: [ULID: MissionStore] = [:]
    var blockingWaits: [ULID: BlockingWait] = [:]
    /// destino (node) → remetente (node) com ask bloqueante em voo — limite de profundidade §14.2.
    var blockingWaiters: [ULID: ULID] = [:]
    var clients: [ObjectIdentifier: ClientConnection] = [:]

    private var server: SocketServer?
    private var lockFD: Int32 = -1
    private var shuttingDown = false
    private var flushTimer: DispatchSourceTimer?
    private var tickTimer: DispatchSourceTimer?
    private var config = EngineConfig.default

    public init(paths: ColmeiaPaths = ColmeiaPaths(), tcpPort: UInt16 = 0, registry: AdapterRegistry = .standard()) {
        self.paths = paths
        self.engineTCPPort = tcpPort
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
        let loadedConfig = EngineConfig.load(from: paths)
        config = loadedConfig.config
        if let warning = loadedConfig.warning {
            log.warn("config_warning", warning)
        }
        let expired = SessionRetention.pruneClosedJournals(
            paths: paths,
            retentionDays: config.closedJournalRetentionDays)
        for removal in expired {
            log.info(
                "journal_retention_cleanup",
                "sessão encerrada expirada removida",
                sessionID: removal.sessionID)
        }
        scanWorkspaces() // ainda sem concorrência: servidor e timers só sobem depois
        scanRooms()
        let server = SocketServer(path: paths.engineSocket.path, tcpPort: engineTCPPort, engine: self)
        try server.start()
        self.server = server
        stateQueue.async { [weak self] in
            self?.recoverActiveDelegations()
        }
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
        runWatchdog()
        expireRoomLeases()
        expireRoomPresences()
    }

    /// Limpa leases expirados de todas as salas (tick de 1s).
    private func expireRoomLeases() {
        let now = Date()
        for store in roomStores.values {
            let expired = store.expireLeases(now: now)
            for leaseID in expired {
                broadcast(.leaseRevoked, ws: nil, LeaseRevokedTopicPayload(leaseID: leaseID))
            }
        }
    }

    /// Descarta presenças expiradas (TTL §6.4).
    private func expireRoomPresences() {
        let now = Date()
        for store in roomStores.values {
            let expired = store.expirePresence(now: now)
            for memberID in expired {
                broadcast(.presenceChanged, ws: nil,
                    PresenceChangedTopicPayload(
                        roomID: store.roomID, memberID: memberID,
                        connected: false, lastSeen: now))
            }
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
            guard fm.fileExists(atPath: paths.workspaceFile(wsID).path) else {
                continue
            }
            guard let workspace = try? AtomicJSON.read(Workspace.self, from: paths.workspaceFile(wsID)) else {
                log.warn("workspace_illegivel", "workspace.json ilegível em \(entry.lastPathComponent)")
                continue
            }
            guard let state = try? WorkspaceState(
                paths: paths,
                workspace: workspace,
                snapshotEveryOps: config.documentSnapshotEveryOps)
            else { continue }
            migrateLegacyMaestroRoles(in: state, workspaceID: wsID)
            workspaces[wsID] = state
            deliveryStores[wsID] = try? DeliveryStore(directory: paths.deliveriesDir(wsID))
            watchdogConfigurations[wsID] =
                (try? AtomicJSON.read(WorkerWatchdogConfiguration.self, from: paths.watchdogFile(wsID)))
                ?? WorkerWatchdogConfiguration()
            let archived =
                (try? AtomicJSON.read([WorkerArchiveTombstone].self, from: paths.workerArchiveFile(wsID)))
                ?? []
            workerArchives[wsID] = WorkerArchiveService(records: archived)
            let savedDelegations = (try? AtomicJSON.read([Delegation].self, from: paths.delegationsFile(wsID))) ?? []
            delegations[wsID] = Dictionary(uniqueKeysWithValues: savedDelegations.map { ($0.id, $0) })
            semanticEvents[wsID] = Self.readSemanticEvents(from: paths.semanticEventsFile(wsID))
            if let notice = state.corruptionNotice {
                log.warn("document_corrupted", notice, workspaceID: wsID)
            }
            recoverSessions(wsID)
            loadRoutines(wsID)
            loadFloorsAndReconcile(wsID)
        }
    }

    /// Mantém os workspaces persistidos antes da troca de nomenclatura operacionais,
    /// registrando a conversão no journal do documento em vez de alterar o estado direto.
    private func migrateLegacyMaestroRoles(in state: WorkspaceState, workspaceID: ULID) {
        for node in state.nodes.values {
            guard case .terminal(let terminal) = node, terminal.papel == "maestro" else { continue }
            let op = DocOp(
                opID: ULID.generate(), author: .sistema, ts: Date(),
                payload: .nodeUpdate(NodeUpdateOpPayload(
                    id: terminal.id, campos: .object(["papel": .string("rainha")]))))
            guard (try? state.applyProposal(op, liveNodeIDs: liveNodeIDs)) != nil else { continue }
            log.info("role_migrated", "papel maestro migrado para rainha", workspaceID: workspaceID)
        }
        try? state.saveWorkspace()
    }

    /// Recupera o Hub virtual local. Salas arquivadas permanecem no disco para
    /// auditoria, mas não voltam à lista ativa.
    private func scanRooms() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: paths.roomsDir, includingPropertiesForKeys: nil
        ) else { return }
        for entry in entries {
            guard let roomID = ULID(entry.lastPathComponent) else { continue }
            let snapshotURL = paths.roomSnapshotFile(roomID)
            let legacyRoomURL = paths.roomFile(roomID)
            guard fm.fileExists(atPath: snapshotURL.path)
                    || fm.fileExists(atPath: legacyRoomURL.path) else {
                continue
            }
            do {
                let store: RoomStore
                if fm.fileExists(atPath: snapshotURL.path) {
                    store = try RoomStore.load(from: paths, roomID: roomID)
                } else {
                    let room = try AtomicJSON.read(Room.self, from: legacyRoomURL)
                    guard room.id == roomID else {
                        throw RoomStoreError.roomNotFound(roomID)
                    }
                    store = RoomStore(room: room)
                    let legacyMembers = (try? AtomicJSON.read(
                        [Member].self, from: paths.roomMembersFile(roomID))) ?? []
                    for member in legacyMembers where member.status == .active {
                        _ = try store.addMember(
                            id: member.id,
                            displayName: member.displayName,
                            roles: member.roles,
                            now: member.joinedAt)
                    }
                    try store.persist(to: paths)
                    log.info(
                        "room_migrated",
                        "sala legada migrada para snapshot",
                        workspaceID: nil)
                }
                guard store.getRoom().state == .active else { continue }
                roomStores[roomID] = store
                missionStores[roomID] = (try? MissionStore.load(from: paths, roomID: roomID))
                    ?? MissionStore(roomID: roomID)
            } catch {
                log.warn(
                    "room_unreadable",
                    "sala multiplayer ilegível em \(entry.lastPathComponent): \(error)")
            }
        }
    }

    private func persistRoom(_ store: RoomStore) throws {
        try store.persist(to: paths)
    }

    private func persistMissionStore(_ roomID: ULID) throws {
        guard let store = missionStores[roomID] else { return }
        try store.persist(to: paths)
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
                if let journal = try? SessionJournal(
                    url: journalURL,
                    lastSeq: result.events.last?.seq ?? 0,
                    policy: config.journalPolicy)
                {
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
            let agenda = RoutineScheduling.recalcular(
                agenda: routine.agenda,
                agora: Date(),
                jaExecutou: routine.ultimaExecucao != nil)
            routine.estadoAgenda = agenda.estado
            routine.proximaExecucao = routine.habilitada ? agenda.proximaExecucao : nil
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
                if let primaryNodeID = params.primaryNodeID {
                    guard state.terminalNode(primaryNodeID) != nil else {
                        throw ProtocolError(name: .node_not_found, message: "principal não é um terminal deste workspace")
                    }
                    state.workspace.primaryNodeID = primaryNodeID
                }
                state.workspace.atualizadoEm = Date()
                try? state.saveWorkspace()
                respondEncodable(client, id: request.id, WorkspaceResult(workspace: state.workspace))
            case .docApply:
                let params = try request.decodeParams(DocApplyParams.self)
                let state = try requireWorkspace(params.workspaceID)
                // Validação e persistência em lote: nenhuma operação/broadcast do
                // prefixo escapa se uma proposta posterior for rejeitada (§7.1).
                let appliedOps = try state.applyBatch(
                    params.ops,
                    liveNodeIDs: liveNodeIDs)
                var seqFinal = state.seq
                for applied in appliedOps {
                    seqFinal = applied.seq ?? seqFinal
                    broadcast(.documentOp, ws: params.workspaceID, DocumentOpTopicPayload(
                        workspaceID: params.workspaceID, op: applied, seq: applied.seq ?? 0))
                    switch applied.payload {
                    case .connectionAdd(let payload):
                        notificarConexao(payload.connection, removida: false, em: state)
                    case .connectionDelete:
                        if let anterior = applied.anterior?.objectValue?["connection"],
                           let conexao = try? anterior.decode(as: Connection.self) {
                            notificarConexao(conexao, removida: true, em: state)
                        }
                    default:
                        break
                    }
                }
                // An agent-created terminal is part of that agent's working
                // graph immediately, not only after the first message.
                if case .agente(let sourceString) = client.author,
                   let sourceID = ULID(sourceString) {
                    for applied in appliedOps {
                        guard case .nodeAdd(let payload) = applied.payload,
                              case .terminal(let terminal) = payload.node,
                              terminal.id != sourceID else { continue }
                        ensureConversaConnection(
                            ws: params.workspaceID, entre: sourceID, e: terminal.id)
                    }
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
            case .sessionEnsure:
                let params = try request.decodeParams(SessionEnsureParams.self)
                respondEncodable(client, id: request.id, SessionResult(session: try handleSessionEnsure(params)))
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
                // Resize idêntico é no-op: sem SIGWINCH (TUIs redesenham a tela inteira)
                // e sem evento redundante no journal.
                if live.cols != params.cols || live.rows != params.rows {
                    live.cols = params.cols
                    live.rows = params.rows
                    if let pty = live.pty {
                        PTY.resize(master: pty.master, pid: pty.pid, cols: params.cols, rows: params.rows)
                    }
                    live.journal.append(
                        .resize(ResizeEventPayload(cols: params.cols, rows: params.rows)),
                        author: client.author)
                } else if let pty = live.pty,
                          let actual = PTY.size(master: pty.master),
                          actual.cols != params.cols || actual.rows != params.rows {
                    // Cura sessões criadas por versões que gravavam a geometria
                    // correta no metadado, mas deixavam o slave real em 0×0.
                    // Não cria resize duplicado no journal.
                    PTY.resize(
                        master: pty.master, pid: pty.pid,
                        cols: params.cols, rows: params.rows)
                }
                respondEncodable(client, id: request.id, EmptyResult())
            case .sessionKill:
                let params = try request.decodeParams(SessionKillParams.self)
                let live = try requireLiveSession(params.sessionID)
                if let pty = live.pty {
                    if params.sinal == .kill {
                        PTY.signal(pid: pty.pid, SIGKILL)
                    } else {
                        terminateGracefully(live, pty: pty)
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
            case .nodeList:
                let params = try request.decodeParams(NodeListParams.self)
                respondEncodable(client, id: request.id, try handleNodeList(params, author: client.author))
            case .noteCreate:
                let params = try request.decodeParams(NoteCreateParams.self)
                respondEncodable(client, id: request.id, try handleNoteCreate(params, author: client.author))
            case .noteGet:
                let params = try request.decodeParams(NoteGetParams.self)
                respondEncodable(client, id: request.id, try handleNoteGet(params, author: client.author))
            case .noteConnected:
                let params = try request.decodeParams(NoteConnectedParams.self)
                respondEncodable(client, id: request.id, try handleNoteConnected(params, author: client.author))
            case .noteChain:
                let params = try request.decodeParams(NoteConnectedParams.self)
                respondEncodable(client, id: request.id, try handleNoteChain(params, author: client.author))
            case .noteAssetAdd:
                let params = try request.decodeParams(NoteAssetAddParams.self)
                respondEncodable(client, id: request.id, try handleNoteAssetAdd(params, author: client.author))
            case .noteAssetList:
                let params = try request.decodeParams(NoteAssetListParams.self)
                respondEncodable(client, id: request.id, try handleNoteAssetList(params, author: client.author))
            case .noteAssetRm:
                let params = try request.decodeParams(NoteAssetRmParams.self)
                respondEncodable(client, id: request.id, try handleNoteAssetRm(params, author: client.author))
            case .noteAssetGet:
                let params = try request.decodeParams(NoteAssetGetParams.self)
                respondEncodable(client, id: request.id, try handleNoteAssetGet(params, author: client.author))
            case .noteReplace:
                let params = try request.decodeParams(NoteReplaceParams.self)
                respondEncodable(client, id: request.id, try handleNoteReplace(params, author: client.author))
            case .noteChecklistAdd:
                let params = try request.decodeParams(NoteChecklistAddParams.self)
                respondEncodable(client, id: request.id, try handleNoteChecklistAdd(params, author: client.author))
            case .noteChecklistSet:
                let params = try request.decodeParams(NoteChecklistSetParams.self)
                respondEncodable(client, id: request.id, try handleNoteChecklistSet(params, author: client.author))
            case .portalOpen:
                let params = try request.decodeParams(PortalOpenParams.self)
                respondEncodable(client, id: request.id, try handlePortalOpen(params, author: client.author))
            case .portalCommand:
                let params = try request.decodeParams(PortalCommandParams.self)
                respondEncodable(client, id: request.id, try handlePortalCommand(params, author: client.author))
            case .nodeDismiss:
                let params = try request.decodeParams(NodeDismissParams.self)
                respondEncodable(client, id: request.id, try handleNodeDismiss(params, author: client.author))
            case .nodeConnect:
                let params = try request.decodeParams(NodeConnectParams.self)
                respondEncodable(client, id: request.id, try handleNodeConnect(params, author: client.author))
            case .nodeDisconnect:
                let params = try request.decodeParams(NodeDisconnectParams.self)
                respondEncodable(client, id: request.id, try handleNodeDisconnect(params, author: client.author))
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
            case .memoryGet:
                let params = try request.decodeParams(MemoryGetParams.self)
                respondEncodable(client, id: request.id, try handleMemoryGet(params, author: client.author))
            case .memoryUpdate:
                let params = try request.decodeParams(MemoryUpdateParams.self)
                respondEncodable(client, id: request.id, try handleMemoryUpdate(params, author: client.author))
            case .memoryPropose:
                let params = try request.decodeParams(MemoryProposeParams.self)
                respondEncodable(client, id: request.id, try handleMemoryPropose(params, author: client.author))
            case .memoryProposalList:
                let params = try request.decodeParams(MemoryProposalListParams.self)
                _ = try authorizeWorkspace(params.workspaceID, author: client.author)
                respondEncodable(client, id: request.id,
                    memoryStore(params.workspaceID).list(status: params.status))
            case .memoryAccept:
                let params = try request.decodeParams(MemoryProposalResolveParams.self)
                respondEncodable(client, id: request.id, try handleMemoryAccept(params, author: client.author))
            case .memoryReject:
                let params = try request.decodeParams(MemoryProposalResolveParams.self)
                respondEncodable(client, id: request.id, try handleMemoryReject(params, author: client.author))
            case .memoryHistory:
                let params = try request.decodeParams(MemoryHistoryParams.self)
                _ = try authorizeWorkspace(params.workspaceID, author: client.author)
                respondEncodable(client, id: request.id, memoryStore(params.workspaceID).history())
            case .deliverySubmit:
                let params = try request.decodeParams(DeliverySubmitParams.self)
                respondEncodable(client, id: request.id, DeliveryResult(
                    delivery: try handleDeliverySubmit(params, author: client.author)))
            case .deliveryList:
                let params = try request.decodeParams(DeliveryListParams.self)
                _ = try authorizeWorkspace(params.workspaceID, author: client.author)
                var values = try deliveryStore(params.workspaceID).deliveries(workspaceID: params.workspaceID)
                if let estado = params.estado { values = values.filter { $0.estado == estado } }
                respondEncodable(client, id: request.id, values)
            case .deliveryAccept:
                let params = try request.decodeParams(DeliveryReviewParams.self)
                respondEncodable(client, id: request.id, DeliveryResult(
                    delivery: try handleDeliveryReview(params.deliveryID, accept: true, author: client.author)))
            case .deliveryReopen:
                let params = try request.decodeParams(DeliveryReviewParams.self)
                respondEncodable(client, id: request.id, DeliveryResult(
                    delivery: try handleDeliveryReview(params.deliveryID, accept: false, author: client.author)))
            case .watchdogGet:
                let params = try request.decodeParams(WatchdogGetParams.self)
                _ = try authorizeWorkspace(params.workspaceID, author: client.author)
                var history: [WatchdogHistoryEntry] = []
                let visibleNodeIDs = Set(workspaces[params.workspaceID]?.nodes.keys ?? Dictionary<ULID, Node>().keys)
                let watchdogNeedle = Data("watchdog_".utf8)
                for session in sessionMetas.values
                    where session.workspaceID == params.workspaceID && visibleNodeIDs.contains(session.nodeID) {
                    let journalURL = session.journal.map { URL(fileURLWithPath: $0) }
                        ?? paths.sessionJournal(workspace: session.workspaceID, session: session.id)
                    guard let data = try? Data(contentsOf: journalURL) else { continue }
                    for line in data.split(separator: 0x0A)
                        where Data(line).range(of: watchdogNeedle) != nil {
                        guard let event = try? ColmeiaJSON.decoder().decode(Event.self, from: Data(line)) else { continue }
                        if case .system(let system) = event.payload,
                           system.name.hasPrefix("watchdog") {
                            history.append(WatchdogHistoryEntry(
                                sessionID: session.id, message: system.message,
                                occurredAt: event.ts, seq: event.seq))
                        }
                    }
                }
                history.sort { $0.occurredAt < $1.occurredAt }
                respondEncodable(client, id: request.id, WatchdogGetResult(
                    configuration: watchdogConfigurations[params.workspaceID] ?? WorkerWatchdogConfiguration(),
                    history: Array(history.suffix(50))))
            case .watchdogUpdate:
                let params = try request.decodeParams(WatchdogUpdateParams.self)
                try handleWatchdogUpdate(params, author: client.author)
                respondEncodable(client, id: request.id, WatchdogGetResult(configuration: params.configuration))
            case .workerArchive:
                let params = try request.decodeParams(WorkerArchiveParams.self)
                respondEncodable(client, id: request.id, WorkerArchiveResult(
                    tombstone: try handleWorkerArchive(params, author: client.author)))
            case .workerList:
                let params = try request.decodeParams(WorkerListParams.self)
                _ = try authorizeWorkspace(params.workspaceID, author: client.author)
                respondEncodable(client, id: request.id,
                    workerArchives[params.workspaceID]?.tombstones() ?? [])
            case .workerRestore:
                let params = try request.decodeParams(WorkerRestoreParams.self)
                respondEncodable(client, id: request.id, try handleWorkerRestore(params, author: client.author))
            case .workerAcquire:
                let params = try request.decodeParams(WorkerAcquireParams.self)
                respondEncodable(client, id: request.id, try handleWorkerAcquire(params, author: client.author))
            case .delegationCreate:
                let params = try request.decodeParams(DelegationCreateParams.self)
                respondEncodable(client, id: request.id, try handleDelegationCreate(params, author: client.author))
            case .delegationWait:
                let params = try request.decodeParams(DelegationWaitParams.self)
                handleDelegationWait(params, request: request, client: client)
            case .delegationDone:
                let params = try request.decodeParams(DelegationDoneParams.self)
                respondEncodable(client, id: request.id, try handleDelegationDone(params, author: client.author))
            case .delegationList:
                let params = try request.decodeParams(DelegationListParams.self)
                _ = try authorizeWorkspace(params.workspaceID, author: client.author)
                let list = Array(delegations[params.workspaceID]?.values ?? Dictionary<ULID, Delegation>().values)
                    .sorted { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
                respondEncodable(client, id: request.id, list)
            case .adapterList:
                respondEncodable(client, id: request.id, registry.availability())
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
            case .roomCreate:
                let params = try request.decodeParams(RoomCreateParams.self)
                let now = Date()
                let ownerID = InstallationIdentity.current().string
                let roomID = params.id ?? ULID.generate()
                let room = Room(
                    id: roomID, name: params.name, ownerID: ownerID,
                    policy: params.policy ?? RoomPolicy(),
                    workspaceID: params.workspaceID,
                    createdAt: now, updatedAt: now)
                let store = RoomStore(room: room)
                roomStores[room.id] = store
                missionStores[room.id] = MissionStore(roomID: room.id)
                let myself = Member(
                    id: ownerID,
                    displayName: NSFullUserName(), roles: [.owner], joinedAt: now)
                try store.addMember(id: myself.id, displayName: myself.displayName, roles: [.owner])
                try persistRoom(store)
                try persistMissionStore(room.id)
                respondEncodable(client, id: request.id, RoomResult(room: room))
            case .roomJoin:
                let params = try request.decodeParams(RoomJoinParams.self)
                let store = try roomStore(params.roomID)
                let memberID = InstallationIdentity.current().string
                if let token = params.inviteToken, !token.isEmpty {
                    let invite = try store.redeemInvite(token: token, memberID: memberID)
                    if store.getMember(id: memberID) == nil {
                        try store.addMember(
                            id: memberID, displayName: invite.displayName, roles: invite.roles)
                        try persistRoom(store)
                    }
                } else if store.getMember(id: memberID) == nil {
                    try store.addMember(id: memberID, displayName: NSFullUserName(), roles: [.viewer])
                    try persistRoom(store)
                }
                let snapshot = store.snapshot()
                respondEncodable(client, id: request.id, RoomJoinResult(
                    room: snapshot.room, members: snapshot.members, agentSessions: snapshot.agentSessions))
            case .roomLeave:
                let params = try request.decodeParams(RoomLeaveParams.self)
                let store = try roomStore(params.roomID)
                let memberID = InstallationIdentity.current().string
                _ = try store.removeMember(id: memberID)
                try persistRoom(store)
                respondEncodable(client, id: request.id, EmptyResult())
            case .roomSnapshot:
                let params = try request.decodeParams(RoomSnapshotParams.self)
                let store = try roomStore(params.roomID)
                var snapshot = store.snapshot()
                if let since = params.sinceRoomSeq {
                    snapshot.events = snapshot.events.filter { $0.logicalClock > since }
                }
                respondEncodable(client, id: request.id, snapshot)
            case .roomDelta:
                let params = try request.decodeParams(RoomDeltaParams.self)
                let store = try roomStore(params.roomID)
                respondEncodable(client, id: request.id, store.buildDelta(sinceRoomSeq: params.sinceRoomSeq))
            case .roomList:
                let rooms = roomStores.values.map { $0.getRoom() }
                    .sorted { $0.updatedAt > $1.updatedAt }
                respondEncodable(client, id: request.id, rooms)
            case .roomUpdate:
                let params = try request.decodeParams(RoomUpdateParams.self)
                let store = try roomStore(params.roomID)
                let room = store.updateRoom(name: params.name, policy: params.policy)
                try persistRoom(store)
                respondEncodable(client, id: request.id, RoomResult(room: room))
            case .roomDelete:
                let params = try request.decodeParams(RoomDeleteParams.self)
                guard params.confirmar else {
                    throw ProtocolError(name: .confirmation_required, message: "room.delete exige confirmar: true")
                }
                guard let store = roomStores[params.roomID] else {
                    throw ProtocolError(name: .room_not_found, message: "sala \(params.roomID) não existe")
                }
                _ = store.archiveRoom()
                try persistRoom(store)
                roomStores.removeValue(forKey: params.roomID)
                respondEncodable(client, id: request.id, EmptyResult())
            case .memberInvite:
                let params = try request.decodeParams(MemberInviteParams.self)
                let store = try roomStore(params.roomID)
                let invite = store.createInvite(
                    displayName: params.displayName,
                    roles: params.roles,
                    ttlSeconds: params.ttlSeconds)
                let inviteMemberID = "invite-\(invite.token.prefix(8))"
                let member = (try? store.addMember(id: inviteMemberID, displayName: params.displayName, roles: params.roles)) ?? Member(
                    id: inviteMemberID,
                    displayName: params.displayName,
                    roles: params.roles,
                    status: .invited,
                    joinedAt: Date())
                try persistRoom(store)
                respondEncodable(client, id: request.id, MemberInviteResult(
                    member: member, inviteToken: invite.token))
            case .memberInviteList:
                let params = try request.decodeParams(MemberInviteListParams.self)
                let store = try roomStore(params.roomID)
                respondEncodable(client, id: request.id, store.listInvites())
            case .memberInviteRevoke:
                let params = try request.decodeParams(MemberInviteRevokeParams.self)
                let store = try roomStore(params.roomID)
                try store.revokeInvite(token: params.token)
                try persistRoom(store)
                respondEncodable(client, id: request.id, EmptyResult())
            case .memberList:
                let params = try request.decodeParams(MemberListParams.self)
                let store = try roomStore(params.roomID)
                respondEncodable(client, id: request.id, store.getMembers(status: params.status))
            case .memberUpdate:
                let params = try request.decodeParams(MemberUpdateParams.self)
                let store = try roomStore(params.roomID)
                let member = try store.updateMember(
                    id: params.memberID, displayName: params.displayName, roles: params.roles)
                try persistRoom(store)
                respondEncodable(client, id: request.id, MemberResult(member: member))
            case .memberRemove:
                let params = try request.decodeParams(MemberRemoveParams.self)
                let store = try roomStore(params.roomID)
                let member = try store.removeMember(id: params.memberID)
                try persistRoom(store)
                respondEncodable(client, id: request.id, MemberResult(member: member))
            case .agentSessionCreate:
                let params = try request.decodeParams(AgentSessionCreateParams.self)
                let store = try roomStore(params.roomID)
                let session = store.createAgentSession(params)
                try persistRoom(store)
                respondEncodable(client, id: request.id, AgentSessionResult(agentSession: session))
            case .agentSessionGet:
                let params = try request.decodeParams(AgentSessionGetParams.self)
                let sessions = roomStores.values.lazy.compactMap { $0.getAgentSession(id: params.agentSessionID) }
                guard let session = sessions.first else {
                    throw ProtocolError(name: .agent_session_not_found,
                        message: "sessão de agente \(params.agentSessionID) não encontrada")
                }
                respondEncodable(client, id: request.id, AgentSessionResult(agentSession: session))
            case .agentSessionList:
                let params = try request.decodeParams(AgentSessionListParams.self)
                let store = try roomStore(params.roomID)
                respondEncodable(client, id: request.id, store.getAgentSessions(state: params.state))
            case .agentSessionUpdate:
                let params = try request.decodeParams(AgentSessionUpdateParams.self)
                for store in roomStores.values {
                    if store.getAgentSession(id: params.agentSessionID) != nil {
                        let session = try store.updateAgentSession(
                            id: params.agentSessionID, objective: params.objective,
                            state: params.state, conductorID: params.conductorID,
                            summary: params.summary)
                        try persistRoom(store)
                        respondEncodable(client, id: request.id, AgentSessionResult(agentSession: session))
                        return
                    }
                }
                throw ProtocolError(name: .agent_session_not_found,
                    message: "sessão de agente \(params.agentSessionID) não encontrada")
            case .agentSessionHandoffRequest:
                let params = try request.decodeParams(AgentSessionHandoffRequestParams.self)
                for store in roomStores.values {
                    if store.getAgentSession(id: params.agentSessionID) != nil {
                        let session = try store.requestHandoff(
                            sessionID: params.agentSessionID,
                            fromMemberID: currentMemberID,
                            toMemberID: params.toMemberID, scope: params.scope)
                        try persistRoom(store)
                        broadcast(.handoffRequested, ws: nil,
                            HandoffRequestedTopicPayload(sessionID: params.agentSessionID, handoff: session.handoff!))
                        respondEncodable(client, id: request.id, AgentSessionResult(agentSession: session))
                        return
                    }
                }
                throw ProtocolError(name: .agent_session_not_found,
                    message: "sessão de agente \(params.agentSessionID) não encontrada")
            case .agentSessionHandoffAccept:
                let params = try request.decodeParams(AgentSessionHandoffAcceptParams.self)
                for store in roomStores.values {
                    if store.getAgentSession(id: params.agentSessionID) != nil {
                        let session = try store.acceptHandoff(
                            sessionID: params.agentSessionID, by: currentMemberID)
                        try persistRoom(store)
                        broadcast(.handoffAccepted, ws: nil,
                            HandoffAcceptedTopicPayload(sessionID: params.agentSessionID,
                                fromMemberID: session.handoff?.fromMemberID ?? "",
                                toMemberID: currentMemberID, scope: session.handoff?.scope ?? .conductor))
                        if session.conductorID == currentMemberID {
                            broadcast(.conductorChanged, ws: nil,
                                ConductorChangedTopicPayload(sessionID: params.agentSessionID,
                                    previousConductorID: nil, newConductorID: currentMemberID))
                        }
                        respondEncodable(client, id: request.id, AgentSessionResult(agentSession: session))
                        return
                    }
                }
                throw ProtocolError(name: .agent_session_not_found,
                    message: "sessão de agente \(params.agentSessionID) não encontrada")
            case .agentSessionHandoffReject:
                let params = try request.decodeParams(AgentSessionHandoffAcceptParams.self)
                for store in roomStores.values {
                    if store.getAgentSession(id: params.agentSessionID) != nil {
                        let session = try store.rejectHandoff(
                            sessionID: params.agentSessionID, by: currentMemberID)
                        try persistRoom(store)
                        respondEncodable(client, id: request.id, AgentSessionResult(agentSession: session))
                        return
                    }
                }
                throw ProtocolError(name: .agent_session_not_found,
                    message: "sessão de agente \(params.agentSessionID) não encontrada")
            case .agentSessionTransition:
                let params = try request.decodeParams(AgentSessionTransitionParams.self)
                for store in roomStores.values {
                    if store.getAgentSession(id: params.agentSessionID) != nil {
                        let session = try store.transitionSession(id: params.agentSessionID, to: params.state)
                        try persistRoom(store)
                        respondEncodable(client, id: request.id, AgentSessionResult(agentSession: session))
                        return
                    }
                }
                throw ProtocolError(name: .agent_session_not_found,
                    message: "sessão de agente \(params.agentSessionID) não encontrada")
            case .agentSessionBriefing:
                let params = try request.decodeParams(AgentSessionBriefingParams.self)
                for store in roomStores.values {
                    if let briefing = store.buildBriefing(for: params.agentSessionID, newMemberName: NSFullUserName()) {
                        respondEncodable(client, id: request.id, AgentSessionBriefingResult(briefing: briefing))
                        return
                    }
                }
                throw ProtocolError(name: .agent_session_not_found,
                    message: "sessão de agente \(params.agentSessionID) não encontrada")
            case .sessionEventAppend:
                let params = try request.decodeParams(SessionEventAppendParams.self)
                let store = try roomStore(params.roomID)
                let (event, roomSeq, _) = try store.appendEvent(
                    sessionID: params.sessionID, kind: params.kind,
                    payload: params.payload, author: client.author)
                try persistRoom(store)
                broadcast(.sessionEventAppended, ws: nil, SessionEventAppendedTopicPayload(event: event))
                broadcast(.eventAck, ws: nil, EventAckTopicPayload(eventID: event.id, roomSeq: roomSeq))
                respondEncodable(client, id: request.id,
                    SessionEventAppendResult(event: event, roomSeq: roomSeq))
            case .grantIssue:
                let params = try request.decodeParams(GrantIssueParams.self)
                let store = try roomStore(params.roomID)
                let grant = store.issueGrant(
                    subjectID: params.subjectID, resource: params.resource,
                    actions: params.actions, issuedBy: client.author,
                    expiresAt: params.expiresAt, contextHash: params.contextHash)
                try persistRoom(store)
                respondEncodable(client, id: request.id, GrantResult(grant: grant))
            case .grantRevoke:
                let params = try request.decodeParams(GrantRevokeParams.self)
                // grant é global entre rooms — procura em todas
                for store in roomStores.values {
                    if let grant = try? store.revokeGrant(id: params.grantID) {
                        try persistRoom(store)
                        respondEncodable(client, id: request.id, GrantResult(grant: grant))
                        return
                    }
                }
                throw ProtocolError(name: .grant_not_found,
                    message: "grant \(params.grantID) não encontrado")
            case .grantList:
                let params = try request.decodeParams(GrantListParams.self)
                let store = try roomStore(params.roomID)
                respondEncodable(client, id: request.id,
                    store.getGrants(subjectID: params.subjectID, activeOnly: params.activeOnly ?? false))
            case .presenceUpdate:
                let params = try request.decodeParams(PresenceUpdateParams.self)
                let store = try roomStore(params.roomID)
                let memberID = InstallationIdentity.current().string
                let presence = store.updatePresence(
                    memberID: memberID,
                    viewport: params.viewport,
                    selectedNodeID: params.selectedNodeID,
                    viewingSessionID: params.viewingSessionID)
                broadcast(.presenceChanged, ws: nil,
                    PresenceChangedTopicPayload(
                        roomID: presence.roomID, memberID: presence.memberID,
                        viewport: presence.viewport,
                        selectedNodeID: presence.selectedNodeID,
                        viewingSessionID: presence.viewingSessionID,
                        lastSeen: presence.lastSeen))
                respondEncodable(client, id: request.id, EmptyResult())
            case .leaseAcquire:
                let params = try request.decodeParams(LeaseAcquireParams.self)
                let store = try roomStore(params.roomID)
                guard store.getAgentSession(id: params.sessionID) != nil else {
                    throw ProtocolError(name: .agent_session_not_found,
                        message: "sessão \(params.sessionID) não encontrada")
                }
                let memberID = InstallationIdentity.current().string
                let lease = store.acquireLease(sessionID: params.sessionID, scope: params.scope, memberID: memberID)
                broadcast(.leaseAcquired, ws: nil, LeaseAcquiredTopicPayload(lease: lease))
                respondEncodable(client, id: request.id, lease)
            case .leaseRelease:
                let params = try request.decodeParams(LeaseReleaseParams.self)
                _ = roomStores.values.first.map { $0.releaseLease(leaseID: params.leaseID) }
                broadcast(.leaseRevoked, ws: nil, LeaseRevokedTopicPayload(leaseID: params.leaseID))
                respondEncodable(client, id: request.id, EmptyResult())
            // §5.2–5.8 mission model
            case .missionCreate:
                let params = try request.decodeParams(MissionCreateParams.self)
                _ = try roomStore(params.roomID)
                let store = try missionStore(params.roomID)
                let owner = params.ownerID ?? InstallationIdentity.current().string
                let mission = try store.createMission(
                    title: params.title, context: params.context,
                    definitionOfDone: params.definitionOfDone, ownerID: owner)
                try persistMissionStore(params.roomID)
                respondEncodable(client, id: request.id, MissionResult(mission: mission))
            case .missionGet:
                let params = try request.decodeParams(MissionGetParams.self)
                let store = try missionStore(params.roomID)
                guard let mission = store.getMission(params.missionID) else {
                    throw ProtocolError(name: .invalid_params, message: "missão \(params.missionID) não encontrada")
                }
                respondEncodable(client, id: request.id, MissionResult(mission: mission))
            case .missionList:
                let params = try request.decodeParams(MissionListParams.self)
                let store = try missionStore(params.roomID)
                respondEncodable(client, id: request.id, store.listMissions(state: params.state))
            case .missionUpdate:
                let params = try request.decodeParams(MissionUpdateParams.self)
                let store = try missionStore(params.roomID)
                let mission = try store.updateMission(
                    id: params.missionID, title: params.title, context: params.context,
                    definitionOfDone: params.definitionOfDone, ownerID: params.ownerID)
                try persistMissionStore(params.roomID)
                respondEncodable(client, id: request.id, MissionResult(mission: mission))
            case .missionTransition:
                let params = try request.decodeParams(MissionTransitionParams.self)
                let store = try missionStore(params.roomID)
                let mission = try store.transitionMission(
                    id: params.missionID, to: params.state, reason: params.reason)
                try persistMissionStore(params.roomID)
                respondEncodable(client, id: request.id, MissionResult(mission: mission))
            case .workstreamCreate:
                let params = try request.decodeParams(WorkstreamCreateParams.self)
                let store = try missionStore(params.roomID)
                let ws = try store.createWorkstream(
                    missionID: params.missionID, title: params.title, objective: params.objective,
                    definitionOfDone: params.definitionOfDone, assignee: params.assignee,
                    dependsOn: params.dependsOn ?? [])
                try persistMissionStore(params.roomID)
                respondEncodable(client, id: request.id, WorkstreamResult(workstream: ws))
            case .workstreamGet:
                let params = try request.decodeParams(WorkstreamGetParams.self)
                let store = try missionStore(params.roomID)
                guard let ws = store.getWorkstream(params.workstreamID) else {
                    throw ProtocolError(name: .invalid_params, message: "frente \(params.workstreamID) não encontrada")
                }
                respondEncodable(client, id: request.id, WorkstreamResult(workstream: ws))
            case .workstreamList:
                let params = try request.decodeParams(WorkstreamListParams.self)
                let store = try missionStore(params.roomID)
                respondEncodable(
                    client, id: request.id,
                    store.listWorkstreams(missionID: params.missionID, state: params.state))
            case .workstreamUpdate:
                let params = try request.decodeParams(WorkstreamUpdateParams.self)
                let store = try missionStore(params.roomID)
                let ws = try store.updateWorkstream(
                    id: params.workstreamID, title: params.title, objective: params.objective,
                    definitionOfDone: params.definitionOfDone, assignee: params.assignee,
                    clearAssignee: params.clearAssignee ?? false,
                    dependsOn: params.dependsOn, blockedBy: params.blockedBy)
                try persistMissionStore(params.roomID)
                respondEncodable(client, id: request.id, WorkstreamResult(workstream: ws))
            case .workstreamTransition:
                let params = try request.decodeParams(WorkstreamTransitionParams.self)
                let store = try missionStore(params.roomID)
                let ws = try store.transitionWorkstream(id: params.workstreamID, to: params.state)
                try persistMissionStore(params.roomID)
                respondEncodable(client, id: request.id, WorkstreamResult(workstream: ws))
            case .workstreamBriefing:
                let params = try request.decodeParams(WorkstreamBriefingParams.self)
                let store = try missionStore(params.roomID)
                let text = try store.buildWorkstreamBriefing(
                    workstreamID: params.workstreamID,
                    agentName: params.agentName,
                    agentRole: params.agentRole,
                    capabilities: params.capabilities ?? [],
                    allowedArtifacts: params.allowedArtifacts ?? [])
                respondEncodable(client, id: request.id, WorkstreamBriefingResult(briefing: text))
            case .decisionCreate:
                let params = try request.decodeParams(DecisionCreateParams.self)
                let store = try missionStore(params.roomID)
                let decision = try store.createDecision(
                    missionID: params.missionID, workstreamID: params.workstreamID,
                    question: params.question, options: params.options ?? [],
                    requestedBy: client.author, dueAt: params.dueAt)
                try persistMissionStore(params.roomID)
                respondEncodable(client, id: request.id, DecisionResult(decision: decision))
            case .decisionGet:
                let params = try request.decodeParams(DecisionGetParams.self)
                let store = try missionStore(params.roomID)
                guard let decision = store.getDecision(params.decisionID) else {
                    throw ProtocolError(name: .invalid_params, message: "decisão \(params.decisionID) não encontrada")
                }
                respondEncodable(client, id: request.id, DecisionResult(decision: decision))
            case .decisionList:
                let params = try request.decodeParams(DecisionListParams.self)
                let store = try missionStore(params.roomID)
                respondEncodable(
                    client, id: request.id,
                    store.listDecisions(missionID: params.missionID, state: params.state))
            case .decisionDecide:
                let params = try request.decodeParams(DecisionDecideParams.self)
                let store = try missionStore(params.roomID)
                let decider = params.deciderID ?? InstallationIdentity.current().string
                let decision = try store.decide(
                    id: params.decisionID, decisionText: params.decision,
                    rationale: params.rationale, deciderID: decider)
                try persistMissionStore(params.roomID)
                respondEncodable(client, id: request.id, DecisionResult(decision: decision))
            case .decisionSupersede:
                let params = try request.decodeParams(DecisionIDParams.self)
                let store = try missionStore(params.roomID)
                let decision = try store.supersedeDecision(id: params.decisionID)
                try persistMissionStore(params.roomID)
                respondEncodable(client, id: request.id, DecisionResult(decision: decision))
            case .decisionCancel:
                let params = try request.decodeParams(DecisionIDParams.self)
                let store = try missionStore(params.roomID)
                let decision = try store.cancelDecision(id: params.decisionID)
                try persistMissionStore(params.roomID)
                respondEncodable(client, id: request.id, DecisionResult(decision: decision))
            case .relationAdd:
                let params = try request.decodeParams(RelationAddParams.self)
                let store = try missionStore(params.roomID)
                let relation = try store.addRelation(
                    fromID: params.fromID, toID: params.toID, kind: params.kind,
                    author: client.author, labelPosition: params.labelPosition)
                try persistMissionStore(params.roomID)
                respondEncodable(client, id: request.id, RelationResult(relation: relation))
            case .relationList:
                let params = try request.decodeParams(RelationListParams.self)
                let store = try missionStore(params.roomID)
                respondEncodable(client, id: request.id, store.listRelations(kind: params.kind))
            case .relationRemove:
                let params = try request.decodeParams(RelationRemoveParams.self)
                let store = try missionStore(params.roomID)
                _ = try store.removeRelation(id: params.relationID)
                try persistMissionStore(params.roomID)
                respondEncodable(client, id: request.id, EmptyResult())
            case .workspacePushSnapshot, .workspaceCatchUp:
                throw ProtocolError(name: .invalid_params, message: "método exclusivo do Hub: \(request.method)")
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

    /// Uma identidade de agente só pode operar no workspace de seu TerminalNode.
    /// A checagem vem antes de consultar conteúdo para não revelar dados de outro workspace.
    private func authorizeWorkspace(_ id: ULID, author: Author) throws -> WorkspaceState {
        let state = try requireWorkspace(id)
        if case .agente(let rawID) = author {
            guard let nodeID = ULID(rawID), state.terminalNode(nodeID) != nil else {
                throw ProtocolError(name: .invalid_params, message: "agente não autorizado neste workspace")
            }
        }
        return state
    }

    private func activeFloor(_ id: ULID, in workspaceID: ULID) throws -> Floor {
        guard let floor = floors[id], floor.origem == workspaceID, floor.estado == .ativo else {
            throw ProtocolError(name: .invalid_params, message: "andar não está ativo neste workspace")
        }
        return floor
    }

    /// Associa um nó novo ao piso indicado e emite a mudança observável de floors.json.
    private func assignNode(_ nodeID: ULID, toFloor floorID: ULID?, workspaceID: ULID) throws {
        guard let floorID else { return }
        var floor = try activeFloor(floorID, in: workspaceID)
        guard !floor.nos.contains(nodeID) else { return }
        floor.nos.append(nodeID)
        floors[floor.id] = floor
        saveFloors(workspaceID)
        broadcast(.floorChanged, ws: workspaceID, FloorChangedTopicPayload(floor: floor))
    }

    private func floorID(for nodeID: ULID, in workspaceID: ULID) -> ULID? {
        floors.values.first(where: {
            $0.origem == workspaceID && $0.estado == .ativo && $0.nos.contains(nodeID)
        })?.id
    }

    /// ID de membro estável da instalação corrente.
    private var currentMemberID: String { InstallationIdentity.current().string }

    /// Multiplayer: obtém ou cria o RoomStore para a sala indicada.
    private func roomStore(_ roomID: ULID) throws -> RoomStore {
        if let store = roomStores[roomID] { return store }
        if let store = try? RoomStore.load(from: paths, roomID: roomID),
           store.getRoom().state == .active {
            roomStores[roomID] = store
            if missionStores[roomID] == nil {
                missionStores[roomID] = (try? MissionStore.load(from: paths, roomID: roomID))
                    ?? MissionStore(roomID: roomID)
            }
            return store
        }
        throw ProtocolError(name: .room_not_found, message: "sala \(roomID) não existe")
    }

    private func missionStore(_ roomID: ULID) throws -> MissionStore {
        // §5.1 — instalação local PODE operar Missão sem Hub; se a sala ainda
        // não está em memória, materializa uma sala pessoal com o mesmo id.
        if roomStores[roomID] == nil {
            let now = Date()
            let ownerID = InstallationIdentity.current().string
            let room = Room(
                id: roomID, name: "Sala local", ownerID: ownerID,
                createdAt: now, updatedAt: now)
            let store = RoomStore(room: room)
            _ = try? store.addMember(id: ownerID, displayName: NSFullUserName(), roles: [.owner])
            roomStores[roomID] = store
            try? persistRoom(store)
        }
        if let store = missionStores[roomID] { return store }
        let store = MissionStore(roomID: roomID)
        missionStores[roomID] = store
        return store
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
        let state = try WorkspaceState(
            paths: paths,
            workspace: workspace,
            snapshotEveryOps: config.documentSnapshotEveryOps)
        try state.saveWorkspace()
        workspaces[workspace.id] = state
        deliveryStores[workspace.id] = try DeliveryStore(directory: paths.deliveriesDir(workspace.id))
        watchdogConfigurations[workspace.id] = WorkerWatchdogConfiguration()
        workerArchives[workspace.id] = WorkerArchiveService()
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
        deliveryStores.removeValue(forKey: params.id)
        watchdogConfigurations.removeValue(forKey: params.id)
        workerArchives.removeValue(forKey: params.id)
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

    // MARK: - Memória, entregas e operação de workers

    private func memoryStore(_ workspaceID: ULID) -> WorkspaceMemoryStore {
        WorkspaceMemoryStore(workspaceDirectory: paths.memoryDir(workspaceID))
    }

    private func deliveryStore(_ workspaceID: ULID) throws -> DeliveryStore {
        if let store = deliveryStores[workspaceID] { return store }
        let store = try DeliveryStore(directory: paths.deliveriesDir(workspaceID))
        deliveryStores[workspaceID] = store
        return store
    }

    private func handleMemoryGet(_ params: MemoryGetParams, author: Author) throws -> MemoryGetResult {
        _ = try authorizeWorkspace(params.workspaceID, author: author)
        let store = memoryStore(params.workspaceID)
        return MemoryGetResult(memory: store.get(), briefing: store.briefing())
    }

    private func handleMemoryUpdate(_ params: MemoryUpdateParams, author: Author) throws -> MemoryGetResult {
        _ = try authorizeWorkspace(params.workspaceID, author: author)
        do {
            let store = memoryStore(params.workspaceID)
            let memory = try store.update(params.content, author: author)
            broadcast(.memoryChanged, ws: params.workspaceID,
                MemoryChangedTopicPayload(workspaceID: params.workspaceID, memory: memory))
            return MemoryGetResult(memory: memory, briefing: store.briefing())
        } catch {
            throw contentProtocolError(error)
        }
    }

    private func handleMemoryPropose(
        _ params: MemoryProposeParams, author: Author
    ) throws -> MemoryProposal {
        _ = try authorizeWorkspace(params.workspaceID, author: author)
        do {
            let proposal = try memoryStore(params.workspaceID).propose(
                params.content, author: author, id: params.proposalID ?? ULID.generate())
            broadcast(.memoryChanged, ws: params.workspaceID,
                MemoryChangedTopicPayload(workspaceID: params.workspaceID, proposal: proposal))
            return proposal
        } catch {
            throw contentProtocolError(error)
        }
    }

    private func handleMemoryAccept(
        _ params: MemoryProposalResolveParams, author: Author
    ) throws -> MemoryGetResult {
        _ = try authorizeWorkspace(params.workspaceID, author: author)
        do {
            let store = memoryStore(params.workspaceID)
            let memory = try store.accept(
                params.proposalID, author: author, editedContent: params.editedContent)
            let proposal = store.list().first { $0.id == params.proposalID }
            broadcast(.memoryChanged, ws: params.workspaceID,
                MemoryChangedTopicPayload(
                    workspaceID: params.workspaceID, memory: memory, proposal: proposal))
            _ = try? store.appendDaily(
                "Proposta de memória \(params.proposalID) aceita por \(author.rawValue).",
                author: .sistema)
            return MemoryGetResult(memory: memory, briefing: store.briefing())
        } catch {
            throw contentProtocolError(error)
        }
    }

    private func handleMemoryReject(
        _ params: MemoryProposalResolveParams, author: Author
    ) throws -> MemoryProposal {
        _ = try authorizeWorkspace(params.workspaceID, author: author)
        do {
            let proposal = try memoryStore(params.workspaceID).reject(
                params.proposalID, author: author, note: params.note)
            broadcast(.memoryChanged, ws: params.workspaceID,
                MemoryChangedTopicPayload(workspaceID: params.workspaceID, proposal: proposal))
            return proposal
        } catch {
            throw contentProtocolError(error)
        }
    }

    private func handleDeliverySubmit(
        _ params: DeliverySubmitParams, author: Author
    ) throws -> Delivery {
        let submission = params.submission
        _ = try authorizeWorkspace(submission.workspaceID, author: author)
        guard let meta = sessions[submission.sessionID]?.dto() ?? sessionMetas[submission.sessionID],
              meta.workspaceID == submission.workspaceID,
              meta.nodeID == submission.nodeID
        else {
            throw ProtocolError(
                name: .invalid_params,
                message: "sessão, nó e workspace da entrega não correspondem")
        }
        if case .agente(let rawNodeID) = author, rawNodeID != submission.nodeID.string {
            throw ProtocolError(name: .invalid_params, message: "agente só pode entregar pelo próprio nó")
        }
        do {
            let delivery = try deliveryStore(submission.workspaceID).submit(submission, author: author)
            broadcast(.deliveryChanged, ws: submission.workspaceID,
                DeliveryChangedTopicPayload(delivery: delivery))
            _ = try? memoryStore(submission.workspaceID).appendDaily(
                "Entrega \(delivery.id) declarada \(delivery.estado.rawValue): \(delivery.resumo)",
                author: .sistema)
            return delivery
        } catch {
            throw contentProtocolError(error)
        }
    }

    private func handleDeliveryReview(
        _ deliveryID: ULID, accept: Bool, author: Author
    ) throws -> Delivery {
        guard case .humano = author else {
            throw ProtocolError(name: .invalid_params, message: "revisão de entrega exige identidade humana")
        }
        for (workspaceID, store) in deliveryStores {
            guard store.delivery(id: deliveryID) != nil else { continue }
            do {
                let delivery = accept
                    ? try store.accept(deliveryID, by: author)
                    : try store.reopen(deliveryID, by: author)
                broadcast(.deliveryChanged, ws: workspaceID,
                    DeliveryChangedTopicPayload(delivery: delivery))
                _ = try? memoryStore(workspaceID).appendDaily(
                    "Entrega \(delivery.id) \(accept ? "aceita" : "reaberta") por \(author.rawValue).",
                    author: .sistema)
                return delivery
            } catch {
                throw contentProtocolError(error)
            }
        }
        throw ProtocolError(name: .invalid_params, message: "entrega \(deliveryID) não existe")
    }

    private func handleWatchdogUpdate(_ params: WatchdogUpdateParams, author: Author) throws {
        _ = try authorizeWorkspace(params.workspaceID, author: author)
        guard case .humano = author else {
            throw ProtocolError(name: .invalid_params, message: "configurar watchdog exige identidade humana")
        }
        watchdogConfigurations[params.workspaceID] = params.configuration
        try AtomicJSON.write(params.configuration, to: paths.watchdogFile(params.workspaceID))
    }

    private func handleWorkerArchive(
        _ params: WorkerArchiveParams, author: Author
    ) throws -> WorkerArchiveTombstone {
        _ = try authorizeWorkspace(params.workspaceID, author: author)
        guard case .humano = author else {
            throw ProtocolError(name: .invalid_params, message: "arquivar worker exige identidade humana")
        }
        guard let meta = sessionMetas[params.sessionID], meta.workspaceID == params.workspaceID else {
            throw ProtocolError(name: .session_not_found, message: "sessão \(params.sessionID) não existe")
        }
        let matching = (try? deliveryStore(params.workspaceID).deliveries(workspaceID: params.workspaceID))
            ?? []
        let accepted = matching.filter { $0.sessionID == params.sessionID && $0.aceita }
        let evidence = WorkerArchiveEvidence(
            journal: meta.journal,
            deliveryIDs: matching.filter { $0.sessionID == params.sessionID }.map(\.id),
            approvalIDs: approvals.values.filter { $0.sessionID == params.sessionID }.map(\.id),
            relatedNodeIDs: [meta.nodeID])
        let service = workerArchives[params.workspaceID] ?? WorkerArchiveService()
        workerArchives[params.workspaceID] = service
        switch service.decide(
            action: .archive, session: meta, evidence: evidence,
            deliveryAccepted: !accepted.isEmpty, humanConfirmed: params.confirmar,
            initiator: .human)
        {
        case .archived(let tombstone):
            try AtomicJSON.write(service.tombstones(), to: paths.workerArchiveFile(params.workspaceID))
            broadcast(.workerArchived, ws: params.workspaceID,
                WorkerArchivedTopicPayload(workspaceID: params.workspaceID, tombstone: tombstone))
            _ = try? memoryStore(params.workspaceID).appendDaily(
                "Worker da sessão \(params.sessionID) arquivado; replay preservado.",
                author: .sistema)
            return tombstone
        case .refused(let refusal):
            throw ProtocolError(name: .invalid_params, message: "worker não arquivado: \(refusal.rawValue)")
        default:
            throw ProtocolError(name: .internal_error, message: "resultado de arquivo inesperado")
        }
    }

    private func handleWorkerRestore(
        _ params: WorkerRestoreParams, author: Author
    ) throws -> WorkerRestoreResult {
        _ = try authorizeWorkspace(params.workspaceID, author: author)
        guard case .humano = author else {
            throw ProtocolError(name: .invalid_params, message: "restaurar replay exige identidade humana")
        }
        guard let service = workerArchives[params.workspaceID],
              let decision = service.restoreForReplay(tombstoneID: params.archiveID)
        else {
            throw ProtocolError(name: .invalid_params, message: "arquivo \(params.archiveID) não existe")
        }
        guard case .restoreReplay(let session, let journal) = decision else {
            throw ProtocolError(name: .internal_error, message: "replay arquivado indisponível")
        }
        try AtomicJSON.write(service.tombstones(), to: paths.workerArchiveFile(params.workspaceID))
        return WorkerRestoreResult(session: session, journal: journal)
    }

    private func handleWorkerAcquire(
        _ params: WorkerAcquireParams,
        author: Author,
        excluding excludedNodeID: ULID? = nil
    ) throws -> WorkerAcquireResult {
        let state = try authorizeWorkspace(params.workspaceID, author: author)
        guard !params.role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProtocolError(name: .invalid_params, message: "role do worker não pode ser vazio")
        }
        let candidates = state.nodes.values.compactMap { node -> TerminalNode? in
            guard case .terminal(let terminal) = node,
                  terminal.id != excludedNodeID,
                  terminal.adapter.caseInsensitiveCompare(params.adapter) == .orderedSame,
                  terminal.papel?.caseInsensitiveCompare(params.role) == .orderedSame else { return nil }
            return terminal
        }
        let busyNodeIDs = Set(
            (delegations[params.workspaceID]?.values ?? Dictionary<ULID, Delegation>().values)
                .filter { !$0.estado.isTerminal }
                .map(\.subagentNodeID)
        )
        let chosen: TerminalNode
        let reused: Bool
        if !params.newIdentity, let running = candidates.first(where: {
            guard !busyNodeIDs.contains($0.id) else { return false }
            guard let sid = nodeSessions[$0.id], let session = sessions[sid] else { return false }
            return session.estado.isViva
        }) {
            chosen = running; reused = true
        } else if !params.newIdentity, let parked = candidates.first(where: {
            !busyNodeIDs.contains($0.id)
                && !(nodeSessions[$0.id].flatMap { sessions[$0] }?.estado.isViva ?? false)
        }) {
            chosen = parked; reused = true
        } else {
            let base = "\(params.role)-worker"
            let existing = Set(state.nodes.values.compactMap { if case .terminal(let t) = $0 { return t.nome.lowercased() }; return nil })
            var name = base; var suffix = 2
            while existing.contains(name.lowercased()) { name = "\(base)-\(suffix)"; suffix += 1 }
            let node = TerminalNode(id: ULID.generate(), posicao: Ponto(x: 80, y: 80), tamanho: Tamanho(w: 640, h: 420), criadoEm: Date(), nome: name, papel: params.role, adapter: params.adapter, cwd: state.workspace.caminhoRaiz ?? FileManager.default.homeDirectoryForCurrentUser.path)
            let proposal = DocOp(opID: ULID.generate(), author: author, ts: Date(), payload: .nodeAdd(NodeAddOpPayload(node: .terminal(node))))
            guard let applied = try? state.applyProposal(proposal, liveNodeIDs: liveNodeIDs) else {
                throw ProtocolError(name: .internal_error, message: "não foi possível criar o subagente")
            }
            broadcast(.documentOp, ws: params.workspaceID, DocumentOpTopicPayload(workspaceID: params.workspaceID, op: applied, seq: applied.seq ?? 0))
            try? state.saveWorkspace()
            chosen = node; reused = false
        }
        let session = try handleSessionEnsure(SessionEnsureParams(workspaceID: params.workspaceID, nodeID: chosen.id))
        return WorkerAcquireResult(node: chosen, session: session, reused: reused)
    }

    private func persistDelegations(_ workspaceID: ULID) {
        let values = Array(delegations[workspaceID]?.values ?? Dictionary<ULID, Delegation>().values)
            .sorted { $0.id.string < $1.id.string }
        try? AtomicJSON.write(values, to: paths.delegationsFile(workspaceID))
    }

    private static func readSemanticEvents(from url: URL) -> [SemanticEvent] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? ColmeiaJSON.decoder().decode(SemanticEvent.self, from: Data($0)) }
    }

    private func recordSemanticEvent(_ event: SemanticEvent) {
        semanticEvents[event.workspaceID, default: []].append(event)
        let count = semanticEvents[event.workspaceID]?.count ?? 0
        if count > 2_000 {
            semanticEvents[event.workspaceID]?.removeFirst(count - 2_000)
        }
        guard let data = try? ColmeiaJSON.encoder().encode(event) else { return }
        let url = paths.semanticEventsFile(event.workspaceID)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(data); handle.write(Data([0x0A])); try? handle.close()
        } else {
            var line = data
            line.append(0x0A)
            try? line.write(to: url, options: Data.WritingOptions.atomic)
        }
    }

    private func handleDelegationCreate(_ params: DelegationCreateParams, author: Author) throws -> DelegationResult {
        let state = try authorizeWorkspace(params.workspaceID, author: author)
        guard state.terminalNode(params.principalNodeID) != nil else {
            throw ProtocolError(name: .node_not_found, message: "principal não existe")
        }
        let acquired = try handleWorkerAcquire(
            WorkerAcquireParams(
                workspaceID: params.workspaceID, role: params.role,
                adapter: params.adapter, newIdentity: params.newIdentity),
            author: author,
            excluding: params.principalNodeID)
        let principalSession = nodeSessions[params.principalNodeID].flatMap { sessions[$0] }
        let delegation = Delegation(
            workspaceID: params.workspaceID,
            principalNodeID: params.principalNodeID,
            subagentNodeID: acquired.node.id,
            task: params.task,
            principalSessionID: principalSession?.id,
            subagentSessionID: acquired.session.id,
            estado: .running,
            startedAt: Date())
        delegations[params.workspaceID, default: [:]][delegation.id] = delegation
        persistDelegations(params.workspaceID)
        recordSemanticEvent(SemanticEvent(
            workspaceID: params.workspaceID, sessionID: acquired.session.id,
            nodeID: acquired.node.id, kind: .delegationStarted, text: params.task,
            metadata: [
                "delegation_id": delegation.id.string,
                "principal_node_id": params.principalNodeID.string
            ]))

        let completionCommand =
            "colmeia done --delegation \(delegation.id.string) --status completed --summary \"<short result>\""
        let prompt = """
        Delegation \(delegation.id.string) from your primary agent:
        \(params.task)

        Complete the task, then report it exactly once with:
        \(completionCommand)
        """
        if let child = sessions[acquired.session.id] {
            sessionInput(
                child, data: Data(prompt.utf8),
                author: .agente(params.principalNodeID.string), terminalInput: false)
            stateQueue.asyncAfter(deadline: .now() + .milliseconds(120)) { [weak self, weak child] in
                guard let self, let child, child.estado.isViva else { return }
                self.sessionInput(
                    child, data: Data([0x0D]),
                    author: .agente(params.principalNodeID.string), terminalInput: false)
            }
        }
        return DelegationResult(delegation: delegation)
    }

    private func handleDelegationWait(
        _ params: DelegationWaitParams,
        request: RequestMessage,
        client: ClientConnection
    ) {
        guard let delegation = delegations.values.compactMap({ $0[params.delegationID] }).first else {
            client.respond(
                id: request.id,
                error: ProtocolError(name: .invalid_params, message: "delegação não existe"))
            return
        }
        do {
            _ = try authorizeWorkspace(delegation.workspaceID, author: client.author)
        } catch let error as ProtocolError {
            client.respond(id: request.id, error: error)
            return
        } catch {
            client.respond(
                id: request.id,
                error: ProtocolError(name: .internal_error, message: "\(error)"))
            return
        }
        if delegation.estado.isTerminal {
            respondEncodable(client, id: request.id, DelegationResult(delegation: delegation))
            return
        }
        delegationWaiters[delegation.id, default: []].append { [weak client] completed in
            client?.respond(
                id: request.id,
                result: (try? JSONValue(encoding: DelegationResult(delegation: completed)))
                    ?? .object([:]))
        }
    }

    private func handleDelegationDone(_ params: DelegationDoneParams, author: Author) throws -> DelegationResult {
        guard let current = delegations.values.compactMap({ $0[params.delegationID] }).first else { throw ProtocolError(name: .invalid_params, message: "delegação não existe") }
        guard case .agente(let nodeRaw) = author, ULID(nodeRaw) == current.subagentNodeID else { throw ProtocolError(name: .invalid_params, message: "somente o subagente pode concluir esta delegação") }
        guard params.status.isTerminal else {
            throw ProtocolError(name: .invalid_params, message: "status final inválido: \(params.status.rawValue)")
        }
        if current.estado.isTerminal {
            guard current.estado == params.status,
                  current.result == params.result,
                  current.deliveryID == params.deliveryID else {
                throw ProtocolError(
                    name: .invalid_params,
                    message: "delegação já concluída com outro resultado")
            }
            return DelegationResult(delegation: current)
        }
        var updated = current
        updated.estado = params.status
        updated.result = params.result
        updated.deliveryID = params.deliveryID
        updated.completedAt = Date()
        delegations[updated.workspaceID]?[updated.id] = updated
        persistDelegations(updated.workspaceID)
        recordSemanticEvent(SemanticEvent(
            workspaceID: updated.workspaceID, sessionID: updated.subagentSessionID,
            nodeID: updated.subagentNodeID, kind: .delegationCompleted,
            text: updated.result,
            metadata: [
                "delegation_id": updated.id.string,
                "status": updated.estado.rawValue
            ]))
        if let sessionID = updated.subagentSessionID,
           let child = sessions[sessionID],
           let pty = child.pty {
            terminateGracefully(child, pty: pty)
            notifyDelegationWaitersAfterParking(
                updated, sessionID: sessionID,
                deadline: Date().addingTimeInterval(4))
        } else {
            notifyDelegationWaiters(updated)
        }
        return DelegationResult(delegation: updated)
    }

    private func notifyDelegationWaiters(_ delegation: Delegation) {
        let waiters = delegationWaiters.removeValue(forKey: delegation.id) ?? []
        waiters.forEach { $0(delegation) }
    }

    private func notifyDelegationWaitersAfterParking(
        _ delegation: Delegation,
        sessionID: ULID,
        deadline: Date
    ) {
        if sessions[sessionID]?.estado.isViva != true || Date() >= deadline {
            notifyDelegationWaiters(delegation)
            return
        }
        stateQueue.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
            self?.notifyDelegationWaitersAfterParking(
                delegation, sessionID: sessionID, deadline: deadline)
        }
    }

    /// Relações ativas sobrevivem ao processo do engine. Cada subagente retoma
    /// sua casa Codex isolada e recebe um lembrete da mesma delegação, nunca uma
    /// identidade nova.
    private func recoverActiveDelegations() {
        for workspaceID in Array(delegations.keys) {
            let active = delegations[workspaceID]?.values.filter {
                !$0.estado.isTerminal
            } ?? []
            for current in active {
                do {
                    let session = try handleSessionEnsure(SessionEnsureParams(
                        workspaceID: workspaceID,
                        nodeID: current.subagentNodeID))
                    var updated = current
                    updated.subagentSessionID = session.id
                    // O pedido antigo de aprovação morreu com o PTY; a conversa
                    // retomada poderá pedi-lo novamente de forma íntegra.
                    updated.pendingApprovalID = nil
                    if updated.estado == .waitingApproval {
                        updated.estado = .running
                    }
                    delegations[workspaceID]?[updated.id] = updated
                    persistDelegations(workspaceID)
                    guard let child = sessions[session.id] else { continue }
                    let reminder = """
                    Resume delegation \(updated.id.string) after the Colmeia engine restarted.
                    Task: \(updated.task)
                    Continue from your preserved context. When complete, run:
                    colmeia done --delegation \(updated.id.string) --status completed --summary "<short result>"
                    """
                    stateQueue.asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self, weak child] in
                        guard let self, let child, child.estado.isViva else { return }
                        self.sessionInput(
                            child, data: Data(reminder.utf8),
                            author: .agente(updated.principalNodeID.string),
                            terminalInput: false)
                        self.stateQueue.asyncAfter(deadline: .now() + .milliseconds(120)) { [weak self, weak child] in
                            guard let self, let child, child.estado.isViva else { return }
                            self.sessionInput(
                                child, data: Data([0x0D]),
                                author: .agente(updated.principalNodeID.string),
                                terminalInput: false)
                        }
                    }
                } catch {
                    log.warn(
                        "delegation_recovery_failed",
                        "\(current.id.string): \(error)",
                        workspaceID: workspaceID)
                }
            }
        }
    }

    private func contentProtocolError(_ error: Error) -> ProtocolError {
        ProtocolError(name: .invalid_params, message: (error as? LocalizedError)?.errorDescription ?? "\(error)")
    }

    private func runWatchdog() {
        let now = Date()
        for session in sessions.values where session.estado.isViva {
            let configuration = watchdogConfigurations[session.workspaceID] ?? WorkerWatchdogConfiguration()
            let policy = configuration.policy(for: session.id)
            if watchdogAlertedSessions.contains(session.id),
               (!policy.enabled || now.timeIntervalSince(session.lastActivityAt) < policy.staleAfter)
            {
                watchdogAlertedSessions.remove(session.id)
                broadcast(.watchdogAlert, ws: session.workspaceID, WatchdogAlertTopicPayload(
                    workspaceID: session.workspaceID, sessionID: session.id,
                    kind: "recovered", episode: 0,
                    message: "O worker voltou a registrar atividade."))
            }
            let snapshot = WorkerActivitySnapshot(
                sessionID: session.id, workspaceID: session.workspaceID,
                state: session.estado, lastActivityAt: session.lastActivityAt)
            switch watchdog.evaluate(snapshot, configuration: configuration) {
            case .none:
                continue
            case .nudge(_, let episode):
                watchdogAlertedSessions.insert(session.id)
                let text = "[colmeia] Watchdog: não houve atividade recente. "
                    + "Registre a entrega com `colmeia done`, ou declare claramente o bloqueio."
                broadcast(.watchdogAlert, ws: session.workspaceID, WatchdogAlertTopicPayload(
                    workspaceID: session.workspaceID, sessionID: session.id,
                    kind: "nudge", episode: episode, message: text))
                // O nudge é a única intervenção do watchdog e é limitado pela
                // política a no máximo dois por episódio; nunca mata/reinicia.
                deliver(QueuedMessage(
                    id: ULID.generate(), deNode: session.nodeID, texto: text,
                    enqueuedAt: now, sistema: true, systemName: "watchdog_nudge"), to: session)
            case .escalate(_, let episode):
                watchdogAlertedSessions.insert(session.id)
                let text = "Worker sem progresso após o limite de nudges; revisão humana necessária."
                broadcast(.watchdogAlert, ws: session.workspaceID, WatchdogAlertTopicPayload(
                    workspaceID: session.workspaceID, sessionID: session.id,
                    kind: "escalate", episode: episode, message: text))
                broadcast(.engineWarning, ws: session.workspaceID, EngineWarningTopicPayload(
                    name: "watchdog_escalated", message: text))
                _ = try? memoryStore(session.workspaceID).appendDaily(
                    "Watchdog escalou a sessão \(session.id) para revisão humana.",
                    author: .sistema)
            }
        }
    }

    // MARK: - session.* (§9, §24.2, §24.3)

    private func handleSessionStart(_ params: SessionStartParams) throws -> Session {
        guard !StorageHealth.shared.readOnlyForNewSessions else {
            let detail = StorageHealth.shared.lastFailure.map {
                " (\($0.operation), errno \($0.code))"
            } ?? ""
            throw ProtocolError(
                name: .internal_error,
                message: "armazenamento sem espaço; novas sessões estão bloqueadas\(detail)")
        }
        let state = try requireWorkspace(params.workspaceID)
        guard let node = state.terminalNode(params.nodeID) else {
            throw ProtocolError(name: .node_not_found, message: "TerminalNode \(params.nodeID) não existe")
        }
        let effectiveFloorID = params.floorID ?? activeFloor[params.workspaceID]
        var sessionFloor: Floor?
        if let floorID = effectiveFloorID {
            guard let floor = floors[floorID] else {
                throw ProtocolError(name: .floor_not_found, message: "andar \(floorID) não existe")
            }
            guard floor.origem == params.workspaceID, floor.estado == .ativo else {
                throw ProtocolError(
                    name: .invalid_params,
                    message: "andar não está ativo neste workspace")
            }
            if let activeID = activeFloor[params.workspaceID], activeID != floorID {
                throw ProtocolError(
                    name: .invalid_params,
                    message: "floor_id diverge do andar ativo")
            }
            sessionFloor = floor
        }
        if let sid = nodeSessions[params.nodeID], sessions[sid]?.estado.isViva == true {
            throw ProtocolError(name: .session_already_running, message: "nó já tem sessão viva: \(sid)")
        }
        guard let adapter = registry.find(node.adapter) else {
            throw ProtocolError(name: .adapter_not_found, message: "adapter \(node.adapter) não registrado")
        }
        let codexHome: URL?
        if node.adapter == "codex" {
            codexHome = try CodexAgentHome.prepare(
                paths: paths,
                workspaceID: params.workspaceID,
                nodeID: node.id,
                inheritedEnvironment: baseEnvironment)
        } else {
            codexHome = nil
        }
        let plan = adapter.launch(LaunchConfig(
            node: node, workspace: state.workspace,
            conexoes: vizinhosDeConversa(de: node.id, em: state),
            memoria: memoryStore(params.workspaceID).briefing(),
            retomarSessao: codexHome.map(CodexAgentHome.hasSession(in:)) ?? false,
            modelo: node.modelo))
        var executable = plan.executavel
        var args = plan.args
        if let override = node.comandoOverride, !override.isEmpty {
            // §10.2 — override substitui executável+args do adapter, mantendo a env
            executable = "/bin/sh"
            args = ["-c", override]
        } else if !adapter.disponivel() {
            throw ProtocolError(name: .adapter_launch_failed, message: "binário de \(node.adapter) não encontrado (§22.2)")
        }

        // §9.1 — geometria inicial do cliente; sem cliente informando, default do engine.
        let cols = params.cols ?? 120
        let rows = params.rows ?? 32
        guard cols > 0, rows > 0, cols <= 4096, rows <= 4096 else {
            throw ProtocolError(name: .invalid_params, message: "geometria inicial inválida")
        }

        let sessionID = ULID.generate()
        // §10.2 — env herdada saneada (nunca vazar marcadores de sessão do Claude Code).
        var env = SessionEnv.inherited(from: baseEnvironment)
        for (key, value) in plan.envExtra { env[key] = value }
        env[ColmeiaEnv.socket] = paths.engineSocket.path
        env[ColmeiaEnv.sessionID] = sessionID.string
        env[ColmeiaEnv.nodeID] = node.id.string
        env[ColmeiaEnv.workspaceID] = state.workspace.id.string
        if let codexHome { env["CODEX_HOME"] = codexHome.path }
        env["TERM"] = "xterm-256color"
        env["PATH"] = ([cliDirectory] + executableSearchPath(environment: env))
            .joined(separator: ":")

        // Um nó do andar sempre nasce no worktree/clone isolado. O cwd gravado no
        // TerminalNode continua sendo o fallback do térreo e para arquivos antigos.
        var cwd = sessionFloor?.caminho ?? node.cwd
        if cwd.isEmpty { cwd = state.workspace.caminhoRaiz ?? NSHomeDirectory() }
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir) || !isDir.boolValue {
            cwd = NSHomeDirectory()
        }

        let journal = try SessionJournal(
            url: paths.sessionJournal(workspace: params.workspaceID, session: sessionID),
            policy: config.journalPolicy)
        // §8.2/§9.1 — geometria inicial GRAVADA como primeiro evento: o replay configura
        // o emulador antes do primeiro feed e reconstrói a mesma tela do vivo.
        journal.append(.resize(ResizeEventPayload(cols: cols, rows: rows)), author: .sistema)
        let live = LiveSession(
            id: sessionID, workspaceID: params.workspaceID, nodeID: node.id, nodeNome: node.nome,
            adapterID: node.adapter, monitorar: node.monitorarAtividade, journal: journal,
            cols: cols, rows: rows)
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
        if var floor = sessionFloor, !floor.nos.contains(node.id) {
            floor.nos.append(node.id)
            floors[floor.id] = floor
            saveFloors(params.workspaceID)
        }
        saveMeta(live.dto())
        startReader(live)
        log.info("session_start", "\(node.nome) (\(node.adapter))", sessionID: sessionID, workspaceID: params.workspaceID)
        return live.dto()
    }

    private func handleSessionEnsure(_ params: SessionEnsureParams) throws -> Session {
        let state = try requireWorkspace(params.workspaceID)
        guard state.terminalNode(params.nodeID) != nil else {
            throw ProtocolError(name: .node_not_found, message: "TerminalNode \(params.nodeID) não existe")
        }
        if let sid = nodeSessions[params.nodeID], let live = sessions[sid], live.estado.isViva {
            return live.dto()
        }
        return try handleSessionStart(SessionStartParams(
            workspaceID: params.workspaceID,
            nodeID: params.nodeID,
            floorID: params.floorID,
            cols: params.cols,
            rows: params.rows))
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
        watchdog.forget(sessionID: session.id)
        watchdogAlertedSessions.remove(session.id)
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
        if let limit = params.limit, limit >= 0, events.count > limit {
            events = Array(events.suffix(limit))
        }
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
            sessionID: session.id, estado: novo, motivo: motivo,
            nodeID: session.nodeID, workspaceID: session.workspaceID))
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
        updateDelegationApproval(
            sessionID: session.id, approvalID: approval.id, waiting: true)
        session.pendingApprovalID = approval.id
        session.inputSincePendingApproval = false
        session.journal.append(
            .approval(ApprovalEventPayload(approvalID: approval.id, acao: .criada)), author: .sistema)
        broadcast(.approvalCreated, ws: session.workspaceID, ApprovalTopicPayload(approval: approval))
        recordSemanticEvent(SemanticEvent(workspaceID: session.workspaceID, sessionID: session.id, nodeID: session.nodeID, kind: .approvalRequested, text: approval.resumo, metadata: ["approval_id": approval.id.string]))
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
        updateDelegationApproval(
            sessionID: session.id, approvalID: pendingID, waiting: false)
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
        updateDelegationApproval(
            sessionID: live.id, approvalID: approval.id, waiting: false)
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

    private func updateDelegationApproval(
        sessionID: ULID,
        approvalID: ULID,
        waiting: Bool
    ) {
        for workspaceID in Array(delegations.keys) {
            guard let match = delegations[workspaceID]?.values.first(where: {
                $0.subagentSessionID == sessionID && !$0.estado.isTerminal
            }) else { continue }
            var updated = match
            if waiting {
                updated.estado = .waitingApproval
                updated.pendingApprovalID = approvalID
            } else if updated.pendingApprovalID == approvalID {
                updated.estado = .running
                updated.pendingApprovalID = nil
            } else {
                continue
            }
            delegations[workspaceID]?[updated.id] = updated
            persistDelegations(workspaceID)
        }
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
        if message.sistema {
            // Aviso do engine: evento system no journal + linha no PTY com author
            // sistema. Sem message.delivered nem auto-conexão (não é conversa).
            dest.journal.append(
                .system(SystemEventPayload(name: message.systemName, message: message.texto)),
                author: .sistema)
            sessionInput(dest, data: Data((message.texto + "\r").utf8), author: .sistema, terminalInput: false)
            return
        }
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
        recordSemanticEvent(SemanticEvent(workspaceID: dest.workspaceID, sessionID: dest.id, nodeID: dest.nodeID, kind: .userMessage, text: message.texto, metadata: ["from_node_id": message.deNode.string, "message_id": message.id.string]))
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
        recordSemanticEvent(SemanticEvent(workspaceID: session.workspaceID, sessionID: session.id, nodeID: session.nodeID, kind: .assistantMessage, text: resposta, metadata: ["reply_to": wait.messageID.string]))
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
            notificarConexao(connection, removida: false, em: state)
        }
    }

    // MARK: - Consciência de conexão (extensão sobre §5.3/§14.2)

    /// Vizinhos por `Connection {conversa}` do nó — entra no LaunchConfig para o
    /// briefing do adapter refletir a topologia no momento do launch.
    private func vizinhosDeConversa(de nodeID: ULID, em state: WorkspaceState) -> [ConexaoVizinha] {
        state.connectionOrder.compactMap { connectionID -> ConexaoVizinha? in
            guard let connection = state.connections[connectionID],
                  connection.semantica == .conversa else { return nil }
            let outroID: ULID
            if connection.de == nodeID {
                outroID = connection.para
            } else if connection.para == nodeID {
                outroID = connection.de
            } else {
                return nil
            }
            guard case .terminal(let outro)? = state.nodes[outroID] else { return nil }
            return ConexaoVizinha(nome: outro.nome, adapter: outro.adapter, papel: outro.papel)
        }
    }

    /// Conexão `conversa` criada ou removida envolvendo terminal com sessão viva →
    /// linha informativa curta no PTY afetado (author sistema), entregue pela MESMA
    /// fila adiada da mensageria — nunca atropela um turno (§14.2). Conexão de nota
    /// fica apenas no briefing e no journal: não polui a conversa visível do usuário.
    /// `visual` é só decoração: sem aviso.
    private func notificarConexao(_ connection: Connection, removida: Bool, em state: WorkspaceState) {
        guard connection.semantica != .visual else { return }
        for (ponta, outroID) in [(connection.de, connection.para), (connection.para, connection.de)] {
            guard let sid = nodeSessions[ponta], let live = sessions[sid], live.estado.isViva else { continue }
            let texto: String
            switch connection.semantica {
            case .conversa:
                guard case .terminal(let outro)? = state.nodes[outroID] else { continue }
                if removida {
                    texto = "[colmeia] conexão com o nó \"\(outro.nome)\" desfeita."
                } else {
                    var detalhe = outro.adapter
                    if let papel = outro.papel, !papel.isEmpty { detalhe += ", papel \(papel)" }
                    texto = "[colmeia] conectado ao nó \"\(outro.nome)\" (\(detalhe)). "
                        + "Use o mecanismo de descoberta de comandos do terminal para delegar tarefas."
                }
            case .escritaDeNota:
                texto = removida
                    ? "[colmeia] nota desconectada do seu nó."
                    : "[colmeia] nota conectada ao seu nó — use a integração local para escrever nela."
                // A capacidade continua auditável sem virar uma mensagem digitada
                // dentro do terminal. O briefing de launch já descreve a CLI.
                live.journal.append(
                    .system(SystemEventPayload(name: "conexao", message: texto)), author: .sistema)
                continue
            case .visual:
                continue
            }
            notificarSistema(live, contraparte: outroID, texto: texto)
        }
    }

    /// Entrega imediata em `esperando_humano`/`ociosa`; senão entra na fila FIFO do
    /// destino (§14.2). Fila cheia → descarte silencioso: aviso é melhor-esforço e
    /// nunca pode falhar um `doc.apply`.
    private func notificarSistema(_ session: LiveSession, contraparte: ULID, texto: String) {
        let aviso = QueuedMessage(
            id: ULID.generate(), deNode: contraparte, texto: texto, enqueuedAt: Date(), sistema: true)
        if session.estado == .esperandoHumano || session.estado == .ociosa {
            deliver(aviso, to: session)
        } else if session.fila.count < Engine.filaMaxPorDestino {
            session.fila.append(aviso)
        }
    }

    // MARK: - Notas (§13.3)

    private func handleNoteAppend(_ params: NoteAppendParams, author: Author) throws -> NoteAppendResult {
        let state = try authorizeWorkspace(params.workspaceID, author: author)
        guard let origem = state.terminalNode(params.nodeIDOrigem) else {
            throw ProtocolError(name: .node_not_found, message: "terminal \(params.nodeIDOrigem) não existe")
        }
        var notaID: ULID?
        // Com várias notas conectadas, `colmeia note` usa a mais recentemente
        // conectada. As demais continuam acessíveis por note.get/set explícito.
        for connectionID in state.connectionOrder.reversed() {
            guard let connection = state.connections[connectionID],
                  connection.semantica == .escritaDeNota,
                  connection.de == origem.id
            else { continue }
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
        let texto = normalizarMarkdownRecebido(params.texto)
        var bloco = ""
        if let attrs = try? FileManager.default.attributesOfItem(atPath: noteURL.path),
           (attrs[.size] as? Int ?? 0) > 0 {
            bloco += "\n\n---\n"
        }
        bloco += "_\(nomeAmigavelDaFonte(author, in: state)) — \(ColmeiaJSON.string(from: Date()))_\n\n\(texto)\n"
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
        let resumo = String(texto.split(separator: "\n").first?.prefix(120) ?? "")
        if let sid = nodeSessions[origem.id], let live = sessions[sid] {
            live.journal.append(.note(NoteEventPayload(notaNodeID: notaID, resumo: resumo)), author: author)
        }
        let fullConteudo = (try? String(contentsOf: noteURL, encoding: .utf8)) ?? bloco
        broadcast(.noteAppended, ws: params.workspaceID, NoteAppendedTopicPayload(
            nodeID: notaID, fonte: author, resumo: resumo, conteudo: fullConteudo))
        return NoteAppendResult(notaNodeID: notaID)
    }

    /// Alguns agentes enviam Markdown serializado, com `\\n` literal. Decodificamos
    /// somente essa sequência para não reinterpretar escapes nem alterar barras que
    /// pertencem ao texto normal (URLs, caminhos, `\\t`, etc.).
    private func normalizarMarkdownRecebido(_ texto: String) -> String {
        texto.replacingOccurrences(of: "\\n", with: "\n")
    }

    /// A auditoria conserva `Author` nos eventos e nas operações do documento; a nota
    /// mostra a pessoa/agente pelo nome do nó, nunca pelo identificador técnico ULID.
    private func nomeAmigavelDaFonte(_ author: Author, in state: WorkspaceState) -> String {
        switch author {
        case .humano(let id):
            return id == "local" ? "você" : id
        case .agente(let rawID):
            guard let nodeID = ULID(rawID), case .terminal(let node)? = state.nodes[nodeID] else {
                return "agente"
            }
            return node.nome
        case .sistema:
            return "sistema"
        }
    }

    // MARK: - Capacidades de agentes: node.list / note.*

    private static let maxNoteBytes = 1_048_576

    private func validateNoteContent(_ content: String) throws {
        guard !content.contains("\0"), content.lengthOfBytes(using: .utf8) <= Engine.maxNoteBytes else {
            throw ProtocolError(name: .invalid_params, message: "conteúdo da nota inválido ou maior que 1 MiB")
        }
    }

    private func requireNote(_ nodeID: ULID, in state: WorkspaceState) throws -> NotaNode {
        guard let node = state.nodes[nodeID] else {
            throw ProtocolError(name: .node_not_found, message: "nó \(nodeID) não existe")
        }
        guard case .nota(let note) = node else {
            throw ProtocolError(name: .invalid_params, message: "nó \(nodeID) não é uma nota")
        }
        return note
    }

    private func noteContent(workspaceID: ULID, nodeID: ULID) throws -> String {
        let url = paths.noteFile(workspace: workspaceID, node: nodeID)
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ProtocolError(name: .internal_error, message: "não foi possível ler a nota")
        }
    }

    private func saveNoteContent(_ content: String, workspaceID: ULID, nodeID: ULID) throws {
        let url = paths.noteFile(workspace: workspaceID, node: nodeID)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url, options: .atomic)
        } catch {
            throw ProtocolError(name: .internal_error, message: "não foi possível salvar a nota")
        }
    }

    private func noteRecord(_ note: NotaNode, content: String, workspaceID: ULID) -> NoteRecord {
        NoteRecord(
            nodeID: note.id, conteudo: content, cor: note.cor, ultimaFonte: note.ultimaFonte,
            floorID: floorID(for: note.id, in: workspaceID), checklist: NoteChecklist.items(in: content))
    }

    private func updateNoteSource(
        _ nodeID: ULID, workspaceID: ULID, author: Author, state: WorkspaceState, summary: String
    ) throws {
        let op = DocOp(
            opID: ULID.generate(), author: author, ts: Date(),
            payload: .nodeUpdate(NodeUpdateOpPayload(
                id: nodeID, campos: .object(["ultima_fonte": .string(author.rawValue)]))))
        let applied = try state.applyProposal(op, liveNodeIDs: liveNodeIDs)
        broadcast(.documentOp, ws: workspaceID, DocumentOpTopicPayload(
            workspaceID: workspaceID, op: applied, seq: applied.seq ?? 0))
        broadcast(.noteAppended, ws: workspaceID, NoteAppendedTopicPayload(
            nodeID: nodeID, fonte: author, resumo: summary))
        try state.saveWorkspace()
    }

    private func handleNodeList(_ params: NodeListParams, author: Author) throws -> NodeListResult {
        let state = try authorizeWorkspace(params.workspaceID, author: author)
        if let floorID = params.floorID { _ = try activeFloor(floorID, in: params.workspaceID) }
        return state.nodeOrder.compactMap { nodeID in
            guard let node = state.nodes[nodeID], params.tipo == nil || node.tipo == params.tipo else { return nil }
            let nodeFloorID = floorID(for: nodeID, in: params.workspaceID)
            guard params.floorID == nil || params.floorID == nodeFloorID else { return nil }
            let title: String
            var papel: String?
            var adapter: String?
            var estadoSessao: String?
            switch node {
            case .terminal(let terminal):
                title = terminal.nome
                papel = terminal.papel
                adapter = terminal.adapter
                if let sid = terminal.sessionID {
                    if let live = sessions[sid] {
                        estadoSessao = live.estado.rawValue
                    } else if let meta = sessionMetas[sid] {
                        estadoSessao = meta.estado.rawValue
                    } else {
                        estadoSessao = "vinculada"
                    }
                }
            case .nota: title = "Nota"
            case .desenho: title = "Desenho"
            case .portal(let portal): title = portal.titulo ?? portal.url
            }
            return NodeSummary(id: nodeID, tipo: node.tipo, titulo: title, floorID: nodeFloorID, papel: papel, estadoSessao: estadoSessao, adapter: adapter)
        }
    }

    private func handleNoteCreate(_ params: NoteCreateParams, author: Author) throws -> NoteRecord {
        let state = try authorizeWorkspace(params.workspaceID, author: author)
        try validateNoteContent(params.conteudo)
        if let floorID = params.floorID { _ = try activeFloor(floorID, in: params.workspaceID) }
        let nodeID = ULID.generate()
        let offset = Double(state.nodes.count % 12) * 32
        let note = NotaNode(
            id: nodeID, posicao: Ponto(x: 160 + offset, y: 160 + offset),
            tamanho: Tamanho(w: 360, h: 260), z: (state.nodes.values.map(\.z).max() ?? 0) + 1,
            criadoEm: Date(), arquivo: "notes/\(nodeID.string).md",
            cor: params.cor?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? params.cor! : "amarela",
            ultimaFonte: author)
        let content = NoteChecklist.normalize(normalizarMarkdownRecebido(params.conteudo))
        try saveNoteContent(content, workspaceID: params.workspaceID, nodeID: nodeID)
        let op = DocOp(opID: ULID.generate(), author: author, ts: Date(),
                       payload: .nodeAdd(NodeAddOpPayload(node: .nota(note))))
        let applied = try state.applyProposal(op, liveNodeIDs: liveNodeIDs)
        broadcast(.documentOp, ws: params.workspaceID, DocumentOpTopicPayload(
            workspaceID: params.workspaceID, op: applied, seq: applied.seq ?? 0))
        try assignNode(nodeID, toFloor: params.floorID, workspaceID: params.workspaceID)
        broadcast(.noteAppended, ws: params.workspaceID, NoteAppendedTopicPayload(
            nodeID: nodeID, fonte: author, resumo: "nota criada", conteudo: content))
        try state.saveWorkspace()
        return noteRecord(note, content: content, workspaceID: params.workspaceID)
    }

    private func handleNoteGet(_ params: NoteGetParams, author: Author) throws -> NoteRecord {
        let state = try authorizeWorkspace(params.workspaceID, author: author)
        let note = try requireNote(params.nodeID, in: state)
        return noteRecord(note, content: try noteContent(workspaceID: params.workspaceID, nodeID: note.id), workspaceID: params.workspaceID)
    }

    private func handleNoteConnected(
        _ params: NoteConnectedParams, author: Author
    ) throws -> NoteConnectedResult {
        let state = try authorizeWorkspace(params.workspaceID, author: author)
        guard state.terminalNode(params.nodeID) != nil else {
            throw ProtocolError(name: .node_not_found, message: "terminal \(params.nodeID) não existe")
        }
        if case .agente(let rawNodeID) = author, rawNodeID != params.nodeID.string {
            throw ProtocolError(name: .invalid_params, message: "agente só pode consultar as próprias conexões")
        }
        var seen = Set<ULID>()
        return try state.connectionOrder.reversed().compactMap { connectionID in
            guard let connection = state.connections[connectionID],
                  connection.semantica == .escritaDeNota,
                  connection.de == params.nodeID,
                  seen.insert(connection.para).inserted,
                  case .nota(let note)? = state.nodes[connection.para]
            else { return nil }
            return noteRecord(
                note,
                content: try noteContent(workspaceID: params.workspaceID, nodeID: note.id),
                workspaceID: params.workspaceID)
        }
    }

    private func handleNoteChain(
        _ params: NoteConnectedParams, author: Author
    ) throws -> NoteChainResult {
        let state = try authorizeWorkspace(params.workspaceID, author: author)
        guard state.terminalNode(params.nodeID) != nil else {
            throw ProtocolError(name: .node_not_found, message: "terminal \(params.nodeID) não existe")
        }
        if case .agente(let rawNodeID) = author, rawNodeID != params.nodeID.string {
            throw ProtocolError(name: .invalid_params, message: "agente só pode consultar as próprias conexões")
        }
        let maxDepth = params.maxProfundidade ?? 10
        var visited = Set<ULID>()
        var result: [NoteConnectedEntry] = []
        var queue: [(ULID, Int)] = [(params.nodeID, 0)]
        var head = 0
        while head < queue.count {
            let (currentID, depth) = queue[head]
            head += 1
            guard depth < maxDepth else { continue }
            for connectionID in state.connectionOrder.reversed() {
                guard let conn = state.connections[connectionID],
                      conn.semantica == .escritaDeNota else { continue }
                let nextID: ULID
                if conn.de == currentID { nextID = conn.para }
                else if conn.para == currentID { nextID = conn.de }
                else { continue }
                guard case .nota(let note)? = state.nodes[nextID] else { continue }
                let isCycle = !visited.insert(nextID).inserted
                let entry = NoteConnectedEntry(
                    note: noteRecord(note,
                        content: try noteContent(workspaceID: params.workspaceID, nodeID: note.id),
                        workspaceID: params.workspaceID),
                    profundidade: depth + 1,
                    ciclo: isCycle)
                result.append(entry)
                if !isCycle {
                    queue.append((nextID, depth + 1))
                }
            }
        }
        return result
    }

    private func handleNoteReplace(_ params: NoteReplaceParams, author: Author) throws -> NoteRecord {
        let state = try authorizeWorkspace(params.workspaceID, author: author)
        let note = try requireNote(params.nodeID, in: state)
        try validateNoteContent(params.conteudo)
        let content = NoteChecklist.normalize(normalizarMarkdownRecebido(params.conteudo))
        try saveNoteContent(content, workspaceID: params.workspaceID, nodeID: note.id)
        let summary = String(content.split(separator: "\n").first?.prefix(120) ?? "nota atualizada")
        try updateNoteSource(note.id, workspaceID: params.workspaceID, author: author, state: state, summary: summary)
        guard case .nota(let updated) = state.nodes[note.id] else { return noteRecord(note, content: content, workspaceID: params.workspaceID) }
        return noteRecord(updated, content: content, workspaceID: params.workspaceID)
    }

    private func handleNoteChecklistAdd(_ params: NoteChecklistAddParams, author: Author) throws -> NoteRecord {
        let state = try authorizeWorkspace(params.workspaceID, author: author)
        let note = try requireNote(params.nodeID, in: state)
        let text = params.texto.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("\n"), !text.contains("\r"), text.lengthOfBytes(using: .utf8) <= 16_384 else {
            throw ProtocolError(name: .invalid_params, message: "texto do item de checklist inválido")
        }
        let content = NoteChecklist.appending(text, to: try noteContent(workspaceID: params.workspaceID, nodeID: note.id), id: ULID.generate())
        try validateNoteContent(content)
        try saveNoteContent(content, workspaceID: params.workspaceID, nodeID: note.id)
        try updateNoteSource(note.id, workspaceID: params.workspaceID, author: author, state: state, summary: text)
        guard case .nota(let updated) = state.nodes[note.id] else { return noteRecord(note, content: content, workspaceID: params.workspaceID) }
        return noteRecord(updated, content: content, workspaceID: params.workspaceID)
    }

    private func handleNoteChecklistSet(_ params: NoteChecklistSetParams, author: Author) throws -> NoteChecklistSetResult {
        let state = try authorizeWorkspace(params.workspaceID, author: author)
        let note = try requireNote(params.nodeID, in: state)
        let oldContent = try noteContent(workspaceID: params.workspaceID, nodeID: note.id)
        guard let result = NoteChecklist.setting(params.itemID, marked: params.marcada, in: oldContent) else {
            throw ProtocolError(name: .invalid_params, message: "item de checklist não existe nesta nota")
        }
        if result.changed {
            try saveNoteContent(result.content, workspaceID: params.workspaceID, nodeID: note.id)
            try updateNoteSource(note.id, workspaceID: params.workspaceID, author: author, state: state, summary: "checklist atualizada")
        }
        let currentNote: NotaNode
        if case .nota(let updated) = state.nodes[note.id] { currentNote = updated } else { currentNote = note }
        return NoteChecklistSetResult(
            note: noteRecord(currentNote, content: result.content, workspaceID: params.workspaceID), changed: result.changed)
    }

    // MARK: - note.asset.* (Paste image)

    private func assetsDir(for nodeID: ULID, workspaceID: ULID) -> String {
        let state = workspaces[workspaceID]
        let base = state?.workspace.caminhoRaiz ?? paths.workspacesDir.appendingPathComponent(workspaceID.string).path
        return (base as NSString).appendingPathComponent("notes/\(nodeID.string)/assets")
    }

    private func assetPath(assetID: ULID, mime: String, nodeID: ULID, workspaceID: ULID) -> String {
        let ext: String
        if mime == "image/png" { ext = "png" }
        else if mime == "image/jpeg" || mime == "image/jpg" { ext = "jpg" }
        else if mime == "image/gif" { ext = "gif" }
        else if mime == "image/webp" { ext = "webp" }
        else if mime == "image/svg+xml" { ext = "svg" }
        else if mime == "text/plain" { ext = "txt" }
        else { ext = "bin" }
        return (assetsDir(for: nodeID, workspaceID: workspaceID) as NSString).appendingPathComponent("\(assetID.string).\(ext)")
    }

    private func loadAssetManifest(nodeID: ULID, workspaceID: ULID) -> [AssetRef] {
        let dir = assetsDir(for: nodeID, workspaceID: workspaceID)
        let path = (dir as NSString).appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let items = try? ColmeiaJSON.decoder().decode([AssetRef].self, from: data) else {
            return []
        }
        return items
    }

    private func saveAssetManifest(_ items: [AssetRef], nodeID: ULID, workspaceID: ULID) {
        let dir = assetsDir(for: nodeID, workspaceID: workspaceID)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent("manifest.json")
        if let data = try? ColmeiaJSON.encoder().encode(items) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    private func handleNoteAssetAdd(_ params: NoteAssetAddParams, author: Author) throws -> NoteAssetAddResult {
        let state = try authorizeWorkspace(params.workspaceID, author: author)
        guard let note = state.nodes[params.nodeID], case .nota = note else {
            throw ProtocolError(name: .node_not_found, message: "nota \(params.nodeID) não existe")
        }
        guard let data = Data(base64Encoded: params.dataB64) else {
            throw ProtocolError(name: .invalid_params, message: "data_b64 inválido")
        }
        guard data.count <= 10 * 1024 * 1024 else {
            throw ProtocolError(name: .invalid_params, message: "asset muito grande (máx 10 MiB)")
        }
        let assetID = ULID.generate()
        let asset = AssetRef(id: assetID, mime: params.mime, tamanho: data.count, alt: params.alt, criadoEm: Date(), filename: params.filename)
        let path = assetPath(assetID: assetID, mime: params.mime, nodeID: params.nodeID, workspaceID: params.workspaceID)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path))
        var manifest = loadAssetManifest(nodeID: params.nodeID, workspaceID: params.workspaceID)
        manifest.append(asset)
        saveAssetManifest(manifest, nodeID: params.nodeID, workspaceID: params.workspaceID)
        let markdown = "![\(params.alt ?? assetID.string)](colmeia-asset://\(assetID.string))"
        return NoteAssetAddResult(asset: asset, markdown: markdown)
    }

    private func handleNoteAssetList(_ params: NoteAssetListParams, author: Author) throws -> NoteAssetListResult {
        _ = try authorizeWorkspace(params.workspaceID, author: author)
        return loadAssetManifest(nodeID: params.nodeID, workspaceID: params.workspaceID)
    }

    private func handleNoteAssetRm(_ params: NoteAssetRmParams, author: Author) throws -> EmptyResult {
        _ = try authorizeWorkspace(params.workspaceID, author: author)
        var manifest = loadAssetManifest(nodeID: params.nodeID, workspaceID: params.workspaceID)
        guard let idx = manifest.firstIndex(where: { $0.id == params.assetID }) else {
            throw ProtocolError(name: .invalid_params, message: "asset \(params.assetID) não existe")
        }
        let asset = manifest.remove(at: idx)
        let path = assetPath(assetID: asset.id, mime: asset.mime, nodeID: params.nodeID, workspaceID: params.workspaceID)
        try? FileManager.default.removeItem(atPath: path)
        saveAssetManifest(manifest, nodeID: params.nodeID, workspaceID: params.workspaceID)
        return EmptyResult()
    }

    private func handleNoteAssetGet(_ params: NoteAssetGetParams, author: Author) throws -> NoteAssetGetResult {
        _ = try authorizeWorkspace(params.workspaceID, author: author)
        let manifest = loadAssetManifest(nodeID: params.nodeID, workspaceID: params.workspaceID)
        guard let asset = manifest.first(where: { $0.id == params.assetID }) else {
            throw ProtocolError(name: .invalid_params, message: "asset \(params.assetID) não existe")
        }
        let path = assetPath(assetID: asset.id, mime: asset.mime, nodeID: params.nodeID, workspaceID: params.workspaceID)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            throw ProtocolError(name: .internal_error, message: "asset \(params.assetID) corrompido no disco")
        }
        return NoteAssetGetResult(asset: asset, dataB64: data.base64EncodedString())
    }

    // MARK: - Modo Rainha (node.dismiss / node.connect / node.disconnect)

    private func requireRainha(author: Author, em workspaceID: ULID) throws -> WorkspaceState {
        let state = try authorizeWorkspace(workspaceID, author: author)
        guard case .agente(let nodeID) = author else {
            throw ProtocolError(name: .insufficient_permissions, message: "apenas agentes podem usar comandos da Rainha")
        }
        guard let nid = ULID(nodeID) else {
            throw ProtocolError(name: .insufficient_permissions, message: "author nodeID inválido")
        }
        guard let terminal = state.terminalNode(nid) else {
            throw ProtocolError(name: .insufficient_permissions, message: "só nós terminais podem ser Rainha")
        }
        guard terminal.papel == "rainha" else {
            throw ProtocolError(name: .insufficient_permissions, message: "papel \"\(terminal.papel ?? "regular")\" não tem permissão de Rainha — necessário papel=rainha")
        }
        return state
    }

    private func handleNodeDismiss(_ params: NodeDismissParams, author: Author) throws -> EmptyResult {
        let state = try requireRainha(author: author, em: params.workspaceID)
        guard let target = state.terminalNode(params.nodeID) else {
            throw ProtocolError(name: .node_not_found, message: "nó \(params.nodeID) não existe ou não é terminal")
        }
        if let sid = target.sessionID {
            if let live = sessions[sid] {
                let pty = live.pty
                live.estado = .morta
                live.encerradaEm = Date()
                sessionMetas[target.sessionID!] = live.dto()
                sessions.removeValue(forKey: sid)
                if let pty, PTY.isAlive(pid: pty.pid) {
                    PTY.signal(pid: pty.pid, SIGTERM)
                }
            }
        }
        let op = DocOp(opID: ULID.generate(), author: author, ts: Date(),
                       payload: .nodeDelete(NodeDeleteOpPayload(id: params.nodeID)))
        let applied = try state.applyProposal(op, liveNodeIDs: liveNodeIDs)
        broadcast(.documentOp, ws: params.workspaceID, DocumentOpTopicPayload(
            workspaceID: params.workspaceID, op: applied, seq: applied.seq ?? 0))
        try state.saveWorkspace()
        return EmptyResult()
    }

    private func handleNodeConnect(_ params: NodeConnectParams, author: Author) throws -> EmptyResult {
        let state = try requireRainha(author: author, em: params.workspaceID)
        guard state.nodes[params.de] != nil else {
            throw ProtocolError(name: .node_not_found, message: "nó origem \(params.de) não existe")
        }
        guard state.nodes[params.para] != nil else {
            throw ProtocolError(name: .node_not_found, message: "nó destino \(params.para) não existe")
        }
        let connection = Connection(
            id: ULID.generate(), de: params.de, para: params.para,
            semantica: .escritaDeNota, estilo: .solida)
        let op = DocOp(opID: ULID.generate(), author: author, ts: Date(),
                       payload: .connectionAdd(ConnectionAddOpPayload(connection: connection)))
        let applied = try state.applyProposal(op, liveNodeIDs: liveNodeIDs)
        broadcast(.documentOp, ws: params.workspaceID, DocumentOpTopicPayload(
            workspaceID: params.workspaceID, op: applied, seq: applied.seq ?? 0))
        try state.saveWorkspace()
        return EmptyResult()
    }

    private func handleNodeDisconnect(_ params: NodeDisconnectParams, author: Author) throws -> EmptyResult {
        let state = try requireRainha(author: author, em: params.workspaceID)
        guard let connID = state.connectionOrder.first(where: { connID in
            guard let conn = state.connections[connID] else { return false }
            return conn.de == params.de && conn.para == params.para
        }) else {
            throw ProtocolError(name: .invalid_params, message: "conexão entre \(params.de) e \(params.para) não existe")
        }
        let op = DocOp(opID: ULID.generate(), author: author, ts: Date(),
                       payload: .connectionDelete(ConnectionDeleteOpPayload(id: connID)))
        let applied = try state.applyProposal(op, liveNodeIDs: liveNodeIDs)
        broadcast(.documentOp, ws: params.workspaceID, DocumentOpTopicPayload(
            workspaceID: params.workspaceID, op: applied, seq: applied.seq ?? 0))
        try state.saveWorkspace()
        return EmptyResult()
    }

    // MARK: - Portais ([v1.5] antecipado)

    /// `portal.open`: valida a URL (http/https com host; senão `invalid_params`) e cria
    /// o PortalNode pelo MESMO caminho de `doc.apply` (§7.1) — clientes veem o `node.add`
    /// pelo eco `document.op` normalmente. Posição: definida-pela-implementação —
    /// cascata simples a partir de (120,120) com passo de 40 px por nó existente.
    private func handlePortalOpen(_ params: PortalOpenParams, author: Author) throws -> PortalOpenResult {
        let state = try authorizeWorkspace(params.workspaceID, author: author)
        guard let componentes = URLComponents(string: params.url),
              let scheme = componentes.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = componentes.host, !host.isEmpty
        else {
            throw ProtocolError(
                name: .invalid_params,
                message: "portal.open exige URL http/https absoluta; recebeu \"\(params.url)\"")
        }
        if let floorID = params.floorID { _ = try activeFloor(floorID, in: params.workspaceID) }
        let passo = Double(state.nodes.count % 12) * 40
        let node = PortalNode(
            id: ULID.generate(),
            posicao: Ponto(x: 120 + passo, y: 120 + passo),
            tamanho: Tamanho(w: 720, h: 520),
            z: (state.nodes.values.map(\.z).max() ?? 0) + 1,
            criadoEm: Date(),
            url: params.url,
            titulo: params.nome)
        let op = DocOp(
            opID: ULID.generate(), author: author, ts: Date(),
            payload: .nodeAdd(NodeAddOpPayload(node: .portal(node))))
        let applied = try state.applyProposal(op, liveNodeIDs: liveNodeIDs)
        broadcast(.documentOp, ws: params.workspaceID, DocumentOpTopicPayload(
            workspaceID: params.workspaceID, op: applied, seq: applied.seq ?? 0))
        // Portal aberto DE DENTRO de um terminal gerenciado pertence àquele
        // agente: ele nasce conectado no canvas, em vez de virar uma página
        // solta que a pessoa precisa ligar manualmente depois.
        if case .agente(let rawNodeID) = author,
           let sourceID = ULID(rawNodeID),
           state.terminalNode(sourceID) != nil,
           !state.connections.values.contains(where: { $0.de == sourceID && $0.para == node.id })
        {
            let connection = Connection(
                id: ULID.generate(), de: sourceID, para: node.id,
                semantica: .visual, estilo: .tracejada)
            let connectionOp = DocOp(
                opID: ULID.generate(), author: author, ts: Date(),
                payload: .connectionAdd(ConnectionAddOpPayload(connection: connection)))
            let appliedConnection = try state.applyProposal(connectionOp, liveNodeIDs: liveNodeIDs)
            broadcast(.documentOp, ws: params.workspaceID, DocumentOpTopicPayload(
                workspaceID: params.workspaceID, op: appliedConnection, seq: appliedConnection.seq ?? 0))
        }
        try assignNode(node.id, toFloor: params.floorID, workspaceID: params.workspaceID)
        try state.saveWorkspace()
        log.info("portal_open", params.url, workspaceID: params.workspaceID)
        return PortalOpenResult(nodeID: node.id)
    }

    // MARK: - portal.command (Automação do portal)

    final class PortalBrowserSession: @unchecked Sendable {
        let nodeID: ULID
        var currentURL: String
        var process: Process?
        let debugPort: Int
        let userDataDir: String
        init(nodeID: ULID, currentURL: String, debugPort: Int, userDataDir: String) {
            self.nodeID = nodeID
            self.currentURL = currentURL
            self.debugPort = debugPort
            self.userDataDir = userDataDir
        }
    }

    private func handlePortalCommand(_ params: PortalCommandParams, author: Author) throws -> PortalCommandResult {
        let state = try authorizeWorkspace(params.workspaceID, author: author)
        guard let node = state.nodes[params.nodeID], case .portal(let portal) = node else {
            throw ProtocolError(name: .node_not_found, message: "portal \(params.nodeID) não existe")
        }

        if portalBrowsers[params.nodeID] == nil {
            let port = try allocatePortalDebugPort()
            let dir = paths.workspaceDir(params.workspaceID).appendingPathComponent("chrome-\(params.nodeID)").path
            portalBrowsers[params.nodeID] = PortalBrowserSession(
                nodeID: params.nodeID, currentURL: portal.url, debugPort: port, userDataDir: dir)
        }

        guard let browser = portalBrowsers[params.nodeID] else {
            throw ProtocolError(name: .internal_error, message: "falha ao criar sessão de browser")
        }

        switch params.acao {
        case .navigate:
            guard let url = params.url, !url.isEmpty else {
                throw ProtocolError(name: .invalid_params, message: "portal.command navigate exige url")
            }
            guard let componentes = URLComponents(string: url),
                  let scheme = componentes.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  let host = componentes.host, !host.isEmpty
            else {
                throw ProtocolError(name: .invalid_params, message: "navigate exige URL http/https absoluta")
            }
            return try launchChrome(url: url, browser: browser, nodeID: params.nodeID)

        case .shot:
            let selector = params.selector
            return try chromeShot(browser: browser, selector: selector, nodeID: params.nodeID)

        case .snapshot:
            return try chromeSnapshot(browser: browser, nodeID: params.nodeID)

        case .click:
            guard let selector = params.selector, !selector.isEmpty else {
                throw ProtocolError(name: .invalid_params, message: "portal.command click exige selector")
            }
            return try chromeEval(browser: browser, code: "document.querySelector('\(selector.replacingOccurrences(of: "'", with: "\\'"))').click()", nodeID: params.nodeID)

        case .fill:
            guard let selector = params.selector, !selector.isEmpty,
                  let value = params.value else {
                throw ProtocolError(name: .invalid_params, message: "portal.command fill exige selector e value")
            }
            let escapedSelector = selector.replacingOccurrences(of: "'", with: "\\'")
            let escapedValue = value.replacingOccurrences(of: "'", with: "\\'")
            let js = """
            (function(){
              const el = document.querySelector('\(escapedSelector)');
              if(!el) throw new Error('seletor não encontrado: \(escapedSelector)');
              const tag = el.tagName.toLowerCase();
              if(tag==='select'){ el.value='\(escapedValue)'; el.dispatchEvent(new Event('change')); }
              else { el.value='\(escapedValue)'; el.dispatchEvent(new Event('input')); }
              return 'ok';
            })()
            """
            return try chromeEval(browser: browser, code: js, nodeID: params.nodeID)

        case .key:
            guard let keys = params.keys, !keys.isEmpty else {
                throw ProtocolError(name: .invalid_params, message: "portal.command key exige keys")
            }
            let keyMapping: [String: String] = [
                "enter": "Enter", "tab": "Tab", "escape": "Escape", "esc": "Escape",
                "backspace": "Backspace", "delete": "Delete", "arrowup": "ArrowUp",
                "arrowdown": "ArrowDown", "arrowleft": "ArrowLeft", "arrowright": "ArrowRight",
                "space": " ", " ": " "
            ]
            let k = keyMapping[keys.lowercased()] ?? keys
            let escapedKey = k.replacingOccurrences(of: "'", with: "\\'")
            let js = """
            document.activeElement.dispatchEvent(new KeyboardEvent('keydown', {key:'\(escapedKey)'}));
            document.activeElement.dispatchEvent(new KeyboardEvent('keyup', {key:'\(escapedKey)'}));
            """
            return try chromeEval(browser: browser, code: js, nodeID: params.nodeID)

        case .eval:
            guard let code = params.code, !code.isEmpty else {
                throw ProtocolError(name: .invalid_params, message: "portal.command eval exige code")
            }
            return try chromeEval(browser: browser, code: code, nodeID: params.nodeID)
        }
    }

    private func browserCDNSession(_ browser: PortalBrowserSession) -> URL {
        URL(string: "http://127.0.0.1:\(browser.debugPort)")!
    }

    private func allocatePortalDebugPort() throws -> Int {
        #if canImport(Darwin)
        let type = SOCK_STREAM
        #else
        let type = Int32(SOCK_STREAM.rawValue)
        #endif
        let fd = socket(AF_INET, type, 0)
        guard fd >= 0 else {
            throw ProtocolError(name: .internal_error, message: "não abriu socket para portal")
        }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            throw ProtocolError(name: .internal_error, message: "não reservou porta para portal")
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard getsockname(fd, withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 }
        }, &length) == 0 else {
            throw ProtocolError(name: .internal_error, message: "não leu porta do portal")
        }
        return Int(CFSwapInt16BigToHost(address.sin_port))
    }

    private func ensureChrome(browser: PortalBrowserSession, nodeID: ULID) throws {
        if browser.process?.isRunning == true { return }
        let chromePaths = [
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "/usr/bin/chromium", "/usr/bin/chromium-browser",
            "/usr/bin/google-chrome", "/usr/bin/google-chrome-stable"
        ]
        guard let chrome = chromePaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw ProtocolError(name: .internal_error, message: "navegador headless não encontrado (instale Chrome ou Chromium)")
        }
        try FileManager.default.createDirectory(atPath: browser.userDataDir, withIntermediateDirectories: true)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: chrome)
        proc.arguments = [
            "--headless", "--disable-gpu", "--no-first-run",
            "--remote-debugging-port=\(browser.debugPort)",
            "--remote-allow-origins=*",
            "--user-data-dir=\(browser.userDataDir)",
            "--no-sandbox", "--disable-dev-shm-usage"
        ]
        try proc.run()
        portalBrowsers[nodeID]?.process = proc
        Thread.sleep(forTimeInterval: 1.5)
    }

    private func launchChrome(url: String, browser: PortalBrowserSession, nodeID: ULID) throws -> PortalCommandResult {
        try ensureChrome(browser: browser, nodeID: nodeID)
        portalBrowsers[nodeID]?.currentURL = url
        let escaped = url.replacingOccurrences(of: "'", with: "\\'")
        _ = try chromeEval(browser: browser, code: "window.location.href='\(escaped)'", nodeID: nodeID)
        return PortalCommandResult(resultado: "navegando para \(url)")
    }

    private func chromeShot(browser: PortalBrowserSession, selector: String?, nodeID: ULID) throws -> PortalCommandResult {
        try ensureChrome(browser: browser, nodeID: nodeID)
        let cdpURL = browserCDNSession(browser)
        guard let wsURL = try fetchCDPTarget(cdpURL: cdpURL) else {
            throw ProtocolError(name: .internal_error, message: "chrome CDP não disponível")
        }
        let screenshotDir = paths.workspacesDir.appendingPathComponent("portal-screenshots")
        try FileManager.default.createDirectory(atPath: screenshotDir.path, withIntermediateDirectories: true)
        let filename = "shot-\(nodeID)-\(ULID.generate()).png"
        let filePath = screenshotDir.appendingPathComponent(filename).path

        let js: String
        if let sel = selector {
            let esel = sel.replacingOccurrences(of: "'", with: "\\'")
            js = """
            (async () => {
              const el = document.querySelector('\(esel)');
              if(!el) throw new Error('seletor não encontrado');
              const rect = el.getBoundingClientRect();
              return JSON.stringify({x:rect.x, y:rect.y, w:rect.width, h:rect.height});
            })()
            """
            let rectJSON = try chromeEvalInner(browser: browser, code: js)
            guard let data = rectJSON.data(using: .utf8),
                  let rect = try? JSONDecoder().decode(RectPayload.self, from: data) else {
                return PortalCommandResult(resultado: "erro ao obter bounding rect")
            }
            return try takeScreenshotViaCDP(cdpURL: cdpURL, wsURL: wsURL, filePath: filePath, clip: rect)
        }
        return try takeScreenshotViaCDP(cdpURL: cdpURL, wsURL: wsURL, filePath: filePath, clip: nil)
    }

    private func chromeSnapshot(browser: PortalBrowserSession, nodeID: ULID) throws -> PortalCommandResult {
        try ensureChrome(browser: browser, nodeID: nodeID)
        let cdpURL = browserCDNSession(browser)
        guard let wsURL = try fetchCDPTarget(cdpURL: cdpURL) else {
            throw ProtocolError(name: .internal_error, message: "chrome CDP não disponível")
        }
        let pdfDir = paths.workspacesDir.appendingPathComponent("portal-pdfs")
        try FileManager.default.createDirectory(atPath: pdfDir.path, withIntermediateDirectories: true)
        let filename = "pdf-\(nodeID)-\(ULID.generate()).pdf"
        let filePath = pdfDir.appendingPathComponent(filename).path
        return try printToPDFViaCDP(cdpURL: cdpURL, wsURL: wsURL, filePath: filePath)
    }

    // MARK: - Chrome DevTools Protocol helpers

    private struct RectPayload: Codable { var x: Double; var y: Double; var w: Double; var h: Double }

    private func fetchCDPTarget(cdpURL: URL) throws -> String? {
        // Runtime/Page commands must target a page websocket, not the browser
        // websocket returned by /json/version.
        let jsonURL = cdpURL.appendingPathComponent("json")
        guard let data = try? Data(contentsOf: jsonURL),
              let pages = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let page = pages.first(where: { $0["type"] as? String == "page" }),
              let wsURL = page["webSocketDebuggerUrl"] as? String else {
            return nil
        }
        return wsURL
    }

    private func chromeEval(browser: PortalBrowserSession, code: String, nodeID: ULID) throws -> PortalCommandResult {
        let result = try chromeEvalInner(browser: browser, code: code)
        return PortalCommandResult(resultado: result)
    }

    private func chromeEvalInner(browser: PortalBrowserSession, code: String) throws -> String {
        try ensureChrome(browser: browser, nodeID: browser.nodeID)
        let cdpURL = browserCDNSession(browser)
        guard let wsURL = try fetchCDPTarget(cdpURL: cdpURL) else {
            throw ProtocolError(name: .internal_error, message: "chrome CDP não disponível")
        }
        return try sendCDPCommand(wsURL: wsURL, method: "Runtime.evaluate", params: [
            "expression": code,
            "returnByValue": true,
            "awaitPromise": true
        ])
    }

    private func sendCDPCommand(wsURL: String, method: String, params: [String: Any]) throws -> String {
        guard let url = URL(string: wsURL) else {
            throw ProtocolError(name: .internal_error, message: "wsURL inválida")
        }
        let wire = try CDPWire(url: url)
        defer { wire.shutdown() }
        let requestID = Int.random(in: 1...99999)
        let command: [String: Any] = ["id": requestID, "method": method, "params": params]
        try wire.sendText(JSONSerialization.data(withJSONObject: command))
        let receivedResult = try wire.receiveText()
        // Extract result value from CDP response
        if let data = receivedResult.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let resultDict = json["result"] as? [String: Any],
           let value = resultDict["result"] as? [String: Any],
           let resultValueStr = value["value"] {
            return "\(resultValueStr)"
        }
        if let data = receivedResult.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let resultDict = json["result"] as? [String: Any],
           let exception = resultDict["exceptionDetails"] as? [String: Any],
           let text = exception["text"] as? String {
            throw ProtocolError(name: .internal_error, message: "JS eval error: \(text)")
        }
        return receivedResult
    }

    /// Cliente WebSocket mínimo para o DevTools Protocol local. URLSessionWebSocketTask
    /// depende de um run loop que não existe enquanto o engine atende a fila serial.
    private final class CDPWire {
        private var fd: Int32
        private var buffer = Data()

        init(url: URL) throws {
            guard let host = url.host, host == "127.0.0.1",
                  let port = url.port else {
                throw ProtocolError(name: .internal_error, message: "endpoint CDP deve ser local")
            }
            #if canImport(Darwin)
            let type = SOCK_STREAM
            #else
            let type = Int32(SOCK_STREAM.rawValue)
            #endif
            fd = socket(AF_INET, type, 0)
            guard fd >= 0 else {
                throw ProtocolError(name: .internal_error, message: "não abriu socket CDP: \(String(cString: strerror(errno)))")
            }
            var timeout = timeval(tv_sec: 15, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            #if canImport(Darwin)
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            #endif
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = CFSwapInt16HostToBig(UInt16(port))
            address.sin_addr = in_addr(s_addr: inet_addr(host))
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connected == 0 else {
                let code = errno
                close(fd)
                throw ProtocolError(name: .internal_error, message: "não conectou ao CDP: \(String(cString: strerror(code)))")
            }

            let key = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
            let requestPath = url.path + (url.query.map { "?\($0)" } ?? "")
            let handshake = "GET \(requestPath) HTTP/1.1\r\n" +
                "Host: \(host):\(port)\r\n" +
                "Upgrade: websocket\r\nConnection: Upgrade\r\n" +
                "Sec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n" +
                "Origin: http://localhost\r\n\r\n"
            try sendAll(Data(handshake.utf8))
            let header = try readHeader()
            guard header.contains("HTTP/1.1 101") else {
                close(fd)
                throw ProtocolError(name: .internal_error, message: "handshake CDP recusado")
            }
        }

        deinit { shutdown() }

        func shutdown() {
            guard fd >= 0 else { return }
            let socket = fd
            fd = -1
            _ = close(socket)
        }

        func sendText(_ payload: Data) throws {
            var frame = Data([0x81])
            let mask = (0..<4).map { _ in UInt8.random(in: .min ... .max) }
            if payload.count <= 125 {
                frame.append(0x80 | UInt8(payload.count))
            } else if payload.count <= 65_535 {
                frame.append(0xFE)
                frame.append(UInt8((payload.count >> 8) & 0xFF))
                frame.append(UInt8(payload.count & 0xFF))
            } else {
                frame.append(0xFF)
                for shift in stride(from: 56, through: 0, by: -8) {
                    frame.append(UInt8((UInt64(payload.count) >> UInt64(shift)) & 0xFF))
                }
            }
            frame.append(contentsOf: mask)
            for (index, byte) in payload.enumerated() { frame.append(byte ^ mask[index % 4]) }
            try sendAll(frame)
        }

        func receiveText() throws -> String {
            while true {
                let first = try readExactly(2)
                let opcode = first[0] & 0x0F
                var length = Int(first[1] & 0x7F)
                if length == 126 {
                    let extended = try readExactly(2)
                    length = Int(extended[0]) << 8 | Int(extended[1])
                } else if length == 127 {
                    let extended = try readExactly(8)
                    length = extended.reduce(0) { ($0 << 8) | Int($1) }
                }
                let masked = (first[1] & 0x80) != 0
                let mask = masked ? try readExactly(4) : Data()
                var payload = try readExactly(length)
                if masked {
                    for index in payload.indices { payload[index] ^= mask[index % 4] }
                }
                switch opcode {
                case 0x1:
                    return String(decoding: payload, as: UTF8.self)
                case 0x8:
                    throw ProtocolError(name: .internal_error, message: "CDP encerrou a conexão")
                default:
                    continue
                }
            }
        }

        private func sendAll(_ data: Data) throws {
            var offset = 0
            while offset < data.count {
                let written = data.withUnsafeBytes { bytes in
                    send(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset, 0)
                }
                guard written > 0 else {
                    throw ProtocolError(name: .internal_error, message: "falha ao escrever no CDP")
                }
                offset += written
            }
        }

        private func readHeader() throws -> String {
            while let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let header = buffer.subdata(in: 0..<range.lowerBound)
                buffer.removeSubrange(0..<range.upperBound)
                return String(decoding: header, as: UTF8.self)
            }
            while buffer.count < 16 * 1024 {
                try readMore()
                if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let header = buffer.subdata(in: 0..<range.lowerBound)
                    buffer.removeSubrange(0..<range.upperBound)
                    return String(decoding: header, as: UTF8.self)
                }
            }
            throw ProtocolError(name: .internal_error, message: "handshake CDP grande demais")
        }

        private func readExactly(_ count: Int) throws -> Data {
            while buffer.count < count { try readMore() }
            let result = buffer.subdata(in: 0..<count)
            buffer.removeSubrange(0..<count)
            return result
        }

        private func readMore() throws {
            var bytes = [UInt8](repeating: 0, count: 8192)
            let readCount = recv(fd, &bytes, bytes.count, 0)
            guard readCount > 0 else {
                throw ProtocolError(name: .internal_error, message: "CDP não respondeu")
            }
            buffer.append(contentsOf: bytes.prefix(readCount))
        }
    }

    private func takeScreenshotViaCDP(cdpURL: URL, wsURL: String, filePath: String, clip: RectPayload?) throws -> PortalCommandResult {
        var params: [String: Any] = [:]
        if let c = clip {
            params["clip"] = ["x": c.x, "y": c.y, "width": c.w, "height": c.h, "scale": 1]
        }
        let result = try sendCDPCommand(wsURL: wsURL, method: "Page.captureScreenshot", params: params)
        if let data = result.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let resultDict = json["result"] as? [String: Any],
           let b64 = resultDict["data"] as? String,
           let imgData = Data(base64Encoded: b64) {
            try imgData.write(to: URL(fileURLWithPath: filePath))
            return PortalCommandResult(resultado: filePath, dataB64: b64)
        }
        throw ProtocolError(name: .internal_error, message: "falha ao capturar screenshot")
    }

    private func printToPDFViaCDP(cdpURL: URL, wsURL: String, filePath: String) throws -> PortalCommandResult {
        let result = try sendCDPCommand(wsURL: wsURL, method: "Page.printToPDF", params: [:])
        if let data = result.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let resultDict = json["result"] as? [String: Any],
           let b64 = resultDict["data"] as? String,
           let pdfData = Data(base64Encoded: b64) {
            try pdfData.write(to: URL(fileURLWithPath: filePath))
            return PortalCommandResult(resultado: filePath, dataB64: b64)
        }
        throw ProtocolError(name: .internal_error, message: "falha ao gerar PDF")
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
        let agenda = RoutineScheduling.recalcular(
            agenda: routine.agenda, agora: Date(), jaExecutou: false)
        routine.estadoAgenda = agenda.estado
        routine.proximaExecucao = routine.habilitada ? agenda.proximaExecucao : nil
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
        let agenda = RoutineScheduling.recalcular(
            agenda: routine.agenda,
            agora: Date(),
            jaExecutou: routine.ultimaExecucao != nil && routine.agenda.tipo == .once)
        routine.estadoAgenda = agenda.estado
        routine.proximaExecucao = routine.habilitada ? agenda.proximaExecucao : nil
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
        let agenda = RoutineScheduling.recalcular(
            agenda: routine.agenda,
            agora: Date(),
            jaExecutou: routine.agenda.tipo == .once) // once já teve sua chance
        routine.estadoAgenda = agenda.estado
        routine.proximaExecucao = routine.habilitada ? agenda.proximaExecucao : nil
        routines[id] = routine
        saveRoutines(routine.workspaceID)
        return resultado
    }

    // MARK: - Andares (§16, §24.6)

    private func handleFloorCreate(_ params: FloorCreateParams) throws -> Floor {
        let state = try requireWorkspace(params.workspaceID)
        let raiz: String
        if let caminhoRaiz = state.workspace.caminhoRaiz {
            raiz = caminhoRaiz
        } else {
            // Workspaces recém-criados ainda não apontam para uma pasta do usuário.
            // Damos a eles uma base gerenciada e persistida para que andares sejam
            // utilizáveis antes de um projeto externo ser escolhido.
            let managedBase = paths.workspaceDir(params.workspaceID).appendingPathComponent("base", isDirectory: true)
            try FileManager.default.createDirectory(at: managedBase, withIntermediateDirectories: true)
            raiz = managedBase.path
            state.workspace.caminhoRaiz = raiz
            state.workspace.atualizadoEm = Date()
            try state.saveWorkspace()
        }
        var raizIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: raiz, isDirectory: &raizIsDirectory), raizIsDirectory.boolValue else {
            throw ProtocolError(name: .invalid_params, message: "caminho raiz do workspace não é um diretório")
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
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: base), withIntermediateDirectories: true)

        let floor: Floor
        if Git.isRepo(raiz), Git.hasHead(raiz) {
            let branch = params.branch ?? "andar/\(nomeS)"
            var result = Git.run(["-C", raiz, "worktree", "add", caminho, "-b", branch], cwd: nil)
            if result.status != 0 {
                // branch já existe → usa sem -b
                result = Git.run(["-C", raiz, "worktree", "add", caminho, branch], cwd: nil)
            }
            guard result.status == 0 else {
                throw ProtocolError(name: .internal_error, message: "git worktree add: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            floor = Floor(
                id: ULID.generate(), nome: params.nome, origem: params.workspaceID,
                mecanismo: .gitWorktree, branch: branch, caminho: caminho,
                estado: .ativo, criadoEm: Date(), nos: [])
        } else {
            guard params.branch == nil else {
                throw ProtocolError(
                    name: .floor_mechanism_unavailable,
                    message: "branch exige um repositório Git com ao menos um commit")
            }
            try DirectoryClone.copy(from: raiz, to: caminho)
            floor = Floor(
                id: ULID.generate(), nome: params.nome, origem: params.workspaceID,
                mecanismo: .apfsClone, caminho: caminho,
                estado: .ativo, criadoEm: Date(), nos: [])
        }
        floors[floor.id] = floor
        saveFloors(params.workspaceID)
        broadcast(.floorChanged, ws: params.workspaceID, FloorChangedTopicPayload(floor: floor))
        return floor
    }

    private func handleFloorSwitch(_ params: FloorSwitchParams) throws -> FloorSwitchResult {
        let target = params.floorID.flatMap { floors[$0] }
        if let floorID = params.floorID, target == nil {
            throw ProtocolError(name: .floor_not_found, message: "andar \(floorID) não existe")
        }
        let inferredWorkspaceIDs = Set(activeFloor.compactMap { workspaceID, activeID in
            activeID == params.floorID || params.floorID == nil ? workspaceID : nil
        })
        guard let workspaceID = target?.origem
                ?? params.workspaceID
                ?? (inferredWorkspaceIDs.count == 1 ? inferredWorkspaceIDs.first : nil)
        else {
            throw ProtocolError(
                name: .invalid_params,
                message: "floor.switch para o andar-base exige workspace_id")
        }
        _ = try requireWorkspace(workspaceID)
        if let requestedWorkspaceID = params.workspaceID, requestedWorkspaceID != workspaceID {
            throw ProtocolError(name: .invalid_params, message: "andar pertence a outro workspace")
        }

        // Persiste a câmera do contexto que está sendo abandonado antes da troca.
        if let viewport = params.viewport {
            if let currentID = activeFloor[workspaceID], var current = floors[currentID] {
                current.viewport = viewport
                floors[currentID] = current
                saveFloors(workspaceID)
            } else if let state = workspaces[workspaceID] {
                state.workspace.viewport = viewport
                state.workspace.atualizadoEm = Date()
                try state.saveWorkspace()
            }
        }

        // `floor_id: null` é a operação explícita de retorno ao térreo.
        guard var floor = target else {
            activeFloor.removeValue(forKey: workspaceID)
            let floorNodeIDs = Set(
                floors.values
                    .filter { $0.origem == workspaceID && $0.estado == .ativo }
                    .flatMap(\.nos))
            let baseNodes = workspaces[workspaceID]?.nodeOrder.filter { !floorNodeIDs.contains($0) } ?? []
            return FloorSwitchResult(
                floor: nil,
                nos: .array(baseNodes.map { .string($0.string) }))
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
        activeFloor[workspaceID] = floor.id
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
        guard floor.mecanismo == .gitWorktree else {
            throw ProtocolError(
                name: .floor_mechanism_unavailable,
                message: "clone isolado não suporta aterrissagem; descarte o andar explicitamente")
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
            if floor.mecanismo == .gitWorktree {
                let raiz = self.workspaces[floor.origem]?.workspace.caminhoRaiz ?? floor.caminho
                let result = Git.run(["-C", raiz, "worktree", "remove", "--force", floor.caminho], cwd: nil)
                if result.status != 0 {
                    // Registro órfão pode apontar para um diretório que o Git já
                    // não conhece. Ainda assim só removemos o caminho registrado
                    // e contido na base, nunca uma pasta arbitrária.
                    guard let base = self.workspaces[floor.origem]?.workspace.caminhoRaiz.map(FloorPaths.base(caminhoRaiz:)),
                          caminhoContido(floor.caminho, em: base), floor.caminho != base
                    else {
                        client?.respond(id: requestID, error: ProtocolError(
                            name: .internal_error,
                            message: "git worktree remove: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"))
                        return
                    }
                    do {
                        try FileManager.default.removeItem(atPath: floor.caminho)
                    } catch {
                        client?.respond(id: requestID, error: ProtocolError(
                            name: .internal_error, message: "não foi possível descartar worktree órfão: \(error)"))
                        return
                    }
                    _ = Git.run(["-C", raiz, "worktree", "prune"], cwd: nil)
                }
            } else if let base = self.workspaces[floor.origem]?.workspace.caminhoRaiz.map(FloorPaths.base(caminhoRaiz:)),
                      caminhoContido(floor.caminho, em: base), floor.caminho != base {
                do {
                    try FileManager.default.removeItem(atPath: floor.caminho)
                } catch {
                    client?.respond(id: requestID, error: ProtocolError(
                        name: .internal_error, message: "não foi possível descartar clone: \(error)"))
                    return
                }
            } else {
                client?.respond(id: requestID, error: ProtocolError(
                    name: .invalid_params, message: "caminho do andar fora da base registrada"))
                return
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

    // MARK: - Kill gracioso (TERM → 1s → KILL)

    private func terminateGracefully(_ session: LiveSession, pty: PTYHandle) {
        PTY.signal(pid: pty.pid, SIGTERM)
        session.killDeadline = Date().addingTimeInterval(Self.sessionKillGrace)
        let sessionID = session.id
        stateQueue.asyncAfter(deadline: .now() + Self.sessionKillGrace) { [weak self] in
            guard let self,
                  let current = self.sessions[sessionID],
                  current.estado.isViva,
                  current.killDeadline != nil,
                  let currentPTY = current.pty
            else { return }
            if PTY.isAlive(pid: currentPTY.pid) {
                PTY.signal(pid: currentPTY.pid, SIGKILL)
            }
            current.killDeadline = nil
        }
    }

    private func killAndWait(_ list: [LiveSession], completion: @escaping () -> Void) {
        for session in list where session.estado.isViva {
            if let pty = session.pty {
                terminateGracefully(session, pty: pty)
            }
        }
        pollSessionsEnded(ids: list.map { $0.id }, deadline: Date().addingTimeInterval(4), completion: completion)
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
        for browser in portalBrowsers.values {
            if browser.process?.isRunning == true {
                browser.process?.terminate()
            }
        }
        portalBrowsers.removeAll()
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
