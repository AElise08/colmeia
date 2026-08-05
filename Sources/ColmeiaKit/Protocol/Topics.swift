import Foundation

/// Tópicos de evento (§6.5). `session.output` só flui para clientes com
/// `session.attach` naquela sessão; os demais, para assinantes do workspace.
public enum ColmeiaTopic: String, Codable, CaseIterable, Sendable {
    case sessionOutput = "session.output"
    case sessionState = "session.state"
    case documentOp = "document.op"
    case approvalCreated = "approval.created"
    case approvalResolved = "approval.resolved"
    case messageDelivered = "message.delivered"
    case noteAppended = "note.appended"
    case routineFired = "routine.fired"
    case floorChanged = "floor.changed"
    case memoryChanged = "memory.changed"
    case deliveryChanged = "delivery.changed"
    case missionChanged = "mission.changed"
    case workstreamChanged = "workstream.changed"
    case decisionChanged = "decision.changed"
    case watchdogAlert = "watchdog.alert"
    case workerArchived = "worker.archived"
    case engineWarning = "engine.warning"
    // Control plane visual — atividade auditável, sem conteúdo de prompt/output.
    case telemetrySample = "telemetry.sample"
    case telemetryActivity = "telemetry.activity"
    case telemetryAggregateChanged = "telemetry.aggregate.changed"
    case telemetryBudgetAlert = "telemetry.budget.alert"
    case connectionActivity = "connection.activity"
    case fileActivity = "file.activity"
    case portalActivity = "portal.activity"
    case deployStateChanged = "deploy.state.changed"
    // Multiplayer (§6.1)
    case roomUpdated = "room.updated"
    case roomLayoutChanged = "room.layout.changed"
    case memberJoined = "member.joined"
    case memberLeft = "member.left"
    case memberUpdated = "member.updated"
    case sessionEventAppended = "session_event.appended"
    case eventAck = "event.ack"
    case eventReject = "event.reject"
    case grantIssued = "grant.issued"
    case grantRevoked = "grant.revoked"
    case presenceChanged = "presence.changed"
    case leaseAcquired = "lease.acquired"
    case leaseRevoked = "lease.revoked"
    case handoffRequested = "handoff.requested"
    case handoffAccepted = "handoff.accepted"
    case conductorChanged = "conductor.changed"

    /// Payload novo não é enviado a engines antigos: SubscribeParams usa um
    /// enum fechado no wire e um cliente novo precisa manter compatibilidade.
    public static var legacyCompatibleCases: [ColmeiaTopic] {
        let additions: Set<ColmeiaTopic> = [
            .telemetrySample, .telemetryActivity, .telemetryAggregateChanged,
            .telemetryBudgetAlert, .connectionActivity, .fileActivity, .portalActivity,
            .deployStateChanged
        ]
        return allCases.filter { !additions.contains($0) }
    }
}

public struct SessionOutputTopicPayload: Codable, Equatable, Sendable {
    public var sessionID: ULID
    public var seq: UInt64
    public var dataB64: String

    enum CodingKeys: String, CodingKey {
        case seq
        case sessionID = "session_id"
        case dataB64 = "data_b64"
    }

    public init(sessionID: ULID, seq: UInt64, dataB64: String) {
        self.sessionID = sessionID
        self.seq = seq
        self.dataB64 = dataB64
    }
}

public struct SessionStateTopicPayload: Codable, Equatable, Sendable {
    public var sessionID: ULID
    public var estado: SessionEstado
    public var motivo: String?
    public var nodeID: ULID?
    public var workspaceID: ULID?

    enum CodingKeys: String, CodingKey {
        case estado, motivo
        case sessionID = "session_id"
        case nodeID = "node_id"
        case workspaceID = "workspace_id"
    }

    public init(
        sessionID: ULID,
        estado: SessionEstado,
        motivo: String? = nil,
        nodeID: ULID? = nil,
        workspaceID: ULID? = nil
    ) {
        self.sessionID = sessionID
        self.estado = estado
        self.motivo = motivo
        self.nodeID = nodeID
        self.workspaceID = workspaceID
    }
}

/// O eco da própria op confirma persistência (§6.5).
public struct DocumentOpTopicPayload: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public var op: DocOp
    public var seq: UInt64

    enum CodingKeys: String, CodingKey {
        case op, seq
        case workspaceID = "workspace_id"
    }

    public init(workspaceID: ULID, op: DocOp, seq: UInt64) {
        self.workspaceID = workspaceID
        self.op = op
        self.seq = seq
    }
}

