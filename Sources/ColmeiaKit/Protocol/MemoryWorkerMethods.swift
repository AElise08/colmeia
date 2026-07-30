import Foundation

// MARK: - memory.*

public struct MemoryGetParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    enum CodingKeys: String, CodingKey { case workspaceID = "workspace_id" }
    public init(workspaceID: ULID) { self.workspaceID = workspaceID }
}

public struct MemoryGetResult: Codable, Equatable, Sendable {
    public var memory: WorkspaceMemory
    public var briefing: MemoryBriefing
    public init(memory: WorkspaceMemory, briefing: MemoryBriefing) { self.memory = memory; self.briefing = briefing }
}

public struct MemoryUpdateParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public var content: String
    enum CodingKeys: String, CodingKey { case content; case workspaceID = "workspace_id" }
    public init(workspaceID: ULID, content: String) { self.workspaceID = workspaceID; self.content = content }
}

public struct MemoryProposeParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public var proposalID: ULID?
    public var content: String
    enum CodingKeys: String, CodingKey { case content; case workspaceID = "workspace_id"; case proposalID = "proposal_id" }
    public init(workspaceID: ULID, proposalID: ULID? = nil, content: String) {
        self.workspaceID = workspaceID; self.proposalID = proposalID; self.content = content
    }
}

public struct MemoryProposalListParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public var status: MemoryProposalStatus?
    enum CodingKeys: String, CodingKey { case status; case workspaceID = "workspace_id" }
    public init(workspaceID: ULID, status: MemoryProposalStatus? = nil) { self.workspaceID = workspaceID; self.status = status }
}
public typealias MemoryProposalListResult = [MemoryProposal]

public struct MemoryProposalResolveParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public var proposalID: ULID
    /// Em accept, edita apenas a proposta selecionada; não substitui MEMORY.md.
    public var editedContent: String?
    public var note: String?
    enum CodingKeys: String, CodingKey {
        case note
        case workspaceID = "workspace_id"
        case proposalID = "proposal_id"
        case editedContent = "edited_content"
    }
    public init(workspaceID: ULID, proposalID: ULID, editedContent: String? = nil, note: String? = nil) {
        self.workspaceID = workspaceID; self.proposalID = proposalID; self.editedContent = editedContent; self.note = note
    }
}

public struct MemoryHistoryParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    enum CodingKeys: String, CodingKey { case workspaceID = "workspace_id" }
    public init(workspaceID: ULID) { self.workspaceID = workspaceID }
}
public typealias MemoryHistoryResult = [MemoryHistoryEntry]

// MARK: - delivery.*

public struct DeliverySubmitParams: Codable, Equatable, Sendable {
    public var submission: DeliverySubmission
    public init(submission: DeliverySubmission) { self.submission = submission }
}
public struct DeliveryResult: Codable, Equatable, Sendable {
    public var delivery: Delivery
    public init(delivery: Delivery) { self.delivery = delivery }
}
public struct DeliveryListParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public var estado: DeliveryEstado?
    enum CodingKeys: String, CodingKey {
        case estado
        case workspaceID = "workspace_id"
    }
    public init(workspaceID: ULID, estado: DeliveryEstado? = nil) {
        self.workspaceID = workspaceID
        self.estado = estado
    }
}
public typealias DeliveryListResult = [Delivery]
public struct DeliveryReviewParams: Codable, Equatable, Sendable {
    public var deliveryID: ULID
    enum CodingKeys: String, CodingKey { case deliveryID = "delivery_id" }
    public init(deliveryID: ULID) { self.deliveryID = deliveryID }
}

// MARK: - watchdog.*

public struct WatchdogGetParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    enum CodingKeys: String, CodingKey { case workspaceID = "workspace_id" }
    public init(workspaceID: ULID) { self.workspaceID = workspaceID }
}
public struct WatchdogGetResult: Codable, Equatable, Sendable {
    public var configuration: WorkerWatchdogConfiguration
    public var history: [WatchdogHistoryEntry]?
    public init(configuration: WorkerWatchdogConfiguration, history: [WatchdogHistoryEntry]? = nil) {
        self.configuration = configuration
        self.history = history
    }
}
public struct WatchdogHistoryEntry: Codable, Equatable, Sendable {
    public var sessionID: ULID
    public var message: String
    public var occurredAt: Date
    public var seq: UInt64
    enum CodingKeys: String, CodingKey {
        case message, seq
        case sessionID = "session_id"
        case occurredAt = "occurred_at"
    }
    public init(sessionID: ULID, message: String, occurredAt: Date, seq: UInt64) {
        self.sessionID = sessionID
        self.message = message
        self.occurredAt = occurredAt
        self.seq = seq
    }
}
public struct WatchdogUpdateParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public var configuration: WorkerWatchdogConfiguration
    enum CodingKeys: String, CodingKey { case configuration; case workspaceID = "workspace_id" }
    public init(workspaceID: ULID, configuration: WorkerWatchdogConfiguration) {
        self.workspaceID = workspaceID; self.configuration = configuration
    }
}

// MARK: - worker.*

public struct WorkerArchiveParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public var sessionID: ULID
    public var confirmar: Bool
    enum CodingKeys: String, CodingKey {
        case confirmar
        case workspaceID = "workspace_id"
        case sessionID = "session_id"
    }
    public init(workspaceID: ULID, sessionID: ULID, confirmar: Bool = false) {
        self.workspaceID = workspaceID; self.sessionID = sessionID; self.confirmar = confirmar
    }
}
public struct WorkerArchiveResult: Codable, Equatable, Sendable {
    public var tombstone: WorkerArchiveTombstone
    public init(tombstone: WorkerArchiveTombstone) { self.tombstone = tombstone }
}
public struct WorkerListParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    enum CodingKeys: String, CodingKey { case workspaceID = "workspace_id" }
    public init(workspaceID: ULID) { self.workspaceID = workspaceID }
}
public typealias WorkerListResult = [WorkerArchiveTombstone]
public struct WorkerRestoreParams: Codable, Equatable, Sendable {
    public var workspaceID: ULID
    public var archiveID: ULID
    enum CodingKeys: String, CodingKey { case workspaceID = "workspace_id"; case archiveID = "archive_id" }
    public init(workspaceID: ULID, archiveID: ULID) { self.workspaceID = workspaceID; self.archiveID = archiveID }
}
/// Restauração de arquivo só reexpõe o metadado e a referência ao journal para
/// replay; ela não recria processo nem inicia sessão.
public struct WorkerRestoreResult: Codable, Equatable, Sendable {
    public var session: Session
    public var journal: String?
    public init(session: Session, journal: String?) { self.session = session; self.journal = journal }
}
