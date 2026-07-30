import Foundation

/// §4.1.5 — autorização temporária e revogável para uma ação
/// que cruza a fronteira da sala para a máquina de um executor.
public enum CapabilityAction: String, Codable, CaseIterable, Sendable {
    case execute
    case read
    case write
    case openBrowser = "open_browser"
    case network
}

public struct CapabilityGrant: Codable, Equatable, Sendable {
    public var id: ULID
    public var roomID: ULID
    /// Sessão, Worker ou membro a quem o grant se aplica.
    public var subjectID: String
    /// Recurso alvo da permissão: sessão, caminho lógico, portal ou
    /// destino de rede (§4.1.5).
    public var resource: String
    /// Conjunto explícito de ações permitidas.
    public var actions: Set<CapabilityAction>
    /// Quem emitiu o grant.
    public var issuedBy: Author
    /// Quem aprovou (pode ser diferente de quem emitiu).
    public var approvedBy: Author?
    public var expiresAt: Date
    public var revokedAt: Date?
    /// Hash da proposta que originou este grant; invalida a permissão
    /// se a proposta mudar.
    public var contextHash: String?

    enum CodingKeys: String, CodingKey {
        case id, resource, actions
        case roomID = "room_id"
        case subjectID = "subject_id"
        case issuedBy = "issued_by"
        case approvedBy = "approved_by"
        case expiresAt = "expires_at"
        case revokedAt = "revoked_at"
        case contextHash = "context_hash"
    }

    public init(
        id: ULID,
        roomID: ULID,
        subjectID: String,
        resource: String,
        actions: Set<CapabilityAction>,
        issuedBy: Author,
        approvedBy: Author? = nil,
        expiresAt: Date,
        revokedAt: Date? = nil,
        contextHash: String? = nil
    ) {
        self.id = id
        self.roomID = roomID
        self.subjectID = subjectID
        self.resource = resource
        self.actions = actions
        self.issuedBy = issuedBy
        self.approvedBy = approvedBy
        self.expiresAt = expiresAt
        self.revokedAt = revokedAt
        self.contextHash = contextHash
    }

    public var isActive: Bool {
        revokedAt == nil && expiresAt > Date()
    }
}
