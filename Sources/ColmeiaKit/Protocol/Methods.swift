import Foundation

/// Inventário completo de métodos (§6.4).
public enum ColmeiaMethod: String, Codable, CaseIterable, Sendable {
    case hello
    case workspaceList = "workspace.list"
    case workspaceCreate = "workspace.create"
    case workspaceOpen = "workspace.open"
    case workspaceHealth = "workspace.health"
    case workspaceClose = "workspace.close"
    case workspaceDelete = "workspace.delete"
    case workspaceUpdate = "workspace.update"
    /// Substituição atômica de toda a projeção do workspace (dados completos do sync).
    case workspacePushSnapshot = "workspace.pushSnapshot"
    /// Recupera operações perdidas desde `from_seq` (retorna ops ou snapshot completo).
    case workspaceCatchUp = "workspace.catchUp"
    case docApply = "doc.apply"
    case docSnapshot = "doc.snapshot"
    case docHistory = "doc.history"
    case sessionStart = "session.start"
    case sessionEnsure = "session.ensure"
    case sessionAttach = "session.attach"
    case sessionInput = "session.input"
    case sessionResize = "session.resize"
    case sessionKill = "session.kill"
    case sessionList = "session.list"
    case sessionReplay = "session.replay"
    case approvalList = "approval.list"
    case approvalResolve = "approval.resolve"
    case messageSend = "message.send"
    case chatMessageAppend = "chat.message.append"
    case chatMessageList = "chat.message.list"
    case noteAppend = "note.append"
    /// Capacidades explícitas para agentes manipularem notas sem escrever em arquivos arbitrários.
    case nodeList = "node.list"
    case noteCreate = "note.create"
    case noteGet = "note.get"
    case noteConnected = "note.connected"
    case noteChain = "note.chain"
    case noteAssetAdd = "note.asset.add"
    case noteAssetList = "note.asset.list"
    case noteAssetRm = "note.asset.rm"
    case noteAssetGet = "note.asset.get"
    case noteReplace = "note.replace"
    case noteChecklistAdd = "note.checklist.add"
    case noteChecklistSet = "note.checklist.set"
    /// Modo Rainha: remove nó terminal (apenas rainha).
    case nodeDismiss = "node.dismiss"
    /// Modo Rainha: conecta dois nós (apenas rainha).
    case nodeConnect = "node.connect"
    /// Modo Rainha: desconecta dois nós (apenas rainha).
    case nodeDisconnect = "node.disconnect"
    /// Extensão forward-compatible (§0): [v1.5 antecipado] — cria nó portal validado.
    case portalOpen = "portal.open"
    /// Automação do portal: navigate, click, fill, key, shot, snapshot, eval.
    case portalCommand = "portal.command"
    case routineCreate = "routine.create"
    case routineUpdate = "routine.update"
    case routineDelete = "routine.delete"
    case routineList = "routine.list"
    case routineRunNow = "routine.run_now"
    case floorCreate = "floor.create"
    case floorSwitch = "floor.switch"
    case floorLand = "floor.land"
    case floorDiscard = "floor.discard"
    case floorList = "floor.list"
    case memoryGet = "memory.get"
    case memoryUpdate = "memory.update"
    case memoryPropose = "memory.propose"
    case memoryProposalList = "memory.proposal.list"
    case memoryAccept = "memory.accept"
    case memoryReject = "memory.reject"
    case memoryHistory = "memory.history"
    case deliverySubmit = "delivery.submit"
    case deliveryList = "delivery.list"
    case deliveryAccept = "delivery.accept"
    case deliveryReopen = "delivery.reopen"
    case watchdogGet = "watchdog.get"
    case watchdogUpdate = "watchdog.update"
    case workerArchive = "worker.archive"
    case workerList = "worker.list"
    case workerRestore = "worker.restore"
    case workerAcquire = "worker.acquire"
    case delegationCreate = "delegation.create"
    case delegationWait = "delegation.wait"
    case delegationDone = "delegation.done"
    case delegationList = "delegation.list"
    /// Inventário local dos motores e sua disponibilidade nesta máquina.
    case adapterList = "adapter.list"
    case subscribe
    case unsubscribe
    // Multiplayer — room.* (§6.1)
    case roomCreate = "room.create"
    case roomJoin = "room.join"
    case roomLeave = "room.leave"
    case roomSnapshot = "room.snapshot"
    case roomDelta = "room.delta"
    case roomList = "room.list"
    case roomUpdate = "room.update"
    case roomDelete = "room.delete"
    // Multiplayer — member.* (§7.1)
    case memberInvite = "member.invite"
    case memberInviteList = "member.invite.list"
    case memberInviteRevoke = "member.invite.revoke"
    case memberList = "member.list"
    case memberUpdate = "member.update"
    case memberRemove = "member.remove"
    // Multiplayer — agent_session.* (§4.1.3)
    case agentSessionCreate = "agent_session.create"
    case agentSessionGet = "agent_session.get"
    case agentSessionList = "agent_session.list"
    case agentSessionUpdate = "agent_session.update"
    // Fase 2 — handoff, transições, briefing
    case agentSessionHandoffRequest = "agent_session.handoff_request"
    case agentSessionHandoffAccept = "agent_session.handoff_accept"
    case agentSessionHandoffReject = "agent_session.handoff_reject"
    case agentSessionTransition = "agent_session.transition"
    case agentSessionBriefing = "agent_session.briefing"
    // Multiplayer — session_event.* (§4.1.4)
    case sessionEventAppend = "session_event.append"
    // Multiplayer — grant.* (§4.1.5)
    case grantIssue = "grant.issue"
    case grantRevoke = "grant.revoke"
    case grantList = "grant.list"
    // Multiplayer — presence (§4.1.6, efêmero)
    case presenceUpdate = "presence.update"
    // Multiplayer — lease (§6.1)
    case leaseAcquire = "lease.acquire"
    case leaseRelease = "lease.release"
    case engineStatus = "engine.status"
    case engineShutdown = "engine.shutdown"
    // §5.2–5.8 / Marco A — modelo de missão
    case missionCreate = "mission.create"
    case missionGet = "mission.get"
    case missionList = "mission.list"
    case missionUpdate = "mission.update"
    case missionTransition = "mission.transition"
    case workstreamCreate = "workstream.create"
    case workstreamGet = "workstream.get"
    case workstreamList = "workstream.list"
    case workstreamUpdate = "workstream.update"
    case workstreamTransition = "workstream.transition"
    case workstreamBriefing = "workstream.briefing"
    case decisionCreate = "decision.create"
    case decisionGet = "decision.get"
    case decisionList = "decision.list"
    case decisionDecide = "decision.decide"
    case decisionSupersede = "decision.supersede"
    case decisionCancel = "decision.cancel"
    case relationAdd = "relation.add"
    case relationList = "relation.list"
    case relationRemove = "relation.remove"
}

/// Resultado `{}`.
public struct EmptyResult: Codable, Equatable, Sendable {
    public init() {}
}

// MARK: - adapter.*

public struct AdapterAvailability: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var nome: String
    public var disponivel: Bool

    public init(id: String, nome: String, disponivel: Bool) {
        self.id = id
        self.nome = nome
        self.disponivel = disponivel
    }
}

public typealias AdapterListResult = [AdapterAvailability]

// MARK: - hello (§6.3)

/// CLI dentro de terminal gerenciado DEVE usar `author: agente:<node-id>` (env COLMEIA_NODE_ID).
public struct HelloParams: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    /// "canvas-ui" | "cli" | "test".
    public var client: String
    public var author: Author
    /// Token de autenticação do Hub — opcional (backward compat).
    public var token: String?

    enum CodingKeys: String, CodingKey {
        case client, author, token
        case protocolVersion = "protocol_version"
    }

    public init(protocolVersion: Int = ColmeiaVersion.protocolVersion, client: String, author: Author, token: String? = nil) {
        self.protocolVersion = protocolVersion
        self.client = client
        self.author = author
        self.token = token
    }
}

public struct HelloResult: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var engineVersion: String
    public var engineStartedEm: Date
    public var author: Author?

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case engineVersion = "engine_version"
        case engineStartedEm = "engine_started_em"
        case author
    }

    public init(protocolVersion: Int, engineVersion: String, engineStartedEm: Date, author: Author? = nil) {
        self.protocolVersion = protocolVersion
        self.engineVersion = engineVersion
        self.engineStartedEm = engineStartedEm
        self.author = author
    }
}

public struct SyncSessionStartRequest: Codable, Equatable, Sendable {
    public var requestID: String
    public var start: SessionStartParams

    enum CodingKeys: String, CodingKey {
        case start
        case requestID = "request_id"
    }

    public init(requestID: String, start: SessionStartParams) {
        self.requestID = requestID
        self.start = start
    }
}

public struct SyncSessionStartResult: Codable, Equatable, Sendable {
    public var requestID: String
    public var session: Session?
    public var error: ProtocolError?

    enum CodingKeys: String, CodingKey {
        case session, error
        case requestID = "request_id"
    }

    public init(requestID: String, session: Session? = nil, error: ProtocolError? = nil) {
        self.requestID = requestID
        self.session = session
        self.error = error
    }
}

// MARK: - workspace.*

public struct WorkspaceSummary: Codable, Equatable, Sendable {
    public var id: ULID
    public var nome: String
    public var caminhoRaiz: String?
    public var atualizadoEm: Date

    enum CodingKeys: String, CodingKey {
        case id, nome
        case caminhoRaiz = "caminho_raiz"
        case atualizadoEm = "atualizado_em"
    }

    public init(id: ULID, nome: String, caminhoRaiz: String? = nil, atualizadoEm: Date) {
        self.id = id
        self.nome = nome
        self.caminhoRaiz = caminhoRaiz
        self.atualizadoEm = atualizadoEm
    }
}

public typealias WorkspaceListResult = [WorkspaceSummary]

