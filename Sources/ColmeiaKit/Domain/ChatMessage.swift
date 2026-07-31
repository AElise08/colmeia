import Foundation

/// Mensagem persistente da superfície Agent Chat.
///
/// Mensagens entre agentes também aparecem nos journals das sessões, mas esta
/// projeção permite restaurar a conversa sem reprocessar output ANSI. Mensagens
/// humanas possuem `fromNodeID == nil` e continuam associadas ao agente destino.
public struct ChatMessage: Codable, Equatable, Sendable, Identifiable {
    public var id: ULID
    public var workspaceID: ULID
    public var fromNodeID: ULID?
    public var toNodeID: ULID
    public var text: String
    public var attachments: [String]
    public var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, text, attachments
        case workspaceID = "workspace_id"
        case fromNodeID = "from_node_id"
        case toNodeID = "to_node_id"
        case createdAt = "created_at"
    }

    public init(
        id: ULID = ULID.generate(),
        workspaceID: ULID,
        fromNodeID: ULID? = nil,
        toNodeID: ULID,
        text: String,
        attachments: [String] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.fromNodeID = fromNodeID
        self.toNodeID = toNodeID
        self.text = text
        self.attachments = attachments
        self.createdAt = createdAt
    }
}

