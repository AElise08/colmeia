import Foundation

/// Memória curada do workspace. Diferente do journal de sessão, ela contém só
/// conhecimento humano revisável — nunca prompt nem saída bruta de terminal.
public struct WorkspaceMemory: Codable, Equatable, Sendable {
    public var content: String
    public var updatedAt: Date?
    public var updatedBy: Author?

    public init(content: String = "", updatedAt: Date? = nil, updatedBy: Author? = nil) {
        self.content = content
        self.updatedAt = updatedAt
        self.updatedBy = updatedBy
    }
}

public enum MemoryProposalStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case accepted
    case rejected
}

/// Sugestão de memória feita por um agente. A proposta não altera `MEMORY.md`
/// até ser aceita por uma identidade humana.
public struct MemoryProposal: Codable, Equatable, Sendable, Identifiable {
    public var id: ULID
    public var content: String
    public var author: Author
    public var createdAt: Date
    public var status: MemoryProposalStatus
    public var resolvedAt: Date?
    public var resolvedBy: Author?
    public var resolutionNote: String?

    public init(
        id: ULID,
        content: String,
        author: Author,
        createdAt: Date,
        status: MemoryProposalStatus = .pending,
        resolvedAt: Date? = nil,
        resolvedBy: Author? = nil,
        resolutionNote: String? = nil
    ) {
        self.id = id
        self.content = content
        self.author = author
        self.createdAt = createdAt
        self.status = status
        self.resolvedAt = resolvedAt
        self.resolvedBy = resolvedBy
        self.resolutionNote = resolutionNote
    }
}

public enum MemoryHistoryAction: String, Codable, CaseIterable, Sendable {
    case memoryUpdated = "memory_updated"
    case dailyAppended = "daily_appended"
    case proposalCreated = "proposal_created"
    case proposalAccepted = "proposal_accepted"
    case proposalRejected = "proposal_rejected"
}

/// Auditoria sem repetir o conteúdo da memória (que pode ser sensível).
public struct MemoryHistoryEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: ULID
    public var action: MemoryHistoryAction
    public var author: Author
    public var timestamp: Date
    public var proposalID: ULID?
    public var detail: String?

    public init(
        id: ULID,
        action: MemoryHistoryAction,
        author: Author,
        timestamp: Date,
        proposalID: ULID? = nil,
        detail: String? = nil
    ) {
        self.id = id
        self.action = action
        self.author = author
        self.timestamp = timestamp
        self.proposalID = proposalID
        self.detail = detail
    }
}

/// Conteúdo pronto para briefing: memória curada + diário recente, ambos já
/// sanitizados e com limite de tamanho aplicado pelo serviço persistente.
public struct MemoryBriefing: Codable, Equatable, Sendable {
    public var memory: WorkspaceMemory
    public var daily: String

    public init(memory: WorkspaceMemory, daily: String = "") {
        self.memory = memory
        self.daily = daily
    }
}