/// Usado por `approval.created` e `approval.resolved`.
public struct ApprovalTopicPayload: Codable, Equatable, Sendable {
    public var approval: Approval

    public init(approval: Approval) {
        self.approval = approval
    }
}

public struct MessageDeliveredTopicPayload: Codable, Equatable, Sendable {
    public var de: ULID
    public var para: ULID
    public var texto: String
    public var messageID: ULID

    enum CodingKeys: String, CodingKey {
        case de, para, texto
        case messageID = "message_id"
    }

    public init(de: ULID, para: ULID, texto: String, messageID: ULID) {
        self.de = de
        self.para = para
        self.texto = texto
        self.messageID = messageID
    }
}

public struct TelemetrySampleTopicPayload: Codable, Equatable, Sendable {
    public var sample: UsageSample

    public init(sample: UsageSample) { self.sample = sample }
}

public struct TelemetryAggregateChangedTopicPayload: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public var snapshot: TelemetrySnapshot

    enum CodingKeys: String, CodingKey {
        case snapshot
        case workspaceID = "workspace_id"
    }

    public init(workspaceID: ULID, snapshot: TelemetrySnapshot) {
        self.workspaceID = workspaceID
        self.snapshot = snapshot
    }
}

public struct TelemetryBudgetAlertTopicPayload: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public var threshold: Double
    public var percent: Double

    enum CodingKeys: String, CodingKey {
        case threshold, percent
        case workspaceID = "workspace_id"
    }

    public init(workspaceID: ULID, threshold: Double, percent: Double) {
        self.workspaceID = workspaceID
        self.threshold = threshold
        self.percent = percent
    }
}

public struct ConnectionActivityTopicPayload: Codable, Equatable, Sendable {
    public var event: ConnectionActivityEvent

    public init(event: ConnectionActivityEvent) { self.event = event }
}

public struct FileActivityTopicPayload: Codable, Equatable, Sendable {
    public var event: FileActivityEvent

    public init(event: FileActivityEvent) { self.event = event }
}

public struct PortalActivityTopicPayload: Codable, Equatable, Sendable {
    public var event: PortalActivityEvent

    public init(event: PortalActivityEvent) { self.event = event }
}

public struct DeployStateChangedTopicPayload: Codable, Equatable, Sendable {
    public var request: DeployRequest
    public init(request: DeployRequest) { self.request = request }
}

public struct NoteAppendedTopicPayload: Codable, Equatable, Sendable {
    public var nodeID: ULID
    public var fonte: Author
    public var resumo: String
    public var conteudo: String?

    enum CodingKeys: String, CodingKey {
        case fonte, resumo, conteudo
        case nodeID = "node_id"
    }

    public init(nodeID: ULID, fonte: Author, resumo: String, conteudo: String? = nil) {
        self.nodeID = nodeID
        self.fonte = fonte
        self.resumo = resumo
        self.conteudo = conteudo
    }
}

public struct RoutineFiredTopicPayload: Codable, Equatable, Sendable {
    public var routineID: ULID
    public var resultado: RoutineResultado

    enum CodingKeys: String, CodingKey {
        case resultado
        case routineID = "routine_id"
    }

    public init(routineID: ULID, resultado: RoutineResultado) {
        self.routineID = routineID
        self.resultado = resultado
    }
}

/// Criação/aterrissagem/descarte/orfandade (§6.5).
public struct FloorChangedTopicPayload: Codable, Equatable, Sendable {
    public var floor: Floor

    public init(floor: Floor) {
        self.floor = floor
    }
}

/// Mudança de memória curada e/ou de sua fila de propostas; conteúdo técnico de
/// journal não é publicado neste tópico.
public struct MemoryChangedTopicPayload: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public var memory: WorkspaceMemory?
    public var proposal: MemoryProposal?

    enum CodingKeys: String, CodingKey {
        case memory, proposal
        case workspaceID = "workspace_id"
    }

    public init(workspaceID: ULID, memory: WorkspaceMemory? = nil, proposal: MemoryProposal? = nil) {
        self.workspaceID = workspaceID
        self.memory = memory
        self.proposal = proposal
    }
}

/// Mudanças semânticas da Sala. O payload completo permite que clientes
/// atualizem o agregado sem buscar uma segunda fonte e mantém `change` apenas
/// como pista de apresentação/auditoria.
public struct MissionChangedTopicPayload: Codable, Equatable, Sendable {
    public var roomID: ULID
    public var mission: Mission
    public var change: String