public struct WorkspaceCreateParams: Codable, Equatable, Sendable {
    public var nome: String
    public var caminhoRaiz: String?
    public var id: ULID?

    enum CodingKeys: String, CodingKey {
        case nome, id
        case caminhoRaiz = "caminho_raiz"
    }

    public init(nome: String, caminhoRaiz: String? = nil, id: ULID? = nil) {
        self.nome = nome
        self.caminhoRaiz = caminhoRaiz
        self.id = id
    }
}

public struct WorkspaceResult: Codable, Equatable, Sendable {
    public var workspace: Workspace

    public init(workspace: Workspace) {
        self.workspace = workspace
    }
}

public struct WorkspaceOpenParams: Codable, Equatable, Sendable {
    public var id: ULID

    public init(id: ULID) {
        self.id = id
    }
}

public struct WorkspaceOpenResult: Codable, Equatable, Sendable {
    public var workspace: Workspace
    public var documentSnapshot: DocumentSnapshot
    public var health: WorkspaceHealth?

    enum CodingKeys: String, CodingKey {
        case workspace
        case documentSnapshot = "document_snapshot"
        case health
    }

    public init(workspace: Workspace, documentSnapshot: DocumentSnapshot, health: WorkspaceHealth? = nil) {
        self.workspace = workspace
        self.documentSnapshot = documentSnapshot
        self.health = health
    }
}

public struct WorkspaceHealthParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    enum CodingKeys: String, CodingKey { case workspaceID = "workspace_id" }
    public init(workspaceID: ULID) { self.workspaceID = workspaceID }
}

public typealias WorkspaceHealthResult = WorkspaceHealth

/// Sessões continuam vivas (§6.4).
public struct WorkspaceCloseParams: Codable, Equatable, Sendable {
    public var id: ULID

    public init(id: ULID) {
        self.id = id
    }
}

/// DEVE falhar com sessões ativas; sem `confirmar: true` → `confirmation_required`.
public struct WorkspaceDeleteParams: Codable, Equatable, Sendable {
    public var id: ULID
    public var confirmar: Bool

    public init(id: ULID, confirmar: Bool) {
        self.id = id
        self.confirmar = confirmar
    }
}

public struct WorkspaceUpdateParams: Codable, Equatable, Sendable {
    public var id: ULID
    public var nome: String?
    public var caminhoRaiz: String?
    public var viewport: Viewport?
    public var cursor: Ponto?
    public var primaryNodeID: ULID?

    enum CodingKeys: String, CodingKey {
        case id, nome, viewport
        case caminhoRaiz = "caminho_raiz"
        case primaryNodeID = "primary_node_id"
    }

    public init(id: ULID, nome: String? = nil, caminhoRaiz: String? = nil, viewport: Viewport? = nil, primaryNodeID: ULID? = nil) {
        self.id = id
        self.nome = nome
        self.caminhoRaiz = caminhoRaiz
        self.viewport = viewport
        self.primaryNodeID = primaryNodeID
    }
}

// MARK: - workspace.pushSnapshot

public struct PushSnapshotParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public var nome: String
    public var seq: UInt64
    public var nodes: [Node]
    public var connections: [Connection]
    public var noteContents: [String: String]?
    public var sessionStates: [[String: String]]?
    public var sessionOutputs: [String: [[String: String]]]?
    public var watchdogConfiguration: WorkerWatchdogConfiguration?
    public var watchdogHistory: [WatchdogHistoryEntry]?

    enum CodingKeys: String, CodingKey {
        case nome, seq, nodes, connections
        case workspaceID = "workspace_id"
        case noteContents = "note_contents"
        case sessionStates = "session_states"
        case sessionOutputs = "session_outputs"
        case watchdogConfiguration = "watchdog_configuration"
        case watchdogHistory = "watchdog_history"
    }

    public init(
        workspaceID: ULID, nome: String, seq: UInt64,
        nodes: [Node], connections: [Connection],
        noteContents: [String: String]? = nil,
        sessionStates: [[String: String]]? = nil,
        sessionOutputs: [String: [[String: String]]]? = nil,
        watchdogConfiguration: WorkerWatchdogConfiguration? = nil,
        watchdogHistory: [WatchdogHistoryEntry]? = nil
    ) {
        self.workspaceID = workspaceID
        self.nome = nome
        self.seq = seq
        self.nodes = nodes
        self.connections = connections
        self.noteContents = noteContents
        self.sessionStates = sessionStates
        self.sessionOutputs = sessionOutputs
        self.watchdogConfiguration = watchdogConfiguration
        self.watchdogHistory = watchdogHistory
    }
}

public struct PushSnapshotResult: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public var seq: UInt64

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id", seq
    }

    public init(workspaceID: ULID, seq: UInt64) {
        self.workspaceID = workspaceID
        self.seq = seq
    }
}

// MARK: - workspace.catchUp

public struct CatchUpParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public var fromSeq: UInt64

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case fromSeq = "from_seq"
    }

    public init(workspaceID: ULID, fromSeq: UInt64) {
        self.workspaceID = workspaceID
        self.fromSeq = fromSeq
    }
}

public struct CatchUpResult: Codable, Equatable, Sendable {
    /// Operações desde `from_seq` (vazio se houve gap — usar snapshot).
    public var ops: [JSONValue]?
    /// Snapshot completo (enviado quando ops não estão disponíveis).
    public var snapshot: DocumentSnapshot?

    public init(ops: [JSONValue]? = nil, snapshot: DocumentSnapshot? = nil) {
        self.ops = ops
        self.snapshot = snapshot
    }
}

// MARK: - doc.*

public struct DocApplyParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public var ops: [DocOp]

    enum CodingKeys: String, CodingKey {
        case ops
        case workspaceID = "workspace_id"
    }

    public init(workspaceID: ULID, ops: [DocOp]) {
        self.workspaceID = workspaceID
        self.ops = ops
    }
}

public struct DocApplyResult: Codable, Equatable, Sendable {
    public var seqFinal: UInt64

    enum CodingKeys: String, CodingKey {
        case seqFinal = "seq_final"
    }

    public init(seqFinal: UInt64) {
        self.seqFinal = seqFinal
    }
}

public struct DocSnapshotParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
    }

    public init(workspaceID: ULID) {
        self.workspaceID = workspaceID
    }
}

public struct DocSnapshotResult: Codable, Equatable, Sendable {
    public var documentSnapshot: DocumentSnapshot

    enum CodingKeys: String, CodingKey {
        case documentSnapshot = "document_snapshot"
    }

    public init(documentSnapshot: DocumentSnapshot) {
        self.documentSnapshot = documentSnapshot
    }
}

public struct DocHistoryParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public var desdeSeq: UInt64
    public var ateSeq: UInt64?

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case desdeSeq = "desde_seq"
        case ateSeq = "ate_seq"
    }

    public init(workspaceID: ULID, desdeSeq: UInt64, ateSeq: UInt64? = nil) {
        self.workspaceID = workspaceID
        self.desdeSeq = desdeSeq
        self.ateSeq = ateSeq
    }
}

public struct DocHistoryResult: Codable, Equatable, Sendable {
    public var ops: [DocOp]

    public init(ops: [DocOp]) {
        self.ops = ops
    }
}

// MARK: - session.*

public struct SessionStartParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public var nodeID: ULID
    /// Extensão forward-compatible de §16: associa o terminal iniciado ao andar
    /// ativo. Ausente/nulo mantém o terminal no andar-base.
    public var floorID: ULID?
    /// §9.1 — geometria inicial do cliente: o PTY já nasce no tamanho certo (o agente
    /// não redesenha a tela num resize logo após o launch). Ausente → default do engine.
    public var cols: Int?
    public var rows: Int?

    enum CodingKeys: String, CodingKey {
        case cols, rows
        case workspaceID = "workspace_id"
        case nodeID = "node_id"
        case floorID = "floor_id"
    }

    public init(
        workspaceID: ULID,
        nodeID: ULID,
        floorID: ULID? = nil,
        cols: Int? = nil,
        rows: Int? = nil
    ) {
        self.workspaceID = workspaceID
        self.nodeID = nodeID
        self.floorID = floorID
        self.cols = cols
        self.rows = rows
    }
}

/// Garante uma sessão para um nó existente: reutiliza a viva ou relança o
/// mesmo nó quando ela terminou, preservando o histórico do adapter.
public struct SessionEnsureParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public var nodeID: ULID
    public var floorID: ULID?
    public var cols: Int?
    public var rows: Int?

    enum CodingKeys: String, CodingKey {
        case cols, rows
        case workspaceID = "workspace_id"
        case nodeID = "node_id"
        case floorID = "floor_id"
    }

    public init(workspaceID: ULID, nodeID: ULID, floorID: ULID? = nil, cols: Int? = nil, rows: Int? = nil) {
        self.workspaceID = workspaceID
        self.nodeID = nodeID
        self.floorID = floorID
        self.cols = cols
        self.rows = rows
    }
}

public struct SessionResult: Codable, Equatable, Sendable {
    public var session: Session

    public init(session: Session) {
        self.session = session
    }
}

public struct WorkerAcquireParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public var role: String
    public var adapter: String
    public var newIdentity: Bool
    enum CodingKeys: String, CodingKey { case role, adapter; case workspaceID = "workspace_id"; case newIdentity = "new" }
    public init(workspaceID: ULID, role: String, adapter: String, newIdentity: Bool = false) {
        self.workspaceID = workspaceID; self.role = role; self.adapter = adapter; self.newIdentity = newIdentity
    }
}

public struct WorkerAcquireResult: Codable, Equatable, Sendable {
    public var node: TerminalNode
    public var session: Session
    public var reused: Bool
    public init(node: TerminalNode, session: Session, reused: Bool) { self.node = node; self.session = session; self.reused = reused }
}

