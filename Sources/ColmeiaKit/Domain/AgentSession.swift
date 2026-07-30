import Foundation

/// §4.2 — estado colaborativo da AgentSession, independente
/// de `SessionEstado` do PTY, mas a UI DEVE exibir ambos quando o Worker
/// estiver online.
public enum AgentSessionState: String, Codable, CaseIterable, Sendable {
    case draft
    case ready
    case running
    case waitingForDirection = "waiting_for_direction"
    case waitingForApproval = "waiting_for_approval"
    case handoffPending = "handoff_pending"
    case paused
    case completed
    case failed
    case archived

    /// Uma sessão não pode sair de `archived`; reabrir cria uma nova sessão.
    public var isArchived: Bool {
        self == .archived
    }

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .archived: return true
        default: return false
        }
    }
}

/// §4.1.3 — extensão colaborativa da `Session` local.
/// Referencia a sessão PTY quando há Worker ativo, mas sobrevive ao
/// processo e à conexão.
public struct AgentSession: Codable, Equatable, Sendable {
    public var id: ULID
    public var roomID: ULID
    public var workspaceID: ULID
    public var nodeID: ULID
    /// Objetivo humano legível da sessão.
    public var objective: String?
    /// Estado colaborativo (§4.2).
    public var state: AgentSessionState
    /// Membro/Worker com lease de execução, ou `nil`.
    public var executorID: String?
    /// Pessoa cuja direção pode chegar ao agente automaticamente.
    public var conductorID: String?
    /// Pedido de transferência pendente, se houver.
    public var handoff: AgentSessionHandoff?
    /// Resumo revisável, nunca cadeia de pensamento privada.
    public var summary: String?
    public var lastActivityAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, objective, state, handoff, summary
        case roomID = "room_id"
        case workspaceID = "workspace_id"
        case nodeID = "node_id"
        case executorID = "executor_id"
        case conductorID = "conductor_id"
        case lastActivityAt = "last_activity_at"
    }

    public init(
        id: ULID,
        roomID: ULID,
        workspaceID: ULID,
        nodeID: ULID,
        objective: String? = nil,
        state: AgentSessionState = .draft,
        executorID: String? = nil,
        conductorID: String? = nil,
        handoff: AgentSessionHandoff? = nil,
        summary: String? = nil,
        lastActivityAt: Date? = nil
    ) {
        self.id = id
        self.roomID = roomID
        self.workspaceID = workspaceID
        self.nodeID = nodeID
        self.objective = objective
        self.state = state
        self.executorID = executorID
        self.conductorID = conductorID
        self.handoff = handoff
        self.summary = summary
        self.lastActivityAt = lastActivityAt
    }
}

/// §5.2 — pedido de transferência de condutor ou executor.
public struct AgentSessionHandoff: Codable, Equatable, Sendable {
    public var fromMemberID: String
    public var toMemberID: String
    /// `conductor`, `executor` ou ambos.
    public var scope: HandoffScope
    public var requestedAt: Date
    public var message: String?

    enum CodingKeys: String, CodingKey {
        case scope, message
        case fromMemberID = "from_member_id"
        case toMemberID = "to_member_id"
        case requestedAt = "requested_at"
    }

    public init(
        fromMemberID: String,
        toMemberID: String,
        scope: HandoffScope,
        requestedAt: Date,
        message: String? = nil
    ) {
        self.fromMemberID = fromMemberID
        self.toMemberID = toMemberID
        self.scope = scope
        self.requestedAt = requestedAt
        self.message = message
    }
}

public enum HandoffScope: String, Codable, CaseIterable, Sendable {
    case conductor
    case executor
    case both
}