    enum CodingKeys: String, CodingKey {
        case mission, change
        case roomID = "room_id"
    }

    public init(roomID: ULID, mission: Mission, change: String = "updated") {
        self.roomID = roomID
        self.mission = mission
        self.change = change
    }
}

public struct WorkstreamChangedTopicPayload: Codable, Equatable, Sendable {
    public var roomID: ULID
    public var workstream: Workstream
    public var change: String

    enum CodingKeys: String, CodingKey {
        case workstream, change
        case roomID = "room_id"
    }

    public init(roomID: ULID, workstream: Workstream, change: String = "updated") {
        self.roomID = roomID
        self.workstream = workstream
        self.change = change
    }
}

public struct DecisionChangedTopicPayload: Codable, Equatable, Sendable {
    public var roomID: ULID
    public var decision: Decision
    public var change: String

    enum CodingKeys: String, CodingKey {
        case decision, change
        case roomID = "room_id"
    }

    public init(roomID: ULID, decision: Decision, change: String = "updated") {
        self.roomID = roomID
        self.decision = decision
        self.change = change
    }
}

public struct DeliveryChangedTopicPayload: Codable, Equatable, Sendable {
    public var delivery: Delivery

    public init(delivery: Delivery) { self.delivery = delivery }
}

/// Alerta puramente observável: não pede, cria, mata ou arquiva worker.
public struct WatchdogAlertTopicPayload: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public var sessionID: ULID
    public var kind: String
    public var episode: Int
    public var message: String

    enum CodingKeys: String, CodingKey {
        case kind, episode, message
        case workspaceID = "workspace_id"
        case sessionID = "session_id"
    }

    public init(workspaceID: ULID, sessionID: ULID, kind: String, episode: Int, message: String) {
        self.workspaceID = workspaceID
        self.sessionID = sessionID
        self.kind = kind
        self.episode = episode
        self.message = message
    }
}

public struct WorkerArchivedTopicPayload: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public var tombstone: WorkerArchiveTombstone

    enum CodingKeys: String, CodingKey {
        case tombstone
        case workspaceID = "workspace_id"
    }

    public init(workspaceID: ULID, tombstone: WorkerArchiveTombstone) {
        self.workspaceID = workspaceID
        self.tombstone = tombstone
    }
}

/// Condições de §22 (ex.: aviso antes de desconectar cliente sem backpressure).
public struct EngineWarningTopicPayload: Codable, Equatable, Sendable {
    public var name: String
    public var message: String

    public init(name: String, message: String) {
        self.name = name
        self.message = message
    }
}

// MARK: - Multiplayer topic payloads

public struct RoomUpdatedTopicPayload: Codable, Equatable, Sendable {
    public var room: Room

    public init(room: Room) { self.room = room }
}

public struct RoomLayoutChangedTopicPayload: Codable, Equatable, Sendable {
    public var roomID: ULID
    public var objectID: ULID
    public var position: Ponto
    /// Snapshot pequeno do layout para clientes que perderam eventos durante
    /// uma reconexão; a posição individual continua sendo o delta principal.
    public var positions: [String: Ponto]

    enum CodingKeys: String, CodingKey {
        case position, positions
        case roomID = "room_id"
        case objectID = "object_id"
    }

    public init(roomID: ULID, objectID: ULID, position: Ponto, positions: [String: Ponto]) {
        self.roomID = roomID
        self.objectID = objectID
        self.position = position
        self.positions = positions
    }
}

public struct MemberJoinedTopicPayload: Codable, Equatable, Sendable {
    public var member: Member
    public var roomID: ULID?
    public var roomSeq: UInt64?

    enum CodingKeys: String, CodingKey {
        case member
        case roomID = "room_id"
        case roomSeq = "room_seq"
    }

    public init(member: Member, roomID: ULID? = nil, roomSeq: UInt64? = nil) {
        self.member = member
        self.roomID = roomID
        self.roomSeq = roomSeq
    }
}

public struct MemberLeftTopicPayload: Codable, Equatable, Sendable {
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

public struct MemberUpdatedTopicPayload: Codable, Equatable, Sendable {
    public var member: Member

    public init(member: Member) { self.member = member }
}

public struct SessionEventAppendedTopicPayload: Codable, Equatable, Sendable {
    public var event: CollaborativeSessionEvent