public struct DelegationCreateParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public var principalNodeID: ULID
    public var role: String
    public var adapter: String
    public var task: String
    public var newIdentity: Bool
    enum CodingKeys: String, CodingKey { case role, adapter, task; case workspaceID = "workspace_id"; case principalNodeID = "principal_node_id"; case newIdentity = "new" }
    public init(workspaceID: ULID, principalNodeID: ULID, role: String, adapter: String, task: String, newIdentity: Bool = false) {
        self.workspaceID = workspaceID; self.principalNodeID = principalNodeID; self.role = role; self.adapter = adapter; self.task = task; self.newIdentity = newIdentity
    }
}

public struct DelegationDoneParams: Codable, Equatable, Sendable {
    public var delegationID: ULID
    public var status: DelegationEstado
    public var result: String
    public var deliveryID: ULID?
    enum CodingKeys: String, CodingKey { case status, result; case delegationID = "delegation_id"; case deliveryID = "delivery_id" }
    public init(delegationID: ULID, status: DelegationEstado = .completed, result: String, deliveryID: ULID? = nil) {
        self.delegationID = delegationID; self.status = status; self.result = result; self.deliveryID = deliveryID
    }
}

public struct DelegationResult: Codable, Equatable, Sendable { public var delegation: Delegation; public init(delegation: Delegation) { self.delegation = delegation } }
public struct DelegationWaitParams: Codable, Equatable, Sendable {
    public var delegationID: ULID
    enum CodingKeys: String, CodingKey { case delegationID = "delegation_id" }
    public init(delegationID: ULID) { self.delegationID = delegationID }
}
public struct DelegationListParams: Codable, Equatable, Sendable { public var workspaceID: ULID; public init(workspaceID: ULID) { self.workspaceID = workspaceID } }

/// Replay + stream ao vivo emendados sem buraco nem duplicata (§8.4).
public struct SessionAttachParams: Codable, Equatable, Sendable {
    public var sessionID: ULID
    public var desdeSeq: UInt64?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case desdeSeq = "desde_seq"
    }

    public init(sessionID: ULID, desdeSeq: UInt64? = nil) {
        self.sessionID = sessionID
        self.desdeSeq = desdeSeq
    }
}

public struct SessionAttachResult: Codable, Equatable, Sendable {
    public var session: Session
    public var replay: [Event]

    public init(session: Session, replay: [Event]) {
        self.session = session
        self.replay = replay
    }
}

public struct SessionInputParams: Codable, Equatable, Sendable {
    public var sessionID: ULID
    public var dataB64: String

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case dataB64 = "data_b64"
    }

    public init(sessionID: ULID, dataB64: String) {
        self.sessionID = sessionID
        self.dataB64 = dataB64
    }
}

public struct SessionResizeParams: Codable, Equatable, Sendable {
    public var sessionID: ULID
    public var cols: Int
    public var rows: Int

    enum CodingKeys: String, CodingKey {
        case cols, rows
        case sessionID = "session_id"
    }

    public init(sessionID: ULID, cols: Int, rows: Int) {
        self.sessionID = sessionID
        self.cols = cols
        self.rows = rows
    }
}

public enum KillSinal: String, Codable, CaseIterable, Sendable {
    case term, kill
}

public struct SessionKillParams: Codable, Equatable, Sendable {
    public var sessionID: ULID
    public var sinal: KillSinal?

    enum CodingKeys: String, CodingKey {
        case sinal
        case sessionID = "session_id"
    }

    public init(sessionID: ULID, sinal: KillSinal? = nil) {
        self.sessionID = sessionID
        self.sinal = sinal
    }
}

public struct SessionListParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID?

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
    }

    public init(workspaceID: ULID? = nil) {
        self.workspaceID = workspaceID
    }
}

public typealias SessionListResult = [Session]

/// Funciona para sessões encerradas (§6.4).
public struct SessionReplayParams: Codable, Equatable, Sendable {
    public var sessionID: ULID
    public var desdeSeq: UInt64?
    public var ateSeq: UInt64?
    public var limit: Int?

    enum CodingKeys: String, CodingKey {
        case limit
        case sessionID = "session_id"
        case desdeSeq = "desde_seq"
        case ateSeq = "ate_seq"
    }

    public init(sessionID: ULID, desdeSeq: UInt64? = nil, ateSeq: UInt64? = nil, limit: Int? = nil) {
        self.sessionID = sessionID
        self.desdeSeq = desdeSeq
        self.ateSeq = ateSeq
        self.limit = limit
    }
}

public struct SessionReplayResult: Codable, Equatable, Sendable {
    public var events: [Event]

    public init(events: [Event]) {
        self.events = events
    }
}

// MARK: - approval.*

public struct ApprovalListParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID?
    public var estado: ApprovalEstado?

    enum CodingKeys: String, CodingKey {
        case estado
        case workspaceID = "workspace_id"
    }

    public init(workspaceID: ULID? = nil, estado: ApprovalEstado? = nil) {
        self.workspaceID = workspaceID
        self.estado = estado
    }
}

public typealias ApprovalListResult = [Approval]

public struct ApprovalResolveParams: Codable, Equatable, Sendable {
    public var approvalID: ULID
    public var decisao: ApprovalDecisao
    public var opcaoIndex: Int?

    enum CodingKeys: String, CodingKey {
        case decisao
        case approvalID = "approval_id"
        case opcaoIndex = "opcao_index"
    }

    public init(approvalID: ULID, decisao: ApprovalDecisao, opcaoIndex: Int? = nil) {
        self.approvalID = approvalID
        self.decisao = decisao
        self.opcaoIndex = opcaoIndex
    }
}

public struct ApprovalResult: Codable, Equatable, Sendable {
    public var approval: Approval

    public init(approval: Approval) {
        self.approval = approval
    }
}

// MARK: - message.send (§14)

public struct MessageSendParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public var deNode: ULID
    /// Endereçamento por NOME do nó (único case-insensitive no workspace, §5.2.1).
    public var paraNome: String
    public var texto: String
    public var timeoutSeg: Int?

    enum CodingKeys: String, CodingKey {
        case texto
        case workspaceID = "workspace_id"
        case deNode = "de_node"
        case paraNome = "para_nome"
        case timeoutSeg = "timeout_seg"
    }

    public init(workspaceID: ULID, deNode: ULID, paraNome: String, texto: String, timeoutSeg: Int? = nil) {
        self.workspaceID = workspaceID
        self.deNode = deNode
        self.paraNome = paraNome
        self.texto = texto
        self.timeoutSeg = timeoutSeg
    }
}

public struct MessageSendResult: Codable, Equatable, Sendable {
    public var messageID: ULID

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
    }

    public init(messageID: ULID) {
        self.messageID = messageID
    }
}

// MARK: - chat.message.*

public struct ChatMessageAppendParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public var fromNodeID: ULID?
    public var toNodeID: ULID
    public var text: String
    public var attachments: [String]

    enum CodingKeys: String, CodingKey {
        case text, attachments
        case workspaceID = "workspace_id"
        case fromNodeID = "from_node_id"
        case toNodeID = "to_node_id"
    }

    public init(
        workspaceID: ULID,
        fromNodeID: ULID? = nil,
        toNodeID: ULID,
        text: String,
        attachments: [String] = []
    ) {
        self.workspaceID = workspaceID
        self.fromNodeID = fromNodeID
        self.toNodeID = toNodeID
        self.text = text
        self.attachments = attachments
    }
}

public struct ChatMessageListParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public var nodeID: ULID?
    public var limit: Int?

    enum CodingKeys: String, CodingKey {
        case limit
        case workspaceID = "workspace_id"
        case nodeID = "node_id"
    }

    public init(workspaceID: ULID, nodeID: ULID? = nil, limit: Int? = nil) {
        self.workspaceID = workspaceID
        self.nodeID = nodeID
        self.limit = limit
    }
}

public struct ChatMessageResult: Codable, Equatable, Sendable {
    public var message: ChatMessage

    public init(message: ChatMessage) { self.message = message }
}

public typealias ChatMessageListResult = [ChatMessage]

// MARK: - note.append (§13.3)

/// Sem conexão `escrita-de-nota`, o engine DEVE criar NotaNode adjacente e conectá-la.
public struct NoteAppendParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public var nodeIDOrigem: ULID
    public var texto: String

    enum CodingKeys: String, CodingKey {
        case texto
        case workspaceID = "workspace_id"
        case nodeIDOrigem = "node_id_origem"
    }

    public init(workspaceID: ULID, nodeIDOrigem: ULID, texto: String) {
        self.workspaceID = workspaceID
        self.nodeIDOrigem = nodeIDOrigem
        self.texto = texto
    }
}

public struct NoteAppendResult: Codable, Equatable, Sendable {
    public var notaNodeID: ULID

    enum CodingKeys: String, CodingKey {
        case notaNodeID = "nota_node_id"
    }

    public init(notaNodeID: ULID) {
        self.notaNodeID = notaNodeID
    }
}

// MARK: - node.list / note.* (capacidades de agentes)

/// Lista metadados de nós; nunca inclui o conteúdo de arquivos de nota.
public struct NodeListParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public var floorID: ULID?
    public var tipo: NodeTipo?

    enum CodingKeys: String, CodingKey {
        case tipo
        case workspaceID = "workspace_id"
        case floorID = "floor_id"
    }

    public init(workspaceID: ULID, floorID: ULID? = nil, tipo: NodeTipo? = nil) {
        self.workspaceID = workspaceID
        self.floorID = floorID
        self.tipo = tipo
    }
}

public struct NodeSummary: Codable, Equatable, Sendable {
    public var id: ULID
    public var tipo: NodeTipo
    public var titulo: String
    public var floorID: ULID?
    /// "regular" | "rainha" — papel do nó terminal no workspace.
    public var papel: String?
    /// Estado da sessão ativa, se houver.
    public var estadoSessao: String?
    /// Nome do adapter (shell, claude-code, etc).
    public var adapter: String?

