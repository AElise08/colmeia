import Foundation

/// Operações distintas por design. Esta fundação não executa nenhuma delas.
public enum WorkerLifecycleAction: String, Codable, CaseIterable, Sendable {
    case terminate
    case archive
    case delete
}

public enum WorkerArchiveRefusal: String, Codable, Equatable, Sendable {
    case sessionStillLive = "session_still_live"
    case deliveryNotAccepted = "delivery_not_accepted"
    case automaticArchiveDisabled = "automatic_archive_disabled"
    case deletionNotImplemented = "deletion_not_implemented"
}

public enum WorkerArchiveInitiator: String, Codable, Equatable, Sendable {
    case automatic
    case human
}

/// Referências que devem continuar disponíveis no replay/auditoria após arquivar.
public struct WorkerArchiveEvidence: Codable, Equatable, Sendable {
    public var journal: String?
    public var deliveryIDs: [ULID]
    public var messageIDs: [ULID]
    public var approvalIDs: [ULID]
    public var relatedNodeIDs: [ULID]

    public init(
        journal: String?, deliveryIDs: [ULID] = [], messageIDs: [ULID] = [],
        approvalIDs: [ULID] = [], relatedNodeIDs: [ULID] = []
    ) {
        self.journal = journal
        self.deliveryIDs = deliveryIDs
        self.messageIDs = messageIDs
        self.approvalIDs = approvalIDs
        self.relatedNodeIDs = relatedNodeIDs
    }
}

/// Metadado/tombstone aditivo: não remove nem move journal, replay ou relações.
public struct WorkerArchiveTombstone: Codable, Equatable, Sendable {
    public var id: ULID
    public var session: Session
    public var evidence: WorkerArchiveEvidence
    public var archivedAt: Date
    public var deliveryAccepted: Bool
    public var humanConfirmed: Bool
    public var restoredAt: Date?

    public init(
        id: ULID = ULID.generate(), session: Session, evidence: WorkerArchiveEvidence,
        archivedAt: Date, deliveryAccepted: Bool, humanConfirmed: Bool, restoredAt: Date? = nil
    ) {
        self.id = id
        self.session = session
        self.evidence = evidence
        self.archivedAt = archivedAt
        self.deliveryAccepted = deliveryAccepted
        self.humanConfirmed = humanConfirmed
        self.restoredAt = restoredAt
    }
}

public enum WorkerArchiveDecision: Equatable, Sendable {
    case terminateOnly
    case archived(WorkerArchiveTombstone)
    case restoreReplay(session: Session, journal: String?)
    case refused(WorkerArchiveRefusal)
}