    public init(event: CollaborativeSessionEvent) { self.event = event }
}

public struct EventAckTopicPayload: Codable, Equatable, Sendable {
    public var eventID: ULID
    public var roomSeq: UInt64

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case roomSeq = "room_seq"
    }

    public init(eventID: ULID, roomSeq: UInt64) {
        self.eventID = eventID
        self.roomSeq = roomSeq
    }
}

public struct EventRejectTopicPayload: Codable, Equatable, Sendable {
    public var eventID: ULID
    public var error: String

    enum CodingKeys: String, CodingKey {
        case error
        case eventID = "event_id"
    }

    public init(eventID: ULID, error: String) {
        self.eventID = eventID
        self.error = error
    }
}

public struct GrantIssuedTopicPayload: Codable, Equatable, Sendable {
    public var grant: CapabilityGrant

    public init(grant: CapabilityGrant) { self.grant = grant }
}

public struct GrantRevokedTopicPayload: Codable, Equatable, Sendable {
    public var grantID: ULID

    enum CodingKeys: String, CodingKey {
        case grantID = "grant_id"
    }

    public init(grantID: ULID) { self.grantID = grantID }
}

public struct PresenceChangedTopicPayload: Codable, Equatable, Sendable {
    public var roomID: ULID
    public var memberID: String
    public var connected: Bool
    public var viewport: Viewport?
    public var cursor: Ponto?
    public var displayName: String?
    public var selectedNodeID: ULID?
    public var viewingSessionID: ULID?
    public var lastSeen: Date

    enum CodingKeys: String, CodingKey {
        case connected, viewport, cursor
        case displayName = "display_name"
        case roomID = "room_id"
        case memberID = "member_id"
        case selectedNodeID = "selected_node_id"
        case viewingSessionID = "viewing_session_id"
        case lastSeen = "last_seen"
    }

    public init(
        roomID: ULID, memberID: String,
        connected: Bool = true,
        viewport: Viewport? = nil,
        cursor: Ponto? = nil,
        displayName: String? = nil,
        selectedNodeID: ULID? = nil,
        viewingSessionID: ULID? = nil,
        lastSeen: Date
    ) {
        self.roomID = roomID
        self.memberID = memberID
        self.connected = connected
        self.viewport = viewport
        self.cursor = cursor
        self.displayName = displayName
        self.selectedNodeID = selectedNodeID
        self.viewingSessionID = viewingSessionID
        self.lastSeen = lastSeen
    }
}

public struct LeaseAcquiredTopicPayload: Codable, Equatable, Sendable {
    public var lease: LeaseResult

    public init(lease: LeaseResult) { self.lease = lease }
}

public struct LeaseRevokedTopicPayload: Codable, Equatable, Sendable {
    public var leaseID: ULID

    enum CodingKeys: String, CodingKey {
        case leaseID = "lease_id"
    }

    public init(leaseID: ULID) { self.leaseID = leaseID }
}

public struct HandoffRequestedTopicPayload: Codable, Equatable, Sendable {
    public var sessionID: ULID
    public var handoff: AgentSessionHandoff

    enum CodingKeys: String, CodingKey {
        case handoff
        case sessionID = "session_id"
    }

    public init(sessionID: ULID, handoff: AgentSessionHandoff) {
        self.sessionID = sessionID
        self.handoff = handoff
    }
}

public struct HandoffAcceptedTopicPayload: Codable, Equatable, Sendable {
    public var sessionID: ULID
    public var fromMemberID: String
    public var toMemberID: String
    public var scope: HandoffScope

    enum CodingKeys: String, CodingKey {
        case scope
        case sessionID = "session_id"
        case fromMemberID = "from_member_id"
        case toMemberID = "to_member_id"
    }

    public init(sessionID: ULID, fromMemberID: String, toMemberID: String, scope: HandoffScope) {
        self.sessionID = sessionID
        self.fromMemberID = fromMemberID
        self.toMemberID = toMemberID
        self.scope = scope
    }
}

public struct ConductorChangedTopicPayload: Codable, Equatable, Sendable {
    public var sessionID: ULID
    public var previousConductorID: String?
    public var newConductorID: String

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case previousConductorID = "previous_conductor_id"
        case newConductorID = "new_conductor_id"
    }

    public init(sessionID: ULID, previousConductorID: String?, newConductorID: String) {
        self.sessionID = sessionID
        self.previousConductorID = previousConductorID
        self.newConductorID = newConductorID
    }
}