    enum CodingKeys: String, CodingKey {
        case id, tipo, titulo, papel, adapter
        case floorID = "floor_id"
        case estadoSessao = "estado_sessao"
    }

    public init(id: ULID, tipo: NodeTipo, titulo: String, floorID: ULID? = nil, papel: String? = nil, estadoSessao: String? = nil, adapter: String? = nil) {
        self.id = id
        self.tipo = tipo
        self.titulo = titulo
        self.floorID = floorID
        self.papel = papel
        self.estadoSessao = estadoSessao
        self.adapter = adapter
    }
}

public typealias NodeListResult = [NodeSummary]

public struct NoteChecklistItem: Codable, Equatable, Sendable {
    public var id: ULID
    public var texto: String
    public var marcada: Bool

    public init(id: ULID, texto: String, marcada: Bool) {
        self.id = id
        self.texto = texto
        self.marcada = marcada
    }
}

/// Conteúdo de uma NotaNode. Só é retornado por `note.get`, nunca por `node.list`.
public struct NoteRecord: Codable, Equatable, Sendable {
    public var nodeID: ULID
    public var conteudo: String
    public var cor: String
    public var ultimaFonte: Author?
    public var floorID: ULID?
    public var checklist: [NoteChecklistItem]

    enum CodingKeys: String, CodingKey {
        case conteudo, cor, checklist
        case nodeID = "node_id"
        case ultimaFonte = "ultima_fonte"
        case floorID = "floor_id"
    }

    public init(
        nodeID: ULID, conteudo: String, cor: String, ultimaFonte: Author?,
        floorID: ULID?, checklist: [NoteChecklistItem]
    ) {
        self.nodeID = nodeID
        self.conteudo = conteudo
        self.cor = cor
        self.ultimaFonte = ultimaFonte
        self.floorID = floorID
        self.checklist = checklist
    }
}

public struct NoteCreateParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public var conteudo: String
    public var cor: String?
    public var floorID: ULID?

    enum CodingKeys: String, CodingKey {
        case conteudo, cor
        case workspaceID = "workspace_id"
        case floorID = "floor_id"
    }

    public init(workspaceID: ULID, conteudo: String = "", cor: String? = nil, floorID: ULID? = nil) {
        self.workspaceID = workspaceID
        self.conteudo = conteudo
        self.cor = cor
        self.floorID = floorID
    }
}

public struct NoteGetParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public var nodeID: ULID

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case nodeID = "node_id"
    }

    public init(workspaceID: ULID, nodeID: ULID) {
        self.workspaceID = workspaceID
        self.nodeID = nodeID
    }
}

public struct NoteConnectedParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public var nodeID: ULID
    /// Se true, faz travessia recursiva (BFS) seguindo conexões de nota em nota.
    public var recursivo: Bool?
    /// Profundidade máxima da recursão (1 = só conexões diretas).
    public var maxProfundidade: Int?

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case nodeID = "node_id"
        case recursivo
        case maxProfundidade = "max_profundidade"
    }

    public init(workspaceID: ULID, nodeID: ULID, recursivo: Bool? = nil, maxProfundidade: Int? = nil) {
        self.workspaceID = workspaceID
        self.nodeID = nodeID
        self.recursivo = recursivo
        self.maxProfundidade = maxProfundidade
    }
}

public struct NoteConnectedEntry: Codable, Equatable, Sendable {
    public var note: NoteRecord
    /// Profundidade na travessia: 0 = direta, 1 = conexão de conexão, etc.
    public var profundidade: Int
    /// true se este nó já foi visitado antes (ciclo).
    public var ciclo: Bool

    public init(note: NoteRecord, profundidade: Int, ciclo: Bool = false) {
        self.note = note
        self.profundidade = profundidade
        self.ciclo = ciclo
    }
}

public typealias NoteConnectedResult = [NoteRecord]

public typealias NoteChainResult = [NoteConnectedEntry]

// MARK: - note.asset.* (Paste image)

public struct AssetRef: Codable, Equatable, Sendable, Identifiable {
    public var id: ULID
    public var mime: String
    /// Tamanho em bytes.
    public var tamanho: Int
    /// Texto alternativo para markdown.
    public var alt: String?
    public var criadoEm: Date
    /// Nome do arquivo original (útil para extensão).
    public var filename: String?

    enum CodingKeys: String, CodingKey {
        case id, mime, tamanho, alt
        case criadoEm = "criado_em"
        case filename
    }

    public init(id: ULID, mime: String, tamanho: Int, alt: String? = nil, criadoEm: Date, filename: String? = nil) {
        self.id = id
        self.mime = mime
        self.tamanho = tamanho
        self.alt = alt
        self.criadoEm = criadoEm
        self.filename = filename
    }
}

public struct NoteAssetAddParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public var nodeID: ULID
    public var mime: String
    /// Conteúdo binário em base64.
    public var dataB64: String
    public var alt: String?
    public var filename: String?

    enum CodingKeys: String, CodingKey {
        case mime, alt, filename
        case workspaceID = "workspace_id"
        case nodeID = "node_id"
        case dataB64 = "data_b64"
    }

    public init(workspaceID: ULID, nodeID: ULID, mime: String, dataB64: String, alt: String? = nil, filename: String? = nil) {
        self.workspaceID = workspaceID
        self.nodeID = nodeID
        self.mime = mime
        self.dataB64 = dataB64
        self.alt = alt
        self.filename = filename
    }
}

public struct NoteAssetAddResult: Codable, Equatable, Sendable {
    public var asset: AssetRef
    public var markdown: String

    public init(asset: AssetRef, markdown: String) {
        self.asset = asset
        self.markdown = markdown
    }
}

public struct NoteAssetListParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public var nodeID: ULID

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case nodeID = "node_id"
    }

    public init(workspaceID: ULID, nodeID: ULID) {
        self.workspaceID = workspaceID
        self.nodeID = nodeID
    }
}

public typealias NoteAssetListResult = [AssetRef]

public struct NoteAssetRmParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public var nodeID: ULID
    public var assetID: ULID

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case nodeID = "node_id"
        case assetID = "asset_id"
    }

    public init(workspaceID: ULID, nodeID: ULID, assetID: ULID) {
        self.workspaceID = workspaceID
        self.nodeID = nodeID
        self.assetID = assetID
    }
}

public struct NoteAssetGetParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public var nodeID: ULID
    public var assetID: ULID

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case nodeID = "node_id"
        case assetID = "asset_id"
    }

    public init(workspaceID: ULID, nodeID: ULID, assetID: ULID) {
        self.workspaceID = workspaceID
        self.nodeID = nodeID
        self.assetID = assetID
    }
}

public struct NoteAssetGetResult: Codable, Equatable, Sendable {
    public var asset: AssetRef
    public var dataB64: String

    enum CodingKeys: String, CodingKey {
        case asset
        case dataB64 = "data_b64"
    }

    public init(asset: AssetRef, dataB64: String) {
        self.asset = asset
        self.dataB64 = dataB64
    }
}

public struct NoteReplaceParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public var nodeID: ULID
    public var conteudo: String

    enum CodingKeys: String, CodingKey {
        case conteudo
        case workspaceID = "workspace_id"
        case nodeID = "node_id"
    }

    public init(workspaceID: ULID, nodeID: ULID, conteudo: String) {
        self.workspaceID = workspaceID
        self.nodeID = nodeID
        self.conteudo = conteudo
    }
}

/// Cria um item de checklist com ID estável retornado em `NoteRecord.checklist`.
public struct NoteChecklistAddParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public var nodeID: ULID
    public var texto: String

    enum CodingKeys: String, CodingKey {
        case texto
        case workspaceID = "workspace_id"
        case nodeID = "node_id"
    }

    public init(workspaceID: ULID, nodeID: ULID, texto: String) {
        self.workspaceID = workspaceID
        self.nodeID = nodeID
        self.texto = texto
    }
}

public struct NoteChecklistSetParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public var nodeID: ULID
    public var itemID: ULID
    public var marcada: Bool

    enum CodingKeys: String, CodingKey {
        case marcada
        case workspaceID = "workspace_id"
        case nodeID = "node_id"
        case itemID = "item_id"
    }

    public init(workspaceID: ULID, nodeID: ULID, itemID: ULID, marcada: Bool) {
        self.workspaceID = workspaceID
        self.nodeID = nodeID
        self.itemID = itemID
        self.marcada = marcada
    }
}

public struct NoteChecklistSetResult: Codable, Equatable, Sendable {
    public var note: NoteRecord
    public var changed: Bool

    public init(note: NoteRecord, changed: Bool) {
        self.note = note
        self.changed = changed
    }
}

// MARK: - node.dismiss / node.connect / node.disconnect (Modo Rainha)

public struct NodeDismissParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public var nodeID: ULID

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case nodeID = "node_id"
    }

    public init(workspaceID: ULID, nodeID: ULID) {
        self.workspaceID = workspaceID
        self.nodeID = nodeID
    }
}

public struct NodeConnectParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public var de: ULID
    public var para: ULID

    enum CodingKeys: String, CodingKey {
        case de, para
        case workspaceID = "workspace_id"
    }

    public init(workspaceID: ULID, de: ULID, para: ULID) {
        self.workspaceID = workspaceID
        self.de = de
        self.para = para
    }
}

public struct NodeDisconnectParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public var de: ULID
    public var para: ULID

    enum CodingKeys: String, CodingKey {
        case de, para
        case workspaceID = "workspace_id"
    }

    public init(workspaceID: ULID, de: ULID, para: ULID) {
        self.workspaceID = workspaceID
        self.de = de
        self.para = para
    }
}

// MARK: - portal.open ([v1.5] antecipado)

