import Foundation

/// §4.1.4 — registro append-only que representa uma intenção
/// ou fato compartilhável na thread colaborativa. Diferente do `Event` local
/// que é unidade de journal PTY — este é o evento compartilhado na sala.
public enum CollaborativeEventKind: String, Codable, CaseIterable, Sendable {
    case messageSent = "message_sent"
    case directionProposed = "direction_proposed"
    case directionApplied = "direction_applied"
    case planProposed = "plan_proposed"
    case planAccepted = "plan_accepted"
    case decisionRecorded = "decision_recorded"
    case handoffRequested = "handoff_requested"
    case handoffAccepted = "handoff_accepted"
    case conductorChanged = "conductor_changed"
    case approvalRequested = "approval_requested"
    case approvalResolved = "approval_resolved"
    case executionStarted = "execution_started"
    case executionProgressed = "execution_progressed"
    case executionFinished = "execution_finished"
    case artifactPublished = "artifact_published"
    case deliverySubmitted = "delivery_submitted"
    case deliveryReviewed = "delivery_reviewed"
    case summaryUpdated = "session_summary_updated"
    case stateChanged = "session_state_changed"
}

/// Payload de um CollaborativeSessionEvent. O conteúdo concreto varia
/// por `kind` e é validado pelo Hub (§4.1.4); campos desconhecidos
/// DEVEM ser ignorados para forward compatibility.
public struct CollaborativeEventPayload: Codable, Equatable, Sendable {
    public var texto: String?
    /// Direção ou plano proposto.
    public var direction: String?
    /// Referência ao job de execução.
    public var executionJobID: String?
    /// Artefato ou entrega referenciada.
    public var artifactID: ULID?
    public var deliveryID: ULID?
    /// Estado anterior/próximo da sessão.
    public var previousState: AgentSessionState?
    public var newState: AgentSessionState?
    /// Handoff — membro origem/destino.
    public var fromMemberID: String?
    public var toMemberID: String?
    /// Decisão tomada.
    public var decision: String?
    /// Resumo atualizado.
    public var summary: String?

    enum CodingKeys: String, CodingKey {
        case texto, direction, decision, summary
        case executionJobID = "execution_job_id"
        case artifactID = "artifact_id"
        case deliveryID = "delivery_id"
        case previousState = "previous_state"
        case newState = "new_state"
        case fromMemberID = "from_member_id"
        case toMemberID = "to_member_id"
    }

    public init(
        texto: String? = nil,
        direction: String? = nil,
        executionJobID: String? = nil,
        artifactID: ULID? = nil,
        deliveryID: ULID? = nil,
        previousState: AgentSessionState? = nil,
        newState: AgentSessionState? = nil,
        fromMemberID: String? = nil,
        toMemberID: String? = nil,
        decision: String? = nil,
        summary: String? = nil
    ) {
        self.texto = texto
        self.direction = direction
        self.executionJobID = executionJobID
        self.artifactID = artifactID
        self.deliveryID = deliveryID
        self.previousState = previousState
        self.newState = newState
        self.fromMemberID = fromMemberID
        self.toMemberID = toMemberID
        self.decision = decision
        self.summary = summary
    }
}

/// Evento colaborativo append-only — fonte de verdade da thread e das
/// projeções de sessão (§4.1.4).
public struct CollaborativeSessionEvent: Codable, Equatable, Sendable {
    public var id: ULID
    public var roomID: ULID
    public var sessionID: ULID
    public var author: Author
    public var kind: CollaborativeEventKind
    public var payload: CollaborativeEventPayload
    public var createdAt: Date
    /// Relógio lógico para ordem dentro da sala.
    public var logicalClock: UInt64
    /// Assinatura do autor (Fase 1+); presente mas opcional na Fase 0.
    public var signature: String?

    enum CodingKeys: String, CodingKey {
        case id, author, kind, payload, signature
        case roomID = "room_id"
        case sessionID = "session_id"
        case createdAt = "created_at"
        case logicalClock = "logical_clock"
    }

    public init(
        id: ULID,
        roomID: ULID,
        sessionID: ULID,
        author: Author,
        kind: CollaborativeEventKind,
        payload: CollaborativeEventPayload,
        createdAt: Date,
        logicalClock: UInt64,
        signature: String? = nil
    ) {
        self.id = id
        self.roomID = roomID
        self.sessionID = sessionID
        self.author = author
        self.kind = kind
        self.payload = payload
        self.createdAt = createdAt
        self.logicalClock = logicalClock
        self.signature = signature
    }
}
