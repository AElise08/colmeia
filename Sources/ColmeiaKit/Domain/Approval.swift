import Foundation

public enum ApprovalEstado: String, Codable, CaseIterable, Sendable {
    case pendente
    case aprovada
    case negada
    case expirada
    case resolvidaNoTerminal = "resolvida_no_terminal"
}

/// Decisão em `approval.resolve` (§6.4).
public enum ApprovalDecisao: String, Codable, CaseIterable, Sendable {
    case aprovar, negar
}

/// §5.6 — pedido de permissão como objeto de primeira classe (§4.5).
public struct Approval: Codable, Equatable, Sendable {
    public var id: ULID
    public var sessionID: ULID
    /// Desnormalizado para exibição.
    public var nodeNome: String
    /// Texto do pedido, extraído pelo adapter.
    public var resumo: String
    /// Opções detectadas ("Yes", "Yes, don't ask again", "No"), se houver.
    public var opcoes: [String]?
    public var estado: ApprovalEstado
    public var criadaEm: Date
    public var resolvidaEm: Date?
    public var resolvidaPor: Author?

    enum CodingKeys: String, CodingKey {
        case id, resumo, opcoes, estado
        case sessionID = "session_id"
        case nodeNome = "node_nome"
        case criadaEm = "criada_em"
        case resolvidaEm = "resolvida_em"
        case resolvidaPor = "resolvida_por"
    }

    public init(
        id: ULID,
        sessionID: ULID,
        nodeNome: String,
        resumo: String,
        opcoes: [String]? = nil,
        estado: ApprovalEstado,
        criadaEm: Date,
        resolvidaEm: Date? = nil,
        resolvidaPor: Author? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.nodeNome = nodeNome
        self.resumo = resumo
        self.opcoes = opcoes
        self.estado = estado
        self.criadaEm = criadaEm
        self.resolvidaEm = resolvidaEm
        self.resolvidaPor = resolvidaPor
    }
}
