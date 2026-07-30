import Foundation

/// §4.1.6 — estado efêmero, não auditável por padrão:
/// conexão, cursor, seleção, sessão em visualização e `lastSeen`.
/// Presença NÃO entra no log de eventos e pode sumir durante uma partição
/// sem gerar conflito de domínio.
public struct Presence: Codable, Equatable, Sendable {
    public var roomID: ULID
    public var memberID: String
    public var connected: Bool
    public var viewport: Viewport?
    public var cursor: Ponto?
    public var selectedNodeID: ULID?
    public var viewingSessionID: ULID?
    public var lastSeen: Date

    enum CodingKeys: String, CodingKey {
        case connected, viewport, cursor
        case roomID = "room_id"
        case memberID = "member_id"
        case selectedNodeID = "selected_node_id"
        case viewingSessionID = "viewing_session_id"
        case lastSeen = "last_seen"
    }

    public init(
        roomID: ULID,
        memberID: String,
        connected: Bool = true,
        viewport: Viewport? = nil,
        cursor: Ponto? = nil,
        selectedNodeID: ULID? = nil,
        viewingSessionID: ULID? = nil,
        lastSeen: Date
    ) {
        self.roomID = roomID
        self.memberID = memberID
        self.connected = connected
        self.viewport = viewport
        self.cursor = cursor
        self.selectedNodeID = selectedNodeID
        self.viewingSessionID = viewingSessionID
        self.lastSeen = lastSeen
    }
}