/// `portal.open {workspace_id, url, nome?}` → engine valida a URL (http/https apenas;
/// senão `invalid_params`), cria op `node.add` de PortalNode pelo caminho interno de
/// `doc.apply` e retorna `{node_id}`. Clientes veem o `node.add` pelo tópico
/// `document.op` normalmente. Navegar portal existente = `node.update {url}` comum.
public struct PortalOpenParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public var url: String
    /// Apelido inicial do portal (vira `titulo` até a página fornecer o próprio).
    public var nome: String?
    /// Quando presente, o portal passa a pertencer ao andar ativo indicado.
    public var floorID: ULID?

    enum CodingKeys: String, CodingKey {
        case url, nome
        case workspaceID = "workspace_id"
        case floorID = "floor_id"
    }

    public init(workspaceID: ULID, url: String, nome: String? = nil, floorID: ULID? = nil) {
        self.workspaceID = workspaceID
        self.url = url
        self.nome = nome
        self.floorID = floorID
    }
}

public struct PortalOpenResult: Codable, Equatable, Sendable {
    public var nodeID: ULID

    enum CodingKeys: String, CodingKey {
        case nodeID = "node_id"
    }

    public init(nodeID: ULID) {
        self.nodeID = nodeID
    }
}

// MARK: - portal.command (Automação do portal)

/// Ação a ser executada no portal.
public enum PortalCommandAction: String, Codable, CaseIterable, Sendable {
    /// Navegar para uma URL.
    case navigate
    /// Tirar screenshot do viewport.
    case shot
    /// Capturar página como PDF.
    case snapshot
    /// Clicar num elemento (seletor CSS).
    case click
    /// Preencher campo de formulário.
    case fill
    /// Enviar tecla(s).
    case key
    /// Executar JavaScript.
    case eval
}

/// `portal.command` — controla um portal aberto.
///
/// - `navigate`: `{url}` — vai para a URL.
/// - `shot`: `{selector?}` — screenshot do viewport (ou de um elemento).
/// - `snapshot`: `{}` — PDF da página atual.
/// - `click`: `{selector}` — clique no elemento.
/// - `fill`: `{selector, value}` — preenche campo.
/// - `key`: `{keys}` — teclas (ex: "Enter", "Tab", "Escape").
/// - `eval`: `{code}` — executa JS e retorna resultado.
public struct PortalCommandParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public var nodeID: ULID
    public var acao: PortalCommandAction
    public var url: String?
    public var selector: String?
    public var value: String?
    public var keys: String?
    public var code: String?

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case nodeID = "node_id"
        case acao = "action"
        case url, selector, value, keys, code
    }

    public init(
        workspaceID: ULID, nodeID: ULID, acao: PortalCommandAction,
        url: String? = nil, selector: String? = nil, value: String? = nil,
        keys: String? = nil, code: String? = nil
    ) {
        self.workspaceID = workspaceID
        self.nodeID = nodeID
        self.acao = acao
        self.url = url
        self.selector = selector
        self.value = value
        self.keys = keys
        self.code = code
    }
}

public struct PortalCommandResult: Codable, Equatable, Sendable {
    /// Resultado textual (ex: screenshot path, eval return, confirmação).
    public var resultado: String
    /// Dados binários em base64 (screenshot, snapshot PDF).
    public var dataB64: String?

    enum CodingKeys: String, CodingKey {
        case resultado
        case dataB64 = "data_b64"
    }

    public init(resultado: String, dataB64: String? = nil) {
        self.resultado = resultado
        self.dataB64 = dataB64
    }
}

// MARK: - routine.* (§5.7/§17)

public struct RoutineCreateParams: Codable, Equatable, Sendable {
    public var nome: String
    public var workspaceID: ULID
    public var alvo: ULID
    public var comando: String
    public var agenda: Agenda
    public var notificar: Bool
    public var habilitada: Bool

    enum CodingKeys: String, CodingKey {
        case nome, alvo, comando, agenda, notificar, habilitada
        case workspaceID = "workspace_id"
    }

    public init(
        nome: String,
        workspaceID: ULID,
        alvo: ULID,
        comando: String,
        agenda: Agenda,
        notificar: Bool = false,
        habilitada: Bool = true
    ) {
        self.nome = nome
        self.workspaceID = workspaceID
        self.alvo = alvo
        self.comando = comando
        self.agenda = agenda
        self.notificar = notificar
        self.habilitada = habilitada
    }
}

public struct RoutineUpdateParams: Codable, Equatable, Sendable {
    public var id: ULID
    public var nome: String?
    public var alvo: ULID?
    public var comando: String?
    public var agenda: Agenda?
    public var notificar: Bool?
    public var habilitada: Bool?

    public init(
        id: ULID,
        nome: String? = nil,
        alvo: ULID? = nil,
        comando: String? = nil,
        agenda: Agenda? = nil,
        notificar: Bool? = nil,
        habilitada: Bool? = nil
    ) {
        self.id = id
        self.nome = nome
        self.alvo = alvo
        self.comando = comando
        self.agenda = agenda
        self.notificar = notificar
        self.habilitada = habilitada
    }
}

public struct RoutineDeleteParams: Codable, Equatable, Sendable {
    public var id: ULID

    public init(id: ULID) {
        self.id = id
    }
}

public struct RoutineResult: Codable, Equatable, Sendable {
    public var routine: Routine

    public init(routine: Routine) {
        self.routine = routine
    }
}

public struct RoutineListParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
    }

    public init(workspaceID: ULID) {
        self.workspaceID = workspaceID
    }
}

public typealias RoutineListResult = [Routine]

public struct RoutineRunNowParams: Codable, Equatable, Sendable {
    public var routineID: ULID

    enum CodingKeys: String, CodingKey {
        case routineID = "routine_id"
    }

    public init(routineID: ULID) {
        self.routineID = routineID
    }
}

public struct RoutineRunNowResult: Codable, Equatable, Sendable {
    public var resultado: RoutineResultado

    public init(resultado: RoutineResultado) {
        self.resultado = resultado
    }
}

// MARK: - floor.* (§16)

public struct FloorCreateParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public var nome: String
    public var branch: String?

    enum CodingKeys: String, CodingKey {
        case nome, branch
        case workspaceID = "workspace_id"
    }

    public init(workspaceID: ULID, nome: String, branch: String? = nil) {
        self.workspaceID = workspaceID
        self.nome = nome
        self.branch = branch
    }
}

public struct FloorResult: Codable, Equatable, Sendable {
    public var floor: Floor

    public init(floor: Floor) {
        self.floor = floor
    }
}

public struct FloorSwitchParams: Codable, Equatable, Sendable {
    /// Necessário quando `floor_id` é nulo para identificar de qual workspace
    /// sair. Opcional para manter compatibilidade com clientes anteriores.
    public var workspaceID: ULID?
    /// `nil` volta explicitamente ao andar-base. Clientes antigos continuam
    /// enviando um ULID e recebem a mesma resposta de antes.
    public var floorID: ULID?
    /// Viewport do contexto que está sendo abandonado, persistido antes da troca.
    public var viewport: Viewport?

    enum CodingKeys: String, CodingKey {
        case viewport
        case workspaceID = "workspace_id"
        case floorID = "floor_id"
    }

    public init(workspaceID: ULID? = nil, floorID: ULID?, viewport: Viewport? = nil) {
        self.workspaceID = workspaceID
        self.floorID = floorID
        self.viewport = viewport
    }
}

/// A spec (§6.4) não fixa a forma de `nos`; fica genérico até a implementação de §16.
public struct FloorSwitchResult: Codable, Equatable, Sendable {
    /// `nil` representa o andar-base; respostas para andares continuam trazendo
    /// um Floor completo e permanecem compatíveis com clientes anteriores.
    public var floor: Floor?
    public var nos: JSONValue

    public init(floor: Floor?, nos: JSONValue) {
        self.floor = floor
        self.nos = nos
    }
}

public struct FloorLandParams: Codable, Equatable, Sendable {
    public var floorID: ULID
    public var confirmar: Bool

    enum CodingKeys: String, CodingKey {
        case confirmar
        case floorID = "floor_id"
    }

    public init(floorID: ULID, confirmar: Bool) {
        self.floorID = floorID
        self.confirmar = confirmar
    }
}

public struct FloorDiscardParams: Codable, Equatable, Sendable {
    public var floorID: ULID
    public var confirmar: Bool

    enum CodingKeys: String, CodingKey {
        case confirmar
        case floorID = "floor_id"
    }

    public init(floorID: ULID, confirmar: Bool) {
        self.floorID = floorID
        self.confirmar = confirmar
    }
}

public struct FloorListParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
    }

    public init(workspaceID: ULID) {
        self.workspaceID = workspaceID
    }
}

public typealias FloorListResult = [Floor]

// MARK: - subscribe / unsubscribe

public struct SubscribeParams: Codable, Equatable, Sendable {
    public var topics: [ColmeiaTopic]
    public var workspaceID: ULID?

    enum CodingKeys: String, CodingKey {
        case topics
        case workspaceID = "workspace_id"
    }

    public init(topics: [ColmeiaTopic], workspaceID: ULID? = nil) {
        self.topics = topics
        self.workspaceID = workspaceID
    }
}

public struct UnsubscribeParams: Codable, Equatable, Sendable {
    public var topics: [ColmeiaTopic]

    public init(topics: [ColmeiaTopic]) {
        self.topics = topics
    }
}

// MARK: - engine.*

public struct EngineStatusResult: Codable, Equatable, Sendable {
    public var sessionsAtivas: Int
    public var workspacesAbertos: Int
    /// Segundos desde o start do engine.
    public var uptime: Double
    public var versao: String

    enum CodingKeys: String, CodingKey {
        case uptime, versao
        case sessionsAtivas = "sessions_ativas"
        case workspacesAbertos = "workspaces_abertos"
    }

