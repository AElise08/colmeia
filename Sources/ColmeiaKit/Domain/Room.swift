import Foundation

/// §5.1 — unidade de colaboração. Uma sala pode conter muitas Missões.
public enum RoomState: String, Codable, CaseIterable, Sendable {
    case active
    case archived
    case deleted
}

public struct RoomPolicy: Codable, Equatable, Sendable {
    public var version: Int
    public var content: JSONValue

    public init(version: Int = 1, content: JSONValue = .object([:])) {
        self.version = version
        self.content = content
    }
}

// §5.1
public struct Room: Codable, Equatable, Sendable {
    public var id: ULID
    public var name: String
    /// §5.1 — membro administrador.
    public var ownerID: String?
    public var policy: RoomPolicy
    /// Versão da chave da sala, se cifrada (definido-pela-implementação).
    public var keyVersion: Int?
    /// Workspace vinculado a esta sala (opcional — vínculo 1:1).
    public var workspaceID: ULID?
    public var createdAt: Date
    public var updatedAt: Date
    public var state: RoomState

    enum CodingKeys: String, CodingKey {
        case id, name, policy, state
        case ownerID = "owner_id"
        case keyVersion = "key_version"
        case workspaceID = "workspace_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(
        id: ULID,
        name: String,
        ownerID: String? = nil,
        policy: RoomPolicy = RoomPolicy(),
        keyVersion: Int? = nil,
        workspaceID: ULID? = nil,
        createdAt: Date,
        updatedAt: Date,
        state: RoomState = .active
    ) {
        self.id = id
        self.name = name
        self.ownerID = ownerID
        self.policy = policy
        self.keyVersion = keyVersion
        self.workspaceID = workspaceID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.state = state
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(ULID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        ownerID = try c.decodeIfPresent(String.self, forKey: .ownerID)
        policy = try c.decodeIfPresent(RoomPolicy.self, forKey: .policy) ?? RoomPolicy()
        keyVersion = try c.decodeIfPresent(Int.self, forKey: .keyVersion)
        workspaceID = try c.decodeIfPresent(ULID.self, forKey: .workspaceID)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        state = try c.decodeIfPresent(RoomState.self, forKey: .state) ?? .active
    }
}