    public init(sessionsAtivas: Int, workspacesAbertos: Int, uptime: Double, versao: String) {
        self.sessionsAtivas = sessionsAtivas
        self.workspacesAbertos = workspacesAbertos
        self.uptime = uptime
        self.versao = versao
    }
}

/// DEVE fazer flush e encerrar sessões graciosamente (§6.4).
public struct EngineShutdownParams: Codable, Equatable, Sendable {
    public var confirmar: Bool

    public init(confirmar: Bool) {
        self.confirmar = confirmar
    }
}

// MARK: - room.* (§6.1)

public struct RoomCreateParams: Codable, Equatable, Sendable {
    public var name: String
    public var policy: RoomPolicy?
    /// ID opcional — usado pelo Hub ao sincronizar sala com o Engine.
    public var id: ULID?
    /// Workspace a vincular a esta sala (opcional).
    public var workspaceID: ULID?

    enum CodingKeys: String, CodingKey {
        case name, policy, id
        case workspaceID = "workspace_id"
    }

    public init(name: String, policy: RoomPolicy? = nil, id: ULID? = nil, workspaceID: ULID? = nil) {
        self.name = name
        self.policy = policy
        self.id = id
        self.workspaceID = workspaceID
    }
}

public struct RoomResult: Codable, Equatable, Sendable {
    public var room: Room

    public init(room: Room) { self.room = room }
}

public struct RoomJoinParams: Codable, Equatable, Sendable {
    public var roomID: ULID
    public var inviteToken: String?

    enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case inviteToken = "invite_token"
    }

    public init(roomID: ULID, inviteToken: String? = nil) {
        self.roomID = roomID
        self.inviteToken = inviteToken
    }
}

public struct RoomJoinResult: Codable, Equatable, Sendable {
    public var room: Room
    public var members: [Member]
    public var agentSessions: [AgentSession]

    enum CodingKeys: String, CodingKey {
        case room, members
        case agentSessions = "agent_sessions"
    }

    public init(room: Room, members: [Member], agentSessions: [AgentSession]) {
        self.room = room
        self.members = members
        self.agentSessions = agentSessions
    }
}

public struct RoomLeaveParams: Codable, Equatable, Sendable {
    public var roomID: ULID

    enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
    }

    public init(roomID: ULID) { self.roomID = roomID }
}

public struct RoomSnapshotParams: Codable, Equatable, Sendable {
    public var roomID: ULID
    public var sinceRoomSeq: UInt64?

    enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case sinceRoomSeq = "since_room_seq"
    }

    public init(roomID: ULID, sinceRoomSeq: UInt64? = nil) {
        self.roomID = roomID
        self.sinceRoomSeq = sinceRoomSeq
    }
}

public struct RoomSnapshotResult: Codable, Equatable, Sendable {
    public var room: Room
    public var members: [Member]
    public var agentSessions: [AgentSession]
    public var events: [CollaborativeSessionEvent]
    public var roomSeq: UInt64

    enum CodingKeys: String, CodingKey {
        case room, members, events
        case agentSessions = "agent_sessions"
        case roomSeq = "room_seq"
    }

    public init(
        room: Room, members: [Member],
        agentSessions: [AgentSession],
        events: [CollaborativeSessionEvent],
        roomSeq: UInt64
    ) {
        self.room = room
        self.members = members
        self.agentSessions = agentSessions
        self.events = events
        self.roomSeq = roomSeq
    }
}

/// Delta incremental — apenas eventos e estado mutável desde `sinceRoomSeq` (§6.2).
public struct RoomDeltaParams: Codable, Equatable, Sendable {
    public var roomID: ULID
    public var sinceRoomSeq: UInt64

    enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case sinceRoomSeq = "since_room_seq"
    }

    public init(roomID: ULID, sinceRoomSeq: UInt64) {
        self.roomID = roomID
        self.sinceRoomSeq = sinceRoomSeq
    }
}

public struct RoomDeltaResult: Codable, Equatable, Sendable {
    public var events: [CollaborativeSessionEvent]
    public var agentSessions: [AgentSession]
    public var roomSeq: UInt64
    public var roomUpdatedAt: Date

    enum CodingKeys: String, CodingKey {
        case events
        case agentSessions = "agent_sessions"
        case roomSeq = "room_seq"
        case roomUpdatedAt = "room_updated_at"
    }

    public init(
        events: [CollaborativeSessionEvent],
        agentSessions: [AgentSession],
        roomSeq: UInt64,
        roomUpdatedAt: Date
    ) {
        self.events = events
        self.agentSessions = agentSessions
        self.roomSeq = roomSeq
        self.roomUpdatedAt = roomUpdatedAt
    }
}

public typealias RoomListResult = [Room]

public struct RoomUpdateParams: Codable, Equatable, Sendable {
    public var roomID: ULID
    public var name: String?
    public var policy: RoomPolicy?

    enum CodingKeys: String, CodingKey {
        case name, policy
        case roomID = "room_id"
    }

    public init(roomID: ULID, name: String? = nil, policy: RoomPolicy? = nil) {
        self.roomID = roomID
        self.name = name
        self.policy = policy
    }
}

public struct RoomDeleteParams: Codable, Equatable, Sendable {
    public var roomID: ULID
    public var confirmar: Bool

    enum CodingKeys: String, CodingKey {
        case confirmar
        case roomID = "room_id"
    }

    public init(roomID: ULID, confirmar: Bool) {
        self.roomID = roomID
        self.confirmar = confirmar
    }
}

// MARK: - member.* (§7.1)

public struct MemberInviteParams: Codable, Equatable, Sendable {
    public var roomID: ULID
    public var displayName: String
    public var roles: Set<MemberRole>
    /// TTL do convite em segundos; default definido-pela-implementação.
    public var ttlSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case roles
        case roomID = "room_id"
        case displayName = "display_name"
        case ttlSeconds = "ttl_seconds"
    }

    public init(roomID: ULID, displayName: String, roles: Set<MemberRole>, ttlSeconds: Int? = nil) {
        self.roomID = roomID
        self.displayName = displayName
        self.roles = roles
        self.ttlSeconds = ttlSeconds
    }
}

public struct MemberInviteResult: Codable, Equatable, Sendable {
    public var member: Member
    public var inviteToken: String

    enum CodingKeys: String, CodingKey {
        case member
        case inviteToken = "invite_token"
    }

    public init(member: Member, inviteToken: String) {
        self.member = member
        self.inviteToken = inviteToken
    }
}

public struct MemberInviteListParams: Codable, Equatable, Sendable {
    public var roomID: ULID

    enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
    }

    public init(roomID: ULID) {
        self.roomID = roomID
    }
}

public typealias MemberInviteListResult = [InviteToken]

public struct MemberInviteRevokeParams: Codable, Equatable, Sendable {
    public var roomID: ULID
    public var token: String

    enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case token
    }

    public init(roomID: ULID, token: String) {
        self.roomID = roomID
        self.token = token
    }
}

public struct MemberListParams: Codable, Equatable, Sendable {
    public var roomID: ULID
    public var status: MemberStatus?

    enum CodingKeys: String, CodingKey {
        case status
        case roomID = "room_id"
    }

    public init(roomID: ULID, status: MemberStatus? = nil) {
        self.roomID = roomID
        self.status = status
    }
}

public typealias MemberListResult = [Member]

public struct MemberUpdateParams: Codable, Equatable, Sendable {
    public var roomID: ULID
    public var memberID: String
    public var displayName: String?
    public var roles: Set<MemberRole>?

    enum CodingKeys: String, CodingKey {
        case roles
        case roomID = "room_id"
        case memberID = "member_id"
        case displayName = "display_name"
    }

    public init(roomID: ULID, memberID: String, displayName: String? = nil, roles: Set<MemberRole>? = nil) {
        self.roomID = roomID
        self.memberID = memberID
        self.displayName = displayName
        self.roles = roles
    }
}

public struct MemberResult: Codable, Equatable, Sendable {
    public var member: Member

    public init(member: Member) { self.member = member }
}

public struct MemberRemoveParams: Codable, Equatable, Sendable {
    public var roomID: ULID
    public var memberID: String

    enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case memberID = "member_id"
    }

    public init(roomID: ULID, memberID: String) {
        self.roomID = roomID
        self.memberID = memberID
    }
}

// MARK: - agent_session.* (§4.1.3)

public struct AgentSessionCreateParams: Codable, Equatable, Sendable {
    public var roomID: ULID
    public var workspaceID: ULID
    public var nodeID: ULID
    public var objective: String?

    enum CodingKeys: String, CodingKey {
        case objective
        case roomID = "room_id"
        case workspaceID = "workspace_id"
        case nodeID = "node_id"
    }

    public init(roomID: ULID, workspaceID: ULID, nodeID: ULID, objective: String? = nil) {
        self.roomID = roomID
        self.workspaceID = workspaceID
        self.nodeID = nodeID
        self.objective = objective
    }
}

public struct AgentSessionResult: Codable, Equatable, Sendable {
    public var agentSession: AgentSession

    enum CodingKeys: String, CodingKey {
        case agentSession = "agent_session"
    }

    public init(agentSession: AgentSession) { self.agentSession = agentSession }
}

public struct AgentSessionGetParams: Codable, Equatable, Sendable {
    public var agentSessionID: ULID

    enum CodingKeys: String, CodingKey {
        case agentSessionID = "agent_session_id"
    }

    public init(agentSessionID: ULID) { self.agentSessionID = agentSessionID }
}

public struct AgentSessionListParams: Codable, Equatable, Sendable {
    public var roomID: ULID
    public var state: AgentSessionState?

    enum CodingKeys: String, CodingKey {
        case state
        case roomID = "room_id"
    }

    public init(roomID: ULID, state: AgentSessionState? = nil) {
        self.roomID = roomID
        self.state = state
    }
}

public typealias AgentSessionListResult = [AgentSession]

public struct AgentSessionUpdateParams: Codable, Equatable, Sendable {
    public var agentSessionID: ULID
    public var objective: String?
    public var state: AgentSessionState?
    public var conductorID: String?
    public var summary: String?

    enum CodingKeys: String, CodingKey {
        case objective, state, summary
        case agentSessionID = "agent_session_id"
        case conductorID = "conductor_id"
    }

    public init(
        agentSessionID: ULID,
        objective: String? = nil,
        state: AgentSessionState? = nil,
        conductorID: String? = nil,
        summary: String? = nil
    ) {
        self.agentSessionID = agentSessionID
        self.objective = objective
        self.state = state
        self.conductorID = conductorID
        self.summary = summary
    }
}

// MARK: - Fase 2 — handoff, transições, briefing

public struct AgentSessionHandoffRequestParams: Codable, Equatable, Sendable {
    public var agentSessionID: ULID
    public var toMemberID: String
    public var scope: HandoffScope

    enum CodingKeys: String, CodingKey {
        case scope
        case agentSessionID = "agent_session_id"
        case toMemberID = "to_member_id"
    }

    public init(agentSessionID: ULID, toMemberID: String, scope: HandoffScope) {
        self.agentSessionID = agentSessionID
        self.toMemberID = toMemberID
        self.scope = scope
    }
}

public struct AgentSessionHandoffAcceptParams: Codable, Equatable, Sendable {
    public var agentSessionID: ULID

    enum CodingKeys: String, CodingKey {
        case agentSessionID = "agent_session_id"
    }

    public init(agentSessionID: ULID) { self.agentSessionID = agentSessionID }
}

public struct AgentSessionTransitionParams: Codable, Equatable, Sendable {
    public var agentSessionID: ULID
    public var state: AgentSessionState

    enum CodingKeys: String, CodingKey {
        case state
        case agentSessionID = "agent_session_id"
    }

    public init(agentSessionID: ULID, state: AgentSessionState) {
        self.agentSessionID = agentSessionID
        self.state = state
    }
}

public struct AgentSessionBriefingParams: Codable, Equatable, Sendable {
    public var agentSessionID: ULID

    enum CodingKeys: String, CodingKey {
        case agentSessionID = "agent_session_id"
    }

    public init(agentSessionID: ULID) { self.agentSessionID = agentSessionID }
}

public struct AgentSessionBriefingResult: Codable, Equatable, Sendable {
    public var briefing: String

    public init(briefing: String) { self.briefing = briefing }
}

// MARK: - session_event.* (§4.1.4)

public struct SessionEventAppendParams: Codable, Equatable, Sendable {
    public var roomID: ULID
    public var sessionID: ULID
    public var kind: CollaborativeEventKind
    public var payload: CollaborativeEventPayload
    /// Chave de deduplicação (§6.2). Reenvio do mesmo ID devolve o mesmo ack.
    public var eventID: ULID?

    enum CodingKeys: String, CodingKey {
        case kind, payload
        case roomID = "room_id"
        case sessionID = "session_id"
        case eventID = "event_id"
    }

    public init(
        roomID: ULID, sessionID: ULID,
        kind: CollaborativeEventKind,
        payload: CollaborativeEventPayload,
        eventID: ULID? = nil
    ) {
        self.roomID = roomID
        self.sessionID = sessionID
        self.kind = kind
        self.payload = payload
        self.eventID = eventID
    }
}

public struct SessionEventAppendResult: Codable, Equatable, Sendable {
    public var event: CollaborativeSessionEvent
    public var roomSeq: UInt64

    enum CodingKeys: String, CodingKey {
        case event
        case roomSeq = "room_seq"
    }

    public init(event: CollaborativeSessionEvent, roomSeq: UInt64) {
        self.event = event
        self.roomSeq = roomSeq
    }
}

// MARK: - grant.* (§4.1.5)

public struct GrantIssueParams: Codable, Equatable, Sendable {
    public var roomID: ULID
    public var subjectID: String
    public var resource: String
    public var actions: Set<CapabilityAction>
    public var expiresAt: Date?
    public var contextHash: String?

    enum CodingKeys: String, CodingKey {
        case resource, actions
        case roomID = "room_id"
        case subjectID = "subject_id"
        case expiresAt = "expires_at"
        case contextHash = "context_hash"
    }

    public init(
        roomID: ULID, subjectID: String, resource: String,
        actions: Set<CapabilityAction>,
        expiresAt: Date? = nil, contextHash: String? = nil
    ) {
        self.roomID = roomID
        self.subjectID = subjectID
        self.resource = resource
        self.actions = actions
        self.expiresAt = expiresAt
        self.contextHash = contextHash
    }
}

public struct GrantResult: Codable, Equatable, Sendable {
    public var grant: CapabilityGrant

    public init(grant: CapabilityGrant) { self.grant = grant }
}

public struct GrantRevokeParams: Codable, Equatable, Sendable {
    public var grantID: ULID

    enum CodingKeys: String, CodingKey {
        case grantID = "grant_id"
    }

    public init(grantID: ULID) { self.grantID = grantID }
}

public struct GrantListParams: Codable, Equatable, Sendable {
    public var roomID: ULID
    public var subjectID: String?
    public var activeOnly: Bool?

    enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case subjectID = "subject_id"
        case activeOnly = "active_only"
    }

    public init(roomID: ULID, subjectID: String? = nil, activeOnly: Bool? = nil) {
        self.roomID = roomID
        self.subjectID = subjectID
        self.activeOnly = activeOnly
    }
}

public typealias GrantListResult = [CapabilityGrant]

// MARK: - presence (§4.1.6)

public struct PresenceUpdateParams: Codable, Equatable, Sendable {
    public var roomID: ULID
    public var viewport: Viewport?
    public var cursor: Ponto?
    public var selectedNodeID: ULID?
    public var viewingSessionID: ULID?

    enum CodingKeys: String, CodingKey {
        case viewport, cursor
        case roomID = "room_id"
        case selectedNodeID = "selected_node_id"
        case viewingSessionID = "viewing_session_id"
    }

    public init(
        roomID: ULID,
        viewport: Viewport? = nil,
        cursor: Ponto? = nil,
        selectedNodeID: ULID? = nil,
        viewingSessionID: ULID? = nil
    ) {
        self.roomID = roomID
        self.viewport = viewport
        self.cursor = cursor
        self.selectedNodeID = selectedNodeID
        self.viewingSessionID = viewingSessionID
    }
}

// MARK: - lease.* (§6.1)

public struct LeaseAcquireParams: Codable, Equatable, Sendable {
    public var roomID: ULID
    public var sessionID: ULID
    /// `conductor` ou `executor`.
    public var scope: HandoffScope

    enum CodingKeys: String, CodingKey {
        case scope
        case roomID = "room_id"
        case sessionID = "session_id"
    }

    public init(roomID: ULID, sessionID: ULID, scope: HandoffScope) {
        self.roomID = roomID
        self.sessionID = sessionID
        self.scope = scope
    }
}

public struct LeaseResult: Codable, Equatable, Sendable {
    public var leaseID: ULID
    public var sessionID: ULID
    public var scope: HandoffScope
    public var expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case scope
        case leaseID = "lease_id"
        case sessionID = "session_id"
        case expiresAt = "expires_at"
    }

    public init(leaseID: ULID, sessionID: ULID, scope: HandoffScope, expiresAt: Date) {
        self.leaseID = leaseID
        self.sessionID = sessionID
        self.scope = scope
        self.expiresAt = expiresAt
    }
}

public struct LeaseReleaseParams: Codable, Equatable, Sendable {
    public var leaseID: ULID

    enum CodingKeys: String, CodingKey {
        case leaseID = "lease_id"
    }

    public init(leaseID: ULID) { self.leaseID = leaseID }
}

// MARK: - mission.* / workstream.* / decision.* / relation.* (§5.2–5.8)

public struct MissionCreateParams: Codable, Equatable, Sendable {
    public var roomID: ULID
    public var title: String
    public var context: String?
    public var definitionOfDone: String
    public var ownerID: String?

    enum CodingKeys: String, CodingKey {
        case title, context
        case roomID = "room_id"
        case definitionOfDone = "definition_of_done"
        case ownerID = "owner_id"
    }

    public init(
        roomID: ULID, title: String, context: String? = nil,
        definitionOfDone: String, ownerID: String? = nil
    ) {
        self.roomID = roomID
        self.title = title
        self.context = context
        self.definitionOfDone = definitionOfDone
        self.ownerID = ownerID
    }
}

public struct MissionResult: Codable, Equatable, Sendable {
    public var mission: Mission
    public init(mission: Mission) { self.mission = mission }
}

public struct MissionGetParams: Codable, Equatable, Sendable {
    public var roomID: ULID
    public var missionID: ULID
    enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case missionID = "mission_id"
    }
    public init(roomID: ULID, missionID: ULID) {
        self.roomID = roomID
        self.missionID = missionID
    }
}

public struct MissionListParams: Codable, Equatable, Sendable {
    public var roomID: ULID
    public var state: MissionState?
    enum CodingKeys: String, CodingKey {
        case state
        case roomID = "room_id"
    }
    public init(roomID: ULID, state: MissionState? = nil) {
        self.roomID = roomID
        self.state = state
    }
}

public typealias MissionListResult = [Mission]

public struct MissionUpdateParams: Codable, Equatable, Sendable {
    public var roomID: ULID
    public var missionID: ULID
    public var title: String?
    public var context: String?
    public var definitionOfDone: String?
    public var ownerID: String?
    enum CodingKeys: String, CodingKey {
        case title, context
        case roomID = "room_id"
        case missionID = "mission_id"
        case definitionOfDone = "definition_of_done"
        case ownerID = "owner_id"
    }
    public init(
        roomID: ULID, missionID: ULID, title: String? = nil,
        context: String? = nil, definitionOfDone: String? = nil, ownerID: String? = nil
    ) {
        self.roomID = roomID
        self.missionID = missionID
        self.title = title
        self.context = context
        self.definitionOfDone = definitionOfDone
        self.ownerID = ownerID
    }
}

public struct MissionTransitionParams: Codable, Equatable, Sendable {
    public var roomID: ULID
    public var missionID: ULID
    public var state: MissionState
    public var reason: String?
    enum CodingKeys: String, CodingKey {
        case state, reason
        case roomID = "room_id"
        case missionID = "mission_id"
    }
    public init(roomID: ULID, missionID: ULID, state: MissionState, reason: String? = nil) {
        self.roomID = roomID
        self.missionID = missionID
        self.state = state
        self.reason = reason
    }
}

public struct WorkstreamCreateParams: Codable, Equatable, Sendable {
    public var roomID: ULID
    public var missionID: ULID
    public var title: String
    public var objective: String
    public var definitionOfDone: String
    public var assignee: WorkstreamAssignee?
    public var dependsOn: [ULID]?
    enum CodingKeys: String, CodingKey {
        case title, objective, assignee
        case roomID = "room_id"
        case missionID = "mission_id"
        case definitionOfDone = "definition_of_done"
        case dependsOn = "depends_on"
    }
    public init(
        roomID: ULID, missionID: ULID, title: String, objective: String,
        definitionOfDone: String, assignee: WorkstreamAssignee? = nil, dependsOn: [ULID]? = nil
    ) {
        self.roomID = roomID
        self.missionID = missionID
        self.title = title
        self.objective = objective
        self.definitionOfDone = definitionOfDone
        self.assignee = assignee
        self.dependsOn = dependsOn
    }
}

public struct WorkstreamResult: Codable, Equatable, Sendable {
    public var workstream: Workstream
    public init(workstream: Workstream) { self.workstream = workstream }
}

public struct WorkstreamGetParams: Codable, Equatable, Sendable {
    public var roomID: ULID
    public var workstreamID: ULID
    enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case workstreamID = "workstream_id"
    }
    public init(roomID: ULID, workstreamID: ULID) {
        self.roomID = roomID
        self.workstreamID = workstreamID
    }
}

public struct WorkstreamListParams: Codable, Equatable, Sendable {
    public var roomID: ULID
    public var missionID: ULID?
    public var state: WorkstreamState?
    enum CodingKeys: String, CodingKey {
        case state
        case roomID = "room_id"
        case missionID = "mission_id"
    }
    public init(roomID: ULID, missionID: ULID? = nil, state: WorkstreamState? = nil) {
        self.roomID = roomID
        self.missionID = missionID
        self.state = state
    }
}

public typealias WorkstreamListResult = [Workstream]

public struct WorkstreamUpdateParams: Codable, Equatable, Sendable {
    public var roomID: ULID
    public var workstreamID: ULID
    public var title: String?
    public var objective: String?
    public var definitionOfDone: String?
    public var assignee: WorkstreamAssignee?
    public var clearAssignee: Bool?
    public var dependsOn: [ULID]?
    public var blockedBy: [WorkstreamBlocker]?
    enum CodingKeys: String, CodingKey {
        case title, objective, assignee
        case roomID = "room_id"
        case workstreamID = "workstream_id"
        case definitionOfDone = "definition_of_done"
        case clearAssignee = "clear_assignee"
        case dependsOn = "depends_on"
        case blockedBy = "blocked_by"
    }
    public init(
        roomID: ULID, workstreamID: ULID, title: String? = nil, objective: String? = nil,
        definitionOfDone: String? = nil, assignee: WorkstreamAssignee? = nil,
        clearAssignee: Bool? = nil, dependsOn: [ULID]? = nil, blockedBy: [WorkstreamBlocker]? = nil
    ) {
        self.roomID = roomID
        self.workstreamID = workstreamID
        self.title = title
        self.objective = objective
        self.definitionOfDone = definitionOfDone
        self.assignee = assignee
        self.clearAssignee = clearAssignee
        self.dependsOn = dependsOn
        self.blockedBy = blockedBy
    }
}

public struct WorkstreamTransitionParams: Codable, Equatable, Sendable {
    public var roomID: ULID
    public var workstreamID: ULID
    public var state: WorkstreamState
    enum CodingKeys: String, CodingKey {
        case state
        case roomID = "room_id"
        case workstreamID = "workstream_id"
    }
    public init(roomID: ULID, workstreamID: ULID, state: WorkstreamState) {
        self.roomID = roomID
        self.workstreamID = workstreamID
        self.state = state
    }
}

public struct WorkstreamBriefingParams: Codable, Equatable, Sendable {
    public var roomID: ULID
    public var workstreamID: ULID
    public var agentName: String
    public var agentRole: String?
    public var capabilities: [String]?
    public var allowedArtifacts: [String]?
    enum CodingKeys: String, CodingKey {
        case capabilities
        case roomID = "room_id"
        case workstreamID = "workstream_id"
        case agentName = "agent_name"
        case agentRole = "agent_role"
        case allowedArtifacts = "allowed_artifacts"
    }
    public init(
        roomID: ULID, workstreamID: ULID, agentName: String, agentRole: String? = nil,
        capabilities: [String]? = nil, allowedArtifacts: [String]? = nil
    ) {
        self.roomID = roomID
        self.workstreamID = workstreamID
        self.agentName = agentName
        self.agentRole = agentRole
        self.capabilities = capabilities
        self.allowedArtifacts = allowedArtifacts
    }
}

public struct WorkstreamBriefingResult: Codable, Equatable, Sendable {
    public var briefing: String
    public init(briefing: String) { self.briefing = briefing }
}

public struct DecisionCreateParams: Codable, Equatable, Sendable {
    public var roomID: ULID
    public var missionID: ULID
    public var workstreamID: ULID?
    public var question: String
    public var options: [DecisionOption]?
    public var dueAt: Date?
    enum CodingKeys: String, CodingKey {
        case question, options
        case roomID = "room_id"
        case missionID = "mission_id"
        case workstreamID = "workstream_id"
        case dueAt = "due_at"
    }
    public init(
        roomID: ULID, missionID: ULID, workstreamID: ULID? = nil,
        question: String, options: [DecisionOption]? = nil, dueAt: Date? = nil
    ) {
        self.roomID = roomID
        self.missionID = missionID
        self.workstreamID = workstreamID
        self.question = question
        self.options = options
        self.dueAt = dueAt
    }
}

public struct DecisionResult: Codable, Equatable, Sendable {
    public var decision: Decision
    public init(decision: Decision) { self.decision = decision }
}

public struct DecisionGetParams: Codable, Equatable, Sendable {
    public var roomID: ULID
    public var decisionID: ULID
    enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case decisionID = "decision_id"
    }
    public init(roomID: ULID, decisionID: ULID) {
        self.roomID = roomID
        self.decisionID = decisionID
    }
}

public struct DecisionListParams: Codable, Equatable, Sendable {
    public var roomID: ULID
    public var missionID: ULID?
    public var state: DecisionState?
    enum CodingKeys: String, CodingKey {
        case state
        case roomID = "room_id"
        case missionID = "mission_id"
    }
    public init(roomID: ULID, missionID: ULID? = nil, state: DecisionState? = nil) {
        self.roomID = roomID
        self.missionID = missionID
        self.state = state
    }
}

public typealias DecisionListResult = [Decision]

public struct DecisionDecideParams: Codable, Equatable, Sendable {
    public var roomID: ULID
    public var decisionID: ULID
    public var decision: String
    public var rationale: String?
    public var deciderID: String?
    enum CodingKeys: String, CodingKey {
        case decision, rationale
        case roomID = "room_id"
        case decisionID = "decision_id"
        case deciderID = "decider_id"
    }
    public init(
        roomID: ULID, decisionID: ULID, decision: String,
        rationale: String? = nil, deciderID: String? = nil
    ) {
        self.roomID = roomID
        self.decisionID = decisionID
        self.decision = decision
        self.rationale = rationale
        self.deciderID = deciderID
    }
}

public struct DecisionIDParams: Codable, Equatable, Sendable {
    public var roomID: ULID
    public var decisionID: ULID
    enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case decisionID = "decision_id"
    }
    public init(roomID: ULID, decisionID: ULID) {
        self.roomID = roomID
        self.decisionID = decisionID
    }
}

public struct RelationAddParams: Codable, Equatable, Sendable {
    public var roomID: ULID
    public var fromID: ULID
    public var toID: ULID
    public var kind: RelationKind
    public var labelPosition: Ponto?
    enum CodingKeys: String, CodingKey {
        case kind
        case roomID = "room_id"
        case fromID = "from_id"
        case toID = "to_id"
        case labelPosition = "label_position"
    }
    public init(
        roomID: ULID, fromID: ULID, toID: ULID, kind: RelationKind, labelPosition: Ponto? = nil
    ) {
        self.roomID = roomID
        self.fromID = fromID
        self.toID = toID
        self.kind = kind
        self.labelPosition = labelPosition
    }
}

public struct RelationResult: Codable, Equatable, Sendable {
    public var relation: Relation
    public init(relation: Relation) { self.relation = relation }
}

public struct RelationListParams: Codable, Equatable, Sendable {
    public var roomID: ULID
    public var kind: RelationKind?
    enum CodingKeys: String, CodingKey {
        case kind
        case roomID = "room_id"
    }
    public init(roomID: ULID, kind: RelationKind? = nil) {
        self.roomID = roomID
        self.kind = kind
    }
}

public typealias RelationListResult = [Relation]

public struct RelationRemoveParams: Codable, Equatable, Sendable {
    public var roomID: ULID
    public var relationID: ULID
    enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case relationID = "relation_id"
    }
    public init(roomID: ULID, relationID: ULID) {
        self.roomID = roomID
        self.relationID = relationID
    }
}
